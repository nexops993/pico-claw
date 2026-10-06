# Product Requirements Document — Pico Claw

**Status:** Target specification · **Version:** 0.2-draft

## 1. Vision
Pico Claw is a lightweight, private personal AI agent that becomes more effective through tools, structured memory, reusable skills, evaluation, and selective teacher-model assistance without requiring fine-tuning initially. “More capable than Hermes” is an aspiration, not a verified claim; measure progress on declared benchmarks.

## 2. Users and jobs
- Owner/operator configures identity, providers, permissions, memory, and budgets.
- User delegates bounded tasks, inspects progress, and approves sensitive actions.
- Developer extends tools, providers, MCP adapters, evaluators, and skills without coupling the runtime.

Core jobs: use owner context selectively; execute multi-step tasks; recover from errors; ask teacher models for difficult work; verify outputs; reuse validated lessons; expose usage and side effects.

## 3. Principles
Lightweight by default; local-first; model-agnostic; retrieval over prompt stuffing; verification over self-reported confidence; human approval for irreversible/high-impact actions; inspectable and reversible learning; core policy separate from editable memory; fail closed when permissions or budgets cannot be checked.

## 4. Scope

### P0 — foundation
- Provider abstraction with timeout, normalized errors, output limits, and usage metadata where available.
- Central context builder with bounded sections and traceable inclusion reasons.
- Owner-controlled `SOUL.md`; curated `MEMORY.md`; configurable paths and safe defaults.
- Structured memory with provenance, timestamps, status, retrieval metadata, and deletion.
- Task lifecycle with step states, checkpoints, bounded retries, result, and audit trail.
- Typed tools with validation, permissions, timeouts, output limits.
- Task evaluation separated from learning evaluation.
- Teacher router with opt-in provider, privacy policy, and budget limits.
- Learning proposals/versioned skills; no auto-promotion without validation.
- CLI status and tests for policy, memory, routing, and learning.

### P1 — expansion
- Semantic retrieval abstraction; benchmark before choosing vector DB.
- Dynamic skills with prerequisites, examples, tests, versions, activation/rollback.
- MCP client with allowlists, lazy schema discovery, timeouts, trust boundaries.
- Dashboard for tasks, approvals, providers, usage, memory, skills, evaluations.
- Task budgets, resumable checkpoints, compact run summaries.
- Benchmark suite for coding, tool use, memory recall, planning, recovery.

### P2 — later
Optional background consolidation, optional dataset export for future fine-tuning, sandboxed code execution, multi-agent collaboration, notifications/channels after core reliability is measured.

## 5. Non-goals initially
No fine-tuning, unrestricted self-modifying code, arbitrary shell execution, public unauthenticated dashboard/API, blind trust in teacher/MCP/skills, model debate for every request, or heavy dependency without measured need.

## 6. Functional requirements
- **FR-01 Context:** Build explicit bounded sections; track why included.
- **FR-02 Memory:** Retrieve relevant records; support correction, deletion, expiry, source inspection.
- **FR-03 Task state:** Resume from compact state without repeating completed side effects.
- **FR-04 Routing:** Select by difficulty, risk, capability, privacy, latency, and budget; support local-only mode.
- **FR-05 Teacher:** Send concise task/evidence/failed attempts/tests, not full history by default.
- **FR-06 Verification:** Prefer deterministic tests; label model-only grading as weaker evidence.
- **FR-07 Learning:** Lessons/skills are proposals until policy and validation pass.
- **FR-08 Safety:** Authorize destructive actions, credentials, public exposure, external side effects.
- **FR-09 Observability:** Record route, latency, retries, usage, outcomes without secrets.
- **FR-10 UI:** Show task state, approvals, provider/usage, and evidence honestly.
- **FR-11 Resilience:** Handle timeout, malformed output, tool failure, corrupt records, and budget exhaustion.
- **FR-12 Portability:** Version storage formats and provide migrations.

## 7. Non-functional requirements
Bounded memory/execution; actionable errors; no secrets in logs/traces/UI/datasets; tests for parsing/policy/migration/retry/rollback; minimal dependencies; configurable local storage; responsive accessible UI.

## 8. Metrics
Establish a baseline first: task completion, held-out benchmark score, regression rate, recovery rate, teacher calls per successful task, median/p95 latency, tokens/cost per successful task, invalid tool-call rate, skill rollback rate, memory retrieval precision, secret-leak test results.

## 9. Release gates
Acceptance criteria, tests, build/format checks, security review for side effects, docs, and reproducible benchmarks for performance claims.

## 10. Open decisions
Resolve only when needed: pinned Zig/toolchain support, retrieval implementation, supported MCP transport, embedded vs separate UI, retention limits and privacy defaults.
