# Changelog

## Unreleased — Production readiness (operations, recovery, observability)

### Added

- **Remote dashboard login flow**: with `PICO_CLAW_DASHBOARD_TOKEN` set, the
  dashboard shell (`GET /`) is now served without a token so a remote browser
  can load the control plane; every data route (API, chat, health, artifacts,
  uploads) stays token-protected and answers `401` without one. The embedded
  dashboard gained a real login screen (password-style token input,
  verify-before-store, inline errors — no `window.prompt()`), stores the
  token in `localStorage.picoToken`, sends it as `X-Pico-Token` on every API
  call, re-opens the gate on any `401`, and offers a ⏻ sign-out control that
  clears it (visible only when the runtime reports `auth_required`, now part
  of `GET /api/status`). Loopback-without-token behavior is unchanged. The
  server-side gate is now the testable `authGate`/`validateBind` pair
  (`src/interfaces/http.zig`); the non-loopback bind-without-token startup
  refusal and both accepted headers (`X-Pico-Token`,
  `Authorization: Bearer`) are regression-tested.

### Fixed

- **Attachment / upload infrastructure** (`src/runtime/attachments.zig`):
  controlled ingestion into `workspace/uploads/<id>/` with client-name
  validation (traversal, absolute/UNC/drive, reserved device names, control
  characters all rejected — never sanitized silently), content-derived MIME
  type (extensions and client claims are never trusted), SHA-256, per-file
  size limit and total quota, `meta.json` sidecars, ZIP extraction through the
  sandbox extractor (zip-slip refusal, entry/size limits, no link following),
  and an orphan scan that removes interrupted uploads at startup.
- **Long-running job runtime** (`src/core/jobs.zig`): one bounded worker
  thread; explicit lifecycle (`queued → running → completed | failed |
  timed_out`, with `cancelling → cancelled`); cooperative cancellation and
  deadlines via `checkpoint()`; graceful shutdown that joins the worker and
  cancels everything queued; bounded job history; every job is linked to a
  run in the inspector. Client disconnects never cancel jobs — only an
  explicit cancel does, and a finished job never reports cancelled.
- **Artifact system** (`src/services/artifacts.zig`): real, validated files in
  `workspace/artifacts/<id>/`. Supported natively: `txt`, `md`, `json`, `csv`,
  `zip` (sandbox zip writer). PDF/DOCX/PPTX/XLSX are reported as
  **UNSUPPORTED** — the runtime never writes a fake file. Every artifact
  carries id, filename, kind, size, SHA-256 (computed from what is on disk),
  generator, validation state, optional job id.
- **Run inspector** (`src/core/runs.zig`): bounded run/event store shared by
  the service and the job worker. Details containing credential markers are
  replaced wholesale with `[redacted]`; events are capped and overflow is
  counted. Jobs, doctor passes, and future chat turns all flow through it.
- **Doctor** (`src/services/doctor.zig`): real checks with five honest states
  (pass/warn/fail/unavailable/unsupported) — configuration, provider model
  discovery (real HTTP round trip), Telegram `getMe` when configured, a
  sandbox write/read/delete cycle, MCP server states, attachments, artifacts,
  jobs, runs. Available on the CLI and at `GET /api/doctor`.
- **Installer foundations**: `pico_claw install` (creates workspace/data,
  copies the example config only when absent, never overwrites),
  `pico_claw uninstall [--yes]` (dry run by default; deletes config/,
  workspace/, data/ and memory files only with --yes; the binary is always
  removed manually), `pico_claw update --check` (prints the release
  coordinates; binary download/replacement is UNSUPPORTED until signed
  release assets exist).
- **Control-plane APIs**: `GET/POST /api/attachments` (raw upload with
  `?name=`), `GET/DELETE /api/attachments/:id`, `POST /api/attachments/:id/extract`
  (background job), `GET/POST /api/artifacts`, `GET/DELETE /api/artifacts/:id`,
  `GET /api/artifacts/:id/content` (download with honest content type),
  `GET/POST /api/jobs`, `GET /api/jobs/:id`, `POST /api/jobs/:id/cancel`,
  `GET /api/events`, `GET /api/events/:id`, `GET /api/doctor`.
