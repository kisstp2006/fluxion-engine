// SPDX-License-Identifier: BSD-3-Clause

//! Signals and events through a whole app, frame by frame: who hears what,
//! when, and with which arguments.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");
const signals = @import("signals.zig");
const events = @import("events.zig");
const scene_mod = @import("scene.zig");
const json = @import("fluxion_json");
const Transform2D = @import("components.zig").Transform2D;

const Entity = ecs.Entity;

const Health = extern struct {
    hp: f32 = 100,

    pub const signals = .{
        .died = struct {},
        .hit = struct { damage: f32, by: Entity },
    };
    pub const reflect_methods = .{.heal};

    pub fn heal(self: *Health, amount: f32) void {
        self.hp += amount;
    }
};

const Armour = extern struct {
    points: f32 = 0,

    pub const signals = .{ .hit = struct { damage: f32 } };
};

/// What the handlers heard, in order.
const Heard = struct {
    var calls: [32]Call = undefined;
    var len: usize = 0;

    const Call = struct { who: u8, damage: f32 = 0, frame: u64 = 0 };

    fn reset() void {
        len = 0;
    }

    fn note(call: Call) void {
        calls[len] = call;
        len += 1;
    }

    fn onHit(app: *App, self: Entity, damage: f32, by: Entity) !void {
        _ = self;
        _ = by;
        note(.{ .who = 1, .damage = damage, .frame = app.time.frame });
    }

    fn onHitFn(app: *App, args: struct { damage: f32, by: Entity }) !void {
        note(.{ .who = 2, .damage = args.damage, .frame = app.time.frame });
    }

    fn onHitAgainFn(app: *App, args: struct { damage: f32, by: Entity }) !void {
        note(.{ .who = 4, .damage = args.damage, .frame = app.time.frame });
    }

    fn onDied(_: *App, _: Entity) !void {
        note(.{ .who = 5 });
    }

    fn fails(_: *App, _: Entity, _: f32, _: Entity) !void {
        note(.{ .who = 3 });
        return error.Deliberate;
    }
};

fn made() !struct { app: *App, player: Entity, hud: Entity } {
    const app = try App.create(testing.allocator, .{ .headless = true });
    errdefer app.destroy();
    try app.registerComponents(.{ Health, Armour });
    const player = try app.world.spawnWith(.{ Transform2D{}, Health{} });
    const hud = try app.world.spawnWith(.{Transform2D{}});
    try app.addMethod("_on_hit", Heard.onHit);
    try app.addMethod("_fails", Heard.fails);
    Heard.reset();
    return .{ .app = app, .player = player, .hud = hud };
}

const Emitter = struct {
    var player: Entity = .none;
    var damage: f32 = 5;
    var inside_query = false;

    fn hit(app: *App) anyerror!void {
        try app.emit(player, Health, .hit, .{ .damage = damage, .by = player });
        // Not heard yet: this system has not returned.
        inside_query = Heard.len != 0;
    }
};

test "an emit is heard when the emitting system returns, with its arguments" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();
    Emitter.player = scene.player;
    Emitter.damage = 5;
    try app.addSystem(.update, "hit", Emitter.hit);

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_on_hit"), .{});
    try hit.connectFn(Heard.onHitFn, .{});
    try testing.expect(hit.hasConnections());

    _ = try app.step();
    try testing.expect(!Emitter.inside_query);
    try testing.expectEqual(@as(usize, 2), Heard.len);
    // In the order they were connected, Godot 4's.
    try testing.expectEqual(@as(u8, 1), Heard.calls[0].who);
    try testing.expectEqual(@as(u8, 2), Heard.calls[1].who);
    try testing.expectEqual(@as(f32, 5), Heard.calls[0].damage);
    try testing.expectEqual(@as(f32, 5), Heard.calls[1].damage);
}

