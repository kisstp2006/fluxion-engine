// SPDX-License-Identifier: BSD-3-Clause

//! The window, the event queue, and the two seams a device wants from them.
//!
//! Almost nothing here is engine code:
//! [Fluxion Platform](https://github.com/kisstp2006/fluxion-platform) opens
//! the window and queues the events, and what this file adds is the shape an
//! engine wants - one `pump` that drains the queue into `Input`, keeps the
//! framebuffer size up to date, and answers whether the game should carry on.
//!
//! **It is opened in place, not returned.**
//!
//! ```zig
//! var window: Window = undefined;
//! try window.open(gpa, .{ .title = "game" });
//! ```
//!
//! rather than `const window = try Window.open(...)`, and the reason is worth
//! knowing because it catches everyone once. A `platform.Window` is a handle
//! that holds `ctx: *Context`, and the `Context` is a field of this struct -
//! so the moment the struct is copied, that pointer aims at where the old
//! copy used to be. Zig moves a value on return, on assignment, and whenever
//! it likes; the only fix is for the address never to change, which means the
//! caller decides where it lives before anything inside it is set up. The
//! same argument is why `App` is created on the heap.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");

const Input = @import("input.zig");

const Window = @This();
const log = std.log.scoped(.fluxion_engine);

pub const Error = platform.Error;

/// How the window fills the screen.
///
/// `fluxion-platform`'s `Fullscreen` with one question taken out of it -
/// which monitor - because a game should not have to answer it. The answer
/// here is always the monitor the window is on: the one the player is
/// looking at, and the one they dragged it to if they have two. A game that
/// wants a particular monitor moves the window there first.
pub const Fullscreen = union(enum) {
    /// A window, at the size and in the place it had before.
    windowed,
    /// The whole monitor, at the resolution it already has. What a game
    /// should use: nothing about the display changes, so alt-tab is instant
    /// and nothing else on the desktop moves.
    borderless,
    /// The whole monitor, after switching it to this mode. Slower to go into
    /// and out of, and it rearranges every other window on the machine;
    /// worth it only when a different resolution really is the point. A
    /// refresh rate of zero keeps whichever the display picks.
    exclusive: platform.VideoMode,
};

