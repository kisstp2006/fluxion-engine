// SPDX-License-Identifier: BSD-3-Clause

//! Models through a whole app, headless: a glTF read as a scene and made
//! into entities, its parts kept under its name, read in the background
//! with the scene that names it, an FBX read from what an editor made of
//! it, import settings, and materials as files.

const std = @import("std");
const testing = std.testing;

const image = @import("fluxion_image");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const components = @import("../scene/components.zig");
const materials = @import("../render/materials.zig");
const gltf = @import("gltf.zig");
const math = @import("fluxion_math");

const Transform3D = components.Transform3D;
const MeshInstance3D = components.MeshInstance3D;
const Material3DData = components.Material3DData;
const Camera3D = components.Camera3D;
const DirectionalLight3D = components.DirectionalLight3D;
const Skeleton3D = components.Skeleton3D;
const BoneAttachment3D = components.BoneAttachment3D;

/// A project in a folder of its own, with a model in `models/`: a red
/// triangle under a node 1, 2, 3 along, its picture beside it, a camera and
/// the sun.
const Folder = struct {
    tmp: testing.TmpDir,
    buffer: [160]u8 = undefined,

    /// Where it is, from the working folder: in its own buffer, so only
    /// once it is where it stays.
    fn root(self: *Folder) []const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}", .{self.tmp.sub_path}) catch unreachable;
    }

    fn init(folder: *Folder) !void {
        folder.* = .{ .tmp = testing.tmpDir(.{}) };
        try Project.writeSettings(testing.allocator, testing.io, folder.root(), .{ .application = .{ .name = "Models" } });
        try folder.tmp.dir.createDirPath(testing.io, "models");
        try folder.put("models/tri.gltf", try triangle());
        var pixels: [2 * 2 * 4]u8 = undefined;
        for (0..4) |at| pixels[at * 4 ..][0..4].* = .{ 220, 40, 40, 255 };
        var path: [200]u8 = undefined;
        try image.png.writeFile(testing.allocator, testing.io, try std.fmt.bufPrint(&path, "{s}/models/red.png", .{folder.root()}), .{ .width = 2, .height = 2, .pixels = &pixels, .row_pitch = 8 }, .{});
    }

    fn deinit(self: *Folder) void {
        self.tmp.cleanup();
    }

    fn put(self: *Folder, name: []const u8, text: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    }

    fn exists(self: *Folder, name: []const u8) bool {
        self.tmp.dir.access(testing.io, name, .{}) catch return false;
        return true;
    }
};

var triangle_text: [4096]u8 = undefined;

fn triangle() ![]const u8 {
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const uvs = [_]f32{ 0, 0, 1, 0, 0, 1 };
    var raw: [36 + 24]u8 = undefined;
    @memcpy(raw[0..36], std.mem.asBytes(&positions));
    @memcpy(raw[36..], std.mem.asBytes(&uvs));
    var coded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&coded, &raw);
    return std.fmt.bufPrint(&triangle_text,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "scenes": [{{ "nodes": [0, 2, 3] }}],
        \\  "nodes": [
        \\    {{ "name": "Holder", "translation": [1, 2, 3], "children": [1] }},
        \\    {{ "name": "Tri", "mesh": 0 }},
        \\    {{ "name": "Eye", "camera": 0, "translation": [1.3, 2.3, 8] }},
        \\    {{ "name": "Sun", "extensions": {{ "KHR_lights_punctual": {{ "light": 0 }} }} }}
        \\  ],
        \\  "meshes": [{{ "name": "Triangle", "primitives": [{{ "attributes": {{ "POSITION": 0, "TEXCOORD_0": 1 }}, "material": 0 }}] }}],
        \\  "materials": [{{ "name": "Red", "pbrMetallicRoughness": {{ "baseColorTexture": {{ "index": 0 }} }}, "doubleSided": true }}],
        \\  "textures": [{{ "source": 0 }}],
        \\  "images": [{{ "uri": "red.png" }}],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2" }}
        \\  ],
        \\  "bufferViews": [{{ "buffer": 0, "byteLength": 36 }}, {{ "buffer": 0, "byteOffset": 36, "byteLength": 24 }}],
        \\  "buffers": [{{ "byteLength": 60, "uri": "data:application/octet-stream;base64,{s}" }}],
        \\  "cameras": [{{ "type": "perspective", "perspective": {{ "yfov": 0.9, "znear": 0.1, "zfar": 100 }} }}],
        \\  "extensions": {{ "KHR_lights_punctual": {{ "lights": [{{ "type": "directional", "intensity": 2 }}] }} }}
        \\}}
    , .{coded});
}

