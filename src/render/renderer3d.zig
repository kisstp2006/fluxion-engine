// SPDX-License-Identifier: BSD-3-Clause

//! The 3D layer: every `MeshInstance3D` a camera sees, lit as real surfaces
//! are, drawn with a depth test before the 2D world and the interface go
//! over it.
//!
//! What is drawn is gathered each frame, surface by surface, left out where
//! its mesh is off the camera's frustum, and sorted: solid surfaces grouped
//! by how they are drawn - one draw for every instance of a surface with the
//! same shader, pictures, material and sides culled - then see-through ones
//! back to front, after them.
//!
//! **Light.** A surface is lit by how much of it is metal and how rough it
//! is - the model a glTF material is written for - by up to four
//! `DirectionalLight3D`s, the eight `PointLight3D`s and `SpotLight3D`s
//! nearest it that reach it, of the sixty-four the frame keeps (those the
//! camera sees, nearest first), and the light from everywhere. Colours are
//! made linear as they are read - a picture's, a material's - and light
//! adds up as it does: brighter than white where it is.
//!
//! **The environment.** The first `Environment` that is visible says what
//! is behind everything, the light from everywhere, the fog, and how the
//! light becomes a picture: exposure, tone and glow - see `post3d.zig`.
//! With none, a little grey light from everywhere, and the light as it is.
//!
//! **Smoothing.** With `Lighting.antialias`, the project's `msaa_3d` -
//! several samples a pixel, as many as the device has up to it - and its
//! `screen_space_aa`.
//!
//! A surface's material is, first found: the material of a `Material3D`
//! beside the `MeshInstance3D`, the surface's own, or plain. A material
//! that names a `.shader3d` is drawn with it - see `shader3d.zig` - given
//! the numbers the material's file gives it, and over them the entity's.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const mesh = @import("mesh.zig");
const post3d = @import("post3d.zig");
const shader3d = @import("shader3d.zig");
const shaders = @import("shaders.zig");
const View3D = @import("view3d.zig").View3D;

const MeshInstance3D = components3d.MeshInstance3D;
const MaterialHandle = @import("materials.zig").MaterialHandle;
const PrimitiveMesh3D = components3d.PrimitiveMesh3D;
const Material3D = components3d.Material3D;
const Material3DData = components3d.Material3DData;
const DirectionalLight3D = components3d.DirectionalLight3D;
const PointLight3D = components3d.PointLight3D;
const SpotLight3D = components3d.SpotLight3D;
const Environment = components3d.Environment;

const Frame = shader3d.Frame;
const Look = shader3d.Look;
const Lights = shader3d.Lights;
const Instance = shader3d.Instance;
const Way = shader3d.Way;

const log = std.log.scoped(.fluxion_engine);

/// The light from everywhere a world gets with no `Environment`.
pub const ambient: Color = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1 };

/// What lights a world that has no light of its own, where it is asked for:
/// an editor's view of a scene with none.
pub const preview_light: struct { toward: math.Vec3, color: Color } = .{
    .toward = .init(0.4, 0.8, 0.45),
    .color = .{ .r = 0.9, .g = 0.9, .b = 0.88, .a = 1 },
};

/// A picture's colour, as light adds up.
fn linear(c: Color) [4]f32 {
    return .{ toLinear(c.r), toLinear(c.g), toLinear(c.b), c.a };
}

