//! MCP server configuration: a validated, secret-safe model.
//!
//! Deny by default: with no `config/mcp.json` nothing runs; with a config
//! file, a server only becomes startable when it is explicitly `enabled`.
//! Processes are always described as a structured executable plus an
//! argument array — never a shell string — so there is no interpolation step
//! to inject into.
//!
//! Environment values passed to MCP servers are accepted for spawning but
//! are never rendered anywhere: every JSON/reporting surface exposes names
//! only (the same rule the sandbox applies to `env_allowlist`).

const std = @import("std");

pub const default_path = "config/mcp.json";

/// Hard bounds. Configuration cannot request more than these; they are the
/// outer envelope, not tunables.
pub const max_servers: usize = 16;
pub const max_args: usize = 32;
pub const max_command_len: usize = 1024;
pub const max_arg_len: usize = 4096;
pub const max_env_vars: usize = 32;
pub const max_env_name_len: usize = 256;
pub const max_env_value_len: usize = 8192;
pub const max_id_len: usize = 32;

pub const min_timeout_ms: u64 = 1_000;
pub const max_timeout_ms: u64 = 120_000;

/// Permission tier an MCP tool requires in the shared ToolRegistry. MCP
/// tools default to `elevated` because every call runs code in an external
/// process; operators may lower this to `standard` per server in config.
pub const Permission = enum {
    standard,
    network,
    elevated,

    pub fn fromName(text: []const u8) ?Permission {
        inline for (@typeInfo(Permission).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn name(self: Permission) []const u8 {
        return @tagName(self);
    }
};

pub const ParseError = error{
    InvalidConfig,
    DuplicateServerId,
} || std.mem.Allocator.Error;

/// One validated MCP server definition. All strings are owned.
pub const ServerConfig = struct {
    /// Stable identifier used in tool names (`mcp.<id>.<tool>`) and the API.
    /// Restricted to `[a-z0-9_-]` so tool names stay unambiguous.
    id: []u8,
    /// Executable path or name. Spawned directly; never passed to a shell.
    command: []u8,
    /// Argument array (no shell, no interpolation).
    args: [][]u8,
    /// Environment variable names and values handed to the child. Values are
    /// never logged, rendered, or persisted anywhere except the config file
    /// the operator wrote.
    env_names: [][]u8,
    env_values: [][]u8,
    enabled: bool = false,
    /// Start automatically when the runtime boots. Defaults to false: even
    /// an enabled server does not run until it is started explicitly or here.
    auto_start: bool = false,
    /// Per-request timeout (initialize, tools/list, tools/call).
    timeout_ms: u64 = 10_000,
    permission: Permission = .elevated,

    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.command);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        for (self.env_names) |name| allocator.free(name);
        allocator.free(self.env_names);
        for (self.env_values) |value| allocator.free(value);
        allocator.free(self.env_values);
        self.* = undefined;
    }
};

/// Whole-file configuration. `enabled: false` disables MCP entirely even if
/// servers are listed — the outer kill switch.
pub const Config = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    servers: []ServerConfig = &.{},

    pub fn deinit(self: *Config) void {
        for (self.servers) |*server| server.deinit(self.allocator);
        self.allocator.free(self.servers);
        self.* = undefined;
    }

    pub fn serverById(self: *const Config, id: []const u8) ?*const ServerConfig {
        for (self.servers) |*server| {
            if (std.mem.eql(u8, server.id, id)) return server;
        }
        return null;
    }
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

/// Server ids become tool-name components: lowercase, unambiguous, short.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Structured executable: non-empty, bounded, no control characters. No
/// shell is ever involved, so no metacharacter needs escaping — control
/// characters are still refused because no legitimate program name has one.
pub fn validCommand(command: []const u8) bool {
    if (command.len == 0 or command.len > max_command_len) return false;
    return !hasControlChar(command);
}

pub fn hasControlChar(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

/// Environment variable names: printable ASCII, no '=' or NUL, no leading digit.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_env_name_len) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |c| {
        if (c < 0x21 or c > 0x7e or c == '=') return false;
    }
    return true;
}

