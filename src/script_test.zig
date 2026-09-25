// SPDX-License-Identifier: BSD-3-Clause

//! Flux scripts through a whole app, frame by frame: when each script is
//! called, what it reaches, what happens when one fails, a script read
//! again while the game runs, and a script in a scene.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const ecs = @import("fluxion_ecs");
const script = @import("script.zig");
const scene = @import("scene.zig");
const signals = @import("signals.zig");

const flux = script.flux;
const Entity = ecs.Entity;
const Transform2D = @import("components.zig").Transform2D;
const Script = script.Script;
const ScriptHandle = script.ScriptHandle;

const Counter = extern struct {
    value: i64 = 0,

    pub const reflect_name = "Counter";
};

const Marker = extern struct {
    on: bool = true,

    pub const reflect_name = "Marker";
};

const Health = extern struct {
    hp: f32 = 10,
    /// Who it is set on: a component's field that holds an entity.
    target: Entity = .none,

    pub const reflect_name = "Health";
    pub const signals = .{ .hit = struct { damage: f32, by: Entity } };
};

/// A headless app running scripts: a quarter of a second a frame, and one
/// step in each.
fn scripted(options: script.Options) !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    errdefer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.registerComponents(.{ Counter, Marker, Health });
    try app.useScripts(options);
    return app;
}

/// The same, with a project at `root` to read scripts from.
fn scriptedAt(root: []const u8) !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .fixed_delta = 0.25 });
    errdefer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.registerComponents(.{ Counter, Marker, Health });
    try app.useScripts(.{});
    return app;
}

/// A variable of a script's file.
fn global(app: *App, handle: ScriptHandle, name: []const u8) flux.Value {
    const scripts = app.scripts.?;
    return scripts.vm.get(scripts.moduleOf(handle).?, name).?;
}

fn globalText(app: *App, handle: ScriptHandle, name: []const u8) []const u8 {
    return global(app, handle, name).as(flux.object.String).bytes();
}

const door_script =
    \\var readied = 0;
    \\var updates = 0;
    \\var steps = 0;
    \\var exits = 0;
    \\var gone = 0;
    \\var named = "";
    \\
    \\struct Door {
    \\    var frames: int = 0;
    \\
    \\    fn ready(self) {
    \\        readied += 1;
    \\        named = self.entity.name();
    \\    }
    \\    fn fixed(self, dt: float) {
    \\        steps += 1;
    \\        self.entity.get("Counter").value += 1;
    \\    }
    \\    fn update(self, dt: float) {
    \\        updates += 1;
    \\        self.frames += 1;
    \\    }
    \\    fn exit(self) {
    \\        exits += 1;
    \\        if (!self.entity.alive()) gone += 1;
    \\    }
    \\    fn framesSoFar(self) int {
    \\        return self.frames;
    \\    }
    \\}
;

/// What the game's own systems saw of the script, step by step and frame by
/// frame.
const Seen = struct {
    var door: Entity = .none;
    var file: ScriptHandle = .none;
    var in_fixed: [8]i64 = undefined;
    var fixed_count: usize = 0;
    var in_update: [8]i64 = undefined;
    var update_count: usize = 0;

    fn reset(entity: Entity, handle: ScriptHandle) void {
        door = entity;
        file = handle;
        fixed_count = 0;
        update_count = 0;
    }

    fn fixed(app: *App) anyerror!void {
        in_fixed[fixed_count] = app.world.get(door, Counter).?.value;
        fixed_count += 1;
    }

    fn update(app: *App) anyerror!void {
        in_update[update_count] = global(app, file, "updates").asInt();
        update_count += 1;
    }
};

test "a script is readied once, then stepped and updated before the game's own systems" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("door.flux", door_script);
    const door = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    try app.setName(door, "front door");
    Seen.reset(door, file);
    try app.addSystem(.fixed, "look after fixed", Seen.fixed);
    try app.addSystem(.update, "look after update", Seen.update);

    for (0..3) |_| _ = try app.step();

    try testing.expectEqual(@as(i64, 1), global(app, file, "readied").asInt());
    try testing.expectEqualStrings("front door", globalText(app, file, "named"));
    // Each step's system saw that step's `fixed`, and each frame's system
    // that frame's `update`.
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, Seen.in_fixed[0..Seen.fixed_count]);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, Seen.in_update[0..Seen.update_count]);
    // The instance keeps its own fields from frame to frame.
    const instance = app.scripts.?.instanceOf(door).?;
    try testing.expectEqual(@as(i64, 3), (try app.scripts.?.vm.callMethod(instance, "framesSoFar", &.{})).asInt());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "a paused game's scripts wait, and their tasks with them, but a pause menu's run" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("pause.flux",
        \\var games = 0;
        \\var menus = 0;
        \\var rang = 0;
        \\fn bell(by: int) { await wait(0.5); rang += by; }
        \\struct Game {
        \\    fn ready(self) { bell(1); }
        \\    fn update(self, dt: float) { games += 1; }
        \\}
        \\struct Menu {
        \\    fn ready(self) { bell(10); }
        \\    fn update(self, dt: float) { menus += 1; }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.named(file, "Game")});
    const menu = try app.world.spawnWith(.{ Script.named(file, "Menu"), @import("inherited.zig").Processing{ .mode = .when_paused } });
    _ = menu;

    app.setPaused(true);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(i64, 0), global(app, file, "games").asInt());
    try testing.expectEqual(@as(i64, 3), global(app, file, "menus").asInt());
    // The menu's bell rang; the game's is still waiting where it was.
    try testing.expectEqual(@as(i64, 10), global(app, file, "rang").asInt());

    app.setPaused(false);
    _ = try app.step();
    try testing.expectEqual(@as(i64, 10), global(app, file, "rang").asInt());
    _ = try app.step();
    try testing.expectEqual(@as(i64, 11), global(app, file, "rang").asInt());
    try testing.expectEqual(@as(i64, 3), global(app, file, "menus").asInt());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "the tasks of an entity that dies stop where they wait" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("gone.flux",
        \\var rang = 0;
        \\struct Bell {
        \\    fn ready(self) { self.ring(); }
        \\    fn ring(self) {
        \\        await wait(0.5);
        \\        rang += 1;
        \\        self.entity.get("Counter").value += 1;
        \\    }
        \\}
    );
    const kept = try app.world.spawnWith(.{ Counter{}, Script.named(file, "Bell") });
    const doomed = try app.world.spawnWith(.{ Counter{}, Script.named(file, "Bell") });
    _ = try app.step();
    app.world.despawn(doomed);
    for (0..3) |_| _ = try app.step();
    // Only the one still here rang: the other's wait ended with it.
    try testing.expectEqual(@as(i64, 1), global(app, file, "rang").asInt());
    try testing.expectEqual(@as(i64, 1), app.world.get(kept, Counter).?.value);
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "exit comes when the entity dies, loses its script or turns it off, and when the world is cleared" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("door.flux", door_script);
    const doomed = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    const stripped = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    const switched = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    _ = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 4), global(app, file, "readied").asInt());
    try testing.expectEqual(@as(i64, 0), global(app, file, "exits").asInt());

    // Despawned in a system: `exit` at the end of that frame, with the
    // entity gone.
    const Despawner = struct {
        var target: Entity = .none;
        fn despawn(a: *App) anyerror!void {
            if (a.world.isAlive(target)) a.world.despawn(target);
        }
    };
    Despawner.target = doomed;
    try app.addSystem(.update, "despawn", Despawner.despawn);
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, file, "exits").asInt());
    try testing.expectEqual(@as(i64, 1), global(app, file, "gone").asInt());

    // Its `Script` taken off, or turned off: the entity is still there.
    try app.world.remove(stripped, Script);
    app.world.get(switched, Script).?.enabled = false;
    _ = try app.step();
    try testing.expectEqual(@as(i64, 3), global(app, file, "exits").asInt());
    try testing.expectEqual(@as(i64, 1), global(app, file, "gone").asInt());
    try testing.expectEqual(@as(usize, 1), app.scripts.?.instances.count());

    // Turned on again, it is a new instance, readied again.
    app.world.get(switched, Script).?.enabled = true;
    _ = try app.step();
    try testing.expectEqual(@as(i64, 5), global(app, file, "readied").asInt());

    app.clearWorld();
    try testing.expectEqual(@as(i64, 5), global(app, file, "exits").asInt());
    try testing.expectEqual(@as(i64, 3), global(app, file, "gone").asInt());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.instances.count());
}

