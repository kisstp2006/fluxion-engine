// SPDX-License-Identifier: BSD-3-Clause

//! Animation players and animated sprites, headless: a quarter of a second
//! a frame.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const animation = @import("animation.zig");
const components = @import("components.zig");
const inherited = @import("inherited.zig");
const scene = @import("scene.zig");
const script = @import("script.zig");

const AnimationPlayer = animation.AnimationPlayer;
const Transform2D = components.Transform2D;
const Appearance = inherited.Appearance;

fn quartered() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    return app;
}

const library_text =
    \\{ "fluxion_animation": 1, "animations": [
    \\  { "name": "fade", "length": 1, "tracks": [
    \\    { "target": "", "property": "Appearance.modulate.a", "keys": [ { "time": 0, "value": 0 }, { "time": 1, "value": 1 } ] },
    \\    { "target": "Child", "property": "Transform2D.x,y", "keys": [ { "time": 0, "value": [0, 0] }, { "time": 1, "value": [100, 50] } ] } ] },
    \\  { "name": "spin", "length": 1, "loop": "repeat", "tracks": [
    \\    { "target": "Child", "property": "Transform2D.rotation", "keys": [ { "time": 0, "value": 0 }, { "time": 1, "value": 4 } ] } ] },
    \\  { "name": "bob", "length": 1, "loop": "ping_pong", "tracks": [
    \\    { "target": "Child", "property": "Transform2D.y", "keys": [ { "time": 0, "value": 0 }, { "time": 1, "value": 10 } ] } ] },
    \\  { "name": "blink", "length": 1, "tracks": [
    \\    { "target": "", "property": "Appearance.visible", "update": "discrete",
    \\      "keys": [ { "time": 0, "value": true }, { "time": 0.5, "value": false } ] } ] } ] }
;

const Heard = struct {
    var started: usize = 0;
    var finished: usize = 0;
    var last: [32]u8 = @splat(0);
    var last_len: usize = 0;

    fn reset() void {
        started = 0;
        finished = 0;
        last_len = 0;
    }

    fn start(_: *App, _: struct { name: []const u8 }) !void {
        started += 1;
    }

    fn done(_: *App, args: struct { name: []const u8 }) !void {
        finished += 1;
        last_len = @min(args.name.len, last.len);
        @memcpy(last[0..last_len], args.name[0..last_len]);
    }
};

/// A player on a root with an `Appearance`, over a child called `Child`.
fn rigged(app: *App) !struct { root: ecs.Entity, child: ecs.Entity } {
    const library = try app.addAnimations("ui.anim", library_text);
    const root = try app.world.spawnWith(.{ Transform2D.at(0, 0), Appearance{}, AnimationPlayer{ .library = library } });
    const child = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Parent.of(root) });
    try app.setName(child, "Child");
    try app.signal(root, AnimationPlayer, .animation_started).connectFn(Heard.start, .{});
    try app.signal(root, AnimationPlayer, .animation_finished).connectFn(Heard.done, .{});
    return .{ .root = root, .child = child };
}

test "a player plays an animation on its entity and the one under it, and says when it starts and finishes" {
    const app = try quartered();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    app.world.get(it.root, AnimationPlayer).?.play("fade");
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.started);
    try testing.expectApproxEqAbs(@as(f32, 0.25), app.world.get(it.root, Appearance).?.modulate.a, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 25), app.world.get(it.child, Transform2D).?.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12.5), app.world.get(it.child, Transform2D).?.y, 0.001);

    for (0..3) |_| _ = try app.step();
    const player = app.world.get(it.root, AnimationPlayer).?;
    try testing.expect(!player.playing);
    try testing.expectEqualStrings("fade", player.currentName());
    try testing.expectEqual(@as(f32, 1), app.world.get(it.root, Appearance).?.modulate.a);
    try testing.expectEqual(@as(usize, 1), Heard.finished);
    try testing.expectEqualStrings("fade", Heard.last[0..Heard.last_len]);
}

test "a looping animation goes round, one going back and forth comes back, and a queued one follows" {
    const app = try quartered();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    const player = app.world.get(it.root, AnimationPlayer).?;
    player.play("spin");
    for (0..5) |_| _ = try app.step();
    // A second and a quarter in: a quarter round again.
    try testing.expectApproxEqAbs(@as(f32, 1), app.world.get(it.child, Transform2D).?.rotation, 0.001);
    try testing.expectEqual(@as(usize, 0), Heard.finished);

    app.world.get(it.root, AnimationPlayer).?.play("bob");
    for (0..6) |_| _ = try app.step();
    // A second and a half: half way back.
    try testing.expectApproxEqAbs(@as(f32, 5), app.world.get(it.child, Transform2D).?.y, 0.001);

    app.world.get(it.root, AnimationPlayer).?.play("fade");
    app.world.get(it.root, AnimationPlayer).?.queue("blink");
    for (0..4) |_| _ = try app.step();
    try testing.expectEqualStrings("blink", app.world.get(it.root, AnimationPlayer).?.currentName());
    try testing.expect(app.world.get(it.root, AnimationPlayer).?.playing);
}

