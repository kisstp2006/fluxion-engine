// SPDX-License-Identifier: BSD-3-Clause

//! A model file is a scene: `app.loadScene("res://models/robot.glb")` - or
//! `app.instantiate` with it, or a scene that has one as an instance - gives
//! the tree its nodes make, each a `Transform3D` with a `MeshInstance3D`, a
//! `Camera3D`, a `DirectionalLight3D`, a `PointLight3D` or a `SpotLight3D`
//! as the node has, under a root named after the file.
//!
//! ```zig
//! const robot = try app.loadScene("res://models/robot.glb");
//! const one = try app.instantiate(robot, level);
//! ```
//!
//! What it is made of is kept under its name with what it is after a `#`:
//! `res://models/robot.glb#mesh/0`, `#material/2`, `#image/1`,
//! `#skeleton/0`, `#animations`. A scene or a script can name one of those
//! as any file - the model is read first.
//!
//! **A skin** is a `Skeleton` - its bones are not entities - on the entity
//! of the node its top bones hang from (the model's root where they hang
//! from none), as a `Skeleton3D`; the node whose mesh it bends gets a
//! `MeshInstance3D` whose `skeleton` names that entity. What hangs from a
//! bone in the file is put under an entity named after the bone, with a
//! `BoneAttachment3D`, under the skeleton's entity.
//!
//! **Its animations** are one library, `#animations`, which an
//! `AnimationPlayer` on the model's root plays: a bone's channel a track of
//! the bone on its skeleton's entity, any other node's a track of its
//! entity's `Transform3D`. A cubic spline is turned into straight keys,
//! thirty a second; a step's track jumps from key to key. A bone hung from
//! its parent bone through nodes that are not bones - folded into its place
//! at rest - is baked with them: its place through them at each of their
//! keys and its, and thirty times a second between. One whose name
//! ends in `loop` goes round and round, and with `"loop_animations": true`
//! in the `.import` file every one does.
//!
//! - **glTF 2.0** - `.glb`, or `.gltf` with its files beside it - is read
//!   as it is: see `assets/gltf.zig`.
//! - **FBX and Blender files** are turned into glTF by an editor, with the
//!   Blender it finds on the machine, into the project's
//!   `.fluxion/imported/` folder; a game reads that. One no editor has
//!   turned is `error.NotImported`.
//! - **`<file>.import`** beside the model says how it is brought in:
//!   `{ "scale": 0.01 }` for a model made in centimetres, and
//!   `"lightmap_uvs": true` for one a lightmap lights that brings no second
//!   coordinates of its own: they are worked out as it is read.
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
const skeleton_table = @import("../render/skeleton.zig");
const animation = @import("../animation/animation.zig");
const Value = @import("../reflect/property.zig").Value;

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
    /// Whether its meshes that bring no lightmap UVs get them worked out,
    /// for a lightmap to light them.
    lightmap_uvs: bool = false,
    /// Whether every one of its animations goes round and round, not only
    /// one whose name ends in `loop`.
    loop_animations: bool = false,
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
    const settings = settingsOf(gpa, files, file);
    var model = try gltf.parse(gpa, bytes, beside.fetch());
    errdefer model.deinit();
    model.unwrap_lightmap = settings.lightmap_uvs;
    try gltf.finish(&model);
    return .{ .model = model, .settings = settings };
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
        for (material.pictures()) |held| if (held) |ref| {
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
            out.* = try app.assets.adoptTexture(named, picture.width, picture.height, picture.pixels, .{ .filter = if (nearest[at]) .nearest else .linear, .wrap = .repeat, .mips = true });
        }
    }

    const materials = try gpa.alloc(MaterialHandle, model.materials.len);
    defer gpa.free(materials);
    for (model.materials, materials, 0..) |material, *out, at| {
        var look = material.look;
        // Read as the file says its colour picture is: texel by texel, or
        // smoothly.
        if (material.albedo) |ref| {
            look.albedo_texture = pictures[ref.image];
            if (ref.nearest) look.texture_filter = .nearest;
        }
        if (material.emission) |ref| look.emission_texture = pictures[ref.image];
        if (material.metallic_roughness) |ref| look.metallic_roughness_texture = pictures[ref.image];
        if (material.normal) |ref| look.normal_texture = pictures[ref.image];
        if (material.occlusion) |ref| look.occlusion_texture = pictures[ref.image];
        var name: [512]u8 = undefined;
        out.* = try app.materials.add(gpa, try std.fmt.bufPrint(&name, "{s}#material/{d}", .{ source, at }), look);
    }

    // Made on a loading thread, the meshes' memory is that thread's
    // allocator's: copied into the app's, which lets them go.
    const same = model.gpa.ptr == gpa.ptr and model.gpa.vtable == gpa.vtable;
    for (model.meshes, 0..) |*held, at| {
        if (!held.built) try gltf.buildMesh(model, at);
        const vertices, const indices, const surfaces, const skin = if (same) held.take() else .{
            try gpa.dupe(mesh.Vertex, held.vertices),
            try gpa.dupe(u32, held.indices),
            try gpa.dupe(mesh.Surface, held.surfaces),
            try gpa.dupe(mesh.SkinVertex, held.skin),
        };
        for (surfaces, held.materials) |*surface, material| {
            surface.material = if (material) |m| materials[m] else .none;
        }
        var made = mesh.Mesh.adopt(vertices, indices, surfaces) catch |err| {
            gpa.free(vertices);
            gpa.free(indices);
            gpa.free(surfaces);
            gpa.free(skin);
            return err;
        };
        made.uv2_texels = held.uv2_texels;
        // Bent by the skin of the first node that draws it with one, its
        // bones' boxes in that skin's bones' spaces; drawn as it was made
        // where no node does.
        if (skinOf(model, at)) |bending| {
            made.skin = skin;
            made.bone_bounds = mesh.boneBounds(gpa, vertices, skin, bending.inverse_binds) catch |err| {
                made.deinit(gpa);
                return err;
            };
        } else gpa.free(skin);
        var name: [512]u8 = undefined;
        _ = try app.meshes.add(gpa, &app.device, try std.fmt.bufPrint(&name, "{s}#mesh/{d}", .{ source, at }), made);
    }

    // Each skin a skeleton of its bones, in its order.
    const parents = try parentsOf(gpa, model);
    defer gpa.free(parents);
    for (model.skins, 0..) |skin, at| {
        if (skin.joints.len == 0) continue;
        var made = try skeletonOf(gpa, model, parents, skin);
        errdefer made.deinit(gpa);
        var name: [512]u8 = undefined;
        _ = try app.skeletons.add(gpa, try std.fmt.bufPrint(&name, "{s}#skeleton/{d}", .{ source, at }), made);
    }

    // Its animations, one library: what its root's player plays.
    if (model.animations.len > 0) {
        var made: animation.Library = .{ .source = &.{}, .on_disc = false };
        defer made.deinitContent(gpa);
        try animationsOf(gpa, model, parents, prepared.settings, &made);
        var name: [512]u8 = undefined;
        _ = try app.animation_libraries.adopt(gpa, try std.fmt.bufPrint(&name, "{s}#animations", .{source}), &made.animations);
    }

    const text = try sceneText(gpa, source, prepared);
    defer gpa.free(text);
    return app.scenes.add(gpa, source, text);
}