fn appIn(folder: *Folder) !*App {
    return App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = folder.root(), .width = 64, .height = 64 });
}

test "a glTF model is a scene: its nodes an entity tree, its parts kept under its name" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try appIn(&folder);
    defer app.destroy();

    const scene = try app.loadScene("res://models/tri.gltf");
    const root = try app.instantiate(scene, .none);
    try testing.expectEqualStrings("tri", app.nameOf(root).?);
    const holder = app.find("Holder").?;
    try testing.expect(app.parentOf(holder).eql(root));
    try testing.expect(app.world.get(holder, Transform3D).?.position.approxEql(.init(1, 2, 3)));
    const tri = app.find("Tri").?;
    try testing.expect(app.parentOf(tri).eql(holder));
    try testing.expect(app.globalPosition3D(tri).?.approxEql(.init(1, 2, 3)));

    // Its mesh, its material and its picture, by the model's name.
    const mesh = app.world.get(tri, MeshInstance3D).?.mesh;
    try testing.expect(mesh.eql(app.findMesh("res://models/tri.gltf#mesh/0").?));
    const surface = app.meshOf(mesh).?.surfaces[0];
    try testing.expect(surface.material.eql(app.findMaterial("res://models/tri.gltf#material/0").?));
    const look = app.materialOf(surface.material).?;
    try testing.expectEqual(Material3DData.Cull.disabled, look.cull);
    try testing.expect(look.albedo_texture.eql(app.assets.findTexture("res://models/tri.gltf#image/0").?));

    try testing.expectApproxEqAbs(@as(f32, 0.9), app.world.get(app.find("Eye").?, Camera3D).?.fov, 1e-6);
    try testing.expectEqual(@as(f32, 2), app.world.get(app.find("Sun").?, DirectionalLight3D).?.energy);

    // Seen through its own camera, it is drawn.
    try app.makeCurrent3D(app.find("Eye").?);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);

    // A part is named, and read, as any file - and has no UUID file of its own.
    try testing.expect(app.loadMesh("res://models/tri.gltf#mesh/0") catch null != null);
    try app.saveScene("res://level.json", .{});
    try testing.expect(!folder.exists("models/tri.gltf#image/0.uid"));
    try testing.expect(app.scenes.find("res://models/tri.gltf") != null);
}

test "a scene naming a model reads the model with it in the background, a step at a time" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    try folder.put("level.json",
        \\{ "fluxion_scene": 3, "entities": [ { "name": "Thing", "Transform3D": {}, "MeshInstance3D": { "mesh": "res://models/tri.gltf#mesh/0" } } ] }
    );
    const app = try appIn(&folder);
    defer app.destroy();

    try app.loadInBackground("res://level.json");
    var words: [256]u8 = undefined;
    var frames: usize = 0;
    var most: u32 = 0;
    while (frames < 5000) : (frames += 1) {
        const report = app.loadReport("res://level.json", &words).?;
        most = @max(most, report.total);
        if (report.finished) break;
        _ = try app.step();
    }
    // The scene, the model, its picture and its mesh.
    try testing.expectEqual(@as(u32, 4), most);
    const all = app.loadsReport(&words);
    try testing.expect(all.finished);

    const level = try app.loadScene("res://level.json");
    try testing.expectEqual(@as(usize, 0), app.loads.list.items.len);
    try testing.expect(app.scenes.find("res://models/tri.gltf") != null);
    try app.openScene(level);
    const thing = app.find("Thing").?;
    try testing.expect(app.world.get(thing, MeshInstance3D).?.mesh.eql(app.findMesh("res://models/tri.gltf#mesh/0").?));
}

test "an FBX no editor has turned into glTF is refused, and read once one has" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    try folder.put("models/box.fbx", "Kaydara FBX Binary");
    const app = try appIn(&folder);
    defer app.destroy();
    try testing.expectError(error.NotImported, app.loadScene("res://models/box.fbx"));

    try folder.tmp.dir.createDirPath(testing.io, ".fluxion/imported/models");
    try folder.put(".fluxion/imported/models/box.fbx.glb", try triangle());
    // The picture the glTF names is beside what was made, as an editor puts it.
    try folder.put(".fluxion/imported/models/red.png", "not a picture");
    const scene = try app.loadScene("res://models/box.fbx");
    _ = try app.instantiate(scene, .none);
    try testing.expect(app.find("box") != null);
    try testing.expect(app.findMesh("res://models/box.fbx#mesh/0") != null);
}

