// SPDX-License-Identifier: BSD-3-Clause

//! glTF 2.0 - a `.glb`, or a `.gltf` with the files it names beside it -
//! read into plain data, made on whichever thread reads it: its meshes,
//! its materials, the pictures they name, and the tree of its nodes with
//! their cameras and lights. What the engine makes of it is
//! `assets/models.zig`'s.
//!
//! Reading is in pieces so a load can share them out: `parse` reads the
//! document and its buffers, then each mesh is built (`buildMesh`) and each
//! picture decoded (`decodeImage`) on its own, in any order, on any thread.
//! `read` does it all at once.
//!
//! What is read: triangles, strips and fans with their positions, normals
//! (worked out, flat, where there are none), first picture coordinates and
//! colours; the metallic-roughness material's base colour and picture,
//! emission and its strength, its alpha mode and whether both its sides
//! show, and the unlit extension; a picture's coordinates moved and scaled
//! by the texture-transform extension; PNG and JPEG pictures, in the file
//! or beside it; nodes' places, turns and sizes, given apart or as a
//! matrix; perspective and orthographic cameras; the punctual lights;
//! skins - the nodes that are a skeleton's bones, each one's inverse bind
//! matrix, and each vertex's four bones and weights - and animations, each
//! channel a node's place, turn or size, stepped, straight or along a cubic
//! spline. What is left out - lines, points, morph targets and their
//! weights, a sparse accessor, a picture of another format, a skin of more
//! than `mesh.max_bones` bones - is said in `Model.notes`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const image = @import("fluxion_image");
const math = @import("fluxion_math");

const Color = @import("../math/color.zig").Color;
const mesh = @import("../render/mesh.zig");
const lightmap_uv = @import("../render/lightmap_uv.zig");
const lods = @import("../render/lods.zig");
const Material3D = @import("../render/render3d_components.zig").Material3DData;

const Vec3 = math.Vec3;

pub const Error = error{
    /// Not glTF 2.0: a broken container, a document that does not read, a
    /// number that points past what it names.
    BadModel,
    /// glTF of a version other than 2, or one that needs an extension that
    /// is not read.
    UnsupportedModel,
} || Allocator.Error;

/// Reads a file a `.gltf` names - a buffer, a picture - by the `uri` it
/// gives, relative to the `.gltf`.
pub const Fetch = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, gpa: Allocator, uri: []const u8) anyerror![]u8,
};

/// Where a material's picture comes from.
pub const TextureRef = struct {
    image: u32,
    nearest: bool = false,
};

pub const Material = struct {
    name: []const u8,
    /// What the material is, but its pictures, which are the rest.
    look: Material3D,
    albedo: ?TextureRef = null,
    emission: ?TextureRef = null,
    metallic_roughness: ?TextureRef = null,
    normal: ?TextureRef = null,
    occlusion: ?TextureRef = null,

    /// Every picture it names, for what goes through them all.
    pub fn pictures(self: Material) [5]?TextureRef {
        return .{ self.albedo, self.emission, self.metallic_roughness, self.normal, self.occlusion };
    }
};

pub const Image = struct {
    name: []const u8,
    /// As stored: a PNG or a JPEG.
    bytes: []const u8 = &.{},
    /// Once `decodeImage` has: four bytes a pixel, top row first.
    width: u32 = 0,
    height: u32 = 0,
    pixels: []u8 = &.{},
    decoded: bool = false,
};

pub const SurfaceData = struct {
    first_index: u32,
    index_count: u32,
    material: ?u32,
};

pub const MeshData = struct {
    name: []const u8,
    /// Once `buildMesh` has: the gpa's, given away with `take`.
    vertices: []mesh.Vertex = &.{},
    indices: []u32 = &.{},
    surfaces: []mesh.Surface = &.{},
    /// Each surface's material, by the document's index.
    materials: []?u32 = &.{},
    /// Its `Mesh.uv2_texels`: what its own second coordinates are laid out
    /// for, or what `lightmap_uv.unwrap` made; nought for none.
    uv2_texels: u32 = 0,
    /// Its coarser levels: see `render/lods.zig`. Their surfaces' materials
    /// are the mesh's own surfaces', in order.
    lods: []mesh.Lod = &.{},
    /// Each vertex's bones, for a mesh a skin bends; empty for one that is
    /// not. See `mesh.SkinVertex`.
    skin: []mesh.SkinVertex = &.{},
    built: bool = false,

    /// The vertices, indices, surfaces, skin and levels, which are the
    /// caller's from here.
    pub fn take(self: *MeshData) struct { []mesh.Vertex, []u32, []mesh.Surface, []mesh.SkinVertex, []mesh.Lod } {
        defer {
            self.vertices = &.{};
            self.indices = &.{};
            self.surfaces = &.{};
            self.skin = &.{};
            self.lods = &.{};
        }
        return .{ self.vertices, self.indices, self.surfaces, self.skin, self.lods };
    }
};

pub const Camera = struct {
    orthogonal: bool = false,
    /// Radians, bottom to top.
    fov: f32 = std.math.degreesToRadians(60.0),
    /// World units, bottom to top.
    size: f32 = 2,
    near: f32 = 0.05,
    far: f32 = 4000,
};

pub const Light = struct {
    kind: Kind,
    color: Color = .white,
    intensity: f32 = 1,
    /// Nought for none.
    range: f32 = 0,
    inner_cone: f32 = 0,
    outer_cone: f32 = std.math.pi / 4.0,

    pub const Kind = enum { directional, point, spot };
};

pub const Node = struct {
    name: []const u8,
    transform: math.Transform = .{},
    mesh: ?u32 = null,
    /// The skin its mesh is bent by, if it is.
    skin: ?u32 = null,
    camera: ?u32 = null,
    light: ?u32 = null,
    children: []const u32 = &.{},
};

/// A skeleton: the nodes that are its bones, in the order a vertex of a
/// mesh it bends names them, and each one's inverse bind matrix - what takes
/// a vertex from where the mesh was made to the bone's own space.
pub const Skin = struct {
    name: []const u8,
    joints: []const u32,
    inverse_binds: []const math.Mat4,
};

/// One node's place, turn or size over time.
pub const Channel = struct {
    node: u32,
    path: Path,
    interpolation: Interpolation,
    /// Seconds, rising.
    times: []const f32,
    /// Each key's numbers: three for a place or a size, four for a turn -
    /// x, y, z, w. On a cubic spline, three of those a key: the tangent in,
    /// the value, the tangent out.
    values: []const f32,

    pub const Path = enum { translation, rotation, scale };
    pub const Interpolation = enum { linear, step, cubic };

    /// How many numbers one value is.
    pub fn width(self: Channel) usize {
        return if (self.path == .rotation) 4 else 3;
    }
};

pub const Animation = struct {
    name: []const u8,
    channels: []const Channel,
    /// Its last key's time, in seconds.
    length: f32,
};

