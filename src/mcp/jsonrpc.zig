//! JSON-RPC 2.0 framing for the MCP stdio transport.
//!
//! MCP's stdio transport frames every message as a single line of UTF-8 JSON
//! (no embedded newlines). This module only builds and classifies those
//! messages; it performs no I/O, so every rule here is unit-testable and the
//! client stays the only place that touches pipes.
//!
//! Everything a server sends is untrusted: a line that is not valid JSON-RPC
//! is a protocol violation the caller must surface, never something to guess
//! at. The classifier therefore never repairs input — it reports.

const std = @import("std");
const Provider = @import("../provider.zig").Provider;

/// JSON-RPC protocol version string required on every message.
pub const version = "2.0";

/// MCP protocol revision this client advertises in `initialize`. It is sent
/// as-is; whatever the server echoes back is recorded, never assumed.
pub const protocol_version = "2024-11-05";

pub const client_name = "pico-claw";

/// Largest single message (line) accepted in either direction.
pub const max_message_bytes: usize = 1024 * 1024;

/// Longest error text retained from a server error object.
pub const max_error_message_len: usize = 256;

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
};

pub const Kind = enum {
    /// A response to a request we sent (has `id`).
    response,
    /// A one-way notification (has `method`, no `id`) — no reply expected.
    notification,
    /// Structurally invalid, unparsable, or unsupported input.
    invalid,
};

/// A parsed message. Borrows from an internal arena; call `deinit` when done.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    id: ?i64 = null,
    /// Present when the message is a JSON-RPC error response.
    err: ?ErrorObject = null,
    /// True when the message is a response carrying a `result` member.
    has_result: bool = false,
    result: ?std.json.Value = null,
    method: []const u8 = "",
    params: ?std.json.Value = null,
    /// Human-readable reason when `kind == .invalid`.
    reason: []const u8 = "",

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Write a JSON-RPC request object (without the trailing newline).
pub fn writeRequest(
    writer: *std.Io.Writer,
    id: i64,
    method: []const u8,
    params_json: ?[]const u8,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writer.print("{d}", .{id});
    try writer.writeAll(",\"method\":");
    try Provider.appendJsonString(writer, method);
    if (params_json) |params| {
        try writer.writeAll(",\"params\":");
        try writer.writeAll(params);
    }
    try writer.writeByte('}');
}

/// Write a JSON-RPC notification (no `id`, no reply expected).
pub fn writeNotification(
    writer: *std.Io.Writer,
    method: []const u8,
    params_json: ?[]const u8,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try Provider.appendJsonString(writer, method);
    if (params_json) |params| {
        try writer.writeAll(",\"params\":");
        try writer.writeAll(params);
    }
    try writer.writeByte('}');
}

/// Classify one inbound line. Never repairs input: a malformed line yields
/// `kind = .invalid` with a reason the caller records and reports.
pub fn parse(allocator: std.mem.Allocator, line: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    if (line.len > max_message_bytes) {
        return .{ .arena = arena, .kind = .invalid, .reason = "message too large" };
    }
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) {
        return .{ .arena = arena, .kind = .invalid, .reason = "empty message" };
    }

    const value = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch {
        return .{ .arena = arena, .kind = .invalid, .reason = "malformed JSON" };
    };
    if (value != .object) {
        return .{ .arena = arena, .kind = .invalid, .reason = "not a JSON object" };
    }
    const object = value.object;

    // The version marker is mandatory and must be exactly "2.0".
    const version_value = object.get("jsonrpc") orelse
        return .{ .arena = arena, .kind = .invalid, .reason = "missing jsonrpc version" };
    if (version_value != .string or !std.mem.eql(u8, version_value.string, version)) {
        return .{ .arena = arena, .kind = .invalid, .reason = "unsupported jsonrpc version" };
    }

    const id_value = object.get("id");
    const method_value = object.get("method");

    // A server-initiated request (method + id) is not something this client
    // advertised support for; classify it as invalid rather than answering.
    if (method_value != null and id_value != null) {
        return .{ .arena = arena, .kind = .invalid, .reason = "unsupported server request" };
    }

    if (method_value) |method| {
        if (method != .string) {
            return .{ .arena = arena, .kind = .invalid, .reason = "notification method is not a string" };
        }
        return .{
            .arena = arena,
            .kind = .notification,
            .method = method.string,
            .params = object.get("params"),
        };
    }

    if (id_value) |id| {
        var parsed_id: ?i64 = null;
        switch (id) {
            .integer => |int| parsed_id = int,
            .null => parsed_id = null,
            else => return .{ .arena = arena, .kind = .invalid, .reason = "response id is not an integer" },
        }

        if (object.get("error")) |err_value| {
            if (err_value != .object) {
                return .{ .arena = arena, .kind = .invalid, .reason = "error member is not an object" };
            }
            const code_value = err_value.object.get("code") orelse
                return .{ .arena = arena, .kind = .invalid, .reason = "error is missing a code" };
            if (code_value != .integer) {
                return .{ .arena = arena, .kind = .invalid, .reason = "error code is not an integer" };
            }
            var message: []const u8 = "server error";
            if (err_value.object.get("message")) |msg_value| {
                if (msg_value == .string) {
                    message = truncate(msg_value.string, max_error_message_len);
                }
            }
            return .{
                .arena = arena,
                .kind = .response,
                .id = parsed_id,
                .err = .{ .code = code_value.integer, .message = message },
            };
        }

        if (object.get("result")) |result_value| {
            return .{
                .arena = arena,
                .kind = .response,
                .id = parsed_id,
                .has_result = true,
                .result = result_value,
            };
        }

        return .{ .arena = arena, .kind = .invalid, .reason = "response has neither result nor error" };
    }

    return .{ .arena = arena, .kind = .invalid, .reason = "message has neither method nor id" };
}

