// SPDX-License-Identifier: BSD-3-Clause

//! The components the 3D physics reads and writes: `RigidBody3D`,
//! `CharacterBody3D`, `Collider3D`, `Area3D` and `RayCast3D` - the 2D ones'
//! counterparts, in metres, with `+y` up. See `scene/components.zig` for
//! what every component is.

const std = @import("std");

const math = @import("fluxion_math");
const physics3d = @import("fluxion_physics3d");
const MouseButton = @import("fluxion_platform").MouseButton;

const attr = @import("../reflect/attr.zig");
const InputEvent = @import("../input/input_event.zig").InputEvent;
const Entity = @import("fluxion_ecs").Entity;
const Rotation = @import("../scene/transform3d.zig").Rotation;
const MeshHandle = @import("../render/mesh.zig").MeshHandle;

/// Something that moves as a solid object in the 3D world: it falls, is
/// pushed, rolls and bounces. What it collides with is its `Collider3D`,
/// on this entity or on the ones hanging from it.
///
/// ```zig
/// _ = try world.spawnWith(.{
///     Transform3D.at(0, 4, 0).interpolated(),
///     MeshInstance3D{}, PrimitiveMesh3D{ .shape = .box },
///     RigidBody3D{},
///     Collider3D{}, // a box of one metre
/// });
/// ```
///
/// The body is in the world's space, so a moving parent does not carry it.
/// After every fixed step its place and turn go into the transform and its
/// speeds into `linear_velocity` and `angular_velocity`; writing either
/// moves the body or sets it going.
pub const RigidBody3D = extern struct {
    /// Changing it makes the body anew.
    type: Type = .dynamic,
    /// Metres a second.
    linear_velocity: math.Vec3 = .zero,
    /// Radians a second about each axis.
    angular_velocity: math.Vec3 = .zero,
    /// How much of its speed it loses a second: 0.1 slows it by a tenth.
    /// Minus one takes the project's `default_linear_damp`.
    linear_damp: f32 = -1,
    /// The same for its spin; minus one is `default_angular_damp`.
    angular_damp: f32 = -1,
    /// Nought floats, minus one rises.
    gravity_scale: f32 = 1,
    /// It moves but never turns.
    lock_rotation: bool = false,
    /// Whether it may stop being worked out while it lies still.
    can_sleep: bool = true,
    /// Whether the pointer can pick it: false on a body by default, and
    /// true on an `Area3D`.
    input_pickable: bool = false,

    /// Static never moves; kinematic moves at its velocity and nothing
    /// pushes it; dynamic is pushed by everything.
    pub const Type = physics3d.BodyType;

    /// What the pointer did over it, and which of its colliders it was
    /// over. A body is picked only with `input_pickable`.
    pub const signals = .{
        // What the pointer did over it - a button, motion, the wheel - with
        // the collider it was over: picked by a ray from the current camera.
        .input_event = struct { event: InputEvent, shape: Entity },
        // The pointer came over it, or went off it.
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        // A mouse button went down over it.
        .pressed = struct { button: MouseButton },
        // The button that went down over it came up, wherever the pointer
        // is then.
        .released = struct { button: MouseButton },
        // The button that went down over it came up over it: a click.
        .clicked = struct { button: MouseButton },
    };

    pub const reflect_name = "RigidBody3D";
    pub const reflect_fields = .{
        .linear_velocity = .{ attr.Unit{ .text = "m/s" }, attr.Doc{ .text = "Metres a second" } },
        .angular_velocity = .{ attr.Unit{ .text = "rad/s" }, attr.Doc{ .text = "Radians a second about each axis" } },
        .linear_damp = .{attr.Doc{ .text = "Speed lost a second; -1 is the project's" }},
        .angular_damp = .{attr.Doc{ .text = "Spin lost a second; -1 is the project's" }},
        .gravity_scale = .{attr.Doc{ .text = "Zero floats, minus one rises" }},
        .lock_rotation = .{attr.Doc{ .text = "It moves but never turns" }},
        .input_pickable = .{attr.Doc{ .text = "Whether the pointer can pick it" }},
    };
};

