// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself knows about.
//!
//! There are seven, and the list is deliberately short. A game invents its own
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

const ecs = @import("fluxion_ecs");
const assets = @import("assets.zig");

/// What names a thing in the world. Re-exported because `Parent` holds one.
pub const Entity = ecs.Entity;

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
    /// Between layers it is this number, and it is a sort key rather than a
    /// depth value: the 2D pass blends back to front with no depth test,
    /// because half-transparent pixels and a depth buffer disagree about what
    /// is behind them. Within one layer, see `order`.
    layer: i16 = 0,

    /// Skipped entirely when false. Cheaper than removing the component and
    /// adding it back, which moves the entity between two archetypes twice.
    visible: bool = true,

    /// Where a sprite sits *within* its layer. Lower is drawn first.
    ///
    /// Zero for everything, by default, and then sprites of one layer are
    /// grouped by texture so each texture is one draw call. Setting it is how
    /// a top-down game sorts by feet: a system in `.late` copying
    /// `transform.y` in here makes a thing lower on the screen draw over a
    /// thing higher up. That costs the grouping, which is the trade a
    /// y-sorted layer always makes.
    ///
    /// Two sprites with the same layer, order and texture are drawn in the
    /// order they were found, which is stable from one frame to the next.
    order: f32 = 0,

    /// A sprite showing the whole of a texture at its own size.
    pub fn of(texture: assets.TextureHandle) Sprite {
        return .{ .texture = texture };
    }

    /// A rectangle of solid colour, with no texture at all.
    pub fn solid(color: Color, width: f32, height: f32) Sprite {
        return .{ .tint = color, .width = width, .height = height };
    }
};

/// Where a thing *was* before the last fixed step, for drawing it smoothly.
///
/// ```zig
/// _ = try world.spawnWith(.{ Transform2D.at(0, 0), Sprite.of(hero), Previous2D{} });
/// ```
///
/// A body moved in the `.fixed` stage jumps sixty times a second, and a
/// screen that refreshes a hundred and forty-four times a second shows every
/// jump twice and some three times, which is the stutter that makes a
/// fixed-step game look worse than the loop it runs on. The cure is to draw
/// each frame somewhere *between* the last two steps, at `Time.alpha`.
///
/// Add this component to anything that moves in `.fixed` and wants to be
/// drawn between steps. The engine fills it in: before every fixed step it
/// copies the entity's `Transform2D` here, and the renderer blends the two by
/// `alpha`. Nothing about the game's own systems changes - they keep writing
/// the `Transform2D` and never look at this one.
///
/// Leave it off anything moved in `.update`, which already moves once a
/// frame and would only be drawn a frame late.
pub const Previous2D = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// False until the engine has taken the first snapshot, so a thing spawned
    /// this frame is drawn where it is rather than slid in from the origin.
    valid: bool = false,

    /// Take a copy of where a thing is now. What the engine does before each
    /// fixed step, and what a game does itself when it teleports something
    /// and does not want the renderer to draw the journey.
    pub fn snapshot(self: *Previous2D, now: Transform2D) void {
        self.* = .{
            .x = now.x,
            .y = now.y,
            .rotation = now.rotation,
            .scale_x = now.scale_x,
            .scale_y = now.scale_y,
            .valid = true,
        };
    }

    /// Somewhere between here and `now`, at `t` from zero to one.
    ///
    /// The rotation is blended as a plain number, so a thing that turns more
    /// than half a circle in one step is drawn going the long way round.
    /// Nothing moving at sixty steps a second turns that fast.
    pub fn blend(self: Previous2D, now: Transform2D, t: f32) Transform2D {
        if (!self.valid) return now;
        return .{
            .x = std.math.lerp(self.x, now.x, t),
            .y = std.math.lerp(self.y, now.y, t),
            .rotation = std.math.lerp(self.rotation, now.rotation, t),
            .scale_x = std.math.lerp(self.scale_x, now.scale_x, t),
            .scale_y = std.math.lerp(self.scale_y, now.scale_y, t),
        };
    }
};

