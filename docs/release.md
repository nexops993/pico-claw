# Pico Claw v0.1.0 release

## Scope

Initial documented local agent runtime: Zig-native CLI; loopback HTTP API/dashboard; buffered provider adapter; conversation context; Brain tool loop; calculator/filesystem/system tools; planner/executor; memory, experience, strategy, and knowledge JSONL persistence; deterministic evaluation/reflection/learning; static skills metadata.

## Security characteristics

Environment-only API key, no key in dashboard, loopback-only bind, filesystem traversal rejection, no arbitrary shell execution, 1 MiB chat request limit, malformed-request errors, generic provider failure response, and no dynamic/self-modifying code. Service has no authentication/rate limiting and is not for public exposure.

## Known limitations

- Buffered provider response; no SSE/chunk streaming.
- Filesystem plan lacks typed grammar and is not directly executed through Conversation's Executor path.
- Lexical memory and substring knowledge retrieval; no embeddings/vector DB.
- Static local dashboard lacks authentication, sessions, and history UI.
- Help/version/status bootstrap all subsystems.
- No WhatsApp, Telegram, browser automation, dynamic plugins, external dependency system, public bind, or self-modifying source.

## Verification

Release preparation requires Zig 0.16.0 checks:

```text
zig fmt --check build.zig src
zig build test
zig build
```

Runtime smoke checks are `pico_claw --help`, `--version`, and `status` with local config. Live chat requires valid provider access and key and may incur provider usage. Exact verification result belongs in release preparation report, not assumed here.

No official binary artifacts or GitHub release are claimed. Future direction may include typed planner/tool contracts, better local UI/state, and provider transport options; no listed limitation is promised for a specific release.
