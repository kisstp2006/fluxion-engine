// SPDX-License-Identifier: BSD-3-Clause

//! Where a game's files are, and the names the game gives them.
//!
//! ```zig
//! const hero = try app.assets.loadTexture("res://art/hero.png", .{});
//! try app.saveScene("res://levels/meadow.json", .{});
//! ```
//!
//! **A `res://` path is the project's.** `res://art/hero.png` is
//! `art/hero.png` under the project's root, whichever directory the program
//! was started in, and it is how a scene names a file. Any other path is the
//! operating system's, as it always was: a system font, where a screenshot
//! goes. A file the engine is handed by the operating system's path is still
//! kept by its project path when it lies inside the root, so a scene never
//! holds one machine's directories. The root is `App.Options.root` - `--root`
//! on the command line - or else the working directory; a project file will
//! say where it is, once there is one.
//!
//! **A project's file can have a UUID**, kept beside it in a `.uid` file -
//! `art/hero.png.uid`, one line, `uid://...`. A scene names a file by its
//! UUID as well as by its path, and reading one goes by the UUID first, so a
//! texture moved or renamed together with its `.uid` file is found where it
//! went. A `uid://` path is taken wherever a `res://` one is.
//!
//! Where a UUID's file is, is learnt from the `.uid` files read along the way;
//! one nobody has read yet sends the engine through the whole project once,
//! passing over hidden directories - `.git`, `.zig-cache` - and `zig-out` and
//! `zig-pkg`, which are built rather than written.
//!
//! **A file moved here takes its UUID along**: `moveFile` moves the `.uid`
//! file beside it and tells the project where the UUID is now, and
//! `copyFile` gives a copy a UUID of its own, so two files never share one.
//! Neither ever writes over a file.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const Uuid = @import("fluxion_id").Uuid;
const folders = @import("fluxion_platform").folders;

const project_file = @import("project/settings.zig");

const Project = @This();
const log = std.log.scoped(.fluxion_engine);

/// What a project's file is called, at its root: `project.fluxion`.
pub const file_name = project_file.file_name;

/// What a project file says, a section a field: `application`, `display`,
/// `rendering`, `physics_2d`, `layer_names`, `gui`, `input`. See
/// `project/settings.zig`.
pub const Settings = project_file.Settings;

/// The project file's sections.
pub const Application = project_file.Application;
pub const Display = project_file.Display;
pub const Rendering = project_file.Rendering;
/// How a 2D world moves: `physics_2d` in the project file.
pub const Physics2D = project_file.Physics2D;
pub const Audio = project_file.Audio;
pub const LayerNames = project_file.LayerNames;
pub const Gui = project_file.Gui;
pub const InputMap = project_file.InputMap;

/// Which family of graphics APIs a project is drawn with, and its backends
/// on each system.
pub const Renderer = project_file.Renderer;

/// The top of a project file: `"fluxion_project": 2`.
pub const settings_header = project_file.header;

pub const ReadError = project_file.ReadError;
pub const WriteError = project_file.WriteError;
pub const CreateError = project_file.CreateError;

/// The project file in a folder, read with no `App` and no GPU: what a
/// project manager lists projects by.
pub const readSettings = project_file.read;

/// Write a folder's project file in place of the one there.
pub const writeSettings = project_file.write;

/// The project file's text, as `writeSettings` writes it.
pub const settingsText = project_file.text;

/// Make a new project: its folder and its project file.
pub const create = project_file.create;

/// What a project path starts with.
pub const scheme = "res://";

/// What a path naming a file by its UUID starts with.
pub const uid_scheme = "uid://";

/// What a path in the player's own folder starts with: saved games and
/// settings, which a game writes and its files are not. See `userRoot`.
pub const user_scheme = "user://";

/// What is added to a file's name for the file its UUID is kept in.
pub const uid_extension = ".uid";

pub const Error = error{
    /// A `res://` path that climbs out of the project with `..`, or that
    /// names a root or a drive of its own.
    OutsideProject,
    /// A `uid://` path whose UUID does not read, or that no `.uid` file in
    /// the project holds.
    NoSuchUid,
    /// A `user://` path on a system that keeps no folder for a program's
    /// data, or with no `Io` to ask it.
    NoUserFolder,
} || Allocator.Error;

pub const InitError = std.Io.Dir.OpenError || std.Io.Dir.RealPathError || Allocator.Error;

/// What reading a `.uid` file can say, besides what reading any file can.
pub const UidError = error{
    /// A `.uid` file that does not hold a UUID.
    InvalidUid,
} || Error || std.Io.Dir.ReadFileAllocError;

gpa: Allocator,
io: ?std.Io,

/// The root, as the operating system spells it: absolute, when there is an
/// `Io` to ask.
root: []const u8,

/// The working directory, absolute, for an operating-system path that is
/// relative. Asked once: a game does not change directory.
cwd: []const u8,

/// Every UUID read from a `.uid` file or made for one, and the project path
/// of the file it names; `by_path` is the other way round. Each path is one
/// allocation, shared by the two.
by_uid: std.AutoHashMapUnmanaged(Uuid, []const u8) = .empty,
by_path: std.StringHashMapUnmanaged(Uuid) = .empty,

/// Whether the whole project has been looked through for `.uid` files.
scanned: bool = false,

/// What the project file at the root says, once `loadSettings` has read it:
/// null for a root with none.
settings: ?Settings = null,

/// What new UUIDs are drawn from: seeded by the operating system, or with no
/// `Io` by a constant, so a test makes the same ones every run.
source: std.Random.DefaultCsprng,

/// Where `user://` is, once `userRoot` has worked it out - or set first: a
/// test's folder, a game kept on a stick with its saves beside it. Owned.
user_root: ?[]u8 = null,
/// What the game is called when the project file does not say: the folder
/// `user://` is under is named after it. Owned.
fallback_name: ?[]u8 = null,

