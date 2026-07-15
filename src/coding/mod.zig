//! coding — franky-coding-agent: tools, session, modes.

pub const tools = struct {
    pub const read = @import("tools/read.zig");
    pub const write = @import("tools/write.zig");
    pub const edit = @import("tools/edit.zig");
    pub const bash = @import("tools/bash.zig");
    pub const ls = @import("tools/ls.zig");
    pub const find = @import("tools/find.zig");
    pub const grep = @import("tools/grep.zig");
    pub const subagent = @import("tools/subagent.zig");
    pub const web_search = @import("tools/web_search.zig");
    pub const web_fetch = @import("tools/web_fetch.zig");
    pub const workspace = @import("tools/workspace.zig");
    pub const common = @import("tools/common.zig");
    pub const truncate = @import("tools/truncate.zig");
    pub const ccr_retrieve = @import("tools/ccr_retrieve.zig");
};

pub const modes = struct {
    pub const print = @import("modes/print.zig");
    pub const interactive = @import("modes/interactive.zig");
    pub const rpc = @import("modes/rpc.zig");
    pub const proxy = @import("modes/proxy.zig");
};

pub const terminal = @import("terminal.zig");

pub const session = @import("session/mod.zig");

// ═══════════════════════════════════════════════════
// Backward-compatible aliases for moved modules.
// These replicate the v2.22 flat namespace so consumers
// (modes, bin/) resolve `franky.coding.<name>` without
// changes. Remove after v2.24 when consumers are updated.
// ═══════════════════════════════════════════════════

pub const cli = @import("config/cli.zig");
pub const settings = @import("config/settings.zig");
pub const profiles = @import("config/profiles.zig");
pub const role = @import("security/role.zig");
pub const permissions = @import("security/permissions.zig");
pub const auth = @import("security/auth.zig");
pub const object_store = @import("session/object_store.zig");
pub const branching = @import("session/branching.zig");
pub const compaction = @import("session/compaction.zig");
pub const replay = @import("session/replay.zig");
pub const compression = @import("compression.zig");
pub const models = @import("model_catalog/models.zig");
pub const models_render = @import("model_catalog/render.zig");
pub const models_fetch = @import("model_catalog/fetch.zig");

pub const config = struct {
    pub const cli = @import("config/cli.zig");
    pub const settings = @import("config/settings.zig");
    pub const profiles = @import("config/profiles.zig");
    /// v2.22 — unified config resolver.
    pub const resolver = @import("config.zig");
};
pub const security = struct {
    pub const role = @import("security/role.zig");
    pub const permissions = @import("security/permissions.zig");
    pub const auth = @import("security/auth.zig");
    pub const path_safety = @import("security/path_safety.zig");
    pub const env_denylist = @import("security/env_denylist.zig");
};
pub const model_catalog = struct {
    pub const models = @import("model_catalog/models.zig");
    pub const render = @import("model_catalog/render.zig");
    pub const fetch = @import("model_catalog/fetch.zig");
};
pub const regex = @import("regex.zig");
pub const gitignore = @import("gitignore.zig");
pub const rpc = @import("rpc.zig");
pub const slash = @import("slash.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const improvement = @import("improvement.zig");
pub const update = @import("update.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const skills = @import("skills.zig");
pub const instructions = @import("instructions.zig");
pub const restart = @import("restart.zig");
pub const templates = @import("templates.zig");
pub const extensions = @import("extensions.zig");
pub const extensions_builtin = struct {
    pub const catalog = @import("extensions_builtin/catalog.zig");
    pub const echo = @import("extensions_builtin/echo.zig");
};

test {
    _ = tools.read;
    _ = tools.write;
    _ = tools.edit;
    _ = tools.bash;
    _ = tools.ls;
    _ = tools.find;
    _ = tools.grep;
    _ = tools.subagent;
    _ = tools.web_search;
    _ = tools.web_fetch;
    _ = tools.workspace;
    _ = tools.common;
    _ = tools.truncate;
    _ = modes.print;
    _ = modes.interactive;
    _ = modes.rpc;
    _ = modes.proxy;
    _ = terminal;
    _ = session;
    _ = cli; // backward compat alias
    _ = settings; // backward compat alias
    _ = profiles; // backward compat alias
    _ = role; // backward compat alias
    _ = permissions; // backward compat alias
    _ = auth; // backward compat alias
    _ = object_store; // backward compat alias
    _ = branching; // backward compat alias
    _ = compaction; // backward compat alias
    _ = replay; // backward compat alias
    _ = compression;
    _ = models; // backward compat alias
    _ = models_render; // backward compat alias
    _ = models_fetch; // backward compat alias
    _ = config.cli;
    _ = config.settings;
    _ = config.profiles;
    _ = security.role;
    _ = security.permissions;
    _ = security.auth;
    _ = security.path_safety;
    _ = security.env_denylist;
    _ = model_catalog.models;
    _ = model_catalog.render;
    _ = model_catalog.fetch;
    _ = regex;
    _ = gitignore;
    _ = rpc;
    _ = slash;
    _ = diagnostics;
    _ = improvement;
    _ = update;
    _ = skills;
    _ = restart;
    _ = templates;
    _ = extensions;
    _ = extensions_builtin.catalog;
    _ = extensions_builtin.echo;
}
