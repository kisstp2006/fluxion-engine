// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself knows about.
//!
//! There are four, and the list is deliberately short. A game invents its own
//! - `Health`, `Wave`, `PatrolRoute` - and the engine never sees them; these
//! are only the ones the renderer reads, because something has to agree on
//! where a thing is before it can be drawn there.
//!
//! ```zig
//! _ = try app.world.spawnWith(.{
//!     Transform2D{ .x = 320, .y = 180 },
//!     Sprite{ .texture = hero, .width = 48, .height = 48 },
//! });
//! ```
//!
//! **Every one of them is plain data**, and
//! [Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs) checks it at
//! compile time: no pointers, no slices, nothing that owns anything. That is
//! what lets a row be moved with a `memcpy` when an entity gains a component,
//! a column be handed to a job as a slice, and a world be written to a file
//! that opens on another machine. A texture is therefore a handle and not a
//! pointer - see `assets`.
//!
//! **`extern struct`** rather than a plain one, because these end up in a
//! vertex buffer by way of the renderer and because the layout being fixed
//! makes a saved world readable by a build that added a field somewhere else.
//! It costs nothing here: every field is a float already in declaration
//! order.
//!
//! **The coordinate system is the interface's.** `+x` is right, `+y` is
//! *down*, and a rotation of a quarter turn takes `+x` towards `+y`, which
//! looks clockwise on screen. That is the same system
//! [Fluxion UI](https://github.com/kisstp2006/fluxion-ui) lays out in and the
//! same one a texture is stored in, so a sprite at `(0, 0)` and a UI element
//! at `(0, 0)` are in the same corner. Choosing the mathematician's `+y` up
//! instead would mean one of the three layers disagreeing with the other two,
//! and the layer that would have to flip is the one with the text in it.

const std = @import("std");
const testing = std.testing;

const assets = @import("assets.zig");

/// A colour, four floats from zero to one. `.hex(0x3AA0FF)` is the spelling
/// to reach for. See `color`.
pub const Color = @import("color.zig").Color;

/// Where a thing is, how big, and which way round.
pub const Transform2D = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Radians. Positive turns `+x` towards `+y`, which is clockwise on a
    /// screen whose `y` points down.
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// A transform at a point, unrotated and unscaled. The common case, and
    /// worth a name so the other three fields do not have to be written to
    /// say nothing.
    pub fn at(x: f32, y: f32) Transform2D {
        return .{ .x = x, .y = y };
    }

    /// Move by an amount. `t.translate(dx * dt, dy * dt)` is what a movement
    /// system spends its time doing.
    pub fn translate(self: *Transform2D, dx: f32, dy: f32) void {
        self.x += dx;
        self.y += dy;
    }

    /// The same scale on both axes.
    pub fn scaled(self: Transform2D, factor: f32) Transform2D {
        var out = self;
        out.scale_x *= factor;
        out.scale_y *= factor;
        return out;
    }

    /// Turn a point in this transform's own space into world space.
    ///
    /// Written out rather than built from a matrix type because it is two
    /// sines and four multiplies, and the renderer does it for every corner
    /// of every sprite every frame.
    pub fn apply(self: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
        const sx = x * self.scale_x;
        const sy = y * self.scale_y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        return .{
            .x = self.x + sx * c - sy * s,
            .y = self.y + sx * s + sy * c,
        };
    }
};

/// Which part of a texture a sprite shows, in zero to one.
///
/// Normalised rather than in texels, because that is what the shader wants
/// and because it survives the texture being replaced by one at a different
/// resolution - which is what an art pass does to every file in the game.
/// `fromPixels` is there for whoever has the sprite sheet's numbers in front
/// of them, which is everybody.
pub const Region = extern struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,

    /// The whole texture.
    pub const full: Region = .{};

    /// A rectangle of a sprite sheet, in texels, given the size of the sheet.
    pub fn fromPixels(x: f32, y: f32, w: f32, h: f32, sheet_width: f32, sheet_height: f32) Region {
        return .{
            .u0 = x / sheet_width,
            .v0 = y / sheet_height,
            .u1 = (x + w) / sheet_width,
            .v1 = (y + h) / sheet_height,
        };
    }

    /// One cell of a grid of them, counting left to right and then down.
    /// What an animation strip is made of.
    pub fn cell(index: u32, columns: u32, rows: u32) Region {
        const cw = 1 / @as(f32, @floatFromInt(columns));
        const ch = 1 / @as(f32, @floatFromInt(rows));
        const cx = @as(f32, @floatFromInt(index % columns)) * cw;
        const cy = @as(f32, @floatFromInt((index / columns) % rows)) * ch;
        return .{ .u0 = cx, .v0 = cy, .u1 = cx + cw, .v1 = cy + ch };
    }

    /// The same region, mirrored. What a character walking the other way is.
    pub fn flippedX(self: Region) Region {
        return .{ .u0 = self.u1, .v0 = self.v0, .u1 = self.u0, .v1 = self.v1 };
    }

    pub fn flippedY(self: Region) Region {
        return .{ .u0 = self.u0, .v0 = self.v1, .u1 = self.u1, .v1 = self.v0 };
    }
};

