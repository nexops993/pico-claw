//! Media inspection: images and video containers.
//!
//! This module reports only what can be derived from the file itself (format,
//! dimensions, size, hash, container metadata). It never claims visual
//! understanding: vision is a *provider* capability surfaced separately by the
//! capability manifest, and frame extraction requires an external tool that is
//! not bundled, so those return structured `unsupported` results.

const std = @import("std");
const sandbox_mod = @import("sandbox.zig");

pub const Sandbox = sandbox_mod.Sandbox;

pub const ImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
    unknown,

    pub fn name(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpeg",
            .gif => "gif",
            .webp => "webp",
            .bmp => "bmp",
            .unknown => "unknown",
        };
    }

    pub fn mime(self: ImageFormat) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .bmp => "image/bmp",
            .unknown => "application/octet-stream",
        };
    }
};

pub const VideoFormat = enum {
    mp4,
    matroska,
    webm,
    avi,
    unknown,

    pub fn name(self: VideoFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
            .matroska => "matroska",
            .webm => "webm",
            .avi => "avi",
            .unknown => "unknown",
        };
    }
};

pub const ImageInfo = struct {
    format: ImageFormat = .unknown,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Set when the format is recognized but a field is unavailable.
    note: []const u8 = "",
};

/// Sniff an image from its leading bytes; pure function, unit-testable.
pub fn sniffImage(head: []const u8) ImageInfo {
    if (head.len >= 24 and std.mem.eql(u8, head[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' })) {
        return .{
            .format = .png,
            .width = std.mem.readInt(u32, head[16..20], .big),
            .height = std.mem.readInt(u32, head[20..24], .big),
        };
    }
    if (head.len >= 10 and std.mem.eql(u8, head[0..3], "GIF")) {
        return .{
            .format = .gif,
            .width = std.mem.readInt(u16, head[6..8], .little),
            .height = std.mem.readInt(u16, head[8..10], .little),
        };
    }
    if (head.len >= 26 and std.mem.eql(u8, head[0..2], "BM")) {
        const bw = std.mem.readInt(i32, head[18..22], .little);
        const bh = std.mem.readInt(i32, head[22..26], .little);
        return .{
            .format = .bmp,
            .width = if (bw > 0) @intCast(bw) else null,
            .height = if (bh > 0) @intCast(bh) else null,
        };
    }
    if (head.len >= 30 and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "WEBP")) {
        return sniffWebp(head) orelse .{ .format = .webp, .note = "dimensions unavailable" };
    }
    if (head.len >= 4 and head[0] == 0xff and head[1] == 0xd8) {
        return sniffJpeg(head);
    }
    return .{ .format = .unknown };
}

fn sniffWebp(head: []const u8) ?ImageInfo {
    if (std.mem.eql(u8, head[12..16], "VP8X") and head.len >= 30) {
        const w = (@as(u32, head[24]) | (@as(u32, head[25]) << 8) | (@as(u32, head[26]) << 16)) + 1;
        const h = (@as(u32, head[27]) | (@as(u32, head[28]) << 8) | (@as(u32, head[29]) << 16)) + 1;
        return .{ .format = .webp, .width = w, .height = h };
    }
    if (std.mem.eql(u8, head[12..16], "VP8 ") and head.len >= 30 and
        head[23] == 0x9d and head[24] == 0x01 and head[25] == 0x2a)
    {
        const w = (std.mem.readInt(u16, head[26..28], .little)) & 0x3fff;
        const h = (std.mem.readInt(u16, head[28..30], .little)) & 0x3fff;
        return .{ .format = .webp, .width = w, .height = h };
    }
    if (std.mem.eql(u8, head[12..16], "VP8L") and head.len >= 25 and head[20] == 0x2f) {
        const bits = std.mem.readInt(u32, head[21..25], .little);
        const w = (bits & 0x3fff) + 1;
        const h = ((bits >> 14) & 0x3fff) + 1;
        return .{ .format = .webp, .width = w, .height = h };
    }
    return null;
}

fn sniffJpeg(head: []const u8) ImageInfo {
    var i: usize = 2;
    while (i + 9 < head.len) {
        if (head[i] != 0xff) {
            i += 1;
            continue;
        }
        const marker = head[i + 1];
        const is_sof = (marker >= 0xc0 and marker <= 0xc3) or
            (marker >= 0xc5 and marker <= 0xc7) or
            (marker >= 0xc9 and marker <= 0xcb) or
            (marker >= 0xcd and marker <= 0xcf);
        if (is_sof) {
            const height = std.mem.readInt(u16, head[i + 5 ..][0..2], .big);
            const width = std.mem.readInt(u16, head[i + 7 ..][0..2], .big);
            return .{ .format = .jpeg, .width = width, .height = height };
        }
        if (marker == 0xd8 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) {
            i += 2;
            continue;
        }
        const len = std.mem.readInt(u16, head[i + 2 ..][0..2], .big);
        if (len < 2) break;
        i += 2 + len;
    }
    return .{ .format = .jpeg, .note = "dimensions unavailable" };
}

pub const VideoInfo = struct {
    format: VideoFormat = .unknown,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_ms: ?u64 = null,
    note: []const u8 = "",
};

/// Sniff a video container from its leading bytes (metadata only).
pub fn sniffVideo(head: []const u8) VideoInfo {
    if (head.len >= 12 and std.mem.eql(u8, head[4..8], "ftyp")) {
        const brand = head[8..12];
        return .{
            .format = .mp4,
            .note = if (std.mem.eql(u8, brand, "qt  ")) "quicktime" else "",
        };
    }
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 })) {
        const format: VideoFormat = if (std.mem.indexOf(u8, head, "webm") != null) .webm else .matroska;
        return .{ .format = format };
    }
    if (head.len >= 12 and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "AVI ")) {
        return .{ .format = .avi };
    }
    return .{ .format = .unknown };
}

