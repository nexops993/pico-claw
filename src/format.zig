//! Markdown-to-Telegram-HTML formatting shared by the Telegram channel and
//! the web dashboard chat view.
//!
//! Model output is arbitrary and often malformed Markdown, so the formatter
//! is deliberately conservative and repair-oriented:
//!
//! - Every `<`, `>`, and `&` outside known-safe generated tags is escaped
//!   (including inside code blocks), so the output is always valid Telegram
//!   `parse_mode=HTML` and safe to embed in the dashboard.
//! - Supported Markdown: bold `**x**`, italic `*x*`, strikethrough `~~x~~`,
//!   inline code, fenced code blocks with an optional language tag, ATX
//!   headings (`#`..`######`), `-`/`*` bullet lists, and `[text](url)` links
//!   with `http`/`https`/`telegram` schemes only.
//! - Unclosed emphasis or inline code at end of line is auto-closed (valid
//!   HTML, marker characters dropped); an unclosed fence at end of input is
//!   auto-closed as well. Snake_case identifiers are never touched (`_` is
//!   literal, unlike Telegram MarkdownV1).
//! - `chunkAndFormat` splits long replies into Telegram-sized parts: parts
//!   break at line boundaries, never split a UTF-8 sequence, keep code fences
//!   open across parts (each part re-opens and re-closes `<pre>`), and every
//!   returned part is valid HTML within the limit by construction.

const std = @import("std");

pub const FormatError = error{OutOfMemory};

/// Default part size target for `chunkAndFormat` (margin below Telegram's
/// 4096-character hard limit; callers pass their own constant explicitly).
pub const default_part_limit: usize = 4000;

/// Hard floor for chunking; below this the splitting invariants cannot hold
/// (a worst-case fence-open tag is 62 bytes and must always fit a fresh part).
pub const min_part_limit: usize = 128;

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

/// Escape `&`, `<`, and `>` for Telegram HTML and HTML embedding generally.
/// All other bytes (including arbitrary UTF-8 and emoji) pass through.
pub fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) FormatError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try escapeInto(allocator, &out, text);
    return out.toOwnedSlice(allocator);
}

fn escapeInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) FormatError!void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const entity: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (entity) |value| {
            try out.appendSlice(allocator, text[start..index]);
            try out.appendSlice(allocator, value);
            start = index + 1;
        }
    }
    try out.appendSlice(allocator, text[start..]);
}

// ---------------------------------------------------------------------------
// Fenced code blocks
// ---------------------------------------------------------------------------

/// If `line` opens a fenced code block, return the raw fence info string
/// (everything after the backticks); otherwise null.
pub fn fenceOpen(line: []const u8) ?[]const u8 {
    const trimmed_start = std.mem.trimStart(u8, line, " ");
    if (trimmed_start.len < 3) return null;
    var ticks: usize = 0;
    for (trimmed_start) |byte| {
        if (byte != '`') break;
        ticks += 1;
    }
    if (ticks != 3) return null;
    // An info string means an opening fence; a bare ``` may open or close
    // depending on the current state, which callers resolve.
    return trimmed_start[3..];
}