/// The shape a 3D body collides with. On an entity with a `RigidBody3D`,
/// a `CharacterBody3D` or an `Area3D` it is that body's, and on one hanging
/// from such an entity it is part of that body, where the entity is.
/// Anywhere else it is a static body of its own: a wall, a floor, a level.
///
/// Its size is in the entity's own space, before the transform's scale.
/// `convex` and `mesh` are made from a mesh - `mesh`, or the one the
/// `MeshInstance3D` beside it draws: a hull round it, which a body can be,
/// or its very triangles, which only a static body can.
///
/// Two colliders touch when either one's `collision_mask` has the other's
/// `collision_layer`. A pair's friction is the smaller of the two, and its
/// bounce the two added, no more than one.
pub const Collider3D = extern struct {
    shape: Shape = .box,
    /// Half a box's size each way.
    extents: math.Vec3 = .init(0.5, 0.5, 0.5),
    /// A sphere's, a capsule's and a cylinder's.
    radius: f32 = 0.5,
    /// A capsule's and a cylinder's whole height along the entity's `y`,
    /// a capsule's round ends included.
    height: f32 = 2,
    /// What `convex` and `mesh` are made from; none takes the mesh the
    /// `MeshInstance3D` beside it draws.
    mesh: MeshHandle = .none,
    /// From the entity's origin, before its scale.
    offset: math.Vec3 = .zero,
    /// Its turn on the entity.
    rotation: Rotation = .identity,
    /// How much it grips what slides on it, from nought for ice to one.
    friction: f32 = 0.6,
    /// How much of the speed a hit gives back: nought a beanbag, one a
    /// superball.
    bounce: f32 = 0,
    /// Mass a cubic metre.
    density: f32 = 1,
    /// Reports what overlaps it and pushes nothing: a trigger, a pickup.
    sensor: bool = false,
    /// Not there at all while on.
    disabled: bool = false,
    collision_layer: u32 = 1,
    collision_mask: u32 = 1,

    pub const Shape = enum(u8) { box, sphere, capsule, cylinder, convex, mesh };

    pub const reflect_name = "Collider3D";
    pub const reflect_fields = .{
        .shape = .{attr.Doc{ .text = "A box, a ball, a capsule or a cylinder standing along y, a hull round a mesh, or a mesh's own triangles - the last for what never moves" }},
        .extents = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Half a box's size each way" } },
        .radius = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "A sphere's, a capsule's and a cylinder's" } },
        .height = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "A capsule's and a cylinder's whole height, round ends included" } },
        .mesh = .{attr.Doc{ .text = "What a convex or a mesh collider is made from; none is the MeshInstance3D's" }},
        .offset = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "From the entity's origin" } },
        .friction = .{attr.Range{ .min = 0, .max = 1 }},
        .bounce = .{attr.Range{ .min = 0, .max = 1 }},
        .density = .{attr.Doc{ .text = "Mass a cubic metre" }},
        .disabled = .{attr.Doc{ .text = "Off, nothing touches it" }},
        .collision_layer = .{ attr.Layers{ .names = .physics_3d }, attr.Doc{ .text = "The layers it is on" } },
        .collision_mask = .{ attr.Layers{ .names = .physics_3d }, attr.Doc{ .text = "The layers it looks for" } },
    };

    pub fn box(half: math.Vec3) Collider3D {
        return .{ .extents = half };
    }

    pub fn sphere(radius: f32) Collider3D {
        return .{ .shape = .sphere, .radius = radius };
    }

    /// A capsule `height` tall, round ends included, and `radius` round.
    pub fn capsule(radius: f32, height: f32) Collider3D {
        return .{ .shape = .capsule, .radius = radius, .height = height };
    }

    pub fn cylinder(radius: f32, height: f32) Collider3D {
        return .{ .shape = .cylinder, .radius = radius, .height = height };
    }
};

