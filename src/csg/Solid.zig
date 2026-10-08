// SPDX-License-Identifier: BSD-3-Clause

//! A solid as the polygons round it, facing out - and joined to another,
//! cut by it, or met with it, by binary space partitioning: each solid's
//! polygons put in a tree of the planes they lie in, each solid's polygons
//! cut by the other's tree and those inside it - or outside, for the parts
//! a cut or a meeting keeps - thrown away.
//!
//! The trees are walked with lists of their own, never by recursion: a
//! solid of thousands of polygons may make a tree that deep, and a stack
//! does not run out. Everything an operation makes is in the arena it is
//! given, freed at once when the arena is.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Solid = @This();

polygons: []const Polygon = &.{},

/// How far from a plane a point is still on it, in the solid's units.
pub const epsilon = 1e-5;

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    pub fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f64) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }

    pub fn len(a: Vec3) f64 {
        return @sqrt(a.dot(a));
    }

    pub fn norm(a: Vec3) Vec3 {
        const l = a.len();
        return if (l > 0) a.scale(1 / l) else a;
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f64) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
};

/// A place an affine transform puts things: three rows of four.
pub const Affine = struct {
    rows: [3][4]f64 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },

    pub const identity: Affine = .{};

    /// From a matrix of sixteen, column by column.
    pub fn ofColumns(m: [16]f32) Affine {
        var out: Affine = undefined;
        for (0..3) |r| {
            for (0..4) |c| out.rows[r][c] = m[c * 4 + r];
        }
        return out;
    }

    pub fn point(self: Affine, p: Vec3) Vec3 {
        const r = self.rows;
        return .{
            .x = r[0][0] * p.x + r[0][1] * p.y + r[0][2] * p.z + r[0][3],
            .y = r[1][0] * p.x + r[1][1] * p.y + r[1][2] * p.z + r[1][3],
            .z = r[2][0] * p.x + r[2][1] * p.y + r[2][2] * p.z + r[2][3],
        };
    }

    fn column(self: Affine, c: usize) Vec3 {
        return .{ .x = self.rows[0][c], .y = self.rows[1][c], .z = self.rows[2][c] };
    }

    /// Whether it turns a solid inside out: a mirror.
    pub fn mirrors(self: Affine) bool {
        return self.column(0).dot(self.column(1).cross(self.column(2))) < 0;
    }

    /// A normal as the transform turns it: by the inverse of its turn turned
    /// over - its columns' crossings - made one long again.
    pub fn normal(self: Affine, n: Vec3) Vec3 {
        const a = self.column(0);
        const b = self.column(1);
        const c = self.column(2);
        const turned = b.cross(c).scale(n.x).add(c.cross(a).scale(n.y)).add(a.cross(b).scale(n.z));
        return (if (self.mirrors()) turned.scale(-1) else turned).norm();
    }

    /// `self` after `first`: what puts a thing where `first` does, then
    /// moves it as `self` does.
    pub fn after(self: Affine, first: Affine) Affine {
        var out: Affine = undefined;
        for (0..3) |r| {
            for (0..4) |c| {
                var sum: f64 = if (c == 3) self.rows[r][3] else 0;
                for (0..3) |k| sum += self.rows[r][k] * first.rows[k][c];
                out.rows[r][c] = sum;
            }
        }
        return out;
    }
};

/// A corner of a polygon, and which way the surface faces there: the
/// plane's way for a flat face, along it for a smooth one.
pub const Vertex = struct {
    pos: Vec3,
    normal: Vec3,

    fn between(a: Vertex, b: Vertex, t: f64) Vertex {
        return .{ .pos = a.pos.lerp(b.pos, t), .normal = a.normal.lerp(b.normal, t).norm() };
    }
};

pub const Plane = struct {
    normal: Vec3,
    w: f64,

    /// Through the points of a polygon, by Newell's sum: steady however
    /// thin the polygon. Null for one with no area.
    pub fn through(points: []const Vertex) ?Plane {
        var n: Vec3 = .zero;
        var middle: Vec3 = .zero;
        for (points, 0..) |a, i| {
            const b = points[(i + 1) % points.len];
            n.x += (a.pos.y - b.pos.y) * (a.pos.z + b.pos.z);
            n.y += (a.pos.z - b.pos.z) * (a.pos.x + b.pos.x);
            n.z += (a.pos.x - b.pos.x) * (a.pos.y + b.pos.y);
            middle = middle.add(a.pos);
        }
        const l = n.len();
        if (!(l > epsilon * epsilon)) return null;
        const unit = n.scale(1 / l);
        middle = middle.scale(1 / @as(f64, @floatFromInt(points.len)));
        return .{ .normal = unit, .w = unit.dot(middle) };
    }

    fn flipped(self: Plane) Plane {
        return .{ .normal = self.normal.scale(-1), .w = -self.w };
    }

    fn distance(self: Plane, p: Vec3) f64 {
        return self.normal.dot(p) - self.w;
    }
};

