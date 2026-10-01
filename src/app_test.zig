// SPDX-License-Identifier: BSD-3-Clause

//! The app as a whole, headless: its loop and its stages, quitting, the background,
//! the commands between systems, flags, the project it opens and the backend it picks.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const Backend = App.Backend;
const Flags = App.Flags;
const Options = App.Options;
const Project = @import("project/Project.zig");
const backendsToTry = App.backendsToTry;
const components = @import("scene/components.zig");
const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const parseFlags = App.parseFlags;
const helpers = @import("test_helpers.zig");
const pressOf = helpers.pressOf;

fn spawnOne(app: *App) anyerror!void {
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(64, 64),
        components.Sprite.solid(.hex(0xFF0000), 32, 32),
    });
}

fn countFrames(app: *App) anyerror!void {
    const counted = struct {
        var frames: u32 = 0;
    };
    counted.frames += 1;
    if (counted.frames >= 3) app.quit();
}

test "a headless app runs its stages and draws" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 64,
        .height = 64,
        // Without this, or a system that calls `quit`, `run` never ends.
        .frames = 1,
    });
    defer app.destroy();

    try app.addSystem(.startup, "spawn one", spawnOne);
    try app.run();

    try testing.expectEqual(@as(usize, 1), app.world.count());
    // One sprite, one texture, one draw call.
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);
}

test "the frame count ends the loop" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 5 });
    defer app.destroy();

    try app.run();
    try testing.expectEqual(@as(u64, 5), app.time.frame);
}

test "quitting from a system ends the loop" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try app.addSystem(.update, "count frames", countFrames);
    try app.run();

    try testing.expect(!app.running);
    try testing.expectEqual(@as(u64, 3), app.time.frame);
}

test "the engine's flags are read by name, and a game's own sit beside them" {
    const engine = try parseFlags(Flags, &.{ "game", "--backend", "d3d11", "--frames", "300", "--capture", "shot.png" });
    try testing.expectEqual(Backend.d3d11, engine.backend.?);
    try testing.expectEqual(@as(u32, 300), engine.frames.?);
    try testing.expectEqualStrings("shot.png", engine.capture.?);
    try testing.expect(engine.width == null);

    // The engine's flags inside a game's own: both read, and `write_atlas`
    // is `--write-atlas`.
    const Mine = struct { app: Flags = .{}, write_atlas: ?[]const u8 = null };
    const mine = try parseFlags(Mine, &.{ "game", "--write-atlas", "atlas.png", "--width", "640" });
    try testing.expectEqualStrings("atlas.png", mine.write_atlas.?);
    try testing.expectEqual(@as(u32, 640), mine.app.width.?);
}

test "a flag that is wrong stops the program rather than being passed over" {
    try testing.expectError(error.UnknownFlag, parseFlags(Flags, &.{ "game", "--frame", "10" }));
    try testing.expectError(error.MissingValue, parseFlags(Flags, &.{ "game", "--frames" }));
    try testing.expectError(error.InvalidValue, parseFlags(Flags, &.{ "game", "--frames", "ten" }));
    try testing.expectError(error.InvalidValue, parseFlags(Flags, &.{ "game", "--backend", "metal" }));
}

test "flags override what they say and leave the rest, and a capture is reproducible" {
    const base: Options = .{ .width = 960, .height = 540, .frames = null };

    const sized = (Flags{ .width = 1280 }).apply(base);
    try testing.expectEqual(@as(u32, 1280), sized.width);
    try testing.expectEqual(@as(u32, 540), sized.height);
    try testing.expect(sized.frame_time == null);

    // A capture: a frame count to stop at, and a clock that is not the
    // machine's.
    const captured = (Flags{ .capture = "shot.png" }).apply(base);
    try testing.expectEqual(@as(u32, Flags.capture_frames), captured.frames.?);
    try testing.expect(captured.fixed_frame_time);

    // With a count of its own, that count.
    const counted = (Flags{ .capture = "shot.png", .frames = 7 }).apply(base);
    try testing.expectEqual(@as(u32, 7), counted.frames.?);
}

