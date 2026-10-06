# Learning proposals (M4)

M4 separates **task evaluation** from **learning evaluation** and turns every
learning outcome into a **proposal**: structured, evidence-backed suggestions
that a human reviews and applies. Nothing promotes automatically — the roadmap
exit criterion is that *failed validation never promotes* and *provenance is
recorded*.

## Two evaluations, on purpose

- **Task evaluation** (`experience/task_evaluation.zig`): measured facts from
  the M2/M3 task record — final state, error kind and stable code, provider
  attempts, teacher escalations, replayed work, tool calls, failed steps,
  latency, and byte totals. Everything here is observed, not judged.
- **Learning evaluation** (existing M1 pipeline): the heuristic response
  evaluation, reflection, and lesson. Its score is a **heuristic**, not a
  measured quality metric; wherever it feeds a proposal, the proposal says so
  in its `confidence_basis`.

The system does not claim the model is improving: there is no valid quality
evaluator, so no quality score is invented. Confidence values are documented
heuristics about *evidence strength* only.

## Proposals

A proposal carries: supporting evidence (task id, key hash, route, state,
error kind/code, attempts, escalations, latency, byte totals), the observed
problem, a suggested change, an explained confidence with its derivation
basis, and fixed constraints: *"proposal only; requires human validation and
manual application; no automatic change is performed"*.

Two kinds are generated today:

- **task_review** — from task evidence, only when there is something to
  learn: a failed task (provider/tool/plan/internal follow-ups differ), a
  success that needed retries, or a success that needed teacher escalation. A
  clean first-attempt success produces **no** proposal, so the store never
  fills with trivial entries.
- **lesson** — from the M1 reflection/learning pipeline on successful tasks.
  The lesson text is templated by that pipeline (never task or tool content).
  The proposal suggests manual application to the knowledge store; it does not
  write it.

Skill proposals are deliberately not generated yet: promoting a skill requires
the M5 skill validator, and an unvalidatable proposal would be decoration.

## Storage

Proposals persist in `data/proposals/proposals.jsonl` (bounded to the 64 most
recent, oldest evicted). Content-free by policy: ids, hashes, states, counts,
durations, byte totals, stable error codes, and the templated problem/
suggestion text — never task text, tool content, prompts, or credentials.
Corrupt or schema-invalid lines are skipped on load; confidence is clamped to
[0, 1] on load.

## CLI

```text
pico_claw proposals                 # list (same as `proposals list`)
pico_claw proposals list
pico_claw proposals accept <id>     # record acceptance
pico_claw proposals reject <id>     # record rejection
```

- Accepting records the decision (terminal; a decided proposal cannot be
  re-decided or flipped), persists it, and prints the explicit manual
  application instructions. **No code runs and no other store is modified.**
- Rejecting records the decision; the proposal stays in the journal for
  auditability.
- `pico_claw status` reports proposal totals.

## Limitations

- This system collects evidence and proposes follow-ups; it does not prove
  that the agent or model improved. There is no benchmark, no hold-out, and
  no quality metric (M8 territory).
- Accepting a proposal applies nothing automatically; application is manual by
  design (sanctioned safe scope), so accepted-but-unapplied proposals are
  possible by construction.
- Proposals derive from single runs; evidence strength is capped below full
  confidence and is not a substitute for measurement.
- Skill proposals and automatic application await the M5 skill validator.
