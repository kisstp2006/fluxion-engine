// SPDX-License-Identifier: BSD-3-Clause

//! What an editor asks about a `.shader` file being written - its colours,
//! what is wrong with it, what may be typed at the caret, what a call takes
//! and what a name is - with what the engine writes after it known: `UV`,
//! `COLOR`, `TIME` and the rest are declared in the engine's part, and
//! completed and explained as the file's own names are, from the doc above
//! each. What the file never sees - the vertex stage's attributes, `Frame`'s
//! inner workings - is not offered.
//!
//! The file is analysed as it is compiled - its text, then the engine's
//! part, see `material.whole` - so what is said wrong is what compiling it
//! would say, at the file's own lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shader = @import("fluxion_shader");
const material = @import("render/material.zig");

const service = shader.service;

pub const Token = service.Token;
pub const TokenKind = service.TokenKind;
pub const Item = service.Item;
pub const ItemKind = service.ItemKind;
pub const Completions = service.Completions;
pub const Signature = service.Signature;
pub const Hover = service.Hover;

/// Something wrong with the file, at a place in its own text. One in the
/// engine's part - a name of the file's that clashes with one of the
/// engine's - is at its start, and says so.
pub const Problem = struct {
    start: u32,
    end: u32,
    message: []const u8,
};

pub const Analysis = struct {
    /// The file's colours, for its own text.
    tokens: []const Token,
    problems: []const Problem,
    /// The file's text with the engine's part after it, and what was said
    /// of that: what completing, a signature and a hover read.
    whole: []const u8,
    said: service.Analysis,
};

/// What the engine writes and a file does not use, or may not write: kept
/// out of what is offered.
const hidden = [_][]const u8{ "CORNER", "PLACEMENT", "SPIN", "TINT", "REGION", "PROJECTION", "SCREEN_FLIP", "Frame", "attribute", "varying", "vertex", "position" };

/// The engine's textures, declared only in a file that names them: offered
/// whether or not it has yet.
const textures = [_]service.Word{
    .{ .name = "TEXTURE", .detail = "texture2d TEXTURE", .doc = material.texture_doc },
    .{ .name = "SCREEN_TEXTURE", .detail = "texture2d SCREEN_TEXTURE", .doc = material.screen_texture_doc },
};

