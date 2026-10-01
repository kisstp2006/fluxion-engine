// SPDX-License-Identifier: BSD-3-Clause

//! How the 2D world is lit: `lights.zig` says what a game puts in it, and
//! this is how the renderer draws it.
//!
//! **One buffer, the size of the target.** It is cleared to half the ambient
//! light, every light is drawn into it - added, or taken away - and it is
//! laid over what was drawn of the world, the two multiplied twice: half is
//! the world as it was, and one, all a byte holds, twice as bright. What is
//! `unshaded` is drawn after, over it. One pass for all the lights, however
//! many.
//!
//! **Shadows are in the buffer's alpha.** A light with shadows first writes
//! one over its reach, then takes its shadows from it: every edge of an
//! occluder that faces away from it, drawn out away from it past its reach.
//! Then it is drawn twice - once everywhere, times what its `shadow_color`
//! lets through, and once with the rest as far as the alpha says it is not
//! shadowed - so no light needs a buffer of its own. The occluder itself
//! lies between the edges that face the light and those that do not, and so
//! is lit.
//!
//! **A soft shadow is many sharp ones.** A light as wide as its
//! `shadow_softness` casts its shadows from `soft_samples` places across it -
//! or ways, for a directional one - each taking its share of the alpha, so a
//! place some of them reach is part lit: a penumbra, wider the farther it
//! falls. The light itself is still drawn once.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");

const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const inherited_mod = @import("../scene/inherited.zig");
const lights = @import("lights.zig");
const tilemap = @import("../tiles/tilemap.zig");
const tileset = @import("../tiles/tileset.zig");
const material = @import("material.zig");
const sprite = @import("sprite.zig");
const view_mod = @import("view.zig");

const Vec2 = math.Vec2;
const Transform2D = components.Transform2D;
const Inherited = inherited_mod.Inherited;
const Instance = sprite.Instance;
const View = view_mod.View;
const Bounds = view_mod.Bounds;

/// What a light is drawn through: its picture as light - its colour times
/// its alpha, times the light's - with the alpha the draw is given, which is
/// what a mask writes.
const light_shader =
    \\fragment {
    \\    vec4 held = sample(TEXTURE, UV);
    \\    target = vec4(held.rgb * held.a * COLOR.rgb, COLOR.a);
    \\}
;

const light_blends = [_]material.Blend{ .light, .darkness, .light_unshadowed, .darkness_unshadowed, .mask, .shadow };

/// The most light buffers kept, one for each size of target drawn into.
const max_buffers = 4;

/// What marks a light's reach lit, in the buffer's alpha.
const in_light = [4]f32{ 0, 0, 0, 1 };

/// How many places across it a soft light casts its shadows from. Fifteen,
/// so each takes seventeen of a byte's 255 from the alpha, and all of them
/// take it all.
pub const soft_samples = 15;

/// A turn over the golden ratio, squared: places spread by it over a disc
/// never line up.
const golden_angle = std.math.pi * (3 - @sqrt(5.0));

/// One thing drawn into the light buffer, in the order it is drawn.
pub const Draw = struct {
    instance: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    blend: material.Blend,

    pub fn sharesDrawWith(self: Draw, other: Draw) bool {
        return self.blend == other.blend and
            std.meta.eql(self.texture, other.texture) and
            std.meta.eql(self.sampler, other.sampler);
    }
};

/// A light the view sees, found before anything of it is drawn.
const Light = struct {
    quad: Instance,
    texture: rhi.Texture,
    sampler: rhi.Sampler,
    source: Source,
    blend: lights.Blend,
    shadows: bool,
    shadow_color: Color,
    /// How far across it is, for its shadows; an angle, for a directional
    /// light.
    softness: f32 = 0,

    const Source = union(enum) {
        /// Where a point light is, and how far its quad reaches from there.
        point: struct { at: Vec2, reach: f32 },
        /// The way a directional light falls, and how far behind an
        /// occluder its shadow goes.
        way: struct { way: Vec2, distance: f32 },

        /// Where the `k`th of `samples` shares of a light `softness` across
        /// comes from: a place on a disc round a point light's - spread by
        /// the golden angle, as many near its middle as a disc has - or a way
        /// either side of a directional light's.
        fn sampled(self: Source, softness: f32, k: usize, samples: u32) Source {
            if (samples <= 1) return self;
            const along = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(samples));
            return switch (self) {
                .point => |point| point: {
                    const angle = @as(f32, @floatFromInt(k)) * golden_angle;
                    const out = Vec2.init(@cos(angle), @sin(angle)).scale(softness * @sqrt(along));
                    break :point .{ .point = .{ .at = point.at.add(out), .reach = point.reach + softness } };
                },
                .way => |way| .{ .way = .{ .way = way.way.rotate(softness * (2 * along - 1)), .distance = way.distance } },
            };
        }
    };

    /// How far from the view an occluder can be and still cast a shadow of
    /// it into the view.
    fn shadowReach(self: Light) f32 {
        return switch (self.source) {
            .point => |point| 2 * point.reach + self.softness,
            .way => |way| way.distance,
        };
    }
};

