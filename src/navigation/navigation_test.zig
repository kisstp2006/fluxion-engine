// SPDX-License-Identifier: BSD-3-Clause

//! Navigation through a whole app, headless: a region baked from what hangs
//! from it, ways round what is in the way, agents walking to their targets
//! and out of each other's way, and a `.navmesh` written and read back.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const components = @import("../scene/components.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Transform3D = components.Transform3D;
const Collider3D = components.Collider3D;
const CharacterBody3D = components.CharacterBody3D;
const MeshInstance3D = components.MeshInstance3D;
const PrimitiveMesh3D = components.PrimitiveMesh3D;
const NavigationRegion3D = components.NavigationRegion3D;
const NavigationAgent3D = components.NavigationAgent3D;
const Parent = components.Parent;

const dt = 1.0 / 60.0;

fn headless() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .frame_time = dt });
    errdefer app.destroy();
    try app.addMethod("_reached", Heard.reached);
    try app.addMethod("_finished", Heard.finished);
    try app.addMethod("_safe", Heard.safe);
    try app.addMethod("_link", Heard.link);
    try app.addMethod("_changed", Heard.changed);
    Heard.reset();
    return app;
}

const Heard = struct {
    var reached_count: usize = 0;
    var finished_count: usize = 0;
    var safe_count: usize = 0;
    var link_count: usize = 0;
    var changed_count: usize = 0;

    fn reset() void {
        reached_count = 0;
        finished_count = 0;
        safe_count = 0;
        link_count = 0;
        changed_count = 0;
    }

    /// At a link's start: over it at once, as a jump would take it.
    fn link(app: *App, self: Entity, _: Vec3, end: Vec3) !void {
        link_count += 1;
        app.world.get(self, Transform3D).?.position = end.add(.init(0, 0.9, 0));
    }

    fn changed(_: *App, _: Entity) !void {
        changed_count += 1;
    }

    fn reached(_: *App, _: Entity) !void {
        reached_count += 1;
    }

    fn finished(_: *App, _: Entity) !void {
        finished_count += 1;
    }

    /// Each agent moves by what keeps it out of the way.
    fn safe(app: *App, self: Entity, velocity: Vec3) !void {
        safe_count += 1;
        const body = app.world.get(self, CharacterBody3D) orelse return;
        body.velocity = velocity;
        _ = try app.moveAndSlide(self);
    }
};

/// A region with a floor twenty across hanging from it - a collider - and a
/// pillar two across in the middle - a box mesh.
fn level(app: *App) !Entity {
    const region = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(10, 0.5, 10)), Parent.of(region) });
    var pillar: PrimitiveMesh3D = .of(.box);
    pillar.size = .init(2, 3, 2);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 1.5, 0), MeshInstance3D{}, pillar, Parent.of(region) });
    return region;
}

fn legsClear(path: []const Vec3, half: f32) !void {
    for (path[0 .. path.len - 1], path[1..]) |a, b| {
        for (0..21) |k| {
            const p = a.lerp(b, @as(f32, @floatFromInt(k)) / 20);
            try testing.expect(@max(@abs(p.x), @abs(p.z)) > half);
        }
    }
}

test "a region baked from what hangs from it has a way round the pillar, and carries its floor when it moves" {
    const app = try headless();
    defer app.destroy();
    const region = try level(app);
    // Nothing outside the region is baked.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 5, 0), Collider3D.box(.init(30, 0.5, 30)) });
    try app.bakeNavigationMesh(region, null);
    const handle = app.world.get(region, NavigationRegion3D).?.navigation_mesh;
    const mesh = app.navMeshOf(handle).?;
    try testing.expect(mesh.polygons.len > 0);
    for (mesh.vertices) |v| try testing.expect(v[1] < 1);

    const way = try app.navigationPath(.init(0, 0, -7), .init(0, 0, 7));
    try testing.expect(way.len >= 3);
    try testing.expect(way[0].sub(Vec3.init(0, 0, -7)).len() < 0.3);
    try testing.expect(way[way.len - 1].sub(Vec3.init(0, 0, 7)).len() < 0.3);
    try legsClear(way, 1.1);

    // Off the floor, the nearest point of it.
    const near = try app.closestNavigationPoint(.init(20, 3, 0));
    try testing.expect(near.x > 8 and near.x < 9.6);
    // Moved, its floor goes with it.
    app.world.get(region, Transform3D).?.position = .init(100, 0, 0);
    const moved = try app.closestNavigationPoint(.init(100, 1, -7));
    try testing.expectApproxEqAbs(@as(f32, 100), moved.x, 0.01);
}

