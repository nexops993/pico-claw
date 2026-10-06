const std = @import("std");
const builtin = @import("builtin");
const owner = @import("owner.zig");
const task = @import("core/task.zig");
const router = @import("core/router.zig");

/// M3 teacher routing configuration. All values are optional: without a
/// teacher endpoint and model, escalation stays disabled and installs keep
/// their pre-M3 behavior exactly.
pub const RoutingConfig = struct {
    /// Privacy mode: never send a task to a remote teacher, even when one is
    /// configured.
    local_only: bool = false,
    /// Teacher endpoint (OpenAI-style chat completions). Owned.
    teacher_base_url: ?[]const u8 = null,
    /// Teacher model name; recorded in the task journal as a label. Owned.
    teacher_model: ?[]const u8 = null,
    /// Byte budget for the compact teacher request.
    teacher_max_request_bytes: usize = router.default_max_request_bytes,

    /// A teacher is usable only when both endpoint and model are configured
    /// with non-empty values.
    pub fn teacherConfigured(self: *const RoutingConfig) bool {
        const url = self.teacher_base_url orelse return false;
        const model = self.teacher_model orelse return false;
        return url.len > 0 and model.len > 0;
    }
};

// ---------------------------------------------------------------------------
// Provider request deadline: bounded configuration, never unbounded
// ---------------------------------------------------------------------------

/// Default hard deadline for provider HTTP requests. Generous enough for
/// slow completion endpoints, small enough that a hung connection cannot
/// stall the single-threaded runtime for minutes on end.
pub const default_request_timeout_ms: u32 = 120_000;
/// Hard cap for the configured deadline. Nothing can configure a provider
/// request that blocks longer than ten minutes.
pub const max_request_timeout_ms: u32 = 600_000;

/// Normalize a raw `request_timeout_ms` config value. Absent, non-finite,
/// negative, zero, or fractional-below-one values fall back to the default;
/// values above the cap are clamped. Zero deliberately means "unset", never
/// "disabled": a provider request cannot be configured to hang forever.
pub fn requestTimeoutFromRaw(raw: ?f64) u32 {
    const value = raw orelse return default_request_timeout_ms;
    if (!std.math.isFinite(value) or value < 1) return default_request_timeout_ms;
    if (value >= @as(f64, max_request_timeout_ms)) return max_request_timeout_ms;
    return @intFromFloat(value);
}

