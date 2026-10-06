//! Sandboxed process execution.
//!
//! There is deliberately no shell: the agent supplies a program name plus
//! argument list, never a command string. The program must be on the sandbox
//! execution allowlist; the working directory must resolve inside the
//! sandbox; the environment is filtered through an allowlist of variable
//! names; stdout/stderr are bounded; and a timeout terminates the child
//! process tree. Results come from the actual process outcome.

const std = @import("std");
const sandbox_mod = @import("sandbox.zig");

pub const Sandbox = sandbox_mod.Sandbox;

pub const ExecRequest = struct {
    /// Program name (allowlist-matched) or a sandbox-relative path.
    command: []const u8,
    args: []const []const u8 = &.{},
    /// Sandbox-relative working directory.
    cwd: []const u8 = ".",
    stdin: []const u8 = "",
    /// Overrides the policy default; clamped to the policy maximum.
    timeout_ms: ?u64 = null,
};

pub const ExecError = sandbox_mod.OpenPathError || error{
    /// The command is not on the sandbox execution allowlist.
    ExecuteDenied,
    /// `command` is empty or malformed.
    InvalidCommand,
    /// A request field exceeded a sandbox limit.
    TooLarge,
    /// The child could not be spawned.
    SpawnFailed,
    /// Process bookkeeping failed (thread/allocator resources).
    ProcessFailed,
};

