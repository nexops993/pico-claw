//! Explicit sandbox runtime: path policy, containment, and limits.
//!
//! Every path the agent (model) supplies is validated here before any
//! filesystem operation. Containment is enforced by three independent layers:
//!
//! 1. Strict lexical validation (`validateRelPath`): rejects absolute paths,
//!    drive letters, UNC/NT device paths, `..` traversal, reserved device
//!    names, control characters, and Windows-forbidden punctuation.
//! 2. Handle-relative operations: all file operations go through an open
//!    directory handle for the sandbox root, one path component at a time,
//!    with symlink following disabled (`walkTo`), so junctions, reparse
//!    points, and symlinks can never redirect an operation outside the root.
//! 3. Resource limits (`Limits`): file, output, archive, and extraction sizes
//!    plus entry counts and timeouts.
//!
//! The sandbox never materializes absolute host paths for agent-supplied
//! input; agent-visible paths are always sandbox-relative.

const std = @import("std");

pub const max_path_len: usize = 1024;
pub const max_component_len: usize = 255;
pub const max_depth: usize = 64;

/// Resource limits. Defaults are conservative; configuration may lower them
/// (raising requires an explicit host-side decision, never model input).
pub const Limits = struct {
    /// Largest file the sandbox will read into memory for the agent.
    max_read_bytes: usize = 2 * 1024 * 1024,
    /// Largest file the sandbox will write or edit.
    max_write_bytes: usize = 64 * 1024 * 1024,
    /// Largest single process output stream (stdout or stderr).
    max_output_bytes: usize = 512 * 1024,
    /// Largest archive file accepted for inspection/extraction.
    max_archive_bytes: usize = 256 * 1024 * 1024,
    /// Largest total extracted size across one archive extraction.
    max_extracted_bytes: usize = 1024 * 1024 * 1024,
    /// Largest number of entries in one archive or directory listing.
    max_entries: usize = 20_000,
    /// Largest number of search results returned.
    max_search_results: usize = 500,
    /// Default process execution timeout.
    exec_timeout_ms: u64 = 60_000,
    /// Largest stdin payload passed to a child process.
    max_stdin_bytes: usize = 256 * 1024,
};

/// Whole-root access grants. Additional per-subpath prefix grants can be
/// layered via `read_prefixes` / `write_prefixes`; an empty list means the
/// whole root is covered by the corresponding grant.
pub const Access = struct {
    read: bool = true,
    write: bool = true,
    execute: bool = false,
    read_prefixes: []const []const u8 = &.{},
    write_prefixes: []const []const u8 = &.{},
    /// Exact argv[0] program names that may be spawned. Empty denies all
    /// execution; there is no wildcard.
    executable_commands: []const []const u8 = &.{},
    /// Environment variable NAMES forwarded to child processes. Values are
    /// never logged; names only appear in policy metadata.
    env_allowlist: []const []const u8 = &.{},
    network_enabled: bool = false,
};

pub const PathError = error{
    /// Empty, too long, malformed, or otherwise unusable path.
    InvalidPath,
    /// Absolute path, drive letter, UNC/NT device path, or `..` traversal.
    PathTraversal,
    /// Windows reserved device name (CON, NUL, COM1, ...).
    ReservedName,
    /// Depth or component count exceeds sandbox limits.
    TooDeep,
};

/// Lexical path errors plus grant refusal.
pub const GrantError = PathError || error{PathDenied};

const reserved_devices = [_][]const u8{
    "CON",  "PRN",  "AUX",  "NUL",
    "COM1", "COM2", "COM3", "COM4",
    "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3",
    "LPT4", "LPT5", "LPT6", "LPT7",
    "LPT8", "LPT9",
};

