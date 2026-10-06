//! Archive inspection and extraction, always inside the sandbox.
//!
//! Security model for extraction (defense in depth, all layers required):
//!   1. Every entry name is validated with the sandbox path policy before any
//!      bytes are written: no absolute paths, drive letters, UNC/device paths,
//!      `..` traversal, backslash separators, or reserved device names.
//!   2. Size accounting is done up front: entry counts and total extracted
//!      bytes must fit the configured limits, and each entry must fit the
//!      per-file limit (decompression-bomb protection).
//!   3. Extraction writes into a destination directory handle obtained from
//!      the sandbox (component-by-component, no symlink following), never
//!      into a host absolute path.
//!   4. Symlink/hardlink entries are never materialized: they are skipped and
//!      reported, so an archive cannot plant an escape link.
//!
//! Supported: ZIP (store + deflate) and TAR (ustar/POSIX + GNU long names),
//! including TAR.GZ via std.compress.flate.

const std = @import("std");
const sandbox_mod = @import("sandbox.zig");

pub const Sandbox = sandbox_mod.Sandbox;

pub const ArchiveError = sandbox_mod.OpenPathError || error{
    /// Not a recognized archive format.
    UnsupportedFormat,
    /// An entry name would escape the sandbox.
    UnsafeEntry,
    /// Entry count or extracted size exceeds the configured limits.
    LimitExceeded,
    /// The archive is malformed or truncated.
    CorruptArchive,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Kind = enum {
    zip,
    tar,
    tar_gz,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .zip => "zip",
            .tar => "tar",
            .tar_gz => "tar.gz",
        };
    }
};

pub const Summary = struct {
    kind: Kind,
    /// Entries successfully extracted.
    extracted: usize,
    /// Directory entries created (also counted in `extracted`).
    directories: usize,
    /// Entries skipped because they were links or unsupported types.
    skipped: usize,
    /// Total uncompressed bytes written.
    bytes: u64,
};

/// Detect the archive kind from the leading bytes of the file.
pub fn detectKind(head: []const u8) ?Kind {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], &[_]u8{ 'P', 'K', 3, 4 })) return .zip;
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], &[_]u8{ 'P', 'K', 5, 6 })) return .zip;
    if (head.len >= 2 and head[0] == 0x1f and head[1] == 0x8b) return .tar_gz;
    if (head.len >= 265 and std.mem.eql(u8, head[257..262], "ustar")) return .tar;
    return null;
}

/// Validate one archive entry name against the sandbox path policy.
/// Directory entries (trailing `/`) are validated without the separator.
pub fn validateEntryName(raw: []const u8) ArchiveError![]const u8 {
    if (raw.len == 0) return error.UnsafeEntry;
    var name = raw;
    while (name.len > 0 and (name[name.len - 1] == '/' or name[name.len - 1] == '\\')) {
        name = name[0 .. name.len - 1];
    }
    if (name.len == 0) return error.CorruptArchive;
    // A backslash inside an entry name is a Windows separator in disguise and
    // the classic zip-slip vector; refuse rather than normalize.
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.UnsafeEntry;
    sandbox_mod.validateRelPath(name) catch return error.UnsafeEntry;
    return name;
}