pub const ProcessRunner = struct {
    sb: *const Sandbox,
    /// Parent environment; only names listed in the policy allowlist are
    /// forwarded. `null` means child processes get an empty environment.
    parent_env: ?*const std.process.Environ.Map = null,

    /// JSON request shape accepted by `execJson`:
    /// {"command":"zig","args":["build","test"],"cwd":".",
    ///  "stdin":"","timeout_ms":5000}
    pub const RawRequest = struct {
        command: []const u8,
        args: ?[]const []const u8 = null,
        cwd: ?[]const u8 = null,
        stdin: ?[]const u8 = null,
        timeout_ms: ?u64 = null,
    };

    pub fn init(sb: *const Sandbox, parent_env: ?*const std.process.Environ.Map) ProcessRunner {
        return .{ .sb = sb, .parent_env = parent_env };
    }

    /// Execute a request parsed from JSON and return the structured JSON
    /// result: {"exit_code","stdout","stderr","duration_ms","timed_out",...}
    pub fn execJson(self: *const ProcessRunner, allocator: std.mem.Allocator, json: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(RawRequest, allocator, json, .{}) catch
            return error.InvalidCommand;
        defer parsed.deinit();

        return self.exec(allocator, .{
            .command = parsed.value.command,
            .args = parsed.value.args orelse &.{},
            .cwd = parsed.value.cwd orelse ".",
            .stdin = parsed.value.stdin orelse "",
            .timeout_ms = parsed.value.timeout_ms,
        });
    }

    /// Execute `req` inside the sandbox and return a structured JSON result.
    /// The result always reflects the real process outcome.
    pub fn exec(self: *const ProcessRunner, allocator: std.mem.Allocator, req: ExecRequest) ExecError![]u8 {
        const io = self.sb.io;
        const limits = self.sb.limits;

        if (req.command.len == 0) return error.InvalidCommand;
        if (!self.sb.checkExecute(req.command)) return error.ExecuteDenied;
        if (req.stdin.len > limits.max_stdin_bytes) return error.TooLarge;
        for (req.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
        }
        const timeout_ms: u64 = @min(req.timeout_ms orelse limits.exec_timeout_ms, limits.exec_timeout_ms);

        // The working directory must resolve inside the sandbox without
        // traversing symlinks/junctions. "." means the sandbox root.
        var cwd_opened: ?sandbox_mod.OpenedPath = null;
        defer if (cwd_opened) |*o| self.sb.closeOpened(o);
        var cwd_dir_owned: ?std.Io.Dir = null;
        defer if (cwd_dir_owned) |d| d.close(io);
        const cwd_dir: std.Io.Dir = blk: {
            if (std.mem.eql(u8, req.cwd, ".")) break :blk self.sb.root;
            cwd_opened = try self.sb.walkTo(req.cwd);
            const opened = &cwd_opened.?;
            const parent = if (opened.parent_dirs.len == 0)
                self.sb.root
            else
                opened.parent_dirs[opened.parent_dirs.len - 1];
            const dir = parent.openDir(io, opened.basename, .{
                .access_sub_paths = true,
                .follow_symlinks = false,
            }) catch |err| return sandbox_mod.mapOpenError(err);
            cwd_dir_owned = dir;
            break :blk dir;
        };

        // Filtered environment: only allowlisted variable NAMES are passed
        // through; values are never logged or returned anywhere.
        var child_env: ?std.process.Environ.Map = null;
        defer if (child_env) |*m| m.deinit();
        if (self.sb.policy.env_allowlist.len > 0) {
            var map = std.process.Environ.Map.init(allocator);
            errdefer map.deinit();
            if (self.parent_env) |parent| {
                for (self.sb.policy.env_allowlist) |name| {
                    if (parent.get(name)) |value|
                        map.put(name, value) catch return error.OutOfMemory;
                }
            }
            child_env = map;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        argv.append(allocator, req.command) catch return error.OutOfMemory;
        for (req.args) |arg|
            argv.append(allocator, arg) catch return error.OutOfMemory;

        const spawn_options: std.process.SpawnOptions = .{
            .argv = argv.items,
            .cwd = .{ .dir = cwd_dir },
            .environ_map = if (child_env) |*m| m else null,
            .stdin = if (req.stdin.len > 0) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        };

        // A command containing a path separator runs a binary from inside
        // the sandbox workspace; anything else resolves via the filtered
        // PATH and must have matched the exact allowlist above.
        const started = std.Io.Timestamp.now(io, .awake);
        var child = if (std.mem.indexOfAny(u8, req.command, "/\\") != null)
            std.process.spawnPath(io, self.sb.root, spawn_options) catch return error.SpawnFailed
        else
            std.process.spawn(io, spawn_options) catch return error.SpawnFailed;
        var finished = false;
        defer if (!finished) child.kill(io);

        // Feed stdin from a helper thread so a child that never reads its
        // input cannot deadlock the collection loop.
        var stdin_thread: ?std.Thread = null;
        defer if (stdin_thread) |t| t.join();
        if (child.stdin) |stdin_file| {
            stdin_thread = std.Thread.spawn(.{}, writeStdin, .{ stdin_file, io, req.stdin }) catch null;
            // Ownership of the write end moves to the thread.
            child.stdin = null;
        }

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();
        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        var timed_out = false;
        var truncated = false;
        var killed = false;

        while (multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .awake } })) |_| {
            if (stdout_reader.buffered().len > limits.max_output_bytes or
                stderr_reader.buffered().len > limits.max_output_bytes)
            {
                truncated = true;
                break;
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => timed_out = true,
            else => return error.ProcessFailed,
        }

        var term: std.process.Child.Term = .{ .unknown = 0 };
        if (timed_out or truncated) {
            child.kill(io);
            killed = true;
            finished = true;
            // Drain whatever the child produced before termination.
            while (multi_reader.fill(64, .none)) |_| {} else |_| {}
        } else {
            multi_reader.checkAnyError() catch {};
            term = child.wait(io) catch return error.ProcessFailed;
            finished = true;
        }

        const stdout = multi_reader.toOwnedSlice(0) catch return error.OutOfMemory;
        defer allocator.free(stdout);
        const stderr = multi_reader.toOwnedSlice(1) catch return error.OutOfMemory;
        defer allocator.free(stderr);

        const duration_ms = started
            .durationTo(std.Io.Timestamp.now(io, .awake))
            .toMilliseconds();

        return renderResult(allocator, .{
            .command = req.command,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (term) {
                .exited => |code| @as(?i64, code),
                else => null,
            },
            .signal = switch (term) {
                .signal => |sig| @as(?[]const u8, @tagName(sig)),
                .stopped => |sig| @as(?[]const u8, @tagName(sig)),
                else => null,
            },
            .duration_ms = duration_ms,
            .timed_out = timed_out,
            .truncated = truncated,
            .killed = killed,
        });
    }

    fn writeStdin(file: std.Io.File, io: std.Io, data: []const u8) void {
        defer file.close(io);
        file.writeStreamingAll(io, data) catch {};
    }
};

