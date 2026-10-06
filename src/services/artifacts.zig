//! Artifact generation: real files, real metadata, honest capabilities.
//!
//! An artifact is a file the runtime produced on purpose, stored inside the
//! sandbox workspace under `artifacts/<id>/`, with identity (id, filename),
//! integrity (size, SHA-256), provenance (generator, optional job id), and a
//! validation state.
//!
//! Format support is capability-honest. This runtime has safe native
//! backends for text-family formats and ZIP; office and PDF formats are
//! reported as UNSUPPORTED instead of being faked by a mislabeled file.
//! `supported()` below is the single source of truth, and the capability
//! manifest renders directly from it.

const std = @import("std");
const sandbox_mod = @import("../runtime/sandbox.zig");
const archives_mod = @import("../runtime/archives.zig");
const attachments = @import("../runtime/attachments.zig");

pub const max_artifact_bytes: usize = 32 * 1024 * 1024;
pub const max_count: usize = 256;

pub const Kind = enum {
    txt,
    md,
    json,
    csv,
    zip,
    pdf,
    docx,
    pptx,
    xlsx,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    /// True only when a real, tested backend exists in this runtime.
    pub fn supported(self: Kind) bool {
        return switch (self) {
            .txt, .md, .json, .csv, .zip => true,
            .pdf, .docx, .pptx, .xlsx => false,
        };
    }

    /// The mime type of a produced file (used for downloads only).
    pub fn mime(self: Kind) []const u8 {
        return switch (self) {
            .txt => "text/plain",
            .md => "text/markdown",
            .json => "application/json",
            .csv => "text/csv",
            .zip => "application/zip",
            .pdf => "application/pdf",
            .docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            .pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            .xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        };
    }
};

pub const Artifact = struct {
    id: []u8,
    filename: []u8,
    kind: Kind,
    size: usize,
    sha256_hex: []u8,
    path: []u8,
    created_ms: i64,
    generator: []const u8 = "native",
    job_id: ?[]u8 = null,
    validated: bool = false,
};

