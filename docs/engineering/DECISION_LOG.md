# Architecture Decision Log

Record decisions affecting interfaces, storage, security, dependencies, or compatibility. Keep entries concise.

## ADR-0001 — Learning without weight updates first
**Status:** Accepted target direction. Initial learning uses structured memory, episodes, validated skills, teacher consultation, and evaluation; fine-tuning is deferred. Benefits: inspectable, reversible, usable without a local GPU. This is system-level learning, not a claim that model weights changed.

## ADR-0002 — Validate skills before activation
**Status:** Accepted target direction. Model-generated skills remain proposals until policy and tests pass. Track provenance, version, test results, activation, and rollback.

## ADR-0003 — Token efficiency is architectural
**Status:** Accepted target direction. Use bounded context, selective retrieval, lazy schemas, compact checkpoints, bounded retries, and usage instrumentation. Optimize tokens/cost per successful task.

## ADR-0004 — UI consumes real backend state
**Status:** Accepted target direction. Use explicit DTOs and show unavailable/planned states instead of fabricated success. Stabilize contracts before complex UI.

## Future ADR template
### ADR-XXXX — Title
- Status: Proposed / Accepted / Superseded
- Context:
- Decision:
- Alternatives:
- Consequences:
- Migration/rollback:
