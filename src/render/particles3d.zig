// SPDX-License-Identifier: BSD-3-Clause

//! `Particles3D`: rain, sparks, smoke, dust, embers - many small pictures
//! an entity lets go of in the 3D world, each moving on its own for a
//! while, facing the camera, shrinking and fading as it goes.
//!
//! ```zig
//! _ = try world.spawnWith(.{
//!     fx.Transform3D.at(0, 8, 0),
//!     fx.Particles3D{ .amount = 2000, .emission_shape = .box, .emission_extents = .init(10, 0, 10),
//!         .direction = .init(0, -1, 0), .speed_min = 12, .speed_max = 14, .stretch = 0.04 },
//! });
//! ```
//!
//! The same cycle as a `Particles2D`'s: `amount` places, each starting a
//! particle once every `lifetime`, spread over it or bunched at its start
//! by `explosiveness`; `one_shot` stops after one, says `finished` and turns
//! `emitting` off; `app.emitParticles` lets go of more at once, and
//! `app.restartParticles` starts again. In metres and seconds: a particle
//! starts at the emitter, anywhere in a sphere, on its surface, in a box
//! round it or on a ring about its `y`; it goes along `direction`, turned
//! by up to `spread` from it, at a speed from `speed_min` to `speed_max`.
//! `gravity` pulls it, its own acceleration pushes it along its way, away
//! from the emitter or round its `y`, and damping slows it.
//!
//! **What it looks like.** A quad `size` metres across facing the camera -
//! its texture's frame, or a soft round dot - turned by its angle, at a
//! scale from `scale_min` to `scale_max`, its colour from `color` to
//! `color_random`, each multiplied by its end by the end of its life. With
//! `align_to_velocity` it lies along the way it goes, `stretch` times its
//! speed longer: a streak of rain. Drawn by `render/billboards.zig`, not lit
//! but in the fog, the furthest first where they are mixed by alpha.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const Curve = @import("particles.zig").Particles2D.Curve;

const Entity = ecs.Entity;
const Vec3 = math.Vec3;

