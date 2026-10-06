const std = @import("std");
const Plan = @import("planner.zig").Plan;
const ToolRegistry = @import("tools/registry.zig").ToolRegistry;
const task = @import("core/task.zig");

pub const max_execution_steps: usize = 16;

pub const StepResult = struct {
    step_id: usize,
    tool_name: ?[]const u8,
    output: []u8,
};

pub const ExecutionResult = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(StepResult) = .empty,

    pub fn deinit(self: *ExecutionResult) void {
        for (self.steps.items) |step| self.allocator.free(step.output);
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    tools: *const ToolRegistry,
    step_limit: usize = max_execution_steps,
    /// Optional clock; step durations are recorded as 0 when absent.
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator, tools: *const ToolRegistry) Executor {
        return .{ .allocator = allocator, .tools = tools };
    }

    pub fn execute(self: *const Executor, plan: *const Plan) !ExecutionResult {
        return self.executeResumable(plan, null);
    }

    /// Execute a plan, skipping steps that already completed for this task
    /// (reported by `recorder`). A skipped step contributes a bounded replay
    /// marker instead of re-running its tool, so resuming a failed task never
    /// repeats completed side effects.
    pub fn executeResumable(
        self: *const Executor,
        plan: *const Plan,
        recorder: ?task.Recorder,
    ) !ExecutionResult {
        if (plan.stepCount() == 0) return error.EmptyPlan;
        if (plan.stepCount() > self.step_limit) return error.ExecutionLimitExceeded;

        var result = ExecutionResult{ .allocator = self.allocator };
        errdefer result.deinit();
        for (plan.steps.items) |step| {
            if (recorder) |r| {
                if (r.sawStep(step.id, step.tool_name)) {
                    r.noteStep(step.id, step.tool_name, .replayed, 0);
                    const marker = try std.fmt.allocPrint(
                        self.allocator,
                        task.step_replay_marker,
                        .{ step.id, step.tool_name orelse "reasoning" },
                    );
                    errdefer self.allocator.free(marker);
                    try result.steps.append(self.allocator, .{
                        .step_id = step.id,
                        .tool_name = step.tool_name,
                        .output = marker,
                    });
                    continue;
                }
                r.noteStep(step.id, step.tool_name, .running, 0);
            }

            const started = task.monotonicNow(self.io);
            const output = if (step.tool_name) |name|
                self.tools.execute(self.allocator, name, step.tool_input.?) catch |err| {
                    if (recorder) |r| r.noteStep(step.id, step.tool_name, .failed, task.elapsedMs(self.io, started));
                    return err;
                }
            else
                try self.allocator.dupe(u8, step.description);
            errdefer self.allocator.free(output);
            if (recorder) |r| r.noteStep(step.id, step.tool_name, .completed, task.elapsedMs(self.io, started));
            try result.steps.append(self.allocator, .{
                .step_id = step.id,
                .tool_name = step.tool_name,
                .output = output,
            });
        }
        return result;
    }
};

const EchoTool = struct {
    calls: usize = 0,

    fn execute(context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        const self: *EchoTool = @ptrCast(@alignCast(context));
        self.calls += 1;
        return allocator.dupe(u8, input);
    }
};

test "executor runs mixed multi-step plan in order" {
    var echo = EchoTool{};
    var tools = ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    try tools.register(.{
        .name = "echo",
        .description = "Echo",
        .context = &echo,
        .executeFn = EchoTool.execute,
    });
    var plan = try Plan.init(std.testing.allocator, "multi-step");
    defer plan.deinit();
    try plan.addStep("first reasoning", null, null);
    try plan.addStep("echo second", "echo", "second");

    const executor = Executor.init(std.testing.allocator, &tools);
    var result = try executor.execute(&plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expectEqualStrings("first reasoning", result.steps.items[0].output);
    try std.testing.expectEqualStrings("second", result.steps.items[1].output);
    try std.testing.expectEqual(@as(usize, 1), echo.calls);
}

test "executor validates empty plan limit and unknown tool" {
    var tools = ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    const executor = Executor.init(std.testing.allocator, &tools);
    var empty = try Plan.init(std.testing.allocator, "empty");
    defer empty.deinit();
    try std.testing.expectError(error.EmptyPlan, executor.execute(&empty));

    var invalid = try Plan.init(std.testing.allocator, "invalid");
    defer invalid.deinit();
    try invalid.addStep("missing", "missing", "input");
    try std.testing.expectError(error.ToolNotFound, executor.execute(&invalid));

    var limited = try Plan.init(std.testing.allocator, "limited");
    defer limited.deinit();
    try limited.addStep("one", null, null);
    var strict = executor;
    strict.step_limit = 0;
    try std.testing.expectError(error.ExecutionLimitExceeded, strict.execute(&limited));
}

test "executor resume replays completed steps without repeating side effects" {
    var echo = EchoTool{};
    var tools = ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    try tools.register(.{
        .name = "echo",
        .description = "Echo",
        .context = &echo,
        .executeFn = EchoTool.execute,
    });

    var plan = try Plan.init(std.testing.allocator, "resume");
    defer plan.deinit();
    try plan.addStep("echo first", "echo", "first");
    try plan.addStep("echo second", "echo", "second");

    // A record whose first step already completed (seeded from a previous
    // failed run) must make the executor skip it.
    var record = task.TaskRecord.begin(std.testing.allocator, 0, 0);
    defer record.deinit();
    try record.start();
    try record.seedStep(1, "echo");

    const executor = Executor.init(std.testing.allocator, &tools);
    var result = try executor.executeResumable(&plan, record.recorder());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), echo.calls);
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.steps.items[0].output, "replayed") != null);
    try std.testing.expectEqualStrings("second", result.steps.items[1].output);
    try std.testing.expectEqual(@as(usize, 1), record.replayedStepCount());
    try std.testing.expectEqual(@as(usize, 1), record.completedStepCount());
}

test "executor records failed steps as not resumable" {
    const FailingTool = struct {
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]u8 {
            return error.ToolFailure;
        }
    };
    var marker: u8 = 0;
    var tools = ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    try tools.register(.{
        .name = "broken",
        .description = "fails",
        .context = &marker,
        .executeFn = FailingTool.execute,
    });

    var plan = try Plan.init(std.testing.allocator, "failing");
    defer plan.deinit();
    try plan.addStep("broken step", "broken", "input");

    var record = task.TaskRecord.begin(std.testing.allocator, 0, 0);
    defer record.deinit();
    try record.start();

    const executor = Executor.init(std.testing.allocator, &tools);
    try std.testing.expectError(error.ToolFailure, executor.executeResumable(&plan, record.recorder()));

    try std.testing.expectEqual(@as(usize, 1), record.failedStepCount());
    try std.testing.expectEqual(@as(usize, 0), record.completedStepCount());
    try std.testing.expect(!record.wasStepCompleted(1, "broken"));
}