/// Returns the first `limit` bytes of `text` (a prefix slice, never copied).
pub fn truncate(text: []const u8, limit: usize) []const u8 {
    return if (text.len <= limit) text else text[0..limit];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeRequest produces a single valid JSON-RPC line" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRequest(&out.writer, 7, "tools/list", "{}");
    const line = out.written();
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{}}",
        line,
    );
}

test "writeRequest escapes method text and omits absent params" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeRequest(&out.writer, 1, "a\"b\\c", null);
    const line = out.written();
    try testing.expect(std.mem.indexOf(u8, line, "\\\"b\\\\c") != null);
    try testing.expect(std.mem.indexOf(u8, line, "params") == null);
}

test "writeNotification has no id and classifies as a notification" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeNotification(&out.writer, "notifications/initialized", "{}");
    const line = out.written();
    try testing.expect(std.mem.indexOf(u8, line, "\"id\"") == null);
    var parsed = try parse(testing.allocator, line);
    defer parsed.deinit();
    try testing.expectEqual(Kind.notification, parsed.kind);
    try testing.expectEqualStrings("notifications/initialized", parsed.method);
}

test "parse classifies a result response" {
    var parsed = try parse(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[]}}",
    );
    defer parsed.deinit();
    try testing.expectEqual(Kind.response, parsed.kind);
    try testing.expectEqual(@as(?i64, 3), parsed.id);
    try testing.expect(parsed.err == null);
    try testing.expect(parsed.has_result);
    try testing.expect(parsed.result != null);
}

test "parse classifies an error response and keeps a bounded message" {
    const long = "x" ** 400;
    const line = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{{\"code\":-32601,\"message\":\"{s}\"}}}}",
        .{long},
    );
    defer testing.allocator.free(line);
    var parsed = try parse(testing.allocator, line);
    defer parsed.deinit();
    try testing.expectEqual(Kind.response, parsed.kind);
    try testing.expectEqual(@as(i64, -32601), parsed.err.?.code);
    try testing.expectEqual(max_error_message_len, parsed.err.?.message.len);
    try testing.expect(!parsed.has_result);
}

test "parse rejects malformed, non-object, and wrong-version input" {
    const cases = [_][]const u8{
        "not json at all",
        "[1,2,3]",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"id\":5}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{}}",
    };
    for (cases) |case| {
        var parsed = try parse(testing.allocator, case);
        defer parsed.deinit();
        try testing.expectEqual(Kind.invalid, parsed.kind);
        try testing.expect(parsed.reason.len > 0);
    }
}

test "parse accepts a null id response as a valid shape" {
    var parsed = try parse(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}");
    defer parsed.deinit();
    try testing.expectEqual(Kind.response, parsed.kind);
    try testing.expectEqual(@as(?i64, null), parsed.id);
}

test "parse enforces the message size ceiling" {
    const big = try testing.allocator.alloc(u8, max_message_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    var parsed = try parse(testing.allocator, big);
    defer parsed.deinit();
    try testing.expectEqual(Kind.invalid, parsed.kind);
    try testing.expectEqualStrings("message too large", parsed.reason);
}

test "truncate keeps short text intact and bounds long text" {
    try testing.expectEqualStrings("abc", truncate("abc", 10));
    try testing.expectEqualStrings("abc", truncate("abcdef", 3));
}
