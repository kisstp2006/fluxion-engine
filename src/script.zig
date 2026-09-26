// SPDX-License-Identifier: BSD-3-Clause

//! Flux scripts on entities. A `Script` component names a `.flux` file and a
//! struct in it. The engine makes the entity an instance of that struct, with
//! the entity in it as `self.entity`, and calls whichever of these the struct
//! declares:
//!
//! - `ready(self)` before anything else of it;
//! - `fixed(self, dt: float)` every fixed step, before the game's `.fixed`
//!   systems;
//! - `update(self, dt: float)` every frame, before the game's `.update`
//!   systems;
//! - `exit(self)` when the entity dies, when its `Script` is taken off or
//!   turned off, or when the world is cleared.
//!
//! - `input(self, event: InputEvent)` for everything the player does - each
//!   key, each mouse button, the mouse moving, the wheel, a controller's
//!   button - and `unhandled_input(self, event: InputEvent)` for what no
//!   `input` took with `app.setInputAsHandled()` and the interface did not
//!   have. Which it is, `is` asks: `if (event is KeyEvent)`. See
//!   `input_event.zig`.
//!
//! The compiler knows them (see `Lifecycle`): a method of one of these
//! names that takes other arguments is warned of, and a parameter of one
//! given no type is given the type the engine passes.
//!
//! `fixed` and `update` are called while the entity runs: not while the game
//! is paused, unless its `Processing` - or the nearest one above it - says
//! otherwise. A task a script starts belongs to the entity whose script
//! started it, and its `await wait(...)` stands still while that entity does
//! not run. See `App.setPaused`.
//!
//! ```zig
//! try app.useScripts(.{});
//! const door = try app.loadScript("res://scripts/door.flux");
//! _ = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Script.of(door) });
//! ```
//!
//! ```
//! // res://scripts/door.flux
//! struct Door {
//!     var open: bool = false;
//!
//!     fn ready(self) {
//!         print("a door called", self.entity.name());
//!     }
//!
//!     fn update(self, dt: float) {
//!         if (self.open) self.entity.get(Transform2D).rotation += dt;
//!     }
//! }
//! ```
//!
//! **One VM for the app.** `App.useScripts` makes it and registers `Script`
//! for scenes. A game that never calls it compiles none of the language in:
//! the frame reaches the scripts through pointers only `useScripts` sets.
//!
//! **Every script sees `app`**: the engine, with the calls
//! `App.reflect_methods` lists. **Every instance sees `self.entity`**, which
//! it reads and cannot assign: `get(Sprite)`, `find(Sprite)`, `has`, `add`,
//! `remove`, and every call of `app`'s that is given an entity first, as the
//! entity's own - `self.entity.globalPosition()`, `self.entity.parent()`.
//! **The engine's types are the scripts'**: a component, an event, `Entity`,
//! named in a type and where a value goes, and their enums as Flux enums.
//! `install` says all of it to the VM, in one place, and `App.scriptSetup`
//! gives an editor's language service the same, so it checks and completes
//! what the game runs, with what the doc comments say.
//!
//! **And `files`**: the game's own files to read, the player's to read and
//! write - `files.readText`, `writeText`, `exists`, `makeDir`, `list`,
//! `remove` - and no others. See `FileAccess`. A save is JSON with the
//! language's `json` module:
//!
//! ```
//! const json = @import("json");
//!
//! fn save(slot: any) {
//!     files.writeText("user://save.json", json.stringify(slot, 2)) catch |e| print("not saved:", e.name);
//! }
//!
//! fn load() any {
//!     const text = files.readText("user://save.json") catch return null;
//!     return json.parse(text) catch null;
//! }
//! ```
//!
//! **A component is found again at each use.** `self.entity.get(Health)`
//! is a handle the engine looks up every time the script touches it, so
//! keeping it in a field is safe while rows move. Once the component or its
//! entity is gone, using it stops the script with a panic that says so.
//!
//! **An error of the engine's stops the script** with its name, as a
//! mistake in the script would - a name taken, a property that is not
//! there. Those of `files`, `images`, `time`, a config, an image, a clock and
//! a set of sprite frames are values to `catch` instead: a file that is not
//! there is no mistake.
//!
//! **Signals both ways.** A script's signals are its entity's, under
//! `Script`: listed by `App.signalsOf` from the struct as soon as the entity
//! has its `Script`, connected by name, saved with a scene, and heard by the
//! engine's connections when the script emits. A signal the engine sends -
//! a component's, another script's - calls a method the target's script
//! declares.
//!
//! **An entity is one handle.** Wherever a script is handed an entity -
//! `self.entity`, `app.find("door")`, a field such as `Transform2D.parent`,
//! a signal's argument - it is the same handle for as long as the entity
//! lives, so `==` says whether two are the same entity, and null is none.
//! Where a call or a field wants an entity, a script gives that handle, a
//! scripted entity's instance as an emit may, or null for none. Anything
//! else stops it with a panic that says what it gave.
//!
//! **A script cannot stop the game.** Each call into one gets a budget of
//! loop rounds, and a call that runs past it is stopped. A panic is said in
//! the log with its place in the file, the first time for each instance's
//! method, and every one is counted in `Scripts.failures`; the other scripts
//! go on. A file that does not compile still gets a handle, so a scene that
//! holds it opens. Its reasons are in the log, and it runs once a reload
//! compiles.
//!
//! **Read again while it runs.** `App.reloadScript` puts a file's new code
//! into the instances it has, which keep their fields. With `Options.watch`
//! the engine looks at the files itself, every so many seconds, for a game
//! started from an editor as a program of its own.
//!
//! **An editor has the scripts and runs none of them**: `Options.run =
//! false`. Its files are compiled, read again and written in scenes, and
//! their structs' signals and methods listed and connected to, but no code
//! of theirs runs - not the top level, a default, `ready` or `update` - so
//! a script cannot change the scene being edited.
//!
//! **Order.** Scripts are called in the order their instances were made.
//! `exit` runs at the end of the frame the entity died in, after it is gone,
//! so `self.entity.alive()` is false there. An app closing calls no `exit`:
//! that is the game's quit handling.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const platform = @import("fluxion_platform");
const reflect = @import("fluxion_reflect");
/// The language: its VM, its values, its language service.
pub const flux = @import("fluxion_script");

const math = @import("fluxion_math");

const json = @import("fluxion_json");

const App = @import("App.zig");
const actions = @import("actions.zig");
const AssetKind = @import("asset_kind.zig").AssetKind;
const data_file = @import("data.zig");
const property = @import("property.zig");
const attr = @import("attr.zig");
const Project = @import("Project.zig");
const signals = @import("signals.zig");
const tileset = @import("tileset.zig");
const shaders_mod = @import("shaders.zig");
const sprite_frames = @import("sprite_frames.zig");
const Assets = @import("assets.zig");
const geometry = @import("geometry.zig");
const Color = @import("color.zig").Color;
const input_event = @import("input_event.zig");
const InputEvent = input_event.InputEvent;
const datetime = @import("datetime.zig");
const clocks_mod = @import("clocks.zig");
const ConfigFile = @import("config.zig").ConfigFile;
const dialog = @import("dialog.zig");
const Image = @import("images.zig").Image;

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

/// The largest script file read.
const file_limit = 16 << 20;

/// What the engine lists a script's signals and methods under, as a scene
/// calls a component: `Script.died`.
pub const component_name = "Script";

/// The most arguments a signal carries between a script and the engine.
pub const max_args = 16;

/// The `signals.Info.args` of a script's signal: a struct with no fields,
/// since no Zig struct describes what a script's signal gives. Its
/// `signature` and `arity` say.
pub const ScriptArguments = struct {
    pub const reflect_name = "ScriptArguments";
};

pub const Options = struct {
    /// How many loop rounds one call into a script may take before it is
    /// stopped as a loop that would never end. One call is a frame's
    /// `update`, a step's `fixed`, or the frame's waiting tasks. Null for
    /// no limit.
    budget: ?u64 = 10_000_000,
    /// The most the scripts' objects may take, in bytes. Past it, what
    /// allocates fails in the script, not in the game. Null for no limit.
    max_bytes: ?usize = null,
    /// Where `print` writes. Null is the log, under `.flux`, a line at a
    /// time.
    out: ?*std.Io.Writer = null,
    /// How often to look at the files the scripts were read from, in
    /// seconds of the clock that does not stop for a paused game, and read
    /// again each one saved since: a game run from an editor takes what the
    /// editor saves. Null never looks, as a shipped game has nothing to watch.
    watch: ?f32 = null,
    /// Whether the scripts run. Off is an editor's: a file is compiled and
    /// never run, not even its top level; no instance is made, so no
    /// default, `ready`, `fixed`, `update` or `exit` runs, no task wakes,
    /// and `watch` is not looked at. The structs' signals and methods are
    /// listed all the same, and connections to them kept. A signal's call
    /// into a method is `error.NotRunning`.
    run: bool = true,
};

/// A `.flux` file loaded into the app's VM, the way a `FontHandle` is a
/// font.
pub const ScriptHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub const none: ScriptHandle = .{};

    /// A tool shows `App.scriptSource` instead, as for a texture.
    pub const reflect_name = "ScriptHandle";

    pub fn isNone(self: ScriptHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(a: ScriptHandle, b: ScriptHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    fn toId(self: ScriptHandle) FileId {
        return @bitCast(self);
    }

    fn fromId(handle: FileId) ScriptHandle {
        return @bitCast(handle);
    }
};

const FileId = id.handle.Handle(File);
const FileTable = id.handle.Table(File);

/// A script on an entity. A scene saves the file by its path.
pub const Script = extern struct {
    source: ScriptHandle = .none,
    /// Which struct of the file is the entity's. Empty means the one named
    /// after the file: `Door` in `door.flux`, `BigDoor` in `big_door.flux`,
    /// or one called exactly what the file is.
    struct_name: [48]u8 = @splat(0),
    /// When off, no instance is made, and an existing one is let go of, with
    /// `exit`.
    enabled: bool = true,

    pub const reflect_name = "Script";
    pub const reflect_fields = .{
        .source = .{attr.Doc{ .text = "The .flux file" }},
        .struct_name = .{attr.Doc{ .text = "Which struct of the file; empty for the one named after the file" }},
        .enabled = .{attr.Doc{ .text = "Off, the script is let go of, with exit" }},
    };

    /// The struct named after the file.
    pub fn of(source: ScriptHandle) Script {
        return .{ .source = source };
    }

    /// A struct of the file, by name. A name longer than 48 bytes is cut
    /// at the last whole character that fits.
    pub fn named(source: ScriptHandle, name: []const u8) Script {
        var made: Script = .{ .source = source };
        var len = @min(name.len, made.struct_name.len);
        while (len < name.len and len > 0 and name[len] & 0xC0 == 0x80) len -= 1;
        @memcpy(made.struct_name[0..len], name[0..len]);
        return made;
    }

    /// The struct's name as written: up to the first zero byte.
    pub fn structName(self: *const Script) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.struct_name, 0) orelse self.struct_name.len;
        return self.struct_name[0..end];
    }
};

/// What a script reaches as `self.entity`: its entity, and the calls on it.
/// The collector owns it, so a script that keeps it after `exit` holds
/// nothing freed. For a dead entity it answers as for one with nothing:
/// empty, null, false.
pub const EntityRef = struct {
    scripts: *Scripts,
    entity: Entity,
    /// `uuid`'s text, for the call that asked.
    uuid_text: [36]u8 = undefined,

    pub const reflect_name = "Entity";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .alive = .{},
        .name = .{},
        .uuid = .{},
        .has = .{attr.Params{ .names = &.{"component"} }},
        .get = .{attr.Params{ .names = &.{ "vm", "component" } }},
        .find = .{attr.Params{ .names = &.{ "vm", "component" } }},
        .add = .{attr.Params{ .names = &.{ "vm", "component" } }},
        .remove = .{attr.Params{ .names = &.{ "vm", "component" } }},
        .despawn = .{},
        .script = .{},
    };

    /// Whether it is still in the world. False in `exit` for a despawned
    /// entity.
    pub fn alive(self: *EntityRef) bool {
        return self.scripts.app.world.isAlive(self.entity);
    }

    /// Its name, or "" for one without: never null, as `app.nameOf` may be.
    pub fn name(self: *EntityRef) []const u8 {
        return self.scripts.app.nameOf(self.entity) orelse "";
    }

    /// Its UUID as text, or "" for one without.
    pub fn uuid(self: *EntityRef) []const u8 {
        const held = self.scripts.app.uuidOf(self.entity) orelse return "";
        self.uuid_text = held.toString();
        return &self.uuid_text;
    }

    /// Whether it has a `component`: `self.entity.has(Sprite)`.
    pub fn has(self: *EntityRef, component: *const reflect.Type) bool {
        return self.scripts.app.componentOfType(self.entity, component) != null;
    }

    /// Its `component`, to read and write in place:
    /// `self.entity.get(Transform2D).x += 1`. One it has not got stops the
    /// script, saying so; `find` is for one it may not have. It is found
    /// again at each use, so it may be kept.
    pub fn get(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!flux.Value {
        return try self.find(vm, component) orelse vm.fail("{s} has no {s}: `find({s})` is null for one that may not have it", .{ self.called(), shortName(component), shortName(component) });
    }

    /// Its `component`, or null when it has none: `if
    /// (self.entity.find(Sprite)) |sprite| ...`.
    pub fn find(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!?flux.Value {
        _ = try self.entryOf(vm, component);
        if (self.scripts.app.componentOfType(self.entity, component) == null) return null;
        return try vm.liveHandle(&self.scripts.resolver, self.entity.toInt(), component);
    }

    /// Put a `component` on, holding its defaults, and hand it back to fill
    /// in. One it has already is handed back as it is.
    pub fn add(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!flux.Value {
        const entry = try self.entryOf(vm, component);
        const added = self.scripts.app.addComponentNamed(self.entity, entry.name) catch |err| return refused(vm, err, "add", entry.name);
        return vm.liveHandle(&self.scripts.resolver, self.entity.toInt(), added.type);
    }

    /// Take a `component` off. One it has not got does nothing.
    pub fn remove(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!void {
        const entry = try self.entryOf(vm, component);
        self.scripts.app.removeComponentNamed(self.entity, entry.name) catch |err| return refused(vm, err, "remove", entry.name);
    }

    fn entryOf(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!*const @import("scene.zig").Registry.Entry {
        return self.scripts.app.scene_components.findType(component) orelse vm.fail("{s} is no component", .{shortName(component)});
    }

    /// What it is called in a message: its name, or "the entity".
    fn called(self: *EntityRef) []const u8 {
        return self.scripts.app.nameOf(self.entity) orelse "the entity";
    }

    /// The instance its `Script` made, to call and to read as any value:
    /// `app.find("Loader").script().open("res://menu.json")`, one script
    /// asking another. Null while it has none - no `Script`, one that did
    /// not compile, or one whose `ready` has not come yet.
    pub fn script(self: *EntityRef) flux.Value {
        return self.scripts.instanceOf(self.entity) orelse .null;
    }

    /// Take it out of the world, and everything that hangs from it. Its
    /// script's `exit` comes at the end of the frame.
    pub fn despawn(self: *EntityRef) error{OutOfMemory}!void {
        if (!self.scripts.app.world.isAlive(self.entity)) return;
        try self.scripts.app.despawnTree(self.entity);
    }

    fn refused(vm: *flux.Vm, err: App.ComponentError, comptime what: []const u8, component: []const u8) flux.Vm.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NoSuchComponent => vm.fail("cannot " ++ what ++ " {s}: no component is registered under that name", .{component}),
            error.NoSuchEntity => vm.fail("cannot " ++ what ++ " {s}: the entity is not alive", .{component}),
            else => vm.fail("cannot " ++ what ++ " {s}: {t}", .{ component, err }),
        };
    }
};

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

    fn writable(path: []const u8) error{NotAllowed}!void {
        if (!std.mem.startsWith(u8, path, Project.user_scheme)) return error.NotAllowed;
    }
};

/// Whether a script may read `path`: the game's, the player's under
/// `user://`, or a file of theirs they chose in a dialog or let go over the
/// window.
fn mayRead(app: *App, path: []const u8) error{NotAllowed}!void {
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

/// What a script reaches as `images`: pictures in memory, made, read from a
/// file, or caught from the screen, to change a pixel at a time, save, and
/// draw as a texture. An image is an `Image`: see `ImageRef`.
///
/// ```
/// const shot = images.capture();                     // the frame as it is
/// shot.resize(320, 180);
/// shot.saveJpg("user://saves/one.jpg", 0.85);        // a save's thumbnail
/// const map = images.new(64, 64, color(0, 0, 0, 1));
/// map.setPixel(10, 12, color(1, 1, 1));
/// sprite.texture = images.toTexture(map);            // "image://1"
/// ```
pub const ImagesAccess = struct {
    app: *App,

    pub const reflect_name = "Images";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .new = .{ attr.Params{ .names = &.{ "vm", "width", "height", "color" } }, attr.defaults(.{Color.transparent}), flux.Returns.of(ImageRef) },
        .read = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .capture = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .fromTexture = .{ attr.Params{ .names = &.{ "vm", "texture" } }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .toTexture = .{ attr.Params{ .names = &.{ "vm", "image" } }, flux.GivesErrors{} },
        .updateTexture = .{ attr.Params{ .names = &.{ "vm", "texture", "image" } }, flux.GivesErrors{} },
    };

    /// One `width` by `height`, every pixel `color`: see-through when none
    /// is given.
    pub fn new(self: *ImagesAccess, vm: *flux.Vm, width: i64, height: i64, color: Color) anyerror!flux.Value {
        const made = try Image.init(vm.gpa, try side(width), try side(height), color);
        return imageValue(vm, self.app, made);
    }

    /// A picture's file, a PNG or a JPEG: the game's (`res://`) or the
    /// player's (`user://`).
    pub fn read(self: *ImagesAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        return imageValue(vm, self.app, try self.app.readImage(vm.gpa, path));
    }

    /// The frame drawn again, the window's size.
    pub fn capture(self: *ImagesAccess, vm: *flux.Vm) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.app.captureImage(vm.gpa));
    }

    /// What a texture holds, read back from the GPU.
    pub fn fromTexture(self: *ImagesAccess, vm: *flux.Vm, texture: Assets.TextureHandle) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.app.textureImage(vm.gpa, texture));
    }

    /// The image as a texture to draw, called `image://1`, `image://2`...:
    /// what a sprite's `texture` is given.
    pub fn toTexture(self: *ImagesAccess, vm: *flux.Vm, picture: flux.Value) anyerror!Assets.TextureHandle {
        return self.app.newTexture((try imageOf(vm, picture)).held, .{});
    }

    /// A texture given an image's pixels, the same size or another.
    pub fn updateTexture(self: *ImagesAccess, vm: *flux.Vm, texture: Assets.TextureHandle, picture: flux.Value) anyerror!void {
        try self.app.updateTexture(texture, (try imageOf(vm, picture)).held);
    }
};

