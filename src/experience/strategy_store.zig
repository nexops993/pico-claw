const std = @import("std");
const builtin = @import("builtin");
const LearningEntry = @import("learning.zig").LearningEntry;

pub const StrategyRecord = struct {
    strategy: []u8,
    uses: u64,
    successes: u64,
    failures: u64,
    average_score: f64,
    confidence: f64,
    last_score: f64,
    last_action: []u8,
};

pub const StrategyStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    directory_path: []const u8,
    file_path: []const u8,
    records: std.ArrayList(StrategyRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) StrategyStore {
        return initAt(allocator, io, std.Io.Dir.cwd(), "data/learning", "data/learning/strategies.jsonl");
    }

    pub fn initAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, directory_path: []const u8, file_path: []const u8) StrategyStore {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .directory_path = directory_path,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *StrategyStore) void {
        self.clear();
        self.records.deinit(self.allocator);
    }

    pub fn update(self: *StrategyStore, learning: *const LearningEntry) !void {
        if (learning.strategy.len == 0 or
            !validUnitValue(learning.score) or
            !validUnitValue(learning.confidence)) return error.InvalidLearningEntry;

        if (self.findMutable(learning.strategy)) |record| {
            if (record.uses == std.math.maxInt(u64)) return error.StrategyCounterOverflow;
            const action = try self.allocator.dupe(u8, learning.action.name());
            const old_uses: f64 = @floatFromInt(record.uses);
            record.uses += 1;
            record.average_score = (record.average_score * old_uses + learning.score) /
                @as(f64, @floatFromInt(record.uses));
            applyOutcome(record, learning.score);
            record.confidence = learning.confidence;
            record.last_score = learning.score;
            self.allocator.free(record.last_action);
            record.last_action = action;
            return;
        }

        const strategy = try self.allocator.dupe(u8, learning.strategy);
        errdefer self.allocator.free(strategy);
        const action = try self.allocator.dupe(u8, learning.action.name());
        errdefer self.allocator.free(action);
        var record = StrategyRecord{
            .strategy = strategy,
            .uses = 1,
            .successes = 0,
            .failures = 0,
            .average_score = learning.score,
            .confidence = learning.confidence,
            .last_score = learning.score,
            .last_action = action,
        };
        applyOutcome(&record, learning.score);
        try self.records.append(self.allocator, record);
    }

    pub fn find(self: *const StrategyStore, strategy: []const u8) ?*const StrategyRecord {
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.strategy, strategy)) return record;
        }
        return null;
    }

    pub fn count(self: *const StrategyStore) usize {
        return self.records.items.len;
    }

    pub fn getAll(self: *const StrategyStore) []const StrategyRecord {
        return self.records.items;
    }

    pub fn select(self: *const StrategyStore) ?*const StrategyRecord {
        var best: ?*const StrategyRecord = null;
        var best_score: f64 = -1;
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.last_action, "reconsider_strategy")) continue;
            const score = record.average_score * 0.7 + record.confidence * 0.2 + record.last_score * 0.1;
            if (score > best_score or (score == best_score and (best == null or std.mem.lessThan(u8, record.strategy, best.?.strategy)))) {
                best = record;
                best_score = score;
            }
        }
        return best;
    }

    pub fn clear(self: *StrategyStore) void {
        for (self.records.items) |record| self.freeRecord(record);
        self.records.clearRetainingCapacity();
    }

    pub fn save(self: *StrategyStore) !void {
        try self.dir.createDirPath(self.io, self.directory_path);
        var atomic_file = try self.dir.createFileAtomic(self.io, self.file_path, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic_file.file.writer(self.io, &buffer);
        for (self.records.items, 0..) |record, index| {
            if (index > 0) try writer.interface.writeByte('\n');
            var stringify: std.json.Stringify = .{ .writer = &writer.interface };
            try stringify.write(.{
                .strategy = record.strategy,
                .uses = record.uses,
                .successes = record.successes,
                .failures = record.failures,
                .average_score = record.average_score,
                .confidence = record.confidence,
                .last_score = record.last_score,
                .last_action = record.last_action,
            });
        }
        try writer.interface.flush();
        try atomic_file.replace(self.io);
    }

    pub fn load(self: *StrategyStore) !void {
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

        self.clear();
        var lines = std.mem.splitScalar(u8, output.written(), '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            self.loadLine(line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => if (!builtin.is_test)
                    std.log.warn("[StrategyStore] Skipping corrupt line: {s}", .{@errorName(err)}),
            };
        }
    }

    fn loadLine(self: *StrategyStore, line: []const u8) !void {
        const StoredRecord = struct {
            strategy: []const u8,
            uses: u64,
            successes: u64,
            failures: u64,
            average_score: f64,
            confidence: f64,
            last_score: f64,
            last_action: []const u8,
        };
        const parsed = try std.json.parseFromSlice(StoredRecord, self.allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value.strategy.len == 0 or
            parsed.value.uses == 0 or
            parsed.value.successes > parsed.value.uses or
            parsed.value.failures != parsed.value.uses - parsed.value.successes or
            !validUnitValue(parsed.value.average_score) or
            !validUnitValue(parsed.value.confidence) or
            !validUnitValue(parsed.value.last_score) or
            !validAction(parsed.value.last_action) or
            self.find(parsed.value.strategy) != null) return error.InvalidStrategyRecord;

        const strategy = try self.allocator.dupe(u8, parsed.value.strategy);
        errdefer self.allocator.free(strategy);
        const action = try self.allocator.dupe(u8, parsed.value.last_action);
        errdefer self.allocator.free(action);
        try self.records.append(self.allocator, .{
            .strategy = strategy,
            .uses = parsed.value.uses,
            .successes = parsed.value.successes,
            .failures = parsed.value.failures,
            .average_score = parsed.value.average_score,
            .confidence = parsed.value.confidence,
            .last_score = parsed.value.last_score,
            .last_action = action,
        });
    }

    fn findMutable(self: *StrategyStore, strategy: []const u8) ?*StrategyRecord {
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.strategy, strategy)) return record;
        }
        return null;
    }

    fn freeRecord(self: *StrategyStore, record: StrategyRecord) void {
        self.allocator.free(record.strategy);
        self.allocator.free(record.last_action);
    }
};