pub const Particles3D = extern struct {
    /// Whether places start particles. Set, after it was not, the cycle
    /// starts again from its beginning.
    emitting: bool = true,
    /// How many places the cycle has: as many particles at most, over and
    /// above those `emitParticles` lets go of.
    amount: u32 = 64,
    /// How long a particle lives, and so how long a cycle is, in seconds.
    lifetime: f32 = 1,
    /// One burst of `amount` and no more: `emitting` goes off, and `finished`
    /// is said.
    one_shot: bool = false,
    /// Seconds run through before it is first shown: rain already falling.
    preprocess: f32 = 0,
    /// How fast its time runs: faster above one, slower below.
    speed_scale: f32 = 1,
    /// How far the places' starts are bunched at the start of the cycle.
    explosiveness: f32 = 0,
    /// How much of its `lifetime` a particle may lose, at random.
    randomness: f32 = 0,
    /// Whether particles move with the emitter, or stay where they were let
    /// go of.
    local_coords: bool = false,
    /// The same particles every time for any but nought; others each time.
    seed: u32 = 0,

    /// Where a particle starts: at the emitter, in a sphere, on its surface,
    /// in a box, or on a ring about the emitter's `y`.
    emission_shape: EmissionShape = .point,
    /// A sphere's and a ring's radius, in metres.
    emission_radius: f32 = 1,
    /// Half the box's size, in metres.
    emission_extents: Vec3 = .init(1, 1, 1),

    /// The way particles go, turned with the emitter.
    direction: Vec3 = .init(0, 1, 0),
    /// How far from `direction` a particle may go, in radians: a cone.
    spread: f32 = 0.4,
    /// How fast a particle starts, at random between these, in metres a
    /// second.
    speed_min: f32 = 2,
    /// How fast a particle starts, at random between these, in metres a
    /// second.
    speed_max: f32 = 4,
    /// Pulls every particle, in metres a second each second.
    gravity: Vec3 = .init(0, -9.8, 0),
    /// Along its way: forward for more than nought, back for less.
    linear_accel_min: f32 = 0,
    /// Along its way: forward for more than nought, back for less.
    linear_accel_max: f32 = 0,
    /// Away from the emitter for more than nought, towards it for less.
    radial_accel_min: f32 = 0,
    /// Away from the emitter for more than nought, towards it for less.
    radial_accel_max: f32 = 0,
    /// Round the emitter's `y`, anticlockwise from above for more than
    /// nought.
    tangential_accel_min: f32 = 0,
    /// Round the emitter's `y`, anticlockwise from above for more than
    /// nought.
    tangential_accel_max: f32 = 0,
    /// Speed lost each second.
    damping_min: f32 = 0,
    /// Speed lost each second.
    damping_max: f32 = 0,
    /// How its picture is turned when it starts, in radians.
    angle_min: f32 = 0,
    /// How its picture is turned when it starts, in radians.
    angle_max: f32 = 0,
    /// How fast its picture turns, in radians a second.
    spin_min: f32 = 0,
    /// How fast its picture turns, in radians a second.
    spin_max: f32 = 0,
    /// Lies along the way it goes rather than turned by its angle: a streak
    /// of rain, a spark's trail.
    align_to_velocity: bool = false,
    /// With `align_to_velocity`, how much longer it is for each metre a
    /// second it goes, in seconds: a raindrop's streak.
    stretch: f32 = 0,

    /// How big a particle is at a scale of one, in metres across.
    size: f32 = 0.1,
    /// None is a soft round dot.
    texture: Assets.TextureHandle = .none,
    /// How many frames its texture holds across, for an animated particle.
    frames_across: u16 = 1,
    /// How many frames its texture holds down.
    frames_down: u16 = 1,
    /// How many times its frames play through over a particle's life; for
    /// nought, each shows one frame of its own, picked at random.
    frame_speed: f32 = 1,
    /// How big a particle starts, at random between these.
    scale_min: f32 = 1,
    /// How big a particle starts, at random between these.
    scale_max: f32 = 1,
    /// What its scale is multiplied by at the end of its life.
    scale_end: f32 = 1,
    /// How its scale goes from the start to `scale_end`.
    scale_curve: Curve = .linear,
    /// Its colour as it starts.
    color: Color = .white,
    /// A particle's colour starts somewhere between `color` and this.
    color_random: Color = .white,
    /// What its colour is multiplied by at the end of its life: an alpha of
    /// nought fades it out.
    color_end: Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    /// How its colour goes from `color` to `color_end`.
    color_curve: Curve = .linear,
    /// How it goes onto what is behind it: mixed by its alpha, added for a
    /// glow, taken away, or multiplied.
    blend: components3d.Sprite3D.Blend = .alpha,
    /// Whether it faces the camera, or the camera turning only about its up.
    billboard: components3d.Billboard = .enabled,
    /// Drawn over everything, whatever is in front of it.
    no_depth_test: bool = false,
    /// The render layers it is on: a camera whose `cull_mask` has none of
    /// them does not see it.
    layers: u32 = 1,

    pub const EmissionShape = enum(u8) { point, sphere, sphere_surface, box, ring };

    pub const signals = .{
        // A one-shot burst is over: the last of its particles is gone, and
        // `emitting` is off again.
        .finished = struct {},
    };

    pub const reflect_name = "Particles3D";
    pub const reflect_fields = .{
        .amount = .{attr.Range{ .min = 1, .max = max_amount }},
        .lifetime = .{ attr.Range{ .min = 0.01, .max = 600 }, attr.Unit{ .text = "s" } },
        .preprocess = .{ attr.Range{ .min = 0, .max = 600 }, attr.Unit{ .text = "s" } },
        .explosiveness = .{attr.Range{ .min = 0, .max = 1 }},
        .randomness = .{attr.Range{ .min = 0, .max = 1 }},
        .emission_shape = .{attr.Group{ .name = "Where they start" }},
        .emission_radius = .{attr.Unit{ .text = "m" }},
        .emission_extents = .{attr.Unit{ .text = "m" }},
        .direction = .{attr.Group{ .name = "Motion" }},
        .spread = .{attr.Angle{}},
        .speed_min = .{attr.Unit{ .text = "m/s" }},
        .speed_max = .{attr.Unit{ .text = "m/s" }},
        .gravity = .{attr.Unit{ .text = "m/s²" }},
        .angle_min = .{ attr.Angle{}, attr.Group{ .name = "Turning" } },
        .angle_max = .{attr.Angle{}},
        .spin_min = .{attr.Angle{}},
        .spin_max = .{attr.Angle{}},
        .size = .{ attr.Group{ .name = "Look" }, attr.Unit{ .text = "m" } },
        .frames_across = .{attr.Range{ .min = 1, .max = 256 }},
        .frames_down = .{attr.Range{ .min = 1, .max = 256 }},
        .blend = .{attr.Group{ .name = "Drawing" }},
        .layers = .{attr.Layers{ .names = .render_3d }},
    };
};

