const std = @import("std");

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    tool_name: ?[]const u8,
};

pub const Registry = struct {
    skills: []const Skill,

    pub fn default() Registry {
        return .{ .skills = &.{
            .{ .name = "arithmetic", .description = "Solve arithmetic with calculator", .tool_name = "calculator" },
            .{ .name = "filesystem", .description = "Read or write workspace files", .tool_name = "filesystem" },
            .{ .name = "reasoning", .description = "Reason with provider", .tool_name = null },
        } };
    }

    pub fn select(self: *const Registry, task: []const u8) Skill {
        if (containsIgnoreCase(task, "calculate") or containsIgnoreCase(task, "hitung")) return self.skills[0];
        if (containsIgnoreCase(task, "file") or containsIgnoreCase(task, "berkas")) return self.skills[1];
        return self.skills[2];
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}

test "skills select static task guidance without code execution" {
    const skills = Registry.default();
    try std.testing.expectEqualStrings("arithmetic", skills.select("calculate 2 + 2").name);
    try std.testing.expectEqualStrings("filesystem", skills.select("read file a.txt").name);
    try std.testing.expectEqualStrings("reasoning", skills.select("explain ownership").name);
}
