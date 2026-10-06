const std = @import("std");

/// Authorization tier a tool requires. Every tool needs at least `.standard`
/// (registered by the composition root); `.network` tools reach external
/// services and `.elevated` tools change durable state outside the session.
pub const Permission = enum {
    standard,
    network,
    elevated,

    pub fn name(self: Permission) []const u8 {
        return switch (self) {
            .standard => "standard",
            .network => "network",
            .elevated => "elevated",
        };
    }
};

/// Static blast-radius classification used by the tool manifest UI. It is
/// advisory metadata, not an enforcement mechanism.
pub const Risk = enum {
    low,
    medium,
    high,

    pub fn name(self: Risk) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

/// One named parameter of a tool, purely descriptive (tools take a single
/// string input; this metadata documents its expected shape for the manifest).
pub const Param = struct {
    name: []const u8,
    description: []const u8 = "",
    required: bool = true,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    context: *anyopaque,
    executeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
    /// Disabled tools stay registered (visible in the manifest) but refuse
    /// execution; the agent is never told they are available.
    enabled: bool = true,
    permission: Permission = .standard,
    risk: Risk = .low,
    parameters: []const Param = &.{},

    pub fn execute(
        self: Tool,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        if (!self.enabled) return error.ToolDisabled;
        return self.executeFn(self.context, allocator, input);
    }
};

test "tool delegates execution" {
    const Echo = struct {
        fn execute(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            input: []const u8,
        ) ![]u8 {
            return allocator.dupe(u8, input);
        }
    };

    var context: u8 = 0;
    const tool = Tool{
        .name = "echo",
        .description = "Echo input",
        .context = &context,
        .executeFn = Echo.execute,
    };

    const result = try tool.execute(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "disabled tool refuses execution without running the handler" {
    const Boom = struct {
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]u8 {
            unreachable;
        }
    };

    var context: u8 = 0;
    const tool = Tool{
        .name = "off",
        .description = "Disabled tool",
        .context = &context,
        .executeFn = Boom.execute,
        .enabled = false,
    };

    try std.testing.expectError(error.ToolDisabled, tool.execute(std.testing.allocator, "x"));
}
