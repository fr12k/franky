//! Google Vertex AI provider — §A.5 + §Q.4.
//!
//! Shares Gemini's wire format (see `google_gemini.zig` for the body
//! builder + SSE driver). The delta is in transport:
//!
//!   * Endpoint host: `{region}-aiplatform.googleapis.com` with the
//!     model path rooted at `/v1/projects/{project}/locations/{region}/
//!     publishers/google/models/{model}:streamGenerateContent`.
//!   * Auth: `Authorization: Bearer <access-token>` (from a
//!     service-account JWT exchange performed externally) instead
//!     of `?key=API_KEY`. This provider accepts a pre-minted access
//!     token through `options.auth_token` or `VERTEX_ACCESS_TOKEN` /
//!     `GOOGLE_CLOUD_ACCESS_TOKEN` env vars (resolved in print mode).
//!
//! `project` and `region` come from `options.base_url` when the
//! caller supplies a full URL; otherwise we default to
//! `VERTEX_PROJECT` / `VERTEX_REGION` (resolved upstream).
//!
//! Registers under api tag `google-vertex`.

const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const stream_mod = @import("../stream.zig");
const channel_mod = @import("../channel.zig");
const registry_mod = @import("../registry.zig");
const http_mod = @import("../http.zig");
const log = @import("../log.zig");
const gemini = @import("google_gemini.zig");

const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const default_region: []const u8 = "us-central1";

/// Wire format is identical to Gemini's public API — re-export for
/// discoverability + tests.
pub const buildRequestJson = gemini.buildRequestJson;
pub const runFromSse = gemini.runFromSse;
pub const runFromSseWithTrace = gemini.runFromSseWithTrace;

/// Build the Vertex endpoint path. `base` is the host (either
/// caller-supplied or defaulted). No-op validation — malformed URLs
/// surface as a transport error on the fetch.
pub fn buildEndpoint(
    allocator: std.mem.Allocator,
    project: []const u8,
    region: []const u8,
    model_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse",
        .{ region, project, region, model_id },
    );
}

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const credential: []const u8 = ctx.options.auth_token orelse ctx.options.api_key orelse {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(u8, "google-vertex: no credential (set --auth-token or a pre-minted VERTEX_ACCESS_TOKEN)"),
        } });
        return;
    };

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=google-vertex model={s} body_bytes={d}", .{ ctx.model.id, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    // Caller controls the endpoint via base_url — project/region must
    // be encoded in it. Without a base_url, the provider has no way
    // to know the project, so require it explicitly.
    const endpoint: []const u8 = ctx.options.base_url orelse {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.request_invalid,
            .message = try ctx.allocator.dupe(u8, "google-vertex: --base-url must encode the project + region endpoint"),
        } });
        return;
    };

    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{credential});
    defer ctx.allocator.free(auth_header);

    var http_headers_buf: [3]std.http.Header = undefined;
    http_headers_buf[0] = .{ .name = "authorization", .value = auth_header };
    http_headers_buf[1] = .{ .name = "content-type", .value = "application/json" };
    http_headers_buf[2] = .{ .name = "accept", .value = "text/event-stream" };
    const http_headers = http_headers_buf[0..3];

    const cancel = ctx.options.cancel orelse unreachable;

    var sc = http_mod.acquireStreamClient(ctx) orelse return;
    defer sc.deinit();
    const client = sc.client;

    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(client, .{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .extra_headers = http_headers,
    }, &bw, cancel, ctx.options.retry_policy orelse .{}, ctx.options.timeouts, http_mod.hooksFromOptionsWithRetry(ctx), &phase_info) catch |e| {
        try http_mod.reportTransportErrorWithPhase(ctx.out, ctx.io, ctx.allocator, e, phase_info.timed_out_phase, ctx.options.timeouts, phase_info.last_error_message);
        if (phase_info.last_error_message) |m| ctx.allocator.free(m);
        return;
    };

    const response_body = bw.written();
    const trace_id_owned = http_mod.writeTraceFile(
        ctx.allocator,
        ctx.io,
        ctx.options.http_trace_dir,
        "google-vertex",
        endpoint,
        "POST",
        @intFromEnum(result.status),
        body,
        response_body,
    );
    if (@intFromEnum(result.status) >= 400) {
        if (trace_id_owned) |tid| ctx.allocator.free(tid);
        try ctx.out.push(ctx.io, .start);
        const details = try @import("../error_map.zig").mapError(
            ctx.allocator,
            .openai,
            @intFromEnum(result.status),
            response_body,
        );
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = details });
        return;
    }

    try runFromSseWithTrace(ctx.allocator, ctx.io, response_body, ctx.out, cancel, trace_id_owned);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "buildEndpoint: renders Vertex URL with project + region + model" {
    const gpa = testing.allocator;
    const url = try buildEndpoint(gpa, "my-proj", "us-east4", "gemini-2.5-pro");
    defer gpa.free(url);
    try testing.expectEqualStrings(
        "https://us-east4-aiplatform.googleapis.com/v1/projects/my-proj/locations/us-east4/publishers/google/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
        url,
    );
}

test "wire format: buildRequestJson is the same as Gemini's" {
    // Structural equivalence — Vertex shares Gemini's request body.
    // If this test ever fails, Vertex has diverged and needs its
    // own builder.
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "sys", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "vertex", .api = "google-vertex" };

    const vertex_body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(vertex_body);

    const gemini_body = try gemini.buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(gemini_body);

    try testing.expectEqualStrings(gemini_body, vertex_body);
}

test "buildEndpoint: defaults-agnostic — caller always supplies region" {
    const gpa = testing.allocator;
    const url = try buildEndpoint(gpa, "p", default_region, "m");
    defer gpa.free(url);
    try testing.expect(std.mem.indexOf(u8, url, default_region) != null);
    try testing.expect(std.mem.indexOf(u8, url, "/publishers/google/models/m:streamGenerateContent") != null);
}