/// The project at `root` - the working directory when null, and the folder
/// it is in when `root` names a project file, as a file association hands it
/// over. With no `Io` the paths are kept as they are given, and nothing is
/// read. Its settings are read by `loadSettings`.
pub fn init(gpa: Allocator, io: ?std.Io, root: ?[]const u8) InitError!Project {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = @splat(0x9A);
    if (io) |reach| reach.random(&seed);

    const cwd = if (io) |reach| try absoluteDirectory(gpa, reach, ".") else try gpa.dupe(u8, ".");
    errdefer gpa.free(cwd);
    const given = root orelse ".";
    const at = if (std.mem.eql(u8, std.fs.path.basename(given), file_name))
        std.fs.path.dirname(given) orelse "."
    else
        given;
    const absolute = if (io) |reach| try absoluteDirectory(gpa, reach, at) else try gpa.dupe(u8, at);
    return .{ .gpa = gpa, .io = io, .root = absolute, .cwd = cwd, .source = .init(seed) };
}

/// Read the project file at the root into `settings`. A root with none is
/// left with none, and is still somewhere to read files from; one that is
/// wrong is an error, with what and where in `diagnostics`.
pub fn loadSettings(self: *Project, diagnostics: ?*json.Diagnostics) ReadError!void {
    const io = self.io orelse return;
    const read = readSettings(self.gpa, io, self.root, diagnostics) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (self.settings) |*old| old.deinit();
    self.settings = read;
}

fn absoluteDirectory(gpa: Allocator, io: std.Io, path: []const u8) InitError![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buffer);
    return gpa.dupe(u8, buffer[0..len]);
}

pub fn deinit(self: *Project) void {
    if (self.settings) |*held| held.deinit();
    self.forget();
    self.by_uid.deinit(self.gpa);
    self.by_path.deinit(self.gpa);
    self.gpa.free(self.root);
    self.gpa.free(self.cwd);
    if (self.user_root) |held| self.gpa.free(held);
    if (self.fallback_name) |held| self.gpa.free(held);
    self.* = undefined;
}

/// Whether this is a path the project reads for itself: `res://` or
/// `uid://`.
pub fn isProjectPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, scheme) or std.mem.startsWith(u8, path, uid_scheme);
}

/// Whether this is a project path that could name a file: a `res://` one
/// that stays inside the root - see `tidy` - or a `uid://` one that holds a
/// UUID. Asks nothing of the disc.
pub fn isValidProjectPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, uid_scheme)) return parseUid(path) != null;
    if (!std.mem.startsWith(u8, path, scheme)) return false;
    const inside = path[scheme.len..];
    if (inside.len > 0 and std.fs.path.isSep(inside[0])) return false;
    if (inside.len > 1 and inside[1] == ':' and std.ascii.isAlphabetic(inside[0])) return false;
    var steps = std.mem.tokenizeAny(u8, inside, "/\\");
    while (steps.next()) |step| {
        if (std.mem.eql(u8, step, "..")) return false;
    }
    return true;
}

// -------------------------------------------------------------------------
// Paths
// -------------------------------------------------------------------------

/// The name a file is kept under: `res://` and its path from the root for a
/// file inside the project, however it was spelt - `art/./hero.png`, a
/// relative path, an absolute one, a `uid://` - and the operating system's
/// absolute path for one outside it. With no `Io`, as it is. The caller
/// frees it.
pub fn canonical(self: *Project, gpa: Allocator, path: []const u8) Error![]u8 {
    inline for (.{ scheme, user_scheme }) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            const inside = try tidy(gpa, path[prefix.len..]);
            defer gpa.free(inside);
            return std.mem.concat(gpa, u8, &.{ prefix, inside });
        }
    }
    if (std.mem.startsWith(u8, path, uid_scheme)) {
        return gpa.dupe(u8, try self.pathOfUidPath(path));
    }
    if (self.io == null) return gpa.dupe(u8, path);

    const absolute = try std.fs.path.resolve(gpa, &.{ self.cwd, path });
    const inside = self.within(absolute) orelse return absolute;
    defer gpa.free(absolute);
    const named = try std.mem.concat(gpa, u8, &.{ scheme, inside });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, named, std.fs.path.sep, '/');
    return named;
}

/// The operating system's path for any path the engine takes: `res://` under
/// the root, `uid://` wherever its file is, `user://` under `userRoot`, any
/// other path as it is. The caller frees it.
pub fn osPath(self: *Project, gpa: Allocator, path: []const u8) Error![]u8 {
    if (std.mem.startsWith(u8, path, user_scheme)) return joinUnder(gpa, try self.userRoot(), path[user_scheme.len..]);
    const project_path = if (std.mem.startsWith(u8, path, uid_scheme))
        try self.pathOfUidPath(path)
    else
        path;
    if (!std.mem.startsWith(u8, project_path, scheme)) return gpa.dupe(u8, path);

    return underRoot(gpa, self.root, project_path);
}

/// Where a `res://` path is under `root`: `osPath` with no project, and so
/// nothing but arithmetic on the two - what a thread of its own can ask. A
/// path that is not `res://` is itself.
pub fn underRoot(gpa: Allocator, root: []const u8, path: []const u8) Error![]u8 {
    if (!std.mem.startsWith(u8, path, scheme)) return gpa.dupe(u8, path);
    return joinUnder(gpa, root, path[scheme.len..]);
}

/// `inside`, tidied, under `base`, in the system's spelling.
fn joinUnder(gpa: Allocator, base: []const u8, inside_given: []const u8) Error![]u8 {
    const inside = try tidy(gpa, inside_given);
    defer gpa.free(inside);
    const joined = if (inside.len == 0) try gpa.dupe(u8, base) else try std.fs.path.join(gpa, &.{ base, inside });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, joined, '/', std.fs.path.sep);
    return joined;
}

