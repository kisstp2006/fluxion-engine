// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself reads. `Transform2D` and `Parent` -
//! where a thing is, and what it hangs from - are here; the ones drawn from
//! are in `render/render_components.zig` and the physics' in
//! `physics/physics_components.zig`, each beside what reads it, and every
//! one of them is listed here too. A game declares its own beside them.
//!
//! ```zig
//! _ = try app.world.spawnWith(.{
//!     Transform2D{ .x = 320, .y = 180 },
//!     Sprite{ .texture = hero, .width = 48, .height = 48 },
//! });
//! ```
//!
//! All plain data, as fluxion-ecs requires - no pointers, nothing that owns
//! memory - so a row moves with a `memcpy` and a world saves to a file. The
//! coordinate system is the interface's: `+x` right, `+y` down, and a
//! positive rotation turns `+x` towards `+y`, which is clockwise on screen.
//!
//! Each is described to fluxion-reflect as well, for what reads a component
//! it was not compiled against - an inspector, a console: `reflect_name` is
//! the name a scene gives it, and `reflect_fields` says what a field's number
//! means where the name does not - a range, an angle, a unit, layers, a zero
//! that is not zero. See `attr`.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const attr = @import("../reflect/attr.zig");

// The components drawn from, and the ones the physics reads: each beside
// what reads it, and listed here with the rest.
pub const Region = @import("../render/render_components.zig").Region;
pub const Sprite = @import("../render/render_components.zig").Sprite;
pub const Text2D = @import("../render/render_components.zig").Text2D;
pub const Camera2D = @import("../render/render_components.zig").Camera2D;
pub const RenderView = @import("../render/render_components.zig").RenderView;
pub const MeshInstance3D = @import("../render/render3d_components.zig").MeshInstance3D;
pub const PrimitiveMesh3D = @import("../render/render3d_components.zig").PrimitiveMesh3D;
pub const Material3D = @import("../render/render3d_components.zig").Material3D;
pub const Camera3D = @import("../render/render3d_components.zig").Camera3D;
pub const DirectionalLight3D = @import("../render/render3d_components.zig").DirectionalLight3D;
pub const ViewTexture = @import("../render/render_components.zig").ViewTexture;
pub const RigidBody2D = @import("../physics/physics_components.zig").RigidBody2D;
pub const CharacterBody2D = @import("../physics/physics_components.zig").CharacterBody2D;
pub const Collider2D = @import("../physics/physics_components.zig").Collider2D;
pub const Area2D = @import("../physics/physics_components.zig").Area2D;
pub const RayCast2D = @import("../physics/physics_components.zig").RayCast2D;

/// Where a thing is in 3D. See `scene/transform3d.zig`.
pub const Transform3D = @import("transform3d.zig").Transform3D;
pub const Rotation = @import("transform3d.zig").Rotation;

/// Re-exported because a transform names the entity it hangs from.
pub const Entity = ecs.Entity;

/// A colour, four floats from zero to one. See `color`.
pub const Color = @import("../math/color.zig").Color;

/// What an entity hangs from: the one tree every entity is in, whatever it
/// is - where a sprite is placed from, which control holds a button, what a
/// timer or a sound belongs to. An entity without one is a root.
///
/// ```zig
/// const tank = try world.spawnWith(.{ Transform2D.at(100, 100), Sprite.of(hull) });
/// _ = try world.spawnWith(.{ Transform2D.at(0, -6), Parent.of(tank), Sprite.of(turret) });
/// ```
///
/// When the parent is despawned, so is this, at the end of that frame - and
/// whatever hangs from this in turn. `App.setParent` hangs an entity from
/// another, keeping names unique among siblings; the tree `App.childrenOf`
/// walks is built again whenever an entity is spawned, despawned, or gains
/// or loses a component, and at once after `setParent`. A parent written
/// straight into the component is seen after the next of those, and keeps
/// no name free: an inspector shows it and leaves the change to `setParent`.
pub const Parent = extern struct {
    entity: Entity = .none,

    pub const reflect_name = "Parent";
    pub const reflect_fields = .{
        .entity = .{ attr.ReadOnly{}, attr.Doc{ .text = "Changed by moving the entity in the tree" } },
    };

    pub fn of(parent: Entity) Parent {
        return .{ .entity = parent };
    }
};

