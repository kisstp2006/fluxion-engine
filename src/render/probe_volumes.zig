// SPDX-License-Identifier: BSD-3-Clause

//! The light from everywhere at every pixel inside a `ProbeVolume3D`: a
//! grid of probes over its box, each holding how lit a surface facing any
//! way is there, read eight at a time round each pixel - and only those the
//! pixel can see from where they are.
//!
//! **Baked.** A `LightmapGI`'s bake bakes every probe volume of its world
//! with it (`App.bakeLightmap`): for each probe, its light - traced as the
//! lightmap's own probes are - and what each of its rays met - 32, 64 or
//! 128, as its `quality` says: how far,
//! which way it faced, its colour, what it gives off, and which of the
//! first sixteen lights it saw. Baked, that light is what is read.
//!
//! **Realtime.** Each frame the GPU lights again what the rays met, as the
//! lights are now - a lamp put out, the sun dimmed, a sky turned red - and
//! with the probes' own light of the frame before, so light bounces as
//! often as there are frames: a fragment pass over every probe's rays,
//! then one that sums each probe's rays into its light, blended into the
//! last so the change is smooth. A light's sight of each ray's end is the
//! bake's: one moved, or one the bake did not have, lights nothing. This is
//! DDGI - Majercik, Guertin, Nowrouzezahrai and McGuire, "Dynamic Diffuse
//! Global Illumination with Ray-Traced Irradiance Fields" (JCGT 2019) - but
//! with its rays traced once, at the bake, rather than every frame: the
//! world's still meshes do not move, so neither does what the rays meet.
//!
//! **Seen.** A pixel takes the eight probes round it, each by how near,
//! how much it faces the probe, and whether the probe sees it: the mean of
//! the distance each probe saw that way and of its square bound how likely
//! something stands between (Chebyshev's inequality, as DDGI's does), so a
//! probe behind a wall gives a room none of its light.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const lightmapper = @import("fluxion_lightmapper");

pub const depth_side = lightmapper.volume_depth_side;
comptime {
    // The sum shader's loop goes as far as the most rays there may be.
    std.debug.assert(lightmapper.most_volume_rays == 128);
}
/// The most probes a volume has across any way, and in all: what its
/// pictures have room for.
pub const most_across = 96;
pub const most_probes = 32768;

/// The grid of a probe volume whose box is round `middle`, `half` each way:
/// a probe in the middle of each cell the box is cut into - so none is on
/// a wall the box ends at - as few fewer as keeps it within `most_across`
/// each way and `most_probes` in all.
pub fn gridOf(middle: [3]f32, half: [3]f32, wanted_spacing: f32) lightmapper.VolumeGrid {
    var spacing = @max(wanted_spacing, 0.05);
    while (true) {
        var counts: [3]u32 = undefined;
        var origin: [3]f32 = undefined;
        for (0..3) |a| {
            const across = @max(half[a] * 2, 0);
            counts[a] = std.math.clamp(@as(u32, @intFromFloat(@floor(across / spacing))), 1, most_across);
            const span = @as(f32, @floatFromInt(counts[a] - 1)) * spacing;
            origin[a] = middle[a] - half[a] + (across - span) / 2;
        }
        const grid: lightmapper.VolumeGrid = .{ .origin = origin, .spacing = spacing, .counts = counts };
        if (grid.count() <= most_probes and @as(u64, counts[1]) * counts[2] * depth_side <= 32768) return grid;
        spacing *= 1.25;
    }
}

test "a volume's grid puts a probe in the middle of each cell, and grows coarser to fit" {
    const grid = gridOf(.{ 0, 1, 0 }, .{ 3, 1, 1.5 }, 1);
    try testing.expectEqual([3]u32{ 6, 2, 3 }, grid.counts);
    try testing.expectApproxEqAbs(@as(f32, -2.5), grid.origin[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), grid.origin[1], 0.0001);
    const huge = gridOf(.{ 0, 0, 0 }, .{ 500, 50, 500 }, 1);
    try testing.expect(huge.count() <= most_probes);
    for (huge.counts) |c| try testing.expect(c <= most_across);
}

/// What the 3D shader's `Volume` block holds.
pub const Block = extern struct {
    /// Where the first probe is, and how far apart they are.
    origin: [4]f32 = .{ 0, 0, 0, 0 },
    /// How many each way, and whether it is read: nought for none.
    counts: [4]f32 = .{ 0, 0, 0, 0 },
    /// Its strength; whether its light is read over the lightmap's - one
    /// realtime - and one over the light and depth pictures' widths.
    knobs: [4]f32 = .{ 0, 0, 0, 0 },
    /// One over the light and depth pictures' heights.
    sizes: [4]f32 = .{ 0, 0, 0, 0 },
};

