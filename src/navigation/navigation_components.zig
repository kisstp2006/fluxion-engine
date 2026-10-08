// SPDX-License-Identifier: BSD-3-Clause

//! The components of navigation in 3D: `NavigationRegion3D`, where agents
//! may walk, baked from the world into a navigation mesh, and
//! `NavigationAgent3D`, something that finds its way across one. See
//! `navigation/Navigation.zig`.

const std = @import("std");

const math = @import("fluxion_math");

const attr = @import("../reflect/attr.zig");
const NavMeshHandle = @import("navmeshes.zig").NavMeshHandle;

/// Where agents may walk: a navigation mesh, baked from what hangs from
/// the region - or the whole scene - and kept as a `.navmesh`, in the
/// region's own space so it moves with it.
///
/// ```zig
/// const region = try world.spawnWith(.{ Transform3D{}, NavigationRegion3D{} });
/// // ... the floor, the walls and the furniture hanging from it ...
/// try app.bakeNavigationMesh(region, "res://levels/office.navmesh");
/// ```
///
/// A bake lays the solid of every mesh and collider it finds in columns of
/// cells, keeps the tops an agent can stand on - no steeper than
/// `agent_max_slope`, with `agent_height` of air above - wears them back
/// from walls and drops by `agent_radius`, and draws what is left as convex
/// polygons. A box, a ball, a capsule, a cylinder and a convex collider are
/// solid; any other mesh is only its surface, so a closed one standing on
/// the floor may leave an island of floor inside it that nothing reaches.
/// What moves - a rigid body, a character, an area - is left out.
pub const NavigationRegion3D = extern struct {
    /// What was baked: a `.navmesh`.
    navigation_mesh: NavMeshHandle = .none,
    /// Off, agents do not walk on it.
    enabled: bool = true,
    /// What is baked from.
    source: Source = .meshes_and_colliders,
    scope: Scope = .children,
    /// A cell's side on the ground and its step up: smaller is truer, and
    /// slower to bake.
    cell_size: f32 = 0.25,
    cell_height: f32 = 0.25,
    /// The agents it is for. `agent_max_climb` is the highest kerb a way
    /// goes up: no higher than what walks it steps up - a
    /// `CharacterBody3D`'s `max_step_height` - or it is stopped there.
    agent_height: f32 = 1.5,
    agent_radius: f32 = 0.5,
    agent_max_climb: f32 = 0.25,
    agent_max_slope: f32 = std.math.pi / 4.0,
    /// Pieces of floor smaller than this are left out.
    min_region_area: f32 = 1,
    /// How long an edge along a wall may be, and how far it may stray from
    /// the cells, in cells.
    edge_max_length: f32 = 12,
    edge_max_error: f32 = 1.3,
    /// How far apart the heights sampled inside each polygon are; nought
    /// samples none.
    detail_sample_distance: f32 = 0.5,
    /// A box on the ground, in the region's space, the mesh is cut to: none
    /// while its size is nought. What is round it is still looked at, so
    /// the mesh reaches its sides rather than being worn back from them,
    /// and two regions cut along one line meet there - with `scope` the
    /// whole scene, so each sees the other's floor.
    bake_bounds_center: math.Vec3 = .zero,
    bake_bounds_size: math.Vec3 = .zero,

    pub const Source = enum(u8) { meshes_and_colliders, meshes, colliders };
    /// What hangs from the region, or everything in the scene.
    pub const Scope = enum(u8) { children, scene };

    pub const reflect_name = "NavigationRegion3D";
    pub const reflect_fields = .{
        .navigation_mesh = .{attr.Doc{ .text = "What was baked: a .navmesh" }},
        .enabled = .{attr.Doc{ .text = "Off, agents do not walk on it" }},
        .source = .{ attr.Group{ .name = "Baking" }, attr.Doc{ .text = "Meshes, colliders or both: what the floor and walls are made from" } },
        .scope = .{attr.Doc{ .text = "What hangs from the region, or the whole scene" }},
        .cell_size = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0.05, .max = 2 }, attr.Doc{ .text = "A cell's side on the ground: smaller is truer and slower" } },
        .cell_height = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0.05, .max = 2 }, attr.Doc{ .text = "A cell's step up" } },
        .agent_height = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0.1, .max = 20 }, attr.Doc{ .text = "Air an agent needs over the floor" } },
        .agent_radius = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0, .max = 10 }, attr.Doc{ .text = "How far an agent's middle keeps from walls and drops" } },
        .agent_max_climb = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0, .max = 10 }, attr.Doc{ .text = "The highest kerb a way goes up: no higher than the character's max_step_height" } },
        .agent_max_slope = .{ attr.Angle{}, attr.Doc{ .text = "The steepest slope an agent walks up" } },
        .min_region_area = .{ attr.Unit{ .text = "m²" }, attr.Doc{ .text = "Pieces of floor smaller than this are left out" } },
        .edge_max_length = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How long an edge along a wall may be; nought for any" } },
        .edge_max_error = .{attr.Doc{ .text = "How far, in cells, an edge along a wall may stray from them" }},
        .detail_sample_distance = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How far apart the heights sampled inside each polygon are; nought for none" } },
        .bake_bounds_center = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "The middle of the box the mesh is cut to, in the region's space" } },
        .bake_bounds_size = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "The box the mesh is cut to; nought for none. Cut, it meets the next region's" } },
    };

    /// What the bake is told.
    pub fn bakeSettings(self: NavigationRegion3D) @import("fluxion_navmesh").Settings {
        return .{
            .cell_size = self.cell_size,
            .cell_height = self.cell_height,
            .agent_height = self.agent_height,
            .agent_radius = self.agent_radius,
            .agent_max_climb = self.agent_max_climb,
            .agent_max_slope = self.agent_max_slope,
            .min_region_area = self.min_region_area,
            .edge_max_length = self.edge_max_length,
            .edge_max_error = self.edge_max_error,
            .detail_sample_distance = self.detail_sample_distance,
            .bounds = if (self.bake_bounds_size.x > 0 and self.bake_bounds_size.z > 0) .{
                .{ self.bake_bounds_center.x - self.bake_bounds_size.x / 2, self.bake_bounds_center.y - self.bake_bounds_size.y / 2, self.bake_bounds_center.z - self.bake_bounds_size.z / 2 },
                .{ self.bake_bounds_center.x + self.bake_bounds_size.x / 2, self.bake_bounds_center.y + self.bake_bounds_size.y / 2, self.bake_bounds_center.z + self.bake_bounds_size.z / 2 },
            } else null,
        };
    }
};

