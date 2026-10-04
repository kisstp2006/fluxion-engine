// SPDX-License-Identifier: BSD-3-Clause

//! Meshes: the triangles a `MeshInstance3D` draws, kept by the app under a
//! `MeshHandle` - made in code, read from a `.mesh` file, or worked out from
//! a `PrimitiveMesh3D`'s numbers.
//!
//! ```zig
//! const crate = try fx.mesh.box(gpa, .init(1, 1, 1));
//! const handle = try app.addMesh("crate", crate); // the app's from here
//! _ = try app.world.spawnWith(.{ fx.Transform3D.at(0, 0.5, 0), fx.MeshInstance3D{ .mesh = handle } });
//! try app.saveMesh(handle, "res://models/crate.mesh");
//! ```
//!
//! A triangle's corners go counter-clockwise seen from the side it faces:
//! the side a `Material3D`'s `cull` keeps. A mesh is one or more surfaces -
//! runs of its triangles - each drawn with a material of its own: a model's
//! mesh has one for each material it was made with. A `.mesh` file is the
//! vertices, the indices and the surfaces as they are held, little-endian -
//! see `write`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const file_table = @import("../assets/file_table.zig");
const MaterialHandle = @import("materials.zig").MaterialHandle;

const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const Aabb = math.Aabb;

/// What a mesh's file ends in.
pub const extension = ".mesh";

/// A mesh, the way a `TextureHandle` is a picture.
pub const MeshHandle = file_table.Handle("MeshHandle");

/// One corner of a triangle: where it is, which way its surface faces,
/// where on a picture it is, the colour it holds - white for most, a
/// model's painted shading for some - and which way its pictures' `u` runs
/// across the surface, for a normal map: `w` is one, or minus one where `v`
/// runs the other way round.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32 = .{ 0, 0 },
    color: [4]u8 = .{ 255, 255, 255, 255 },
    tangent: [4]f32 = no_tangent,
};

/// What a vertex's tangent is until one is worked out.
pub const no_tangent: [4]f32 = .{ 1, 0, 0, 1 };

/// Each vertex's tangent worked out from its triangles' positions and
/// pictures' coordinates: what a normal map is read against. Where the
/// coordinates say nothing - none, or all one point - any way square to the
/// normal.
pub fn computeTangents(vertices: []Vertex, indices: []const u32) void {
    computeTangentsFrom(vertices, indices, 0);
}

/// `computeTangents` for the vertices from `base` on, which `indices` -
/// into the whole of `vertices` - name: one part of a mesh being built.
pub fn computeTangentsFrom(vertices: []Vertex, indices: []const u32, base: usize) void {
    for (vertices[base..]) |*v| {
        v.tangent = .{ 0, 0, 0, 0 };
    }
    // Each triangle's `u` and `v` directions, added to its corners'.
    var at: usize = 0;
    while (at + 3 <= indices.len) : (at += 3) {
        const corners = [3]u32{ indices[at], indices[at + 1], indices[at + 2] };
        const p0 = Vec3.fromArray(vertices[corners[0]].position);
        const p1 = Vec3.fromArray(vertices[corners[1]].position);
        const p2 = Vec3.fromArray(vertices[corners[2]].position);
        const uv0 = vertices[corners[0]].uv;
        const uv1 = vertices[corners[1]].uv;
        const uv2 = vertices[corners[2]].uv;
        const e1 = p1.sub(p0);
        const e2 = p2.sub(p0);
        const du1 = uv1[0] - uv0[0];
        const dv1 = uv1[1] - uv0[1];
        const du2 = uv2[0] - uv0[0];
        const dv2 = uv2[1] - uv0[1];
        const area = du1 * dv2 - du2 * dv1;
        if (@abs(area) < 1e-12) continue;
        const r = 1 / area;
        const u_way = e1.scale(dv2).sub(e2.scale(dv1)).scale(r);
        const v_way = e2.scale(du1).sub(e1.scale(du2)).scale(r);
        for (corners) |c| {
            const t = &vertices[c].tangent;
            t[0] += u_way.x;
            t[1] += u_way.y;
            t[2] += u_way.z;
            // The handedness, summed as a vote: `w` keeps it until the end.
            const n = Vec3.fromArray(vertices[c].normal);
            t[3] += if (n.cross(u_way).dot(v_way) < 0) -1 else 1;
        }
    }
    for (vertices[base..]) |*v| {
        const n = Vec3.fromArray(v.normal);
        const summed: Vec3 = .init(v.tangent[0], v.tangent[1], v.tangent[2]);
        // Square to the normal, as a normal map reads it.
        const square = summed.sub(n.scale(n.dot(summed)));
        const way = square.tryNorm() orelse anySquareTo(n);
        v.tangent = .{ way.x, way.y, way.z, if (v.tangent[3] < 0) -1 else 1 };
    }
}