fn isHidden(name: []const u8) bool {
    for (hidden) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Everything said of a file's `text`, in `arena`; `gpa` is for the
/// compiler's own work.
pub fn analyze(gpa: Allocator, arena: Allocator, text: []const u8) Allocator.Error!Analysis {
    const built = try material.whole(arena, text);
    const said = try service.analyze(gpa, arena, built.source);

    var tokens: std.ArrayList(Token) = .empty;
    for (said.tokens) |t| {
        if (t.start + t.len > text.len) break;
        try tokens.append(arena, t);
    }

    var problems: std.ArrayList(Problem) = .empty;
    if (built.trespass) |where| try problems.append(arena, .{
        .start = where.offset,
        .end = wordEnd(text, where.offset),
        .message = (try built.trespassMessage(arena, text)).?,
    });
    for (said.problems) |p| {
        if (p.offset < text.len) {
            try problems.append(arena, .{ .start = p.offset, .end = wordEnd(text, p.offset), .message = p.message });
        } else {
            const line = p.line -| @as(u32, @intCast(built.engine_line - 1));
            try problems.append(arena, .{
                .start = 0,
                .end = 0,
                .message = try std.fmt.allocPrint(arena, "the engine's part, {d}:{d}: {s}", .{ line, p.column, p.message }),
            });
        }
    }
    return .{ .tokens = tokens.items, .problems = problems.items, .whole = built.source, .said = said };
}

/// Where the word at `at` ends, or the character after it.
fn wordEnd(text: []const u8, at: u32) u32 {
    var end: usize = at;
    while (end < text.len and isWordChar(text[end])) end += 1;
    return @intCast(@max(end, @min(text.len, @as(usize, at) + 1)));
}

/// What may be typed at `offset` of the file's text.
pub fn complete(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Completions {
    const found = (try service.complete(arena, a.whole, offset, &a.said)) orelse return null;
    var items: std.ArrayList(Item) = .empty;
    var swizzle = false;
    for (found.items) |item| {
        if (item.kind == .swizzle) swizzle = true;
        if (isHidden(item.label)) continue;
        // A name of the vertex stage's own is not the fragment stage's.
        if (item.kind == .attribute) continue;
        try items.append(arena, item);
    }
    if (!swizzle) for (textures) |t| {
        const declared = for (items.items) |item| {
            if (std.mem.eql(u8, item.label, t.name)) break true;
        } else false;
        if (!declared) try items.append(arena, .{ .label = t.name, .kind = .texture, .detail = t.detail, .doc = t.doc, .rank = 1 });
    };
    return .{ .items = items.items, .start = found.start, .end = found.end };
}

/// The call `offset` of the file's text is in.
pub fn signature(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Signature {
    return service.signature(arena, a.whole, offset, &a.said);
}

/// What the name at `offset` of the file's text is.
pub fn hover(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Hover {
    const at = @min(offset, a.whole.len);
    var start = at;
    while (start > 0 and isWordChar(a.whole[start - 1])) start -= 1;
    var end = at;
    while (end < a.whole.len and isWordChar(a.whole[end])) end += 1;
    for (textures) |t| if (std.mem.eql(u8, a.whole[start..end], t.name)) {
        return .{ .start = @intCast(start), .end = @intCast(end), .code = t.detail, .doc = t.doc };
    };
    return service.hover(arena, a.whole, offset, &a.said);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "a file's colours are its own, and the engine's names are completed with their docs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\uniform Look : 1 {
        \\    float strength = 0.5;
        \\}
        \\fragment {
        \\    target = sample(TEXTURE, UV) * COLOR * strength;
        \\}
    ;
    const a = try analyze(testing.allocator, arena.allocator(), text);
    try testing.expectEqual(@as(usize, 0), a.problems.len);
    for (a.tokens) |t| try testing.expect(t.start + t.len <= text.len);
    // `UV` is a varying the engine declares.
    const uv: u32 = @intCast(std.mem.indexOf(u8, text, "UV").?);
    const coloured = for (a.tokens) |t| {
        if (t.start == uv) break t;
    } else return error.TestExpectedEqual;
    try testing.expectEqual(TokenKind.varying, coloured.kind);

    const at: u32 = @intCast(std.mem.indexOf(u8, text, "target").?);
    const found = (try complete(arena.allocator(), &a, at + 1)).?;
    var saw: struct { time: bool = false, screen: bool = false, corner: bool = false, vertex: bool = false } = .{};
    for (found.items) |item| {
        if (std.mem.eql(u8, item.label, "TIME")) {
            saw.time = true;
            try testing.expectEqualStrings("Seconds since the game started.", item.doc.?);
        }
        if (std.mem.eql(u8, item.label, "SCREEN_TEXTURE")) saw.screen = true;
        if (std.mem.eql(u8, item.label, "CORNER")) saw.corner = true;
        if (std.mem.eql(u8, item.label, "vertex")) saw.vertex = true;
    }
    try testing.expect(saw.time and saw.screen and !saw.corner and !saw.vertex);

    const shown = (try hover(arena.allocator(), &a, uv + 1)).?;
    try testing.expectEqualStrings("varying vec2 UV", shown.code);
    try testing.expect(std.mem.startsWith(u8, shown.doc.?, "Where on the picture"));
}

test "a mistake is at the file's own place, a clash with the engine's part is said to be one, and so is a stage of the engine's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const wrong = "fragment {\n    target = vec4(1.0) + vec2(1.0);\n}\n";
    const a = try analyze(testing.allocator, arena.allocator(), wrong);
    try testing.expect(a.problems.len > 0);
    try testing.expect(a.problems[0].start > 10 and a.problems[0].start < wrong.len);

    const clash = try analyze(testing.allocator, arena.allocator(), "const float TIME = 1.0;\nfragment { target = vec4(TIME); }\n");
    var engine = false;
    for (clash.problems) |p| {
        if (std.mem.startsWith(u8, p.message, "the engine's part")) engine = true;
    }
    try testing.expect(engine);

    const trespass = try analyze(testing.allocator, arena.allocator(), "vertex { position = vec4(1.0); }\nfragment { target = vec4(1.0); }\n");
    try testing.expectEqual(@as(u32, 0), trespass.problems[0].start);
    try testing.expect(std.mem.indexOf(u8, trespass.problems[0].message, "is the engine's") != null);
}
