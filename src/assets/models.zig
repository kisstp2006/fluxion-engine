// SPDX-License-Identifier: BSD-3-Clause

//! A model file is a scene: `app.loadScene("res://models/robot.glb")` - or
//! `app.instantiate` with it, or a scene that has one as an instance - gives
//! the tree its nodes make, each a `Transform3D` with a `MeshInstance3D`, a
//! `Camera3D` or a `DirectionalLight3D` as the node has, under a root named
//! after the file.
//!
//! ```zig
//! const robot = try app.loadScene("res://models/robot.glb");
//! const one = try app.instantiate(robot, level);
//! ```
//!
//! What it is made of is kept under its name with what it is after a `#`:
//! `res://models/robot.glb#mesh/0`, `#material/2`, `#image/1`. A scene or a
//! script can name one of those as any file - the model is read first.
//!
//! - **glTF 2.0** - `.glb`, or `.gltf` with its files beside it - is read
//!   as it is: see `assets/gltf.zig`.
//! - **FBX and Blender files** are turned into glTF by an editor, with the
//!   Blender it finds on the machine, into the project's
//!   `.fluxion/imported/` folder; a game reads that. One no editor has
//!   turned is `error.NotImported`.
//! - **`<file>.import`** beside the model says how it is brought in:
//!   `{ "scale": 0.01 }` for a model made in centimetres.
//!
//! A model read in the background (`App.loadInBackground`) has its meshes
//! made and its pictures decoded on the loading threads, each on its own;
//! see `assets/background_load.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const math = @import("fluxion_math");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const file_table = @import("file_table.zig");
const gltf = @import("gltf.zig");
const mesh = @import("../render/mesh.zig");
const SceneHandle = @import("scene_table.zig").SceneHandle;
const MaterialHandle = @import("../render/materials.zig").MaterialHandle;
const TextureHandle = @import("assets.zig").TextureHandle;

const log = std.log.scoped(.fluxion_engine);

/// The endings of the files a model is read from.
pub const extensions = [_][]const u8{ ".glb", ".gltf", ".fbx", ".blend" };

/// What a file of a model's import settings ends in, beside the model.
pub const import_extension = ".import";

/// Where an editor puts the glTF it made of an FBX or a Blender file: the
/// model's own path under it, with `.glb` after.
pub const imported_folder = "res://.fluxion/imported/";

/// Whether the file at `path` is a model.
pub fn isModel(path: []const u8) bool {
    const ending = std.fs.path.extension(path);
    for (extensions) |known| if (std.ascii.eqlIgnoreCase(ending, known)) return true;
    return false;
}

/// Whether a model is one an editor turns into glTF first.
pub fn isConverted(path: []const u8) bool {
    const ending = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ending, ".fbx") or std.ascii.eqlIgnoreCase(ending, ".blend");
}

/// The model a part's name is of - `res://robot.glb` of
/// `res://robot.glb#mesh/0` - or null for a name that is not a part's.
pub fn baseOf(path: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, path, '#') orelse return null;
    const base = path[0..hash];
    return if (isModel(base)) base else null;
}

/// The glTF an editor made of the converted model at `source` - a
/// `res://` path - the caller's.
pub fn importedPath(gpa: Allocator, source: []const u8) Allocator.Error![]u8 {
    const inside = if (std.mem.startsWith(u8, source, Project.scheme)) source[Project.scheme.len..] else source;
    return std.mem.concat(gpa, u8, &.{ imported_folder, inside, ".glb" });
}

/// What the file a model's glTF is read from is: the model's own, or what
/// an editor made of it. The caller's.
pub fn readablePath(gpa: Allocator, source: []const u8) Allocator.Error![]u8 {
    return if (isConverted(source)) importedPath(gpa, source) else gpa.dupe(u8, source);
}

/// How a model is brought in, as `<model>.import` says.
pub const ImportSettings = struct {
    /// What its size is multiplied by: 0.01 for one made in centimetres.
    scale: f32 = 1,
};