/// Each node's parent, the first that lists it; none for a root.
fn parentsOf(gpa: Allocator, model: *const gltf.Model) Allocator.Error![]?u32 {
    const out = try gpa.alloc(?u32, model.nodes.len);
    @memset(out, null);
    for (model.nodes, 0..) |node, at| for (node.children) |child| {
        if (out[child] == null) out[child] = @intCast(at);
    };
    return out;
}

/// The place of `node` in `skin`'s bones, if it is one.
fn jointIndex(skin: gltf.Skin, node: u32) ?u16 {
    for (skin.joints, 0..) |joint, at| if (joint == node) return @intCast(at);
    return null;
}

/// The node `skin`'s skeleton is on: the one its first top bone hangs from,
/// or none - the model's root - where it hangs from none.
fn skeletonNode(skin: gltf.Skin, parents: []const ?u32) ?u32 {
    for (skin.joints) |joint| {
        var up = parents[joint];
        var top = true;
        while (up) |node| : (up = parents[node]) {
            if (jointIndex(skin, node) != null) {
                top = false;
                break;
            }
        }
        if (top) return parents[joint];
    }
    return null;
}

/// Where `node` is from `from` - one of its ancestors, or the scene's root
/// for none - each node's own place, turn and size on the way down.
fn placeFrom(model: *const gltf.Model, parents: []const ?u32, from: ?u32, node: u32) math.Mat4 {
    var out = model.nodes[node].transform.toMat4();
    var up = parents[node];
    while (up) |at| : (up = parents[at]) {
        if (from != null and at == from.?) break;
        out = model.nodes[at].transform.toMat4().mul(out);
    }
    return out;
}

