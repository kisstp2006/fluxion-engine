// SPDX-License-Identifier: BSD-3-Clause

//! Light in the 2D world: lamps, torches, a moon through a window, and the
//! shadows walls cast from them.
//!
//! ```zig
//! _ = try world.spawnWith(.{ fx.AmbientLight2D{ .color = .rgba(0.15, 0.15, 0.25, 1) } });
//! _ = try world.spawnWith(.{ fx.Transform2D.at(300, 200), fx.PointLight2D{ .radius = 180, .shadows = true } });
//! _ = try world.spawnWith(.{ fx.Transform2D.at(360, 220), fx.Sprite{ .texture = crate }, fx.LightOccluder2D{} });
//! ```
//!
//! **The world is lit as a whole.** Once a view sees a light or an
//! `AmbientLight2D`, what it draws of the world is multiplied by the light
//! that falls there: the ambient light - white without one, so a light
//! only brightens - and every light's added on, or taken off for one that
//! subtracts. Light can make what it falls on up to twice as bright. The
//! interface is never lit, and neither is what an `Appearance` marks
//! `unshaded`, which is drawn over the lit world.
//!
//! **A `PointLight2D`** shines from its entity to `radius` away, fading to
//! nothing there - or as its own `texture` says, stretched over that reach
//! and turned with the entity: a torch's cone. **A `DirectionalLight2D`**
//! lights everything alike, falling along its entity's `+y`.
//!
//! **Shadows.** A light with `shadows` is stopped by every
//! `LightOccluder2D` - a box, a circle or a capsule, the sprite's size when
//! it gives none, as a `Collider2D` is - and by the solid tiles of a
//! `TileMap` with `light_occlusion`. What an occluder hides of a light is
//! multiplied by its `shadow_color`: black, and nothing of the light gets
//! there. An occluder's own face toward the light is lit. A light with a
//! `shadow_softness` is as wide as that, and its shadows' edges soften the
//! farther they fall.
//!
//! The lights are the `render_layers` of their `Appearance`: a camera whose
//! `cull_mask` does not see a light's layers is not lit by it.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");

const attr = @import("../reflect/attr.zig");
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const components = @import("../scene/components.zig");

const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;

/// Whether a light adds to the light where it falls, or takes from it.
pub const Blend = enum(u8) { add, subtract };

pub const PointLight2D = extern struct {
    enabled: bool = true,
    color: Color = .white,
    /// How strong it is: one adds its colour where it is brightest.
    energy: f32 = 1,
    /// How far it reaches: it fades to nothing there.
    radius: f32 = 128,
    /// How it falls off, stretched over its reach and turned with its
    /// entity; none is a soft round glow.
    texture: Assets.TextureHandle = .none,
    blend: Blend = .add,
    shadows: bool = false,
    /// What it is multiplied by where an occluder hides it; its alpha is how
    /// much.
    shadow_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    /// How far across the light is, for its shadows: nought is a point, and
    /// its shadows' edges are sharp; the wider, the softer they are, and the
    /// softer the farther they fall.
    shadow_softness: f32 = 0,

    pub const reflect_name = "PointLight2D";
    pub const reflect_fields = .{
        .energy = .{attr.Range{ .min = 0, .max = 16 }},
        .radius = .{ attr.Radius{}, attr.Doc{ .text = "How far it reaches" } },
        .texture = .{attr.Doc{ .text = "How it falls off; none is a soft round glow" }},
        .shadows = .{ attr.Doc{ .text = "Stopped by light occluders" }, attr.Group{ .name = "Shadows" } },
        .shadow_color = .{attr.Doc{ .text = "What it is multiplied by in shadow" }},
        .shadow_softness = .{ attr.Range{ .min = 0, .max = 256 }, attr.Doc{ .text = "How wide the light is: its shadows' edges are softer the wider it is" } },
    };
};

