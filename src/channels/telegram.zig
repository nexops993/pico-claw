//! Telegram channel adapter: long-polling transport that feeds normalized
//! messages into the shared agent session layer. Configuration comes from the
//! environment (a local `.env` is fine) so the bot token never appears in
//! config files, code, logs, or tests. The agent invocation is the same
//! `Conversation.send` path used by the CLI.

const std = @import("std");
const builtin = @import("builtin");

const ui = @import("../interfaces/ui.zig");
const provider_module = @import("../provider.zig");
const format = @import("../format.zig");
const channel_mod = @import("channel.zig");
const session_mod = @import("session.zig");

const InboundMessage = channel_mod.InboundMessage;
const ChannelKind = channel_mod.ChannelKind;
const ChannelState = channel_mod.ChannelState;
const SessionStore = session_mod.SessionStore;

pub const api_base_url: []const u8 = "https://api.telegram.org";
pub const default_poll_timeout_secs: u16 = 5;
pub const max_poll_timeout_secs: u16 = 50;
pub const poll_limit: u16 = 20;
/// Margin below Telegram's hard 4096-character message limit.
pub const send_message_limit: usize = 4000;
pub const max_error_backoff_secs: u32 = 30;
/// Bounded retry for transient `sendMessage` failures (3 attempts total).
pub const max_send_attempts: usize = 3;
pub const send_retry_delay_secs: u32 = 1;

pub const enabled_env = "TELEGRAM_ENABLED";
pub const token_env = "TELEGRAM_BOT_TOKEN";
pub const allowed_users_env = "TELEGRAM_ALLOWED_USERS";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const ConfigError = error{
    TokenMissing,
    InvalidAllowedUsers,
    OutOfMemory,
};

pub const Config = struct {
    token: []u8,
    /// Decimal Telegram user ids. Empty means "deny everyone" (locked mode);
    /// the bot only answers users on this list.
    allowed_users: []i64,
    poll_timeout_secs: u16 = default_poll_timeout_secs,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.allowed_users.len > 0) allocator.free(self.allowed_users);
    }
};

pub const AccessPolicy = struct {
    allowed_users: []const i64,

    /// Deny by default: an empty allowlist authorizes nobody.
    pub fn allows(self: AccessPolicy, user_id: i64) bool {
        for (self.allowed_users) |id| {
            if (id == user_id) return true;
        }
        return false;
    }
};

/// Whether the Telegram channel is switched on via `TELEGRAM_ENABLED`.
pub fn isEnabled(env_map: *const std.process.Environ.Map) bool {
    const raw = env_map.get(enabled_env) orelse return false;
    const truthy = [_][]const u8{ "1", "true", "yes", "on" };
    for (truthy) |candidate| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), candidate)) return true;
    }
    return false;
}

/// Channel lifecycle state as seen from the environment, for `status` output.
pub fn stateFromEnv(env_map: *const std.process.Environ.Map) ChannelState {
    if (!isEnabled(env_map)) return .disabled;
    const token = env_map.get(token_env) orelse return .not_configured;
    if (std.mem.trim(u8, token, " \t\r\n").len == 0) return .not_configured;
    return .enabled;
}

