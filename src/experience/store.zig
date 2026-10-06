const std = @import("std");
const builtin = @import("builtin");

const Entry = @import("entry.zig").ExperienceEntry;
const ExperienceResult = @import("entry.zig").ExperienceResult;

pub const ExperienceStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    entries: std.ArrayList(Entry),
    next_id: u64,

    base_path: []const u8,

    const StoredExperience = struct {
        id: u64,
        task: []const u8,
        response: []const u8,
        strategy: []const u8,
        result: []const u8,
        memory_used: usize,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) ExperienceStore {
        return initAt(allocator, io, std.Io.Dir.cwd(), "data/experiences");
    }

    pub fn initAt(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        base_path: []const u8,
    ) ExperienceStore {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .entries = .empty,
            .next_id = 1,
            .base_path = base_path,
        };
    }

    pub fn deinit(
        self: *ExperienceStore,
    ) void {
        for (self.entries.items) |entry| {
            self.allocator.free(
                entry.task,
            );

            self.allocator.free(
                entry.response,
            );

            self.allocator.free(
                entry.strategy,
            );
        }

        self.entries.deinit(
            self.allocator,
        );
    }

    pub fn add(
        self: *ExperienceStore,
        task: []const u8,
        response: []const u8,
        strategy: []const u8,
        result: ExperienceResult,
        memory_used: usize,
    ) !Entry {
        const owned_task =
            try self.allocator.dupe(
                u8,
                task,
            );

        errdefer self.allocator.free(
            owned_task,
        );

        const owned_response =
            try self.allocator.dupe(
                u8,
                response,
            );

        errdefer self.allocator.free(
            owned_response,
        );

        const owned_strategy =
            try self.allocator.dupe(
                u8,
                strategy,
            );

        errdefer self.allocator.free(
            owned_strategy,
        );

        const entry = Entry{
            .id = self.next_id,
            .task = owned_task,
            .response = owned_response,
            .strategy = owned_strategy,
            .result = result,
            .memory_used = memory_used,
        };

        self.next_id += 1;

        try self.entries.append(
            self.allocator,
            entry,
        );

        return entry;
    }

    pub fn count(
        self: *const ExperienceStore,
    ) usize {
        return self.entries.items.len;
    }

    pub fn getAll(
        self: *const ExperienceStore,
    ) []const Entry {
        return self.entries.items;
    }

    pub fn getLatest(
        self: *const ExperienceStore,
    ) ?Entry {
        if (self.entries.items.len == 0) {
            return null;
        }

        return self.entries.items[
            self.entries.items.len - 1
        ];
    }

    pub fn clear(
        self: *ExperienceStore,
    ) void {
        for (self.entries.items) |entry| {
            self.allocator.free(
                entry.task,
            );

            self.allocator.free(
                entry.response,
            );

            self.allocator.free(
                entry.strategy,
            );
        }

        self.entries.clearRetainingCapacity();

        self.next_id = 1;
    }

    pub fn save(
        self: *ExperienceStore,
    ) !void {
        try self.ensureBaseDirectory();

        const file_path =
            try self.path();

        defer self.allocator.free(
            file_path,
        );

        const file =
            try self.dir.createFile(
                self.io,
                file_path,
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

        for (self.entries.items, 0..) |entry, index| {
            if (index > 0) {
                try writer.interface.writeByte(
                    '\n',
                );
            }

            try writer.interface.writeAll(
                "{\"id\":",
            );

            try writer.interface.print(
                "{d}",
                .{
                    entry.id,
                },
            );

            try writer.interface.writeAll(
                ",\"task\":",
            );

            try writeJsonString(
                &writer.interface,
                entry.task,
            );

            try writer.interface.writeAll(
                ",\"response\":",
            );

            try writeJsonString(
                &writer.interface,
                entry.response,
            );

            try writer.interface.writeAll(
                ",\"strategy\":",
            );

            try writeJsonString(
                &writer.interface,
                entry.strategy,
            );

            try writer.interface.writeAll(
                ",\"result\":",
            );

            try writeJsonString(
                &writer.interface,
                entry.result.name(),
            );

            try writer.interface.writeAll(
                ",\"memory_used\":",
            );

            try writer.interface.print(
                "{d}",
                .{
                    entry.memory_used,
                },
            );

            try writer.interface.writeByte(
                '}',
            );
        }

        try writer.interface.flush();
    }

    pub fn load(
        self: *ExperienceStore,
    ) !void {
        const file_path =
            try self.path();

        defer self.allocator.free(
            file_path,
        );

        const file =
            self.dir.openFile(
                self.io,
                file_path,
                .{},
            ) catch |err| {
                if (err == error.FileNotFound) {
                    return;
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
            return;
        }

        var line_start: usize = 0;

        while (line_start < raw.len) {
            var line_end =
                line_start;

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
                self.loadExperienceLine(line) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => if (!builtin.is_test)
                        std.log.warn("[Experience] Skipping corrupt line: {s}", .{@errorName(err)}),
                };
            }

            if (line_end >= raw.len) {
                break;
            }

            line_start =
                line_end + 1;
        }
    }

    fn loadExperienceLine(
        self: *ExperienceStore,
        line: []const u8,
    ) !void {
        const parsed =
            try std.json.parseFromSlice(
                StoredExperience,
                self.allocator,
                line,
                .{},
            );

        defer parsed.deinit();

        const owned_task =
            try self.allocator.dupe(
                u8,
                parsed.value.task,
            );

        errdefer self.allocator.free(
            owned_task,
        );

        const owned_response =
            try self.allocator.dupe(
                u8,
                parsed.value.response,
            );

        errdefer self.allocator.free(
            owned_response,
        );

        const owned_strategy =
            try self.allocator.dupe(
                u8,
                parsed.value.strategy,
            );

        errdefer self.allocator.free(
            owned_strategy,
        );

        const result =
            parseResult(
                parsed.value.result,
            );

        try self.entries.append(
            self.allocator,
            .{
                .id = parsed.value.id,
                .task = owned_task,
                .response = owned_response,
                .strategy = owned_strategy,
                .result = result,
                .memory_used = parsed.value.memory_used,
            },
        );

        if (parsed.value.id >= self.next_id) {
            self.next_id =
                parsed.value.id + 1;
        }
    }

    pub fn print(
        self: *const ExperienceStore,
    ) void {
        std.debug.print(
            "\nExperiences: {d}\n",
            .{
                self.entries.items.len,
            },
        );

        if (self.entries.items.len == 0) {
            std.debug.print(
                "Belum ada experience.\n",
                .{},
            );

            return;
        }

        for (self.entries.items) |entry| {
            std.debug.print(
                "\nExperience #{d}\n",
                .{
                    entry.id,
                },
            );

            std.debug.print(
                "Task: {s}\n",
                .{
                    entry.task,
                },
            );

            std.debug.print(
                "Response: {s}\n",
                .{
                    entry.response,
                },
            );

            std.debug.print(
                "Strategy: {s}\n",
                .{
                    entry.strategy,
                },
            );

            std.debug.print(
                "Result: {s}\n",
                .{
                    entry.result.name(),
                },
            );

            std.debug.print(
                "Memory used: {d}\n",
                .{
                    entry.memory_used,
                },
            );
        }
    }

    fn ensureBaseDirectory(
        self: *ExperienceStore,
    ) !void {
        self.dir.createDirPath(
            self.io,
            self.base_path,
        ) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };
    }

    fn path(
        self: *ExperienceStore,
    ) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/experiences.jsonl",
            .{
                self.base_path,
            },
        );
    }
};

fn parseResult(
    value: []const u8,
) ExperienceResult {
    if (std.ascii.eqlIgnoreCase(
        value,
        "success",
    )) {
        return .success;
    }

    if (std.ascii.eqlIgnoreCase(
        value,
        "failure",
    )) {
        return .failure;
    }

    return .unknown;
}

fn writeJsonString(
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    try writer.writeByte(
        '"',
    );

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

    try writer.writeByte(
        '"',
    );
}