/// Where `user://` is: a folder of the game's own under the one the system
/// keeps for programs' data - `%APPDATA%` on Windows, `~/.local/share` on
/// Linux, `~/Library/Application Support` on a Mac - named after the game:
/// the project file's `application.name`, or what the game called itself -
/// or where its `application.user_folder` says, a step or more:
/// `Studio/Game`. Worked out once; the folder is made when something is
/// written in it.
pub fn userRoot(self: *Project) Error![]const u8 {
    if (self.user_root) |held| return held;
    const io = self.io orelse return error.NoUserFolder;
    const data = folders.path(self.gpa, io, .data) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NoUserFolder,
    };
    defer self.gpa.free(data);

    const asked = if (self.settings) |held| held.application.user_folder else "";
    var names: [8][128]u8 = undefined;
    var steps: [9][]const u8 = undefined;
    steps[0] = data;
    var count: usize = 1;
    var given = std.mem.tokenizeAny(u8, asked, "/\\");
    while (given.next()) |step| {
        if (count == steps.len) break;
        steps[count] = folderName(&names[count - 1], step);
        count += 1;
    }
    if (count == 1) {
        steps[1] = folderName(&names[0], self.gameName());
        count = 2;
    }
    self.user_root = try std.fs.path.join(self.gpa, steps[0..count]);
    return self.user_root.?;
}

/// The name a game gives the file at `path`: `user://` inside the player's
/// folder, `res://` inside the project, and the system's own path for
/// anything else - what `osPath` turns back into it. The player's folder is
/// the nearer where it is inside the project. The caller frees it.
pub fn localPath(self: *Project, gpa: Allocator, path: []const u8) Error![]u8 {
    const named = try self.canonical(gpa, path);
    if (std.mem.startsWith(u8, named, user_scheme) or self.io == null) return named;
    const given = self.userRoot() catch return named;
    const user = try std.fs.path.resolve(gpa, &.{ self.cwd, given });
    defer gpa.free(user);
    const file = try self.osPath(gpa, named);
    defer gpa.free(file);
    const absolute = try std.fs.path.resolve(gpa, &.{ self.cwd, file });
    defer gpa.free(absolute);

    const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(absolute, user) else std.mem.eql(u8, absolute, user);
    if (same) {
        gpa.free(named);
        return gpa.dupe(u8, user_scheme);
    }
    const inside = below(user, absolute) orelse return named;
    defer gpa.free(named);
    const out = try std.mem.concat(gpa, u8, &.{ user_scheme, inside });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// What the game is called, for its folder.
fn gameName(self: *const Project) []const u8 {
    if (self.settings) |held| if (held.application.name.len > 0) return held.application.name;
    return self.fallback_name orelse "fluxion";
}

/// A name as a folder can be called on any system: letters, digits, spaces,
/// `-`, `_` and `.`, and `_` for the rest; never empty, nor ending in a dot
/// or a space, which Windows does not keep.
pub fn folderName(buffer: []u8, name: []const u8) []const u8 {
    var len: usize = 0;
    for (name) |c| {
        if (len == buffer.len) break;
        const kept = std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_' or c == '.' or c >= 0x80;
        buffer[len] = if (kept) c else '_';
        len += 1;
    }
    var trimmed = std.mem.trim(u8, buffer[0..len], " .");
    if (trimmed.len == 0) trimmed = "fluxion";
    return trimmed;
}

/// The part of an absolute path below the root, or null for one that is not
/// below it. Letter case is the file system's business on Windows, so it is
/// not compared there.
fn within(self: *const Project, absolute: []const u8) ?[]const u8 {
    return below(self.root, absolute);
}

/// The part of an absolute path below `root`, as `within` finds it.
fn below(root: []const u8, absolute: []const u8) ?[]const u8 {
    if (absolute.len <= root.len) return null;
    const head = absolute[0..root.len];
    const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(head, root) else std.mem.eql(u8, head, root);
    if (!same) return null;
    // A root that is a drive or `/` ends in its separator already.
    if (std.fs.path.isSep(root[root.len - 1])) return absolute[root.len..];
    if (!std.fs.path.isSep(absolute[root.len])) return null;
    return absolute[root.len + 1 ..];
}

/// A path from the root with its `.` and empty steps taken out, or
/// `OutsideProject` for one that climbs out with `..` or starts from a root
/// or a drive of its own.
fn tidy(gpa: Allocator, inside: []const u8) Error![]u8 {
    if (inside.len > 0 and std.fs.path.isSep(inside[0])) return error.OutsideProject;
    if (inside.len > 1 and inside[1] == ':' and std.ascii.isAlphabetic(inside[0])) return error.OutsideProject;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var steps = std.mem.tokenizeAny(u8, inside, "/\\");
    while (steps.next()) |step| {
        if (std.mem.eql(u8, step, ".")) continue;
        if (std.mem.eql(u8, step, "..")) return error.OutsideProject;
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, step);
    }
    return out.toOwnedSlice(gpa);
}

// -------------------------------------------------------------------------
// UUIDs
// -------------------------------------------------------------------------

/// The UUID a project file is known by already, asking nothing of the disc:
/// read from its `.uid` file when it was loaded, or made for it since.
pub fn knownUid(self: *const Project, project_path: []const u8) ?Uuid {
    return self.by_path.get(project_path);
}

