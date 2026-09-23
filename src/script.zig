// SPDX-License-Identifier: BSD-3-Clause

//! Flux scripts on entities. A `Script` component names a `.flux` file and a
//! struct in it. The engine makes the entity an instance of that struct, with
//! the entity in it as `self.entity`, and calls whichever of these the struct
//! declares:
//!
//! - `ready(self)` before anything else of it;
//! - `physics(self, dt: float)` every fixed step, before the game's `.fixed`
//!   systems;
//! - `update(self, dt: float)` every frame, before the game's `.update`
//!   systems;
//! - `exit(self)` when the entity dies, when its `Script` is taken off or
//!   turned off, or when the world is cleared.
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
//!         if (self.open) self.entity.get("Transform2D").rotation += dt;
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
//! it reads and cannot assign. `App.scriptSetup` gives an editor's language
//! service the same two, so it checks and completes what the game runs.
//!
//! **A component is found again at each use.** `self.entity.get("Health")`
//! is a handle the engine looks up every time the script touches it, so
//! keeping it in a field is safe while rows move. Once the component or its
//! entity is gone, using it stops the script with a panic that says so.
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
const reflect = @import("fluxion_reflect");
/// The language: its VM, its values, its language service.
pub const flux = @import("fluxion_script");

const math = @import("fluxion_math");

