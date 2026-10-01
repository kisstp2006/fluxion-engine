// SPDX-License-Identifier: BSD-3-Clause

//! The window, the device and what a frame is drawn into, opened for one
//! backend, and the window put where the project says before it shows.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const Window = @import("../platform/window.zig");
const Options = @import("options.zig").Options;
const Resolved = @import("options.zig").Resolved;
const Backend = @import("options.zig").Backend;
const log = std.log.scoped(.fluxion_engine);

/// The window, the device and what is drawn into, for one backend: the
/// window kept from a backend tried before where it does for this one, and
/// made again where it does not - no platform lets a window change its mind
/// about an OpenGL context. What this attempt made is undone where it fails.
pub fn open(app: *App, gpa: Allocator, options: Options, resolved: Resolved, backend: Backend) !void {
    const wants_gl = backend == .gl;
    if (app.window) |*w| if (w.has_gl_context != wants_gl) {
        w.close();
        app.window = null;
    };
    if (!options.headless and app.window == null) {
        // Opened in place: its handle points at the context beside it.
        app.window = @as(Window, undefined);
        app.window.?.open(gpa, .{
            .title = titleOf(options, app.project.settings),
            .width = resolved.width,
            .height = resolved.height,
            .resizable = resolved.resizable,
            .decorated = !resolved.borderless,
            // Shown once it is in its place, so it is never seen elsewhere.
            .visible = false,
            .gl = wants_gl,
            .present_mode = resolved.vsync_mode.present(),
        }) catch |err| {
            app.window = null;
            if (Window.isAbsent(err)) {
                log.info("no window could be opened: {t}", .{err});
                return error.NoDisplay;
            }
            return err;
        };
        app.clipboard.system = &app.window.?.ctx;
        if (resolved.min_size[0] > 0 or resolved.min_size[1] > 0) {
            app.window.?.setSizeLimits(.{ .min_width = resolved.min_size[0], .min_height = resolved.min_size[1] }) catch |err|
                log.warn("the window's least size could not be set: {t}", .{err});
        }
        // Before anything is sized from the window, so the swapchain is made
        // at its final size. None of it fatal: a game that cannot be put
        // where it asks still runs, and says why.
        placeWindow(&app.window.?, resolved);
    }

    const width = if (app.window) |*w| w.width else resolved.width;
    const height = if (app.window) |*w| w.height else resolved.height;
    app.width = width;
    app.height = height;
    // The surface is about to be made at this size, so the first frame has
    // nothing to resize; and the input starts out agreeing with the window
    // about the keyboard.
    if (app.window) |*w| {
        w.resized = false;
        app.input.focused = w.focused;
    }
    fitInterface(app);

    app.device = try .init(gpa, .{
        .backend = switch (backend) {
            .gl => .gl,
            .d3d11 => .d3d11,
            .d3d12 => .d3d12,
            .vulkan => .vulkan,
            .webgl => .webgl,
            .none => .none,
            .auto => .auto,
        },
        // Only OpenGL wants the context; Direct3D takes the window handle at
        // surface time instead.
        .gl = if (wants_gl and app.window != null) app.window.?.hooks() else null,
    });
    errdefer app.device.deinit();

    if (app.window) |*w| {
        // The window as it is, whichever backend draws into it: its handle,
        // and its hooks for a backend that makes its surface from it.
        app.surface = try app.device.createSurface(.{
            .native_window = w.nativeHandle(),
            .window = w.surfaceHooks(),
            .width = width,
            .height = height,
            // Told to the swapchain as well as the window: Direct3D keeps it
            // on the swapchain, OpenGL on the context.
            .present_mode = resolved.vsync_mode.present(),
        });
    } else {
        // No window, so the frame goes into a texture, through every draw
        // call the real path makes.
        app.offscreen = try app.device.createTexture(.{
            .width = width,
            .height = height,
            .usage = .{ .sampled = true, .render_target = true },
            .clear_color = resolved.background.array(),
            .label = "headless target",
        });
    }
    if (backend.experimental()) log.warn("drawing with {t} ({s}), which is experimental", .{ backend, app.device.info().renderer });
}

