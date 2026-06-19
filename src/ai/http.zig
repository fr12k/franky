//! HTTP transport — §G of the spec.
//!
//! Exposes:
//!   - `Request` — payload envelope (method, url, headers, body).
//!   - `Timeouts` — §G.4 phase timeouts (re-exported from `registry.zig`).
//!   - `driveSseFromBytes(...)` — SSE state-machine pump that tolerates a
//!     bounded gap between emitted events; returns `Timeout` if the gap
//!     exceeds `event_gap_ms`.
//!   - `streamSse(...)` — one-shot fetch + parse convenience built on
//!     `Client.fetch` (buffered). Used by provider-side tests;
//!     production providers inline their own fetch so they can inspect
//!     status/headers before parsing.
//!
//! ### Timeout strategy
//!
//! The four §G.4 fields (`connect_ms`, `upload_ms`, `first_byte_ms`,
//! `event_gap_ms`) are all plumbed through `StreamOptions.timeouts`.
//!
//! - **v0.3.0**: shapes + `event_gap_ms` enforcement in
//!   `driveSseFromBytes`.
//! - **v1.3.1**: total wall-clock budget = `connect + upload +
//!   first_byte` enforced between retry attempts via `fetchDeadlineMs()`.
//! - **v1.8.0** (this pass): per-phase enforcement via
//!   `fetchAttemptPhased`. Each request goes through the lower-level
//!   `client.connect → request → sendBody → receiveHead → readBody`
//!   sequence (instead of one-shot `client.fetch`), and a watchdog
//!   thread closes the connection's underlying stream when the
//!   current phase budget expires. The blocked phase op then returns
//!   `error.ConnectionResetByPeer` / `error.BrokenPipe`, which we
//!   classify as `error.Timeout`. The phase tag (`connect`, `upload`,
//!   `first_byte`) is reported via the optional `*PhaseInfo`
//!   out-parameter on `fetchWithRetryAndTimeoutsAndHooksAndPhases`.
//!
//! The connect-phase watchdog can only **tag** post-fact (not
//! interrupt) — `client.request()` does CA-bundle setup before
//! exposing a connection to close, and we don't have a hook between
//! those two. Practically this is rarely a problem because the
//! TCP+TLS connect itself is what's hanging, and the OS-level connect
//! timeout (~60s on Linux) bounds it long before user-facing impact.
//!
//! Body reading still buffers the full response before SSE parsing —
//! true streaming reads are post-1.0 (§N.2 `io.concurrent`).

const std = @import("std");
const sse_mod = @import("sse.zig");
const stream_mod = @import("stream.zig");
const errors_mod = @import("errors.zig");
const registry_mod = @import("registry.zig");
const log = @import("log.zig");
const err_map = @import("error_map.zig");

pub const Timeouts = registry_mod.Timeouts;

// `Client` is a vendored copy of `std.http.Client` from the bundled Zig
// 0.17-dev toolchain with Zig PR #23365 applied. Without that patch, when
// `HTTPS_PROXY` points at a forward proxy and the origin uses HTTPS, the
// stdlib client opens the CONNECT tunnel correctly but then sends the
// request body as plaintext through the tunnel — TLS-intercepting proxies
// (Squid with `host_strict_verify`, Docker Sandboxes' MITM proxy) reject
// that with "Host header does not match CONNECT request". The vendored
// copy performs the missing TLS handshake on the established tunnel.
//
// All franky internals (providers, model index generator) and
// franky-do's Slack web_api consume this alias, not
// `std.http.Client`, so the patch is in effect everywhere we make
// HTTP calls.
//
// See https://github.com/ziglang/zig/issues/19878 and PR #23365 for
// background, and `vendored/http_client.zig` for the patched source.
pub const Client = @import("vendored/http_client.zig");

/// Cast an opaque `StreamCtx.http_client` handle back to a typed pointer.
/// The inverse of `@ptrCast(client_ptr)` at the call site.
pub fn clientFromOpaque(h: *anyopaque) *Client {
    return @ptrCast(@alignCast(h));
}

// ─── client setup ────────────────────────────────────────────────
//
// `setupClientFromEnv` consolidates proxy setup for any `Client`
// we hand out. Each provider streamFn previously called
// `initDefaultProxies` inline; this centralises it.
//
// **v1.29.7 — proper proxy lifetime via caller-owned arena.**
// History: v1.28.x scoped a `proxy_arena` to this very function
// and `defer`-deinited it on return — but the vendored Client's
// `http_proxy` / `https_proxy` fields are pointers INTO that
// arena (per `vendored/http_client.zig:1331-1334`: "Uses `arena`
// for a few small allocations that must outlive the client"),
// so the next request's `connect()` deref'd freed memory.
// v1.29.4 routed around the UAF by passing the caller's
// long-lived allocator straight in — fixing the segfault but
// leaking ~100 bytes (Proxy struct + host + maybe Basic-auth
// blob) per call, since nobody tracks when the client is done.
// v1.29.7 honours the upstream contract literally: this
// function creates a fresh `ArenaAllocator`, hands its allocator
// to `initDefaultProxies`, and **returns the arena to the
// caller**. The caller pairs the arena's deinit with the
// client's, in that order:
//
//     var client = Client{ .allocator = a, .io = io };
//     var proxy_arena = try http.setupClientFromEnv(&client, a, env_map);
//     defer {
//         client.deinit();          // uses proxy pointers (alive)
//         proxy_arena.deinit();     // then frees them
//     }
//
// Single `defer { ... }` block is intentional — two separate
// defers would LIFO-order against intent.

pub fn setupClientFromEnv(
    client: *Client,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) anyerror!std.heap.ArenaAllocator {
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer proxy_arena.deinit();
    try client.initDefaultProxies(proxy_arena.allocator(), environ_map);
    return proxy_arena;
}

// ─── v1.3.0 dedup — stream client acquire/release ──────────────────
//
// Every provider's `streamFn` carried the same
// `var local_client / var proxy_arena / if (ctx.http_client) |h| …
// else blk: { setupClientFromEnv … } / defer cleanup` block
// (byte-identical across openai_chat, openai_responses, anthropic,
// google_gemini, google_vertex). See `DEDUP_PLAN.md` Finding 4.

/// Owned HTTP client resources for one streaming request.
/// `acquireStreamClient` returns `null` when env-proxy setup failed —
/// in that case it has already pushed a `start` + `transport` error
/// event onto `ctx.out` and the caller should just `return`.
pub const StreamClient = struct {
    client: *Client,
    local_client: Client,
    proxy_arena: ?std.heap.ArenaAllocator,
    /// True when we own `local_client` (i.e. `ctx.http_client` was
    /// null). False when the caller passed a persistent client.
    owns: bool,

    pub fn deinit(self: *StreamClient) void {
        if (self.owns) {
            self.local_client.deinit();
            if (self.proxy_arena) |*a| a.deinit();
        }
    }
};

/// Resolve the HTTP client for a streaming request. When
/// `ctx.http_client` is non-null it is reused as-is (caller-owned);
/// otherwise a per-request `local_client` is constructed and, if
/// `ctx.options.environ_map` is set, wired up with env proxies via
/// `setupClientFromEnv`.
///
/// On `setupClientFromEnv` failure this pushes a `start` event plus a
/// `transport` error event onto `ctx.out` and returns `null` — the
/// caller should `return` immediately.
///
/// **Review fix (multi-model v1.3.1):** if `std.fmt.allocPrint` fails
/// while building the transport-error message (OOM), the original
/// `catch return null` left the channel with only a `.start` event and
/// no terminal event, so consumers blocked on `next` forever. Now the
/// OOM arm still closes the channel with a zero-length owned message
/// before returning `null`.
pub fn acquireStreamClient(ctx: registry_mod.StreamCtx) ?StreamClient {
    var local_client: Client = undefined;
    var proxy_arena: ?std.heap.ArenaAllocator = null;
    const client: *Client = if (ctx.http_client) |h|
        @ptrCast(@alignCast(h))
    else blk: {
        local_client = .{ .allocator = ctx.allocator, .io = ctx.io };
        if (ctx.options.environ_map) |env_map| {
            proxy_arena = setupClientFromEnv(&local_client, ctx.allocator, env_map) catch |e| {
                ctx.out.push(ctx.io, .start) catch {};
                const msg = std.fmt.allocPrint(ctx.allocator, "client setup failed: {s}", .{@errorName(e)}) catch
                    (ctx.allocator.alloc(u8, 0) catch return null);
                ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
                    .code = errors_mod.Code.transport,
                    .message = msg,
                } });
                return null;
            };
        }
        break :blk &local_client;
    };
    return .{
        .client = client,
        .local_client = local_client,
        .proxy_arena = proxy_arena,
        .owns = ctx.http_client == null,
    };
}

