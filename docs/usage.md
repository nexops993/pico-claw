# Usage and CLI

## Top-level commands

| Command | Behavior |
|---|---|
| `pico_claw chat` | Starts interactive chat. Also default with no argument. |
| `pico_claw serve` | Starts the local dashboard/HTTP server at `127.0.0.1:8080`. See [Web dashboard](web-dashboard.md). |
| `pico_claw status` | Prints version, configured model, and counts for tools/memory/experiences/strategies/knowledge/tasks/proposals, provider/owner/routing state. |
| `pico_claw proposals [list\|accept <id>\|reject <id>]` | Lists learning proposals or records a manual accept/reject decision. |
| `pico_claw channel [status\|telegram]` | Prints the channel state or runs the Telegram polling loop. See [Telegram channel](telegram.md). |
| `pico_claw --debug <command>` | Enables bounded internal diagnostics (`[HTTP]`, task/proposal records) on stderr for that run. |
| `pico_claw --help` or `-h` | Prints top-level usage. |
| `pico_claw --version` | Prints `Pico Claw v0.1.0`. |

Simple commands accept exactly zero or one user argument; `proposals` and `channel` accept their documented subcommands (plus the optional `--debug` flag, accepted at any position). Unknown or extra arguments produce invalid-argument failure after usage. All commands currently load config, register tools, and load stores before dispatch.

### Output and diagnostics

- Normal output is quiet: no `[HTTP]`, `[Task]`, or `[Proposal]` lines, no provider response dumps, and no HTTP status/content-type noise.
- `--debug` turns on bounded internal diagnostics on stderr. It never prints the API key, the Authorization header, or full provider request/response bodies.
- UI color uses ANSI codes on interactive terminals. Output falls back to plain text when stdout is piped or when the `NO_COLOR` environment variable is set.
- UI glyphs are UTF-8. On Windows the console is switched to the UTF-8 code page (CP 65001) at startup when possible; set `PICO_CLAW_ASCII=1` (or when the switch fails) to get a pure-ASCII UI (`+ - |`, `[ok]`, `[!!]`, `[x]`). Provider reply content is never transliterated.
- Provider errors print a short, actionable message (for example `✗ AI request failed` with the normalized error name) instead of a raw response dump.

```powershell
zig build run -- chat
zig build run -- serve
zig build run -- status
zig build run -- --help
zig build run -- --version
```

## Interactive chat

Commands are `help`, `clear`, `exit`, and `quit`, with `/help`, `/clear`, `/exit`, and `/quit` accepted. `clear` resets in-memory conversation context to configured system prompt; it does not erase persistent stores.

For normal input, Conversation retrieves memory, strategy, and knowledge, creates plan, may execute calculator plan, and sends context to Brain/provider. Brain can request a registered tool only by returning exact tool-call envelope. Tool result is returned to provider until final text arrives or four-call limit is exceeded.

A successful provider reply is added to session and persisted as successful experience. Evaluation/reflection/learning update strategy and knowledge. v0.1.0 does not automatically create new long-term memory entries from chat; memory API/store loads existing JSONL data.

Examples are illustrative, not guaranteed provider outputs:

```text
> Calculate (2 + 3) * 4

  Pico Claw
  20

> 
```

Provider may instead use Brain tool protocol or phrase response differently. Filesystem access is provider-directed through strict Filesystem tool commands; natural-language planner filesystem steps are not directly executed by Conversation.

## Web dashboard (`serve`)

`pico_claw serve` builds the same agent stack as `chat`, routes it through the
shared session layer, and serves the embedded Agent Control Plane (liquid-glass
UI, persistent sidebar navigation, dark/light themes, mobile drawer) plus a
control-plane API. See [Web dashboard](web-dashboard.md) and [API](api.md) for
the full endpoint reference. The host, port, and an optional auth token come
from `PICO_CLAW_DASHBOARD_HOST`, `PICO_CLAW_DASHBOARD_PORT`, and
`PICO_CLAW_DASHBOARD_TOKEN`.

| Endpoint | Method | Behavior |
|---|---|---|
| `/` | GET | Dashboard UI (Chat, Status, Sessions; dark/light theme). |
| `/health` | GET | Liveness JSON. |
| `/chat` | POST | `{"message":"…"}` → `{"response":"…","html":"…"}`; `html` is pre-rendered, escaped HTML from the shared formatter. |
| `/api/*` | GET/POST/PUT/DELETE | Control plane: status, capabilities, models, sessions, profiles, skills, tools, memory, gateways, config, settings, runs. `{"ok":true,"data":…}` envelope; see [API](api.md). |

Dashboard sessions are in-memory and per-process (restarting `serve` clears
them); durable memory, experiences, tasks, and proposals persist as usual.
The endpoint is loopback-only and unauthenticated — do not expose it. No API
key or bot token is ever returned by any endpoint.

## Telegram (`channel telegram`)

`pico_claw channel telegram` runs the same agent core per allowed private
chat. Bot commands are `/start`, `/help`, `/status`, and `/clear`; replies are
rendered as Telegram HTML (bold, italic, code blocks, headings, bullets,
links) and long replies are split safely. See [Telegram channel](telegram.md).
