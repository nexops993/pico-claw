# Pico Claw — Product & Engineering Spec Pack

Documentation only; this pack does not implement the planned features.

## Read order for AI coding agents
1. `AGENTS.md` — always-follow working rules.
2. `.clinerules/00-core.md` — concise Cline rules.
3. `docs/product/PRD.md` — scope and acceptance criteria.
4. `docs/architecture/TARGET_ARCHITECTURE.md` — target boundaries and data flow.
5. Read only the task-relevant design: `docs/design/WEB_UI.md`, `docs/learning/CONTINUOUS_LEARNING.md`, `docs/engineering/TOKEN_EFFICIENCY.md`, `docs/engineering/QUALITY_AND_TESTING.md`.
6. `docs/ROADMAP.md` — dependency order.

Copy these paths into the repository root, preserving paths. Review existing files before replacing anything. This pack does not overwrite existing README or implementation files.

Status vocabulary: **Existing** means verify in source before changing; **Target** means planned, not necessarily implemented; **Deferred** means outside initial scope.

Never implement the whole roadmap in one change. Use small, testable vertical slices. Never claim a feature exists until source and tests prove it.
