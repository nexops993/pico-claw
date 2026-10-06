const std = @import("std");

const Entry = @import("entry.zig").MemoryEntry;
const MemoryType = @import("entry.zig").MemoryType;

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    entries: std.ArrayList(Entry),
    next_id: u64,

    base_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) MemoryStore {
        return .{
            .allocator = allocator,
            .io = io,
            .entries = .empty,
            .next_id = 1,
            .base_path = "data/memory",
        };
    }

    pub fn deinit(
        self: *MemoryStore,
    ) void {
        for (self.entries.items) |entry| {
            self.allocator.free(
                entry.content,
            );
        }

        self.entries.deinit(
            self.allocator,
        );
    }

    pub fn add(
        self: *MemoryStore,
        memory_type: MemoryType,
        content: []const u8,
        importance: f64,
    ) !Entry {
        const owned_content =
            try self.allocator.dupe(
                u8,
                content,
            );

        errdefer self.allocator.free(
            owned_content,
        );

        const entry = Entry{
            .id = self.next_id,
            .memory_type = memory_type,
            .content = owned_content,
            .importance = importance,
        };

        self.next_id += 1;

        try self.entries.append(
            self.allocator,
            entry,
        );

        return entry;
    }

    pub fn getByType(
        self: *const MemoryStore,
        memory_type: MemoryType,
    ) []const Entry {
        var matching_count: usize = 0;

        for (self.entries.items) |entry| {
            if (entry.memory_type == memory_type) {
                matching_count += 1;
            }
        }

        if (matching_count == 0) {
            return &[_]Entry{};
        }

        const result =
            self.allocator.alloc(
                Entry,
                matching_count,
            ) catch {
                return &[_]Entry{};
            };

        var result_index: usize = 0;

        for (self.entries.items) |entry| {
            if (entry.memory_type == memory_type) {
                result[result_index] = entry;
                result_index += 1;
            }
        }

        return result;
    }

    pub fn count(
        self: *const MemoryStore,
    ) usize {
        return self.entries.items.len;
    }

    pub fn countByType(
        self: *const MemoryStore,
        memory_type: MemoryType,
    ) usize {
        var result: usize = 0;

        for (self.entries.items) |entry| {
            if (entry.memory_type == memory_type) {
                result += 1;
            }
        }

        return result;
    }

    // Pencarian memory berbasis keyword.
    //
    // Contoh:
    //
    // Memory:
    //     "hijau adalah satu"
    //
    // Query:
    //     "hijau itu berapa?"
    //
    // Query akan dipecah menjadi keyword:
    //     hijau
    //
    // Kemudian dicocokkan dengan memory.
    //
    // Stopword seperti "itu", "berapa", "saya",
    // "siapa", dan lain-lain diabaikan.
    pub fn search(
        self: *const MemoryStore,
        query: []const u8,
    ) []const Entry {
        if (query.len == 0) {
            return &[_]Entry{};
        }

        var matches =
            std.ArrayList(SearchMatch).empty;

        defer matches.deinit(
            self.allocator,
        );

        for (self.entries.items) |entry| {
            const score =
                calculateRelevance(
                    query,
                    entry.content,
                );

            if (score > 0) {
                matches.append(
                    self.allocator,
                    .{
                        .entry = entry,
                        .score = score,
                    },
                ) catch {
                    return &[_]Entry{};
                };
            }
        }

        if (matches.items.len == 0) {
            return &[_]Entry{};
        }

        // Urutkan berdasarkan relevance score.
        //
        // Score lebih tinggi berada di depan.
        sortMatches(
            matches.items,
        );

        const result =
            self.allocator.alloc(
                Entry,
                matches.items.len,
            ) catch {
                return &[_]Entry{};
            };

        for (matches.items, 0..) |match, index| {
            result[index] = match.entry;
        }

        return result;
    }

    /// Remove one entry by id. Returns false when the id is unknown. The
    /// affected type's JSONL file is rewritten so the removal persists;
    /// a persistence failure keeps the in-memory removal (next save of that
    /// type rewrites the file).
    pub fn remove(self: *MemoryStore, id: u64) bool {
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) {
            if (self.entries.items[index].id == id) {
                const memory_type = self.entries.items[index].memory_type;
                self.allocator.free(self.entries.items[index].content);
                _ = self.entries.orderedRemove(index);
                self.saveType(memory_type) catch {};
                return true;
            }
        }
        return false;
    }

    pub fn clearType(
        self: *MemoryStore,
        memory_type: MemoryType,
    ) void {
        var index: usize = 0;

        while (index < self.entries.items.len) {
            if (self.entries.items[index].memory_type ==
                memory_type)
            {
                self.allocator.free(
                    self.entries.items[index].content,
                );

                _ = self.entries.orderedRemove(
                    index,
                );

                continue;
            }

            index += 1;
        }
    }

    pub fn saveType(
        self: *MemoryStore,
        memory_type: MemoryType,
    ) !void {
        try self.ensureBaseDirectory();

        const path =
            try self.pathForType(
                memory_type,
            );

        defer self.allocator.free(
            path,
        );

        const file =
            try std.Io.Dir.cwd().createFile(
                self.io,
                path,
                .{},
            );

        defer file.close(
            self.io,
        );

        var buffer: [16 * 1024]u8 = undefined;

        var writer =
            file.writer(
                self.io,
                &buffer,
            );

        var first = true;

        for (self.entries.items) |entry| {
            if (entry.memory_type != memory_type) {
                continue;
            }

            if (!first) {
                try writer.interface.writeByte(
                    '\n',
                );
            }

            first = false;

            try writer.interface.writeAll(
                "{\"id\":",
            );

            try writer.interface.print(
                "{d}",
                .{entry.id},
            );

            try writer.interface.writeAll(
                ",\"content\":",
            );

            try writeJsonString(
                &writer.interface,
                entry.content,
            );

            try writer.interface.writeAll(
                ",\"importance\":",
            );

            try writer.interface.print(
                "{d}",
                .{entry.importance},
            );

            try writer.interface.writeByte(
                '}',
            );
        }

        try writer.interface.flush();
    }

    pub fn loadType(
        self: *MemoryStore,
        memory_type: MemoryType,
    ) ![]Entry {
        const path =
            try self.pathForType(
                memory_type,
            );

        defer self.allocator.free(
            path,
        );

        const file =
            std.Io.Dir.cwd().openFile(
                self.io,
                path,
                .{},
            ) catch |err| {
                if (err == error.FileNotFound) {
                    return &[_]Entry{};
                }

                return err;
            };

        defer file.close(
            self.io,
        );

        var buffer: [16 * 1024]u8 = undefined;

        var reader =
            file.reader(
                self.io,
                &buffer,
            );

        var contents =
            std.Io.Writer.Allocating.init(
                self.allocator,
            );

        defer contents.deinit();

        _ = try reader.interface.streamRemaining(
            &contents.writer,
        );

        const raw =
            contents.written();

        if (raw.len == 0) {
            return &[_]Entry{};
        }

        const StoredMemory = struct {
            id: u64,
            content: []const u8,
            importance: f64,
        };

        var result =
            std.ArrayList(Entry).empty;

        errdefer {
            for (result.items) |entry| {
                self.allocator.free(
                    entry.content,
                );
            }

            result.deinit(
                self.allocator,
            );
        }

        var line_start: usize = 0;

        while (line_start < raw.len) {
            var line_end = line_start;

            while (line_end < raw.len and
                raw[line_end] != '\n')
            {
                line_end += 1;
            }

            const line =
                std.mem.trim(
                    u8,
                    raw[line_start..line_end],
                    " \t\r\n",
                );

            if (line.len > 0) {
                const parsed =
                    try std.json.parseFromSlice(
                        StoredMemory,
                        self.allocator,
                        line,
                        .{},
                    );

                defer parsed.deinit();

                const owned_content =
                    try self.allocator.dupe(
                        u8,
                        parsed.value.content,
                    );

                errdefer self.allocator.free(
                    owned_content,
                );

                try result.append(
                    self.allocator,
                    .{
                        .id = parsed.value.id,
                        .memory_type = memory_type,
                        .content = owned_content,
                        .importance = parsed.value.importance,
                    },
                );
            }

            if (line_end >= raw.len) {
                break;
            }

            line_start = line_end + 1;
        }

        return try result.toOwnedSlice(
            self.allocator,
        );
    }

    fn ensureBaseDirectory(
        self: *MemoryStore,
    ) !void {
        const cwd =
            std.Io.Dir.cwd();

        cwd.createDirPath(
            self.io,
            self.base_path,
        ) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }

    fn pathForType(
        self: *MemoryStore,
        memory_type: MemoryType,
    ) ![]u8 {
        const filename =
            switch (memory_type) {
                .semantic => "semantic.jsonl",
                .episodic => "episodic.jsonl",
                .procedural => "procedural.jsonl",
                .error_memory => "error.jsonl",
                .preference => "preference.jsonl",
            };

        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{
                self.base_path,
                filename,
            },
        );
    }
};

