// SPDX-License-Identifier: BSD-3-Clause

//! A picture laid onto whatever is inside a box: each `Decal` the camera
//! sees some of - the forty-eight nearest it - in one uniform block, and
//! what the surfaces' shader does with them: a pixel of a surface inside a
//! decal's box takes the picture's colour there, as if it were shone onto
//! the surface along the box's own `-z`. A bullet's hole in a wall, a
//! scorch on a floor, a puddle, a painted line.
//!
//! Nothing is added to the mesh it lies on, so it bends over a corner and
//! a step as the surface does, and never flickers against it. Its picture
//! is a tile of the atlas the lights' cookies are in - the renderer's
//! `placePictures` - and one with no picture is a soft round dot.
//!
//! A decal that has a `lifetime` grows older each frame - `age` - fades over
//! its last `fade` seconds, and is despawned when its time is up.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const Decal = @import("render3d_components.zig").Decal;
const View3D = @import("view3d.zig").View3D;
const worlds3d = @import("worlds3d.zig");

/// The most a frame holds.
pub const most = 48;
/// The uniform block's slot, in the surfaces' shader.
pub const slot = 8;
/// Five `vec4`s a decal.
pub const rows = 5;

/// The decals, as the shader's `Decals` block says: each its world to its
/// own space - its box from minus one to one - as three rows, where its
/// picture is in the atlas, and its colour; and how many there are.
pub const Block = extern struct {
    decals: [most * rows][4]f32 = @splat(@splat(0)),
    count: [4]f32 = @splat(0),
};

/// The shader's part: the block, and what lays the decals onto a colour.
/// Reads `COOKIE_ATLAS`, the atlas the pictures are in, `FEEL` of the
/// `Material` block and `toLinear`.
pub const shader_part =
    \\uniform Decals : 8 {
    \\    vec4 DECALS[240];
    \\    vec4 DECAL_COUNT;
    \\}
    \\
    \\// A surface's colour at `p`, facing `n`, under the decals it is inside.
    \\// What is drawn as its colour alone - a sky, a glow - takes none.
    \\vec3 decals(vec3 albedo, vec3 p, vec3 n) {
    \\    vec3 result = albedo;
    \\    if (FEEL.x > 0.5) {
    \\        return result;
    \\    }
    \\    for (int d = 0; d < 48; d = d + 1) {
    \\        if (float(d) < DECAL_COUNT.x) {
    \\            int b = d * 5;
    \\            vec4 r0 = DECALS[b];
    \\            vec4 r1 = DECALS[b + 1];
    \\            vec4 r2 = DECALS[b + 2];
    \\            vec3 q = vec3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
    \\            if (max(abs(q.x), max(abs(q.y), abs(q.z))) < 1.0) {
    \\                vec4 place = DECALS[b + 3];
    \\                vec4 tint = DECALS[b + 4];
    \\                // A surface edge-on to the way it is shone takes none of it,
    \\                // and it thins toward the near and far ends of its box.
    \\                float square = abs(dot(normalize(r2.xyz), normalize(n)));
    \\                float cover = tint.w * smoothstep(0.0, 0.35, square) * (1.0 - smoothstep(0.75, 1.0, abs(q.z)));
    \\                vec3 paint = tint.rgb;
    \\                if (place.z > 0.0) {
    \\                    vec4 texel = sample_level(COOKIE_ATLAS, place.xy + vec2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5) * place.zw, 0.0);
    \\                    paint = toLinear(texel.rgb) * tint.rgb;
    \\                    cover = cover * texel.a;
    \\                } else {
    \\                    cover = cover * (1.0 - smoothstep(0.45, 1.0, length(q.xy)));
    \\                }
    \\                result = mix(result, paint, clamp(cover, 0.0, 1.0));
    \\            }
    \\        }
    \\    }
    \\    return result;
    \\}
    \\
;

/// A decal the frame keeps: its rows but for its picture's place, which the
/// renderer writes once the picture has a tile.
pub const Kept = struct {
    rows: [rows][4]f32,
    /// Its picture, and the tile of the atlas it is in. None is a round
    /// dot - or, for one that `pictured`, a picture no tile was left for.
    picture: rhi.Texture = .none,
    tile: u32 = 0,
    pictured: bool = false,
    /// Where that tile is in the atlas, as the shader reads it: the
    /// renderer's to say, which knows which way up its device keeps it.
    place: [4]f32 = @splat(0),
    distance: f32,

    fn nearer(_: void, a: Kept, b: Kept) bool {
        return a.distance < b.distance;
    }
};

