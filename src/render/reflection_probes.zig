// SPDX-License-Identifier: BSD-3-Clause

//! What smooth surfaces reflect: the world seen from a `ReflectionProbe3D`,
//! all round, and laid back onto every surface in its box.
//!
//! ```zig
//! _ = try app.world.spawnWith(.{
//!     fx.Transform3D.at(0, 1.5, 0),
//!     fx.ReflectionProbe3D{ .extents = .init(6, 3, 4) }, // a room
//! });
//! ```
//!
//! **Captured.** A probe draws the world six times, a cube's faces round its
//! middle - plus its `capture_offset` - into pictures of the light as it is
//! before the screen's effects: what a mirror there shows. They are folded
//! onto one square, an octahedron's unfolding (`octahedral` in the 3D
//! shader), and blurred into four rougher squares, each half the last,
//! for rougher surfaces: each a GGX lobe of its roughness, as a mirror of
//! that roughness spreads what it reflects - the split sum of Unreal's
//! "Real Shading" (Karis 2013), its second half Karis's fit for phones. The
//! five squares of every probe are in one atlas.
//!
//! **When.** `once` probes are captured once the world is there - streamed
//! in - and again when `App.captureReflectionProbes` asks: a room's light
//! that does not change. `realtime` ones over and over, a face a frame
//! between them: a window whose light changes with the time of day. What
//! the probes capture is drawn without their own reflections, so nothing
//! reflects itself.
//!
//! **Laid on.** Every surface finds the eight probes nearest the camera
//! whose boxes the camera can see, and takes each that holds it - the
//! highest `priority`, then the smallest box, first - fading toward its
//! box's sides over `blend_distance`, until it has a whole one; what is
//! missing is what the light from everywhere gave before. With
//! `box_projection` - the parallax correction of Lagarde and Zanuttini's
//! "Local Image-based Lighting with Parallax-corrected Cubemap" - the ray
//! a surface reflects is followed to the box's side and looked up from
//! where the probe saw it, so a room's reflections stand where its walls
//! are rather than at infinity.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const App = @import("../App.zig");
const components3d = @import("render3d_components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const material = @import("material.zig");
const shader3d = @import("shader3d.zig");
const lightmaps = @import("lightmaps.zig");
const view3d = @import("view3d.zig");
const skyboxes = @import("skyboxes.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const Color = @import("../math/color.zig").Color;

const ReflectionProbe3D = components3d.ReflectionProbe3D;
const View3D = view3d.View3D;
const Vec3 = math.Vec3;
const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

/// The block of uniforms the 3D shader reads them from, and the atlas's slot.
pub const slot = shader3d.reflections_slot;
pub const atlas_slot = shader3d.reflection_atlas_slot;
/// The most probes a frame's surfaces take reflections from.
pub const most_shown = 8;
/// A face, and the sharpest square, this many texels across.
pub const face_size = 128;
/// The squares of a probe: their roughness one of `levels - 1` apart, their
/// sides halved each, and where each is in its probe's block.
pub const levels = 5;
const level_places = [levels][3]u32{ .{ 0, 0, 128 }, .{ 128, 0, 64 }, .{ 128, 64, 32 }, .{ 160, 64, 16 }, .{ 176, 64, 8 } };
/// A probe's block: 192 by 128 texels.
const block_width = 192;
const block_height = 128;
const atlas_width = 2048;
const blocks_across = atlas_width / block_width;
/// The most probes kept at once.
pub const most_probes = 160;
/// GGX samples a texel of a rougher square takes from the one before.
const prefilter_samples = 32;

/// What the 3D shader's `Reflections` block holds: five `vec4`s a probe -
/// its box's low corner and how far in it fades, its high corner and its
/// strength, where it saw from and whether it bends reflections to its
/// box, and where its block is in the atlas.
pub const Block = extern struct {
    /// How many, and one over the atlas's width and height.
    info: [4]f32 = .{ 0, 0, 0, 0 },
    probes: [most_shown * 4][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

/// One probe's place in the atlas, and how far its capture is.
const Slot = struct {
    entity: Entity,
    /// Faces drawn of the capture under way: a bit each.
    faces: u8 = 0,
    /// Whether a whole capture is in the atlas.
    ready: bool = false,
    /// Captured again from the start: `App.captureReflectionProbes`.
    again: bool = false,
};

pub const Reflections = struct {
    gpa: Allocator,
    device: *rhi.Device,
    format: rhi.Format,
    atlas: ?rhi.Texture = null,
    atlas_rows: u32 = 0,
    faces: [6]?rhi.Texture = @splat(null),
    scratch: [levels]?rhi.Texture = @splat(null),
    slots: std.ArrayList(Slot) = .empty,
    block: rhi.Buffer = .none,
    passes: rhi.Buffer = .none,
    corners: rhi.Buffer = .none,
    sampler: rhi.Sampler = .none,
    shaders: ?Shaders = null,
    refused: bool = false,
    /// The probe a realtime capture is on, round the realtime ones.
    turn: usize = 0,
    /// What was drawn into the block last: the probes surfaces read now.
    shown: Block = .{},
    /// Whether a capture is being drawn: then no probe is read.
    capturing: bool = false,

    const Shaders = struct {
        fold: shader.Module,
        fold_gpu: rhi.Shader,
        fold_pipeline: rhi.Pipeline,
        blur: shader.Module,
        blur_gpu: rhi.Shader,
        blur_pipeline: rhi.Pipeline,
        copy: shader.Module,
        copy_gpu: rhi.Shader,
        copy_pipeline: rhi.Pipeline,
        /// The same, laid over what is there by its alpha: the world over
        /// its skybox.
        over_pipeline: rhi.Pipeline,
    };

    /// The numbers of a pass of the capture: see the shaders below.
    const Pass = extern struct {
        /// One over the target's side, the screen's flip, and the level.
        texel: [4]f32,
        /// The six faces' view and projection, turned only: four columns each.
        faces: [24][4]f32,
        /// GGX samples round the normal, in its own frame: `xyz` and a weight.
        samples: [prefilter_samples][4]f32,
    };

    pub fn init(gpa: Allocator, device: *rhi.Device) !Reflections {
        const caps = device.caps();
        const half = caps.formatSupport(.rgba16_float);
        const format: rhi.Format = if (half.render_target and half.sampled and half.filterable) .rgba16_float else .rgba8_unorm;
        var self: Reflections = .{ .gpa = gpa, .device = device, .format = format };
        self.block = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Block), .dynamic = true, .label = "reflection probes" });
        errdefer device.destroyBuffer(self.block);
        self.passes = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Pass), .dynamic = true, .label = "reflection probe pass" });
        errdefer device.destroyBuffer(self.passes);
        const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
        self.corners = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "reflection probe corners" });
        errdefer device.destroyBuffer(self.corners);
        self.sampler = try device.createSampler(.{ .min_filter = .linear, .mag_filter = .linear, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
        try device.updateBuffer(self.block, 0, std.mem.asBytes(&self.shown));
        return self;
    }

    pub fn deinit(self: *Reflections) void {
        const device = self.device;
        if (self.shaders) |*held| {
            device.destroyPipeline(held.over_pipeline);
            inline for (.{ "fold", "blur", "copy" }) |name| {
                device.destroyPipeline(@field(held, name ++ "_pipeline"));
                device.destroyShader(@field(held, name ++ "_gpu"));
                @field(held, name).deinit();
            }
        }
        for (self.faces) |held| if (held) |texture| device.destroyTexture(texture);
        for (self.scratch) |held| if (held) |texture| device.destroyTexture(texture);
        if (self.atlas) |texture| device.destroyTexture(texture);
        self.slots.deinit(self.gpa);
        device.destroySampler(self.sampler);
        device.destroyBuffer(self.corners);
        device.destroyBuffer(self.passes);
        device.destroyBuffer(self.block);
    }

    /// The atlas the 3D shader reads, or a stand-in while there is none.
    pub fn atlasOr(self: *const Reflections, stand_in: rhi.Texture) rhi.Texture {
        return self.atlas orelse stand_in;
    }

    /// Every probe captured again, from the start: `App.captureReflectionProbes`.
    pub fn captureAgain(self: *Reflections) void {
        for (self.slots.items) |*held| {
            held.again = true;
            held.faces = 0;
        }
    }

    // -------------------------------------------------------------------------
    // Capturing
    // -------------------------------------------------------------------------

    /// This frame's captures, before anything else is drawn: a probe not
    /// captured yet - once the world is in - six faces of it; then the
    /// realtime ones, a face each frame between them.
    pub fn capture(self: *Reflections, app: *App) !void {
        if (self.refused) return;
        try self.keepSlots(app);
        if (self.slots.items.len == 0) return;
        // A capture of a world still coming in would keep what is missing.
        if (!app.streamingReady()) return;
        var budget: u32 = 6;
        // First what has never been captured, or was asked for again: a
        // whole probe a frame.
        for (self.slots.items, 0..) |*held, at| {
            if (budget == 0) break;
            if (held.ready and !held.again) continue;
            while (budget > 0 and held.faces != 0b111111) : (budget -= 1) {
                const face: u3 = @intCast(@ctz(~held.faces));
                if (!try self.captureFace(app, at, face)) return;
            }
            if (held.faces == 0b111111) try self.finishCapture(app, at);
        }
        if (budget < 6) return;
        // Then a face of the next realtime probe.
        const count = self.slots.items.len;
        for (0..count) |step| {
            const at = (self.turn + step) % count;
            const held = &self.slots.items[at];
            const probe = app.world.get(held.entity, ReflectionProbe3D) orelse continue;
            if (probe.update != .realtime) continue;
            if (held.faces == 0b111111) held.faces = 0;
            const face: u3 = @intCast(@ctz(~held.faces));
            if (!try self.captureFace(app, at, face)) return;
            if (held.faces == 0b111111) {
                try self.finishCapture(app, at);
                self.turn = at + 1;
            }
            return;
        }
    }

    /// The slots kept in step with the probes there are: a new one given
    /// one, one gone let go of.
    fn keepSlots(self: *Reflections, app: *App) !void {
        var at: usize = 0;
        while (at < self.slots.items.len) {
            const held = self.slots.items[at].entity;
            if (app.world.isAlive(held) and app.world.has(held, ReflectionProbe3D)) at += 1 else _ = self.slots.orderedRemove(at);
        }
        var it = try ecs.Query(.{ Transform3D, ReflectionProbe3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.entities) |entity| {
                const known = for (self.slots.items) |held| {
                    if (held.entity == entity) break true;
                } else false;
                if (known) continue;
                if (self.slots.items.len >= most_probes) {
                    log.warn("more than {d} reflection probes: the rest reflect nothing", .{most_probes});
                    return;
                }
                try self.slots.append(self.gpa, .{ .entity = entity });
            }
        }
    }

    /// Which way each face looks, and its up: a cube's six, +x first.
    const face_ways = [6][2]Vec3{
        .{ .init(1, 0, 0), .init(0, -1, 0) },  .{ .init(-1, 0, 0), .init(0, -1, 0) },
        .{ .init(0, 1, 0), .init(0, 0, 1) },   .{ .init(0, -1, 0), .init(0, 0, -1) },
        .{ .init(0, 0, 1), .init(0, -1, 0) },  .{ .init(0, 0, -1), .init(0, -1, 0) },
    };

    /// The view of face `face` from `from`: a quarter turn across, square.
    fn faceView(probe: ReflectionProbe3D, from: Vec3, face: usize) View3D {
        var placed: Transform3D = .{ .position = from };
        placed.lookAt(from.add(face_ways[face][0]), face_ways[face][1]);
        return .{
            .position = from,
            .rotation = placed.rotation.quat().norm(),
            .fov = std.math.pi / 2.0,
            .near = probe.near,
            .far = probe.far,
            .width = face_size,
            .height = face_size,
            .cull_mask = probe.cull_mask,
        };
    }

    /// Face `face` of probe `at` drawn: false where nothing can be.
    fn captureFace(self: *Reflections, app: *App, at: usize, face: u3) !bool {
        const held = &self.slots.items[at];
        const probe = (app.world.get(held.entity, ReflectionProbe3D) orelse return false).*;
        const local = (app.world.get(held.entity, Transform3D) orelse return false).*;
        const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, held.entity, local, 1) orelse return false;
        const from = placed.position.add(probe.capture_offset);
        const target = try self.faceTexture(face);
        const view = faceView(probe, from, face);
        app.renderer3d.captured = null;
        self.capturing = true;
        defer self.capturing = false;
        const shaders = self.compiled() catch {
            self.refused = true;
            return false;
        };
        const device = self.device;
        var pass: Pass = .{ .texel = .{ 1.0 / @as(f32, face_size), material.screenFlip(device), 0, 0 }, .faces = @splat(.{ 0, 0, 0, 0 }), .samples = @splat(.{ 0, 0, 0, 0 }) };
        try device.updateBuffer(self.passes, 0, std.mem.asBytes(&pass));
        // The skybox's world first, with the sky - then the world over it,
        // where it drew anything. The light drawn is the renderer's own,
        // kept until its next draw of this size: copied out at once.
        var clear: ?Color = app.clear_color;
        if (skyboxes.viewFor(app, view)) |sky| {
            try app.renderer3d.draw(app, .{ .texture = target }, face_size, face_size, sky, clear, .{ .capture = true, .shadows = probe.shadows });
            try self.copyInto(target, shaders.copy_pipeline, app.renderer3d.captured orelse return false);
            clear = null;
        }
        app.renderer3d.captured = null;
        try app.renderer3d.draw(app, .{ .texture = target }, face_size, face_size, view, clear, .{ .capture = true, .shadows = probe.shadows });
        try self.copyInto(target, if (clear == null) shaders.over_pipeline else shaders.copy_pipeline, app.renderer3d.captured orelse return false);
        held.faces |= @as(u8, 1) << face;
        return true;
    }

    /// `light` drawn into the face `target` with `pipeline`: as it is, or
    /// over what is there.
    fn copyInto(self: *Reflections, target: rhi.Texture, pipeline: rhi.Pipeline, light: rhi.Texture) !void {
        const device = self.device;
        const list = device.begin();
        try list.beginPass(.{ .color = .{ .target = .{ .texture = target }, .load = .load } });
        try list.setViewport(.{ .width = face_size, .height = face_size });
        try list.setPipeline(pipeline);
        try list.setUniformBuffer(0, self.passes);
        try list.setTexture(0, light, self.sampler);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.draw(.{ .vertex_count = 4 });
        try list.endPass();
        try device.submit();
    }

    fn faceTexture(self: *Reflections, face: usize) !rhi.Texture {
        if (self.faces[face]) |held| return held;
        const made = try self.device.createTexture(.{
            .width = face_size,
            .height = face_size,
            .format = self.format,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "reflection probe face",
        });
        self.faces[face] = made;
        return made;
    }

    fn scratchTexture(self: *Reflections, level: usize) !rhi.Texture {
        if (self.scratch[level]) |held| return held;
        const side = level_places[level][2];
        const made = try self.device.createTexture(.{
            .width = side,
            .height = side,
            .format = self.format,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "reflection probe square",
        });
        self.scratch[level] = made;
        return made;
    }

    /// The atlas, with room for `rows` rows of blocks: made again, larger,
    /// when it has none - every probe in it captured again.
    fn atlasFor(self: *Reflections, rows: u32) !rhi.Texture {
        if (self.atlas) |held| if (self.atlas_rows >= rows) return held;
        if (self.atlas) |held| self.device.destroyTexture(held);
        const wanted = @max(rows, 2);
        self.atlas = try self.device.createTexture(.{
            .width = atlas_width,
            .height = wanted * block_height,
            .format = self.format,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "reflection probe atlas",
        });
        self.atlas_rows = wanted;
        for (self.slots.items) |*held| if (held.ready) {
            held.ready = false;
            held.faces = 0;
        };
        return self.atlas.?;
    }

    /// The six faces of probe `at` folded onto its sharpest square, blurred
    /// into the rougher ones, and all of them put in its block of the atlas.
    fn finishCapture(self: *Reflections, app: *App, at: usize) !void {
        _ = app;
        const shaders = self.compiled() catch {
            self.refused = true;
            return;
        };
        const atlas = try self.atlasFor(@intCast(@divFloor(self.slots.items.len + blocks_across - 1, blocks_across)));
        // The atlas made again lets every capture go.
        if (!self.slots.items[at].ready and self.slots.items[at].faces != 0b111111) return;
        const device = self.device;
        const flip = material.screenFlip(device);
        var pass: Pass = .{ .texel = .{ 0, flip, 0, 0 }, .faces = undefined, .samples = @splat(.{ 0, 0, 0, 0 }) };
        const clip = device.clip();
        for (0..6) |face| {
            var view = faceView(.{}, Vec3.zero, face);
            view.near = 0.05;
            view.far = 10;
            const columns = view.matrix(clip).array();
            for (0..4) |c| pass.faces[face * 4 + c] = columns[c * 4 ..][0..4].*;
        }
        // The faces folded onto the sharpest square.
        {
            pass.texel[0] = 1.0 / @as(f32, face_size);
            try device.updateBuffer(self.passes, 0, std.mem.asBytes(&pass));
            const list = device.begin();
            const into = try self.scratchTexture(0);
            try list.beginPass(.{ .color = .{ .target = .{ .texture = into }, .load = .dont_care } });
            try list.setViewport(.{ .width = face_size, .height = face_size });
            try list.setPipeline(shaders.fold_pipeline);
            try list.setUniformBuffer(0, self.passes);
            for (0..6) |face| try list.setTexture(@intCast(face), self.faces[face].?, self.sampler);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 4 });
            try list.endPass();
            try device.submit();
        }
        // Each rougher one blurred from the one before, by the lobe that
        // widens the one before's to its own.
        for (1..levels) |level| {
            const side = level_places[level][2];
            pass.texel = .{ 1.0 / @as(f32, @floatFromInt(side)), flip, @floatFromInt(level), 1.0 / @as(f32, @floatFromInt(level_places[level - 1][2])) };
            pass.samples = ggxSamples(roughnessStep(level));
            try device.updateBuffer(self.passes, 0, std.mem.asBytes(&pass));
            const list = device.begin();
            try list.beginPass(.{ .color = .{ .target = .{ .texture = try self.scratchTexture(level) }, .load = .dont_care } });
            try list.setViewport(.{ .width = @floatFromInt(side), .height = @floatFromInt(side) });
            try list.setPipeline(shaders.blur_pipeline);
            try list.setUniformBuffer(0, self.passes);
            try list.setTexture(0, self.scratch[level - 1].?, self.sampler);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 4 });
            try list.endPass();
            try device.submit();
        }
        // All of them into the probe's block.
        const origin = blockOrigin(at);
        for (0..levels) |level| {
            const place = level_places[level];
            const list = device.begin();
            try list.beginPass(.{ .color = .{ .target = .{ .texture = atlas }, .load = .load } });
            try list.setViewport(.{
                .x = @floatFromInt(origin[0] + place[0]),
                .y = @floatFromInt(origin[1] + place[1]),
                .width = @floatFromInt(place[2]),
                .height = @floatFromInt(place[2]),
            });
            try list.setPipeline(shaders.copy_pipeline);
            try list.setUniformBuffer(0, self.passes);
            try list.setTexture(0, self.scratch[level].?, self.sampler);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 4 });
            try list.endPass();
            try device.submit();
        }
        const held = &self.slots.items[at];
        held.ready = true;
        held.again = false;
        const all_ready = for (self.slots.items) |one| {
            if (!one.ready) break false;
        } else true;
        if (all_ready) log.info("{d} reflection probes captured", .{self.slots.items.len});
    }

    fn compiled(self: *Reflections) !*Shaders {
        if (self.shaders) |*held| return held;
        const device = self.device;
        var made: Shaders = undefined;
        inline for (.{ .{ "fold", fold_source }, .{ "blur", blur_source }, .{ "copy", copy_source } }) |pair| {
            var said: std.Io.Writer.Allocating = .init(self.gpa);
            defer said.deinit();
            var module = shader.compile(self.gpa, pair[1], &said.writer) catch |err| {
                log.err("reflection probe {s} shader: {s}", .{ pair[0], said.written() });
                return err;
            };
            errdefer module.deinit();
            const gpu = try device.createShader(.{
                .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
                .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
                .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
                .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
                .label = "reflection probe " ++ pair[0],
            });
            errdefer device.destroyShader(gpu);
            const pipeline = device.createPipeline(.{
                .shader = gpu,
                .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
                .buffers = &.{.{ .stride = @sizeOf([2]f32) }},
                .topology = .triangle_strip,
                .color_format = self.format,
                .uniform_blocks = (try module.uniformBlockNames()) orelse return error.ShaderFailed,
                .textures = (try module.textureNames()) orelse return error.ShaderFailed,
                .label = "reflection probe " ++ pair[0],
            }) catch |err| {
                log.err("the graphics driver refused the reflection probe {s} pipeline: {s}", .{ pair[0], device.diagnostics() });
                return err;
            };
            @field(made, pair[0]) = module;
            @field(made, pair[0] ++ "_gpu") = gpu;
            @field(made, pair[0] ++ "_pipeline") = pipeline;
        }
        made.over_pipeline = device.createPipeline(.{
            .shader = made.copy_gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = @sizeOf([2]f32) }},
            .topology = .triangle_strip,
            .color_format = self.format,
            .blend = .alpha,
            .uniform_blocks = (try made.copy.uniformBlockNames()) orelse return error.ShaderFailed,
            .textures = (try made.copy.textureNames()) orelse return error.ShaderFailed,
            .label = "reflection probe over",
        }) catch |err| {
            log.err("the graphics driver refused the reflection probe over pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        self.shaders = made;
        return &self.shaders.?;
    }

    // -------------------------------------------------------------------------
    // Laid on
    // -------------------------------------------------------------------------

    /// The probes this frame's surfaces read, for a view from `eye` that
    /// sees `frustum`: the nearest eight it sees whose capture is whole,
    /// the highest priority then the smallest first. None while capturing.
    /// With the world's lightmap `baked`, each with how bright the light
    /// from everywhere is where it saw from: a surface darker than that -
    /// in a corner, in the shade, indoors - reflects it as much darker, as
    /// Unreal's reflections normalized by the lightmap are.
    pub fn show(self: *Reflections, app: *App, eye: Vec3, frustum: math.Frustum, baked: ?*const lightmaps.Lightmap) !void {
        var block: Block = .{};
        if (!self.capturing and self.atlas != null) {
            const Candidate = struct { at: usize, far: f32, priority: i32, size: f32, lo: Vec3, hi: Vec3, from: Vec3, probe: ReflectionProbe3D };
            var found: [most_probes]Candidate = undefined;
            var count: usize = 0;
            for (self.slots.items, 0..) |held, at| {
                if (!held.ready) continue;
                const probe = (app.world.get(held.entity, ReflectionProbe3D) orelse continue).*;
                const local = (app.world.get(held.entity, Transform3D) orelse continue).*;
                const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, held.entity, local, 1) orelse continue;
                const half = probe.extents.mul(placed.scale.abs());
                const lo = placed.position.sub(half);
                const hi = placed.position.add(half);
                if (frustum.testAabb(.{ .min = lo, .max = hi }) == .outside) continue;
                const nearest = eye.max(lo).min(hi);
                found[count] = .{ .at = at, .far = nearest.sub(eye).len(), .priority = probe.priority, .size = half.x * half.y * half.z, .lo = lo, .hi = hi, .from = placed.position.add(probe.capture_offset), .probe = probe };
                count += 1;
            }
            const nearest_first = struct {
                fn less(_: void, a: Candidate, b: Candidate) bool {
                    return a.far < b.far;
                }
            }.less;
            std.mem.sort(Candidate, found[0..count], {}, nearest_first);
            const kept = found[0..@min(count, most_shown)];
            const strongest_first = struct {
                fn less(_: void, a: Candidate, b: Candidate) bool {
                    if (a.priority != b.priority) return a.priority > b.priority;
                    return a.size < b.size;
                }
            }.less;
            std.mem.sort(Candidate, kept, {}, strongest_first);
            const height: f32 = @floatFromInt(self.atlas_rows * block_height);
            block.info = .{ @floatFromInt(kept.len), 1.0 / @as(f32, atlas_width), 1.0 / height, 0 };
            for (kept, 0..) |one, i| {
                const origin = blockOrigin(one.at);
                block.probes[i * 4 + 0] = .{ one.lo.x, one.lo.y, one.lo.z, @max(one.probe.blend_distance, 0.001) };
                block.probes[i * 4 + 1] = .{ one.hi.x, one.hi.y, one.hi.z, @max(one.probe.intensity, 0) };
                block.probes[i * 4 + 2] = .{ one.from.x, one.from.y, one.from.z, if (one.probe.box_projection) 1 else 0 };
                var there: f32 = 0;
                if (baked) |held| if (held.probeLight(one.from.array())) |light| {
                    there = 0.2126 * light[0] + 0.7152 * light[4] + 0.0722 * light[8];
                };
                block.probes[i * 4 + 3] = .{ @floatFromInt(origin[0]), @floatFromInt(origin[1]), there, 0 };
            }
        }
        if (std.mem.eql(u8, std.mem.asBytes(&block), std.mem.asBytes(&self.shown))) return;
        self.shown = block;
        try self.device.updateBuffer(self.block, 0, std.mem.asBytes(&block));
    }
};