/// A convex polygon, its corners anticlockwise seen from the outside, in
/// its plane. `tag` says whose it was: which material it is drawn with.
pub const Polygon = struct {
    vertices: []const Vertex,
    plane: Plane,
    tag: u32,

    fn flipped(self: Polygon, pool: *Pool) Allocator.Error!Polygon {
        const out = try pool.take(Vertex, self.vertices.len);
        for (self.vertices, 0..) |v, i| {
            out[self.vertices.len - 1 - i] = .{ .pos = v.pos, .normal = v.normal.scale(-1) };
        }
        return .{ .vertices = out, .plane = self.plane.flipped(), .tag = self.tag };
    }
};

pub const Operation = enum {
    /// What is in either.
    @"union",
    /// What is in the first and not the second.
    subtract,
    /// What is in both.
    intersect,
};

// -------------------------------------------------------------------------
// Memory
//
// What an operation makes is handed out in order from blocks of the
// caller's arena, each twice the last, and its lists grow in them: an
// operation makes many small things and lets them all go at once, and the
// arena is asked a few times rather than each time.

const Pool = struct {
    backing: Allocator,
    next: [*]u8 = undefined,
    left: usize = 0,
    /// How big the next block is: each twice the last, so an operation
    /// asks its arena a few times, however much it makes.
    block: usize = first_block,

    /// Room for `n` of `T`, good until the arena goes.
    fn take(self: *Pool, comptime T: type, n: usize) Allocator.Error![]T {
        if (n == 0) return &.{};
        const size = n * @sizeOf(T);
        const alignment = @alignOf(T);
        var pad = (alignment - @intFromPtr(self.next) % alignment) % alignment;
        if (self.left < pad + size) {
            const block = try self.backing.alignedAlloc(u8, .@"16", @max(size + alignment, self.block));
            self.block = @min(self.block * 2, last_block);
            self.next = block.ptr;
            self.left = block.len;
            pad = 0;
        }
        const at = self.next + pad;
        self.next = at + size;
        self.left -= pad + size;
        const typed: [*]T = @ptrCast(@alignCast(at));
        return typed[0..n];
    }

    fn create(self: *Pool, comptime T: type, value: T) Allocator.Error!*T {
        const one = try self.take(T, 1);
        one[0] = value;
        return &one[0];
    }

    const first_block = 16 * 1024;
    const last_block = 16 * 1024 * 1024;
};

/// A list growing in a pool: what it outgrows is left where it is.
fn List(comptime T: type) type {
    return struct {
        items: []T = &.{},
        capacity: usize = 0,

        const Self = @This();

        fn withCapacity(pool: *Pool, n: usize) Allocator.Error!Self {
            const room = try pool.take(T, n);
            return .{ .items = room[0..0], .capacity = n };
        }

        fn ensure(self: *Self, pool: *Pool, more: usize) Allocator.Error!void {
            const wanted = self.items.len + more;
            if (wanted <= self.capacity) return;
            const capacity = @max(wanted, self.capacity * 2, 8);
            const room = try pool.take(T, capacity);
            @memcpy(room[0..self.items.len], self.items);
            self.items = room[0..self.items.len];
            self.capacity = capacity;
        }

        fn append(self: *Self, pool: *Pool, item: T) Allocator.Error!void {
            try self.ensure(pool, 1);
            self.items.len += 1;
            self.items[self.items.len - 1] = item;
        }

        fn appendSlice(self: *Self, pool: *Pool, more: []const T) Allocator.Error!void {
            try self.ensure(pool, more.len);
            const at = self.items.len;
            self.items.len += more.len;
            @memcpy(self.items[at..], more);
        }

        fn pop(self: *Self) ?T {
            if (self.items.len == 0) return null;
            const item = self.items[self.items.len - 1];
            self.items.len -= 1;
            return item;
        }
    };
}

// -------------------------------------------------------------------------
// The tree

const Node = struct {
    plane: ?Plane = null,
    front: ?*Node = null,
    back: ?*Node = null,
    polygons: PolygonList = .{},
};

const PolygonList = List(Polygon);

const coplanar = 0;
const in_front = 1;
const behind = 2;
const spanning = 3;

/// `polygon` sorted by `plane`: into the lists of what is on it - facing
/// its way or not - in front of it and behind it, cut in two where it is
/// both.
fn split(pool: *Pool, plane: Plane, polygon: Polygon, on_front: *PolygonList, on_back: *PolygonList, front: *PolygonList, back: *PolygonList) Allocator.Error!void {
    var sides: [64]u2 = undefined;
    const many = polygon.vertices.len > sides.len;
    const kinds = if (many) try pool.take(u2, polygon.vertices.len) else sides[0..polygon.vertices.len];
    var whole: u2 = 0;
    for (polygon.vertices, kinds) |v, *kind| {
        const t = plane.distance(v.pos);
        kind.* = if (t < -epsilon) behind else if (t > epsilon) in_front else coplanar;
        whole |= kind.*;
    }
    switch (whole) {
        coplanar => try (if (plane.normal.dot(polygon.plane.normal) > 0) on_front else on_back).append(pool, polygon),
        in_front => try front.append(pool, polygon),
        behind => try back.append(pool, polygon),
        spanning => {
            // A convex polygon cut by a line: each side has its own corners
            // and the two where the line crosses, at most.
            const n = polygon.vertices.len;
            const f = try pool.take(Vertex, n + 2);
            const b = try pool.take(Vertex, n + 2);
            var fn_: usize = 0;
            var bn: usize = 0;
            for (0..n) |i| {
                const j = if (i + 1 == n) 0 else i + 1;
                const ti = kinds[i];
                const tj = kinds[j];
                const vi = polygon.vertices[i];
                const vj = polygon.vertices[j];
                if (ti != behind) {
                    f[fn_] = vi;
                    fn_ += 1;
                }
                if (ti != in_front) {
                    b[bn] = vi;
                    bn += 1;
                }
                if ((ti | tj) == spanning) {
                    const along = plane.normal.dot(vj.pos.sub(vi.pos));
                    const t = if (along != 0) (plane.w - plane.normal.dot(vi.pos)) / along else 0;
                    const v = vi.between(vj, @min(@max(t, 0), 1));
                    f[fn_] = v;
                    fn_ += 1;
                    b[bn] = v;
                    bn += 1;
                }
            }
            if (fn_ >= 3) try front.append(pool, .{ .vertices = f[0..fn_], .plane = polygon.plane, .tag = polygon.tag });
            if (bn >= 3) try back.append(pool, .{ .vertices = b[0..bn], .plane = polygon.plane, .tag = polygon.tag });
        },
    }
}

