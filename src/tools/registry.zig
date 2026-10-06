const std = @import("std");
const Tool = @import("tool.zig").Tool;

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayList(Tool) = .empty,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit(self.allocator);
        // Leave the registry usable and safe: later code (e.g. MCP server
        // teardown) may still try to disable tools by name.
        self.tools = .empty;
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        if (tool.name.len == 0) return error.InvalidTool;
        if (self.find(tool.name) != null) return error.DuplicateTool;
        try self.tools.append(self.allocator, tool);
    }

    pub fn find(self: *const ToolRegistry, name: []const u8) ?Tool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    /// Enable or disable a registered tool by name. Returns false when the
    /// name is unknown; the previous state is otherwise replaced.
    pub fn setEnabled(self: *ToolRegistry, name: []const u8, enabled: bool) bool {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.name, name)) {
                tool.enabled = enabled;
                return true;
            }
        }
        return false;
    }

    pub fn isEnabled(self: *const ToolRegistry, name: []const u8) ?bool {
        const tool = self.find(name) orelse return null;
        return tool.enabled;
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.tools.items.len;
    }

    pub fn execute(
        self: *const ToolRegistry,
        allocator: std.mem.Allocator,
        name: []const u8,
        input: []const u8,
    ) ![]u8 {
        const tool = self.find(name) orelse return error.ToolNotFound;
        if (!tool.enabled) return error.ToolDisabled;
        return tool.execute(allocator, input);
    }
};

test "registry registers finds and executes tools" {
    const Calculator = @import("calculator.zig").Calculator;
    var calculator = Calculator{};
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(calculator.tool());
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.find("calculator") != null);

    const result = try registry.execute(std.testing.allocator, "calculator", "7 * 8");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("56", result);
}

test "registry rejects duplicates and missing tools" {
    const SystemTool = @import("system.zig").SystemTool;
    var system = SystemTool{};
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(system.tool());
    try std.testing.expectError(error.DuplicateTool, registry.register(system.tool()));
    try std.testing.expectError(error.ToolNotFound, registry.execute(std.testing.allocator, "missing", ""));
}

test "registry honors disabled tools" {
    const Calculator = @import("calculator.zig").Calculator;
    var calculator = Calculator{};
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(calculator.tool());

    try std.testing.expectEqual(@as(?bool, true), registry.isEnabled("calculator"));
    try testing_expect_equal_strings_static("56", try registry.execute(std.testing.allocator, "calculator", "7 * 8"));

    try std.testing.expect(registry.setEnabled("calculator", false));
    try std.testing.expect(!registry.setEnabled("missing", false));
    try std.testing.expectEqual(@as(?bool, false), registry.isEnabled("calculator"));
    try std.testing.expectError(error.ToolDisabled, registry.execute(std.testing.allocator, "calculator", "1 + 1"));

    try std.testing.expect(registry.setEnabled("calculator", true));
    const again = try registry.execute(std.testing.allocator, "calculator", "2 + 2");
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings("4", again);
}

fn testing_expect_equal_strings_static(expected: []const u8, actual: []u8) !void {
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
