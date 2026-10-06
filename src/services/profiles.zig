//! Profile management.
//!
//! A profile is a named personality/context configuration stored under
//! `config/profiles/<id>/`. Profiles are the only way the dashboard can edit
//! agent identity, and they are strictly contained:
//!
//! * ids are validated (`[a-z0-9-_]{1,64}`) — never taken from the browser
//!   unvalidated, never used as an arbitrary path;
//! * file names are picked from a fixed whitelist, never passed through;
//! * every write goes through the same link-safe atomic writer used for
//!   `SOUL.md`/`MEMORY.md`, so a symlink/junction destination fails safe;
//! * activating a profile materializes `SOUL.md` and `MEMORY.md` through the
//!   owner context and refreshes it, so the change takes effect without a
//!   restart.

const std = @import("std");
const owner = @import("../owner.zig");

pub const base_dir = "config/profiles";
pub const active_path = "config/profiles/active.json";
pub const manifest_name = "profile.json";

/// Editable file keys. The browser sends these keys, never paths.
pub const FileKey = enum {
    soul,
    memory,
    instructions,
    behavior,
    custom,

    pub fn fileName(self: FileKey) []const u8 {
        return switch (self) {
            .soul => "soul.md",
            .memory => "memory.md",
            .instructions => "instructions.md",
            .behavior => "behavior.md",
            .custom => "custom.md",
        };
    }

    pub fn fromString(value: []const u8) ?FileKey {
        inline for (@typeInfo(FileKey).@"enum".fields) |field| {
            const key: FileKey = @enumFromInt(field.value);
            if (std.mem.eql(u8, value, key.fileName())) return key;
        }
        return null;
    }
};

pub const max_id_len: usize = 64;
pub const max_file_bytes: usize = 256 * 1024;

pub const Fault = error{
    OutOfMemory,
    InvalidId,
    InvalidFile,
    NotFound,
    AlreadyExists,
    ActiveProfile,
    FileTooLarge,
    Unsupported,
};

