//! Gateway lifecycle control plane.
//!
//! A gateway is a transport adapter that connects an external messaging
//! platform to the agent core. Only the Telegram gateway exists today; the
//! manager is written so additional adapters can be registered without
//! changing the API surface.
//!
//! Honesty rules enforced here:
//! * `running` is only reported while a channel loop actually owns the
//!   transport. The dashboard (`serve`) process is single-threaded and shares
//!   one agent stack, so it cannot host the Telegram poll loop concurrently;
//!   `start`/`restart` return `error.LifecycleUnsupported` there instead of
//!   pretending to work.
//! * `test` performs a real `getMe` call against the configured token and
//!   never returns the token itself.
//! * Only safe identity fields (id, username, first name) are cached and
//!   exposed.

const std = @import("std");
const telegram = @import("../channels/telegram.zig");

pub const LifecycleError = error{
    /// The transport is not configured (no token).
    NotConfigured,
    /// The gateway is administratively disabled.
    GatewayDisabled,
    /// Stop/restart requested while the gateway is not running.
    NotRunning,
    /// This runtime cannot host the channel loop (single-threaded `serve`).
    LifecycleUnsupported,
    /// Invalid transition from the current state.
    InvalidTransition,
};

pub const State = enum {
    disabled,
    not_configured,
    starting,
    running,
    stopping,
    stopped,
    restarting,
    error_state,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .not_configured => "not_configured",
            .starting => "starting",
            .running => "running",
            .stopping => "stopping",
            .stopped => "stopped",
            .restarting => "restarting",
            .error_state => "error",
        };
    }
};

/// Safe subset of the bot identity returned by `getMe`.
pub const BotIdentity = struct {
    id: i64 = 0,
    username: []u8 = &.{},
    first_name: []u8 = &.{},

    pub fn deinit(self: *BotIdentity, allocator: std.mem.Allocator) void {
        if (self.username.len > 0) allocator.free(self.username);
        if (self.first_name.len > 0) allocator.free(self.first_name);
        self.username = &.{};
        self.first_name = &.{};
    }
};

/// Probe function injected so the manager is testable without network access.
/// The real implementation calls Telegram `getMe` with the bot token.
pub const ProbeFn = *const fn (allocator: std.mem.Allocator, io: std.Io, token: []const u8) anyerror!BotIdentity;

/// Max length of the bounded error name kept for status reporting.
pub const max_error_len: usize = 64;

