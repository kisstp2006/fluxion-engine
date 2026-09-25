// SPDX-License-Identifier: BSD-3-Clause

//! Sprite frames and the animated sprites that play them, headless: a
//! quarter of a second a frame, at four frames a second, so a pass is one
//! frame's progress exactly.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const image = @import("fluxion_image");
const flux = @import("fluxion_script");

const App = @import("App.zig");
const components = @import("components.zig");
const scene = @import("scene.zig");
const script = @import("script.zig");
const sprite_frames = @import("sprite_frames.zig");

const AnimatedSprite2D = sprite_frames.AnimatedSprite2D;
const Entity = ecs.Entity;
const Sprite = components.Sprite;
const Transform2D = components.Transform2D;

fn quartered() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 0.25 });
    app.time.source = .{ .fixed = 0.25 };
    return app;
}

/// A sheet of four cells of four by four texels, and four animations of
/// them at four frames a second: `walk`, round and round; `once`, three
/// frames once; `swing`, three frames back and forth; `none`, no frames.
fn rigged(app: *App) !sprite_frames.SpriteFramesHandle {
    const sheet = try app.assets.textureFromPixels(16, 4, &(.{255} ** (16 * 4 * 4)), .{});
    return app.addGridFrames("strip.frames", sheet, 4, 1, &.{
        .{ .name = "walk", .cells = &.{ 0, 1, 2, 3 }, .speed = 4 },
        .{ .name = "once", .cells = &.{ 0, 1, 2 }, .speed = 4, .loop = .none },
        .{ .name = "swing", .cells = &.{ 0, 1, 2 }, .speed = 4, .loop = .pingpong },
        .{ .name = "none", .cells = &.{}, .speed = 4 },
    });
}

/// What a sprite said, a letter a signal: `a`nimation changed, `f`inished,
/// `l`ooped, `n`ew frame, `s`prite frames changed.
const Heard = struct {
    var letters: [256]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }

    fn said() []const u8 {
        defer len = 0;
        return letters[0..len];
    }

    fn got(letter: u8) void {
        letters[len] = letter;
        len += 1;
    }

    fn changed(_: *App, _: struct {}) !void {
        got('a');
    }
    fn finished(_: *App, _: struct {}) !void {
        got('f');
    }
    fn looped(_: *App, _: struct {}) !void {
        got('l');
    }
    fn frame(_: *App, _: struct {}) !void {
        got('n');
    }
    fn frames(_: *App, _: struct {}) !void {
        got('s');
    }

    fn listen(app: *App, e: Entity) !void {
        reset();
        try app.signal(e, AnimatedSprite2D, .animation_changed).connectFn(changed, .{});
        try app.signal(e, AnimatedSprite2D, .animation_finished).connectFn(finished, .{});
        try app.signal(e, AnimatedSprite2D, .animation_looped).connectFn(looped, .{});
        try app.signal(e, AnimatedSprite2D, .frame_changed).connectFn(frame, .{});
        try app.signal(e, AnimatedSprite2D, .sprite_frames_changed).connectFn(frames, .{});
    }
};

fn spawned(app: *App, sprite: AnimatedSprite2D) !Entity {
    const e = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{}, sprite });
    try Heard.listen(app, e);
    return e;
}

fn of(app: *App, e: Entity) *AnimatedSprite2D {
    return app.world.get(e, AnimatedSprite2D).?;
}

fn steps(app: *App, n: usize) !void {
    for (0..n) |_| _ = try app.step();
}