fn side(n: i64) error{BadSize}!u32 {
    if (n <= 0 or n > Image.max_side) return error.BadSize;
    return @intCast(n);
}

/// A picture in memory as a script holds it. Its pixels are let go of with
/// it. A pixel outside it is `error.OutsideImage` to read or write; a
/// rectangle is cut to what is inside.
///
/// ```
/// const picture = images.read("res://art/map.png") catch return;
/// const under = picture.getPixel(3, 4);
/// picture.fillRect(0, 0, 8, 8, color(1, 0, 0));
/// picture.blend(images.read("res://art/pin.png") catch return, 20, 30);
/// picture.savePng("user://map.png");
/// ```
pub const ImageRef = struct {
    app: *App,
    held: Image,

    pub const reflect_name = "Image";
    pub const reflect_opaque = true;
    pub const reflect_drop = release;
    pub const reflect_methods = .{
        .width = .{},
        .height = .{},
        .getPixel = .{attr.Params{ .names = &.{ "x", "y" } }},
        .setPixel = .{attr.Params{ .names = &.{ "x", "y", "color" } }},
        .fill = .{attr.Params{ .names = &.{"color"} }},
        .fillRect = .{attr.Params{ .names = &.{ "x", "y", "width", "height", "color" } }},
        .region = .{ attr.Params{ .names = &.{ "vm", "x", "y", "width", "height" } }, flux.Returns.of(ImageRef) },
        .blit = .{attr.Params{ .names = &.{ "vm", "source", "x", "y" } }},
        .blend = .{attr.Params{ .names = &.{ "vm", "source", "x", "y" } }},
        .resize = .{ attr.Params{ .names = &.{ "vm", "width", "height", "smooth" } }, attr.defaults(.{true}) },
        .flipX = .{},
        .flipY = .{},
        .copy = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of(ImageRef) },
        .savePng = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .saveJpg = .{ attr.Params{ .names = &.{ "path", "quality" } }, attr.defaults(.{0.9}), flux.GivesErrors{} },
    };

    fn release(self: *ImageRef, gpa: Allocator) void {
        self.held.deinit(gpa);
    }

    pub fn width(self: *ImageRef) i64 {
        return self.held.width;
    }

    pub fn height(self: *ImageRef) i64 {
        return self.held.height;
    }

    pub fn getPixel(self: *ImageRef, x: i64, y: i64) anyerror!Color {
        return self.held.getPixel(x, y) orelse error.OutsideImage;
    }

    pub fn setPixel(self: *ImageRef, x: i64, y: i64, color: Color) anyerror!void {
        if (!self.held.setPixel(x, y, color)) return error.OutsideImage;
    }

    pub fn fill(self: *ImageRef, color: Color) void {
        self.held.fill(color);
    }

    pub fn fillRect(self: *ImageRef, x: i64, y: i64, w: i64, h: i64, color: Color) void {
        self.held.fillRect(x, y, w, h, color);
    }

    /// A new image of a rectangle of this one.
    pub fn region(self: *ImageRef, vm: *flux.Vm, x: i64, y: i64, w: i64, h: i64) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.held.region(vm.gpa, x, y, w, h));
    }

    /// Another image copied in, its top left at (`x`, `y`), alpha and all.
    pub fn blit(self: *ImageRef, vm: *flux.Vm, source: flux.Value, x: i64, y: i64) anyerror!void {
        self.held.blit((try imageOf(vm, source)).held, x, y);
    }

    /// Another image drawn over, its top left at (`x`, `y`).
    pub fn blend(self: *ImageRef, vm: *flux.Vm, source: flux.Value, x: i64, y: i64) anyerror!void {
        self.held.blend((try imageOf(vm, source)).held, x, y);
    }

    /// Made `width` by `height`: smooth, or each pixel the nearest - for
    /// pixel art.
    pub fn resize(self: *ImageRef, vm: *flux.Vm, w: i64, h: i64, smooth: bool) anyerror!void {
        const made = try self.held.resized(vm.gpa, try side(w), try side(h), smooth);
        self.held.deinit(vm.gpa);
        self.held = made;
    }

    pub fn flipX(self: *ImageRef) void {
        self.held.flipX();
    }

    pub fn flipY(self: *ImageRef) void {
        self.held.flipY();
    }

    pub fn copy(self: *ImageRef, vm: *flux.Vm) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.held.clone(vm.gpa));
    }

    /// Write it as a PNG under `user://`.
    pub fn savePng(self: *ImageRef, path: []const u8) anyerror!void {
        try FileAccess.writable(path);
        const bytes = try self.held.encodePng(self.app.gpa);
        defer self.app.gpa.free(bytes);
        try self.app.writeText(path, bytes);
    }

    /// Write it as a JPEG under `user://`, at a quality from 0 to 1.
    pub fn saveJpg(self: *ImageRef, path: []const u8, quality: f64) anyerror!void {
        try FileAccess.writable(path);
        const scaled: u8 = @intFromFloat(std.math.clamp(@round(quality * 100), 1, 100));
        const bytes = try self.held.encodeJpg(self.app.gpa, scaled);
        defer self.app.gpa.free(bytes);
        try self.app.writeText(path, bytes);
    }
};

/// An image made the scripts' value, which lets go of its pixels.
fn imageValue(vm: *flux.Vm, app: *App, made: Image) flux.Vm.Error!flux.Value {
    var held = made;
    const ref = vm.gpa.create(ImageRef) catch |err| {
        held.deinit(vm.gpa);
        return err;
    };
    ref.* = .{ .app = app, .held = held };
    return vm.adoptHandle(ref) catch |err| {
        ref.held.deinit(vm.gpa);
        vm.gpa.destroy(ref);
        return err;
    };
}

/// The image a script's value is, or `error.NotAnImage`.
fn imageOf(vm: *flux.Vm, value: flux.Value) error{NotAnImage}!*const ImageRef {
    if (vm.reflectOf(value)) |held| if (held.asConst(ImageRef)) |ref| return ref;
    return error.NotAnImage;
}

/// What a script reaches as `time`: this moment, dates made and read,
/// spans of time, the culture they are written in, and clocks of the game's
/// own. Dates are `DateTime` values and spans `Duration` ones, with their
/// calls:
///
/// ```
/// let now = time.now();
/// print(now.formatStyle("long", "short"));          // 2026. szeptember 25. 19:42
/// print(now.addDays(1).format("EEEE"));              // szombat
/// let saved = time.parse("2026-09-25T18:00:00+02:00");
/// print(saved.relative());                           // 1 órával ezelőtt
/// let night = time.clock(time.date(2026, 1, 1), 60);
/// night.hour_passed.connect(fn(hours) { print(night.time().format("h a")); });
/// ```
pub const TimeAccess = struct {
    app: *App,

    pub const reflect_name = "Time";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .now = .{},
        .utcNow = .{},
        .unix = .{},
        .fromUnix = .{attr.Params{ .names = &.{"seconds"} }},
        .date = .{ attr.Params{ .names = &.{ "year", "month", "day", "hour", "minute", "second" } }, attr.defaults(.{ 0, 0, 0 }) },
        .utcDate = .{ attr.Params{ .names = &.{ "year", "month", "day", "hour", "minute", "second" } }, attr.defaults(.{ 0, 0, 0 }) },
        .parse = .{ attr.Params{ .names = &.{"text"} }, flux.GivesErrors{} },
        .seconds = .{attr.Params{ .names = &.{"n"} }},
        .minutes = .{attr.Params{ .names = &.{"n"} }},
        .hours = .{attr.Params{ .names = &.{"n"} }},
        .days = .{attr.Params{ .names = &.{"n"} }},
        .locale = .{},
        .setLocale = .{ attr.Params{ .names = &.{"tag"} }, flux.GivesErrors{} },
        .systemLocale = .{attr.Params{ .names = &.{"vm"} }},
        .zoneName = .{attr.Params{ .names = &.{"vm"} }},
        .clock = .{ attr.Params{ .names = &.{ "vm", "start", "rate" } }, attr.defaults(.{1.0}), flux.Returns.of(ClockRef) },
    };

    /// This moment, on the player's calendar and clock.
    pub fn now(self: *TimeAccess) datetime.DateTime {
        return self.app.localNow();
    }

    pub fn utcNow(self: *TimeAccess) datetime.DateTime {
        return self.app.now().in(.utc);
    }

    /// Seconds since 1970-01-01 00:00 UTC.
    pub fn unix(self: *TimeAccess) f64 {
        return self.app.now().unix();
    }

    /// The moment `seconds` after 1970 began, on the player's clock.
    pub fn fromUnix(_: *TimeAccess, since_1970: f64) datetime.DateTime {
        return datetime.Instant.fromUnix(since_1970).in(.local);
    }

    /// A date and time on the player's clock. What does not fit carries
    /// over: day 32 of January is the first of February.
    pub fn date(_: *TimeAccess, year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) datetime.DateTime {
        return datetime.DateTime.at(.local, year, month, day, hour, minute, second);
    }

    pub fn utcDate(_: *TimeAccess, year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) datetime.DateTime {
        return datetime.DateTime.at(.utc, year, month, day, hour, minute, second);
    }

    /// ISO 8601: `2026-09-25`, `2026-09-25 19:42`, `...T19:42:05+02:00`.
    /// One without an offset is on the player's clock.
    pub fn parse(_: *TimeAccess, text: []const u8) anyerror!datetime.DateTime {
        return datetime.DateTime.parseIso(text, .local);
    }

    pub fn seconds(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofSeconds(n);
    }
    pub fn minutes(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofMinutes(n);
    }
    pub fn hours(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofHours(n);
    }
    pub fn days(_: *TimeAccess, n: f64) datetime.Duration {
        return .ofDays(n);
    }

    /// The tag of the culture dates are written in: `hu-HU`.
    pub fn locale(self: *TimeAccess) anyerror![]const u8 {
        return self.app.locale();
    }

    /// Write in `tag`'s way from now on - `de-DE` - or, for `""`, the
    /// player's.
    pub fn setLocale(self: *TimeAccess, tag: []const u8) anyerror!void {
        try self.app.setLocale(tag);
    }

    /// The player's own locale, whatever the game writes in.
    pub fn systemLocale(_: *TimeAccess, vm: *flux.Vm) []const u8 {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        const held: *[platform.culture.max_tag]u8 = scripts.said[0..platform.culture.max_tag];
        return platform.culture.userLocale(held);
    }

    /// The player's time zone: `Europe/Budapest`, where the system names it.
    pub fn zoneName(_: *TimeAccess, vm: *flux.Vm) []const u8 {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        return platform.culture.timeZoneName(&scripts.said);
    }

    /// A clock of the game's own, showing `start`'s fields and running
    /// `rate` seconds a real second. See `ClockRef`.
    pub fn clock(self: *TimeAccess, vm: *flux.Vm, start: datetime.DateTime, rate: f64) anyerror!flux.Value {
        const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
        const handle = try self.app.newClock(.{ .start = start, .rate = rate });
        return clockValue(scripts, handle);
    }
};

/// A clock of the game's own as a script holds it: what `time.clock(start,
/// rate)` gives. `time()` is what it shows, `setTime`, `setRate`, `pause`,
/// `unpause` and `remove` change it, and its signals say what turned over -
/// each once a frame with how many:
///
/// ```
/// let night = time.clock(time.date(2026, 1, 1), 60);
/// night.hour_passed.connect(fn(hours) { if (night.time().hour == 6) win(); });
/// await night.day_passed;
/// ```
///
/// It stands while the game is paused. A call on one taken away says so.
pub const ClockRef = struct {
    scripts: *Scripts,
    handle: clocks_mod.ClockHandle,

    pub const signal_names = [3][]const u8{ "minute_passed", "hour_passed", "day_passed" };

    pub const reflect_name = "Clock";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .time = .{},
        .setTime = .{attr.Params{ .names = &.{"time"} }},
        .rate = .{},
        .setRate = .{attr.Params{ .names = &.{"rate"} }},
        .pause = .{},
        .unpause = .{},
        .isPaused = .{},
        .remove = .{},
    };

    /// What it shows.
    pub fn time(self: *ClockRef) anyerror!datetime.DateTime {
        return self.scripts.app.clockTime(self.handle) orelse error.NoSuchClock;
    }

    /// Show `to`'s fields from now on.
    pub fn setTime(self: *ClockRef, to: datetime.DateTime) anyerror!void {
        if (self.scripts.app.clockTime(self.handle) == null) return error.NoSuchClock;
        self.scripts.app.setClockTime(self.handle, to);
    }

    /// Seconds of it a real second.
    pub fn rate(self: *ClockRef) f64 {
        return self.scripts.app.clockRate(self.handle);
    }

    pub fn setRate(self: *ClockRef, to: f64) anyerror!void {
        if (self.scripts.app.clockTime(self.handle) == null) return error.NoSuchClock;
        self.scripts.app.setClockRate(self.handle, to);
    }

    pub fn pause(self: *ClockRef) void {
        self.scripts.app.pauseClock(self.handle);
    }

    pub fn unpause(self: *ClockRef) void {
        self.scripts.app.resumeClock(self.handle);
    }

    pub fn isPaused(self: *ClockRef) bool {
        return self.scripts.app.isClockPaused(self.handle);
    }

    pub fn remove(self: *ClockRef) void {
        self.scripts.app.removeClock(self.handle);
    }
};

fn clockKey(handle: clocks_mod.ClockHandle) u64 {
    return @bitCast(handle);
}

