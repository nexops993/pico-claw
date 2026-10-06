# Pico Claw — Product Requirements Document

## 1. Document Status

This document is the authoritative product specification for the next development cycle of Pico Claw.

Current state is based on the latest engineering report:
- Zig project.
- Existing provider/SSE stack is stable.
- Telegram channel is working and must be preserved.
- Web dashboard/control plane is working.
- Runtime sandbox is implemented and tested.
- Existing tool registry is the execution boundary.
- MCP is NOT implemented yet.
- Current verification baseline: 281 passing, 1 skipped, 282 total.
- The symlink-escape test may be skipped when the host cannot create symlinks.
- The binary version string is currently inconsistent with the changelog and must be reconciled before release.

This PRD supersedes earlier drafts where they conflict with the current implementation.

## 2. Product Vision

Pico Claw is a local-first, professional, universal AI agent and control plane.

It should be capable of understanding a task, inspecting available context, planning, using approved tools, operating inside an explicit workspace/sandbox, observing results, verifying them, recovering from failures, and reporting honestly.

The product must work across Windows, Linux, and macOS on supported x64 and ARM64 targets without assuming that a particular shell, scripting language, media utility, office suite, container runtime, or operating-system command exists.

The core principle is:

Capability must be real, discoverable, permissioned, bounded, observable, and testable.

The agent must never claim a capability that the runtime has not actually exposed.

## 3. Product Principles

1. Local-first.
2. Cross-platform by architecture, not by scattered OS conditionals.
3. Capability-driven.
4. Deny by default for dangerous operations.
5. No fake tools, fake results, fake model capabilities, or simulated success.
6. Existing stable subsystems are protected by regression tests.
7. Provider/SSE behavior must remain compatible.
8. Telegram behavior must remain compatible.
9. Sandbox boundaries must be stronger than prompt instructions.
10. Agent output must distinguish success, failure, unsupported, unavailable, and denied.
11. Every meaningful capability needs tests.
12. Security failures are release blockers.
13. The dashboard is a control plane, not the source of truth for runtime state.
14. Runtime state must be represented by real backend services.
15. The benchmark/QA harness is an external development tool, not a production feature.

## 4. Current Architecture

The current architecture includes:

Agent Core
→ Brain / planning
→ Executor
→ Tool Registry
→ Runtime implementations

Supporting services include:
- Provider/model service
- Session store
- Profiles
- Settings
- Gateways
- Capabilities
- Sandbox
- Memory
- Task/journal infrastructure
- Web dashboard

Current runtime sandbox:
- Workspace: `./workspace/`
- File operations
- Directory operations
- Search
- Copy/move/delete/edit/stat
- Process execution
- Archive operations
- Media metadata inspection

The sandbox sits behind the existing tool registry:

Agent Core → Executor → ToolRegistry → Runtime/Sandbox → Result

Do not bypass the ToolRegistry for agent-initiated operations.

## 5. Agent Operating Model

The intended agent loop is:

Understand
→ Gather Context
→ Plan
→ Request/Check Permissions
→ Act
→ Observe
→ Verify
→ Repair if needed
→ Respond

The agent should prefer evidence over assumptions.

For file or code tasks:
- inspect first;
- identify relevant files;
- plan changes;
- make minimal changes;
- run relevant verification;
- inspect results;
- repair failures;
- report exactly what happened.

For operations that can have side effects:
- determine capability;
- determine permission;
- determine risk;
- require approval when policy requires it;
- execute within resource limits;
- record an auditable event.

## 6. Capability Contract

Every capability exposed to the agent or dashboard should have a machine-readable contract containing, as applicable:

- id
- version
- platform
- availability
- enabled state
- permissions
- risk
- dependencies
- resource limits
- input schema
- output schema
- side effects
- security policy
- test coverage/status

Capability states should distinguish at least:
- available
- disabled
- unsupported
- unavailable
- denied
- error

The same capability information should be usable by:
- Agent Core
- Dashboard
- Doctor
- QA/benchmark tooling
- Security/audit components

