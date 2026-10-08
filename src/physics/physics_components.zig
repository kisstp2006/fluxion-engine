// SPDX-License-Identifier: BSD-3-Clause

//! The components the physics reads and writes: `RigidBody2D`,
//! `CharacterBody2D`, `Collider2D`, `Area2D` and `RayCast2D`. See
//! `scene/components.zig` for what every component is.

const std = @import("std");

const math = @import("fluxion_math");
const physics = @import("fluxion_physics");
const MouseButton = @import("fluxion_platform").MouseButton;

const attr = @import("../reflect/attr.zig");
const InputEvent = @import("../input/input_event.zig").InputEvent;
const Entity = @import("fluxion_ecs").Entity;

/// Something that moves as a solid object: it falls, is pushed and bounces.
/// What it collides with is its `Collider2D`, on this entity or on the ones
/// hanging from it.
///
/// ```zig
/// _ = try world.spawnWith(.{
///     Transform2D.at(320, 0).interpolated(),
///     Sprite.of(crate),
///     RigidBody2D{},
///     Collider2D{}, // the size of the sprite
/// });
/// ```
///
/// The body is in the world's space, so a moving parent does not carry it.
/// After every fixed step its place goes into the transform and its speed
/// into `linear_velocity`; writing either moves the body or sets it going.
pub const RigidBody2D = extern struct {
    /// Changing it makes the body anew, and the joints to the old one go.
    type: Type = .dynamic,
    /// Units a second.
    linear_velocity: math.Vec2 = .zero,
    /// Radians a second, clockwise on screen.
    angular_velocity: f32 = 0,
    /// How much of its speed it loses a second: 0.1 slows it by a tenth. Minus one takes the project's `default_linear_damp`.
    linear_damp: f32 = -1,
    /// The same for its spin; minus one is `default_angular_damp`.
    angular_damp: f32 = -1,
    /// Zero floats, minus one rises.
    gravity_scale: f32 = 1,
    fixed_rotation: bool = false,
    can_sleep: bool = true,
    /// Continuous collision detection. Off, a fast body is still
    /// stopped by the level; on, by the other moving bodies too.
    continuous_cd: ContinuousCd = .disabled,

    /// Whether the pointer can pick it: false on a body by default, and
    /// true on an `Area2D`; picking asks it of whichever object a collider
    /// belongs to.
    input_pickable: bool = false,

    /// Static never moves; kinematic moves at its velocity and nothing
    /// pushes it; dynamic is pushed by everything.
    pub const Type = physics.BodyType;

    /// A ray and a shape cast are both one sweep here.
    pub const ContinuousCd = enum(u8) { disabled, cast_ray, cast_shape };

    /// What the pointer did over it, and which of its colliders it was
    /// over. A body is picked only with `input_pickable`; see
    /// `App.physics_object_picking`.
    pub const signals = .{
        // What the pointer did over it - a button, motion, the wheel - with
        // the collider it was over; see `App.physics_object_picking`.
        .input_event = struct { event: InputEvent, shape: Entity },
        // The pointer came over it, or went off it.
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        // The pointer came over one of its colliders, or went off it.
        .mouse_shape_entered = struct { shape: Entity },
        .mouse_shape_exited = struct { shape: Entity },
        // A mouse button went down over it.
        .pressed = struct { button: MouseButton },
        // The button that went down over it came up, wherever the pointer
        // is then.
        .released = struct { button: MouseButton },
        // The button that went down over it came up over it: a click.
        .clicked = struct { button: MouseButton },
    };

    pub const reflect_name = "RigidBody2D";
    pub const reflect_fields = .{
        .linear_velocity = .{ attr.Unit{ .text = "/s" }, attr.Doc{ .text = "World units a second" } },
        .angular_velocity = .{ attr.Angle{}, attr.Unit{ .text = "/s" }, attr.Doc{ .text = "Clockwise on screen" } },
        .linear_damp = .{attr.Doc{ .text = "Speed lost a second; -1 is the project's" }},
        .angular_damp = .{attr.Doc{ .text = "Spin lost a second; -1 is the project's" }},
        .gravity_scale = .{attr.Doc{ .text = "Zero floats, minus one rises" }},
        .continuous_cd = .{attr.Doc{ .text = "Swept against moving bodies too" }},
        .input_pickable = .{attr.Doc{ .text = "Whether the pointer can pick it" }},
    };
};