pub const Rendered = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?i64,
    signal: ?[]const u8,
    duration_ms: i64,
    timed_out: bool,
    truncated: bool,
    killed: bool,
};

fn renderResult(allocator: std.mem.Allocator, r: Rendered) ExecError![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    stringify.beginObject() catch return error.OutOfMemory;
    stringify.objectField("command") catch return error.OutOfMemory;
    stringify.write(r.command) catch return error.OutOfMemory;
    stringify.objectField("exit_code") catch return error.OutOfMemory;
    if (r.exit_code) |code| {
        stringify.write(code) catch return error.OutOfMemory;
    } else {
        stringify.write(null) catch return error.OutOfMemory;
    }
    stringify.objectField("signal") catch return error.OutOfMemory;
    if (r.signal) |sig| {
        stringify.write(sig) catch return error.OutOfMemory;
    } else {
        stringify.write(null) catch return error.OutOfMemory;
    }
    stringify.objectField("stdout") catch return error.OutOfMemory;
    stringify.write(r.stdout) catch return error.OutOfMemory;
    stringify.objectField("stderr") catch return error.OutOfMemory;
    stringify.write(r.stderr) catch return error.OutOfMemory;
    stringify.objectField("duration_ms") catch return error.OutOfMemory;
    stringify.write(r.duration_ms) catch return error.OutOfMemory;
    stringify.objectField("timed_out") catch return error.OutOfMemory;
    stringify.write(r.timed_out) catch return error.OutOfMemory;
    stringify.objectField("truncated") catch return error.OutOfMemory;
    stringify.write(r.truncated) catch return error.OutOfMemory;
    stringify.objectField("killed") catch return error.OutOfMemory;
    stringify.write(r.killed) catch return error.OutOfMemory;
    stringify.endObject() catch return error.OutOfMemory;
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const builtin = @import("builtin");

fn echoCommand() struct { cmd: []const u8, args: []const []const u8 } {
    return switch (builtin.os.tag) {
        .windows => .{ .cmd = "cmd", .args = &.{ "/c", "echo", "pico-exec-ok" } },
        else => .{ .cmd = "echo", .args = &.{"pico-exec-ok"} },
    };
}

/// A child that stays alive longer than any test timeout.
fn sleepProgram() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "ping",
        else => "sleep",
    };
}

fn sleepArgs() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "-n", "30", "127.0.0.1" },
        else => &.{"30"},
    };
}

const exec_test_allowlist = [_][]const u8{ "cmd", "echo", "ping", "sleep", "more", "cat", "sh" };

const TestHarness = struct {
    sandbox: sandbox_mod.Sandbox,
    root_name: []const u8,
    cwd_dir: std.Io.Dir,

    fn deinit(self: *TestHarness) void {
        self.sandbox.deinit();
        self.cwd_dir.deleteTree(std.testing.io, self.root_name) catch {};
    }

    /// Runner over the (now stable) sandbox field.
    fn runner(self: *TestHarness) ProcessRunner {
        return ProcessRunner.init(&self.sandbox, null);
    }
};

fn testRunner(allocator: std.mem.Allocator, limits: sandbox_mod.Limits) !TestHarness {
    const io = std.testing.io;
    const cwd_dir = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-exec";
    cwd_dir.deleteTree(io, root_name) catch {};
    const sandbox = try sandbox_mod.Sandbox.init(io, allocator, cwd_dir, root_name, .{
        .read = true,
        .write = true,
        .execute = true,
        .executable_commands = &exec_test_allowlist,
    }, limits);
    return .{
        .sandbox = sandbox,
        .root_name = root_name,
        .cwd_dir = cwd_dir,
    };
}

test "process.exec runs an allowlisted command and reports the real outcome" {
    var t = try testRunner(std.testing.allocator, .{});
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    const echo = echoCommand();
    const json = try runner.exec(std.testing.allocator, .{
        .command = echo.cmd,
        .args = echo.args,
        .timeout_ms = 10_000,
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pico-exec-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timed_out\":false") != null);
}