pub const DirectionalLight2D = extern struct {
    enabled: bool = true,
    color: Color = .white,
    energy: f32 = 0.5,
    blend: Blend = .add,
    shadows: bool = false,
    shadow_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    /// How far either way from its way the light comes, for its shadows:
    /// nought is sharp, and more is softer the farther they fall.
    shadow_softness: f32 = 0,
    /// How far behind an occluder its shadow reaches.
    max_distance: f32 = 2000,

    pub const reflect_name = "DirectionalLight2D";
    pub const reflect_fields = .{
        .energy = .{attr.Range{ .min = 0, .max = 16 }},
        .shadows = .{ attr.Doc{ .text = "Stopped by light occluders" }, attr.Group{ .name = "Shadows" } },
        .shadow_color = .{attr.Doc{ .text = "What it is multiplied by in shadow" }},
        .shadow_softness = .{ attr.Angle{}, attr.Doc{ .text = "How far either way the light comes from: its shadows are softer the more" } },
        .max_distance = .{attr.Doc{ .text = "How far behind an occluder its shadow reaches" }},
    };
};

/// The light everywhere, before any light is added: night, a cellar.
pub const AmbientLight2D = extern struct {
    color: Color = .{ .r = 0.25, .g = 0.25, .b = 0.3, .a = 1 },

    pub const reflect_name = "AmbientLight2D";
    pub const reflect_fields = .{
        .color = .{attr.Doc{ .text = "The light everywhere; white is none taken away" }},
    };
};

/// A shape a light with `shadows` does not get past: sized as a
/// `Collider2D` is.
pub const LightOccluder2D = extern struct {
    enabled: bool = true,
    shape: Shape = .rectangle,
    /// Half a rectangle's width and height, before the transform's scale.
    /// Zero takes the sprite's size, and centres the shape on the sprite. A
    /// capsule's `y` is half its whole height.
    extents: Vec2 = .zero,
    /// A circle's, and a capsule's round ends'. Zero is half the sprite's
    /// width.
    radius: f32 = 0,
    /// From the entity's origin, before its scale.
    offset: Vec2 = .zero,
    /// A rectangle's or a capsule's turn on the entity.
    rotation: f32 = 0,

    pub const Shape = components.Collider2D.Shape;

    pub const reflect_name = "LightOccluder2D";
    pub const reflect_attributes = .{attr.Placement{ .offset = "offset", .rotation = "rotation" }};
    pub const reflect_fields = .{
        .extents = .{
            attr.Extents{ .when = .{ .field = "shape", .is = &.{"rectangle"} } },
            attr.Capsule{ .radius = "radius", .when = .{ .field = "shape", .is = &.{"capsule"} } },
            attr.Doc{ .text = "Half the size; zero is the sprite's" },
        },
        .radius = .{ attr.Radius{ .when = .{ .field = "shape", .is = &.{"circle"} } }, attr.Doc{ .text = "Zero is half the sprite's width" } },
        .rotation = .{attr.Angle{}},
    };
};

/// The most corners an occluder's outline has.
pub const max_corners = 24;

/// A sprite's size and where its middle is from its entity's origin -
/// `{ width, height, x, y }` - for an occluder with no size of its own;
/// zeros for none.
pub const SpriteBox = [4]f32;

