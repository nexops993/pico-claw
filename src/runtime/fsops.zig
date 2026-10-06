//! Structured filesystem operations backed by the sandbox.
//!
//! Every operation validates the agent-supplied path against the sandbox
//! policy, opens directories component-by-component without following
//! symlinks, and honors the sandbox limits. Results are structured JSON so
//! the agent (and the dashboard) can consume them directly.

const std = @import("std");
const sandbox_mod = @import("sandbox.zig");

pub const Sandbox = sandbox_mod.Sandbox;
pub const OpenedPath = sandbox_mod.OpenedPath;

pub const OpError = sandbox_mod.OpenPathError || error{
    /// Payload or file exceeds the configured sandbox limit.
    TooLarge,
    /// The requested content is binary and was not returned as text.
    BinaryContent,
    /// The edit pattern did not match anything.
    NoMatch,
    /// Non-recursive delete of a non-empty directory.
    NotEmpty,
    /// The path names a directory where a file was required.
    IsDir,
    /// The sandbox does not support this operation.
    Unsupported,
    ReadFailed,
    WriteFailed,
};

/// Filesystem facade over one sandbox.
pub const FsOps = struct {
    sb: *const Sandbox,

    pub fn init(sb: *const Sandbox) FsOps {
        return .{ .sb = sb };
    }

    pub fn parentOf(self: *const FsOps, opened: *const OpenedPath) std.Io.Dir {
        if (opened.parent_dirs.len == 0) return self.sb.root;
        return opened.parent_dirs[opened.parent_dirs.len - 1];
    }

    /// Structured directory listing:
    /// {"path":"src","entries":[{"name":"main.zig","type":"file","size":1}]}
    pub fn listJson(self: *const FsOps, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try self.sb.checkRead(path);

        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);

        // The listing target is the final path component; open it as a
        // directory without following symlinks.
        var dir: std.Io.Dir = undefined;
        var dir_owned = false;
        const parent = self.parentOf(&opened);
        if (std.mem.eql(u8, opened.basename, ".")) {
            dir = parent;
        } else {
            dir = parent.openDir(self.sb.io, opened.basename, .{
                .access_sub_paths = true,
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| return sandbox_mod.mapOpenError(err);
            dir_owned = true;
        }
        defer if (dir_owned) dir.close(self.sb.io);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(path);
        try stringify.objectField("entries");
        try stringify.beginArray();

        var it = dir.iterate();
        var count: usize = 0;
        var truncated = false;
        while (it.next(self.sb.io) catch |err| return sandbox_mod.mapOpenError(err)) |entry| {
            if (count >= self.sb.limits.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            try stringify.beginObject();
            try stringify.objectField("name");
            try stringify.write(entry.name);
            try stringify.objectField("type");
            try stringify.write(fileKindName(entry.kind));
            if (self.entrySize(dir, entry)) |size| {
                try stringify.objectField("size");
                try stringify.write(size);
            }
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.objectField("truncated");
        try stringify.write(truncated);
        try stringify.endObject();

        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn entrySize(self: *const FsOps, dir: std.Io.Dir, entry: std.Io.Dir.Entry) ?u64 {
        if (entry.kind != .file) return null;
        const stat = dir.statFile(self.sb.io, entry.name, .{ .follow_symlinks = false }) catch return null;
        return stat.size;
    }

    /// {"path":...,"type":"file","size":12,"modified_ns":...}
    pub fn statJson(self: *const FsOps, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try self.sb.checkRead(path);
        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);
        const parent = self.parentOf(&opened);
        const stat = parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(path);
        try stringify.objectField("type");
        try stringify.write(fileKindName(stat.kind));
        try stringify.objectField("size");
        try stringify.write(stat.size);
        try stringify.objectField("modified_ns");
        try stringify.write(stat.mtime.nanoseconds);
        try stringify.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Bounded read with binary detection:
    /// text   -> {"path","size","encoding":"utf-8"|"text","truncated","content"}
    /// binary -> {"path","size","encoding":"binary","truncated","content_base64"}
    pub fn readJson(self: *const FsOps, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try self.sb.checkRead(path);
        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);
        const parent = self.parentOf(&opened);

        const stat = parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        if (stat.kind == .directory) return error.IsDir;
        // Refuse a symlink/junction planted at the target (no-follow stat).
        const target = parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        if (target.kind == .sym_link) return error.SymLinkRefused;

        var file = parent.openFile(self.sb.io, opened.basename, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        defer file.close(self.sb.io);

        const limit = self.sb.limits.max_read_bytes;
        var reader_buf: [8192]u8 = undefined;
        var file_reader = file.readerStreaming(self.sb.io, &reader_buf);
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var truncated = false;
        file_reader.interface.appendRemaining(allocator, &content, .limited(limit)) catch |err| switch (err) {
            error.StreamTooLong => truncated = true,
            else => return sandbox_mod.mapOpenError(err),
        };
        // stat.size > limit implies truncation even when the stream ended
        // exactly at the limit boundary.
        if (!truncated and stat.size > limit) truncated = true;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(path);
        try stringify.objectField("size");
        try stringify.write(stat.size);
        try stringify.objectField("truncated");
        try stringify.write(truncated);
        if (looksBinary(content.items)) {
            try stringify.objectField("encoding");
            try stringify.write("binary");
            try stringify.objectField("content_base64");
            const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(content.items.len));
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, content.items);
            try stringify.write(encoded);
        } else {
            const valid_utf8 = std.unicode.utf8ValidateSlice(content.items);
            try stringify.objectField("encoding");
            try stringify.write(if (valid_utf8) "utf-8" else "text");
            try stringify.objectField("content");
            try stringify.write(content.items);
        }
        try stringify.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Write (create or replace) a file inside the sandbox. Creates parent
    /// directories. Refuses to follow a symlink at the destination. Returns
    /// the number of bytes written.
    pub fn write(self: *const FsOps, path: []const u8, content: []const u8) !usize {
        if (content.len > self.sb.limits.max_write_bytes) return error.TooLarge;
        try self.sb.checkWrite(path);

        var opened = try self.sb.walkToCreate(path);
        defer self.sb.closeOpened(&opened);
        const parent = self.parentOf(&opened);

        // Refuse to write through a symlink/junction planted at the target.
        if (parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .sym_link) return error.SymLinkRefused;
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        }

        var file = parent.createFile(self.sb.io, opened.basename, .{
            .resolve_beneath = true,
        }) catch |err| return sandbox_mod.mapOpenError(err);
        defer file.close(self.sb.io);
        file.writeStreamingAll(self.sb.io, content) catch return error.WriteFailed;
        return content.len;
    }

    /// Read a text file fully (bounded), for edit/search helpers.
    fn readText(self: *const FsOps, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try self.sb.checkRead(path);
        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);
        const parent = self.parentOf(&opened);
        var file = parent.openFile(self.sb.io, opened.basename, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        defer file.close(self.sb.io);

        var reader_buf: [8192]u8 = undefined;
        var file_reader = file.readerStreaming(self.sb.io, &reader_buf);
        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(allocator);
        file_reader.interface.appendRemaining(allocator, &content, .limited(self.sb.limits.max_read_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.TooLarge,
            else => return sandbox_mod.mapOpenError(err),
        };
        return content.toOwnedSlice(allocator);
    }

    /// Replace every occurrence of `old` with `new` in a text file. Returns
    /// the number of replacements (0 replacements is `error.NoMatch`).
    pub fn edit(
        self: *const FsOps,
        allocator: std.mem.Allocator,
        path: []const u8,
        old: []const u8,
        new: []const u8,
    ) !usize {
        if (old.len == 0) return error.InvalidPath;
        try self.sb.checkWrite(path);
        const original = try self.readText(allocator, path);
        defer allocator.free(original);
        if (looksBinary(original)) return error.BinaryContent;
        if (original.len > self.sb.limits.max_write_bytes) return error.TooLarge;

        var replaced: std.ArrayList(u8) = .empty;
        defer replaced.deinit(allocator);
        var count: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, original, cursor, old)) |idx| {
            try replaced.appendSlice(allocator, original[cursor..idx]);
            try replaced.appendSlice(allocator, new);
            cursor = idx + old.len;
            count += 1;
        }
        if (count == 0) return error.NoMatch;
        try replaced.appendSlice(allocator, original[cursor..]);
        _ = try self.write(path, replaced.items);
        return count;
    }

    /// Create a directory chain inside the sandbox. The existing prefix is
    /// checked for symlink/junction components; the missing tail is created.
    pub fn mkdir(self: *const FsOps, path: []const u8) !void {
        try self.sb.checkWrite(path);
        if (self.sb.walkTo(path)) |opened_const| {
            var opened = opened_const;
            self.sb.closeOpened(&opened);
        } else |err| switch (err) {
            // A not-yet-existing path is the normal mkdir case; everything
            // that already exists was verified symlink-free by walkTo.
            error.FileNotFound => {},
            else => return err,
        }
        self.sb.root.createDirPath(self.sb.io, path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return sandbox_mod.mapOpenError(err),
        };
    }

    /// Delete a file, symlink, or directory (directories require `recursive`).
    pub fn delete(self: *const FsOps, path: []const u8, recursive: bool) !void {
        try self.sb.checkWrite(path);
        if (std.mem.eql(u8, path, ".")) return error.InvalidPath;
        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);
        const parent = self.parentOf(&opened);

        const stat = parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        if (stat.kind == .directory) {
            if (!recursive) {
                // Non-recursive delete must only succeed on empty dirs.
                var sub = parent.openDir(self.sb.io, opened.basename, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| return sandbox_mod.mapOpenError(err);
                defer sub.close(self.sb.io);
                var it = sub.iterate();
                const first = try it.next(self.sb.io);
                if (first != null) return error.NotEmpty;
            }
            parent.deleteTree(self.sb.io, opened.basename) catch |err| return sandbox_mod.mapOpenError(err);
            return;
        }
        parent.deleteFile(self.sb.io, opened.basename) catch |err| return sandbox_mod.mapOpenError(err);
    }

    /// Move/rename inside the sandbox using two validated parent handles.
    pub fn move(self: *const FsOps, src: []const u8, dst: []const u8) !void {
        try self.sb.checkWrite(src);
        try self.sb.checkWrite(dst);
        if (std.mem.eql(u8, src, dst)) return;

        var opened_src = try self.sb.walkTo(src);
        defer self.sb.closeOpened(&opened_src);
        var opened_dst = try self.sb.walkToCreate(dst);
        defer self.sb.closeOpened(&opened_dst);

        const src_dir = self.parentOf(&opened_src);
        const dst_dir = self.parentOf(&opened_dst);
        src_dir.rename(opened_src.basename, dst_dir, opened_dst.basename, self.sb.io) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
    }

    /// Copy a file inside the sandbox (existing destination replaced).
    pub fn copy(self: *const FsOps, src: []const u8, dst: []const u8) !void {
        try self.sb.checkRead(src);
        try self.sb.checkWrite(dst);

        var opened_src = try self.sb.walkTo(src);
        defer self.sb.closeOpened(&opened_src);
        var opened_dst = try self.sb.walkToCreate(dst);
        defer self.sb.closeOpened(&opened_dst);

        const src_dir = self.parentOf(&opened_src);
        const dst_dir = self.parentOf(&opened_dst);
        const stat = src_dir.statFile(self.sb.io, opened_src.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        if (stat.size > self.sb.limits.max_write_bytes) return error.TooLarge;
        src_dir.copyFile(opened_src.basename, dst_dir, opened_dst.basename, self.sb.io, .{}) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
    }

    /// Bounded recursive name search under `base`:
    /// {"query":"x","base":".","matches":[{"path":"a/x.txt","type":"file"}],...}
    pub fn searchJson(
        self: *const FsOps,
        allocator: std.mem.Allocator,
        base: []const u8,
        query: []const u8,
    ) ![]u8 {
        try self.sb.checkRead(base);
        if (query.len == 0) return error.InvalidPath;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("query");
        try stringify.write(query);
        try stringify.objectField("base");
        try stringify.write(base);
        try stringify.objectField("matches");
        try stringify.beginArray();

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Bounded DFS; each stack node records whether the dir handle is
        // owned by the search (borrowed handles, e.g. the sandbox root or a
        // walkTo parent, must never be closed here).
        const Node = struct { dir: std.Io.Dir, owned: bool, prefix: []const u8 };
        var stack: std.ArrayList(Node) = .empty;
        defer {
            for (stack.items) |node| {
                if (node.owned) node.dir.close(self.sb.io);
            }
            stack.deinit(allocator);
        }

        var base_opened = try self.sb.walkTo(base);
        defer self.sb.closeOpened(&base_opened);
        const parent = self.parentOf(&base_opened);
        // Reported paths are sandbox-root-relative so the agent can feed
        // them straight into follow-up tool calls.
        const root_prefix: []const u8 = if (std.mem.eql(u8, base, ".")) "" else base;
        if (std.mem.eql(u8, base_opened.basename, ".")) {
            try stack.append(allocator, .{ .dir = parent, .owned = false, .prefix = root_prefix });
        } else {
            const dir = parent.openDir(self.sb.io, base_opened.basename, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| return sandbox_mod.mapOpenError(err);
            try stack.append(allocator, .{ .dir = dir, .owned = true, .prefix = root_prefix });
        }

        var scanned: usize = 0;
        var matches: usize = 0;
        var truncated = false;
        while (stack.items.len > 0 and !truncated) {
            var node = stack.pop().?;
            defer if (node.owned) node.dir.close(self.sb.io);
            var it = node.dir.iterate();
            while (it.next(self.sb.io) catch |err| return sandbox_mod.mapOpenError(err)) |entry| {
                scanned += 1;
                if (scanned > self.sb.limits.max_entries) {
                    truncated = true;
                    break;
                }
                const rel = if (node.prefix.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ node.prefix, entry.name });

                if (containsIgnoreCase(entry.name, query)) {
                    if (matches >= self.sb.limits.max_search_results) {
                        truncated = true;
                        break;
                    }
                    matches += 1;
                    try stringify.beginObject();
                    try stringify.objectField("path");
                    try stringify.write(rel);
                    try stringify.objectField("type");
                    try stringify.write(fileKindName(entry.kind));
                    try stringify.endObject();
                }

                if (entry.kind == .directory) {
                    const sub = node.dir.openDir(self.sb.io, entry.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch continue; // symlinked/junctioned dirs are refused
                    try stack.append(allocator, .{ .dir = sub, .owned = true, .prefix = rel });
                }
            }
        }

        try stringify.endArray();
        try stringify.objectField("scanned");
        try stringify.write(scanned);
        try stringify.objectField("truncated");
        try stringify.write(truncated);
        try stringify.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

/// ASCII case-insensitive substring test.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn fileKindName(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        .block_device => "block_device",
        .character_device => "character_device",
        .named_pipe => "named_pipe",
        .unix_domain_socket => "socket",
        else => "unknown",
    };
}

/// Heuristic binary detection: a NUL byte in the first 8 KiB marks the
/// content binary. Text is everything else.
pub fn looksBinary(data: []const u8) bool {
    const window = data[0..@min(data.len, 8192)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

const TestEnv = struct {
    sandbox: Sandbox,
    cwd: std.Io.Dir,
    root_name: []const u8,

    fn init(allocator: std.mem.Allocator, root_name: []const u8, limits: sandbox_mod.Limits) !TestEnv {
        const io = std.testing.io;
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, root_name) catch {};
        return .{
            .sandbox = try Sandbox.init(io, allocator, cwd, root_name, .{
                .read = true,
                .write = true,
                .execute = false,
            }, limits),
            .cwd = cwd,
            .root_name = root_name,
        };
    }

    /// FsOps over the (now stable) sandbox field. Must not be taken before
    /// the TestEnv has reached its final address.
    fn ops(self: *TestEnv) FsOps {
        return FsOps.init(&self.sandbox);
    }

    fn deinit(self: *TestEnv) void {
        self.sandbox.deinit();
        self.cwd.deleteTree(std.testing.io, self.root_name) catch {};
    }
};

test "fsops writes, reads, lists and stats inside the sandbox" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-basic", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;
    const io = std.testing.io;

    _ = try ops.write("src/main.txt", "hello world");
    _ = try ops.write("src/nested/deep.txt", "deep");
    _ = try ops.mkdir("empty");

    const read_json = try ops.readJson(std.testing.allocator, "src/main.txt");
    defer std.testing.allocator.free(read_json);
    try std.testing.expect(std.mem.indexOf(u8, read_json, "\"content\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_json, "\"encoding\":\"utf-8\"") != null);

    const list_json = try ops.listJson(std.testing.allocator, "src");
    defer std.testing.allocator.free(list_json);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"name\":\"main.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"type\":\"file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "\"type\":\"directory\"") != null);

    const stat_json = try ops.statJson(std.testing.allocator, "src/main.txt");
    defer std.testing.allocator.free(stat_json);
    try std.testing.expect(std.mem.indexOf(u8, stat_json, "\"size\":11") != null);

    const stat_dir = try ops.statJson(std.testing.allocator, "empty");
    defer std.testing.allocator.free(stat_dir);
    try std.testing.expect(std.mem.indexOf(u8, stat_dir, "\"type\":\"directory\"") != null);

    const raw = try env.sandbox.root.readFileAlloc(io, "src/main.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("hello world", raw);
}

test "fsops rejects traversal, absolute paths and reserved names on every op" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-traversal", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    try std.testing.expectError(error.PathTraversal, ops.write("../escape.txt", "x"));
    try std.testing.expectError(error.PathTraversal, ops.readJson(std.testing.allocator, "C:/Windows/system.ini"));
    try std.testing.expectError(error.PathTraversal, ops.readJson(std.testing.allocator, "..\\..\\secret"));
    try std.testing.expectError(error.PathTraversal, ops.listJson(std.testing.allocator, "/"));
    try std.testing.expectError(error.PathTraversal, ops.mkdir("a/../b"));
    try std.testing.expectError(error.ReservedName, ops.write("aux.log", "x"));
    try std.testing.expectError(error.PathTraversal, ops.delete("C:\\Windows", true));
    try std.testing.expectError(error.PathTraversal, ops.statJson(std.testing.allocator, "\\\\server\\share"));
}

test "fsops edit replaces matches and reports no-match" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-edit", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    _ = try ops.write("code.txt", "alpha beta alpha");
    const count = try ops.edit(std.testing.allocator, "code.txt", "alpha", "gamma");
    try std.testing.expectEqual(@as(usize, 2), count);
    const json = try ops.readJson(std.testing.allocator, "code.txt");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "gamma beta gamma") != null);

    try std.testing.expectError(error.NoMatch, ops.edit(std.testing.allocator, "code.txt", "absent", "x"));
}

