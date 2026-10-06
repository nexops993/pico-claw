# Telegram channel

`pico_claw channel telegram` runs a Telegram long-polling loop that feeds every
allowed private chat through the same agent stack as CLI chat. The channel is
optional, disabled by default, and configured entirely through environment
variables — never through `config/config.json`.

## Commands

| Command | Behavior |
|---|---|
| `pico_claw channel` or `pico_claw channel status` | Prints the Telegram channel state: `disabled`, `not configured (missing token)`, or `enabled`. |
| `pico_claw channel telegram` | Requires `TELEGRAM_ENABLED=true` and `TELEGRAM_BOT_TOKEN`; polls until Ctrl+C (Windows) or SIGINT/SIGTERM (POSIX). |

`pico_claw status` also reports the channel in its `Channels` section. Channel
commands do not require `PICO_CLAW_API_KEY`; the agent still needs it to
answer chats.

## Bot commands

The bot accepts four exact commands (case-insensitive, no arguments; anything
else is ordinary agent input):

| Command | Behavior |
|---|---|
| `/start` | Short greeting. |
| `/help` | Lists the available commands. |
| `/status` | Compact agent status: model, provider URL, memory/experience/strategy/knowledge counts, task and proposal totals, active chat sessions. Never prints a token, key, or provider body. |
| `/clear` | Clears the in-memory conversation context of that chat only; durable stores are untouched. |

## Reply formatting

Replies never contain raw Markdown. Every agent reply is converted to
Telegram `parse_mode=HTML` by the shared formatter (`src/format.zig`):

- supported: bold `**x**`, italic `*x*`, strikethrough `~~x~~`, inline code,
  fenced code blocks (with a sanitized language class), ATX headings, `-`/`*`
  bullet lists, and `[text](url)` links with `http`/`https`/`telegram`
  schemes;
- `<`, `>`, and `&` are escaped everywhere, including inside code blocks;
- malformed input is repaired rather than rejected: unclosed bold, inline
  code, or a fence at the end of a reply is closed into valid HTML, and
  `snake_case` identifiers are never italicized;
- long replies are split into parts of at most 4000 characters at line
  boundaries, never inside a UTF-8 sequence and never breaking a code block —
  each part stays valid HTML.

Internal details are never shown to the user. Failures produce a single
generic notice (`AI request failed; please try again later.`) plus bounded
diagnostics on stderr when `--debug` is on.

## Environment variables

| Variable | Required | Meaning |
|---|---|---|
| `TELEGRAM_ENABLED` | no | `1`, `true`, `yes`, or `on` (case-insensitive) enables the channel. Unset or any other value keeps it disabled. |
| `TELEGRAM_BOT_TOKEN` | yes, to run | Bot token from @BotFather. Never printed, logged, or embedded in diagnostics; request URLs that contain it are suppressed. |
| `TELEGRAM_ALLOWED_USERS` | recommended | Comma-separated numeric Telegram user ids. Empty or unset denies everyone (deny by default). |

Set them in the shell or in `.env` (see [configuration](configuration.md));
shell values always win over `.env`.

## Creating a bot

1. Open Telegram and start a chat with **@BotFather**.
2. Send `/newbot`, pick a display name and a username ending in `bot`.
3. Copy the token BotFather returns into `TELEGRAM_BOT_TOKEN` (shell or `.env`). Never paste it into `config/config.json`, docs, issues, or commits.
4. Discover your numeric user id: set `TELEGRAM_ENABLED=true`, run `pico_claw channel telegram`, and send the bot any message. A denied sender receives a fixed hint that echoes their own id — add it to `TELEGRAM_ALLOWED_USERS`.
5. Restart the channel so the allowlist applies.

Example `.env` block:

```text
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN=123456789:replace-with-botfather-token
TELEGRAM_ALLOWED_USERS=11111111
```

## Scope (v0.1.0)

- **Private text chats only.** Group/supergroup/channel messages, edited
  messages, media-only messages, and updates without a sender are ignored.
- **Deny by default.** Only senders listed in `TELEGRAM_ALLOWED_USERS` are
  processed. Everyone else receives one fixed line with their own user id and
  no agent processing.
- **Commands.** `/start`, `/help`, `/status`, and `/clear` are handled locally;
  all other chat text is provider input, never a control surface.
- **Per-chat sessions.** Each chat id gets its own bounded conversation
  context (8 concurrent chats, least-recently-used evicted) while sharing the
  same durable memory, experience, strategy, knowledge, task, and proposal
  stores as CLI chat and the dashboard. Session history is in-memory only.
- **Formatted, chunked replies.** Replies are sent as Telegram HTML from the
  shared formatter; replies longer than 4000 characters are split into several
  messages, preferring newline boundaries (Telegram's hard limit is 4096).
- **Typing indicator and bounded retries.** A `typing` chat action is sent
  while the agent works, and `sendMessage` retries transient failures up to
  three attempts before giving up; delivery stops after a failed part so the
  reply never arrives out of order.
- **Long polling only.** Offset-based `getUpdates` requesting `message`
  updates; updates whose id is below the confirmed offset are skipped
  (duplicate protection); the channel opens no listening port and no webhook.

## Security notes

- The bot token is read from the environment only and is never printed,
  logged, or written to journals; request URLs that embed it are never logged.
- Transport is HTTPS to `https://api.telegram.org`.
- Telegram content is untrusted data: it is never treated as instructions to
  the agent runtime, and replies are escaped Telegram HTML (never raw
  Markdown).
- Anyone holding the token controls the bot. Keep it out of docs, chats, and
  commits; rotate it with `/revoke` in BotFather if it leaks.
- Stop the channel with Ctrl+C; the poll loop exits cleanly after the current
  batch.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `channel status` says `disabled` | `TELEGRAM_ENABLED` unset or not a truthy value. |
| `channel status` says `not configured (missing token)` | `TELEGRAM_ENABLED` is truthy but `TELEGRAM_BOT_TOKEN` is empty or unset. |
| `✗ Telegram bot token missing` when starting | Same as above; set `TELEGRAM_BOT_TOKEN` in the shell or `.env`. |
| `✗ TELEGRAM_ALLOWED_USERS is invalid` | Use comma-separated numeric ids (`111,222`); trailing commas are ignored, non-numeric tokens are rejected. |
| Bot replies with a "Not authorized" id hint | The sender id is not in `TELEGRAM_ALLOWED_USERS`; add it and restart. |
| Bot ignores messages entirely | Group chat, media-only message, or edited message — out of v0.1.0 scope. |
| Warnings but the loop keeps running | Transport failures back off exponentially (1s doubling, capped at 30s) and retry automatically; run with `--debug` for bounded diagnostics. |

See [usage](usage.md), [configuration](configuration.md), and
[security](security.md).