test "a second connect is refused, unless counted, and a count is taken one at a time" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_on_hit"), .{});
    try testing.expectError(error.AlreadyConnected, hit.connect(.method(scene.hud, "_on_hit"), .{}));
    // A Zig function is the same one by its address, and another is not it.
    try hit.connectFn(Heard.onHitFn, .{});
    try testing.expectError(error.AlreadyConnected, hit.connectFn(Heard.onHitFn, .{}));
    try hit.connectFn(Heard.onHitAgainFn, .{});
    try hit.emit(.{ .damage = 1, .by = scene.player });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 3), Heard.len);

    const died = app.signal(scene.player, Health, .died);
    const counted: signals.Options = .{ .flags = .{ .reference_counted = true } };
    try died.connect(.method(scene.hud, "_on_died"), counted);
    try died.connect(.method(scene.hud, "_on_died"), counted);
    var found: [4]signals.Connection = undefined;
    try testing.expectEqual(@as(u32, 2), died.connections(&found)[0].count);
    died.disconnect(.method(scene.hud, "_on_died"));
    try testing.expect(died.isConnected(.method(scene.hud, "_on_died")));
    died.disconnect(.method(scene.hud, "_on_died"));
    try testing.expect(!died.isConnected(.method(scene.hud, "_on_died")));
}

test "a one-shot connection goes as it is emitted, before it is heard" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_on_hit"), .{ .flags = .{ .one_shot = true } });
    try hit.emit(.{ .damage = 1, .by = scene.player });
    // Gone at once, though nothing has heard it yet.
    try testing.expect(!hit.hasConnections());
    try hit.emit(.{ .damage = 2, .by = scene.player });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 1), Heard.len);
    try testing.expectEqual(@as(f32, 1), Heard.calls[0].damage);
}

test "a component's own method is called by name, on the target" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();
    const medic = try app.world.spawnWith(.{ Transform2D{}, Health{ .hp = 10 } });

    // `died` carries nothing; the bind is what `heal` is handed.
    try app.signal(scene.player, Health, .died).connect(.method(medic, "heal"), .{ .binds = &.{.{ .float = 15 }} });
    try app.emit(scene.player, Health, .died, .{});
    try app.signals.drain(app);
    try testing.expectEqual(@as(f32, 25), app.world.get(medic, Health).?.hp);
}

test "unbinds drop the last arguments, and the source and the binds come after" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const Took = struct {
        var got_damage: f32 = 0;
        var got_from: Entity = .none;
        var got_difficulty: i64 = 0;

        fn took(_: *App, _: Entity, damage: f32, from: Entity, difficulty: i64) !void {
            got_damage = damage;
            got_from = from;
            got_difficulty = difficulty;
        }
    };
    try app.addMethod("_took", Took.took);
    // `by` unbound, the source appended in its place, then a bind.
    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_took"), .{
        .flags = .{ .append_source = true },
        .unbinds = 1,
        .binds = &.{.{ .int = 3 }},
    });
    try app.emit(scene.player, Health, .hit, .{ .damage = 7, .by = scene.hud });
    try app.signals.drain(app);
    try testing.expectEqual(@as(f32, 7), Took.got_damage);
    try testing.expect(Took.got_from.eql(scene.player));
    try testing.expectEqual(@as(i64, 3), Took.got_difficulty);
}

test "a handler's error is said and counted, and the rest are still heard" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_fails"), .{});
    try hit.connect(.method(scene.hud, "_missing"), .{});
    try hit.connect(.method(scene.hud, "_on_hit"), .{});
    try hit.emit(.{ .damage = 1, .by = scene.player });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 2), app.signals.failures);
    try testing.expectEqual(@as(usize, 2), Heard.len);
    try testing.expectEqual(@as(u8, 1), Heard.calls[1].who);
}

