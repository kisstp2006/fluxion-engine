// SPDX-License-Identifier: BSD-3-Clause

//! Shadows: every light that casts one sees the world from where it shines,
//! and how near it each thing is - its depth - is drawn into one picture,
//! the atlas, before the world is drawn. A surface then asks the atlas
//! whether something nearer the light stands between them.
//!
//! **One atlas, square tiles.** A sun's view is cut along the camera's into
//! one to four cascades, nearest smallest, each a tile; a spot light is a
//! tile; a point light is six, one a side of a cube around it. Tiles are
//! handed out largest first - suns', then lamps' by how much of the picture
//! they light - and a lamp that does not fit gets a smaller one, or casts
//! none.
//!
//! **A view is two matrices.** One draws the tile, in the device's clip
//! space. The other takes a point of the world straight to where it is in
//! the atlas and the depth to compare it with - made in Direct3D's clip
//! space, whose window depth every API agrees on, and turned over for a
//! device whose pictures are stored bottom row first. So the shader asks
//! the same thing on every backend.
//!
//! **What keeps a surface from shadowing itself.** The point looked up is
//! moved toward the light and out along its surface by a light's
//! `shadow_bias` and `shadow_normal_bias`, counted in the shadow's own
//! texels there - so the same numbers hold near and far, and in every tile
//! size - and what casts is drawn pushed back by its slope.
//!
//! **Soft edges.** A shadow is read at several points round the one looked
//! up - the project's `shadow_filter` says how many - turned a little from
//! one pixel to the next, over `shadow_blur` texels. A light with a `size`
//! (a sun, an `angular_size`) first looks for what casts the shadow, and
//! softens it by how far that is from where the shadow falls.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;

const shader3d = @import("shader3d.zig");
const View3D = @import("view3d.zig").View3D;

/// The most views - tiles - a frame's shadows take: sixteen cascades, and
/// what is left for lamps.
pub const most_views = 128;
const most_suns = shader3d.most_suns;
const most_lamps = shader3d.most_lamps;

/// How soft a filter makes a shadow's edge, in texels, at a light's
/// `shadow_blur` of one.
pub const Filter = enum {
    hard,
    soft_low,
    soft_medium,
    soft_high,

    /// How many times the atlas is read for one shadow.
    pub fn taps(self: Filter) u32 {
        return switch (self) {
            .hard => 1,
            .soft_low => 6,
            .soft_medium => 12,
            .soft_high => 20,
        };
    }

    pub fn radius(self: Filter) f32 {
        return switch (self) {
            .hard => 0,
            .soft_low => 1.0,
            .soft_medium => 1.5,
            .soft_high => 2.0,
        };
    }
};

/// What every shadow of a frame tells the shader, as its `Shadows` block
/// says.
pub const Shadows = extern struct {
    /// Each view: the world to the atlas - where across and down, and the
    /// depth to compare with.
    matrices: [most_views]Mat4,
    /// The part of the atlas each view reads, its left, top, right and
    /// bottom: a reading is kept inside its own tile.
    rects: [most_views][4]f32,
    /// Each view's near and far, how wide one of its texels is - a unit
    /// away, for one that is seen in perspective - and one for perspective.
    views: [most_views][4]f32,
    /// Each lamp's first view, or -1; how many it has (a point light six);
    /// its bias toward the light and along its surface, in texels.
    lamps: [most_lamps][4]f32,
    /// Each lamp's blur in texels, and its size.
    lamp_softness: [most_lamps][4]f32,
    /// Each sun's first view, or -1; its cascades; its two biases.
    suns: [most_suns][4]f32,
    /// How far along the camera's view each of a sun's cascades ends.
    sun_splits: [most_suns][4]f32,
    /// Each sun's blur in texels, how much wider its shadows get a unit
    /// further from what casts them, and where they start and finish
    /// fading out.
    sun_softness: [most_suns][4]f32,
    /// One texel of the atlas, the filter's readings, and its size.
    atlas: [4]f32,

    /// None: no lamp or sun has a shadow.
    pub fn none() Shadows {
        var out: Shadows = undefined;
        @memset(std.mem.asBytes(&out), 0);
        for (&out.lamps) |*lamp| lamp[0] = -1;
        for (&out.suns) |*sun| sun[0] = -1;
        for (&out.sun_splits) |*split| split.* = @splat(std.math.floatMax(f32));
        for (&out.matrices) |*m| m.* = .identity;
        return out;
    }
};

