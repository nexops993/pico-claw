const std = @import("std");

// ---------------------------------------------------------------------------
// Task and step state machines
// ---------------------------------------------------------------------------

/// Lifecycle state of one task run. A task is one `Conversation.send` call:
/// retrieval, planning, execution, provider interaction, and learning.
///
/// Only the transitions listed in `canTransitionTask` are accepted, so a task
/// can never jump from `pending` to `completed` or be mutated after it
/// reached a terminal state.
pub const TaskState = enum {
    pending,
    running,
    completed,
    failed,

    pub fn name(self: TaskState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
        };
    }

    pub fn isTerminal(self: TaskState) bool {
        return self == .completed or self == .failed;
    }
};

/// Lifecycle state of one plan step or provider tool call. `replayed` marks a
/// step/call that already completed in an earlier failed run and was skipped
/// through the task journal instead of being executed again.
pub const StepState = enum {
    pending,
    running,
    completed,
    failed,
    replayed,

    pub fn name(self: StepState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .replayed => "replayed",
        };
    }

    /// States that satisfy "this work is done and must not run again".
    pub fn isDone(self: StepState) bool {
        return self == .completed or self == .replayed;
    }
};

pub const StateError = error{InvalidTransition};

pub fn canTransitionTask(from: TaskState, to: TaskState) bool {
    return switch (from) {
        .pending => to == .running,
        .running => to == .completed or to == .failed,
        else => false,
    };
}

pub fn canTransitionStep(from: StepState, to: StepState) bool {
    return switch (from) {
        .pending => to == .running or to == .replayed,
        .running => to == .completed or to == .failed,
        else => false,
    };
}

pub fn transitionTask(state: *TaskState, to: TaskState) StateError!void {
    if (!canTransitionTask(state.*, to)) return error.InvalidTransition;
    state.* = to;
}

pub fn transitionStep(state: *StepState, to: StepState) StateError!void {
    if (!canTransitionStep(state.*, to)) return error.InvalidTransition;
    state.* = to;
}

// ---------------------------------------------------------------------------
// Normalized errors
// ---------------------------------------------------------------------------

/// Coarse failure categories. Task records store only the category and the
/// stable compiler error identifier (`@errorName`); free-form error messages
/// are never persisted, so no URL, key, or provider payload can leak into the
/// journal.
pub const ErrorKind = enum {
    plan,
    tool,
    provider,
    internal,

    pub fn name(self: ErrorKind) []const u8 {
        return switch (self) {
            .plan => "plan",
            .tool => "tool",
            .provider => "provider",
            .internal => "internal",
        };
    }
};

pub const NormalizedError = struct {
    kind: ErrorKind,
    code: []const u8,

    pub fn normalize(err: anyerror) NormalizedError {
        return .{ .kind = classifyError(err), .code = @errorName(err) };
    }
};

pub fn classifyError(err: anyerror) ErrorKind {
    return switch (err) {
        error.InvalidTask,
        error.TaskTooLong,
        error.InvalidStep,
        error.StepTooLong,
        error.PlanLimitExceeded,
        error.EmptyPlan,
        error.ExecutionLimitExceeded,
        error.InvalidTransition,
        => .plan,

        error.ToolNotFound,
        error.MalformedToolCall,
        error.ToolCallLimitExceeded,
        => .tool,

        error.ApiKeyNotFound,
        error.ApiRequestFailed,
        error.InvalidApiResponse,
        error.ProviderFailed,
        error.ProviderUnavailableInTest,
        => .provider,

        else => .internal,
    };
}

/// Whether a bounded retry may attempt the failed operation again. Missing
/// configuration is never retried; provider transport and response failures
/// are.
pub fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.ApiKeyNotFound => false,
        else => classifyError(err) == .provider,
    };
}

// ---------------------------------------------------------------------------
// Bounded retry policy
// ---------------------------------------------------------------------------

pub const hard_max_attempts: u8 = 5;