/// An occluder's outline, among `Lighting.corners`.
const Outline = struct {
    first: u32,
    count: u32,
    /// The middle of its corners, and how far the farthest is from it.
    center: Vec2,
    reach: f32,
    /// Which way round its corners go, which says which side of an edge is
    /// out.
    anticlockwise: bool,
};

/// A light buffer, of the size of a target drawn into.
const Buffer = struct {
    texture: rhi.Texture = .none,
    width: u32 = 0,
    height: u32 = 0,
    /// When it was last asked for, by `Lighting.clock`.
    used: u64 = 0,
};

pub const Lighting = struct {
    device: *rhi.Device,
    /// What the lights are drawn through.
    shader: material.Compiled,
    /// This frame's: what the buffer is cleared to, and what is drawn into
    /// it after.
    ambient: Color = .white,
    draws: std.ArrayList(Draw) = .empty,
    found: std.ArrayList(Light) = .empty,
    /// The occluders' outlines this frame, their corners one after another.
    corners: std.ArrayList(Vec2) = .empty,
    outlines: std.ArrayList(Outline) = .empty,
    buffers: [max_buffers]Buffer = @splat(.{}),
    clock: u64 = 0,
    /// How many lights the last frame drew, and how many pieces of shadow.
    lights_drawn: u32 = 0,
    shadows_drawn: u32 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device) !Lighting {
        var problems: std.Io.Writer.Allocating = .init(gpa);
        defer problems.deinit();
        const shader = material.compile(gpa, device, light_shader, "lights", &problems.writer, &light_blends) catch |err| {
            std.log.scoped(.fluxion_engine).err("light shader: {s}", .{problems.written()});
            return err;
        };
        return .{ .device = device, .shader = shader };
    }

    pub fn deinit(self: *Lighting, gpa: Allocator) void {
        for (self.buffers) |held| if (!held.texture.isNone()) self.device.destroyTexture(held.texture);
        self.draws.deinit(gpa);
        self.found.deinit(gpa);
        self.corners.deinit(gpa);
        self.outlines.deinit(gpa);
        self.shader.deinit(self.device);
        self.* = undefined;
    }

    /// The light as `view` sees it this frame, made ready to draw into the
    /// buffer. False when it sees no light and no ambient light: the world
    /// is drawn as it is.
    pub fn gather(
        self: *Lighting,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        tile_sets: *tileset.TileSets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !bool {
        self.draws.clearRetainingCapacity();
        self.found.clearRetainingCapacity();
        self.corners.clearRetainingCapacity();
        self.outlines.clearRetainingCapacity();
        self.lights_drawn = 0;
        self.shadows_drawn = 0;

        const ambient = try self.findAmbient(gpa, world, inherited, view);
        try self.findLights(gpa, world, assets, snapshots, inherited, alpha, view);
        if (!ambient and self.found.items.len == 0) return false;

        // Only the occluders near enough to cast a shadow into the view.
        var reach: ?f32 = null;
        for (self.found.items) |light| {
            if (light.shadows) reach = @max(reach orelse 0, light.shadowReach());
        }
        if (reach) |far| try self.findOccluders(gpa, world, assets, tile_sets, snapshots, inherited, alpha, view.bounds(), far);

        // Those without shadows first, where they draw together.
        for (self.found.items) |light| if (!light.shadows) try self.drawLight(gpa, light);
        for (self.found.items) |light| if (light.shadows) try self.drawLight(gpa, light);
        self.lights_drawn = @intCast(self.found.items.len);
        return true;
    }

    /// What the buffer starts as: half the ambient light, as it holds half.
    pub fn clearColor(self: *const Lighting) Color {
        return .{ .r = self.ambient.r / 2, .g = self.ambient.g / 2, .b = self.ambient.b / 2, .a = 1 };
    }

    /// A buffer of this size: one kept from before, or a new one in place of
    /// the one least lately used.
    pub fn bufferOf(self: *Lighting, width: u32, height: u32) !rhi.Texture {
        self.clock += 1;
        var oldest: *Buffer = &self.buffers[0];
        for (&self.buffers) |*held| {
            if (held.width == width and held.height == height) {
                held.used = self.clock;
                return held.texture;
            }
            if (held.used < oldest.used) oldest = held;
        }
        const texture = try self.device.createTexture(.{
            .width = @max(width, 1),
            .height = @max(height, 1),
            .usage = .{ .sampled = true, .render_target = true },
            .clear_color = self.clearColor().array(),
            .label = "light",
        });
        if (!oldest.texture.isNone()) self.device.destroyTexture(oldest.texture);
        oldest.* = .{ .texture = texture, .width = width, .height = height, .used = self.clock };
        return texture;
    }

    fn findAmbient(self: *Lighting, gpa: Allocator, world: *ecs.World, inherited: *Inherited, view: View) !bool {
        self.ambient = .white;
        var it = try ecs.Query(.{lights.AmbientLight2D}).over(world);
        while (it.next()) |chunk| {
            for (chunk.slice(lights.AmbientLight2D), chunk.entities) |held, entity| {
                if (!shows(inherited.of(gpa, world, entity), view)) continue;
                self.ambient = held.color;
                return true;
            }
        }
        return false;
    }

    fn findLights(
        self: *Lighting,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        view: View,
    ) !void {
        const bounds = view.bounds();
        var points = try ecs.Query(.{ Transform2D, lights.PointLight2D }).over(world);
        while (points.next()) |chunk| {
            for (chunk.slice(Transform2D), chunk.slice(lights.PointLight2D), chunk.entities) |local, held, entity| {
                if (!held.enabled or !(held.radius > 0) or !(held.energy * held.color.a > 0)) continue;
                if (!shows(inherited.of(gpa, world, entity), view)) continue;
                const placed = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;
                const width = 2 * held.radius * placed.scale_x;
                const height = 2 * held.radius * placed.scale_y;
                const reach = @sqrt(width * width + height * height) / 2;
                if (!bounds.admits(placed.x, placed.y, reach)) continue;
                const picture = assets.get(if (held.texture.isNone()) assets.glow else held.texture) orelse
                    assets.get(assets.glow) orelse continue;
                const uv: [4]f32 = if (picture.upside_down) .{ 0, 1, 1, 0 } else .{ 0, 0, 1, 1 };
                try self.found.append(gpa, .{
                    .quad = .quad(placed.x, placed.y, width, height, 0.5, 0.5, @cos(placed.rotation), @sin(placed.rotation), glowOf(held.color, held.energy), uv),
                    .texture = picture.gpu,
                    .sampler = assets.samplerFor(picture.filter, .clamp_to_edge),
                    .source = .{ .point = .{ .at = .init(placed.x, placed.y), .reach = reach } },
                    .blend = held.blend,
                    .shadows = held.shadows,
                    .shadow_color = held.shadow_color,
                    .softness = if (held.shadow_softness > 0) held.shadow_softness else 0,
                });
            }
        }

        const white = assets.get(assets.white) orelse return;
        var ways = try ecs.Query(.{lights.DirectionalLight2D}).over(world);
        while (ways.next()) |chunk| {
            for (chunk.slice(lights.DirectionalLight2D), chunk.entities) |held, entity| {
                if (!held.enabled or !(held.energy * held.color.a > 0)) continue;
                if (!shows(inherited.of(gpa, world, entity), view)) continue;
                // Along its entity's `+y`: down the screen, unturned.
                const turn: f32 = if (world.get(entity, Transform2D)) |local|
                    (hierarchy.resolve(world, snapshots, entity, local.*, alpha) orelse continue).rotation
                else
                    0;
                try self.found.append(gpa, .{
                    .quad = overView(view, glowOf(held.color, held.energy), .{ 0, 0, 1, 1 }),
                    .texture = white.gpu,
                    .sampler = assets.samplerFor(white.filter, .clamp_to_edge),
                    .source = .{ .way = .{ .way = .init(-@sin(turn), @cos(turn)), .distance = @max(held.max_distance, 0) } },
                    .blend = held.blend,
                    .shadows = held.shadows,
                    .shadow_color = held.shadow_color,
                    // Less than a quarter turn either way, or the shadows
                    // would fall back past what casts them.
                    .softness = if (held.shadow_softness > 0) @min(held.shadow_softness, 1.5) else 0,
                });
            }
        }
    }

    /// Every occluder's outline, and every solid tile's of a map that casts
    /// shadows, that could cast one `far` into the view.
    fn findOccluders(
        self: *Lighting,
        gpa: Allocator,
        world: *ecs.World,
        assets: *Assets,
        tile_sets: *tileset.TileSets,
        snapshots: *const hierarchy.Snapshots,
        inherited: *Inherited,
        alpha: f32,
        bounds: Bounds,
        far: f32,
    ) !void {
        var corners: [lights.max_corners]Vec2 = undefined;
        var own = try ecs.Query(.{ Transform2D, lights.LightOccluder2D }).over(world);
        while (own.next()) |chunk| {
            for (chunk.slice(Transform2D), chunk.slice(lights.LightOccluder2D), chunk.entities) |local, held, entity| {
                if (!held.enabled or !inherited.of(gpa, world, entity).visible) continue;
                const placed = hierarchy.resolve(world, snapshots, entity, local, alpha) orelse continue;
                const box: lights.SpriteBox = if (world.get(entity, components.Sprite)) |drawn|
                    sprite.spriteBox(drawn.*, assets.get(drawn.texture) orelse assets.get(assets.white) orelse continue)
                else
                    @splat(0);
                try self.keep(gpa, lights.outline(held, box, placed, &corners), bounds, far);
            }
        }

        var chunks = try ecs.Query(.{tilemap.TileChunk}).over(world);
        while (chunks.next()) |chunk| {
            for (chunk.slice(tilemap.TileChunk)) |*tiles| {
                const map = world.get(tiles.map, tilemap.TileMap) orelse continue;
                if (!map.light_occlusion or !inherited.of(gpa, world, tiles.map).visible) continue;
                const set = tile_sets.get(map.tile_set) orelse continue;
                const local = world.get(tiles.map, Transform2D) orelse continue;
                const placed = hierarchy.resolve(world, snapshots, tiles.map, local.*, alpha) orelse continue;
                const tile_width: f32 = @floatFromInt(@max(set.tile_width, 1));
                const tile_height: f32 = @floatFromInt(@max(set.tile_height, 1));
                // The chunk's top left, in cells from the map's origin.
                const left: f32 = @floatFromInt(tiles.x * tilemap.chunk_side);
                const top: f32 = @floatFromInt(tiles.y * tilemap.chunk_side);
                const Cells = struct {
                    placed: Transform2D,
                    width: f32,
                    height: f32,

                    fn at(cells: @This(), x: f32, y: f32) Vec2 {
                        const moved = cells.placed.apply(x * cells.width, y * cells.height);
                        return .init(moved.x, moved.y);
                    }
                };
                const cells: Cells = .{ .placed = placed, .width = tile_width, .height = tile_height };

                var solids: tilemap.Solids = .{ .chunk = tiles, .set = set };
                while (solids.next()) |solid| {
                    const count: usize = switch (solid) {
                        .box => |box| count: {
                            const x0 = left + @as(f32, @floatFromInt(box.x));
                            const y0 = top + @as(f32, @floatFromInt(box.y));
                            const x1 = x0 + @as(f32, @floatFromInt(box.width));
                            const y1 = y0 + @as(f32, @floatFromInt(box.height));
                            corners[0..4].* = .{ cells.at(x0, y0), cells.at(x1, y0), cells.at(x1, y1), cells.at(x0, y1) };
                            break :count 4;
                        },
                        .polygon => |shaped| count: {
                            const given = shaped.tile.polygon();
                            for (given, 0..) |point, i| {
                                const turned = tilemap.place(shaped.cell, point.x / tile_width, point.y / tile_height);
                                corners[i] = cells.at(left + @as(f32, @floatFromInt(shaped.x)) + turned[0], top + @as(f32, @floatFromInt(shaped.y)) + turned[1]);
                            }
                            break :count given.len;
                        },
                    };
                    try self.keep(gpa, corners[0..count], bounds, far);
                }
            }
        }
    }

    /// An outline kept for this frame's shadows, if it is near enough to
    /// cast one into the view and has an inside to cast it with.
    fn keep(self: *Lighting, gpa: Allocator, corners: []const Vec2, bounds: Bounds, far: f32) !void {
        if (corners.len < 3) return;
        var area: f32 = 0;
        var sum: Vec2 = .zero;
        for (corners, 0..) |corner, i| {
            area += corner.crossZ(corners[(i + 1) % corners.len]);
            sum = sum.add(corner);
        }
        if (!(area != 0)) return;
        const center = sum.scale(1 / @as(f32, @floatFromInt(corners.len)));
        var reach: f32 = 0;
        for (corners) |corner| reach = @max(reach, corner.dist(center));
        if (!bounds.admits(center.x, center.y, reach + far)) return;
        try self.outlines.append(gpa, .{
            .first = @intCast(self.corners.items.len),
            .count = @intCast(corners.len),
            .center = center,
            .reach = reach,
            .anticlockwise = area > 0,
        });
        try self.corners.appendSlice(gpa, corners);
    }

    fn put(self: *Lighting, gpa: Allocator, light: Light, instance: Instance, blend: material.Blend) !void {
        try self.draws.append(gpa, .{ .instance = instance, .texture = light.texture, .sampler = light.sampler, .blend = blend });
    }

    /// One light into the buffer: as it is, or with its reach and its shadows
    /// marked in the alpha first.
    fn drawLight(self: *Lighting, gpa: Allocator, light: Light) !void {
        const everywhere: material.Blend, const unshadowed: material.Blend = switch (light.blend) {
            .add => .{ .light, .light_unshadowed },
            .subtract => .{ .darkness, .darkness_unshadowed },
        };
        if (!light.shadows) return self.put(gpa, light, light.quad, everywhere);

        const marked = self.draws.items.len;
        try self.put(gpa, light, tinted(light.quad, in_light), .mask);
        const cast = try self.castShadows(gpa, light);
        if (cast == 0) {
            // Nothing in its way: drawn as a light without shadows is.
            self.draws.shrinkRetainingCapacity(marked);
            return self.put(gpa, light, light.quad, everywhere);
        }
        self.shadows_drawn += cast;

        // What its shadows let through, everywhere; the rest only where it
        // is not shadowed.
        const shadow = light.shadow_color;
        const through = [3]f32{
            1 + (shadow.r - 1) * shadow.a,
            1 + (shadow.g - 1) * shadow.a,
            1 + (shadow.b - 1) * shadow.a,
        };
        const own = light.quad.tint;
        if (through[0] > 0 or through[1] > 0 or through[2] > 0) {
            try self.put(gpa, light, tinted(light.quad, .{ own[0] * through[0], own[1] * through[1], own[2] * through[2], 1 }), everywhere);
        }
        try self.put(gpa, light, tinted(light.quad, .{ own[0] * (1 - through[0]), own[1] * (1 - through[1]), own[2] * (1 - through[2]), 1 }), unshadowed);
    }

    /// The shadows of every kept outline's edges that face away from the
    /// light, taken from the alpha: from its middle, for a sharp light, and
    /// for a soft one from each of `soft_samples` places across it, each
    /// taking its share. How many pieces were drawn.
    fn castShadows(self: *Lighting, gpa: Allocator, light: Light) !u32 {
        const samples: u32 = if (light.softness > 0) soft_samples else 1;
        const share = [4]f32{ 0, 0, 0, 1 / @as(f32, @floatFromInt(samples)) };
        var cast: u32 = 0;
        for (0..samples) |k| {
            const from = light.source.sampled(light.softness, k, samples);
            for (self.outlines.items) |outline| {
                if (from == .point) {
                    const point = from.point;
                    if (outline.center.dist(point.at) > outline.reach + point.reach) continue;
                }
                const corners = self.corners.items[outline.first..][0..outline.count];
                for (corners, 0..) |a, i| {
                    const b = corners[(i + 1) % corners.len];
                    const edge = b.sub(a);
                    const out: Vec2 = if (outline.anticlockwise) .init(edge.y, -edge.x) else .init(-edge.y, edge.x);
                    switch (from) {
                        .point => |point| {
                            if (!(out.dot(a.add(b).scale(0.5).sub(point.at)) > 0)) continue;
                            cast += try self.shadowFrom(gpa, light, point.at, point.reach, a, b, share);
                        },
                        .way => |way| {
                            if (!(out.dot(way.way) > 0)) continue;
                            try self.put(gpa, light, .parallelogram(a, edge, way.way.scale(way.distance), share, .{ 0, 0, 1, 1 }), .shadow);
                            cast += 1;
                        },
                    }
                }
            }
        }
        return cast;
    }

    /// The shadow edge `a` to `b` casts from a light at `from`: the rays from
    /// the light through the edge, from the edge on to at least `reach` from
    /// the light. In at most three pieces, each a sixth of a turn or less
    /// across, so the far side of each stays that far away: an edge the light
    /// is almost on sees nearly half a turn.
    fn shadowFrom(self: *Lighting, gpa: Allocator, light: Light, from: Vec2, reach: f32, a: Vec2, b: Vec2, share: [4]f32) !u32 {
        const to_a = a.sub(from);
        const to_b = b.sub(from);
        const turn = std.math.atan2(to_a.crossZ(to_b), to_a.dot(to_b));
        const pieces: u32 = @max(@as(u32, @intFromFloat(@ceil(@abs(turn) / (std.math.pi / 3.0)))), 1);
        const piece = turn / @as(f32, @floatFromInt(pieces));
        // Past the edge's own far end, as well as the light's reach.
        const far = @max(reach, @max(to_a.len(), to_b.len())) * 1.01;
        const out = far / @cos(piece / 2);
        const start = std.math.atan2(to_a.y, to_a.x);

        var near = a;
        var away = from.add(Vec2.init(@cos(start), @sin(start)).scale(out));
        for (1..pieces + 1) |i| {
            const angle = start + piece * @as(f32, @floatFromInt(i));
            const way: Vec2 = .init(@cos(angle), @sin(angle));
            const next_near = if (i == pieces) b else hit(from, way, a, b);
            const next_away = from.add(way.scale(out));
            try self.put(gpa, light, .triangle(near, next_near, next_away, share), .shadow);
            try self.put(gpa, light, .triangle(near, next_away, away, share), .shadow);
            near = next_near;
            away = next_away;
        }
        return pieces * 2;
    }
};

