//! Unicode text segmentation and terminal cell width utilities.
//!
//! The public API is intentionally small: iterate UTF-8 input by extended
//! grapheme cluster and ask how many fixed-width terminal cells each cluster
//! occupies.

const std = @import("std");
const unicode_data = @import("unicode_data.zig");

const Gbp = unicode_data.GraphemeBreakProperty;
const Icb = unicode_data.IndicConjunctBreak;

pub const GraphemeCluster = struct {
    /// Original bytes for this visible text unit. A Unicode grapheme cluster can
    /// be as large as the remaining input for pathological combining/control
    /// sequences; callers must not copy this into fixed-size buffers.
    bytes: []const u8,
    /// Terminal cells occupied by this cluster. Control effects that would move
    /// backward at codepoint level are clamped to zero for iterator consumers.
    width: usize,
};

pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Iterator) ?GraphemeCluster {
        const cluster_bytes = self.nextBytes() orelse return null;
        return .{
            .bytes = cluster_bytes,
            .width = clampWidth(graphemeWidthSigned(cluster_bytes)),
        };
    }

    fn nextBytes(self: *Iterator) ?[]const u8 {
        if (self.index >= self.bytes.len) return null;

        const start = self.index;
        var decoded = decodeNext(self.bytes, self.index);
        var prev_prop = graphemeBreakProperty(decoded.cp);
        var ri_run: usize = if (prev_prop == .regional_indicator) 1 else 0;
        var last_ep_before_extend = isExtendedPictographic(decoded.cp);
        var zwj_after_ep = false;
        var incb_seen_consonant = indicConjunctBreak(decoded.cp) == .consonant;
        var incb_can_join = false;

        self.index = decoded.end;

        while (self.index < self.bytes.len) {
            decoded = decodeNext(self.bytes, self.index);
            const curr_prop = graphemeBreakProperty(decoded.cp);

            if (hasGraphemeBreak(prev_prop, curr_prop, ri_run, zwj_after_ep, incb_can_join, decoded.cp)) {
                break;
            }

            self.index = decoded.end;

            switch (curr_prop) {
                .regional_indicator => ri_run += 1,
                else => ri_run = 0,
            }

            if (curr_prop == .zwj) {
                zwj_after_ep = last_ep_before_extend;
                last_ep_before_extend = false;
            } else if (curr_prop == .extend) {
                // GB11 allows Extended_Pictographic Extend* ZWJ.
            } else {
                zwj_after_ep = false;
                last_ep_before_extend = isExtendedPictographic(decoded.cp);
            }

            updateIndicState(decoded.cp, curr_prop, &incb_seen_consonant, &incb_can_join);

            prev_prop = curr_prop;
        }

        return self.bytes[start..self.index];
    }
};

/// Returns the terminal display width of a UTF-8 string in cells.
///
/// Invalid UTF-8 bytes are preserved by the iterator and counted like U+FFFD.
/// Ill-formed multibyte prefixes consume their maximal available continuation
/// subpart so callers see one original byte slice per replacement unit.
/// Backspace/DEL are allowed to reduce the accumulated width, but the result is
/// never less than zero.
pub fn stringWidth(bytes: []const u8) usize {
    var it = Iterator.init(bytes);
    var total: isize = 0;
    while (it.nextBytes()) |cluster_bytes| {
        total = saturatingAddIsize(total, graphemeWidthSigned(cluster_bytes));
    }
    return clampWidth(total);
}

/// Width of one extended grapheme cluster. If `bytes` contains multiple
/// clusters, this returns the width policy for the bytes as one cluster; callers
/// that need full string width should use `stringWidth` or `Iterator`.
pub fn graphemeWidth(bytes: []const u8) usize {
    return clampWidth(graphemeWidthSigned(bytes));
}