/// Build the channel configuration from the environment. The token is read
/// from `TELEGRAM_BOT_TOKEN` (set in `.env` or the real environment) and is
/// only stored in memory. Returns `error.TokenMissing` when absent or blank.
pub fn configFromEnv(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ConfigError!Config {
    const raw_token = env_map.get(token_env) orelse return error.TokenMissing;
    const trimmed = std.mem.trim(u8, raw_token, " \t\r\n");
    if (trimmed.len == 0) return error.TokenMissing;

    const token = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(token);

    const allowed_users = try parseAllowedUsers(allocator, env_map.get(allowed_users_env) orelse "");
    errdefer if (allowed_users.len > 0) allocator.free(allowed_users);

    return .{ .token = token, .allowed_users = allowed_users };
}

/// Parse a comma-separated list of decimal Telegram user ids, e.g.
/// `"123456, -1009988"`. Empty input yields an empty (locked) allowlist.
pub fn parseAllowedUsers(allocator: std.mem.Allocator, csv: []const u8) error{ InvalidAllowedUsers, OutOfMemory }![]i64 {
    var list: std.ArrayList(i64) = .empty;
    errdefer list.deinit(allocator);

    var entries = std.mem.splitScalar(u8, csv, ',');
    while (entries.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const id = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidAllowedUsers;
        try list.append(allocator, id);
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const UpdateError = error{ SyntaxError, OutOfMemory };

pub const ParsedUpdate = struct {
    update_id: i64,
    /// Normalized inbound message, or null for updates Pico Claw ignores
    /// (edits, media, non-private chats, unknown senders, …).
    message: ?InboundMessage = null,
};

const UserJson = struct {
    id: i64,
};

const ChatJson = struct {
    id: ?i64 = null,
    type: []const u8 = "",
};

const MessageJson = struct {
    message_id: i64 = 0,
    from: ?UserJson = null,
    chat: ChatJson = .{},
    text: []const u8 = "",
};

const UpdateJson = struct {
    update_id: i64,
    message: ?MessageJson = null,
};

/// Envelope of a `getUpdates` batch: `{"ok":true,"result":[…]}`.
const UpdatesJson = struct {
    ok: bool = false,
    description: ?[]const u8 = null,
    result: ?[]UpdateJson = null,
};

const ApiEnvelope = struct {
    ok: bool = false,
    description: ?[]const u8 = null,
};

/// Validate an API response envelope. On failure, a bounded and sanitized
/// prefix of the API description is emitted through debug logging only —
/// never the request URL, never the token.
pub fn checkApiOk(allocator: std.mem.Allocator, body: []const u8) error{ ApiRequestFailed, InvalidResponse, OutOfMemory }!void {
    const parsed = std.json.parseFromSlice(ApiEnvelope, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value.ok) return;
    if (parsed.value.description) |description| {
        var buffer: [160]u8 = undefined;
        ui.debugOut("[Telegram] API error: {s}\n", .{provider_module.boundedPrefix(&buffer, description)});
    }
    return error.ApiRequestFailed;
}

/// Normalize one Telegram message into a channel message. v1 scope: private
/// chats with plain text from a known sender; everything else is ignored.
fn normalizeMessage(allocator: std.mem.Allocator, message: *const MessageJson) UpdateError!?InboundMessage {
    if (message.text.len == 0) return null;
    const sender = message.from orelse return null;
    if (!std.mem.eql(u8, message.chat.type, "private")) return null;
    const chat_number = message.chat.id orelse return null;

    const user_id = std.fmt.allocPrint(allocator, "{d}", .{sender.id}) catch |err| return err;
    defer allocator.free(user_id);
    const chat_id = std.fmt.allocPrint(allocator, "{d}", .{chat_number}) catch |err| return err;
    defer allocator.free(chat_id);

    return try InboundMessage.init(
        allocator,
        .telegram,
        user_id,
        chat_id,
        message.text,
        if (message.message_id > 0) @intCast(message.message_id) else null,
    );
}

/// Parse a single Telegram update (used by tests and diagnostics). Invalid
/// JSON is reported as `error.SyntaxError` so callers can back off.
pub fn parseUpdate(allocator: std.mem.Allocator, bytes: []const u8) UpdateError!ParsedUpdate {
    const parsed = std.json.parseFromSlice(UpdateJson, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SyntaxError,
    };
    defer parsed.deinit();

    const update = parsed.value;
    if (update.message) |*message| {
        if (try normalizeMessage(allocator, message)) |inbound| {
            return .{ .update_id = update.update_id, .message = inbound };
        }
    }
    return .{ .update_id = update.update_id };
}

/// Build the JSON body of a `sendMessage` request. The text is JSON-escaped
/// including surrogate-safe UTF-8 handling.
pub fn buildSendMessageBody(allocator: std.mem.Allocator, chat_id: i64, text: []const u8) error{OutOfMemory}![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    const writer = &output.writer;
    writer.print("{{\"chat_id\":{d},\"text\":", .{chat_id}) catch return error.OutOfMemory;
    provider_module.Provider.appendJsonString(writer, text) catch return error.OutOfMemory;
    writer.writeByte('}') catch return error.OutOfMemory;

    return allocator.dupe(u8, output.written());
}

/// Build the JSON body of an HTML-formatted `sendMessage` request: the text
/// is already escaped Telegram HTML from `format.chunkAndFormat`, so it is
/// sent with `parse_mode=HTML` and link previews disabled.
pub fn buildSendMessageHtmlBody(allocator: std.mem.Allocator, chat_id: i64, html: []const u8) error{OutOfMemory}![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    const writer = &output.writer;
    writer.print("{{\"chat_id\":{d},\"text\":", .{chat_id}) catch return error.OutOfMemory;
    provider_module.Provider.appendJsonString(writer, html) catch return error.OutOfMemory;
    writer.writeAll(",\"parse_mode\":\"HTML\",\"link_preview_options\":{\"is_disabled\":true}}") catch
        return error.OutOfMemory;

    return allocator.dupe(u8, output.written());
}

/// Build the JSON body of a `sendChatAction` request. `action` is a fixed
/// literal ("typing") chosen by the caller, not user input.
pub fn buildChatActionBody(allocator: std.mem.Allocator, chat_id: i64, action: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"chat_id\":{d},\"action\":\"{s}\"}}", .{ chat_id, action });
}

/// Split a reply into `sendMessage`-sized chunks, preferring newline
/// boundaries in the second half of each chunk; falls back to a hard cut.
pub fn splitMessage(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![][]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }

    var remaining = text;
    while (remaining.len > send_message_limit) {
        var split_at = send_message_limit;
        if (std.mem.lastIndexOfScalar(u8, remaining[0..send_message_limit], '\n')) |newline| {
            if (newline >= send_message_limit / 2) split_at = newline + 1;
        } else {
            // Hard cut: back up to a UTF-8 sequence boundary so a multi-byte
            // character is never split in half.
            while (split_at > 0 and (remaining[split_at] & 0xC0) == 0x80) split_at -= 1;
        }
        try parts.append(allocator, try allocator.dupe(u8, remaining[0..split_at]));
        remaining = remaining[split_at..];
    }
    if (remaining.len > 0 or parts.items.len == 0) {
        try parts.append(allocator, try allocator.dupe(u8, remaining));
    }
    return parts.toOwnedSlice(allocator);
}

/// Free a value returned by `splitMessage`.
pub fn freeParts(allocator: std.mem.Allocator, parts: [][]u8) void {
    for (parts) |part| allocator.free(part);
    allocator.free(parts);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Basic user-facing commands. Deliberately minimal: chat text without an
/// exact command match is agent input, never a control surface.
pub const Command = enum {
    start,
    help,
    status,
    clear,
};

/// Parse an exact command message (`/help`, case-insensitive, no arguments).
/// Anything else — including `/status now` or `/unknown` — returns null and
/// is treated as ordinary chat input.
pub fn parseCommand(text: []const u8) ?Command {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, trimmed[1..], ' ') != null) return null;

    const entries = [_]struct { name: []const u8, command: Command }{
        .{ .name = "/start", .command = .start },
        .{ .name = "/help", .command = .help },
        .{ .name = "/status", .command = .status },
        .{ .name = "/clear", .command = .clear },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.name)) return entry.command;
    }
    return null;
}