/// Whether `line` closes the current fenced code block.
pub fn isFenceClose(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 3) return false;
    for (trimmed) |byte| {
        if (byte != '`') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Inline span rendering
// ---------------------------------------------------------------------------

const Tag = enum { bold, italic, strike };

const span_open_tags = [_][]const u8{ "<b>", "<i>", "<s>" };
const span_close_tags = [_][]const u8{ "</b>", "</i>", "</s>" };

/// Render one line's inline spans (bold, italic, strike, inline code, links)
/// into `out`, escaping everything else. Unclosed markers are auto-closed at
/// end of line so the output stays valid. A trailing newline is not added.
fn renderSpans(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) FormatError!void {
    // Pre-pass: a backtick with no partner on this line is literal text, not
    // an inline-code opener (prevents swallowing stray characters).
    var tick_count: usize = 0;
    for (text) |byte| {
        if (byte == '`') tick_count += 1;
    }
    var literal_tick_at: ?usize = null;
    if (tick_count % 2 == 1) {
        var index: usize = text.len;
        while (index > 0) {
            index -= 1;
            if (text[index] == '`') {
                literal_tick_at = index;
                break;
            }
        }
    }

    var stack: [8]Tag = undefined;
    var depth: usize = 0;
    var in_code = false;
    var start: usize = 0;
    var index: usize = 0;

    while (index < text.len) {
        const rest = text[index..];
        if (in_code) {
            if (rest[0] == '`' and index != literal_tick_at) {
                try escapeInto(allocator, out, text[start..index]);
                try out.appendSlice(allocator, "</code>");
                in_code = false;
                index += 1;
                start = index;
                continue;
            }
            index += 1;
            continue;
        }
        switch (rest[0]) {
            '`' => {
                if (index == literal_tick_at) {
                    index += 1;
                    continue;
                }
                try escapeInto(allocator, out, text[start..index]);
                try out.appendSlice(allocator, "<code>");
                in_code = true;
                index += 1;
                start = index;
                continue;
            },
            '*' => {
                if (std.mem.startsWith(u8, rest, "**")) {
                    try escapeInto(allocator, out, text[start..index]);
                    try toggle(allocator, out, &stack, &depth, .bold);
                    index += 2;
                    start = index;
                    continue;
                }
                try escapeInto(allocator, out, text[start..index]);
                try toggle(allocator, out, &stack, &depth, .italic);
                index += 1;
                start = index;
                continue;
            },
            '~' => {
                if (std.mem.startsWith(u8, rest, "~~")) {
                    try escapeInto(allocator, out, text[start..index]);
                    try toggle(allocator, out, &stack, &depth, .strike);
                    index += 2;
                    start = index;
                    continue;
                }
            },
            '[' => {
                if (try renderLink(allocator, out, text[index..])) |consumed| {
                    try escapeInto(allocator, out, text[start..index]);
                    index += consumed;
                    start = index;
                    continue;
                }
            },
            else => {},
        }
        index += 1;
    }

    try escapeInto(allocator, out, text[start..]);
    // Auto-close anything left open so the line is always valid HTML.
    while (depth > 0) {
        depth -= 1;
        try out.appendSlice(allocator, span_close_tags[@intFromEnum(stack[depth])]);
    }
    if (in_code) try out.appendSlice(allocator, "</code>");
}

/// Open or close an emphasis tag. A marker only closes the matching top-of
/// stack tag; a mismatched closer is treated as open (repair-oriented).
fn toggle(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stack: *[8]Tag,
    depth: *usize,
    tag: Tag,
) FormatError!void {
    if (depth.* > 0 and stack[depth.* - 1] == tag) {
        depth.* -= 1;
        try out.appendSlice(allocator, span_close_tags[@intFromEnum(tag)]);
        return;
    }
    if (depth.* == stack.len) return; // too deep; drop the marker silently
    stack[depth.*] = tag;
    depth.* += 1;
    try out.appendSlice(allocator, span_open_tags[@intFromEnum(tag)]);
}

/// Try to render `[text](url)` at the start of `rest`. Returns the number of
/// bytes consumed on success (anchor already appended), null when the input
/// is not a link with an allowed scheme.
fn renderLink(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rest: []const u8,
) FormatError!?usize {
    const close_bracket = std.mem.indexOfScalarPos(u8, rest, 1, ']') orelse return null;
    if (close_bracket + 1 >= rest.len or rest[close_bracket + 1] != '(') return null;
    const url_start = close_bracket + 2;
    const close_paren = std.mem.indexOfScalarPos(u8, rest, url_start, ')') orelse return null;
    const label = rest[1..close_bracket];
    const url = rest[url_start..close_paren];
    if (label.len == 0 or url.len == 0) return null;

    const schemes = [_][]const u8{ "http://", "https://", "telegram://" };
    var allowed = false;
    for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) {
            allowed = true;
            break;
        }
    }
    if (!allowed) return null;
    if (std.mem.indexOfAny(u8, url, "\"' <>") != null) return null;

    try out.appendSlice(allocator, "<a href=\"");
    try escapeInto(allocator, out, url);
    try out.appendSlice(allocator, "\">");
    try escapeInto(allocator, out, label);
    try out.appendSlice(allocator, "</a>");
    return close_paren + 1;
}

