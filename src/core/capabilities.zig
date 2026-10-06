//! Runtime capability manifest.
//!
//! The manifest is the single source of truth for "what can this runtime
//! actually do right now". It is assembled from live runtime state (registered
//! tools, gateway state, provider configuration) — never from configuration
//! intent alone — and is consumed two ways:
//!
//! 1. `renderPrompt` produces a concise system-prompt section so the model
//!    never claims a channel, tool, or action the runtime does not expose.
//! 2. `writeJson` feeds the dashboard `/api/capabilities` endpoint.
//!
//! This module is pure: it renders from the plain input structs below and
//! performs no I/O, so every rule here is unit-testable.

const std = @import("std");

/// One channel's runtime availability. `enabled` must reflect the *actual*
/// runtime state: a configured Telegram token with the channel not running is
/// NOT an enabled channel.
pub const ChannelCap = struct {
    name: []const u8,
    enabled: bool,
    /// Short reason when disabled (e.g. "disabled", "not configured").
    note: []const u8 = "",
};

pub const ToolCap = struct {
    name: []const u8,
    enabled: bool,
};

pub const Channels = struct {
    cli: bool = true,
    /// True only when the Telegram gateway is actually running/available in
    /// this runtime — not merely when a token exists.
    telegram: bool = false,
    telegram_note: []const u8 = "disabled",
    dashboard: bool = false,
};

pub const Gateways = struct {
    /// Inbound Telegram messages can be received by this process.
    telegram_receive: bool = false,
    /// Outbound telegram.send_message tool permission is explicitly granted.
    telegram_send: bool = false,
    /// Telegram bot commands (/start, /help, …) are handled.
    telegram_commands: bool = false,
};

pub const Provider = struct {
    /// Endpoint configured AND credentials available in this process.
    available: bool = false,
    model_discovery: bool = true,
    streaming: bool = false,
    vision: bool = false,
    tool_calling: bool = false,
    note: []const u8 = "",
};

pub const Workspace = struct {
    read: bool = true,
    write: bool = true,
    /// Only true when an execution tool (e.g. a command runner) is registered;
    /// Pico Claw has none by default.
    execute: bool = false,
    root: []const u8 = ".",
};

/// MCP external-tool runtime state. `enabled` is true only when the MCP
/// registry is attached, the kill switch is on, and at least one server is
/// actually running — configuration alone never counts.
pub const Mcp = struct {
    enabled: bool = false,
    servers_configured: usize = 0,
    servers_running: usize = 0,
    tools_available: usize = 0,
    note: []const u8 = "not configured",
};

pub const Manifest = struct {
    channels: Channels = .{},
    gateways: Gateways = .{},
    provider: Provider = .{},
    workspace: Workspace = .{},
    mcp: Mcp = .{},
    tools: []const ToolCap = &.{},
    /// Operations subsystems: true only when the service is actually attached
    /// to this runtime (never merely because a feature exists in the binary).
    attachments: bool = false,
    artifacts: bool = false,
    jobs: bool = false,
    runs: bool = false,
    /// Typed long-term memory store availability (entries count is advisory).
    memory_available: bool = true,
    memory_entries: usize = 0,
    /// In-session conversation management (list/clear sessions).
    session_management: bool = true,

    pub fn toolEnabled(self: *const Manifest, name: []const u8) bool {
        for (self.tools) |tool| {
            if (tool.enabled and std.mem.eql(u8, tool.name, name)) return true;
        }
        return false;
    }
};

fn appendEnabled(writer: *std.Io.Writer, name: []const u8, enabled: bool, note: []const u8) !void {
    try writer.print("{s}: ", .{name});
    if (enabled) {
        try writer.writeAll("enabled");
    } else {
        try writer.writeAll("disabled");
        if (note.len > 0) try writer.print(" ({s})", .{note});
    }
}

