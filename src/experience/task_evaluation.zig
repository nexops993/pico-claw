const std = @import("std");
const task = @import("../core/task.zig");
const proposal = @import("proposal.zig");

// ---------------------------------------------------------------------------
// Task evaluation (M4): measured facts from the M2/M3 task record.
//
// This is the *task* evaluation. It is deliberately separate from the M1
// response-quality heuristic (experience/evaluation.zig): everything here is a
// measured fact, and every derived value is labeled as a heuristic.
// ---------------------------------------------------------------------------

pub const TaskEvaluation = struct {
    task_id: u64 = 0,
    key_hash: u64 = 0,
    route: task.Route = .reasoning,
    state: task.TaskState = .pending,
    error_kind: ?task.ErrorKind = null,
    error_code: ?[]const u8 = null,
    attempts: usize = 0,
    escalations: usize = 0,
    replays: usize = 0,
    tool_calls: usize = 0,
    failed_steps: usize = 0,
    latency_ms: i64 = 0,
    provider_input_bytes: usize = 0,
    provider_output_bytes: usize = 0,
    /// Completed only because a retry or a teacher escalation was needed.
    degraded: bool = false,
};

/// Extract the measured facts of a finished task. Never called for a task
/// that is still running.
pub fn evaluateTask(record: *const task.TaskRecord) TaskEvaluation {
    const degraded = record.state == .completed and
        (record.attemptCount() > 1 or record.escalationCount() > 0);
    return .{
        .task_id = record.id,
        .key_hash = record.key_hash,
        .route = record.route,
        .state = record.state,
        .error_kind = record.error_kind,
        .error_code = if (record.error_code) |code| code else null,
        .attempts = record.attemptCount(),
        .escalations = record.escalationCount(),
        .replays = record.replayedStepCount(),
        .tool_calls = record.toolCallCount(),
        .failed_steps = record.failedStepCount(),
        .latency_ms = record.latencyMs(),
        .provider_input_bytes = record.providerInputBytes(),
        .provider_output_bytes = record.providerOutputBytes(),
        .degraded = degraded,
    };
}

// ---------------------------------------------------------------------------
// Confidence: strength-of-evidence heuristic, not a quality score
// ---------------------------------------------------------------------------

/// Evidence strength for a task-review proposal, derived deterministically
/// from measured facts and explained in `basis`. Capped below 1.0: a single
/// observed run never justifies full confidence, and this is not a model
/// quality metric. The basis strings are comptime so the derivation is fully
/// determined by the measured flags.
fn evidenceConfidence(evaluation: TaskEvaluation) struct { value: f64, basis: []const u8 } {
    var value: f64 = 0.4;
    const base = "single observed task run";
    const repeated = "; repeated provider attempts observed";
    const escalated = "; teacher escalation observed";
    const terminal = "; terminal failure with a stable error code";

    const attempts_multiple = evaluation.attempts > 1;
    const was_escalated = evaluation.escalations > 0;
    const was_failed = evaluation.state == .failed;

    const basis: []const u8 = if (attempts_multiple and was_escalated and was_failed)
        base ++ repeated ++ escalated ++ terminal
    else if (attempts_multiple and was_escalated)
        base ++ repeated ++ escalated
    else if (attempts_multiple and was_failed)
        base ++ repeated ++ terminal
    else if (was_escalated and was_failed)
        base ++ escalated ++ terminal
    else if (attempts_multiple)
        base ++ repeated
    else if (was_escalated)
        base ++ escalated
    else if (was_failed)
        base ++ terminal
    else
        base;

    if (attempts_multiple) value += 0.1;
    if (was_escalated) value += 0.2;
    if (was_failed) value += 0.1;
    if (value > 0.9) value = 0.9;
    return .{ .value = value, .basis = basis };
}