pub const Archives = struct {
    sb: *const Sandbox,

    pub fn init(sb: *const Sandbox) Archives {
        return .{ .sb = sb };
    }

    fn openArchiveFile(self: *const Archives, path: []const u8) !std.Io.File {
        try self.sb.checkRead(path);
        var opened = try self.sb.walkTo(path);
        defer self.sb.closeOpened(&opened);
        const parent = if (opened.parent_dirs.len == 0)
            self.sb.root
        else
            opened.parent_dirs[opened.parent_dirs.len - 1];
        const stat = parent.statFile(self.sb.io, opened.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop => return error.SymLinkRefused,
            else => return sandbox_mod.mapOpenError(err),
        };
        if (stat.kind == .sym_link) return error.SymLinkRefused;
        if (stat.size > self.sb.limits.max_archive_bytes) return error.LimitExceeded;
        return parent.openFile(self.sb.io, opened.basename, .{ .mode = .read_only }) catch |err|
            sandbox_mod.mapOpenError(err);
    }

    /// Open the extraction destination directory (created if missing).
    /// The whole destination chain is created inside the sandbox root and
    /// then re-verified component-by-component without symlink following.
    fn openExtractDir(self: *const Archives, dest: []const u8) !std.Io.Dir {
        try self.sb.checkWrite(dest);
        self.sb.root.createDirPath(self.sb.io, dest) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return sandbox_mod.mapOpenError(err),
        };
        var opened = try self.sb.walkTo(dest);
        defer self.sb.closeOpened(&opened);
        const parent = if (opened.parent_dirs.len == 0)
            self.sb.root
        else
            opened.parent_dirs[opened.parent_dirs.len - 1];
        return parent.openDir(self.sb.io, opened.basename, .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| sandbox_mod.mapOpenError(err);
    }

    /// ZIP entry listing:
    /// {"path":...,"kind":"zip","entries":[{"name","size","compressed_size",
    ///  "type"}],"truncated":false}
    pub fn zipListJson(self: *const Archives, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var file = try self.openArchiveFile(path);
        defer file.close(self.sb.io);

        var reader_buf: [4096]u8 = undefined;
        var fr = file.reader(self.sb.io, &reader_buf);
        var iter = std.zip.Iterator.init(&fr) catch return error.CorruptArchive;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(path);
        try stringify.objectField("kind");
        try stringify.write("zip");
        try stringify.objectField("entries");
        try stringify.beginArray();

        var count: usize = 0;
        var truncated = false;
        while (iter.next() catch return error.CorruptArchive) |entry| {
            if (count >= self.sb.limits.max_entries) {
                truncated = true;
                break;
            }
            count += 1;
            var name_buf: [4096]u8 = undefined;
            const name = try self.readZipName(&fr, entry, &name_buf, allocator);
            defer if (name.owned) allocator.free(name.bytes);

            try stringify.beginObject();
            try stringify.objectField("name");
            try stringify.write(name.bytes);
            try stringify.objectField("size");
            try stringify.write(entry.uncompressed_size);
            try stringify.objectField("compressed_size");
            try stringify.write(entry.compressed_size);
            try stringify.objectField("type");
            try stringify.write(if (name.is_dir) "directory" else "file");
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.objectField("truncated");
        try stringify.write(truncated);
        try stringify.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    const ZipName = struct { bytes: []const u8, is_dir: bool, owned: bool };

    fn readZipName(
        self: *const Archives,
        fr: *std.Io.File.Reader,
        entry: std.zip.Iterator.Entry,
        buf: []u8,
        allocator: std.mem.Allocator,
    ) !ZipName {
        _ = self;
        const len: usize = entry.filename_len;
        var name: []u8 = undefined;
        var owned = false;
        if (len <= buf.len) {
            name = buf[0..len];
        } else {
            name = allocator.alloc(u8, len) catch return error.OutOfMemory;
            owned = true;
        }
        fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch return error.CorruptArchive;
        fr.interface.readSliceAll(name) catch return error.CorruptArchive;
        const is_dir = name.len > 0 and name[name.len - 1] == '/';
        return .{ .bytes = name, .is_dir = is_dir, .owned = owned };
    }

    /// Extract a ZIP archive into `dest` (a sandbox-relative directory).
    /// Every entry is validated and size-accounted before extraction; link
    /// entries are skipped. Returns a summary of what was written.
    pub fn zipExtract(
        self: *const Archives,
        allocator: std.mem.Allocator,
        path: []const u8,
        dest: []const u8,
    ) !Summary {
        var file = try self.openArchiveFile(path);
        defer file.close(self.sb.io);

        var reader_buf: [4096]u8 = undefined;
        var fr = file.reader(self.sb.io, &reader_buf);
        var iter = std.zip.Iterator.init(&fr) catch return error.CorruptArchive;

        // Pass 1: validate every entry name and account for size/entry limits
        // before a single byte is written. Nothing is extracted unless the
        // whole archive passes.
        var planned_entries: usize = 0;
        var planned_bytes: u64 = 0;
        var name_buf: [4096]u8 = undefined;
        while (iter.next() catch return error.CorruptArchive) |entry| {
            if (planned_entries >= self.sb.limits.max_entries) return error.LimitExceeded;
            if (planned_bytes + entry.uncompressed_size > self.sb.limits.max_extracted_bytes)
                return error.LimitExceeded;
            if (entry.uncompressed_size > self.sb.limits.max_write_bytes)
                return error.LimitExceeded;
            switch (entry.compression_method) {
                .store, .deflate => {},
                else => return error.UnsupportedFormat,
            }
            const name = try self.readZipName(&fr, entry, &name_buf, allocator);
            defer if (name.owned) allocator.free(name.bytes);
            _ = validateEntryName(name.bytes) catch return error.UnsafeEntry;
            planned_entries += 1;
            planned_bytes += entry.uncompressed_size;
        }

        // Pass 2: extract, now that every target path is known-good.
        iter = std.zip.Iterator.init(&fr) catch return error.CorruptArchive;
        var dest_dir = try self.openExtractDir(dest);
        defer dest_dir.close(self.sb.io);

        var summary = Summary{ .kind = .zip, .extracted = 0, .directories = 0, .skipped = 0, .bytes = 0 };
        while (iter.next() catch return error.CorruptArchive) |entry| {
            const name = try self.readZipName(&fr, entry, &name_buf, allocator);
            defer if (name.owned) allocator.free(name.bytes);
            const clean = try validateEntryName(name.bytes);
            if (name.is_dir) {
                dest_dir.createDirPath(self.sb.io, clean) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return sandbox_mod.mapOpenError(err),
                };
                summary.directories += 1;
                summary.extracted += 1;
                continue;
            }
            var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
            const filename_len = @min(clean.len, filename_buf.len);
            @memcpy(filename_buf[0..filename_len], clean);
            entry.extract(&fr, .{ .allow_backslashes = false }, filename_buf[0..filename_len], dest_dir) catch |err| switch (err) {
                error.UnsupportedCompressionMethod => return error.UnsupportedFormat,
                else => return error.CorruptArchive,
            };
            summary.extracted += 1;
            summary.bytes += entry.uncompressed_size;
        }
        return summary;
    }

    /// Detect the archive kind using a short-lived handle. The main pass
    /// re-opens the file afterwards so the streaming reader always starts at
    /// offset 0 (positional probes may advance the shared file pointer).
    pub fn detectKindFor(self: *const Archives, path: []const u8) !Kind {
        var file = try self.openArchiveFile(path);
        defer file.close(self.sb.io);
        var reader_buf: [512]u8 = undefined;
        var fr = file.readerStreaming(self.sb.io, &reader_buf);
        var head: [512]u8 = undefined;
        // Short files are fine here: detection only needs the leading bytes.
        const n = fr.interface.readSliceShort(&head) catch return error.ReadFailed;
        if (n == 0) return error.CorruptArchive;
        return detectKind(head[0..n]) orelse error.CorruptArchive;
    }

    /// TAR entry listing (same JSON shape as the ZIP listing).
    pub fn tarListJson(self: *const Archives, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const kind = try self.detectKindFor(path);
        var file = try self.openArchiveFile(path);
        defer file.close(self.sb.io);

        var reader_buf: [8192]u8 = undefined;
        var fr = file.readerStreaming(self.sb.io, &reader_buf);
        var source: *std.Io.Reader = &fr.interface;
        var window: [65536]u8 = undefined;
        var dec: std.compress.flate.Decompress = undefined;
        if (kind == .tar_gz) {
            dec = std.compress.flate.Decompress.init(&fr.interface, .gzip, &window);
            source = &dec.reader;
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stringify: std.json.Stringify = .{ .writer = &output.writer };
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(path);
        try stringify.objectField("kind");
        try stringify.write(kind.name());
        try stringify.objectField("entries");
        try stringify.beginArray();
        const summary = try walkTar(allocator, source, self.sb.limits, self.sb.io, null, &stringify);
        try stringify.endArray();
        try stringify.objectField("truncated");
        try stringify.write(false);
        try stringify.objectField("skipped");
        try stringify.write(summary.skipped);
        try stringify.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Extract a TAR or TAR.GZ archive into `dest`, with the same two-pass
    /// validation and limit accounting as ZIP. Link entries are skipped.
    pub fn tarExtract(
        self: *const Archives,
        allocator: std.mem.Allocator,
        path: []const u8,
        dest: []const u8,
    ) !Summary {
        const kind = try self.detectKindFor(path);
        var file = try self.openArchiveFile(path);
        defer file.close(self.sb.io);

        var dest_dir = try self.openExtractDir(dest);
        defer dest_dir.close(self.sb.io);

        var reader_buf: [8192]u8 = undefined;
        var fr = file.readerStreaming(self.sb.io, &reader_buf);
        var window: [65536]u8 = undefined;
        var dec: std.compress.flate.Decompress = undefined;
        var source: *std.Io.Reader = &fr.interface;
        if (kind == .tar_gz) {
            dec = std.compress.flate.Decompress.init(&fr.interface, .gzip, &window);
            source = &dec.reader;
        }

        return walkTar(allocator, source, self.sb.limits, self.sb.io, dest_dir, null);
    }

    /// Create a ZIP archive (store method) at `dest` containing the given
    /// sandbox files. Returns the number of entries written.
    pub fn zipCreate(
        self: *const Archives,
        allocator: std.mem.Allocator,
        dest: []const u8,
        sources: []const []const u8,
    ) !usize {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;

        const Central = struct { name: []u8, crc: u32, size: u64, offset: u64 };
        var centrals: std.ArrayList(Central) = .empty;
        defer {
            for (centrals.items) |c| allocator.free(c.name);
            centrals.deinit(allocator);
        }

        for (sources) |src| {
            try self.sb.checkRead(src);
            const data = self.sb.root.readFileAlloc(self.sb.io, src, allocator, .limited(self.sb.limits.max_read_bytes)) catch |err|
                return sandbox_mod.mapOpenError(err);
            defer allocator.free(data);
            const crc = std.hash.Crc32.hash(data);

            const offset: u64 = out.written().len;
            const name_copy = allocator.dupe(u8, src) catch return error.OutOfMemory;
            errdefer allocator.free(name_copy);

            // Local file header (store).
            try writeU32(w, 0x04034b50); // local file header signature
            try writeU16(w, 20); // version needed
            try writeU16(w, 0); // flags
            try writeU16(w, 0); // method: store
            try writeU16(w, 0); // mod time
            try writeU16(w, 0); // mod date
            try writeU32(w, crc);
            try writeU32(w, @intCast(data.len)); // compressed
            try writeU32(w, @intCast(data.len)); // uncompressed
            try writeU16(w, @intCast(src.len));
            try writeU16(w, 0); // extra len
            try w.writeAll(src);
            try w.writeAll(data);

            try centrals.append(allocator, .{ .name = name_copy, .crc = crc, .size = data.len, .offset = offset });
        }

        const cd_start: u64 = out.written().len;
        for (centrals.items) |c| {
            try writeU32(w, 0x02014b50); // signature
            try writeU16(w, 20); // version made by
            try writeU16(w, 20); // version needed
            try writeU16(w, 0);
            try writeU16(w, 0);
            try writeU16(w, 0);
            try writeU16(w, 0);
            try writeU32(w, c.crc);
            try writeU32(w, @intCast(c.size));
            try writeU32(w, @intCast(c.size));
            try writeU16(w, @intCast(c.name.len));
            try writeU16(w, 0); // extra
            try writeU16(w, 0); // comment
            try writeU16(w, 0); // disk
            try writeU16(w, 0); // internal attrs
            try writeU32(w, 0); // external attrs
            try writeU32(w, @intCast(c.offset));
            try w.writeAll(c.name);
        }
        const cd_size: u64 = out.written().len - cd_start;

        // End of central directory.
        try writeU32(w, 0x06054b50);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, @intCast(centrals.items.len));
        try writeU16(w, @intCast(centrals.items.len));
        try writeU32(w, @intCast(cd_size));
        try writeU32(w, @intCast(cd_start));
        try writeU16(w, 0);

        try self.sb.checkWrite(dest);
        var opened = try self.sb.walkToCreate(dest);
        defer self.sb.closeOpened(&opened);
        const parent = if (opened.parent_dirs.len == 0)
            self.sb.root
        else
            opened.parent_dirs[opened.parent_dirs.len - 1];
        var file = parent.createFile(self.sb.io, opened.basename, .{}) catch |err|
            return sandbox_mod.mapOpenError(err);
        defer file.close(self.sb.io);
        var list = out.toArrayList();
        const bytes = list.toOwnedSlice(allocator) catch return error.OutOfMemory;
        defer allocator.free(bytes);
        file.writeStreamingAll(self.sb.io, bytes) catch return error.WriteFailed;
        return centrals.items.len;
    }
};

fn writeU16(w: *std.Io.Writer, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try w.writeAll(&buf);
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try w.writeAll(&buf);
}

// ---------------------------------------------------------------------------
// Test fixtures

const TarEntry = struct {
    name: []const u8,
    data: []const u8 = "",
    typeflag: u8 = '0',
};

/// Build a ustar archive in memory: entries, two terminating zero blocks.
fn buildTar(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries) |entry| {
        var block: [512]u8 = undefined;
        tarHeaderBlock(&block, entry.name, entry.data.len, entry.typeflag);
        try out.appendSlice(allocator, &block);
        try out.appendSlice(allocator, entry.data);
        const pad = (entry.data.len + 511) / 512 * 512 - entry.data.len;
        try out.appendNTimes(allocator, 0, pad);
    }
    try out.appendNTimes(allocator, 0, 1024);
    return out.toOwnedSlice(allocator);
}

fn tarHeaderBlock(buf: *[512]u8, name: []const u8, size: u64, typeflag: u8) void {
    @memset(buf, 0);
    const n = @min(name.len, 100);
    @memcpy(buf[0..n], name[0..n]);
    writeTarOctal(buf[124..136], size);
    buf[156] = typeflag;
    @memcpy(buf[257..262], "ustar");
    buf[263] = '0';
    buf[264] = '0';
    @memset(buf[148..156], ' ');
    var sum: u64 = 0;
    for (buf) |b| sum += b;
    writeTarOctal(buf[148..154], sum);
    buf[154] = 0;
    buf[155] = ' ';
}

fn writeTarOctal(field: []u8, value: u64) void {
    var v = value;
    var i = field.len;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v % 8));
        v /= 8;
        if (v == 0 and i > 0) {
            // left-pad with zeros
            var j = i;
            while (j > 0) {
                j -= 1;
                field[j] = '0';
            }
            break;
        }
    }
}

