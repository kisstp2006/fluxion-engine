// SPDX-License-Identifier: BSD-3-Clause

//! The 3D physics through a whole app, headless: bodies falling and resting,
//! compounds, colliders made from meshes, characters walking, areas, rays,
//! and what a script asks of it.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const script = @import("../script/script.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Transform3D = components.Transform3D;
const RigidBody3D = components.RigidBody3D;
const Collider3D = components.Collider3D;
const CharacterBody3D = components.CharacterBody3D;
const Area3D = components.Area3D;
const RayCast3D = components.RayCast3D;
const Parent = components.Parent;
const MeshInstance3D = components.MeshInstance3D;
const PrimitiveMesh3D = components.PrimitiveMesh3D;

const dt = 1.0 / 60.0;

/// Earth's pull, and nothing slowing a body down: what these tests' numbers
/// were worked out for.
fn headless() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .frame_time = dt, .physics_3d = .{ .default_linear_damp = 0, .default_angular_damp = 0 } });
    errdefer app.destroy();
    try app.addMethod("_body_in", Seen.bodyIn);
    try app.addMethod("_body_out", Seen.bodyOut);
    Seen.reset();
    return app;
}

fn frames(app: *App, count: usize) !void {
    for (0..count) |_| _ = try app.step();
}

/// A floor whose top is at nought: a collider of its own, so a static body.
fn floorOf(app: *App) !Entity {
    return app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(20, 0.5, 20)) });
}

const Seen = struct {
    var entered: usize = 0;
    var exited: usize = 0;
    var last: Entity = .none;

    fn reset() void {
        entered = 0;
        exited = 0;
        last = .none;
    }

    fn bodyIn(_: *App, _: Entity, body: Entity) !void {
        entered += 1;
        last = body;
    }

    fn bodyOut(_: *App, _: Entity, _: Entity) !void {
        exited += 1;
    }
};

test "a crate falls onto a floor and rests on it, its place and speed written back" {
    const app = try headless();
    defer app.destroy();
    const floor = try floorOf(app);
    const crate = try app.world.spawnWith(.{ Transform3D.at(0, 3, 0), RigidBody3D{}, Collider3D{} });
    try frames(app, 30);
    // Half a second of Earth's pull, nothing in the way yet.
    try testing.expectApproxEqAbs(@as(f32, -4.9), app.world.get(crate, RigidBody3D).?.linear_velocity.y, 0.3);
    try frames(app, 150);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(crate, Transform3D).?.position.y, 0.02);
    try testing.expect(app.world.get(crate, RigidBody3D).?.linear_velocity.len() < 0.05);
    try testing.expectEqual(RigidBody3D.Type.static, app.bodyOf3D(floor).?.type);
    try testing.expectEqual(@as(usize, 2), app.physics3d.bodyCount());
}

test "colliders hanging from a body are one body, and a body hung from a moving parent still falls in the world" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    // A lamp: a broad foot and a post on it, one body.
    const table = try app.world.spawnWith(.{ Transform3D.at(0, 2, 0), RigidBody3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.4, 0), Collider3D.box(.init(1, 0.1, 1)), Parent.of(table) });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0.1, 0), Collider3D.box(.init(0.1, 0.4, 0.1)), Parent.of(table) });
    try frames(app, 180);
    try testing.expectEqual(@as(usize, 2), app.physics3d.bodyCount());
    // Standing on its foot: the foot's underside at the floor.
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(table, Transform3D).?.position.y, 0.03);
    try testing.expect(@abs(app.world.get(table, Transform3D).?.rotation.w) > 0.99);
}

