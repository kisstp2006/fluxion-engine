// SPDX-License-Identifier: BSD-3-Clause

//! Flat pictures in the 3D world: each `Sprite3D`'s picture, each
//! `Label3D`'s letters and each `Particles3D`'s particles, as quads made on
//! the CPU each frame - turned as their entity is, or facing the camera -
//! into one vertex buffer, and drawn in the 3D pass with a shader of their
//! own: not lit, but in the environment's fog and the fog volumes.
//!
//! **Where in the pass.** What is cut by its alpha - a `Sprite3D` with an
//! `alpha_cut` - is drawn after the solid surfaces, writing depth as they
//! do. What is see-through is drawn among the see-through surfaces, the
//! furthest first, a sprite, a label or an emitter at a time: a glass pane
//! in front of a sign is drawn over it, and one behind it under it. An
//! emitter's particles are drawn the furthest first among themselves where
//! they are mixed by alpha.
//!
//! A label's letters are laid out as a `Text2D`'s are, in the same fonts'
//! atlases: see `sprite.zig`'s `wordsOf`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const App = @import("../App.zig");
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const fog_volumes = @import("fog_volumes.zig");
const particles3d = @import("particles3d.zig");
const shader3d = @import("shader3d.zig");
const sprite = @import("sprite.zig");
const Text2D = @import("render_components.zig").Text2D;
const ViewTexture = @import("render_components.zig").ViewTexture;
const View3D = @import("view3d.zig").View3D;
const worlds3d = @import("worlds3d.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Sprite3D = components3d.Sprite3D;
const Label3D = components3d.Label3D;
const Billboard = components3d.Billboard;
const Particles3D = particles3d.Particles3D;

const log = std.log.scoped(.fluxion_engine);

/// One corner of a quad.
pub const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
    /// Linear, as light adds up.
    color: [4]f32,
    /// The alpha under which nothing is drawn, and how the fog is taken:
    /// nought into its colour, one toward nothing for what adds or takes
    /// away light, two toward white for what multiplies.
    knobs: [2]f32,
};

/// How a batch is drawn: how it goes onto what is behind it, how it is
/// tested against depth, and whether its back is culled.
pub const Way = struct {
    blend: Sprite3D.Blend = .alpha,
    depth: Depth = .tested,
    cull: bool = false,

    /// One number for each way.
    fn key(self: Way) u32 {
        return @as(u32, @intFromEnum(self.blend)) | @as(u32, @intFromEnum(self.depth)) << 2 | @as(u32, @intFromBool(self.cull)) << 4;
    }

    pub const Depth = enum(u2) {
        /// Tested and written: what is cut by its alpha.
        written,
        /// Tested, not written: what is see-through.
        tested,
        /// Neither: drawn over everything.
        none,
    };
};

/// One draw: quads of one picture, drawn one way.
const Batch = struct {
    first: u32,
    count: u32,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    way: Way,
    /// How far in front of the camera its middle is.
    depth: f32,
    /// Its place among the frame's batches, which keeps a label's shadows,
    /// outline and letters in the order they were laid.
    sequence: u32,

    fn solid(self: Batch) bool {
        return self.way.depth == .written;
    }

    /// The solid ones first, then the furthest; in the order they were made
    /// where those are the same.
    fn before(_: void, a: Batch, b: Batch) bool {
        if (a.solid() != b.solid()) return a.solid();
        if (!a.solid() and a.depth != b.depth) return a.depth > b.depth;
        return a.sequence < b.sequence;
    }
};

const source = vertex_part ++ fog_volumes.shader_part ++ fragment_part;

const vertex_part =
    \\attribute vec3 POSITION : 0;
    \\attribute vec2 TEXCOORD : 1;
    \\attribute vec4 TINT : 2;
    \\attribute vec2 KNOB : 3;
    \\
    \\varying vec3 WORLD_POSITION;
    \\varying vec2 UV;
    \\varying vec4 COLOR;
    \\varying vec2 KNOBS;
    \\
    \\uniform Frame : 0 {
    \\    mat4 VIEW_PROJECTION;
    \\    vec4 CAMERA_POSITION;
    \\    vec4 CAMERA_FORWARD;
    \\    vec4 SUN_DIRECTIONS[4];
    \\    vec4 SUN_COLORS[4];
    \\    vec4 AMBIENT;
    \\    vec4 FOG_COLOR;
    \\    vec4 FOG_HEIGHT;
    \\    vec4 SCREEN;
    \\    float TIME;
    \\}
    \\
    \\texture2d PICTURE : 0;
    \\
    \\vec3 toLinear(vec3 c) {
    \\    vec3 x = max(c, vec3(0.0));
    \\    return mix(x / 12.92, pow((x + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), x));
    \\}
    \\