/// A body the game moves rather than the physics: a player, a guard. Its
/// `velocity` is what `App.moveAndSlide` moves it by, a step at a time,
/// stopping at what it meets and sliding along it; what it stands on and
/// what it is against are said after. Its shapes are its `Collider3D`s, a
/// capsule most often, and nothing pushes it. See `character3d.zig`.
pub const CharacterBody3D = extern struct {
    /// Metres a second. What went into a wall or a floor is taken off it by
    /// a move.
    velocity: math.Vec3 = .zero,
    /// Which way is up: a floor faces it, a ceiling away from it.
    up_direction: math.Vec3 = .init(0, 1, 0),
    motion_mode: MotionMode = .grounded,
    /// The steepest slope that is still a floor.
    floor_max_angle: f32 = std.math.pi / 4.0,
    /// How far below it a floor is kept to, walking off the top of a slope
    /// or down a step. Nought never keeps to one.
    floor_snap_length: f32 = 0.1,
    /// Standing on a slope, it stays: it slides down only what it walks.
    floor_stop_on_slope: bool = true,
    /// How high an edge it walks up onto from the floor - a kerb, a stair -
    /// rather than stopping at it. Nought climbs only slopes.
    max_step_height: f32 = 0.3,
    /// How far it keeps from what it touches.
    safe_margin: f32 = 0.001,
    /// How many times one move may stop and slide on.
    max_slides: u32 = 4,
    /// What the last move found.
    on_floor: bool = false,
    /// Whether the last move ran it into a wall.
    on_wall: bool = false,
    /// Whether the last move ran it into a ceiling.
    on_ceiling: bool = false,
    /// Out of the floor it stands on, when it does.
    floor_normal: math.Vec3 = .zero,
    /// Out of the wall it is against, when it is.
    wall_normal: math.Vec3 = .zero,

    /// Grounded: floors, walls and ceilings. Floating: everything it meets
    /// is a wall - something flying, swimming.
    pub const MotionMode = enum(u8) { grounded, floating };

    pub const reflect_name = "CharacterBody3D";
    pub const reflect_fields = .{
        .velocity = .{ attr.Unit{ .text = "m/s" }, attr.Doc{ .text = "Metres a second: what moveAndSlide moves it by" } },
        .up_direction = .{attr.Doc{ .text = "A floor faces it, a ceiling away from it" }},
        .motion_mode = .{attr.Doc{ .text = "Grounded has floors and ceilings; floating, only walls" }},
        .floor_max_angle = .{ attr.Angle{}, attr.Doc{ .text = "The steepest slope that is still a floor" } },
        .floor_snap_length = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How far below it a floor is kept to; nought never" } },
        .floor_stop_on_slope = .{attr.Doc{ .text = "Standing on a slope, it does not slide down it" }},
        .max_step_height = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0, .max = 10 }, attr.Doc{ .text = "How high a kerb or a stair it walks up onto from the floor; nought climbs only slopes" } },
        .safe_margin = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How far it keeps from what it touches" } },
        .on_floor = .{attr.ReadOnly{}},
        .on_wall = .{attr.ReadOnly{}},
        .on_ceiling = .{attr.ReadOnly{}},
        .floor_normal = .{attr.ReadOnly{}},
        .wall_normal = .{attr.ReadOnly{}},
    };
};

