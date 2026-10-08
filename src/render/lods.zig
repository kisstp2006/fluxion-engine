// SPDX-License-Identifier: BSD-3-Clause

//! Levels of detail: a dense mesh's coarser levels, each of fewer
//! triangles over the mesh's own vertices, drawn in its place as it gets
//! further off - the coarsest one whose difference from the whole would
//! cover no more than `Rendering.lod_threshold` pixels.
//!
//! A level is made by `fluxion_simplify` from the one before, surface by
//! surface, half as many triangles each time, until one would be too small
//! or would change the shape too much. A model's levels are made once, by
//! an editor as it brings the model in, and kept in a file of their own
//! beside what it made of it - `.fluxion/imported/<model>.lods` - which an
//! export takes along; where there is none, or one made of another version
//! of the mesh, the levels are made as the model is read.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const simplify = @import("fluxion_simplify");

const mesh = @import("mesh.zig");
const Mesh = mesh.Mesh;
const Lod = mesh.Lod;
const Surface = mesh.Surface;
const Vertex = mesh.Vertex;

/// A mesh of fewer triangles than this has no levels: it costs little
/// enough as it is.
pub const min_triangles = 2048;
/// A level of fewer than this is not made.
pub const least_triangles = 256;
/// The most levels a mesh has.
pub const max_levels = mesh.max_lods;
/// How far a level may move a corner from the level before, as a share of
/// the mesh's size, at most.
pub const step_error = 0.05;

/// The levels of the mesh `vertices`, `indices` and `surfaces` are, the
/// caller's. None for one of fewer than `min_triangles`.
pub fn make(gpa: Allocator, vertices: []const Vertex, indices: []const u32, surfaces: []const Surface) Allocator.Error![]Lod {
    if (indices.len / 3 < min_triangles) return &.{};
    const positions = try gpa.alloc([3]f32, vertices.len);
    defer gpa.free(positions);
    for (vertices, positions) |v, *p| p.* = v.position;
    var extent: f32 = 0;
    if (vertices.len > 0) {
        var low = positions[0];
        var high = positions[0];
        for (positions) |p| for (0..3) |k| {
            low[k] = @min(low[k], p[k]);
            high[k] = @max(high[k], p[k]);
        };
        for (0..3) |k| extent = @max(extent, high[k] - low[k]);
    }

    var levels: std.ArrayList(Lod) = .empty;
    errdefer {
        for (levels.items) |*level| level.deinit(gpa);
        levels.deinit(gpa);
    }
    // Each level from the one before.
    var from_indices: []const u32 = indices;
    var from_surfaces: []const Surface = surfaces;
    var distance: f32 = 0;
    while (levels.items.len < max_levels) {
        var made_indices: std.ArrayList(u32) = .empty;
        errdefer made_indices.deinit(gpa);
        const made_surfaces = try gpa.alloc(Surface, from_surfaces.len);
        errdefer gpa.free(made_surfaces);
        var worst: f32 = 0;
        for (from_surfaces, made_surfaces) |surface, *out| {
            const part = from_indices[surface.first_index..][0..surface.index_count];
            const fewer = try simplify.simplify(gpa, part, positions, .{ .target_index_count = part.len / 2, .target_error = step_error });
            defer gpa.free(fewer.indices);
            out.* = .{ .first_index = @intCast(made_indices.items.len), .index_count = @intCast(fewer.indices.len), .material = surface.material };
            try made_indices.appendSlice(gpa, fewer.indices);
            worst = @max(worst, fewer.error_share);
        }
        const before = from_indices.len;
        const after = made_indices.items.len;
        // Too few left, or too few taken away to be worth a level.
        if (after / 3 < least_triangles or after * 5 > before * 4) {
            made_indices.deinit(gpa);
            gpa.free(made_surfaces);
            break;
        }
        distance += worst * extent;
        try levels.append(gpa, .{ .indices = try made_indices.toOwnedSlice(gpa), .surfaces = made_surfaces, .distance = distance });
        const last = levels.items[levels.items.len - 1];
        from_indices = last.indices;
        from_surfaces = last.surfaces;
    }
    return levels.toOwnedSlice(gpa);
}

/// What a mesh is, for knowing whether levels kept for it are still its:
/// its vertices' places and its indices, hashed.
pub fn hashOf(vertices: []const Vertex, indices: []const u32) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (vertices) |v| hasher.update(std.mem.asBytes(&v.position));
    hasher.update(std.mem.sliceAsBytes(indices));
    return hasher.final();
}

