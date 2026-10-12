// SPDX-License-Identifier: BSD-3-Clause

//! The fog volumes over what is behind the world: a skybox drawn before it,
//! or a picture it is drawn over. A surface is seen through the fog on the
//! way to it (`fog_volumes.zig`); where there is none, the way runs on to the
//! camera's far end, and what is behind is seen through the fog on that.
//!
//! A quad across the whole view at the far end, drawn first in the world's
//! pass: its colour the fog's, its alpha how much of what is behind the fog
//! hides. The surfaces drawn after cover it, as they cover the skybox.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const fog_volumes = @import("fog_volumes.zig");
const View3D = @import("view3d.zig").View3D;

const log = std.log.scoped(.fluxion_engine);

const source =
    \\attribute vec3 POSITION : 0;
    \\
    \\varying vec3 WORLD_POSITION;
    \\
    \\uniform Frame : 0 {
    \\    mat4 VIEW_PROJECTION;
    \\    vec4 CAMERA_POSITION;
    \\    vec4 CAMERA_FORWARD;
    \\}
    \\
++ fog_volumes.shader_part ++
    \\vertex {
    \\    WORLD_POSITION = POSITION;
    \\    position = VIEW_PROJECTION * vec4(POSITION, 1.0);
    \\}
    \\
    \\fragment {
    \\    // The fog volumes take a colour toward theirs by as much as they hide
    \\    // it: from black and from white, how much is hidden, and in what.
    \\    vec3 over_black = fogVolumes(vec3(0.0), WORLD_POSITION);
    \\    vec3 through = fogVolumes(vec3(1.0), WORLD_POSITION) - over_black;
    \\    float hidden = clamp(1.0 - (through.r + through.g + through.b) / 3.0, 0.0, 1.0);
    \\    target = vec4(over_black / max(hidden, 0.0001), hidden);
    \\}
;

/// How far toward the camera's far end the quad is: inside it, not on it.
pub const at_far = 0.98;

pub const FogBackdrop = struct {
    module: shader.Module,
    gpu: rhi.Shader,
    corners: rhi.Buffer,
    /// By samples a pixel: made the first time it is drawn so.
    pipelines: std.AutoHashMapUnmanaged(u32, rhi.Pipeline) = .empty,
    refused: bool = false,

    pub fn init(gpa: Allocator, device: *rhi.Device) !FogBackdrop {
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        var module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("the fog backdrop's shader: {s}", .{said.written()});
            return err;
        };
        errdefer module.deinit();
        const gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = "3D fog backdrop",
        });
        errdefer device.destroyShader(gpu);
        const corners = try device.createBuffer(.{ .kind = .vertex, .size = 4 * @sizeOf([3]f32), .dynamic = true, .label = "3D fog backdrop" });
        return .{ .module = module, .gpu = gpu, .corners = corners };
    }

    pub fn deinit(self: *FogBackdrop, gpa: Allocator, device: *rhi.Device) void {
        var it = self.pipelines.valueIterator();
        while (it.next()) |pipeline| device.destroyPipeline(pipeline.*);
        self.pipelines.deinit(gpa);
        device.destroyBuffer(self.corners);
        device.destroyShader(self.gpu);
        self.module.deinit();
    }

    /// Into the pass `list` has begun: the fog over what is behind `view`.
    pub fn draw(self: *FogBackdrop, gpa: Allocator, device: *rhi.Device, list: *rhi.CommandList, view: View3D, frame: rhi.Buffer, fog: rhi.Buffer, color_format: rhi.Format, depth_format: rhi.Format, samples: u32) !void {
        const pipeline = self.pipelineOf(gpa, device, color_format, depth_format, samples) catch return;
        const corners = cornersOf(view);
        try device.updateBuffer(self.corners, 0, std.mem.sliceAsBytes(&corners));
        try list.setPipeline(pipeline);
        try list.setUniformBuffer(0, frame);
        try list.setUniformBuffer(fog_volumes.slot, fog);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.draw(.{ .vertex_count = 4 });
    }

    fn pipelineOf(self: *FogBackdrop, gpa: Allocator, device: *rhi.Device, color_format: rhi.Format, depth_format: rhi.Format, samples: u32) !rhi.Pipeline {
        if (self.pipelines.get(samples)) |held| return held;
        if (self.refused) return error.Refused;
        const arena = self.module.arena.allocator();
        const names = try arena.alloc([:0]const u8, fog_volumes.slot + 1);
        @memset(names, "");
        for (self.module.blocks) |block| names[block.slot] = try arena.dupeZ(u8, block.name);
        const pipeline = device.createPipeline(.{
            .shader = self.gpu,
            .attributes = &.{.{ .location = 0, .format = .float3, .offset = 0 }},
            .buffers = &.{.{ .stride = @sizeOf([3]f32) }},
            .topology = .triangle_strip,
            .depth = .{},
            .color_format = color_format,
            .depth_format = depth_format,
            .samples = samples,
            .uniform_blocks = names,
            .label = "3D fog backdrop",
        }) catch |err| {
            self.refused = true;
            log.err("the graphics driver refused the fog backdrop's pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        try self.pipelines.put(gpa, samples, pipeline);
        return pipeline;
    }
};

/// The quad's corners, in the world, as a strip: across the whole view, at
/// `at_far` of the way to its far end.
pub fn cornersOf(view: View3D) [4][3]f32 {
    const far = view.far * at_far;
    const middle = view.position.add(view.forward().scale(far));
    const aspect = if (view.height > 0) view.width / view.height else 1;
    const tall = switch (view.projection) {
        .perspective => far * @tan(view.fov / 2),
        .orthogonal => view.size / 2,
    };
    // A little over the edges: nothing of the view's edge is left out.
    const up = view.up().scale(tall * 1.02);
    const right = view.right().scale(tall * aspect * 1.02);
    const at = if (view.projection == .orthogonal) view.position.add(view.forward().scale(far)) else middle;
    return .{
        at.sub(right).sub(up).array(),
        at.add(right).sub(up).array(),
        at.sub(right).add(up).array(),
        at.add(right).add(up).array(),
    };
}

test "the backdrop's quad covers the whole view, at nearly its far end" {
    var placed = @import("../scene/transform3d.zig").Transform3D.at(1, 2, 3);
    placed.lookAt(.init(1, 2, -10), .unit_y);
    var view: View3D = .of(.{ .far = 400 }, placed, 160, 90);
    view.fov = std.math.pi / 2.0;
    const corners = cornersOf(view);
    for (corners) |corner| {
        const p: math.Vec3 = .init(corner[0], corner[1], corner[2]);
        try testing.expectApproxEqAbs(@as(f32, 400 * at_far), p.sub(view.position).dot(view.forward()), 1e-2);
    }
    // At a fov of a right angle, as tall as it is far, and as wide as the view is.
    const height = (math.Vec3{ .x = corners[2][0], .y = corners[2][1], .z = corners[2][2] }).sub(.init(corners[0][0], corners[0][1], corners[0][2])).len();
    try testing.expectApproxEqAbs(@as(f32, 2 * 400 * at_far * 1.02), height, 0.5);
}
