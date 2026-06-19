//! Comptime signature hash test for 🔒 PUBLIC API functions.
//!
//! Every function annotated with
//!   `/// 🔒 PUBLIC API — do not remove, do not change signature`
//! gets one entry here. If a signature drifts, the hash changes and
//! `zig build test` fails at compile time.
//!
//! To intentionally change a signature:
//!   1. Make the code change.
//!   2. Run `zig build test` — it fails and prints the new hash.
//!   3. Copy the "actual" hash from the error message into this file.
//!   4. Run `zig build test` again — it passes.
//!   5. Bump semver-major and document the break.
//!
//! Note: functions with identical signatures share the same hash
//! (e.g. `abort`, `reset`, `interrupt` are all `fn(*Agent) void`).
//! This is fine — changing any of them requires updating all matching
//! entries, and the test will catch the drift.

const std = @import("std");
const franky = @import("franky");
const sdk = franky.sdk;

fn H(f: anytype) u64 {
    return std.hash.Wyhash.hash(0, @typeName(@TypeOf(f)));
}
fn HT(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

fn check(comptime tag: []const u8, f: anytype, comptime expected: u64) void {
    const actual = comptime H(f);
    if (actual != expected) {
        @compileError(std.fmt.comptimePrint(
            "🔒 " ++ tag ++ " signature changed! expected 0x{x} got 0x{x}",
            .{ expected, actual },
        ));
    }
}
fn checkT(comptime tag: []const u8, comptime T: type, comptime expected: u64) void {
    const actual = comptime HT(T);
    if (actual != expected) {
        @compileError(std.fmt.comptimePrint(
            "🔒 " ++ tag ++ " type changed! expected 0x{x} got 0x{x}",
            .{ expected, actual },
        ));
    }
}

// ── Agent ──
test "hash: Agent.interrupt" {
    check("Agent.interrupt", sdk.Agent.interrupt, 0x904ab417dfd5353a);
}
test "hash: Agent.steer" {
    check("Agent.steer", sdk.Agent.steer, 0x230ab71a6bb8f610);
}
test "hash: Agent.followUp" {
    check("Agent.followUp", sdk.Agent.followUp, 0x6369236f0ae587e7);
}
test "hash: Agent.subscribe" {
    check("Agent.subscribe", sdk.Agent.subscribe, 0x0e5cd00c8ca778d3);
}
test "hash: Agent.setModel" {
    check("Agent.setModel", sdk.Agent.setModel, 0xffc5fc5fe72149cc);
}
test "hash: Agent.setTools" {
    check("Agent.setTools", sdk.Agent.setTools, 0xd4a3dd8561b5e3df);
}
test "hash: Agent.setSystemPrompt" {
    check("Agent.setSystemPrompt", sdk.Agent.setSystemPrompt, 0xcde035bfee397355);
}
test "hash: Agent.setThinking" {
    check("Agent.setThinking", sdk.Agent.setThinking, 0xd03f05ec2d694dff);
}
test "hash: Agent.reset" {
    check("Agent.reset", sdk.Agent.reset, 0x904ab417dfd5353a);
}
test "hash: Agent.continueRun" {
    check("Agent.continueRun", sdk.Agent.continueRun, 0x529942dee3321041);
}
test "hash: Agent.abort" {
    check("Agent.abort", sdk.Agent.abort, 0x904ab417dfd5353a);
}
test "hash: Agent.drainSteerQueue" {
    check("Agent.drainSteerQueue", sdk.Agent.drainSteerQueue, 0x64539739f9a9ad40);
}
test "hash: Agent.drainFollowUpQueue" {
    check("Agent.drainFollowUpQueue", sdk.Agent.drainFollowUpQueue, 0xf8820f962b0665a3);
}
test "hash: Agent.pendingSteerCount" {
    check("Agent.pendingSteerCount", sdk.Agent.pendingSteerCount, 0x0e88d01b6540ab15);
}
test "hash: Agent.pendingFollowUpCount" {
    check("Agent.pendingFollowUpCount", sdk.Agent.pendingFollowUpCount, 0x0e88d01b6540ab15);
}

// ── transform ──
test "hash: transform.apiAcceptsThinkingOnInput" {
    check("transform.apiAcceptsThinkingOnInput", sdk.transform.apiAcceptsThinkingOnInput, 0xa4a312caf08a8f89);
}
test "hash: transform.transformForApi" {
    check("transform.transformForApi", sdk.transform.transformForApi, 0x8daac814fab2366d);
}
test "hash: transform.freeTransformed" {
    check("transform.freeTransformed", sdk.transform.freeTransformed, 0x108ba97fcaf7edae);
}

// ── log ──
test "hash: log.setLevel" {
    check("log.setLevel", sdk.log.setLevel, 0x277b2556a3aff56d);
}
test "hash: log.enabled" {
    check("log.enabled", sdk.log.enabled, 0x6f46c170115cf8b1);
}
test "hash: log.resetScopeOverrides" {
    check("log.resetScopeOverrides", sdk.log.resetScopeOverrides, 0x4454be924aca4fb7);
}

// ── errors ──
test "hash: errors.fromToolResult" {
    check("errors.fromToolResult", sdk.errors.fromToolResult, 0xbb6c6c4af4d97010);
}

// ── retry ──
test "hash: retry.nextDelay" {
    check("retry.nextDelay", sdk.retry.nextDelay, 0xc7a11c80d67a31b0);
}

// ── object_store ──
test "hash: object_store.store" {
    check("object_store.store", sdk.object_store.store, 0x3857d734b61590e1);
}
test "hash: object_store.resolve" {
    check("object_store.resolve", sdk.object_store.resolve, 0x4592e310407c0e93);
}
test "hash: object_store.sweep" {
    check("object_store.sweep", sdk.object_store.sweep, 0x95001acda30ed634);
}
test "hash: object_store.writeObject" {
    check("object_store.writeObject", sdk.object_store.writeObject, 0xe5f88098541e605f);
}

// ── session ──
test "hash: session.migrateSessionIfNeeded" {
    check("session.migrateSessionIfNeeded", franky.coding.session.migrateSessionIfNeeded, 0x8042677888491156);
}

// ── session (factory) — §3.2, added in v3.3 ──
test "hash: SessionState.init" {
    check("SessionState.init", sdk.SessionState.init, 0x7fded742a2806b8a);
}
test "hash: SessionState.deinit" {
    check("SessionState.deinit", sdk.SessionState.deinit, 0x4628f64c24aea49c);
}
test "hash: SessionState.id" {
    check("SessionState.id", sdk.SessionState.id, 0xdfaeef31f4c4c4e5);
}
test "hash: SessionState.persist" {
    check("SessionState.persist", sdk.SessionState.persist, 0xc64b12c6fc422cec);
}
test "hash: SessionHandle.deinit" {
    check("SessionHandle.deinit", sdk.SessionHandle.deinit, 0xabbf6cbd29447ec);
}
test "hash: SessionHandle.sessionId" {
    check("SessionHandle.sessionId", sdk.SessionHandle.sessionId, 0x325f033c5f286cf5);
}
test "hash: createSession" {
    check("createSession", sdk.createSession, 0xe0d2753ed09846d0);
}

// ── types ──
test "hash: errors.ErrorSource" {
    checkT("errors.ErrorSource", sdk.errors.ErrorSource, 0x40fefdc831bac7da);
}