/// The shape a body collides with. On an entity with a `RigidBody2D` it is
/// that body's, and on one hanging from such an entity it is part of that
/// body, where the entity is. Anywhere else it is a static body of its own:
/// a wall, a floor tile.
///
/// Two colliders touch when either one's `collision_mask` has the other's
/// `collision_layer`. A pair's friction is the smaller of the two, and its
/// bounce the two added, no more than one.
pub const Collider2D = extern struct {
    shape: Shape = .rectangle,
    /// Half a rectangle's width and height, before the transform's scale.
    /// Zero takes the sprite's size, and centres the shape on the sprite. A
    /// capsule's `y` is half its whole height, round ends and all.
    extents: math.Vec2 = .zero,
    /// A circle's, and a capsule's round ends'. Zero is half the sprite's
    /// width, centred on the sprite.
    radius: f32 = 0,
    /// From the entity's origin, before its scale.
    offset: math.Vec2 = .zero,
    /// A rectangle's turn on the entity.
    rotation: f32 = 0,
    friction: f32 = 1,
    /// How much of the speed a hit gives back: zero a beanbag, one a
    /// superball.
    bounce: f32 = 0,
    /// Mass per square unit.
    density: f32 = 1,
    /// Reports what overlaps it and pushes nothing: a trigger, a pickup.
    sensor: bool = false,
    /// Not there at all while on: nothing touches it, and it weighs nothing.
    disabled: bool = false,
    /// Held from one side only, a platform to jump up through: what comes
    /// onto it from its entity's `-y`, up the screen, stands on it; what
    /// comes from anywhere else goes through. Decided when the two first
    /// touch, and kept while they touch.
    one_way_collision: bool = false,
    /// The layers it is on, and the layers it looks for.
    collision_layer: u32 = 1,
    collision_mask: u32 = 1,

    /// A capsule stands along the entity's `y`, round at both ends: what a
    /// character is, sliding over a step's edge rather than catching on it.
    pub const Shape = enum(u8) { rectangle, circle, capsule };

    pub const reflect_name = "Collider2D";
    pub const reflect_attributes = .{attr.Placement{ .offset = "offset", .rotation = "rotation" }};
    pub const reflect_fields = .{
        .extents = .{
            attr.Extents{ .when = .{ .field = "shape", .is = &.{"rectangle"} } },
            attr.Capsule{ .radius = "radius", .when = .{ .field = "shape", .is = &.{"capsule"} } },
            attr.Doc{ .text = "Half the size; zero is the sprite's" },
        },
        .radius = .{ attr.Radius{ .when = .{ .field = "shape", .is = &.{"circle"} } }, attr.Doc{ .text = "Zero is half the sprite's width" } },
        .rotation = .{attr.Angle{}},
        .friction = .{attr.Range{ .min = 0, .max = 1 }},
        .bounce = .{attr.Range{ .min = 0, .max = 1 }},
        .density = .{attr.Doc{ .text = "Mass per square unit" }},
        .disabled = .{attr.Doc{ .text = "Off, nothing touches it" }},
        .one_way_collision = .{attr.Doc{ .text = "Held only from above" }},
        .collision_layer = .{ attr.Layers{ .names = .physics_2d }, attr.Doc{ .text = "The layers it is on" } },
        .collision_mask = .{ attr.Layers{ .names = .physics_2d }, attr.Doc{ .text = "The layers it looks for" } },
    };

    /// A rectangle of these half sizes, its `extents`.
    pub fn rectangle(half_width: f32, half_height: f32) Collider2D {
        return .{ .extents = .init(half_width, half_height) };
    }

    pub fn circle(radius: f32) Collider2D {
        return .{ .shape = .circle, .radius = radius };
    }

    /// A capsule `height` tall, round ends included, and `radius` round.
    pub fn capsule(radius: f32, height: f32) Collider2D {
        return .{ .shape = .capsule, .radius = radius, .extents = .init(radius, height / 2) };
    }
};

/// A body the game moves rather than the physics: a player, a guard walking
/// a corridor. Its `velocity` is what `App.moveAndSlide` moves it by, a step
/// at a time, stopping at what it meets and sliding along it; what it stands
/// on and what it is against are said after. Its shapes are its
/// `Collider2D`s, as a rigid body's are, and nothing pushes it. See
/// `character.zig`.
pub const CharacterBody2D = extern struct {
    /// Units a second. What went into a wall or a floor is taken off it by a
    /// move.
    velocity: math.Vec2 = .zero,
    /// Which way is up: a floor faces it, a ceiling faces away. Up the
    /// screen.
    up_direction: math.Vec2 = .init(0, -1),
    motion_mode: MotionMode = .grounded,
    /// The steepest slope that is still a floor.
    floor_max_angle: f32 = std.math.pi / 4.0,
    /// How far below it a floor is kept to, walking off the top of a slope
    /// or down a step. Nought never keeps to one.
    floor_snap_length: f32 = 4,
    /// Standing on a slope, it stays: it slides down only what it walks.
    floor_stop_on_slope: bool = true,
    /// How far it keeps from what it touches.
    safe_margin: f32 = 0.5,
    /// How many times one move may stop and slide on.
    max_slides: u32 = 4,
    /// What the last move found.
    on_floor: bool = false,
    on_wall: bool = false,
    on_ceiling: bool = false,
    /// Out of the floor it stands on, and the wall it is against, when it
    /// is.
    floor_normal: math.Vec2 = .zero,
    wall_normal: math.Vec2 = .zero,

    /// Grounded: floors, walls and ceilings, for a game seen from the side.
    /// Floating: everything it meets is a wall, for a game seen from above.
    pub const MotionMode = enum(u8) { grounded, floating };

    pub const reflect_name = "CharacterBody2D";
    pub const reflect_fields = .{
        .velocity = .{ attr.Unit{ .text = "/s" }, attr.Doc{ .text = "World units a second: what moveAndSlide moves it by" } },
        .up_direction = .{attr.Doc{ .text = "A floor faces it, a ceiling away from it" }},
        .motion_mode = .{attr.Doc{ .text = "Grounded has floors and ceilings; floating, seen from above, only walls" }},
        .floor_max_angle = .{ attr.Angle{}, attr.Doc{ .text = "The steepest slope that is still a floor" } },
        .floor_snap_length = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "How far below it a floor is kept to; nought never" } },
        .floor_stop_on_slope = .{attr.Doc{ .text = "Standing on a slope, it does not slide down it" }},
        .safe_margin = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "How far it keeps from what it touches" } },
        .on_floor = .{attr.ReadOnly{}},
        .on_wall = .{attr.ReadOnly{}},
        .on_ceiling = .{attr.ReadOnly{}},
        .floor_normal = .{attr.ReadOnly{}},
        .wall_normal = .{attr.ReadOnly{}},
    };
};

