# Development

Use Zig 0.16.0 and standard library only. Repository modules:

- `src/main.zig`: composition root/command dispatch
- `src/core/`: agent, owned message context, conversation orchestration
- `src/interfaces/`: CLI and HTTP/dashboard
- `src/tools/`: Tool ABI, registry, built-ins
- `src/memory/`: categorized persistence/retrieval
- `src/experience/`: entries, evaluation, reflection, learning, strategies
- `src/brain.zig`, `provider.zig`, `planner.zig`, `executor.zig`, `knowledge.zig`, `skills.zig`, `owner.zig`
- `src/tests.zig`: test root that references every module so `zig build test` runs the full inline suite.

## Philosophy and ownership

Prefer small explicit code, bounded work, Zig stdlib, and no speculative architecture. Allocator-returned slices are owned by caller unless API says otherwise. Components retaining input duplicate it. Pair each owning type with `deinit`; preserve long-lived pointer order established in `main`.

## Workflow

```text
zig fmt build.zig src
zig fmt --check build.zig src
zig build test
zig build
```

Tests are inline Zig tests and must not need live API key/network. Use temporary directories for persistence/filesystem tests.

## Extending safely

Adding tool: define narrow grammar and rejection tests, implement `Tool`, register in `main`, then document security/input/output. Never execute arbitrary provider text as shell/code.

Adding planner behavior: keep planning side-effect-free, bounded, and ownership-correct. Direct Executor use requires planner output exactly match tool grammar. Add planner and executor tests.

Modifying provider: preserve environment key, buffered behavior unless scope explicitly changes, HTTP status checking, response schema validation, and generic local API errors. Update configuration docs when wire payload changes.

Persistence: maintain JSONL compatibility, duplicate retained strings, handle corrupt records intentionally, and use atomic replacement where existing store does. Runtime data may contain secrets and must stay ignored.

Static `skills.zig` is metadata/guidance only and currently not connected to Conversation. Do not describe it as plugin system.
