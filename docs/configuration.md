# Configuration

Pico Claw loads required JSON from `config/config.json`, relative to current working directory. Copy [example](../config/config.example.json) and edit local copy.

```json
{
    "agent_name": "Pico Claw",
    "model": "tamandata",
    "base_url": "https://ai.tamandata.com/v1",
    "system_prompt": "You are Pico Claw, a lightweight, safe, and helpful personal AI agent.",
    "settings": {
        "temperature": 0.7,
        "max_tokens": 2048,
        "soul_path": "SOUL.md",
        "memory_path": "MEMORY.md",
        "soul_budget_bytes": 4096,
        "memory_budget_bytes": 16384,
        "owner_budget_bytes": 20480
    }
}
```

| Field | Type | Current use |
|---|---|---|
| `agent_name` | string | Printed during startup greeting. |
| `model` | string | Printed in status and sent as provider request `model`. |
| `base_url` | string | Provider endpoint base; runtime appends `/chat/completions`. Avoid trailing slash to prevent doubled separator. |
| `system_prompt` | string | Initial system message and base of each request context. |
| `settings.temperature` | number | Required and loaded as `f64`; not sent by v0.1.0 provider implementation. |
| `settings.max_tokens` | unsigned integer | Required and loaded as `u32`; not sent by v0.1.0 provider implementation. |
| `settings.soul_path` | string, optional | Path to the owner identity file, relative to the working directory. Default `SOUL.md`. |
| `settings.memory_path` | string, optional | Path to the persistent owner memory file, relative to the working directory. Default `MEMORY.md`. |
| `settings.soul_budget_bytes` | number, optional | Maximum SOUL.md content read into the prompt. Default `4096` (4 KiB). `0` disables the section. |
| `settings.memory_budget_bytes` | number, optional | Maximum MEMORY.md content read into the prompt. Default `16384` (16 KiB). `0` disables the section. |
| `settings.owner_budget_bytes` | number, optional | Combined SOUL.md + MEMORY.md cap. Default `20480` (20 KiB). SOUL is served first; memory is trimmed to the remainder. |
| `settings.task_max_attempts` | number, optional | Total provider attempts per task, clamped to 1–5. Default `1` (no retries, pre-M2 behavior). Only provider failures are retried; see [tasks](tasks.md). |
| `settings.request_timeout_ms` | number, optional | Hard deadline for every provider HTTP request (chat completions and model discovery), clamped to 1–600000 ms. Default `120000` (2 minutes). Absent, zero, negative, or non-finite values fall back to the default, and the value can never be set to "disabled": a hung provider endpoint fails with `RequestTimeout` instead of blocking the single-threaded runtime. |
| `settings.routing_teacher_base_url` | string, optional | Teacher endpoint for escalation (OpenAI-style `/chat/completions`). Unset disables escalation entirely. |
| `settings.routing_teacher_model` | string, optional | Teacher model name. Both teacher keys must be set for escalation to be available; the name is recorded in the task journal. |
| `settings.routing_local_only` | boolean, optional | Privacy mode: never send a task to a remote teacher, even when configured. Default `false`. |
| `settings.routing_teacher_max_request_bytes` | number, optional | Byte budget for the compact teacher request, clamped to 1024–65536. Default `8192`. See [teacher routing](routing.md). |

Parser uses fixed 16 KiB config read buffer. Missing file, malformed JSON, missing/wrong-type fields, or oversized content prevents startup. `max_tokens` must fit an unsigned 32-bit integer; out-of-range values are rejected. The owner context keys are optional: old configs without them keep working with defaults. Negative, non-finite, or absurd budget values fall back to defaults or are clamped to hard caps (1 MiB per section, 2 MiB combined) instead of failing startup or causing huge allocations. See [SOUL and MEMORY](soul-memory.md).

## API key

Set separately; never place it in JSON:

```powershell
$env:PICO_CLAW_API_KEY = "<your-provider-api-key>"
```

Alternatively, copy `.env.example` to `.env` in the working directory and set
the key there: the file is loaded at startup (before anything reads the
environment) and variables already set in the shell always win over it. Keys
are never printed, logged, or journaled.

Missing or empty required settings fail fast with actionable messages:
`base_url` and `model` are checked for every command, and
`PICO_CLAW_API_KEY` only for commands that contact the provider (`chat`,
`serve`) — `status`, `proposals`, and `channel` work without it.
`config/config.json`, `.env` are ignored by Git (copy `.env.example` as the
starting point).

## Runtime settings

`PUT /api/settings` (dashboard) persists validated overrides to
`config/settings.json`: the active model (clamped to 256 characters, restricted
charset, no secrets) and provider retry attempts (clamped 1-5). The file is
loaded at startup when present; malformed values fall back to defaults instead
of failing startup. Everything else the dashboard shows (bind address, auth
state, workspace paths) is read-only runtime state.

## Dashboard environment

| Variable | Meaning |
|---|---|
| `PICO_CLAW_DASHBOARD_HOST` | Bind address, default `127.0.0.1`. Non-loopback requires a token. |
| `PICO_CLAW_DASHBOARD_PORT` | Listen port, default `8080`. |
| `PICO_CLAW_DASHBOARD_TOKEN` | When set, every dashboard/API request must present it. |

## Telegram agent tool

The Telegram tool (outbound `get_me`, `get_chat`, allowlisted `send_message`)
is separate from the channel and requires an explicit grant:

| Variable | Meaning |
|---|---|
| `TELEGRAM_TOOL_ENABLED` | `1`/`true`/`yes`/`on` registers the tool. Channel configuration never implies tool permission. |
| `TELEGRAM_BOT_TOKEN` | Shared with the channel. Never returned by any API. |
| `TELEGRAM_ALLOWED_USERS` | Also restricts tool sends: an empty allowlist denies all sends. |

## Telegram channel

The optional Telegram channel is configured only through environment
variables (shell or `.env`), never through `config/config.json`:

| Variable | Meaning |
|---|---|
| `TELEGRAM_ENABLED` | `1`, `true`, `yes`, or `on` (case-insensitive) enables the channel; anything else keeps it disabled. |
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather. Required to run `pico_claw channel telegram`. Never printed or logged. |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated numeric Telegram user ids allowed to chat. Empty or unset denies everyone; denied senders receive only a fixed hint echoing their own id. |

```powershell
$env:TELEGRAM_ENABLED = "true"
$env:TELEGRAM_BOT_TOKEN = "<token-from-botfather>"
$env:TELEGRAM_ALLOWED_USERS = "11111111"
zig build run -- channel telegram
```

`pico_claw channel status` reports the channel state, and `pico_claw status`
includes it in the `Channels` section. Bot creation, scope limits, and
troubleshooting: [Telegram channel](telegram.md).
