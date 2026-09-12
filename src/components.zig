// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself reads: `Transform2D`, `Sprite`,
//! `Text2D`, `Animation`, `Camera2D`, `RigidBody2D` and `Collider2D`. A game
//! declares its own beside them.
//!
//! ```zig
//! _ = try app.world.spawnWith(.{
//!     Transform2D{ .x = 320, .y = 180 },
//!     Sprite{ .texture = hero, .width = 48, .height = 48 },
//! });
//! ```
//!
//! All plain data, as fluxion-ecs requires - no pointers, nothing that owns
//! memory - so a row moves with a `memcpy` and a world saves to a file. The
//! coordinate system is the interface's: `+x` right, `+y` down, and a
//! positive rotation turns `+x` towards `+y`, which is clockwise on screen.
//!
//! Each is described to fluxion-reflect as well, for what reads a component
//! it was not compiled against - an inspector, a console: `reflect_name` is
//! the name a scene gives it, and `reflect_fields` says what a field's number
//! means where the name does not - a range, an angle, a unit, layers, a zero
//! that is not zero. See `attr`.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");
const assets = @import("assets.zig");
const attr = @import("attr.zig");

/// Re-exported because a transform names the entity it hangs from.
pub const Entity = ecs.Entity;

/// A colour, four floats from zero to one. See `color`.
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
/// The numbers are local - in the parent's space, as with Unity's
/// `Transform` and Godot's `Node2D` - and `App.worldTransform` gives the
/// world's. The parent is a field rather than a component, so gaining one
/// does not move the entity to another archetype.
pub const Transform2D = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Radians. Positive turns `+x` towards `+y`: clockwise on screen.
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// Whose space `x` and `y` are in. `.none` is the world.
    ///
    /// When the parent is despawned, so is this, at the end of that frame -
    /// and whatever hangs from this in turn. To keep it, write
    /// `App.worldTransform` over it first. A living parent with no
    /// `Transform2D` places nothing, and still owns what hangs from it.
    parent: Entity = .none,

    /// Whether this turns with its parent. Its offset turns either way; off is
    /// for a shadow or a name plate that should not tip over.
    inherit_rotation: bool = true,

    /// Whether the parent's scale multiplies this one's.
    inherit_scale: bool = true,

    /// Draw this between its last two fixed steps, for anything moved in
    /// `.fixed` - otherwise a 60 Hz step stutters on a 144 Hz screen. The
    /// engine keeps where it was; see `hierarchy.Snapshot`.
    interpolate: bool = false,

    /// How many links of a chain are followed before giving up: enough for a
    /// skeleton, few enough that a cycle is caught within a frame.
    pub const max_depth: u8 = 16;

    pub const reflect_name = "Transform2D";
    pub const reflect_fields = .{
        .rotation = .{ attr.Angle{}, attr.Doc{ .text = "Clockwise on screen" } },
        .parent = .{attr.Doc{ .text = "Whose space x and y are in; none is the world's" }},
    };
    pub const reflect_methods = .{.translate};

    /// A transform at a point, unrotated, unscaled and unparented.
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

    /// The same transform, drawn between fixed steps.
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

    /// `apply` undone: a point in the parent's space, in this transform's own.
    /// A scale of zero is left out rather than divided by.
    pub fn unapply(self: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
        const dx = x - self.x;
        const dy = y - self.y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        const rx = dx * c + dy * s;
        const ry = dy * c - dx * s;
        return .{
            .x = if (self.scale_x != 0) rx / self.scale_x else rx,
            .y = if (self.scale_y != 0) ry / self.scale_y else ry,
        };
    }

    /// Where `local` ends up, given where its parent ended up. The result has
    /// no parent of its own.
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

    /// One cell of a grid, counted left to right and then down.
    pub fn cell(index: u32, columns: u32, rows: u32) Region {
        const cw = 1 / @as(f32, @floatFromInt(columns));
        const ch = 1 / @as(f32, @floatFromInt(rows));
        const cx = @as(f32, @floatFromInt(index % columns)) * cw;
        const cy = @as(f32, @floatFromInt((index / columns) % rows)) * ch;
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

    /// Where a sprite sits within its layer: lower is drawn first. At zero, a
    /// layer's sprites are grouped by texture, one draw call each. Copying
    /// `transform.y` in here sorts a top-down game by feet, at the cost of
    /// that grouping. Ties keep a stable order.
    order: f32 = 0,

    pub const Blend = enum(u8) { alpha, additive };

    pub const reflect_name = "Sprite";
    pub const reflect_fields = .{
        .width = .{attr.Doc{ .text = "World units; zero is the region's width in texels" }},
        .height = .{attr.Doc{ .text = "World units; zero is the region's height in texels" }},
        .pivot_x = .{attr.Range{ .min = 0, .max = 1 }},
        .pivot_y = .{attr.Range{ .min = 0, .max = 1 }},
    };

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
/// The engine advances it once a frame and writes the cell into
/// `Sprite.region`. The sheet is a grid counted left to right and then down,
/// and `first` is where this animation starts, so one sheet can hold several.
pub const Animation = extern struct {
    /// The cell it starts at, counting across the whole sheet.
    first: u16 = 0,
    /// How many cells it runs for. One is a still picture.
    length: u16 = 1,

    /// The shape of the whole sheet, in cells.
    columns: u16 = 1,
    rows: u16 = 1,

    /// Cells a second. Twelve is the usual hand-drawn rate.
    fps: f32 = 12,

    /// Seconds into the animation, rather than a frame number, so changing
    /// `fps` part way through does not jump.
    time: f32 = 0,

    playing: bool = true,

    /// Whether it starts again at the end. A one-shot stops on its last cell
    /// and sets `finished`.
    looping: bool = true,

    /// Set when a one-shot reaches its end. Cleared by writing a new
    /// animation over the component.
    finished: bool = false,

    pub const reflect_name = "Animation";
    pub const reflect_fields = .{
        .fps = .{ attr.Unit{ .text = "/s" }, attr.Doc{ .text = "Cells a second" } },
        .time = .{ attr.Unit{ .text = "s" }, attr.Doc{ .text = "Into the animation" } },
        .finished = .{attr.ReadOnly{}},
    };
    pub const reflect_methods = .{.frame};

    /// The first `length` cells of a single row.
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

    /// Move it on by `delta` seconds, and say which cell to show. The clock is
    /// wound back by whole loops, so it stays precise however long it runs.
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
/// _ = try world.spawnWith(.{ Transform2D.at(16, 16), label });
///
/// // ... and later, from a system:
/// text.print("{d} points", .{score});
/// ```
///
/// The text is inside the component, in a fixed buffer: a component may not
/// own memory, and world text is short - a score, a name plate, "Press E".
/// The transform is the top left of the first line, not the baseline.
pub const Text2D = extern struct {
    /// UTF-8. Not a slice: see above.
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,

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

    /// Bytes of text that fit: 63 and a length make the component 96 bytes.
    pub const capacity = 63;

    pub const Alignment = enum(u8) { left, center, right };

    /// The buffer is no field to show or to edit: the words are the
    /// property `text`, read with `slice` and written with `set`, which keep
    /// the length and the UTF-8 right - and may run over several lines.
    pub const reflect_name = "Text2D";
    pub const reflect_attributes = .{attr.Property{ .name = "text", .get = "slice", .set = "set" }};
    pub const reflect_fields = .{
        .bytes = .{attr.Hidden{}},
        .len = .{attr.Hidden{}},
        .size = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "Per em, before the transform's scale" } },
    };
    pub const reflect_methods = .{
        .set = .{attr.Multiline{}},
        .slice = .{},
    };

    /// A label with this text in it, cut on a character boundary if it does
    /// not fit.
    pub fn of(run: []const u8) Text2D {
        var self: Text2D = .{};
        self.set(run);
        return self;
    }

    /// Replace the text.
    pub fn set(self: *Text2D, run: []const u8) void {
        const room = @min(run.len, capacity);
        // Back up to the start of a character rather than cut one in half. A
        // continuation byte is `10xxxxxx`.
        var cut = room;
        while (cut > 0 and cut < run.len and run[cut] & 0xC0 == 0x80) cut -= 1;

        @memcpy(self.bytes[0..cut], run[0..cut]);
        self.len = @intCast(cut);
    }

    /// Format into the label. Cut short rather than failing: a number too long
    /// to fit is no reason to stop the frame.
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

    pub const reflect_name = "Camera2D";
    pub const reflect_fields = .{
        .fit_width = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .fit_height = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .rotation = .{ attr.Angle{}, attr.Doc{ .text = "Clockwise on screen; the world turns the other way" } },
    };

    pub fn atZoom(zoom: f32) Camera2D {
        return .{ .zoom = zoom };
    }

    /// A camera that always shows the whole of an area this size.
    pub fn fitting(width: f32, height: f32) Camera2D {
        return .{ .fit_width = width, .fit_height = height };
    }
};