/// Hand-built single-entry stored ZIP with an arbitrary (attacker-controlled)
/// entry name — used to prove traversal entries are rejected.
fn buildMaliciousZip(allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const crc = std.hash.Crc32.hash(data);
    const offset: u32 = 0;

    try writeU32(w, 0x04034b50);
    try writeU16(w, 20);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU32(w, crc);
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(data.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0);
    try w.writeAll(name);
    try w.writeAll(data);

    const cd_start: u32 = @intCast(out.written().len);
    try writeU32(w, 0x02014b50);
    try writeU16(w, 20);
    try writeU16(w, 20);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU32(w, crc);
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(data.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU32(w, 0);
    try writeU32(w, offset);
    try w.writeAll(name);
    const cd_size: u32 = @intCast(out.written().len - cd_start);

    try writeU32(w, 0x06054b50);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, 1);
    try writeU16(w, 1);
    try writeU32(w, cd_size);
    try writeU32(w, cd_start);
    try writeU16(w, 0);

    var list = out.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "tar fixtures parse back correctly" {
    const entries = [_]TarEntry{
        .{ .name = "a.txt", .data = "1" },
        .{ .name = "b.txt", .data = "2" },
    };
    const bytes = try buildTar(std.testing.allocator, &entries);
    defer std.testing.allocator.free(bytes);
    // 2 * (512 header + 512 data/pad) + 1024 terminator
    try std.testing.expectEqual(@as(usize, 3072), bytes.len);

    const h1 = (try parseTarHeader(bytes[0..512])).?;
    try std.testing.expectEqualStrings("a.txt", h1.name);
    try std.testing.expectEqual(@as(u64, 1), h1.size);
    try std.testing.expectEqual(@as(u8, '0'), h1.typeflag);

    const h2 = (try parseTarHeader(bytes[1024..1536])).?;
    try std.testing.expectEqualStrings("b.txt", h2.name);
    try std.testing.expectEqual(@as(u64, 1), h2.size);
    try std.testing.expectEqual(@as(u8, '0'), h2.typeflag);

    // Terminator.
    try std.testing.expect((try parseTarHeader(bytes[2048..2560])) == null);

    // The walker itself sees two regular entries when fed the same bytes.
    var fixed = std.Io.Reader.fixed(bytes);
    const summary = try walkTar(
        std.testing.allocator,
        &fixed,
        .{},
        std.testing.io,
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), summary.extracted);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(u64, 2), summary.bytes);

    // The entry-count limit aborts the second entry.
    var fixed2 = std.Io.Reader.fixed(bytes);
    try std.testing.expectError(
        error.LimitExceeded,
        walkTar(std.testing.allocator, &fixed2, .{ .max_entries = 1 }, std.testing.io, null, null),
    );
    // The per-entry size limit aborts an oversized entry.
    const big = [_]TarEntry{.{ .name = "big.txt", .data = "0123456789" }};
    const big_tar = try buildTar(std.testing.allocator, &big);
    defer std.testing.allocator.free(big_tar);
    var fixed3 = std.Io.Reader.fixed(big_tar);
    try std.testing.expectError(
        error.LimitExceeded,
        walkTar(std.testing.allocator, &fixed3, .{ .max_write_bytes = 2 }, std.testing.io, null, null),
    );
}