pub const RetryPolicy = struct {
    /// Total attempts per task, including the first. The default of 1 keeps
    /// pre-M2 behavior (no retries) for existing configurations.
    max_attempts: u8 = 1,

    /// Clamp into the safe range; 0 and negative values mean "default".
    pub fn sanitized(self: RetryPolicy) RetryPolicy {
        return .{ .max_attempts = std.math.clamp(self.max_attempts, 1, hard_max_attempts) };
    }

    /// Convert a raw JSON number into a policy. Invalid values fall back to
    /// the default instead of failing startup, matching owner budgets.
    pub fn fromRaw(value: ?f64) RetryPolicy {
        const raw = value orelse return .{};
        if (!std.math.isFinite(raw) or raw < 1) return .{};
        if (raw >= @as(f64, @floatFromInt(hard_max_attempts)))
            return .{ .max_attempts = hard_max_attempts };
        return .{ .max_attempts = @intFromFloat(raw) };
    }
};

// ---------------------------------------------------------------------------
// Route labels
// ---------------------------------------------------------------------------

/// Which planner route a task took. Derived from the leading plan step tool;
/// recorded for observability, never used to change behavior.
pub const Route = enum {
    reasoning,
    calculator,
    filesystem,
    other,

    pub fn name(self: Route) []const u8 {
        return switch (self) {
            .reasoning => "reasoning",
            .calculator => "calculator",
            .filesystem => "filesystem",
            .other => "other",
        };
    }

    pub fn forPlanTool(tool_name: ?[]const u8) Route {
        const tool = tool_name orelse return .reasoning;
        if (std.mem.eql(u8, tool, "calculator")) return .calculator;
        if (std.mem.eql(u8, tool, "filesystem")) return .filesystem;
        return .other;
    }
};

// ---------------------------------------------------------------------------
// Stable, content-free identities
// ---------------------------------------------------------------------------

/// Stable key for a task: the hash of the trimmed input text. Task content is
/// never stored in records; the hash only lets a re-sent task find the
/// checkpoint of its previous failed run.
pub fn keyHash(input: []const u8) u64 {
    return std.hash.Wyhash.hash(0, std.mem.trim(u8, input, " \t\r\n"));
}

/// Stable identity of a provider tool call: hash of the tool input, so a
/// retried identical call can be recognized without storing its content.
pub fn callInputHash(input: []const u8) u64 {
    return std.hash.Wyhash.hash(0, input);
}

/// Monotonic timestamp for latency measurement, or null when no clock is
/// wired (durations are then recorded as 0).
pub fn monotonicNow(io: ?std.Io) ?std.Io.Timestamp {
    const clock = io orelse return null;
    return std.Io.Timestamp.now(clock, .awake);
}

/// Milliseconds between `started` and now; 0 when no clock is wired.
pub fn elapsedMs(io: ?std.Io, started: ?std.Io.Timestamp) i64 {
    const begin = started orelse return 0;
    const clock = io orelse return 0;
    return begin.durationTo(std.Io.Timestamp.now(clock, .awake)).toMilliseconds();
}

/// Wall-clock timestamp in milliseconds since the Unix epoch.
pub fn wallClockMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn toolNameHash(tool_name: ?[]const u8) u64 {
    return std.hash.Wyhash.hash(0, tool_name orelse "");
}

fn sameTool(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    if (left == null) return true;
    return std.mem.eql(u8, left.?, right.?);
}

// ---------------------------------------------------------------------------
// Task record
// ---------------------------------------------------------------------------

pub const max_plan_steps = 32;
pub const max_tool_calls = 48;

pub const StepRecord = struct {
    step_id: usize,
    tool_name: ?[]u8,
    state: StepState = .pending,
    duration_ms: i64 = 0,
};

pub const CallRecord = struct {
    tool_name: []u8,
    input_hash: u64,
    state: StepState,
    duration_ms: i64 = 0,
};

pub const AttemptRecord = struct {
    attempt: u8,
    ok: bool,
    duration_ms: i64,
    input_bytes: usize = 0,
    output_bytes: usize = 0,
    error_code: ?[]u8 = null,
};

/// Why a task was (or was not) escalated to a teacher model. `provider_failure`
/// is the only escalation trigger in M3: it is measured (the primary provider
/// exhausted its bounded attempts with a provider-class error) rather than
/// guessed. The other values are the explicit, loggable skip reasons.
pub const EscalationReason = enum {
    provider_failure,
    no_failure,
    disabled,
    local_only,
    not_provider_failure,
    budget_exhausted,
    request_too_large,

    pub fn name(self: EscalationReason) []const u8 {
        return switch (self) {
            .provider_failure => "provider_failure",
            .no_failure => "no_failure",
            .disabled => "disabled",
            .local_only => "local_only",
            .not_provider_failure => "not_provider_failure",
            .budget_exhausted => "budget_exhausted",
            .request_too_large => "request_too_large",
        };
    }
};

