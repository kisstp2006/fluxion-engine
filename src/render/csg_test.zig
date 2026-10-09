// SPDX-License-Identifier: BSD-3-Clause

//! Solids in the scene, through a whole app, headless: a wall with a door
//! cut from it drawn as one mesh, collided with through the door's hole,
//! made again only when a shape changes, and the faces drawn with whose
//! material they came from.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const mesh = @import("mesh.zig");
const csg_shapes = @import("csg_shapes.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Transform3D = components.Transform3D;
const MeshInstance3D = components.MeshInstance3D;
const Camera3D = components.Camera3D;
const Collider3D = components.Collider3D;
const CSGShape3D = components.CSGShape3D;

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io });
}

/// How much a closed mesh holds.
fn volumeOf(made: *const mesh.Mesh) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i + 2 < made.indices.len) : (i += 3) {
        const a = Vec3.fromArray(made.vertices[made.indices[i]].position);
        const b = Vec3.fromArray(made.vertices[made.indices[i + 1]].position);
        const c = Vec3.fromArray(made.vertices[made.indices[i + 2]].position);
        sum += a.dot(b.cross(c));
    }
    return sum / 6;
}

/// A wall six metres wide, three high and a third thick, standing on the
/// floor, and a door a metre wide and two high cut from it.
fn wallWithDoor(app: *App) !struct { wall: Entity, door: Entity } {
    const wall = try app.world.spawnWith(.{
        Transform3D.at(0, 1.5, 0),
        MeshInstance3D{},
        CSGShape3D{ .size = .init(6, 3, 0.3) },
        Collider3D{ .shape = .mesh },
    });
    const door = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), CSGShape3D{ .operation = .subtract, .size = .init(1, 2, 1) } });
    try app.setParent(door, wall, false);
    return .{ .wall = wall, .door = door };
}

test "a wall with a door cut from it is one mesh, drawn by the wall, and the door draws nothing" {
    const app = try headless();
    defer app.destroy();
    const built = try wallWithDoor(app);
    const instance = app.world.get(built.wall, MeshInstance3D).?.*;
    const kept = (try app.meshDrawnBy(built.wall, instance)).?;
    // What is left: the wall, but the door's two by one by a third.
    try testing.expectApproxEqAbs(@as(f32, 6 * 3 * 0.3 - 1 * 2 * 0.3), volumeOf(&kept.mesh), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -3), kept.mesh.bounds.min.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.5), kept.mesh.bounds.max.y, 1e-4);
    // Lightmap UVs, and tangents for a normal map.
    try testing.expect(kept.mesh.uv2_texels > 0);
    try testing.expect(!std.meta.eql(kept.mesh.vertices[0].tangent, mesh.no_tangent) or kept.mesh.vertices[0].normal[0] != 0);
    // The door is part of the wall's mesh, and none of its own.
    try testing.expect(try app.meshDrawnBy(built.door, .{}) == null);
    try testing.expect(csg_shapes.isTop(&app.world, built.wall));
    try testing.expect(!csg_shapes.isTop(&app.world, built.door));
    try testing.expect(csg_shapes.topOf(&app.world, built.door).eql(built.wall));

    // Seen by a camera: one mesh drawn.
    var eye: Transform3D = .at(0, 1.5, 8);
    eye.lookAt(.init(0, 1.5, 0), .unit_y);
    _ = try app.world.spawnWith(.{ eye, Camera3D{} });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
}

test "a shape's mesh is made again when a shape under it moves or changes, and kept while none does" {
    const app = try headless();
    defer app.destroy();
    const built = try wallWithDoor(app);
    const instance = app.world.get(built.wall, MeshInstance3D).?.*;
    const first = (try app.meshDrawnBy(built.wall, instance)).?;
    const stamp = first.stamp;
    try testing.expectEqual(@as(u64, 1), app.csg.made);
    _ = try app.meshDrawnBy(built.wall, instance);
    try testing.expectEqual(@as(u64, 1), app.csg.made);

    // Moved: made again, with a stamp of its own.
    app.world.get(built.door, Transform3D).?.position.x = 1.5;
    const moved = (try app.meshDrawnBy(built.wall, instance)).?;
    try testing.expectEqual(@as(u64, 2), app.csg.made);
    try testing.expect(moved.stamp != stamp);
    try testing.expectApproxEqAbs(@as(f32, 6 * 3 * 0.3 - 1 * 2 * 0.3), volumeOf(&moved.mesh), 1e-3);

    // Made wider: a bigger hole.
    app.world.get(built.door, CSGShape3D).?.size.x = 2;
    try testing.expectApproxEqAbs(@as(f32, 6 * 3 * 0.3 - 2 * 2 * 0.3), volumeOf(&(try app.meshDrawnBy(built.wall, instance)).?.mesh), 1e-3);

    // Hidden: left out, and the wall whole again.
    try app.world.add(built.door, Appearance{ .visible = false });
    try testing.expectApproxEqAbs(@as(f32, 6 * 3 * 0.3), volumeOf(&(try app.meshDrawnBy(built.wall, instance)).?.mesh), 1e-3);
    try testing.expectEqual(@as(u64, 4), app.csg.made);

    // Gone with its entity.
    try app.despawnTree(built.wall);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.csg.of_top.count());
}

