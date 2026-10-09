// SPDX-License-Identifier: BSD-3-Clause

//! Solids joined, cut and met, in the scene: a level's walls with their
//! doors and windows cut out, an arch, a pillar's round top. A `CSGShape3D`
//! is a box, a cylinder, a ball, an outline drawn out - a polygon - or a
//! closed mesh - or only a group of what is under it - and each
//! `CSGShape3D` under it, in their order, is joined to it, cut from it or
//! met with it, by its `operation`.
//!
//! The one at the top - whose parent has none - is what they all come to:
//! the `MeshInstance3D` beside it draws a mesh of it, a mesh `Collider3D`
//! beside it collides with it, a navigation region walks on it and a
//! lightmap bakes it, as they would a mesh of its own. Those under it draw
//! nothing themselves. The mesh is made again when any of them changes -
//! moved, resized, cut another way - and kept as it is while none does.
//!
//! ```zig
//! const wall = try app.world.spawnWith(.{
//!     fx.Transform3D.at(0, 1.5, 0), fx.MeshInstance3D{},
//!     fx.CSGShape3D{ .size = .init(6, 3, 0.3) }, fx.Collider3D{ .shape = .mesh },
//! });
//! const door = try app.world.spawnWith(.{
//!     fx.Transform3D.at(0, -0.5, 0),
//!     fx.CSGShape3D{ .operation = .subtract, .size = .init(1, 2, 1) },
//! });
//! try app.setParent(door, wall, false);
//! ```
//!
//! Each face is drawn with the material of the shape it came from: a hole's
//! sides with the cutter's. A shape with none has its parent's. A picture
//! lies flat on each face, seen along the axis the face turns most to, a
//! metre to its width - as big on every face whatever its size; the
//! material's `uv_scale` lays it on more often - and the mesh has lightmap
//! UVs of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const csg = @import("fluxion_csg");
const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const hierarchy = @import("../scene/hierarchy.zig");
const lightmap_uv = @import("lightmap_uv.zig");
const mesh = @import("mesh.zig");
const MaterialHandle = @import("materials.zig").MaterialHandle;

const Entity = ecs.Entity;
const Mat4 = math.Mat4;

/// A solid, joined to what its parent comes to, cut from it or met with
/// it - or, at the top, what those under it are joined to, cut from or met
/// with. See `render/csg_shapes.zig`.
pub const CSGShape3D = extern struct {
    /// What it is: a box, a cylinder standing along `y`, a ball, the closed
    /// `mesh`, nothing of its own - only a group of what is under it - or a
    /// polygon: its outline drawn out along `y`.
    shape: Shape = .box,
    /// What it does to what its parent comes to: joined to it, cut from it,
    /// or kept only where both are. Nothing at the top.
    operation: Operation = .@"union",
    /// A box's width, height and depth.
    size: math.Vec3 = .one,
    /// A cylinder's and a ball's.
    radius: f32 = 0.5,
    /// A cylinder's and a polygon's, from end to end.
    height: f32 = 1,
    /// How many faces round a cylinder or a ball has.
    sides: u32 = 16,
    /// How many bands a ball has from pole to pole.
    rings: u32 = 8,
    /// Whether a cylinder or a ball is lit as if round, or face by face.
    smooth: bool = true,
    /// A polygon's outline, seen from above: the first `point_count`, each
    /// corner's `x` and `z` - as `x` and `y` - in order round it, either
    /// way. A metre square to start with.
    points: [max_points]math.Vec2 = square,
    /// How many of `points` the outline has.
    point_count: u32 = 4,
    /// The material its faces are drawn with, and the sides of what it
    /// cuts; none takes its parent's. A `Material3D` beside the one at the
    /// top draws every face with its own.
    material: MaterialHandle = .none,
    /// The closed mesh a `.mesh` shape is.
    mesh: mesh.MeshHandle = .none,

    pub const Shape = enum(u8) { box, cylinder, sphere, mesh, group, polygon };

    /// A polygon's corners: the first `point_count` of `points`.
    pub fn outline(self: *const CSGShape3D) []const math.Vec2 {
        return self.points[0..@min(self.point_count, max_points)];
    }

    pub const Operation = enum(u8) {
        /// What is in either.
        @"union",
        /// What its parent comes to, but where it is.
        subtract,
        /// Only where both are.
        intersect,
    };

    pub const reflect_name = "CSGShape3D";
    pub const reflect_fields = .{
        .shape = .{attr.Doc{ .text = "A box, a cylinder, a sphere, a closed mesh, a group of what is under it, or an outline drawn out" }},
        .operation = .{attr.Doc{ .text = "Joined to what its parent comes to, cut from it, or kept only where both are" }},
        .size = .{attr.Doc{ .text = "A box's width, height and depth" }},
        .radius = .{ attr.Range{ .min = 0, .max = 1000 }, attr.Doc{ .text = "A cylinder's and a sphere's" } },
        .height = .{ attr.Range{ .min = 0, .max = 1000 }, attr.Doc{ .text = "A cylinder's and a polygon's, end to end" } },
        .sides = .{ attr.Range{ .min = min_sides, .max = max_sides, .step = 1 }, attr.Doc{ .text = "Faces round a cylinder or a sphere" } },
        .rings = .{ attr.Range{ .min = min_rings, .max = max_rings, .step = 1 }, attr.Doc{ .text = "Bands of a sphere from pole to pole" } },
        .smooth = .{attr.Doc{ .text = "Lit as if round, or face by face" }},
        .points = .{ attr.Hidden{}, attr.Doc{ .text = "A polygon's corners seen from above, x and z" } },
        .point_count = .{ attr.Hidden{}, attr.Doc{ .text = "How many corners a polygon has" } },
        .material = .{ attr.Group{ .name = "Look" }, attr.Doc{ .text = "Its faces' material, and the sides of what it cuts; none takes its parent's" } },
        .mesh = .{attr.Doc{ .text = "The closed mesh a mesh shape is" }},
    };
};

