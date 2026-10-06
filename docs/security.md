# Security design

Pico Claw v0.1.0 targets local, controlled use, not authenticated public service.

- Provider key comes only from `PICO_CLAW_API_KEY`; missing/empty key fails provider call. No endpoint returns the key, the Telegram token, or any Authorization header.
- Server binds IPv4 loopback `127.0.0.1` on port 8080 by default. `PICO_CLAW_DASHBOARD_HOST`/`_PORT`/`_TOKEN` are optional. Binding a non-loopback address without a dashboard token is refused at startup (`error.NonLoopbackRequiresAuth`).
- When `PICO_CLAW_DASHBOARD_TOKEN` is set, every request must present `Authorization: Bearer <token>` or `X-Pico-Token: <token>`; comparison is length-checked and content-compared without early exit. The only token-exempt request is the dashboard shell (`GET /`), static markup with no secrets, served so a remote browser can load the login screen; every data route stays token-protected. The browser stores the token in `localStorage.picoToken` after it is verified against a protected endpoint, and a sign-out control clears it.
- State-changing requests (`POST`/`PUT`/`DELETE`/`PATCH`) validate the `Origin` header against the request host and are rejected on mismatch — this is the CSRF control for the unauthenticated loopback case, and it also runs under token auth. State-changing endpoints are rate-limited (120 requests/minute, fixed window).
- Profile files are contained: ids must match `[a-z0-9-_]{1,64}`, file keys come from a fixed whitelist, all writes use the link-safe atomic writer, and the active profile cannot be deleted. The browser can never express an arbitrary filesystem path.
- The Telegram agent tool is permission-gated by the explicit `TELEGRAM_TOOL_ENABLED` grant (channel configured never implies tool permission) and outbound sends are restricted to the `TELEGRAM_ALLOWED_USERS` allowlist; destructive/administrative Telegram API is not exposed.
- Filesystem tool rejects empty/absolute paths and `.`/`..` components; writes request beneath-resolution. Base is current working directory.
- Owner files (`SOUL.md`, `MEMORY.md`) cannot be read or written through symlinks, junctions, or other reparse points: path components are resolved to open directory handles without following links and the destination must be a real regular file. See [soul-memory containment](soul-memory.md#link-safe-workspace-containment).
- Provider requests carry only valid UTF-8: non-UTF-8 file content is replaced with U+FFFD at load, and the request encoder never emits invalid byte sequences.
- System tool permits only empty input or `info`; no shell/process execution.
- `/chat` body maximum is 1 MiB. Malformed JSON, missing/empty messages, wrong routes/methods, and provider failures map to bounded JSON errors; provider failure detail is not exposed in HTTP response.
- Brain tool calls require exact envelope, JSON name/input, registered name, and four-call maximum.
- No dynamic code execution, dynamic plugin execution, or self-modifying source.
- Persistent prompts, responses, memories, strategies, and knowledge are plaintext local JSONL ignored by Git.

## Trust boundaries

User/browser input, provider responses, persisted JSONL, filesystem paths, and configuration are untrusted. Provider receives conversation/context data over configured endpoint. Review provider privacy policy and use HTTPS URL. Local users/processes with loopback or filesystem access remain in trust model.

## Not provided

No authentication, authorization, TLS listener, session isolation, rate limiting, CSRF protection, public binding, sandbox, encrypted persistence, or multi-user isolation. Do not expose server via proxy, tunnel, container port publication, or firewall rule without future design for these controls.

See repository [security policy](../SECURITY.md) for reporting.
