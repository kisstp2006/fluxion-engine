// SPDX-License-Identifier: BSD-3-Clause

//! What a script's VM is told of the engine, in one place: the types a
//! script can name, how a value crosses between the two, the members a
//! handle reads and writes beyond its fields, the hooks the engine calls and
//! the annotations it reads. `install` says it all.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const reflect = @import("fluxion_reflect");
const flux = @import("fluxion_script");
const App = @import("../App.zig");
const component_texts = @import("../scene/component_texts.zig");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;
const property = @import("../reflect/property.zig");
const attr = @import("../reflect/attr.zig");
const Project = @import("../project/Project.zig");
const tileset = @import("../tiles/tileset.zig");
const Material = @import("../render/shaders.zig").Material;
const Color = @import("../math/color.zig").Color;
const input_event = @import("../input/input_event.zig");
const InputEvent = input_event.InputEvent;
const datetime = @import("../time/datetime.zig");
const Transform2D = @import("../scene/components.zig").Transform2D;
const Entity = ecs.Entity;

const AssetKey = @import("asset_refs.zig").AssetKey;
const AssetRef = @import("asset_refs.zig").AssetRef;
const ClockRef = @import("time_access.zig").ClockRef;
const ConfigRef = @import("file_access.zig").ConfigRef;
const EntityRef = @import("entity_ref.zig").EntityRef;
const FileAccess = @import("file_access.zig").FileAccess;
const FramesRef = @import("asset_refs.zig").FramesRef;
const ImageRef = @import("image_access.zig").ImageRef;
const ImagesAccess = @import("image_access.zig").ImagesAccess;
const Lifecycle = @import("script.zig").Lifecycle;
const RefOf = @import("asset_refs.zig").RefOf;
const Scripts = @import("script.zig").Scripts;
const TimeAccess = @import("time_access.zig").TimeAccess;
const WebAccess = @import("web_access.zig").WebAccess;
const WebResponse = @import("web_access.zig").WebResponse;
const entityHandle = @import("script.zig").entityHandle;
const member_docs = @import("script.zig").member_docs;
const typeName = @import("script.zig").typeName;

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
            return assetValue(self, kind, handle);
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
                    if (vm.reflectOf(value)) |now| if (now.asConst(RefOf(kind))) |ref| break :blk2 ref.handle;
                    return vm.fail("a " ++ comptime kind.label() ++ " is wanted here, not a {s}", .{value.as(flux.object.Handle).value.type.name.slice()});
                },
                else => return vm.fail("a " ++ comptime kind.label() ++ " is wanted here, or its path, as \"res://...\", not {s}", .{typeName(value)}),
            };
            into.set(H, handle) catch return vm.fail("this " ++ comptime kind.label() ++ " can only be read", .{});
        }
    };
    return .{
        .type = reflect.typeOf(H),
        .script = reflect.typeOf(RefOf(kind)),
        .nullable = true,
        .from_string = true,
        .to_script = Shim.toScript,
        .from_script = Shim.fromScript,
    };
}