/// A place in the 3D world that tells what is in it, and pushes nothing: a
/// trigger, a pickup, a door's threshold - and a thing the pointer can go
/// onto, leave and press: a lever, a button on a wall.
///
/// Its shapes are its own `Collider3D` and the ones hanging from it, every
/// one a sensor whatever the collider says. In the physics it is a
/// kinematic body that goes where its transform goes. An entity may have an
/// `Area3D` or a `RigidBody3D`, not both.
pub const Area3D = extern struct {
    /// Whether it says what is in it.
    monitoring: bool = true,
    /// Whether other areas see it.
    monitorable: bool = true,
    /// Whether the pointer can pick it; true for an area by default.
    input_pickable: bool = true,
    /// Whether the pointer is over it now, and whether a mouse button went
    /// down on it and is not up yet. Read-only, and never saved.
    hovered: bool = false,
    held: bool = false,

    pub const signals = .{
        // A body came into it: the first of its colliders to touch.
        .body_entered = struct { body: Entity },
        // A body left it: the last of its colliders in it went out.
        .body_exited = struct { body: Entity },
        // One collider of a body, `body_shape`, came into one of its own,
        // `local_shape`.
        .body_shape_entered = struct { body: Entity, body_shape: Entity, local_shape: Entity },
        // One collider of a body went out of one of its own.
        .body_shape_exited = struct { body: Entity, body_shape: Entity, local_shape: Entity },
        // Another area that is `monitorable` came into it.
        .area_entered = struct { area: Entity },
        // Another area left it.
        .area_exited = struct { area: Entity },
        // One collider of another area came into one of its own.
        .area_shape_entered = struct { area: Entity, area_shape: Entity, local_shape: Entity },
        // One collider of another area went out of one of its own.
        .area_shape_exited = struct { area: Entity, area_shape: Entity, local_shape: Entity },

        // What the pointer did over it - a button, motion, the wheel - with
        // the collider it was over: picked by a ray from the current camera.
        .input_event = struct { event: InputEvent, shape: Entity },
        // The pointer came over it, or went off it.
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        // A mouse button went down over it.
        .pressed = struct { button: MouseButton },
        // The button that went down over it came up, wherever the pointer
        // is then.
        .released = struct { button: MouseButton },
        // The button that went down over it came up over it: a click.
        .clicked = struct { button: MouseButton },
    };

    pub const reflect_name = "Area3D";
    pub const reflect_fields = .{
        .monitoring = .{attr.Doc{ .text = "Whether it says what is in it" }},
        .monitorable = .{attr.Doc{ .text = "Whether other areas see it" }},
        .input_pickable = .{attr.Doc{ .text = "Whether the pointer can pick it" }},
        .hovered = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether the pointer is over it" } },
        .held = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether a mouse button went down on it and is not up yet" } },
    };
};

/// A ray from the entity, asked once a fixed step what it hits first: the
/// ground under a foot, a wall ahead, whether anything stands between a
/// guard and the player. Beside a `Transform3D`; `target` turns and scales
/// with it.
pub const RayCast3D = extern struct {
    /// Whether it casts its ray each step.
    enabled: bool = true,
    /// Where the ray ends, in the entity's own space.
    target: math.Vec3 = .init(0, -1, 0),
    collision_mask: u32 = 0xFFFF_FFFF,
    /// Whether an area stops it, as a body does.
    hit_areas: bool = false,
    /// Whether the body it hangs from - or is - is passed over.
    exclude_parent: bool = true,

    /// What it found at the last fixed step. Read-only, and never saved.
    colliding: bool = false,
    collider: Entity = .none,
    shape: Entity = .none,
    point: math.Vec3 = .zero,
    normal: math.Vec3 = .zero,

    pub const reflect_name = "RayCast3D";
    pub const reflect_fields = .{
        .target = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Where the ray ends, in the entity's own space" } },
        .collision_mask = .{ attr.Layers{ .names = .physics_3d }, attr.Doc{ .text = "The layers it looks for" } },
        .hit_areas = .{attr.Doc{ .text = "Whether an area stops it" }},
        .exclude_parent = .{attr.Doc{ .text = "Whether the body it is on is passed over" }},
        .colliding = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether it hit something at the last fixed step" } },
        .collider = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "The body or area it hit" } },
        .shape = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "The collider it hit" } },
        .point = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Where, in the world" } },
        .normal = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Out of the side it hit" } },
    };
};