/// The pictures a volume is read from, made from what was baked: a probe's
/// light three texels - red, green and blue, each how lit a surface facing
/// `n` is as `x + y n.x + z n.y + w n.z` - its row `y` plus `z` times the
/// rows of `y`; its distances an 8 by 8 tile of mean and mean square.
pub const Pictures = struct {
    light: rhi.Texture,
    depth: rhi.Texture,
    light_width: u32,
    light_height: u32,
    depth_width: u32,
    depth_height: u32,

    pub fn deinit(self: *Pictures, device: *rhi.Device) void {
        device.destroyTexture(self.light);
        device.destroyTexture(self.depth);
    }
};

/// Where probe (`x`, `y`, `z`) of `counts` is in the light picture: its
/// first texel's column and its row.
pub fn lightTexel(counts: [3]u32, x: u32, y: u32, z: u32) [2]u32 {
    return .{ x * 3, y + z * counts[1] };
}

/// The light and depth pictures of `volume`.
pub fn picturesOf(gpa: Allocator, device: *rhi.Device, volume: lightmapper.Volume) !Pictures {
    const counts = volume.grid.counts;
    const light_width = counts[0] * 3;
    const light_height = counts[1] * counts[2];
    const light = try gpa.alloc([4]f32, @as(usize, light_width) * light_height);
    defer gpa.free(light);
    for (0..volume.grid.count()) |i| {
        const x: u32 = @intCast(i % counts[0]);
        const y: u32 = @intCast((i / counts[0]) % counts[1]);
        const z: u32 = @intCast(i / (@as(usize, counts[0]) * counts[1]));
        const at = lightTexel(counts, x, y, z);
        // One inside something is dark and is read as none: its fourth
        // number below nought.
        const valid = volume.valid[i];
        for (0..3) |c| {
            const s = volume.light[i][c * 4 ..][0..4];
            light[@as(usize, at[1]) * light_width + at[0] + c] = if (valid) .{ s[0], s[1], s[2], s[3] } else .{ -1, 0, 0, 0 };
        }
    }
    const depth_width = counts[0] * depth_side;
    const depth_height = counts[1] * counts[2] * depth_side;
    const depth = try gpa.alloc([2]f32, @as(usize, depth_width) * depth_height);
    defer gpa.free(depth);
    for (0..volume.grid.count()) |i| {
        const x: u32 = @intCast(i % counts[0]);
        const row: u32 = @intCast(i / counts[0]);
        for (0..depth_side) |ty| for (0..depth_side) |tx| {
            depth[(@as(usize, row) * depth_side + ty) * depth_width + x * depth_side + tx] = volume.depth[i][ty * depth_side + tx];
        };
    }
    const light_texture = try device.createTexture(.{
        .width = light_width,
        .height = light_height,
        .format = .rgba32_float,
        .data = std.mem.sliceAsBytes(light),
        .usage = .{ .sampled = true, .render_target = true },
        .label = "probe volume light",
    });
    errdefer device.destroyTexture(light_texture);
    const depth_texture = try device.createTexture(.{
        .width = depth_width,
        .height = depth_height,
        .format = .rg32_float,
        .data = std.mem.sliceAsBytes(depth),
        .label = "probe volume depth",
    });
    return .{ .light = light_texture, .depth = depth_texture, .light_width = light_width, .light_height = light_height, .depth_width = depth_width, .depth_height = depth_height };
}

test "a probe's light is three texels on its row, its rows the grid's y and z" {
    const counts = [3]u32{ 4, 3, 2 };
    try testing.expectEqual([2]u32{ 0, 0 }, lightTexel(counts, 0, 0, 0));
    try testing.expectEqual([2]u32{ 9, 2 }, lightTexel(counts, 3, 2, 0));
    try testing.expectEqual([2]u32{ 3, 4 }, lightTexel(counts, 1, 1, 1));
}

// -------------------------------------------------------------------------
// Drawn: the volume a frame reads, lit again where it is realtime
// -------------------------------------------------------------------------

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const shader = @import("fluxion_shader");
const id = @import("fluxion_id");

const App = @import("../App.zig");
const components3d = @import("render3d_components.zig");
const lightmaps = @import("lightmaps.zig");
const material = @import("material.zig");
const shader3d = @import("shader3d.zig");
const Color = @import("../math/color.zig").Color;

