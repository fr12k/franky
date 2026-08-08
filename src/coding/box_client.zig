//! Box client — HTTP client for the franky-box remote task queue.
//!
//! Thin wrapper around `ai.http.Client` exposing the three endpoints
//! a worker needs: claim, complete, fail.

const std = @import("std");
const ai = struct {
    pub const http = @import("../ai/http.zig");
    pub const log = @import("../ai/log.zig");
};
const box_types = @import("box_types.zig");

allocator: std.mem.Allocator,
io: std.Io,
client: ai.http.Client,
base_url: []const u8,
agent_id: []const u8,
agent_secret: []const u8,
team_id: []const u8,
/// Pre-allocated auth header value: "Bearer <secret>"
auth_value: []const u8,
/// Reusable extra-headers slice pointing at `auth_value`.
headers: [1]std.http.Header,

pub const BoxClient = @This();

pub const InitOptions = struct {
    base_url: []const u8,
    agent_id: []const u8,
    agent_secret: []const u8,
    team_id: []const u8,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: InitOptions) !BoxClient {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{opts.agent_secret});
    return .{
        .allocator = allocator,
        .io = io,
        .client = .{ .allocator = allocator, .io = io },
        .base_url = opts.base_url,
        .agent_id = opts.agent_id,
        .agent_secret = opts.agent_secret,
        .team_id = opts.team_id,
        .auth_value = auth_value,
        .headers = .{.{ .name = "authorization", .value = auth_value }},
    };
}

pub fn deinit(self: *BoxClient) void {
    self.allocator.free(self.auth_value);
    self.client.deinit();
}

fn claimUrl(self: *BoxClient, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/inbox/claim", .{ self.base_url, self.agent_id });
}

fn completeUrl(self: *BoxClient, allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/outbox/{s}/complete", .{ self.base_url, self.agent_id, task_id });
}

fn failUrl(self: *BoxClient, allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/outbox/{s}/fail", .{ self.base_url, self.agent_id, task_id });
}

/// Claim the next available task. Returns `null` when no tasks are available (HTTP 204).
pub fn claim(self: *BoxClient) !?box_types.ClaimedTask {
    const url = try claimUrl(self, self.allocator);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .response_writer = &body_writer.writer,
        .extra_headers = &self.headers,
    }) catch |err| {
        ai.log.log(.warn, "box_client", "claim", "request failed: {}", .{err});
        return null;
    };

    if (result.status != .ok) return null;

    const body = body_writer.writer.getWritten();
    return box_types.parseClaimedTask(self.allocator, body) catch null;
}

/// Mark a task as completed by posting the result output to the outbox.
pub fn complete(self: *BoxClient, task_id: []const u8, output: []const u8) !bool {
    const url = try completeUrl(self, self.allocator, task_id);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const content_type_header: std.http.Header = .{ .name = "content-type", .value = "application/json" };
    const all_headers = [_]std.http.Header{ self.headers[0], content_type_header };

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = output,
        .response_writer = &body_writer.writer,
        .extra_headers = &all_headers,
    }) catch |err| {
        ai.log.log(.warn, "box_client", "complete", "request failed: {}", .{err});
        return false;
    };
    return result.status == .ok;
}

/// Mark a task as failed by posting an error JSON to the outbox.
pub fn fail(self: *BoxClient, task_id: []const u8, error_json: []const u8) !bool {
    const url = try failUrl(self, self.allocator, task_id);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const content_type_header: std.http.Header = .{ .name = "content-type", .value = "application/json" };
    const all_headers = [_]std.http.Header{ self.headers[0], content_type_header };

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = error_json,
        .response_writer = &body_writer.writer,
        .extra_headers = &all_headers,
    }) catch |err| {
        ai.log.log(.warn, "box_client", "fail", "request failed: {}", .{err});
        return false;
    };
    return result.status == .ok;
}