/// A place that tells what is in it, and pushes nothing. A trigger, a
/// pickup, a hurtbox, a door's threshold - and a thing in the world the
/// pointer can go onto, leave and press, with no interface at all: a lever,
/// a card on a table.
///
/// ```zig
/// const trap = try world.spawnWith(.{ Transform2D.at(100, 0), Area2D{}, Collider2D.rectangle(32, 32) });
/// try app.signal(trap, Area2D, .body_entered).connect(.method(door, "_on_body_entered"), .{});
/// try app.signal(trap, Area2D, .clicked).connect(.method(door, "_on_trap_clicked"), .{});
/// ```
///
/// Its shapes are its own `Collider2D` and the ones hanging from it, every
/// one of them a sensor whatever the collider says. In the physics it is a
/// kinematic body that goes where its transform goes, so a moving area
/// carries its shapes. An entity may have an `Area2D` or a `RigidBody2D`,
/// not both.
///
/// It has no priority, no gravity or damping overrides and no audio bus:
/// this is what overlaps, not a place that changes physics.
pub const Area2D = extern struct {
    /// Whether it says what is in it. Off, it hears nothing and its
    /// questions are empty, and what was in it is left with an exit.
    monitoring: bool = true,
    /// Whether other areas see it. It is still seen by a body's contacts.
    monitorable: bool = true,
    /// Whether the pointer can pick it; true for an area by default.
    input_pickable: bool = true,
    /// Whether the pointer is over it now, and whether a mouse button went
    /// down on it and is not up yet: what the game draws it by, as a
    /// button's. Read-only, and never saved.
    hovered: bool = false,
    held: bool = false,

    /// What it says. `body` is the entity of what came in - the collider's
    /// `App.collisionObjectOf` - and `local_shape` the collider of this
    /// area that was touched.
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
        // the collider it was over; see `App.physics_object_picking`.
        .input_event = struct { event: InputEvent, shape: Entity },
        // The pointer came over it, or went off it.
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        // The pointer came over one of its colliders, or went off it.
        .mouse_shape_entered = struct { shape: Entity },
        .mouse_shape_exited = struct { shape: Entity },
        // A mouse button went down over it.
        .pressed = struct { button: MouseButton },
        // The button that went down over it came up, wherever the pointer
        // is then.
        .released = struct { button: MouseButton },
        // The button that went down over it came up over it: a click.
        .clicked = struct { button: MouseButton },
    };

    pub const reflect_name = "Area2D";
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
/// guard and the player. Beside a `Transform2D`; `target` turns and scales
/// with it.
pub const RayCast2D = extern struct {
    enabled: bool = true,
    /// Where the ray ends, in the entity's own space.
    target: math.Vec2 = .init(0, 50),
    /// The layers it looks for.
    collision_mask: u32 = 0xFFFF_FFFF,
    /// Whether an area stops it, as a body does.
    hit_areas: bool = false,
    /// Whether the body it hangs from - or is - is passed over.
    exclude_parent: bool = true,

    /// What it found at the last fixed step: whether it hit, the collision
    /// object it hit (see `App.collisionObjectOf`), the collider, where,
    /// and out of which side. Read-only, and never saved.
    colliding: bool = false,
    collider: Entity = .none,
    shape: Entity = .none,
    point: math.Vec2 = .zero,
    normal: math.Vec2 = .zero,

    pub const reflect_name = "RayCast2D";
    pub const reflect_fields = .{
        .target = .{attr.Doc{ .text = "Where the ray ends, in the entity's own space" }},
        .collision_mask = .{ attr.Layers{ .names = .physics_2d }, attr.Doc{ .text = "The layers it looks for" } },
        .hit_areas = .{attr.Doc{ .text = "Whether an area stops it" }},
        .exclude_parent = .{attr.Doc{ .text = "Whether the body it is on is passed over" }},
        .colliding = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether it hit something at the last fixed step" } },
        .collider = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "The body or area it hit" } },
        .shape = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "The collider it hit" } },
        .point = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Where, in the world" } },
        .normal = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Out of the side it hit" } },
    };
};