test "a convex collider is the hull of its mesh, and a mesh collider its very triangles" {
    const app = try headless();
    defer app.destroy();
    // The floor: a plane of triangles, ten metres a side.
    _ = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, PrimitiveMesh3D{ .shape = .plane, .size = .init(10, 1, 10) }, Collider3D{ .shape = .mesh } });
    // A box made from the box mesh drawn, scaled up to a metre and a half.
    var scaled: Transform3D = .at(0, 3, 0);
    scaled.scale = .init(1.5, 1.5, 1.5);
    const rock = try app.world.spawnWith(.{ scaled, MeshInstance3D{}, PrimitiveMesh3D{ .shape = .box }, RigidBody3D{}, Collider3D{ .shape = .convex } });
    try frames(app, 180);
    try testing.expectApproxEqAbs(@as(f32, 0.75), app.world.get(rock, Transform3D).?.position.y, 0.03);
    try testing.expectEqual(@as(usize, 1), app.bodies3d.hulls.count());
    try testing.expectEqual(@as(usize, 1), app.bodies3d.meshes.count());
    // Gone with its entity, and its hull with it.
    try app.despawnTree(rock);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 0), app.bodies3d.hulls.count());
}

test "a character walks, falls onto the floor, stands on it and stops at a wall" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    _ = try app.world.spawnWith(.{ Transform3D.at(3, 1, 0), Collider3D.box(.init(0.5, 1, 5)) });
    const player = try app.world.spawnWith(.{ Transform3D.at(0, 2, 0), CharacterBody3D{}, Collider3D.capsule(0.3, 1.8) });
    app.time.source = .{ .fixed = dt };
    for (0..120) |_| {
        const body = app.world.get(player, CharacterBody3D).?;
        body.velocity = .init(2, body.velocity.y - 9.8 * dt, 0);
        _ = try app.moveAndSlide(player);
        _ = try app.step();
    }
    const body = app.world.get(player, CharacterBody3D).?;
    try testing.expect(body.on_floor);
    try testing.expect(body.on_wall);
    try testing.expect(body.wall_normal.approxEql(.init(-1, 0, 0)));
    const at = app.world.get(player, Transform3D).?.position;
    // Feet on the floor; against the wall's face at x = 2.5.
    try testing.expectApproxEqAbs(@as(f32, 0.9), at.y, 0.03);
    try testing.expectApproxEqAbs(@as(f32, 2.2), at.x, 0.03);
}

test "a character walks up a ramp of triangles onto the ledge at its top, and stops at the wall" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    // A slab tilted 18 degrees, sunk so its foot meets the floor, its own
    // triangles the collider; the ledge level with its top, and a wall
    // behind it.
    var slab: PrimitiveMesh3D = .of(.box);
    slab.size = .init(6, 0.3, 3);
    var ramp: Transform3D = .at(-6, 0.784, 0);
    ramp.rotation = .of(.fromAxisAngle(.init(0, 0, 1), std.math.degreesToRadians(-18.0)));
    _ = try app.world.spawnWith(.{ ramp, MeshInstance3D{}, slab, Collider3D{ .shape = .mesh } });
    _ = try app.world.spawnWith(.{ Transform3D.at(-9.35, 0.925, 0), Collider3D.box(.init(0.65, 0.925, 1.5)) });
    _ = try app.world.spawnWith(.{ Transform3D.at(-10.25, 1.25, 0), Collider3D.box(.init(0.25, 1.25, 1.5)) });
    const player = try app.world.spawnWith(.{ Transform3D.at(0, 0.9, 0), CharacterBody3D{}, Collider3D.capsule(0.4, 1.8) });
    app.time.source = .{ .fixed = dt };
    for (0..180) |_| {
        const body = app.world.get(player, CharacterBody3D).?;
        body.velocity = .init(-5, body.velocity.y - 18 * dt, 0);
        _ = try app.moveAndSlide(player);
        _ = try app.step();
    }
    const at = app.world.get(player, Transform3D).?.position;
    // On the ledge, feet at 1.85, against the wall's face at x = -10.
    try testing.expectApproxEqAbs(@as(f32, -9.6), at.x, 0.03);
    try testing.expectApproxEqAbs(@as(f32, 1.85 + 0.9), at.y, 0.03);
    const body = app.world.get(player, CharacterBody3D).?;
    try testing.expect(body.on_floor and body.on_wall);
}