/// A quad covering the whole of what `view` shows, in the world: what a
/// directional light lights, and where the buffer is laid over the world.
pub fn overView(view: View, tint: [4]f32, uv: [4]f32) Instance {
    const origin = view.toWorld(.zero);
    return .parallelogram(origin, view.toWorld(.init(view.width, 0)).sub(origin), view.toWorld(.init(0, view.height)).sub(origin), tint, uv);
}

/// Whether what `looks` resolved to is shown in `view`.
fn shows(looks: inherited_mod.Resolved, view: View) bool {
    return looks.visible and looks.render_layers & view.cull_mask != 0;
}

/// A light's colour as it goes into the buffer, which holds half.
fn glowOf(color: Color, energy: f32) [4]f32 {
    const strength = energy * color.a / 2;
    return .{ color.r * strength, color.g * strength, color.b * strength, 1 };
}

fn tinted(instance: Instance, tint: [4]f32) Instance {
    var out = instance;
    out.tint = tint;
    return out;
}

/// Where the ray from `from` along `way` meets the line through `a` and `b`;
/// `a`, for a ray along it.
fn hit(from: Vec2, way: Vec2, a: Vec2, b: Vec2) Vec2 {
    const edge = b.sub(a);
    const across = way.crossZ(edge);
    if (!(@abs(across) > 1e-6 * edge.len())) return a;
    return from.add(way.scale(@max(a.sub(from).crossZ(edge) / across, 0)));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Whether `p` is inside the triangle an instance folds into.
fn inTriangle(instance: Instance, p: Vec2) bool {
    const a = instance.corner(0, 0);
    const b = instance.corner(1, 0);
    const c = instance.corner(0, 1);
    const one = b.sub(a).crossZ(p.sub(a));
    const two = c.sub(b).crossZ(p.sub(b));
    const three = a.sub(c).crossZ(p.sub(c));
    return (one >= 0 and two >= 0 and three >= 0) or (one <= 0 and two <= 0 and three <= 0);
}

/// How much the shadows drawn take from the alpha at `p`.
fn coverage(lighting: *const Lighting, p: Vec2) f32 {
    var taken: f32 = 0;
    for (lighting.draws.items) |drawn| {
        if (drawn.blend != .shadow) continue;
        const covers = if (drawn.instance.shape[2] == 1) inTriangle(drawn.instance, p) else covers: {
            const a = drawn.instance.corner(0, 0);
            const c = drawn.instance.corner(1, 1);
            break :covers inTriangle(.triangle(a, drawn.instance.corner(1, 0), c, @splat(0)), p) or
                inTriangle(.triangle(a, c, drawn.instance.corner(0, 1), @splat(0)), p);
        };
        if (covers) taken += drawn.instance.tint[3];
    }
    return taken;
}

fn shadowed(lighting: *const Lighting, p: Vec2) bool {
    return coverage(lighting, p) > 0;
}

test "a box's shadow falls behind it from the light, and nowhere else" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var lighting: Lighting = try .init(testing.allocator, &device);
    defer lighting.deinit(testing.allocator);

    // A light at the origin, and a box 20 to 40 to its right, 10 tall each
    // way; wound either way round.
    const light: Light = .{
        .quad = .quad(0, 0, 400, 400, 0.5, 0.5, 1, 0, .{ 0.5, 0.5, 0.5, 1 }, .{ 0, 0, 1, 1 }),
        .texture = .none,
        .sampler = .none,
        .source = .{ .point = .{ .at = .zero, .reach = 283 } },
        .blend = .add,
        .shadows = true,
        .shadow_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    const box = [_]Vec2{ .init(20, -10), .init(40, -10), .init(40, 10), .init(20, 10) };
    const round_the_other_way = [_]Vec2{ box[3], box[2], box[1], box[0] };
    const bounds: Bounds = .{ .left = -200, .top = -200, .right = 200, .bottom = 200 };
    for ([_][]const Vec2{ &box, &round_the_other_way }) |corners| {
        lighting.draws.clearRetainingCapacity();
        lighting.corners.clearRetainingCapacity();
        lighting.outlines.clearRetainingCapacity();
        try lighting.keep(testing.allocator, corners, bounds, 600);
        try lighting.drawLight(testing.allocator, light);

        try testing.expect(shadowed(&lighting, .init(100, 0)));
        try testing.expect(shadowed(&lighting, .init(270, 30)));
        // The box itself, what is in front of it and what is beside it are lit.
        try testing.expect(!shadowed(&lighting, .init(30, 0)));
        try testing.expect(!shadowed(&lighting, .init(10, 0)));
        try testing.expect(!shadowed(&lighting, .init(100, 60)));
        try testing.expect(!shadowed(&lighting, .init(-100, 0)));
        // Its reach marked first, and a black shadow lets nothing through:
        // the light is drawn once, where it is not shadowed.
        const draws = lighting.draws.items;
        try testing.expectEqual(material.Blend.mask, draws[0].blend);
        try testing.expectEqual(@as(f32, 1), draws[0].instance.tint[3]);
        try testing.expectEqual(material.Blend.light_unshadowed, draws[draws.len - 1].blend);
        try testing.expect(draws[draws.len - 2].blend == .shadow);
    }
}

test "a light inside an occluder, or almost on its edge, still shadows all it should" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var lighting: Lighting = try .init(testing.allocator, &device);
    defer lighting.deinit(testing.allocator);
    const bounds: Bounds = .{ .left = -200, .top = -200, .right = 200, .bottom = 200 };
    const wall = [_]Vec2{ .init(-50, 0.01), .init(50, 0.01), .init(50, 20), .init(-50, 20) };
    try lighting.keep(testing.allocator, &wall, bounds, 600);

    var light: Light = .{
        .quad = .quad(0, 0, 200, 200, 0.5, 0.5, 1, 0, .{ 0.5, 0.5, 0.5, 1 }, .{ 0, 0, 1, 1 }),
        .texture = .none,
        .sampler = .none,
        .source = .{ .point = .{ .at = .zero, .reach = 142 } },
        .blend = .add,
        .shadows = true,
        .shadow_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    // Just above the wall's top edge: everything below the wall is dark,
    // right out to the light's reach.
    try lighting.drawLight(testing.allocator, light);
    for ([_]Vec2{ .init(0, 30), .init(-95, 25), .init(95, 25), .init(0, 99) }) |p| try testing.expect(shadowed(&lighting, p));
    try testing.expect(!shadowed(&lighting, .init(0, -30)));

    // In the wall: everything but the wall is dark.
    lighting.draws.clearRetainingCapacity();
    light.source.point.at = .init(0, 10);
    try lighting.drawLight(testing.allocator, light);
    for ([_]Vec2{ .init(0, -40), .init(90, 10), .init(-90, 10), .init(0, 60) }) |p| try testing.expect(shadowed(&lighting, p));
    try testing.expect(!shadowed(&lighting, .init(10, 10)));
}

test "a directional light's shadows fall its way, and a coloured shadow lets some of it through" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var lighting: Lighting = try .init(testing.allocator, &device);
    defer lighting.deinit(testing.allocator);
    const bounds: Bounds = .{ .left = -200, .top = -200, .right = 200, .bottom = 200 };
    const box = [_]Vec2{ .init(-10, -10), .init(10, -10), .init(10, 10), .init(-10, 10) };
    try lighting.keep(testing.allocator, &box, bounds, 100);

    try lighting.drawLight(testing.allocator, .{
        .quad = overView(.screen(400, 400), .{ 0.4, 0.4, 0.4, 1 }, .{ 0, 0, 1, 1 }),
        .texture = .none,
        .sampler = .none,
        .source = .{ .way = .{ .way = .init(0, 1), .distance = 100 } },
        .blend = .add,
        .shadows = true,
        .shadow_color = .{ .r = 0.5, .g = 0, .b = 0, .a = 1 },
    });
    try testing.expect(shadowed(&lighting, .init(0, 50)));
    try testing.expect(!shadowed(&lighting, .init(0, 150)));
    try testing.expect(!shadowed(&lighting, .init(0, -50)));
    try testing.expect(!shadowed(&lighting, .init(30, 50)));

    // Half its red gets through the shadow, drawn everywhere; the rest only
    // where it is not shadowed.
    const draws = lighting.draws.items;
    const everywhere = draws[draws.len - 2];
    const unshadowed = draws[draws.len - 1];
    try testing.expectEqual(material.Blend.light, everywhere.blend);
    try testing.expectApproxEqAbs(@as(f32, 0.2), everywhere.instance.tint[0], 1e-6);
    try testing.expectEqual(@as(f32, 0), everywhere.instance.tint[1]);
    try testing.expectEqual(material.Blend.light_unshadowed, unshadowed.blend);
    try testing.expectApproxEqAbs(@as(f32, 0.2), unshadowed.instance.tint[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), unshadowed.instance.tint[1], 1e-6);
}