pub const CreateError = error{
    /// The requested format has no real backend in this runtime.
    UnsupportedKind,
    /// The client-provided filename is not usable.
    InvalidFilename,
    /// Content failed format validation (e.g. invalid JSON).
    InvalidContent,
    /// Content exceeds the artifact size ceiling.
    TooLarge,
    /// The id/name could not be materialized inside the sandbox.
    WriteFailed,
    SymLinkRefused,
    PathDenied,
    OutOfMemory,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    sb: *const sandbox_mod.Sandbox,
    entries: std.ArrayList(Artifact) = .empty,
    counter: usize = 0,
    max_bytes: usize = max_artifact_bytes,

    pub fn init(allocator: std.mem.Allocator, sb: *const sandbox_mod.Sandbox) Store {
        return .{ .allocator = allocator, .sb = sb };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| self.destroyEntry(&entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    pub fn find(self: *Store, id: []const u8) ?*Artifact {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    /// Create a text-family artifact from real content. The format is
    /// validated before anything is written: invalid JSON never becomes a
    /// "json" artifact.
    pub fn createText(
        self: *Store,
        kind: Kind,
        filename: []const u8,
        content: []const u8,
    ) CreateError!*Artifact {
        if (!kind.supported()) return error.UnsupportedKind;
        switch (kind) {
            .json => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                _ = std.json.parseFromSliceLeaky(
                    std.json.Value,
                    arena.allocator(),
                    content,
                    .{},
                ) catch return error.InvalidContent;
            },
            .txt, .md, .csv => {
                if (content.len == 0) return error.InvalidContent;
                if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidContent;
            },
            else => return error.UnsupportedKind,
        }
        return self.store(kind, filename, content, "text-writer");
    }

    /// Create a ZIP artifact from workspace sources using the sandbox zip
    /// writer (real archive, verified after writing).
    pub fn createZip(
        self: *Store,
        filename: []const u8,
        sources: []const []const u8,
    ) CreateError!*Artifact {
        if (sources.len == 0) return error.InvalidContent;
        const safe = attachments.safeNameOf(filename) catch return error.InvalidFilename;

        self.counter += 1;
        var id_buf: [64]u8 = undefined;
        const id_text = std.fmt.bufPrint(
            &id_buf,
            "art-{d}-{d}",
            .{ wallClockMs(self.sb.io), self.counter },
        ) catch return error.WriteFailed;
        const id = try self.allocator.dupe(u8, id_text);
        errdefer self.allocator.free(id);

        const path = std.fmt.allocPrint(self.allocator, "artifacts/{s}/{s}", .{ id, safe }) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(path);

        var archives = archives_mod.Archives.init(self.sb);
        _ = archives.zipCreate(self.allocator, path, sources) catch |err| return mapWriteError(err);
        return self.finish(id, safe, .zip, path, "zip-archiver");
    }

    fn store(
        self: *Store,
        kind: Kind,
        filename: []const u8,
        content: []const u8,
        generator: []const u8,
    ) CreateError!*Artifact {
        if (content.len > self.max_bytes) return error.TooLarge;
        if (self.entries.items.len >= max_count) return error.TooLarge;
        const safe = attachments.safeNameOf(filename) catch return error.InvalidFilename;

        self.counter += 1;
        var id_buf: [64]u8 = undefined;
        const id_text = std.fmt.bufPrint(
            &id_buf,
            "art-{d}-{d}",
            .{ wallClockMs(self.sb.io), self.counter },
        ) catch return error.WriteFailed;
        const id = try self.allocator.dupe(u8, id_text);
        errdefer self.allocator.free(id);

        const path = std.fmt.allocPrint(self.allocator, "artifacts/{s}/{s}", .{ id, safe }) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(path);

        self.sb.checkWrite(path) catch |err| return mapWriteError(err);
        var opened = self.sb.walkToCreate(path) catch |err| return mapWriteError(err);
        defer self.sb.closeOpened(&opened);
        var file = opened.parent_dirs[opened.parent_dirs.len - 1].createFile(
            self.sb.io,
            opened.basename,
            .{ .resolve_beneath = true },
        ) catch |err| return mapWriteError(err);
        file.writeStreamingAll(self.sb.io, content) catch {
            file.close(self.sb.io);
            return error.WriteFailed;
        };
        file.close(self.sb.io);

        return self.finish(id, safe, kind, path, generator);
    }

    /// Read back what was written, compute the hash, and register the record.
    /// An artifact only exists once its content is verifiably on disk.
    fn finish(
        self: *Store,
        id: []u8,
        safe: []const u8,
        kind: Kind,
        path: []u8,
        generator: []const u8,
    ) CreateError!*Artifact {
        errdefer self.allocator.free(id);
        errdefer self.allocator.free(path);

        const data = self.sb.root.readFileAlloc(
            self.sb.io,
            path,
            self.allocator,
            .limited(self.max_bytes + 1),
        ) catch return error.WriteFailed;
        defer self.allocator.free(data);
        if (data.len == 0) return error.InvalidContent;

        const digest = attachments.sha256Hex(self.allocator, data) catch return error.OutOfMemory;
        errdefer self.allocator.free(digest);
        const filename_copy = self.allocator.dupe(u8, safe) catch return error.OutOfMemory;
        errdefer self.allocator.free(filename_copy);

        const record = Artifact{
            .id = id,
            .filename = filename_copy,
            .kind = kind,
            .size = data.len,
            .sha256_hex = digest,
            .path = path,
            .created_ms = wallClockMs(self.sb.io),
            .generator = generator,
            .validated = true,
        };
        self.writeMeta(&record) catch {};
        self.entries.append(self.allocator, record) catch return error.OutOfMemory;
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Read artifact content for download (bounded by the recorded size).
    pub fn readContent(self: *Store, id: []const u8) ![]u8 {
        const record = self.find(id) orelse return error.NotFound;
        return self.sb.root.readFileAlloc(
            self.sb.io,
            record.path,
            self.allocator,
            .limited(self.max_bytes),
        );
    }

    /// Delete an artifact and its directory.
    pub fn delete(self: *Store, id: []const u8) bool {
        for (self.entries.items, 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.id, id)) {
                var dir_buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&dir_buf, "artifacts/{s}", .{entry.id})) |dir_path| {
                    self.sb.root.deleteTree(self.sb.io, dir_path) catch {};
                } else |_| {}
                self.destroyEntry(entry);
                _ = self.entries.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Persist metadata next to the artifact (restart-survivable records).
    fn writeMeta(self: *Store, record: *const Artifact) !void {
        var meta_path_buf: [160]u8 = undefined;
        const meta_path = std.fmt.bufPrint(
            &meta_path_buf,
            "artifacts/{s}/meta.json",
            .{record.id},
        ) catch return error.WriteFailed;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        try renderArtifactJson(record, &stringify);

        self.sb.checkWrite(meta_path) catch return error.WriteFailed;
        var opened = try self.sb.walkToCreate(meta_path);
        defer self.sb.closeOpened(&opened);
        var file = opened.parent_dirs[opened.parent_dirs.len - 1].createFile(
            self.sb.io,
            opened.basename,
            .{ .resolve_beneath = true },
        ) catch return error.WriteFailed;
        defer file.close(self.sb.io);
        file.writeStreamingAll(self.sb.io, out.written()) catch return error.WriteFailed;
    }

    fn destroyEntry(self: *Store, entry: *const Artifact) void {
        self.allocator.free(entry.id);
        self.allocator.free(entry.filename);
        self.allocator.free(entry.sha256_hex);
        self.allocator.free(entry.path);
        if (entry.job_id) |job| self.allocator.free(job);
    }

    pub fn writeListJson(self: *Store, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("count");
        try writer.write(self.entries.items.len);
        try writer.objectField("supported_kinds");
        try writer.beginArray();
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            const kind: Kind = @enumFromInt(field.value);
            if (kind.supported()) try writer.write(kind.name());
        }
        try writer.endArray();
        try writer.objectField("unsupported_kinds");
        try writer.beginArray();
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            const kind: Kind = @enumFromInt(field.value);
            if (!kind.supported()) try writer.write(kind.name());
        }
        try writer.endArray();
        try writer.objectField("artifacts");
        try writer.beginArray();
        for (self.entries.items) |*entry| try renderArtifactJson(entry, writer);
        try writer.endArray();
        try writer.endObject();
    }

    pub fn writeOneJson(self: *Store, id: []const u8, writer: *std.json.Stringify) !bool {
        const record = self.find(id) orelse return false;
        try renderArtifactJson(record, writer);
        return true;
    }
};