pub const Config = struct {
    agent_name: []const u8,
    model: []const u8,
    base_url: []const u8,
    system_prompt: []const u8,
    temperature: f64,
    max_tokens: u32,
    soul_path: []const u8,
    memory_path: []const u8,
    soul_budget_bytes: usize,
    memory_budget_bytes: usize,
    owner_budget_bytes: usize,
    /// Total provider attempts per task. Default 1 keeps pre-M2 behavior
    /// (no retries); the value is clamped into 1..=5.
    task_max_attempts: u8 = 1,
    /// Hard deadline for every provider HTTP request (chat, model discovery).
    /// Absent or invalid values fall back to `default_request_timeout_ms`;
    /// the effective value is always within 1..=`max_request_timeout_ms`, so
    /// a hung endpoint can never block the single-threaded runtime forever.
    request_timeout_ms: u32 = default_request_timeout_ms,
    /// M3 teacher routing. Without a teacher, failures stay on the primary
    /// provider exactly as before.
    routing: RoutingConfig = .{},

    pub fn load(
        allocator: std.mem.Allocator,
    ) !Config {
        const io =
            std.Io.Threaded.global_single_threaded.io();

        var file = try std.Io.Dir.cwd().openFile(
            io,
            "config/config.json",
            .{},
        );
        defer file.close(io);

        var buffer: [16 * 1024]u8 = undefined;

        const buffers = [_][]u8{
            buffer[0..],
        };

        const size = try file.readPositional(
            io,
            &buffers,
            0,
        );

        return parse(allocator, buffer[0..size]);
    }

    /// Parse configuration JSON into an owned `Config` (free with `deinit`).
    /// Owner fields are optional: legacy configs without them keep working
    /// with conservative defaults. Malformed JSON, missing required fields,
    /// or wrong-typed values fail startup. Budget values that are negative,
    /// non-finite, or absurd fall back to defaults or are clamped to hard
    /// caps instead of failing (see `owner.limitsFromRaw`).
    pub fn parse(
        allocator: std.mem.Allocator,
        contents: []const u8,
    ) !Config {
        const ParsedSettings = struct {
            temperature: f64,
            max_tokens: u32,
            soul_path: []const u8 = owner.defaults.soul_path,
            memory_path: []const u8 = owner.defaults.memory_path,
            soul_budget_bytes: ?f64 = null,
            memory_budget_bytes: ?f64 = null,
            owner_budget_bytes: ?f64 = null,
            task_max_attempts: ?f64 = null,
            request_timeout_ms: ?f64 = null,
            routing_local_only: ?bool = null,
            routing_teacher_base_url: ?[]const u8 = null,
            routing_teacher_model: ?[]const u8 = null,
            routing_teacher_max_request_bytes: ?f64 = null,
        };

        const ParsedConfig = struct {
            agent_name: []const u8,
            model: []const u8,
            base_url: []const u8,
            system_prompt: []const u8,
            settings: ParsedSettings,
        };

        const parsed = try std.json.parseFromSlice(
            ParsedConfig,
            allocator,
            contents,
            .{},
        );
        defer parsed.deinit();

        const agent_name = try allocator.dupe(
            u8,
            parsed.value.agent_name,
        );
        errdefer allocator.free(agent_name);
        const model = try allocator.dupe(
            u8,
            parsed.value.model,
        );
        errdefer allocator.free(model);
        const base_url = try allocator.dupe(
            u8,
            parsed.value.base_url,
        );
        errdefer allocator.free(base_url);
        const system_prompt = try allocator.dupe(
            u8,
            parsed.value.system_prompt,
        );
        errdefer allocator.free(system_prompt);
        const soul_path = try allocator.dupe(
            u8,
            parsed.value.settings.soul_path,
        );
        errdefer allocator.free(soul_path);
        const memory_path = try allocator.dupe(
            u8,
            parsed.value.settings.memory_path,
        );
        errdefer allocator.free(memory_path);

        var routing = RoutingConfig{
            .local_only = parsed.value.settings.routing_local_only orelse false,
            .teacher_max_request_bytes = router.Policy.fromRawRequestBytes(
                parsed.value.settings.routing_teacher_max_request_bytes,
            ),
        };
        if (parsed.value.settings.routing_teacher_base_url) |url| {
            const owned_url = try allocator.dupe(u8, url);
            errdefer allocator.free(owned_url);
            routing.teacher_base_url = owned_url;
        }
        if (parsed.value.settings.routing_teacher_model) |teacher_model| {
            const owned_model = try allocator.dupe(u8, teacher_model);
            errdefer allocator.free(owned_model);
            routing.teacher_model = owned_model;
        }

        const limits = owner.limitsFromRaw(
            parsed.value.settings.soul_budget_bytes,
            parsed.value.settings.memory_budget_bytes,
            parsed.value.settings.owner_budget_bytes,
        );

        return .{
            .agent_name = agent_name,
            .model = model,
            .base_url = base_url,
            .system_prompt = system_prompt,
            .temperature = parsed.value.settings.temperature,
            .max_tokens = parsed.value.settings.max_tokens,
            .soul_path = soul_path,
            .memory_path = memory_path,
            .soul_budget_bytes = limits.soul_bytes,
            .memory_budget_bytes = limits.memory_bytes,
            .owner_budget_bytes = limits.combined_bytes,
            .task_max_attempts = task.RetryPolicy.fromRaw(parsed.value.settings.task_max_attempts)
                .sanitized()
                .max_attempts,
            .request_timeout_ms = requestTimeoutFromRaw(parsed.value.settings.request_timeout_ms),
            .routing = routing,
        };
    }

    pub fn deinit(
        self: *const Config,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.agent_name);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.system_prompt);
        allocator.free(self.soul_path);
        allocator.free(self.memory_path);
        if (self.routing.teacher_base_url) |url| allocator.free(url);
        if (self.routing.teacher_model) |model| allocator.free(model);
    }
};

// ---------------------------------------------------------------------------
// Provider settings validation: clear, secret-free diagnostics
// ---------------------------------------------------------------------------

pub const ProviderValidationError = error{
    MissingBaseUrl,
    MissingModel,
    MissingApiKey,
};

/// Validate the required endpoint and model. Runs for every command so a
/// broken configuration fails fast with an actionable message.
pub fn validateEndpointAndModel(
    base_url: []const u8,
    model: []const u8,
) ProviderValidationError!void {
    if (base_url.len == 0) {
        if (!builtin.is_test) std.debug.print(
            "\nConfiguration error: the provider endpoint is empty.\nSet \"base_url\" in config/config.json, for example \"https://api.example.com/v1\".\n",
            .{},
        );
        return error.MissingBaseUrl;
    }
    if (model.len == 0) {
        if (!builtin.is_test) std.debug.print(
            "\nConfiguration error: the provider model is empty.\nSet \"model\" in config/config.json.\n",
            .{},
        );
        return error.MissingModel;
    }
}