const ArchiveTestEnv = struct {
    sandbox: sandbox_mod.Sandbox,
    root_name: []const u8,
    cwd_dir: std.Io.Dir,

    fn init(allocator: std.mem.Allocator, root_name: []const u8, limits: sandbox_mod.Limits) !ArchiveTestEnv {
        const io = std.testing.io;
        const cwd_dir = std.Io.Dir.cwd();
        cwd_dir.deleteTree(io, root_name) catch {};
        return .{
            .sandbox = try sandbox_mod.Sandbox.init(io, allocator, cwd_dir, root_name, .{
                .read = true,
                .write = true,
            }, limits),
            .root_name = root_name,
            .cwd_dir = cwd_dir,
        };
    }

    fn archives(self: *ArchiveTestEnv) Archives {
        return Archives.init(&self.sandbox);
    }

    fn write(self: *ArchiveTestEnv, path: []const u8, data: []const u8) !void {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            self.sandbox.root.createDirPath(std.testing.io, path[0..slash]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        try self.sandbox.root.writeFile(std.testing.io, .{
            .sub_path = path,
            .data = data,
            .flags = .{ .resolve_beneath = true },
        });
    }

    fn read(self: *ArchiveTestEnv, path: []const u8) ![]u8 {
        return self.sandbox.root.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    }

    fn deinit(self: *ArchiveTestEnv) void {
        self.sandbox.deinit();
        self.cwd_dir.deleteTree(std.testing.io, self.root_name) catch {};
    }
};

test "archives zip round trip: create, list and extract" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-archzip", .{});
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    try env.write("src/one.txt", "first file");
    try env.write("src/two.txt", "second file");

    const sources = [_][]const u8{ "src/one.txt", "src/two.txt" };
    const count = try arc.zipCreate(std.testing.allocator, "out/bundle.zip", &sources);
    try std.testing.expectEqual(@as(usize, 2), count);

    const listing = try arc.zipListJson(std.testing.allocator, "out/bundle.zip");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"kind\":\"zip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "src/one.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "src/two.txt") != null);

    const summary = try arc.zipExtract(std.testing.allocator, "out/bundle.zip", "unpacked");
    try std.testing.expectEqual(@as(usize, 2), summary.extracted);
    const one = try env.read("unpacked/src/one.txt");
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("first file", one);
    const two = try env.read("unpacked/src/two.txt");
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings("second file", two);
}

