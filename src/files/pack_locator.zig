// SPDX-License-Identifier: BSD-3-Clause

//! Where a shipped game's program finds its pack: beside it, named after
//! it with `.fxpack` for its ending - `Game.fxpack` by `Game.exe`,
//! `game.fxpack` by `game.x86_64` - and on Android in the APK's `assets/`,
//! stored as it is, which `platform.bundle` opens.

const std = @import("std");
const Io = std.Io;

const vfs = @import("fluxion_vfs");
const platform = @import("fluxion_platform");

/// What a pack beside a program ends in.
pub const pack_extension = ".fxpack";

/// What the pack is called inside an APK's `assets/`.
pub const android_pack = "game.fxpack";

pub const OpenError = vfs.Pack.Error || error{ OutOfMemory, NoGame };

/// The pack of the program running: the one `path` names, else the one
/// beside it; on Android the APK's `assets/game.fxpack`. `error.NoGame`
/// when there is none.
pub fn openPack(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) OpenError!vfs.Pack {
    if (path) |named| return vfs.Pack.openFile(gpa, io, named, .{});
    if (comptime @import("builtin").abi.isAndroid()) {
        const bundled = platform.bundle.open(android_pack) catch return error.NoGame;
        errdefer bundled.file.close(io);
        var pack = try vfs.Pack.fromFileRegion(gpa, io, bundled.file, bundled.start, bundled.len, .{});
        pack.storage.file.owned = true;
        return pack;
    }

    const program = std.process.executablePathAlloc(io, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoGame,
    };
    defer gpa.free(program);
    const beside = try besidePath(gpa, program);
    defer gpa.free(beside);
    return vfs.Pack.openFile(gpa, io, beside, .{}) catch |err| switch (err) {
        error.FileNotFound => error.NoGame,
        else => err,
    };
}

/// The pack beside the program at `program`: its name without its ending,
/// and `.fxpack`.
pub fn besidePath(gpa: std.mem.Allocator, program: []const u8) error{OutOfMemory}![]u8 {
    const folder = program[0 .. program.len - std.fs.path.basename(program).len];
    return std.mem.concat(gpa, u8, &.{ folder, std.fs.path.stem(program), pack_extension });
}

test "the pack beside a program is named after it" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{ .{ "Game.exe", "Game.fxpack" }, .{ "Secret_Game.x86_64", "Secret_Game.fxpack" } }) |case| {
        const program = try std.fs.path.join(gpa, &.{ "games", "secret", case[0] });
        defer gpa.free(program);
        const want = try std.fs.path.join(gpa, &.{ "games", "secret", case[1] });
        defer gpa.free(want);
        const beside = try besidePath(gpa, program);
        defer gpa.free(beside);
        try std.testing.expectEqualStrings(want, beside);
    }
}