/// Where probe `at`'s block is in the atlas, in texels.
fn blockOrigin(at: usize) [2]u32 {
    return .{ @intCast((at % blocks_across) * block_width), @intCast((at / blocks_across) * block_height) };
}

/// The roughness of each square: nought, then a quarter more each.
pub fn roughnessOf(level: usize) f32 {
    return @as(f32, @floatFromInt(level)) / @as(f32, levels - 1);
}

/// The roughness a square's blur adds to the square before it: GGX lobes
/// widen about as their widths' squares add.
fn roughnessStep(level: usize) f32 {
    const now = roughnessOf(level);
    const before = roughnessOf(level - 1);
    return @sqrt(@max(now * now - before * before, 0.0001));
}

/// `prefilter_samples` half-vectors round the normal - `z` - for a GGX lobe
/// of `roughness`, as Hammersley's points spread them, each with its weight.
fn ggxSamples(roughness: f32) [prefilter_samples][4]f32 {
    var out: [prefilter_samples][4]f32 = undefined;
    const a = roughness * roughness;
    for (&out, 0..) |*sample, i| {
        const u = (@as(f32, @floatFromInt(i)) + 0.5) / prefilter_samples;
        const v = radicalInverse(@intCast(i));
        const phi = 2 * std.math.pi * v;
        const cos_theta = @sqrt((1 - u) / (1 + (a * a - 1) * u));
        const sin_theta = @sqrt(1 - cos_theta * cos_theta);
        sample.* = .{ sin_theta * @cos(phi), sin_theta * @sin(phi), cos_theta, 1 };
    }
    return out;
}