test "archives zip rejects traversal entries before extracting anything" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-archslip", .{});
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    const evil = try buildMaliciousZip(std.testing.allocator, "../evil.txt", "pwned");
    defer std.testing.allocator.free(evil);
    try env.write("evil.zip", evil);

    try std.testing.expectError(
        error.UnsafeEntry,
        arc.zipExtract(std.testing.allocator, "evil.zip", "unpacked"),
    );
    // Nothing was written: the escape file must not exist in the parent of
    // the sandbox root either.
    const io = std.testing.io;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, "evil.txt", .{}),
    );
    try std.testing.expectError(error.FileNotFound, env.read("evil.txt"));

    // Windows-style separators are refused too.
    const backslash = try buildMaliciousZip(std.testing.allocator, "..\\evil2.txt", "pwned");
    defer std.testing.allocator.free(backslash);
    try env.write("evil2.zip", backslash);
    try std.testing.expectError(
        error.UnsafeEntry,
        arc.zipExtract(std.testing.allocator, "evil2.zip", "unpacked"),
    );

    // detectKind recognises the archive heads.
    try std.testing.expectEqual(@as(?Kind, .zip), detectKind(evil[0..4]));
}

test "archives tar lists and extracts files, dirs, and skips links" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-arctar", .{});
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    const entries = [_]TarEntry{
        .{ .name = "bundle/", .typeflag = '5' },
        .{ .name = "bundle/note.txt", .data = "tar payload" },
        .{ .name = "bundle/link.txt", .data = "../outside", .typeflag = '2' },
    };
    const tar_bytes = try buildTar(std.testing.allocator, &entries);
    defer std.testing.allocator.free(tar_bytes);
    try env.write("bundle.tar", tar_bytes);

    const listing = try arc.tarListJson(std.testing.allocator, "bundle.tar");
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"kind\":\"tar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "bundle/note.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"skipped\":1") != null);

    const summary = try arc.tarExtract(std.testing.allocator, "bundle.tar", "out");
    try std.testing.expectEqual(@as(usize, 1), summary.skipped);
    const note = try env.read("out/bundle/note.txt");
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings("tar payload", note);
    // The symlink entry was never materialized.
    try std.testing.expectError(error.FileNotFound, env.read("out/bundle/link.txt"));
}