/// Escape pressed on the third frame, the way the platform would deliver it.
fn escapeOnThird(app: *App) anyerror!void {
    if (app.time.frame == 3) app.input.apply(pressOf(.escape));
}

test "a quit key ends the game after the frame it was pressed in" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 100, .quit_key = .escape });
    defer app.destroy();

    try app.addSystem(.input, "escape on third", escapeOnThird);
    try app.run();
    try testing.expectEqual(@as(u64, 3), app.time.frame);
}

test "a shortcut nobody asked for is not one" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 5 });
    defer app.destroy();

    try app.addSystem(.input, "escape on third", escapeOnThird);
    try app.run();
    try testing.expectEqual(@as(u64, 5), app.time.frame);
}

test "a stretch, the physics' steps and the game's version change as a game says, and a close is asked of it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 1280, .height = 720, .stretch = .{ .mode = .canvas, .width = 640, .height = 360 } });
    defer app.destroy();
    try testing.expectEqual(@as(u32, 1280), app.frame.width);

    // Twice as big: half the game shows.
    app.setStretchScale(2);
    try testing.expectEqual(@as(f32, 2), app.stretchScale());
    app.setStretchMode(.picture);
    try testing.expectEqual(@as(u32, 320), app.frame.width);
    app.setStretchScaleMode(.integer);
    app.setStretchAspect(.keep_width);
    try testing.expect(app.stretchMode() == .picture and app.stretchAspect() == .keep_width and app.stretchScaleMode() == .integer);

    app.setMaxPhysicsStepsPerFrame(3);
    try testing.expectEqual(@as(u32, 3), app.maxPhysicsStepsPerFrame());
    app.setPhysicsTicksPerSecond(120);
    try testing.expectEqual(@as(u32, 120), app.physicsTicksPerSecond());
    try testing.expectEqualStrings("", app.gameVersion());

    try testing.expect(!app.closeRequested());
    app.close_frame = app.time.frame;
    try testing.expect(app.closeRequested());
    try testing.expectEqual(Backend.none, app.backendInUse());
    try testing.expectEqual(Project.Renderer.compatibility, app.rendererInUse());
}

const Nap = struct {
    fn run(_: *App) anyerror!void {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
};

test "each system's time over the last frame is kept under its name" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 2, .io = testing.io });
    defer app.destroy();
    try app.addSystem(.update, "nap", Nap.run);
    try app.run();

    const nap = app.schedule.systemsIn(.update)[0];
    try testing.expectEqualStrings("nap", nap.name);
    try testing.expect(nap.time_last_frame.nanoseconds >= std.time.ns_per_ms / 2);
}

test "a frame cap slows the loop down to it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 6, .io = testing.io });
    defer app.destroy();
    app.time.max_fps = 100;

    try app.run();
    try testing.expect(app.time.elapsed >= 0.03);
}

test "what a system asks of the commands is done before the next system runs" {
    const Seen = struct {
        var by_itself: usize = 99;
        var by_the_next: usize = 99;

        fn spawnTwo(a: *App) anyerror!void {
            _ = try a.commands.spawn(.{components.Transform2D.at(1, 2)});
            _ = try a.commands.spawn(.{components.Transform2D.at(3, 4)});
            by_itself = try ecs.Query(.{components.Transform2D}).count(&a.world);
        }

        fn count(a: *App) anyerror!void {
            by_the_next = try ecs.Query(.{components.Transform2D}).count(&a.world);
        }
    };

    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.addSystem(.update, "spawn", Seen.spawnTwo);
    try app.addSystem(.update, "count", Seen.count);
    try app.run();
    try testing.expectEqual(@as(usize, 0), Seen.by_itself);
    try testing.expectEqual(@as(usize, 2), Seen.by_the_next);
}

