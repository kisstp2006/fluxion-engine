// SPDX-License-Identifier: BSD-3-Clause

//! The 3D layer: every `MeshInstance3D` a camera sees, drawn with a depth
//! test before the 2D world and the interface go over it.
//!
//! What is drawn is gathered each frame, left out where it is off the
//! camera's frustum, and sorted: solid meshes grouped by how they are drawn
//! - one draw for every instance of a mesh with the same picture and the
//! same sides culled - then see-through ones back to front, after them. Each
//! mesh is lit by the first `DirectionalLight3D` and a little light from
//! everywhere; a `Material3D` that is `unshaded` is its colour as it is.
//!
//! The depth is a texture of the renderer's at each size it draws at. The
//! shader is the engine's, in fluxion-shader's language: one source for
//! every backend.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const App = @import("../App.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const mesh = @import("mesh.zig");
const View3D = @import("view3d.zig").View3D;

const MeshInstance3D = components3d.MeshInstance3D;
const PrimitiveMesh3D = components3d.PrimitiveMesh3D;
const Material3D = components3d.Material3D;
const DirectionalLight3D = components3d.DirectionalLight3D;

const log = std.log.scoped(.fluxion_engine);

/// What every draw of a frame tells the shader, as its `Frame` block says:
/// `std140`, a hundred and twelve bytes.
const Frame = extern struct {
    view_projection: math.Mat4,
    /// Toward the light, and nought in `w`; all nought for no light.
    light_direction: [4]f32,
    /// Its colour times its energy.
    light_color: [4]f32,
    ambient: [4]f32,
};

/// One mesh drawn: read by the shader per instance.
const Instance = extern struct {
    /// Its own space to the world's, column by column.
    model: [4][4]f32,
    /// Its normals to the world's: the model's inverse turned over, which
    /// keeps them square to a surface its scale has stretched.
    normal: [3][3]f32,
    albedo: [4]f32,
    /// The picture's scale, then its offset.
    uv: [4]f32,
    /// One where it is unshaded.
    look: [4]f32,
};

/// The light from everywhere a lit mesh gets on top of its light's.
pub const ambient: Color = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1 };

/// What lights a world that has no light of its own, where it is asked for:
/// an editor's view of a scene with none.
pub const preview_light: struct { toward: math.Vec3, color: Color } = .{
    .toward = .init(0.4, 0.8, 0.45),
    .color = .{ .r = 0.9, .g = 0.9, .b = 0.88, .a = 1 },
};

const source =
    \\attribute vec3 VERTEX_POSITION : 0;
    \\attribute vec3 VERTEX_NORMAL : 1;
    \\attribute vec2 VERTEX_UV : 2;
    \\attribute vec4 MODEL_0 : 3;
    \\attribute vec4 MODEL_1 : 4;
    \\attribute vec4 MODEL_2 : 5;
    \\attribute vec4 MODEL_3 : 6;
    \\attribute vec3 TURN_0 : 7;
    \\attribute vec3 TURN_1 : 8;
    \\attribute vec3 TURN_2 : 9;
    \\attribute vec4 ALBEDO_COLOR : 10;
    \\attribute vec4 UV_PLACE : 11;
    \\attribute vec4 LOOK : 12;
    \\
    \\varying vec3 WORLD_NORMAL;
    \\varying vec2 UV;
    \\varying vec4 ALBEDO;
    \\varying float UNSHADED;
    \\
    \\uniform Frame : 0 {
    \\    mat4 VIEW_PROJECTION;
    \\    vec4 LIGHT_DIRECTION;
    \\    vec4 LIGHT_COLOR;
    \\    vec4 AMBIENT;
    \\}
    \\
    \\texture2d ALBEDO_TEXTURE : 0;
    \\
    \\vertex {
    \\    vec4 world = MODEL_0 * VERTEX_POSITION.x + MODEL_1 * VERTEX_POSITION.y + MODEL_2 * VERTEX_POSITION.z + MODEL_3;
    \\    WORLD_NORMAL = TURN_0 * VERTEX_NORMAL.x + TURN_1 * VERTEX_NORMAL.y + TURN_2 * VERTEX_NORMAL.z;
    \\    UV = VERTEX_UV * UV_PLACE.xy + UV_PLACE.zw;
    \\    ALBEDO = ALBEDO_COLOR;
    \\    UNSHADED = LOOK.x;
    \\    position = VIEW_PROJECTION * world;
    \\}
    \\
    \\fragment {
    \\    vec4 albedo = sample(ALBEDO_TEXTURE, UV) * ALBEDO;
    \\    float facing = max(dot(normalize(WORLD_NORMAL), LIGHT_DIRECTION.xyz), 0.0);
    \\    vec3 lit = albedo.rgb * (AMBIENT.rgb + LIGHT_COLOR.rgb * facing);
    \\    target = vec4(mix(lit, albedo.rgb, UNSHADED), albedo.a);
    \\}
