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

const flux = script.flux;
const Entity = ecs.Entity;
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

/// A headless app running scripts: a quarter of a second a frame, and one
/// step in each.
fn scripted(options: script.Options) !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    errdefer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.registerComponents(.{ Counter, Marker });
    try app.useScripts(options);
    return app;
}

/// The same, with a project at `root` to read scripts from.
fn scriptedAt(root: []const u8) !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .fixed_delta = 0.25 });
    errdefer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.registerComponents(.{ Counter, Marker });
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
    \\    fn physics(self, dt: float) {
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
    try app.addSystem(.fixed, "look after physics", Seen.fixed);
    try app.addSystem(.update, "look after update", Seen.update);

    for (0..3) |_| _ = try app.step();

    try testing.expectEqual(@as(i64, 1), global(app, file, "readied").asInt());
    try testing.expectEqualStrings("front door", globalText(app, file, "named"));
    // Each step's system saw that step's `physics`, and each frame's system
    // that frame's `update`.
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, Seen.in_fixed[0..Seen.fixed_count]);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, Seen.in_update[0..Seen.update_count]);
    // The instance keeps its own fields from frame to frame.
    const instance = app.scripts.?.instanceOf(door).?;
    try testing.expectEqual(@as(i64, 3), (try app.scripts.?.vm.callMethod(instance, "framesSoFar", &.{})).asInt());
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