/// Something that moves as a solid object: it falls, is pushed and bounces.
/// What it collides with is its `Collider2D`, on this entity or on the ones
/// hanging from it.
///
/// ```zig
/// _ = try world.spawnWith(.{
///     Transform2D.at(320, 0).interpolated(),
///     Sprite.of(crate),
///     RigidBody2D{},
///     Collider2D{}, // the size of the sprite
/// });
/// ```
///
/// The body is in the world's space, so a moving parent does not carry it.
/// After every fixed step its place goes into the transform and its speed
/// into `velocity`; writing either moves the body or sets it going.
pub const RigidBody2D = extern struct {
    /// Changing it makes the body anew, and the joints to the old one go.
    type: Type = .dynamic,
    /// Units a second.
    velocity: math.Vec2 = .zero,
    /// Radians a second, clockwise on screen.
    angular_velocity: f32 = 0,
    linear_damping: f32 = 0,
    angular_damping: f32 = 0,
    /// Zero floats, minus one rises.
    gravity_scale: f32 = 1,
    fixed_rotation: bool = false,
    can_sleep: bool = true,
    /// Swept against other moving bodies too, not only the static ones.
    bullet: bool = false,

    /// Static never moves; kinematic moves at its velocity and nothing
    /// pushes it; dynamic is pushed by everything.
    pub const Type = physics.BodyType;

    pub const reflect_name = "RigidBody2D";
    pub const reflect_fields = .{
        .velocity = .{ attr.Unit{ .text = "/s" }, attr.Doc{ .text = "World units a second" } },
        .angular_velocity = .{ attr.Angle{}, attr.Unit{ .text = "/s" }, attr.Doc{ .text = "Clockwise on screen" } },
        .gravity_scale = .{attr.Doc{ .text = "Zero floats, minus one rises" }},
    };
};