/// A tree of `polygons`.
fn treeOf(pool: *Pool, polygons: []const Polygon) Allocator.Error!*Node {
    const root = try pool.create(Node, .{});
    try build(pool, root, polygons);
    return root;
}

const Work = struct { node: *Node, list: []const Polygon };

/// `polygons` put into the tree under `root`.
fn build(pool: *Pool, root: *Node, polygons: []const Polygon) Allocator.Error!void {
    var stack: List(Work) = .{};
    try stack.append(pool, .{ .node = root, .list = polygons });
    while (stack.pop()) |work| {
        if (work.list.len == 0) continue;
        const node = work.node;
        const plane = node.plane orelse work.list[0].plane;
        node.plane = plane;
        // Each polygon goes at most once to each side.
        var front: PolygonList = try .withCapacity(pool, work.list.len);
        var back: PolygonList = try .withCapacity(pool, work.list.len);
        try node.polygons.ensure(pool, work.list.len);
        for (work.list) |polygon| try split(pool, plane, polygon, &node.polygons, &node.polygons, &front, &back);
        if (front.items.len > 0) {
            if (node.front == null) node.front = try pool.create(Node, .{});
            try stack.append(pool, .{ .node = node.front.?, .list = front.items });
        }
        if (back.items.len > 0) {
            if (node.back == null) node.back = try pool.create(Node, .{});
            try stack.append(pool, .{ .node = node.back.?, .list = back.items });
        }
    }
}

/// Every node of the tree under `root`.
fn nodesOf(pool: *Pool, root: *Node) Allocator.Error![]*Node {
    var out: List(*Node) = .{};
    try out.append(pool, root);
    var at: usize = 0;
    while (at < out.items.len) : (at += 1) {
        const node = out.items[at];
        if (node.front) |f| try out.append(pool, f);
        if (node.back) |b| try out.append(pool, b);
    }
    return out.items;
}

/// What of `polygons` is outside the solid `root` is the tree of.
fn clipPolygons(pool: *Pool, root: *Node, polygons: []const Polygon) Allocator.Error!PolygonList {
    var out: PolygonList = .{};
    var stack: List(Work) = .{};
    try stack.append(pool, .{ .node = root, .list = polygons });
    while (stack.pop()) |work| {
        const plane = work.node.plane orelse {
            try out.appendSlice(pool, work.list);
            continue;
        };
        var front: PolygonList = try .withCapacity(pool, work.list.len);
        var back: PolygonList = try .withCapacity(pool, work.list.len);
        for (work.list) |polygon| try split(pool, plane, polygon, &front, &back, &front, &back);
        if (work.node.front) |f| {
            try stack.append(pool, .{ .node = f, .list = front.items });
        } else try out.appendSlice(pool, front.items);
        if (work.node.back) |b| try stack.append(pool, .{ .node = b, .list = back.items });
    }
    return out;
}

/// Every polygon of `self`'s tree cut down to what is outside `other`'s.
fn clipTo(pool: *Pool, self: *Node, other: *Node) Allocator.Error!void {
    for (try nodesOf(pool, self)) |node| node.polygons = try clipPolygons(pool, other, node.polygons.items);
}

/// The solid turned inside out: what was in is out.
fn invert(pool: *Pool, root: *Node) Allocator.Error!void {
    for (try nodesOf(pool, root)) |node| {
        for (node.polygons.items) |*polygon| polygon.* = try polygon.flipped(pool);
        if (node.plane) |plane| node.plane = plane.flipped();
        const front = node.front;
        node.front = node.back;
        node.back = front;
    }
}

fn allPolygons(pool: *Pool, root: *Node) Allocator.Error![]Polygon {
    var out: PolygonList = .{};
    for (try nodesOf(pool, root)) |node| try out.appendSlice(pool, node.polygons.items);
    return out.items;
}

// -------------------------------------------------------------------------
// Solids

