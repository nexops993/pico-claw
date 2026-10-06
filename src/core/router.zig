const std = @import("std");
const task = @import("task.zig");
const Context = @import("context.zig").Context;

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

pub const default_max_request_bytes: usize = 8 * 1024;
pub const min_max_request_bytes: usize = 1024;
pub const max_request_bytes_cap: usize = 64 * 1024;

/// Escalations per task run. Hard cap: one teacher consultation per run, so
/// routing can never loop or compound on top of itself. Teacher calls also
/// never execute tools, so an escalation cannot repeat a side effect.
pub const max_escalations_per_run: usize = 1;

pub const Policy = struct {
    /// Whether a teacher provider is configured at all.
    teacher_configured: bool = false,
    /// Privacy mode: blocks remote teacher escalation regardless of config.
    local_only: bool = false,
    /// Byte budget for the compact teacher request.
    max_request_bytes: usize = default_max_request_bytes,

    pub fn sanitized(self: Policy) Policy {
        return .{
            .teacher_configured = self.teacher_configured,
            .local_only = self.local_only,
            .max_request_bytes = std.math.clamp(
                self.max_request_bytes,
                min_max_request_bytes,
                max_request_bytes_cap,
            ),
        };
    }

    pub fn enabled(self: Policy) bool {
        return self.teacher_configured and !self.local_only;
    }

    /// Convert a raw JSON byte budget into a value. Invalid values fall back
    /// to the default; valid ones are clamped into [min, cap].
    pub fn fromRawRequestBytes(value: ?f64) usize {
        const raw = value orelse return default_max_request_bytes;
        if (!std.math.isFinite(raw) or raw < min_max_request_bytes) return default_max_request_bytes;
        if (raw >= @as(f64, @floatFromInt(max_request_bytes_cap))) return max_request_bytes_cap;
        return @intFromFloat(raw);
    }
};

// ---------------------------------------------------------------------------
// Routing decision (pure; separated from provider execution)
// ---------------------------------------------------------------------------

pub const Decision = struct {
    escalate: bool,
    reason: task.EscalationReason,
};

/// Decide whether the primary provider's failure should escalate to the
/// teacher. Checked in this documented order:
///
/// 1. nothing failed (`no_failure`);
/// 2. no teacher configured (`disabled`);
/// 3. local-only privacy mode (`local_only`);
/// 4. the failure is not provider-class — plan/tool/internal errors are not
///    fixed by another model (`not_provider_failure`);
/// 5. the per-run escalation budget is spent (`budget_exhausted`);
/// 6. the compact request exceeds the byte budget (`request_too_large`);
/// 7. otherwise escalate for the measured provider failure.
pub fn decide(
    policy: Policy,
    escalations_used: usize,
    failure: ?anyerror,
    request_bytes: usize,
) Decision {
    if (failure == null) return .{ .escalate = false, .reason = .no_failure };
    if (!policy.teacher_configured) return .{ .escalate = false, .reason = .disabled };
    if (policy.local_only) return .{ .escalate = false, .reason = .local_only };
    if (task.classifyError(failure.?) != .provider) {
        return .{ .escalate = false, .reason = .not_provider_failure };
    }
    if (escalations_used >= max_escalations_per_run) {
        return .{ .escalate = false, .reason = .budget_exhausted };
    }
    if (request_bytes > policy.max_request_bytes) {
        return .{ .escalate = false, .reason = .request_too_large };
    }
    return .{ .escalate = true, .reason = .provider_failure };
}

// ---------------------------------------------------------------------------
// Compact, privacy-bounded escalation request
// ---------------------------------------------------------------------------

/// Briefing template for the teacher. It carries only normalized error
/// metadata (stable kind/code identifiers) — never messages, payloads, or
/// private context.
pub const briefing_template =
    "[escalation] The primary model failed for this task (error kind/code: {s}/{s}). " ++
    "You are the fallback teacher model. Answer the user's request directly and completely.";

const briefing_placeholder_bytes: usize = "{s}".len * 2;

/// Byte estimate of the compact escalation request, matching exactly what
/// `buildEscalationContext` assembles: agent policy + escalation briefing +
/// the task itself. Used to enforce the request budget before any provider
/// call happens.
pub fn estimateRequestBytes(
    system_prompt_bytes: usize,
    input_bytes: usize,
    failure: anyerror,
) usize {
    const normalized = task.NormalizedError.normalize(failure);
    const briefing_bytes = briefing_template.len - briefing_placeholder_bytes +
        normalized.kind.name().len + normalized.code.len;
    return system_prompt_bytes + briefing_bytes + input_bytes;
}