/// The most places an emitter may have.
pub const max_amount = 100_000;

/// One particle, in the world's space - or the emitter's, for one that
/// moves with it.
pub const Particle = struct {
    position: Vec3,
    velocity: Vec3,
    rotation: f32,
    spin: f32,
    age: f32,
    life: f32,
    scale: f32,
    color: Color,
    linear: f32,
    radial: f32,
    tangential: f32,
    damping: f32,
    pick: f32,
    alive: bool,

    const dead: Particle = .{
        .position = .zero,
        .velocity = .zero,
        .rotation = 0,
        .spin = 0,
        .age = 0,
        .life = 0,
        .scale = 1,
        .color = .white,
        .linear = 0,
        .radial = 0,
        .tangential = 0,
        .damping = 0,
        .pick = 0,
        .alive = false,
    };

    /// How far through its life it is, from nought to one.
    pub fn progress(self: Particle) f32 {
        return if (self.life > 0) std.math.clamp(self.age / self.life, 0, 1) else 1;
    }

    /// Its scale and colour as far through its life as it is, and which of
    /// the `frames` of its sheet it shows.
    pub fn shown(self: Particle, settings: *const Particles3D, frames: u32) Shown {
        const t = self.progress();
        const fade = settings.color_curve.at(t);
        const end = settings.color_end;
        return .{
            .scale = self.scale * lerp(1, settings.scale_end, settings.scale_curve.at(t)),
            .color = .{
                .r = self.color.r * lerp(1, end.r, fade),
                .g = self.color.g * lerp(1, end.g, fade),
                .b = self.color.b * lerp(1, end.b, fade),
                .a = self.color.a * lerp(1, end.a, fade),
            },
            .frame = frame: {
                if (frames <= 1) break :frame 0;
                const count: f32 = @floatFromInt(frames);
                const at = if (settings.frame_speed == 0) self.pick * count else t * settings.frame_speed * count;
                if (!std.math.isFinite(at)) break :frame 0;
                break :frame @intFromFloat(@mod(@floor(at), count));
            },
        };
    }

    pub const Shown = struct { scale: f32, color: Color, frame: u32 };
};

/// One emitter's particles and where it is in its cycle.
pub const Emitter = struct {
    particles: std.ArrayList(Particle) = .empty,
    places: usize = 0,
    random: std.Random.DefaultPrng = .init(0),
    clock: f32 = 0,
    begun: bool = false,
    spent: bool = false,
    was_emitting: bool = false,
    /// A preview's pause after a one-shot cycle, before it starts again.
    rest: f32 = 0,

    fn deinit(self: *Emitter, gpa: Allocator) void {
        self.particles.deinit(gpa);
    }

    pub fn aliveCount(self: *const Emitter) usize {
        var n: usize = 0;
        for (self.particles.items) |p| n += @intFromBool(p.alive);
        return n;
    }
};