;

/// Which attributes are the mesh's own; the rest are per instance.
fn bufferOf(name: []const u8) u32 {
    return if (std.mem.startsWith(u8, name, "VERTEX_")) 0 else 1;
}

fn vertexFormat(ty: shader.Type) ?rhi.VertexFormat {
    return switch (ty) {
        .float => .float,
        .vec2 => .float2,
        .vec3 => .float3,
        .vec4 => .float4,
        else => null,
    };
}

/// How a mesh is drawn, past its picture: which sides, and whether over
/// what is behind it.
const Way = struct {
    cull: Material3D.Cull,
    transparency: Material3D.Transparency,

    const count = 6;

    fn index(self: Way) usize {
        return @as(usize, @intFromEnum(self.cull)) * 2 + @intFromEnum(self.transparency);
    }

    fn of(at: usize) Way {
        return .{ .cull = @enumFromInt(at / 2), .transparency = @enumFromInt(at % 2) };
    }
};

/// What is drawn of one mesh, before it is sorted.
const Item = struct {
    way: u8,
    transparent: bool,
    gpu: mesh.Gpu,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    /// How far in front of the camera its middle is.
    depth: f32,
    /// Where its `Instance` is in `gathered`.
    instance: u32,

    /// Solid ones first, grouped by how they are drawn and then nearest
    /// first; see-through ones after, furthest first.
    fn before(_: void, a: Item, b: Item) bool {
        if (a.transparent != b.transparent) return !a.transparent;
        if (a.transparent) return a.depth > b.depth;
        if (a.way != b.way) return a.way < b.way;
        const at = keyOf(a);
        const bt = keyOf(b);
        if (at != bt) return at < bt;
        return a.depth < b.depth;
    }

    fn keyOf(item: Item) u128 {
        return @as(u128, item.texture.toInt()) << 64 | item.gpu.vertices.toInt();
    }

    /// Whether `b` is drawn in the same draw as `a`.
    fn joins(a: Item, b: Item) bool {
        return a.way == b.way and std.meta.eql(a.texture, b.texture) and std.meta.eql(a.sampler, b.sampler) and std.meta.eql(a.gpu, b.gpu);
    }
};

/// A depth texture at one size.
const Depth = struct {
    width: u32,
    height: u32,
    texture: rhi.Texture,
    /// The frame it was last drawn with, by `Renderer3D.clock`.
    used: u64,
};

/// Lighting a draw asks for beyond the world's own.
pub const Lighting = struct {
    /// Light a world that has no `DirectionalLight3D` with `preview_light`.
    preview: bool = false,
};