/// Build the compact escalation request. Deliberately excludes owner files
/// (SOUL/MEMORY), memory, knowledge, conversation history, and tool outputs,
/// so none of that private context reaches the teacher provider.
pub fn buildEscalationContext(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    input: []const u8,
    failure: anyerror,
) !Context {
    var context = Context.init(allocator);
    errdefer context.deinit();

    try context.addSystem(system_prompt);

    const normalized = task.NormalizedError.normalize(failure);
    const briefing = try std.fmt.allocPrint(
        allocator,
        briefing_template,
        .{ normalized.kind.name(), normalized.code },
    );
    defer allocator.free(briefing);
    try context.addSystem(briefing);

    try context.addUser(input);
    return context;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "routing decision covers every explicit condition in documented order" {
    const enabled = Policy{ .teacher_configured = true };
    const local = Policy{ .teacher_configured = true, .local_only = true };
    const unset = Policy{};

    // Nothing failed: no escalation decision is even meaningful.
    try std.testing.expectEqual(
        task.EscalationReason.no_failure,
        decide(enabled, 0, null, 10).reason,
    );
    try std.testing.expect(!decide(enabled, 0, null, 10).escalate);

    // No teacher configured: local-only installations keep M2 behavior.
    try std.testing.expectEqual(
        task.EscalationReason.disabled,
        decide(unset, 0, error.ApiRequestFailed, 10).reason,
    );

    // Local-only privacy mode blocks the remote teacher even when configured.
    try std.testing.expectEqual(
        task.EscalationReason.local_only,
        decide(local, 0, error.ApiRequestFailed, 10).reason,
    );

    // Only provider-class failures escalate; plan/tool/internal errors do not.
    try std.testing.expectEqual(
        task.EscalationReason.not_provider_failure,
        decide(enabled, 0, error.PlanLimitExceeded, 10).reason,
    );
    try std.testing.expectEqual(
        task.EscalationReason.not_provider_failure,
        decide(enabled, 0, error.ToolNotFound, 10).reason,
    );

    // The per-run escalation budget is bounded.
    try std.testing.expectEqual(
        task.EscalationReason.budget_exhausted,
        decide(enabled, max_escalations_per_run, error.ApiRequestFailed, 10).reason,
    );

    // The compact request must fit the byte budget.
    try std.testing.expectEqual(
        task.EscalationReason.request_too_large,
        decide(enabled, 0, error.ApiRequestFailed, enabled.sanitized().max_request_bytes + 1).reason,
    );

    // The measured trigger: primary provider failure with everything allowed.
    const decision = decide(enabled, 0, error.ApiRequestFailed, 10);
    try std.testing.expect(decision.escalate);
    try std.testing.expectEqual(task.EscalationReason.provider_failure, decision.reason);
}

test "routing policy clamps the request byte budget" {
    try std.testing.expectEqual(default_max_request_bytes, (Policy{}).sanitized().max_request_bytes);
    try std.testing.expectEqual(default_max_request_bytes, Policy.fromRawRequestBytes(null));
    try std.testing.expectEqual(default_max_request_bytes, Policy.fromRawRequestBytes(0));
    try std.testing.expectEqual(default_max_request_bytes, Policy.fromRawRequestBytes(-5));
    try std.testing.expectEqual(@as(usize, 2048), Policy.fromRawRequestBytes(2048));
    try std.testing.expectEqual(max_request_bytes_cap, Policy.fromRawRequestBytes(1_000_000));
    try std.testing.expectEqual(@as(usize, min_max_request_bytes), (Policy{ .max_request_bytes = 1 }).sanitized().max_request_bytes);
    try std.testing.expect(!(Policy{}).enabled());
    try std.testing.expect(!(Policy{ .teacher_configured = true, .local_only = true }).enabled());
    try std.testing.expect((Policy{ .teacher_configured = true }).enabled());
}

test "escalation context is compact, policy-first, and metadata-only" {
    const allocator = std.testing.allocator;

    var context = try buildEscalationContext(
        allocator,
        "SYSTEM POLICY: follow safety rules.",
        "Explain closure capture",
        error.ApiRequestFailed,
    );
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 3), context.count());

    const messages = context.messages.items;
    try std.testing.expectEqual(@as(@TypeOf(messages[0].role), .system), messages[0].role);
    try std.testing.expectEqual(@as(@TypeOf(messages[0].role), .system), messages[1].role);
    try std.testing.expectEqual(@as(@TypeOf(messages[0].role), .user), messages[2].role);

    try std.testing.expectEqualStrings("SYSTEM POLICY: follow safety rules.", messages[0].content);
    try std.testing.expect(std.mem.indexOf(u8, messages[1].content, "[escalation]") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[1].content, "provider/ApiRequestFailed") != null);
    try std.testing.expectEqualStrings("Explain closure capture", messages[2].content);

    // The byte estimate must match the assembled request exactly, so the
    // routing budget is enforced on what is actually sent.
    const estimated = estimateRequestBytes(
        "SYSTEM POLICY: follow safety rules.".len,
        "Explain closure capture".len,
        error.ApiRequestFailed,
    );
    try std.testing.expectEqual(context.byteCount(), estimated);
}
