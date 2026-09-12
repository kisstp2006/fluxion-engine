// SPDX-License-Identifier: BSD-3-Clause

//! The 2D layer: every entity with a `Transform2D` and a `Sprite` or a
//! `Text2D`, drawn through the camera in one instanced draw per texture.
//!
//! One unit quad, and a buffer of 64-byte `Instance`s uploaded in one call:
//! an update per sprite would re-send the whole buffer each time on
//! Direct3D 11, which maps dynamic buffers with `WRITE_DISCARD`. The sine and
//! cosine of a rotation are worked out once per sprite, not per vertex.
//!
//! Sorted back to front by layer and blended with no depth test, because a
//! depth buffer and half-transparent pixels disagree. The texture is in the
//! sort key, so a layer's sprites of one texture are one draw call. What the
//! camera cannot see is dropped before it is sorted.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const shader = @import("fluxion_shader");
const typeface = @import("fluxion_font");

const Assets = @import("../assets.zig");
const components = @import("../components.zig");
const hierarchy = @import("../hierarchy.zig");
const view_mod = @import("view.zig");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Color = components.Color;
const Text2D = components.Text2D;
const View = view_mod.View;
const Bounds = view_mod.Bounds;

const Drawable = ecs.Query(.{ Transform2D, Sprite });
const Labels = ecs.Query(.{ Transform2D, Text2D });

pub const Error = rhi.Error || Allocator.Error || error{ShaderFailed};

/// The shader, in the one language that becomes both GLSL and HLSL.
const source = @embedFile("shaders/sprite.fxs");

/// Which vertex buffer an attribute is read from: `corner` is the quad that
/// never changes, and everything else is per instance.
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

/// One sprite, as the vertex shader reads it: 64 bytes. `extern`, because it
/// is copied into a vertex buffer; the attribute offsets come from the
/// shader's own list, so the two cannot drift apart.
pub const Instance = extern struct {
    /// x and y of the pivot in world space, then width and height.
    placement: [4]f32,
    /// Pivot in zero to one, then the cosine and sine of the rotation.
    spin: [4]f32,
    tint: [4]f32,
    /// u0, v0, u1, v1.
    uv_rect: [4]f32,
};

/// What the frame tells the shader: one matrix.
const Frame = extern struct {
    view_projection: math.Mat4,
};

/// A sprite waiting to be drawn, with what decides its place in the queue.
const Item = struct {
    /// Layer, then texture, so a layer's sprites of one texture form one run
    /// and one draw call.
    key: u64,
    /// `Sprite.order`: sorted between the layer and the texture.
    order: f32,
    /// Where in the walk it was found. The last tie-breaker, so equal sprites
    /// keep their order from frame to frame: the sort is not stable.
    sequence: u32,
    instance: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    blend: Sprite.Blend,

    fn before(_: void, a: Item, b: Item) bool {
        const layer_a = a.key >> 32;
        const layer_b = b.key >> 32;
        if (layer_a != layer_b) return layer_a < layer_b;
        if (a.order != b.order) return a.order < b.order;
        if (a.blend != b.blend) return @intFromEnum(a.blend) < @intFromEnum(b.blend);
        if (a.key != b.key) return a.key < b.key;
        return a.sequence < b.sequence;
    }

    fn sharesDrawWith(self: Item, other: Item) bool {
        return self.blend == other.blend and
            std.meta.eql(self.texture, other.texture) and
            std.meta.eql(self.sampler, other.sampler);
    }
};

/// The four corners of the unit square, as a triangle strip.
const quad_corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

