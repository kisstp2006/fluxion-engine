// SPDX-License-Identifier: BSD-3-Clause

//! From triangles to a navigation mesh: the solid in columns, what can be
//! stood on kept, worn back from the walls by the agent's radius, cut into
//! regions, outlined, and the outlines made polygons.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const Heightfield = @import("Heightfield.zig");
const Compact = @import("Compact.zig");
const contours = @import("contours.zig");
const polymesh = @import("polymesh.zig");
const NavMesh = @import("NavMesh.zig");

pub const Settings = struct {
    /// A cell's side on the ground, and its step up: smaller is truer and
    /// slower.
    cell_size: f32 = 0.25,
    cell_height: f32 = 0.25,
    /// The agent: how tall, how wide from its middle, how high a step it
    /// climbs, and the steepest slope it walks up, in radians.
    agent_height: f32 = 1.5,
    agent_radius: f32 = 0.5,
    agent_max_climb: f32 = 0.25,
    agent_max_slope: f32 = std.math.degreesToRadians(45.0),
    /// Pieces of floor smaller than this, in square metres, are left out.
    min_region_area: f32 = 1,
    /// How far an edge along a wall may stray from the cells, in cells,
    /// and how long it may be, in metres - nought for any length.
    edge_max_error: f32 = 1.3,
    edge_max_length: f32 = 12,
};

pub const Input = struct {
    vertices: []const Vec3,
    /// Wound counter-clockwise seen from outside: what faces up is floor.
    triangles: []const [3]u32,
    /// Runs of `triangles` - first and how many - that each close a convex
    /// solid: a box, a ball, a hull. Filled to the top, so there is no
    /// floor inside them, as there would be inside a box standing on the
    /// floor if only its faces were laid down. The rest are surfaces.
    solids: []const [2]u32 = &.{},
};

pub const Error = Allocator.Error || error{TooManyRegions};

/// What a bake found besides the mesh.
pub const Report = struct {
    /// Outlines that could not be cut into triangles whole: some floor
    /// left out.
    bad_outlines: usize = 0,
};

pub fn bake(gpa: Allocator, input: Input, settings: Settings, report: ?*Report) Error!NavMesh {
    const agent: NavMesh.Agent = .{
        .height = settings.agent_height,
        .radius = settings.agent_radius,
        .max_climb = settings.agent_max_climb,
        .max_slope = settings.agent_max_slope,
    };
    if (input.triangles.len == 0 or input.vertices.len == 0) return empty(gpa, agent);
    var min = input.vertices[0];
    var max = min;
    for (input.vertices[1..]) |v| {
        min = @min(min, v);
        max = @max(max, v);
    }
    const cs = @max(settings.cell_size, 0.01);
    const ch = @max(settings.cell_height, 0.01);
    // Room above the highest floor for the agent to stand.
    max[1] += settings.agent_height + ch;

    const height: i32 = @intFromFloat(@ceil(settings.agent_height / ch));
    const climb: i32 = @intFromFloat(@floor(settings.agent_max_climb / ch));
    // Walking across a cell of a slope no steeper than the agent walks, the
    // floor rises as much as this: a step between neighbours, however
    // little the agent climbs, or a slope is cut up by its own rounding.
    const rise: i32 = @intFromFloat(@ceil(cs * @tan(std.math.clamp(settings.agent_max_slope, 0, 1.4)) / ch));
    const reach = @max(climb, rise);
    const radius: i32 = @intFromFloat(@ceil(settings.agent_radius / cs));

    var hf = try Heightfield.init(gpa, min, max, cs, ch);
    defer hf.deinit(gpa);
    var in_solid = try std.DynamicBitSetUnmanaged.initEmpty(gpa, input.triangles.len);
    defer in_solid.deinit(gpa);
    for (input.solids) |run| {
        const first = @min(run[0], input.triangles.len);
        const end = @min(first + run[1], input.triangles.len);
        in_solid.setRangeValue(.{ .start = first, .end = end }, true);
        try hf.rasterizeSolid(gpa, input.vertices, input.triangles[first..end], settings.agent_max_slope, climb);
    }
    for (input.triangles, 0..) |t, i| {
        if (in_solid.isSet(i)) continue;
        const a = input.vertices[t[0]];
        const b = input.vertices[t[1]];
        const c = input.vertices[t[2]];
        const area = if (Heightfield.walkable(a, b, c, settings.agent_max_slope)) Heightfield.walkable_area else Heightfield.null_area;
        try hf.rasterize(gpa, a, b, c, area, climb);
    }
    hf.filterLowObstacles(climb);
    try hf.filterLedges(gpa, height, reach, @max(climb, 2 * rise));
    hf.filterLowCeilings(height);

    var chf = try Compact.init(gpa, &hf, height, reach);
    defer chf.deinit(gpa);
    try chf.erode(gpa, radius);
    const min_cells: usize = @intFromFloat(@max(0, @ceil(settings.min_region_area / (cs * cs))));
    try chf.buildRegions(gpa, min_cells);

    var outlines = try contours.build(gpa, &chf, settings.edge_max_error, @intFromFloat(@ceil(settings.edge_max_length / cs)));
    defer outlines.deinit(gpa);
    var mesh = try polymesh.build(gpa, &outlines);
    defer mesh.deinit(gpa);
    if (report) |r| r.bad_outlines = mesh.bad_outlines;

    const vertices = try gpa.alloc(Vec3, mesh.vertices.items.len);
    errdefer gpa.free(vertices);
    for (mesh.vertices.items, vertices) |v, *w| {
        w.* = .{
            min[0] + @as(f32, @floatFromInt(v.x)) * cs,
            min[1] + @as(f32, @floatFromInt(v.y)) * ch,
            min[2] + @as(f32, @floatFromInt(v.z)) * cs,
        };
    }
    const polygons = try gpa.alloc(NavMesh.Polygon, mesh.polygons.items.len);
    errdefer gpa.free(polygons);
    for (mesh.polygons.items, polygons) |p, *q| {
        q.* = .{ .vertices = p.vertices, .neighbours = p.neighbours, .count = @intCast(p.count()), .area = p.area };
    }
    return NavMesh.init(gpa, vertices, polygons, agent);
}

