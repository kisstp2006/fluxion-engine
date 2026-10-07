// SPDX-License-Identifier: BSD-3-Clause

//! Animation players and animated sprites, headless: a quarter of a second
//! a frame.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");

const App = @import("../App.zig");
const animation = @import("animation.zig");
const components = @import("../scene/components.zig");
const inherited = @import("../scene/inherited.zig");
const scene = @import("../scene/scene.zig");
const script = @import("../script/script.zig");
const skeleton_table = @import("../render/skeleton.zig");

const AnimationPlayer = animation.AnimationPlayer;
const Transform2D = components.Transform2D;
const Transform3D = components.Transform3D;
const Appearance = inherited.Appearance;

const quarterSecondApp = @import("../test_helpers.zig").quarterSecondApp;

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
    const app = try quarterSecondApp();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    app.world.get(it.root, AnimationPlayer).?.play("fade", -1);
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
    const app = try quarterSecondApp();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    const player = app.world.get(it.root, AnimationPlayer).?;
    player.play("spin", -1);
    for (0..5) |_| _ = try app.step();
    // A second and a quarter in: a quarter round again.
    try testing.expectApproxEqAbs(@as(f32, 1), app.world.get(it.child, Transform2D).?.rotation, 0.001);
    try testing.expectEqual(@as(usize, 0), Heard.finished);

    app.world.get(it.root, AnimationPlayer).?.play("bob", -1);
    for (0..6) |_| _ = try app.step();
    // A second and a half: half way back.
    try testing.expectApproxEqAbs(@as(f32, 5), app.world.get(it.child, Transform2D).?.y, 0.001);

    app.world.get(it.root, AnimationPlayer).?.play("fade", -1);
    app.world.get(it.root, AnimationPlayer).?.queue("blink");
    for (0..4) |_| _ = try app.step();
    try testing.expectEqualStrings("blink", app.world.get(it.root, AnimationPlayer).?.currentName());
    try testing.expect(app.world.get(it.root, AnimationPlayer).?.playing);
}

test "a player starts by itself, holds while paused, and is posed where a seek puts it" {
    const app = try quarterSecondApp();
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

test "a player plays backwards from the end, pauses and goes on, forgets its queue, and says what its library has" {
    const app = try quarterSecondApp();
    defer app.destroy();
    Heard.reset();
    const it = try rigged(app);
    app.world.get(it.root, AnimationPlayer).?.playBackwards("fade");
    _ = try app.step();
    // From the end, a quarter back.
    try testing.expectApproxEqAbs(@as(f32, 0.75), app.world.get(it.root, AnimationPlayer).?.position, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 75), app.world.get(it.child, Transform2D).?.x, 0.001);

    // Paused, it holds; played with no name, it goes on from there.
    app.world.get(it.root, AnimationPlayer).?.pause();
    try testing.expect(!app.world.get(it.root, AnimationPlayer).?.isPlaying());
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.75), app.world.get(it.root, AnimationPlayer).?.position, 0.001);
    app.world.get(it.root, AnimationPlayer).?.play("", -1);
    try testing.expect(app.world.get(it.root, AnimationPlayer).?.isPlaying());
    for (0..3) |_| _ = try app.step();
    // Back at the start, and finished there.
    try testing.expectEqual(@as(f32, 0), app.world.get(it.root, AnimationPlayer).?.position);
    try testing.expectEqual(@as(f32, 0), app.world.get(it.child, Transform2D).?.x);
    try testing.expectEqual(@as(usize, 1), Heard.finished);

    // A queue forgotten is not played.
    app.world.get(it.root, AnimationPlayer).?.play("fade", -1);
    app.world.get(it.root, AnimationPlayer).?.queue("blink");
    app.world.get(it.root, AnimationPlayer).?.clearQueue();
    for (0..5) |_| _ = try app.step();
    try testing.expectEqualStrings("fade", app.world.get(it.root, AnimationPlayer).?.currentName());

    const names = try app.animationNames(it.root);
    try testing.expectEqual(@as(usize, 4), names.len);
    try testing.expectEqualStrings("spin", names[1]);
    try testing.expect(app.hasAnimation(it.root, "bob") and !app.hasAnimation(it.root, "walk"));
    try testing.expectEqual(@as(f32, 1), app.animationLength(it.root, "fade"));
    try testing.expectEqual(@as(f32, 0), app.animationLength(it.child, "fade"));
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
        \\        const player = self.entity.get(AnimationPlayer);
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
    const app = try quarterSecondApp();
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

const bones_text =
    \\{ "fluxion_animation": 1, "animations": [
    \\  { "name": "raise", "length": 1, "tracks": [
    \\    { "target": "Rig", "bone": "Arm", "property": "position", "keys": [ { "time": 0, "value": [0, 1, 0] }, { "time": 1, "value": [0, 3, 0] } ] },
    \\    { "target": "Rig", "bone": "Arm", "property": "rotation",
    \\      "keys": [ { "time": 0, "value": { "x": 0, "y": 0, "z": 0, "w": 1 } }, { "time": 1, "value": { "x": 0, "y": 0, "z": 0.70710678, "w": 0.70710678 } } ] } ] },
    \\  { "name": "lift", "length": 1, "loop": "repeat", "tracks": [
    \\    { "target": "Rig", "bone": "Hips", "property": "position", "keys": [ { "time": 0, "value": [0, 2, 0] } ] },
    \\    { "target": "Rig", "bone": "Tail", "property": "position", "keys": [ { "time": 0, "value": [9, 9, 9] } ] },
    \\    { "target": "", "property": "Transform3D.position", "keys": [ { "time": 0, "value": [4, 0, 0] } ] } ] } ] }