/// One routing decision per task run: whether the teacher was consulted, why,
/// which teacher model was used, how long it took, and the byte totals and
/// stable error code of that call. Model labels come from configuration and
/// are never credentials; the compact teacher request is never recorded.
pub const EscalationRecord = struct {
    escalated: bool,
    reason: EscalationReason,
    model_label: ?[]u8 = null,
    ok: bool = false,
    duration_ms: i64 = 0,
    input_bytes: usize = 0,
    output_bytes: usize = 0,
    error_code: ?[]u8 = null,
};

/// Observability record for one task run. Holds structured, bounded metadata
/// only: states, counts, durations, byte totals, and stable identifiers. No
/// task text, tool input, tool output, or provider payload is ever stored.
///
/// Recording is best-effort: out-of-memory and invalid transitions drop the
/// record entry instead of failing the task.
pub const TaskRecord = struct {
    allocator: std.mem.Allocator,
    id: u64 = 0,
    key_hash: u64 = 0,
    state: TaskState = .pending,
    route: Route = .reasoning,
    planned_steps: usize = 0,
    started_at_ms: i64 = 0,
    ended_at_ms: i64 = 0,
    error_kind: ?ErrorKind = null,
    error_code: ?[]u8 = null,
    escalation: ?EscalationRecord = null,

    steps: std.ArrayList(StepRecord) = .empty,
    calls: std.ArrayList(CallRecord) = .empty,
    attempts: std.ArrayList(AttemptRecord) = .empty,

    pub fn begin(allocator: std.mem.Allocator, key_hash: u64, started_at_ms: i64) TaskRecord {
        return .{
            .allocator = allocator,
            .key_hash = key_hash,
            .started_at_ms = started_at_ms,
        };
    }

    pub fn deinit(self: *TaskRecord) void {
        for (self.steps.items) |step| {
            if (step.tool_name) |name| self.allocator.free(name);
        }
        for (self.calls.items) |call| {
            self.allocator.free(call.tool_name);
        }
        for (self.attempts.items) |attempt| {
            if (attempt.error_code) |code| self.allocator.free(code);
        }
        if (self.error_code) |code| self.allocator.free(code);
        if (self.escalation) |*escalation| {
            if (escalation.model_label) |label| self.allocator.free(label);
            if (escalation.error_code) |code| self.allocator.free(code);
        }
        self.steps.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.attempts.deinit(self.allocator);
    }

    pub fn start(self: *TaskRecord) StateError!void {
        try transitionTask(&self.state, .running);
    }

    pub fn finish(self: *TaskRecord, err: ?anyerror, ended_at_ms: i64) (StateError || std.mem.Allocator.Error)!void {
        if (err) |value| {
            try transitionTask(&self.state, .failed);
            self.error_kind = classifyError(value);
            const owned = try self.allocator.dupe(u8, @errorName(value));
            if (self.error_code) |old| self.allocator.free(old);
            self.error_code = owned;
        } else {
            try transitionTask(&self.state, .completed);
        }
        self.ended_at_ms = ended_at_ms;
    }

    pub fn setRoute(self: *TaskRecord, route: Route) void {
        self.route = route;
    }

    pub fn setPlannedSteps(self: *TaskRecord, count: usize) void {
        self.planned_steps = count;
    }

    pub fn latencyMs(self: *const TaskRecord) i64 {
        return self.ended_at_ms - self.started_at_ms;
    }

    /// Record a plan step transition. Called with `.running` before the step
    /// executes and with `.completed`/`.failed` afterwards; a single call with
    /// `.replayed` records a checkpointed skip. Invalid transitions are
    /// dropped.
    pub fn noteStep(
        self: *TaskRecord,
        step_id: usize,
        tool_name: ?[]const u8,
        state: StepState,
        duration_ms: i64,
    ) void {
        var index = self.steps.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.steps.items[index];
            if (entry.step_id != step_id) continue;
            if (!sameTool(entry.tool_name, tool_name)) continue;
            transitionStep(&entry.state, state) catch return;
            entry.duration_ms = duration_ms;
            return;
        }

        const owned_name: ?[]u8 = if (tool_name) |name|
            self.allocator.dupe(u8, name) catch return
        else
            null;
        self.steps.append(self.allocator, .{
            .step_id = step_id,
            .tool_name = owned_name,
            .state = .pending,
            .duration_ms = 0,
        }) catch {
            if (owned_name) |name| self.allocator.free(name);
            return;
        };
        const entry = &self.steps.items[self.steps.items.len - 1];
        transitionStep(&entry.state, state) catch {};
        entry.duration_ms = duration_ms;
    }

    /// Append a step that already completed in a previous failed run (resume
    /// seeding). These entries make the recorder report the step as done.
    pub fn seedStep(self: *TaskRecord, step_id: usize, tool_name: ?[]const u8) !void {
        const owned_name: ?[]u8 = if (tool_name) |name|
            try self.allocator.dupe(u8, name)
        else
            null;
        errdefer if (owned_name) |name| self.allocator.free(name);
        try self.steps.append(self.allocator, .{
            .step_id = step_id,
            .tool_name = owned_name,
            .state = .replayed,
            .duration_ms = 0,
        });
    }

    /// Record a resolved provider tool call (never `pending`/`running`: calls
    /// are recorded exactly once, after they resolve).
    pub fn noteCall(
        self: *TaskRecord,
        tool_name: []const u8,
        input_hash: u64,
        state: StepState,
        duration_ms: i64,
    ) void {
        if (!state.isDone() and state != .failed) return;
        const owned = self.allocator.dupe(u8, tool_name) catch return;
        self.calls.append(self.allocator, .{
            .tool_name = owned,
            .input_hash = input_hash,
            .state = state,
            .duration_ms = duration_ms,
        }) catch self.allocator.free(owned);
    }

    pub fn seedCall(self: *TaskRecord, tool_name: []const u8, input_hash: u64) !void {
        const owned = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(owned);
        try self.calls.append(self.allocator, .{
            .tool_name = owned,
            .input_hash = input_hash,
            .state = .replayed,
            .duration_ms = 0,
        });
    }

    // History loading (journal restore): entries are appended with their
    // recorded state directly, bypassing the transition rules, because they
    // describe work that already resolved in an earlier process.

    pub fn restoreStep(
        self: *TaskRecord,
        step_id: usize,
        tool_name: ?[]const u8,
        state: StepState,
        duration_ms: i64,
    ) !void {
        const owned_name: ?[]u8 = if (tool_name) |name|
            try self.allocator.dupe(u8, name)
        else
            null;
        errdefer if (owned_name) |name| self.allocator.free(name);
        try self.steps.append(self.allocator, .{
            .step_id = step_id,
            .tool_name = owned_name,
            .state = state,
            .duration_ms = duration_ms,
        });
    }

    pub fn restoreCall(
        self: *TaskRecord,
        tool_name: []const u8,
        input_hash: u64,
        state: StepState,
        duration_ms: i64,
    ) !void {
        const owned = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(owned);
        try self.calls.append(self.allocator, .{
            .tool_name = owned,
            .input_hash = input_hash,
            .state = state,
            .duration_ms = duration_ms,
        });
    }

    pub fn restoreAttempt(
        self: *TaskRecord,
        attempt: u8,
        ok: bool,
        duration_ms: i64,
        input_bytes: usize,
        output_bytes: usize,
        error_code: ?[]const u8,
    ) !void {
        const owned_code: ?[]u8 = if (error_code) |code|
            try self.allocator.dupe(u8, code)
        else
            null;
        errdefer if (owned_code) |code| self.allocator.free(code);
        try self.attempts.append(self.allocator, .{
            .attempt = attempt,
            .ok = ok,
            .duration_ms = duration_ms,
            .input_bytes = input_bytes,
            .output_bytes = output_bytes,
            .error_code = owned_code,
        });
    }

    pub fn restoreEscalation(
        self: *TaskRecord,
        escalated: bool,
        reason: EscalationReason,
        model_label: ?[]const u8,
        ok: bool,
        duration_ms: i64,
        input_bytes: usize,
        output_bytes: usize,
        error_code: ?[]const u8,
    ) !void {
        var record = EscalationRecord{
            .escalated = escalated,
            .reason = reason,
            .ok = ok,
            .duration_ms = duration_ms,
            .input_bytes = input_bytes,
            .output_bytes = output_bytes,
        };
        if (model_label) |label| record.model_label = try self.allocator.dupe(u8, label);
        errdefer if (record.model_label) |label| self.allocator.free(label);
        if (error_code) |code| record.error_code = try self.allocator.dupe(u8, code);
        self.setEscalation(record);
    }

    /// Record one provider attempt with its latency and request/reply byte
    /// totals (usage without content).
    pub fn noteAttempt(
        self: *TaskRecord,
        attempt: u8,
        ok: bool,
        duration_ms: i64,
        input_bytes: usize,
        output_bytes: usize,
        err: ?anyerror,
    ) void {
        const owned_code: ?[]u8 = if (err) |value|
            self.allocator.dupe(u8, @errorName(value)) catch return
        else
            null;
        self.attempts.append(self.allocator, .{
            .attempt = attempt,
            .ok = ok,
            .duration_ms = duration_ms,
            .input_bytes = input_bytes,
            .output_bytes = output_bytes,
            .error_code = owned_code,
        }) catch {
            if (owned_code) |code| self.allocator.free(code);
        };
    }

    /// Record a denied routing decision (best-effort; replaces any previous
    /// escalation record for this run).
    pub fn noteEscalationSkipped(self: *TaskRecord, reason: EscalationReason) void {
        self.setEscalation(.{ .escalated = false, .reason = reason });
    }

    /// Record a teacher consultation. Labels and codes are duplicated from
    /// configuration values and stable error identifiers, never from message
    /// content.
    pub fn noteEscalation(
        self: *TaskRecord,
        model_label: []const u8,
        ok: bool,
        duration_ms: i64,
        input_bytes: usize,
        output_bytes: usize,
        err: ?anyerror,
    ) void {
        var record = EscalationRecord{
            .escalated = true,
            .reason = .provider_failure,
            .ok = ok,
            .duration_ms = duration_ms,
            .input_bytes = input_bytes,
            .output_bytes = output_bytes,
        };
        record.model_label = self.allocator.dupe(u8, model_label) catch null;
        if (err) |value| record.error_code = self.allocator.dupe(u8, @errorName(value)) catch null;
        self.setEscalation(record);
    }

    fn setEscalation(self: *TaskRecord, record: EscalationRecord) void {
        if (self.escalation) |*existing| {
            if (existing.model_label) |label| self.allocator.free(label);
            if (existing.error_code) |code| self.allocator.free(code);
        }
        self.escalation = record;
    }

    /// Escalations attempted for this run (bounded to 1 by the router).
    pub fn escalationCount(self: *const TaskRecord) usize {
        if (self.escalation) |escalation| {
            return if (escalation.escalated) 1 else 0;
        }
        return 0;
    }

    pub fn escalationReason(self: *const TaskRecord) ?EscalationReason {
        if (self.escalation) |escalation| return escalation.reason;
        return null;
    }

    pub fn wasStepCompleted(self: *const TaskRecord, step_id: usize, tool_name: ?[]const u8) bool {
        for (self.steps.items) |entry| {
            if (entry.step_id != step_id) continue;
            if (!sameTool(entry.tool_name, tool_name)) continue;
            if (entry.state.isDone()) return true;
        }
        return false;
    }

    pub fn wasCallCompleted(self: *const TaskRecord, tool_name: []const u8, input_hash: u64) bool {
        for (self.calls.items) |entry| {
            if (entry.input_hash != input_hash) continue;
            if (!std.mem.eql(u8, entry.tool_name, tool_name)) continue;
            if (entry.state.isDone()) return true;
        }
        return false;
    }

    pub fn stepCount(self: *const TaskRecord) usize {
        return self.steps.items.len;
    }

    pub fn completedStepCount(self: *const TaskRecord) usize {
        return self.countSteps(.completed);
    }

    pub fn failedStepCount(self: *const TaskRecord) usize {
        return self.countSteps(.failed);
    }

    pub fn replayedStepCount(self: *const TaskRecord) usize {
        return self.countSteps(.replayed);
    }

    pub fn toolCallCount(self: *const TaskRecord) usize {
        return self.calls.items.len;
    }

    pub fn attemptCount(self: *const TaskRecord) usize {
        return self.attempts.items.len;
    }

    pub fn providerInputBytes(self: *const TaskRecord) usize {
        var total: usize = 0;
        for (self.attempts.items) |attempt| total += attempt.input_bytes;
        return total;
    }

    pub fn providerOutputBytes(self: *const TaskRecord) usize {
        var total: usize = 0;
        for (self.attempts.items) |attempt| total += attempt.output_bytes;
        return total;
    }

    fn countSteps(self: *const TaskRecord, state: StepState) usize {
        var total: usize = 0;
        for (self.steps.items) |entry| {
            if (entry.state == state) total += 1;
        }
        return total;
    }

    // Recorder adapter for Executor and Brain, following the same vtable
    // pattern as `ChatHandler` and `Tool`.

    pub fn recorder(self: *TaskRecord) Recorder {
        return .{
            .context = self,
            .sawStepFn = sawStepAdapter,
            .noteStepFn = noteStepAdapter,
            .sawCallFn = sawCallAdapter,
            .noteCallFn = noteCallAdapter,
        };
    }

    fn sawStepAdapter(context: *anyopaque, step_id: usize, tool_name: ?[]const u8) bool {
        const self: *TaskRecord = @ptrCast(@alignCast(context));
        return self.wasStepCompleted(step_id, tool_name);
    }

    fn noteStepAdapter(
        context: *anyopaque,
        step_id: usize,
        tool_name: ?[]const u8,
        state: StepState,
        duration_ms: i64,
    ) void {
        const self: *TaskRecord = @ptrCast(@alignCast(context));
        self.noteStep(step_id, tool_name, state, duration_ms);
    }

    fn sawCallAdapter(context: *anyopaque, tool_name: []const u8, input_hash: u64) bool {
        const self: *TaskRecord = @ptrCast(@alignCast(context));
        return self.wasCallCompleted(tool_name, input_hash);
    }

    fn noteCallAdapter(
        context: *anyopaque,
        tool_name: []const u8,
        input_hash: u64,
        state: StepState,
        duration_ms: i64,
    ) void {
        const self: *TaskRecord = @ptrCast(@alignCast(context));
        self.noteCall(tool_name, input_hash, state, duration_ms);
    }
};

