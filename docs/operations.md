# Operations: attachments, jobs, artifacts, runs, doctor

These subsystems make up Pico Claw's production operations layer. Every one
is honest about its state: the capability manifest, the agent prompt, and the
API all report what is actually attached and running.

## Attachments (uploads)

`POST /api/attachments?name=file.txt` with the raw bytes as the body stores
the upload inside the sandbox at `workspace/uploads/<id>/`.

- Names are validated, never silently fixed: traversal (`..`), absolute,
  UNC/drive, reserved device names (CON, NUL, ...), and control characters
  are rejected with `INVALID_NAME`.
- The MIME type is derived from the bytes (PNG/JPEG/GIF/PDF/ZIP/text/...).
  Extensions and client-declared types are ignored.
- SHA-256 is computed over the stored bytes; the value is part of the record.
- Limits: 16 MB per attachment, 128 MB total quota (both enforced
  server-side; the transport ceiling is 20 MB).
- ZIP uploads can be extracted via `POST /api/attachments/:id/extract` as a
  background job. Extraction uses the sandbox extractor: zip-slip entries are
  refused, entry/size limits apply, symlinks are not followed, and nothing
  can escape `uploads/<id>/extracted/`.
- Uploaded content is untrusted data. Nothing in the runtime executes it.
- Recovery: at startup the runtime removes upload directories that have no
  `meta.json` (interrupted uploads) and reports how many were removed.

## Jobs

`GET /api/jobs`, `GET /api/jobs/:id`, `POST /api/jobs` (`{"kind":"doctor"}`),
`POST /api/jobs/:id/cancel`.

- One bounded worker thread; no unmanaged background threads or processes.
- States: `queued`, `starting`, `running`, `cancelling`, `cancelled`,
  `completed`, `failed`, `timed_out`.
- Cancellation and timeouts are cooperative via `checkpoint()`. The runtime
  records `cancelled`/`timed_out` only when the job actually stops; a job
  that finishes despite a cancel request is recorded as `completed` with
  `cancel_requested: true`.
- A client disconnecting never cancels a job.
- Every job links to a run in the inspector.

## Artifacts

`GET/POST /api/artifacts`, `GET /api/artifacts/:id`,
`GET /api/artifacts/:id/content`, `DELETE /api/artifacts/:id`.

- Supported natively: `txt`, `md`, `json`, `csv`, `zip`. Content is validated
  before writing (JSON must parse; text must be non-empty UTF-8) and the
  written file is read back and hashed.
- `pdf`, `docx`, `pptx`, `xlsx`: **UNSUPPORTED**. The API answers
  `UNSUPPORTED_KIND` and nothing is written.
- Artifacts live in `workspace/artifacts/<id>/` with a `meta.json` sidecar.

## Run inspector (events)

`GET /api/events`, `GET /api/events/:id`.

- Runs carry identity (id, request/session), context (model, provider,
  profile), lifecycle state, and a bounded event list (tool calls, MCP calls,
  job start/result, artifact creation, verification, recovery).
- Any event detail that contains a credential marker (`PICO_CLAW_API_KEY`,
  `TELEGRAM_BOT_TOKEN`, `Bearer `, `token=`, ...) is stored as `[redacted]`.

## Doctor

`GET /api/doctor` or `pico_claw doctor`.

Checks (all real): binary version, configuration, provider model discovery
(authenticated HTTP round trip), Telegram `getMe` when configured, sandbox
write/read/delete cycle, MCP server states, attachments quota, artifacts,
job runtime, run store. States: `pass`, `warn`, `fail`, `unavailable`,
`unsupported`. Overall is the least healthy check.

## Installer

- `pico_claw install` — creates `workspace/` and `data/`, copies
  `config/config.example.json` to `config/config.json` only when absent.
- `pico_claw uninstall [--yes]` — lists everything it would remove; deletes
  config/workspace/data/memory only with `--yes`. The binary is always
  removed manually.
- `pico_claw update --check` — prints the current version and the release
  asset name it would look for. Download/replacement is UNSUPPORTED until
  signed release assets exist; there is no self-update.