const SearchMatch = struct {
    entry: Entry,
    score: usize,
};

fn calculateRelevance(
    query: []const u8,
    content: []const u8,
) usize {
    var score: usize = 0;

    var query_tokens =
        std.mem.tokenizeAny(
            u8,
            query,
            " \t\r\n.,!?;:()[]{}\"'`",
        );

    while (query_tokens.next()) |raw_token| {
        const token =
            normalizeToken(
                raw_token,
            );

        if (token.len == 0) {
            continue;
        }

        if (isStopWord(token)) {
            continue;
        }

        if (containsWordIgnoreCase(
            content,
            token,
        )) {
            score += 1;

            // Exact token yang cocok mendapat
            // bonus tambahan.
            if (containsIgnoreCase(
                content,
                token,
            )) {
                score += 1;
            }
        }
    }

    // Jika seluruh query ternyata cocok sebagai
    // substring, beri bonus besar.
    if (containsIgnoreCase(
        content,
        query,
    )) {
        score += 3;
    }

    return score;
}

fn normalizeToken(
    token: []const u8,
) []const u8 {
    var start: usize = 0;
    var end: usize = token.len;

    while (start < end and
        isTokenPunctuation(token[start]))
    {
        start += 1;
    }

    while (end > start and
        isTokenPunctuation(token[end - 1]))
    {
        end -= 1;
    }

    return token[start..end];
}