/// Fixed reply bodies. They are Markdown and go through the same HTML
/// formatter as agent replies, so no raw markup ever reaches Telegram.
pub const start_reply =
    "👋 **Halo! Saya Pico Claw** — asisten AI pribadi Anda.\n\n" ++
    "Kirim pesan apa saja untuk mulai, atau ketik /help untuk daftar perintah.";
pub const help_reply =
    "**Perintah Pico Claw**\n\n" ++
    "• /start — sapaan awal\n" ++
    "• /help — daftar perintah\n" ++
    "• /status — status agent ringkas\n" ++
    "• /clear — bersihkan sesi chat ini\n\n" ++
    "Selain perintah di atas, semua pesan diteruskan ke agent.";
pub const clear_reply = "🧹 Sesi chat ini sudah dibersihkan.";
pub const clear_missing_reply = "Belum ada sesi aktif untuk chat ini.";

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    base_url: []const u8 = api_base_url,

    /// Fetch pending updates with long polling. The returned body is owned
    /// by the caller.
    pub fn getUpdates(self: *const Client, offset: i64, timeout_secs: u16) ![]u8 {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"offset\":{d},\"timeout\":{d},\"limit\":{d},\"allowed_updates\":[\"message\"]}}",
            .{ offset, timeout_secs, poll_limit },
        );
        defer self.allocator.free(body);
        return self.post("getUpdates", body);
    }

    /// Deliver one message. Replies longer than `send_message_limit` must be
    /// pre-split with `splitMessage`.
    pub fn sendMessage(self: *const Client, chat_id: i64, text: []const u8) !void {
        const body = try buildSendMessageBody(self.allocator, chat_id, text);
        defer self.allocator.free(body);

        const response = try self.post("sendMessage", body);
        defer self.allocator.free(response);

        try checkApiOk(self.allocator, response);
    }

    /// Deliver one pre-formatted HTML message part. The input must already be
    /// escaped, valid Telegram HTML (see `format.chunkAndFormat`).
    pub fn sendMessageHtml(self: *const Client, chat_id: i64, html: []const u8) !void {
        const body = try buildSendMessageHtmlBody(self.allocator, chat_id, html);
        defer self.allocator.free(body);

        const response = try self.post("sendMessage", body);
        defer self.allocator.free(response);

        try checkApiOk(self.allocator, response);
    }

    /// Best-effort chat action (e.g. "typing"). Failures are non-fatal and
    /// are ignored by callers.
    pub fn sendChatAction(self: *const Client, chat_id: i64, action: []const u8) !void {
        const body = try buildChatActionBody(self.allocator, chat_id, action);
        defer self.allocator.free(body);

        const response = try self.post("sendChatAction", body);
        defer self.allocator.free(response);

        try checkApiOk(self.allocator, response);
    }

    /// Fetch the bot's own identity (`getMe`). Used by the gateway
    /// "test connection" probe and the Telegram agent tool. The token never
    /// appears in logs; the raw body is the caller's to free.
    pub fn getMe(self: *const Client) ![]u8 {
        const response = try self.post("getMe", "{}");
        errdefer self.allocator.free(response);
        try checkApiOk(self.allocator, response);
        return response;
    }

    /// Fetch one chat's public metadata (`getChat`). The raw body is the
    /// caller's to free.
    pub fn getChat(self: *const Client, chat_id: i64) ![]u8 {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"chat_id\":{d}}}", .{chat_id});
        defer self.allocator.free(body);

        const response = try self.post("getChat", body);
        errdefer self.allocator.free(response);
        try checkApiOk(self.allocator, response);
        return response;
    }

    /// POST `<base>/bot<token>/<method>` with a JSON body and return the
    /// owned response body. The URL contains the bot token and is therefore
    /// never logged; diagnostics use the method name and status code only.
    fn post(self: *const Client, method: []const u8, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/bot{s}/{s}",
            .{ self.base_url, self.token, method },
        );
        defer self.allocator.free(url);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var request = try client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer request.deinit();

        // `sendBodyComplete` requires a mutable body; match the provider's
        // convention of duping the encoded payload before sending.
        const mutable_body = try self.allocator.dupe(u8, body);
        defer self.allocator.free(mutable_body);
        try request.sendBodyComplete(mutable_body);
        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            var buffer: [160]u8 = undefined;
            ui.debugOut("[Telegram] {s} failed: HTTP {d}\n", .{
                provider_module.boundedPrefix(&buffer, method),
                @intFromEnum(response.head.status),
            });
            return error.ApiRequestFailed;
        }

        var response_body = std.Io.Writer.Allocating.init(self.allocator);
        defer response_body.deinit();

        var transfer_buffer: [16 * 1024]u8 = undefined;
        var reader = response.reader(&transfer_buffer);
        _ = try reader.streamRemaining(&response_body.writer);

        return self.allocator.dupe(u8, response_body.written());
    }
};

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

