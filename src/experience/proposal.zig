const std = @import("std");
const builtin = @import("builtin");
const task = @import("../core/task.zig");

// ---------------------------------------------------------------------------
// Proposal types
// ---------------------------------------------------------------------------

/// What kind of change the proposal suggests. Skill proposals are not
/// generated yet: promoting a skill requires the M5 skill validator, and
/// inventing one without it would be an unvalidated claim.
pub const ProposalKind = enum {
    /// A lesson produced by the M1 reflection/learning pipeline, offered for
    /// manual promotion into the knowledge store after validation.
    lesson,
    /// An evidence-based review suggestion derived from the M2 task record
    /// (configuration or investigation follow-up).
    task_review,

    pub fn name(self: ProposalKind) []const u8 {
        return switch (self) {
            .lesson => "lesson",
            .task_review => "task_review",
        };
    }
};

pub const ProposalStatus = enum {
    proposed,
    accepted,
    rejected,

    pub fn name(self: ProposalStatus) []const u8 {
        return switch (self) {
            .proposed => "proposed",
            .accepted => "accepted",
            .rejected => "rejected",
        };
    }

    fn isTerminal(self: ProposalStatus) bool {
        return self != .proposed;
    }
};

/// Measured facts the proposal was derived from. Metadata and stable
/// identifiers only: no task text, tool content, prompt, or credential.
pub const Evidence = struct {
    task_id: u64 = 0,
    key_hash: u64 = 0,
    route: task.Route = .reasoning,
    task_state: task.TaskState = .pending,
    error_kind: ?task.ErrorKind = null,
    error_code: ?[]const u8 = null,
    attempts: usize = 0,
    escalations: usize = 0,
    latency_ms: i64 = 0,
    provider_input_bytes: usize = 0,
    provider_output_bytes: usize = 0,
};

pub const ProposalRecord = struct {
    allocator: std.mem.Allocator,
    id: u64,
    kind: ProposalKind,
    status: ProposalStatus,
    problem: []u8,
    suggestion: []u8,
    confidence: f64,
    confidence_basis: []u8,
    constraints: []u8,
    evidence: Evidence,
    created_at_ms: i64,
    decided_at_ms: i64 = 0,

    pub fn deinit(self: *ProposalRecord) void {
        self.allocator.free(self.problem);
        self.allocator.free(self.suggestion);
        self.allocator.free(self.confidence_basis);
        self.allocator.free(self.constraints);
        if (self.evidence.error_code) |code| self.allocator.free(code);
    }
};

/// A freshly drafted proposal handed to the store. `problem`, `suggestion`,
/// and `confidence_basis` are owned by the draft; `constraints` and
/// `evidence.error_code` are borrowed and must outlive the `add` call.
pub const ProposalDraft = struct {
    allocator: std.mem.Allocator,
    kind: ProposalKind,
    problem: []u8,
    suggestion: []u8,
    confidence: f64,
    confidence_basis: []u8,
    constraints: []const u8,
    evidence: Evidence,
    created_at_ms: i64,

    pub fn deinit(self: *ProposalDraft) void {
        self.allocator.free(self.problem);
        self.allocator.free(self.suggestion);
        self.allocator.free(self.confidence_basis);
    }
};

/// Constraint text attached to every proposal: a proposal is never an
/// automatic change.
pub const default_constraints =
    "proposal only; requires human validation and manual application; no automatic change is performed";

pub fn clampConfidence(value: f64) f64 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Store (bounded JSONL, one proposal per line)
// ---------------------------------------------------------------------------

pub const max_proposals: usize = 64;