/// Attaches one entity to another, so that moving the parent moves the child.
///
/// ```zig
/// const tank = try world.spawnWith(.{ Transform2D.at(100, 100), Sprite.of(hull) });
/// _ = try world.spawnWith(.{
///     Transform2D{},                       // written by the engine, not by you
///     Sprite.of(turret),
///     Parent{ .entity = tank, .local = .at(0, -6) },
/// });
/// ```
///
/// **The local position lives in this component, and `Transform2D` stays the
/// world one.** That is the opposite way round from Godot and from Bevy,
/// where the transform is local and a second, derived component holds the
/// world one - and it is a deliberate trade with a reason on each side.
///
/// Their way needs the engine to add a component to every entity that has a
/// transform, which in an archetype world means moving every one of those
/// rows into another table. This way a child costs one component, a root
/// costs nothing at all, the renderer reads one field whether or not anything
/// is parented, and every system that asks where a thing *is* - collision, a
/// camera, a spatial index - gets the answer without composing anything.
///
/// The cost is the surprise: writing `transform.x` on a child moves it for
/// one frame and is then overwritten. Move a child by its `local`.
///
/// **Cycles are survived, not diagnosed.** Following the chain stops after
/// `max_depth` links, so an entity accidentally made its own ancestor draws
/// somewhere wrong instead of hanging the frame.
pub const Parent = extern struct {
    /// Who to follow. `.none` - or a handle to something that has died -
    /// leaves the child where the last resolved frame put it.
    entity: Entity = .none,

    /// Where this sits in the parent's own space.
    local: Transform2D = .{},

    /// Whether the child turns with the parent. Off for a health bar over a
    /// spinning enemy, which should follow it round without tipping over.
    ///
    /// The *offset* is turned by the parent either way - that is what being
    /// attached to something means. This is only about the child's own angle.
    inherit_rotation: bool = true,

    /// Whether the parent's scale multiplies the child's.
    inherit_scale: bool = true,

    /// How many links of a chain are followed before giving up. Deep enough
    /// for a skeleton, shallow enough that a cycle is noticed within a frame.
    pub const max_depth: u8 = 16;

    /// Where a child ends up, given where its parent ended up.
    pub fn resolve(self: Parent, parent: Transform2D) Transform2D {
        const placed = parent.apply(self.local.x, self.local.y);
        return .{
            .x = placed.x,
            .y = placed.y,
            .rotation = if (self.inherit_rotation)
                parent.rotation + self.local.rotation
            else
                self.local.rotation,
            .scale_x = if (self.inherit_scale)
                parent.scale_x * self.local.scale_x
            else
                self.local.scale_x,
            .scale_y = if (self.inherit_scale)
                parent.scale_y * self.local.scale_y
            else
                self.local.scale_y,
        };
    }
};

/// A sprite that walks through the cells of its own texture.
///
/// ```zig
/// _ = try world.spawnWith(.{
///     Transform2D.at(64, 64),
///     Sprite.of(hero),
///     Animation{ .length = 6, .columns = 6, .fps = 10 },
/// });
/// ```
///
/// The engine advances it once a frame - in `.update` rather than `.fixed`,
/// because an animation is something a viewer sees and not something the
/// simulation depends on - and writes the result into `Sprite.region`. A game
/// that would rather drive the region itself leaves this component off.
///
/// **The strip is a grid, counted left to right and then down**, which is how
/// every sprite sheet an artist hands over is arranged. `first` is where this
/// animation starts in that grid, so one sheet holds a walk, an idle and an
/// attack, and swapping between them is writing two numbers.
pub const Animation = extern struct {
    /// The cell this animation starts at, counting across the whole sheet.
    first: u16 = 0,
    /// How many cells it runs for. One is a still picture.
    length: u16 = 1,

    /// The shape of the whole sheet, in cells.
    columns: u16 = 1,
    rows: u16 = 1,

    /// Cells a second. Twelve is the usual hand-drawn rate.
    fps: f32 = 12,

    /// How far into the animation it is, in seconds. Kept rather than a frame
    /// number, so that changing `fps` part way through does not jump.
    time: f32 = 0,

    playing: bool = true,

    /// Whether it starts again at the end. A one-shot stops on its last cell
    /// and sets `finished`.
    looping: bool = true,

    /// True once a non-looping animation has reached its end. A game reads it
    /// to know when to swap back to the idle, and clears it by writing a new
    /// animation over the component.
    finished: bool = false,

    /// The first `length` cells of a single row, which is what most sheets
    /// are.
    pub fn strip(length: u16, fps: f32) Animation {
        return .{ .length = length, .columns = length, .rows = 1, .fps = fps };
    }

    /// Which cell of the sheet is showing.
    pub fn frame(self: Animation) u32 {
        if (self.length <= 1 or self.fps <= 0) return self.first;
        const step: u32 = @intFromFloat(@max(self.time, 0) * self.fps);
        const within = if (self.looping)
            step % self.length
        else
            @min(step, self.length - 1);
        return self.first + within;
    }

    /// Move it on by `delta` seconds, and say which cell to show.
    ///
    /// The clock is wound back by whole loops rather than left to grow, so an
    /// animation running for an hour is as precise as one that started a
    /// second ago - an `f32` counting seconds has lost its sixtieths by then.
    pub fn advance(self: *Animation, delta: f32) Region {
        if (self.playing and self.length > 1 and self.fps > 0) {
            self.time += delta;

            const loop = @as(f32, @floatFromInt(self.length)) / self.fps;
            if (self.looping) {
                while (self.time >= loop) self.time -= loop;
            } else if (self.time >= loop) {
                self.time = loop;
                self.finished = true;
                self.playing = false;
            }
        }
        return .cell(self.frame(), self.columns, self.rows);
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
    // This is the check the world would make when the component is first
    // used, brought forward so a field that cannot be a component is a
    // failing test here rather than a compile error in somebody's game.
    ecs.component.check(Transform2D);
    ecs.component.check(Sprite);
    ecs.component.check(Camera2D);
    ecs.component.check(Previous2D);
    ecs.component.check(Parent);
    ecs.component.check(Animation);
}

test "a child follows its parent round" {
    const parent: Transform2D = .{ .x = 100, .y = 100, .rotation = std.math.pi / 2.0 };
    const child: Parent = .{ .local = .at(10, 0) };

    // A quarter turn takes the offset from +x to +y, so the child ends up
    // below the parent rather than to its right.
    const placed = child.resolve(parent);
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 110), placed.y, 0.0001);
    try testing.expectApproxEqAbs(parent.rotation, placed.rotation, 0.0001);
}

