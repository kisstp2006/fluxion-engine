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
//! **Shadows.** A light with `shadow` on has what it lights cast one: see
//! `shadows3d.zig`. Before the world is drawn, what each such light sees of
//! it is drawn into the shadow atlas - each mesh with `cast_shadow` whose
//! box is in a light's view, drawn by its own shader's caster - and the
//! world is then lit through it. A light keeps its tiles from draw to draw,
//! and a view whose light and casters are as they were - its signature the
//! same - is not drawn again: a still room's lamps cost nothing after the
//! first frame, in every render view that sees them.
//!
//! **Cookies.** A spot light's `cookie` is drawn into a tile of the cookie
//! atlas - sixteen pictures at most in a frame - the first frame it is
//! needed, and the light takes its colours across its cone.
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
const shader = @import("fluxion_shader");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const lightmaps = @import("lightmaps.zig");
const mesh = @import("mesh.zig");
const post3d = @import("post3d.zig");
const shader3d = @import("shader3d.zig");
const shaders = @import("shaders.zig");
const shadows3d = @import("shadows3d.zig");
const UniformBlocks = @import("uniform_blocks.zig").UniformBlocks;
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
const GiMode = components3d.GiMode;
const LightmapGI = components3d.LightmapGI;

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
    /// Its entity: which light it is from draw to draw.
    entity: u64 = 0,
    /// Half a spot light's cone, in radians.
    angle: f32 = 0,
    /// A spot light's up: its cookie's top.
    up: math.Vec3 = .unit_y,
    /// Its cookie's picture, and the tile of the cookie atlas it is in.
    cookie: rhi.Texture = .none,
    cookie_tile: u32 = 0,
    /// Its shadow, where it casts one.
    shadow: ?shadows3d.Settings = null,

    fn nearer(_: void, a: Lamp, b: Lamp) bool {
        return a.distance < b.distance;
    }
};

/// A sun the frame is lit by.
const Sun = struct {
    toward: math.Vec3,
    /// Its colour times its energy, linear.
    color: [4]f32,
    /// Its shadow, where it casts one.
    shadow: ?shadows3d.Sun = null,
};

/// A surface drawn into one view of the shadow atlas.
const ShadowItem = struct {
    view: u32,
    item: Item,

    fn before(_: void, a: ShadowItem, b: ShadowItem) bool {
        if (a.view != b.view) return a.view < b.view;
        return Item.order(a.item, b.item) == .lt;
    }

    fn joins(a: ShadowItem, b: ShadowItem) bool {
        return a.view == b.view and Item.joins(a.item, b.item);
    }
};

