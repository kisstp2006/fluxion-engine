// SPDX-License-Identifier: BSD-3-Clause

//! What the 3D layer is drawn into, and how it becomes a picture.
//!
//! The light a camera sees is worked out in a target of its own, as it adds
//! up - brighter than white where it is - in half floats where the device
//! draws into them: with several samples a pixel where the project asks for
//! them, averaged into one when the pass ends. Then, each a pass over the
//! whole of it:
//!
//! - **Glow**: what is brighter than the environment's threshold, taken
//!   out at half the size, made smaller and smaller, and added back up the
//!   way it came, each step spread a little: bloom. What the levels add up
//!   to is divided by how many there are, so the glow is as strong whatever
//!   the size of the picture.
//! - **Tone**: the light times the exposure, with the glow added, brought
//!   into what a screen shows - as it is, Reinhard, filmic or ACES - and
//!   written as a picture's colours are.
//! - **Smoothing**, where the project asks for it: an edge smoother over
//!   the toned picture.
//!
//! The passes are one list, their numbers one buffer each binds a part of.
//! The targets are kept by size, as depth is, and let go of once nothing
//! has drawn at a size for a few frames.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const material = @import("material.zig");
const Environment = @import("render3d_components.zig").Environment;
const UniformBlocks = @import("uniform_blocks.zig").UniformBlocks;

const log = std.log.scoped(.fluxion_engine);

/// The most times the glow is made smaller.
const most_glow_levels = 6;

/// What every pass is told: the size of a pixel of what it reads, which way
/// up a picture drawn into is read, and the pass's own numbers.
const Post = extern struct {
    /// One over the source's width and height; how a target drawn into is
    /// read, as `material.screenFlip` says; nought.
    texel: [4]f32,
    knobs: [4]f32,
};

/// The three corners of a triangle that covers the whole target.
const corners = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };

const vertex_part =
    \\attribute vec2 CORNER : 0;
    \\varying vec2 UV;
    \\uniform Post : 0 {
    \\    vec4 TEXEL;
    \\    vec4 KNOBS;
    \\}
    \\vertex {
    \\    UV = vec2(CORNER.x * 0.5 + 0.5, CORNER.y * 0.5 * TEXEL.z + 0.5);
    \\    position = vec4(CORNER, 0.0, 1.0);
    \\}
    \\
;

/// What is brighter than `KNOBS.x`, after the exposure in `KNOBS.y`: by
/// its brightest channel, so a deep red or orange glows as a white of the
/// same strength does, with a soft knee half the threshold wide so the glow
/// does not start at an edge. No pixel glows brighter than sixteen, so one
/// spark does not light the screen.
const bright_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec3 light = sample(SOURCE, UV).rgb;
    \\    vec3 seen = light * KNOBS.y;
    \\    float brightest = max(seen.r, max(seen.g, seen.b));
    \\    float knee = KNOBS.x * 0.5 + 0.0001;
    \\    float soft = clamp(brightest - KNOBS.x + knee, 0.0, 2.0 * knee);
    \\    soft = soft * soft / (4.0 * knee);
    \\    float kept = max(soft, brightest - KNOBS.x) / max(brightest, 0.0001);
    \\    vec3 glow = light * kept;
    \\    float peak = max(glow.r, max(glow.g, glow.b)) * KNOBS.y;
    \\    target = vec4(glow * (16.0 / max(peak, 16.0)), 1.0);
    \\}
;