fn toLinear(v: f32) f32 {
    const x = @max(v, 0);
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

const no_params = std.math.maxInt(u32);

/// The flat normal map: what a material with none is read with.
const flat_normal = [4]u8{ 128, 128, 255, 255 };

/// What is drawn of one surface, before it is sorted.
const Item = struct {
    way: u8,
    transparent: bool,
    compiled: *shader3d.Compiled,
    gpu: mesh.Gpu,
    first_index: u32,
    index_count: u32,
    /// Albedo, emission, metal and roughness, normal, occlusion.
    textures: [5]rhi.Texture,
    sampler: rhi.Sampler,
    /// Its material's numbers, among the frame's.
    look: u32,
    /// Its shader's own numbers, among the frame's, or `no_params`.
    params: u32,
    /// How far in front of the camera its middle is.
    depth: f32,
    /// Where its `Instance` is in `gathered`.
    instance: u32,

    /// Solid ones first, grouped by how they are drawn and then nearest
    /// first; see-through ones after, furthest first.
    fn before(_: void, a: Item, b: Item) bool {
        if (a.transparent != b.transparent) return !a.transparent;
        if (a.transparent) return a.depth > b.depth;
        return switch (order(a, b)) {
            .lt => true,
            .gt => false,
            .eq => a.depth < b.depth,
        };
    }

    fn order(a: Item, b: Item) std.math.Order {
        const keys_a = keysOf(a);
        const keys_b = keysOf(b);
        for (keys_a, keys_b) |x, y| {
            if (x != y) return std.math.order(x, y);
        }
        return .eq;
    }

    fn keysOf(item: Item) [12]u64 {
        return .{
            item.way,                 @intFromPtr(item.compiled),              item.textures[0].toInt(),
            item.textures[1].toInt(), item.textures[2].toInt(),                item.textures[3].toInt(),
            item.textures[4].toInt(), item.sampler.toInt(),                    item.gpu.vertices.toInt(),
            item.first_index,         @as(u64, item.look) << 32 | item.params, item.index_count,
        };
    }

    /// Whether `b` is drawn in the same draw as `a`.
    fn joins(a: Item, b: Item) bool {
        return order(a, b) == .eq and std.meta.eql(a.gpu, b.gpu);
    }
};

/// A point or spot light the frame keeps.
const Lamp = struct {
    place: math.Vec3,
    range: f32,
    /// Its colour times its energy, linear.
    color: [3]f32,
    attenuation: f32,
    /// The way it shines; nought for a point light.
    aim: math.Vec3,
    /// The cosine of the edge of its cone; -2 for a point light.
    edge: f32,
    cone: f32,
    /// How far it is from the camera.
    distance: f32,

    fn nearer(_: void, a: Lamp, b: Lamp) bool {
        return a.distance < b.distance;
    }
};

const DistanceFade = struct {
    enabled: bool,
    begin: f32,
    length: f32,

    fn amount(self: DistanceFade, distance: f32) f32 {
        if (!self.enabled) return 1;
        const begin = @max(self.begin, 0);
        return 1 - std.math.clamp((distance - begin) / @max(self.length, 0.001), 0, 1);
    }
};

/// Lighting a draw asks for beyond the world's own.
pub const Lighting = struct {
    /// Light a world that has no `DirectionalLight3D` with `preview_light`.
    preview: bool = false,
    /// Smooth its edges as the project says: `msaa_3d` and
    /// `screen_space_aa`. Off, one sample a pixel and nothing over it.
    antialias: bool = false,
};

pub const Renderer3D = struct {
    device: *rhi.Device,
    /// Null where the device draws into no depth format, and nothing 3D is
    /// drawn.
    depth_format: ?rhi.Format,
    /// The engine's own shader: a material with none of its own.
    plain: ?shader3d.Compiled = null,
    post: ?post3d.Post3D = null,
    frame: rhi.Buffer,
    lights: rhi.Buffer,
    instances: rhi.Buffer,
    /// How many instances the buffer has room for. Grown, never shrunk.
    capacity: u32,
    white: rhi.Texture,
    flat: rhi.Texture,
    /// The depth the last draw drew into - one sample a pixel, at its size
    /// - for what goes over it with a depth test; null after a draw with
    /// several.
    last_depth: ?rhi.Texture = null,

    gathered: std.ArrayList(Instance) = .empty,
    items: std.ArrayList(Item) = .empty,
    staging: std.ArrayList(Instance) = .empty,
    lamps: std.ArrayList(Lamp) = .empty,
    /// This draw's materials' numbers, each once.
    looks: std.ArrayList(Look) = .empty,
    look_found: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// This draw's shaders' own numbers, each set once.
    param_bytes: std.ArrayList(u8) = .empty,
    param_sets: std.ArrayList(struct { start: u32, len: u32 }) = .empty,
    param_found: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Both, in one buffer a draw binds a part of: each where the device
    /// binds a block from, the materials' first. Grown, never shrunk.
    blocks: ?rhi.Buffer = null,
    blocks_size: u32 = 0,
    block_bytes: std.ArrayList(u8) = .empty,
    /// Where each material's numbers are in `blocks`, and each set of a
    /// shader's.
    look_offsets: std.ArrayList(u32) = .empty,
    param_offsets: std.ArrayList(u32) = .empty,

    /// What the last draw drew: meshes, and the draws they took.
    drawn: u32 = 0,
    draw_calls: u32 = 0,
    /// The meshes it left out for being off the camera's frustum.
    culled: u32 = 0,
    /// The point and spot lights it kept, and the samples a pixel it drew
    /// with.
    lamps_kept: u32 = 0,
    samples: u32 = 1,

    const initial_capacity = 64;

    pub fn init(gpa: Allocator, device: *rhi.Device) !Renderer3D {
        const frame = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Frame), .dynamic = true, .label = "3D frame" });
        errdefer device.destroyBuffer(frame);
        const lights = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Lights), .dynamic = true, .label = "3D lights" });
        errdefer device.destroyBuffer(lights);
        const instances = try device.createBuffer(.{ .kind = .vertex, .size = initial_capacity * @sizeOf(Instance), .dynamic = true, .label = "3D instances" });
        errdefer device.destroyBuffer(instances);
        const white_texel = [4]u8{ 255, 255, 255, 255 };
        const white = try device.createTexture(.{ .width = 1, .height = 1, .data = &white_texel, .label = "no picture" });
        errdefer device.destroyTexture(white);
        const flat = try device.createTexture(.{ .width = 1, .height = 1, .data = &flat_normal, .label = "no normal map" });
        errdefer device.destroyTexture(flat);
        var self: Renderer3D = .{
            .device = device,
            .depth_format = depthFormat(device),
            .frame = frame,
            .lights = lights,
            .instances = instances,
            .capacity = initial_capacity,
            .white = white,
            .flat = flat,
        };
        const depth_format = self.depth_format orelse {
            log.warn("the {t} backend draws into no depth format here: nothing 3D is drawn", .{device.info().backend});
            return self;
        };
        var problems: std.Io.Writer.Allocating = .init(gpa);
        defer problems.deinit();
        self.plain = shader3d.compile(gpa, device, shader3d.plain, "3D", &problems.writer) catch |err| {
            log.err("the 3D shader: {s}", .{problems.written()});
            return err;
        };
        errdefer self.plain.?.deinit(device);
        self.post = try .init(gpa, device, depth_format);
        return self;
    }

    /// The most precise depth the device draws into.
    fn depthFormat(device: *rhi.Device) ?rhi.Format {
        for ([_]rhi.Format{ .depth32_float, .depth24_stencil8, .depth16_unorm }) |format| {
            if (device.caps().formatSupport(format).render_target) return format;
        }
        return null;
    }

    pub fn deinit(self: *Renderer3D, gpa: Allocator) void {
        const device = self.device;
        if (self.post) |*held| held.deinit(gpa);
        if (self.plain) |*held| held.deinit(device);
        if (self.blocks) |buffer| device.destroyBuffer(buffer);
        self.block_bytes.deinit(gpa);
        self.look_offsets.deinit(gpa);
        self.param_offsets.deinit(gpa);
        device.destroyBuffer(self.frame);
        device.destroyBuffer(self.lights);
        device.destroyBuffer(self.instances);
        device.destroyTexture(self.white);
        device.destroyTexture(self.flat);
        self.gathered.deinit(gpa);
        self.items.deinit(gpa);
        self.staging.deinit(gpa);
        self.lamps.deinit(gpa);
        self.looks.deinit(gpa);
        self.look_found.deinit(gpa);
        self.param_bytes.deinit(gpa);
        self.param_sets.deinit(gpa);
        self.param_found.deinit(gpa);
        self.* = undefined;
    }

    /// One more frame: targets no draw has used for a few are let go - a
    /// window dragged bigger leaves every size it passed through.
    pub fn tick(self: *Renderer3D) void {
        self.last_depth = null;
        if (self.post) |*held| held.tick();
    }

    /// Draw the 3D world through `view` into `into`, which is `width` by
    /// `height` pixels: in place of what is there, behind it all `clear` -
    /// or the environment's background - or over it as it is with null.
    pub fn draw(self: *Renderer3D, app: *App, into: rhi.RenderTarget, width: u32, height: u32, view: View3D, clear: ?Color, lighting: Lighting) !void {
        self.drawn = 0;
        self.draw_calls = 0;
        self.culled = 0;
        self.lamps_kept = 0;
        if (width == 0 or height == 0) return;
        const gpa = app.gpa;
        const device = self.device;
        const clip = device.clip();
        const view_projection = view.matrix(clip);

        const depth_format = self.depth_format orelse {
            if (clear) |color| try clearOnly(device, into, color);
            return;
        };
        const post = &self.post.?;
        const environment = environmentOf(app);
        var background = clear;
        if (environment) |held| if (clear != null and held.background == .color) {
            background = held.background_color;
        };

        const frustum: math.Frustum = .fromViewProjection(view_projection, clip);
        try self.gatherLamps(app, view, frustum);
        try self.gather(app, view, frustum);
        std.mem.sort(Item, self.items.items, {}, Item.before);
        self.staging.clearRetainingCapacity();
        try self.staging.ensureTotalCapacity(gpa, self.items.items.len);
        for (self.items.items) |item| self.staging.appendAssumeCapacity(self.gathered.items[item.instance]);
        try self.upload(gpa);
        try self.uploadFrame(app, view, view_projection, environment, lighting);

        const rendering: Project.Rendering = if (app.project.settings) |held| held.rendering else .{};
        const samples = if (lighting.antialias) post.samplesFor(rendering.msaa_3d.samples()) else 1;
        self.samples = samples;
        const targets = try post.targetsAt(gpa, width, height, samples);
        const list = device.begin();
        try list.beginPass(.{
            .color = .{
                .target = .{ .texture = targets.drawnInto() },
                .load = .clear,
                .clear_color = if (background) |color| linear(color) else .{ 0, 0, 0, 0 },
                .resolve = if (targets.multisampled != null) .{ .texture = targets.light } else null,
            },
            .depth = .{ .texture = targets.depth },
        });
        try list.setViewport(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
        const items = self.items.items;
        var start: usize = 0;
        while (start < items.len) {
            var end = start + 1;
            while (end < items.len and Item.joins(items[start], items[end])) end += 1;
            var first = items[start];
            // A shader whose pipeline the device refuses is drawn as the
            // engine's own, and is not asked again.
            const pipeline = first.compiled.pipelineOf(device, post.light_format, depth_format, samples, .of(first.way)) catch |err| blk: {
                const plain = &self.plain.?;
                if (first.compiled == plain) return err;
                first.params = no_params;
                break :blk try plain.pipelineOf(device, post.light_format, depth_format, samples, .of(first.way));
            };
            try list.setPipeline(pipeline);
            try list.setUniformBuffer(0, self.frame);
            try list.setUniformBufferRange(1, self.blocks.?, self.look_offsets.items[first.look], @sizeOf(Look));
            try list.setUniformBuffer(2, self.lights);
            if (first.params != no_params) {
                const set = self.param_sets.items[first.params];
                try list.setUniformBufferRange(shader3d.params_slot, self.blocks.?, self.param_offsets.items[first.params], set.len);
            }
            for (first.textures, 0..) |texture, slot| try list.setTexture(@intCast(slot), texture, first.sampler);
            try list.setVertexBuffer(0, first.gpu.vertices, 0);
            try list.setVertexBuffer(1, self.instances, @intCast(start * @sizeOf(Instance)));
            try list.setIndexBuffer(first.gpu.indices, .u32);
            try list.drawIndexed(.{ .index_count = first.index_count, .first_index = first.first_index, .instance_count = @intCast(end - start) });
            self.draw_calls += 1;
            start = end;
        }
        try list.endPass();
        try device.submit();
        self.drawn = @intCast(items.len);

        try post.finish(gpa, targets, into, .of(environment, lighting.antialias and rendering.screen_space_aa == .fxaa), clear == null);
        self.last_depth = if (samples == 1) targets.depth else null;
    }

    /// The frame's numbers: the camera, the suns, the light from
    /// everywhere and the fog - and every lamp kept.
    fn uploadFrame(self: *Renderer3D, app: *App, view: View3D, view_projection: math.Mat4, environment: ?Environment, lighting: Lighting) !void {
        const forward = view.forward();
        var frame: Frame = .{
            .view_projection = view_projection,
            .camera_position = .{ view.position.x, view.position.y, view.position.z, 1 },
            .camera_forward = .{ forward.x, forward.y, forward.z, if (view.projection == .orthogonal) 1 else 0 },
            .sun_directions = @splat(@splat(0)),
            .sun_colors = @splat(@splat(0)),
            .ambient = .{ ambient.r, ambient.g, ambient.b, 1 },
            .fog_color = @splat(0),
            .fog_height = @splat(0),
            .time = @floatCast(app.interface.seconds),
        };
        const suns = sunsOf(app, &frame);
        if (suns == 0 and lighting.preview) {
            const toward = preview_light.toward.norm();
            frame.sun_directions[0] = .{ toward.x, toward.y, toward.z, 0 };
            frame.sun_colors[0] = linear(preview_light.color);
        }
        if (environment) |held| {
            const sky = linear(held.ambient_color);
            frame.ambient = .{ sky[0] * held.ambient_energy, sky[1] * held.ambient_energy, sky[2] * held.ambient_energy, 1 };
            if (held.fog) {
                const fog = linear(held.fog_color);
                frame.fog_color = .{ fog[0], fog[1], fog[2], @max(held.fog_density, 0) };
                frame.fog_height = .{ held.fog_height, @max(held.fog_height_density, 0), 1, 0 };
            }
        }
        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&frame));

        var lights: Lights = .{ .places = @splat(@splat(0)), .colors = @splat(@splat(0)), .aims = @splat(@splat(0)), .cones = @splat(@splat(0)) };
        for (self.lamps.items, 0..) |lamp, at| {
            lights.places[at] = .{ lamp.place.x, lamp.place.y, lamp.place.z, lamp.range };
            lights.colors[at] = .{ lamp.color[0], lamp.color[1], lamp.color[2], lamp.attenuation };
            lights.aims[at] = .{ lamp.aim.x, lamp.aim.y, lamp.aim.z, lamp.edge };
            lights.cones[at] = .{ lamp.cone, 0, 0, 0 };
        }
        try self.device.updateBuffer(self.lights, 0, std.mem.asBytes(&lights));
    }

    /// The point and spot lights the camera sees some of, nearest first,
    /// up to `shader3d.most_lamps`.
    fn gatherLamps(self: *Renderer3D, app: *App, view: View3D, frustum: math.Frustum) !void {
        const gpa = app.gpa;
        self.lamps.clearRetainingCapacity();
        {
            var it = try ecs.Query(.{ Transform3D, PointLight3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(PointLight3D), chunk.entities) |light, entity| {
                    const placed = placedLight(app, entity) orelse continue;
                    try self.keepLamp(gpa, view, frustum, lampOf(placed.position, light.color, light.energy, light.range, light.attenuation), .{
                        .enabled = light.distance_fade,
                        .begin = light.distance_fade_begin,
                        .length = light.distance_fade_length,
                    });
                }
            }
        }
        {
            var it = try ecs.Query(.{ Transform3D, SpotLight3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(SpotLight3D), chunk.entities) |light, entity| {
                    const placed = placedLight(app, entity) orelse continue;
                    var lamp = lampOf(placed.position, light.color, light.energy, light.range, light.attenuation);
                    lamp.aim = placed.forward().tryNorm() orelse continue;
                    lamp.edge = @cos(std.math.clamp(light.angle, 0, std.math.degreesToRadians(89.9)));
                    lamp.cone = @max(light.angle_attenuation, 0.01);
                    try self.keepLamp(gpa, view, frustum, lamp, .{
                        .enabled = light.distance_fade,
                        .begin = light.distance_fade_begin,
                        .length = light.distance_fade_length,
                    });
                }
            }
        }
        std.mem.sort(Lamp, self.lamps.items, {}, Lamp.nearer);
        if (self.lamps.items.len > shader3d.most_lamps) self.lamps.shrinkRetainingCapacity(shader3d.most_lamps);
        self.lamps_kept = @intCast(self.lamps.items.len);
    }

    fn keepLamp(self: *Renderer3D, gpa: Allocator, view: View3D, frustum: math.Frustum, lamp: Lamp, fade: DistanceFade) !void {
        if (lamp.color[0] + lamp.color[1] + lamp.color[2] <= 0) return;
        if (frustum.testSphere(.init(lamp.place, lamp.range)) == .outside) return;
        var kept = lamp;
        kept.distance = lamp.place.sub(view.position).len();
        const amount = fade.amount(kept.distance);
        if (amount <= 0) return;
        for (&kept.color) |*channel| channel.* *= amount;
        try self.lamps.append(gpa, kept);
    }

    /// The lamps a mesh within `bounds` is lit by: the nearest that reach
    /// it, up to `shader3d.lamps_per_mesh`, by their place in the frame's.
    fn lampsFor(self: *const Renderer3D, bounds: math.Aabb) [2][4]f32 {
        var which: [shader3d.lamps_per_mesh]u32 = undefined;
        var near: [shader3d.lamps_per_mesh]f32 = undefined;
        var count: usize = 0;
        for (self.lamps.items, 0..) |lamp, at| {
            const d = distanceSquared(bounds, lamp.place);
            if (d >= lamp.range * lamp.range) continue;
            if (count == which.len and d >= near[count - 1]) continue;
            var slot = @min(count, which.len - 1);
            while (slot > 0 and near[slot - 1] > d) : (slot -= 1) {
                near[slot] = near[slot - 1];
                which[slot] = which[slot - 1];
            }
            near[slot] = d;
            which[slot] = @intCast(at);
            count = @min(count + 1, which.len);
        }
        var out: [2][4]f32 = @splat(@splat(-1));
        for (which[0..count], 0..) |at, slot| out[slot / 4][slot % 4] = @floatFromInt(at);
        return out;
    }

    /// What every surface of every mesh the camera sees is drawn as,
    /// unsorted.
    fn gather(self: *Renderer3D, app: *App, view: View3D, frustum: math.Frustum) !void {
        const gpa = app.gpa;
        self.gathered.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.looks.clearRetainingCapacity();
        self.look_found.clearRetainingCapacity();
        self.param_bytes.clearRetainingCapacity();
        self.param_sets.clearRetainingCapacity();
        self.param_found.clearRetainingCapacity();
        const alpha = app.time.alpha();
        const forward = view.forward();
        const plain = &self.plain.?;

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
                const turn = model.normalMatrix() orelse math.Mat3.identity;
                const depth = bounds.center().sub(view.position).dot(forward);
                const own: MaterialHandle = if (app.world.get(entity, Material3D)) |held| held.material else .none;
                const at: u32 = @intCast(self.gathered.items.len);
                try self.gathered.append(gpa, .{
                    .model = .{ model.cols[0].array(), model.cols[1].array(), model.cols[2].array(), model.cols[3].array() },
                    .normal = .{ turn.cols[0].array(), turn.cols[1].array(), turn.cols[2].array() },
                    .tint = linear(looks.tint(.white)),
                    .lights = self.lampsFor(bounds),
                });
                for (kept.mesh.surfaces) |surface| {
                    if (surface.index_count == 0) continue;
                    const chosen = if (!own.isNone() and app.materials.get(own) != null) own else surface.material;
                    const look = materialOf(app, chosen);
                    var compiled = if (look.shader.isNone()) plain else app.shaders.compiled3DOf(look.shader) orelse plain;
                    if (compiled.refused) compiled = plain;
                    var sampler = app.assets.samplerFor(.linear, .repeat);
                    var textures: [5]rhi.Texture = .{ self.white, self.white, self.white, self.flat, self.white };
                    for ([_]@TypeOf(look.albedo_texture){ look.albedo_texture, look.emission_texture, look.metallic_roughness_texture, look.normal_texture, look.occlusion_texture }, 0..) |handle, slot| {
                        if (handle.isNone()) continue;
                        const held = app.assets.get(handle) orelse continue;
                        textures[slot] = held.gpu;
                        if (slot == 0) sampler = app.assets.samplerFor(held.filter, .repeat);
                    }
                    const blend = look.transparency == .alpha;
                    const way: Way = .{ .cull = look.cull, .blend = blend };
                    try self.items.append(gpa, .{
                        .way = @intCast(way.index()),
                        .transparent = blend,
                        .compiled = compiled,
                        .gpu = gpu,
                        .first_index = surface.first_index,
                        .index_count = surface.index_count,
                        .textures = textures,
                        .sampler = sampler,
                        .look = try self.lookIndex(gpa, lookOf(look, !look.normal_texture.isNone() or compiled.writes_normal_map)),
                        .params = try self.paramSetOf(app, compiled, chosen, entity),
                        .depth = depth,
                        .instance = at,
                    });
                }
            }
        }
    }

    /// Which of this draw's materials' numbers `look` is: one made for it,
    /// or the same one another gave.
    fn lookIndex(self: *Renderer3D, gpa: Allocator, look: Look) !u32 {
        const bytes = std.mem.asBytes(&look);
        const found = try self.look_found.getOrPut(gpa, std.hash.Wyhash.hash(0, bytes));
        if (found.found_existing and std.mem.eql(u8, std.mem.asBytes(&self.looks.items[found.value_ptr.*]), bytes)) return found.value_ptr.*;
        const at: u32 = @intCast(self.looks.items.len);
        try self.looks.append(gpa, look);
        if (!found.found_existing) found.value_ptr.* = at;
        return at;
    }

    /// Which of this draw's sets of numbers `compiled`'s own block is given -
    /// the material's, and over them `entity`'s - or `no_params` for a
    /// shader with none.
    fn paramSetOf(self: *Renderer3D, app: *App, compiled: *const shader3d.Compiled, material: MaterialHandle, entity: ecs.Entity) !u32 {
        const gpa = app.gpa;
        const block = compiled.params orelse return no_params;
        const start: u32 = @intCast(self.param_bytes.items.len);
        try self.param_bytes.resize(gpa, start + block.size);
        const bytes = self.param_bytes.items[start..];
        shaders.packLayers(block, &.{ app.materials.params(material), app.shader_params.of(entity) }, bytes);
        const found = try self.param_found.getOrPut(gpa, std.hash.Wyhash.hash(block.size, bytes));
        if (found.found_existing) {
            const set = self.param_sets.items[found.value_ptr.*];
            if (set.len == block.size and std.mem.eql(u8, self.param_bytes.items[set.start..][0..set.len], bytes)) {
                self.param_bytes.shrinkRetainingCapacity(start);
                return found.value_ptr.*;
            }
        }
        const at: u32 = @intCast(self.param_sets.items.len);
        try self.param_sets.append(gpa, .{ .start = start, .len = block.size });
        if (!found.found_existing) found.value_ptr.* = at;
        return at;
    }

    /// The sorted instances into the buffer, grown to hold them, and every
    /// material's and shader's numbers into one, each where the device binds
    /// a block from.
    fn upload(self: *Renderer3D, gpa: Allocator) !void {
        const device = self.device;
        const count: u32 = @intCast(self.staging.items.len);
        if (count > self.capacity) {
            var room = self.capacity;
            while (room < count) room *= 2;
            const grown = try device.createBuffer(.{ .kind = .vertex, .size = room * @sizeOf(Instance), .dynamic = true, .label = "3D instances" });
            device.destroyBuffer(self.instances);
            self.instances = grown;
            self.capacity = room;
        }
        if (count > 0) try device.updateBuffer(self.instances, 0, std.mem.sliceAsBytes(self.staging.items));

        const alignment = device.caps().limits.uniform_offset_alignment;
        self.block_bytes.clearRetainingCapacity();
        self.look_offsets.clearRetainingCapacity();
        self.param_offsets.clearRetainingCapacity();
        for (self.looks.items) |*look| try self.look_offsets.append(gpa, try self.place(gpa, std.mem.asBytes(look), alignment));
        for (self.param_sets.items) |set| try self.param_offsets.append(gpa, try self.place(gpa, self.param_bytes.items[set.start..][0..set.len], alignment));
        const size: u32 = @intCast(self.block_bytes.items.len);
        if (size == 0) return;
        if (self.blocks_size < size) {
            var room = @max(self.blocks_size, alignment * 64);
            while (room < size) room *= 2;
            const grown = try device.createBuffer(.{ .kind = .uniform, .size = room, .dynamic = true, .label = "3D materials" });
            if (self.blocks) |old| device.destroyBuffer(old);
            self.blocks = grown;
            self.blocks_size = room;
        }
        try device.updateBuffer(self.blocks.?, 0, self.block_bytes.items);
    }

    /// `bytes` at the next place in `block_bytes` a block is bound from.
    fn place(self: *Renderer3D, gpa: Allocator, bytes: []const u8, alignment: u32) !u32 {
        const old = self.block_bytes.items.len;
        const at: u32 = @intCast(std.mem.alignForward(usize, old, alignment));
        try self.block_bytes.resize(gpa, at + bytes.len);
        @memset(self.block_bytes.items[old..at], 0);
        @memcpy(self.block_bytes.items[at..][0..bytes.len], bytes);
        return at;
    }
};