test "an agent walks round the pillar to its target, says it got there once, and finishes" {
    const app = try headless();
    defer app.destroy();
    const region = try level(app);
    try app.bakeNavigationMesh(region, null);
    const walker = try app.world.spawnWith(.{
        Transform3D.at(0, 0.9, -7),
        CharacterBody3D{},
        Collider3D.capsule(0.4, 1.8),
        NavigationAgent3D{ .target_position = .init(0.5, 0, 7) },
    });
    try app.signal(walker, NavigationAgent3D, .target_reached).connect(.method(walker, "_reached"), .{});
    try app.signal(walker, NavigationAgent3D, .navigation_finished).connect(.method(walker, "_finished"), .{});
    app.time.source = .{ .fixed = dt };
    var seconds: f32 = 0;
    while (seconds < 10 and !app.isNavigationFinished(walker)) : (seconds += dt) {
        const next = try app.nextPathPosition(walker);
        const at = app.world.get(walker, Transform3D).?.position;
        var to = next.sub(at);
        to.y = 0;
        const body = app.world.get(walker, CharacterBody3D).?;
        const speed: f32 = 4;
        const flat = if (to.len() > 1e-4) to.scale(speed / to.len()) else Vec3.zero;
        body.velocity = .init(flat.x, body.velocity.y - 9.8 * dt, flat.z);
        _ = try app.moveAndSlide(walker);
        _ = try app.step();
        // Never through the pillar.
        const p = app.world.get(walker, Transform3D).?.position;
        try testing.expect(@max(@abs(p.x), @abs(p.z)) > 1.2);
    }
    // There, in less than going straight at walking pace twice over.
    try testing.expect(seconds < 7);
    try testing.expect(app.isTargetReached(walker));
    try testing.expect(app.distanceToTarget(walker) < 1.1);
    // Asked again, it stays put and says nothing more.
    _ = try app.nextPathPosition(walker);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.reached_count);
    try testing.expectEqual(@as(usize, 1), Heard.finished_count);
    // A new target sets it off again.
    app.world.get(walker, NavigationAgent3D).?.target_position = .init(-6, 0, 6);
    _ = try app.nextPathPosition(walker);
    try testing.expect(!app.isNavigationFinished(walker));
}

test "two agents walking at each other with avoidance are given velocities that keep them apart" {
    const app = try headless();
    defer app.destroy();
    const region = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(10, 0.5, 4)), Parent.of(region) });
    try app.bakeNavigationMesh(region, null);
    var agents: [2]Entity = undefined;
    for (&agents, [_]f32{ -5, 5 }, [_]f32{ 0.05, -0.05 }) |*a, x, z| {
        a.* = try app.world.spawnWith(.{
            Transform3D.at(x, 0.9, z),
            CharacterBody3D{},
            Collider3D.capsule(0.4, 1.8),
            NavigationAgent3D{ .target_position = .init(-x, 0, z), .avoidance_enabled = true, .radius = 0.5, .max_speed = 3, .time_horizon = 2 },
        });
        try app.signal(a.*, NavigationAgent3D, .velocity_computed).connect(.method(a.*, "_safe"), .{});
    }
    app.time.source = .{ .fixed = dt };
    var nearest: f32 = std.math.inf(f32);
    for (0..360) |_| {
        for (agents) |a| {
            if (app.isNavigationFinished(a) and app.isTargetReached(a)) continue;
            const next = try app.nextPathPosition(a);
            const at = app.world.get(a, Transform3D).?.position;
            var to = next.sub(at);
            to.y = 0;
            const want = if (to.len() > 1e-4) to.scale(2.5 / to.len()) else Vec3.zero;
            try app.setAgentVelocity(a, want);
        }
        _ = try app.step();
        const pa = app.world.get(agents[0], Transform3D).?.position;
        const pb = app.world.get(agents[1], Transform3D).?.position;
        nearest = @min(nearest, Vec3.init(pa.x - pb.x, 0, pa.z - pb.z).len());
    }
    try testing.expect(Heard.safe_count > 100);
    // Their capsules never ran into each other, and both got past.
    try testing.expect(nearest > 0.75);
    try testing.expect(app.world.get(agents[0], Transform3D).?.position.x > 3);
    try testing.expect(app.world.get(agents[1], Transform3D).?.position.x < -3);
}