/// A surface that casts a shadow, and where its mesh is.
const Caster = struct {
    item: Item,
    bounds: math.Aabb,
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
    /// Both, in one buffer a draw binds a part of, the materials' first.
    blocks: UniformBlocks = .{ .label = "3D materials" },
    /// Where each material's numbers are in `blocks`, and each set of a
    /// shader's.
    look_offsets: std.ArrayList(u32) = .empty,
    param_offsets: std.ArrayList(u32) = .empty,

    /// Every shadow's numbers, as the shader's `Shadows` block says.
    shadows: rhi.Buffer,
    /// The baked light from everywhere: the probes' samples for the meshes
    /// that move, as the shader's `Probes` block says, and the lightmap the
    /// frame reads, the lightmap asset's; read across at its edges.
    probes: rhi.Buffer,
    probe_data: shader3d.Probes = .{ .samples = @splat(@splat(0)), .energy = .{ 1, 0, 0, 0 } },
    lightmap: ?rhi.Texture = null,
    lightmap_sampler: rhi.Sampler,
    /// What the first `LightmapGI` with its data baked, which this draw
    /// reads; null for none.
    baked: ?*const lightmaps.Lightmap = null,
    /// The atlas the frame's shadows are drawn into, made the first time a
    /// light casts one and let go a few frames after none does; its size.
    atlas: ?rhi.Texture = null,
    atlas_size: u32 = 0,
    atlas_idle: u32 = 0,
    /// What it is made as: null where the device reads no depth, and no
    /// shadows are drawn.
    atlas_format: ?rhi.Format,
    /// Bound where the atlas is read when there is none: a depth of one.
    no_shadow: rhi.Texture,
    /// The atlas read by comparing, and as it is.
    comparing: rhi.Sampler,
    reading: rhi.Sampler,
    plan: shadows3d.Plan = .{},
    /// The tiles each light keeps in the atlas, and what was drawn into them.
    shadow_cache: ?shadows3d.Cache = null,
    /// Whether nothing has been drawn into the atlas since it was made.
    atlas_fresh: bool = false,
    /// What clears one tile of the atlas, when its view is drawn again.
    tile_clear: ?TileClear = null,
    /// The atlas as a picture a person can look at, made when asked for.
    atlas_picture: ?AtlasPicture = null,
    signatures: std.ArrayList(u64) = .empty,
    redraw: std.ArrayList(bool) = .empty,
    suns: std.ArrayList(Sun) = .empty,
    shadow_lamps: std.ArrayList(shadows3d.Lamp) = .empty,
    casters: std.ArrayList(Caster) = .empty,
    shadow_items: std.ArrayList(ShadowItem) = .empty,
    /// The spot lights' cookies, a tile each, made the first time a light
    /// has one; what picture each tile holds, drawn again only when that
    /// changes; and what draws one into its tile.
    cookie_atlas: ?rhi.Texture = null,
    cookie_tiles: [cookie_across * cookie_across]rhi.Texture = @splat(.none),
    cookie_copy: ?CookieCopy = null,
    /// Each view's `Frame`, in one buffer the shadow pass binds a part of.
    shadow_frames: UniformBlocks = .{ .label = "3D shadow views" },
    frame_offsets: std.ArrayList(u32) = .empty,
    /// The frame's numbers, as the last draw wrote them.
    frame_data: Frame = undefined,

    /// What the last draw drew: meshes, and the draws they took.
    drawn: u32 = 0,
    draw_calls: u32 = 0,
    /// The meshes it left out for being off the camera's frustum.
    culled: u32 = 0,
    /// The point and spot lights it kept, and the samples a pixel it drew
    /// with.
    lamps_kept: u32 = 0,
    samples: u32 = 1,
    /// The views of the atlas the last draw used, how many of them it drew
    /// again - the rest were as they were - the surfaces drawn into them, and
    /// the draws they took.
    shadow_views: u32 = 0,
    shadow_views_drawn: u32 = 0,
    shadow_casters: u32 = 0,
    shadow_draws: u32 = 0,
    /// The meshes the last draw lit from the lightmap, and from the probes.
    gi_lightmapped: u32 = 0,
    gi_probed: u32 = 0,

    const initial_capacity = 64;
    /// Draws an atlas no light has needed is kept for.
    const atlas_kept = 3;
    /// How large a cookie's tile is, and how many there are across.
    const cookie_size = 256;
    const cookie_across = 4;

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
        const shadow_block = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(shadows3d.Shadows), .dynamic = true, .label = "3D shadows" });
        errdefer device.destroyBuffer(shadow_block);
        const probes = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(shader3d.Probes), .dynamic = true, .label = "3D probes" });
        errdefer device.destroyBuffer(probes);
        const lightmap_sampler = try device.createSampler(.{});
        errdefer device.destroySampler(lightmap_sampler);
        const atlas_format = atlasFormat(device);
        const no_shadow = try noShadow(device, atlas_format, white);
        errdefer if (no_shadow != white) device.destroyTexture(no_shadow);
        const filtered = if (atlas_format) |format| device.caps().formatSupport(format).filterable else false;
        const comparing = try device.createSampler(.{
            .min_filter = if (filtered) .linear else .nearest,
            .mag_filter = if (filtered) .linear else .nearest,
            .compare = .less_equal,
        });
        errdefer device.destroySampler(comparing);
        const reading = try device.createSampler(.nearest);
        errdefer device.destroySampler(reading);
        var self: Renderer3D = .{
            .device = device,
            .depth_format = depthFormat(device),
            .frame = frame,
            .lights = lights,
            .instances = instances,
            .capacity = initial_capacity,
            .white = white,
            .flat = flat,
            .shadows = shadow_block,
            .probes = probes,
            .lightmap_sampler = lightmap_sampler,
            .atlas_format = atlas_format,
            .no_shadow = no_shadow,
            .comparing = comparing,
            .reading = reading,
        };
        if (atlas_format == null) log.warn("the {t} backend reads no depth here: 3D lights cast no shadows", .{device.info().backend});
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

    /// The most precise depth the device draws into and reads: what the
    /// shadow atlas is made as.
    fn atlasFormat(device: *rhi.Device) ?rhi.Format {
        for ([_]rhi.Format{ .depth32_float, .depth24_stencil8, .depth16_unorm }) |format| {
            const support = device.caps().formatSupport(format);
            if (support.render_target and support.sampled) return format;
        }
        return null;
    }

    /// A depth texture of one texel, at one: what is read where there is no
    /// atlas, by a shader that reads none of it. `white` where there is no
    /// depth to read.
    fn noShadow(device: *rhi.Device, format: ?rhi.Format, white: rhi.Texture) !rhi.Texture {
        const depth = format orelse return white;
        const texture = try device.createTexture(.{ .width = 1, .height = 1, .format = depth, .usage = .{ .sampled = true, .render_target = true }, .label = "no shadow" });
        errdefer device.destroyTexture(texture);
        const list = device.begin();
        try list.beginPass(.{ .depth = .{ .texture = texture } });
        try list.endPass();
        try device.submit();
        return texture;
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
        self.blocks.deinit(gpa, device);
        self.look_offsets.deinit(gpa);
        self.param_offsets.deinit(gpa);
        device.destroyBuffer(self.frame);
        device.destroyBuffer(self.lights);
        device.destroyBuffer(self.instances);
        device.destroyTexture(self.white);
        device.destroyTexture(self.flat);
        device.destroyBuffer(self.shadows);
        device.destroyBuffer(self.probes);
        device.destroySampler(self.lightmap_sampler);
        if (self.atlas) |atlas| device.destroyTexture(atlas);
        if (self.shadow_cache) |*cache| cache.deinit(gpa);
        if (self.tile_clear) |*clear| clear.deinit(device);
        if (self.atlas_picture) |*picture| picture.deinit(device);
        self.signatures.deinit(gpa);
        self.redraw.deinit(gpa);
        if (self.no_shadow != self.white) device.destroyTexture(self.no_shadow);
        device.destroySampler(self.comparing);
        device.destroySampler(self.reading);
        self.plan.deinit(gpa);
        self.suns.deinit(gpa);
        self.shadow_lamps.deinit(gpa);
        self.casters.deinit(gpa);
        self.shadow_items.deinit(gpa);
        self.shadow_frames.deinit(gpa, device);
        self.frame_offsets.deinit(gpa);
        if (self.cookie_atlas) |atlas| device.destroyTexture(atlas);
        if (self.cookie_copy) |*copy| copy.deinit(device);
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
    pub fn tick(self: *Renderer3D, gpa: Allocator) void {
        self.last_depth = null;
        if (self.post) |*held| held.tick();
        if (self.shadow_cache) |*cache| cache.frame += 1;
        if (self.atlas) |atlas| {
            self.atlas_idle += 1;
            if (self.atlas_idle > atlas_kept) {
                self.device.destroyTexture(atlas);
                self.atlas = null;
                self.atlas_size = 0;
                if (self.shadow_cache) |*cache| cache.deinit(gpa);
                self.shadow_cache = null;
            }
        }
    }

    /// Draw the 3D world through `view` into `into`, which is `width` by
    /// `height` pixels: in place of what is there, behind it all `clear` -
    /// or the environment's background - or over it as it is with null.
    pub fn draw(self: *Renderer3D, app: *App, into: rhi.RenderTarget, width: u32, height: u32, view: View3D, clear: ?Color, lighting: Lighting) !void {
        self.drawn = 0;
        self.draw_calls = 0;
        self.culled = 0;
        self.lamps_kept = 0;
        self.shadow_views = 0;
        self.shadow_views_drawn = 0;
        self.shadow_casters = 0;
        self.shadow_draws = 0;
        self.gi_lightmapped = 0;
        self.gi_probed = 0;
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
        const rendering: Project.Rendering = if (app.project.settings) |held| held.rendering else .{};
        try self.findBaked(app);
        try self.gatherLamps(app, view, frustum);
        try self.gatherSuns(app);
        try self.planShadows(gpa, view, rendering);
        try self.gather(app, view, frustum, self.plan.views.items.len > 0);
        try self.gatherShadowItems(gpa);
        std.mem.sort(Item, self.items.items, {}, Item.before);
        self.staging.clearRetainingCapacity();
        try self.staging.ensureTotalCapacity(gpa, self.items.items.len + self.shadow_items.items.len);
        for (self.items.items) |item| self.staging.appendAssumeCapacity(self.gathered.items[item.instance]);
        for (self.shadow_items.items) |shadowed| self.staging.appendAssumeCapacity(self.gathered.items[shadowed.item.instance]);
        try self.upload(gpa);
        try self.placeCookies(gpa);
        try self.uploadFrame(app, view, view_projection, environment, lighting);
        try self.drawShadows(gpa);
        const shadow_map = if (self.shadow_views > 0) self.atlas.? else self.no_shadow;

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
            try list.setUniformBufferRange(1, self.blocks.buffer.?, self.look_offsets.items[first.look], @sizeOf(Look));
            try list.setUniformBuffer(2, self.lights);
            if (first.params != no_params) {
                const set = self.param_sets.items[first.params];
                try list.setUniformBufferRange(shader3d.params_slot, self.blocks.buffer.?, self.param_offsets.items[first.params], set.len);
            }
            try list.setUniformBuffer(shader3d.shadows_slot, self.shadows);
            for (first.textures, 0..) |texture, slot| try list.setTexture(@intCast(slot), texture, first.sampler);
            try list.setTexture(shader3d.shadow_map_slot, shadow_map, self.comparing);
            try list.setTexture(shader3d.shadow_depth_slot, shadow_map, self.reading);
            try list.setTexture(shader3d.cookie_slot, self.cookie_atlas orelse self.white, self.cookieSampler());
            try list.setUniformBuffer(shader3d.probes_slot, self.probes);
            try list.setTexture(shader3d.lightmap_slot, self.lightmap orelse self.white, self.lightmap_sampler);
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
            .screen = .{ view.width, view.height, 0, 0 },
            .time = @floatCast(app.interface.seconds),
        };
        for (self.suns.items, 0..) |sun, at| {
            frame.sun_directions[at] = .{ sun.toward.x, sun.toward.y, sun.toward.z, 0 };
            frame.sun_colors[at] = sun.color;
        }
        if (self.suns.items.len == 0 and lighting.preview) {
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
        self.frame_data = frame;
        try self.device.updateBuffer(self.shadows, 0, std.mem.asBytes(&self.plan.block));
        try self.device.updateBuffer(self.probes, 0, std.mem.asBytes(&self.probe_data));

        var lights: Lights = .{
            .places = @splat(@splat(0)),
            .colors = @splat(@splat(0)),
            .aims = @splat(@splat(0)),
            .cones = @splat(@splat(0)),
            .ups = @splat(@splat(0)),
            .cookies = @splat(@splat(0)),
        };
        const bottom_left = self.device.caps().features.render_target_origin_bottom_left;
        for (self.lamps.items, 0..) |lamp, at| {
            lights.places[at] = .{ lamp.place.x, lamp.place.y, lamp.place.z, lamp.range };
            lights.colors[at] = .{ lamp.color[0], lamp.color[1], lamp.color[2], lamp.attenuation };
            lights.aims[at] = .{ lamp.aim.x, lamp.aim.y, lamp.aim.z, lamp.edge };
            lights.cones[at] = .{ lamp.cone, 0, 0, 0 };
            lights.ups[at] = .{ lamp.up.x, lamp.up.y, lamp.up.z, @tan(lamp.angle) };
            if (!lamp.cookie.isNone()) lights.cookies[at] = cookieRect(lamp.cookie_tile, bottom_left);
        }
        try self.device.updateBuffer(self.lights, 0, std.mem.asBytes(&lights));
    }

    /// The first visible `LightmapGI` with what it baked: what this draw
    /// reads the light from everywhere from, its picture made for the
    /// device the first time.
    fn findBaked(self: *Renderer3D, app: *App) !void {
        self.baked = null;
        self.lightmap = null;
        self.probe_data.energy = .{ 1, 0, 0, 0 };
        var it = try ecs.Query(.{LightmapGI}).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(LightmapGI), chunk.entities) |gi, entity| {
                if (gi.data.isNone()) continue;
                if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
                const held = app.lightmaps.get(gi.data) orelse continue;
                self.baked = held;
                self.lightmap = try app.lightmaps.textureOf(self.device, gi.data);
                self.probe_data.energy = .{ @max(gi.energy, 0), 0, 0, 0 };
                return;
            }
        }
    }

    /// Where a mesh's light from everywhere is read, as `Instance.gi` says:
    /// its place in the lightmap, the probes' light round it - one more of
    /// the frame's probe samples - or the environment's.
    fn giOf(self: *Renderer3D, app: *App, entity: ecs.Entity, mode: GiMode, bounds: math.Aabb) [4]f32 {
        const baked = self.baked orelse return @splat(0);
        if (mode == .off) return @splat(0);
        if (mode == .static) if (app.uuidOf(entity)) |uuid| if (baked.placeOf(uuid)) |place| {
            self.gi_lightmapped += 1;
            return place;
        };
        if (self.gi_probed == shader3d.most_probe_samples) return @splat(0);
        const light = baked.probeLight(bounds.center().array()) orelse return @splat(0);
        const at = self.gi_probed;
        self.gi_probed += 1;
        for (0..3) |c| self.probe_data.samples[at * 3 + c] = light[c * 4 ..][0..4].*;
        return .{ -@as(f32, @floatFromInt(at)) - 1, 0, 0, 0 };
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
                    // Baked whole: its light is in the lightmap.
                    if (light.bake == .all and self.baked != null) continue;
                    const placed = placedLight(app, entity) orelse continue;
                    var lamp = lampOf(placed.position, light.color, light.energy, light.range, light.attenuation);
                    lamp.entity = entity.toInt();
                    if (light.shadow) lamp.shadow = .{ .bias = light.shadow_bias, .normal_bias = light.shadow_normal_bias, .blur = light.shadow_blur, .size = @max(light.size, 0) };
                    // Its way and up, which turn its cookie; its cone is none.
                    lamp.aim = placed.forward().tryNorm() orelse .init(0, 0, -1);
                    lamp.up = placed.up().tryNorm() orelse .unit_y;
                    if (!light.cookie.isNone()) if (app.assets.get(light.cookie)) |held| {
                        lamp.cookie = held.gpu;
                    };
                    try self.keepLamp(gpa, view, frustum, lamp, .{
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
                    if (light.bake == .all and self.baked != null) continue;
                    const placed = placedLight(app, entity) orelse continue;
                    var lamp = lampOf(placed.position, light.color, light.energy, light.range, light.attenuation);
                    lamp.entity = entity.toInt();
                    lamp.aim = placed.forward().tryNorm() orelse continue;
                    lamp.angle = std.math.clamp(light.angle, 0, std.math.degreesToRadians(89.9));
                    lamp.edge = @cos(lamp.angle);
                    lamp.up = placed.up().tryNorm() orelse .unit_y;
                    if (!light.cookie.isNone()) if (app.assets.get(light.cookie)) |held| {
                        lamp.cookie = held.gpu;
                    };
                    lamp.cone = @max(light.angle_attenuation, 0.01);
                    if (light.shadow) lamp.shadow = .{ .bias = light.shadow_bias, .normal_bias = light.shadow_normal_bias, .blur = light.shadow_blur, .size = @max(light.size, 0) };
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
    /// unsorted - and with `casting`, what every mesh that casts a shadow
    /// casts it with.
    fn gather(self: *Renderer3D, app: *App, view: View3D, frustum: math.Frustum, casting: bool) !void {
        const gpa = app.gpa;
        self.gathered.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.casters.clearRetainingCapacity();
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
                const seen = frustum.testAabb(bounds) != .outside;
                const casts = casting and instance.cast_shadow;
                if (!seen) self.culled += 1;
                if (!seen and !casts) continue;
                kept.used = app.meshes.clock;
                const gpu = try kept.uploaded(self.device);
                const depth = bounds.center().sub(view.position).dot(forward);
                const own: MaterialHandle = if (app.world.get(entity, Material3D)) |held| held.material else .none;
                const at: u32 = @intCast(self.gathered.items.len);
                try self.gathered.append(gpa, .{
                    .model = .{ model.cols[0].array(), model.cols[1].array(), model.cols[2].array(), model.cols[3].array() },
                    .tint = linear(looks.tint(.white)),
                    .lights = if (seen) self.lampsFor(bounds) else @splat(@splat(-1)),
                    .gi = if (seen) self.giOf(app, entity, instance.gi_mode, bounds) else @splat(0),
                });
                for (kept.mesh.surfaces) |surface| {
                    if (surface.index_count == 0) continue;
                    const chosen = if (!own.isNone() and app.materials.get(own) != null) own else surface.material;
                    const look = materialOf(app, chosen);
                    var compiled = if (look.shader.isNone()) plain else app.shaders.compiled3DOf(look.shader) orelse plain;
                    if (compiled.refused) compiled = plain;
                    // Between levels too: a surface's pictures are asked for
                    // their chains, and read from them once they have them.
                    var sampler = app.assets.mipSamplerFor(.linear, .repeat);
                    var textures: [5]rhi.Texture = .{ self.white, self.white, self.white, self.flat, self.white };
                    for ([_]@TypeOf(look.albedo_texture){ look.albedo_texture, look.emission_texture, look.metallic_roughness_texture, look.normal_texture, look.occlusion_texture }, 0..) |handle, slot| {
                        if (handle.isNone()) continue;
                        const held = app.assets.get(handle) orelse continue;
                        app.assets.wantMips(handle);
                        textures[slot] = held.gpu;
                        if (slot == 0) sampler = app.assets.mipSamplerFor(held.filter, .repeat);
                    }
                    const blend = look.transparency == .alpha;
                    const way: Way = .{ .cull = look.cull, .blend = blend };
                    const item: Item = .{
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
                    };
                    if (seen) try self.items.append(gpa, item);
                    // What is laid over what is behind it casts no shadow.
                    if (casts and !blend) try self.casters.append(gpa, .{ .item = item, .bounds = bounds });
                }
            }
        }
    }

    /// Each visible `DirectionalLight3D`, up to `shader3d.most_suns`, and
    /// what its shadow is where it casts one.
    fn gatherSuns(self: *Renderer3D, app: *App) !void {
        self.suns.clearRetainingCapacity();
        var it = try ecs.Query(.{ Transform3D, DirectionalLight3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(DirectionalLight3D), chunk.entities) |light, entity| {
                if (self.suns.items.len == shader3d.most_suns) return;
                if (light.bake == .all and self.baked != null) continue;
                const placed = placedLight(app, entity) orelse continue;
                const toward = placed.back().tryNorm() orelse continue;
                const c = linear(light.color);
                const e = @max(light.energy, 0);
                const index: u32 = @intCast(self.suns.items.len);
                try self.suns.append(app.gpa, .{
                    .toward = toward,
                    .color = .{ c[0] * e, c[1] * e, c[2] * e, 1 },
                    .shadow = if (!light.shadow) null else .{
                        .index = index,
                        .toward = toward,
                        .settings = .{
                            .bias = light.shadow_bias,
                            .normal_bias = light.shadow_normal_bias,
                            .blur = light.shadow_blur,
                            // How much wider its shadow gets a unit further from what casts it.
                            .size = 2 * @tan(std.math.clamp(light.angular_size, 0, 1) / 2),
                        },
                        .cascades = light.shadow_cascades.count(),
                        .max_distance = @max(light.shadow_max_distance, 0.1),
                    },
                });
            }
        }
    }

    /// The views of the atlas this draw's shadows take: the suns' and the
    /// lamps' that cast one, those lighting more of the picture first.
    fn planShadows(self: *Renderer3D, gpa: Allocator, view: View3D, rendering: Project.Rendering) !void {
        self.plan.views.clearRetainingCapacity();
        self.plan.block = .none();
        const format = self.atlas_format orelse return;
        var suns: [shader3d.most_suns]shadows3d.Sun = undefined;
        var sun_count: usize = 0;
        for (self.suns.items) |sun| if (sun.shadow) |shadow| {
            suns[sun_count] = shadow;
            sun_count += 1;
        };
        self.shadow_lamps.clearRetainingCapacity();
        for (self.lamps.items, 0..) |lamp, at| {
            const settings = lamp.shadow orelse continue;
            try self.shadow_lamps.append(gpa, .{
                .index = @intCast(at),
                .light = lamp.entity,
                .place = lamp.place,
                .range = lamp.range,
                .spot = if (lamp.edge > -1.5) .{ .aim = lamp.aim, .angle = lamp.angle } else null,
                .settings = settings,
                .distance = lamp.distance,
            });
        }
        if (sun_count == 0 and self.shadow_lamps.items.len == 0) return;
        std.mem.sort(shadows3d.Lamp, self.shadow_lamps.items, {}, lightsMore);

        const device = self.device;
        const size = @min(rendering.shadow_atlas_size.pixels(), device.caps().limits.max_texture_2d);
        if (self.atlas == null or self.atlas_size != size) {
            if (self.atlas) |old| device.destroyTexture(old);
            self.atlas = null;
            if (self.shadow_cache) |*cache| cache.deinit(gpa);
            self.shadow_cache = null;
            self.atlas = try device.createTexture(.{ .width = size, .height = size, .format = format, .usage = .{ .sampled = true, .render_target = true }, .label = "shadow atlas" });
            self.atlas_size = size;
            self.shadow_cache = try .init(gpa, size);
            self.atlas_fresh = true;
        }
        self.atlas_idle = 0;
        try shadows3d.plan(gpa, &self.plan, &self.shadow_cache.?, view, suns[0..sun_count], self.shadow_lamps.items, .{
            .atlas = size,
            .filter = switch (rendering.shadow_filter) {
                .hard => .hard,
                .soft_low => .soft_low,
                .soft_medium => .soft_medium,
                .soft_high => .soft_high,
            },
            .clip = device.clip(),
            .bottom_left = device.caps().features.render_target_origin_bottom_left,
        });
    }

    /// What each view of the atlas draws: the casters whose box is in it,
    /// sorted by view and then by how they are drawn.
    fn gatherShadowItems(self: *Renderer3D, gpa: Allocator) !void {
        self.shadow_items.clearRetainingCapacity();
        for (self.plan.views.items, 0..) |shadow_view, at| {
            for (self.casters.items) |caster| {
                if (shadow_view.reach) |reach| if (!reach.intersectsAabb(caster.bounds)) continue;
                if (shadow_view.frustum.testAabb(caster.bounds) == .outside) continue;
                try self.shadow_items.append(gpa, .{ .view = @intCast(at), .item = caster.item });
            }
        }
        std.mem.sort(ShadowItem, self.shadow_items.items, {}, ShadowItem.before);
        self.shadow_casters = @intCast(self.shadow_items.items.len);
    }

    /// What a view of the atlas would draw, as one number: its light and
    /// tile, and each surface cast into it - where its mesh is, what it is
    /// and its material - or a new number every time, where a surface's
    /// shader reads the time.
    fn signatureOf(self: *const Renderer3D, shadow_view: shadows3d.View, items: []const ShadowItem) u64 {
        var hash: std.hash.Wyhash = .init(0);
        hash.update(std.mem.asBytes(&shadow_view.render));
        hash.update(std.mem.asBytes(&shadow_view.tile));
        for (items) |shadowed| {
            const item = shadowed.item;
            if (item.compiled.reads_time) return self.shadow_cache.?.draw *% 0x9E37_79B9_7F4A_7C15 | 1;
            hash.update(std.mem.asBytes(&self.gathered.items[item.instance].model));
            hash.update(std.mem.asBytes(&@intFromPtr(item.compiled)));
            hash.update(std.mem.asBytes(&item.gpu));
            hash.update(std.mem.asBytes(&[_]u32{ item.first_index, item.index_count, item.way }));
            hash.update(std.mem.asBytes(&item.textures[0]));
            hash.update(std.mem.asBytes(&self.looks.items[item.look]));
            if (item.params != no_params) {
                const set = self.param_sets.items[item.params];
                hash.update(self.param_bytes.items[set.start..][0..set.len]);
            }
        }
        // Nought is "nothing drawn yet".
        return hash.final() | 1;
    }

    /// The shadow atlas as a picture to look at - 512 texels a side, the
    /// atlas's top at the top, nearer its light lighter, an empty tile black - or
    /// null when there is no atlas. An editor shows it beside `plan.views`.
    pub fn shadowAtlasPicture(self: *Renderer3D, gpa: Allocator) !?rhi.Texture {
        const atlas = self.atlas orelse return null;
        if (self.atlas_picture == null) self.atlas_picture = try .init(gpa, self.device);
        const picture = &self.atlas_picture.?;
        try picture.draw(self.device, atlas, self.reading);
        return picture.texture;
    }

    /// The views of the atlas whose signature is not what was drawn into
    /// their tiles last drawn again - each tile cleared, and what casts into
    /// it drawn, depth alone, by each surface's own shader's caster - in one
    /// pass; the others left as they are.
    fn drawShadows(self: *Renderer3D, gpa: Allocator) !void {
        const views = self.plan.views.items;
        if (views.len == 0) return;
        self.shadow_views = @intCast(views.len);
        const device = self.device;
        const atlas = self.atlas.?;
        const format = self.atlas_format.?;
        const cache = &self.shadow_cache.?;

        // Which views changed: the items are sorted by view.
        const all = self.shadow_items.items;
        try self.signatures.resize(gpa, views.len);
        try self.redraw.resize(gpa, views.len);
        var stale = false;
        {
            var at: usize = 0;
            for (views, 0..) |shadow_view, index| {
                const from = at;
                while (at < all.len and all[at].view == index) at += 1;
                self.signatures.items[index] = self.signatureOf(shadow_view, all[from..at]);
                const entry = cache.entries.getPtr(shadow_view.key).?;
                self.redraw.items[index] = self.atlas_fresh or entry.signature != self.signatures.items[index];
                stale = stale or self.redraw.items[index];
            }
        }
        if (!stale) return;
        if (self.tile_clear == null) self.tile_clear = try .init(gpa, device, format);

        // Each view's frame: the draw's, seen from its light.
        self.shadow_frames.clear();
        self.frame_offsets.clearRetainingCapacity();
        for (views) |shadow_view| {
            var frame = self.frame_data;
            frame.view_projection = shadow_view.render;
            try self.frame_offsets.append(gpa, try self.shadow_frames.place(gpa, device, std.mem.asBytes(&frame)));
        }
        try self.shadow_frames.upload(device);

        const list = device.begin();
        try list.beginPass(.{ .depth = .{ .texture = atlas, .load = if (self.atlas_fresh) .clear else .load, .clear_depth = 1 } });
        const items = self.shadow_items.items;
        const first_instance = self.items.items.len;
        // Each view drawn again: its tile cleared, before what casts into it.
        for (views, 0..) |shadow_view, index| {
            if (!self.redraw.items[index]) continue;
            cache.entries.getPtr(shadow_view.key).?.signature = self.signatures.items[index];
            self.shadow_views_drawn += 1;
            if (self.atlas_fresh) continue;
            const tile = shadow_view.tile;
            try list.setViewport(.{ .x = @floatFromInt(tile.x), .y = @floatFromInt(tile.y), .width = @floatFromInt(tile.size), .height = @floatFromInt(tile.size) });
            try list.setScissor(.{ .x = @intCast(tile.x), .y = @intCast(tile.y), .width = tile.size, .height = tile.size });
            try self.tile_clear.?.draw(list);
        }
        var start: usize = 0;
        var current: ?u32 = null;
        while (start < items.len) {
            var end = start + 1;
            while (end < items.len and ShadowItem.joins(items[start], items[end])) end += 1;
            const shadowed = items[start];
            // A view as it was is skipped whole.
            if (!self.redraw.items[shadowed.view]) {
                start = end;
                continue;
            }
            if (current != shadowed.view) {
                current = shadowed.view;
                const tile = views[shadowed.view].tile;
                try list.setViewport(.{ .x = @floatFromInt(tile.x), .y = @floatFromInt(tile.y), .width = @floatFromInt(tile.size), .height = @floatFromInt(tile.size) });
                try list.setScissor(.{ .x = @intCast(tile.x), .y = @intCast(tile.y), .width = tile.size, .height = tile.size });
            }
            var first = shadowed.item;
            const way = Way.of(first.way);
            // A shader whose caster the device refuses casts as the engine's.
            const pipeline = first.compiled.casterPipelineOf(device, format, way.cull) catch |err| blk: {
                const plain = &self.plain.?;
                if (first.compiled == plain) return err;
                first.params = no_params;
                break :blk try plain.casterPipelineOf(device, format, way.cull);
            };
            try list.setPipeline(pipeline);
            try list.setUniformBufferRange(0, self.shadow_frames.buffer.?, self.frame_offsets.items[shadowed.view], @sizeOf(Frame));
            try list.setUniformBufferRange(1, self.blocks.buffer.?, self.look_offsets.items[first.look], @sizeOf(Look));
            try list.setUniformBuffer(2, self.lights);
            if (first.params != no_params) {
                const set = self.param_sets.items[first.params];
                try list.setUniformBufferRange(shader3d.params_slot, self.blocks.buffer.?, self.param_offsets.items[first.params], set.len);
            }
            try list.setUniformBuffer(shader3d.shadows_slot, self.shadows);
            for (first.textures, 0..) |texture, slot| try list.setTexture(@intCast(slot), texture, first.sampler);
            try list.setTexture(shader3d.shadow_map_slot, self.no_shadow, self.comparing);
            try list.setTexture(shader3d.shadow_depth_slot, self.no_shadow, self.reading);
            try list.setTexture(shader3d.cookie_slot, self.cookie_atlas orelse self.white, self.cookieSampler());
            try list.setUniformBuffer(shader3d.probes_slot, self.probes);
            try list.setTexture(shader3d.lightmap_slot, self.lightmap orelse self.white, self.lightmap_sampler);
            try list.setVertexBuffer(0, first.gpu.vertices, 0);
            try list.setVertexBuffer(1, self.instances, @intCast((first_instance + start) * @sizeOf(Instance)));
            try list.setIndexBuffer(first.gpu.indices, .u32);
            try list.drawIndexed(.{ .index_count = first.index_count, .first_index = first.first_index, .instance_count = @intCast(end - start) });
            self.shadow_draws += 1;
            start = end;
        }
        try list.endPass();
        try device.submit();
        self.atlas_fresh = false;
    }

    /// Every kept lamp's cookie into a tile of the cookie atlas: the one that
    /// holds its picture already, or one no lamp of this draw needs, into
    /// which it is drawn.
    fn placeCookies(self: *Renderer3D, gpa: Allocator) !void {
        var wanted = false;
        for (self.lamps.items) |lamp| wanted = wanted or !lamp.cookie.isNone();
        if (!wanted) return;
        const device = self.device;
        var fresh = false;
        if (self.cookie_atlas == null) {
            self.cookie_atlas = try device.createTexture(.{
                .width = cookie_size * cookie_across,
                .height = cookie_size * cookie_across,
                .usage = .{ .sampled = true, .render_target = true },
                .label = "cookie atlas",
            });
            self.cookie_tiles = @splat(.none);
            fresh = true;
        }
        if (self.cookie_copy == null) self.cookie_copy = try .init(gpa, device);

        var used: [cookie_across * cookie_across]bool = @splat(false);
        var drawn: [cookie_across * cookie_across]bool = @splat(false);
        // Those already there first, so a new picture takes a tile no lamp keeps.
        for (self.lamps.items) |*lamp| {
            if (lamp.cookie.isNone()) continue;
            for (self.cookie_tiles, 0..) |held, at| if (held == lamp.cookie) {
                lamp.cookie_tile = @intCast(at);
                used[at] = true;
                break;
            };
        }
        for (self.lamps.items) |*lamp| {
            if (lamp.cookie.isNone() or self.cookie_tiles[lamp.cookie_tile] == lamp.cookie) continue;
            const free = std.mem.indexOfScalar(bool, &used, false) orelse {
                // More pictures than tiles: this one shines plain.
                lamp.cookie = .none;
                continue;
            };
            used[free] = true;
            drawn[free] = true;
            self.cookie_tiles[free] = lamp.cookie;
            lamp.cookie_tile = @intCast(free);
            // Another lamp with the same picture finds it there.
            for (self.lamps.items) |*other| if (other.cookie == lamp.cookie) {
                other.cookie_tile = @intCast(free);
            };
        }
        if (std.mem.indexOfScalar(bool, &drawn, true) == null and !fresh) return;

        const copy = &self.cookie_copy.?;
        const list = device.begin();
        try list.beginPass(.{ .color = .{ .target = .{ .texture = self.cookie_atlas.? }, .load = if (fresh) .clear else .load, .clear_color = .{ 1, 1, 1, 1 } } });
        try list.setPipeline(copy.pipeline);
        try list.setVertexBuffer(0, copy.corners, 0);
        for (drawn, 0..) |draw_it, at| {
            if (!draw_it) continue;
            const x: f32 = @floatFromInt((at % cookie_across) * cookie_size);
            const y: f32 = @floatFromInt((at / cookie_across) * cookie_size);
            try list.setViewport(.{ .x = x, .y = y, .width = cookie_size, .height = cookie_size });
            try list.setTexture(0, self.cookie_tiles[at], copy.sampler);
            try list.draw(.{ .vertex_count = 4 });
        }
        try list.endPass();
        try device.submit();
    }

    /// What the cookie atlas is read with: smoothly, kept inside it.
    fn cookieSampler(self: *const Renderer3D) rhi.Sampler {
        return if (self.cookie_copy) |copy| copy.sampler else self.reading;
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

        self.blocks.clear();
        self.look_offsets.clearRetainingCapacity();
        self.param_offsets.clearRetainingCapacity();
        for (self.looks.items) |*look| try self.look_offsets.append(gpa, try self.blocks.place(gpa, device, std.mem.asBytes(look)));
        for (self.param_sets.items) |set| try self.param_offsets.append(gpa, try self.blocks.place(gpa, device, self.param_bytes.items[set.start..][0..set.len]));
        try self.blocks.upload(device);
    }
};

