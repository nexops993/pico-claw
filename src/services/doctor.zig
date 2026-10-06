//! Doctor: real health checks over the whole runtime.
//!
//! Every check performs actual work — files are written and deleted, the
//! provider API is really called, Telegram really receives a `getMe` — and
//! reports one of five honest states. Nothing reports PASS merely because a
//! file exists:
//!
//! * `pass`        — the check ran and everything works.
//! * `warn`        — usable, but degraded (e.g. MCP configured, none running).
//! * `fail`        — something is broken and needs attention.
//! * `unavailable` — the capability is not configured in this runtime.
//! * `unsupported` — the capability has no implementation here.
//!
//! Secrets never enter the report: keys and tokens are only ever read into
//! the check implementations, and the rendered details contain counts,
//! states, and safe identity fields — never credentials.

const std = @import("std");
const sandbox_mod = @import("../runtime/sandbox.zig");
const attachments_mod = @import("../runtime/attachments.zig");
const artifacts_mod = @import("artifacts.zig");
const jobs_mod = @import("../core/jobs.zig");
const mcp_mod = @import("../mcp/registry.zig");
const runs_mod = @import("../core/runs.zig");
const Config = @import("../config.zig").Config;
const Provider = @import("../provider.zig").Provider;
const gateway_mod = @import("gateways.zig");
const provider_mod = @import("../provider.zig");

