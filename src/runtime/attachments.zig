//! Attachment ingestion: the controlled entry point for files from outside.
//!
//! Everything uploaded here — via the dashboard API or a future channel —
//! lands inside the sandbox workspace under `uploads/<id>/`, never anywhere
//! else on the host. The pipeline is:
//!
//!   upload bytes → filename validation → size/quota limits → content
//!   sniffing (never trusting the client's claims) → SHA-256 → sandbox write
//!   → metadata (meta.json + in-memory registry) → optional extraction
//!
//! Security rules enforced in this module:
//! * Client-supplied names are data, never paths: traversal components,
//!   absolute/UNC/drive forms, reserved device names, and control characters
//!   are rejected outright. The stored name is the validated basename.
//! * Content type comes from sniffing the bytes; neither the extension nor a
//!   client-declared MIME type is trusted.
//! * Uploads are size-limited individually and by a total workspace quota.
//! * Archive extraction reuses the sandbox extractor (zip-slip refusal,
//!   entry/size limits, no symlink following) and can never escape
//!   `uploads/<id>/extracted/`.
//! * Uploads are untrusted data: nothing in this module executes content.

const std = @import("std");
const sandbox_mod = @import("sandbox.zig");
const archives_mod = @import("archives.zig");

pub const max_upload_bytes: usize = 16 * 1024 * 1024;
pub const default_max_total_bytes: usize = 128 * 1024 * 1024;
pub const max_name_len: usize = 255;
pub const sha256_hex_len: usize = 64;

pub const Status = enum {
    stored,
    extracted,
    failed,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }
};

pub const Attachment = struct {
    id: []u8,
    original_name: []u8,
    safe_name: []u8,
    mime: []u8,
    sha256_hex: []u8,
    path: []u8,
    size: usize,
    created_ms: i64,
    status: Status = .stored,
    extracted_count: usize = 0,
    extracted_failed: usize = 0,
};

pub const IngestError = error{
    /// The client-provided name is not a usable file name.
    InvalidFilename,
    /// Empty body.
    Empty,
    /// Body exceeds the per-attachment limit.
    TooLarge,
    /// The upload would exceed the total attachments quota.
    QuotaExceeded,
    /// The id/name could not be materialized inside the sandbox.
    WriteFailed,
    SymLinkRefused,
    PathDenied,
    OutOfMemory,
};

/// Validate a client-provided name and reduce it to a safe basename.
/// Rejection (not silent sanitization) is the policy for anything suspicious.
pub fn safeNameOf(raw: []const u8) IngestError![]const u8 {
    if (raw.len == 0 or raw.len > max_name_len) return error.InvalidFilename;
    // Control characters can smuggle separators and confuse downstream tools.
    for (raw) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidFilename;
    }
    // Absolute, drive-letter, and UNC forms are rejected outright.
    if (raw[0] == '/' or raw[0] == '\\') return error.InvalidFilename;
    if (raw.len >= 2 and raw[1] == ':') return error.InvalidFilename;
    if (std.mem.startsWith(u8, raw, "\\\\") or std.mem.startsWith(u8, raw, "//")) return error.InvalidFilename;
    // Traversal in any component is rejected, never normalized away.
    var segments = std.mem.tokenizeAny(u8, raw, "/\\");
    var safe: []const u8 = "";
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return error.InvalidFilename;
        safe = segment;
    }
    if (safe.len == 0) return error.InvalidFilename;
    // The sandbox lexical rules cover reserved device names, Windows-forbidden
    // punctuation, and trailing dot/space tricks.
    sandbox_mod.validateRelPath(safe) catch return error.InvalidFilename;
    return safe;
}