/// The value a clock is to the scripts: one clock, one value.
fn clockValue(scripts: *Scripts, handle: clocks_mod.ClockHandle) flux.Vm.Error!flux.Value {
    const key = clockKey(handle);
    if (scripts.clock_values.get(key)) |known| return known;
    const vm = scripts.vm;
    try scripts.clock_values.ensureUnusedCapacity(scripts.app.gpa, 1);
    const ref = try vm.gpa.create(ClockRef);
    ref.* = .{ .scripts = scripts, .handle = handle };
    const made = vm.adoptHandle(ref) catch |err| {
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.hold(made);
    scripts.clock_values.putAssumeCapacityNoClobber(key, made);
    return made;
}

/// A set of sprite frames as a script holds it: what `sprite.sprite_frames`,
/// `app.newSpriteFrames()` and `app.loadSpriteFrames(path)` give. The calls
/// are `SpriteFrames`'s, by the same names, a texture given by its path:
///
/// ```
/// let frames = app.newSpriteFrames();
/// frames.addAnimation("walk");
/// frames.setAnimationSpeed("walk", 8);
/// frames.addFrameRegion("walk", "res://art/hero.png", 0, 0, 32, 32);
/// print(frames.getAnimationNames(), frames.resource_path);
/// ```
///
/// `resource_path` is the file it is, empty for new frames not saved yet. One
/// set of frames is one value: two sprites playing it hand back the same.
/// A call that cannot be done - an animation it has not, a name it has - says
/// why in the log and gives an error.
pub const FramesRef = struct {
    scripts: *Scripts,
    handle: sprite_frames.SpriteFramesHandle,

    pub const reflect_name = "SpriteFrames";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .addAnimation = .{attr.Params{ .names = &.{"name"} }},
        .addFrame = .{ attr.Params{ .names = &.{ "name", "texture", "duration", "at_position" } }, attr.defaults(.{ 1.0, -1 }) },
        .addFrameRegion = .{ attr.Params{ .names = &.{ "name", "texture", "x", "y", "width", "height", "duration", "at_position" } }, attr.defaults(.{ 1.0, -1 }) },
        .clear = .{attr.Params{ .names = &.{"name"} }},
        .clearAll = .{},
        .duplicateAnimation = .{attr.Params{ .names = &.{ "from", "to" } }},
        .getAnimationLoopMode = .{attr.Params{ .names = &.{"name"} }},
        .setAnimationLoopMode = .{attr.Params{ .names = &.{ "name", "mode" } }},
        .getAnimationNames = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of([]const []const u8) },
        .getAnimationSpeed = .{attr.Params{ .names = &.{"name"} }},
        .setAnimationSpeed = .{attr.Params{ .names = &.{ "name", "fps" } }},
        .getFrameCount = .{attr.Params{ .names = &.{"name"} }},
        .getFrameDuration = .{attr.Params{ .names = &.{ "name", "index" } }},
        .getFrameTexture = .{attr.Params{ .names = &.{ "name", "index" } }},
        .getFrameRegion = .{attr.Params{ .names = &.{ "name", "index" } }},
        .hasAnimation = .{attr.Params{ .names = &.{"name"} }},
        .removeAnimation = .{attr.Params{ .names = &.{"name"} }},
        .removeFrame = .{attr.Params{ .names = &.{ "name", "index" } }},
        .renameAnimation = .{attr.Params{ .names = &.{ "name", "new_name" } }},
        .setFrame = .{ attr.Params{ .names = &.{ "name", "index", "texture", "duration" } }, attr.defaults(.{1.0}) },
        .setFrameRegion = .{ attr.Params{ .names = &.{ "name", "index", "texture", "x", "y", "width", "height", "duration" } }, attr.defaults(.{1.0}) },
    };

    const Failed = sprite_frames.Error || error{NoSuchFrames};

    fn held(self: *FramesRef) error{NoSuchFrames}!*sprite_frames.SpriteFrames {
        return self.scripts.app.sprite_frames.edit(self.handle) orelse error.NoSuchFrames;
    }

    fn gpa(self: *FramesRef) Allocator {
        return self.scripts.app.gpa;
    }

    /// `err`, said in the log as the call that met it.
    fn refused(self: *FramesRef, comptime call: []const u8, name: []const u8, err: Failed) Failed {
        const source = self.scripts.app.sprite_frames.sourceOf(self.handle) orelse "sprite frames";
        log.warn("{s}: {s}(\"{s}\"): {t}", .{ source, call, name, err });
        return err;
    }

    pub fn addAnimation(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).addAnimation(self.gpa(), name) catch |err| return self.refused("addAnimation", name, err);
    }

    pub fn addFrame(self: *FramesRef, name: []const u8, texture: Assets.TextureHandle, duration: f32, at_position: i32) Failed!void {
        (try self.held()).addFrame(self.gpa(), name, texture, duration, at_position) catch |err| return self.refused("addFrame", name, err);
    }

    pub fn addFrameRegion(self: *FramesRef, name: []const u8, texture: Assets.TextureHandle, x: f32, y: f32, width: f32, height: f32, duration: f32, at_position: i32) Failed!void {
        (try self.held()).addFrameRegion(self.gpa(), name, texture, .init(x, y, width, height), duration, at_position) catch |err| return self.refused("addFrameRegion", name, err);
    }

    pub fn clear(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).clear(name) catch |err| return self.refused("clear", name, err);
    }

    pub fn clearAll(self: *FramesRef) Failed!void {
        try (try self.held()).clearAll(self.gpa());
    }

    pub fn duplicateAnimation(self: *FramesRef, from: []const u8, to: []const u8) Failed!void {
        (try self.held()).duplicateAnimation(self.gpa(), from, to) catch |err| return self.refused("duplicateAnimation", from, err);
    }

    pub fn getAnimationLoopMode(self: *FramesRef, name: []const u8) Failed!sprite_frames.LoopMode {
        return (try self.held()).getAnimationLoopMode(name);
    }

    pub fn setAnimationLoopMode(self: *FramesRef, name: []const u8, mode: sprite_frames.LoopMode) Failed!void {
        (try self.held()).setAnimationLoopMode(name, mode) catch |err| return self.refused("setAnimationLoopMode", name, err);
    }

    /// Their names, in the order of the alphabet.
    pub fn getAnimationNames(self: *FramesRef, vm: *flux.Vm) anyerror!flux.Value {
        const names = try (try self.held()).getAnimationNames(self.gpa());
        defer self.gpa().free(names);
        return flux.bind.toValue(vm, names);
    }

    pub fn getAnimationSpeed(self: *FramesRef, name: []const u8) Failed!f32 {
        return (try self.held()).getAnimationSpeed(name);
    }

    pub fn setAnimationSpeed(self: *FramesRef, name: []const u8, fps: f32) Failed!void {
        (try self.held()).setAnimationSpeed(name, fps) catch |err| return self.refused("setAnimationSpeed", name, err);
    }

    pub fn getFrameCount(self: *FramesRef, name: []const u8) Failed!i32 {
        return (try self.held()).getFrameCount(name);
    }

    pub fn getFrameDuration(self: *FramesRef, name: []const u8, index: i32) Failed!f32 {
        return (try self.held()).getFrameDuration(name, index);
    }

    pub fn getFrameTexture(self: *FramesRef, name: []const u8, index: i32) Failed!Assets.TextureHandle {
        return (try self.held()).getFrameTexture(name, index);
    }

    pub fn getFrameRegion(self: *FramesRef, name: []const u8, index: i32) Failed!geometry.Rect2 {
        return (try self.held()).getFrameRegion(name, index);
    }

    pub fn hasAnimation(self: *FramesRef, name: []const u8) Failed!bool {
        return (try self.held()).hasAnimation(name);
    }

    pub fn removeAnimation(self: *FramesRef, name: []const u8) Failed!void {
        (try self.held()).removeAnimation(self.gpa(), name) catch |err| return self.refused("removeAnimation", name, err);
    }

    pub fn removeFrame(self: *FramesRef, name: []const u8, index: i32) Failed!void {
        (try self.held()).removeFrame(name, index) catch |err| return self.refused("removeFrame", name, err);
    }

    pub fn renameAnimation(self: *FramesRef, name: []const u8, new_name: []const u8) Failed!void {
        (try self.held()).renameAnimation(self.gpa(), name, new_name) catch |err| return self.refused("renameAnimation", name, err);
    }

    pub fn setFrame(self: *FramesRef, name: []const u8, index: i32, texture: Assets.TextureHandle, duration: f32) Failed!void {
        (try self.held()).setFrame(name, index, texture, duration) catch |err| return self.refused("setFrame", name, err);
    }

    pub fn setFrameRegion(self: *FramesRef, name: []const u8, index: i32, texture: Assets.TextureHandle, x: f32, y: f32, width: f32, height: f32, duration: f32) Failed!void {
        (try self.held()).setFrameRegion(name, index, texture, .init(x, y, width, height), duration) catch |err| return self.refused("setFrameRegion", name, err);
    }

    /// The file it is: empty for frames not saved yet.
    fn resourcePath(self: *FramesRef) []const u8 {
        const frames = self.scripts.app.sprite_frames.get(self.handle) orelse return "";
        return if (frames.on_disc) frames.source else "";
    }
};

/// The app a VM's scripts belong to: for a call of the engine's given the
/// VM, as `InputEvent.isAction` is.
pub fn appOf(vm: *flux.Vm) *App {
    const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
    return scripts.app;
}

/// An input in words - `Space`, `Left Mouse`, `Pad A` - for the call that
/// asked.
pub fn describe(vm: *flux.Vm, bound: actions.Binding) []const u8 {
    const scripts: *Scripts = @ptrCast(@alignCast(vm.host.?));
    return std.fmt.bufPrint(&scripts.described, "{f}", .{bound}) catch "";
}

/// A type's name as a script writes it, without the file it is in.
fn shortName(t: *const reflect.Type) []const u8 {
    const full = t.name.slice();
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// One of the engine's signals as the scripts' own. See `Scripts.bridges`.
const Bridge = struct {
    source: Entity,
    /// `Component.name`: owned.
    key: []u8,
    signal: flux.Value,
};

fn matchesKey(key: []const u8, component: []const u8, name: []const u8) bool {
    return key.len == component.len + 1 + name.len and std.mem.startsWith(u8, key, component) and
        key[component.len] == '.' and std.mem.endsWith(u8, key, name);
}

/// A file, as read and compiled.
const File = struct {
    /// The path it was read from, as `Project.canonical` spells it, or the
    /// name it was given.
    source: []const u8,
    /// The text last compiled, to tell whether a reload changes anything.
    text: []const u8,
    /// Null while the text does not compile.
    module: ?*flux.object.Module,
    /// Whether there is a file to read again, or only text it was given.
    on_disc: bool,
    /// The file as it was when last read, for `Options.watch` to see it
    /// saved since. Null for text, and for a file the system would not say.
    stamp: ?Stamp = null,
};

/// When a file was last changed, and how long it is: a save in the same
/// tick of a coarse clock still changes the length, as a rule.
const Stamp = struct {
    modified: i96,
    size: u64,

    fn of(io: std.Io, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .modified = stat.mtime.nanoseconds, .size = stat.size };
    }
};

/// The methods the engine calls on a script's instance: what each is passed
/// and when, as the compiler checks a struct's methods against and an
/// editor offers them. See `install`.
const Lifecycle = enum {
    ready,
    fixed,
    update,
    exit,
    input,
    unhandled_input,

    const dt = [_]flux.Hook.Param{.{ .name = "dt", .type = reflect.typeOf(f32) }};
    const event = [_]flux.Hook.Param{.{ .name = "event", .type = reflect.typeOf(InputEvent) }};

    fn hook(self: Lifecycle) flux.Hook {
        return switch (self) {
            .ready => .{ .name = "ready", .doc = "Once, when its entity is in the world with the script made: before anything else of it." },
            .fixed => .{ .name = "fixed", .params = &dt, .doc = "Every fixed step, `dt` seconds of the physics' own clock, before the game's `.fixed` systems: what moves a body." },
            .update => .{ .name = "update", .params = &dt, .doc = "Every frame, `dt` seconds after the last, before the game's `.update` systems." },
            .exit => .{ .name = "exit", .doc = "When its entity dies, its `Script` is taken off or turned off, or the world is cleared: at the end of that frame." },
            .input => .{ .name = "input", .params = &event, .doc = "Each thing the player did this frame, in order. `app.setInputAsHandled()` keeps it from the scripts after, and from `unhandled_input`." },
            .unhandled_input => .{ .name = "unhandled_input", .params = &event, .doc = "What no script's `input` took, and the interface did not have." },
        };
    }

    /// How many parameters it takes besides `self`.
    fn params(self: Lifecycle) usize {
        return self.hook().params.len;
    }
};

/// One entity's instance of its struct.
const Instance = struct {
    file: ScriptHandle,
    struct_name: [48]u8,
    value: flux.Value,
    /// Its struct's methods, looked up when made and after each reload.
    methods: std.EnumArray(Lifecycle, ?flux.Value) = .initFill(null),
    readied: bool = false,
    /// The methods whose failure has been said. The rest are only counted.
    said: std.EnumSet(Lifecycle) = .initEmpty(),
};

/// What the engine calls in `Scripts`, through pointers `App.useScripts`
/// sets: the frame, and the signal table asking what an entity's script
/// declares.
pub const Calls = struct {
    pass: *const fn (self: *Scripts, moment: Moment) Allocator.Error!void,
    clear: *const fn (self: *Scripts) void,
    destroy: *const fn (self: *Scripts) void,
    /// The signals the entity's script declares, as many as `found` holds.
    signals: *const fn (self: *Scripts, entity: Entity, found: []signals.Info) []signals.Info,
    /// The methods the entity's script declares, as many as `found` holds.
    methods: *const fn (self: *Scripts, entity: Entity, found: []signals.MethodInfo) []signals.MethodInfo,
    hasMethod: *const fn (self: *Scripts, entity: Entity, name: []const u8) bool,
    /// Call a method of the entity's script with a signal's arguments.
    callMethod: *const fn (self: *Scripts, entity: Entity, name: []const u8, args: []const reflect.Value) anyerror!void,
    /// Emit the scripts' own signal for an engine's signal, with its
    /// arguments: see `Callable.script`.
    bridge: *const fn (self: *Scripts, source: Entity, component: []const u8, name: []const u8, args: []const reflect.Value) anyerror!void,
    /// Call a script's function at the end of the frame: `app.callDeferred`.
    callDeferred: *const fn (self: *Scripts, callable: flux.Value) anyerror!void,
    /// What a script awaits for the next frame: `app.nextFrame()`.
    nextFrame: *const fn (self: *Scripts) flux.Value,
    /// The fields the entity's script exports, made or not.
    exportedFields: *const fn (self: *Scripts, entity: Entity, found: []flux.FieldInfo) []flux.FieldInfo,
    /// The fields a script's struct exports: a data file's.
    structFields: *const fn (self: *Scripts, script: ScriptHandle, struct_name: []const u8, found: []flux.FieldInfo) []flux.FieldInfo,
    /// A data file's struct, made and given its values: `app.readData`.
    readData: *const fn (self: *Scripts, contents: *const data_file.Contents, source: []const u8) anyerror!flux.Value,
    /// A script's struct as a data file's text: `app.writeData`.
    writeData: *const fn (self: *Scripts, value: flux.Value) anyerror![]u8,
};

/// Where in the frame `Calls.pass` is called.
pub const Moment = union(enum) {
    /// Before the game's `.input` systems: the frame's input, to each
    /// script's `input` and `unhandled_input`.
    input,
    /// Before the game's `.fixed` systems, with the step.
    fixed: f32,
    /// Before the game's `.update` systems, with the frame's delta.
    update: f32,
    /// After the game's `.late` systems: the instances of the dead, and of
    /// the entities whose `Script` went, are let go of.
    end_of_frame,
};