/// A way square to `n`, for a vertex whose pictures say nothing of one.
fn anySquareTo(n: Vec3) Vec3 {
    const other: Vec3 = if (@abs(n.x) < 0.9) .unit_x else .unit_y;
    return other.sub(n.scale(n.dot(other))).tryNorm() orelse .unit_x;
}

/// Whether every vertex still has the tangent it started with: one nothing
/// has worked out.
fn tangentsUnset(vertices: []const Vertex) bool {
    for (vertices) |v| if (!std.meta.eql(v.tangent, no_tangent)) return false;
    return true;
}

/// A run of a mesh's indices, drawn with a material of its own.
pub const Surface = struct {
    first_index: u32,
    index_count: u32,
    /// None draws it plain, unless what draws the mesh says otherwise.
    material: MaterialHandle = .none,
};

/// Triangles: every three indices one, each naming a vertex, in surfaces.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    /// At least one, together every index once, in order.
    surfaces: []Surface,
    /// The box the vertices are in.
    bounds: Aabb,

    /// A mesh of one surface, of copies of `vertices` and `indices`, their
    /// tangents worked out where none was given. `error.BadMesh` for an
    /// index past the vertices, or a count of indices that is not whole
    /// triangles.
    pub fn init(gpa: Allocator, vertices: []const Vertex, indices: []const u32) (Allocator.Error || error{BadMesh})!Mesh {
        try check(vertices.len, indices);
        const own_vertices = try gpa.dupe(Vertex, vertices);
        errdefer gpa.free(own_vertices);
        if (tangentsUnset(own_vertices)) computeTangents(own_vertices, indices);
        const own_indices = try gpa.dupe(u32, indices);
        errdefer gpa.free(own_indices);
        return .{ .vertices = own_vertices, .indices = own_indices, .surfaces = try whole(gpa, indices.len), .bounds = boundsOf(vertices) };
    }

    /// A mesh of what `vertices`, `indices` and `surfaces` hold, which are
    /// its once it is made, and still the caller's when it is not.
    /// `error.BadMesh` as `init` says, or for surfaces that are not every
    /// index once, in order.
    pub fn adopt(vertices: []Vertex, indices: []u32, surfaces: []Surface) error{BadMesh}!Mesh {
        try check(vertices.len, indices);
        var at: u32 = 0;
        for (surfaces) |surface| {
            if (surface.first_index != at or surface.index_count % 3 != 0) return error.BadMesh;
            at += surface.index_count;
        }
        if (at != indices.len or surfaces.len == 0) return error.BadMesh;
        return .{ .vertices = vertices, .indices = indices, .surfaces = surfaces, .bounds = boundsOf(vertices) };
    }

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        gpa.free(self.surfaces);
        self.* = undefined;
    }

    pub fn triangleCount(self: Mesh) usize {
        return self.indices.len / 3;
    }

    /// The nearest triangle `ray` meets, in the mesh's own space, and how
    /// far along the ray it is: what a click picks.
    pub fn intersectRay(self: Mesh, ray: math.Ray) ?f32 {
        if (ray.intersectAabb(self.bounds) == null) return null;
        var nearest: ?f32 = null;
        var at: usize = 0;
        while (at + 3 <= self.indices.len) : (at += 3) {
            const a = Vec3.fromArray(self.vertices[self.indices[at]].position);
            const b = Vec3.fromArray(self.vertices[self.indices[at + 1]].position);
            const c = Vec3.fromArray(self.vertices[self.indices[at + 2]].position);
            const hit = ray.intersectTriangle(a, b, c) orelse continue;
            if (nearest == null or hit.t < nearest.?) nearest = hit.t;
        }
        return nearest;
    }
};

/// One surface of every index.
fn whole(gpa: Allocator, count: usize) Allocator.Error![]Surface {
    const out = try gpa.alloc(Surface, 1);
    out[0] = .{ .first_index = 0, .index_count = @intCast(count) };
    return out;
}

fn check(vertex_count: usize, indices: []const u32) error{BadMesh}!void {
    if (indices.len % 3 != 0) return error.BadMesh;
    for (indices) |index| if (index >= vertex_count) return error.BadMesh;
}

fn boundsOf(vertices: []const Vertex) Aabb {
    if (vertices.len == 0) return .init(.zero, .zero);
    var out: Aabb = .empty;
    for (vertices) |v| out = out.expand(.fromArray(v.position));
    return out;
}

// -------------------------------------------------------------------------
// Shapes made from numbers
// -------------------------------------------------------------------------