/// Graceful shutdown flag; `installShutdownHandler` wires Ctrl+C/SIGTERM to it.
var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn shutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

const windows_console = struct {
    const DWORD = std.os.windows.DWORD;
    const BOOL = std.os.windows.BOOL;

    const Handler = ?*const fn (ctrl_type: DWORD) callconv(.c) BOOL;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: Handler, add: BOOL) BOOL;

    fn handler(ctrl_type: DWORD) callconv(.c) BOOL {
        _ = ctrl_type;
        requestShutdown();
        // Handled: the process stays alive until the poll loop exits cleanly.
        return .TRUE;
    }

    fn install() void {
        _ = SetConsoleCtrlHandler(handler, .TRUE);
    }
};

const posix_signals = struct {
    fn onSignal(sig: std.posix.SIG) callconv(.c) void {
        _ = sig;
        requestShutdown();
    }

    fn install() void {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    }
};

/// Stop the poll loop gracefully on Ctrl+C (Windows) or SIGINT/SIGTERM (POSIX).
pub fn installShutdownHandler() void {
    if (comptime builtin.os.tag == .windows) {
        windows_console.install();
    } else {
        posix_signals.install();
    }
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    sessions: *SessionStore,
    client: Client,
    /// Next `update_id` to fetch (Telegram long-poll offset).
    offset: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const Config,
        sessions: *SessionStore,
    ) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .sessions = sessions,
            .client = .{ .allocator = allocator, .io = io, .token = config.token },
        };
    }

    /// Poll loop; returns after shutdown is requested. Transport failures
    /// back off exponentially (capped at `max_error_backoff_secs`) and never
    /// stop the loop; only `error.OutOfMemory` is fatal.
    pub fn run(self: *Runtime) !void {
        var backoff_secs: u32 = 1;
        while (!shutdownRequested()) {
            const body = self.client.getUpdates(self.offset, self.config.poll_timeout_secs) catch |err| {
                if (err == error.OutOfMemory) return err;
                ui.debugOut("[Telegram] getUpdates failed: {s}\n", .{@errorName(err)});
                self.sleepSeconds(backoff_secs);
                backoff_secs = @min(backoff_secs * 2, max_error_backoff_secs);
                continue;
            };
            defer self.allocator.free(body);

            backoff_secs = 1;
            self.processBatch(body) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    ui.debugOut("[Telegram] update batch rejected: {s}\n", .{@errorName(err)});
                    self.sleepSeconds(1);
                },
            };
        }
    }

    fn processBatch(self: *Runtime, body: []const u8) !void {
        const parsed = std.json.parseFromSlice(
            UpdatesJson,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        defer parsed.deinit();

        if (!parsed.value.ok) return error.ApiRequestFailed;
        const updates = parsed.value.result orelse return;

        for (updates) |*update| {
            // Duplicate update protection: Telegram may redeliver an update
            // (for example a repeated id inside one batch); anything below
            // the confirmed offset is skipped before any agent work.
            if (update.update_id < self.offset) continue;
            self.offset = update.update_id + 1;
            if (update.message) |*message| {
                if (try normalizeMessage(self.allocator, message)) |inbound| {
                    self.handleUpdate(inbound);
                }
            }
        }
    }

    /// Route one normalized message: allowlist, then the chat's conversation,
    /// then chunked delivery. Takes ownership of `inbound`.
    fn handleUpdate(self: *Runtime, inbound: InboundMessage) void {
        defer inbound.deinit(self.allocator);

        const user_id = std.fmt.parseInt(i64, inbound.user_id, 10) catch return;
        const chat_id = std.fmt.parseInt(i64, inbound.chat_id, 10) catch return;

        const access = AccessPolicy{ .allowed_users = self.config.allowed_users };
        if (!access.allows(user_id)) {
            // The hint only echoes the caller's own id, which they know.
            var buffer: [160]u8 = undefined;
            const hint = std.fmt.bufPrint(
                &buffer,
                "Not authorized. Your Telegram user id is {d}; add it to TELEGRAM_ALLOWED_USERS to use this bot.",
                .{user_id},
            ) catch return;
            self.client.sendMessage(chat_id, hint) catch |err| {
                ui.debugOut("[Telegram] rejection notice failed: {s}\n", .{@errorName(err)});
            };
            return;
        }

        if (parseCommand(inbound.text)) |command| {
            self.handleCommand(command, chat_id, inbound.chat_id);
            return;
        }

        const conversation = self.sessions.getOrCreate(inbound.chat_id) catch |err| {
            ui.debugOut("[Telegram] session unavailable for chat {s}: {s}\n", .{ inbound.chat_id, @errorName(err) });
            return;
        };

        // Typing indicator while the agent works (best effort; Telegram keeps
        // the state for a few seconds and there is no background thread to
        // renew it).
        self.client.sendChatAction(chat_id, "typing") catch {};

        const reply = conversation.send(inbound.text) catch |err| {
            ui.debugOut("[Telegram] agent request failed for chat {s}: {s}\n", .{ inbound.chat_id, @errorName(err) });
            self.client.sendMessage(chat_id, "AI request failed; please try again later.") catch |send_err| {
                ui.debugOut("[Telegram] failure notice failed: {s}\n", .{@errorName(send_err)});
            };
            return;
        };
        defer self.allocator.free(reply);

        self.deliverFormatted(chat_id, reply);
    }

    /// Execute one parsed command. Commands never touch the provider.
    fn handleCommand(self: *Runtime, command: Command, chat_id: i64, chat_key: []const u8) void {
        switch (command) {
            .start => self.deliverFormatted(chat_id, start_reply),
            .help => self.deliverFormatted(chat_id, help_reply),
            .status => {
                const text = self.buildStatusText() catch |err| {
                    ui.debugOut("[Telegram] status build failed: {s}\n", .{@errorName(err)});
                    return;
                };
                defer self.allocator.free(text);
                self.deliverFormatted(chat_id, text);
            },
            .clear => {
                const cleared = self.sessions.clearChat(chat_key);
                const reply = if (cleared) clear_reply else clear_missing_reply;
                self.client.sendMessage(chat_id, reply) catch |err| {
                    ui.debugOut("[Telegram] clear notice failed: {s}\n", .{@errorName(err)});
                };
            },
        }
    }

    /// Compact, secret-free agent status for the /status command.
    fn buildStatusText(self: *const Runtime) error{OutOfMemory}![]u8 {
        const deps = &self.sessions.deps;

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        writer.writeAll("🤖 **Pico Claw** status\n\n") catch return error.OutOfMemory;
        writer.print("• Model: {s}\n", .{deps.provider.model()}) catch return error.OutOfMemory;
        writer.print("• Provider: {s}\n", .{deps.provider.baseUrl()}) catch return error.OutOfMemory;
        writer.print("• Memories: {d}\n", .{deps.memory.count()}) catch return error.OutOfMemory;
        writer.print("• Experiences: {d}\n", .{deps.experience.count()}) catch return error.OutOfMemory;
        writer.print("• Strategies: {d}\n", .{deps.strategies.count()}) catch return error.OutOfMemory;
        writer.print("• Knowledge: {d}\n", .{deps.knowledge.count()}) catch return error.OutOfMemory;
        writer.print("• Tasks: {d} ({d} completed, {d} failed)\n", .{
            if (deps.tasks) |store| store.count() else 0,
            if (deps.tasks) |store| store.completedCount() else 0,
            if (deps.tasks) |store| store.failedCount() else 0,
        }) catch return error.OutOfMemory;
        writer.print("• Proposals: {d} ({d} proposed, {d} accepted, {d} rejected)\n", .{
            if (deps.proposals) |store| store.count() else 0,
            if (deps.proposals) |store| store.countStatus(.proposed) else 0,
            if (deps.proposals) |store| store.countStatus(.accepted) else 0,
            if (deps.proposals) |store| store.countStatus(.rejected) else 0,
        }) catch return error.OutOfMemory;
        writer.print("• Active chats: {d}\n", .{self.sessions.count()}) catch return error.OutOfMemory;

        return self.allocator.dupe(u8, output.written());
    }

    /// Format a Markdown reply into Telegram HTML parts and deliver them in
    /// order. Each part is valid, escaped HTML within `send_message_limit` by
    /// construction, so no raw Markdown ever reaches the user.
    fn deliverFormatted(self: *Runtime, chat_id: i64, markdown: []const u8) void {
        const parts = format.chunkAndFormat(self.allocator, markdown, send_message_limit) catch |err| {
            ui.debugOut("[Telegram] reply formatting failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer format.freeParts(self.allocator, parts);

        for (parts) |part| {
            self.deliverHtmlPart(chat_id, part.html) catch |err| {
                ui.debugOut("[Telegram] sendMessage failed for chat {d}: {s}\n", .{ chat_id, @errorName(err) });
                // Stop after a failed part: keeps the remaining conversation
                // ordered instead of skipping a chunk of the reply.
                return;
            };
        }
    }

    /// Send one HTML part with bounded retries for transient API errors.
    fn deliverHtmlPart(self: *Runtime, chat_id: i64, html: []const u8) !void {
        var attempt: usize = 1;
        while (true) {
            self.client.sendMessageHtml(chat_id, html) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (attempt >= max_send_attempts) return err;
                ui.debugOut("[Telegram] sendMessage retry {d}/{d}: {s}\n", .{
                    attempt,
                    max_send_attempts - 1,
                    @errorName(err),
                });
                attempt += 1;
                self.sleepSeconds(send_retry_delay_secs);
                continue;
            };
            return;
        }
    }

    fn sleepSeconds(self: *Runtime, seconds: u32) void {
        std.Io.sleep(self.io, std.Io.Duration.fromSeconds(@intCast(seconds)), .awake) catch {};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseAllowedUsers accepts decimal ids and rejects garbage" {
    const allocator = std.testing.allocator;

    const empty = try parseAllowedUsers(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const list = try parseAllowedUsers(allocator, " 111,222 ,-1009988 ");
    defer allocator.free(list);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 111, 222, -1009988 }, list);

    try std.testing.expectError(error.InvalidAllowedUsers, parseAllowedUsers(allocator, "not-a-number"));
}

test "access policy denies by default and allows listed users only" {
    const policy = AccessPolicy{ .allowed_users = &[_]i64{ 111, 222 } };
    try std.testing.expect(policy.allows(111));
    try std.testing.expect(policy.allows(222));
    try std.testing.expect(!policy.allows(999));

    const locked = AccessPolicy{ .allowed_users = &[_]i64{} };
    try std.testing.expect(!locked.allows(0));
}

test "configFromEnv reads the token and allowlist from the environment" {
    const allocator = std.testing.allocator;

    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();
    try std.testing.expectError(error.TokenMissing, configFromEnv(allocator, &map));

    try map.put(token_env, "test-token-not-real");
    try map.put(allowed_users_env, "111, 222");
    var config = try configFromEnv(allocator, &map);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("test-token-not-real", config.token);
    try std.testing.expectEqual(@as(usize, 2), config.allowed_users.len);
    try std.testing.expectEqual(default_poll_timeout_secs, config.poll_timeout_secs);

    try map.put(allowed_users_env, "bad");
    try std.testing.expectError(error.InvalidAllowedUsers, configFromEnv(allocator, &map));
}

test "stateFromEnv reflects the enabled flag and token presence" {
    const allocator = std.testing.allocator;

    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();

    try std.testing.expectEqual(ChannelState.disabled, stateFromEnv(&map));

    try map.put(enabled_env, "true");
    try std.testing.expectEqual(ChannelState.not_configured, stateFromEnv(&map));

    try map.put(token_env, "test-token-not-real");
    try std.testing.expectEqual(ChannelState.enabled, stateFromEnv(&map));

    try map.put(enabled_env, "false");
    try std.testing.expectEqual(ChannelState.disabled, stateFromEnv(&map));

    try map.put(enabled_env, "TRUE");
    try std.testing.expectEqual(ChannelState.enabled, stateFromEnv(&map));
}

test "parseUpdate normalizes a private text message" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"update_id":42,"message":{"message_id":7,"date":1700000000,"from":{"id":111,"is_bot":false,"first_name":"Owner"},"chat":{"id":111,"type":"private"},"text":"Halo \"bot\"\nline2"}}
    ;

    const parsed = try parseUpdate(allocator, raw);
    defer if (parsed.message) |message| message.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 42), parsed.update_id);
    const message = parsed.message.?;
    try std.testing.expectEqual(ChannelKind.telegram, message.channel);
    try std.testing.expectEqualStrings("111", message.user_id);
    try std.testing.expectEqualStrings("111", message.chat_id);
    try std.testing.expectEqualStrings("Halo \"bot\"\nline2", message.text);
    try std.testing.expectEqual(@as(?u64, 7), message.message_id);
}