test "a model's import settings scale its root" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    try folder.put("models/tri.gltf.import", "{ \"scale\": 0.5 }");
    const app = try appIn(&folder);
    defer app.destroy();
    const root = try app.instantiate(try app.loadScene("res://models/tri.gltf"), .none);
    try testing.expectEqual(@as(f32, 0.5), app.world.get(root, Transform3D).?.scale.x);
    try testing.expect(app.globalPosition3D(app.find("Holder").?).?.approxEql(.init(0.5, 1, 1.5)));
}

test "a material is written to a file and read back, its picture by its path and its shader's numbers with it" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try appIn(&folder);
    defer app.destroy();
    const red = try app.loadAsset(@import("assets.zig").TextureHandle, "res://models/red.png");
    const made = try app.addMaterial("brick", .{ .albedo_texture = red, .emission = .{ .r = 1, .g = 0.5, .b = 0, .a = 1 }, .emission_energy = 2, .transparency = .scissor, .cull = .front });
    try app.setMaterialParam(made, "speed", &.{ 2, 3 });
    try app.setMaterialParam(made, "glow", &.{1});
    try app.setMaterialParam(made, "glow", &.{});
    try app.saveMaterial(made, "res://brick.mat3d");
    app.unloadMaterial(made);
    const back = try app.loadMaterial("res://brick.mat3d");
    const look = app.materialOf(back).?;
    try testing.expect(look.albedo_texture.eql(red));
    try testing.expectEqual(@as(f32, 2), look.emission_energy);
    try testing.expectEqual(Material3DData.Transparency.scissor, look.transparency);
    try testing.expectEqual(Material3DData.Cull.front, look.cull);
    // What it leaves out is what a material starts as.
    try testing.expectEqual(@as(f32, 0.5), look.alpha_scissor_threshold);
    try testing.expectEqualStrings("res://brick.mat3d", app.assetSource(back).?);
    try testing.expectEqualSlices(f32, &.{ 2, 3 }, app.materialParam(back, "speed").?);
    try testing.expect(app.materialParam(back, "glow") == null);
}

/// The red triangle as one GLB, its picture in its binary part.
fn triangleGlb(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [2 * 2 * 4]u8 = undefined;
    for (0..4) |at| pixels[at * 4 ..][0..4].* = .{ 40, 200, 40, 255 };
    const png = try image.png.encodeAlloc(gpa, .{ .width = 2, .height = 2, .pixels = &pixels, .row_pitch = 8 }, .{});
    defer gpa.free(png);
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const uvs = [_]f32{ 0, 0, 1, 0, 0, 1 };
    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(gpa);
    try bin.appendSlice(gpa, std.mem.asBytes(&positions));
    try bin.appendSlice(gpa, std.mem.asBytes(&uvs));
    try bin.appendSlice(gpa, png);
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.print(gpa,
        \\{{ "asset": {{ "version": "2.0" }}, "scenes": [{{ "nodes": [0] }}], "nodes": [{{ "name": "Tri", "mesh": 0 }}],
        \\  "meshes": [{{ "primitives": [{{ "attributes": {{ "POSITION": 0, "TEXCOORD_0": 1 }}, "material": 0 }}] }}],
        \\  "materials": [{{ "pbrMetallicRoughness": {{ "baseColorTexture": {{ "index": 0 }} }} }}],
        \\  "textures": [{{ "source": 0 }}], "images": [{{ "bufferView": 2, "mimeType": "image/png" }}],
        \\  "accessors": [{{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }}, {{ "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2" }}],
        \\  "bufferViews": [{{ "buffer": 0, "byteLength": 36 }}, {{ "buffer": 0, "byteOffset": 36, "byteLength": 24 }}, {{ "buffer": 0, "byteOffset": 60, "byteLength": {d} }}],
        \\  "buffers": [{{ "byteLength": {d} }}] }}
    , .{ png.len, bin.items.len });
    while (text.items.len % 4 != 0) try text.append(gpa, ' ');
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const total: u32 = @intCast(12 + 8 + text.items.len + 8 + bin.items.len);
    try out.appendSlice(gpa, "glTF");
    for ([_]u32{ 2, total, @intCast(text.items.len), 0x4E4F534A }) |word| try out.appendSlice(gpa, std.mem.asBytes(&word));
    try out.appendSlice(gpa, text.items);
    for ([_]u32{ @intCast(bin.items.len), 0x004E4942 }) |word| try out.appendSlice(gpa, std.mem.asBytes(&word));
    try out.appendSlice(gpa, bin.items);
    return out.toOwnedSlice(gpa);
}

