//! Terminal presentation layer for the CLI: colors, user-facing output on
//! stdout, and a debug gate for internal diagnostics (stderr).
//!
//! Rules:
//! - User-facing output goes to stdout and never contains credentials.
//! - Internal diagnostics ([HTTP], [Task], [Proposal], ...) only appear when
//!   debug mode is on, go to stderr, and are bounded: the API key, the
//!   Authorization header, and full provider bodies are never printed.
//! - Color uses ANSI codes. When `NO_COLOR` is set or stdout is not a
//!   terminal, codes resolve to empty strings (plain-text fallback).
//! - UI glyphs (`╭─│✓⚠✗├─└─⠋`) are emitted as raw UTF-8 bytes. On Windows the
//!   console output code page is switched to UTF-8 (CP 65001) best-effort; if
//!   that is not possible the UI falls back to pure-ASCII glyphs (`+ - | [ok]
//!   [!!] [x]`). `PICO_CLAW_ASCII=1` forces the ASCII fallback everywhere.

const std = @import("std");
const builtin = @import("builtin");

pub var debug_enabled: bool = false;

/// Set by the composition root during startup (see `init`).
pub var color_enabled: bool = true;

/// Set by the composition root during startup (see `init`). When false, all
/// UI glyphs are pure ASCII so terminals without UTF-8 support never render
/// mojibake. Assistant reply content is never transliterated either way.
pub var unicode_enabled: bool = true;

pub const Color = enum {
    cyan,
    green,
    yellow,
    red,
    dim,
    reset,

    pub fn code(self: Color) []const u8 {
        if (!color_enabled) return "";
        return switch (self) {
            .cyan => "\x1b[36m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .red => "\x1b[31m",
            .dim => "\x1b[2m",
            .reset => "\x1b[0m",
        };
    }
};

/// UI glyph set. The Unicode set is emitted as UTF-8 bytes; the ASCII set
/// keeps every byte <= 0x7f so legacy code pages cannot produce mojibake.
pub const Glyphs = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
    ok: []const u8,
    warn: []const u8,
    fail: []const u8,
    branch: []const u8,
    last_branch: []const u8,
    spinner: []const u8,
};

pub const unicode_glyphs = Glyphs{
    .top_left = "╭",
    .top_right = "╮",
    .bottom_left = "╰",
    .bottom_right = "╯",
    .horizontal = "─",
    .vertical = "│",
    .ok = "✓",
    .warn = "⚠",
    .fail = "✗",
    .branch = "├─ ",
    .last_branch = "└─ ",
    .spinner = "⠋",
};

pub const ascii_glyphs = Glyphs{
    .top_left = "+",
    .top_right = "+",
    .bottom_left = "+",
    .bottom_right = "+",
    .horizontal = "-",
    .vertical = "|",
    .ok = "[ok]",
    .warn = "[!!]",
    .fail = "[x]",
    .branch = "|-- ",
    .last_branch = "`-- ",
    .spinner = "...",
};

pub fn glyphs() *const Glyphs {
    return if (unicode_enabled) &unicode_glyphs else &ascii_glyphs;
}

const windows_console = struct {
    const CP_UTF8: std.os.windows.UINT = 65001;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: std.os.windows.UINT) std.os.windows.BOOL;
    extern "kernel32" fn GetConsoleOutputCP() std.os.windows.UINT;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) std.os.windows.BOOL;

    fn isConsole(file: std.Io.File) bool {
        var mode: std.os.windows.DWORD = 0;
        return GetConsoleMode(file.handle, &mode).toBool();
    }

    /// Best-effort: switch the attached console to UTF-8 so raw UTF-8 output
    /// renders correctly, and report whether Unicode output is safe. A pipe
    /// (MinTTY, pager, redirect) passes bytes through untouched: UTF-8 stays
    /// intact and is decoded by the receiving terminal, so Unicode stays on.
    fn enableUtf8() bool {
        const stdout = std.Io.File.stdout();
        if (!isConsole(stdout)) return true;
        _ = SetConsoleOutputCP(CP_UTF8);
        return GetConsoleOutputCP() == CP_UTF8;
    }
};

