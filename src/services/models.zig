//! Model catalog: dynamic provider model discovery with a bounded cache.
//!
//! Discovery goes through `Provider.listModels` (OpenAI-compatible
//! `GET /models`); nothing here hardcodes model names. The catalog keeps the
//! last successful normalized listing, the fetch timestamp, and the last error
//! name so the UI can show loading/error/freshness states.

const std = @import("std");
const provider_mod = @import("../provider.zig");
const task_mod = @import("../core/task.zig");
const Provider = provider_mod.Provider;
const ModelRecord = provider_mod.ModelRecord;

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *Provider,
    models: []ModelRecord = &.{},
    fetched_at_ms: i64 = 0,
    loaded: bool = false,
    last_error: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, provider: *Provider) Catalog {
        return .{ .allocator = allocator, .io = io, .provider = provider };
    }

    pub fn deinit(self: *Catalog) void {
        self.clearModels();
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = null;
    }

    fn clearModels(self: *Catalog) void {
        for (self.models) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.display_name);
            if (model.owner) |owner| self.allocator.free(owner);
        }
        self.allocator.free(self.models);
        self.models = &.{};
    }

    pub fn count(self: *const Catalog) usize {
        return self.models.len;
    }

    pub fn fresh(self: *const Catalog) bool {
        return self.loaded and self.last_error == null;
    }

    fn setError(self: *Catalog, name: []const u8) void {
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = self.allocator.dupe(u8, name[0..@min(name.len, 64)]) catch null;
    }

    /// Replace the cache with a fresh provider listing. On failure the
    /// previous models are kept and the error name is recorded.
    pub fn refresh(self: *Catalog) !usize {
        var result = provider_mod.listModels(self.provider) catch |err| {
            self.setError(@errorName(err));
            return err;
        };
        defer result.deinit(self.allocator);

        self.clearModels();
        self.models = result.models;
        result.models = &.{};
        self.fetched_at_ms = task_mod.wallClockMs(self.io);
        self.loaded = true;
        self.setErrorClean();
        return self.models.len;
    }

    fn setErrorClean(self: *Catalog) void {
        if (self.last_error) |value| self.allocator.free(value);
        self.last_error = null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "catalog starts empty and unfresh" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    var provider = Provider.init(testing.allocator, testing.io, &env_map, .{
        .agent_name = "t",
        .model = "m",
        .base_url = "http://127.0.0.1:1/v1",
        .system_prompt = "p",
        .temperature = 0.0,
        .max_tokens = 1,
        .soul_path = "SOUL.md",
        .memory_path = "MEMORY.md",
        .soul_budget_bytes = 0,
        .memory_budget_bytes = 0,
        .owner_budget_bytes = 0,
    });

    var catalog = Catalog.init(testing.allocator, testing.io, &provider);
    defer catalog.deinit();

    try testing.expectEqual(@as(usize, 0), catalog.count());
    try testing.expect(!catalog.fresh());
    try testing.expect(catalog.last_error == null);
}

test "catalog records a bounded error name when the provider is unreachable" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    var provider = Provider.init(testing.allocator, testing.io, &env_map, .{
        .agent_name = "t",
        .model = "m",
        .base_url = "http://127.0.0.1:1/v1",
        .system_prompt = "p",
        .temperature = 0.0,
        .max_tokens = 1,
        .soul_path = "SOUL.md",
        .memory_path = "MEMORY.md",
        .soul_budget_bytes = 0,
        .memory_budget_bytes = 0,
        .owner_budget_bytes = 0,
    });

    var catalog = Catalog.init(testing.allocator, testing.io, &provider);
    defer catalog.deinit();

    // No API key configured: discovery fails without any network access.
    try testing.expectError(error.ApiKeyNotFound, catalog.refresh());
    try testing.expectEqualStrings("ApiKeyNotFound", catalog.last_error.?);
    try testing.expectEqual(@as(usize, 0), catalog.count());
    try testing.expect(!catalog.fresh());
}
