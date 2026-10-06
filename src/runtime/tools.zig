//! Sandbox tools exposed to the agent through the existing tool registry.
//!
//! Every tool takes a JSON object input and returns structured JSON, so the
//! model consumes real results and the dashboard can render them. Tools map
//! 1:1 onto sandbox operations and carry the registry's permission/risk
//! metadata; `process.exec` is gated by the sandbox execution allowlist on
//! top of the registry grant.

const std = @import("std");
const Tool = @import("../tools/tool.zig").Tool;
const Permission = @import("../tools/tool.zig").Permission;
const Risk = @import("../tools/tool.zig").Risk;
const Param = @import("../tools/tool.zig").Param;
const sandbox_mod = @import("sandbox.zig");
const fsops_mod = @import("fsops.zig");
const process_mod = @import("process.zig");
const archives_mod = @import("archives.zig");
const media_mod = @import("media.zig");

pub const ToolId = enum(u8) {
    fs_list,
    fs_read,
    fs_write,
    fs_edit,
    fs_stat,
    fs_mkdir,
    fs_delete,
    fs_move,
    fs_copy,
    fs_search,
    process_exec,
    archive_list,
    archive_extract,
    archive_create,
    media_inspect,
    media_thumbnail,
};

const Adapter = struct {
    tools: *SandboxTools,
    id: ToolId,
};

pub const SandboxTools = struct {
    allocator: std.mem.Allocator,
    sb: *const sandbox_mod.Sandbox,
    fs: fsops_mod.FsOps,
    runner: process_mod.ProcessRunner,
    archives: archives_mod.Archives,
    media: media_mod.Media,
    adapters: [16]Adapter = undefined,
    adapter_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, sb: *const sandbox_mod.Sandbox, parent_env: ?*const std.process.Environ.Map) SandboxTools {
        return .{
            .allocator = allocator,
            .sb = sb,
            .fs = fsops_mod.FsOps.init(sb),
            .runner = process_mod.ProcessRunner.init(sb, parent_env),
            .archives = archives_mod.Archives.init(sb),
            .media = media_mod.Media.init(sb),
        };
    }

    /// Build one registered tool. Adapters live in `self`, so `self` must be
    /// stable before this is called (same rule as the sandbox itself).
    pub fn tool(self: *SandboxTools, id: ToolId) Tool {
        self.adapters[self.adapter_count] = .{ .tools = self, .id = id };
        const adapter = &self.adapters[self.adapter_count];
        self.adapter_count += 1;
        return .{
            .name = nameOf(id),
            .description = descriptionOf(id),
            .context = adapter,
            .executeFn = executeErased,
            .permission = permissionOf(id),
            .risk = riskOf(id),
            .parameters = parametersOf(id),
        };
    }

    pub fn execute(self: *SandboxTools, allocator: std.mem.Allocator, id: ToolId, input: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(Args, allocator, input, .{}) catch
            return error.InvalidInput;
        defer parsed.deinit();
        switch (id) {
            .fs_list, .fs_read, .fs_stat, .fs_write, .fs_edit, .fs_mkdir, .fs_delete, .fs_move, .fs_copy, .fs_search => {
                return self.executeFs(allocator, id, parsed.value);
            },
            .process_exec => {
                if (parsed.value.command) |command| {
                    return self.runner.exec(allocator, .{
                        .command = command,
                        .args = parsed.value.args orelse &.{},
                        .cwd = parsed.value.cwd orelse ".",
                        .stdin = parsed.value.stdin orelse "",
                        .timeout_ms = parsed.value.timeout_ms,
                    });
                }
                return self.runner.execJson(allocator, input);
            },
            .archive_list, .archive_extract, .archive_create, .media_inspect, .media_thumbnail => {
                return self.executeArchiveMedia(allocator, id, parsed.value);
            },
        }
    }

    fn executeFs(self: *SandboxTools, allocator: std.mem.Allocator, id: ToolId, v: Args) ![]u8 {
        const path = v.path orelse return error.InvalidInput;
        switch (id) {
            .fs_list => return self.fs.listJson(allocator, path),
            .fs_read => return self.fs.readJson(allocator, path),
            .fs_stat => return self.fs.statJson(allocator, path),
            .fs_write => {
                const content = v.content orelse return error.InvalidInput;
                const written = try self.fs.write(path, content);
                return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"bytes\":{d}}}", .{ path, written });
            },
            .fs_edit => {
                const old = v.old orelse return error.InvalidInput;
                const count = try self.fs.edit(allocator, path, old, v.new orelse "");
                return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"replacements\":{d}}}", .{ path, count });
            },
            .fs_mkdir => {
                try self.fs.mkdir(path);
                return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"created\":true}}", .{path});
            },
            .fs_delete => {
                try self.fs.delete(path, v.recursive);
                return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"deleted\":true}}", .{path});
            },
            .fs_move => {
                const to = v.to orelse return error.InvalidInput;
                try self.fs.move(path, to);
                return std.fmt.allocPrint(allocator, "{{\"from\":\"{s}\",\"to\":\"{s}\",\"moved\":true}}", .{ path, to });
            },
            .fs_copy => {
                const to = v.to orelse return error.InvalidInput;
                try self.fs.copy(path, to);
                return std.fmt.allocPrint(allocator, "{{\"from\":\"{s}\",\"to\":\"{s}\",\"copied\":true}}", .{ path, to });
            },
            .fs_search => {
                const query = v.query orelse return error.InvalidInput;
                return self.fs.searchJson(allocator, v.base orelse ".", query);
            },
            else => unreachable,
        }
    }

    fn executeErased(context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
        const adapter: *Adapter = @ptrCast(@alignCast(context));
        return adapter.tools.execute(allocator, adapter.id, input);
    }

    fn executeArchiveMedia(self: *SandboxTools, allocator: std.mem.Allocator, id: ToolId, v: Args) ![]u8 {
        switch (id) {
            .archive_list => {
                const path = v.path orelse return error.InvalidInput;
                return switch (try self.archives.detectKindFor(path)) {
                    .zip => self.archives.zipListJson(allocator, path),
                    .tar, .tar_gz => self.archives.tarListJson(allocator, path),
                };
            },
            .archive_extract => {
                const path = v.path orelse return error.InvalidInput;
                const dest = v.dest orelse return error.InvalidInput;
                return switch (try self.archives.detectKindFor(path)) {
                    .zip => renderSummary(allocator, try self.archives.zipExtract(allocator, path, dest)),
                    .tar, .tar_gz => renderSummary(allocator, try self.archives.tarExtract(allocator, path, dest)),
                };
            },
            .archive_create => {
                const dest = v.dest orelse return error.InvalidInput;
                const sources = v.sources orelse return error.InvalidInput;
                const count = try self.archives.zipCreate(allocator, dest, sources);
                return std.fmt.allocPrint(allocator, "{{\"dest\":\"{s}\",\"entries\":{d}}}", .{ dest, count });
            },
            .media_inspect => {
                const path = v.path orelse return error.InvalidInput;
                return self.media.inspectJson(allocator, path);
            },
            .media_thumbnail => {
                const path = v.path orelse return error.InvalidInput;
                return self.media.unsupportedJson(allocator, path, v.operation orelse "media.thumbnail");
            },
            else => unreachable,
        }
    }
};