/// Validate that the provider API key is present. Only its presence is
/// checked — the key value is never printed, logged, or stored. Required for
/// commands that contact the provider (chat, serve); local commands such as
/// status and proposals work without it.
pub fn validateApiKey(api_key: ?[]const u8) ProviderValidationError!void {
    if (api_key == null or api_key.?.len == 0) {
        if (!builtin.is_test) std.debug.print(
            "\nConfiguration error: the provider API key is not set.\nExport PICO_CLAW_API_KEY or add it to a local .env file (see .env.example).\nThe key is required for chat and serve; status and proposals work without it.\n",
            .{},
        );
        return error.MissingApiKey;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Configuration regression tests
// ---------------------------------------------------------------------------

fn expectParseError(allocator: std.mem.Allocator, contents: []const u8) !void {
    if (Config.parse(allocator, contents)) |config| {
        config.deinit(allocator);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "legacy config without owner fields keeps defaults" {
    const contents =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": {
        \\        "temperature": 0.5,
        \\        "max_tokens": 128
        \\    }
        \\}
    ;

    const config = try Config.parse(std.testing.allocator, contents);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(owner.defaults.soul_path, config.soul_path);
    try std.testing.expectEqualStrings(owner.defaults.memory_path, config.memory_path);
    try std.testing.expectEqual(owner.defaults.soul_bytes, config.soul_budget_bytes);
    try std.testing.expectEqual(owner.defaults.memory_bytes, config.memory_budget_bytes);
    try std.testing.expectEqual(owner.defaults.combined_bytes, config.owner_budget_bytes);
    try std.testing.expectEqual(@as(f64, 0.5), config.temperature);
    try std.testing.expectEqual(@as(u32, 128), config.max_tokens);
    try std.testing.expectEqualStrings("Pico", config.agent_name);
}

test "valid owner fields are applied from config" {
    const contents =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": {
        \\        "temperature": 0.9,
        \\        "max_tokens": 256,
        \\        "soul_path": "custom/SOUL.md",
        \\        "memory_path": "notes/MEMORY.md",
        \\        "soul_budget_bytes": 2048,
        \\        "memory_budget_bytes": 8192,
        \\        "owner_budget_bytes": 10240
        \\    }
        \\}
    ;

    const config = try Config.parse(std.testing.allocator, contents);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("custom/SOUL.md", config.soul_path);
    try std.testing.expectEqualStrings("notes/MEMORY.md", config.memory_path);
    try std.testing.expectEqual(@as(usize, 2048), config.soul_budget_bytes);
    try std.testing.expectEqual(@as(usize, 8192), config.memory_budget_bytes);
    try std.testing.expectEqual(@as(usize, 10240), config.owner_budget_bytes);
    try std.testing.expectEqual(@as(f64, 0.9), config.temperature);
    try std.testing.expectEqual(@as(u32, 256), config.max_tokens);
}

test "task retry attempts are optional, defaulted, and clamped" {
    const legacy =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128 }
        \\}
    ;
    const defaulted = try Config.parse(std.testing.allocator, legacy);
    defer defaulted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), defaulted.task_max_attempts);

    const configured =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128, "task_max_attempts": 3 }
        \\}
    ;
    const retrying = try Config.parse(std.testing.allocator, configured);
    defer retrying.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), retrying.task_max_attempts);

    const absurd =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128, "task_max_attempts": 99 }
        \\}
    ;
    const clamped = try Config.parse(std.testing.allocator, absurd);
    defer clamped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, task.hard_max_attempts), clamped.task_max_attempts);
}

test "provider request deadline is bounded and cannot be disabled" {
    // Raw normalization: absent, non-finite, negative, zero and sub-one
    // values fall back to the default; oversized values clamp to the cap.
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(null));
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(0));
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(-5));
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(0.5));
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(std.math.nan(f64)));
    try std.testing.expectEqual(default_request_timeout_ms, requestTimeoutFromRaw(std.math.inf(f64)));
    try std.testing.expectEqual(@as(u32, 30_000), requestTimeoutFromRaw(30_000));
    try std.testing.expectEqual(max_request_timeout_ms, requestTimeoutFromRaw(1e12));

    // Config parsing: absent keeps the default, a configured value is used.
    const legacy =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128 }
        \\}
    ;
    const defaulted = try Config.parse(std.testing.allocator, legacy);
    defer defaulted.deinit(std.testing.allocator);
    try std.testing.expectEqual(default_request_timeout_ms, defaulted.request_timeout_ms);

    const configured =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128, "request_timeout_ms": 45000 }
        \\}
    ;
    const bounded = try Config.parse(std.testing.allocator, configured);
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 45_000), bounded.request_timeout_ms);
}

