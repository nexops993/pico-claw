# Quality, Testing, and Safety Gates

## Test pyramid
- Unit: parsers, schemas, budgets, scoring, routing, state transitions, permissions.
- Component: provider normalization, context builder, persistence, registry, skill validation.
- Integration: task through plan → tool → verification → episode → learning proposal.
- Regression: fixed bug cases and benchmark tasks.
- Manual acceptance: dashboard, approvals, local-only behavior, privacy.

## Baseline checks
Current docs list:
- `zig fmt --check build.zig src`
- `zig build test`
- `zig build`
Verify commands against the actual repository/toolchain. Run them and report results; never assume success.

Interpreting `zig build test` output: if a step writes anything to stderr (even a passing test's diagnostic), the Zig 0.16 build runner prefixes the captured stderr with `failed command: ...` even though the build succeeded. The Build Summary line and the process exit code are authoritative: `N/N tests passed` with exit code 0 is a pass; a real failure reports `(... failed)` and exits non-zero. Expected diagnostics from production code paths (for example the corrupt-line skip notices) are suppressed under `builtin.is_test` so successful runs stay stderr-clean.

## Safety invariants
- Provider keys never appear in logs or response bodies.
- Tool arguments are validated before execution.
- Disallowed tool calls never execute.
- Timeouts and call budgets terminate loops.
- Untrusted skill/MCP/teacher text cannot change policy.
- Local-only mode blocks external routing.
- Learning cannot auto-edit SOUL/security policy/source code.
- Failed validation never activates a proposed skill.
- Rollback restores a prior known-good skill.
- Resume does not repeat completed non-idempotent side effects without explicit policy.
- UI cannot approve an action that is no longer pending or has changed.

## Deterministic testability
Use fake providers/tools and fixtures. Normal tests must not depend on paid APIs/network. Provider smoke tests are opt-in and redact credentials.

## Learning evaluation
Test originating case, at least one related held-out case where practical, and baseline regressions. Record evidence type and skill version. Keep proposals inactive if evidence is insufficient.

## Change checklist
- [ ] Requirement and acceptance criteria identified.
- [ ] Compatibility reviewed.
- [ ] Failure cases and permissions considered.
- [ ] Tests added/updated.
- [ ] Format/build/tests run and results recorded.
- [ ] Logs/UI checked for secrets and untrusted HTML.
- [ ] Docs/migration updated as needed.
- [ ] Diff contains no unrelated changes.
- [ ] Rollback path exists for persistent/skill changes.