test "a child that does not inherit rotation is still carried round" {
    const parent: Transform2D = .{ .x = 0, .y = 0, .rotation = std.math.pi / 2.0 };
    const child: Parent = .{ .local = .at(10, 0), .inherit_rotation = false };

    const placed = child.resolve(parent);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), placed.y, 0.0001);
    try testing.expectEqual(@as(f32, 0), placed.rotation);
}

test "scale multiplies down the chain" {
    const parent: Transform2D = .{ .scale_x = 2, .scale_y = 2 };
    const child: Parent = .{ .local = .{ .scale_x = 3, .scale_y = 3 } };
    try testing.expectEqual(@as(f32, 6), child.resolve(parent).scale_x);
}

test "an animation walks its cells and comes back round" {
    var animation: Animation = .strip(4, 10);

    try testing.expectEqual(@as(u32, 0), animation.frame());
    _ = animation.advance(0.1);
    try testing.expectEqual(@as(u32, 1), animation.frame());
    _ = animation.advance(0.2);
    try testing.expectEqual(@as(u32, 3), animation.frame());

    // A whole loop is four tenths of a second, so this is back at the start
    // rather than off the end of the sheet.
    _ = animation.advance(0.1);
    try testing.expectEqual(@as(u32, 0), animation.frame());
}

test "a one-shot stops on its last cell and says so" {
    var animation: Animation = .strip(3, 10);
    animation.looping = false;

    _ = animation.advance(1);
    try testing.expectEqual(@as(u32, 2), animation.frame());
    try testing.expect(animation.finished);
    try testing.expect(!animation.playing);
}

test "an animation with one cell never moves" {
    var animation: Animation = .{ .first = 5, .length = 1 };
    const region = animation.advance(10);
    try testing.expectEqual(@as(u32, 5), animation.frame());
    try testing.expectEqual(Region.cell(5, 1, 1).u0, region.u0);
}

test "a fresh snapshot is not blended from" {
    const now: Transform2D = .at(10, 20);
    const previous: Previous2D = .{};
    const drawn = previous.blend(now, 0.5);
    try testing.expectEqual(@as(f32, 10), drawn.x);
    try testing.expectEqual(@as(f32, 20), drawn.y);
}

test "a snapshot is blended halfway at half an alpha" {
    var previous: Previous2D = .{};
    previous.snapshot(.at(0, 0));
    const drawn = previous.blend(.at(10, 20), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 5), drawn.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), drawn.y, 0.0001);
}