/// Every 3D emitter's particles, by its entity.
pub const Emitters = struct {
    of_entity: std.AutoArrayHashMapUnmanaged(Entity, Emitter) = .empty,

    pub fn deinit(self: *Emitters, gpa: Allocator) void {
        for (self.of_entity.values()) |*e| e.deinit(gpa);
        self.of_entity.deinit(gpa);
    }

    pub fn get(self: *const Emitters, entity: Entity) ?*Emitter {
        return self.of_entity.getPtr(entity);
    }

    /// Those of the dead, and of what lost its `Particles3D`, let go.
    pub fn forgetDead(self: *Emitters, app: *App) void {
        var at: usize = 0;
        while (at < self.of_entity.count()) {
            const entity = self.of_entity.keys()[at];
            if (app.world.isAlive(entity) and app.world.has(entity, Particles3D)) {
                at += 1;
                continue;
            }
            self.of_entity.values()[at].deinit(app.gpa);
            self.of_entity.swapRemoveAt(at);
        }
    }

    pub fn clear(self: *Emitters, app: *App) void {
        for (self.of_entity.values()) |*e| e.deinit(app.gpa);
        self.of_entity.clearRetainingCapacity();
    }

    fn emitterOf(self: *Emitters, gpa: Allocator, entity: Entity) Allocator.Error!*Emitter {
        const got = try self.of_entity.getOrPut(gpa, entity);
        if (!got.found_existing) got.value_ptr.* = .{};
        return got.value_ptr;
    }
};

pub const Mode = @import("particles.zig").Mode;

/// Every 3D emitter moved on by `delta` seconds. What `App.step` calls
/// after the game's systems; an editor calls it with `.preview`.
pub fn update(app: *App, delta: f32, mode: Mode) !void {
    var finished: std.ArrayList(Entity) = .empty;
    defer finished.deinit(app.gpa);
    var it = ecs.Query(.{Particles3D}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Particles3D)) |entity, *settings| {
            if (mode == .game and !app.isProcessing(entity)) continue;
            const emitter = try app.particles3d.emitterOf(app.gpa, entity);
            const placed = placeOf(app, entity);
            if (try advance(app.gpa, emitter, settings, placed, delta, mode, app.random_source.random())) {
                if (mode == .game) {
                    settings.emitting = false;
                    emitter.was_emitting = false;
                    try finished.append(app.gpa, entity);
                }
            }
        }
    }
    for (finished.items) |entity| try app.emit(entity, Particles3D, .finished, .{});
}

/// Where the emitter is in the world now.
pub fn placeOf(app: *App, entity: Entity) Transform3D {
    const local = app.world.get(entity, Transform3D) orelse return .{};
    return hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local.*, 1) orelse local.*;
}

pub const Error = Allocator.Error || error{NotAnEmitter};

/// Start the cycle again, every particle gone, and emitting.
pub fn restart(app: *App, entity: Entity) Error!void {
    const settings = app.world.get(entity, Particles3D) orelse return error.NotAnEmitter;
    settings.emitting = true;
    const emitter = try app.particles3d.emitterOf(app.gpa, entity);
    emitter.particles.clearRetainingCapacity();
    emitter.begun = false;
    emitter.spent = false;
    emitter.clock = 0;
    emitter.was_emitting = true;
}

/// `count` particles let go of at once, over and above the cycle.
pub fn burst(app: *App, entity: Entity, count: u32) Error!void {
    const settings = app.world.get(entity, Particles3D) orelse return error.NotAnEmitter;
    const emitter = try app.particles3d.emitterOf(app.gpa, entity);
    if (!emitter.begun) try begin(app.gpa, emitter, settings, app.random_source.random());
    const placed = placeOf(app, entity);
    const room = max_amount -| (emitter.particles.items.len - emitter.places);
    for (0..@min(count, room)) |_| try emitter.particles.append(app.gpa, spawn(emitter.random.random(), settings, placed));
}

fn begin(gpa: Allocator, emitter: *Emitter, settings: *const Particles3D, chance: std.Random) Allocator.Error!void {
    const amount: usize = @min(@max(settings.amount, 1), max_amount);
    emitter.particles.clearRetainingCapacity();
    try emitter.particles.appendNTimes(gpa, Particle.dead, amount);
    emitter.places = amount;
    emitter.random = .init(if (settings.seed != 0) settings.seed else chance.int(u64));
    emitter.clock = 0;
    emitter.spent = false;
    emitter.begun = true;
}

