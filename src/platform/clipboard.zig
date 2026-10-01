// SPDX-License-Identifier: BSD-3-Clause

//! Text on the clipboard. With a window it is the system's, through the
//! window's platform context: what a game copies reaches every other program,
//! and what they copied reaches the game. Without one - headless, in a test -
//! there is no system to ask, and the clipboard is the program's own.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const platform = @import("fluxion_platform");

const Clipboard = @This();

/// `error.Unavailable` for text that is not UTF-8, and for a system that will
/// not take it: Wayland takes the clipboard only from the window with the
/// keyboard, and a page may not have one at all.
pub const Error = platform.Error;

/// The window's context. Null without a window.
system: ?*platform.Context = null,
/// The text, when there is no system to keep it.
own: std.ArrayList(u8) = .empty,

pub fn deinit(self: *Clipboard, gpa: Allocator) void {
    self.own.deinit(gpa);
    self.* = undefined;
}

/// Put `value` on the clipboard. Copied, so it may go as soon as this
/// returns.
pub fn set(self: *Clipboard, gpa: Allocator, value: []const u8) Error!void {
    if (self.system) |ctx| return ctx.setClipboardText(value);
    if (!std.unicode.utf8ValidateSlice(value)) return error.Unavailable;
    self.own.clearRetainingCapacity();
    try self.own.appendSlice(gpa, value);
}

/// What the clipboard holds, empty for nothing. Lent until the next `read`.
pub fn read(self: *Clipboard) Error![]const u8 {
    if (self.system) |ctx| return ctx.clipboardText();
    return self.own.items;
}

/// Whether it holds text, asked without reading it.
pub fn has(self: *Clipboard) bool {
    if (self.system) |ctx| return ctx.hasClipboardText();
    return self.own.items.len != 0;
}

test "without a window the clipboard is the program's own" {
    var clipboard: Clipboard = .{};
    defer clipboard.deinit(testing.allocator);

    try testing.expect(!clipboard.has());
    try testing.expectEqualStrings("", try clipboard.read());

    try clipboard.set(testing.allocator, "árvíztűrő\ntükörfúrógép");
    try testing.expect(clipboard.has());
    try testing.expectEqualStrings("árvíztűrő\ntükörfúrógép", try clipboard.read());
}

test "text that is not UTF-8 is refused, and what was there stays" {
    var clipboard: Clipboard = .{};
    defer clipboard.deinit(testing.allocator);

    try clipboard.set(testing.allocator, "kept");
    try testing.expectError(error.Unavailable, clipboard.set(testing.allocator, "\xff\xfe"));
    try testing.expectEqualStrings("kept", try clipboard.read());
}