/// The corners round an occluder's shape, in the world, the same way round
/// whatever its scale: into `into`, and the part of it used. Empty for a
/// shape with no size.
pub fn outline(occluder: LightOccluder2D, sprite: SpriteBox, place: Transform2D, into: *[max_corners]Vec2) []Vec2 {
    var offset: Vec2 = occluder.offset;
    const sized = switch (occluder.shape) {
        .rectangle => occluder.extents.x != 0 and occluder.extents.y != 0,
        .circle => occluder.radius != 0,
        .capsule => occluder.radius != 0 and occluder.extents.y != 0,
    };
    if (!sized) offset = offset.add(.init(sprite[2], sprite[3]));
    const half_width = if (occluder.extents.x != 0) occluder.extents.x else sprite[0] / 2;
    const half_height = if (occluder.extents.y != 0) occluder.extents.y else sprite[1] / 2;
    const radius = if (occluder.radius != 0) occluder.radius else sprite[0] / 2;

    // In the entity's own space first, then its transform's.
    var n: usize = 0;
    const turn_c = @cos(occluder.rotation);
    const turn_s = @sin(occluder.rotation);
    const Local = struct {
        fn put(points: *[max_corners]Vec2, count: *usize, x: f32, y: f32, c: f32, s: f32, at: Vec2) void {
            points[count.*] = .init(at.x + x * c - y * s, at.y + x * s + y * c);
            count.* += 1;
        }
    };
    switch (occluder.shape) {
        .rectangle => {
            if (!(@abs(half_width) > 0 and @abs(half_height) > 0)) return into[0..0];
            for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }) |corner| {
                Local.put(into, &n, corner[0] * half_width, corner[1] * half_height, turn_c, turn_s, offset);
            }
        },
        .circle => {
            if (!(@abs(radius) > 0)) return into[0..0];
            const sides = 16;
            for (0..sides) |i| {
                const angle = @as(f32, @floatFromInt(i)) / sides * std.math.tau;
                Local.put(into, &n, @cos(angle) * radius, @sin(angle) * radius, 1, 0, offset);
            }
        },
        .capsule => {
            if (!(@abs(radius) > 0 and @abs(half_height) > 0)) return into[0..0];
            // Two half circles, one round each end's centre.
            const reach = @max(@abs(half_height) - @abs(radius), 0);
            const half = 10;
            for (0..half + 1) |i| {
                const angle = std.math.pi + @as(f32, @floatFromInt(i)) / half * std.math.pi;
                Local.put(into, &n, @cos(angle) * radius, -reach + @sin(angle) * radius, turn_c, turn_s, offset);
            }
            for (0..half + 1) |i| {
                const angle = @as(f32, @floatFromInt(i)) / half * std.math.pi;
                Local.put(into, &n, @cos(angle) * radius, reach + @sin(angle) * radius, turn_c, turn_s, offset);
            }
        },
    }
    for (into[0..n]) |*point| {
        const at = place.apply(point.x, point.y);
        point.* = .init(at.x, at.y);
    }
    return into[0..n];
}

test "an occluder's outline is its box, circle or capsule in the world, or its sprite's size with none" {
    var points: [max_corners]Vec2 = undefined;
    const place: Transform2D = .{ .x = 100, .y = 50, .scale_x = 2, .scale_y = 2 };
    const box = outline(.{ .extents = .init(10, 5) }, @splat(0), place, &points);
    try testing.expectEqual(@as(usize, 4), box.len);
    try testing.expect(box[0].approxEql(.init(80, 40)));
    try testing.expect(box[2].approxEql(.init(120, 60)));

    // None of its own: the sprite's, round the sprite's middle.
    const sprite = outline(.{}, .{ 32, 16, 4, 0 }, .{}, &points);
    try testing.expect(sprite[0].approxEql(.init(-12, -8)));
    try testing.expect(sprite[2].approxEql(.init(20, 8)));

    const circle = outline(.{ .shape = .circle, .radius = 8 }, @splat(0), .{}, &points);
    try testing.expectEqual(@as(usize, 16), circle.len);
    for (circle) |p| try testing.expectApproxEqAbs(@as(f32, 8), p.len(), 0.001);

    const capsule = outline(.{ .shape = .capsule, .radius = 4, .extents = .init(0, 10) }, @splat(0), .{}, &points);
    try testing.expectEqual(@as(usize, 22), capsule.len);
    var lowest: f32 = 0;
    var highest: f32 = 0;
    for (capsule) |p| {
        lowest = @min(lowest, p.y);
        highest = @max(highest, p.y);
    }
    try testing.expectApproxEqAbs(@as(f32, -10), lowest, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), highest, 0.001);

    // No size and no sprite: nothing.
    try testing.expectEqual(@as(usize, 0), outline(.{}, @splat(0), .{}, &points).len);
}