/// Codepoint terminal width. Negative values are reserved for controls that can
/// move the cursor backward; aggregate APIs clamp so they never underflow.
pub fn codepointWidth(cp: u21) i4 {
    if (cp == 0) return 0;
    if (cp == 0x08 or cp == 0x7f) return -1;
    if (cp < 0x20 or (0x80 <= cp and cp <= 0x9f)) return 0;

    // Match common terminal/wcwidth behavior for these printable format chars.
    if (cp == 0x00ad) return 1; // SOFT HYPHEN
    if (cp == 0x0603) return 1; // ARABIC SIGN SAFHA
    if (cp == 0x2e3a) return 2; // TWO-EM DASH
    if (cp == 0x2e3b) return 3; // THREE-EM DASH

    const prop = graphemeBreakProperty(cp);
    if (prop == .regional_indicator) return 2;
    if (isEmojiModifier(cp)) return 2;
    if (prop == .control or prop == .extend or prop == .zwj or prop == .prepend or prop == .spacing_mark) return 0;

    if (inRanges(&unicode_data.wide_ranges, cp)) return 2;
    if (inRanges(&unicode_data.emoji_presentation_ranges, cp)) return 2;
    return 1;
}

fn graphemeWidthSigned(bytes: []const u8) isize {
    var i: usize = 0;
    var first_nonzero: ?i4 = null;
    var saw_vs15 = false;
    var saw_vs16 = false;
    var saw_zwj = false;
    var saw_ep = false;
    var saw_modifier = false;
    var ri_count: usize = 0;

    while (i < bytes.len) {
        const decoded = decodeNext(bytes, i);
        i = decoded.end;

        const cp = decoded.cp;
        if (cp == 0xfe0e) saw_vs15 = true;
        if (cp == 0xfe0f) saw_vs16 = true;
        if (cp == 0x200d) saw_zwj = true;
        if (isExtendedPictographic(cp)) saw_ep = true;
        if (isEmojiModifier(cp)) saw_modifier = true;
        if (graphemeBreakProperty(cp) == .regional_indicator) ri_count += 1;

        const w = codepointWidth(cp);
        if (w != 0 and first_nonzero == null) first_nonzero = w;
    }

    const base_width = first_nonzero orelse return if (saw_modifier) 2 else 0;
    if (base_width < 0) return base_width;
    if (saw_vs15) return 1;
    if (saw_vs16) return 2;
    if (ri_count >= 2) return 2;
    if (saw_zwj and saw_ep) return 2;
    if (saw_modifier and saw_ep) return 2;
    return base_width;
}

fn hasGraphemeBreak(prev: Gbp, curr: Gbp, ri_run: usize, zwj_after_ep: bool, incb_can_join: bool, curr_cp: u21) bool {
    // GB3
    if (prev == .cr and curr == .lf) return false;
    // GB4/GB5
    if (isControlBreak(prev) or isControlBreak(curr)) return true;
    // GB6
    if (prev == .l and (curr == .l or curr == .v or curr == .lv or curr == .lvt)) return false;
    // GB7
    if ((prev == .lv or prev == .v) and (curr == .v or curr == .t)) return false;
    // GB8
    if ((prev == .lvt or prev == .t) and curr == .t) return false;
    // GB9b
    if (prev == .prepend) return false;
    // GB9 / GB9a
    if (curr == .extend or curr == .zwj or curr == .spacing_mark) return false;
    // GB9c
    if (incb_can_join and indicConjunctBreak(curr_cp) == .consonant) return false;
    // GB11
    if (prev == .zwj and zwj_after_ep and isExtendedPictographic(curr_cp)) return false;
    // GB12/GB13
    if (prev == .regional_indicator and curr == .regional_indicator and (ri_run % 2 == 1)) return false;
    // GB999
    return true;
}

fn isControlBreak(prop: Gbp) bool {
    return prop == .control or prop == .cr or prop == .lf;
}

fn updateIndicState(cp: u21, gcb: Gbp, seen_consonant: *bool, can_join: *bool) void {
    switch (indicConjunctBreak(cp)) {
        .consonant => {
            seen_consonant.* = true;
            can_join.* = false;
        },
        .linker => {
            if (seen_consonant.*) can_join.* = true;
        },
        .extend => {},
        .none => {
            if (gcb != .extend and gcb != .zwj) {
                seen_consonant.* = false;
                can_join.* = false;
            }
        },
    }
}

fn graphemeBreakProperty(cp: u21) Gbp {
    var lo: usize = 0;
    var hi: usize = unicode_data.grapheme_break_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = unicode_data.grapheme_break_ranges[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return range.prop;
        }
    }
    return .other;
}

fn indicConjunctBreak(cp: u21) Icb {
    var lo: usize = 0;
    var hi: usize = unicode_data.indic_conjunct_break_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = unicode_data.indic_conjunct_break_ranges[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return range.prop;
        }
    }
    return .none;
}

