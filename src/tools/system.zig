const std = @import("std");
const builtin = @import("builtin");
const Tool = @import("tool.zig").Tool;

pub const SystemTool = struct {
    pub const pico_claw_version = "0.1.0";

    pub fn tool(self: *SystemTool) Tool {
        return .{
            .name = "system",
            .description = "Report safe Pico Claw runtime information",
            .context = self,
            .executeFn = executeErased,
            .permission = .standard,
            .risk = .low,
            .parameters = &.{
                .{ .name = "subcommand", .description = "info (or empty)", .required = false },
            },
        };
    }

    pub fn execute(
        _: *SystemTool,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        if (input.len != 0 and !std.mem.eql(u8, input, "info")) return error.InvalidCommand;
        return std.fmt.allocPrint(
            allocator,
            "platform={s}\narch={s}\npico_claw={s}\nzig={s}",
            .{
                @tagName(builtin.target.os.tag),
                @tagName(builtin.target.cpu.arch),
                pico_claw_version,
                builtin.zig_version_string,
            },
        );
    }

    fn executeErased(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        const self: *SystemTool = @ptrCast(@alignCast(context));
        return self.execute(allocator, input);
    }
};

test "system tool reports safe runtime information" {
    var system = SystemTool{};
    const result = try system.execute(std.testing.allocator, "info");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "pico_claw=0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zig=") != null);
}

test "system tool rejects arbitrary commands" {
    var system = SystemTool{};
    try std.testing.expectError(error.InvalidCommand, system.execute(std.testing.allocator, "exec whoami"));
}