test "a handler that emits is heard in the same drain, and a loop is stopped" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const Echo = struct {
        var player: Entity = .none;
        var times: usize = 0;

        fn echo(a: *App, _: Entity, damage: f32, by: Entity) !void {
            times += 1;
            if (damage > 1) try a.emit(player, Health, .hit, .{ .damage = damage - 1, .by = by });
        }
    };
    Echo.player = scene.player;
    Echo.times = 0;
    try app.addMethod("_echo", Echo.echo);
    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_echo"), .{});

    try app.emit(scene.player, Health, .hit, .{ .damage = 4, .by = scene.hud });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 4), Echo.times);

    // Round and round, past the cap: stopped, and said.
    app.signals.max_calls = 50;
    Echo.times = 0;
    try app.emit(scene.player, Health, .hit, .{ .damage = 1000, .by = scene.hud });
    try testing.expectError(error.TooManyCalls, app.signals.drain(app));
    try testing.expectEqual(@as(usize, 50), Echo.times);
}

test "a deferred call is heard at the end of the frame, after late" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const Order = struct {
        var late_ran_at: usize = 0;

        fn late(_: *App) anyerror!void {
            late_ran_at = Heard.len;
        }
    };
    Emitter.player = scene.player;
    try app.addSystem(.update, "hit", Emitter.hit);
    try app.addSystem(.late, "late", Order.late);
    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_on_hit"), .{ .flags = .{ .deferred = true } });

    _ = try app.step();
    // Not by `.late`, but by the end of the frame.
    try testing.expectEqual(@as(usize, 0), Order.late_ran_at);
    try testing.expectEqual(@as(usize, 1), Heard.len);
}

test "what a deferred call emits is heard in the same frame, and its arguments outlast other emits" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();
    const bystander = try app.world.spawnWith(.{ Transform2D{}, Health{} });

    const Twice = struct {
        var player: Entity = .none;
        var other: Entity = .none;

        fn first(a: *App) anyerror!void {
            try a.emit(player, Health, .hit, .{ .damage = 5, .by = player });
        }
        fn second(a: *App) anyerror!void {
            try a.emit(other, Health, .hit, .{ .damage = 9, .by = other });
        }
        fn relay(a: *App, _: Entity, _: f32, _: Entity) !void {
            try a.emit(player, Health, .died, .{});
        }
    };
    Twice.player = scene.player;
    Twice.other = bystander;
    try app.addMethod("_relay", Twice.relay);
    try app.addMethod("_on_died", Heard.onDied);
    try app.addSystem(.update, "first", Twice.first);
    try app.addSystem(.update, "second", Twice.second);
    const deferred: signals.Options = .{ .flags = .{ .deferred = true } };
    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_on_hit"), deferred);
    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_relay"), deferred);
    try app.signal(scene.player, Health, .died).connect(.method(scene.hud, "_on_died"), .{});
    try app.signal(bystander, Health, .hit).connect(.method(scene.hud, "_on_hit"), .{});

    _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Heard.len);
    // The other's as its system returned; the player's at the end of the
    // frame, with its own arguments though others were copied since; and
    // what the relay emitted, as it returned.
    try testing.expectEqual(@as(f32, 9), Heard.calls[0].damage);
    try testing.expectEqual(@as(f32, 5), Heard.calls[1].damage);
    try testing.expectEqual(@as(u8, 5), Heard.calls[2].who);
}

test "a blocked entity's emits do nothing, and an editor's switch calls nothing" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_on_hit"), .{});

    try app.setBlockSignals(scene.player, true);
    try testing.expect(app.isBlockingSignals(scene.player));
    try hit.emit(.{ .damage = 1, .by = scene.player });
    try app.setBlockSignals(scene.player, false);

    app.signals.dispatch = false;
    try hit.emit(.{ .damage = 2, .by = scene.player });
    app.signals.dispatch = true;

    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 0), Heard.len);
    // Kept all the while.
    try testing.expect(hit.hasConnections());
}