fn radicalInverse(i: u32) f32 {
    return @as(f32, @floatFromInt(@bitReverse(i))) / 4294967296.0;
}

const vertex_part =
    \\attribute vec2 CORNER : 0;
    \\varying vec2 UV;
    \\uniform Pass : 0 {
    \\    vec4 TEXEL;
    \\    vec4 FACES[24];
    \\    vec4 SAMPLES[32];
    \\}
    \\vertex {
    \\    UV = vec2(CORNER.x * 0.5 + 0.5, CORNER.y * 0.5 * TEXEL.y + 0.5);
    \\    position = vec4(CORNER, 0.0, 1.0);
    \\}
    \\
    \\// A square's texel's way, from its place in the square: the
    \\// octahedron's unfolding, its edge texels on its edges.
    \\vec3 wayOf(vec2 uv, float side) {
    \\    vec2 e = clamp((uv * side - vec2(0.5)) / (side - 1.0), vec2(0.0), vec2(1.0)) * 2.0 - vec2(1.0);
    \\    vec3 v = vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    \\    if (v.z < 0.0) {
    \\        v = vec3((1.0 - abs(e.y)) * (e.x >= 0.0 ? 1.0 : -1.0), (1.0 - abs(e.x)) * (e.y >= 0.0 ? 1.0 : -1.0), v.z);
    \\    }
    \\    return normalize(v);
    \\}
    \\
    \\// Where in a square of `side` the way `n` is.
    \\vec2 placeOf(vec3 n, float side) {
    \\    vec2 p = n.xy / (abs(n.x) + abs(n.y) + abs(n.z));
    \\    if (n.z < 0.0) {
    \\        p = (vec2(1.0) - abs(vec2(p.y, p.x))) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
    \\    }
    \\    return (vec2(0.5) + (p * 0.5 + vec2(0.5)) * (side - 1.0)) / side;
    \\}
    \\