/// Callbacks Executor and Brain use to consult and update the task record.
/// `sawStep`/`sawCall` let callers skip work that already completed; the
/// `note*` callbacks report resolved work with its duration.
pub const Recorder = struct {
    context: *anyopaque,
    sawStepFn: *const fn (*anyopaque, step_id: usize, tool_name: ?[]const u8) bool,
    noteStepFn: *const fn (*anyopaque, step_id: usize, tool_name: ?[]const u8, state: StepState, duration_ms: i64) void,
    sawCallFn: *const fn (*anyopaque, tool_name: []const u8, input_hash: u64) bool,
    noteCallFn: *const fn (*anyopaque, tool_name: []const u8, input_hash: u64, state: StepState, duration_ms: i64) void,

    pub fn sawStep(self: Recorder, step_id: usize, tool_name: ?[]const u8) bool {
        return self.sawStepFn(self.context, step_id, tool_name);
    }

    pub fn noteStep(
        self: Recorder,
        step_id: usize,
        tool_name: ?[]const u8,
        state: StepState,
        duration_ms: i64,
    ) void {
        self.noteStepFn(self.context, step_id, tool_name, state, duration_ms);
    }

    pub fn sawCall(self: Recorder, tool_name: []const u8, input_hash: u64) bool {
        return self.sawCallFn(self.context, tool_name, input_hash);
    }

    pub fn noteCall(
        self: Recorder,
        tool_name: []const u8,
        input_hash: u64,
        state: StepState,
        duration_ms: i64,
    ) void {
        self.noteCallFn(self.context, tool_name, input_hash, state, duration_ms);
    }
};

