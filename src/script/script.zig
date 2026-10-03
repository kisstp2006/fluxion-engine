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

const App = @import("../App.zig");
const actions = @import("../input/actions.zig");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const data_file = @import("../assets/data_files.zig");
const plugins = @import("../project/plugins.zig");
const property = @import("../reflect/property.zig");
const attr = @import("../reflect/attr.zig");
const Project = @import("../project/Project.zig");
const signals = @import("../core/signals.zig");
const Color = @import("../math/color.zig").Color;
const input_event = @import("../input/input_event.zig");
const InputEvent = input_event.InputEvent;
const ClockHandle = @import("../time/game_clocks.zig").ClockHandle;
const dialog = @import("../platform/dialog.zig");

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

const AssetKey = @import("asset_refs.zig").AssetKey;
const assetOf = @import("asset_refs.zig").assetOf;
const assetValue = @import("script_host.zig").assetValue;
const classAsked = @import("script_service.zig").classAsked;
const classFor = @import("script_service.zig").classFor;
const clockKey = @import("time_access.zig").clockKey;
const expected = @import("script_service.zig").expected;
const loadImport = @import("script_service.zig").loadImport;
const scriptValueOf = @import("script_host.zig").scriptValueOf;

/// What the parts of this module that live in files of their own give.
pub const EntityRef = @import("entity_ref.zig").EntityRef;
pub const FileAccess = @import("file_access.zig").FileAccess;
pub const ConfigRef = @import("file_access.zig").ConfigRef;
pub const ImagesAccess = @import("image_access.zig").ImagesAccess;
pub const ImageRef = @import("image_access.zig").ImageRef;
pub const TimeAccess = @import("time_access.zig").TimeAccess;
pub const ClockRef = @import("time_access.zig").ClockRef;
pub const WebAccess = @import("web_access.zig").WebAccess;
pub const WebResponse = @import("web_access.zig").WebResponse;
const web_access = @import("web_access.zig");
pub const FramesRef = @import("asset_refs.zig").FramesRef;
pub const AssetRef = @import("asset_refs.zig").AssetRef;
pub const RefOf = @import("asset_refs.zig").RefOf;
pub const Given = @import("script_host.zig").Given;
pub const install = @import("script_host.zig").install;
pub const serviceOptions = @import("script_service.zig").serviceOptions;
pub const hostServiceOptions = @import("script_service.zig").hostServiceOptions;

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
    /// Whether the scripts are the world's: put on the entities whose
    /// `Script` names them, each given its `ready`, `update` and the rest.
    /// Off is a host's own scripts that are no entity's - an editor's
    /// plugins - which run, and whose tasks, web requests and signals go on,
    /// with the world left alone. Their tasks' owners are the host's to
    /// count, and none is held for a pause. The host stops what it made of
    /// a file before it is read again, and starts it after: so the file is
    /// compiled afresh, not put in place in the old code.
    entities: bool = true,
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