test "a set of sprite frames answers the calls a set of frames does" {
    const app = try quartered();
    defer app.destroy();
    const gpa = app.gpa;
    const handle = try app.newSpriteFrames();
    const frames = app.sprite_frames.edit(handle).?;
    try testing.expect(frames.hasAnimation("default"));
    try testing.expectEqual(@as(f32, 5), frames.getAnimationSpeed("default"));
    try testing.expectEqual(sprite_frames.LoopMode.linear, frames.getAnimationLoopMode("default"));
    try testing.expectError(error.AnimationExists, frames.addAnimation(gpa, "default"));

    const a = try app.assets.textureFromPixels(1, 1, &.{ 1, 2, 3, 4 }, .{});
    const b = try app.assets.textureFromPixels(1, 1, &.{ 5, 6, 7, 8 }, .{});
    try frames.addAnimation(gpa, "run");
    try frames.addFrame(gpa, "run", a, 1, -1);
    try frames.addFrame(gpa, "run", b, 2, 0);
    try frames.addFrameRegion(gpa, "run", a, .init(1, 2, 3, 4), 1, 99);
    try testing.expectEqual(@as(i32, 3), frames.getFrameCount("run"));
    try testing.expect(frames.getFrameTexture("run", 0).eql(b));
    try testing.expectEqual(@as(f32, 2), frames.getFrameDuration("run", 0));
    try testing.expectEqual(@as(f32, 3), frames.getFrameRegion("run", 2).size.x);
    try testing.expect(frames.getFrameTexture("run", 7).isNone());
    try testing.expectEqual(@as(i32, 0), frames.getFrameCount("fly"));
    try testing.expectError(error.NoSuchAnimation, frames.addFrame(gpa, "fly", a, 1, -1));

    try frames.setFrame("run", 1, b, 3);
    try testing.expect(frames.getFrameTexture("run", 1).eql(b));
    try testing.expectError(error.NoSuchFrame, frames.setFrame("run", 3, b, 1));
    try frames.removeFrame("run", 0);
    try testing.expectEqual(@as(i32, 2), frames.getFrameCount("run"));

    try frames.duplicateAnimation(gpa, "run", "dash");
    try frames.setAnimationSpeed("dash", 12);
    try frames.setAnimationLoopMode("dash", .pingpong);
    try testing.expectEqual(@as(i32, 2), frames.getFrameCount("dash"));
    try testing.expectEqual(@as(f32, 5), frames.getAnimationSpeed("run"));
    try frames.renameAnimation(gpa, "dash", "bolt");
    try testing.expectError(error.AnimationExists, frames.renameAnimation(gpa, "bolt", "run"));
    const names = try frames.getAnimationNames(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("bolt", names[0]);
    try testing.expectEqualStrings("default", names[1]);
    try testing.expectEqualStrings("run", names[2]);
    try testing.expectEqual(sprite_frames.LoopMode.pingpong, frames.getAnimationLoopMode("bolt"));

    try frames.clear("run");
    try testing.expectEqual(@as(i32, 0), frames.getFrameCount("run"));
    try frames.removeAnimation(gpa, "bolt");
    try testing.expect(!frames.hasAnimation("bolt"));
    try frames.clearAll(gpa);
    try testing.expectEqual(@as(usize, 1), frames.animations.items.len);
    try testing.expect(frames.hasAnimation("default"));
}

test "sprite frames are written as they are, and read back so" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root_dir = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var png_buffer: [192]u8 = undefined;
    try image.png.writeFile(testing.allocator, testing.io, try std.fmt.bufPrint(&png_buffer, "{s}/sheet.png", .{root_dir}), .{ .width = 8, .height = 4, .pixels = &(.{255} ** 128), .row_pitch = 32 }, .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hero.frames", .data =
        \\{ "fluxion_frames": 2, "animations": [
        \\    { "name": "walk", "speed": 8, "frames": [
        \\        { "texture": "res://sheet.png", "region": [0, 0, 4, 4] },
        \\        { "texture": "res://sheet.png", "region": [4, 0, 4, 4], "duration": 2 } ] },
        \\    { "name": "hit", "loop": "none", "frames": [ { "texture": "res://sheet.png" }, {} ] },
        \\    { "name": "bob", "loop": "pingpong", "frames": [] } ] }
    });
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root_dir });
    defer app.destroy();

    const handle = try app.loadSpriteFrames("res://hero.frames");
    const frames = app.sprite_frames.get(handle).?;
    try testing.expectEqual(@as(f32, 8), frames.getAnimationSpeed("walk"));
    try testing.expectEqual(@as(f32, 5), frames.getAnimationSpeed("hit"));
    try testing.expectEqual(sprite_frames.LoopMode.none, frames.getAnimationLoopMode("hit"));
    try testing.expectEqual(sprite_frames.LoopMode.pingpong, frames.getAnimationLoopMode("bob"));
    try testing.expectEqual(@as(f32, 2), frames.getFrameDuration("walk", 1));
    try testing.expectEqual(@as(f32, 4), frames.getFrameRegion("walk", 1).position.x);
    try testing.expect(frames.getFrameTexture("hit", 1).isNone());

    const text = try app.sprite_frames.textOf(app, testing.allocator, handle);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"fluxion_frames\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"loop\": \"pingpong\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"duration\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"texture\": \"res://sheet.png\"") != null);

    // Read again from what was written: the same frames.
    const copy = try app.addSpriteFrames("copy.frames", text);
    const again = app.sprite_frames.get(copy).?;
    try testing.expectEqual(@as(usize, 3), again.animations.items.len);
    try testing.expectEqual(@as(f32, 4), again.getFrameRegion("walk", 1).size.x);
    try testing.expectEqual(@as(i32, 2), again.getFrameCount("hit"));

    // New frames become the file they are saved as.
    const made = try app.newSpriteFrames();
    try app.saveSpriteFrames(made, "res://made.frames");
    try testing.expectEqualStrings("res://made.frames", app.sprite_frames.sourceOf(made).?);
    try testing.expect(app.findSpriteFrames("res://made.frames").?.eql(made));
}

