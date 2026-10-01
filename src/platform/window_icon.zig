// SPDX-License-Identifier: BSD-3-Clause

//! The window's own picture: the project's `application.icon`, made at the
//! sizes the systems draw one at.

const std = @import("std");

const platform = @import("fluxion_platform");

const App = @import("../App.zig");
const Image = @import("../assets/images.zig").Image;
const game_files = @import("../files/game_files.zig");

const log = std.log.scoped(.fluxion_engine);

/// The sizes a window's picture is made in: what the systems draw one at,
/// in a title bar and a task switcher, at display scales from 100% to 300%,
/// smallest first.
const sides = [_]u32{ 16, 20, 24, 28, 32, 40, 48, 56, 64, 96, 128, 256 };

/// The project file's `application.icon` on the window, when it names one:
/// what the game shows in the taskbar. The picture can be any size; the
/// window gets it at each of `sides`. A program with an icon of its own - a
/// Windows export - keeps that one, which its export made for it. A picture
/// that does not read is said, and the window keeps the system's.
pub fn useProjectIcon(app: *App) void {
    const settings = app.project.settings orelse return;
    const path = settings.application.icon;
    const window = if (app.window) |*one| one else return;
    if (path.len == 0 or window.programIcon()) return;
    const bytes = app.project.readFileAlloc(app.gpa, path, .limited(game_files.text_limit)) catch |err| {
        return log.warn("the project's icon {s} did not read: {t}", .{ path, err });
    };
    defer app.gpa.free(bytes);
    var art = Image.decode(app.gpa, bytes) catch |err| {
        return log.warn("the project's icon {s} did not read: {t}", .{ path, err });
    };
    defer art.deinit(app.gpa);

    // The largest from the picture, and the rest from that one, so a picture
    // of any size is gone over once.
    var made: [sides.len]Image = undefined;
    var sizes: [sides.len]platform.IconImage = undefined;
    var count: usize = 0;
    defer for (made[0..count]) |*one| one.deinit(app.gpa);
    var left: usize = sides.len;
    while (left > 0) {
        left -= 1;
        const side = sides[left];
        made[count] = (if (count == 0) art.icon(app.gpa, side, side) else made[0].resized(app.gpa, side, side, true)) catch |err| {
            return log.warn("the project's icon {s} was not put on the window: {t}", .{ path, err });
        };
        sizes[count] = .{ .pixels = made[count].pixels, .width = side, .height = side };
        count += 1;
    }
    app.setWindowIcon(&sizes) catch |err| {
        log.warn("the project's icon {s} was not put on the window: {t}", .{ path, err });
    };
}