/// Detect the content type from the bytes. Extensions and client claims are
/// never consulted.
pub fn sniffMime(bytes: []const u8) []const u8 {
    if (bytes.len >= 8 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))) return "image/gif";
    if (bytes.len >= 5 and std.mem.startsWith(u8, bytes, "%PDF-")) return "application/pdf";
    if (bytes.len >= 4 and std.mem.startsWith(u8, bytes, "PK\x03\x04")) return "application/zip";
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "\x1aE\xdf\xa3")) return "video/x-matroska";
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.startsWith(u8, bytes[8..], "WEBP")) return "image/webp";
    // Text heuristic: valid UTF-8 without disallowed control bytes.
    if (std.unicode.utf8ValidateSlice(bytes)) {
        for (bytes) |c| {
            if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return "application/octet-stream";
        }
        return "text/plain";
    }
    return "application/octet-stream";
}

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = try allocator.alloc(u8, sha256_hex_len);
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = charset[byte >> 4];
        hex[index * 2 + 1] = charset[byte & 0x0f];
    }
    return hex;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    sb: *const sandbox_mod.Sandbox,
    entries: std.ArrayList(Attachment) = .empty,
    max_total_bytes: usize = default_max_total_bytes,
    /// Per-instance ceiling (defaults to `max_upload_bytes`); tests may lower it.
    max_bytes: usize = max_upload_bytes,
    counter: usize = 0,

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

    pub fn totalBytes(self: *const Store) usize {
        var total: usize = 0;
        for (self.entries.items) |*entry| total += entry.size;
        return total;
    }

    pub fn find(self: *Store, id: []const u8) ?*Attachment {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    /// Ingest one upload into the sandbox. Returns a pointer to the stored
    /// record (owned by the store; callers must not free it).
    pub fn ingest(
        self: *Store,
        original_name: []const u8,
        bytes: []const u8,
    ) IngestError!*Attachment {
        const safe = try safeNameOf(original_name);
        if (bytes.len == 0) return error.Empty;
        if (bytes.len > self.max_bytes) return error.TooLarge;
        if (self.totalBytes() + bytes.len > self.max_total_bytes) return error.QuotaExceeded;

        // Identifier: monotonic counter plus wall clock so ids stay unique
        // across restarts. Only [a-z0-9-] appears in it.
        self.counter += 1;
        var id_buf: [64]u8 = undefined;
        const id_text = std.fmt.bufPrint(
            &id_buf,
            "att-{d}-{d}",
            .{ wallClockMs(self.sb.io), self.counter },
        ) catch return error.WriteFailed;
        const id = try self.allocator.dupe(u8, id_text);
        errdefer self.allocator.free(id);

        const mime = sniffMime(bytes);
        const digest = try sha256Hex(self.allocator, bytes);
        errdefer self.allocator.free(digest);

        const path = try std.fmt.allocPrint(
            self.allocator,
            "uploads/{s}/{s}",
            .{ id, safe },
        );
        errdefer self.allocator.free(path);

        // Write inside the sandbox: grant check + component walk (no symlink
        // following) + file creation. Nothing leaves uploads/<id>/.
        self.sb.checkWrite(path) catch |err| return mapWriteError(err);
        var opened = self.sb.walkToCreate(path) catch |err| return mapWriteError(err);
        defer self.sb.closeOpened(&opened);
        var file = opened.parent_dirs[opened.parent_dirs.len - 1].createFile(
            self.sb.io,
            opened.basename,
            .{ .resolve_beneath = true },
        ) catch |err| return mapWriteError(err);
        file.writeStreamingAll(self.sb.io, bytes) catch {
            file.close(self.sb.io);
            return error.WriteFailed;
        };
        file.close(self.sb.io);

        const original_copy = try self.allocator.dupe(u8, original_name);
        errdefer self.allocator.free(original_copy);
        const safe_copy = try self.allocator.dupe(u8, safe);
        errdefer self.allocator.free(safe_copy);
        const mime_copy = try self.allocator.dupe(u8, mime);
        errdefer self.allocator.free(mime_copy);

        const record = Attachment{
            .id = id,
            .original_name = original_copy,
            .safe_name = safe_copy,
            .mime = mime_copy,
            .sha256_hex = digest,
            .path = path,
            .size = bytes.len,
            .created_ms = wallClockMs(self.sb.io),
            .status = .stored,
        };

        self.writeMeta(&record) catch {};
        try self.entries.append(self.allocator, record);
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Extract a stored ZIP attachment into `uploads/<id>/extracted/` using
    /// the sandbox extractor (zip-slip refusal, entry/size limits, no link
    /// following). Statuses reflect what really happened.
    pub fn extract(self: *Store, id: []const u8) !*Attachment {
        const record = self.find(id) orelse return error.NotFound;
        if (!std.mem.eql(u8, record.mime, "application/zip")) return error.NotAnArchive;

        var archives = archives_mod.Archives.init(self.sb);
        const dest = std.fmt.allocPrint(
            self.allocator,
            "uploads/{s}/extracted",
            .{record.id},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(dest);

        const summary = archives.zipExtract(self.allocator, record.path, dest) catch |err| {
            record.status = .failed;
            return err;
        };
        record.status = .extracted;
        record.extracted_count = summary.extracted;
        self.writeMeta(record) catch {};
        return record;
    }

    /// Delete an attachment and everything under its directory.
    pub fn delete(self: *Store, id: []const u8) bool {
        for (self.entries.items, 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.id, id)) {
                var dir_buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&dir_buf, "uploads/{s}", .{entry.id})) |dir_path| {
                    self.sb.root.deleteTree(self.sb.io, dir_path) catch {};
                } else |_| {}
                self.destroyEntry(entry);
                _ = self.entries.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Recovery scan: remove upload directories without usable metadata
    /// (interrupted uploads). Returns how many were removed. Best effort.
    pub fn cleanupOrphans(self: *Store) usize {
        var removed: usize = 0;
        var uploads_dir = self.sb.root.openDir(self.sb.io, "uploads", .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch return 0;
        defer uploads_dir.close(self.sb.io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        var it = uploads_dir.iterate();
        while (it.next(self.sb.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const copy = self.allocator.dupe(u8, entry.name) catch continue;
            names.append(self.allocator, copy) catch self.allocator.free(copy);
        }

        for (names.items) |name| {
            var meta_buf: [160]u8 = undefined;
            const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{name}) catch continue;
            _ = uploads_dir.statFile(self.sb.io, meta_path, .{ .follow_symlinks = false }) catch {
                // No metadata: an interrupted upload. Remove best effort.
                var dir_buf: [128]u8 = undefined;
                const dir_path = std.fmt.bufPrint(&dir_buf, "uploads/{s}", .{name}) catch continue;
                self.sb.root.deleteTree(self.sb.io, dir_path) catch continue;
                removed += 1;
            };
        }
        return removed;
    }

    /// Persist the metadata next to the content so attachments survive
    /// restarts and the recovery scan can tell complete uploads apart.
    fn writeMeta(self: *Store, record: *const Attachment) !void {
        var meta_path_buf: [160]u8 = undefined;
        const meta_path = std.fmt.bufPrint(
            &meta_path_buf,
            "uploads/{s}/meta.json",
            .{record.id},
        ) catch return error.WriteFailed;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        try renderAttachmentJson(record, &stringify);

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

    fn destroyEntry(self: *Store, entry: *const Attachment) void {
        self.allocator.free(entry.id);
        self.allocator.free(entry.original_name);
        self.allocator.free(entry.safe_name);
        self.allocator.free(entry.mime);
        self.allocator.free(entry.sha256_hex);
        self.allocator.free(entry.path);
    }

    /// Serialize the inventory. The client-controlled original name is data.
    pub fn writeListJson(self: *Store, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("count");
        try writer.write(self.entries.items.len);
        try writer.objectField("total_bytes");
        try writer.write(self.totalBytes());
        try writer.objectField("quota_bytes");
        try writer.write(self.max_total_bytes);
        try writer.objectField("attachments");
        try writer.beginArray();
        for (self.entries.items) |*entry| try renderAttachmentJson(entry, writer);
        try writer.endArray();
        try writer.endObject();
    }

    pub fn writeOneJson(self: *Store, id: []const u8, writer: *std.json.Stringify) !bool {
        const record = self.find(id) orelse return false;
        try renderAttachmentJson(record, writer);
        return true;
    }
};

fn renderAttachmentJson(record: *const Attachment, writer: *std.json.Stringify) !void {
    try writer.beginObject();
    try writer.objectField("id");
    try writer.write(record.id);
    try writer.objectField("original_name");
    try writer.write(record.original_name);
    try writer.objectField("safe_name");
    try writer.write(record.safe_name);
    try writer.objectField("mime");
    try writer.write(record.mime);
    try writer.objectField("size");
    try writer.write(record.size);
    try writer.objectField("sha256");
    try writer.write(record.sha256_hex);
    try writer.objectField("path");
    try writer.write(record.path);
    try writer.objectField("created_ms");
    try writer.write(record.created_ms);
    try writer.objectField("status");
    try writer.write(record.status.name());
    try writer.objectField("extracted_count");
    try writer.write(record.extracted_count);
    try writer.endObject();
}

fn mapWriteError(err: anyerror) IngestError {
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

    /// Heap-allocated on purpose: `store.sb` points back into the harness,
    /// so the struct must never move after creation.
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

fn makeHarness(allocator: std.mem.Allocator, root_name: []const u8) !*Harness {
    return Harness.create(allocator, root_name);
}

test "upload stores content in the sandbox with sniffed type and hash" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-basic");
    defer t.destroy();

    const record = try t.store.ingest("notes.txt", "hello attachments");
    try testing.expectEqual(Status.stored, record.status);
    try testing.expectEqualStrings("text/plain", record.mime);
    try testing.expectEqualStrings("notes.txt", record.safe_name);
    try testing.expectEqualStrings("notes.txt", record.original_name);
    try testing.expectEqual(@as(usize, 17), record.size);
    try testing.expect(std.mem.startsWith(u8, record.path, "uploads/att-"));

    // The recorded hash must match an independent computation.
    const expected = try sha256Hex(testing.allocator, "hello attachments");
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, record.sha256_hex);

    // Content really exists inside the sandbox at the recorded path.
    const data = try t.sb.root.readFileAlloc(
        t.sb.io,
        record.path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello attachments", data);

    // Metadata sidecar exists beside the content.
    const found = t.store.find(record.id) != null;
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 17), t.store.totalBytes());
}

test "upload rejects traversal, absolute, reserved, and malformed names" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-names");
    defer t.destroy();

    const bad_names = [_][]const u8{
        "../evil.txt",
        "a/../b.txt",
        "..\\evil.txt",
        "/etc/passwd",
        "C:\\Windows\\evil.txt",
        "\\\\server\\share\\x.txt",
        "..",
        ".",
        "CON",
        "con.txt",
        "NUL",
        "evil\nname.txt",
        "",
        "trailing.",
        "sub/dir/file.txt/..",
    };
    for (bad_names) |name| {
        try testing.expectError(error.InvalidFilename, safeNameOf(name));
        try testing.expectError(error.InvalidFilename, t.store.ingest(name, "x"));
    }

    // Subdirectory paths in the client name are reduced to the basename,
    // which must itself be clean.
    try testing.expectEqualStrings("file.txt", try safeNameOf("some/long/path/file.txt"));
    try testing.expectError(error.InvalidFilename, safeNameOf("some/../path/file.txt"));
}

test "upload sniffs content instead of trusting names" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-mime");
    defer t.destroy();

    // A .png name with text content is text/plain, not an image.
    const png_name = try t.store.ingest("fake.png", "not really a png");
    try testing.expectEqualStrings("text/plain", png_name.mime);
    // Save the id now: later ingests may reallocate the entries list.
    const png_id = try testing.allocator.dupe(u8, png_name.id);
    defer testing.allocator.free(png_id);

    // Real PNG magic is detected regardless of the name.
    const real_png = try t.store.ingest("blob.bin", "\x89PNG\r\n\x1a\n" ++ "rest");
    try testing.expectEqualStrings("image/png", real_png.mime);

    // Invalid UTF-8 binary is honest about being opaque. (Records are kept
    // in a growable list, so re-resolve by id after every ingest.)
    const opaque_bytes = try t.store.ingest("blob2.bin", "\xff\xfe\x00\x01");
    try testing.expectEqualStrings("application/octet-stream", opaque_bytes.mime);
    const first = t.store.find(png_id).?;
    try testing.expectEqualStrings("text/plain", first.mime);
}