test "a system that fails leaves nothing of what it asked the commands for" {
    const Failing = struct {
        fn run(a: *App) anyerror!void {
            _ = try a.commands.spawn(.{components.Transform2D.at(1, 2)});
            return error.Deliberate;
        }
    };
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.addSystem(.update, "fail", Failing.run);
    try testing.expectError(error.Deliberate, app.run());
    try testing.expectEqual(@as(usize, 0), app.commands.count());
    try testing.expectEqual(@as(usize, 0), try ecs.Query(.{components.Transform2D}).count(&app.world));
}

test "commands asked for between frames are done at the top of the next" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const e = try app.commands.spawn(.{components.Transform2D.at(5, 6)});
    try testing.expect(app.world.get(e, components.Transform2D) == null);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 5), app.world.get(e, components.Transform2D).?.x);

    try app.commands.despawn(e);
    app.clearWorld();
    try testing.expectEqual(@as(usize, 0), app.commands.count());
}

test "with no window the clipboard is the program's own, and the game and the interface share it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try testing.expect(app.clipboard.system == null);
    try testing.expect(!app.hasClipboardText());

    try app.setClipboardText("level 3");
    try testing.expect(app.hasClipboardText());
    try testing.expectEqualStrings("level 3", try app.clipboardText());
    try testing.expectError(error.Unavailable, app.setClipboardText("\xc3"));
}

test "the project's root is an option and a flag, and one that is not there stops the start" {
    const flags = try App.parseFlags(App.Flags, &.{ "game", "--root", "games/pong" });
    try testing.expectEqualStrings("games/pong", flags.apply(.{}).root.?);
    try testing.expectError(error.FileNotFound, App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = "no/such/project" }));
}

test "a project file that is wrong stops the start, and says what and where" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = Project.file_name, .data = "{ \"fluxion_project\": 9, \"application\": { \"name\": \"Later\" } }" });

    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.UnsupportedVersion, App.create(testing.allocator, .{
        .headless = true,
        .io = testing.io,
        .root = root,
        .project_diagnostics = &diagnostics,
    }));
    try testing.expectEqualStrings("this project file is version 9, written for a newer Fluxion; this one reads version 2", diagnostics.message());
    try testing.expect(std.mem.endsWith(u8, diagnostics.file(), Project.file_name));

    // A value of the wrong kind, at its line.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = Project.file_name, .data = "{ \"fluxion_project\": 2,\n  \"application\": { \"name\": \"Wide\" },\n  \"display\": { \"width\": \"wide\" } }" });
    try testing.expectError(error.WrongType, App.create(testing.allocator, .{
        .headless = true,
        .io = testing.io,
        .root = root,
        .project_diagnostics = &diagnostics,
    }));
    try testing.expectEqual(@as(u32, 3), diagnostics.line);
}

fn expectBackends(wanted: Backend, rendering: Project.Rendering, os: std.Target.Os.Tag, expected: []const Backend) !void {
    var buffer: [Project.Rendering.max_backends]Backend = undefined;
    try testing.expectEqualSlices(Backend, expected, backendsToTry(wanted, rendering, os, &buffer));
}