/// `self` joined with `other`, cut by it, or met with it: in `arena`, as
/// what it is made from.
pub fn combine(self: Solid, arena: Allocator, other: Solid, operation: Operation) Allocator.Error!Solid {
    if (other.polygons.len == 0) return if (operation == .intersect) .{} else self;
    if (self.polygons.len == 0) return if (operation == .@"union") other else .{};
    var pool: Pool = .{ .backing = arena };
    const a = try treeOf(&pool, self.polygons);
    const b = try treeOf(&pool, other.polygons);
    switch (operation) {
        .@"union" => {
            try clipTo(&pool, a, b);
            try clipTo(&pool, b, a);
            try invert(&pool, b);
            try clipTo(&pool, b, a);
            try invert(&pool, b);
            try build(&pool, a, try allPolygons(&pool, b));
        },
        .subtract => {
            try invert(&pool, a);
            try clipTo(&pool, a, b);
            try clipTo(&pool, b, a);
            try invert(&pool, b);
            try clipTo(&pool, b, a);
            try invert(&pool, b);
            try build(&pool, a, try allPolygons(&pool, b));
            try invert(&pool, a);
        },
        .intersect => {
            try invert(&pool, a);
            try clipTo(&pool, b, a);
            try invert(&pool, b);
            try clipTo(&pool, a, b);
            try clipTo(&pool, b, a);
            try build(&pool, a, try allPolygons(&pool, b));
            try invert(&pool, a);
        },
    }
    return .{ .polygons = try allPolygons(&pool, a) };
}

/// A polygon of `corners` as `place` puts it, turned over where `place`
/// mirrors: none for one with no area.
fn placed(pool: *Pool, corners: []const Vertex, place: Affine, tag: u32, out: *PolygonList) Allocator.Error!void {
    const vertices = try pool.take(Vertex, corners.len);
    const mirror = place.mirrors();
    for (corners, 0..) |v, i| {
        const at = if (mirror) corners.len - 1 - i else i;
        vertices[at] = .{ .pos = place.point(v.pos), .normal = place.normal(v.normal) };
    }
    const plane = Plane.through(vertices) orelse return;
    try out.append(pool, .{ .vertices = vertices, .plane = plane, .tag = tag });
}

/// A box `size` big about its middle.
pub fn box(arena: Allocator, size: Vec3, place: Affine, tag: u32) Allocator.Error!Solid {
    var pool: Pool = .{ .backing = arena };
    const h = size.scale(0.5);
    const faces = [_]struct { corners: [4]u3, normal: Vec3 }{
        .{ .corners = .{ 0, 4, 6, 2 }, .normal = .init(-1, 0, 0) },
        .{ .corners = .{ 1, 3, 7, 5 }, .normal = .init(1, 0, 0) },
        .{ .corners = .{ 0, 1, 5, 4 }, .normal = .init(0, -1, 0) },
        .{ .corners = .{ 2, 6, 7, 3 }, .normal = .init(0, 1, 0) },
        .{ .corners = .{ 0, 2, 3, 1 }, .normal = .init(0, 0, -1) },
        .{ .corners = .{ 4, 5, 7, 6 }, .normal = .init(0, 0, 1) },
    };
    var out: PolygonList = .{};
    for (faces) |face| {
        var corners: [4]Vertex = undefined;
        for (face.corners, &corners) |i, *v| {
            const sx: f64 = if (i & 1 != 0) 1 else -1;
            const sy: f64 = if (i & 2 != 0) 1 else -1;
            const sz: f64 = if (i & 4 != 0) 1 else -1;
            v.* = .{ .pos = .init(h.x * sx, h.y * sy, h.z * sz), .normal = face.normal };
        }
        try placed(&pool, &corners, place, tag, &out);
    }
    return .{ .polygons = out.items };
}

/// A cylinder standing along `y`, `height` tall about its middle, of
/// `sides` faces round - smooth round its side, or flat for each.
pub fn cylinder(arena: Allocator, radius: f64, height: f64, sides: u32, smooth: bool, place: Affine, tag: u32) Allocator.Error!Solid {
    var pool: Pool = .{ .backing = arena };
    const n = @max(sides, 3);
    const top = height / 2;
    var out: PolygonList = try .withCapacity(&pool, 3 * n);
    const up: Vec3 = .init(0, 1, 0);
    const down: Vec3 = .init(0, -1, 0);
    for (0..n) |i| {
        const a0 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * std.math.tau;
        const a1 = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n)) * std.math.tau;
        const r0: Vec3 = .init(@cos(a0), 0, -@sin(a0));
        const r1: Vec3 = .init(@cos(a1), 0, -@sin(a1));
        const middle = r0.add(r1).norm();
        const n0 = if (smooth) r0 else middle;
        const n1 = if (smooth) r1 else middle;
        const b0 = r0.scale(radius).add(down.scale(top));
        const b1 = r1.scale(radius).add(down.scale(top));
        const t0 = r0.scale(radius).add(up.scale(top));
        const t1 = r1.scale(radius).add(up.scale(top));
        try placed(&pool, &.{ .{ .pos = b0, .normal = n0 }, .{ .pos = b1, .normal = n1 }, .{ .pos = t1, .normal = n1 }, .{ .pos = t0, .normal = n0 } }, place, tag, &out);
        try placed(&pool, &.{ .{ .pos = up.scale(top), .normal = up }, .{ .pos = t0, .normal = up }, .{ .pos = t1, .normal = up } }, place, tag, &out);
        try placed(&pool, &.{ .{ .pos = down.scale(top), .normal = down }, .{ .pos = b1, .normal = down }, .{ .pos = b0, .normal = down } }, place, tag, &out);
    }
    return .{ .polygons = out.items };
}