/// JSON arguments accepted by every sandbox tool (unused fields are ignored).
pub const Args = struct {
    path: ?[]const u8 = null,
    to: ?[]const u8 = null,
    dest: ?[]const u8 = null,
    content: ?[]const u8 = null,
    old: ?[]const u8 = null,
    new: ?[]const u8 = null,
    query: ?[]const u8 = null,
    base: ?[]const u8 = null,
    recursive: bool = false,
    sources: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    operation: ?[]const u8 = null,
};

fn renderSummary(allocator: std.mem.Allocator, s: archives_mod.Summary) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"extracted\":{d},\"directories\":{d},\"skipped\":{d},\"bytes\":{d}}}",
        .{ s.extracted, s.directories, s.skipped, s.bytes },
    );
}

pub fn nameOf(id: ToolId) []const u8 {
    return switch (id) {
        .fs_list => "filesystem.list",
        .fs_read => "filesystem.read",
        .fs_write => "filesystem.write",
        .fs_edit => "filesystem.edit",
        .fs_stat => "filesystem.stat",
        .fs_mkdir => "filesystem.mkdir",
        .fs_delete => "filesystem.delete",
        .fs_move => "filesystem.move",
        .fs_copy => "filesystem.copy",
        .fs_search => "filesystem.search",
        .process_exec => "process.exec",
        .archive_list => "archive.list",
        .archive_extract => "archive.extract",
        .archive_create => "archive.create",
        .media_inspect => "media.inspect",
        .media_thumbnail => "media.thumbnail",
    };
}

pub fn descriptionOf(id: ToolId) []const u8 {
    return switch (id) {
        .fs_list => "List a sandbox directory (JSON entries)",
        .fs_read => "Read a sandbox file with binary detection and limits",
        .fs_write => "Write a sandbox file (creates parent directories)",
        .fs_edit => "Replace exact text inside a sandbox file",
        .fs_stat => "Stat a sandbox path",
        .fs_mkdir => "Create a directory chain inside the sandbox",
        .fs_delete => "Delete a sandbox file or directory (recursive flag)",
        .fs_move => "Move/rename inside the sandbox",
        .fs_copy => "Copy a file inside the sandbox",
        .fs_search => "Bounded recursive name search under a sandbox path",
        .process_exec => "Run an allowlisted command in the sandbox (no shell)",
        .archive_list => "List ZIP/TAR/TGZ archive entries",
        .archive_extract => "Safely extract an archive into the sandbox",
        .archive_create => "Create a stored ZIP from sandbox files",
        .media_inspect => "Inspect sandbox image/video metadata",
        .media_thumbnail => "Thumbnail generation (currently unsupported)",
    };
}

