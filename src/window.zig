// SPDX-License-Identifier: BSD-3-Clause

//! The window and the event queue.
//!
//! fluxion-platform opens the window and queues the events; this adds one
//! `pump` that drains the queue into `Input`, tracks the framebuffer size,
//! and says whether the game should carry on.
//!
//! ```zig
//! var window: Window = undefined;
//! try window.open(gpa, .{ .title = "game" });
//! ```
//!
//! Opened in place rather than returned, because the platform window holds a
//! pointer to the `Context` inside this struct, and a copy would leave it
//! pointing at the old one. `App` is on the heap for the same reason.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");

const Input = @import("input.zig");
const dialog = @import("dialog.zig");

const Window = @This();
const log = std.log.scoped(.fluxion_engine);

pub const Error = platform.Error;

/// How the window fills the screen - always on the monitor it is on.
pub const Fullscreen = union(enum) {
    /// A window, at the size and in the place it had before.
    windowed,
    /// The whole monitor at the resolution it already has. What a game should
    /// use: alt-tab is instant and nothing else on the desktop moves.
    borderless,
    /// The whole monitor, switched to this mode. Slower, and it rearranges
    /// the desktop; worth it only when the resolution is the point. A refresh
    /// rate of zero lets the display pick.
    exclusive: platform.VideoMode,
};

/// Where the pointer may go, and whether it shows. The platform's `captured`
/// is `confined` here, and its `disabled` is `locked`.
pub const Cursor = enum {
    /// The ordinary arrow, free to leave the window.
    normal,
    /// Invisible over the window, otherwise free: for a game that draws its
    /// own pointer.
    hidden,
    /// Visible, and held inside the window: edge scrolling in a window.
    confined,
    /// Invisible and held, reporting movement with no edge to stop at: a
    /// first-person camera, or a drag further than the screen is wide.
    /// `Input.pointer` holds still and only `dx` and `dy` move.
    locked,

    /// Whether this mode keeps the pointer inside the window - and so lets go
    /// of it while the window is without the keyboard, which the platform
    /// sees to.
    pub fn holds(self: Cursor) bool {
        return self == .confined or self == .locked;
    }

    fn platformMode(self: Cursor) platform.CursorMode {
        return switch (self) {
            .normal => .normal,
            .hidden => .hidden,
            .confined => .captured,
            .locked => .disabled,
        };
    }
};

/// Whether a window is at its own size, maximised, or minimised.
pub const State = enum {
    normal,
    /// Filling the monitor's work area, frame included.
    maximized,
    /// In the taskbar. `App.width` and `height` hold at the last real size -
    /// the platform reports no other - because a swapchain of nought by
    /// nought is an error on every backend.
    minimized,
};

/// How small and how large the player may drag the window, in pixels. Zero on
/// an edge is no limit there.
pub const SizeLimits = platform.backend.SizeLimits;

pub const Desc = struct {
    title: []const u8 = "fluxion",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
    /// Open maximised. Only a resizable window can be.
    maximized: bool = false,
    /// Ask for an OpenGL context. Only the `gl` backend needs one.
    gl: bool = true,
    /// Wait for the display before showing a frame.
    vsync: bool = true,
};

ctx: platform.Context,
handle: platform.Window,

/// The drawable size in pixels - on a HiDPI display, not the window's size.
width: u32,
height: u32,

/// Whether the framebuffer changed size since `App` last read this.
resized: bool = false,

/// Set by the close button, by Alt+F4, and by `requestClose`.
closing: bool = false,

/// What the game asked the pointer to do.
cursor_wanted: Cursor = .normal,

/// Whether the window has the keyboard. Asked of the platform at `open`,
/// because Windows gives a new window the keyboard only if its program had
/// it.
focused: bool = true,

/// Pixels per logical unit of the display the window is on: 1 on an
/// ordinary one, 1.5 or 2 on a HiDPI one. Asked at `open`, and told again
/// whenever the window moves to a monitor with another. What
/// `Interface.display_scale` follows.
content_scale: f32 = 1,

has_gl_context: bool = false,

/// Open a window at this address.
pub fn open(self: *Window, gpa: Allocator, desc: Desc) Error!void {
    self.* = .{
        .ctx = try .init(gpa, .{}),
        // Filled in below: the context has to be at its final address first.
        .handle = undefined,
        .width = desc.width,
        .height = desc.height,
        .has_gl_context = desc.gl,
    };
    errdefer self.ctx.deinit();

    self.handle = try self.ctx.createWindow(.{
        .title = desc.title,
        .width = desc.width,
        .height = desc.height,
        .resizable = desc.resizable,
        .maximized = desc.maximized,
        .gl = if (desc.gl) .{ .major = 3, .minor = 3, .profile = .core } else null,
    });
    errdefer self.handle.destroy();

    if (desc.gl) {
        try self.handle.makeContextCurrent();
        // Not fatal: a driver that refuses draws at a rate of its own.
        self.setVsync(desc.vsync) catch |err| {
            log.warn("could not set the swap interval: {t}", .{err});
        };
    }

    const fb = self.handle.framebufferSize();
    self.width = fb[0];
    self.height = fb[1];
    self.focused = self.handle.isFocused();
    self.content_scale = self.handle.contentScale()[0];
}