fn empty(gpa: Allocator, agent: NavMesh.Agent) Allocator.Error!NavMesh {
    return NavMesh.init(gpa, &.{}, &.{}, agent);
}

// -------------------------------------------------------------------------
// Tests: worlds made of boxes
// -------------------------------------------------------------------------

const World = struct {
    vertices: std.ArrayList(Vec3) = .empty,
    triangles: std.ArrayList([3]u32) = .empty,
    solids: std.ArrayList([2]u32) = .empty,

    fn deinit(self: *World) void {
        self.vertices.deinit(testing.allocator);
        self.triangles.deinit(testing.allocator);
        self.solids.deinit(testing.allocator);
    }

    fn input(self: *const World) Input {
        return .{ .vertices = self.vertices.items, .triangles = self.triangles.items, .solids = self.solids.items };
    }

    /// A box between two corners, its faces wound outwards.
    fn box(self: *World, lo: Vec3, hi: Vec3) !void {
        try self.turnedBox(lo, hi, 0);
    }

    /// The same turned by `angle` about z through its middle.
    fn turnedBox(self: *World, lo: Vec3, hi: Vec3, angle: f32) !void {
        const gpa = testing.allocator;
        const base: u32 = @intCast(self.vertices.items.len);
        const mid = (lo + hi) * @as(Vec3, @splat(0.5));
        for (0..8) |i| {
            var p: Vec3 = .{
                if (i & 1 != 0) hi[0] else lo[0],
                if (i & 2 != 0) hi[1] else lo[1],
                if (i & 4 != 0) hi[2] else lo[2],
            };
            const d = p - mid;
            p = mid + Vec3{ d[0] * @cos(angle) - d[1] * @sin(angle), d[0] * @sin(angle) + d[1] * @cos(angle), d[2] };
            try self.vertices.append(gpa, p);
        }
        // Corners: bit 0 x, bit 1 y, bit 2 z. Each face outwards.
        const faces = [6][4]u32{
            .{ 2, 6, 7, 3 }, // +y
            .{ 0, 1, 5, 4 }, // -y
            .{ 1, 3, 7, 5 }, // +x
            .{ 0, 4, 6, 2 }, // -x
            .{ 4, 5, 7, 6 }, // +z
            .{ 0, 2, 3, 1 }, // -z
        };
        const first: u32 = @intCast(self.triangles.items.len);
        for (faces) |f| {
            try self.triangles.append(gpa, .{ base + f[0], base + f[1], base + f[2] });
            try self.triangles.append(gpa, .{ base + f[0], base + f[2], base + f[3] });
        }
        try self.solids.append(gpa, .{ first, 12 });
    }
};

