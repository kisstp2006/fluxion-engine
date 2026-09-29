// SPDX-License-Identifier: BSD-3-Clause

//! `Particles2D`: sparks, smoke, rain, dust - many small pictures an entity
//! lets go of, each moving on its own for a while, shrinking and fading as
//! it goes.
//!
//! ```zig
//! _ = try world.spawnWith(.{
//!     fx.Transform2D.at(320, 300),
//!     fx.Particles2D{ .amount = 64, .lifetime = 1.5, .speed_min = 80, .speed_max = 140 },
//! });
//! ```
//!
//! **A cycle of places.** An emitter has `amount` places, and each starts a
//! particle once every `lifetime`, spread over it - or bunched at its start
//! by `explosiveness`, all at once at one. A particle lives its `lifetime`,
//! less up to `randomness` of it, and its place starts another when its turn
//! comes round. `one_shot` stops after one cycle: the last particle gone,
//! `emitting` is false and `finished` is said. `app.emitParticles(e, n)`
//! lets go of `n` more at once, over and above the cycle.
//!
//! **Where and how fast.** A particle starts at the emitter, or anywhere in
//! a circle, on its edge, or in a box around it; it goes along `direction`,
//! turned by up to `spread` either way, at a speed from `speed_min` to
//! `speed_max`. Gravity pulls it, its own acceleration pushes it along its
//! way, away from the emitter or round it, and damping slows it.
//!
//! **What it looks like.** Its picture - a soft round dot eight units across
//! without one, or a frame of a sheet of `frames_across` by `frames_down` -
//! at a scale from `scale_min` to `scale_max`, multiplied by `scale_end` by
//! the end of its life; its colour somewhere from `color` to `color_random`,
//! multiplied by `color_end` by then: an end alpha of nought fades it out.
//!
//! The particles are the app's, not the component's: `local_coords` moves
//! them with the emitter, and without it they stay where they were let go
//! as it moves on. They go with its entity, and start again after a
//! `restartParticles`. The emitter's `Appearance` shows them, and a
//! `Material` beside it draws them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("App.zig");
const attr = @import("attr.zig");
const Assets = @import("assets.zig");
const Color = @import("color.zig").Color;
const components = @import("components.zig");
const hierarchy = @import("hierarchy.zig");

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;
const Sprite = components.Sprite;

