// SPDX-License-Identifier: BSD-3-Clause

//! Materials as files: a `.mat3d` is a `Material3D`'s fields, written as a
//! scene writes the component, and kept under a `MaterialHandle` - what a
//! mesh's surface and a `MeshInstance3D`'s `material_override` name.
//!
//! ```zig
//! const brick = try app.loadMaterial("res://materials/brick.mat3d");
//! app.world.get(wall, fx.MeshInstance3D).?.material_override = brick;
//! const glass = try app.addMaterial("glass", .{ .albedo_color = .hexa(0x9FD3FF55), .transparency = .alpha });
//! try app.saveMaterial(glass, "res://materials/glass.mat3d");
//! ```
//!
//! ```json
//! { "albedo_color": { "r": 0.8, "g": 0.4, "b": 0.3, "a": 1.0 }, "albedo_texture": "res://art/brick.png", "cull": "disabled" }
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
const Material3D = @import("render3d_components.zig").Material3D;
const scene_read = @import("../scene/scene_read.zig");
const scene_write = @import("../scene/scene_write.zig");

/// What a material's file ends in.
pub const extension = ".mat3d";

/// A material, the way a `TextureHandle` is a picture.
pub const MaterialHandle = file_table.Handle("MaterialHandle");

/// A material's file's text as a material. What it leaves out is what a
/// `Material3D` starts as.
pub fn read(app: *App, bytes: []const u8, diagnostics: ?*json.Diagnostics) !Material3D {
    var out: Material3D = .{};
    try scene_read.readValueText(app, Material3D, bytes, &out, diagnostics);
    return out;
}

/// A material as its file's text, the caller's: what it holds that is not
/// what a `Material3D` starts as.
pub fn write(app: *App, gpa: Allocator, material: Material3D) ![]u8 {
    return scene_write.writeValueText(app, gpa, Material3D, &material);
}

/// Every material read or made, under its handle.
pub const Materials = struct {
    table: Inner = .empty,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        source: []u8,
        on_disc: bool,
        material: Material3D,
    };

    fn toId(handle: MaterialHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) MaterialHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *Materials, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| gpa.free(entry.value.source);
        self.table.deinit(gpa);
        self.* = .{};
    }

    /// Keep `material` under `name`: a name given before gets the new one,
    /// and keeps its handle.
    pub fn add(self: *Materials, gpa: Allocator, name: []const u8, material: Material3D) Allocator.Error!MaterialHandle {
        return self.keep(gpa, name, material, false);
    }

    fn keep(self: *Materials, gpa: Allocator, name: []const u8, material: Material3D, on_disc: bool) Allocator.Error!MaterialHandle {
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.material = material;
            held.on_disc = on_disc;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .material = material }));
    }

    /// The material in the `.mat3d` file at `path`, read now unless it was
    /// read before.
    pub fn load(self: *Materials, app: *App, path: []const u8) !MaterialHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        const material = try readFile(app, source);
        if (Project.isProjectPath(source)) _ = app.project.uidOf(source) catch {};
        return self.keep(app.gpa, source, material, true);
    }

    fn readFile(app: *App, source: []const u8) !Material3D {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return read(app, bytes, null);
    }

    /// Read a material's file again. Says whether it had one.
    pub fn reload(self: *Materials, app: *App, handle: MaterialHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        held.material = try readFile(app, held.source);
        return true;
    }

    pub fn unload(self: *Materials, gpa: Allocator, handle: MaterialHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        gpa.free(held.source);
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
    pub fn get(self: *Materials, handle: MaterialHandle) ?*Material3D {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.material;
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
