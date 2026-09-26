// SPDX-License-Identifier: BSD-3-Clause

//! The engine's sound, headless: every frame's sound mixed and heard
//! nowhere, so what a game hears of it - `playing`, `position`, `finished` -
//! and how loud a frame was are there to check.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const sound = @import("fluxion_audio");

const App = @import("App.zig");
const audio = @import("audio.zig");
const inherited = @import("inherited.zig");
const components = @import("components.zig");
const scene = @import("scene.zig");
const script = @import("script.zig");

const AudioPlayer = audio.AudioPlayer;

/// A quarter of a second a frame.
fn quartered() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    return app;
}

/// `seconds` of a constant half-loud tone, mono at 44100, as a WAVE file.
fn tone(seconds: f32) ![]u8 {
    const count: usize = @intFromFloat(seconds * 44100);
    const samples = try testing.allocator.alloc(i16, count);
    defer testing.allocator.free(samples);
    @memset(samples, 16384);
    return sound.wav.write(testing.allocator, i16, 1, 44100, samples);
}

fn clipOf(app: *App, name: []const u8, seconds: f32) !audio.AudioClipHandle {
    const file = try tone(seconds);
    defer testing.allocator.free(file);
    return app.addAudio(name, file);
}

const Heard = struct {
    var finished: usize = 0;

    fn done(_: *App, _: struct {}) !void {
        finished += 1;
    }
};

test "a player that starts by itself plays its clip through, and says finished at its end" {
    const app = try quartered();
    defer app.destroy();
    Heard.finished = 0;
    const clip = try clipOf(app, "beep.wav", 1);
    try testing.expectApproxEqAbs(@as(f32, 1), app.audioLength(clip), 0.001);
    const beeper = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .autoplay = true }});
    try app.signal(beeper, AudioPlayer, .finished).connectFn(Heard.done, .{});

    _ = try app.step();
    try testing.expect(app.world.get(beeper, AudioPlayer).?.playing);
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(beeper, AudioPlayer).?.position, 0.001);
    // Heard: half as loud as it goes.
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.audio.loudest(), 0.001);

    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.finished);
    const player = app.world.get(beeper, AudioPlayer).?;
    try testing.expect(!player.playing);
    try testing.expectEqual(@as(f32, 0), player.position);
    // It started by itself once, and does not again.
    for (0..6) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Heard.finished);
}

test "play, seek and stop are done by the next audio pass, and a loop never finishes" {
    const app = try quartered();
    defer app.destroy();
    Heard.finished = 0;
    const clip = try clipOf(app, "beep.wav", 1);
    const beeper = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .loop = true }});
    try app.signal(beeper, AudioPlayer, .finished).connectFn(Heard.done, .{});
    _ = try app.step();
    try testing.expect(!app.world.get(beeper, AudioPlayer).?.playing);

    app.world.get(beeper, AudioPlayer).?.play(0.5);
    try testing.expect(app.world.get(beeper, AudioPlayer).?.playing);
    for (0..9) |_| _ = try app.step();
    // Round and round: 0.5 in, and nine quarters on.
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(beeper, AudioPlayer).?.position, 0.001);
    try testing.expectEqual(@as(usize, 0), Heard.finished);

    app.world.get(beeper, AudioPlayer).?.seek(0.25);
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(beeper, AudioPlayer).?.position, 0.001);

    app.world.get(beeper, AudioPlayer).?.stop();
    _ = try app.step();
    try testing.expect(!app.world.get(beeper, AudioPlayer).?.playing);
    try testing.expectEqual(@as(usize, 0), app.audio.voices.count());
    // The frame it was asked in was heard; the next is not.
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.audio.loudest());
    try testing.expectEqual(@as(usize, 0), Heard.finished);
}

