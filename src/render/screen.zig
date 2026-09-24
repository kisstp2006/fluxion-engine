// SPDX-License-Identifier: BSD-3-Clause

//! The frame, drawn where it can be read: into a texture of its own, copied
//! for a shader that reads what is under it, and put on the window at last.
//!
//! A frame is drawn straight into the window's surface while nothing reads
//! it. A material that reads `SCREEN_TEXTURE`, or a project that stretches
//! its picture to the window, has it drawn into `frameOf` instead: a shader
//! cannot read the target it draws into, so what is there so far is copied
//! with `copyOf` - the frame's whole picture, into a second texture - and
//! read from that, and `present` puts the frame on the window, scaled and
//! placed as the stretch says. There is no blit in fluxion-rhi: a copy is a
//! quad over the whole of a target, sampling the picture.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const material = @import("material.zig");
const Color = @import("../color.zig").Color;

/// The quad over the whole of a target, and where in the picture each of its
/// pixels is - counted as `SCREEN_UV` counts, so a copy is the right way up
/// on every backend.
const source =
    \\attribute vec2 corner : 0;
    \\varying vec2 uv;
    \\uniform Blit : 0 { float flip; }
    \\texture2d picture : 0;
    \\vertex {
    \\    uv = vec2(corner.x, 0.5 + (corner.y - 0.5) * flip);
    \\    position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    \\}
    \\fragment {
    \\    target = sample(picture, uv);
    \\}
;

const quad_corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

/// A picture of the frame's, and the size it was made at.
const Picture = struct {
    texture: rhi.Texture,
    width: u32,
    height: u32,
};

/// Where in a target the frame is shown, in its pixels from the top left.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
};

pub const Screen = struct {
    device: *rhi.Device,
    gpu: rhi.Shader,
    pipeline: rhi.Pipeline,
    quad: rhi.Buffer,
    uniforms: rhi.Buffer,
    /// What the frame is drawn into when it has to be read.
    frame: ?Picture = null,
    /// What is drawn so far, copied for a shader to read.
    copy: ?Picture = null,
    /// How many copies the last frame took.
    copies: u32 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device) !Screen {
        var log: std.Io.Writer.Allocating = .init(gpa);
        defer log.deinit();
        var module = shader.compile(gpa, source, &log.writer) catch |err| {
            std.log.scoped(.fluxion_engine).err("screen shader: {s}", .{log.written()});
            return err;
        };
        defer module.deinit();
        const gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .label = "screen",
        });
        errdefer device.destroyShader(gpu);
        const pipeline = try device.createPipeline(.{
            .shader = gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0, .buffer = 0 }},
            .buffers = &.{.{ .stride = @sizeOf(f32) * 2 }},
            .topology = .triangle_strip,
            .uniform_blocks = &.{"Blit"},
            .textures = &.{"picture"},
            .label = "screen",
        });
        errdefer device.destroyPipeline(pipeline);
        const quad = try device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(@TypeOf(quad_corners)),
            .data = std.mem.asBytes(&quad_corners),
            .label = "screen quad",
        });
        errdefer device.destroyBuffer(quad);
        const flip: [4]f32 = .{ material.screenFlip(device), 0, 0, 0 };
        const uniforms = try device.createBuffer(.{
            .kind = .uniform,
            .size = @sizeOf([4]f32),
            .data = std.mem.asBytes(&flip),
            .label = "screen blit",
        });
        return .{ .device = device, .gpu = gpu, .pipeline = pipeline, .quad = quad, .uniforms = uniforms };
    }

    pub fn deinit(self: *Screen) void {
        if (self.frame) |held| self.device.destroyTexture(held.texture);
        if (self.copy) |held| self.device.destroyTexture(held.texture);
        self.device.destroyBuffer(self.uniforms);
        self.device.destroyBuffer(self.quad);
        self.device.destroyPipeline(self.pipeline);
        self.device.destroyShader(self.gpu);
        self.* = undefined;
    }

    /// A texture of this size to draw the frame into: the one made last
    /// time, or a new one when the size changed.
    pub fn frameOf(self: *Screen, width: u32, height: u32) !rhi.Texture {
        return (try self.pictureOf(&self.frame, width, height, "frame")).texture;
    }

    /// What is drawn in `from` so far, copied where a shader can read it
    /// while more is drawn into `from`. Nothing may be in a pass.
    pub fn copyOf(self: *Screen, from: rhi.Texture, width: u32, height: u32, sampler: rhi.Sampler) !rhi.Texture {
        const into = try self.pictureOf(&self.copy, width, height, "frame copy");
        try self.blit(from, .{ .texture = into.texture }, .{ .width = @floatFromInt(width), .height = @floatFromInt(height) }, sampler, null);
        self.copies += 1;
        return into.texture;
    }

    /// Put `from` on `into`, filling `rect` of it, and the rest of it
    /// `bars`: the frame on the window, as the stretch places it.
    pub fn present(self: *Screen, from: rhi.Texture, into: rhi.RenderTarget, rect: Rect, sampler: rhi.Sampler, bars: Color) !void {
        try self.blit(from, into, rect, sampler, bars);
    }

    fn blit(self: *Screen, from: rhi.Texture, into: rhi.RenderTarget, rect: Rect, sampler: rhi.Sampler, clear: ?Color) !void {
        const list = self.device.begin();
        try list.beginPass(.{ .color = .{
            .target = into,
            .load = if (clear == null) .dont_care else .clear,
            .clear_color = if (clear) |c| c.array() else .{ 0, 0, 0, 1 },
        } });
        try list.setViewport(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height });
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.quad, 0);
        try list.setUniformBuffer(0, self.uniforms);
        try list.setTexture(0, from, sampler);
        try list.draw(.{ .vertex_count = 4 });
        try list.endPass();
        try self.device.submit();
    }

    fn pictureOf(self: *Screen, slot: *?Picture, width: u32, height: u32, label: []const u8) !Picture {
        if (slot.*) |held| {
            if (held.width == width and held.height == height) return held;
            self.device.destroyTexture(held.texture);
            slot.* = null;
        }
        const texture = try self.device.createTexture(.{
            .width = @max(width, 1),
            .height = @max(height, 1),
            .usage = .{ .sampled = true, .render_target = true },
            .label = label,
        });
        slot.* = .{ .texture = texture, .width = width, .height = height };
        return slot.*.?;
    }
};

test "a frame is drawn into a picture of its size, copied, and put on a target" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var screen: Screen = try .init(testing.allocator, &device);
    defer screen.deinit();

    const frame = try screen.frameOf(320, 180);
    // Kept while the size stays, remade when it changes.
    try testing.expectEqual(frame, try screen.frameOf(320, 180));
    const sampler = try device.createSampler(.{});
    defer device.destroySampler(sampler);
    _ = try screen.copyOf(frame, 320, 180, sampler);
    try testing.expectEqual(@as(u32, 1), screen.copies);

    const surface = try device.createSurface(.{ .width = 640, .height = 480 });
    defer device.destroySurface(surface);
    try screen.present(frame, .{ .surface = surface }, .{ .y = 60, .width = 640, .height = 360 }, sampler, .black);
    _ = try screen.frameOf(640, 360);
    try testing.expectEqual(@as(u32, 640), screen.frame.?.width);
}