test "parseUpdate ignores edits media group chats and unknown senders" {
    const allocator = std.testing.allocator;

    // Edited messages are not user input.
    const edited =
        \\{"update_id":1,"edited_message":{"message_id":2,"chat":{"id":5,"type":"private"},"text":"edited"}}
    ;
    const edited_update = try parseUpdate(allocator, edited);
    try std.testing.expect(edited_update.message == null);
    try std.testing.expectEqual(@as(i64, 1), edited_update.update_id);

    // Group chats are out of scope in v1.
    const group =
        \\{"update_id":2,"message":{"message_id":3,"from":{"id":6},"chat":{"id":-1009988,"type":"supergroup"},"text":"hello"}}
    ;
    try std.testing.expect((try parseUpdate(allocator, group)).message == null);

    // Unknown sender or media-only messages are ignored.
    const no_sender =
        \\{"update_id":3,"message":{"message_id":4,"chat":{"id":5,"type":"private"},"text":"hello"}}
    ;
    try std.testing.expect((try parseUpdate(allocator, no_sender)).message == null);

    const media_only =
        \\{"update_id":4,"message":{"message_id":5,"from":{"id":6},"chat":{"id":5,"type":"private"},"photo":[{"file_id":"x"}]}}
    ;
    try std.testing.expect((try parseUpdate(allocator, media_only)).message == null);

    // Malformed JSON is a syntax error, not a crash.
    try std.testing.expectError(error.SyntaxError, parseUpdate(allocator, "not json"));
}