/// Describe the observed problem from measured facts only (error kinds and
/// codes, counts, bytes — never task or tool content).
pub fn describeProblem(allocator: std.mem.Allocator, evaluation: TaskEvaluation) ![]u8 {
    if (evaluation.state == .failed) {
        const kind = evaluation.error_kind orelse task.ErrorKind.internal;
        const code = evaluation.error_code orelse "unknown";
        return std.fmt.allocPrint(
            allocator,
            "task failed with {s}/{s} after {d} provider attempt(s) and {d} teacher escalation(s)",
            .{ kind.name(), code, evaluation.attempts, evaluation.escalations },
        );
    }
    if (evaluation.escalations > 0) {
        return std.fmt.allocPrint(
            allocator,
            "task completed only through teacher escalation after {d} provider attempt(s)",
            .{evaluation.attempts},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "task completed after {d} provider attempt(s)",
        .{evaluation.attempts},
    );
}

/// The deterministic follow-up suggestion for a task-review proposal.
pub fn describeSuggestion(allocator: std.mem.Allocator, evaluation: TaskEvaluation) ![]u8 {
    if (evaluation.state == .failed) {
        switch (evaluation.error_kind orelse task.ErrorKind.internal) {
            .provider => {
                if (evaluation.error_code) |code| {
                    if (std.mem.eql(u8, code, "ApiKeyNotFound")) {
                        return std.fmt.allocPrint(
                            allocator,
                            "set the provider API key (PICO_CLAW_API_KEY); authentication failures are never retried or escalated",
                            .{},
                        );
                    }
                }
                if (evaluation.escalations > 0) {
                    return std.fmt.allocPrint(
                        allocator,
                        "primary and teacher providers both failed for this task; check provider health, endpoints, and credentials before re-running",
                        .{},
                    );
                }
                return std.fmt.allocPrint(
                    allocator,
                    "if failures are transient, consider raising settings.task_max_attempts (observed attempts: {d}); never retry authentication or invalid-input failures",
                    .{evaluation.attempts},
                );
            },
            .tool => {
                return std.fmt.allocPrint(
                    allocator,
                    "a tool step failed ({d} failed step(s), {d} tool call(s)); inspect the failed step in the task journal and the tool input validation",
                    .{ evaluation.failed_steps, evaluation.tool_calls },
                );
            },
            .plan => {
                return std.fmt.allocPrint(
                    allocator,
                    "no valid plan was produced; review the task format against planner recognition rules",
                    .{},
                );
            },
            .internal => {
                return std.fmt.allocPrint(
                    allocator,
                    "unexpected internal error; capture the stable error code for a bug report",
                    .{},
                );
            },
        }
    }
    if (evaluation.escalations > 0) {
        return std.fmt.allocPrint(
            allocator,
            "the teacher answered what the primary model could not; investigate primary provider health before relying on escalation",
            .{},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "the primary provider needed {d} attempts; review provider stability and consider whether failures were transient",
        .{evaluation.attempts},
    );
}

/// Draft a follow-up proposal from measured facts, or null when there is
/// nothing worth proposing: a clean first-attempt success produces no
/// proposal, so the store never fills with trivial entries.
pub fn draftTaskProposal(
    allocator: std.mem.Allocator,
    evaluation: TaskEvaluation,
    created_at_ms: i64,
) !?proposal.ProposalDraft {
    if (evaluation.state != .completed and evaluation.state != .failed) return null;
    const clean_success = evaluation.state == .completed and
        !evaluation.degraded and evaluation.attempts <= 1;
    if (clean_success) return null;

    const confidence = evidenceConfidence(evaluation);
    const draft = proposal.ProposalDraft{
        .allocator = allocator,
        .kind = .task_review,
        .problem = try describeProblem(allocator, evaluation),
        .suggestion = try describeSuggestion(allocator, evaluation),
        .confidence = confidence.value,
        .confidence_basis = try std.fmt.allocPrint(
            allocator,
            "evidence-strength heuristic ({s}); not a model quality score",
            .{confidence.basis},
        ),
        .constraints = proposal.default_constraints,
        .evidence = .{
            .task_id = evaluation.task_id,
            .key_hash = evaluation.key_hash,
            .route = evaluation.route,
            .task_state = evaluation.state,
            .error_kind = evaluation.error_kind,
            .error_code = evaluation.error_code,
            .attempts = evaluation.attempts,
            .escalations = evaluation.escalations,
            .latency_ms = evaluation.latency_ms,
            .provider_input_bytes = evaluation.provider_input_bytes,
            .provider_output_bytes = evaluation.provider_output_bytes,
        },
        .created_at_ms = created_at_ms,
    };
    return draft;
}

/// Draft a lesson proposal from the M1 reflection/learning pipeline. The
/// lesson text is templated by that pipeline (never task or tool content),
/// and the confidence is carried over with an explicit basis naming the
/// heuristic that produced it.
pub fn draftLessonProposal(
    allocator: std.mem.Allocator,
    learning: *const @import("learning.zig").LearningEntry,
    created_at_ms: i64,
) !proposal.ProposalDraft {
    const problem = try std.fmt.allocPrint(
        allocator,
        "heuristic response evaluation scored {d:.2} for strategy '{s}'",
        .{ learning.score, learning.strategy },
    );
    const suggestion = try std.fmt.allocPrint(
        allocator,
        "{s}: if validated manually, apply this lesson under strategy '{s}' to the knowledge store: {s}",
        .{ learning.action.name(), learning.strategy, learning.lesson },
    );
    const basis = try std.fmt.allocPrint(
        allocator,
        "heuristic M1 response evaluation (score {d:.2}); not a measured quality metric",
        .{learning.score},
    );
    return .{
        .allocator = allocator,
        .kind = .lesson,
        .problem = problem,
        .suggestion = suggestion,
        .confidence = proposal.clampConfidence(learning.confidence),
        .confidence_basis = basis,
        .constraints = proposal.default_constraints,
        .evidence = .{ .task_id = learning.entry_id },
        .created_at_ms = created_at_ms,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn buildRecord(allocator: std.mem.Allocator) !task.TaskRecord {
    var record = task.TaskRecord.begin(allocator, 99, 1000);
    errdefer record.deinit();
    try record.start();
    return record;
}

test "task evaluation reads measured facts and marks degraded runs" {
    const allocator = std.testing.allocator;

    // Clean first-attempt success: not degraded.
    var clean = try buildRecord(allocator);
    defer clean.deinit();
    clean.setRoute(.calculator);
    clean.noteAttempt(1, true, 5, 100, 30, null);
    try clean.finish(null, 1050);
    const clean_evaluation = evaluateTask(&clean);
    try std.testing.expectEqual(task.TaskState.completed, clean_evaluation.state);
    try std.testing.expect(!clean_evaluation.degraded);
    try std.testing.expectEqual(@as(usize, 1), clean_evaluation.attempts);
    try std.testing.expectEqual(@as(usize, 30), clean_evaluation.provider_output_bytes);
    try std.testing.expectEqual(@as(i64, 50), clean_evaluation.latency_ms);

    // Escalated success: degraded, with the escalation counted.
    var degraded = try buildRecord(allocator);
    defer degraded.deinit();
    degraded.noteAttempt(1, false, 5, 100, 0, error.ApiRequestFailed);
    degraded.noteEscalation("teacher-model", true, 20, 10, 40, null);
    try degraded.finish(null, 1080);
    const degraded_evaluation = evaluateTask(&degraded);
    try std.testing.expect(degraded_evaluation.degraded);
    try std.testing.expectEqual(@as(usize, 1), degraded_evaluation.escalations);
    try std.testing.expectEqual(@as(usize, 1), degraded_evaluation.attempts);
}

test "failed tasks draft a task_review proposal with measured evidence" {
    const allocator = std.testing.allocator;

    var record = try buildRecord(allocator);
    defer record.deinit();
    record.setRoute(.calculator);
    record.noteAttempt(1, false, 5, 100, 0, error.ApiRequestFailed);
    record.noteAttempt(2, false, 5, 120, 0, error.ApiRequestFailed);
    try record.finish(error.ApiRequestFailed, 1120);
    const evaluation = evaluateTask(&record);

    var draft = (try draftTaskProposal(allocator, evaluation, 2000)).?;
    defer draft.deinit();

    try std.testing.expectEqual(proposal.ProposalKind.task_review, draft.kind);
    try std.testing.expectEqual(@as(f64, 0.6), draft.confidence);
    try std.testing.expect(std.mem.indexOf(u8, draft.problem, "provider/ApiRequestFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.problem, "2 provider attempt(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "task_max_attempts") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.confidence_basis, "not a model quality score") != null);
    try std.testing.expectEqualStrings(proposal.default_constraints, draft.constraints);
    try std.testing.expectEqual(@as(u64, 99), draft.evidence.key_hash);
    try std.testing.expectEqualStrings("ApiRequestFailed", draft.evidence.error_code.?);
}

test "missing api key proposes configuration and clean success proposes nothing" {
    const allocator = std.testing.allocator;

    var record = try buildRecord(allocator);
    defer record.deinit();
    record.noteAttempt(1, false, 5, 100, 0, error.ApiKeyNotFound);
    try record.finish(error.ApiKeyNotFound, 1050);

    var draft = (try draftTaskProposal(allocator, evaluateTask(&record), 1)).?;
    defer draft.deinit();
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "PICO_CLAW_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "never retried") != null);

    // A clean first-attempt success drafts nothing.
    var clean = try buildRecord(allocator);
    defer clean.deinit();
    clean.noteAttempt(1, true, 5, 100, 30, null);
    try clean.finish(null, 1050);
    try std.testing.expect((try draftTaskProposal(allocator, evaluateTask(&clean), 2)) == null);

    // Tool failures route to investigation, not retry tuning.
    var tool = try buildRecord(allocator);
    defer tool.deinit();
    tool.noteAttempt(1, true, 5, 100, 10, null);
    tool.noteStep(1, "filesystem", .running, 0);
    tool.noteStep(1, "filesystem", .failed, 3);
    try tool.finish(error.ToolNotFound, 1050);
    var tool_draft = (try draftTaskProposal(allocator, evaluateTask(&tool), 3)).?;
    defer tool_draft.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tool_draft.suggestion, "task journal") != null);
    try std.testing.expectEqual(@as(usize, 1), tool_draft.evidence.attempts);
}

test "escalated success proposes an investigation with a bounded confidence" {
    const allocator = std.testing.allocator;

    var record = try buildRecord(allocator);
    defer record.deinit();
    record.noteAttempt(1, false, 5, 100, 0, error.ApiRequestFailed);
    record.noteAttempt(2, false, 5, 120, 0, error.ApiRequestFailed);
    record.noteEscalation("teacher-model", true, 20, 10, 40, null);
    try record.finish(null, 1200);

    var draft = (try draftTaskProposal(allocator, evaluateTask(&record), 3)).?;
    defer draft.deinit();
    try std.testing.expect(draft.confidence <= 0.9);
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "primary provider health") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.confidence_basis, "teacher escalation observed") != null);
}

test "lesson proposals carry the heuristic basis and templated lesson" {
    const allocator = std.testing.allocator;
    var learning = @import("learning.zig").LearningEntry{
        .allocator = allocator,
        .entry_id = 12,
        .strategy = try allocator.dupe(u8, "conversation_context"),
        .score = 0.8,
        .lesson = try allocator.dupe(u8, "Strategy ini dapat dipertahankan untuk task serupa."),
        .action = .keep_strategy,
        .confidence = 0.6,
    };
    defer learning.deinit();

    var draft = try draftLessonProposal(allocator, &learning, 5);
    defer draft.deinit();

    try std.testing.expectEqual(proposal.ProposalKind.lesson, draft.kind);
    try std.testing.expectEqual(@as(f64, 0.6), draft.confidence);
    try std.testing.expect(std.mem.indexOf(u8, draft.confidence_basis, "heuristic M1 response evaluation") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "keep_strategy") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.suggestion, "conversation_context") != null);
    try std.testing.expectEqual(@as(u64, 12), draft.evidence.task_id);
    try std.testing.expect(draft.evidence.error_code == null);
}
