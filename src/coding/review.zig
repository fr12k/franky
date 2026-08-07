//! Shared multi-model review prompt builder.
//!
//! The `/review` slash command (proxy mode) needs a
//! self-contained prompt that embeds the review instructions so the
//! feature works without requiring the `multimodel-review` skill to be
//! active. This module provides the shared prompt text — identical
//! across modes — avoiding the duplication that the original inline
//! string-literals introduced.

const std = @import("std");

/// Returns the shared multi-model review instruction prompt.
/// The caller owns the returned slice (must allocator.free).
///
/// The prompt tells the main agent to collect a diff, fan out
/// `diff-review` sub-agents, check quorum, and aggregate results.
/// The agent is expected to substitute `[paste full diff]` with the
/// actual diff output when constructing each sub-agent call.
pub fn buildReviewPrompt(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\Run a multi-model code review using the following process:
        \\
        \\## Process
        \\
        \\1. **Collect the diff.**
        \\   Default: `git diff HEAD` (staged + unstaged). Accept an explicit path
        \\   or revision if the user provided one (e.g. `src/agent/loop.zig`).
        \\
        \\2. **Select profiles.**
        \\   Priority order:
        \\   a. `--profiles A,B,C` in the invocation argument -- split on comma, use as-is.
        \\   b. The `## Review configuration` block in this system prompt (populated from
        \\      `settings.json -> review.profiles` at session start).
        \\   c. Auto-discovery fallback: call `list_subagent_presets` and select up to
        \\      `max_models` profiles (default 4) whose names suggest code capability.
        \\
        \\3. **Fan out in parallel -- single tool-call batch.**
        \\   Spawn one `diff-review` subagent per selected profile. All subagents receive
        \\   the identical prompt. **The prompt is critical: it must be strict about
        \\   bounding the agent's investigation.** `diff-review` has NO file-reading
        \\   tools -- it can only analyse the diff text in the prompt. Use the following
        \\   wording verbatim:
        \\
        \\   > Review this diff for correctness, security, and performance issues.
        \\   >
        \\   > **Rules (follow exactly):**
        \\   > 1. **Work from the diff only.** Do NOT read, grep, or examine any
        \\   >    source files outside what is shown in the diff. If context from
        \\   >    the diff alone is insufficient, prefix the finding with
        \\   >    `[needs verification]` and move on.
        \\   > 2. **Make exactly one pass.** Identify all findings from the diff text
        \\   >    in a single read-through. Do NOT go back to re-evaluate earlier
        \\   >    findings after reading later parts of the diff.
        \\   > 3. **Do not speculate on allocator types, method signatures, or
        \\   >    standard-library behavior** that you cannot confirm from the diff.
        \\   >    Flag those with `[uncertain]` if they matter.
        \\   > 4. **Report only confirmed findings.** Omit potential or might-be
        \\   >    issues unless you are certain.
        \\   > 5. **Output format -- one line per finding:**
        \\   >    `file:line -- description`
        \\   >    Prefix with `[critical]`, `[bug]`, `[leak]`, `[race]`, `[design]`,
        \\   >    or `[nit]` as appropriate.
        \\   > 6. **Keep the response under 300 lines total.** Be concise.
        \\   >
        \\   > Include only real issues; omit style nits and formatting comments.
        \\   > [paste full diff]
        \\
        \\   Use `timeout_ms` from the Review configuration (default 180000).
        \\   Use `preset: "diff-review"` and `profile: "<profile-name>"` for each call.
        \\
        \\4. **Check quorum.**
        \\   Count how many subagents returned output. If fewer than `min_models`
        \\   (default 2), abort: Multi-model review aborted: only N/M models
        \\   responded (minimum: min_models required).
        \\
        \\5. **Aggregate.**
        \\   Group findings semantically -- same file, same concern, possibly different
        \\   line numbers. Label each group:
        \\   - `[all N]`  -- every model flagged it -> high confidence
        \\   - `[N-1 of N]` -- all but one -> medium confidence
        \\   - `[1 of N]`  -- one model only -> low confidence / disputed
        \\
        \\6. **Render the unified report** (see Output format below).
        \\
        \\## Output format
        \\
        \\```
        \\## Multi-Model Review  (N models . M findings)
        \\
        \\### High confidence  [found by N/N]
        \\- file:line -- description
        \\
        \\### Medium confidence  [found by N-1/N]
        \\- file:line -- description
        \\
        \\### Low confidence  [found by 1/N]
        \\- file:line -- description  (model-name only)
        \\
        \\### Profiles that timed out or errored
        \\- profile-name: reason
        \\```
        \\
        \\Sort sections high -> low confidence. Within each section, sort by file path.
    , .{});
}
