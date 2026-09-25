// SPDX-License-Identifier: BSD-3-Clause

//! The components the engine itself reads: `Transform2D`, `Sprite`,
//! `Text2D`, `Camera2D`, `RigidBody2D` and `Collider2D`. A game
//! declares its own beside them.
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
const math = @import("fluxion_math");
const physics = @import("fluxion_physics");
const assets = @import("assets.zig");
const attr = @import("attr.zig");
const pointer = @import("pointer.zig");

/// Re-exported because a transform names the entity it hangs from.
pub const Entity = ecs.Entity;

/// A colour, four floats from zero to one. See `color`.
pub const Color = @import("color.zig").Color;

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

/// Which part of a texture a sprite shows, from zero to one - so it survives
/// the texture being redrawn at another resolution. `fromPixels` takes texels.
pub const Region = extern struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,

    /// The whole texture.
    pub const full: Region = .{};

    /// No range on the corners: past one is a texture repeated.
    pub const reflect_name = "Region";

    /// A rectangle of a sprite sheet, in texels, given the size of the sheet.
    pub fn fromPixels(x: f32, y: f32, w: f32, h: f32, sheet_width: f32, sheet_height: f32) Region {
        return .{
            .u0 = x / sheet_width,
            .v0 = y / sheet_height,
            .u1 = (x + w) / sheet_width,
            .v1 = (y + h) / sheet_height,
        };
    }

    pub fn repeated(across: f32, down: f32) Region {
        return .{ .u1 = across, .v1 = down };
    }

    /// One cell of a grid, counted left to right and then down. A grid of no
    /// columns or no rows - a number from a file, not from a sheet - is taken
    /// as one, rather than divided by.
    pub fn cell(index: u32, columns: u32, rows: u32) Region {
        const across = @max(columns, 1);
        const down = @max(rows, 1);
        const cw = 1 / @as(f32, @floatFromInt(across));
        const ch = 1 / @as(f32, @floatFromInt(down));
        const cx = @as(f32, @floatFromInt(index % across)) * cw;
        const cy = @as(f32, @floatFromInt((index / across) % down)) * ch;
        return .{ .u0 = cx, .v0 = cy, .u1 = cx + cw, .v1 = cy + ch };
    }

    /// Mirrored left to right.
    pub fn flippedX(self: Region) Region {
        return .{ .u0 = self.u1, .v0 = self.v0, .u1 = self.u0, .v1 = self.v1 };
    }

    /// Mirrored top to bottom.
    pub fn flippedY(self: Region) Region {
        return .{ .u0 = self.u0, .v0 = self.v1, .u1 = self.u1, .v1 = self.v0 };
    }
};

/// A picture drawn at a transform.
pub const Sprite = extern struct {
    /// What to draw. `.none` - also what a zeroed component holds - draws a
    /// rectangle of solid `tint`.
    texture: assets.TextureHandle = .none,

    /// Multiplied into the texture. White leaves it alone; the alpha fades it.
    tint: Color = .white,

    /// Which part of the texture.
    region: Region = .full,

    /// Size in world units, before the transform's scale. Zero means the
    /// region's size in texels, so most sprites need no size.
    width: f32 = 0,
    height: f32 = 0,

    /// Which point of the sprite sits on the transform, from zero to one. The
    /// middle by default, so it turns about itself.
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,

    /// What is drawn over what: higher is nearer. A sort key, not a depth -
    /// the 2D pass blends back to front with no depth test. Within a layer,
    /// see `order`.
    layer: i16 = 0,

    /// Skipped when false. Cheaper than removing the component, which moves
    /// the entity between archetypes.
    visible: bool = true,

    blend: Blend = .alpha,

    /// Where a sprite sits within its layer: lower is drawn first. At zero, a
    /// layer's sprites are grouped by texture, one draw call each. Copying
    /// `transform.y` in here sorts a top-down game by feet, at the cost of
    /// that grouping. Ties keep a stable order.
    order: f32 = 0,

    pub const Blend = enum(u8) { alpha, additive };

    pub const reflect_name = "Sprite";
    pub const reflect_fields = .{
        .width = .{attr.Doc{ .text = "World units; zero is the region's width in texels" }},
        .height = .{attr.Doc{ .text = "World units; zero is the region's height in texels" }},
        .pivot_x = .{attr.Range{ .min = 0, .max = 1 }},
        .pivot_y = .{attr.Range{ .min = 0, .max = 1 }},
    };

    /// A sprite showing the whole of a texture at its own size.
    pub fn of(texture: assets.TextureHandle) Sprite {
        return .{ .texture = texture };
    }

    /// A rectangle of solid colour, with no texture at all.
    pub fn solid(color: Color, width: f32, height: f32) Sprite {
        return .{ .tint = color, .width = width, .height = height };
    }
};

