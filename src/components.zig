// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself knows about.
//!
//! There are five - `Transform2D`, `Sprite`, `Text2D`, `Animation` and
//! `Camera2D` - and the list is deliberately short. A game invents its own -
//! `Health`, `Wave`, `PatrolRoute` - and the engine never sees them; these
//! are only the ones the engine itself reads, because something has to agree
//! on where a thing is before it can be drawn there.
//!
//! Each one is a thing somebody making a game would name, which is the test a
//! component has to pass here. `Parent` and `Previous2D` used to be on this
//! list and are not any more: parenting is what a transform *does* - Unity
//! puts it on `Transform` and Godot puts it in the tree - and where something
//! was a step ago is the engine's own bookkeeping, which a game should never
//! have to declare. Both are fields of `Transform2D` now.
//!
//! `Color` and `Region` are in this file too and are *not* components. They
//! are values that live inside one - a tint, a rectangle of a sprite sheet -
//! and putting either on an entity of its own would mean nothing.
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

/// What names a thing in the world. Re-exported because a transform names
/// the one it hangs from.
pub const Entity = ecs.Entity;

/// A colour, four floats from zero to one. `.hex(0x3AA0FF)` is the spelling
/// to reach for. See `color`.
pub const Color = @import("color.zig").Color;

/// Where a thing is, how big, which way round, and what it hangs from.
///
/// ```zig
/// const tank = try world.spawnWith(.{ Transform2D.at(100, 100), Sprite.of(hull) });
/// _ = try world.spawnWith(.{
///     Transform2D.childOf(tank, 0, -6),
///     Sprite.of(turret),
/// });
/// ```
///
/// **The numbers are local.** They are in the parent's space, and in the
/// world's only when there is no parent - which is Unity's `Transform` and
/// Godot's `Node2D`, and is what people mean when they move a turret by one:
/// one along the tank, not one along the world. `App.worldTransform` is the
/// other one, `global_position` by another name, and it costs a walk up the
/// chain rather than a field read.
///
/// **The parent is a field rather than a component of its own.** A component
/// here has to be something a person making a game would name, and nobody
/// names "parent" - they name the turret and say what it is on. Unity agrees
/// (`transform.parent`) and so does Godot (the tree itself). Keeping it here
/// also means an entity gains a parent without moving between archetype
/// tables, which is what a separate component would cost.
pub const Transform2D = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Radians. Positive turns `+x` towards `+y`, which is clockwise on a
    /// screen whose `y` points down.
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// Whose space `x` and `y` are in. `.none` is the world.
    ///
    /// **What hangs from something goes with it.** When the parent is
    /// despawned, so is this - at the end of that frame, before anything is
    /// drawn - and so is whatever hangs from this in turn. That is Unity's
    /// rule and Godot's, and it is the one a scene made of parts wants: a
    /// creature that dies takes its eyes, its shadow and its name plate with
    /// it, rather than leaving them hanging in the air where it stood. To keep
    /// something when what it hangs from goes, let go of it first:
    /// `App.worldTransform` has no parent in it, so writing that over this
    /// transform keeps the thing exactly where it was.
    ///
    /// A parent that is alive and has no `Transform2D` of its own is
    /// somewhere nobody can say, so it places nothing - these numbers are the
    /// world's, as if there were no parent - and it still owns this. An entity
    /// with no transform is therefore a way to say "these belong together"
    /// without saying where: despawn it, and they all go.
    parent: Entity = .none,

    /// Whether this turns with its parent.
    ///
    /// The *offset* is turned either way - that is what being attached to
    /// something means. This is only about the thing's own angle, and it is
    /// off for a shadow on the ground and for a name plate over a leaning
    /// creature, both of which should follow without tipping over. Godot
    /// spells the all-or-nothing version of this `top_level`.
    inherit_rotation: bool = true,

    /// Whether the parent's scale multiplies this one's.
    inherit_scale: bool = true,

    /// Draw this between its last two fixed steps rather than at the latest.
    ///
    /// For anything moved in the `.fixed` stage. A body stepped sixty times a
    /// second on a screen that refreshes a hundred and forty-four times shows
    /// every step twice and some three times, which is the stutter that makes
    /// a fixed-step game look worse than the loop it runs on; drawing it
    /// somewhere between the last two steps is the cure.
    ///
    /// The engine keeps where it was - see `hierarchy.Snapshot` - so nothing
    /// about a game's own systems changes. They keep writing this transform
    /// and never look at the other one. Leave it off anything moved in
    /// `.update`, which already moves once a frame.
    interpolate: bool = false,

    /// How many links of a chain are followed before giving up. Deep enough
    /// for a skeleton, shallow enough that a cycle is noticed within a frame.
    pub const max_depth: u8 = 16;

    /// A transform at a point, unrotated, unscaled and unparented. The common
    /// case, and worth a name so the other fields do not have to be written
    /// to say nothing.
    pub fn at(x: f32, y: f32) Transform2D {
        return .{ .x = x, .y = y };
    }

    /// A transform at a point in something else's space.
    pub fn childOf(parent: Entity, x: f32, y: f32) Transform2D {
        return .{ .x = x, .y = y, .parent = parent };
    }

    /// Move by an amount, in whatever space this transform is in.
    pub fn translate(self: *Transform2D, dx: f32, dy: f32) void {
        self.x += dx;
        self.y += dy;
    }

    /// The same transform, drawn between fixed steps. For anything a `.fixed`
    /// system moves: `Transform2D.at(10, 20).interpolated()`.
    pub fn interpolated(self: Transform2D) Transform2D {
        var out = self;
        out.interpolate = true;
        return out;
    }

    /// The same scale on both axes.
    pub fn scaled(self: Transform2D, factor: f32) Transform2D {
        var out = self;
        out.scale_x *= factor;
        out.scale_y *= factor;
        return out;
    }

    /// Turn a point in this transform's own space into its parent's.
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

    /// Where `local` ends up, given where its parent ended up.
    ///
    /// The result carries no parent of its own: it is a world transform, and
    /// composing it again would apply the same chain twice.
    pub fn compose(parent: Transform2D, local: Transform2D) Transform2D {
        const placed = parent.apply(local.x, local.y);
        return .{
            .x = placed.x,
            .y = placed.y,
            .rotation = if (local.inherit_rotation)
                parent.rotation + local.rotation
            else
                local.rotation,
            .scale_x = if (local.inherit_scale)
                parent.scale_x * local.scale_x
            else
                local.scale_x,
            .scale_y = if (local.inherit_scale)
                parent.scale_y * local.scale_y
            else
                local.scale_y,
            .parent = .none,
            .interpolate = local.interpolate,
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

/// Words drawn at a transform, in a font the assets are holding.
///
/// ```zig
/// var label: Text2D = .of("Score");
/// label.size = 24;
/// label.color = .hex(0xE6E9EF);
/// _ = try world.spawnWith(.{ Transform2D.at(16, 16), label });
///
/// // ... and later, from a system:
/// text.print("{d} points", .{score});
/// ```
///
/// **The text is inside the component**, in a fixed buffer, rather than a
/// slice into somewhere else. A component may not own memory - that is what
/// lets a row be moved with a `memcpy` and a world be written to a file - so
/// the choice was between an index into a table of strings the engine keeps
/// and a few dozen bytes carried in the row. The bytes win for what world
/// text actually is: a score, a name plate, a damage figure, "Press E". A
/// paragraph is not this component's job, and when there is a paragraph to
/// draw it will be the interface layer's.
///
/// `print` is the one to reach for, because a game's text is nearly always a
/// number that changed.
///
/// **The transform is the top left of the first line**, not the baseline.
/// Baselines are how a font thinks and corners are how a person placing a
/// label thinks, and the renderer knows the ascent it takes to convert.
pub const Text2D = extern struct {
    /// The bytes, as UTF-8. Not a slice: see above.
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,

    /// Which font. `.none` means the first one that was loaded - see
    /// `assets.default_font` - so a game with one font never names it.
    font: assets.FontHandle = .none,

    /// Pixels per em, before the transform's scale. Rounded to whole pixels
    /// when the glyphs are rasterised, so easing a label from 15.6 to 16.4
    /// does not fill the atlas with an alphabet a frame.
    size: f32 = 16,

    color: Color = .white,

    /// Where the transform sits along the line.
    alignment: Alignment = .left,

    /// Multiplies the font's own line height, for text that wants to breathe.
    line_spacing: f32 = 1,

    /// The same two numbers a `Sprite` sorts by, and they mean the same
    /// thing: text and sprites are in one list and one order.
    layer: i16 = 0,
    order: f32 = 0,

    visible: bool = true,

    /// How many bytes of text fit. Sixty-three and a length, so the whole
    /// component is a round ninety-six bytes.
    pub const capacity = 63;

    pub const Alignment = enum(u8) { left, center, right };

    /// A label with this text in it. Truncated if it does not fit, on a
    /// character boundary rather than in the middle of one.
    pub fn of(run: []const u8) Text2D {
        var self: Text2D = .{};
        self.set(run);
        return self;
    }

    /// Replace the text.
    pub fn set(self: *Text2D, run: []const u8) void {
        const room = @min(run.len, capacity);
        // Cutting a UTF-8 sequence in half would put a broken character at
        // the end, so back up to where one starts. A continuation byte is
        // `10xxxxxx`; anything else begins a character.
        var cut = room;
        while (cut > 0 and cut < run.len and run[cut] & 0xC0 == 0x80) cut -= 1;

        @memcpy(self.bytes[0..cut], run[0..cut]);
        self.len = @intCast(cut);
    }

    /// Format into the label, which is what a score does every frame.
    ///
    /// Silently truncated rather than failing: a number too long to fit is a
    /// display problem and not a reason for a frame to stop.
    pub fn print(self: *Text2D, comptime format: []const u8, args: anytype) void {
        var buffer: [capacity]u8 = undefined;
        const written = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
        self.set(written);
    }

    /// The text, as a string.
    pub fn slice(self: *const Text2D) []const u8 {
        return self.bytes[0..self.len];
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
    ///
    /// With `fit_width` and `fit_height` set, this multiplies the fit rather
    /// than replacing it: 1 shows exactly the fitted area, 2 half of it.
    zoom: f32 = 1,

    /// A part of the world that is always all on screen, whatever size the
    /// window is: the play field of a game designed at one size.
    ///
    /// The view is scaled so this area fits the window with nothing cut off,
    /// and whatever room the window has spare in one direction shows more of
    /// the world around it. Zero on either - the default - is no fit, and one
    /// world unit is one pixel before `zoom`. Doing this by hand is a system
    /// reading the window's size every frame and writing the zoom, which is
    /// what `pong` did.
    fit_width: f32 = 0,
    fit_height: f32 = 0,

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

    /// A camera that always shows the whole of an area this size. See
    /// `fit_width`.
    pub fn fitting(width: f32, height: f32) Camera2D {
        return .{ .fit_width = width, .fit_height = height };
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
    ecs.component.check(Animation);
    ecs.component.check(Text2D);
}

test "a child is carried round by its parent" {
    const parent: Transform2D = .{ .x = 100, .y = 100, .rotation = std.math.pi / 2.0 };
    const local: Transform2D = .at(10, 0);

    // A quarter turn takes the offset from +x to +y, so the child ends up
    // below the parent rather than to its right.
    const placed = Transform2D.compose(parent, local);
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 110), placed.y, 0.0001);
    try testing.expectApproxEqAbs(parent.rotation, placed.rotation, 0.0001);
}

test "a child that does not inherit rotation is still carried round" {
    const parent: Transform2D = .{ .rotation = std.math.pi / 2.0 };
    var local: Transform2D = .at(10, 0);
    local.inherit_rotation = false;

    const placed = Transform2D.compose(parent, local);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), placed.y, 0.0001);
    try testing.expectEqual(@as(f32, 0), placed.rotation);
}