## 7. Universal Runtime

Supported target families:
- Windows x64
- Windows ARM64
- Linux x64
- Linux ARM64
- macOS x64
- macOS ARM64

Architecture requirements:
- define platform-neutral interfaces first;
- isolate OS-specific implementations behind backends;
- detect capabilities at runtime;
- never infer availability from the operating system name alone.

Do not assume:
- Bash
- PowerShell
- cmd
- Python
- Node
- Docker
- Podman
- FFmpeg
- LibreOffice
- ImageMagick
- Git
- external package managers

Optional external dependencies may be detected and used only through explicit capability adapters.

## 8. Sandbox

The sandbox is a security boundary, not merely a convenience directory.

Current policy:
- workspace is `./workspace/`;
- absolute paths are rejected;
- UNC and NT-device paths are rejected;
- drive-letter paths are rejected;
- traversal components are rejected;
- reserved Windows device names are rejected;
- Windows-forbidden punctuation and ADS syntax are rejected;
- symlink/junction/reparse-point traversal is blocked;
- resource limits are enforced.

Current limits include:
- read: 2 MB
- write: 64 MB
- process output: 512 KB
- archive input: 256 MB
- extracted archive data: 1 GB
- archive entries: 20,000
- process timeout: 60 seconds
- process execution: denied by default through an empty allowlist
- network: denied by default

These limits must remain configurable only through controlled policy mechanisms.

The sandbox must prevent:
- path traversal;
- workspace escape;
- unsafe symlink traversal;
- archive zip-slip;
- archive bombs/resource exhaustion;
- accidental secret disclosure;
- uncontrolled process execution.

## 9. Filesystem Capabilities

Required structured operations:
- list
- read
- write
- edit
- stat
- mkdir
- delete
- move
- copy
- search

Operations must use structured arguments rather than shell strings.

All failures must return structured error information.

The agent must not fabricate a file result when the operation failed.

## 10. Process Execution

Process execution must:
- use structured executable + argument arrays;
- avoid shell interpretation;
- use an allowlist;
- enforce timeout;
- enforce output limits;
- capture real exit status;
- filter environment variables by name;
- never return secret values;
- expose stdin only when explicitly permitted;
- provide deterministic failure states.

Default policy remains deny-by-default.

The dashboard must not turn process execution into unrestricted host execution.

## 11. Archives

Supported current formats:
- ZIP
- TAR
- TAR.GZ

Required protections:
- reject zip-slip/traversal before writes;
- skip or reject unsafe links;
- enforce entry count and extracted-size limits;
- enforce input-size limits;
- report partial/failed extraction accurately;
- never claim successful extraction if an operation was aborted.

## 12. Media

Current metadata support includes common image and video container formats implemented by the runtime.

Current formats reported by the implementation include:
- PNG
- JPEG
- GIF
- WebP
- BMP
- MP4
- MKV
- WebM
- AVI

Current metadata capability may include SHA-256.

Thumbnail generation, video frame extraction, and audio extraction are currently unsupported unless a real implementation is added.

Vision must not be advertised unless the configured provider actually supports it.

## 13. MCP

MCP is currently NOT implemented.

MCP is the next major runtime integration target.

Phase A — MCP Client/Host:
1. MCP configuration model.
2. MCP server registry.
3. Stdio transport.
4. Protocol initialization/negotiation.
5. Capability discovery.
6. Tool discovery.
7. Resource discovery where supported.
8. Structured invocation.
9. Timeouts.
10. Process lifecycle management.
11. Error normalization.
12. Permission/risk integration.
13. Capability manifest integration.
14. Audit events.

The first implementation must use a deterministic in-repository test MCP server.

MCP-discovered tools must enter the existing permission/risk model. They must not bypass ToolRegistry or security policy.

Phase B:
- Streamable HTTP transport.
- MCP resources/prompts where useful.
- authentication/authorization policies.
- connection health.
- restart/reconnect behavior.

Phase C:
- optional Pico Claw MCP server exposing selected safe capabilities.

