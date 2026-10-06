//! Long-running job runtime.
//!
//! The HTTP server is single-threaded: any slow operation would freeze the
//! dashboard and every channel. Jobs move such work onto one bounded worker
//! thread with an explicit lifecycle, so nothing slow ever runs inside a
//! request and no background work is unmanaged.
//!
//! Contract (deliberately honest about what a thread can and cannot do):
//!
//! * States: `queued` → `running` → `completed` | `failed` | `timed_out`,
//!   with `cancelling` → `cancelled` for cooperative cancellation.
//! * Cancellation is cooperative. The job function polls `checkpoint()`;
//!   when it returns, the runtime records `cancelled`. A function that never
//!   checks finishes normally and is recorded as `completed` with
//!   `cancel_requested: true` — the runtime never claims a cancellation that
//!   did not happen. Only process-backed work can be killed forcibly, and
//!   that is the process runner's job, not this runtime's.
//! * Timeout is the same mechanism: past the deadline `checkpoint()` returns
//!   `error.TimedOut` and the job is recorded `timed_out`.
//! * A client disconnecting from an HTTP request never cancels a job: jobs
//!   are owned by the runtime, not by the connection. Only an explicit
//!   cancel (API/CLI) or shutdown moves a job out of its course.
//! * Shutdown is graceful: `deinit` stops the worker from taking new jobs,
//!   waits for the running job to finish, and marks everything still queued
//!   as `cancelled`. There is no orphan thread and no orphan job record.
//!
//! Every job is linked to a run in the observability store when one is
//! attached, so the run inspector shows the job's start, result, and state.

const std = @import("std");
const runs_mod = @import("runs.zig");

pub const max_jobs: usize = 128;
pub const poll_interval_ms: u64 = 20;

pub const State = enum {
    queued,
    starting,
    running,
    cancelling,
    cancelled,
    completed,
    failed,
    timed_out,

    pub fn name(self: State) []const u8 {
        return @tagName(self);
    }

    pub fn terminal(self: State) bool {
        return switch (self) {
            .cancelled, .completed, .failed, .timed_out => true,
            else => false,
        };
    }

    pub fn toRunState(self: State) runs_mod.RunState {
        return switch (self) {
            .cancelled => .cancelled,
            .completed => .completed,
            .failed => .failed,
            .timed_out => .timed_out,
            else => .failed,
        };
    }
};

pub const Kind = enum {
    artifact_generation,
    attachment_extraction,
    doctor,
    generic,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// Errors a job function may return to steer its own lifecycle. Any other
/// error marks the job `failed` with the error's name.
pub const ControlError = error{ Cancelled, TimedOut };

pub const max_title_len: usize = 96;

/// Handed to the job function. All scheduling decisions flow through
/// `checkpoint()`: return its errors unchanged and the runtime records an
/// honest final state.
pub const Context = struct {
    runtime: *Runtime,
    job: *Job,
    io: std.Io,

    pub fn cancelRequested(self: *const Context) bool {
        return self.job.cancel_requested.load(.acquire);
    }

    pub fn deadlineExceeded(self: *const Context) bool {
        if (self.job.deadline_ms == 0) return false;
        const elapsed = std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - self.job.started_ms;
        return elapsed > @as(i64, @intCast(self.job.deadline_ms));
    }

    pub fn elapsedMs(self: *const Context) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - self.job.started_ms;
    }

    /// Cancel if requested, time out if past the deadline, otherwise continue.
    pub fn checkpoint(self: *Context) ControlError!void {
        if (self.cancelRequested()) return error.Cancelled;
        if (self.deadlineExceeded()) return error.TimedOut;
    }

    /// Report progress (0..100). Values outside the range are clamped.
    pub fn setProgress(self: *Context, percent: u8) void {
        self.runtime.withJob(self.job, struct {
            fn apply(j: *Job, value: u8) void {
                j.progress = value;
            }
        }.apply, @min(percent, 100));
    }
};

/// A job function returns a caller-owned JSON payload on success. It must be
/// bounded in time (poll `checkpoint()`) and in memory.
pub const Fn = *const fn (ctx: *Context, allocator: std.mem.Allocator) anyerror![]u8;

