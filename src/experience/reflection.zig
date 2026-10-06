const std = @import("std");

const Entry = @import("entry.zig").ExperienceEntry;
const ExperienceResult = @import("entry.zig").ExperienceResult;
const Evaluation = @import("evaluation.zig").Evaluation;
const Evaluator = @import("evaluation.zig").Evaluator;

pub const Reflection = struct {
    allocator: std.mem.Allocator,

    entry_id: u64,
    evaluation: Evaluation,
    insight: []u8,
    recommendation: []u8,

    pub fn deinit(self: *Reflection) void {
        self.allocator.free(self.insight);
        self.allocator.free(self.recommendation);
    }

    pub fn print(self: *const Reflection) void {
        std.debug.print(
            "\n=== Reflection ===\n",
            .{},
        );

        std.debug.print(
            "Experience: #{d}\n",
            .{self.entry_id},
        );

        std.debug.print(
            "Evaluation: {s}\n",
            .{self.evaluation.label()},
        );

        std.debug.print(
            "Score: {d:.2}\n",
            .{self.evaluation.score},
        );

        std.debug.print(
            "Insight: {s}\n",
            .{self.insight},
        );

        std.debug.print(
            "Recommendation: {s}\n",
            .{self.recommendation},
        );

        std.debug.print(
            "=== End Reflection ===\n",
            .{},
        );
    }
};

pub const Reflector = struct {
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
    ) Reflector {
        return .{
            .allocator = allocator,
        };
    }

    pub fn reflect(
        self: *Reflector,
        entry: *const Entry,
    ) !Reflection {
        const evaluation =
            Evaluator.evaluate(entry);

        const insight =
            try self.buildInsight(
                entry,
                &evaluation,
            );

        errdefer self.allocator.free(
            insight,
        );

        const recommendation =
            try self.buildRecommendation(
                entry,
                &evaluation,
            );

        errdefer self.allocator.free(
            recommendation,
        );

        return .{
            .allocator = self.allocator,
            .entry_id = entry.id,
            .evaluation = evaluation,
            .insight = insight,
            .recommendation = recommendation,
        };
    }

    fn buildInsight(
        self: *Reflector,
        entry: *const Entry,
        evaluation: *const Evaluation,
    ) ![]u8 {
        var writer =
            std.Io.Writer.Allocating.init(
                self.allocator,
            );

        defer writer.deinit();

        switch (entry.result) {
            .success => {
                try writer.writer.writeAll(
                    "Task berhasil diselesaikan",
                );

                if (entry.memory_used > 0) {
                    try writer.writer.writeAll(
                        " dengan bantuan long-term memory",
                    );
                } else {
                    try writer.writer.writeAll(
                        " tanpa bantuan long-term memory",
                    );
                }

                try writer.writer.writeAll(
                    ".",
                );
            },

            .failure => {
                try writer.writer.writeAll(
                    "Task gagal diselesaikan menggunakan strategy ",
                );

                try writer.writer.writeAll(
                    entry.strategy,
                );

                try writer.writer.writeAll(
                    ".",
                );
            },

            .unknown => {
                try writer.writer.writeAll(
                    "Hasil task belum dapat dikategorikan secara pasti.",
                );
            },
        }

        try writer.writer.writeAll(
            " Evaluation berada pada kategori ",
        );

        try writer.writer.writeAll(
            evaluation.label(),
        );

        try writer.writer.writeAll(
            ".",
        );

        return try self.allocator.dupe(
            u8,
            writer.written(),
        );
    }

    fn buildRecommendation(
        self: *Reflector,
        entry: *const Entry,
        evaluation: *const Evaluation,
    ) ![]u8 {
        var writer =
            std.Io.Writer.Allocating.init(
                self.allocator,
            );

        defer writer.deinit();

        if (evaluation.score >= 0.8) {
            try writer.writer.writeAll(
                "Strategy ini dapat dipertahankan untuk task serupa.",
            );

            return try self.allocator.dupe(
                u8,
                writer.written(),
            );
        }

        if (evaluation.score >= 0.5) {
            try writer.writer.writeAll(
                "Strategy ini dapat digunakan kembali, tetapi perlu evaluasi tambahan pada task berikutnya.",
            );

            return try self.allocator.dupe(
                u8,
                writer.written(),
            );
        }

        if (entry.result == .failure) {
            try writer.writer.writeAll(
                "Strategy perlu dievaluasi dan kemungkinan diganti untuk task serupa.",
            );
        } else {
            try writer.writer.writeAll(
                "Hasil ini perlu diamati kembali sebelum strategy dianggap berhasil.",
            );
        }

        return try self.allocator.dupe(
            u8,
            writer.written(),
        );
    }
};

