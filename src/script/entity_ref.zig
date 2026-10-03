// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `self.entity`, or as any entity it is handed:
//! the entity, its components found by their type, and every call of the
//! app's that is given an entity first.

const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");
const flux = @import("fluxion_script");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const Entity = ecs.Entity;

const Scripts = @import("script.zig").Scripts;
const shortName = @import("script.zig").shortName;
const componentHandle = @import("script.zig").componentHandle;

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
        return try componentHandle(self.scripts, self.entity, component);
    }

    /// Put a `component` on, holding its defaults, and hand it back to fill
    /// in. One it has already is handed back as it is.
    pub fn add(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!flux.Value {
        const entry = try self.entryOf(vm, component);
        const added = self.scripts.app.addComponentNamed(self.entity, entry.name) catch |err| return refused(vm, err, "add", entry.name);
        return componentHandle(self.scripts, self.entity, added.type);
    }

    /// Take a `component` off. One it has not got does nothing.
    pub fn remove(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!void {
        const entry = try self.entryOf(vm, component);
        self.scripts.app.removeComponentNamed(self.entity, entry.name) catch |err| return refused(vm, err, "remove", entry.name);
    }

    fn entryOf(self: *EntityRef, vm: *flux.Vm, component: *const reflect.Type) flux.Vm.Error!*const @import("../scene/scene.zig").Registry.Entry {
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
