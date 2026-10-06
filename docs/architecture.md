# Architecture

```text
CLI / HTTP / Dashboard / Telegram channel
        |
   Application Service (src/services/)
        |
   Conversation
        |
Memory retrieval ---- Knowledge retrieval ---- Strategy selection
        |
     Planner
        |
    Executor
        |
 ToolRegistry / Tools
        |
 Brain / Provider
        |
 Experience -> Evaluation -> Reflection -> Learning
        |
 StrategyStore + KnowledgeStore + Memory persistence
```

## Responsibilities

- `src/main.zig`: loads config, constructs long-lived components, registers built-in tools (plus the explicit-grant Telegram tool), loads persisted stores, composes the runtime system prompt through the service layer, and dispatches the command.
- `services/`: the presentation-neutral application service boundary. `Services` exposes status, sessions, models, tools, skills, memory, runs, gateways, profiles, config, and settings as typed operations that return allocated JSON payloads; HTTP handlers call these and never touch stores, the provider, or the tool registry directly. `gateways.zig` owns the gateway lifecycle state machine, `models.zig` the discovery cache, `settings.zig` validated persisted overrides, `profiles.zig` contained profile CRUD and activation.
- `core/capabilities.zig`: the runtime capability manifest. Assembled from live state (tools, gateway state, provider configuration, workspace), rendered into the agent's system prompt, and served at `/api/capabilities`. The model must never claim a capability that is not in the manifest; disabled tools are also hidden from the Brain's tool instructions.
- `interfaces/cli.zig`: top-level argument parsing and interactive terminal loop.
- `interfaces/http.zig`: loopback listener, HTTP parsing/routing, dashboard HTML, body limit, JSON responses.
- `core/conversation.zig`: request coordinator and session context owner.
- `memory/`: five typed JSONL stores and relevance-ranked retrieval, bounded to 10 in conversation.
- `knowledge.zig`: learned topic/content records; conversation asks for at most 3 substring matches.
- `experience/strategy_store.zig`: aggregate strategy statistics and deterministic best eligible strategy selection.
- `planner.zig`: creates owned, bounded plans without side effects.
- `executor.zig`: executes plan steps in order through ToolRegistry; reasoning steps echo description.
- `tools/registry.zig`: validates unique names and dispatches tools.
- `brain.zig`: adds tool instructions, invokes provider, parses exact tool-call envelopes, executes tools, and feeds results back; maximum four tool calls.
- `provider.zig`: buffered bearer-authenticated chat-completions request and response extraction.
- `experience/`: stores successful interactions, deterministically evaluates, reflects, learns, and updates persistence.
- `skills.zig`: static metadata/keyword guidance with runtime enable flags exposed through the service layer; disabling a skill also disables its linked tool. Not dynamically loaded and not wired into Conversation planning.
- `channels/telegram_tool.zig`: the Telegram agent tool (get_me/get_chat/allowlisted send_message), registered only with the explicit `TELEGRAM_TOOL_ENABLED` grant; channel configured does not imply tool permission.
- `owner.zig`: loads bounded `SOUL.md`/`MEMORY.md` owner context (labels, deterministic truncation, atomic MEMORY.md replacement). It is not a policy mechanism; content stays subordinate to the system prompt.

## Request sequence

Conversation searches memory, plans input, directly executes plan only when first tool is `calculator`, then builds temporary provider context containing system prompt, bounded owner context (SOUL.md/MEMORY.md, explicitly labeled as lower-priority untrusted data), preferred strategy, matching knowledge, calculator output, memories, and session messages. Brain handles optional provider-directed tool calls. On successful final response, Conversation appends session messages and records experience as `success`. Persistence/reflection failures are logged after response generation and do not add new runtime capabilities.

Filesystem planner recognition produces natural-language task input. Because Filesystem tool requires `read <path>` or `write <path>\n<content>`, Conversation intentionally does not directly execute filesystem plans.

## Ownership and lifetime

`main` owns config strings and long-lived Agent/ToolRegistry, Provider, Memory, ExperienceStore, StrategyStore, KnowledgeStore, and Conversation. Tools are stack values registered by non-owning context pointer and outlive registry. Stores own duplicated strings and free them in `deinit`. Context owns copied message content. Plans and execution results own task/step/output allocations. Search result arrays are temporary borrowed-entry copies; caller frees arrays, stores retain entry strings. Provider replies are caller-owned allocations.

Application uses current working directory for `config/config.json`, workspace filesystem base, and `data/` persistence.