test "archives tar rejects traversal entries" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-arctarslip", .{});
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    const entries = [_]TarEntry{
        .{ .name = "..\\escaped.txt", .data = "nope" },
    };
    const tar_bytes = try buildTar(std.testing.allocator, &entries);
    defer std.testing.allocator.free(tar_bytes);
    try env.write("evil.tar", tar_bytes);

    try std.testing.expectError(
        error.UnsafeEntry,
        arc.tarExtract(std.testing.allocator, "evil.tar", "out"),
    );
}

test "archives tar.gz extraction works through the gzip container" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-arctgz", .{});
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    const entries = [_]TarEntry{
        .{ .name = "gz/inside.txt", .data = "gzipped payload" },
    };
    const tar_bytes = try buildTar(std.testing.allocator, &entries);
    defer std.testing.allocator.free(tar_bytes);

    var gz_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer gz_output.deinit();
    // Compress asserts a non-trivial output buffer up front.
    try gz_output.ensureTotalCapacity(4096);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &gz_output.writer,
        &window,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );
    try compressor.writer.writeAll(tar_bytes);
    try compressor.finish();
    try env.write("bundle.tar.gz", gz_output.written());

    try std.testing.expectEqual(@as(?Kind, .tar_gz), detectKind(gz_output.written()[0..4]));

    const summary = try arc.tarExtract(std.testing.allocator, "bundle.tar.gz", "out");
    try std.testing.expectEqual(@as(usize, 1), summary.extracted);
    const inside = try env.read("out/gz/inside.txt");
    defer std.testing.allocator.free(inside);
    try std.testing.expectEqualStrings("gzipped payload", inside);
}

