//! Run and event model: the observability backbone for the run inspector.
//!
//! A run is one unit of work with a lifecycle (chat turn, job, doctor pass).
//! Events are appended as that work proceeds so the dashboard and the API can
//! answer "what did the runtime actually do, and what happened to it".
//!
//! Two rules are enforced here rather than trusted to callers:
//!
//! 1. Nothing carries a secret. Every detail string is scanned for known
//!    credential markers and is replaced wholesale with `[redacted]` when one
//!    appears, so a careless caller cannot leak a token into the log.
//! 2. Memory is bounded. Runs, events per run, and detail length all have hard
//!    ceilings; overflow is counted and reported instead of silently dropped.
//!
//! The store is shared by the single-threaded HTTP service and the job worker
//! thread, so every mutation and every read holds `mutex`.

const std = @import("std");

pub const max_runs: usize = 128;
pub const max_events_per_run: usize = 256;
pub const max_detail_len: usize = 200;
pub const max_label_len: usize = 64;

/// Marker substrings that must never be recorded. A detail containing any of
/// them is replaced entirely: partial redaction of free text is not reliable.
pub const forbidden_markers = [_][]const u8{
    "PICO_CLAW_API_KEY",
    "TELEGRAM_BOT_TOKEN",
    "PICO_MCP",
    "Bearer ",
    "token=",
    "api_key",
    "apikey",
    "secret",
    "password",
};

pub const EventKind = enum {
    context,
    planning,
    tool_start,
    tool_result,
    mcp_start,
    mcp_result,
    process_start,
    process_result,
    artifact,
    upload,
    extract,
    verification,
    job_start,
    job_result,
    doctor_check,
    error_event,
    recovery,

    pub fn name(self: EventKind) []const u8 {
        return switch (self) {
            .context => "context",
            .planning => "planning",
            .tool_start => "tool_start",
            .tool_result => "tool_result",
            .mcp_start => "mcp_start",
            .mcp_result => "mcp_result",
            .process_start => "process_start",
            .process_result => "process_result",
            .artifact => "artifact",
            .upload => "upload",
            .extract => "extract",
            .verification => "verification",
            .job_start => "job_start",
            .job_result => "job_result",
            .doctor_check => "doctor_check",
            .error_event => "error",
            .recovery => "recovery",
        };
    }
};

pub const RunState = enum {
    running,
    completed,
    failed,
    cancelled,
    timed_out,

    pub fn name(self: RunState) []const u8 {
        return @tagName(self);
    }

    pub fn terminal(self: RunState) bool {
        return self != .running;
    }
};

pub const Event = struct {
    at_ms: i64,
    kind: EventKind,
    detail: []u8,
};

pub const Run = struct {
    id: []u8,
    request_id: []u8,
    session_id: []u8,
    model: []u8,
    provider: []u8,
    profile: []u8,
    started_ms: i64,
    ended_ms: i64 = 0,
    state: RunState = .running,
    error_name: ?[]u8 = null,
    events: std.ArrayList(Event) = .empty,
    dropped_events: usize = 0,
};

