const std = @import("std");

pub const MemoryType = enum {
    semantic,
    episodic,
    procedural,
    error_memory,
    preference,

    pub fn name(
        self: MemoryType,
    ) []const u8 {
        return switch (self) {
            .semantic => "semantic",
            .episodic => "episodic",
            .procedural => "procedural",
            .error_memory => "error",
            .preference => "preference",
        };
    }

    pub fn fromString(
        value: []const u8,
    ) ?MemoryType {
        if (std.mem.eql(
            u8,
            value,
            "semantic",
        )) {
            return .semantic;
        }

        if (std.mem.eql(
            u8,
            value,
            "episodic",
        )) {
            return .episodic;
        }

        if (std.mem.eql(
            u8,
            value,
            "procedural",
        )) {
            return .procedural;
        }

        if (std.mem.eql(
            u8,
            value,
            "error",
        )) {
            return .error_memory;
        }

        if (std.mem.eql(
            u8,
            value,
            "preference",
        )) {
            return .preference;
        }

        return null;
    }
};

pub const MemoryEntry = struct {
    id: u64,
    memory_type: MemoryType,
    content: []u8,
    importance: f64,

    pub fn deinit(
        self: *MemoryEntry,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(
            self.content,
        );
    }
};