pub const Particles2D = extern struct {
    /// Whether places start particles. Set, after it was not, the cycle
    /// starts again from its beginning.
    emitting: bool = true,
    /// How many places the cycle has: as many particles at most, over and
    /// above those `emitParticles` lets go of.
    amount: u32 = 16,
    /// How long a particle lives, and so how long a cycle is, in seconds.
    lifetime: f32 = 1,
    one_shot: bool = false,
    /// Seconds run through before it is first shown: a fire already burning.
    preprocess: f32 = 0,
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

    emission_shape: EmissionShape = .point,
    emission_radius: f32 = 16,
    /// Half the box's size.
    emission_extents: Vec2 = .init(16, 16),

    /// The way particles go, turned with the emitter.
    direction: Vec2 = .init(0, -1),
    /// How far either way from `direction` a particle may go.
    spread: f32 = 0.5,
    speed_min: f32 = 40,
    speed_max: f32 = 80,
    gravity: Vec2 = .init(0, 40),
    /// Along its way: forward for more than nought, back for less.
    linear_accel_min: f32 = 0,
    linear_accel_max: f32 = 0,
    /// Away from the emitter for more than nought, towards it for less.
    radial_accel_min: f32 = 0,
    radial_accel_max: f32 = 0,
    /// Round the emitter, clockwise on screen for more than nought.
    tangential_accel_min: f32 = 0,
    tangential_accel_max: f32 = 0,
    /// Speed lost each second.
    damping_min: f32 = 0,
    damping_max: f32 = 0,
    /// How it is turned when it starts.
    angle_min: f32 = 0,
    angle_max: f32 = 0,
    /// How fast it turns.
    spin_min: f32 = 0,
    spin_max: f32 = 0,
    /// Turned the way it goes, its `x` along its path: a streak of rain.
    align_to_velocity: bool = false,

    /// None is a soft round dot, eight units across.
    texture: Assets.TextureHandle = .none,
    frames_across: u16 = 1,
    frames_down: u16 = 1,
    /// How many times its frames play through over a particle's life; for
    /// nought, each shows one frame of its own, picked at random.
    frame_speed: f32 = 1,
    scale_min: f32 = 1,
    scale_max: f32 = 1,
    /// What its scale is multiplied by at the end of its life.
    scale_end: f32 = 1,
    scale_curve: Curve = .linear,
    color: Color = .white,
    /// A particle's colour starts somewhere between `color` and this.
    color_random: Color = .white,
    /// What its colour is multiplied by at the end of its life: an alpha of
    /// nought fades it out.
    color_end: Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    color_curve: Curve = .linear,
    blend: Sprite.Blend = .alpha,
    layer: i16 = 0,
    order: f32 = 0,
    draw_order: DrawOrder = .oldest_first,

    pub const EmissionShape = enum(u8) { point, circle, circle_edge, rectangle };
    /// How a particle goes from its start to its end, over its life.
    pub const Curve = enum(u8) {
        linear,
        ease_in,
        ease_out,
        ease_in_out,

        pub fn at(self: Curve, t: f32) f32 {
            return switch (self) {
                .linear => t,
                .ease_in => math.ease.Kind.quad_in.apply(t),
                .ease_out => math.ease.Kind.quad_out.apply(t),
                .ease_in_out => math.ease.Kind.quad_in_out.apply(t),
            };
        }
    };
    pub const DrawOrder = enum(u8) { oldest_first, newest_first };

    pub const signals = .{
        .finished = struct {},
    };

    pub const reflect_name = "Particles2D";
    pub const reflect_fields = .{
        .amount = .{attr.Range{ .min = 1, .max = max_amount }},
        .lifetime = .{ attr.Range{ .min = 0.01, .max = 600 }, attr.Unit{ .text = "s" } },
        .preprocess = .{ attr.Range{ .min = 0, .max = 600 }, attr.Unit{ .text = "s" } },
        .explosiveness = .{attr.Range{ .min = 0, .max = 1 }},
        .randomness = .{attr.Range{ .min = 0, .max = 1 }},
        .emission_shape = .{ attr.Group{ .name = "Where they start" }, attr.Doc{ .text = "A point, anywhere in a circle, on its edge, or in a box" } },
        .emission_radius = .{attr.Radius{ .when = .{ .field = "emission_shape", .is = &.{ "circle", "circle_edge" } } }},
        .emission_extents = .{attr.Extents{ .when = .{ .field = "emission_shape", .is = &.{"rectangle"} } }},
        .direction = .{ attr.Group{ .name = "Motion" }, attr.Doc{ .text = "The way they go, turned with the emitter" } },
        .spread = .{ attr.Angle{}, attr.Doc{ .text = "How far either way from the direction one may go" } },
        .gravity = .{attr.Doc{ .text = "Pulls every particle, in units a second each second" }},
        .angle_min = .{ attr.Angle{}, attr.Group{ .name = "Turning" } },
        .angle_max = .{attr.Angle{}},
        .spin_min = .{attr.Angle{}},
        .spin_max = .{attr.Angle{}},
        .texture = .{ attr.Group{ .name = "Look" }, attr.Doc{ .text = "None is a soft round dot" } },
        .frames_across = .{attr.Range{ .min = 1, .max = 256 }},
        .frames_down = .{attr.Range{ .min = 1, .max = 256 }},
        .color_end = .{attr.Doc{ .text = "What its colour is multiplied by at the end of its life" }},
        .blend = .{attr.Group{ .name = "Drawing" }},
        .layer = .{attr.Doc{ .text = "Higher is drawn over lower" }},
        .order = .{attr.Doc{ .text = "Its place within its layer: lower first" }},
    };
};

/// The most places an emitter may have.
pub const max_amount = 100_000;

/// How big a particle with no picture is, in world units.
pub const dot_size = 8;