pub const Job = struct {
    id: []u8,
    kind: Kind,
    title: []u8,
    state: State = .queued,
    created_ms: i64,
    started_ms: i64 = 0,
    completed_ms: i64 = 0,
    deadline_ms: u64 = 0,
    progress: u8 = 0,
    result: ?[]u8 = null,
    error_name: ?[]u8 = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    func: ?Fn = null,
    run_id: ?[]u8 = null,
    /// Opaque caller context, set at submit time and interpreted only by the
    /// job function itself; the runtime never dereferences or frees it.
    user: ?*anyopaque = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: std.ArrayList(*Job) = .empty,
    mutex: std.Io.Mutex = .init,
    shutdown_flag: bool = false,
    worker: ?std.Thread = null,
    runs: ?*runs_mod.Store = null,
    default_timeout_ms: u64,
    job_counter: usize = 0,

    /// Start the runtime and its single worker thread. The runtime is
    /// heap-allocated on purpose: the worker thread holds its address, so it
    /// must never move.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, default_timeout_ms: u64) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .default_timeout_ms = default_timeout_ms,
        };
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
        return self;
    }

    pub fn attachRuns(self: *Runtime, store: *runs_mod.Store) void {
        self.runs = store;
    }

    /// Graceful shutdown: stop accepting work, let the running job finish
    /// (it is bounded by its own checkpoints), cancel everything queued, and
    /// free all records. Never leaves a thread or a job behind.
    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown_flag = true;
        self.mutex.unlock(self.io);

        if (self.worker) |thread| thread.join();

        self.mutex.lockUncancelable(self.io);
        for (self.jobs.items) |job| {
            if (job.state == .queued or job.state == .starting) {
                job.state = .cancelled;
                job.completed_ms = wallClockMs(self.io);
            }
        }
        for (self.jobs.items) |job| self.destroyJob(job);
        self.jobs.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.allocator.destroy(self);
    }

    /// Queue a job. `timeout_ms == 0` means no deadline (still cancellable).
    /// `user` is handed back to the function via `ctx.job.user`.
    pub fn submit(
        self: *Runtime,
        kind: Kind,
        title: []const u8,
        timeout_ms: u64,
        func: Fn,
        user: ?*anyopaque,
    ) (std.mem.Allocator.Error || error{RuntimeShutdown})!*Job {
        self.mutex.lockUncancelable(self.io);
        const shut = self.shutdown_flag;
        self.mutex.unlock(self.io);
        if (shut) return error.RuntimeShutdown;

        var id_buf: [32]u8 = undefined;
        const id = try self.allocator.dupe(u8, std.fmt.bufPrint(
            &id_buf,
            "job-{d}",
            .{self.nextJobNumber()},
        ) catch "job");
        errdefer self.allocator.free(id);
        const owned_title = try self.allocator.dupe(u8, title[0..@min(title.len, max_title_len)]);
        errdefer self.allocator.free(owned_title);

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .id = id,
            .kind = kind,
            .title = owned_title,
            .created_ms = wallClockMs(self.io),
            .deadline_ms = timeout_ms,
            .func = func,
            .user = user,
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.evictLocked();
        try self.jobs.append(self.allocator, job);
        return job;
    }

    /// Request cancellation. `true` when the request was delivered to a job
    /// that had not finished yet.
    pub fn cancel(self: *Runtime, id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.findLocked(id) orelse return false;
        switch (job.state) {
            .queued, .starting => {
                job.state = .cancelled;
                job.completed_ms = wallClockMs(self.io);
                return true;
            },
            .running => {
                job.state = .cancelling;
                job.cancel_requested.store(true, .release);
                return true;
            },
            else => return false,
        }
    }

    pub fn find(self: *Runtime, id: []const u8) ?*Job {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.findLocked(id);
    }

    pub fn count(self: *Runtime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.jobs.items.len;
    }

    /// Snapshot one job's state (safe to poll from another thread).
    pub fn stateOf(self: *Runtime, id: []const u8) ?State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.findLocked(id) orelse return null;
        return job.state;
    }

    pub fn runningCount(self: *Runtime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var total: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state == .running or job.state == .starting or job.state == .cancelling) total += 1;
        }
        return total;
    }

    /// Apply a mutation to one job under the runtime lock (used by Context).
    fn withJob(self: *Runtime, job: *Job, comptime apply: fn (*Job, u8) void, value: u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        apply(job, value);
    }

    fn nextJobNumber(self: *Runtime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.job_counter += 1;
        return self.job_counter;
    }

    /// Worker main loop. Polls the queue on a short interval: simple, immune
    /// to missed wakeups, and fast enough for operations that take seconds.
    fn workerLoop(self: *Runtime) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.shutdown_flag) {
                self.mutex.unlock(self.io);
                return;
            }
            var next: ?*Job = null;
            for (self.jobs.items) |job| {
                if (job.state == .queued) {
                    next = job;
                    break;
                }
            }
            if (next) |job| {
                job.state = .running;
                job.started_ms = wallClockMs(self.io);
                self.mutex.unlock(self.io);
                self.runJob(job);
                continue;
            }
            self.mutex.unlock(self.io);
            self.io.sleep(.fromMilliseconds(@intCast(poll_interval_ms)), .awake) catch {};
        }
    }

    /// Execute one job and record its honest final state.
    fn runJob(self: *Runtime, job: *Job) void {
        var ctx = Context{ .runtime = self, .job = job, .io = self.io };

        if (self.runs) |runs| {
            const run = runs.begin(.{
                .model = "job",
                .provider = "runtime",
                .profile = job.kind.name(),
            }) catch null;
            if (run) |r| {
                runs.record(r, .job_start, job.title);
                self.mutex.lockUncancelable(self.io);
                job.run_id = self.allocator.dupe(u8, r.id) catch null;
                self.mutex.unlock(self.io);
            }
        }

        const outcome = job.func.?(&ctx, self.allocator);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        job.completed_ms = wallClockMs(self.io);
        job.progress = 100;
        if (outcome) |payload| {
            job.result = payload;
            job.state = .completed;
        } else |err| switch (err) {
            error.Cancelled => job.state = .cancelled,
            error.TimedOut => job.state = .timed_out,
            else => {
                job.state = .failed;
                job.error_name = self.allocator.dupe(u8, @errorName(err)) catch null;
            },
        }
        if (self.runs) |runs| {
            if (job.run_id) |run_id| {
                if (runs.find(run_id)) |r| {
                    var buf: [96]u8 = undefined;
                    const detail = std.fmt.bufPrint(&buf, "job {s} -> {s}", .{ job.id, job.state.name() }) catch "job finished";
                    runs.record(r, .job_result, detail);
                    runs.end(r, job.state.toRunState(), job.error_name);
                }
            }
        }
    }

    fn findLocked(self: *Runtime, id: []const u8) ?*Job {
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    /// Keep at most `max_jobs` records; only terminal jobs are evicted.
    fn evictLocked(self: *Runtime) void {
        while (self.jobs.items.len >= max_jobs) {
            var oldest: ?usize = null;
            for (self.jobs.items, 0..) |job, index| {
                if (job.state.terminal()) {
                    oldest = index;
                    break;
                }
            }
            const index = oldest orelse return;
            const job = self.jobs.orderedRemove(index);
            self.destroyJob(job);
        }
    }

    fn destroyJob(self: *Runtime, job: *Job) void {
        if (job.result) |payload| self.allocator.free(payload);
        if (job.error_name) |name| self.allocator.free(name);
        if (job.run_id) |run_id| self.allocator.free(run_id);
        self.allocator.free(job.id);
        self.allocator.free(job.title);
        self.allocator.destroy(job);
    }

    /// Serialize the inventory (summaries; results only in the detail view).
    pub fn writeListJson(self: *Runtime, writer: *std.json.Stringify) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try writer.beginObject();
        try writer.objectField("count");
        try writer.write(self.jobs.items.len);
        try writer.objectField("running");
        try writer.write(self.runningCountLocked());
        try writer.objectField("jobs");
        try writer.beginArray();
        for (self.jobs.items) |job| try renderJobJson(job, false, writer);
        try writer.endArray();
        try writer.endObject();
    }

    /// Serialize one job including its result payload; false when unknown.
    pub fn writeJobJson(self: *Runtime, id: []const u8, writer: *std.json.Stringify) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.findLocked(id) orelse return false;
        try renderJobJson(job, true, writer);
        return true;
    }

    fn runningCountLocked(self: *Runtime) usize {
        var total: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state == .running or job.state == .starting or job.state == .cancelling) total += 1;
        }
        return total;
    }
};