;

const fragment_part =
    \\vertex {
    \\    WORLD_POSITION = POSITION;
    \\    UV = TEXCOORD;
    \\    COLOR = TINT;
    \\    KNOBS = KNOB;
    \\    position = VIEW_PROJECTION * vec4(POSITION, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(PICTURE, UV);
    \\    vec4 c = vec4(toLinear(texel.rgb), texel.a) * COLOR;
    \\    if (c.a < KNOBS.x) {
    \\        discard;
    \\    }
    \\    vec3 eye = CAMERA_POSITION.xyz;
    \\    if (CAMERA_FORWARD.w > 0.5) {
    \\        eye = WORLD_POSITION - CAMERA_FORWARD.xyz * dot(WORLD_POSITION - CAMERA_POSITION.xyz, CAMERA_FORWARD.xyz);
    \\    }
    \\    float far = length(WORLD_POSITION - eye);
    \\    float thick = FOG_COLOR.w + max(FOG_HEIGHT.x - WORLD_POSITION.y, 0.0) * FOG_HEIGHT.y;
    \\    float fog = clamp((1.0 - exp(-thick * far)) * FOG_HEIGHT.z, 0.0, 1.0);
    \\    vec4 result = vec4(fogVolumes(mix(c.rgb, FOG_COLOR.rgb, fog), WORLD_POSITION), c.a);
    \\    if (KNOBS.y > 1.5) {
    \\        result = vec4(mix(vec3(1.0), c.rgb, c.a * (1.0 - fog)), 1.0);
    \\    } else if (KNOBS.y > 0.5) {
    \\        result = vec4(c.rgb * (1.0 - fog), c.a);
    \\    }
    \\    target = result;
    \\}
;

pub const Billboards = struct {
    gpa: Allocator,
    device: *rhi.Device,
    module: ?shader.Module = null,
    gpu: rhi.Shader = .none,
    /// By `Way` and samples: made the first time it is drawn so.
    pipelines: std.AutoHashMapUnmanaged(u32, rhi.Pipeline) = .empty,
    refused: bool = false,
    buffer: rhi.Buffer = .none,
    /// How many vertices the buffer has room for.
    capacity: u32 = 0,

    vertices: std.ArrayList(Vertex) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    /// Where the see-through ones the pass has not drawn yet start.
    next: usize = 0,
    solid_drawn: bool = false,
    /// The fonts whose atlases this frame's labels emptied.
    emptied: std.ArrayList(*Assets.Font) = .empty,
    said_full: bool = false,
    /// An emitter's particles, the furthest first.
    order: std.ArrayList(Far) = .empty,

    /// What the last draw drew: quads, and the draws they took.
    quads: u32 = 0,
    draw_calls: u32 = 0,

    const Far = struct {
        depth: f32,
        index: u32,

        fn further(_: void, a: Far, b: Far) bool {
            return a.depth > b.depth;
        }
    };

    pub fn init(gpa: Allocator, device: *rhi.Device) !Billboards {
        var self: Billboards = .{ .gpa = gpa, .device = device };
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        self.module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("the 3D billboards' shader: {s}", .{said.written()});
            return err;
        };
        errdefer self.module.?.deinit();
        const module = &self.module.?;
        const frame = module.block("Frame").?;
        inline for (.{ .{ "VIEW_PROJECTION", "view_projection" }, .{ "CAMERA_POSITION", "camera_position" }, .{ "CAMERA_FORWARD", "camera_forward" }, .{ "FOG_COLOR", "fog_color" }, .{ "FOG_HEIGHT", "fog_height" }, .{ "TIME", "time" } }) |pair| {
            std.debug.assert(frame.offsetOf(pair[0]).? == @offsetOf(shader3d.Frame, pair[1]));
        }
        self.gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "3D billboards",
        });
        return self;
    }

    pub fn deinit(self: *Billboards, gpa: Allocator) void {
        var it = self.pipelines.valueIterator();
        while (it.next()) |pipeline| self.device.destroyPipeline(pipeline.*);
        self.pipelines.deinit(gpa);
        if (!self.buffer.isNone()) self.device.destroyBuffer(self.buffer);
        if (!self.gpu.isNone()) self.device.destroyShader(self.gpu);
        if (self.module) |*held| held.deinit();
        self.vertices.deinit(gpa);
        self.batches.deinit(gpa);
        self.emptied.deinit(gpa);
        self.order.deinit(gpa);
        self.* = undefined;
    }

    /// Every sprite, label and particle `view` sees in the world `worlds`
    /// sees, as quads, sorted and put in the vertex buffer.
    pub fn gather(self: *Billboards, app: *App, view: View3D, frustum: math.Frustum, worlds: worlds3d.Filter) !void {
        const gpa = app.gpa;
        self.vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.next = 0;
        self.solid_drawn = false;
        self.quads = 0;
        self.draw_calls = 0;
        try self.gatherSprites(app, view, frustum, worlds);
        try self.gatherParticles(app, view, frustum, worlds);
        // A label that fills a font's atlas has room made, and the labels
        // are laid out again; with no more room, they are left out.
        self.emptied.clearRetainingCapacity();
        const vertices_from = self.vertices.items.len;
        const batches_from = self.batches.items.len;
        while (true) {
            self.gatherLabels(app, view, frustum, worlds) catch |err| switch (err) {
                error.AtlasFull => {
                    self.vertices.shrinkRetainingCapacity(vertices_from);
                    self.batches.shrinkRetainingCapacity(batches_from);
                    if (try app.sprites.makeRoom(gpa, &app.assets, &self.emptied)) continue;
                    if (!self.said_full) log.warn("the 3D labels of a frame do not fit a font's atlas: they are left out", .{});
                    self.said_full = true;
                    break;
                },
                else => return err,
            };
            break;
        }
        std.mem.sort(Batch, self.batches.items, {}, Batch.before);
        self.quads = @intCast(self.vertices.items.len / 6);
        try self.upload();
        // The see-through ones start after the solid ones.
        while (self.next < self.batches.items.len and self.batches.items[self.next].solid()) self.next += 1;
    }

    fn upload(self: *Billboards) !void {
        const count: u32 = @intCast(self.vertices.items.len);
        if (count == 0) return;
        if (count > self.capacity) {
            const capacity = @max(count, self.capacity * 2, 1024);
            const grown = try self.device.createBuffer(.{ .kind = .vertex, .size = capacity * @sizeOf(Vertex), .dynamic = true, .label = "3D billboards" });
            if (!self.buffer.isNone()) self.device.destroyBuffer(self.buffer);
            self.buffer = grown;
            self.capacity = capacity;
        }
        try self.device.updateBuffer(self.buffer, 0, std.mem.sliceAsBytes(self.vertices.items));
    }

    /// What the pass binds for every batch: the frame's numbers and the fog
    /// volumes', and where the pass draws into.
    pub const Pass = struct {
        list: *rhi.CommandList,
        frame: rhi.Buffer,
        fog: rhi.Buffer,
        color_format: rhi.Format,
        depth_format: rhi.Format,
        samples: u32,
    };

    /// The batches cut by their alpha, drawn as the solid surfaces are: once,
    /// after them.
    pub fn drawSolid(self: *Billboards, pass: Pass) !void {
        if (self.solid_drawn) return;
        self.solid_drawn = true;
        for (self.batches.items) |batch| {
            if (!batch.solid()) break;
            try self.drawBatch(pass, batch);
        }
    }

    /// The see-through batches further than `depth` not drawn yet: before a
    /// see-through surface that far away.
    pub fn drawFurtherThan(self: *Billboards, pass: Pass, depth: f32) !void {
        try self.drawSolid(pass);
        while (self.next < self.batches.items.len) : (self.next += 1) {
            const batch = self.batches.items[self.next];
            if (batch.depth <= depth) return;
            try self.drawBatch(pass, batch);
        }
    }

    /// Whatever is left, at the end of the pass.
    pub fn drawRest(self: *Billboards, pass: Pass) !void {
        try self.drawFurtherThan(pass, -std.math.inf(f32));
    }

    fn drawBatch(self: *Billboards, pass: Pass, batch: Batch) !void {
        const pipeline = self.pipelineOf(batch.way, pass) catch return;
        const list = pass.list;
        try list.setPipeline(pipeline);
        try list.setUniformBuffer(0, pass.frame);
        try list.setUniformBuffer(fog_volumes.slot, pass.fog);
        try list.setTexture(0, batch.texture, batch.sampler);
        try list.setVertexBuffer(0, self.buffer, 0);
        try list.draw(.{ .vertex_count = batch.count, .first_vertex = batch.first });
        self.draw_calls += 1;
    }

    fn pipelineOf(self: *Billboards, way: Way, pass: Pass) !rhi.Pipeline {
        const key = way.key() | @as(u32, std.math.log2_int(u32, pass.samples)) << 8;
        if (self.pipelines.get(key)) |held| return held;
        if (self.refused) return error.Refused;
        const module = &self.module.?;
        const stride: u32 = @sizeOf(Vertex);
        const pipeline = self.device.createPipeline(.{
            .shader = self.gpu,
            .attributes = &.{
                .{ .location = 0, .format = .float3, .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .format = .float2, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .format = .float4, .offset = @offsetOf(Vertex, "color") },
                .{ .location = 3, .format = .float2, .offset = @offsetOf(Vertex, "knobs") },
            },
            .buffers = &.{.{ .stride = stride }},
            .topology = .triangles,
            .blend = blendOf(way.blend),
            .depth = switch (way.depth) {
                .written => .{ .test_enabled = true, .write = true, .compare = .less },
                .tested => .{ .test_enabled = true, .write = false, .compare = .less },
                .none => .{},
            },
            .cull = if (way.cull) .back else .none,
            .front_face = .ccw,
            .color_format = pass.color_format,
            .depth_format = pass.depth_format,
            .samples = pass.samples,
            .uniform_blocks = try blockNames(module),
            .textures = (try module.textureNames()).?,
            .label = "3D billboards",
        }) catch |err| {
            self.refused = true;
            log.err("the graphics driver refused the 3D billboards' pipeline: {s}", .{self.device.diagnostics()});
            return err;
        };
        try self.pipelines.put(self.gpa, key, pipeline);
        return pipeline;
    }

    // ---------------------------------------------------------------------
    // Sprites

    fn gatherSprites(self: *Billboards, app: *App, view: View3D, frustum: math.Frustum, worlds: worlds3d.Filter) !void {
        var it = try ecs.Query(.{ Transform3D, Sprite3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(Transform3D), chunk.slice(Sprite3D), chunk.entities) |local, held, entity| {
                if (held.layers & view.cull_mask == 0) continue;
                if (!worlds.admits(app, entity)) continue;
                const looks = app.inherited.of(app.gpa, &app.world, entity);
                if (!looks.visible) continue;
                // A render view's picture is not read while it is drawn into.
                if (app.world.get(entity, ViewTexture)) |shown| if (!view.render_view.isNone() and shown.view.eql(view.render_view)) continue;
                const handle = app.views.shown(&app.world, entity, held.texture);
                if (handle.isNone()) continue;
                const picture = app.assets.get(handle) orelse continue;
                const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, app.time.alpha()) orelse continue;

                const shape = spriteShape(held, picture.*) orelse continue;
                const uv = shape.uv;
                const quad = cornersOf(view, placed, held.billboard, shape.box) orelse continue;
                const middle = quad.middle();
                if (frustum.testSphere(.init(middle, quad.reach())) == .outside) continue;
                var tint = linear(held.tint);
                const shade = linear(looks.tint(.white));
                for (&tint, shade) |*channel, by| channel.* *= by;
                const cut = held.blend == .alpha and held.alpha_cut > 0;
                const way: Way = .{
                    .blend = held.blend,
                    .depth = if (held.no_depth_test) .none else if (cut) .written else .tested,
                    .cull = !held.double_sided and held.billboard == .disabled,
                };
                const first: u32 = @intCast(self.vertices.items.len);
                try self.addQuad(app.gpa, quad, uv, tint, .{ if (cut) held.alpha_cut else 0, fogKnob(held.blend) });
                try self.batches.append(app.gpa, .{
                    .first = first,
                    .count = 6,
                    .texture = picture.gpu,
                    .sampler = app.assets.mipSamplerFor(picture.filter, .clamp_to_edge),
                    .way = way,
                    .depth = depthOf(view, middle),
                    .sequence = @intCast(self.batches.items.len),
                });
            }
        }
    }

    // ---------------------------------------------------------------------
    // Labels

    fn gatherLabels(self: *Billboards, app: *App, view: View3D, frustum: math.Frustum, worlds: worlds3d.Filter) !void {
        const gpa = app.gpa;
        var it = try ecs.Query(.{ Transform3D, Label3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(Transform3D), chunk.slice(Label3D), chunk.entities) |local, held, entity| {
                if (held.layers & view.cull_mask == 0) continue;
                if (!worlds.admits(app, entity)) continue;
                const run = app.textOf(entity, Label3D, "text");
                if (run.len == 0) continue;
                const looks = app.inherited.of(gpa, &app.world, entity);
                if (!looks.visible) continue;
                const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, app.time.alpha()) orelse continue;
                const label = textOf(held);
                // Kept apart from a `Text2D`'s layout of the same entity.
                const key = entity.toInt() ^ (@as(u64, 1) << 63);
                const words = (try app.sprites.wordsOf(gpa, &app.assets, label, run, key)) orelse continue;
                const size = held.pixel_size;
                const box = boxOf(words.width * size, words.height * size, held.pivot_x, held.pivot_y);
                const whole = cornersOf(view, placed, held.billboard, box) orelse continue;
                const middle = whole.middle();
                if (frustum.testSphere(.init(middle, whole.reach())) == .outside) continue;
                const depth = depthOf(view, middle);
                const way: Way = .{
                    .blend = .alpha,
                    .depth = if (held.no_depth_test) .none else .tested,
                    .cull = !held.double_sided and held.billboard == .disabled,
                };
                const shade = linear(looks.tint(.white));
                const sampler = app.assets.samplerFor(.linear, .clamp_to_edge);
                var batch: ?Batch = null;
                for (words.glyphs) |glyph| {
                    var own = switch (glyph.kind) {
                        .shadow => glyph.color.?,
                        .outline => label.outline_color,
                        .letter => glyph.color orelse label.color,
                    };
                    if (glyph.colored) own = .rgba(1, 1, 1, own.a);
                    var tint = linear(own);
                    for (tint[0..3], shade[0..3]) |*channel, by| channel.* *= by;
                    tint[3] *= shade[3] * glyph.opacity;
                    if (!(tint[3] > 0)) continue;
                    // The glyph's box in the words' box, in metres: across
                    // from its left, up from its bottom.
                    const left = glyph.x / words.width;
                    const right = (glyph.x + glyph.width) / words.width;
                    const top = 1 - glyph.y / words.height;
                    const bottom = 1 - (glyph.y + glyph.height) / words.height;
                    const quad = whole.part(left, right, bottom, top);
                    const texture = words.faces.get(glyph.face).texture;
                    if (batch) |*open| if (open.texture.toInt() != texture.toInt()) {
                        try self.batches.append(gpa, open.*);
                        batch = null;
                    };
                    if (batch == null) batch = .{
                        .first = @intCast(self.vertices.items.len),
                        .count = 0,
                        .texture = texture,
                        .sampler = sampler,
                        .way = way,
                        .depth = depth,
                        .sequence = @intCast(self.batches.items.len),
                    };
                    try self.addQuad(gpa, quad, glyph.uv, tint, .{ 0, 0 });
                    batch.?.count += 6;
                }
                if (batch) |open| try self.batches.append(gpa, open);
            }
        }
    }

    /// The `Text2D` a label is laid out as.
    pub fn textOf(held: Label3D) Text2D {
        return .{
            .font = held.font,
            .size = held.size,
            .color = held.color,
            .alignment = switch (held.alignment) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
            .line_spacing = held.line_spacing,
            .wrap_width = held.wrap_width,
            .outline_size = held.outline_size,
            .outline_color = held.outline_color,
            .markup = held.markup,
        };
    }

    // ---------------------------------------------------------------------
    // Particles

    fn gatherParticles(self: *Billboards, app: *App, view: View3D, frustum: math.Frustum, worlds: worlds3d.Filter) !void {
        const gpa = app.gpa;
        var it = try ecs.Query(.{ Transform3D, Particles3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(Particles3D), chunk.entities) |*settings, entity| {
                if (settings.layers & view.cull_mask == 0) continue;
                if (!worlds.admits(app, entity)) continue;
                const emitter = app.particles3d.get(entity) orelse continue;
                if (emitter.particles.items.len == 0) continue;
                const looks = app.inherited.of(gpa, &app.world, entity);
                if (!looks.visible) continue;
                const own = if (settings.texture.isNone() or app.assets.get(settings.texture) == null) app.assets.glow else settings.texture;
                const picture = app.assets.get(own) orelse continue;
                const placed = particles3d.placeOf(app, entity);
                const turn = placed.rotation.quat();

                const across = @max(settings.frames_across, 1);
                const down = @max(settings.frames_down, 1);
                const frames: u32 = @as(u32, across) * down;
                const frame_w = @as(f32, @floatFromInt(picture.width)) / @as(f32, @floatFromInt(across));
                const frame_h = @as(f32, @floatFromInt(picture.height)) / @as(f32, @floatFromInt(down));
                const aspect = if (frame_w > 0) frame_h / frame_w else 1;

                // The furthest first, where they are mixed by alpha.
                self.order.clearRetainingCapacity();
                var bounds: math.Aabb = .empty;
                for (emitter.particles.items, 0..) |p, at| {
                    if (!p.alive) continue;
                    const where = if (settings.local_coords) placed.apply(p.position) else p.position;
                    bounds = bounds.expand(where);
                    try self.order.append(gpa, .{ .depth = depthOf(view, where), .index = @intCast(at) });
                }
                if (self.order.items.len == 0) continue;
                const reach = settings.size * @max(settings.scale_max, settings.scale_min, 1) * @max(1, aspect) + 1;
                const padded: math.Aabb = .{ .min = bounds.min.sub(.splat(reach)), .max = bounds.max.add(.splat(reach)) };
                if (frustum.testAabb(padded) == .outside) continue;
                if (settings.blend == .alpha) std.mem.sort(Far, self.order.items, {}, Far.further);

                const shade = linear(looks.tint(.white));
                const first: u32 = @intCast(self.vertices.items.len);
                for (self.order.items) |far| {
                    const p = emitter.particles.items[far.index];
                    const look = p.shown(settings, frames);
                    var tint = linear(look.color);
                    for (&tint, shade) |*channel, by| channel.* *= by;
                    if (!(tint[3] > 0)) continue;
                    const where = if (settings.local_coords) placed.apply(p.position) else p.position;
                    const going = if (settings.local_coords) turn.rotate(p.velocity) else p.velocity;
                    const width = settings.size * look.scale;
                    if (!(width > 0)) continue;
                    const quad = particleQuad(view, where, going, width, width * aspect, p.rotation, settings) orelse continue;
                    const column: f32 = @floatFromInt(look.frame % across);
                    const row: f32 = @floatFromInt(look.frame / across);
                    const fu = 1 / @as(f32, @floatFromInt(across));
                    const fv = 1 / @as(f32, @floatFromInt(down));
                    var uv: [4]f32 = .{ fu * column, fv * row, fu * (column + 1), fv * (row + 1) };
                    if (picture.upside_down) std.mem.swap(f32, &uv[1], &uv[3]);
                    try self.addQuad(gpa, quad, uv, tint, .{ 0, fogKnob(settings.blend) });
                }
                const count: u32 = @as(u32, @intCast(self.vertices.items.len)) - first;
                if (count == 0) continue;
                try self.batches.append(gpa, .{
                    .first = first,
                    .count = count,
                    .texture = picture.gpu,
                    .sampler = app.assets.mipSamplerFor(picture.filter, .clamp_to_edge),
                    .way = .{ .blend = settings.blend, .depth = if (settings.no_depth_test) .none else .tested },
                    .depth = depthOf(view, bounds.center()),
                    .sequence = @intCast(self.batches.items.len),
                });
            }
        }
    }

    // ---------------------------------------------------------------------

    /// Two triangles of `quad`, anticlockwise from its front: `uv` is its
    /// picture's left, top, right and bottom.
    fn addQuad(self: *Billboards, gpa: Allocator, quad: Quad, uv: [4]f32, color: [4]f32, knobs: [2]f32) !void {
        const corners = [4]struct { Vec3, [2]f32 }{
            .{ quad.bottom_left, .{ uv[0], uv[3] } },
            .{ quad.bottom_right, .{ uv[2], uv[3] } },
            .{ quad.top_right, .{ uv[2], uv[1] } },
            .{ quad.top_left, .{ uv[0], uv[1] } },
        };
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |at| {
            const corner = corners[at];
            try self.vertices.append(gpa, .{ .position = corner[0].array(), .uv = corner[1], .color = color, .knobs = knobs });
        }
    }
};