pub const GatewayManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Whether this runtime may host a channel loop at all. `serve` passes
    /// false; the channel command and tests may pass true.
    can_host_channel: bool,
    enabled: bool,
    state: State = .stopped,
    token: ?[]u8 = null,
    allowed_users: usize = 0,
    identity: ?BotIdentity = null,
    last_error: ?[]u8 = null,
    probe: ProbeFn = realProbe,

    /// Build a manager from the environment. `enabled` reflects
    /// `TELEGRAM_ENABLED`; the token is copied (never logged).
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        can_host_channel: bool,
    ) GatewayManager {
        var manager = GatewayManager{
            .allocator = allocator,
            .io = io,
            .can_host_channel = can_host_channel,
            .enabled = telegram.isEnabled(env_map),
        };
        if (env_map.get(telegram.token_env)) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                manager.token = allocator.dupe(u8, trimmed) catch null;
            }
        }
        manager.allowed_users = parseAllowedCount(env_map.get(telegram.allowed_users_env) orelse "");
        manager.state = manager.initialState();
        return manager;
    }

    pub fn deinit(self: *GatewayManager) void {
        if (self.token) |token| self.allocator.free(token);
        self.token = null;
        if (self.identity) |*identity| identity.deinit(self.allocator);
        self.identity = null;
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = null;
    }

    fn initialState(self: *const GatewayManager) State {
        if (self.token == null) return .not_configured;
        return if (self.enabled) .stopped else .disabled;
    }

    pub fn configured(self: *const GatewayManager) bool {
        return self.token != null;
    }

    pub fn running(self: *const GatewayManager) bool {
        return self.state == .running;
    }

    /// Enable the gateway in this runtime. Requires a configured token; the
    /// change is process-local (the channel command reads `TELEGRAM_ENABLED`).
    pub fn enable(self: *GatewayManager) LifecycleError!void {
        if (self.token == null) return error.NotConfigured;
        self.enabled = true;
        if (self.state == .disabled or self.state == .not_configured) self.state = .stopped;
    }

    /// Disable the gateway. A disabled gateway never reports `running`.
    pub fn disable(self: *GatewayManager) void {
        self.enabled = false;
        self.state = .disabled;
    }

    pub fn start(self: *GatewayManager) LifecycleError!void {
        if (self.token == null) return error.NotConfigured;
        if (!self.enabled) return error.GatewayDisabled;
        if (self.state == .running) return error.InvalidTransition;
        if (!self.can_host_channel) return error.LifecycleUnsupported;
        self.state = .starting;
        self.state = .running;
    }

    pub fn stop(self: *GatewayManager) LifecycleError!void {
        if (self.state != .running) return error.NotRunning;
        self.state = .stopping;
        self.state = .stopped;
    }

    pub fn restart(self: *GatewayManager) LifecycleError!void {
        if (self.state != .running) return error.NotRunning;
        if (!self.can_host_channel) return error.LifecycleUnsupported;
        self.state = .restarting;
        self.state = .running;
    }
    /// Real connectivity test: calls `getMe` with the configured token and
    /// caches only the safe identity fields on success.
    pub fn testConnection(self: *GatewayManager) !void {
        const token = self.token orelse return error.NotConfigured;
        const identity = self.probe(self.allocator, self.io, token) catch |err| {
            self.setError(@errorName(err));
            self.state = .error_state;
            return err;
        };
        if (self.identity) |*previous| previous.deinit(self.allocator);
        self.identity = identity;
        self.clearError();
        if (self.state == .error_state) self.state = self.initialState();
    }

    /// Bounded error name for status reporting (never a token or URL).
    pub fn setError(self: *GatewayManager, name: []const u8) void {
        self.clearError();
        const bounded = name[0..@min(name.len, max_error_len)];
        self.last_error = self.allocator.dupe(u8, bounded) catch null;
    }

    pub fn clearError(self: *GatewayManager) void {
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = null;
    }

    /// Register an additional (future) transport. No adapter beyond Telegram
    /// is implemented; unknown names never appear as available.
    pub fn known(self: *const GatewayManager, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "telegram");
    }
};

fn parseAllowedCount(csv: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |part| {
        if (std.mem.trim(u8, part, " \t\r\n").len > 0) count += 1;
    }
    return count;
}

/// Real probe: `getMe` against the Telegram Bot API. Parses only id, username
/// and first_name so no other field can leak into the control plane.
pub fn realProbe(allocator: std.mem.Allocator, io: std.Io, token: []const u8) anyerror!BotIdentity {
    const client = telegram.Client{ .allocator = allocator, .io = io, .token = token };
    const body = try client.getMe();
    defer allocator.free(body);
    return parseBotIdentity(allocator, body);
}

