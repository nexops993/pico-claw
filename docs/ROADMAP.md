# Pico Claw Roadmap

Dependency order, not a mandate to implement everything in one session. Each milestone is a small, reviewable vertical slice.

## M0 — Baseline
Inspect source, tests, pinned Zig version, config, storage, API. Record capabilities/gaps and reproducible build/test baseline. **Exit:** source-to-doc map and baseline tests.

## M1 — Context and owner policy
Load/validate SOUL and MEMORY; separate policy, owner memory, session state, and general knowledge; add context budgets and compact summaries. **Exit:** tests prove selective retrieval and policy retention.

## M2 — Task state and observability
Task/step states, checkpoints, normalized errors, bounded retries, route/tool/latency/usage records without secrets. **Exit:** resume does not repeat completed side effects.

## M3 — Teacher routing
Router behind provider abstraction; privacy, budget, timeout, compact requests. **Exit:** escalation, no-escalation, provider failure, and local-only tests.

## M4 — Evaluation and learning proposals
Separate task and learning evaluation; create structured lessons/skill proposals; no promotion before validation. **Exit:** failed validation never promotes; provenance recorded.

## M5 — Skill lifecycle
Versioned skills, applicability, tests, activation/disable/rollback and relevance retrieval. **Exit:** validated skill improves a held-out related task without regression.

## M6 — MCP boundaries
Selected transports, allowlists, lazy schemas, timeouts, output limits, trust boundaries. **Exit:** untrusted MCP results cannot bypass policy; side effects gated.

## M7 — Web UI
Use real DTOs after backend contracts stabilize. Start Overview, Tasks, Chat/trace, Approvals, Memory, Skills/Learning, Settings. Authentication before any non-loopback exposure. **Exit:** responsive UI mirrors real state; no fake data.

## M8 — Benchmark and optimize
Compare baseline/learned behavior on held-out tasks; optimize task completion, tokens/cost per successful task, latency, regression rate. **Exit:** reproducible environment, cases, metrics, limitations.

## Deferred
Fine-tuning, autonomous source modification, unrestricted shell/public unauthenticated service, default multi-agent debate, vector DB/heavy dependency without evidence.

Each milestone issue/PR must include objective, out-of-scope, expected files/interfaces, acceptance criteria, tests, migration/rollback, and token/cost impact.
