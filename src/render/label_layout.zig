// SPDX-License-Identifier: BSD-3-Clause

//! Where a `Text2D`'s letters go, from its fonts' measurements alone: its
//! words broken into lines - where they say, and with a `wrap_width` between
//! words and inside a word longer than a line - and each letter in the font,
//! the size and the look its tags give it. What the renderer puts a quad at
//! for each letter, and what the box an editor outlines and the camera tests
//! is measured from, so the two cannot disagree.
//!
//! No atlas here: a letter advances by its font's advance at the size the
//! atlas draws it at, which is what a glyph drawn there advances by.
//!
//! **Tags**, with `markup` on, are a `RichText`'s - fluxion-ui's markup -
//! but for pictures: `{color=red|...}`, `{opacity=0.5|...}`, `{hide|...}`,
//! `{shadow_color=black_offset=0.1,0.1|...}`, `{size=24|...}` in the
//! label's units to the em, and `{b|...}` in the `bold_font`, or struck
//! twice in the label's own font when it names none.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("fluxion_ui");

const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const Text2D = @import("render_components.zig").Text2D;

const markup = ui.markup;

/// Which of a label's two fonts a letter is in.
pub const Face = enum(u1) { own, bold };

/// A label's fonts: its own, and the one its `{b|...}` stretches are set in
/// when it names one that is loaded.
pub const Faces = struct {
    own: *Assets.Font,
    bold: ?*Assets.Font = null,

    /// What a label is drawn in, from what the assets hold: null when not
    /// even its own font is there.
    pub fn of(assets: *Assets, label: Text2D) ?Faces {
        const own = assets.fontOf(label.font) orelse return null;
        const bold = if (label.bold_font.isNone()) null else assets.fontOf(label.bold_font);
        return .{ .own = own, .bold = bold };
    }

    pub fn get(self: Faces, face: Face) *Assets.Font {
        return switch (face) {
            .own => self.own,
            .bold => self.bold orelse self.own,
        };
    }
};

/// The size a letter's glyph is drawn into its font's atlas at: its own in
/// whole pixels, as the atlas is keyed - a size read from a file is not
/// always one a hand would give, and NaN is the smallest - and at most
/// `Assets.max_glyph`, scaled up past it by `stretch`, which is what one of
/// the glyph's pixels is in the label's units.
pub const GlyphSize = struct {
    pixels: u16,
    stretch: f32,

    pub fn of(size: f32) GlyphSize {
        const biggest: f32 = @floatFromInt(Assets.max_glyph);
        const rounded = @round(size);
        if (rounded >= 1 and rounded <= biggest) return .{ .pixels = @intFromFloat(rounded), .stretch = 1 };
        if (rounded > biggest) return .{ .pixels = Assets.max_glyph, .stretch = @min(size, 65536) / biggest };
        return .{ .pixels = 1, .stretch = 1 };
    }

    /// An em, in the label's units: what it is drawn at, not what was asked.
    pub fn em(self: GlyphSize) f32 {
        return @as(f32, @floatFromInt(self.pixels)) * self.stretch;
    }
};

/// A copy of a letter behind it, in a colour of its own.
pub const Shadow = struct {
    color: Color,
    /// How far from the letter, in the label's units.
    x: f32,
    y: f32,
};

/// One letter to draw, in its label's space.
pub const Letter = struct {
    glyph: u16,
    face: Face,
    size: GlyphSize,
    /// Its pen on its line, alignment and all, and its line's baseline.
    x: f32,
    baseline: f32,
    /// A colour of its own, from a tag; null for the label's.
    color: ?Color = null,
    /// Multiplied into the alpha of all it draws.
    opacity: f32 = 1,
    /// Struck a second time this far right: a heavy stretch with no font of
    /// its own. Nought for once.
    strike: f32 = 0,
    shadow: ?Shadow = null,
};