/// `skin`'s bones as a skeleton: each one's parent the nearest bone above it,
/// and its place at rest from there - from the skeleton's node for a bone at
/// the top.
fn skeletonOf(gpa: Allocator, model: *const gltf.Model, parents: []const ?u32, skin: gltf.Skin) !skeleton_table.Skeleton {
    const owner = skeletonNode(skin, parents);
    const bones = try gpa.alloc(skeleton_table.Bone, skin.joints.len);
    defer gpa.free(bones);
    for (skin.joints, bones, 0..) |joint, *bone, at| {
        var parent: ?u16 = null;
        var from: ?u32 = owner;
        var up = parents[joint];
        while (up) |node| : (up = parents[node]) {
            if (jointIndex(skin, node)) |found| {
                parent = found;
                from = node;
                break;
            }
            if (owner != null and node == owner.?) break;
        }
        // A node between two bones, or between the skeleton and its top
        // bone, is folded into the bone's place.
        const local = if (parent == null and owner == null) placeFrom(model, parents, null, joint) else placeFrom(model, parents, from, joint);
        bone.* = .{
            .name = model.nodes[joint].name,
            .parent = parent,
            .rest = .fromMat4(local),
            .inverse_bind = skin.inverse_binds[at],
        };
    }
    return skeleton_table.Skeleton.init(gpa, bones);
}

/// The model's animations into `into`, each channel a track: of a bone on
/// its skeleton's entity, or of a node's entity's `Transform3D`.
fn animationsOf(gpa: Allocator, model: *const gltf.Model, parents: []const ?u32, settings: ImportSettings, into: *animation.Library) !void {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    var between: std.ArrayList(u32) = .empty;
    defer between.deinit(gpa);
    for (model.animations, 0..) |given, at| {
        // Cut to what a player holds, and made unlike the others.
        var name_buffer: [animation.name_len]u8 = undefined;
        var name = cutTo(given.name, animation.name_len);
        if (into.find(name) != null) name = std.fmt.bufPrint(&name_buffer, "{s} {d}", .{ cutTo(given.name, animation.name_len - 8), at }) catch name;
        const made = try into.addAnimation(gpa, name);
        made.length = given.length;
        const looped = settings.loop_animations or std.ascii.endsWithIgnoreCase(name, "loop");
        made.loop = if (looped) .repeat else .none;
        for (given.channels) |channel| {
            const track = if (boneSkin(model, channel.node)) |skin| bone: {
                // A bone under nodes that are not bones is baked, below,
                // with theirs.
                if (try betweenBones(gpa, model, parents, skin, channel.node, &between) > 0) continue;
                try entityPath(gpa, model, parents, skeletonNode(model.skins[skin], parents), &path);
                break :bone try made.ensureBoneTrack(gpa, path.items, model.nodes[channel.node].name, @tagName(boneChannel(channel.path)));
            } else node: {
                try entityPath(gpa, model, parents, channel.node, &path);
                break :node try made.ensureTrack(gpa, path.items, switch (channel.path) {
                    .translation => "Transform3D.position",
                    .rotation => "Transform3D.rotation",
                    .scale => "Transform3D.scale",
                });
            };
            track.update = if (channel.interpolation == .step) .discrete else .continuous;
            track.keys.clearRetainingCapacity();
            try keysOf(gpa, channel, &track.keys);
        }
        // Each bone hung from its parent bone through nodes that are not
        // bones, that it or they move: its place from its parent each time
        // they and it are, through them.
        for (model.skins, 0..) |skin, skin_at| for (skin.joints) |joint| {
            if (boneSkin(model, joint).? != skin_at) continue;
            if (try betweenBones(gpa, model, parents, @intCast(skin_at), joint, &between) == 0) continue;
            if (!movesAny(given, joint, between.items)) continue;
            try entityPath(gpa, model, parents, skeletonNode(skin, parents), &path);
            try bakeBone(gpa, made, path.items, model, given, joint, between.items);
        };
    }
}