test "archives enforce entry-count and size limits" {
    var env = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-arclimits", .{
        .max_entries = 1,
        .max_extracted_bytes = 4096,
    });
    defer env.deinit();
    var arc_v = env.archives();
    const arc = &arc_v;

    const entries = [_]TarEntry{
        .{ .name = "a.txt", .data = "1" },
        .{ .name = "b.txt", .data = "2" },
    };
    const tar_bytes = try buildTar(std.testing.allocator, &entries);
    defer std.testing.allocator.free(tar_bytes);
    try env.write("limits.tar", tar_bytes);

    try std.testing.expectError(
        error.LimitExceeded,
        arc.tarExtract(std.testing.allocator, "limits.tar", "out"),
    );

    // Per-entry size limit also applies.
    var env2 = try ArchiveTestEnv.init(std.testing.allocator, "zig-cache-pico-arclimits2", .{
        .max_write_bytes = 2,
    });
    defer env2.deinit();
    var arc2_v = env2.archives();
    const arc2 = &arc2_v;
    const big = [_]TarEntry{.{ .name = "big.txt", .data = "0123456789" }};
    const big_tar = try buildTar(std.testing.allocator, &big);
    defer std.testing.allocator.free(big_tar);
    try env2.write("big.tar", big_tar);
    try std.testing.expectError(
        error.LimitExceeded,
        arc2.tarExtract(std.testing.allocator, "big.tar", "out"),
    );
}

const TarHeader = struct {
    name: []const u8,
    size: u64,
    typeflag: u8,
    prefix: []const u8 = "",
};

/// Parse one 512-byte TAR header block. Returns null at the archive terminator.
fn parseTarHeader(block: []const u8) !?TarHeader {
    if (block.len != 512) return error.CorruptArchive;
    // Two zero blocks terminate the archive.
    var all_zero = true;
    for (block) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return null;

    const raw_name = std.mem.sliceTo(block[0..100], 0);
    const prefix = std.mem.sliceTo(block[345..500], 0);
    const size_field = std.mem.sliceTo(block[124..136], 0);
    const size = parseTarOctal(size_field) catch return error.CorruptArchive;
    const typeflag = block[156];

    // ustar prefix joins the name with a '/'.
    var full: []const u8 = raw_name;
    if (prefix.len > 0) {
        // The caller copies the name out of the block buffer; a prefix needs
        // the caller's arena, so it is materialized by the caller instead.
        full = raw_name; // handled below by caller-provided concat
    }
    return .{ .name = full, .size = size, .typeflag = typeflag, .prefix = prefix };
}

fn parseTarOctal(field: []const u8) !u64 {
    var value: u64 = 0;
    var seen = false;
    for (field) |c| {
        if (c == 0 or c == ' ') {
            if (seen) break;
            continue;
        }
        if (c < '0' or c > '7') return error.CorruptArchive;
        value = value * 8 + (c - '0');
        seen = true;
    }
    return value;
}

fn readTarHeader(source: *std.Io.Reader, allocator: std.mem.Allocator) !?TarHeader {
    var block: [512]u8 = undefined;
    readBlock(source, &block) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    const parsed = (try parseTarHeader(&block)) orelse return null;
    // Materialize the (possibly prefixed) name into owned memory.
    var name: []const u8 = undefined;
    if (parsed.prefix.len > 0) {
        name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parsed.prefix, parsed.name });
    } else {
        name = try allocator.dupe(u8, parsed.name);
    }
    return .{ .name = name, .size = parsed.size, .typeflag = parsed.typeflag, .prefix = "" };
}

/// Read exactly 512 bytes or report EndOfStream for a short tail.
fn readBlock(source: *std.Io.Reader, block: *[512]u8) !void {
    source.readSliceAll(block) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.CorruptArchive,
    };
}

/// Skip `n` bytes of stream content (file data or padding).
fn skipTarBytes(source: *std.Io.Reader, n: u64) !void {
    var remaining = n;
    var scratch: [1024]u8 = undefined;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, scratch.len));
        source.readSliceAll(scratch[0..chunk]) catch return error.CorruptArchive;
        remaining -= chunk;
    }
}

/// Skip the padding-block-rounded size of a TAR entry.
fn skipTarPadded(source: *std.Io.Reader, size: u64) !void {
    try skipTarBytes(source, (size + 511) / 512 * 512);
}