test "reflection success tanpa memory" {
    var task = [_]u8{
        'H', 'i', 't', 'u', 'n', 'g',
    };

    var response = [_]u8{
        'J', 'a', 'w', 'a', 'b', 'a', 'n',
    };

    var strategy = [_]u8{
        'c', 'o', 'n', 'v', 'e',
        'r', 's', 'a', 't', 'i',
        'o', 'n', '_', 'c', 'o',
        'n', 't', 'e', 'x', 't',
    };

    const entry = Entry{
        .id = 1,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .success,
        .memory_used = 0,
    };

    var reflector =
        Reflector.init(
            std.testing.allocator,
        );

    var reflection =
        try reflector.reflect(
            &entry,
        );

    defer reflection.deinit();

    try std.testing.expectEqual(
        @as(f64, 0.8),
        reflection.evaluation.score,
    );

    try std.testing.expectEqualStrings(
        "good",
        reflection.evaluation.label(),
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reflection.insight,
            "tanpa bantuan long-term memory",
        ) != null,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reflection.recommendation,
            "dipertahankan",
        ) != null,
    );
}

test "reflection success dengan memory" {
    var task = [_]u8{
        'T', 'e', 's', ' ',
        'm', 'e', 'm', 'o',
        'r', 'y',
    };

    var response = [_]u8{
        'J', 'a', 'w', 'a', 'b', 'a', 'n',
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
        .memory_used = 2,
    };

    var reflector =
        Reflector.init(
            std.testing.allocator,
        );

    var reflection =
        try reflector.reflect(
            &entry,
        );

    defer reflection.deinit();

    try std.testing.expectEqual(
        @as(f64, 0.9),
        reflection.evaluation.score,
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reflection.insight,
            "dengan bantuan long-term memory",
        ) != null,
    );
}

test "reflection failure" {
    var task = [_]u8{
        'T', 'e', 's', ' ',
        'g', 'a', 'g', 'a',
        'l',
    };

    var response = [_]u8{
        'G', 'a', 'g', 'a', 'l',
    };

    var strategy = [_]u8{
        't', 'e', 's', 't',
        '_', 's', 't', 'r',
        'a', 't', 'e', 'g',
        'y',
    };

    const entry = Entry{
        .id = 3,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .failure,
        .memory_used = 0,
    };

    var reflector =
        Reflector.init(
            std.testing.allocator,
        );

    var reflection =
        try reflector.reflect(
            &entry,
        );

    defer reflection.deinit();

    try std.testing.expectEqual(
        @as(f64, 0.2),
        reflection.evaluation.score,
    );

    try std.testing.expectEqualStrings(
        "poor",
        reflection.evaluation.label(),
    );

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reflection.recommendation,
            "diganti",
        ) != null,
    );
}

test "reflection unknown" {
    var task = [_]u8{
        'T', 'e', 's',
    };

    var response = [_]u8{
        'R', 'e', 's',
        'p', 'o', 'n',
        's', 'e',
    };

    var strategy = [_]u8{
        'u', 'n', 'k', 'n',
        'o', 'w', 'n',
    };

    const entry = Entry{
        .id = 4,
        .task = task[0..],
        .response = response[0..],
        .strategy = strategy[0..],
        .result = .unknown,
        .memory_used = 0,
    };

    var reflector =
        Reflector.init(
            std.testing.allocator,
        );

    var reflection =
        try reflector.reflect(
            &entry,
        );

    defer reflection.deinit();

    try std.testing.expectEqual(
        @as(f64, 0.5),
        reflection.evaluation.score,
    );

    try std.testing.expectEqualStrings(
        "moderate",
        reflection.evaluation.label(),
    );
}