/// Validate and take ownership of one raw JSON object describing a server.
/// Every rule failure is reported as `error.InvalidConfig`; callers surface
/// the field name in their own messages.
pub fn parseServer(allocator: std.mem.Allocator, value: std.json.Value) ParseError!ServerConfig {
    if (value != .object) return error.InvalidConfig;
    const object = value.object;

    const id_raw = stringField(object, "id") orelse return error.InvalidConfig;
    if (!validId(id_raw)) return error.InvalidConfig;
    const id = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(id);

    const command_raw = stringField(object, "command") orelse return error.InvalidConfig;
    if (!validCommand(command_raw)) return error.InvalidConfig;
    const command = try allocator.dupe(u8, command_raw);
    errdefer allocator.free(command);

    // Arguments: a JSON array of strings. Anything else is rejected — a
    // single string would invite shell-style concatenation.
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    if (object.get("args")) |args_value| {
        if (args_value != .array) return error.InvalidConfig;
        if (args_value.array.items.len > max_args) return error.InvalidConfig;
        for (args_value.array.items) |item| {
            if (item != .string) return error.InvalidConfig;
            const arg = item.string;
            if (arg.len > max_arg_len or hasControlChar(arg)) return error.InvalidConfig;
            try args.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Environment: object of name -> value. Names are validated like real
    // environment variables; values are stored but never rendered.
    var env_names: std.ArrayList([]u8) = .empty;
    var env_values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (env_names.items) |entry_name| allocator.free(entry_name);
        env_names.deinit(allocator);
        for (env_values.items) |entry_value| allocator.free(entry_value);
        env_values.deinit(allocator);
    }
    if (object.get("env")) |env_value| {
        if (env_value != .object) return error.InvalidConfig;
        if (env_value.object.count() > max_env_vars) return error.InvalidConfig;
        var iterator = env_value.object.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!validEnvName(name)) return error.InvalidConfig;
            const env_val = entry.value_ptr.*;
            if (env_val != .string) return error.InvalidConfig;
            if (env_val.string.len > max_env_value_len or hasControlChar(env_val.string))
                return error.InvalidConfig;
            try env_names.append(allocator, try allocator.dupe(u8, name));
            try env_values.append(allocator, try allocator.dupe(u8, env_val.string));
        }
    }

    var timeout_ms: u64 = 10_000;
    if (object.get("timeout_ms")) |timeout_value| {
        if (timeout_value != .integer) return error.InvalidConfig;
        if (timeout_value.integer < 0) return error.InvalidConfig;
        timeout_ms = std.math.clamp(
            @as(u64, @intCast(timeout_value.integer)),
            min_timeout_ms,
            max_timeout_ms,
        );
    }

    var permission: Permission = .elevated;
    if (object.get("permission")) |permission_value| {
        if (permission_value != .string) return error.InvalidConfig;
        permission = Permission.fromName(permission_value.string) orelse return error.InvalidConfig;
    }

    const enabled = boolField(object, "enabled") orelse false;
    const auto_start = boolField(object, "auto_start") orelse false;

    return .{
        .id = id,
        .command = command,
        .args = try args.toOwnedSlice(allocator),
        .env_names = try env_names.toOwnedSlice(allocator),
        .env_values = try env_values.toOwnedSlice(allocator),
        .enabled = enabled,
        .auto_start = auto_start,
        .timeout_ms = timeout_ms,
        .permission = permission,
    };
}