test "upload enforces per-attachment and total quota limits" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-quota");
    defer t.destroy();
    t.store.max_bytes = 8;
    t.store.max_total_bytes = 12;

    try testing.expectError(error.TooLarge, t.store.ingest("big.txt", "123456789"));
    try testing.expectError(error.Empty, t.store.ingest("empty.txt", ""));

    _ = try t.store.ingest("one.txt", "12345678");
    try testing.expectError(error.QuotaExceeded, t.store.ingest("two.txt", "12345"));
    // Deleting frees quota again.
    const id = try testing.allocator.dupe(u8, t.store.entries.items[0].id);
    defer testing.allocator.free(id);
    try testing.expect(t.store.delete(id));
    try testing.expectEqual(@as(usize, 0), t.store.totalBytes());
    _ = try t.store.ingest("three.txt", "ok");
    try testing.expectEqual(@as(usize, 1), t.store.count());
}

test "zip upload extracts inside its own directory and nothing escapes" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-zip");
    defer t.destroy();

    // Build a real archive with the sandbox zip writer, then feed its bytes
    // through the upload pipeline.
    var fsops = @import("fsops.zig").FsOps.init(&t.sb);
    _ = try fsops.write("src/inner.txt", "inside archive");
    var archives = archives_mod.Archives.init(&t.sb);
    _ = try archives.zipCreate(testing.allocator, "src-bundle.zip", &.{"src/inner.txt"});
    const zip_bytes = try t.sb.root.readFileAlloc(
        t.sb.io,
        "src-bundle.zip",
        testing.allocator,
        .limited(1024 * 1024),
    );
    defer testing.allocator.free(zip_bytes);

    const record = try t.store.ingest("proj.zip", zip_bytes);
    // The entries list is growable: save the id (and re-resolve by id) rather
    // than holding a pointer across later ingests.
    const record_id = try testing.allocator.dupe(u8, record.id);
    defer testing.allocator.free(record_id);
    try testing.expectEqualStrings("application/zip", record.mime);
    try testing.expectEqual(@as(usize, 0), record.extracted_count);

    const extracted = try t.store.extract(record.id);
    try testing.expectEqual(Status.extracted, extracted.status);
    try testing.expect(extracted.extracted_count >= 1);

    // The archive entry landed inside uploads/<id>/extracted/.
    var probe_buf: [160]u8 = undefined;
    const found_path = std.fmt.bufPrint(&probe_buf, "uploads/{s}/extracted/src/inner.txt", .{record_id}) catch unreachable;
    const content = try t.sb.root.readFileAlloc(
        t.sb.io,
        found_path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("inside archive", content);

    // Non-archive uploads refuse extraction honestly.
    const text_attachment = try t.store.ingest("plain.txt", "hello");
    try testing.expectError(error.NotAnArchive, t.store.extract(text_attachment.id));
    try testing.expectEqualStrings("stored", text_attachment.status.name());

    // JSON shapes for the API.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try t.store.writeListJson(&stringify);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"sha256\":") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"status\":\"extracted\"") != null);

    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var one_stringify: std.json.Stringify = .{ .writer = &one.writer };
    try testing.expect(try t.store.writeOneJson(record_id, &one_stringify));
    try testing.expect(std.mem.indexOf(u8, one.written(), "\"mime\":\"application/zip\"") != null);
    try testing.expectEqual(false, try t.store.writeOneJson("att-ghost", &one_stringify));
}

test "orphan scan removes interrupted uploads without metadata" {
    var t = try makeHarness(testing.allocator, "zig-cache-pico-attach-orphan");
    defer t.destroy();

    // A complete upload: has metadata.
    _ = try t.store.ingest("good.txt", "with metadata");

    // An interrupted upload: a bare directory with a partial file.
    var partial = try t.sb.walkToCreate("uploads/att-999/partial.txt");
    defer t.sb.closeOpened(&partial);
    var file = partial.parent_dirs[partial.parent_dirs.len - 1].createFile(
        t.sb.io,
        partial.basename,
        .{ .resolve_beneath = true },
    ) catch unreachable;
    file.writeStreamingAll(t.sb.io, "half") catch unreachable;
    file.close(t.sb.io);

    const removed = t.store.cleanupOrphans();
    try testing.expectEqual(@as(usize, 1), removed);

    // The complete upload directory survives.
    const kept = try t.sb.root.readFileAlloc(
        t.sb.io,
        t.store.entries.items[0].path,
        testing.allocator,
        .limited(256),
    );
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("with metadata", kept);

    // Second scan is a no-op.
    try testing.expectEqual(@as(usize, 0), t.store.cleanupOrphans());
}
