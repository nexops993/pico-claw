# Web dashboard

Start with:

```text
pico_claw serve
```

The server listens on `http://127.0.0.1:8080` by default and serves the
embedded control plane from `src/interfaces/dashboard.html`. The dashboard is
still dependency-free: semantic HTML, one inline stylesheet, one inline
script, no CDN, no remote fonts, no external JavaScript — everything ships
inside the binary.

## Navigation

A persistent left sidebar (a drawer on mobile) routes between pages. The
current page lives in the URL hash (`#/overview`), so browser back/forward
and reloads keep you in place. The footer shows the runtime version, active
model, and uptime; the top bar shows a live runtime/provider status pill.

| Page | What it shows |
|---|---|
| **Chat** | Primary workspace: conversation rail, model selector, message history, composer. |
| **Overview** | Agent/provider/gateway cards, run and tool-call metrics, recent activity. |
| **Sessions** | Every live session (id, message count, kind: dashboard/telegram/local) with clear. |
| **Models** | Discovered models (id, provider, streaming/vision/tool-calling, context) with refresh, last-fetched time, and the active model. |
| **Profiles** | Create/duplicate/edit/activate/delete profiles; edit soul/memory/instructions/behavior/custom files. |
| **Skills** | Registered skills with their linked tool, permission, and enable/disable. |
| **Tools** | Tool manifest: parameters, permission, risk, enabled state, enable/disable. |
| **Memory** | Typed memory (all/semantic/episodic/procedural/error/preference) with search, forget, and clear. |
| **Gateways** | Telegram card (configured, enabled, state, bot identity, allowed users, last error) with lifecycle controls, plus planned transports. |
| **Config** | Structured, schema-shaped view of provider / Telegram / runtime / owner / routing state. |
| **Settings** | Appearance (theme, density), agent (model, retries), security facts, runtime facts. |
| **Logs** | Agent run inspector: stage-by-stage view of the task journal. |

## Chat workspace

- **Conversations** — new, rename, clear, delete; the rail lists every live
  session with its message count. History is rehydrated from the session
  detail API, so a page reload keeps the conversation.
- **Model selector** — populated from `GET /api/models`; choosing a model
  persists a validated override through `PUT /api/settings` (no API keys ever
  reach the browser).
- **Messages** — assistant replies are rendered from the same escaped HTML the
  Telegram channel uses (`src/format.zig`), with copy buttons on code blocks,
  links, and headings. Errors show a retry button; a thinking indicator runs
  while the agent works.
- **Composer** — Enter sends, Shift+Enter inserts a newline, the textarea
  auto-grows, and the view auto-scrolls when you are near the bottom.
- **Stop** is intentionally not a server feature: the runtime answers each
  request synchronously, so cancelling means aborting the browser request.
  There is no fake "stopped" state.

## States and feedback

Every page implements loading (skeletons), empty, and error (with retry)
states. Destructive actions (delete profile, clear memory, clear session,
delete/clear conversation) require an in-page confirmation dialog. Successful
and failed actions surface as toasts. Controls are keyboard reachable with a
visible focus ring, and `Escape` closes the drawer or dialog.

## Files still shared with the agent core

The dashboard never re-implements agent logic. Chat runs through the same
`SessionStore` and `Conversation.send` as CLI chat and Telegram; the run
inspector reads the same task journal; profiles activate through the same
owner context that loads `SOUL.md`/`MEMORY.md`.

## Security

- Default bind is loopback (`127.0.0.1`); the page is served unauthenticated
  only there.
- Set `PICO_CLAW_DASHBOARD_TOKEN` to require authentication. The browser
  script attaches `X-Pico-Token` from `localStorage.picoToken` when present.
- Binding a non-loopback address without a token is refused at startup.
- State-changing requests validate the `Origin` header against the request
  host (CSRF protection) and are rate-limited (120/minute).
- No endpoint ever returns an API key, a bot token, an Authorization header,
  or a raw provider payload.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `PICO_CLAW_DASHBOARD_HOST` | `127.0.0.1` | Bind address. Non-loopback requires a token. |
| `PICO_CLAW_DASHBOARD_PORT` | `8080` | Listen port. |
| `PICO_CLAW_DASHBOARD_TOKEN` | unset | When set, every request must present it. |

## Limits

- Single-page, single-file, no build step, no authentication UI (the token is
  supplied per browser).
- Sessions are per-process and in-memory; restarting `serve` clears live
  conversations (durable stores keep tasks, experiences, and proposals).
- The `serve` process cannot host the Telegram poll loop; run the channel
  with `pico_claw channel telegram` and use the dashboard for status and
  connection testing.