/// Render one full non-code line: heading/bullet prefixes first, then spans.
/// `allow_prefix` is false for continuation pieces of a hard-split line so
/// split fragments cannot gain a bullet or heading marker they never had.
fn renderLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    allow_prefix: bool,
) FormatError!void {
    const content = std.mem.trimEnd(u8, line, "\r");
    if (allow_prefix) {
        if (headingDepth(content)) |rest| {
            if (rest.len > 0) {
                try out.appendSlice(allocator, "<b>");
                try renderSpans(allocator, out, rest);
                try out.appendSlice(allocator, "</b>");
            }
            return;
        }
        for ([_][]const u8{ "- ", "* ", "• " }) |marker| {
            if (std.mem.startsWith(u8, content, marker)) {
                try out.appendSlice(allocator, "• ");
                try renderSpans(allocator, out, content[marker.len..]);
                return;
            }
        }
    }
    try renderSpans(allocator, out, content);
}

/// `#`..`######` followed by a space at line start; returns the remainder.
fn headingDepth(line: []const u8) ?[]const u8 {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) level += 1;
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return line[level + 1 ..];
}

// ---------------------------------------------------------------------------
// Whole-message formatting and Telegram-sized chunking
// ---------------------------------------------------------------------------

const max_language_len = 24;
const pre_close = "</code></pre>";

/// One formatted message part. `html` is valid Telegram HTML owned by the
/// caller (see `freeParts`).
pub const Part = struct {
    html: []u8,
};

/// Free a value returned by `chunkAndFormat`.
pub fn freeParts(allocator: std.mem.Allocator, parts: []Part) void {
    for (parts) |part| allocator.free(part.html);
    allocator.free(parts);
}

/// Format a complete Markdown message into one HTML string (no chunking).
/// Used by the dashboard, which has no message-size limit.
pub fn format(allocator: std.mem.Allocator, markdown: []const u8) FormatError![]u8 {
    const parts = try chunkAndFormat(allocator, markdown, std.math.maxInt(usize));
    defer freeParts(allocator, parts);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts) |part| {
        try out.appendSlice(allocator, part.html);
    }
    return out.toOwnedSlice(allocator);
}