/// A ball of `slices` round and `stacks` from pole to pole.
pub fn sphere(arena: Allocator, radius: f64, slices: u32, stacks: u32, place: Affine, tag: u32) Allocator.Error!Solid {
    var pool: Pool = .{ .backing = arena };
    const across = @max(slices, 3);
    const down = @max(stacks, 2);
    var out: PolygonList = try .withCapacity(&pool, across * down);
    for (0..across) |i| {
        for (0..down) |j| {
            // Down a slice, across, and back up: at a pole two corners are
            // one, and the face a triangle.
            var corners: [4]Vertex = undefined;
            var count: usize = 0;
            const all = [4][2]usize{ .{ i, j }, .{ i, j + 1 }, .{ i + 1, j + 1 }, .{ i + 1, j } };
            for (all, 0..) |at, k| {
                if (j == 0 and k == 3) continue;
                if (j + 1 == down and k == 2) continue;
                corners[count] = onBall(radius, at[0], at[1], across, down);
                count += 1;
            }
            try placed(&pool, corners[0..count], place, tag, &out);
        }
    }
    return .{ .polygons = out.items };
}

fn onBall(radius: f64, i: usize, j: usize, across: u32, down: u32) Vertex {
    const theta = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(across)) * std.math.tau;
    const phi = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(down)) * std.math.pi;
    const way: Vec3 = .init(@cos(theta) * @sin(phi), @cos(phi), -@sin(theta) * @sin(phi));
    return .{ .pos = way.scale(radius), .normal = way };
}

/// The triangles of a closed mesh, three indices each into `positions`.
pub fn mesh(arena: Allocator, positions: []const [3]f32, indices: []const u32, place: Affine, tag: u32) Allocator.Error!Solid {
    var pool: Pool = .{ .backing = arena };
    var out: PolygonList = try .withCapacity(&pool, indices.len / 3);
    var i: usize = 0;
    while (i + 2 < indices.len) : (i += 3) {
        var corners: [3]Vertex = undefined;
        for (&corners, indices[i..][0..3]) |*v, index| {
            if (index >= positions.len) break;
            const p = positions[index];
            v.* = .{ .pos = .init(p[0], p[1], p[2]), .normal = .zero };
        } else {
            const plane = Plane.through(&corners) orelse continue;
            for (&corners) |*v| v.normal = plane.normal;
            try placed(&pool, &corners, place, tag, &out);
        }
    }
    return .{ .polygons = out.items };
}

/// The solid as triangles: each polygon a fan from its first corner, those
/// with no area left out.
pub const Triangles = struct {
    /// Three corners a triangle.
    positions: [][3]f32,
    normals: [][3]f32,
    /// One a triangle: which way its polygon faces.
    faces: [][3]f32,
    /// One a triangle: its polygon's.
    tags: []u32,

    pub fn deinit(self: *Triangles, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.faces);
        gpa.free(self.tags);
        self.* = undefined;
    }

    pub fn count(self: Triangles) usize {
        return self.tags.len;
    }
};

pub fn triangles(self: Solid, gpa: Allocator) Allocator.Error!Triangles {
    var positions: std.ArrayList([3]f32) = .empty;
    errdefer positions.deinit(gpa);
    var normals: std.ArrayList([3]f32) = .empty;
    errdefer normals.deinit(gpa);
    var faces: std.ArrayList([3]f32) = .empty;
    errdefer faces.deinit(gpa);
    var tags: std.ArrayList(u32) = .empty;
    errdefer tags.deinit(gpa);
    for (self.polygons) |polygon| {
        const way = polygon.plane.normal;
        const v = polygon.vertices;
        if (v.len < 3) continue;
        for (1..v.len - 1) |k| {
            const corners = [3]Vertex{ v[0], v[k], v[k + 1] };
            const size = corners[1].pos.sub(corners[0].pos).cross(corners[2].pos.sub(corners[0].pos)).len();
            if (!(size > epsilon * epsilon)) continue;
            for (corners) |c| {
                try positions.append(gpa, .{ @floatCast(c.pos.x), @floatCast(c.pos.y), @floatCast(c.pos.z) });
                const facing = if (c.normal.dot(polygon.plane.normal) > 0) c.normal else polygon.plane.normal;
                try normals.append(gpa, .{ @floatCast(facing.x), @floatCast(facing.y), @floatCast(facing.z) });
            }
            try faces.append(gpa, .{ @floatCast(way.x), @floatCast(way.y), @floatCast(way.z) });
            try tags.append(gpa, polygon.tag);
        }
    }
    const own_positions = try positions.toOwnedSlice(gpa);
    errdefer gpa.free(own_positions);
    const own_normals = try normals.toOwnedSlice(gpa);
    errdefer gpa.free(own_normals);
    const own_faces = try faces.toOwnedSlice(gpa);
    errdefer gpa.free(own_faces);
    return .{ .positions = own_positions, .normals = own_normals, .faces = own_faces, .tags = try tags.toOwnedSlice(gpa) };
}

