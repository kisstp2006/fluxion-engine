// SPDX-License-Identifier: BSD-3-Clause

//! A `Tween`: properties moved from what they hold to what they are given,
//! over time, along a curve - a panel faded in, a menu slid over - on an
//! entity of its own that goes once it is done.
//!
//! ```zig
//! const slide = try app.tween(menu);                  // hangs from `menu`, and goes with it
//! try app.tweenParallel(slide, true);                 // the steps after this start together
//! try app.tweenProperty(slide, overlay, "Appearance.modulate.a", .{ .number = 1 }, 0.2);
//! try app.tweenProperty(slide, overlay, "Control.offset_x,offset_y", .{ .vec2 = .{ 0, 0 } }, 0.26);
//! try app.signal(slide, fx.Tween, .finished).connectFn(shown, .{});
//! app.world.despawn(slide);                           // stops it where it is
//! ```
//!
//! **Steps** run one after another, or with `tweenParallel` on, together with
//! the one before them. A step takes the value its property holds when the
//! step starts, and moves it to the one it was given by the curve
//! `tweenEase` named last - `quad_out`, `back_in`, ... - or in a straight line.
//! `tweenInterval` waits. See `property.zig` for what a property is.
//!
//! **Moved by the engine** once a frame before the `.update` systems, while
//! the tween's entity runs: one made under a pause menu goes on while the
//! game is paused, and one under the game waits. A frame with no time moves
//! nothing, as an editor's never does. `finished` is said once it has played
//! through `loops` times - 0 is for ever - and the entity goes in the frame
//! after.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("App.zig");
const attr = @import("attr.zig");
const property_mod = @import("property.zig");

const Entity = ecs.Entity;
const Property = property_mod.Property;
const Value = property_mod.Value;

pub const Tween = extern struct {
    /// Faster above 1, slower below.
    speed: f32 = 1,
    /// Times it plays through before it is done; 0 for ever.
    loops: u32 = 1,
    /// Held where it is while on.
    paused: bool = false,
    /// Seconds into this time through it.
    elapsed: f32 = 0,
    /// Times it has played through.
    passes: u32 = 0,
    /// Played through the last time: it goes at the next pass.
    done: bool = false,

    pub const signals = .{ .finished = struct {} };

    pub const reflect_name = "Tween";
    pub const reflect_fields = .{
        .speed = .{attr.Doc{ .text = "Faster above 1, slower below" }},
        .loops = .{attr.Doc{ .text = "Times it plays through; 0 for ever" }},
        .paused = .{attr.Doc{ .text = "Held where it is" }},
        .elapsed = .{ attr.ReadOnly{}, attr.Unit{ .text = "s" } },
        .passes = .{attr.ReadOnly{}},
        .done = .{attr.Hidden{}},
    };
};

/// One step of a tween.
pub const Step = struct {
    target: Entity = .none,
    /// Null for a wait.
    property: ?Property = null,
    to: Value = .{ .number = 0 },
    seconds: f32,
    ease: math.ease.Kind = .linear,
    /// Starts with the step before it, rather than after it.
    with_before: bool = false,
    /// What the property held when the step started, this time through.
    from: ?Value = null,
    /// Done, this time through.
    finished: bool = false,
};

/// Each tween's steps, and what the steps added next are like.
pub const Plan = struct {
    steps: std.ArrayList(Step) = .empty,
    parallel: bool = false,
    ease: math.ease.Kind = .linear,
};