test "a script that clears the world from inside a call lets go of every instance once" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("ender.flux",
        \\var exits = 0;
        \\struct Ender {
        \\    fn update(self, dt: float) { app.clearWorld(); }
        \\    fn exit(self) {
        \\        exits += 1;
        \\        app.clearWorld();
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();
    try testing.expectEqual(@as(i64, 2), global(app, file, "exits").asInt());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.instances.count());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    _ = try app.step();
}

test "a script that panics or never ends is stopped and counted, and the others go on" {
    const app = try scripted(.{ .budget = 10_000 });
    defer app.destroy();
    const file = try app.addScript("trouble.flux",
        \\var fine = 0;
        \\struct Spinner {
        \\    fn update(self, dt: float) {
        \\        var n = 0;
        \\        while (true) { n += 1; }
        \\    }
        \\}
        \\struct Thrower {
        \\    fn update(self, dt: float) { assert(false, "on purpose"); }
        \\}
        \\struct Fine {
        \\    fn update(self, dt: float) { fine += 1; }
        \\}
        \\// Inside the budget each call, and past it in two calls together.
        \\struct Busy {
        \\    fn update(self, dt: float) {
        \\        var n = 0;
        \\        while (n < 6000) { n += 1; }
        \\    }
        \\}
    );
    // First, one after the other: each call starts with the whole budget.
    _ = try app.world.spawnWith(.{Script.named(file, "Busy")});
    _ = try app.world.spawnWith(.{Script.named(file, "Busy")});
    _ = try app.world.spawnWith(.{Script.named(file, "Spinner")});
    _ = try app.world.spawnWith(.{Script.named(file, "Thrower")});
    _ = try app.world.spawnWith(.{Script.named(file, "Fine")});
    for (0..3) |_| _ = try app.step();

    try testing.expectEqual(@as(i64, 3), global(app, file, "fine").asInt());
    try testing.expectEqual(@as(usize, 6), app.scripts.?.failures);
    try testing.expect(app.scripts.?.vm.panic == null);
    try testing.expectEqual(@as(usize, 5), app.scripts.?.instances.count());
}

test "a struct that is not there, or a method with the wrong parameters, is said and left alone" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("gate.flux",
        \\var updates = 0;
        \\struct Gate {
        \\    fn update(self) { updates += 1; }
        \\}
    );
    const gate = try app.world.spawnWith(.{Script.named(file, "Door")});
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.instances.count());

    // The struct named after the file: made, and its `update`, which takes
    // no `dt`, is not called.
    app.world.get(gate, Script).?.* = .of(file);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), app.scripts.?.instances.count());
    try testing.expectEqual(@as(i64, 0), global(app, file, "updates").asInt());
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "a script that does not compile gets a handle, and runs once its text does" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("late.flux", "struct Late { fn update(self, dt: float) {");
    try testing.expect(app.scripts.?.moduleOf(file) == null);
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.instances.count());

    try app.setScriptText(file,
        \\var updates = 0;
        \\struct Late { fn update(self, dt: float) { updates += 1; } }
    );
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, file, "updates").asInt());
}

test "a script reaches its entity's components, and a handle it keeps follows the component as rows move" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("keeper.flux",
        \\var had = false;
        \\var id = "";
        \\struct Keeper {
        \\    var kept: any = null;
        \\
        \\    fn ready(self) {
        \\        had = self.entity.has("Counter") and !self.entity.has("Marker");
        \\        id = self.entity.uuid();
        \\        self.kept = self.entity.get("Counter");
        \\        // Moves the entity to another table, and the one after it into
        \\        // its row.
        \\        self.entity.add("Marker").on = false;
        \\    }
        \\
        \\    fn update(self, dt: float) {
        \\        self.kept.value += 10;
        \\    }
        \\}
    );
    const keeper = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    var off: Script = .of(file);
    off.enabled = false;
    const bystander = try app.world.spawnWith(.{ Counter{ .value = -1 }, off });
    const uuid = try app.ensureUuid(keeper);

    _ = try app.step();
    try testing.expect(global(app, file, "had").asBool());
    try testing.expectEqualStrings(&uuid.toString(), globalText(app, file, "id"));
    try testing.expectEqual(@as(i64, 10), app.world.get(keeper, Counter).?.value);
    try testing.expectEqual(@as(i64, -1), app.world.get(bystander, Counter).?.value);
    try testing.expect(!app.world.get(keeper, Marker).?.on);

    _ = try app.step();
    try testing.expectEqual(@as(i64, 20), app.world.get(keeper, Counter).?.value);

    // Taken off: the handle is gone, and using it stops the script.
    try app.world.remove(keeper, Counter);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), app.scripts.?.failures);
    try testing.expectEqual(@as(i64, -1), app.world.get(bystander, Counter).?.value);
}

test "what a script prints goes where the options say, and a task wakes on the game's clock" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const app = try scripted(.{ .out = &out.writer });
    defer app.destroy();
    const file = try app.addScript("greeter.flux",
        \\struct Greeter {
        \\    fn ready(self) {
        \\        print("hello", 3);
        \\        await wait(0.5);
        \\        print("half a second on");
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();
    try testing.expectEqualStrings("hello 3\n", out.written());
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqualStrings("hello 3\nhalf a second on\n", out.written());
}

const mover_before =
    \\struct Mover {
    \\    var hits: int = 0;
    \\    fn update(self, dt: float) {
    \\        self.hits += 1;
    \\        self.entity.get("Counter").value = self.hits;
    \\    }
    \\}
;

const mover_after =
    \\struct Mover {
    \\    var hits: int = 0;
    \\    fn update(self, dt: float) {
    \\        self.hits += 1;
    \\        self.entity.get("Counter").value = self.hits * 100;
    \\    }
    \\}
;

test "a script read again runs its new code in the instances it has, which keep their fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = mover_before });

    const app = try scriptedAt(root);
    defer app.destroy();
    const file = try app.loadScript("res://mover.flux");
    try testing.expect((try app.loadScript("res://mover.flux")).eql(file));
    const mover = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(i64, 2), app.world.get(mover, Counter).?.value);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = mover_after });
    try testing.expect(try app.reloadScript(file));
    _ = try app.step();
    // The third update, in the new code: `hits` was kept.
    try testing.expectEqual(@as(i64, 300), app.world.get(mover, Counter).?.value);

    // Text that does not compile leaves the code that did running.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = "struct Mover {" });
    try testing.expect(try app.reloadScript(file));
    _ = try app.step();
    try testing.expectEqual(@as(i64, 400), app.world.get(mover, Counter).?.value);

    // Moved, it is found where it went, and read from there.
    try app.moveFile("res://mover.flux", "res://moved.flux");
    try testing.expect(app.findScript("res://moved.flux").?.eql(file));
    try testing.expect(app.findScript("res://mover.flux") == null);
    try testing.expect(try app.reloadScript(file));
    try testing.expect(!try app.reloadScript(.none));
}

