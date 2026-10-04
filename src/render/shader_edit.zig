// SPDX-License-Identifier: BSD-3-Clause

//! What an editor asks about a `.shader` or a `.shader3d` file being
//! written - its colours, what is wrong with it, what may be typed at the
//! caret, what a call takes and what a name is - with what the engine writes
//! known: `UV`, `COLOR`, `TIME` and the rest are declared in the engine's
//! part, and completed and explained as the file's own names are, from the
//! doc above each. What the file never sees - the vertex stage's
//! attributes, the blocks' inner workings - is not offered.
//!
//! The file is analysed as it is compiled - its text, then the engine's
//! part, see `material.whole` and `shader3d.whole` - so what is said wrong
//! is what compiling it would say, at the file's own lines. A 3D shader's
//! fragment stage has the engine's start and end written in it, and a place
//! in the file is found in what was compiled past them: see `Splice`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shader = @import("fluxion_shader");
const material = @import("material.zig");
const shader3d = @import("shader3d.zig");

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

/// Which kind of shader a file is: a sprite's, or a mesh's surface.
pub const Kind = enum {
    sprite,
    mesh,

    /// The kind of a file by its path.
    pub fn of(path: []const u8) Kind {
        return if (std.ascii.endsWithIgnoreCase(path, shader3d.extension)) .mesh else .sprite;
    }
};

/// Where the engine wrote into the file's own text, as a 3D shader's
/// fragment stage starts and ends with its lines: a place in the file is
/// found past what was written before it, and what was written is no place
/// in the file. Nothing, for a sprite's shader.
pub const Splice = struct {
    /// Where in the text the engine's start goes, and its end.
    open: u32 = 0,
    close: u32 = 0,
    /// How long each is.
    before: u32 = 0,
    after: u32 = 0,

    pub fn toWhole(self: Splice, at: u32) u32 {
        if (self.before == 0 and self.after == 0) return at;
        if (at < self.open) return at;
        if (at < self.close) return at + self.before;
        return at + self.before + self.after;
    }

    /// The place in the file, or null for one in what the engine wrote.
    pub fn toText(self: Splice, at: u32) ?u32 {
        if (self.before == 0 and self.after == 0) return at;
        if (at < self.open) return at;
        if (at < self.open + self.before) return null;
        const inner = at - self.before;
        if (inner < self.close) return inner;
        if (inner < self.close + self.after) return null;
        return inner - self.after;
    }
};

pub const Analysis = struct {
    kind: Kind = .sprite,
    /// The file's colours, for its own text.
    tokens: []const Token,
    problems: []const Problem,
    /// The file's text with the engine's put in it, and what was said of
    /// that: what completing, a signature and a hover read.
    whole: []const u8,
    splice: Splice = .{},
    said: service.Analysis,
};

/// What the engine writes and a file does not use, or may not write: kept
/// out of what is offered.
const hidden = [_][]const u8{ "CORNER", "PLACE", "SHAPE", "TINT", "REGION", "PROJECTION", "SCREEN_FLIP", "Frame", "attribute", "varying", "vertex", "position" };

/// The same, for a 3D shader: the blocks' workings, the lamps', and the
/// engine's own functions but `toLinear`.
const hidden_3d = [_][]const u8{
    "Frame",      "Material",    "Lights",       "VIEW_PROJECTION", "CAMERA_FORWARD", "SUN_DIRECTIONS",
    "SUN_COLORS", "AMBIENT",     "FOG_COLOR",    "FOG_HEIGHT",      "ALBEDO_COLOR",   "EMISSION_COLOR",
    "UV_PLACE",   "SURFACE",     "FEEL",         "FACING",          "LIGHT_PLACES",   "LIGHT_COLORS",
    "LIGHT_AIMS", "LIGHT_CONES", "LIGHT_LIST_0", "LIGHT_LIST_1",    "WORLD_TANGENT",  "shine",
    "sun",        "lamp",        "lit",          "PI",              "attribute",      "varying",
    "vertex",     "position",    "target",
};