/// Marker the executor substitutes for a step that was skipped through the
/// checkpoint. Deterministic and bounded; no recorded content is restored.
pub const step_replay_marker =
    "[replayed: step {d} ({s}) already completed for this task; result withheld from the task journal]";

/// Marker the brain substitutes for a tool call that was skipped through the
/// checkpoint.
pub const call_replay_marker =
    "[replayed: tool call already completed for this task; result withheld from the task journal]";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "task transitions are explicit and invalid ones are rejected" {
    var state: TaskState = .pending;
    try transitionTask(&state, .running);
    try std.testing.expectEqual(TaskState.running, state);
    try transitionTask(&state, .completed);
    try std.testing.expectEqual(TaskState.completed, state);
    try std.testing.expect(state.isTerminal());

    try std.testing.expectError(error.InvalidTransition, transitionTask(&state, .running));
    var pending: TaskState = .pending;
    try std.testing.expectError(error.InvalidTransition, transitionTask(&pending, .completed));
    var failed: TaskState = .failed;
    try std.testing.expectError(error.InvalidTransition, transitionTask(&failed, .running));
    try std.testing.expectEqual(TaskState.completed, state);
}

test "step transitions are explicit and invalid ones are rejected" {
    var state: StepState = .pending;
    try transitionStep(&state, .running);
    try transitionStep(&state, .completed);
    try std.testing.expect(state.isDone());

    try std.testing.expectError(error.InvalidTransition, transitionStep(&state, .running));
    var pending_step: StepState = .pending;
    try std.testing.expectError(error.InvalidTransition, transitionStep(&pending_step, .completed));
    var failed_step: StepState = .failed;
    try std.testing.expectError(error.InvalidTransition, transitionStep(&failed_step, .replayed));

    var replayed: StepState = .pending;
    try transitionStep(&replayed, .replayed);
    try std.testing.expect(replayed.isDone());
}

