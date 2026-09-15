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
//! `art/hero.png.uid`, one line, `uid://...` - as Godot 4 keeps its. A scene
//! names a file by its UUID as well as by its path, and reading one goes by
//! the UUID first, so a texture moved or renamed together with its `.uid` file
//! is found where it went. A `uid://` path is taken wherever a `res://` one is.
//!
//! Where a UUID's file is, is learnt from the `.uid` files read along the way;
//! one nobody has read yet sends the engine through the whole project once,
//! passing over hidden directories - `.git`, `.zig-cache` - and `zig-out` and
//! `zig-pkg`, which are built rather than written.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const Uuid = @import("fluxion_id").Uuid;

const settings_file = @import("project/settings.zig");

const Project = @This();
const log = std.log.scoped(.fluxion_engine);

/// What a project's file is called, at its root: `project.fluxion`.
pub const file_name = settings_file.file_name;

/// What a project file says: its name, its renderer, its icon and the rest.
/// See `project/settings.zig`.
pub const Settings = settings_file.Settings;

/// Which family of graphics APIs a project is drawn with, and its backends
/// on each system.
pub const Renderer = settings_file.Renderer;

pub const ReadError = settings_file.ReadError;
pub const WriteError = settings_file.WriteError;
pub const CreateError = settings_file.CreateError;

/// The project file in a folder, read with no `App` and no GPU: what a
/// project manager lists projects by.
pub const readSettings = settings_file.read;

/// Write a folder's project file in place of the one there.
pub const writeSettings = settings_file.write;

/// Make a new project: its folder and its project file.
pub const create = settings_file.create;

/// What a project path starts with.
pub const scheme = "res://";

/// What a path naming a file by its UUID starts with.
pub const uid_scheme = "uid://";

/// What is added to a file's name for the file its UUID is kept in.
pub const uid_extension = ".uid";

pub const Error = error{
    /// A `res://` path that climbs out of the project with `..`, or that
    /// names a root or a drive of its own.
    OutsideProject,
    /// A `uid://` path whose UUID does not read, or that no `.uid` file in
    /// the project holds.
    NoSuchUid,
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
    if (std.mem.startsWith(u8, path, scheme)) {
        const inside = try tidy(gpa, path[scheme.len..]);
        defer gpa.free(inside);
        return std.mem.concat(gpa, u8, &.{ scheme, inside });
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
/// the root, `uid://` wherever its file is, any other path as it is. The
/// caller frees it.
pub fn osPath(self: *Project, gpa: Allocator, path: []const u8) Error![]u8 {
    const project_path = if (std.mem.startsWith(u8, path, uid_scheme))
        try self.pathOfUidPath(path)
    else
        path;
    if (!std.mem.startsWith(u8, project_path, scheme)) return gpa.dupe(u8, path);

    const inside = try tidy(gpa, project_path[scheme.len..]);
    defer gpa.free(inside);
    const joined = if (inside.len == 0) try gpa.dupe(u8, self.root) else try std.fs.path.join(gpa, &.{ self.root, inside });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, joined, '/', std.fs.path.sep);
    return joined;
}

/// The part of an absolute path below the root, or null for one that is not
/// below it. Letter case is the file system's business on Windows, so it is
/// not compared there.
fn within(self: *const Project, absolute: []const u8) ?[]const u8 {
    const root = self.root;
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
