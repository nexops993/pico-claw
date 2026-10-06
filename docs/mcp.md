# MCP (Model Context Protocol) client

Pico Claw can attach external MCP servers over **stdio** and expose their
tools to the agent through the same boundaries every other tool uses.

- Status: **stdio transport implemented and tested** (client side).
- Protocol: JSON-RPC 2.0, newline-framed messages, MCP revision
  `2024-11-05` advertised during `initialize`.
- What is implemented: server configuration, process lifecycle, initialize
  handshake, tool discovery (`tools/list` with pagination), tool invocation
  (`tools/call`), timeouts, crash/malformed-response detection, cleanup,
  permission/risk integration, capability reporting, control-plane API.
- What is NOT implemented: Streamable HTTP transport, MCP resources/prompts,
  sampling, server-initiated requests, and any dashboard UI for MCP. Nothing
  here is simulated; those features are simply reported as unavailable.

## Security model

MCP is an **external capability boundary**. Everything a server sends is
untrusted data:

- A tool description (even one saying "ignore previous instructions") is
  stored as bounded metadata, never interpreted.
- Tool output is returned verbatim as content inside the result JSON. The
  runtime never acts on it.
- Nothing is trusted merely because a server advertises it. Discovery that
  contains a tool outside the portable name alphabet is **refused as a
  whole** (`InvalidToolListing`) rather than partially exposed.
- Processes are spawned directly (executable + argument array). There is no
  shell and nothing is ever parsed or re-interpreted.
- The child receives **exactly** the environment configured in the file. The
  parent environment is not inherited, so no Pico Claw credential can leak
  into an external server by accident.
- stderr is counted, never logged, rendered, or returned.
- Every request carries a deadline; every line is size-bounded (1 MB).

Lifecycle states reported by the registry: `disabled`, `configured`,
`starting`, `running`, `stopped`, `error`. `running` is only reported while a
live, initialized client with a successful discovery exists.

## Configuration

MCP is configured in `config/mcp.json` (copy `config/mcp.example.json`).
With no file (or `"enabled": false`) MCP is off. Each server is also disabled
until `"enabled": true`, and does not run until started explicitly or when
`"auto_start": true`.

| Field | Meaning |
|---|---|
| `enabled` (top level) | Master kill switch for MCP. |
| `servers[].id` | `1..32` chars of `[a-z0-9_-]`; becomes the tool namespace. |
| `servers[].command` | Executable path or name. Resolved through PATH. |
| `servers[].args` | Argument array (strings only, no shell). |
| `servers[].env` | Environment variables for the child. **Names** appear in API output; values never do. |
| `servers[].enabled` | Server-level enable switch. |
| `servers[].auto_start` | Start when the runtime boots. |
| `servers[].timeout_ms` | Per-request timeout, clamped to 1_000..120_000. |
| `servers[].permission` | `standard`, `network`, or `elevated` (default). |

All MCP tools are reported with `risk: high` (external code) and get the
tool id `mcp.<server-id>.<mcp-tool-name>` in the shared tool registry.

## Control-plane API

| Route | Behavior |
|---|---|
| `GET /api/mcp` | Inventory: kill switch, per-server state/transport/server-info/tools (no secrets). |
| `GET /api/mcp/<id>` | One server's detail document. |
| `POST /api/mcp/<id>/start` | Spawn + initialize + discover + register tools. |
| `POST /api/mcp/<id>/stop` | Kill the child, disable its tools. |
| `POST /api/mcp/<id>/restart` | Stop, then start. |
| `POST /api/mcp/<id>/test` | Real handshake probe; never leaves a process behind. |
| `POST /api/mcp/<id>/enable` | Re-enable (does not start anything). |
| `POST /api/mcp/<id>/disable` | Disable; stops a running server first. |

There is deliberately no create/update/delete endpoint yet: runtime mutation
of process-spawning configuration without a designed persistence story would
weaken the security model. Edit `config/mcp.json` and restart instead.

`GET /api/capabilities` reports an `mcp` section that reflects live state
only, and the agent's system prompt states MCP tool availability in the same
way.

## Deterministic test server

`pico_mcp_test_server` (built by `zig build test`) is an in-repository MCP
server used by the automated tests. It offers `echo`, `add`, `structured`,
`fail`, `delay`, `malformed`, `wrong_id`, `crash`, `inject`, and
`env_report`, plus `--behavior=` modes (`silent`, `exit_immediately`,
`garbage_init`, `bad_tools`) that drive timeout, crash, malformed-response,
and unsafe-listing tests. It needs no internet and no external runtime.

## Known limitations

- stdio only (`UNAVAILABLE` for HTTP transport).
- No MCP resources/prompts/sampling (`UNAVAILABLE`).
- No runtime creation of server configs via API (`UNSUPPORTED`, intentional).
- If a server crashes mid-call the runtime reports `error` state and disables
  that server's tools until a successful restart.
