# Pico Claw

Pico Claw v0.1.0 is a lightweight personal AI agent runtime written in Zig. It combines local orchestration with provider-based AI, memory, tools, planning, execution, experience, reflection, learning, and persistent knowledge in a small native application with no external package dependencies.

Independent implementation inspired by general modern personal-agent architecture. Not official Hermes Agent or OpenClaw fork.

## Features

- Native Zig 0.16.0 executable
- Agent control plane dashboard (embedded, dependency-free): persistent sidebar navigation over Chat, Overview, Sessions, Models, Profiles, Skills, Tools, Memory, Gateways, Config, Settings, and Logs; liquid-glass design with dark/light themes, mobile drawer, and professional loading/empty/error states
- Runtime capability manifest injected into the agent context and served at `/api/capabilities` — the model can only claim channels, tools, and actions the runtime actually exposes
- Dynamic provider model discovery (`GET /v1/models`), a cached model catalog, and a validated active-model override
- Gateway control plane: Telegram lifecycle state, real connection test, and explicitly planned (not faked) future transports
- Profiles for identity/SOUL/MEMORY/instructions management with strict path containment and atomic activation
- Agent run inspector over the content-free task journal (stages, tool calls, provider attempts)
- Dashboard APIs behind a consistent `{"ok":true,"data":…}` envelope with token auth, origin validation, and rate limiting on state-changing routes
- Telegram channel: long-polling adapter with env-only configuration, deny-by-default user allowlist, per-chat sessions, HTML-formatted replies, `/start` `/help` `/status` `/clear` commands, and UTF-8-safe chunking
- OpenAI-style chat-completions provider adapter
- Calculator, workspace filesystem, and safe system-information tools
- ToolRegistry and bounded Brain tool-calling loop
- Planner and Executor for supported deterministic plans
- Persistent JSONL memory, experience, strategy, and knowledge
- Optional SOUL.md/MEMORY.md owner context with byte budgets and atomic updates
- Explicit task/step states, JSONL task journal with checkpoints, bounded provider retries, and secret-free route/tool/latency/usage records
- Teacher routing: bounded, measured escalation to a configured teacher provider on primary-provider failure, with compact privacy-bounded requests and a full fallback path
- Learning proposals: evidence-based post-task evaluation, structured lesson/review proposals with provenance and explained confidence, a bounded content-free proposal journal, and a `proposals` CLI for listing and accept/reject decisions (nothing promotes automatically)
- Deterministic evaluation, reflection, and learning
- Static skill metadata for arithmetic, filesystem, and reasoning

## Architecture and agent flow

```text
CLI / HTTP / Dashboard / Telegram channel
        |
   Conversation
        |
Memory retrieval ---- Knowledge retrieval ---- Strategy selection
        |
     Planner
        |
    Executor
        |
 ToolRegistry / Tools
        |
 Brain / Provider
        |
 Experience -> Evaluation -> Reflection -> Learning
        |
 StrategyStore + KnowledgeStore + Memory persistence
```

`Conversation` retrieves up to 10 memories, selects persisted strategy guidance, retrieves up to 3 knowledge entries, plans, directly executes calculator plans, builds context, then invokes `Brain`. Brain may execute registered tools through strict tool-call protocol, up to four calls. Successful replies create experience, strategy, and knowledge updates. See [architecture](docs/architecture.md).

## Components