fn polygonArea(mesh: *const NavMesh) f32 {
    var total: f32 = 0;
    for (mesh.polygons, 0..) |p, i| {
        const a = mesh.corner(@intCast(i), 0);
        for (1..p.count - 1) |k| total += @abs(vec.area2d(a, mesh.corner(@intCast(i), k), mesh.corner(@intCast(i), k + 1))) / 2;
    }
    return total;
}

test "a box's top is floor and its faces are wound outwards" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const v = world.vertices.items;
    const top = world.triangles.items[0];
    try testing.expect(Heightfield.walkable(v[top[0]], v[top[1]], v[top[2]], 0.5));
    const bottom = world.triangles.items[2];
    try testing.expect(!Heightfield.walkable(v[bottom[0]], v[bottom[1]], v[bottom[2]], 0.5));
}

test "an open floor is one piece, worn back from its edges by the agent's radius" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ -5, -0.5, -5 }, .{ 5, 0, 5 });
    var mesh = try bake(testing.allocator, world.input(), .{}, null);
    defer mesh.deinit(testing.allocator);
    try testing.expect(mesh.polygons.len >= 1);
    try testing.expectEqual(mesh.polygons.len, try mesh.connectedFrom(testing.allocator, 0));
    // Nine by nine, more or less: half a metre in from each side, and the
    // cells at the very edge not stood on.
    const area = polygonArea(&mesh);
    try testing.expect(area > 7.5 * 7.5 and area < 9.2 * 9.2);
    for (mesh.vertices) |v| {
        try testing.expect(@abs(v[0]) <= 4.6 and @abs(v[2]) <= 4.6);
        try testing.expectApproxEqAbs(@as(f32, 0), v[1], 0.3);
    }
    // The floor's middle is on it; the inside of the box is not.
    const middle = mesh.closestPoint(.{ 0, 0.1, 0 }).?;
    try testing.expectApproxEqAbs(@as(f32, 0), middle.point[0], 1e-4);
}

test "a pillar is a hole worn wider by the radius, and a path goes round it" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ -6, -0.5, -6 }, .{ 6, 0, 6 });
    try world.box(.{ -1, 0, -1 }, .{ 1, 3, 1 });
    var mesh = try bake(testing.allocator, world.input(), .{}, null);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.polygons.len, try mesh.connectedFrom(testing.allocator, 0));
    // No polygon over the pillar or its worn edge - give or take the 1.3
    // cells an outline may stray along a wall.
    const at = mesh.closestPoint(.{ 0, 0, 0 }).?;
    try testing.expect(@max(@abs(at.point[0]), @abs(at.point[2])) >= 1.5 - 1.3 * 0.25);

    var path: NavMesh.Path = .{};
    defer path.deinit(testing.allocator);
    try mesh.findPath(testing.allocator, .{ 0, 0, -4 }, .{ 0, 0, 4 }, &path);
    try testing.expect(!path.partial);
    try testing.expect(path.points.items.len >= 3);
    // Round it, not through it: every leg keeps clear of the pillar.
    for (path.points.items[0 .. path.points.items.len - 1], path.points.items[1..]) |a, b| {
        for (0..21) |k| {
            const p = vec.lerp(a, b, @as(f32, @floatFromInt(k)) / 20);
            try testing.expect(@max(@abs(p[0]), @abs(p[2])) > 1.5 - 1.3 * 0.25);
        }
    }
    var length: f32 = 0;
    for (path.points.items[0 .. path.points.items.len - 1], path.points.items[1..]) |a, b| length += vec.length(b - a);
    // Pulled tight: not much longer than going round the worn corner.
    try testing.expect(length < 9.5);
}

