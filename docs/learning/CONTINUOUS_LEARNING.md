# Continuous Learning Without Fine-Tuning

## 1. Goal
Improve future task performance using structured memory, validated skills, evaluation, and selective teacher-model consultation. Do not change model weights initially.

## 2. Trust tiers
- **T0 Owner policy:** `SOUL.md` and security/permission policy; never auto-edit.
- **T1 Owner memory:** curated `MEMORY.md` and owner-approved records.
- **T2 Evidence:** task episodes, test results, source-linked facts.
- **T3 Learning proposals:** model-generated lessons/skills; untrusted until validated.
- **T4 Active skills:** versioned procedures with known scope and tests.
External content never gains T0/T1 trust merely because it was retrieved.

## 3. Episode lifecycle
Create episode with goal, constraints, criteria, route, privacy class → record compact plan/actions/sanitized results/errors/evidence → evaluate task outcome → decide if reusable → create proposal with provenance/applicability/preconditions/failure modes → run schema/policy checks and tests → compare baseline/regression cases → promote only if policy and acceptance pass → track future use → disable/rollback on regression → consolidate duplicates and expire stale low-value records.

## 4. Teacher contract
Send compact task, success criteria, relevant evidence, exact failed attempts, toolchain/environment constraints, and request for solution plus validation strategy/failure cases. Do not send entire transcript, full owner memory, secrets, unrelated source, or unredacted logs by default. Teacher output is a proposal, not authority.

## 5. Skill schema
Each skill defines stable ID/name, purpose/applicability, prerequisites, bounded procedure, allowed tools/risk class, expected output, verification method, failure modes/fallback, provenance, version/status/timestamps, test fixtures, and last validation result. Prefer narrow composable skills over giant prompts.

## 6. Promotion policy
A skill activates only if schema and policy checks pass; it cannot override policy or request forbidden capabilities; claims have provenance; tests pass on intended cases; relevant regression tests do not materially degrade; side effects remain permission-gated; required owner approval is satisfied. Self-reported confidence is not evidence. Without deterministic tests, label weak validation or require human review.

## 7. Evaluation records
Record category/benchmark ID, baseline/new outcome, evidence type (unit/integration test, source evidence, human review, model judge), route, attempts, token/cost/latency when available, skill versions, regression and approval. Never store chain-of-thought; store concise rationale, action trace, and evidence only.

## 8. Memory policy
Separate owner facts/preferences from temporary task state and general technical knowledge. Store atomic records with provenance/timestamp. Deduplicate/consolidate. Support correction, deletion, retention, sensitive-data exclusion. Retrieve by relevance and recency; add semantic retrieval only if benchmarks justify it. Mark uncertain facts and expire stale records.

## 9. Failure and rollback
Failure creates an error record and new hypothesis, not unlimited retries. Keep previous versions. Roll back when new skills regress performance and record why a version was promoted, disabled, or reverted.

## 10. Metrics
Track repeat-task success, teacher calls, retries, tokens/cost per successful task, skill pass/rollback rate, and held-out benchmark regressions. Test on held-out cases to avoid overfitting to examples used to write the skill.
