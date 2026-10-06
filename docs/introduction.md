# Introduction

Pico Claw v0.1.0 is a lightweight personal AI agent runtime implemented natively in Zig 0.16.0. It keeps orchestration local while using a configured HTTP provider for language-model responses. It is an independent implementation inspired by general architecture of modern personal AI agents, not an official Hermes Agent or OpenClaw fork.

## Goals

- Small native executable and explicit ownership.
- Zig standard library only; no external package dependencies.
- Local conversation orchestration with narrow, deterministic tools.
- Plain JSONL persistence inspectable without database software.
- Bounded retrieval and execution loops.
- Honest, limited local HTTP surface.

## v0.1.0 scope

Implemented: CLI chat/server/status/help/version; local dashboard; three HTTP routes; provider adapter; Brain tool loop; calculator, filesystem, and system tools; ToolRegistry; planner and executor; persistent memory, experience, strategies, and knowledge; evaluation, reflection, and learning; static skill metadata.

Deliberately outside scope: streaming, WhatsApp, Telegram, browser automation, authentication, remote/public dashboard binding, embeddings/vector search or DB, dynamic plugins, external dependency system, arbitrary shell execution, dynamic code execution, and self-modifying Zig source.

Provider responses are buffered. Dashboard is intentionally static and local. Portability is a design goal, but only platform-specific testing establishes support.