/// Validate a sandbox-relative path lexically. The accepted shape is a clean,
/// relative, forward-slash path: `dir/file.txt`, `a/b/c`, `file.txt`.
/// Trailing separators are tolerated and ignored.
pub fn validateRelPath(path: []const u8) PathError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > max_path_len) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.PathTraversal;

    // UNC / NT device / drive-letter absolute paths are rejected outright.
    if (std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//"))
        return error.PathTraversal;
    if (path.len >= 2 and path[1] == ':') return error.PathTraversal;

    var components = std.mem.tokenizeAny(u8, path, "/\\");
    var depth: usize = 0;
    while (components.next()) |component| {
        depth += 1;
        if (depth > max_depth) return error.TooDeep;
        if (component.len == 0) continue; // duplicate separators
        if (component.len > max_component_len) return error.InvalidPath;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.PathTraversal;
        for (component) |c| {
            // Windows forbids bytes < 0x20 in file names; DEL and the
            // reserved punctuation are rejected for the same reason.
            if (c < 0x20 or c == 0x7f) return error.InvalidPath;
            switch (c) {
                ':', '"', '*', '<', '>', '|', '?' => return error.PathTraversal,
                else => {},
            }
        }
        // Windows strips trailing dots/spaces, which enables rename confusion;
        // reject rather than normalize so the agent sees the real policy.
        if (component[component.len - 1] == '.' or component[component.len - 1] == ' ')
            return error.InvalidPath;
        // Reserved device names match the stem (before the first dot) and
        // are case-insensitive: CON.txt is as dangerous as CON.
        const stem = component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len];
        for (reserved_devices) |device| {
            if (std.ascii.eqlIgnoreCase(stem, device)) return error.ReservedName;
        }
    }
    if (depth == 0) return error.InvalidPath;
}

/// Normalize a validated path: forward slashes, no trailing separator,
/// no duplicate separators. Returns a slice of `buf`.
pub fn normalizePath(buf: []u8, path: []const u8) PathError![]const u8 {
    try validateRelPath(path);
    var out: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (out != 0) {
            buf[out] = '/';
            out += 1;
        }
        @memcpy(buf[out..][0..component.len], component);
        out += component.len;
    }
    return buf[0..out];
}

/// True when `path` is inside `prefix` at a component boundary. ASCII
/// case-insensitive: Windows file names compare without case.
pub fn pathHasPrefix(prefix: []const u8, path: []const u8) bool {
    if (prefix.len == 0) return true;
    if (path.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)) return false;
    if (path.len == prefix.len) return true;
    return path[prefix.len] == '/';
}

/// A validated path opened component-by-component without following symlinks.
/// `parent_dirs` holds every intermediate directory that was opened (the last
/// element is the directory containing `basename`); callers must close them.
pub const OpenedPath = struct {
    parent_dirs: []std.Io.Dir,
    basename: []const u8,

    pub fn close(self: *OpenedPath, io: std.Io, allocator: std.mem.Allocator) void {
        var i = self.parent_dirs.len;
        while (i > 0) {
            i -= 1;
            self.parent_dirs[i].close(io);
        }
        allocator.free(self.parent_dirs);
        self.parent_dirs = &.{};
    }
};

pub const OpenPathError = PathError || error{
    AccessDenied,
    FileNotFound,
    NotDir,
    SymLinkLoop,
    SystemResources,
    Unexpected,
    OutOfMemory,
    ProcessFdQuotaExceeded,
    NameTooLong,
    /// A symlink or junction was refused by policy (no-follow).
    SymLinkRefused,
    /// The operation is not permitted by the sandbox access grant.
    PathDenied,
};

pub fn mapOpenError(err: anyerror) OpenPathError {
    return switch (err) {
        error.InvalidPath, error.PathTraversal, error.ReservedName, error.TooDeep => |e| @errorCast(e),
        error.AccessDenied, error.FileNotFound, error.NotDir, error.SymLinkLoop => |e| @errorCast(e),
        error.SymLink => error.SymLinkRefused,
        error.PathDenied => error.PathDenied,
        error.OutOfMemory, error.SystemResources, error.ProcessFdQuotaExceeded, error.NameTooLong, error.Unexpected => |e| @errorCast(e),
        else => error.Unexpected,
    };
}