/// A picture drawn at a transform.
pub const Sprite = extern struct {
    /// What to draw. `.none` - the default, and what a zeroed component is -
    /// draws a rectangle of solid `tint`, because the renderer falls back to
    /// the white texel.
    texture: assets.TextureHandle = .none,

    /// Multiplied into whatever the texture says. White leaves it alone;
    /// anything else tints it, and the alpha fades it.
    tint: Color = .white,

    /// Which part of the texture.
    region: Region = .full,

    /// How big it is in world units, before the transform's scale.
    ///
    /// Zero on either axis means "as many world units as the region has
    /// texels", which for a game whose camera is at zoom 1 means the sprite
    /// comes out the size of its own artwork. That default is why most
    /// sprites need no size at all.
    width: f32 = 0,
    height: f32 = 0,

    /// Which point of the sprite sits on the transform, in zero to one.
    /// The middle by default, so rotation spins a thing about itself.
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,

    /// What is drawn on top of what. Higher is nearer the viewer.
    ///
    /// Within one layer the order is the order the archetypes happen to be
    /// in, which is not an order to depend on. Between layers it is this
    /// number, and it is a sort key rather than a depth value: the 2D pass
    /// blends back to front with no depth test, because half-transparent
    /// pixels and a depth buffer disagree about what is behind them.
    layer: i16 = 0,

    /// Skipped entirely when false. Cheaper than removing the component and
    /// adding it back, which moves the entity between two archetypes twice.
    visible: bool = true,

    /// A sprite showing the whole of a texture at its own size.
    pub fn of(texture: assets.TextureHandle) Sprite {
        return .{ .texture = texture };
    }

    /// A rectangle of solid colour, with no texture at all.
    pub fn solid(color: Color, width: f32, height: f32) Sprite {
        return .{ .tint = color, .width = width, .height = height };
    }
};

/// What the 2D pass looks through.
///
/// The camera's *position* is its entity's `Transform2D`, and its position is
/// the centre of the view - not a corner. An entity with both is a camera;
/// there is no separate registry to keep in step with the world.
///
/// **With no camera in the world at all**, the pass draws with the origin at
/// the top left corner of the window and one world unit to the pixel, which
/// is the same coordinate system as the interface layer. That is a deliberate
/// default rather than an oversight: a game that has not thought about
/// cameras yet is usually laying things out in screen coordinates, and it
/// should be able to.
pub const Camera2D = extern struct {
    /// Bigger is closer in. 2 draws everything at twice the size.
    zoom: f32 = 1,

    /// Radians, the same sense as `Transform2D.rotation`. The world turns the
    /// other way, which is what a camera rotating means.
    rotation: f32 = 0,

    /// Which camera to use when there is more than one. The one with the
    /// highest `priority` that is `active` wins; ties go to whichever the
    /// archetypes are walked first, which is not an order to depend on.
    priority: i16 = 0,

    active: bool = true,

    pub fn atZoom(zoom: f32) Camera2D {
        return .{ .zoom = zoom };
    }
};

test "a transform maps its own space into the world" {
    const t: Transform2D = .{ .x = 10, .y = 20, .rotation = std.math.pi / 2.0, .scale_x = 2, .scale_y = 2 };
    const p = t.apply(1, 0);

    // A quarter turn takes +x to +y, and the scale doubled the length.
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 22), p.y, 0.0001);
}

test "a cell of a strip is the strip divided up" {
    const r: Region = .cell(1, 4, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.u0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.u1, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), r.v0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), r.v1, 0.0001);
}

test "mirroring swaps the horizontal edges and leaves the vertical ones" {
    const r: Region = .fromPixels(0, 0, 16, 16, 64, 64);
    const flipped = r.flippedX();
    try testing.expectEqual(r.u1, flipped.u0);
    try testing.expectEqual(r.u0, flipped.u1);
    try testing.expectEqual(r.v0, flipped.v0);
}

test "every engine component is one the world will accept" {
    const ecs = @import("fluxion_ecs");
    // This is the check the world would make when the component is first
    // used, brought forward so a field that cannot be a component is a
    // failing test here rather than a compile error in somebody's game.
    ecs.component.check(Transform2D);
    ecs.component.check(Sprite);
    ecs.component.check(Camera2D);
}