test "teacher routing config is optional and defaults to disabled" {
    const legacy =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.5, "max_tokens": 128 }
        \\}
    ;
    const without_teacher = try Config.parse(std.testing.allocator, legacy);
    defer without_teacher.deinit(std.testing.allocator);
    try std.testing.expect(!without_teacher.routing.teacherConfigured());
    try std.testing.expect(!without_teacher.routing.local_only);
    try std.testing.expectEqual(router.default_max_request_bytes, without_teacher.routing.teacher_max_request_bytes);
    try std.testing.expect(without_teacher.routing.teacher_base_url == null);
    try std.testing.expect(without_teacher.routing.teacher_model == null);

    // Only the endpoint: escalation stays disabled until the model is set too.
    const partial =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": {
        \\        "temperature": 0.5,
        \\        "max_tokens": 128,
        \\        "routing_teacher_base_url": "https://teacher.example/v1"
        \\    }
        \\}
    ;
    const partial_parsed = try Config.parse(std.testing.allocator, partial);
    defer partial_parsed.deinit(std.testing.allocator);
    try std.testing.expect(!partial_parsed.routing.teacherConfigured());

    // Both keys, local-only, and an absurd budget: parsed, clamped.
    const routed =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": {
        \\        "temperature": 0.5,
        \\        "max_tokens": 128,
        \\        "routing_teacher_base_url": "https://teacher.example/v1",
        \\        "routing_teacher_model": "strong-model",
        \\        "routing_local_only": true,
        \\        "routing_teacher_max_request_bytes": 999999
        \\    }
        \\}
    ;
    const routed_parsed = try Config.parse(std.testing.allocator, routed);
    defer routed_parsed.deinit(std.testing.allocator);
    try std.testing.expect(routed_parsed.routing.teacherConfigured());
    try std.testing.expectEqualStrings("https://teacher.example/v1", routed_parsed.routing.teacher_base_url.?);
    try std.testing.expectEqualStrings("strong-model", routed_parsed.routing.teacher_model.?);
    try std.testing.expect(routed_parsed.routing.local_only);
    try std.testing.expectEqual(router.max_request_bytes_cap, routed_parsed.routing.teacher_max_request_bytes);
}

test "invalid budget values fall back or clamp instead of failing" {
    const contents =
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": {
        \\        "temperature": 0.7,
        \\        "max_tokens": 128,
        \\        "soul_budget_bytes": -1,
        \\        "memory_budget_bytes": 1e300,
        \\        "owner_budget_bytes": 0
        \\    }
        \\}
    ;

    const config = try Config.parse(std.testing.allocator, contents);
    defer config.deinit(std.testing.allocator);

    // Negative falls back to the default; absurd values clamp to hard caps;
    // zero explicitly disables a section.
    try std.testing.expectEqual(owner.defaults.soul_bytes, config.soul_budget_bytes);
    try std.testing.expectEqual(owner.defaults.max_section_bytes, config.memory_budget_bytes);
    try std.testing.expectEqual(@as(usize, 0), config.owner_budget_bytes);
}

test "malformed and out-of-range config is rejected" {
    const allocator = std.testing.allocator;

    try expectParseError(allocator, "{ definitely not json");

    // Missing required "settings" object.
    try expectParseError(allocator,
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy"
        \\}
    );

    // Required fields must be present.
    try expectParseError(allocator,
        \\{
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.7, "max_tokens": 128 }
        \\}
    );

    // max_tokens must fit u32.
    try expectParseError(allocator,
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.7, "max_tokens": -1 }
        \\}
    );
    try expectParseError(allocator,
        \\{
        \\    "agent_name": "Pico",
        \\    "model": "m",
        \\    "base_url": "http://localhost/v1",
        \\    "system_prompt": "policy",
        \\    "settings": { "temperature": 0.7, "max_tokens": 4294967296 }
        \\}
    );
}

test "provider validation reports exactly what is missing without leaking values" {
    // All present: valid.
    try validateEndpointAndModel("https://api.example.com/v1", "model-x");
    try validateApiKey("super-secret-do-not-print");

    // Endpoint and model must be non-empty.
    try std.testing.expectError(error.MissingBaseUrl, validateEndpointAndModel("", "model-x"));
    try std.testing.expectError(error.MissingModel, validateEndpointAndModel("https://api.example.com/v1", ""));

    // The key must be present and non-empty; its value is never echoed.
    try std.testing.expectError(error.MissingApiKey, validateApiKey(null));
    try std.testing.expectError(error.MissingApiKey, validateApiKey(""));
}
