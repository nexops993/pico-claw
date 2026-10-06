# Sandbox runtime

Pico Claw ships an explicit sandbox runtime (`src/runtime/`) that gives the
agent real workspace capabilities without giving the model access to the host
filesystem. Everything the agent does goes through the sandbox.

## Boundaries

- **Workspace root**: `./workspace/` (created at startup). All agent paths are
  relative to this root; the agent never sees absolute host paths.
- **Allowed** (default): anything inside `./workspace/`, e.g. `project/`,
  `uploads/`, `output/`.
- **Refused** (always, before any syscall):
  - absolute paths (`/etc/passwd`, `C:\Users\...`, `C:/...`),
  - UNC / NT device paths (`\\server\share`, `\\.\pipe\...`),
  - `..` traversal and `.` components (`a/../secret`),
  - Windows reserved device names (`CON`, `NUL`, `COM1`… `LPT9`, including
    `CON.txt`),
  - drive-colon / alternate-data-stream names (`stream:hidden`),
  - Windows-forbidden punctuation (`" * < > | ?`), control bytes, trailing
    dots/spaces,
  - symlink/junction/reparse-point components (opened component-by-component
    with symlink following disabled).

Containment is layered: lexical validation **and** directory-handle-relative
operations opened one component at a time without following symlinks, **and**
resource limits. There is no single point of failure.

## Policy

The whole-root policy lives in `runtime/sandbox.zig` (`Access`):

- `read`, `write`, `execute` grants (per-prefix grants via `read_prefixes` /
  `write_prefixes` when needed),
- `executable_commands`: exact program allowlist for `process.exec` (empty =
  execution denied; there is no wildcard),
- `env_allowlist`: environment variable **names** forwarded to child
  processes (values are never logged or returned),
- `network_enabled`: `false` by default.

Current defaults in `src/main.zig`: read/write granted, execute **denied**
until the operator adds programs to the allowlist in code, network disabled.

## Limits (`Limits`)

| Limit | Default |
|---|---|
| max read into memory | 2 MB |
| max write / edit | 64 MB |
| max stdout/stderr | 512 KB |
| max archive size | 256 MB |
| max extracted total | 1 GB |
| max entries (listing/archive) | 20 000 |
| max search results | 500 |
| exec timeout | 60 s |
| max stdin | 256 KB |

## Tools (registered in the tool registry)

All take a JSON object string and return structured JSON:

`filesystem.list` · `filesystem.read` · `filesystem.write` · `filesystem.edit`
· `filesystem.stat` · `filesystem.mkdir` · `filesystem.delete` ·
`filesystem.move` · `filesystem.copy` · `filesystem.search` ·
`process.exec` · `archive.list` · `archive.extract` · `archive.create` ·
`media.inspect` · `media.thumbnail`

- `process.exec` never spawns a shell: `{"command":"zig","args":["build","test"]}`.
  The result carries the real `exit_code`, `stdout`, `stderr`, `duration_ms`,
  `timed_out`, `truncated`, `killed`.
- `archive.extract` performs ZIP-slip protection (every entry name validated
  before extraction; ZIP uses a validate-all-then-extract two-pass), rejects
  backslash entry names, skips symlink/hardlink entries, and enforces the
  entry-count and extracted-size limits. TAR (ustar + GNU long names) and
  TAR.GZ (gzip via std.compress.flate) are supported; entries are validated
  as they are encountered because a gzipped stream cannot be rewound.
- `media.inspect` reports format, dimensions, MIME type, size and SHA-256 from
  the file bytes (PNG/JPEG/GIF/WebP/BMP images; MP4/Matroska/WebM/AVI
  containers). It does **not** provide vision — the model never "sees" an
  image, and no such claim is made.
- `media.thumbnail` and frame/audio extraction return a structured
  `{"supported":false,"reason":...}` result because no external media tool is
  bundled. Nothing pretends to be supported.

## Dashboard

The Sandbox page (`GET /api/sandbox`) shows the workspace root, grants,
executable allowlist, environment variable *names*, and every limit. No
secrets are exposed (values of environment variables are never read).

## Known limitations

- MCP (client/server, Phases 11–15 of the roadmap) is **not implemented**;
  there are no `/api/mcp` endpoints and no MCP UI. No stub is exposed.
- Folder/file upload attachments (Phase 17/33) are not implemented yet; the
  agent can still operate on files placed in `./workspace/` by the operator.
- Vision/video playback remain provider-side capabilities that are not
  advertised.
