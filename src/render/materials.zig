// SPDX-License-Identifier: BSD-3-Clause

//! Materials as files: a `.mat3d` is a `Material3DData`'s fields, written
//! as a scene writes a component, and its shader's numbers under `params`,
//! kept under a `MaterialHandle` - what a `Material3D` and a mesh's surface
//! name.
//!
//! ```zig
//! const brick = try app.loadMaterial("res://materials/brick.mat3d");
//! app.world.get(wall, fx.Material3D).?.material = brick;
//! const glass = try app.addMaterial("glass", .{ .albedo_color = .hexa(0x9FD3FF55), .transparency = .alpha });
//! try app.saveMaterial(glass, "res://materials/glass.mat3d");
//! ```
//!
//! ```json
//! { "albedo_color": { "r": 0.8, "g": 0.4, "b": 0.3, "a": 1.0 }, "shader": "res://shaders/waves.shader3d", "params": { "speed": 2 } }
//! ```
//!
//! A model's materials are kept the same way, named after the model:
//! `res://models/robot.glb#material/2`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const json = @import("fluxion_json");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const file_table = @import("../assets/file_table.zig");
const Material3DData = @import("render3d_components.zig").Material3DData;
const scene_read = @import("../scene/scene_read.zig");
const scene_write = @import("../scene/scene_write.zig");
const shaders = @import("shaders.zig");

/// What a material's file ends in.
pub const extension = ".mat3d";

/// A material, the way a `TextureHandle` is a picture.
pub const MaterialHandle = file_table.Handle("MaterialHandle");

/// What a material's file holds: the material, and its shader's numbers -
/// whose names are the caller's to free with `shaders.freeParams`.
pub const Read = struct {
    material: Material3DData,
    params: shaders.ParamList,
};

/// A material's file's text as a material. What it leaves out is what a
/// `Material3DData` starts as.
pub fn read(app: *App, bytes: []const u8, diagnostics: ?*json.Diagnostics) !Read {
    var out: Read = .{ .material = .{}, .params = .empty };
    errdefer shaders.freeParams(app.gpa, &out.params);
    try scene_read.readValueTextKeeping(app, Material3DData, bytes, &out.material, diagnostics, &out.params);
    return out;
}

/// A material as its file's text, the caller's: what it holds that is not
/// what a `Material3DData` starts as, and the numbers it gives its shader.
pub fn write(app: *App, gpa: Allocator, material: Material3DData, params: []const shaders.Param) ![]u8 {
    return scene_write.writeValueTextWith(app, gpa, Material3DData, &material, params);
}

/// Every material read or made, under its handle.
pub const Materials = struct {
    table: Inner = .empty,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        source: []u8,
        on_disc: bool,
        material: Material3DData,
        /// Its shader's numbers: what each mesh drawn with it gives the
        /// shader, unless the mesh's entity gives its own.
        params: shaders.ParamList = .empty,
    };

    fn toId(handle: MaterialHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) MaterialHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *Materials, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value.source);
            shaders.freeParams(gpa, &entry.value.params);
        }
        self.table.deinit(gpa);
        self.* = .{};
    }

    /// Keep `material` under `name`: a name given before gets the new one,
    /// and keeps its handle.
    pub fn add(self: *Materials, gpa: Allocator, name: []const u8, material: Material3DData) Allocator.Error!MaterialHandle {
        return self.keep(gpa, name, .{ .material = material, .params = .empty }, false);
    }

    /// Keep what was read, its numbers' names now the table's.
    fn keep(self: *Materials, gpa: Allocator, name: []const u8, made: Read, on_disc: bool) Allocator.Error!MaterialHandle {
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.material = made.material;
            shaders.freeParams(gpa, &held.params);
            held.params = made.params;
            held.on_disc = on_disc;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .material = made.material, .params = made.params }));
    }

    /// The material in the `.mat3d` file at `path`, read now unless it was
    /// read before.
    pub fn load(self: *Materials, app: *App, path: []const u8) !MaterialHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        var made = try readFile(app, source);
        errdefer shaders.freeParams(app.gpa, &made.params);
        if (Project.isProjectPath(source)) _ = app.project.uidOf(source) catch {};
        return self.keep(app.gpa, source, made, true);
    }

    fn readFile(app: *App, source: []const u8) !Read {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return read(app, bytes, null);
    }

    /// Read a material's file again. Says whether it had one.
    pub fn reload(self: *Materials, app: *App, handle: MaterialHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const made = try readFile(app, held.source);
        held.material = made.material;
        shaders.freeParams(app.gpa, &held.params);
        held.params = made.params;
        return true;
    }

    pub fn unload(self: *Materials, gpa: Allocator, handle: MaterialHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        gpa.free(held.source);
        shaders.freeParams(gpa, &held.params);
        _ = self.table.remove(toId(handle));
    }

    pub fn find(self: *Materials, source: []const u8) ?MaterialHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *Materials, handle: MaterialHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    /// The material itself, to read or to change: what draws with it draws
    /// the change from the next frame.
    pub fn get(self: *Materials, handle: MaterialHandle) ?*Material3DData {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.material;
    }

    /// The numbers a material gives its shader: none for none.
    pub fn params(self: *Materials, handle: MaterialHandle) []const shaders.Param {
        const held = self.table.get(toId(handle)) orelse return &.{};
        return held.params.items;
    }

    /// Give a material's shader's field `name` `numbers`, or, for none,
    /// what the shader's file says again: every mesh drawn with it the
    /// next frame.
    pub fn setParam(self: *Materials, gpa: Allocator, handle: MaterialHandle, name: []const u8, numbers: []const f32) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchMaterial;
        try shaders.setIn(gpa, &held.params, name, numbers);
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Materials, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};
