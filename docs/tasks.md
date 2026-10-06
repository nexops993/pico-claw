# Tasks, checkpoints, and observability

M2 gives every agent turn an explicit, observable lifecycle: task and step
states, checkpoints, normalized errors, bounded retries, and route/tool/
latency/usage records. The roadmap exit criterion is that **resume does not
repeat completed side effects**.

## What a task is

One task is one `Conversation.send` call: memory and knowledge retrieval,
planning, plan execution, the provider interaction (including the brain's tool
loop), and the experience/learning writes that follow a successful reply.

Each task has exactly one record in the task journal
(`data/tasks/journal.jsonl`), written once when the task finishes.

## Task and step states

```text
task:  pending --> running --> completed
                          \--> failed

step:  pending --> running --> completed
                            \--> failed
step:  pending --> replayed        (checkpointed skip)
```

Transitions are explicit and validated (`core/task.zig`): a task can never
jump from `pending` to `completed`, and a terminal task is immutable. Steps
add a `replayed` state: a step or tool call that already completed in a
previous failed run is marked `replayed` instead of running again.

## What is recorded

The record carries structured metadata only — no task text, no tool input or
output, no provider payload:

| Field | Meaning |
|---|---|
| `id`, `key_hash` | Journal id and the hash of the trimmed input text (the stable task key). |
| `state` | Final task state (`completed` or `failed` in the journal). |
| `route` | Planner route of the leading plan step: `reasoning`, `calculator`, `filesystem`, or `other`. |
| `started_at_ms`, `ended_at_ms` | Wall-clock times; `ended - started` is the task latency. |
| `planned_steps` | Step count of the produced plan. |
| `steps[]` | Per plan step: id, tool name (or null for reasoning), state, duration. |
| `calls[]` | Per provider tool call: tool name, input hash, state, duration. |
| `attempts[]` | Per provider attempt: index, ok, duration, request bytes, reply bytes, error code. |
| `escalation` | Teacher routing decision (M3): escalated/skipped, explicit reason, teacher model label, ok, duration, byte totals, stable error code. |
| `error_kind`, `error_code` | Normalized failure: coarse kind (`plan`, `tool`, `provider`, `internal`) plus the stable compiler error identifier. |

The CLI prints one structured line per finished task:

```text
[Task] #12 key=a1b2c3d4 state=failed route=calculator steps=1 replayed=0 calls=0 attempts=2 latency=812ms error=provider/ApiRequestFailed
```

`pico_claw status` reports the journal totals (`Tasks: n (x completed, y
failed)`), and `Conversation` exposes `lastTask` plus task counters for the
upcoming HTTP dashboard (M7).

## Checkpoints and resume

When a task fails, its record stays in the journal with the steps and tool
calls that completed. Sending the **same task text again** starts a new task
whose recorder is seeded from the latest failed run for that key:

- Plan steps that completed are not executed again; the executor substitutes a
  bounded, deterministic replay marker.
- Provider tool calls that completed are not executed again; the brain feeds
  the provider a replay marker instead.

A *completed* run never makes a later identical task resumable: re-asking a
task that already succeeded always runs fresh. The journal is bounded to the
64 most recent tasks; evicted checkpoints simply mean a new run starts fresh.

Two assumptions make resume sound, and both hold today:

- The planner is deterministic for the same input and tool registry, so plan
  step ids match across runs.
- Provider tool calls are identified by (tool name, input hash): a retry that
  changes the tool input is a new call and runs normally.

## Bounded retries

`settings.task_max_attempts` (1–5, default `1`) bounds how often the provider
interaction is retried within one task. Only provider-class failures are
retried (`isRetryable`); missing configuration, plan, and tool errors fail
immediately. The default keeps pre-M2 behavior: one attempt, no retries.
Each attempt gets a fresh request context, so a retried task never accumulates
stale tool messages.

## Privacy

Records are content-free by design: the journal holds states, counts,
durations, byte totals, hashes, and stable error codes. Error codes are
compiler identifiers, never free-form messages, so no URL, key, or payload can
leak. The provider API key is never touched by the task subsystem. Integration
tests assert the journal contains neither the task text nor the key.

## Integration points

- `Conversation.send` owns the lifecycle: begin → seed resume → plan →
  execute → provider attempts → finish → journal save.
- `Executor.executeResumable` and `Brain.respondChecked` consult the task
  recorder (same vtable pattern as `Tool`/`ChatHandler`) and report resolved
  work with durations.
- `main.zig` loads the journal at startup and prints the counts in `status`.

## Limitations

- **Crash window:** records are written once, when a task finishes. A process
  crash mid-task leaves nothing in the journal, so a restart runs the task
  fresh; completed side effects from the crashed run are not journaled.
- **Replay is metadata, not data:** a replayed step's original tool output is
  withheld from the journal (privacy), so the provider sees a replay marker
  rather than the earlier result.
- **Tool-level failures are retried:** a brain tool call whose tool reported
  an error is recorded as `failed` and re-executed on a retry, because a
  failed call cannot be assumed to have completed its side effect (or not).
- **No HTTP/UI surface yet:** observability is wired into the CLI (`status`
  plus the per-task log line) and `Conversation` accessors; the dashboard is
  M7.