test "process.exec refuses commands outside the allowlist" {
    var t = try testRunner(std.testing.allocator, .{});
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    try std.testing.expectError(
        error.ExecuteDenied,
        runner.exec(std.testing.allocator, .{ .command = "whoami" }),
    );
    // Execution with the grant off is refused even for allowlisted names.
    t.sandbox.policy.execute = false;
    const echo = echoCommand();
    try std.testing.expectError(
        error.ExecuteDenied,
        runner.exec(std.testing.allocator, .{ .command = echo.cmd, .args = echo.args }),
    );
}

test "process.exec timeout kills the child and reports timed_out" {
    var t = try testRunner(std.testing.allocator, .{});
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    const json = try runner.exec(std.testing.allocator, .{
        .command = sleepProgram(),
        .args = sleepArgs(),
        .timeout_ms = 400,
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"killed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exit_code\":null") != null);
}

test "process.exec enforces output limits and flags truncation" {
    var t = try testRunner(std.testing.allocator, .{ .max_output_bytes = 64 });
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    const long = "a" ** 512;
    const json = switch (builtin.os.tag) {
        .windows => try runner.exec(std.testing.allocator, .{
            .command = "cmd",
            .args = &.{ "/c", "echo", long },
            .timeout_ms = 10_000,
        }),
        else => try runner.exec(std.testing.allocator, .{
            .command = "echo",
            .args = &.{long},
            .timeout_ms = 10_000,
        }),
    };
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"killed\":true") != null);
}

test "process.exec pipes stdin to the child" {
    var t = try testRunner(std.testing.allocator, .{});
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    const json = switch (builtin.os.tag) {
        .windows => try runner.exec(std.testing.allocator, .{
            .command = "cmd",
            .args = &.{ "/c", "more" },
            .stdin = "hello-from-stdin",
            .timeout_ms = 10_000,
        }),
        else => try runner.exec(std.testing.allocator, .{
            .command = "cat",
            .stdin = "hello-from-stdin",
            .timeout_ms = 10_000,
        }),
    };
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello-from-stdin") != null);
}

test "process.exec filters the environment through the allowlist" {
    const io = std.testing.io;
    const cwd_dir = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-exec-env";
    cwd_dir.deleteTree(io, root_name) catch {};
    var sandbox = try sandbox_mod.Sandbox.init(io, std.testing.allocator, cwd_dir, root_name, .{
        .read = true,
        .write = true,
        .execute = true,
        .executable_commands = &exec_test_allowlist,
        .env_allowlist = &.{"PICO_TEST_SAFE"},
    }, .{});
    defer {
        sandbox.deinit();
        cwd_dir.deleteTree(io, root_name) catch {};
    }

    var parent_env = std.process.Environ.Map.init(std.testing.allocator);
    defer parent_env.deinit();
    try parent_env.put("PICO_TEST_SAFE", "visible-value");
    try parent_env.put("PICO_TEST_SECRET", "hidden-value");

    var runner_v = ProcessRunner.init(&sandbox, &parent_env);
    const runner = &runner_v;
    const json = switch (builtin.os.tag) {
        .windows => try runner.exec(std.testing.allocator, .{
            .command = "cmd",
            .args = &.{ "/c", "set" },
            .timeout_ms = 10_000,
        }),
        else => try runner.exec(std.testing.allocator, .{
            .command = "sh",
            .args = &.{ "-c", "env" },
            .timeout_ms = 10_000,
        }),
    };
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "PICO_TEST_SAFE=visible-value") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "PICO_TEST_SECRET") == null);
}

test "process.exec reports nonzero exit codes verbatim" {
    var t = try testRunner(std.testing.allocator, .{});
    defer t.deinit();
    var runner_v = t.runner();
    const runner = &runner_v;
    const json = switch (builtin.os.tag) {
        .windows => try runner.exec(std.testing.allocator, .{
            .command = "cmd",
            .args = &.{ "/c", "exit", "7" },
            .timeout_ms = 10_000,
        }),
        else => try runner.exec(std.testing.allocator, .{
            .command = "sh",
            .args = &.{ "-c", "exit 7" },
            .timeout_ms = 10_000,
        }),
    };
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exit_code\":7") != null);
}
