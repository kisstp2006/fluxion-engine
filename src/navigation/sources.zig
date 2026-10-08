// SPDX-License-Identifier: BSD-3-Clause

//! What a `NavigationRegion3D` is baked from: the triangles of the meshes
//! and the still colliders that hang from it - or the whole scene's - in
//! the region's own space. A primitive's mesh and every collider but a
//! mesh are closed convex solids, filled when baked; any other mesh is its
//! surface. What moves is left out: a rigid body, a character, an area,
//! and what hangs from one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const navmesh = @import("fluxion_navmesh");
const physics3d = @import("fluxion_physics3d");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const nav = @import("navigation_components.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const NavigationRegion3D = nav.NavigationRegion3D;

pub const Gathered = struct {
    vertices: std.ArrayList(navmesh.Vec3) = .empty,
    triangles: std.ArrayList([3]u32) = .empty,
    solids: std.ArrayList([2]u32) = .empty,

    pub fn deinit(self: *Gathered, gpa: Allocator) void {
        self.vertices.deinit(gpa);
        self.triangles.deinit(gpa);
        self.solids.deinit(gpa);
        self.* = undefined;
    }

    pub fn input(self: *const Gathered) navmesh.Input {
        return .{ .vertices = self.vertices.items, .triangles = self.triangles.items, .solids = self.solids.items };
    }

    /// Triangles about to be added, as one solid when `solid`.
    fn begin(self: *const Gathered) [2]u32 {
        return .{ @intCast(self.vertices.items.len), @intCast(self.triangles.items.len) };
    }

    fn end(self: *Gathered, gpa: Allocator, started: [2]u32, solid: bool) Allocator.Error!void {
        const count: u32 = @as(u32, @intCast(self.triangles.items.len)) - started[1];
        if (solid and count > 0) try self.solids.append(gpa, .{ started[1], count });
    }

    fn vertex(self: *Gathered, gpa: Allocator, p: Vec3) Allocator.Error!u32 {
        try self.vertices.append(gpa, .{ p.x, p.y, p.z });
        return @intCast(self.vertices.items.len - 1);
    }

    /// A triangle of the vertices from `base`, turned round when what
    /// placed them mirrors.
    fn triangle(self: *Gathered, gpa: Allocator, base: u32, t: [3]u32, mirrored: bool) Allocator.Error!void {
        if (mirrored) {
            try self.triangles.append(gpa, .{ base + t[0], base + t[2], base + t[1] });
        } else try self.triangles.append(gpa, .{ base + t[0], base + t[1], base + t[2] });
    }
};

pub const Error = Allocator.Error || error{ NotARegion, FlatRegion, TooManyComponents };

/// Every triangle `region` is baked from, in its own space.
pub fn gather(app: *App, region: Entity) Error!Gathered {
    const settings = (app.world.get(region, NavigationRegion3D) orelse return error.NotARegion).*;
    const gpa = app.gpa;
    var out: Gathered = .{};
    errdefer out.deinit(gpa);
    // Into the region's own space.
    const placed = app.worldTransform3D(region) orelse components.Transform3D{};
    const to_local = placed.matrix().inverse() orelse return error.FlatRegion;

    if (settings.source != .colliders) try gatherMeshes(app, region, settings.scope, to_local, &out);
    if (settings.source != .meshes) try gatherColliders(app, region, settings.scope, to_local, &out);
    return out;
}

/// Whether `e` is in the region's reach.
fn inScope(app: *App, e: Entity, region: Entity, scope: NavigationRegion3D.Scope) bool {
    if (scope == .scene) return true;
    var at = e;
    for (0..64) |_| {
        if (at.eql(region)) return true;
        const above = app.parentOf(at);
        if (above.isNone()) return false;
        at = above;
    }
    return false;
}

/// Whether `e`, or what it hangs from, moves on its own.
fn moves(app: *App, e: Entity) bool {
    var at = e;
    for (0..64) |_| {
        if (app.world.has(at, components.RigidBody3D) or app.world.has(at, components.CharacterBody3D) or app.world.has(at, components.Area3D)) return true;
        const above = app.parentOf(at);
        if (above.isNone()) return false;
        at = above;
    }
    return false;
}

fn gatherMeshes(app: *App, region: Entity, scope: NavigationRegion3D.Scope, to_local: Mat4, out: *Gathered) Error!void {
    const gpa = app.gpa;
    var it = try ecs.Query(.{ components.Transform3D, components.MeshInstance3D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(components.MeshInstance3D)) |e, instance| {
            // A skin goes where its bones do.
            if (!instance.skeleton.isNone()) continue;
            if (!inScope(app, e, region, scope) or moves(app, e)) continue;
            // A closed shape, whose inside is not walked on.
            const solid = if (app.world.get(e, components.PrimitiveMesh3D)) |shape| shape.shape != .plane else app.world.has(e, components.CSGShape3D);
            const mesh = &(try app.meshDrawnBy(e, instance) orelse continue).mesh;
            const world = (app.worldTransform3D(e) orelse continue).matrix();
            const m = to_local.mul(world);
            const mirrored = m.det() < 0;
            const started = out.begin();
            for (mesh.vertices) |v| _ = try out.vertex(gpa, m.mulPoint(.init(v.position[0], v.position[1], v.position[2])));
            var i: usize = 0;
            while (i + 2 < mesh.indices.len) : (i += 3) {
                try out.triangle(gpa, started[0], .{ mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2] }, mirrored);
            }
            try out.end(gpa, started, solid);
        }
    }
}