test "forwards, a frame steps on once its progress is full, and a loop goes round" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .autoplaying(try rigged(app), "walk"));
    try steps(app, 1);
    // Autoplay: started, and a frame's progress on.
    try testing.expect(of(app, e).isPlaying());
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqual(@as(f32, 1), of(app, e).frame_progress);
    try steps(app, 3);
    try testing.expectEqual(@as(i32, 3), of(app, e).frame);
    try testing.expectEqualStrings("nnn", Heard.said());
    try steps(app, 1);
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqualStrings("ln", Heard.said());
    try testing.expectEqual(@as(f32, 1), of(app, e).getPlayingSpeed());
}

test "a one-shot stops on its last frame, paused, and says it finished; play() starts it again" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .{ .sprite_frames = try rigged(app) });
    try steps(app, 1);
    // Not autoplayed: `default` is not one of these, so the first is taken.
    try testing.expectEqualStrings("walk", of(app, e).animationName());
    try testing.expect(!of(app, e).isPlaying());

    of(app, e).play("once", 1, false);
    try testing.expectEqualStrings("once", of(app, e).animationName());
    try steps(app, 3);
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    try testing.expectEqualStrings("ann", Heard.said());
    try steps(app, 1);
    try testing.expect(!of(app, e).isPlaying());
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    try testing.expectEqual(@as(f32, 0), of(app, e).getPlayingSpeed());
    try testing.expectEqualStrings("f", Heard.said());
    try steps(app, 2);
    try testing.expectEqualStrings("", Heard.said());

    // Played again from its end: from its start.
    of(app, e).play("", 1, false);
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try steps(app, 2);
    try testing.expectEqual(@as(i32, 1), of(app, e).frame);
    try testing.expectEqualStrings("nn", Heard.said());
}