fn applyOutcome(record: *StrategyRecord, score: f64) void {
    if (score >= 0.7) record.successes += 1 else record.failures += 1;
}

fn validUnitValue(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn validAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "keep_strategy") or
        std.mem.eql(u8, action, "observe_strategy") or
        std.mem.eql(u8, action, "reconsider_strategy");
}

fn fakeLearning(allocator: std.mem.Allocator, strategy: []const u8, score: f64, confidence: f64) !LearningEntry {
    const owned_strategy = try allocator.dupe(u8, strategy);
    errdefer allocator.free(owned_strategy);
    return .{
        .allocator = allocator,
        .entry_id = 1,
        .strategy = owned_strategy,
        .score = score,
        .lesson = try allocator.dupe(u8, "test lesson"),
        .action = if (score >= 0.7) .keep_strategy else .reconsider_strategy,
        .confidence = confidence,
    };
}

test "StrategyStore aggregates repeated learning" {
    var store = StrategyStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var first = try fakeLearning(std.testing.allocator, "context", 0.8, 0.7);
    defer first.deinit();
    var second = try fakeLearning(std.testing.allocator, "context", 0.4, 0.3);
    defer second.deinit();

    try store.update(&first);
    try store.update(&second);
    const record = store.find("context").?;
    try std.testing.expectEqual(@as(u64, 2), record.uses);
    try std.testing.expectEqual(@as(u64, 1), record.successes);
    try std.testing.expectEqual(@as(u64, 1), record.failures);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), record.average_score, 0.000001);
    try std.testing.expectEqualStrings("reconsider_strategy", record.last_action);
}

test "StrategyStore save load round trip and skips corrupt lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = StrategyStore.initAt(std.testing.allocator, std.testing.io, tmp.dir, "learning", "learning/strategies.jsonl");
    defer source.deinit();
    var learning = try fakeLearning(std.testing.allocator, "quoted_\"strategy", 0.9, 0.8);
    defer learning.deinit();
    try source.update(&learning);
    try source.save();

    {
        const file = try tmp.dir.createFile(std.testing.io, "learning/strategies.jsonl", .{ .read = true, .truncate = false });
        defer file.close(std.testing.io);
        var buffer: [256]u8 = undefined;
        var writer = file.writer(std.testing.io, &buffer);
        try writer.seekTo((try file.stat(std.testing.io)).size);
        try writer.interface.writeAll("\nnot-json\n");
        try writer.interface.flush();
    }

    var loaded = StrategyStore.initAt(std.testing.allocator, std.testing.io, tmp.dir, "learning", "learning/strategies.jsonl");
    defer loaded.deinit();
    try loaded.load();
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    const record = loaded.find("quoted_\"strategy").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), record.average_score, 0.000001);
}

test "StrategyStore load tolerates missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = StrategyStore.initAt(std.testing.allocator, std.testing.io, tmp.dir, "learning", "learning/strategies.jsonl");
    defer store.deinit();
    try store.load();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "StrategyStore selects best non-reconsidered strategy deterministically" {
    var store = StrategyStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var good = try fakeLearning(std.testing.allocator, "alpha", 0.9, 0.8);
    defer good.deinit();
    var bad = try fakeLearning(std.testing.allocator, "beta", 0.2, 0.2);
    defer bad.deinit();
    try store.update(&good);
    try store.update(&bad);
    try std.testing.expectEqualStrings("alpha", store.select().?.strategy);
}

test "StrategyStore clear releases records" {
    var store = StrategyStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var learning = try fakeLearning(std.testing.allocator, "memory", 0.9, 0.8);
    defer learning.deinit();
    try store.update(&learning);
    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