fn isExtendedPictographic(cp: u21) bool {
    return inRanges(&unicode_data.extended_pictographic_ranges, cp);
}

fn isEmojiModifier(cp: u21) bool {
    return inRanges(&unicode_data.emoji_modifier_ranges, cp);
}

fn inRanges(ranges: []const unicode_data.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn clampWidth(width: isize) usize {
    return if (width <= 0) 0 else @intCast(width);
}

fn saturatingAddIsize(a: isize, b: isize) isize {
    if (b > 0 and a > std.math.maxInt(isize) - b) return std.math.maxInt(isize);
    if (b < 0 and a < std.math.minInt(isize) - b) return std.math.minInt(isize);
    return a + b;
}

const Decoded = struct {
    cp: u21,
    end: usize,
};

fn decodeNext(bytes: []const u8, index: usize) Decoded {
    std.debug.assert(index < bytes.len);
    const replacement: u21 = 0xfffd;
    const b0 = bytes[index];
    if (b0 < 0x80) return .{ .cp = b0, .end = index + 1 };

    if (b0 >= 0xc0 and b0 <= 0xdf) {
        if (b0 >= 0xc2 and index + 1 < bytes.len and isContinuation(bytes[index + 1])) {
            const cp = (@as(u21, b0 & 0x1f) << 6) | @as(u21, bytes[index + 1] & 0x3f);
            return .{ .cp = cp, .end = index + 2 };
        }
        return .{ .cp = replacement, .end = invalidSubpartEnd(bytes, index, 2) };
    }

    if (b0 >= 0xe0 and b0 <= 0xef) {
        if (index + 2 < bytes.len) {
            const b1 = bytes[index + 1];
            const b2 = bytes[index + 2];
            const valid_b1 = switch (b0) {
                0xe0 => b1 >= 0xa0 and b1 <= 0xbf,
                0xed => b1 >= 0x80 and b1 <= 0x9f,
                else => isContinuation(b1),
            };
            if (valid_b1 and isContinuation(b2)) {
                const cp = (@as(u21, b0 & 0x0f) << 12) | (@as(u21, b1 & 0x3f) << 6) | @as(u21, b2 & 0x3f);
                return .{ .cp = cp, .end = index + 3 };
            }
        }
        return .{ .cp = replacement, .end = invalidSubpartEnd(bytes, index, 3) };
    }

    if (b0 >= 0xf0 and b0 <= 0xf4) {
        if (index + 3 < bytes.len) {
            const b1 = bytes[index + 1];
            const b2 = bytes[index + 2];
            const b3 = bytes[index + 3];
            const valid_b1 = switch (b0) {
                0xf0 => b1 >= 0x90 and b1 <= 0xbf,
                0xf4 => b1 >= 0x80 and b1 <= 0x8f,
                else => isContinuation(b1),
            };
            if (valid_b1 and isContinuation(b2) and isContinuation(b3)) {
                const cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3f) << 12) | (@as(u21, b2 & 0x3f) << 6) | @as(u21, b3 & 0x3f);
                return .{ .cp = cp, .end = index + 4 };
            }
        }
        return .{ .cp = replacement, .end = invalidSubpartEnd(bytes, index, 4) };
    }

    return .{ .cp = replacement, .end = index + 1 };
}