// ─── §G.4 per-phase timeout primitives (v1.8.0) ──────────────────

/// On-success this is `none`; on `error.Timeout` it identifies which
/// phase the watchdog killed. `event_gap_ms` timeouts come from
/// `driveSseFromBytes` and are reported separately at the SSE layer.
pub const PhaseTag = enum {
    none,
    connect,
    upload,
    first_byte,

    pub fn label(self: PhaseTag) []const u8 {
        return switch (self) {
            .none => "none",
            .connect => "connect",
            .upload => "upload",
            .first_byte => "first_byte",
        };
    }
};

/// Out-parameter passed by callers that want to know which phase
/// timed out. `null` is fine — the per-phase enforcement still
/// happens; only the diagnostic tag is dropped on the floor.
pub const PhaseInfo = struct {
    timed_out_phase: PhaseTag = .none,
    /// Provider error message from the last retryable HTTP response
    /// (5xx/429 body's `error.message`). Dupe'd from the client
    /// allocator; the caller must free it. Populated by
    /// `fetchAttemptPhased`; useful when a later transport error
    /// exhausts retries so the upstream error can be surfaced.
    last_error_message: ?[]const u8 = null,
};

/// Shared state between the request thread and its watchdog. Owned
/// by the request thread; the watchdog reads/writes via `mutex`.
///
/// The watchdog is a single thread per request attempt. It polls
/// the deadline every `poll_ms` and, when armed and expired, closes
/// the connection's underlying `std.Io.net.Stream` so the blocked
/// phase op returns. This gives us interrupt semantics without
/// needing async/coroutines.
const PhaseGuard = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Connection whose stream we close when the deadline fires.
    /// Null while no connection exists yet (i.e. during `connect`).
    connection: ?*Client.Connection = null,
    /// Absolute deadline in ms-since-epoch for the active phase.
    /// 0 = no active deadline (between phases or done).
    deadline_ms: i64 = 0,
    /// Phase tag for the active deadline.
    current_phase: PhaseTag = .none,
    /// Phase whose deadline the watchdog fired (if any). Read by
    /// the request thread after a phase op fails to disambiguate
    /// "real" connection error from "we killed it".
    fired_phase: PhaseTag = .none,
    /// Set by the request thread when the request completes (one
    /// way or another). The watchdog observes and exits.
    stop: std.atomic.Value(bool) = .init(false),
    /// Sleep granularity. Tests can tighten this. Production keeps
    /// 50 ms (snappy phase-end shutdown, negligible CPU).
    poll_ms: u64 = 50,
};

fn watchdogLoop(g: *PhaseGuard) void {
    while (!g.stop.load(.acquire)) {
        nanoSleepMs(g.poll_ms);
        if (g.stop.load(.acquire)) return;
        g.mutex.lockUncancelable(g.io);
        const now = stream_mod.nowMillis();
        if (g.deadline_ms > 0 and now >= g.deadline_ms) {
            // Fire — record which phase, then `shutdown(.both)`
            // the connection stream so the blocked phase op
            // returns. Disarm in the same critical section so we
            // don't re-fire if the request thread is slow to react.
            // shutdown is preferred over close because the request
            // thread still holds Reader/Writer state on the socket;
            // closing the fd from another thread races with that
            // state and crashes. shutdown signals EOF to in-flight
            // reads/writes without freeing the fd.
            g.fired_phase = g.current_phase;
            const conn = g.connection;
            g.deadline_ms = 0;
            g.mutex.unlock(g.io);
            if (conn) |c| c.stream_reader.stream.shutdown(g.io, .both) catch {};
            continue;
        }
        g.mutex.unlock(g.io);
    }
}

/// Arm `g` for a new phase. Caller-side: the request thread calls
/// this immediately before the IO op and `disarmPhase` immediately
/// after it returns.
fn armPhase(g: *PhaseGuard, phase: PhaseTag, conn: ?*Client.Connection, budget_ms: u32) void {
    if (budget_ms == 0) return; // disabled — leave deadline=0
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    g.current_phase = phase;
    g.connection = conn;
    g.deadline_ms = stream_mod.nowMillis() + @as(i64, @intCast(budget_ms));
}

/// Disarm — clears the active deadline so the watchdog can't fire.
/// Returns whether the watchdog already fired (caller maps that to
/// `error.Timeout`).
fn disarmPhase(g: *PhaseGuard) bool {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    g.current_phase = .none;
    g.connection = null;
    g.deadline_ms = 0;
    return g.fired_phase != .none;
}

/// Sleep for `ms` milliseconds. Best-effort — signals can wake it
/// early, harmless here. Production binaries link libc and use
/// `nanosleep`; tests (which don't link libc in this project) fall
/// back to a wall-clock busy-spin so the function actually delays.
/// The mirror in `coding/modes/proxy.zig` only runs in production
/// where libc is always present.
fn nanoSleepMs(ms: u64) void {
    if (@import("builtin").link_libc) {
        const sec: i64 = @intCast(ms / 1000);
        const nsec: i64 = @intCast((ms % 1000) * std.time.ns_per_ms);
        const ts = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
        _ = std.c.nanosleep(&ts, null);
        return;
    }
    // No libc — busy-spin against the wall clock. CPU-hot but
    // correct; only the test binary takes this path.
    const start = stream_mod.nowMillis();
    const deadline = start + @as(i64, @intCast(ms));
    while (stream_mod.nowMillis() < deadline) {}
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method = .POST,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Method = enum { GET, POST };

pub const EventHandler = *const fn (
    userdata: ?*anyopaque,
    event: sse_mod.Event,
) EventHandlerError!void;

pub const EventHandlerError = error{
    Aborted,
    ProtocolViolation,
    OutOfMemory,
    Handler,
    Timeout,
};

// ─── SSE parse loop ───────────────────────────────────────────────────

/// Drive the SSE state machine against raw bytes. Returns when `bytes`
/// is exhausted, or as soon as a terminal condition fires (cancel,
/// handler error, event gap).
pub fn driveSseFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
) EventHandlerError!void {
    return driveSseFromBytesWithTimeouts(allocator, bytes, cancel, on_event, userdata, .{});
}

/// Same, with an explicit `event_gap_ms` deadline between successful
/// handler callbacks. Zero disables the gap check.
pub fn driveSseFromBytesWithTimeouts(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
    timeouts: Timeouts,
) EventHandlerError!void {
    var parser = sse_mod.Parser.init(allocator);
    defer parser.deinit();

    var i: usize = 0;
    const chunk: usize = 32;
    var last_event_ms: i64 = stream_mod.nowMillis();
    while (i < bytes.len) {
        if (cancel.isFired()) return EventHandlerError.Aborted;
        if (timeouts.event_gap_ms != 0) {
            const elapsed = stream_mod.nowMillis() - last_event_ms;
            if (elapsed > @as(i64, @intCast(timeouts.event_gap_ms))) {
                return EventHandlerError.Timeout;
            }
        }
        const end = @min(i + chunk, bytes.len);
        parser.feed(bytes[i..end]) catch |e| switch (e) {
            error.ProtocolViolation => return EventHandlerError.ProtocolViolation,
            error.OutOfMemory => return EventHandlerError.OutOfMemory,
        };
        while (true) {
            const ev = parser.next() catch |e| switch (e) {
                error.ProtocolViolation => return EventHandlerError.ProtocolViolation,
                error.OutOfMemory => return EventHandlerError.OutOfMemory,
            };
            if (ev == null) break;
            try on_event(userdata, ev.?);
            const after = stream_mod.nowMillis();
            if (timeouts.event_gap_ms != 0 and (after - last_event_ms) > @as(i64, @intCast(timeouts.event_gap_ms))) {
                return EventHandlerError.Timeout;
            }
            last_event_ms = after;
        }
        i = end;
    }
    if (try parser.flush()) |ev| try on_event(userdata, ev);
}

// ─── Full fetch + SSE ─────────────────────────────────────────────────

