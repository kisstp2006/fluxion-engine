// SPDX-License-Identifier: BSD-3-Clause

//! A game made at one size, shown in a window of any: `display.stretch_mode`
//! and `display.stretch_aspect` in the project file, over the size it says
//! the window opens at.
//!
//! | Mode | What it does |
//! | --- | --- |
//! | `disabled` | The frame is the window: a bigger window shows more. |
//! | `canvas` | The world and the interface are laid out at the project's size and drawn at the window's, scaled: sharp text at any size. |
//! | `picture` | Everything is drawn at the project's size, into a picture of its own, and the picture is scaled to the window: pixel art stays pixels. |
//!
//! | Aspect | What it does |
//! | --- | --- |
//! | `keep` | Always the project's shape: bars fill what the window has to spare. |
//! | `expand` | The spare room shows more: the frame grows the long way, and the project's size is the least of it. |
//!
//! What the game sees is the frame: what the interface is laid out in, what
//! the camera's view is sized by, and where the pointer is - the window's
//! pixels, turned into the frame's by `Input` as they come. The window's size
//! is `App.width` and `App.height` still; the frame's is `App.frame`.

const std = @import("std");
const testing = std.testing;

const math = @import("fluxion_math");

pub const Mode = enum { disabled, canvas, picture };

pub const Aspect = enum { keep, expand };

/// What a project asks of the window, and the size it was made at.
pub const Stretch = struct {
    mode: Mode = .disabled,
    aspect: Aspect = .keep,
    width: u32 = 0,
    height: u32 = 0,

    /// The frame for a window `width` by `height` pixels.
    pub fn frameOf(self: Stretch, width: u32, height: u32) Frame {
        if (self.mode == .disabled or self.width == 0 or self.height == 0 or width == 0 or height == 0) return .window(width, height);
        const window_width: f32 = @floatFromInt(width);
        const window_height: f32 = @floatFromInt(height);
        const base_width: f32 = @floatFromInt(self.width);
        const base_height: f32 = @floatFromInt(self.height);
        const scale = @min(window_width / base_width, window_height / base_height);

        // What the game has room for, at its own size: the project's, or -
        // expanded - that and what the window has to spare.
        const room_width = if (self.aspect == .expand) window_width / scale else base_width;
        const room_height = if (self.aspect == .expand) window_height / scale else base_height;
        const shown_width = @round(room_width * scale);
        const shown_height = @round(room_height * scale);
        const shown: Rect = .{
            .x = @floor((window_width - shown_width) / 2),
            .y = @floor((window_height - shown_height) / 2),
            .width = shown_width,
            .height = shown_height,
        };
        var out: Frame = switch (self.mode) {
            .disabled => unreachable,
            .canvas => .{ .width = whole(shown_width), .height = whole(shown_height), .scale = scale, .shown = shown },
            .picture => .{ .width = whole(room_width), .height = whole(room_height), .shown = shown },
        };
        out.apart = !(shown.x == 0 and shown.y == 0 and out.width == width and out.height == height);
        return out;
    }
};

fn whole(pixels: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@round(pixels))));
}

/// A rectangle of the window, in its pixels from the top left.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
};

/// What a frame is laid out and drawn at, and where on the window it goes.
pub const Frame = struct {
    /// Its pixels: what the interface is laid out in and the camera's view
    /// is sized by.
    width: u32,
    height: u32,
    /// What world units and the interface's lengths are multiplied by on
    /// top of their own: the canvas's scale. One for a picture, which is
    /// scaled whole instead.
    scale: f32 = 1,
    /// Where on the window it is shown.
    shown: Rect,
    /// Drawn into a picture of its own and put on the window, rather than
    /// on the window itself: when it is not the whole window at one pixel
    /// to one.
    apart: bool = false,

    /// The window itself.
    pub fn window(width: u32, height: u32) Frame {
        return .{
            .width = @max(width, 1),
            .height = @max(height, 1),
            .shown = .{ .width = @floatFromInt(@max(width, 1)), .height = @floatFromInt(@max(height, 1)) },
        };
    }

    /// How many of its pixels one of the window's is.
    pub fn ratio(self: Frame) f32 {
        return @as(f32, @floatFromInt(self.width)) / self.shown.width;
    }

    /// A point on the window, in the frame's pixels.
    pub fn toFrame(self: Frame, point: math.Vec2) math.Vec2 {
        const r = self.ratio();
        return .init((point.x - self.shown.x) * r, (point.y - self.shown.y) * r);
    }
};

test "disabled, the frame is the window" {
    const frame = (Stretch{ .width = 640, .height = 360 }).frameOf(1280, 800);
    try testing.expectEqual(@as(u32, 1280), frame.width);
    try testing.expect(!frame.apart);
    try testing.expectEqual(@as(f32, 1), frame.scale);
}

test "a canvas keeping its shape is scaled into the window with bars at the sides" {
    const frame = (Stretch{ .mode = .canvas, .width = 640, .height = 360 }).frameOf(1600, 720);
    // Twice as tall: twice the size, and the spare width in two bars.
    try testing.expectEqual(@as(f32, 2), frame.scale);
    try testing.expectEqual(@as(u32, 1280), frame.width);
    try testing.expectEqual(@as(u32, 720), frame.height);
    try testing.expectEqual(@as(f32, 160), frame.shown.x);
    try testing.expect(frame.apart);
    // The pointer at the bar's edge is at the frame's.
    try testing.expectEqual(@as(f32, 0), frame.toFrame(.init(160, 0)).x);
}

test "an expanded canvas fills the window and shows more the long way" {
    const frame = (Stretch{ .mode = .canvas, .aspect = .expand, .width = 640, .height = 360 }).frameOf(1600, 720);
    try testing.expectEqual(@as(u32, 1600), frame.width);
    try testing.expectEqual(@as(f32, 2), frame.scale);
    // One pixel to one, all of the window: drawn straight on it.
    try testing.expect(!frame.apart);
}

test "a picture is drawn at the project's size and scaled whole" {
    const frame = (Stretch{ .mode = .picture, .width = 320, .height = 180 }).frameOf(1280, 800);
    try testing.expectEqual(@as(u32, 320), frame.width);
    try testing.expectEqual(@as(u32, 180), frame.height);
    try testing.expectEqual(@as(f32, 1), frame.scale);
    try testing.expectEqual(@as(f32, 1280), frame.shown.width);
    try testing.expectEqual(@as(f32, 720), frame.shown.height);
    try testing.expectEqual(@as(f32, 40), frame.shown.y);
    // Four of the window's pixels are one of the picture's.
    try testing.expectEqual(@as(f32, 0.25), frame.ratio());
    const point = frame.toFrame(.init(640, 400));
    try testing.expectEqual(@as(f32, 160), point.x);
    try testing.expectEqual(@as(f32, 90), point.y);

    const wide = (Stretch{ .mode = .picture, .aspect = .expand, .width = 320, .height = 180 }).frameOf(1280, 800);
    try testing.expectEqual(@as(u32, 320), wide.width);
    try testing.expectEqual(@as(u32, 200), wide.height);
}