test "backwards, it starts from the last frame and a one-shot finishes on the first" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .{ .sprite_frames = try rigged(app) });
    try steps(app, 1);
    of(app, e).playBackwards("once");
    try testing.expectEqual(@as(f32, 1), of(app, e).frame_progress);
    try steps(app, 1);
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    try testing.expectEqual(@as(f32, 0), of(app, e).frame_progress);
    try testing.expectEqual(@as(f32, -1), of(app, e).getPlayingSpeed());
    try steps(app, 2);
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try steps(app, 1);
    try testing.expect(!of(app, e).isPlaying());
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqualStrings("annnf", Heard.said());

    // A negative scale plays backwards too, and a loop goes round to the end.
    of(app, e).speed_scale = -1;
    of(app, e).play("walk", 1, false);
    // Round from the first frame to the last, and on back.
    try steps(app, 1);
    try testing.expectEqual(@as(i32, 3), of(app, e).frame);
    try testing.expectEqualStrings("aln", Heard.said());
    try steps(app, 1);
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
}

test "back and forth, it turns round at either end and shows the ends once" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .autoplaying(try rigged(app), "swing"));
    var shown: [9]i32 = undefined;
    for (&shown) |*frame| {
        try steps(app, 1);
        frame.* = of(app, e).frame;
    }
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 1, 0, 1, 2, 1, 0 }, &shown);
    try testing.expectEqualStrings("nnlnnlnnlnn", Heard.said());
    // Turned round by its custom speed: going back, until the next pass.
    try testing.expect(of(app, e).getPlayingSpeed() < 0);
}

test "pause holds it where it is, play() goes on from there, and stop() puts it back" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .autoplaying(try rigged(app), "walk"));
    try steps(app, 3);
    of(app, e).pause();
    try steps(app, 2);
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    of(app, e).play("", 2, false);
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    try testing.expectEqual(@as(f32, 2), of(app, e).getPlayingSpeed());
    _ = Heard.said();
    try steps(app, 1);
    // Twice as fast: two frames' progress in a pass, the last frame's and,
    // round again, the first's.
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqual(@as(f32, 1), of(app, e).frame_progress);
    try testing.expectEqualStrings("nln", Heard.said());

    of(app, e).stop();
    try testing.expect(!of(app, e).isPlaying());
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqual(@as(f32, 0), of(app, e).frame_progress);
    try testing.expectEqual(@as(f32, 1), of(app, e).custom_speed);
}

test "writing the animation, the frame or the frames does what their setters do" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    const app = try quartered();
    defer app.destroy();
    const strip = try rigged(app);
    const e = try spawned(app, .autoplaying(strip, "walk"));
    try steps(app, 3);
    _ = Heard.said();

    // Another animation: from its first frame, and said.
    of(app, e).setAnimation("once");
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqual(@as(f32, 0), of(app, e).frame_progress);
    try testing.expect(of(app, e).isPlaying());
    // A frame: kept to them, from its beginning.
    of(app, e).setFrame(9);
    _ = try app.step();
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
    try testing.expectEqualStrings("an", Heard.said());
    of(app, e).setFrameAndProgress(-4, 0.5);
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    try testing.expectEqual(@as(f32, 0.5), of(app, e).frame_progress);

    // A name it has not: said in the log, and none.
    of(app, e).setAnimation("fly");
    _ = try app.step();
    try testing.expectEqualStrings("", of(app, e).animationName());
    try testing.expect(!of(app, e).isPlaying());
    _ = Heard.said();

    // Written as a field, as an inspector or a track does: the next pass
    // makes it the same.
    of(app, e).play("walk", 1, false);
    _ = try app.step();
    @memcpy(of(app, e).animation[0..4], "swin");
    of(app, e).animation[4] = 'g';
    of(app, e).frame_progress = 0.5;
    of(app, e).frame = 2;
    _ = try app.step();
    try testing.expectEqualStrings("swing", of(app, e).animationName());
    try testing.expect(Heard.len > 0);
    _ = Heard.said();

    // Other frames: stopped, a name they have not made their first, an
    // autoplay they have not dropped, and said.
    of(app, e).setAutoplay("walk");
    const other = try app.addGridFrames("other.frames", .none, 2, 1, &.{.{ .name = "blink", .cells = &.{ 0, 1 } }});
    of(app, e).setSpriteFrames(other);
    _ = try app.step();
    try testing.expectEqualStrings("blink", of(app, e).animationName());
    try testing.expectEqualStrings("", of(app, e).autoplayName());
    try testing.expect(!of(app, e).isPlaying());
    try testing.expectEqual(@as(i32, 0), of(app, e).frame);
    const said = Heard.said();
    try testing.expect(std.mem.indexOfScalar(u8, said, 's') != null);
    try testing.expect(std.mem.indexOfScalar(u8, said, 'a') != null);

    // Written as a field, the frames are the same too.
    of(app, e).sprite_frames = strip;
    _ = try app.step();
    try testing.expectEqualStrings("walk", of(app, e).animationName());
    const again = Heard.said();
    try testing.expect(std.mem.indexOfScalar(u8, again, 's') != null);
    try testing.expect(std.mem.indexOfScalar(u8, again, 'a') != null);
}

