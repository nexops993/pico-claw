const std = @import("std");
const builtin = @import("builtin");
const task = @import("task.zig");
const TaskRecord = task.TaskRecord;

/// Bounded, local task journal. Oldest records are evicted so the file and
/// memory stay small; a record is written once, when its task finishes.
pub const max_records: usize = 64;

pub const TaskStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    directory_path: []const u8,
    file_path: []const u8,
    records: std.ArrayList(TaskRecord) = .empty,
    next_id: u64 = 1,
    limit: usize = max_records,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TaskStore {
        return initAt(allocator, io, std.Io.Dir.cwd(), "data/tasks", "data/tasks/journal.jsonl");
    }

    pub fn initAt(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        directory_path: []const u8,
        file_path: []const u8,
    ) TaskStore {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .directory_path = directory_path,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *TaskStore) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
    }

    /// Start a new task record. Owned by the store for the rest of its life.
    pub fn begin(self: *TaskStore, key_hash: u64, started_at_ms: i64) !*TaskRecord {
        while (self.records.items.len >= self.limit) {
            var oldest = self.records.orderedRemove(0);
            oldest.deinit();
        }
        var record = TaskRecord.begin(self.allocator, key_hash, started_at_ms);
        record.id = self.next_id;
        self.next_id += 1;
        try self.records.append(self.allocator, record);
        return &self.records.items[self.records.items.len - 1];
    }

    /// Mark the completed work of the latest failed run for this key as
    /// replayed, so the executor and brain skip it instead of repeating its
    /// side effects. Returns the number of seeded entries. A completed run
    /// never makes a later identical task resumable.
    pub fn seedResume(self: *TaskStore, record: *TaskRecord) usize {
        const prior = self.latestFailed(record.key_hash) orelse return 0;
        if (prior == record) return 0;

        var seeded: usize = 0;
        for (prior.steps.items) |step| {
            if (!step.state.isDone()) continue;
            record.seedStep(step.step_id, step.tool_name) catch continue;
            seeded += 1;
        }
        for (prior.calls.items) |call| {
            if (!call.state.isDone()) continue;
            record.seedCall(call.tool_name, call.input_hash) catch continue;
            seeded += 1;
        }
        return seeded;
    }

    /// Latest failed record for a task key (resume source), if any.
    pub fn latestFailed(self: *const TaskStore, key_hash: u64) ?*TaskRecord {
        var index = self.records.items.len;
        while (index > 0) {
            index -= 1;
            const record = &self.records.items[index];
            if (record.key_hash != key_hash) continue;
            if (record.state == .failed) return record;
        }
        return null;
    }

    pub fn last(self: *const TaskStore) ?*const TaskRecord {
        if (self.records.items.len == 0) return null;
        return &self.records.items[self.records.items.len - 1];
    }

    pub fn count(self: *const TaskStore) usize {
        return self.records.items.len;
    }

    pub fn completedCount(self: *const TaskStore) usize {
        return self.countState(.completed);
    }

    pub fn failedCount(self: *const TaskStore) usize {
        return self.countState(.failed);
    }

    fn countState(self: *const TaskStore, state: task.TaskState) usize {
        var total: usize = 0;
        for (self.records.items) |record| {
            if (record.state == state) total += 1;
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Journal persistence (JSONL, one finished task per line)
    // -----------------------------------------------------------------------

    fn writeJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
        if (value) |text| {
            try writer.writeByte('"');
            for (text) |char| {
                switch (char) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(char),
                }
            }
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
    }

    fn writeRecord(writer: *std.Io.Writer, record: *const TaskRecord) !void {
        try writer.print(
            "{{\"id\":{d},\"key_hash\":{d},\"state\":\"{s}\",\"route\":\"{s}\",\"planned_steps\":{d},\"started_at_ms\":{d},\"ended_at_ms\":{d},\"error_kind\":",
            .{
                record.id,
                record.key_hash,
                record.state.name(),
                record.route.name(),
                record.planned_steps,
                record.started_at_ms,
                record.ended_at_ms,
            },
        );
        if (record.error_kind) |kind| {
            try writer.print("\"{s}\"", .{kind.name()});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"error_code\":");
        try writeJsonString(writer, record.error_code);

        try writer.writeAll(",\"steps\":[");
        for (record.steps.items, 0..) |step, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"step_id\":{d},\"tool_name\":", .{step.step_id});
            try writeJsonString(writer, step.tool_name);
            try writer.print(",\"state\":\"{s}\",\"duration_ms\":{d}}}", .{ step.state.name(), step.duration_ms });
        }

        try writer.writeAll("],\"calls\":[");
        for (record.calls.items, 0..) |call, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"tool_name\":", .{});
            try writeJsonString(writer, call.tool_name);
            try writer.print(",\"input_hash\":{d},\"state\":\"{s}\",\"duration_ms\":{d}}}", .{ call.input_hash, call.state.name(), call.duration_ms });
        }

        try writer.writeAll("],\"attempts\":[");
        for (record.attempts.items, 0..) |attempt, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"attempt\":{d},\"ok\":{},\"duration_ms\":{d},\"input_bytes\":{d},\"output_bytes\":{d},\"error_code\":",
                .{ attempt.attempt, attempt.ok, attempt.duration_ms, attempt.input_bytes, attempt.output_bytes },
            );
            try writeJsonString(writer, attempt.error_code);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"escalation\":");
        if (record.escalation) |escalation| {
            try writer.print(
                "{{\"escalated\":{},\"reason\":\"{s}\",\"model_label\":",
                .{ escalation.escalated, escalation.reason.name() },
            );
            try writeJsonString(writer, escalation.model_label);
            try writer.print(
                ",\"ok\":{},\"duration_ms\":{d},\"input_bytes\":{d},\"output_bytes\":{d},\"error_code\":",
                .{ escalation.ok, escalation.duration_ms, escalation.input_bytes, escalation.output_bytes },
            );
            try writeJsonString(writer, escalation.error_code);
            try writer.writeByte('}');
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }

    pub fn save(self: *const TaskStore) !void {
        try self.dir.createDirPath(self.io, self.directory_path);
        var atomic = try self.dir.createFileAtomic(self.io, self.file_path, .{ .replace = true });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        for (self.records.items, 0..) |*record, index| {
            if (index > 0) try writer.interface.writeByte('\n');
            try writeRecord(&writer.interface, record);
        }
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    // ---------------------------------------------------------------------------
    // Loading
    // ---------------------------------------------------------------------------

    const ParsedStep = struct {
        step_id: usize,
        tool_name: ?[]const u8 = null,
        state: []const u8,
        duration_ms: i64 = 0,
    };

    const ParsedCall = struct {
        tool_name: []const u8,
        input_hash: u64,
        state: []const u8,
        duration_ms: i64 = 0,
    };

    const ParsedAttempt = struct {
        attempt: u8,
        ok: bool,
        duration_ms: i64,
        input_bytes: usize = 0,
        output_bytes: usize = 0,
        error_code: ?[]const u8 = null,
    };

    /// Optional so journals written before teacher routing existed (without
    /// escalation records) keep loading unchanged.
    const ParsedEscalation = struct {
        escalated: bool,
        reason: []const u8,
        model_label: ?[]const u8 = null,
        ok: bool = false,
        duration_ms: i64 = 0,
        input_bytes: usize = 0,
        output_bytes: usize = 0,
        error_code: ?[]const u8 = null,
    };

    const ParsedRecord = struct {
        id: u64,
        key_hash: u64,
        state: []const u8,
        route: []const u8,
        planned_steps: usize = 0,
        started_at_ms: i64 = 0,
        ended_at_ms: i64 = 0,
        error_kind: ?[]const u8 = null,
        error_code: ?[]const u8 = null,
        steps: []const ParsedStep = &.{},
        calls: []const ParsedCall = &.{},
        attempts: []const ParsedAttempt = &.{},
        escalation: ?ParsedEscalation = null,
    };

    fn parseTaskState(value: []const u8) !task.TaskState {
        inline for (@typeInfo(task.TaskState).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidTaskState;
    }

    fn parseStepState(value: []const u8) !task.StepState {
        inline for (@typeInfo(task.StepState).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidStepState;
    }

    fn parseRoute(value: []const u8) !task.Route {
        inline for (@typeInfo(task.Route).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidRoute;
    }

    fn parseErrorKind(value: []const u8) !task.ErrorKind {
        inline for (@typeInfo(task.ErrorKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidErrorKind;
    }

    fn parseEscalationReason(value: []const u8) !task.EscalationReason {
        inline for (@typeInfo(task.EscalationReason).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidEscalationReason;
    }

    pub fn load(self: *TaskStore) !void {
        const file = self.dir.openFile(self.io, self.file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buffer);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        _ = try reader.interface.streamRemaining(&output.writer);
        for (self.records.items) |*record| record.deinit();
        self.records.clearRetainingCapacity();
        self.next_id = 1;
        var lines = std.mem.splitScalar(u8, output.written(), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            self.loadLine(line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => if (!builtin.is_test)
                    std.log.warn("[Tasks] Skipping corrupt journal line: {s}", .{@errorName(err)}),
            };
        }
    }

    fn loadLine(self: *TaskStore, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(ParsedRecord, self.allocator, line, .{});
        defer parsed.deinit();
        const value = parsed.value;

        var record = TaskRecord.begin(self.allocator, value.key_hash, value.started_at_ms);
        errdefer record.deinit();
        record.id = value.id;
        record.state = try parseTaskState(value.state);
        record.route = try parseRoute(value.route);
        record.planned_steps = value.planned_steps;
        record.ended_at_ms = value.ended_at_ms;
        if (value.error_kind) |kind| record.error_kind = try parseErrorKind(kind);
        if (value.error_code) |code| record.error_code = try self.allocator.dupe(u8, code);

        for (value.steps) |step| {
            try record.restoreStep(step.step_id, step.tool_name, try parseStepState(step.state), step.duration_ms);
        }
        for (value.calls) |call| {
            try record.restoreCall(call.tool_name, call.input_hash, try parseStepState(call.state), call.duration_ms);
        }
        for (value.attempts) |attempt| {
            try record.restoreAttempt(
                attempt.attempt,
                attempt.ok,
                attempt.duration_ms,
                attempt.input_bytes,
                attempt.output_bytes,
                attempt.error_code,
            );
        }
        if (value.escalation) |escalation| {
            try record.restoreEscalation(
                escalation.escalated,
                try parseEscalationReason(escalation.reason),
                escalation.model_label,
                escalation.ok,
                escalation.duration_ms,
                escalation.input_bytes,
                escalation.output_bytes,
                escalation.error_code,
            );
        }

        try self.records.append(self.allocator, record);
        if (value.id >= self.next_id) self.next_id = value.id + 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "task store persists and reloads journal records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var source = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer source.deinit();

    const record = try source.begin(task.keyHash("build the report"), 1000);
    try record.start();
    record.setRoute(.calculator);
    record.setPlannedSteps(1);
    record.noteStep(1, "calculator", .running, 0);
    record.noteStep(1, "calculator", .completed, 4);
    record.noteCall("filesystem", 7, .failed, 9);
    record.noteAttempt(1, false, 10, 100, 0, error.ApiRequestFailed);
    try record.finish(error.ApiRequestFailed, 1050);
    try source.save();

    var loaded = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer loaded.deinit();
    try loaded.load();

    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expectEqual(@as(usize, 0), loaded.completedCount());
    try std.testing.expectEqual(@as(usize, 1), loaded.failedCount());

    const restored = loaded.last().?;
    try std.testing.expectEqual(@as(u64, 1), restored.id);
    try std.testing.expectEqual(task.keyHash("build the report"), restored.key_hash);
    try std.testing.expectEqual(task.TaskState.failed, restored.state);
    try std.testing.expectEqual(task.Route.calculator, restored.route);
    try std.testing.expectEqual(@as(usize, 1), restored.planned_steps);
    try std.testing.expectEqual(@as(i64, 1000), restored.started_at_ms);
    try std.testing.expectEqual(@as(i64, 1050), restored.ended_at_ms);
    try std.testing.expectEqual(@as(i64, 50), restored.latencyMs());
    try std.testing.expectEqual(task.ErrorKind.provider, restored.error_kind.?);
    try std.testing.expectEqualStrings("ApiRequestFailed", restored.error_code.?);
    try std.testing.expectEqual(@as(usize, 1), restored.completedStepCount());
    try std.testing.expectEqual(@as(usize, 1), restored.toolCallCount());
    try std.testing.expectEqual(@as(usize, 1), restored.attemptCount());
    try std.testing.expectEqual(@as(usize, 100), restored.providerInputBytes());

    // Ids continue after a reload instead of restarting from 1.
    const next = try loaded.begin(7, 2000);
    try std.testing.expectEqual(@as(u64, 2), next.id);
}

test "resume comes from the latest failed run and never from a completed one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const key = task.keyHash("same task");

    var store = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer store.deinit();

    const first = try store.begin(key, 0);
    try first.start();
    first.noteStep(1, "calculator", .running, 0);
    first.noteStep(1, "calculator", .completed, 1);
    first.noteCall("filesystem", 7, .completed, 2);
    try first.finish(error.ProviderFailed, 10);

    const completed_run = try store.begin(key, 20);
    try completed_run.start();
    try completed_run.finish(null, 30);

    // The completed run must not hide the failed run's checkpoint, and the
    // latest failed run is the resume source.
    const resumed = try store.begin(key, 40);
    try std.testing.expectEqual(@as(usize, 2), store.seedResume(resumed));
    try std.testing.expect(resumed.wasStepCompleted(1, "calculator"));
    try std.testing.expect(resumed.wasCallCompleted("filesystem", 7));

    // A newer failed run replaces the resume source.
    const newer = try store.begin(key, 50);
    try newer.start();
    newer.noteStep(5, "calculator", .running, 0);
    newer.noteStep(5, "calculator", .completed, 1);
    try newer.finish(error.ApiRequestFailed, 60);

    const again = try store.begin(key, 70);
    try std.testing.expectEqual(@as(usize, 1), store.seedResume(again));
    try std.testing.expect(again.wasStepCompleted(5, "calculator"));
    try std.testing.expect(!again.wasCallCompleted("filesystem", 7));

    // Unknown keys have nothing to resume.
    const other = try store.begin(task.keyHash("different task"), 80);
    try std.testing.expectEqual(@as(usize, 0), store.seedResume(other));
}

test "task store evicts oldest records to stay bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var store = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer store.deinit();
    store.limit = 3;

    for (0..5) |_| {
        const record = try store.begin(0, 0);
        try record.start();
        try record.finish(null, 1);
    }

    try std.testing.expectEqual(@as(usize, 3), store.count());
    try std.testing.expectEqual(@as(u64, 3), store.records.items[0].id);
    try std.testing.expectEqual(@as(u64, 5), store.records.items[2].id);
}

test "journal round-trips escalation records and stays backward compatible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var source = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer source.deinit();

    const escalated = try source.begin(1, 0);
    try escalated.start();
    escalated.noteEscalation("teacher-model", true, 120, 900, 300, null);
    try escalated.finish(null, 130);

    const skipped = try source.begin(2, 200);
    try skipped.start();
    skipped.noteEscalationSkipped(.local_only);
    try skipped.finish(error.ProviderFailed, 260);
    try source.save();

    var loaded = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer loaded.deinit();
    try loaded.load();

    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    const first = &loaded.records.items[0];
    try std.testing.expect(first.escalation.?.escalated);
    try std.testing.expectEqual(task.EscalationReason.provider_failure, first.escalation.?.reason);
    try std.testing.expectEqualStrings("teacher-model", first.escalation.?.model_label.?);
    try std.testing.expect(first.escalation.?.ok);
    try std.testing.expectEqual(@as(i64, 120), first.escalation.?.duration_ms);
    try std.testing.expectEqual(@as(usize, 900), first.escalation.?.input_bytes);
    const second = &loaded.records.items[1];
    try std.testing.expect(!second.escalation.?.escalated);
    try std.testing.expectEqual(task.EscalationReason.local_only, second.escalation.?.reason);

    // A journal line written before teacher routing (without an escalation
    // field) still loads: the schema addition is backward compatible.
    const legacy_line =
        \\{"id":7,"key_hash":99,"state":"completed","route":"reasoning","planned_steps":1,"started_at_ms":10,"ended_at_ms":20,"error_kind":null,"error_code":null,"steps":[],"calls":[],"attempts":[]}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "tasks/journal.jsonl", .data = legacy_line });

    var legacy = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer legacy.deinit();
    try legacy.load();
    try std.testing.expectEqual(@as(usize, 1), legacy.count());
    try std.testing.expectEqual(@as(u64, 7), legacy.records.items[0].id);
    try std.testing.expect(legacy.records.items[0].escalation == null);
}

test "corrupt journal lines are skipped without failing the load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var source = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer source.deinit();
    const record = try source.begin(11, 0);
    try record.start();
    try record.finish(null, 5);
    try source.save();

    // Prepend a garbage line in front of the valid record line; the valid
    // line must still load.
    const contents = try tmp.dir.readFileAlloc(io, "tasks/journal.jsonl", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    const combined = try std.fmt.allocPrint(std.testing.allocator, "this is not json\n{s}", .{contents});
    defer std.testing.allocator.free(combined);
    try tmp.dir.writeFile(io, .{ .sub_path = "tasks/journal.jsonl", .data = combined });

    var loaded = TaskStore.initAt(std.testing.allocator, io, tmp.dir, "tasks", "tasks/journal.jsonl");
    defer loaded.deinit();
    try loaded.load();
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expectEqual(@as(u64, 11), loaded.last().?.key_hash);
}