/// A mesh being put together: vertices and triangles added, then kept.
const Builder = struct {
    gpa: Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    fn deinit(self: *Builder) void {
        self.vertices.deinit(self.gpa);
        self.indices.deinit(self.gpa);
    }

    fn vertex(self: *Builder, position: Vec3, normal: Vec3, uv: Vec2) Allocator.Error!u32 {
        const at: u32 = @intCast(self.vertices.items.len);
        try self.vertices.append(self.gpa, .{ .position = position.array(), .normal = normal.array(), .uv = .{ uv.x, uv.y } });
        return at;
    }

    fn triangle(self: *Builder, a: u32, b: u32, c: u32) Allocator.Error!void {
        try self.indices.appendSlice(self.gpa, &.{ a, b, c });
    }

    /// Rows of `columns + 1` vertices each, one after another from `first`,
    /// joined into a band of triangles: each row above the next, going
    /// right as its columns go. The first row's pole and the last's are
    /// left out where they are one point.
    fn band(self: *Builder, first: u32, rows: u32, columns: u32, top_is_pole: bool, bottom_is_pole: bool) Allocator.Error!void {
        var row: u32 = 0;
        while (row + 1 < rows) : (row += 1) {
            for (0..columns) |c| {
                const a = first + row * (columns + 1) + @as(u32, @intCast(c));
                const b = a + columns + 1;
                if (!(bottom_is_pole and row + 2 == rows)) try self.triangle(a, b, b + 1);
                if (!(top_is_pole and row == 0)) try self.triangle(a, b + 1, a + 1);
            }
        }
    }

    fn finish(self: *Builder) Allocator.Error!Mesh {
        const vertices = try self.vertices.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(vertices);
        const indices = try self.indices.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(indices);
        computeTangents(vertices, indices);
        return .{ .vertices = vertices, .indices = indices, .surfaces = try whole(self.gpa, indices.len), .bounds = boundsOf(vertices) };
    }
};

/// A box `size` across, around its middle: four corners of its own on each
/// side, each side's picture the whole of it.
pub fn box(gpa: Allocator, size: Vec3) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    const half = abs(size).scale(0.5);
    // Each side's way out, and its right and its up seen from outside.
    const sides = [_][3]Vec3{
        .{ .unit_x, .init(0, 0, -1), .unit_y },
        .{ .init(-1, 0, 0), .unit_z, .unit_y },
        .{ .unit_y, .unit_x, .init(0, 0, -1) },
        .{ .init(0, -1, 0), .unit_x, .unit_z },
        .{ .unit_z, .unit_x, .unit_y },
        .{ .init(0, 0, -1), .init(-1, 0, 0), .unit_y },
    };
    for (sides) |side| try face(&b, side[0], side[1], side[2], along(side[0], half), along(side[1], half), along(side[2], half));
    return b.finish();
}

/// A flat square facing up, `size` across on `x` and deep on `z`: a floor.
pub fn plane(gpa: Allocator, size: Vec2) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    try face(&b, .unit_y, .unit_x, .init(0, 0, -1), 0, @abs(size.x) / 2, @abs(size.y) / 2);
    return b.finish();
}

/// One side of a box: `out` from the middle by `depth`, `width` either way
/// along `right` and `height` along `up`.
fn face(b: *Builder, out: Vec3, right: Vec3, up: Vec3, depth: f32, width: f32, height: f32) Allocator.Error!void {
    const middle = out.scale(depth);
    const corners = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    var at: [4]u32 = undefined;
    for (corners, &at) |corner, *index| {
        const position = middle.add(right.scale(corner[0] * width)).add(up.scale(corner[1] * height));
        index.* = try b.vertex(position, out, .init((corner[0] + 1) / 2, (1 - corner[1]) / 2));
    }
    try b.triangle(at[0], at[1], at[2]);
    try b.triangle(at[0], at[2], at[3]);
}

fn abs(v: Vec3) Vec3 {
    return .init(@abs(v.x), @abs(v.y), @abs(v.z));
}

/// How far `half` reaches along an axis.
fn along(axis: Vec3, half: Vec3) f32 {
    return @abs(axis.x) * half.x + @abs(axis.y) * half.y + @abs(axis.z) * half.z;
}

/// The least and most a shape is cut into, round and from top to bottom.
pub const min_segments = 3;
pub const max_segments = 256;
pub const min_rings = 2;
pub const max_rings = 256;

/// Where a point at `phi` down from the top and `theta` round is, on a
/// sphere of one: the way out from its middle.
fn onSphere(phi: f32, theta: f32) Vec3 {
    const ring = @sin(phi);
    return .init(ring * @sin(theta), @cos(phi), ring * @cos(theta));
}

/// A ball of `radius` round its middle, cut into `segments` round and
/// `rings` from pole to pole.
pub fn sphere(gpa: Allocator, radius: f32, rings: u32, segments: u32) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    const r = @abs(radius);
    const down = std.math.clamp(rings, min_rings, max_rings);
    const round = std.math.clamp(segments, min_segments, max_segments);
    for (0..down + 1) |row| {
        const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(down));
        for (0..round + 1) |column| {
            const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(round));
            const normal = onSphere(v * std.math.pi, u * std.math.tau);
            _ = try b.vertex(normal.scale(r), normal, .init(u, v));
        }
    }
    try b.band(0, down + 1, round, true, true);
    return b.finish();
}