/// A quad's four corners in the world.
pub const Quad = struct {
    bottom_left: Vec3,
    bottom_right: Vec3,
    top_right: Vec3,
    top_left: Vec3,

    pub fn middle(self: Quad) Vec3 {
        return self.bottom_left.add(self.top_right).scale(0.5);
    }

    /// How far from its middle it reaches, at most.
    pub fn reach(self: Quad) f32 {
        return @max(self.bottom_left.sub(self.top_right).len(), self.bottom_right.sub(self.top_left).len()) * 0.5;
    }

    /// The part of it from `left` to `right` across and `bottom` to `top`
    /// up, each from nought to one.
    pub fn part(self: Quad, left: f32, right: f32, bottom: f32, top: f32) Quad {
        const across = self.bottom_right.sub(self.bottom_left);
        const up = self.top_left.sub(self.bottom_left);
        const at = struct {
            fn of(q: Quad, a: Vec3, u: Vec3, x: f32, y: f32) Vec3 {
                return q.bottom_left.add(a.scale(x)).add(u.scale(y));
            }
        }.of;
        return .{
            .bottom_left = at(self, across, up, left, bottom),
            .bottom_right = at(self, across, up, right, bottom),
            .top_right = at(self, across, up, right, top),
            .top_left = at(self, across, up, left, top),
        };
    }
};