pub fn permissionOf(id: ToolId) Permission {
    return switch (id) {
        .fs_list, .fs_read, .fs_stat, .fs_search, .archive_list, .media_inspect, .media_thumbnail => .standard,
        .fs_write, .fs_edit, .fs_mkdir, .fs_move, .fs_copy, .fs_delete, .archive_extract, .archive_create, .process_exec => .elevated,
    };
}

pub fn riskOf(id: ToolId) Risk {
    return switch (id) {
        .fs_list, .fs_read, .fs_stat, .fs_search, .archive_list, .media_inspect, .media_thumbnail => .low,
        .fs_write, .fs_edit, .fs_mkdir, .fs_move, .fs_copy, .archive_create, .fs_delete, .archive_extract => .medium,
        .process_exec => .high,
    };
}

pub fn parametersOf(id: ToolId) []const Param {
    return switch (id) {
        .fs_list, .fs_read, .fs_stat, .fs_mkdir, .media_inspect, .media_thumbnail, .archive_list => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"...\"}" },
        },
        .fs_write => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"...\",\"content\":\"...\"}" },
        },
        .fs_edit => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"...\",\"old\":\"...\",\"new\":\"...\"}" },
        },
        .fs_delete => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"...\",\"recursive\":false}" },
        },
        .fs_move, .fs_copy => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"...\",\"to\":\"...\"}" },
        },
        .fs_search => &.{
            Param{ .name = "args", .description = "JSON object: {\"query\":\"...\",\"base\":\".\"}" },
        },
        .process_exec => &.{
            Param{ .name = "args", .description = "JSON object: {\"command\":\"zig\",\"args\":[\"build\",\"test\"],\"cwd\":\".\",\"timeout_ms\":60000}" },
        },
        .archive_extract => &.{
            Param{ .name = "args", .description = "JSON object: {\"path\":\"a.zip\",\"dest\":\"dir\"}" },
        },
        .archive_create => &.{
            Param{ .name = "args", .description = "JSON object: {\"dest\":\"out.zip\",\"sources\":[\"a.txt\"]}" },
        },
    };
}

test "sandbox tools register with metadata and execute real operations" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-sbtools";
    cwd.deleteTree(io, root_name) catch {};
    var sandbox = try sandbox_mod.Sandbox.init(io, std.testing.allocator, cwd, root_name, .{
        .read = true,
        .write = true,
        .execute = false,
    }, .{});
    defer {
        sandbox.deinit();
        cwd.deleteTree(io, root_name) catch {};
    }
    var tools = SandboxTools.init(std.testing.allocator, &sandbox, null);

    var registry = @import("../tools/registry.zig").ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    inline for (std.meta.fields(ToolId)) |field| {
        const id: ToolId = @enumFromInt(field.value);
        try registry.register(tools.tool(id));
    }
    try std.testing.expectEqual(@as(usize, 16), registry.count());
    // Risk metadata surfaces in the manifest for the dashboard.
    try std.testing.expectEqual(Risk.high, registry.find("process.exec").?.risk);
    try std.testing.expectEqual(Risk.low, registry.find("filesystem.read").?.risk);

    // A real write -> list -> read cycle through the registry.
    const write_result = try registry.execute(std.testing.allocator, "filesystem.write", "{\"path\":\"docs/note.txt\",\"content\":\"hello sandbox\"}");
    defer std.testing.allocator.free(write_result);
    try std.testing.expect(std.mem.indexOf(u8, write_result, "\"bytes\":13") != null);

    const list_result = try registry.execute(std.testing.allocator, "filesystem.list", "{\"path\":\"docs\"}");
    defer std.testing.allocator.free(list_result);
    try std.testing.expect(std.mem.indexOf(u8, list_result, "\"name\":\"note.txt\"") != null);

    const read_result = try registry.execute(std.testing.allocator, "filesystem.read", "{\"path\":\"docs/note.txt\"}");
    defer std.testing.allocator.free(read_result);
    try std.testing.expect(std.mem.indexOf(u8, read_result, "hello sandbox") != null);

    // Process execution is denied while the sandbox grant is off.
    try std.testing.expectError(
        error.ExecuteDenied,
        registry.execute(std.testing.allocator, "process.exec", "{\"command\":\"cmd\"}"),
    );

    // Unsupported media operations answer honestly.
    const thumb = try registry.execute(std.testing.allocator, "media.thumbnail", "{\"path\":\"docs/note.txt\"}");
    defer std.testing.allocator.free(thumb);
    try std.testing.expect(std.mem.indexOf(u8, thumb, "\"supported\":false") != null);
}
