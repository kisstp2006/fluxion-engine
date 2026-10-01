// SPDX-License-Identifier: BSD-3-Clause

//! Particles, headless: the cycle of places, a one-shot's end, a burst, what
//! moves with its emitter and what stays where it was let go of, and what is
//! drawn of them.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const particles = @import("particles.zig");
const scene = @import("../scene/scene.zig");
const script = @import("../script/script.zig");

const Transform2D = components.Transform2D;
const Particles2D = particles.Particles2D;

/// Frames a quarter of a second long, which a float holds exactly.
fn quartered() !*App {
    return App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25, .width = 400, .height = 400 });
}

/// Particles that stay where they start, and live a second.
const still: Particles2D = .{ .amount = 4, .lifetime = 1, .speed_min = 0, .speed_max = 0, .gravity = .zero, .seed = 3 };

test "an emitter's places each start a particle in turn over its lifetime, and each lives it through" {
    const app = try quartered();
    defer app.destroy();
    const fountain = try app.world.spawnWith(.{ Transform2D.at(200, 200), still });

    // One place a quarter: the first at nought, the last at three quarters.
    for ([_]u32{ 1, 2, 3 }) |wanted| {
        _ = try app.step();
        try testing.expectEqual(wanted, app.particleCount(fountain));
    }
    // The first dies at the end of its second as the last starts, and from
    // then on each place starts again as its particle dies.
    for (0..6) |_| {
        _ = try app.step();
        try testing.expectEqual(@as(u32, 3), app.particleCount(fountain));
    }

    // Turned off, what is out lives on and no more start.
    app.world.get(fountain, Particles2D).?.emitting = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.particleCount(fountain));
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.particleCount(fountain));

    // And turned on again, the cycle starts from its beginning.
    app.world.get(fountain, Particles2D).?.emitting = true;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.particleCount(fountain));
}

test "an explosive emitter lets all its places go at once, and a one-shot says finished when its last is gone" {
    const app = try quartered();
    defer app.destroy();
    const Heard = struct {
        var finished: u32 = 0;
        fn done(_: *App, _: struct {}) !void {
            finished += 1;
        }
    };
    Heard.finished = 0;
    var burst = still;
    burst.explosiveness = 1;
    burst.one_shot = true;
    const bang = try app.world.spawnWith(.{ Transform2D.at(200, 200), burst });
    try app.signal(bang, Particles2D, .finished).connectFn(Heard.done, .{});

    _ = try app.step();
    try testing.expectEqual(@as(u32, 4), app.particleCount(bang));
    for (0..2) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 4), app.particleCount(bang));
    // A second in, they are gone, and the emitter with them.
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.particleCount(bang));
    try testing.expectEqual(@as(u32, 1), Heard.finished);
    try testing.expect(!app.world.get(bang, Particles2D).?.emitting);
    for (0..4) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 1), Heard.finished);
    try testing.expectEqual(@as(u32, 0), app.particleCount(bang));

    // Started again: another burst, and another finished.
    try app.restartParticles(bang);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 4), app.particleCount(bang));
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 2), Heard.finished);
}

test "particles let go of by hand live over and above the cycle, and go when they die" {
    const app = try quartered();
    defer app.destroy();
    var quiet = still;
    quiet.emitting = false;
    const sparks = try app.world.spawnWith(.{ Transform2D.at(200, 200), quiet });

    try app.emitParticles(sparks, 10);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 10), app.particleCount(sparks));
    for (0..4) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.particleCount(sparks));
    // Only the places are kept.
    try testing.expectEqual(@as(usize, 4), app.particles.get(sparks).?.particles.items.len);

    const nothing = try app.world.spawn();
    try testing.expectError(error.NotAnEmitter, app.emitParticles(nothing, 1));
    try testing.expectError(error.NotAnEmitter, app.restartParticles(nothing));
}