/// Half the size: thirteen taps over the four by four pixels under each,
/// the middle ones counted most, which keeps a small bright thing from
/// flickering as it moves.
const down_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec2 t = TEXEL.xy;
    \\    vec3 a = sample(SOURCE, UV + t * vec2(-2.0, -2.0)).rgb;
    \\    vec3 b = sample(SOURCE, UV + t * vec2(0.0, -2.0)).rgb;
    \\    vec3 c = sample(SOURCE, UV + t * vec2(2.0, -2.0)).rgb;
    \\    vec3 d = sample(SOURCE, UV + t * vec2(-2.0, 0.0)).rgb;
    \\    vec3 e = sample(SOURCE, UV).rgb;
    \\    vec3 f = sample(SOURCE, UV + t * vec2(2.0, 0.0)).rgb;
    \\    vec3 g = sample(SOURCE, UV + t * vec2(-2.0, 2.0)).rgb;
    \\    vec3 h = sample(SOURCE, UV + t * vec2(0.0, 2.0)).rgb;
    \\    vec3 i = sample(SOURCE, UV + t * vec2(2.0, 2.0)).rgb;
    \\    vec3 j = sample(SOURCE, UV + t * vec2(-1.0, -1.0)).rgb;
    \\    vec3 k = sample(SOURCE, UV + t * vec2(1.0, -1.0)).rgb;
    \\    vec3 l = sample(SOURCE, UV + t * vec2(-1.0, 1.0)).rgb;
    \\    vec3 m = sample(SOURCE, UV + t * vec2(1.0, 1.0)).rgb;
    \\    vec3 sum = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    \\    target = vec4(sum, 1.0);
    \\}
;

/// Twice the size: a three by three tent, `KNOBS.x` pixels of the smaller
/// wide, times `KNOBS.y`, added to what is there.
const up_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec2 t = TEXEL.xy * KNOBS.x;
    \\    vec3 sum = sample(SOURCE, UV + t * vec2(-1.0, -1.0)).rgb + sample(SOURCE, UV + t * vec2(1.0, -1.0)).rgb
    \\        + sample(SOURCE, UV + t * vec2(-1.0, 1.0)).rgb + sample(SOURCE, UV + t).rgb
    \\        + 2.0 * (sample(SOURCE, UV + t * vec2(0.0, -1.0)).rgb + sample(SOURCE, UV + t * vec2(-1.0, 0.0)).rgb
    \\        + sample(SOURCE, UV + t * vec2(1.0, 0.0)).rgb + sample(SOURCE, UV + t * vec2(0.0, 1.0)).rgb)
    \\        + 4.0 * sample(SOURCE, UV).rgb;
    \\    target = vec4(sum * (KNOBS.y / 16.0), 1.0);
    \\}
;

/// The light, times the exposure in `KNOBS.x`, with `KNOBS.w` of the glow,
/// toned by the curve `KNOBS.z` names with the white in `KNOBS.y`, and
/// written as a picture's colours are.
const tone_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\texture2d GLOW : 1;
    \\
    \\// The film industry's curve, as Krzysztof Narkowicz fitted it.
    \\vec3 aces(vec3 x) {
    \\    return clamp((x * (2.51 * x + vec3(0.03))) / (x * (2.43 * x + vec3(0.59)) + vec3(0.14)), 0.0, 1.0);
    \\}
    \\
    \\// John Hable's filmic curve.
    \\vec3 hable(vec3 x) {
    \\    return ((x * (0.15 * x + vec3(0.05)) + vec3(0.004)) / (x * (0.15 * x + vec3(0.5)) + vec3(0.06))) - vec3(0.02 / 0.3);
    \\}
    \\
    \\vec3 toSrgb(vec3 light) {
    \\    vec3 x = clamp(light, vec3(0.0), vec3(1.0));
    \\    vec3 low = x * 12.92;
    \\    vec3 high = 1.055 * pow(x, vec3(1.0 / 2.4)) - vec3(0.055);
    \\    return mix(low, high, step(vec3(0.0031308), x));
    \\}
    \\
    \\fragment {
    \\    vec4 light = sample(SOURCE, UV);
    \\    vec3 seen = (light.rgb + sample(GLOW, UV).rgb * KNOBS.w) * KNOBS.x;
    \\    vec3 toned = seen;
    \\    if (KNOBS.z > 2.5) {
    \\        toned = aces(seen);
    \\    } else if (KNOBS.z > 1.5) {
    \\        toned = hable(seen * 2.0) / hable(vec3(11.2 * KNOBS.y));
    \\    } else if (KNOBS.z > 0.5) {
    \\        toned = seen * (vec3(1.0) + seen / vec3(KNOBS.y * KNOBS.y)) / (vec3(1.0) + seen);
    \\    }
    \\    target = vec4(toSrgb(toned), light.a);
    \\}