/// A material's numbers as the shader reads them.
fn lookOf(look: Material3DData, normal_map: bool) Look {
    const glow = linear(look.emission);
    const energy = look.emission_energy;
    return .{
        .albedo_color = linear(look.albedo_color),
        .emission_color = .{ glow[0] * energy, glow[1] * energy, glow[2] * energy, 0 },
        .uv_place = .{ look.uv_scale.x, look.uv_scale.y, look.uv_offset.x, look.uv_offset.y },
        .surface = .{
            std.math.clamp(look.metallic, 0, 1),
            std.math.clamp(look.roughness, 0, 1),
            look.normal_scale,
            if (look.occlusion_texture.isNone()) 0 else std.math.clamp(look.occlusion_strength, 0, 1),
        },
        .feel = .{
            if (look.unshaded) 1 else 0,
            if (look.vertex_color) 1 else 0,
            if (look.transparency == .scissor) look.alpha_scissor_threshold else 0,
            if (normal_map) 1 else 0,
        },
        .facing = .{ if (look.cull == .back) 0 else 1, 0, 0, 0 },
    };
}

/// A lamp, from what a point or spot light says.
fn lampOf(place: math.Vec3, color: Color, energy: f32, range: f32, attenuation: f32) Lamp {
    const c = linear(color);
    const e = @max(energy, 0);
    return .{
        .place = place,
        .range = @max(range, 0.001),
        .color = .{ c[0] * e, c[1] * e, c[2] * e },
        .attenuation = @max(attenuation, 0.01),
        .aim = .zero,
        .edge = -2,
        .cone = 1,
        .distance = 0,
    };
}