test "a gentle ramp is walked up to a platform, a steep one is not, and a step too high splits the floor" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ -10, -0.5, -3 }, .{ 10, 0, 3 });
    // A platform a metre up at the right.
    try world.box(.{ 4, 0, -3 }, .{ 10, 1, 3 });
    // A ramp of about seventeen degrees up to it.
    try world.turnedBox(.{ 0.5, 0.3, -2 }, .{ 4.5, 0.6, 2 }, std.math.degreesToRadians(17.0));
    var mesh = try bake(testing.allocator, world.input(), .{ .cell_size = 0.2, .cell_height = 0.1 }, null);
    defer mesh.deinit(testing.allocator);
    var path: NavMesh.Path = .{};
    defer path.deinit(testing.allocator);
    try mesh.findPath(testing.allocator, .{ -6, 0, 0 }, .{ 7, 1, 0 }, &path);
    try testing.expect(!path.partial);
    try testing.expectApproxEqAbs(@as(f32, 1), path.points.items[path.points.items.len - 1][1], 0.25);
    // A point in the platform's footprint, on the floor's height: on the
    // platform, where it is.
    const up = mesh.closestPoint(.{ 7, 0, 0.5 }).?;
    try testing.expectApproxEqAbs(@as(f32, 7), up.point[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), up.point[2], 1e-4);
    try testing.expect(up.point[1] > 0.7);

    // Too steep: the platform is cut off.
    var steep: World = .{};
    defer steep.deinit();
    try steep.box(.{ -10, -0.5, -3 }, .{ 10, 0, 3 });
    try steep.box(.{ 4, 0, -3 }, .{ 10, 1, 3 });
    try steep.turnedBox(.{ 2.6, -0.2, -2 }, .{ 4.6, 0.1, 2 }, std.math.degreesToRadians(60.0));
    var cut = try bake(testing.allocator, steep.input(), .{ .cell_size = 0.2, .cell_height = 0.1 }, null);
    defer cut.deinit(testing.allocator);
    try cut.findPath(testing.allocator, .{ -6, 0, 0 }, .{ 7, 1, 0 }, &path);
    try testing.expect(path.partial);
}

test "a gap under a low beam is walked under only by an agent short enough" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ -6, -0.5, -2 }, .{ 6, 0, 2 });
    // Walls either side of a doorway at x = 0, and a beam over it 1.2 up.
    try world.box(.{ -0.25, 0, -2 }, .{ 0.25, 3, -1 });
    try world.box(.{ -0.25, 0, 1 }, .{ 0.25, 3, 2 });
    try world.box(.{ -0.25, 1.2, -1 }, .{ 0.25, 3, 1 });
    var path: NavMesh.Path = .{};
    defer path.deinit(testing.allocator);

    var tall = try bake(testing.allocator, world.input(), .{ .agent_radius = 0.3, .cell_size = 0.1, .cell_height = 0.1 }, null);
    defer tall.deinit(testing.allocator);
    try tall.findPath(testing.allocator, .{ -4, 0, 0 }, .{ 4, 0, 0 }, &path);
    try testing.expect(path.partial);

    var short = try bake(testing.allocator, world.input(), .{ .agent_radius = 0.3, .agent_height = 1, .cell_size = 0.1, .cell_height = 0.1 }, null);
    defer short.deinit(testing.allocator);
    try short.findPath(testing.allocator, .{ -4, 0, 0 }, .{ 4, 0, 0 }, &path);
    try testing.expect(!path.partial);
}

test "a slope is walked up with coarse cells and a low climb: its rounding into steps does not cut it up" {
    var world: World = .{};
    defer world.deinit();
    try world.box(.{ -10, -0.5, -3 }, .{ 10, 0, 3 });
    try world.box(.{ 4, 0, -3 }, .{ 10, 1, 3 });
    // About twenty-five degrees, up to the platform a metre high.
    try world.turnedBox(.{ 1.3, 0.25, -2 }, .{ 4.3, 0.55, 2 }, std.math.degreesToRadians(25.0));
    var path: NavMesh.Path = .{};
    defer path.deinit(testing.allocator);
    for ([_]Settings{ .{ .agent_max_climb = 0.1 }, .{ .agent_max_climb = 0.1, .cell_size = 0.2, .cell_height = 0.05 } }) |settings| {
        var mesh = try bake(testing.allocator, world.input(), settings, null);
        defer mesh.deinit(testing.allocator);
        try mesh.findPath(testing.allocator, .{ -6, 0, 0 }, .{ 7, 1, 0 }, &path);
        try testing.expect(!path.partial);
    }
    // A kerb higher than a cell of the slope rises, rounded to steps, is
    // not stepped onto.
    var kerb: World = .{};
    defer kerb.deinit();
    try kerb.box(.{ -10, -0.5, -3 }, .{ 10, 0, 3 });
    try kerb.box(.{ 2, 0, -3 }, .{ 10, 0.6, 3 });
    var stepped = try bake(testing.allocator, kerb.input(), .{ .agent_max_climb = 0.1 }, null);
    defer stepped.deinit(testing.allocator);
    try stepped.findPath(testing.allocator, .{ -6, 0, 0 }, .{ 6, 0.6, 0 }, &path);
    try testing.expect(path.partial);
}