/// A sprite's picture: where on its texture, and its box.
const SpriteShape = struct { uv: [4]f32, box: [4]f32 };

fn spriteShape(held: Sprite3D, picture: Assets.Texture) ?SpriteShape {
    const across: f32 = @floatFromInt(@max(held.frames_across, 1));
    const down: f32 = @floatFromInt(@max(held.frames_down, 1));
    const frames = @as(u32, @max(held.frames_across, 1)) * @max(held.frames_down, 1);
    const frame = held.frame % frames;
    const column: f32 = @floatFromInt(frame % @max(held.frames_across, 1));
    const row: f32 = @floatFromInt(frame / @max(held.frames_across, 1));
    const r = held.region;
    const fw = (r.u1 - r.u0) / across;
    const fh = (r.v1 - r.v0) / down;
    var uv: [4]f32 = .{ r.u0 + fw * column, r.v0 + fh * row, r.u0 + fw * (column + 1), r.v0 + fh * (row + 1) };
    if (held.flip_h) std.mem.swap(f32, &uv[0], &uv[2]);
    if (held.flip_v != picture.upside_down) std.mem.swap(f32, &uv[1], &uv[3]);
    const width = @abs(fw) * @as(f32, @floatFromInt(picture.width)) * held.pixel_size;
    const height = @abs(fh) * @as(f32, @floatFromInt(picture.height)) * held.pixel_size;
    if (!(width > 0 and height > 0)) return null;
    return .{ .uv = uv, .box = boxOf(width, height, held.pivot_x, held.pivot_y) };
}

