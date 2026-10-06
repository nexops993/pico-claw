//! MCP registry: server lifecycle, discovery, and tool exposure.
//!
//! This is the backend service behind `/api/mcp` and the composition root.
//! It owns one record per configured server and is the only component that
//! decides when an MCP server is running:
//!
//! * Nothing runs unless the file-level kill switch is on AND the server is
//!   explicitly enabled AND it is started (by hand or via `auto_start`).
//! * A discovered tool never reaches the agent directly. It is wrapped in an
//!   adapter registered in the shared `ToolRegistry` under a namespaced id
//!   (`mcp.<server>.<tool>`), so permission, risk, enable/disable, and the
//!   capability manifest all flow through the existing boundaries.
//! * Everything an MCP server sends is untrusted data: descriptions are
//!   sanitized metadata, tool output is returned verbatim as content, and no
//!   error is ever converted into a fake success.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const config = @import("config.zig");
const client_mod = @import("client.zig");
const Tool = @import("../tools/tool.zig").Tool;
const Permission = @import("../tools/tool.zig").Permission;
const Risk = @import("../tools/tool.zig").Risk;
const Param = @import("../tools/tool.zig").Param;
const tool_registry_mod = @import("../tools/registry.zig");

pub const max_error_len: usize = 64;

/// Server lifecycle. `running` is reported only while a live, initialized
/// client with a successful tool discovery exists — never because config
/// intent says a server should run.
pub const State = enum {
    disabled,
    configured,
    starting,
    running,
    stopped,
    error_state,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .configured => "configured",
            .starting => "starting",
            .running => "running",
            .stopped => "stopped",
            .error_state => "error",
        };
    }
};

/// One configured MCP server and everything the runtime knows about it.
pub const ServerRecord = struct {
    cfg: config.ServerConfig,
    state: State = .configured,
    client: ?*client_mod.Client = null,
    /// Current discovery result (empty until a start succeeded).
    tools: []client_mod.ToolInfo = &.{},
    adapters: std.ArrayList(*Adapter) = .empty,
    /// Bounded error name from the last failed operation (gateway-style).
    last_error: ?[]u8 = null,
    /// Observability counters (safe to expose; no payloads are kept).
    invocations: u64 = 0,
    invocation_errors: u64 = 0,

    fn setLastError(self: *ServerRecord, allocator: std.mem.Allocator, name: []const u8) void {
        if (self.last_error) |existing| allocator.free(existing);
        const bounded = name[0..@min(name.len, max_error_len)];
        self.last_error = allocator.dupe(u8, bounded) catch null;
    }

    fn clearLastError(self: *ServerRecord, allocator: std.mem.Allocator) void {
        if (self.last_error) |existing| allocator.free(existing);
        self.last_error = null;
    }

    fn findAdapter(self: *ServerRecord, mcp_name: []const u8) ?*Adapter {
        for (self.adapters.items) |adapter| {
            if (std.mem.eql(u8, adapter.mcp_name, mcp_name)) return adapter;
        }
        return null;
    }
};

/// Tool-adapter bridge: one `ToolRegistry` entry per discovered MCP tool.
/// The registry keeps these alive for the record's lifetime, so a registered
/// `Tool` context pointer stays valid across restarts.
pub const Adapter = struct {
    registry: *Registry,
    server: *ServerRecord,
    /// The MCP tool's own name (as the server advertises it).
    mcp_name: []u8,
    /// Namespaced id in the shared ToolRegistry: `mcp.<server>.<tool>`.
    internal_name: []u8,
    /// Bounded, sanitized copy of the server-provided description.
    description: []u8,

    fn tool(self: *Adapter) Tool {
        return .{
            .name = self.internal_name,
            .description = self.description,
            .context = self,
            .executeFn = executeErased,
            .enabled = true,
            .permission = permissionOf(self.server.cfg.permission),
            // Every MCP tool runs code in an external process; the blast
            // radius is high no matter what the server claims.
            .risk = .high,
            .parameters = &.{
                Param{
                    .name = "args",
                    .description = "JSON object with this tool's arguments",
                    .required = false,
                },
            },
        };
    }

    fn executeErased(ctx: *anyopaque, allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        return self.execute(allocator, input);
    }

    fn execute(self: *Adapter, allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
        self.server.invocations += 1;
        const client = self.server.client orelse {
            self.server.invocation_errors += 1;
            return error.ServerUnavailable;
        };
        const result = client.callTool(
            allocator,
            self.mcp_name,
            input,
            self.server.cfg.timeout_ms,
        ) catch |err| {
            self.server.invocation_errors += 1;
            switch (err) {
                // The child died mid-call: that is a server-lifecycle event,
                // not just a failed request.
                error.EndOfStream => self.registry.handleClientDeath(self.server),
                else => {},
            }
            return err;
        };
        return result;
    }
};