test "a frame with no time starts nothing, as an editor's never does" {
    const app = try quartered();
    defer app.destroy();
    app.time.scale = 0;
    const clip = try clipOf(app, "beep.wav", 1);
    const beeper = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .autoplay = true }});
    const asked = try app.world.spawnWith(.{AudioPlayer{ .clip = clip }});
    app.world.get(asked, AudioPlayer).?.play(0);
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.audio.voices.count());
    try testing.expect(!app.world.get(beeper, AudioPlayer).?.started);

    // Time again: the one asked plays, and the other starts by itself.
    app.time.scale = 1;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), app.audio.voices.count());
}

test "a paused game holds its sounds where they are, but for those that run while it is paused" {
    const app = try quartered();
    defer app.destroy();
    const clip = try clipOf(app, "beep.wav", 4);
    const world_sound = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .autoplay = true }});
    const menu_music = try app.world.spawnWith(.{ AudioPlayer{ .clip = clip, .autoplay = true }, inherited.Processing{ .mode = .always } });
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.25), app.world.get(world_sound, AudioPlayer).?.position, 0.001);

    app.setPaused(true);
    for (0..4) |_| _ = try app.step();
    try testing.expect(app.world.get(world_sound, AudioPlayer).?.playing);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(world_sound, AudioPlayer).?.position, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.25), app.world.get(menu_music, AudioPlayer).?.position, 0.001);

    app.setPaused(false);
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.75), app.world.get(world_sound, AudioPlayer).?.position, 0.001);
}

test "a player's own paused holds it, and a despawned one's sound stops" {
    const app = try quartered();
    defer app.destroy();
    const clip = try clipOf(app, "beep.wav", 4);
    const beeper = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .autoplay = true }});
    _ = try app.step();
    _ = try app.step();
    app.world.get(beeper, AudioPlayer).?.paused = true;
    for (0..3) |_| _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.world.get(beeper, AudioPlayer).?.position, 0.001);
    try testing.expectEqual(@as(f32, 0), app.audio.loudest());

    app.world.despawn(beeper);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.audio.voices.count());
}

test "buses are the project's, each into the one it sends to, and turned down are heard quieter" {
    var mixed: audio.Audio = try .init(testing.allocator, .silent, true, &.{
        .{ .name = "Music", .volume_db = -6, .send = "Loud" },
        .{ .name = "Loud", .send = "Music" },
        .{ .name = "Master", .volume_db = -3 },
        .{ .name = "Voices", .mute = true, .send = "Nowhere" },
    });
    defer mixed.deinit();
    try testing.expectEqualStrings("Master", mixed.buses.items[0].name);
    try testing.expectEqual(@as(f32, -3), mixed.buses.items[0].volume_db);
    try testing.expectEqual(@as(usize, 4), mixed.buses.items.len);
    // Music into Loud, and Loud - which would come back round - into Master.
    try testing.expectEqual(mixed.busIndex("Loud").?, mixed.buses.items[mixed.busIndex("Music").?].send);
    try testing.expectEqual(@as(usize, 0), mixed.buses.items[mixed.busIndex("Loud").?].send);
    try testing.expectEqual(@as(usize, 0), mixed.buses.items[mixed.busIndex("Voices").?].send);
    try testing.expect(mixed.isBusMuted("Voices"));

    const app = try quartered();
    defer app.destroy();
    const clip = try clipOf(app, "beep.wav", 4);
    const beeper = try app.world.spawnWith(.{AudioPlayer{ .clip = clip, .autoplay = true }});
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.audio.loudest(), 0.001);
    try testing.expect(app.setBusVolumeDb("Master", -6));
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.25), app.audio.loudest(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, -6), app.busVolumeDb("Master"), 0.001);
    try testing.expect(!app.setBusVolumeDb("Nowhere", 0));
    try testing.expect(app.setBusMute("Master", true));
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.audio.loudest());
    // A bus the project has not is Master.
    app.world.get(beeper, AudioPlayer).?.setBus("Nowhere");
    _ = try app.step();
    try testing.expectEqualStrings("Nowhere", app.world.get(beeper, AudioPlayer).?.busName());
    try testing.expect(app.world.get(beeper, AudioPlayer).?.playing);
}