test "an animation with no frames does not play, and a frame without a texture shows nothing" {
    const app = try quartered();
    defer app.destroy();
    const e = try spawned(app, .autoplaying(try rigged(app), "walk"));
    try steps(app, 1);
    of(app, e).play("none", 1, false);
    _ = try app.step();
    try testing.expect(!of(app, e).isPlaying());
    try testing.expectEqual(@as(f32, 0), app.world.get(e, Sprite).?.width);
}

test "the Sprite beside it shows its frame: the part, flipped, its size, and its pivot" {
    const app = try quartered();
    defer app.destroy();
    var sprite: AnimatedSprite2D = .{ .sprite_frames = try rigged(app), .frame = 1 };
    sprite.offset = .init(1, -2);
    sprite.flip_h = true;
    const e = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{ .tint = .rgba(1, 0, 0, 1), .layer = 3 }, sprite });
    _ = try app.step();
    const drawn = app.world.get(e, Sprite).?;
    try testing.expectEqual(@as(f32, 0.5), drawn.region.u0);
    try testing.expectEqual(@as(f32, 0.25), drawn.region.u1);
    try testing.expectEqual(@as(f32, 4), drawn.width);
    try testing.expectEqual(@as(f32, 4), drawn.height);
    try testing.expectEqual(@as(f32, 0.25), drawn.pivot_x);
    try testing.expectEqual(@as(f32, 1), drawn.pivot_y);
    // What is the Sprite's own stays its own.
    try testing.expectEqual(@as(i16, 3), drawn.layer);
    try testing.expectEqual(@as(f32, 0), drawn.tint.g);

    of(app, e).centered = false;
    of(app, e).offset = .zero;
    of(app, e).flip_h = false;
    of(app, e).flip_v = true;
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), drawn.pivot_x);
    try testing.expectEqual(@as(f32, 1), drawn.region.v0);
    try testing.expectEqual(@as(f32, 0), drawn.region.v1);

    // With nothing to show, it shows nothing - not a white texel.
    of(app, e).sprite_frames = .none;
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), drawn.width);
    try testing.expectEqual(@as(f32, 0), drawn.region.u1);
}

test "autoplay waits for time to go by, as an editor's frames have none" {
    const app = try quartered();
    defer app.destroy();
    app.time.source = .{ .fixed = 0 };
    const e = try spawned(app, .autoplaying(try rigged(app), "walk"));
    try steps(app, 3);
    try testing.expect(!of(app, e).isPlaying());
    // In an editor the frame is shown all the same.
    of(app, e).frame = 2;
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0.5), app.world.get(e, Sprite).?.region.u0);

    app.time.source = .{ .fixed = 0.25 };
    _ = try app.step();
    try testing.expect(of(app, e).isPlaying());
}

test "a scene keeps what it is, and not what the engine works out while it plays" {
    const app = try quartered();
    defer app.destroy();
    const strip = try rigged(app);
    var sprite: AnimatedSprite2D = .autoplaying(strip, "swing");
    sprite.frame = 1;
    _ = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{}, sprite });
    try steps(app, 4);
    const text = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"autoplay\": \"swing\"") != null);
    for ([_][]const u8{ "playing", "custom_speed", "seen", "told", "frame_count", "started", "check_" }) |kept| {
        try testing.expect(std.mem.indexOf(u8, text, kept) == null);
    }
}

