// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `files`: the game's own files to read, the
//! player's to read and write, and no others - and a `Config` of sections
//! and keys kept in one of them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const json = @import("fluxion_json");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const Project = @import("../project/Project.zig");
const Color = @import("../math/color.zig").Color;
const datetime = @import("../time/datetime.zig");
const ConfigFile = @import("../files/config_file.zig").ConfigFile;
const dialog = @import("../platform/dialog.zig");

const Scripts = @import("script.zig").Scripts;
const jsonOf = @import("script.zig").jsonOf;

/// What a script reaches as `files`: the files a game ships to read, and the
/// player's own under `user://` to read and write. Nothing else on the
/// computer - a path anywhere else is `error.NotAllowed` - so a script can
/// neither read the player's documents nor break the game it came with.
/// A call that fails gives an error to `catch`: `FileNotFound`,
/// `NotAllowed`, and whatever else the system said.
///
/// ```
/// const slot = files.join("user://saves", files.validName(player_name) + ".json");
/// files.writeText(slot, json.stringify(state)) catch |err| print(err);
/// print(files.modifiedTime(slot).relative());          // 5 minutes ago
/// files.writeSecret("user://progress.sav", json.stringify(progress), "a password");
/// const settings = files.config("user://settings.cfg");
/// settings.set("audio", "music", 0.8);
/// settings.save();
/// ```
pub const FileAccess = struct {
    app: *App,

    pub const reflect_name = "Files";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .readText = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8), flux.GivesErrors{} },
        .writeText = .{ attr.Params{ .names = &.{ "path", "text" } }, flux.GivesErrors{} },
        .appendText = .{ attr.Params{ .names = &.{ "path", "text" } }, flux.GivesErrors{} },
        .exists = .{attr.Params{ .names = &.{"path"} }},
        .isDir = .{attr.Params{ .names = &.{"path"} }},
        .makeDir = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .list = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const []const u8), flux.GivesErrors{} },
        .remove = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .copy = .{ attr.Params{ .names = &.{ "from", "to", "replace" } }, attr.defaults(.{false}), flux.GivesErrors{} },
        .move = .{ attr.Params{ .names = &.{ "from", "to", "replace" } }, attr.defaults(.{false}), flux.GivesErrors{} },
        .size = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .modifiedTime = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .sha256 = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8), flux.GivesErrors{} },
        .writeCompressed = .{ attr.Params{ .names = &.{ "path", "text" } }, flux.GivesErrors{} },
        .readCompressed = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8), flux.GivesErrors{} },
        .writeSecret = .{ attr.Params{ .names = &.{ "path", "text", "password" } }, flux.GivesErrors{} },
        .readSecret = .{ attr.Params{ .names = &.{ "vm", "path", "password" } }, flux.Returns.of([]const u8), flux.GivesErrors{} },
        .config = .{ attr.Params{ .names = &.{ "vm", "path", "password" } }, attr.defaults(.{""}), flux.Returns.of(ConfigRef), flux.GivesErrors{} },
        .writeData = .{ attr.Params{ .names = &.{ "value", "path" } }, flux.GivesErrors{} },
        .readData = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .join = .{ attr.Params{ .names = &.{ "vm", "path", "name" } }, flux.Returns.of([]const u8) },
        .dirName = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .fileName = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .stem = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .extension = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .isValidName = .{attr.Params{ .names = &.{"name"} }},
        .validName = .{ attr.Params{ .names = &.{ "vm", "name" } }, flux.Returns.of([]const u8) },
        .globalPath = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .localPath = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of([]const u8) },
        .open = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .showInFolder = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .choose = .{ attr.Params{ .names = &.{ "vm", "title", "extensions", "many" } }, attr.defaults(.{ "", flux.Value.null, false }), flux.Returns{ .builtin = .signal }, flux.GivesErrors{} },
        .dropped = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns{ .builtin = .signal } },
    };

    /// The text of a file: the game's (`res://`) or the player's
    /// (`user://`).
    pub fn readText(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const text = try self.app.readText(self.app.gpa, path);
        defer self.app.gpa.free(text);
        return flux.bind.toValue(vm, text);
    }

    /// Write a file under `user://`, over what it held, and the folders it
    /// is in. A game stopped halfway through leaves the old file whole.
    pub fn writeText(self: *FileAccess, path: []const u8, text: []const u8) anyerror!void {
        try writable(path);
        try self.app.writeText(path, text);
    }

    /// Add to the end of a file under `user://`, making it when there is
    /// none: a log, a line at a time.
    pub fn appendText(self: *FileAccess, path: []const u8, text: []const u8) anyerror!void {
        try writable(path);
        try self.app.appendText(path, text);
    }

    /// Whether there is a file or a folder there - false for a path a
    /// script may not read.
    pub fn exists(self: *FileAccess, path: []const u8) bool {
        mayRead(self.app, path) catch return false;
        return self.app.fileExists(path);
    }

    /// Whether there is a folder there.
    pub fn isDir(self: *FileAccess, path: []const u8) bool {
        mayRead(self.app, path) catch return false;
        return self.app.isDir(path);
    }

    /// Make a folder under `user://`, and the ones it is in.
    pub fn makeDir(self: *FileAccess, path: []const u8) anyerror!void {
        try writable(path);
        try self.app.makeDir(path);
    }

    /// The names in a folder, sorted; a folder's end with `/`.
    pub fn list(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const listed = try self.app.listDir(self.app.gpa, path);
        defer listed.deinit(self.app.gpa);
        return flux.bind.toValue(vm, listed.names);
    }

    /// Take out a file under `user://`, or a folder with nothing in it.
    pub fn remove(self: *FileAccess, path: []const u8) anyerror!void {
        try writable(path);
        try self.app.removeFile(path);
    }

    /// Copy a file - or a folder, and all in it - to `to`, under `user://`,
    /// making the folders it goes in. Never over what is there, unless
    /// `replace` says so: `error.PathAlreadyExists`.
    pub fn copy(self: *FileAccess, from: []const u8, to: []const u8, replace: bool) anyerror!void {
        try mayRead(self.app, from);
        try self.makeRoomFor(to, replace);
        try self.app.copyFile(from, to);
    }

    /// Move or rename a file or a folder under `user://`, as `copy` does.
    pub fn move(self: *FileAccess, from: []const u8, to: []const u8, replace: bool) anyerror!void {
        try writable(from);
        try self.makeRoomFor(to, replace);
        try self.app.moveFile(from, to);
    }

    fn makeRoomFor(self: *FileAccess, to: []const u8, replace: bool) anyerror!void {
        try writable(to);
        if (replace and self.app.fileExists(to)) try self.app.removeFile(to);
        const folder = dirNameOf(to);
        if (folder.len > Project.user_scheme.len) try self.app.makeDir(folder);
    }

    /// A file's size in bytes; nought for a folder.
    pub fn size(self: *FileAccess, path: []const u8) anyerror!i64 {
        try mayRead(self.app, path);
        return @intCast((try self.app.fileInfo(path)).size);
    }

    /// When a file was last written, in the player's time: what a save slot
    /// shows as `modifiedTime(slot).relative()`.
    pub fn modifiedTime(self: *FileAccess, path: []const u8) anyerror!datetime.DateTime {
        try mayRead(self.app, path);
        return (try self.app.fileInfo(path)).modified.in(.local);
    }

    /// A file's SHA-256, as 64 hexadecimal digits.
    pub fn sha256(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const digest = try self.app.fileSha256(path);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return vm.string(&hex);
    }

    /// Write text under `user://` as gzip: a tenth of the room.
    pub fn writeCompressed(self: *FileAccess, path: []const u8, text: []const u8) anyerror!void {
        try writable(path);
        try self.app.writeCompressed(path, text);
    }

    /// The text of a file `writeCompressed` wrote.
    pub fn readCompressed(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const text = try self.app.readCompressed(self.app.gpa, path);
        defer self.app.gpa.free(text);
        return flux.bind.toValue(vm, text);
    }

    /// Write text under `user://` compressed and sealed with a password:
    /// the player can neither read it nor change it and have the game take
    /// it.
    pub fn writeSecret(self: *FileAccess, path: []const u8, text: []const u8, password: []const u8) anyerror!void {
        try writable(path);
        try self.app.writeSecret(path, text, password);
    }

    /// The text of a file `writeSecret` wrote: `error.CannotOpen` with
    /// another password, or once it was changed.
    pub fn readSecret(self: *FileAccess, vm: *flux.Vm, path: []const u8, password: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const text = try self.app.readSecret(self.app.gpa, path, password);
        defer self.app.gpa.free(text);
        return flux.bind.toValue(vm, text);
    }

    /// The settings file at `path` - see `Config` - empty when there is no
    /// file yet. With a password, it is read and saved sealed.
    pub fn config(self: *FileAccess, vm: *flux.Vm, path: []const u8, password: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        var held = if (password.len == 0)
            try ConfigFile.load(self.app, path)
        else blk: {
            const text = self.app.readSecret(self.app.gpa, path, password) catch |err| switch (err) {
                error.FileNotFound => break :blk try ConfigFile.init(self.app.gpa),
                else => return err,
            };
            defer self.app.gpa.free(text);
            break :blk try ConfigFile.parse(self.app.gpa, text, null);
        };
        errdefer held.deinit();
        const ref = try vm.gpa.create(ConfigRef);
        errdefer vm.gpa.destroy(ref);
        const kept_path = try vm.gpa.dupe(u8, path);
        errdefer vm.gpa.free(kept_path);
        const kept_password = try vm.gpa.dupe(u8, password);
        errdefer vm.gpa.free(kept_password);
        ref.* = .{ .app = self.app, .held = held, .path = kept_path, .password = kept_password };
        return vm.adoptHandle(ref);
    }

    /// Write a struct of a script's as a data file under `user://`: its
    /// `@export` fields' values, which `readData` makes it again from - a
    /// save as a struct.
    pub fn writeData(self: *FileAccess, value: flux.Value, path: []const u8) anyerror!void {
        try writable(path);
        try self.app.writeData(value, path);
    }

    /// A data file's struct, made anew with the file's values: the game's
    /// (`res://`) or one `writeData` wrote. The same as `app.readData`.
    pub fn readData(self: *FileAccess, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        return self.app.readData(try self.app.loadData(path));
    }

    /// `name` in the folder `path`: `join("user://saves", "one.json")`.
    pub fn join(self: *FileAccess, vm: *flux.Vm, path: []const u8, name: []const u8) anyerror!flux.Value {
        _ = self;
        if (path.len == 0 or isRooted(name)) return vm.string(name);
        if (name.len == 0) return vm.string(path);
        const apart = if (path[path.len - 1] == '/' or path[path.len - 1] == '\\') "" else "/";
        const joined = try std.mem.concat(vm.gpa, u8, &.{ path, apart, name });
        defer vm.gpa.free(joined);
        return vm.string(joined);
    }

    /// The folder a path is in: `user://saves` of `user://saves/one.json`.
    pub fn dirName(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        _ = self;
        return vm.string(dirNameOf(path));
    }

    /// The last step of a path: `one.json` of `user://saves/one.json`.
    pub fn fileName(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        _ = self;
        return vm.string(fileNameOf(path));
    }

    /// Its name without the extension: `one` of `user://saves/one.json`.
    pub fn stem(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        _ = self;
        const name = fileNameOf(path);
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return vm.string(name);
        return vm.string(if (dot == 0) name else name[0..dot]);
    }

    /// What its name ends with after the last dot, without it: `json`.
    /// Empty for a name with none.
    pub fn extension(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        _ = self;
        const name = fileNameOf(path);
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return vm.string("");
        return vm.string(if (dot == 0) "" else name[dot + 1 ..]);
    }

    /// Whether `name` can be a file's name on every system: not empty, none
    /// of `/ \ : * ? " < > |` nor a control character, not ending in a dot
    /// or a space, and not a name Windows keeps for itself (`CON`, `COM1`…).
    pub fn isValidName(self: *FileAccess, name: []const u8) bool {
        _ = self;
        return validFileName(name);
    }

    /// `name` made one a file can have - what the player typed for a save's
    /// name: what is not allowed becomes `_`.
    pub fn validName(self: *FileAccess, vm: *flux.Vm, name: []const u8) anyerror!flux.Value {
        _ = self;
        const made = try vm.gpa.alloc(u8, @min(name.len, 200) + 1);
        defer vm.gpa.free(made);
        var len: usize = 0;
        for (name[0..@min(name.len, 200)]) |c| {
            made[len] = if (c < 0x20 or std.mem.indexOfScalar(u8, forbidden_in_names, c) != null) '_' else c;
            len += 1;
        }
        while (len > 0 and (made[len - 1] == '.' or made[len - 1] == ' ')) len -= 1;
        if (len == 0 or reservedName(made[0..len])) {
            std.mem.copyBackwards(u8, made[1 .. len + 1], made[0..len]);
            made[0] = '_';
            len += 1;
        }
        return vm.string(made[0..len]);
    }

    /// Where a `res://` or `user://` path is on this computer: to tell the
    /// player where the saves are.
    pub fn globalPath(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        const global = try self.app.project.osPath(vm.gpa, path);
        defer vm.gpa.free(global);
        return vm.string(global);
    }

    /// A path of this computer's as the game names it: `res://` inside the
    /// project, `user://` inside the player's folder, and as it is
    /// elsewhere.
    pub fn localPath(self: *FileAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        const local = try self.app.project.localPath(vm.gpa, path);
        defer vm.gpa.free(local);
        return vm.string(local);
    }

    /// Open a file in the program the player opens its kind with, or a
    /// folder in the file manager.
    pub fn open(self: *FileAccess, path: []const u8) anyerror!void {
        try mayRead(self.app, path);
        try self.app.openPath(path);
    }

    /// Show a file picked out in its folder's window: a Saves button.
    pub fn showInFolder(self: *FileAccess, path: []const u8) anyerror!void {
        try mayRead(self.app, path);
        try self.app.showInFolder(path);
    }

    /// Ask the player for a file of theirs with the system's dialog: a
    /// signal said once, with a list of the paths chosen - empty when the
    /// dialog is cancelled. A file chosen is one `files` reads, wherever it
    /// is, and one a sprite or a player can be given. `extensions` lists the
    /// kinds shown, without their dots.
    ///
    /// ```
    /// const chosen = await files.choose("A picture of you", ["png", "jpg"]);
    /// if (chosen.len > 0) { avatar.texture = chosen[0]; }
    /// ```
    pub fn choose(self: *FileAccess, vm: *flux.Vm, title: []const u8, extensions: flux.Value, many: bool) anyerror!flux.Value {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        const gpa = self.app.gpa;
        var kinds: std.ArrayList([]const u8) = .empty;
        defer kinds.deinit(gpa);
        if (extensions.tag == .list) {
            for (extensions.as(flux.object.List).items.items) |item| {
                if (item.tag != .string) return error.NotAnExtension;
                const text = item.as(flux.object.String).bytes();
                try kinds.append(gpa, if (std.mem.startsWith(u8, text, ".")) text[1..] else text);
            }
        } else if (extensions.tag != .null) return error.NotAnExtension;
        const label = try std.mem.join(gpa, ", ", kinds.items);
        defer gpa.free(label);
        const one = [_]dialog.Filter{.{ .name = label, .extensions = kinds.items }};
        const asked = try self.app.openFileDialog(.{
            .title = if (title.len == 0) null else title,
            .multiple = many,
            .filters = if (kinds.items.len == 0) &.{} else &one,
        });

        const signal = try vm.newSignal("chosen", 1);
        try vm.hold(signal);
        errdefer vm.release(signal);
        try scripts.dialogs.append(gpa, .{ .id = asked, .signal = signal });
        return signal;
    }

    /// The signal said with a list of the paths of the files the player lets
    /// go over the window, each time they do: files `files` reads then.
    ///
    /// ```
    /// files.dropped().connect(fn(paths: any) { print(paths); });
    /// ```
    pub fn dropped(self: *FileAccess, vm: *flux.Vm) anyerror!flux.Value {
        _ = self;
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        if (scripts.drop_signal.tag != .signal) {
            const signal = try vm.newSignal("dropped", 1);
            try vm.hold(signal);
            scripts.drop_signal = signal;
        }
        return scripts.drop_signal;
    }

    fn readable(path: []const u8) error{NotAllowed}!void {
        inline for (.{ Project.scheme, Project.uid_scheme, Project.user_scheme }) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return;
        }
        return error.NotAllowed;
    }

    pub fn writable(path: []const u8) error{NotAllowed}!void {
        if (!std.mem.startsWith(u8, path, Project.user_scheme)) return error.NotAllowed;
    }
};