/// Where a `Sprite3D`'s picture or a `Label3D`'s words are in the world as
/// they are drawn now, seen through `view`: what an editor outlines and
/// picks. Null for an entity with neither, or with nothing to show.
pub fn quadOf(app: *App, entity: Entity, view: View3D) ?Quad {
    const placed = app.drawnTransform3D(entity) orelse return null;
    if (app.world.get(entity, Sprite3D)) |held| {
        const handle = app.views.shown(&app.world, entity, held.texture);
        const picture = app.assets.get(handle) orelse return null;
        const shape = spriteShape(held.*, picture.*) orelse return null;
        return cornersOf(view, placed, held.billboard, shape.box);
    }
    if (app.world.get(entity, Label3D)) |held| {
        const run = app.textOf(entity, Label3D, "text");
        if (run.len == 0) return null;
        const key = entity.toInt() ^ (@as(u64, 1) << 63);
        const words = (app.sprites.wordsOf(app.gpa, &app.assets, Billboards.textOf(held.*), run, key) catch return null) orelse return null;
        const size = held.pixel_size;
        return cornersOf(view, placed, held.billboard, boxOf(words.width * size, words.height * size, held.pivot_x, held.pivot_y));
    }
    return null;
}

/// A box `width` by `height` round a pivot: its left, right, bottom and top
/// in its own plane, `y` up.
fn boxOf(width: f32, height: f32, pivot_x: f32, pivot_y: f32) [4]f32 {
    return .{ -pivot_x * width, (1 - pivot_x) * width, -(1 - pivot_y) * height, pivot_y * height };
}