/// Where a thing is, how big and which way round.
///
/// The numbers are local - in the space of the entity it hangs from, its
/// `Parent` - and `App.worldTransform` gives the world's. A parent with no
/// `Transform2D` places nothing: the numbers are the world's.
pub const Transform2D = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Radians. Positive turns `+x` towards `+y`: clockwise on screen.
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    /// Whether this turns with its parent. Its offset turns either way; off is
    /// for a shadow or a name plate that should not tip over.
    inherit_rotation: bool = true,

    /// Whether the parent's scale multiplies this one's.
    inherit_scale: bool = true,

    /// Draw this between its last two fixed steps, for anything moved in
    /// `.fixed` - otherwise a 60 Hz step stutters on a 144 Hz screen. The
    /// engine keeps where it was; see `hierarchy.Snapshot`.
    interpolate: bool = false,

    /// How many links of a chain are followed before giving up: enough for a
    /// skeleton, few enough that a cycle is caught within a frame.
    pub const max_depth: u8 = 16;

    pub const reflect_name = "Transform2D";
    pub const reflect_fields = .{
        .rotation = .{ attr.Angle{}, attr.Doc{ .text = "Clockwise on screen" } },
    };
    pub const reflect_methods = .{ .translate = .{attr.Params{ .names = &.{ "dx", "dy" } }} };

    /// A transform at a point, unrotated and unscaled.
    pub fn at(x: f32, y: f32) Transform2D {
        return .{ .x = x, .y = y };
    }

    /// Move by an amount, in whatever space this transform is in.
    pub fn translate(self: *Transform2D, dx: f32, dy: f32) void {
        self.x += dx;
        self.y += dy;
    }

    /// The same transform, drawn between fixed steps.
    pub fn interpolated(self: Transform2D) Transform2D {
        var out = self;
        out.interpolate = true;
        return out;
    }

    /// The same scale on both axes.
    pub fn scaled(self: Transform2D, factor: f32) Transform2D {
        var out = self;
        out.scale_x *= factor;
        out.scale_y *= factor;
        return out;
    }

    /// Turn a point in this transform's own space into its parent's.
    pub fn apply(self: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
        const sx = x * self.scale_x;
        const sy = y * self.scale_y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        return .{
            .x = self.x + sx * c - sy * s,
            .y = self.y + sx * s + sy * c,
        };
    }

    /// `apply` undone: a point in the parent's space, in this transform's own.
    /// A scale of zero is left out rather than divided by.
    pub fn unapply(self: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
        const dx = x - self.x;
        const dy = y - self.y;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        const rx = dx * c + dy * s;
        const ry = dy * c - dx * s;
        return .{
            .x = if (self.scale_x != 0) rx / self.scale_x else rx,
            .y = if (self.scale_y != 0) ry / self.scale_y else ry,
        };
    }

    /// Where `local` ends up, given where its parent ended up.
    pub fn compose(parent: Transform2D, local: Transform2D) Transform2D {
        const placed = parent.apply(local.x, local.y);
        return .{
            .x = placed.x,
            .y = placed.y,
            .rotation = if (local.inherit_rotation)
                parent.rotation + local.rotation
            else
                local.rotation,
            .scale_x = if (local.inherit_scale)
                parent.scale_x * local.scale_x
            else
                local.scale_x,
            .scale_y = if (local.inherit_scale)
                parent.scale_y * local.scale_y
            else
                local.scale_y,
            .interpolate = local.interpolate,
        };
    }
};

test "a transform maps its own space into the world" {
    const t: Transform2D = .{ .x = 10, .y = 20, .rotation = std.math.pi / 2.0, .scale_x = 2, .scale_y = 2 };
    const p = t.apply(1, 0);

    // A quarter turn takes +x to +y, and the scale doubled the length.
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 22), p.y, 0.0001);
}

test "every engine component is one the world will accept" {
    // The check the world makes on first use, brought forward into a test.
    ecs.component.check(Transform2D);
    ecs.component.check(Sprite);
    ecs.component.check(Camera2D);
    ecs.component.check(Text2D);
    ecs.component.check(RigidBody2D);
    ecs.component.check(Collider2D);
}

test "what an inspector shows a field by is on the field" {
    const reflect = @import("fluxion_reflect");
    try testing.expect(reflect.typeOf(Transform2D).field("rotation").?.attribute(attr.Angle) != null);
    try testing.expect(reflect.typeOf(Transform2D).field("x").?.attribute(attr.Angle) == null);
    // Named from the project's list of physics layers, and dragged as a box
    // from where the collider is placed.
    try testing.expectEqual(attr.Layers.Names.physics_2d, reflect.typeOf(Collider2D).field("collision_mask").?.attribute(attr.Layers).?.names);
    try testing.expect(reflect.typeOf(Collider2D).field("extents").?.attribute(attr.Extents) != null);
    try testing.expectEqualStrings("offset", reflect.typeOf(Collider2D).attribute(attr.Placement).?.offset);
    try testing.expectEqualStrings("px", reflect.typeOf(Text2D).field("size").?.attribute(attr.Unit).?.text);
    try testing.expectEqual(@as(f64, 1), reflect.typeOf(Collider2D).field("bounce").?.attribute(attr.Range).?.max);

    // The words of a label are kept beside it, and they may run over several
    // lines.
    try testing.expect(reflect.typeOf(Text2D).field("text") == null);
    try testing.expect(reflect.typeOf(Text2D).attribute(attr.Text).?.multiline);
    try testing.expectEqualStrings("text", reflect.typeOf(Text2D).attribute(attr.Text).?.name);
}

test "unapply takes a point back to where apply found it" {
    const t: Transform2D = .{ .x = 10, .y = -4, .rotation = 0.7, .scale_x = 2, .scale_y = 0.5 };
    const out = t.apply(3, 5);
    const back = t.unapply(out.x, out.y);
    try testing.expectApproxEqAbs(@as(f32, 3), back.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5), back.y, 0.0001);
}

test "a child is carried round by its parent" {
    const parent: Transform2D = .{ .x = 100, .y = 100, .rotation = std.math.pi / 2.0 };
    const local: Transform2D = .at(10, 0);

    // A quarter turn puts the child below the parent, not to its right.
    const placed = Transform2D.compose(parent, local);
    try testing.expectApproxEqAbs(@as(f32, 100), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 110), placed.y, 0.0001);
    try testing.expectApproxEqAbs(parent.rotation, placed.rotation, 0.0001);
}

test "a child that does not inherit rotation is still carried round" {
    const parent: Transform2D = .{ .rotation = std.math.pi / 2.0 };
    var local: Transform2D = .at(10, 0);
    local.inherit_rotation = false;

    const placed = Transform2D.compose(parent, local);
    try testing.expectApproxEqAbs(@as(f32, 0), placed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), placed.y, 0.0001);
    try testing.expectEqual(@as(f32, 0), placed.rotation);
}

test "scale multiplies down the chain" {
    const parent: Transform2D = .{ .scale_x = 2, .scale_y = 2 };
    const local: Transform2D = .{ .scale_x = 3, .scale_y = 3 };
    try testing.expectEqual(@as(f32, 6), Transform2D.compose(parent, local).scale_x);
}