test "particles in their emitter's space move with it, and the rest stay where they were let go of" {
    const app = try quartered();
    defer app.destroy();
    var held = still;
    held.explosiveness = 1;
    held.local_coords = true;
    var loose = still;
    loose.explosiveness = 1;
    const carried = try app.world.spawnWith(.{ Transform2D.at(100, 100), held });
    const left = try app.world.spawnWith(.{ Transform2D.at(100, 300), loose });
    _ = try app.step();
    app.world.get(carried, Transform2D).?.x = 150;
    app.world.get(left, Transform2D).?.x = 150;
    _ = try app.step();

    // Every particle drawn, the one set where the emitter is now and the
    // other where it was.
    try testing.expectEqual(@as(u32, 8), app.sprites.drawn);
    for (app.sprites.items.items) |item| {
        const middle = item.instance.corner(0.5, 0.5);
        const wanted: f32 = if (middle.y < 200) 150 else 100;
        try testing.expectApproxEqAbs(wanted, middle.x, 0.001);
        // No picture: the soft dot, its eight units across.
        try testing.expectApproxEqAbs(@as(f32, particles.dot_size), item.instance.place[2], 0.001);
    }

    // Gone with their emitter.
    app.world.despawn(carried);
    _ = try app.step();
    try testing.expect(app.particles.get(carried) == null);
    try testing.expectEqual(@as(u32, 4), app.sprites.drawn);
}

test "a particle shrinks, fades and turns through its sheet's frames as its life goes" {
    const settings: Particles2D = .{ .scale_end = 0.5, .color_end = .{ .r = 1, .g = 0, .b = 1, .a = 0 }, .frame_speed = 1 };
    var particle: particles.Particle = .{
        .position = .zero,
        .velocity = .zero,
        .rotation = 0,
        .spin = 0,
        .age = 0.6,
        .life = 1,
        .scale = 2,
        .color = .white,
        .linear = 0,
        .radial = 0,
        .tangential = 0,
        .damping = 0,
        .pick = 0.9,
        .alive = true,
    };
    const shown = particle.shown(&settings, 4);
    try testing.expectApproxEqAbs(@as(f32, 2 * 0.7), shown.scale, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.4), shown.color.g, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.4), shown.color.a, 1e-5);
    try testing.expectEqual(@as(u32, 2), shown.frame);

    // Twice through its frames, and none of its own at a speed of nought.
    var twice = settings;
    twice.frame_speed = 2;
    try testing.expectEqual(@as(u32, 0), particle.shown(&twice, 4).frame);
    var picked = settings;
    picked.frame_speed = 0;
    try testing.expectEqual(@as(u32, 3), particle.shown(&picked, 4).frame);
    particle.pick = 0.1;
    try testing.expectEqual(@as(u32, 0), particle.shown(&picked, 4).frame);
}

test "a scene keeps an emitter and its settings, and a script bursts one and hears it finish" {
    const app = try quartered();
    defer app.destroy();
    var smoke = still;
    smoke.emission_shape = .rectangle;
    smoke.blend = .additive;
    smoke.draw_order = .newest_first;
    _ = try app.world.spawnWith(.{ Transform2D.at(10, 10), smoke });
    const bytes = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(bytes);
    app.clearWorld();
    _ = try scene.read(app, bytes, .{});
    var it = try @import("fluxion_ecs").Query(.{Particles2D}).over(&app.world);
    const again = it.next().?.slice(Particles2D)[0];
    try testing.expectEqual(Particles2D.EmissionShape.rectangle, again.emission_shape);
    try testing.expectEqual(components.Sprite.Blend.additive, again.blend);
    try testing.expectEqual(Particles2D.DrawOrder.newest_first, again.draw_order);
    try testing.expectEqual(@as(u32, 3), again.seed);

    try app.useScripts(.{});
    const handle = try app.addScript("sparks.flux",
        \\var heard = 0;
        \\var out = 0;
        \\fn done() { heard += 1; }
        \\struct Sparks {
        \\    fn ready(self) {
        \\        const emitter = self.entity.get(Particles2D);
        \\        emitter.one_shot = true;
        \\        emitter.explosiveness = 1.0;
        \\        emitter.finished.connect(done);
        \\        self.entity.emitParticles(5);
        \\    }
        \\    fn update(self, delta: float) {
        \\        out = self.entity.particleCount();
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{ Transform2D.at(50, 50), still, script.Script.of(handle) });
    _ = try app.step();
    const scripts = app.scripts.?;
    const module = scripts.moduleOf(handle).?;
    _ = try app.step();
    try testing.expectEqual(@as(i64, 9), scripts.vm.get(module, "out").?.asInt());
    for (0..6) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    try testing.expectEqual(@as(i64, 1), scripts.vm.get(module, "heard").?.asInt());
}