fn renderArtifactJson(record: *const Artifact, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(record.id);
    try writer.objectField("filename");
    try writer.write(record.filename);
    try writer.objectField("kind");
    try writer.write(record.kind.name());
    try writer.objectField("mime");
    try writer.write(record.kind.mime());
    try writer.objectField("size");
    try writer.write(record.size);
    try writer.objectField("sha256");
    try writer.write(record.sha256_hex);
    try writer.objectField("path");
    try writer.write(record.path);
    try writer.objectField("created_ms");
    try writer.write(record.created_ms);
    try writer.objectField("generator");
    try writer.write(record.generator);
    try writer.objectField("validated");
    try writer.write(record.validated);
    try writer.objectField("job_id");
    if (record.job_id) |job| try writer.write(job) else try writer.write(null);
    try writer.endObject();
}

fn mapWriteError(err: anyerror) CreateError {
    return switch (err) {
        error.PathDenied => error.PathDenied,
        error.SymLinkRefused => error.SymLinkRefused,
        error.OutOfMemory => error.OutOfMemory,
        else => error.WriteFailed,
    };
}

fn wallClockMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    sb: sandbox_mod.Sandbox,
    store: Store,
    root_name: []const u8,

    /// Heap-allocated: `store.sb` points back into the harness.
    fn create(allocator: std.mem.Allocator, root_name: []const u8) !*Harness {
        const io = std.testing.io;
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, root_name) catch {};
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        self.* = .{
            .sb = try sandbox_mod.Sandbox.init(io, allocator, cwd, root_name, .{
                .read = true,
                .write = true,
            }, .{}),
            .store = undefined,
            .root_name = root_name,
        };
        self.store = Store.init(allocator, &self.sb);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.store.deinit();
        self.sb.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.root_name) catch {};
        std.testing.allocator.destroy(self);
    }
};

test "text artifacts are real validated files inside the sandbox" {
    var t = try Harness.create(testing.allocator, "zig-cache-pico-art-text");
    defer t.destroy();

    const record = try t.store.createText(.md, "report.md", "# Report\n\nBody.");
    try testing.expectEqual(Kind.md, record.kind);
    try testing.expect(record.validated);
    try testing.expectEqualStrings("text-writer", record.generator);
    try testing.expect(std.mem.startsWith(u8, record.path, "artifacts/art-"));
    try testing.expectEqual(@as(usize, 15), record.size);

    const data = try t.sb.root.readFileAlloc(
        t.sb.io,
        record.path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("# Report\n\nBody.", data);

    const expected = try attachments.sha256Hex(testing.allocator, "# Report\n\nBody.");
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, record.sha256_hex);

    const content = try t.store.readContent(record.id);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# Report\n\nBody.", content);
}