/// Whether a script may read `path`: the game's, the player's under
/// `user://`, or a file of theirs they chose in a dialog or let go over the
/// window.
pub fn mayRead(app: *App, path: []const u8) error{NotAllowed}!void {
    FileAccess.readable(path) catch {
        const scripts = app.scripts orelse return error.NotAllowed;
        if (!scripts.granted.contains(path)) return error.NotAllowed;
    };
}

/// What no file's name may hold on some system.
const forbidden_in_names = "/\\:*?\"<>|";

fn validFileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    for (name) |c| if (c < 0x20 or std.mem.indexOfScalar(u8, forbidden_in_names, c) != null) return false;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    return !reservedName(name);
}

/// A name Windows keeps for a device, with an extension or without:
/// `nul.txt` is refused too.
fn reservedName(name: []const u8) bool {
    const base = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    inline for (.{ "CON", "PRN", "AUX", "NUL" }) |kept| if (std.ascii.eqlIgnoreCase(base, kept)) return true;
    if (base.len == 4 and (std.ascii.startsWithIgnoreCase(base, "COM") or std.ascii.startsWithIgnoreCase(base, "LPT"))) {
        return base[3] >= '1' and base[3] <= '9';
    }
    return false;
}

/// Whether a path starts from somewhere of its own: a scheme, a root, a
/// drive.
fn isRooted(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "://") != null) return true;
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len > 1 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
}