test "a track keys a sprite's animation by its name, and its frame" {
    const app = try quartered();
    defer app.destroy();
    const strip = try rigged(app);
    const e = try spawned(app, .{ .sprite_frames = strip });
    _ = try app.step();
    const name = try @import("property.zig").Property.compile(app, "AnimatedSprite2D.animation");
    try testing.expectEqualStrings("walk", name.read(app, e).?.text());
    try testing.expect(name.write(app, e, .nameOf("swing")));
    const frame = try @import("property.zig").Property.compile(app, "AnimatedSprite2D.frame");
    try testing.expect(frame.write(app, e, .{ .number = 2 }));
    _ = try app.step();
    try testing.expectEqualStrings("swing", of(app, e).animationName());
    try testing.expectEqual(@as(i32, 2), of(app, e).frame);
}

test "a script plays it, leaving arguments out, writes it through its setters, and holds its frames" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root_dir = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root_dir, .fixed_delta = 0.25 });
    defer app.destroy();
    app.time.source = .{ .fixed = 0.25 };
    try app.useScripts(.{});
    const strip = try rigged(app);

    const handle = try app.addScript("hero.flux",
        \\var finished = 0;
        \\var frame_after = -1;
        \\var names = [];
        \\var same = false;
        \\var path = "?";
        \\var loop = "";
        \\struct Hero {
        \\    fn ready(self) {
        \\        const sprite = self.entity.get("AnimatedSprite2D");
        \\        sprite.animation_finished.connect(fn () { finished += 1; });
        \\        sprite.play("once");
        \\        const frames = sprite.sprite_frames;
        \\        names = frames.getAnimationNames();
        \\        loop = frames.getAnimationLoopMode("swing");
        \\        same = frames == sprite.sprite_frames;
        \\        path = frames.resource_path;
        \\        frames.addAnimation("blink");
        \\        frames.addFrameRegion("blink", null, 0, 0, 4, 4);
        \\    }
        \\    fn jump(self) {
        \\        const sprite = self.entity.get("AnimatedSprite2D");
        \\        sprite.frame = 1;
        \\        sprite.animation = "walk";
        \\        frame_after = sprite.frame;
        \\        sprite.playBackwards();
        \\    }
        \\}
    );
    const e = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite{}, AnimatedSprite2D{ .sprite_frames = strip }, script.Script.of(handle) });
    try steps(app, 6);
    const scripts = app.scripts.?;
    try testing.expectEqual(@as(usize, 0), scripts.failures);
    const module = scripts.moduleOf(handle).?;
    try testing.expectEqual(@as(i64, 1), scripts.vm.get(module, "finished").?.asInt());
    try testing.expect(scripts.vm.get(module, "same").?.asBool());
    try testing.expectEqualStrings("", scripts.vm.get(module, "path").?.as(flux.object.String).bytes());
    try testing.expectEqualStrings("pingpong", scripts.vm.get(module, "loop").?.as(flux.object.String).bytes());
    try testing.expectEqual(@as(usize, 4), scripts.vm.get(module, "names").?.as(flux.object.List).items.items.len);
    try testing.expectEqual(@as(i32, 1), app.sprite_frames.get(strip).?.getFrameCount("blink"));

    _ = try scripts.vm.callMethod(scripts.instanceOf(e).?, "jump", &.{});
    // Through the setter at once: another animation starts from its first frame.
    try testing.expectEqual(@as(i64, 0), scripts.vm.get(module, "frame_after").?.asInt());
    try testing.expect(of(app, e).isPlaying());
    _ = try app.step();
    try testing.expectEqual(@as(i32, 3), of(app, e).frame);
    try testing.expectEqual(@as(f32, -1), of(app, e).getPlayingSpeed());
}