/// What starts a run. Every field is a short label, never free-form payload.
pub const BeginOptions = struct {
    request_id: []const u8 = "",
    session_id: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    profile: []const u8 = "",
    state: RunState = .running,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runs: std.ArrayList(*Run) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Store) void {
        for (self.runs.items) |run| self.destroyRun(run);
        self.runs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Begin a run and keep ownership of it in the store (bounded FIFO of
    /// terminal runs; a run is only evicted once it is finished).
    pub fn begin(self: *Store, opts: BeginOptions) !*Run {
        var id_buf: [32]u8 = undefined;
        const id = try self.allocator.dupe(
            u8,
            std.fmt.bufPrint(&id_buf, "run-{d}", .{self.runs.items.len + 1}) catch "run",
        );
        errdefer self.allocator.free(id);
        const request_id = try self.allocator.dupe(u8, truncateLabel(opts.request_id));
        errdefer self.allocator.free(request_id);
        const session_id = try self.allocator.dupe(u8, truncateLabel(opts.session_id));
        errdefer self.allocator.free(session_id);
        const model = try self.allocator.dupe(u8, truncateLabel(opts.model));
        errdefer self.allocator.free(model);
        const provider = try self.allocator.dupe(u8, truncateLabel(opts.provider));
        errdefer self.allocator.free(provider);
        const profile = try self.allocator.dupe(u8, truncateLabel(opts.profile));
        errdefer self.allocator.free(profile);

        const run = try self.allocator.create(Run);
        errdefer self.allocator.destroy(run);
        run.* = .{
            .id = id,
            .request_id = request_id,
            .session_id = session_id,
            .model = model,
            .provider = provider,
            .profile = profile,
            .started_ms = wallClockMs(self.io),
            .state = opts.state,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.evictLocked();
        try self.runs.append(self.allocator, run);
        return run;
    }

    /// Append one event. The detail is redacted and bounded; when the per-run
    /// cap is hit the event is counted as dropped instead of stored.
    pub fn record(self: *Store, run: *Run, kind: EventKind, detail: []const u8) void {
        const sanitized = sanitizeDetail(self.allocator, detail) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (run.events.items.len >= max_events_per_run) {
            run.dropped_events += 1;
            self.allocator.free(sanitized);
            return;
        }
        run.events.append(self.allocator, .{
            .at_ms = wallClockMs(self.io),
            .kind = kind,
            .detail = sanitized,
        }) catch {
            self.allocator.free(sanitized);
        };
    }

    /// Close a run with its final state. Closing twice is a caller bug; the
    /// second call is ignored so the recorded history stays truthful.
    pub fn end(self: *Store, run: *Run, state: RunState, error_name: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (run.state.terminal()) return;
        run.state = state;
        run.ended_ms = wallClockMs(self.io);
        if (error_name) |name| {
            run.error_name = self.allocator.dupe(u8, truncateLabel(name)) catch null;
        }
    }

    pub fn runCount(self: *Store) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.runs.items.len;
    }

    pub fn find(self: *Store, id: []const u8) ?*Run {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.findLocked(id);
    }

    /// Serialize the inventory (summaries only, no event payloads) so the API
    /// answer stays bounded. Caller owns nothing; writes into `writer`.
    pub fn writeListJson(self: *Store, writer: *std.json.Stringify) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try writer.beginObject();
        try writer.objectField("count");
        try writer.write(self.runs.items.len);
        try writer.objectField("runs");
        try writer.beginArray();
        for (self.runs.items) |run| try writeSummaryJson(run, writer);
        try writer.endArray();
        try writer.endObject();
    }

    /// Serialize one run with its full event list; returns false when unknown.
    pub fn writeRunJson(self: *Store, id: []const u8, writer: *std.json.Stringify) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const run = self.findLocked(id) orelse return false;
        try writeRunJsonLocked(run, writer);
        return true;
    }

    fn findLocked(self: *Store, id: []const u8) ?*Run {
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.id, id)) return run;
        }
        return null;
    }

    /// Keep at most `max_runs`; only terminal runs may be evicted.
    fn evictLocked(self: *Store) void {
        while (self.runs.items.len >= max_runs) {
            var oldest: ?usize = null;
            for (self.runs.items, 0..) |run, index| {
                if (!run.state.terminal()) continue;
                oldest = index;
                break;
            }
            const index = oldest orelse return; // all still running: keep
            const run = self.runs.orderedRemove(index);
            self.destroyRun(run);
        }
    }

    fn destroyRun(self: *Store, run: *Run) void {
        for (run.events.items) |event| self.allocator.free(event.detail);
        run.events.deinit(self.allocator);
        if (run.error_name) |name| self.allocator.free(name);
        self.allocator.free(run.id);
        self.allocator.free(run.request_id);
        self.allocator.free(run.session_id);
        self.allocator.free(run.model);
        self.allocator.free(run.provider);
        self.allocator.free(run.profile);
        self.allocator.destroy(run);
    }
};

fn truncateLabel(label: []const u8) []const u8 {
    return if (label.len <= max_label_len) label else label[0..max_label_len];
}

/// Replace a detail that carries any credential marker with a fixed stub:
/// partial redaction of free text cannot be trusted, so the whole value goes.
pub fn sanitizeDetail(allocator: std.mem.Allocator, detail: []const u8) ![]u8 {
    const capped = if (detail.len > max_detail_len) detail[0..max_detail_len] else detail;
    for (forbidden_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(capped, marker) != null) {
            return allocator.dupe(u8, "[redacted]");
        }
    }
    return allocator.dupe(u8, capped);
}

fn writeSummaryJson(run: *Run, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(run.id);
    try writer.objectField("request_id");
    try writer.write(run.request_id);
    try writer.objectField("session_id");
    try writer.write(run.session_id);
    try writer.objectField("model");
    try writer.write(run.model);
    try writer.objectField("provider");
    try writer.write(run.provider);
    try writer.objectField("profile");
    try writer.write(run.profile);
    try writer.objectField("state");
    try writer.write(run.state.name());
    try writer.objectField("started_ms");
    try writer.write(run.started_ms);
    try writer.objectField("ended_ms");
    try writer.write(run.ended_ms);
    try writer.objectField("event_count");
    try writer.write(run.events.items.len);
    try writer.objectField("error");
    if (run.error_name) |name| try writer.write(name) else try writer.write(null);
    try writer.endObject();
}

