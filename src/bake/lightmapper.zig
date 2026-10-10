// SPDX-License-Identifier: BSD-3-Clause

//! The lightmap baker: the light from everywhere on a world's still meshes,
//! worked out by tracing rays, into a picture of their lightmap UVs side by
//! side, and a grid of probes for the meshes that move.
//!
//! It is given plain numbers - triangles in the world, their materials and
//! pictures, the lights and the sky - and gives back plain numbers. The
//! engine gathers them from its world and keeps what comes back as a
//! `.lightmap` (`render/lightmap_bake.zig`). It is built for speed whatever
//! the engine is built as, since tracing rays is nearly all it does.
//!
//! Light is counted as the engine's shader counts it: a surface of albedo
//! `a` lit by `E` shows `a * E`, a light of colour `c` falling at `n . l`
//! lights it by `c * (n . l)`, and the sky lights an open floor by its
//! colour. What a texel holds is that `E`: the sky's light, the lights'
//! own on it where they are baked whole, and every light bounced to it.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const bvh = @import("bvh.zig");
const Vec3 = bvh.Vec3;
const dot = bvh.dot;
const cross = bvh.cross;
const length = bvh.length;
const normalize = bvh.normalize;
const splat = bvh.splat;
const vec = bvh.vec;

/// A picture a material or a light reads: four bytes a texel, its colours
/// as they are stored (sRGB), its top row first.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const Material = struct {
    /// Linear, times its picture's where it has one: what a bounce keeps
    /// of the light.
    albedo: [3]f32 = .{ 1, 1, 1 },
    albedo_image: ?u32 = null,
    /// Linear, its energy counted in, times its picture's: what it gives off.
    emission: [3]f32 = .{ 0, 0, 0 },
    emission_image: ?u32 = null,
    /// Its picture's alpha times this under `cut` is not there: a hole a
    /// ray passes through. Null for a material with none.
    alpha: f32 = 1,
    cut: ?f32 = null,
    /// Whether its back is a side of its own; a back that is not is the
    /// inside of something, and dark.
    two_sided: bool = false,
};

/// A mesh baked: the triangles that name it make it.
pub const Instance = struct {
    /// Whether it has a place in the lightmap: one with lightmap UVs. One
    /// without still stands in the light's way and bounces it.
    lit: bool,
    /// How many texels across its lightmap UVs need at least: what keeps
    /// their charts apart.
    least_texels: u32,
};

/// One triangle, in the world.
pub const Triangle = struct {
    positions: [3][3]f32,
    normals: [3][3]f32,
    uvs: [3][2]f32,
    lightmap_uvs: [3][2]f32,
    instance: u32,
    material: u32,
};

/// How much of a lamp's light reaches `d` from it, by its range.
pub fn lampFade(light: Light, d: f32) f32 {
    if (light.by_distance) {
        var near = d / light.range;
        near = near * near;
        near = @max(1 - near * near, 0);
        return near * near * std.math.pow(f32, @max(d, 0.0001), -light.attenuation);
    }
    return std.math.pow(f32, @max(1 - d / light.range, 0), light.attenuation);
}

/// How much of a spot light's light is left `cosine` from its way, by its
/// cone.
pub fn coneFade(light: Light, cosine: f32) f32 {
    if (light.by_distance) {
        const rim = @max((1 - @max(cosine, light.cone)) / @max(1 - light.cone, 0.0001), 0.0001);
        return 1 - std.math.pow(f32, rim, light.cone_attenuation);
    }
    const t = std.math.clamp((cosine - light.cone) / @max(1 - light.cone, 0.0001), 0, 1);
    return std.math.pow(f32, t, light.cone_attenuation);
}

pub const Light = struct {
    kind: Kind,
    /// Where a lamp is.
    position: [3]f32 = .{ 0, 0, 0 },
    /// Toward a sun; the way a spot light shines.
    direction: [3]f32 = .{ 0, -1, 0 },
    /// Linear, its energy counted in.
    color: [3]f32,
    range: f32 = 0,
    attenuation: f32 = 1,
    /// The cosine of a spot light's edge, and how it fades toward it.
    cone: f32 = -1,
    cone_attenuation: f32 = 1,
    /// Whether it falls off with the distance - `attenuation` the power -
    /// rather than toward its range: see the engine's `Falloff`.
    by_distance: bool = false,
    /// How big a lamp is across, in units; how wide a sun looks, in radians.
    size: f32 = 0,
    /// A cookie's top, and how wide a spot light's is: the tangent of half
    /// its cone.
    up: [3]f32 = .{ 0, 1, 0 },
    spread: f32 = 1,
    cookie: ?u32 = null,
    /// Whether its own light on a texel is baked; its light bounced always
    /// is. A light baked whole is not drawn over the lightmap.
    direct: bool,

    pub const Kind = enum { sun, point, spot };
};

pub const Scene = struct {
    triangles: []const Triangle,
    instances: []const Instance,
    materials: []const Material,
    images: []const Image,
    lights: []const Light,
};

pub const Settings = struct {
    /// How many texels a unit of surface has, across.
    texels_per_unit: f32 = 8,
    /// The most texels the lightmap is across.
    max_size: u32 = 2048,
    /// How many times light bounces.
    bounces: u32 = 3,
    /// How many rays a texel sends for the light bounced to it.
    rays: u32 = 64,
    /// How many rays a light that has a size is looked at with.
    light_rays: u32 = 16,
    denoise: bool = true,
    /// How far apart the probes are.
    probe_spacing: f32 = 2,
    /// The light of the sky, where a ray meets nothing.
    sky: [3]f32 = .{ 0, 0, 0 },
    seed: u64 = 0x5EED,
    /// How many threads to bake on, the calling one counted; nought for
    /// one a core.
    threads: u32 = 0,
};

/// What was baked.
pub const Result = struct {
    width: u32,
    height: u32,
    /// Linear light, red, green and blue a texel, its top row first.
    pixels: [][3]f32,
    /// Each instance's place in the picture: its lightmap UVs times `x`
    /// and `y`, moved by `z` and `w`. Nought for one not in it.
    places: [][4]f32,
    probes: Probes,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.pixels);
        gpa.free(self.places);
        self.probes.deinit(gpa);
        self.* = undefined;
    }
};

/// A grid of probes: the light from everywhere at each, as twelve numbers.
pub const Probes = struct {
    /// Where the first is, how far apart they are, and how many each way.
    origin: [3]f32 = .{ 0, 0, 0 },
    spacing: f32 = 1,
    counts: [3]u32 = .{ 0, 0, 0 },
    /// `x` fastest, then `y`, then `z`: red, green and blue, each how lit a
    /// surface facing `n` is as `c0 + c1 n.x + c2 n.y + c3 n.z`.
    samples: [][12]f32 = &.{},
    /// Whether each is in the open; one inside something is not read.
    valid: []bool = &.{},

    pub fn deinit(self: *Probes, gpa: Allocator) void {
        gpa.free(self.samples);
        gpa.free(self.valid);
        self.* = .{};
    }
};