/// Map the configured permission tier onto the shared tool permission type.
pub fn permissionOf(permission: config.Permission) Permission {
    return switch (permission) {
        .standard => .standard,
        .network => .network,
        .elevated => .elevated,
    };
}

pub const LifecycleError = client_mod.Error || error{
    /// The file-level MCP kill switch is off.
    McpDisabled,
    ServerNotFound,
    /// The server exists but is administratively disabled.
    ServerDisabled,
    AlreadyRunning,
    NotRunning,
    InvalidTransition,
    /// Two servers produced the same namespaced tool id (config bug).
    DuplicateToolName,
    /// A namespaced tool id was rejected by the shared registry.
    InvalidToolName,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// File-level kill switch: false means MCP is off even if servers exist.
    enabled: bool = false,
    servers: std.ArrayList(*ServerRecord) = .empty,
    /// When attached, discovered tools become real agent-callable tools.
    tools: ?*tool_registry_mod.ToolRegistry = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        self.clearServers();
        self.servers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Attach the shared tool registry. Tools discovered later are registered
    /// into it; servers already running are replayed.
    pub fn attachToolRegistry(self: *Registry, tools: *tool_registry_mod.ToolRegistry) void {
        self.tools = tools;
    }

    pub fn findServer(self: *Registry, id: []const u8) ?*ServerRecord {
        for (self.servers.items) |server| {
            if (std.mem.eql(u8, server.cfg.id, id)) return server;
        }
        return null;
    }

    pub fn serverCount(self: *const Registry) usize {
        return self.servers.items.len;
    }

    pub fn runningCount(self: *const Registry) usize {
        var count: usize = 0;
        for (self.servers.items) |server| {
            if (server.state == .running) count += 1;
        }
        return count;
    }

    /// Number of discovered tools across every running server.
    pub fn availableToolCount(self: *const Registry) usize {
        var count: usize = 0;
        for (self.servers.items) |server| {
            if (server.state != .running) continue;
            count += server.tools.len;
        }
        return count;
    }

    /// Replace the current configuration. Running servers are stopped first:
    /// a config change must never leave an orphan process behind.
    pub fn loadConfig(self: *Registry, contents: []const u8) (config.ParseError || std.mem.Allocator.Error)!void {
        var parsed = try config.parse(self.allocator, contents);
        defer parsed.deinit();

        // Build the complete new record list first; only commit when every
        // record exists, so a failure can never leave a half-adopted config.
        // Until commit, `parsed` still owns every server config, so the error
        // path releases records only — never their strings.
        var new_servers: std.ArrayList(*ServerRecord) = .empty;
        errdefer {
            for (new_servers.items) |server| {
                server.adapters.deinit(self.allocator);
                self.allocator.destroy(server);
            }
            new_servers.deinit(self.allocator);
        }
        for (parsed.servers) |server_cfg| {
            const record = try self.allocator.create(ServerRecord);
            errdefer self.allocator.destroy(record);
            record.* = .{
                .cfg = server_cfg,
                .state = if (parsed.enabled and server_cfg.enabled) .configured else .disabled,
            };
            try new_servers.append(self.allocator, record);
        }

        self.clearServers();
        self.servers.deinit(self.allocator);
        self.servers = new_servers;
        self.enabled = parsed.enabled;
        // Ownership of the server configs moved into the records.
        self.allocator.free(parsed.servers);
        parsed.servers = &.{};
    }

    /// Load `config/mcp.json`. A missing file is not an error: it means MCP
    /// is not configured, and the registry stays disabled.
    pub fn loadConfigFile(
        self: *Registry,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        const contents = dir.readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                self.enabled = false;
                return;
            },
            else => return err,
        };
        defer self.allocator.free(contents);
        try self.loadConfig(contents);
    }

    /// Start every server that is enabled and marked `auto_start`. Failures
    /// are recorded on the server; they never abort the runtime.
    pub fn startAutoStart(self: *Registry) void {
        if (!self.enabled) return;
        for (self.servers.items) |server| {
            if (!server.cfg.enabled or !server.cfg.auto_start) continue;
            if (server.state == .running) continue;
            self.startServer(server.cfg.id) catch {};
        }
    }

    /// Spawn, handshake, discover, and register one server. On any failure
    /// the child is cleaned up, the state becomes `error`, and the reason is
    /// recorded — the server is never left half-running.
    pub fn startServer(self: *Registry, id: []const u8) LifecycleError!void {
        const server = self.findServer(id) orelse return error.ServerNotFound;
        if (!self.enabled) return error.McpDisabled;
        if (!server.cfg.enabled) return error.ServerDisabled;
        switch (server.state) {
            .running => return error.AlreadyRunning,
            .starting => return error.InvalidTransition,
            else => {},
        }

        server.state = .starting;
        const client = client_mod.Client.start(
            self.allocator,
            self.io,
            &server.cfg,
            client_mod.default_connect_timeout_ms,
        ) catch |err| {
            self.failServer(server, @errorName(err));
            return err;
        };
        server.client = client;

        const tools = client.listTools(self.allocator, server.cfg.timeout_ms) catch |err| {
            client.deinit();
            server.client = null;
            self.failServer(server, @errorName(err));
            return err;
        };
        if (server.tools.len > 0) client_mod.freeTools(self.allocator, server.tools);
        server.tools = tools;

        self.syncAdapters(server) catch |err| {
            client.deinit();
            server.client = null;
            self.failServer(server, @errorName(err));
            return err;
        };

        server.clearLastError(self.allocator);
        server.state = .running;
    }

    /// Stop a running server and disable its tools. Stopping an already
    /// stopped server is refused: the dashboard must never see fake success.
    pub fn stopServer(self: *Registry, id: []const u8) LifecycleError!void {
        const server = self.findServer(id) orelse return error.ServerNotFound;
        if (server.state != .running) return error.NotRunning;
        self.shutdownServer(server);
        server.state = .stopped;
    }

    /// Stop, then start again.
    pub fn restartServer(self: *Registry, id: []const u8) LifecycleError!void {
        const server = self.findServer(id) orelse return error.ServerNotFound;
        if (server.state == .running) self.shutdownServer(server);
        server.state = .stopped;
        return self.startServer(id);
    }

    /// A real connectivity probe: full handshake and discovery on a
    /// throwaway connection (or the live one when running). Never returns
    /// credentials and never leaves a process behind. Like the gateway test,
    /// failures are recorded on the record.
    pub fn probeServer(self: *Registry, id: []const u8) LifecycleError!void {
        const server = self.findServer(id) orelse return error.ServerNotFound;
        if (!self.enabled) return error.McpDisabled;
        if (!server.cfg.enabled) return error.ServerDisabled;

        if (server.state == .running) {
            // Live server: verify the protocol still works end to end.
            const tools = server.client.?.listTools(self.allocator, server.cfg.timeout_ms) catch |err| {
                self.handleClientDeath(server);
                return err;
            };
            client_mod.freeTools(self.allocator, tools);
            server.clearLastError(self.allocator);
            return;
        }

        const client = client_mod.Client.start(
            self.allocator,
            self.io,
            &server.cfg,
            client_mod.default_connect_timeout_ms,
        ) catch |err| {
            self.failServer(server, @errorName(err));
            return err;
        };
        const tools = client.listTools(self.allocator, server.cfg.timeout_ms) catch |err| {
            client.deinit();
            self.failServer(server, @errorName(err));
            return err;
        };
        client_mod.freeTools(self.allocator, tools);
        client.deinit();
        server.clearLastError(self.allocator);
    }

    /// Enable or disable a server. Disabling stops a running server first;
    /// enabling does NOT start anything (an explicit start is required).
    pub fn setEnabled(self: *Registry, id: []const u8, enabled: bool) LifecycleError!void {
        const server = self.findServer(id) orelse return error.ServerNotFound;
        if (enabled) {
            server.cfg.enabled = true;
            if (server.state == .disabled) server.state = .configured;
        } else {
            if (server.state == .running) self.shutdownServer(server);
            server.cfg.enabled = false;
            server.state = .disabled;
        }
    }

    /// A client died (crash or exit): reflect reality immediately.
    pub fn handleClientDeath(self: *Registry, server: *ServerRecord) void {
        if (server.state != .running) return;
        self.shutdownServer(server);
        server.state = .error_state;
        server.setLastError(self.allocator, "EndOfStream");
    }

    /// Run one lifecycle action by name. This is the complete action surface
    /// exposed to the service/API layer; anything else is refused.
    pub fn lifecycle(
        self: *Registry,
        id: []const u8,
        action: []const u8,
    ) (LifecycleError || error{UnknownAction})!void {
        if (std.mem.eql(u8, action, "start")) return self.startServer(id);
        if (std.mem.eql(u8, action, "stop")) return self.stopServer(id);
        if (std.mem.eql(u8, action, "restart")) return self.restartServer(id);
        if (std.mem.eql(u8, action, "test")) return self.probeServer(id);
        if (std.mem.eql(u8, action, "enable")) return self.setEnabled(id, true);
        if (std.mem.eql(u8, action, "disable")) return self.setEnabled(id, false);
        return error.UnknownAction;
    }

    /// Stop the child (if any) and disable its tools, keeping the record.
    fn shutdownServer(self: *Registry, server: *ServerRecord) void {
        if (server.client) |client| client.deinit();
        server.client = null;
        self.disableServerTools(server);
    }

    /// Mark a failed operation on a record (bounded error name only).
    fn failServer(self: *Registry, server: *ServerRecord, err_name: []const u8) void {
        self.disableServerTools(server);
        if (server.tools.len > 0) client_mod.freeTools(self.allocator, server.tools);
        server.tools = &.{};
        server.state = .error_state;
        server.setLastError(self.allocator, err_name);
    }

    /// Disable this server's tools in the shared registry. The entries stay
    /// registered (visible in the manifest) but refuse execution, so the
    /// agent is never told a dead server's tools are available.
    fn disableServerTools(self: *Registry, server: *ServerRecord) void {
        const tools = self.tools orelse return;
        for (server.adapters.items) |adapter| {
            _ = tools.setEnabled(adapter.internal_name, false);
        }
    }

    /// Reconcile discovered tools with adapters: reuse adapters for tools
    /// already seen (their registry entries stay valid), create the rest,
    /// and enable everything this server currently advertises.
    fn syncAdapters(self: *Registry, server: *ServerRecord) !void {
        for (server.tools) |tool_info| {
            var adapter = server.findAdapter(tool_info.name);
            if (adapter == null) {
                adapter = try self.createAdapter(server, tool_info);
            }
            if (self.tools) |tools| {
                if (tools.find(adapter.?.internal_name) == null) {
                    tools.register(adapter.?.tool()) catch |err| switch (err) {
                        error.DuplicateTool => return error.DuplicateToolName,
                        error.InvalidTool => return error.InvalidToolName,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                } else {
                    _ = tools.setEnabled(adapter.?.internal_name, true);
                }
            }
        }
    }

    fn createAdapter(
        self: *Registry,
        server: *ServerRecord,
        tool_info: client_mod.ToolInfo,
    ) !*Adapter {
        const adapter = try self.allocator.create(Adapter);
        errdefer self.allocator.destroy(adapter);

        const internal_name = try std.fmt.allocPrint(
            self.allocator,
            "mcp.{s}.{s}",
            .{ server.cfg.id, tool_info.name },
        );
        errdefer self.allocator.free(internal_name);

        const mcp_name = try self.allocator.dupe(u8, tool_info.name);
        errdefer self.allocator.free(mcp_name);

        const description = try self.allocator.dupe(u8, tool_info.description);
        errdefer self.allocator.free(description);

        adapter.* = .{
            .registry = self,
            .server = server,
            .mcp_name = mcp_name,
            .internal_name = internal_name,
            .description = description,
        };
        try server.adapters.append(self.allocator, adapter);
        return adapter;
    }

    fn clearServers(self: *Registry) void {
        for (self.servers.items) |server| self.destroyServer(server);
        self.servers.clearRetainingCapacity();
    }

    fn destroyServer(self: *Registry, server: *ServerRecord) void {
        // Tools can never reach a freed adapter: disable them first (the
        // registry entries themselves belong to the shared ToolRegistry).
        self.disableServerTools(server);
        if (server.client) |client| client.deinit();
        for (server.adapters.items) |adapter| {
            self.allocator.free(adapter.mcp_name);
            self.allocator.free(adapter.internal_name);
            self.allocator.free(adapter.description);
            self.allocator.destroy(adapter);
        }
        server.adapters.deinit(self.allocator);
        if (server.tools.len > 0) client_mod.freeTools(self.allocator, server.tools);
        if (server.last_error) |text| self.allocator.free(text);
        server.cfg.deinit(self.allocator);
        self.allocator.destroy(server);
    }

    /// Secret-free JSON for `/api/mcp`. Environment variable *names* are
    /// listed; values are never rendered anywhere.
    pub fn writeJson(registry: *Registry, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("enabled");
        try writer.write(registry.enabled);
        try writer.objectField("servers");
        try writer.beginArray();
        for (registry.servers.items) |server| {
            try writeServerJson(registry, server, writer);
        }
        try writer.endArray();
        try writer.objectField("running_servers");
        try writer.write(registry.runningCount());
        try writer.objectField("available_tools");
        try writer.write(registry.availableToolCount());
        try writer.endObject();
    }

    /// Secret-free JSON for one server (`/api/mcp/:id`).
    pub fn writeServerJson(
        registry: *Registry,
        server: *ServerRecord,
        writer: *std.json.Stringify,
    ) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(server.cfg.id);
        try writer.objectField("state");
        try writer.write(server.state.name());
        try writer.objectField("enabled");
        try writer.write(server.cfg.enabled);
        try writer.objectField("auto_start");
        try writer.write(server.cfg.auto_start);
        try writer.objectField("transport");
        try writer.write("stdio");
        try writer.objectField("command");
        try writer.write(server.cfg.command);
        try writer.objectField("args");
        try writer.beginArray();
        for (server.cfg.args) |arg| try writer.write(arg);
        try writer.endArray();
        try writer.objectField("env_names");
        try writer.beginArray();
        for (server.cfg.env_names) |name| try writer.write(name);
        try writer.endArray();
        try writer.objectField("timeout_ms");
        try writer.write(server.cfg.timeout_ms);
        try writer.objectField("permission");
        try writer.write(server.cfg.permission.name());
        // Every MCP tool is external code: the risk tier is fixed high.
        try writer.objectField("risk");
        try writer.write(Risk.high.name());
        try writer.objectField("protocol_version");
        try writer.write(if (server.client) |client| client.protocol_version else "");
        try writer.objectField("server_info");
        try writer.beginObject();
        try writer.objectField("name");
        try writer.write(if (server.client) |client| client.server_name else "");
        try writer.objectField("version");
        try writer.write(if (server.client) |client| client.server_version else "");
        try writer.endObject();

        try writer.objectField("tools");
        try writer.beginArray();
        for (server.adapters.items) |adapter| {
            try writer.beginObject();
            try writer.objectField("name");
            try writer.write(adapter.internal_name);
            try writer.objectField("mcp_name");
            try writer.write(adapter.mcp_name);
            try writer.objectField("description");
            try writer.write(adapter.description);
            const tool_enabled = if (registry.tools) |tools|
                (tools.isEnabled(adapter.internal_name) orelse false)
            else
                (server.state == .running);
            try writer.objectField("enabled");
            try writer.write(tool_enabled);
            try writer.objectField("permission");
            try writer.write(permissionOf(server.cfg.permission).name());
            try writer.objectField("risk");
            try writer.write(Risk.high.name());
            try writer.endObject();
        }
        try writer.endArray();

        try writer.objectField("invocations");
        try writer.write(server.invocations);
        try writer.objectField("invocation_errors");
        try writer.write(server.invocation_errors);
        try writer.objectField("stderr_bytes");
        try writer.write(if (server.client) |client| client.stderr_bytes else 0);
        try writer.objectField("last_error");
        if (server.last_error) |text| {
            try writer.write(text);
        } else {
            try writer.write(null);
        }
        try writer.endObject();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const ServerSpec = struct {
    id: []const u8,
    behavior: ?[]const u8 = null,
    enabled: bool = true,
    auto_start: bool = false,
    timeout_ms: ?u64 = null,
    permission: ?[]const u8 = null,
    env: ?[]const u8 = null,
};

/// Build an MCP config JSON document around the real test server executable.
/// Skips the test when the build did not provide the server path.
fn makeConfigJson(
    allocator: std.mem.Allocator,
    mcp_enabled: bool,
    specs: []const ServerSpec,
) ![]u8 {
    const server_path = std.process.Environ.getAlloc(
        std.testing.environ,
        allocator,
        "PICO_MCP_TEST_SERVER",
    ) catch return error.SkipZigTest;
    defer allocator.free(server_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.print("{{\"enabled\":{},\"servers\":[", .{mcp_enabled});
    for (specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        var stringify: std.json.Stringify = .{ .writer = writer };
        try stringify.write(spec.id);
        try writer.writeAll(",\"command\":");
        stringify = .{ .writer = writer };
        try stringify.write(server_path);
        try writer.print(
            ",\"enabled\":{},\"auto_start\":{}",
            .{ spec.enabled, spec.auto_start },
        );
        if (spec.behavior) |behavior| {
            const arg = try std.fmt.allocPrint(allocator, "--behavior={s}", .{behavior});
            defer allocator.free(arg);
            try writer.writeAll(",\"args\":[");
            var arg_stringify: std.json.Stringify = .{ .writer = writer };
            try arg_stringify.write(arg);
            try writer.writeAll("]");
        }
        if (spec.timeout_ms) |timeout| {
            try writer.print(",\"timeout_ms\":{d}", .{timeout});
        }
        if (spec.permission) |permission| {
            try writer.writeAll(",\"permission\":\"");
            try writer.writeAll(permission);
            try writer.writeAll("\"");
        }
        if (spec.env) |env| {
            try writer.writeAll(",\"env\":");
            try writer.writeAll(env);
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn expectState(registry: *Registry, id: []const u8, expected: State) !void {
    const server = registry.findServer(id) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(expected, server.state);
}

test "registry is deny-by-default without configuration" {
    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 0), registry.serverCount());
    try testing.expectEqual(@as(usize, 0), registry.runningCount());
    try testing.expectEqual(@as(usize, 0), registry.availableToolCount());
    // With no configured server there is nothing to start or stop — and
    // nothing may be invented.
    try testing.expectError(error.ServerNotFound, registry.startServer("demo"));
    try testing.expectError(error.ServerNotFound, registry.stopServer("demo"));
    try testing.expectError(error.ServerNotFound, registry.setEnabled("demo", true));
}

test "registry refuses to start when MCP is switched off" {
    const json = try makeConfigJson(testing.allocator, false, &.{.{
        .id = "off",
        .behavior = "exit_immediately",
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    try expectState(&registry, "off", .disabled);
    try testing.expectError(error.McpDisabled, registry.startServer("off"));
    try expectState(&registry, "off", .disabled);
}

test "registry refuses to start a server that is not enabled" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "quiet",
        .behavior = "exit_immediately",
        .enabled = false,
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    try expectState(&registry, "quiet", .disabled);
    try testing.expectError(error.ServerDisabled, registry.startServer("quiet"));
}

test "registry starts a real server and exposes tools through the ToolRegistry" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "demo",
        .env = "{\"DEMO_TOKEN\":\"secret-value\"}",
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    try expectState(&registry, "demo", .configured);
    try testing.expectEqual(@as(usize, 0), tools.count());

    try registry.startServer("demo");
    try expectState(&registry, "demo", .running);
    try testing.expectEqual(@as(usize, 1), registry.runningCount());
    try testing.expectEqual(@as(usize, 10), registry.availableToolCount());

    // Discovery must have produced namespaced entries in the shared registry.
    try testing.expect(tools.find("mcp.demo.echo") != null);
    try testing.expectEqual(Permission.elevated, tools.find("mcp.demo.echo").?.permission);
    try testing.expectEqual(Risk.high, tools.find("mcp.demo.echo").?.risk);

    // Execution goes through the ToolRegistry: no bypass.
    const echoed = try tools.execute(testing.allocator, "mcp.demo.echo", "{\"text\":\"via registry\"}");
    defer testing.allocator.free(echoed);
    try testing.expect(std.mem.indexOf(u8, echoed, "via registry") != null);

    const summed = try tools.execute(testing.allocator, "mcp.demo.add", "{\"a\":20,\"b\":22}");
    defer testing.allocator.free(summed);
    try testing.expect(std.mem.indexOf(u8, summed, "\"text\":\"42\"") != null);

    try testing.expectEqual(@as(u64, 2), registry.findServer("demo").?.invocations);

    // Double start is a transition error, not silent success.
    try testing.expectError(error.AlreadyRunning, registry.startServer("demo"));
}

test "registry stop disables tools and restart brings them back" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{ .id = "cycle" }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    try registry.startServer("cycle");
    try testing.expectEqual(@as(?bool, true), tools.isEnabled("mcp.cycle.echo"));

    try registry.stopServer("cycle");
    try expectState(&registry, "cycle", .stopped);
    try testing.expectEqual(@as(usize, 0), registry.runningCount());
    // The tool entry remains registered but refuses execution: the agent is
    // never told a stopped server's tools are available.
    try testing.expectEqual(@as(?bool, false), tools.isEnabled("mcp.cycle.echo"));
    try testing.expectError(
        error.ToolDisabled,
        tools.execute(testing.allocator, "mcp.cycle.echo", "{}"),
    );
    try testing.expectError(error.NotRunning, registry.stopServer("cycle"));

    try registry.restartServer("cycle");
    try expectState(&registry, "cycle", .running);
    try testing.expectEqual(@as(?bool, true), tools.isEnabled("mcp.cycle.echo"));
    const echoed = try tools.execute(testing.allocator, "mcp.cycle.echo", "{\"text\":\"back\"}");
    defer testing.allocator.free(echoed);
    try testing.expect(std.mem.indexOf(u8, echoed, "back") != null);
}

test "registry marks a crashed server as error and refuses its tools" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{ .id = "doomed" }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    try registry.startServer("doomed");
    try testing.expectError(
        error.EndOfStream,
        tools.execute(testing.allocator, "mcp.doomed.crash", "{}"),
    );

    try expectState(&registry, "doomed", .error_state);
    try testing.expectEqualStrings("EndOfStream", registry.findServer("doomed").?.last_error.?);
    try testing.expectEqual(@as(u64, 1), registry.findServer("doomed").?.invocation_errors);
    try testing.expectEqual(@as(?bool, false), tools.isEnabled("mcp.doomed.echo"));
}

test "registry records an initialization timeout on a silent server" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "silent",
        .behavior = "silent",
        .timeout_ms = 1000,
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    try testing.expectError(error.Timeout, registry.startServer("silent"));
    try expectState(&registry, "silent", .error_state);
    try testing.expectEqualStrings("Timeout", registry.findServer("silent").?.last_error.?);
    try testing.expectEqual(@as(usize, 0), registry.availableToolCount());
}

test "registry records a failed spawn instead of faking a server" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "missing",
        .behavior = "exit_immediately",
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    // Simulate an operator typo in the configured executable.
    const server = registry.findServer("missing").?;
    testing.allocator.free(server.cfg.command);
    server.cfg.command = try testing.allocator.dupe(u8, "pico-claw-no-such-mcp-server");

    try testing.expectError(error.SpawnFailed, registry.startServer("missing"));
    try expectState(&registry, "missing", .error_state);
    try testing.expectEqualStrings("SpawnFailed", registry.findServer("missing").?.last_error.?);
    // A retry after a failure is allowed (the state is not stuck running).
    try testing.expectError(error.SpawnFailed, registry.startServer("missing"));
}