test "fsops move, copy and delete respect sandbox rules" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-move", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    _ = try ops.write("a.txt", "content-a");
    try ops.copy("a.txt", "backup/a.txt");
    try ops.move("a.txt", "moved/a.txt");
    try std.testing.expectError(error.FileNotFound, ops.statJson(std.testing.allocator, "a.txt"));

    const moved = try ops.readJson(std.testing.allocator, "moved/a.txt");
    defer std.testing.allocator.free(moved);
    try std.testing.expect(std.mem.indexOf(u8, moved, "content-a") != null);
    const backup = try ops.readJson(std.testing.allocator, "backup/a.txt");
    defer std.testing.allocator.free(backup);
    try std.testing.expect(std.mem.indexOf(u8, backup, "content-a") != null);

    // Non-recursive delete refuses a non-empty directory.
    _ = try ops.write("dir/file.txt", "x");
    try std.testing.expectError(error.NotEmpty, ops.delete("dir", false));
    try ops.delete("dir", true);
    try std.testing.expectError(error.FileNotFound, ops.statJson(std.testing.allocator, "dir/file.txt"));
}

test "fsops search is bounded and stays inside the sandbox" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-search", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    _ = try ops.write("tree/one/match_me.txt", "1");
    _ = try ops.write("tree/two/match_too.txt", "2");
    _ = try ops.write("tree/other/skip.txt", "3");

    const json = try ops.searchJson(std.testing.allocator, "tree", "match");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "tree/one/match_me.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tree/two/match_too.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "skip.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"truncated\":false") != null);
}

