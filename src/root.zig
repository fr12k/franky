//! franky — Zig port of the franky-mono agent architecture.
//!
//! Layered module exports:
//!   - `ai` provider-agnostic LLM streaming
//!   - `agent` stateful tool-using runtime
//!   - `coding` tools, session, modes
//!
//! All public IO-performing APIs accept an allocator (and, where
//! concurrency is spawned, a `Cancel` pointer) explicitly.

pub const ai = @import("ai/mod.zig");
pub const agent = @import("agent/mod.zig");
pub const coding = @import("coding/mod.zig");
pub const tui = @import("tui/mod.zig");
/// v2.31 — content-aware compression library. Re-exported at the top
/// level so dependents of franky can `franky.zompress.compress(...)` etc.
/// The dependency is wired in `build.zig` via `b.dependency("zompress", …)`
/// and the `zompress` module is registered by the upstream build script
/// (see patch note in `zig-pkg/zompress-*/build.zig`).
pub const zompress = @import("zompress");
/// Programmatic SDK facade (§5.9). Re-exports the stable public
/// surface for embedding franky in other Zig programs without
/// learning the ai/ vs agent/ vs coding/ layering. Deeper modules
/// stay reachable via `franky.ai`/`franky.agent`/`franky.coding`.
pub const sdk = @import("sdk.zig");
/// v1.3.0 — shared `testIo()` helper. Integration tests use
/// `franky.test_helpers.threadedIo()`; src-internal tests import
/// `test_helpers.zig` relatively.
pub const test_helpers = @import("test_helpers.zig");

/// v2.4.0 — centralized allocator. All tests and production code
/// that doesn't thread an allocator explicitly gets it from here.
/// Change `src/global_allocator.zig` to swap the allocator project-wide.
pub const global_allocator = @import("global_allocator.zig");

/// Version info injected by goreleaser via -Dversion / -Dcommit / -Ddate.
/// Falls back to "dev"/"unknown" when building with plain `zig build`.
const build_options = @import("build_options");
pub const version: []const u8 = build_options.version;
pub const commit: []const u8 = build_options.commit;
pub const build_date: []const u8 = build_options.date;

test {
    _ = ai;
    _ = agent;
    _ = coding;
    _ = tui;
    _ = sdk;
    _ = test_helpers;
    _ = zompress;
}