pub fn close(self: *Window) void {
    // An exclusive display mode and a held pointer belong to the whole
    // machine: the platform puts both back as the window goes.
    self.handle.destroy();
    self.ctx.deinit();
    self.* = undefined;
}

/// Where the pointer may go, and whether it shows. A mode that holds the
/// pointer holds it only while the window has the keyboard, as GLFW's does:
/// the platform lets go when an alt-tab takes the focus, and takes the
/// pointer back when it returns. Asked for from the background, it waits.
pub fn setCursor(self: *Window, wanted: Cursor) Error!void {
    // Raw motion matters only while locked, and the platform switches it with
    // the mode. Where there is none, locking works on accelerated numbers.
    if (wanted == .locked) _ = self.handle.setRawMouseMotion(true);

    try self.handle.setCursorMode(wanted.platformMode());
    self.cursor_wanted = wanted;
}

/// What the game asked the pointer to do.
pub fn cursor(self: *const Window) Cursor {
    return self.cursor_wanted;
}

pub fn setVsync(self: *Window, on: bool) Error!void {
    if (self.has_gl_context) try self.handle.setSwapInterval(if (on) .vsync else .immediate);
}

/// Use one of the system's own pointer shapes over this window.
/// `error.Unavailable` for a shape this system has not got.
pub fn setCursorShape(self: *Window, shape: platform.CursorShape) Error!void {
    try self.handle.setCursorShape(shape);
}

/// Let an input method sit between the keys and the text, and raise the
/// soft keyboard on a phone or a page: on while something is being typed
/// into, and off otherwise. See `Interface.applyTextInput`.
pub fn setTextInput(self: *Window, on: bool) Error!void {
    try self.handle.setTextInput(on);
}

/// Whether text input is on.
pub fn textInput(self: *const Window) bool {
    return self.handle.textInput();
}

/// Where the caret is, in the framebuffer's pixels as the pointer is, so an
/// input method puts its composition there and its candidates clear of it.
pub fn setTextInputArea(self: *Window, area: platform.text.Area) Error!void {
    try self.handle.setTextInputArea(area);
}

/// How many lines the user has the system scroll text by for a notch of the
/// wheel - or a page. Asked each time, so a changed setting is taken at once.
pub fn scrollLines(self: *Window) platform.ScrollLines {
    return self.ctx.scrollLines();
}

/// Open the system's file dialog, in front of this window and modal to it.
/// The answer comes through `pump`. See `dialog`.
pub fn openFileDialog(self: *Window, options: dialog.FileOptions) Error!dialog.Id {
    if (comptime dialog.available) {
        const id = try self.ctx.openFileDialog(.{
            .window = self.handle,
            .title = options.title,
            .multiple = options.multiple,
            .filters = options.filters,
            .initial_folder = options.initial_folder,
        });
        return @enumFromInt(@intFromEnum(id));
    } else return error.Unavailable;
}

/// Open the system's folder dialog, as `openFileDialog` does a file one.
pub fn openFolderDialog(self: *Window, options: dialog.FolderOptions) Error!dialog.Id {
    if (comptime dialog.available) {
        const id = try self.ctx.openFolderDialog(.{
            .window = self.handle,
            .title = options.title,
            .initial_folder = options.initial_folder,
        });
        return @enumFromInt(@intFromEnum(id));
    } else return error.Unavailable;
}

/// Fill the monitor the window is on, or go back to being a window. The size
/// is read back at once, so `App.create` makes its swapchain at the right
/// size.
pub fn setFullscreen(self: *Window, wanted: Fullscreen) Error!void {
    const request: platform.Fullscreen = switch (wanted) {
        .windowed => .windowed,
        .borderless => .{ .borderless = self.handle.monitor() orelse return error.Unavailable },
        .exclusive => |mode| .{ .exclusive = .{
            .monitor = self.handle.monitor() orelse return error.Unavailable,
            .mode = mode,
        } },
    };
    try self.handle.setFullscreen(request);
    self.refreshSize();
}

/// How the window fills the screen now.
pub fn fullscreen(self: *const Window) Fullscreen {
    return switch (self.handle.fullscreen()) {
        .windowed => .windowed,
        .borderless => .borderless,
        .exclusive => |it| .{ .exclusive = it.mode },
    };
}

/// What the title bar says.
pub fn setTitle(self: *Window, title: []const u8) Error!void {
    try self.handle.setTitle(title);
}

/// Make the content area this size, in pixels. A fullscreen, maximised or
/// minimised window is made an ordinary one first.
pub fn setSize(self: *Window, width: u32, height: u32) Error!void {
    try self.makeOrdinary();
    try self.handle.setSize(width, height);
    self.refreshSize();
}

