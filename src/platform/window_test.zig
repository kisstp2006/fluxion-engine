// SPDX-License-Identifier: BSD-3-Clause

//! The window through a whole app, headless: what it says with no display, the
//! pointer's shape, the size and the vsync mode.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const CursorShape = platform.CursorShape;
const VsyncMode = Window.VsyncMode;
const WindowMode = Window.Mode;
const components = @import("../scene/components.zig");
const control = @import("../ui/control.zig");
const ecs = @import("fluxion_ecs");
const image = @import("fluxion_image");
const platform = @import("fluxion_platform");
const Window = @import("window.zig");

test "a headless app has no screen to fill, and says so without failing" {
    const app = try App.create(testing.allocator, .{ .headless = true, .window_mode = .fullscreen, .borderless = true, .always_on_top = true });
    defer app.destroy();

    try testing.expect(app.windowMode() == .windowed);
    for (std.enums.values(WindowMode)) |mode| try app.setWindowMode(mode);
    try app.toggleFullscreen();
    try testing.expect(app.windowMode() == .windowed);
    try app.setWindowBorderless(true);
    try app.setWindowResizable(false);
    try app.setWindowAlwaysOnTop(true);
    try app.setKeepScreenOn(false);
    try testing.expect(!app.windowBorderless() and !app.windowResizable() and !app.windowAlwaysOnTop() and !app.keepScreenOn());
    // No screens to be on, and nothing to say of one.
    try testing.expectEqual(@as(u32, 0), app.screenCount());
    try testing.expect(app.windowScreen() == null and app.primaryScreen() == null);
    try app.setWindowScreen(1);
    try app.centerWindow();
    try testing.expect(app.screenRect(0) == null and app.videoMode(0, 0) == null);
    try testing.expectEqual(@as(u32, 0), app.videoModeCount(0));
}

test "a headless app has no pointer to hold, and says so without failing" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    try app.setCursor(.locked);
    try testing.expect(app.cursor() == .normal);
    try testing.expect(!app.input.pointer.locked);
    app.setDefaultCursorShape(.crosshair);
    try testing.expectEqual(@as(usize, 0), try app.addGamepadMappings("not a mapping"));
}

fn pointerTo(x: f64, y: f64) platform.Event {
    return .{ .cursor = .{ .window = .none, .x = x, .y = y, .dx = 0, .dy = 0 } };
}

test "the pointer takes the shape its control asks for, the game's default elsewhere, and the picture the game gave it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100, .io = testing.io });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ control.Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, control.CanvasLayer{} });
    const button = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 60 }, .height = .{ .mode = .fixed, .value = 30 } },
        components.Parent.of(root),
        control.Button{},
    });
    const edge = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 60 }, .height = .{ .mode = .fixed, .value = 30 } },
        components.Parent.of(root),
        control.PanelContainer{},
        control.MouseCursor{ .shape = .resize_ew },
    });
    try app.startup();
    _ = try app.step();

    const Hover = struct {
        fn over(a: *App, entity: ecs.Entity) !CursorShape {
            const box = a.controlRect(entity).?;
            a.input.apply(pointerTo(box.position.x + box.size.x / 2, box.position.y + box.size.y / 2));
            _ = try a.step();
            return a.currentCursorShape();
        }
        fn away(a: *App) !CursorShape {
            a.input.apply(pointerTo(199, 99));
            _ = try a.step();
            return a.currentCursorShape();
        }
    };
    try testing.expectEqual(CursorShape.arrow, try Hover.away(app));
    try testing.expectEqual(CursorShape.pointing_hand, try Hover.over(app, button));
    try testing.expectEqual(CursorShape.resize_ew, try Hover.over(app, edge));

    // The game's default stands in for the arrow, and nowhere else.
    app.setDefaultCursorShape(.crosshair);
    try testing.expectEqual(CursorShape.crosshair, try Hover.away(app));
    try testing.expectEqual(CursorShape.pointing_hand, try Hover.over(app, button));

    // A control that lets the pointer through asks for nothing.
    app.world.get(edge, control.Control).?.mouse_filter = .ignore;
    try testing.expectEqual(CursorShape.crosshair, try Hover.over(app, edge));

    // A picture from a file, its point kept inside it; a picture too large
    // is refused and the one held stays.
    var name: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&name, ".zig-cache/tmp/{s}/sword.png", .{tmp.sub_path});
    const pixels = [_]u8{ 255, 0, 0, 255 } ** (4 * 4);
    try image.png.writeFile(testing.allocator, testing.io, path, .{ .width = 4, .height = 4, .pixels = &pixels, .row_pitch = 16 }, .{});
    try app.setCustomCursorFile(path, .pointing_hand, .init(9, 1));
    const held = app.cursors.custom[@intFromEnum(CursorShape.pointing_hand)].?;
    try testing.expectEqual(@as(u32, 4), held.width);
    try testing.expectEqual(@as(u32, 3), held.hot_x);
    try testing.expectEqual(@as(u32, 1), held.hot_y);

    const huge = try testing.allocator.alloc(u8, 257 * 1 * 4);
    defer testing.allocator.free(huge);
    try testing.expectError(error.CursorTooLarge, app.setCustomCursorPixels(.{ .pixels = huge, .width = 257, .height = 1 }, .pointing_hand));
    try testing.expectEqual(@as(u32, 4), app.cursors.custom[@intFromEnum(CursorShape.pointing_hand)].?.width);

    try app.setCustomCursorPixels(null, .pointing_hand);
    try testing.expect(app.cursors.custom[@intFromEnum(CursorShape.pointing_hand)] == null);
    try testing.expectError(error.FileNotFound, app.setCustomCursorFile("res://nowhere.png", .arrow, .init(0, 0)));
}

test "a headless app has no window to move, and says so without failing; a size is what it draws into" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 320,
        .height = 240,
        .resizable = false,
        .window_mode = .maximized,
    });
    defer app.destroy();

    try app.setWindowTitle("nobody reads this");
    try app.setWindowSize(800, 600);
    try app.setWindowPosition(10, 20);
    try app.setWindowSizeLimits(.{ .min_width = 640, .min_height = 480 });
    try app.setWindowMode(.maximized);

    try testing.expect(app.windowPosition() == null);
    try testing.expect(app.windowMode() == .windowed);
    // What it draws into took the size.
    try testing.expectEqual(@as(u32, 800), app.width);
    try testing.expectEqual(@as(u32, 600), app.height);
    try testing.expect(app.resized);
}

test "the vsync mode is remembered, even with no display to wait for" {
    const app = try App.create(testing.allocator, .{ .headless = true, .vsync_mode = .mailbox });
    defer app.destroy();

    try testing.expectEqual(VsyncMode.mailbox, app.vsyncMode());
    for (std.enums.values(VsyncMode)) |mode| {
        try app.setVsyncMode(mode);
        try testing.expectEqual(mode, app.vsyncMode());
    }
}
