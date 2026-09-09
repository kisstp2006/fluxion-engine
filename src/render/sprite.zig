// SPDX-License-Identifier: BSD-3-Clause

//! The 2D layer: every entity that has a `Transform2D` and a `Sprite`, drawn
//! through the camera, in one instanced draw per texture.
//!
//! ```zig
//! try renderer.draw(gpa, &world, &assets, .{ .surface = surface }, width, height, background);
//! ```
//!
//! **One quad, and a buffer of where it goes.** The vertex buffer holds four
//! corners of a unit square and never changes. Everything that makes one
//! sprite different from another - where it is, how big, which way round,
//! what colour, which part of which texture - is sixty-four bytes in a
//! second buffer that steps once per instance. A thousand sprites is a
//! thousand of those, one upload, and one `draw`.
//!
//! **The upload is one call**, not one per sprite. The sorted sprites are
//! laid out in a staging array and the whole thing goes to the GPU at once.
//! A call per sprite looks the same on a diagram and is not: on Direct3D 11
//! a dynamic buffer is mapped with `WRITE_DISCARD`, which hands back memory
//! with nothing in it, so every update has to re-send the *whole* buffer -
//! a thousand sprites would be a thousand maps of sixty-four kilobytes each.
//!
//! **The rotation is worked out on the processor, not in the shader.** A
//! sine and a cosine per sprite on the CPU, against a sine and a cosine per
//! *vertex* on the GPU - four times as many, for a number that is the same
//! all four times. The instance carries `cos` and `sin` and the vertex shader
//! does two multiplies with them.
//!
//! **Sorted back to front, and blended with no depth test.** A depth buffer
//! decides one pixel at a time whether something is behind something else,
//! which is exactly wrong for half-transparent pixels: the near sprite writes
//! its depth, the far one is rejected, and the glass has nothing behind it.
//! So the 2D layer sorts by `Sprite.layer` and draws in that order, and the
//! sort key has the texture in its low bits so that sprites of one layer
//! sharing a texture come out as one run and therefore one draw call.
//!
//! That is also why this is a separate pass from the 3D layer that does not
//! exist yet, rather than more geometry inside it: the 3D pass wants a depth
//! test and this one must not have one.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const shader = @import("fluxion_shader");

const Assets = @import("../assets.zig");
const components = @import("../components.zig");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Camera2D = components.Camera2D;
const Previous2D = components.Previous2D;
const Color = components.Color;

/// Everything with a place and a picture. The one query this layer runs.
///
/// Walked by hand rather than through `Query.over`, because a third
/// component - `Previous2D` - is read when an archetype has it and skipped
/// when it does not, and a query can only ask for what every row must have.
const Drawable = ecs.Query(.{ Transform2D, Sprite });

/// Everything that can be looked through.
const Cameras = ecs.Query(.{ Transform2D, Camera2D });

pub const Error = rhi.Error || Allocator.Error || error{ShaderFailed};