/// Split `markdown` into message parts of at most `limit` bytes. Invariants:
/// - every part is valid HTML within `limit` (an open code fence is closed at
///   the end of a part and re-opened at the start of the next one),
/// - UTF-8 sequences are never split,
/// - parts appear in input order and blank-line structure is preserved.
pub fn chunkAndFormat(
    allocator: std.mem.Allocator,
    markdown: []const u8,
    limit: usize,
) FormatError![]Part {
    const part_limit = @max(limit, min_part_limit);

    var parts: std.ArrayList(Part) = .empty;
    errdefer {
        for (parts.items) |*part| allocator.free(part.html);
        parts.deinit(allocator);
    }

    var in_code = false;
    var language: [max_language_len]u8 = undefined;
    var language_len: usize = 0;

    var part: std.ArrayList(u8) = .empty;
    defer part.deinit(allocator);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);
    // Fence tags are rendered here so `scratch` (and thus the borrowed
    // `rendered` slice) is never mutated while `rendered` is still in use.
    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(allocator);

    var rest = markdown;
    while (rest.len > 0) {
        const newline = std.mem.indexOfScalar(u8, rest, '\n');
        const raw_line = if (newline) |index| rest[0..index] else rest;

        // Classify and render the line against the current state.
        var rendered: []const u8 = "";
        var in_code_after = in_code;

        if (in_code) {
            if (isFenceClose(raw_line)) {
                in_code_after = false;
                rendered = pre_close;
            } else {
                scratch.clearRetainingCapacity();
                try escapeInto(allocator, &scratch, std.mem.trimEnd(u8, raw_line, "\r"));
                rendered = scratch.items;
            }
        } else if (fenceOpen(raw_line)) |info| {
            in_code_after = true;
            language_len = sanitizeLanguage(&language, std.mem.trim(u8, info, " \t\r")).len;
            tag.clearRetainingCapacity();
            try appendFenceOpen(allocator, &tag, language[0..language_len]);
            rendered = tag.items;
        } else {
            scratch.clearRetainingCapacity();
            try renderLine(allocator, &scratch, raw_line, true);
            rendered = scratch.items;
        }

        // Close the current part when this line would not fit anymore.
        const overhead_after: usize = if (in_code_after) pre_close.len else 0;
        if (part.items.len + rendered.len + 1 + overhead_after > part_limit) {
            try flushPart(allocator, &parts, &part, in_code);
            if (in_code) {
                // The fence is still logically open: re-open it in the fresh
                // part so code keeps rendering as code across parts.
                tag.clearRetainingCapacity();
                try appendFenceOpen(allocator, &tag, language[0..language_len]);
                try part.appendSlice(allocator, tag.items);
            }
        }

        if (part.items.len + rendered.len + 1 + overhead_after > part_limit) {
            // One line too large even for a fresh part (fence tags are far
            // below `min_part_limit`, so this is only ever content): split
            // the raw line into pieces that each fit the remaining room.
            try appendOverlongLine(
                allocator,
                &parts,
                &part,
                &scratch,
                raw_line,
                part_limit,
                in_code,
                language[0..language_len],
            );
        } else {
            try part.appendSlice(allocator, rendered);
            try part.append(allocator, '\n');
        }

        in_code = in_code_after;
        if (newline) |index| {
            rest = rest[index + 1 ..];
        } else {
            rest = rest[rest.len..];
        }
    }

    try flushPart(allocator, &parts, &part, in_code);
    return parts.toOwnedSlice(allocator);
}

/// Append `<pre><code>` (optionally with a sanitized language class). Worst
/// case size is 62 bytes, which is why `min_part_limit` is 128.
fn appendFenceOpen(allocator: std.mem.Allocator, out: *std.ArrayList(u8), language: []const u8) FormatError!void {
    try out.appendSlice(allocator, "<pre><code");
    if (language.len > 0) {
        try out.appendSlice(allocator, " class=\"language-");
        try out.appendSlice(allocator, language);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, ">");
}

/// Finalize the current part: close an open fence, store the part, reset.
fn flushPart(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(Part),
    part: *std.ArrayList(u8),
    in_code: bool,
) FormatError!void {
    if (in_code and part.items.len > 0) {
        // The fence opened in this part but never closed in it: repair the
        // part so it stays valid HTML. The next part re-opens the fence.
        try part.appendSlice(allocator, pre_close);
    }
    if (part.items.len > 0) {
        try parts.append(allocator, .{ .html = try part.toOwnedSlice(allocator) });
    }
    part.clearRetainingCapacity();
}