;

/// Edges smoothed: where the brightness changes across, the pixel is a mix
/// along the edge. Where it hardly changes, it is left as it is.
const smooth_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
    \\float brightness(vec3 c) {
    \\    return dot(c, vec3(0.299, 0.587, 0.114));
    \\}
    \\
    \\fragment {
    \\    vec2 px = TEXEL.xy;
    \\    vec4 middle = sample(SOURCE, UV);
    \\    float b_nw = brightness(sample(SOURCE, UV + vec2(-px.x, -px.y)).rgb);
    \\    float b_ne = brightness(sample(SOURCE, UV + vec2(px.x, -px.y)).rgb);
    \\    float b_sw = brightness(sample(SOURCE, UV + vec2(-px.x, px.y)).rgb);
    \\    float b_se = brightness(sample(SOURCE, UV + px).rgb);
    \\    float b_m = brightness(middle.rgb);
    \\    float least = min(b_m, min(min(b_nw, b_ne), min(b_sw, b_se)));
    \\    float most = max(b_m, max(max(b_nw, b_ne), max(b_sw, b_se)));
    \\    vec4 result = middle;
    \\    if (most - least >= max(0.0312, most * 0.125)) {
    \\        vec2 along = vec2(-((b_nw + b_ne) - (b_sw + b_se)), (b_nw + b_sw) - (b_ne + b_se));
    \\        float reduce = max((b_nw + b_ne + b_sw + b_se) * 0.03125, 1.0 / 128.0);
    \\        float scale = 1.0 / (min(abs(along.x), abs(along.y)) + reduce);
    \\        along = clamp(along * scale, vec2(-8.0), vec2(8.0)) * px;
    \\        vec3 near = 0.5 * (sample(SOURCE, UV + along * (1.0 / 3.0 - 0.5)).rgb + sample(SOURCE, UV + along * (2.0 / 3.0 - 0.5)).rgb);
    \\        vec3 wide = near * 0.5 + 0.25 * (sample(SOURCE, UV - along * 0.5).rgb + sample(SOURCE, UV + along * 0.5).rgb);
    \\        float b_wide = brightness(wide);
    \\        result = vec4((b_wide < least || b_wide > most) ? near : wide, middle.a);
    \\    }
    \\    target = result;
    \\}
;

/// One pass over the whole of a target, waiting for its numbers to be
/// written with the rest.
const Pass = struct {
    pipeline: rhi.Pipeline,
    into: rhi.RenderTarget,
    width: u32,
    height: u32,
    load: rhi.LoadOp,
    sources: [2]rhi.Texture,
    source_count: u8,
    knobs: Post,
    /// Where its numbers are in the buffer, once they are written.
    at: u32 = 0,
};

/// A pass's shader and the pipelines it is drawn with.
const Stage = struct {
    module: ?shader.Module = null,
    gpu: rhi.Shader = .none,
    pipeline: rhi.Pipeline = .none,
    /// The same, laid over what is there by its alpha.
    over: rhi.Pipeline = .none,

    fn deinit(self: *Stage, device: *rhi.Device) void {
        if (!self.over.isNone()) device.destroyPipeline(self.over);
        if (!self.pipeline.isNone()) device.destroyPipeline(self.pipeline);
        if (!self.gpu.isNone()) device.destroyShader(self.gpu);
        if (self.module) |*held| held.deinit();
        self.* = .{};
    }
};

/// What the 3D layer is drawn into at one size and one count of samples.
pub const Targets = struct {
    width: u32,
    height: u32,
    samples: u32,
    /// The light, one sample a pixel: what the passes read.
    light: rhi.Texture,
    /// Drawn into with several samples, and averaged into `light`; none
    /// with one.
    multisampled: ?rhi.Texture,
    /// The depth the meshes are tested against, as many samples as the
    /// colour.
    depth: rhi.Texture,
    /// The toned picture, before it is smoothed, where it is.
    toned: ?rhi.Texture = null,
    /// The glow, each half the one before; none until glow is asked for.
    glow: [most_glow_levels]?rhi.Texture = @splat(null),
    glow_levels: u32 = 0,
    /// The frame it was last drawn with.
    used: u64,

    fn deinit(self: *Targets, device: *rhi.Device) void {
        device.destroyTexture(self.light);
        if (self.multisampled) |held| device.destroyTexture(held);
        device.destroyTexture(self.depth);
        if (self.toned) |held| device.destroyTexture(held);
        for (self.glow) |held| if (held) |texture| device.destroyTexture(texture);
    }

    /// What the meshes are drawn into: the samples, or the light itself.
    pub fn drawnInto(self: Targets) rhi.Texture {
        return self.multisampled orelse self.light;
    }
};