- **Memory:** semantic, episodic, procedural, error, and preference JSONL under `data/memory/`; token relevance plus substring bonus.
- **Owner context:** optional `SOUL.md` (identity/style) and `MEMORY.md` (persistent owner notes) with configurable byte budgets, deterministic section-aware truncation, explicit untrusted-data labels, and atomic memory replacement.
- **Tasks:** every send is a task with validated state transitions, a content-free JSONL journal (`data/tasks/journal.jsonl`), checkpoints that replay completed work of a failed run instead of repeating its side effects, bounded provider retries, and normalized errors. See [tasks](docs/tasks.md).
- **Teacher routing:** when the primary provider fails after its bounded attempts and a teacher is configured, the task escalates once to a compact, privacy-bounded teacher request (policy + error metadata + task only — never owner files, memory, history, or tool outputs). Teacher failure falls back to the original error. See [routing](docs/routing.md).
- **Learning proposals:** finished tasks are evaluated from measured facts; failures, degraded runs, and M1 lessons become structured proposals (evidence, problem, suggestion, explained confidence, constraints) in a bounded content-free journal. Accept/reject is a human CLI decision that never applies anything automatically. See [learning proposals](docs/learning-proposals.md).
- **Experience/Learning:** completed replies are stored as success, scored, reflected on, and converted into lesson/action/confidence records.
- **Knowledge:** learned lessons keyed by strategy; bounded case-insensitive substring retrieval, not vector search.
- **Skills:** static metadata/guidance in `src/skills.zig`; no plugin loading or execution.
- **Planner:** recognizes arithmetic expressions and filesystem keywords; otherwise one reasoning step.
- **Executor:** bounded ToolRegistry execution. Current conversation directly executes calculator plans only.
- **Brain:** provider reasoning and exact `<tool_call>` loop.
- **Tools:** calculator; relative workspace file read/write; runtime information; optional Telegram actions (`get_me`, `get_chat`, allowlisted `send_message`) behind the explicit `TELEGRAM_TOOL_ENABLED` grant. System tool never starts shell.
- **Services layer:** `src/services/` is the presentation-neutral boundary between channels and the agent core (gateway lifecycle, model catalog, settings, profiles); HTTP handlers never touch agent internals directly.
- **Provider:** buffered POST to `<base_url>/chat/completions`; no SSE/chunk streaming.

Details: [memory](docs/memory.md), [learning](docs/experience-learning.md), [planner/executor](docs/planner-executor.md), [tools](docs/tools.md).

## CLI

```text
pico_claw chat
pico_claw serve
pico_claw status
pico_claw proposals [list|accept <id>|reject <id>]
pico_claw --debug chat
pico_claw --help
pico_claw --version
```

No argument defaults to `chat`. Interactive commands: `help`, `clear`, `exit`, `quit` and slash-prefixed equivalents. Top-level commands currently initialize config/subsystems before dispatch.

Output is quiet by default: internal `[HTTP]`, `[Task]`, and `[Proposal]` diagnostics are hidden. `--debug` (accepted at any position) enables those bounded diagnostics on stderr; they never include the API key, the Authorization header, or full provider request/response bodies. UI color uses ANSI codes on interactive terminals and falls back to plain text when stdout is piped or `NO_COLOR` is set.

UI glyphs (`╭─│✓⚠✗├─└─`) are emitted as raw UTF-8. On Windows the program switches the attached console to the UTF-8 code page (CP 65001) at startup when possible; if that fails (or when `PICO_CLAW_ASCII` is set), the UI falls back to pure-ASCII glyphs (`+ - |`, `[ok]`, `[!!]`, `[x]`). Provider replies are never transliterated.

## HTTP API and dashboard

`serve` listens only at `http://127.0.0.1:8080`:

- `GET /` static dashboard
- `GET /health` health JSON
- `POST /chat` with `{"message":"Hello"}`; success `{"response":"..."}`

Body limit: 1 MiB. See [API](docs/api.md) and [dashboard](docs/web-dashboard.md).

## Installation and quick start

Requires Zig 0.16.0, provider access, and Git when cloning.

```powershell
git clone <repository-url>
cd pico-claw
Copy-Item config/config.example.json config/config.json
$env:PICO_CLAW_API_KEY = "<your-provider-api-key>"
zig build
zig build run -- chat
```

Never commit local config or keys. See [installation](docs/installation.md).

## Configuration

```json
{
  "agent_name": "Pico Claw",
  "model": "tamandata",
  "base_url": "https://ai.tamandata.com/v1",
  "system_prompt": "You are Pico Claw, a lightweight, safe, and helpful personal AI agent.",
  "settings": { "temperature": 0.7, "max_tokens": 2048 }
}
```

All fields shown are required except the optional owner-context keys (`soul_path`, `memory_path`, `soul_budget_bytes`, `memory_budget_bytes`, `owner_budget_bytes`), which default to `SOUL.md`, `MEMORY.md`, and 4/16/20 KiB. v0.1.0 loads `temperature` and `max_tokens`, but provider wire request currently sends only `model` and `messages`. Key belongs only in `PICO_CLAW_API_KEY`. See [configuration](docs/configuration.md) and [SOUL and MEMORY](docs/soul-memory.md).

## Environment variables

Pico Claw requires one environment variable; the optional Telegram channel adds three more:

| Variable | Required for | Meaning |
|---|---|---|
| `PICO_CLAW_API_KEY` | `chat`, `serve` | API key of the primary provider (and of the teacher provider when teacher routing is configured). Never printed or logged. |
| `TELEGRAM_ENABLED` | `channel telegram` | `1`/`true`/`yes`/`on` (case-insensitive) enables the Telegram channel; unset or anything else keeps it disabled. |
| `TELEGRAM_BOT_TOKEN` | `channel telegram` (when enabled) | Bot token from @BotFather. Never printed or logged. |
| `TELEGRAM_ALLOWED_USERS` | recommended for `channel telegram` | Comma-separated numeric Telegram user ids; empty denies everyone. See [Telegram channel](docs/telegram.md). |

Copy `.env.example` to `.env` and fill in the key: the file is loaded from the
working directory at startup, **before** anything reads the environment.
Variables already set in the shell always win over `.env`; values are never
logged. `.env` is gitignored. All other settings (endpoint, model, teacher
routing, budgets) live in `config/config.json` — see the settings table above.
Missing or empty required settings fail fast with actionable messages:
`base_url`/`model` for every command, and the API key only for commands that
contact the provider (`chat`, `serve`).

## Usage

```powershell
zig build run -- --help
zig build run -- --version
zig build run -- status
zig build run -- chat
zig build run -- serve
zig build run -- channel status
```

Built executable: `zig-out\bin\pico_claw.exe` on Windows; `zig-out/bin/pico_claw` on Unix-like targets. Outputs depend on provider and local data. See [usage](docs/usage.md).


## Build and test

```text
zig fmt --check build.zig src
zig build test
zig build
```

Standard Zig target/optimization options exist; no custom flags. See [building](docs/building.md).

## Security

Loopback binding, environment-only key, no dashboard key exposure, traversal rejection, restricted system tool, request limit, malformed JSON rejection, and generic HTTP 500 errors. Local/controlled use only: no authentication, sessions, or rate limits. Do not expose publicly. See [SECURITY.md](SECURITY.md) and [security design](docs/security.md).

## Project structure

```text
config/             safe example; local config ignored
data/               local JSONL persistence; runtime files ignored
docs/               documentation
src/runtime/        sandbox runtime (workspace policy, filesystem/process/archive/media)
src/core/           agent, context, conversation, task state + journal
src/channels/       channel core, per-chat sessions, Telegram adapter
src/experience/     evaluation, reflection, learning, strategies
src/interfaces/     CLI, HTTP + dashboard API, dashboard.html, terminal UI
src/memory/         memory and persistence
src/tools/          registry and built-in tools
src/*.zig            brain, provider, planner, executor, knowledge, skills, owner, format
```

## Platform notes

Windows is validated development platform. Linux/macOS require target-specific build and runtime validation. No Android or published-binary claim. See [cross-platform](docs/cross-platform.md).

## Limitations

- Buffered provider HTTP; no SSE/chunk streaming.
- Filesystem planner emits natural-language input, not typed grammar, so Conversation does not directly execute it with Executor.
- Knowledge search uses bounded substring logic, not embeddings or semantic/vector DB.
- Static local dashboard has no authentication, rate limiting, or CSRF design, and no public binding; sessions are in-memory and per-process.
- SOUL.md/MEMORY.md budgets cap input bytes, not model tokens; owner-file selection is positional, not semantic.
- Help/version/status bootstrap subsystems first.
- Telegram channel scope: private text chats only (groups, media, and edits are ignored); per-chat session history is in-memory and LRU-evicted; commands are limited to `/start`, `/help`, `/status`, and `/clear`; no webhooks or group support.
- No WhatsApp, browser automation, dynamic plugins, external dependency system, dynamic code execution, or self-modifying source.

## Roadmap

Potential directions: typed planner/tool contracts, improved local UI/state handling, and provider transport options. Authentication, public deployment, integrations, vector storage, plugins, and streaming are not v0.1.0 commitments.

## Development, release, troubleshooting

Read [docs index](docs/README.md), [development](docs/development.md), [contributing](CONTRIBUTING.md), [troubleshooting](docs/troubleshooting.md), [changelog](CHANGELOG.md), and [release notes](docs/release.md).

## License

No license file currently included. No permission grant should be inferred until repository owner adds one.