fn renderJobJson(job: *Job, include_result: bool, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(job.id);
    try writer.objectField("kind");
    try writer.write(job.kind.name());
    try writer.objectField("title");
    try writer.write(job.title);
    try writer.objectField("state");
    try writer.write(job.state.name());
    try writer.objectField("progress");
    try writer.write(job.progress);
    try writer.objectField("cancel_requested");
    try writer.write(job.cancel_requested.load(.acquire));
    try writer.objectField("created_ms");
    try writer.write(job.created_ms);
    try writer.objectField("started_ms");
    try writer.write(job.started_ms);
    try writer.objectField("completed_ms");
    try writer.write(job.completed_ms);
    try writer.objectField("run_id");
    if (job.run_id) |run_id| try writer.write(run_id) else try writer.write(null);
    try writer.objectField("error");
    if (job.error_name) |name| try writer.write(name) else try writer.write(null);
    if (include_result) {
        try writer.objectField("result");
        if (job.result) |payload| try writer.write(payload) else try writer.write(null);
    }
    try writer.endObject();
}

/// Job timestamps use the monotonic `.awake` clock so deadline math and
/// duration comparisons are always on the same time base.
fn wallClockMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn waitForState(runtime: *Runtime, id: []const u8, expected: State, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (waited < timeout_ms) {
        if (runtime.stateOf(id)) |state| {
            if (state == expected) return;
        } else return error.JobNotFound;
        runtime.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 5;
    }
    return error.TestUnexpectedResult;
}