/// A model's import settings, or what they start as when it has none or
/// they do not read.
pub fn settingsOf(gpa: Allocator, files: Project.Files, file: []const u8) ImportSettings {
    const path = std.mem.concat(gpa, u8, &.{ file, import_extension }) catch return .{};
    defer gpa.free(path);
    const bytes = files.read(gpa, path, .limited(64 * 1024)) catch return .{};
    defer gpa.free(bytes);
    const parsed = json.parseAs(ImportSettings, gpa, bytes, .{ .syntax = .json5 }) catch |err| {
        log.warn("{s} does not read, and the model is brought in as it is: {t}", .{ path, err });
        return .{};
    };
    defer parsed.deinit();
    return parsed.value;
}

/// Reads the files a `.gltf` names, beside it.
pub const Beside = struct {
    files: Project.Files,
    /// The folder of the file the model was read from, as `files` reads it.
    folder: []const u8,

    pub fn fetch(self: *Beside) gltf.Fetch {
        return .{ .context = self, .read = read };
    }

    fn read(context: *anyopaque, gpa: Allocator, uri: []const u8) anyerror![]u8 {
        const self: *Beside = @ptrCast(@alignCast(context));
        const path = try std.mem.concat(gpa, u8, &.{ self.folder, "/", uri });
        defer gpa.free(path);
        return self.files.read(gpa, path, .limited(file_table.file_limit));
    }
};

/// The folder part of a path, slashes either way.
pub fn folderOf(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return ".";
    return path[0..at];
}

/// A model read on any thread: what is left is for the game's own.
pub const Prepared = struct {
    model: gltf.Model,
    settings: ImportSettings,

    pub fn deinit(self: *Prepared) void {
        self.model.deinit();
    }
};

/// Read and make all of the model at `file` - the system's path, or a
/// pack's - on this thread.
pub fn prepare(gpa: Allocator, files: Project.Files, file: []const u8) !Prepared {
    const bytes = try files.read(gpa, file, .limited(file_table.file_limit));
    defer gpa.free(bytes);
    var beside: Beside = .{ .files = files, .folder = folderOf(file) };
    return .{ .model = try gltf.read(gpa, bytes, beside.fetch()), .settings = settingsOf(gpa, files, file) };
}

/// Read the model at `path` now, on this thread, and keep what it made: its
/// scene's handle. One read before is found.
pub fn load(app: *App, path: []const u8) !SceneHandle {
    if (app.scenes.find(path)) |known| return known;
    const source = try app.project.canonical(app.gpa, path);
    defer app.gpa.free(source);
    if (app.scenes.find(source)) |known| return known;
    var prepared = try prepareAt(app, source);
    defer prepared.deinit();
    return take(app, source, &prepared);
}

/// Read a model's file again, and make its meshes, materials, pictures and
/// scene anew under the same names: what draws them draws the new ones.
pub fn reload(app: *App, source: []const u8) !void {
    var prepared = try prepareAt(app, source);
    defer prepared.deinit();
    _ = try take(app, source, &prepared);
}

fn prepareAt(app: *App, source: []const u8) !Prepared {
    const readable = try readablePath(app.gpa, source);
    defer app.gpa.free(readable);
    const file = if (app.project.pack != null and Project.isProjectPath(readable))
        try app.gpa.dupe(u8, readable)
    else
        try app.project.osPath(app.gpa, readable);
    defer app.gpa.free(file);
    return prepare(app.gpa, app.project.files(), file) catch |err| switch (err) {
        error.FileNotFound => if (isConverted(source)) error.NotImported else err,
        else => err,
    };
}