/// Where a box round `placed` is in the world, turned as `billboard` says;
/// null where it cannot face the camera.
pub fn cornersOf(view: View3D, placed: Transform3D, billboard: Billboard, box: [4]f32) ?Quad {
    const left, const right, const bottom, const top = box;
    switch (billboard) {
        .disabled => {
            const m = placed.matrix();
            return .{
                .bottom_left = m.mulPoint(.init(left, bottom, 0)),
                .bottom_right = m.mulPoint(.init(right, bottom, 0)),
                .top_right = m.mulPoint(.init(right, top, 0)),
                .top_left = m.mulPoint(.init(left, top, 0)),
            };
        },
        .enabled, .y_only => {
            const axes = facing(view, placed.position, billboard) orelse return null;
            const across = axes[0].scale(@abs(placed.scale.x));
            const up = axes[1].scale(@abs(placed.scale.y));
            const o = placed.position;
            return .{
                .bottom_left = o.add(across.scale(left)).add(up.scale(bottom)),
                .bottom_right = o.add(across.scale(right)).add(up.scale(bottom)),
                .top_right = o.add(across.scale(right)).add(up.scale(top)),
                .top_left = o.add(across.scale(left)).add(up.scale(top)),
            };
        },
    }
}

/// The right and up of a picture at `at` facing the camera - wholly, or
/// turning only about the world's up.
fn facing(view: View3D, at: Vec3, billboard: Billboard) ?[2]Vec3 {
    if (billboard != .y_only) return .{ view.right(), view.up() };
    const toward = if (view.projection == .orthogonal) view.forward().scale(-1) else view.position.sub(at);
    const flat = Vec3.init(toward.x, 0, toward.z).tryNorm() orelse return null;
    return .{ Vec3.unit_y.cross(flat), Vec3.unit_y };
}