/// An upright tube `height` tall with flat ends, `radius` round.
pub fn cylinder(gpa: Allocator, radius: f32, height: f32, segments: u32) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    const r = @abs(radius);
    const half = @abs(height) / 2;
    const round = std.math.clamp(segments, min_segments, max_segments);
    for ([_]f32{ half, -half }, 0..) |y, row| {
        for (0..round + 1) |column| {
            const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(round));
            const out = onSphere(std.math.pi / 2.0, u * std.math.tau);
            _ = try b.vertex(.init(out.x * r, y, out.z * r), out, .init(u, @floatFromInt(row)));
        }
    }
    try b.band(0, 2, round, false, false);
    try cap(&b, r, half, round, true);
    try cap(&b, r, -half, round, false);
    return b.finish();
}

/// A flat round end at `y`, facing up or down.
fn cap(b: *Builder, radius: f32, y: f32, round: u32, up: bool) Allocator.Error!void {
    const normal: Vec3 = if (up) .unit_y else .init(0, -1, 0);
    const middle = try b.vertex(.init(0, y, 0), normal, .init(0.5, 0.5));
    const first: u32 = @intCast(b.vertices.items.len);
    for (0..round + 1) |column| {
        const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(round));
        const out = onSphere(std.math.pi / 2.0, u * std.math.tau);
        _ = try b.vertex(.init(out.x * radius, y, out.z * radius), normal, .init(0.5 + out.x / 2, 0.5 + if (up) out.z / 2 else -out.z / 2));
    }
    for (0..round) |column| {
        const at = first + @as(u32, @intCast(column));
        if (up) try b.triangle(middle, at, at + 1) else try b.triangle(middle, at + 1, at);
    }
}

/// An upright tube with round ends, `height` tall from end to end - which
/// is at least the two ends - and `radius` round: what a character stands
/// as.
pub fn capsule(gpa: Allocator, radius: f32, height: f32, rings: u32, segments: u32) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    const r = @abs(radius);
    const tube = @max(@abs(height) - 2 * r, 0) / 2;
    const total = 2 * (tube + r);
    const half_rings = @max(std.math.clamp(rings, min_rings, max_rings) / 2, 1);
    const round = std.math.clamp(segments, min_segments, max_segments);
    // The top half's rows down to its middle, then the bottom half's from
    // its middle: the tube is between the two middles.
    for (0..2) |half| {
        const lift: f32 = if (half == 0) tube else -tube;
        for (0..half_rings + 1) |row| {
            const phi = (@as(f32, @floatFromInt(half)) + @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(half_rings))) * std.math.pi / 2.0;
            for (0..round + 1) |column| {
                const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(round));
                const normal = onSphere(phi, u * std.math.tau);
                const position = normal.scale(r).add(.init(0, lift, 0));
                _ = try b.vertex(position, normal, .init(u, if (total > 0) (total / 2 - position.y) / total else 0));
            }
        }
    }
    try b.band(0, 2 * (half_rings + 1), round, true, true);
    return b.finish();
}

// -------------------------------------------------------------------------
// The file
// -------------------------------------------------------------------------

/// What a `.mesh` file starts with, its version in the last two letters.
/// A file of an earlier version - eight numbers a vertex and one surface,
/// or no tangents - is still read, its tangents worked out.
pub const magic = "FXMESH03";
const magic_v1 = "FXMESH01";
const magic_v2 = "FXMESH02";

const header_size = magic.len + 12 + 24;
const header_size_v1 = magic.len + 8 + 24;
const vertex_size_v2 = 8 * 4 + 4;
const vertex_size = vertex_size_v2 + 4 * 4;

/// A mesh as a `.mesh` file's bytes, owned by the caller: `magic`, the
/// counts of vertices, of indices and of surfaces as `u32`s, the bounds'
/// least and most corners as six `f32`s, then each vertex's eight `f32`s,
/// four bytes of colour and its tangent's four `f32`s, each index as a
/// `u32`, and each surface's first index and count as two `u32`s.
/// Little-endian throughout. A surface's material is not written: what
/// reads the file gives it one.
pub fn write(gpa: Allocator, mesh: Mesh) Allocator.Error![]u8 {
    const size = header_size + mesh.vertices.len * vertex_size + mesh.indices.len * 4 + mesh.surfaces.len * 8;
    var out: std.ArrayList(u8) = try .initCapacity(gpa, size);
    errdefer out.deinit(gpa);
    out.appendSliceAssumeCapacity(magic);
    appendInt(&out, @intCast(mesh.vertices.len));
    appendInt(&out, @intCast(mesh.indices.len));
    appendInt(&out, @intCast(mesh.surfaces.len));
    for (mesh.bounds.min.array() ++ mesh.bounds.max.array()) |number| appendInt(&out, @bitCast(number));
    for (mesh.vertices) |v| {
        for (v.position ++ v.normal ++ v.uv) |number| appendInt(&out, @bitCast(number));
        out.appendSliceAssumeCapacity(&v.color);
        for (v.tangent) |number| appendInt(&out, @bitCast(number));
    }
    for (mesh.indices) |index| appendInt(&out, index);
    for (mesh.surfaces) |surface| {
        appendInt(&out, surface.first_index);
        appendInt(&out, surface.index_count);
    }
    return out.toOwnedSlice(gpa);
}