/// The solid as a mesh: its triangles' corners made one where they are the
/// same - the same place, to a hundredth of a millimetre, facing the same
/// way, at the same place on a picture - each with its place on a picture
/// laid flat on its face (`planarUv`) and the way that picture's `u` runs,
/// and the triangles of each tag together, the tags in their order.
pub const Indexed = struct {
    positions: [][3]f32,
    normals: [][3]f32,
    uvs: [][2]f32,
    /// The way `u` runs across the surface, square to the normal; `w` is
    /// one, or minus one where `v` runs the other way round.
    tangents: [][4]f32,
    indices: []u32,
    /// Each tag's run of `indices`, for the tags that have triangles.
    runs: []Run,

    pub const Run = struct { tag: u32, first: u32, count: u32 };

    pub fn deinit(self: *Indexed, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.uvs);
        gpa.free(self.tangents);
        gpa.free(self.indices);
        gpa.free(self.runs);
        self.* = undefined;
    }
};

pub fn indexed(self: Solid, gpa: Allocator) Allocator.Error!Indexed {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var pool: Pool = .{ .backing = arena_state.allocator() };

    // Each polygon a fan of triangles from its first corner, those with no
    // area left out, at most so many.
    var most: usize = 0;
    var last: u32 = 0;
    for (self.polygons) |polygon| {
        if (polygon.vertices.len >= 3) most += polygon.vertices.len - 2;
        last = @max(last, polygon.tag);
    }
    const positions = try pool.take([3]f32, most * 3);
    const normals = try pool.take([3]f32, most * 3);
    const uvs = try pool.take([2]f32, most * 3);
    const tangents = try pool.take([4]f32, most * 3);
    const indices = try pool.take(u32, most * 3);
    var runs: List(Indexed.Run) = .{};
    var corners: Corners = try .init(&pool, most * 3);
    var vertex_count: u32 = 0;
    var index_count: u32 = 0;

    if (most > 0) {
        var tag: u32 = 0;
        while (tag <= last) : (tag += 1) {
            const first = index_count;
            corners.clear();
            for (self.polygons) |polygon| {
                if (polygon.tag != tag or polygon.vertices.len < 3) continue;
                const v = polygon.vertices;
                const way = polygon.plane.normal;
                const facing: [3]f32 = .{ @floatCast(way.x), @floatCast(way.y), @floatCast(way.z) };
                for (1..v.len - 1) |k| {
                    const fan = [3]Vertex{ v[0], v[k], v[k + 1] };
                    const size = fan[1].pos.sub(fan[0].pos).cross(fan[2].pos.sub(fan[0].pos)).len();
                    if (!(size > epsilon * epsilon)) continue;
                    for (fan) |c| {
                        const position = rounded(.{ @floatCast(c.pos.x), @floatCast(c.pos.y), @floatCast(c.pos.z) });
                        const n = if (c.normal.dot(way) > 0) c.normal else way;
                        const normal: [3]f32 = .{ @floatCast(n.x), @floatCast(n.y), @floatCast(n.z) };
                        const uv = planarUv(position, facing);
                        const key: [8]u32 = .{
                            @bitCast(position[0]), @bitCast(position[1]), @bitCast(position[2]),
                            @bitCast(normal[0]),   @bitCast(normal[1]),   @bitCast(normal[2]),
                            @bitCast(uv[0]),       @bitCast(uv[1]),
                        };
                        const at = corners.find(key, vertex_count);
                        if (at == vertex_count) {
                            positions[at] = position;
                            normals[at] = normal;
                            uvs[at] = uv;
                            tangents[at] = tangentOf(normal, facing);
                            vertex_count += 1;
                        }
                        indices[index_count] = at;
                        index_count += 1;
                    }
                }
            }
            if (index_count > first) try runs.append(&pool, .{ .tag = tag, .first = first, .count = index_count - first });
        }
    }

    var out: Indexed = undefined;
    out.positions = try gpa.dupe([3]f32, positions[0..vertex_count]);
    errdefer gpa.free(out.positions);
    out.normals = try gpa.dupe([3]f32, normals[0..vertex_count]);
    errdefer gpa.free(out.normals);
    out.uvs = try gpa.dupe([2]f32, uvs[0..vertex_count]);
    errdefer gpa.free(out.uvs);
    out.tangents = try gpa.dupe([4]f32, tangents[0..vertex_count]);
    errdefer gpa.free(out.tangents);
    out.indices = try gpa.dupe(u32, indices[0..index_count]);
    errdefer gpa.free(out.indices);
    out.runs = try gpa.dupe(Indexed.Run, runs.items);
    return out;
}

/// The corners met so far, by everything that makes them one: a table
/// of their places among the vertices, open, twice as large as needed.
const Corners = struct {
    keys: [][8]u32,
    places: []u32,
    used: []bool,

    fn init(pool: *Pool, most: usize) Allocator.Error!Corners {
        var size: usize = 16;
        while (size < most * 2) size *= 2;
        return .{ .keys = try pool.take([8]u32, size), .places = try pool.take(u32, size), .used = try pool.take(bool, size) };
    }

    fn clear(self: *Corners) void {
        @memset(self.used, false);
    }

    /// The place of the corner `key`; `next`, and it kept there, for one
    /// not met yet.
    fn find(self: *Corners, key: [8]u32, next: u32) u32 {
        var h: u32 = 2166136261;
        for (key) |word| h = (h ^ word) *% 16777619;
        const mask = self.keys.len - 1;
        var at: usize = h & mask;
        while (self.used[at]) : (at = (at + 1) & mask) {
            const known = self.keys[at];
            var same = true;
            for (known, key) |a, b| same = same and a == b;
            if (same) return self.places[at];
        }
        self.used[at] = true;
        self.keys[at] = key;
        self.places[at] = next;
        return next;
    }
};