pub const Model = struct {
    /// What `parse` read: the document's names and buffers.
    arena: std.heap.ArenaAllocator,
    /// What the pieces made, which any thread may ask of: the meshes and the
    /// pictures. Freed with the model unless it was taken.
    gpa: Allocator,
    meshes: []MeshData = &.{},
    materials: []Material = &.{},
    images: []Image = &.{},
    nodes: []Node = &.{},
    /// The nodes the shown scene starts from.
    roots: []const u32 = &.{},
    cameras: []Camera = &.{},
    lights: []Light = &.{},
    skins: []Skin = &.{},
    animations: []Animation = &.{},
    /// What was left out, in words: one line each.
    notes: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Kept for `buildMesh`: the document and its buffers.
    doc: Doc = .{},
    buffers: [][]const u8 = &.{},
    /// Whether `buildMesh` works out lightmap UVs for a mesh that brings
    /// none, with `lightmap_uv.unwrap`.
    unwrap_lightmap: bool = false,
    /// A file of the model's meshes' levels of detail, as an editor made it:
    /// see `render/lods.zig`. The gpa's, freed with the model.
    lod_file: []const u8 = &.{},
    /// Whether `buildMesh` makes the levels of a mesh the file has none for.
    make_lods: bool = true,

    pub fn deinit(self: *Model) void {
        for (self.meshes) |*held| {
            self.gpa.free(held.vertices);
            self.gpa.free(held.indices);
            self.gpa.free(held.surfaces);
            self.gpa.free(held.materials);
            self.gpa.free(held.skin);
            for (held.lods) |*level| level.deinit(self.gpa);
            self.gpa.free(held.lods);
        }
        self.gpa.free(self.lod_file);
        for (self.images) |held| self.gpa.free(held.pixels);
        self.arena.deinit();
        self.* = undefined;
    }

    fn note(self: *Model, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.notes.append(self.arena.allocator(), try std.fmt.allocPrint(self.arena.allocator(), fmt, args));
    }

    /// The triangles of every mesh, built.
    pub fn triangleCount(self: *const Model) usize {
        var count: usize = 0;
        for (self.meshes) |held| count += held.indices.len / 3;
        return count;
    }
};

/// Everything at once: `parse`, then `finish`.
pub fn read(gpa: Allocator, bytes: []const u8, fetch: ?Fetch) Error!Model {
    var model = try parse(gpa, bytes, fetch);
    errdefer model.deinit();
    try finish(&model);
    return model;
}

/// Every mesh built and every picture decoded.
pub fn finish(model: *Model) Error!void {
    for (0..model.meshes.len) |at| try buildMesh(model, at);
    for (0..model.images.len) |at| try decodeImage(model, at);
}

/// How many texels across a mesh's own second coordinates are taken to be
/// laid out for: what the file does not say.
pub const brought_uv2_texels = 64;

// -------------------------------------------------------------------------
// The document
// -------------------------------------------------------------------------

const Doc = struct {
    asset: struct { version: []const u8 = "" } = .{},
    extensionsRequired: []const []const u8 = &.{},
    scene: ?u32 = null,
    scenes: []const struct { nodes: []const u32 = &.{} } = &.{},
    nodes: []const NodeDoc = &.{},
    meshes: []const MeshDoc = &.{},
    accessors: []const AccessorDoc = &.{},
    bufferViews: []const BufferViewDoc = &.{},
    buffers: []const struct { uri: ?[]const u8 = null, byteLength: u64 = 0 } = &.{},
    materials: []const MaterialDoc = &.{},
    textures: []const struct { source: ?u32 = null, sampler: ?u32 = null } = &.{},
    images: []const struct { uri: ?[]const u8 = null, bufferView: ?u32 = null, mimeType: []const u8 = "", name: []const u8 = "" } = &.{},
    samplers: []const struct { magFilter: ?u32 = null } = &.{},
    cameras: []const CameraDoc = &.{},
    skins: []const SkinDoc = &.{},
    animations: []const AnimationDoc = &.{},
    extensions: struct {
        KHR_lights_punctual: ?struct { lights: []const LightDoc = &.{} } = null,
    } = .{},
};

const SkinDoc = struct {
    name: []const u8 = "",
    inverseBindMatrices: ?u32 = null,
    joints: []const u32 = &.{},
};

const AnimationDoc = struct {
    name: []const u8 = "",
    channels: []const struct {
        sampler: u32,
        target: struct { node: ?u32 = null, path: []const u8 = "" },
    } = &.{},
    samplers: []const struct {
        input: u32,
        output: u32,
        interpolation: []const u8 = "LINEAR",
    } = &.{},
};

const NodeDoc = struct {
    name: []const u8 = "",
    children: []const u32 = &.{},
    mesh: ?u32 = null,
    skin: ?u32 = null,
    camera: ?u32 = null,
    matrix: ?[16]f32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    extensions: struct { KHR_lights_punctual: ?struct { light: u32 } = null } = .{},
};

const MeshDoc = struct {
    name: []const u8 = "",
    primitives: []const PrimitiveDoc = &.{},
};

const PrimitiveDoc = struct {
    attributes: struct {
        POSITION: ?u32 = null,
        NORMAL: ?u32 = null,
        TEXCOORD_0: ?u32 = null,
        TEXCOORD_1: ?u32 = null,
        COLOR_0: ?u32 = null,
        TANGENT: ?u32 = null,
        JOINTS_0: ?u32 = null,
        WEIGHTS_0: ?u32 = null,
    } = .{},
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: u32 = 4,
    targets: []const json.Value = &.{},
};

const AccessorDoc = struct {
    bufferView: ?u32 = null,
    byteOffset: u64 = 0,
    componentType: u32 = 0,
    normalized: bool = false,
    count: u32 = 0,
    type: []const u8 = "SCALAR",
    sparse: ?json.Value = null,
};

const BufferViewDoc = struct {
    buffer: u32 = 0,
    byteOffset: u64 = 0,
    byteLength: u64 = 0,
    byteStride: ?u32 = null,
};

const TextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    extensions: struct {
        KHR_texture_transform: ?struct { offset: [2]f32 = .{ 0, 0 }, scale: [2]f32 = .{ 1, 1 } } = null,
    } = .{},
};

const MaterialDoc = struct {
    name: []const u8 = "",
    pbrMetallicRoughness: struct {
        baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
        baseColorTexture: ?TextureInfo = null,
        metallicFactor: f32 = 1,
        roughnessFactor: f32 = 1,
        metallicRoughnessTexture: ?TextureInfo = null,
    } = .{},
    normalTexture: ?struct { index: u32, texCoord: u32 = 0, scale: f32 = 1 } = null,
    occlusionTexture: ?struct { index: u32, texCoord: u32 = 0, strength: f32 = 1 } = null,
    emissiveFactor: [3]f32 = .{ 0, 0, 0 },
    emissiveTexture: ?TextureInfo = null,
    alphaMode: []const u8 = "OPAQUE",
    alphaCutoff: f32 = 0.5,
    doubleSided: bool = false,
    extensions: struct {
        KHR_materials_emissive_strength: ?struct { emissiveStrength: f32 = 1 } = null,
        KHR_materials_unlit: ?json.Value = null,
    } = .{},
};

const CameraDoc = struct {
    type: []const u8 = "perspective",
    perspective: ?struct { yfov: f32 = 1, znear: f32 = 0.05, zfar: ?f32 = null } = null,
    orthographic: ?struct { ymag: f32 = 1, znear: f32 = 0.05, zfar: f32 = 4000 } = null,
};

const LightDoc = struct {
    type: []const u8 = "point",
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    range: ?f32 = null,
    spot: ?struct { innerConeAngle: f32 = 0, outerConeAngle: f32 = std.math.pi / 4.0 } = null,
};

/// The extensions a file may need and still be read.
const understood = [_][]const u8{ "KHR_texture_transform", "KHR_materials_emissive_strength", "KHR_materials_unlit", "KHR_lights_punctual", "KHR_mesh_quantization" };