fn echoJob(ctx: *Context, allocator: std.mem.Allocator) anyerror![]u8 {
    try ctx.checkpoint();
    ctx.setProgress(50);
    try ctx.checkpoint();
    return allocator.dupe(u8, "{\"echo\":true}");
}

test "job queues, runs, and completes with a real result" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 5_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "echo test", 5_000, echoJob, null);
    try waitForState(runtime, job.id, .completed, 3_000);

    const detail = runtime.find(job.id).?;
    try testing.expectEqual(State.completed, detail.state);
    try testing.expect(detail.result != null);
    try testing.expectEqualStrings("{\"echo\":true}", detail.result.?);
    try testing.expect(detail.completed_ms >= detail.started_ms);
    try testing.expectEqual(@as(u8, 100), detail.progress);
    try testing.expectEqual(@as(?bool, false), if (detail.cancel_requested.load(.acquire)) true else false);
}

test "job failure records the real error name" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 5_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "broken", 5_000, struct {
        fn run(_: *Context, _: std.mem.Allocator) anyerror![]u8 {
            return error.SimulatedFailure;
        }
    }.run, null);
    try waitForState(runtime, job.id, .failed, 3_000);

    const detail = runtime.find(job.id).?;
    try testing.expectEqual(State.failed, detail.state);
    try testing.expectEqualStrings("SimulatedFailure", detail.error_name.?);
    try testing.expect(detail.result == null);
}

// Shared atoms for the blocking-job tests (functions cannot capture).
var test_blocker_release = std.atomic.Value(bool).init(false);

fn blockerJob(_: *Context, allocator: std.mem.Allocator) anyerror![]u8 {
    // Occupy the worker until the test releases it. Bounded by the job's
    // own deadline in the runtime.
    while (!test_blocker_release.load(.acquire)) {
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return allocator.dupe(u8, "blocker");
}

fn neverRunsJob(_: *Context, _: std.mem.Allocator) anyerror![]u8 {
    return "";
}

test "cancelling a queued job prevents it from ever running" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 10_000);
    defer runtime.deinit();
    test_blocker_release.store(false, .release);
    defer test_blocker_release.store(true, .release);

    // Occupy the worker.
    const blocker = try runtime.submit(.generic, "blocker", 10_000, blockerJob, null);
    try waitForState(runtime, blocker.id, .running, 3_000);

    // The second job stays queued; cancel it there.
    const queued = try runtime.submit(.generic, "never runs", 10_000, neverRunsJob, null);
    try testing.expect(runtime.cancel(queued.id));
    try testing.expectEqual(State.cancelled, runtime.stateOf(queued.id).?);

    // Unknown ids are refused.
    try testing.expect(!runtime.cancel("job-999"));
    try testing.expectEqual(@as(?State, null), runtime.stateOf("job-999"));

    test_blocker_release.store(true, .release);
    try waitForState(runtime, blocker.id, .completed, 3_000);
}

test "cancelling a running job is cooperative and recorded honestly" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 10_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "cooperative", 10_000, struct {
        fn run(ctx: *Context, _: std.mem.Allocator) anyerror![]u8 {
            while (true) try ctx.checkpoint();
        }
    }.run, null);
    try waitForState(runtime, job.id, .running, 3_000);

    try testing.expect(runtime.cancel(job.id));
    try waitForState(runtime, job.id, .cancelled, 3_000);

    const detail = runtime.find(job.id).?;
    try testing.expectEqual(State.cancelled, detail.state);
    try testing.expect(detail.cancel_requested.load(.acquire));
    try testing.expect(detail.result == null);
}