/// A particle's quad: facing the camera turned by `angle`, or lying along
/// the way it goes, stretched by its speed.
fn particleQuad(view: View3D, at: Vec3, velocity: Vec3, width: f32, height: f32, angle: f32, settings: *const Particles3D) ?Quad {
    if (settings.align_to_velocity) {
        const speed = velocity.len();
        const along = velocity.tryNorm() orelse view.up();
        const toward = if (view.projection == .orthogonal) view.forward().scale(-1) else view.position.sub(at);
        const side = along.cross(toward).tryNorm() orelse view.right();
        const half_long = (height + speed * @max(settings.stretch, 0)) * 0.5;
        const half_wide = width * 0.5;
        return .{
            .bottom_left = at.sub(side.scale(half_wide)).sub(along.scale(half_long)),
            .bottom_right = at.add(side.scale(half_wide)).sub(along.scale(half_long)),
            .top_right = at.add(side.scale(half_wide)).add(along.scale(half_long)),
            .top_left = at.sub(side.scale(half_wide)).add(along.scale(half_long)),
        };
    }
    const axes = facing(view, at, settings.billboard) orelse return null;
    const c = @cos(angle);
    const s = @sin(angle);
    const across = axes[0].scale(c).add(axes[1].scale(s)).scale(width * 0.5);
    const up = axes[1].scale(c).sub(axes[0].scale(s)).scale(height * 0.5);
    return .{
        .bottom_left = at.sub(across).sub(up),
        .bottom_right = at.add(across).sub(up),
        .top_right = at.add(across).add(up),
        .top_left = at.sub(across).add(up),
    };
}