/// A `.glb`'s two parts: the document, and the binary buffer if it has one.
fn split(bytes: []const u8) Error!struct { text: []const u8, bin: ?[]const u8 } {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "glTF")) return .{ .text = bytes, .bin = null };
    if (bytes.len < 20) return error.BadModel;
    if (std.mem.readInt(u32, bytes[4..8], .little) != 2) return error.UnsupportedModel;
    const total = @min(std.mem.readInt(u32, bytes[8..12], .little), bytes.len);
    var at: usize = 12;
    var text: ?[]const u8 = null;
    var bin: ?[]const u8 = null;
    while (at + 8 <= total) {
        const length = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        at += 8;
        if (at + length > total) return error.BadModel;
        const chunk = bytes[at .. at + length];
        if (kind == 0x4E4F534A and text == null) text = chunk;
        if (kind == 0x004E4942 and bin == null) bin = chunk;
        at += length;
    }
    return .{ .text = text orelse return error.BadModel, .bin = bin };
}

/// The document and its buffers read; every mesh and picture named but
/// not yet made.
/// What is read of `bytes` by `buildMesh` and `decodeImage` - a GLB's
/// binary part - is read where it is: `bytes` outlives the model's pieces.
pub fn parse(gpa: Allocator, bytes: []const u8, fetch: ?Fetch) Error!Model {
    var model: Model = .{ .arena = .init(gpa), .gpa = gpa };
    errdefer model.deinit();
    const a = model.arena.allocator();
    const parts = try split(bytes);
    const parsed = json.parseAs(Doc, a, parts.text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadModel,
    };
    const doc = parsed.value;
    model.doc = doc;
    if (!std.mem.startsWith(u8, doc.asset.version, "2")) return error.UnsupportedModel;
    for (doc.extensionsRequired) |needed| {
        for (understood) |known| {
            if (std.mem.eql(u8, needed, known)) break;
        } else return error.UnsupportedModel;
    }

    // The buffers: the binary part, a data URI, or a file beside it.
    const buffers = try a.alloc([]const u8, doc.buffers.len);
    for (doc.buffers, buffers, 0..) |given, *out, at| {
        out.* = if (given.uri) |uri|
            fromUri(a, uri, fetch) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadModel,
            }
        else if (at == 0) parts.bin orelse return error.BadModel else return error.BadModel;
        if (out.len < given.byteLength) return error.BadModel;
    }
    model.buffers = buffers;

    // The pictures, as stored.
    model.images = try a.alloc(Image, doc.images.len);
    for (doc.images, model.images, 0..) |given, *out, at| {
        out.* = .{ .name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Image {d}", .{at}) };
        if (given.bufferView) |view| {
            out.bytes = try viewBytes(&model, view);
        } else if (given.uri) |uri| {
            out.bytes = fromUri(a, uri, fetch) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try model.note("the picture {s} did not read: {t}", .{ uri, err });
                break :blk &.{};
            };
        }
    }

    // The materials, their pictures by index.
    model.materials = try a.alloc(Material, doc.materials.len);
    for (doc.materials, model.materials, 0..) |given, *out, at| {
        out.* = .{ .name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Material {d}", .{at}), .look = try materialOf(&model, given) };
        if (given.pbrMetallicRoughness.baseColorTexture) |info| out.albedo = textureRef(&model, info);
        if (given.emissiveTexture) |info| out.emission = textureRef(&model, info);
        if (given.pbrMetallicRoughness.metallicRoughnessTexture) |info| out.metallic_roughness = textureRef(&model, info);
        if (given.normalTexture) |info| out.normal = textureRef(&model, .{ .index = info.index, .texCoord = info.texCoord });
        if (given.occlusionTexture) |info| out.occlusion = textureRef(&model, .{ .index = info.index, .texCoord = info.texCoord });
    }

    model.meshes = try a.alloc(MeshData, doc.meshes.len);
    for (doc.meshes, model.meshes, 0..) |given, *out, at| {
        out.* = .{ .name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Mesh {d}", .{at}) };
    }

    model.cameras = try a.alloc(Camera, doc.cameras.len);
    for (doc.cameras, model.cameras) |given, *out| {
        out.* = .{};
        if (std.mem.eql(u8, given.type, "orthographic")) {
            const ortho = given.orthographic orelse continue;
            out.* = .{ .orthogonal = true, .size = 2 * ortho.ymag, .near = ortho.znear, .far = ortho.zfar };
        } else if (given.perspective) |persp| {
            out.* = .{ .fov = persp.yfov, .near = persp.znear, .far = persp.zfar orelse 4000 };
        }
    }

    const light_docs: []const LightDoc = if (doc.extensions.KHR_lights_punctual) |held| held.lights else &.{};
    model.lights = try a.alloc(Light, light_docs.len);
    for (light_docs, model.lights) |given, *out| {
        const kind: Light.Kind = if (std.mem.eql(u8, given.type, "directional")) .directional else if (std.mem.eql(u8, given.type, "spot")) .spot else .point;
        out.* = .{ .kind = kind, .color = Color.fromLinear(given.color[0], given.color[1], given.color[2], 1), .intensity = given.intensity, .range = given.range orelse 0 };
        if (given.spot) |cone| {
            out.inner_cone = cone.innerConeAngle;
            out.outer_cone = cone.outerConeAngle;
        }
    }

    model.nodes = try a.alloc(Node, doc.nodes.len);
    for (doc.nodes, model.nodes, 0..) |given, *out, at| {
        for (given.children) |child| if (child >= doc.nodes.len) return error.BadModel;
        if (given.mesh) |held| if (held >= doc.meshes.len) return error.BadModel;
        if (given.camera) |held| if (held >= doc.cameras.len) return error.BadModel;
        out.* = .{
            .name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Node {d}", .{at}),
            .transform = transformOf(given),
            .mesh = given.mesh,
            .skin = if (given.skin) |held| if (held < doc.skins.len) held else null else null,
            .camera = given.camera,
            .children = given.children,
        };
        if (given.extensions.KHR_lights_punctual) |held| {
            if (held.light >= light_docs.len) return error.BadModel;
            out.light = held.light;
        }
    }

    try readSkins(&model);
    try readAnimations(&model);

    // The scene shown: the one it names, the first, or every node no other
    // has as a child.
    if (doc.scenes.len > 0) {
        const shown = doc.scene orelse 0;
        if (shown >= doc.scenes.len) return error.BadModel;
        model.roots = doc.scenes[shown].nodes;
        for (model.roots) |root| if (root >= doc.nodes.len) return error.BadModel;
    } else {
        var held = try a.alloc(bool, doc.nodes.len);
        @memset(held, false);
        for (doc.nodes) |node| for (node.children) |child| {
            held[child] = true;
        };
        var roots: std.ArrayListUnmanaged(u32) = .empty;
        for (held, 0..) |is_child, at| if (!is_child) try roots.append(a, @intCast(at));
        model.roots = roots.items;
    }
    return model;
}

/// Each skin's bones and inverse bind matrices. One of more bones than a
/// vertex can name is left out, and its meshes drawn as they are.
fn readSkins(model: *Model) Error!void {
    const doc = model.doc;
    const a = model.arena.allocator();
    model.skins = try a.alloc(Skin, doc.skins.len);
    for (doc.skins, model.skins, 0..) |given, *out, at| {
        for (given.joints) |joint| if (joint >= doc.nodes.len) return error.BadModel;
        const name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Skin {d}", .{at});
        if (given.joints.len > mesh.max_bones) {
            try model.note("the skin {s} has {d} bones, more than {d}: its meshes are drawn as they were made", .{ name, given.joints.len, mesh.max_bones });
            out.* = .{ .name = name, .joints = &.{}, .inverse_binds = &.{} };
            continue;
        }
        const binds = try a.alloc(math.Mat4, given.joints.len);
        @memset(binds, math.Mat4.identity);
        if (given.inverseBindMatrices) |accessor| {
            const view = try viewOf(model, accessor, "inverse bind matrices");
            if (view.components != 16 or view.count < given.joints.len) return error.BadModel;
            for (binds, 0..) |*bind, i| {
                var numbers: [16]f32 = undefined;
                for (&numbers, 0..) |*number, c| number.* = view.float(i, c);
                bind.* = .fromArray(numbers);
            }
        }
        out.* = .{ .name = name, .joints = given.joints, .inverse_binds = binds };
    }
}

/// Each animation's channels: its nodes' places, turns and sizes, keyed.
/// A morph target's weights, and a channel that names no node, are left
/// out.
fn readAnimations(model: *Model) Error!void {
    const doc = model.doc;
    const a = model.arena.allocator();
    var animations: std.ArrayListUnmanaged(Animation) = .empty;
    var weights_noted = false;
    for (doc.animations, 0..) |given, at| {
        var channels: std.ArrayListUnmanaged(Channel) = .empty;
        var length: f32 = 0;
        for (given.channels) |channel| {
            const node = channel.target.node orelse continue;
            if (node >= doc.nodes.len or channel.sampler >= given.samplers.len) return error.BadModel;
            const path: Channel.Path = if (std.mem.eql(u8, channel.target.path, "translation"))
                .translation
            else if (std.mem.eql(u8, channel.target.path, "rotation"))
                .rotation
            else if (std.mem.eql(u8, channel.target.path, "scale"))
                .scale
            else {
                if (!weights_noted) try model.note("a morph target's weights are not animated", .{});
                weights_noted = true;
                continue;
            };
            const sampler = given.samplers[channel.sampler];
            const interpolation: Channel.Interpolation = if (std.mem.eql(u8, sampler.interpolation, "STEP"))
                .step
            else if (std.mem.eql(u8, sampler.interpolation, "CUBICSPLINE"))
                .cubic
            else
                .linear;
            const input = try viewOf(model, sampler.input, "key times");
            const output = try viewOf(model, sampler.output, "key values");
            const width: usize = if (path == .rotation) 4 else 3;
            const per_key: usize = if (interpolation == .cubic) 3 else 1;
            if (input.components != 1 or output.components != width or output.count < input.count * per_key) return error.BadModel;
            const times = try a.alloc(f32, input.count);
            for (times, 0..) |*time, i| time.* = input.float(i, 0);
            const values = try a.alloc(f32, input.count * per_key * width);
            for (0..input.count * per_key) |i| for (0..width) |c| {
                values[i * width + c] = output.float(i, c);
            };
            if (times.len > 0) length = @max(length, times[times.len - 1]);
            try channels.append(a, .{ .node = node, .path = path, .interpolation = interpolation, .times = times, .values = values });
        }
        const name = if (given.name.len > 0) given.name else try std.fmt.allocPrint(a, "Animation {d}", .{at});
        try animations.append(a, .{ .name = name, .channels = channels.items, .length = length });
    }
    model.animations = animations.items;
}

fn transformOf(given: NodeDoc) math.Transform {
    if (given.matrix) |m| return .fromMat4(.fromArray(m));
    var out: math.Transform = .{};
    if (given.translation) |t| out.translation = .init(t[0], t[1], t[2]);
    if (given.rotation) |r| out.rotation = (math.Quat{ .x = r[0], .y = r[1], .z = r[2], .w = r[3] }).norm();
    if (given.scale) |s| out.scale = .init(s[0], s[1], s[2]);
    return out;
}

fn textureRef(model: *Model, info: TextureInfo) ?TextureRef {
    const doc = model.doc;
    if (info.index >= doc.textures.len) return null;
    const texture = doc.textures[info.index];
    const source = texture.source orelse return null;
    if (source >= model.images.len) return null;
    var nearest = false;
    if (texture.sampler) |at| if (at < doc.samplers.len) {
        nearest = (doc.samplers[at].magFilter orelse 9729) == 9728;
    };
    return .{ .image = source, .nearest = nearest };
}

fn materialOf(model: *Model, given: MaterialDoc) Allocator.Error!Material3D {
    const pbr = given.pbrMetallicRoughness;
    const base = pbr.baseColorFactor;
    var look: Material3D = .{
        .albedo_color = Color.fromLinear(base[0], base[1], base[2], base[3]),
        // A glTF material is always tinted by its corners' colours, which
        // are white where a mesh gives none.
        .vertex_color = true,
        .emission = Color.fromLinear(given.emissiveFactor[0], given.emissiveFactor[1], given.emissiveFactor[2], 1),
        .metallic = pbr.metallicFactor,
        .roughness = pbr.roughnessFactor,
        .cull = if (given.doubleSided) .disabled else .back,
        .unshaded = given.extensions.KHR_materials_unlit != null,
    };
    if (given.normalTexture) |info| look.normal_scale = info.scale;
    if (given.occlusionTexture) |info| look.occlusion_strength = info.strength;
    if (given.extensions.KHR_materials_emissive_strength) |strength| look.emission_energy = strength.emissiveStrength;
    if (std.mem.eql(u8, given.alphaMode, "BLEND")) {
        look.transparency = .alpha;
    } else if (std.mem.eql(u8, given.alphaMode, "MASK")) {
        look.transparency = .scissor;
        look.alpha_scissor_threshold = given.alphaCutoff;
    }
    if (pbr.baseColorTexture) |info| {
        if (info.texCoord != 0) try model.note("the material {s} lays its picture by its second coordinates, which are not read", .{given.name});
        if (info.extensions.KHR_texture_transform) |moved| {
            look.uv_scale = .init(moved.scale[0], moved.scale[1]);
            look.uv_offset = .init(moved.offset[0], moved.offset[1]);
        }
    }
    return look;
}

/// A buffer view's bytes.
fn viewBytes(model: *const Model, at: u32) Error![]const u8 {
    const doc = model.doc;
    if (at >= doc.bufferViews.len) return error.BadModel;
    const view = doc.bufferViews[at];
    if (view.buffer >= model.buffers.len) return error.BadModel;
    const buffer = model.buffers[view.buffer];
    if (view.byteOffset + view.byteLength > buffer.len) return error.BadModel;
    return buffer[@intCast(view.byteOffset)..][0..@intCast(view.byteLength)];
}

/// A data URI's bytes, or the file it names beside the model's.
fn fromUri(a: Allocator, uri: []const u8, fetch: ?Fetch) ![]const u8 {
    if (std.mem.startsWith(u8, uri, "data:")) {
        const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.BadModel;
        if (!std.mem.endsWith(u8, uri[0..comma], ";base64")) return error.BadModel;
        const coded = uri[comma + 1 ..];
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(coded) catch return error.BadModel;
        const out = try a.alloc(u8, size);
        decoder.decode(out, coded) catch return error.BadModel;
        return out;
    }
    const reader = fetch orelse return error.BadModel;
    const named = try percentDecoded(a, uri);
    return reader.read(reader.context, a, named);
}

/// `%20` and the like, as a URI spells them, made what they are.
fn percentDecoded(a: Allocator, uri: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, uri, '%') == null) return uri;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var at: usize = 0;
    while (at < uri.len) : (at += 1) {
        if (uri[at] == '%' and at + 2 < uri.len) {
            if (std.fmt.parseInt(u8, uri[at + 1 .. at + 3], 16)) |byte| {
                try out.append(a, byte);
                at += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, uri[at]);
    }
    return out.items;
}