test "a script imports the file beside it, and calls another entity's script" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "scripts");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "scripts/numbers.flux", .data =
        \\fn twice(x: int) int { return x * 2; }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "scripts/bank.flux", .data =
        \\struct Bank {
        \\    var held: int = 0;
        \\    fn put(self, amount: int) int {
        \\        self.held += amount;
        \\        return self.held;
        \\    }
        \\}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "scripts/saver.flux", .data =
        \\const numbers = @import("numbers.flux");
        \\const same = @import("res://scripts/numbers.flux");
        \\struct Saver {
        \\    fn ready(self) {
        \\        const bank = app.find("Bank").script();
        \\        self.entity.get("Counter").value = bank.put(numbers.twice(3)) + same.twice(1);
        \\        print(app.find("Nobody") == null, self.entity.script() != null);
        \\    }
        \\}
    });

    const app = try scriptedAt(root);
    defer app.destroy();
    const bank = try app.world.spawnWith(.{Script.of(try app.loadScript("res://scripts/bank.flux"))});
    try app.setName(bank, "Bank");
    const saver = try app.world.spawnWith(.{ Counter{}, Script.of(try app.loadScript("res://scripts/saver.flux")) });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    // Six put in, and two beside it.
    try testing.expectEqual(@as(i64, 8), app.world.get(saver, Counter).?.value);
    const held = app.scripts.?.vm.getField(app.scripts.?.instanceOf(bank).?, "held").?;
    try testing.expectEqual(@as(i64, 6), held.asInt());
}

test "a script saved while the game runs is read again when the watch next looks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = mover_before });

    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .fixed_delta = 0.25 });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.registerComponents(.{Counter});
    // Every half second: every other frame.
    try app.useScripts(.{ .watch = 0.5 });
    const file = try app.loadScript("res://mover.flux");
    const mover = try app.world.spawnWith(.{ Counter{}, Script.of(file) });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), app.world.get(mover, Counter).?.value);

    // The second frame's look finds it saved, before that frame's update.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = mover_after });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 200), app.world.get(mover, Counter).?.value);

    // Saved again, it waits for the next look, two frames on.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mover.flux", .data = mover_before });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 300), app.world.get(mover, Counter).?.value);
    _ = try app.step();
    try testing.expectEqual(@as(i64, 4), app.world.get(mover, Counter).?.value);
}

test "a scene keeps an entity's script by its file and struct, and reading it loads the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "door.flux", .data = door_script });

    const app = try scriptedAt(root);
    defer app.destroy();
    const file = try app.loadScript("res://door.flux");
    const door = try app.world.spawnWith(.{ Counter{}, Script.named(file, "Door") });
    try app.setName(door, "front door");
    const written = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"res://door.flux\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"Door\"") != null);

    const copy = try scriptedAt(root);
    defer copy.destroy();
    _ = try scene.read(copy, written, .{});
    // Written again before a frame has changed it, it is the same scene.
    const again = try scene.write(copy, testing.allocator, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(written, again);

    _ = try copy.step();
    const loaded = copy.findScript("res://door.flux").?;
    try testing.expectEqual(@as(i64, 1), global(copy, loaded, "readied").asInt());
    try testing.expectEqualStrings("front door", globalText(copy, loaded, "named"));

    // Saved to the disc, the script is given a UUID beside it, and the scene
    // names it by that too.
    try copy.saveScene("res://level.json", .{});
    try tmp.dir.access(testing.io, "door.flux.uid", .{});
    const saved = try tmp.dir.readFileAlloc(testing.io, "level.json", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"uid\": \"uid://") != null);
}

test "an editor's analysis compiles a script as the game does, with app and self.entity" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const source = "struct Door { fn ready(self) { print(self.entity.name(), app); } }";

    const bare = try flux.service.newVm(testing.allocator, .{});
    defer bare.destroy();
    try testing.expectError(error.CompileFailed, bare.compile("door.flux", source));

    // No `useScripts` needed: an editor checks scripts it does not run.
    const set_up = try flux.service.newVm(testing.allocator, app.scriptSetup());
    defer set_up.destroy();
    _ = try set_up.compile("door.flux", source);
    try testing.expect(app.scripts == null);
}

test "an app that does not use scripts has none, and says so when asked for one" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try testing.expect(app.scripts == null);
    try testing.expectError(error.ScriptsNotUsed, app.loadScript("res://door.flux"));
    try testing.expect(!try app.reloadScript(.none));
    try testing.expect(app.findScript("res://door.flux") == null);
    _ = try app.step();
}

// ---------------------------------------------------------------------------
// Signals, both ways
// ---------------------------------------------------------------------------

const door_signals =
    \\struct Door {
    \\    /// When it opens.
    \\    signal opened(by: string, times: int);
    \\    var times: int = 0;
    \\
    \\    fn update(self, dt: float) {
    \\        self.times += 1;
    \\        self.opened.emit("hand", self.times);
    \\    }
    \\}
;

/// What the engine's methods heard of a script's signal.
const Heard = struct {
    var calls: usize = 0;
    var times: i64 = 0;
    var by: [16]u8 = undefined;
    var by_len: usize = 0;
    var at: Entity = .none;

    fn reset() void {
        calls = 0;
        times = 0;
        by_len = 0;
        at = .none;
    }

    fn onOpened(_: *App, self: Entity, who: []const u8, count: i64) !void {
        calls += 1;
        times = count;
        at = self;
        by_len = @min(who.len, by.len);
        @memcpy(by[0..by_len], who[0..by_len]);
    }
};