/// What a light that casts a shadow says about it.
pub const Settings = struct {
    /// How far the point looked up is moved toward the light, and out along
    /// its surface, in the shadow's texels.
    bias: f32 = 1,
    normal_bias: f32 = 1.5,
    /// How soft its edge is: one is the filter's own.
    blur: f32 = 1,
    /// How big the light is - in units for a lamp, and for a sun how much
    /// wider its shadow gets a unit further from what casts it.
    size: f32 = 0,
};

/// A point or spot light that casts a shadow.
pub const Lamp = struct {
    /// Its place among the frame's lamps: where the shader finds it.
    index: u32,
    /// Which light it is from draw to draw: its entity.
    light: u64 = 0,
    place: Vec3,
    range: f32,
    /// A spot light's way and half its cone; none for a point light.
    spot: ?struct { aim: Vec3, angle: f32 } = null,
    settings: Settings,
    /// How far it is from the camera.
    distance: f32,
};

/// A sun that casts a shadow.
pub const Sun = struct {
    /// Its place among the frame's suns.
    index: u32,
    /// Toward it.
    toward: Vec3,
    settings: Settings,
    cascades: u32,
    max_distance: f32,
};

/// A square of the atlas, in texels from its top left.
pub const Tile = struct { x: u32, y: u32, size: u32 };

/// One tile's worth of what a light sees.
pub const View = struct {
    /// What the tile is drawn through, in the device's clip space.
    render: Mat4,
    tile: Tile,
    /// What casts into it is inside this, in the device's clip space.
    frustum: math.Frustum,
    /// And within this, for a lamp: as far as it reaches.
    reach: ?math.Sphere = null,
    /// Its tile's place in the cache.
    key: Cache.Key = .{ .light = 0, .face = 0 },
};

/// Square tiles of sizes that are powers of two, taken and given back: a
/// square of the atlas splits into four to make a smaller one, and four
/// given back join again. The smallest is a sixty-fourth of the atlas across.
pub const Tiles = struct {
    atlas: u32,
    unit: u32,
    /// The free squares of each size: `free[0]` the whole atlas, each level
    /// after a quarter of the one before.
    free: [levels]std.ArrayList(Tile) = @splat(.empty),

    const levels = 7;

    pub fn init(gpa: Allocator, atlas: u32) Allocator.Error!Tiles {
        var self: Tiles = .{ .atlas = atlas, .unit = @max(atlas / 64, 16) };
        try self.free[0].append(gpa, .{ .x = 0, .y = 0, .size = atlas });
        return self;
    }

    pub fn deinit(self: *Tiles, gpa: Allocator) void {
        for (&self.free) |*list| list.deinit(gpa);
        self.* = undefined;
    }

    fn levelOf(self: *const Tiles, size: u32) usize {
        const wanted = std.math.clamp(size, self.unit, self.atlas);
        return @min(std.math.log2_int(u32, self.atlas / std.math.floorPowerOfTwo(u32, wanted)), levels - 1);
    }

    /// A tile `size` texels a side - a power of two, from the atlas's
    /// smallest up to the whole of it - or null when none is free.
    pub fn take(self: *Tiles, gpa: Allocator, size: u32) Allocator.Error!?Tile {
        const level = self.levelOf(size);
        var from = level;
        while (self.free[from].items.len == 0) {
            if (from == 0) return null;
            from -= 1;
        }
        var tile = self.free[from].pop().?;
        // Split down to the size asked for, keeping three quarters each time.
        while (from < level) : (from += 1) {
            const half = tile.size / 2;
            try self.free[from + 1].appendSlice(gpa, &.{
                .{ .x = tile.x + half, .y = tile.y, .size = half },
                .{ .x = tile.x, .y = tile.y + half, .size = half },
                .{ .x = tile.x + half, .y = tile.y + half, .size = half },
            });
            tile.size = half;
        }
        return tile;
    }

    /// `count` tiles of `size` into `out`, or none of them.
    pub fn takeMany(self: *Tiles, gpa: Allocator, size: u32, out: []Tile) Allocator.Error!bool {
        for (out, 0..) |*tile, at| {
            tile.* = (try self.take(gpa, size)) orelse {
                for (out[0..at]) |taken| try self.give(gpa, taken);
                return false;
            };
        }
        return true;
    }

    /// Give `tile` back, joining it with its three neighbours into the square
    /// they were split from where they are free too.
    pub fn give(self: *Tiles, gpa: Allocator, tile: Tile) Allocator.Error!void {
        const level = self.levelOf(tile.size);
        if (level > 0) {
            const whole = tile.size * 2;
            const parent: Tile = .{ .x = tile.x - tile.x % whole, .y = tile.y - tile.y % whole, .size = whole };
            var found: [3]usize = undefined;
            var count: usize = 0;
            for (self.free[level].items, 0..) |held, at| {
                if (held.x - held.x % whole == parent.x and held.y - held.y % whole == parent.y) {
                    if (count < 3) found[count] = at;
                    count += 1;
                }
            }
            if (count == 3) {
                // Removed from the back first, so the places before stay put.
                std.mem.sort(usize, &found, {}, std.sort.desc(usize));
                for (found) |at| _ = self.free[level].swapRemove(at);
                return self.give(gpa, parent);
            }
        }
        try self.free[level].append(gpa, tile);
    }
};