/// The shader, in the one language that becomes both.
///
/// Writing it here instead of as GLSL beside HLSL is the whole reason
/// [Fluxion Shader](https://github.com/kisstp2006/fluxion-shader) exists: the
/// two would drift, and the drift would show up as one backend drawing
/// correctly and the other not, which is the most expensive kind of bug this
/// stack can have.
const source =
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\attribute vec4 spin : 2;
    \\attribute vec4 tint : 3;
    \\attribute vec4 uv_rect : 4;
    \\
    \\varying vec2 uv;
    \\varying vec4 shade;
    \\
    \\uniform Frame : 0 {
    \\    mat4 view_projection;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\vertex {
    \\    // `corner` is a unit square. Take the pivot off it, scale it to the
    \\    // sprite's size, turn it, and put it where the sprite is.
    \\    vec2 local = (corner - spin.xy) * placement.zw;
    \\    vec2 turned = vec2(
    \\        local.x * spin.z - local.y * spin.w,
    \\        local.x * spin.w + local.y * spin.z
    \\    );
    \\    uv = mix(uv_rect.xy, uv_rect.zw, corner);
    \\    shade = tint;
    \\    position = view_projection * vec4(placement.xy + turned, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = sample(atlas, uv) * shade;
    \\}
;

/// Which vertex buffer each attribute is read from.
///
/// The one thing the shader does not know and cannot: a location and a format
/// belong to the shader, but how the vertices are packed into buffers is this
/// program's business. `corner` is the quad that never changes; everything
/// else is the per-instance buffer.
fn bufferOf(name: []const u8) u32 {
    return if (std.mem.eql(u8, name, "corner")) 0 else 1;
}

fn vertexFormat(ty: shader.Type) !rhi.VertexFormat {
    return switch (ty) {
        .float => .float,
        .vec2 => .float2,
        .vec3 => .float3,
        .vec4 => .float4,
        else => error.NotAVertexFormat,
    };
}

/// One sprite, as the vertex shader reads it. Sixty-four bytes.
///
/// `extern` because it is `memcpy`d into a vertex buffer and the attribute
/// offsets are byte offsets into exactly this. The field order is the order
/// the attributes are declared in the shader above, and the two must not
/// drift apart - which they cannot, because the offsets are computed from the
/// shader's own list rather than written down here.
pub const Instance = extern struct {
    /// x and y of the pivot in world space, then width and height.
    placement: [4]f32,
    /// Pivot in zero to one, then the cosine and sine of the rotation.
    spin: [4]f32,
    tint: [4]f32,
    /// u0, v0, u1, v1.
    uv_rect: [4]f32,
};

/// What the frame tells the shader: one matrix, sixty-four bytes.
const Frame = extern struct {
    view_projection: math.Mat4,
};

/// A sprite waiting to be drawn, with what decides its place in the queue.
const Item = struct {
    /// Layer first, then texture. Sorting on this puts the layers in order
    /// and, inside a layer, gathers each texture into one run - so the number
    /// of draw calls is the number of textures, not the number of sprites.
    key: u64,
    /// `Sprite.order`, between the layer and the texture: it decides the
    /// order inside a layer and the texture only breaks its ties.
    order: f32,
    /// Where in the walk this sprite was found. The last tie-breaker, and
    /// what makes the order of two otherwise equal sprites the same from one
    /// frame to the next - the sort is not a stable one, and without this a
    /// pair of overlapping sprites could swap whenever the world changed
    /// shape.
    sequence: u32,
    instance: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,

    fn before(_: void, a: Item, b: Item) bool {
        const layer_a = a.key >> 32;
        const layer_b = b.key >> 32;
        if (layer_a != layer_b) return layer_a < layer_b;
        if (a.order != b.order) return a.order < b.order;
        if (a.key != b.key) return a.key < b.key;
        return a.sequence < b.sequence;
    }
};

/// The four corners of the unit square, as a triangle strip.
const quad_corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

pub const Renderer = struct {
    device: *rhi.Device,

    /// Kept rather than dropped: the pipeline was described out of the names
    /// in it, and holding it means nothing has to reason about how long a
    /// driver looks at a string.
    module: shader.Module,
    pipeline: rhi.Pipeline,

    quad: rhi.Buffer,
    instances: rhi.Buffer,
    /// How many instances the buffer has room for. Grown, never shrunk: a
    /// game whose sprite count spikes once will spike again.
    capacity: u32,
    frame: rhi.Buffer,

    /// This frame's sprites, gathered and sorted. Kept between frames so a
    /// settled game stops allocating for it.
    items: std.ArrayList(Item) = .empty,

    /// The sorted instances, contiguous, as the GPU reads them. Filled from
    /// `items` after the sort and uploaded in one call.
    staging: std.ArrayList(Instance) = .empty,

    /// How many draw calls the last frame took. Worth watching: it is the
    /// number of textures in use, and a game whose sprites all come from one
    /// atlas should see one.
    draw_calls: u32 = 0,

    /// How many sprites the last frame drew.
    drawn: u32 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device) Error!Renderer {
        var log: std.Io.Writer.Allocating = .init(gpa);
        defer log.deinit();

        var module = shader.compile(gpa, source, &log.writer) catch {
            // The compiler's message names a line and a column in the source
            // above, which is the only place the mistake can be.
            std.log.scoped(.fluxion_engine).err("sprite shader: {s}", .{log.written()});
            return Error.ShaderFailed;
        };
        errdefer module.deinit();

        const handle = device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .label = "sprites",
        }) catch |err| {
            std.log.scoped(.fluxion_engine).err("sprite shader: {s}", .{device.diagnostics()});
            return err;
        };

        // The locations and the formats are the shader's; which buffer each
        // one is packed into is this file's. Nothing is written down twice,
        // so adding a field to `Instance` means adding an attribute to the
        // shader and nothing else.
        var attributes: [8]rhi.VertexAttribute = undefined;
        var strides: [2]u32 = @splat(0);
        for (module.attributes, 0..) |a, i| {
            const buffer = bufferOf(a.name);
            const format = vertexFormat(a.ty) catch return Error.ShaderFailed;
            attributes[i] = .{
                .location = a.location,
                .format = format,
                .offset = strides[buffer],
                .buffer = buffer,
            };
            strides[buffer] += format.size();
        }

        const pipeline = device.createPipeline(.{
            .shader = handle,
            .attributes = attributes[0..module.attributes.len],
            .buffers = &.{
                .{ .stride = strides[0] },
                .{ .stride = strides[1], .step = .instance },
            },
            .topology = .triangle_strip,
            .blend = .alpha,
            // Both lists come out of the shader itself, in slot order. A
            // hole in the numbering is the one thing they cannot express, and
            // this shader has none.
            .uniform_blocks = (try module.uniformBlockNames()) orelse return Error.ShaderFailed,
            .textures = (try module.textureNames()) orelse return Error.ShaderFailed,
            .label = "sprites",
        }) catch |err| {
            std.log.scoped(.fluxion_engine).err("sprite pipeline: {s}", .{device.diagnostics()});
            return err;
        };

        const block = module.block("Frame") orelse return Error.ShaderFailed;
        const initial_capacity = 256;

        return .{
            .device = device,
            .module = module,
            .pipeline = pipeline,
            .quad = try device.createBuffer(.{
                .kind = .vertex,
                .size = @sizeOf(@TypeOf(quad_corners)),
                .data = std.mem.asBytes(&quad_corners),
                .label = "sprite quad",
            }),
            .instances = try device.createBuffer(.{
                .kind = .vertex,
                .size = initial_capacity * @sizeOf(Instance),
                .dynamic = true,
                .label = "sprite instances",
            }),
            .capacity = initial_capacity,
            // The size the shader said the block is, not the size this file
            // guessed it would be.
            .frame = try device.createBuffer(.{
                .kind = .uniform,
                .size = block.size,
                .label = "sprite frame",
            }),
        };
    }

    pub fn deinit(self: *Renderer, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.staging.deinit(gpa);
        self.module.deinit();
        self.device.destroyBuffer(self.quad);
        self.device.destroyBuffer(self.instances);
        self.device.destroyBuffer(self.frame);
        self.device.destroyPipeline(self.pipeline);
        self.* = undefined;
    }

    /// Draw every sprite in the world into `target`.
    ///
    /// `clear` is the colour to start from, or null to draw on top of what is
    /// already there. The 2D layer clears because it is the first thing in
    /// the frame today; when there is a 3D layer under it, this becomes null
    /// and the 3D pass does the clearing. That is the whole of what layering
    /// costs, which is the point of doing it this way round.
    ///
    /// `alpha` is how far the frame sits between the last two fixed steps,
    /// from `Time.alpha`, and only a sprite with a `Previous2D` uses it.
    pub fn draw(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        target: rhi.RenderTarget,
        width: f32,
        height: f32,
        clear: ?Color,
        alpha: f32,
    ) !void {
        try self.gather(gpa, world, assets, alpha);

        const view_projection = self.viewProjection(world, width, height);
        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&Frame{
            .view_projection = view_projection,
        }));

        if (self.items.items.len > 0) {
            try self.reserve(@intCast(self.items.items.len));
            // The instances are interleaved with their sort keys in `items`,
            // so they are laid out contiguously first and go to the GPU as
            // one slice in one call. See the module comment for why one call
            // per sprite is not the same thing.
            self.staging.clearRetainingCapacity();
            try self.staging.ensureTotalCapacity(gpa, self.items.items.len);
            for (self.items.items) |item| self.staging.appendAssumeCapacity(item.instance);
            try self.device.updateBuffer(self.instances, 0, std.mem.sliceAsBytes(self.staging.items));
        }

        const list = self.device.begin();
        try list.beginPass(.{ .color = .{
            .target = target,
            .load = if (clear == null) .load else .clear,
            .clear_color = if (clear) |c| c.array() else .{ 0, 0, 0, 1 },
        } });
        try list.setViewport(.{ .width = width, .height = height });
        try list.setPipeline(self.pipeline);
        try list.setVertexBuffer(0, self.quad, 0);
        try list.setUniformBuffer(0, self.frame);

        self.draw_calls = 0;
        self.drawn = @intCast(self.items.items.len);

        var start: usize = 0;
        while (start < self.items.items.len) {
            const texture = self.items.items[start].texture;
            const sampler = self.items.items[start].sampler;

            // How far this run of one texture goes. Everything in it is one
            // instanced draw.
            var end = start + 1;
            while (end < self.items.items.len and
                std.meta.eql(self.items.items[end].texture, texture) and
                std.meta.eql(self.items.items[end].sampler, sampler)) : (end += 1)
            {}

            try list.setTexture(0, texture, sampler);
            // A draw has no first-instance argument, so a run that does not
            // start at zero is reached by moving the buffer binding instead.
            try list.setVertexBuffer(1, self.instances, @intCast(start * @sizeOf(Instance)));
            try list.draw(.{ .vertex_count = 4, .instance_count = @intCast(end - start) });
            self.draw_calls += 1;

            start = end;
        }

        try list.endPass();
        try self.device.submit();
    }

    /// Walk the world and turn every visible sprite into an instance.
    fn gather(self: *Renderer, gpa: Allocator, world: *ecs.World, assets: *Assets, alpha: f32) !void {
        self.items.clearRetainingCapacity();

        const transform_id = try world.idOf(Transform2D);
        const sprite_id = try world.idOf(Sprite);
        const previous_id = try world.idOf(Previous2D);
        const wanted = [_]ecs.component.Id{ transform_id, sprite_id };

        var sequence: u32 = 0;

        for (world.archetypeSlice()) |*archetype| {
            if (archetype.len() == 0) continue;
            if (!archetype.signature().containsAll(&wanted)) continue;

            // Two plain slices over one archetype's rows, which is what the
            // whole archetype layout is for: no indirection per entity, and a
            // loop the compiler can see all the way through.
            const rows = archetype.len();
            const transforms = column(Transform2D, archetype, transform_id, rows);
            const sprites = column(Sprite, archetype, sprite_id, rows);

            // The third slice is there or it is not, per archetype rather
            // than per sprite, so the loop below asks once.
            const previous: ?[]const Previous2D = if (archetype.columnOf(previous_id) != null)
                column(Previous2D, archetype, previous_id, rows)
            else
                null;

            for (transforms, sprites, 0..) |stepped, sprite, row| {
                if (!sprite.visible or sprite.tint.a <= 0) continue;

                const transform = if (previous) |p| p[row].blend(stepped, alpha) else stepped;

                // A handle that no longer resolves draws as the white texel
                // rather than not at all. A missing texture that shows up as
                // a coloured rectangle is a bug somebody notices; one that
                // shows up as nothing is a bug somebody ships.
                const texture = assets.get(sprite.texture) orelse
                    assets.get(assets.white) orelse continue;

                const size = spriteSize(sprite, texture);
                const c = @cos(transform.rotation);
                const s = @sin(transform.rotation);

                defer sequence += 1;
                try self.items.append(gpa, .{
                    .key = sortKey(sprite.layer, sprite.texture),
                    .order = sprite.order,
                    .sequence = sequence,
                    .texture = texture.gpu,
                    .sampler = assets.samplerFor(texture.filter),
                    .instance = .{
                        .placement = .{
                            transform.x,
                            transform.y,
                            size.width * transform.scale_x,
                            size.height * transform.scale_y,
                        },
                        .spin = .{ sprite.pivot_x, sprite.pivot_y, c, s },
                        .tint = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
                        .uv_rect = .{
                            sprite.region.u0,
                            sprite.region.v0,
                            sprite.region.u1,
                            sprite.region.v1,
                        },
                    },
                });
            }
        }

        std.sort.pdq(Item, self.items.items, {}, Item.before);
    }

    /// One component's values for one archetype, as a slice. What
    /// `Query.Chunk.slice` does, for a walk that is not a query.
    fn column(comptime T: type, archetype: *ecs.Archetype, id: ecs.component.Id, rows: usize) []T {
        const typed: [*]T = @ptrCast(@alignCast(archetype.columnOf(id).?.bytes.ptr));
        return typed[0..rows];
    }

    /// What the camera sees, as one matrix.
    ///
    /// With no camera in the world the view is the window itself: the origin
    /// at the top left corner, one world unit to the pixel. See `Camera2D`.
    fn viewProjection(self: *Renderer, world: *ecs.World, width: f32, height: f32) math.Mat4 {
        const clip = self.device.clip();

        const found = bestCamera(world);
        const camera = found orelse return math.orthographic(.{
            .left = 0,
            .right = width,
            .bottom = height,
            .top = 0,
            .near = -1,
            .far = 1,
            .clip = clip,
        });

        // A zoom of two means everything twice the size, which means the
        // camera sees half as much - so the extents are divided by it and not
        // multiplied. Getting this the wrong way round is the traditional
        // mistake and looks right until somebody zooms.
        //
        // One zoom per axis, because the camera's transform may be scaled
        // unevenly and a single number could only honour one of the two.
        const zoom_x = if (camera.zoom_x > 0) camera.zoom_x else 1;
        const zoom_y = if (camera.zoom_y > 0) camera.zoom_y else 1;
        const half_width = width / (2 * zoom_x);
        const half_height = height / (2 * zoom_y);

        const projection = math.orthographic(.{
            .left = -half_width,
            .right = half_width,
            .bottom = half_height,
            .top = -half_height,
            .near = -1,
            .far = 1,
            .clip = clip,
        });

        // The world moves opposite to the camera, in both senses: it slides
        // by minus the camera's position and turns by minus its rotation.
        const turn: math.Mat4 = .fromAxisAngle(.init(0, 0, 1), -camera.rotation);
        const slide: math.Mat4 = .fromTranslation(.init(-camera.x, -camera.y, 0));
        return projection.mul(turn.mul(slide));
    }

    /// Make sure the instance buffer holds at least this many.
    fn reserve(self: *Renderer, count: u32) !void {
        if (count <= self.capacity) return;

        var capacity = self.capacity;
        while (capacity < count) capacity *= 2;

        const grown = try self.device.createBuffer(.{
            .kind = .vertex,
            .size = capacity * @sizeOf(Instance),
            .dynamic = true,
            .label = "sprite instances",
        });
        self.device.destroyBuffer(self.instances);
        self.instances = grown;
        self.capacity = capacity;
    }
};