fn appendInt(out: *std.ArrayList(u8), value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    out.appendSliceAssumeCapacity(&bytes);
}

/// A `.mesh` file's bytes as a mesh, the caller's. `error.BadMesh` for one
/// that is not one, is cut short, names a vertex it does not have, or has
/// surfaces that are not its indices.
pub fn read(gpa: Allocator, bytes: []const u8) (Allocator.Error || error{BadMesh})!Mesh {
    if (bytes.len < magic.len) return error.BadMesh;
    const first = std.mem.eql(u8, bytes[0..magic.len], magic_v1);
    const second = std.mem.eql(u8, bytes[0..magic.len], magic_v2);
    if (!first and !second and !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMesh;
    if (bytes.len < if (first) header_size_v1 else header_size) return error.BadMesh;
    var at: usize = magic.len;
    const vertex_count = takeInt(bytes, &at);
    const index_count = takeInt(bytes, &at);
    const surface_count: u32 = if (first) 1 else takeInt(bytes, &at);
    const each: u64 = if (first) 8 * 4 else if (second) vertex_size_v2 else vertex_size;
    const header: u64 = if (first) header_size_v1 else header_size;
    const surfaces_size: u64 = if (first) 0 else @as(u64, surface_count) * 8;
    if (bytes.len != header + @as(u64, vertex_count) * each + @as(u64, index_count) * 4 + surfaces_size) return error.BadMesh;
    at += 24;
    const vertices = try gpa.alloc(Vertex, vertex_count);
    errdefer gpa.free(vertices);
    for (vertices) |*v| {
        var numbers: [8]f32 = undefined;
        for (&numbers) |*number| number.* = @bitCast(takeInt(bytes, &at));
        v.* = .{ .position = numbers[0..3].*, .normal = numbers[3..6].*, .uv = numbers[6..8].* };
        if (!first) {
            v.color = bytes[at..][0..4].*;
            at += 4;
        }
        if (!first and !second) for (&v.tangent) |*number| {
            number.* = @bitCast(takeInt(bytes, &at));
        };
    }
    const indices = try gpa.alloc(u32, index_count);
    errdefer gpa.free(indices);
    for (indices) |*index| index.* = takeInt(bytes, &at);
    const surfaces = if (first) try whole(gpa, index_count) else try gpa.alloc(Surface, surface_count);
    errdefer gpa.free(surfaces);
    if (!first) for (surfaces) |*surface| {
        surface.* = .{ .first_index = takeInt(bytes, &at), .index_count = takeInt(bytes, &at) };
    };
    if (first or second) computeTangents(vertices, indices);
    // Worked out again rather than trusted: a file edited by hand keeps
    // its picking and its culling right.
    return Mesh.adopt(vertices, indices, surfaces);
}

fn takeInt(bytes: []const u8, at: *usize) u32 {
    defer at.* += 4;
    return std.mem.readInt(u32, bytes[at.*..][0..4], .little);
}

// -------------------------------------------------------------------------
// The app's meshes
// -------------------------------------------------------------------------

/// A mesh on the device: what a draw binds.
pub const Gpu = struct {
    vertices: rhi.Buffer,
    indices: rhi.Buffer,
    index_count: u32,

    fn of(device: *rhi.Device, mesh: Mesh, label: []const u8) rhi.Error!Gpu {
        // An empty mesh still has buffers, of one vertex and one triangle
        // that names it, so nothing that draws it needs to ask.
        const no_vertex = [1]Vertex{.{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }};
        const no_index = [3]u32{ 0, 0, 0 };
        const vertices: []const Vertex = if (mesh.vertices.len > 0) mesh.vertices else &no_vertex;
        const indices: []const u32 = if (mesh.indices.len > 0) mesh.indices else &no_index;
        const vertex_buffer = try device.createBuffer(.{
            .kind = .vertex,
            .size = @intCast(vertices.len * @sizeOf(Vertex)),
            .data = std.mem.sliceAsBytes(vertices),
            .label = label,
        });
        errdefer device.destroyBuffer(vertex_buffer);
        const index_buffer = try device.createBuffer(.{
            .kind = .index,
            .size = @intCast(indices.len * 4),
            .data = std.mem.sliceAsBytes(indices),
            .label = label,
        });
        return .{ .vertices = vertex_buffer, .indices = index_buffer, .index_count = @intCast(mesh.indices.len) };
    }

    fn deinit(self: Gpu, device: *rhi.Device) void {
        device.destroyBuffer(self.vertices);
        device.destroyBuffer(self.indices);
    }
};

/// A mesh the app keeps, and its buffers once it has been drawn.
pub const Kept = struct {
    mesh: Mesh,
    gpu: ?Gpu = null,
    /// When it was last drawn, by `Meshes.clock`: a primitive's that has not
    /// been for a while is let go.
    used: u64 = 0,

    fn deinit(self: *Kept, gpa: Allocator, device: *rhi.Device) void {
        if (self.gpu) |gpu| gpu.deinit(device);
        self.mesh.deinit(gpa);
    }

    /// Its buffers, made the first time they are asked for.
    pub fn uploaded(self: *Kept, device: *rhi.Device) rhi.Error!Gpu {
        if (self.gpu) |gpu| return gpu;
        self.gpu = try .of(device, self.mesh, "mesh");
        return self.gpu.?;
    }
};

/// Every mesh read or made, under its handle, and the meshes primitives'
/// numbers came to.
pub const Meshes = struct {
    table: Inner = .empty,
    primitives: std.AutoHashMapUnmanaged(PrimitiveKey, Kept) = .empty,
    /// Counts up each frame drawn: see `Kept.used`.
    clock: u64 = 0,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        /// The path or name it was read by: `res://` for a file of the project's.
        source: []u8,
        on_disc: bool,
        kept: Kept,
    };

    /// How many frames a primitive's mesh is kept after it was last drawn.
    pub const primitive_frames = 120;

    fn toId(handle: MeshHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) MeshHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *Meshes, gpa: Allocator, device: *rhi.Device) void {
        var it = self.table.iterator();
        while (it.next()) |entry| free(gpa, device, entry.value);
        self.table.deinit(gpa);
        var shapes = self.primitives.valueIterator();
        while (shapes.next()) |kept| kept.deinit(gpa, device);
        self.primitives.deinit(gpa);
        self.* = .{};
    }

    fn free(gpa: Allocator, device: *rhi.Device, entry: *Entry) void {
        gpa.free(entry.source);
        entry.kept.deinit(gpa, device);
    }

    /// Keep `mesh`, which is the table's from here, under `name`: a name
    /// given before gets the new mesh, and keeps its handle.
    pub fn add(self: *Meshes, gpa: Allocator, device: *rhi.Device, name: []const u8, mesh: Mesh) Allocator.Error!MeshHandle {
        return self.keep(gpa, device, name, mesh, false);
    }

    fn keep(self: *Meshes, gpa: Allocator, device: *rhi.Device, name: []const u8, mesh: Mesh, on_disc: bool) Allocator.Error!MeshHandle {
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.kept.deinit(gpa, device);
            held.kept = .{ .mesh = mesh };
            held.on_disc = on_disc;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .kept = .{ .mesh = mesh } }));
    }

    /// The mesh in the `.mesh` file at `path`, read now unless it was read
    /// before.
    pub fn load(self: *Meshes, app: *App, path: []const u8) !MeshHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        var mesh = try readFile(app, source);
        errdefer mesh.deinit(app.gpa);
        return self.keep(app.gpa, &app.device, source, mesh, true);
    }

    fn readFile(app: *App, source: []const u8) !Mesh {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return read(app.gpa, bytes);
    }

    /// Read a mesh's file again. Says whether it had one.
    pub fn reload(self: *Meshes, app: *App, handle: MeshHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const mesh = try readFile(app, held.source);
        held.kept.deinit(app.gpa, &app.device);
        held.kept = .{ .mesh = mesh };
        return true;
    }

    /// Let a mesh go. Its handle names nothing from here.
    pub fn unload(self: *Meshes, gpa: Allocator, device: *rhi.Device, handle: MeshHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        free(gpa, device, held);
        _ = self.table.remove(toId(handle));
    }

    pub fn find(self: *Meshes, source: []const u8) ?MeshHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *Meshes, handle: MeshHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn get(self: *Meshes, handle: MeshHandle) ?*const Mesh {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.kept.mesh;
    }

    /// The mesh and its buffers, for a draw.
    pub fn keptOf(self: *Meshes, handle: MeshHandle) ?*Kept {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.kept;
    }

    /// The mesh a primitive's numbers come to, made the first time they
    /// are asked for.
    pub fn primitive(self: *Meshes, gpa: Allocator, shape: Primitive) Allocator.Error!*Kept {
        const key = shape.key();
        const found = try self.primitives.getOrPut(gpa, key);
        if (!found.found_existing) {
            const mesh = shape.build(gpa) catch |err| {
                self.primitives.removeByPtr(found.key_ptr);
                return err;
            };
            found.value_ptr.* = .{ .mesh = mesh };
        }
        return found.value_ptr;
    }

    /// One more frame: a primitive's mesh not drawn for `primitive_frames`
    /// is let go - one whose numbers a tween changes each frame would
    /// otherwise keep every size it passed through.
    pub fn tick(self: *Meshes, gpa: Allocator, device: *rhi.Device) void {
        self.clock += 1;
        if (self.clock % 30 != 0) return;
        var stale: std.ArrayList(PrimitiveKey) = .empty;
        defer stale.deinit(gpa);
        var it = self.primitives.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.used + primitive_frames < self.clock) stale.append(gpa, entry.key_ptr.*) catch break;
        }
        for (stale.items) |key| {
            var gone = self.primitives.fetchRemove(key).?;
            gone.value.deinit(gpa, device);
        }
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Meshes, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};