pub const Stage = enum(u8) { preparing, lighting, finishing, probes, done };

pub const Progress = struct {
    stage: Stage,
    done: u64,
    total: u64,
};

/// How a bake is followed and stopped from another thread.
pub const Control = struct {
    stage: std.atomic.Value(u8) = .init(@intFromEnum(Stage.preparing)),
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn progress(self: *const Control) Progress {
        return .{
            .stage = @enumFromInt(self.stage.load(.acquire)),
            .done = self.done.load(.acquire),
            .total = self.total.load(.acquire),
        };
    }

    fn begin(self: *Control, stage: Stage, total: u64) void {
        self.done.store(0, .release);
        self.total.store(total, .release);
        self.stage.store(@intFromEnum(stage), .release);
    }
};

/// A bake on a thread of its own, from `start` to `finish`.
pub const Bake = struct {
    gpa: Allocator,
    scene: Scene,
    settings: Settings,
    control: Control = .{},
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    outcome: (Allocator.Error || error{Cancelled})!Result = error.Cancelled,

    /// Start baking `scene`, which must stay as it is until `finish`. The
    /// work goes on threads of its own; without threads it is done here.
    pub fn start(gpa: Allocator, scene: Scene, settings: Settings) (Allocator.Error || std.Thread.SpawnError)!*Bake {
        const self = try gpa.create(Bake);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .scene = scene, .settings = settings };
        if (builtin.single_threaded) {
            run(self);
        } else {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }
        return self;
    }

    fn run(self: *Bake) void {
        self.outcome = bake(self.gpa, self.scene, self.settings, &self.control);
        self.control.stage.store(@intFromEnum(Stage.done), .release);
        self.finished.store(true, .release);
    }

    pub fn progress(self: *const Bake) Progress {
        return self.control.progress();
    }

    /// Ask it to stop: `finish` then says `error.Cancelled`.
    pub fn cancel(self: *Bake) void {
        self.control.cancelled.store(true, .release);
    }

    pub fn isFinished(self: *const Bake) bool {
        return self.finished.load(.acquire);
    }

    /// Wait for it, and let it go: what it baked, the caller's.
    pub fn finish(self: *Bake) (Allocator.Error || error{Cancelled})!Result {
        if (self.thread) |thread| thread.join();
        const outcome = self.outcome;
        self.gpa.destroy(self);
        return outcome;
    }
};

/// Bake `scene` on this thread and as many more as `settings` says,
/// following `control`.
pub fn bake(gpa: Allocator, scene: Scene, settings: Settings, control: *Control) (Allocator.Error || error{Cancelled})!Result {
    var world = try World.init(gpa, scene, settings);
    defer world.deinit(gpa);
    if (control.cancelled.load(.acquire)) return error.Cancelled;

    var atlas = try Atlas.init(gpa, &world, settings);
    defer atlas.deinit(gpa);

    // Each texel's light: what falls straight on it, and what is bounced.
    control.begin(.lighting, atlas.texels.items.len);
    const direct = try gpa.alloc(Vec3, atlas.texels.items.len);
    defer gpa.free(direct);
    const bounced = try gpa.alloc(Vec3, atlas.texels.items.len);
    defer gpa.free(bounced);
    const inside = try gpa.alloc(bool, atlas.texels.items.len);
    defer gpa.free(inside);
    {
        var job: TexelJob = .{ .world = &world, .atlas = &atlas, .direct = direct, .bounced = bounced, .inside = inside };
        parallel(TexelJob, &job, atlas.texels.items.len, settings.threads, control);
    }
    if (control.cancelled.load(.acquire)) return error.Cancelled;

    control.begin(.finishing, 1);
    if (settings.denoise) try denoise(gpa, &atlas, bounced, inside);
    const pixels = try gpa.alloc([3]f32, @as(usize, atlas.size) * atlas.size);
    errdefer gpa.free(pixels);
    try atlas.fill(gpa, pixels, direct, bounced, inside);
    control.done.store(1, .release);

    var probes = try bakeProbes(gpa, &world, settings, control);
    errdefer probes.deinit(gpa);
    if (control.cancelled.load(.acquire)) return error.Cancelled;

    const places = try gpa.alloc([4]f32, scene.instances.len);
    errdefer gpa.free(places);
    const size: f32 = @floatFromInt(atlas.size);
    for (places, atlas.rects) |*place, rect| {
        place.* = if (rect.size == 0) @splat(0) else .{
            @as(f32, @floatFromInt(rect.size)) / size,
            @as(f32, @floatFromInt(rect.size)) / size,
            @as(f32, @floatFromInt(rect.x)) / size,
            @as(f32, @floatFromInt(rect.y)) / size,
        };
    }
    return .{ .width = atlas.size, .height = atlas.size, .pixels = pixels, .places = places, .probes = probes };
}

// -------------------------------------------------------------------------
// The world, as rays meet it
// -------------------------------------------------------------------------

