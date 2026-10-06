# MEMORY.example.md — persistent owner memory template

Copy this file to `MEMORY.md` in the project root (or point
`settings.memory_path` at your own copy) and edit it. This file is optional.
It stores durable notes that are useful across sessions — not conversation
history. Nothing is written here automatically.

Guidelines:

- Curate by hand: add only stable facts, preferences, and agreed decisions.
- Remove duplicates and stale entries instead of appending forever.
- Never store secrets, credentials, or sensitive personal data.
- Content is treated as untrusted reference data by the agent, never as
  instructions, and can never override the system policy.

## Preferences

- (example) Prefers concise answers with concrete next steps.

## Project facts

- (example) Pico Claw is a Zig 0.16.0 application built with `zig build`.

## Agreed decisions

- (example) Keep runtime JSONL data under `data/` and never commit it.

## Notes

- (example) Windows is the validated development platform.