pub const Renderer3D = struct {
    device: *rhi.Device,
    /// Null where the device draws into no depth format, and nothing 3D is
    /// drawn.
    depth_format: ?rhi.Format,
    module: ?shader.Module = null,
    gpu: rhi.Shader = .none,
    pipelines: [Way.count]rhi.Pipeline = @splat(.none),
    frame: rhi.Buffer,
    instances: rhi.Buffer,
    /// How many instances the buffer has room for. Grown, never shrunk.
    capacity: u32,
    white: rhi.Texture,
    depths: std.ArrayList(Depth) = .empty,
    /// The depth the last draw drew into, for what goes over it with a
    /// depth test.
    last_depth: ?rhi.Texture = null,
    clock: u64 = 0,

    gathered: std.ArrayList(Instance) = .empty,
    items: std.ArrayList(Item) = .empty,
    staging: std.ArrayList(Instance) = .empty,

    /// What the last draw drew: meshes, and the draws they took.
    drawn: u32 = 0,
    draw_calls: u32 = 0,
    /// The meshes it left out for being off the camera's frustum.
    culled: u32 = 0,

    const initial_capacity = 64;

    pub fn init(gpa: Allocator, device: *rhi.Device) !Renderer3D {
        const frame = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Frame), .dynamic = true, .label = "3D frame" });
        errdefer device.destroyBuffer(frame);
        const instances = try device.createBuffer(.{ .kind = .vertex, .size = initial_capacity * @sizeOf(Instance), .dynamic = true, .label = "3D instances" });
        errdefer device.destroyBuffer(instances);
        const white_texel = [4]u8{ 255, 255, 255, 255 };
        const white = try device.createTexture(.{ .width = 1, .height = 1, .data = &white_texel, .label = "no albedo" });
        errdefer device.destroyTexture(white);
        var self: Renderer3D = .{
            .device = device,
            .depth_format = depthFormat(device),
            .frame = frame,
            .instances = instances,
            .capacity = initial_capacity,
            .white = white,
        };
        if (self.depth_format == null) {
            log.warn("the {t} backend draws into no depth format here: nothing 3D is drawn", .{device.info().backend});
            return self;
        }
        self.compile(gpa) catch |err| {
            if (self.module) |*held| held.deinit();
            self.module = null;
            return err;
        };
        return self;
    }

    /// The most precise depth the device draws into.
    fn depthFormat(device: *rhi.Device) ?rhi.Format {
        for ([_]rhi.Format{ .depth32_float, .depth24_stencil8, .depth16_unorm }) |format| {
            if (device.caps().formatSupport(format).render_target) return format;
        }
        return null;
    }

    fn compile(self: *Renderer3D, gpa: Allocator) !void {
        const device = self.device;
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        self.module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("the 3D shader: {s}", .{said.written()});
            return err;
        };
        const module = &self.module.?;
        const frame_block = module.block("Frame").?;
        inline for (.{ .{ "VIEW_PROJECTION", "view_projection" }, .{ "LIGHT_DIRECTION", "light_direction" }, .{ "LIGHT_COLOR", "light_color" }, .{ "AMBIENT", "ambient" } }) |pair| {
            std.debug.assert(frame_block.offsetOf(pair[0]).? == @offsetOf(Frame, pair[1]));
        }
        std.debug.assert(frame_block.size == @sizeOf(Frame));

        self.gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "3D",
        });

        var attributes: [16]rhi.VertexAttribute = undefined;
        var strides: [2]u32 = @splat(0);
        for (module.attributes, 0..) |a, i| {
            const buffer = bufferOf(a.name);
            const format = vertexFormat(a.ty).?;
            attributes[i] = .{ .location = a.location, .format = format, .offset = strides[buffer], .buffer = buffer };
            strides[buffer] += format.size();
        }
        std.debug.assert(strides[0] == @sizeOf(mesh.Vertex));
        std.debug.assert(strides[1] == @sizeOf(Instance));

        for (&self.pipelines, 0..) |*pipeline, at| {
            const way: Way = .of(at);
            const see_through = way.transparency == .alpha;
            pipeline.* = try device.createPipeline(.{
                .shader = self.gpu,
                .attributes = attributes[0..module.attributes.len],
                .buffers = &.{
                    .{ .stride = strides[0] },
                    .{ .stride = strides[1], .step = .instance },
                },
                .topology = .triangles,
                .blend = if (see_through) .alpha else .solid,
                // See-through meshes are tested against the solid ones and
                // write no depth: one behind another still shows through.
                .depth = .{ .test_enabled = true, .write = !see_through, .compare = .less },
                .cull = switch (way.cull) {
                    .back => .back,
                    .front => .front,
                    .disabled => .none,
                },
                .front_face = .ccw,
                .depth_format = self.depth_format,
                .uniform_blocks = (try module.uniformBlockNames()).?,
                .textures = (try module.textureNames()).?,
                .label = "3D",
            });
        }
    }

    pub fn deinit(self: *Renderer3D, gpa: Allocator) void {
        for (self.pipelines) |pipeline| if (!pipeline.isNone()) self.device.destroyPipeline(pipeline);
        if (!self.gpu.isNone()) self.device.destroyShader(self.gpu);
        if (self.module) |*held| held.deinit();
        for (self.depths.items) |depth| self.device.destroyTexture(depth.texture);
        self.depths.deinit(gpa);
        self.device.destroyBuffer(self.frame);
        self.device.destroyBuffer(self.instances);
        self.device.destroyTexture(self.white);
        self.gathered.deinit(gpa);
        self.items.deinit(gpa);
        self.staging.deinit(gpa);
        self.* = undefined;
    }

    /// The depth texture at a size, made the first time it is drawn at.
    fn depthAt(self: *Renderer3D, gpa: Allocator, width: u32, height: u32) !rhi.Texture {
        for (self.depths.items) |*depth| {
            if (depth.width == width and depth.height == height) {
                depth.used = self.clock;
                return depth.texture;
            }
        }
        const texture = try self.device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.depth_format.?,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D depth",
        });
        errdefer self.device.destroyTexture(texture);
        try self.depths.append(gpa, .{ .width = width, .height = height, .texture = texture, .used = self.clock });
        return texture;
    }

    /// One more frame: a depth texture no draw has used for a few is let
    /// go - a window dragged bigger leaves every size it passed through.
    pub fn tick(self: *Renderer3D) void {
        self.clock += 1;
        var at: usize = 0;
        while (at < self.depths.items.len) {
            const depth = self.depths.items[at];
            if (depth.used + 3 < self.clock) {
                if (self.last_depth) |last| if (std.meta.eql(last, depth.texture)) {
                    self.last_depth = null;
                };
                self.device.destroyTexture(depth.texture);
                _ = self.depths.swapRemove(at);
            } else at += 1;
        }
    }

    /// Draw the 3D world through `view` into `into`, which is `width` by
    /// `height` pixels: cleared to `clear` first, or drawn over as it is
    /// with null.
    pub fn draw(self: *Renderer3D, app: *App, into: rhi.RenderTarget, width: u32, height: u32, view: View3D, clear: ?Color, lighting: Lighting) !void {
        self.drawn = 0;
        self.draw_calls = 0;
        self.culled = 0;
        if (width == 0 or height == 0) return;
        const gpa = app.gpa;
        const device = self.device;
        const clip = device.clip();
        const view_projection = view.matrix(clip);

        if (self.depth_format == null) {
            if (clear) |color| try clearOnly(device, into, color);
            return;
        }

        try self.gather(app, view, view_projection, clip);
        std.mem.sort(Item, self.items.items, {}, Item.before);
        self.staging.clearRetainingCapacity();
        try self.staging.ensureTotalCapacity(gpa, self.items.items.len);
        for (self.items.items) |item| self.staging.appendAssumeCapacity(self.gathered.items[item.instance]);
        try self.upload(gpa);

        var frame: Frame = .{
            .view_projection = view_projection,
            .light_direction = @splat(0),
            .light_color = @splat(0),
            .ambient = ambient.array(),
        };
        if (lightOf(app)) |light| {
            frame.light_direction = .{ light.toward.x, light.toward.y, light.toward.z, 0 };
            frame.light_color = light.color;
        } else if (lighting.preview) {
            const toward = preview_light.toward.norm();
            frame.light_direction = .{ toward.x, toward.y, toward.z, 0 };
            frame.light_color = preview_light.color.array();
        }
        try device.updateBuffer(self.frame, 0, std.mem.asBytes(&frame));

        const depth = try self.depthAt(gpa, width, height);
        self.last_depth = depth;
        const list = device.begin();
        try list.beginPass(.{
            .color = .{
                .target = into,
                .load = if (clear != null) .clear else .load,
                .clear_color = if (clear) |color| color.array() else .{ 0, 0, 0, 1 },
            },
            .depth = .{ .texture = depth },
        });
        try list.setViewport(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
        const items = self.items.items;
        var start: usize = 0;
        while (start < items.len) {
            var end = start + 1;
            while (end < items.len and Item.joins(items[start], items[end])) end += 1;
            const first = items[start];
            try list.setPipeline(self.pipelines[first.way]);
            try list.setUniformBuffer(0, self.frame);
            try list.setTexture(0, first.texture, first.sampler);
            try list.setVertexBuffer(0, first.gpu.vertices, 0);
            try list.setVertexBuffer(1, self.instances, @intCast(start * @sizeOf(Instance)));
            try list.setIndexBuffer(first.gpu.indices, .u32);
            try list.drawIndexed(.{ .index_count = first.gpu.index_count, .instance_count = @intCast(end - start) });
            self.draw_calls += 1;
            start = end;
        }
        try list.endPass();
        try device.submit();
        self.drawn = @intCast(items.len);
    }

    /// What every mesh the camera sees is drawn as, unsorted.
    fn gather(self: *Renderer3D, app: *App, view: View3D, view_projection: math.Mat4, clip: math.Clip) !void {
        const gpa = app.gpa;
        self.gathered.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        const frustum: math.Frustum = .fromViewProjection(view_projection, clip);
        const alpha = app.time.alpha();
        const forward = view.forward();

        var it = try ecs.Query(.{ Transform3D, MeshInstance3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(Transform3D), chunk.slice(MeshInstance3D), chunk.entities) |local, instance, entity| {
                if (instance.layers & view.cull_mask == 0) continue;
                const looks = app.inherited.of(gpa, &app.world, entity);
                if (!looks.visible) continue;
                const kept: *mesh.Kept = if (app.world.get(entity, PrimitiveMesh3D)) |shape|
                    try app.meshes.primitive(gpa, shape.primitive())
                else
                    app.meshes.keptOf(instance.mesh) orelse continue;
                if (kept.mesh.indices.len == 0) continue;
                const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, alpha) orelse continue;
                const model = placed.matrix();
                const bounds = kept.mesh.bounds.transformed(model);
                if (frustum.testAabb(bounds) == .outside) {
                    self.culled += 1;
                    continue;
                }
                kept.used = app.meshes.clock;
                const gpu = try kept.uploaded(self.device);

                const look = app.world.get(entity, Material3D) orelse &Material3D{};
                var texture = self.white;
                var sampler = app.assets.samplerFor(.linear, .repeat);
                if (!look.albedo_texture.isNone()) if (app.assets.get(look.albedo_texture)) |held| {
                    texture = held.gpu;
                    sampler = app.assets.samplerFor(held.filter, .repeat);
                };
                const turn = model.normalMatrix() orelse math.Mat3.identity;
                const tint = looks.tint(look.albedo_color);
                const at: u32 = @intCast(self.gathered.items.len);
                try self.gathered.append(gpa, .{
                    .model = .{ model.cols[0].array(), model.cols[1].array(), model.cols[2].array(), model.cols[3].array() },
                    .normal = .{ turn.cols[0].array(), turn.cols[1].array(), turn.cols[2].array() },
                    .albedo = tint.array(),
                    .uv = .{ look.uv_scale.x, look.uv_scale.y, look.uv_offset.x, look.uv_offset.y },
                    .look = .{ if (look.unshaded) 1 else 0, 0, 0, 0 },
                });
                const way: Way = .{ .cull = look.cull, .transparency = look.transparency };
                try self.items.append(gpa, .{
                    .way = @intCast(way.index()),
                    .transparent = look.transparency == .alpha,
                    .gpu = gpu,
                    .texture = texture,
                    .sampler = sampler,
                    .depth = bounds.center().sub(view.position).dot(forward),
                    .instance = at,
                });
            }
        }
    }

    /// The sorted instances into the buffer, grown to hold them.
    fn upload(self: *Renderer3D, gpa: Allocator) !void {
        _ = gpa;
        const count: u32 = @intCast(self.staging.items.len);
        if (count == 0) return;
        if (count > self.capacity) {
            var room = self.capacity;
            while (room < count) room *= 2;
            const grown = try self.device.createBuffer(.{ .kind = .vertex, .size = room * @sizeOf(Instance), .dynamic = true, .label = "3D instances" });
            self.device.destroyBuffer(self.instances);
            self.instances = grown;
            self.capacity = room;
        }
        try self.device.updateBuffer(self.instances, 0, std.mem.sliceAsBytes(self.staging.items));
    }
};