;

/// The faces folded onto a square: each texel's way looked up in the face
/// that sees it, through that face's own view and projection.
const fold_source = vertex_part ++
    \\texture2d FACE_0 : 0;
    \\texture2d FACE_1 : 1;
    \\texture2d FACE_2 : 2;
    \\texture2d FACE_3 : 3;
    \\texture2d FACE_4 : 4;
    \\texture2d FACE_5 : 5;
    \\
    \\vec2 onFace(int face, vec3 way) {
    \\    int c = face * 4;
    \\    vec4 projected = FACES[c] * way.x + FACES[c + 1] * way.y + FACES[c + 2] * way.z + FACES[c + 3];
    \\    vec2 ndc = projected.xy / projected.w;
    \\    return vec2(ndc.x * 0.5 + 0.5, ndc.y * 0.5 * TEXEL.y + 0.5);
    \\}
    \\
    \\fragment {
    \\    vec3 way = wayOf(UV, 1.0 / TEXEL.x);
    \\    vec3 a = abs(way);
    \\    vec3 seen = vec3(0.0);
    \\    if (a.x >= a.y && a.x >= a.z) {
    \\        seen = way.x > 0.0 ? sample_level(FACE_0, onFace(0, way), 0.0).rgb : sample_level(FACE_1, onFace(1, way), 0.0).rgb;
    \\    } else if (a.y >= a.z) {
    \\        seen = way.y > 0.0 ? sample_level(FACE_2, onFace(2, way), 0.0).rgb : sample_level(FACE_3, onFace(3, way), 0.0).rgb;
    \\    } else {
    \\        seen = way.z > 0.0 ? sample_level(FACE_4, onFace(4, way), 0.0).rgb : sample_level(FACE_5, onFace(5, way), 0.0).rgb;
    \\    }
    \\    target = vec4(seen, 1.0);
    \\}