// -------------------------------------------------------------------------
// The file

/// What a file of a model's levels starts with.
pub const magic = "FXLODS01";

/// One mesh's levels, as a file keeps them: by the mesh's place in its
/// model, and its hash.
pub const Entry = struct {
    hash: u64,
    levels: []const Lod,
};

/// A file of `entries`, one a mesh of the model in their order: `magic`,
/// how many meshes, and for each its hash, how many levels, and for each
/// level its distance, its surfaces' first indices and counts, and its
/// indices. Little-endian; the caller's.
pub fn write(gpa: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try int(gpa, &out, u32, @intCast(entries.len));
    for (entries) |entry| {
        try int(gpa, &out, u64, entry.hash);
        try int(gpa, &out, u32, @intCast(entry.levels.len));
        for (entry.levels) |level| {
            try int(gpa, &out, u32, @bitCast(level.distance));
            try int(gpa, &out, u32, @intCast(level.surfaces.len));
            for (level.surfaces) |surface| {
                try int(gpa, &out, u32, surface.first_index);
                try int(gpa, &out, u32, surface.index_count);
            }
            try int(gpa, &out, u32, @intCast(level.indices.len));
            for (level.indices) |index| try int(gpa, &out, u32, index);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn int(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

/// The levels a file keeps for the mesh at `at` of its model, if it keeps
/// them for a mesh of `hash` - with the materials of `surfaces`, the
/// mesh's own - and they name no vertex past `vertex_count`; null
/// otherwise. The caller's.
pub fn read(gpa: Allocator, bytes: []const u8, at: usize, hash: u64, surfaces: []const Surface, vertex_count: usize) Allocator.Error!?[]Lod {
    return readOrRefuse(gpa, bytes, at, hash, surfaces, vertex_count) catch |err| switch (err) {
        error.Refused => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn readOrRefuse(gpa: Allocator, bytes: []const u8, at: usize, hash: u64, surfaces: []const Surface, vertex_count: usize) (Allocator.Error || error{Refused})![]Lod {
    var reader: Reader = .{ .bytes = bytes };
    if (!std.mem.startsWith(u8, bytes, magic)) return error.Refused;
    reader.at = magic.len;
    const count = try reader.take(u32);
    var mesh_at: usize = 0;
    while (mesh_at < count) : (mesh_at += 1) {
        const its_hash = try reader.take(u64);
        const level_count = try reader.take(u32);
        if (mesh_at != at) {
            // Passed over: each level's surfaces and indices.
            for (0..level_count) |_| {
                _ = try reader.take(u32);
                const surface_count = try reader.take(u32);
                try reader.skip(@as(usize, surface_count) * 8);
                const index_count = try reader.take(u32);
                try reader.skip(@as(usize, index_count) * 4);
            }
            continue;
        }
        if (its_hash != hash or level_count > max_levels) return error.Refused;
        var levels: std.ArrayList(Lod) = .empty;
        errdefer {
            for (levels.items) |*level| level.deinit(gpa);
            levels.deinit(gpa);
        }
        for (0..level_count) |_| {
            const distance: f32 = @bitCast(try reader.take(u32));
            const surface_count = try reader.take(u32);
            if (surface_count != surfaces.len) return error.Refused;
            const level_surfaces = try gpa.alloc(Surface, surface_count);
            errdefer gpa.free(level_surfaces);
            for (level_surfaces, surfaces) |*out, own| {
                out.* = .{ .first_index = try reader.take(u32), .index_count = try reader.take(u32), .material = own.material };
            }
            const index_count = try reader.take(u32);
            if (index_count % 3 != 0 or reader.left() < @as(usize, index_count) * 4) return error.Refused;
            const indices = try gpa.alloc(u32, index_count);
            errdefer gpa.free(indices);
            for (indices) |*index| {
                index.* = try reader.take(u32);
                if (index.* >= vertex_count) return error.Refused;
            }
            for (level_surfaces) |surface| {
                if (@as(u64, surface.first_index) + surface.index_count > index_count) return error.Refused;
            }
            try levels.append(gpa, .{ .indices = indices, .surfaces = level_surfaces, .distance = distance });
        }
        return levels.toOwnedSlice(gpa);
    }
    return error.Refused;
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, comptime T: type) error{Refused}!T {
        if (self.left() < @sizeOf(T)) return error.Refused;
        defer self.at += @sizeOf(T);
        return std.mem.readInt(T, self.bytes[self.at..][0..@sizeOf(T)], .little);
    }

    fn skip(self: *Reader, n: usize) error{Refused}!void {
        if (self.left() < n) return error.Refused;
        self.at += n;
    }

    fn left(self: *const Reader) usize {
        return self.bytes.len - self.at;
    }
};

// -------------------------------------------------------------------------
// Tests

/// A bumpy ball of `slices` round and `stacks` down, its vertices split
/// along one meridian as a picture's seam splits them.
fn ballMesh(gpa: Allocator, slices: u32, stacks: u32) !struct { vertices: []Vertex, indices: []u32 } {
    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(gpa);
    for (0..stacks + 1) |j| {
        const phi = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(stacks)) * std.math.pi;
        for (0..slices + 1) |i| {
            const theta = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(slices)) * std.math.tau;
            const r = 1 + 0.05 * @sin(theta * 5) * @sin(phi * 4);
            const p: [3]f32 = .{ r * @cos(theta) * @sin(phi), r * @cos(phi), -r * @sin(theta) * @sin(phi) };
            try vertices.append(gpa, .{ .position = p, .normal = p });
        }
    }
    const row = slices + 1;
    for (0..stacks) |j| for (0..slices) |i| {
        const a: u32 = @intCast(j * row + i);
        const b = a + row;
        try indices.appendSlice(gpa, &.{ a, b, b + 1, a, b + 1, a + 1 });
    };
    return .{ .vertices = try vertices.toOwnedSlice(gpa), .indices = try indices.toOwnedSlice(gpa) };
}

test "a dense mesh gets coarser levels, each about half the one before, further from it as they go; a small one none" {
    const gpa = testing.allocator;
    const ball = try ballMesh(gpa, 96, 48);
    defer gpa.free(ball.vertices);
    defer gpa.free(ball.indices);
    const surfaces = [_]Surface{.{ .first_index = 0, .index_count = @intCast(ball.indices.len) }};
    const levels = try make(gpa, ball.vertices, ball.indices, &surfaces);
    defer {
        for (levels) |*level| level.deinit(gpa);
        gpa.free(levels);
    }
    try testing.expect(levels.len >= 3);
    var before = ball.indices.len;
    var distance: f32 = 0;
    // The first about half; each after it at least a fifth fewer.
    try testing.expect(levels[0].indices.len * 10 <= ball.indices.len * 6);
    for (levels) |level| {
        try testing.expect(level.indices.len * 5 <= before * 4);
        try testing.expect(level.distance >= distance);
        try testing.expectEqual(@as(usize, level.indices.len), level.surfaces[0].index_count);
        before = level.indices.len;
        distance = level.distance;
    }
    // Small: none.
    const small = try make(gpa, ball.vertices, ball.indices[0..300], &.{.{ .first_index = 0, .index_count = 300 }});
    try testing.expectEqual(@as(usize, 0), small.len);
}

test "levels kept in a file are read back for the mesh they were made for, and not for another" {
    const gpa = testing.allocator;
    const ball = try ballMesh(gpa, 96, 48);
    defer gpa.free(ball.vertices);
    defer gpa.free(ball.indices);
    const surfaces = [_]Surface{.{ .first_index = 0, .index_count = @intCast(ball.indices.len) }};
    const levels = try make(gpa, ball.vertices, ball.indices, &surfaces);
    defer {
        for (levels) |*level| level.deinit(gpa);
        gpa.free(levels);
    }
    const hash = hashOf(ball.vertices, ball.indices);
    const bytes = try write(gpa, &.{ .{ .hash = 7, .levels = levels[0..1] }, .{ .hash = hash, .levels = levels } });
    defer gpa.free(bytes);
    const back = (try read(gpa, bytes, 1, hash, &surfaces, ball.vertices.len)).?;
    defer {
        for (back) |*level| level.deinit(gpa);
        gpa.free(back);
    }
    try testing.expectEqual(levels.len, back.len);
    try testing.expectEqualSlices(u32, levels[0].indices, back[0].indices);
    try testing.expectEqual(levels[1].distance, back[1].distance);
    // Another mesh, or another place, or a file cut short: nothing.
    try testing.expect(try read(gpa, bytes, 1, hash +% 1, &surfaces, ball.vertices.len) == null);
    try testing.expect(try read(gpa, bytes, 3, hash, &surfaces, ball.vertices.len) == null);
    try testing.expect(try read(gpa, bytes[0 .. bytes.len - 3], 1, hash, &surfaces, ball.vertices.len) == null);
}