/// The first `DirectionalLight3D`'s way toward it and its colour.
fn lightOf(app: *App) ?struct { toward: math.Vec3, color: [4]f32 } {
    var it = ecs.Query(.{ Transform3D, DirectionalLight3D }).over(&app.world) catch return null;
    while (it.next()) |chunk| {
        for (chunk.slice(DirectionalLight3D), chunk.entities) |light, entity| {
            if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
            const placed = app.drawnTransform3D(entity) orelse continue;
            const toward = placed.back().tryNorm() orelse continue;
            const color = light.color;
            return .{ .toward = toward, .color = .{ color.r * light.energy, color.g * light.energy, color.b * light.energy, 1 } };
        }
    }
    return null;
}

/// Clear a target and draw nothing: a device with no depth.
fn clearOnly(device: *rhi.Device, into: rhi.RenderTarget, color: Color) !void {
    const list = device.begin();
    try list.beginPass(.{ .color = .{ .target = into, .clear_color = color.array() } });
    try list.endPass();
    try device.submit();
}

test "an instance and the frame are laid out as the shader reads them" {
    try testing.expectEqual(@as(usize, 112), @sizeOf(Frame));
    try testing.expectEqual(@as(usize, 148), @sizeOf(Instance));
    try testing.expectEqual(@as(usize, 32), @sizeOf(mesh.Vertex));
    for (0..Way.count) |at| try testing.expectEqual(at, Way.of(at).index());
}