/// The nodes between `joint` and the bone - or the skeleton's node - its
/// place is from, into `into`, the one nearest the top first: what is
/// folded into its place. How many.
fn betweenBones(gpa: Allocator, model: *const gltf.Model, parents: []const ?u32, skin_at: u32, joint: u32, into: *std.ArrayList(u32)) !usize {
    into.clearRetainingCapacity();
    const skin = model.skins[skin_at];
    const owner = skeletonNode(skin, parents);
    var up = parents[joint];
    while (up) |node| : (up = parents[node]) {
        if (jointIndex(skin, node) != null) break;
        if (owner != null and node == owner.?) break;
        // No deeper than the nodes are many, should a broken file go round.
        if (into.items.len > model.nodes.len) break;
        try into.append(gpa, node);
    }
    std.mem.reverse(u32, into.items);
    return into.items.len;
}

/// Whether `given` moves `joint` or one of `nodes`.
fn movesAny(given: gltf.Animation, joint: u32, nodes: []const u32) bool {
    for (given.channels) |channel| {
        if (channel.node == joint) return true;
        for (nodes) |node| if (channel.node == node) return true;
    }
    return false;
}

/// `joint`'s place from its parent bone through `nodes` each time `given`
/// moves it or them, and thirty times a second between, as three tracks
/// of the bone.
fn bakeBone(gpa: Allocator, made: *animation.Animation, target: []const u8, model: *const gltf.Model, given: gltf.Animation, joint: u32, nodes: []const u32) !void {
    var times: std.ArrayList(f32) = .empty;
    defer times.deinit(gpa);
    for (given.channels) |channel| {
        const moved = channel.node == joint or for (nodes) |node| {
            if (channel.node == node) break true;
        } else false;
        if (moved) try times.appendSlice(gpa, channel.times);
    }
    if (times.items.len == 0) return;
    std.mem.sort(f32, times.items, {}, std.sort.asc(f32));
    const first = times.items[0];
    const last = times.items[times.items.len - 1];
    const steps: usize = @intFromFloat(@ceil((last - first) * 30));
    for (1..steps) |step| try times.append(gpa, first + (last - first) * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps)));
    std.mem.sort(f32, times.items, {}, std.sort.asc(f32));

    const name = model.nodes[joint].name;
    const position = try made.ensureBoneTrack(gpa, target, name, "position");
    position.keys.clearRetainingCapacity();
    const rotation = try made.ensureBoneTrack(gpa, target, name, "rotation");
    rotation.keys.clearRetainingCapacity();
    const scale = try made.ensureBoneTrack(gpa, target, name, "scale");
    scale.keys.clearRetainingCapacity();
    var previous: ?f32 = null;
    for (times.items) |time| {
        if (previous) |was| if (time - was < animation.same_time) continue;
        previous = time;
        var place = math.Mat4.identity;
        for (nodes) |node| place = place.mul(nodeAt(model, given, node, time).toMat4());
        const placed = math.Transform.fromMat4(place.mul(nodeAt(model, given, joint, time).toMat4()));
        try position.keys.append(gpa, .{ .time = time, .value = .{ .vec3 = placed.translation.array() } });
        try rotation.keys.append(gpa, .{ .time = time, .value = .{ .quat = .{ placed.rotation.x, placed.rotation.y, placed.rotation.z, placed.rotation.w } } });
        try scale.keys.append(gpa, .{ .time = time, .value = .{ .vec3 = placed.scale.array() } });
    }
}

/// `node`'s place, turn and size `time` seconds into `given`: its own where
/// no channel moves them.
fn nodeAt(model: *const gltf.Model, given: gltf.Animation, node: u32, time: f32) math.Transform {
    var out = model.nodes[node].transform;
    for (given.channels) |channel| {
        if (channel.node != node) continue;
        const value = sampleChannel(channel, time);
        switch (channel.path) {
            .translation => out.translation = .init(value[0], value[1], value[2]),
            .rotation => out.rotation = (math.Quat{ .x = value[0], .y = value[1], .z = value[2], .w = value[3] }).norm(),
            .scale => out.scale = .init(value[0], value[1], value[2]),
        }
    }
    return out;
}