- **Dashboard pages**: Doctor, Jobs, Files — every button maps to a real API
  operation; the liquid-glass design and no-CDN rule are preserved.
- Capability manifest now reports attachments/artifacts/jobs/runs exactly as
  attached, and the agent prompt states artifact format support honestly.

### Notes

- The uploads transport ceiling is 20 MB (per-route); the service enforces
  its own 16 MB per-attachment limit and a 128 MB total quota by default.
- `uninstall --yes` deletes user data (workspace, memory files) by explicit
  request only; without the flag nothing is touched.

## Unreleased — MCP stdio client

### Added

- **Real MCP stdio client** (`src/mcp/`): configuration model, per-server
  registry with a lifecycle state machine (`disabled`, `configured`,
  `starting`, `running`, `stopped`, `error`), process spawning without a shell,
  JSON-RPC 2.0 newline framing, `initialize` handshake, `tools/list`
  discovery with pagination, `tools/call` invocation, per-request timeouts,
  crash/EOF/malformed-response detection, bounded stderr accounting, and
  deterministic child cleanup.
- **Tool integration**: every discovered tool becomes a namespaced entry
  (`mcp.<server>.<tool>`) in the existing `ToolRegistry` with permission/risk
  metadata, so MCP never bypasses the execution boundary. Stopping a server
  disables its tools; a crashed server moves to `error` and disables them.
- **Capability reporting**: `GET /api/capabilities` and the agent system
  prompt now report MCP only when a server is actually running.
- **Control plane**: `GET /api/mcp`, `GET /api/mcp/:id`, and
  `POST /api/mcp/:id/{start,stop,restart,test,enable,disable}` with the
  standard success/error envelope. No create/update/delete endpoint exists
  yet (runtime mutation of process-spawning config is intentionally deferred).
- **Deterministic MCP test server** (`pico_mcp_test_server`, built by
  `zig build test`) plus 48 new tests covering configuration validation,
  startup, handshake, initialization timeout/failure, discovery, metadata
  normalization, invocation, invalid arguments, disabled/unavailable servers,
  invocation timeout, crash, malformed responses, correlation errors,
  cleanup, multiple servers, namespacing, capability manifest, secret
  redaction, and prompt-injection-as-data.
- Documentation: `docs/mcp.md`, `config/mcp.example.json`.

### Security

- MCP children receive **only** the environment configured in
  `config/mcp.json`; the parent environment (and its credentials) is never
  inherited.
- Environment **values** are never rendered: API output exposes names only.
- Tool descriptions and results are treated as untrusted data; a listing that
  contains a non-portable tool name is refused as a whole.
- MCP is deny-by-default: file kill switch, per-server enable switch, and an
  explicit start (or `auto_start`) are all required.

### Fixed

- **Provider requests are bounded (F-PROV-01)**: every provider HTTP request
  (chat completions and model discovery) now runs under a hard deadline —
  `settings.request_timeout_ms`, clamped to 1–600000 ms, default 120000, never
  disableable. The blocking exchange runs as a concurrent task; on deadline
  the connection is shutdown and the exchange is joined (abandoned as a last
  resort when no socket exists yet), so a hung provider endpoint fails with
  `RequestTimeout` instead of blocking the single-threaded runtime forever.
  Without available concurrency the request is refused
  (`RequestDeadlineUnavailable`) rather than silently becoming unbounded.
- **Malformed `<tool_call>` handling (F-BRAIN-01)**: the brain now repairs
  benign formatting safely — prose around exactly one complete call, a
  missing closer whose payload still parses, `input` sent as a JSON
  object/array (re-serialized to compact JSON), unknown fields ignored, and
  missing/`null` input treated as empty. Everything else (multiple calls in
  one response, empty payload, non-string/non-object input types, oversized
  names) is refused and fed back through a bounded repair loop
  (`max_tool_repairs = 2`, fixed protocol-correction message, invalid response
  kept in history); after the budget is spent the respond fails honestly with
  `MalformedToolCall`.
- **Zip artifacts are wired end to end (F-ART-01)**: `POST /api/artifacts`
  with `{"kind":"zip","filename","sources":[...]}` now builds a real archive
  from workspace-relative sources (max 64) through the sandbox zip writer;
  missing/empty `sources` → `INVALID_VALUE`, a source that does not exist →
  `ARTIFACT_FAILED`. The advertised capability was previously untrue at the
  service/transport layer even though the store backend existed.

