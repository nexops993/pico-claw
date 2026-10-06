const std = @import("std");
const Tool = @import("tool.zig").Tool;

pub const Filesystem = struct {
    io: std.Io,
    base_dir: std.Io.Dir,
    max_read_bytes: usize = 1024 * 1024,

    pub fn init(io: std.Io, base_dir: std.Io.Dir) Filesystem {
        return .{ .io = io, .base_dir = base_dir };
    }

    pub fn tool(self: *Filesystem) Tool {
        return .{
            .name = "filesystem",
            .description = "Read or write files inside the configured workspace",
            .context = self,
            .executeFn = executeErased,
            .permission = .elevated,
            .risk = .medium,
            .parameters = &.{
                .{ .name = "operation", .description = "read or write", .required = true },
                .{ .name = "path", .description = "Relative path inside the workspace", .required = true },
                .{ .name = "content", .description = "File body for write (first line after the path)", .required = false },
            },
        };
    }

    pub fn execute(
        self: *Filesystem,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        if (std.mem.startsWith(u8, input, "read ")) {
            return self.read(allocator, std.mem.trim(u8, input[5..], " \t\r\n"));
        }
        if (std.mem.startsWith(u8, input, "write ")) {
            const payload = input[6..];
            const separator = std.mem.indexOfScalar(u8, payload, '\n') orelse return error.InvalidCommand;
            const path = std.mem.trim(u8, payload[0..separator], " \t\r");
            try self.write(path, payload[separator + 1 ..]);
            return allocator.dupe(u8, "ok");
        }
        return error.InvalidCommand;
    }

    pub fn read(self: *Filesystem, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try validatePath(path);
        return self.base_dir.readFileAlloc(self.io, path, allocator, .limited(self.max_read_bytes));
    }

    pub fn write(self: *Filesystem, path: []const u8, content: []const u8) !void {
        try validatePath(path);
        try self.base_dir.writeFile(self.io, .{
            .sub_path = path,
            .data = content,
            .flags = .{ .resolve_beneath = true },
        });
    }

    fn executeErased(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        const self: *Filesystem = @ptrCast(@alignCast(context));
        return self.execute(allocator, input);
    }

    fn validatePath(path: []const u8) !void {
        if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidPath;
        var components = std.mem.tokenizeAny(u8, path, "/\\");
        var count: usize = 0;
        while (components.next()) |component| {
            count += 1;
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.PathTraversal;
        }
        if (count == 0 or path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    }
};

test "filesystem writes and reads inside workspace" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache-pico-tools-test";
    cwd.createDirPath(io, test_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try cwd.openDir(io, test_dir, .{});
    defer dir.close(io);
    defer cwd.deleteTree(io, test_dir) catch {};

    var filesystem = Filesystem.init(io, dir);
    try filesystem.write("sample.txt", "safe content");
    const content = try filesystem.read(std.testing.allocator, "sample.txt");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("safe content", content);
}

test "filesystem execute supports read and write" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache-pico-tools-execute-test";
    cwd.createDirPath(io, test_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try cwd.openDir(io, test_dir, .{});
    defer dir.close(io);
    defer cwd.deleteTree(io, test_dir) catch {};

    var filesystem = Filesystem.init(io, dir);
    const write_result = try filesystem.execute(std.testing.allocator, "write note.txt\nhello");
    defer std.testing.allocator.free(write_result);
    try std.testing.expectEqualStrings("ok", write_result);
    const read_result = try filesystem.execute(std.testing.allocator, "read note.txt");
    defer std.testing.allocator.free(read_result);
    try std.testing.expectEqualStrings("hello", read_result);
}

test "filesystem rejects invalid and traversal paths" {
    var filesystem = Filesystem.init(std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectError(error.InvalidPath, filesystem.read(std.testing.allocator, ""));
    try std.testing.expectError(error.PathTraversal, filesystem.read(std.testing.allocator, "../secret.txt"));
    try std.testing.expectError(error.PathTraversal, filesystem.write("folder\\..\\secret.txt", "blocked"));
}
