# Building and testing

Requires Zig 0.16.0.

```text
zig fmt --check build.zig src
zig build test
zig build
```

- Format check validates Zig formatting without changing files.
- `zig build test` compiles/runs root module's inline tests.
- `zig build` installs `pico_claw` under `zig-out/bin/`.

Run command and pass application argument after `--`:

```text
zig build run -- chat
zig build run -- status
```

`build.zig` uses standard `b.standardTargetOptions` and `b.standardOptimizeOption`, so standard Zig target/optimization options are available. Example standard release build:

```text
zig build -Doptimize=ReleaseSafe
```

No custom project build flags or external dependencies exist. Cross-compilation can compile target code but does not prove runtime/provider/filesystem behavior on target OS.