/// Where the cookie in `tile` is in the cookie atlas, as the shader reads
/// it: across and down from where, and how far for the whole picture - up
/// the atlas, for a device that stores what is drawn bottom row first.
fn cookieRect(tile: u32, bottom_left: bool) [4]f32 {
    const across: f32 = Renderer3D.cookie_across;
    const u = @as(f32, @floatFromInt(tile % Renderer3D.cookie_across)) / across;
    const v = @as(f32, @floatFromInt(tile / Renderer3D.cookie_across)) / across;
    const s = 1 / across;
    return if (bottom_left) .{ u, 1 - v, s, -s } else .{ u, v, s, s };
}

/// The shadow atlas drawn into a picture to look at. Both are drawn into, so
/// on a device that stores what is drawn bottom row first they are turned
/// the same way, and reading the one at the other's place shows the atlas
/// its top at the top on every device.
const AtlasPicture = struct {
    gpu: rhi.Shader,
    pipeline: rhi.Pipeline,
    corners: rhi.Buffer,
    texture: rhi.Texture,

    const size = 512;

    const source =
        \\attribute vec2 corner : 0;
        \\varying vec2 at;
        \\texture2d depths : 0;
        \\vertex {
        \\    at = vec2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);
        \\    position = vec4(corner, 0.0, 1.0);
        \\}
        \\fragment {
        \\    float d = sample_level(depths, at, 0.0).r;
        \\    // Most of a view's depth is near its far end: stretched, so what
        \\    // is drawn shows, and what is empty is black.
        \\    float near = 0.0;
        \\    if (d < 1.0) {
        \\        near = 0.15 + 0.85 * pow(1.0 - d, 0.125);
        \\    }
        \\    target = vec4(vec3(near), 1.0);
        \\}
    ;

    fn init(gpa: Allocator, device: *rhi.Device) !AtlasPicture {
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        var module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("the shadow atlas picture's shader: {s}", .{said.written()});
            return err;
        };
        defer module.deinit();
        const gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "shadow atlas picture",
        });
        errdefer device.destroyShader(gpu);
        const pipeline = try device.createPipeline(.{
            .shader = gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = 8 }},
            .textures = &.{"depths"},
            .label = "shadow atlas picture",
        });
        errdefer device.destroyPipeline(pipeline);
        const corners = [6]f32{ -1, -1, 3, -1, -1, 3 };
        const buffer = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "shadow atlas picture" });
        errdefer device.destroyBuffer(buffer);
        const texture = try device.createTexture(.{ .width = size, .height = size, .usage = .{ .sampled = true, .render_target = true }, .label = "shadow atlas picture" });
        return .{ .gpu = gpu, .pipeline = pipeline, .corners = buffer, .texture = texture };
    }

    fn deinit(self: *AtlasPicture, device: *rhi.Device) void {
        device.destroyTexture(self.texture);
        device.destroyBuffer(self.corners);
        device.destroyPipeline(self.pipeline);
        device.destroyShader(self.gpu);
    }

    fn draw(self: *const AtlasPicture, device: *rhi.Device, atlas: rhi.Texture, sampler: rhi.Sampler) !void {
        const list = device.begin();
        try list.beginPass(.{ .color = .{ .target = .{ .texture = self.texture } } });
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.setTexture(0, atlas, sampler);
        try list.draw(.{ .vertex_count = 3 });
        try list.endPass();
        try device.submit();
    }
};