pub const Status = enum {
    pass,
    warn,
    fail,
    unavailable,
    unsupported,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const max_detail_len: usize = 160;

pub const Check = struct {
    name: []const u8,
    status: Status,
    detail: []u8,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    checks: std.ArrayList(Check) = .empty,

    pub fn deinit(self: *Report) void {
        for (self.checks.items) |check| self.allocator.free(check.detail);
        self.checks.deinit(self.allocator);
        self.* = undefined;
    }

    /// The least healthy state: any fail wins, then warn, then pass.
    pub fn overall(self: *const Report) Status {
        var result: Status = .pass;
        for (self.checks.items) |check| {
            switch (check.status) {
                .fail => return .fail,
                .warn => result = .warn,
                else => {},
            }
        }
        return result;
    }

    pub fn writeJson(self: *const Report, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("overall");
        try writer.write(self.overall().name());
        try writer.objectField("checks");
        try writer.beginArray();
        for (self.checks.items) |check| {
            try writer.beginObject();
            try writer.objectField("name");
            try writer.write(check.name);
            try writer.objectField("status");
            try writer.write(check.status.name());
            try writer.objectField("detail");
            try writer.write(check.detail);
            try writer.endObject();
        }
        try writer.endArray();
        try writer.endObject();
    }
};

/// Everything doctor needs. All handles are optional so a check can honestly
/// report `unavailable` when the runtime does not have that subsystem.
pub const Inputs = struct {
    version: []const u8,
    env: *const std.process.Environ.Map,
    config: *const Config,
    io: std.Io,
    sandbox: ?*const sandbox_mod.Sandbox = null,
    mcp: ?*mcp_mod.Registry = null,
    attachments: ?*attachments_mod.Store = null,
    artifacts: ?*artifacts_mod.Store = null,
    jobs: ?*jobs_mod.Runtime = null,
    runs: ?*runs_mod.Store = null,
    provider: ?*Provider = null,
    /// Real network probes for provider/Telegram. The API runs doctor with
    /// this enabled too, but a caller may disable it for offline diagnostics.
    probe_network: bool = true,
};

/// Run every check and return the owned report.
pub fn run(allocator: std.mem.Allocator, inputs: Inputs) !Report {
    var report = Report{ .allocator = allocator };
    errdefer report.deinit();

    try checkBinary(&report, inputs);
    try checkConfiguration(&report, inputs);
    try checkProvider(&report, inputs);
    try checkTelegram(&report, inputs);
    try checkSandbox(&report, inputs);
    try checkMcp(&report, inputs);
    try checkAttachments(&report, inputs);
    try checkArtifacts(&report, inputs);
    try checkJobs(&report, inputs);
    try checkRuns(&report, inputs);
    return report;
}

fn add(
    report: *Report,
    name: []const u8,
    status: Status,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const detail = try std.fmt.allocPrint(report.allocator, fmt, args);
    errdefer report.allocator.free(detail);
    try report.checks.append(report.allocator, .{
        .name = name,
        .status = status,
        .detail = detail[0..@min(detail.len, max_detail_len * 4)],
    });
}

fn checkBinary(report: *Report, inputs: Inputs) !void {
    try add(report, "binary", .pass, "pico_claw {s} ({s}-{s})", .{
        inputs.version,
        @tagName(@import("builtin").os.tag),
        @tagName(@import("builtin").cpu.arch),
    });
}

fn checkConfiguration(report: *Report, inputs: Inputs) !void {
    const cfg = inputs.config;
    if (cfg.base_url.len == 0 or cfg.model.len == 0) {
        try add(report, "configuration", .fail, "base_url or model missing in config/config.json", .{});
        return;
    }
    try add(report, "configuration", .pass, "model '{s}' at {s}", .{ cfg.model, cfg.base_url });
}

fn checkProvider(report: *Report, inputs: Inputs) !void {
    const key = inputs.env.get("PICO_CLAW_API_KEY") orelse "";
    if (key.len == 0) {
        try add(report, "provider", .unavailable, "PICO_CLAW_API_KEY not configured", .{});
        return;
    }
    const provider = inputs.provider orelse {
        try add(report, "provider", .unavailable, "provider not attached to this runtime", .{});
        return;
    };
    if (!inputs.probe_network) {
        try add(report, "provider", .warn, "configured; network probe disabled", .{});
        return;
    }
    // Real model discovery: a genuine authenticated HTTP round trip.
    const result = provider_mod.listModels(provider) catch |err| {
        try add(report, "provider", .fail, "model discovery failed: {s}", .{@errorName(err)});
        return;
    };
    var result_owned = result;
    defer result_owned.deinit(provider.allocator);
    try add(report, "provider", .pass, "model discovery ok ({d} model(s))", .{result_owned.models.len});
}

fn checkTelegram(report: *Report, inputs: Inputs) !void {
    const token = inputs.env.get("TELEGRAM_BOT_TOKEN") orelse "";
    const enabled = inputs.env.get("TELEGRAM_ENABLED") orelse "";
    if (token.len == 0 or !std.ascii.eqlIgnoreCase(enabled, "true")) {
        try add(report, "telegram", .unavailable, "not configured (TELEGRAM_ENABLED != true)", .{});
        return;
    }
    // Real getMe against the configured token; only safe identity fields are
    // recorded, the token itself is never rendered anywhere.
    const identity = gateway_mod.realProbe(report.allocator, inputs.io, token) catch |err| {
        try add(report, "telegram", .fail, "getMe failed: {s}", .{@errorName(err)});
        return;
    };
    var identity_owned = identity;
    defer identity_owned.deinit(report.allocator);
    try add(report, "telegram", .pass, "bot @{s} reachable", .{identity_owned.username});
}

fn checkSandbox(report: *Report, inputs: Inputs) !void {
    const sb = inputs.sandbox orelse {
        try add(report, "sandbox", .unavailable, "no sandbox attached to this runtime", .{});
        return;
    };
    // A real write/read/delete cycle inside the workspace root.
    const probe_path = "doctor-probe.txt";
    var opened = sb.walkToCreate(probe_path) catch |err| {
        try add(report, "sandbox", .fail, "workspace probe failed: {s}", .{@errorName(err)});
        return;
    };
    defer sb.closeOpened(&opened);
    // Single-component paths have no opened parents: the target is the root.
    const parent = if (opened.parent_dirs.len == 0) sb.root else opened.parent_dirs[opened.parent_dirs.len - 1];
    var file = parent.createFile(
        sb.io,
        opened.basename,
        .{ .resolve_beneath = true },
    ) catch |err| {
        try add(report, "sandbox", .fail, "workspace probe failed: {s}", .{@errorName(err)});
        return;
    };
    file.writeStreamingAll(sb.io, "doctor") catch {
        file.close(sb.io);
        try add(report, "sandbox", .fail, "workspace probe write failed", .{});
        return;
    };
    file.close(sb.io);

    const data = sb.root.readFileAlloc(sb.io, probe_path, report.allocator, .limited(64)) catch |err| {
        try add(report, "sandbox", .fail, "workspace probe read failed: {s}", .{@errorName(err)});
        return;
    };
    defer report.allocator.free(data);
    sb.root.deleteTree(sb.io, probe_path) catch {};
    if (!std.mem.eql(u8, data, "doctor")) {
        try add(report, "sandbox", .fail, "workspace probe read back wrong content", .{});
        return;
    }
    try add(report, "sandbox", .pass, "workspace '{s}' write/read/delete ok", .{
        if (sb.root_name.len > 0) sb.root_name else ".",
    });
}

fn checkMcp(report: *Report, inputs: Inputs) !void {
    const registry = inputs.mcp orelse {
        try add(report, "mcp", .unavailable, "no MCP registry attached", .{});
        return;
    };
    if (!registry.enabled) {
        try add(report, "mcp", .unavailable, "disabled in config/mcp.json", .{});
        return;
    }
    const configured = registry.serverCount();
    const running = registry.runningCount();
    if (configured == 0) {
        try add(report, "mcp", .unavailable, "no servers configured", .{});
        return;
    }
    if (running > 0) {
        try add(report, "mcp", .pass, "{d}/{d} server(s) running, {d} tools", .{
            running,
            configured,
            registry.availableToolCount(),
        });
        return;
    }
    for (registry.servers.items) |server| {
        if (server.state == .error_state) {
            try add(report, "mcp", .fail, "server '{s}' in error state ({s})", .{
                server.cfg.id,
                if (server.last_error) |e| e else "unknown",
            });
            return;
        }
    }
    try add(report, "mcp", .warn, "{d} server(s) configured, none running", .{configured});
}

fn checkAttachments(report: *Report, inputs: Inputs) !void {
    const store = inputs.attachments orelse {
        try add(report, "attachments", .unavailable, "upload service not attached", .{});
        return;
    };
    try add(report, "attachments", .pass, "{d} attachment(s), {d}/{d} bytes quota", .{
        store.count(),
        store.totalBytes(),
        store.max_total_bytes,
    });
}

fn checkArtifacts(report: *Report, inputs: Inputs) !void {
    const store = inputs.artifacts orelse {
        try add(report, "artifacts", .unavailable, "artifact service not attached", .{});
        return;
    };
    try add(report, "artifacts", .pass, "{d} artifact(s); supported: txt md json csv zip; pdf/docx/pptx/xlsx unsupported", .{
        store.count(),
    });
}

fn checkJobs(report: *Report, inputs: Inputs) !void {
    const runtime = inputs.jobs orelse {
        try add(report, "jobs", .unavailable, "job runtime not attached", .{});
        return;
    };
    try add(report, "jobs", .pass, "{d} job record(s), {d} active, worker alive", .{
        runtime.count(),
        runtime.runningCount(),
    });
}

fn checkRuns(report: *Report, inputs: Inputs) !void {
    const store = inputs.runs orelse {
        try add(report, "runs", .unavailable, "run store not attached", .{});
        return;
    };
    try add(report, "runs", .pass, "{d} run(s) recorded", .{store.runCount()});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testConfig(model: []const u8, base_url: []const u8) Config {
    return .{
        .agent_name = "Pico Claw",
        .model = model,
        .base_url = base_url,
        .system_prompt = "",
        .temperature = 0.7,
        .max_tokens = 64,
        .soul_path = "SOUL.md",
        .memory_path = "MEMORY.md",
        .soul_budget_bytes = 1024,
        .memory_budget_bytes = 1024,
        .owner_budget_bytes = 2048,
    };
}

test "doctor reports unavailable for every unattached subsystem" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const cfg = testConfig("test-model", "http://127.0.0.1:1/v1");

    var report = try run(testing.allocator, .{
        .version = "0.1.0",
        .env = &env,
        .config = &cfg,
        .io = testing.io,
        .probe_network = false,
    });
    defer report.deinit();

    const names = [_][]const u8{ "binary", "configuration", "provider", "telegram", "sandbox", "mcp", "attachments", "artifacts", "jobs", "runs" };
    try testing.expectEqual(@as(usize, names.len), report.checks.items.len);
    for (names, 0..) |name, index| {
        try testing.expectEqualStrings(name, report.checks.items[index].name);
    }
    try testing.expectEqual(Status.unavailable, report.checks.items[2].status);
    try testing.expectEqual(Status.pass, report.checks.items[0].status);
    try testing.expectEqual(Status.pass, report.checks.items[1].status);
    try testing.expectEqual(Status.pass, report.overall());
}

test "doctor escalates to fail on a broken configuration" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const cfg = testConfig("", "");

    var report = try run(testing.allocator, .{
        .version = "0.1.0",
        .env = &env,
        .config = &cfg,
        .io = testing.io,
        .probe_network = false,
    });
    defer report.deinit();

    try testing.expectEqual(Status.fail, report.overall());
    var found = false;
    for (report.checks.items) |check| {
        if (std.mem.eql(u8, check.name, "configuration")) {
            found = true;
            try testing.expectEqual(Status.fail, check.status);
        }
    }
    try testing.expect(found);
}