/// Make what a prepared model holds the app's - its pictures textures, its
/// materials and meshes kept under their names - and keep the scene of its
/// nodes under `source`: what `instantiate` takes.
pub fn take(app: *App, source: []const u8, prepared: *Prepared) !SceneHandle {
    const gpa = app.gpa;
    const model = &prepared.model;
    for (model.notes.items) |note| log.warn("{s}: {s}", .{ source, note });

    // The pictures, filtered as the first texture that uses each says.
    const nearest = try gpa.alloc(bool, model.images.len);
    defer gpa.free(nearest);
    @memset(nearest, false);
    for (model.materials) |material| {
        for ([_]?gltf.TextureRef{ material.albedo, material.emission }) |held| if (held) |ref| {
            nearest[ref.image] = ref.nearest;
        };
    }
    const pictures = try gpa.alloc(TextureHandle, model.images.len);
    defer gpa.free(pictures);
    for (model.images, pictures, 0..) |picture, *out, at| {
        out.* = .none;
        if (!picture.decoded) {
            if (picture.bytes.len > 0) log.warn("{s}: the picture {s} is not a PNG or a JPEG, and is left out", .{ source, picture.name });
            continue;
        }
        var name: [512]u8 = undefined;
        const named = try std.fmt.bufPrint(&name, "{s}#image/{d}", .{ source, at });
        if (app.assets.findTexture(named)) |held| {
            try app.assets.setTexturePixels(held, picture.width, picture.height, picture.pixels);
            out.* = held;
        } else {
            out.* = try app.assets.adoptTexture(named, picture.width, picture.height, picture.pixels, .{ .filter = if (nearest[at]) .nearest else .linear, .wrap = .repeat });
        }
    }

    const materials = try gpa.alloc(MaterialHandle, model.materials.len);
    defer gpa.free(materials);
    for (model.materials, materials, 0..) |material, *out, at| {
        var look = material.look;
        if (material.albedo) |ref| look.albedo_texture = pictures[ref.image];
        if (material.emission) |ref| look.emission_texture = pictures[ref.image];
        var name: [512]u8 = undefined;
        out.* = try app.materials.add(gpa, try std.fmt.bufPrint(&name, "{s}#material/{d}", .{ source, at }), look);
    }

    // Made on a loading thread, the meshes' memory is that thread's
    // allocator's: copied into the app's, which lets them go.
    const same = model.gpa.ptr == gpa.ptr and model.gpa.vtable == gpa.vtable;
    for (model.meshes, 0..) |*held, at| {
        if (!held.built) try gltf.buildMesh(model, at);
        const vertices, const indices, const surfaces = if (same) held.take() else .{
            try gpa.dupe(mesh.Vertex, held.vertices),
            try gpa.dupe(u32, held.indices),
            try gpa.dupe(mesh.Surface, held.surfaces),
        };
        for (surfaces, held.materials) |*surface, material| {
            surface.material = if (material) |m| materials[m] else .none;
        }
        const made = mesh.Mesh.adopt(vertices, indices, surfaces) catch |err| {
            gpa.free(vertices);
            gpa.free(indices);
            gpa.free(surfaces);
            return err;
        };
        var name: [512]u8 = undefined;
        _ = try app.meshes.add(gpa, &app.device, try std.fmt.bufPrint(&name, "{s}#mesh/{d}", .{ source, at }), made);
    }

    const text = try sceneText(gpa, source, prepared);
    defer gpa.free(text);
    return app.scenes.add(gpa, source, text);
}

/// What every UUID of a model's scene is made from, with the model's path
/// and the node's place: the same each time it is read, so what an instance
/// of it changes stays with the node it changed.
const namespace: Uuid = .parseComptime("6f1d0c52-8a4e-4b3a-9d2e-3c7b9a6e5f10");

fn uuidOf(source: []const u8, node: ?usize) [36]u8 {
    var name: [600]u8 = undefined;
    const text = if (node) |at|
        std.fmt.bufPrint(&name, "{s}#node/{d}", .{ source, at }) catch source
    else
        std.fmt.bufPrint(&name, "{s}#root", .{source}) catch source;
    return Uuid.fromName(namespace, text).toString();
}

/// The scene a model's nodes make, as a scene file says it.
fn sceneText(gpa: Allocator, source: []const u8, prepared: *const Prepared) ![]u8 {
    return json.stringify(gpa, ModelScene{ .source = source, .prepared = prepared }, .{ .indent = 2 });
}