/// Full streaming POST + SSE parse — issues a request via `Client`
/// and feeds the response body into the parser, invoking `on_event` for
/// every parsed event.
///
/// Currently uses the buffered `Client.fetch` API (the whole body lands
/// in memory before parsing). `timeouts.event_gap_ms` is enforced
/// against the `on_event` callbacks; the other three timeout fields
/// are accepted but not yet enforced by the fetch — see the module
/// doc comment.
pub fn streamSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: Request,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
    timeouts: Timeouts,
) !void {
    var client = Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const method: std.http.Method = switch (req.method) {
        .GET => .GET,
        .POST => .POST,
    };

    const http_headers = try allocator.alloc(std.http.Header, req.headers.len);
    defer allocator.free(http_headers);
    for (req.headers, 0..) |h, i| http_headers[i] = .{ .name = h.name, .value = h.value };

    const result = client.fetch(.{
        .location = .{ .url = req.url },
        .method = method,
        .payload = if (req.body.len > 0) req.body else null,
        .response_writer = &body_writer.writer,
        .extra_headers = http_headers,
    }) catch |e| return mapHttpError(e);

    if (@intFromEnum(result.status) >= 400) return error.HttpErrorStatus;

    try driveSseFromBytesWithTimeouts(allocator, body_writer.written(), cancel, on_event, userdata, timeouts);
}

// ─── retry-wrapped fetch ─────────────────────────────────────────

const retry_mod = @import("retry.zig");

pub const FetchRetryCtx = struct {
    client: *Client,
    options: *Client.FetchOptions,
    /// Output slot — on success contains the FetchResult; on
    /// terminal failure contains the error from the final attempt.
    last_status: std.http.Status = .ok,
    last_err: ?anyerror = null,
    /// Response-body writer. `retry.run` calls `attempt_fn`
    /// repeatedly; we reset this writer at the top of each call so
    /// a failed attempt doesn't leak partial bytes into the next.
    body_writer: *std.Io.Writer.Allocating,
    /// Upper bound on whether retry is legal at all.  Per §F.1,
    /// once bytes have flowed to the caller we CANNOT retry — this
    /// flag flips after first successful status so the caller can
    /// gate us.
    bytes_flowed: *bool,
    /// Wall-clock deadline, milliseconds since epoch-zero. 0 → no
    /// deadline. `fetchAttempt` checks this before each attempt
    /// and short-circuits with `error.Timeout` if exceeded.
    deadline_ms: u64 = 0,
    start_ms: i64 = 0,
    /// §3.5 hooks (v1.7.2) — forwarded from `StreamOptions.hooks`.
    /// `on_payload` fires before each `client.fetch`; `on_response`
    /// fires after each attempt returns.
    hook_userdata: ?*anyopaque = null,
    on_payload: ?*const fn (userdata: ?*anyopaque, payload: []const u8) void = null,
    on_response: ?*const fn (userdata: ?*anyopaque, status: u16) void = null,
    /// v1.8.0 — full §G.4 phase budgets used by `fetchAttemptPhased`.
    /// `fetchAttempt` (the legacy single-shot path) only uses
    /// `deadline_ms` (= sum of phase budgets) for total-budget cuts.
    timeouts: Timeouts = .{},
    /// v1.8.0 — out-parameter for the per-phase tag on
    /// `error.Timeout`. `fetchAttemptPhased` writes this; the legacy
    /// `fetchAttempt` leaves it as-is.
    phase_info: ?*PhaseInfo = null,
    /// Allocator for duplicating the provider error message across
    /// retry attempts. Owned by the caller; freed by
    /// `fetchWithRetryAndTimeoutsAndHooksAndPhases` on exit.
    allocator: std.mem.Allocator,
    /// Preserved error message from the last HTTP 5xx/429 attempt,
    /// so transport-error exhaustion can surface the upstream cause
    /// rather than just "ConnectionResetByPeer". Dupe'd from
    /// `allocator`; freed below on termination or overwrite.
    last_error_message: ?[]const u8 = null,
};

/// Shared attempt callback used by `fetchWithRetry`. Classifies
/// the result into `retryable` / `terminal` / `success` per §F.1:
///   - HTTP 5xx → retryable
///   - HTTP 429 with `Retry-After` → retryable (hint)
///   - HTTP 4xx other → terminal
///   - Transport errors (ConnectionReset, Timeout, NetworkDown) → retryable
///   - Anything else → terminal
pub fn fetchAttempt(userdata: ?*anyopaque, attempt: u32) retry_mod.AttemptResult {
    _ = attempt;
    const ctx: *FetchRetryCtx = @ptrCast(@alignCast(userdata.?));

    // §G.4 wall-clock deadline check — short-circuit before
    // spending more time on a request that's already over
    // budget. `Timeout` classifies as terminal so `retry.run`
    // stops and bubbles up `error.DeadlineExceeded` via `last_err`.
    if (ctx.deadline_ms > 0 and deadlineExpired(stream_mod.nowMillis(), ctx.start_ms, ctx.deadline_ms)) {
        ctx.last_err = error.Timeout;
        return .{ .outcome = .terminal };
    }

    // Reset the body writer before each attempt so a 500 on call-1
    // doesn't leave garbage that a successful call-2 appends to.
    ctx.body_writer.clearRetainingCapacity();

    // §3.5 on_payload hook — fires before the outgoing request.
    if (ctx.on_payload) |hook| {
        const payload = ctx.options.payload orelse "";
        hook(ctx.hook_userdata, payload);
    }

    const result = ctx.client.fetch(ctx.options.*) catch |e| {
        ctx.last_err = e;
        return .{ .outcome = classifyTransport(e) };
    };
    ctx.last_status = result.status;
    ctx.last_err = null;

    // §3.5 on_response hook — fires after headers/body land.
    if (ctx.on_response) |hook| {
        hook(ctx.hook_userdata, @intFromEnum(result.status));
    }

    const status_code = @intFromEnum(result.status);
    if (status_code < 400) {
        ctx.bytes_flowed.* = true;
        return .{ .outcome = .success };
    }
    if (status_code >= 500 or status_code == 429) {
        // Retryable HTTP status. `Retry-After` parsing would live
        // here; for now the caller's policy.max_retry_delay_ms
        // bounds us.
        return .{ .outcome = .retryable };
    }
    return .{ .outcome = .terminal };
}

fn classifyTransport(e: anyerror) retry_mod.Outcome {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.HttpConnectionClosing,
        error.BrokenPipe,
        error.TlsInitializationFailed,
        error.HttpChunkTruncated,
        => .retryable,
        else => .terminal,
    };
}

/// v1.8.0 — phased attempt callback. Replaces `fetchAttempt`'s
/// single-shot `client.fetch(...)` with the three-phase
/// `connect → request+sendBody → receiveHead → readBody` flow,
/// each guarded by its own watchdog so a hung phase returns
/// promptly. Body reading still buffers (no streaming SSE parse
/// yet — post-1.0).
///
/// Per-phase timeouts come from `ctx.timeouts`. Setting any field
/// to 0 disables enforcement for that phase. The watchdog tags
/// `ctx.phase_info.?.timed_out_phase` on the way out.
pub fn fetchAttemptPhased(userdata: ?*anyopaque, attempt: u32) retry_mod.AttemptResult {
    _ = attempt;
    const ctx: *FetchRetryCtx = @ptrCast(@alignCast(userdata.?));

    // §G.4 wall-clock total-budget check — same short-circuit as
    // `fetchAttempt` so a request already over budget doesn't
    // start a new phase round.
    if (ctx.deadline_ms > 0 and deadlineExpired(stream_mod.nowMillis(), ctx.start_ms, ctx.deadline_ms)) {
        ctx.last_err = error.Timeout;
        return .{ .outcome = .terminal };
    }

    ctx.body_writer.clearRetainingCapacity();

    if (ctx.on_payload) |hook| {
        const payload = ctx.options.payload orelse "";
        hook(ctx.hook_userdata, payload);
    }

    // Spawn the watchdog up-front; it serves all three phases. We
    // hand it `io` from the client so closing the connection is
    // io-aware. `stop` flips at function exit (deferred) so the
    // thread joins cleanly on every return path.
    var guard: PhaseGuard = .{ .io = ctx.client.io };
    const wd_thread = std.Thread.spawn(.{}, watchdogLoop, .{&guard}) catch |e| {
        ctx.last_err = e;
        return .{ .outcome = .terminal };
    };
    defer {
        guard.stop.store(true, .release);
        wd_thread.join();
    }

    const result = fetchPhased(ctx, &guard) catch |e| {
        ctx.last_err = e;
        // If the watchdog killed a phase, surface the tag and
        // upgrade to `error.Timeout` (which `classifyTransport`
        // routes to `terminal`, stopping retries — connect-phase
        // timeouts ARE retryable in principle, but for v1.8.0 we
        // keep the conservative behavior: total-budget retry
        // already covers the "transient slow" case).
        if (guard.fired_phase != .none) {
            if (ctx.phase_info) |pi| pi.timed_out_phase = guard.fired_phase;
            ctx.last_err = error.Timeout;
            return .{ .outcome = .terminal };
        }
        return .{ .outcome = classifyTransport(e) };
    };
    ctx.last_status = result.status;
    ctx.last_err = null;

    if (ctx.on_response) |hook| {
        hook(ctx.hook_userdata, @intFromEnum(result.status));
    }

    const status_code = @intFromEnum(result.status);
    if (status_code < 400) {
        ctx.bytes_flowed.* = true;
        return .{ .outcome = .success };
    }
    if (status_code >= 500 or status_code == 429) {
        // Extract the provider error message from the response body
        // so retry logging can surface what actually went wrong
        // (e.g. "model overloaded") rather than just the code.
        // Free the previous attempt's message before overwriting.
        if (ctx.last_error_message) |prev| ctx.allocator.free(prev);
        ctx.last_error_message = extractErrorMessage(ctx.allocator, ctx.body_writer.written());
        log.log(.debug, "http", "retryable", "status={d} msg={?s}", .{ status_code, ctx.last_error_message });
        return .{ .outcome = .retryable, .message = ctx.last_error_message };
    }
    return .{ .outcome = .terminal };
}

