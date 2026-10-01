// SPDX-License-Identifier: BSD-3-Clause

//! The pointer's look: the pictures a game gives its shapes, the shape it
//! takes where nothing asks for another, and the one the interface asked
//! for - told to the window only when it changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const platform = @import("fluxion_platform");
const image = @import("fluxion_image");
const ui_lib = @import("fluxion_ui");

const App = @import("../App.zig");
const Assets = @import("../assets/assets.zig");
const Window = @import("window.zig");
const game_files = @import("../files/game_files.zig");

const CursorShape = platform.CursorShape;
const log = std.log.scoped(.fluxion_engine);

pub const Cursors = struct {
    /// The picture the game gave each of the pointer's shapes, if it gave
    /// one.
    custom: [@typeInfo(CursorShape).@"enum".fields.len]?Custom = @splat(null),
    /// What the pointer is where nothing asks for another shape.
    default_shape: CursorShape = .arrow,
    /// The shape the last frame's interface asked for.
    wanted: CursorShape = .arrow,
    /// What the window was last told, with the pictures as they were then.
    shown: ?struct { shape: CursorShape, generation: u32 } = null,
    /// Counted up whenever a picture changes, so a shape is told again.
    generation: u32 = 0,

    /// A picture the game gave one of the pointer's shapes.
    const Custom = struct { pixels: []u8, width: u32, height: u32, hot_x: u32, hot_y: u32 };

    pub fn deinit(self: *Cursors, gpa: Allocator) void {
        for (self.custom) |held| if (held) |custom| gpa.free(custom.pixels);
    }

    /// A shape's picture from pixels in memory - straight RGBA, row by row
    /// from the top - which are copied; null gives the shape back to the
    /// system.
    pub fn setPixels(self: *Cursors, gpa: Allocator, picture: ?platform.CursorImage, shape: CursorShape) !void {
        const slot = &self.custom[@intFromEnum(shape)];
        const given = picture orelse {
            if (slot.*) |held| gpa.free(held.pixels);
            slot.* = null;
            self.generation +%= 1;
            return;
        };
        if (given.width > platform.CursorImage.max_side or given.height > platform.CursorImage.max_side) return error.CursorTooLarge;
        if (!given.valid()) return error.InvalidCursor;
        const pixels = try gpa.dupe(u8, given.pixels);
        if (slot.*) |held| gpa.free(held.pixels);
        slot.* = .{ .pixels = pixels, .width = given.width, .height = given.height, .hot_x = given.hot_x, .hot_y = given.hot_y };
        self.generation +%= 1;
    }

    /// The shape the interface asks for, the arrow being the game's default.
    pub fn want(self: *Cursors, asked: ui_lib.CursorShape) void {
        const shape: CursorShape = switch (asked) {
            inline else => |named| @field(CursorShape, @tagName(named)),
        };
        self.wanted = if (shape == .arrow) self.default_shape else shape;
    }

    /// The window shows the wanted shape: the game's picture for it where it
    /// gave one, and the system's otherwise - told only of a change.
    pub fn apply(self: *Cursors, window: *Window) void {
        const shape = self.wanted;
        if (self.shown) |shown| {
            if (shown.shape == shape and shown.generation == self.generation) return;
        }
        self.shown = .{ .shape = shape, .generation = self.generation };
        if (self.custom[@intFromEnum(shape)]) |custom| {
            window.setCursorImage(.{ .pixels = custom.pixels, .width = custom.width, .height = custom.height, .hot_x = custom.hot_x, .hot_y = custom.hot_y }) catch |err| {
                log.warn("the pointer's picture was not taken: {t}", .{err});
            };
            return;
        }
        window.setCursorImage(null) catch {};
        window.setCursorShape(shape) catch {};
    }
};

/// A shape's picture from a texture's file: see `App.setCustomCursor`.
pub fn setCustom(app: *App, texture: Assets.TextureHandle, shape: CursorShape, hotspot: math.Vec2) !void {
    if (texture.isNone()) return app.cursors.setPixels(app.gpa, null, shape);
    const source = app.assets.textureSource(texture) orelse return error.NoFile;
    return setCustomFile(app, source, shape, hotspot);
}

/// A shape's picture from a picture's file, read without making a texture
/// of it, `hotspot` held inside the picture.
pub fn setCustomFile(app: *App, path: []const u8, shape: CursorShape, hotspot: math.Vec2) !void {
    const bytes = try app.project.readFileAlloc(app.gpa, path, .limited(game_files.text_limit));
    defer app.gpa.free(bytes);
    var decoded = try image.decode(app.gpa, bytes);
    defer decoded.deinit(app.gpa);
    const hot_x: u32 = @intFromFloat(std.math.clamp(@round(hotspot.x), 0, @as(f32, @floatFromInt(decoded.width -| 1))));
    const hot_y: u32 = @intFromFloat(std.math.clamp(@round(hotspot.y), 0, @as(f32, @floatFromInt(decoded.height -| 1))));
    try app.cursors.setPixels(app.gpa, .{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height, .hot_x = hot_x, .hot_y = hot_y }, shape);
}

/// The project file's `display.mouse_cursor` for the arrow. A picture that
/// does not read is said, and the system's arrow stays.
pub fn useProjectCursor(app: *App) void {
    const settings = app.project.settings orelse return;
    const path = settings.display.mouse_cursor;
    if (path.len == 0) return;
    setCustomFile(app, path, .arrow, settings.display.mouse_cursor_hotspot) catch |err| {
        log.warn("the project's pointer {s} was not taken: {t}", .{ path, err });
    };
}
