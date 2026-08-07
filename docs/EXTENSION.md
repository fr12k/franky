Here is the minimal `main.zig` that wires a franky extension — tools, skills, and hooks — into print mode with a single registration call:

```zig
//! franky-go — standalone binary with the go-dev extension pre-loaded.
//!
//! Wire a franky extension + skill files in ~20 lines of main.zig.
//! Everything else (agent loop, mode dispatch, skill loading) stays
//! fully controlled by franky — no forking required.
//!
//! Usage:
//!   zig build run -- --extensions go-dev \"Write a Go http handler\"
//!   zig build run -- --mode proxy
//!   zig build run -- --extensions go-dev --mode proxy

const std = @import(\"std\");
const franky = @import(\"franky\");
const go_dev = @import(\"franky-golang\");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // ── 1. Register the extension in the runtime catalog ─────────────
    // After this call, `--extensions go-dev` resolves to this extension
    // at startup. The extension's init_fn registers:
    //   - Tools  → merged into the agent loop's tool list
    //   - Presets → merged into the subagent PresetRegistry
    //   - Slash commands → merged into the slash registry (proxy mode)
    try franky.ext_catalog.register(\"go-dev\", go_dev.extension);

    // ── 2. Skills go in <workspace>/skills/*.md ─────────────────────
    // No code needed. Skills are auto-discovered by franky's
    // buildSystemPromptIo() from these roots:
    //   <workspace>/skills/          (highest precedence)
    //   $FRANKY_HOME/skills/
    //   ~/.franky/skills/
    //
    // Activation is deterministic — --skill NAME or auto_apply glob.
    // Example skill file (skills/go-dev.md):
    //
    //   ---
    //   name: golang
    //   description: |
    //     Go 1.24 idioms and project structure. TRIGGER when: editing .go files
    //     or go.mod.
    //   auto_apply: [\"**/*.go\", \"**/go.mod\", \"**/go.sum\"]
    //   ---
    //
    //   # Go 1.24 programming reference
    //   ...
    //
    // ── 3. Hooks work out of the box ─────────────────────────────────
    // The extension system already provides the Host API:
    //   host.registerTool()     — add a tool
    //   host.registerPreset()   — add a subagent preset
    //   host.registerCommand()  — add a slash command (proxy)
    //   host.subscribe()        — subscribe to agent events
    //
    // No additional wiring needed.

    // ── 4. Delegate to franky's mode driver ─────────────────────────
    // Dispatches --mode print (default) and --mode proxy.
    // The extension tools are already in final_tools; skills are in
    // the system prompt; hooks are active.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }
    try franky.coding.modes.print.run(gpa, io, init.minimal.environ, init.environ_map, args_list.items);
}
```

## What each piece enables

| Piece | How | Code needed |
|-------|-----|-------------|
| **Tools** | Extension `init_fn` calls `host.registerTool()` | `ext_catalog.register(\"go-dev\", go_dev.extension)` |
| **Subagent presets** | Extension `init_fn` calls `host.registerPreset()` (or `registerPreset(&preset_registry)` for standalone) | Same one-liner |
| **Skills** | `<workspace>/skills/*.md` files auto-discovered by `buildSystemPromptIo()` | Zero |
| **Slash commands** | Extension `init_fn` calls `host.registerCommand()` — active in proxy mode | Same one-liner |
| **Event subscriptions** | Extension `init_fn` calls `host.subscribe()` — agent events forwarded | Same one-liner |
| **Print mode** | `--extensions go-dev \"write a Go http server\"` | Delegated to franky |
| **Proxy mode** | `--extensions go-dev --mode proxy` | Delegated to franky |
| **CLI flags** | `--provider`, `--model`, `--thinking`, `--role`, etc. | Delegated to franky |
| **Session persistence** | Auto-saved under `$FRANKY_HOME/sessions/` | Delegated to franky |
| **Agent loop** | Turn logic, tool execution, error recovery, guardrails | Delegated to franky |
| **Permissions** | `--prompts`, `--yes`, `--allow-tools`, `--deny-tools` | Delegated to franky |

## How the extension `init_fn` looks

Inside your `go_dev.zig` the extension factory returns an `Extension` with an `init_fn`:

```zig
pub fn extension() ext.Extension {
    return .{
        .name = \"go-dev\",
        .version = \"0.2.0\",
        .init_fn = init,
    };
}

fn init(_: *ext.Extension, host: *ext.Host) ext.ExtError!void {
    // Tool → agent loop sees it immediately
    try host.registerTool(goTool());

    // Preset → subagents can spawn go-dev sub-agents
    if (host.presets) |registry| try registerPreset(registry);
}
```

The `Host` view gives access to `registerTool`, `registerPreset`, `registerCommand`, and `subscribe` — everything a mode driver already wires.

## What changed in franky to make this work

1. **`extensions_builtin/catalog.zig`** — added `register()` for runtime registration
2. **`print.zig`** — added extension loading + tool merging into `final_tools`
3. **`proxy.zig`** — added extension tool merging into `session.tools` after extension loading
4. **`sdk.zig`** — added `ext_catalog` re-export

No changes to the agent loop, skill loading, or mode dispatch were needed — franky's existing architecture already supports all of this once the extension's tools are properly merged.