/// Inner phased flow used by `fetchAttemptPhased`. Returns the
/// HTTP result on success, propagates whatever error the std.http
/// client surfaced on failure (the watchdog flag distinguishes
/// "we killed it" from "real network error" at the caller).
fn fetchPhased(
    ctx: *FetchRetryCtx,
    guard: *PhaseGuard,
) !Client.FetchResult {
    const opts = ctx.options.*;
    const uri = switch (opts.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    const method: std.http.Method = opts.method orelse
        if (opts.payload != null) .POST else .GET;

    // ── Phase 1: connect ──
    // Connect through `client.request` (it does CA-bundle setup +
    // `client.connect`). The watchdog tags but can't interrupt
    // (no connection handle exists yet); the OS-level connect
    // timeout still bounds it. Once `request` returns, we own a
    // connection and the next two phases get full interrupt.
    armPhase(guard, .connect, null, ctx.timeouts.connect_ms);
    var req = Client.request(ctx.client, method, uri, .{
        .redirect_behavior = opts.redirect_behavior orelse
            if (opts.payload == null) @enumFromInt(3) else .unhandled,
        .headers = opts.headers,
        .extra_headers = opts.extra_headers,
        .privileged_headers = opts.privileged_headers,
    }) catch |e| {
        if (disarmPhase(guard)) return error.Timeout;
        return e;
    };
    defer req.deinit();
    if (disarmPhase(guard)) return error.Timeout;

    // ── Phase 2: upload ──
    armPhase(guard, .upload, req.connection, ctx.timeouts.upload_ms);
    if (opts.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = req.sendBodyUnflushed(&.{}) catch |e| {
            if (disarmPhase(guard)) return error.Timeout;
            return e;
        };
        body.writer.writeAll(payload) catch |e| {
            if (disarmPhase(guard)) return error.Timeout;
            return e;
        };
        body.end() catch |e| {
            if (disarmPhase(guard)) return error.Timeout;
            return e;
        };
        req.connection.?.flush() catch |e| {
            if (disarmPhase(guard)) return error.Timeout;
            return e;
        };
    } else {
        req.sendBodiless() catch |e| {
            if (disarmPhase(guard)) return error.Timeout;
            return e;
        };
    }
    if (disarmPhase(guard)) return error.Timeout;

    // ── Phase 3: first byte (response head) ──
    const redirect_buffer: []u8 = if (opts.redirect_behavior == .unhandled) &.{} else opts.redirect_buffer orelse
        ctx.client.allocator.alloc(u8, 8 * 1024) catch |e| return e;
    defer if (opts.redirect_buffer == null and opts.redirect_behavior != .unhandled) ctx.client.allocator.free(redirect_buffer);

    armPhase(guard, .first_byte, req.connection, ctx.timeouts.first_byte_ms);
    var response = req.receiveHead(redirect_buffer) catch |e| {
        if (disarmPhase(guard)) return error.Timeout;
        return e;
    };
    if (disarmPhase(guard)) return error.Timeout;

    // ── Phase 4: body ──
    // No watchdog here — body reads are bounded by `event_gap_ms`
    // at the SSE layer (`driveSseFromBytes`). For non-SSE
    // responses, the response_writer's own pacing applies. True
    // streaming SSE parse is post-1.0 (§N.2 `io.concurrent`).
    //
    // Snapshot string fields from the head before initializing the
    // body reader: `Response.reader(...)` and
    // `Response.readerDecompressing(...)` both call
    // `head.invalidateStrings()`, which fills `content_type` (and the
    // other string slices) with `undefined` (the 0xaa pattern).
    // Reading them afterward — as the chunk-truncation tolerance check
    // needs to do — segfaults inside `startsWithIgnoreCase`.
    const content_type_snapshot = response.head.content_type;

    const response_writer = opts.response_writer orelse {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch {
            const body_err = response.bodyErr().?;
            if (toleratedChunkTruncation(body_err, content_type_snapshot)) {
                return .{ .status = response.head.status };
            }
            return body_err;
        };
        return .{ .status = response.head.status };
    };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => opts.decompress_buffer orelse ctx.client.allocator.alloc(u8, std.compress.zstd.default_window_len) catch |e| return e,
        .deflate, .gzip => opts.decompress_buffer orelse ctx.client.allocator.alloc(u8, std.compress.flate.max_window_len) catch |e| return e,
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (opts.decompress_buffer == null) switch (response.head.content_encoding) {
        .identity => {},
        .zstd, .deflate, .gzip => ctx.client.allocator.free(decompress_buffer),
        .compress => unreachable,
    };

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(response_writer) catch |e| switch (e) {
        error.ReadFailed => {
            const body_err = response.bodyErr().?;
            if (toleratedChunkTruncation(body_err, content_type_snapshot)) {
                // Bytes streamed before the truncation are already in
                // `response_writer`. SSE callers parse them via the
                // `[DONE]` sentinel; nothing meaningful was lost.
                return .{ .status = response.head.status };
            }
            return body_err;
        },
        else => return e,
    };

    return .{ .status = response.head.status };
}

/// Some upstream servers (notably Ollama-derived ones, and the
/// OpenAI-compatible gateway some self-hosters wrap them in) close
/// the TCP connection immediately after sending `data: [DONE]\n\n`
/// without writing the trailing `0\r\n\r\n` chunk-terminator that
/// HTTP/1.1 chunked transfer-encoding requires. Zig's std HTTP
/// reader correctly flags this as `HttpChunkTruncated`, but for an
/// SSE stream the truncation is benign — the application-level
/// terminator (`[DONE]`) is already in the buffer.
///
/// We tolerate the error only when the response was advertised as
/// `text/event-stream`. Real truncation on a normal JSON / binary
/// body is still an error.
fn toleratedChunkTruncation(err: anyerror, content_type: ?[]const u8) bool {
    if (err != error.HttpChunkTruncated) return false;
    const ct = content_type orelse return false;
    // Match `text/event-stream` regardless of trailing `; charset=...`
    // and case (RFC 7231 sec. 3.1.1.1 — media types are case-insensitive).
    return std.ascii.startsWithIgnoreCase(ct, "text/event-stream");
}

/// Drop-in replacement for `client.fetch` with §F.1 retry policy
/// baked in. Writes the response body into `body_writer`; returns
/// the final `FetchResult` on success, or propagates the last
/// error when all attempts fail.
///
/// Per §F.1 "no retry after first byte": once we've observed a
/// 2xx status on attempt N, we stop retrying. A 500 on attempt 1
/// followed by a 200 on attempt 2 is valid; a 200 followed by a
/// broken SSE stream is NOT retryable from this layer.
pub fn fetchWithRetry(
    client: *Client,
    options: Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
) !Client.FetchResult {
    return fetchWithRetryAndTimeouts(client, options, body_writer, cancel, policy, .{});
}

/// Same as `fetchWithRetry` but honors the §G.4 wall-clock deadline
/// derived from `timeouts.fetchDeadlineMs()`. Zero → unbounded.
/// When the deadline fires we return `error.Timeout` without
/// starting the next attempt. Per-phase (connect/upload/first-byte)
/// enforcement still requires streaming-reads migration; this
/// covers the coarser "total budget" case.
pub fn fetchWithRetryAndTimeouts(
    client: *Client,
    options: Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
    timeouts: Timeouts,
) !Client.FetchResult {
    return fetchWithRetryAndTimeoutsAndHooks(client, options, body_writer, cancel, policy, timeouts, .{});
}

/// §6.13 — heap-allocated context owned by `hooksFromOptionsWithRetry`.
/// Freed by `fetchWithRetryAndTimeoutsAndHooksAndPhases` via `owned_retry_ctx`.
/// Lives at module scope so the fetch function can reference its type for cleanup.
const StreamRetryCtx = struct {
    out: *stream_mod.Channel,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn callback(ud: ?*anyopaque, attempt: u32, max_attempts: u32, delay_ms: u32, reason: errors_mod.Code) void {
        const self: *StreamRetryCtx = @ptrCast(@alignCast(ud.?));
        self.out.push(self.io, .{ .provider_retry = .{
            .attempt = attempt,
            .max_attempts = max_attempts,
            .delay_ms = delay_ms,
            .reason = reason,
        } }) catch {};
    }
};

/// v1.7.2 — §3.5 hooks: fires `on_payload` before every attempt,
/// `on_response` after each one. When both hooks are null this is
/// byte-for-byte equivalent to `fetchWithRetryAndTimeouts`.
pub const Hooks = struct {
    userdata: ?*anyopaque = null,
    on_payload: ?*const fn (userdata: ?*anyopaque, payload: []const u8) void = null,
    on_response: ?*const fn (userdata: ?*anyopaque, status: u16) void = null,
    /// §6.13 — fired before each retry sleep with the 1-indexed
    /// attempt number, total allowed attempts, and the delay about
    /// to be slept. Wired into `Policy.on_retry`.
    on_retry: ?retry_mod.OnRetryFn = null,
    /// §6.13 — non-null only when set by `hooksFromOptionsWithRetry`.
    /// Owned by this Hooks value; freed by `fetchWithRetryAndTimeoutsAndHooksAndPhases`.
    owned_retry_ctx: ?*StreamRetryCtx = null,
};

/// v1.3.0 R5 — pull the hooks out of a `StreamOptions` (from
/// registry.zig). Factored so every provider's `streamFn`
/// doesn't spell the three-field copy out inline.
pub fn hooksFromOptions(opts: anytype) Hooks {
    return .{
        .userdata = opts.hooks.userdata,
        .on_payload = opts.hooks.on_payload,
        .on_response = opts.hooks.on_response,
        .on_retry = opts.hooks.on_retry,
    };
}

/// §6.13 — same as `hooksFromOptions` but also wires `on_retry` to
/// push a `provider_retry` event onto `ctx.out` before each retry
/// sleep. Providers that use the HTTP fetch path call this instead
/// of `hooksFromOptions` to get retry visibility for free.
/// The allocated `StreamRetryCtx` is owned by the returned `Hooks.owned_retry_ctx`
/// and freed by `fetchWithRetryAndTimeoutsAndHooksAndPhases` after the fetch.
pub fn hooksFromOptionsWithRetry(ctx: anytype) Hooks {
    var hooks = hooksFromOptions(ctx.options);
    const rc = ctx.allocator.create(StreamRetryCtx) catch return hooks;
    rc.* = .{ .out = ctx.out, .io = ctx.io, .allocator = ctx.allocator };
    hooks.owned_retry_ctx = rc;
    hooks.on_retry = StreamRetryCtx.callback;
    return hooks;
}

/// v1.3.0 R5 — push the canonical `.start` → `error_ev(...)` →
/// close-channel sequence when a provider's HTTP fetch fails.
///
/// Branches on `err`:
///   - `error.Timeout` → `code = .timeout`, message names the
///     phase (when `phase_info` is provided) and includes the
///     budget that was exceeded so the user can tune the
///     matching `--<phase>-timeout-ms` flag. This is the typical
///     symptom when running against slow local LLMs (Ollama on
///     CPU, vLLM cold cache).
///   - everything else → `code = .transport`, `http error: <name>`.
pub fn reportTransportError(
    out: *stream_mod.Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    err: anyerror,
) !void {
    return reportTransportErrorWithPhase(out, io, allocator, err, null, null, null);
}

/// Variant that surfaces phase + budget + optional provider error
/// message. Pass `null` for any parameter you don't have access to.
pub fn reportTransportErrorWithPhase(
    out: *stream_mod.Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    err: anyerror,
    phase: ?PhaseTag,
    timeouts: ?Timeouts,
    /// Optional upstream error message (e.g. "model overloaded" from
    /// a prior 5xx attempt). Included in the error when available.
    provider_message: ?[]const u8,
) !void {
    try out.push(io, .start);
    const Code = @import("errors.zig").Code;
    if (err == error.Timeout) {
        const message = try formatTimeoutMessage(allocator, phase, timeouts);
        out.closeWithFinal(io, .{ .error_ev = .{ .code = Code.timeout, .message = message } });
        return;
    }
    const msg = if (provider_message) |pm|
        try std.fmt.allocPrint(allocator, "http error: {s} ({s})", .{ @errorName(err), pm })
    else
        try std.fmt.allocPrint(allocator, "http error: {s}", .{@errorName(err)});
    out.closeWithFinal(io, .{ .error_ev = .{
        .code = Code.transport,
        .message = msg,
    } });
}

fn formatTimeoutMessage(
    allocator: std.mem.Allocator,
    phase: ?PhaseTag,
    timeouts: ?Timeouts,
) ![]u8 {
    const phase_name: []const u8 = if (phase) |p| switch (p) {
        .connect => "connect",
        .upload => "upload",
        .first_byte => "first-byte",
        .none => "request",
    } else "request";
    const flag_name: []const u8 = if (phase) |p| switch (p) {
        .connect => "--connect-timeout-ms",
        .upload => "--upload-timeout-ms",
        .first_byte => "--first-byte-timeout-ms",
        .none => "--first-byte-timeout-ms",
    } else "--first-byte-timeout-ms";
    const budget_ms: ?u32 = if (timeouts) |t| switch (phase orelse .none) {
        .connect => t.connect_ms,
        .upload => t.upload_ms,
        .first_byte => t.first_byte_ms,
        .none => null,
    } else null;
    if (budget_ms) |ms| {
        return std.fmt.allocPrint(
            allocator,
            "{s} timeout: provider didn't respond within {d}ms; raise {s} (or set FRANKY_FIRST_BYTE_TIMEOUT_MS) for slow models",
            .{ phase_name, ms, flag_name },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} timeout: provider didn't respond in time; raise {s} (or set FRANKY_FIRST_BYTE_TIMEOUT_MS) for slow models",
        .{ phase_name, flag_name },
    );
}

/// Extract the human-readable error message from a provider response
/// body. Returns the dupe'd `error.message` field (owned by
/// `allocator`), or null when the body is empty or unparseable.
///
/// The caller is responsible for freeing the returned string.
fn extractErrorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    if (body.len == 0) return null;
    // We're in the retry loop — don't know the provider, but all
    // providers we support share the `{"error":{"message":"..."}}` shape.
    const ext = err_map.extract(allocator, .openai, body);
    // extract dups both `kind` and `message`; we only need message.
    if (ext.kind) |k| allocator.free(k);
    return ext.message;
}

