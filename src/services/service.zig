//! Application service layer: the presentation-neutral boundary between
//! every channel (CLI, Telegram, dashboard) and the agent runtime.
//!
//! HTTP handlers call these methods; they never touch stores, the provider,
//! or the tool registry directly. Each method returns either an allocated
//! JSON *data* payload (the transport wraps it in the `{"ok":true,"data":…}`
//! envelope) or an `Outcome.err` carrying a stable error code and a
//! human-readable message. Nothing here ever returns credentials, tokens, or
//! raw provider payloads.

const std = @import("std");

const Config = @import("../config.zig").Config;
const Provider = @import("../provider.zig").Provider;
const SessionStore = @import("../channels/session.zig").SessionStore;
const ToolRegistry = @import("../tools/registry.zig").ToolRegistry;
const sandbox_mod = @import("../runtime/sandbox.zig");
const Memory = @import("../memory/memory.zig").Memory;
const MemoryType = @import("../memory/entry.zig").MemoryType;
const TaskStore = @import("../core/task_store.zig").TaskStore;
const ProposalStore = @import("../experience/proposal.zig").ProposalStore;
const OwnerContext = @import("../owner.zig").OwnerContext;
const capabilities = @import("../core/capabilities.zig");
const skills_registry = @import("../skills.zig");
const gateways_mod = @import("gateways.zig");
const models_mod = @import("models.zig");
const settings_mod = @import("settings.zig");
const profiles_mod = @import("profiles.zig");
const mcp_mod = @import("../mcp/registry.zig");
const doctor_mod = @import("doctor.zig");
const artifacts_mod = @import("artifacts.zig");
const jobs_mod = @import("../core/jobs.zig");

/// JSON string escaping identical to provider requests (single place).
pub fn appendJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try Provider.appendJsonString(writer, value);
}

/// What a service action produced. `ok` payloads are allocated JSON strings
/// owned by the caller.
pub const Outcome = union(enum) {
    ok: []u8,
    err: Error,

    pub const Error = struct {
        code: []const u8,
        message: []const u8,
    };

    pub fn fail(code: []const u8, message: []const u8) Outcome {
        return .{ .err = .{ .code = code, .message = message } };
    }
};

/// Raw (non-JSON) content plus its honest content type, for download routes.
pub const ContentResult = union(enum) {
    ok: struct { data: []u8, mime: []const u8 },
    err: Outcome.Error,
};

/// Convert an allocating writer's buffered JSON into an owned ok Outcome.
/// Takes the writer by pointer: buffer ownership moves into the payload.
fn ownedOutcome(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) Outcome {
    var list = out.toArrayList();
    const payload = list.toOwnedSlice(allocator) catch {
        list.deinit(allocator);
        return Outcome.fail("INTERNAL", "Encoding failed.");
    };
    return .{ .ok = payload };
}

/// One statically registered skill plus its runtime enable flag.
pub const SkillState = struct {
    name: []const u8,
    description: []const u8,
    tool_name: ?[]const u8,
    enabled: bool = true,
};