const World = struct {
    scene: Scene,
    settings: Settings,
    tree: bvh.Bvh,
    /// Each triangle's way, by its corners' order.
    faces: []Vec3,
    /// The box round everything, and how far a ray starts off a surface.
    lo: Vec3,
    hi: Vec3,
    lift: f32,

    fn init(gpa: Allocator, scene: Scene, settings: Settings) Allocator.Error!World {
        const corners = try gpa.alloc(bvh.Triangle, scene.triangles.len);
        defer gpa.free(corners);
        const faces = try gpa.alloc(Vec3, scene.triangles.len);
        errdefer gpa.free(faces);
        var lo = splat(std.math.floatMax(f32));
        var hi = splat(-std.math.floatMax(f32));
        for (scene.triangles, corners, faces) |t, *c, *f| {
            c.* = .{ vec(t.positions[0]), vec(t.positions[1]), vec(t.positions[2]) };
            f.* = normalize(cross(c[1] - c[0], c[2] - c[0]));
            for (c) |p| {
                lo = @min(lo, p);
                hi = @max(hi, p);
            }
        }
        if (scene.triangles.len == 0) {
            lo = splat(0);
            hi = splat(0);
        }
        const tree = try bvh.Bvh.build(gpa, corners);
        return .{
            .scene = scene,
            .settings = settings,
            .tree = tree,
            .faces = faces,
            .lo = lo,
            .hi = hi,
            .lift = @max(length(hi - lo) * 2e-5, 1e-4),
        };
    }

    fn deinit(self: *World, gpa: Allocator) void {
        self.tree.deinit(gpa);
        gpa.free(self.faces);
    }

    /// The filter that lets rays through the holes in what is cut.
    fn holes(self: *const World) Holes {
        return .{ .world = self };
    }

    const Holes = struct {
        world: *const World,

        pub fn keeps(self: Holes, triangle: u32, u: f32, v: f32) bool {
            const t = self.world.scene.triangles[triangle];
            const m = self.world.scene.materials[t.material];
            const cut = m.cut orelse return true;
            const image = m.albedo_image orelse return m.alpha >= cut;
            const uv = mix2(t.uvs, u, v);
            return self.world.texel(image, uv)[3] * m.alpha >= cut;
        }
    };

    /// What `image` holds at `uv`, its colour linear: the nearest texel,
    /// the picture repeating.
    fn texel(self: *const World, image: u32, uv: [2]f32) [4]f32 {
        const picture = self.scene.images[image];
        if (picture.width == 0 or picture.height == 0) return .{ 1, 1, 1, 1 };
        const w: f32 = @floatFromInt(picture.width);
        const h: f32 = @floatFromInt(picture.height);
        const fx = (uv[0] - @floor(uv[0])) * w;
        const fy = (uv[1] - @floor(uv[1])) * h;
        const x: usize = @min(@as(usize, @intFromFloat(fx)), picture.width - 1);
        const y: usize = @min(@as(usize, @intFromFloat(fy)), picture.height - 1);
        const at = (y * picture.width + x) * 4;
        const p = picture.pixels[at..][0..4];
        return .{ toLinear(p[0]), toLinear(p[1]), toLinear(p[2]), @as(f32, @floatFromInt(p[3])) / 255 };
    }

    /// What a surface keeps of the light, and gives off, where a ray met it.
    fn surfaceAt(self: *const World, hit: bvh.Hit) struct { albedo: Vec3, emission: Vec3 } {
        const t = self.scene.triangles[hit.triangle];
        const m = self.scene.materials[t.material];
        var albedo = vec(m.albedo);
        var emission = vec(m.emission);
        if (m.albedo_image != null or m.emission_image != null) {
            const uv = mix2(t.uvs, hit.u, hit.v);
            if (m.albedo_image) |image| {
                const c = self.texel(image, uv);
                albedo *= Vec3{ c[0], c[1], c[2] };
            }
            if (m.emission_image) |image| {
                const c = self.texel(image, uv);
                emission *= Vec3{ c[0], c[1], c[2] };
            }
        }
        return .{ .albedo = albedo, .emission = emission };
    }

    /// The light of `light` on a surface at `p` facing `n`, as the engine's
    /// shader works it out, times how much of it is not in shadow: looked
    /// at with `rays` rays where it has a size.
    fn lightOn(self: *const World, light: Light, p: Vec3, n: Vec3, rays: u32, random: std.Random) Vec3 {
        const holes_filter = self.holes();
        switch (light.kind) {
            .sun => {
                const l = normalize(vec(light.direction));
                const facing = dot(n, l);
                if (facing <= 0) return splat(0);
                const count = if (light.size > 0) @max(rays, 1) else 1;
                var seen: f32 = 0;
                for (0..count) |_| {
                    const way = if (light.size > 0) inCone(l, light.size / 2, random) else l;
                    if (!self.tree.blocked(p, way, std.math.floatMax(f32), holes_filter)) seen += 1;
                }
                return vec(light.color) * splat(facing * seen / @as(f32, @floatFromInt(count)));
            },
            .point, .spot => {
                const place = vec(light.position);
                const to = place - p;
                const d = length(to);
                if (d >= light.range or d <= 0) return splat(0);
                const l = to / splat(d);
                const facing = dot(n, l);
                if (facing <= 0) return splat(0);
                var fade = lampFade(light, d);
                var color = vec(light.color);
                const aim = normalize(vec(light.direction));
                if (light.kind == .spot) fade *= coneFade(light, dot(-l, aim));
                if (fade <= 0) return splat(0);
                if (light.cookie) |image| color *= self.cookieAt(light, image, p, l);
                const count = if (light.size > 0) @max(rays, 1) else 1;
                var seen: f32 = 0;
                for (0..count) |_| {
                    const target = if (light.size > 0) place + inBall(random) * splat(light.size / 2) else place;
                    const toward = target - p;
                    const far = length(toward);
                    if (far <= 0) continue;
                    if (!self.tree.blocked(p, toward / splat(far), far * 0.999, holes_filter)) seen += 1;
                }
                return color * splat(facing * fade * seen / @as(f32, @floatFromInt(count)));
            },
        }
    }

    /// A light's cookie's colour toward `p`, as the engine's shader reads
    /// it: across the cone for a spot light, all round for a point light.
    fn cookieAt(self: *const World, light: Light, image: u32, p: Vec3, l: Vec3) Vec3 {
        const place = vec(light.position);
        const aim = normalize(vec(light.direction));
        const up = normalize(vec(light.up));
        const off = p - place;
        const right = cross(aim, up);
        var uv: [2]f32 = undefined;
        if (light.kind == .spot) {
            const along = @max(dot(off, aim), 0.0001) * light.spread;
            uv = .{ 0.5 + 0.5 * dot(off, right) / along, 0.5 - 0.5 * dot(off, up) / along };
        } else {
            uv = .{
                0.5 + std.math.atan2(dot(-l, right), dot(-l, aim)) / std.math.tau,
                std.math.acos(std.math.clamp(dot(-l, up), -1, 1)) / std.math.pi,
            };
        }
        uv = .{ std.math.clamp(uv[0], 0.002, 0.998), std.math.clamp(uv[1], 0.002, 0.998) };
        const c = self.texel(image, uv);
        return .{ c[0], c[1], c[2] };
    }

    /// The light that comes along a ray from `origin` going `way`: what it
    /// meets gives off, and the light that falls on that - one light looked
    /// at each time it meets something, the rest of the way bounced on.
    /// `first_back` says whether the first thing it met was the inside of
    /// something.
    fn gather(self: *const World, origin: Vec3, way: Vec3, random: std.Random) struct { light: Vec3, first_back: bool } {
        const lights = self.scene.lights;
        var carried = splat(1);
        var light = splat(0);
        var o = origin;
        var d = way;
        // Each thing met lights the way back by the light falling on it:
        // light bounced once at the first, twice at the second.
        const bounces = @max(self.settings.bounces, 1);
        for (0..bounces) |bounce| {
            const hit = self.tree.nearest(o, d, std.math.floatMax(f32), self.holes()) orelse {
                light += carried * vec(self.settings.sky);
                break;
            };
            const t = self.scene.triangles[hit.triangle];
            const m = self.scene.materials[t.material];
            var face = self.faces[hit.triangle];
            var normal = normalize(mix3(t.normals, hit.u, hit.v));
            if (hit.back) {
                if (!m.two_sided) return .{ .light = light, .first_back = bounce == 0 };
                face = -face;
                normal = -normal;
            }
            if (dot(normal, face) <= 0) normal = face;
            const surface = self.surfaceAt(hit);
            light += carried * surface.emission;
            const p = o + d * splat(hit.t) + face * splat(self.lift);
            if (lights.len > 0) {
                const which = random.uintLessThan(usize, lights.len);
                const falling = self.lightOn(lights[which], p, normal, 1, random);
                light += carried * surface.albedo * falling * splat(@floatFromInt(lights.len));
            }
            if (bounce + 1 == bounces) break;
            carried *= surface.albedo;
            if (@reduce(.Max, carried) < 0.001) break;
            o = p;
            d = cosineAround(normal, random.float(f32), random.float(f32));
        }
        return .{ .light = light, .first_back = false };
    }
};