test "a wide light's shadow is dark behind what casts it, and fades out at its edges" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var lighting: Lighting = try .init(testing.allocator, &device);
    defer lighting.deinit(testing.allocator);
    const bounds: Bounds = .{ .left = -300, .top = -300, .right = 300, .bottom = 300 };
    const box = [_]Vec2{ .init(20, -10), .init(40, -10), .init(40, 10), .init(20, 10) };
    try lighting.keep(testing.allocator, &box, bounds, 800);

    var light: Light = .{
        .quad = .quad(0, 0, 500, 500, 0.5, 0.5, 1, 0, .{ 0.5, 0.5, 0.5, 1 }, .{ 0, 0, 1, 1 }),
        .texture = .none,
        .sampler = .none,
        .source = .{ .point = .{ .at = .zero, .reach = 354 } },
        .blend = .add,
        .shadows = true,
        .shadow_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .softness = 8,
    };
    try lighting.drawLight(testing.allocator, light);
    // Every share of it is stopped right behind the box, and all of it
    // together is the whole alpha.
    try testing.expectApproxEqAbs(@as(f32, 1), coverage(&lighting, .init(60, 0)), 1e-4);
    // Where the sharp shadow's edge would be, far off, part of it gets by.
    const edge = coverage(&lighting, .init(200, 100));
    try testing.expect(edge > 0.2 and edge < 0.8);
    try testing.expectEqual(@as(f32, 0), coverage(&lighting, .init(200, 240)));

    // Sharp again: all or nothing, even there.
    lighting.draws.clearRetainingCapacity();
    light.softness = 0;
    try lighting.drawLight(testing.allocator, light);
    try testing.expectEqual(@as(f32, 1), coverage(&lighting, .init(200, 99)));
    try testing.expectEqual(@as(f32, 0), coverage(&lighting, .init(200, 101)));
}

test "a buffer is kept for each size a target is drawn at, the least lately used going first" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var lighting: Lighting = try .init(testing.allocator, &device);
    defer lighting.deinit(testing.allocator);

    const screen = try lighting.bufferOf(320, 180);
    try testing.expectEqual(screen, try lighting.bufferOf(320, 180));
    for (0..max_buffers - 1) |i| _ = try lighting.bufferOf(64, @intCast(i + 1));
    _ = try lighting.bufferOf(320, 180);
    // One more size: the oldest of the small ones goes, not the screen's.
    _ = try lighting.bufferOf(8, 8);
    try testing.expectEqual(screen, try lighting.bufferOf(320, 180));
    var sizes: u32 = 0;
    for (lighting.buffers) |held| sizes += @intFromBool(held.width == 64);
    try testing.expectEqual(@as(u32, max_buffers - 2), sizes);
}