test "a call to what has died is not made, and the connections go with the dead" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    const hit = app.signal(scene.player, Health, .hit);
    try hit.connect(.method(scene.hud, "_on_hit"), .{});
    try hit.emit(.{ .damage = 1, .by = scene.player });
    app.world.despawn(scene.hud);
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 0), Heard.len);
    try testing.expectEqual(@as(usize, 0), app.signals.failures);

    _ = try app.step();
    try testing.expect(!hit.hasConnections());

    // And a source that dies takes its own.
    const medic = try app.world.spawnWith(.{ Transform2D{}, Health{} });
    try app.signal(scene.player, Health, .died).connect(.method(medic, "heal"), .{});
    var found: [4]signals.Connection = undefined;
    try testing.expectEqual(@as(usize, 1), app.connectionsTo(medic, &found).len);
    app.world.despawn(scene.player);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.connectionsTo(medic, &found).len);
}

test "a signal is found by its name, and by its component's when two declare it" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    try testing.expect(app.hasSignal(scene.player, "hit"));
    try testing.expect(!app.hasSignal(scene.player, "healed"));
    _ = try app.signalNamed(scene.player, "hit");

    try app.world.add(scene.player, Armour{});
    try testing.expectError(error.AmbiguousSignal, app.signalNamed(scene.player, "hit"));
    const armour = try app.signalNamed(scene.player, "Armour.hit");
    try testing.expectEqualStrings("Armour", armour.component);

    // Kept as `Component.name`, now that the bare one is two.
    try armour.connect(.method(scene.hud, "_on_hit"), .{});
    var found: [4]signals.Connection = undefined;
    try testing.expectEqualStrings("Armour.hit", app.connectionsFrom(scene.player, &found)[0].signal);

    var infos: [8]signals.Info = undefined;
    try testing.expectEqual(@as(usize, 3), app.signalsOf(scene.player, &infos).len);
    try testing.expectEqual(@as(usize, 2), app.signalsOfComponent("Health", &infos).len);
    try testing.expectEqual(@as(usize, 1), app.connectionCount(scene.player));
    try testing.expectEqual(@as(usize, 0), app.connectionCount(scene.hud));
}

test "a component added later does not make one connection two signals" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    try app.signal(scene.player, Health, .hit).connect(.method(scene.hud, "_on_hit"), .{ .flags = .{ .persist = true } });
    var found: [4]signals.Connection = undefined;
    try testing.expectEqualStrings("hit", app.connectionsFrom(scene.player, &found)[0].signal);

    // A shield that says `hit` too: the connection is still Health's.
    try app.world.add(scene.player, Armour{});
    try testing.expectEqualStrings("Health.hit", app.connectionsFrom(scene.player, &found)[0].signal);
    try app.emit(scene.player, Armour, .hit, .{ .damage = 3 });
    try app.emit(scene.player, Health, .hit, .{ .damage = 4, .by = scene.hud });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 1), Heard.len);
    try testing.expectEqual(@as(f32, 4), Heard.calls[0].damage);
    try testing.expectEqual(@as(usize, 0), app.signals.failures);

    // And a scene says which, and is read back as the same one.
    const bytes = try scene_mod.write(app, testing.allocator, .{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"signal\": \"Health.hit\"") != null);
    const copy = try App.create(testing.allocator, .{ .headless = true });
    defer copy.destroy();
    try copy.registerComponents(.{ Health, Armour });
    const loaded = try scene_mod.read(copy, bytes, .{});
    try testing.expectEqual(@as(usize, 0), loaded.connections_skipped);
    const player = copy.findUuid(app.uuidOf(scene.player).?).?;
    const listed = copy.connectionsFrom(player, &found);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expect(listed[0].known);
    try testing.expectEqualStrings("Health.hit", listed[0].signal);

    // With neither component, it still says whose it was.
    try app.world.remove(scene.player, Armour);
    try app.world.remove(scene.player, Health);
    try testing.expectEqualStrings("Health.hit", app.connectionsFrom(scene.player, &found)[0].signal);
}