test "a player starts by itself, holds while paused, and is posed where a seek puts it" {
    const app = try quartered();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    app.world.get(it.root, AnimationPlayer).?.setAutoplay("blink");
    _ = try app.step();
    try testing.expect(app.world.get(it.root, Appearance).?.visible);
    _ = try app.step();
    // A discrete track jumps: half a second in, hidden.
    try testing.expect(!app.world.get(it.root, Appearance).?.visible);

    app.world.get(it.root, AnimationPlayer).?.seek(0.25);
    app.world.get(it.root, AnimationPlayer).?.paused = true;
    _ = try app.step();
    try testing.expect(app.world.get(it.root, Appearance).?.visible);
    try testing.expectEqual(@as(f32, 0.25), app.world.get(it.root, AnimationPlayer).?.position);

    // An editor poses one with no player, as it scrubs.
    const library = app.animation_libraries.get(app.findAnimations("ui.anim").?).?;
    try animation.pose(app, it.root, library.find("fade").?, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), app.world.get(it.child, Transform2D).?.x, 0.001);
}

test "a scene writes a player's library as its file, and an animation from Flux" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ui.anim", .data = library_text });
    var buffer: [128]u8 = undefined;
    const root_dir = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root_dir, .fixed_delta = 0.25 });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.useScripts(.{});

    const library = try app.loadAnimations("res://ui.anim");
    const handle = try app.addScript("fader.flux",
        \\var finished = "";
        \\fn done(name: string) { finished = name; }
        \\struct Fader {
        \\    fn ready(self) {
        \\        const player = self.entity.get("AnimationPlayer");
        \\        player.animation_finished.connect(done);
        \\        player.play("fade");
        \\    }
        \\}
    );
    var player: AnimationPlayer = .{ .library = library };
    player.setAutoplay("blink");
    const root = try app.world.spawnWith(.{ Transform2D.at(0, 0), Appearance{}, player });
    const child = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Parent.of(root) });
    try app.setName(child, "Child");

    const written = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"library\": \"res://ui.anim\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"autoplay\": \"blink\"") != null);

    try app.world.add(root, script.Script.of(handle));
    for (0..6) |_| _ = try app.step();
    const scripts = app.scripts.?;
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    const said = scripts.vm.get(scripts.moduleOf(handle).?, "finished").?;
    try testing.expectEqualStrings("fade", said.as(@import("fluxion_script").object.String).bytes());
}

test "an editor adds animations, tracks and keys, and a track names what it moves by its path" {
    const app = try quartered();
    defer app.destroy();
    const it = try rigged(app);
    const library = app.animation_libraries.edit(app.findAnimations("ui.anim").?).?;
    const made = try library.addAnimation(app.gpa, "shake");
    const track = try made.ensureTrack(app.gpa, "Child", "Transform2D.x");
    try testing.expectEqual(track, try made.ensureTrack(app.gpa, "Child", "Transform2D.x"));
    _ = try track.setKey(app.gpa, .{ .time = 1, .value = .{ .number = 10 } });
    _ = try track.setKey(app.gpa, .{ .time = 0, .value = .{ .number = 0 } });
    try testing.expectEqual(@as(usize, 1), try track.setKey(app.gpa, .{ .time = 1.0001, .value = .{ .number = 20 } }));
    try testing.expectEqual(@as(usize, 2), track.keys.items.len);
    try testing.expectEqual(@as(f64, 20), track.keys.items[1].value.number);
    try library.renameAnimation(app.gpa, library.indexOf("shake").?, "wobble");
    library.touched();
    try animation.pose(app, it.root, library.find("wobble").?, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 10), app.world.get(it.child, Transform2D).?.x, 0.001);
    library.removeAnimation(app.gpa, library.indexOf("wobble").?);
    try testing.expect(library.find("wobble") == null);

    var buffer: [64]u8 = undefined;
    const grandchild = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Parent.of(it.child) });
    try testing.expect(animation.targetPath(app, it.root, grandchild, &buffer) == null);
    try app.setName(grandchild, "Hand");
    try testing.expectEqualStrings("Child/Hand", animation.targetPath(app, it.root, grandchild, &buffer).?);
    try testing.expectEqualStrings("", animation.targetPath(app, it.root, it.root, &buffer).?);
    try testing.expect(animation.targetPath(app, it.child, it.root, &buffer) == null);
}