pub const Renderer = struct {
    device: *rhi.Device,

    /// Kept, because the pipeline was described with names inside it.
    module: shader.Module,
    pipelines: std.EnumArray(Sprite.Blend, rhi.Pipeline),

    quad: rhi.Buffer,
    instances: rhi.Buffer,
    /// How many instances the buffer has room for. Grown, never shrunk.
    capacity: u32,
    frame: rhi.Buffer,

    /// This frame's sprites, gathered and sorted. Kept for its capacity.
    items: std.ArrayList(Item) = .empty,

    /// The sorted instances, contiguous, as they are uploaded.
    staging: std.ArrayList(Instance) = .empty,

    /// How many draw calls the last frame took: the number of textures in use.
    draw_calls: u32 = 0,

    /// How many sprites the last frame dropped for being off screen.
    culled: u32 = 0,

    /// How many sprites the last frame drew.
    drawn: u32 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device) Error!Renderer {
        var log: std.Io.Writer.Allocating = .init(gpa);
        defer log.deinit();

        var module = shader.compile(gpa, source, &log.writer) catch {
            // The message names a line and a column in the shader source.
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

        // Locations and formats come from the shader; only which buffer each
        // is packed into is decided here, by `bufferOf`.
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

        var pipelines: std.EnumArray(Sprite.Blend, rhi.Pipeline) = .initFill(.none);
        errdefer for (pipelines.values) |pipeline| device.destroyPipeline(pipeline);
        for (std.enums.values(Sprite.Blend)) |blend| {
            pipelines.set(blend, device.createPipeline(.{
                .shader = handle,
                .attributes = attributes[0..module.attributes.len],
                .buffers = &.{
                    .{ .stride = strides[0] },
                    .{ .stride = strides[1], .step = .instance },
                },
                .topology = .triangle_strip,
                .blend = switch (blend) {
                    .alpha => .alpha,
                    .additive => .additive,
                },
                // Both lists come out of the shader, in slot order.
                .uniform_blocks = (try module.uniformBlockNames()) orelse return Error.ShaderFailed,
                .textures = (try module.textureNames()) orelse return Error.ShaderFailed,
                .label = "sprites",
            }) catch |err| {
                std.log.scoped(.fluxion_engine).err("sprite pipeline: {s}", .{device.diagnostics()});
                return err;
            });
        }

        const block = module.block("Frame") orelse return Error.ShaderFailed;
        const initial_capacity = 256;

        return .{
            .device = device,
            .module = module,
            .pipelines = pipelines,
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
            // The size the shader says the block is.
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
        for (self.pipelines.values) |pipeline| self.device.destroyPipeline(pipeline);
        self.* = undefined;
    }

    /// Draw every sprite and label in the world into `target`, through
    /// `view` - the world's own camera, `View.of`, or anyone else's - at the
    /// view's size.
    ///
    /// `clear` is the colour to start from, or null to draw over what is
    /// there - for when a 3D pass has drawn first. `alpha` is `Time.alpha`,
    /// used by transforms that `interpolate`.
    pub fn draw(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        target: rhi.RenderTarget,
        view: View,
        clear: ?Color,
        alpha: f32,
    ) !void {
        // The box that culls and the matrix that draws are two readings of
        // the same view.
        try self.gather(gpa, world, assets, snapshots, alpha, view.bounds());

        // Gathering the text may have rasterised new letters, so the atlases
        // go up once, before anything samples them.
        try assets.flushFonts();

        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&Frame{
            .view_projection = view.matrix(self.device.clip()),
        }));

        if (self.items.items.len > 0) {
            try self.reserve(@intCast(self.items.items.len));
            // Laid out contiguously and uploaded in one call; see the module
            // comment.
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
        try list.setViewport(.{ .width = view.width, .height = view.height });
        var bound_blend: Sprite.Blend = .alpha;
        try list.setPipeline(self.pipelines.get(bound_blend));
        try list.setVertexBuffer(0, self.quad, 0);
        try list.setUniformBuffer(0, self.frame);

        self.draw_calls = 0;
        self.drawn = @intCast(self.items.items.len);

        var start: usize = 0;
        while (start < self.items.items.len) {
            const first = self.items.items[start];

            var end = start + 1;
            while (end < self.items.items.len and first.sharesDrawWith(self.items.items[end])) : (end += 1) {}

            if (first.blend != bound_blend) {
                bound_blend = first.blend;
                try list.setPipeline(self.pipelines.get(bound_blend));
            }
            try list.setTexture(0, first.texture, first.sampler);
            // A draw has no first-instance argument, so the buffer binding is
            // moved to the start of the run instead.
            try list.setVertexBuffer(1, self.instances, @intCast(start * @sizeOf(Instance)));
            try list.draw(.{ .vertex_count = 4, .instance_count = @intCast(end - start) });
            self.draw_calls += 1;

            start = end;
        }

        try list.endPass();
        try self.device.submit();
    }

    /// Walk the world and turn every visible sprite into an instance.
    fn gather(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        alpha: f32,
        bounds: Bounds,
    ) !void {
        self.items.clearRetainingCapacity();
        self.culled = 0;

        var sequence: u32 = 0;

        var it = try Drawable.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const sprites = chunk.slice(Sprite);

            for (transforms, sprites, chunk.entities) |local, sprite, entity| {
                if (!sprite.visible or sprite.tint.a <= 0) continue;

                // Interpolated, then carried through whatever it hangs from.
                // What cannot be placed - its parent died this frame, or its
                // chain is a cycle - is not drawn.
                const transform = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;

                // A handle that no longer resolves draws as the white texel:
                // a coloured rectangle is a bug somebody notices.
                const texture = assets.get(sprite.texture) orelse
                    assets.get(assets.white) orelse continue;

                const size = spriteSize(sprite, texture);
                const drawn_width = size.width * transform.scale_x;
                const drawn_height = size.height * transform.scale_y;

                // Nowhere near the camera: not sorted, uploaded or drawn.
                if (!bounds.admits(transform.x, transform.y, spriteRadius(drawn_width, drawn_height))) {
                    self.culled += 1;
                    continue;
                }

                const c = @cos(transform.rotation);
                const s = @sin(transform.rotation);

                defer sequence += 1;
                try self.items.append(gpa, .{
                    .key = sortKey(sprite.layer, sprite.texture),
                    .order = sprite.order,
                    .sequence = sequence,
                    .texture = texture.gpu,
                    .sampler = assets.samplerFor(texture.filter, texture.wrap),
                    .blend = sprite.blend,
                    .instance = .{
                        .placement = .{ transform.x, transform.y, drawn_width, drawn_height },
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

        try self.gatherText(gpa, world, assets, snapshots, alpha, bounds, &sequence);

        std.sort.pdq(Item, self.items.items, {}, Item.before);
    }

    /// Turn every `Text2D` into one instance per glyph, in the same list and
    /// the same order as the sprites. A font's atlas is one texture, so all
    /// the text in one font is one draw call.
    fn gatherText(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        alpha: f32,
        bounds: Bounds,
        sequence: *u32,
    ) !void {
        var it = try Labels.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const labels = chunk.slice(Text2D);

            for (transforms, labels, chunk.entities) |local, label, entity| {
                if (!label.visible or label.len == 0 or label.color.a <= 0) continue;

                // Not drawn when it cannot be placed, as with a sprite.
                const transform = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;
                const face = assets.fontOf(label.font) orelse continue;

                try self.layOut(gpa, assets, face, label, transform, bounds, sequence);
            }
        }
    }

    /// Walk one label's characters, and put a quad where each one goes.
    fn layOut(
        self: *Renderer,
        gpa: Allocator,
        assets: *Assets,
        face: *Assets.Font,
        label: Text2D,
        transform: Transform2D,
        bounds: Bounds,
        sequence: *u32,
    ) !void {
        // Whole pixels, as the atlas is keyed.
        const pixels: u16 = @intFromFloat(@max(1, @round(label.size)));
        const scaled = face.face.at(@floatFromInt(pixels));
        const line_height = scaled.lineHeight() * label.line_spacing;

        // The whole label against the camera, boxed generously: one test, not
        // one per letter.
        const measured = measure(&face.face, scaled, label.slice());
        const reach = spriteRadius(
            measured.width * @abs(transform.scale_x),
            (measured.lines * line_height) * @abs(transform.scale_y),
        );
        if (!bounds.admits(transform.x, transform.y, reach)) {
            self.culled += 1;
            return;
        }

        const c = @cos(transform.rotation);
        const sn = @sin(transform.rotation);
        const key = sortKeyOf(label.layer, if (label.font.isNone())
            assets.default_font.index
        else
            label.font.index);

        var line_start: usize = 0;
        var line_index: f32 = 0;
        const run = label.slice();

        while (line_start <= run.len) {
            const end = std.mem.indexOfScalarPos(u8, run, line_start, '\n') orelse run.len;
            const line = run[line_start..end];

            // The transform is the top left of the first line, so the first
            // baseline is one ascent below it.
            const baseline = scaled.ascent() + line_index * line_height;
            var pen: f32 = switch (label.alignment) {
                .left => 0,
                .center => -lineWidth(&face.face, scaled, line) / 2,
                .right => -lineWidth(&face.face, scaled, line),
            };

            var previous_glyph: ?u16 = null;
            var characters = std.unicode.Utf8View.initUnchecked(line).iterator();
            while (characters.nextCodepoint()) |codepoint| {
                const index = face.face.glyphFor(codepoint);

                if (previous_glyph) |left| {
                    const units = face.face.kern(left, index) catch 0;
                    pen += @as(f32, @floatFromInt(units)) * scaled.scale;
                }
                previous_glyph = index;

                const entry = face.atlas.glyph(&face.face, index, pixels) catch |err| switch (err) {
                    // A full atlas drops the rest of this label rather than
                    // failing the frame.
                    error.AtlasFull => break,
                    else => return err,
                };
                defer pen += entry.advance;

                if (entry.width == 0) continue;

                // The glyph's top left, in the label's space, then the world's.
                const placed = transform.apply(pen + entry.left, baseline - entry.top);

                sequence.* += 1;
                try self.items.append(gpa, .{
                    .key = key,
                    .order = label.order,
                    .sequence = sequence.*,
                    .texture = face.texture,
                    // Linear: a zoomed camera draws glyphs at sizes they were
                    // not rasterised at.
                    .sampler = assets.samplerFor(.linear, .clamp_to_edge),
                    .blend = .alpha,
                    .instance = .{
                        .placement = .{
                            placed.x,
                            placed.y,
                            entry.width * transform.scale_x,
                            entry.height * transform.scale_y,
                        },
                        // The pivot is the corner the pen worked out.
                        .spin = .{ 0, 0, c, sn },
                        .tint = .{ label.color.r, label.color.g, label.color.b, label.color.a },
                        .uv_rect = .{ entry.u0, entry.v0, entry.u1, entry.v1 },
                    },
                });
            }

            if (end == run.len) break;
            line_start = end + 1;
            line_index += 1;
        }
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

/// How wide one line is, in pixels, kerning included.
fn lineWidth(face: *const typeface.Font, scaled: typeface.Scaled, line: []const u8) f32 {
    var width: f32 = 0;
    var previous: ?u16 = null;

    var characters = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (characters.nextCodepoint()) |codepoint| {
        const index = face.glyphFor(codepoint);
        if (previous) |left| {
            const units = face.kern(left, index) catch 0;
            width += @as(f32, @floatFromInt(units)) * scaled.scale;
        }
        previous = index;
        width += scaled.advance(index) catch 0;
    }
    return width;
}

/// The widest line, and how many there are.
fn measure(face: *const typeface.Font, scaled: typeface.Scaled, run: []const u8) struct {
    width: f32,
    lines: f32,
} {
    var widest: f32 = 0;
    var lines: f32 = 0;
    var it = std.mem.splitScalar(u8, run, '\n');
    while (it.next()) |line| {
        widest = @max(widest, lineWidth(face, scaled, line));
        lines += 1;
    }
    return .{ .width = widest, .lines = lines };
}

/// How far from its transform a sprite can reach, whatever its pivot and
/// rotation: width plus height, which is generous and needs no square root.
inline fn spriteRadius(width: f32, height: f32) f32 {
    return @abs(width) + @abs(height);
}

/// Where a sprite's four corners land in the world, round from the one at
/// the texture's top left: the vertex shader's arithmetic, on the CPU. What
/// an editor outlines and what a click is tested against. `placed` is the
/// sprite's world transform, and `texture` what its handle resolves to.
pub fn cornersOf(sprite: Sprite, placed: Transform2D, texture: *const Assets.Texture) [4]math.Vec2 {
    const size = spriteSize(sprite, texture);
    const width = size.width * placed.scale_x;
    const height = size.height * placed.scale_y;
    const c = @cos(placed.rotation);
    const s = @sin(placed.rotation);
    var out: [4]math.Vec2 = undefined;
    for (quad_round, &out) |corner, *point| {
        const x = (corner[0] - sprite.pivot_x) * width;
        const y = (corner[1] - sprite.pivot_y) * height;
        point.* = .init(placed.x + x * c - y * s, placed.y + x * s + y * c);
    }
    return out;
}

/// The unit square's corners in order round it, rather than in the strip's
/// order.
const quad_round = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

/// How big a sprite is, falling back to the size of its own artwork.
fn spriteSize(sprite: Sprite, texture: *const Assets.Texture) struct { width: f32, height: f32 } {
    const region_width = @abs(sprite.region.u1 - sprite.region.u0) * @as(f32, @floatFromInt(texture.width));
    const region_height = @abs(sprite.region.v1 - sprite.region.v0) * @as(f32, @floatFromInt(texture.height));
    return .{
        .width = if (sprite.width != 0) sprite.width else region_width,
        .height = if (sprite.height != 0) sprite.height else region_height,
    };
}

/// Layer in the high bits, texture in the low ones. The layer is biased
/// rather than cast, so negative layers sort before positive ones.
fn sortKey(layer: i16, texture: Assets.TextureHandle) u64 {
    return sortKeyOf(layer, texture.index);
}

/// The same for text, which sorts by the font whose atlas it is drawn from.
fn sortKeyOf(layer: i16, texture_index: u32) u64 {
    const biased: u64 = @as(u16, @bitCast(layer)) ^ 0x8000;
    return (biased << 32) | texture_index;
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

test "within a layer, order comes first, then blend, then texture, and sequence breaks the tie" {
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
                .blend = .alpha,
            };
        }

        fn glowing(layer: i16, order: f32, texture: Assets.TextureHandle, sequence: u32) Item {
            var out = make(layer, order, texture, sequence);
            out.blend = .additive;
            return out;
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

    try testing.expect(Item.before({}, item.make(0, 0, second, 1), item.glowing(0, 0, first, 0)));
    try testing.expect(Item.before({}, item.glowing(0, -1, first, 2), item.make(0, 0, second, 1)));
}

test "a sprite with no size of its own takes the texture's" {
    const texture: Assets.Texture = .{ .gpu = .none, .width = 32, .height = 16, .filter = .nearest, .wrap = .clamp_to_edge };
    const size = spriteSize(.{}, &texture);
    try testing.expectEqual(@as(f32, 32), size.width);
    try testing.expectEqual(@as(f32, 16), size.height);

    // Half the texture is half the size.
    const half = spriteSize(.{ .region = .{ .u0 = 0, .v0 = 0, .u1 = 0.5, .v1 = 1 } }, &texture);
    try testing.expectEqual(@as(f32, 16), half.width);
}

test "the corners an editor outlines are where the vertex shader puts them" {
    const texture: Assets.Texture = .{ .gpu = .none, .width = 32, .height = 16, .filter = .nearest, .wrap = .clamp_to_edge };
    const sprite: Sprite = .{ .width = 20, .height = 10, .pivot_x = 0.25, .pivot_y = 0.75 };
    const placed: Transform2D = .{ .x = 100, .y = 50, .rotation = 0.6, .scale_x = 2, .scale_y = -1 };
    const corners = cornersOf(sprite, placed, &texture);

    // `sprite.fxs`, line for line, fed what `gather` gives it.
    const c = @cos(placed.rotation);
    const s = @sin(placed.rotation);
    const placement = [4]f32{ placed.x, placed.y, 20 * placed.scale_x, 10 * placed.scale_y };
    const spin = [4]f32{ sprite.pivot_x, sprite.pivot_y, c, s };
    for (quad_round, corners) |corner, got| {
        const local_x = (corner[0] - spin[0]) * placement[2];
        const local_y = (corner[1] - spin[1]) * placement[3];
        const turned_x = local_x * spin[2] - local_y * spin[3];
        const turned_y = local_x * spin[3] + local_y * spin[2];
        try testing.expectApproxEqAbs(placement[0] + turned_x, got.x, 0.0001);
        try testing.expectApproxEqAbs(placement[1] + turned_y, got.y, 0.0001);
    }

    // And unturned, the box it should be.
    const upright = cornersOf(.{ .width = 20, .height = 10 }, .at(100, 50), &texture);
    try testing.expectApproxEqAbs(@as(f32, 90), upright[0].x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 45), upright[0].y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 110), upright[2].x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 55), upright[2].y, 0.0001);
}

test "a mirrored region is not a negative size" {
    const texture: Assets.Texture = .{ .gpu = .none, .width = 32, .height = 32, .filter = .nearest, .wrap = .clamp_to_edge };
    const size = spriteSize(.{ .region = components.Region.full.flippedX() }, &texture);
    try testing.expectEqual(@as(f32, 32), size.width);
}