/// Words drawn at a transform, in a font the assets are holding.
///
/// ```zig
/// const label = try world.spawnWith(.{ Transform2D.at(16, 16), Text2D{ .size = 24 } });
/// try app.setText(label, Text2D, "text", "Score");
///
/// // ... and later, from a system:
/// try app.printText(label, Text2D, "text", "{d} points", .{score});
/// ```
///
/// The words are the app's, kept beside the component as long as they are:
/// see `texts.zig`. The transform is the top left of the first line, not the
/// baseline.
pub const Text2D = extern struct {
    /// `.none` is the default font, the first one loaded.
    font: assets.FontHandle = .none,

    /// Pixels per em, before the transform's scale. Rounded to whole pixels
    /// when rasterised.
    size: f32 = 16,

    color: Color = .white,

    /// Where the transform sits along the line.
    alignment: Alignment = .left,

    /// Multiplies the font's own line height.
    line_spacing: f32 = 1,

    /// The same sort keys as a `Sprite`'s: text and sprites are one list.
    layer: i16 = 0,
    order: f32 = 0,

    visible: bool = true,

    pub const Alignment = enum(u8) { left, center, right };

    pub const reflect_name = "Text2D";
    pub const reflect_attributes = .{attr.Text{ .name = "text", .multiline = true }};
    pub const reflect_fields = .{
        .size = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "Per em, before the transform's scale" } },
    };
};

/// What the 2D pass looks through. Its position is its entity's
/// `Transform2D`, at the middle of the view. With no camera in the world, the
/// origin is the window's top left and one unit is one pixel.
pub const Camera2D = extern struct {
    /// Bigger is closer: 2 draws everything at twice the size. With a fit set,
    /// it multiplies the fit: 1 shows exactly the fitted area.
    zoom: f32 = 1,

    /// An area always shown whole, whatever the window's size: a play field
    /// designed at one size. Spare room shows more of the world around it.
    /// Zero on either is no fit.
    fit_width: f32 = 0,
    fit_height: f32 = 0,

    /// Radians, as `Transform2D.rotation`. The world turns the other way.
    rotation: f32 = 0,

    /// With more than one camera, the active one with the highest priority
    /// wins. Ties go to whichever is found first, which is not an order to
    /// depend on.
    priority: i16 = 0,

    active: bool = true,

    /// The render layers it sees: what an `Appearance` puts on layers it
    /// does not have is not drawn through it. See `Appearance.render_layers`.
    cull_mask: u32 = 0xFFFF_FFFF,

    pub const reflect_name = "Camera2D";
    pub const reflect_fields = .{
        .cull_mask = .{ attr.Layers{ .names = .render_2d }, attr.Doc{ .text = "The render layers it sees" } },
        .fit_width = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .fit_height = .{attr.Doc{ .text = "Always shown whole; zero is no fit" }},
        .rotation = .{ attr.Angle{}, attr.Doc{ .text = "Clockwise on screen; the world turns the other way" } },
    };

    pub fn atZoom(zoom: f32) Camera2D {
        return .{ .zoom = zoom };
    }

    /// A camera that always shows the whole of an area this size.
    pub fn fitting(width: f32, height: f32) Camera2D {
        return .{ .fit_width = width, .fit_height = height };
    }
};

/// A camera that draws into a picture of its own rather than onto the
/// screen: a game in an arcade cabinet, a minimap, a monitor on a wall.
/// Beside a `Camera2D`, which says how close it is and what it sees, and a
/// `Transform2D`, which says where it looks. The screen is never looked at
/// through it.
///
/// What it draws is shown by a `ViewTexture` on a `Sprite` or a
/// `TextureRect`, or by `App.viewTexture` from code: drawn every frame
/// before the screen is, so what shows it shows this frame's.
pub const RenderView = extern struct {
    width: u32 = 320,
    height: u32 = 180,
    clear_color: Color = .black,
    /// Nearest keeps a small picture's pixels square when it is shown
    /// bigger; linear smooths it.
    filter: Filter = .nearest,
    /// Off, it keeps the last picture it drew.
    active: bool = true,

    pub const Filter = enum(u8) { nearest, linear };

    pub const reflect_name = "RenderView";
    pub const reflect_fields = .{
        .width = .{ attr.Range{ .min = 1, .max = 4096, .step = 1 }, attr.Unit{ .text = "px" } },
        .height = .{ attr.Range{ .min = 1, .max = 4096, .step = 1 }, attr.Unit{ .text = "px" } },
        .clear_color = .{attr.Doc{ .text = "What the picture is cleared to before the world is drawn" }},
        .active = .{attr.Doc{ .text = "Off, it keeps the last picture it drew" }},
    };
};

