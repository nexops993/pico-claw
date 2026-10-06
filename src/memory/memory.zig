const std = @import("std");

const Entry = @import("entry.zig").MemoryEntry;
const MemoryType = @import("entry.zig").MemoryType;
const MemoryStore = @import("store.zig").MemoryStore;

pub const Memory = struct {
    allocator: std.mem.Allocator,
    store: MemoryStore,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !Memory {
        var store = MemoryStore.init(
            allocator,
            io,
        );

        errdefer store.deinit();

        var memory = Memory{
            .allocator = allocator,
            .store = store,
        };

        try memory.loadAll();

        return memory;
    }

    pub fn deinit(
        self: *Memory,
    ) void {
        self.store.deinit();
    }

    pub fn remember(
        self: *Memory,
        memory_type: MemoryType,
        content: []const u8,
        importance: f64,
    ) !u64 {
        const entry = try self.store.add(
            memory_type,
            content,
            importance,
        );

        try self.store.saveType(
            memory_type,
        );

        return entry.id;
    }

    pub fn rememberSemantic(
        self: *Memory,
        content: []const u8,
    ) !u64 {
        return try self.remember(
            .semantic,
            content,
            1.0,
        );
    }

    pub fn rememberEpisodic(
        self: *Memory,
        content: []const u8,
    ) !u64 {
        return try self.remember(
            .episodic,
            content,
            1.0,
        );
    }

    pub fn rememberProcedural(
        self: *Memory,
        content: []const u8,
    ) !u64 {
        return try self.remember(
            .procedural,
            content,
            1.0,
        );
    }

    pub fn rememberError(
        self: *Memory,
        content: []const u8,
    ) !u64 {
        return try self.remember(
            .error_memory,
            content,
            1.0,
        );
    }

    pub fn rememberPreference(
        self: *Memory,
        content: []const u8,
    ) !u64 {
        return try self.remember(
            .preference,
            content,
            1.0,
        );
    }

    pub fn getByType(
        self: *const Memory,
        memory_type: MemoryType,
    ) []const Entry {
        return self.store.getByType(
            memory_type,
        );
    }

    pub fn count(
        self: *const Memory,
    ) usize {
        return self.store.count();
    }

    pub fn countByType(
        self: *const Memory,
        memory_type: MemoryType,
    ) usize {
        return self.store.countByType(
            memory_type,
        );
    }

    pub fn print(
        self: *const Memory,
    ) void {
        const types = [_]MemoryType{
            .semantic,
            .episodic,
            .procedural,
            .error_memory,
            .preference,
        };

        std.debug.print(
            "\n====================\n",
            .{},
        );

        std.debug.print(
            "PICO CLAW MEMORY\n",
            .{},
        );

        std.debug.print(
            "====================\n",
            .{},
        );

        std.debug.print(
            "Total memory: {d}\n\n",
            .{self.count()},
        );

        for (types) |memory_type| {
            const entries = self.getByType(
                memory_type,
            );

            defer if (entries.len > 0) {
                self.allocator.free(entries);
            };

            std.debug.print(
                "[{s}] ({d})\n",
                .{
                    memory_type.name(),
                    entries.len,
                },
            );

            for (entries) |entry| {
                std.debug.print(
                    "  #{d} {s}\n",
                    .{
                        entry.id,
                        entry.content,
                    },
                );

                std.debug.print(
                    "      importance: {d:.2}\n",
                    .{entry.importance},
                );
            }

            std.debug.print(
                "\n",
                .{},
            );
        }
    }

    pub fn searchEntries(
        self: *const Memory,
        query: []const u8,
    ) []const Entry {
        return self.searchEntriesLimited(query, 10);
    }

    pub fn searchEntriesLimited(
        self: *const Memory,
        query: []const u8,
        limit: usize,
    ) []const Entry {
        if (limit == 0) return &[_]Entry{};
        const ranked = self.store.search(query);
        if (ranked.len <= limit) return ranked;
        const result = self.allocator.alloc(Entry, limit) catch {
            self.freeSearchResults(ranked);
            return &[_]Entry{};
        };
        @memcpy(result, ranked[0..limit]);
        self.freeSearchResults(ranked);
        return result;
    }

    pub fn freeSearchResults(
        self: *const Memory,
        results: []const Entry,
    ) void {
        if (results.len > 0) {
            self.allocator.free(results);
        }
    }

    pub fn search(
        self: *const Memory,
        query: []const u8,
    ) void {
        const results = self.searchEntries(
            query,
        );

        defer self.freeSearchResults(
            results,
        );

        std.debug.print(
            "\n====================\n",
            .{},
        );

        std.debug.print(
            "MEMORY SEARCH\n",
            .{},
        );

        std.debug.print(
            "Query: {s}\n",
            .{query},
        );

        std.debug.print(
            "====================\n\n",
            .{},
        );

        if (results.len == 0) {
            std.debug.print(
                "Tidak ada memory yang cocok.\n",
                .{},
            );

            return;
        }

        for (results) |entry| {
            std.debug.print(
                "#{d} [{s}]\n",
                .{
                    entry.id,
                    entry.memory_type.name(),
                },
            );

            std.debug.print(
                "{s}\n",
                .{entry.content},
            );

            std.debug.print(
                "importance: {d:.2}\n\n",
                .{entry.importance},
            );
        }
    }

    pub fn clearType(
        self: *Memory,
        memory_type: MemoryType,
    ) !void {
        self.store.clearType(
            memory_type,
        );

        try self.store.saveType(
            memory_type,
        );
    }

    /// Forget one entry by id. Returns false when the id is unknown; on
    /// success the typed JSONL store is rewritten so the removal persists.
    pub fn forget(self: *Memory, id: u64) bool {
        return self.store.remove(id);
    }

    /// Free a slice of entries previously returned by the store (getByType
    /// allocates a filtered copy). Zero-length static slices are ignored.
    pub fn freeEntries(self: *Memory, entries: []const Entry) void {
        if (entries.len > 0) {
            self.allocator.free(@constCast(entries));
        }
    }

    pub fn clear(
        self: *Memory,
    ) !void {
        const types = [_]MemoryType{
            .semantic,
            .episodic,
            .procedural,
            .error_memory,
            .preference,
        };

        for (types) |memory_type| {
            self.store.clearType(
                memory_type,
            );
        }

        for (types) |memory_type| {
            try self.store.saveType(
                memory_type,
            );
        }
    }

    pub fn clearAll(
        self: *Memory,
    ) !void {
        try self.clear();
    }

    fn loadAll(
        self: *Memory,
    ) !void {
        try self.loadType(
            .semantic,
        );

        try self.loadType(
            .episodic,
        );

        try self.loadType(
            .procedural,
        );

        try self.loadType(
            .error_memory,
        );

        try self.loadType(
            .preference,
        );
    }

    fn loadType(
        self: *Memory,
        memory_type: MemoryType,
    ) !void {
        const entries =
            try self.store.loadType(
                memory_type,
            );

        defer freeLoadedEntries(
            self.allocator,
            entries,
        );

        for (entries) |entry| {
            const added = try self.store.add(
                entry.memory_type,
                entry.content,
                entry.importance,
            );

            if (added.id >= self.store.next_id) {
                self.store.next_id =
                    added.id + 1;
            }
        }
    }

    pub fn exportJson(
        self: *const Memory,
    ) ![]u8 {
        var writer =
            std.Io.Writer.Allocating.init(
                self.allocator,
            );

        defer writer.deinit();

        try writer.writer.writeByte('[');

        var first = true;

        const types = [_]MemoryType{
            .semantic,
            .episodic,
            .procedural,
            .error_memory,
            .preference,
        };

        for (types) |memory_type| {
            const entries = self.getByType(
                memory_type,
            );

            defer if (entries.len > 0) {
                self.allocator.free(entries);
            };

            for (entries) |entry| {
                if (!first) {
                    try writer.writer.writeByte(',');
                }

                first = false;

                try writer.writer.writeAll(
                    "{\"id\":",
                );

                try writer.writer.print(
                    "{d}",
                    .{entry.id},
                );

                try writer.writer.writeAll(
                    ",\"type\":",
                );

                try writeJsonString(
                    &writer.writer,
                    entry.memory_type.name(),
                );

                try writer.writer.writeAll(
                    ",\"content\":",
                );

                try writeJsonString(
                    &writer.writer,
                    entry.content,
                );

                try writer.writer.writeAll(
                    ",\"importance\":",
                );

                try writer.writer.print(
                    "{d}",
                    .{entry.importance},
                );

                try writer.writer.writeByte('}');
            }
        }

        try writer.writer.writeByte(']');

        return try self.allocator.dupe(
            u8,
            writer.written(),
        );
    }
};

