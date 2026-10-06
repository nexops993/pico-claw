const std = @import("std");

const Entry = @import("entry.zig").ExperienceEntry;
const ExperienceResult = @import("entry.zig").ExperienceResult;
const Evaluation = @import("evaluation.zig").Evaluation;
const Evaluator = @import("evaluation.zig").Evaluator;
const Reflection = @import("reflection.zig").Reflection;
const Reflector = @import("reflection.zig").Reflector;

pub const LearningAction = enum {
    keep_strategy,
    observe_strategy,
    reconsider_strategy,

    pub fn name(self: LearningAction) []const u8 {
        return switch (self) {
            .keep_strategy => "keep_strategy",
            .observe_strategy => "observe_strategy",
            .reconsider_strategy => "reconsider_strategy",
        };
    }
};

pub const LearningEntry = struct {
    allocator: std.mem.Allocator,

    entry_id: u64,
    strategy: []u8,
    score: f64,
    lesson: []u8,
    action: LearningAction,
    confidence: f64,

    pub fn deinit(self: *LearningEntry) void {
        self.allocator.free(self.strategy);
        self.allocator.free(self.lesson);
    }

    pub fn print(self: *const LearningEntry) void {
        std.debug.print(
            "\n=== Learning ===\n",
            .{},
        );

        std.debug.print(
            "Experience: #{d}\n",
            .{self.entry_id},
        );

        std.debug.print(
            "Strategy: {s}\n",
            .{self.strategy},
        );

        std.debug.print(
            "Score: {d:.2}\n",
            .{self.score},
        );

        std.debug.print(
            "Lesson: {s}\n",
            .{self.lesson},
        );

        std.debug.print(
            "Action: {s}\n",
            .{self.action.name()},
        );

        std.debug.print(
            "Confidence: {d:.2}\n",
            .{self.confidence},
        );

        std.debug.print(
            "=== End Learning ===\n",
            .{},
        );
    }
};

pub const Learner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Learner {
        return .{
            .allocator = allocator,
        };
    }

    pub fn learn(
        self: *Learner,
        entry: *const Entry,
        evaluation: *const Evaluation,
        reflection: *const Reflection,
    ) !LearningEntry {
        const strategy = try self.allocator.dupe(
            u8,
            entry.strategy,
        );

        errdefer self.allocator.free(strategy);

        const lesson = try std.fmt.allocPrint(
            self.allocator,
            "{s} {s}",
            .{
                reflection.insight,
                reflection.recommendation,
            },
        );

        errdefer self.allocator.free(lesson);

        return .{
            .allocator = self.allocator,
            .entry_id = entry.id,
            .strategy = strategy,
            .score = evaluation.score,
            .lesson = lesson,
            .action = actionForScore(evaluation.score),
            .confidence = confidenceForScore(evaluation.score),
        };
    }

    fn actionForScore(score: f64) LearningAction {
        if (score >= 0.8) {
            return .keep_strategy;
        }

        if (score >= 0.5) {
            return .observe_strategy;
        }

        return .reconsider_strategy;
    }

    fn confidenceForScore(score: f64) f64 {
        var confidence = if (score >= 0.5)
            (score - 0.5) * 2.0
        else
            (0.5 - score) * 2.0;

        if (confidence < 0.0) {
            confidence = 0.0;
        }

        if (confidence > 1.0) {
            confidence = 1.0;
        }

        return confidence;
    }
};

fn createLearning(
    allocator: std.mem.Allocator,
    entry: *const Entry,
) !LearningEntry {
    const evaluation = Evaluator.evaluate(entry);

    var reflector = Reflector.init(allocator);
    var reflection = try reflector.reflect(entry);
    defer reflection.deinit();

    var learner = Learner.init(allocator);

    return try learner.learn(
        entry,
        &evaluation,
        &reflection,
    );
}

fn testEntry(
    id: u64,
    result: ExperienceResult,
    memory_used: usize,
    task: []u8,
    response: []u8,
    strategy: []u8,
) Entry {
    return .{
        .id = id,
        .task = task,
        .response = response,
        .strategy = strategy,
        .result = result,
        .memory_used = memory_used,
    };
}