// -------------------------------------------------------------------------
// The pieces
// -------------------------------------------------------------------------

/// The picture at `at` decoded into four bytes a pixel. One that is not a
/// PNG or a JPEG is left out, and said in `notes` - on the thread that reads
/// the notes once every piece is done.
pub fn decodeImage(model: *Model, at: usize) Error!void {
    const held = &model.images[at];
    if (held.decoded or held.bytes.len == 0) return;
    const picture = image.decode(model.gpa, held.bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    held.width = picture.width;
    held.height = picture.height;
    held.pixels = picture.pixels;
    held.decoded = true;
}

/// An accessor, as its bytes and how to read them.
const View = struct {
    bytes: []const u8,
    count: u32,
    components: u32,
    component: u32,
    normalized: bool,
    stride: usize,

    fn componentSize(kind: u32) ?usize {
        return switch (kind) {
            5120, 5121 => 1,
            5122, 5123 => 2,
            5125, 5126 => 4,
            else => null,
        };
    }

    /// Item `i`'s component `c`, as a number: a normalized integer made
    /// nought to one (or minus one to one).
    fn float(self: View, i: usize, c: usize) f32 {
        const size = componentSize(self.component).?;
        const at = self.bytes[i * self.stride + c * size ..];
        return switch (self.component) {
            5126 => @bitCast(std.mem.readInt(u32, at[0..4], .little)),
            5121 => blk: {
                const v: f32 = @floatFromInt(at[0]);
                break :blk if (self.normalized) v / 255 else v;
            },
            5120 => blk: {
                const v: f32 = @floatFromInt(@as(i8, @bitCast(at[0])));
                break :blk if (self.normalized) @max(v / 127, -1) else v;
            },
            5123 => blk: {
                const v: f32 = @floatFromInt(std.mem.readInt(u16, at[0..2], .little));
                break :blk if (self.normalized) v / 65535 else v;
            },
            5122 => blk: {
                const v: f32 = @floatFromInt(std.mem.readInt(i16, at[0..2], .little));
                break :blk if (self.normalized) @max(v / 32767, -1) else v;
            },
            5125 => @floatFromInt(std.mem.readInt(u32, at[0..4], .little)),
            else => 0,
        };
    }

    fn index(self: View, i: usize) u32 {
        return self.whole(i, 0);
    }

    /// Item `i`'s component `c`, as a whole number: what a vertex's bones
    /// are named by.
    fn whole(self: View, i: usize, c: usize) u32 {
        const at = self.bytes[i * self.stride + c * (componentSize(self.component) orelse 1) ..];
        return switch (self.component) {
            5121 => at[0],
            5123 => std.mem.readInt(u16, at[0..2], .little),
            5125 => std.mem.readInt(u32, at[0..4], .little),
            else => 0,
        };
    }
};

fn viewOf(model: *const Model, at: u32, comptime what: []const u8) Error!View {
    const doc = model.doc;
    if (at >= doc.accessors.len) return error.BadModel;
    const accessor = doc.accessors[at];
    if (accessor.sparse != null) return error.UnsupportedModel;
    const components: u32 = if (std.mem.eql(u8, accessor.type, "SCALAR")) 1 else if (std.mem.eql(u8, accessor.type, "VEC2")) 2 else if (std.mem.eql(u8, accessor.type, "VEC3")) 3 else if (std.mem.eql(u8, accessor.type, "VEC4")) 4 else if (std.mem.eql(u8, accessor.type, "MAT4")) 16 else return error.BadModel;
    const size = View.componentSize(accessor.componentType) orelse return error.BadModel;
    const view_index = accessor.bufferView orelse return error.BadModel;
    const bytes = try viewBytes(model, view_index);
    const stride: usize = doc.bufferViews[view_index].byteStride orelse components * size;
    if (accessor.count == 0) return .{ .bytes = &.{}, .count = 0, .components = components, .component = accessor.componentType, .normalized = accessor.normalized, .stride = stride };
    const start: usize = @intCast(accessor.byteOffset);
    const needed = start + (accessor.count - 1) * stride + components * size;
    if (needed > bytes.len) return error.BadModel;
    _ = what;
    return .{ .bytes = bytes[start..], .count = accessor.count, .components = components, .component = accessor.componentType, .normalized = accessor.normalized, .stride = stride };
}

/// The mesh at `at` built: each primitive's vertices and triangles
/// appended, a surface each.
pub fn buildMesh(model: *Model, at: usize) Error!void {
    const held = &model.meshes[at];
    if (held.built) return;
    const gpa = model.gpa;
    const given = model.doc.meshes[at];
    var vertices: std.ArrayListUnmanaged(mesh.Vertex) = .empty;
    defer vertices.deinit(gpa);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(gpa);
    var surfaces: std.ArrayListUnmanaged(mesh.Surface) = .empty;
    defer surfaces.deinit(gpa);
    var materials: std.ArrayListUnmanaged(?u32) = .empty;
    defer materials.deinit(gpa);
    // Whether every part brings its lightmap UVs: one that does not leaves
    // the rest's on top of its own.
    var all_second = true;
    // Bent by a skin where any part names its bones: each vertex's bones
    // beside it, on the first bone where a part names none.
    var skin: std.ArrayListUnmanaged(mesh.SkinVertex) = .empty;
    defer skin.deinit(gpa);
    const skinned = for (given.primitives) |primitive| {
        if (primitive.attributes.JOINTS_0 != null and primitive.attributes.WEIGHTS_0 != null) break true;
    } else false;
    var far_bone = false;

    for (given.primitives) |primitive| {
        if (primitive.mode < 4 or primitive.mode > 6) continue;
        const position_at = primitive.attributes.POSITION orelse continue;
        const positions = try viewOf(model, position_at, "positions");
        if (positions.components != 3) return error.BadModel;
        const base: u32 = @intCast(vertices.items.len);
        const normals: ?View = if (primitive.attributes.NORMAL) |n| try viewOf(model, n, "normals") else null;
        const uvs: ?View = if (primitive.attributes.TEXCOORD_0) |n| try viewOf(model, n, "coordinates") else null;
        const second_uvs: ?View = if (primitive.attributes.TEXCOORD_1) |n| try viewOf(model, n, "second coordinates") else null;
        const colors: ?View = if (primitive.attributes.COLOR_0) |n| try viewOf(model, n, "colours") else null;
        const tangents: ?View = if (primitive.attributes.TANGENT) |n| try viewOf(model, n, "tangents") else null;
        const joints: ?View = if (primitive.attributes.JOINTS_0) |n| try viewOf(model, n, "bones") else null;
        const weights: ?View = if (primitive.attributes.WEIGHTS_0) |n| try viewOf(model, n, "weights") else null;
        if (skinned) try skin.ensureUnusedCapacity(gpa, positions.count);
        try vertices.ensureUnusedCapacity(gpa, positions.count);
        for (0..positions.count) |i| {
            var v: mesh.Vertex = .{ .position = .{ positions.float(i, 0), positions.float(i, 1), positions.float(i, 2) }, .normal = .{ 0, 1, 0 } };
            if (normals) |n| if (i < n.count) {
                v.normal = .{ n.float(i, 0), n.float(i, 1), n.float(i, 2) };
            };
            if (uvs) |n| if (i < n.count) {
                v.uv = .{ n.float(i, 0), n.float(i, 1) };
            };
            if (second_uvs) |n| if (i < n.count) {
                v.uv2 = .{ n.float(i, 0), n.float(i, 1) };
            };
            if (colors) |n| if (i < n.count) {
                const linear = [4]f32{
                    n.float(i, 0),
                    if (n.components > 1) n.float(i, 1) else 1,
                    if (n.components > 2) n.float(i, 2) else 1,
                    if (n.components > 3) n.float(i, 3) else 1,
                };
                const encoded = Color.fromLinear(linear[0], linear[1], linear[2], linear[3]);
                for (encoded.array(), 0..) |value, c| v.color[c] = @intFromFloat(std.math.clamp(value, 0, 1) * 255 + 0.5);
            };
            if (tangents) |n| if (i < n.count and n.components == 4) {
                v.tangent = .{ n.float(i, 0), n.float(i, 1), n.float(i, 2), if (n.float(i, 3) < 0) -1 else 1 };
            };
            vertices.appendAssumeCapacity(v);
            if (skinned) {
                var bones: mesh.SkinVertex = .{};
                if (joints != null and weights != null and i < joints.?.count and i < weights.?.count) {
                    for (0..4) |c| {
                        const joint = if (c < joints.?.components) joints.?.whole(i, c) else 0;
                        const weight = if (c < weights.?.components) weights.?.float(i, c) else 0;
                        if (joint >= mesh.max_bones) {
                            far_bone = true;
                            bones.joints[c] = 0;
                            bones.weights[c] = 0;
                        } else {
                            bones.joints[c] = @intCast(joint);
                            bones.weights[c] = weight;
                        }
                    }
                }
                skin.appendAssumeCapacity(bones.normalized());
            }
        }

        // The corners, as triangles.
        var corners: std.ArrayListUnmanaged(u32) = .empty;
        defer corners.deinit(gpa);
        if (primitive.indices) |n| {
            const view = try viewOf(model, n, "indices");
            try corners.ensureUnusedCapacity(gpa, view.count);
            for (0..view.count) |i| corners.appendAssumeCapacity(view.index(i));
        } else {
            try corners.ensureUnusedCapacity(gpa, positions.count);
            for (0..positions.count) |i| corners.appendAssumeCapacity(@intCast(i));
        }
        const first: u32 = @intCast(indices.items.len);
        switch (primitive.mode) {
            4 => {
                const whole = corners.items.len - corners.items.len % 3;
                for (corners.items[0..whole]) |c| try indices.append(gpa, c + base);
            },
            5 => if (corners.items.len >= 3) for (0..corners.items.len - 2) |i| {
                const a = corners.items[i];
                const b = corners.items[i + 1];
                const c = corners.items[i + 2];
                if (i % 2 == 0) try indices.appendSlice(gpa, &.{ a + base, b + base, c + base }) else try indices.appendSlice(gpa, &.{ b + base, a + base, c + base });
            },
            6 => if (corners.items.len >= 3) for (1..corners.items.len - 1) |i| {
                try indices.appendSlice(gpa, &.{ corners.items[0] + base, corners.items[i] + base, corners.items[i + 1] + base });
            },
            else => unreachable,
        }
        for (indices.items[first..]) |index| if (index >= vertices.items.len) return error.BadModel;
        if (normals == null) try flatten(gpa, &vertices, &indices, if (skinned) &skin else null, base, first);
        // Worked out where the file gives none, or the corners were made
        // apart and lost what it gave.
        if (tangents == null or normals == null) mesh.computeTangentsFrom(vertices.items, indices.items[first..], base);
        const count: u32 = @intCast(indices.items.len - first);
        if (count == 0) continue;
        if (second_uvs == null) all_second = false;
        try surfaces.append(gpa, .{ .first_index = first, .index_count = count });
        try materials.append(gpa, if (primitive.material) |m| if (m < model.materials.len) m else null else null);
    }
    if (surfaces.items.len == 0) try surfaces.append(gpa, .{ .first_index = 0, .index_count = 0 });
    if (surfaces.items.len == 1 and materials.items.len == 0) try materials.append(gpa, null);
    const own_vertices = try vertices.toOwnedSlice(gpa);
    const own_indices = indices.toOwnedSlice(gpa) catch |err| {
        gpa.free(own_vertices);
        return err;
    };
    var built = mesh.Mesh.adopt(own_vertices, own_indices, surfaces.items) catch {
        gpa.free(own_vertices);
        gpa.free(own_indices);
        return error.BadModel;
    };
    errdefer {
        gpa.free(built.vertices);
        gpa.free(built.indices);
    }
    if (far_bone) try model.note("the mesh {s} names a bone past the {d} a skin may have", .{ held.name, mesh.max_bones });
    if (all_second and own_indices.len > 0) {
        built.uv2_texels = brought_uv2_texels;
    } else if (model.unwrap_lightmap and !skinned) {
        // A mesh a skeleton bends is lit from the probes, never a lightmap:
        // and unwrapping would part vertices from their bones.
        try lightmap_uv.unwrap(gpa, &built);
    }
    // Its levels: kept in the model's file of them for this very mesh, or
    // made now.
    const levels = (try lods.read(gpa, model.lod_file, at, lods.hashOf(built.vertices, built.indices), surfaces.items, built.vertices.len)) orelse
        if (model.make_lods) try lods.make(gpa, built.vertices, built.indices, surfaces.items) else try gpa.alloc(mesh.Lod, 0);
    errdefer {
        for (levels) |*level| level.deinit(gpa);
        gpa.free(levels);
    }
    held.skin = try skin.toOwnedSlice(gpa);
    held.surfaces = try surfaces.toOwnedSlice(gpa);
    held.materials = try materials.toOwnedSlice(gpa);
    held.vertices = built.vertices;
    held.indices = built.indices;
    held.uv2_texels = built.uv2_texels;
    held.lods = levels;
    held.built = true;
}

/// A primitive with no normals made flat, as glTF says it is: each of its
/// triangles' corners a vertex of its own, facing the triangle's way.
fn flatten(gpa: Allocator, vertices: *std.ArrayListUnmanaged(mesh.Vertex), indices: *std.ArrayListUnmanaged(u32), skin: ?*std.ArrayListUnmanaged(mesh.SkinVertex), base: u32, first: u32) Allocator.Error!void {
    const corners = try gpa.dupe(u32, indices.items[first..]);
    defer gpa.free(corners);
    const shared = try gpa.dupe(mesh.Vertex, vertices.items[base..]);
    defer gpa.free(shared);
    const shared_bones = if (skin) |held| try gpa.dupe(mesh.SkinVertex, held.items[base..]) else &.{};
    defer gpa.free(shared_bones);
    vertices.shrinkRetainingCapacity(base);
    indices.shrinkRetainingCapacity(first);
    if (skin) |held| held.shrinkRetainingCapacity(base);
    var at: usize = 0;
    while (at + 3 <= corners.len) : (at += 3) {
        var three: [3]mesh.Vertex = .{ shared[corners[at] - base], shared[corners[at + 1] - base], shared[corners[at + 2] - base] };
        const a = Vec3.fromArray(three[0].position);
        const b = Vec3.fromArray(three[1].position);
        const c = Vec3.fromArray(three[2].position);
        const facing = (b.sub(a).cross(c.sub(a))).tryNorm() orelse Vec3.unit_y;
        for (&three) |*v| v.normal = facing.array();
        const start: u32 = @intCast(vertices.items.len);
        try vertices.appendSlice(gpa, &three);
        try indices.appendSlice(gpa, &.{ start, start + 1, start + 2 });
        if (skin) |held| for (corners[at..][0..3]) |corner| try held.append(gpa, shared_bones[corner - base]);
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A triangle facing `+z`, in a `.gltf` whose buffer is a data URI: its
/// positions, then its indices.
fn triangleGltf(gpa: Allocator, extra_nodes: []const u8) ![]u8 {
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const indices = [_]u16{ 0, 1, 2, 0 };
    var raw: [@sizeOf(@TypeOf(positions)) + @sizeOf(@TypeOf(indices))]u8 = undefined;
    @memcpy(raw[0..36], std.mem.asBytes(&positions));
    @memcpy(raw[36..], std.mem.asBytes(&indices));
    var coded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&coded, &raw);
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "scene": 0,
        \\  "scenes": [{{ "nodes": [0] }}],
        \\  "nodes": [{{ "name": "Holder", "translation": [1, 2, 3], "children": [1] }}, {{ "name": "Tri", "mesh": 0, "scale": [2, 2, 2] }}{s}],
        \\  "meshes": [{{ "name": "Triangle", "primitives": [{{ "attributes": {{ "POSITION": 0 }}, "indices": 1, "material": 0 }}] }}],
        \\  "materials": [{{ "name": "Red", "pbrMetallicRoughness": {{ "baseColorFactor": [0.5, 0, 0, 1] }}, "alphaMode": "MASK", "alphaCutoff": 0.25, "doubleSided": true }}],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR" }}
        \\  ],
        \\  "bufferViews": [{{ "buffer": 0, "byteLength": 36 }}, {{ "buffer": 0, "byteOffset": 36, "byteLength": 6 }}],
        \\  "buffers": [{{ "byteLength": {d}, "uri": "data:application/octet-stream;base64,{s}" }}],
        \\  "cameras": [{{ "type": "perspective", "perspective": {{ "yfov": 0.8, "znear": 0.1 }} }}],
        \\  "extensions": {{ "KHR_lights_punctual": {{ "lights": [{{ "type": "directional", "color": [1, 0.5, 0.5], "intensity": 3 }}] }} }}
        \\}}
    , .{ extra_nodes, raw.len, coded });
}