fn invalidSubpartEnd(bytes: []const u8, index: usize, expected_len: usize) usize {
    var end = index + 1;
    const max_end = @min(bytes.len, index + expected_len);
    while (end < max_end and isContinuation(bytes[end])) end += 1;
    return end;
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

fn appendUtf8(out: []u8, len: *usize, cp: u21) !void {
    if (len.* > out.len) return error.NoSpace;
    if (cp <= 0x7f) {
        if (out.len - len.* < 1) return error.NoSpace;
        out[len.*] = @intCast(cp);
        len.* += 1;
    } else if (cp <= 0x7ff) {
        if (out.len - len.* < 2) return error.NoSpace;
        out[len.*] = @intCast(0xc0 | (cp >> 6));
        out[len.* + 1] = @intCast(0x80 | (cp & 0x3f));
        len.* += 2;
    } else if (cp <= 0xffff) {
        if (out.len - len.* < 3) return error.NoSpace;
        out[len.*] = @intCast(0xe0 | (cp >> 12));
        out[len.* + 1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[len.* + 2] = @intCast(0x80 | (cp & 0x3f));
        len.* += 3;
    } else if (cp <= 0x10ffff) {
        if (out.len - len.* < 4) return error.NoSpace;
        out[len.*] = @intCast(0xf0 | (cp >> 18));
        out[len.* + 1] = @intCast(0x80 | ((cp >> 12) & 0x3f));
        out[len.* + 2] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[len.* + 3] = @intCast(0x80 | (cp & 0x3f));
        len.* += 4;
    } else {
        return error.InvalidCodepoint;
    }
}

fn parseHex(token: []const u8) !u21 {
    return try std.fmt.parseInt(u21, token, 16);
}

test "codepoint width edge cases adapted from zg and zig-wcwidth" {
    try std.testing.expectEqual(@as(i4, 0), codepointWidth(0x0000));
    try std.testing.expectEqual(@as(i4, -1), codepointWidth(0x0008));
    try std.testing.expectEqual(@as(i4, -1), codepointWidth(0x007f));
    try std.testing.expectEqual(@as(i4, 0), codepointWidth(0x0005));
    try std.testing.expectEqual(@as(i4, 0), codepointWidth(0x0007));
    try std.testing.expectEqual(@as(i4, 0), codepointWidth(0x000a));
    try std.testing.expectEqual(@as(i4, 0), codepointWidth(0x070f));
    try std.testing.expectEqual(@as(i4, 1), codepointWidth(0x0603));
    try std.testing.expectEqual(@as(i4, 1), codepointWidth(0x00ad));
    try std.testing.expectEqual(@as(i4, 2), codepointWidth(0x2e3a));
    try std.testing.expectEqual(@as(i4, 3), codepointWidth(0x2e3b));
    try std.testing.expectEqual(@as(i4, 1), codepointWidth(0x00bd));
    try std.testing.expectEqual(@as(i4, 1), codepointWidth('é'));
    try std.testing.expectEqual(@as(i4, 2), codepointWidth('😊'));
    try std.testing.expectEqual(@as(i4, 2), codepointWidth('统'));
}

test "string width cases adapted from related libraries" {
    try std.testing.expectEqual(@as(usize, 0), stringWidth(""));
    try std.testing.expectEqual(@as(usize, 5), stringWidth("hello"));
    try std.testing.expectEqual(@as(usize, 5), stringWidth("Hello\r\n"));
    try std.testing.expectEqual(@as(usize, 19), stringWidth("コンニチハ, セカイ!"));
    try std.testing.expectEqual(@as(usize, 4), stringWidth("cafe\u{0301}"));
    try std.testing.expectEqual(@as(usize, 4), stringWidth("--\u{05bf}--"));
    try std.testing.expectEqual(@as(usize, 1), stringWidth("\u{0401}\u{0488}"));
    try std.testing.expectEqual(@as(usize, 3), stringWidth("\u{1b13}\u{1b28}\u{1b2e}\u{1b44}"));
    try std.testing.expectEqual(@as(usize, 8), stringWidth("Hello 😊"));
    try std.testing.expectEqual(@as(usize, 0), stringWidth("A\x08"));
    try std.testing.expectEqual(@as(usize, 0), stringWidth("\x7fA"));
}

test "grapheme cluster width cases adapted from uniseg zg and libvaxis" {
    const Case = struct { s: []const u8, width: usize };
    const cases = [_]Case{
        .{ .s = "e\u{0301}", .width = 1 },
        .{ .s = "\u{2764}", .width = 1 },
        .{ .s = "\u{2764}\u{fe0e}", .width = 1 },
        .{ .s = "\u{2764}\u{fe0f}", .width = 2 },
        .{ .s = "\u{26a1}", .width = 2 },
        .{ .s = "\u{26a1}\u{fe0e}", .width = 1 },
        .{ .s = "\u{26a1}\u{fe0f}", .width = 2 },
        .{ .s = "👋🏿", .width = 2 },
        .{ .s = "🇩🇪", .width = 2 },
        .{ .s = "🇺🇸🇦", .width = 4 },
        .{ .s = "🇺🇸🇦🇺", .width = 4 },
        .{ .s = "👩‍🚀", .width = 2 },
        .{ .s = "👨‍👩‍👧‍👧", .width = 2 },
        .{ .s = "🏳️‍🌈", .width = 2 },
        .{ .s = "☺️", .width = 2 },
        .{ .s = "⌛︎", .width = 1 },
        .{ .s = "훯", .width = 2 },
        .{ .s = "ผู้", .width = 1 },
        .{ .s = "👩🏻‍", .width = 2 },
        .{ .s = "👩🏻‍💻", .width = 2 },
        .{ .s = "⛹🏻‍♀️", .width = 2 },
        .{ .s = "♀️", .width = 2 },
        .{ .s = "\u{200b}", .width = 0 },
        .{ .s = "\u{200c}", .width = 0 },
        .{ .s = "\u{1f476}\u{1f3ff}\u{0308}\u{200d}\u{1f476}\u{1f3ff}", .width = 2 },
        .{ .s = "🔥🗡🍩👩🏻‍🚀⏰💃🏼🔦👍🏻", .width = 15 },
        .{ .s = "✍️✍🏻✍🏼✍🏽✍🏾✍🏿", .width = 12 },
        .{ .s = "슬라바 우크라이나", .width = 17 },
        .{ .s = "1️⃣", .width = 2 },
    };
    for (cases) |case| {
        errdefer std.debug.print("width case failed: {s}\n", .{case.s});
        try std.testing.expectEqual(case.width, stringWidth(case.s));
    }
}

test "iterator exposes original grapheme cluster bytes" {
    var it = Iterator.init("e\u{0301} 👩🏽‍🚀 界");
    const first = it.next().?;
    try std.testing.expectEqualStrings("e\u{0301}", first.bytes);
    try std.testing.expectEqual(@as(usize, 1), first.width);
    const space = it.next().?;
    try std.testing.expectEqualStrings(" ", space.bytes);
    try std.testing.expectEqual(@as(usize, 1), space.width);
    const astronaut = it.next().?;
    try std.testing.expectEqualStrings("👩🏽‍🚀", astronaut.bytes);
    try std.testing.expectEqual(@as(usize, 2), astronaut.width);
    _ = it.next().?; // space
    const cjk = it.next().?;
    try std.testing.expectEqualStrings("界", cjk.bytes);
    try std.testing.expectEqual(@as(usize, 2), cjk.width);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), it.next());
}