/// Where the camera is and what it is doing, flattened out of the two
/// components that say so.
const CameraView = struct {
    x: f32,
    y: f32,
    zoom_x: f32,
    zoom_y: f32,
    rotation: f32,
};

/// The active camera with the highest priority, or none.
fn bestCamera(world: *ecs.World) ?CameraView {
    var it = Cameras.over(world) catch return null;
    var best: ?CameraView = null;
    var best_priority: i16 = std.math.minInt(i16);

    while (it.next()) |chunk| {
        const transforms = chunk.slice(Transform2D);
        const cameras = chunk.slice(Camera2D);
        for (transforms, cameras) |transform, camera| {
            if (!camera.active) continue;
            if (best != null and camera.priority <= best_priority) continue;
            best_priority = camera.priority;
            best = .{
                .x = transform.x,
                .y = transform.y,
                // The camera's own transform may be scaled - a camera parented
                // to something that grows - and that multiplies the zoom
                // rather than fighting it, on each axis separately.
                .zoom_x = camera.zoom * transform.scale_x,
                .zoom_y = camera.zoom * transform.scale_y,
                .rotation = camera.rotation + transform.rotation,
            };
        }
    }
    return best;
}

/// How big a sprite is, falling back to the size of its own artwork.
fn spriteSize(sprite: Sprite, texture: *const Assets.Texture) struct { width: f32, height: f32 } {
    const region_width = @abs(sprite.region.u1 - sprite.region.u0) * @as(f32, @floatFromInt(texture.width));
    const region_height = @abs(sprite.region.v1 - sprite.region.v0) * @as(f32, @floatFromInt(texture.height));
    return .{
        .width = if (sprite.width != 0) sprite.width else region_width,
        .height = if (sprite.height != 0) sprite.height else region_height,
    };
}