test "a .gltf's triangle, its material, its nodes, a camera and a light are read" {
    const text = try triangleGltf(testing.allocator, ", { \"name\": \"Eye\", \"camera\": 0 }, { \"name\": \"Sun\", \"extensions\": { \"KHR_lights_punctual\": { \"light\": 0 } } }");
    defer testing.allocator.free(text);
    var model = try read(testing.allocator, text, null);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    const tri = model.meshes[0];
    try testing.expectEqual(@as(usize, 3), tri.indices.len);
    // No normals given: worked out flat, facing +z; no pictures' places
    // either, so a tangent any way square to it.
    try testing.expectEqual([3]f32{ 0, 0, 1 }, tri.vertices[0].normal);
    try testing.expectEqual(@as(f32, 0), tri.vertices[0].tangent[2]);
    try testing.expectEqual(@as(f32, 1), @abs(tri.vertices[0].tangent[0]) + @abs(tri.vertices[0].tangent[1]));
    try testing.expectEqual(@as(?u32, 0), tri.materials[0]);

    const red = model.materials[0];
    try testing.expectApproxEqAbs(@as(f32, 0.735357), red.look.albedo_color.r, 0.00001);
    try testing.expectEqual(Material3D.Transparency.scissor, red.look.transparency);
    try testing.expectEqual(@as(f32, 0.25), red.look.alpha_scissor_threshold);
    try testing.expectEqual(Material3D.Cull.disabled, red.look.cull);

    try testing.expectEqualSlices(u32, &.{0}, model.roots);
    try testing.expectEqualStrings("Holder", model.nodes[0].name);
    try testing.expect(model.nodes[0].transform.translation.approxEql(.init(1, 2, 3)));
    try testing.expectEqual(@as(?u32, 0), model.nodes[1].mesh);
    try testing.expectEqual(@as(?u32, 0), model.nodes[2].camera);
    try testing.expectApproxEqAbs(@as(f32, 0.8), model.cameras[0].fov, 1e-6);
    try testing.expectEqual(Light.Kind.directional, model.lights[model.nodes[3].light.?].kind);
    try testing.expectEqual(@as(f32, 3), model.lights[0].intensity);
    try testing.expectApproxEqAbs(@as(f32, 0.735357), model.lights[0].color.g, 0.00001);
}