/// Where a path's last step starts: after its scheme, and after its last
/// `/` or `\`.
fn lastStep(path: []const u8) usize {
    const after_scheme = if (std.mem.indexOf(u8, path, "://")) |at| at + 3 else 0;
    const cut = std.mem.lastIndexOfAny(u8, path[after_scheme..], "/\\") orelse return after_scheme;
    return after_scheme + cut + 1;
}

fn dirNameOf(path: []const u8) []const u8 {
    const step = lastStep(path);
    const after_scheme = if (std.mem.indexOf(u8, path, "://")) |at| at + 3 else 0;
    if (step <= after_scheme) return path[0..after_scheme];
    return path[0 .. step - 1];
}

fn fileNameOf(path: []const u8) []const u8 {
    return path[lastStep(path)..];
}

/// A settings file as a script holds it: `files.config(path)`. Sections of
/// keys, each any number, bool, text, vector or colour, or a list of them;
/// kept in memory until `save`.
///
/// ```
/// const settings = files.config("user://settings.cfg");
/// const volume = settings.get("audio", "music", 0.8);   // 0.8 the first time
/// settings.set("display", "window", vec2(1280, 720));
/// settings.save();
/// ```
///
/// A value comes back as the kind its default is: a `vec2` for a `vec2`
/// default, a colour for a colour - JSON keeps them as a list and as `#hex`.
/// Without a default, a number, bool, text or list; anything else is null.
pub const ConfigRef = struct {
    app: *App,
    held: ConfigFile,
    path: []u8,
    password: []u8,

    pub const reflect_name = "Config";
    pub const reflect_opaque = true;
    pub const reflect_drop = release;
    pub const reflect_methods = .{
        .get = .{ attr.Params{ .names = &.{ "vm", "section", "key", "default" } }, attr.defaults(.{flux.Value.null}) },
        .set = .{attr.Params{ .names = &.{ "section", "key", "value" } }},
        .has = .{attr.Params{ .names = &.{ "section", "key" } }},
        .erase = .{attr.Params{ .names = &.{ "section", "key" } }},
        .eraseSection = .{attr.Params{ .names = &.{"section"} }},
        .sections = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of([]const []const u8) },
        .keys = .{ attr.Params{ .names = &.{ "vm", "section" } }, flux.Returns.of([]const []const u8) },
        .save = .{flux.GivesErrors{}},
    };

    fn release(self: *ConfigRef, gpa: Allocator) void {
        self.held.deinit();
        gpa.free(self.path);
        gpa.free(self.password);
    }

    pub fn get(self: *ConfigRef, vm: *flux.Vm, section: []const u8, key: []const u8, default: flux.Value) anyerror!flux.Value {
        const held = self.held.get(section, key);
        if (held == .null) return default;
        return try fluxLike(vm, held, default) orelse default;
    }

    /// Set a key, making its section when it is new. A value a file cannot
    /// keep - a map, a struct, a function - is `error.CannotKeep`.
    pub fn set(self: *ConfigRef, section: []const u8, key: []const u8, value: flux.Value) anyerror!void {
        const written = try jsonOf(&self.held.doc, value);
        if (written == .null and value.tag != .null) return error.CannotKeep;
        try self.held.set(section, key, written);
    }

    pub fn has(self: *ConfigRef, section: []const u8, key: []const u8) bool {
        return self.held.has(section, key);
    }

    /// Take a key out; whether it was there.
    pub fn erase(self: *ConfigRef, section: []const u8, key: []const u8) bool {
        return self.held.erase(section, key);
    }

    pub fn eraseSection(self: *ConfigRef, section: []const u8) bool {
        return self.held.eraseSection(section);
    }

    pub fn sections(self: *ConfigRef, vm: *flux.Vm) anyerror!flux.Value {
        return flux.bind.toValue(vm, self.held.sections());
    }

    pub fn keys(self: *ConfigRef, vm: *flux.Vm, section: []const u8) anyerror!flux.Value {
        return flux.bind.toValue(vm, self.held.keys(section));
    }

    /// Write it where it was read from, under `user://`: sealed when it was
    /// opened with a password.
    pub fn save(self: *ConfigRef) anyerror!void {
        if (!std.mem.startsWith(u8, self.path, Project.user_scheme)) return error.NotAllowed;
        const text = try self.held.write(self.app.gpa);
        defer self.app.gpa.free(text);
        if (self.password.len == 0) return self.app.writeText(self.path, text);
        try self.app.writeSecret(self.path, text, self.password);
    }
};