const App = @import("App.zig");
const attr = @import("attr.zig");
const Project = @import("Project.zig");
const signals = @import("signals.zig");
const tileset = @import("tileset.zig");
const Color = @import("color.zig").Color;

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
    /// `update`, a step's `physics`, or the frame's waiting tasks. Null for
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
    /// default, `ready`, `physics`, `update` or `exit` runs, no task wakes,
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
    pub const reflect_methods = .{ .alive, .name, .uuid, .has, .get, .add, .remove };

    /// Whether it is still in the world. False in `exit` for a despawned
    /// entity.
    pub fn alive(self: *EntityRef) bool {
        return self.scripts.app.world.isAlive(self.entity);
    }

    /// Its name, or "" for one without.
    pub fn name(self: *EntityRef) []const u8 {
        return self.scripts.app.nameOf(self.entity) orelse "";
    }

    /// Its UUID as text, or "" for one without.
    pub fn uuid(self: *EntityRef) []const u8 {
        const held = self.scripts.app.uuidOf(self.entity) orelse return "";
        self.uuid_text = held.toString();
        return &self.uuid_text;
    }

    /// Whether it has the component called `component`.
    pub fn has(self: *EntityRef, component: []const u8) bool {
        return self.scripts.app.componentOf(self.entity, component) != null;
    }

    /// The component called `component`, to read and write in place:
    /// `self.entity.get("Transform2D").x += 1`. Null when it has none. It is
    /// found again at each use, so it may be kept.
    pub fn get(self: *EntityRef, vm: *flux.Vm, component: []const u8) flux.Vm.Error!flux.Value {
        const found = self.scripts.app.componentOf(self.entity, component) orelse return .null;
        return vm.liveHandle(&self.scripts.resolver, self.entity.toInt(), found.type);
    }

    /// Put the component called `component` on, holding its defaults, and
    /// hand it back to fill in. One it has already is handed back as it is.
    pub fn add(self: *EntityRef, vm: *flux.Vm, component: []const u8) flux.Vm.Error!flux.Value {
        const added = self.scripts.app.addComponentNamed(self.entity, component) catch |err| return refused(vm, err, "add", component);
        return vm.liveHandle(&self.scripts.resolver, self.entity.toInt(), added.type);
    }

    /// Take the component called `component` off. One it has not got does
    /// nothing.
    pub fn remove(self: *EntityRef, vm: *flux.Vm, component: []const u8) flux.Vm.Error!void {
        self.scripts.app.removeComponentNamed(self.entity, component) catch |err| return refused(vm, err, "remove", component);
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

const Lifecycle = enum {
    ready,
    physics,
    update,
    exit,

    /// How many parameters it takes besides `self`.
    fn params(self: Lifecycle) u8 {
        return switch (self) {
            .ready, .exit => 0,
            .physics, .update => 1,
        };
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
};

/// Where in the frame `Calls.pass` is called.
pub const Moment = union(enum) {
    /// Before the game's `.fixed` systems, with the step.
    physics: f32,
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
    files: FileTable = .empty,
    /// Each entity's instance, in the order they were made.
    instances: std.AutoArrayHashMapUnmanaged(Entity, Instance) = .empty,
    /// Each instance's entity, by the instance: whose signal an emit is.
    entity_of: std.AutoHashMapUnmanaged(*flux.object.Obj, Entity) = .empty,
    /// The handle each entity is to the scripts, held from the first time
    /// one is handed to them until the end of the frame it dies in.
    handles: std.AutoHashMapUnmanaged(Entity, flux.Value) = .empty,
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
            },
            .resolver = .{
                .context = app,
                .resolve = findComponent,
                .why = "its entity was despawned, or the component was taken off",
            },
        };
        const vm = try flux.Vm.create(app.gpa, .{
            .out = options.out orelse &self.printed.writer,
            .max_bytes = options.max_bytes,
            .io = app.io,
            .on_task_panic = sayTaskPanic,
            .on_emit = heardEmit,
            .host_types = &.{ entity_type, tile_value_type },
        });
        errdefer vm.destroy();
        vm.host = self;
        try install(vm, try vm.handle(app));
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
        self.refused.deinit(gpa);
        self.scratch.deinit(gpa);
        self.changed.deinit(gpa);
        var it = self.files.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value.source);
            gpa.free(entry.value.text);
        }
        self.files.deinit(gpa);
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
            .physics => |dt| {
                try self.sync();
                self.readyTheNew();
                self.callEach(.physics, dt);
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
                self.callEach(.update, dt);
                // The scripts' own clock, so `await wait(1.0)` wakes.
                self.vm.setBudget(self.options.budget);
                self.vm.update(dt) catch |err| switch (err) {
                    error.OutOfMemory => self.outOfMemory(null),
                    error.Panic => self.sayPanic(null, "the tasks of"),
                };
            },
            .end_of_frame => {
                try self.letGoOfTheUnwanted();
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
                log.warn("`{s}` takes {d} parameters besides self, and the engine passes {s}: it is not called", .{
                    member.name,
                    member.params,
                    if (which.params() == 0) "none" else "dt",
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
            self.call(self.instances.keys()[at], method, &.{ inst.value, .float(dt) }, which);
        }
    }

    /// An instance let go of: its `exit`, if it was readied, and then the
    /// collector may have it.
    fn letGo(self: *Scripts, entity: Entity, inst: Instance) void {
        // What `exit` emits is still its entity's.
        if (inst.readied) {
            if (inst.methods.get(.exit)) |method| self.call(entity, method, &.{inst.value}, .exit);
        }
        _ = self.entity_of.remove(inst.value.obj());
        self.vm.release(inst.value);
    }

    /// Every instance let go of, each with its `exit`: the world was cleared.
    fn clear(self: *Scripts) void {
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
        _ = vm.call(method, values[0 .. args.len + 1]) catch |err| {
            self.failures += 1;
            switch (err) {
                error.Panic => self.writePanic(entity, "a signal's call into the script of"),
                error.OutOfMemory => {},
            }
            return err;
        };
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

    /// One call into a script, under the budget.
    fn call(self: *Scripts, entity: Entity, method: flux.Value, args: []const flux.Value, which: Lifecycle) void {
        self.vm.setBudget(self.options.budget);
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

/// How a script sees an `Entity`: see "An entity is one handle" above.
const entity_type: flux.HostType = .{
    .type = reflect.typeOf(Entity),
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

/// What every VM that compiles the game's scripts is given - the game's
/// own, and each of an editor's analyses - so the two agree on what a
/// script may name.
pub fn install(vm: *flux.Vm, app: flux.Value) Allocator.Error!void {
    try vm.declareHostMember("entity", "The entity this script is on: `alive()`, `name()`, `uuid()`, `has(name)`, `get(name)`, `add(name)`, `remove(name)`.");
    try vm.defineGlobal("app", app, "The engine: the calls `App.reflect_methods` lists.");
}

/// For `App.scriptSetup`. An analysis only compiles, so `app` is a name
/// with nothing behind it there.
pub fn serviceOptions(app: *App) flux.service.Options {
    return .{ .setup = .{ .context = app, .run = installForAnalysis }, .io = app.io };
}

fn installForAnalysis(context: ?*anyopaque, vm: *flux.Vm) anyerror!void {
    _ = context;
    try install(vm, .null);
}

/// The struct a `Script` names: the one it names, or else the one named
/// after its file, as the file is spelt or in CamelCase.
fn classFor(vm: *flux.Vm, module: *flux.object.Module, script: *const Script, source: []const u8, spelled: *[64]u8) ?flux.Value {
    const asked = script.structName();
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