test "a material's metal, roughness, normal map and occlusion are read, each picture by its index" {
    var model = try read(testing.allocator,
        \\{ "asset": { "version": "2.0" },
        \\  "materials": [{ "name": "Brass",
        \\    "pbrMetallicRoughness": { "metallicFactor": 0.75, "roughnessFactor": 0.25, "metallicRoughnessTexture": { "index": 0 } },
        \\    "normalTexture": { "index": 1, "scale": 0.5 },
        \\    "occlusionTexture": { "index": 2, "strength": 0.8 } },
        \\    { "name": "Plain" }],
        \\  "textures": [{ "source": 0 }, { "source": 1 }, { "source": 2 }],
        \\  "images": [{ "uri": "surface.png" }, { "uri": "normal.png" }, { "uri": "occlusion.png" }] }
    , null);
    defer model.deinit();
    const brass = model.materials[0];
    try testing.expectEqual(@as(f32, 0.75), brass.look.metallic);
    try testing.expectEqual(@as(f32, 0.25), brass.look.roughness);
    try testing.expectEqual(@as(f32, 0.5), brass.look.normal_scale);
    try testing.expectEqual(@as(f32, 0.8), brass.look.occlusion_strength);
    try testing.expectEqual(@as(u32, 0), brass.metallic_roughness.?.image);
    try testing.expectEqual(@as(u32, 1), brass.normal.?.image);
    try testing.expectEqual(@as(u32, 2), brass.occlusion.?.image);
    // glTF's own first values: all metal, all rough.
    const plain = model.materials[1];
    try testing.expectEqual(@as(f32, 1), plain.look.metallic);
    try testing.expectEqual(@as(f32, 1), plain.look.roughness);
    try testing.expect(plain.normal == null);
}