/// What a channel says `time` seconds in, as glTF says it is read: held
/// before its first key and after its last, and between two the way its
/// interpolation goes.
fn sampleChannel(channel: gltf.Channel, time: f32) [4]f32 {
    const width = channel.width();
    const times = channel.times;
    const per_key: usize = if (channel.interpolation == .cubic) 3 else 1;
    // Where a key's value is among the numbers: after its tangent in, on a
    // cubic spline.
    const value_at = if (channel.interpolation == .cubic) width else 0;
    var out: [4]f32 = .{ 0, 0, 0, 1 };
    if (times.len == 0) return out;
    const OrderOf = struct {
        fn order(at: f32, key: f32) std.math.Order {
            return std.math.order(at, key);
        }
    };
    const after = std.sort.upperBound(f32, times, time, OrderOf.order);
    if (after == 0 or after >= times.len) {
        const key = if (after == 0) 0 else times.len - 1;
        @memcpy(out[0..width], channel.values[key * per_key * width + value_at ..][0..width]);
        return out;
    }
    const before = after - 1;
    const here = channel.values[before * per_key * width ..][0 .. per_key * width];
    const next = channel.values[after * per_key * width ..][0 .. per_key * width];
    const span = times[after] - times[before];
    const t: f32 = if (span > 0) (time - times[before]) / span else 1;
    switch (channel.interpolation) {
        .step => @memcpy(out[0..width], here[0..width]),
        .linear => if (channel.path == .rotation) {
            const from: math.Quat = .{ .x = here[0], .y = here[1], .z = here[2], .w = here[3] };
            const to: math.Quat = .{ .x = next[0], .y = next[1], .z = next[2], .w = next[3] };
            const turn = math.Quat.slerp(from.norm(), to.norm(), t);
            out = .{ turn.x, turn.y, turn.z, turn.w };
        } else {
            for (0..width) |c| out[c] = here[c] + (next[c] - here[c]) * t;
        },
        .cubic => {
            const t2 = t * t;
            const t3 = t2 * t;
            for (0..width) |c| {
                out[c] = (2 * t3 - 3 * t2 + 1) * here[width + c] + span * (t3 - 2 * t2 + t) * here[2 * width + c] +
                    (-2 * t3 + 3 * t2) * next[width + c] + span * (t3 - t2) * next[c];
            }
            if (channel.path == .rotation) {
                const turn = (math.Quat{ .x = out[0], .y = out[1], .z = out[2], .w = out[3] }).norm();
                out = .{ turn.x, turn.y, turn.z, turn.w };
            }
        },
    }
    return out;
}

/// A name no longer than `limit` - what a player holds - cut where a
/// letter starts.
fn cutTo(name: []const u8, limit: usize) []const u8 {
    if (name.len <= limit) return name;
    var end: usize = limit;
    while (end > 0 and name[end] & 0xc0 == 0x80) end -= 1;
    return name[0..end];
}

fn boneChannel(path: gltf.Channel.Path) animation.BoneChannel {
    return switch (path) {
        .translation => .position,
        .rotation => .rotation,
        .scale => .scale,
    };
}

/// A channel's keys: its own, or along a cubic spline thirty a second.
fn keysOf(gpa: Allocator, channel: gltf.Channel, into: *std.ArrayList(animation.Key)) !void {
    const width = channel.width();
    const times = channel.times;
    if (channel.interpolation != .cubic) {
        for (times, 0..) |time, at| try into.append(gpa, .{ .time = time, .value = valueOf(channel.path, channel.values[at * width ..][0..width]) });
        return;
    }
    // Three values a key: the tangent in, the value, the tangent out.
    const per_key = width * 3;
    for (times, 0..) |time, at| {
        const here = channel.values[at * per_key ..][0..per_key];
        try into.append(gpa, .{ .time = time, .value = valueOf(channel.path, here[width..][0..width]) });
        if (at + 1 == times.len) break;
        const next = channel.values[(at + 1) * per_key ..][0..per_key];
        const span = times[at + 1] - time;
        const steps: usize = @intFromFloat(@max(1, @ceil(span * 30)));
        for (1..steps) |step| {
            const s = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const s2 = s * s;
            const s3 = s2 * s;
            var out: [4]f32 = undefined;
            for (0..width) |c| {
                out[c] = (2 * s3 - 3 * s2 + 1) * here[width + c] + span * (s3 - 2 * s2 + s) * here[2 * width + c] +
                    (-2 * s3 + 3 * s2) * next[width + c] + span * (s3 - s2) * next[c];
            }
            try into.append(gpa, .{ .time = time + span * s, .value = valueOf(channel.path, out[0..width]) });
        }
    }
}