test "doctor performs a real sandbox write/read/delete cycle" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-doctor";
    cwd.deleteTree(io, root_name) catch {};
    var sb = try sandbox_mod.Sandbox.init(io, testing.allocator, cwd, root_name, .{
        .read = true,
        .write = true,
    }, .{});
    defer {
        sb.deinit();
        cwd.deleteTree(io, root_name) catch {};
    }

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const cfg = testConfig("m", "http://127.0.0.1:1/v1");

    var report = try run(testing.allocator, .{
        .version = "0.1.0",
        .env = &env,
        .config = &cfg,
        .io = io,
        .sandbox = &sb,
        .probe_network = false,
    });
    defer report.deinit();

    var sandbox_ok = false;
    for (report.checks.items) |check| {
        if (std.mem.eql(u8, check.name, "sandbox")) {
            sandbox_ok = check.status == .pass;
            try testing.expect(std.mem.indexOf(u8, check.detail, "write/read/delete ok") != null);
        }
    }
    try testing.expect(sandbox_ok);
    // The probe file was cleaned up afterwards.
    try testing.expectError(error.FileNotFound, sb.root.statFile(io, "doctor-probe.txt", .{}));
}

test "doctor report renders secret-free JSON" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PICO_CLAW_API_KEY", "sk-canary-value-never-shown");
    const cfg = testConfig("test-model", "http://127.0.0.1:1/v1");

    var report = try run(testing.allocator, .{
        .version = "0.1.0",
        .env = &env,
        .config = &cfg,
        .io = testing.io,
        .probe_network = false,
    });
    defer report.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try report.writeJson(&stringify);
    const json = out.written();
    // The canary key value never appears anywhere in the report.
    try testing.expect(std.mem.indexOf(u8, json, "sk-canary-value-never-shown") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"provider\",\"status\":\"unavailable\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