/// How the light becomes a picture, from an `Environment` or what is there
/// without one.
pub const Look = struct {
    tonemap: Environment.Tonemap = .linear,
    exposure: f32 = 1,
    white: f32 = 1,
    glow: bool = false,
    glow_threshold: f32 = 1,
    glow_intensity: f32 = 0.8,
    glow_spread: f32 = 1,
    /// Smooth the edges of the toned picture.
    smooth: bool = false,

    pub fn of(environment: ?Environment, smooth: bool) Look {
        const held = environment orelse return .{ .smooth = smooth };
        return .{
            .tonemap = held.tonemap,
            .exposure = held.exposure,
            .white = @max(held.white, 0.01),
            .glow = held.glow and held.glow_intensity > 0,
            .glow_threshold = held.glow_threshold,
            .glow_intensity = held.glow_intensity,
            .glow_spread = std.math.clamp(held.glow_spread, 0, 1),
            .smooth = smooth,
        };
    }
};

pub const Post3D = struct {
    device: *rhi.Device,
    /// What the light is kept in: half floats where the device draws into,
    /// filters and blends them, and a picture's bytes where it does not.
    light_format: rhi.Format,
    depth_format: rhi.Format,
    corners: rhi.Buffer,
    /// A black picture: no glow.
    black: rhi.Texture,
    sampler: rhi.Sampler,
    bright: Stage = .{},
    down: Stage = .{},
    up: Stage = .{},
    tone: Stage = .{},
    smooth: Stage = .{},
    targets: std.ArrayList(Targets) = .empty,
    /// This draw's passes, recorded into one list once their numbers are
    /// written.
    passes: std.ArrayList(Pass) = .empty,
    /// Every pass's numbers, in one buffer a pass binds a part of.
    blocks: UniformBlocks = .{ .label = "3D post" },
    clock: u64 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device, depth_format: rhi.Format) !Post3D {
        const caps = device.caps();
        const half = caps.formatSupport(.rgba16_float);
        const light_format: rhi.Format = if (half.render_target and half.sampled and half.filterable and half.blendable) .rgba16_float else .rgba8_unorm;
        if (light_format != .rgba16_float) log.info("the {t} backend draws into no half floats here: 3D light brighter than white is cut off", .{device.info().backend});
        const buffer = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "3D post corners" });
        errdefer device.destroyBuffer(buffer);
        const black_texel = [4]u8{ 0, 0, 0, 255 };
        const black = try device.createTexture(.{ .width = 1, .height = 1, .data = &black_texel, .label = "no glow" });
        errdefer device.destroyTexture(black);
        var self: Post3D = .{
            .device = device,
            .light_format = light_format,
            .depth_format = depth_format,
            .corners = buffer,
            .black = black,
            .sampler = try device.createSampler(.{ .min_filter = .linear, .mag_filter = .linear, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge }),
        };
        errdefer self.deinit(gpa);
        try self.compile(gpa, &self.bright, bright_source, light_format, false, "3D glow, bright");
        try self.compile(gpa, &self.down, down_source, light_format, false, "3D glow, down");
        try self.compile(gpa, &self.up, up_source, light_format, true, "3D glow, up");
        try self.compile(gpa, &self.tone, tone_source, .rgba8_unorm, false, "3D tone");
        try self.compile(gpa, &self.smooth, smooth_source, .rgba8_unorm, false, "3D smoothing");
        return self;
    }

    pub fn deinit(self: *Post3D, gpa: Allocator) void {
        const device = self.device;
        for (self.targets.items) |*held| held.deinit(device);
        self.targets.deinit(gpa);
        self.blocks.deinit(gpa, device);
        self.passes.deinit(gpa);
        for ([_]*Stage{ &self.bright, &self.down, &self.up, &self.tone, &self.smooth }) |stage| stage.deinit(device);
        device.destroySampler(self.sampler);
        device.destroyTexture(self.black);
        device.destroyBuffer(self.corners);
    }

    /// A pass's shader, and its pipeline into `format`: adding what it
    /// draws to what is there with `adds`. The tone pass also gets one laid
    /// over what is there by its alpha.
    fn compile(self: *Post3D, gpa: Allocator, stage: *Stage, source: []const u8, format: rhi.Format, adds: bool, label: []const u8) !void {
        const device = self.device;
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        stage.module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("{s}: {s}", .{ label, said.written() });
            return err;
        };
        const module = &stage.module.?;
        std.debug.assert(module.block("Post").?.size == @sizeOf(Post));
        stage.gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = label,
        });
        var desc: rhi.PipelineDesc = .{
            .shader = stage.gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = @sizeOf([2]f32) }},
            .topology = .triangles,
            .blend = if (adds) .additive else .solid,
            .color_format = format,
            .uniform_blocks = (try module.uniformBlockNames()).?,
            .textures = (try module.textureNames()).?,
            .label = label,
        };
        stage.pipeline = try device.createPipeline(desc);
        if (stage == &self.tone or stage == &self.smooth) {
            desc.blend = .alpha;
            stage.over = try device.createPipeline(desc);
        }
    }

    /// The targets at a size and a count of samples, made the first time
    /// they are drawn at.
    pub fn targetsAt(self: *Post3D, gpa: Allocator, width: u32, height: u32, samples: u32) !*Targets {
        for (self.targets.items) |*held| {
            if (held.width == width and held.height == height and held.samples == samples) {
                held.used = self.clock;
                return held;
            }
        }
        const device = self.device;
        const light = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.light_format,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "3D light",
        });
        errdefer device.destroyTexture(light);
        const multisampled: ?rhi.Texture = if (samples > 1) try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.light_format,
            .samples = samples,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D light, multisampled",
        }) else null;
        errdefer if (multisampled) |held| device.destroyTexture(held);
        const depth = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.depth_format,
            .samples = samples,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D depth",
        });
        errdefer device.destroyTexture(depth);
        try self.targets.append(gpa, .{ .width = width, .height = height, .samples = samples, .light = light, .multisampled = multisampled, .depth = depth, .used = self.clock });
        return &self.targets.items[self.targets.items.len - 1];
    }

    /// The most samples a pixel the device draws the light and the depth
    /// with, up to `wanted`.
    pub fn samplesFor(self: *const Post3D, wanted: u32) u32 {
        const caps = self.device.caps();
        var count = wanted;
        while (count > 1) : (count /= 2) {
            if (caps.formatSupport(self.light_format).supportsSamples(count) and caps.formatSupport(self.depth_format).supportsSamples(count)) return count;
        }
        return 1;
    }

    /// One more frame: targets no draw has used for a few are let go.
    pub fn tick(self: *Post3D) void {
        self.clock += 1;
        var at: usize = 0;
        while (at < self.targets.items.len) {
            if (self.targets.items[at].used + 3 < self.clock) {
                self.targets.items[at].deinit(self.device);
                _ = self.targets.swapRemove(at);
            } else at += 1;
        }
    }

    /// Turn the light in `targets` into a picture in `into`, `out_width` by
    /// `out_height` - larger or smaller than the targets where the 3D world
    /// is drawn at a scale of its own: glow, tone and smoothing as `look`
    /// says. Over what `into` holds by the light's alpha with `over`, or in
    /// place of it.
    pub fn finish(self: *Post3D, gpa: Allocator, targets: *Targets, into: rhi.RenderTarget, out_width: u32, out_height: u32, look: Look, over: bool) !void {
        const device = self.device;
        self.passes.clearRetainingCapacity();
        const flip = material.screenFlip(device);
        const width = targets.width;
        const height = targets.height;

        const glow: Glow = if (look.glow) try self.glowOf(gpa, targets, look, flip) else .{ .texture = self.black, .weight = 1 };

        // Toned into the picture - or into a picture of its own first,
        // where it is smoothed after.
        const smoothing = look.smooth;
        if (smoothing and targets.toned == null) targets.toned = try device.createTexture(.{
            .width = width,
            .height = height,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "3D toned",
        });
        const tone_into: rhi.RenderTarget = if (smoothing) .{ .texture = targets.toned.? } else into;
        const tone_width = if (smoothing) width else out_width;
        const tone_height = if (smoothing) height else out_height;
        const curve: f32 = switch (look.tonemap) {
            .linear => 0,
            .reinhard => 1,
            .filmic => 2,
            .aces => 3,
        };
        try self.queue(gpa, if (over and !smoothing) self.tone.over else self.tone.pipeline, tone_into, tone_width, tone_height, if (over and !smoothing) .load else .dont_care, &.{ targets.light, glow.texture }, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
            .knobs = .{ look.exposure, look.white, curve, if (look.glow) look.glow_intensity / glow.weight else 0 },
        });
        if (smoothing) try self.queue(gpa, if (over) self.smooth.over else self.smooth.pipeline, into, out_width, out_height, if (over) .load else .dont_care, &.{targets.toned.?}, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
            .knobs = @splat(0),
        });
        try self.run(gpa);
    }

    /// The glow, and what its levels add up to: what it is divided by.
    const Glow = struct { texture: rhi.Texture, weight: f32 };

    /// The glow of what is bright in `targets`: taken out at half the size,
    /// made smaller level by level, and added back up the way it came. The
    /// half-size level, which holds all of it, and how many times over.
    fn glowOf(self: *Post3D, gpa: Allocator, targets: *Targets, look: Look, flip: f32) !Glow {
        const device = self.device;
        if (targets.glow_levels == 0) {
            var w = @max(targets.width / 2, 1);
            var h = @max(targets.height / 2, 1);
            var level: u32 = 0;
            errdefer {
                for (targets.glow[0..level]) |*texture| {
                    if (texture.*) |made| device.destroyTexture(made);
                    texture.* = null;
                }
            }
            while (level < most_glow_levels and (level == 0 or (w >= 4 and h >= 4))) : (level += 1) {
                targets.glow[level] = try device.createTexture(.{
                    .width = w,
                    .height = h,
                    .format = self.light_format,
                    .usage = .{ .sampled = true, .render_target = true },
                    .label = "3D glow",
                });
                w = @max(w / 2, 1);
                h = @max(h / 2, 1);
            }
            targets.glow_levels = level;
        }
        const levels = targets.glow_levels;
        const sizeOf = struct {
            fn at(t: *const Targets, level: u32) [2]u32 {
                return .{ @max(t.width >> @intCast(level + 1), 1), @max(t.height >> @intCast(level + 1), 1) };
            }
        }.at;

        // What is bright, at half the size.
        const first = sizeOf(targets, 0);
        try self.queue(gpa, self.bright.pipeline, .{ .texture = targets.glow[0].? }, first[0], first[1], .dont_care, &.{targets.light}, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(targets.width)), 1 / @as(f32, @floatFromInt(targets.height)), flip, 0 },
            .knobs = .{ look.glow_threshold, look.exposure, 0, 0 },
        });
        // Down: each level half the one before.
        var level: u32 = 1;
        while (level < levels) : (level += 1) {
            const from = sizeOf(targets, level - 1);
            const size = sizeOf(targets, level);
            try self.queue(gpa, self.down.pipeline, .{ .texture = targets.glow[level].? }, size[0], size[1], .dont_care, &.{targets.glow[level - 1].?}, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(from[0])), 1 / @as(f32, @floatFromInt(from[1])), flip, 0 },
                .knobs = @splat(0),
            });
        }
        // Up: each level added to the one above it, spread a little; the
        // further down, the less with a small spread. A level counts as many
        // times as the weights on its way up multiply to.
        var weights: [most_glow_levels]f32 = @splat(1);
        for (1..levels) |at| {
            const reach: f32 = @as(f32, @floatFromInt(at)) / @as(f32, @floatFromInt(@max(levels - 1, 1)));
            weights[at] = if (look.glow_spread >= reach) 1 else look.glow_spread / @max(reach, 0.0001);
        }
        var total: f32 = 1;
        var carried: f32 = 1;
        for (1..levels) |at| {
            carried *= weights[at];
            total += carried;
        }
        level = levels;
        while (level > 1) {
            level -= 1;
            const from = sizeOf(targets, level);
            const size = sizeOf(targets, level - 1);
            try self.queue(gpa, self.up.pipeline, .{ .texture = targets.glow[level - 1].? }, size[0], size[1], .load, &.{targets.glow[level].?}, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(from[0])), 1 / @as(f32, @floatFromInt(from[1])), flip, 0 },
                .knobs = .{ 1, weights[level], 0, 0 },
            });
        }
        return .{ .texture = targets.glow[0].?, .weight = total };
    }

    /// One pass over the whole of `into`, reading `sources`: kept for `run`.
    fn queue(self: *Post3D, gpa: Allocator, pipeline: rhi.Pipeline, into: rhi.RenderTarget, width: u32, height: u32, load: rhi.LoadOp, sources: []const rhi.Texture, knobs: Post) !void {
        var held: Pass = .{ .pipeline = pipeline, .into = into, .width = width, .height = height, .load = load, .sources = undefined, .source_count = @intCast(sources.len), .knobs = knobs };
        @memcpy(held.sources[0..sources.len], sources);
        try self.passes.append(gpa, held);
    }

    /// Every pass queued: their numbers into the buffer at once, each where
    /// the device binds a block from, and the passes one list.
    fn run(self: *Post3D, gpa: Allocator) !void {
        const device = self.device;
        const passes = self.passes.items;
        if (passes.len == 0) return;
        self.blocks.clear();
        for (passes) |*held| held.at = try self.blocks.place(gpa, device, std.mem.asBytes(&held.knobs));
        try self.blocks.upload(device);
        const buffer = self.blocks.buffer.?;
        const list = device.begin();
        for (passes) |held| {
            try list.beginPass(.{ .color = .{ .target = held.into, .load = held.load, .clear_color = .{ 0, 0, 0, 0 } } });
            try list.setViewport(.{ .width = @floatFromInt(held.width), .height = @floatFromInt(held.height) });
            try list.setPipeline(held.pipeline);
            try list.setUniformBufferRange(0, buffer, held.at, @sizeOf(Post));
            for (held.sources[0..held.source_count], 0..) |source, slot| try list.setTexture(@intCast(slot), source, self.sampler);
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 3 });
            try list.endPass();
        }
        try device.submit();
    }
};