pub const Media = struct {
    sb: *const Sandbox,

    pub fn init(sb: *const Sandbox) Media {
        return .{ .sb = sb };
    }

    fn readHead(self: *const Media, path: []const u8, buf: []u8) !struct { data: []u8, size: u64 } {
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
        var file = parent.openFile(self.sb.io, opened.basename, .{ .mode = .read_only }) catch |err|
            return sandbox_mod.mapOpenError(err);
        defer file.close(self.sb.io);
        var reader_buf: [8192]u8 = undefined;
        var fr = file.readerStreaming(self.sb.io, &reader_buf);
        const n = fr.interface.readSliceShort(buf) catch return error.ReadFailed;
        return .{ .data = buf[0..n], .size = stat.size };
    }

    /// {"path","size","kind","format","mime","width","height","sha256"}
    pub fn inspectJson(self: *const Media, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var head_buf: [4096]u8 = undefined;
        const head = try self.readHead(path, &head_buf);
        const image = sniffImage(head.data);
        const video = sniffVideo(head.data);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var st: std.json.Stringify = .{ .writer = &output.writer };
        try st.beginObject();
        try st.objectField("path");
        try st.write(path);
        try st.objectField("size");
        try st.write(head.size);
        if (image.format != .unknown) {
            try st.objectField("kind");
            try st.write("image");
            try st.objectField("format");
            try st.write(image.format.name());
            try st.objectField("mime");
            try st.write(image.format.mime());
            try st.objectField("width");
            try writeOptionalU32(&st, image.width);
            try st.objectField("height");
            try writeOptionalU32(&st, image.height);
        } else if (video.format != .unknown) {
            try st.objectField("kind");
            try st.write("video");
            try st.objectField("format");
            try st.write(video.format.name());
            try st.objectField("width");
            try writeOptionalU32(&st, video.width);
            try st.objectField("height");
            try writeOptionalU32(&st, video.height);
            try st.objectField("note");
            try st.write(video.note);
        } else {
            try st.objectField("kind");
            try st.write("unknown");
            try st.objectField("format");
            try st.write("unknown");
        }
        const hash = try self.hashHex(path);
        defer self.sb.allocator.free(hash);
        try st.objectField("sha256");
        try st.write(hash);
        try st.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// SHA-256 of the whole (bounded) file, hex encoded.
    fn hashHex(self: *const Media, path: []const u8) ![]u8 {
        const allocator = self.sb.allocator;
        const bytes = self.sb.root.readFileAlloc(self.sb.io, path, allocator, .limited(self.sb.limits.max_read_bytes)) catch |err|
            return sandbox_mod.mapOpenError(err);
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = allocator.alloc(u8, 64) catch return error.OutOfMemory;
        errdefer allocator.free(hex);
        _ = std.fmt.bufPrint(hex, "{x}", .{digest}) catch return error.OutOfMemory;
        return hex;
    }

    /// Frame/audio extraction requires an external media tool that Pico Claw
    /// does not bundle; report honestly instead of pretending.
    pub fn unsupportedJson(self: *const Media, allocator: std.mem.Allocator, path: []const u8, op: []const u8) ![]u8 {
        _ = self;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var st: std.json.Stringify = .{ .writer = &output.writer };
        try st.beginObject();
        try st.objectField("path");
        try st.write(path);
        try st.objectField("operation");
        try st.write(op);
        try st.objectField("supported");
        try st.write(false);
        try st.objectField("reason");
        try st.write("requires an external media tool that is not configured");
        try st.endObject();
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

fn writeOptionalU32(st: *std.json.Stringify, value: ?u32) !void {
    if (value) |v| {
        try st.write(v);
    } else {
        try st.write(null);
    }
}

test "sniffImage reads PNG, GIF, BMP and JPEG dimensions" {
    var png_buf: [24]u8 = undefined;
    const png = png_buf[0..];
    @memset(png, 0);
    @memcpy(png[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, png[16..20], 640, .big);
    std.mem.writeInt(u32, png[20..24], 480, .big);
    const png_info = sniffImage(png);
    try std.testing.expectEqual(ImageFormat.png, png_info.format);
    try std.testing.expectEqual(@as(?u32, 640), png_info.width);
    try std.testing.expectEqual(@as(?u32, 480), png_info.height);

    var gif_buf: [10]u8 = undefined;
    const gif = gif_buf[0..];
    @memset(gif, 0);
    @memcpy(gif[0..6], "GIF89a");
    std.mem.writeInt(u16, gif[6..8], 320, .little);
    std.mem.writeInt(u16, gif[8..10], 200, .little);
    const gif_info = sniffImage(gif);
    try std.testing.expectEqual(ImageFormat.gif, gif_info.format);
    try std.testing.expectEqual(@as(?u32, 320), gif_info.width);

    var bmp_buf: [26]u8 = undefined;
    const bmp = bmp_buf[0..];
    @memset(bmp, 0);
    @memcpy(bmp[0..2], "BM");
    std.mem.writeInt(i32, bmp[18..22], 100, .little);
    std.mem.writeInt(i32, bmp[22..26], 50, .little);
    const bmp_info = sniffImage(bmp);
    try std.testing.expectEqual(ImageFormat.bmp, bmp_info.format);
    try std.testing.expectEqual(@as(?u32, 100), bmp_info.width);

    var jpeg_buf: [12]u8 = undefined;
    const jpeg = jpeg_buf[0..];
    @memset(jpeg, 0);
    jpeg[0] = 0xff;
    jpeg[1] = 0xd8; // SOI
    jpeg[2] = 0xff;
    jpeg[3] = 0xc0; // SOF0
    std.mem.writeInt(u16, jpeg[4..6], 11, .big);
    jpeg[6] = 8; // precision
    std.mem.writeInt(u16, jpeg[7..9], 768, .big);
    std.mem.writeInt(u16, jpeg[9..11], 1024, .big);
    const jpeg_info = sniffImage(jpeg);
    try std.testing.expectEqual(ImageFormat.jpeg, jpeg_info.format);
    try std.testing.expectEqual(@as(?u32, 1024), jpeg_info.width);
    try std.testing.expectEqual(@as(?u32, 768), jpeg_info.height);

    try std.testing.expectEqual(ImageFormat.unknown, sniffImage("hello").format);
}

test "sniffVideo identifies mp4 and matroska containers" {
    var mp4_buf: [16]u8 = undefined;
    const mp4 = mp4_buf[0..];
    @memset(mp4, 0);
    std.mem.writeInt(u32, mp4[0..4], 16, .big);
    @memcpy(mp4[4..8], "ftyp");
    @memcpy(mp4[8..12], "isom");
    try std.testing.expectEqual(VideoFormat.mp4, sniffVideo(mp4).format);

    var mkv_buf: [8]u8 = undefined;
    const mkv = mkv_buf[0..];
    @memcpy(mkv[0..4], &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 });
    @memset(mkv[4..8], 0);
    try std.testing.expectEqual(VideoFormat.matroska, sniffVideo(mkv).format);

    var webm_buf: [24]u8 = undefined;
    const webm = webm_buf[0..];
    @memcpy(webm[0..4], &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 });
    @memset(webm[4..], 0);
    @memcpy(webm[8..12], "webm");
    try std.testing.expectEqual(VideoFormat.webm, sniffVideo(webm).format);

    try std.testing.expectEqual(VideoFormat.unknown, sniffVideo("nope").format);
}

test "media inspectJson reports image metadata and hash" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-media";
    cwd.deleteTree(io, root_name) catch {};
    var sandbox = try Sandbox.init(io, std.testing.allocator, cwd, root_name, .{}, .{});
    defer {
        sandbox.deinit();
        cwd.deleteTree(io, root_name) catch {};
    }
    var media_v = Media.init(&sandbox);
    const media = &media_v;

    var png_buf: [33]u8 = undefined;
    const png = png_buf[0..];
    @memset(png, 0);
    @memcpy(png[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 32, .big);
    std.mem.writeInt(u32, png[20..24], 16, .big);
    try sandbox.root.writeFile(io, .{ .sub_path = "pic.png", .data = png, .flags = .{} });

    const json = try media.inspectJson(std.testing.allocator, "pic.png");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\":\"png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"width\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mime\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sha256\":\"") != null);

    try std.testing.expectError(error.PathTraversal, media.inspectJson(std.testing.allocator, "C:/Windows/a.png"));
}

test "media unsupported operations report honestly" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root_name = "zig-cache-pico-media-unsupported";
    cwd.deleteTree(io, root_name) catch {};
    var sandbox = try Sandbox.init(io, std.testing.allocator, cwd, root_name, .{}, .{});
    defer {
        sandbox.deinit();
        cwd.deleteTree(io, root_name) catch {};
    }
    var media_v = Media.init(&sandbox);
    const media = &media_v;

    const json = try media.unsupportedJson(std.testing.allocator, "clip.mp4", "video.extract_frame");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"supported\":false") != null);
}
