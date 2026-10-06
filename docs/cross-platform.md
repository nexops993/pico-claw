# Cross-platform considerations

Pico Claw uses Zig native build model and standard library for files, networking, HTTP, environment, and target metadata. `build.zig` exposes standard target and optimization selection.

## Windows

Windows is current validated development platform. PowerShell setup and `zig-out\bin\pico_claw.exe` examples are documented. Current server uses IPv4 loopback and filesystem tool accepts slash/backslash path tokenization.

## Linux and macOS

Source is designed to be portable, and Zig can target these systems. Still validate build, TLS/provider access, filesystem permissions and path behavior, loopback listening, environment setup, persistence, and tests on each OS. On Unix-like systems executable path is normally `zig-out/bin/pico_claw` and API key can be exported in shell.

Do not infer official binary availability from source portability. No binaries are documented as published. Android and other targets are not claimed supported or verified. Cross-compilation alone is not runtime validation.

## Platform capability matrix (production gate audit)

Legend:

- **CODE COMPATIBLE** — implemented with platform-neutral Zig APIs (no
  shell assumptions, no POSIX-only calls, no hardcoded paths); expected to
  build and behave correctly but **not executed on that platform yet**.
- **LIVE VERIFIED** — built and exercised end to end on that platform
  (unit tests, live API checks, runtime behavior).
- **UNSUPPORTED** — not claimed on that platform.

| Capability | Windows x64 | Windows ARM64 | Linux x64 | Linux ARM64 | macOS x64 | macOS ARM64 |
|---|---|---|---|---|---|---|
| Core runtime (agent, tools, sandbox) | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Provider/SSE + Telegram | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Dashboard (HTTP, loopback) | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| MCP stdio client | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Attachments / artifacts | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Job runtime (threads, cooperative cancel) | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Doctor (incl. network probes) | LIVE VERIFIED | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |
| Installer (install/uninstall/update --check) | LIVE VERIFIED (CLI) | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE | CODE COMPATIBLE |

Portability rules the code follows (audited):

- no shell invocation anywhere in the runtime;
- process spawn through `std.process` with structured argv and explicit
  environments (children never inherit the parent environment by default);
- all filesystem access is sandbox-relative via `std.Io.Dir` handles — no
  hardcoded `/tmp`, `/bin`, drive letters, or path separators in logic;
- threads/mutexes/condition handling through `std.Thread` / `std.Io`
  primitives only.

Any claim above `CODE COMPATIBLE` for a platform other than Windows x64
requires the external QA phase to run the full suite and the live API
checks on that platform before release.