test "a script's signal is its entity's: listed, connected by name, and heard by the engine" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("door.flux", door_signals);
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_opened", Heard.onOpened);
    Heard.reset();

    // Listed before the first frame, from the struct: no instance is made yet.
    var infos: [8]signals.Info = undefined;
    const listed = app.signalsOf(door, &infos);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("Script", listed[0].component);
    try testing.expectEqualStrings("opened", listed[0].name);
    try testing.expectEqualStrings("by: string, times: int", listed[0].signature);
    try testing.expectEqual(@as(?u8, 2), listed[0].arity);
    try testing.expectEqual(@as(usize, 0), listed[0].args.fields().len);
    try testing.expect(app.hasSignal(door, "opened"));
    try testing.expect(app.hasSignal(door, "Script.opened"));
    try testing.expect(!app.hasSignal(door, "closed"));

    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{});
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Heard.calls);
    try testing.expectEqual(@as(i64, 2), Heard.times);
    try testing.expectEqualStrings("hand", Heard.by[0..Heard.by_len]);
    try testing.expect(Heard.at.eql(listener));

    // Kept as a component's is, and written bare.
    var connections: [4]signals.Connection = undefined;
    const kept = app.connectionsFrom(door, &connections);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(kept[0].known);
    try testing.expectEqualStrings("opened", kept[0].signal);
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "an engine signal calls a method its target's script declares, an entity arriving as a handle" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("hud.flux",
        \\var hits = 0;
        \\var total = 0.0;
        \\var who = "";
        \\struct Hud {
        \\    fn on_hit(self, damage: float, by: any) {
        \\        hits += 1;
        \\        total += damage;
        \\        who = by.name();
        \\    }
        \\}
    );
    const player = try app.world.spawnWith(.{Health{}});
    try app.setName(player, "player");
    const hud = try app.world.spawnWith(.{Script.of(file)});

    try testing.expect(app.hasMethod(hud, "on_hit"));
    try testing.expect(app.hasMethod(hud, "Script.on_hit"));
    try testing.expect(!app.hasMethod(hud, "on_miss"));
    var infos: [8]signals.MethodInfo = undefined;
    const methods = app.methodsOf(hud, &infos);
    try testing.expectEqual(@as(usize, 1), methods.len);
    try testing.expectEqualStrings("Script", methods[0].component);
    try testing.expectEqualStrings("on_hit", methods[0].name);
    // `any` is no type to write: the parameter is its name alone.
    try testing.expectEqualStrings("damage: float, by", methods[0].signature);
    try testing.expectEqual(@as(?u8, 2), methods[0].arity);

    try app.signal(player, Health, .hit).connect(.method(hud, "on_hit"), .{});
    // Before the first frame: the instance is made, and readied, to hear it.
    try app.emit(player, Health, .hit, .{ .damage = 2.5, .by = player });
    try app.signals.drain(app);
    try testing.expectEqual(@as(i64, 1), global(app, file, "hits").asInt());
    try testing.expectEqual(@as(usize, 1), app.scripts.?.instances.count());

    try app.emit(player, Health, .hit, .{ .damage = 1.5, .by = player });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 2), global(app, file, "hits").asInt());
    try testing.expectEqual(@as(f64, 4.0), global(app, file, "total").asFloat());
    try testing.expectEqualStrings("player", globalText(app, file, "who"));
    try testing.expectEqual(@as(usize, 0), app.signals.failures);
}

test "a script reads what a tile says as the number or the truth it is" {
    const app = try scripted(.{});
    defer app.destroy();
    const set = try app.addTileSet("data.tileset",
        \\{ "fluxion_tileset": 1, "tile_size": [16, 16],
        \\  "data_layers": [{ "name": "damage", "type": "int" }, { "name": "water", "type": "bool" }, { "name": "slow", "type": "float" }],
        \\  "sources": [{ "id": 0, "tiles": [{ "at": [0, 0], "data": { "damage": 3, "water": true, "slow": 0.5 } }] }] }
    );
    const TileMap = @import("tilemap.zig").TileMap;
    const map = try app.world.spawnWith(.{ Transform2D{}, TileMap{ .tile_set = set } });
    try app.setName(map, "ground");
    _ = try app.setTile(map, 1, 0, .at(0, 0, 0));
    const file = try app.addScript("reader.flux",
        \\var damage: any = null;
        \\var water: any = null;
        \\var slow: any = null;
        \\var cell_x: any = null;
        \\var cell_y: any = null;
        \\var nothing: any = 1;
        \\struct Reader {
        \\    fn ready(self) {
        \\        var ground = app.find("ground");
        \\        damage = app.tileDataAt(ground, vec2(20, 4), "damage");
        \\        water = app.tileData(ground, 1, 0, "water");
        \\        slow = app.tileData(ground, 1, 0, "slow");
        \\        var cell = app.cellAt(ground, vec2(20, 4));
        \\        cell_x = cell.x;
        \\        cell_y = cell.y;
        \\        nothing = app.tileData(ground, 5, 5, "damage");
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();

    try testing.expectEqual(@as(i64, 3), global(app, file, "damage").asInt());
    try testing.expect(global(app, file, "water").asBool());
    try testing.expectEqual(@as(f64, 0.5), global(app, file, "slow").asFloat());
    try testing.expectEqual(@as(i64, 1), global(app, file, "cell_x").asInt());
    try testing.expectEqual(@as(i64, 0), global(app, file, "cell_y").asInt());
    try testing.expect(global(app, file, "nothing").tag == .null);
}

test "a script draws the game's chance, the same again from the same seed" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("dice.flux",
        \\var first = 0;
        \\var again = 0;
        \\var inside = true;
        \\struct Dice {
        \\    fn ready(self) {
        \\        app.seedRandom(42);
        \\        first = app.randomInt(1, 6);
        \\        app.seedRandom(42);
        \\        again = app.randomInt(1, 6);
        \\        var x = app.randomRange(2.0, 3.0);
        \\        inside = x >= 2.0 and x < 3.0 and app.randomIndex(3) < 3;
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();

    const first = global(app, file, "first").asInt();
    try testing.expect(first >= 1 and first <= 6);
    try testing.expectEqual(first, global(app, file, "again").asInt());
    try testing.expect(global(app, file, "inside").asBool());
}

test "an entity is one handle to the scripts, wherever they are handed it" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("finder.flux",
        \\var name = "";
        \\var nobody = false;
        \\var mine = false;
        \\var placed = 0.0;
        \\var parented = false;
        \\var hung = false;
        \\var heard = false;
        \\var kept: any = null;
        \\var me: any = null;
        \\struct Finder {
        \\    fn ready(self) {
        \\        app.find("other").get("Transform2D").x += 1;
        \\        name = app.nameOf(app.find("other"));
        \\        nobody = app.find("nobody") == null;
        \\        mine = app.find("finder") == self.entity;
        \\        // A struct handed back is the script's own, which the next
        \\        // call does not write over.
        \\        var place = app.worldTransform(app.find("other"));
        \\        app.nameOf(self.entity);
        \\        placed = place.x;
        \\        var health = self.entity.get("Health");
        \\        health.target = app.find("other");
        \\        parented = health.target == app.find("other");
        \\        app.setParent(self.entity, app.find("other"), false);
        \\        hung = app.parentOf(self.entity) == app.find("other") and app.childAt(app.find("other"), 0) == self.entity;
        \\        kept = app.find("other");
        \\        me = self;
        \\    }
        \\    fn on_hit(self, damage: float, by: any) {
        \\        heard = by == kept;
        \\    }
        \\}
        \\struct Point {
        \\    var x: int = 0;
        \\}
        \\fn unparent() { app.findPath(app.find("other"), "finder").get("Health").target = null; }
        \\fn parentOf() { return app.findPath(app.find("other"), "finder").get("Health").target; }
        \\fn byInstance() { return app.nameOf(me); }
        \\fn keptAlive() { return kept.alive(); }
        \\fn number() { return app.nameOf(5); }
        \\fn fraction() { return app.nameOf(1.5); }
        \\fn text() { return app.nameOf("other"); }
        \\fn component() { return app.nameOf(app.find("finder").get("Transform2D")); }
        \\fn stray() { return app.nameOf(Point{}); }
    );
    const finder = try app.world.spawnWith(.{ Transform2D.at(0, 0), Health{}, Script.of(file) });
    try app.setName(finder, "finder");
    const other = try app.world.spawnWith(.{ Transform2D.at(5, 0), Health{} });
    try app.setName(other, "other");
    try app.signal(other, Health, .hit).connect(.method(finder, "on_hit"), .{});
    _ = try app.step();

    // Found, reached through, named and compared.
    try testing.expectEqual(@as(f32, 6), app.world.get(other, Transform2D).?.x);
    try testing.expectEqualStrings("other", globalText(app, file, "name"));
    try testing.expect(global(app, file, "nobody").asBool());
    try testing.expect(global(app, file, "mine").asBool());
    try testing.expectEqual(@as(f64, 6), global(app, file, "placed").asFloat());
    // Written into a component's field, and read back as the same handle.
    try testing.expect(global(app, file, "parented").asBool());
    try testing.expect(app.world.get(finder, Health).?.target.eql(other));
    // Hung from another from a script, and found there by a path.
    try testing.expect(global(app, file, "hung").asBool());
    try testing.expect(app.parentOf(finder).eql(other));

    // A signal's entity is the same handle too.
    try app.emit(other, Health, .hit, .{ .damage = 1, .by = other });
    _ = try app.step();
    try testing.expect(global(app, file, "heard").asBool());

    const scripts = app.scripts.?;
    const module = scripts.moduleOf(file).?;
    _ = try scripts.vm.callName(module, "unparent", &.{});
    try testing.expect(app.world.get(finder, Health).?.target.isNone());
    try testing.expect((try scripts.vm.callName(module, "parentOf", &.{})).tag == .null);
    try testing.expectEqualStrings("finder", (try scripts.vm.callName(module, "byInstance", &.{})).as(flux.object.String).bytes());

    // Anything else stops the script, saying what it gave.
    for ([_][2][]const u8{
        .{ "number", "an entity is wanted here, not a number" },
        .{ "fraction", "an entity is wanted here, not a number" },
        .{ "text", "an entity is wanted here, not a string" },
        .{ "component", "an entity is wanted here, not a Transform2D" },
        .{ "stray", "an entity is wanted here, not a Point on no entity" },
    }) |case| {
        try testing.expectError(error.Panic, scripts.vm.callName(module, case[0], &.{}));
        try testing.expectEqualStrings(case[1], scripts.vm.panic.?.message);
        scripts.vm.clearPanic();
    }

    // Each handle is held while its entity lives, so the collector leaves
    // it though no script has it. A dead entity's is let go of at the end
    // of the frame, and the one the script kept answers as a dead entity's.
    var handles = scripts.handles.valueIterator();
    while (handles.next()) |handle| try testing.expect(scripts.vm.held.contains(handle.obj()));
    const other_handle = scripts.handles.get(other).?;
    // Taken back to the root first, or it would go with the one it hangs from.
    try app.setParent(finder, .none, false);
    app.world.despawn(other);
    _ = try app.step();
    try testing.expect(!scripts.handles.contains(other));
    try testing.expect(!scripts.vm.held.contains(other_handle.obj()));
    try testing.expect(scripts.handles.contains(finder));
    try testing.expect(!(try scripts.vm.callName(module, "keptAlive", &.{})).asBool());
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    try testing.expectEqual(@as(usize, 0), app.signals.failures);
}

test "a script's signal calls a method another script declares" {
    const app = try scripted(.{});
    defer app.destroy();
    const door_file = try app.addScript("door.flux", door_signals);
    const bell_file = try app.addScript("bell.flux",
        \\var rung = 0;
        \\var last = "";
        \\struct Bell {
        \\    fn ring(self, by: string, times: int) {
        \\        rung = times;
        \\        last = by;
        \\    }
        \\}
    );
    const door = try app.world.spawnWith(.{Script.of(door_file)});
    const bell = try app.world.spawnWith(.{Script.of(bell_file)});
    try app.connectNamed(door, "Script.opened", .method(bell, "ring"), .{});
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(i64, 3), global(app, bell_file, "rung").asInt());
    try testing.expectEqualStrings("hand", globalText(app, bell_file, "last"));
}

test "a connection made while its script did not compile is heard once it does" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("door.flux", "struct Door { signal opened(by: string, times: int)");
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_opened", Heard.onOpened);
    Heard.reset();

    // Nothing declares it yet: kept as written, and not heard.
    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{});
    var connections: [4]signals.Connection = undefined;
    try testing.expect(!app.connectionsFrom(door, &connections)[0].known);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), Heard.calls);

    try app.setScriptText(file, door_signals);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.calls);
    try testing.expect(app.connectionsFrom(door, &connections)[0].known);
}