/// The UUID in the `.uid` file beside a project file, or null when there is
/// none.
pub fn uidOf(self: *Project, project_path: []const u8) UidError!?Uuid {
    if (self.by_path.get(project_path)) |known| return known;
    const io = self.io orelse return null;
    const file = try self.osPath(self.gpa, project_path);
    defer self.gpa.free(file);
    const kept = try std.mem.concat(self.gpa, u8, &.{ file, uid_extension });
    defer self.gpa.free(kept);

    const text = std.Io.Dir.cwd().readFileAlloc(io, kept, self.gpa, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer self.gpa.free(text);
    const uid = parseUid(text) orelse return error.InvalidUid;
    try self.remember(uid, project_path);
    return uid;
}

/// A project file's UUID, made and written into a `.uid` file beside it if
/// it has none - which is an author's act, done by saving a scene, not by a
/// game loading one.
pub fn ensureUid(self: *Project, project_path: []const u8) (UidError || std.Io.Dir.WriteFileError || error{NoIo})!Uuid {
    if (try self.uidOf(project_path)) |held| return held;
    const io = self.io orelse return error.NoIo;
    const uid = self.newUid();

    const file = try self.osPath(self.gpa, project_path);
    defer self.gpa.free(file);
    const kept = try std.mem.concat(self.gpa, u8, &.{ file, uid_extension });
    defer self.gpa.free(kept);
    var line: [uid_scheme.len + Uuid.string_len + 1]u8 = undefined;
    const text = std.fmt.bufPrint(&line, uid_scheme ++ "{f}\n", .{uid}) catch unreachable;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kept, .data = text });
    try self.remember(uid, project_path);
    return uid;
}

/// A new random UUID, version 4, for a file.
pub fn newUid(self: *Project) Uuid {
    return .random(self.source.random());
}

/// The project path of the file whose `.uid` holds `uid`. One not seen yet
/// sends the engine through the project, once: `rescan` for another look.
pub fn pathOf(self: *Project, uid: Uuid) Allocator.Error!?[]const u8 {
    if (self.by_uid.get(uid)) |path| return path;
    if (self.scanned) return null;
    try self.scan();
    return self.by_uid.get(uid);
}

/// Forget where every UUID's file was, and look through the project again:
/// after files were moved while the program ran.
pub fn rescan(self: *Project) Allocator.Error!void {
    self.forget();
    try self.scan();
}

fn pathOfUidPath(self: *Project, path: []const u8) Error![]const u8 {
    const uid = parseUid(path) orelse return error.NoSuchUid;
    return (try self.pathOf(uid)) orelse error.NoSuchUid;
}

/// A UUID from `uid://...`, with or without the scheme, and with space
/// around it.
fn parseUid(text: []const u8) ?Uuid {
    var body = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, body, uid_scheme)) body = body[uid_scheme.len..];
    return Uuid.parse(body) catch null;
}

/// That `uid` names the file at `project_path`. The first to say so wins: a
/// file copied with its `.uid` file is two files and one UUID, and the copy
/// is the one that has to be given a new one.
fn remember(self: *Project, uid: Uuid, project_path: []const u8) Allocator.Error!void {
    if (self.by_uid.contains(uid) or self.by_path.contains(project_path)) return;
    const owned = try self.gpa.dupe(u8, project_path);
    errdefer self.gpa.free(owned);
    try self.by_uid.ensureUnusedCapacity(self.gpa, 1);
    try self.by_path.put(self.gpa, owned, uid);
    self.by_uid.putAssumeCapacityNoClobber(uid, owned);
}

fn forget(self: *Project) void {
    var paths = self.by_uid.valueIterator();
    while (paths.next()) |path| self.gpa.free(path.*);
    self.by_uid.clearRetainingCapacity();
    self.by_path.clearRetainingCapacity();
    self.scanned = false;
}

/// Read every `.uid` file in the project whose file is still beside it. A
/// directory that cannot be read is passed over, not a reason to stop.
fn scan(self: *Project) Allocator.Error!void {
    self.scanned = true;
    const io = self.io orelse return;
    var root = std.Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = try root.walkSelectively(self.gpa);
    defer walker.deinit();

    while (true) {
        const entry = (walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        }) orelse break;
        switch (entry.kind) {
            .directory => if (!passedOver(entry.basename)) walker.enter(io, entry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            },
            .file => if (std.mem.endsWith(u8, entry.basename, uid_extension)) try self.learn(io, entry),
            else => {},
        }
    }
}

fn passedOver(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or
        std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg");
}

/// Remember one `.uid` file found by `scan`, if it reads and its file is
/// there.
fn learn(self: *Project, io: std.Io, entry: std.Io.Dir.Walker.Entry) Allocator.Error!void {
    const named = entry.basename[0 .. entry.basename.len - uid_extension.len];
    entry.dir.access(io, named, .{}) catch return;
    const text = entry.dir.readFileAlloc(io, entry.basename, self.gpa, .limited(256)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer self.gpa.free(text);
    const uid = parseUid(text) orelse {
        log.warn("{s} does not hold a UUID", .{entry.path});
        return;
    };

    const inside = entry.path[0 .. entry.path.len - uid_extension.len];
    const project_path = try std.mem.concat(self.gpa, u8, &.{ scheme, inside });
    defer self.gpa.free(project_path);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, project_path, std.fs.path.sep, '/');
    if (self.by_uid.get(uid)) |first| {
        if (!std.mem.eql(u8, first, project_path)) log.warn("{s} and {s} have one UUID; the first is kept", .{ first, project_path });
        return;
    }
    try self.remember(uid, project_path);
}

// -------------------------------------------------------------------------
// Moving and copying
// -------------------------------------------------------------------------

