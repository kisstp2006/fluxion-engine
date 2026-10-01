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
//!
//! A view that sees a light is drawn in three passes: the lit world, the
//! light into a buffer of its own, and the buffer laid over the world with
//! what is unshaded drawn after it. See `lighting.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const typeface = @import("fluxion_font");

const Assets = @import("../assets/assets.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const Inherited = @import("../scene/inherited.zig").Inherited;
const Processing = @import("../scene/inherited.zig").Processing;
const Resolved = @import("../scene/inherited.zig").Resolved;
const tilemap = @import("../tiles/tilemap.zig");
const tileset = @import("../tiles/tileset.zig");
const Bounds = @import("view.zig").Bounds;
const View = @import("view.zig").View;

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Color = components.Color;
const Text2D = components.Text2D;
const Texts = @import("../scene/component_texts.zig").Texts;
const keyFor = @import("../scene/component_texts.zig").keyFor;
/// What a label says, among the app's texts.
const text_key = keyFor(Text2D, "text");

const Material = @import("shaders.zig").Material;
const Params = @import("shaders.zig").Params;
const ShaderHandle = @import("shaders.zig").ShaderHandle;
const Shaders = @import("shaders.zig").Shaders;
const material = @import("shaders.zig").material;
const pack = @import("shaders.zig").pack;
const Screen = @import("screen.zig").Screen;
const Views = @import("view_textures.zig").Views;
const Drawing2D = @import("drawing.zig").Drawing2D;
const Drawings = @import("drawing.zig").Drawings;
const Picture = @import("drawing.zig").Picture;
const Shape = @import("drawing.zig").Shape;
const segmentsOf = @import("drawing.zig").segmentsOf;
const Particle = @import("particles.zig").Particle;
const Particles = @import("particles.zig").Particles;
const Particles2D = @import("particles.zig").Particles2D;
const dot_size = @import("particles.zig").dot_size;
const Lighting = @import("lighting.zig").Lighting;
const overView = @import("lighting.zig").overView;

const Drawable = ecs.Query(.{ Transform2D, Sprite });
const Labels = ecs.Query(.{ Transform2D, Text2D });
const TileChunks = ecs.Query(.{tilemap.TileChunk});
const Drawings2D = ecs.Query(.{Drawing2D});
const Emitters = ecs.Query(.{Particles2D});

pub const Error = rhi.Error || Allocator.Error || error{ShaderFailed};

/// One sprite, as the vertex shader reads it: 64 bytes. `extern`, because it
/// is copied into a vertex buffer; the attribute offsets come from the
/// shader's own list, so the two cannot drift apart.
pub const Instance = extern struct {
    /// Where the unit square's corner (0, 0) lands in the world, then the way
    /// to where (1, 0) does.
    place: [4]f32,
    /// The way to where (0, 1) lands, then 1 for a triangle - (1, 1) folded
    /// onto (0, 1) - and 0 for a four-cornered shape.
    shape: [4]f32,
    tint: [4]f32,
    /// u0, v0, u1, v1.
    uv_rect: [4]f32,

    /// A box `width` by `height` whose point `pivot` - from nought to one -
    /// sits at `x, y`, turned by the angle whose cosine and sine are `c` and
    /// `s`: a sprite, a glyph, a tile.
    pub fn quad(x: f32, y: f32, width: f32, height: f32, pivot_x: f32, pivot_y: f32, c: f32, s: f32, tint: [4]f32, uv_rect: [4]f32) Instance {
        const across = [2]f32{ width * c, width * s };
        const down = [2]f32{ -height * s, height * c };
        return .{
            .place = .{ x - pivot_x * across[0] - pivot_y * down[0], y - pivot_x * across[1] - pivot_y * down[1], across[0], across[1] },
            .shape = .{ down[0], down[1], 0, 0 },
            .tint = tint,
            .uv_rect = uv_rect,
        };
    }

    /// Any four-cornered shape with parallel sides: `origin`, and the ways
    /// to its next two corners.
    pub fn parallelogram(origin: math.Vec2, across: math.Vec2, down: math.Vec2, tint: [4]f32, uv_rect: [4]f32) Instance {
        return .{
            .place = .{ origin.x, origin.y, across.x, across.y },
            .shape = .{ down.x, down.y, 0, 0 },
            .tint = tint,
            .uv_rect = uv_rect,
        };
    }

    /// A triangle of one colour, corner by corner.
    pub fn triangle(a: math.Vec2, b: math.Vec2, c: math.Vec2, tint: [4]f32) Instance {
        return .{
            .place = .{ a.x, a.y, b.x - a.x, b.y - a.y },
            .shape = .{ c.x - a.x, c.y - a.y, 1, 0 },
            .tint = tint,
            .uv_rect = .{ 0, 0, 1, 1 },
        };
    }

    /// Where the vertex stage puts a corner of the unit square.
    pub fn corner(self: Instance, x: f32, y: f32) math.Vec2 {
        const fold = self.shape[2] * x * y;
        const cx = x - x * fold;
        const cy = y + (1 - y) * fold;
        return .init(self.place[0] + self.place[2] * cx + self.shape[0] * cy, self.place[1] + self.place[3] * cx + self.shape[1] * cy);
    }
};

/// No numbers of a material's own: a plain picture, or a shader with no
/// block.
const no_params = std.math.maxInt(u32);

/// A sprite waiting to be drawn, with what decides its place in the queue.
const Item = struct {
    /// Layer, then texture, so a layer's sprites of one texture form one run
    /// and one draw call.
    key: u64,
    /// `Sprite.order`: sorted between the layer and the texture.
    order: f32,
    instance: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    blend: material.Blend,
    /// The shader its `Material` names, or none for a plain picture.
    shader: ShaderHandle = .none,
    /// Which of this frame's sets of numbers its material gives, or
    /// `no_params`.
    params: u32 = no_params,
    /// Drawn as it is over the lit world, in a frame that is lit.
    unshaded: bool = false,

    /// What it is drawn in the order of, as one number, most telling first:
    /// in a lit frame the lit before the unshaded, then the layer, the order,
    /// the blend, the shader, the set of numbers and the texture - the last
    /// four so that what shares a draw is together. Two with the same key
    /// are drawn in the order they were found, so they keep it from frame to
    /// frame. A shader's index past 16 bits or a set's past 24 are taken as
    /// the last there is: they sort together, which costs draws, not order.
    fn rank(self: Item, lit: bool) u128 {
        var out: u128 = @intFromBool(lit and self.unshaded);
        out = (out << 16) | (self.key >> 32);
        out = (out << 32) | orderBits(self.order);
        out = (out << 4) | @intFromEnum(self.blend);
        out = (out << 16) | @min(self.shader.index, 0xFFFF);
        out = (out << 24) | @min(self.params, 0xFF_FFFF);
        out = (out << 32) | (self.key & 0xFFFF_FFFF);
        return out;
    }

    comptime {
        std.debug.assert(@typeInfo(material.Blend).@"enum".fields.len <= 16);
    }

    fn sharesDrawWith(self: Item, other: Item) bool {
        return self.blend == other.blend and
            self.shader.eql(other.shader) and
            self.params == other.params and
            std.meta.eql(self.texture, other.texture) and
            std.meta.eql(self.sampler, other.sampler);
    }
};

/// A float's bits turned so that they compare as the float does: nought and
/// minus nought alike.
fn orderBits(order: f32) u32 {
    const bits: u32 = @bitCast(if (order == 0) 0 else order);
    return if (bits >> 31 != 0) ~bits else bits | 0x8000_0000;
}

/// One item's key and where it was found: what the frame sorts, small, so
/// the sort moves little.
const Ranked = struct {
    key: u128,
    at: u32,

    fn before(_: void, a: Ranked, b: Ranked) bool {
        return a.key < b.key or (a.key == b.key and a.at < b.at);
    }
};

/// `ranked` in the order of its keys, those alike kept in the order they
/// are in: a byte of the key at a time, from the lowest, leaving out the
/// bytes every key has alike - most of them, in most frames - so a frame
/// costs a few passes over its items rather than a comparison sort's many.
/// `room` is as long as `ranked`.
fn radixSort(ranked: []Ranked, room: []Ranked) void {
    if (ranked.len < 2) return;
    var differ: u128 = 0;
    for (ranked) |one| differ |= one.key ^ ranked[0].key;
    var from = ranked;
    var to = room[0..ranked.len];
    var byte: u8 = 0;
    while (byte < 16) : (byte += 1) {
        const shift: u7 = @intCast(byte * 8);
        if (@as(u8, @truncate(differ >> shift)) == 0) continue;
        var starts: [256]u32 = @splat(0);
        for (from) |one| starts[@as(u8, @truncate(one.key >> shift))] += 1;
        var sum: u32 = 0;
        for (&starts) |*start| {
            const count = start.*;
            start.* = sum;
            sum += count;
        }
        for (from) |one| {
            const digit: u8 = @truncate(one.key >> shift);
            to[starts[digit]] = one;
            starts[digit] += 1;
        }
        std.mem.swap([]Ranked, &from, &to);
    }
    if (from.ptr != ranked.ptr) @memcpy(ranked, from);
}

/// What a drawn thing's material gives it.
const DrawnWith = struct { shader: ShaderHandle = .none, params: u32 = no_params };

/// What only some of the things a walk finds have, read a chunk at a time:
/// a thing with none of it is a root, looks as nothing above it says, and
/// has no material and no view's picture - and nothing is looked up for it.
const Has = struct {
    parents: ?[]const components.Parent,
    own_looks: bool,
    material: bool,
    view_texture: bool,

    fn of(chunk: anytype) Has {
        return .{
            .parents = chunk.optional(components.Parent),
            .own_looks = chunk.optional(Appearance) != null or chunk.optional(Processing) != null,
            .material = chunk.optional(Material) != null,
            .view_texture = chunk.optional(components.ViewTexture) != null,
        };
    }

    fn parentOf(self: Has, row: usize) ecs.Entity {
        const held = self.parents orelse return .none;
        return held[row].entity;
    }

    /// What it is under everything above it: the defaults for a root with
    /// nothing of its own.
    fn looks(self: Has, gpa: Allocator, world: *ecs.World, inherited: *Inherited, entity: ecs.Entity, row: usize) Resolved {
        if (!self.own_looks and self.parentOf(row).isNone()) return .{};
        return inherited.of(gpa, world, entity);
    }

    /// Where it is in the world: its own transform, for a root.
    fn placed(self: Has, world: *ecs.World, snapshots: *const hierarchy.Snapshots, entity: ecs.Entity, row: usize, local: Transform2D, alpha: f32) ?Transform2D {
        if (self.parentOf(row).isNone()) return hierarchy.stepped(snapshots, entity, local, alpha);
        return hierarchy.resolve(world, snapshots, entity, local, alpha);
    }
};

/// The four corners of the unit square, as a triangle strip.
const quad_corners = [8]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

/// One set of a frame's material numbers: where its bytes are, and a hash
/// that finds another set of the same.
const ParamSet = struct {
    start: u32,
    len: u32,
};

/// A uniform buffer a set of numbers is put in, kept from frame to frame.
const ParamBuffer = struct {
    buffer: rhi.Buffer,
    size: u32,
};

pub const Renderer = struct {
    device: *rhi.Device,
    /// What each `Text2D` says: the app's. Nothing is drawn of one without.
    texts: ?*const Texts = null,
    /// The shaders a `Material` names, and the numbers each gives. Without
    /// them every sprite is a plain picture.
    shaders: ?*const Shaders = null,
    params: ?*const Params = null,
    /// Where what is drawn so far is copied for a shader that reads it. With
    /// none, such a shader reads a white picture.
    screen: ?*Screen = null,
    /// Seconds, as `TIME`.
    time: f32 = 0,
    /// The picture each `RenderView` draws, for what a `ViewTexture` shows.
    views: ?*const Views = null,
    /// What each `Drawing2D` has drawn. Nothing of one is drawn without.
    drawings: ?*const Drawings = null,
    /// Each emitter's particles. None are drawn without.
    particles: ?*const Particles = null,
    /// The font whose atlas the last label found full.
    full: ?*Assets.Font = null,
    /// The fonts whose atlases this frame's words emptied: one that fills
    /// again grows.
    emptied: std.ArrayList(*Assets.Font) = .empty,
    /// Whether a label that finds its atlas full leaves out the rest of its
    /// letters, rather than asking for room: the last pass of a frame whose
    /// words do not fit the biggest atlas.
    fit_only: bool = false,
    /// Whether that has been said.
    said_full: bool = false,
    /// Each label's letters as last laid out, by its entity: one whose
    /// words, font, size and atlas are as they were is only placed again.
    /// See `layOut`.
    laid: std.AutoArrayHashMapUnmanaged(u64, Laid) = .empty,
    /// A drawing's words, laid out each time they are drawn.
    loose: Laid = .{},
    /// Counts the times the words are gathered, for `Laid.used`.
    text_clock: u64 = 0,

    /// A picture, coloured: what a sprite with no material is drawn with,
    /// and the light buffer is laid over the world with.
    plain: material.Compiled,
    /// The same, for one that multiplies what is under it.
    multiplied: material.Compiled,
    lighting: Lighting,

    quad: rhi.Buffer,
    instances: rhi.Buffer,
    /// How many instances the buffer has room for. Grown, never shrunk.
    capacity: u32,
    frame: rhi.Buffer,
    /// What a shader that reads the screen reads when there is no copy of it.
    white: rhi.Texture,
    white_sampler: rhi.Sampler,

    /// This frame's sprites, gathered and sorted. Kept for its capacity.
    items: std.ArrayList(Item) = .empty,
    /// The frame's items ranked, and put in that order: kept from frame to
    /// frame, as `items` is.
    sort_keys: std.ArrayList(Ranked) = .empty,
    sort_room: std.ArrayList(Ranked) = .empty,
    sorted: std.ArrayList(Item) = .empty,
    /// An emitter's living particles, in the order they are drawn.
    ranks: std.ArrayList(u32) = .empty,

    /// The sorted instances, contiguous, as they are uploaded.
    staging: std.ArrayList(Instance) = .empty,

    /// This frame's sets of material numbers, their bytes one after
    /// another, and the uniform buffers they are put in.
    param_sets: std.ArrayList(ParamSet) = .empty,
    param_bytes: std.ArrayList(u8) = .empty,
    param_found: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    param_buffers: std.ArrayList(ParamBuffer) = .empty,

    /// How many draw calls the last frame took: the number of textures in use.
    draw_calls: u32 = 0,

    /// How many sprites the last frame dropped for being off screen.
    culled: u32 = 0,

    /// How many sprites the last frame drew.
    drawn: u32 = 0,

    tile_chunks_drawn: u32 = 0,
    tile_chunks_culled: u32 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device) Error!Renderer {
        var problems: std.Io.Writer.Allocating = .init(gpa);
        defer problems.deinit();
        var plain = material.compile(gpa, device, material.plain, "sprites", &problems.writer, &.{ .alpha, .additive, .subtractive, .lit }) catch |err| {
            std.log.scoped(.fluxion_engine).err("sprite shader: {s}", .{problems.written()});
            return err;
        };
        errdefer plain.deinit(device);
        var multiplied = material.compile(gpa, device, material.plain_multiply, "multiplied sprites", &problems.writer, &.{.multiply}) catch |err| {
            std.log.scoped(.fluxion_engine).err("sprite shader: {s}", .{problems.written()});
            return err;
        };
        errdefer multiplied.deinit(device);
        var lighting: Lighting = try .init(gpa, device);
        errdefer lighting.deinit(gpa);

        const initial_capacity = 256;
        const quad = try device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(@TypeOf(quad_corners)),
            .data = std.mem.asBytes(&quad_corners),
            .label = "sprite quad",
        });
        errdefer device.destroyBuffer(quad);
        const instances = try device.createBuffer(.{
            .kind = .vertex,
            .size = initial_capacity * @sizeOf(Instance),
            .dynamic = true,
            .label = "sprite instances",
        });
        errdefer device.destroyBuffer(instances);
        const frame = try device.createBuffer(.{
            .kind = .uniform,
            .size = @sizeOf(material.Frame),
            .label = "sprite frame",
        });
        errdefer device.destroyBuffer(frame);
        const white_texel = [4]u8{ 255, 255, 255, 255 };
        const white = try device.createTexture(.{ .width = 1, .height = 1, .data = &white_texel, .label = "no screen" });
        errdefer device.destroyTexture(white);
        const white_sampler = try device.createSampler(.{});

        return .{
            .device = device,
            .plain = plain,
            .multiplied = multiplied,
            .lighting = lighting,
            .quad = quad,
            .instances = instances,
            .capacity = initial_capacity,
            .frame = frame,
            .white = white,
            .white_sampler = white_sampler,
        };
    }

    pub fn deinit(self: *Renderer, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.sort_keys.deinit(gpa);
        self.sort_room.deinit(gpa);
        self.sorted.deinit(gpa);
        self.ranks.deinit(gpa);
        self.emptied.deinit(gpa);
        for (self.laid.values()) |*held| held.glyphs.deinit(gpa);
        self.laid.deinit(gpa);
        self.loose.glyphs.deinit(gpa);
        self.staging.deinit(gpa);
        self.param_sets.deinit(gpa);
        self.param_bytes.deinit(gpa);
        self.param_found.deinit(gpa);
        for (self.param_buffers.items) |held| self.device.destroyBuffer(held.buffer);
        self.param_buffers.deinit(gpa);
        self.plain.deinit(self.device);
        self.multiplied.deinit(self.device);
        self.lighting.deinit(gpa);
        self.device.destroyBuffer(self.quad);
        self.device.destroyBuffer(self.instances);
        self.device.destroyBuffer(self.frame);
        self.device.destroyTexture(self.white);
        self.device.destroySampler(self.white_sampler);
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
        tile_sets: *tileset.TileSets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        target: rhi.RenderTarget,
        view: View,
        clear: ?Color,
        alpha: f32,
    ) !void {
        self.forgetParams();
        // The box that culls and the matrix that draws are two readings of
        // the same view.
        const lit = try self.lighting.gather(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view);
        try self.gather(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view, lit);

        // Gathering the text may have rasterised new letters, so the atlases
        // go up once, before anything samples them.
        try assets.flushFonts();

        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&self.frameOf(view.matrix(self.device.clip()), view.width, view.height)));
        try self.uploadParams(gpa);

        // The world's instances, then the lights', then the light buffer
        // laid over the world: contiguous, and uploaded in one call; see the
        // module comment.
        const items = self.items.items;
        const lights = if (lit) self.lighting.draws.items else &.{};
        const laid_over = items.len + lights.len;
        const total = laid_over + @intFromBool(lit);
        if (total > 0) {
            try self.reserve(@intCast(total));
            self.staging.clearRetainingCapacity();
            try self.staging.ensureTotalCapacity(gpa, total);
            for (items) |item| self.staging.appendAssumeCapacity(item.instance);
            for (lights) |drawn| self.staging.appendAssumeCapacity(drawn.instance);
            // The buffer is drawn upside down where the device counts rows
            // from the bottom, as a render view's picture is.
            const uv: [4]f32 = if (self.device.caps().features.render_target_origin_bottom_left) .{ 0, 1, 1, 0 } else .{ 0, 0, 1, 1 };
            if (lit) self.staging.appendAssumeCapacity(overView(view, @splat(1), uv));
            try self.device.updateBuffer(self.instances, 0, std.mem.sliceAsBytes(self.staging.items));
        }

        self.draw_calls = 0;
        self.drawn = @intCast(items.len);

        var pass: Pass = .{ .renderer = self, .target = target, .width = view.width, .height = view.height };
        try pass.begin(clear);
        if (!lit) {
            try self.drawItems(&pass, 0, items.len);
            return pass.end();
        }

        const unshaded = for (items, 0..) |item, i| {
            if (item.unshaded) break i;
        } else items.len;
        try self.drawItems(&pass, 0, unshaded);
        try pass.end();

        const buffer = try self.lighting.bufferOf(@intFromFloat(view.width), @intFromFloat(view.height));
        var light: Pass = .{ .renderer = self, .target = .{ .texture = buffer }, .width = view.width, .height = view.height };
        try light.begin(self.lighting.clearColor());
        var start: usize = 0;
        while (start < lights.len) {
            const first = lights[start];
            var end = start + 1;
            while (end < lights.len and first.sharesDrawWith(lights[end])) : (end += 1) {}
            try light.useCompiled(&self.lighting.shader, first.blend);
            try light.bindPicture(first.texture, first.sampler);
            try light.drawRun(items.len + start, end - start);
            start = end;
        }
        try light.end();

        try pass.begin(null);
        try pass.useCompiled(&self.plain, .lit);
        try pass.bindPicture(buffer, assets.samplerFor(.nearest, .clamp_to_edge));
        try pass.drawRun(laid_over, 1);
        try self.drawItems(&pass, unshaded, items.len);
        try pass.end();
    }

    /// The items from `from` to `to`, a draw for each run that shares one.
    fn drawItems(self: *Renderer, pass: *Pass, from: usize, to: usize) !void {
        const items = self.items.items;
        var start = from;
        while (start < to) {
            const first = items[start];
            var end = start + 1;
            while (end < to and first.sharesDrawWith(items[end])) : (end += 1) {}
            try pass.use(first.shader, first.blend, first.params);
            try pass.bindPicture(first.texture, first.sampler);
            try pass.drawRun(start, end - start);
            start = end;
        }
    }

    /// Draw one quad through `entity`'s material into `target`, which is
    /// `width` by `height` pixels, with the pixels as its space: a
    /// control's box the interface left for its shader. `scissor` clips it.
    pub fn drawQuad(
        self: *Renderer,
        gpa: Allocator,
        entity: ecs.Entity,
        shader: ShaderHandle,
        target: rhi.RenderTarget,
        width: f32,
        height: f32,
        instance: Instance,
        texture: rhi.Texture,
        sampler: rhi.Sampler,
        scissor: ?rhi.Rect,
    ) !void {
        self.forgetParams();
        const compiled = (if (self.shaders) |table| table.compiledOf(shader) else null) orelse return;
        const params = try self.paramSetOf(gpa, compiled, entity);
        try self.uploadParams(gpa);
        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&self.frameOf(View.screen(width, height).matrix(self.device.clip()), width, height)));
        try self.reserve(1);
        try self.device.updateBuffer(self.instances, 0, std.mem.asBytes(&instance));

        var pass: Pass = .{ .renderer = self, .target = target, .width = width, .height = height, .scissor = scissor };
        try pass.begin(null);
        try pass.use(shader, .alpha, params);
        try pass.bindPicture(texture, sampler);
        try pass.list.setVertexBuffer(1, self.instances, 0);
        try pass.list.draw(.{ .vertex_count = 4, .instance_count = 1 });
        try pass.end();
    }

    fn frameOf(self: *const Renderer, projection: math.Mat4, width: f32, height: f32) material.Frame {
        return .{
            .projection = projection,
            .screen_pixel_size = .{ 1 / @max(width, 1), 1 / @max(height, 1) },
            .time = self.time,
            .screen_flip = material.screenFlip(self.device),
        };
    }

    /// The compiled shader a handle names, or the plain one for `blend`.
    fn compiledFor(self: *const Renderer, shader: ShaderHandle, blend: material.Blend) *const material.Compiled {
        const plain = if (blend == .multiply) &self.multiplied else &self.plain;
        if (shader.isNone()) return plain;
        const table = self.shaders orelse return plain;
        return table.compiledOf(shader) orelse plain;
    }

    fn forgetParams(self: *Renderer) void {
        self.param_sets.clearRetainingCapacity();
        self.param_bytes.clearRetainingCapacity();
        self.param_found.clearRetainingCapacity();
    }

    /// Which of this frame's sets of numbers `entity`'s material gives
    /// `compiled`: one made for it, or the same one another gave.
    fn paramSetOf(self: *Renderer, gpa: Allocator, compiled: *const material.Compiled, entity: ecs.Entity) !u32 {
        const block = compiled.params orelse return no_params;
        const given = if (self.params) |store| store.of(entity) else &.{};
        const start: u32 = @intCast(self.param_bytes.items.len);
        try self.param_bytes.resize(gpa, start + block.size);
        const bytes = self.param_bytes.items[start..];
        pack(block, given, bytes);
        const hash = std.hash.Wyhash.hash(block.size, bytes);
        const found = try self.param_found.getOrPut(gpa, hash);
        if (found.found_existing) {
            self.param_bytes.shrinkRetainingCapacity(start);
            return found.value_ptr.*;
        }
        found.value_ptr.* = @intCast(self.param_sets.items.len);
        try self.param_sets.append(gpa, .{ .start = start, .len = block.size });
        return found.value_ptr.*;
    }

    /// Put each set of numbers in a uniform buffer of its own: a buffer is
    /// bound whole, with no offset.
    fn uploadParams(self: *Renderer, gpa: Allocator) !void {
        for (self.param_sets.items, 0..) |set, index| {
            if (index == self.param_buffers.items.len) try self.param_buffers.append(gpa, .{ .buffer = .none, .size = 0 });
            const held = &self.param_buffers.items[index];
            if (held.size < set.len) {
                if (held.size > 0) self.device.destroyBuffer(held.buffer);
                held.* = .{ .size = 0, .buffer = .none };
                held.buffer = try self.device.createBuffer(.{ .kind = .uniform, .size = set.len, .label = "material numbers" });
                held.size = set.len;
            }
            try self.device.updateBuffer(held.buffer, 0, self.param_bytes.items[set.start..][0..set.len]);
        }
    }

    /// A pass into the frame's target, and what is bound in it: begun again
    /// after a copy of the screen, with all of it bound again.
    const Pass = struct {
        renderer: *Renderer,
        target: rhi.RenderTarget,
        width: f32,
        height: f32,
        scissor: ?rhi.Rect = null,
        list: *rhi.CommandList = undefined,
        /// What it draws with now.
        bound: ?Bound = null,
        /// Whether anything has been drawn since the screen was last copied.
        drew: bool = false,
        /// The copy a shader reading the screen reads, while it holds.
        copy: ?rhi.Texture = null,

        /// A shader, a way of blending and a set of numbers.
        const Bound = struct {
            compiled: *const material.Compiled,
            blend: material.Blend,
            params: u32,
        };

        fn begin(self: *Pass, clear: ?Color) !void {
            const r = self.renderer;
            self.list = r.device.begin();
            try self.list.beginPass(.{ .color = .{
                .target = self.target,
                .load = if (clear == null) .load else .clear,
                .clear_color = if (clear) |c| c.array() else .{ 0, 0, 0, 1 },
            } });
            try self.list.setViewport(.{ .width = self.width, .height = self.height });
            if (self.scissor) |clip| try self.list.setScissor(clip);
            if (self.bound) |held| {
                self.bound = null;
                try self.bind(held);
            }
        }

        fn end(self: *Pass) !void {
            try self.list.setScissor(null);
            try self.list.endPass();
            try self.renderer.device.submit();
        }

        /// Draw with a material's shader - the plain one for none - a way of
        /// blending and a set of numbers.
        fn use(self: *Pass, shader: ShaderHandle, blend: material.Blend, params: u32) !void {
            try self.bind(.{ .compiled = self.renderer.compiledFor(shader, blend), .blend = blend, .params = params });
        }

        /// Draw with one of the renderer's own shaders.
        fn useCompiled(self: *Pass, compiled: *const material.Compiled, blend: material.Blend) !void {
            try self.bind(.{ .compiled = compiled, .blend = blend, .params = no_params });
        }

        fn bind(self: *Pass, wanted: Bound) !void {
            if (self.bound) |held| if (std.meta.eql(held, wanted)) return;
            const r = self.renderer;
            self.bound = wanted;
            try self.list.setPipeline(wanted.compiled.pipelines.get(wanted.blend));
            try self.list.setVertexBuffer(0, r.quad, 0);
            try self.list.setUniformBuffer(0, r.frame);
            if (wanted.params != no_params and wanted.compiled.params != null) {
                try self.list.setUniformBuffer(material.params_slot, r.param_buffers.items[wanted.params].buffer);
            }
        }

        /// Draw `count` of the frame's instances from `start`.
        fn drawRun(self: *Pass, start: usize, count: usize) !void {
            // A draw has no first-instance argument, so the buffer binding is
            // moved to the start of the run instead.
            try self.list.setVertexBuffer(1, self.renderer.instances, @intCast(start * @sizeOf(Instance)));
            try self.list.draw(.{ .vertex_count = 4, .instance_count = @intCast(count) });
            self.drew = true;
            self.renderer.draw_calls += 1;
        }

        /// Bind a run's picture, and - for a shader that reads the screen -
        /// a copy of what is drawn so far, made now if more has been drawn
        /// since the last.
        fn bindPicture(self: *Pass, texture: rhi.Texture, sampler: rhi.Sampler) !void {
            const r = self.renderer;
            const compiled = self.bound.?.compiled;
            if (compiled.texture_slot) |slot| try self.list.setTexture(slot, texture, sampler);
            const slot = compiled.screen_slot orelse return;
            const screen = r.screen orelse return self.list.setTexture(slot, r.white, r.white_sampler);
            const from = switch (self.target) {
                .texture => |held| held,
                // A surface cannot be read; a frame that reads it is drawn
                // into a texture instead - see `App.drawLayers`.
                else => return self.list.setTexture(slot, r.white, r.white_sampler),
            };
            if (self.copy == null or self.drew) {
                try self.end();
                self.copy = try screen.copyOf(from, @intFromFloat(self.width), @intFromFloat(self.height), r.white_sampler);
                self.drew = false;
                try self.begin(null);
                // `begin` bound the shader again; the picture goes back too.
                if (compiled.texture_slot) |picture_slot| try self.list.setTexture(picture_slot, texture, sampler);
            }
            try self.list.setTexture(slot, self.copy.?, r.white_sampler);
        }
    };

    /// Walk the world and turn every visible sprite into an instance: shown
    /// as its `Appearance` and everything above it say - hidden, its colour
    /// multiplied, its layer raised - and sorted for a frame that is `lit`
    /// or not.
    fn gather(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        tile_sets: *tileset.TileSets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
        lit: bool,
    ) !void {
        const bounds = view.bounds();
        self.items.clearRetainingCapacity();
        self.culled = 0;
        self.tile_chunks_drawn = 0;
        self.tile_chunks_culled = 0;

        var it = try Drawable.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const sprites = chunk.slice(Sprite);
            const has: Has = .of(chunk);

            for (transforms, sprites, chunk.entities, 0..) |local, sprite, entity, row| {
                if (!sprite.visible or sprite.tint.a <= 0) continue;
                const looks = has.looks(gpa, world, inherited, entity, row);
                const tint = looks.tint(sprite.tint);
                if (!looks.visible or tint.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                const picture = if (has.view_texture) (self.pictureOf(world, entity, sprite.texture, view) orelse continue) else sprite.texture;

                // Interpolated, then carried through whatever it hangs from.
                // What cannot be placed - its parent died this frame, or its
                // chain is a cycle - is not drawn.
                const transform = has.placed(world, snapshots, entity, row, local, alpha) orelse continue;

                // A handle that no longer resolves draws as the white texel:
                // a coloured rectangle is a bug somebody notices.
                const texture = assets.get(picture) orelse
                    assets.get(assets.white) orelse continue;
                // A picture drawn into on a backend that counts rows from
                // the bottom is shown turned over.
                const region = if (texture.upside_down) sprite.shownRegion().flippedY() else sprite.shownRegion();

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
                const drawn_with: DrawnWith = if (has.material) try self.materialOf(gpa, world, entity) else .{};

                try self.items.append(gpa, .{
                    .key = sortKey(looks.layer(sprite.layer), picture),
                    .order = sprite.order,
                    .texture = texture.gpu,
                    .sampler = assets.samplerFor(texture.filter, texture.wrap),
                    .blend = .of(sprite.blend),
                    .shader = drawn_with.shader,
                    .params = drawn_with.params,
                    .unshaded = looks.unshaded,
                    .instance = .quad(transform.x, transform.y, drawn_width, drawn_height, sprite.pivot_x, sprite.pivot_y, c, s, .{ tint.r, tint.g, tint.b, tint.a }, .{ region.u0, region.v0, region.u1, region.v1 }),
                });
            }
        }

        try self.gatherTiles(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view);
        try self.gatherParticles(gpa, world, assets, snapshots, inherited, alpha, view);
        try self.gatherWords(gpa, world, assets, snapshots, inherited, alpha, view);

        try self.sortItems(gpa, lit);
    }

    /// The items in the order they are drawn in: see `Item.rank`.
    fn sortItems(self: *Renderer, gpa: Allocator, lit: bool) !void {
        const items = self.items.items;
        try self.sort_keys.resize(gpa, items.len);
        for (items, self.sort_keys.items, 0..) |item, *rank, at| rank.* = .{ .key = item.rank(lit), .at = @intCast(at) };
        // A world that does not change its layers is found in order again.
        if (std.sort.isSorted(Ranked, self.sort_keys.items, {}, Ranked.before)) return;
        try self.sort_room.resize(gpa, items.len);
        radixSort(self.sort_keys.items, self.sort_room.items);
        try self.sorted.resize(gpa, items.len);
        for (self.sort_keys.items, self.sorted.items) |rank, *to| to.* = items[rank.at];
        std.mem.swap(std.ArrayList(Item), &self.items, &self.sorted);
    }

    /// Every emitter's living particles, one instance each, among the
    /// sprites of its layer: the oldest drawn first, or the newest, as it
    /// says. See `particles.zig`.
    fn gatherParticles(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const table = self.particles orelse return;
        const bounds = view.bounds();
        var it = try Emitters.over(world);
        while (it.next()) |chunk| {
            for (chunk.slice(Particles2D), chunk.entities) |*settings, entity| {
                const emitter = table.get(entity) orelse continue;
                const looks = inherited.of(gpa, world, entity);
                if (!looks.visible or looks.modulate.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                // Moved with its emitter, or where they were let go of.
                const placed: Transform2D = if (world.get(entity, Transform2D)) |local|
                    hierarchy.resolve(world, snapshots, entity, local.*, alpha) orelse continue
                else
                    .{};
                // No picture of its own, or one that no longer resolves: the
                // soft dot.
                const own = if (settings.texture.isNone() or assets.get(settings.texture) == null) assets.glow else settings.texture;
                const picture = assets.get(own) orelse continue;
                const across: u32 = @max(settings.frames_across, 1);
                const down: u32 = @max(settings.frames_down, 1);
                const size: [2]f32 = if (own.eql(assets.glow))
                    .{ dot_size, dot_size }
                else
                    .{ @as(f32, @floatFromInt(picture.width)) / @as(f32, @floatFromInt(across)), @as(f32, @floatFromInt(picture.height)) / @as(f32, @floatFromInt(down)) };
                const drawn_with = try self.materialOf(gpa, world, entity);
                const key = sortKey(looks.layer(settings.layer), own);
                const sampler = assets.samplerFor(picture.filter, picture.wrap);

                self.ranks.clearRetainingCapacity();
                for (emitter.particles.items, 0..) |particle, index| {
                    if (particle.alive) try self.ranks.append(gpa, @intCast(index));
                }
                const Age = struct {
                    particles: []const Particle,
                    newest_first: bool,

                    fn before(by: @This(), a: u32, b: u32) bool {
                        const age_a = by.particles[a].age;
                        const age_b = by.particles[b].age;
                        if (age_a != age_b) return (age_a < age_b) == by.newest_first;
                        return a < b;
                    }
                };
                std.sort.pdq(u32, self.ranks.items, Age{ .particles = emitter.particles.items, .newest_first = settings.draw_order == .newest_first }, Age.before);

                for (self.ranks.items) |index| {
                    const particle = emitter.particles.items[index];
                    const shown = particle.shown(settings, across * down);
                    const tint = looks.tint(shown.color);
                    if (tint.a <= 0) continue;
                    var at: Transform2D = .{ .x = particle.position.x, .y = particle.position.y, .rotation = particle.rotation, .scale_x = shown.scale, .scale_y = shown.scale };
                    if (settings.local_coords) {
                        const moved = placed.apply(at.x, at.y);
                        at = .{ .x = moved.x, .y = moved.y, .rotation = at.rotation + placed.rotation, .scale_x = shown.scale * placed.scale_x, .scale_y = shown.scale * placed.scale_y };
                    }
                    const width = size[0] * at.scale_x;
                    const height = size[1] * at.scale_y;
                    if (!bounds.admits(at.x, at.y, spriteRadius(width, height))) {
                        self.culled += 1;
                        continue;
                    }
                    const column: f32 = @floatFromInt(shown.frame % across);
                    const row: f32 = @floatFromInt(shown.frame / across);
                    const cells_across: f32 = @floatFromInt(across);
                    const cells_down: f32 = @floatFromInt(down);
                    var region: components.Region = .{ .u0 = column / cells_across, .v0 = row / cells_down, .u1 = (column + 1) / cells_across, .v1 = (row + 1) / cells_down };
                    if (picture.upside_down) region = region.flippedY();
                    try self.items.append(gpa, .{
                        .key = key,
                        .order = settings.order,
                        .texture = picture.gpu,
                        .sampler = sampler,
                        .blend = .of(settings.blend),
                        .shader = drawn_with.shader,
                        .params = drawn_with.params,
                        .unshaded = looks.unshaded,
                        .instance = .quad(at.x, at.y, width, height, 0.5, 0.5, @cos(at.rotation), @sin(at.rotation), .{ tint.r, tint.g, tint.b, tint.a }, .{ region.u0, region.v0, region.u1, region.v1 }),
                    });
                }
            }
        }
    }

    /// The labels, and the drawings, which may hold words too. A font whose
    /// atlas fills on the way has it emptied, and they are laid out again;
    /// filled again, the atlas grows. What an atlas as big as it goes still
    /// cannot hold is left out, and that is said once.
    fn gatherWords(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const from = self.items.items.len;
        const culled_from = self.culled;
        self.emptied.clearRetainingCapacity();
        defer self.fit_only = false;
        self.text_clock += 1;
        defer self.forgetLaidOut(gpa);
        while (true) {
            self.layWords(gpa, world, assets, snapshots, inherited, alpha, view) catch |err| switch (err) {
                error.AtlasFull => {
                    self.items.shrinkRetainingCapacity(from);
                    self.culled = culled_from;
                    const face = self.full.?;
                    if (std.mem.indexOfScalar(*Assets.Font, self.emptied.items, face) == null) {
                        face.atlas.clear();
                        try self.emptied.append(gpa, face);
                    } else if (!try assets.growAtlas(face)) {
                        if (!self.said_full) std.log.scoped(.fluxion_engine).warn("the words of a frame do not fit a font's atlas of {d} pixels a side: the letters that do not fit are left out", .{face.atlas.width});
                        self.said_full = true;
                        self.fit_only = true;
                    }
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    /// Let go of the layouts of labels not drawn for a while: gone, hidden,
    /// or seen by no camera.
    fn forgetLaidOut(self: *Renderer, gpa: Allocator) void {
        const every = 64;
        if (self.text_clock % every != 0) return;
        var i = self.laid.count();
        while (i > 0) {
            i -= 1;
            const held = &self.laid.values()[i];
            if (held.used + every >= self.text_clock) continue;
            held.glyphs.deinit(gpa);
            self.laid.swapRemoveAt(i);
        }
    }

    fn layWords(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        try self.gatherText(gpa, world, assets, snapshots, inherited, alpha, view);
        try self.gatherDrawings(gpa, world, assets, snapshots, inherited, alpha, view);
    }

    /// The texture a sprite shows: a render view's picture, for one with a
    /// `ViewTexture`, or its own. Null for one showing the picture `view`
    /// draws, which cannot be read while it is drawn into.
    fn pictureOf(self: *const Renderer, world: *ecs.World, entity: ecs.Entity, own: Assets.TextureHandle, view: View) ?Assets.TextureHandle {
        const views = self.views orelse return own;
        if (world.get(entity, components.ViewTexture)) |held| {
            if (!view.render_view.isNone() and held.view.eql(view.render_view)) return null;
        }
        return views.shown(world, entity, own);
    }

    /// The shader an entity's `Material` names - when it compiled - and the
    /// set of numbers it gives it; none for a plain picture.
    fn materialOf(self: *Renderer, gpa: Allocator, world: *ecs.World, entity: ecs.Entity) !DrawnWith {
        const held = world.get(entity, Material) orelse return .{};
        const table = self.shaders orelse return .{};
        const compiled = table.compiledOf(held.shader) orelse return .{};
        return .{ .shader = held.shader, .params = try self.paramSetOf(gpa, compiled, entity) };
    }

    /// Every tile of every chunk near the camera, as one instance each: a
    /// chunk is culled as a whole, and the tiles of one sheet are one draw.
    ///
    /// A cell that is turned - `Cell.transpose` - is drawn as a quad turned
    /// a quarter about its middle, because the shader reads a corner's `u`
    /// from the quad's own `x` and no region can swap the two. See
    /// `tilemap.drawn`.
    fn gatherTiles(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        tile_sets: *tileset.TileSets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const bounds = view.bounds();
        var it = try TileChunks.over(world);
        while (it.next()) |chunk| {
            for (chunk.slice(tilemap.TileChunk)) |tiles| {
                const map = world.get(tiles.map, tilemap.TileMap) orelse continue;
                if (!map.visible or map.tint.a <= 0) continue;
                // A chunk is shown as its map is.
                const looks = inherited.of(gpa, world, tiles.map);
                const tint = looks.tint(map.tint);
                if (!looks.visible or tint.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                const layer = looks.layer(map.layer);
                const local = world.get(tiles.map, Transform2D) orelse continue;
                const placed = hierarchy.resolve(world, snapshots, tiles.map, local.*, alpha) orelse continue;
                const set = tile_sets.get(map.tile_set);
                const tile_width: f32 = if (set) |held| @floatFromInt(held.tile_width) else tileset.default_tile_size;
                const tile_height: f32 = if (set) |held| @floatFromInt(held.tile_height) else tileset.default_tile_size;
                const chunk_width = tile_width * tilemap.chunk_side;
                const chunk_height = tile_height * tilemap.chunk_side;
                const chunk_left = @as(f32, @floatFromInt(tiles.x)) * chunk_width;
                const chunk_top = @as(f32, @floatFromInt(tiles.y)) * chunk_height;
                const chunk_center = placed.apply(chunk_left + chunk_width / 2, chunk_top + chunk_height / 2);
                const reach = spriteRadius(chunk_width * @abs(placed.scale_x), chunk_height * @abs(placed.scale_y));
                if (!bounds.admits(chunk_center.x, chunk_center.y, reach)) {
                    self.tile_chunks_culled += 1;
                    continue;
                }
                self.tile_chunks_drawn += 1;

                const turn = std.math.pi / 2.0;
                for (tiles.cells, 0..) |cell, index| {
                    if (cell.isEmpty()) continue;
                    const x: f32 = @floatFromInt(index % tilemap.chunk_side);
                    const y: f32 = @floatFromInt(index / tilemap.chunk_side);

                    // A map with no tile set draws white squares its tint
                    // colours: a level blocked out before its art exists.
                    const picture: tileset.TilePicture = if (set) |held|
                        held.pictureOf(assets, cell)
                    else
                        .{ .texture = assets.white, .region = .full };
                    const texture = assets.get(picture.texture) orelse assets.get(assets.white) orelse continue;
                    const how = tilemap.drawn(cell, picture.region);

                    // The middle of the cell, so a turned quad turns about
                    // itself rather than about a corner.
                    const at = placed.apply(chunk_left + (x + 0.5) * tile_width, chunk_top + (y + 0.5) * tile_height);
                    const rotation = if (how.turned) placed.rotation - turn else placed.rotation;
                    const across = if (how.turned) tile_height * placed.scale_y else tile_width * placed.scale_x;
                    const down = if (how.turned) tile_width * placed.scale_x else tile_height * placed.scale_y;
                    try self.items.append(gpa, .{
                        .key = sortKey(layer, picture.texture),
                        .order = map.order,
                        .texture = texture.gpu,
                        .sampler = assets.samplerFor(texture.filter, texture.wrap),
                        .blend = .alpha,
                        .unshaded = looks.unshaded,
                        .instance = .quad(at.x, at.y, across, down, 0.5, 0.5, @cos(rotation), @sin(rotation), .{ tint.r, tint.g, tint.b, tint.a }, .{ how.region.u0, how.region.v0, how.region.u1, how.region.v1 }),
                    });
                }
            }
        }
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
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const bounds = view.bounds();
        var it = try Labels.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const labels = chunk.slice(Text2D);
            const has: Has = .of(chunk);

            for (transforms, labels, chunk.entities, 0..) |local, label, entity, row| {
                const run = (self.texts orelse return).get(entity, text_key);
                if (!label.visible or run.len == 0 or label.color.a <= 0) continue;
                const looks = has.looks(gpa, world, inherited, entity, row);
                if (!looks.visible or looks.modulate.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                // A scene's words are UTF-8 by the time they are read, but a
                // label's bytes can be written by hand, and the walk through
                // its characters below takes them on trust.
                if (!std.unicode.utf8ValidateSlice(run)) continue;

                // Not drawn when it cannot be placed, as with a sprite.
                const transform = has.placed(world, snapshots, entity, row, local, alpha) orelse continue;
                const face = assets.fontOf(label.font) orelse continue;

                var shown = label;
                shown.color = looks.tint(label.color);
                shown.layer = looks.layer(label.layer);
                try self.layOut(gpa, assets, face, shown, run, transform, bounds, null, entity, looks.unshaded);
            }
        }
    }

    /// Put a quad where each of one label's letters goes: laid out again
    /// only when what it is laid out from changed. See `Laid`.
    fn layOut(
        self: *Renderer,
        gpa: Allocator,
        assets: *Assets,
        face: *Assets.Font,
        label: Text2D,
        run: []const u8,
        transform: Transform2D,
        bounds: Bounds,
        /// A drawing's key, so its words stay among its shapes in the order
        /// they were drawn; null for a label's own.
        drawn_key: ?u64,
        /// The label's entity, whose layout is kept; none for a drawing's
        /// words.
        kept_for: ecs.Entity,
        unshaded: bool,
    ) !void {
        const size = GlyphSize.of(label.size);
        const scaled = face.face.at(@floatFromInt(size.pixels));
        const line_height = scaled.lineHeight() * label.line_spacing * size.stretch;

        const laid = if (kept_for.isNone()) &self.loose else laid: {
            const found = try self.laid.getOrPut(gpa, kept_for.toInt());
            if (!found.found_existing) found.value_ptr.* = .{};
            break :laid found.value_ptr;
        };
        laid.used = self.text_clock;
        const hash = layoutHash(face, label, run);
        if (laid.hash != hash or kept_for.isNone()) {
            var widths: [max_measured_lines]f32 = undefined;
            const measured = measureLines(&face.face, scaled, run, &widths);
            laid.hash = hash;
            laid.width = measured.width * size.stretch;
            laid.height = measured.lines * line_height;
            laid.whole = false;
        }

        // The whole label against the camera, boxed generously: one test, not
        // one per letter. Letters off screen are not drawn into the atlas.
        const reach = spriteRadius(laid.width * @abs(transform.scale_x), laid.height * @abs(transform.scale_y));
        if (!bounds.admits(transform.x, transform.y, reach)) {
            self.culled += 1;
            return;
        }
        if (!laid.whole) try self.layLetters(gpa, face, label, run, scaled, line_height, size, laid);

        const c = @cos(transform.rotation);
        const sn = @sin(transform.rotation);
        const key = drawn_key orelse sortKeyOf(label.layer, if (label.font.isNone())
            assets.default_font.index
        else
            label.font.index);
        // Linear: a zoomed camera draws glyphs at sizes they were not
        // rasterised at.
        const sampler = assets.samplerFor(.linear, .clamp_to_edge);
        try self.items.ensureUnusedCapacity(gpa, laid.glyphs.items.len);
        for (laid.glyphs.items) |glyph| {
            const placed = transform.apply(glyph.x, glyph.y);
            self.items.appendAssumeCapacity(.{
                .key = key,
                .order = label.order,
                .texture = face.texture,
                .sampler = sampler,
                .blend = .alpha,
                .unshaded = unshaded,
                // The pivot is the corner the pen worked out.
                .instance = .quad(
                    placed.x,
                    placed.y,
                    glyph.width * transform.scale_x,
                    glyph.height * transform.scale_y,
                    0,
                    0,
                    c,
                    sn,
                    .{ label.color.r, label.color.g, label.color.b, label.color.a },
                    glyph.uv,
                ),
            });
        }
    }

    /// Walk one label's characters, and find where each goes in its own
    /// space and in the atlas, drawing into the atlas what is not there yet.
    fn layLetters(
        self: *Renderer,
        gpa: Allocator,
        face: *Assets.Font,
        label: Text2D,
        run: []const u8,
        scaled: typeface.Scaled,
        line_height: f32,
        size: GlyphSize,
        laid: *Laid,
    ) !void {
        const stretch = size.stretch;
        laid.glyphs.clearRetainingCapacity();
        var line_start: usize = 0;
        var line_index: usize = 0;

        while (line_start <= run.len) {
            const end = std.mem.indexOfScalarPos(u8, run, line_start, '\n') orelse run.len;
            const line = run[line_start..end];

            // The transform is the top left of the first line, so the first
            // baseline is one ascent below it.
            const baseline = scaled.ascent() * stretch + @as(f32, @floatFromInt(line_index)) * line_height;
            const width = if (label.alignment == .left) 0 else lineWidth(&face.face, scaled, line);
            var pen: f32 = switch (label.alignment) {
                .left => 0,
                .center => -width * stretch / 2,
                .right => -width * stretch,
            };

            var previous_glyph: ?u16 = null;
            var characters = std.unicode.Utf8View.initUnchecked(line).iterator();
            while (characters.nextCodepoint()) |codepoint| {
                const index = face.face.glyphFor(codepoint);

                if (previous_glyph) |left| {
                    const units = face.face.kern(left, index) catch 0;
                    pen += @as(f32, @floatFromInt(units)) * scaled.scale * stretch;
                }
                previous_glyph = index;

                const entry = face.atlas.glyph(&face.face, index, size.pixels) catch |err| switch (err) {
                    // Room is made and the frame's words laid out again - but
                    // for the last pass of a frame that has none to make,
                    // which leaves the rest of this label out.
                    error.AtlasFull => {
                        if (self.fit_only) return;
                        self.full = face;
                        return error.AtlasFull;
                    },
                    else => return err,
                };
                defer pen += entry.advance * stretch;

                if (entry.width == 0) continue;

                // The glyph's top left, in the label's space.
                try laid.glyphs.append(gpa, .{
                    .x = pen + entry.left * stretch,
                    .y = baseline - entry.top * stretch,
                    .width = entry.width * stretch,
                    .height = entry.height * stretch,
                    .uv = .{ entry.u0, entry.v0, entry.u1, entry.v1 },
                });
            }

            if (end == run.len) break;
            line_start = end + 1;
            line_index += 1;
        }
        laid.whole = true;
    }

    /// What each `Drawing2D` holds, its shapes put in the world: at its layer
    /// among the sprites, in the order they were drawn. See `drawing.zig`.
    fn gatherDrawings(
        self: *Renderer,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const table = self.drawings orelse return;
        const bounds = view.bounds();
        const white = assets.get(assets.white) orelse return;
        var it = try Drawings2D.over(world);
        while (it.next()) |chunk| {
            for (chunk.slice(Drawing2D), chunk.entities) |held, entity| {
                if (!held.visible) continue;
                const picture = table.get(entity) orelse continue;
                if (picture.isEmpty()) continue;
                const looks = inherited.of(gpa, world, entity);
                if (!looks.visible or looks.modulate.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                // In its entity's space, or the world's for one with none.
                const placed: Transform2D = if (world.get(entity, Transform2D)) |local|
                    hierarchy.resolve(world, snapshots, entity, local.*, alpha) orelse continue
                else
                    .{};
                const middle = placed.apply((picture.low.x + picture.high.x) / 2, (picture.low.y + picture.high.y) / 2);
                const reach = spriteRadius((picture.high.x - picture.low.x) * placed.scale_x, (picture.high.y - picture.low.y) * placed.scale_y);
                if (!bounds.admits(middle.x, middle.y, reach)) {
                    self.culled += 1;
                    continue;
                }
                const drawn_with = try self.materialOf(gpa, world, entity);
                var pen: Pen = .{
                    .renderer = self,
                    .gpa = gpa,
                    .placed = placed,
                    .looks = looks,
                    // One key for the whole drawing, apart from the
                    // sprites': its shapes are sorted by the order they
                    // were drawn in, whatever their pictures.
                    .key = sortKeyOf(looks.layer(held.layer), drawn_key_base | entity.index),
                    .order = held.order,
                    .white = white.gpu,
                    .white_sampler = assets.samplerFor(white.filter, white.wrap),
                    .shader = drawn_with.shader,
                    .params = drawn_with.params,
                };
                for (picture.shapes.items) |shape| try pen.draw(assets, picture, shape, bounds);
            }
        }
    }

    /// Past every texture's index: a drawing's key never falls among the
    /// sprites' of one texture.
    const drawn_key_base: u32 = 0x8000_0000;

    /// Puts one drawing's shapes into the queue, in the world.
    const Pen = struct {
        renderer: *Renderer,
        gpa: Allocator,
        placed: Transform2D,
        looks: @import("../scene/inherited.zig").Resolved,
        key: u64,
        order: f32,
        white: rhi.Texture,
        white_sampler: rhi.Sampler,
        shader: ShaderHandle,
        params: u32,

        fn at(self: *const Pen, p: math.Vec2) math.Vec2 {
            const moved = self.placed.apply(p.x, p.y);
            return .init(moved.x, moved.y);
        }

        /// A width in the entity's space as it is drawn: scaled with it.
        fn widthOf(self: *const Pen, width: f32) f32 {
            return @max(width, 0) * (@abs(self.placed.scale_x) + @abs(self.placed.scale_y)) / 2;
        }

        fn colorOf(self: *const Pen, color: Color) [4]f32 {
            const shown = self.looks.tint(color);
            return .{ shown.r, shown.g, shown.b, shown.a };
        }

        fn put(self: *Pen, instance: Instance, texture: rhi.Texture, sampler: rhi.Sampler) !void {
            try self.renderer.items.append(self.gpa, .{
                .key = self.key,
                .order = self.order,
                .texture = texture,
                .sampler = sampler,
                .blend = .alpha,
                .shader = self.shader,
                .params = self.params,
                .unshaded = self.looks.unshaded,
                .instance = instance,
            });
        }

        fn triangle(self: *Pen, a: math.Vec2, b: math.Vec2, c: math.Vec2, tint: [4]f32) !void {
            try self.put(.triangle(a, b, c, tint), self.white, self.white_sampler);
        }

        /// A straight line `width` wide between two points of the world.
        fn line(self: *Pen, from: math.Vec2, to: math.Vec2, width: f32, tint: [4]f32) !void {
            const along = to.sub(from);
            const length = along.len();
            if (length == 0 or width <= 0) return;
            const side = along.perp().scale(width / (2 * length));
            try self.put(.parallelogram(from.sub(side), along, side.scale(2), tint, .{ 0, 0, 1, 1 }), self.white, self.white_sampler);
        }

        /// A box of the entity's space, as it lands in the world.
        fn box(self: *Pen, corner: math.Vec2, size: math.Vec2, tint: [4]f32, texture: rhi.Texture, sampler: rhi.Sampler, uv: [4]f32) !void {
            const origin = self.at(corner);
            const across = self.at(corner.add(.init(size.x, 0))).sub(origin);
            const down = self.at(corner.add(.init(0, size.y))).sub(origin);
            try self.put(.parallelogram(origin, across, down, tint, uv), texture, sampler);
        }

        /// Points round a circle of the entity's space, in the world.
        fn round(self: *Pen, center: math.Vec2, radius: f32, start: f32, turn: f32, out: []math.Vec2) []math.Vec2 {
            const scale = (@abs(self.placed.scale_x) + @abs(self.placed.scale_y)) / 2;
            const pieces = @min(segmentsOf(radius * scale, turn), @as(u32, @intCast(out.len - 1)));
            for (0..pieces + 1) |i| {
                const angle = start + turn * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pieces));
                out[i] = self.at(center.add(math.Vec2.init(@cos(angle), @sin(angle)).scale(radius)));
            }
            return out[0 .. pieces + 1];
        }

        fn draw(self: *Pen, assets: *Assets, picture: *const Picture, shape: Shape, bounds: Bounds) !void {
            switch (shape) {
                .line => |held| try self.line(self.at(held.from), self.at(held.to), self.widthOf(held.width), self.colorOf(held.color)),
                .rect => |held| {
                    const tint = self.colorOf(held.color);
                    if (held.filled) return self.box(held.at, held.size, tint, self.white, self.white_sampler, .{ 0, 0, 1, 1 });
                    const corners = [4]math.Vec2{
                        self.at(held.at),
                        self.at(held.at.add(.init(held.size.x, 0))),
                        self.at(held.at.add(held.size)),
                        self.at(held.at.add(.init(0, held.size.y))),
                    };
                    const width = self.widthOf(held.width);
                    for (corners, 0..) |from, i| try self.line(from, corners[(i + 1) % 4], width, tint);
                },
                .circle => |held| {
                    var buffer: [97]math.Vec2 = undefined;
                    const points = self.round(held.center, held.radius, 0, std.math.tau, &buffer);
                    const tint = self.colorOf(held.color);
                    if (held.filled) {
                        const middle = self.at(held.center);
                        for (points[0 .. points.len - 1], points[1..]) |a, b| try self.triangle(middle, a, b, tint);
                    } else {
                        const width = self.widthOf(held.width);
                        for (points[0 .. points.len - 1], points[1..]) |a, b| try self.line(a, b, width, tint);
                    }
                },
                .arc => |held| {
                    var buffer: [97]math.Vec2 = undefined;
                    const points = self.round(held.center, held.radius, held.start, held.end - held.start, &buffer);
                    const tint = self.colorOf(held.color);
                    const width = self.widthOf(held.width);
                    for (points[0 .. points.len - 1], points[1..]) |a, b| try self.line(a, b, width, tint);
                },
                .polyline => |held| {
                    const points = picture.points.items[held.first..][0..held.count];
                    if (points.len < 2) return;
                    const tint = self.colorOf(held.color);
                    const width = self.widthOf(held.width);
                    for (points[0 .. points.len - 1], points[1..]) |a, b| try self.line(self.at(a), self.at(b), width, tint);
                },
                .polygon => |held| {
                    const tint = self.colorOf(held.color);
                    const corners = picture.corners.items[held.first_corner..][0..held.corners];
                    var i: usize = 0;
                    while (i + 2 < corners.len) : (i += 3) {
                        const points = picture.points.items;
                        try self.triangle(self.at(points[corners[i]]), self.at(points[corners[i + 1]]), self.at(points[corners[i + 2]]), tint);
                    }
                },
                .texture => |held| {
                    const texture = assets.get(held.texture) orelse return;
                    const size: math.Vec2 = if (held.size.x == 0 and held.size.y == 0)
                        .init(@floatFromInt(texture.width), @floatFromInt(texture.height))
                    else
                        held.size;
                    const uv: [4]f32 = if (texture.upside_down) .{ 0, 1, 1, 0 } else .{ 0, 0, 1, 1 };
                    try self.box(held.at, size, self.colorOf(held.color), texture.gpu, assets.samplerFor(texture.filter, texture.wrap), uv);
                },
                .text => |held| {
                    const run = picture.words.items[held.first..][0..held.len];
                    if (run.len == 0 or !std.unicode.utf8ValidateSlice(run)) return;
                    const face = assets.fontOf(held.font) orelse return;
                    var placed = self.placed;
                    const start = self.at(held.at);
                    placed.x = start.x;
                    placed.y = start.y;
                    const shown = self.looks.tint(held.color);
                    const label: Text2D = .{ .font = held.font, .size = held.size, .color = shown, .order = self.order };
                    try self.renderer.layOut(self.gpa, assets, face, label, run, placed, bounds, self.key, .none, self.looks.unshaded);
                },
            }
        }
    };

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
fn measure(face: *const typeface.Font, scaled: typeface.Scaled, run: []const u8) Measured {
    return measureLines(face, scaled, run, &.{});
}

const Measured = struct { width: f32, lines: f32 };

/// How many lines' widths a label's layout keeps from measuring it, for
/// their alignment; one with more measures the rest again.
const max_measured_lines = 32;

/// One label laid out: see `Renderer.laid`.
const Laid = struct {
    /// What it was laid out from. See `layoutHash`; nought for nothing.
    hash: u64 = 0,
    /// The last `Renderer.text_clock` it was drawn at.
    used: u64 = 0,
    /// How far it reaches in its own space, for the camera's test.
    width: f32 = 0,
    height: f32 = 0,
    /// Whether `glyphs` holds every letter: not before the label was first
    /// on screen, nor when the atlas had no room for them all.
    whole: bool = false,
    glyphs: std.ArrayList(LaidGlyph) = .empty,
};

/// A letter of a label, in the label's space: its top left, its size, and
/// where it is in the atlas.
const LaidGlyph = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    uv: [4]f32,
};

/// What a label is laid out from: its words, its size and lines, and the
/// atlas its letters are in, which is new each time it is emptied or grows
/// and so tells its font too.
fn layoutHash(face: *const Assets.Font, label: Text2D, run: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(face.atlas.generation);
    hasher.update(run);
    hasher.update(std.mem.asBytes(&label.size));
    hasher.update(std.mem.asBytes(&label.line_spacing));
    hasher.update(std.mem.asBytes(&label.alignment));
    return hasher.final() | 1;
}

/// `measure`, with the width of each of the first lines put in `widths`.
fn measureLines(face: *const typeface.Font, scaled: typeface.Scaled, run: []const u8, widths: []f32) Measured {
    var widest: f32 = 0;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, run, '\n');
    while (it.next()) |line| {
        const width = lineWidth(face, scaled, line);
        if (lines < widths.len) widths[lines] = width;
        widest = @max(widest, width);
        lines += 1;
    }
    return .{ .width = widest, .lines = @floatFromInt(lines) };
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

/// Where a label's four corners land in the world, round from the top left
/// of its first line: the box its lines are laid out in - the widest line
/// across, shifted by the alignment, and the lines' heights down - turned
/// and scaled as the transform says. The laid-out box, not the ink: a line
/// of spaces is as tall as any other.
///
/// Null for a label with nothing drawn: no words, a size that measures
/// nothing, or bytes that are not UTF-8. What an editor outlines, frames and
/// tests a click against, as `cornersOf` is for a sprite.
pub fn labelCornersOf(label: Text2D, run: []const u8, placed: Transform2D, face: *Assets.Font) ?[4]math.Vec2 {
    if (run.len == 0 or !std.unicode.utf8ValidateSlice(run)) return null;

    // The size the renderer lays it out at, and the lines it lays out.
    const size = GlyphSize.of(label.size);
    const scaled = face.face.at(@floatFromInt(size.pixels));
    const line_height = scaled.lineHeight() * label.line_spacing * size.stretch;
    const measured = measure(&face.face, scaled, run);
    const across = measured.width * size.stretch;
    if (!(across > 0) or !(measured.lines > 0) or !std.math.isFinite(line_height)) return null;

    // The transform is the top left of the first line; each line is moved
    // by the alignment, and so is the box around them.
    const left: f32 = switch (label.alignment) {
        .left => 0,
        .center => -across / 2,
        .right => -across,
    };
    const width = across * placed.scale_x;
    const height = measured.lines * line_height * placed.scale_y;
    const x0 = left * placed.scale_x;
    const c = @cos(placed.rotation);
    const s = @sin(placed.rotation);
    var out: [4]math.Vec2 = undefined;
    for (quad_round, &out) |corner, *point| {
        const x = x0 + corner[0] * width;
        const y = corner[1] * height;
        point.* = .init(placed.x + x * c - y * s, placed.y + x * s + y * c);
    }
    return out;
}

/// The size a label's glyphs are drawn into its font's atlas at: its own in
/// whole pixels, as the atlas is keyed - a size read from a file is not
/// always one a hand would give, and NaN is the smallest - and at most
/// `Assets.max_glyph`, scaled up past it by `stretch`, which is what one of
/// the glyphs' pixels is in the label's units.
const GlyphSize = struct {
    pixels: u16,
    stretch: f32,

    fn of(size: f32) GlyphSize {
        const biggest: f32 = @floatFromInt(Assets.max_glyph);
        const rounded = @round(size);
        if (rounded >= 1 and rounded <= biggest) return .{ .pixels = @intFromFloat(rounded), .stretch = 1 };
        if (rounded > biggest) return .{ .pixels = Assets.max_glyph, .stretch = @min(size, 65536) / biggest };
        return .{ .pixels = 1, .stretch = 1 };
    }
};

/// The unit square's corners in order round it, rather than in the strip's
/// order.
const quad_round = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

/// How big a sprite is, falling back to the size of its own artwork.
pub fn spriteSize(sprite: Sprite, texture: *const Assets.Texture) struct { width: f32, height: f32 } {
    const region_width = @abs(sprite.region.u1 - sprite.region.u0) * @as(f32, @floatFromInt(texture.width));
    const region_height = @abs(sprite.region.v1 - sprite.region.v0) * @as(f32, @floatFromInt(texture.height));
    return .{
        .width = if (sprite.width != 0) sprite.width else region_width,
        .height = if (sprite.height != 0) sprite.height else region_height,
    };
}

/// A sprite's size, and where its middle is from its entity's origin:
/// `{ width, height, x, y }`, before its transform. What a collider or a
/// light occluder with no size of its own takes.
pub fn spriteBox(sprite: Sprite, texture: *const Assets.Texture) [4]f32 {
    const size = spriteSize(sprite, texture);
    return .{ size.width, size.height, (0.5 - sprite.pivot_x) * size.width, (0.5 - sprite.pivot_y) * size.height };
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

test "within a layer, order comes first, then blend, then texture, and where it was found breaks the tie" {
    const first: Assets.TextureHandle = .{ .index = 1, .generation = 1 };
    const second: Assets.TextureHandle = .{ .index = 2, .generation = 1 };
    const blank: Instance = .{ .place = @splat(0), .shape = @splat(0), .tint = @splat(0), .uv_rect = @splat(0) };

    const item = struct {
        fn make(layer: i16, order: f32, texture: Assets.TextureHandle) Item {
            return .{
                .key = sortKey(layer, texture),
                .order = order,
                .instance = blank,
                .texture = .none,
                .sampler = .none,
                .blend = .alpha,
            };
        }

        fn glowing(layer: i16, order: f32, texture: Assets.TextureHandle) Item {
            var out = make(layer, order, texture);
            out.blend = .additive;
            return out;
        }

        fn before(lit: bool, a: Item, b: Item) bool {
            return a.rank(lit) < b.rank(lit);
        }
    };

    // A lower order draws first even on a later texture, and a negative one
    // before nought.
    try testing.expect(item.before(false, item.make(0, 1, second), item.make(0, 2, first)));
    try testing.expect(item.before(false, item.make(0, -2, second), item.make(0, -1, first)));
    try testing.expect(item.before(false, item.make(0, -0.5, second), item.make(0, 0, first)));
    try testing.expectEqual(item.make(0, 0, first).rank(false), item.make(0, -0.0, first).rank(false));
    // The same order falls back to the texture, which keeps the batching.
    try testing.expect(item.before(false, item.make(0, 0, first), item.make(0, 0, second)));
    // And the layer still wins over all of it.
    try testing.expect(item.before(false, item.make(-1, 100, second), item.make(0, 0, first)));

    try testing.expect(item.before(false, item.make(0, 0, second), item.glowing(0, 0, first)));
    try testing.expect(item.before(false, item.glowing(0, -1, first), item.make(0, 0, second)));

    // In a lit frame what is unshaded comes after all that is lit, whatever
    // its layer; in one that is not, the layer decides.
    var sign = item.make(-5, 0, first);
    sign.unshaded = true;
    try testing.expect(item.before(true, item.make(3, 0, second), sign));
    try testing.expect(item.before(false, sign, item.make(3, 0, second)));

    // Everything equal: whichever was found first, however many there are.
    const a = Ranked{ .key = item.make(0, 0, first).rank(false), .at = 3 };
    const b = Ranked{ .key = a.key, .at = 4 };
    try testing.expect(Ranked.before({}, a, b));
    try testing.expect(!Ranked.before({}, b, a));
}

test "the sort puts keys in order and keeps the order of those alike" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var ranked: [500]Ranked = undefined;
    var room: [500]Ranked = undefined;
    for (&ranked, 0..) |*one, at| {
        // A few layers and textures, and an order: bytes far apart.
        const layer: u128 = random.uintLessThan(u8, 4);
        const texture: u128 = random.uintLessThan(u8, 3);
        one.* = .{ .key = (layer << 112) | (@as(u128, orderBits(@floatFromInt(random.intRangeAtMost(i8, -2, 2)))) << 80) | texture, .at = @intCast(at) };
    }
    var expected = ranked;
    std.sort.pdq(Ranked, &expected, {}, Ranked.before);
    radixSort(&ranked, &room);
    try testing.expectEqualSlices(Ranked, &expected, &ranked);
    // One alike throughout, and one of none, are left as they are.
    var same = [_]Ranked{ .{ .key = 5, .at = 0 }, .{ .key = 5, .at = 1 } };
    radixSort(&same, room[0..2]);
    try testing.expectEqual(@as(u32, 0), same[0].at);
    radixSort(ranked[0..0], room[0..0]);
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

    // The vertex stage's arithmetic, fed what `gather` gives it.
    const instance: Instance = .quad(placed.x, placed.y, 20 * placed.scale_x, 10 * placed.scale_y, sprite.pivot_x, sprite.pivot_y, @cos(placed.rotation), @sin(placed.rotation), @splat(1), .{ 0, 0, 1, 1 });
    for (quad_round, corners) |corner, got| {
        const want = instance.corner(corner[0], corner[1]);
        try testing.expectApproxEqAbs(want.x, got.x, 0.0001);
        try testing.expectApproxEqAbs(want.y, got.y, 0.0001);
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