test "a player in the world is quieter far from the listener, and panned to its side" {
    const app = try quartered();
    defer app.destroy();
    const clip = try clipOf(app, "beep.wav", 4);
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), audio.AudioListener2D{} });
    const near = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), AudioPlayer{ .clip = clip, .autoplay = true }, audio.AudioSpatial2D{ .max_distance = 1000 } });
    const right = try app.world.spawnWith(.{ components.Transform2D.at(500, 0), AudioPlayer{ .clip = clip, .autoplay = true }, audio.AudioSpatial2D{ .max_distance = 1000 } });
    const gone = try app.world.spawnWith(.{ components.Transform2D.at(-2000, 0), AudioPlayer{ .clip = clip, .autoplay = true }, audio.AudioSpatial2D{ .max_distance = 1000 } });
    _ = try app.step();
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 1), app.audio.voices.get(near).?.gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.audio.voices.get(right).?.gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), app.audio.voices.get(right).?.pan, 0.001);
    try testing.expectEqual(@as(f32, 0), app.audio.voices.get(gone).?.gain);

    // Moved, it is heard as it is now.
    app.world.get(right, components.Transform2D).?.x = 250;
    _ = try app.step();
    try testing.expectApproxEqAbs(@as(f32, 0.75), app.audio.voices.get(right).?.gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.audio.voices.get(right).?.pan, 0.001);
}

test "a scene writes a player's clip as its file, and reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tone(0.5);
    defer testing.allocator.free(file);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "beep.wav", .data = file });
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
    defer app.destroy();

    const clip = try app.loadAudio("res://beep.wav");
    try testing.expect(app.findAudio("res://beep.wav").?.eql(clip));
    var player: AudioPlayer = .{ .clip = clip, .volume_db = -3, .loop = true };
    player.setBus("Music");
    _ = try app.world.spawnWith(.{player});
    const written = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"clip\": \"res://beep.wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"bus\": \"Music\"") != null);

    app.clearWorld();
    _ = try scene.read(app, written, .{});
    var it = try ecs.Query(.{AudioPlayer}).over(&app.world);
    const back = (it.next() orelse return error.TestUnexpectedResult).slice(AudioPlayer)[0];
    try testing.expect(back.clip.eql(clip));
    try testing.expectEqualStrings("Music", back.busName());
    try testing.expectEqual(@as(f32, -3), back.volume_db);
}

test "a script plays a sound, hears it finish, and turns a bus down" {
    const app = try quartered();
    defer app.destroy();
    try app.useScripts(.{});
    _ = try clipOf(app, "beep.wav", 0.5);
    const handle = try app.addScript("sfx.flux",
        \\var length = 0.0;
        \\var asked = false;
        \\var heard = 0;
        \\var master = 0.0;
        \\fn done() { heard += 1; }
        \\struct Sfx {
        \\    fn ready(self) {
        \\        const player = self.entity.get(AudioPlayer);
        \\        player.clip = "beep.wav";
        \\        player.play(0.0);
        \\        asked = player.playing;
        \\        player.finished.connect(done);
        \\        length = app.audioLength("beep.wav");
        \\        app.setBusVolumeDb("Master", app.linearToDb(0.5));
        \\        master = app.busVolumeDb("Master");
        \\    }
        \\}
    );
    const beeper = try app.world.spawnWith(.{ AudioPlayer{}, script.Script.of(handle) });
    for (0..5) |_| _ = try app.step();
    const scripts = app.scripts.?;
    const module = scripts.moduleOf(handle).?;
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    try testing.expect(scripts.vm.get(module, "asked").?.asBool());
    try testing.expectApproxEqAbs(@as(f64, 0.5), scripts.vm.get(module, "length").?.asFloat(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, -6.02), scripts.vm.get(module, "master").?.asFloat(), 0.01);
    try testing.expectEqual(@as(i64, 1), scripts.vm.get(module, "heard").?.asInt());
    try testing.expect(!app.world.get(beeper, AudioPlayer).?.playing);
}