fn mix2(c: [3][2]f32, u: f32, v: f32) [2]f32 {
    const w = 1 - u - v;
    return .{ c[0][0] * w + c[1][0] * u + c[2][0] * v, c[0][1] * w + c[1][1] * u + c[2][1] * v };
}

fn mix3(c: [3][3]f32, u: f32, v: f32) Vec3 {
    return vec(c[0]) * splat(1 - u - v) + vec(c[1]) * splat(u) + vec(c[2]) * splat(v);
}

fn toLinear(byte: u8) f32 {
    const x = @as(f32, @floatFromInt(byte)) / 255;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

/// Two ways square to `n` and to each other.
fn basisOf(n: Vec3) [2]Vec3 {
    const other: Vec3 = if (@abs(n[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
    const t = normalize(cross(other, n));
    return .{ t, cross(n, t) };
}

/// A way round `n`, more of them nearer it as the cosine says: from two
/// numbers between nought and one.
fn cosineAround(n: Vec3, r1: f32, r2: f32) Vec3 {
    const b = basisOf(n);
    const phi = std.math.tau * r1;
    const r = @sqrt(r2);
    return normalize(b[0] * splat(r * @cos(phi)) + b[1] * splat(r * @sin(phi)) + n * splat(@sqrt(@max(1 - r2, 0))));
}

/// A way anywhere, as likely as any other.
fn onSphere(r1: f32, r2: f32) Vec3 {
    const z = 1 - 2 * r1;
    const r = @sqrt(@max(1 - z * z, 0));
    const phi = std.math.tau * r2;
    return .{ r * @cos(phi), r * @sin(phi), z };
}

/// A way within `half` radians of `l`.
fn inCone(l: Vec3, half: f32, random: std.Random) Vec3 {
    const b = basisOf(l);
    const cos_max = @cos(half);
    const z = 1 - random.float(f32) * (1 - cos_max);
    const r = @sqrt(@max(1 - z * z, 0));
    const phi = std.math.tau * random.float(f32);
    return normalize(b[0] * splat(r * @cos(phi)) + b[1] * splat(r * @sin(phi)) + l * splat(z));
}

/// A point in the ball of one round nought.
fn inBall(random: std.Random) Vec3 {
    while (true) {
        const p: Vec3 = .{ random.float(f32) * 2 - 1, random.float(f32) * 2 - 1, random.float(f32) * 2 - 1 };
        if (dot(p, p) <= 1) return p;
    }
}

/// The `i`th of a sequence of points in the unit square that spread
/// evenly, moved round by `shift`.
fn spread2(i: u32, shift: [2]f32) [2]f32 {
    const a1 = 0.7548776662466927;
    const a2 = 0.5698402909980532;
    const fi: f64 = @floatFromInt(i);
    const x: f32 = @floatCast(@mod(0.5 + a1 * fi + shift[0], 1.0));
    const y: f32 = @floatCast(@mod(0.5 + a2 * fi + shift[1], 1.0));
    return .{ x, y };
}

fn randomFor(seed: u64, which: u64) std.Random.DefaultPrng {
    return .init(seed ^ (which *% 0x9E3779B97F4A7C15) ^ 0xD1B54A32D192ED03);
}

// -------------------------------------------------------------------------
// The lightmap: a square of each instance's lightmap UVs, and their texels
// -------------------------------------------------------------------------

const Rect = struct { x: u32 = 0, y: u32 = 0, size: u32 = 0 };

/// A texel a surface covers: where on it, which way it faces there, and
/// whose it is.
const Texel = struct {
    pixel: u32,
    position: Vec3,
    normal: Vec3,
    face: Vec3,
    instance: u32,
    /// How wide a texel is in the world, there.
    width: f32,
};

const Atlas = struct {
    size: u32,
    rects: []Rect,
    texels: std.ArrayList(Texel),
    /// Each pixel's texel, or none.
    owner: []u32,

    const none = std.math.maxInt(u32);

    fn init(gpa: Allocator, world: *const World, settings: Settings) Allocator.Error!Atlas {
        const scene = world.scene;
        const count = scene.instances.len;
        // How big each instance is in the world, and its lightmap UVs on
        // their square.
        const world_area = try gpa.alloc(f64, count);
        defer gpa.free(world_area);
        const map_area = try gpa.alloc(f64, count);
        defer gpa.free(map_area);
        @memset(world_area, 0);
        @memset(map_area, 0);
        for (scene.triangles) |t| {
            const p0 = vec(t.positions[0]);
            world_area[t.instance] += length(cross(vec(t.positions[1]) - p0, vec(t.positions[2]) - p0)) / 2;
            const a = t.lightmap_uvs;
            map_area[t.instance] += @abs((a[1][0] - a[0][0]) * (a[2][1] - a[0][1]) - (a[2][0] - a[0][0]) * (a[1][1] - a[0][1])) / 2;
        }

        const rects = try gpa.alloc(Rect, count);
        errdefer gpa.free(rects);
        const wanted = try gpa.alloc(u32, count);
        defer gpa.free(wanted);
        for (scene.instances, wanted, world_area, map_area) |instance, *w, wa, ma| {
            if (!instance.lit or ma <= 0 or wa <= 0) {
                w.* = 0;
                continue;
            }
            const across = settings.texels_per_unit * @as(f32, @floatCast(@sqrt(wa / ma)));
            w.* = std.math.clamp(@as(u32, @intFromFloat(@ceil(across))), @max(instance.least_texels, 8), settings.max_size);
        }

        // Largest first, on shelves in the smallest square that holds them,
        // each smaller where none does; at the last, those that still do not
        // fit are left out of it.
        const order = try gpa.alloc(u32, count);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const Larger = struct {
            fn lessThan(all: []const u32, a: u32, b: u32) bool {
                if (all[a] != all[b]) return all[a] > all[b];
                return a < b;
            }
        };
        std.mem.sort(u32, order, @as([]const u32, wanted), Larger.lessThan);
        const max_size = @max(settings.max_size, 16);
        var scale: f32 = 1;
        var size: u32 = 0;
        for (0..40) |_| {
            var side: u32 = @min(256, max_size);
            while (side < max_size and !pack(order, wanted, rects, side, scale, false)) side = @min(side * 2, max_size);
            if (pack(order, wanted, rects, side, scale, false)) {
                size = side;
                break;
            }
            scale *= 0.85;
        } else {
            size = max_size;
            _ = pack(order, wanted, rects, size, scale, true);
        }

        const owner = try gpa.alloc(u32, @as(usize, size) * size);
        errdefer gpa.free(owner);
        @memset(owner, none);
        var self: Atlas = .{ .size = size, .rects = rects, .texels = .empty, .owner = owner };
        errdefer self.texels.deinit(gpa);
        try self.raster(gpa, world, world_area, map_area);
        return self;
    }

    fn deinit(self: *Atlas, gpa: Allocator) void {
        gpa.free(self.rects);
        self.texels.deinit(gpa);
        gpa.free(self.owner);
    }

    /// Put each wanted square, times `scale`, in `order`, on shelves
    /// `side` across: whether they all fit. With `leave_out`, one that does
    /// not is left out, and the rest go on.
    fn pack(order: []const u32, wanted: []const u32, rects: []Rect, side: u32, scale: f32, leave_out: bool) bool {
        var x: u32 = 0;
        var y: u32 = 0;
        var shelf: u32 = 0;
        for (rects) |*r| r.* = .{};
        for (order) |i| {
            if (wanted[i] == 0) continue;
            const s = @min(scaled(wanted[i], scale), side);
            if (x + s > side) {
                y += shelf;
                x = 0;
                shelf = 0;
            }
            if (y + s > side) {
                if (leave_out) continue;
                return false;
            }
            rects[i] = .{ .x = x, .y = y, .size = s };
            x += s;
            shelf = @max(shelf, s);
        }
        return true;
    }

    fn scaled(w: u32, scale: f32) u32 {
        return @max(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) * scale))), 4);
    }

    /// The texels each instance's triangles cover: each pixel the nearest
    /// triangle's, where its middle is, or the nearest point to it on a
    /// triangle half a texel off.
    fn raster(self: *Atlas, gpa: Allocator, world: *const World, world_area: []const f64, map_area: []const f64) Allocator.Error!void {
        const scene = world.scene;
        const pixel_count = @as(usize, self.size) * self.size;
        const nearest = try gpa.alloc(f32, pixel_count);
        defer gpa.free(nearest);
        @memset(nearest, std.math.floatMax(f32));
        const which = try gpa.alloc(u32, pixel_count);
        defer gpa.free(which);
        @memset(which, none);
        const shares = try gpa.alloc([2]f32, pixel_count);
        defer gpa.free(shares);

        for (scene.triangles, 0..) |t, ti| {
            const rect = self.rects[t.instance];
            if (rect.size == 0) continue;
            // One of no area in the world lights nothing.
            if (bvh.dot(world.faces[ti], world.faces[ti]) == 0) continue;
            const r: f32 = @floatFromInt(rect.size);
            var c: [3][2]f32 = undefined;
            for (&c, t.lightmap_uvs) |*corner, uv| corner.* = .{
                @as(f32, @floatFromInt(rect.x)) + std.math.clamp(uv[0], 0, 1) * r,
                @as(f32, @floatFromInt(rect.y)) + std.math.clamp(uv[1], 0, 1) * r,
            };
            const x0 = clampPixel(@floor(@min(c[0][0], c[1][0], c[2][0]) - 1), rect.x, rect.size);
            const x1 = clampPixel(@ceil(@max(c[0][0], c[1][0], c[2][0]) + 1), rect.x, rect.size);
            const y0 = clampPixel(@floor(@min(c[0][1], c[1][1], c[2][1]) - 1), rect.y, rect.size);
            const y1 = clampPixel(@ceil(@max(c[0][1], c[1][1], c[2][1]) + 1), rect.y, rect.size);
            for (y0..y1) |y| for (x0..x1) |x| {
                const p: [2]f32 = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                const found = closestOnTriangle(c, p);
                if (found.distance > 0.75) continue;
                const at = y * self.size + x;
                if (found.distance < nearest[at]) {
                    nearest[at] = found.distance;
                    which[at] = @intCast(ti);
                    shares[at] = .{ found.u, found.v };
                }
            };
        }

        for (which, shares, 0..) |ti, share, at| {
            if (ti == none) continue;
            const t = scene.triangles[ti];
            const face = world.faces[ti];
            var normal = normalize(mix3(t.normals, share[0], share[1]));
            if (dot(normal, face) <= 0) normal = face;
            const rect = self.rects[t.instance];
            const texels_area = map_area[t.instance] * @as(f64, @floatFromInt(rect.size)) * @as(f64, @floatFromInt(rect.size));
            self.owner[at] = @intCast(self.texels.items.len);
            try self.texels.append(gpa, .{
                .pixel = @intCast(at),
                .position = mix3(t.positions, share[0], share[1]),
                .normal = normal,
                .face = face,
                .instance = t.instance,
                .width = @floatCast(@sqrt(world_area[t.instance] / @max(texels_area, 1e-12))),
            });
        }
    }

    fn clampPixel(x: f32, start: u32, size: u32) usize {
        const lo: f32 = @floatFromInt(start);
        const hi: f32 = @floatFromInt(start + size);
        return @intFromFloat(std.math.clamp(x, lo, hi));
    }

    /// The picture: each texel's light, and the pixels round each
    /// instance's charts filled from their neighbours, so a picture read
    /// across their edges reads its own.
    fn fill(self: *const Atlas, gpa: Allocator, pixels: [][3]f32, direct: []const Vec3, bounced: []const Vec3, inside: []const bool) Allocator.Error!void {
        @memset(pixels, .{ 0, 0, 0 });
        const known = try gpa.alloc(bool, pixels.len);
        defer gpa.free(known);
        @memset(known, false);
        // Whose square each pixel is in, for the filling to keep to it.
        const square = try gpa.alloc(u32, pixels.len);
        defer gpa.free(square);
        @memset(square, none);
        for (self.rects, 0..) |r, i| {
            for (r.y..r.y + r.size) |y| @memset(square[y * self.size + r.x ..][0..r.size], @intCast(i));
        }
        for (self.texels.items, direct, bounced, inside) |t, d, b, in| {
            if (in) continue;
            const light = d + b;
            pixels[t.pixel] = .{ light[0], light[1], light[2] };
            known[t.pixel] = true;
        }
        const next = try gpa.alloc(bool, pixels.len);
        defer gpa.free(next);
        for (0..8) |_| {
            @memcpy(next, known);
            var changed = false;
            for (0..self.size) |y| for (0..self.size) |x| {
                const at = y * self.size + x;
                if (known[at] or square[at] == none) continue;
                var sum = splat(0);
                var n: f32 = 0;
                for ([_]i32{ -1, 0, 1 }) |dy| for ([_]i32{ -1, 0, 1 }) |dx| {
                    const nx = @as(i64, @intCast(x)) + dx;
                    const ny = @as(i64, @intCast(y)) + dy;
                    if (nx < 0 or ny < 0 or nx >= self.size or ny >= self.size) continue;
                    const other: usize = @intCast(ny * self.size + nx);
                    if (!known[other] or square[other] != square[at]) continue;
                    sum += vec(pixels[other]);
                    n += 1;
                };
                if (n == 0) continue;
                const mean = sum / splat(n);
                pixels[at] = .{ mean[0], mean[1], mean[2] };
                next[at] = true;
                changed = true;
            };
            @memcpy(known, next);
            if (!changed) break;
        }
    }
};