/// Shows the picture a `RenderView` draws, in place of its own texture:
/// beside a `Sprite` or a `TextureRect`.
pub const ViewTexture = extern struct {
    view: Entity = .none,

    pub const reflect_name = "ViewTexture";
    pub const reflect_fields = .{
        .view = .{attr.Doc{ .text = "The entity whose RenderView's picture is shown" }},
    };
};

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
        .input_event = struct { event: pointer.InputEvent, shape: Entity },
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        .mouse_shape_entered = struct { shape: Entity },
        .mouse_shape_exited = struct { shape: Entity },
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
        .extents = .{ attr.Extents{}, attr.Doc{ .text = "Half the size; zero is the sprite's" } },
        .radius = .{ attr.Radius{}, attr.Doc{ .text = "Zero is half the sprite's width" } },
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
/// pickup, a hurtbox, a door's threshold.
///
/// ```zig
/// const trap = try world.spawnWith(.{ Transform2D.at(100, 0), Area2D{}, Collider2D.box(32, 32) });
/// try app.signal(trap, Area2D, .body_entered).connect(.method(door, "_on_body_entered"), .{});
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

    /// What it says. `body` is the entity of what came in - the collider's
    /// `App.collisionObjectOf` - and `local_shape` the collider of this
    /// area that was touched.
    pub const signals = .{
        .body_entered = struct { body: Entity },
        .body_exited = struct { body: Entity },
        .body_shape_entered = struct { body: Entity, body_shape: Entity, local_shape: Entity },
        .body_shape_exited = struct { body: Entity, body_shape: Entity, local_shape: Entity },
        .area_entered = struct { area: Entity },
        .area_exited = struct { area: Entity },
        .area_shape_entered = struct { area: Entity, area_shape: Entity, local_shape: Entity },
        .area_shape_exited = struct { area: Entity, area_shape: Entity, local_shape: Entity },

        // What the pointer did over it; see `App.physics_object_picking`.
        .input_event = struct { event: pointer.InputEvent, shape: Entity },
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        .mouse_shape_entered = struct { shape: Entity },
        .mouse_shape_exited = struct { shape: Entity },
    };

    pub const reflect_name = "Area2D";
    pub const reflect_fields = .{
        .monitoring = .{attr.Doc{ .text = "Whether it says what is in it" }},
        .monitorable = .{attr.Doc{ .text = "Whether other areas see it" }},
        .input_pickable = .{attr.Doc{ .text = "Whether the pointer can pick it" }},
    };
};

test "a transform maps its own space into the world" {
    const t: Transform2D = .{ .x = 10, .y = 20, .rotation = std.math.pi / 2.0, .scale_x = 2, .scale_y = 2 };
    const p = t.apply(1, 0);

    // A quarter turn takes +x to +y, and the scale doubled the length.
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 22), p.y, 0.0001);
}

test "a cell of a strip is the strip divided up" {
    const r: Region = .cell(1, 4, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.u0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.u1, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), r.v0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), r.v1, 0.0001);
}

test "a sprite's blend mode fits in the padding it already had" {
    try testing.expectEqual(64, @sizeOf(Sprite));
}

test "mirroring swaps the horizontal edges and leaves the vertical ones" {
    const r: Region = .fromPixels(0, 0, 16, 16, 64, 64);
    const flipped = r.flippedX();
    try testing.expectEqual(r.u1, flipped.u0);
    try testing.expectEqual(r.u0, flipped.u1);
    try testing.expectEqual(r.v0, flipped.v0);
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

test "a label's words are the app's, as long as they are, and gone with it" {
    const App = @import("App.zig");
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const label = try app.world.spawnWith(.{ Transform2D.at(0, 0), Text2D{} });
    try testing.expectEqualStrings("", app.textOf(label, Text2D, "text"));
    try app.setText(label, Text2D, "text", "Score");
    try testing.expectEqualStrings("Score", app.textOf(label, Text2D, "text"));
    try app.printText(label, Text2D, "text", "{d} points", .{42});
    try testing.expectEqualStrings("42 points", app.textOf(label, Text2D, "text"));

    // Far longer than any buffer a component could hold.
    const long = "é" ** 400;
    try app.setText(label, Text2D, "text", long);
    try testing.expectEqualStrings(long, app.textNamed(label, "Text2D", "text"));
    try testing.expectError(error.NoSuchText, app.setTextNamed(label, "Text2D", "words", "no"));

    app.world.despawn(label);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.texts.map.count());
    try testing.expectError(error.NoSuchEntity, app.setText(label, Text2D, "text", "late"));
}