fn freeLoadedEntries(
    allocator: std.mem.Allocator,
    entries: []Entry,
) void {
    for (entries) |*entry| {
        entry.deinit(allocator);
    }

    if (entries.len > 0) {
        allocator.free(entries);
    }
}

test "Memory load and deinit release loaded entry ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(
        std.testing.io,
        "semantic.jsonl",
        .{},
    );
    defer file.close(std.testing.io);
    var buffer: [256]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(
        "{\"id\":1,\"content\":\"loaded memory\",\"importance\":1}",
    );
    try writer.interface.flush();

    const base_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(base_path);

    var store = MemoryStore.init(std.testing.allocator, std.testing.io);
    store.base_path = base_path;
    var memory = Memory{
        .allocator = std.testing.allocator,
        .store = store,
    };
    defer memory.deinit();

    try memory.loadType(.semantic);
    try std.testing.expectEqual(@as(usize, 1), memory.count());
    try std.testing.expectEqualStrings(
        "loaded memory",
        memory.store.entries.items[0].content,
    );
}

fn writeJsonString(
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    try writer.writeByte('"');

    for (value) |char| {
        switch (char) {
            '"' => {
                try writer.writeAll(
                    "\\\"",
                );
            },

            '\\' => {
                try writer.writeAll(
                    "\\\\",
                );
            },

            '\n' => {
                try writer.writeAll(
                    "\\n",
                );
            },

            '\r' => {
                try writer.writeAll(
                    "\\r",
                );
            },

            '\t' => {
                try writer.writeAll(
                    "\\t",
                );
            },

            else => {
                try writer.writeByte(
                    char,
                );
            },
        }
    }

    try writer.writeByte('"');
}