const Closest = struct { u: f32, v: f32, distance: f32 };

/// The point of triangle `c` nearest `p`, as the second and third corners'
/// shares of it, and how far it is from `p`.
fn closestOnTriangle(c: [3][2]f32, p: [2]f32) Closest {
    const e1 = [2]f32{ c[1][0] - c[0][0], c[1][1] - c[0][1] };
    const e2 = [2]f32{ c[2][0] - c[0][0], c[2][1] - c[0][1] };
    const w = [2]f32{ p[0] - c[0][0], p[1] - c[0][1] };
    const twice = e1[0] * e2[1] - e1[1] * e2[0];
    if (@abs(twice) > 1e-12) {
        const u = (w[0] * e2[1] - w[1] * e2[0]) / twice;
        const v = (e1[0] * w[1] - e1[1] * w[0]) / twice;
        if (u >= 0 and v >= 0 and u + v <= 1) return .{ .u = u, .v = v, .distance = 0 };
    }
    // Outside: the nearest point of its three edges.
    var best: Closest = .{ .u = 0, .v = 0, .distance = std.math.floatMax(f32) };
    const edges = [_][2]u2{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } };
    for (edges) |e| {
        const a = c[e[0]];
        const b = c[e[1]];
        const ab = [2]f32{ b[0] - a[0], b[1] - a[1] };
        const ap = [2]f32{ p[0] - a[0], p[1] - a[1] };
        const len2 = ab[0] * ab[0] + ab[1] * ab[1];
        const s = if (len2 > 0) std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / len2, 0, 1) else 0;
        const q = [2]f32{ a[0] + ab[0] * s, a[1] + ab[1] * s };
        const d = @sqrt((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]));
        if (d < best.distance) {
            // The shares of corners 1 and 2 at that point.
            var shares: [3]f32 = .{ 0, 0, 0 };
            shares[e[0]] = 1 - s;
            shares[e[1]] = s;
            best = .{ .u = shares[1], .v = shares[2], .distance = d };
        }
    }
    return best;
}