fn valueOf(path: gltf.Channel.Path, numbers: []const f32) Value {
    if (path != .rotation) return .{ .vec3 = numbers[0..3].* };
    const turn = (math.Quat{ .x = numbers[0], .y = numbers[1], .z = numbers[2], .w = numbers[3] }).norm();
    return .{ .quat = .{ turn.x, turn.y, turn.z, turn.w } };
}

/// The path from the model's root a track names `node`'s entity by - empty
/// for the root - as the scene puts it: what hangs from a bone hangs from
/// an entity named after it, under its skeleton's.
fn entityPath(gpa: Allocator, model: *const gltf.Model, parents: []const ?u32, node: ?u32, into: *std.ArrayList(u8)) !void {
    into.clearRetainingCapacity();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var at = node;
    // No deeper than the nodes are many, should a broken file go round.
    while (at) |here| {
        if (names.items.len > model.nodes.len) break;
        try names.append(gpa, model.nodes[here].name);
        at = if (boneSkin(model, here)) |skin| skeletonNode(model.skins[skin], parents) else parents[here];
    }
    var i = names.items.len;
    while (i > 0) {
        i -= 1;
        try into.appendSlice(gpa, names.items[i]);
        if (i > 0) try into.append(gpa, '/');
    }
}

/// The first skin that has `node` as a bone.
fn boneSkin(model: *const gltf.Model, node: u32) ?u32 {
    for (model.skins, 0..) |skin, at| {
        if (jointIndex(skin, node) != null) return @intCast(at);
    }
    return null;
}