test "a .glb's document and binary part are read, and a strip and a fan become triangles" {
    // Four corners of a square, as a strip and as a fan.
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0 };
    const document =
        \\{"asset":{"version":"2.0"},"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":0},"mode":5},{"attributes":{"POSITION":0,"NORMAL":0},"mode":6}]}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"}],"bufferViews":[{"buffer":0,"byteLength":48}],"buffers":[{"byteLength":48}],"nodes":[{"mesh":0}]}
    ;
    const padded_text = (document.len + 3) / 4 * 4;
    var glb: std.ArrayList(u8) = .empty;
    defer glb.deinit(testing.allocator);
    const total: u32 = @intCast(12 + 8 + padded_text + 8 + 48);
    try glb.appendSlice(testing.allocator, "glTF");
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&@as(u32, 2)));
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&total));
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&@as(u32, @intCast(padded_text))));
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&@as(u32, 0x4E4F534A)));
    try glb.appendSlice(testing.allocator, document);
    try glb.appendNTimes(testing.allocator, ' ', padded_text - document.len);
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&@as(u32, 48)));
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&@as(u32, 0x004E4942)));
    try glb.appendSlice(testing.allocator, std.mem.asBytes(&positions));

    var model = try read(testing.allocator, glb.items, null);
    defer model.deinit();
    const square = model.meshes[0];
    // Two triangles each, two surfaces, with no scene: the node is a root.
    try testing.expectEqual(@as(usize, 12), square.indices.len);
    try testing.expectEqual(@as(usize, 2), square.surfaces.len);
    try testing.expectEqual(@as(u32, 6), square.surfaces[1].first_index);
    try testing.expectEqualSlices(u32, &.{0}, model.roots);
    // Each triangle of the strip turns the same way.
    for (0..2) |t| {
        const v = square.vertices;
        const i = square.indices[t * 3 ..][0..3];
        const a = Vec3.fromArray(v[i[0]].position);
        const b = Vec3.fromArray(v[i[1]].position);
        const c = Vec3.fromArray(v[i[2]].position);
        try testing.expect(b.sub(a).cross(c.sub(a)).z > 0);
    }
}

