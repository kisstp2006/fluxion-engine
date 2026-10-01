// SPDX-License-Identifier: BSD-3-Clause

//! A window of the program's beside its main one, with an interface of its
//! own: an editor's panel torn off into a window of its own, a game's debug
//! view on a second monitor.
//!
//! It draws with the main window's device - on OpenGL, in a context of its
//! own that shares the main one's textures, buffers and shaders - and in the
//! main interface's fonts, so a style's font index means the same in both.
//! Its own are an `Input`, fed with this window's events and no other's, a
//! `ui`, and a renderer for that `ui`. The program lays its interface out
//! each frame through `draw`, after the `.ui` systems have laid out the main
//! window's; the window says when its close button was pressed, and the
//! program closes it or keeps it.
//!
//! ```zig
//! const tool = try app.openToolWindow(.{ .title = "Code", .width = 900, .height = 700 });
//! tool.draw = .{ .context = editor, .run = drawCode };
//! // each frame, somewhere:
//! if (tool.close_pressed) app.closeToolWindow(tool);
//! ```
//!
//! Without a window - headless - it is drawn into a texture of its size, and
//! a test hands its `input` events itself.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");
const ui_lib = @import("fluxion_ui");

const App = @import("../App.zig");
const Input = @import("../input/input.zig");
const Window = @import("../platform/window.zig");
const Interface = @import("interface.zig");

const ToolWindow = @This();

pub const Desc = struct {
    title: []const u8 = "fluxion",
    width: u32 = 800,
    height: u32 = 600,
    resizable: bool = true,
    visible: bool = true,
};

/// What lays the window's interface out each frame, inside a root that
/// fills it: `tool.ui` is where it goes.
pub const Draw = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, tool: *ToolWindow) anyerror!void,
};

/// The platform's window; null without one, when it is drawn into
/// `offscreen`.
handle: ?platform.Window,
surface: ?rhi.Surface = null,
offscreen: ?rhi.Texture = null,
input: Input = .{},
ui: ui_lib.Ui,
/// Its scale, its renderer, the textures its images name - `textures` is
/// the program's to set - and this frame's commands. Its fonts are the main
/// interface's.
interface: Interface = .{},
draw: ?Draw = null,
/// Filled behind the interface.
clear_color: [4]f32 = .{ 0.11, 0.12, 0.14, 1 },

/// The drawable size in pixels, and whether it changed since the device's
/// surface was told.
width: u32,
height: u32,
resized: bool = false,
/// Pixels per logical unit of the display it is on.
content_scale: f32 = 1,
focused: bool = true,
/// Its close button, or Alt+F4, since the program last took it: the window
/// stays until `App.closeToolWindow`.
close_pressed: bool = false,
/// The pointer's shape it was last given.
cursor_shown: ?platform.CursorShape = null,

/// Take one of this window's events: into its input, and into what the
/// window keeps of itself.
pub fn take(self: *ToolWindow, ev: platform.Event) void {
    self.input.apply(ev);
    switch (ev) {
        .close => self.close_pressed = true,
        .focus => |change| self.focused = change.value,
        .scale => |to| self.content_scale = to.x,
        .framebuffer_resize => |size| {
            if (size.width == self.width and size.height == self.height) return;
            self.width = size.width;
            self.height = size.height;
            self.resized = true;
        },
        else => {},
    }
}

/// What it draws into this frame.
pub fn target(self: *const ToolWindow) rhi.RenderTarget {
    if (self.surface) |surface| return .{ .surface = surface };
    return .{ .texture = self.offscreen.? };
}

/// Show `shape` over it, told only of a change.
pub fn showCursor(self: *ToolWindow, shape: platform.CursorShape) void {
    const handle = self.handle orelse return;
    if (self.cursor_shown == shape) return;
    self.cursor_shown = shape;
    handle.setCursorShape(shape) catch {};
}

/// What a backend that makes its surface from the window asks of it: a
/// Vulkan surface, or - on OpenGL - its own context, which shares the
/// device's. `self` is on the heap, so it stays where the hooks point.
pub fn surfaceHooks(self: *ToolWindow, gl: bool) rhi.WindowHooks {
    return .{
        .context = self,
        .make_vulkan_surface = makeVulkanSurface,
        .gl = if (gl) .{
            .make_current = makeCurrent,
            .swap_buffers = swapBuffers,
            .framebuffer_size = framebufferSize,
            .set_swap_interval = setSwapInterval,
        } else null,
    };
}

fn of(context: *anyopaque) *ToolWindow {
    return @ptrCast(@alignCast(context));
}

fn makeVulkanSurface(context: *anyopaque, instance: usize, get_instance_proc_addr: *const anyopaque) ?u64 {
    const handle = of(context).handle orelse return null;
    return handle.createVulkanSurface(instance, @ptrCast(@alignCast(get_instance_proc_addr)), null) catch null;
}

fn makeCurrent(context: *anyopaque) void {
    const handle = of(context).handle orelse return;
    handle.makeContextCurrent() catch {};
}

fn swapBuffers(context: *anyopaque) void {
    const handle = of(context).handle orelse return;
    handle.swapBuffers() catch {};
}

fn framebufferSize(context: *anyopaque) [2]u32 {
    const self = of(context);
    return .{ self.width, self.height };
}

fn setSwapInterval(context: *anyopaque, mode: rhi.PresentMode) void {
    const handle = of(context).handle orelse return;
    Window.applySwapInterval(handle, mode);
}