/// What clears one tile of the shadow atlas: a quad over the viewport at the
/// far plane, its depth written whatever was there.
const TileClear = struct {
    gpu: rhi.Shader,
    pipeline: rhi.Pipeline,
    corners: rhi.Buffer,

    const source =
        \\attribute vec2 corner : 0;
        \\vertex {
        \\    position = vec4(corner * 2.0 - 1.0, 1.0, 1.0);
        \\}
        \\fragment {
        \\}
    ;

    fn init(gpa: Allocator, device: *rhi.Device, depth_format: rhi.Format) !TileClear {
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        var module = shader.compileWith(gpa, source, &said.writer, .{ .depth_only = true }) catch |err| {
            log.err("the shadow tile shader: {s}", .{said.written()});
            return err;
        };
        defer module.deinit();
        const gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "shadow tile",
        });
        errdefer device.destroyShader(gpu);
        const pipeline = try device.createPipeline(.{
            .shader = gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = 8 }},
            .topology = .triangle_strip,
            .depth = .{ .test_enabled = true, .write = true, .compare = .always },
            .color_format = null,
            .depth_format = depth_format,
            .label = "shadow tile",
        });
        errdefer device.destroyPipeline(pipeline);
        const corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        const buffer = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "shadow tile quad" });
        return .{ .gpu = gpu, .pipeline = pipeline, .corners = buffer };
    }

    fn deinit(self: *TileClear, device: *rhi.Device) void {
        device.destroyBuffer(self.corners);
        device.destroyPipeline(self.pipeline);
        device.destroyShader(self.gpu);
    }

    /// The tile the viewport is on cleared.
    fn draw(self: *const TileClear, list: *rhi.CommandList) !void {
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.draw(.{ .vertex_count = 4 });
    }
};

