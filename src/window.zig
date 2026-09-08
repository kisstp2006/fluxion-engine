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

pub const Desc = struct {
    title: []const u8 = "fluxion",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
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
}

pub fn close(self: *Window) void {
    self.handle.destroy();
    self.ctx.deinit();
    self.* = undefined;
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

    while (self.ctx.poll()) |ev| {
        input.apply(ev);
        switch (ev) {
            .close => self.closing = true,
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