;

/// A rougher square: each texel the square before seen through a GGX
/// lobe round its way - the eye taken to look along it, as the split sum
/// does - the samples weighted by how much they face it.
const blur_source = vertex_part ++
    \\texture2d BEFORE : 0;
    \\
    \\fragment {
    \\    vec3 n = wayOf(UV, 1.0 / TEXEL.x);
    \\    vec3 up = abs(n.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    \\    vec3 tx = normalize(cross(up, n));
    \\    vec3 ty = cross(n, tx);
    \\    vec3 sum = vec3(0.0);
    \\    float weight = 0.0;
    \\    float side = 1.0 / TEXEL.w;
    \\    for (int i = 0; i < 32; i = i + 1) {
    \\        vec3 h = SAMPLES[i].xyz;
    \\        vec3 half_way = tx * h.x + ty * h.y + n * h.z;
    \\        vec3 l = half_way * (2.0 * dot(n, half_way)) - n;
    \\        float nl = dot(n, l);
    \\        if (nl > 0.0) {
    \\            sum = sum + sample_level(BEFORE, placeOf(l, side), 0.0).rgb * nl;
    \\            weight = weight + nl;
    \\        }
    \\    }
    \\    target = vec4(sum / max(weight, 0.0001), 1.0);
    \\}
;

/// A square as it is, into its place in the atlas.
const copy_source = vertex_part ++
    \\texture2d SQUARE : 0;
    \\
    \\fragment {
    \\    target = sample_level(SQUARE, UV, 0.0);
    \\}
;

test "the capture's shaders compile" {
    inline for (.{ fold_source, blur_source, copy_source }) |source| {
        var said: std.Io.Writer.Allocating = .init(testing.allocator);
        defer said.deinit();
        var module = shader.compile(testing.allocator, source, &said.writer) catch |err| {
            std.debug.print("{s}\n", .{said.written()});
            return err;
        };
        module.deinit();
    }
}

test "a probe's squares fit its block, and the blocks the atlas" {
    for (level_places) |place| {
        try testing.expect(place[0] + place[2] <= block_width);
        try testing.expect(place[1] + place[2] <= block_height);
    }
    try testing.expectEqual(@as(u32, 128), level_places[0][2]);
    try testing.expect(blockOrigin(most_probes - 1)[0] + block_width <= atlas_width);
}

test "each rougher square's blur, added to the one before, makes its own roughness" {
    var width: f32 = 0;
    for (1..levels) |level| {
        const step = roughnessStep(level);
        width = @sqrt(width * width + step * step);
        try testing.expectApproxEqAbs(roughnessOf(level), width, 0.02);
    }
}

test "GGX samples lean further from the normal the rougher the lobe" {
    const sharp = ggxSamples(0.1);
    const rough = ggxSamples(0.9);
    var sharp_sum: f32 = 0;
    var rough_sum: f32 = 0;
    for (sharp, rough) |a, b| {
        sharp_sum += a[2];
        rough_sum += b[2];
        try testing.expectApproxEqAbs(@as(f32, 1), a[0] * a[0] + a[1] * a[1] + a[2] * a[2], 0.001);
    }
    try testing.expect(sharp_sum > rough_sum);
}