/// Where the pointer may go, and whether it shows.
///
/// `fluxion-platform`'s cursor modes under the names a game uses for them -
/// its `captured` is `confined` here and its `disabled` is `locked` - because
/// "disabled" is what the pointer is and "locked" is what the game did to it.
pub const Cursor = enum {
    /// The ordinary arrow, free to leave the window. What a window starts
    /// with.
    normal,
    /// Invisible over the window, and otherwise free. For a game that draws
    /// its own pointer.
    hidden,
    /// Visible, and held inside the window. A strategy game that scrolls
    /// when the pointer touches an edge, in a window rather than fullscreen.
    confined,
    /// Gone: invisible, held, and reporting movement with no edge to stop
    /// at, unaccelerated where the system can manage it. What a first-person
    /// camera needs, and what makes dragging a map further than the screen
    /// is wide possible. `Input.pointer` holds still while it is locked and
    /// only its `dx` and `dy` move; see `Input.Pointer.locked`.
    locked,

    /// Does this mode keep the pointer inside the window? Those are the two
    /// that have to be let go when the window loses the keyboard.
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

/// Whether a window is at its own size, filling the screen's work area, or
/// down in the taskbar.
pub const State = enum {
    /// A window at its own size and place.
    normal,
    /// Filling the monitor's work area, frame and title bar included. Still
    /// a window, which is the difference from fullscreen.
    maximized,
    /// Down in the taskbar or the dock. `App.width` and `height` hold at the
    /// last real size while it is, because a swapchain of nought by nought is
    /// an error on every backend.
    minimized,
};

/// How small and how large the player may drag the window, in the units of
/// `Desc.width` and `height`. Zero on an edge is no limit there.
/// `fluxion-platform`'s own.
pub const SizeLimits = platform.backend.SizeLimits;

pub const Desc = struct {
    title: []const u8 = "fluxion",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
    /// Open maximised. Only a resizable window can be: one that cannot change
    /// size has no maximise button, and asking is quietly nothing.
    maximized: bool = false,
    /// Ask for an OpenGL context. Required by the `gl` backend and pointless
    /// to the Direct3D one, which makes its own device and takes the window
    /// handle at surface time instead.
    gl: bool = true,
    /// Wait for the display before showing a frame. On means no tearing and
    /// a frame rate the monitor decides; off means as fast as the machine
    /// can, which is what a profiler wants.
    vsync: bool = true,
};

ctx: platform.Context,
handle: platform.Window,

/// The drawable size in pixels, which on a HiDPI display is not the window
/// size. This is the one a swapchain, a viewport and a projection all want.
width: u32,
height: u32,

/// Whether the framebuffer changed size since this was last cleared. `App`
/// reads it to resize the surface and clears it in the same breath.
resized: bool = false,

/// Set by the close button, by Alt+F4, and by anything that calls `close`.
closing: bool = false,

/// What the game asked the pointer to do. Not always what the platform has
/// been told: while the window is in the background a held pointer is let
/// go, and this is what it is taken back to. See `refocus`.
cursor_wanted: Cursor = .normal,

/// Whether the window has the keyboard: asked of the platform when the
/// window opens, and kept up to date by its focus events after that.
///
/// Asked rather than assumed, because a window is not always made with it -
/// Windows gives the keyboard to a new window only if the program that made
/// it already had it, so a game started from something in the background
/// opens behind whatever the player is using. Assuming otherwise would lock
/// the pointer over a window the player cannot see.
focused: bool = true,

/// Open a window at this address.
pub fn open(self: *Window, gpa: Allocator, desc: Desc) Error!void {
    self.* = .{
        .ctx = try .init(gpa, .{}),
        // Filled in below. A window cannot be made until the context exists,
        // and the context has to be at its final address before it is.
        .handle = undefined,
        .width = desc.width,
        .height = desc.height,
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
        // Not fatal: a driver that refuses the swap interval draws at
        // whatever rate it likes, which is a worse experience and not a
        // broken one.
        self.handle.setSwapInterval(if (desc.vsync) .vsync else .immediate) catch |err| {
            log.warn("could not set the swap interval: {t}", .{err});
        };
    }

    const fb = self.handle.framebufferSize();
    self.width = fb[0];
    self.height = fb[1];
    self.focused = self.handle.isFocused();
}

pub fn close(self: *Window) void {
    // A display switched for exclusive fullscreen is switched back before the
    // window goes. The platform does that only when asked to go windowed, and
    // Windows itself only when the process ends - so a program that closes
    // the game and carries on, a launcher or a test runner, would otherwise
    // leave the desktop at the game's resolution.
    if (self.handle.fullscreen() == .exclusive) {
        self.handle.setFullscreen(.windowed) catch {};
    }
    // And a held pointer is let go, for the same reason: the rectangle it is
    // confined to belongs to the whole machine, not to this window, and
    // outlives it unless somebody says otherwise.
    if (self.cursor_wanted.holds()) {
        self.handle.setCursorMode(.normal) catch {};
    }
    self.handle.destroy();
    self.ctx.deinit();
    self.* = undefined;
}

/// Where the pointer may go, and whether it shows. See `Cursor`.
///
/// A mode that holds the pointer is only ever held while the window has the
/// keyboard: asked for from the background, it is remembered and taken when
/// the window comes back. See `refocus`.
pub fn setCursor(self: *Window, wanted: Cursor) Error!void {
    // Unaccelerated movement means anything only while locked, and asking for
    // it once is enough: the platform turns it on and off as the mode comes
    // and goes. Where the system cannot give it, locking still works, on the
    // accelerated numbers.
    if (wanted == .locked) _ = self.handle.setRawMouseMotion(true);

    if (self.focused or !wanted.holds()) {
        try self.handle.setCursorMode(wanted.platformMode());
    }
    self.cursor_wanted = wanted;
}

/// What the game asked the pointer to do.
pub fn cursor(self: *const Window) Cursor {
    return self.cursor_wanted;
}

/// Use one of the system's own pointer shapes over this window: a hand over
/// a button, an I-beam over a text box. `error.Unavailable` for a shape this
/// system has not got; see `fluxion-platform`'s `cursor.Shape`.
pub fn setCursorShape(self: *Window, shape: platform.CursorShape) Error!void {
    try self.handle.setCursorShape(shape);
}

/// Let a held pointer go while the window is in the background, and take it
/// back when the window returns.
///
/// On Windows the platform holds the pointer by asking for a rectangle of the
/// screen, and nothing on its side gives the rectangle back when the window
/// loses the keyboard - nor asks for it again when the window returns, in
/// case it was let go in the meantime. A locked pointer without raw motion is
/// also put back in the middle of the window on every move over it, focused
/// or not. So without this, a game alt-tabbed away from while it held the
/// pointer could keep it trapped where its window was, or come back holding
/// nothing. GLFW lets go on losing focus and takes hold again on getting it
/// back, and so does this.
fn refocus(self: *Window, focused: bool) void {
    self.focused = focused;
    if (!self.cursor_wanted.holds()) return;

    const mode: platform.CursorMode = if (focused) self.cursor_wanted.platformMode() else .normal;
    self.handle.setCursorMode(mode) catch |err| {
        log.warn("could not {s} the pointer: {t}", .{ if (focused) "take back" else "let go of", err });
    };
}

/// Fill the monitor the window is on, or go back to being a window. See
/// `Fullscreen`.
///
/// The size is read back straight away, so a caller that asks before the
/// swapchain exists - `App.create` - makes it at the right size. Where the
/// window system only gets round to it later, the change arrives as an
/// ordinary resize on a later pump instead.
pub fn setFullscreen(self: *Window, wanted: Fullscreen) Error!void {
    const request: platform.Fullscreen = switch (wanted) {
        .windowed => .windowed,
        .borderless => .{ .borderless = self.monitorIndex() orelse return error.Unavailable },
        .exclusive => |mode| .{ .exclusive = .{
            .monitor = self.monitorIndex() orelse return error.Unavailable,
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

/// Make the content area this size, in the units of `Desc.width` and
/// `height` - pixels, on every backend `fluxion-platform` has today.
///
/// A fullscreen, maximised or minimised window has no size of its own to
/// change, so it is made an ordinary window first - which is what a settings
/// screen offering "1280 by 720, in a window" means by it.
pub fn setSize(self: *Window, width: u32, height: u32) Error!void {
    try self.makeOrdinary();
    try self.handle.setSize(width, height);
    self.refreshSize();
}

/// Put the top left of the content area at this point of the desktop: the
/// coordinates of `position`, and of a monitor's bounds. An ordinary window
/// first, for the same reason as `setSize`.
pub fn setPosition(self: *Window, x: i32, y: i32) Error!void {
    try self.makeOrdinary();
    try self.handle.setPosition(x, y);
}

/// Where the top left of the content area is on the desktop. Nought, nought
/// on Wayland, always: it does not tell a program where its own window is,
/// because a program that knew could argue with the compositor about it.
pub fn position(self: *const Window) [2]i32 {
    return self.handle.position();
}

/// How small and how large the player may drag the window. See `SizeLimits`.
///
/// The platform only applies limits when the player next drags an edge, so a
/// window already outside the new ones is brought inside them here and now:
/// a minimum that the window is smaller than is not a minimum anybody can
/// see.
pub fn setSizeLimits(self: *Window, limits: SizeLimits) Error!void {
    try self.handle.setSizeLimits(limits);

    // Only an ordinary window has a size of its own to bring inside. A
    // maximised or fullscreen one is sized by its monitor, and meets the
    // limits when it goes back to being a window.
    if (self.state() != .normal or self.fullscreen() != .windowed) return;
    const width = within(self.width, limits.min_width, limits.max_width);
    const height = within(self.height, limits.min_height, limits.max_height);
    if (width != self.width or height != self.height) try self.setSize(width, height);
}

/// Maximise the window, minimise it, or put it back.
///
/// Maximised is a kind of window, so a fullscreen one stops being fullscreen
/// first. Minimised is not, and a fullscreen game minimised comes back
/// fullscreen when it is put back.
pub fn setState(self: *Window, wanted: State) Error!void {
    if (self.state() == wanted) return;
    switch (wanted) {
        .minimized => try self.handle.iconify(),
        .maximized => {
            if (self.fullscreen() != .windowed) try self.setFullscreen(.windowed);
            try self.handle.maximize();
        },
        .normal => try self.restoreFully(),
    }
    self.refreshSize();
}

/// Whether the window is at its own size, maximised, or minimised.
pub fn state(self: *const Window) State {
    if (self.handle.isIconified()) return .minimized;
    if (self.handle.isMaximized()) return .maximized;
    return .normal;
}

/// Not fullscreen, not maximised, not minimised: a window with a size and a
/// place of its own, which is the only kind that can be given either.
fn makeOrdinary(self: *Window) Error!void {
    if (self.fullscreen() != .windowed) try self.setFullscreen(.windowed);
    try self.restoreFully();
}

/// Back to the window's own size and place - twice, when it takes two.
///
/// Windows puts a minimised window back the way it was before it went down,
/// so one that was maximised first comes back maximised, and only a second
/// restore takes it the rest of the way. Asking for `.normal` and getting a
/// maximised window was what one restore did; the test that found it is a
/// window maximised, minimised, and then put back.
fn restoreFully(self: *Window) Error!void {
    for (0..2) |_| {
        if (self.state() == .normal) return;
        try self.handle.restore();
    }
}

/// One edge of a size held between its limits, where a limit of zero is no
/// limit at all.
fn within(value: u32, min: u32, max: u32) u32 {
    var held = value;
    if (min != 0) held = @max(held, min);
    if (max != 0) held = @min(held, max);
    return held;
}

/// Which of the context's monitors the window is on: the one under the
/// middle of it, or the primary one when it is over none of them - which is
/// where a minimised window is, parked by Windows at minus thirty-two
/// thousand. Null only when there are no monitors to be on.
fn monitorIndex(self: *Window) ?usize {
    const list = self.ctx.monitors();
    if (list.len == 0) return null;

    // The middle rather than the corner, because a window straddling two
    // monitors belongs to the one showing more of it, and the middle is on
    // that one. Wayland will not say where a window is, so there this comes
    // out as the first monitor - and its compositor decides for itself.
    const at = self.handle.position();
    const middle_x = at[0] +| @as(i32, @intCast(self.width / 2));
    const middle_y = at[1] +| @as(i32, @intCast(self.height / 2));

    for (list, 0..) |mon, i| {
        if (mon.bounds.contains(middle_x, middle_y)) return i;
    }
    for (list, 0..) |mon, i| {
        if (mon.primary) return i;
    }
    return 0;
}

/// Read the drawable size back from the platform, and flag a resize if it
/// moved - the same flag `pump` sets, so `App` resizes the surface the same
/// way whichever of the two noticed first.
fn refreshSize(self: *Window) void {
    const fb = self.handle.framebufferSize();
    // Zero is a minimised window, which is held at its last real size. See
    // `pump`.
    if (fb[0] == 0 or fb[1] == 0) return;
    if (fb[0] == self.width and fb[1] == self.height) return;
    self.width = fb[0];
    self.height = fb[1];
    self.resized = true;
}

/// Whether an error means this machine has no display rather than this
/// program being wrong.
///
/// A build server gets the first and should carry on headless; a game gets
/// the second and should say so. Telling them apart is the difference between
/// a test suite that runs everywhere and one that is quietly skipped
/// everywhere.
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
///
/// Every event goes to `Input` as well as being looked at here, because the
/// two want different things from the same message: a resize is a new
/// swapchain to this file and nothing at all to the keyboard, and a key is
/// the other way round.
pub fn pump(self: *Window, input: *Input) bool {
    self.ctx.pump() catch |err| {
        log.err("the event loop failed: {t}", .{err});
        return false;
    };

    // The platform polled every controller inside that pump, before handing
    // out the events - so a connection notice and the state it announces
    // arrive in the same frame.
    input.readPads(self.ctx.gamepads());

    while (self.ctx.poll()) |ev| {
        // Only what happened to this window, and what happened to no window
        // in particular - a controller plugged in, the app sent to the
        // background. A game that opens a second platform window for a tool
        // of its own should not find that window's keys, or its focus, in the
        // game's input.
        const about = ev.window();
        if (about != .none and about != self.handle.id) continue;

        input.apply(ev);
        switch (ev) {
            .close => self.closing = true,
            .focus => |change| self.refocus(change.value),
            .framebuffer_resize => |size| {
                // Minimising a window on Windows reports zero by zero, and a
                // swapchain of that size is an error on every backend. Held
                // at the last real size instead, so a minimised game carries
                // on drawing into a surface nobody can see rather than
                // falling over.
                if (size.width == 0 or size.height == 0) continue;
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

/// Show the frame that was just drawn. Only the OpenGL backend needs this;
/// Direct3D presents through the surface instead.
pub fn swap(self: *Window) void {
    self.handle.swapBuffers() catch |err| {
        log.err("could not swap buffers: {t}", .{err});
    };
}

/// The platform's own handle - an `HWND` on Windows - which is what the
/// Direct3D backend makes a swapchain from.
pub fn nativeHandle(self: *const Window) usize {
    return self.handle.native();
}

/// What the OpenGL backend needs from whoever made the context, which is
/// never the renderer: three callbacks onto this window.
///
/// The `context` pointer is this struct, so the address it is taken at has to
/// outlive the device. See the note at the top of the file.
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
