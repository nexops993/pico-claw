const std = @import("std");
const builtin = @import("builtin");

const ConfigModule =
    @import("config.zig");

const Config =
    ConfigModule.Config;

const env_loader =
    @import("env_loader.zig");

const ChatProvider =
    @import("brain.zig").ChatProvider;

const Agent =
    @import("core/agent.zig").Agent;

const ConversationModule =
    @import("core/conversation.zig");

const Conversation =
    ConversationModule.Conversation;

const ConversationTeacher =
    ConversationModule.Teacher;

const Provider =
    @import("provider.zig").Provider;

const Memory =
    @import("memory/memory.zig").Memory;

const ExperienceStore =
    @import("experience/store.zig").ExperienceStore;

const StrategyStore =
    @import("experience/strategy_store.zig").StrategyStore;

const KnowledgeStore =
    @import("knowledge.zig").KnowledgeStore;

const OwnerContext =
    @import("owner.zig").OwnerContext;

const task =
    @import("core/task.zig");

const TaskStore =
    @import("core/task_store.zig").TaskStore;

const ProposalStore =
    @import("experience/proposal.zig").ProposalStore;

const Calculator =
    @import("tools/calculator.zig").Calculator;

const Filesystem =
    @import("tools/filesystem.zig").Filesystem;

const SystemTool =
    @import("tools/system.zig").SystemTool;

const runtime_sandbox = @import("runtime/sandbox.zig");
const runtime_tools = @import("runtime/tools.zig");
const mcp_registry_mod = @import("mcp/registry.zig");
const mcp_config_mod = @import("mcp/config.zig");
const runs_mod = @import("core/runs.zig");
const jobs_mod = @import("core/jobs.zig");
const attachments_mod = @import("runtime/attachments.zig");
const artifacts_mod = @import("services/artifacts.zig");

const gateway_mod = @import("services/gateways.zig");
const models_mod = @import("services/models.zig");
const settings_mod = @import("services/settings.zig");
const profiles_mod = @import("services/profiles.zig");
const service_mod = @import("services/service.zig");
const telegram_tool = @import("channels/telegram_tool.zig");

const cli = @import("interfaces/cli.zig");
const ui = @import("interfaces/ui.zig");
const http = @import("interfaces/http.zig");
const telegram = @import("channels/telegram.zig");
const session = @import("channels/session.zig");
const doctor_mod = @import("services/doctor.zig");