/// The shape a body collides with. On an entity with a `RigidBody2D` it is
/// that body's, and on one hanging from such an entity it is part of that
/// body, where the entity is. Anywhere else it is a static body of its own:
/// a wall, a floor tile.
pub const Collider2D = extern struct {
    shape: Shape = .box,
    /// A box's size before the transform's scale. Zero takes the sprite's,
    /// and centres the shape on the sprite.
    width: f32 = 0,
    height: f32 = 0,
    /// Zero is half the sprite's width, centred on the sprite.
    radius: f32 = 0,
    /// From the entity's origin, before its scale.
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// A box's turn on the entity.
    rotation: f32 = 0,
    friction: f32 = 0.6,
    /// How much of the speed a hit gives back: zero a beanbag, one a
    /// superball.
    restitution: f32 = 0,
    /// Mass per square unit.
    density: f32 = 1,
    /// Reports what overlaps it and pushes nothing: a trigger, a pickup.
    sensor: bool = false,
    /// Who touches whom; see `physics.Filter`.
    category: u16 = 1,
    mask: u16 = 0xFFFF,
    group: i16 = 0,

    pub const Shape = enum(u8) { box, circle };

    pub const reflect_name = "Collider2D";
    pub const reflect_fields = .{
        .width = .{attr.Doc{ .text = "Zero is the sprite's width" }},
        .height = .{attr.Doc{ .text = "Zero is the sprite's height" }},
        .radius = .{attr.Doc{ .text = "Zero is half the sprite's width" }},
        .rotation = .{attr.Angle{}},
        .friction = .{attr.Range{ .min = 0, .max = 1 }},
        .restitution = .{attr.Range{ .min = 0, .max = 1 }},
        .density = .{attr.Doc{ .text = "Mass per square unit" }},
        .category = .{ attr.Layers{}, attr.Doc{ .text = "The layers it is on" } },
        .mask = .{ attr.Layers{}, attr.Doc{ .text = "The layers it touches" } },
    };

    pub fn box(width: f32, height: f32) Collider2D {
        return .{ .width = width, .height = height };
    }

    pub fn circle(radius: f32) Collider2D {
        return .{ .shape = .circle, .radius = radius };
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

test "a sprite's blend mode fits in the padding it already had" {
    try testing.expectEqual(64, @sizeOf(Sprite));
}

test "mirroring swaps the horizontal edges and leaves the vertical ones" {
    const r: Region = .fromPixels(0, 0, 16, 16, 64, 64);
    const flipped = r.flippedX();
    try testing.expectEqual(r.u1, flipped.u0);
    try testing.expectEqual(r.u0, flipped.u1);
    try testing.expectEqual(r.v0, flipped.v0);
}

test "every engine component is one the world will accept" {
    // The check the world makes on first use, brought forward into a test.
    ecs.component.check(Transform2D);
    ecs.component.check(Sprite);
    ecs.component.check(Camera2D);
    ecs.component.check(Animation);
    ecs.component.check(Text2D);
    ecs.component.check(RigidBody2D);
    ecs.component.check(Collider2D);
}

test "what an inspector shows a field by is on the field" {
    const reflect = @import("fluxion_reflect");
    try testing.expect(reflect.typeOf(Transform2D).field("rotation").?.attribute(attr.Angle) != null);
    try testing.expect(reflect.typeOf(Transform2D).field("x").?.attribute(attr.Angle) == null);
    try testing.expect(reflect.typeOf(Collider2D).field("mask").?.attribute(attr.Layers) != null);
    try testing.expectEqualStrings("px", reflect.typeOf(Text2D).field("size").?.attribute(attr.Unit).?.text);
    try testing.expectEqual(@as(f64, 1), reflect.typeOf(Collider2D).field("restitution").?.attribute(attr.Range).?.max);

    // The words of a label are its methods' to read and write, and they may
    // run over several lines.
    try testing.expect(reflect.typeOf(Text2D).field("bytes").?.attribute(attr.Hidden) != null);
    try testing.expect(reflect.typeOf(Text2D).method("set").?.attribute(attr.Multiline) != null);
    try testing.expect(reflect.typeOf(Text2D).method("slice").?.attribute(attr.Multiline) == null);
}

test "unapply takes a point back to where apply found it" {
    const t: Transform2D = .{ .x = 10, .y = -4, .rotation = 0.7, .scale_x = 2, .scale_y = 0.5 };
    const out = t.apply(3, 5);
    const back = t.unapply(out.x, out.y);
    try testing.expectApproxEqAbs(@as(f32, 3), back.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5), back.y, 0.0001);
}

test "a child is carried round by its parent" {
    const parent: Transform2D = .{ .x = 100, .y = 100, .rotation = std.math.pi / 2.0 };
    const local: Transform2D = .at(10, 0);

    // A quarter turn puts the child below the parent, not to its right.
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
    // `é` is two bytes, so byte 63 is the middle of the thirty-second one:
    // the cut has to back up to 62.
    var label: Text2D = .of("é" ** 40);
    try testing.expectEqual(@as(u8, 62), label.len);
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

    // A whole loop is 0.4 seconds, so this is back at the start.
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