test "every pass's shader compiles for every backend, and its numbers are laid out as the engine writes them" {
    for ([_][]const u8{ bright_source, down_source, up_source, tone_source, smooth_source }) |source| {
        var said: std.Io.Writer.Allocating = .init(testing.allocator);
        defer said.deinit();
        var module = shader.compile(testing.allocator, source, &said.writer) catch |err| {
            std.debug.print("{s}\n", .{said.written()});
            return err;
        };
        defer module.deinit();
        try testing.expectEqual(@as(u32, @sizeOf(Post)), module.block("Post").?.size);
    }
}

test "a look is what an environment says, or light as it is without one" {
    const plain: Look = .of(null, false);
    try testing.expectEqual(Environment.Tonemap.linear, plain.tonemap);
    try testing.expect(!plain.glow);
    const glowing: Look = .of(.{ .glow = true, .tonemap = .aces, .exposure = 2 }, true);
    try testing.expect(glowing.glow and glowing.smooth);
    try testing.expectEqual(@as(f32, 2), glowing.exposure);
    // No glow added where there is none to add.
    try testing.expect(!Look.of(.{ .glow = true, .glow_intensity = 0 }, false).glow);
}

test "tone and smoothing can both be laid over an existing picture" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var post = try Post3D.init(testing.allocator, &device, .depth32_float);
    defer post.deinit(testing.allocator);
    try testing.expect(!post.tone.over.isNone());
    try testing.expect(!post.smooth.over.isNone());
}