/// Move one emitter on by `delta` seconds. True when a one-shot has just
/// ended: its cycle run, its last particle gone.
fn advance(gpa: Allocator, emitter: *Emitter, settings: *Particles3D, placed: Transform3D, delta: f32, mode: Mode, chance: std.Random) Allocator.Error!bool {
    const amount: usize = @min(@max(settings.amount, 1), max_amount);
    const turned_on = settings.emitting and !emitter.was_emitting;
    emitter.was_emitting = settings.emitting;
    if (turned_on and emitter.begun and emitter.places == amount) {
        emitter.clock = 0;
        emitter.spent = false;
    }
    if (!emitter.begun or emitter.places != amount) {
        try begin(gpa, emitter, settings, chance);
        if (settings.preprocess > 0 and settings.emitting) {
            var left = @min(settings.preprocess, 600);
            while (left > 0) {
                const step = @min(left, 1.0 / 30.0);
                run(emitter, settings, placed, step * settings.speed_scale);
                left -= step;
            }
        }
    }
    if (delta <= 0) return false;
    run(emitter, settings, placed, delta * settings.speed_scale);

    if (!settings.one_shot or !emitter.spent) return false;
    for (emitter.particles.items) |p| if (p.alive) return false;
    if (mode == .preview) {
        emitter.rest += delta;
        if (emitter.rest >= 0.5) {
            emitter.rest = 0;
            emitter.begun = false;
        }
        return false;
    }
    return settings.emitting;
}

fn run(emitter: *Emitter, settings: *const Particles3D, placed: Transform3D, dt: f32) void {
    const lifetime = @max(settings.lifetime, 0.001);
    const random = emitter.random.random();
    for (emitter.particles.items) |*p| move(p, settings, placed, dt);
    dropBursts(emitter);

    if (!settings.emitting or emitter.spent) return;
    const places = emitter.particles.items[0..emitter.places];
    const amount = places.len;
    const spread_over = lifetime * (1 - std.math.clamp(settings.explosiveness, 0, 1));
    var from = emitter.clock;
    var left = dt;
    var cycles: u8 = 0;
    while (left > 0 and cycles < 2) : (cycles += 1) {
        const to = @min(from + left, lifetime);
        for (0..amount) |i| {
            const start = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(amount)) * spread_over;
            if (start < from or start >= to) continue;
            places[i] = spawn(random, settings, placed);
            move(&places[i], settings, placed, to - start);
        }
        left -= to - from;
        from = to;
        if (from >= lifetime) {
            if (settings.one_shot) {
                emitter.spent = true;
                break;
            }
            from = 0;
        }
    }
    emitter.clock = from;
}