/// What draws a picture into a tile of the cookie atlas: a quad over the
/// tile, the picture's top at the top.
const CookieCopy = struct {
    gpu: rhi.Shader,
    pipeline: rhi.Pipeline,
    corners: rhi.Buffer,
    sampler: rhi.Sampler,

    const source =
        \\attribute vec2 corner : 0;
        \\varying vec2 uv;
        \\texture2d picture : 0;
        \\vertex {
        \\    uv = vec2(corner.x, 1.0 - corner.y);
        \\    position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
        \\}
        \\fragment {
        \\    target = sample(picture, uv);
        \\}
    ;

    fn init(gpa: Allocator, device: *rhi.Device) !CookieCopy {
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        var module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("the cookie shader: {s}", .{said.written()});
            return err;
        };
        defer module.deinit();
        const gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "cookie",
        });
        errdefer device.destroyShader(gpu);
        const pipeline = try device.createPipeline(.{
            .shader = gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = 8 }},
            .topology = .triangle_strip,
            .textures = &.{"picture"},
            .label = "cookie",
        });
        errdefer device.destroyPipeline(pipeline);
        const corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        const buffer = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "cookie quad" });
        errdefer device.destroyBuffer(buffer);
        const sampler = try device.createSampler(.{});
        return .{ .gpu = gpu, .pipeline = pipeline, .corners = buffer, .sampler = sampler };
    }

    fn deinit(self: *CookieCopy, device: *rhi.Device) void {
        device.destroySampler(self.sampler);
        device.destroyBuffer(self.corners);
        device.destroyPipeline(self.pipeline);
        device.destroyShader(self.gpu);
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

/// Whether lamp `a` lights more of the picture than `b`: nearer the camera
/// for how far it reaches. Its shadow gets the larger tile.
fn lightsMore(_: void, a: shadows3d.Lamp, b: shadows3d.Lamp) bool {
    return a.range / @max(a.distance, 0.001) > b.range / @max(b.distance, 0.001);
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