/// The sandbox: an open workspace root plus explicit policy and limits.
/// Construct one per workspace and pass it to every tool that touches the
/// filesystem or spawns processes.
pub const Sandbox = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    root_owned: bool = true,
    /// Display name of the workspace root (for policy reporting).
    root_name: []const u8 = "",
    policy: Access,
    limits: Limits,

    /// Open the sandbox root under `base_dir`, creating it when missing.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        base_dir: std.Io.Dir,
        root_name: []const u8,
        policy: Access,
        limits: Limits,
    ) OpenPathError!Sandbox {
        validateRelPath(root_name) catch |err| return mapOpenError(err);
        base_dir.createDirPath(io, root_name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return mapOpenError(err),
        };
        const root = base_dir.openDir(io, root_name, .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| return mapOpenError(err);
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .root_name = root_name,
            .policy = policy,
            .limits = limits,
        };
    }

    /// Wrap an already-open directory as the sandbox root (used by tests and
    /// by callers that manage the root handle themselves).
    pub fn attach(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: std.Io.Dir,
        policy: Access,
        limits: Limits,
    ) Sandbox {
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .root_owned = false,
            .policy = policy,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Sandbox) void {
        if (self.root_owned) self.root.close(self.io);
        self.root_owned = false;
    }

    pub fn checkRead(self: *const Sandbox, path: []const u8) GrantError!void {
        try validateRelPath(path);
        if (!self.policy.read) return error.PathDenied;
        if (self.policy.read_prefixes.len == 0) return;
        for (self.policy.read_prefixes) |prefix| {
            if (pathHasPrefix(prefix, path)) return;
        }
        return error.PathDenied;
    }

    pub fn checkWrite(self: *const Sandbox, path: []const u8) GrantError!void {
        try validateRelPath(path);
        if (!self.policy.write) return error.PathDenied;
        if (self.policy.write_prefixes.len == 0) return;
        for (self.policy.write_prefixes) |prefix| {
            if (pathHasPrefix(prefix, path)) return;
        }
        return error.PathDenied;
    }

    /// Exact-match program allowlist check; there is deliberately no wildcard
    /// and no shell interpretation.
    pub fn checkExecute(self: *const Sandbox, command: []const u8) bool {
        if (!self.policy.execute) return false;
        for (self.policy.executable_commands) |allowed| {
            if (std.mem.eql(u8, allowed, command)) return true;
        }
        return false;
    }

    /// Open every intermediate directory of a validated `path` without
    /// following symlinks. Symlinked/junctioned intermediates are refused.
    pub fn walkTo(self: *const Sandbox, path: []const u8) OpenPathError!OpenedPath {
        return self.walkToInternal(path, false);
    }

    /// Like `walkTo`, but creates missing intermediate directories
    /// (`mkdir -p` semantics) before returning. Used by write operations.
    pub fn walkToCreate(self: *const Sandbox, path: []const u8) OpenPathError!OpenedPath {
        return self.walkToInternal(path, true);
    }

    fn walkToInternal(self: *const Sandbox, path: []const u8, create: bool) OpenPathError!OpenedPath {
        validateRelPath(path) catch |err| return mapOpenError(err);

        var dirs: std.ArrayList(std.Io.Dir) = .empty;
        errdefer {
            for (dirs.items) |*d| d.close(self.io);
            dirs.deinit(self.allocator);
        }

        var current = self.root;
        var components = std.mem.tokenizeAny(u8, path, "/\\");
        var basename: []const u8 = components.next() orelse return error.InvalidPath;
        while (components.next()) |next| {
            const sub = current.openDir(self.io, basename, .{
                .access_sub_paths = true,
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.NotDir => return error.NotDir,
                error.SymLinkLoop => return error.SymLinkRefused,
                error.FileNotFound => blk: {
                    if (!create) return error.FileNotFound;
                    current.createDirPath(self.io, basename) catch |cerr| switch (cerr) {
                        error.PathAlreadyExists => {},
                        else => return mapOpenError(cerr),
                    };
                    break :blk current.openDir(self.io, basename, .{
                        .access_sub_paths = true,
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch |oerr| return mapOpenError(oerr);
                },
                else => return mapOpenError(err),
            };
            try dirs.append(self.allocator, sub);
            current = sub;
            basename = next;
        }
        return .{
            .parent_dirs = try dirs.toOwnedSlice(self.allocator),
            .basename = basename,
        };
    }

    /// Release a `walkTo`/`walkToCreate` result.
    pub fn closeOpened(self: *const Sandbox, opened: *OpenedPath) void {
        opened.close(self.io, self.allocator);
    }
};

test "validateRelPath accepts clean relative paths" {
    try validateRelPath("file.txt");
    try validateRelPath("dir/file.txt");
    try validateRelPath("a/b/c.zig");
    try validateRelPath("dir/");
    try validateRelPath("uploads/project.zip");
}

test "validateRelPath rejects absolute and traversal paths" {
    try std.testing.expectError(error.InvalidPath, validateRelPath(""));
    try std.testing.expectError(error.PathTraversal, validateRelPath("/etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("\\Windows"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("C:\\Users\\x"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("C:/Windows"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("\\\\server\\share\\f"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("\\\\.\\pipe\\x"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("a/../secret"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("..\\secret"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("dir/.."));
    try std.testing.expectError(error.PathTraversal, validateRelPath("stream:hidden"));
    try std.testing.expectError(error.PathTraversal, validateRelPath("a<b"));
}

test "validateRelPath rejects reserved device names and malformed components" {
    try std.testing.expectError(error.ReservedName, validateRelPath("CON"));
    try std.testing.expectError(error.ReservedName, validateRelPath("con.txt"));
    try std.testing.expectError(error.ReservedName, validateRelPath("dir/NUL.log"));
    try std.testing.expectError(error.ReservedName, validateRelPath("COM1"));
    try std.testing.expectError(error.InvalidPath, validateRelPath("trailing."));
    try std.testing.expectError(error.InvalidPath, validateRelPath("trailing "));
    try std.testing.expectError(error.InvalidPath, validateRelPath("bad\x00name"));
    try std.testing.expectError(error.InvalidPath, validateRelPath("a\x01b"));
}

test "normalizePath canonicalizes separators and duplicates" {
    var buf: [max_path_len]u8 = undefined;
    try std.testing.expectEqualStrings("a/b/c", try normalizePath(&buf, "a//b\\c/"));
    try std.testing.expectEqualStrings("x.txt", try normalizePath(&buf, "x.txt"));
    // `.` components are policy-rejected, not normalized away.
    try std.testing.expectError(error.PathTraversal, normalizePath(&buf, "./x.txt"));
}

test "pathHasPrefix is component-boundary aware and case-insensitive" {
    try std.testing.expect(pathHasPrefix("", "anything"));
    try std.testing.expect(pathHasPrefix("a", "a/b"));
    try std.testing.expect(pathHasPrefix("a", "a"));
    try std.testing.expect(!pathHasPrefix("a", "ab/c"));
    try std.testing.expect(pathHasPrefix("UPLOADS", "uploads/file.txt"));
    try std.testing.expect(!pathHasPrefix("uploads", "uploads2/file.txt"));
}

test "sandbox opens root, creates dirs, and enforces grants" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_root = "zig-cache-pico-sandbox-test";
    var sandbox = try Sandbox.init(io, std.testing.allocator, cwd, test_root, .{ .write = true }, .{});
    defer {
        sandbox.deinit();
        cwd.deleteTree(io, test_root) catch {};
    }

    try sandbox.checkRead("a/b.txt");
    try sandbox.checkWrite("out/result.txt");

    var denied = sandbox;
    denied.policy.read = false;
    try std.testing.expectError(error.PathDenied, denied.checkRead("a/b.txt"));

    var prefixed = sandbox;
    prefixed.policy = .{ .read = true, .read_prefixes = &.{"public"} };
    try prefixed.checkRead("public/doc.txt");
    try std.testing.expectError(error.PathDenied, prefixed.checkRead("private/doc.txt"));

    // walkToCreate creates the parent chain; the result can be used to
    // create the final component.
    var opened = try sandbox.walkToCreate("nested/deeper/file.txt");
    defer sandbox.closeOpened(&opened);
    const parent = opened.parent_dirs[opened.parent_dirs.len - 1];
    var file = try parent.createFile(io, opened.basename, .{
        .resolve_beneath = true,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, "payload");

    // The created file is visible through the sandbox root at the expected
    // relative path.
    const content = try sandbox.root.readFileAlloc(
        io,
        "nested/deeper/file.txt",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("payload", content);

    // Traversal and absolute paths are refused before any syscall.
    try std.testing.expectError(error.PathTraversal, sandbox.walkTo("../outside.txt"));
    try std.testing.expectError(error.PathTraversal, sandbox.walkTo("C:/Windows/System32"));
}