;

/// A player over an entity called `Rig` with a skeleton of two bones: the
/// arm one up from the hips.
fn boned(app: *App) !struct { root: ecs.Entity, rig: ecs.Entity } {
    const bones = [_]skeleton_table.Bone{
        .{ .name = "Hips" },
        .{ .name = "Arm", .parent = 0, .rest = .{ .translation = .init(0, 1, 0) } },
    };
    const skeleton = try app.addSkeleton("rig", try skeleton_table.Skeleton.init(app.gpa, &bones));
    const library = try app.addAnimations("rig.anim", bones_text);
    const root = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), AnimationPlayer{ .library = library } });
    const rig = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), components.Parent.of(root), components.Skeleton3D{ .skeleton = skeleton } });
    try app.setName(rig, "Rig");
    return .{ .root = root, .rig = rig };
}

test "a bone's track moves that bone of the skeleton it names, and is written with its bone" {
    const app = try quarterSecondApp();
    defer app.destroy();
    const it = try boned(app);
    app.world.get(it.root, AnimationPlayer).?.play("raise", -1);
    _ = try app.step();
    try testing.expect(app.bonePosition(it.rig, 1).approxEql(.init(0, 1.5, 0)));
    for (0..3) |_| _ = try app.step();
    try testing.expect(app.bonePosition(it.rig, 1).approxEql(.init(0, 3, 0)));
    // A quarter turn about z: the arm's tip, one up from it, points left.
    try testing.expect(app.boneRotation(it.rig, 1).rotate(.init(0, 1, 0)).sub(.init(-1, 0, 0)).len() < 1e-4);
    try testing.expect(app.bonePosition(it.rig, 0).approxEql(.zero));

    const text = try app.animation_libraries.textOf(app, testing.allocator, app.findAnimations("rig.anim").?);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"bone\": \"Arm\"") != null);
    const copy = app.animation_libraries.edit(try app.addAnimations("copy.anim", text)).?;
    const track = copy.animations.items[0].boneTrackOf("Rig", "Arm", "rotation").?;
    try testing.expectEqual(@as(usize, 2), track.keys.items.len);
    try testing.expect(copy.animations.items[0].trackOf("Rig", "rotation") == null);
}

test "a track's keys are found by halving, as one key after another would find them" {
    var track: animation.Track = .{ .target = &.{}, .property = &.{} };
    defer track.keys.deinit(testing.allocator);
    for (0..1000) |at| try track.keys.append(testing.allocator, .{ .time = @floatFromInt(at), .value = .{ .number = @floatFromInt(at * 2) } });
    try testing.expectEqual(@as(f64, 0), track.sample(-5).?.number);
    try testing.expectEqual(@as(f64, 1998), track.sample(5000).?.number);
    try testing.expectApproxEqAbs(@as(f64, 1001), track.sample(500.5).?.number, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 14), track.sample(7).?.number, 1e-3);
    track.update = .discrete;
    try testing.expectEqual(@as(f64, 1000), track.sample(500.9).?.number);
}

test "a change of animation fades: each bone between the two, one only the old moved toward its rest" {
    const app = try quarterSecondApp();
    defer app.destroy();
    const it = try boned(app);
    app.world.get(it.root, AnimationPlayer).?.play("raise", -1);
    for (0..4) |_| _ = try app.step();
    try testing.expect(app.bonePosition(it.rig, 1).approxEql(.init(0, 3, 0)));

    // Over a second: a quarter of the way after a quarter.
    app.world.get(it.root, AnimationPlayer).?.play("lift", 1);
    _ = try app.step();
    try testing.expect(app.bonePosition(it.rig, 1).approxEql(.init(0, 2.5, 0)));
    try testing.expect(app.bonePosition(it.rig, 0).approxEql(.init(0, 0.5, 0)));
    // A property only the new one moves is where it says at once.
    try testing.expect(app.world.get(it.root, Transform3D).?.position.approxEql(.init(4, 0, 0)));
    for (0..3) |_| _ = try app.step();
    try testing.expect(app.bonePosition(it.rig, 1).approxEql(.init(0, 1, 0)));
    try testing.expect(app.boneRotation(it.rig, 1).approxEql(.identity));
    try testing.expect(app.bonePosition(it.rig, 0).approxEql(.init(0, 2, 0)));
    try testing.expectEqual(@as(f32, 0), app.world.get(it.root, AnimationPlayer).?.fade_length);

    // With a default, a change with no blend of its own fades too; nought
    // cuts.
    const player = app.world.get(it.root, AnimationPlayer).?;
    player.default_blend = 0.5;
    player.play("raise", -1);
    _ = try app.step();
    try testing.expect(app.world.get(it.root, AnimationPlayer).?.fade_length > 0);
    app.world.get(it.root, AnimationPlayer).?.play("lift", 0);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.world.get(it.root, AnimationPlayer).?.fade_length);
    try testing.expect(app.bonePosition(it.rig, 0).approxEql(.init(0, 2, 0)));
}