/// Move or rename a file or a folder, named as any path is, with its `.uid`
/// file: its UUID goes where it goes, so every scene that names it finds it
/// there. Never over something already at `to` - that is
/// `error.PathAlreadyExists` - and never into itself. The folder it goes into
/// has to be there. `App.moveFile` moves what was loaded from it as well.
pub fn moveFile(self: *Project, from: []const u8, to: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const gpa = self.gpa;
    const old = try self.canonical(gpa, from);
    defer gpa.free(old);
    const new = try self.canonical(gpa, to);
    defer gpa.free(new);
    const old_file = try self.osPath(gpa, old);
    defer gpa.free(old_file);
    const new_file = try self.osPath(gpa, new);
    defer gpa.free(new_file);
    if (std.mem.eql(u8, new, old)) return;
    if (under(new, old) != null) return error.InsideItself;

    // Another spelling of the one file - `hero.png` to `Hero.png` where
    // letter case is not told apart - is there already, and is a rename all
    // the same.
    const cwd = std.Io.Dir.cwd();
    const respelt = try sameFile(io, old_file, new_file);
    if (respelt) try cwd.rename(old_file, cwd, new_file, io) else try renameNew(io, old_file, new_file);

    // A file's UUID goes with it; a folder's files' `.uid` files are inside
    // it already. The file has moved either way, so a `.uid` file left
    // behind is said, not undone.
    const old_uid = try std.mem.concat(gpa, u8, &.{ old_file, uid_extension });
    defer gpa.free(old_uid);
    const new_uid = try std.mem.concat(gpa, u8, &.{ new_file, uid_extension });
    defer gpa.free(new_uid);
    if (cwd.access(io, old_uid, .{})) |_| {
        const moved = if (respelt) cwd.rename(old_uid, cwd, new_uid, io) else renameNew(io, old_uid, new_uid);
        moved catch |err| log.warn("{s} moved to {s}, and its {s} file did not: {t}", .{ old, new, uid_extension, err });
    } else |_| {}
    try self.repoint(old, new);
}

/// Whether `other` is `path` spelt another way - where letter case is not
/// told apart, on Windows or a Mac or a Windows drive under Linux - rather
/// than another file: the same file on the disc, when there is one there.
fn sameFile(io: std.Io, path: []const u8, other: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const there = cwd.statFile(io, other, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    const here = try cwd.statFile(io, path, .{});
    return here.inode == there.inode;
}

/// Copy a file, or a folder and everything in it, never over something
/// already at `to`. A copy is a file of its own: where the original has a
/// UUID, the copy is given a new one, so the two are never taken for each
/// other.
pub fn copyFile(self: *Project, from: []const u8, to: []const u8) !void {
    const io = self.io orelse return error.NoIo;
    const gpa = self.gpa;
    const old = try self.canonical(gpa, from);
    defer gpa.free(old);
    const new = try self.canonical(gpa, to);
    defer gpa.free(new);
    const old_file = try self.osPath(gpa, old);
    defer gpa.free(old_file);
    const new_file = try self.osPath(gpa, new);
    defer gpa.free(new_file);
    try refuseTaken(io, new_file);
    // A folder copied into itself would copy its copy, for ever.
    if (under(new, old) != null) return error.InsideItself;

    const cwd = std.Io.Dir.cwd();
    const kind = (try cwd.statFile(io, old_file, .{})).kind;
    if (kind != .directory) {
        try copyNew(io, cwd, old_file, cwd, new_file);
        const kept = try std.mem.concat(gpa, u8, &.{ old_file, uid_extension });
        defer gpa.free(kept);
        if (cwd.access(io, kept, .{})) |_| {
            const fresh = try std.mem.concat(gpa, u8, &.{ new_file, uid_extension });
            defer gpa.free(fresh);
            try self.giveNewUid(io, cwd, fresh, new);
        } else |_| {}
        return;
    }

    var source = try cwd.openDir(io, old_file, .{ .iterate = true });
    defer source.close(io);
    try cwd.createDir(io, new_file, .default_dir);
    var target = try cwd.openDir(io, new_file, .{});
    defer target.close(io);
    var walker = try source.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try target.createDirPath(io, entry.path),
        .file => if (std.mem.endsWith(u8, entry.basename, uid_extension)) {
            const inside = entry.path[0 .. entry.path.len - uid_extension.len];
            const named = try std.mem.concat(gpa, u8, &.{ new, "/", inside });
            defer gpa.free(named);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, named, std.fs.path.sep, '/');
            try self.giveNewUid(io, target, entry.path, named);
        } else try copyNew(io, entry.dir, entry.basename, target, entry.path),
        // A link is left out rather than followed out of the folder.
        else => {},
    };
}

/// Forget the UUIDs of the file at `path`, or of every file in a folder:
/// after it left the disc, so no UUID names a place with nothing there. A
/// scan finds it again if it comes back.
pub fn forgetFile(self: *Project, path: []const u8) Allocator.Error!void {
    const named = self.canonical(self.gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A path that names nothing here has nothing to forget.
        error.OutsideProject, error.NoSuchUid, error.NoUserFolder => return,
    };
    defer self.gpa.free(named);
    try self.repoint(named, null);
}

/// What comes after `folder` in `path`, when `path` is `folder` or is inside
/// it: `""`, or the rest from its separator on. Null otherwise. Asks nothing
/// of the disc.
pub fn under(path: []const u8, folder: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, folder)) return null;
    const rest = path[folder.len..];
    if (rest.len == 0) return rest;
    if (rest[0] == '/' or std.fs.path.isSep(rest[0])) return rest;
    return null;
}

