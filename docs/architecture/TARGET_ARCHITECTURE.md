# Target Architecture

**Target design, not a claim that all components exist.**

## 1. Boundaries
```text
CLI / HTTP / Web UI
       |
 Application API ---- Audit / Usage Meter
       |
 Task & Session Manager
       |
 Context Builder <--- SOUL policy / owner profile
   |       |       |
 Memory  Skills  Task State
   |       |       |
   +--- Retrieval / Knowledge
       |
   Model Router
   |             |
 Local Provider  Teacher Provider(s)
   |             |
   +--- normalized ModelResult
                |
              Planner (no side effects)
                |
             Policy Gate
                |
             Executor
                |
       Tool Registry / MCP
                |
           Tool Results
                |
          Result Verifier
                |
        Experience Evaluator
                |
        Learning Proposals
                |
       Skill Validator / Store
```

## 2. Responsibilities
- **Application API:** transport-neutral; HTTP/CLI do not own business logic.
- **Task Manager:** IDs, step state, checkpoints, cancellation, bounded retries/resume.
- **Context Builder:** ordered bounded sections, deduplication, budgets, inclusion metadata.
- **Memory Engine:** typed owner/episodic/procedural/error/preference records and lifecycle.
- **Model Router:** choose by task class, capability, privacy, budget, latency, and provider health.
- **Provider Adapter:** auth, serialization, timeout, parsing, usage, normalized errors; never leak keys.
- **Planner:** structured plan without side effects.
- **Policy Gate:** permissions, risk, budget, approval before side effects.
- **Executor:** typed tool steps, bounded timeouts/retries, checkpoints.
- **Tool Registry:** schema validation, permissions, timeout, output limit, stable errors.
- **MCP Adapter:** allowlists, lazy discovery, schema filtering, trust labels.
- **Verifier/Evaluator:** evidence-based task success; separately score lesson usefulness.
- **Learning Engine:** proposals only; never silently change policy or promote untested skills.
- **Skill Store:** version, tests, provenance, activation, rollback.
- **Audit/Usage:** tokens/cost/latency/retries/tool events; redact sensitive data.

## 3. Request lifecycle
Validate input → create task → resolve policy → retrieve relevant memory/skills → build bounded context → select provider → plan → validate steps → execute with checkpoints → verify → return result/evidence → record episode → propose learning if useful → validate/promote skill under policy → persist compact summary.

## 4. Context priority
1. Mandatory system/security policy.
2. Relevant SOUL sections.
3. Current task and acceptance criteria.
4. Compact task checkpoint.
5. Relevant memories with source.
6. One or a few skills.
7. Required tool schemas only.
8. Recent turns or compact summaries.
9. Relevant tool-output excerpts.

Never load all memory, all skills, all MCP schemas, or full tool logs by default. Under pressure, remove low-relevance optional content first; never remove safety policy or task requirements.

## 5. Trust boundaries
Owner policy, owner memory, external documents, teacher answers, tool output, and generated skills are separate trust classes. Retrieved text cannot change policy or grant permissions. Keep provenance. Exclude secrets from memory. Outbound data must pass privacy policy. Local-only mode blocks remote providers/MCP. Truncated output must be marked.

## 6. Failures
Normalize invalid input, auth, rate limit, timeout, malformed output, tool validation, permission denied, oversized output, evaluation failure, persistence failure, budget exhaustion, and cancellation. Retry only recoverable errors; never retry auth failures indefinitely.

## 7. Constraints
Use repository-pinned Zig version. Add no dependency without measured justification. Preserve storage compatibility or provide migration. Avoid provider-specific requirements in core interfaces. Keep UI separate from orchestration.