/// The most corners a polygon has.
pub const max_points = 32;

/// A metre square about the middle: a polygon's outline to start with.
const square: [max_points]math.Vec2 = blk: {
    var corners: [max_points]math.Vec2 = @splat(.zero);
    corners[0] = .{ .x = -0.5, .y = -0.5 };
    corners[1] = .{ .x = 0.5, .y = -0.5 };
    corners[2] = .{ .x = 0.5, .y = 0.5 };
    corners[3] = .{ .x = -0.5, .y = 0.5 };
    break :blk corners;
};

pub const min_sides = 3;
pub const max_sides = 128;
pub const min_rings = 2;
pub const max_rings = 64;

/// How deep shapes under shapes are followed.
pub const max_depth = 32;

/// Whether `entity` is a `CSGShape3D` at the top: one whose parent has none.
pub fn isTop(world: *ecs.World, entity: Entity) bool {
    if (!world.has(entity, CSGShape3D)) return false;
    const parent = hierarchy.parentOf(world, entity);
    return parent.isNone() or !world.has(parent, CSGShape3D);
}

/// The `CSGShape3D` at the top that `entity` is part of: itself at the
/// top, `.none` where it has none.
pub fn topOf(world: *ecs.World, entity: Entity) Entity {
    var at = entity;
    var depth: usize = 0;
    while (world.has(at, CSGShape3D)) : (depth += 1) {
        const parent = hierarchy.parentOf(world, at);
        if (parent.isNone() or !world.has(parent, CSGShape3D) or depth == max_depth) return at;
        at = parent;
    }
    return .none;
}

/// How many frames a shape at the top stays as it is before its mesh is
/// given lightmap UVs: one changed every frame - dragged, moved by a script
/// - is not unwrapped each time.
pub const settle_frames = 30;