test "a scene keeps a connection to a script's signal, and it is heard after reading" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "door.flux", .data = door_signals });

    const app = try scriptedAt(root);
    defer app.destroy();
    const file = try app.loadScript("res://door.flux");
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{ .flags = .{ .persist = true } });
    const written = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"opened\"") != null);

    const copy = try scriptedAt(root);
    defer copy.destroy();
    try copy.addMethod("_on_opened", Heard.onOpened);
    Heard.reset();
    _ = try scene.read(copy, written, .{});
    var connections: [4]signals.Connection = undefined;
    _ = try copy.step();
    try testing.expectEqual(@as(usize, 1), Heard.calls);
    var found: usize = 0;
    var query = try ecs.Query(.{Script}).over(&copy.world);
    while (query.next()) |chunk| {
        for (chunk.entities) |entity| {
            const kept = copy.connectionsFrom(entity, &connections);
            found += kept.len;
            for (kept) |c| try testing.expect(c.known);
        }
    }
    try testing.expectEqual(@as(usize, 1), found);
}

const Touched = struct {
    var by: Entity = .none;
    var calls: usize = 0;

    fn onTouched(_: *App, _: Entity, who: Entity) !void {
        by = who;
        calls += 1;
    }
};

test "a script's instance or self.entity, emitted, reaches the engine as its entity" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("pad.flux",
        \\struct Pad {
        \\    signal touched(by: any);
        \\    signal pressed(by: any);
        \\    fn update(self, dt: float) {
        \\        self.touched.emit(self.entity);
        \\        self.pressed.emit(self);
        \\    }
        \\}
    );
    const pad = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_touched", Touched.onTouched);
    Touched.calls = 0;
    try app.connectNamed(pad, "touched", .method(listener, "_on_touched"), .{});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Touched.calls);
    try testing.expect(Touched.by.eql(pad));

    app.disconnectNamed(pad, "touched", .method(listener, "_on_touched"));
    try app.connectNamed(pad, "pressed", .method(listener, "_on_touched"), .{});
    Touched.by = .none;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Touched.calls);
    try testing.expect(Touched.by.eql(pad));
    try testing.expectEqual(@as(usize, 0), app.signals.failures);
}

test "a signal a component and the script both declare is named by which" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("player.flux",
        \\struct Player {
        \\    signal hit(damage: float);
        \\}
    );
    const player = try app.world.spawnWith(.{ Health{}, Script.of(file) });
    try testing.expectError(error.AmbiguousSignal, app.signalNamed(player, "hit"));
    try testing.expectEqualStrings("Health", (try app.signalNamed(player, "Health.hit")).component);
    try testing.expectEqualStrings("Script", (try app.signalNamed(player, "Script.hit")).component);
    var infos: [8]signals.Info = undefined;
    try testing.expectEqual(@as(usize, 2), app.signalsOf(player, &infos).len);
}

test "an instance let go of is no longer its entity's: what it emits after is not the entity's" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("door.flux",
        \\var kept: any = null;
        \\struct Door {
        \\    signal opened(by: string, times: int);
        \\    fn ready(self) { kept = self; }
        \\}
        \\fn ring() { kept.opened.emit("ghost", 99); }
    );
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_opened", Heard.onOpened);
    Heard.reset();
    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{});
    _ = try app.step();

    // Heard while it is the entity's.
    const scripts = app.scripts.?;
    _ = try scripts.vm.callName(scripts.moduleOf(file).?, "ring", &.{});
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 1), Heard.calls);

    // Its `Script` taken off, the entity lives on with its connection, and
    // the instance a script kept speaks for nobody.
    try app.world.remove(door, Script);
    _ = try app.step();
    _ = try scripts.vm.callName(scripts.moduleOf(file).?, "ring", &.{});
    try app.signals.drain(app);
    try testing.expectEqual(@as(usize, 1), Heard.calls);
}