const ModelScene = struct {
    source: []const u8,
    prepared: *const Prepared,

    pub fn toJson(self: ModelScene, w: *json.Writer) json.Writer.Error!void {
        const model = &self.prepared.model;
        const stem = std.fs.path.stem(if (std.mem.lastIndexOfScalar(u8, self.source, '/')) |at| self.source[at + 1 ..] else self.source);
        const root = uuidOf(self.source, null);
        try w.beginObject();
        try w.field("fluxion_scene", @as(u32, 3));
        try w.key("entities");
        try w.beginArray();
        try w.beginObject();
        try w.field("uuid", @as([]const u8, &root));
        try w.field("name", stem);
        const scale = self.prepared.settings.scale;
        try w.key("Transform3D");
        try w.beginObject();
        if (scale != 1) try vector(w, "scale", .{ scale, scale, scale });
        try w.endObject();
        try w.endObject();
        // Each node once, under the node that has it - the first that does,
        // where a broken file has two - from the shown scene's roots down.
        const placed = std.heap.page_allocator.alloc(bool, model.nodes.len) catch return error.WriteFailed;
        defer std.heap.page_allocator.free(placed);
        @memset(placed, false);
        for (model.roots) |at| try self.node(w, at, &root, placed);
        try w.endArray();
        try w.endObject();
    }

    fn node(self: ModelScene, w: *json.Writer, at: u32, parent: []const u8, placed: []bool) json.Writer.Error!void {
        if (placed[at]) return;
        placed[at] = true;
        const model = &self.prepared.model;
        const held = model.nodes[at];
        const uuid = uuidOf(self.source, at);
        try w.beginObject();
        try w.field("uuid", @as([]const u8, &uuid));
        try w.field("parent", parent);
        try w.field("name", held.name);
        const t = held.transform;
        try w.key("Transform3D");
        try w.beginObject();
        try vector(w, "position", t.translation.array());
        try w.key("rotation");
        try w.beginObject();
        try w.field("x", t.rotation.x);
        try w.field("y", t.rotation.y);
        try w.field("z", t.rotation.z);
        try w.field("w", t.rotation.w);
        try w.endObject();
        try vector(w, "scale", t.scale.array());
        try w.endObject();
        if (held.mesh) |m| {
            var name: [512]u8 = undefined;
            try w.key("MeshInstance3D");
            try w.beginObject();
            try w.field("mesh", std.fmt.bufPrint(&name, "{s}#mesh/{d}", .{ self.source, m }) catch "");
            try w.endObject();
        }
        if (held.camera) |c| {
            const camera = model.cameras[c];
            try w.key("Camera3D");
            try w.beginObject();
            if (camera.orthogonal) {
                try w.field("projection", "orthogonal");
                try w.field("size", camera.size);
            } else try w.field("fov", camera.fov);
            try w.field("near", camera.near);
            try w.field("far", camera.far);
            try w.endObject();
        }
        if (held.light) |l| {
            const light = model.lights[l];
            if (light.kind == .directional) {
                try w.key("DirectionalLight3D");
                try w.beginObject();
                try w.key("color");
                try w.beginObject();
                try w.field("r", light.color.r);
                try w.field("g", light.color.g);
                try w.field("b", light.color.b);
                try w.field("a", @as(f32, 1));
                try w.endObject();
                try w.field("energy", @min(light.intensity, 16));
                try w.endObject();
            } else log.info("{s}: the {t} light {s} is kept as a place: the engine draws only directional lights so far", .{ self.source, light.kind, held.name });
        }
        try w.endObject();
        for (held.children) |child| try self.node(w, child, &uuid, placed);
    }

    fn vector(w: *json.Writer, name: []const u8, v: [3]f32) json.Writer.Error!void {
        try w.key(name);
        try w.beginObject();
        try w.field("x", v[0]);
        try w.field("y", v[1]);
        try w.field("z", v[2]);
        try w.endObject();
    }
};

test "a part's name is of its model, and a converted model is read from what was made of it" {
    try testing.expectEqualStrings("res://m/robot.glb", baseOf("res://m/robot.glb#mesh/2").?);
    try testing.expect(baseOf("res://art/hero.png") == null);
    try testing.expect(baseOf("res://notes#1.txt") == null);
    try testing.expect(isModel("res://m/ROBOT.GLB"));
    try testing.expect(isConverted("res://m/house.blend"));
    const made = try readablePath(testing.allocator, "res://m/house.fbx");
    defer testing.allocator.free(made);
    try testing.expectEqualStrings("res://.fluxion/imported/m/house.fbx.glb", made);
}