test "a navigation mesh baked into a file is read back by another app, and a scene keeps it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try Project.writeSettings(testing.allocator, testing.io, root, .{ .application = .{ .name = "Walked" } });
    {
        const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
        defer app.destroy();
        const region = try level(app);
        try app.bakeNavigationMesh(region, "res://level.navmesh");
        try testing.expectEqualStrings("res://level.navmesh", app.assetSource(app.world.get(region, NavigationRegion3D).?.navigation_mesh).?);
        try app.saveScene("res://level.json", .{});
    }
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
    defer app.destroy();
    _ = try app.instantiate(try app.loadScene("res://level.json"), .none);
    const way = try app.navigationPath(.init(0, 0, -7), .init(0, 0, 7));
    try testing.expect(way.len >= 3);
    try legsClear(way, 1.1);
}

test "a script bakes the region, walks its agent by the velocity that comes back, and asks for a way" {
    const script = @import("../script/script.zig");
    const app = try headless();
    defer app.destroy();
    try app.useScripts(.{});
    const region = try level(app);
    try app.setName(region, "Region");
    const handle = try app.addScript("walker.flux",
        \\var corners = 0;
        \\var moves = 0;
        \\struct Walker {
        \\    fn ready(self) {
        \\        app.bakeNavigationMesh(app.find("Region").?);
        \\        app.setDebugView("navigation", true);
        \\        self.entity.get(NavigationAgent3D).velocity_computed.connect(self.moved);
        \\    }
        \\    fn fixed(self, dt: float) {
        \\        if (app.isNavigationFinished(self.entity)) return;
        \\        const next = app.nextPathPosition(self.entity);
        \\        var to = next - self.entity.globalPosition3D().?;
        \\        to.y = 0.0;
        \\        if (to.length() > 0.001) app.setAgentVelocity(self.entity, to.normalized() * 4.0);
        \\        corners = app.navigationPath(vec3(0, 0, -7), vec3(0, 0, 7)).len;
        \\    }
        \\    fn moved(self, safe_velocity: vec3) {
        \\        moves += 1;
        \\        const body = self.entity.get(CharacterBody3D);
        \\        body.velocity = vec3(safe_velocity.x, body.velocity.y - 0.16, safe_velocity.z);
        \\        app.moveAndSlide(self.entity);
        \\    }
        \\}
    );
    const walker = try app.world.spawnWith(.{
        Transform3D.at(0, 0.9, -7),
        CharacterBody3D{},
        Collider3D.capsule(0.4, 1.8),
        NavigationAgent3D{ .target_position = .init(0, 0, 7) },
        script.Script.of(handle),
    });
    for (0..420) |_| _ = try app.step();
    const scripts = app.scripts.?;
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    const module = scripts.moduleOf(handle).?;
    try testing.expect(scripts.vm.get(module, "corners").?.asInt() >= 3);
    try testing.expect(scripts.vm.get(module, "moves").?.asInt() > 60);
    try testing.expect(app.isTargetReached(walker));
    try testing.expect(app.isDebugViewOn("navigation"));
    try testing.expectError(error.NoSuchView, app.setDebugView("nothing", true));
}

const NavigationLink3D = components.NavigationLink3D;
const NavigationObstacle3D = components.NavigationObstacle3D;