test "a character gets up a flight of stairs from a standstill at its foot" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    // Five stairs, each 0.2 up and 0.3 on, the first one's face at x = 1.
    for (0..5) |n| {
        const i: f32 = @floatFromInt(n);
        const top = 0.2 * (i + 1);
        _ = try app.world.spawnWith(.{ Transform3D.at(3 + 0.3 * i, top / 2, 0), Collider3D.box(.init(2, top / 2, 2)) });
    }
    var walker: CharacterBody3D = .{};
    walker.max_step_height = 0.45;
    const player = try app.world.spawnWith(.{ Transform3D.at(0.5, 0.9, 0), walker, Collider3D.capsule(0.35, 1.8) });
    app.time.source = .{ .fixed = dt };
    for (0..80) |_| {
        // Gathering speed a little a step, as a game's own movement does:
        // whatever a stair's face took off it has to be made up again.
        const body = app.world.get(player, CharacterBody3D).?;
        body.velocity.x = @min(body.velocity.x + 20 * dt, 4);
        body.velocity.y -= 9.8 * dt;
        _ = try app.moveAndSlide(player);
        _ = try app.step();
    }
    const at = app.world.get(player, Transform3D).?.position;
    // On the top one, a metre up, and on along it.
    try testing.expect(at.x > 3);
    try testing.expectApproxEqAbs(@as(f32, 0.9 + 1.0), at.y, 0.03);
    try testing.expect(app.world.get(player, CharacterBody3D).?.on_floor);
}

test "a character walks up onto a kerb no higher than its step, and stops at one higher" {
    for ([_]f32{ 0.2, 0.5 }) |kerb| {
        const app = try headless();
        defer app.destroy();
        _ = try floorOf(app);
        _ = try app.world.spawnWith(.{ Transform3D.at(6, kerb / 2, 0), Collider3D.box(.init(4, kerb / 2, 4)) });
        const player = try app.world.spawnWith(.{ Transform3D.at(0, 0.9, 0), CharacterBody3D{}, Collider3D.capsule(0.3, 1.8) });
        app.time.source = .{ .fixed = dt };
        for (0..120) |_| {
            const body = app.world.get(player, CharacterBody3D).?;
            body.velocity = .init(3, body.velocity.y - 9.8 * dt, 0);
            _ = try app.moveAndSlide(player);
            _ = try app.step();
        }
        const at = app.world.get(player, Transform3D).?.position;
        if (kerb < 0.3) {
            // Up on it and on along it.
            try testing.expect(at.x > 4);
            try testing.expectApproxEqAbs(@as(f32, 0.9 + kerb), at.y, 0.03);
            try testing.expect(app.world.get(player, CharacterBody3D).?.on_floor);
        } else {
            // Against its edge at x = 2.
            try testing.expectApproxEqAbs(@as(f32, 1.7), at.x, 0.03);
            try testing.expectApproxEqAbs(@as(f32, 0.9), at.y, 0.03);
        }
    }
}

test "an area says a body came in and went out, and a ray says what is below it" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    const gate = try app.world.spawnWith(.{ Transform3D.at(0, 4, 0), Area3D{}, Collider3D.box(.init(1, 0.5, 1)) });
    try app.signal(gate, Area3D, .body_entered).connect(.method(gate, "_body_in"), .{});
    try app.signal(gate, Area3D, .body_exited).connect(.method(gate, "_body_out"), .{});
    const ball = try app.world.spawnWith(.{ Transform3D.at(0, 7, 0), RigidBody3D{}, Collider3D.sphere(0.25) });
    const eye = try app.world.spawnWith(.{ Transform3D.at(5, 2, 0), RayCast3D{ .target = .init(0, -5, 0) } });
    try frames(app, 120);
    try testing.expectEqual(@as(usize, 1), Seen.entered);
    try testing.expectEqual(@as(usize, 1), Seen.exited);
    try testing.expect(Seen.last.eql(ball));
    try testing.expect(!app.hasOverlappingBodies(gate));
    const ray = app.world.get(eye, RayCast3D).?;
    try testing.expect(ray.colliding);
    try testing.expect(ray.point.approxEql(.init(5, 0, 0)));
    try testing.expect(ray.normal.approxEql(.init(0, 1, 0)));
    // Asked straight: down onto the ball where it rests.
    const hit = app.castRay3D(.init(0, 5, 0), .init(0, -5, 0), 0xFFFF_FFFF, false).?;
    try testing.expect(hit.collider.eql(ball));
    try testing.expectApproxEqAbs(@as(f32, 0.5), hit.point.y, 0.02);
}