/// The mesh of every `CSGShape3D` at the top, by its entity.
pub const Shapes = struct {
    of_top: std.AutoArrayHashMapUnmanaged(Entity, Made) = .empty,
    /// How many meshes have been made: one more each time a shape changed.
    made: u64 = 0,

    const Made = struct {
        kept: *mesh.Kept,
        /// What it was made from: see `signatureOf`.
        signature: u64,
        /// `Meshes.clock` when it was made.
        at: u64,
    };

    pub fn deinit(self: *Shapes, gpa: Allocator, device: *rhi.Device) void {
        for (self.of_top.values()) |made| free(gpa, device, made.kept);
        self.of_top.deinit(gpa);
    }

    fn free(gpa: Allocator, device: *rhi.Device, kept: *mesh.Kept) void {
        kept.deinit(gpa, device);
        gpa.destroy(kept);
    }

    /// Those of the dead, and of what is no longer at the top, let go.
    pub fn forgetDead(self: *Shapes, app: *App) void {
        var at: usize = 0;
        while (at < self.of_top.count()) {
            const entity = self.of_top.keys()[at];
            if (app.world.isAlive(entity) and isTop(&app.world, entity)) {
                at += 1;
                continue;
            }
            free(app.gpa, &app.device, self.of_top.values()[at].kept);
            self.of_top.swapRemoveAt(at);
        }
    }

    pub fn clear(self: *Shapes, app: *App) void {
        for (self.of_top.values()) |made| free(app.gpa, &app.device, made.kept);
        self.of_top.clearRetainingCapacity();
    }

    /// The mesh `top` and the shapes under it come to, made again if any of
    /// them changed since it was last made. Null where `top` is not a
    /// `CSGShape3D` at the top. Made the first time, or after it stayed as
    /// it was for `settle_frames`, it has lightmap UVs; made again sooner,
    /// it gets them once it has stayed so long.
    pub fn meshOf(self: *Shapes, app: *App, top: Entity) Allocator.Error!?*mesh.Kept {
        if (!isTop(&app.world, top)) return null;
        const signature = signatureOf(app, top);
        const clock = app.meshes.clock;
        const found = try self.of_top.getOrPut(app.gpa, top);
        if (found.found_existing and found.value_ptr.signature == signature) {
            const made = found.value_ptr;
            if (clock -% made.at >= settle_frames) try unwrap(app, made.kept);
            return made.kept;
        }
        const settled = !found.found_existing or clock -% found.value_ptr.at >= settle_frames;
        const kept = build(app, top, settled) catch |err| {
            if (!found.found_existing) _ = self.of_top.swapRemove(top);
            return err;
        };
        // Made before the old is let go: a collider made from the old one
        // sees another address, as well as another stamp.
        if (found.found_existing) free(app.gpa, &app.device, found.value_ptr.kept);
        found.value_ptr.* = .{ .kept = kept, .signature = signature, .at = clock };
        self.made += 1;
        return kept;
    }
};

/// Give a shape's mesh lightmap UVs now if it has none: what a lightmap
/// bake asks before it bakes it. Its buffers are made again with them.
pub fn unwrap(app: *App, kept: *mesh.Kept) Allocator.Error!void {
    if (kept.mesh.uv2_texels > 0 or kept.mesh.indices.len == 0) return;
    try lightmap_uv.unwrap(app.gpa, &kept.mesh);
    if (kept.gpu) |gpu| gpu.deinit(&app.device);
    kept.gpu = null;
}

// -------------------------------------------------------------------------
// What a mesh is made from

/// What changes the mesh `top` comes to, summed: each shape's numbers, its
/// place under the top, whether it is shown, and the making of a mesh it
/// is. Cheap enough to ask each frame.
fn signatureOf(app: *App, top: Entity) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    const shape = app.world.get(top, CSGShape3D) orelse return 0;
    sign(app, &hasher, top, shape.*, 0);
    return hasher.final();
}

fn sign(app: *App, hasher: *std.hash.Wyhash, entity: Entity, shape: CSGShape3D, depth: usize) void {
    hasher.update(std.mem.asBytes(&entity));
    inline for (std.meta.fields(CSGShape3D)) |field| {
        hasher.update(std.mem.asBytes(&@field(shape, field.name)));
    }
    if (shape.shape == .mesh) {
        const stamp: u64 = if (app.meshes.keptOf(shape.mesh)) |kept| kept.stamp else 0;
        hasher.update(std.mem.asBytes(&stamp));
    }
    if (depth == max_depth) return;
    for (app.children(entity)) |child| {
        const under = app.world.get(child, CSGShape3D) orelse continue;
        if (!shown(app, child)) continue;
        const place = placeOf(app, child);
        hasher.update(std.mem.asBytes(&place));
        sign(app, hasher, child, under.*, depth + 1);
    }
}

/// Whether a shape under the top takes part: one an `Appearance` hides is
/// left out, to see what is there without it.
fn shown(app: *App, entity: Entity) bool {
    const look = app.world.get(entity, Appearance) orelse return true;
    return look.visible;
}

/// A shape's place in its parent's space.
fn placeOf(app: *App, entity: Entity) Mat4 {
    const local = app.world.get(entity, Transform3D) orelse return .identity;
    return local.matrix();
}

// -------------------------------------------------------------------------
// Making the mesh

