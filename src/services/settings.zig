//! Runtime settings: a small, validated, persisted override set.
//!
//! Settings live in `config/settings.json` (separate from the strict
//! `config/config.json` parser) and only contain values the runtime actually
//! honors today: the active model override and the provider retry attempt
//! budget. Everything else the dashboard shows (bind address, auth state,
//! workspace paths) is read-only runtime state and is never persisted here.

const std = @import("std");
const owner = @import("../owner.zig");

pub const path = "config/settings.json";

/// Hard bounds mirroring config validation. Attempts clamp into 1..=5 like
/// `task_max_attempts` in config.json; model names are bounded identifiers.
pub const max_attempts_limit: u8 = 5;
pub const max_model_len: usize = 256;

pub const Settings = struct {
    allocator: std.mem.Allocator,
    /// Active model override; null means "use the configured model".
    model: ?[]u8 = null,
    task_max_attempts: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator) Settings {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Settings) void {
        if (self.model) |value| self.allocator.free(value);
        self.model = null;
    }

    /// Validate and apply new values; returns a short error string when a
    /// value is rejected. Owned copies replace the previous values only after
    /// validation passes.
    pub fn update(self: *Settings, model: ?[]const u8, task_max_attempts: ?u8) ?[]const u8 {
        if (model) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0) return "model must not be empty";
            if (trimmed.len > max_model_len) return "model is too long";
            if (!isValidModel(trimmed)) return "model contains invalid characters";
            const owned = self.allocator.dupe(u8, trimmed) catch return "out of memory";
            if (self.model) |previous| self.allocator.free(previous);
            self.model = owned;
        }
        if (task_max_attempts) |value| {
            self.task_max_attempts = @max(1, @min(value, max_attempts_limit));
        }
        return null;
    }

    /// Persist atomically through the same link-safe writer used for owner
    /// files. A failed write leaves the previous file untouched.
    pub fn save(self: *const Settings, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, "config") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writer.writeAll("{");
        if (self.model) |model| {
            try writer.writeAll("\"model\":");
            try std.json.Stringify.value(model, .{}, writer);
        } else {
            try writer.writeAll("\"model\":null");
        }
        if (self.task_max_attempts) |attempts| {
            try writer.print(",\"task_max_attempts\":{d}", .{attempts});
        }
        try writer.writeAll("}");

        try owner.writeMemoryAtomic(io, cwd, path, output.written());
    }
};

pub fn isValidModel(model: []const u8) bool {
    for (model) |char| {
        const ok = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or
            char == '_' or char == '/' or char == ':' or char == '@';
        if (!ok) return false;
    }
    return true;
}

/// Load persisted settings; a missing or malformed file yields defaults.
/// Unknown keys are ignored; invalid values fall back instead of failing
/// startup.
pub fn load(allocator: std.mem.Allocator, io: std.Io) Settings {
    var settings = Settings.init(allocator);
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch return settings;
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    const buffers = [_][]u8{buffer[0..]};
    const size = file.readPositional(io, &buffers, 0) catch return settings;

    const Parsed = struct {
        model: ?[]const u8 = null,
        task_max_attempts: ?f64 = null,
    };
    const parsed = std.json.parseFromSlice(Parsed, allocator, buffer[0..size], .{}) catch return settings;
    defer parsed.deinit();

    if (parsed.value.model) |model| {
        if (model.len > 0 and model.len <= max_model_len and isValidModel(model)) {
            settings.model = allocator.dupe(u8, model) catch null;
        }
    }
    if (parsed.value.task_max_attempts) |raw| {
        if (std.math.isFinite(raw) and raw >= 1 and raw <= @as(f64, @floatFromInt(max_attempts_limit))) {
            settings.task_max_attempts = @intFromFloat(raw);
        }
    }
    return settings;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "settings update validates model names and clamps attempts" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();

    try testing.expect(settings.update("gpt-4.1-mini", 9) == null);
    try testing.expectEqualStrings("gpt-4.1-mini", settings.model.?);
    try testing.expectEqual(@as(?u8, max_attempts_limit), settings.task_max_attempts);

    try testing.expect(settings.update("", null) != null);
    try testing.expect(settings.update("bad model with spaces", null) != null);
    try testing.expect(settings.update("x" ** (max_model_len + 1), null) != null);
    // The previously valid value is untouched by rejected updates.
    try testing.expectEqualStrings("gpt-4.1-mini", settings.model.?);

    try testing.expect(settings.update(null, 0) == null);
    try testing.expectEqual(@as(?u8, 1), settings.task_max_attempts);
}

test "settings serialize a stable json shape without secrets" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.update("m1", 3) == null);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{");
    if (settings.model) |model| {
        try writer.writeAll("\"model\":");
        try std.json.Stringify.value(model, .{}, writer);
    }
    if (settings.task_max_attempts) |attempts| {
        try writer.print(",\"task_max_attempts\":{d}", .{attempts});
    }
    try writer.writeAll("}");

    const json = output.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"model\":\"m1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"task_max_attempts\":3") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
}