test "errors normalize to a kind and stable code without free-form content" {
    const normalized = NormalizedError.normalize(error.ApiRequestFailed);
    try std.testing.expectEqual(ErrorKind.provider, normalized.kind);
    try std.testing.expectEqualStrings("ApiRequestFailed", normalized.code);

    try std.testing.expectEqual(ErrorKind.plan, classifyError(error.PlanLimitExceeded));
    try std.testing.expectEqual(ErrorKind.tool, classifyError(error.ToolNotFound));
    try std.testing.expectEqual(ErrorKind.internal, classifyError(error.Unexpected));

    try std.testing.expect(isRetryable(error.ApiRequestFailed));
    try std.testing.expect(isRetryable(error.InvalidApiResponse));
    try std.testing.expect(!isRetryable(error.ApiKeyNotFound));
    try std.testing.expect(!isRetryable(error.PlanLimitExceeded));
    try std.testing.expect(!isRetryable(error.ToolNotFound));
}

test "retry policy clamps raw values into the bounded range" {
    try std.testing.expectEqual(@as(u8, 1), (RetryPolicy{}).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, 1), RetryPolicy.fromRaw(null).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, 1), RetryPolicy.fromRaw(0).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, 1), RetryPolicy.fromRaw(-3).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, 3), RetryPolicy.fromRaw(3).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, hard_max_attempts), RetryPolicy.fromRaw(99).sanitized().max_attempts);
    try std.testing.expectEqual(@as(u8, 1), RetryPolicy.fromRaw(std.math.nan(f64)).sanitized().max_attempts);
}

