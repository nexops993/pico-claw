const std = @import("std");

const Config = @import("../config.zig").Config;
const Tool = @import("../tools/tool.zig").Tool;
const ToolRegistry = @import("../tools/registry.zig").ToolRegistry;

pub const Agent = struct {
    config: Config,
    tools: ToolRegistry,

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) Agent {
        return .{
            .config = config,
            .tools = ToolRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.tools.deinit();
    }

    pub fn registerTool(self: *Agent, tool: Tool) !void {
        try self.tools.register(tool);
    }

    pub fn toolCount(self: *const Agent) usize {
        return self.tools.count();
    }

    pub fn executeTool(
        self: *const Agent,
        allocator: std.mem.Allocator,
        name: []const u8,
        input: []const u8,
    ) ![]u8 {
        return self.tools.execute(allocator, name, input);
    }

    pub fn greet(
        self: *const Agent,
    ) void {
        std.debug.print(
            "Agent: {s}\n",
            .{self.config.agent_name},
        );

        std.debug.print(
            "Model: {s}\n",
            .{self.config.model},
        );
    }
};