pub const Services = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    config: *const Config,
    provider: *Provider,
    sessions: ?*SessionStore = null,
    tools: *ToolRegistry,
    memory: ?*Memory = null,
    tasks: ?*TaskStore = null,
    proposals: ?*ProposalStore = null,
    owner_context: ?*OwnerContext = null,
    gateways: *gateways_mod.GatewayManager,
    models: *models_mod.Catalog,
    settings: *settings_mod.Settings,
    profiles: *profiles_mod.Service,
    skills: std.ArrayList(SkillState) = .empty,
    version: []const u8 = "0.1.0",
    started_at_ms: i64 = 0,
    /// Composed system prompt (policy + capabilities + active profile).
    system_prompt: []u8 = &.{},
    /// Model override applied to the provider, owned here for cleanup.
    applied_model: ?[]u8 = null,
    /// Dashboard transport facts (read-only, reported by config/settings).
    dashboard_host: []const u8 = "127.0.0.1",
    dashboard_port: u16 = 8080,
    auth_required: bool = false,
    /// Live sandbox handle for the Sandbox page; null reports disabled.
    sandbox: ?*const sandbox_mod.Sandbox = null,
    /// Live MCP registry; null reports MCP as not configured.
    mcp: ?*mcp_mod.Registry = null,
    /// Operations subsystems (final milestone). null reports unavailable.
    attachments: ?*@import("../runtime/attachments.zig").Store = null,
    artifacts: ?*@import("artifacts.zig").Store = null,
    jobs: ?*@import("../core/jobs.zig").Runtime = null,
    runs: ?*@import("../core/runs.zig").Store = null,
    /// Tests run against temporary state and must not write config/settings.json.
    persist_settings: bool = true,

    pub fn init(self: *Services) void {
        const defaults = skills_registry.Registry.default();
        for (defaults.skills) |skill| {
            self.skills.append(self.allocator, .{
                .name = skill.name,
                .description = skill.description,
                .tool_name = skill.tool_name,
            }) catch {};
        }
        self.started_at_ms = task_mod.wallClockMs(self.io);
    }

    pub fn deinit(self: *Services) void {
        self.skills.deinit(self.allocator);
        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        if (self.applied_model) |model| self.allocator.free(model);
    }

    pub fn apiKeyAvailable(self: *const Services) bool {
        const key = self.env_map.get("PICO_CLAW_API_KEY") orelse return false;
        return key.len > 0;
    }

    pub fn activeModel(self: *const Services) []const u8 {
        if (self.settings.model) |model| return model;
        return self.config.model;
    }

    /// Assemble the runtime capability manifest from live state. The caller
    /// owns (and must free) the tool list.
    pub fn capabilitiesManifest(self: *const Services, allocator: std.mem.Allocator) !struct {
        manifest: capabilities.Manifest,
        tools: []capabilities.ToolCap,
    } {
        var tool_caps = try allocator.alloc(capabilities.ToolCap, self.tools.count());
        for (self.tools.tools.items, 0..) |tool, index| {
            tool_caps[index] = .{ .name = tool.name, .enabled = tool.enabled };
        }

        const telegram_running = self.gateways.running();
        const manifest = capabilities.Manifest{
            .channels = .{
                .cli = true,
                .telegram = telegram_running,
                .telegram_note = self.gateways.state.name(),
                .dashboard = true,
            },
            .gateways = .{
                .telegram_receive = telegram_running,
                .telegram_send = self.gateways.configured() and self.toolEnabledByName("telegram"),
                .telegram_commands = telegram_running,
            },
            .provider = .{
                .available = self.apiKeyAvailable() and self.config.base_url.len > 0,
                .model_discovery = true,
                .streaming = false,
                .vision = false,
                .tool_calling = true,
                .note = if (self.apiKeyAvailable()) "" else "missing API key",
            },
            .workspace = .{ .read = true, .write = true, .execute = false, .root = "." },
            .tools = tool_caps,
            .mcp = self.mcpCapability(),
            .attachments = self.attachments != null,
            .artifacts = self.artifacts != null,
            .jobs = self.jobs != null,
            .runs = self.runs != null,
            .memory_available = self.memory != null,
            .memory_entries = if (self.memory) |memory| memory.count() else 0,
            .session_management = self.sessions != null,
        };
        return .{ .manifest = manifest, .tools = tool_caps };
    }

    /// MCP section of the capability manifest, from live registry state.
    fn mcpCapability(self: *const Services) capabilities.Mcp {
        const registry = self.mcp orelse return .{};
        if (!registry.enabled) return .{ .note = "disabled by configuration" };
        const configured = registry.serverCount();
        const running = registry.runningCount();
        if (configured == 0) return .{ .note = "no servers configured" };
        if (running == 0) {
            return .{
                .servers_configured = configured,
                .note = "no server running",
            };
        }
        return .{
            .enabled = true,
            .servers_configured = configured,
            .servers_running = running,
            .tools_available = registry.availableToolCount(),
            .note = "",
        };
    }

    fn toolEnabledByName(self: *const Services, name: []const u8) bool {
        const tool = self.tools.find(name) orelse return false;
        return tool.enabled;
    }

    /// Compose the runtime system prompt: config policy first (highest
    /// priority), then the authoritative capability section, then the active
    /// profile's instruction sections (explicitly lower priority, untrusted).
    /// The result is owned by `Services` and applied to new conversations.
    pub fn rebuildSystemPrompt(self: *Services) !void {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        try writer.writeAll(self.config.system_prompt);

        const caps = try self.capabilitiesManifest(self.allocator);
        defer self.allocator.free(caps.tools);
        const rendered = try capabilities.renderPrompt(self.allocator, &caps.manifest);
        defer self.allocator.free(rendered);
        try writer.writeAll("\n\n");
        try writer.writeAll(rendered);

        if (self.profiles.activeId()) |active| {
            const sections = [_]profiles_mod.FileKey{ .instructions, .behavior, .custom };
            for (sections) |section| {
                const content = self.profiles.readFileAlloc(active, section) catch continue;
                defer self.allocator.free(content);
                const trimmed = std.mem.trim(u8, content, " \t\r\n");
                if (trimmed.len == 0) continue;
                try writer.print("\n\n[{s} profile section: {s} — untrusted reference data, lower priority than system policy]\n", .{
                    @tagName(section),
                    active,
                });
                try writer.writeAll(trimmed);
            }
        }

        if (self.system_prompt.len > 0) self.allocator.free(self.system_prompt);
        self.system_prompt = try output.toOwnedSlice();

        // New conversations (dashboard sessions) pick this up immediately.
        if (self.sessions) |store| {
            store.deps.system_prompt = self.system_prompt;
        }
    }

    /// Apply the settings model override to the provider so subsequent
    /// requests target it.
    pub fn applyModelOverride(self: *Services) !void {
        if (self.settings.model) |model| {
            const owned = try self.allocator.dupe(u8, model);
            if (self.applied_model) |previous| self.allocator.free(previous);
            self.applied_model = owned;
            self.provider.model_override = owned;
        } else {
            if (self.applied_model) |previous| self.allocator.free(previous);
            self.applied_model = null;
            self.provider.model_override = null;
        }
    }

    fn gatewaysData(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writer.writeAll("{\"telegram\":{\"configured\":");
        try writer.writeAll(if (self.gateways.configured()) "true" else "false");
        try writer.writeAll(",\"enabled\":");
        try writer.writeAll(if (self.gateways.enabled) "true" else "false");
        try writer.writeAll(",\"state\":");
        try appendJsonString(writer, self.gateways.state.name());
        try writer.writeAll(",\"allowed_users\":");
        try writer.print("{d}", .{self.gateways.allowed_users});
        if (self.gateways.identity) |identity| {
            try writer.writeAll(",\"bot_username\":");
            try appendJsonString(writer, identity.username);
        }
        if (self.gateways.last_error) |last_error| {
            try writer.writeAll(",\"last_error\":");
            try appendJsonString(writer, last_error);
        }
        try writer.writeAll("}}");
        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    pub fn capabilitiesJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const caps = try self.capabilitiesManifest(self.allocator);
        defer self.allocator.free(caps.tools);
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try capabilities.writeJson(&stringify, &caps.manifest);
        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Normalized model listing from the catalog cache.
    pub fn modelsJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"active_model\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.activeModel());
        writer.writeAll(",\"configured_model\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.config.model);
        writer.print(",\"fetched_at_ms\":{d},\"available\":{s},\"count\":{d},\"models\":[", .{
            self.models.fetched_at_ms,
            if (self.models.fresh()) "true" else "false",
            self.models.count(),
        }) catch return error.OutOfMemory;

        for (self.models.models, 0..) |model, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"id\":") catch return error.OutOfMemory;
            try appendJsonString(writer, model.id);
            writer.writeAll(",\"display_name\":") catch return error.OutOfMemory;
            try appendJsonString(writer, model.display_name);
            if (model.owner) |owner_name| {
                writer.writeAll(",\"provider\":") catch return error.OutOfMemory;
                try appendJsonString(writer, owner_name);
            }
            if (model.created) |created| {
                writer.print(",\"freshness\":{d}", .{created}) catch return error.OutOfMemory;
            }
            writer.print(",\"capabilities_known\":{s},\"streaming\":{s},\"vision\":{s},\"tool_calling\":{s}", .{
                if (model.capabilities_known) "true" else "false",
                if (model.streaming) "true" else "false",
                if (model.vision) "true" else "false",
                if (model.tool_calling) "true" else "false",
            }) catch return error.OutOfMemory;
            if (model.context_limit) |limit| {
                writer.print(",\"context_limit\":{d}", .{limit}) catch return error.OutOfMemory;
            }
            writer.writeByte('}') catch return error.OutOfMemory;
        }
        writer.writeAll("]}") catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Force a provider model refresh. Errors carry a stable code.
    pub fn refreshModels(self: *Services) Outcome {
        _ = self.models.refresh() catch |err| {
            const code: []const u8 = switch (err) {
                error.InvalidApiResponse => "PROVIDER_INVALID_RESPONSE",
                else => "PROVIDER_UNAVAILABLE",
            };
            return Outcome.fail(code, "Model refresh failed. Check the provider endpoint and API key.");
        };
        const payload = self.modelsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// The dashboard's primary chat identity inside the shared session store.
    pub const default_chat_id = "dashboard";

    /// Live in-memory sessions: ids and message counts, never content.
    pub fn sessionsJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeByte('[') catch return error.OutOfMemory;
        if (self.sessions) |store| {
            const infos = try store.list(self.allocator);
            defer SessionStore.freeList(self.allocator, infos);
            for (infos, 0..) |info, index| {
                if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
                writer.writeAll("{\"chat_id\":") catch return error.OutOfMemory;
                try appendJsonString(writer, info.chat_id);
                writer.print(",\"messages\":{d},\"active\":{s}}}", .{
                    info.message_count,
                    if (std.mem.eql(u8, info.chat_id, default_chat_id)) "true" else "false",
                }) catch return error.OutOfMemory;
            }
        }
        writer.writeByte(']') catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Bounded message history for one session, oldest first. System-policy
    /// messages are excluded; when the cap is exceeded whole old messages are
    /// dropped from the front (never truncated mid-message).
    pub fn sessionDetailJson(self: *Services, chat_id: []const u8) !?[]u8 {
        const store = self.sessions orelse return null;
        const conversation = store.find(chat_id) orelse return null;

        const max_messages: usize = 200;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"chat_id\":") catch return error.OutOfMemory;
        try appendJsonString(writer, chat_id);
        writer.writeAll(",\"messages\":[") catch return error.OutOfMemory;

        const all = conversation.context.messages.items;
        var visible: usize = 0;
        for (all) |message| {
            if (message.role != .system) visible += 1;
        }
        var skipped: usize = if (visible > max_messages) visible - max_messages else 0;
        var emitted: usize = 0;
        for (all) |message| {
            if (message.role == .system) continue;
            if (skipped > 0) {
                skipped -= 1;
                continue;
            }
            if (emitted > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"role\":") catch return error.OutOfMemory;
            try appendJsonString(writer, switch (message.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
            });
            writer.writeAll(",\"content\":") catch return error.OutOfMemory;
            try appendJsonString(writer, message.content);
            writer.writeByte('}') catch return error.OutOfMemory;
            emitted += 1;
        }

        writer.print("],\"count\":{d}}}", .{visible}) catch return error.OutOfMemory;
        var list = output.toArrayList();
        return try list.toOwnedSlice(self.allocator);
    }

    /// Create a session. Ids are validated; only then is anything created.
    pub fn validChatId(chat_id: []const u8) bool {
        if (chat_id.len == 0 or chat_id.len > 64) return false;
        for (chat_id) |char| {
            const ok = std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.';
            if (!ok) return false;
        }
        return true;
    }

    pub fn createSession(self: *Services, chat_id: []const u8) Outcome {
        if (!validChatId(chat_id)) return Outcome.fail("INVALID_SESSION_ID", "Session id must be 1-64 characters of [A-Za-z0-9._-].");
        const store = self.sessions orelse return Outcome.fail("SESSIONS_UNAVAILABLE", "Session store is not attached.");
        if (store.find(chat_id) != null) return Outcome.fail("ALREADY_EXISTS", "A session with this id already exists.");
        _ = store.getOrCreate(chat_id) catch return Outcome.fail("INTERNAL", "Session creation failed.");
        const payload = self.sessionDetailJson(chat_id) catch null;
        if (payload) |value| return .{ .ok = value };
        return Outcome.fail("INTERNAL", "Encoding failed.");
    }

    pub fn renameSession(self: *Services, from: []const u8, to: []const u8) Outcome {
        if (!validChatId(from) or !validChatId(to)) {
            return Outcome.fail("INVALID_SESSION_ID", "Session id must be 1-64 characters of [A-Za-z0-9._-].");
        }
        const store = self.sessions orelse return Outcome.fail("SESSIONS_UNAVAILABLE", "Session store is not attached.");
        const renamed = store.rename(from, to) catch return Outcome.fail("INTERNAL", "Rename failed.");
        if (!renamed) return Outcome.fail("SESSION_NOT_FOUND", "Source session missing or target id taken.");
        const payload = self.sessionsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// Send a user message into a specific session conversation. Same agent
    /// core as CLI chat and Telegram; the reply is returned raw plus
    /// pre-rendered HTML from the shared formatter (identical to /chat).
    pub fn sendToSession(self: *Services, chat_id: []const u8, message: []const u8) Outcome {
        if (!validChatId(chat_id)) return Outcome.fail("INVALID_SESSION_ID", "Invalid session id.");
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed.len == 0) return Outcome.fail("INVALID_VALUE", "message must not be empty");
        const store = self.sessions orelse return Outcome.fail("SESSIONS_UNAVAILABLE", "Session store is not attached.");

        const conversation = store.getOrCreate(chat_id) catch return Outcome.fail("INTERNAL", "Session creation failed.");
        const reply = conversation.send(trimmed) catch |err| {
            const code: []const u8 = switch (err) {
                error.ApiKeyNotFound => "PROVIDER_UNAVAILABLE",
                error.ApiRequestFailed => "PROVIDER_UNAVAILABLE",
                else => "INTERNAL",
            };
            return Outcome.fail(code, "The agent could not complete this request.");
        };
        defer self.allocator.free(reply);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{\"response\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        appendJsonString(writer, reply) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.writeAll(",\"html\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        const html = @import("../format.zig").format(self.allocator, reply) catch null;
        if (html) |rendered| {
            defer self.allocator.free(rendered);
            appendJsonString(writer, rendered) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        } else {
            writer.writeAll("\"\"") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn deleteSession(self: *Services, chat_id: []const u8) Outcome {
        if (!validChatId(chat_id)) return Outcome.fail("INVALID_SESSION_ID", "Invalid session id.");
        const store = self.sessions orelse return Outcome.fail("SESSIONS_UNAVAILABLE", "Session store is not attached.");
        if (!store.remove(chat_id)) return Outcome.fail("SESSION_NOT_FOUND", "No such session.");
        const payload = self.sessionsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn clearSession(self: *Services, chat_id: []const u8) Outcome {
        if (!validChatId(chat_id)) return Outcome.fail("INVALID_SESSION_ID", "Invalid session id.");
        const store = self.sessions orelse return Outcome.fail("SESSIONS_UNAVAILABLE", "Session store is not attached.");
        if (!store.clearChat(chat_id)) return Outcome.fail("SESSION_NOT_FOUND", "No such session.");
        const payload = self.sessionDetailJson(chat_id) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        if (payload) |value| return .{ .ok = value };
        return Outcome.fail("INTERNAL", "Encoding failed.");
    }

    /// Tool manifest from the live registry: name, description, parameters,
    /// permission, risk, enabled state. Only registered tools appear.
    pub fn toolsJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeByte('[') catch return error.OutOfMemory;
        for (self.tools.tools.items, 0..) |tool, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"name\":") catch return error.OutOfMemory;
            try appendJsonString(writer, tool.name);
            writer.writeAll(",\"description\":") catch return error.OutOfMemory;
            try appendJsonString(writer, tool.description);
            writer.writeAll(",\"permission\":") catch return error.OutOfMemory;
            try appendJsonString(writer, tool.permission.name());
            writer.writeAll(",\"risk\":") catch return error.OutOfMemory;
            try appendJsonString(writer, tool.risk.name());
            writer.print(",\"enabled\":{s},\"parameters\":[", .{if (tool.enabled) "true" else "false"}) catch return error.OutOfMemory;
            for (tool.parameters, 0..) |param, param_index| {
                if (param_index > 0) writer.writeByte(',') catch return error.OutOfMemory;
                writer.writeAll("{\"name\":") catch return error.OutOfMemory;
                try appendJsonString(writer, param.name);
                writer.writeAll(",\"description\":") catch return error.OutOfMemory;
                try appendJsonString(writer, param.description);
                writer.print(",\"required\":{s}}}", .{if (param.required) "true" else "false"}) catch return error.OutOfMemory;
            }
            writer.writeAll("]}") catch return error.OutOfMemory;
        }
        writer.writeByte(']') catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    pub fn setToolEnabled(self: *Services, name: []const u8, enabled: bool) Outcome {
        if (!self.tools.setEnabled(name, enabled)) {
            return Outcome.fail("TOOL_NOT_FOUND", "No such tool is registered.");
        }
        // The capability section must reflect the change immediately.
        self.rebuildSystemPrompt() catch {};
        const payload = self.toolsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// Registered skills with their runtime enable flags. Skills are static
    /// metadata; enabling one exposes its linked tool in the manifest.
    pub fn skillsJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeByte('[') catch return error.OutOfMemory;
        for (self.skills.items, 0..) |skill, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"id\":") catch return error.OutOfMemory;
            try appendJsonString(writer, skill.name);
            writer.writeAll(",\"description\":") catch return error.OutOfMemory;
            try appendJsonString(writer, skill.description);
            writer.writeAll(",\"tool\":") catch return error.OutOfMemory;
            if (skill.tool_name) |tool_name| {
                try appendJsonString(writer, tool_name);
            } else {
                writer.writeAll("null") catch return error.OutOfMemory;
            }
            writer.writeAll(",\"permission\":") catch return error.OutOfMemory;
            if (skill.tool_name) |tool_name| {
                if (self.tools.find(tool_name)) |tool| {
                    try appendJsonString(writer, tool.permission.name());
                } else {
                    writer.writeAll("\"none\"") catch return error.OutOfMemory;
                }
            } else {
                writer.writeAll("\"none\"") catch return error.OutOfMemory;
            }
            writer.print(",\"tool_available\":{s},\"enabled\":{s}}}", .{
                if (skill.tool_name == null) "true" else if (self.toolEnabledByName(skill.tool_name.?)) "true" else "false",
                if (skill.enabled) "true" else "false",
            }) catch return error.OutOfMemory;
        }
        writer.writeByte(']') catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    pub fn setSkillEnabled(self: *Services, id: []const u8, enabled: bool) Outcome {
        for (self.skills.items) |*skill| {
            if (!std.mem.eql(u8, skill.name, id)) continue;
            skill.enabled = enabled;
            // A skill's linked tool follows the skill's state.
            if (skill.tool_name) |tool_name| {
                _ = self.tools.setEnabled(tool_name, enabled);
            }
            self.rebuildSystemPrompt() catch {};
            const payload = self.skillsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
            return .{ .ok = payload };
        }
        return Outcome.fail("SKILL_NOT_FOUND", "No such skill is registered.");
    }

    const memory_types = [_]MemoryType{ .semantic, .episodic, .procedural, .error_memory, .preference };

    fn writeMemoryEntry(self: *Services, writer: *std.Io.Writer, entry: anytype) !void {
        _ = self;
        try writer.writeAll("{\"id\":");
        try writer.print("{d}", .{entry.id});
        try writer.writeAll(",\"type\":");
        try appendJsonString(writer, entry.memory_type.name());
        try writer.writeAll(",\"content\":");
        try appendJsonString(writer, entry.content);
        try writer.print(",\"importance\":{d}}}", .{entry.importance});
    }

    /// Typed memory listing, optionally filtered to one type. Content is
    /// returned to the operator; credentials never live here by construction.
    pub fn memoryJson(self: *Services, filter: ?MemoryType) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"counts\":{") catch return error.OutOfMemory;
        for (memory_types, 0..) |memory_type, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            try appendJsonString(writer, memory_type.name());
            writer.writeByte(':') catch return error.OutOfMemory;
            writer.print("{d}", .{if (self.memory) |memory| memory.countByType(memory_type) else 0}) catch return error.OutOfMemory;
        }
        writer.writeAll("},\"entries\":[") catch return error.OutOfMemory;

        if (self.memory) |memory| {
            var emitted: usize = 0;
            for (memory_types) |memory_type| {
                if (filter) |wanted| {
                    if (wanted != memory_type) continue;
                }
                const entries = memory.getByType(memory_type);
                defer memory.freeEntries(entries);
                for (entries) |entry| {
                    if (emitted > 0) writer.writeByte(',') catch return error.OutOfMemory;
                    try self.writeMemoryEntry(writer, entry);
                    emitted += 1;
                }
            }
        }
        writer.writeAll("]}") catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    pub fn memorySearchJson(self: *Services, query: []const u8, filter: ?MemoryType) Outcome {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return Outcome.fail("INVALID_QUERY", "Search query must not be empty.");
        const memory = self.memory orelse return Outcome.fail("MEMORY_UNAVAILABLE", "Memory store is not attached.");

        const results = memory.searchEntriesLimited(trimmed, 25);
        defer memory.freeSearchResults(results);

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{\"query\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        appendJsonString(writer, trimmed) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.writeAll(",\"matches\":[") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        var emitted: usize = 0;
        for (results) |entry| {
            if (filter) |wanted| {
                if (wanted != entry.memory_type) continue;
            }
            if (emitted > 0) writer.writeByte(',') catch return Outcome.fail("INTERNAL", "Encoding failed.");
            self.writeMemoryEntry(writer, entry) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            emitted += 1;
        }
        writer.writeAll("]}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn memoryForgetJson(self: *Services, id: u64) Outcome {
        const memory = self.memory orelse return Outcome.fail("MEMORY_UNAVAILABLE", "Memory store is not attached.");
        if (!memory.forget(id)) return Outcome.fail("MEMORY_NOT_FOUND", "No memory entry with that id.");
        const payload = self.memoryJson(null) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn memoryClearJson(self: *Services, filter: ?MemoryType) Outcome {
        const memory = self.memory orelse return Outcome.fail("MEMORY_UNAVAILABLE", "Memory store is not attached.");
        if (filter) |memory_type| {
            memory.clearType(memory_type) catch return Outcome.fail("INTERNAL", "Clearing failed.");
        } else {
            memory.clear() catch return Outcome.fail("INTERNAL", "Clearing failed.");
        }
        const payload = self.memoryJson(null) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    const task_mod = @import("../core/task.zig");

    /// Agent run list from the task journal: bounded metadata only. Task
    /// records never store task text, tool input/output, or provider payloads.
    pub fn runsJson(self: *Services, limit: usize) Outcome {
        const store = self.tasks orelse return Outcome.fail("RUNS_UNAVAILABLE", "Task journal is not attached.");
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        writer.writeByte('[') catch return Outcome.fail("INTERNAL", "Encoding failed.");
        const items = store.records.items;
        var emitted: usize = 0;
        var index: usize = items.len;
        while (index > 0 and emitted < limit) {
            index -= 1;
            const record = &items[index];
            if (emitted > 0) writer.writeByte(',') catch return Outcome.fail("INTERNAL", "Encoding failed.");
            self.writeRunSummary(writer, record) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            emitted += 1;
        }
        writer.writeByte(']') catch return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    fn writeRunSummary(self: *Services, writer: *std.Io.Writer, record: *const task_mod.TaskRecord) !void {
        _ = self;
        try writer.print("{{\"id\":{d},\"state\":", .{record.id});
        try appendJsonString(writer, record.state.name());
        try writer.print(",\"started_at_ms\":{d},\"duration_ms\":{d},\"route\":", .{
            record.started_at_ms,
            if (record.ended_at_ms >= record.started_at_ms) record.ended_at_ms - record.started_at_ms else 0,
        });
        try appendJsonString(writer, record.route.name());
        if (record.error_kind) |kind| {
            try writer.writeAll(",\"error_kind\":");
            try appendJsonString(writer, kind.name());
        }
        if (record.error_code) |code| {
            try writer.writeAll(",\"error\":");
            try appendJsonString(writer, code);
        }
        try writer.writeAll("}");
    }

    /// One run's stage-by-stage inspection: plan steps, tool calls (names,
    /// states, durations — never input content), provider attempts, and
    /// escalation metadata.
    pub fn runDetailJson(self: *Services, id: u64) Outcome {
        const store = self.tasks orelse return Outcome.fail("RUNS_UNAVAILABLE", "Task journal is not attached.");
        var found: ?*const task_mod.TaskRecord = null;
        for (store.records.items) |*record| {
            if (record.id == id) found = record;
        }
        const record = found orelse return Outcome.fail("RUN_NOT_FOUND", "No run with that id.");

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        self.writeRunSummary(writer, record) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        // Extend the summary object instead of duplicating it.
        writer.end -= 1;
        writer.print(",\"planned_steps\":{d},\"steps\":[", .{record.planned_steps}) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        for (record.steps.items, 0..) |step, index| {
            if (index > 0) writer.writeByte(',') catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.print("{{\"step_id\":{d},\"state\":", .{step.step_id}) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, step.state.name()) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(",\"tool\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            if (step.tool_name) |name| {
                appendJsonString(writer, name) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            } else {
                writer.writeAll("null") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            }
            writer.print(",\"duration_ms\":{d}}}", .{step.duration_ms}) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("],\"tool_calls\":[") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        for (record.calls.items, 0..) |call, index| {
            if (index > 0) writer.writeByte(',') catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll("{\"tool\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, call.tool_name) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(",\"state\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, call.state.name()) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.print(",\"input_hash\":\"{x}\",\"duration_ms\":{d}}}", .{ call.input_hash, call.duration_ms }) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("],\"attempts\":[") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        for (record.attempts.items, 0..) |attempt, index| {
            if (index > 0) writer.writeByte(',') catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.print("{{\"attempt\":{d},\"ok\":{s},\"duration_ms\":{d},\"input_bytes\":{d},\"output_bytes\":{d}}}", .{
                attempt.attempt,
                if (attempt.ok) "true" else "false",
                attempt.duration_ms,
                attempt.input_bytes,
                attempt.output_bytes,
            }) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("],\"escalation\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        if (record.escalation) |escalation| {
            writer.writeAll("{\"escalated\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(if (escalation.escalated) "true" else "false") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(",\"reason\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, escalation.reason.name()) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            if (escalation.model_label) |label| {
                writer.writeAll(",\"model\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
                appendJsonString(writer, label) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            }
            writer.writeAll("}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        } else {
            writer.writeAll("null") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("}") catch return Outcome.fail("INTERNAL", "Encoding failed.");

        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// Gateway inventory. Only Telegram has a real adapter; future transports
    /// are listed as planned/unavailable and never as functional.
    pub fn gatewaysJson(self: *Services) Outcome {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{\"gateways\":[") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.writeAll("{\"name\":\"telegram\",\"adapter\":true,\"planned\":false,") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.print("\"configured\":{s},\"enabled\":{s},\"state\":", .{
            if (self.gateways.configured()) "true" else "false",
            if (self.gateways.enabled) "true" else "false",
        }) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        appendJsonString(writer, self.gateways.state.name()) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.print(",\"running\":{s},\"allowed_users\":{d},\"can_host\":{s}", .{
            if (self.gateways.running()) "true" else "false",
            self.gateways.allowed_users,
            if (self.gateways.can_host_channel) "true" else "false",
        }) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        writer.writeAll(",\"bot\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        if (self.gateways.identity) |identity| {
            writer.print("{{\"id\":{d},\"username\":", .{identity.id}) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, identity.username) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(",\"first_name\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, identity.first_name) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll("}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        } else {
            writer.writeAll("null") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll(",\"last_error\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        if (self.gateways.last_error) |last_error| {
            appendJsonString(writer, last_error) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        } else {
            writer.writeAll("null") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        // Planned transports: no adapter exists, so they are shown as planned.
        for ([_][]const u8{ "whatsapp", "discord", "slack" }) |planned_name| {
            writer.writeAll(",{\"name\":") catch return Outcome.fail("INTERNAL", "Encoding failed.");
            appendJsonString(writer, planned_name) catch return Outcome.fail("INTERNAL", "Encoding failed.");
            writer.writeAll(",\"adapter\":false,\"planned\":true,\"configured\":false,\"enabled\":false,\"state\":\"unavailable\"}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        }
        writer.writeAll("]}") catch return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const owned = list.toOwnedSlice(self.allocator) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = owned };
    }

    /// Perform a gateway lifecycle action. Returns the updated gateway list.
    pub fn gatewayAction(self: *Services, name: []const u8, action: []const u8) Outcome {
        if (!self.gateways.known(name)) {
            return Outcome.fail("GATEWAY_NOT_FOUND", "No gateway adapter with that name.");
        }
        self.performGatewayAction(action) catch |err| return switch (err) {
            error.NotConfigured => Outcome.fail("GATEWAY_NOT_CONFIGURED", "Telegram token is not configured."),
            error.GatewayDisabled => Outcome.fail("GATEWAY_DISABLED", "Gateway is disabled; enable it first."),
            error.NotRunning => Outcome.fail("GATEWAY_NOT_RUNNING", "Gateway is not running."),
            error.LifecycleUnsupported => Outcome.fail(
                "GATEWAY_LIFECYCLE_UNSUPPORTED",
                "This process cannot host the channel loop (single-threaded serve). Run the channel with: pico_claw channel telegram",
            ),
            error.InvalidTransition => Outcome.fail("GATEWAY_INVALID_STATE", "Invalid state transition."),
            else => Outcome.fail("GATEWAY_TEST_FAILED", "Connection test failed. Check the token and network."),
        };
        return self.gatewaysJson();
    }

    fn performGatewayAction(self: *Services, action: []const u8) !void {
        if (std.mem.eql(u8, action, "enable")) return self.gateways.enable();
        if (std.mem.eql(u8, action, "disable")) return self.gateways.disable();
        if (std.mem.eql(u8, action, "start")) return self.gateways.start();
        if (std.mem.eql(u8, action, "stop")) return self.gateways.stop();
        if (std.mem.eql(u8, action, "restart")) return self.gateways.restart();
        if (std.mem.eql(u8, action, "test")) return self.gateways.testConnection();
        return error.InvalidTransition;
    }

    /// MCP inventory from the live registry. Without a registry the call
    /// reports MCP_UNAVAILABLE — it never invents state.
    pub fn mcpJson(self: *Services) Outcome {
        const registry = self.mcp orelse
            return Outcome.fail("MCP_UNAVAILABLE", "MCP is not configured in this runtime.");
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        mcp_mod.Registry.writeJson(registry, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// One MCP server's detail document (safe metadata only).
    pub fn mcpServerJson(self: *Services, id: []const u8) Outcome {
        const registry = self.mcp orelse
            return Outcome.fail("MCP_UNAVAILABLE", "MCP is not configured in this runtime.");
        const server = registry.findServer(id) orelse
            return Outcome.fail("MCP_SERVER_NOT_FOUND", "No MCP server with that id.");
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        mcp_mod.Registry.writeServerJson(registry, server, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        var list = output.toArrayList();
        const payload = list.toOwnedSlice(self.allocator) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// MCP lifecycle action for one server; returns the refreshed detail.
    pub fn mcpAction(self: *Services, id: []const u8, action: []const u8) Outcome {
        const registry = self.mcp orelse
            return Outcome.fail("MCP_UNAVAILABLE", "MCP is not configured in this runtime.");

        mcp_mod.Registry.lifecycle(registry, id, action) catch |err| {
            return switch (err) {
                error.ServerNotFound => Outcome.fail("MCP_SERVER_NOT_FOUND", "No MCP server with that id."),
                error.McpDisabled => Outcome.fail("MCP_DISABLED", "MCP is disabled; enable it in config/mcp.json first."),
                error.ServerDisabled => Outcome.fail("MCP_SERVER_DISABLED", "Server is disabled; enable it first."),
                error.AlreadyRunning => Outcome.fail("MCP_ALREADY_RUNNING", "Server is already running."),
                error.NotRunning => Outcome.fail("MCP_NOT_RUNNING", "Server is not running."),
                error.InvalidTransition => Outcome.fail("MCP_INVALID_STATE", "Invalid state transition."),
                error.UnknownAction => Outcome.fail("INVALID_ACTION", "unknown MCP action"),
                else => Outcome.fail(
                    "MCP_START_FAILED",
                    "MCP operation failed; the server state and last_error report the real cause.",
                ),
            };
        };
        return self.mcpServerJson(id);
    }

    // ---- Operations: attachments ------------------------------------------

    pub fn attachmentsJson(self: *Services) Outcome {
        const store = self.attachments orelse
            return Outcome.fail("ATTACHMENTS_UNAVAILABLE", "Upload service is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        store.writeListJson(&stringify) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    /// Ingest a raw upload. The name comes from the query string; the body
    /// bytes are the actual content. Everything else is derived server-side.
    pub fn attachmentIngest(self: *Services, name: []const u8, bytes: []const u8) Outcome {
        const store = self.attachments orelse
            return Outcome.fail("ATTACHMENTS_UNAVAILABLE", "Upload service is not attached.");
        const record = store.ingest(name, bytes) catch |err| return switch (err) {
            error.InvalidFilename => Outcome.fail("INVALID_NAME", "Filename is not usable (traversal, reserved name, or malformed)."),
            error.Empty => Outcome.fail("INVALID_VALUE", "Upload body is empty."),
            error.TooLarge => Outcome.fail("TOO_LARGE", "Upload exceeds the per-attachment size limit."),
            error.QuotaExceeded => Outcome.fail("QUOTA_EXCEEDED", "Upload would exceed the attachments quota."),
            error.PathDenied => Outcome.fail("PATH_DENIED", "Sandbox refused the upload path."),
            error.SymLinkRefused => Outcome.fail("SYMLINK_REFUSED", "Sandbox refused a symlink on the upload path."),
            else => Outcome.fail("UPLOAD_FAILED", "Upload could not be stored."),
        };
        _ = record;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        const last = store.entries.items[store.entries.items.len - 1];
        _ = store.writeOneJson(last.id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn attachmentJson(self: *Services, id: []const u8) Outcome {
        const store = self.attachments orelse
            return Outcome.fail("ATTACHMENTS_UNAVAILABLE", "Upload service is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        const found = store.writeOneJson(id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        if (!found) return Outcome.fail("ATTACHMENT_NOT_FOUND", "No attachment with that id.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn attachmentDelete(self: *Services, id: []const u8) Outcome {
        const store = self.attachments orelse
            return Outcome.fail("ATTACHMENTS_UNAVAILABLE", "Upload service is not attached.");
        if (!store.delete(id)) {
            return Outcome.fail("ATTACHMENT_NOT_FOUND", "No attachment with that id.");
        }
        return self.attachmentsJson();
    }

    /// Queue archive extraction as a background job; returns the job list.
    pub fn attachmentExtractJob(self: *Services, id: []const u8) Outcome {
        const store = self.attachments orelse
            return Outcome.fail("ATTACHMENTS_UNAVAILABLE", "Upload service is not attached.");
        if (store.find(id) == null) {
            return Outcome.fail("ATTACHMENT_NOT_FOUND", "No attachment with that id.");
        }
        const runtime = self.jobs orelse
            return Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is not attached.");

        const user = self.allocator.create(ExtractJobCtx) catch
            return Outcome.fail("INTERNAL", "Allocation failed.");
        const id_copy = self.allocator.dupe(u8, id) catch {
            self.allocator.destroy(user);
            return Outcome.fail("INTERNAL", "Allocation failed.");
        };
        user.* = .{ .services = self, .id = id_copy };

        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "extract {s}", .{id}) catch "extract attachment";
        _ = runtime.submit(.attachment_extraction, title, 120_000, extractAttachmentJobFn, user) catch |err| {
            self.allocator.free(user.id);
            self.allocator.destroy(user);
            return switch (err) {
                error.RuntimeShutdown => Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is shutting down."),
                else => Outcome.fail("INTERNAL", "Allocation failed."),
            };
        };
        return self.jobsJson();
    }

    // ---- Operations: artifacts --------------------------------------------

    pub fn artifactsJson(self: *Services) Outcome {
        const store = self.artifacts orelse
            return Outcome.fail("ARTIFACTS_UNAVAILABLE", "Artifact service is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        store.writeListJson(&stringify) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    /// Create an artifact. The transport parses the body; this takes typed
    /// fields. Unsupported formats are refused with UNSUPPORTED_KIND.
    ///
    /// Zip artifacts are real archives built from workspace sources: the
    /// caller passes `sources` (workspace-relative paths) and `content` is
    /// ignored. Every other supported kind takes inline `content`.
    pub fn artifactCreate(
        self: *Services,
        kind_name: []const u8,
        filename: []const u8,
        content: []const u8,
        sources: ?[]const []const u8,
    ) Outcome {
        const store = self.artifacts orelse
            return Outcome.fail("ARTIFACTS_UNAVAILABLE", "Artifact service is not attached.");
        const kind = artifacts_mod.Kind.parse(kind_name) orelse
            return Outcome.fail("INVALID_VALUE", "unknown artifact kind");

        if (kind == .zip) {
            const list = sources orelse
                return Outcome.fail("INVALID_VALUE", "zip artifacts require a non-empty \"sources\" array");
            if (list.len == 0)
                return Outcome.fail("INVALID_VALUE", "zip artifacts require a non-empty \"sources\" array");
            for (list) |source| {
                if (source.len == 0)
                    return Outcome.fail("INVALID_VALUE", "sources entries must be non-empty workspace paths");
            }
            const record = store.createZip(filename, list) catch |err| return artifactFailure(err);
            return self.artifactCreatedJson(store, record.id);
        }

        const record = store.createText(kind, filename, content) catch |err| return artifactFailure(err);
        return self.artifactCreatedJson(store, record.id);
    }

    /// Map an artifact store failure to a stable API error code.
    fn artifactFailure(err: artifacts_mod.CreateError) Outcome {
        return switch (err) {
            error.UnsupportedKind => Outcome.fail(
                "UNSUPPORTED_KIND",
                "This runtime has no backend for that format (supported: txt, md, json, csv, zip).",
            ),
            error.InvalidFilename => Outcome.fail("INVALID_NAME", "Filename is not usable."),
            error.InvalidContent => Outcome.fail("INVALID_CONTENT", "Content failed format validation."),
            error.TooLarge => Outcome.fail("TOO_LARGE", "Content exceeds the artifact size limit."),
            else => Outcome.fail("ARTIFACT_FAILED", "Artifact could not be written."),
        };
    }

    /// Encode a freshly created artifact record as an ok Outcome. A record
    /// that vanished right after creation is an internal error, not success.
    fn artifactCreatedJson(self: *Services, store: *artifacts_mod.Store, id: []const u8) Outcome {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        _ = store.writeOneJson(id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn artifactJson(self: *Services, id: []const u8) Outcome {
        const store = self.artifacts orelse
            return Outcome.fail("ARTIFACTS_UNAVAILABLE", "Artifact service is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        const found = store.writeOneJson(id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        if (!found) return Outcome.fail("ARTIFACT_NOT_FOUND", "No artifact with that id.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn artifactDelete(self: *Services, id: []const u8) Outcome {
        const store = self.artifacts orelse
            return Outcome.fail("ARTIFACTS_UNAVAILABLE", "Artifact service is not attached.");
        if (!store.delete(id)) {
            return Outcome.fail("ARTIFACT_NOT_FOUND", "No artifact with that id.");
        }
        return self.artifactsJson();
    }

    /// Raw artifact content for download; the caller owns the bytes.
    pub fn artifactContent(self: *Services, id: []const u8) ContentResult {
        const store = self.artifacts orelse
            return .{ .err = .{ .code = "ARTIFACTS_UNAVAILABLE", .message = "Artifact service is not attached." } };
        const record = store.find(id) orelse
            return .{ .err = .{ .code = "ARTIFACT_NOT_FOUND", .message = "No artifact with that id." } };
        const data = store.readContent(id) catch
            return .{ .err = .{ .code = "INTERNAL", .message = "Read failed." } };
        return .{ .ok = .{ .data = data, .mime = record.kind.mime() } };
    }

    // ---- Operations: jobs / doctor / runs ---------------------------------

    pub fn jobsJson(self: *Services) Outcome {
        const runtime = self.jobs orelse
            return Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        runtime.writeListJson(&stringify) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn jobJson(self: *Services, id: []const u8) Outcome {
        const runtime = self.jobs orelse
            return Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        const found = runtime.writeJobJson(id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        if (!found) return Outcome.fail("JOB_NOT_FOUND", "No job with that id.");
        return ownedOutcome(self.allocator, &out);
    }

    /// Cancel a job. Client disconnects never reach here: only an explicit
    /// caller request can cancel.
    pub fn jobCancel(self: *Services, id: []const u8) Outcome {
        const runtime = self.jobs orelse
            return Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is not attached.");
        if (!runtime.cancel(id)) {
            return Outcome.fail("JOB_NOT_CANCELLABLE", "No such job, or it already finished.");
        }
        return self.jobJson(id);
    }

    /// Queue a doctor pass as a job (real checks with network probes).
    pub fn doctorJob(self: *Services) Outcome {
        const runtime = self.jobs orelse
            return Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is not attached.");
        _ = runtime.submit(.doctor, "doctor", 60_000, doctorJobFn, self) catch |err| {
            return switch (err) {
                error.RuntimeShutdown => Outcome.fail("JOBS_UNAVAILABLE", "Job runtime is shutting down."),
                else => Outcome.fail("INTERNAL", "Allocation failed."),
            };
        };
        return self.jobsJson();
    }

    /// Run doctor synchronously and render the report JSON.
    pub fn doctorJson(self: *Services) Outcome {
        var report = doctor_mod.run(self.allocator, self.doctorInputs()) catch
            return Outcome.fail("INTERNAL", "Doctor run failed.");
        defer report.deinit();
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        report.writeJson(&stringify) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    fn doctorInputs(self: *Services) doctor_mod.Inputs {
        return .{
            .version = self.version,
            .env = self.env_map,
            .config = self.config,
            .io = self.io,
            .sandbox = self.sandbox,
            .mcp = self.mcp,
            .attachments = self.attachments,
            .artifacts = self.artifacts,
            .jobs = self.jobs,
            .runs = self.runs,
            .provider = self.provider,
            .probe_network = true,
        };
    }

    // ---- Operations: runs --------------------------------------------------

    pub fn eventsJson(self: *Services) Outcome {
        const store = self.runs orelse
            return Outcome.fail("RUNS_UNAVAILABLE", "Run store is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        store.writeListJson(&stringify) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return ownedOutcome(self.allocator, &out);
    }

    pub fn eventJson(self: *Services, id: []const u8) Outcome {
        const store = self.runs orelse
            return Outcome.fail("RUNS_UNAVAILABLE", "Run store is not attached.");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        const found = store.writeRunJson(id, &stringify) catch
            return Outcome.fail("INTERNAL", "Encoding failed.");
        if (!found) return Outcome.fail("RUN_NOT_FOUND", "No run with that id.");
        return ownedOutcome(self.allocator, &out);
    }

    /// Sandbox policy and limits for the dashboard. Environment entries are
    /// variable NAMES only; values are never read or returned here.
    pub fn sandboxJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var st: std.json.Stringify = .{ .writer = &output.writer };
        const sandbox = self.sandbox;

        try st.beginObject();
        try st.objectField("enabled");
        try st.write(sandbox != null);
        try st.objectField("root");
        try st.write(if (sandbox) |s| s.root_name else "");
        try st.objectField("policy");
        try st.beginObject();
        const policy = if (sandbox) |s| s.policy else sandbox_mod.Access{};
        try st.objectField("read");
        try st.write(policy.read);
        try st.objectField("write");
        try st.write(policy.write);
        try st.objectField("execute");
        try st.write(policy.execute);
        try st.objectField("network");
        try st.write(policy.network_enabled);
        try st.objectField("read_prefixes");
        try writeStringArray(&st, policy.read_prefixes);
        try st.objectField("write_prefixes");
        try writeStringArray(&st, policy.write_prefixes);
        try st.objectField("executable_commands");
        try writeStringArray(&st, policy.executable_commands);
        try st.objectField("env_names");
        try writeStringArray(&st, policy.env_allowlist);
        try st.endObject();
        try st.objectField("limits");
        try st.beginObject();
        const limits = if (sandbox) |s| s.limits else sandbox_mod.Limits{};
        try st.objectField("max_read_bytes");
        try st.write(limits.max_read_bytes);
        try st.objectField("max_write_bytes");
        try st.write(limits.max_write_bytes);
        try st.objectField("max_output_bytes");
        try st.write(limits.max_output_bytes);
        try st.objectField("max_archive_bytes");
        try st.write(limits.max_archive_bytes);
        try st.objectField("max_extracted_bytes");
        try st.write(limits.max_extracted_bytes);
        try st.objectField("max_entries");
        try st.write(limits.max_entries);
        try st.objectField("exec_timeout_ms");
        try st.write(limits.exec_timeout_ms);
        try st.endObject();
        try st.endObject();

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Legacy-compatible status payload (same keys as v1) plus new metrics,
    /// gateways, and models sections. Identifiers and counts only.
    pub fn statusJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        var memories: usize = 0;
        var experiences: usize = 0;
        var strategies: usize = 0;
        var knowledge: usize = 0;
        var task_total: usize = 0;
        var task_completed: usize = 0;
        var task_failed: usize = 0;
        var proposal_total: usize = 0;
        var proposal_proposed: usize = 0;
        var proposal_accepted: usize = 0;
        var proposal_rejected: usize = 0;
        var tool_calls: usize = 0;
        var messages: usize = 0;
        var session_count: usize = 0;
        if (self.sessions) |store| {
            const deps = &store.deps;
            memories = deps.memory.count();
            experiences = deps.experience.count();
            strategies = deps.strategies.count();
            knowledge = deps.knowledge.count();
            if (deps.tasks) |tasks| {
                task_total = tasks.count();
                task_completed = tasks.completedCount();
                task_failed = tasks.failedCount();
                for (tasks.records.items) |record| {
                    tool_calls += record.calls.items.len;
                }
            }
            if (deps.proposals) |proposals| {
                proposal_total = proposals.count();
                proposal_proposed = proposals.countStatus(.proposed);
                proposal_accepted = proposals.countStatus(.accepted);
                proposal_rejected = proposals.countStatus(.rejected);
            }
            session_count = store.count();
            for (&store.entries) |*slot| {
                if (slot.*) |*entry| messages += entry.conversation.messageCount();
            }
        }

        writer.writeAll("{\"agent\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.config.agent_name);
        writer.writeAll(",\"version\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.version);
        writer.writeAll(",\"model\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.activeModel());
        writer.writeAll(",\"provider\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.config.base_url);
        writer.print(",\"provider_connected\":{s}", .{if (self.apiKeyAvailable()) "true" else "false"}) catch return error.OutOfMemory;
        writer.print(",\"memory\":{{\"memories\":{d},\"experiences\":{d},\"strategies\":{d},\"knowledge\":{d}}}", .{
            memories, experiences, strategies, knowledge,
        }) catch return error.OutOfMemory;
        writer.print(",\"tasks\":{{\"total\":{d},\"completed\":{d},\"failed\":{d}}}", .{
            task_total, task_completed, task_failed,
        }) catch return error.OutOfMemory;
        writer.print(",\"proposals\":{{\"total\":{d},\"proposed\":{d},\"accepted\":{d},\"rejected\":{d}}}", .{
            proposal_total, proposal_proposed, proposal_accepted, proposal_rejected,
        }) catch return error.OutOfMemory;
        writer.writeAll(",\"channels\":{\"telegram\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.gateways.state.name());
        writer.print("}},\"sessions\":{{\"count\":{d}}}", .{session_count}) catch return error.OutOfMemory;
        writer.print(",\"metrics\":{{\"messages\":{d},\"tool_calls\":{d},\"successful_runs\":{d},\"failed_runs\":{d}}}", .{
            messages, tool_calls, task_completed, task_failed,
        }) catch return error.OutOfMemory;
        writer.writeAll(",\"gateways\":") catch return error.OutOfMemory;
        const gateways_json = try self.gatewaysData();
        defer self.allocator.free(gateways_json);
        try writer.writeAll(gateways_json);
        writer.print(",\"models\":{{\"count\":{d},\"available\":{s},\"fetched_at_ms\":{d}}}", .{
            self.models.count(),
            if (self.models.fresh()) "true" else "false",
            self.models.fetched_at_ms,
        }) catch return error.OutOfMemory;
        writer.writeAll(",\"active_profile\":") catch return error.OutOfMemory;
        if (self.profiles.activeId()) |active| {
            try appendJsonString(writer, active);
        } else {
            writer.writeAll("null") catch return error.OutOfMemory;
        }
        writer.print(",\"uptime_ms\":{d}}}", .{task_mod.wallClockMs(self.io) -| self.started_at_ms}) catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Structured configuration view: provider, telegram, runtime, owner, and
    /// routing status. Never includes keys, tokens, or provider payloads.
    pub fn configJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"provider\":{\"endpoint\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.config.base_url);
        writer.print(",\"api_key_set\":{s},\"configured\":{s},\"active_model\":", .{
            if (self.apiKeyAvailable()) "true" else "false",
            if (self.apiKeyAvailable() and self.config.base_url.len > 0) "true" else "false",
        }) catch return error.OutOfMemory;
        try appendJsonString(writer, self.activeModel());
        writer.writeAll(",\"configured_model\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.config.model);
        writer.print(",\"model_count\":{d},\"last_model_refresh_ms\":{d}}}", .{
            self.models.count(),
            self.models.fetched_at_ms,
        }) catch return error.OutOfMemory;

        writer.writeAll(",\"telegram\":{\"configured\":") catch return error.OutOfMemory;
        writer.writeAll(if (self.gateways.configured()) "true" else "false") catch return error.OutOfMemory;
        writer.writeAll(",\"token_set\":") catch return error.OutOfMemory;
        writer.writeAll(if (self.gateways.configured()) "true" else "false") catch return error.OutOfMemory;
        writer.writeAll(",\"enabled\":") catch return error.OutOfMemory;
        writer.writeAll(if (self.gateways.enabled) "true" else "false") catch return error.OutOfMemory;
        writer.writeAll(",\"state\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.gateways.state.name());
        writer.print(",\"allowed_users\":{d}}}", .{self.gateways.allowed_users}) catch return error.OutOfMemory;

        writer.print(",\"runtime\":{{\"workspace\":\".\",\"data_dir\":\"data\",\"config_path\":\"config/config.json\",\"settings_path\":", .{}) catch return error.OutOfMemory;
        try appendJsonString(writer, settings_mod.path);
        writer.writeAll(",\"dashboard_host\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.dashboard_host);
        writer.print(",\"dashboard_port\":{d},\"auth_required\":{s}}}", .{
            self.dashboard_port,
            if (self.auth_required) "true" else "false",
        }) catch return error.OutOfMemory;

        if (self.owner_context) |owner_context| {
            writer.writeAll(",\"owner\":{\"soul\":") catch return error.OutOfMemory;
            try appendJsonString(writer, owner_context.soul.status.name());
            writer.writeAll(",\"memory\":") catch return error.OutOfMemory;
            try appendJsonString(writer, owner_context.memory.status.name());
            writer.writeAll(",\"active_profile\":") catch return error.OutOfMemory;
            if (self.profiles.activeId()) |active| {
                try appendJsonString(writer, active);
            } else {
                writer.writeAll("null") catch return error.OutOfMemory;
            }
            writer.writeAll("}") catch return error.OutOfMemory;
        }

        writer.print(",\"routing\":{{\"teacher_configured\":{s},\"local_only\":{s}}}}}", .{
            if (self.config.routing.teacherConfigured()) "true" else "false",
            if (self.config.routing.local_only) "true" else "false",
        }) catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Effective runtime settings plus read-only runtime facts. Appearance
    /// preferences are client-side and intentionally absent.
    pub fn settingsJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"model\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.activeModel());
        writer.writeAll(",\"model_source\":") catch return error.OutOfMemory;
        try appendJsonString(writer, if (self.settings.model != null) "settings" else "config");
        writer.print(",\"task_max_attempts\":{d},\"task_max_attempts_source\":", .{
            self.effectiveAttempts(),
        }) catch return error.OutOfMemory;
        try appendJsonString(writer, if (self.settings.task_max_attempts != null) "settings" else "config");
        writer.writeAll(",\"limits\":{\"max_attempts\":") catch return error.OutOfMemory;
        writer.print("{d}", .{settings_mod.max_attempts_limit}) catch return error.OutOfMemory;
        writer.writeAll(",\"max_model_len\":") catch return error.OutOfMemory;
        writer.print("{d}}}", .{settings_mod.max_model_len}) catch return error.OutOfMemory;

        writer.writeAll(",\"runtime\":{\"workspace\":\".\",\"data_dir\":\"data\",\"log_level\":\"info\"") catch return error.OutOfMemory;
        writer.writeAll(",\"dashboard_host\":") catch return error.OutOfMemory;
        try appendJsonString(writer, self.dashboard_host);
        writer.print(",\"dashboard_port\":{d},\"auth_required\":{s},\"debug_default\":false}}", .{
            self.dashboard_port,
            if (self.auth_required) "true" else "false",
        }) catch return error.OutOfMemory;
        writer.writeAll("}") catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    pub fn effectiveAttempts(self: *const Services) u8 {
        if (self.settings.task_max_attempts) |attempts| return attempts;
        return self.config.task_max_attempts;
    }

    /// Validate, persist, and apply a settings update. Only values the
    /// runtime actually honors are accepted.
    pub fn putSettings(self: *Services, model: ?[]const u8, clear_model: bool, attempts: ?u8) Outcome {
        if (clear_model and model == null) {
            const err = self.settings.update(null, attempts);
            if (err) |message| return Outcome.fail("INVALID_VALUE", message);
        } else if (model) |value| {
            const err = self.settings.update(value, attempts);
            if (err) |message| return Outcome.fail("INVALID_VALUE", message);
        } else {
            const err = self.settings.update(null, attempts);
            if (err) |message| return Outcome.fail("INVALID_VALUE", message);
        }

        if (self.persist_settings) {
            self.settings.save(self.io) catch {
                return Outcome.fail("PERSIST_FAILED", "Settings were applied but could not be saved.");
            };
        }
        self.applyModelOverride() catch return Outcome.fail("INTERNAL", "Applying the model override failed.");
        // New conversations use the updated retry budget.
        if (self.sessions) |store| {
            if (self.settings.task_max_attempts) |value| store.deps.retry.max_attempts = value;
        }
        const payload = self.settingsJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// Profile list payload.
    pub fn profilesJson(self: *Services) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        const writer = &output.writer;

        writer.writeByte('[') catch return error.OutOfMemory;
        const infos = self.profiles.list() catch return error.OutOfMemory;
        defer profiles_mod.freeInfos(self.allocator, infos);
        for (infos, 0..) |info, index| {
            if (index > 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll("{\"id\":") catch return error.OutOfMemory;
            try appendJsonString(writer, info.id);
            writer.writeAll(",\"name\":") catch return error.OutOfMemory;
            try appendJsonString(writer, info.name);
            writer.writeAll(",\"description\":") catch return error.OutOfMemory;
            try appendJsonString(writer, info.description);
            writer.print(",\"active\":{s}}}", .{if (info.active) "true" else "false"}) catch return error.OutOfMemory;
        }
        writer.writeByte(']') catch return error.OutOfMemory;

        var list = output.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Full profile detail: manifest plus every editable file's content.
    pub fn profileDetailJson(self: *Services, id: []const u8) !?[]u8 {
        if (!self.profiles.exists(id)) return null;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        writer.writeAll("{\"id\":") catch return error.OutOfMemory;
        try appendJsonString(writer, id);
        writer.writeAll(",\"active\":") catch return error.OutOfMemory;
        if (self.profiles.activeId()) |active| {
            writer.writeAll(if (std.mem.eql(u8, active, id)) "true" else "false") catch return error.OutOfMemory;
        } else {
            writer.writeAll("false") catch return error.OutOfMemory;
        }
        const keys = [_]profiles_mod.FileKey{ .soul, .memory, .instructions, .behavior, .custom };
        for (keys) |key| {
            writer.writeByte(',') catch return error.OutOfMemory;
            try appendJsonString(writer, key.fileName());
            writer.writeByte(':') catch return error.OutOfMemory;
            if (self.profiles.readFileAlloc(id, key)) |content| {
                defer self.allocator.free(content);
                try appendJsonString(writer, content);
            } else |_| {
                writer.writeAll("null") catch return error.OutOfMemory;
            }
        }
        writer.writeAll("}") catch return error.OutOfMemory;

        var list = output.toArrayList();
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn profileCreate(self: *Services, id: []const u8, name: []const u8, description: []const u8) Outcome {
        self.profiles.create(id, name, description) catch |err| return switch (err) {
            error.InvalidId => Outcome.fail("INVALID_PROFILE_ID", "Profile id must be 1-64 chars of [a-z0-9-_]."),
            error.AlreadyExists => Outcome.fail("ALREADY_EXISTS", "A profile with that id already exists."),
            else => Outcome.fail("PROFILE_IO_FAILED", "Creating the profile failed."),
        };
        const payload = self.profilesJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn profileDuplicate(self: *Services, source: []const u8, id: []const u8, name: []const u8) Outcome {
        self.profiles.duplicate(source, id, name) catch |err| return switch (err) {
            error.InvalidId => Outcome.fail("INVALID_PROFILE_ID", "Profile id must be 1-64 chars of [a-z0-9-_]."),
            error.NotFound => Outcome.fail("PROFILE_NOT_FOUND", "Source profile not found."),
            error.AlreadyExists => Outcome.fail("ALREADY_EXISTS", "A profile with that id already exists."),
            else => Outcome.fail("PROFILE_IO_FAILED", "Duplicating the profile failed."),
        };
        const payload = self.profilesJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    pub fn profileDelete(self: *Services, id: []const u8) Outcome {
        self.profiles.delete(id) catch |err| return switch (err) {
            error.InvalidId => Outcome.fail("INVALID_PROFILE_ID", "Invalid profile id."),
            error.NotFound => Outcome.fail("PROFILE_NOT_FOUND", "Profile not found."),
            error.ActiveProfile => Outcome.fail("PROFILE_ACTIVE", "The active profile cannot be deleted; activate another first."),
            else => Outcome.fail("PROFILE_IO_FAILED", "Deleting the profile failed."),
        };
        const payload = self.profilesJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }

    /// Replace one whitelisted profile file. The file key comes from a fixed
    /// enum — arbitrary paths from the browser are impossible by design.
    pub fn profileUpdateFile(self: *Services, id: []const u8, file_key: []const u8, content: []const u8) Outcome {
        const key = profiles_mod.FileKey.fromString(file_key) orelse
            return Outcome.fail("INVALID_PROFILE_FILE", "Unknown profile file key.");
        self.profiles.writeFile(id, key, content) catch |err| return switch (err) {
            error.InvalidId => Outcome.fail("INVALID_PROFILE_ID", "Invalid profile id."),
            error.NotFound => Outcome.fail("PROFILE_NOT_FOUND", "Profile not found."),
            error.FileTooLarge => Outcome.fail("FILE_TOO_LARGE", "Profile file exceeds the size cap."),
            else => Outcome.fail("PROFILE_IO_FAILED", "Writing the profile file failed."),
        };
        // An active profile's edits take effect for new conversations.
        if (self.profiles.activeId()) |active| {
            if (std.mem.eql(u8, active, id) and (key == .soul or key == .memory)) {
                self.applyActiveProfileToOwner(id);
                self.rebuildSystemPrompt() catch {};
            }
        }
        const payload = self.profileDetailJson(id) catch return Outcome.fail("INTERNAL", "Encoding failed.");
        if (payload) |value| return .{ .ok = value };
        return Outcome.fail("INTERNAL", "Encoding failed.");
    }

    fn applyActiveProfileToOwner(self: *Services, id: []const u8) void {
        const owner_context = self.owner_context orelse return;
        const soul = self.profiles.readFileAlloc(id, .soul) catch return;
        defer self.allocator.free(soul);
        owner_context.saveSoul(soul) catch {};
        if (self.profiles.readFileAlloc(id, .memory)) |memory| {
            defer self.allocator.free(memory);
            owner_context.saveMemory(memory) catch {};
        } else |_| {}
        owner_context.reload();
    }

    pub fn profileActivate(self: *Services, id: []const u8) Outcome {
        self.profiles.activate(id) catch |err| return switch (err) {
            error.InvalidId => Outcome.fail("INVALID_PROFILE_ID", "Invalid profile id."),
            error.NotFound => Outcome.fail("PROFILE_NOT_FOUND", "Profile not found."),
            else => Outcome.fail("PROFILE_IO_FAILED", "Activating the profile failed."),
        };
        self.rebuildSystemPrompt() catch {};
        const payload = self.profilesJson() catch return Outcome.fail("INTERNAL", "Encoding failed.");
        return .{ .ok = payload };
    }
};

fn writeStringArray(st: *std.json.Stringify, values: []const []const u8) !void {
    try st.beginArray();
    for (values) |value| try st.write(value);
    try st.endArray();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// ---------------------------------------------------------------------------
// Job functions
//
// Background work that belongs to a real subsystem runs here, on the job
// runtime's worker thread. Each function owns its `user` context and frees
// it when the job ends; cancellation and timeouts flow through checkpoint().
// ---------------------------------------------------------------------------

/// Context for an attachment-extraction job.
const ExtractJobCtx = struct {
    services: *Services,
    id: []u8,
};

fn extractAttachmentJobFn(ctx: *jobs_mod.Context, allocator: std.mem.Allocator) anyerror![]u8 {
    const user: *ExtractJobCtx = @ptrCast(@alignCast(ctx.job.user.?));
    defer {
        allocator.free(user.id);
        allocator.destroy(user);
    }
    try ctx.checkpoint();

    const store = user.services.attachments orelse return error.ServerUnavailable;
    const record = try store.extract(user.id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"attachment_id\":\"{s}\",\"extracted\":{d},\"status\":\"{s}\"}}", .{
        record.id,
        record.extracted_count,
        record.status.name(),
    });
    return out.toOwnedSlice();
}

fn doctorJobFn(ctx: *jobs_mod.Context, allocator: std.mem.Allocator) anyerror![]u8 {
    const self: *Services = @ptrCast(@alignCast(ctx.job.user.?));
    try ctx.checkpoint();

    var report = try doctor_mod.run(allocator, self.doctorInputs());
    defer report.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try report.writeJson(&stringify);
    return out.toOwnedSlice();
}