test "buildSendMessageBody escapes the text as JSON" {
    const allocator = std.testing.allocator;

    const body = try buildSendMessageBody(allocator, 123, "say \"hi\"\n\\ back é");
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":123,\"text\":\"say \\\"hi\\\"\\n\\\\ back é\"}",
        body,
    );
}

test "buildSendMessageHtmlBody sets parse mode and disables previews" {
    const allocator = std.testing.allocator;

    const body = try buildSendMessageHtmlBody(allocator, 55, "<b>hi</b> &amp; bye");
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":55,\"text\":\"<b>hi</b> &amp; bye\",\"parse_mode\":\"HTML\",\"link_preview_options\":{\"is_disabled\":true}}",
        body,
    );
}

test "buildChatActionBody encodes the typing action" {
    const allocator = std.testing.allocator;

    const body = try buildChatActionBody(allocator, 9, "typing");
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"chat_id\":9,\"action\":\"typing\"}", body);
}

test "parseCommand matches exact commands and rejects everything else" {
    try std.testing.expectEqual(Command.start, parseCommand("/start").?);
    try std.testing.expectEqual(Command.help, parseCommand("  /HELP \n").?);
    try std.testing.expectEqual(Command.status, parseCommand("/Status").?);
    try std.testing.expectEqual(Command.clear, parseCommand("/clear").?);

    // Not commands: arguments, unknown, chat text, bare slash.
    try std.testing.expect(parseCommand("/status now") == null);
    try std.testing.expect(parseCommand("/unknown") == null);
    try std.testing.expect(parseCommand("/") == null);
    try std.testing.expect(parseCommand("hello") == null);
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("/clear extra") == null);
}

