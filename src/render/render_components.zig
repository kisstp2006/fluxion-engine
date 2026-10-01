// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine draws from: `Sprite`, `Text2D`, the `Region`
//! of a texture a sprite shows, `Camera2D`, and `RenderView` with the
//! `ViewTexture` that shows its picture. See `scene/components.zig` for
//! what every component is.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");

const App = @import("../App.zig");
const assets = @import("../assets/assets.zig");
const attr = @import("../reflect/attr.zig");
const Color = @import("../math/color.zig").Color;
const Transform2D = @import("../scene/components.zig").Transform2D;
const Entity = @import("fluxion_ecs").Entity;

/// Which part of a texture a sprite shows, from zero to one - so it survives
/// the texture being redrawn at another resolution. `fromPixels` takes texels.
pub const Region = extern struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,

    /// The whole texture.
    pub const full: Region = .{};

    /// No range on the corners: past one is a texture repeated.
    pub const reflect_name = "Region";

    /// A rectangle of a sprite sheet, in texels, given the size of the sheet.
    pub fn fromPixels(x: f32, y: f32, w: f32, h: f32, sheet_width: f32, sheet_height: f32) Region {
        return .{
            .u0 = x / sheet_width,
            .v0 = y / sheet_height,
            .u1 = (x + w) / sheet_width,
            .v1 = (y + h) / sheet_height,
        };
    }

    pub fn repeated(across: f32, down: f32) Region {
        return .{ .u1 = across, .v1 = down };
    }

    /// One cell of a grid, counted left to right and then down. A grid of no
    /// columns or no rows - a number from a file, not from a sheet - is taken
    /// as one, rather than divided by.
    pub fn cell(index: u32, columns: u32, rows: u32) Region {
        const across = @max(columns, 1);
        const down = @max(rows, 1);
        const cw = 1 / @as(f32, @floatFromInt(across));
        const ch = 1 / @as(f32, @floatFromInt(down));
        const cx = @as(f32, @floatFromInt(index % across)) * cw;
        const cy = @as(f32, @floatFromInt((index / across) % down)) * ch;
        return .{ .u0 = cx, .v0 = cy, .u1 = cx + cw, .v1 = cy + ch };
    }

    /// Mirrored left to right.
    pub fn flippedX(self: Region) Region {
        return .{ .u0 = self.u1, .v0 = self.v0, .u1 = self.u0, .v1 = self.v1 };
    }

    /// Mirrored top to bottom.
    pub fn flippedY(self: Region) Region {
        return .{ .u0 = self.u0, .v0 = self.v1, .u1 = self.u1, .v1 = self.v0 };
    }
};

/// A picture drawn at a transform.
pub const Sprite = extern struct {
    /// What to draw. `.none` - also what a zeroed component holds - draws a
    /// rectangle of solid `tint`.
    texture: assets.TextureHandle = .none,

    /// Multiplied into the texture. White leaves it alone; the alpha fades it.
    tint: Color = .white,

    /// Which part of the texture.
    region: Region = .full,

    /// Size in world units, before the transform's scale. Zero means the
    /// region's size in texels, so most sprites need no size.
    width: f32 = 0,
    height: f32 = 0,

    /// Which point of the sprite sits on the transform, from zero to one. The
    /// middle by default, so it turns about itself.
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,

    /// What is drawn over what: higher is nearer. A sort key, not a depth -
    /// the 2D pass blends back to front with no depth test. Within a layer,
    /// see `order`.
    layer: i16 = 0,

    /// Skipped when false. Cheaper than removing the component, which moves
    /// the entity between archetypes.
    visible: bool = true,

    blend: Blend = .alpha,

    /// Drawn mirrored, left to right or top to bottom, in the same place: a
    /// character facing the other way.
    flip_h: bool = false,
    flip_v: bool = false,

    /// Where a sprite sits within its layer: lower is drawn first. At zero, a
    /// layer's sprites are grouped by texture, one draw call each. Copying
    /// `transform.y` in here sorts a top-down game by feet, at the cost of
    /// that grouping. Ties keep a stable order.
    order: f32 = 0,

    /// How it is laid over what is under it: over it, added to it - a glow -
    /// taken from it, or multiplied with it - a stain, a tinted glass - where
    /// it is not see-through.
    pub const Blend = enum(u8) { alpha, additive, subtractive, multiply };

    pub const reflect_name = "Sprite";
    pub const reflect_fields = .{
        .width = .{attr.Doc{ .text = "World units; zero is the region's width in texels" }},
        .height = .{attr.Doc{ .text = "World units; zero is the region's height in texels" }},
        .pivot_x = .{attr.Range{ .min = 0, .max = 1 }},
        .pivot_y = .{attr.Range{ .min = 0, .max = 1 }},
        .flip_h = .{attr.Doc{ .text = "Mirrored left to right" }},
        .flip_v = .{attr.Doc{ .text = "Mirrored top to bottom" }},
    };

    /// The part of the texture drawn, mirrored as its flips say.
    pub fn shownRegion(self: Sprite) Region {
        var region = self.region;
        if (self.flip_h) region = region.flippedX();
        if (self.flip_v) region = region.flippedY();
        return region;
    }

    /// A sprite showing the whole of a texture at its own size.
    pub fn of(texture: assets.TextureHandle) Sprite {
        return .{ .texture = texture };
    }

    /// A rectangle of solid colour, with no texture at all.
    pub fn solid(color: Color, width: f32, height: f32) Sprite {
        return .{ .tint = color, .width = width, .height = height };
    }
};