const ProbeVolume3D = components3d.ProbeVolume3D;
const Uuid = id.Uuid;
const log = std.log.scoped(.fluxion_engine);

/// The block of uniforms the 3D shader reads the volume from, and its
/// pictures' slots.
pub const slot = shader3d.volume_slot;
pub const light_slot = shader3d.volume_light_slot;
pub const depth_slot = shader3d.volume_depth_slot;

/// The most lights a realtime volume is lit by: those of the bake's whose
/// sight it kept.
pub const most_lights = lightmapper.volume_lights;

/// What the relighting passes read: the grid, the sky, how much bounces,
/// the flip, how much of the last frame stays, how many rays a probe
/// sends, and four `vec4`s a light.
const Relight = extern struct {
    origin: [4]f32,
    counts: [4]f32,
    sizes: [4]f32,
    sky: [4]f32,
    texel: [4]f32,
    lights: [most_lights * 4][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

/// A baked volume on the device: its pictures, and for a realtime one what
/// lights it again - what its rays met, the light along each this frame,
/// and its light of the frame before.
const Held = struct {
    uuid: Uuid,
    pictures: Pictures,
    count: u32,
    /// What its rays met, three texels a ray: distance and normal; colour
    /// and the lights it sees; what it gives off.
    hits: ?rhi.Texture = null,
    /// The light along each ray this frame.
    radiance: ?rhi.Texture = null,
    /// Its light of the frame before, swapped with `pictures.light` each frame.
    before: ?rhi.Texture = null,
    /// The frame it was last lit again in.
    lit_frame: u64 = std.math.maxInt(u64),

    fn deinit(self: *Held, device: *rhi.Device) void {
        self.pictures.deinit(device);
        for ([_]?rhi.Texture{ self.hits, self.radiance, self.before }) |held| if (held) |texture| device.destroyTexture(texture);
    }
};

pub const Volumes = struct {
    gpa: Allocator,
    device: *rhi.Device,
    held: std.ArrayList(Held) = .empty,
    /// The lightmap the held volumes were made from.
    from: ?*const lightmaps.Lightmap = null,
    block: rhi.Buffer,
    relight_block: rhi.Buffer,
    corners: rhi.Buffer,
    nearest: rhi.Sampler,
    shaders: ?Shaders = null,
    refused: bool = false,
    shown: Block = .{},
    /// The volume drawn this frame, and what it reads: its light and depth.
    light: ?rhi.Texture = null,
    depth: ?rhi.Texture = null,

    const Shaders = struct {
        rays: shader.Module,
        rays_gpu: rhi.Shader,
        rays_pipeline: rhi.Pipeline,
        sum: shader.Module,
        sum_gpu: rhi.Shader,
        sum_pipeline: rhi.Pipeline,
    };

    pub fn init(gpa: Allocator, device: *rhi.Device) !Volumes {
        var self: Volumes = .{ .gpa = gpa, .device = device, .block = .none, .relight_block = .none, .corners = .none, .nearest = .none };
        self.block = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Block), .dynamic = true, .label = "probe volume" });
        errdefer device.destroyBuffer(self.block);
        self.relight_block = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Relight), .dynamic = true, .label = "probe volume relight" });
        errdefer device.destroyBuffer(self.relight_block);
        const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
        self.corners = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "probe volume corners" });
        errdefer device.destroyBuffer(self.corners);
        self.nearest = try device.createSampler(.nearest);
        try device.updateBuffer(self.block, 0, std.mem.asBytes(&self.shown));
        return self;
    }

    pub fn deinit(self: *Volumes) void {
        const device = self.device;
        self.forget();
        self.held.deinit(self.gpa);
        if (self.shaders) |*held| {
            inline for (.{ "rays", "sum" }) |name| {
                device.destroyPipeline(@field(held, name ++ "_pipeline"));
                device.destroyShader(@field(held, name ++ "_gpu"));
                @field(held, name).deinit();
            }
        }
        device.destroySampler(self.nearest);
        device.destroyBuffer(self.corners);
        device.destroyBuffer(self.relight_block);
        device.destroyBuffer(self.block);
    }

    fn forget(self: *Volumes) void {
        for (self.held.items) |*held| held.deinit(self.device);
        self.held.clearRetainingCapacity();
        self.from = null;
    }

    /// The volume this frame's surfaces read - the one round `eye`, or the
    /// nearest - from the world's lightmap `baked`, lit again first where
    /// it is realtime, once a frame. None without a baked one.
    pub fn show(self: *Volumes, app: *App, eye: math.Vec3, baked: ?*const lightmaps.Lightmap, sky: [3]f32) !void {
        var block: Block = .{};
        self.light = null;
        self.depth = null;
        if (baked) |lightmap| if (lightmap.volumes.len > 0 and !self.refused) {
            if (self.from != lightmap) {
                self.forget();
                self.from = lightmap;
            }
            if (try self.nearestTo(app, eye, lightmap)) |found| {
                const held = found.held;
                const volume = found.volume;
                const grid = volume.baked.grid;
                const component = found.component;
                const realtime = component.mode == .realtime;
                if (realtime and held.lit_frame != app.time.frame) {
                    held.lit_frame = app.time.frame;
                    self.relight(app, held, volume, lightmap, component, sky) catch |err| {
                        log.warn("a realtime probe volume is not lit again: {t}", .{err});
                        self.refused = true;
                    };
                }
                block = .{
                    .origin = .{ grid.origin[0], grid.origin[1], grid.origin[2], grid.spacing },
                    .counts = .{ @floatFromInt(grid.counts[0]), @floatFromInt(grid.counts[1]), @floatFromInt(grid.counts[2]), 1 },
                    .knobs = .{ @max(component.intensity, 0), if (realtime) 1 else 0, 1.0 / @as(f32, @floatFromInt(held.pictures.light_width)), 1.0 / @as(f32, @floatFromInt(held.pictures.depth_width)) },
                    .sizes = .{ 1.0 / @as(f32, @floatFromInt(held.pictures.light_height)), 1.0 / @as(f32, @floatFromInt(held.pictures.depth_height)), 0, 0 },
                };
                self.light = held.pictures.light;
                self.depth = held.pictures.depth;
            }
        };
        if (std.mem.eql(u8, std.mem.asBytes(&block), std.mem.asBytes(&self.shown))) return;
        self.shown = block;
        try self.device.updateBuffer(self.block, 0, std.mem.asBytes(&block));
    }

    const Found = struct { held: *Held, volume: *const lightmaps.Volume, component: ProbeVolume3D };

    /// The probe volume whose box holds `eye`, or the nearest, with its
    /// bake and its pictures.
    fn nearestTo(self: *Volumes, app: *App, eye: math.Vec3, lightmap: *const lightmaps.Lightmap) !?Found {
        var best: ?Found = null;
        var best_far: f32 = std.math.floatMax(f32);
        var it = try ecs.Query(.{ components3d.ProbeVolume3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(ProbeVolume3D), chunk.entities) |component, entity| {
                const uuid = app.uuidOf(entity) orelse continue;
                const volume = lightmaps.Volume.find(lightmap.volumes, uuid) orelse continue;
                const grid = volume.baked.grid;
                const lo = math.Vec3.init(grid.origin[0], grid.origin[1], grid.origin[2]);
                const span = @as(f32, grid.spacing);
                const hi = lo.add(math.Vec3.init(@floatFromInt(grid.counts[0] - 1), @floatFromInt(grid.counts[1] - 1), @floatFromInt(grid.counts[2] - 1)).scale(span));
                const far = eye.max(lo).min(hi).sub(eye).len();
                if (far >= best_far) continue;
                best_far = far;
                best = .{ .held = try self.heldOf(volume), .volume = volume, .component = component };
            }
        }
        return best;
    }

    fn heldOf(self: *Volumes, volume: *const lightmaps.Volume) !*Held {
        for (self.held.items) |*held| if (held.uuid.eql(volume.uuid)) return held;
        const pictures = try picturesOf(self.gpa, self.device, volume.baked);
        try self.held.append(self.gpa, .{ .uuid = volume.uuid, .pictures = pictures, .count = @intCast(volume.baked.grid.count()) });
        return &self.held.items[self.held.items.len - 1];
    }

    /// A realtime volume lit again: the light along each of its probes'
    /// rays from what each met, as the lights are now and with the light it
    /// had the frame before; then each probe's rays summed into its light,
    /// blended into what it had.
    fn relight(self: *Volumes, app: *App, held: *Held, volume: *const lightmaps.Volume, lightmap: *const lightmaps.Lightmap, component: ProbeVolume3D, sky: [3]f32) !void {
        const device = self.device;
        const shaders = try self.compiled();
        const grid = volume.baked.grid;
        if (held.hits == null) held.hits = try hitsOf(self.gpa, device, volume.baked);
        if (held.radiance == null) held.radiance = try device.createTexture(.{
            .width = grid.rays,
            .height = held.count,
            .format = .rgba32_float,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "probe volume rays",
        });
        if (held.before == null) held.before = try device.createTexture(.{
            .width = held.pictures.light_width,
            .height = held.pictures.light_height,
            .format = .rgba32_float,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "probe volume light",
        });
        var block: Relight = .{
            .origin = .{ grid.origin[0], grid.origin[1], grid.origin[2], grid.spacing },
            .counts = .{ @floatFromInt(grid.counts[0]), @floatFromInt(grid.counts[1]), @floatFromInt(grid.counts[2]), 0 },
            .sizes = .{ 1.0 / @as(f32, @floatFromInt(grid.rays * 3)), 1.0 / @as(f32, @floatFromInt(held.count)), 1.0 / @as(f32, @floatFromInt(held.pictures.light_width)), 1.0 / @as(f32, @floatFromInt(held.pictures.light_height)) },
            .sky = .{ sky[0], sky[1], sky[2], if (component.bounce) 1 else 0 },
            .texel = .{ material.screenFlip(device), std.math.clamp(component.hysteresis, 0, 0.99), @floatFromInt(grid.rays), 0 },
        };
        block.counts[3] = @floatFromInt(lightsNow(app, lightmap.volume_lights, &block.lights));
        try device.updateBuffer(self.relight_block, 0, std.mem.asBytes(&block));
        // The light along each ray, from the light the volume had.
        {
            const list = device.begin();
            try list.beginPass(.{ .color = .{ .target = .{ .texture = held.radiance.? }, .load = .dont_care } });
            try list.setViewport(.{ .width = @floatFromInt(grid.rays), .height = @floatFromInt(held.count) });
            try list.setPipeline(shaders.rays_pipeline);
            try list.setUniformBuffer(0, self.relight_block);
            try list.setTexture(0, held.hits.?, self.nearest);
            try list.setTexture(1, held.pictures.light, self.nearest);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 4 });
            try list.endPass();
            try device.submit();
        }
        // Each probe's rays summed into its light, into the other picture,
        // which is the light from now on.
        {
            const list = device.begin();
            try list.beginPass(.{ .color = .{ .target = .{ .texture = held.before.? }, .load = .dont_care } });
            try list.setViewport(.{ .width = @floatFromInt(held.pictures.light_width), .height = @floatFromInt(held.pictures.light_height) });
            try list.setPipeline(shaders.sum_pipeline);
            try list.setUniformBuffer(0, self.relight_block);
            try list.setTexture(0, held.radiance.?, self.nearest);
            try list.setTexture(1, held.pictures.light, self.nearest);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 4 });
            try list.endPass();
            try device.submit();
        }
        const now = held.before.?;
        held.before = held.pictures.light;
        held.pictures.light = now;
    }

    fn compiled(self: *Volumes) !*Shaders {
        if (self.shaders) |*held| return held;
        const device = self.device;
        var made: Shaders = undefined;
        inline for (.{ .{ "rays", rays_source }, .{ "sum", sum_source } }) |pair| {
            var said: std.Io.Writer.Allocating = .init(self.gpa);
            defer said.deinit();
            var module = shader.compile(self.gpa, pair[1], &said.writer) catch |err| {
                log.err("probe volume {s} shader: {s}", .{ pair[0], said.written() });
                return err;
            };
            errdefer module.deinit();
            const gpu = try device.createShader(.{
                .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
                .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
                .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
                .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
                .label = "probe volume " ++ pair[0],
            });
            errdefer device.destroyShader(gpu);
            const pipeline = device.createPipeline(.{
                .shader = gpu,
                .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
                .buffers = &.{.{ .stride = @sizeOf([2]f32) }},
                .topology = .triangle_strip,
                .color_format = .rgba32_float,
                .uniform_blocks = (try module.uniformBlockNames()) orelse return error.ShaderFailed,
                .textures = (try module.textureNames()) orelse return error.ShaderFailed,
                .label = "probe volume " ++ pair[0],
            }) catch |err| {
                log.err("the graphics driver refused the probe volume {s} pipeline: {s}", .{ pair[0], device.diagnostics() });
                return err;
            };
            @field(made, pair[0]) = module;
            @field(made, pair[0] ++ "_gpu") = gpu;
            @field(made, pair[0] ++ "_pipeline") = pipeline;
        }
        self.shaders = made;
        return &self.shaders.?;
    }
};