/// The skin the first node that draws mesh `at` bends it with, if one does
/// and it has bones.
fn skinOf(model: *const gltf.Model, at: usize) ?gltf.Skin {
    for (model.nodes) |node| {
        const drawn = node.mesh orelse continue;
        if (drawn != at) continue;
        const skin = model.skins[node.skin orelse continue];
        if (skin.joints.len > 0) return skin;
    }
    return null;
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
        // A skeleton on the root, for a skin whose top bones hang from no
        // node.
        const parents = parentsOf(std.heap.page_allocator, model) catch return error.WriteFailed;
        defer std.heap.page_allocator.free(parents);
        if (self.skinOn(null, parents)) |skin| {
            try w.key("Skeleton3D");
            try w.beginObject();
            try self.skeletonField(w, skin);
            try w.endObject();
        }
        // Its animations, for the root to play.
        if (model.animations.len > 0) {
            var name: [512]u8 = undefined;
            try w.key("AnimationPlayer");
            try w.beginObject();
            try w.field("library", std.fmt.bufPrint(&name, "{s}#animations", .{self.source}) catch "");
            try w.endObject();
        }
        try w.endObject();
        // Each node once, under the node that has it - the first that does,
        // where a broken file has two - from the shown scene's roots down.
        const placed = std.heap.page_allocator.alloc(bool, model.nodes.len) catch return error.WriteFailed;
        defer std.heap.page_allocator.free(placed);
        @memset(placed, false);
        const scene: Scene = .{ .placed = placed, .parents = parents };
        for (model.roots) |at| try self.node(w, at, &root, scene);
        try w.endArray();
        try w.endObject();
    }

    /// What the walk down the nodes keeps.
    const Scene = struct {
        placed: []bool,
        parents: []const ?u32,
    };

    /// The first skin with bones whose skeleton is on `node` - the root for
    /// none.
    fn skinOn(self: ModelScene, owner: ?u32, parents: []const ?u32) ?u32 {
        for (self.prepared.model.skins, 0..) |skin, at| {
            if (skin.joints.len == 0) continue;
            const on = skeletonNode(skin, parents);
            if (on == owner) return @intCast(at);
        }
        return null;
    }

    fn skinOfBone(self: ModelScene, at_node: u32) ?u32 {
        return boneSkin(&self.prepared.model, at_node);
    }

    fn skeletonField(self: ModelScene, w: *json.Writer, skin: u32) json.Writer.Error!void {
        var name: [512]u8 = undefined;
        try w.field("skeleton", std.fmt.bufPrint(&name, "{s}#skeleton/{d}", .{ self.source, skin }) catch "");
    }

    /// The UUID of the entity skin `skin`'s skeleton is on.
    fn skeletonEntity(self: ModelScene, skin: u32, parents: []const ?u32) [36]u8 {
        const on = skeletonNode(self.prepared.model.skins[skin], parents);
        return uuidOf(self.source, if (on) |node_at| node_at else null);
    }

    /// A bone: no entity of its own. What hangs from it in the file hangs
    /// from an entity named after it, with a `BoneAttachment3D`, under its
    /// skeleton's; its bones below are walked the same way.
    fn bone(self: ModelScene, w: *json.Writer, at: u32, scene: Scene) json.Writer.Error!void {
        if (scene.placed[at]) return;
        scene.placed[at] = true;
        const model = &self.prepared.model;
        const held = model.nodes[at];
        const skin = self.skinOfBone(at).?;
        const skeleton = self.skeletonEntity(skin, scene.parents);
        var attachment: ?[36]u8 = null;
        for (held.children) |child| {
            if (self.skinOfBone(child) != null) {
                try self.bone(w, child, scene);
                continue;
            }
            if (attachment == null) {
                var name: [600]u8 = undefined;
                const uuid = Uuid.fromName(namespace, std.fmt.bufPrint(&name, "{s}#bone/{d}", .{ self.source, at }) catch self.source).toString();
                attachment = uuid;
                try w.beginObject();
                try w.field("uuid", @as([]const u8, &uuid));
                try w.field("parent", @as([]const u8, &skeleton));
                try w.field("name", held.name);
                try w.key("Transform3D");
                try w.beginObject();
                try w.endObject();
                try w.key("BoneAttachment3D");
                try w.beginObject();
                try w.field("bone", held.name);
                try w.endObject();
                try w.endObject();
            }
            try self.node(w, child, &attachment.?, scene);
        }
    }

    fn node(self: ModelScene, w: *json.Writer, at: u32, parent: []const u8, scene: Scene) json.Writer.Error!void {
        if (self.skinOfBone(at) != null) return self.bone(w, at, scene);
        if (scene.placed[at]) return;
        scene.placed[at] = true;
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
            if (held.skin) |skin| if (model.skins[skin].joints.len > 0) {
                const skeleton = self.skeletonEntity(skin, scene.parents);
                try w.field("skeleton", @as([]const u8, &skeleton));
            };
            try w.endObject();
        }
        if (self.skinOn(at, scene.parents)) |skin| {
            try w.key("Skeleton3D");
            try w.beginObject();
            try self.skeletonField(w, skin);
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
            try w.key(switch (light.kind) {
                .directional => "DirectionalLight3D",
                .point => "PointLight3D",
                .spot => "SpotLight3D",
            });
            try w.beginObject();
            try w.key("color");
            try w.beginObject();
            try w.field("r", light.color.r);
            try w.field("g", light.color.g);
            try w.field("b", light.color.b);
            try w.field("a", @as(f32, 1));
            try w.endObject();
            if (light.kind == .directional) {
                try w.field("energy", @min(light.intensity, 16));
            } else {
                // A point's candela spread over the sphere round it: what
                // a light of energy one is, next to it.
                try w.field("energy", @min(light.intensity / (4 * std.math.pi), 16));
                // glTF's endless reach, where it gives none, is far enough
                // for a room.
                try w.field("range", if (light.range > 0) light.range else 10);
            }
            if (light.kind == .spot) try w.field("angle", light.outer_cone);
            try w.endObject();
        }
        try w.endObject();
        for (held.children) |child| try self.node(w, child, &uuid, scene);
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