/// Every tween's plan: `app.tweens`.
pub const Tweens = struct {
    by: std.AutoArrayHashMapUnmanaged(Entity, Plan) = .empty,
    /// The tweens done this pass, to say so after it.
    ended: std.ArrayList(Entity) = .empty,

    pub fn deinit(self: *Tweens, gpa: Allocator) void {
        for (self.by.values()) |*plan| plan.steps.deinit(gpa);
        self.by.deinit(gpa);
        self.ended.deinit(gpa);
    }

    /// Every tween is gone: the world was cleared.
    pub fn clear(self: *Tweens, gpa: Allocator) void {
        for (self.by.values()) |*plan| plan.steps.deinit(gpa);
        self.by.clearRetainingCapacity();
    }

    /// The plan of a tween, made the first time it is asked for.
    pub fn planOf(self: *Tweens, gpa: Allocator, tween: Entity) Allocator.Error!*Plan {
        const entry = try self.by.getOrPut(gpa, tween);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    /// Let go of the plans of the tweens that died.
    pub fn forgetDead(self: *Tweens, gpa: Allocator, world: *const ecs.World) void {
        var at = self.by.count();
        while (at > 0) {
            at -= 1;
            if (world.isAlive(self.by.keys()[at])) continue;
            self.by.values()[at].steps.deinit(gpa);
            self.by.swapRemoveAt(at);
        }
    }
};

/// Move every tween on by `delta` seconds. What `App.step` calls.
pub fn update(app: *App, delta: f32) !void {
    const tweens = &app.tweens;
    tweens.ended.clearRetainingCapacity();
    var gone: std.ArrayList(Entity) = .empty;
    defer gone.deinit(app.gpa);

    var it = ecs.Query(.{Tween}).over(&app.world) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyComponents => return,
    };
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(Tween)) |e, *tween| {
            if (tween.done) {
                try gone.append(app.gpa, e);
                continue;
            }
            if (delta <= 0 or tween.paused or !app.isProcessing(e)) continue;
            // One with nothing in it has nothing to wait for.
            const plan = tweens.by.getPtr(e) orelse {
                tween.done = true;
                try tweens.ended.append(app.gpa, e);
                continue;
            };
            tween.elapsed += delta * @max(tween.speed, 0);
            const length = advance(app, plan, tween.elapsed);
            if (tween.elapsed < length) continue;
            tween.passes += 1;
            // Done - or, with nothing in it to take time, done at once
            // rather than going round for ever in one frame.
            if ((tween.loops != 0 and tween.passes >= tween.loops) or !(length > 0)) {
                tween.done = true;
                try tweens.ended.append(app.gpa, e);
                continue;
            }
            tween.elapsed = @mod(tween.elapsed - length, length);
            for (plan.steps.items) |*step| {
                step.from = null;
                step.finished = false;
            }
        }
    }
    for (tweens.ended.items) |e| try app.emit(e, Tween, .finished, .{});
    for (gone.items) |e| app.world.despawn(e);
}

/// Every step as it is `elapsed` seconds into the plan, and how long the
/// plan takes.
fn advance(app: *App, plan: *Plan, elapsed: f32) f32 {
    const steps = plan.steps.items;
    var start: f32 = 0;
    var first: usize = 0;
    while (first < steps.len) {
        // The steps that start together.
        var end = first + 1;
        while (end < steps.len and steps[end].with_before) end += 1;
        var length: f32 = 0;
        for (steps[first..end]) |step| length = @max(length, step.seconds);

        if (elapsed >= start) for (steps[first..end]) |*step| {
            if (step.finished) continue;
            const local = elapsed - start;
            const t: f32 = if (step.seconds > 0) std.math.clamp(local / step.seconds, 0, 1) else 1;
            if (step.property) |held| {
                if (step.from == null) step.from = held.read(app, step.target) orelse {
                    // Its entity, or its component, is gone.
                    step.finished = true;
                    continue;
                };
                const value = if (t >= 1) step.to else step.from.?.lerp(step.to, step.ease.apply(t));
                _ = held.write(app, step.target, value);
            }
            if (t >= 1) step.finished = true;
        };
        start += length;
        first = end;
    }
    return start;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const components = @import("components.zig");

/// A quarter of a second a frame.
fn quartered() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    return app;
}

const Heard = struct {
    var finished: usize = 0;

    fn done(_: *App, _: struct {}) !void {
        finished += 1;
    }
};

