// SPDX-License-Identifier: BSD-3-Clause

//! A game's own files, at any path a game names - `res://`, `user://`,
//! `uid://` or the system's own: their text, folders, what is known of a
//! file without reading it, a hash, compressed and sealed saves, and the
//! system's programs a file or an address is handed to.
//!
//! A project path in a shipped game is read out of its pack, which nothing
//! writes to: see `Project`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const platform = @import("fluxion_platform");

const Project = @import("../project/Project.zig");
const datetime = @import("../time/datetime.zig");
const sealed = @import("sealed.zig");

/// The most a file is read as text: `readText`.
pub const text_limit = 64 << 20;

/// The text of the file at `path` - `res://`, `user://`, `uid://` or the
/// system's own - in `gpa`'s memory, for the caller to free.
/// `error.FileNotFound` where there is none.
pub fn readText(project: *Project, gpa: Allocator, path: []const u8) ![]u8 {
    return project.readFileAlloc(gpa, path, .limited(text_limit));
}

/// Write `text` to the file at `path`, over what it held, making the
/// folders on the way. The new text is written beside the old and then put
/// in its place, so a game that stops halfway through a save leaves the
/// last one whole.
pub fn writeText(project: *Project, path: []const u8, text: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, file, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
}

/// Whether there is a file or a folder at `path`.
pub fn fileExists(project: *Project, path: []const u8) bool {
    if (project.packInfo(path) != null) return true;
    const io = project.io orelse return false;
    const file = project.osPath(project.gpa, path) catch return false;
    defer project.gpa.free(file);
    std.Io.Dir.cwd().access(io, file, .{}) catch return false;
    return true;
}

/// Make the folder at `path`, and the ones it is in. One there already is
/// fine.
pub fn makeDir(project: *Project, path: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    try std.Io.Dir.cwd().createDirPath(io, file);
}

/// Take out the file at `path`, or the folder, when it is empty.
pub fn removeFile(project: *Project, path: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    std.Io.Dir.cwd().deleteFile(io, file) catch |err| switch (err) {
        error.IsDir => try std.Io.Dir.cwd().deleteDir(io, file),
        else => return err,
    };
}

/// What a folder holds, by name, in order. See `listDir`.
pub const Listing = struct {
    /// A folder's name ends with `/`: `slots/`.
    names: [][]u8,

    pub fn deinit(self: Listing, gpa: Allocator) void {
        for (self.names) |name| gpa.free(name);
        gpa.free(self.names);
    }
};