test "fsops enforces read and write limits" {
    const limits = sandbox_mod.Limits{
        .max_read_bytes = 8,
        .max_write_bytes = 16,
    };
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-limits", limits);
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    try std.testing.expectError(error.TooLarge, ops.write("big.bin", "x" ** 32));
    _ = try ops.write("small.txt", "0123456789ABCDEF");
    const json = try ops.readJson(std.testing.allocator, "small.txt");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "01234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "89ABCDEF") == null);
}

test "fsops detects binary content and encodes it as base64" {
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-binary", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    const payload = [_]u8{ 0x89, 'P', 'N', 'G', 0x00, 0x01, 0x02, 0xff };
    _ = try ops.write("img.bin", &payload);
    const json = try ops.readJson(std.testing.allocator, "img.bin");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"encoding\":\"binary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "content_base64") != null);

    // Editing binary content is refused.
    try std.testing.expectError(error.BinaryContent, ops.edit(std.testing.allocator, "img.bin", "P", "Q"));
}

test "fsops refuses symlink escape when the platform permits symlinks" {
    const io = std.testing.io;
    var env = try TestEnv.init(std.testing.allocator, "zig-cache-pico-fsops-symlink", .{});
    defer env.deinit();
    var ops_v = env.ops();
    const ops = &ops_v;

    // Create a symlink inside the sandbox that points outside it. Creating
    // symlinks needs privileges on some systems; skip when unavailable.
    env.sandbox.root.symLink(io, "..", "escape_link", .{ .is_directory = true }) catch return error.SkipZigTest;

    try std.testing.expectError(error.SymLinkRefused, ops.readJson(std.testing.allocator, "escape_link/anything.txt"));
    try std.testing.expectError(error.SymLinkRefused, ops.listJson(std.testing.allocator, "escape_link"));
    try std.testing.expectError(error.SymLinkRefused, ops.write("escape_link/planted.txt", "x"));
}