No MCP endpoint or dashboard UI should exist merely as a placeholder.

## 14. Dashboard / Control Plane

The dashboard is dependency-free and embedded into the binary.

It should expose real runtime state through backend APIs.

Major sections:
- Chat
- Overview
- Sessions
- Models
- Profiles
- Skills
- Tools
- Memory
- Gateways
- Config
- Settings
- Logs
- Sandbox
- MCP when MCP backend exists

Visual direction:
- liquid-glass / glassmorphism;
- dark/light themes;
- responsive;
- no external CDN dependency;
- accessible controls;
- clear loading/empty/error states.

The dashboard must never invent backend state.

## 15. Chat

Chat should support:
- persistent session state while the process is running;
- session creation;
- session clearing;
- model selection from real model discovery;
- markdown rendering;
- code blocks;
- links;
- tool execution indicators;
- errors;
- retry/regenerate where supported;
- attachments when attachment infrastructure exists.

Stop behavior must accurately describe whether the server-side execution was cancelled or only the client request was aborted.

## 16. Models

Model discovery must use the provider's real model API.

Do not hardcode a model catalog.

A normalized model record may include:
- id
- provider
- display name
- capabilities
- context length when available
- availability
- active state
- metadata

Vision, tool calling, streaming, reasoning, or other model features must be advertised only when actually supported/detected.

## 17. Profiles

Profiles should support:
- list
- create
- update
- duplicate
- delete
- activate

A profile can define:
- identity
- system instructions
- behavior/style
- custom instructions
- SOUL content
- MEMORY association
- workspace policy

Profile paths and referenced files must remain contained within approved locations.

## 18. Skills

Skills must represent real capabilities.

A skill should expose metadata such as:
- id
- version
- description
- availability
- enabled state
- dependencies
- configuration schema

Static metadata must not be presented as a working runtime capability unless the underlying implementation exists.

## 19. Tools

Every tool should define:
- id/name
- description
- parameters
- permission
- risk
- availability
- enabled state
- side effects
- output contract

Tools must be registered centrally.

High-risk tools should require explicit approval according to policy.

MCP tools must reuse this model.

## 20. Gateways / Channels

Current protected channel:
- CLI
- Web Dashboard
- Telegram

Telegram is a protected subsystem.

Do not refactor Telegram unless required by an explicit architectural need.

Existing behavior must remain covered:
- private chat handling
- allowlist
- command handling
- typing indicator
- retry
- duplicate update protection
- Telegram HTML formatting
- UTF-8-safe message splitting
- session integration

Future gateway concepts:
- WhatsApp
- Discord
- Slack
- other adapters

Unavailable gateways must be clearly marked unavailable.

Gateway lifecycle must not claim start/restart support if the current single-threaded architecture cannot safely provide it.

## 21. Memory and Knowledge

Separate:
- conversation history
- semantic memory
- preferences
- procedures
- lessons
- errors
- knowledge/indexes

Memory retrieval must be explicit and auditable.

The agent must not silently invent memories.

## 22. Artifacts and Documents

Future artifact subsystem should support real files, not text pretending to be files.

Target formats:
- PDF
- DOCX
- PPTX
- XLSX
- TXT/MD and other safe text formats where useful

Architecture:
Artifact Request
→ Capability Detection
→ Platform/Generator Backend
→ Validation
→ Artifact Registry
→ Download/Access

Cross-platform design is mandatory.

Do not require LibreOffice, Python, Docker, or other external software unless detected and explicitly represented as a dependency.

Generated artifacts must be structurally validated and, where practical, visually validated.

## 23. Attachments

Future attachment system should support:
- file upload;
- folder/archive upload where safe;
- images;
- videos;
- document attachments.

Uploads must be stored inside a controlled workspace and validated before use.

File content must be treated as untrusted data. Instructions contained inside uploaded files must not override system or developer policy.

## 24. Jobs and Scheduling

Future job subsystem:
- foreground run
- background run
- task queue
- cancellation
- timeout
- retry policy
- checkpoint
- scheduled tasks