/// Walk the agent on `walker` towards where it should head, at `speed`,
/// for `seconds` or until it has finished.
fn walk(app: *App, walker: Entity, speed: f32, seconds: f32) !f32 {
    var t: f32 = 0;
    while (t < seconds and !app.isNavigationFinished(walker)) : (t += dt) {
        const next = try app.nextPathPosition(walker);
        const at = app.world.get(walker, Transform3D).?.position;
        var to = next.sub(at);
        to.y = 0;
        const body = app.world.get(walker, CharacterBody3D).?;
        const flat = if (to.len() > 1e-4) to.scale(speed / to.len()) else Vec3.zero;
        body.velocity = .init(flat.x, body.velocity.y - 9.8 * dt, flat.z);
        _ = try app.moveAndSlide(walker);
        _ = try app.step();
    }
    return t;
}

fn spawnWalker(app: *App, at: Vec3, target: Vec3) !Entity {
    return app.world.spawnWith(.{
        Transform3D.at(at.x, at.y + 0.9, at.z),
        CharacterBody3D{},
        Collider3D.capsule(0.4, 1.8),
        NavigationAgent3D{ .target_position = target },
    });
}

test "two regions cut along one line are one map, and a way crosses from one into the other" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(8, 0.5, 3)) });
    const left = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{ .scope = .scene, .bake_bounds_center = .init(-4, 0, 0), .bake_bounds_size = .init(8, 4, 8) } });
    const right = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{ .scope = .scene, .bake_bounds_center = .init(4, 0, 0), .bake_bounds_size = .init(8, 4, 8) } });
    try app.bakeNavigationMesh(left, null);
    try app.bakeNavigationMesh(right, null);
    // Each reaches the line it is cut at, worn back only at the floor's ends.
    for ([_]Entity{ left, right }, [_]f32{ 1, -1 }) |region, side| {
        const mesh = app.navMeshOf(app.world.get(region, NavigationRegion3D).?.navigation_mesh).?;
        var nearest: f32 = 100;
        for (mesh.vertices) |v| nearest = @min(nearest, @abs(v[0]));
        try testing.expectApproxEqAbs(@as(f32, 0), nearest, 1e-3);
        for (mesh.vertices) |v| try testing.expect(v[0] * side <= 1e-3);
    }
    const way = try app.navigationPath(.init(-6, 0, 1), .init(6, 0, -1));
    try testing.expect(way.len >= 2);
    try testing.expect(way[way.len - 1].sub(Vec3.init(6, 0, -1)).len() < 0.3);
    // The map knows where they meet.
    const map = (try app.navigation.mapOf(app)).?;
    var doors: usize = 0;
    for (map.links) |l| {
        if (l.kind == .doorway) doors += 1;
    }
    try testing.expect(doors >= 2);
}

test "a link takes an agent over a trench the mesh does not cross, and it hears the link's start" {
    const app = try headless();
    defer app.destroy();
    const region = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(-4.5, -0.5, 0), Collider3D.box(.init(3.5, 0.5, 3)), Parent.of(region) });
    _ = try app.world.spawnWith(.{ Transform3D.at(4.5, -0.5, 0), Collider3D.box(.init(3.5, 0.5, 3)), Parent.of(region) });
    try app.bakeNavigationMesh(region, null);
    // No way across without a link.
    try testing.expect((try app.navigationPath(.init(-6, 0, 0), .init(6, 0, 0)))[(try app.navigationPath(.init(-6, 0, 0), .init(6, 0, 0))).len - 1].x < 0);
    _ = try app.world.spawnWith(.{ Transform3D{}, NavigationLink3D{ .start_position = .init(-1.6, 0, 0), .end_position = .init(1.6, 0, 0) } });
    const across = try app.navigationPath(.init(-6, 0, 0), .init(6, 0, 0));
    try testing.expect(across[across.len - 1].sub(Vec3.init(6, 0, 0)).len() < 0.3);

    const agent = try spawnWalker(app, .init(-6, 0, 0.5), .init(6, 0, -0.5));
    try app.signal(agent, NavigationAgent3D, .link_reached).connect(.method(agent, "_link"), .{});
    app.time.source = .{ .fixed = dt };
    _ = try walk(app, agent, 4, 10);
    try testing.expectEqual(@as(usize, 1), Heard.link_count);
    try testing.expect(app.isTargetReached(agent));
}