test "a script kicks a body and asks a ray" {
    const app = try headless();
    defer app.destroy();
    try app.useScripts(.{});
    _ = try floorOf(app);
    const handle = try app.addScript("kicker.flux",
        \\var below = false;
        \\struct Kicker {
        \\    fn ready(self) {
        \\        app.applyImpulse3D(self.entity, vec3(5.0, 0.0, 0.0));
        \\    }
        \\    fn fixed(self, dt: float) {
        \\        const at = self.entity.get(Transform3D).position;
        \\        const hit = app.castRay3D(at, at - vec3(0.0, 3.0, 0.0), 0xFFFFFFFF, false);
        \\        if (hit != null) below = true;
        \\    }
        \\}
    );
    const ball = try app.world.spawnWith(.{ Transform3D.at(0, 0.5, 0), RigidBody3D{}, Collider3D.sphere(0.5), script.Script.of(handle) });
    try frames(app, 30);
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    const scripts = app.scripts.?;
    try testing.expect(scripts.vm.get(scripts.moduleOf(handle).?, "below").?.asBool());
    try testing.expect(app.world.get(ball, Transform3D).?.position.x > 1);
}

test "a script goes through the 3D contacts that began and ended, and asks each for the other one" {
    const app = try headless();
    defer app.destroy();
    try app.useScripts(.{});
    const handle = try app.addScript("listener3d.flux",
        \\var begun = 0;
        \\var ended = 0;
        \\var crate_met = false;
        \\struct Listener3d {
        \\    fn update(self, dt: float) {
        \\        const floor = app.find("Floor") orelse return;
        \\        for (app.contactsBegun3D()) |contact| {
        \\            begun += 1;
        \\            if (contact.other(floor)) |other| {
        \\                if (other.name() == "Crate" and !contact.sensor) crate_met = true;
        \\            }
        \\        }
        \\        ended += app.contactsEnded3D().len;
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{script.Script.of(handle)});
    try app.setName(try floorOf(app), "Floor");
    const crate = try app.world.spawnWith(.{ Transform3D.at(0, 2, 0), RigidBody3D{}, Collider3D.box(.init(0.5, 0.5, 0.5)) });
    try app.setName(crate, "Crate");
    try frames(app, 90);
    // Gone, its contact ends.
    app.world.despawn(crate);
    try frames(app, 2);
    const scripts = app.scripts.?;
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    const module = scripts.moduleOf(handle).?;
    // It may bounce before it rests; whatever began has ended once it is gone.
    const begun = scripts.vm.get(module, "begun").?.asInt();
    try testing.expect(begun >= 1);
    try testing.expectEqual(begun, scripts.vm.get(module, "ended").?.asInt());
    try testing.expect(scripts.vm.get(module, "crate_met").?.asBool());
}

const Clicks = struct {
    var entered: usize = 0;
    var pressed: usize = 0;
    var clicked: usize = 0;
    var last: Entity = .none;

    fn reset() void {
        entered = 0;
        pressed = 0;
        clicked = 0;
        last = .none;
    }

    fn in(_: *App, self: Entity) !void {
        entered += 1;
        last = self;
    }

    fn down(_: *App, self: Entity, _: @import("fluxion_platform").MouseButton) !void {
        pressed += 1;
        last = self;
    }

    fn click(_: *App, self: Entity, _: @import("fluxion_platform").MouseButton) !void {
        clicked += 1;
        last = self;
    }
};

fn button(app: *App, down: bool) void {
    app.input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = if (down) .press else .release, .mods = .{}, .x = 100, .y = 50 } });
}