/// The tiles each light's shadow had, and what was drawn into them, kept
/// from draw to draw: a view whose light and casters are as they were is
/// not drawn again.
pub const Cache = struct {
    tiles: Tiles,
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// Counted up by each plan, and by each frame: what a plan has not used
    /// may be given up for room, and a light's tile changes size no more
    /// than once a frame, however many views draw it.
    draw: u64 = 0,
    frame: u64 = 0,

    /// A light - a lamp's entity, or a sun's place among the frame's - and
    /// one of its views.
    pub const Key = struct { light: u64, face: u32 };

    pub const Entry = struct {
        tile: Tile,
        /// What was drawn into it last; nought for nothing yet.
        signature: u64 = 0,
        used: u64 = 0,
        sized: u64 = 0,
    };

    pub fn init(gpa: Allocator, atlas: u32) Allocator.Error!Cache {
        return .{ .tiles = try .init(gpa, atlas) };
    }

    pub fn deinit(self: *Cache, gpa: Allocator) void {
        self.tiles.deinit(gpa);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// The tiles of `count` views of `light`, about `size` each: the ones it
    /// had, where they are near that size, or new ones - smaller where there
    /// is no room, once what no view of this plan uses is given up.
    pub fn tilesFor(self: *Cache, gpa: Allocator, light: u64, count: u32, size: u32, out: []Tile) Allocator.Error!bool {
        const views = out[0..count];
        kept: {
            var held_size: u32 = 0;
            for (0..count) |face| {
                const entry = self.entries.getPtr(.{ .light = light, .face = @intCast(face) }) orelse break :kept;
                if (face > 0 and entry.tile.size != held_size) break :kept;
                held_size = entry.tile.size;
            }
            // Within twice or half what it wants, it keeps what it has - and
            // whatever it wants, once a frame has sized it.
            const first = self.entries.getPtr(.{ .light = light, .face = 0 }).?;
            if (first.sized != self.frame and (held_size * 2 < size or held_size > size * 2)) break :kept;
            for (views, 0..) |*tile, face| {
                const entry = self.entries.getPtr(.{ .light = light, .face = @intCast(face) }).?;
                entry.used = self.draw;
                tile.* = entry.tile;
            }
            return true;
        }
        try self.forget(gpa, light, count);
        var want = size;
        while (want >= self.tiles.unit) {
            if (try self.tiles.takeMany(gpa, want, views)) {
                for (views, 0..) |tile, face| {
                    try self.entries.put(gpa, .{ .light = light, .face = @intCast(face) }, .{ .tile = tile, .used = self.draw, .sized = self.frame });
                }
                return true;
            }
            if (!try self.giveUpOldest(gpa)) want /= 2;
        }
        return false;
    }

    /// The tiles of `light`'s first `count` views - and any after - given back.
    fn forget(self: *Cache, gpa: Allocator, light: u64, count: u32) Allocator.Error!void {
        var face: u32 = 0;
        while (face < @max(count, 6)) : (face += 1) {
            const gone = self.entries.fetchRemove(.{ .light = light, .face = face }) orelse continue;
            try self.tiles.give(gpa, gone.value.tile);
        }
    }

    /// The tile no view of this plan uses that was used longest ago, given
    /// back; false when every tile is this plan's.
    fn giveUpOldest(self: *Cache, gpa: Allocator) Allocator.Error!bool {
        var oldest: ?Key = null;
        var when: u64 = std.math.maxInt(u64);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.used == self.draw or entry.value_ptr.used >= when) continue;
            when = entry.value_ptr.used;
            oldest = entry.key_ptr.*;
        }
        const key = oldest orelse return false;
        try self.forget(gpa, key.light, 1);
        return true;
    }
};

/// A sun's key in the cache: its place among the frame's suns, set apart
/// from every entity's.
pub fn sunKey(index: u32) u64 {
    return 0xFFFF_FFFF_0000_0000 | @as(u64, index);
}