/// A corner to the nearest hundredth of a millimetre: the same corner, cut
/// out of two faces' edges, is one.
fn rounded(p: [3]f32) [3]f32 {
    const grid = 1e5;
    return .{ @round(p[0] * grid) / grid, @round(p[1] * grid) / grid, @round(p[2] * grid) / grid };
}

/// Where on a picture a point of a face is: the point seen along the axis
/// the face turns most to - from the side, from above or from the front -
/// in the solid's units, so a picture is as big on every face whatever its
/// size, and upright on the sides. Nothing mirrored: `u` runs to the right
/// seen from outside.
pub fn planarUv(position: [3]f32, facing: [3]f32) [2]f32 {
    const way = axesOf(facing);
    const p: Vec3 = .init(position[0], position[1], position[2]);
    return .{ @floatCast(p.dot(way.u)), @floatCast(p.dot(way.v)) };
}

/// The ways a picture's `u` and `v` run on a face that faces `facing`.
fn axesOf(facing: [3]f32) struct { u: Vec3, v: Vec3 } {
    const ax = @abs(facing[0]);
    const ay = @abs(facing[1]);
    const az = @abs(facing[2]);
    if (ay >= ax and ay >= az) return if (facing[1] > 0) .{ .u = .init(1, 0, 0), .v = .init(0, 0, 1) } else .{ .u = .init(1, 0, 0), .v = .init(0, 0, -1) };
    if (ax >= az) return if (facing[0] > 0) .{ .u = .init(0, 0, -1), .v = .init(0, -1, 0) } else .{ .u = .init(0, 0, 1), .v = .init(0, -1, 0) };
    return if (facing[2] > 0) .{ .u = .init(1, 0, 0), .v = .init(0, -1, 0) } else .{ .u = .init(-1, 0, 0), .v = .init(0, -1, 0) };
}

/// The way `u` runs at a corner facing `normal` on a face facing `facing`,
/// square to the normal, and which way round `v` runs.
fn tangentOf(normal: [3]f32, facing: [3]f32) [4]f32 {
    const way = axesOf(facing);
    const n: Vec3 = .init(normal[0], normal[1], normal[2]);
    var t = way.u.sub(n.scale(n.dot(way.u)));
    if (!(t.len() > 1e-6)) t = way.v.cross(n);
    t = t.norm();
    const w: f32 = if (n.cross(way.u).dot(way.v) < 0) -1 else 1;
    return .{ @floatCast(t.x), @floatCast(t.y), @floatCast(t.z), w };
}

/// How much is inside: the sum over the triangles of the tetrahedra they
/// make with the origin. Nought for a solid that is not closed only by
/// chance; what the tests measure an operation by.
pub fn volume(self: Solid) f64 {
    var sum: f64 = 0;
    for (self.polygons) |polygon| {
        const v = polygon.vertices;
        if (v.len < 3) continue;
        for (1..v.len - 1) |k| sum += v[0].pos.dot(v[k].pos.cross(v[k + 1].pos));
    }
    return sum / 6;
}

/// How much surface it has.
pub fn area(self: Solid) f64 {
    var sum: f64 = 0;
    for (self.polygons) |polygon| {
        const v = polygon.vertices;
        if (v.len < 3) continue;
        for (1..v.len - 1) |k| sum += v[k].pos.sub(v[0].pos).cross(v[k + 1].pos.sub(v[0].pos)).len();
    }
    return sum / 2;
}

/// Whether it has no hole in its surface: what its triangles face, each
/// as much as it is big, sums to nought for a closed surface, and a hole
/// leaves its own over.
pub fn closed(self: Solid) bool {
    var sum: Vec3 = .zero;
    var whole: f64 = 0;
    for (self.polygons) |polygon| {
        const v = polygon.vertices;
        if (v.len < 3) continue;
        for (1..v.len - 1) |k| {
            const n = v[k].pos.sub(v[0].pos).cross(v[k + 1].pos.sub(v[0].pos));
            sum = sum.add(n);
            whole += n.len();
        }
    }
    return sum.len() <= whole * 1e-6 + 1e-9;
}

// -------------------------------------------------------------------------

fn expectNear(want: f64, got: f64, tolerance: f64) !void {
    try testing.expectApproxEqAbs(want, got, tolerance);
}

test "a box, a cylinder and a ball are closed, face out, and hold what they should" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cube = try box(arena, .init(2, 3, 4), .identity, 0);
    try expectNear(24, cube.volume(), 1e-9);
    try expectNear(2 * (6 + 8 + 12), cube.area(), 1e-9);
    try testing.expect(cube.closed());
    const can = try cylinder(arena, 1, 2, 64, true, .identity, 0);
    try expectNear(std.math.pi * 2, can.volume(), 0.02);
    try testing.expect(can.closed());
    const ball = try sphere(arena, 1, 48, 24, .identity, 0);
    try expectNear(4.0 / 3.0 * std.math.pi, ball.volume(), 0.03);
    try testing.expect(ball.closed());
    // Every polygon faces out of the middle.
    for ([_]Solid{ cube, can, ball }) |solid| {
        for (solid.polygons) |polygon| {
            var middle: Vec3 = .zero;
            for (polygon.vertices) |v| middle = middle.add(v.pos);
            try testing.expect(polygon.plane.normal.dot(middle) > 0);
        }
    }
}