test "a click through the camera picks the area it is over, and a wall in front hides it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100, .frame_time = dt });
    defer app.destroy();
    try app.addMethod("_in", Clicks.in);
    try app.addMethod("_down", Clicks.down);
    try app.addMethod("_click", Clicks.click);
    Clicks.reset();
    // Looking down -z from five metres back at a lever.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 5), components.Camera3D{ .current = true } });
    const lever = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), Area3D{}, Collider3D.box(.init(0.5, 0.5, 0.5)) });
    try app.signal(lever, Area3D, .mouse_entered).connect(.method(lever, "_in"), .{});
    try app.signal(lever, Area3D, .pressed).connect(.method(lever, "_down"), .{});
    try app.signal(lever, Area3D, .clicked).connect(.method(lever, "_click"), .{});
    button(app, true);
    _ = try app.step();
    button(app, false);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Clicks.entered);
    try testing.expectEqual(@as(usize, 1), Clicks.pressed);
    try testing.expectEqual(@as(usize, 1), Clicks.clicked);
    try testing.expect(app.world.get(lever, Area3D).?.hovered);

    // A wall between: the lever is left and hears no more.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 2), Collider3D.box(.init(2, 2, 0.1)) });
    button(app, true);
    _ = try app.step();
    button(app, false);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Clicks.pressed);
    try testing.expect(!app.world.get(lever, Area3D).?.hovered);
}

test "a mesh collider is not made again when its mesh only moves in memory, as the mesh table grows" {
    const app = try headless();
    defer app.destroy();
    const floor = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, PrimitiveMesh3D{ .shape = .plane, .size = .init(10, 1, 10) }, Collider3D{ .shape = .mesh } });
    try frames(app, 2);
    const shape = app.bodies3d.shapes.items[floor.index].shape;
    const stamp = app.bodies3d.shapes.items[floor.index].made_from.stamp;
    try testing.expect(!std.meta.eql(shape, @TypeOf(shape).none));
    // Meshes enough of their own that the table holding the floor's grows,
    // and moves it.
    for (0..300) |i| {
        var made: PrimitiveMesh3D = .of(.box);
        made.size = .init(1 + @as(f32, @floatFromInt(i)) * 0.01, 1, 1);
        _ = try app.world.spawnWith(.{ Transform3D.at(0, 50, 0), MeshInstance3D{}, made, Collider3D{ .shape = .convex } });
    }
    try frames(app, 2);
    try testing.expectEqual(stamp, app.bodies3d.shapes.items[floor.index].made_from.stamp);
    try testing.expect(std.meta.eql(shape, app.bodies3d.shapes.items[floor.index].shape));
    try testing.expectEqual(@as(usize, 1), app.bodies3d.meshes.count());
}

test "a joint holds a body to another, and to the world with none named; taken away, it lets go" {
    const app = try headless();
    defer app.destroy();
    // A lamp on a chain: a link held to the ceiling, the lamp held to the link.
    const link = try app.world.spawnWith(.{ Transform3D.at(0, 4, 0), RigidBody3D{}, Collider3D.box(.init(0.05, 0.25, 0.05)), components.Joint3D{ .position = .init(0, 0.25, 0), .connected_position = .init(0, 4.25, 0) } });
    const lamp = try app.world.spawnWith(.{ Transform3D.at(0, 3.5, 0), RigidBody3D{}, Collider3D.sphere(0.2), components.Joint3D{ .connected = link, .position = .init(0, 0.25, 0), .connected_position = .init(0, -0.25, 0) } });
    // Pushed sideways, it swings and keeps its length.
    app.world.get(lamp, RigidBody3D).?.linear_velocity = .init(2, 0, 0);
    try frames(app, 120);
    try testing.expectEqual(@as(usize, 2), app.physics3d.jointCount());
    const hung = app.world.get(lamp, Transform3D).?.position;
    // No further from the ceiling than the chain and the lamp's hook reach.
    try testing.expect(hung.sub(.init(0, 4.25, 0)).len() < 1.02);
    try testing.expect(hung.y > 3);
    // Disabled, the chain lets the lamp go.
    app.world.get(lamp, components.Joint3D).?.disabled = true;
    try frames(app, 60);
    try testing.expectEqual(@as(usize, 1), app.physics3d.jointCount());
    try testing.expect(app.world.get(lamp, Transform3D).?.position.y < 0);
    try app.world.remove(link, components.Joint3D);
    try frames(app, 1);
    try testing.expectEqual(@as(usize, 0), app.physics3d.jointCount());
}