// -------------------------------------------------------------------------
// Lighting the texels, on threads
// -------------------------------------------------------------------------

const TexelJob = struct {
    world: *const World,
    atlas: *const Atlas,
    direct: []Vec3,
    bounced: []Vec3,
    inside: []bool,

    fn one(self: *TexelJob, i: usize) void {
        const world = self.world;
        const settings = world.settings;
        const texel = self.atlas.texels.items[i];
        var prng = randomFor(settings.seed, i);
        const random = prng.random();
        const lift = @max(world.lift, texel.width * 0.1);
        const origin = texel.position + texel.face * splat(lift);

        var direct = splat(0);
        for (world.scene.lights) |light| {
            if (!light.direct) continue;
            direct += world.lightOn(light, origin, texel.normal, settings.light_rays, random);
        }

        var bounced = splat(0);
        var backs: u32 = 0;
        const shift: [2]f32 = .{ random.float(f32), random.float(f32) };
        const rays = @max(settings.rays, 1);
        for (0..rays) |k| {
            const r = spread2(@intCast(k), shift);
            const way = cosineAround(texel.normal, r[0], r[1]);
            const got = world.gather(origin, way, random);
            if (got.first_back) backs += 1;
            bounced += got.light;
        }
        self.direct[i] = direct;
        self.bounced[i] = bounced / splat(@floatFromInt(rays));
        // A texel more than half of whose rays meet the inside of
        // something is in it: filled from its neighbours instead.
        self.inside[i] = backs * 2 > rays;
    }
};

/// Run `job.one(i)` for every `i` below `count`, in chunks, on threads,
/// counting what is done on `control` and stopping when it is cancelled.
/// Where no more threads can be had, on those there are.
fn parallel(comptime Job: type, job: *Job, count: usize, threads: u32, control: *Control) void {
    const Shared = struct {
        job: *Job,
        count: usize,
        next: std.atomic.Value(usize) = .init(0),
        control: *Control,

        const chunk = 64;

        fn work(self: *@This()) void {
            while (!self.control.cancelled.load(.acquire)) {
                const start = self.next.fetchAdd(chunk, .acq_rel);
                if (start >= self.count) break;
                const end = @min(start + chunk, self.count);
                for (start..end) |i| self.job.one(i);
                _ = self.control.done.fetchAdd(end - start, .acq_rel);
            }
        }
    };
    var shared: Shared = .{ .job = job, .count = count, .control = control };
    if (builtin.single_threaded) {
        shared.work();
        return;
    }
    const wanted: usize = if (threads > 0) threads else std.Thread.getCpuCount() catch 1;
    const extra = @min(@max(wanted, 1) - 1, 63);
    var spawned: [63]std.Thread = undefined;
    var running: usize = 0;
    defer for (spawned[0..running]) |thread| thread.join();
    for (0..extra) |_| {
        spawned[running] = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch break;
        running += 1;
    }
    shared.work();
}

/// Smooth the bounced light, which is grainy from its few rays: each
/// texel's mixed with its neighbours' that face its way and lie near it.
fn denoise(gpa: Allocator, atlas: *const Atlas, bounced: []Vec3, inside: []const bool) Allocator.Error!void {
    const smoothed = try gpa.alloc(Vec3, bounced.len);
    defer gpa.free(smoothed);
    const size = atlas.size;
    for ([_]i32{ 1, 2 }) |step| {
        for (atlas.texels.items, 0..) |t, i| {
            if (inside[i]) {
                smoothed[i] = bounced[i];
                continue;
            }
            const x: i64 = t.pixel % size;
            const y: i64 = t.pixel / size;
            var sum = splat(0);
            var weights: f32 = 0;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const nx = x + dx * step;
                    const ny = y + dy * step;
                    if (nx < 0 or ny < 0 or nx >= size or ny >= size) continue;
                    const j = atlas.owner[@intCast(ny * size + nx)];
                    if (j == Atlas.none or inside[j]) continue;
                    const o = atlas.texels.items[j];
                    if (o.instance != t.instance) continue;
                    const facing = @max(dot(o.normal, t.normal), 0);
                    const apart = length(o.position - t.position) / @max(t.width * 2 * @as(f32, @floatFromInt(step)), 1e-6);
                    const w = std.math.pow(f32, facing, 8) * @exp(-apart * apart) * @exp(-@as(f32, @floatFromInt(dx * dx + dy * dy)) / 4.5);
                    sum += bounced[j] * splat(w);
                    weights += w;
                }
            }
            smoothed[i] = if (weights > 0) sum / splat(weights) else bounced[i];
        }
        @memcpy(bounced, smoothed);
    }
}

// -------------------------------------------------------------------------
// Probes
// -------------------------------------------------------------------------

/// The most probes a grid has each way.
const most_across = 32;