pub const ProfileInfo = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    active: bool,

    pub fn deinit(self: *ProfileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub fn freeInfos(allocator: std.mem.Allocator, infos: []ProfileInfo) void {
    for (infos) |*info| info.deinit(allocator);
    allocator.free(infos);
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |char| {
        const ok = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or char == '_';
        if (!ok) return false;
    }
    return true;
}

/// A profiles service rooted at `dir` (workspace root in production, a temp
/// dir in tests) with `base` naming the profiles directory inside it.
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    base: []const u8,
    owner_context: *owner.OwnerContext,
    active_id: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        base: []const u8,
        owner_context: *owner.OwnerContext,
    ) Service {
        var service = Service{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .base = base,
            .owner_context = owner_context,
        };
        service.loadActive();
        return service;
    }

    pub fn deinit(self: *Service) void {
        if (self.active_id) |id| self.allocator.free(id);
        self.active_id = null;
    }

    pub fn activeId(self: *const Service) ?[]const u8 {
        return self.active_id;
    }

    fn loadActive(self: *Service) void {
        var buffer: [4096]u8 = undefined;
        const path = std.fmt.allocPrint(self.allocator, "{s}/active.json", .{self.base}) catch return;
        defer self.allocator.free(path);
        const contents = self.readPath(&buffer, path) orelse return;
        const Parsed = struct { id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Parsed, self.allocator, contents, .{}) catch return;
        defer parsed.deinit();
        if (!validId(parsed.value.id)) return;
        self.active_id = self.allocator.dupe(u8, parsed.value.id) catch null;
    }

    fn ensureBase(self: *Service) !void {
        self.dir.createDirPath(self.io, self.base) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    fn profilePath(self: *Service, id: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.base, id, name });
    }

    /// Read a file under `dir` into a caller buffer; null when unreadable.
    /// Used for small manifests only — profile content has its own API.
    fn readPath(self: *Service, buffer: []u8, rel: []const u8) ?[]const u8 {
        var file = self.dir.openFile(self.io, rel, .{}) catch return null;
        defer file.close(self.io);
        const buffers = [_][]u8{buffer};
        const size = file.readPositional(self.io, &buffers, 0) catch return null;
        return buffer[0..size];
    }

    pub fn exists(self: *Service, id: []const u8) bool {
        if (!validId(id)) return false;
        const path = self.profilePath(id, manifest_name) catch return false;
        defer self.allocator.free(path);
        var file = self.dir.openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    /// Create a profile with template files. All writes go through the
    /// link-safe atomic writer.
    pub fn create(self: *Service, id: []const u8, name: []const u8, description: []const u8) Fault!void {
        if (!validId(id)) return error.InvalidId;
        if (self.exists(id)) return error.AlreadyExists;
        self.ensureBase() catch return error.Unsupported;

        const dir_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base, id }) catch return error.OutOfMemory;
        defer self.allocator.free(dir_path);
        self.dir.createDirPath(self.io, dir_path) catch return error.Unsupported;

        try self.writeManifest(id, name, description);
        const keys = [_]FileKey{ .soul, .memory, .instructions, .behavior, .custom };
        for (keys) |key| {
            const template = templateFor(key, name);
            self.writeFile(id, key, template) catch return error.Unsupported;
        }
    }

    /// Duplicate an existing profile under a new id/name.
    pub fn duplicate(self: *Service, source: []const u8, id: []const u8, name: []const u8) Fault!void {
        if (!validId(id)) return error.InvalidId;
        if (!validId(source)) return error.InvalidId;
        if (!self.exists(source)) return error.NotFound;
        if (self.exists(id)) return error.AlreadyExists;
        try self.create(id, name, "");
        const keys = [_]FileKey{ .soul, .memory, .instructions, .behavior, .custom };
        for (keys) |key| {
            const content = self.readFileAlloc(source, key) catch continue;
            defer self.allocator.free(content);
            self.writeFile(id, key, content) catch return error.Unsupported;
        }
    }

    /// Delete a profile. The active profile is protected so identity never
    /// disappears silently.
    pub fn delete(self: *Service, id: []const u8) Fault!void {
        if (!validId(id)) return error.InvalidId;
        if (!self.exists(id)) return error.NotFound;
        if (self.active_id) |active| {
            if (std.mem.eql(u8, active, id)) return error.ActiveProfile;
        }
        const dir_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base, id }) catch return error.OutOfMemory;
        defer self.allocator.free(dir_path);
        self.dir.deleteTree(self.io, dir_path) catch return error.Unsupported;
    }

    /// Read one whitelisted file of a profile. Caller owns the result.
    pub fn readFileAlloc(self: *Service, id: []const u8, key: FileKey) Fault![]u8 {
        if (!validId(id)) return error.InvalidId;
        const path = self.profilePath(id, key.fileName()) catch return error.OutOfMemory;
        defer self.allocator.free(path);

        var file = self.dir.openFile(self.io, path, .{}) catch return error.NotFound;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.Unsupported;
        if (length > max_file_bytes) return error.FileTooLarge;

        const buffer = self.allocator.alloc(u8, @intCast(length)) catch return error.OutOfMemory;
        errdefer self.allocator.free(buffer);
        const buffers = [_][]u8{buffer};
        const size = file.readPositional(self.io, &buffers, 0) catch return error.Unsupported;
        return self.allocator.realloc(buffer, size) catch buffer[0..size];
    }

    /// Replace one whitelisted file atomically (symlink-safe).
    pub fn writeFile(self: *Service, id: []const u8, key: FileKey, content: []const u8) Fault!void {
        if (!validId(id)) return error.InvalidId;
        if (content.len > max_file_bytes) return error.FileTooLarge;
        const path = self.profilePath(id, key.fileName()) catch return error.OutOfMemory;
        defer self.allocator.free(path);
        owner.writeMemoryAtomic(self.io, self.dir, path, content) catch return error.Unsupported;
    }

    /// Activate a profile: materialize SOUL.md/MEMORY.md through the owner
    /// context and refresh it, then persist the active id.
    pub fn activate(self: *Service, id: []const u8) Fault!void {
        if (!validId(id)) return error.InvalidId;
        if (!self.exists(id)) return error.NotFound;

        const soul = try self.readFileAlloc(id, .soul);
        defer self.allocator.free(soul);
        const memory = self.readFileAlloc(id, .memory) catch null;
        defer if (memory) |value| self.allocator.free(value);

        self.owner_context.saveSoul(soul) catch return error.Unsupported;
        if (memory) |value| {
            self.owner_context.saveMemory(value) catch return error.Unsupported;
        }
        self.owner_context.reload();

        const owned = self.allocator.dupe(u8, id) catch return error.OutOfMemory;
        if (self.active_id) |previous| self.allocator.free(previous);
        self.active_id = owned;

        const path = std.fmt.allocPrint(self.allocator, "{s}/active.json", .{self.base}) catch return error.OutOfMemory;
        defer self.allocator.free(path);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        output.writer.print("{{\"id\":", .{}) catch return error.OutOfMemory;
        std.json.Stringify.value(id, .{}, &output.writer) catch return error.OutOfMemory;
        output.writer.writeAll("}") catch return error.OutOfMemory;
        owner.writeMemoryAtomic(self.io, self.dir, path, output.written()) catch return error.Unsupported;
    }

    /// List profiles from the manifest files on disk. Missing or malformed
    /// manifests are skipped rather than failing the listing.
    pub fn list(self: *Service) Fault![]ProfileInfo {
        var infos: std.ArrayList(ProfileInfo) = .empty;
        errdefer {
            for (infos.items) |*info| info.deinit(self.allocator);
            infos.deinit(self.allocator);
        }

        var profiles_dir = self.dir.openDir(self.io, self.base, .{ .iterate = true }) catch
            return self.allocator.alloc(ProfileInfo, 0); // no profiles dir yet: empty inventory
        defer profiles_dir.close(self.io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        var iterator = profiles_dir.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = self.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            names.append(self.allocator, name) catch return error.OutOfMemory;
        }

        for (names.items) |name| {
            if (!validId(name)) continue;
            const manifest = self.readManifest(name) catch continue;
            const id_copy = self.allocator.dupe(u8, name) catch continue;
            infos.append(self.allocator, .{
                .id = id_copy,
                .name = manifest.name,
                .description = manifest.description,
                .active = if (self.active_id) |active| std.mem.eql(u8, active, name) else false,
            }) catch continue;
        }

        return infos.toOwnedSlice(self.allocator);
    }

    const Manifest = struct { name: []u8, description: []u8 };

    fn readManifest(self: *Service, id: []const u8) !Manifest {
        const path = try self.profilePath(id, manifest_name);
        defer self.allocator.free(path);
        var file = try self.dir.openFile(self.io, path, .{});
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        const buffers = [_][]u8{buffer[0..]};
        const size = try file.readPositional(self.io, &buffers, 0);

        const Parsed = struct {
            name: []const u8 = "",
            description: []const u8 = "",
        };
        const parsed = try std.json.parseFromSlice(Parsed, self.allocator, buffer[0..size], .{});
        defer parsed.deinit();
        return .{
            .name = try self.allocator.dupe(u8, parsed.value.name),
            .description = try self.allocator.dupe(u8, parsed.value.description),
        };
    }

    fn writeManifest(self: *Service, id: []const u8, name: []const u8, description: []const u8) Fault!void {
        const path = self.profilePath(id, manifest_name) catch return error.OutOfMemory;
        defer self.allocator.free(path);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        writer.writeAll("{\"name\":") catch return error.OutOfMemory;
        std.json.Stringify.value(name, .{}, writer) catch return error.OutOfMemory;
        writer.writeAll(",\"description\":") catch return error.OutOfMemory;
        std.json.Stringify.value(description, .{}, writer) catch return error.OutOfMemory;
        writer.writeAll("}") catch return error.OutOfMemory;
        owner.writeMemoryAtomic(self.io, self.dir, path, output.written()) catch return error.Unsupported;
    }
};

