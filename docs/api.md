# HTTP API

Base URL: `http://127.0.0.1:8080` (loopback by default). All responses close
the connection. JSON routes use `content-type: application/json`; the
dashboard uses `text/html; charset=utf-8`.

## Response envelope

Every control-plane endpoint (all `/api/*` except the legacy flat routes
below) answers:

```json
{"ok": true, "data": { }}
```

```json
{"ok": false, "error": {"code": "PROVIDER_UNAVAILABLE", "message": "Provider is currently unavailable."}}
```

Codes are stable and machine-readable (`SESSION_NOT_FOUND`,
`INVALID_PROFILE_ID`, `GATEWAY_LIFECYCLE_UNSUPPORTED`, `PROVIDER_UNAVAILABLE`,
`INVALID_VALUE`, …). Responses never contain stack traces, secrets,
Authorization headers, or raw provider credentials.

Legacy v1 routes keep their historical flat bodies so existing clients and
tests are unaffected: `GET /health` → `{"status":"ok","agent":"Pico Claw"}`,
`POST /chat` → `{"response":…,"html":…}`. With the service layer attached,
`GET /api/status`, `GET /api/sessions`, and session mutations answer with the
envelope; without it (tests) they answer with the v1 shapes.

## Authentication

- Loopback without `PICO_CLAW_DASHBOARD_TOKEN`: unauthenticated.
- With the token set: every request must present
  `Authorization: Bearer <token>` or `X-Pico-Token: <token>`; otherwise
  `401 {"ok":false,"error":{"code":"UNAUTHORIZED",…}}`. The single
  exception is the dashboard shell itself (`GET /`), which is served
  without a token so the browser can render the login screen; it is static
  markup and carries no secrets.
- Non-loopback bind without a token is refused at startup
  (`error.NonLoopbackRequiresAuth`).
- State-changing requests (`POST`/`PUT`/`DELETE`/`PATCH`) validate the
  `Origin` header against the request host (`403 FORBIDDEN`) and are
  rate-limited to 120/minute (`429 RATE_LIMITED`).

## Static and health

| Endpoint | Method | Behavior |
|---|---|---|
| `/` | GET | Embedded dashboard HTML. |
| `/health` | GET | `{"status":"ok","agent":"Pico Claw"}`. |
| `/chat` | POST | `{"message":"…"}` → `{"response":…,"html":…}` on the `dashboard` session. |

## Status and capabilities

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/status` | GET | Agent identity, version, active model, provider endpoint + connection, memory/task/proposal counts, session count, gateways, model-catalog summary, active profile, metrics (messages, tool calls, successful/failed runs), uptime. |
| `/api/capabilities` | GET | The runtime capability manifest (channels, gateways, provider, workspace, tools with enable flags, memory, session management). |

## Models

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/models` | GET | Active + configured model, fetch timestamp, availability, and the normalized model list. |
| `/api/models/refresh` | POST | Queries the provider `/models` endpoint; `503 PROVIDER_UNAVAILABLE` when discovery fails. |

## Sessions

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/sessions` | GET | `[{chat_id, messages, active}, …]`. |
| `/api/sessions` | POST | `{chat_id}` creates a session (id `[A-Za-z0-9._-]{1,64}`). |
| `/api/sessions/:id` | GET | Bounded message history (system-policy messages excluded). `404 SESSION_NOT_FOUND`. |
| `/api/sessions/:id` | DELETE | Drops the session (in-memory only). |
| `/api/sessions/:id/send` | POST | `{message}` → `{response, html}` through the shared agent core. |
| `/api/sessions/:id/clear` | POST | Resets the in-memory context. |
| `/api/sessions/:id/rename` | POST | `{chat_id}` renames the session. |

## Profiles

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/profiles` | GET / POST | List, or create with `{id, name, description}` (or `{id, source, name}` to duplicate). |
| `/api/profiles/:id` | GET / PUT / DELETE | Detail (manifest + all file contents) / replace one whitelisted file `{file, content}` / delete (the active profile is protected with `409 PROFILE_ACTIVE`). |
| `/api/profiles/:id/activate` | POST | Materializes SOUL.md/MEMORY.md, reloads the owner context, and recomposes the runtime system prompt. |

File keys are `soul.md`, `memory.md`, `instructions.md`, `behavior.md`,
`custom.md` — arbitrary paths are impossible by design.

## Skills and tools

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/skills` | GET | Registered skills with linked tool, permission, availability, enabled state. |
| `/api/skills/:id/enable` \| `/disable` | POST | Toggles a skill (its linked tool follows). |
| `/api/tools` | GET | Tool manifest: description, parameters, permission, risk, enabled state. |
| `/api/tools/:name/enable` \| `/disable` | POST | Toggles a tool; disabled tools refuse execution and leave the agent's instructions. |

## Memory

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/memory` | GET | Per-type counts plus every entry (`id`, `type`, `content`, `importance`). |
| `/api/memory/search` | POST | `{query, type?}` → relevance-ranked matches (empty query → `400 INVALID_QUERY`). |
| `/api/memory/forget` | POST | `{id}` removes one entry and rewrites its typed store. |
| `/api/memory/clear` | POST | `{type?}` clears one type or all memory. |