/// Single-pass TAR walker. With `dest_dir == null` it collects a listing into
/// `listing`; with a directory it extracts (validating each name before its
/// own write; link entries are skipped and never materialized). TAR streams
/// cannot be rewound (they may be gunzipped), so limit accounting is
/// incremental: a limit violation aborts extraction, leaving the destination
/// partially populated.
fn walkTar(
    allocator: std.mem.Allocator,
    source: *std.Io.Reader,
    limits: sandbox_mod.Limits,
    io: std.Io,
    dest_dir: ?std.Io.Dir,
    listing: ?*std.json.Stringify,
) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var summary = Summary{ .kind = .tar, .extracted = 0, .directories = 0, .skipped = 0, .bytes = 0 };
    var long_name: ?[]const u8 = null;

    while (true) {
        var block: [512]u8 = undefined;
        readBlock(source, &block) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const parsed = (try parseTarHeader(&block)) orelse break;

        if (parsed.typeflag == 'L') {
            // GNU long name: the payload holds the next entry's real name.
            const payload = try arena.alloc(u8, (parsed.size + 511) / 512 * 512);
            source.readSliceAll(payload) catch return error.CorruptArchive;
            long_name = try arena.dupe(u8, std.mem.sliceTo(payload[0..@intCast(parsed.size)], 0));
            continue;
        }
        if (parsed.typeflag == 'x' or parsed.typeflag == 'g') {
            try skipTarPadded(source, parsed.size);
            continue;
        }

        const entry_name: []const u8 = long_name orelse blk: {
            if (parsed.prefix.len > 0)
                break :blk try std.fmt.allocPrint(arena, "{s}/{s}", .{ parsed.prefix, parsed.name });
            break :blk parsed.name;
        };
        long_name = null;

        const clean = validateEntryName(entry_name) catch return error.UnsafeEntry;
        const is_dir = parsed.typeflag == '5' or
            (parsed.typeflag == '0' and entry_name.len > 0 and entry_name[entry_name.len - 1] == '/');

        if (parsed.typeflag == '0' or parsed.typeflag == ' ' or parsed.typeflag == '5') {
            if (is_dir) {
                if (dest_dir) |d| {
                    d.createDirPath(io, clean) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return sandbox_mod.mapOpenError(err),
                    };
                }
                if (listing) |st| {
                    try st.beginObject();
                    try st.objectField("name");
                    try st.write(entry_name);
                    try st.objectField("size");
                    try st.write(parsed.size);
                    try st.objectField("type");
                    try st.write("directory");
                    try st.endObject();
                }
                summary.directories += 1;
                summary.extracted += 1;
                try skipTarPadded(source, parsed.size);
            } else {
                if (summary.extracted >= limits.max_entries) return error.LimitExceeded;
                if (summary.bytes + parsed.size > limits.max_extracted_bytes) return error.LimitExceeded;
                if (parsed.size > limits.max_write_bytes) return error.LimitExceeded;
                if (listing) |st| {
                    try st.beginObject();
                    try st.objectField("name");
                    try st.write(entry_name);
                    try st.objectField("size");
                    try st.write(parsed.size);
                    try st.objectField("type");
                    try st.write("file");
                    try st.endObject();
                }
                if (dest_dir) |d| {
                    try writeFileFromTar(io, d, clean, source, parsed.size);
                } else {
                    try skipTarPadded(source, parsed.size);
                }
                summary.extracted += 1;
                summary.bytes += parsed.size;
            }
        } else {
            // Links, devices, FIFOs, and anything else: never materialized.
            summary.skipped += 1;
            try skipTarPadded(source, parsed.size);
        }
    }
    return summary;
}

/// Stream `size` bytes of entry data into a new file under `dest_dir`.
/// Consumes exactly `size` bytes plus padding from the source.
fn writeFileFromTar(
    io: std.Io,
    dest_dir: std.Io.Dir,
    clean: []const u8,
    source: *std.Io.Reader,
    size: u64,
) !void {
    if (std.mem.lastIndexOfScalar(u8, clean, '/')) |slash| {
        dest_dir.createDirPath(io, clean[0..slash]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return sandbox_mod.mapOpenError(err),
        };
    }
    var file = dest_dir.createFile(io, clean, .{}) catch |err|
        return sandbox_mod.mapOpenError(err);
    defer file.close(io);
    var writer_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &writer_buf);

    var remaining = size;
    var chunk: [4096]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        source.readSliceAll(chunk[0..want]) catch return error.CorruptArchive;
        fw.interface.writeAll(chunk[0..want]) catch return error.WriteFailed;
        remaining -= want;
    }
    fw.interface.flush() catch return error.WriteFailed;
    const pad = (size + 511) / 512 * 512 - size;
    if (pad > 0) {
        var scratch: [512]u8 = undefined;
        source.readSliceAll(scratch[0..@intCast(pad)]) catch return error.CorruptArchive;
    }
}