/// What a frame's shadows are: the views drawn into the atlas, and what the
/// shader is told of them.
pub const Plan = struct {
    views: std.ArrayList(View) = .empty,
    block: Shadows = .none(),

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        self.views.deinit(gpa);
        self.* = undefined;
    }
};

/// How the plan is made.
pub const Options = struct {
    /// The atlas's size, a side.
    atlas: u32,
    filter: Filter,
    /// The device's clip space, which the tiles are drawn in.
    clip: math.Clip,
    /// Whether the device stores a picture drawn into bottom row first.
    bottom_left: bool,
};

/// Work out every view `suns` and `lamps` need, seen from `camera`, into
/// `plan`, with the tiles `cache` keeps for them: suns first, then lamps in
/// the order given - the one lighting most of the picture first - each
/// taking what room is left. The cache's atlas is `options.atlas` a side.
pub fn plan(gpa: Allocator, out: *Plan, cache: *Cache, camera: View3D, suns: []const Sun, lamps: []const Lamp, options: Options) Allocator.Error!void {
    out.views.clearRetainingCapacity();
    out.block = .none();
    cache.draw += 1;
    const block = &out.block;
    const size: f32 = @floatFromInt(options.atlas);
    block.atlas = .{ 1 / size, @floatFromInt(options.filter.taps()), size, 0 };
    var tiles: [6]Tile = undefined;

    for (suns) |sun| {
        const count = std.math.clamp(sun.cascades, 1, 4);
        const wanted = if (count == 1) options.atlas / 2 else options.atlas / 4;
        const first = out.views.items.len;
        if (first + count > most_views) break;
        const splits = cascadeSplits(camera, count, sun.max_distance);
        if (!try cache.tilesFor(gpa, sunKey(sun.index), count, wanted, &tiles)) continue;
        var start = camera.near;
        for (0..count) |cascade| {
            const end = splits[cascade];
            try addCascade(gpa, out, camera, sun.toward, start, end, @max(sun.max_distance, 1), tiles[cascade], options);
            out.views.items[out.views.items.len - 1].key = .{ .light = sunKey(sun.index), .face = @intCast(cascade) };
            start = end;
        }
        const reach = @min(sun.max_distance, camera.far);
        block.suns[sun.index] = .{ @floatFromInt(first), @floatFromInt(count), sun.settings.bias, sun.settings.normal_bias };
        block.sun_splits[sun.index] = splits;
        block.sun_softness[sun.index] = .{ sun.settings.blur * options.filter.radius(), sun.settings.size, reach * 0.9, reach };
    }

    for (lamps) |lamp| {
        const faces: u32 = if (lamp.spot == null) 6 else 1;
        const first = out.views.items.len;
        if (first + faces > most_views) break;
        const base = if (lamp.spot == null) options.atlas / 16 else options.atlas / 8;
        const wanted = lampTile(base, lamp.range, lamp.distance);
        // Every face of a point light is one size.
        if (!try cache.tilesFor(gpa, lamp.light, faces, wanted, &tiles)) continue;
        if (lamp.spot) |spot| {
            try addSpot(gpa, out, lamp, spot.aim, spot.angle, tiles[0], options);
        } else for (0..faces) |face| {
            try addFace(gpa, out, lamp, @intCast(face), tiles[face], options);
        }
        for (out.views.items[first..], 0..) |*made, face| made.key = .{ .light = lamp.light, .face = @intCast(face) };
        block.lamps[lamp.index] = .{ @floatFromInt(first), @floatFromInt(faces), lamp.settings.bias, lamp.settings.normal_bias };
        block.lamp_softness[lamp.index] = .{ lamp.settings.blur * options.filter.radius(), lamp.settings.size, 0, 0 };
    }
}

/// How large a lamp's tile is: `base` for one whose light reaches the
/// camera, smaller the further it is for the light it gives.
fn lampTile(base: u32, range: f32, distance: f32) u32 {
    const near = range / @max(distance, 0.001);
    if (near >= 1) return base;
    if (near >= 0.4) return base / 2;
    if (near >= 0.15) return base / 4;
    return base / 8;
}

/// Where along the camera's view each of `count` cascades ends: closer
/// together near it, where a texel covers less, up to `max_distance`.
pub fn cascadeSplits(camera: View3D, count: u32, max_distance: f32) [4]f32 {
    const near = @max(camera.near, 0.0001);
    const far = @max(@min(camera.far, max_distance), near + 0.001);
    var splits: [4]f32 = @splat(std.math.floatMax(f32));
    for (0..count) |i| {
        const f = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(count));
        const even = near + (far - near) * f;
        const spread = near * std.math.pow(f32, far / near, f);
        splits[i] = if (camera.projection == .perspective) std.math.lerp(even, spread, 0.75) else even;
    }
    splits[count - 1] = far;
    return splits;
}