/// Words drawn at a transform, in a font the assets are holding.
///
/// ```zig
/// const label = try world.spawnWith(.{ Transform2D.at(16, 16), Text2D{ .size = 24 } });
/// try app.setText(label, Text2D, "text", "Score");
///
/// // ... and later, from a system:
/// try app.printText(label, Text2D, "text", "{d} points", .{score});
/// ```
///
/// The words are the app's, kept beside the component as long as they are:
/// see `component_texts.zig`. The transform is the top left of the first line, not the
/// baseline.
pub const Text2D = extern struct {
    /// `.none` is the default font, the first one loaded.
    font: assets.FontHandle = .none,

    /// Pixels per em, before the transform's scale. Rounded to whole pixels
    /// when rasterised.
    size: f32 = 16,

    color: Color = .white,

    /// Where the transform sits along the line.
    alignment: Alignment = .left,

    /// Multiplies the font's own line height.
    line_spacing: f32 = 1,

    /// The same sort keys as a `Sprite`'s: text and sprites are one list.
    layer: i16 = 0,
    order: f32 = 0,

    visible: bool = true,

    pub const Alignment = enum(u8) { left, center, right };

    pub const reflect_name = "Text2D";
    pub const reflect_attributes = .{attr.Text{ .name = "text", .multiline = true }};
    pub const reflect_fields = .{
        .size = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "Per em, before the transform's scale" } },
    };
};

/// What the 2D pass looks through. Its position is its entity's
/// `Transform2D`, at the middle of the view. With no camera in the world, the
/// origin is the window's top left and one unit is one pixel.
pub const Camera2D = extern struct {
    /// Bigger is closer: 2 draws everything at twice the size. With a fit set,
    /// it multiplies the fit: 1 shows exactly the fitted area.
    zoom: f32 = 1,

    /// An area always shown whole, whatever the window's size: a play field
    /// designed at one size. Spare room shows more of the world around it.
    /// Zero on either is no fit.
    fit_width: f32 = 0,
    fit_height: f32 = 0,

    /// Radians, as `Transform2D.rotation`. The world turns the other way.
    rotation: f32 = 0,

    /// With more than one camera, the active one with the highest priority
    /// wins. Ties go to whichever is found first, which is not an order to
    /// depend on.
    priority: i16 = 0,

    active: bool = true,

    /// The render layers it sees: what an `Appearance` puts on layers it
    /// does not have is not drawn through it. See `Appearance.render_layers`.
    cull_mask: u32 = 0xFFFF_FFFF,

    /// Where it looks, moved from where it is, turned with it: a shake, a
    /// look ahead of a runner.
    offset: math.Vec2 = .zero,

    /// The edges of the world it never shows past: a level's walls. The
    /// middle of what it shows is kept far enough in; a level narrower than
    /// the screen is shown in the middle.
    limit_left: f32 = -no_limit,
    limit_top: f32 = -no_limit,
    limit_right: f32 = no_limit,
    limit_bottom: f32 = no_limit,

    /// Following where it is at `smoothing_speed` - the part of the way it
    /// closes each second, roughly - rather than at once.
    smoothing: bool = false,
    smoothing_speed: f32 = 5,

    /// Where its smoothing has got to, and whether it has started: the
    /// engine's, each frame. Never saved.
    shown: math.Vec2 = .zero,
    following: bool = false,

    /// Far enough that no level reaches it: a limit not set.
    pub const no_limit: f32 = 10_000_000;

    pub const reflect_name = "Camera2D";
    pub const reflect_fields = .{
        .cull_mask = .{ attr.Layers{ .names = .render_2d }, attr.Doc{ .text = "The render layers it sees" } },
        .fit_width = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .fit_height = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .rotation = .{ attr.Angle{}, attr.Doc{ .text = "Clockwise on screen; the world turns the other way" } },
        .offset = .{attr.Doc{ .text = "Where it looks, moved from where it is: a shake" }},
        .limit_left = .{attr.Doc{ .text = "The world's left edge it never shows past" }},
        .limit_top = .{attr.Doc{ .text = "The world's top edge it never shows past" }},
        .limit_right = .{attr.Doc{ .text = "The world's right edge it never shows past" }},
        .limit_bottom = .{attr.Doc{ .text = "The world's bottom edge it never shows past" }},
        .smoothing = .{attr.Doc{ .text = "Following where it is smoothly, not at once" }},
        .smoothing_speed = .{attr.Doc{ .text = "How fast it catches up" }},
        .shown = .{ attr.Hidden{}, attr.Unsaved{} },
        .following = .{ attr.Hidden{}, attr.Unsaved{} },
    };

    /// Where it would look now: its place and its offset, turned with it.
    pub fn target(self: Camera2D, placed: Transform2D) math.Vec2 {
        const turn = self.rotation + placed.rotation;
        const c = @cos(turn);
        const s = @sin(turn);
        return .init(placed.x + self.offset.x * c - self.offset.y * s, placed.y + self.offset.x * s + self.offset.y * c);
    }

    /// Where it looks, before its limits: where its smoothing has got to,
    /// else its target.
    pub fn looking(self: Camera2D, placed: Transform2D) math.Vec2 {
        return if (self.smoothing and self.following) self.shown else self.target(placed);
    }

    /// A middle kept inside the limits, seeing `half_width` and
    /// `half_height` either side of it.
    pub fn limited(self: Camera2D, at: math.Vec2, half_width: f32, half_height: f32) math.Vec2 {
        return .init(within(at.x, self.limit_left, self.limit_right, half_width), within(at.y, self.limit_top, self.limit_bottom, half_height));
    }

    fn within(at: f32, low: f32, high: f32, half: f32) f32 {
        if (high - low <= 2 * half) return (low + high) / 2;
        return std.math.clamp(at, low + half, high - half);
    }

    pub fn atZoom(zoom: f32) Camera2D {
        return .{ .zoom = zoom };
    }

    /// A camera that always shows the whole of an area this size.
    pub fn fitting(width: f32, height: f32) Camera2D {
        return .{ .fit_width = width, .fit_height = height };
    }
};