/// The value a file is to the scripts: made the first time, the same one
/// after.
pub fn assetValue(scripts: *Scripts, comptime kind: AssetKind, handle: kind.Handle()) flux.Vm.Error!flux.Value {
    const key: AssetKey = .{ .kind = kind, .index = handle.index, .generation = handle.generation };
    if (scripts.asset_values.get(key)) |known| return known;
    const vm = scripts.vm;
    try scripts.asset_values.ensureUnusedCapacity(scripts.app.gpa, 1);
    const Ref = RefOf(kind);
    const ref = try vm.gpa.create(Ref);
    ref.* = .{ .scripts = scripts, .handle = handle };
    const made = vm.adoptHandle(ref) catch |err| {
        vm.gpa.destroy(ref);
        return err;
    };
    try vm.hold(made);
    scripts.asset_values.putAssumeCapacityNoClobber(key, made);
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
            if (component_texts.attributeOf(entry.type, name) != null) return try vm.string(self.app.textNamed(source, entry.name, name));
            // A transform's place and scale as vectors: `t.position`.
            if (entry.type.same(reflect.typeOf(Transform2D))) return transformVector(self, source, name);
            // A material's numbers: `material.strength`.
            if (entry.type.same(reflect.typeOf(Material))) if (try shaderParamOf(self, source, name)) |value| return value;
            for (entry.signals) |decl| {
                if (std.mem.eql(u8, decl.name, name)) return try self.bridgeOf(source, entry.name, decl.name, decl.args.fields().len);
            }
            return null;
        }
        return null;
    }
    const now = vm.reflectOf(handle) orelse return null;
    inline for (AssetKind.handled) |kind| if (now.asConst(RefOf(kind))) |file| {
        if (std.mem.eql(u8, name, "resource_path")) return try vm.string(file.resourcePath());
        return null;
    };
    if (now.asConst(WebResponse)) |response| return response.member(vm, name);
    // `app.focus_changed`, `app.quitting`.
    if (now.as(App) != null) {
        const which = std.meta.stringToEnum(Scripts.AppSignal, name) orelse return null;
        return try self.appSignal(which);
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
/// kept beside it, as its `attr.Text` says. See `component_texts.zig`.
fn hostSetMember(vm: *flux.Vm, handle: flux.Value, name: []const u8, value: flux.Value) flux.Vm.Error!bool {
    const self: *Scripts = @ptrCast(@alignCast(vm.host.?));
    const h = handle.as(flux.object.Handle);
    if (h.live == null or h.live.? != &self.resolver) return false;
    const source = Entity.fromInt(h.key);
    for (self.app.scene_components.entries.items) |*entry| {
        if (!entry.type.same(h.value.type)) continue;
        if (entry.type.same(reflect.typeOf(Material))) return setShaderParamOf(self, source, name, value);
        if (entry.type.same(reflect.typeOf(Transform2D))) return setTransformVector(self, source, name, value);
        if (component_texts.attributeOf(entry.type, name) == null) return false;
        if (value.tag != .string) return vm.fail("{s}.{s} is text, not {s}", .{ entry.name, name, typeName(value) });
        self.app.setTextNamed(source, entry.name, name, value.as(flux.object.String).bytes()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return vm.fail("{s}.{s} could not be written: {t}", .{ entry.name, name, err }),
        };
        return true;
    }
    return false;
}

/// A transform's `x, y` and `scale_x, scale_y` as the vectors a script moves
/// them by: `t.position += velocity * delta`. Null for any other name.
fn transformVector(self: *Scripts, entity: Entity, name: []const u8) ?flux.Value {
    const held = self.app.world.get(entity, Transform2D) orelse return null;
    if (std.mem.eql(u8, name, "position")) return .vec2(held.x, held.y);
    if (std.mem.eql(u8, name, "scale")) return .vec2(held.scale_x, held.scale_y);
    return null;
}

fn setTransformVector(self: *Scripts, entity: Entity, name: []const u8, value: flux.Value) flux.Vm.Error!bool {
    const place = std.mem.eql(u8, name, "position");
    if (!place and !std.mem.eql(u8, name, "scale")) return false;
    if (value.tag != .vec2) return self.vm.fail("Transform2D.{s} is a vec2, not {s}", .{ name, typeName(value) });
    const held = self.app.world.get(entity, Transform2D) orelse return false;
    const xy = value.asVec2();
    if (place) {
        held.x = xy[0];
        held.y = xy[1];
    } else {
        held.scale_x = xy[0];
        held.scale_y = xy[1];
    }
    return true;
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
    const held = self.app.world.get(entity, Material) orelse return false;
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
    return scriptValueOf(vm, value.asConst(property.Value).?.*);
}

/// A tweened value as a script has it: a number, a `vec2`, a `color`, a
/// bool or a name.
pub fn scriptValueOf(vm: *flux.Vm, value: property.Value) flux.Vm.Error!flux.Value {
    return switch (value) {
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

/// The values behind `app`, `files`, `time`, `images` and `web` where the
/// scripts run.
pub const Given = struct { app: flux.Value, files: flux.Value, time: flux.Value, images: flux.Value, web: flux.Value };

/// What every VM that compiles the game's scripts is given - the game's own,
/// with the values `given` holds, and each of an editor's analyses, with
/// their types only - so the two agree on what a script may name, what it
/// can call, and what is said of it: the engine's types and enums by name,
/// the calls an entity has of `app`'s, what its components have beside
/// their fields, the methods the engine calls and the annotations it reads.
pub fn install(vm: *flux.Vm, app: *App, given: ?Given) Allocator.Error!void {
    // The project says how strict the compiler is, for the game and for an
    // editor's analyses alike.
    vm.options.unhandled_errors = if (app.project.settings) |s| s.scripting.unhandled_errors else (Project.Settings{}).scripting.unhandled_errors;
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
        try vm.defineGlobal("web", g.web, web_doc);
    } else {
        try vm.declareGlobal("app", reflect.typeOf(App), app_doc);
        try vm.declareGlobal("files", reflect.typeOf(FileAccess), files_doc);
        try vm.declareGlobal("time", reflect.typeOf(TimeAccess), time_doc);
        try vm.declareGlobal("images", reflect.typeOf(ImagesAccess), images_doc);
        try vm.declareGlobal("web", reflect.typeOf(WebAccess), web_doc);
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
    try vm.declareOpen(reflect.typeOf(Material));
    try vm.declareMember(.{ .of = reflect.typeOf(Transform2D), .name = "position", .type = .vec2, .writable = true, .doc = "`x` and `y` as one vector: `t.position += velocity * delta`." });
    try vm.declareMember(.{ .of = reflect.typeOf(Transform2D), .name = "scale", .type = .vec2, .writable = true, .doc = "`scale_x` and `scale_y` as one vector." });
    for (ClockRef.signal_names) |name| try vm.declareMember(.{ .of = reflect.typeOf(ClockRef), .name = name, .type = .signal });
    for (WebResponse.fields) |f| try vm.declareMember(.{ .of = reflect.typeOf(WebResponse), .name = f.name, .type = f.type, .doc = f.doc });
    try vm.declareMember(.{ .of = reflect.typeOf(App), .name = "focus_changed", .type = .signal, .doc = "Said when the game comes to the front or goes behind another program, with whether it is in front now: `app.focus_changed.connect(fn(front: bool) { ... })`." });
    try vm.declareMember(.{ .of = reflect.typeOf(App), .name = "quitting", .type = .signal, .doc = "Said as the game ends, before its last frame is let go: what is asked of the web then is given a moment to go - a session closed, a score sent." });
    inline for (AssetKind.handled) |kind| {
        if (kind != .frames) try vm.declareType(reflect.typeOf(AssetRef(kind)));
        try vm.declareMember(.{ .of = reflect.typeOf(RefOf(kind)), .name = "resource_path", .type = .string, .doc = "The file it was read from, or \"\" for one made in memory and not saved yet." });
    }
    for (std.enums.values(Lifecycle)) |which| try vm.declareHook(which.hook());
    for (annotations) |a| try vm.declareAnnotation(a);
}

/// The engine's types a script names besides its components, and with them
/// the enums and unions they take and give - `Key`, `WindowMode` - and what
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
    reflect.typeOf(WebAccess),
    reflect.typeOf(WebResponse),
    reflect.typeOf(FramesRef),
    reflect.typeOf(datetime.DateTime),
    reflect.typeOf(datetime.Duration),
    reflect.typeOf(InputEvent),
};

/// What the engine reads of an exported field besides `@export`: see
/// `script_exports.zig` and the editor's Inspector.
const annotations = [_]flux.Annotation{
    .{ .name = "range", .sig = "@range(min, max, step)", .doc = "The numbers an exported field may be, for the Inspector's slider: `@range(0, 100)`, the step left out for any." },
    .{ .name = "multiline", .sig = "@multiline", .doc = "An exported string written over several lines." },
    .{ .name = "group", .sig = "@group(name: string)", .doc = "Where an exported field is listed in the Inspector, under a heading of its own." },
    .{ .name = "file", .sig = "@file(ending: string, ...)", .doc = "An exported string that names a file of the project's, by its endings: `@file(\"png\", \"jpg\")`." },
    .{ .name = "entity", .sig = "@entity", .doc = "An exported field that names an entity of the scene, chosen from its tree." },
    .{ .name = "secret", .sig = "@secret", .doc = "An exported field of a plugin's settings kept out of the project file - a private key - in the project's .fluxion/secrets.json, which version control leaves out and an export puts in the game's pack. Anyone with the game can still dig it out of it." },
};

const entity_doc = "The entity this script is on: `get(Sprite)`, `find(Sprite)`, `has`, `add`, `remove`, `alive()`, `uuid()`, and every call of `app`'s given an entity first - `name()`, `parent()`, `globalPosition()`.";

const app_doc = "The engine: the calls `App.reflect_methods` lists.";

const files_doc = "The game's files to read (`res://`) and the player's to read and write (`user://`): `readText(path)`, `writeText(path, text)`, `appendText`, `exists`, `isDir`, `list`, `copy`, `move`, `remove`, `size`, `modifiedTime`, `sha256`; kept sealed with `writeSecret(path, text, password)` or small with `writeCompressed`; `config(path)` for settings and `writeData(value, path)` for a struct; paths with `join`, `dirName`, `fileName`, `stem`, `extension`, `validName`; the player's own with `choose(title, extensions)` and `dropped()`.";

const time_doc = "Dates, times and spans, written in the game's culture: `now()`, `date(year, month, day)`, `parse(text)`, `minutes(n)`, `locale()`, `setLocale(tag)`, and `clock(start, rate)` for a clock of the game's own.";

const web_doc = "The web, asked without the game waiting: `get(url)`, `post(url, body)`, `postForm(url, values)`, `request(method, url, headers, body)` - each a task to `await` for its `Response`, `catch` for what went wrong - and `download(url, path)` into a file under `user://`; `progress(task)`, `received(task)`, `cancel(task)`.";

const images_doc = "Pictures in memory: `new(width, height, color)`, `read(path)`, `capture()` of the frame, `fromTexture(texture)`; an image's `getPixel`, `setPixel`, `fill`, `fillRect`, `region`, `blit`, `blend`, `resize`, `flipX`, `flipY`, `savePng`, `saveJpg`; `toTexture(image)` draws it.";