test "splitMessage never splits a utf-8 sequence on a hard cut" {
    const allocator = std.testing.allocator;
    const testing = std.testing;

    // Solid multi-byte text without any newline forces hard cuts.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..send_message_limit * 2) |_| {
        try text.appendSlice(allocator, "🌊");
    }

    const parts = try splitMessage(allocator, text.items);
    defer freeParts(allocator, parts);
    try std.testing.expect(parts.len > 1);

    var waves: usize = 0;
    for (parts) |part| {
        try testing.expect(part.len <= send_message_limit);
        try testing.expect(std.unicode.utf8ValidateSlice(part));
        waves += std.mem.count(u8, part, "🌊");
    }
    try testing.expectEqual(@as(usize, send_message_limit * 2), waves);
}

test "splitMessage keeps short replies whole and splits long ones" {
    const allocator = std.testing.allocator;

    // Short reply stays whole.
    const single = try splitMessage(allocator, "short");
    defer freeParts(allocator, single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("short", single[0]);

    // Long reply splits at a newline boundary; reassembly is lossless and
    // every part fits the limit.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    for (0..send_message_limit / 40 + 4) |index| {
        try long.appendSlice(allocator, "x" ** 39);
        try long.append(allocator, '\n');
        try long.append(allocator, 'a' + @as(u8, @intCast(index % 26)));
    }
    const parts = try splitMessage(allocator, long.items);
    defer freeParts(allocator, parts);
    try std.testing.expect(parts.len > 1);
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(allocator);
    for (parts) |part| {
        try std.testing.expect(part.len <= send_message_limit);
        try rebuilt.appendSlice(allocator, part);
    }
    try std.testing.expectEqualStrings(long.items, rebuilt.items);

    // Without any newline, the fallback is a hard cut at the limit.
    const solid = try allocator.alloc(u8, send_message_limit * 2 + 10);
    defer allocator.free(solid);
    @memset(solid, 'z');
    const hard = try splitMessage(allocator, solid);
    defer freeParts(allocator, hard);
    try std.testing.expectEqual(@as(usize, 3), hard.len);
    for (hard[0..2]) |part| try std.testing.expectEqual(send_message_limit, part.len);
    try std.testing.expectEqual(@as(usize, 10), hard[2].len);
}

test "checkApiOk validates envelopes and rejects failures" {
    const allocator = std.testing.allocator;

    try checkApiOk(allocator, "{\"ok\":true,\"result\":[]}");
    try std.testing.expectError(error.ApiRequestFailed, checkApiOk(allocator, "{\"ok\":false,\"description\":\"Bad Request: chat not found\"}"));
    try std.testing.expectError(error.InvalidResponse, checkApiOk(allocator, "gateway timeout html"));
}

test "runtime shutdown flag is settable and readable" {
    try std.testing.expect(!shutdownRequested());
    requestShutdown();
    try std.testing.expect(shutdownRequested());
    shutdown_requested.store(false, .release);
    try std.testing.expect(!shutdownRequested());
}