fn depthOf(view: View3D, at: Vec3) f32 {
    return at.sub(view.position).dot(view.forward());
}

/// How the fog is taken: see `Vertex.knobs`.
fn fogKnob(blend: Sprite3D.Blend) f32 {
    return switch (blend) {
        .alpha => 0,
        .additive, .subtractive => 1,
        .multiply => 2,
    };
}

fn blendOf(blend: Sprite3D.Blend) rhi.BlendState {
    return switch (blend) {
        .alpha => .alpha,
        .additive => .additive,
        .subtractive => .{ .enabled = true, .src_rgb = .src_alpha, .dst_rgb = .one, .op_rgb = .reverse_subtract, .src_alpha = .zero, .dst_alpha = .one },
        .multiply => .{ .enabled = true, .src_rgb = .dst_color, .dst_rgb = .zero, .src_alpha = .zero, .dst_alpha = .one },
    };
}

/// Its blocks' names by slot, with none where it has none.
fn blockNames(module: *shader.Module) ![]const [:0]const u8 {
    const arena = module.arena.allocator();
    const names = try arena.alloc([:0]const u8, fog_volumes.slot + 1);
    @memset(names, "");
    for (module.blocks) |block| names[block.slot] = try arena.dupeZ(u8, block.name);
    return names;
}

fn linear(c: Color) [4]f32 {
    return .{ toLinear(c.r), toLinear(c.g), toLinear(c.b), c.a };
}

fn toLinear(v: f32) f32 {
    const x = @max(v, 0);
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

test "a picture facing the camera is turned to it, and one turning about its up stays upright" {
    var eye: Transform3D = .at(0, 5, 10);
    eye.lookAt(.zero, .unit_y);
    const view: View3D = .of(.{}, eye, 100, 100);
    const placed: Transform3D = .at(0, 0, 0);
    const box = boxOf(2, 1, 0.5, 1);
    const facing_quad = cornersOf(view, placed, .enabled, box).?;
    // Its plane is the camera's: across it is the camera's right.
    const across = facing_quad.bottom_right.sub(facing_quad.bottom_left);
    try testing.expectApproxEqAbs(@as(f32, 2), across.dot(view.right()), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), facing_quad.top_left.sub(facing_quad.bottom_left).dot(view.forward()), 1e-4);
    // Its pivot at its bottom: standing on its transform.
    try testing.expectApproxEqAbs(@as(f32, 0), facing_quad.bottom_left.sub(placed.position).dot(view.up()), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), facing_quad.top_left.sub(placed.position).dot(view.up()), 1e-4);

    const upright = cornersOf(view, placed, .y_only, box).?;
    try testing.expect(upright.top_left.sub(upright.bottom_left).approxEql(.unit_y));
    try testing.expectApproxEqAbs(@as(f32, 0), upright.bottom_right.sub(upright.bottom_left).y, 1e-5);

    // Turned as its entity is.
    var turned: Transform3D = .at(1, 0, 0);
    turned.rotation = .of(math.Quat.fromAxisAngle(.unit_y, std.math.pi / 2.0));
    const own = cornersOf(view, turned, .disabled, boxOf(2, 2, 0.5, 0.5)).?;
    try testing.expect(own.middle().approxEql(.init(1, 0, 0)));
    try testing.expectApproxEqAbs(@as(f32, 0), own.bottom_right.sub(own.bottom_left).x, 1e-5);

    // A part of it, as a letter is of its label.
    const half = own.part(0, 0.5, 0, 1);
    try testing.expect(half.bottom_right.approxEql(own.bottom_left.add(own.bottom_right).scale(0.5)));
}