test "auto opens the best of the project's renderer and falls back through the rest, and a backend asked for is the only one" {
    try expectBackends(.auto, .{}, .windows, &.{ .d3d11, .gl });
    try expectBackends(.auto, .{}, .linux, &.{.gl});
    try expectBackends(.auto, .{}, .macos, &.{.gl});
    try expectBackends(.auto, .{}, .emscripten, &.{.webgl});
    try expectBackends(.gl, .{}, .windows, &.{.gl});

    // The modern renderer: Direct3D 12 first on Windows, Vulkan elsewhere,
    // and where none of it opens, the compatibility renderer.
    try expectBackends(.auto, .{ .renderer = .modern }, .windows, &.{ .d3d12, .vulkan, .d3d11, .gl });
    try expectBackends(.auto, .{ .renderer = .modern }, .linux, &.{ .vulkan, .gl });
    try testing.expect(Backend.vulkan.experimental() and !Backend.d3d11.experimental());

    // A backend chosen within its renderer comes first; with no falling
    // back, it is the only one.
    try expectBackends(.auto, .{ .renderer = .modern, .modern_backend = .vulkan }, .windows, &.{ .vulkan, .d3d12, .d3d11, .gl });
    try expectBackends(.auto, .{ .compatibility_backend = .gl, .fall_back = false }, .windows, &.{.gl});
    try expectBackends(.auto, .{ .renderer = .modern, .fall_back = false, .fall_back_to_compatibility = false }, .windows, &.{.d3d12});
    // One the system has not got is the renderer's best.
    try expectBackends(.auto, .{ .compatibility_backend = .d3d11 }, .linux, &.{.gl});

    // None here, and no falling back to the other renderer: refused, not
    // drawn with something else - unless asked for.
    try expectBackends(.auto, .{ .renderer = .modern, .fall_back_to_compatibility = false }, .macos, &.{});
    try expectBackends(.auto, .{ .renderer = .modern }, .macos, &.{.gl});
    try expectBackends(.d3d11, .{ .renderer = .modern }, .windows, &.{.d3d11});

    const flags = try App.parseFlags(App.Flags, &.{ "game", "--backend", "gl" });
    try testing.expectEqual(Backend.gl, flags.apply(.{}).backend);
    const vulkan = try App.parseFlags(App.Flags, &.{ "game", "--backend", "vulkan" });
    try testing.expectEqual(Backend.vulkan, vulkan.apply(.{}).backend);
}

test "a program in the background runs no systems until it is back, but for the frame it left in" {
    const Count = struct {
        var runs: usize = 0;
        var left: usize = 0;
        var back: usize = 0;

        fn look(a: *App) anyerror!void {
            runs += 1;
            if (a.input.justSuspended()) left += 1;
            if (a.input.justResumed()) back += 1;
        }
    };
    Count.runs = 0;
    Count.left = 0;
    Count.back = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Count.look);

    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Count.runs);

    // Told between frames, as the next pump would tell it.
    app.input.apply(.suspended);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), Count.runs);
    try testing.expectEqual(@as(usize, 1), Count.left);

    for (0..3) |_| try testing.expect(try app.step());
    try testing.expectEqual(@as(usize, 2), Count.runs);

    app.input.apply(.resumed);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 3), Count.runs);
    try testing.expectEqual(@as(usize, 1), Count.back);
}

test "the time a program spent in the background is not a frame" {
    // The clock, not a fixed frame, so time away can be measured.
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = try app.step();

    app.input.apply(.suspended);
    _ = try app.step();
    _ = try app.step();

    // Away for ever, as far as the clock can tell, and back.
    app.time.last = .zero;
    app.input.apply(.resumed);
    _ = try app.step();
    try testing.expectEqual(@as(f32, 0), app.time.unscaled_delta);
}

test "memory running low is told to the systems of one frame" {
    const Seen = struct {
        var low: usize = 0;

        fn look(a: *App) anyerror!void {
            if (a.input.lowMemory()) low += 1;
        }
    };
    Seen.low = 0;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "look", Seen.look);

    app.input.apply(.low_memory);
    _ = try app.step();
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), Seen.low);
}

test "the game's chance is the same from the same seed, and keeps to the ranges it is given" {
    const app = try App.create(testing.allocator, .{ .headless = true, .random_seed = 7 });
    defer app.destroy();
    var first: [8]i64 = undefined;
    for (&first) |*n| n.* = app.randomInt(1, 6);
    app.seedRandom(7);
    for (first) |n| try testing.expectEqual(n, app.randomInt(6, 1));
    for (0..200) |_| {
        const x = app.randomRange(-2, 3);
        try testing.expect(x >= -2 and x < 3);
        const i = app.randomIndex(4);
        try testing.expect(i >= 0 and i < 4);
        const f = app.randomFloat();
        try testing.expect(f >= 0 and f < 1);
    }
    try testing.expectEqual(@as(i64, 0), app.randomIndex(0));
    try testing.expect(!app.randomChance(0));
    try testing.expect(app.randomChance(1));
}