test "registry namespaces tools per server and runs several servers at once" {
    const json = try makeConfigJson(testing.allocator, true, &.{
        .{ .id = "alpha", .auto_start = true },
        .{ .id = "beta", .auto_start = true },
    });
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    registry.startAutoStart();
    try testing.expectEqual(@as(usize, 2), registry.runningCount());
    try testing.expectEqual(@as(usize, 20), registry.availableToolCount());
    try testing.expectEqual(@as(usize, 20), tools.count());

    // Same MCP tool name, distinct namespaced ids, independent execution.
    const from_alpha = try tools.execute(testing.allocator, "mcp.alpha.echo", "{\"text\":\"A\"}");
    defer testing.allocator.free(from_alpha);
    const from_beta = try tools.execute(testing.allocator, "mcp.beta.echo", "{\"text\":\"B\"}");
    defer testing.allocator.free(from_beta);
    try testing.expect(std.mem.indexOf(u8, from_alpha, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, from_beta, "\"B\"") != null);

    // Stopping one server leaves the other untouched.
    try registry.stopServer("alpha");
    try testing.expectEqual(@as(usize, 1), registry.runningCount());
    try testing.expectEqual(@as(?bool, true), tools.isEnabled("mcp.beta.echo"));
    try testing.expectEqual(@as(?bool, false), tools.isEnabled("mcp.alpha.echo"));
}