/// A JSON value as a script's, the kind `like` is where it can be: what a
/// `Config` gives back. Null for what it cannot be.
fn fluxLike(vm: *flux.Vm, value: json.Value, like: flux.Value) flux.Vm.Error!?flux.Value {
    switch (like.tag) {
        .int => return .int(value.asInt(i64) orelse return null),
        .float => return .float(value.asFloat(f64) orelse return null),
        .bool => return .boolean(value.asBool() orelse return null),
        .string => return try vm.string(value.asString() orelse return null),
        .vec2, .vec3 => {
            const n: usize = if (like.tag == .vec2) 2 else 3;
            if (value.asArray() == null or value.len() != n) return null;
            var xyz: [3]f32 = @splat(0);
            for (0..n) |i| xyz[i] = @floatCast(value.get(i).asFloat(f64) orelse return null);
            return if (n == 2) .vec2(xyz[0], xyz[1]) else .vec3(xyz[0], xyz[1], xyz[2]);
        },
        .color => {
            const c = Color.parse(value.asString() orelse return null) orelse return null;
            return try vm.newColor(.{ c.r, c.g, c.b, c.a });
        },
        else => return anyFlux(vm, value, 0),
    }
}

/// A JSON value as a script's own kind of it: a number, a bool, text, a
/// list of them; null for an object.
fn anyFlux(vm: *flux.Vm, value: json.Value, depth: u32) flux.Vm.Error!?flux.Value {
    return switch (value) {
        .int => |n| .int(n),
        .float => |f| .float(f),
        .bool => |b| .boolean(b),
        .string => |text| try vm.string(text),
        else => {
            const items = value.asArray() orelse return null;
            if (depth > 32) return null;
            var made: std.ArrayList(flux.Value) = .empty;
            defer made.deinit(vm.gpa);
            defer for (made.items) |_| vm.popRoot();
            for (items.items()) |item| {
                const one = try anyFlux(vm, item, depth + 1) orelse flux.Value.null;
                try made.append(vm.gpa, one);
                try vm.pushRoot(one);
            }
            return try vm.newList(.any, made.items);
        },
    };
}
