const std = @import("std");
const ToolRegistry = @import("tools/registry.zig").ToolRegistry;

pub const max_task_bytes: usize = 4096;
pub const max_step_bytes: usize = 4096;
pub const max_steps: usize = 16;

pub const PlanStep = struct {
    id: usize,
    description: []u8,
    tool_name: ?[]u8,
    tool_input: ?[]u8,

    pub fn deinit(self: *PlanStep, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        if (self.tool_name) |value| allocator.free(value);
        if (self.tool_input) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    task: []u8,
    steps: std.ArrayList(PlanStep) = .empty,

    pub fn init(allocator: std.mem.Allocator, task: []const u8) !Plan {
        const normalized = std.mem.trim(u8, task, " \t\r\n");
        if (normalized.len == 0) return error.InvalidTask;
        if (normalized.len > max_task_bytes) return error.TaskTooLong;
        return .{
            .allocator = allocator,
            .task = try allocator.dupe(u8, normalized),
        };
    }

    pub fn deinit(self: *Plan) void {
        for (self.steps.items) |*step| step.deinit(self.allocator);
        self.steps.deinit(self.allocator);
        self.allocator.free(self.task);
        self.* = undefined;
    }

    pub fn addStep(
        self: *Plan,
        description: []const u8,
        tool_name: ?[]const u8,
        tool_input: ?[]const u8,
    ) !void {
        const normalized_description = std.mem.trim(u8, description, " \t\r\n");
        if (normalized_description.len == 0) return error.InvalidStep;
        if (normalized_description.len > max_step_bytes) return error.StepTooLong;
        if ((tool_name == null) != (tool_input == null)) return error.InvalidStep;
        if (self.steps.items.len >= max_steps) return error.PlanLimitExceeded;

        const owned_description = try self.allocator.dupe(u8, normalized_description);
        errdefer self.allocator.free(owned_description);
        const owned_tool_name = if (tool_name) |name| blk: {
            const normalized = std.mem.trim(u8, name, " \t\r\n");
            if (normalized.len == 0 or normalized.len > max_step_bytes) return error.InvalidStep;
            break :blk try self.allocator.dupe(u8, normalized);
        } else null;
        errdefer if (owned_tool_name) |value| self.allocator.free(value);
        const owned_tool_input = if (tool_input) |input| blk: {
            if (input.len > max_step_bytes) return error.StepTooLong;
            break :blk try self.allocator.dupe(u8, input);
        } else null;
        errdefer if (owned_tool_input) |value| self.allocator.free(value);

        try self.steps.append(self.allocator, .{
            .id = self.steps.items.len + 1,
            .description = owned_description,
            .tool_name = owned_tool_name,
            .tool_input = owned_tool_input,
        });
    }

    pub fn stepCount(self: *const Plan) usize {
        return self.steps.items.len;
    }

    pub fn getStep(self: *const Plan, index: usize) ?*const PlanStep {
        if (index >= self.steps.items.len) return null;
        return &self.steps.items[index];
    }
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    tools: *const ToolRegistry,

    pub fn init(allocator: std.mem.Allocator, tools: *const ToolRegistry) Planner {
        return .{ .allocator = allocator, .tools = tools };
    }

    pub fn deinit(_: *Planner) void {}

    pub fn plan(self: *const Planner, task: []const u8) !Plan {
        var result = try Plan.init(self.allocator, task);
        errdefer result.deinit();

        if (self.tools.find("calculator") != null) {
            if (arithmeticExpression(result.task)) |expression| {
                try result.addStep("Calculate arithmetic expression", "calculator", expression);
                return result;
            }
        }
        if (self.tools.find("filesystem") != null and isFilesystemTask(result.task)) {
            try result.addStep("Perform requested file operation", "filesystem", result.task);
            return result;
        }

        try result.addStep("Reason about the task", null, null);
        return result;
    }
};

fn arithmeticExpression(task: []const u8) ?[]const u8 {
    var start: ?usize = null;
    for (task, 0..) |char, index| {
        if (std.ascii.isDigit(char)) {
            start = index;
            break;
        }
    }
    const begin = start orelse return null;
    var end = begin;
    var has_operator = false;
    while (end < task.len) : (end += 1) {
        const char = task[end];
        if (std.ascii.isDigit(char) or std.ascii.isWhitespace(char) or char == '.') continue;
        if (char == '+' or char == '-' or char == '*' or char == '/' or char == '(' or char == ')') {
            if (char == '+' or char == '-' or char == '*' or char == '/') has_operator = true;
            continue;
        }
        break;
    }
    if (!has_operator) return null;
    const expression = std.mem.trim(u8, task[begin..end], " \t\r\n");
    return if (expression.len == 0) null else expression;
}

fn isFilesystemTask(task: []const u8) bool {
    const keywords = [_][]const u8{ "file", "berkas", "read", "write", "baca", "tulis" };
    for (keywords) |keyword| {
        if (containsIgnoreCase(task, keyword)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

const TestTool = struct {
    called: bool = false,

    fn execute(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
        const self: *TestTool = @ptrCast(@alignCast(context));
        self.called = true;
        return allocator.dupe(u8, "unexpected");
    }
};

fn registerTestTool(registry: *ToolRegistry, state: *TestTool, name: []const u8) !void {
    try registry.register(.{
        .name = name,
        .description = "Planner test tool",
        .context = state,
        .executeFn = TestTool.execute,
    });
}

test "planner creates owned calculator plan without executing tool" {
    var state = TestTool{};
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerTestTool(&registry, &state, "calculator");
    var planner = Planner.init(std.testing.allocator, &registry);
    defer planner.deinit();

    var task = [_]u8{ 'H', 'i', 't', 'u', 'n', 'g', ' ', '1', '2', '3', ' ', '*', ' ', '4', '5', '6' };
    var plan_result = try planner.plan(&task);
    defer plan_result.deinit();
    @memset(&task, 'x');

    try std.testing.expectEqualStrings("Hitung 123 * 456", plan_result.task);
    try std.testing.expectEqual(@as(usize, 1), plan_result.stepCount());
    const step = plan_result.getStep(0).?;
    try std.testing.expectEqual(@as(usize, 1), step.id);
    try std.testing.expectEqualStrings("calculator", step.tool_name.?);
    try std.testing.expectEqualStrings("123 * 456", step.tool_input.?);
    try std.testing.expect(!state.called);
}

test "planner creates filesystem plan when tool is available" {
    var state = TestTool{};
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerTestTool(&registry, &state, "filesystem");
    var planner = Planner.init(std.testing.allocator, &registry);
    defer planner.deinit();

    var plan_result = try planner.plan("Read file notes.txt");
    defer plan_result.deinit();
    const step = plan_result.getStep(0).?;
    try std.testing.expectEqualStrings("filesystem", step.tool_name.?);
    try std.testing.expectEqualStrings("Read file notes.txt", step.tool_input.?);
    try std.testing.expect(!state.called);
}

test "planner falls back to one reasoning step" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var planner = Planner.init(std.testing.allocator, &registry);
    defer planner.deinit();

    var plan_result = try planner.plan("Explain ownership");
    defer plan_result.deinit();
    const step = plan_result.getStep(0).?;
    try std.testing.expectEqual(@as(usize, 1), plan_result.stepCount());
    try std.testing.expect(step.tool_name == null);
    try std.testing.expect(step.tool_input == null);
    try std.testing.expect(plan_result.getStep(1) == null);
}

test "plan validates task steps and limit" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var planner = Planner.init(std.testing.allocator, &registry);
    defer planner.deinit();
    try std.testing.expectError(error.InvalidTask, planner.plan(" \r\n"));

    var plan_result = try Plan.init(std.testing.allocator, "bounded task");
    defer plan_result.deinit();
    try std.testing.expectError(error.InvalidStep, plan_result.addStep("", null, null));
    try std.testing.expectError(error.InvalidStep, plan_result.addStep("step", "calculator", null));
    for (0..max_steps) |_| try plan_result.addStep("step", null, null);
    try std.testing.expectError(error.PlanLimitExceeded, plan_result.addStep("extra", null, null));
}

test "planner does not attach unavailable recognized tool" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var planner = Planner.init(std.testing.allocator, &registry);
    defer planner.deinit();

    var plan_result = try planner.plan("Calculate 7 * 8");
    defer plan_result.deinit();
    try std.testing.expect(plan_result.getStep(0).?.tool_name == null);
}
