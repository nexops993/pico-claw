# Web UI Design Specification

**Status:** Target design. Build against real backend contracts; do not imply unimplemented features exist.

## 0. Implemented responsive baseline (current build)
- **Mobile-first CSS:** the stylesheet starts at phone widths (360-430px
  verified breakpoints) and enhances at `>=640px`, `>=900px` and `>=1100px`.
  Below 900px the navigation sidebar and the chat conversation rail are
  off-canvas drawers opened by the hamburger and a per-page toggle, closed
  by backdrop tap, `Escape`, or navigation.
- **No horizontal page scroll:** `html/body` clamp overflow; wide tables are
  wrapped in `.table-wrap` horizontal-scroll containers; card grids collapse
  to one column below 640px.
- **Chat keyboard behavior:** the app uses `100dvh` height, the message list
  is the only scrolling element, the composer keeps `env(safe-area-inset-bottom)`
  padding, and the viewport meta carries `viewport-fit=cover` so the input
  stays usable above the mobile keyboard.
- **Touch targets:** buttons, nav items and list rows keep a 40px minimum
  height; forms stretch to full available width.
- **Dialogs:** native `<dialog>` modals cap at `min(92vw, 460px)` and
  `86dvh` so they always fit phone viewports. All former `window.prompt`
  flows (conversation rename, memory search, profile create/duplicate) use
  these modals.
- **Config page is editable:** facts cards are read-only; the editable form
  writes through `PUT /api/config`, tracks unsaved changes (navigation and
  reload warnings), and reports `applied` vs `requires_restart` vs `ignored`
  per field. Secrets are never rendered as inputs.
- **Gateway honesty:** Start/Stop/Restart controls only render when the
  runtime reports `can_host: true`; otherwise the page shows the external
  `pico_claw channel telegram` command and real connection-test state.

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