test "a mesh collider beside the wall is the wall's mesh: a ray through the doorway passes, one at the wall stops" {
    const app = try headless();
    defer app.destroy();
    const built = try wallWithDoor(app);
    _ = try app.step();
    try testing.expect(app.castRay3D(.init(0, 1, -3), .init(0, 1, 3), 0xFFFF_FFFF, false) == null);
    const hit = app.castRay3D(.init(2, 1, -3), .init(2, 1, 3), 0xFFFF_FFFF, false).?;
    try testing.expect(hit.collider.eql(built.wall));
    try testing.expectApproxEqAbs(@as(f32, -0.15), hit.point.z, 1e-3);

    // The door moved aside: the collider is made again from the new mesh.
    app.world.get(built.door, Transform3D).?.position.x = 2;
    _ = try app.step();
    try testing.expect(app.castRay3D(.init(0, 1, -3), .init(0, 1, 3), 0xFFFF_FFFF, false) != null);
    try testing.expect(app.castRay3D(.init(2, 1, -3), .init(2, 1, 3), 0xFFFF_FFFF, false) == null);
}

test "a character walks through the doorway cut from a wall, and one beside it is stopped by the wall" {
    const app = try headless();
    defer app.destroy();
    const dt = 1.0 / 60.0;
    app.time.source = .{ .fixed = dt };
    // The ground, and the wall standing on it.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(10, 0.5, 10)) });
    _ = try wallWithDoor(app);
    const through = try app.world.spawnWith(.{ Transform3D.at(0, 0.9, 3), components.CharacterBody3D{}, Collider3D.capsule(0.3, 1.8) });
    const beside = try app.world.spawnWith(.{ Transform3D.at(2, 0.9, 3), components.CharacterBody3D{}, Collider3D.capsule(0.3, 1.8) });
    for (0..180) |_| {
        for ([_]Entity{ through, beside }) |walker| {
            const body = app.world.get(walker, components.CharacterBody3D).?;
            body.velocity = .init(0, body.velocity.y - 9.8 * dt, -2);
            _ = try app.moveAndSlide(walker);
        }
        _ = try app.step();
    }
    // Out the other side; against the wall's face at z = 0.15.
    try testing.expect(app.world.get(through, Transform3D).?.position.z < -2);
    try testing.expectApproxEqAbs(@as(f32, 0.45), app.world.get(beside, Transform3D).?.position.z, 0.05);
    try testing.expect(app.world.get(beside, components.CharacterBody3D).?.on_wall);
}

test "each face is drawn with the material of the shape it came from, and a shape with none has its parent's" {
    const app = try headless();
    defer app.destroy();
    const plaster = try app.addMaterial("plaster", .{});
    const wood = try app.addMaterial("wood", .{});
    const built = try wallWithDoor(app);
    app.world.get(built.wall, CSGShape3D).?.material = plaster;
    // A frame round the doorway, joined: no material, so the wall's.
    const frame = try app.world.spawnWith(.{ Transform3D.at(-0.6, -0.5, 0), CSGShape3D{ .size = .init(0.2, 2, 0.4) } });
    try app.setParent(frame, built.wall, false);
    const instance = app.world.get(built.wall, MeshInstance3D).?.*;
    var kept = (try app.meshDrawnBy(built.wall, instance)).?;
    try testing.expectEqual(@as(usize, 1), kept.mesh.surfaces.len);
    try testing.expect(kept.mesh.surfaces[0].material.eql(plaster));

    // The door cut with wood: the doorway's sides are wood.
    app.world.get(built.door, CSGShape3D).?.material = wood;
    kept = (try app.meshDrawnBy(built.wall, instance)).?;
    try testing.expectEqual(@as(usize, 2), kept.mesh.surfaces.len);
    try testing.expect(kept.mesh.surfaces[0].material.eql(plaster));
    try testing.expect(kept.mesh.surfaces[1].material.eql(wood));
    // A metre of wood's picture is a metre of the face's: the doorway's
    // side, two metres high, runs over two of `v`.
    const doorway = kept.mesh.surfaces[1];
    var lowest: f32 = std.math.inf(f32);
    var highest: f32 = -std.math.inf(f32);
    for (kept.mesh.indices[doorway.first_index..][0..doorway.index_count]) |index| {
        const v = kept.mesh.vertices[index];
        if (@abs(v.normal[0]) < 0.9) continue;
        lowest = @min(lowest, v.uv[1]);
        highest = @max(highest, v.uv[1]);
    }
    try testing.expectApproxEqAbs(@as(f32, 2), highest - lowest, 1e-3);
}