/// A label laid out, and what it is worked out in, kept from one label to
/// the next.
pub const Layout = struct {
    letters: std.ArrayList(Letter) = .empty,
    /// The box the lines are laid out in, from the transform: `width`
    /// across from `left`, and `height` down from the top of the first line.
    left: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    /// How far a shadow or a second strike reaches past the box.
    overhang: f32 = 0,

    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(markup.Span) = .empty,
    characters: std.ArrayList(Character) = .empty,
    lines: std.ArrayList(Line) = .empty,

    pub fn deinit(self: *Layout, gpa: Allocator) void {
        self.letters.deinit(gpa);
        self.text.deinit(gpa);
        self.spans.deinit(gpa);
        self.characters.deinit(gpa);
        self.lines.deinit(gpa);
        self.* = undefined;
    }

    /// Lay out `run`, which is UTF-8, as `label` says, in `faces`, in place
    /// of what this held.
    pub fn make(self: *Layout, gpa: Allocator, faces: Faces, label: Text2D, run: []const u8) Allocator.Error!void {
        self.letters.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.characters.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.left = 0;
        self.width = 0;
        self.height = 0;
        self.overhang = 0;

        // Tags taken out of UTF-8 leave UTF-8: they are all ASCII.
        const words = if (label.markup)
            (try markup.parse(&self.text, &self.spans, null, null, gpa, run, null)).text
        else
            run;

        try self.measure(gpa, faces, label, words);
        try self.breakLines(gpa, label);
        try self.place(gpa, faces, label);
    }

    /// Each character in its font and size, and how far it moves the pen.
    fn measure(self: *Layout, gpa: Allocator, faces: Faces, label: Text2D, words: []const u8) Allocator.Error!void {
        var span_at: usize = 0;
        var previous: ?Character = null;
        var at: usize = 0;
        var characters = std.unicode.Utf8View.initUnchecked(words).iterator();
        while (characters.nextCodepointSlice()) |bytes| {
            defer at += bytes.len;
            const codepoint = std.unicode.utf8Decode(bytes) catch continue;
            if (codepoint == '\n') {
                try self.characters.append(gpa, .{ .kind = .newline });
                previous = null;
                continue;
            }

            const span = self.spanAt(&span_at, at);
            const look = spanOf(self.spans.items, span);
            const face: Face = if (look.bold and faces.bold != null) .bold else .own;
            const font = faces.get(face);
            const size: GlyphSize = .of(look.size orelse label.size);
            const scaled = font.face.at(@floatFromInt(size.pixels));
            const units = scaled.scale * size.stretch;
            const glyph = font.face.glyphFor(codepoint);

            var character: Character = .{
                .kind = if (codepoint == ' ' or codepoint == '\t') .space else .letter,
                .glyph = glyph,
                .face = face,
                .size = size,
                .span = span,
                .advance = (scaled.advance(glyph) catch 0) * size.stretch,
                .ascent = scaled.ascent() * size.stretch,
                .line_height = scaled.lineHeight() * size.stretch,
            };
            if (previous) |left| if (left.face == face and left.size.pixels == size.pixels) {
                const kerning = font.face.kern(left.glyph, glyph) catch 0;
                character.kern = @as(f32, @floatFromInt(kerning)) * units;
            };
            try self.characters.append(gpa, character);
            previous = character;
        }
    }

    /// The span over byte `at` of the words, moving on from where the last
    /// one was found; `plain` with no tags read.
    fn spanAt(self: *const Layout, from: *usize, at: usize) u32 {
        const spans = self.spans.items;
        if (spans.len == 0) return plain;
        while (from.* + 1 < spans.len and spans[from.*].end <= at) from.* += 1;
        return @intCast(from.*);
    }

    /// The characters into lines: at each newline, and with a wrap width
    /// before the word that would cross it - or inside a word wider than a
    /// line, before the letter that would. The spaces a line breaks at stay
    /// on it, and do not count to its width.
    fn breakLines(self: *Layout, gpa: Allocator, label: Text2D) Allocator.Error!void {
        const wrap = if (label.wrap_width > 0 and std.math.isFinite(label.wrap_width)) label.wrap_width else std.math.inf(f32);
        const characters = self.characters.items;

        var start: usize = 0;
        var pen: f32 = 0;
        // Where the line may break: the first letter after its last spaces,
        // once it has a letter before them.
        var opening: ?usize = null;
        var lettered = false;

        for (characters, 0..) |character, i| {
            switch (character.kind) {
                .newline => {
                    try self.lines.append(gpa, .{ .start = start, .end = i, .width = pen });
                    start = i + 1;
                    pen = 0;
                    opening = null;
                    lettered = false;
                },
                .space => pen += self.step(start, i),
                .letter => {
                    if (lettered and characters[i - 1].kind == .space) opening = i;
                    while (i > start and pen + self.step(start, i) > wrap) {
                        const end = opening orelse i;
                        try self.lines.append(gpa, .{ .start = start, .end = end, .width = self.widthOf(start, end) });
                        start = end;
                        opening = null;
                        pen = self.widthOf(start, i);
                    }
                    pen += self.step(start, i);
                    lettered = true;
                },
            }
        }
        try self.lines.append(gpa, .{ .start = start, .end = characters.len, .width = pen });
    }

    /// How far character `i` moves the pen on a line that starts at
    /// `start`: no kerning with what is not on the line.
    fn step(self: *const Layout, start: usize, i: usize) f32 {
        const character = self.characters.items[i];
        return character.advance + if (i > start) character.kern else 0;
    }

    /// How wide characters `start` to `end` are on a line of their own, the
    /// spaces after their last letter left out.
    fn widthOf(self: *const Layout, start: usize, end: usize) f32 {
        var last = end;
        while (last > start and self.characters.items[last - 1].kind == .space) last -= 1;
        var width: f32 = 0;
        for (start..last) |i| width += self.step(start, i);
        return width;
    }

    /// Each line under the last, as tall as its tallest character, and each
    /// letter on it where its alignment puts it.
    fn place(self: *Layout, gpa: Allocator, faces: Faces, label: Text2D) Allocator.Error!void {
        // An empty line is as tall as one in the label's own size.
        const base_size: GlyphSize = .of(label.size);
        const base = faces.own.face.at(@floatFromInt(base_size.pixels));

        var top: f32 = 0;
        var widest: f32 = 0;
        for (self.lines.items) |line| {
            const on_line = self.characters.items[line.start..line.end];
            var ascent: f32 = if (on_line.len == 0) base.ascent() * base_size.stretch else 0;
            var line_height: f32 = if (on_line.len == 0) base.lineHeight() * base_size.stretch else 0;
            for (on_line) |character| {
                ascent = @max(ascent, character.ascent);
                line_height = @max(line_height, character.line_height);
            }

            const baseline = top + ascent;
            var pen = shift(label.alignment, line.width);
            for (on_line, line.start..) |character, i| {
                pen += if (i > line.start) character.kern else 0;
                defer pen += character.advance;
                if (character.kind != .letter) continue;
                const look = spanOf(self.spans.items, character.span);
                if (look.hidden) continue;
                const letter = letterOf(character, look, faces, pen, baseline);
                self.overhang = @max(self.overhang, letter.strike);
                if (letter.shadow) |shadow| self.overhang = @max(self.overhang, @max(@abs(shadow.x), @abs(shadow.y)));
                try self.letters.append(gpa, letter);
            }

            top += line_height * label.line_spacing;
            widest = @max(widest, line.width);
        }
        self.width = widest;
        self.height = top;
        self.left = shift(label.alignment, widest);
    }
};