pub fn fetchWithRetryAndTimeoutsAndHooks(
    client: *Client,
    options: Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
    timeouts: Timeouts,
    hooks: Hooks,
) !Client.FetchResult {
    return fetchWithRetryAndTimeoutsAndHooksAndPhases(
        client,
        options,
        body_writer,
        cancel,
        policy,
        timeouts,
        hooks,
        null,
    );
}

/// v1.8.0 — adds the optional `*PhaseInfo` out-parameter so callers
/// can read which §G.4 phase fired on `error.Timeout`. Routes
/// through `fetchAttemptPhased`; legacy `fetchAttempt` (single-shot
/// `client.fetch`) remains for backward compat but is no longer
/// reachable through any of the public entry points.
pub fn fetchWithRetryAndTimeoutsAndHooksAndPhases(
    client: *Client,
    options: Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
    timeouts: Timeouts,
    hooks: Hooks,
    phase_info: ?*PhaseInfo,
) !Client.FetchResult {
    var opts_copy = options;
    opts_copy.response_writer = &body_writer.writer;

    const deadline_ms: u64 = timeouts.fetchDeadlineMs();
    const start_ms: i64 = if (deadline_ms > 0) stream_mod.nowMillis() else 0;

    var bytes_flowed = false;
    var ctx: FetchRetryCtx = .{
        .client = client,
        .options = &opts_copy,
        .body_writer = body_writer,
        .bytes_flowed = &bytes_flowed,
        .deadline_ms = deadline_ms,
        .start_ms = start_ms,
        .hook_userdata = hooks.userdata,
        .on_payload = hooks.on_payload,
        .on_response = hooks.on_response,
        .timeouts = timeouts,
        .phase_info = phase_info,
        .allocator = client.allocator,
    };

    defer if (hooks.owned_retry_ctx) |rc| rc.allocator.destroy(rc);

    var effective_policy = policy;
    effective_policy.on_retry = if (hooks.on_retry) |func| .{
        .ctx = hooks.owned_retry_ctx,
        .func = func,
    } else null;

    const result = retry_mod.run(
        effective_policy,
        cancel,
        defaultSleep,
        null,
        fetchAttemptPhased,
        @ptrCast(&ctx),
    );

    switch (result.outcome) {
        .success => {
            if (ctx.last_error_message) |m| ctx.allocator.free(m);
            return .{ .status = ctx.last_status };
        },
        .terminal => {
            if (ctx.last_err != null) {
                // Transport error — transfer the preserved error message
                // to phase_info so the provider catch block can format
                // and free it. Use ctx.last_error_message directly (not
                // result.last_message) because retry.run's cancel path
                // leaves result.last_message null.
                if (phase_info) |pi| {
                    pi.last_error_message = ctx.last_error_message;
                    ctx.last_error_message = null;
                } else {
                    // No phase_info to hand ownership to; free here.
                    if (ctx.last_error_message) |m| ctx.allocator.free(m);
                    ctx.last_error_message = null;
                }
                return ctx.last_err.?;
            }
            // HTTP-status exhaustion — provider uses mapError on the
            // final body instead. Free the preserved message.
            if (ctx.last_error_message) |m| ctx.allocator.free(m);
            ctx.last_error_message = null;
            if (phase_info) |pi| pi.last_error_message = null;
            return .{ .status = ctx.last_status };
        },
        .retryable => unreachable,
    }
}