/// What `view` sees through `frustum` into `kept`, cleared first: the
/// visible decals in `world` - the world a `World3D` makes, or the main one
/// for none - nearest the camera first, at most `most`.
pub fn gather(app: *App, kept: *std.ArrayList(Kept), view: View3D, frustum: math.Frustum, worlds: worlds3d.Filter) !void {
    kept.clearRetainingCapacity();
    var it = try ecs.Query(.{ Transform3D, Decal }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform3D), chunk.slice(Decal), chunk.entities) |local, decal, entity| {
            const shown = decal.color.a * fading(decal);
            if (!(shown > 0)) continue;
            if (!worlds.admits(app, entity)) continue;
            if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
            const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, app.time.alpha()) orelse continue;
            const half = decal.size.scale(0.5);
            if (!(half.x > 0 and half.y > 0 and half.z > 0)) continue;
            const model = placed.matrix().mul(.fromScale(half));
            const bounds = (math.Aabb{ .min = .splat(-1), .max = .splat(1) }).transformed(model);
            if (frustum.testAabb(bounds) == .outside) continue;
            var held = rowsOf(decal, model) orelse continue;
            held[4][3] = shown;
            const picture: rhi.Texture = if (app.assets.get(decal.texture)) |image| image.gpu else .none;
            try kept.append(app.gpa, .{ .rows = held, .picture = picture, .pictured = !picture.isNone(), .distance = bounds.center().sub(view.position).len() });
        }
    }
    std.mem.sort(Kept, kept.items, {}, Kept.nearer);
    if (kept.items.len > most) kept.shrinkRetainingCapacity(most);
}

/// The block for what `gather` kept, each picture at its `place`; a decal
/// whose picture found no tile is left out.
pub fn blockOf(kept: []const Kept) Block {
    var block: Block = .{};
    var count: usize = 0;
    for (kept) |decal| {
        var held = decal.rows;
        if (decal.pictured and decal.picture.isNone()) continue;
        if (decal.pictured) held[3] = decal.place;
        @memcpy(block.decals[count * rows ..][0..rows], &held);
        count += 1;
    }
    block.count = .{ @floatFromInt(count), 0, 0, 0 };
    return block;
}

/// One decal's rows of the block: its world to its own space, made from
/// `model`, its box's, no place for a picture, and its colour; null where
/// `model` cannot be undone.
pub fn rowsOf(decal: Decal, model: math.Mat4) ?[rows][4]f32 {
    const inverse = model.inverse() orelse return null;
    return .{
        inverse.row(0).array(),
        inverse.row(1).array(),
        inverse.row(2).array(),
        @splat(0),
        .{ toLinear(decal.color.r), toLinear(decal.color.g), toLinear(decal.color.b), decal.color.a },
    };
}

/// How much of a decal is left, from one to nought: one until its last
/// `fade` seconds, and one always for a decal that lasts.
pub fn fading(decal: Decal) f32 {
    if (!(decal.lifetime > 0)) return 1;
    const left = decal.lifetime - decal.age;
    if (left <= 0) return 0;
    if (!(decal.fade > 0)) return 1;
    return @min(left / decal.fade, 1);
}

/// Every decal with a `lifetime` is `delta` seconds older, and those whose
/// time is up are despawned, with what hangs from them.
pub fn age(app: *App, delta: f32) !void {
    var over: std.ArrayList(ecs.Entity) = .empty;
    defer over.deinit(app.gpa);
    var it = try ecs.Query(.{Decal}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Decal), chunk.entities) |*decal, entity| {
            if (!(decal.lifetime > 0)) continue;
            decal.age += delta;
            if (decal.age >= decal.lifetime) try over.append(app.gpa, entity);
        }
    }
    for (over.items) |entity| try app.despawnTree(entity);
}

fn toLinear(v: f32) f32 {
    const x = @max(v, 0);
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

test "a decal's rows take the world into its box, from minus one to one" {
    var placed: Transform3D = .at(10, 0, 0);
    placed.scale = .init(2, 1, 1);
    const decal: Decal = .{ .size = .init(0.5, 0.25, 1), .color = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 } };
    const model = placed.matrix().mul(.fromScale(decal.size.scale(0.5)));
    const held = rowsOf(decal, model).?;
    const corner: math.Vec3 = .init(10.5, 0.125, 0.5);
    for (held[0..3]) |row| {
        try testing.expectApproxEqAbs(@as(f32, 1), row[0] * corner.x + row[1] * corner.y + row[2] * corner.z + row[3], 1e-5);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.5), held[4][3], 1e-6);
}

test "a decal fades over the last of its time, and one that lasts never does" {
    try testing.expectEqual(@as(f32, 1), fading(.{}));
    try testing.expectEqual(@as(f32, 1), fading(.{ .lifetime = 4, .fade = 1, .age = 2.5 }));
    try testing.expectApproxEqAbs(@as(f32, 0.5), fading(.{ .lifetime = 4, .fade = 1, .age = 3.5 }), 1e-6);
    try testing.expectEqual(@as(f32, 0), fading(.{ .lifetime = 4, .fade = 1, .age = 4 }));
    try testing.expectEqual(@as(f32, 1), fading(.{ .lifetime = 4, .fade = 0, .age = 3.9 }));
}

test "a decal's picture is at its place in the block, and one with no tile is left out" {
    const kept = [_]Kept{
        .{ .rows = @splat(@splat(0)), .picture = .{ .index = 7, .generation = 1 }, .pictured = true, .place = .{ 0.5, 0.25, 0.25, 0.25 }, .distance = 1 },
        .{ .rows = @splat(@splat(0)), .distance = 2 },
        // More pictures than tiles: left out.
        .{ .rows = @splat(@splat(0)), .pictured = true, .distance = 3 },
    };
    const block = blockOf(&kept);
    try testing.expectEqual(@as(f32, 2), block.count[0]);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25, 0.25, 0.25 }, &block.decals[3]);
    // No picture, no place: the shader draws its dot.
    try testing.expectEqual(@as(f32, 0), block.decals[rows + 3][2]);
}
