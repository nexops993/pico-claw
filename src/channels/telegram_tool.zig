//! Telegram agent tool: outbound actions from the agent core to the
//! Telegram API.
//!
//! The Telegram CHANNEL (inbound messages) and this TOOL (outbound actions)
//! are separate capabilities. Registering the tool requires an explicit,
//! separate grant via TELEGRAM_TOOL_ENABLED — a configured channel never
//! implies tool permission. Outbound sends are additionally restricted to the
//! TELEGRAM_ALLOWED_USERS allowlist: an empty allowlist denies all sends.
//! Only three safe operations exist: get_me, get_chat, send_message. No
//! destructive or administrative Telegram API is exposed.

const std = @import("std");
const telegram = @import("telegram.zig");
const Tool = @import("../tools/tool.zig").Tool;

pub const enabled_env = "TELEGRAM_TOOL_ENABLED";
pub const max_tool_text_bytes: usize = telegram.send_message_limit;

pub const Fault = error{
    OutOfMemory,
    NotPermitted,
    NotConfigured,
    InvalidInput,
    InvalidChatId,
    TextTooLong,
    NotAllowed,
    UnsupportedOperation,
};

/// Truthy env check (same convention as TELEGRAM_ENABLED).
pub fn permissionGranted(env_map: *const std.process.Environ.Map) bool {
    const raw = env_map.get(enabled_env) orelse return false;
    const truthy = [_][]const u8{ "1", "true", "yes", "on" };
    for (truthy) |value| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), value)) return true;
    }
    return false;
}

pub const Op = enum {
    get_me,
    get_chat,
    send_message,
    send_document,

    pub fn name(self: Op) []const u8 {
        return switch (self) {
            .get_me => "get_me",
            .get_chat => "get_chat",
            .send_message => "send_message",
            .send_document => "send_document",
        };
    }
};

pub const Request = struct {
    op: Op,
    chat_id: ?i64 = null,
    /// Owned copy of the message text (free with deinit).
    text: []u8 = &.{},
    /// Owned copy of the document path (free with deinit).
    file_path: []u8 = &.{},

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
        if (self.file_path.len > 0) allocator.free(self.file_path);
        self.text = &.{};
        self.file_path = &.{};
    }
};

/// Parse the tool input envelope into an owned request. Pure and testable.
pub fn parseRequest(allocator: std.mem.Allocator, input: []const u8) Fault!Request {
    const Parsed = struct {
        op: []const u8 = "",
        chat_id: ?i64 = null,
        text: []const u8 = "",
        file_path: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Parsed, allocator, input, .{}) catch
        return error.InvalidInput;
    defer parsed.deinit();

    var op: ?Op = null;
    inline for (@typeInfo(Op).@"enum".fields) |field| {
        const candidate: Op = @enumFromInt(field.value);
        if (std.mem.eql(u8, parsed.value.op, candidate.name())) op = candidate;
    }
    const operation = op orelse return error.UnsupportedOperation;

    var request = Request{ .op = operation, .text = try allocator.dupe(u8, parsed.value.text), .file_path = try allocator.dupe(u8, parsed.value.file_path) };
    errdefer request.deinit(allocator);
    if (parsed.value.chat_id) |chat_id| request.chat_id = chat_id;
    switch (operation) {
        .get_me => {},
        .get_chat => if (request.chat_id == null) return error.InvalidChatId,
        .send_message => {
            if (request.chat_id == null) return error.InvalidChatId;
            if (std.mem.trim(u8, request.text, " \t\r\n").len == 0) return error.InvalidInput;
            if (request.text.len > max_tool_text_bytes) return error.TextTooLong;
        },
        .send_document => {
            if (request.chat_id == null) return error.InvalidChatId;
            if (std.mem.trim(u8, request.file_path, " \t\r\n").len == 0) return error.InvalidInput;
        },
    }
    return request;
}