### Notes

- MCP Streamable HTTP transport, resources/prompts/sampling, and any MCP
  dashboard UI are **not implemented** and are reported as unavailable.
- `POST`/`GET` on a known route with the wrong method now answers `405`
  instead of `500` (the error envelope gained the `METHOD_NOT_ALLOWED`
  mapping).

## Unreleased — Sandbox runtime

### Fixed

- **Dashboard rendered CSS as visible text**: `dashboard.html` contained a premature `</style>` after the base stylesheet, so the chat-workspace styles parsed as a document text node and a stray closing tag followed. The stylesheet is one balanced block again; the served page is valid HTML (`GET /` verified at runtime).

### Added

- **Sandbox runtime** (`src/runtime/`): an explicit workspace sandbox at `./workspace/` with strict path policy (absolute/UNC/device/`..`/reserved-name/control-character rejection), component-by-component directory traversal with symlink following disabled (junction/reparse-point escape refused), and resource limits (file, output, archive, extraction, entries, timeout). See `docs/sandbox.md`.
- **Sandbox tools in the agent registry** (`filesystem.list/read/write/edit/stat/mkdir/delete/move/copy/search`, `process.exec`, `archive.list/extract/create`, `media.inspect/thumbnail`), all JSON-in/JSON-out, carrying permission/risk metadata. `process.exec` is allowlist-gated (empty list = denied), spawns no shell, enforces timeouts and output limits, and reports the real exit code; archives reject zip-slip entries before extracting anything and skip link entries; media inspection reports honest metadata (and `unsupported` for thumbnails/frames) without ever claiming vision.
- **Agent instructions**: the shared tool prompt now states the no-fake-results rules (never claim a read/command/media result that did not actually happen; inspect → act → verify).
- **Dashboard Sandbox page** with `GET /api/sandbox`: workspace root, grants, executable allowlist, environment variable *names* (values are never exposed), and every resource limit.

### Notes

- ~~MCP client/server support is **not implemented** in this release; no MCP endpoints or UI exist and none are simulated.~~ Superseded: the MCP stdio client landed in the *Unreleased — MCP stdio client* section above. Streamable HTTP transport, resources/prompts, and dashboard UI remain unimplemented.

## v0.2.0 — Agent Control Plane


### Added