/// Put a window opened hidden where and how `resolved` says - its screen or
/// its point, its frame, its stacking, its mode - and show it. Whatever the
/// system will not do is said, and the rest done.
fn placeWindow(w: *Window, resolved: Resolved) void {
    const screens = w.screens();
    switch (resolved.initial_position) {
        .center_of_primary_screen => if (w.primaryScreen()) |primary| w.centerOn(primary) catch |err| log.info("the window could not be centred: {t}", .{err}),
        .center_of_screen => {
            const index: usize = if (resolved.screen < screens.len) resolved.screen else w.primaryScreen() orelse 0;
            if (resolved.screen >= screens.len) log.warn("there is no screen {d}: the window opens on the primary one", .{resolved.screen});
            w.centerOn(index) catch |err| log.info("the window could not be centred: {t}", .{err});
        },
        .absolute => w.setPosition(resolved.position.x, resolved.position.y) catch |err| log.info("the window could not be put at its position: {t}", .{err}),
    }
    if (resolved.always_on_top) w.setTopmost(true) catch |err| log.warn("the window cannot be kept on top here: {t}", .{err});
    // In its mode before it shows, so it never shows as a window first; a
    // system that takes no mode for a window not shown yet is asked again.
    const wanted = resolved.window_mode;
    if (wanted != .windowed) w.setMode(wanted) catch {};
    w.show();
    if (wanted != .windowed and w.mode() != wanted) w.setMode(wanted) catch |err| log.warn("the window could not open {t}: {t}", .{ wanted, err });
    w.setKeepAwake(resolved.keep_screen_on) catch |err| switch (err) {
        // A phone, a page and Wayland keep their screens as they will.
        error.Unavailable => {},
        else => log.warn("the screen could not be kept on: {t}", .{err}),
    };
}

/// What the title bar says: the game's own title, or else its project's
/// name, or else "fluxion".
pub fn titleOf(options: Options, settings: ?Project.Settings) []const u8 {
    if (options.title) |title| return title;
    if (settings) |held| {
        if (held.application.name.len > 0) return held.application.name;
    }
    return "fluxion";
}

/// This frame's size and place on the window, as the stretch says, and the
/// pointer's pixels turned into its. See `stretch.zig`.
pub fn fitFrame(app: *App) void {
    app.frame = app.stretch.frameOf(app.width, app.height);
    app.input.frame_origin = .init(app.frame.shown.x, app.frame.shown.y);
    app.input.frame_ratio = app.frame.ratio();
    // A density-independent pixel, in the frame's: the window's pixels in
    // one, and the frame's in each of those.
    const display_scale: f32 = if (app.window) |*window| window.content_scale else 1;
    app.input.dp = display_scale * app.input.frame_ratio;
}

/// The interface's scale for this frame: the game's `zoom` times the
/// display's, which it follows unless told not to - and 1 with no window.
/// A stretched game's is its frame's scale instead, which already counts
/// the window's pixels.
pub fn fitInterface(app: *App) void {
    const display_scale: f32 = if (app.window) |*window|
        (if (app.interface.follow_display) window.content_scale else 1)
    else
        1;
    app.interface.display_scale = display_scale;
    const outer: f32 = if (app.stretch.mode == .disabled) display_scale else app.frame.scale;
    app.interface.scale = app.interface.zoom * outer;
    if (app.interface.follow_safe_area) {
        const edges = app.safeArea();
        app.interface.safe_area = .{
            .left = cut(edges.left),
            .top = cut(edges.top),
            .right = cut(edges.right),
            .bottom = cut(edges.bottom),
        };
    }
}

/// A screen edge as the interface holds it: sixteen bits, which is wider
/// than any screen there is.
fn cut(edge: u32) u16 {
    return @intCast(@min(edge, std.math.maxInt(u16)));
}

/// Take a new size from the window: the numbers, the flag, and the swapchain.
pub fn adoptSize(app: *App, width: u32, height: u32) !void {
    app.width = width;
    app.height = height;
    fitFrame(app);
    app.resized = true;
    if (app.surface) |surface| try app.device.resizeSurface(surface, width, height);
}