/// A shape made from numbers: what a `PrimitiveMesh3D` says.
pub const Primitive = struct {
    shape: Shape,
    size: Vec3 = .one,
    radius: f32 = 0.5,
    height: f32 = 2,
    rings: u32 = 16,
    segments: u32 = 32,

    pub const Shape = enum(u8) { box, sphere, plane, cylinder, capsule };

    pub fn build(self: Primitive, gpa: Allocator) Allocator.Error!Mesh {
        return switch (self.shape) {
            .box => box(gpa, self.size),
            .plane => plane(gpa, .init(self.size.x, self.size.z)),
            .sphere => sphere(gpa, self.radius, self.rings, self.segments),
            .cylinder => cylinder(gpa, self.radius, self.height, self.segments),
            .capsule => capsule(gpa, self.radius, self.height, self.rings, self.segments),
        };
    }

    /// The numbers that make its mesh, and only those: a sphere's size
    /// changes nothing of it.
    fn key(self: Primitive) PrimitiveKey {
        var out: PrimitiveKey = .{ .shape = self.shape };
        switch (self.shape) {
            .box => out.numbers = .{ @bitCast(self.size.x), @bitCast(self.size.y), @bitCast(self.size.z), 0, 0 },
            .plane => out.numbers = .{ @bitCast(self.size.x), @bitCast(self.size.z), 0, 0, 0 },
            .sphere => out.numbers = .{ @bitCast(self.radius), self.rings, self.segments, 0, 0 },
            .cylinder => out.numbers = .{ @bitCast(self.radius), @bitCast(self.height), self.segments, 0, 0 },
            .capsule => out.numbers = .{ @bitCast(self.radius), @bitCast(self.height), self.rings, self.segments, 0 },
        }
        return out;
    }
};