test "iterator handles prepend and regional indicator boundaries" {
    var prepend = Iterator.init("\u{0600}a");
    const joined = prepend.next().?;
    try std.testing.expectEqualStrings("\u{0600}a", joined.bytes);
    try std.testing.expectEqual(@as(usize, 1), joined.width);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), prepend.next());

    var flags = Iterator.init("a🇺🇸🇦b");
    try std.testing.expectEqualStrings("a", flags.next().?.bytes);
    try std.testing.expectEqualStrings("🇺🇸", flags.next().?.bytes);
    const lone_ri = flags.next().?;
    try std.testing.expectEqualStrings("🇦", lone_ri.bytes);
    try std.testing.expectEqual(@as(usize, 2), lone_ri.width);
    try std.testing.expectEqualStrings("b", flags.next().?.bytes);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), flags.next());
}

test "invalid UTF-8 is preserved and counted as replacement width" {
    try std.testing.expectEqual(std.math.maxInt(isize), saturatingAddIsize(std.math.maxInt(isize), 1));
    try std.testing.expectEqual(std.math.minInt(isize), saturatingAddIsize(std.math.minInt(isize), -1));

    const truncated_four = "\xf0\x9f";
    var truncated = Iterator.init(truncated_four);
    const truncated_cluster = truncated.next().?;
    try std.testing.expectEqualStrings(truncated_four, truncated_cluster.bytes);
    try std.testing.expectEqual(@as(usize, 1), truncated_cluster.width);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), truncated.next());

    const overlong = "a\xc0\xafz";
    var overlong_it = Iterator.init(overlong);
    try std.testing.expectEqualStrings("a", overlong_it.next().?.bytes);
    const invalid = overlong_it.next().?;
    try std.testing.expectEqualStrings("\xc0\xaf", invalid.bytes);
    try std.testing.expectEqual(@as(usize, 1), invalid.width);
    try std.testing.expectEqualStrings("z", overlong_it.next().?.bytes);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), overlong_it.next());

    const surrogate = "\xed\xa0\x80";
    var surrogate_it = Iterator.init(surrogate);
    try std.testing.expectEqualStrings(surrogate, surrogate_it.next().?.bytes);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), surrogate_it.next());

    const mixed = "x\x80y\xe2(\xa1";
    var mixed_it = Iterator.init(mixed);
    try std.testing.expectEqualStrings("x", mixed_it.next().?.bytes);
    try std.testing.expectEqualStrings("\x80", mixed_it.next().?.bytes);
    try std.testing.expectEqualStrings("y", mixed_it.next().?.bytes);
    try std.testing.expectEqualStrings("\xe2", mixed_it.next().?.bytes);
    try std.testing.expectEqualStrings("(", mixed_it.next().?.bytes);
    try std.testing.expectEqualStrings("\xa1", mixed_it.next().?.bytes);
    try std.testing.expectEqual(@as(?GraphemeCluster, null), mixed_it.next());

    try std.testing.expectEqual(@as(usize, 4), stringWidth("a\xf0\x9fb\x80"));
}

