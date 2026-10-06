# Troubleshooting

## Zig unavailable or wrong version

Run `zig version`; expected `0.16.0`. Ensure Zig binary is on `PATH`. Code uses Zig 0.16 APIs and should not be rewritten to older API patterns.

## Configuration missing or invalid

Create `config/config.json` from example and run from repository root. All fields are required. Keep file below 16 KiB and valid JSON. Help/version/status also require config because startup occurs before command dispatch.

## API key missing

Set nonempty `PICO_CLAW_API_KEY` in same process environment that launches Pico Claw. Do not put it in JSON. Key is checked when provider request occurs.

## Provider unavailable

Check `base_url`, model, network/DNS/TLS access, provider account, and key. Runtime appends `/chat/completions`; avoid trailing slash. Provider must return HTTP 200 JSON with `choices[0].message.content` string. Responses are buffered, not streamed.

## Build failure

Confirm Zig 0.16.0, run from repository root, then run formatting/tests separately to isolate failure. No dependency fetch is expected.

## Port already in use

Port is fixed at `127.0.0.1:8080`. Stop process using port; v0.1.0 has no port flag.

## Malformed HTTP requests

Send JSON object with nonempty string `message`, and keep body at or below 1 MiB. Use exact `/chat` target and POST method.

## Permission problems

Ensure current directory permits reads of config/data/workspace and writes to `data/`. Filesystem tool cannot create missing parent directories. OS ACLs still apply.

## Stale build artifacts

Remove `.zig-cache/` and `zig-out/`, then run `zig build test` and `zig build`. These are generated and Git-ignored.

## Persistence problems

Back up local JSONL before manual repair. Invalid experience JSONL may fail startup; strategy/knowledge loaders skip corrupt lines except allocation failures; missing files mean empty store. Verify valid one-object-per-line JSON and directory permissions. Runtime files are local and ignored by Git.