/// Point the UUIDs of the file or folder at `old` at `new`, both as
/// `canonical` names them - or, with `new` null or outside the project,
/// forget them.
fn repoint(self: *Project, old: []const u8, new: ?[]const u8) Allocator.Error!void {
    var found: std.ArrayList([]const u8) = .empty;
    defer found.deinit(self.gpa);
    var it = self.by_path.keyIterator();
    while (it.next()) |path| {
        if (under(path.*, old) != null) try found.append(self.gpa, path.*);
    }
    for (found.items) |held| {
        defer self.gpa.free(held);
        const uid = self.by_path.fetchRemove(held).?.value;
        _ = self.by_uid.remove(uid);
        const to = new orelse continue;
        const moved = try std.mem.concat(self.gpa, u8, &.{ to, held[old.len..] });
        defer self.gpa.free(moved);
        if (std.mem.startsWith(u8, moved, scheme)) try self.remember(uid, moved);
    }
}

/// A `.uid` file at `sub_path` in `dir` with a UUID never given before, for
/// the file `project_path` names.
fn giveNewUid(self: *Project, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, project_path: []const u8) !void {
    const uid = self.newUid();
    var line: [uid_scheme.len + Uuid.string_len + 1]u8 = undefined;
    const text = std.fmt.bufPrint(&line, uid_scheme ++ "{f}\n", .{uid}) catch unreachable;
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = text, .flags = .{ .exclusive = true } });
    if (std.mem.startsWith(u8, project_path, scheme)) try self.remember(uid, project_path);
}

/// `error.PathAlreadyExists` when something is at `path`.
fn refuseTaken(io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
}

/// Whether a rename can be asked never to replace what is there, on every
/// drive: Windows promises it. Linux has it on most file systems and not on
/// some - a Windows drive under WSL, FUSE, older NFS - and there the standard
/// library takes the refusal for its own mistake, a panic in a debug build.
/// So elsewhere the name is looked at first, and taken in the moment after.
const atomic_new_names = builtin.os.tag == .windows;

/// A rename that never replaces what is at `to`.
fn renameNew(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (atomic_new_names) return cwd.renamePreserve(from, cwd, to, io);
    try refuseTaken(io, to);
    try cwd.rename(from, cwd, to, io);
}

/// A copy that never replaces what is at `to`, the same way.
fn copyNew(io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) !void {
    if (atomic_new_names) return std.Io.Dir.copyFile(from_dir, from, to_dir, to, io, .{ .replace = false });
    if (to_dir.access(io, to, .{})) |_| return error.PathAlreadyExists else |_| {}
    try std.Io.Dir.copyFile(from_dir, from, to_dir, to, io, .{});
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A project in a directory of its own, and that directory's path from the
/// working directory.
const Scratch = struct {
    tmp: testing.TmpDir,
    buffer: [128]u8 = undefined,
    path: []const u8 = "",

    fn init() Scratch {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn at(self: *Scratch) ![]const u8 {
        self.path = try std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        return self.path;
    }

    fn put(self: *Scratch, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "bytes" });
    }
};

test "a res:// path is under the root, and any other is the operating system's" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();

    const hero = try project.osPath(testing.allocator, "res://art/./hero.png");
    defer testing.allocator.free(hero);
    const expected = try std.fs.path.join(testing.allocator, &.{ project.root, "art", "hero.png" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, hero);

    const plain = try project.osPath(testing.allocator, "art/hero.png");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("art/hero.png", plain);

    try testing.expectError(error.OutsideProject, project.osPath(testing.allocator, "res://../secret.png"));
    try testing.expectError(error.OutsideProject, project.osPath(testing.allocator, "res://art/../../secret.png"));
    try testing.expectError(error.OutsideProject, project.osPath(testing.allocator, "res:///etc/passwd"));
    try testing.expectError(error.OutsideProject, project.osPath(testing.allocator, "res://C:/Windows/win.ini"));
}

test "a file inside the root is kept by its project path, however it was spelt" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();

    const spellings = [_][]const u8{ "res://art/hero.png", "res://art//./hero.png", "res://art\\hero.png" };
    for (spellings) |spelling| {
        const named = try project.canonical(testing.allocator, spelling);
        defer testing.allocator.free(named);
        try testing.expectEqualStrings("res://art/hero.png", named);
    }

    // The operating system's spelling of the same file, relative and
    // absolute.
    var buffer: [160]u8 = undefined;
    const relative = try std.fmt.bufPrint(&buffer, "{s}/art/hero.png", .{scratch.path});
    const from_cwd = try project.canonical(testing.allocator, relative);
    defer testing.allocator.free(from_cwd);
    try testing.expectEqualStrings("res://art/hero.png", from_cwd);

    const absolute = try std.fs.path.join(testing.allocator, &.{ project.root, "art", "hero.png" });
    defer testing.allocator.free(absolute);
    const from_root = try project.canonical(testing.allocator, absolute);
    defer testing.allocator.free(from_root);
    try testing.expectEqualStrings("res://art/hero.png", from_root);

    // Outside the project, the absolute path it is.
    const outside = try project.canonical(testing.allocator, "build.zig");
    defer testing.allocator.free(outside);
    try testing.expect(std.fs.path.isAbsolute(outside));
    try testing.expect(std.mem.endsWith(u8, outside, "build.zig"));

    // A directory beside the root whose name starts with the root's is not
    // inside it.
    const sibling = try std.mem.concat(testing.allocator, u8, &.{ project.root, "2", std.fs.path.sep_str, "hero.png" });
    defer testing.allocator.free(sibling);
    const beside = try project.canonical(testing.allocator, sibling);
    defer testing.allocator.free(beside);
    try testing.expectEqualStrings(sibling, beside);
}

test "with no Io, paths are kept as they are given" {
    var project: Project = try .init(testing.allocator, null, "game");
    defer project.deinit();
    const plain = try project.canonical(testing.allocator, "art/hero.png");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("art/hero.png", plain);
    try testing.expectEqual(@as(?Uuid, null), try project.uidOf("res://art/hero.png"));
    try testing.expectError(error.NoIo, project.ensureUid("res://art/hero.png"));
}