/// What each of `volume`'s rays met, as the relighting reads it.
fn hitsOf(gpa: Allocator, device: *rhi.Device, volume: lightmapper.Volume) !rhi.Texture {
    const count = volume.grid.count();
    const texels = try gpa.alloc([4]f32, count * volume.grid.rays * 3);
    defer gpa.free(texels);
    for (volume.hits, 0..) |hit, i| {
        texels[i * 3 + 0] = .{ hit.distance, hit.normal[0], hit.normal[1], hit.normal[2] };
        texels[i * 3 + 1] = .{ hit.albedo[0], hit.albedo[1], hit.albedo[2], @floatFromInt(hit.lights) };
        texels[i * 3 + 2] = .{ hit.emission[0], hit.emission[1], hit.emission[2], 0 };
    }
    return device.createTexture(.{
        .width = volume.grid.rays * 3,
        .height = @intCast(count),
        .format = .rgba32_float,
        .data = std.mem.sliceAsBytes(texels),
        .label = "probe volume hits",
    });
}

/// The lights a volume was baked to see, as they are now, into `into`:
/// four `vec4`s each - toward a sun or where a lamp is and its kind (one a
/// sun, two a point light, three a spot light, nought gone), its light and
/// reach, its aim and cone, how it falls off. How many there are.
fn lightsNow(app: *App, uuids: []const Uuid, into: *[most_lights * 4][4]f32) usize {
    for (uuids[0..@min(uuids.len, most_lights)], 0..) |uuid, l| {
        const at = l * 4;
        into[at] = .{ 0, 0, 0, 0 };
        const entity = app.findUuid(uuid) orelse continue;
        if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
        const placed = app.drawnTransform3D(entity) orelse continue;
        if (app.world.get(entity, components3d.DirectionalLight3D)) |sun| {
            const toward = placed.back().tryNorm() orelse continue;
            const c = colorOf(sun.color, sun.energy);
            into[at] = .{ toward.x, toward.y, toward.z, 1 };
            into[at + 1] = .{ c[0], c[1], c[2], 0 };
        } else if (app.world.get(entity, components3d.PointLight3D)) |lamp| {
            const c = colorOf(lamp.color, lamp.energy);
            into[at] = .{ placed.position.x, placed.position.y, placed.position.z, 2 };
            into[at + 1] = .{ c[0], c[1], c[2], @max(lamp.range, 0.001) };
            into[at + 3] = falloffOf(lamp.falloff == .distance, lamp.attenuation, lamp.size, 1);
        } else if (app.world.get(entity, components3d.SpotLight3D)) |spot| {
            const aim = placed.forward().tryNorm() orelse continue;
            const angle = std.math.clamp(spot.angle, 0, std.math.degreesToRadians(89.9));
            const c = colorOf(spot.color, spot.energy);
            into[at] = .{ placed.position.x, placed.position.y, placed.position.z, 3 };
            into[at + 1] = .{ c[0], c[1], c[2], @max(spot.range, 0.001) };
            into[at + 2] = .{ aim.x, aim.y, aim.z, @cos(angle) };
            into[at + 3] = falloffOf(spot.falloff == .distance, spot.attenuation, spot.size, @max(spot.angle_attenuation, 0.01));
        }
    }
    return @min(uuids.len, most_lights);
}

