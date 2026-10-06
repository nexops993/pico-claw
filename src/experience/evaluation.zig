const std = @import("std");

const Entry = @import("entry.zig").ExperienceEntry;
const ExperienceResult = @import("entry.zig").ExperienceResult;

pub const Evaluation = struct {
    score: f64,
    result: ExperienceResult,
    memory_used: usize,
    strategy: []const u8,

    pub fn isSuccessful(self: *const Evaluation) bool {
        return self.result == .success;
    }

    pub fn isFailure(self: *const Evaluation) bool {
        return self.result == .failure;
    }

    pub fn label(self: *const Evaluation) []const u8 {
        if (self.score >= 0.8) {
            return "good";
        }

        if (self.score >= 0.5) {
            return "moderate";
        }

        return "poor";
    }

    pub fn print(self: *const Evaluation) void {
        std.debug.print(
            "Evaluation: {s}\n",
            .{self.label()},
        );

        std.debug.print(
            "Score: {d:.2}\n",
            .{self.score},
        );

        std.debug.print(
            "Result: {s}\n",
            .{self.result.name()},
        );

        std.debug.print(
            "Strategy: {s}\n",
            .{self.strategy},
        );

        std.debug.print(
            "Memory used: {d}\n",
            .{self.memory_used},
        );
    }
};

pub const Evaluator = struct {
    pub fn evaluate(
        entry: *const Entry,
    ) Evaluation {
        const score =
            calculateScore(
                entry.result,
                entry.memory_used,
                entry.response,
            );

        return .{
            .score = score,
            .result = entry.result,
            .memory_used = entry.memory_used,
            .strategy = entry.strategy,
        };
    }

    fn calculateScore(
        result: ExperienceResult,
        memory_used: usize,
        response: []const u8,
    ) f64 {
        var score: f64 = switch (result) {
            .success => 0.8,
            .failure => 0.2,
            .unknown => 0.5,
        };

        if (memory_used > 0 and result == .success) {
            score += 0.1;
        }

        if (response.len == 0) {
            score -= 0.3;
        }

        if (score < 0.0) {
            score = 0.0;
        }

        if (score > 1.0) {
            score = 1.0;
        }

        return score;
    }
};

test "evaluasi experience berhasil" {
    var task = [_]u8{ 'T', 'e', 's' };
    var response = [_]u8{
        'J', 'a', 'w', 'a', 'b',
        'a', 'n', ' ', 'b', 'e',
        'r', 'h', 'a', 's', 'i',
        'l',
    };
    var strategy = [_]u8{
        'c', 'o', 'n', 'v', 'e', 'r',
        's', 'a', 't', 'i', 'o', 'n',
        '_', 'c', 'o', 'n', 't', 'e',
        'x', 't',
    };

    const entry = Entry{
        .id = 1,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .success,
        .memory_used = 0,
    };

    const evaluation =
        Evaluator.evaluate(&entry);

    try std.testing.expectEqual(
        ExperienceResult.success,
        evaluation.result,
    );

    try std.testing.expectEqual(
        @as(f64, 0.8),
        evaluation.score,
    );

    try std.testing.expect(
        evaluation.isSuccessful(),
    );

    try std.testing.expectEqualStrings(
        "good",
        evaluation.label(),
    );
}

test "evaluasi success dengan memory" {
    var task = [_]u8{
        'T', 'e', 's', ' ',
        'm', 'e', 'm', 'o',
        'r', 'y',
    };

    var response = [_]u8{
        'J', 'a', 'w', 'a', 'b',
        'a', 'n', ' ', 'm', 'e',
        'n', 'g', 'g', 'u', 'n',
        'a', 'k', 'a', 'n', ' ',
        'm', 'e', 'm', 'o', 'r',
        'y',
    };

    var strategy = [_]u8{
        'l', 'o', 'n', 'g',
        '_', 't', 'e', 'r',
        'm', '_', 'm', 'e',
        'm', 'o', 'r', 'y',
    };

    const entry = Entry{
        .id = 2,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .success,
        .memory_used = 3,
    };

    const evaluation =
        Evaluator.evaluate(&entry);

    try std.testing.expectEqual(
        @as(f64, 0.9),
        evaluation.score,
    );
}

test "evaluasi failure" {
    var task = [_]u8{
        'T', 'e', 's', ' ',
        'g', 'a', 'g', 'a',
        'l',
    };

    var response = [_]u8{
        'G', 'a', 'g', 'a', 'l',
    };

    var strategy = [_]u8{
        'c', 'o', 'n', 'v', 'e',
        'r', 's', 'a', 't', 'i',
        'o', 'n', '_', 'c', 'o',
        'n', 't', 'e', 'x', 't',
    };

    const entry = Entry{
        .id = 3,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .failure,
        .memory_used = 0,
    };

    const evaluation =
        Evaluator.evaluate(&entry);

    try std.testing.expectEqual(
        ExperienceResult.failure,
        evaluation.result,
    );

    try std.testing.expectEqual(
        @as(f64, 0.2),
        evaluation.score,
    );

    try std.testing.expect(
        evaluation.isFailure(),
    );

    try std.testing.expectEqualStrings(
        "poor",
        evaluation.label(),
    );
}

test "response kosong menurunkan score" {
    var task = [_]u8{
        'T', 'e', 's', ' ',
        'k', 'o', 's', 'o',
        'n', 'g',
    };

    var response = [_]u8{};

    var strategy = [_]u8{
        'c', 'o', 'n', 'v', 'e',
        'r', 's', 'a', 't', 'i',
        'o', 'n', '_', 'c', 'o',
        'n', 't', 'e', 'x', 't',
    };

    const entry = Entry{
        .id = 4,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .success,
        .memory_used = 0,
    };

    const evaluation =
        Evaluator.evaluate(&entry);

    try std.testing.expectEqual(
        @as(f64, 0.5),
        evaluation.score,
    );
}