- **Runtime capability manifest** (`src/core/capabilities.zig`): the agent's system context now includes an authoritative capability section assembled from live runtime state — channels (CLI/Telegram/dashboard), gateways (receive/send/commands), provider (connected, discovery, streaming, vision, tool calling), workspace (read/write/execute/root), registered tools, and memory. The model can no longer claim a channel, tool, or action the runtime does not expose: disabled tools are hidden from the Brain's tool instructions, and a Telegram token alone never makes the channel "enabled" (only an actually-running loop does). The manifest is also served at `GET /api/capabilities`.
- **Application service layer** (`src/services/`): a presentation-neutral boundary between every channel and the agent runtime. HTTP handlers now call `Services` methods and never touch stores, the provider, or the tool registry directly. The layer includes the gateway lifecycle manager, the model catalog, runtime settings, and profile management.
- **Dynamic model discovery**: `Provider.listModels` queries the OpenAI-compatible `GET /models` endpoint with the existing bearer credentials; the parser normalizes ids, display names, owners, freshness, optional capability blocks, and context limits without hardcoding any model name. `GET /api/models` serves the cached catalog with a fetch timestamp; `POST /api/models/refresh` forces a refresh; `PUT /api/settings` persists an active-model override (validated, no keys).
- **Gateway control plane**: `GET /api/gateways` and `GET /api/gateways/:name` report Telegram's real state (configured/enabled/state/allowed users/safe bot identity/last error) plus explicitly *planned* transports (WhatsApp, Discord, Slack) that never pretend to be functional. `POST /api/gateways/:name/{enable,disable,start,stop,restart,test}` drive an honest lifecycle: `start`/`restart` from the dashboard return 501 with an actionable message because the single-threaded `serve` process cannot host the poll loop, `test` performs a real `getMe` probe and caches only safe identity fields, and enable/disable toggle real runtime state reflected in the capability manifest.
- **Telegram agent tool** (`src/channels/telegram_tool.zig`): separates the Telegram *channel* from a Telegram *tool*. Registration requires the explicit `TELEGRAM_TOOL_ENABLED` grant; operations are limited to `get_me`, `get_chat`, and `send_message`; outbound sends are restricted to the `TELEGRAM_ALLOWED_USERS` allowlist (an empty allowlist denies everything); message length is bounded; failures are reported as failures, never claimed as success. The tool appears in the manifest with `network` permission and `high` risk.
- **Agent run inspector**: `GET /api/runs` and `GET /api/runs/:id` expose the existing task journal as a stage-by-stage run view (plan steps, tool calls with names/states/durations/input hashes, provider attempts with byte totals, escalation metadata). The journal still never stores task text, tool input/output, or provider payloads.
- **Profiles** (`src/services/profiles.zig`): personality/context configurations under `config/profiles/<id>/` with soul/memory/instructions/behavior/custom files. Ids are validated (`[a-z0-9-_]{1,64}`), file keys come from a fixed whitelist (arbitrary browser paths are impossible), every write uses the link-safe atomic writer, and activation materializes SOUL.md/MEMORY.md through the owner context, reloads it, and recomposes the runtime system prompt (policy first, capabilities second, profile sections last and labeled untrusted). Full CRUD + duplicate + activate at `/api/profiles`.
- **Dashboard control plane rewrite** (`src/interfaces/dashboard.html`, still embedded, dependency-free): persistent left navigation (Chat, Overview, Sessions, Models, Profiles, Skills, Tools, Memory, Gateways, Config, Settings, Logs) with a runtime/version footer, liquid-glass design (translucent surfaces, backdrop blur, radial gradients, 16-24px radii, restrained animation), dark/light themes with system detection and a manual switch, mobile drawer navigation, hash routing, toasts, confirm dialogs, visible focus states, and loading/empty/error/disabled states on every page. Chat remains the primary workspace with a conversation list (new/rename/delete/clear), a model selector backed by `GET /api/models`, pre-rendered markdown/code blocks with copy buttons, error retry, thinking state, Enter/Shift+Enter handling, and an auto-growing composer.
- **Settings & config pages**: `GET /api/settings` / `PUT /api/settings` expose and persist only what the runtime honors today (active model override, provider retry attempts, clamped 1-5), with read-only runtime facts (bind address, auth state, workspace, data dir). `GET /api/config` gives a structured, schema-shaped view of provider, Telegram, runtime, owner-context, and routing state. The Logs page renders the run inspector.
- **Dashboard security** (loopback default preserved): optional `PICO_CLAW_DASHBOARD_TOKEN` enables token authentication (`Authorization: Bearer` or `X-Pico-Token`, length-checked comparison); binding any non-loopback address without a token is refused at startup; state-changing requests validate the `Origin` header against the request host (CSRF protection that also covers the unauthenticated loopback case); and state-changing endpoints are rate-limited (120/minute fixed window). New environment knobs: `PICO_CLAW_DASHBOARD_HOST`, `PICO_CLAW_DASHBOARD_PORT`, `PICO_CLAW_DASHBOARD_TOKEN`.
- **API envelope**: every new `/api` endpoint answers `{"ok":true,"data":…}` or `{"ok":false,"error":{"code":"…","message":"…"}}` with stable machine-readable codes (no stack traces, no secrets). Legacy v1 routes (`/chat`, `/health`, legacy flat-shape status/sessions) keep their exact historical bodies for compatibility.
- Tool manifest metadata: tools now carry permission (standard/network/elevated), risk (low/medium/high), documented parameters, and an enable flag; `GET /api/tools` serves the manifest and enable/disable routes change live state (disabled tools refuse execution and disappear from the agent's instructions).
- Session management APIs: create/rename/delete/clear/detail (`GET /api/sessions/:id` returns bounded message history excluding system-policy messages), and per-session chat send (`POST /api/sessions/:id/send`) that reuses the exact agent path as `/chat`.
- Memory APIs: typed listing with counts, relevance-ranked search, per-entry forget (persisted by rewriting the typed JSONL store), and per-type or full clear. Memory listing never reinterprets conversation history as long-term memory.

### Changed

- `main` composes the system prompt for every channel (CLI, dashboard sessions) through the service layer: config policy, then the capability section, then the active profile's instruction sections. Skills can be enabled/disabled at runtime (a skill's linked tool follows its state) and both change the capability context immediately.
- The dashboard chat no longer depends on the single hard-coded dashboard identity: conversations are explicit session ids, and multi-conversation history survives page reloads via the session detail API (in-memory per process, as before).
- Tool registry: added `setEnabled`/`isEnabled`; disabled tools return `error.ToolDisabled` which the Brain feeds back to the provider as a protocol error instead of executing.