fn gatherColliders(app: *App, region: Entity, scope: NavigationRegion3D.Scope, to_local: Mat4, out: *Gathered) Error!void {
    const gpa = app.gpa;
    // The colliders where their transforms say.
    app.bodies3d.sync(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    var it = try ecs.Query(.{ components.Transform3D, components.Collider3D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(components.Collider3D)) |e, collider| {
            if (collider.disabled or collider.sensor) continue;
            if (!inScope(app, e, region, scope) or moves(app, e)) continue;
            const id = app.bodies3d.shapeOfEntity(e) orelse continue;
            const shape = app.physics3d.shape(id) orelse continue;
            const body = app.physics3d.bodyConst(shape.body) orelse continue;
            if (body.type != .static) continue;
            const xf = app.physics3d.shapeTransform(shape);
            try addGeometry(gpa, shape.def.geometry, xf, to_local, out);
        }
    }
}

/// A collider's shape as triangles, wound outwards.
fn addGeometry(gpa: Allocator, geometry: physics3d.Geometry, xf: physics3d.Transform, to_local: Mat4, out: *Gathered) Allocator.Error!void {
    const place = struct {
        fn at(m: Mat4, t: physics3d.Transform, p: Vec3) Vec3 {
            return m.mulPoint(t.apply(p));
        }
    };
    const started = out.begin();
    switch (geometry) {
        .box => |b| {
            const h = b.half;
            for (0..8) |i| {
                const p: Vec3 = .init(if (i & 1 != 0) h.x else -h.x, if (i & 2 != 0) h.y else -h.y, if (i & 4 != 0) h.z else -h.z);
                _ = try out.vertex(gpa, place.at(to_local, xf, p));
            }
            for (box_faces) |f| {
                try out.triangle(gpa, started[0], .{ f[0], f[1], f[2] }, false);
                try out.triangle(gpa, started[0], .{ f[0], f[2], f[3] }, false);
            }
        },
        .sphere => |s| try lathe(gpa, out, started[0], to_local, xf, &sphereProfile(s.radius, 0)),
        .capsule => |c| try lathe(gpa, out, started[0], to_local, xf, &capsuleProfile(c.radius, c.half_height)),
        .cylinder => |c| try lathe(gpa, out, started[0], to_local, xf, &[_][2]f32{ .{ 0, -c.half_height }, .{ c.radius, -c.half_height }, .{ c.radius, c.half_height }, .{ 0, c.half_height } }),
        .hull => |hull| {
            for (hull.vertices) |v| _ = try out.vertex(gpa, place.at(to_local, xf, v));
            for (hull.faces) |face| {
                const corners = hull.face_vertices[face.first..][0..face.count];
                for (1..corners.len - 1) |k| try out.triangle(gpa, started[0], .{ corners[0], corners[k], corners[k + 1] }, false);
            }
        },
        .mesh => |mesh| {
            for (mesh.vertices) |v| _ = try out.vertex(gpa, place.at(to_local, xf, v));
            for (mesh.triangles) |t| try out.triangle(gpa, started[0], t, false);
            // A surface, not a solid.
            return;
        },
    }
    try out.end(gpa, started, true);
}

/// A box's corners, bit 0 x, bit 1 y, bit 2 z, and its faces outwards.
const box_faces = [6][4]u32{
    .{ 2, 6, 7, 3 },
    .{ 0, 1, 5, 4 },
    .{ 1, 3, 7, 5 },
    .{ 0, 4, 6, 2 },
    .{ 4, 5, 7, 6 },
    .{ 0, 2, 3, 1 },
};

const segments = 12;
const rings = 4;

/// A ball's outline from its bottom to its top, as radius and height, its
/// middle `y` up.
fn sphereProfile(radius: f32, y: f32) [2 * rings + 1][2]f32 {
    var out: [2 * rings + 1][2]f32 = undefined;
    for (&out, 0..) |*p, i| {
        const a = (@as(f32, @floatFromInt(i)) / (2 * rings) - 0.5) * std.math.pi;
        p.* = .{ radius * @cos(a), y + radius * @sin(a) };
    }
    return out;
}

/// A capsule's: the bottom half ball, then the top one.
fn capsuleProfile(radius: f32, half_height: f32) [2 * rings + 2][2]f32 {
    var out: [2 * rings + 2][2]f32 = undefined;
    const low = sphereProfile(radius, -half_height);
    const high = sphereProfile(radius, half_height);
    for (0..rings + 1) |i| out[i] = low[i];
    for (rings..2 * rings + 1) |i| out[i + 1] = high[i];
    return out;
}

/// A solid turned round `y` from its outline, bottom to top: `segments`
/// round, its faces outwards.
fn lathe(gpa: Allocator, out: *Gathered, base: u32, to_local: Mat4, xf: physics3d.Transform, profile: []const [2]f32) Allocator.Error!void {
    for (profile) |p| {
        for (0..segments) |k| {
            const a = @as(f32, @floatFromInt(k)) / segments * std.math.tau;
            _ = try out.vertex(gpa, to_local.mulPoint(xf.apply(.init(p[0] * @cos(a), p[1], p[0] * @sin(a)))));
        }
    }
    for (0..profile.len - 1) |j| {
        for (0..segments) |k| {
            const k1 = (k + 1) % segments;
            const a: u32 = @intCast(j * segments + k);
            const b: u32 = @intCast(j * segments + k1);
            const c: u32 = @intCast((j + 1) * segments + k1);
            const d: u32 = @intCast((j + 1) * segments + k);
            try out.triangle(gpa, base, .{ a, c, b }, false);
            try out.triangle(gpa, base, .{ a, d, c }, false);
        }
    }
    // The bottom's and the top's flat caps, where the outline has a radius there.
    const last = profile.len - 1;
    for (1..segments - 1) |k| {
        if (profile[0][0] > 0) try out.triangle(gpa, base, .{ 0, @intCast(k), @intCast(k + 1) }, false);
        if (profile[last][0] > 0) {
            const top: u32 = @intCast(last * segments);
            try out.triangle(gpa, base, .{ top, top + @as(u32, @intCast(k + 1)), top + @as(u32, @intCast(k)) }, false);
        }
    }
}

test "the solids made from colliders are wound outwards" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var out: Gathered = .{};
    defer out.deinit(gpa);
    const identity = Mat4.identity;
    for ([_]physics3d.Geometry{
        .{ .box = .{ .half = .init(1, 0.5, 2) } },
        .{ .sphere = .{ .radius = 1 } },
        .{ .capsule = .{ .radius = 0.5, .half_height = 1 } },
        .{ .cylinder = .{ .radius = 0.5, .half_height = 1 } },
    }) |g| {
        out.vertices.clearRetainingCapacity();
        out.triangles.clearRetainingCapacity();
        try addGeometry(gpa, g, .{}, identity, &out);
        try testing.expect(out.triangles.items.len > 4);
        var up = false;
        for (out.triangles.items) |t| {
            const a = out.vertices.items[t[0]];
            const b = out.vertices.items[t[1]];
            const c = out.vertices.items[t[2]];
            const n = navmesh.vec.cross(b - a, c - a);
            if (navmesh.vec.length(n) < 1e-6) continue;
            const middle = (a + b + c) / @as(navmesh.Vec3, @splat(3));
            try testing.expect(navmesh.vec.dot(n, middle) > 0);
            if (n[1] > 0.9 * navmesh.vec.length(n)) up = true;
        }
        // Its top can be stood on.
        try testing.expect(up);
    }
}