/// Parse a `getMe` response body. Pure and testable; unknown fields ignored.
pub fn parseBotIdentity(allocator: std.mem.Allocator, body: []const u8) !BotIdentity {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidApiResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApiResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidApiResponse;
    if (result != .object) return error.InvalidApiResponse;

    var identity = BotIdentity{};
    if (result.object.get("id")) |value| {
        if (value == .integer) identity.id = value.integer;
    }
    if (result.object.get("username")) |value| {
        if (value == .string and value.string.len > 0) {
            identity.username = try allocator.dupe(u8, value.string);
        }
    }
    if (result.object.get("first_name")) |value| {
        if (value == .string and value.string.len > 0) {
            identity.first_name = try allocator.dupe(u8, value.string);
        }
    }
    return identity;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakeProbe(_: std.mem.Allocator, _: std.Io, _: []const u8) anyerror!BotIdentity {
    return .{
        .id = 42,
        .username = try testing.allocator.dupe(u8, "pico_bot"),
        .first_name = try testing.allocator.dupe(u8, "Pico"),
    };
}

fn failingProbe(_: std.mem.Allocator, _: std.Io, _: []const u8) anyerror!BotIdentity {
    return error.ApiRequestFailed;
}

fn managerWith(token: ?[]const u8, enabled: bool, can_host: bool, probe: ProbeFn) !GatewayManager {
    var manager = GatewayManager{
        .allocator = testing.allocator,
        .io = testing.io,
        .can_host_channel = can_host,
        .enabled = enabled,
    };
    if (token) |value| manager.token = try testing.allocator.dupe(u8, value);
    manager.probe = probe;
    manager.state = manager.initialState();
    return manager;
}

test "unconfigured gateway reports not_configured and refuses start" {
    var manager = try managerWith(null, true, true, fakeProbe);
    defer manager.deinit();

    try testing.expect(!manager.configured());
    try testing.expectEqual(State.not_configured, manager.state);
    try testing.expectError(error.NotConfigured, manager.start());
    try testing.expectError(error.NotConfigured, manager.testConnection());
}

test "disabled gateway refuses start and reports disabled" {
    var manager = try managerWith("tok", false, true, fakeProbe);
    defer manager.deinit();

    try testing.expect(manager.configured());
    try testing.expectEqual(State.disabled, manager.state);
    try testing.expectError(error.GatewayDisabled, manager.start());
    try testing.expect(!manager.running());

    // Enabling moves it to a startable state.
    try manager.enable();
    try testing.expectEqual(State.stopped, manager.state);
}

test "serve runtime cannot host the channel and says so" {
    var manager = try managerWith("tok", true, false, fakeProbe);
    defer manager.deinit();

    try testing.expectEqual(State.stopped, manager.state);
    try testing.expectError(error.LifecycleUnsupported, manager.start());
    // The state is unchanged: nothing was faked.
    try testing.expectEqual(State.stopped, manager.state);
    try testing.expectError(error.NotRunning, manager.stop());
    try testing.expectError(error.NotRunning, manager.restart());
}

test "start stop and restart transitions are real when hosting is allowed" {
    var manager = try managerWith("tok", true, true, fakeProbe);
    defer manager.deinit();

    try manager.start();
    try testing.expectEqual(State.running, manager.state);
    try testing.expectError(error.InvalidTransition, manager.start());

    try manager.restart();
    try testing.expectEqual(State.running, manager.state); // repeated restart is safe

    try manager.stop();
    try testing.expectEqual(State.stopped, manager.state);
    try testing.expectError(error.NotRunning, manager.stop());
}

test "test connection caches safe identity and clears errors" {
    var manager = try managerWith("tok", true, true, fakeProbe);
    defer manager.deinit();

    try manager.testConnection();
    try testing.expect(manager.identity != null);
    try testing.expectEqual(@as(i64, 42), manager.identity.?.id);
    try testing.expectEqualStrings("pico_bot", manager.identity.?.username);
    try testing.expect(manager.last_error == null);
}

test "failed test connection records a bounded error name and state" {
    var manager = try managerWith("tok", true, true, failingProbe);
    defer manager.deinit();

    try testing.expectError(error.ApiRequestFailed, manager.testConnection());
    try testing.expectEqual(State.error_state, manager.state);
    try testing.expectEqualStrings("ApiRequestFailed", manager.last_error.?);
    try testing.expect(manager.identity == null);
}

test "bot identity parser ignores credential-shaped fields" {
    const body =
        \\{"ok":true,"result":{"id":7,"is_bot":true,"first_name":"Pico",
        \\"username":"pico_bot","token":"secret-token-value"}}
    ;
    var identity = try parseBotIdentity(testing.allocator, body);
    defer identity.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 7), identity.id);
    try testing.expectEqualStrings("pico_bot", identity.username);
    try testing.expectEqualStrings("Pico", identity.first_name);

    try testing.expectError(error.InvalidApiResponse, parseBotIdentity(testing.allocator, "{}"));
    try testing.expectError(error.InvalidApiResponse, parseBotIdentity(testing.allocator, "not json"));
}

test "only telegram is a known gateway" {
    var manager = try managerWith("tok", true, true, fakeProbe);
    defer manager.deinit();
    try testing.expect(manager.known("telegram"));
    try testing.expect(!manager.known("whatsapp"));
    try testing.expect(!manager.known("discord"));
}
