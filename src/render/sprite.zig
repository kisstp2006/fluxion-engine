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
const typeface = @import("fluxion_font");

const Assets = @import("../assets.zig");
const components = @import("../components.zig");
const hierarchy = @import("../hierarchy.zig");
const Inherited = @import("../inherited.zig").Inherited;
const tilemap = @import("../tilemap.zig");
const tileset = @import("../tileset.zig");
const view_mod = @import("view.zig");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Color = components.Color;
const Text2D = components.Text2D;
const texts_mod = @import("../texts.zig");
/// What a label says, among the app's texts.
const text_key = texts_mod.keyFor(Text2D, "text");
const View = view_mod.View;
const Bounds = view_mod.Bounds;

const shaders_mod = @import("../shaders.zig");
const material = shaders_mod.material;
const ShaderHandle = shaders_mod.ShaderHandle;
const Screen = @import("screen.zig").Screen;
const views_mod = @import("../views.zig");

const Drawable = ecs.Query(.{ Transform2D, Sprite });
const Labels = ecs.Query(.{ Transform2D, Text2D });
const TileChunks = ecs.Query(.{tilemap.TileChunk});

pub const Error = rhi.Error || Allocator.Error || error{ShaderFailed};

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
    /// Where in the walk it was found. The last tie-breaker, so equal sprites
    /// keep their order from frame to frame: the sort is not stable.
    sequence: u32,
    instance: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    blend: Sprite.Blend,
    /// The shader its `Material` names, or none for a plain picture.
    shader: ShaderHandle = .none,
    /// Which of this frame's sets of numbers its material gives, or
    /// `no_params`.
    params: u32 = no_params,

    fn before(_: void, a: Item, b: Item) bool {
        const layer_a = a.key >> 32;
        const layer_b = b.key >> 32;
        if (layer_a != layer_b) return layer_a < layer_b;
        if (a.order != b.order) return a.order < b.order;
        if (a.blend != b.blend) return @intFromEnum(a.blend) < @intFromEnum(b.blend);
        if (!a.shader.eql(b.shader)) return a.shader.index < b.shader.index;
        if (a.params != b.params) return a.params < b.params;
        if (a.key != b.key) return a.key < b.key;
        return a.sequence < b.sequence;
    }

    fn sharesDrawWith(self: Item, other: Item) bool {
        return self.blend == other.blend and
            self.shader.eql(other.shader) and
            self.params == other.params and
            std.meta.eql(self.texture, other.texture) and
            std.meta.eql(self.sampler, other.sampler);
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
    texts: ?*const texts_mod.Texts = null,
    /// The shaders a `Material` names, and the numbers each gives. Without
    /// them every sprite is a plain picture.
    shaders: ?*const shaders_mod.Shaders = null,
    params: ?*const shaders_mod.Params = null,
    /// Where what is drawn so far is copied for a shader that reads it. With
    /// none, such a shader reads a white picture.
    screen: ?*Screen = null,
    /// Seconds, as `TIME`.
    time: f32 = 0,
    /// The picture each `RenderView` draws, for what a `ViewTexture` shows.
    views: ?*const views_mod.Views = null,
    /// The render view being drawn, whose own picture is not drawn into it.
    drawing: ecs.Entity = .none,

    /// A picture, coloured: what a sprite with no material is drawn with.
    plain: material.Compiled,

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
        var plain = material.compile(gpa, device, material.plain, "sprites", &problems.writer) catch |err| {
            std.log.scoped(.fluxion_engine).err("sprite shader: {s}", .{problems.written()});
            return err;
        };
        errdefer plain.deinit(device);

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
        self.staging.deinit(gpa);
        self.param_sets.deinit(gpa);
        self.param_bytes.deinit(gpa);
        self.param_found.deinit(gpa);
        for (self.param_buffers.items) |held| self.device.destroyBuffer(held.buffer);
        self.param_buffers.deinit(gpa);
        self.plain.deinit(self.device);
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
        try self.gather(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view);

        // Gathering the text may have rasterised new letters, so the atlases
        // go up once, before anything samples them.
        try assets.flushFonts();

        try self.device.updateBuffer(self.frame, 0, std.mem.asBytes(&self.frameOf(view.matrix(self.device.clip()), view.width, view.height)));
        try self.uploadParams(gpa);

        if (self.items.items.len > 0) {
            try self.reserve(@intCast(self.items.items.len));
            // Laid out contiguously and uploaded in one call; see the module
            // comment.
            self.staging.clearRetainingCapacity();
            try self.staging.ensureTotalCapacity(gpa, self.items.items.len);
            for (self.items.items) |item| self.staging.appendAssumeCapacity(item.instance);
            try self.device.updateBuffer(self.instances, 0, std.mem.sliceAsBytes(self.staging.items));
        }

        var pass: Pass = .{ .renderer = self, .target = target, .width = view.width, .height = view.height };
        try pass.begin(clear);

        self.draw_calls = 0;
        self.drawn = @intCast(self.items.items.len);

        var start: usize = 0;
        while (start < self.items.items.len) {
            const first = self.items.items[start];

            var end = start + 1;
            while (end < self.items.items.len and first.sharesDrawWith(self.items.items[end])) : (end += 1) {}

            try pass.use(first.shader, first.blend, first.params);
            try pass.bindPicture(first.texture, first.sampler);
            // A draw has no first-instance argument, so the buffer binding is
            // moved to the start of the run instead.
            try pass.list.setVertexBuffer(1, self.instances, @intCast(start * @sizeOf(Instance)));
            try pass.list.draw(.{ .vertex_count = 4, .instance_count = @intCast(end - start) });
            pass.drew = true;
            self.draw_calls += 1;

            start = end;
        }

        try pass.end();
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

    /// The compiled shader a handle names, or the plain one.
    fn compiledOf(self: *const Renderer, shader: ShaderHandle) *const material.Compiled {
        if (shader.isNone()) return &self.plain;
        const table = self.shaders orelse return &self.plain;
        return table.compiledOf(shader) orelse &self.plain;
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
        shaders_mod.pack(block, given, bytes);
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
        compiled: *const material.Compiled = undefined,
        shader: ?ShaderHandle = null,
        blend: Sprite.Blend = .alpha,
        params: u32 = no_params,
        /// Whether anything has been drawn since the screen was last copied.
        drew: bool = false,
        /// The copy a shader reading the screen reads, while it holds.
        copy: ?rhi.Texture = null,

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
            if (self.shader) |shader| {
                const blend = self.blend;
                const params = self.params;
                self.shader = null;
                try self.use(shader, blend, params);
            }
        }

        fn end(self: *Pass) !void {
            try self.list.setScissor(null);
            try self.list.endPass();
            try self.renderer.device.submit();
        }

        /// Draw with a shader, a way of blending and a set of numbers.
        fn use(self: *Pass, shader: ShaderHandle, blend: Sprite.Blend, params: u32) !void {
            const r = self.renderer;
            if (self.shader) |bound| if (bound.eql(shader) and self.blend == blend and self.params == params) return;
            self.compiled = r.compiledOf(shader);
            self.shader = shader;
            self.blend = blend;
            self.params = params;
            try self.list.setPipeline(self.compiled.pipelines.get(blend));
            try self.list.setVertexBuffer(0, r.quad, 0);
            try self.list.setUniformBuffer(0, r.frame);
            if (params != no_params and self.compiled.params != null) {
                try self.list.setUniformBuffer(material.params_slot, r.param_buffers.items[params].buffer);
            }
        }

        /// Bind a run's picture, and - for a shader that reads the screen -
        /// a copy of what is drawn so far, made now if more has been drawn
        /// since the last.
        fn bindPicture(self: *Pass, texture: rhi.Texture, sampler: rhi.Sampler) !void {
            const r = self.renderer;
            if (self.compiled.texture_slot) |slot| try self.list.setTexture(slot, texture, sampler);
            const slot = self.compiled.screen_slot orelse return;
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
                if (self.compiled.texture_slot) |picture_slot| try self.list.setTexture(picture_slot, texture, sampler);
            }
            try self.list.setTexture(slot, self.copy.?, r.white_sampler);
        }
    };

    /// Walk the world and turn every visible sprite into an instance: shown
    /// as its `Appearance` and everything above it say - hidden, its colour
    /// multiplied, its layer raised.
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
    ) !void {
        const bounds = view.bounds();
        self.items.clearRetainingCapacity();
        self.culled = 0;
        self.tile_chunks_drawn = 0;
        self.tile_chunks_culled = 0;

        var sequence: u32 = 0;

        var it = try Drawable.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const sprites = chunk.slice(Sprite);

            for (transforms, sprites, chunk.entities) |local, sprite, entity| {
                if (!sprite.visible or sprite.tint.a <= 0) continue;
                const looks = inherited.of(gpa, world, entity);
                const tint = looks.tint(sprite.tint);
                if (!looks.visible or tint.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                const picture = self.pictureOf(world, entity, sprite.texture) orelse continue;

                // Interpolated, then carried through whatever it hangs from.
                // What cannot be placed - its parent died this frame, or its
                // chain is a cycle - is not drawn.
                const transform = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;

                // A handle that no longer resolves draws as the white texel:
                // a coloured rectangle is a bug somebody notices.
                const texture = assets.get(picture) orelse
                    assets.get(assets.white) orelse continue;
                // A picture drawn into on a backend that counts rows from
                // the bottom is shown turned over.
                const region = if (texture.upside_down) sprite.region.flippedY() else sprite.region;

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
                const drawn_with = try self.materialOf(gpa, world, entity);

                defer sequence += 1;
                try self.items.append(gpa, .{
                    .key = sortKey(looks.layer(sprite.layer), picture),
                    .order = sprite.order,
                    .sequence = sequence,
                    .texture = texture.gpu,
                    .sampler = assets.samplerFor(texture.filter, texture.wrap),
                    .blend = sprite.blend,
                    .shader = drawn_with.shader,
                    .params = drawn_with.params,
                    .instance = .{
                        .placement = .{ transform.x, transform.y, drawn_width, drawn_height },
                        .spin = .{ sprite.pivot_x, sprite.pivot_y, c, s },
                        .tint = .{ tint.r, tint.g, tint.b, tint.a },
                        .uv_rect = .{ region.u0, region.v0, region.u1, region.v1 },
                    },
                });
            }
        }

        try self.gatherTiles(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view, &sequence);
        try self.gatherText(gpa, world, assets, snapshots, inherited, alpha, view, &sequence);

        std.sort.pdq(Item, self.items.items, {}, Item.before);
    }

    /// The texture a sprite shows: a render view's picture, for one with a
    /// `ViewTexture`, or its own. Null for one showing the view being drawn,
    /// which cannot be read while it is drawn into.
    fn pictureOf(self: *const Renderer, world: *ecs.World, entity: ecs.Entity, own: Assets.TextureHandle) ?Assets.TextureHandle {
        const views = self.views orelse return own;
        if (world.get(entity, components.ViewTexture)) |held| {
            if (!self.drawing.isNone() and held.view.eql(self.drawing)) return null;
        }
        return views.shown(world, entity, own);
    }

    /// The shader an entity's `Material` names - when it compiled - and the
    /// set of numbers it gives it; none for a plain picture.
    fn materialOf(self: *Renderer, gpa: Allocator, world: *ecs.World, entity: ecs.Entity) !struct { shader: ShaderHandle = .none, params: u32 = no_params } {
        const held = world.get(entity, shaders_mod.Material) orelse return .{};
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
        sequence: *u32,
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
                    const picture: tileset.Picture = if (set) |held|
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

                    sequence.* += 1;
                    try self.items.append(gpa, .{
                        .key = sortKey(layer, picture.texture),
                        .order = map.order,
                        .sequence = sequence.*,
                        .texture = texture.gpu,
                        .sampler = assets.samplerFor(texture.filter, texture.wrap),
                        .blend = .alpha,
                        .instance = .{
                            .placement = .{ at.x, at.y, across, down },
                            .spin = .{ 0.5, 0.5, @cos(rotation), @sin(rotation) },
                            .tint = .{ tint.r, tint.g, tint.b, tint.a },
                            .uv_rect = .{ how.region.u0, how.region.v0, how.region.u1, how.region.v1 },
                        },
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
        sequence: *u32,
    ) !void {
        const bounds = view.bounds();
        var it = try Labels.over(world);
        while (it.next()) |chunk| {
            const transforms = chunk.slice(Transform2D);
            const labels = chunk.slice(Text2D);

            for (transforms, labels, chunk.entities) |local, label, entity| {
                const run = (self.texts orelse return).get(entity, text_key);
                if (!label.visible or run.len == 0 or label.color.a <= 0) continue;
                const looks = inherited.of(gpa, world, entity);
                if (!looks.visible or looks.modulate.a <= 0 or looks.render_layers & view.cull_mask == 0) continue;
                // A scene's words are UTF-8 by the time they are read, but a
                // label's bytes can be written by hand, and the walk through
                // its characters below takes them on trust.
                if (!std.unicode.utf8ValidateSlice(run)) continue;

                // Not drawn when it cannot be placed, as with a sprite.
                const transform = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;
                const face = assets.fontOf(label.font) orelse continue;

                var shown = label;
                shown.color = looks.tint(label.color);
                shown.layer = looks.layer(label.layer);
                try self.layOut(gpa, assets, face, shown, run, transform, bounds, sequence);
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
        run: []const u8,
        transform: Transform2D,
        bounds: Bounds,
        sequence: *u32,
    ) !void {
        // Whole pixels, as the atlas is keyed - and no taller than the atlas,
        // which could not keep a bigger glyph anyway: a size read from a file
        // is not always one a hand would give, and NaN is the smallest.
        const tallest: f32 = @floatFromInt(@min(face.atlas.height, std.math.maxInt(u16)));
        const rounded = @round(label.size);
        const pixels: u16 = if (rounded >= 1 and rounded <= tallest)
            @intFromFloat(rounded)
        else if (rounded > tallest)
            @intFromFloat(tallest)
        else
            1;
        const scaled = face.face.at(@floatFromInt(pixels));
        const line_height = scaled.lineHeight() * label.line_spacing;

        // The whole label against the camera, boxed generously: one test, not
        // one per letter.
        const measured = measure(&face.face, scaled, run);
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

    // The size the renderer rounds to, and the lines it lays out.
    const tallest: f32 = @floatFromInt(@min(face.atlas.height, std.math.maxInt(u16)));
    const rounded = @round(label.size);
    const pixels: u16 = if (rounded >= 1 and rounded <= tallest)
        @intFromFloat(rounded)
    else if (rounded > tallest)
        @intFromFloat(tallest)
    else
        1;
    const scaled = face.face.at(@floatFromInt(pixels));
    const line_height = scaled.lineHeight() * label.line_spacing;
    const measured = measure(&face.face, scaled, run);
    if (!(measured.width > 0) or !(measured.lines > 0) or !std.math.isFinite(line_height)) return null;

    // The transform is the top left of the first line; each line is moved
    // by the alignment, and so is the box around them.
    const left: f32 = switch (label.alignment) {
        .left => 0,
        .center => -measured.width / 2,
        .right => -measured.width,
    };
    const width = measured.width * placed.scale_x;
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