## Gateways

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/gateways` | GET | Adapter list: Telegram (real state) plus planned transports. |
| `/api/gateways/:name` | GET | Gateway detail (`404 GATEWAY_NOT_FOUND` for unknown/planned names). |
| `/api/gateways/:name/enable` \| `/disable` | POST | Toggles process-local gateway state (reflected in `/api/capabilities`). |
| `/api/gateways/:name/start` \| `/stop` \| `/restart` | POST | Lifecycle. From `serve`: `501 GATEWAY_LIFECYCLE_UNSUPPORTED` (the single-threaded process cannot host the poll loop); `409 GATEWAY_NOT_RUNNING` otherwise. |
| `/api/gateways/:name/test` | POST | Real `getMe` probe; caches only id/username/first name. |

Token values are never returned; the API exposes `configured`/`enabled`/
`state`/`allowed_users`/`bot`/`last_error` only.

## Config and settings

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/config` | GET | Schema-shaped provider/Telegram/runtime/owner/routing view (no secrets). |
| `/api/settings` | GET | Effective model + source, retry attempts + source, limits, runtime facts. |
| `/api/settings` | PUT | `{model?, task_max_attempts?, clear_model?}` — validated, persisted to `config/settings.json`, applied to the provider and new conversations. |

## Runs

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/runs` | GET | Recent runs from the task journal (id, state, route, duration, start, error). |
| `/api/runs/:id` | GET | Stage detail: plan steps, tool calls (names/states/durations/input hashes), provider attempts with byte totals, escalation metadata. |

The journal never stores task text, tool input/output, or provider payloads.

## MCP

MCP servers are configured in `config/mcp.json`; nothing runs until the file
enables MCP **and** a server is enabled **and** started (see `docs/mcp.md`).

| Route | Description |
|---|---|
| `GET /api/mcp` | Inventory: kill switch, per-server state, transport, server info, tools, errors. |
| `GET /api/mcp/:id` | One server's detail document. |
| `POST /api/mcp/:id/start` | Spawn + initialize + discover + register tools. |
| `POST /api/mcp/:id/stop` | Kill the child and disable its tools. |
| `POST /api/mcp/:id/restart` | Stop, then start. |
| `POST /api/mcp/:id/test` | Real handshake probe (no process left behind). |
| `POST /api/mcp/:id/enable` | Re-enable a server (does not start it). |
| `POST /api/mcp/:id/disable` | Disable a server (stops it first when running). |

Environment variable *names* are listed; values never are. Tool ids are
namespaced as `mcp.<server>.<tool>` with `risk: high`. States are
`disabled`, `configured`, `starting`, `running`, `stopped`, `error`.

## Operations (attachments / artifacts / jobs / events / doctor)

Full behavior in `docs/operations.md`. Highlights:

| Route | Description |
|---|---|
| `POST /api/attachments?name=file.txt` | Raw upload; stored inside the sandbox with content-derived MIME + SHA-256. 20 MB transport ceiling. |
| `GET /api/attachments` · `GET /api/attachments/:id` | Inventory / one record. |
| `DELETE /api/attachments/:id` | Remove the record and its directory. |
| `POST /api/attachments/:id/extract` | Queue ZIP extraction as a background job. |
| `POST /api/artifacts` | `{"kind","filename","content"}` — validated; `txt md json csv zip` supported, office/PDF → `UNSUPPORTED_KIND`. Zip artifacts take `{"kind":"zip","filename","sources":[...]}` instead of `content`: `sources` is a list of workspace-relative paths (max 64, non-empty) and the response artifact is a real archive built from those files. A missing source file fails with `ARTIFACT_FAILED`; a missing/empty `sources` list fails with `INVALID_VALUE`. |
| `GET /api/artifacts` · `GET /api/artifacts/:id` | Inventory / one record. |
| `GET /api/artifacts/:id/content` | Raw download with the honest content type. |
| `DELETE /api/artifacts/:id` | Remove the artifact. |
| `GET /api/jobs` · `POST /api/jobs` | Job inventory; queue `{"kind":"doctor"}`. |
| `GET /api/jobs/:id` · `POST /api/jobs/:id/cancel` | One job's detail / explicit cancel. |
| `GET /api/events` · `GET /api/events/:id` | Run inspector: bounded run/event history, secrets redacted. |
| `GET /api/doctor` | Real health checks (provider round trip, sandbox probe, MCP states). |

## Errors and limits

| Status | Cause |
|---|---|
| `400` | Invalid JSON, invalid id/model/value, empty query. |
| `401` / `403` / `429` | Missing/incorrect token, rejected origin, rate limit. |
| `404` | Unknown session/profile/run/gateway/tool/skill or unknown path. |
| `405` | Known route with the wrong method. |
| `409` | Duplicate id, deleting the active profile, invalid gateway transition. |
| `413` | Body over 1,048,576 bytes on a state-changing route. |
| `501` | Gateway lifecycle action this process cannot host. |
| `503` | Provider or gateway configuration unavailable. |
| `500` | Unexpected internal failure (`{"ok":false,"error":{"code":"INTERNAL",…}}`). |

Example:

```powershell
Invoke-RestMethod -Uri http://127.0.0.1:8080/api/status
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/api/sessions -ContentType application/json -Body '{"chat_id":"research"}'
```