/// Check whether the wall-clock deadline has expired. Pure so
/// tests can drive it with a fixed "now".
pub fn deadlineExpired(now_ms: i64, start_ms: i64, deadline_ms: u64) bool {
    if (deadline_ms == 0) return false;
    const elapsed = now_ms - start_ms;
    return elapsed >= @as(i64, @intCast(deadline_ms));
}

fn defaultSleep(_: ?*anyopaque, ms: u32) void {
    nanoSleepMs(ms);
}

/// Narrow std.http client errors into the spec's canonical codes.
/// Used by the provider layer to produce `ErrorDetails`.
pub fn mapHttpError(e: anyerror) errors_mod.AgentError {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.UnknownHostName,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.TemporaryNameServerFailure,
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        error.HttpChunkTruncated,
        => error.Transport,
        error.HttpErrorStatus => error.Transient,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Internal,
    };
}

// ─── v1.16.1 — opt-in HTTP trace files ─────────────────────────

/// Process-global sequence counter so concurrent provider calls
/// land in distinct files even when they fire in the same
/// millisecond.
// 32-bit (not u64) so atomic ops work on i386 / 32-bit ARM targets
// where 64-bit atomic RMW isn't a single-instruction primitive.
// 4 billion traces per process lifetime is plenty for a diagnostic.
var trace_seq: std.atomic.Value(u32) = .init(0);

/// Write a full request/response trace file when `dir` is non-null.
/// No-op when null. Best-effort: any IO error is swallowed (a trace
/// failure must never break the live fetch path). Filename:
/// `<unix_ms>-<seq>-<provider>.txt`.
///
/// v1.29.0 — returns an allocated `<unix_ms>-<seq>` "trace id" on
/// success so callers can stamp it into `Message.diagnostics`. The
/// caller owns the slice and must `allocator.free()` it. Returns
/// `null` when `dir` is null OR any IO step fails.
///
/// File format (plain text, easy to grep / diff):
///
///     === franky http trace ===
///     ts: <iso8601-ms>
///     seq: <u64>
///     provider: <tag>
///     url: <full URL>
///     method: <GET|POST|...>
///     status: <code>
///     request_body_bytes: <n>
///     response_body_bytes: <n>
///
///     --- request body ---
///     <full request body, verbatim>
///
///     --- response body ---
///     <full response body, verbatim>
///
/// The response body is written **without truncation** — debugging
/// a 5 MB reasoning reply is the use case this exists for. Caller
/// keeps the trace dir on its toes (no rotation in this revision).
pub fn writeTraceFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: ?[]const u8,
    provider: []const u8,
    url: []const u8,
    method: []const u8,
    status: u16,
    request_body: []const u8,
    response_body: []const u8,
) ?[]u8 {
    const trace_dir = dir orelse return null;
    const seq = trace_seq.fetchAdd(1, .monotonic);
    const ts_ms = stream_mod.nowMillis();

    // mkdir -p the trace dir. Anything other than "already exists"
    // is a soft fail — give up on this trace silently.
    std.Io.Dir.cwd().createDirPath(io, trace_dir) catch return null;

    const path = std.fmt.allocPrint(
        allocator,
        "{s}/{d}-{d:0>4}-{s}.txt",
        .{ trace_dir, ts_ms, seq, provider },
    ) catch return null;
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    const out = &w.interface;

    const header = std.fmt.allocPrint(
        allocator,
        \\=== franky http trace ===
        \\ts_ms: {d}
        \\seq: {d}
        \\provider: {s}
        \\url: {s}
        \\method: {s}
        \\status: {d}
        \\request_body_bytes: {d}
        \\response_body_bytes: {d}
        \\
        \\--- request body ---
        \\
    ,
        .{ ts_ms, seq, provider, url, method, status, request_body.len, response_body.len },
    ) catch return null;
    defer allocator.free(header);

    out.writeAll(header) catch return null;
    out.writeAll(request_body) catch return null;
    out.writeAll("\n\n--- response body ---\n") catch return null;
    out.writeAll(response_body) catch return null;
    out.flush() catch return null;

    // Caller-owned trace id matching the filename stem.
    return std.fmt.allocPrint(allocator, "{d}-{d:0>4}", .{ ts_ms, seq }) catch null;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "classifyTransport: connection resets are retryable" {
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionResetByPeer));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionRefused));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionTimedOut));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.BrokenPipe));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.TlsInitializationFailed));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.HttpChunkTruncated));
}

test "deadlineExpired: zero deadline means never" {
    try testing.expect(!deadlineExpired(10_000, 0, 0));
    try testing.expect(!deadlineExpired(std.math.maxInt(i64), 0, 0));
}

test "deadlineExpired: elapsed < deadline → false" {
    try testing.expect(!deadlineExpired(500, 0, 1000));
    try testing.expect(!deadlineExpired(999, 0, 1000));
}

test "deadlineExpired: elapsed >= deadline → true" {
    try testing.expect(deadlineExpired(1000, 0, 1000));
    try testing.expect(deadlineExpired(1500, 0, 1000));
}

test "deadlineExpired: start offset is respected" {
    try testing.expect(!deadlineExpired(5500, 5000, 1000));
    try testing.expect(deadlineExpired(6000, 5000, 1000));
}

test "classifyTransport: unknown errors are terminal" {
    try testing.expectEqual(retry_mod.Outcome.terminal, classifyTransport(error.OutOfMemory));
    try testing.expectEqual(retry_mod.Outcome.terminal, classifyTransport(error.CertificateBundleLoadFailure));
}

test "Timeouts.fetchDeadlineMs sums the three request-phase fields" {
    const t: Timeouts = .{ .connect_ms = 1, .upload_ms = 2, .first_byte_ms = 4, .event_gap_ms = 8 };
    try testing.expectEqual(@as(u64, 7), t.fetchDeadlineMs());
}

test "Timeouts: connect_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 100, .upload_ms = 0, .first_byte_ms = 0 };
    const b: Timeouts = .{ .connect_ms = 500, .upload_ms = 0, .first_byte_ms = 0 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts: upload_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 0, .upload_ms = 100, .first_byte_ms = 0 };
    const b: Timeouts = .{ .connect_ms = 0, .upload_ms = 500, .first_byte_ms = 0 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts: first_byte_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 0, .upload_ms = 0, .first_byte_ms = 100 };
    const b: Timeouts = .{ .connect_ms = 0, .upload_ms = 0, .first_byte_ms = 500 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts defaults match §G.4 (10s / 120s / 30s / 60s)" {
    const t: Timeouts = .{};
    try testing.expectEqual(@as(u32, 10_000), t.connect_ms);
    try testing.expectEqual(@as(u32, 120_000), t.upload_ms);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
    try testing.expectEqual(@as(u32, 60_000), t.event_gap_ms);
}

test "formatTimeoutMessage: first_byte phase names the right flag + budget" {
    const gpa = testing.allocator;
    const msg = try formatTimeoutMessage(gpa, .first_byte, .{ .first_byte_ms = 30_000 });
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "first-byte timeout") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "30000ms") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "--first-byte-timeout-ms") != null);
}