/// The app's scripts: `app.scripts`, once `App.useScripts` has made them.
pub const Scripts = struct {
    app: *App,
    options: Options,
    vm: *flux.Vm,
    calls: Calls,
    /// How a component handle finds its component again.
    resolver: flux.Resolver,
    /// What scripts reach as `files`.
    file_access: FileAccess,
    /// What scripts reach as `time`.
    time_access: TimeAccess,
    /// What scripts reach as `images`.
    images_access: ImagesAccess,
    files: FileTable = .empty,
    /// Each entity's instance, in the order they were made.
    instances: std.AutoArrayHashMapUnmanaged(Entity, Instance) = .empty,
    /// Each instance's entity, by the instance: whose signal an emit is.
    entity_of: std.AutoHashMapUnmanaged(*flux.object.Obj, Entity) = .empty,
    /// The handle each entity is to the scripts, held from the first time
    /// one is handed to them until the end of the frame it dies in.
    handles: std.AutoHashMapUnmanaged(Entity, flux.Value) = .empty,
    /// The value each set of sprite frames is to the scripts, once handed to
    /// them: one set, one value.
    frames_handles: std.AutoHashMapUnmanaged(sprite_frames.SpriteFramesHandle, flux.Value) = .empty,
    /// Entities whose script could not be made, with the `Script` that
    /// asked. It is not tried again until the `Script` or its file changes.
    refused: std.AutoHashMapUnmanaged(Entity, Script) = .empty,
    /// Calls into scripts that failed: a panic, a budget run out, the
    /// scripts' memory run out.
    failures: usize = 0,
    /// Where `print` goes when `Options.out` does not take it.
    printed: Printed = .{},
    /// Entities found in one walk of the world, to act on after it.
    scratch: std.ArrayList(Entity) = .empty,
    /// Seconds since the files were last looked at. See `Options.watch`.
    since_watched: f32 = 0,
    /// Files found saved since they were read, to read after the look.
    changed: std.ArrayList(ScriptHandle) = .empty,
    /// The engine's signals the scripts have reached - `timer.timeout` - each
    /// a signal of the scripts' own, emitted as the engine's is.
    bridges: std.ArrayList(Bridge) = .empty,
    /// What `app.nextFrame()` gives to await this frame. Once one has been
    /// given, the end of the frame makes it `frame_due`, and a new one takes
    /// its place: a wait begun in a frame is over in the next, whatever
    /// part of the frame began it.
    frame: flux.Value = .null,
    frame_given: bool = false,
    /// Emitted at the top of this frame's update, before the scripts'
    /// `update`s.
    frame_due: flux.Value = .null,
    /// The file dialogs scripts asked for, each with the signal its answer
    /// is said on: `files.choose`.
    dialogs: std.ArrayList(Waiting) = .empty,
    /// What `files.dropped()` gives, made the first time.
    drop_signal: flux.Value = .null,
    /// Files outside the game and `user://` a script may read: the player
    /// chose them, or let them go over the window.
    granted: std.StringHashMapUnmanaged(void) = .empty,
    /// What `app.callDeferred` was given, called at the end of the frame.
    deferred: std.ArrayList(flux.Value) = .empty,
    /// Whether the event being handed round was taken: see
    /// `App.setInputAsHandled`.
    input_handled: bool = false,
    /// `InputEvent.describe`'s words, for the call that asked.
    described: [64]u8 = undefined,
    /// The words a date, a time or a span was written in, for the call that
    /// asked: see `datetime.zig`.
    said: [512]u8 = undefined,
    /// The value each clock is to the scripts, once handed to them.
    clock_values: std.AutoHashMapUnmanaged(u64, flux.Value) = .empty,
    /// A clock's `minute_passed`, `hour_passed` and `day_passed`, once a
    /// script has reached for them; `.null` for one it has not.
    clock_signals: std.AutoHashMapUnmanaged(u64, [3]flux.Value) = .empty,

    /// The VM, with `app` and `self.entity` in it.
    pub fn create(app: *App, options: Options) (Allocator.Error || flux.Vm.Error)!*Scripts {
        const self = try app.gpa.create(Scripts);
        errdefer app.gpa.destroy(self);
        self.* = .{
            .app = app,
            .options = options,
            .vm = undefined,
            .calls = .{
                .pass = pass,
                .clear = clear,
                .destroy = destroy,
                .signals = signalsOf,
                .methods = methodsOf,
                .hasMethod = hasMethod,
                .callMethod = callMethod,
                .bridge = bridge,
                .callDeferred = callDeferred,
                .nextFrame = nextFrame,
                .exportedFields = exportedFields,
                .structFields = structFields,
                .readData = readData,
                .writeData = writeData,
            },
            .resolver = .{
                .context = app,
                .resolve = findComponent,
                .why = "its entity was despawned, or the component was taken off",
            },
            .file_access = .{ .app = app },
            .time_access = .{ .app = app },
            .images_access = .{ .app = app },
        };
        const vm = try flux.Vm.create(app.gpa, .{
            .out = options.out orelse &self.printed.writer,
            .max_bytes = options.max_bytes,
            .io = app.io,
            .on_task_panic = sayTaskPanic,
            .on_emit = heardEmit,
            .loader = .{ .context = app, .load = loadImport },
        });
        errdefer vm.destroy();
        vm.host = self;
        try install(vm, app, .{
            .app = try vm.handle(app),
            .files = try vm.handle(&self.file_access),
            .time = try vm.handle(&self.time_access),
            .images = try vm.handle(&self.images_access),
        });
        self.frame = try vm.newSignal("frame", 0);
        try vm.hold(self.frame);
        self.vm = vm;
        return self;
    }

    fn destroy(self: *Scripts) void {
        const gpa = self.app.gpa;
        // The collector frees the instances and every `EntityRef` with the
        // VM.
        self.vm.destroy();
        self.instances.deinit(gpa);
        self.entity_of.deinit(gpa);
        self.handles.deinit(gpa);
        self.frames_handles.deinit(gpa);
        self.clock_values.deinit(gpa);
        self.clock_signals.deinit(gpa);
        self.refused.deinit(gpa);
        self.scratch.deinit(gpa);
        self.changed.deinit(gpa);
        for (self.bridges.items) |held| gpa.free(held.key);
        self.bridges.deinit(gpa);
        self.deferred.deinit(gpa);
        var it = self.files.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value.source);
            gpa.free(entry.value.text);
        }
        self.files.deinit(gpa);
        self.dialogs.deinit(gpa);
        var given = self.granted.keyIterator();
        while (given.next()) |path| gpa.free(path.*);
        self.granted.deinit(gpa);
        gpa.destroy(self);
    }

    // ---------------------------------------------------------------------
    // Files
    // ---------------------------------------------------------------------

    /// Read a `.flux` file and compile it, or find the one read from there
    /// already. A file that reads and does not compile is kept, and its
    /// reasons are said: see `Script`.
    pub fn load(self: *Scripts, path: []const u8) !ScriptHandle {
        const app = self.app;
        const io = app.io orelse return error.NoIo;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;

        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        // Looked at before it is read: a save between the two is seen at the
        // next look, not taken for what was read.
        const stamp: ?Stamp = .of(io, file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        const made = try self.keep(source, text, true);
        if (self.files.get(made.toId())) |kept| kept.stamp = stamp;
        return made;
    }

    /// A script from text, not a file: a test's, or a tool's. `name` is what
    /// the log and a scene call it, and what `find` finds it by. A name
    /// given before gets the new text.
    pub fn add(self: *Scripts, name: []const u8, text: []const u8) !ScriptHandle {
        if (self.find(name)) |known| {
            try self.setText(known, text);
            return known;
        }
        return self.keep(name, try self.app.gpa.dupe(u8, text), false);
    }

    /// Takes `text`, which `gpa` allocated.
    fn keep(self: *Scripts, source: []const u8, text: []u8, on_disc: bool) !ScriptHandle {
        const gpa = self.app.gpa;
        errdefer gpa.free(text);
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        const made: ScriptHandle = .fromId(try self.files.add(gpa, .{ .source = name, .text = text, .module = null, .on_disc = on_disc }));
        self.compile(made);
        return made;
    }

    /// Compile a file for the first time, or again after it did not.
    fn compile(self: *Scripts, handle: ScriptHandle) void {
        const file = self.files.get(handle.toId()).?;
        // Its text stays where it is, and the `File` may not: running the
        // top level can load another script, and the table grow.
        const source = file.source;
        if (!self.options.run) {
            // An editor's: the structs are made by compiling, and nothing
            // runs. Text that does not compile leaves the last that did.
            const compiled = self.vm.compile(source, file.text) catch |err| switch (err) {
                error.CompileFailed => return self.sayDiagnostics(source),
                error.OutOfMemory => return self.outOfMemory(null),
            };
            self.files.get(handle.toId()).?.module = compiled;
            return;
        }
        const module = self.vm.load(source, file.text) catch |err| switch (err) {
            error.CompileFailed => return self.sayDiagnostics(source),
            // Compiled, and its top level stopped: the structs are there.
            error.Panic => blk: {
                self.sayPanic(null, "the top level of a script");
                break :blk self.vm.moduleNamed(source);
            },
            error.OutOfMemory => return self.outOfMemory(null),
        };
        self.files.get(handle.toId()).?.module = module;
    }

    /// The handle of a file already read, by the path or name it was read by.
    pub fn find(self: *Scripts, source: []const u8) ?ScriptHandle {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return .fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *Scripts, handle: ScriptHandle) ?[]const u8 {
        const file = self.files.get(handle.toId()) orelse return null;
        return file.source;
    }

    /// The module a file compiled into; null while it does not compile.
    pub fn moduleOf(self: *Scripts, handle: ScriptHandle) ?*flux.object.Module {
        const file = self.files.get(handle.toId()) orelse return null;
        return file.module;
    }

    /// The instance of an entity's script, while it has one.
    pub fn instanceOf(self: *Scripts, entity: Entity) ?flux.Value {
        const inst = self.instances.getPtr(entity) orelse return null;
        return inst.value;
    }

    /// Read a file again and put its code in while the game runs. Instances
    /// keep their fields and go on with the new code. Says whether there was
    /// a file to read. Not for a script made from text, nor for a handle
    /// that has expired. Text that does not compile leaves the old code
    /// running, and the reasons are said.
    pub fn reload(self: *Scripts, handle: ScriptHandle) !bool {
        const app = self.app;
        const file = self.files.get(handle.toId()) orelse return false;
        if (!file.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const path = try app.project.osPath(app.gpa, file.source);
        defer app.gpa.free(path);
        const stamp: ?Stamp = .of(io, path);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, app.gpa, .limited(file_limit));
        defer app.gpa.free(text);
        try self.setText(handle, text);
        // Looked up again: the new code's defaults can load a script.
        if (self.files.get(handle.toId())) |read| read.stamp = stamp;
        return true;
    }

    /// Each file saved since it was read, read again: see `Options.watch`.
    /// One that does not read now - held by the program saving it - is
    /// tried again at the next look.
    fn watchFiles(self: *Scripts) Allocator.Error!void {
        const app = self.app;
        const io = app.io orelse return;
        // Found first and read after: reading runs code, which can load a
        // script into the table being walked.
        self.changed.clearRetainingCapacity();
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const path = app.project.osPath(app.gpa, entry.value.source) catch continue;
            defer app.gpa.free(path);
            const now = Stamp.of(io, path) orelse continue;
            if (entry.value.stamp) |then| if (std.meta.eql(then, now)) continue;
            try self.changed.append(app.gpa, .fromId(entry.handle));
        }
        for (self.changed.items) |handle| {
            if (self.reload(handle)) |_| {
                log.info("{s} was saved, and is read again", .{self.sourceOf(handle) orelse "a script"});
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.warn("{s} was saved, and does not read yet: {t}", .{ self.sourceOf(handle) orelse "a script", err }),
            }
        }
    }

    /// New code for a script, from text rather than its file: an editor's
    /// unsaved changes. Text the same as the last compiled changes nothing.
    /// Not from inside a script: that is `error.Busy`.
    pub fn setText(self: *Scripts, handle: ScriptHandle, text: []const u8) !void {
        const gpa = self.app.gpa;
        const file = self.files.get(handle.toId()) orelse return error.NoSuchScript;
        if (file.module != null and std.mem.eql(u8, file.text, text)) return;
        const kept = try gpa.dupe(u8, text);
        gpa.free(file.text);
        file.text = kept;

        // As in `compile`: a default the reload runs can load a script.
        const source = file.source;
        if (!self.options.run) {
            // Nothing runs and no instance holds the old code: compiled
            // afresh.
            self.compile(handle);
        } else if (file.module) |module| {
            const report = self.vm.reload(module, kept) catch |err| switch (err) {
                error.CompileFailed => return self.sayDiagnostics(source),
                error.Busy => return error.Busy,
                error.OutOfMemory => return error.OutOfMemory,
                // The new code is in, and a default it ran stopped.
                error.Panic => blk: {
                    self.sayPanic(null, "a default of a script");
                    break :blk flux.Vm.Reload{};
                },
            };
            if (report.stopped > 0) log.warn("{s} changed shape at {s}: {d} tasks in the old code were stopped", .{ source, report.changed orelse "?", report.stopped });
        } else self.compile(handle);

        // The struct may be there now, or gone: each entity is looked at
        // afresh, and each failure said again.
        self.refused.clearRetainingCapacity();
        for (self.instances.values()) |*inst| {
            inst.said = .initEmpty();
            self.lookUp(inst);
        }
        // A signal the new code declares may have connections waiting: on
        // each entity the file is on, whether it has an instance or not.
        try self.knowConnectionsOf(handle);
    }

    fn knowConnectionsOf(self: *Scripts, handle: ScriptHandle) Allocator.Error!void {
        const app = self.app;
        self.scratch.clearRetainingCapacity();
        var query = ecs.Query(.{Script}).over(&app.world) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooManyComponents => return,
        };
        while (query.next()) |chunk| {
            for (chunk.entities, chunk.slice(Script)) |entity, script| {
                if (script.source.eql(handle)) try self.scratch.append(app.gpa, entity);
            }
        }
        for (self.scratch.items) |entity| try self.knowConnections(entity);
    }

    /// Give each script of the project's that has no UUID one, in a `.uid`
    /// file beside it, as `Assets.ensureUids` does for textures and fonts.
    pub fn ensureUids(self: *Scripts) !void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (entry.value.on_disc and Project.isProjectPath(entry.value.source)) _ = try self.app.project.ensureUid(entry.value.source);
        }
    }

    /// The file or folder at `old` is now at `new`, both as
    /// `Project.canonical` spells them: a script read from under it is
    /// found at its new place.
    pub fn renamed(self: *Scripts, old: []const u8, new: []const u8) Allocator.Error!void {
        const gpa = self.app.gpa;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }

    // ---------------------------------------------------------------------
    // The frame
    // ---------------------------------------------------------------------

    fn pass(self: *Scripts, moment: Moment) Allocator.Error!void {
        // An editor's scripts are never made, stepped or looked for.
        if (!self.options.run) return;
        switch (moment) {
            .input => {
                try self.sync();
                self.readyTheNew();
                self.deliverInput();
                self.answerDialogs();
                self.hearDrops();
            },
            .fixed => |dt| {
                try self.sync();
                self.readyTheNew();
                self.callEach(.fixed, dt);
            },
            .update => |dt| {
                // First, so what was saved runs this frame.
                if (self.options.watch) |every| {
                    self.since_watched += self.app.time.unscaled_delta;
                    if (self.since_watched >= every) {
                        self.since_watched = 0;
                        try self.watchFiles();
                    }
                }
                try self.sync();
                self.readyTheNew();
                // What waited for this frame goes on first.
                if (self.frame_due.tag == .signal) {
                    const due = self.frame_due;
                    self.frame_due = .null;
                    defer self.vm.release(due);
                    self.vm.setBudget(self.options.budget);
                    self.vm.emitSignalValue(due, &.{}) catch |err| switch (err) {
                        error.OutOfMemory => self.outOfMemory(null),
                        error.Panic => self.sayPanic(null, "the next frame of"),
                    };
                }
                self.emitClocks();
                self.callEach(.update, dt);
                // The scripts' own clock, so `await wait(1.0)` wakes - but
                // not the waits of the entities that do not run now.
                self.vm.setBudget(self.options.budget);
                self.vm.updateHolding(dt, .{ .context = self.app, .held = heldOwner }) catch |err| switch (err) {
                    error.OutOfMemory => self.outOfMemory(null),
                    error.Panic => self.sayPanic(null, "the tasks of"),
                };
            },
            .end_of_frame => {
                self.callTheDeferred();
                try self.letGoOfTheUnwanted();
                self.forgetDeadBridges();
                if (self.frame_given) {
                    // Held already: it goes from one place to the other.
                    const next = self.vm.newSignal("frame", 0) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // Making one runs no script.
                        error.Panic => unreachable,
                    };
                    try self.vm.hold(next);
                    self.frame_due = self.frame;
                    self.frame = next;
                    self.frame_given = false;
                }
                // A refusal of the dead is forgotten: its slot, given out
                // again, is another entity. Removing leaves the table where
                // it is, so the walk goes on.
                var it = self.refused.keyIterator();
                while (it.next()) |entity| {
                    if (!self.app.world.isAlive(entity.*)) self.refused.removeByPtr(entity);
                }
                // So is a dead entity's handle. A script that kept it keeps
                // it, and it answers as a dead entity's.
                var handles = self.handles.iterator();
                while (handles.next()) |entry| {
                    if (self.app.world.isAlive(entry.key_ptr.*)) continue;
                    self.vm.release(entry.value_ptr.*);
                    self.handles.removeByPtr(entry.key_ptr);
                }
            },
        }
    }

    /// Make an instance for each enabled `Script` without one, and let go of
    /// each instance whose entity is dead or whose `Script` has gone, changed
    /// or been turned off.
    fn sync(self: *Scripts) Allocator.Error!void {
        const app = self.app;
        try self.letGoOfTheUnwanted();

        // Found first and made after: making one runs its struct's defaults,
        // which may change the world the query is walking.
        self.scratch.clearRetainingCapacity();
        var query = ecs.Query(.{Script}).over(&app.world) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Nothing has a `Script` then.
            error.TooManyComponents => return,
        };
        while (query.next()) |chunk| {
            for (chunk.entities, chunk.slice(Script)) |entity, script| {
                if (!script.enabled or script.source.isNone() or self.instances.contains(entity)) continue;
                if (self.refused.get(entity)) |asked| if (std.meta.eql(asked, script)) continue;
                try self.scratch.append(app.gpa, entity);
            }
        }
        for (self.scratch.items) |entity| {
            // Looked at again: making the ones before may have changed it.
            const script = (app.world.getConst(entity, Script) orelse continue).*;
            if (!script.enabled or script.source.isNone() or self.instances.contains(entity)) continue;
            try self.make(entity, script);
        }
    }

    fn letGoOfTheUnwanted(self: *Scripts) Allocator.Error!void {
        self.scratch.clearRetainingCapacity();
        for (self.instances.keys(), self.instances.values()) |entity, *inst| {
            if (!self.wanted(entity, inst)) try self.scratch.append(self.app.gpa, entity);
        }
        // Each taken out before its `exit`, which may change the rest.
        for (self.scratch.items) |entity| {
            const gone = self.instances.fetchOrderedRemove(entity) orelse continue;
            self.letGo(entity, gone.value);
        }
    }

    fn wanted(self: *Scripts, entity: Entity, inst: *const Instance) bool {
        const script = self.app.world.getConst(entity, Script) orelse return false;
        return script.enabled and script.source.eql(inst.file) and std.mem.eql(u8, &script.struct_name, &inst.struct_name);
    }

    fn make(self: *Scripts, entity: Entity, script: Script) Allocator.Error!void {
        const file = self.files.get(script.source.toId()) orelse
            return self.refuse(entity, script, "its script has been let go of", .{});
        const source = file.source;
        const module = file.module orelse
            return self.refuse(entity, script, "{s} does not compile", .{source});
        var spelled: [64]u8 = undefined;
        const class = classFor(self.vm, module, &script, source, &spelled) orelse {
            const asked = script.structName();
            if (asked.len != 0) return self.refuse(entity, script, "{s} has no struct called {s}", .{ source, asked });
            return self.refuse(entity, script, "{s} has no struct named after the file: {s}", .{ source, expected(source, &spelled) });
        };

        const vm = self.vm;
        const ref = entityHandle(self, entity) catch |err| switch (err) {
            error.OutOfMemory => return self.outOfMemory(entity),
            error.Panic => unreachable,
        };
        vm.setBudget(self.options.budget);
        const value = vm.instantiate(class, &.{.{ .name = "entity", .value = ref }}) catch |err| switch (err) {
            error.OutOfMemory => return self.outOfMemory(entity),
            error.Panic => {
                self.sayPanic(entity, "making the script of");
                return self.refuse(entity, script, "its defaults stopped", .{});
            },
        };
        vm.hold(value) catch return self.outOfMemory(entity);
        // What the scene gives its `@export`s, before anything of it runs.
        if (self.app.exports.of(entity)) |values| {
            self.applyValues(value, class, values, .{ .entity = entity }) catch return self.outOfMemory(entity);
        }

        var inst: Instance = .{ .file = script.source, .struct_name = script.struct_name, .value = value };
        self.lookUp(&inst);
        self.instances.put(self.app.gpa, entity, inst) catch |err| {
            vm.release(value);
            return err;
        };
        self.entity_of.put(self.app.gpa, value.obj(), entity) catch |err| {
            _ = self.instances.orderedRemove(entity);
            vm.release(value);
            return err;
        };
        try self.knowConnections(entity);
    }

    fn refuse(self: *Scripts, entity: Entity, script: Script, comptime why: []const u8, args: anytype) Allocator.Error!void {
        try self.refused.put(self.app.gpa, entity, script);
        log.warn("the script of {f} is not made: " ++ why, .{entity} ++ args);
    }

    /// Its struct's methods, each checked for the parameters the engine
    /// passes.
    fn lookUp(self: *Scripts, inst: *Instance) void {
        const class = flux.classOf(inst.value) orelse return;
        var buffer: [64]flux.Member = undefined;
        const members = flux.methodsOf(class, &buffer);
        for (std.enums.values(Lifecycle)) |which| {
            const method = self.vm.methodNamed(class, @tagName(which));
            inst.methods.set(which, method);
            if (method == null) continue;
            const member = for (members) |m| {
                if (std.mem.eql(u8, m.name, @tagName(which))) break m;
            } else continue;
            if (member.params == which.params()) continue;
            inst.methods.set(which, null);
            if (!inst.said.contains(which)) {
                inst.said.insert(which);
                log.warn("`{s}` takes {d} parameters besides self, and the engine passes {d}: it is not called", .{
                    member.name,
                    member.params,
                    which.params(),
                });
            }
        }
    }

    /// `ready` for each instance made since the last pass.
    fn readyTheNew(self: *Scripts) void {
        var at: usize = 0;
        // By index, and each looked at again after a call: a script can
        // clear the world, and the instances with it.
        while (at < self.instances.count()) : (at += 1) {
            const inst = &self.instances.values()[at];
            if (inst.readied) continue;
            inst.readied = true;
            const method = inst.methods.get(.ready) orelse continue;
            self.call(self.instances.keys()[at], method, &.{inst.value}, .ready);
        }
    }

    fn callEach(self: *Scripts, comptime which: Lifecycle, dt: f32) void {
        var at: usize = 0;
        while (at < self.instances.count()) : (at += 1) {
            const inst = self.instances.values()[at];
            if (!inst.readied) continue;
            const method = inst.methods.get(which) orelse continue;
            const entity = self.instances.keys()[at];
            if (!self.app.isProcessing(entity)) continue;
            self.call(entity, method, &.{ inst.value, .float(dt) }, which);
        }
    }

    /// Whether the tasks of an owner - an entity, as `call` gives them one -
    /// wait. A task of no entity's waits while the game is paused, as a
    /// root with no `Processing` would.
    fn heldOwner(context: ?*anyopaque, owner: u64) bool {
        const app: *App = @ptrCast(@alignCast(context.?));
        if (owner == 0) return app.paused;
        const entity = Entity.fromInt(owner);
        if (!app.world.isAlive(entity)) return app.paused;
        return !app.isProcessing(entity);
    }

    /// An instance let go of: its `exit`, if it was readied, and then the
    /// collector may have it.
    fn letGo(self: *Scripts, entity: Entity, inst: Instance) void {
        // What `exit` emits is still its entity's.
        if (inst.readied) {
            if (inst.methods.get(.exit)) |method| self.call(entity, method, &.{inst.value}, .exit);
        }
        // What it was waiting for goes with it: a task of an entity that is
        // gone would wake to find nothing where it was.
        _ = self.vm.stopTasks(entity.toInt()) catch |err| log.warn("the tasks of {f} were not stopped: {t}", .{ entity, err });
        _ = self.entity_of.remove(inst.value.obj());
        self.vm.release(inst.value);
    }

    /// Every instance let go of, each with its `exit`: the world was cleared.
    fn clear(self: *Scripts) void {
        // The table's connections go with the world; so do their signals.
        for (self.bridges.items) |held| {
            self.vm.release(held.signal);
            self.app.gpa.free(held.key);
        }
        self.bridges.clearRetainingCapacity();
        // Taken out first, so an `exit` that clears the world again finds
        // nothing to let go of twice.
        var taken = self.instances;
        self.instances = .empty;
        defer taken.deinit(self.app.gpa);
        for (taken.keys(), taken.values()) |entity, inst| self.letGo(entity, inst);
        self.refused.clearRetainingCapacity();
    }

    // ---------------------------------------------------------------------
    // Signals, both ways
    // ---------------------------------------------------------------------

    /// The struct an entity's script makes, whether its instance is made
    /// yet or not: what its signals and methods are listed from, so a scene
    /// read before the first frame connects to them.
    fn classOfEntity(self: *Scripts, entity: Entity) ?flux.Value {
        if (self.instances.getPtr(entity)) |inst| return flux.classOf(inst.value);
        const script = self.app.world.getConst(entity, Script) orelse return null;
        const file = self.files.get(script.source.toId()) orelse return null;
        const module = file.module orelse return null;
        var spelled: [64]u8 = undefined;
        return classFor(self.vm, module, script, file.source, &spelled);
    }

    fn signalsOf(self: *Scripts, entity: Entity, found: []signals.Info) []signals.Info {
        const class = self.classOfEntity(entity) orelse return found[0..0];
        var members: [64]flux.Member = undefined;
        const listed = flux.signalsOf(class, members[0..@min(found.len, members.len)]);
        for (listed, found[0..listed.len]) |m, *into| {
            into.* = .{
                .component = component_name,
                .name = m.name,
                .args = reflect.typeOf(ScriptArguments),
                .signature = m.signature,
                .arity = m.params,
            };
        }
        return found[0..listed.len];
    }

    fn methodsOf(self: *Scripts, entity: Entity, found: []signals.MethodInfo) []signals.MethodInfo {
        const class = self.classOfEntity(entity) orelse return found[0..0];
        var members: [64]flux.Member = undefined;
        const listed = flux.methodsOf(class, members[0..@min(found.len, members.len)]);
        for (listed, found[0..listed.len]) |m, *into| {
            into.* = .{ .component = component_name, .name = m.name, .params = &.{}, .signature = m.signature, .arity = m.params };
        }
        return found[0..listed.len];
    }

    fn hasMethod(self: *Scripts, entity: Entity, name: []const u8) bool {
        const class = self.classOfEntity(entity) orelse return false;
        return self.vm.hasMethod(class, name);
    }

    /// A signal's call of a method the entity's script declares, with the
    /// signal's arguments as the script's own values, as `flux.Vm.valueOf`
    /// makes them: an entity as its handle. An instance not made yet - a
    /// signal emitted before the first frame - is made and readied first.
    fn callMethod(self: *Scripts, entity: Entity, name: []const u8, args: []const reflect.Value) anyerror!void {
        if (!self.options.run) return error.NotRunning;
        const class = self.classOfEntity(entity) orelse return error.NoSuchMethod;
        const method = self.vm.methodNamed(class, name) orelse return error.NoSuchMethod;
        if (args.len >= max_args) return error.WrongArguments;
        if (!self.instances.contains(entity)) {
            const script = (self.app.world.getConst(entity, Script) orelse return error.NoSuchMethod).*;
            if (!script.enabled) return error.NoSuchMethod;
            try self.make(entity, script);
            self.readyTheNew();
        }
        const inst = self.instances.getPtr(entity) orelse return error.NoSuchMethod;

        const vm = self.vm;
        var values: [max_args]flux.Value = undefined;
        values[0] = inst.value;
        var made: usize = 0;
        // Each held until the call: making the next can collect.
        defer for (values[1 .. made + 1]) |v| vm.release(v);
        for (args, values[1 .. args.len + 1]) |arg, *into| {
            into.* = try vm.valueOf(arg);
            try vm.hold(into.*);
            made += 1;
        }
        vm.setBudget(self.options.budget);
        // What the call starts belongs to the entity.
        const owner = vm.setTaskOwner(entity.toInt());
        defer _ = vm.setTaskOwner(owner);
        _ = vm.call(method, values[0 .. args.len + 1]) catch |err| {
            self.failures += 1;
            switch (err) {
                error.Panic => self.writePanic(entity, "a signal's call into the script of"),
                error.OutOfMemory => {},
            }
            return err;
        };
    }

    // ---------------------------------------------------------------------
    // Input
    // ---------------------------------------------------------------------

    /// Every event of the frame, one at a time: to each `input`, in the
    /// order the instances were made, until one takes it; then, if none did
    /// and the interface did not have it, to each `unhandled_input`.
    fn deliverInput(self: *Scripts) void {
        var any = false;
        for (self.instances.values()) |inst| {
            if (inst.methods.get(.input) != null or inst.methods.get(.unhandled_input) != null) any = true;
        }
        if (!any) return;
        const app = self.app;
        var events: std.ArrayList(InputEvent) = .empty;
        defer events.deinit(app.gpa);
        self.gather(&events) catch return self.outOfMemory(null);
        for (events.items) |event| self.deliver(event);
    }

    fn gather(self: *Scripts, events: *std.ArrayList(InputEvent)) Allocator.Error!void {
        const app = self.app;
        const gpa = app.gpa;
        for (app.input.keyEvents()) |k| try events.append(gpa, .{ .key = .{
            .key = k.key,
            .virtual_key = k.virtual,
            .pressed = k.action.down(),
            .echo = k.action == .repeat,
            .mods = k.mods,
        } });
        try events.appendSlice(gpa, app.input.pointerEvents());
        for (app.input.pads, 0..) |state, slot| {
            for (0..platform.GamepadButton.count) |i| {
                const went_down = state.pressed.isSet(i);
                const came_up = state.released.isSet(i);
                if (went_down) try events.append(gpa, .{ .pad_button = .{ .button = @enumFromInt(i), .pad = @intCast(slot), .pressed = true } });
                if (came_up) try events.append(gpa, .{ .pad_button = .{ .button = @enumFromInt(i), .pad = @intCast(slot), .pressed = false } });
            }
        }
    }

    fn deliver(self: *Scripts, event: InputEvent) void {
        const vm = self.vm;
        var held = event;
        const value = vm.valueOf(reflect.Value.of(&held)) catch return self.outOfMemory(null);
        vm.hold(value) catch return self.outOfMemory(null);
        defer vm.release(value);
        self.input_handled = false;
        defer self.input_handled = false;
        for ([_]Lifecycle{ .input, .unhandled_input }) |which| {
            if (which == .unhandled_input and self.takenByInterface(event)) return;
            var at: usize = 0;
            while (at < self.instances.count()) : (at += 1) {
                const inst = self.instances.values()[at];
                if (!inst.readied) continue;
                const method = inst.methods.get(which) orelse continue;
                const entity = self.instances.keys()[at];
                if (!self.app.isProcessing(entity)) continue;
                self.call(entity, method, &.{ inst.value, value }, which);
                if (self.input_handled) return;
            }
        }
    }

    /// Whether the interface had it: a key while a field has the keys, the
    /// pointer over what it draws or taken by a system.
    fn takenByInterface(self: *Scripts, event: InputEvent) bool {
        const app = self.app;
        return switch (event) {
            .key => app.ui.wantsKeyboard(),
            .mouse_button, .mouse_motion, .wheel => app.input.isHandled() or app.ui.wantsPointer(),
            .pad_button => false,
        };
    }

    // ---------------------------------------------------------------------
    // `@export`s
    // ---------------------------------------------------------------------

    fn exportedFields(self: *Scripts, entity: Entity, found: []flux.FieldInfo) []flux.FieldInfo {
        const class = self.classOfEntity(entity) orelse return found[0..0];
        return exportsOf(self.vm, class, found);
    }

    fn structFields(self: *Scripts, script: ScriptHandle, struct_name: []const u8, found: []flux.FieldInfo) []flux.FieldInfo {
        const file = self.files.get(script.toId()) orelse return found[0..0];
        const module = file.module orelse return found[0..0];
        var spelled: [64]u8 = undefined;
        const class = classAsked(self.vm, module, struct_name, file.source, &spelled) orelse return found[0..0];
        return exportsOf(self.vm, class, found);
    }

    fn exportsOf(vm: *flux.Vm, class: flux.Value, found: []flux.FieldInfo) []flux.FieldInfo {
        var all: [64]flux.FieldInfo = undefined;
        var count: usize = 0;
        for (flux.fieldsOf(vm, class, &all)) |field| {
            if (!field.exported) continue;
            if (count == found.len) break;
            found[count] = field;
            count += 1;
        }
        return found[0..count];
    }

    /// Whose values `applyValues` sets, for what it says of them.
    const Whose = union(enum) {
        /// An entity's script's, from `app.exports`.
        entity: Entity,
        /// A data file's struct's, from the file.
        file: []const u8,

        pub fn format(self: Whose, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .entity => |e| try w.print("the script of {f}", .{e}),
                .file => |path| try w.writeAll(path),
            }
        }
    };

    /// `values`, an object by field, set on the instance's `@export`s; what
    /// does not fit is said and passed over.
    fn applyValues(self: *Scripts, instance: flux.Value, class: flux.Value, values: json.Value, whose: Whose) Allocator.Error!void {
        const given = values.asObject() orelse return;
        var buffer: [64]flux.FieldInfo = undefined;
        const fields = flux.fieldsOf(self.vm, class, &buffer);
        for (given.keys(), given.values()) |name, value| {
            const field = for (fields) |f| {
                if (f.exported and std.mem.eql(u8, f.name, name)) break f;
            } else {
                log.warn("{f} exports no {s}: the value given it is passed over", .{ whose, name });
                continue;
            };
            const made = self.fluxOf(field, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Panic => {
                    self.vm.clearPanic();
                    continue;
                },
            } orelse {
                log.warn("{s} of {f} holds {t}, and is given {f}", .{ name, whose, field.kind, value });
                continue;
            };
            self.vm.setField(instance, name, made) catch |err| {
                log.warn("{s} of {f} was not given its value: {t}", .{ name, whose, err });
            };
        }
    }

    /// A struct as a data file: the script it is in, its name - empty when it
    /// is the one named after its file - and its `@export` fields' values.
    fn writeData(self: *Scripts, value: flux.Value) anyerror![]u8 {
        const class = flux.classOf(value) orelse return error.NotAStruct;
        const module = class.as(flux.object.Class).module orelse return error.NotAStruct;
        const source = self.sourceOfModule(module) orelse return error.NotAStruct;

        var doc = try json.Document.init(self.app.gpa);
        defer doc.deinit();
        const values = try doc.object();
        var found: [128]flux.FieldInfo = undefined;
        for (flux.fieldsOf(self.vm, class, &found)) |field| {
            if (!field.exported) continue;
            const held = self.vm.getField(value, field.name) orelse continue;
            const written = try jsonOf(&doc, held);
            if (written == .null and held.tag != .null) {
                log.warn("{s} of a {s} is not written to its data file: a file cannot say it", .{ field.name, class.as(flux.object.Class).name.bytes() });
                continue;
            }
            try values.put(field.name, written);
        }

        const name = class.as(flux.object.Class).name.bytes();
        var spelled: [64]u8 = undefined;
        const own = std.mem.eql(u8, name, std.fs.path.stem(source)) or std.mem.eql(u8, name, expected(source, &spelled));
        return data_file.write(self.app.gpa, source, if (own) "" else name, values);
    }

    /// The path of the script a compiled module is: one of the scripts'
    /// files, or one a script imported, named as `loadImport` names it.
    fn sourceOfModule(self: *Scripts, module: *flux.object.Module) ?[]const u8 {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (entry.value.module == module) return entry.value.source;
        }
        const name = module.name.bytes();
        return if (std.mem.startsWith(u8, name, Project.scheme)) name else null;
    }

    /// A data file's struct, made anew with the file's values: a struct with
    /// nothing to give it, as a data file's is.
    fn readData(self: *Scripts, contents: *const data_file.Contents, source: []const u8) anyerror!flux.Value {
        const handle = try self.load(contents.script);
        const file = self.files.get(handle.toId()) orelse return error.NoSuchScript;
        const module = file.module orelse return error.ScriptDoesNotCompile;
        var spelled: [64]u8 = undefined;
        const class = classAsked(self.vm, module, contents.struct_name, file.source, &spelled) orelse return error.NoSuchStruct;
        const vm = self.vm;
        const made = vm.instantiate(class, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Panic => {
                self.sayPanic(null, "making the struct of a data file");
                return error.DefaultsStopped;
            },
        };
        try vm.pushRoot(made);
        defer vm.popRoot();
        try self.applyValues(made, class, contents.values, .{ .file = source });
        return made;
    }

    /// A value a scene wrote as the script's own, as a field of `field`'s
    /// kind holds it; null for one it cannot hold.
    fn fluxOf(self: *Scripts, field: flux.FieldInfo, value: json.Value) flux.Vm.Error!?flux.Value {
        if (value == .null) return if (field.nullable or field.kind == .any) .null else null;
        if (flux.annotationOf(field, "entity") != null) {
            const text = value.asString() orelse return null;
            const uuid = id.Uuid.parse(text) catch return null;
            const entity = self.app.findUuid(uuid) orelse return .null;
            return try entityHandle(self, entity);
        }
        return self.fluxOfKind(field.kind, field, value);
    }

    fn fluxOfKind(self: *Scripts, kind: flux.FieldKind, field: flux.FieldInfo, value: json.Value) flux.Vm.Error!?flux.Value {
        const vm = self.vm;
        switch (kind) {
            .int => return .int(value.asInt(i64) orelse return null),
            .float => return .float(value.asFloat(f64) orelse return null),
            .bool => return .boolean(value.asBool() orelse return null),
            .string => return try vm.string(value.asString() orelse return null),
            .vec2, .vec3 => {
                const n: usize = if (kind == .vec2) 2 else 3;
                if (value.len() != n or value.asArray() == null) return null;
                var xyz: [3]f32 = @splat(0);
                for (0..n) |i| xyz[i] = @floatCast(value.get(i).asFloat(f64) orelse return null);
                return if (kind == .vec2) .vec2(xyz[0], xyz[1]) else .vec3(xyz[0], xyz[1], xyz[2]);
            },
            .color => {
                if (value.asString()) |text| {
                    const c = Color.parse(text) orelse return null;
                    return try vm.newColor(.{ c.r, c.g, c.b, c.a });
                }
                if (value.asArray() == null or (value.len() != 3 and value.len() != 4)) return null;
                var rgba: [4]f32 = .{ 0, 0, 0, 1 };
                for (0..value.len()) |i| rgba[i] = @floatCast(value.get(i).asFloat(f64) orelse return null);
                return try vm.newColor(rgba);
            },
            .enum_member => {
                const name = value.asString() orelse return null;
                const e = field.enum_type orelse return null;
                for (field.members, 0..) |member, i| {
                    if (std.mem.eql(u8, member.bytes(), name)) return flux.enumMember(e, @intCast(i));
                }
                return null;
            },
            .list => {
                const items = value.asArray() orelse return null;
                if (items.len() > 1024) return null;
                var made: std.ArrayList(flux.Value) = .empty;
                defer made.deinit(self.app.gpa);
                // Each rooted until the list has it: making the next can
                // collect.
                defer for (made.items) |_| vm.popRoot();
                for (items.items()) |item| {
                    const one = try self.fluxOfKind(field.element, field, item) orelse return null;
                    try made.append(self.app.gpa, one);
                    try vm.pushRoot(one);
                }
                return try vm.newList(field.element_check, made.items);
            },
            .any => return switch (value) {
                .int => |n| .int(n),
                .float => |f| .float(f),
                .bool => |b| .boolean(b),
                .string => |text| try vm.string(text),
                else => null,
            },
            else => return null,
        }
    }

    // ---------------------------------------------------------------------
    // The engine's signals, as the scripts' own
    // ---------------------------------------------------------------------

    /// The scripts' own signal for `component.name` of `source`, made the
    /// first time a script reaches it and connected to the engine's.
    /// A clock's `minute_passed`, `hour_passed` or `day_passed`, made the
    /// first time a script reaches for it.
    fn clockSignal(self: *Scripts, handle: clocks_mod.ClockHandle, which: usize) flux.Vm.Error!flux.Value {
        const got = try self.clock_signals.getOrPut(self.app.gpa, clockKey(handle));
        if (!got.found_existing) got.value_ptr.* = @splat(.null);
        if (got.value_ptr[which].tag != .signal) {
            const signal = try self.vm.newSignal(ClockRef.signal_names[which], 1);
            try self.vm.hold(signal);
            // Asked again: making it may have grown the table.
            self.clock_signals.getPtr(clockKey(handle)).?[which] = signal;
            return signal;
        }
        return got.value_ptr[which];
    }

    /// Each clock's signals for what turned over on it in this frame's step,
    /// with how many.
    fn emitClocks(self: *Scripts) void {
        if (self.clock_signals.count() == 0) return;
        const Due = struct { signal: flux.Value, count: u64 };
        var due: std.ArrayList(Due) = .empty;
        defer due.deinit(self.app.gpa);
        var it = self.clock_signals.iterator();
        while (it.next()) |entry| {
            const handle: clocks_mod.ClockHandle = @bitCast(entry.key_ptr.*);
            const clock = self.app.clocks.get(handle) orelse continue;
            const counts = [3]u64{ clock.passed.minutes, clock.passed.hours, clock.passed.days };
            for (entry.value_ptr.*, counts) |signal, count| {
                if (signal.tag != .signal or count == 0) continue;
                due.append(self.app.gpa, .{ .signal = signal, .count = count }) catch return self.outOfMemory(null);
            }
        }
        for (due.items) |each| {
            const count = flux.bind.toValue(self.vm, @as(i64, @intCast(@min(each.count, std.math.maxInt(i64))))) catch return self.outOfMemory(null);
            self.vm.setBudget(self.options.budget);
            self.vm.emitSignalValue(each.signal, &.{count}) catch |err| switch (err) {
                error.OutOfMemory => self.outOfMemory(null),
                error.Panic => self.sayPanic(null, "a clock's signal in"),
            };
        }
    }

    fn bridgeOf(self: *Scripts, source: Entity, component: []const u8, name: []const u8, arity: usize) flux.Vm.Error!flux.Value {
        const gpa = self.app.gpa;
        const key = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ component, name });
        for (self.bridges.items) |held| {
            if (held.source.eql(source) and std.mem.eql(u8, held.key, key)) {
                gpa.free(key);
                return held.signal;
            }
        }
        errdefer gpa.free(key);
        const signal = try self.vm.newSignal(name, @intCast(@min(arity, max_args)));
        try self.vm.hold(signal);
        errdefer self.vm.release(signal);
        self.app.signals.connect(source, .{ .component = component, .name = name }, .script, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyConnected => {},
            else => return self.vm.fail("{s} of this entity could not be heard: {t}", .{ key, err }),
        };
        try self.bridges.append(gpa, .{ .source = source, .key = key, .signal = signal });
        return signal;
    }

    fn bridge(self: *Scripts, source: Entity, component: []const u8, name: []const u8, args: []const reflect.Value) anyerror!void {
        if (!self.options.run) return;
        const found = for (self.bridges.items) |held| {
            if (held.source.eql(source) and matchesKey(held.key, component, name)) break held.signal;
        } else return;
        if (args.len >= max_args) return error.WrongArguments;
        const vm = self.vm;
        var values: [max_args]flux.Value = undefined;
        var made: usize = 0;
        // Each held until the emit: making the next can collect.
        defer for (values[0..made]) |v| vm.release(v);
        for (args, values[0..args.len]) |arg, *into| {
            into.* = try vm.valueOf(arg);
            try vm.hold(into.*);
            made += 1;
        }
        vm.setBudget(self.options.budget);
        vm.emitSignalValue(found, values[0..args.len]) catch |err| {
            self.failures += 1;
            switch (err) {
                error.Panic => self.writePanic(source, "a signal the scripts heard of"),
                error.OutOfMemory => {},
            }
            return err;
        };
    }

    /// The bridges of what has died, let go of: the table let go of their
    /// connections.
    fn forgetDeadBridges(self: *Scripts) void {
        var at: usize = 0;
        while (at < self.bridges.items.len) {
            const held = self.bridges.items[at];
            if (self.app.world.isAlive(held.source)) {
                at += 1;
                continue;
            }
            self.vm.release(held.signal);
            self.app.gpa.free(held.key);
            _ = self.bridges.swapRemove(at);
        }
    }

    fn callDeferred(self: *Scripts, callable: flux.Value) anyerror!void {
        switch (callable.tag) {
            .function, .method, .native => {},
            else => return error.NotCallable,
        }
        try self.vm.hold(callable);
        errdefer self.vm.release(callable);
        try self.deferred.append(self.app.gpa, callable);
    }

    /// What `app.callDeferred` was given this frame, first given first.
    /// What they defer waits for the next frame.
    fn callTheDeferred(self: *Scripts) void {
        if (self.deferred.items.len == 0) return;
        var taken = self.deferred;
        self.deferred = .empty;
        defer taken.deinit(self.app.gpa);
        for (taken.items) |callable| {
            self.vm.setBudget(self.options.budget);
            _ = self.vm.call(callable, &.{}) catch |err| {
                self.failures += 1;
                switch (err) {
                    error.Panic => self.writePanic(null, "a call deferred by"),
                    error.OutOfMemory => {},
                }
            };
            self.vm.release(callable);
        }
    }

    fn nextFrame(self: *Scripts) flux.Value {
        self.frame_given = true;
        return self.frame;
    }

    /// Connections kept unknown because the script's signal was not there
    /// when they were made - a scene read while its script did not compile,
    /// a script given to its entity later - heard from now on, where they
    /// are in the order.
    fn knowConnections(self: *Scripts, entity: Entity) Allocator.Error!void {
        var found: [64]signals.Info = undefined;
        for (signalsOf(self, entity, &found)) |info| {
            const key: signals.Key = .{ .component = component_name, .name = info.name };
            var buffer: [128]u8 = undefined;
            if (std.fmt.bufPrint(&buffer, component_name ++ ".{s}", .{info.name})) |dotted| {
                try self.app.signals.know(entity, dotted, key);
            } else |_| {}
            // By its bare name, unless a component of the entity says it too.
            const resolved = self.app.signalNamed(entity, info.name) catch continue;
            if (std.mem.eql(u8, resolved.component, component_name)) try self.app.signals.know(entity, info.name, key);
        }
    }

    /// One call into a script, under the budget. The tasks it starts are the
    /// entity's.
    fn call(self: *Scripts, entity: Entity, method: flux.Value, args: []const flux.Value, which: Lifecycle) void {
        self.vm.setBudget(self.options.budget);
        const owner = self.vm.setTaskOwner(entity.toInt());
        defer _ = self.vm.setTaskOwner(owner);
        _ = self.vm.call(method, args) catch |err| {
            self.failures += 1;
            // Said once for each of an instance's methods. `ready` and
            // `exit` come once anyway.
            const loud = if (self.instances.getPtr(entity)) |inst| blk: {
                if (inst.said.contains(which)) break :blk false;
                inst.said.insert(which);
                break :blk true;
            } else true;
            switch (err) {
                error.Panic => if (loud) self.writePanic(entity, "the script of") else self.vm.clearPanic(),
                error.OutOfMemory => if (loud) log.warn("the script of {f} ran out of memory in {t}", .{ entity, which }),
            }
        };
    }

    fn outOfMemory(self: *Scripts, entity: ?Entity) void {
        self.failures += 1;
        if (entity) |e| {
            log.warn("the scripts ran out of memory making the script of {f}", .{e});
        } else log.warn("the scripts ran out of memory", .{});
    }

    /// A file dialog a script asked for, and the signal its answer is said
    /// on.
    const Waiting = struct { id: dialog.Id, signal: flux.Value };

    /// The dialogs that came back this frame, their paths said.
    fn answerDialogs(self: *Scripts) void {
        var at: usize = 0;
        while (at < self.dialogs.items.len) {
            const waiting = self.dialogs.items[at];
            const paths = self.app.input.dialogAnswer(waiting.id) orelse {
                at += 1;
                continue;
            };
            _ = self.dialogs.orderedRemove(at);
            defer self.vm.release(waiting.signal);
            self.tellPaths(waiting.signal, paths, "a script given the files a dialog chose");
        }
    }

    /// The files let go over the window this frame, said.
    fn hearDrops(self: *Scripts) void {
        if (self.drop_signal.tag != .signal) return;
        for (self.app.input.dropped()) |drop| self.tellPaths(self.drop_signal, drop.paths, "a script given the files dropped");
    }

    /// `paths` said on `signal` as a list, once they are files the scripts
    /// may read.
    fn tellPaths(self: *Scripts, signal: flux.Value, paths: []const []const u8, comptime who: []const u8) void {
        const gpa = self.app.gpa;
        for (paths) |path| {
            if (self.granted.contains(path)) continue;
            const kept = gpa.dupe(u8, path) catch return self.outOfMemory(null);
            self.granted.put(gpa, kept, {}) catch {
                gpa.free(kept);
                return self.outOfMemory(null);
            };
        }
        const list = flux.bind.toValue(self.vm, paths) catch return self.outOfMemory(null);
        self.vm.pushRoot(list) catch return self.outOfMemory(null);
        defer self.vm.popRoot();
        self.vm.setBudget(self.options.budget);
        self.vm.emitSignalValue(signal, &.{list}) catch |err| switch (err) {
            error.OutOfMemory => self.outOfMemory(null),
            error.Panic => self.sayPanic(null, who),
        };
    }

    /// A panic counted, said and cleared.
    fn sayPanic(self: *Scripts, entity: ?Entity, comptime where: []const u8) void {
        self.failures += 1;
        self.writePanic(entity, where);
    }

    fn writePanic(self: *Scripts, entity: ?Entity, comptime where: []const u8) void {
        var buffer: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        self.vm.writePanic(&writer, .{}) catch {};
        self.vm.clearPanic();
        if (entity) |e| {
            log.warn(where ++ " {f} stopped:\n{s}", .{ e, writer.buffered() });
        } else log.warn(where ++ " stopped:\n{s}", .{writer.buffered()});
    }

    fn sayDiagnostics(self: *Scripts, source: []const u8) void {
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        self.vm.writeDiagnostics(&writer, .{}) catch {};
        log.warn("{s} does not compile:\n{s}", .{ source, writer.buffered() });
    }
};