/// Parse a whole `config/mcp.json` document.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) ParseError!Config {
    // The JSON tree is scratch: an arena scopes it so nothing leaks, while
    // the returned Config owns every string with the caller's allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), contents, .{}) catch
        return error.InvalidConfig;
    if (value != .object) return error.InvalidConfig;
    const object = value.object;

    const enabled = boolField(object, "enabled") orelse false;

    var servers: std.ArrayList(ServerConfig) = .empty;
    errdefer {
        for (servers.items) |*server| server.deinit(allocator);
        servers.deinit(allocator);
    }

    if (object.get("servers")) |servers_value| {
        if (servers_value != .array) return error.InvalidConfig;
        if (servers_value.array.items.len > max_servers) return error.InvalidConfig;
        for (servers_value.array.items) |server_value| {
            var server = try parseServer(allocator, server_value);
            errdefer server.deinit(allocator);
            for (servers.items) |*existing| {
                if (std.mem.eql(u8, existing.id, server.id)) return error.DuplicateServerId;
            }
            try servers.append(allocator, server);
        }
    }

    return .{
        .allocator = allocator,
        .enabled = enabled,
        .servers = try servers.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectInvalidConfig(json: []const u8) !void {
    try testing.expectError(error.InvalidConfig, parse(testing.allocator, json));
}

test "config parses an enabled server with args and env" {
    const json =
        \\{"enabled":true,"servers":[{"id":"demo","command":"C:/srv/mcp.exe",
        \\"args":["--quiet"],"env":{"DEMO_TOKEN":"secret-value"},"enabled":true,
        \\"timeout_ms":5000,"permission":"standard","auto_start":true}]}
    ;
    var config = try parse(testing.allocator, json);
    defer config.deinit();

    try testing.expect(config.enabled);
    try testing.expectEqual(@as(usize, 1), config.servers.len);
    const server = &config.servers[0];
    try testing.expectEqualStrings("demo", server.id);
    try testing.expectEqualStrings("--quiet", server.args[0]);
    try testing.expectEqual(@as(usize, 1), server.env_names.len);
    try testing.expectEqualStrings("DEMO_TOKEN", server.env_names[0]);
    try testing.expectEqualStrings("secret-value", server.env_values[0]);
    try testing.expectEqual(@as(u64, 5000), server.timeout_ms);
    try testing.expectEqual(Permission.standard, server.permission);
    try testing.expect(server.enabled and server.auto_start);
    try testing.expect(config.serverById("demo") != null);
    try testing.expect(config.serverById("ghost") == null);
}

test "config defaults are deny-by-default" {
    var config = try parse(testing.allocator,
        \\{"servers":[{"id":"a","command":"mcp-server"}]}
    );
    defer config.deinit();

    try testing.expect(!config.enabled);
    try testing.expect(!config.servers[0].enabled);
    try testing.expect(!config.servers[0].auto_start);
    try testing.expectEqual(Permission.elevated, config.servers[0].permission);
    try testing.expectEqual(@as(u64, 10_000), config.servers[0].timeout_ms);
}

test "config rejects invalid servers" {
    const cases = [_][]const u8{
        "not json",
        "[]",
        "{\"servers\":[{\"command\":\"x\"}]}",
        "{\"servers\":[{\"id\":\"a\"}]}",
        "{\"servers\":[{\"id\":\"Big\",\"command\":\"x\"}]}",
        "{\"servers\":[{\"id\":\"a b\",\"command\":\"x\"}]}",
        "{\"servers\":[{\"id\":\"\",\"command\":\"x\"}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"\"}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"args\":\"--flag\"}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"args\":[1]}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"env\":{\"K\":1}}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"env\":{\"A=B\":\"v\"}}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"timeout_ms\":-5}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"timeout_ms\":\"soon\"}]}",
        "{\"servers\":[{\"id\":\"a\",\"command\":\"x\",\"permission\":\"root\"}]}",
        "{\"servers\":{}}",
    };
    for (cases) |case| {
        try expectInvalidConfig(case);
    }
    try testing.expectError(error.DuplicateServerId, parse(testing.allocator,
        \\{"servers":[{"id":"a","command":"x"},{"id":"a","command":"y"}]}
    ));
}

test "config rejects control characters in commands and args" {
    // Built with format so the source file itself stays free of raw control bytes.
    const with_newline = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"servers\":[{{\"id\":\"a\",\"command\":\"x{c}y\"}}]}}",
        .{@as(u8, 0x0a)},
    );
    defer testing.allocator.free(with_newline);
    try expectInvalidConfig(with_newline);
}

test "config clamps timeout into the documented range" {
    var config = try parse(testing.allocator,
        \\{"servers":[{"id":"a","command":"x","timeout_ms":10},{"id":"b","command":"y","timeout_ms":600000}]}
    );
    defer config.deinit();
    try testing.expectEqual(min_timeout_ms, config.servers[0].timeout_ms);
    try testing.expectEqual(max_timeout_ms, config.servers[1].timeout_ms);
}

test "validId and validEnvName enforce their alphabets" {
    try testing.expect(validId("demo-1_a"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("UPPER"));
    try testing.expect(!validId("with/slash"));
    try testing.expect(validEnvName("PATH"));
    try testing.expect(validEnvName("A_1"));
    try testing.expect(!validEnvName(""));
    try testing.expect(!validEnvName("A=B"));
    try testing.expect(!validEnvName("1A"));
    try testing.expect(!validEnvName("A B"));
}

test "config caps the number of servers" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;
    try writer.writeAll("{\"servers\":[");
    for (0..max_servers + 1) |index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":\"s{d}\",\"command\":\"x\"}}", .{index});
    }
    try writer.writeAll("]}");
    try expectInvalidConfig(buffer.written());
}