/// Something that finds its way: given `target_position`, it says where to
/// head next - `app.nextPathPosition(entity)` - across the navigation
/// regions, round what is in the way, until it is there.
///
/// ```flux
/// fn fixed(self, dt: float) {
///     if (app.isNavigationFinished(self.entity)) return;
///     var to = app.nextPathPosition(self.entity) - self.entity.globalPosition3D().?;
///     to.y = 0.0; // the way is on the floor, the agent's middle above it
///     self.entity.get(CharacterBody3D).velocity = to.normalized() * 4.0;
///     app.moveAndSlide(self.entity);
/// }
/// ```
///
/// With `avoidance_enabled` it keeps out of other agents' way too: the
/// velocity it wants goes to `app.setAgentVelocity(entity, velocity)`, and
/// the one that keeps clear comes back in `velocity_computed` at the next
/// fixed step.
pub const NavigationAgent3D = extern struct {
    /// Where it is going, in the world.
    target_position: math.Vec3 = .zero,
    /// How near a corner of the path counts as there, and how near the
    /// target counts as reached.
    path_desired_distance: f32 = 0.5,
    target_desired_distance: f32 = 0.5,
    /// Further than this from its path, the way is found again.
    path_max_distance: f32 = 3,
    /// How wide it is and how fast it goes, for keeping out of the way.
    radius: f32 = 0.5,
    max_speed: f32 = 5,
    avoidance_enabled: bool = false,
    /// Others further than this are not looked at, nor more than
    /// `max_neighbors` of the nearest.
    neighbor_distance: f32 = 10,
    max_neighbors: u32 = 10,
    /// How far ahead, in seconds, it keeps clear of the others.
    time_horizon: f32 = 1,
    /// Whether it has got there, and whether it has stopped looking - got
    /// there, or no way there - as of the last `nextPathPosition`: what the
    /// signals `target_reached` and `navigation_finished` said last. A new
    /// target is not finished. Read-only, and never saved.
    reached: bool = false,
    finished: bool = false,

    pub const signals = .{
        // A way was found: to a new target, or again after straying.
        .path_changed = struct {},
        // It got to the target: within `target_desired_distance` of it.
        .target_reached = struct {},
        // It is there, or as near as the way goes.
        .navigation_finished = struct {},
        // The velocity that keeps out of the others' way.
        .velocity_computed = struct { safe_velocity: math.Vec3 },
        // At the start of a link: a jump to make, a drop, a ladder.
        .link_reached = struct { start: math.Vec3, end: math.Vec3 },
    };

    pub const reflect_name = "NavigationAgent3D";
    pub const reflect_fields = .{
        .target_position = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Where it is going, in the world" } },
        .path_desired_distance = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How near a corner of the path counts as there" } },
        .target_desired_distance = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How near the target counts as reached" } },
        .path_max_distance = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Further than this from its path, the way is found again" } },
        .radius = .{ attr.Group{ .name = "Avoidance" }, attr.Unit{ .text = "m" }, attr.Doc{ .text = "How wide it is, keeping out of the way" } },
        .max_speed = .{ attr.Unit{ .text = "m/s" }, attr.Doc{ .text = "The fastest velocity_computed gives" } },
        .avoidance_enabled = .{attr.Doc{ .text = "Keeps out of other agents' way: set its velocity with setAgentVelocity" }},
        .neighbor_distance = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Others further than this are not looked at" } },
        .max_neighbors = .{attr.Doc{ .text = "How many of the nearest are looked at" }},
        .time_horizon = .{ attr.Unit{ .text = "s" }, attr.Doc{ .text = "How far ahead it keeps clear of the others" } },
        .reached = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether it got to the target, as of the last nextPathPosition" } },
        .finished = .{ attr.ReadOnly{}, attr.Unsaved{}, attr.Doc{ .text = "Whether it stopped looking: got there, or no way there" } },
    };
};