pub const ProposalStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    directory_path: []const u8,
    file_path: []const u8,
    records: std.ArrayList(ProposalRecord) = .empty,
    next_id: u64 = 1,
    limit: usize = max_proposals,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ProposalStore {
        return initAt(allocator, io, std.Io.Dir.cwd(), "data/proposals", "data/proposals/proposals.jsonl");
    }

    pub fn initAt(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        directory_path: []const u8,
        file_path: []const u8,
    ) ProposalStore {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .directory_path = directory_path,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *ProposalStore) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
    }

    /// Add a proposal from a draft. The store duplicates the draft strings;
    /// the caller keeps ownership of the draft itself.
    pub fn add(self: *ProposalStore, draft: *const ProposalDraft) !*ProposalRecord {
        while (self.records.items.len >= self.limit) {
            var oldest = self.records.orderedRemove(0);
            oldest.deinit();
        }

        var record = ProposalRecord{
            .allocator = self.allocator,
            .id = self.next_id,
            .kind = draft.kind,
            .status = .proposed,
            .problem = try self.allocator.dupe(u8, draft.problem),
            .suggestion = try self.allocator.dupe(u8, draft.suggestion),
            .confidence = clampConfidence(draft.confidence),
            .confidence_basis = try self.allocator.dupe(u8, draft.confidence_basis),
            .constraints = try self.allocator.dupe(u8, draft.constraints),
            .evidence = .{
                .task_id = draft.evidence.task_id,
                .key_hash = draft.evidence.key_hash,
                .route = draft.evidence.route,
                .task_state = draft.evidence.task_state,
                .error_kind = draft.evidence.error_kind,
                .attempts = draft.evidence.attempts,
                .escalations = draft.evidence.escalations,
                .latency_ms = draft.evidence.latency_ms,
                .provider_input_bytes = draft.evidence.provider_input_bytes,
                .provider_output_bytes = draft.evidence.provider_output_bytes,
            },
            .created_at_ms = draft.created_at_ms,
        };
        errdefer record.deinit();
        if (draft.evidence.error_code) |code| {
            record.evidence.error_code = try self.allocator.dupe(u8, code);
        }

        self.next_id += 1;
        try self.records.append(self.allocator, record);
        return &self.records.items[self.records.items.len - 1];
    }

    pub fn find(self: *ProposalStore, id: u64) ?*ProposalRecord {
        for (self.records.items) |*record| {
            if (record.id == id) return record;
        }
        return null;
    }

    /// Accept or reject a proposal. Only a `proposed` record can be decided:
    /// a decision is terminal, so validation cannot be silently reversed, and
    /// accepting never applies anything — it only records the decision.
    pub fn decide(self: *ProposalStore, id: u64, status: ProposalStatus, decided_at_ms: i64) !void {
        if (status.isTerminal() == false) return error.InvalidStatus;
        const record = self.find(id) orelse return error.ProposalNotFound;
        if (record.status != .proposed) return error.AlreadyDecided;
        record.status = status;
        record.decided_at_ms = decided_at_ms;
    }

    pub fn count(self: *const ProposalStore) usize {
        return self.records.items.len;
    }

    pub fn countStatus(self: *const ProposalStore, status: ProposalStatus) usize {
        var total: usize = 0;
        for (self.records.items) |record| {
            if (record.status == status) total += 1;
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Persistence (JSONL)
    // -----------------------------------------------------------------------

    pub fn save(self: *const ProposalStore) !void {
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

    fn writeRecord(writer: *std.Io.Writer, record: *const ProposalRecord) !void {
        try writer.print(
            "{{\"id\":{d},\"kind\":\"{s}\",\"status\":\"{s}\",\"problem\":",
            .{ record.id, record.kind.name(), record.status.name() },
        );
        try writeJsonString(writer, record.problem);
        try writer.writeAll(",\"suggestion\":");
        try writeJsonString(writer, record.suggestion);
        try writer.print(",\"confidence\":{d},\"confidence_basis\":", .{record.confidence});
        try writeJsonString(writer, record.confidence_basis);
        try writer.writeAll(",\"constraints\":");
        try writeJsonString(writer, record.constraints);
        try writer.print(
            ",\"evidence\":{{\"task_id\":{d},\"key_hash\":{d},\"route\":\"{s}\",\"task_state\":\"{s}\",\"error_kind\":",
            .{
                record.evidence.task_id,
                record.evidence.key_hash,
                record.evidence.route.name(),
                record.evidence.task_state.name(),
            },
        );
        if (record.evidence.error_kind) |kind| {
            try writer.print("\"{s}\"", .{kind.name()});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"error_code\":");
        try writeJsonString(writer, record.evidence.error_code);
        try writer.print(
            ",\"attempts\":{d},\"escalations\":{d},\"latency_ms\":{d},\"provider_input_bytes\":{d},\"provider_output_bytes\":{d}}}",
            .{
                record.evidence.attempts,
                record.evidence.escalations,
                record.evidence.latency_ms,
                record.evidence.provider_input_bytes,
                record.evidence.provider_output_bytes,
            },
        );
        try writer.print(",\"created_at_ms\":{d},\"decided_at_ms\":{d}}}", .{ record.created_at_ms, record.decided_at_ms });
    }

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

    // -----------------------------------------------------------------------
    // Loading
    // -----------------------------------------------------------------------

    const ParsedEvidence = struct {
        task_id: u64 = 0,
        key_hash: u64 = 0,
        route: []const u8 = "reasoning",
        task_state: []const u8 = "pending",
        error_kind: ?[]const u8 = null,
        error_code: ?[]const u8 = null,
        attempts: usize = 0,
        escalations: usize = 0,
        latency_ms: i64 = 0,
        provider_input_bytes: usize = 0,
        provider_output_bytes: usize = 0,
    };

    const ParsedRecord = struct {
        id: u64,
        kind: []const u8,
        status: []const u8,
        problem: []const u8,
        suggestion: []const u8,
        confidence: f64,
        confidence_basis: []const u8,
        constraints: []const u8 = default_constraints,
        evidence: ParsedEvidence = .{},
        created_at_ms: i64 = 0,
        decided_at_ms: i64 = 0,
    };

    fn parseEnum(comptime E: type, value: []const u8, invalid: anyerror) !E {
        inline for (@typeInfo(E).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return invalid;
    }

    pub fn load(self: *ProposalStore) !void {
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
                    std.log.warn("[Proposals] Skipping corrupt line: {s}", .{@errorName(err)}),
            };
        }
    }

    fn loadLine(self: *ProposalStore, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(ParsedRecord, self.allocator, line, .{});
        defer parsed.deinit();
        const value = parsed.value;
        const evidence = value.evidence;

        var record = ProposalRecord{
            .allocator = self.allocator,
            .id = value.id,
            .kind = try parseEnum(ProposalKind, value.kind, error.InvalidProposalKind),
            .status = try parseEnum(ProposalStatus, value.status, error.InvalidProposalStatus),
            .problem = try self.allocator.dupe(u8, value.problem),
            .suggestion = try self.allocator.dupe(u8, value.suggestion),
            .confidence = clampConfidence(value.confidence),
            .confidence_basis = try self.allocator.dupe(u8, value.confidence_basis),
            .constraints = try self.allocator.dupe(u8, value.constraints),
            .evidence = .{
                .task_id = evidence.task_id,
                .key_hash = evidence.key_hash,
                .route = try parseEnum(task.Route, evidence.route, error.InvalidRoute),
                .task_state = try parseEnum(task.TaskState, evidence.task_state, error.InvalidTaskState),
                .error_kind = if (evidence.error_kind) |kind_value|
                    try parseEnum(task.ErrorKind, kind_value, error.InvalidErrorKind)
                else
                    null,
                .attempts = evidence.attempts,
                .escalations = evidence.escalations,
                .latency_ms = evidence.latency_ms,
                .provider_input_bytes = evidence.provider_input_bytes,
                .provider_output_bytes = evidence.provider_output_bytes,
            },
            .created_at_ms = value.created_at_ms,
            .decided_at_ms = value.decided_at_ms,
        };
        errdefer record.deinit();
        if (evidence.error_code) |code| record.evidence.error_code = try self.allocator.dupe(u8, code);

        try self.records.append(self.allocator, record);
        if (value.id >= self.next_id) self.next_id = value.id + 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testDraft(allocator: std.mem.Allocator) !ProposalDraft {
    return .{
        .allocator = allocator,
        .kind = .task_review,
        .problem = try std.fmt.allocPrint(allocator, "provider error provider/ApiRequestFailed after 2 attempts", .{}),
        .suggestion = try std.fmt.allocPrint(allocator, "consider raising settings.task_max_attempts", .{}),
        .confidence = 0.5,
        .confidence_basis = try std.fmt.allocPrint(allocator, "single observed run", .{}),
        .constraints = default_constraints,
        .evidence = .{
            .task_id = 3,
            .key_hash = 77,
            .route = .calculator,
            .task_state = .failed,
            .error_kind = .provider,
            .attempts = 2,
            .latency_ms = 40,
        },
        .created_at_ms = 500,
    };
}

test "proposal store adds validates and bounds records with monotonic ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var store = ProposalStore.initAt(std.testing.allocator, io, tmp.dir, "proposals", "proposals/proposals.jsonl");
    defer store.deinit();
    store.limit = 3;

    for (0..5) |_| {
        var draft = try testDraft(std.testing.allocator);
        defer draft.deinit();
        const record = try store.add(&draft);
        try std.testing.expectEqual(@as(f64, 0.5), record.confidence);
        try std.testing.expectEqualStrings(default_constraints, record.constraints);
    }

    try std.testing.expectEqual(@as(usize, 3), store.count());
    try std.testing.expectEqual(@as(u64, 3), store.records.items[0].id);
    try std.testing.expectEqual(@as(u64, 5), store.records.items[2].id);
}

test "proposal decisions are terminal and validated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var store = ProposalStore.initAt(std.testing.allocator, io, tmp.dir, "proposals", "proposals/proposals.jsonl");
    defer store.deinit();

    var draft = try testDraft(std.testing.allocator);
    defer draft.deinit();
    const record = try store.add(&draft);
    try std.testing.expectEqual(ProposalStatus.proposed, record.status);

    // Accepting records the decision only; nothing is applied.
    try store.decide(record.id, .accepted, 900);
    try std.testing.expectEqual(ProposalStatus.accepted, store.find(record.id).?.status);
    try std.testing.expectEqual(@as(i64, 900), store.find(record.id).?.decided_at_ms);
    try std.testing.expectEqual(@as(usize, 1), store.countStatus(.accepted));

    // A decided proposal cannot be decided again or flipped.
    try std.testing.expectError(error.AlreadyDecided, store.decide(record.id, .rejected, 950));
    try std.testing.expectEqual(ProposalStatus.accepted, store.find(record.id).?.status);

    // Unknown ids and non-terminal targets are rejected.
    try std.testing.expectError(error.ProposalNotFound, store.decide(999, .accepted, 1));
    try std.testing.expectError(error.InvalidStatus, store.decide(record.id, .proposed, 1));
}

test "proposal store persists reloads and skips corrupt lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var source = ProposalStore.initAt(std.testing.allocator, io, tmp.dir, "proposals", "proposals/proposals.jsonl");
    defer source.deinit();

    var draft = try testDraft(std.testing.allocator);
    defer draft.deinit();
    draft.evidence.error_code = "ApiRequestFailed";
    const first = try source.add(&draft);
    try source.decide(first.id, .rejected, 700);

    var second_draft = try testDraft(std.testing.allocator);
    defer second_draft.deinit();
    _ = try source.add(&second_draft);
    try source.save();

    var loaded = ProposalStore.initAt(std.testing.allocator, io, tmp.dir, "proposals", "proposals/proposals.jsonl");
    defer loaded.deinit();
    try loaded.load();

    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    const restored = loaded.find(1).?;
    try std.testing.expectEqualStrings("ApiRequestFailed", restored.evidence.error_code.?);
    try std.testing.expectEqual(task.Route.calculator, restored.evidence.route);
    try std.testing.expectEqual(task.TaskState.failed, restored.evidence.task_state);
    try std.testing.expectEqual(task.ErrorKind.provider, restored.evidence.error_kind.?);
    try std.testing.expectEqual(@as(usize, 2), restored.evidence.attempts);
    try std.testing.expectEqual(ProposalStatus.rejected, restored.status);
    try std.testing.expectEqual(@as(usize, 1), loaded.countStatus(.proposed));
    // Ids continue after reload.
    var third = try testDraft(std.testing.allocator);
    defer third.deinit();
    const next = try loaded.add(&third);
    try std.testing.expectEqual(@as(u64, 3), next.id);

    // Corrupt and schema-invalid lines are skipped, valid ones survive.
    const contents = try tmp.dir.readFileAlloc(io, "proposals/proposals.jsonl", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(contents);
    const combined = try std.fmt.allocPrint(
        std.testing.allocator,
        "not json\n{s}\n{{\"id\":9,\"kind\":\"nonsense\",\"status\":\"proposed\",\"problem\":\"p\",\"suggestion\":\"s\",\"confidence\":0.5,\"confidence_basis\":\"b\"}}",
        .{contents},
    );
    defer std.testing.allocator.free(combined);
    try tmp.dir.writeFile(io, .{ .sub_path = "proposals/proposals.jsonl", .data = combined });

    var recovered = ProposalStore.initAt(std.testing.allocator, io, tmp.dir, "proposals", "proposals/proposals.jsonl");
    defer recovered.deinit();
    try recovered.load();
    try std.testing.expectEqual(@as(usize, 2), recovered.count());
}

test "proposal confidence is clamped on load and invalid values never exceed one" {
    const values = [_]f64{ -1, 0, 0.25, 1, 2, std.math.nan(f64), std.math.inf(f64) };
    for (values) |value| {
        const clamped = clampConfidence(value);
        try std.testing.expect(clamped >= 0);
        try std.testing.expect(clamped <= 1);
    }
    try std.testing.expectEqual(@as(f64, 0), clampConfidence(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0), clampConfidence(std.math.inf(f64)));
}