test "formatTimeoutMessage: connect phase names connect flag" {
    const gpa = testing.allocator;
    const msg = try formatTimeoutMessage(gpa, .connect, .{ .connect_ms = 5_000 });
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "connect timeout") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "--connect-timeout-ms") != null);
}

test "formatTimeoutMessage: null phase falls back to generic request wording" {
    const gpa = testing.allocator;
    const msg = try formatTimeoutMessage(gpa, null, null);
    defer gpa.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "request timeout") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "FRANKY_FIRST_BYTE_TIMEOUT_MS") != null);
}

test "reportTransportErrorWithPhase: error.Timeout produces code=.timeout" {
    const gpa = testing.allocator;
    var ch = try stream_mod.Channel.init(gpa, 8);
    defer ch.deinit();
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    try reportTransportErrorWithPhase(
        &ch,
        io,
        gpa,
        error.Timeout,
        .first_byte,
        .{ .first_byte_ms = 42_000 },
        null,
    );

    var saw_timeout = false;
    var saw_message = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .error_ev => |d| {
                if (d.code == .timeout) saw_timeout = true;
                if (std.mem.indexOf(u8, d.message, "42000ms") != null) saw_message = true;
            },
            else => {},
        }
        ev.deinit(gpa);
    }
    try testing.expect(saw_timeout);
    try testing.expect(saw_message);
}

test "reportTransportErrorWithPhase: non-timeout keeps legacy transport code" {
    const gpa = testing.allocator;
    var ch = try stream_mod.Channel.init(gpa, 8);
    defer ch.deinit();
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    try reportTransportErrorWithPhase(&ch, io, gpa, error.ConnectionRefused, null, null, null);

    var saw_transport = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .error_ev => |d| if (d.code == .transport) {
                saw_transport = true;
                try testing.expect(std.mem.indexOf(u8, d.message, "http error: ConnectionRefused") != null);
            },
            else => {},
        }
        ev.deinit(gpa);
    }
    try testing.expect(saw_transport);
}

test "driveSseFromBytes parses synthetic Anthropic-shaped events" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};

    const input =
        "event: message_start\ndata: {\"message\":{\"id\":\"msg_1\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "event: message_stop\ndata: {}\n\n";

    const Ctx = struct {
        count: u32 = 0,
        last_event: [64]u8 = @splat(0),
        last_event_len: usize = 0,

        fn onEv(ud: ?*anyopaque, ev: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.count += 1;
            if (ev.event) |name| {
                const n = @min(name.len, self.last_event.len);
                @memcpy(self.last_event[0..n], name[0..n]);
                self.last_event_len = n;
            }
        }
    };
    var ctx = Ctx{};

    try driveSseFromBytes(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx));
    try testing.expectEqual(@as(u32, 3), ctx.count);
    try testing.expectEqualStrings("message_stop", ctx.last_event[0..ctx.last_event_len]);
}

test "driveSseFromBytes honors cancel" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};
    cancel.fire();

    const input = "event: foo\ndata: {}\n\n";
    const Ctx = struct {
        count: u32 = 0,
        fn onEv(ud: ?*anyopaque, _: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.count += 1;
        }
    };
    var ctx = Ctx{};

    const r = driveSseFromBytes(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx));
    try testing.expectError(EventHandlerError.Aborted, r);
}

test "driveSseFromBytesWithTimeouts fires Timeout when handler stalls past event_gap_ms" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};

    const input =
        "event: a\ndata: {}\n\n" ++
        "event: b\ndata: {}\n\n";

    const Ctx = struct {
        calls: u32 = 0,
        fn onEv(ud: ?*anyopaque, _: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            if (self.calls == 1) {
                // Stall for 80 ms to trigger the event_gap_ms=20 timeout.
                // `nanoSleepMs` uses `std.c.nanosleep` (the test binary
                // links libc), so no busy-polling against the wall clock.
                nanoSleepMs(80);
            }
        }
    };
    var ctx = Ctx{};

    const r = driveSseFromBytesWithTimeouts(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx), .{ .event_gap_ms = 20 });
    try testing.expectError(EventHandlerError.Timeout, r);
}

// ─── §G.4 per-phase enforcement tests (v1.8.0) ──────────────────
//
// Each test stands up a tiny HTTP-ish server on a loopback port
// that's deliberately slow (or completely silent) at one phase
// boundary. The client is configured with a tight phase budget;
// we expect `error.Timeout` and the matching `PhaseTag` in the
// out-parameter `PhaseInfo`.

const test_h = @import("../test_helpers.zig");

const StallPhase = enum {
    none,
    first_byte,
    /// Replies with a chunked `text/event-stream` body, sends one
    /// well-formed chunk, then closes the TCP connection without
    /// the trailing `0\r\n\r\n` terminator. Used to reproduce the
    /// Ollama-style truncation that `toleratedChunkTruncation` is
    /// supposed to absorb.
    chunk_truncate_sse,
};

const StallServer = struct {
    server: std.Io.net.Server,
    port: u16,
    /// Phase the server stalls at: any read past this point hangs.
    stall_at: StallPhase,
    /// How long the server thread sleeps before responding (only
    /// relevant for stall_at != .none).
    stall_ms: u64,
    /// Stop signal — flipped by the test before deinit so the
    /// server thread exits its accept loop cleanly.
    stop: std.atomic.Value(bool) = .init(false),
    io: std.Io,
};

fn stallServerLoop(s: *StallServer) void {
    var stream = s.server.accept(s.io) catch return;
    defer stream.close(s.io);

    // Drain the request bytes. Real HTTP request ends with
    // `\r\n\r\n`. We don't bother parsing — just read until the
    // peer indicates EOF or until we've seen the header
    // terminator. This unblocks the client's upload phase.
    var sink: [4096]u8 = undefined;
    var r = stream.reader(s.io, &.{});
    var saw_term = false;
    var seen: usize = 0;
    while (!saw_term) {
        var vecs: [1][]u8 = .{&sink};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        seen += n;
        // Look for "\r\n\r\n" anywhere — close enough for a
        // well-formed POST since headers come before body for
        // small bodies.
        if (std.mem.indexOf(u8, sink[0..@min(n, sink.len)], "\r\n\r\n") != null) saw_term = true;
        if (seen > 16 * 1024) break;
    }

    switch (s.stall_at) {
        .first_byte => {
            nanoSleepMs(s.stall_ms);
            const reply =
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(s.io, &wbuf);
            w.interface.writeAll(reply) catch {};
            w.interface.flush() catch {};
        },
        .none => {
            const reply =
                "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(s.io, &wbuf);
            w.interface.writeAll(reply) catch {};
            w.interface.flush() catch {};
        },
        .chunk_truncate_sse => {
            // Chunked SSE reply with one valid 14-byte chunk
            // (`data: [DONE]\n\n`) and no terminator chunk — the
            // connection-close *is* the end-of-body, which std.http
            // surfaces as `error.HttpChunkTruncated`.
            const reply =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "e\r\ndata: [DONE]\n\n\r\n";
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(s.io, &wbuf);
            w.interface.writeAll(reply) catch {};
            w.interface.flush() catch {};
        },
    }
}

fn bindStallServer(io: std.Io, stall_at: StallPhase, stall_ms: u64) ?StallServer {
    const from: u16 = 18950;
    const to: u16 = 18999;
    var p = from;
    while (p < to) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 4,
            .reuse_address = true,
        }) catch continue;
        return .{
            .server = server,
            .port = p,
            .stall_at = stall_at,
            .stall_ms = stall_ms,
            .io = io,
        };
    }
    return null;
}

test "fetchPhased: happy path keeps PhaseInfo at .none" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindStallServer(io, .none, 0) orelse return;
    defer s.server.deinit(io);
    const server_thread = try std.Thread.spawn(.{}, stallServerLoop, .{&s});
    defer server_thread.join();

    var client = Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var bw = std.Io.Writer.Allocating.init(gpa);
    defer bw.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(url);

    var cancel: stream_mod.Cancel = .{};
    var pi: PhaseInfo = .{};
    const result = try fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{ .location = .{ .url = url }, .method = .GET },
        &bw,
        &cancel,
        .{ .max_retries = 0 },
        .{ .connect_ms = 5_000, .upload_ms = 5_000, .first_byte_ms = 5_000 },
        .{},
        &pi,
    );
    try testing.expectEqual(@as(u16, 200), @intFromEnum(result.status));
    try testing.expectEqual(PhaseTag.none, pi.timed_out_phase);
}

