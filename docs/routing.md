# Teacher routing (M3)

Teacher routing adds a **model router** decision to every task: when the
primary provider fails after its bounded retries, the task can be escalated
once to a configured *teacher* provider. The router decision is pure and
separated from execution, so it is testable without any network or API key.

## What escalates, and what does not

The decision (`core/router.zig: decide`) is explicit and measured, checked in
this order:

| # | Condition | Outcome |
|---|---|---|
| 1 | Nothing failed | `no_failure` — no escalation |
| 2 | No teacher configured | `disabled` — pre-M3 behavior |
| 3 | `routing_local_only` is set | `local_only` — remote teacher blocked |
| 4 | Failure is not provider-class (plan/tool/internal) | `not_provider_failure` |
| 5 | The per-run escalation budget is spent | `budget_exhausted` |
| 6 | Compact request exceeds `routing_teacher_max_request_bytes` | `request_too_large` |
| 7 | Primary provider exhausted its attempts with a provider-class error | **escalate** (`provider_failure`) |

The single M3 trigger is *repeated failure of the primary provider* — a signal
M2 already measures. Escalation happens **at most once per task run** and the
teacher call **never executes tools**, so routing cannot repeat a side effect
or loop on itself. Difficulty/uncertainty/expected-value triggers require
evaluation signals that do not exist yet (M4); inventing a proxy for them now
would make routing unmeasurable, so they are deliberately deferred.

## Compact request and privacy

The teacher receives a compact, privacy-bounded request assembled by
`buildEscalationContext`:

1. the agent system policy (as with the primary provider);
2. an escalation briefing carrying **only normalized error metadata** — the
   error kind and stable code (for example `provider/ApiRequestFailed`);
3. the task text itself.

It deliberately excludes owner files (SOUL/MEMORY), retrieved memory and
knowledge, conversation history, and tool outputs, so none of that private
context reaches a second provider. The request never contains credentials; the
teacher uses the same `PICO_CLAW_API_KEY` environment variable as the primary
provider.

## Fallback semantics

- Teacher succeeds → the task completes with the teacher's answer.
- Teacher fails → the task fails with the **original primary error**; the
  teacher's own stable error code is recorded in the escalation entry. The
  teacher is never retried and escalation never re-escalates.

Every routing decision is recorded in the M2 task record
(`escalation: {escalated, reason, model_label, ok, duration_ms, input_bytes,
output_bytes, error_code}`) and the per-task log line reports
`escalation=<reason>` plus the teacher label, outcome, latency, and byte
totals. Model labels come from configuration; no request or reply content is
ever journaled.

## Configuration

All keys are optional under `settings`; without them behavior is identical to
M2:

| Key | Default | Meaning |
|---|---|---|
| `routing_teacher_base_url` | unset | Teacher endpoint (OpenAI-style `/chat/completions`). |
| `routing_teacher_model` | unset | Teacher model name; both keys must be set for escalation to be available. |
| `routing_local_only` | `false` | Privacy mode: never send a task to a remote teacher. |
| `routing_teacher_max_request_bytes` | `8192` | Byte budget for the compact request, clamped to 1024–65536. |

`pico_claw status` reports `Teacher: <model|disabled>` and `Local-only: <bool>`.

## Limitations

- **No wall-clock timeout:** Zig 0.16.0's `std.http` exposes only a TCP
  *connect* timeout (`ConnectTcpOptions.timeout`), not a request/response
  timeout, so a hanging teacher call blocks until the transport itself fails.
  The roadmap's timeout item is therefore only partially implementable today;
  enforcing a real deadline would need a threaded wrapper and is deferred.
- The teacher uses the primary API key environment variable; a separate key
  env per provider is future work.
- The teacher is a plain chat call: it cannot run tools, so tool-dependent
  tasks are answered from the task text alone.
- `routing_local_only` blocks the teacher only. A full local-only mode (no
  remote provider at all) needs a local model adapter that does not exist yet.
- Escalation is available wherever `Conversation.send` runs (CLI chat, HTTP
  chat); there is no routing-specific HTTP surface yet.