test "a bare name two components declare is kept as written, and never heard" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();
    const text =
        \\{
        \\  "fluxion_scene": 2,
        \\  "entities": [
        \\    { "uuid": "00000000-0000-4000-8000-000000000001", "Health": {}, "Armour": {} },
        \\    { "uuid": "00000000-0000-4000-8000-000000000002" }
        \\  ],
        \\  "connections": [
        \\    { "from": "00000000-0000-4000-8000-000000000001", "signal": "hit", "to": "00000000-0000-4000-8000-000000000002", "method": "_on_hit" }
        \\  ]
        \\}
    ;
    const loaded = try scene_mod.read(app, text, .{});
    try testing.expectEqual(@as(usize, 1), loaded.connections_unknown);
    const knight = app.findUuid(try .parse("00000000-0000-4000-8000-000000000001")).?;
    var found: [4]signals.Connection = undefined;
    const listed = app.connectionsFrom(knight, &found);
    try testing.expect(!listed[0].known);
    try testing.expectEqualStrings("hit", listed[0].signal);

    try app.emit(knight, Health, .hit, .{ .damage = 1, .by = knight });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 0), Heard.len);

    const saved = try scene_mod.write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"signal\": \"hit\"") != null);

    // Taken away by the name the listing gave it.
    app.disconnectNamed(knight, "hit", .method(listed[0].callable.named.target, "_on_hit"));
    try testing.expectEqual(@as(usize, 0), app.connectionCount(knight));
}

test "a connection made before its component was there is made anew when connected again" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    try app.connectNamed(scene.player, "Armour.hit", .method(scene.hud, "_on_armour_hit"), .{});
    var found: [4]signals.Connection = undefined;
    try testing.expect(!app.connectionsFrom(scene.player, &found)[0].known);

    const Struck = struct {
        var times: usize = 0;
        fn struck(_: *App, _: Entity, _: f32) !void {
            times += 1;
        }
    };
    Struck.times = 0;
    try app.addMethod("_on_armour_hit", Struck.struck);
    try app.world.add(scene.player, Armour{});
    // Not heard, nor the signal's: it was not known when it was made.
    try app.emit(scene.player, Armour, .hit, .{ .damage = 1 });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 0), Struck.times);
    try testing.expect(!app.signal(scene.player, Armour, .hit).hasConnections());

    // Connected again, it is the one connection, known and heard.
    try app.signal(scene.player, Armour, .hit).connect(.method(scene.hud, "_on_armour_hit"), .{});
    const listed = app.connectionsFrom(scene.player, &found);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expect(listed[0].known);
    try app.emit(scene.player, Armour, .hit, .{ .damage = 1 });
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 1), Struck.times);
}

test "an entity's methods are listed with what each takes, its components' first" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    var found: [32]signals.MethodInfo = undefined;
    const listed = app.methodsOf(scene.player, &found);
    var heal: ?signals.MethodInfo = null;
    for (listed) |m| {
        if (std.mem.eql(u8, m.name, "heal")) heal = m;
    }
    try testing.expectEqualStrings("Health", heal.?.component);
    try testing.expectEqual(@as(usize, 1), heal.?.params.len);
    try testing.expectEqual(reflect.typeOf(f32), heal.?.params[0].type);

    // The game's own come last, by name, and every entity has them.
    const own = listed[listed.len - 2 ..];
    try testing.expectEqualStrings("_fails", own[0].name);
    try testing.expectEqualStrings("_on_hit", own[1].name);
    try testing.expectEqualStrings("", own[1].component);
    try testing.expectEqual(@as(usize, 2), own[1].params.len);
    try testing.expectEqual(reflect.typeOf(Entity), own[1].params[1].type);

    // The hud has them all but Health's one.
    const on_player = listed.len;
    try testing.expectEqual(on_player - 1, app.methodsOf(scene.hud, &found).len);
    // And no entity, the game's own alone.
    try testing.expectEqual(@as(usize, 2), app.methodsOf(.none, &found).len);
}