test "a tween moves its steps one after another, says finished, and goes" {
    const app = try quartered();
    defer app.destroy();
    Heard.finished = 0;
    const box = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const moving = try app.tween(.none);
    try app.tweenProperty(moving, box, "Transform2D.x", .{ .number = 100 }, 1);
    try app.tweenInterval(moving, 0.5);
    try app.tweenProperty(moving, box, "Transform2D.y", .{ .number = -40 }, 0.5);
    try app.signal(moving, Tween, .finished).connectFn(Heard.done, .{});

    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 25), app.world.get(box, components.Transform2D).?.x, 0.001);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 100), app.world.get(box, components.Transform2D).?.x);
    try testing.expectEqual(@as(f32, 0), app.world.get(box, components.Transform2D).?.y);
    // Waited, then the second half of the way.
    for (0..3) |_| _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, -20), app.world.get(box, components.Transform2D).?.y, 0.001);
    _ = try app.step();
    try testing.expectEqual(@as(f32, -40), app.world.get(box, components.Transform2D).?.y);
    try testing.expectEqual(@as(usize, 1), Heard.finished);
    _ = try app.step();
    try testing.expect(!app.world.isAlive(moving));
}

test "steps started together, along a curve, from where each was when it started" {
    const app = try quartered();
    defer app.destroy();
    const panel = try app.world.spawnWith(.{ components.Transform2D.at(-200, 10), @import("inherited.zig").Appearance{} });
    const slide = try app.tween(panel);
    try app.tweenParallel(slide, true);
    try testing.expect(app.tweenEase(slide, "quad_out"));
    try app.tweenProperty(slide, panel, "Appearance.modulate.a", .{ .number = 0 }, 0.5);
    try app.tweenProperty(slide, panel, "Transform2D.x,y", .{ .vec2 = .{ 0, 0 } }, 1);
    try testing.expect(!app.tweenEase(slide, "wobbly"));

    _ = try app.step();
    // A quarter of the way along quad_out is seven sixteenths of the move.
    const halfway = app.world.get(panel, @import("inherited.zig").Appearance).?.modulate.a;
    try testing.expectApproxEqAbs(@as(f32, 0.25), halfway, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -200 + 200 * 0.4375), app.world.get(panel, components.Transform2D).?.x, 0.01);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.world.get(panel, @import("inherited.zig").Appearance).?.modulate.a);
    try testing.expectEqual(@as(f32, 0), app.world.get(panel, components.Transform2D).?.x);

    // One that hangs from its entity goes with it.
    const again = try app.tween(panel);
    try app.tweenProperty(again, panel, "Transform2D.x", .{ .number = 50 }, 1);
    app.world.despawn(panel);
    for (0..2) |_| _ = try app.step();
    try testing.expect(!app.world.isAlive(again));
}

test "a tween loops, waits while its entity is paused, and a wrong property says so" {
    const app = try quartered();
    defer app.destroy();
    const box = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});
    const beat = try app.tween(.none);
    app.world.get(beat, Tween).?.loops = 0;
    try app.tweenProperty(beat, box, "Transform2D.rotation", .{ .number = 1 }, 0.5);
    try testing.expectError(error.NoSuchField, app.tweenProperty(beat, box, "Transform2D.spin", .{ .number = 1 }, 1));
    try testing.expectError(error.NoSuchComponent, app.tweenProperty(beat, box, "Wobble.x", .{ .number = 1 }, 1));

    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(box, components.Transform2D).?.rotation, 0.001);
    for (0..3) |_| _ = try app.step();
    // Round again from where the step found it: already at the end.
    try testing.expectEqual(@as(u32, 2), app.world.get(beat, Tween).?.passes);
    app.setPaused(true);
    const held = app.world.get(beat, Tween).?.elapsed;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(held, app.world.get(beat, Tween).?.elapsed);
    try testing.expect(app.world.isAlive(beat));
}