test "what a script emits that the engine cannot carry stops the script, and is counted" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("talker.flux",
        \\struct Talker {
        \\    signal said(what: any);
        \\    fn update(self, dt: float) { self.said.emit([1, 2]); }
        \\}
    );
    const talker = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_opened", Heard.onOpened);
    try app.connectNamed(talker, "said", .method(listener, "_on_opened"), .{});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), app.scripts.?.failures);
    try testing.expectEqual(@as(usize, 0), app.signals.failures);
}

// ---------------------------------------------------------------------------
// An editor's scripts
// ---------------------------------------------------------------------------

const edited_door =
    \\print("the top level");
    \\var opened_at = stamp("a variable");
    \\fn stamp(what: string) int {
    \\    print(what);
    \\    return 1;
    \\}
    \\struct Door {
    \\    signal opened(by: string, times: int);
    \\    var hinge: int = stamp("a default");
    \\    fn ready(self) { print("ready"); }
    \\    fn update(self, dt: float) { print("update"); }
    \\    fn knock(self) { print("knock"); }
    \\}
;

test "an editor's scripts are compiled, listed and connected to, and none of their code runs" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const app = try scripted(.{ .run = false, .out = &out.writer });
    defer app.destroy();
    const file = try app.addScript("door.flux", edited_door);
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.addMethod("_on_opened", Heard.onOpened);
    for (0..3) |_| _ = try app.step();

    // Not the top level, a variable, a default, `ready` or `update`.
    try testing.expectEqualStrings("", out.written());
    try testing.expect(app.scripts.?.instanceOf(door) == null);
    try testing.expect(app.scripts.?.moduleOf(file) != null);

    var infos: [8]signals.Info = undefined;
    const listed = app.signalsOf(door, &infos);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("opened", listed[0].name);
    try testing.expect(app.hasMethod(door, "knock"));
    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{});
    var connections: [4]signals.Connection = undefined;
    try testing.expect(app.connectionsFrom(door, &connections)[0].known);
    try testing.expectError(error.NotRunning, app.callMethodOn(door, "knock", &.{}));

    // New text is compiled afresh: its signal is there, and still nothing
    // runs.
    try app.setScriptText(file, edited_door ++ "\nstruct Latch { signal closed(); }");
    try testing.expect(app.scripts.?.moduleOf(file) != null);
    app.world.get(door, Script).?.* = Script.named(file, "Latch");
    try testing.expect(app.hasSignal(door, "closed"));
    _ = try app.step();
    try testing.expectEqualStrings("", out.written());
    try testing.expect(app.scripts.?.instanceOf(door) == null);
}

test "a connection an editor made while its script did not compile is known once it does" {
    const app = try scripted(.{ .run = false });
    defer app.destroy();
    const file = try app.addScript("door.flux", "struct Door { signal opened(by: string, times: int)");
    const door = try app.world.spawnWith(.{Script.of(file)});
    const listener = try app.world.spawnWith(.{Counter{}});
    try app.connectNamed(door, "opened", .method(listener, "_on_opened"), .{});
    var connections: [4]signals.Connection = undefined;
    try testing.expect(!app.connectionsFrom(door, &connections)[0].known);

    // No instance is ever made, so the file's own reading has to find it.
    try app.setScriptText(file, door_signals);
    try testing.expect(app.connectionsFrom(door, &connections)[0].known);
    try testing.expect(app.scripts.?.instanceOf(door) == null);
}

test "a script reads the game's files and keeps a save in the player's, and reaches nowhere else" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "levels.txt", .data = "meadow" });

    const app = try scriptedAt(root);
    defer app.destroy();
    app.project.user_root = try std.fs.path.join(testing.allocator, &.{ root, "saves" });
    const file = try app.addScript("saver.flux",
        \\const json = @import("json");
        \\var level = "";
        \\var loaded = 0;
        \\var names = 0;
        \\var first = "";
        \\var refused = "";
        \\var escaped = "";
        \\var missing = "";
        \\var outside = true;
        \\
        \\fn save(slot: any) {
        \\    files.writeText("user://slots/one.json", json.stringify(slot, 2)) catch |e| print("not saved:", e.name);
        \\}
        \\
        \\fn load() any {
        \\    const text = files.readText("user://slots/one.json") catch return null;
        \\    return json.parse(text) catch null;
        \\}
        \\
        \\struct Saver {
        \\    fn ready(self) {
        \\        level = files.readText("res://levels.txt") catch "";
        \\        save({"level": 3});
        \\        loaded = load()["level"];
        \\        files.makeDir("user://slots/old") catch {};
        \\        const listed = files.list("user://slots") catch [];
        \\        names = listed.len;
        \\        first = listed[0];
        \\        refused = files.writeText("res://levels.txt", "broken") catch |e| e.name;
        \\        escaped = files.readText("user://../../outside.txt") catch |e| e.name;
        \\        missing = files.readText("user://none.json") catch |e| e.name;
        \\        outside = files.exists("levels.txt");
        \\        files.remove("user://slots/old") catch {};
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();

    try testing.expectEqual(@as(u32, 0), app.scripts.?.failures);
    try testing.expectEqualStrings("meadow", globalText(app, file, "level"));
    try testing.expectEqual(@as(i64, 3), global(app, file, "loaded").asInt());
    try testing.expectEqual(@as(i64, 2), global(app, file, "names").asInt());
    try testing.expectEqualStrings("old/", globalText(app, file, "first"));
    try testing.expectEqualStrings("NotAllowed", globalText(app, file, "refused"));
    try testing.expectEqualStrings("OutsideProject", globalText(app, file, "escaped"));
    try testing.expectEqualStrings("FileNotFound", globalText(app, file, "missing"));
    try testing.expect(!global(app, file, "outside").asBool());
    try testing.expect(!app.fileExists("user://slots/old"));

    const saved = try app.readText(testing.allocator, "user://slots/one.json");
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"level\": 3") != null);
    const kept = try tmp.dir.readFileAlloc(testing.io, "levels.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("meadow", kept);
}

test "a script asks for the game's actions, and holds one down as a button on the screen does" {
    const app = try scripted(.{});
    defer app.destroy();
    try app.input.actions.add(testing.allocator, .{ .name = "jump", .bindings = &.{.keyOf(.space)} });
    const file = try app.addScript("jumper.flux",
        \\var pressed = false;
        \\var down = false;
        \\var named = "";
        \\var across = 0.0;
        \\struct Jumper {
        \\    fn ready(self) {
        \\        app.pressAction("jump", 1.0) catch {};
        \\    }
        \\    fn update(self, dt: float) {
        \\        if (app.actionJustPressed("jump")) pressed = true;
        \\        down = app.actionDown("jump");
        \\        named = app.describeAction("jump");
        \\        across = app.actionVector("ui_left", "ui_right", "ui_up", "ui_down").x;
        \\        app.releaseAction("jump") catch {};
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    app.input.apply(.{ .key = .{ .window = .none, .key = .right, .scancode = @enumFromInt(0), .action = .press, .mods = .{} } });
    _ = try app.step();

    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expect(global(app, file, "pressed").asBool());
    try testing.expect(global(app, file, "down").asBool());
    try testing.expectEqualStrings("Space", globalText(app, file, "named"));
    try testing.expectEqual(@as(f64, 1), global(app, file, "across").asFloat());
    try testing.expect(!app.actionDown("jump"));
}

test "an editor's analysis offers the project's actions inside the quotes of a call that names one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project.fluxion", .data =
        \\{ "fluxion_project": 2, "application": { "name": "Keys" },
        \\  "input": { "actions": [ { "name": "jump", "bindings": [ { "type": "key", "key": "space" } ] } ] } }
    });
    // An editor's app: its own actions are the built-in ones alone.
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .project_input = false });
    defer app.destroy();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { source: []const u8, offered: bool };
    for ([_]Case{
        .{ .source = "struct Hero { fn update(self, dt: float) { if (app.actionDown(\"ju$\")) {} } }", .offered = true },
        .{ .source = "struct Hero { fn update(self, dt: float) { _ = app.actionAxis(\"ui_left\", \"$\"); } }", .offered = true },
        // A strength is no action's name, nor is what `find` looks for.
        .{ .source = "struct Hero { fn ready(self) { app.pressAction(\"jump\", \"$\"); } }", .offered = false },
        .{ .source = "struct Hero { fn ready(self) { _ = app.find(\"$\"); } }", .offered = false },
    }) |case| {
        const where = std.mem.indexOfScalar(u8, case.source, '$').?;
        const source = try std.mem.concat(arena, u8, &.{ case.source[0..where], case.source[where + 1 ..] });
        const found = try flux.service.complete(testing.allocator, arena, "hero.flux", source, @intCast(where), app.scriptSetup());
        var jump: ?flux.service.Item = null;
        var accept = false;
        for (found.items) |item| {
            if (std.mem.eql(u8, item.label, "jump")) jump = item;
            if (std.mem.eql(u8, item.label, "ui_accept")) accept = true;
        }
        try testing.expectEqual(case.offered, jump != null);
        try testing.expectEqual(case.offered, accept);
        if (jump) |item| try testing.expectEqualStrings("Space", item.detail);
    }
}