/// One particle, in the world's space - or the emitter's, for one that
/// moves with it.
pub const Particle = struct {
    position: Vec2,
    velocity: Vec2,
    rotation: f32,
    spin: f32,
    /// Seconds it has lived, and how long it lives.
    age: f32,
    life: f32,
    scale: f32,
    color: Color,
    linear: f32,
    radial: f32,
    tangential: f32,
    damping: f32,
    /// A number of its own, for the frame it shows with a `frame_speed` of
    /// nought.
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

    /// How it looks now, before its emitter's `Appearance`: its scale and
    /// colour as far through its life as it is, and which of the `frames`
    /// of its sheet it shows.
    pub fn shown(self: Particle, settings: *const Particles2D, frames: u32) Shown {
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
    /// Its places first, `places` of them, then what `emitParticles` let go
    /// of.
    particles: std.ArrayList(Particle) = .empty,
    /// How many of `particles` are the cycle's places: its `amount` when it
    /// began.
    places: usize = 0,
    random: std.Random.DefaultPrng = .init(0),
    /// Seconds into the cycle.
    clock: f32 = 0,
    /// Whether it has begun: its places made, its `preprocess` run.
    begun: bool = false,
    /// A one-shot cycle run to its end: no place starts again.
    spent: bool = false,
    /// `emitting` as it was last seen.
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

/// Every emitter's particles, by its entity.
pub const Particles = struct {
    by: std.AutoArrayHashMapUnmanaged(Entity, Emitter) = .empty,

    pub fn deinit(self: *Particles, gpa: Allocator) void {
        for (self.by.values()) |*e| e.deinit(gpa);
        self.by.deinit(gpa);
    }

    pub fn get(self: *const Particles, entity: Entity) ?*Emitter {
        return self.by.getPtr(entity);
    }

    /// Those of the dead, and of what lost its `Particles2D`, let go.
    pub fn forgetDead(self: *Particles, gpa: Allocator, world: *ecs.World) void {
        var at: usize = 0;
        while (at < self.by.count()) {
            const entity = self.by.keys()[at];
            if (world.isAlive(entity) and world.has(entity, Particles2D)) {
                at += 1;
                continue;
            }
            self.by.values()[at].deinit(gpa);
            self.by.swapRemoveAt(at);
        }
    }

    pub fn clearAll(self: *Particles, gpa: Allocator) void {
        for (self.by.values()) |*e| e.deinit(gpa);
        self.by.clearRetainingCapacity();
    }

    fn emitterOf(self: *Particles, gpa: Allocator, entity: Entity) Allocator.Error!*Emitter {
        const got = try self.by.getOrPut(gpa, entity);
        if (!got.found_existing) got.value_ptr.* = .{};
        return got.value_ptr;
    }
};

/// How the particles are moved on: in a game, or in an editor's preview,
/// which writes nothing to the component, says nothing, and starts a
/// one-shot again after a moment.
pub const Mode = enum { game, preview };

/// Every emitter moved on by `delta` seconds: its places started as their
/// turn comes, its particles moved and aged. What `App.step` calls after
/// the game's systems; an editor calls it with `.preview`.
pub fn update(app: *App, delta: f32, mode: Mode) !void {
    var finished: std.ArrayList(Entity) = .empty;
    defer finished.deinit(app.gpa);
    var it = ecs.Query(.{Particles2D}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Particles2D)) |entity, *settings| {
            if (mode == .game and !app.isProcessing(entity)) continue;
            const emitter = try app.particles.emitterOf(app.gpa, entity);
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
    for (finished.items) |entity| try app.emit(entity, Particles2D, .finished, .{});
}

/// Where the emitter is in the world now.
fn placeOf(app: *App, entity: Entity) Transform2D {
    const local = app.world.get(entity, Transform2D) orelse return .{};
    return hierarchy.resolve(&app.world, &app.snapshots, entity, local.*, 1) orelse local.*;
}

/// What can go wrong with an emitter: the entity has no `Particles2D`, or is
/// gone, or there is no room.
pub const Error = Allocator.Error || error{NotAnEmitter};

/// Start the cycle again, every particle gone, and emitting.
pub fn restart(app: *App, entity: Entity) Error!void {
    const settings = app.world.get(entity, Particles2D) orelse return error.NotAnEmitter;
    settings.emitting = true;
    const emitter = try app.particles.emitterOf(app.gpa, entity);
    emitter.particles.clearRetainingCapacity();
    emitter.begun = false;
    emitter.spent = false;
    emitter.clock = 0;
    emitter.was_emitting = true;
}

/// `count` particles let go of at once, over and above the cycle.
pub fn burst(app: *App, entity: Entity, count: u32) Error!void {
    const settings = app.world.get(entity, Particles2D) orelse return error.NotAnEmitter;
    const emitter = try app.particles.emitterOf(app.gpa, entity);
    if (!emitter.begun) try begin(app.gpa, emitter, settings, app.random_source.random());
    const placed = placeOf(app, entity);
    const room = max_amount -| (emitter.particles.items.len - emitter.places);
    for (0..@min(count, room)) |_| try emitter.particles.append(app.gpa, spawn(emitter.random.random(), settings, placed));
}

/// Its places made, empty, and its chance seeded: by its own `seed`, or for
/// nought from `chance` - the app's, which a game seeds to see the same
/// run again.
fn begin(gpa: Allocator, emitter: *Emitter, settings: *const Particles2D, chance: std.Random) Allocator.Error!void {
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
fn advance(gpa: Allocator, emitter: *Emitter, settings: *Particles2D, placed: Transform2D, delta: f32, mode: Mode, chance: std.Random) Allocator.Error!bool {
    const amount: usize = @min(@max(settings.amount, 1), max_amount);
    const turned_on = settings.emitting and !emitter.was_emitting;
    emitter.was_emitting = settings.emitting;
    if (turned_on and emitter.begun and emitter.places == amount) {
        // Turned on again: the cycle from its start, and what is still out
        // lives on.
        emitter.clock = 0;
        emitter.spent = false;
    }
    if (!emitter.begun or emitter.places != amount) {
        try begin(gpa, emitter, settings, chance);
        if (settings.preprocess > 0 and settings.emitting) {
            // Run through in steps of a thirtieth of a second.
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
        // A preview starts a one-shot again after half a second.
        emitter.rest += delta;
        if (emitter.rest >= 0.5) {
            emitter.rest = 0;
            emitter.begun = false;
        }
        return false;
    }
    return settings.emitting;
}

/// Places started as their turns come in the next `dt` seconds, and every
/// particle moved on by it.
fn run(emitter: *Emitter, settings: *const Particles2D, placed: Transform2D, dt: f32) void {
    const lifetime = @max(settings.lifetime, 0.001);
    const random = emitter.random.random();

    // Every particle moved on first, so one started below is moved only for
    // the part of the step after its start.
    for (emitter.particles.items) |*p| move(p, settings, placed, dt);
    dropBursts(emitter);

    if (!settings.emitting or emitter.spent) return;
    const places = emitter.particles.items[0..emitter.places];
    const amount = places.len;
    const spread_over = lifetime * (1 - std.math.clamp(settings.explosiveness, 0, 1));
    var from = emitter.clock;
    var left = dt;
    // At most two cycles a step: more is more than can be seen.
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

/// What `emitParticles` let go of and has died, taken away; the places
/// stay, alive or not.
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

/// A new particle at the emitter, as its settings say.
fn spawn(random: std.Random, settings: *const Particles2D, placed: Transform2D) Particle {
    const r = random;
    var point: Vec2 = .zero;
    switch (settings.emission_shape) {
        .point => {},
        .circle => {
            const angle = r.float(f32) * std.math.tau;
            const distance = settings.emission_radius * @sqrt(r.float(f32));
            point = .init(@cos(angle) * distance, @sin(angle) * distance);
        },
        .circle_edge => {
            const angle = r.float(f32) * std.math.tau;
            point = .init(@cos(angle) * settings.emission_radius, @sin(angle) * settings.emission_radius);
        },
        .rectangle => point = .init((r.float(f32) * 2 - 1) * settings.emission_extents.x, (r.float(f32) * 2 - 1) * settings.emission_extents.y),
    }
    const way = std.math.atan2(settings.direction.y, settings.direction.x) + (r.float(f32) * 2 - 1) * settings.spread;
    const speed = lerp(settings.speed_min, settings.speed_max, r.float(f32));
    var velocity: Vec2 = .init(@cos(way) * speed, @sin(way) * speed);
    var position = point;
    var rotation = lerp(settings.angle_min, settings.angle_max, r.float(f32));
    if (!settings.local_coords) {
        const at = placed.apply(point.x, point.y);
        position = .init(at.x, at.y);
        const c = @cos(placed.rotation);
        const s = @sin(placed.rotation);
        velocity = .init(velocity.x * c - velocity.y * s, velocity.x * s + velocity.y * c);
        rotation += placed.rotation;
    }
    const lifetime = @max(settings.lifetime, 0.001);
    const shade = r.float(f32);
    return .{
        .position = position,
        .velocity = velocity,
        .rotation = rotation,
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
fn move(p: *Particle, settings: *const Particles2D, placed: Transform2D, dt: f32) void {
    if (!p.alive or dt <= 0) return;
    p.age += dt;
    if (p.age >= p.life) {
        p.alive = false;
        return;
    }
    const origin: Vec2 = if (settings.local_coords) .zero else .init(placed.x, placed.y);
    var accel = settings.gravity;
    const speed = p.velocity.len();
    if (p.linear != 0 and speed > 0) accel = accel.add(p.velocity.scale(p.linear / speed));
    const away = p.position.sub(origin);
    const distance = away.len();
    if (distance > 0 and (p.radial != 0 or p.tangential != 0)) {
        const out = away.scale(1 / distance);
        accel = accel.add(out.scale(p.radial)).add(Vec2.init(-out.y, out.x).scale(p.tangential));
    }
    p.velocity = p.velocity.add(accel.scale(dt));
    if (p.damping > 0) {
        const now = p.velocity.len();
        if (now > 0) p.velocity = p.velocity.scale(@max(now - p.damping * dt, 0) / now);
    }
    p.position = p.position.add(p.velocity.scale(dt));
    p.rotation = if (settings.align_to_velocity and p.velocity.len() > 0)
        std.math.atan2(p.velocity.y, p.velocity.x)
    else
        p.rotation + p.spin * dt;
}