/// The engine's textures, declared only in a file that names them: offered
/// whether or not it has yet.
const textures = [_]service.Word{
    .{ .name = "TEXTURE", .detail = "texture2d TEXTURE", .doc = material.texture_doc },
    .{ .name = "SCREEN_TEXTURE", .detail = "texture2d SCREEN_TEXTURE", .doc = material.screen_texture_doc },
};

fn isHidden(kind: Kind, name: []const u8) bool {
    const list: []const []const u8 = switch (kind) {
        .sprite => &hidden,
        .mesh => &hidden_3d,
    };
    for (list) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Everything said of a sprite's shader's `text`, in `arena`; `gpa` is for
/// the compiler's own work.
pub fn analyze(gpa: Allocator, arena: Allocator, text: []const u8) Allocator.Error!Analysis {
    return analyzeAs(gpa, arena, .sprite, text);
}

/// Everything said of a file's `text`, as the kind its `path` says.
pub fn analyzeFile(gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8) Allocator.Error!Analysis {
    return analyzeAs(gpa, arena, .of(path), text);
}

pub fn analyzeAs(gpa: Allocator, arena: Allocator, kind: Kind, text: []const u8) Allocator.Error!Analysis {
    var source: []const u8 = undefined;
    var engine_line: usize = undefined;
    var trespass: ?[]u8 = null;
    var trespass_at: u32 = 0;
    var splice: Splice = .{};
    switch (kind) {
        .sprite => {
            const built = try material.whole(arena, text);
            source = built.source;
            engine_line = built.engine_line;
            trespass = try built.trespassMessage(arena, text);
            if (built.trespass) |where| trespass_at = where.offset;
        },
        .mesh => {
            const built = try shader3d.whole(arena, text);
            source = built.source;
            engine_line = built.engine_line;
            trespass = try built.trespassMessage(arena, text);
            if (built.trespass) |where| trespass_at = where.offset;
            if (built.open) |open| splice = .{ .open = open, .close = built.close, .before = shader3d.prologue_len, .after = shader3d.epilogue_len };
        },
    }
    const said = try service.analyze(gpa, arena, source);

    var tokens: std.ArrayList(Token) = .empty;
    for (said.tokens) |t| {
        var placed = t;
        placed.start = splice.toText(t.start) orelse continue;
        if (placed.start + placed.len > text.len) break;
        try tokens.append(arena, placed);
    }

    var problems: std.ArrayList(Problem) = .empty;
    if (trespass) |message| try problems.append(arena, .{
        .start = trespass_at,
        .end = wordEnd(text, trespass_at),
        .message = message,
    });
    for (said.problems) |p| {
        const at = splice.toText(p.offset);
        if (at != null and at.? < text.len) {
            try problems.append(arena, .{ .start = at.?, .end = wordEnd(text, at.?), .message = p.message });
        } else {
            const line = p.line -| @as(u32, @intCast(engine_line - 1));
            try problems.append(arena, .{
                .start = 0,
                .end = 0,
                .message = if (at == null)
                    try std.fmt.allocPrint(arena, "the engine's part of the fragment stage: {s}", .{p.message})
                else
                    try std.fmt.allocPrint(arena, "the engine's part, {d}:{d}: {s}", .{ line, p.column, p.message }),
            });
        }
    }
    return .{ .kind = kind, .tokens = tokens.items, .problems = problems.items, .whole = source, .splice = splice, .said = said };
}

/// Where the word at `at` ends, or the character after it.
fn wordEnd(text: []const u8, at: u32) u32 {
    var end: usize = at;
    while (end < text.len and isWordChar(text[end])) end += 1;
    return @intCast(@max(end, @min(text.len, @as(usize, at) + 1)));
}

/// What may be typed at `offset` of the file's text.
pub fn complete(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Completions {
    const found = (try service.complete(arena, a.whole, a.splice.toWhole(offset), &a.said)) orelse return null;
    var items: std.ArrayList(Item) = .empty;
    var swizzle = false;
    for (found.items) |item| {
        if (item.kind == .swizzle) swizzle = true;
        if (isHidden(a.kind, item.label)) continue;
        // A name of the vertex stage's own is not the fragment stage's.
        if (item.kind == .attribute) continue;
        try items.append(arena, item);
    }
    const start = a.splice.toText(found.start) orelse offset;
    const end = a.splice.toText(found.end) orelse offset;
    // A 3D shader's pictures are always declared, and offered as they are.
    if (!swizzle and a.kind == .sprite) for (textures) |t| {
        const declared = for (items.items) |item| {
            if (std.mem.eql(u8, item.label, t.name)) break true;
        } else false;
        if (!declared) try items.append(arena, .{ .label = t.name, .kind = .texture, .detail = t.detail, .doc = t.doc, .rank = 1 });
    };
    return .{ .items = items.items, .start = start, .end = end };
}

/// The call `offset` of the file's text is in.
pub fn signature(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Signature {
    return service.signature(arena, a.whole, a.splice.toWhole(offset), &a.said);
}

/// What the name at `offset` of the file's text is.
pub fn hover(arena: Allocator, a: *const Analysis, offset: u32) Allocator.Error!?Hover {
    const at = @min(a.splice.toWhole(offset), a.whole.len);
    var start = at;
    while (start > 0 and isWordChar(a.whole[start - 1])) start -= 1;
    var end = at;
    while (end < a.whole.len and isWordChar(a.whole[end])) end += 1;
    if (a.kind == .sprite) for (textures) |t| if (std.mem.eql(u8, a.whole[start..end], t.name)) {
        return .{ .start = @intCast(start), .end = @intCast(end), .code = t.detail, .doc = t.doc };
    };
    var found = (try service.hover(arena, a.whole, at, &a.said)) orelse return null;
    found.start = a.splice.toText(found.start) orelse offset;
    found.end = a.splice.toText(found.end) orelse offset;
    return found;
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

test "a 3D shader's names are offered in its fragment stage, at the file's own places, and the engine's workings are not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        \\uniform Look : 3 {
        \\    float speed = 1.0;
        \\}
        \\fragment {
        \\    ALBEDO = ALBEDO * sin(TIME * speed);
        \\    ROUGHNESS = 0.2;
        \\}
    ;
    const a = try analyzeFile(testing.allocator, arena.allocator(), "waves.shader3d", text);
    try testing.expectEqual(Kind.mesh, a.kind);
    try testing.expectEqual(@as(usize, 0), a.problems.len);
    // Every colour is on the file's own text, and `TIME` is where it is.
    for (a.tokens) |t| try testing.expect(t.start + t.len <= text.len);
    const time: u32 = @intCast(std.mem.indexOf(u8, text, "TIME").?);
    const coloured = for (a.tokens) |t| {
        if (t.start == time) break t;
    } else return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 4), coloured.len);

    const at: u32 = @intCast(std.mem.indexOf(u8, text, "ROUGHNESS").?);
    const found = (try complete(arena.allocator(), &a, at + 1)).?;
    try testing.expectEqual(at, found.start);
    var saw: struct { metallic: bool = false, normal_map: bool = false, camera: bool = false, lamp: bool = false, feel: bool = false } = .{};
    for (found.items) |item| {
        if (std.mem.eql(u8, item.label, "METALLIC")) saw.metallic = true;
        if (std.mem.eql(u8, item.label, "NORMAL_MAP")) saw.normal_map = true;
        if (std.mem.eql(u8, item.label, "CAMERA_POSITION")) saw.camera = true;
        if (std.mem.eql(u8, item.label, "lamp")) saw.lamp = true;
        if (std.mem.eql(u8, item.label, "FEEL")) saw.feel = true;
    }
    try testing.expect(saw.metallic and saw.normal_map and saw.camera and !saw.lamp and !saw.feel);

    const shown = (try hover(arena.allocator(), &a, time + 1)).?;
    try testing.expectEqual(time, shown.start);
    try testing.expectEqualStrings("Seconds since the game started.", shown.doc.?);

    // A mistake after the engine's start is at the file's own place.
    const wrong = "fragment {\n    ALBEDO = vec2(1.0);\n}\n";
    const w = try analyzeFile(testing.allocator, arena.allocator(), "w.shader3d", wrong);
    try testing.expect(w.problems.len > 0);
    const line_start: u32 = @intCast(std.mem.indexOf(u8, wrong, "ALBEDO").?);
    try testing.expect(w.problems[0].start >= line_start and w.problems[0].start < line_start + 19);
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