/// Where a line `width` wide starts from its transform, as `alignment`
/// says.
fn shift(alignment: Text2D.Alignment, width: f32) f32 {
    return switch (alignment) {
        .left => 0,
        .center => -width / 2,
        .right => -width,
    };
}

/// A letter in the look its tags give it.
fn letterOf(character: Character, look: markup.Span, faces: Faces, x: f32, baseline: f32) Letter {
    const em = character.size.em();
    return .{
        .glyph = character.glyph,
        .face = character.face,
        .size = character.size,
        .x = x,
        .baseline = baseline,
        .color = if (look.color) |color| colorOf(color) else null,
        .opacity = look.opacity,
        // As a `RichText` strikes it: a twentieth of an em across, never less
        // than a unit.
        .strike = if (look.bold and faces.bold == null) @max(1, em * 0.05) else 0,
        .shadow = if (look.shadow) |shadow| .{
            .color = colorOf(shadow.color),
            .x = shadow.offset.x * em,
            .y = shadow.offset.y * em,
        } else null,
    };
}

fn colorOf(color: ui.Color) Color {
    return .rgba(color.r, color.g, color.b, color.a);
}

/// What `span` says, with no tags read for `plain`.
fn spanOf(spans: []const markup.Span, span: u32) markup.Span {
    return if (span == plain) .{ .start = 0, .end = 0 } else spans[span];
}

/// The span of a character with no tags read.
const plain = std.math.maxInt(u32);

/// One character, measured.
const Character = struct {
    kind: enum { letter, space, newline },
    glyph: u16 = 0,
    face: Face = .own,
    size: GlyphSize = .{ .pixels = 1, .stretch = 1 },
    /// Which of the spans it is in, or `plain`.
    span: u32 = plain,
    /// How far it moves the pen, and its kerning with the character before
    /// it when that is on the same line, in the label's units.
    advance: f32 = 0,
    kern: f32 = 0,
    ascent: f32 = 0,
    line_height: f32 = 0,
};

/// Characters `start` to `end` on a line, and how wide the line is.
const Line = struct {
    start: usize,
    end: usize,
    width: f32,
};