/// Where a component a script holds is now.
fn findComponent(context: ?*anyopaque, key: u64, t: *const reflect.Type) ?reflect.Value {
    const app: *App = @ptrCast(@alignCast(context.?));
    return app.componentOfType(.fromInt(key), t);
}

/// A script's emit, heard by the engine's signal table as well: the signal
/// `Script.<name>` of the entity the instance is on, its arguments copied
/// as the table copies anyone's. An instance on no entity - one a script
/// made for itself, or one let go of - is the script's business alone.
fn heardEmit(vm: *flux.Vm, instance: flux.Value, signal: []const u8, args: []const flux.Value) flux.Vm.Error!void {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const entity = self.entity_of.get(instance.obj()) orelse return;
    if (args.len > max_args) return vm.fail("the engine hears signals of up to {d} arguments, and {s} gave {d}", .{ max_args, signal, args.len });
    var held: [max_args]Carried = undefined;
    var values: [max_args]reflect.Value = undefined;
    for (args, held[0..args.len], values[0..args.len], 1..) |arg, *place, *into, n| {
        into.* = try carried(self, vm, arg, place) orelse
            return vm.fail("argument {d} of {s} is {s}, which the engine's signals cannot carry", .{ n, signal, typeName(arg) });
    }
    self.app.signals.emit(entity, component_name, signal, values[0..args.len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.fail("{s} could not be sent: {t}", .{ signal, err }),
    };
}

/// Where an argument a script emits is kept while the table copies it.
const Carried = union {
    int: i64,
    float: f64,
    boolean: bool,
    text: []const u8,
    vec2: math.Vec2,
    vec3: math.Vec3,
    color: Color,
    entity: Entity,
    nothing: ?Entity,
};

/// A script's value as the engine's: numbers, text and vectors as they
/// are, a scripted entity's instance or its `self.entity` as its `Entity`,
/// and a handle as what it stands for now. Null for what has no engine
/// value: a list, a function.
fn carried(self: *Scripts, vm: *flux.Vm, arg: flux.Value, place: *Carried) flux.Vm.Error!?reflect.Value {
    switch (arg.tag) {
        .int => {
            place.* = .{ .int = arg.asInt() };
            return .of(&place.int);
        },
        .float => {
            place.* = .{ .float = arg.asFloat() };
            return .of(&place.float);
        },
        .bool => {
            place.* = .{ .boolean = arg.asBool() };
            return .of(&place.boolean);
        },
        .string => {
            place.* = .{ .text = arg.as(flux.object.String).bytes() };
            return .of(&place.text);
        },
        .vec2 => {
            const xy = arg.asVec2();
            place.* = .{ .vec2 = .{ .x = xy[0], .y = xy[1] } };
            return .of(&place.vec2);
        },
        .vec3 => {
            const xyz = arg.asVec3();
            place.* = .{ .vec3 = .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] } };
            return .of(&place.vec3);
        },
        .color => {
            const rgba = arg.as(flux.object.Color).rgba;
            place.* = .{ .color = .rgba(rgba[0], rgba[1], rgba[2], rgba[3]) };
            return .of(&place.color);
        },
        .null => {
            place.* = .{ .nothing = null };
            return .of(&place.nothing);
        },
        .instance => {
            const entity = self.entity_of.get(arg.obj()) orelse return null;
            place.* = .{ .entity = entity };
            return .of(&place.entity);
        },
        .handle => {
            const now = vm.reflectOf(arg) orelse return vm.fail("an argument is gone: what it stood for is not there any more", .{});
            if (now.asConst(EntityRef)) |ref| {
                place.* = .{ .entity = ref.entity };
                return .of(&place.entity);
            }
            return now;
        },
        else => return null,
    }
}