/// The names in the folder at `path`, sorted, a folder's ending with `/`.
/// `error.FileNotFound` where there is none.
pub fn listDir(project: *Project, gpa: Allocator, path: []const u8) !Listing {
    if (project.pack != null and Project.isProjectPath(path)) {
        return .{ .names = (try project.packListing(gpa, path)) orelse return error.FileNotFound };
    }
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    var dir = try std.Io.Dir.cwd().openDir(io, file, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.ensureUnusedCapacity(gpa, 1);
        const folder = entry.kind == .directory;
        const name = try gpa.alloc(u8, entry.name.len + @intFromBool(folder));
        @memcpy(name[0..entry.name.len], entry.name);
        if (folder) name[entry.name.len] = '/';
        names.appendAssumeCapacity(name);
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return .{ .names = try names.toOwnedSlice(gpa) };
}

/// Add `text` to the end of the file at `path`, making it - and the folders
/// it is in - when there is none: a log, a line at a time.
pub fn appendText(project: *Project, path: []const u8, text: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    if (std.fs.path.dirname(file)) |folder| try std.Io.Dir.cwd().createDirPath(io, folder);
    var handle = try std.Io.Dir.cwd().createFile(io, file, .{ .truncate = false, .read = true });
    defer handle.close(io);
    const end = (try handle.stat(io)).size;
    var buffer: [4096]u8 = undefined;
    var out = handle.writer(io, &buffer);
    try out.seekTo(end);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

/// What is known of a file without reading it. See `fileInfo`.
pub const FileInfo = struct {
    /// Bytes; nought for a folder.
    size: u64,
    /// When it was last written.
    modified: datetime.Instant,
    folder: bool,
};

/// The size of the file at `path`, when it was last written, and whether it
/// is a folder. `error.FileNotFound` where there is none.
pub fn fileInfo(project: *Project, path: []const u8) !FileInfo {
    if (project.pack != null and Project.isProjectPath(path)) {
        const info = project.packInfo(path) orelse return error.FileNotFound;
        // A pack keeps no times: it was all made at once.
        return .{ .size = info.size, .modified = .{ .us = 0 }, .folder = info.folder };
    }
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    const stat = try std.Io.Dir.cwd().statFile(io, file, .{});
    const folder = stat.kind == .directory;
    return .{
        .size = if (folder) 0 else stat.size,
        .modified = .{ .us = @intCast(@divFloor(stat.mtime.nanoseconds, 1000)) },
        .folder = folder,
    };
}

/// Whether there is a folder at `path`.
pub fn isDir(project: *Project, path: []const u8) bool {
    const info = fileInfo(project, path) catch return false;
    return info.folder;
}

/// The SHA-256 of the file at `path`: the same file, the same 32 bytes -
/// whether a download finished whole, or a save is the one the game wrote.
pub fn fileSha256(project: *Project, path: []const u8) ![32]u8 {
    if (project.pack != null and Project.isProjectPath(path)) {
        const bytes = try project.readFileAlloc(project.gpa, path, .unlimited);
        defer project.gpa.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return digest;
    }
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    var handle = try std.Io.Dir.cwd().openFile(io, file, .{});
    defer handle.close(io);
    var in = handle.reader(io, &.{});
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const got = in.interface.readSliceShort(&chunk) catch return in.err orelse error.ReadFailed;
        if (got == 0) break;
        hash.update(chunk[0..got]);
    }
    return hash.finalResult();
}

/// `text` written to `path` as gzip, which any tool opens: a big save in a
/// tenth of the room. `readCompressed` reads it.
pub fn writeCompressed(project: *Project, path: []const u8, text: []const u8) !void {
    const bytes = try sealed.compress(project.gpa, text);
    defer project.gpa.free(bytes);
    try writeText(project, path, bytes);
}

/// The text of a file `writeCompressed` wrote. `error.NotCompressed` for a
/// file that is not gzip.
pub fn readCompressed(project: *Project, gpa: Allocator, path: []const u8) ![]u8 {
    const bytes = try readText(project, project.gpa, path);
    defer project.gpa.free(bytes);
    return sealed.decompress(gpa, bytes, text_limit);
}

/// `text` written to `path` compressed and sealed with `password`: nobody
/// reads it, and a file changed by hand is refused rather than taken. See
/// `sealed`. `cost` is how hard the password is made to guess.
pub fn writeSecret(project: *Project, path: []const u8, text: []const u8, password: []const u8, cost: sealed.Cost) !void {
    const io = project.io orelse return error.NoIo;
    const bytes = try sealed.seal(project.gpa, io, text, password, cost);
    defer project.gpa.free(bytes);
    try writeText(project, path, bytes);
}

/// The text of a file `writeSecret` wrote with `password`.
/// `error.CannotOpen` for another password or a file changed since;
/// `error.NotSealed` for a file that was never sealed.
pub fn readSecret(project: *Project, gpa: Allocator, path: []const u8, password: []const u8) ![]u8 {
    const io = project.io orelse return error.NoIo;
    const bytes = try readText(project, project.gpa, path);
    defer project.gpa.free(bytes);
    return sealed.open(gpa, io, bytes, password, text_limit);
}

/// Open a web or mail address in the player's browser or mail program: a
/// game's page, its store, an address to write to. Only `http://`,
/// `https://` and `mailto:` - anything else is `error.NotAllowed`, so a
/// script cannot start a program with it.
pub fn openUrl(project: *Project, url: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    inline for (.{ "http://", "https://", "mailto:" }) |allowed| {
        if (std.ascii.startsWithIgnoreCase(url, allowed)) return platform.shell.openUrl(project.gpa, io, url);
    }
    return error.NotAllowed;
}

/// Open the file at `path` in the program the player opens its kind with,
/// or a folder in the file manager. `error.Unsupported` where there is none
/// to ask: a page, a phone.
pub fn openPath(project: *Project, path: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    try platform.shell.openPath(project.gpa, io, file);
}

/// Show the file at `path` picked out in the file manager's window of its
/// folder: a Saves folder button's `showInFolder("user://saves/slot1.json")`.
pub fn showInFolder(project: *Project, path: []const u8) !void {
    const io = project.io orelse return error.NoIo;
    const file = try project.osPath(project.gpa, path);
    defer project.gpa.free(file);
    try platform.shell.showInFolder(project.gpa, io, file);
}
