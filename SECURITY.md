# Security Policy

## Supported version

Pico Claw v0.1.0 is current documented release.

## Security model

Pico Claw is intended for local, controlled use. HTTP server binds only to `127.0.0.1:8080`. It has no authentication, sessions, authorization, CSRF controls, or rate limiting and must not be exposed through public interfaces, port forwarding, or a reverse proxy without a future security design covering those controls.

Provider API key is read from `PICO_CLAW_API_KEY`. Keep it out of `config/config.json`, `.env` files committed to Git, command examples, logs, issues, and screenshots. Dashboard does not render key.

Filesystem tool accepts workspace-relative paths, rejects absolute paths and `.`/`..` components, and uses beneath-resolution for writes. Treat workspace content as sensitive. Symlink and platform filesystem behavior still require deployment-specific review.

System tool only reports platform, architecture, Pico Claw version, and Zig version. It does not execute shell commands. Pico Claw has no dynamic plugin execution, dynamic code execution, or self-modifying source.

HTTP chat bodies are capped at 1 MiB. Malformed JSON and empty messages receive 400 responses; provider/runtime failures receive generic 500 responses. Provider traffic leaves local machine and is governed by configured provider.

Persistent JSONL can contain prompts, responses, memories, and learned content. Runtime data is ignored by Git but remains plaintext on disk; protect local filesystem permissions and backups.

## Reporting vulnerability

Prefer GitHub private vulnerability reporting or repository Security Advisory flow once configured. If unavailable, contact repository owner privately through a channel listed on repository profile. Do not open public issue containing exploit details, credentials, private prompts, or user data. Include affected version, impact, reproduction steps, and proposed mitigation when safe.

No dedicated security email is currently published.