/// Render the concise, authoritative capability section injected into the
/// agent's system context. The model is instructed to treat it as the exact
/// boundary of what it may claim.
pub fn renderPrompt(allocator: std.mem.Allocator, manifest: *const Manifest) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.writeAll(
        "## Runtime capabilities (authoritative)\n" ++
            "You are part of a runtime with exactly these capabilities. Never claim " ++
            "a channel, tool, or action that is not listed here; if a request needs " ++
            "something absent, say so plainly.\n",
    );

    try writer.writeAll("Channels: ");
    try appendEnabled(writer, "CLI chat", manifest.channels.cli, "");
    try writer.writeAll("; ");
    try appendEnabled(writer, "Telegram", manifest.channels.telegram, manifest.channels.telegram_note);
    try writer.writeAll("; ");
    try appendEnabled(writer, "Web dashboard", manifest.channels.dashboard, "");
    try writer.writeAll("\n");

    try writer.writeAll("Tools you may call:");
    var first_tool = true;
    for (manifest.tools) |tool| {
        if (!tool.enabled) continue;
        try writer.writeAll(if (first_tool) " " else ", ");
        try writer.writeAll(tool.name);
        first_tool = false;
    }
    if (first_tool) {
        try writer.writeAll(" none");
    }
    try writer.writeAll("\n");

    try writer.writeAll("Gateways: ");
    try appendEnabled(writer, "telegram receive", manifest.gateways.telegram_receive, "");
    try writer.writeAll("; ");
    try appendEnabled(writer, "telegram send", manifest.gateways.telegram_send, "explicit permission required");
    try writer.writeAll("; ");
    try appendEnabled(writer, "telegram commands", manifest.gateways.telegram_commands, "");
    try writer.writeAll("\n");

    if (manifest.provider.available) {
        try writer.writeAll("Provider: connected");
    } else {
        try writer.writeAll("Provider: unavailable");
        if (manifest.provider.note.len > 0) {
            try writer.print(" ({s})", .{manifest.provider.note});
        }
    }
    try writer.print(" (model discovery: {s}; streaming: {s}; vision: {s}; tool calling: {s})\n", .{
        yesNo(manifest.provider.model_discovery),
        yesNo(manifest.provider.streaming),
        yesNo(manifest.provider.vision),
        yesNo(manifest.provider.tool_calling),
    });

    try writer.print(
        "Workspace: read {s}, write {s}, execute {s}; root \"{s}\"\n",
        .{
            yesNo(manifest.workspace.read),
            yesNo(manifest.workspace.write),
            yesNo(manifest.workspace.execute),
            manifest.workspace.root,
        },
    );

    // MCP external tools are only listed when they actually work right now.
    if (manifest.mcp.enabled) {
        try writer.print(
            "MCP external tools: enabled ({d} server(s) running of {d} configured; {d} tools available)\n",
            .{
                manifest.mcp.servers_running,
                manifest.mcp.servers_configured,
                manifest.mcp.tools_available,
            },
        );
    } else {
        try writer.writeAll("MCP external tools: unavailable");
        if (manifest.mcp.note.len > 0) {
            try writer.print(" ({s})", .{manifest.mcp.note});
        }
        try writer.writeAll("\n");
    }

    // Operations subsystems, stated exactly as they are.
    try writer.print("Attachments: {s}\n", .{if (manifest.attachments) "enabled" else "unavailable"});
    try writer.print("Artifacts: {s} (supported: txt, md, json, csv, zip; pdf/docx/pptx/xlsx unsupported)\n", .{
        if (manifest.artifacts) "enabled" else "unavailable",
    });
    try writer.print("Background jobs: {s}\n", .{if (manifest.jobs) "enabled" else "unavailable"});
    try writer.print("Run history: {s}\n", .{if (manifest.runs) "enabled" else "unavailable"});

    if (manifest.memory_available) {
        try writer.print("Memory: available ({d} entries)\n", .{manifest.memory_entries});
    } else {
        try writer.writeAll("Memory: unavailable\n");
    }
    try writer.print("Sessions: {s}\n", .{if (manifest.session_management) "in-session management available" else "unavailable"});

    return output.toOwnedSlice();
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn writeBool(writer: *std.json.Stringify, value: bool) !void {
    try writer.write(value);
}