/// The smallest sphere round what the camera sees from `start` to `end`
/// along its view: what a cascade's tile covers. Its radius does not change
/// as the camera turns.
pub fn sliceSphere(camera: View3D, start: f32, end: f32) math.Sphere {
    const forward = camera.forward();
    const right = camera.right();
    const up = camera.up();
    const aspect = if (camera.height > 0) camera.width / camera.height else 1;
    var corners: [8]Vec3 = undefined;
    for ([_]f32{ start, end }, 0..) |d, at| {
        const half_height = if (camera.projection == .perspective) @tan(std.math.clamp(camera.fov, 0.001, std.math.pi - 0.001) / 2) * d else @max(camera.size, 0.0001) / 2;
        const half_width = half_height * aspect;
        const middle = camera.position.add(forward.scale(d));
        for (0..4) |i| {
            const sx: f32 = if (i & 1 == 0) -1 else 1;
            const sy: f32 = if (i & 2 == 0) -1 else 1;
            corners[at * 4 + i] = middle.add(right.scale(sx * half_width)).add(up.scale(sy * half_height));
        }
    }
    var center: Vec3 = .zero;
    for (corners) |c| center = center.add(c);
    center = center.scale(1.0 / 8.0);
    var radius: f32 = 0;
    for (corners) |c| radius = @max(radius, c.sub(center).len());
    // Rounded up, so it holds still as the camera turns.
    radius = @ceil(radius * 16) / 16;
    return .{ .center = center, .radius = radius };
}

/// One cascade of a sun shining from `toward`, covering what the camera sees
/// from `start` to `end`, and what casts into it from up to `reach` further
/// toward the sun.
fn addCascade(gpa: Allocator, out: *Plan, camera: View3D, toward: Vec3, start: f32, end: f32, reach: f32, tile: Tile, options: Options) Allocator.Error!void {
    const sphere = sliceSphere(camera, start, end);
    const r = sphere.radius;
    const shine = toward.norm().neg();
    const turn = math.proj.lookTowards(.zero, shine, upFor(shine), .right);
    // The middle, in the sun's own space, moved to a whole texel, so what
    // stands still in the world stands still in the atlas as the camera moves.
    const middle = turn.mulVec4(sphere.center.vec4(1));
    const texel = 2 * r / @as(f32, @floatFromInt(tile.size));
    const x = @floor(middle.x / texel) * texel;
    const y = @floor(middle.y / texel) * texel;
    // The camera's slice is `-middle.z` along the sun's way, give or take
    // `r`, and what casts into it stands up to `reach` before.
    const along = -middle.z;
    const near = along - r - @max(reach, 2 * r);
    const far = along + r;
    const box: Box = .{ .left = x - r, .right = x + r, .bottom = y - r, .top = y + r, .near = near, .far = far };
    const render = box.matrix(options.clip).mul(turn);
    const lookup = atlasOf(tile, options).mul(box.matrix(.d3d)).mul(turn);
    try add(gpa, out, render, lookup, tile, .{ near, far, texel, 0 }, null, options);
}

const Box = struct {
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near: f32,
    far: f32,

    fn matrix(self: Box, clip: math.Clip) Mat4 {
        return math.orthographic(.{ .left = self.left, .right = self.right, .bottom = self.bottom, .top = self.top, .near = self.near, .far = self.far, .clip = clip });
    }
};

/// How much wider than the cone a tile looks, so a filter's readings near
/// its edge stay inside the tile: a few texels either side.
fn widened(half_angle: f32, size: u32) f32 {
    const border: f32 = @floatFromInt(@min(8, size / 8));
    const s: f32 = @floatFromInt(size);
    return std.math.atan(@tan(half_angle) * s / (s - 2 * border));
}

/// Where a lamp's view starts: near enough for what is close to it, far
/// enough to keep the depth precise.
fn nearOf(range: f32) f32 {
    return std.math.clamp(range / 500, 0.02, 0.5);
}

fn addSpot(gpa: Allocator, out: *Plan, lamp: Lamp, aim: Vec3, angle: f32, tile: Tile, options: Options) Allocator.Error!void {
    const half = widened(std.math.clamp(angle, 0.001, std.math.degreesToRadians(89.9)), tile.size);
    try addPerspective(gpa, out, lamp, aim, half, tile, options);
}

/// The six ways a point light's faces look, in the order the shader picks
/// them: +x, -x, +y, -y, +z, -z.
const face_ways = [_]Vec3{ .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1) };