test "a physical bone follows its bone while it is not simulated, and the bone follows it once it is" {
    const app = try headless();
    defer app.destroy();
    _ = try floorOf(app);
    const skeleton_table = @import("../render/skeleton.zig");
    const bones = [_]skeleton_table.Bone{
        .{ .name = "Hips", .rest = .{ .translation = .init(0, 1, 0) } },
        .{ .name = "Chest", .parent = 0, .rest = .{ .translation = .init(0, 0.5, 0) } },
    };
    const skeleton = try app.addSkeleton("doll", try skeleton_table.Skeleton.init(app.gpa, &bones));
    const doll = try app.world.spawnWith(.{Transform3D.at(2, 0, 0)});
    const rig = try app.world.spawnWith(.{ Transform3D{}, Parent.of(doll), components.Skeleton3D{ .skeleton = skeleton } });
    const hips = try app.world.spawnWith(.{ Transform3D{}, Parent.of(doll), RigidBody3D{}, Collider3D.box(.init(0.15, 0.15, 0.1)), components.PhysicalBone3D.of("Hips") });
    const chest_body = try app.world.spawnWith(.{ Transform3D{}, Parent.of(doll), RigidBody3D{}, Collider3D.box(.init(0.15, 0.2, 0.1)), components.PhysicalBone3D.of("Chest"), components.Joint3D{ .connected = hips, .connected_position = .init(0, 0.25, 0), .position = .init(0, -0.25, 0) } });
    try frames(app, 10);
    // Following: kinematic, where the hips are, a metre up beside the doll.
    try testing.expectEqual(RigidBody3D.Type.kinematic, app.world.get(hips, RigidBody3D).?.type);
    try testing.expect(app.world.get(hips, Transform3D).?.position.sub(.init(0, 1, 0)).len() < 1e-3);
    try testing.expect(app.bodyOf3D(hips).?.position().sub(.init(2, 1, 0)).len() < 1e-3);
    // Simulated: it falls onto the floor, and the skeleton's hips with it.
    var it = try @import("fluxion_ecs").Query(.{components.PhysicalBone3D}).over(&app.world);
    while (it.next()) |chunk| for (chunk.slice(components.PhysicalBone3D)) |*part| {
        part.simulate = true;
    };
    try frames(app, 180);
    try testing.expectEqual(RigidBody3D.Type.dynamic, app.world.get(hips, RigidBody3D).?.type);
    const globals = app.poses.globalsOf(app, rig).?;
    const fallen = math.Transform.fromMat4(globals[0]).translation;
    try testing.expect(fallen.y < 0.4);
    // The chest still hangs from the hips at the joint, and its bone is
    // where its body is.
    const hips_at = app.bodyOf3D(hips).?.transform;
    const chest_at = app.bodyOf3D(chest_body).?.transform;
    try testing.expect(hips_at.apply(.init(0, 0.25, 0)).sub(chest_at.apply(.init(0, -0.25, 0))).len() < 0.02);
    const chest = math.Transform.fromMat4(globals[1]).translation;
    try testing.expect(chest.add(.init(2, 0, 0)).sub(chest_at.position).len() < 0.02);
}