/// Stable JSON shape for the `/api/capabilities` endpoint. Keys are fixed so
/// the dashboard can rely on them.
pub fn writeJson(writer: *std.json.Stringify, manifest: *const Manifest) !void {
    try writer.beginObject();

    try writer.objectField("channels");
    try writer.beginObject();
    try writer.objectField("cli");
    try writeBool(writer, manifest.channels.cli);
    try writer.objectField("telegram");
    try writeBool(writer, manifest.channels.telegram);
    try writer.objectField("telegram_note");
    try writer.write(manifest.channels.telegram_note);
    try writer.objectField("dashboard");
    try writeBool(writer, manifest.channels.dashboard);
    try writer.endObject();

    try writer.objectField("gateways");
    try writer.beginObject();
    try writer.objectField("telegram_receive");
    try writeBool(writer, manifest.gateways.telegram_receive);
    try writer.objectField("telegram_send");
    try writeBool(writer, manifest.gateways.telegram_send);
    try writer.objectField("telegram_commands");
    try writeBool(writer, manifest.gateways.telegram_commands);
    try writer.endObject();

    try writer.objectField("provider");
    try writer.beginObject();
    try writer.objectField("available");
    try writeBool(writer, manifest.provider.available);
    try writer.objectField("model_discovery");
    try writeBool(writer, manifest.provider.model_discovery);
    try writer.objectField("streaming");
    try writeBool(writer, manifest.provider.streaming);
    try writer.objectField("vision");
    try writeBool(writer, manifest.provider.vision);
    try writer.objectField("tool_calling");
    try writeBool(writer, manifest.provider.tool_calling);
    try writer.endObject();

    try writer.objectField("workspace");
    try writer.beginObject();
    try writer.objectField("read");
    try writeBool(writer, manifest.workspace.read);
    try writer.objectField("write");
    try writeBool(writer, manifest.workspace.write);
    try writer.objectField("execute");
    try writeBool(writer, manifest.workspace.execute);
    try writer.objectField("root");
    try writer.write(manifest.workspace.root);
    try writer.endObject();

    try writer.objectField("mcp");
    try writer.beginObject();
    try writer.objectField("enabled");
    try writeBool(writer, manifest.mcp.enabled);
    try writer.objectField("servers_configured");
    try writer.write(manifest.mcp.servers_configured);
    try writer.objectField("servers_running");
    try writer.write(manifest.mcp.servers_running);
    try writer.objectField("tools_available");
    try writer.write(manifest.mcp.tools_available);
    try writer.objectField("note");
    try writer.write(manifest.mcp.note);
    try writer.endObject();

    try writer.objectField("operations");
    try writer.beginObject();
    try writer.objectField("attachments");
    try writeBool(writer, manifest.attachments);
    try writer.objectField("artifacts");
    try writeBool(writer, manifest.artifacts);
    try writer.objectField("jobs");
    try writeBool(writer, manifest.jobs);
    try writer.objectField("runs");
    try writeBool(writer, manifest.runs);
    try writer.endObject();

    try writer.objectField("tools");
    try writer.beginArray();
    for (manifest.tools) |tool| {
        try writer.beginObject();
        try writer.objectField("name");
        try writer.write(tool.name);
        try writer.objectField("enabled");
        try writeBool(writer, tool.enabled);
        try writer.endObject();
    }
    try writer.endArray();

    try writer.objectField("memory_available");
    try writeBool(writer, manifest.memory_available);
    try writer.objectField("memory_entries");
    try writer.write(manifest.memory_entries);
    try writer.objectField("session_management");
    try writeBool(writer, manifest.session_management);

    try writer.endObject();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "disabled telegram is reported disabled in the prompt" {
    const manifest = Manifest{ .channels = .{ .cli = true, .telegram = false, .telegram_note = "disabled", .dashboard = true } };
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Telegram: disabled (disabled)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Web dashboard: enabled") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CLI chat: enabled") != null);
}

test "enabled telegram is reported enabled in the prompt" {
    const manifest = Manifest{ .channels = .{ .telegram = true, .telegram_note = "" } };
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Telegram: enabled") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Telegram: disabled") == null);
}

test "dashboard capability is visible when enabled" {
    const manifest = Manifest{ .channels = .{ .dashboard = true } };
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Web dashboard: enabled") != null);
}

test "unavailable provider is marked unavailable with its note" {
    const manifest = Manifest{ .provider = .{ .available = false, .note = "missing API key" } };
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Provider: unavailable (missing API key)") != null);
}

