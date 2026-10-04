// SPDX-License-Identifier: BSD-3-Clause

//! What an editor does to a project's files - moving one, or putting it in
//! the trash - done so that nothing the engine holds is left pointing at the
//! old place.

const std = @import("std");

const platform = @import("fluxion_platform");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// Whether `moveToTrash` has a trash to move things to on this system: the
/// Recycle Bin on Windows, the freedesktop.org trash on a Linux desktop -
/// with a fluxion-platform that has trash at all. The Linux one takes only
/// what is on the home folder's drive: anything else is `error.OtherDrive`.
/// A folder in `App.trash` stands in for either, on any system.
pub const trash_available = if (@hasDecl(platform, "trash")) platform.trash.available else false;

/// Move or rename a file or a folder, with its `.uid` file, and everything
/// read from it with it: a texture loaded from it stays loaded, kept by
/// where it is now, so the scene saved next names the new place - and every
/// scene that names it by its UUID finds it there. Never over something
/// already at `to`: that is `error.PathAlreadyExists`. See
/// `Project.moveFile`.
pub fn moveFile(app: *App, from: []const u8, to: []const u8) !void {
    const old = try app.project.canonical(app.gpa, from);
    defer app.gpa.free(old);
    const new = try app.project.canonical(app.gpa, to);
    defer app.gpa.free(new);
    try app.project.moveFile(old, new);
    try app.assets.renamed(old, new);
    try app.tile_sets.renamed(app.gpa, old, new);
    try app.scenes.renamed(app.gpa, old, new);
    try app.data_files.renamed(app.gpa, old, new);
    try app.audio.renamed(old, new);
    try app.animation_libraries.renamed(app.gpa, old, new);
    try app.sprite_frames.renamed(app.gpa, old, new);
    try app.shaders.renamed(app.gpa, old, new);
    try app.meshes.renamed(app.gpa, old, new);
    try app.materials.renamed(app.gpa, old, new);
    try app.themes.renamed(app.gpa, old, new);
    if (app.scripts) |scripts| try scripts.renamed(old, new);
}

/// Move a file or a folder to the system's trash, where a person can take it
/// back from - with its `.uid` file, so what comes back has its UUID. What
/// the project knew of its UUIDs is forgotten; what was loaded from it stays
/// loaded. `error.Unsupported` where there is no trash: see
/// `trash_available`.
pub fn moveToTrash(app: *App, path: []const u8) !void {
    if (comptime @hasDecl(platform, "trash")) {
        const io = app.io orelse return error.NoIo;
        const named = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(named);
        const file = try app.project.osPath(app.gpa, named);
        defer app.gpa.free(file);
        const kept = try std.mem.concat(app.gpa, u8, &.{ file, Project.uid_extension });
        defer app.gpa.free(kept);

        try throwAway(app, io, file);
        // Its UUID after it, so a restore brings back both. The file has gone
        // either way, so a `.uid` file left behind is said, not undone.
        if (std.Io.Dir.cwd().access(io, kept, .{})) |_| {
            throwAway(app, io, kept) catch |err| log.warn("{s} is in the trash and its {s} file is not: {t}", .{ named, Project.uid_extension, err });
        } else |_| {}
        try app.project.forgetFile(named);
        return;
    }
    return error.Unsupported;
}

/// One file or folder, absolute, to `trash` when it is set and to the
/// system's otherwise.
fn throwAway(app: *App, io: std.Io, file: []const u8) !void {
    const bin = platform.trash;
    const folder = app.trash orelse return bin.move(app.gpa, io, file);
    // The time in UTC: a folder of one's own is for tests and tools, which
    // want it the same on every machine more than in the local hour.
    const seconds: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const at: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const date = at.getEpochDay().calculateYearDay();
    const day = date.calculateMonthDay();
    const time = at.getDaySeconds();
    return bin.freedesktop.move(app.gpa, io, file, folder, .{
        .year = date.year,
        .month = day.month.numeric(),
        .day = @as(u8, day.day_index) + 1,
        .hour = time.getHoursIntoDay(),
        .minute = time.getMinutesIntoHour(),
        .second = time.getSecondsIntoMinute(),
    });
}