/// A lamp's fall-off as the relighting reads it: its power, whether by the
/// distance, the nearest it counts from, and its cone's.
fn falloffOf(by_distance: bool, attenuation: f32, size: f32, cone: f32) [4]f32 {
    return .{
        if (by_distance) @max(attenuation, 0) else @max(attenuation, 0.01),
        if (by_distance) 1 else 0,
        lightmapper.lampNear(@max(size, 0)),
        cone,
    };
}

fn colorOf(color: Color, energy: f32) [3]f32 {
    const e = @max(energy, 0);
    return .{ toLinear(color.r) * e, toLinear(color.g) * e, toLinear(color.b) * e };
}

fn toLinear(x: f32) f32 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

const relight_part =
    \\attribute vec2 CORNER : 0;
    \\varying vec2 UV;
    \\uniform Relight : 0 {
    \\    vec4 ORIGIN;
    \\    vec4 COUNTS;
    \\    vec4 SIZES;
    \\    vec4 SKY;
    \\    vec4 TEXEL;
    \\    vec4 LIGHTS[64];
    \\}
    \\vertex {
    \\    UV = vec2(CORNER.x * 0.5 + 0.5, CORNER.y * 0.5 * TEXEL.x + 0.5);
    \\    position = vec4(CORNER, 0.0, 1.0);
    \\}
    \\
    \\// Ray `k`'s way: Fibonacci's spiral, as the bake's `volumeWay`.
    \\vec3 rayWay(float k) {
    \\    float z = 1.0 - (2.0 * k + 1.0) / TEXEL.z;
    \\    float r = sqrt(max(1.0 - z * z, 0.0));
    \\    float phi = 2.399963229728653 * k;
    \\    return vec3(r * cos(phi), r * sin(phi), z);
    \\}
    \\
    \\// How lit a surface facing `n` is by light whose mean over every way is
    \\// `c.x` and which leans along `c.yzw`: the 3D shader's own `leaning`.
    \\float leaning(vec4 c, vec3 n) {
    \\    float mean = max(c.x, 0.0);
    \\    vec3 lean = c.yzw * 0.5;
    \\    float size = length(lean);
    \\    if (mean <= 0.0 || size <= mean * 0.0001) {
    \\        return mean;
    \\    }
    \\    float k = min(size / mean, 1.0);
    \\    float q = max(0.5 * (1.0 + dot(lean / size, n)), 0.0);
    \\    float p = 1.0 + 2.0 * k;
    \\    float a = (1.0 - k) / (1.0 + k);
    \\    return mean * (a + (1.0 - a) * (p + 1.0) * pow(q, p));
    \\}
    \\