/// One-time setup. Color stays on for interactive terminals and is disabled
/// when `NO_COLOR` is set or stdout is piped (plain-text fallback). On
/// Windows the console output code page is switched to UTF-8 when possible;
/// otherwise the UI falls back to ASCII glyphs. `force_ascii` (from the
/// `PICO_CLAW_ASCII` environment variable) always selects ASCII glyphs.
pub fn init(io: std.Io, no_color_env: bool, force_ascii: bool) void {
    const tty = std.Io.File.stdout().isTty(io) catch true;
    color_enabled = tty and !no_color_env;
    unicode_enabled = true;
    if (builtin.os.tag == .windows) {
        unicode_enabled = windows_console.enableUtf8();
    }
    if (force_ascii) unicode_enabled = false;
}

pub fn setDebug(enabled: bool) void {
    debug_enabled = enabled;
}

/// User-facing formatted line on stdout. Formatting errors (line too long)
/// are ignored; use `writeRaw` for arbitrary-length content.
pub fn out(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// Verbatim content on stdout (assistant replies). No formatting, no
/// transliteration: the bytes are already UTF-8 from the provider pipeline.
pub fn writeRaw(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

/// Internal diagnostic on stderr; visible only with debug enabled. Bounded,
/// secret-free content only - never API keys, Authorization headers, or full
/// provider bodies.
pub fn debugOut(comptime format: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    std.debug.print(format, args);
}

pub const StatusKind = enum { ok, warn, fail };

/// Colored status line with a leading icon: check (ok), warning, cross (fail).
/// The icon comes from the active glyph set (Unicode or ASCII fallback).
pub fn statusLine(io: std.Io, kind: StatusKind, text: []const u8) void {
    const g = glyphs();
    var buffer: [1024]u8 = undefined;
    const line = switch (kind) {
        .ok => std.fmt.bufPrint(&buffer, "  {s}{s}{s} {s}", .{
            Color.green.code(), g.ok, Color.reset.code(), text,
        }) catch return,
        .warn => std.fmt.bufPrint(&buffer, "  {s}{s}{s} {s}", .{
            Color.yellow.code(), g.warn, Color.reset.code(), text,
        }) catch return,
        .fail => std.fmt.bufPrint(&buffer, "  {s}{s}{s} {s}", .{
            Color.red.code(), g.fail, Color.reset.code(), text,
        }) catch return,
    };
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
}

/// Key in dim, padded to 11 columns, then the value.
pub fn kv(io: std.Io, key: []const u8, value: []const u8) void {
    out(io, "  {s}{s:<11}{s}{s}\n", .{ Color.dim.code(), key, Color.reset.code(), value });
}

/// Section header inside a report (dim).
pub fn section(io: std.Io, text: []const u8) void {
    out(io, "\n  {s}{s}{s}\n", .{ Color.dim.code(), text, Color.reset.code() });
}

/// Tree item under a section: `├─ key  value` (or `|-- key value` in ASCII).
pub fn treeItem(io: std.Io, last: bool, key: []const u8, value: []const u8) void {
    const g = glyphs();
    out(io, "  {s}{s}{s} {s} {s}\n", .{
        Color.dim.code(), if (last) g.last_branch else g.branch, Color.reset.code(), key, value,
    });
}

/// Simple one-frame waiting state (no animation, no threads). Written only
/// when color/ANSI is available; cleared with a carriage return.
pub fn showThinking(io: std.Io) void {
    if (!color_enabled) return;
    out(io, "  {s} Thinking...", .{glyphs().spinner});
}

pub fn clearThinking(io: std.Io) void {
    if (!color_enabled) return;
    std.Io.File.stdout().writeStreamingAll(io, "\r\x1b[2K") catch {};
}

/// Format a count with a label into `buffer` (`"3 memories"`).
pub fn countLabel(buffer: []u8, count: usize, label: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, label }) catch "";
}

/// Banner used at startup: a light box around the product name. Unicode box
/// drawing when supported; a pure-ASCII `+ - |` box otherwise.
pub fn banner(io: std.Io, title: []const u8, subtitle: []const u8) void {
    const width: usize = 46;
    var buffer: [256]u8 = undefined;
    const g = glyphs();

    bannerEdge(io, &buffer, g.top_left, g.horizontal, width, g.top_right);
    bannerRow(io, &buffer, width, title);
    bannerRow(io, &buffer, width, subtitle);
    bannerEdge(io, &buffer, g.bottom_left, g.horizontal, width, g.bottom_right);
}