/// Append one raw line that cannot fit as a whole: cut the raw text into
/// pieces (UTF-8-safe, preferring spaces for prose) and render each piece
/// with the current state. Continuation pieces never gain bullet/heading
/// prefixes, and code pieces keep their fence (already re-opened by the
/// caller when the part boundary was crossed).
fn appendOverlongLine(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(Part),
    part: *std.ArrayList(u8),
    scratch: *std.ArrayList(u8),
    raw_line: []const u8,
    part_limit: usize,
    in_code: bool,
    language: []const u8,
) FormatError!void {
    var remaining = raw_line;
    var first_piece = true;
    while (remaining.len > 0) {
        const overhead: usize = if (in_code) pre_close.len else 0;
        if (part.items.len + overhead + 32 >= part_limit) {
            // No room for even a small piece: close the part (and the fence
            // view of it), then re-open the fence in a fresh part.
            try flushPart(allocator, parts, part, in_code);
            if (in_code) {
                scratch.clearRetainingCapacity();
                try appendFenceOpen(allocator, scratch, language);
                try part.appendSlice(allocator, scratch.items);
            }
        }

        const avail = part_limit -| part.items.len -| overhead -| 1;
        // Start optimistic and halve on overflow; the floor of 4 bytes (one
        // maximum UTF-8 sequence) always renders within `avail` because the
        // minimum part limit keeps at least ~50 bytes of render room.
        var raw_budget = @max(avail, 4);
        var end: usize = 0;
        while (true) {
            end = nextPieceEnd(remaining, raw_budget, !in_code and first_piece);
            scratch.clearRetainingCapacity();
            if (in_code) {
                try escapeInto(allocator, scratch, remaining[0..end]);
            } else {
                try renderLine(allocator, scratch, remaining[0..end], first_piece);
            }
            if (scratch.items.len <= avail or raw_budget <= 4) break;
            raw_budget = @max(raw_budget / 2, 4);
        }

        try part.appendSlice(allocator, scratch.items);
        if (!in_code or end >= remaining.len) {
            // Prose pieces wrap onto their own line; code pieces stay
            // continuous within a part and only the final one ends the line.
            try part.append(allocator, '\n');
        }
        remaining = remaining[end..];
        first_piece = false;
    }
}

