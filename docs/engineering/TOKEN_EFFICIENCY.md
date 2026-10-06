# Token and Context Efficiency

## Objective
Reduce tokens per successful task without reducing correctness, privacy, or recoverability.

## Context assembly
- Centralize context building; do not scatter prompt construction across Conversation, Brain, tools, and provider.
- Give sections a type, source, relevance, estimate, and maximum budget.
- Reserve room for policy, task, response, and tool results before optional memory.
- Load only relevant SOUL sections, memories, skills, and tool schemas.
- Deduplicate instructions and retrieved records.
- Keep task state in compact structured checkpoints; summarize older turns.
- Keep exact source references when detail must be recoverable.
- Truncate large tool outputs around relevant excerpts and mark truncation.
- Never remove safety policy to fit context.

## Routing and retries
- Use local/default model for known low-risk tasks when quality is adequate.
- Escalate for difficulty, uncertainty, repeated failure, or expected value.
- Do not call multiple teacher models by default.
- Retry only with a changed hypothesis, corrected arguments, or recoverable transient error.
- Do not blindly retry auth, permission, invalid-input, or exhausted-budget failures.
- Enforce task caps for attempts, time, tool calls, output tokens, and external cost.

## Tools/MCP
- Discover tools lazily; send only schemas relevant to the plan.
- Cache non-sensitive schema metadata with invalidation.
- Bound output bytes/items; prefer structured output.
- Persist detailed logs locally; send compact summaries to models.
- Never assume characters/bytes equal tokens.

## Measurement
Use provider-reported input/output tokens when available; otherwise label estimates. Track tokens per request/task, cost per completed task, teacher calls, retries, tool calls, latency/failures, and context sections included.

## Regression cases
Test relevant-memory selection, schema selection, oversized output truncation, safe checkpoint resume, bounded teacher escalation, local-only blocking, budget exhaustion, and policy retention under context pressure.

## Anti-patterns
Never append every conversation to every prompt; send all skills/MCP schemas each time; repeat unchanged failed requests; use teacher grading for every trivial response; assume larger context is always better; log secrets/full sensitive prompts; claim exact token counts from character counts.