/// A camera that draws into a picture of its own rather than onto the
/// screen: a game in an arcade cabinet, a minimap, a monitor on a wall.
/// Beside a `Camera2D`, which says how close it is and what it sees, and a
/// `Transform2D`, which says where it looks. The screen is never looked at
/// through it.
///
/// What it draws is shown by a `ViewTexture` on a `Sprite` or a
/// `TextureRect`, or by `App.viewTexture` from code: drawn every frame
/// before the screen is, so what shows it shows this frame's.
pub const RenderView = extern struct {
    width: u32 = 320,
    height: u32 = 180,
    clear_color: Color = .black,
    /// Nearest keeps a small picture's pixels square when it is shown
    /// bigger; linear smooths it.
    filter: Filter = .nearest,
    /// Off, it keeps the last picture it drew.
    active: bool = true,

    pub const Filter = enum(u8) { nearest, linear };

    pub const reflect_name = "RenderView";
    pub const reflect_fields = .{
        .width = .{ attr.Range{ .min = 1, .max = 4096, .step = 1 }, attr.Unit{ .text = "px" } },
        .height = .{ attr.Range{ .min = 1, .max = 4096, .step = 1 }, attr.Unit{ .text = "px" } },
        .clear_color = .{attr.Doc{ .text = "What the picture is cleared to before the world is drawn" }},
        .active = .{attr.Doc{ .text = "Off, it keeps the last picture it drew" }},
    };
};

/// Shows the picture a `RenderView` draws, in place of its own texture:
/// beside a `Sprite` or a `TextureRect`.
pub const ViewTexture = extern struct {
    view: Entity = .none,

    pub const reflect_name = "ViewTexture";
    pub const reflect_fields = .{
        .view = .{attr.Doc{ .text = "The entity whose RenderView's picture is shown" }},
    };
};

test "a cell of a strip is the strip divided up" {
    const r: Region = .cell(1, 4, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.u0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.u1, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), r.v0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), r.v1, 0.0001);
}

test "a sprite's small fields pack together" {
    try testing.expectEqual(68, @sizeOf(Sprite));
}

test "mirroring swaps the horizontal edges and leaves the vertical ones" {
    const r: Region = .fromPixels(0, 0, 16, 16, 64, 64);
    const flipped = r.flippedX();
    try testing.expectEqual(r.u1, flipped.u0);
    try testing.expectEqual(r.u0, flipped.u1);
    try testing.expectEqual(r.v0, flipped.v0);
}

test "a label's words are the app's, as long as they are, and gone with it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const label = try app.world.spawnWith(.{ Transform2D.at(0, 0), Text2D{} });
    try testing.expectEqualStrings("", app.textOf(label, Text2D, "text"));
    try app.setText(label, Text2D, "text", "Score");
    try testing.expectEqualStrings("Score", app.textOf(label, Text2D, "text"));
    try app.printText(label, Text2D, "text", "{d} points", .{42});
    try testing.expectEqualStrings("42 points", app.textOf(label, Text2D, "text"));

    // Far longer than any buffer a component could hold.
    const long = "é" ** 400;
    try app.setText(label, Text2D, "text", long);
    try testing.expectEqualStrings(long, app.textNamed(label, "Text2D", "text"));
    try testing.expectError(error.NoSuchText, app.setTextNamed(label, "Text2D", "words", "no"));

    app.world.despawn(label);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.texts.map.count());
    try testing.expectError(error.NoSuchEntity, app.setText(label, Text2D, "text", "late"));
}