/// End offset of the next raw piece of at most `budget` bytes. Backs off to a
/// UTF-8 sequence boundary and, for prose, to the last space in the final
/// quarter so words are not torn apart.
fn nextPieceEnd(text: []const u8, budget: usize, prefer_space: bool) usize {
    if (text.len <= budget) return text.len;
    var cut = budget;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    if (prefer_space and cut > budget / 4) {
        if (std.mem.lastIndexOfScalar(u8, text[0..cut], ' ')) |space| {
            if (space + 1 >= budget / 4) cut = space + 1;
        }
    }
    if (cut == 0) cut = 1;
    return cut;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormatEquals(expected: []const u8, markdown: []const u8) !void {
    const html = try format(testing.allocator, markdown);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(expected, html);
}

test "escapeHtml escapes & < > and passes unicode through" {
    const allocator = testing.allocator;

    const escaped = try escapeHtml(allocator, "a < b & c > d");
    defer allocator.free(escaped);
    try testing.expectEqualStrings("a &lt; b &amp; c &gt; d", escaped);

    const plain = try escapeHtml(allocator, "Halo 👋 — café");
    defer allocator.free(plain);
    try testing.expectEqualStrings("Halo 👋 — café", plain);

    const empty = try escapeHtml(allocator, "");
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "format renders bold italic strike and inline code" {
    try expectFormatEquals(
        "<b>bold</b> and <i>italic</i> and <s>strike</s> and <code>code</code>\n",
        "**bold** and *italic* and ~~strike~~ and `code`",
    );
}

test "format escapes html chars and keeps snake_case intact" {
    try expectFormatEquals(
        "use snake_case_name and 2 &lt; 3 &amp; 4 &gt; 1\n",
        "use snake_case_name and 2 < 3 & 4 > 1",
    );
}

test "format renders fenced code with language and escaped content" {
    const markdown =
        \\```python
        \\if a < b & c > d:
        \\    pass
        \\```
    ;
    try expectFormatEquals(
        "<pre><code class=\"language-python\">\nif a &lt; b &amp; c &gt; d:\n    pass\n</code></pre>\n",
        markdown,
    );
}

test "format repairs unclosed bold and unclosed fences into valid html" {
    try expectFormatEquals("<b>Pico Claw</b>\n", "**Pico Claw");

    const html = try format(testing.allocator, "```\njust text");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<pre><code>\njust text\n</code></pre>", html);
}

test "format renders headings bullets and keeps numbered lists" {
    try expectFormatEquals(
        "<b>Title</b>\n• one\n• two\n1. three\n",
        "# Title\n- one\n* two\n1. three",
    );
    // A `#` without a following space is literal text.
    try expectFormatEquals("#hashtag\n", "#hashtag");
}

test "format renders safe links and leaves unsafe schemes literal" {
    try expectFormatEquals(
        "<a href=\"https://example.com\">site</a> and [bad](ftp://x) and [rel](/local)\n",
        "[site](https://example.com) and [bad](ftp://x) and [rel](/local)",
    );
}

test "format handles emoji unicode and stray backticks without corruption" {
    try expectFormatEquals("Halo 👋 — café ✓\n", "Halo 👋 — café ✓");

    // An odd number of backticks leaves the stray one as literal text.
    const html = try format(testing.allocator, "a ` b ` c d `");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("a <code> b </code> c d `\n", html);
}

test "format renders the reported model output sample without raw markdown" {
    const markdown = "**Pico Claw**\n**Kalkulator** — Menghitung...\n- **Filesystem** — Membaca dan menulis...";
    const html = try format(testing.allocator, markdown);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<b>Pico Claw</b>\n<b>Kalkulator</b> — Menghitung...\n• <b>Filesystem</b> — Membaca dan menulis...\n",
        html,
    );
    try testing.expect(std.mem.indexOf(u8, html, "**") == null);
}

test "sanitizeLanguage keeps safe tokens and drops everything else" {
    var buffer: [max_language_len]u8 = undefined;

    try testing.expectEqualStrings("python", sanitizeLanguage(&buffer, "python"));
    try testing.expectEqualStrings("c++", sanitizeLanguage(&buffer, "c++"));
    try testing.expectEqualStrings("py", sanitizeLanguage(&buffer, "py thon"));
    try testing.expectEqual(@as(usize, 0), sanitizeLanguage(&buffer, "<script>").len);

    const long = "a" ** (max_language_len + 10);
    try testing.expectEqual(max_language_len, sanitizeLanguage(&buffer, long).len);
}

test "fence helpers classify opening and closing lines" {
    try testing.expectEqualStrings("python", fenceOpen("```python").?);
    try testing.expectEqualStrings("", fenceOpen("```").?);
    try testing.expectEqualStrings("", fenceOpen("   ```").?);
    try testing.expect(fenceOpen("text") == null);
    try testing.expect(fenceOpen("````") == null);
    try testing.expect(isFenceClose("```"));
    try testing.expect(isFenceClose("  ```  "));
    try testing.expect(!isFenceClose("```rust"));
}

test "chunkAndFormat keeps short messages whole" {
    const allocator = testing.allocator;

    const parts = try chunkAndFormat(allocator, "short reply", default_part_limit);
    defer freeParts(allocator, parts);
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("short reply\n", parts[0].html);
}

test "chunkAndFormat returns no parts for empty input" {
    const allocator = testing.allocator;

    const parts = try chunkAndFormat(allocator, "", 4000);
    defer freeParts(allocator, parts);
    try testing.expectEqual(@as(usize, 0), parts.len);

    const html = try format(allocator, "");
    defer allocator.free(html);
    try testing.expectEqualStrings("", html);
}

test "chunkAndFormat splits long replies within the limit in order" {
    const allocator = testing.allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var buffer: [40]u8 = undefined;
    for (0..300) |index| {
        const line = try std.fmt.bufPrint(&buffer, "plain line number {d} with words\n", .{index});
        try text.appendSlice(allocator, line);
    }

    const parts = try chunkAndFormat(allocator, text.items, 400);
    defer freeParts(allocator, parts);
    try testing.expect(parts.len > 1);

    var newlines: usize = 0;
    for (parts) |part| {
        try testing.expect(part.html.len <= 400);
        try testing.expect(std.unicode.utf8ValidateSlice(part.html));
        try testing.expect(std.mem.indexOf(u8, part.html, "<pre>") == null);
        newlines += std.mem.count(u8, part.html, "\n");
    }
    // Every source line survives as exactly one rendered newline.
    try testing.expectEqual(@as(usize, 300), newlines);
}

test "chunkAndFormat never splits utf-8 sequences of emoji" {
    const allocator = testing.allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const emoji = "😀🙂🚀🔥";
    for (0..1500) |_| {
        try text.appendSlice(allocator, emoji);
    }

    const parts = try chunkAndFormat(allocator, text.items, 400);
    defer freeParts(allocator, parts);
    try testing.expect(parts.len > 1);

    var found: usize = 0;
    for (parts) |part| {
        try testing.expect(part.html.len <= 400);
        try testing.expect(std.unicode.utf8ValidateSlice(part.html));
        // Count a single 4-byte emoji: piece boundaries are always
        // character-aligned, so no occurrence can ever be split.
        found += std.mem.count(u8, part.html, "🙂");
    }
    try testing.expectEqual(@as(usize, 1500), found);
}

test "chunkAndFormat keeps code fences valid across parts" {
    const allocator = testing.allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "before\n```python\ndef run():\n");
    var buffer: [40]u8 = undefined;
    for (0..120) |index| {
        const line = try std.fmt.bufPrint(&buffer, "    x{d} = {d}  # step\n", .{ index, index });
        try text.appendSlice(allocator, line);
    }
    try text.appendSlice(allocator, "```\nafter\n");

    const parts = try chunkAndFormat(allocator, text.items, 300);
    defer freeParts(allocator, parts);
    try testing.expect(parts.len > 1);

    for (parts) |part| {
        try testing.expect(part.html.len <= 300);
        try testing.expect(std.unicode.utf8ValidateSlice(part.html));
        // Each part is a complete, valid code block: exactly one open and
        // one close (the language class may be present only in the first).
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, part.html, "<pre>"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, part.html, "</code></pre>"));
    }
    try testing.expect(std.mem.indexOf(u8, parts[0].html, "language-python") != null);
    // Order and content: the prose around the block survives intact.
    try testing.expect(std.mem.startsWith(u8, parts[0].html, "before\n"));
    try testing.expect(std.mem.endsWith(u8, parts[parts.len - 1].html, "after\n"));
}