test "a connection to a signal nothing declares is kept, listed and never heard" {
    const scene = try made();
    const app = scene.app;
    defer app.destroy();

    try app.connectNamed(scene.player, "Inventory.dropped", .method(scene.hud, "_on_dropped"), .{ .flags = .{ .persist = true } });
    try app.signal(scene.player, Health, .died).connect(.method(scene.player, "heal"), .{});
    var found: [4]signals.Connection = undefined;
    const listed = app.connectionsFrom(scene.player, &found);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expect(!listed[0].known);
    try testing.expect(listed[1].known);
    // The hud's, and not the player's own.
    try testing.expectEqual(@as(usize, 1), app.connectionsTo(scene.hud, &found).len);
    app.disconnectNamed(scene.player, "Inventory.dropped", .method(scene.hud, "_on_dropped"));
    try testing.expectEqual(@as(usize, 1), app.connectionsFrom(scene.player, &found).len);

    // A Zig function is never a scene's.
    try testing.expectError(error.NotPersistable, app.signal(scene.player, Health, .died).connectFn(Heard.onHitFn, .{ .flags = .{ .persist = true } }));
}

const Chat = extern struct {
    unread: u8 = 0,

    pub const signals = .{ .said = struct { text: []const u8 } };
};

test "an emit's arguments are kept as they were, text too, until they are heard" {
    const first = try made();
    const app = first.app;
    defer app.destroy();
    try app.registerComponents(.{Chat});
    const room = try app.world.spawnWith(.{ Transform2D{}, Chat{} });

    const Said = struct {
        var got: [16]u8 = undefined;
        var len: usize = 0;

        fn said(_: *App, _: Entity, text: []const u8) !void {
            @memcpy(got[0..text.len], text);
            len = text.len;
        }
    };
    try app.addMethod("_said", Said.said);
    try app.signal(room, Chat, .said).connect(.method(first.hud, "_said"), .{ .flags = .{ .deferred = true } });

    var buffer = "hello".*;
    try app.emit(room, Chat, .said, .{ .text = &buffer });
    // The emitter's buffer changes before anything hears it.
    buffer = "HELLO".*;
    try app.signals.flushDeferred(app);
    try testing.expectEqualStrings("hello", Said.got[0..Said.len]);
}