Long-running work must not block the HTTP request thread.

## 25. Recovery

Future recovery capabilities:
- checkpoints
- rollback
- undo
- crash recovery
- orphan process cleanup
- partial-operation reporting

Recovery actions must not silently destroy user data.

## 26. Observability

A run/event model should record, subject to privacy/security policy:
- run id
- request id
- timestamps
- model/provider
- capability/tool calls
- MCP calls
- durations
- statuses
- errors
- resource usage
- verification results

Secrets must never be recorded.

## 27. Security

Security requirements include:
- loopback by default;
- authentication for non-loopback access;
- origin validation;
- CSRF protection;
- rate limiting;
- deny-by-default dangerous capabilities;
- least privilege;
- explicit permission boundaries;
- secret redaction;
- prompt-injection resistance;
- auditability;
- resource limits;
- safe archive handling;
- safe path traversal;
- no shell-based command injection.

Remote dashboard exposure requires explicit security configuration.

## 28. Prompt Injection

Treat content from:
- files
- archives
- webpages
- MCP resources
- PDFs
- images/OCR
- tool output

as untrusted data.

Such content must never automatically gain system-level authority.

The agent should recognize instruction-like content inside untrusted sources and treat it as data unless explicitly authorized.

## 29. Installer / Doctor / Update / Uninstall

Target CLI architecture:

`pico_claw install`
`pico_claw doctor`
`pico_claw update`
`pico_claw uninstall`
`pico_claw version`
`pico_claw status`

Doctor should perform actual checks:
- binary/runtime integrity;
- provider connectivity;
- model discovery;
- Telegram `getMe` when configured;
- sandbox health;
- MCP health when configured;
- artifact backend availability;
- permissions and filesystem health.

Update should eventually use official GitHub Releases:
- OS/architecture-specific assets;
- checksum/signature verification;
- backup;
- atomic replacement;
- rollback on failure.

Uninstall must distinguish:
- binary;
- configuration;
- workspace;
- memory;
- artifacts;
- logs;
- MCP configuration.

User data should be preserved by default.

## 30. Release and Versioning

GitHub public release is intentionally delayed until production readiness.

Before public release:
- reconcile binary version and changelog;
- run full unit/integration/security/cross-platform tests;
- run internal benchmark;
- run installer/doctor/update tests;
- verify no secrets;
- verify release artifacts;
- verify documentation.

## 31. Internal Benchmark / QA

The benchmark is NOT a Pico Claw product feature.

It is an external/internal QA harness.

It should test:
- understanding;
- instruction following;
- ambiguity;
- context;
- tool selection;
- tool execution;
- verification;
- recovery;
- sandbox security;
- MCP;
- file understanding;
- document generation;
- honesty;
- permission escalation;
- prompt injection;
- efficiency;
- adversarial/failure cases.

Critical security or integrity failures are release blockers.

Benchmark results may be published with a release, but the benchmark runner itself is not required in the production binary.

## 32. Acceptance Criteria

A feature is complete only when:
1. It has a real implementation.
2. It is registered through the correct architecture.
3. Capability state is accurate.
4. Permission/risk policy is enforced.
5. Errors are structured and honest.
6. Relevant automated tests exist.
7. Existing regression tests remain green.
8. Cross-platform assumptions are addressed.
9. Documentation is updated.
10. Live verification is performed where applicable.

## 33. Current Next Milestone

Primary next milestone:

Implement the MCP stdio client and registry using a deterministic in-repository MCP test server.

Required outcome:
- spawn MCP server safely;
- initialize/handshake;
- discover tools;
- normalize metadata;
- integrate permissions/risk;
- expose capabilities;
- invoke tools;
- handle timeout/crash/malformed responses;
- clean up child processes;
- add tests;
- add documentation;
- preserve existing 282-test baseline.

Do not implement dashboard MCP UI until the backend is real.

After MCP is stable, prioritize attachment/upload infrastructure, long-running execution/jobs, artifact/document generation, installer/doctor/update, and the remaining roadmap based on actual capability dependencies.