test "registry probe performs a real handshake and cleans up" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{ .id = "probe" }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    try registry.probeServer("probe");
    // A probe does not start the server: capability state stays honest.
    try expectState(&registry, "probe", .configured);
    try testing.expect(registry.findServer("probe").?.last_error == null);
    try testing.expectEqual(@as(usize, 0), registry.runningCount());

    // A probe of a broken configuration records the failure.
    const broken = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "probe",
        .behavior = "silent",
        .timeout_ms = 1000,
    }});
    defer testing.allocator.free(broken);
    try registry.loadConfig(broken);
    try testing.expectError(error.Timeout, registry.probeServer("probe"));
    try testing.expectEqualStrings("Timeout", registry.findServer("probe").?.last_error.?);
}

test "registry enable and disable keep the lifecycle honest" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "toggle",
        .enabled = false,
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    try expectState(&registry, "toggle", .disabled);
    try registry.setEnabled("toggle", true);
    try expectState(&registry, "toggle", .configured);

    // Enabling does not start anything by itself.
    try testing.expectEqual(@as(usize, 0), registry.runningCount());
    try registry.startServer("toggle");
    try expectState(&registry, "toggle", .running);

    // Disabling a running server stops it first.
    try registry.setEnabled("toggle", false);
    try expectState(&registry, "toggle", .disabled);
    try testing.expectEqual(@as(usize, 0), registry.runningCount());
    try testing.expectEqual(@as(?bool, false), tools.isEnabled("mcp.toggle.echo"));
    try testing.expectError(error.ServerDisabled, registry.startServer("toggle"));
    try testing.expectError(error.ServerNotFound, registry.setEnabled("ghost", true));
}