/// The interface's scale: the main one's zoom times this window's display,
/// while the main one follows its own.
pub fn fit(self: *ToolWindow, main: *const Interface) void {
    self.interface.zoom = main.zoom;
    self.interface.follow_display = main.follow_display;
    self.interface.display_scale = if (main.follow_display) self.content_scale else 1;
    self.interface.scale = main.zoom * self.interface.display_scale;
    self.interface.scroll_lines = main.scroll_lines;
}

/// Another window beside `app`'s own, put among its tool windows: see
/// `App.openToolWindow`.
pub fn open(app: *App, desc: Desc) !*ToolWindow {
    try app.tool_windows.ensureUnusedCapacity(app.gpa, 1);
    const tool = try app.gpa.create(ToolWindow);
    errdefer app.gpa.destroy(tool);
    tool.* = .{ .handle = null, .ui = .init(app.gpa), .width = desc.width, .height = desc.height };
    errdefer tool.deinit(app.gpa);
    try tool.input.actions.reset(app.gpa, &.{});

    if (app.window) |*window| {
        const handle = try window.openBeside(.{
            .title = desc.title,
            .width = desc.width,
            .height = desc.height,
            .resizable = desc.resizable,
        });
        errdefer handle.destroy();
        tool.handle = handle;
        const size = handle.framebufferSize();
        tool.width = @max(size[0], 1);
        tool.height = @max(size[1], 1);
        tool.content_scale = handle.contentScale()[0];
        tool.focused = handle.isFocused();
        // Two windows waiting for the display each frame would wait twice.
        tool.surface = try app.device.createSurface(.{
            .native_window = handle.native(),
            .window = tool.surfaceHooks(window.has_gl_context),
            .width = tool.width,
            .height = tool.height,
            .present_mode = .disabled,
        });
    } else {
        tool.offscreen = try app.device.createTexture(.{
            .width = tool.width,
            .height = tool.height,
            .usage = .{ .sampled = true, .render_target = true },
            .clear_color = tool.clear_color,
            .label = "tool window",
        });
    }
    tool.fit(&app.interface);
    app.tool_windows.appendAssumeCapacity(tool);
    return tool;
}

/// Close it: out of `app`'s tool windows, and everything it had let go of.
pub fn close(self: *ToolWindow, app: *App) void {
    for (app.tool_windows.items, 0..) |held, i| if (held == self) {
        _ = app.tool_windows.orderedRemove(i);
        break;
    };
    self.destroy(app);
}

/// Let go of everything it has, and of it, whether it is among `app`'s
/// tool windows or no longer.
pub fn destroy(self: *ToolWindow, app: *App) void {
    if (self.surface) |surface| app.device.destroySurface(surface);
    if (self.offscreen) |texture| app.device.destroyTexture(texture);
    self.deinit(app.gpa);
    if (self.handle) |handle| handle.destroy();
    app.gpa.destroy(self);
}

/// An event about a window other than `context`'s own - an `App` - handed
/// to the tool window it is about.
pub fn route(context: *anyopaque, ev: platform.Event) void {
    const app: *App = @ptrCast(@alignCast(context));
    const about = ev.window();
    for (app.tool_windows.items) |tool| {
        const handle = tool.handle orelse continue;
        if (handle.id == about) return tool.take(ev);
    }
}

/// Its input into its interface, then its interface laid out by its `draw`,
/// in the main interface's fonts; its pointer's shape and text input told.
pub fn layOut(self: *ToolWindow, app: *App) !void {
    self.fit(&app.interface);
    if (app.interface.fillFaces(&app.assets).len != 0) self.ui.setMeasurer(Interface.measurer(&app.interface.faces));
    try self.interface.feed(app.gpa, &self.ui, &self.input, &app.clipboard, app.time.unscaled_delta);

    self.interface.commands = &.{};
    self.ui.begin(self.interface.surface(@floatFromInt(self.width), @floatFromInt(self.height)));
    {
        self.ui.open(.{ .width = .grow, .height = .grow });
        defer self.ui.close();
        if (self.draw) |draw| try draw.run(draw.context, self);
    }
    self.interface.commands = try self.ui.end();
    const handle = self.handle orelse return;
    self.showCursor(switch (self.ui.cursor()) {
        inline else => |named| @field(platform.CursorShape, @tagName(named)),
    });
    self.interface.applyTextInput(&self.ui, handle);
}

/// Its background, its interface over it, and shown.
pub fn render(self: *ToolWindow, app: *App) !void {
    if (self.width == 0 or self.height == 0) return;
    if (self.handle) |handle| if (handle.isIconified()) return;
    const into = self.target();
    const cmd = app.device.begin();
    try cmd.beginPass(.{ .color = .{ .target = into, .clear_color = self.clear_color } });
    try cmd.endPass();
    try app.device.submit();
    try self.interface.draw(app.gpa, &app.device, app.interface.fillFaces(&app.assets), into, @floatFromInt(self.width), @floatFromInt(self.height));
    if (self.surface) |surface| try app.device.present(surface);
}

/// Let go of what it holds; the platform's window and the device's
/// surface are `App`'s to let go of.
pub fn deinit(self: *ToolWindow, gpa: Allocator) void {
    self.interface.deinit();
    self.ui.deinit();
    self.input.deinit(gpa);
}