test "an obstacle standing in the doorway an agent's way goes through has it find the other" {
    const app = try headless();
    defer app.destroy();
    const region = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{ .agent_radius = 0.4 } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(7, 0.5, 6)), Parent.of(region) });
    // A wall across with a doorway at each side of the middle.
    for ([_][2]f32{ .{ -5.5, 1.5 }, .{ 0, 2 }, .{ 5.5, 1.5 } }) |w| {
        _ = try app.world.spawnWith(.{ Transform3D.at(w[0], 1, 0), Collider3D.box(.init(w[1], 1, 0.25)), Parent.of(region) });
    }
    try app.bakeNavigationMesh(region, null);
    const agent = try spawnWalker(app, .init(0, 0, -4), .init(0, 0, 4));
    try app.signal(agent, NavigationAgent3D, .path_changed).connect(.method(agent, "_changed"), .{});
    app.time.source = .{ .fixed = dt };
    _ = try app.nextPathPosition(agent);
    const first = app.agentPath(agent);
    // Through one of the two doorways.
    var side: f32 = 0;
    for (first) |p| {
        if (@abs(p.z) < 1.0) side = p.x;
    }
    try testing.expect(@abs(side) > 1.5);
    // Something that closes ways stands in it.
    _ = try app.world.spawnWith(.{ Transform3D.at(if (side > 0) 3 else -3, 0, 0), NavigationObstacle3D{ .radius = 1, .affect_paths = true } });
    _ = try app.step();
    _ = try app.nextPathPosition(agent);
    // Heard when the signals are next said.
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Heard.changed_count);
    var other: f32 = 0;
    for (app.agentPath(agent)) |p| {
        if (@abs(p.z) < 1.0) other = p.x;
    }
    try testing.expect(other * side < 0);
}

test "an agent with avoidance goes round an obstacle that crosses its way and does not turn for it" {
    const app = try headless();
    defer app.destroy();
    const region = try app.world.spawnWith(.{ Transform3D{}, NavigationRegion3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -0.5, 0), Collider3D.box(.init(10, 0.5, 6)), Parent.of(region) });
    try app.bakeNavigationMesh(region, null);
    const agent = try app.world.spawnWith(.{
        Transform3D.at(-7, 0.9, 0),
        CharacterBody3D{},
        Collider3D.capsule(0.4, 1.8),
        NavigationAgent3D{ .target_position = .init(7, 0, 0), .avoidance_enabled = true, .radius = 0.4, .max_speed = 3, .time_horizon = 2 },
    });
    try app.signal(agent, NavigationAgent3D, .velocity_computed).connect(.method(agent, "_safe"), .{});
    const cart = try app.world.spawnWith(.{ Transform3D.at(0, 0, -4.5), NavigationObstacle3D{ .radius = 0.8 } });
    app.time.source = .{ .fixed = dt };
    var nearest: f32 = std.math.inf(f32);
    for (0..420) |_| {
        if (!app.isTargetReached(agent)) {
            const next = try app.nextPathPosition(agent);
            const at = app.world.get(agent, Transform3D).?.position;
            var to = next.sub(at);
            to.y = 0;
            try app.setAgentVelocity(agent, if (to.len() > 1e-4) to.scale(2.5 / to.len()) else Vec3.zero);
        }
        // The cart rolls across at its own pace.
        app.world.get(cart, Transform3D).?.position.z += 1.4 * dt;
        _ = try app.step();
        const a = app.world.get(agent, Transform3D).?.position;
        const c = app.world.get(cart, Transform3D).?.position;
        nearest = @min(nearest, Vec3.init(a.x - c.x, 0, a.z - c.z).len());
    }
    try testing.expect(nearest > 1.1);
    try testing.expect(app.world.get(cart, NavigationObstacle3D).?.velocity.z > 1.3);
    try testing.expect(app.isTargetReached(agent));
}