test "a connection goes through a scene and back, flags, unbinds and binds and all" {
    for ([_]json.Format{ .json, .cbor }) |format| {
        const first = try made();
        const app = first.app;
        defer app.destroy();
        const binds = [_]signals.Bind{
            .{ .int = 2 },
            .{ .string = "easy" },
            .{ .float = 0.5 },
            .{ .bool = true },
            .{ .vec2 = .init(1, 2) },
            .{ .color = .{ .r = 1, .g = 0.5, .b = 0.25, .a = 1 } },
            .{ .entity = first.hud },
        };
        try app.signal(first.player, Health, .hit).connect(.method(first.hud, "_on_hit"), .{
            .flags = .{ .persist = true, .deferred = true, .one_shot = true },
            .unbinds = 1,
            .binds = &binds,
        });
        // Made in play, not to persist: not the scene's.
        try app.signal(first.player, Health, .died).connect(.method(first.hud, "_on_died"), .{});

        const bytes = try scene_mod.write(app, testing.allocator, .{ .format = format });
        defer testing.allocator.free(bytes);
        // The bare name, which only Health declares on the player.
        if (format == .json) try testing.expect(std.mem.indexOf(u8, bytes, "\"signal\": \"hit\"") != null);

        const copy = try App.create(testing.allocator, .{ .headless = true });
        defer copy.destroy();
        try copy.registerComponents(.{ Health, Armour });
        const loaded = try scene_mod.read(copy, bytes, .{});
        try testing.expectEqual(@as(usize, 0), loaded.connections_skipped);
        // `_on_hit` is not a method here: kept, and counted.
        try testing.expectEqual(@as(usize, 1), loaded.connections_unknown);

        const player = copy.findUuid(app.uuidOf(first.player).?).?;
        const hud = copy.findUuid(app.uuidOf(first.hud).?).?;
        var found: [4]signals.Connection = undefined;
        const listed = copy.connectionsFrom(player, &found);
        try testing.expectEqual(@as(usize, 1), listed.len);
        const kept = listed[0];
        try testing.expectEqualStrings("hit", kept.signal);
        try testing.expect(kept.callable.named.target.eql(hud));
        try testing.expectEqualStrings("_on_hit", kept.callable.named.name);
        try testing.expect(kept.options.flags.persist and kept.options.flags.deferred and kept.options.flags.one_shot);
        try testing.expect(!kept.options.flags.reference_counted);
        try testing.expectEqual(@as(u8, 1), kept.options.unbinds);
        try testing.expectEqual(binds.len, kept.options.binds.len);
        for (binds[0 .. binds.len - 1], kept.options.binds[0 .. binds.len - 1]) |want, got| try testing.expect(want.eql(got));
        try testing.expect(kept.options.binds[binds.len - 1].entity.eql(hud));

        // Written again, it is what was read.
        const again = try scene_mod.write(copy, testing.allocator, .{ .format = format });
        defer testing.allocator.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}

test "a connection this build knows nothing of is kept through a load and a save" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const text =
        \\{
        \\  "fluxion_scene": 2,
        \\  "entities": [
        \\    { "uuid": "00000000-0000-4000-8000-000000000001", "name": "chest" },
        \\    { "uuid": "00000000-0000-4000-8000-000000000002", "name": "hud" }
        \\  ],
        \\  "connections": [
        \\    { "from": "00000000-0000-4000-8000-000000000001", "signal": "Inventory.dropped", "to": "00000000-0000-4000-8000-000000000002", "method": "_on_dropped", "binds": [2, "easy"] },
        \\    { "from": "00000000-0000-4000-8000-000000000001", "signal": "opened", "to": "00000000-0000-4000-8000-000000000009", "method": "_on_opened" }
        \\  ]
        \\}
    ;
    const loaded = try scene_mod.read(app, text, .{});
    try testing.expectEqual(@as(usize, 1), loaded.connections_unknown);
    // Its `to` is in neither the scene nor the world.
    try testing.expectEqual(@as(usize, 1), loaded.connections_skipped);

    const saved = try scene_mod.write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"signal\": \"Inventory.dropped\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"method\": \"_on_dropped\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"easy\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "_on_opened") == null);
}

test "an event sent inside a query is read once, by each reader" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const Damage = struct { amount: f32 };
    const Readers = struct {
        var first: events.Reader(Damage) = .{};
        var second: events.Reader(Damage) = .{};
        var total: f32 = 0;
        var seen: usize = 0;

        fn send(a: *App) anyerror!void {
            var it = try ecs.Query(.{Transform2D}).over(&a.world);
            while (it.next()) |chunk| {
                for (chunk.entities) |_| try a.send(Damage{ .amount = 2 });
            }
        }
        fn readFirst(a: *App) anyerror!void {
            var it = first.read(a.events(Damage));
            while (it.next()) |d| total += d.amount;
        }
        fn readSecond(a: *App) anyerror!void {
            var it = second.read(a.events(Damage));
            while (it.next()) |_| seen += 1;
        }
    };
    Readers.first = .{};
    Readers.second = .{};
    Readers.total = 0;
    Readers.seen = 0;
    _ = try app.world.spawnWith(.{Transform2D{}});
    _ = try app.world.spawnWith(.{Transform2D{}});
    // One reader before the sender, one after.
    try app.addSystem(.update, "first", Readers.readFirst);
    try app.addSystem(.update, "send", Readers.send);
    try app.addSystem(.late, "second", Readers.readSecond);

    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), Readers.total);
    try testing.expectEqual(@as(usize, 2), Readers.seen);
    _ = try app.step();
    // The reader before the sender has the first frame's two now, and the
    // one after it the second frame's, each once.
    try testing.expectEqual(@as(f32, 4), Readers.total);
    try testing.expectEqual(@as(usize, 4), Readers.seen);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 8), Readers.total);
    try testing.expectEqual(@as(usize, 6), Readers.seen);
    // Two frames' worth are kept, and no more: the first frame's are gone.
    try testing.expectEqual(@as(usize, 4), app.events(Damage).len());
}