test "json artifacts validate before anything is written" {
    var t = try Harness.create(testing.allocator, "zig-cache-pico-art-json");
    defer t.destroy();

    const good = try t.store.createText(.json, "data.json", "{\"ok\":true}");
    try testing.expect(good.validated);
    try testing.expectEqual(@as(usize, 1), t.store.count());

    // Invalid JSON is refused outright: no fake artifact is created.
    try testing.expectError(
        error.InvalidContent,
        t.store.createText(.json, "broken.json", "{\"ok\":"),
    );
    try testing.expectError(
        error.InvalidContent,
        t.store.createText(.txt, "empty.txt", ""),
    );
    try testing.expectEqual(@as(usize, 1), t.store.count());

    // Path containment: traversal-style filenames are rejected.
    try testing.expectError(
        error.InvalidFilename,
        t.store.createText(.txt, "../escape.txt", "nope"),
    );
    try testing.expectError(
        error.InvalidFilename,
        t.store.createText(.txt, "CON.txt", "nope"),
    );

    // Nothing escaped the workspace root into the parent directory.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(testing.io, "escape.txt", .{}),
    );
}

test "unsupported formats are reported as unsupported, never faked" {
    var t = try Harness.create(testing.allocator, "zig-cache-pico-art-unsupported");
    defer t.destroy();

    inline for (.{ Kind.pdf, Kind.docx, Kind.pptx, Kind.xlsx }) |kind| {
        try testing.expect(!kind.supported());
        var name_buf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&name_buf, "output.{s}", .{kind.name()}) catch unreachable;
        try testing.expectError(
            error.UnsupportedKind,
            t.store.createText(kind, fname, "fake bytes"),
        );
    }
    try testing.expectEqual(@as(usize, 0), t.store.count());
    try testing.expect(Kind.zip.supported());
}

test "zip artifacts are real archives built from workspace sources" {
    var t = try Harness.create(testing.allocator, "zig-cache-pico-art-zip");
    defer t.destroy();

    var fsops = @import("../runtime/fsops.zig").FsOps.init(&t.sb);
    _ = try fsops.write("project/readme.txt", "artifact source");
    _ = try fsops.write("project/main.zig", "pub fn main() void {}");

    const record = try t.store.createZip("bundle.zip", &.{ "project/readme.txt", "project/main.zig" });
    try testing.expectEqual(Kind.zip, record.kind);
    try testing.expectEqualStrings("zip-archiver", record.generator);
    try testing.expect(record.validated);

    const head = try t.sb.root.readFileAlloc(
        t.sb.io,
        record.path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(head);
    try testing.expect(std.mem.startsWith(u8, head, "PK\x03\x04"));

    var archives = archives_mod.Archives.init(&t.sb);
    const listing = try archives.zipListJson(testing.allocator, record.path);
    defer testing.allocator.free(listing);
    try testing.expect(std.mem.indexOf(u8, listing, "project/readme.txt") != null);
}

test "artifact registry JSON shapes and delete" {
    var t = try Harness.create(testing.allocator, "zig-cache-pico-art-jsonshape");
    defer t.destroy();

    const record = try t.store.createText(.txt, "out.txt", "hello artifact");
    const id = try testing.allocator.dupe(u8, record.id);
    defer testing.allocator.free(id);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try t.store.writeListJson(&stringify);
    const list = out.written();
    try testing.expect(std.mem.indexOf(u8, list, "\"supported_kinds\":[\"txt\",\"md\",\"json\",\"csv\",\"zip\"]") != null);
    try testing.expect(std.mem.indexOf(u8, list, "\"unsupported_kinds\":[\"pdf\",\"docx\",\"pptx\",\"xlsx\"]") != null);
    try testing.expect(std.mem.indexOf(u8, list, "\"filename\":\"out.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, list, "\"validated\":true") != null);

    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var one_stringify: std.json.Stringify = .{ .writer = &one.writer };
    try testing.expect(try t.store.writeOneJson(id, &one_stringify));
    try testing.expect(std.mem.indexOf(u8, one.written(), "\"mime\":\"text/plain\"") != null);
    try testing.expectEqual(false, try t.store.writeOneJson("art-ghost", &one_stringify));

    try testing.expect(t.store.delete(id));
    try testing.expectEqual(@as(usize, 0), t.store.count());
    try testing.expectError(error.NotFound, t.store.readContent(id));
    var dir_buf: [64]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "artifacts/{s}", .{id}) catch unreachable;
    try testing.expectError(error.FileNotFound, t.sb.root.statFile(
        t.sb.io,
        dir_path,
        .{ .follow_symlinks = false },
    ));
}