test "scale multiplies down the chain" {
    const parent: Transform2D = .{ .scale_x = 2, .scale_y = 2 };
    const local: Transform2D = .{ .scale_x = 3, .scale_y = 3 };
    try testing.expectEqual(@as(f32, 6), Transform2D.compose(parent, local).scale_x);
}

test "a composed transform has no parent left to apply" {
    const parent: Transform2D = .at(5, 5);
    const local: Transform2D = .childOf(.none, 1, 1);
    try testing.expect(Transform2D.compose(parent, local).parent.isNone());
}

test "a label carries its own text" {
    var label: Text2D = .of("Score");
    try testing.expectEqualStrings("Score", label.slice());

    label.print("{d} points", .{42});
    try testing.expectEqualStrings("42 points", label.slice());
}

test "text too long is cut on a character boundary" {
    // Twenty-two three-byte characters is sixty-six bytes, which is three
    // more than fit - so the last whole one has to go, not two thirds of it.
    var label: Text2D = .of("hétfőkedd" ** 8);
    try testing.expect(label.len <= Text2D.capacity);
    try testing.expect(std.unicode.utf8ValidateSlice(label.slice()));
}

test "an empty label is empty rather than sixty-three zeroes" {
    const label: Text2D = .{};
    try testing.expectEqual(@as(usize, 0), label.slice().len);
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