test "a box cut from a box leaves what is left, a hole through it its walls inside, and two joined what both hold" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wall = try box(arena, .init(4, 3, 0.5), .identity, 0);
    // A doorway through the wall, from the floor up.
    var door_place: Affine = .identity;
    door_place.rows[1][3] = -0.5;
    const door = try box(arena, .init(1, 2, 1), door_place, 1);
    const holed = try wall.combine(arena, door, .subtract);
    try expectNear(6 - 1 * 2 * 0.5, holed.volume(), 1e-6);
    try testing.expect(holed.closed());
    // The doorway's sides are the door's: its tag.
    var tagged: usize = 0;
    for (holed.polygons) |polygon| tagged += @intFromBool(polygon.tag == 1);
    try testing.expect(tagged >= 3);

    // Two boxes overlapping by half: one and a half of one.
    const a = try box(arena, .init(2, 2, 2), .identity, 0);
    var shifted: Affine = .identity;
    shifted.rows[0][3] = 1;
    const b = try box(arena, .init(2, 2, 2), shifted, 0);
    try expectNear(12, (try a.combine(arena, b, .@"union")).volume(), 1e-6);
    try expectNear(4, (try a.combine(arena, b, .intersect)).volume(), 1e-6);
    try expectNear(4, (try a.combine(arena, b, .subtract)).volume(), 1e-6);
    // With nothing: what there was, or nothing.
    try expectNear(8, (try a.combine(arena, .{}, .@"union")).volume(), 1e-9);
    try expectNear(0, (try a.combine(arena, .{}, .intersect)).volume(), 1e-9);
    try expectNear(0, (try Solid.combine(.{}, arena, a, .subtract)).volume(), 1e-9);
}

test "an arch: a cylinder cut from a box, turned to lie across it, leaves its curve" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const block = try box(arena, .init(4, 2, 1), .identity, 0);
    // Lying along z: turned a quarter about x.
    const lying: Affine = .{ .rows = .{ .{ 1, 0, 0, 0 }, .{ 0, 0, -1, -1 }, .{ 0, 1, 0, 0 } } };
    const tube = try cylinder(arena, 1, 2, 64, true, lying, 1);
    const arch = try block.combine(arena, tube, .subtract);
    // Half the tube's round end is inside the block's lower half.
    try expectNear(8 - std.math.pi / 2.0, arch.volume(), 0.02);
    try testing.expect(arch.closed());
    // A mirror turns the polygons round, and the solid still faces out.
    const mirrored = try box(arena, .init(1, 1, 1), .{ .rows = .{ .{ -1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } } }, 0);
    try expectNear(1, mirrored.volume(), 1e-9);
}

test "a box as a mesh is four corners a face, a tag's triangles together, each corner's picture a metre across" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try box(arena, .init(2, 2, 2), .identity, 0);
    var shifted: Affine = .identity;
    shifted.rows[1][3] = 1;
    const cut = try a.combine(arena, try box(arena, .init(1, 1, 1), shifted, 2), .subtract);
    var made = try cut.indexed(testing.allocator);
    defer made.deinit(testing.allocator);
    // Two runs, the tags in their order.
    try testing.expectEqual(@as(usize, 2), made.runs.len);
    try testing.expectEqual(@as(u32, 0), made.runs[0].tag);
    try testing.expectEqual(@as(u32, 2), made.runs[1].tag);
    try testing.expectEqual(made.indices.len, made.runs[0].count + made.runs[1].count);
    // A plain box: four corners a face, shared by its two triangles.
    var plain = try a.indexed(testing.allocator);
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 24), plain.positions.len);
    try testing.expectEqual(@as(usize, 36), plain.indices.len);
    for (plain.positions, plain.uvs, plain.tangents, plain.normals) |p, uv, t, n| {
        // A metre of picture a metre of face, and the tangent along `u`.
        try testing.expectApproxEqAbs(@as(f32, 1), @abs(uv[0]), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1), @abs(uv[1]), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0), t[0] * n[0] + t[1] * n[1] + t[2] * n[2], 1e-6);
        _ = p;
    }
}

test "many cuts make a deep tree, which is walked without running out of stack" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var solid = try box(arena, .init(20, 2, 2), .identity, 0);
    for (0..40) |i| {
        var at: Affine = .identity;
        at.rows[0][3] = -9.5 + @as(f64, @floatFromInt(i)) * 0.48;
        at.rows[1][3] = 0.8;
        solid = try solid.combine(arena, try box(arena, .init(0.2, 1, 3), at, 1), .subtract);
    }
    try testing.expect(solid.volume() < 80 and solid.volume() > 60);
    try testing.expect(solid.closed());
    var tris = try solid.triangles(testing.allocator);
    defer tris.deinit(testing.allocator);
    try testing.expect(tris.count() > 200);
}