/// Put the top left of the content area at this point of the desktop. An
/// ordinary window first, as with `setSize`.
pub fn setPosition(self: *Window, x: i32, y: i32) Error!void {
    try self.makeOrdinary();
    try self.handle.setPosition(x, y);
}

/// Where the top left of the content area is on the desktop. Always nought,
/// nought on Wayland, which does not say.
pub fn position(self: *const Window) [2]i32 {
    return self.handle.position();
}

/// How small and how large the player may drag the window. A window already
/// outside them is brought inside at once, and its size read back; one that
/// is maximised, minimised or fullscreen is sized by its monitor, and meets
/// the limits when it is a window again.
pub fn setSizeLimits(self: *Window, limits: SizeLimits) Error!void {
    try self.handle.setSizeLimits(limits);
    self.refreshSize();
}

/// Maximise the window, minimise it, or put it back. Maximising leaves
/// fullscreen first; a fullscreen game minimised comes back fullscreen.
pub fn setState(self: *Window, wanted: State) Error!void {
    if (self.state() == wanted) return;
    switch (wanted) {
        .minimized => try self.handle.iconify(),
        .maximized => {
            if (self.fullscreen() != .windowed) try self.setFullscreen(.windowed);
            try self.handle.maximize();
        },
        .normal => try self.handle.restore(),
    }
    self.refreshSize();
}

/// Whether the window is at its own size, maximised, or minimised.
pub fn state(self: *const Window) State {
    if (self.handle.isIconified()) return .minimized;
    if (self.handle.isMaximized()) return .maximized;
    return .normal;
}

/// Not fullscreen, maximised or minimised: the only kind of window with a
/// size and a place of its own to be given.
fn makeOrdinary(self: *Window) Error!void {
    if (self.fullscreen() != .windowed) try self.setFullscreen(.windowed);
    // One step from minimised or maximised, even minimised from maximised.
    if (self.state() != .normal) try self.handle.restore();
}

/// Read the drawable size back, and flag a resize if it moved, as `pump`
/// does. A minimised window keeps its last real size.
fn refreshSize(self: *Window) void {
    const fb = self.handle.framebufferSize();
    if (fb[0] == self.width and fb[1] == self.height) return;
    self.width = fb[0];
    self.height = fb[1];
    self.resized = true;
}

/// Whether an error means this machine has no display, rather than a bug. A
/// build server that gets one should carry on headless.
pub fn isAbsent(err: anyerror) bool {
    return switch (err) {
        error.Unsupported,
        error.NoDisplay,
        error.ConnectionFailed,
        error.WindowCreationFailed,
        error.Unavailable,
        => true,
        else => false,
    };
}

/// Drain the queue into `input`, and say whether the game should carry on.
pub fn pump(self: *Window, input: *Input) bool {
    self.ctx.pump() catch |err| {
        log.err("the event loop failed: {t}", .{err});
        return false;
    };

    // The platform polled the controllers inside that pump, so a connection
    // and the state it announces arrive in the same frame.
    input.readPads(self.ctx.gamepads());

    while (self.ctx.poll()) |ev| {
        // Only this window's events, and those about no window in particular:
        // a tool window a game opens must not feed the game's input.
        const about = ev.window();
        if (about != .none and about != self.handle.id) continue;

        input.apply(ev);
        switch (ev) {
            .close => self.closing = true,
            .focus => |change| self.focused = change.value,
            .scale => |to| self.content_scale = to.x,
            .framebuffer_resize => |size| {
                // Never nought by nought: a minimised window keeps its last
                // real size.
                if (size.width == self.width and size.height == self.height) continue;
                self.width = size.width;
                self.height = size.height;
                self.resized = true;
            },
            else => {},
        }
    }

    return !self.closing and !self.handle.shouldClose();
}

/// Ask for the loop to end after this frame.
pub fn requestClose(self: *Window) void {
    self.closing = true;
    self.handle.setShouldClose(true);
}

/// Show the frame that was just drawn. OpenGL only; Direct3D presents through
/// the surface.
pub fn swap(self: *Window) void {
    self.handle.swapBuffers() catch |err| {
        log.err("could not swap buffers: {t}", .{err});
    };
}

/// The platform's own handle - an `HWND` on Windows - that the Direct3D
/// backend makes a swapchain from.
pub fn nativeHandle(self: *const Window) usize {
    return self.handle.native();
}

/// What the OpenGL backend needs from whoever made the context. `context` is
/// this struct, so its address has to outlive the device.
pub fn hooks(self: *Window) rhi.GlHooks {
    return .{
        .context = self,
        .get_proc_address = getProcAddress,
        .swap_buffers = swapBuffers,
        .framebuffer_size = framebufferSize,
    };
}

fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.types.GlProc {
    const self: *Window = @ptrCast(@alignCast(context));
    return self.handle.getProcAddress(name);
}

fn swapBuffers(context: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(context));
    self.swap();
}

fn framebufferSize(context: *anyopaque) [2]u32 {
    const self: *Window = @ptrCast(@alignCast(context));
    return .{ self.width, self.height };
}