test "a group joins what is under it; a cylinder met with a box keeps only where both are" {
    const app = try headless();
    defer app.destroy();
    const group = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, CSGShape3D{ .shape = .group } });
    const a = try app.world.spawnWith(.{ Transform3D.at(-1, 0, 0), CSGShape3D{ .size = .init(2, 2, 2) } });
    const b = try app.world.spawnWith(.{ Transform3D.at(1, 0, 0), CSGShape3D{ .size = .init(2, 2, 2) } });
    try app.setParent(a, group, false);
    try app.setParent(b, group, false);
    const instance = app.world.get(group, MeshInstance3D).?.*;
    try testing.expectApproxEqAbs(@as(f32, 16), volumeOf(&(try app.meshDrawnBy(group, instance)).?.mesh), 1e-3);

    // A cylinder of radius one standing in a box of half its height: what
    // both hold is a disc half a metre thick.
    const pillar = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, CSGShape3D{ .shape = .cylinder, .radius = 1, .height = 2, .sides = 64 } });
    const slab = try app.world.spawnWith(.{ Transform3D{}, CSGShape3D{ .operation = .intersect, .size = .init(4, 0.5, 4) } });
    try app.setParent(slab, pillar, false);
    const held = (try app.meshDrawnBy(pillar, app.world.get(pillar, MeshInstance3D).?.*)).?;
    try testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.5), volumeOf(&held.mesh), 0.01);
}

test "a polygon is its outline drawn out, and a scene keeps only the corners it has" {
    const app = try headless();
    defer app.destroy();
    // An L seen from above, half a metre tall: three squares of one.
    var shape: CSGShape3D = .{ .shape = .polygon, .height = 0.5, .point_count = 6 };
    const l = [_]math.Vec2{ .init(0, 0), .init(2, 0), .init(2, 1), .init(1, 1), .init(1, 2), .init(0, 2) };
    @memcpy(shape.points[0..l.len], &l);
    const ell = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, shape });
    const held = (try app.meshDrawnBy(ell, app.world.get(ell, MeshInstance3D).?.*)).?;
    try testing.expectApproxEqAbs(@as(f32, 1.5), volumeOf(&held.mesh), 1e-4);
    try testing.expect(held.mesh.bounds.max.approxEql(.init(2, 0.25, 2)));

    // Written down: its six corners, not all it could have; read back, the
    // same.
    const written = try @import("../scene/scene.zig").write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    const points = std.mem.indexOf(u8, written, "\"points\"").?;
    const count = std.mem.indexOf(u8, written[points..], "\"point_count\"").?;
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, written[points..][0..count], "\"x\""));
    app.clearWorld();
    _ = try @import("../scene/scene.zig").read(app, written, .{});
    var it = try ecs.Query(.{CSGShape3D}).over(&app.world);
    const back = (it.next() orelse return error.TestUnexpectedResult).slice(CSGShape3D)[0];
    try testing.expectEqual(@as(u32, 6), back.point_count);
    try testing.expectEqualSlices(math.Vec2, &l, back.outline());
    // Past them, what a polygon starts with.
    try testing.expectEqual(@as(f32, 0), back.points[6].x);

    // A box's corners are not written at all.
    app.clearWorld();
    _ = try app.world.spawnWith(.{ Transform3D{}, CSGShape3D{} });
    const plain = try @import("../scene/scene.zig").write(app, testing.allocator, .{});
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "\"points\"") == null);
}
