# Installation

## Windows

### Prerequisites

- Zig 0.16.0 (`zig version` must report `0.16.0`)
- Git when cloning repository
- Access and API key for configured chat-completions provider

```powershell
git clone <repository-url>
cd pico-claw
Copy-Item config/config.example.json config/config.json
$env:PICO_CLAW_API_KEY = "<your-provider-api-key>"
zig build
```

Run through build system:

```powershell
zig build run -- chat
```

Or run installed artifact from repository root:

```powershell
.\zig-out\bin\pico_claw.exe chat
```

Working directory matters: Pico Claw opens `config/config.json`, `data/`, and filesystem-tool paths relative to current directory.

Verify commands:

```powershell
.\zig-out\bin\pico_claw.exe --help
.\zig-out\bin\pico_claw.exe --version
.\zig-out\bin\pico_claw.exe status
```

These commands currently bootstrap config and all stores before dispatch, so valid `config/config.json` is required even for help/version/status. API key is only required when provider request occurs, such as chat.

## Unix-like systems

Equivalent setup generally uses `cp config/config.example.json config/config.json`, `export PICO_CLAW_API_KEY='<your-provider-api-key>'`, and `./zig-out/bin/pico_claw`. Linux/macOS runtime behavior still needs platform-specific validation; see [cross-platform notes](cross-platform.md).