test "fetchPhased: first_byte phase fires when server stalls past budget" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Server reads the request then sleeps 1500 ms. Client's
    // first_byte budget is 200 ms — watchdog should fire well
    // before the server replies.
    var s = bindStallServer(io, .first_byte, 1500) orelse return;
    defer s.server.deinit(io);
    const server_thread = try std.Thread.spawn(.{}, stallServerLoop, .{&s});
    defer server_thread.join();

    var client = Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var bw = std.Io.Writer.Allocating.init(gpa);
    defer bw.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(url);

    var cancel: stream_mod.Cancel = .{};
    var pi: PhaseInfo = .{};
    const t0 = stream_mod.nowMillis();
    const r = fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{ .location = .{ .url = url }, .method = .GET },
        &bw,
        &cancel,
        .{ .max_retries = 0 },
        .{ .connect_ms = 5_000, .upload_ms = 5_000, .first_byte_ms = 200 },
        .{},
        &pi,
    );
    const elapsed = stream_mod.nowMillis() - t0;
    try testing.expectError(error.Timeout, r);
    try testing.expectEqual(PhaseTag.first_byte, pi.timed_out_phase);
    // Watchdog poll is 50ms, budget is 200ms — must fire well
    // before the server's 1500ms reply. Allow generous slack.
    try testing.expect(elapsed < 1200);
}

test "fetchPhased: PhaseTag.label returns canonical phase names" {
    try testing.expectEqualStrings("none", PhaseTag.none.label());
    try testing.expectEqualStrings("connect", PhaseTag.connect.label());
    try testing.expectEqualStrings("upload", PhaseTag.upload.label());
    try testing.expectEqualStrings("first_byte", PhaseTag.first_byte.label());
}

test "toleratedChunkTruncation: only HttpChunkTruncated on SSE is tolerated" {
    // Tolerated: HttpChunkTruncated + SSE content-type.
    try testing.expect(toleratedChunkTruncation(error.HttpChunkTruncated, "text/event-stream"));
    try testing.expect(toleratedChunkTruncation(error.HttpChunkTruncated, "text/event-stream; charset=utf-8"));
    try testing.expect(toleratedChunkTruncation(error.HttpChunkTruncated, "Text/Event-Stream"));

    // Not tolerated: real truncation on a JSON / unknown / missing content-type.
    try testing.expect(!toleratedChunkTruncation(error.HttpChunkTruncated, "application/json"));
    try testing.expect(!toleratedChunkTruncation(error.HttpChunkTruncated, "text/plain"));
    try testing.expect(!toleratedChunkTruncation(error.HttpChunkTruncated, null));

    // Not tolerated: any other error class, even on SSE.
    try testing.expect(!toleratedChunkTruncation(error.ConnectionResetByPeer, "text/event-stream"));
    try testing.expect(!toleratedChunkTruncation(error.HttpChunkInvalid, "text/event-stream"));
}

// Regression: the chunk-truncation tolerance check used to read
// `response.head.content_type` *after* `response.readerDecompressing(...)`,
// which calls `head.invalidateStrings()` and fills the slice with
// `undefined` (the 0xaa pattern). On a real Ollama-style truncation the
// resulting `startsWithIgnoreCase` call segfaulted at 0xaaaaaaaaaaaaaaaa.
// This test drives a chunked SSE response that closes without the
// terminator chunk; the fix snapshots `content_type` before any reader
// init, so the truncation must be tolerated and the call must succeed.
test "fetchPhased: tolerates chunk-truncated SSE without segfaulting on invalidated head strings" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindStallServer(io, .chunk_truncate_sse, 0) orelse return;
    defer s.server.deinit(io);
    const server_thread = try std.Thread.spawn(.{}, stallServerLoop, .{&s});
    defer server_thread.join();

    var client = Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var bw = std.Io.Writer.Allocating.init(gpa);
    defer bw.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(url);

    var cancel: stream_mod.Cancel = .{};
    var pi: PhaseInfo = .{};
    const result = try fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{ .location = .{ .url = url }, .method = .GET },
        &bw,
        &cancel,
        .{ .max_retries = 0 },
        .{ .connect_ms = 5_000, .upload_ms = 5_000, .first_byte_ms = 5_000 },
        .{},
        &pi,
    );

    try testing.expectEqual(@as(u16, 200), @intFromEnum(result.status));
    // The pre-truncation chunk bytes must have been delivered to the
    // body writer — SSE callers parse them via the `[DONE]` sentinel.
    try testing.expectEqualStrings("data: [DONE]\n\n", bw.written());
}

// ─── v1.16.1 — writeTraceFile tests ────────────────────────────

test "writeTraceFile: null dir is a no-op" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    // Just verify it doesn't crash and doesn't error. Null dir → null trace_id.
    const tid = writeTraceFile(testing.allocator, io, null, "x", "http://x", "POST", 200, "req", "resp");
    try testing.expect(tid == null);
}

test "writeTraceFile: writes a file with header + bodies, mkdir-p semantics" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Use a unique dir under /tmp so the trace files don't collide
    // with anything else (and we can clean up afterwards).
    const ts = stream_mod.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-trace-test-{d}/nested", .{ts});
    defer gpa.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const tid = writeTraceFile(
        gpa,
        io,
        dir_path,
        "anthropic",
        "https://api.anthropic.com/v1/messages",
        "POST",
        200,
        "{\"hello\":\"req\"}",
        "data: {\"hello\":\"resp\"}\n\n",
    );
    if (tid) |s| gpa.free(s);
    try testing.expect(tid != null);

    // Read the directory and find the one file we wrote.
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        std.debug.print("openDir failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer dir.close(io);

    var it = dir.iterate();
    const entry = (try it.next(io)) orelse return error.NoTraceFileWritten;
    try testing.expect(std.mem.endsWith(u8, entry.name, "-anthropic.txt"));

    // Read the file back and check the structure.
    var f = try dir.openFile(io, entry.name, .{});
    defer f.close(io);
    var read_buf: std.ArrayList(u8) = .empty;
    defer read_buf.deinit(gpa);
    var rb: [1024]u8 = undefined;
    var r = f.reader(io, &rb);
    var rbuf: [1024]u8 = undefined;
    while (true) {
        var vecs: [1][]u8 = .{&rbuf};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        try read_buf.appendSlice(gpa, rbuf[0..n]);
    }
    const contents = read_buf.items;
    try testing.expect(std.mem.indexOf(u8, contents, "=== franky http trace ===") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "provider: anthropic") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "url: https://api.anthropic.com/v1/messages") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "method: POST") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "status: 200") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "{\"hello\":\"req\"}") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "{\"hello\":\"resp\"}") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "--- request body ---") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "--- response body ---") != null);
}

test "writeTraceFile: monotonic seq across concurrent calls in same ms" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const ts = stream_mod.nowMillis();
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/franky-trace-seq-{d}", .{ts});
    defer gpa.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const tid = writeTraceFile(gpa, io, dir_path, "test", "http://x", "GET", 200, "req", "resp");
        if (tid) |s| gpa.free(s);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 5), count);
}

// ─── v1.29.7 — proxy-arena lifetime regression tests ────────────

test "setupClientFromEnv: returns ArenaAllocator that frees Proxy on deinit (no leak)" {
    // Pre-v1.29.7, this exercise leaked ~100B per call (Proxy
    // struct + duped host string). The test allocator's leak
    // detector would flag those leaks at scope exit. The fix:
    // setupClientFromEnv returns the arena, caller defers it
    // alongside client.deinit, all Proxy allocations get freed.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("https_proxy", "http://proxy.example.com:3128");
    try env_map.put("http_proxy", "http://proxy.example.com:3128");

    {
        var client = Client{ .allocator = gpa, .io = io };
        var proxy_arena = try setupClientFromEnv(&client, gpa, &env_map);
        defer {
            client.deinit();
            proxy_arena.deinit();
        }

        // Both proxy fields populated.
        try testing.expect(client.http_proxy != null);
        try testing.expect(client.https_proxy != null);
        try testing.expectEqual(@as(u16, 3128), client.http_proxy.?.port);
    }
    // Scope exited cleanly. testing.allocator's leak detector
    // would fire at process exit if any Proxy alloc survived;
    // running this in `zig build test` is the assertion.
}

test "setupClientFromEnv: empty environ → empty arena that still deinits cleanly" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    // No proxy envs set.

    var client = Client{ .allocator = gpa, .io = io };
    var proxy_arena = try setupClientFromEnv(&client, gpa, &env_map);
    defer {
        client.deinit();
        proxy_arena.deinit();
    }

    // No proxy configured.
    try testing.expect(client.http_proxy == null);
    try testing.expect(client.https_proxy == null);
    // Arena deinit is still well-defined on the empty case.
}