test "a job past its deadline is recorded timed_out" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 10_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "too slow", 150, struct {
        fn run(ctx: *Context, _: std.mem.Allocator) anyerror![]u8 {
            while (true) try ctx.checkpoint();
        }
    }.run, null);

    try waitForState(runtime, job.id, .timed_out, 3_000);
    try testing.expectEqual(State.timed_out, runtime.stateOf(job.id).?);
}

test "a cancel request that the function ignores must not fake a cancellation" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 10_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "ignores cancel", 10_000, struct {
        fn run(_: *Context, allocator: std.mem.Allocator) anyerror![]u8 {
            // Deliberately ignores ctx: it finishes regardless.
            testing.io.sleep(.fromMilliseconds(80), .awake) catch {};
            return allocator.dupe(u8, "done");
        }
    }.run, null);
    try waitForState(runtime, job.id, .running, 3_000);
    _ = runtime.cancel(job.id);
    try waitForState(runtime, job.id, .completed, 3_000);

    const detail = runtime.find(job.id).?;
    try testing.expectEqual(State.completed, detail.state);
    try testing.expect(detail.cancel_requested.load(.acquire));
    try testing.expectEqualStrings("done", detail.result.?);
}

var test_queued_side_effect = std.atomic.Value(u32).init(0);

fn countingJob(_: *Context, _: std.mem.Allocator) anyerror![]u8 {
    _ = test_queued_side_effect.fetchAdd(1, .release);
    return "";
}

test "shutdown cancels queued jobs and never leaves work behind" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 10_000);
    test_blocker_release.store(false, .release);
    test_queued_side_effect.store(0, .release);

    const blocker = try runtime.submit(.generic, "blocker", 10_000, blockerJob, null);
    try waitForState(runtime, blocker.id, .running, 3_000);

    _ = try runtime.submit(.generic, "queued when shutdown", 10_000, countingJob, null);

    // Release the blocker so shutdown can join promptly, then shut down.
    // The queued job must be recorded cancelled, never executed.
    test_blocker_release.store(true, .release);
    runtime.deinit();
    try testing.expectEqual(@as(u32, 0), test_queued_side_effect.load(.acquire));
}

test "job run is linked to an observability run with matching state" {
    var runs_store = runs_mod.Store.init(testing.allocator, testing.io);
    defer runs_store.deinit();

    const runtime = try Runtime.init(testing.allocator, testing.io, 5_000);
    defer runtime.deinit();
    runtime.attachRuns(&runs_store);

    const job = try runtime.submit(.doctor, "linked", 5_000, echoJob, null);
    try waitForState(runtime, job.id, .completed, 3_000);

    const run_id = runtime.find(job.id).?.run_id.?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try testing.expect(try runs_store.writeRunJson(run_id, &stringify));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"state\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"kind\":\"job_start\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "linked") != null);
}

test "job JSON list and detail shapes are stable and parse" {
    const runtime = try Runtime.init(testing.allocator, testing.io, 5_000);
    defer runtime.deinit();

    const job = try runtime.submit(.generic, "json shape", 5_000, echoJob, null);
    try waitForState(runtime, job.id, .completed, 3_000);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try runtime.writeListJson(&stringify);
    const list = out.written();
    try testing.expect(std.mem.indexOf(u8, list, "\"kind\":\"generic\"") != null);
    // Results stay out of the list (bounded payloads) and live in the detail.
    try testing.expect(std.mem.indexOf(u8, list, "\"result\"") == null);

    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var one_stringify: std.json.Stringify = .{ .writer = &one.writer };
    try testing.expect(try runtime.writeJobJson(job.id, &one_stringify));
    try testing.expect(std.mem.indexOf(u8, one.written(), "\"result\":\"{\\\"echo\\\":true}\"") != null);

    var ghost: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ghost.deinit();
    var ghost_stringify: std.json.Stringify = .{ .writer = &ghost.writer };
    try testing.expectEqual(false, try runtime.writeJobJson("job-999", &ghost_stringify));
}

test "kind names round-trip through parse" {
    try testing.expectEqual(Kind.artifact_generation, Kind.parse("artifact_generation").?);
    try testing.expectEqual(Kind.attachment_extraction, Kind.parse("attachment_extraction").?);
    try testing.expectEqual(Kind.doctor, Kind.parse("doctor").?);
    try testing.expectEqual(@as(?Kind, null), Kind.parse("rm -rf"));
}