/// A way between two places the mesh does not join: a jump across a gap,
/// a drop off a ledge, a ladder. Its ends are found on the nearest
/// navigation mesh, within `search_radius`; an agent's way may go along it,
/// and the agent hears `link_reached` at its start, to make the jump.
pub const NavigationLink3D = extern struct {
    /// Whether agents' ways may go along it.
    enabled: bool = true,
    /// Both ways, or only from the start to the end - a drop.
    bidirectional: bool = true,
    /// Its two ends, in the entity's own space.
    start_position: math.Vec3 = .init(-1, 0, 0),
    end_position: math.Vec3 = .init(1, 0, 0),
    /// Going along it costs its length times `travel_cost`, and
    /// `enter_cost` besides: what makes a way take it, or not.
    enter_cost: f32 = 0,
    travel_cost: f32 = 1,
    /// How far from a mesh its ends may be.
    search_radius: f32 = 1,

    pub const reflect_name = "NavigationLink3D";
    pub const reflect_fields = .{
        .bidirectional = .{attr.Doc{ .text = "Both ways, or only from the start to the end: a drop" }},
        .start_position = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Where it starts, in the entity's own space" } },
        .end_position = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "Where it ends, in the entity's own space" } },
        .enter_cost = .{attr.Doc{ .text = "Added to what a way along it costs" }},
        .travel_cost = .{attr.Doc{ .text = "What its length is counted as, times" }},
        .search_radius = .{ attr.Unit{ .text = "m" }, attr.Doc{ .text = "How far from a mesh its ends may be" } },
    };
};

/// Something in the way that moves on its own - a cart, a rolling boulder,
/// a guard who is not an agent: a disc `radius` wide, `height` tall from
/// the entity up. Agents with avoidance keep out of its way, taking all of
/// the turning away, as it does not turn for them. With `affect_paths`, a
/// way does not go through a doorway of the mesh it stands in - one wide
/// enough is narrowed to beside it - and agents find their way again when
/// it has moved.
pub const NavigationObstacle3D = extern struct {
    radius: f32 = 0.5,
    height: f32 = 1,
    avoidance_enabled: bool = true,
    affect_paths: bool = false,
    /// How fast it is going, from where it was a step before. Read-only,
    /// and never saved.
    velocity: math.Vec3 = .zero,

    pub const reflect_name = "NavigationObstacle3D";
    pub const reflect_fields = .{
        .radius = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How wide it is from its middle" } },
        .height = .{ attr.Unit{ .text = "m" }, attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How tall it is from the entity up" } },
        .avoidance_enabled = .{attr.Doc{ .text = "Agents with avoidance keep out of its way" }},
        .affect_paths = .{attr.Doc{ .text = "Ways do not go through what it stands in, and are found again as it moves" }},
        .velocity = .{ attr.ReadOnly{}, attr.Unsaved{} },
    };
};