test "successful experience menghasilkan learning yang benar" {
    var task = [_]u8{ 'T', 'e', 's' };
    var response = [_]u8{ 'B', 'e', 'r', 'h', 'a', 's', 'i', 'l' };
    var strategy = [_]u8{
        'c', 'o', 'n', 'v', 'e', 'r', 's', 'a', 't', 'i', 'o', 'n',
    };

    const entry = testEntry(
        1,
        .success,
        0,
        task[0..],
        response[0..],
        strategy[0..],
    );

    var learning = try createLearning(
        std.testing.allocator,
        &entry,
    );
    defer learning.deinit();

    try std.testing.expectEqual(@as(u64, 1), learning.entry_id);
    try std.testing.expectEqual(@as(f64, 0.8), learning.score);
    try std.testing.expectEqual(
        LearningAction.keep_strategy,
        learning.action,
    );
    try std.testing.expectEqualStrings(
        strategy[0..],
        learning.strategy,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, learning.lesson, "berhasil") != null,
    );
}

test "successful experience dengan memory mencatat kontribusi memory" {
    var task = [_]u8{ 'T', 'e', 's', ' ', 'm', 'e', 'm', 'o', 'r', 'y' };
    var response = [_]u8{ 'B', 'e', 'r', 'h', 'a', 's', 'i', 'l' };
    var strategy = [_]u8{
        'l', 'o', 'n', 'g', '_', 't', 'e', 'r', 'm', '_',
        'm', 'e', 'm', 'o', 'r', 'y',
    };

    const entry = testEntry(
        2,
        .success,
        2,
        task[0..],
        response[0..],
        strategy[0..],
    );

    var learning = try createLearning(
        std.testing.allocator,
        &entry,
    );
    defer learning.deinit();

    try std.testing.expectEqual(@as(f64, 0.9), learning.score);
    try std.testing.expectEqual(
        LearningAction.keep_strategy,
        learning.action,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            learning.lesson,
            "dengan bantuan long-term memory",
        ) != null,
    );
}

test "failure menghasilkan lesson dan action berbeda" {
    var task = [_]u8{ 'T', 'e', 's', ' ', 'g', 'a', 'g', 'a', 'l' };
    var response = [_]u8{ 'G', 'a', 'g', 'a', 'l' };
    var strategy = [_]u8{
        't', 'e', 's', 't', '_', 's', 't', 'r', 'a', 't', 'e', 'g', 'y',
    };

    const entry = testEntry(
        3,
        .failure,
        0,
        task[0..],
        response[0..],
        strategy[0..],
    );

    var learning = try createLearning(
        std.testing.allocator,
        &entry,
    );
    defer learning.deinit();

    try std.testing.expectEqual(@as(f64, 0.2), learning.score);
    try std.testing.expectEqual(
        LearningAction.reconsider_strategy,
        learning.action,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, learning.lesson, "gagal") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, learning.lesson, "diganti") != null,
    );
}

test "unknown menghasilkan learning aman" {
    var task = [_]u8{ 'T', 'e', 's' };
    var response = [_]u8{ 'R', 'e', 's', 'p', 'o', 'n', 's', 'e' };
    var strategy = [_]u8{ 'u', 'n', 'k', 'n', 'o', 'w', 'n' };

    const entry = testEntry(
        4,
        .unknown,
        0,
        task[0..],
        response[0..],
        strategy[0..],
    );

    var learning = try createLearning(
        std.testing.allocator,
        &entry,
    );
    defer learning.deinit();

    try std.testing.expectEqual(@as(f64, 0.5), learning.score);
    try std.testing.expectEqual(
        LearningAction.observe_strategy,
        learning.action,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, learning.lesson, "belum") != null,
    );
}

test "confidence selalu dalam range" {
    const scores = [_]f64{
        -1.0,
        0.0,
        0.2,
        0.5,
        0.8,
        1.0,
        2.0,
    };

    for (scores) |score| {
        const confidence = Learner.confidenceForScore(score);

        try std.testing.expect(confidence >= 0.0);
        try std.testing.expect(confidence <= 1.0);
    }
}

test "learning deinit membebaskan allocation" {
    var task = [_]u8{ 'T', 'e', 's' };
    var response = [_]u8{ 'B', 'e', 'r', 'h', 'a', 's', 'i', 'l' };
    var strategy = [_]u8{ 't', 'e', 's', 't' };

    const entry = testEntry(
        5,
        .success,
        0,
        task[0..],
        response[0..],
        strategy[0..],
    );

    var learning = try createLearning(
        std.testing.allocator,
        &entry,
    );

    learning.deinit();
}