fn addFace(gpa: Allocator, out: *Plan, lamp: Lamp, face: u32, tile: Tile, options: Options) Allocator.Error!void {
    try addPerspective(gpa, out, lamp, face_ways[face], widened(std.math.pi / 4.0, tile.size), tile, options);
}

fn addPerspective(gpa: Allocator, out: *Plan, lamp: Lamp, way: Vec3, half_angle: f32, tile: Tile, options: Options) Allocator.Error!void {
    const look = math.proj.lookTowards(lamp.place, way, upFor(way), .right);
    const near = nearOf(lamp.range);
    const far = @max(lamp.range, near + 0.01);
    const lens: Lens = .{ .fov = 2 * half_angle, .near = near, .far = far };
    const render = lens.matrix(options.clip).mul(look);
    const lookup = atlasOf(tile, options).mul(lens.matrix(.d3d)).mul(look);
    const texel = 2 * @tan(half_angle) / @as(f32, @floatFromInt(tile.size));
    try add(gpa, out, render, lookup, tile, .{ near, far, texel, 1 }, .init(lamp.place, lamp.range), options);
}

const Lens = struct {
    fov: f32,
    near: f32,
    far: f32,

    fn matrix(self: Lens, clip: math.Clip) Mat4 {
        return math.perspective(.{ .fov_y = self.fov, .aspect = 1, .near = self.near, .far = self.far, .clip = clip });
    }
};

/// Some way that is not `way`, to stand a view up by.
fn upFor(way: Vec3) Vec3 {
    return if (@abs(way.y) > 0.9) .init(0, 0, 1) else .init(0, 1, 0);
}

fn add(gpa: Allocator, out: *Plan, render: Mat4, lookup: Mat4, tile: Tile, info: [4]f32, reach: ?math.Sphere, options: Options) Allocator.Error!void {
    const at = out.views.items.len;
    out.block.matrices[at] = lookup;
    out.block.rects[at] = rectOf(tile, options);
    out.block.views[at] = info;
    try out.views.append(gpa, .{ .render = render, .tile = tile, .frustum = .fromViewProjection(render, options.clip), .reach = reach });
}

/// From Direct3D's clip space to the atlas: across and down `tile`, the
/// depth as it is, and turned over for a device that stores what is drawn
/// bottom row first.
fn atlasOf(tile: Tile, options: Options) Mat4 {
    const atlas: f32 = @floatFromInt(options.atlas);
    const s = @as(f32, @floatFromInt(tile.size)) / atlas;
    const ox = @as(f32, @floatFromInt(tile.x)) / atlas;
    const oy = @as(f32, @floatFromInt(tile.y)) / atlas;
    const down: Vec4 = if (options.bottom_left) .init(0, 0.5 * s, 0, 1 - 0.5 * s - oy) else .init(0, -0.5 * s, 0, 0.5 * s + oy);
    return .fromRows(.init(0.5 * s, 0, 0, 0.5 * s + ox), down, .init(0, 0, 1, 0), .init(0, 0, 0, 1));
}

/// The part of the atlas a tile is read in, a texel in from its edge.
fn rectOf(tile: Tile, options: Options) [4]f32 {
    const atlas: f32 = @floatFromInt(options.atlas);
    const x0 = (@as(f32, @floatFromInt(tile.x)) + 1) / atlas;
    const y0 = (@as(f32, @floatFromInt(tile.y)) + 1) / atlas;
    const x1 = (@as(f32, @floatFromInt(tile.x + tile.size)) - 1) / atlas;
    const y1 = (@as(f32, @floatFromInt(tile.y + tile.size)) - 1) / atlas;
    return if (options.bottom_left) .{ x0, 1 - y1, x1, 1 - y0 } else .{ x0, y0, x1, y1 };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Where `p` is in the atlas, seen through view `at`.
fn seen(block: *const Shadows, at: usize, p: Vec3) Vec3 {
    const s = block.matrices[at].mulVec4(p.vec4(1));
    return .init(s.x / s.w, s.y / s.w, s.z / s.w);
}

fn inside(block: *const Shadows, at: usize, uv: Vec3) bool {
    const r = block.rects[at];
    return uv.x >= r[0] and uv.x <= r[2] and uv.y >= r[1] and uv.y <= r[3];
}

fn overlap(a: Tile, b: Tile) bool {
    return a.x < b.x + b.size and b.x < a.x + a.size and a.y < b.y + b.size and b.y < a.y + a.size;
}

test "tiles are taken without overlapping, run out, and join again when given back" {
    var tiles: Tiles = try .init(testing.allocator, 1024);
    defer tiles.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), tiles.unit);
    var taken: [8]Tile = undefined;
    taken[0] = (try tiles.take(testing.allocator, 512)).?;
    taken[1] = (try tiles.take(testing.allocator, 256)).?;
    taken[2] = (try tiles.take(testing.allocator, 256)).?;
    taken[3] = (try tiles.take(testing.allocator, 128)).?;
    taken[4] = (try tiles.take(testing.allocator, 512)).?;
    taken[5] = (try tiles.take(testing.allocator, 512)).?;
    for (taken[0..6], 0..) |a, i| for (taken[i + 1 .. 6]) |b| try testing.expect(!overlap(a, b));
    try testing.expectEqual(@as(u32, 128), taken[3].size);
    // A quarter is left, but split: no 512 fits.
    try testing.expect((try tiles.take(testing.allocator, 512)) == null);
    // Given back, the 256s and the 128 join into what they were split from.
    for (taken[1..4]) |tile| try tiles.give(testing.allocator, tile);
    taken[6] = (try tiles.take(testing.allocator, 512)).?;
    try testing.expectEqual(@as(u32, 512), taken[6].size);
    try testing.expect((try tiles.take(testing.allocator, 16)) == null);
}

