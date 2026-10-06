# Web UI Design Specification

**Status:** Target design. Build against real backend contracts; do not imply unimplemented features exist.

## 1. Goals and principles
The dashboard is an operations surface, not a decorative chat clone. Users should see task state, selected model/provider, tools used, pending approvals, usage, and what was learned. Responsive mobile/desktop, keyboard-accessible, clear focus, sufficient contrast, restrained motion, semantic status labels. Dark/light theme should use semantic tokens. Never display secrets. Every async action has loading, success, empty, and failure states.

## 2. Information architecture
1. **Overview:** health, active task, recent activity, usage.
2. **Chat:** messages, compact task timeline, tool activity, verification evidence.
3. **Tasks:** queued/running/completed/failed/cancelled, step timeline, resume/cancel when supported.
4. **Memory:** search, source, date, status, edit/delete/forget.
5. **Skills:** proposed/active/disabled/rejected/rolled-back, version, tests, provenance.
6. **Learning:** episodes, teacher consultations, evaluations, pending proposals, regressions.
7. **Models & Providers:** aliases, availability, local/remote status, limits; secrets redacted.
8. **Tools & MCP:** registered tools, trust, permissions, health, schema summary.
9. **Approvals:** proposed action, target, rationale, data impact, approve/deny.
10. **Settings:** owner preferences, budgets, privacy, retention, storage, theme.

If backend support is missing, show a clear unavailable/planned state; never fabricate data.

## 3. Overview
- Header: system status, local-only/connected mode, provider health.
- Active task panel: goal, state, current step, progress from real state.
- Usage: input/output tokens, estimated cost, teacher calls, latency; label unknowns/estimates.
- Recent activity: task outcomes, tool/provider failures, learning proposals.
- Safety panel: pending approvals, blocked actions, storage warnings.
Do not show vanity “IQ” or intelligence scores.

## 4. Chat
- Message stream plus separate task timeline for planning, tools, verification, and final result.
- Tool details collapsed by default; show sanitized input/output on expansion.
- Indicate model/provider and teacher consultation.
- Show concise rationale and evidence, never hidden chain-of-thought.
- Submit/cancel/error controls reflect actual backend state.

## 5. Task detail
Show task ID, goal, timestamps, status, acceptance criteria, plan steps, per-step duration/tool/provider/retries, sanitized summaries, checkpoints, evidence, usage, and linked learning proposal. Cancel/resume/retry only when valid. Statuses: `queued`, `running`, `waiting_approval`, `succeeded`, `failed`, `cancelled`, `needs_attention`.

## 6. Memory
Filter by type/source/date/status/relevance. Show content, provenance, timestamps, trust class, and use count if tracked. Support edit/delete/forget only when backend supports it. Distinguish owner-authored from inferred/external data. Never display credentials.

## 7. Skills and Learning
Skills list shows purpose, version, status, validation result, test ratio, provenance. Detail shows prerequisites, allowed tools, tests, change history, activate/disable/rollback. Learning queue shows episode, initial outcome, teacher used, proposed lesson, evidence, cost, and status. Generated skills must not activate solely because a model recommends them.

## 8. Models, tools, and MCP
Show provider alias, model ID, local/remote label, health, latency, budget policy. Secret inputs are write-only; display configured/not configured, never current value. Label tools read-only/write/network/destructive. MCP shows trust state, allowed tools, last health, and errors. Local-only mode must visibly confirm external routing is disabled.

## 9. Design tokens and components
Use semantic tokens: `--bg`, `--surface`, `--surface-muted`, `--text`, `--text-muted`, `--border`, `--accent`, `--success`, `--warning`, `--danger`, `--info`, spacing, radius, UI font, mono font. Status never relies on color alone.

Reusable components: AppShell, Sidebar/BottomNav, StatusBadge, ProviderHealth, UsageSummary, TaskTimeline, StepRow, ToolCallDisclosure, ApprovalDialog, MemoryRecordCard, SkillStatus, EvaluationResult, EmptyState, ErrorState, LoadingSkeleton, ConfirmActionDialog, SecretInput, FilterBar.

## 10. Target API resources
These are proposed contracts, not existing endpoints:
- `GET /health`, `GET /api/overview`
- `GET /api/tasks`, `GET /api/tasks/{id}`
- `POST /api/tasks/{id}/cancel` if supported
- `GET /api/memory`, `PATCH/DELETE /api/memory/{id}` after persistence/policy exists
- `GET /api/skills`, `GET /api/skills/{id}`
- `GET /api/learning`, `POST /api/learning/{id}/validate|approve|reject|rollback`
- `GET /api/providers`, `GET /api/tools`

Use explicit DTOs, not assistant prose to infer state. Preserve existing API compatibility or document versioned migration. Never return fake success for stubbed endpoints.

## 11. Security and acceptance criteria
Default to loopback binding. Remote access requires authentication, authorization, rate limits, appropriate CSRF protections, and deployment docs. Escape untrusted content. Confirm destructive actions and show target. All displayed values come from backend or are explicitly examples. Every data view has loading/empty/error states. All controls work or are visibly disabled/planned. Mobile and keyboard workflows work. Secrets never appear in responses, logs, or client state after save.