const ProbeJob = struct {
    world: *const World,
    probes: *Probes,

    fn one(self: *ProbeJob, i: usize) void {
        const world = self.world;
        const settings = world.settings;
        const counts = self.probes.counts;
        const x = i % counts[0];
        const y = (i / counts[0]) % counts[1];
        const z = i / (counts[0] * counts[1]);
        const at = vec(self.probes.origin) + Vec3{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) } * splat(self.probes.spacing);
        var prng = randomFor(settings.seed ^ 0xABCDEF, i);
        const random = prng.random();

        // The light coming each way, as spherical harmonics of the first
        // two bands: four numbers a colour.
        var bands: [3][4]f32 = @splat(@splat(0));
        const rays = @max(settings.rays * 2, 64);
        var backs: u32 = 0;
        const shift: [2]f32 = .{ random.float(f32), random.float(f32) };
        for (0..rays) |k| {
            const r = spread2(@intCast(k), shift);
            const way = onSphere(r[0], r[1]);
            const got = world.gather(at, way, random);
            if (got.first_back) backs += 1;
            const basis = [4]f32{ 0.282095, 0.488603 * way[0], 0.488603 * way[1], 0.488603 * way[2] };
            const light: [3]f32 = got.light;
            for (0..3) |c| for (0..4) |b| {
                bands[c][b] += light[c] * basis[b];
            };
        }
        const weight = 4 * std.math.pi / @as(f32, @floatFromInt(rays));
        for (&bands) |*colour| for (colour) |*b| {
            b.* *= weight;
        };
        // The lights baked whole, from where they are: each a point of
        // light in the sky round the probe.
        for (world.scene.lights) |light| {
            if (!light.direct) continue;
            const toward = switch (light.kind) {
                .sun => normalize(vec(light.direction)),
                else => normalize(vec(light.position) - at),
            };
            // As bright as it lights a surface facing it.
            const falling: [3]f32 = world.lightOn(light, at, toward, settings.light_rays, random);
            const basis = [4]f32{ 0.282095, 0.488603 * toward[0], 0.488603 * toward[1], 0.488603 * toward[2] };
            for (0..3) |c| for (0..4) |b| {
                bands[c][b] += std.math.pi * falling[c] * basis[b];
            };
        }
        // How lit a surface facing each way is: the bands smoothed over the
        // half of the sky it faces.
        var out: [12]f32 = undefined;
        for (0..3) |c| {
            out[c * 4] = bands[c][0] * 0.282095;
            for (1..4) |b| out[c * 4 + b] = bands[c][b] * 0.488603 * (2.0 / 3.0);
        }
        self.probes.samples[i] = out;
        self.probes.valid[i] = backs * 4 <= rays;
    }
};

fn bakeProbes(gpa: Allocator, world: *const World, settings: Settings, control: *Control) Allocator.Error!Probes {
    if (world.scene.triangles.len == 0) return .{};
    const extent: [3]f32 = world.hi - world.lo;
    const lo: [3]f32 = world.lo;
    var spacing = @max(settings.probe_spacing, 0.01);
    spacing = @max(spacing, @max(extent[0], extent[1], extent[2]) / (most_across - 1));
    var counts: [3]u32 = undefined;
    var origin: [3]f32 = undefined;
    for (0..3) |a| {
        // One in the middle of each cell the box is cut into, so none is on
        // a floor or a wall the box's edge is at.
        counts[a] = std.math.clamp(@as(u32, @intFromFloat(@floor(extent[a] / spacing))), 1, most_across);
        const span = @as(f32, @floatFromInt(counts[a] - 1)) * spacing;
        origin[a] = lo[a] + (extent[a] - span) / 2;
    }
    const total = @as(usize, counts[0]) * counts[1] * counts[2];
    var probes: Probes = .{ .origin = origin, .spacing = spacing, .counts = counts };
    probes.samples = try gpa.alloc([12]f32, total);
    errdefer gpa.free(probes.samples);
    probes.valid = try gpa.alloc(bool, total);
    errdefer gpa.free(probes.valid);
    control.begin(.probes, total);
    var job: ProbeJob = .{ .world = world, .probes = &probes };
    parallel(ProbeJob, &job, total, settings.threads, control);
    return probes;
}

/// How lit a surface facing `n` is at `at`, from the probes round it: the
/// nearest eight, by how near, those inside something left out. Null where
/// there are none.
pub fn probeLight(probes: Probes, at: [3]f32) ?[12]f32 {
    if (probes.samples.len == 0) return null;
    var cell: [3]usize = undefined;
    var frac: [3]f32 = undefined;
    for (0..3) |a| {
        const n: usize = probes.counts[a];
        if (n < 2) {
            cell[a] = 0;
            frac[a] = 0;
            continue;
        }
        const g = std.math.clamp((at[a] - probes.origin[a]) / probes.spacing, 0, @as(f32, @floatFromInt(n - 1)));
        const lo: usize = @min(@as(usize, @intFromFloat(@floor(g))), n - 2);
        cell[a] = lo;
        frac[a] = g - @as(f32, @floatFromInt(lo));
    }
    var sum: [12]f32 = @splat(0);
    var weights: f32 = 0;
    for (0..8) |corner| {
        var index: usize = 0;
        var w: f32 = 1;
        var stride: usize = 1;
        for (0..3) |a| {
            const up = (corner >> @intCast(a)) & 1 == 1;
            const n: usize = probes.counts[a];
            const c: usize = @min(cell[a] + @intFromBool(up), n - 1);
            index += c * stride;
            stride *= n;
            w *= if (up) frac[a] else 1 - frac[a];
        }
        if (w <= 0 or !probes.valid[index]) continue;
        for (&sum, probes.samples[index]) |*s, v| s.* += v * w;
        weights += w;
    }
    if (weights <= 0) return null;
    for (&sum) |*s| s.* /= weights;
    return sum;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A quad as two triangles, facing `n`, its lightmap UVs the whole square.
fn quad(out: *std.ArrayList(Triangle), corners: [4][3]f32, n: [3]f32, instance: u32, material: u32) !void {
    const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    try out.append(testing.allocator, .{ .positions = .{ corners[0], corners[1], corners[2] }, .normals = .{ n, n, n }, .uvs = .{ uv[0], uv[1], uv[2] }, .lightmap_uvs = .{ uv[0], uv[1], uv[2] }, .instance = instance, .material = material });
    try out.append(testing.allocator, .{ .positions = .{ corners[0], corners[2], corners[3] }, .normals = .{ n, n, n }, .uvs = .{ uv[0], uv[2], uv[3] }, .lightmap_uvs = .{ uv[0], uv[2], uv[3] }, .instance = instance, .material = material });
}

/// The mean light of an instance's texels.
fn meanOf(result: Result, instance: u32) [3]f32 {
    const place = result.places[instance];
    const size: f32 = @floatFromInt(result.width);
    const x0: usize = @intFromFloat(place[2] * size);
    const y0: usize = @intFromFloat(place[3] * size);
    const across: usize = @intFromFloat(place[0] * size);
    var sum: [3]f64 = .{ 0, 0, 0 };
    // The middle half, away from the edges.
    for (y0 + across / 4..y0 + 3 * across / 4) |y| for (x0 + across / 4..x0 + 3 * across / 4) |x| {
        for (&sum, result.pixels[y * result.width + x]) |*s, v| s.* += v;
    };
    const n: f64 = @floatFromInt((across / 2) * (across / 2));
    return .{ @floatCast(sum[0] / n), @floatCast(sum[1] / n), @floatCast(sum[2] / n) };
}

test "a lamp falls off toward its range, or with the distance cut off smoothly at its range; a cone's edge either way" {
    const near: Light = .{ .kind = .point, .color = .{ 1, 1, 1 }, .range = 10, .attenuation = 1, .direct = true };
    try testing.expectApproxEqAbs(@as(f32, 0.5), lampFade(near, 5), 1e-5);
    try testing.expectEqual(@as(f32, 0), lampFade(near, 10));
    var far = near;
    far.by_distance = true;
    // A half at twice the distance, near it; nothing at its range.
    try testing.expectApproxEqAbs(lampFade(far, 1) / 2, lampFade(far, 2), 0.01);
    try testing.expectEqual(@as(f32, 0), lampFade(far, 10));
    const edge = @cos(std.math.degreesToRadians(30.0));
    var spot: Light = .{ .kind = .spot, .color = .{ 1, 1, 1 }, .range = 10, .cone = edge, .cone_attenuation = 1, .direct = true };
    try testing.expectApproxEqAbs(@as(f32, 1), coneFade(spot, 1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), coneFade(spot, edge), 1e-5);
    spot.by_distance = true;
    // Bright to near the edge, and nothing at it.
    try testing.expect(coneFade(spot, @cos(std.math.degreesToRadians(20.0))) > 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), coneFade(spot, edge), 1e-4);
}