fn templateFor(key: FileKey, name: []const u8) []const u8 {
    _ = name;
    return switch (key) {
        .soul => "# Soul\n\nIdentity and character for this profile.\n",
        .memory => "# Memory\n\nDurable owner notes for this profile.\n",
        .instructions => "# System instructions\n\nOperational instructions for this profile.\n",
        .behavior => "# Behavior and style\n\nTone and interaction preferences.\n",
        .custom => "# Custom instructions\n\nFree-form notes. Treated as untrusted context data.\n",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    owner_context: owner.OwnerContext,
    service: Service,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const io = testing.io;
        self.owner_context = try owner.OwnerContext.initAt(
            testing.allocator,
            io,
            self.tmp.dir,
            "SOUL.md",
            "MEMORY.md",
            .{},
        );
        errdefer self.owner_context.deinit();
        self.service = Service.init(testing.allocator, io, self.tmp.dir, "profiles", &self.owner_context);
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.service.deinit();
        self.owner_context.deinit();
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }
};

test "profile ids are strictly validated before any filesystem use" {
    try testing.expect(validId("work"));
    try testing.expect(validId("work-2_a"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("../evil"));
    try testing.expect(!validId(".."));
    try testing.expect(!validId("Has Upper"));
    try testing.expect(!validId("a/b"));
    try testing.expect(!validId("x" ** (max_id_len + 1)));
    try testing.expect(FileKey.fromString("soul.md") != null);
    try testing.expect(FileKey.fromString("../../etc/passwd") == null);
    try testing.expect(FileKey.fromString("profile.json") == null);
}

test "create list duplicate and delete a profile" {
    var fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.service.create("work", "Work", "Day job");
    try testing.expectError(error.AlreadyExists, fixture.service.create("work", "Work", ""));
    try testing.expectError(error.InvalidId, fixture.service.create("bad id", "x", ""));

    const infos = try fixture.service.list();
    defer freeInfos(testing.allocator, infos);
    try testing.expectEqual(@as(usize, 1), infos.len);
    try testing.expectEqualStrings("work", infos[0].id);
    try testing.expectEqualStrings("Work", infos[0].name);
    try testing.expect(!infos[0].active);

    try fixture.service.duplicate("work", "personal", "Personal");
    const after_dup = try fixture.service.list();
    defer freeInfos(testing.allocator, after_dup);
    try testing.expectEqual(@as(usize, 2), after_dup.len);

    // The duplicate carries the source content.
    const soul = try fixture.service.readFileAlloc("personal", .soul);
    defer testing.allocator.free(soul);
    try testing.expect(std.mem.indexOf(u8, soul, "Soul") != null);

    try fixture.service.delete("work");
    try testing.expectError(error.NotFound, fixture.service.delete("work"));
}

test "file writes are contained to the profile directory" {
    var fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.service.create("p1", "P1", "");
    try fixture.service.writeFile("p1", .custom, "custom content");
    const content = try fixture.service.readFileAlloc("p1", .custom);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("custom content", content);

    // Unknown profile: refused without creating anything.
    try testing.expectError(error.InvalidId, fixture.service.writeFile("../outside", .soul, "nope"));
    try testing.expectError(error.NotFound, fixture.service.readFileAlloc("ghost", .soul));
}

test "activate materializes owner files and persists the active id" {
    var fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.service.create("identity", "Identity", "");
    try fixture.service.writeFile("identity", .soul, "# Soul: curious, precise");
    try fixture.service.writeFile("identity", .memory, "# Memory: likes tea");

    try fixture.service.activate("identity");
    try testing.expectEqualStrings("identity", fixture.service.activeId().?);

    // The owner context now renders the profile content.
    const soul = try fixture.owner_context.renderSoul(testing.allocator);
    defer if (soul) |value| testing.allocator.free(value);
    try testing.expect(soul != null);
    try testing.expect(std.mem.indexOf(u8, soul.?, "curious, precise") != null);

    // A fresh service (e.g. after restart) restores the same active id.
    var reloaded = Service.init(testing.allocator, testing.io, fixture.tmp.dir, "profiles", &fixture.owner_context);
    defer reloaded.deinit();
    try testing.expectEqualStrings("identity", reloaded.activeId().?);

    // The active profile is protected against deletion.
    try testing.expectError(error.ActiveProfile, fixture.service.delete("identity"));
}