fn isTokenPunctuation(
    char: u8,
) bool {
    return switch (char) {
        '.', ',', '!', '?', ';', ':', '(', ')', '[', ']', '{', '}', '"', '\'', '`', '-', '_', '/' => true,
        else => false,
    };
}

fn isStopWord(
    token: []const u8,
) bool {
    const stop_words = [_][]const u8{
        "yang",
        "dan",
        "atau",
        "di",
        "ke",
        "dari",
        "untuk",
        "dengan",
        "pada",
        "dalam",
        "adalah",
        "itu",
        "ini",
        "saya",
        "aku",
        "kamu",
        "anda",
        "dia",
        "nya",
        "apa",
        "siapa",
        "berapa",
        "mana",
        "kah",
        "apakah",
        "jadi",
        "bisa",
        "tidak",
        "ga",
        "gak",
        "nggak",
    };

    for (stop_words) |stop_word| {
        if (std.ascii.eqlIgnoreCase(
            token,
            stop_word,
        )) {
            return true;
        }
    }

    return false;
}

fn containsWordIgnoreCase(
    haystack: []const u8,
    needle: []const u8,
) bool {
    if (needle.len == 0) {
        return false;
    }

    var start: usize = 0;

    while (start < haystack.len) {
        while (start < haystack.len and
            !isWordCharacter(haystack[start]))
        {
            start += 1;
        }

        if (start >= haystack.len) {
            break;
        }

        var end = start;

        while (end < haystack.len and
            isWordCharacter(haystack[end]))
        {
            end += 1;
        }

        const word =
            haystack[start..end];

        if (std.ascii.eqlIgnoreCase(
            word,
            needle,
        )) {
            return true;
        }

        start = end;
    }

    return false;
}

fn isWordCharacter(
    char: u8,
) bool {
    return std.ascii.isAlphabetic(char) or
        std.ascii.isDigit(char) or
        char == '_';
}

fn containsIgnoreCase(
    haystack: []const u8,
    needle: []const u8,
) bool {
    if (needle.len == 0) {
        return true;
    }

    if (needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;

    while (start + needle.len <= haystack.len) {
        var matched = true;

        for (needle, 0..) |needle_char, index| {
            if (std.ascii.toLower(
                haystack[start + index],
            ) != std.ascii.toLower(
                needle_char,
            )) {
                matched = false;
                break;
            }
        }

        if (matched) {
            return true;
        }

        start += 1;
    }

    return false;
}

fn sortMatches(
    matches: []SearchMatch,
) void {
    if (matches.len < 2) {
        return;
    }

    var index: usize = 1;

    while (index < matches.len) {
        const current =
            matches[index];

        var position = index;

        while (position > 0 and
            matches[position - 1].score <
                current.score)
        {
            matches[position] =
                matches[position - 1];

            position -= 1;
        }

        matches[position] = current;

        index += 1;
    }
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
