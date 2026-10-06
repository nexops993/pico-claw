const std = @import("std");
const builtin = @import("builtin");

/// Minimal `.env` support: KEY=VALUE pairs loaded into the process
/// environment map before anything reads it. No dependency, no shell.
///
/// Rules (kept deliberately small and predictable):
/// - blank lines and lines starting with `#` are ignored;
/// - an optional leading `export ` is allowed;
/// - the first `=` separates key and value; both sides are trimmed;
/// - matching surrounding quotes (`'` or `"`) are stripped from the value;
/// - inline comments are NOT stripped: put comments on their own line;
/// - keys are used verbatim (case-sensitive) and must be non-empty;
/// - existing variables always win: `.env` never overrides the real
///   environment.
///
/// Values are never logged: warnings carry the line number only.
pub const ParsedLine = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseError = error{InvalidLine};

/// Parse one `.env` line. Returns null for blank lines and comments,
/// `error.InvalidLine` for malformed lines, and the parsed pair otherwise.
/// The returned slices borrow from `line`.
pub fn parseLine(line: []const u8) ParseError!?ParsedLine {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#') return null;

    var rest = trimmed;
    if (std.mem.startsWith(u8, rest, "export ") or std.mem.startsWith(u8, rest, "export\t")) {
        rest = std.mem.trim(u8, rest["export ".len..], " \t");
    }

    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidLine;
    const key = std.mem.trim(u8, rest[0..eq], " \t");
    if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidLine;

    var value = std.mem.trim(u8, rest[eq + 1 ..], " \t");
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            value = value[1 .. value.len - 1];
        }
    }
    if (std.mem.indexOfScalar(u8, key, 0) != null or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidLine;
    }
    return .{ .key = key, .value = value };
}

pub const max_env_file_bytes: usize = 64 * 1024;

/// Load KEY=VALUE pairs from `path` (relative to `dir`) into `map`. Variables
/// that already exist in the map are never overridden. Returns the number of
/// variables that were set. Malformed lines are skipped with a warning that
/// names the line number only — never the line content, which may hold a
/// secret. File-not-found is not an error: it simply loads nothing.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    map: *std.process.Environ.Map,
) !usize {
    const contents = dir.readFileAlloc(io, path, allocator, .limited(max_env_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(contents);

    var loaded: usize = 0;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        const parsed = parseLine(line) catch |err| switch (err) {
            error.InvalidLine => {
                if (!builtin.is_test) {
                    std.debug.print("[Env] Skipping invalid .env line {d}\n", .{line_number});
                }
                continue;
            },
        };
        const entry = parsed orelse continue;
        if (map.get(entry.key) != null) continue; // real environment wins
        map.put(entry.key, entry.value) catch continue;
        loaded += 1;
    }
    return loaded;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseLine handles comments export quotes and rejects malformed lines" {
    // Blank lines and comments.
    try std.testing.expect((try parseLine("")) == null);
    try std.testing.expect((try parseLine("   \t\r")) == null);
    try std.testing.expect((try parseLine("# comment")) == null);
    try std.testing.expect((try parseLine("  # indented comment")) == null);

    // Basic pair.
    const basic = (try parseLine("PICO_CLAW_API_KEY=abc")).?;
    try std.testing.expectEqualStrings("PICO_CLAW_API_KEY", basic.key);
    try std.testing.expectEqualStrings("abc", basic.value);

    // Trimming, export prefix, and quoted values (inner spaces survive).
    const fancy = (try parseLine("  export  PICO_CLAW_API_KEY = \" abc \"  ")).?;
    try std.testing.expectEqualStrings("PICO_CLAW_API_KEY", fancy.key);
    try std.testing.expectEqualStrings(" abc ", fancy.value);

    const single = (try parseLine("KEY='v'")).?;
    try std.testing.expectEqualStrings("v", single.value);

    // Inline comments are not stripped (documented behavior).
    const hash = (try parseLine("KEY=a#b")).?;
    try std.testing.expectEqualStrings("a#b", hash.value);

    // Malformed lines.
    try std.testing.expectError(error.InvalidLine, parseLine("NO_EQUALS"));
    try std.testing.expectError(error.InvalidLine, parseLine("=value"));
    try std.testing.expectError(error.InvalidLine, parseLine("export =value"));
    try std.testing.expectError(error.InvalidLine, parseLine("= "));
}

test "load injects missing variables and never overrides existing ones" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();
    try map.put("EXISTING", "from-environment");

    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data =
        \\# comment
        \\PICO_CLAW_API_KEY=from-dotenv
        \\EXISTING=ignored
        \\BAD LINE WITHOUT EQUALS
        \\
        \\EMPTY_VALUE=
    });

    const loaded = try load(allocator, io, tmp.dir, ".env", &map);
    try std.testing.expectEqual(@as(usize, 2), loaded);
    try std.testing.expectEqualStrings("from-environment", map.get("EXISTING").?);
    try std.testing.expectEqualStrings("from-dotenv", map.get("PICO_CLAW_API_KEY").?);
    try std.testing.expectEqualStrings("", map.get("EMPTY_VALUE").?);
}

test "load returns zero when the file is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();
    const loaded = try load(allocator, io, tmp.dir, ".env", &map);
    try std.testing.expectEqual(@as(usize, 0), loaded);
    try std.testing.expect(map.get("PICO_CLAW_API_KEY") == null);
}