const PrimitiveKey = struct {
    shape: Primitive.Shape,
    numbers: [5]u32 = @splat(0),
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Every triangle faces the way its corners' normals do: outward, on a
/// closed shape.
fn expectFacingOut(mesh: Mesh) !void {
    var at: usize = 0;
    while (at < mesh.indices.len) : (at += 3) {
        const v = [3]Vertex{ mesh.vertices[mesh.indices[at]], mesh.vertices[mesh.indices[at + 1]], mesh.vertices[mesh.indices[at + 2]] };
        const a = Vec3.fromArray(v[0].position);
        const b = Vec3.fromArray(v[1].position);
        const c = Vec3.fromArray(v[2].position);
        const facing = b.sub(a).cross(c.sub(a));
        const said = Vec3.fromArray(v[0].normal).add(.fromArray(v[1].normal)).add(.fromArray(v[2].normal));
        try testing.expect(facing.lenSq() > 0);
        try testing.expect(facing.dot(said) > 0);
    }
}

test "a box is six sides of four corners each, facing out, as big as it was asked" {
    var mesh = try box(testing.allocator, .init(2, 1, 4));
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 24), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 12), mesh.triangleCount());
    try testing.expect(mesh.bounds.approxEql(.init(.init(-1, -0.5, -2), .init(1, 0.5, 2))));
    try expectFacingOut(mesh);
}

test "a plane faces up, and a sphere, a cylinder and a capsule face out, as big as they were asked" {
    var floor = try plane(testing.allocator, .init(4, 2));
    defer floor.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), floor.triangleCount());
    try testing.expect(floor.bounds.approxEql(.init(.init(-2, 0, -1), .init(2, 0, 1))));
    try expectFacingOut(floor);

    var ball = try sphere(testing.allocator, 2, 8, 12);
    defer ball.deinit(testing.allocator);
    for (ball.vertices) |v| try testing.expectApproxEqAbs(@as(f32, 2), Vec3.fromArray(v.position).len(), 1e-4);
    // Two poles of one triangle per column, and two a column between.
    try testing.expectEqual(@as(usize, 12 * 2 + 12 * 6 * 2), ball.triangleCount());
    try expectFacingOut(ball);

    var tube = try cylinder(testing.allocator, 0.5, 3, 16);
    defer tube.deinit(testing.allocator);
    try testing.expect(tube.bounds.approxEql(.init(.init(-0.5, -1.5, -0.5), .init(0.5, 1.5, 0.5))));
    try expectFacingOut(tube);

    var pill = try capsule(testing.allocator, 0.5, 2, 8, 16);
    defer pill.deinit(testing.allocator);
    try testing.expect(pill.bounds.approxEql(.init(.init(-0.5, -1, -0.5), .init(0.5, 1, 0.5))));
    try expectFacingOut(pill);

    // Too few cuts are as few as make a shape.
    var least = try sphere(testing.allocator, 1, 0, 0);
    defer least.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, (min_rings + 1) * (min_segments + 1)), least.vertices.len);
}