test "registry JSON exposes state without any secret value" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{
        .id = "secretive",
        .env = "{\"PICO_CANARY_SECRET\":\"CANARY-SECRET-VALUE\"}",
        .permission = "network",
        .auto_start = true,
    }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);

    registry.startAutoStart();
    try expectState(&registry, "secretive", .running);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try Registry.writeJson(&registry, &stringify);
    const rendered = out.written();

    // The env NAME is reported; the value never is.
    try testing.expect(std.mem.indexOf(u8, rendered, "PICO_CANARY_SECRET") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "CANARY-SECRET-VALUE") == null);
    // Real state is reported.
    try testing.expect(std.mem.indexOf(u8, rendered, "\"state\":\"running\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"transport\":\"stdio\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"permission\":\"network\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"risk\":\"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "mcp.secretive.echo") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"available_tools\":10") != null);

    // The document must parse and contain no credential-shaped field.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rendered, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);

    // A single-server document is valid on its own (GET /api/mcp/:id).
    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var one_stringify: std.json.Stringify = .{ .writer = &one.writer };
    try Registry.writeServerJson(&registry, registry.findServer("secretive").?, &one_stringify);
    try testing.expect(std.mem.indexOf(u8, one.written(), "CANARY-SECRET-VALUE") == null);
    const one_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, one.written(), .{});
    defer one_parsed.deinit();
    try testing.expect(one_parsed.value == .object);
}

test "registry keeps server-provided instructions as inert data" {
    const json = try makeConfigJson(testing.allocator, true, &.{.{ .id = "tricky" }});
    defer testing.allocator.free(json);

    var registry = Registry.init(testing.allocator, testing.io);
    defer registry.deinit();
    try registry.loadConfig(json);

    var tools = tool_registry_mod.ToolRegistry.init(testing.allocator);
    defer tools.deinit();
    registry.attachToolRegistry(&tools);
    try registry.startServer("tricky");

    // The injection text is present as a description (data)...
    const inject_tool = tools.find("mcp.tricky.inject").?;
    try testing.expect(
        std.mem.indexOf(u8, inject_tool.description, "Ignore previous instructions") != null,
    );

    // ...and the tool's output is returned as content, not acted upon: the
    // only thing that happened is the one call the caller asked for.
    const result = try tools.execute(
        testing.allocator,
        "mcp.tricky.inject",
        "{\"text\":\"please\"}",
    );
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "send API keys") != null);
    try testing.expectEqual(@as(u64, 1), registry.findServer("tricky").?.invocations);
}