test "a light keeps its tiles from draw to draw, and one not drawn gives them up for room" {
    var cache: Cache = try .init(testing.allocator, 1024);
    defer cache.deinit(testing.allocator);
    var tiles: [6]Tile = undefined;
    cache.draw = 1;
    try testing.expect(try cache.tilesFor(testing.allocator, 7, 1, 512, &tiles));
    const first = tiles[0];
    // Near the size it had, the same tile; drawn into, it says what was.
    cache.draw = 2;
    cache.frame = 1;
    cache.entries.getPtr(.{ .light = 7, .face = 0 }).?.signature = 99;
    try testing.expect(try cache.tilesFor(testing.allocator, 7, 1, 256, &tiles));
    try testing.expectEqual(first, tiles[0]);
    try testing.expectEqual(@as(u64, 99), cache.entries.get(.{ .light = 7, .face = 0 }).?.signature);
    // Others fill the rest; light 7 is not drawn in this plan, so it gives
    // up its tile when nothing else is left.
    cache.draw = 3;
    for (8..11) |light| try testing.expect(try cache.tilesFor(testing.allocator, light, 1, 512, &tiles));
    try testing.expect(try cache.tilesFor(testing.allocator, 11, 1, 512, &tiles));
    try testing.expect(cache.entries.get(.{ .light = 7, .face = 0 }) == null);
    // Four times the size it has, it gets a new one, drawn into from nothing.
    cache.draw = 4;
    cache.frame = 2;
    try testing.expect(try cache.tilesFor(testing.allocator, 12, 6, 32, &tiles));
    try testing.expect(try cache.tilesFor(testing.allocator, 12, 6, 32, &tiles));
    try testing.expectEqual(@as(u32, 32), tiles[5].size);
}

test "a spot light's view puts what it shines on in its tile, nearer smaller" {
    var out: Plan = .{};
    defer out.deinit(testing.allocator);
    const camera: View3D = .{ .position = .init(0, 0, 10) };
    const lamp: Lamp = .{ .index = 3, .place = .init(0, 5, 0), .range = 20, .spot = .{ .aim = .init(0, -1, 0), .angle = 0.5 }, .settings = .{}, .distance = 11 };
    var cache: Cache = try .init(testing.allocator, 2048);
    defer cache.deinit(testing.allocator);
    try plan(testing.allocator, &out, &cache, camera, &.{}, &.{lamp}, .{ .atlas = 2048, .filter = .soft_medium, .clip = .gl, .bottom_left = false });
    try testing.expectEqual(@as(usize, 1), out.views.items.len);
    try testing.expectEqual(@as(f32, 0), out.block.lamps[3][0]);
    try testing.expectEqual(@as(f32, -1), out.block.lamps[0][0]);

    // Straight below it: the middle of its tile.
    const below = seen(&out.block, 0, .init(0, 0, 0));
    const tile = out.views.items[0].tile;
    const middle = (@as(f32, @floatFromInt(tile.x)) + @as(f32, @floatFromInt(tile.size)) / 2) / 2048;
    try testing.expectApproxEqAbs(middle, below.x, 0.0001);
    try testing.expect(inside(&out.block, 0, below));
    // Nearer the light is less deep.
    const higher = seen(&out.block, 0, .init(0, 2, 0));
    try testing.expect(higher.z < below.z and higher.z > 0 and below.z < 1);
    // Well outside the cone is outside the tile.
    try testing.expect(!inside(&out.block, 0, seen(&out.block, 0, .init(10, 0, 0))));
}