test "task record tracks steps calls attempts and resume queries" {
    var record = TaskRecord.begin(std.testing.allocator, 42, 1000);
    defer record.deinit();

    try record.start();
    try std.testing.expectEqual(TaskState.running, record.state);
    try std.testing.expectEqual(@as(i64, 0), record.ended_at_ms);

    record.setRoute(.calculator);
    record.setPlannedSteps(2);

    // A step that runs and completes is resumable.
    record.noteStep(1, "calculator", .running, 0);
    record.noteStep(1, "calculator", .completed, 5);
    try std.testing.expect(record.wasStepCompleted(1, "calculator"));

    // A step that failed is not resumable.
    record.noteStep(2, "calculator", .running, 0);
    record.noteStep(2, "calculator", .failed, 7);
    try std.testing.expect(!record.wasStepCompleted(2, "calculator"));
    try std.testing.expectEqual(@as(usize, 1), record.completedStepCount());
    try std.testing.expectEqual(@as(usize, 1), record.failedStepCount());

    // Tool calls resolve once and are resumable by content hash.
    record.noteCall("filesystem", 7, .completed, 9);
    try std.testing.expect(record.wasCallCompleted("filesystem", 7));
    try std.testing.expect(!record.wasCallCompleted("filesystem", 8));
    try std.testing.expectEqual(@as(usize, 1), record.toolCallCount());

    // Resume seeding marks the prior work as replayed and still resumable.
    try record.seedStep(1, "calculator");
    try record.seedCall("filesystem", 7);
    try std.testing.expectEqual(@as(usize, 1), record.replayedStepCount());
    try std.testing.expect(record.wasStepCompleted(1, "calculator"));
    try std.testing.expect(record.wasCallCompleted("filesystem", 7));

    record.noteAttempt(1, false, 10, 100, 0, error.ApiRequestFailed);
    record.noteAttempt(2, true, 20, 120, 30, null);
    try std.testing.expectEqual(@as(usize, 2), record.attemptCount());
    try std.testing.expectEqual(@as(usize, 220), record.providerInputBytes());
    try std.testing.expectEqual(@as(usize, 30), record.providerOutputBytes());

    try record.finish(null, 1050);
    try std.testing.expectEqual(TaskState.completed, record.state);
    try std.testing.expectEqual(@as(i64, 50), record.latencyMs());
    try std.testing.expect(record.error_code == null);

    try std.testing.expectError(error.InvalidTransition, record.finish(error.ProviderFailed, 1100));
    try std.testing.expectEqual(TaskState.completed, record.state);
}