fn dropBursts(emitter: *Emitter) void {
    var i = emitter.particles.items.len;
    while (i > emitter.places) {
        i -= 1;
        if (!emitter.particles.items[i].alive) _ = emitter.particles.swapRemove(i);
    }
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// A way within `spread` radians of `way`, at random: evenly over the cap
/// of the sphere it cuts.
fn within(r: std.Random, way: Vec3, spread: f32) Vec3 {
    const axis = way.tryNorm() orelse Vec3.unit_y;
    const cone = std.math.clamp(spread, 0, std.math.pi);
    const lowest = @cos(cone);
    const z = lerp(1, lowest, r.float(f32));
    const around = r.float(f32) * std.math.tau;
    const out = @sqrt(@max(1 - z * z, 0));
    const side = axis.anyPerp().norm();
    const other = axis.cross(side);
    return axis.scale(z).add(side.scale(out * @cos(around))).add(other.scale(out * @sin(around)));
}

/// A new particle at the emitter, as its settings say.
fn spawn(random: std.Random, settings: *const Particles3D, placed: Transform3D) Particle {
    const r = random;
    var point: Vec3 = .zero;
    switch (settings.emission_shape) {
        .point => {},
        .sphere, .sphere_surface => {
            const way = within(r, .unit_y, std.math.pi);
            const reach = if (settings.emission_shape == .sphere) settings.emission_radius * std.math.cbrt(r.float(f32)) else settings.emission_radius;
            point = way.scale(reach);
        },
        .box => {
            const e = settings.emission_extents;
            point = .init((r.float(f32) * 2 - 1) * e.x, (r.float(f32) * 2 - 1) * e.y, (r.float(f32) * 2 - 1) * e.z);
        },
        .ring => {
            const angle = r.float(f32) * std.math.tau;
            point = .init(@cos(angle) * settings.emission_radius, 0, @sin(angle) * settings.emission_radius);
        },
    }
    const speed = lerp(settings.speed_min, settings.speed_max, r.float(f32));
    var velocity = within(r, settings.direction, settings.spread).scale(speed);
    var position = point;
    if (!settings.local_coords) {
        position = placed.apply(point);
        velocity = placed.rotation.quat().rotate(velocity);
    }
    const lifetime = @max(settings.lifetime, 0.001);
    const shade = r.float(f32);
    return .{
        .position = position,
        .velocity = velocity,
        .rotation = lerp(settings.angle_min, settings.angle_max, r.float(f32)),
        .spin = lerp(settings.spin_min, settings.spin_max, r.float(f32)),
        .age = 0,
        .life = lifetime * (1 - std.math.clamp(settings.randomness, 0, 1) * r.float(f32)),
        .scale = lerp(settings.scale_min, settings.scale_max, r.float(f32)),
        .color = .{
            .r = lerp(settings.color.r, settings.color_random.r, shade),
            .g = lerp(settings.color.g, settings.color_random.g, shade),
            .b = lerp(settings.color.b, settings.color_random.b, shade),
            .a = lerp(settings.color.a, settings.color_random.a, shade),
        },
        .linear = lerp(settings.linear_accel_min, settings.linear_accel_max, r.float(f32)),
        .radial = lerp(settings.radial_accel_min, settings.radial_accel_max, r.float(f32)),
        .tangential = lerp(settings.tangential_accel_min, settings.tangential_accel_max, r.float(f32)),
        .damping = lerp(settings.damping_min, settings.damping_max, r.float(f32)),
        .pick = r.float(f32),
        .alive = true,
    };
}

/// One particle moved on by `dt` seconds: pulled, pushed, slowed, turned
/// and aged; gone at the end of its life.
fn move(p: *Particle, settings: *const Particles3D, placed: Transform3D, dt: f32) void {
    if (!p.alive or dt <= 0) return;
    p.age += dt;
    if (p.age >= p.life) {
        p.alive = false;
        return;
    }
    const origin: Vec3 = if (settings.local_coords) .zero else placed.position;
    // Gravity is the world's: in the emitter's own space, turned into it.
    var accel = if (settings.local_coords) placed.rotation.quat().inverse().rotate(settings.gravity) else settings.gravity;
    const speed = p.velocity.len();
    if (p.linear != 0 and speed > 0) accel = accel.add(p.velocity.scale(p.linear / speed));
    const away = p.position.sub(origin);
    const distance = away.len();
    if (distance > 0 and p.radial != 0) accel = accel.add(away.scale(p.radial / distance));
    const flat = Vec3.init(away.x, 0, away.z);
    const flat_distance = flat.len();
    if (flat_distance > 0 and p.tangential != 0) accel = accel.add(Vec3.init(away.z, 0, -away.x).scale(p.tangential / flat_distance));
    p.velocity = p.velocity.add(accel.scale(dt));
    if (p.damping > 0) {
        const now = p.velocity.len();
        if (now > 0) p.velocity = p.velocity.scale(@max(now - p.damping * dt, 0) / now);
    }
    p.position = p.position.add(p.velocity.scale(dt));
    p.rotation += p.spin * dt;
}

test "a way within a spread stays in its cone, and a spread of nought is the way itself" {
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    const down: Vec3 = .init(0, -1, 0);
    for (0..200) |_| {
        const way = within(r, down, 0.3);
        try testing.expectApproxEqAbs(@as(f32, 1), way.len(), 1e-4);
        try testing.expect(way.dot(down) >= @cos(@as(f32, 0.3)) - 1e-4);
    }
    try testing.expect(within(r, .unit_x, 0).approxEql(.unit_x));
}