## Unreleased

### Added

- Telegram reply formatting: agent replies are converted to Telegram `parse_mode=HTML` by a shared, repair-oriented Markdown formatter (`src/format.zig`) — bold, italic, strikethrough, inline code, fenced code blocks with a sanitized language tag, ATX headings, `-`/`*` bullet lists, and `http(s)`/`telegram` links. Every `<`, `>`, and `&` is escaped (including inside code), unclosed emphasis is auto-closed into valid HTML, snake_case is never corrupted, and no raw Markdown reaches the user.
- Telegram long-reply chunking (`format.chunkAndFormat`): parts split at line boundaries with UTF-8-safe hard cuts, an open code fence is closed at the end of a part and re-opened at the start of the next, and every part is valid HTML within the 4000-character limit by construction. The plain-text `splitMessage` fallback never splits a UTF-8 sequence either.
- Telegram UX: a `typing` chat action is sent while the agent works, `sendMessage` retries transient failures up to three attempts (1s delay), delivery stops after a failed part to preserve reply ordering, and updates whose id is below the confirmed long-poll offset are skipped (duplicate update protection). Error notices stay generic ("AI request failed; please try again later.") — no HTTP codes, raw JSON, provider headers, or stack traces.
- Telegram commands: `/start`, `/help`, `/status`, and `/clear` (exact, case-insensitive matches; anything else is agent input). `/status` prints a compact, secret-free agent summary (model, provider URL, store counts, active chats); `/clear` resets only that chat's in-memory session context.
- Web dashboard overhaul: modern responsive single-page UI (`src/interfaces/dashboard.html`, embedded at build time) with Chat, Status, and Sessions views, dark/light theme (follows the system, switchable, remembered), message bubbles, typing indicator, error states with retry, auto-scroll, Enter-to-send / Shift+Enter for newline, and Markdown/code-block rendering driven by the same server-side formatter the Telegram channel uses (`POST /chat` now returns `response` plus pre-rendered, escaped `html`).
- Dashboard API: `GET /api/status` (agent/version/model/provider identifiers, memory/task/proposal counts, Telegram channel state, session count — no secrets), `GET /api/sessions` (live session ids and message counts), and `POST /api/sessions/clear` (clears one in-memory session; never returns content).
- `serve` now routes dashboard chat through the shared `SessionStore` (chat identity `dashboard`), so CLI, Telegram, and the dashboard all run the same Agent Core through the same session layer; Telegram and dashboard conversations also gain the CLI's teacher-routing and proposal-recording behavior.
- Channels: `src/channels/` adds a small channel core (`ChannelKind`, `ChannelState`, owned `InboundMessage`) and a bounded per-chat session layer (`SessionStore`: 8 concurrent chats, least-recently-used eviction) that reuses the exact `Conversation.send` agent path as CLI chat and shares the same durable memory, experience, strategy, knowledge, task, and proposal stores.
- Telegram adapter: environment-only configuration (`TELEGRAM_ENABLED`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS` — no second config system), a deny-by-default user allowlist whose denial notice only echoes the caller's own id, private-text-only update parsing (groups, edits, media, and senderless updates ignored), offset-based `getUpdates` long polling with exponential backoff (1s doubling, capped at 30s), 4000-character newline-preferring reply chunking (Telegram's hard limit is 4096), graceful Ctrl+C (Windows `SetConsoleCtrlHandler`) and SIGINT/SIGTERM (POSIX `sigaction`) shutdown, and a bot token that is never printed, logged, or embedded in diagnostics.
- `pico_claw channel [status|telegram]`: prints the Telegram channel state (`disabled`, `not configured (missing token)`, `enabled`) or runs the polling loop; `pico_claw status` reports the channel in a new `Channels` section. Channel commands do not require `PICO_CLAW_API_KEY`.
- Learning proposals (M4): every finished task is evaluated from **measured facts** of the M2/M3 task record (state, error kind/code, attempts, escalations, replayed work, tool calls, latency, byte totals) and — only when there is something to learn — becomes a structured proposal with supporting evidence, the observed problem, a suggested change, an explained evidence-strength confidence (explicitly not a quality score), and fixed constraints. Proposals persist in a bounded content-free journal (`data/proposals/proposals.jsonl`, newest 64) with input validation and corrupt-line recovery.
- `pico_claw proposals [list|accept <id>|reject <id>]`: listing shows metadata and provenance only; accepting or rejecting records a terminal, persisted decision. Accepting prints the explicit manual application instructions and **never runs code or modifies other stores**.
- `pico_claw status` reports proposal totals (`Proposals: n (x proposed, y accepted, z rejected)`).
- Teacher routing (M3): when the primary provider exhausts its bounded attempts with a provider-class error and a teacher is configured, the task escalates **once** to a compact, privacy-bounded teacher request. The routing decision is a pure function (`core/router.zig`) with explicit, documented conditions (no teacher, local-only mode, non-provider failure, escalation budget, request byte budget) and is recorded in the M2 task journal (`escalation: escalated/skipped, reason, model label, ok, latency, byte totals, stable error code`).
- Compact escalation requests carry only the agent policy, an escalation briefing with normalized error metadata, and the task itself — never owner files (SOUL/MEMORY), memory, knowledge, conversation history, or tool outputs — and never execute tools, so an escalation cannot repeat a side effect.
- Fallback semantics: a teacher failure fails the task with the original primary error (recorded separately in the escalation entry) and is never retried or re-escalated.
- New optional `settings` keys: `routing_teacher_base_url`, `routing_teacher_model` (both required for escalation), `routing_local_only` (privacy mode blocking the remote teacher), and `routing_teacher_max_request_bytes` (default 8192, clamped 1024–65536). Without them, behavior is identical to M2.
- `pico_claw status` reports `Teacher: <model|disabled>` and `Local-only: <bool>`.

- `pico_claw status` reports `Teacher: <model|disabled>` and `Local-only: <bool>`.
- Task state and observability (M2): every `Conversation.send` is a task with explicit, validated task/step state transitions (`pending → running → completed | failed`, plus `replayed` for checkpointed skips), a bounded content-free JSONL journal (`data/tasks/journal.jsonl`, newest 64 tasks), and secret-free observability records: planner route, plan steps with durations, provider tool calls with input hashes, per-attempt latency and request/reply byte totals, and normalized errors (kind + stable error code, never free-form messages).
- Checkpoints and resume: when a task fails, the steps and tool calls that completed stay in the journal; re-sending the same task seeds a new run from the latest failed run, so completed side effects are replayed (executor steps get a bounded replay marker, brain tool calls are answered with a replay marker) instead of executed again. A completed run never makes a later identical task resumable.
- Bounded provider retries via the optional `settings.task_max_attempts` key (clamped 1–5, default `1` keeps the pre-M2 single-attempt behavior). Each attempt uses a fresh request context; only provider-class failures are retried.
- `pico_claw status` now reports task totals (`Tasks: n (x completed, y failed)`), and `Conversation` exposes `lastTask`/task counters for the upcoming dashboard.
- Regression tests for symlink/junction escapes on both read and write (symlink-based where the platform allows link creation, junction-based on Windows where symlink privilege is absent), nested relative path compatibility, small-budget truncation markers, non-UTF-8 sanitization (loaded and truncated), memory budget interaction with distinct soul/memory/combined values, provider JSON encoding of invalid UTF-8, and configuration parsing (legacy configs without owner fields, valid new fields, negative/oversized budget values, malformed JSON, out-of-range `max_tokens`).
- Windows regression tests for a junction at the final path component (read refuses the linked destination, write refuses with `SymlinkEscape`) and for a reparse point present at the destination at rename time, which deterministically reproduces the state a swap during the write path's check-to-rename window produces. On Windows the symlink regression tests additionally fall back to `cmd /c mklink` when Zig's `symLink` is denied but the OS still allows link creation, so they run instead of skipping where the environment permits.

### Changed

- CLI presentation overhaul: quiet-by-default startup (banner, model/provider summary, status lines), ANSI color for hierarchy (brand cyan, success green, warning yellow, error red, dim metadata) with plain-text fallback when stdout is piped or `NO_COLOR` is set, a single-frame `Thinking` indicator while waiting for the provider, assistant replies printed verbatim as UTF-8 (no transliteration), clean provider-error messages instead of raw dumps, a restyled `status` report, and an aligned interactive `help`. No provider, task lifecycle, routing, memory, learning, or configuration behavior changed.
- Internal `[HTTP]`, `[Task]`, `[Proposal]`, and reflection diagnostics are silent by default and appear only with the new `--debug` flag (accepted at any command position). Debug diagnostics go to stderr, stay bounded, and never include the API key, the Authorization header, or full provider request/response bodies (regression-verified against a live provider). The `.env` loader summary line is debug-only as well.

### Security

- Channel hardening: the Telegram bot token lives only in the environment (or `.env`) and is never printed, logged, journaled, or embedded in diagnostics — request URLs that contain it are suppressed and API failures are reported through truncated, token-free descriptions. The allowlist denies by default; unauthorized senders receive a single fixed line (their own user id) and never reach the agent. Telegram content is untrusted data, channel messages never execute tools beyond the normal provider-directed loop, and the channel opens no listening port (outbound long polling only).
- Escalation privacy: the teacher request never contains owner files (SOUL/MEMORY), retrieved memory or knowledge, conversation history, tool inputs/outputs, or credentials, and the task journal never records request/reply content — only labels, hashes, byte totals, durations, and stable error codes (regression-tested).
- Owner files (`SOUL.md`, `MEMORY.md`) can no longer be read or written through symlinks, junctions, or other reparse points. Every path component is resolved to an open directory handle without following links (each open relative to the previously verified handle, so a link swapped in after validation cannot redirect the operation), reads go through the pinned handle, and the atomic write refuses a linked destination with an explicit error instead of following or overwriting it. Valid relative paths with real directories keep working.
- The final path component of owner-file access has no TOCTOU window on Windows either: the no-follow open (`FILE_OPEN_REPARSE_POINT` in Zig 0.16.0) binds the handle to the object as it existed at open time, validation reads that handle rather than a path, and the atomic-write rename is an entry-level replace inside the pinned parent that never writes through a reparse point swapped into the destination during the check-to-rename window. A junction at the final path component is now classified as a link (refused with `SymlinkEscape` on writes and reported as `invalid_path` on reads) instead of surfacing as a directory error.

### Fixed

- HTTP server: the request target (path) is now copied out of the connection reader's buffer before the request body is read. Previously the body read refilled that buffer and corrupted `request.head.target`, so every `POST` route (including the dashboard's `POST /chat`) could fall through to a 404 and, with certain body sizes, crash the process with an access violation.
- Provider response parsing now handles both body shapes by Content-Type: `application/json` completion objects are parsed as before, while `text/event-stream` bodies are parsed as proper SSE (comments ignored, empty lines dispatching events, `data:` payloads processed in order, `[DONE]` terminating the scan). Full completion objects (`choices[0].message.content`) and streamed deltas (`choices[0].delta.content`) are both supported, including servers that emit a bare JSON completion glued directly to `data: [DONE]`. UTF-8 content (Indonesian text, emoji) survives byte-exact. Diagnostics on parse failure are bounded and sanitized — the raw response is never printed in full, and the API key is never logged. A related startup crash on one corrupt experience-journal line now skips the line with a warning (same pattern as the other stores).
- Truncation is never silent: when the budget is too small for the full marker, progressively shorter markers are used down to `\n\n[truncated]`; a budget below that floor shows nothing and reports the `truncated` status explicitly.
- Non-UTF-8 owner file content is sanitized to valid UTF-8 (U+FFFD replacements) before entering prompts, and the provider request encoder never emits invalid UTF-8 or raw control characters, so requests stay valid JSON.
- `saveMemory` refreshes the active in-memory memory section after a successful save (with the same budgets as a fresh load); failed saves still leave both the file and the active state untouched.
- `zig build test` no longer emits a misleading `failed command: ...` line for successful runs: the build runner prints that line whenever a step writes to stderr, so expected diagnostics (corrupt-line skip notices) are suppressed under `builtin.is_test`. Real test failures still print and still exit non-zero.
- Windows terminal mojibake (`ΓöÇ`, `Γ£ô`, `≡ƒ`): UI glyphs are emitted as raw UTF-8 and the attached Windows console is switched to the UTF-8 code page (CP 65001) at startup; when that is not possible — or when `PICO_CLAW_ASCII` is set — the UI uses a pure-ASCII glyph set so legacy code pages can never render mojibake. Unit tests pin the glyph byte sequences (double-encoding would fail them) and the provider reply path keeps multi-byte content byte-exact.

### Changed

- Learning outcomes are **no longer promoted automatically**: the M1 reflection/lesson that previously wrote straight into the strategy and knowledge stores now becomes a `lesson` proposal in the proposal journal, applied only after human validation. Task and learning evaluation are separate paths (task facts vs labeled heuristics), and no quality score is claimed.
- `MEMORY.md` atomic updates flush file data before the rename; no crash durability beyond what the OS provides is claimed (the rename's directory entry is not synced).

### Added (prior)

- Owner context: optional `SOUL.md` (identity and style) and `MEMORY.md` (persistent owner notes) loaded from the working directory before each request, with explicit lower-priority labels and untrusted-data framing.
- Configurable owner context budgets (`settings.soul_budget_bytes`, `settings.memory_budget_bytes`, `settings.owner_budget_bytes`) and configurable paths (`settings.soul_path`, `settings.memory_path`). All new keys are optional; existing configs keep working with conservative defaults (4 KiB / 16 KiB / combined 20 KiB).
- Deterministic, section-aware truncation that keeps earlier sections, never splits UTF-8 characters, never modifies source files, and reports the condition explicitly.
- Atomic `MEMORY.md` replacement (temp file + rename) so failed updates leave previous data untouched.
- `SOUL.md` and `MEMORY.md` are ignored by Git; simple templates in `SOUL.example.md` and `MEMORY.example.md`.

### Fixed

- `zig build test` now compiles `src/tests.zig` as the test root, so the documented command actually runs the full inline test suite (76 tests). It previously compiled a zero-test binary because the root file (`src/main.zig`) contains no `test` blocks, so no tests were discovered.

## v0.1.0

### Added

- Zig-native CLI with `chat`, `serve`, `status`, `--help`, and `--version`.
- Conversation orchestration with provider context, memory, knowledge, strategy, planner, executor, and tool registry.
- Buffered OpenAI-style chat-completions provider using `PICO_CLAW_API_KEY`.
- Calculator, workspace filesystem, and restricted system-information tools.
- Persistent JSONL memory, experience, strategy, and knowledge stores.
- Bounded memory and knowledge retrieval.
- Deterministic evaluation, reflection, learning, strategy aggregation, and learned knowledge.
- Static skill metadata and selection guidance.
- Loopback HTTP server, health route, chat route, and static dashboard.

### Security

- Loopback-only server binding.
- API key sourced from environment and omitted from dashboard.
- Filesystem absolute-path and traversal rejection.
- System tool restricted to runtime information; no arbitrary shell execution.
- 1 MiB HTTP body limit, malformed JSON handling, and generic provider-facing HTTP errors.
- No dynamic code execution or self-modifying source.

### Testing

- Unit tests cover context, tools, registry, brain tool loop, planner, executor, persistence, retrieval, evaluation, reflection, learning, HTTP routing, and security restrictions.
- Release checks use Zig 0.16.0: formatting, tests, and build.

### Limitations

- Buffered provider response only; no SSE/chunk streaming.
- Filesystem plans lack typed command grammar and are not directly executed by conversation's Executor path.
- Knowledge retrieval is substring-based, not semantic/vector search.
- Static dashboard has no authentication, session, or history UI.
- Help/version/status initialize subsystems before command dispatch.
- No WhatsApp, Telegram, browser automation, dynamic plugins, external dependency system, self-modifying code, or public server binding.