fn typeName(arg: flux.Value) []const u8 {
    return switch (arg.tag) {
        .int, .float => "a number",
        .string => "a string",
        .list => "a list",
        .map => "a map",
        .function, .native, .method => "a function",
        .task => "a task",
        .signal => "a signal",
        .class => "a struct",
        else => "a value",
    };
}

/// A task nothing waits for stopped: said and counted.
fn sayTaskPanic(vm: *flux.Vm, panic: *const flux.Vm.Panic) void {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    self.failures += 1;
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    flux.renderPanic(&writer, vm, panic, .{}) catch {};
    log.warn("a script's task stopped:\n{s}", .{writer.buffered()});
}

/// The handle an entity is to the scripts: an `EntityRef`, made the first
/// time and the same one after, until the end of the frame the entity dies
/// in. The collector frees it once no script can reach it either.
fn entityHandle(scripts: *Scripts, entity: Entity) flux.Vm.Error!flux.Value {
    if (scripts.handles.get(entity)) |known| return known;
    const vm = scripts.vm;
    try scripts.handles.ensureUnusedCapacity(scripts.app.gpa, 1);
    const ref = try vm.gpa.create(EntityRef);
    ref.* = .{ .scripts = scripts, .entity = entity };
    const handle = vm.adoptHandle(ref) catch |err| {
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.hold(handle);
    scripts.handles.putAssumeCapacityNoClobber(entity, handle);
    return handle;
}

/// Every type of the engine's that a script sees as something else.
const host_types = [_]flux.HostType{ entity_type, tile_value_type, animated_value_type, color_type } ++ asset_types;

/// A file a component holds - a texture, a scene - as its path, and given
/// as one: `sprite.texture = "res://art/hero.png"`, `app.instantiate("res://
/// enemy.json", self.entity)`. None is null.
const asset_types = blk: {
    var out: [AssetKind.handled.len]flux.HostType = undefined;
    for (AssetKind.handled, 0..) |kind, i| out[i] = assetType(kind);
    break :blk out;
};

fn assetType(comptime kind: AssetKind) flux.HostType {
    const H = kind.Handle();
    const Shim = struct {
        fn toScript(vm: *flux.Vm, value: reflect.Value) flux.Vm.Error!flux.Value {
            const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
            const handle = value.get(H).?;
            if (std.meta.eql(handle, H.none)) return .null;
            // Sprite frames are a value with calls of their own.
            if (comptime kind == .frames) return framesHandle(self, handle);
            const path = self.app.assetSource(handle) orelse return .null;
            return vm.string(path);
        }

        fn fromScript(vm: *flux.Vm, into: reflect.Value, value: flux.Value) flux.Vm.Error!void {
            const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
            const handle: H = switch (value.tag) {
                .null => H.none,
                .string => blk2: {
                    const path = value.as(flux.object.String).bytes();
                    break :blk2 self.app.loadAsset(H, path) catch |err| return vm.fail("the " ++ comptime kind.label() ++ " {s} did not load: {t}", .{ path, err });
                },
                .handle => blk2: {
                    if (comptime kind == .frames) if (vm.reflectOf(value)) |now| if (now.asConst(FramesRef)) |ref| break :blk2 ref.handle;
                    return vm.fail("a " ++ comptime kind.label() ++ " is given by its path, as \"res://...\", not a {s}", .{value.as(flux.object.Handle).value.type.name.slice()});
                },
                else => return vm.fail("a " ++ comptime kind.label() ++ " is given by its path, as \"res://...\", not {s}", .{typeName(value)}),
            };
            into.set(H, handle) catch return vm.fail("this " ++ comptime kind.label() ++ " can only be read", .{});
        }
    };
    return .{
        .type = reflect.typeOf(H),
        // Sprite frames are a value of their own to a script; the other
        // files are their paths.
        .script = if (kind == .frames) reflect.typeOf(FramesRef) else null,
        .given = if (kind == .frames) null else .string,
        .nullable = true,
        .to_script = Shim.toScript,
        .from_script = Shim.fromScript,
    };
}

/// The value a set of sprite frames is to the scripts: made the first time,
/// the same one after.
fn framesHandle(scripts: *Scripts, handle: sprite_frames.SpriteFramesHandle) flux.Vm.Error!flux.Value {
    if (scripts.frames_handles.get(handle)) |known| return known;
    const vm = scripts.vm;
    try scripts.frames_handles.ensureUnusedCapacity(scripts.app.gpa, 1);
    const ref = try vm.gpa.create(FramesRef);
    ref.* = .{ .scripts = scripts, .handle = handle };
    const made = vm.adoptHandle(ref) catch |err| {
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.hold(made);
    scripts.frames_handles.putAssumeCapacityNoClobber(handle, made);
    return made;
}

/// A member of an engine's value that is none of its fields: a signal one
/// of the entity's components declares - `timer.timeout` - as the scripts'
/// own, the words a component keeps beside it, a material's numbers, a
/// clock's signals. `install` declares them for the compiler.
fn hostMember(vm: *flux.Vm, handle: flux.Value, name: []const u8) flux.Vm.Error!?flux.Value {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const h = handle.as(flux.object.Handle);
    if (h.live != null and h.live.? == &self.resolver) {
        const source = Entity.fromInt(h.key);
        for (self.app.scene_components.entries.items) |*entry| {
            if (!entry.type.same(h.value.type)) continue;
            // The words a component keeps beside it: `label.text`.
            if (App.textAttributeOf(entry.type, name) != null) return try vm.string(self.app.textNamed(source, entry.name, name));
            // A material's numbers: `material.strength`.
            if (entry.type.same(reflect.typeOf(shaders_mod.Material))) if (try shaderParamOf(self, source, name)) |value| return value;
            for (entry.signals) |decl| {
                if (std.mem.eql(u8, decl.name, name)) return try self.bridgeOf(source, entry.name, decl.name, decl.args.fields().len);
            }
            return null;
        }
        return null;
    }
    const now = vm.reflectOf(handle) orelse return null;
    if (now.as(FramesRef)) |frames| {
        if (std.mem.eql(u8, name, "resource_path")) return try vm.string(frames.resourcePath());
        return null;
    }
    if (now.as(ClockRef)) |clock| {
        const which = for (ClockRef.signal_names, 0..) |signal_name, i| {
            if (std.mem.eql(u8, signal_name, name)) break i;
        } else return null;
        return try self.clockSignal(clock.handle, which);
    }
    return null;
}

/// A component's words written from a script, `label.text = "Paused"`:
/// kept beside it, as its `attr.Text` says. See `texts.zig`.
fn hostSetMember(vm: *flux.Vm, handle: flux.Value, name: []const u8, value: flux.Value) flux.Vm.Error!bool {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const h = handle.as(flux.object.Handle);
    if (h.live == null or h.live.? != &self.resolver) return false;
    const source = Entity.fromInt(h.key);
    for (self.app.scene_components.entries.items) |*entry| {
        if (!entry.type.same(h.value.type)) continue;
        if (entry.type.same(reflect.typeOf(shaders_mod.Material))) return setShaderParamOf(self, source, name, value);
        if (App.textAttributeOf(entry.type, name) == null) return false;
        if (value.tag != .string) return vm.fail("{s}.{s} is text, not {s}", .{ entry.name, name, typeName(value) });
        self.app.setTextNamed(source, entry.name, name, value.as(flux.object.String).bytes()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return vm.fail("{s}.{s} could not be written: {t}", .{ entry.name, name, err }),
        };
        return true;
    }
    return false;
}

/// What a material gives its shader's field `name`, as a script sees it: a
/// number, a `vec2`, a `vec3`, or a `color` for a `vec4`. Null for a field
/// its shader has not, and for a matrix.
fn shaderParamOf(self: *Scripts, entity: Entity, name: []const u8) flux.Vm.Error!?flux.Value {
    const field = self.app.shaderParamField(entity, name) orelse return null;
    var buffer: [16]f32 = undefined;
    const n = self.app.shaderParamOrDefault(entity, name, &buffer) orelse return null;
    return switch (field.ty) {
        .float => .float(n[0]),
        .int => .int(@intFromFloat(@round(n[0]))),
        .vec2 => .vec2(n[0], n[1]),
        .vec3 => .vec3(n[0], n[1], n[2]),
        .vec4 => try self.vm.newColor(.{ n[0], n[1], n[2], n[3] }),
        else => null,
    };
}

/// A material's number written from a script: `material.strength = 0.6`,
/// `material.glow = Color(1, 0.8, 0.3)`.
fn setShaderParamOf(self: *Scripts, entity: Entity, name: []const u8, value: flux.Value) flux.Vm.Error!bool {
    const vm = self.vm;
    const held = self.app.world.get(entity, shaders_mod.Material) orelse return false;
    // A shader that compiled says what it has; one that did not is given
    // what it is given.
    if (self.app.shaders.compiledOf(held.shader) != null and self.app.shaderParamField(entity, name) == null) return false;
    var numbers: [4]f32 = undefined;
    const given: []const f32 = switch (value.tag) {
        .int => blk: {
            numbers[0] = @floatFromInt(value.asInt());
            break :blk numbers[0..1];
        },
        .float => blk: {
            numbers[0] = @floatCast(value.asFloat());
            break :blk numbers[0..1];
        },
        .vec2 => blk: {
            numbers[0..2].* = value.asVec2();
            break :blk numbers[0..2];
        },
        .vec3 => blk: {
            numbers[0..3].* = value.asVec3();
            break :blk numbers[0..3];
        },
        .color => blk: {
            numbers = value.as(flux.object.Color).rgba;
            break :blk numbers[0..4];
        },
        else => return vm.fail("Material.{s} is a number, a vec2, a vec3 or a color, not {s}", .{ name, typeName(value) }),
    };
    self.app.setShaderParam(entity, name, given) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.fail("Material.{s} could not be written: {t}", .{ name, err }),
    };
    return true;
}

/// How a script sees an `Entity`: see "An entity is one handle" above.
const entity_type: flux.HostType = .{
    .type = reflect.typeOf(Entity),
    .script = reflect.typeOf(EntityRef),
    .nullable = true,
    .to_script = entityToScript,
    .from_script = entityFromScript,
};

/// How a script sees what a tile says under a data layer: the number, or the
/// truth, itself - `app.tileDataAt(map, at, "damage") > 0` - rather than a
/// box with one of three fields in it.
const tile_value_type: flux.HostType = .{
    .type = reflect.typeOf(tileset.Value),
    .to_script = tileValueToScript,
    .from_script = tileValueFromScript,
};

fn tileValueToScript(_: *flux.Vm, value: reflect.Value) flux.Vm.Error!flux.Value {
    return switch (value.asConst(tileset.Value).?.*) {
        .int => |n| .int(n),
        .float => |f| .float(f),
        .bool => |b| .boolean(b),
    };
}

fn tileValueFromScript(vm: *flux.Vm, into: reflect.Value, value: flux.Value) flux.Vm.Error!void {
    const given: tileset.Value = switch (value.tag) {
        .int => .{ .int = value.asInt() },
        .float => .{ .float = value.asFloat() },
        .bool => .{ .bool = value.asBool() },
        else => return vm.fail("a tile's data is a number, true or false, not {s}", .{typeName(value)}),
    };
    const place = into.as(tileset.Value) orelse return vm.fail("this tile's data can only be read", .{});
    place.* = given;
}

/// The engine's colours are the language's own: `look.modulate = color(1, 0.5,
/// 0.5)`, or `"#ff8080"`, and read back as colours.
const color_type: flux.HostType = .{
    .type = reflect.typeOf(Color),
    .given = .color,
    .to_script = colorToScript,
    .from_script = colorFromScript,
};

fn colorToScript(vm: *flux.Vm, value: reflect.Value) flux.Vm.Error!flux.Value {
    const held = value.asConst(Color).?.*;
    return vm.newColor(.{ held.r, held.g, held.b, held.a });
}

fn colorFromScript(vm: *flux.Vm, into: reflect.Value, value: flux.Value) flux.Vm.Error!void {
    const given: Color = switch (value.tag) {
        .color => blk: {
            const rgba = value.as(flux.object.Color).rgba;
            break :blk .rgba(rgba[0], rgba[1], rgba[2], rgba[3]);
        },
        .string => Color.parse(value.as(flux.object.String).bytes()) orelse
            return vm.fail("\"{s}\" is not a colour: \"#rrggbb\" or \"#rrggbbaa\"", .{value.as(flux.object.String).bytes()}),
        else => return vm.fail("a colour is wanted here, as color(r, g, b, a) or \"#rrggbb\", not {s}", .{typeName(value)}),
    };
    into.set(Color, given) catch return vm.fail("this colour can only be read", .{});
}

/// What a tween moves a property to, as a script gives it: a number, a
/// `vec2`, a `color`, true or false - `app.tweenProperty(t, e, "Transform2D.x",
/// 300.0, 1.0)`.
const animated_value_type: flux.HostType = .{
    .type = reflect.typeOf(property.Value),
    .to_script = animatedToScript,
    .from_script = animatedFromScript,
};

fn animatedToScript(vm: *flux.Vm, value: reflect.Value) flux.Vm.Error!flux.Value {
    return switch (value.asConst(property.Value).?.*) {
        .number => |n| .float(n),
        .vec2 => |xy| .vec2(xy[0], xy[1]),
        .color => |rgba| try vm.newColor(rgba),
        .flag => |on| .boolean(on),
        .name => |*held| try vm.string(std.mem.sliceTo(held, 0)),
    };
}

fn animatedFromScript(vm: *flux.Vm, into: reflect.Value, value: flux.Value) flux.Vm.Error!void {
    const given: property.Value = switch (value.tag) {
        .int => .{ .number = @floatFromInt(value.asInt()) },
        .float => .{ .number = value.asFloat() },
        .bool => .{ .flag = value.asBool() },
        .vec2 => .{ .vec2 = value.asVec2() },
        .color => .{ .color = value.as(flux.object.Color).rgba },
        .string => .nameOf(value.as(flux.object.String).bytes()),
        else => return vm.fail("a property moves to a number, a vec2, a color, true or false, or a name, not {s}", .{typeName(value)}),
    };
    const place = into.as(property.Value) orelse return vm.fail("this value can only be read", .{});
    place.* = given;
}

fn entityToScript(vm: *flux.Vm, value: reflect.Value) flux.Vm.Error!flux.Value {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const entity = value.get(Entity).?;
    if (entity.isNone()) return .null;
    return entityHandle(self, entity);
}

fn entityFromScript(vm: *flux.Vm, into: reflect.Value, value: flux.Value) flux.Vm.Error!void {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const entity: Entity = switch (value.tag) {
        .null => .none,
        .instance => self.entity_of.get(value.obj()) orelse return notAnEntity(vm, value),
        .handle => blk: {
            const now = vm.reflectOf(value) orelse return notAnEntity(vm, value);
            const ref = now.asConst(EntityRef) orelse return notAnEntity(vm, value);
            break :blk ref.entity;
        },
        else => return notAnEntity(vm, value),
    };
    into.set(Entity, entity) catch return vm.fail("this entity can only be read", .{});
}

fn notAnEntity(vm: *flux.Vm, value: flux.Value) flux.Vm.Error {
    return switch (value.tag) {
        .handle => vm.fail("an entity is wanted here, not a {s}", .{value.as(flux.object.Handle).value.type.name.slice()}),
        .instance => vm.fail("an entity is wanted here, not a {s} on no entity", .{value.as(flux.object.Instance).class.name.bytes()}),
        else => vm.fail("an entity is wanted here, not {s}", .{typeName(value)}),
    };
}

/// The values behind `app`, `files`, `time` and `images` where the scripts
/// run.
pub const Given = struct { app: flux.Value, files: flux.Value, time: flux.Value, images: flux.Value };

/// What every VM that compiles the game's scripts is given - the game's own,
/// with the values `given` holds, and each of an editor's analyses, with
/// their types only - so the two agree on what a script may name, what it
/// can call, and what is said of it: the engine's types and enums by name,
/// the calls an entity has of `app`'s, what its components have beside
/// their fields, the methods the engine calls and the annotations it reads.
pub fn install(vm: *flux.Vm, app: *App, given: ?Given) Allocator.Error!void {
    vm.options.host_types = &host_types;
    vm.options.host_member = hostMember;
    vm.options.host_set_member = hostSetMember;
    vm.options.docs = member_docs;
    try vm.declareHostMemberOf("entity", reflect.typeOf(EntityRef), entity_doc);
    if (given) |g| {
        try vm.defineGlobal("app", g.app, app_doc);
        try vm.defineGlobal("files", g.files, files_doc);
        try vm.defineGlobal("time", g.time, time_doc);
        try vm.defineGlobal("images", g.images, images_doc);
    } else {
        try vm.declareGlobal("app", reflect.typeOf(App), app_doc);
        try vm.declareGlobal("files", reflect.typeOf(FileAccess), files_doc);
        try vm.declareGlobal("time", reflect.typeOf(TimeAccess), time_doc);
        try vm.declareGlobal("images", reflect.typeOf(ImagesAccess), images_doc);
    }
    try vm.extend(reflect.typeOf(EntityRef), reflect.typeOf(App), if (given) |g| g.app else .null);
    for (named_types) |t| try vm.declareType(t);
    for (app.scene_components.entries.items) |*entry| {
        try vm.declareType(entry.type);
        for (entry.signals) |decl| try vm.declareMember(.{ .of = entry.type, .name = decl.name, .type = .signal });
        for (entry.type.attributes.slice()) |a| if (a.as(attr.Text)) |text| {
            try vm.declareMember(.{ .of = entry.type, .name = text.name, .type = .string, .writable = true });
        };
    }
    // A material's numbers are its shader's to name.
    try vm.declareOpen(reflect.typeOf(shaders_mod.Material));
    for (ClockRef.signal_names) |name| try vm.declareMember(.{ .of = reflect.typeOf(ClockRef), .name = name, .type = .signal });
    try vm.declareMember(.{ .of = reflect.typeOf(FramesRef), .name = "resource_path", .type = .string, .doc = "The file the frames were read from, or \"\" for ones made in memory." });
    for (std.enums.values(Lifecycle)) |which| try vm.declareHook(which.hook());
    for (annotations) |a| try vm.declareAnnotation(a);
}

/// The engine's types a script names besides its components, and with them
/// the enums and unions they take and give - `Key`, `Fullscreen` - and what
/// those unions' arms hold - `KeyEvent`: see `flux.Vm.declareType`.
const named_types = [_]*const reflect.Type{
    reflect.typeOf(App),
    reflect.typeOf(EntityRef),
    reflect.typeOf(FileAccess),
    reflect.typeOf(ConfigRef),
    reflect.typeOf(ImagesAccess),
    reflect.typeOf(ImageRef),
    reflect.typeOf(TimeAccess),
    reflect.typeOf(ClockRef),
    reflect.typeOf(FramesRef),
    reflect.typeOf(datetime.DateTime),
    reflect.typeOf(datetime.Duration),
    reflect.typeOf(InputEvent),
};

/// What the engine reads of an exported field besides `@export`: see
/// `exports.zig` and the editor's Inspector.
const annotations = [_]flux.Annotation{
    .{ .name = "range", .sig = "@range(min, max, step)", .doc = "The numbers an exported field may be, for the Inspector's slider: `@range(0, 100)`, the step left out for any." },
    .{ .name = "multiline", .sig = "@multiline", .doc = "An exported string written over several lines." },
    .{ .name = "group", .sig = "@group(name: string)", .doc = "Where an exported field is listed in the Inspector, under a heading of its own." },
    .{ .name = "file", .sig = "@file(ending: string, ...)", .doc = "An exported string that names a file of the project's, by its endings: `@file(\"png\", \"jpg\")`." },
    .{ .name = "entity", .sig = "@entity", .doc = "An exported field that names an entity of the scene, chosen from its tree." },
};

/// What the engine's doc comments say of its types' members: see
/// `tools/member_docs.zig`.
const member_docs = @import("member_docs").list(flux.Doc);

const entity_doc = "The entity this script is on: `get(Sprite)`, `find(Sprite)`, `has`, `add`, `remove`, `alive()`, `uuid()`, and every call of `app`'s given an entity first - `name()`, `parent()`, `globalPosition()`.";
const app_doc = "The engine: the calls `App.reflect_methods` lists.";
const files_doc = "The game's files to read (`res://`) and the player's to read and write (`user://`): `readText(path)`, `writeText(path, text)`, `appendText`, `exists`, `isDir`, `list`, `copy`, `move`, `remove`, `size`, `modifiedTime`, `sha256`; kept sealed with `writeSecret(path, text, password)` or small with `writeCompressed`; `config(path)` for settings and `writeData(value, path)` for a struct; paths with `join`, `dirName`, `fileName`, `stem`, `extension`, `validName`; the player's own with `choose(title, extensions)` and `dropped()`.";
const time_doc = "Dates, times and spans, written in the game's culture: `now()`, `date(year, month, day)`, `parse(text)`, `minutes(n)`, `locale()`, `setLocale(tag)`, and `clock(start, rate)` for a clock of the game's own.";
const images_doc = "Pictures in memory: `new(width, height, color)`, `read(path)`, `capture()` of the frame, `fromTexture(texture)`; an image's `getPixel`, `setPixel`, `fill`, `fillRect`, `region`, `blit`, `blend`, `resize`, `flipX`, `flipY`, `savePng`, `saveJpg`; `toTexture(image)` draws it.";

/// For `App.scriptSetup`. An analysis only compiles, so `app` is a name
/// with nothing behind it there. Inside the quotes of a call that names an
/// action, the project's actions are offered.
pub fn serviceOptions(app: *App) flux.service.Options {
    return .{
        .setup = .{ .context = app, .run = installForAnalysis },
        .loader = .{ .context = app, .load = loadImport },
        .io = app.io,
        .strings = .{ .context = app, .values = stringValues },
    };
}

/// A script's `@import("save.flux")`: the file beside the one importing it,
/// or at a `res://` path, read from the project. The same file is the same
/// module name however it is spelt - and however the importing file is: an
/// editor outside the engine names it by where it is on the disk.
fn loadImport(context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!flux.Vm.Loader.Loaded {
    const app: *App = @ptrCast(@alignCast(context.?));
    const io = app.io orelse return error.NoIo;
    const importing = try app.project.canonical(gpa, from);
    defer gpa.free(importing);
    const wanted = if (std.mem.indexOf(u8, path, "://") != null)
        try gpa.dupe(u8, path)
    else if (std.mem.lastIndexOfScalar(u8, importing, '/')) |cut|
        // "res://Scripts/menu.flux" and "save.flux" are "res://Scripts/save.flux".
        try std.mem.concat(gpa, u8, &.{ importing[0 .. cut + 1], path })
    else
        try gpa.dupe(u8, path);
    defer gpa.free(wanted);
    const name = try app.project.canonical(gpa, wanted);
    errdefer gpa.free(name);
    const file = try app.project.osPath(gpa, name);
    defer gpa.free(file);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(16 << 20));
    return .{ .name = name, .source = source };
}

/// `app`'s calls whose strings name an action, and whether every one of
/// their arguments does or only the first.
const action_calls = [_]struct { []const u8, bool }{
    .{ "actionDown", false },
    .{ "actionJustPressed", false },
    .{ "actionJustReleased", false },
    .{ "actionStrength", false },
    .{ "actionAxis", true },
    .{ "actionVector", true },
    .{ "pressAction", false },
    .{ "releaseAction", false },
    .{ "describeAction", false },
};

/// What the string a call of `app`'s takes may say: an action's name, for
/// the calls that take one - each with the inputs that set it off.
fn stringValues(context: ?*anyopaque, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    const app: *App = @ptrCast(@alignCast(context.?));
    const receiver = argument.receiver orelse return &.{};
    if (!std.mem.eql(u8, receiver, "app")) return animationNames(app, arena, argument);
    const every = for (action_calls) |each| {
        if (std.mem.eql(u8, each[0], argument.callee)) break each[1];
    } else return &.{};
    if (!every and argument.arg != 0) return &.{};

    // The project file's actions, over the built-in ones: an editor runs
    // with the built-in ones alone, and a game with both.
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    const project: []const actions.Action = if (app.project.settings) |held| held.input.actions else &.{};
    for (actions.builtin) |builtin| {
        const chosen = for (project) |action| {
            if (std.mem.eql(u8, action.name, builtin.name)) break action;
        } else builtin;
        try list.append(arena, try actionValue(arena, chosen, "A built-in action, for moving round the interface."));
    }
    for (project) |action| {
        if (actions.builtinNamed(action.name) != null) continue;
        try list.append(arena, try actionValue(arena, action, null));
    }
    for (app.input.actions.list()) |*entry| {
        const known = for (list.items) |value| {
            if (std.mem.eql(u8, value.label, entry.name)) break true;
        } else false;
        if (!known) try list.append(arena, try actionValue(arena, entry.action(), null));
    }
    return list.items;
}

/// The first string of a sprite's `play` and `playBackwards` and a player's
/// `play` and `queue`: the name of an animation of the sprite frames and
/// the animation libraries read, each with the file it is in. What the call
/// is on is not known to a completion, so both kinds are offered.
fn animationNames(app: *App, arena: Allocator, argument: flux.service.StringArgument) Allocator.Error![]const flux.service.StringValue {
    if (argument.arg != 0) return &.{};
    const callee = argument.callee;
    const of_sprites = std.mem.eql(u8, callee, "play") or std.mem.eql(u8, callee, "playBackwards");
    const of_players = std.mem.eql(u8, callee, "play") or std.mem.eql(u8, callee, "queue");
    var list: std.ArrayList(flux.service.StringValue) = .empty;
    if (of_sprites) {
        var it = app.sprite_frames.table.iterator();
        while (it.next()) |entry| for (entry.value.animations.items) |clip| {
            try list.append(arena, .{ .label = clip.name, .detail = entry.value.source });
        };
    }
    if (of_players) {
        var it = app.animation_libraries.table.iterator();
        while (it.next()) |entry| for (entry.value.animations.items) |held| {
            try list.append(arena, .{ .label = held.name, .detail = entry.value.source });
        };
    }
    return list.items;
}

/// An action as a completion: its name, and its inputs as what it is.
fn actionValue(arena: Allocator, action: actions.Action, doc: ?[]const u8) Allocator.Error!flux.service.StringValue {
    var inputs: std.Io.Writer.Allocating = .init(arena);
    for (action.bindings, 0..) |binding, i| {
        if (i > 0) inputs.writer.writeAll(", ") catch return error.OutOfMemory;
        inputs.writer.print("{f}", .{binding}) catch return error.OutOfMemory;
    }
    return .{ .label = action.name, .detail = if (action.bindings.len == 0) "no input yet" else inputs.written(), .doc = doc };
}

/// What the game's VM is given, with nothing behind `app` and `files`: see
/// `install`.
fn installForAnalysis(context: ?*anyopaque, vm: *flux.Vm) anyerror!void {
    try install(vm, @ptrCast(@alignCast(context.?)), null);
}

/// The struct a `Script` names: the one it names, or else the one named
/// after its file, as the file is spelt or in CamelCase.
fn classFor(vm: *flux.Vm, module: *flux.object.Module, script: *const Script, source: []const u8, spelled: *[64]u8) ?flux.Value {
    return classAsked(vm, module, script.structName(), source, spelled);
}

/// The struct called `asked`, or with nothing asked, the one named after the
/// file.
fn classAsked(vm: *flux.Vm, module: *flux.object.Module, asked: []const u8, source: []const u8, spelled: *[64]u8) ?flux.Value {
    if (asked.len != 0) return classNamed(vm, module, asked);
    if (classNamed(vm, module, std.fs.path.stem(source))) |found| return found;
    return classNamed(vm, module, expected(source, spelled));
}

fn classNamed(vm: *flux.Vm, module: *flux.object.Module, name: []const u8) ?flux.Value {
    const found = vm.get(module, name) orelse return null;
    return if (found.tag == .class) found else null;
}

/// The struct named after a file, in CamelCase: `BigDoor` for
/// `big_door.flux`. Cut at `into`'s length.
fn expected(source: []const u8, into: *[64]u8) []const u8 {
    var len: usize = 0;
    var upper = true;
    for (std.fs.path.stem(source)) |c| {
        if (c == '_' or c == '-' or c == ' ') {
            upper = true;
            continue;
        }
        if (len == into.len) break;
        into[len] = if (upper) std.ascii.toUpper(c) else c;
        len += 1;
        upper = false;
    }
    return into[0..len];
}

/// What scripts print, said in the log a line at a time.
const Printed = struct {
    line: [512]u8 = undefined,
    len: usize = 0,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    const said = std.log.scoped(.flux);

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Printed = @alignCast(@fieldParentPtr("writer", w));
        var taken: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.take(bytes);
            taken += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.take(last);
        return taken + last.len * splat;
    }

    fn take(self: *Printed, bytes: []const u8) void {
        for (bytes) |c| {
            if (c == '\n') {
                said.info("{s}", .{self.line[0..self.len]});
                self.len = 0;
                continue;
            }
            // A line longer than the buffer is said in parts.
            if (self.len == self.line.len) {
                said.info("{s}", .{self.line[0..self.len]});
                self.len = 0;
            }
            self.line[self.len] = c;
            self.len += 1;
        }
    }
};