test "a GLB read in the background makes its picture and its mesh from its own binary part" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const glb = try triangleGlb(testing.allocator);
    defer testing.allocator.free(glb);
    try folder.put("models/tri.glb", glb);
    const app = try appIn(&folder);
    defer app.destroy();

    try app.loadInBackground("res://models/tri.glb");
    var words: [64]u8 = undefined;
    while (app.loadStatus("res://models/tri.glb") == .loading) _ = app.loadsReport(&words);
    _ = try app.instantiate(try app.loadScene("res://models/tri.glb"), .none);
    const picture = app.assets.findTexture("res://models/tri.glb#image/0").?;
    try testing.expectEqual(@as(f32, 2), app.assets.sizeOf(picture).?.width);
    try testing.expect(app.findMesh("res://models/tri.glb#mesh/0") != null);
}

test "an app let go of with loads under way and loads done but not taken frees them all" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try appIn(&folder);
    defer app.destroy();
    try app.loadInBackground("res://models/tri.gltf");
    try app.loadInBackground("res://models/red.png");
    var words: [64]u8 = undefined;
    while (app.loadStatus("res://models/red.png") == .loading) _ = app.loadsReport(&words);
}

test "a skin is a skeleton on the entity its bones hang from, and what hangs from a bone follows it" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    // Two bones bending a square, and a hat on the upper bone.
    const text = try gltf.skinnedGltf(testing.allocator);
    defer testing.allocator.free(text);
    const upper_hat = try std.mem.replaceOwned(u8, testing.allocator, text, "{ \"name\": \"Upper\", \"translation\": [0, 1, 0] }", "{ \"name\": \"Upper\", \"translation\": [0, 1, 0], \"children\": [4] }");
    defer testing.allocator.free(upper_hat);
    const with_hat = try std.mem.replaceOwned(u8, testing.allocator, upper_hat, "{ \"name\": \"Body\", \"mesh\": 0, \"skin\": 0 }", "{ \"name\": \"Body\", \"mesh\": 0, \"skin\": 0 }, { \"name\": \"Hat\", \"translation\": [0, 0.5, 0] }");
    defer testing.allocator.free(with_hat);
    try testing.expect(!std.mem.eql(u8, text, with_hat));
    try folder.put("models/skinned.gltf", with_hat);
    const app = try appIn(&folder);
    defer app.destroy();

    const root = try app.instantiate(try app.loadScene("res://models/skinned.gltf"), .none);
    const armature = app.find("Armature").?;
    try testing.expect(app.parentOf(armature).eql(root));
    const skeleton = app.world.get(armature, Skeleton3D).?.skeleton;
    try testing.expect(skeleton.eql(app.findSkeleton("res://models/skinned.gltf#skeleton/0").?));
    const bones = app.skeletonOf(skeleton).?.bones;
    try testing.expectEqual(@as(usize, 2), bones.len);
    try testing.expectEqualStrings("Upper", bones[1].name);
    try testing.expectEqual(@as(?u16, 0), bones[1].parent);
    try testing.expect(bones[1].rest.translation.approxEql(.init(0, 1, 0)));

    // The bones are not entities; the mesh is bent by the armature's skeleton.
    try testing.expect(app.find("Lower") == null);
    const body = app.find("Body").?;
    try testing.expect(app.world.get(body, MeshInstance3D).?.skeleton.eql(armature));
    const square = app.meshOf(app.world.get(body, MeshInstance3D).?.mesh).?;
    try testing.expectEqual(@as(usize, 6), square.skin.len);
    try testing.expectEqual(@as(usize, 2), square.bone_bounds.len);

    // The hat hangs from an entity named after its bone, which follows it.
    const upper = app.find("Upper").?;
    try testing.expectEqualStrings("Upper", app.world.get(upper, BoneAttachment3D).?.boneName());
    try testing.expect(app.parentOf(upper).eql(armature));
    const hat = app.find("Hat").?;
    try testing.expect(app.parentOf(hat).eql(upper));
    _ = try app.step();
    try testing.expect(app.globalPosition3D(hat).?.approxEql(.init(0, 1.5, 0)));

    // The lower bone turned a quarter about z: the hat swings round with it.
    try testing.expectEqual(@as(u32, 2), app.boneCount(armature));
    try testing.expectEqual(@as(i32, 0), app.findBone(armature, "Lower"));
    try testing.expectEqual(@as(i32, -1), app.findBone(armature, "Tail"));
    app.setBoneRotation(armature, 0, .fromAxisAngle(.unit_z, std.math.pi / 2.0));
    _ = try app.step();
    try testing.expect(app.globalPosition3D(hat).?.sub(.init(-1.5, 0, 0)).len() < 1e-4);
    try testing.expect(app.boneGlobalPosition(armature, 1).sub(.init(-1, 0, 0)).len() < 1e-4);
    app.resetPose(armature);
    try testing.expect(app.bonePosition(armature, 1).approxEql(.init(0, 1, 0)));
}