pub fn main(
    init: std.process.Init,
) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Load a local .env (if present) into the environment map before anything
    // reads it. Existing variables always win; values are never logged.
    // UI setup first: Windows console code page, colors, and the ASCII
    // glyph fallback when UTF-8 rendering is unavailable.
    const no_color = init.environ_map.get("NO_COLOR") != null;
    const force_ascii = init.environ_map.get("PICO_CLAW_ASCII") != null;
    ui.init(io, no_color, force_ascii);

    // Parse CLI arguments before anything prints so `--debug` gates all
    // startup diagnostics too.
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    const invocation = try cli.parseArgs(&args_iter);
    ui.setDebug(invocation.debug);
    const command = invocation.command;

    const env_count = env_loader.load(
        allocator,
        io,
        std.Io.Dir.cwd(),
        ".env",
        init.environ_map,
    ) catch |err| blk: {
        std.debug.print("[Env] .env load failed: {s}\n", .{@errorName(err)});
        break :blk 0;
    };
    if (env_count > 0) {
        ui.debugOut("Loaded .env: {d} variable(s)\n", .{env_count});
    }

    ui.banner(io, "Pico Claw", "Personal AI Agent");

    const config =
        Config.load(
            allocator,
        ) catch |err| {
            if (err == error.FileNotFound and !builtin.is_test) {
                std.debug.print(
                    "\nConfiguration error: config/config.json was not found in the working directory.\nCopy config/config.example.json to config/config.json and edit your local copy.\n",
                    .{},
                );
            }
            return err;
        };

    defer config.deinit(
        allocator,
    );

    // Required provider settings fail fast with clear, secret-free messages.
    try ConfigModule.validateEndpointAndModel(config.base_url, config.model);

    var calculator = Calculator{};
    var filesystem = Filesystem.init(
        io,
        std.Io.Dir.cwd(),
    );
    var system_tool = SystemTool{};

    var agent =
        Agent.init(
            allocator,
            config,
        );

    defer agent.deinit();

    try agent.registerTool(calculator.tool());
    try agent.registerTool(filesystem.tool());
    try agent.registerTool(system_tool.tool());

    // Sandbox runtime: an explicit workspace root with path policy, resource
    // limits, and an execution allowlist. Filesystem tools are registered
    // against it; process execution stays disabled until the operator
    // configures `executable_commands` here (no shell, no wildcard).
    var sandbox = try runtime_sandbox.Sandbox.init(
        io,
        allocator,
        std.Io.Dir.cwd(),
        "workspace",
        .{
            .read = true,
            .write = true,
            .execute = false,
            .env_allowlist = &.{ "PATH", "SystemRoot", "SYSTEMROOT", "SystemDrive", "ComSpec", "PATHEXT", "TEMP", "TMP" },
        },
        runtime_sandbox.Limits{},
    );
    defer sandbox.deinit();

    var sandbox_tools = runtime_tools.SandboxTools.init(allocator, &sandbox, init.environ_map);
    inline for (std.meta.fields(runtime_tools.ToolId)) |field| {
        const tool_id: runtime_tools.ToolId = @enumFromInt(field.value);
        try agent.registerTool(sandbox_tools.tool(tool_id));
    }

    var provider =
        Provider.init(
            allocator,
            io,
            init.environ_map,
            config,
        );

    var memory =
        try Memory.init(
            allocator,
            io,
        );

    defer memory.deinit();

    var experience =
        ExperienceStore.init(
            allocator,
            io,
        );

    defer experience.deinit();

    try experience.load();

    var strategies = StrategyStore.init(allocator, io);
    defer strategies.deinit();
    strategies.load() catch |err| {
        std.debug.print("[StrategyStore] Load failed: {s}\n", .{@errorName(err)});
    };

    var knowledge = KnowledgeStore.init(allocator, io);
    defer knowledge.deinit();
    knowledge.load() catch |err| {
        std.debug.print("[Knowledge] Load failed: {s}\n", .{@errorName(err)});
    };

    var owner_context = try OwnerContext.initAt(
        allocator,
        io,
        std.Io.Dir.cwd(),
        config.soul_path,
        config.memory_path,
        .{
            .soul_bytes = config.soul_budget_bytes,
            .memory_bytes = config.memory_budget_bytes,
            .combined_bytes = config.owner_budget_bytes,
        },
    );
    defer owner_context.deinit();

    var tasks = TaskStore.init(allocator, io);
    defer tasks.deinit();
    tasks.load() catch |err| {
        ui.statusLine(io, .warn, "Task journal load failed");
        ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
    };

    var proposals = ProposalStore.init(allocator, io);
    defer proposals.deinit();
    proposals.load() catch |err| {
        ui.statusLine(io, .warn, "Proposal journal load failed");
        ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
    };

    // M3: teacher routing. Without a configured teacher, behavior stays M2.
    const teacher_url_set = config.routing.teacher_base_url != null and
        config.routing.teacher_base_url.?.len > 0;
    const teacher_model_set = config.routing.teacher_model != null and
        config.routing.teacher_model.?.len > 0;
    if (teacher_url_set != teacher_model_set) {
        ui.statusLine(io, .warn, "Teacher routing disabled: both routing_teacher_base_url and routing_teacher_model must be set");
    }
    var teacher_provider: ?Provider = null;
    var teacher: ?ConversationTeacher = null;
    if (config.routing.teacherConfigured()) {
        teacher_provider = Provider.initTeacher(
            allocator,
            io,
            init.environ_map,
            config,
            config.routing.teacher_base_url.?,
            config.routing.teacher_model.?,
        );
        teacher = .{
            .provider = ChatProvider.fromProvider(&teacher_provider.?),
            .model_label = config.routing.teacher_model.?,
        };
    }

    // ---- Application service layer (presentation-neutral boundary) ----
    var gateway_manager = gateway_mod.GatewayManager.init(allocator, io, init.environ_map, false);
    defer gateway_manager.deinit();
    var settings_state = settings_mod.load(allocator, io);
    defer settings_state.deinit();
    var model_catalog = models_mod.Catalog.init(allocator, io, &provider);
    defer model_catalog.deinit();
    var profiles_service = profiles_mod.Service.init(allocator, io, std.Io.Dir.cwd(), profiles_mod.base_dir, &owner_context);
    defer profiles_service.deinit();

    var services = service_mod.Services{
        .allocator = allocator,
        .io = io,
        .env_map = init.environ_map,
        .config = &config,
        .provider = &provider,
        .sessions = null,
        .tools = &agent.tools,
        .memory = &memory,
        .tasks = &tasks,
        .proposals = &proposals,
        .owner_context = &owner_context,
        .gateways = &gateway_manager,
        .models = &model_catalog,
        .settings = &settings_state,
        .profiles = &profiles_service,
        .sandbox = &sandbox,
    };
    defer services.deinit();
    services.init();
    services.applyModelOverride() catch {};

    // MCP: loaded from config/mcp.json. Nothing runs unless the file turns
    // MCP on and a server is explicitly enabled AND started (here for
    // auto_start servers, or later through the control-plane API). A missing
    // file is normal (MCP not configured); an invalid file is reported but
    // never crashes the runtime — MCP stays off.
    var mcp_registry = mcp_registry_mod.Registry.init(allocator, io);
    defer mcp_registry.deinit();
    mcp_registry.loadConfigFile(std.Io.Dir.cwd(), mcp_config_mod.default_path) catch |err| {
        if (err != error.FileNotFound) {
            ui.statusLine(io, .warn, "MCP disabled: config/mcp.json failed to load");
            ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
        }
    };
    services.mcp = &mcp_registry;
    if (mcp_registry.enabled) {
        mcp_registry.attachToolRegistry(&agent.tools);
        mcp_registry.startAutoStart();
        const started = mcp_registry.runningCount();
        const mcp_tools = mcp_registry.availableToolCount();
        if (started > 0) {
            ui.statusLine(io, .ok, "MCP servers ready");
            ui.out(io, "  {s}{d} running, {d} tools registered{s}\n", .{
                ui.Color.dim.code(),
                started,
                mcp_tools,
                ui.Color.reset.code(),
            });
        } else if (mcp_registry.serverCount() > 0) {
            ui.statusLine(io, .warn, "MCP configured but no server is running");
        }
    }

    // Operations subsystems: attachments, artifacts, background jobs, runs.
    // All live inside the sandbox/workspace boundary; jobs run on one bounded
    // worker thread and are shut down gracefully below.
    var runs_store = runs_mod.Store.init(allocator, io);
    defer runs_store.deinit();
    var jobs_runtime = try jobs_mod.Runtime.init(allocator, io, 120_000);
    defer jobs_runtime.deinit();
    jobs_runtime.attachRuns(&runs_store);
    var attachments_store = attachments_mod.Store.init(allocator, &sandbox);
    defer attachments_store.deinit();
    var artifacts_store = artifacts_mod.Store.init(allocator, &sandbox);
    defer artifacts_store.deinit();

    services.runs = &runs_store;
    services.jobs = jobs_runtime;
    services.attachments = &attachments_store;
    services.artifacts = &artifacts_store;

    // Recovery: clean interrupted uploads left by previous runs.
    const orphans_removed = attachments_store.cleanupOrphans();
    if (orphans_removed > 0) {
        ui.statusLine(io, .ok, "Recovery cleanup");
        ui.out(io, "  {s}{d} interrupted upload(s) removed{s}\n", .{
            ui.Color.dim.code(),
            orphans_removed,
            ui.Color.reset.code(),
        });
    }

    // Explicit Telegram agent-tool grant: channel configured != tool allowed.
    var telegram_agent_tool: ?telegram_tool.TelegramTool = null;
    defer if (telegram_agent_tool) |*tool| tool.deinit();
    if (telegram_tool.permissionGranted(init.environ_map)) {
        telegram_agent_tool = telegram_tool.TelegramTool.init(allocator, io, init.environ_map) catch null;
        if (telegram_agent_tool) |*tool| {
            agent.registerTool(tool.tool()) catch |err| {
                ui.debugOut("[TelegramTool] registration failed: {s}\n", .{@errorName(err)});
                telegram_agent_tool = null;
            };
        }
    }

    // Compose the runtime system prompt (policy + capabilities + profile).
    services.rebuildSystemPrompt() catch {};
    const composed_prompt: []const u8 = if (services.system_prompt.len > 0) services.system_prompt else config.system_prompt;

    var conversation =
        try Conversation.init(
            allocator,
            io,
            &provider,
            &agent.tools,
            &memory,
            &experience,
            &strategies,
            &knowledge,
            &owner_context,
            composed_prompt,
            &tasks,
            task.RetryPolicy{ .max_attempts = services.effectiveAttempts() },
        );
    conversation.teacher = teacher;
    conversation.routing = .{
        .teacher_configured = config.routing.teacherConfigured(),
        .local_only = config.routing.local_only,
        .max_request_bytes = config.routing.teacher_max_request_bytes,
    };
    conversation.proposals = &proposals;

    defer conversation.deinit();

    // Commands that contact the primary provider require an API key; local
    // commands (status, proposals, channel, help) work without one.
    const needs_provider_key = switch (command) {
        .chat, .serve => true,
        .status, .help, .version, .proposals, .channel => false,
        .doctor, .install, .uninstall, .update => false,
    };
    if (needs_provider_key) {
        try ConfigModule.validateApiKey(init.environ_map.get("PICO_CLAW_API_KEY"));
    }
    switch (command) {
        .chat => {
            printChatSummary(io, &config, agent.toolCount());
            try cli.run(allocator, io, &conversation);
        },
        .serve => {
            printChatSummary(io, &config, agent.toolCount());

            // Dashboard bind/auth configuration. Loopback without a token is
            // the default; anything non-loopback requires a token (enforced
            // by the server).
            const dash_host = blk: {
                const raw = init.environ_map.get("PICO_CLAW_DASHBOARD_HOST") orelse break :blk "127.0.0.1";
                break :blk if (raw.len > 0) raw else "127.0.0.1";
            };
            var dash_port: u16 = http.default_port;
            if (init.environ_map.get("PICO_CLAW_DASHBOARD_PORT")) |raw| {
                dash_port = std.fmt.parseInt(u16, raw, 10) catch http.default_port;
            }
            const dash_token: ?[]const u8 = blk: {
                const raw = init.environ_map.get("PICO_CLAW_DASHBOARD_TOKEN") orelse break :blk null;
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                break :blk if (trimmed.len > 0) trimmed else null;
            };

            // The dashboard uses the same session layer and agent core as
            // Telegram and CLI chat; only its chat identity differs.
            var sessions = session.SessionStore.init(allocator, io, .{
                .provider = &provider,
                .tools = &agent.tools,
                .memory = &memory,
                .experience = &experience,
                .strategies = &strategies,
                .knowledge = &knowledge,
                .owner = &owner_context,
                .tasks = &tasks,
                .proposals = &proposals,
                .retry = .{ .max_attempts = services.effectiveAttempts() },
                .system_prompt = composed_prompt,
                .routing = .{
                    .teacher_configured = config.routing.teacherConfigured(),
                    .local_only = config.routing.local_only,
                    .max_request_bytes = config.routing.teacher_max_request_bytes,
                },
                .teacher = teacher,
            });
            defer sessions.deinit();
            services.sessions = &sessions;

            var dashboard_chat = http.SessionChatHandler{ .sessions = &sessions };
            var dashboard = http.Dashboard{
                .handler = http.ChatHandler.fromConversation(&dashboard_chat),
                .sessions = &sessions,
                .agent_name = config.agent_name,
                .model = config.model,
                .base_url = config.base_url,
                .telegram_state = gateway_manager.state.name(),
                .services = &services,
                .auth = .{ .token = dash_token },
            };
            services.dashboard_host = dash_host;
            services.dashboard_port = dash_port;
            services.auth_required = dash_token != null;
            http.serve(allocator, io, &dashboard, dash_host, dash_port) catch |err| switch (err) {
                error.NonLoopbackRequiresAuth => {
                    ui.statusLine(io, .fail, "Refusing to bind a non-loopback address without a dashboard token");
                    ui.out(io, "  {s}Set PICO_CLAW_DASHBOARD_TOKEN (or keep 127.0.0.1).{s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
                    return;
                },
                else => return err,
            };
        },
        .status => {
            ui.out(io, "\n{s}Pico Claw v0.1.0{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
            ui.kv(io, "Model", config.model);
            ui.out(io, "  {s}Tools{s}    {d}\n", .{ ui.Color.dim.code(), ui.Color.reset.code(), agent.toolCount() });
            var memories_buf: [48]u8 = undefined;
            var experiences_buf: [48]u8 = undefined;
            var strategies_buf: [48]u8 = undefined;
            var knowledge_buf: [48]u8 = undefined;
            var tasks_buf: [96]u8 = undefined;
            var proposals_buf: [96]u8 = undefined;
            ui.section(io, "Memory");
            ui.treeItem(io, false, "Memories", ui.countLabel(&memories_buf, memory.count(), "memories"));
            ui.treeItem(io, false, "Experiences", ui.countLabel(&experiences_buf, experience.count(), "entries"));
            ui.treeItem(io, false, "Strategies", ui.countLabel(&strategies_buf, strategies.count(), "entries"));
            ui.treeItem(io, true, "Knowledge", ui.countLabel(&knowledge_buf, knowledge.count(), "entries"));
            ui.section(io, "Tasks");
            ui.treeItem(io, true, "Journal", taskCountLabel(&tasks_buf, &tasks));
            ui.section(io, "Proposals");
            ui.treeItem(io, true, "Journal", proposalCountLabel(&proposals_buf, &proposals));
            ui.section(io, "Channels");
            ui.treeItem(io, true, "Telegram", telegram.stateFromEnv(init.environ_map).label());
            ui.section(io, "Provider");
            ui.treeItem(io, false, "URL", config.base_url);
            ui.treeItem(io, false, "Model", config.model);
            ui.treeItem(io, true, "Auth", "environment variable");
            ui.section(io, "Owner");
            ui.treeItem(io, false, "SOUL.md", owner_context.soul.status.name());
            ui.treeItem(io, true, "MEMORY.md", owner_context.memory.status.name());
            ui.section(io, "Routing");
            ui.treeItem(io, false, "Teacher", config.routing.teacher_model orelse "disabled");
            ui.treeItem(io, true, "Local-only", if (config.routing.local_only) "true" else "false");
            ui.out(io, "\n", .{});
        },
        .proposals => |request| cli.runProposals(io, &proposals, request),
        .channel => |request| switch (request.action) {
            .status => {
                const state = telegram.stateFromEnv(init.environ_map);
                ui.out(io, "\n{s}Channel status{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
                ui.out(io, "  {s}telegram{s}  {s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code(), state.label() });
                ui.out(io, "\n", .{});
            },
            .telegram => {
                var telegram_config = telegram.configFromEnv(allocator, init.environ_map) catch |err| switch (err) {
                    error.TokenMissing => {
                        ui.statusLine(io, .fail, "Telegram bot token missing");
                        ui.out(io, "  {s}Set TELEGRAM_BOT_TOKEN (and TELEGRAM_ENABLED=true) in the environment or .env.{s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
                        return;
                    },
                    error.InvalidAllowedUsers => {
                        ui.statusLine(io, .fail, "TELEGRAM_ALLOWED_USERS is invalid");
                        ui.out(io, "  {s}Expected comma-separated numeric Telegram user ids.{s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
                        return;
                    },
                    else => {
                        ui.statusLine(io, .fail, "Telegram config invalid");
                        ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
                        return;
                    },
                };
                defer telegram_config.deinit(allocator);

                const state = telegram.stateFromEnv(init.environ_map);
                if (state != .enabled) {
                    ui.statusLine(io, .warn, "Telegram channel is disabled");
                    ui.out(io, "  {s}Set TELEGRAM_ENABLED=true to start polling.{s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
                    return;
                }

                // The runtime reuses the fully wired agent stack built above;
                // token values are never printed or logged.
                var sessions = session.SessionStore.init(allocator, io, .{
                    .provider = &provider,
                    .tools = &agent.tools,
                    .memory = &memory,
                    .experience = &experience,
                    .strategies = &strategies,
                    .knowledge = &knowledge,
                    .owner = &owner_context,
                    .tasks = &tasks,
                    .proposals = &proposals,
                    .retry = .{ .max_attempts = config.task_max_attempts },
                    .system_prompt = config.system_prompt,
                    .routing = .{
                        .teacher_configured = config.routing.teacherConfigured(),
                        .local_only = config.routing.local_only,
                        .max_request_bytes = config.routing.teacher_max_request_bytes,
                    },
                    .teacher = teacher,
                });
                var runtime = telegram.Runtime.init(allocator, io, &telegram_config, &sessions);
                telegram.installShutdownHandler();
                runtime.run() catch |err| {
                    ui.statusLine(io, .fail, "Telegram polling stopped");
                    ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
                };
                sessions.deinit();
            },
        },
        .help => cli.printUsage(),
        .version => ui.out(io, "Pico Claw v0.1.0\n", .{}),
        .doctor => {
            var report = doctor_mod.run(allocator, .{
                .version = "0.1.0",
                .env = init.environ_map,
                .config = &config,
                .io = io,
                .sandbox = &sandbox,
                .mcp = &mcp_registry,
                .attachments = &attachments_store,
                .artifacts = &artifacts_store,
                .jobs = jobs_runtime,
                .runs = &runs_store,
                .provider = &provider,
                .probe_network = true,
            }) catch |err| {
                ui.statusLine(io, .fail, "Doctor run failed");
                ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
                return;
            };
            defer report.deinit();
            ui.out(io, "\n{s}Doctor{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
            for (report.checks.items) |check| {
                const color: []const u8 = switch (check.status) {
                    .pass => ui.Color.green.code(),
                    .warn => ui.Color.yellow.code(),
                    .fail => ui.Color.red.code(),
                    .unavailable, .unsupported => ui.Color.dim.code(),
                };
                ui.out(io, "  {s}{s:<13}{s}{s}  {s}\n", .{
                    color,
                    check.name,
                    ui.Color.reset.code(),
                    check.status.name(),
                    check.detail,
                });
            }
            ui.out(io, "\n  Overall: {s}\n\n", .{report.overall().name()});
        },
        .install => {
            ui.out(io, "\n{s}Install{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
            std.Io.Dir.cwd().createDirPath(io, "data") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => ui.out(io, "  {s}warn{s}   data/ not created: {s}\n", .{ ui.Color.yellow.code(), ui.Color.reset.code(), @errorName(err) }),
            };
            ui.statusLine(io, .ok, "workspace/ ready");
            ui.statusLine(io, .ok, "data/ ready");
            const cfg_exists = blk: {
                var f = std.Io.Dir.cwd().openFile(io, "config/config.json", .{}) catch break :blk false;
                f.close(io);
                break :blk true;
            };
            if (cfg_exists) {
                ui.statusLine(io, .ok, "config/config.json present (left untouched)");
            } else {
                const example = std.Io.Dir.cwd().readFileAlloc(io, "config/config.example.json", allocator, .limited(64 * 1024)) catch null;
                if (example) |content| {
                    defer allocator.free(content);
                    const maybe_file = std.Io.Dir.cwd().createFile(io, "config/config.json", .{ .exclusive = true }) catch null;
                    if (maybe_file) |file| {
                        defer file.close(io);
                        file.writeStreamingAll(io, content) catch {};
                        ui.statusLine(io, .ok, "config/config.json created from example");
                    } else {
                        ui.statusLine(io, .warn, "config/config.json could not be created");
                    }
                } else {
                    ui.statusLine(io, .warn, "config/config.example.json not found; copy it manually");
                }
            }
            ui.out(io, "\n  Next: edit config/config.json, set PICO_CLAW_API_KEY, then run `pico_claw doctor`.\n\n", .{});
        },
        .uninstall => |request| {
            ui.out(io, "\n{s}Uninstall{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
            ui.out(io, "  binary    the pico_claw executable (delete this file manually; never automatic)\n", .{});
            ui.out(io, "  config    config/ (includes MCP configuration)\n", .{});
            ui.out(io, "  workspace workspace/ (uploads, artifacts, agent files)\n", .{});
            ui.out(io, "  data      data/ (task journal)\n", .{});
            ui.out(io, "  memory    SOUL.md, MEMORY.md (user data)\n", .{});
            if (!request.yes) {
                ui.out(io, "\n  Dry run only: nothing was deleted. Re-run with `uninstall --yes` to\n", .{});
                ui.out(io, "  remove config/, workspace/, data/ and memory files. The binary is\n", .{});
                ui.out(io, "  always removed manually.\n\n", .{});
                return;
            }
            std.Io.Dir.cwd().deleteTree(io, "config") catch {};
            std.Io.Dir.cwd().deleteTree(io, "workspace") catch {};
            std.Io.Dir.cwd().deleteTree(io, "data") catch {};
            std.Io.Dir.cwd().deleteFile(io, "SOUL.md") catch {};
            std.Io.Dir.cwd().deleteFile(io, "MEMORY.md") catch {};
            ui.statusLine(io, .ok, "config/, workspace/, data/, SOUL.md, MEMORY.md removed");
            ui.out(io, "\n", .{});
        },
        .update => |request| {
            _ = request;
            ui.out(io, "\n{s}Update{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
            const os_tag = @tagName(builtin.os.tag);
            const arch_tag = @tagName(builtin.cpu.arch);
            ui.out(io, "  current version : v0.1.0\n", .{});
            ui.out(io, "  platform        : {s}-{s}\n", .{ os_tag, arch_tag });
            ui.out(io, "  release asset   : pico_claw-{s}-{s}-v0.1.0.zip\n", .{ os_tag, arch_tag });
            ui.out(io, "  source          : official GitHub Releases only (checksum verified,\n", .{});
            ui.out(io, "                    backup + atomic replace + rollback on failure)\n", .{});
            ui.out(io, "\n  Downloading and replacing binaries is UNSUPPORTED until signed release\n", .{});
            ui.out(io, "  assets exist. No self-update was performed.\n\n", .{});
        },
    }
}

fn taskCountLabel(buffer: []u8, tasks: *const TaskStore) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} ({d} completed, {d} failed)", .{
        tasks.count(),
        tasks.completedCount(),
        tasks.failedCount(),
    }) catch "";
}

fn proposalCountLabel(buffer: []u8, proposals: *const ProposalStore) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} ({d} proposed, {d} accepted, {d} rejected)", .{
        proposals.count(),
        proposals.countStatus(.proposed),
        proposals.countStatus(.accepted),
        proposals.countStatus(.rejected),
    }) catch "";
}

fn printChatSummary(io: std.Io, config: *const Config, tool_count: usize) void {
    ui.out(io, "\n", .{});
    ui.kv(io, "Model", config.model);
    ui.out(io, "  {s}Tools{s}    {d}\n", .{ ui.Color.dim.code(), ui.Color.reset.code(), tool_count });
    ui.kv(io, "Provider", config.base_url);
    ui.out(io, "\n", .{});
    ui.statusLine(io, .ok, "Memory initialized");
    ui.statusLine(io, .ok, "Provider ready");
    if (config.routing.teacherConfigured()) {
        ui.statusLine(io, .ok, "Teacher ready");
    } else if (config.routing.local_only) {
        ui.statusLine(io, .warn, "Local-only mode");
    } else {
        ui.statusLine(io, .warn, "Teacher disabled");
    }
    ui.out(io, "\n  {s}Type `help` for commands.{s}\n\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
}