const Building = struct {
    app: *App,
    arena: Allocator,
    /// The materials the faces are drawn with, a face's tag its place here.
    materials: std.ArrayList(MaterialHandle) = .empty,

    fn tagOf(self: *Building, material: MaterialHandle) Allocator.Error!u32 {
        for (self.materials.items, 0..) |known, i| {
            if (known.eql(material)) return @intCast(i);
        }
        try self.materials.append(self.arena, material);
        return @intCast(self.materials.items.len - 1);
    }

    /// What `entity` and the shapes under it come to, placed by `place` in
    /// the top's space.
    fn solidOf(self: *Building, entity: Entity, shape: CSGShape3D, place: Mat4, inherited: MaterialHandle, depth: usize) Allocator.Error!csg.Solid {
        const arena = self.arena;
        const material = if (shape.material.isNone()) inherited else shape.material;
        const tag = try self.tagOf(material);
        const affine: csg.Affine = .ofColumns(@bitCast(place));
        const radius: f64 = @abs(shape.radius);
        const sides = std.math.clamp(shape.sides, min_sides, max_sides);
        var solid: csg.Solid = switch (shape.shape) {
            .box => try csg.box(arena, .init(@abs(shape.size.x), @abs(shape.size.y), @abs(shape.size.z)), affine, tag),
            .cylinder => try csg.cylinder(arena, radius, @abs(shape.height), sides, shape.smooth, affine, tag),
            .sphere => try csg.sphere(arena, radius, sides, std.math.clamp(shape.rings, min_rings, max_rings), affine, tag),
            .mesh => try self.closedMesh(shape.mesh, affine, tag),
            .group => .{},
            .polygon => polygon: {
                var corners: [max_points][2]f64 = undefined;
                const held = shape.outline();
                for (held, corners[0..held.len]) |p, *c| c.* = .{ p.x, p.y };
                break :polygon try csg.prism(arena, corners[0..held.len], @abs(shape.height), affine, tag);
            },
        };
        if (depth == max_depth) return solid;
        // Copied: the children of one asked after the children of another.
        const children = try arena.dupe(Entity, self.app.children(entity));
        for (children) |child| {
            const under = self.app.world.get(child, CSGShape3D) orelse continue;
            if (!shown(self.app, child)) continue;
            const held = under.*;
            const other = try self.solidOf(child, held, place.mul(placeOf(self.app, child)), material, depth + 1);
            solid = try solid.combine(arena, other, switch (held.operation) {
                .@"union" => .@"union",
                .subtract => .subtract,
                .intersect => .intersect,
            });
        }
        return solid;
    }

    fn closedMesh(self: *Building, handle: mesh.MeshHandle, place: csg.Affine, tag: u32) Allocator.Error!csg.Solid {
        const held = self.app.meshOf(handle) orelse return .{};
        const positions = try self.arena.alloc([3]f32, held.vertices.len);
        for (held.vertices, positions) |v, *p| p.* = v.position;
        return csg.mesh(self.arena, positions, held.indices, place, tag);
    }
};

/// The mesh `top` comes to, made now: with lightmap UVs if `lightmapped`.
fn build(app: *App, top: Entity, lightmapped: bool) Allocator.Error!*mesh.Kept {
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    var building: Building = .{ .app = app, .arena = arena_state.allocator() };
    const shape = app.world.get(top, CSGShape3D).?.*;
    const solid = try building.solidOf(top, shape, .identity, .none, 0);
    var made = try meshOfSolid(app.gpa, solid, building.materials.items);
    errdefer made.deinit(app.gpa);
    if (lightmapped) try lightmap_uv.unwrap(app.gpa, &made);
    const kept = try app.gpa.create(mesh.Kept);
    kept.* = .{ .mesh = made, .stamp = app.meshes.stamp() };
    return kept;
}

/// A mesh of `solid`, its triangles tagged with their place among
/// `materials`: a surface for each, the corners they share one, a picture
/// laid flat on each face and its tangents - all worked out by the solids'
/// module.
fn meshOfSolid(gpa: Allocator, solid: csg.Solid, materials: []const MaterialHandle) Allocator.Error!mesh.Mesh {
    var made = try solid.indexed(gpa);
    defer made.deinit(gpa);
    const vertices = try gpa.alloc(mesh.Vertex, made.positions.len);
    errdefer gpa.free(vertices);
    for (vertices, made.positions, made.normals, made.uvs, made.tangents) |*v, p, n, uv, t| {
        v.* = .{ .position = p, .normal = n, .uv = uv, .tangent = t };
    }
    const indices = try gpa.dupe(u32, made.indices);
    errdefer gpa.free(indices);
    const surfaces = try gpa.alloc(mesh.Surface, @max(made.runs.len, 1));
    errdefer gpa.free(surfaces);
    if (made.runs.len == 0) surfaces[0] = .{ .first_index = 0, .index_count = 0 };
    for (made.runs, surfaces[0..made.runs.len]) |run, *surface| {
        surface.* = .{ .first_index = run.first, .index_count = run.count, .material = if (run.tag < materials.len) materials[run.tag] else .none };
    }
    // Every index is a vertex made above, and every surface a run of them
    // in order: nothing `adopt` refuses.
    return mesh.Mesh.adopt(vertices, indices, surfaces) catch unreachable;
}