test "enabled tools appear and disabled tools are excluded from the prompt" {
    var tools = [_]ToolCap{
        .{ .name = "calculator", .enabled = true },
        .{ .name = "filesystem", .enabled = false },
        .{ .name = "system", .enabled = true },
    };
    const manifest = Manifest{ .tools = &tools };
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "calculator") != null);
    try testing.expect(std.mem.indexOf(u8, text, "system") != null);
    try testing.expect(std.mem.indexOf(u8, text, "filesystem") == null);
    try testing.expect(manifest.toolEnabled("calculator"));
    try testing.expect(!manifest.toolEnabled("filesystem"));
    try testing.expect(!manifest.toolEnabled("missing"));
}

test "no tools renders the explicit none line" {
    const manifest = Manifest{};
    const text = try renderPrompt(testing.allocator, &manifest);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Tools you may call: none") != null);
}

test "json shape is stable and exposes every section" {
    var tools = [_]ToolCap{
        .{ .name = "calculator", .enabled = true },
        .{ .name = "filesystem", .enabled = false },
    };
    const manifest = Manifest{
        .channels = .{ .cli = true, .telegram = true, .telegram_note = "", .dashboard = true },
        .gateways = .{ .telegram_receive = true, .telegram_send = true, .telegram_commands = true },
        .provider = .{ .available = true },
        .workspace = .{ .root = "/ws" },
        .tools = &tools,
        .memory_entries = 3,
    };

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try writeJson(&stringify, &manifest);

    const json = output.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"channels\":{\"cli\":true,\"telegram\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"telegram_send\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"provider\":{\"available\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"root\":\"/ws\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"filesystem\",\"enabled\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"memory_entries\":3") != null);

    // The JSON must parse.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "gateway capabilities default to unavailable" {
    const manifest = Manifest{};
    try testing.expect(!manifest.gateways.telegram_receive);
    try testing.expect(!manifest.gateways.telegram_send);
    try testing.expect(!manifest.gateways.telegram_commands);
}

test "mcp is unavailable by default and reflects real runtime state" {
    const off = Manifest{};
    const text = try renderPrompt(testing.allocator, &off);
    defer testing.allocator.free(text);
    try testing.expect(
        std.mem.indexOf(u8, text, "MCP external tools: unavailable (not configured)") != null,
    );

    const off_with_note = Manifest{ .mcp = .{ .enabled = false, .note = "disabled by operator" } };
    const note_text = try renderPrompt(testing.allocator, &off_with_note);
    defer testing.allocator.free(note_text);
    try testing.expect(
        std.mem.indexOf(u8, note_text, "MCP external tools: unavailable (disabled by operator)") != null,
    );

    const on = Manifest{ .mcp = .{
        .enabled = true,
        .servers_configured = 3,
        .servers_running = 2,
        .tools_available = 17,
    } };
    const on_text = try renderPrompt(testing.allocator, &on);
    defer testing.allocator.free(on_text);
    try testing.expect(
        std.mem.indexOf(u8, on_text, "MCP external tools: enabled (2 server(s) running of 3 configured; 17 tools available)") != null,
    );
}

test "mcp json section is present and parseable" {
    var tools = [_]ToolCap{
        .{ .name = "mcp.demo.echo", .enabled = true },
    };
    const manifest = Manifest{
        .mcp = .{
            .enabled = true,
            .servers_configured = 1,
            .servers_running = 1,
            .tools_available = 1,
            .note = "",
        },
        .tools = &tools,
    };
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try writeJson(&stringify, &manifest);

    const json = output.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"mcp\":{\"enabled\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"servers_running\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tools_available\":1") != null);
}

test "operations subsystems are reported honestly in prompt and json" {
    // Nothing attached: everything unavailable, never "enabled".
    const off = Manifest{};
    const off_text = try renderPrompt(testing.allocator, &off);
    defer testing.allocator.free(off_text);
    try testing.expect(std.mem.indexOf(u8, off_text, "Attachments: unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, off_text, "Artifacts: unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, off_text, "Background jobs: unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, off_text, "Run history: unavailable") != null);
    // The unsupported formats are named even when the subsystem is off.
    try testing.expect(std.mem.indexOf(u8, off_text, "pdf/docx/pptx/xlsx unsupported") != null);

    const on = Manifest{ .attachments = true, .artifacts = true, .jobs = true, .runs = true };
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try writeJson(&stringify, &on);
    const json = output.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"operations\":{\"attachments\":true,\"artifacts\":true,\"jobs\":true,\"runs\":true}") != null);
}