/// Two bones up the y axis bending a square, and an animation of them: a
/// turn, straight; a place, stepped; a size, along a cubic spline. Its
/// weights are normalized shorts, and its skin's inverse bind matrices a
/// MAT4 accessor.
pub fn skinnedGltf(gpa: Allocator) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    const positions = [_]f32{ -0.5, 0, 0, 0.5, 0, 0, 0.5, 2, 0, -0.5, 2, 0 };
    const joints = [_]u8{ 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    const weights = [_]u16{ 65535, 0, 0, 0, 65535, 0, 0, 0, 32767, 32768, 0, 0, 0, 0, 0, 0 };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    // Column-major: the first bone at the origin, the second one up.
    const binds = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1 };
    const times = [_]f32{ 0, 1 };
    const half = std.math.sqrt1_2;
    const turns = [_]f32{ 0, 0, 0, 1, 0, 0, half, half };
    const places = [_]f32{ 0, 0, 0, 0, 3, 0 };
    // In-tangent, value, out-tangent, for each of the two keys.
    const sizes = [_]f32{ 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 2, 2, 2, 0, 0, 0 };
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&positions)); // 0, 48
    try raw.appendSlice(gpa, &joints); // 48, 16
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&weights)); // 64, 32
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&indices)); // 96, 12
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&binds)); // 108, 128
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&times)); // 236, 8
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&turns)); // 244, 32
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&places)); // 276, 24
    try raw.appendSlice(gpa, std.mem.sliceAsBytes(&sizes)); // 300, 72
    const coded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(raw.items.len));
    defer gpa.free(coded);
    _ = std.base64.standard.Encoder.encode(coded, raw.items);
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "extensionsRequired": ["KHR_mesh_quantization"],
        \\  "scene": 0,
        \\  "scenes": [{{ "nodes": [0] }}],
        \\  "nodes": [
        \\    {{ "name": "Armature", "children": [1, 3] }},
        \\    {{ "name": "Lower", "children": [2] }},
        \\    {{ "name": "Upper", "translation": [0, 1, 0] }},
        \\    {{ "name": "Body", "mesh": 0, "skin": 0 }}
        \\  ],
        \\  "meshes": [{{ "name": "Square", "primitives": [{{ "attributes": {{ "POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2 }}, "indices": 3 }}] }}],
        \\  "skins": [{{ "name": "Bones", "inverseBindMatrices": 4, "joints": [1, 2] }}],
        \\  "animations": [{{ "name": "Bend",
        \\    "channels": [
        \\      {{ "sampler": 0, "target": {{ "node": 2, "path": "rotation" }} }},
        \\      {{ "sampler": 1, "target": {{ "node": 1, "path": "translation" }} }},
        \\      {{ "sampler": 2, "target": {{ "node": 2, "path": "scale" }} }},
        \\      {{ "sampler": 0, "target": {{ "node": 3, "path": "weights" }} }}
        \\    ],
        \\    "samplers": [
        \\      {{ "input": 5, "output": 6 }},
        \\      {{ "input": 5, "output": 7, "interpolation": "STEP" }},
        \\      {{ "input": 5, "output": 8, "interpolation": "CUBICSPLINE" }}
        \\    ] }}],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5121, "count": 4, "type": "VEC4" }},
        \\    {{ "bufferView": 2, "componentType": 5123, "normalized": true, "count": 4, "type": "VEC4" }},
        \\    {{ "bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR" }},
        \\    {{ "bufferView": 4, "componentType": 5126, "count": 2, "type": "MAT4" }},
        \\    {{ "bufferView": 5, "componentType": 5126, "count": 2, "type": "SCALAR" }},
        \\    {{ "bufferView": 6, "componentType": 5126, "count": 2, "type": "VEC4" }},
        \\    {{ "bufferView": 7, "componentType": 5126, "count": 2, "type": "VEC3" }},
        \\    {{ "bufferView": 8, "componentType": 5126, "count": 6, "type": "VEC3" }}
        \\  ],
        \\  "bufferViews": [
        \\    {{ "buffer": 0, "byteOffset": 0, "byteLength": 48 }}, {{ "buffer": 0, "byteOffset": 48, "byteLength": 16 }},
        \\    {{ "buffer": 0, "byteOffset": 64, "byteLength": 32 }}, {{ "buffer": 0, "byteOffset": 96, "byteLength": 12 }},
        \\    {{ "buffer": 0, "byteOffset": 108, "byteLength": 128 }}, {{ "buffer": 0, "byteOffset": 236, "byteLength": 8 }},
        \\    {{ "buffer": 0, "byteOffset": 244, "byteLength": 32 }}, {{ "buffer": 0, "byteOffset": 276, "byteLength": 24 }},
        \\    {{ "buffer": 0, "byteOffset": 300, "byteLength": 72 }}
        \\  ],
        \\  "buffers": [{{ "byteLength": {d}, "uri": "data:application/octet-stream;base64,{s}" }}]
        \\}}
    , .{ raw.items.len, coded });
}

test "a skin's bones, its vertices' weights and an animation's channels are read" {
    const text = try skinnedGltf(testing.allocator);
    defer testing.allocator.free(text);
    var model = try read(testing.allocator, text, null);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.skins.len);
    const bones = model.skins[0];
    try testing.expectEqualStrings("Bones", bones.name);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, bones.joints);
    try testing.expect(bones.inverse_binds[1].translation().approxEql(.init(0, -1, 0)));
    try testing.expectEqual(@as(?u32, 0), model.nodes[3].skin);

    // Each vertex's bones, the weights made to sum to one - with no normals,
    // each triangle's corners made apart, and their bones with them.
    const square = model.meshes[0];
    try testing.expectEqual(@as(usize, 6), square.skin.len);
    try testing.expectEqual([4]u8{ 0, 1, 0, 0 }, square.skin[0].joints);
    try testing.expectEqual(@as(f32, 1), square.skin[0].weights[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), square.skin[2].weights[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), square.skin[2].weights[0] + square.skin[2].weights[1], 0.0001);
    try testing.expectEqual(square.skin[2], square.skin[4]);
    // A vertex with no weight hangs from its first bone.
    try testing.expectEqual([4]f32{ 1, 0, 0, 0 }, square.skin[5].weights);

    // Three channels; the morph target's weights are left out, and said so.
    const bend = model.animations[0];
    try testing.expectEqualStrings("Bend", bend.name);
    try testing.expectEqual(@as(f32, 1), bend.length);
    try testing.expectEqual(@as(usize, 3), bend.channels.len);
    try testing.expectEqual(Channel.Path.rotation, bend.channels[0].path);
    try testing.expectEqual(Channel.Interpolation.linear, bend.channels[0].interpolation);
    try testing.expectEqual(@as(usize, 8), bend.channels[0].values.len);
    try testing.expectEqual(Channel.Interpolation.step, bend.channels[1].interpolation);
    try testing.expectEqual(@as(u32, 1), bend.channels[1].node);
    try testing.expectEqual(Channel.Interpolation.cubic, bend.channels[2].interpolation);
    try testing.expectEqual(@as(usize, 18), bend.channels[2].values.len);
    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
}

test "what is not glTF 2.0 is refused, and a number past what it names too" {
    try testing.expectError(error.BadModel, read(testing.allocator, "not json", null));
    try testing.expectError(error.UnsupportedModel, read(testing.allocator, "{\"asset\":{\"version\":\"1.0\"}}", null));
    try testing.expectError(error.UnsupportedModel, read(testing.allocator, "{\"asset\":{\"version\":\"2.0\"},\"extensionsRequired\":[\"KHR_draco_mesh_compression\"]}", null));
    try testing.expectError(error.BadModel, read(testing.allocator, "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":4}]}", null));
}
