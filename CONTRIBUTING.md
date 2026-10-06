# Contributing

## Environment

Use Zig 0.16.0. Repository has no external package dependencies. Work from repository root because configuration and persistence paths are relative to current working directory.

Create local `config/config.json` from `config/config.example.json`. Keep provider credentials only in `PICO_CLAW_API_KEY`; never add secrets, `.env`, local config, or runtime JSONL data to Git.

## Required checks

```text
zig fmt --check build.zig src
zig build test
zig build
```

Format changed Zig files with `zig fmt`. Keep tests deterministic and independent of live provider access. Preserve explicit allocator ownership: duplicate borrowed data retained beyond call, free owned allocations in matching `deinit`, and document ownership in APIs where unclear.

## Change scope

- Keep implementation lightweight and standard-library-only unless project requirements explicitly change.
- Avoid speculative abstractions and runtime features.
- Preserve Zig 0.16.0 APIs; do not backport older Zig patterns.
- Update docs when commands, schemas, limits, persistence, or security behavior changes.

## Adding a tool safely

1. Implement `Tool` adapter under `src/tools/` with a narrow input grammar.
2. Validate all untrusted input before side effects.
3. Bound reads, writes, loops, and allocations.
4. Never pass provider text to a shell or dynamic evaluator.
5. Register tool in `src/main.zig` only after focused tests cover valid input and rejection paths.
6. Update `docs/tools.md`, planner docs if applicable, and security docs.

## Planner and executor changes

Planner decides and owns bounded plan data; it must not execute tools. Executor accepts only explicit tool names and inputs from a plan, enforces step limits, and returns owned outputs. New direct-execution behavior requires typed tool grammar and tests proving planner output matches tool contract. Natural-language filesystem tasks are not safe direct filesystem commands.

## Provider changes

Keep API key in environment, preserve generic errors at local HTTP boundary, and test request/response parsing without real credentials. Do not claim streaming unless implemented and tested. Configuration fields and actual wire payload must remain accurately documented.

## Persistence

Runtime files contain user prompts, responses, learned lessons, and potentially sensitive content. Use temporary directories in tests. Maintain malformed-record handling semantics and atomic replacement where currently used. Never commit generated JSONL data.

## Security reports

Do not disclose exploitable details in a public issue. Use GitHub's private security-reporting channel once enabled; otherwise contact repository owner privately through a channel listed on repository profile. See `SECURITY.md`.