fn fuzzOneInput(input: []const u8) !void {
    var total: isize = 0;
    var last_index: usize = 0;
    var cluster_count: usize = 0;
    var it = Iterator.init(input);

    while (it.next()) |cluster| {
        try std.testing.expect(it.index > last_index);
        try std.testing.expect(it.index <= input.len);
        try std.testing.expectEqualSlices(u8, input[last_index..it.index], cluster.bytes);
        try std.testing.expectEqual(clampWidth(graphemeWidthSigned(cluster.bytes)), cluster.width);
        total = saturatingAddIsize(total, graphemeWidthSigned(cluster.bytes));
        last_index = it.index;
        cluster_count += 1;
        try std.testing.expect(cluster_count <= input.len);
    }

    try std.testing.expectEqual(input.len, last_index);
    try std.testing.expectEqual(clampWidth(total), stringWidth(input));
    _ = graphemeWidth(input);
}

test "fuzz textcell invariants" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            try fuzzOneInput(input);
        }
    };

    try std.testing.fuzz(Context{}, Context.testOne, .{ .corpus = &.{
        "",
        "hello",
        "e\u{0301} 👩🏽‍🚀 界",
        "\r\n\x00\x08\x7f",
        "🇺🇸🇦🇺🏳️‍🌈1️⃣",
        "\u{0600}a\u{0915}\u{094d}\u{0924}",
        "\xf0\x9f",
        "\xc0\xaf",
        "\xed\xa0\x80",
        "x\x80y\xe2(\xa1",
        "\xff\xfe\xfd\xfc",
        "\xf4\x90\x80\x80",
        "\xe0\x80\x80",
        "\xf0\x80\x80\x80",
    } });
}

test "Unicode GraphemeBreakTest conformance" {
    const data = @embedFile("testdata/GraphemeBreakTest.txt");
    var lines = std.mem.splitScalar(u8, data, '\n');
    var case_index: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const body = std.mem.trim(u8, std.mem.sliceTo(line, '#'), " \t");
        if (body.len == 0) continue;

        var bytes: [512]u8 = undefined;
        var byte_len: usize = 0;
        var expected: [256]usize = undefined;
        var expected_len: usize = 0;

        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                if (expected_len >= expected.len) return error.NoSpace;
                expected[expected_len] = byte_len;
                expected_len += 1;
            } else if (std.mem.eql(u8, token, "×")) {
                continue;
            } else {
                try appendUtf8(&bytes, &byte_len, try parseHex(token));
            }
        }

        var actual: [256]usize = undefined;
        var actual_len: usize = 0;
        actual[actual_len] = 0;
        actual_len += 1;
        var it = Iterator.init(bytes[0..byte_len]);
        while (it.next()) |_| {
            if (actual_len >= actual.len) return error.NoSpace;
            actual[actual_len] = it.index;
            actual_len += 1;
        }

        errdefer std.debug.print("GraphemeBreakTest case {d} failed: {s}\n", .{ case_index, line });
        try std.testing.expectEqual(expected_len, actual_len);
        for (expected[0..expected_len], actual[0..actual_len]) |want, got| {
            try std.testing.expectEqual(want, got);
        }
        case_index += 1;
    }
}