/// One banner edge: left corner + horizontal run + right corner.
fn bannerEdge(io: std.Io, buffer: []u8, left: []const u8, horizontal: []const u8, width: usize, right: []const u8) void {
    var used: usize = 0;
    @memcpy(buffer[used .. used + left.len], left);
    used += left.len;
    var remaining = width;
    while (remaining > 0) : (remaining -= 1) {
        @memcpy(buffer[used .. used + horizontal.len], horizontal);
        used += horizontal.len;
    }
    @memcpy(buffer[used .. used + right.len], right);
    used += right.len;
    out(io, "{s}{s}{s}\n", .{ Color.cyan.code(), buffer[0..used], Color.reset.code() });
}

fn bannerRow(io: std.Io, buffer: []u8, width: usize, text: []const u8) void {
    const g = glyphs();
    if (2 + text.len + 1 > width) {
        const row = std.fmt.bufPrint(buffer, "{s}  {s}", .{ g.vertical, text }) catch return;
        out(io, "{s}{s}{s}\n", .{ Color.cyan.code(), row, Color.reset.code() });
        return;
    }
    var used: usize = 0;
    @memcpy(buffer[used .. used + g.vertical.len], g.vertical);
    used += g.vertical.len;
    buffer[used] = ' ';
    used += 1;
    buffer[used] = ' ';
    used += 1;
    @memcpy(buffer[used .. used + text.len], text);
    used += text.len;
    const spaces = width - 2 - text.len;
    @memset(buffer[used .. used + spaces], ' ');
    used += spaces;
    @memcpy(buffer[used .. used + g.vertical.len], g.vertical);
    used += g.vertical.len;
    out(io, "{s}{s}{s}\n", .{ Color.cyan.code(), buffer[0..used], Color.reset.code() });
}

test "color codes resolve to plain text when disabled" {
    const original = color_enabled;
    defer color_enabled = original;

    color_enabled = false;
    try std.testing.expectEqualStrings("", Color.cyan.code());
    try std.testing.expectEqualStrings("", Color.reset.code());

    color_enabled = true;
    try std.testing.expect(Color.cyan.code().len > 0);
    try std.testing.expect(Color.dim.code().len > 0);
}

test "countLabel formats count with label" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3 memories", countLabel(&buffer, 3, "memories"));
    try std.testing.expectEqualStrings("0 entries", countLabel(&buffer, 0, "entries"));
    try std.testing.expectEqualStrings("", countLabel(&buffer, 1, "way-too-long-label-for-this-buffer-xx"));
}

// UTF-8 integrity: glyph constants are compared against independently written
// byte literals (not against themselves), so a double-encoding or a corrupted
// source-file encoding would fail these tests.

test "unicode glyphs are exactly the intended utf-8 bytes" {
    // U+256D ╭, U+2500 ─, U+2713 ✓, U+2502 │, U+251C ├, U+280B ⠋.
    try std.testing.expectEqualStrings("\xe2\x95\xad", unicode_glyphs.top_left);
    try std.testing.expectEqualStrings("\xe2\x94\x80", unicode_glyphs.horizontal);
    try std.testing.expectEqualStrings("\xe2\x9c\x93", unicode_glyphs.ok);
    try std.testing.expectEqualStrings("\xe2\x94\x82", unicode_glyphs.vertical);
    try std.testing.expectEqualStrings("\xe2\x94\x9c\xe2\x94\x80 ", unicode_glyphs.branch);
    try std.testing.expectEqualStrings("\xe2\xa0\x8b", unicode_glyphs.spinner);
}

test "unicode glyphs are single-encoded valid utf-8" {
    inline for (@typeInfo(Glyphs).@"struct".fields) |field| {
        const value = @field(unicode_glyphs, field.name);
        try std.testing.expect(std.unicode.utf8ValidateSlice(value));
        // Double-encoding (UTF-8 read as Latin-1 and re-encoded) always
        // produces 0xc2/0xc3 lead bytes; the U+25xx/U+27xx/U+28xx ranges
        // used here never contain them.
        try std.testing.expect(std.mem.indexOfScalar(u8, value, 0xc2) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, value, 0xc3) == null);
    }
}

test "ascii glyph set contains only ascii bytes and is selected by flag" {
    inline for (@typeInfo(Glyphs).@"struct".fields) |field| {
        const value = @field(ascii_glyphs, field.name);
        for (value) |byte| try std.testing.expect(byte <= 0x7f);
    }

    const original = unicode_enabled;
    defer unicode_enabled = original;

    unicode_enabled = true;
    try std.testing.expectEqualStrings("✓", glyphs().ok);
    unicode_enabled = false;
    try std.testing.expectEqualStrings("[ok]", glyphs().ok);
    try std.testing.expectEqualStrings("|", glyphs().vertical);
}