/// Where a light is, when it is visible.
fn placedLight(app: *App, entity: ecs.Entity) ?Transform3D {
    if (!app.inherited.of(app.gpa, &app.world, entity).visible) return null;
    return app.drawnTransform3D(entity);
}

/// How far a point is from a box, squared: nought inside it.
fn distanceSquared(box: math.Aabb, p: math.Vec3) f32 {
    const dx = @max(box.min.x - p.x, 0, p.x - box.max.x);
    const dy = @max(box.min.y - p.y, 0, p.y - box.max.y);
    const dz = @max(box.min.z - p.z, 0, p.z - box.max.z);
    return dx * dx + dy * dy + dz * dz;
}

/// What a surface is drawn with: the `Material3D` beside its mesh's
/// instance, the instance's override, the surface's own, or plain.
fn materialOf(app: *App, handle: MaterialHandle) Material3DData {
    if (!handle.isNone()) if (app.materials.get(handle)) |held| return held.*;
    return .{};
}

/// Each visible `DirectionalLight3D` into the frame, up to
/// `shader3d.most_suns`: how many.
fn sunsOf(app: *App, frame: *Frame) usize {
    var count: usize = 0;
    var it = ecs.Query(.{ Transform3D, DirectionalLight3D }).over(&app.world) catch return 0;
    while (it.next()) |chunk| {
        for (chunk.slice(DirectionalLight3D), chunk.entities) |light, entity| {
            if (count == shader3d.most_suns) return count;
            const placed = placedLight(app, entity) orelse continue;
            const toward = placed.back().tryNorm() orelse continue;
            const c = linear(light.color);
            const e = @max(light.energy, 0);
            frame.sun_directions[count] = .{ toward.x, toward.y, toward.z, 0 };
            frame.sun_colors[count] = .{ c[0] * e, c[1] * e, c[2] * e, 1 };
            count += 1;
        }
    }
    return count;
}