test "a file's own struct is the one named after it, in CamelCase" {
    var spelled: [64]u8 = undefined;
    try testing.expectEqualStrings("BigDoor", expected("res://doors/big_door.flux", &spelled));
    try testing.expectEqualStrings("Door", expected("door.flux", &spelled));
    try testing.expectEqualStrings("HotAirBalloon", expected("hot-air balloon.flux", &spelled));

    try testing.expectEqualStrings("Gate", Script.named(.none, "Gate").structName());
    try testing.expectEqualStrings("", Script.of(.none).structName());
    // Cut at the last whole character: 47 bytes, then one of two.
    const long = "a" ** 47 ++ "é";
    try testing.expectEqualStrings("a" ** 47, Script.named(.none, long).structName());
}

test "what a script prints is said a line at a time" {
    var printed: Printed = .{};
    try printed.writer.writeAll("half a ");
    try testing.expectEqual(@as(usize, 7), printed.len);
    try printed.writer.writeAll("line\nand ");
    try testing.expectEqualStrings("and ", printed.line[0..printed.len]);
    try printed.writer.splatByteAll('x', 600);
    try testing.expectEqual(@as(usize, 600 + 4 - 512), printed.len);
}

/// A script's value as a scene writes an `@export`'s: what an editor shows
/// of a field's default. Null for what a scene cannot say - a function, an
/// instance.
pub fn jsonOf(doc: *json.Document, value: flux.Value) json.EditError!json.Value {
    switch (value.tag) {
        .int => return .{ .int = value.asInt() },
        .float => return .{ .float = value.asFloat() },
        .bool => return .{ .bool = value.asBool() },
        .string => return doc.string(value.as(flux.object.String).bytes()),
        .vec2, .vec3 => {
            const list = try doc.array();
            if (value.tag == .vec2) {
                const xy = value.asVec2();
                try list.append(@as(f64, xy[0]));
                try list.append(@as(f64, xy[1]));
            } else {
                const xyz = value.asVec3();
                for (xyz) |each| try list.append(@as(f64, each));
            }
            return list;
        },
        .color => {
            const rgba = value.as(flux.object.Color).rgba;
            var text: [9]u8 = undefined;
            const c: Color = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
            return doc.string(c.hexText(&text));
        },
        .enum_value => {
            const e = flux.object.EnumType.from(value.obj());
            return doc.string(e.members[value.extra].bytes());
        },
        .list => {
            const list = try doc.array();
            for (value.as(flux.object.List).items.items) |item| try list.append(try jsonOf(doc, item));
            return list;
        },
        else => return .null,
    }
}