;

/// The light along each ray: what it met gives off, and the light falling
/// on that - each light it sees, as the light is now, and the volume's own
/// light of the frame before, where light bounces - times its colour; the
/// sky where it met nothing.
const rays_source = relight_part ++
    \\texture2d HITS : 0;
    \\texture2d BEFORE : 1;
    \\
    \\vec4 hitTexel(float k, float probe, float j) {
    \\    return sample_level(HITS, vec2((k * 3.0 + j + 0.5) * SIZES.x, (probe + 0.5) * SIZES.y), 0.0);
    \\}
    \\
    \\vec3 lightOf(int l, vec3 p, vec3 n) {
    \\    vec4 place = LIGHTS[l * 4];
    \\    vec4 shine = LIGHTS[l * 4 + 1];
    \\    if (place.w < 1.5) {
    \\        return shine.rgb * max(dot(n, place.xyz), 0.0);
    \\    }
    \\    vec4 aim = LIGHTS[l * 4 + 2];
    \\    vec4 fall = LIGHTS[l * 4 + 3];
    \\    vec3 to = place.xyz - p;
    \\    float d = length(to);
    \\    if (d >= shine.w || d <= 0.0) {
    \\        return vec3(0.0);
    \\    }
    \\    vec3 l_way = to / d;
    \\    float fade = 0.0;
    \\    if (fall.y > 0.5) {
    \\        float near = d / shine.w;
    \\        near = near * near;
    \\        near = max(1.0 - near * near, 0.0);
    \\        fade = near * near * pow(max(d, fall.z), -fall.x);
    \\    } else {
    \\        fade = pow(max(1.0 - d / shine.w, 0.0), fall.x);
    \\    }
    \\    if (place.w > 2.5) {
    \\        float cosine = dot(-l_way, aim.xyz);
    \\        if (fall.y > 0.5) {
    \\            float rim = max((1.0 - max(cosine, aim.w)) / max(1.0 - aim.w, 0.0001), 0.0001);
    \\            fade = fade * (1.0 - pow(rim, fall.w));
    \\        } else {
    \\            fade = fade * pow(clamp((cosine - aim.w) / max(1.0 - aim.w, 0.0001), 0.0, 1.0), fall.w);
    \\        }
    \\    }
    \\    return shine.rgb * (max(dot(n, l_way), 0.0) * fade);
    \\}
    \\
    \\// The volume's light of the frame before at `p` on a surface facing `n`:
    \\// the eight probes round it, by how near, those inside something left out.
    \\vec3 before(vec3 p, vec3 n) {
    \\    vec3 most = COUNTS.xyz - vec3(1.0);
    \\    vec3 grid = clamp((p - ORIGIN.xyz) / ORIGIN.w, vec3(0.0), most);
    \\    vec3 base = min(floor(grid), most);
    \\    vec3 f = grid - base;
    \\    vec3 sum = vec3(0.0);
    \\    float weight = 0.0;
    \\    for (int i = 0; i < 8; i = i + 1) {
    \\        vec3 corner = vec3(float(i - (i / 2) * 2), float((i / 2) - (i / 4) * 2), float(i / 4));
    \\        vec3 g = min(base + corner, most);
    \\        vec3 tri = mix(vec3(1.0) - f, f, corner);
    \\        float w = tri.x * tri.y * tri.z;
    \\        vec2 texel = vec2(g.x * 3.0 + 0.5, g.y + g.z * COUNTS.y + 0.5);
    \\        vec4 red = sample_level(BEFORE, texel * SIZES.zw, 0.0);
    \\        if (red.x >= 0.0 && w > 0.0) {
    \\            vec4 green = sample_level(BEFORE, (texel + vec2(1.0, 0.0)) * SIZES.zw, 0.0);
    \\            vec4 blue = sample_level(BEFORE, (texel + vec2(2.0, 0.0)) * SIZES.zw, 0.0);
    \\            sum = sum + vec3(leaning(red, n), leaning(green, n), leaning(blue, n)) * w;
    \\            weight = weight + w;
    \\        }
    \\    }
    \\    return weight > 0.0001 ? sum / weight : vec3(0.0);
    \\}
    \\
    \\fragment {
    \\    float k = floor(UV.x * TEXEL.z);
    \\    float probe = floor(UV.y / SIZES.y);
    \\    vec4 first = hitTexel(k, probe, 0.0);
    \\    if (first.x < 0.0) {
    \\        target = vec4(SKY.rgb, 1.0);
    \\    } else {
    \\        vec4 second = hitTexel(k, probe, 1.0);
    \\        vec4 third = hitTexel(k, probe, 2.0);
    \\        float xs = COUNTS.x;
    \\        float x = probe - floor(probe / xs) * xs;
    \\        float rest = floor(probe / xs);
    \\        float y = rest - floor(rest / COUNTS.y) * COUNTS.y;
    \\        float z = floor(rest / COUNTS.y);
    \\        vec3 at = ORIGIN.xyz + vec3(x, y, z) * ORIGIN.w;
    \\        vec3 n = first.yzw;
    \\        vec3 p = at + rayWay(k) * first.x + n * 0.02;
    \\        vec3 falling = vec3(0.0);
    \\        for (int l = 0; l < 16; l = l + 1) {
    \\            if (float(l) < COUNTS.w && mod(floor(second.w / exp2(float(l))), 2.0) >= 1.0) {
    \\                falling = falling + lightOf(l, p, n);
    \\            }
    \\        }
    \\        if (SKY.w > 0.5) {
    \\            falling = falling + before(p, n);
    \\        }
    \\        target = vec4(third.rgb + second.rgb * falling, 1.0);
    \\    }
    \\}