/// Layer in the high bits, texture in the low ones.
///
/// The layer is biased rather than cast, because a signed number cast to an
/// unsigned one sorts negatives *after* positives - which would put every
/// background layer on top of everything, and is the sort of bug that looks
/// like a renderer problem for an afternoon.
fn sortKey(layer: i16, texture: Assets.TextureHandle) u64 {
    const biased: u64 = @as(u16, @bitCast(layer)) ^ 0x8000;
    return (biased << 32) | texture.index;
}

test "the sort key puts a background layer behind a foreground one" {
    const back = sortKey(-10, .none);
    const front = sortKey(3, .none);
    try testing.expect(back < front);
}

test "sprites of one layer are grouped by texture" {
    const first: Assets.TextureHandle = .{ .index = 1, .generation = 1 };
    const second: Assets.TextureHandle = .{ .index = 2, .generation = 1 };

    try testing.expect(sortKey(0, first) < sortKey(0, second));
    // ... but the layer still wins over the texture.
    try testing.expect(sortKey(0, second) < sortKey(1, first));
}

test "within a layer, order comes before texture and sequence breaks the tie" {
    const first: Assets.TextureHandle = .{ .index = 1, .generation = 1 };
    const second: Assets.TextureHandle = .{ .index = 2, .generation = 1 };
    const blank: Instance = .{ .placement = @splat(0), .spin = @splat(0), .tint = @splat(0), .uv_rect = @splat(0) };

    const item = struct {
        fn make(layer: i16, order: f32, texture: Assets.TextureHandle, sequence: u32) Item {
            return .{
                .key = sortKey(layer, texture),
                .order = order,
                .sequence = sequence,
                .instance = blank,
                .texture = .none,
                .sampler = .none,
            };
        }
    };

    // A lower order draws first even on a later texture.
    try testing.expect(Item.before({}, item.make(0, 1, second, 0), item.make(0, 2, first, 1)));
    // The same order falls back to the texture, which keeps the batching.
    try testing.expect(Item.before({}, item.make(0, 0, first, 5), item.make(0, 0, second, 0)));
    // Everything equal: whichever was found first.
    try testing.expect(Item.before({}, item.make(0, 0, first, 3), item.make(0, 0, first, 4)));
    try testing.expect(!Item.before({}, item.make(0, 0, first, 4), item.make(0, 0, first, 3)));
    // And the layer still wins over all of it.
    try testing.expect(Item.before({}, item.make(-1, 100, second, 9), item.make(0, 0, first, 0)));
}

test "a sprite with no size of its own takes the texture's" {
    const texture: Assets.Texture = .{ .gpu = .none, .width = 32, .height = 16, .filter = .nearest };
    const size = spriteSize(.{}, &texture);
    try testing.expectEqual(@as(f32, 32), size.width);
    try testing.expectEqual(@as(f32, 16), size.height);

    // Half the texture is half the size.
    const half = spriteSize(.{ .region = .{ .u0 = 0, .v0 = 0, .u1 = 0.5, .v1 = 1 } }, &texture);
    try testing.expectEqual(@as(f32, 16), half.width);
}

test "a mirrored region is not a negative size" {
    const texture: Assets.Texture = .{ .gpu = .none, .width = 32, .height = 32, .filter = .nearest };
    const size = spriteSize(.{ .region = components.Region.full.flippedX() }, &texture);
    try testing.expectEqual(@as(f32, 32), size.width);
}