/// How much memory a VM's scripts hold, and how often it is collected:
/// `app.scriptStats()`. Whether `objects` and `live` keep rising, or only
/// `bytes` between collections, tells a leak from collection that is late.
pub const ScriptStats = struct {
    /// Bytes the scripts' objects take, their lists' and maps' storage too.
    bytes: usize = 0,
    /// How many objects there are, alive or not yet collected.
    objects: usize = 0,
    /// How many collections have finished.
    cycles: u64 = 0,
    /// How many objects the last collection left alive.
    live: usize = 0,
    /// How many bytes the next collection starts at.
    threshold: usize = 0,

    pub fn of(vm: *const flux.Vm) ScriptStats {
        const stats = vm.stats();
        return .{
            .bytes = stats.bytes,
            .objects = stats.objects,
            .cycles = stats.cycles,
            .live = stats.live,
            .threshold = stats.threshold,
        };
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
pub fn shortName(t: *const reflect.Type) []const u8 {
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

    /// The stamp of the file a script's path names, or none where it has no
    /// file of its own on the disc - in a pack, which never changes.
    fn ofPath(app: *App, io: std.Io, source: []const u8) ?Stamp {
        const file = app.project.osPath(app.gpa, source) catch return null;
        defer app.gpa.free(file);
        return .of(io, file);
    }
};

/// The methods the engine calls on a script's instance: what each is passed
/// and when, as the compiler checks a struct's methods against and an
/// editor offers them. See `install`.
pub const Lifecycle = enum {
    ready,
    fixed,
    update,
    exit,
    input,
    unhandled_input,
    draw,

    const dt = [_]flux.Hook.Param{.{ .name = "dt", .type = reflect.typeOf(f32) }};
    const event = [_]flux.Hook.Param{.{ .name = "event", .type = reflect.typeOf(InputEvent) }};

    pub fn hook(self: Lifecycle) flux.Hook {
        return switch (self) {
            .ready => .{ .name = "ready", .doc = "Once, when its entity is in the world with the script made: before anything else of it." },
            .fixed => .{ .name = "fixed", .params = &dt, .doc = "Every fixed step, `dt` seconds of the physics' own clock, before the game's `.fixed` systems: what moves a body." },
            .update => .{ .name = "update", .params = &dt, .doc = "Every frame, `dt` seconds after the last, before the game's `.update` systems." },
            .exit => .{ .name = "exit", .doc = "When its entity dies, its `Script` is taken off or turned off, or the world is cleared: at the end of that frame." },
            .input => .{ .name = "input", .params = &event, .doc = "Each thing the player did this frame, in order. `app.setInputAsHandled()` keeps it from the scripts after, and from `unhandled_input`." },
            .unhandled_input => .{ .name = "unhandled_input", .params = &event, .doc = "What no script's `input` took, and the interface did not have." },
            .draw => .{ .name = "draw", .doc = "Its entity's drawing, drawn again: the first frame, and at the end of one that called `self.entity.queueRedraw()`. What it draws - `self.entity.drawLine(...)` and the rest - stays until then." },
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
    /// A plugin's section of the project's settings, its struct given what
    /// the project file and the secrets say: `app.pluginSettings`.
    pluginSettings: *const fn (self: *Scripts, section: []const u8) anyerror!flux.Value,
    /// A script's struct as a data file's text: `app.writeData`.
    writeData: *const fn (self: *Scripts, value: flux.Value) anyerror![]u8,
    /// Keep a script's function while the engine holds it - a tween's
    /// step - and let it go.
    hold: *const fn (self: *Scripts, callable: flux.Value) anyerror!void,
    release: *const fn (self: *Scripts, callable: flux.Value) void,
    /// Call a script's function now, with a value or with none.
    callNow: *const fn (self: *Scripts, callable: flux.Value, value: ?property.Value) void,
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
    /// The game is ending: `app.quitting` is said, for a last request or
    /// save. See `App.stop`.
    quitting,
};

/// The app's scripts: `app.scripts`, once `App.useScripts` has made them.
pub const Scripts = struct {
    app: *App,
    options: Options,
    vm: *flux.Vm,
    calls: Calls,
    /// How a component handle finds its component again.
    resolver: flux.Resolver,
    /// The components handles found last, by entity and type: a script
    /// reads a component's fields one after another, and each read finds
    /// it again. Good while the world's make-up has not changed.
    found: [found_slots]Lookup = @splat(.{}),
    /// What scripts reach as `files`.
    file_access: FileAccess,
    /// What scripts reach as `time`.
    time_access: TimeAccess,
    /// What scripts reach as `images`.
    images_access: ImagesAccess,
    /// What scripts reach as `web`.
    web_access: WebAccess,
    /// The web requests scripts made, each with the task its answer ends.
    web_waiting: std.ArrayList(web_access.Waiting) = .empty,
    /// `app.focus_changed` and `app.quitting`, once a script has reached
    /// for them; `.null` before.
    app_signals: [2]flux.Value = @splat(.null),
    /// Whether the program was in front when last looked: what
    /// `focus_changed` says a change of.
    was_in_front: ?bool = null,
    files: FileTable = .empty,
    /// Each entity's instance, in the order they were made.
    instances: std.AutoArrayHashMapUnmanaged(Entity, Instance) = .empty,
    /// Each instance's entity, by the instance: whose signal an emit is.
    entity_of: std.AutoHashMapUnmanaged(*flux.object.Obj, Entity) = .empty,
    /// The handle each entity is to the scripts, held from the first time
    /// one is handed to them until the end of the frame it dies in.
    handles: std.AutoHashMapUnmanaged(Entity, flux.Value) = .empty,
    /// The handle each component is to the scripts, by its entity and type,
    /// held as `handles` are: one component, one value. See
    /// `componentHandle`.
    component_handles: std.AutoHashMapUnmanaged(ComponentKey, flux.Value) = .empty,
    /// The value each file is to the scripts, once handed to them: one
    /// file, one value. See `assetValue`.
    asset_values: std.AutoHashMapUnmanaged(AssetKey, flux.Value) = .empty,
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
                .pluginSettings = pluginSettings,
                .writeData = writeData,
                .hold = holdCallable,
                .release = releaseCallable,
                .callNow = callNow,
            },
            .resolver = .{
                .context = self,
                .resolve = findComponent,
                .why = "its entity was despawned, or the component was taken off",
            },
            .file_access = .{ .app = app },
            .time_access = .{ .app = app },
            .images_access = .{ .app = app },
            .web_access = .{ .app = app },
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
            .web = try vm.handle(&self.web_access),
        }, if (options.entities) .world else .host);
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
        self.component_handles.deinit(gpa);
        self.asset_values.deinit(gpa);
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
        self.web_waiting.deinit(gpa);
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
    /// The scripts whose VM `vm` is: what a call of the engine's given the
    /// VM works with - the world's, or a host's own.
    pub fn of(vm: *flux.Vm) *Scripts {
        return @ptrCast(@alignCast(vm.host.?));
    }

    pub fn load(self: *Scripts, path: []const u8) !ScriptHandle {
        const app = self.app;
        const io = app.io orelse return error.NoIo;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;

        // Looked at before it is read: a save between the two is seen at the
        // next look, not taken for what was read.
        const stamp: ?Stamp = .ofPath(app, io, source);
        const text = try app.project.readFileAlloc(app.gpa, source, .limited(file_limit));
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

    /// A script's compiled code, which `compile` loads again in a VM set up
    /// as this one is, with none of its text: what a shipped game has in its
    /// place. Only from scripts that do not run - `Options.run` off, an
    /// editor's - since what ran holds values no file can. The caller frees
    /// it. `error.CompileFailed` for a script whose text does not compile,
    /// and `error.Unsaveable` for one that cannot be kept, their reasons in
    /// the log.
    pub fn saveCompiled(self: *Scripts, handle: ScriptHandle, gpa: Allocator, options: flux.image.SaveOptions) ![]u8 {
        const file = self.files.get(handle.toId()) orelse return error.NoSuchScript;
        const module = file.module orelse return error.CompileFailed;
        return self.vm.saveCompiled(module, gpa, options) catch |err| switch (err) {
            error.Unsaveable => {
                self.sayDiagnostics(file.source);
                return error.Unsaveable;
            },
            error.OutOfMemory => error.OutOfMemory,
        };
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
        const stamp: ?Stamp = .ofPath(app, io, file.source);
        const text = try app.project.readFileAlloc(app.gpa, file.source, .limited(file_limit));
        defer app.gpa.free(text);
        try self.setText(handle, text);
        // Looked up again: the new code's defaults can load a script.
        if (self.files.get(handle.toId())) |read| read.stamp = stamp;
        return true;
    }

    /// Every script under `folder` read again from its file - the table's,
    /// and those only another imported, which the table does not hold - so
    /// a host starting a part of its own again, an editor's plugin, runs and
    /// shows what is on disk now. One that does not read or compile is said,
    /// and left as it was.
    pub fn readAgainUnder(self: *Scripts, folder: []const u8) Allocator.Error!void {
        const app = self.app;
        const gpa = app.gpa;
        // The imported first, so a table's file compiled afresh below
        // imports what is new. Gathered before any is read: reading can
        // import more.
        var imported: std.ArrayList(*flux.object.Module) = .empty;
        defer imported.deinit(gpa);
        var modules = self.vm.modules.iterator();
        while (modules.next()) |entry| {
            if (!isUnder(entry.key_ptr.*, folder) or self.isFilesModule(entry.value_ptr.*)) continue;
            try imported.append(gpa, entry.value_ptr.*);
        }
        for (imported.items) |module| {
            const name = module.name.bytes();
            const text = app.project.readFileAlloc(gpa, name, .limited(file_limit)) catch |err| {
                log.warn("{s} is not read again: {t}", .{ name, err });
                continue;
            };
            defer gpa.free(text);
            _ = self.vm.reload(module, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CompileFailed => self.sayDiagnostics(name),
                else => log.warn("{s} is not read again: {t}", .{ name, err }),
            };
        }

        self.changed.clearRetainingCapacity();
        var files = self.files.iterator();
        while (files.next()) |entry| {
            if (entry.value.on_disc and isUnder(entry.value.source, folder)) try self.changed.append(gpa, .fromId(entry.handle));
        }
        for (self.changed.items) |handle| {
            _ = self.reload(handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.warn("{s} is not read again: {t}", .{ self.sourceOf(handle) orelse "a script", err }),
            };
        }
    }

    fn isFilesModule(self: *Scripts, module: *flux.object.Module) bool {
        var it = self.files.iterator();
        while (it.next()) |entry| if (entry.value.module == module) return true;
        return false;
    }

    /// Each file saved since it was read, read again: see `Options.watch`.
    /// One that does not read now - held by the program saving it - is
    /// tried again at the next look.
    fn watchFiles(self: *Scripts) Allocator.Error!void {
        const app = self.app;
        const io = app.io orelse return;
        // Lookup first and read after: reading runs code, which can load a
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
        if (!self.options.run or !self.options.entities) {
            // Nothing runs and no instance holds the old code - or the host
            // let go of what it made of it: compiled afresh.
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
        const world = self.options.entities;
        switch (moment) {
            .input => {
                if (world) {
                    try self.sync();
                    self.readyTheNew();
                    self.deliverInput();
                }
                self.answerDialogs();
                self.hearDrops();
                self.answerWeb();
                self.tellFocus();
            },
            .fixed => |dt| if (world) {
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
                if (world) {
                    try self.sync();
                    self.readyTheNew();
                }
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
                if (world) self.callEach(.update, dt);
                // The scripts' own clock, so `await wait(1.0)` wakes - but
                // not the waits of the entities that do not run now.
                self.vm.setBudget(self.options.budget);
                self.vm.updateHolding(dt, .{ .context = self.app, .held = if (world) heldOwner else heldNever }) catch |err| switch (err) {
                    error.OutOfMemory => self.outOfMemory(null),
                    error.Panic => self.sayPanic(null, "the tasks of"),
                };
            },
            .end_of_frame => {
                self.callTheDeferred();
                self.drawTheWanted();
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
                var component_handles = self.component_handles.iterator();
                while (component_handles.next()) |entry| {
                    if (self.app.world.isAlive(entry.key_ptr.entity)) continue;
                    self.vm.release(entry.value_ptr.*);
                    self.component_handles.removeByPtr(entry.key_ptr);
                }
            },
            .quitting => self.sayAppSignal(.quitting, &.{}),
        }
    }

    /// Make an instance for each enabled `Script` without one, and let go of
    /// each instance whose entity is dead or whose `Script` has gone, changed
    /// or been turned off.
    fn sync(self: *Scripts) Allocator.Error!void {
        const app = self.app;
        try self.letGoOfTheUnwanted();

        // Lookup first and made after: making one runs its struct's defaults,
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

    /// `draw` for each instance whose entity has not been drawn yet, or asked
    /// to be again: on an emptied picture. See `drawing.zig`.
    fn drawTheWanted(self: *Scripts) void {
        var at: usize = 0;
        while (at < self.instances.count()) : (at += 1) {
            const inst = self.instances.values()[at];
            if (!inst.readied) continue;
            const method = inst.methods.get(.draw) orelse continue;
            const entity = self.instances.keys()[at];
            if (self.app.drawings.get(entity)) |held| if (held.drawn and !held.wanted) continue;
            const picture = self.app.drawings.pictureOf(self.app.gpa, entity) catch return self.outOfMemory(null);
            picture.clear();
            picture.wanted = false;
            picture.drawn = true;
            self.call(entity, method, &.{inst.value}, .draw);
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
    fn heldNever(_: ?*anyopaque, _: u64) bool {
        return false;
    }

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
        // A new world counts its changes from nought again.
        self.found = @splat(.{});
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
            // A finger a touch button holds, or the first finger over what
            // took the mouse it is as well; and one finger's gesture as its
            // finger. Two fingers' - and the wheel's pinch - as the
            // pointer's: the first finger is at the pointer.
            .pinch, .pan, .rotate => app.input.isHandled() or app.ui.wantsPointer(),
            .touch, .touch_motion, .tap, .long_press, .swipe => {
                const finger = app.input.touchOf(event.finger().?) orelse return false;
                return finger.on_button or (finger.mouse and app.input.mouse_from_touch and (app.input.isHandled() or app.ui.wantsPointer()));
            },
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
                log.warn("{s} of {f} holds {t}, and is given {f}", .{ name, whose, field.shape.kind, value });
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

    fn pluginSettings(self: *Scripts, section: []const u8) anyerror!flux.Value {
        const app = self.app;
        var found = try plugins.discover(app, app.gpa);
        defer found.deinit();
        const said = for (found.plugins) |*p| {
            const s = p.manifest.settings orelse continue;
            if (std.mem.eql(u8, s.section, section)) break .{ p, s };
        } else return error.NoSuchSection;
        const script_path = try said[0].path(app.gpa, said[1].script);
        defer app.gpa.free(script_path);
        const handle = try self.load(script_path);
        const file = self.files.get(handle.toId()) orelse return error.NoSuchScript;
        const module = file.module orelse return error.ScriptDoesNotCompile;
        var spelled: [64]u8 = undefined;
        const class = classAsked(self.vm, module, said[1].@"struct", file.source, &spelled) orelse return error.NoSuchStruct;
        const vm = self.vm;
        const made = vm.instantiate(class, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Panic => {
                self.sayPanic(null, "making a plugin's settings");
                return error.DefaultsStopped;
            },
        };
        try vm.pushRoot(made);
        defer vm.popRoot();
        // What the project file says, then what it keeps out of itself.
        if (app.project.settings) |*settings| if (settings.kept.rest) |doc| {
            try self.applyValues(made, class, doc.root.get(section), .{ .file = "the project file" });
        };
        const secrets = app.readText(app.gpa, plugins.secrets_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return made,
        };
        defer app.gpa.free(secrets);
        const doc = json.parse(app.gpa, secrets, .{}) catch {
            log.warn("{s} is not JSON: its secrets are passed over", .{plugins.secrets_path});
            return made;
        };
        defer doc.deinit();
        try self.applyValues(made, class, doc.root.get(section), .{ .file = plugins.secrets_path });
        return made;
    }

    /// A value a scene wrote as the script's own, as a field of `field`'s
    /// kind holds it; null for one it cannot hold.
    fn fluxOf(self: *Scripts, field: flux.FieldInfo, value: json.Value) flux.Vm.Error!?flux.Value {
        if (flux.annotationOf(field, "entity") != null) {
            if (value == .null) return .null;
            const text = value.asString() orelse return null;
            const uuid = id.Uuid.parse(text) catch return null;
            const entity = self.app.findUuid(uuid) orelse return .null;
            return try entityHandle(self, entity);
        }
        return self.fluxOfShape(field.shape, field, value, false);
    }

    /// `value` as a value of `shape` holds it: a list's items and a map's
    /// keys and values by `field`'s `element` and `key`. One inside a list
    /// or a map is `inner`: it holds no list or map of its own.
    fn fluxOfShape(self: *Scripts, shape: flux.Shape, field: flux.FieldInfo, value: json.Value, inner: bool) flux.Vm.Error!?flux.Value {
        const vm = self.vm;
        if (value == .null) return if (shape.nullable or shape.kind == .any) .null else null;
        const kind = shape.kind;
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
            .enum_member => return memberNamed(shape, value.asString() orelse return null),
            .host => return try self.hostOfJson(shape.host orelse return null, value),
            .list => {
                if (inner) return null;
                const items = value.asArray() orelse return null;
                if (items.len() > 1024) return null;
                var made: std.ArrayList(flux.Value) = .empty;
                defer made.deinit(self.app.gpa);
                // Each rooted until the list has it: making the next can
                // collect.
                defer for (made.items) |_| vm.popRoot();
                for (items.items()) |item| {
                    const one = try self.fluxOfShape(field.element, field, item, true) orelse return null;
                    try made.append(self.app.gpa, one);
                    try vm.pushRoot(one);
                }
                return try vm.newList(field.element.check, made.items);
            },
            .map => {
                if (inner) return null;
                if (value.asObject() == null or value.keys().len > 1024) return null;
                const gpa = self.app.gpa;
                var keys: std.ArrayList(flux.Value) = .empty;
                defer keys.deinit(gpa);
                var values: std.ArrayList(flux.Value) = .empty;
                defer values.deinit(gpa);
                defer for (keys.items) |_| vm.popRoot();
                defer for (values.items) |_| vm.popRoot();
                for (value.keys(), value.values()) |name, item| {
                    const key = try self.keyOf(field.key, name) orelse return null;
                    try keys.append(gpa, key);
                    try vm.pushRoot(key);
                    const one = try self.fluxOfShape(field.element, field, item, true) orelse return null;
                    try values.append(gpa, one);
                    try vm.pushRoot(one);
                }
                return try vm.newMap(field.key.check, field.element.check, keys.items, values.items);
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

    /// A map's key a scene wrote as the text it is: text, a whole number,
    /// or an enum's member by its name.
    fn keyOf(self: *Scripts, shape: flux.Shape, text: []const u8) flux.Vm.Error!?flux.Value {
        return switch (shape.kind) {
            .string, .any => try self.vm.string(text),
            .int => .int(std.fmt.parseInt(i64, text, 10) catch return null),
            .enum_member => memberNamed(shape, text),
            else => null,
        };
    }

    /// A file a scene names, as the scripts' value of it: `host` says of
    /// which kind. Null for one that does not load.
    fn hostOfJson(self: *Scripts, host: *const reflect.Type, value: json.Value) flux.Vm.Error!?flux.Value {
        const path = value.asString() orelse return null;
        inline for (AssetKind.handled) |kind| if (host.same(reflect.typeOf(RefOf(kind)))) {
            const handle = self.app.loadAsset(kind.Handle(), path) catch |err| {
                log.warn("the {s} {s} did not load: {t}", .{ kind.label(), path, err });
                return null;
            };
            return try assetValue(self, kind, handle);
        };
        return null;
    }

    // ---------------------------------------------------------------------
    // The engine's signals, as the scripts' own
    // ---------------------------------------------------------------------

    /// The scripts' own signal for `component.name` of `source`, made the
    /// first time a script reaches it and connected to the engine's.
    /// A clock's `minute_passed`, `hour_passed` or `day_passed`, made the
    /// first time a script reaches for it.
    pub fn clockSignal(self: *Scripts, handle: ClockHandle, which: usize) flux.Vm.Error!flux.Value {
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
            const handle: ClockHandle = @bitCast(entry.key_ptr.*);
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

    pub fn bridgeOf(self: *Scripts, source: Entity, component: []const u8, name: []const u8, arity: usize) flux.Vm.Error!flux.Value {
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

    fn holdCallable(self: *Scripts, callable: flux.Value) anyerror!void {
        switch (callable.tag) {
            .function, .method, .native => {},
            else => return error.NotCallable,
        }
        try self.vm.hold(callable);
    }

    fn releaseCallable(self: *Scripts, callable: flux.Value) void {
        self.vm.release(callable);
    }

    fn callNow(self: *Scripts, callable: flux.Value, value: ?property.Value) void {
        var given: [1]flux.Value = undefined;
        const args: []const flux.Value = if (value) |held| blk: {
            given[0] = scriptValueOf(self.vm, held) catch return;
            break :blk &given;
        } else &.{};
        self.vm.setBudget(self.options.budget);
        _ = self.vm.call(callable, args) catch |err| {
            self.failures += 1;
            switch (err) {
                error.Panic => self.writePanic(null, "a tween's call in"),
                error.OutOfMemory => {},
            }
        };
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

    /// The signals of `app`'s a script reaches as members:
    /// `app.focus_changed`, `app.quitting`.
    pub const AppSignal = enum {
        focus_changed,
        quitting,

        pub fn params(which: AppSignal) u8 {
            return switch (which) {
                .focus_changed => 1,
                .quitting => 0,
            };
        }
    };

    /// The signal of `app`'s, made the first time a script reaches for it.
    pub fn appSignal(self: *Scripts, which: AppSignal) flux.Vm.Error!flux.Value {
        const held = &self.app_signals[@intFromEnum(which)];
        if (held.tag != .signal) {
            const made = try self.vm.newSignal(@tagName(which), which.params());
            try self.vm.hold(made);
            held.* = made;
        }
        return held.*;
    }

    fn sayAppSignal(self: *Scripts, which: AppSignal, args: []const flux.Value) void {
        const signal = self.app_signals[@intFromEnum(which)];
        if (signal.tag != .signal) return;
        self.vm.setBudget(self.options.budget);
        self.vm.emitSignalValue(signal, args) catch |err| switch (err) {
            error.OutOfMemory => self.outOfMemory(null),
            error.Panic => self.sayPanic(null, "a script told " ++ "the app's news"),
        };
    }

    /// `focus_changed`, said when the program comes to the front or goes
    /// behind another: with whether it is in front now.
    fn tellFocus(self: *Scripts) void {
        const now = self.app.inForeground();
        defer self.was_in_front = now;
        const before = self.was_in_front orelse return;
        if (before != now) self.sayAppSignal(.focus_changed, &.{.boolean(now)});
    }

    /// The web's answers to the scripts' requests, each ending the task
    /// that waited for it.
    fn answerWeb(self: *Scripts) void {
        var at: usize = 0;
        while (at < self.web_waiting.items.len) {
            const waiting = self.web_waiting.items[at];
            var done = self.app.takeWebAnswer(waiting.id) orelse {
                at += 1;
                continue;
            };
            _ = self.web_waiting.orderedRemove(at);
            defer self.vm.release(waiting.task);
            self.vm.setBudget(self.options.budget);
            web_access.finish(self, waiting, &done) catch |err| switch (err) {
                error.OutOfMemory => self.outOfMemory(null),
                error.Panic => self.sayPanic(null, "a script given a web answer"),
            };
        }
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

/// How many components `Scripts.found` keeps.
const found_slots = 64;

/// A component a handle found, and the world's `structure` then: the cell
/// stays where it is until something is spawned, despawned, added or taken
/// off.
const Lookup = struct {
    key: u64 = 0,
    type: ?*const reflect.Type = null,
    structure: u64 = 0,
    value: reflect.Value = undefined,
};

/// Where a component a script holds is now: where it was last time, when
/// the world's make-up has not changed since.
fn findComponent(context: ?*anyopaque, key: u64, t: *const reflect.Type) ?reflect.Value {
    const self: *Scripts = @ptrCast(@alignCast(context.?));
    const structure = self.app.world.structure;
    const spot = &self.found[@intCast((key *% 0x9E37_79B9_7F4A_7C15 ^ @intFromPtr(t) >> 4) % found_slots)];
    if (spot.type == t and spot.key == key and spot.structure == structure) return spot.value;
    const value = self.app.componentOfType(.fromInt(key), t) orelse return null;
    spot.* = .{ .key = key, .type = t, .structure = structure, .value = value };
    return value;
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

pub fn typeName(arg: flux.Value) []const u8 {
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
pub fn entityHandle(scripts: *Scripts, entity: Entity) flux.Vm.Error!flux.Value {
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

/// Whether `path` is inside `folder`, and not merely spelt as it begins.
fn isUnder(path: []const u8, folder: []const u8) bool {
    const bare = std.mem.trimEnd(u8, folder, "/");
    return path.len > bare.len and std.mem.startsWith(u8, path, bare) and path[bare.len] == '/';
}

/// A component of an entity's, by both.
const ComponentKey = struct { entity: Entity, type: *const reflect.Type };

/// The handle a component is to the scripts: made the first time one asks
/// for it and the same one after, until the end of the frame its entity
/// dies in. A handle finds its component again at each use, so the first
/// serves every later `get` - and a script reading a component each frame
/// makes nothing for the collector to free.
pub fn componentHandle(scripts: *Scripts, entity: Entity, component: *const reflect.Type) flux.Vm.Error!flux.Value {
    const key: ComponentKey = .{ .entity = entity, .type = component };
    if (scripts.component_handles.get(key)) |known| return known;
    const vm = scripts.vm;
    try scripts.component_handles.ensureUnusedCapacity(scripts.app.gpa, 1);
    const handle = try vm.liveHandle(&scripts.resolver, entity.toInt(), component);
    try vm.hold(handle);
    scripts.component_handles.putAssumeCapacityNoClobber(key, handle);
    return handle;
}

/// What the engine's doc comments say of its types' members: see
/// `tools/member_docs.zig`.
pub const member_docs = @import("member_docs").list(flux.Doc);

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
            // A line longer than the buffer is said in parts, each cut
            // between characters: a character it would cut in half goes
            // whole into the next part.
            if (self.len == self.line.len) {
                const cut = wholeCharacters(self.line[0..self.len]);
                said.info("{s}", .{self.line[0..cut]});
                std.mem.copyForwards(u8, self.line[0 .. self.len - cut], self.line[cut..self.len]);
                self.len -= cut;
            }
            self.line[self.len] = c;
            self.len += 1;
        }
    }

    /// How much of `bytes` is whole characters: all of it, but for a last
    /// one whose bytes have not all come yet. Bytes that are not UTF-8 count
    /// as whole, each on its own.
    fn wholeCharacters(bytes: []const u8) usize {
        var start = bytes.len;
        // Back over the continuation bytes a character can have, at most.
        while (start > 0 and bytes.len - start < 4) {
            start -= 1;
            if (bytes[start] & 0xC0 != 0x80) break;
        }
        const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes.len;
        // A lead byte with its last continuation byte still to come; never
        // the whole buffer, or nothing would be said.
        return if (start + length > bytes.len and start > 0) start else bytes.len;
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

test "a printed line too long for one part is cut between characters" {
    var printed: Printed = .{};
    // One byte, then two-byte characters: the 512th byte is the first half
    // of one, which waits for the next part.
    try printed.writer.writeAll("a");
    try printed.writer.splatBytesAll("ő", 300);
    try testing.expectEqual(@as(usize, 1 + 600 - 511), printed.len);
    const rest = printed.line[0..printed.len];
    try testing.expect(std.unicode.utf8ValidateSlice(rest));
    try testing.expect(std.mem.startsWith(u8, rest, "ő"));

    // Whole characters are whole, a half one is not, and bytes that are not
    // UTF-8 are their own.
    try testing.expectEqual(@as(usize, 3), Printed.wholeCharacters("aő"));
    try testing.expectEqual(@as(usize, 1), Printed.wholeCharacters("a\xC5"));
    try testing.expectEqual(@as(usize, 1), Printed.wholeCharacters("a\xF0\x9F"));
    try testing.expectEqual(@as(usize, 4), Printed.wholeCharacters("\x80\x80\x80\x80"));
}

/// A script's value as a scene writes an `@export`'s: what an editor shows
/// of a field's default. A file is its path, and a map an object whose
/// names are its keys - text, a whole number or an enum's member. Null for
/// what a scene cannot say - a function, an instance.
/// The member of `shape`'s enum called `name`, or null for none.
fn memberNamed(shape: flux.Shape, name: []const u8) ?flux.Value {
    const e = shape.enum_type orelse return null;
    for (e.members, 0..) |member, i| {
        if (std.mem.eql(u8, member.bytes(), name)) return flux.enumMember(e, @intCast(i));
    }
    return null;
}

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
        .map => {
            const object = try doc.object();
            var it = value.as(flux.object.Map).table.iterator();
            while (it.next()) |entry| {
                var digits: [24]u8 = undefined;
                const name: []const u8 = switch (entry.key.tag) {
                    .string => entry.key.as(flux.object.String).bytes(),
                    .int => std.fmt.bufPrint(&digits, "{d}", .{entry.key.asInt()}) catch unreachable,
                    .enum_value => flux.object.EnumType.from(entry.key.obj()).members[entry.key.extra].bytes(),
                    else => continue,
                };
                try object.put(name, try jsonOf(doc, entry.value));
            }
            return object;
        },
        .handle => {
            const file = assetOf(value) orelse return .null;
            return doc.string(file.path);
        },
        else => return .null,
    }
}