test "a script connects to and awaits the engine's signals: a component's, a timer's, and the next frame" {
    const app = try scripted(.{});
    defer app.destroy();
    const file = try app.addScript("watcher.flux",
        \\var fired = 0;
        \\var waited = false;
        \\var frames = 0;
        \\var hurt = 0.0;
        \\var by_whom = true;
        \\fn onTimeout() { fired += 1; }
        \\fn onHit(damage: float, by: any) {
        \\    hurt += damage;
        \\    by_whom = by != null;
        \\}
        \\struct Watcher {
        \\    fn ready(self) {
        \\        app.createTimer(0.25).timeout.connect(onTimeout);
        \\        self.entity.get("Health").hit.connect(onHit);
        \\        self.wait();
        \\        self.count();
        \\    }
        \\    fn wait(self) {
        \\        await app.createTimer(0.5).timeout;
        \\        waited = true;
        \\    }
        \\    fn count(self) {
        \\        await app.nextFrame();
        \\        frames += 1;
        \\        await app.nextFrame();
        \\        frames += 1;
        \\    }
        \\}
    );
    const watcher = try app.world.spawnWith(.{ Health{}, Script.of(file) });

    // A wait begun in a frame is over in the next, however early it began.
    _ = try app.step();
    try testing.expectEqual(@as(i64, 0), global(app, file, "frames").asInt());
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, file, "frames").asInt());
    _ = try app.step();
    try testing.expectEqual(@as(i64, 2), global(app, file, "frames").asInt());

    try app.emit(watcher, Health, .hit, .{ .damage = 5, .by = .none });
    for (0..4) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqual(@as(i64, 1), global(app, file, "fired").asInt());
    try testing.expect(global(app, file, "waited").asBool());
    try testing.expectEqual(@as(f64, 5), global(app, file, "hurt").asFloat());
    try testing.expect(!global(app, file, "by_whom").asBool());
    // The timers went with their timeouts, and their signals with them.
    try testing.expectEqual(@as(usize, 1), app.scripts.?.bridges.items.len);
}

test "a script makes entities and scenes, takes them out, and calls what it defers at the end of the frame" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "crate.json", .data =
        \\{ "fluxion_scene": 3, "entities": [ { "uuid": "00000000-0000-4000-8000-00000000000a", "name": "crate", "Counter": { "value": 7 } } ] }
    });
    const app = try scriptedAt(root);
    defer app.destroy();
    const file = try app.addScript("maker.flux",
        \\var made_name = "";
        \\var crate_value = 0;
        \\var deferred = 0;
        \\var deferred_then = -1;
        \\var gone = true;
        \\fn later() { deferred += 1; }
        \\struct Maker {
        \\    fn ready(self) {
        \\        const child = app.spawn(self.entity) catch return;
        \\        _ = child.add("Marker");
        \\        app.setName(child, "made") catch {};
        \\        made_name = app.nameOf(child);
        \\        const crate = app.instantiate("res://crate.json", self.entity) catch return;
        \\        crate_value = crate.get("Counter").value;
        \\        app.callDeferred(later) catch {};
        \\        deferred_then = deferred;
        \\        child.despawn() catch {};
        \\        gone = !child.alive();
        \\    }
        \\}
    );
    const maker = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqualStrings("made", globalText(app, file, "made_name"));
    try testing.expectEqual(@as(i64, 7), global(app, file, "crate_value").asInt());
    try testing.expectEqual(@as(i64, 0), global(app, file, "deferred_then").asInt());
    try testing.expectEqual(@as(i64, 1), global(app, file, "deferred").asInt());
    try testing.expect(global(app, file, "gone").asBool());
    try testing.expectEqual(@as(i64, 1), app.childCount(maker));
}

test "a file a component holds is its path to a script, and a path given loads it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "door.flux", .data = "struct Door {}" });
    const app = try scriptedAt(root);
    defer app.destroy();
    const file = try app.addScript("swap.flux",
        \\var before: any = 0;
        \\var after: any = 0;
        \\var refused = "";
        \\struct Swap {
        \\    fn ready(self) {
        \\        const script = self.entity.get("Script");
        \\        before = script.source;
        \\        const other = app.spawn(null) catch return;
        \\        other.add("Script").source = "res://door.flux";
        \\        after = other.get("Script").source;
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(file)});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqualStrings("swap.flux", globalText(app, file, "before"));
    try testing.expectEqualStrings("res://door.flux", globalText(app, file, "after"));
}

const guard_script =
    \\enum Mood { calm, angry }
    \\var seen_hp = 0;
    \\var angry = false;
    \\var steps = 0;
    \\var alpha = 0.0;
    \\var aimed = false;
    \\var motto = "";
    \\struct Guard {
    \\    /// What it takes.
    \\    @export @range(0, 100) var hp: int = 10;
    \\    @export var mood: Mood = .calm;
    \\    @export var path: [vec2];
    \\    @export var tint: color = color(1, 1, 1);
    \\    @export @entity var target: any = null;
    \\    @export @multiline var motto: string = "halt";
    \\    var hidden = 3;
    \\    fn ready(self) {
    \\        seen_hp = self.hp;
    \\        angry = self.mood == Mood.angry;
    \\        steps = self.path.len;
    \\        alpha = self.tint.a;
    \\        aimed = self.target != null;
    \\        motto = self.motto;
    \\    }
    \\}
;

