const std = @import("std");
const builtin = @import("builtin");

pub const KnowledgeEntry = struct {
    id: u64,
    topic: []u8,
    content: []u8,
    source: []u8,
    confidence: f64,
};

pub const KnowledgeStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    directory_path: []const u8,
    file_path: []const u8,
    entries: std.ArrayList(KnowledgeEntry) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) KnowledgeStore {
        return initAt(allocator, io, std.Io.Dir.cwd(), "data/knowledge", "data/knowledge/knowledge.jsonl");
    }

    pub fn initAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, directory_path: []const u8, file_path: []const u8) KnowledgeStore {
        return .{ .allocator = allocator, .io = io, .dir = dir, .directory_path = directory_path, .file_path = file_path };
    }

    pub fn deinit(self: *KnowledgeStore) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *KnowledgeStore, topic: []const u8, content: []const u8, source: []const u8, confidence: f64) !u64 {
        if (topic.len == 0 or content.len == 0 or !std.math.isFinite(confidence) or confidence < 0 or confidence > 1) return error.InvalidKnowledge;
        if (self.find(topic)) |entry| {
            const new_content = try self.allocator.dupe(u8, content);
            errdefer self.allocator.free(new_content);
            const new_source = try self.allocator.dupe(u8, source);
            self.allocator.free(entry.content);
            self.allocator.free(entry.source);
            entry.content = new_content;
            entry.source = new_source;
            entry.confidence = confidence;
            return entry.id;
        }
        const owned_topic = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(owned_topic);
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{ .id = id, .topic = owned_topic, .content = owned_content, .source = owned_source, .confidence = confidence });
        return id;
    }

    pub fn find(self: *KnowledgeStore, topic: []const u8) ?*KnowledgeEntry {
        for (self.entries.items) |*entry| if (std.ascii.eqlIgnoreCase(entry.topic, topic)) return entry;
        return null;
    }

    pub fn search(self: *const KnowledgeStore, query: []const u8, limit: usize) []const KnowledgeEntry {
        if (limit == 0) return &.{};
        var result = std.ArrayList(KnowledgeEntry).empty;
        for (self.entries.items) |entry| {
            if (!containsIgnoreCase(entry.topic, query) and !containsIgnoreCase(entry.content, query)) continue;
            result.append(self.allocator, entry) catch break;
            if (result.items.len == limit) break;
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    pub fn freeSearchResults(self: *const KnowledgeStore, results: []const KnowledgeEntry) void {
        if (results.len > 0) self.allocator.free(results);
    }

    pub fn count(self: *const KnowledgeStore) usize {
        return self.entries.items.len;
    }

    pub fn clear(self: *KnowledgeStore) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.clearRetainingCapacity();
        self.next_id = 1;
    }

    pub fn save(self: *const KnowledgeStore) !void {
        try self.dir.createDirPath(self.io, self.directory_path);
        var atomic = try self.dir.createFileAtomic(self.io, self.file_path, .{ .replace = true });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        for (self.entries.items, 0..) |entry, index| {
            if (index > 0) try writer.interface.writeByte('\n');
            var stringify: std.json.Stringify = .{ .writer = &writer.interface };
            try stringify.write(entry);
        }
        try writer.interface.flush();
        try atomic.replace(self.io);
    }

    pub fn load(self: *KnowledgeStore) !void {
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
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            self.loadLine(line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => if (!builtin.is_test)
                    std.log.warn("[Knowledge] Skipping corrupt line: {s}", .{@errorName(err)}),
            };
        }
    }

    fn loadLine(self: *KnowledgeStore, line: []const u8) !void {
        const Stored = struct { id: u64, topic: []const u8, content: []const u8, source: []const u8, confidence: f64 };
        const parsed = try std.json.parseFromSlice(Stored, self.allocator, line, .{});
        defer parsed.deinit();
        if (self.find(parsed.value.topic) != null) return error.DuplicateKnowledge;
        _ = try self.add(parsed.value.topic, parsed.value.content, parsed.value.source, parsed.value.confidence);
        self.entries.items[self.entries.items.len - 1].id = parsed.value.id;
        if (parsed.value.id >= self.next_id) self.next_id = parsed.value.id + 1;
    }

    fn freeEntry(self: *KnowledgeStore, entry: KnowledgeEntry) void {
        self.allocator.free(entry.topic);
        self.allocator.free(entry.content);
        self.allocator.free(entry.source);
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}

test "KnowledgeStore persists retrieves and frees owned entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = KnowledgeStore.initAt(std.testing.allocator, std.testing.io, tmp.dir, "knowledge", "knowledge/knowledge.jsonl");
    defer source.deinit();
    _ = try source.add("zig", "Zig has explicit allocators", "test", 0.9);
    try source.save();
    var loaded = KnowledgeStore.initAt(std.testing.allocator, std.testing.io, tmp.dir, "knowledge", "knowledge/knowledge.jsonl");
    defer loaded.deinit();
    try loaded.load();
    const results = loaded.search("allocator", 1);
    defer loaded.freeSearchResults(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("zig", results[0].topic);
}

test "KnowledgeStore rejects invalid values and clears" {
    var store = KnowledgeStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    try std.testing.expectError(error.InvalidKnowledge, store.add("", "content", "test", 1));
    _ = try store.add("topic", "content", "test", 0.5);
    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