test "a point light's six faces each see the side the shader picks for them" {
    var out: Plan = .{};
    defer out.deinit(testing.allocator);
    const lamp: Lamp = .{ .index = 0, .place = .init(1, 2, 3), .range = 10, .settings = .{}, .distance = 5 };
    var cache: Cache = try .init(testing.allocator, 2048);
    defer cache.deinit(testing.allocator);
    try plan(testing.allocator, &out, &cache, .{}, &.{}, &.{lamp}, .{ .atlas = 2048, .filter = .soft_medium, .clip = .d3d, .bottom_left = true });
    try testing.expectEqual(@as(usize, 6), out.views.items.len);
    try testing.expectEqual(@as(f32, 6), out.block.lamps[0][1]);
    for (face_ways, 0..) |way, face| {
        const p = lamp.place.add(way.scale(4)).add(.init(0.3, -0.2, 0.1));
        const uv = seen(&out.block, face, p);
        try testing.expect(inside(&out.block, face, uv));
        try testing.expect(uv.z > 0 and uv.z < 1);
        try testing.expectEqual(out.views.items[0].tile.size, out.views.items[face].tile.size);
    }
}

test "a sun's cascades end further apart further away, and cover what the camera sees" {
    const camera: View3D = .{ .position = .init(0, 2, 0), .near = 0.1, .far = 500, .width = 16, .height = 9 };
    const splits = cascadeSplits(camera, 4, 100);
    try testing.expect(splits[0] < splits[1] and splits[1] < splits[2]);
    try testing.expectEqual(@as(f32, 100), splits[3]);
    try testing.expect(splits[1] - splits[0] < splits[3] - splits[2]);

    var out: Plan = .{};
    defer out.deinit(testing.allocator);
    const sun: Sun = .{ .index = 1, .toward = .init(0.3, 1, 0.2), .settings = .{}, .cascades = 4, .max_distance = 100 };
    var cache: Cache = try .init(testing.allocator, 4096);
    defer cache.deinit(testing.allocator);
    try plan(testing.allocator, &out, &cache, camera, &.{sun}, &.{}, .{ .atlas = 4096, .filter = .hard, .clip = .gl, .bottom_left = true });
    try testing.expectEqual(@as(usize, 4), out.views.items.len);
    try testing.expectEqual(@as(f32, 0), out.block.suns[1][0]);
    try testing.expectEqual(@as(f32, 4), out.block.suns[1][1]);
    try testing.expectEqual(@as(f32, -1), out.block.suns[0][0]);
    // A point a little ahead of the camera is in the first cascade's tile,
    // and one further on in the last's.
    const ahead = camera.position.add(camera.forward().scale(2));
    try testing.expect(inside(&out.block, 0, seen(&out.block, 0, ahead)));
    const far = camera.position.add(camera.forward().scale(90));
    try testing.expect(inside(&out.block, 3, seen(&out.block, 3, far)));

    // The slice's sphere is as large whichever way the camera looks.
    var turned = camera;
    turned.rotation = math.Quat.fromAxisAngle(.init(0, 1, 0), 1.1);
    try testing.expectEqual(sliceSphere(camera, 1, 9).radius, sliceSphere(turned, 1, 9).radius);
}

test "a point light that does not fit at its size gets six smaller faces" {
    var out: Plan = .{};
    defer out.deinit(testing.allocator);
    var lamps: [64]Lamp = undefined;
    // Sixty-three spot lights near the camera, 128 a side each in a 1024
    // atlas, leave room for one more of them.
    for (lamps[0..63], 0..) |*lamp, i| lamp.* = .{ .index = @intCast(i), .light = i, .place = .zero, .range = 5, .spot = .{ .aim = .init(0, -1, 0), .angle = 0.6 }, .settings = .{}, .distance = 0 };
    lamps[63] = .{ .index = 63, .light = 63, .place = .zero, .range = 5, .settings = .{}, .distance = 0 };
    var cache: Cache = try .init(testing.allocator, 1024);
    defer cache.deinit(testing.allocator);
    try plan(testing.allocator, &out, &cache, .{}, &.{}, &lamps, .{ .atlas = 1024, .filter = .soft_low, .clip = .d3d, .bottom_left = false });
    try testing.expectEqual(@as(usize, 63 + 6), out.views.items.len);
    try testing.expectEqual(@as(f32, 63), out.block.lamps[63][0]);
    const face = out.views.items[63].tile.size;
    try testing.expect(face < 64);
    for (out.views.items[63..]) |view| try testing.expectEqual(face, view.tile.size);
}
