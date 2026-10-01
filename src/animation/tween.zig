// SPDX-License-Identifier: BSD-3-Clause

//! A `Tween`: properties moved from what they hold to what they are given,
//! over time, along a curve - a panel faded in, a menu slid over - on an
//! entity of its own that goes once it is done.
//!
//! ```zig
//! const slide = try app.tween(menu);                  // hangs from `menu`, and goes with it
//! try app.tweenParallel(slide, true);                 // the steps after this start together
//! try app.tweenProperty(slide, overlay, "Appearance.modulate.a", .{ .number = 1 }, 0.2);
//! try app.tweenProperty(slide, overlay, "Control.offset_left,offset_top", .{ .vec2 = .{ 0, 0 } }, 0.26);
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
//! **The step just added** can start from a value of its own (`tweenFrom`),
//! move by its value rather than to it (`tweenRelative`), and wait before it
//! starts (`tweenDelay`). A script's function is a step too: called once
//! when it is reached (`tweenCallback`), or with each value along the way
//! (`tweenMethod`) - held by the scripts while the tween holds it.
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

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const property_mod = @import("../reflect/property.zig");
const flux = @import("../script/script.zig").flux;

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
    /// Null for a wait, or a call.
    property: ?Property = null,
    to: Value = .{ .number = 0 },
    seconds: f32,
    ease: math.ease.Kind = .linear,
    /// Starts with the step before it, rather than after it.
    with_before: bool = false,
    /// Seconds it waits, after the ones it starts with have started.
    delay: f32 = 0,
    /// Where it starts, rather than what its property holds then.
    start_at: ?Value = null,
    /// It moves by `to` from where it starts, rather than to it.
    relative: bool = false,
    /// A script's function it calls, held by the scripts: `.null` for none.
    call: flux.Value = .null,
    /// Its function is called with each value from `start_at` to `to`, not
    /// once at the end.
    along: bool = false,
    /// What the property held when the step started, this time through,
    /// and where it goes.
    from: ?Value = null,
    aim: Value = .{ .number = 0 },
    /// Done, this time through.
    finished: bool = false,

    /// How long it takes, its wait with it.
    fn length(self: Step) f32 {
        return self.delay + self.seconds;
    }
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
    pub fn clear(self: *Tweens, app: *App) void {
        for (self.by.values()) |*plan| forget(app, plan);
        self.by.clearRetainingCapacity();
    }

    /// The plan of a tween, made the first time it is asked for.
    pub fn planOf(self: *Tweens, gpa: Allocator, tween: Entity) Allocator.Error!*Plan {
        const entry = try self.by.getOrPut(gpa, tween);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    /// Let go of the plans of the tweens that died.
    pub fn forgetDead(self: *Tweens, app: *App) void {
        var at = self.by.count();
        while (at > 0) {
            at -= 1;
            if (app.world.isAlive(self.by.keys()[at])) continue;
            forget(app, &self.by.values()[at]);
            self.by.swapRemoveAt(at);
        }
    }

    /// A plan's steps let go of, and the functions they held.
    fn forget(app: *App, plan: *Plan) void {
        if (app.scripts) |scripts| for (plan.steps.items) |step| {
            if (step.call.tag != .null) scripts.calls.release(scripts, step.call);
        };
        plan.steps.deinit(app.gpa);
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
        for (steps[first..end]) |step| length = @max(length, step.length());

        if (elapsed >= start) for (steps[first..end]) |*step| {
            if (step.finished) continue;
            const local = elapsed - start - step.delay;
            if (local < 0) continue;
            const t: f32 = if (step.seconds > 0) std.math.clamp(local / step.seconds, 0, 1) else 1;
            if (step.property) |held| {
                if (step.from == null) {
                    step.from = step.start_at orelse held.read(app, step.target) orelse {
                        // Its entity, or its component, is gone.
                        step.finished = true;
                        continue;
                    };
                    step.aim = if (step.relative) step.from.?.plus(step.to) else step.to;
                }
                const value = if (t >= 1) step.aim else step.from.?.lerp(step.aim, step.ease.apply(t));
                _ = held.write(app, step.target, value);
            } else if (step.call.tag != .null) {
                if (app.scripts) |scripts| {
                    if (step.along) {
                        const from = step.start_at orelse step.to;
                        scripts.calls.callNow(scripts, step.call, if (t >= 1) step.to else from.lerp(step.to, step.ease.apply(t)));
                    } else if (t >= 1) scripts.calls.callNow(scripts, step.call, null);
                }
            }
            if (t >= 1) step.finished = true;
        };
        start += length;
        first = end;
    }
    return start;
}