test "a file's UUID is made once, kept beside it, and read back by another run" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/hero.png");

    var first: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer first.deinit();
    try testing.expectEqual(@as(?Uuid, null), try first.uidOf("res://art/hero.png"));
    const made = try first.ensureUid("res://art/hero.png");
    try testing.expect(made.eql(try first.ensureUid("res://art/hero.png")));
    try testing.expectEqual(@as(u4, 4), made.version());

    var kept: [64]u8 = undefined;
    const text = try scratch.tmp.dir.readFile(testing.io, "art/hero.png.uid", &kept);
    try testing.expectEqualStrings(uid_scheme ++ made.toString() ++ "\n", text);

    var second: Project = try .init(testing.allocator, testing.io, scratch.path);
    defer second.deinit();
    try testing.expect(made.eql((try second.uidOf("res://art/hero.png")).?));
}

test "a file moved with its .uid file is found where it went" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/hero.png");

    var before: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer before.deinit();
    const uid = try before.ensureUid("res://art/hero.png");

    try scratch.tmp.dir.createDirPath(testing.io, "art/people");
    try scratch.tmp.dir.rename("art/hero.png", scratch.tmp.dir, "art/people/hero.png", testing.io);
    try scratch.tmp.dir.rename("art/hero.png.uid", scratch.tmp.dir, "art/people/hero.png.uid", testing.io);

    var after: Project = try .init(testing.allocator, testing.io, scratch.path);
    defer after.deinit();
    try testing.expectEqualStrings("res://art/people/hero.png", (try after.pathOf(uid)).?);

    var buffer: [64]u8 = undefined;
    const by_uid = try std.fmt.bufPrint(&buffer, uid_scheme ++ "{f}", .{uid});
    const named = try after.canonical(testing.allocator, by_uid);
    defer testing.allocator.free(named);
    try testing.expectEqualStrings("res://art/people/hero.png", named);

    // The one that did not move is found by the path it had, again.
    try testing.expect(before.knownUid("res://art/hero.png").?.eql(uid));
    try before.rescan();
    try testing.expect(before.knownUid("res://art/hero.png") == null);
    try testing.expectEqualStrings("res://art/people/hero.png", (try before.pathOf(uid)).?);
}

test "a UUID no file holds is no path, and hidden and built directories are not looked in" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put(".hidden/a.png");
    try scratch.put("zig-out/b.png");
    try scratch.put("lonely.png.uid");
    const hidden: Uuid = .parseComptime("11111111-1111-4111-8111-111111111111");
    const built: Uuid = .parseComptime("22222222-2222-4222-8222-222222222222");
    const orphan: Uuid = .parseComptime("33333333-3333-4333-8333-333333333333");
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = ".hidden/a.png.uid", .data = uid_scheme ++ hidden.toString() });
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/b.png.uid", .data = uid_scheme ++ built.toString() });
    try scratch.tmp.dir.writeFile(testing.io, .{ .sub_path = "lonely.png.uid", .data = uid_scheme ++ orphan.toString() });

    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();
    try testing.expect(try project.pathOf(hidden) == null);
    try testing.expect(try project.pathOf(built) == null);
    // A `.uid` file whose file has gone names nothing.
    try testing.expect(try project.pathOf(orphan) == null);
    try testing.expectError(error.NoSuchUid, project.canonical(testing.allocator, "uid://" ++ orphan.toString()));
    try testing.expectError(error.NoSuchUid, project.osPath(testing.allocator, "uid://not-a-uuid"));
}