test "recorder adapter reports and updates the record" {
    var record = TaskRecord.begin(std.testing.allocator, 1, 0);
    defer record.deinit();
    try record.start();
    const adapter = record.recorder();

    try std.testing.expect(!adapter.sawStep(3, "echo"));
    adapter.noteStep(3, "echo", .running, 0);
    adapter.noteStep(3, "echo", .completed, 2);
    try std.testing.expect(adapter.sawStep(3, "echo"));

    try std.testing.expect(!adapter.sawCall("echo", 5));
    adapter.noteCall("echo", 5, .completed, 3);
    try std.testing.expect(adapter.sawCall("echo", 5));

    // Reasoning steps (no tool) use the empty-name identity on both sides.
    adapter.noteStep(4, null, .running, 0);
    adapter.noteStep(4, null, .completed, 1);
    try std.testing.expect(adapter.sawStep(4, null));
}

test "escalation decisions are recorded with reasons and bounded per run" {
    var record = TaskRecord.begin(std.testing.allocator, 9, 0);
    defer record.deinit();
    try record.start();

    try std.testing.expectEqual(@as(usize, 0), record.escalationCount());
    try std.testing.expect(record.escalationReason() == null);

    // A denied decision is recorded with its explicit reason.
    record.noteEscalationSkipped(.local_only);
    try std.testing.expectEqual(@as(usize, 0), record.escalationCount());
    try std.testing.expectEqual(EscalationReason.local_only, record.escalationReason().?);
    try std.testing.expect(!record.escalation.?.escalated);

    // A successful consultation replaces it with the teacher outcome.
    record.noteEscalation("teacher-model", true, 250, 1000, 400, null);
    try std.testing.expectEqual(@as(usize, 1), record.escalationCount());
    try std.testing.expectEqual(EscalationReason.provider_failure, record.escalationReason().?);
    try std.testing.expect(record.escalation.?.escalated);
    try std.testing.expect(record.escalation.?.ok);
    try std.testing.expectEqual(@as(i64, 250), record.escalation.?.duration_ms);
    try std.testing.expectEqualStrings("teacher-model", record.escalation.?.model_label.?);
    try std.testing.expect(record.escalation.?.error_code == null);

    // A failed consultation keeps the teacher's stable error code only.
    record.noteEscalation("teacher-model", false, 90, 1000, 0, error.ApiRequestFailed);
    try std.testing.expectEqual(@as(usize, 1), record.escalationCount());
    try std.testing.expect(!record.escalation.?.ok);
    try std.testing.expectEqualStrings("ApiRequestFailed", record.escalation.?.error_code.?);
    try std.testing.expect(std.mem.indexOf(u8, record.escalation.?.model_label.?, "teacher") != null);
}