/// The first visible `Environment`, if there is one.
pub fn environmentOf(app: *App) ?Environment {
    var it = ecs.Query(.{Environment}).over(&app.world) catch return null;
    while (it.next()) |chunk| {
        for (chunk.slice(Environment), chunk.entities) |held, entity| {
            if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
            return held;
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

test "a mesh is lit by the nearest lamps that reach it, nearest first, and no more than it can hold" {
    var renderer: Renderer3D = undefined;
    renderer.lamps = .empty;
    defer renderer.lamps.deinit(testing.allocator);
    const box: math.Aabb = .{ .min = .init(-1, -1, -1), .max = .init(1, 1, 1) };
    for (0..12) |i| {
        var lamp = lampOf(.init(@floatFromInt(2 + i), 0, 0), .white, 1, 20, 1);
        if (i == 3) lamp.range = 0.5; // too short to reach
        try renderer.lamps.append(testing.allocator, lamp);
    }
    const chosen = renderer.lampsFor(box);
    try testing.expectEqual([4]f32{ 0, 1, 2, 4 }, chosen[0]);
    try testing.expectEqual([4]f32{ 5, 6, 7, 8 }, chosen[1]);
    const far: math.Aabb = .{ .min = .init(100, 0, 0), .max = .init(101, 1, 1) };
    try testing.expectEqual([4]f32{ -1, -1, -1, -1 }, renderer.lampsFor(far)[0]);
    try testing.expectEqual(@as(f32, 0), distanceSquared(box, .zero));
    try testing.expectEqual(@as(f32, 4), distanceSquared(box, .init(3, 0, 0)));
}

test "a material's numbers are linear, as light adds up" {
    const look = lookOf(.{ .albedo_color = .{ .r = 0.5, .g = 1, .b = 0, .a = 0.5 }, .emission = .white, .emission_energy = 2, .cull = .disabled }, false);
    try testing.expectApproxEqAbs(@as(f32, 0.214041), look.albedo_color[0], 0.00001);
    try testing.expectEqual(@as(f32, 0.5), look.albedo_color[3]);
    try testing.expectEqual(@as(f32, 2), look.emission_color[0]);
    try testing.expectEqual(@as(f32, 1), look.facing[0]);
    // No occlusion picture, so none of it is read.
    try testing.expectEqual(@as(f32, 0), look.surface[3]);
}

test "a lamp fades smoothly to nothing with its distance from the camera" {
    const fade: DistanceFade = .{ .enabled = true, .begin = 10, .length = 5 };
    try testing.expectEqual(@as(f32, 1), fade.amount(5));
    try testing.expectEqual(@as(f32, 1), fade.amount(10));
    try testing.expectApproxEqAbs(@as(f32, 0.5), fade.amount(12.5), 0.0001);
    try testing.expectEqual(@as(f32, 0), fade.amount(15));
    try testing.expectEqual(@as(f32, 1), (DistanceFade{ .enabled = false, .begin = 0, .length = 0 }).amount(100));
}