test "an open floor under the sky is lit by the sky, and a sun on it adds as much as it falls" {
    var triangles: std.ArrayList(Triangle) = .empty;
    defer triangles.deinit(testing.allocator);
    try quad(&triangles, .{ .{ -2, 0, 2 }, .{ 2, 0, 2 }, .{ 2, 0, -2 }, .{ -2, 0, -2 } }, .{ 0, 1, 0 }, 0, 0);
    const scene: Scene = .{
        .triangles = triangles.items,
        .instances = &.{.{ .lit = true, .least_texels = 8 }},
        .materials = &.{.{ .albedo = .{ 0.5, 0.5, 0.5 } }},
        .images = &.{},
        .lights = &.{.{ .kind = .sun, .direction = .{ 0, 1, 0 }, .color = .{ 1, 0.5, 0.25 }, .direct = true }},
    };
    var control: Control = .{};
    var result = try bake(testing.allocator, scene, .{ .texels_per_unit = 4, .rays = 16, .sky = .{ 0.2, 0.3, 0.4 } }, &control);
    defer result.deinit(testing.allocator);
    const mean = meanOf(result, 0);
    // The sky everywhere above, the sun straight down: nothing to bounce.
    try testing.expectApproxEqAbs(@as(f32, 1.2), mean[0], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.8), mean[1], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.65), mean[2], 0.02);
}

test "a closed room lit by a lamp: a red wall's light falls on the one across from it, and the same seed bakes the same" {
    var triangles: std.ArrayList(Triangle) = .empty;
    defer triangles.deinit(testing.allocator);
    // A box four across, its walls facing in: floor, ceiling, a red wall
    // at -x, a white one at +x, and the other two.
    const s: f32 = 2;
    try quad(&triangles, .{ .{ -s, -s, s }, .{ s, -s, s }, .{ s, -s, -s }, .{ -s, -s, -s } }, .{ 0, 1, 0 }, 0, 0);
    try quad(&triangles, .{ .{ -s, s, -s }, .{ s, s, -s }, .{ s, s, s }, .{ -s, s, s } }, .{ 0, -1, 0 }, 1, 0);
    try quad(&triangles, .{ .{ -s, -s, -s }, .{ -s, s, -s }, .{ -s, s, s }, .{ -s, -s, s } }, .{ 1, 0, 0 }, 2, 1);
    try quad(&triangles, .{ .{ s, -s, s }, .{ s, s, s }, .{ s, s, -s }, .{ s, -s, -s } }, .{ -1, 0, 0 }, 3, 0);
    try quad(&triangles, .{ .{ s, -s, -s }, .{ s, s, -s }, .{ -s, s, -s }, .{ -s, -s, -s } }, .{ 0, 0, 1 }, 4, 0);
    try quad(&triangles, .{ .{ -s, -s, s }, .{ -s, s, s }, .{ s, s, s }, .{ s, -s, s } }, .{ 0, 0, -1 }, 5, 0);
    var instances: [6]Instance = @splat(.{ .lit = true, .least_texels = 8 });
    const scene: Scene = .{
        .triangles = triangles.items,
        .instances = &instances,
        .materials = &.{ .{ .albedo = .{ 0.8, 0.8, 0.8 } }, .{ .albedo = .{ 0.9, 0.1, 0.1 } } },
        .images = &.{},
        .lights = &.{.{ .kind = .point, .position = .{ 0, 1.5, 0 }, .color = .{ 4, 4, 4 }, .range = 10, .direct = false }},
    };
    const settings: Settings = .{ .texels_per_unit = 2, .rays = 32, .bounces = 2, .probe_spacing = 1.5 };
    var control: Control = .{};
    var result = try bake(testing.allocator, scene, settings, &control);
    defer result.deinit(testing.allocator);
    // The white wall across from the red one is redder than it is green.
    const across = meanOf(result, 3);
    try testing.expect(across[0] > across[1] * 1.1);
    // The floor is lit by bounces alone - the lamp's own light is not baked.
    const floor = meanOf(result, 0);
    try testing.expect(floor[1] > 0.05);
    // No probe is in the open but those inside the room, all of them.
    for (result.probes.valid) |v| try testing.expect(v);
    const middle = probeLight(result.probes, .{ 0, 0, 0 }).?;
    try testing.expect(middle[0] > 0);

    var again = try bake(testing.allocator, scene, settings, &control);
    defer again.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(result.pixels), std.mem.sliceAsBytes(again.pixels));
}

test "a cancelled bake stops, and says so" {
    var triangles: std.ArrayList(Triangle) = .empty;
    defer triangles.deinit(testing.allocator);
    try quad(&triangles, .{ .{ -2, 0, 2 }, .{ 2, 0, 2 }, .{ 2, 0, -2 }, .{ -2, 0, -2 } }, .{ 0, 1, 0 }, 0, 0);
    const scene: Scene = .{
        .triangles = triangles.items,
        .instances = &.{.{ .lit = true, .least_texels = 8 }},
        .materials = &.{.{}},
        .images = &.{},
        .lights = &.{},
    };
    const job = try Bake.start(testing.allocator, scene, .{ .texels_per_unit = 64, .rays = 256 });
    job.cancel();
    try testing.expectError(error.Cancelled, job.finish());
}

test "probes round a probe inside something leave it out" {
    var samples = [_][12]f32{ @splat(1), @splat(3) };
    var valid = [_]bool{ true, false };
    const probes: Probes = .{ .origin = .{ 0, 0, 0 }, .spacing = 1, .counts = .{ 2, 1, 1 }, .samples = &samples, .valid = &valid };
    try testing.expectEqual(@as(f32, 1), probeLight(probes, .{ 0.9, 0, 0 }).?[0]);
}

test {
    _ = bvh;
}