test "a mesh's file reads back as it was written, and one that is not whole is refused" {
    var mesh = try box(testing.allocator, .init(1, 2, 3));
    defer mesh.deinit(testing.allocator);
    const bytes = try write(testing.allocator, mesh);
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, mesh.indices, back.indices);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(mesh.vertices), std.mem.sliceAsBytes(back.vertices));
    try testing.expect(mesh.bounds.approxEql(back.bounds));
    try testing.expectEqual(@as(usize, 1), back.surfaces.len);
    try testing.expectEqual(@as(u32, 36), back.surfaces[0].index_count);

    try testing.expectError(error.BadMesh, read(testing.allocator, bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.BadMesh, read(testing.allocator, "FXMESH99"));
    // A surface that is not the indices.
    const broken = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(broken);
    std.mem.writeInt(u32, broken[broken.len - 4 ..][0..4], 99, .little);
    try testing.expectError(error.BadMesh, read(testing.allocator, broken));
}

test "a mesh's file of the first version still reads, as one white surface" {
    // One triangle: eight numbers a vertex and no surfaces.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "FXMESH01");
    const ints = [_]u32{ 3, 3 };
    for (ints) |n| try bytes.appendSlice(testing.allocator, std.mem.asBytes(&n));
    const numbers = [_]f32{ 0, 0, 0, 1, 1, 0 } ++ [_]f32{ 0, 0, 0, 0, 0, 1, 0, 0 } ++ [_]f32{ 1, 0, 0, 0, 0, 1, 1, 0 } ++ [_]f32{ 0, 1, 0, 0, 0, 1, 0, 1 };
    for (numbers) |n| try bytes.appendSlice(testing.allocator, std.mem.asBytes(&n));
    const indices = [_]u32{ 0, 1, 2 };
    for (indices) |n| try bytes.appendSlice(testing.allocator, std.mem.asBytes(&n));
    var mesh = try read(testing.allocator, bytes.items);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, mesh.vertices[1].color);
    try testing.expectEqual(@as(u32, 3), mesh.surfaces[0].index_count);
}

test "a tangent runs along the pictures' first coordinate, square to the normal" {
    // u runs up the triangle, v to the left: the tangent is up, and the
    // bitangent the way the normal and the tangent say.
    var tri = [_]Vertex{
        .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0, 0 } },
        .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 1, 0 } },
        .{ .position = .{ -1, 0, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0, 1 } },
    };
    computeTangents(&tri, &.{ 0, 1, 2 });
    for (tri) |v| try testing.expectEqual([4]f32{ 0, 1, 0, 1 }, v.tangent);
    // Mirrored pictures turn the bitangent round.
    tri[2].uv = .{ 0, -1 };
    computeTangents(&tri, &.{ 0, 1, 2 });
    try testing.expectEqual(@as(f32, -1), tri[0].tangent[3]);

    // Every shape's are whole, and square to its normals.
    for ([_]Primitive.Shape{ .box, .plane, .sphere, .cylinder, .capsule }) |shape| {
        var made = try (Primitive{ .shape = shape }).build(testing.allocator);
        defer made.deinit(testing.allocator);
        for (made.vertices) |v| {
            const t: Vec3 = .init(v.tangent[0], v.tangent[1], v.tangent[2]);
            const n: Vec3 = .init(v.normal[0], v.normal[1], v.normal[2]);
            try testing.expectApproxEqAbs(@as(f32, 1), t.len(), 1e-3);
            try testing.expectApproxEqAbs(@as(f32, 0), t.dot(n), 1e-3);
            try testing.expectEqual(@as(f32, 1), @abs(v.tangent[3]));
        }
    }
}

test "a ray meets a mesh's nearest triangle" {
    var mesh = try box(testing.allocator, .init(2, 2, 2));
    defer mesh.deinit(testing.allocator);
    const t = mesh.intersectRay(.init(.init(0, 0, 5), .init(0, 0, -1))).?;
    try testing.expectApproxEqAbs(@as(f32, 4), t, 1e-5);
    try testing.expect(mesh.intersectRay(.init(.init(3, 0, 5), .init(0, 0, -1))) == null);
}

test "a primitive's mesh is made once for its numbers, and let go once it is not drawn" {
    var meshes: Meshes = .{};
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    defer meshes.deinit(testing.allocator, &device);

    const ball: Primitive = .{ .shape = .sphere, .radius = 1 };
    const first = try meshes.primitive(testing.allocator, ball);
    var bigger = ball;
    bigger.size = .init(9, 9, 9);
    try testing.expectEqual(first, try meshes.primitive(testing.allocator, bigger));
    bigger.radius = 2;
    _ = try meshes.primitive(testing.allocator, bigger);
    try testing.expectEqual(@as(usize, 2), meshes.primitives.count());

    // One drawn each frame stays; the other goes.
    for (0..Meshes.primitive_frames + 60) |_| {
        (try meshes.primitive(testing.allocator, ball)).used = meshes.clock;
        meshes.tick(testing.allocator, &device);
    }
    try testing.expectEqual(@as(usize, 1), meshes.primitives.count());
}