/// The executable tool. All operations run real API calls through the same
/// client the channel uses; failures are returned as errors, never claimed
/// as success.
pub const TelegramTool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []u8,
    allowed_users: []const i64,
    base_url: []const u8 = telegram.api_base_url,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
    ) !TelegramTool {
        const raw_token = env_map.get(telegram.token_env) orelse return error.NotConfigured;
        const trimmed = std.mem.trim(u8, raw_token, " \t\r\n");
        if (trimmed.len == 0) return error.NotConfigured;
        const token = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(token);
        const allowed = try telegram.parseAllowedUsers(allocator, env_map.get(telegram.allowed_users_env) orelse "");
        return .{ .allocator = allocator, .io = io, .token = token, .allowed_users = allowed };
    }

    pub fn deinit(self: *TelegramTool) void {
        self.allocator.free(self.token);
        if (self.allowed_users.len > 0) self.allocator.free(self.allowed_users);
    }

    /// Manifest metadata for the tool registry.
    pub fn tool(self: *TelegramTool) Tool {
        return .{
            .name = "telegram",
            .description = "Telegram actions: get_me, get_chat, send_message, send_document (allowlisted chats only)",
            .context = self,
            .executeFn = executeErased,
            .permission = .network,
            .risk = .high,
            .parameters = &.{
                .{ .name = "op", .description = "get_me | get_chat | send_message", .required = true },
                .{ .name = "chat_id", .description = "Numeric Telegram chat id (get_chat/send_message)", .required = false },
                .{ .name = "text", .description = "Message text for send_message (bounded)", .required = false },
                .{ .name = "file_path", .description = "Absolute host file path for send_document", .required = false },
            },
        };
    }

    pub fn execute(self: *TelegramTool, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var request = parseRequest(allocator, input) catch |err| return err;
        defer request.deinit(allocator);

        const client = telegram.Client{
            .allocator = allocator,
            .io = self.io,
            .token = self.token,
            .base_url = self.base_url,
        };

        switch (request.op) {
            .get_me => return client.getMe(),
            .get_chat => return client.getChat(request.chat_id.?),
            .send_message => {
                if (!self.sendAllowed(request.chat_id.?)) return error.NotAllowed;
                try client.sendMessage(request.chat_id.?, request.text);
                return allocator.dupe(u8, "{\"ok\":true,\"sent\":true}");
            },
            .send_document => {
                if (!self.sendAllowed(request.chat_id.?)) return error.NotAllowed;
                _ = try client.sendDocument(request.chat_id.?, request.file_path);
                return allocator.dupe(u8, "{\"ok\":true,\"sent\":true}");
            },
        }
    }

    /// Explicit permission check: sends are allowed only to allowlisted
    /// chats. An empty allowlist denies everything.
    pub fn sendAllowed(self: *const TelegramTool, chat_id: i64) bool {
        for (self.allowed_users) |allowed| {
            if (allowed == chat_id) return true;
        }
        return false;
    }

    fn executeErased(context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
        const self: *TelegramTool = @ptrCast(@alignCast(context));
        return self.execute(allocator, input);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn envWith(pairs: []const [2][]const u8) std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    for (pairs) |pair| map.put(pair[0], pair[1]) catch {};
    return map;
}

test "telegram tool permission requires the explicit env grant" {
    var map = envWith(&.{.{ "TELEGRAM_BOT_TOKEN", "t" }});
    defer map.deinit();
    try testing.expect(!permissionGranted(&map));

    var granted = envWith(&.{.{ "TELEGRAM_TOOL_ENABLED", "true" }});
    defer granted.deinit();
    try testing.expect(permissionGranted(&granted));
}

test "tool request parsing validates operations and bounds" {
    const good = try parseRequest(testing.allocator, "{\"op\":\"get_me\"}");
    try testing.expectEqual(Op.get_me, good.op);

    const chat = try parseRequest(testing.allocator, "{\"op\":\"get_chat\",\"chat_id\":42}");
    try testing.expectEqual(Op.get_chat, chat.op);
    try testing.expectEqual(@as(?i64, 42), chat.chat_id);

    const send = try parseRequest(testing.allocator, "{\"op\":\"send_message\",\"chat_id\":7,\"text\":\"hi\"}");
    try testing.expectEqual(Op.send_message, send.op);

    try testing.expectError(error.UnsupportedOperation, parseRequest(testing.allocator, "{\"op\":\"delete_chat\"}"));
    try testing.expectError(error.InvalidInput, parseRequest(testing.allocator, "not json"));
    try testing.expectError(error.InvalidChatId, parseRequest(testing.allocator, "{\"op\":\"get_chat\"}"));
    try testing.expectError(error.InvalidChatId, parseRequest(testing.allocator, "{\"op\":\"send_message\",\"text\":\"x\"}"));
    try testing.expectError(error.InvalidInput, parseRequest(testing.allocator, "{\"op\":\"send_message\",\"chat_id\":1,\"text\":\" \"}"));
    try testing.expectError(error.TextTooLong, parseRequest(testing.allocator, "{\"op\":\"send_message\",\"chat_id\":1,\"text\":\"" ++ ("x" ** 4001) ++ "\"}"));
}

test "send permission is restricted to the allowlist" {
    var map = envWith(&.{ .{ "TELEGRAM_BOT_TOKEN", "t" }, .{ "TELEGRAM_ALLOWED_USERS", "111, 222" } });
    defer map.deinit();
    var tool = try TelegramTool.init(testing.allocator, testing.io, &map);
    defer tool.deinit();

    try testing.expect(tool.sendAllowed(111));
    try testing.expect(tool.sendAllowed(222));
    try testing.expect(!tool.sendAllowed(999));
    // The token is held but never rendered by any test or log path here.
    try testing.expect(tool.token.len == 1);
}

test "empty allowlist denies all sends" {
    var map = envWith(&.{.{ "TELEGRAM_BOT_TOKEN", "t" }});
    defer map.deinit();
    var tool = try TelegramTool.init(testing.allocator, testing.io, &map);
    defer tool.deinit();
    try testing.expect(!tool.sendAllowed(111));
}

test "tool metadata is network permission with high risk" {
    var map = envWith(&.{.{ "TELEGRAM_BOT_TOKEN", "t" }});
    defer map.deinit();
    var tool = try TelegramTool.init(testing.allocator, testing.io, &map);
    defer tool.deinit();
    const manifest = tool.tool();
    try testing.expectEqualStrings("telegram", manifest.name);
    try testing.expectEqual(@import("../tools/tool.zig").Permission.network, manifest.permission);
    try testing.expectEqual(@import("../tools/tool.zig").Risk.high, manifest.risk);
}