test "chunkAndFormat hard-splits a single overlong line" {
    const allocator = testing.allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..4000) |_| {
        try text.append(allocator, 'a');
    }

    const parts = try chunkAndFormat(allocator, text.items, 300);
    defer freeParts(allocator, parts);
    try testing.expect(parts.len > 1);

    var total: usize = 0;
    for (parts) |part| {
        try testing.expect(part.html.len <= 300);
        try testing.expect(std.unicode.utf8ValidateSlice(part.html));
        total += std.mem.count(u8, part.html, "a");
    }
    try testing.expectEqual(@as(usize, 4000), total);
}

test "chunkAndFormat hard-splits a long code line without breaking html" {
    const allocator = testing.allocator;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "```js\nconst x = \"");
    for (0..1200) |_| {
        try text.appendSlice(allocator, "<&>");
    }
    try text.appendSlice(allocator, "\";\n```\ndone\n");

    const parts = try chunkAndFormat(allocator, text.items, 400);
    defer freeParts(allocator, parts);
    try testing.expect(parts.len > 1);

    var ampersands: usize = 0;
    for (parts) |part| {
        try testing.expect(part.html.len <= 400);
        try testing.expect(std.unicode.utf8ValidateSlice(part.html));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, part.html, "<pre>"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, part.html, "</code></pre>"));
        ampersands += std.mem.count(u8, part.html, "&amp;");
    }
    // All 1200 raw ampersands escaped, none lost across the splits.
    try testing.expectEqual(@as(usize, 1200), ampersands);
    try testing.expect(std.mem.endsWith(u8, parts[parts.len - 1].html, "done\n"));
}

/// Sanitize a fence info string into a safe code-language class value, or an
/// empty slice when it is empty or contains anything outside `[A-Za-z0-9+_-.]`.
pub fn sanitizeLanguage(buffer: []u8, raw: []const u8) []const u8 {
    var used: usize = 0;
    for (raw) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '_' or byte == '.';
        if (!ok) return buffer[0..used];
        if (used == buffer.len) return buffer[0..used];
        buffer[used] = byte;
        used += 1;
    }
    return buffer[0..used];
}