test "a scene gives a script's @exports their values before its ready, and writes them back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "guard.flux", .data = guard_script });
    const app = try scriptedAt(root);
    defer app.destroy();

    const level =
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "uuid": "00000000-0000-4000-8000-00000000000a", "name": "post" },
        \\  { "uuid": "00000000-0000-4000-8000-00000000000b", "name": "guard", "Script": { "source": "res://guard.flux" },
        \\    "exports": { "hp": 42, "mood": "angry", "path": [[0, 0], [16, 0]], "tint": "#ff000080",
        \\                 "target": "00000000-0000-4000-8000-00000000000a", "hidden": 9, "gone": 1 } }
        \\] }
    ;
    _ = try scene.read(app, level, .{});
    _ = try app.step();
    const file = app.findScript("res://guard.flux").?;
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqual(@as(i64, 42), global(app, file, "seen_hp").asInt());
    try testing.expect(global(app, file, "angry").asBool());
    try testing.expectEqual(@as(i64, 2), global(app, file, "steps").asInt());
    try testing.expectApproxEqAbs(@as(f64, 0.5), global(app, file, "alpha").asFloat(), 0.01);
    try testing.expect(global(app, file, "aimed").asBool());
    // Not given, a field keeps its default.
    try testing.expectEqualStrings("halt", globalText(app, file, "motto"));

    // An editor lists what the struct exports, with what it says of each.
    const guard = app.find("guard").?;
    var fields: [16]flux.FieldInfo = undefined;
    const listed = app.exportedFields(guard, &fields);
    try testing.expectEqual(@as(usize, 6), listed.len);
    try testing.expectEqualStrings("What it takes.", listed[0].doc.?);
    try testing.expectEqual(@as(i64, 100), flux.annotationOf(listed[0], "range").?[1].asInt());

    const written = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"exports\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"hp\": 42") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"mood\": \"angry\"") != null);
}

test "a default a script's field has is what a scene would write of it" {
    var doc: @import("fluxion_json").Document = try .init(testing.allocator);
    defer doc.deinit();
    const app = try scripted(.{});
    defer app.destroy();
    const vm = app.scripts.?.vm;
    try testing.expectEqual(@as(i64, 3), (try script.jsonOf(&doc, .int(3))).asInt(i64).?);
    const pair = try script.jsonOf(&doc, .vec2(1, 2));
    try testing.expectEqual(@as(f64, 2), pair.get(1).asFloat(f64).?);
    const red = try vm.newColor(.{ 1, 0, 0, 1 });
    try testing.expectEqualStrings("#ff0000", (try script.jsonOf(&doc, red)).asString().?);
}

fn keyed(key: @import("fluxion_platform").Key, action: @import("fluxion_platform").Action) @import("fluxion_platform").Event {
    return .{ .key = .{ .window = .none, .key = key, .virtual = key, .scancode = @enumFromInt(0), .action = action, .mods = .{} } };
}

test "a script hears the player's input, takes it from the scripts after it, and rebinds an action from it" {
    const app = try scripted(.{});
    defer app.destroy();
    try app.input.actions.add(testing.allocator, .{ .name = "jump", .bindings = &.{.keyOf(.space)} });
    const first = try app.addScript("first.flux",
        \\var jumps = 0;
        \\var named = "";
        \\var released = 0;
        \\struct First {
        \\    fn input(self, event: any) {
        \\        if (event.isActionPressed("jump")) {
        \\            jumps += 1;
        \\            named = event.describe();
        \\            app.setInputAsHandled();
        \\        }
        \\        if (event.isActionReleased("jump")) released += 1;
        \\        if (event.kind == "key" and event.key == "j" and event.pressed and !app.actionDown("jump")) {
        \\            _ = app.clearAction("jump");
        \\            app.bindAction("jump", event) catch {};
        \\        }
        \\    }
        \\}
    );
    const second = try app.addScript("second.flux",
        \\var heard = 0;
        \\var unheard = 0;
        \\struct Second {
        \\    fn input(self, event: any) {
        \\        if (event.kind == "key") heard += 1;
        \\    }
        \\    fn unhandled_input(self, event: any) {
        \\        if (event.kind == "mouse_button" and event.pressed and event.button == "left") unheard += 1;
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(first)});
    _ = try app.world.spawnWith(.{Script.of(second)});
    _ = try app.step();

    // Taken by the first, the press never reaches the second.
    app.input.apply(keyed(.space, .press));
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, first, "jumps").asInt());
    try testing.expectEqualStrings("Space", globalText(app, first, "named"));
    try testing.expectEqual(@as(i64, 0), global(app, second, "heard").asInt());

    // The release is nobody's to take, and a click nothing drew is left over.
    app.input.apply(keyed(.space, .release));
    app.input.apply(.{ .mouse_button = .{ .window = .none, .button = .left, .action = .press, .mods = .{}, .x = 10, .y = 10 } });
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, first, "released").asInt());
    try testing.expectEqual(@as(i64, 1), global(app, second, "heard").asInt());
    try testing.expectEqual(@as(i64, 1), global(app, second, "unheard").asInt());

    // J, pressed, is jump now, and Space is not.
    app.input.apply(keyed(.j, .press));
    _ = try app.step();
    app.input.apply(keyed(.j, .release));
    app.input.apply(keyed(.space, .press));
    _ = try app.step();
    try testing.expectEqual(@as(i64, 1), global(app, first, "jumps").asInt());
    app.input.apply(keyed(.space, .release));
    app.input.apply(keyed(.j, .press));
    _ = try app.step();
    try testing.expectEqual(@as(i64, 2), global(app, first, "jumps").asInt());
    try testing.expect(app.input.actions.get("jump").?.bindings[0].eql(.keyOf(.j)));
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
}

test "a data file is its struct, made anew from Flux with the file's values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "line.flux", .data =
        \\enum Mood { calm, angry }
        \\struct Line {
        \\    @export var speaker: string = "";
        \\    @export var text: string = "";
        \\    @export var mood: Mood = .calm;
        \\    @export var times: int = 1;
        \\    fn angry(self) bool { return self.mood == Mood.angry; }
        \\}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "intro.data", .data =
        \\{ "fluxion_data": 1, "script": "res://line.flux", "struct": "Line",
        \\  "values": { "speaker": "Guard", "text": "Halt!", "mood": "angry", "gone": 3 } }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.data", .data =
        \\{ "fluxion_data": 1, "script": "res://line.flux", "struct": "Nope" }
    });
    const app = try scriptedAt(root);
    defer app.destroy();
    const reader = try app.addScript("reader.flux",
        \\var said = "";
        \\var angry = false;
        \\var times = 0;
        \\var apart = false;
        \\var refused: any = null;
        \\struct Reader {
        \\    fn ready(self) {
        \\        const line = app.readData("res://intro.data") catch return;
        \\        said = line.speaker + ": " + line.text;
        \\        angry = line.angry();
        \\        times = line.times;
        \\        line.text = "changed";
        \\        const again = app.readData("res://intro.data") catch return;
        \\        apart = again.text == "Halt!";
        \\        refused = app.readData("res://broken.data") catch |e| e.name;
        \\    }
        \\}
    );
    _ = try app.world.spawnWith(.{Script.of(reader)});
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    try testing.expectEqualStrings("Guard: Halt!", globalText(app, reader, "said"));
    try testing.expect(global(app, reader, "angry").asBool());
    // Not given, a field keeps its default; each read is a struct of its own.
    try testing.expectEqual(@as(i64, 1), global(app, reader, "times").asInt());
    try testing.expect(global(app, reader, "apart").asBool());
    try testing.expectEqualStrings("NoSuchStruct", globalText(app, reader, "refused"));
    try testing.expectEqualStrings("res://intro.data", app.dataSource(app.findData("res://intro.data").?).?);
}