/// Whether the directory `folder` has an entry spelt exactly `name`: what
/// `access` cannot say where letter case is not told apart.
fn listed(dir: std.Io.Dir, folder: []const u8, name: []const u8) !bool {
    var inside = try dir.openDir(testing.io, folder, .{ .iterate = true });
    defer inside.close(testing.io);
    var it = inside.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "user:// is a folder of the game's own, named as the project names the game" {
    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    project.user_root = try testing.allocator.dupe(u8, "saves-here");
    const path = try project.osPath(testing.allocator, "user://slots/./one.json");
    defer testing.allocator.free(path);
    const expected = try std.fs.path.join(testing.allocator, &.{ "saves-here", "slots", "one.json" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, path);
    try testing.expectError(error.OutsideProject, project.osPath(testing.allocator, "user://../escape.json"));
    const kept = try project.canonical(testing.allocator, "user://slots//./one.json");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("user://slots/one.json", kept);

    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("Five Nights_ Demo", folderName(&buffer, "Five Nights: Demo."));
    try testing.expectEqualStrings("fluxion", folderName(&buffer, "..."));

    // Given no folder, it is one named after the game in the system's.
    var named: Project = try .init(testing.allocator, testing.io, null);
    defer named.deinit();
    named.fallback_name = try testing.allocator.dupe(u8, "Night: Shift");
    const where = named.userRoot() catch |err| switch (err) {
        error.NoUserFolder => return, // a system that keeps none
        else => return err,
    };
    try testing.expectEqualStrings("Night_ Shift", std.fs.path.basename(where));
    try testing.expect(std.fs.path.isAbsolute(where));
}

test "a file moved takes its UUID along, and never goes over another or into itself" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/hero.png");
    try scratch.put("art/tree.png");
    try scratch.tmp.dir.createDirPath(testing.io, "art/people");
    const dir = scratch.tmp.dir;

    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();
    const uid = try project.ensureUid("res://art/hero.png");

    try project.moveFile("res://art/hero.png", "res://art/people/ada.png");
    try dir.access(testing.io, "art/people/ada.png", .{});
    try dir.access(testing.io, "art/people/ada.png.uid", .{});
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/hero.png.uid", .{}));
    // Known where it went without another look through the project.
    try testing.expect(project.knownUid("res://art/people/ada.png").?.eql(uid));
    try testing.expect(project.knownUid("res://art/hero.png") == null);

    // Over a file already there, and into itself: refused, and nothing moved.
    try testing.expectError(error.PathAlreadyExists, project.moveFile("res://art/tree.png", "res://art/people/ada.png"));
    try testing.expectError(error.InsideItself, project.moveFile("res://art", "res://art/people/art"));
    try dir.access(testing.io, "art/tree.png", .{});

    // Only its letters' case changed: a rename of the one file, wherever
    // case is not told apart too.
    try project.moveFile("res://art/people/ada.png", "res://art/people/Ada.png");
    try testing.expect(try listed(dir, "art/people", "Ada.png"));
    try testing.expect(try listed(dir, "art/people", "Ada.png.uid"));
    try testing.expect(!try listed(dir, "art/people", "ada.png"));
    try testing.expectEqualStrings("res://art/people/Ada.png", (try project.pathOf(uid)).?);

    // To where it is already: nothing to do.
    try project.moveFile("res://art/tree.png", "res://art/./tree.png");
    try dir.access(testing.io, "art/tree.png", .{});
}

test "a folder moved takes the UUID of every file in it along, and none beside it" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/people/ada.png");
    try scratch.put("art/people/deep/bo.png");
    try scratch.put("art/peoples/cy.png");

    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();
    const ada = try project.ensureUid("res://art/people/ada.png");
    const bo = try project.ensureUid("res://art/people/deep/bo.png");
    const cy = try project.ensureUid("res://art/peoples/cy.png");

    // Onto a folder already there: refused, as a file is.
    try testing.expectError(error.PathAlreadyExists, project.moveFile("res://art/people", "res://art/peoples"));

    try project.moveFile("res://art/people", "res://crowd");
    try testing.expectEqualStrings("res://crowd/ada.png", project.by_uid.get(ada).?);
    try testing.expectEqualStrings("res://crowd/deep/bo.png", project.by_uid.get(bo).?);
    try testing.expectEqualStrings("res://art/peoples/cy.png", project.by_uid.get(cy).?);
    try scratch.tmp.dir.access(testing.io, "crowd/deep/bo.png.uid", .{});

    // Another run, which reads the `.uid` files where they went.
    var fresh: Project = try .init(testing.allocator, testing.io, scratch.path);
    defer fresh.deinit();
    try testing.expectEqualStrings("res://crowd/deep/bo.png", (try fresh.pathOf(bo)).?);
}

test "a copy is a file of its own, with a UUID of its own where the original has one" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/hero.png");
    try scratch.put("art/tree.png");
    try scratch.put("art/people/ada.png");
    try scratch.put("art/people/deep/bo.png");
    const dir = scratch.tmp.dir;

    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();
    const hero = try project.ensureUid("res://art/hero.png");
    const ada = try project.ensureUid("res://art/people/ada.png");

    try project.copyFile("res://art/hero.png", "res://art/hero copy.png");
    var bytes: [16]u8 = undefined;
    try testing.expectEqualStrings("bytes", try dir.readFile(testing.io, "art/hero copy.png", &bytes));
    const copied = project.knownUid("res://art/hero copy.png").?;
    try testing.expect(!copied.eql(hero));
    try testing.expectEqualStrings("res://art/hero.png", (try project.pathOf(hero)).?);

    // One with no UUID is copied with none.
    try project.copyFile("res://art/tree.png", "res://art/tree copy.png");
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/tree copy.png.uid", .{}));

    // A folder, and everything in it.
    try project.copyFile("res://art/people", "res://art/crowd");
    try dir.access(testing.io, "art/crowd/deep/bo.png", .{});
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/crowd/deep/bo.png.uid", .{}));
    const crowd = project.knownUid("res://art/crowd/ada.png").?;
    try testing.expect(!crowd.eql(ada));
    var fresh: Project = try .init(testing.allocator, testing.io, scratch.path);
    defer fresh.deinit();
    try testing.expect(crowd.eql((try fresh.uidOf("res://art/crowd/ada.png")).?));

    try testing.expectError(error.PathAlreadyExists, project.copyFile("res://art/tree.png", "res://art/hero.png"));
    try testing.expectError(error.PathAlreadyExists, project.copyFile("res://art/tree.png", "res://art/tree.png"));
    try testing.expectError(error.InsideItself, project.copyFile("res://art", "res://art/crowd/art"));
    try testing.expectEqualStrings("bytes", try dir.readFile(testing.io, "art/hero.png", &bytes));
}

test "a file forgotten leaves its UUID naming nothing, and a folder every UUID in it" {
    var scratch: Scratch = .init();
    defer scratch.tmp.cleanup();
    try scratch.put("art/hero.png");
    try scratch.put("art/people/ada.png");
    try scratch.put("music/song.ogg");

    var project: Project = try .init(testing.allocator, testing.io, try scratch.at());
    defer project.deinit();
    const hero = try project.ensureUid("res://art/hero.png");
    const ada = try project.ensureUid("res://art/people/ada.png");
    const song = try project.ensureUid("res://music/song.ogg");

    try project.forgetFile("res://art");
    try testing.expect(project.by_uid.get(hero) == null);
    try testing.expect(project.by_uid.get(ada) == null);
    try testing.expect(project.knownUid("res://art/hero.png") == null);
    try testing.expect(project.by_uid.get(song) != null);
    // What is not the project's has nothing to forget.
    try project.forgetFile("res://../elsewhere");
}

test "a path is under a folder only past a separator" {
    try testing.expectEqualStrings("", under("res://art", "res://art").?);
    try testing.expectEqualStrings("/hero.png", under("res://art/hero.png", "res://art").?);
    try testing.expect(under("res://artwork/hero.png", "res://art") == null);
    try testing.expect(under("res://ar", "res://art") == null);
}