;

/// Each probe's light: its rays' light as the first two bands of spherical
/// harmonics, each colour's mean and lean - the 3D shader's `leaning` reads
/// them - blended into what it had; one inside something stays as it was.
const sum_source = relight_part ++
    \\texture2d RAYS : 0;
    \\texture2d BEFORE : 1;
    \\
    \\fragment {
    \\    vec2 texel = floor(UV / SIZES.zw);
    \\    vec4 had = sample_level(BEFORE, (texel + vec2(0.5)) * SIZES.zw, 0.0);
    \\    if (had.x < 0.0) {
    \\        target = had;
    \\    } else {
    \\        float x = floor(texel.x / 3.0);
    \\        float c = texel.x - x * 3.0;
    \\        float probe = x + texel.y * COUNTS.x;
    \\        float rows = COUNTS.x * COUNTS.y * COUNTS.z;
    \\        vec4 bands = vec4(0.0);
    \\        for (int k = 0; k < 128; k = k + 1) {
    \\            if (float(k) < TEXEL.z) {
    \\                vec3 seen = sample_level(RAYS, vec2((float(k) + 0.5) / TEXEL.z, (probe + 0.5) / rows), 0.0).rgb;
    \\                float light = c < 0.5 ? seen.r : (c < 1.5 ? seen.g : seen.b);
    \\                vec3 way = rayWay(float(k));
    \\                bands = bands + vec4(0.282095, 0.488603 * way.x, 0.488603 * way.y, 0.488603 * way.z) * light;
    \\            }
    \\        }
    \\        bands = bands * (12.566371 / TEXEL.z);
    \\        vec4 now = vec4(bands.x * 0.282095, bands.yzw * (0.488603 * 2.0 / 3.0));
    \\        target = mix(now, had, TEXEL.y);
    \\    }
    \\}
;

test "the relighting's shaders compile" {
    inline for (.{ rays_source, sum_source }) |source| {
        var said: std.Io.Writer.Allocating = .init(testing.allocator);
        defer said.deinit();
        var module = shader.compile(testing.allocator, source, &said.writer) catch |err| {
            std.debug.print("{s}\n", .{said.written()});
            return err;
        };
        module.deinit();
    }
}
