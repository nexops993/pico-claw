const std = @import("std");

pub const ExperienceResult = enum {
    success,
    failure,
    unknown,

    pub fn name(self: ExperienceResult) []const u8 {
        return switch (self) {
            .success => "success",
            .failure => "failure",
            .unknown => "unknown",
        };
    }
};

pub const ExperienceEntry = struct {
    id: u64,

    task: []u8,
    response: []u8,

    strategy: []u8,

    result: ExperienceResult,

    memory_used: usize,
};