fn writeRunJsonLocked(run: *Run, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(run.id);
    try writer.objectField("request_id");
    try writer.write(run.request_id);
    try writer.objectField("session_id");
    try writer.write(run.session_id);
    try writer.objectField("model");
    try writer.write(run.model);
    try writer.objectField("provider");
    try writer.write(run.provider);
    try writer.objectField("profile");
    try writer.write(run.profile);
    try writer.objectField("state");
    try writer.write(run.state.name());
    try writer.objectField("started_ms");
    try writer.write(run.started_ms);
    try writer.objectField("ended_ms");
    try writer.write(run.ended_ms);
    try writer.objectField("error");
    if (run.error_name) |name| try writer.write(name) else try writer.write(null);
    try writer.objectField("dropped_events");
    try writer.write(run.dropped_events);
    try writer.objectField("event_count");
    try writer.write(run.events.items.len);
    try writer.objectField("tools_invoked");
    try writer.write(countEvents(run, &.{.tool_result}));
    try writer.objectField("mcp_events");
    try writer.write(countEvents(run, &.{ .mcp_start, .mcp_result }));
    try writer.objectField("artifacts");
    try writer.write(countEvents(run, &.{.artifact}));
    try writer.objectField("events");
    try writer.beginArray();
    for (run.events.items) |event| {
        try writer.beginObject();
        try writer.objectField("at_ms");
        try writer.write(event.at_ms);
        try writer.objectField("kind");
        try writer.write(event.kind.name());
        try writer.objectField("detail");
        try writer.write(event.detail);
        try writer.endObject();
    }
    try writer.endArray();
    try writer.endObject();
}

fn countEvents(run: *Run, kinds: []const EventKind) usize {
    var count: usize = 0;
    for (run.events.items) |event| {
        for (kinds) |kind| {
            if (event.kind == kind) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

fn wallClockMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn render(store: *Store, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    _ = try store.writeRunJson(id, &stringify);
    return allocator.dupe(u8, out.written());
}

test "run lifecycle records events and closes with its final state" {
    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();

    const run = try store.begin(.{
        .request_id = "req-1",
        .session_id = "session-7",
        .model = "test-model",
        .provider = "unit-test",
        .profile = "default",
    });
    store.record(run, .tool_start, "filesystem.read docs/a.txt");
    store.record(run, .tool_result, "filesystem.read ok (13 bytes)");
    store.end(run, .completed, null);

    try testing.expectEqual(@as(usize, 1), store.runCount());
    const json = try render(&store, testing.allocator, "run-1");
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"state\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tools_invoked\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"tool_result\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "docs/a.txt") != null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try store.writeListJson(&stringify);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"event_count\":2") != null);
}

test "run details carrying credential markers are redacted wholesale" {
    const cases = [_][]const u8{
        "PICO_CLAW_API_KEY=super-secret-value",
        "sent with Bearer abc.def.ghi",
        "token=deadbeef",
        "config api_key field missing",
        "TELEGRAM_BOT_TOKEN=12345:AAAA",
    };
    for (cases) |case| {
        const sanitized = try sanitizeDetail(testing.allocator, case);
        defer testing.allocator.free(sanitized);
        try testing.expectEqualStrings("[redacted]", sanitized);
    }
    const clean = try sanitizeDetail(testing.allocator, "filesystem.write ok (24 bytes)");
    defer testing.allocator.free(clean);
    try testing.expectEqualStrings("filesystem.write ok (24 bytes)", clean);
}

test "run details are bounded and unknown run ids render as absent" {
    const long = "x" ** 500;
    const sanitized = try sanitizeDetail(testing.allocator, long);
    defer testing.allocator.free(sanitized);
    try testing.expectEqual(max_detail_len, sanitized.len);

    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try testing.expectEqual(false, try store.writeRunJson("run-999", &stringify));
}

test "event cap counts dropped events instead of growing without bound" {
    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();

    const run = try store.begin(.{});
    for (0..max_events_per_run + 10) |index| {
        var buf: [32]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "event {d}", .{index}) catch unreachable;
        store.record(run, .context, detail);
    }
    store.end(run, .completed, null);

    try testing.expectEqual(max_events_per_run, run.events.items.len);
    try testing.expectEqual(@as(usize, 10), run.dropped_events);
    try testing.expectEqualStrings("event 255", run.events.items[255].detail);
}

test "run store stays consistent while events arrive from another thread" {
    var store = Store.init(testing.allocator, testing.io);
    defer store.deinit();

    const run = try store.begin(.{ .model = "race" });

    const Worker = struct {
        fn loop(s: *Store, r: *Run) void {
            for (0..200) |index| {
                var buf: [32]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "worker event {d}", .{index}) catch return;
                s.record(r, .context, detail);
            }
            s.end(r, .completed, null);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.loop, .{ &store, run });

    // Render concurrently with the writer; every render must parse.
    for (0..20) |_| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        _ = try store.writeRunJson("run-1", &stringify);
    }
    thread.join();

    try testing.expectEqual(RunState.completed, run.state);
}
