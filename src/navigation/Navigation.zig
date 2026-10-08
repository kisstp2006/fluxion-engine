// SPDX-License-Identifier: BSD-3-Clause

//! Agents finding their way across the navigation regions: `app.navigation`.
//!
//! The regions that are on and have a mesh are one map, each mesh where its
//! region is now - a region moved carries its floor with it - joined where
//! their edges meet, within `settings.edge_margin`, and by every
//! `NavigationLink3D`: a jump, a drop, a ladder. A way is A* from polygon
//! to polygon across all of it, pulled tight through the doorways, its
//! corners on the floor. The map is made again when a region, its mesh or
//! where it is changes, or a link does.
//!
//! A `NavigationAgent3D`'s way is found when it is asked where to go next -
//! `nextPathPosition` - and found again when its target moves, it strays
//! further than `path_max_distance` from it, or an obstacle that affects
//! ways has moved. Corners nearer than `path_desired_distance` are passed,
//! a link's start with `link_reached`; within `target_desired_distance` of
//! the end it has finished. Distances are on the ground: an agent's middle
//! is above the floor its way is on.
//!
//! An agent with `avoidance_enabled` gives the velocity it wants to
//! `setAgentVelocity`; after the game's `.fixed` systems each is given the
//! nearest velocity that keeps out of the others' way - and out of the way
//! of each `NavigationObstacle3D`, which does not turn for it - for
//! `time_horizon` seconds, in `velocity_computed`, before the physics step.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const navmesh = @import("fluxion_navmesh");
const debugdraw = @import("fluxion_debugdraw");

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const hierarchy = @import("../scene/hierarchy.zig");
const nav = @import("navigation_components.zig");
const sources = @import("sources.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const NavigationRegion3D = nav.NavigationRegion3D;
const NavigationAgent3D = nav.NavigationAgent3D;
const NavigationLink3D = nav.NavigationLink3D;
const NavigationObstacle3D = nav.NavigationObstacle3D;
const NavMesh = navmesh.NavMesh;
const Map = navmesh.Map;

const Navigation = @This();

const Agent = struct {
    /// Its way, in the world, from where it was when found, and what each
    /// corner is.
    path: std.ArrayList(Vec3) = .empty,
    marks: std.ArrayList(Map.Mark) = .empty,
    /// The corner it is heading for.
    next: usize = 0,
    /// The target the way was found for.
    target: Vec3 = .zero,
    found: bool = false,
    /// It could not get all the way.
    partial: bool = false,
    reached_said: bool = false,
    finished_said: bool = false,
    /// The obstacles' moves its way was found with, and when.
    moves_seen: u32 = 0,
    found_at: f64 = 0,
    /// The link it was told it is at, until it is past its end: said once
    /// however often its way is found again on the way.
    crossing: ?[2]Vec3 = null,
    /// What it wants this step, and what it last moved with.
    wanted: ?Vec3 = null,
    velocity: Vec3 = .zero,

    fn deinit(self: *Agent, gpa: Allocator) void {
        self.path.deinit(gpa);
        self.marks.deinit(gpa);
    }
};

const Obstacle = struct {
    /// Where it was at the last step, and where ways were last found round.
    last: Vec3,
    found_at: Vec3,
};

/// How the map is made: how far apart two regions' edges may be and still
/// meet, and how far from a mesh a link's ends may be.
settings: Map.Settings = .{},
agents: std.AutoArrayHashMapUnmanaged(Entity, Agent) = .empty,
obstacles: std.AutoArrayHashMapUnmanaged(Entity, Obstacle) = .empty,
/// Counts up each time an obstacle that affects ways has moved far enough
/// for the ways round it to be found again.
obstacle_moves: u32 = 0,
/// A way asked for with `findPath`, good until the next.
asked: std.ArrayList(Vec3) = .empty,
scratch: Map.Path = .{},
/// The map, and what it was made from.
map: ?Map = null,
signature: u64 = 0,
parts: std.ArrayList(Map.Part) = .empty,
part_regions: std.ArrayList(Entity) = .empty,
jumps: std.ArrayList(Map.Jump) = .empty,
blockers: std.ArrayList(Map.Blocker) = .empty,

pub fn deinit(self: *Navigation, gpa: Allocator) void {
    for (self.agents.values()) |*a| a.deinit(gpa);
    self.agents.deinit(gpa);
    self.obstacles.deinit(gpa);
    self.asked.deinit(gpa);
    self.scratch.deinit(gpa);
    if (self.map) |*m| m.deinit(gpa);
    self.parts.deinit(gpa);
    self.part_regions.deinit(gpa);
    self.jumps.deinit(gpa);
    self.blockers.deinit(gpa);
    self.* = undefined;
}

pub fn clear(self: *Navigation, app: *App) void {
    for (self.agents.values()) |*a| a.deinit(app.gpa);
    self.agents.clearRetainingCapacity();
    self.obstacles.clearRetainingCapacity();
    self.forgetMap(app.gpa);
}

fn forgetMap(self: *Navigation, gpa: Allocator) void {
    if (self.map) |*m| m.deinit(gpa);
    self.map = null;
    self.signature = 0;
}

pub fn forgetDead(self: *Navigation, app: *App) void {
    var i: usize = 0;
    while (i < self.agents.count()) {
        const e = self.agents.keys()[i];
        if (app.world.isAlive(e) and app.world.has(e, NavigationAgent3D)) {
            i += 1;
            continue;
        }
        self.agents.values()[i].deinit(app.gpa);
        self.agents.swapRemoveAt(i);
    }
    i = 0;
    while (i < self.obstacles.count()) {
        const e = self.obstacles.keys()[i];
        if (app.world.isAlive(e) and app.world.has(e, NavigationObstacle3D)) {
            i += 1;
            continue;
        }
        self.obstacles.swapRemoveAt(i);
    }
}

// -------------------------------------------------------------------------
// The map
// -------------------------------------------------------------------------

fn affine(m: Mat4) navmesh.vec.Affine {
    const c = m.cols;
    return .{ .rows = .{
        .{ c[0].x, c[1].x, c[2].x, c[3].x },
        .{ c[0].y, c[1].y, c[2].y, c[3].y },
        .{ c[0].z, c[1].z, c[2].z, c[3].z },
    } };
}

fn toNav(p: Vec3) navmesh.Vec3 {
    return .{ p.x, p.y, p.z };
}

fn fromNav(p: navmesh.Vec3) Vec3 {
    return .init(p[0], p[1], p[2]);
}

/// A region's mesh and where it is, if it is on and has one.
fn regionPart(app: *App, e: Entity, region: NavigationRegion3D) ?struct { mesh: *const NavMesh, to_world: Mat4, to_local: Mat4 } {
    if (!region.enabled) return null;
    const mesh = app.navmeshes.get(region.navigation_mesh) orelse return null;
    if (mesh.polygons.len == 0) return null;
    const placed = app.worldTransform3D(e) orelse components.Transform3D{};
    const to_world = placed.matrix();
    const to_local = to_world.inverse() orelse return null;
    return .{ .mesh = mesh, .to_world = to_world, .to_local = to_local };
}

/// The map as the regions and links are now, made again if they changed.
/// Null with no region that has a mesh.
pub fn mapOf(self: *Navigation, app: *App) Allocator.Error!?*const Map {
    var hash = std.hash.Wyhash.init(0x6e61_76);
    var regions = ecs.Query(.{NavigationRegion3D}).over(&app.world) catch return null;
    while (regions.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationRegion3D)) |e, region| {
            const part = regionPart(app, e, region) orelse continue;
            hash.update(std.mem.asBytes(&e));
            hash.update(std.mem.asBytes(&@intFromPtr(part.mesh)));
            hash.update(std.mem.asBytes(&app.navmeshes.versionOf(region.navigation_mesh)));
            hash.update(std.mem.asBytes(&part.to_world));
        }
    }
    var links = ecs.Query(.{ components.Transform3D, NavigationLink3D }).over(&app.world) catch return null;
    while (links.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationLink3D)) |e, link| {
            if (!link.enabled) continue;
            const placed = app.worldTransform3D(e) orelse continue;
            hash.update(std.mem.asBytes(&e));
            hash.update(std.mem.asBytes(&link));
            hash.update(std.mem.asBytes(&placed.matrix()));
        }
    }
    hash.update(std.mem.asBytes(&self.settings));
    const signature = hash.final() | 1;
    if (self.map != null and signature == self.signature) return &self.map.?;

    self.forgetMap(app.gpa);
    self.parts.clearRetainingCapacity();
    self.part_regions.clearRetainingCapacity();
    self.jumps.clearRetainingCapacity();
    regions = ecs.Query(.{NavigationRegion3D}).over(&app.world) catch return null;
    while (regions.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationRegion3D)) |e, region| {
            const part = regionPart(app, e, region) orelse continue;
            try self.parts.append(app.gpa, .{ .mesh = part.mesh, .to_world = affine(part.to_world), .to_local = affine(part.to_local) });
            try self.part_regions.append(app.gpa, e);
        }
    }
    if (self.parts.items.len == 0) return null;
    links = ecs.Query(.{ components.Transform3D, NavigationLink3D }).over(&app.world) catch return null;
    while (links.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationLink3D)) |e, link| {
            if (!link.enabled) continue;
            const placed = (app.worldTransform3D(e) orelse continue).matrix();
            try self.jumps.append(app.gpa, .{
                .start = toNav(placed.mulPoint(link.start_position)),
                .end = toNav(placed.mulPoint(link.end_position)),
                .bidirectional = link.bidirectional,
                .travel_cost = link.travel_cost,
                .enter_cost = link.enter_cost,
                .id = @intCast(self.jumps.items.len),
            });
        }
    }
    var settings = self.settings;
    // A link's own reach for its ends.
    links = ecs.Query(.{ components.Transform3D, NavigationLink3D }).over(&app.world) catch return null;
    while (links.next()) |chunk| {
        for (chunk.slice(NavigationLink3D)) |link| settings.jump_search = @max(settings.jump_search, link.search_radius);
    }
    self.map = try Map.init(app.gpa, self.parts.items, self.jumps.items, settings);
    self.signature = signature;
    return &self.map.?;
}

/// What stands in the way of a way now: the obstacles that affect ways.
fn gatherBlockers(self: *Navigation, app: *App) Allocator.Error![]const Map.Blocker {
    self.blockers.clearRetainingCapacity();
    var it = ecs.Query(.{ components.Transform3D, NavigationObstacle3D }).over(&app.world) catch return &.{};
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationObstacle3D)) |e, obstacle| {
            if (!obstacle.affect_paths) continue;
            const at = hierarchy.globalPosition3D(&app.world, e) orelse continue;
            try self.blockers.append(app.gpa, .{ .center = toNav(at), .radius = obstacle.radius, .height = obstacle.height });
        }
    }
    return self.blockers.items;
}

/// The point of the map nearest `p`; `p` itself with no map.
pub fn closestPoint(self: *Navigation, app: *App, p: Vec3) Allocator.Error!Vec3 {
    const map = try self.mapOf(app) orelse return p;
    const near = map.closestPoint(toNav(p)) orelse return p;
    return fromNav(near.point);
}

/// The way from `from` to `to` into the scratch path: whether it gets all
/// the way.
fn way(self: *Navigation, app: *App, from: Vec3, to: Vec3, clearance: f32) Allocator.Error!bool {
    self.scratch.clear();
    const map = try self.mapOf(app) orelse return false;
    const blockers = try self.gatherBlockers(app);
    try map.findPath(app.gpa, toNav(from), toNav(to), &self.scratch, .{ .blockers = blockers, .clearance = clearance });
    return !self.scratch.partial and self.scratch.points.items.len > 0;
}

/// The way from `from` to `to`, its corners from the start to the end: good
/// until the next call.
pub fn findPath(self: *Navigation, app: *App, from: Vec3, to: Vec3) Allocator.Error![]const Vec3 {
    _ = try self.way(app, from, to, 0);
    self.asked.clearRetainingCapacity();
    for (self.scratch.points.items) |p| try self.asked.append(app.gpa, fromNav(p));
    return self.asked.items;
}

// -------------------------------------------------------------------------
// Agents
// -------------------------------------------------------------------------

pub const AgentError = Allocator.Error || error{NotAnAgent};

fn ground(a: Vec3, b: Vec3) f32 {
    const x = a.x - b.x;
    const z = a.z - b.z;
    return @sqrt(x * x + z * z);
}

/// How far `p` is on the ground from the leg `a`-`b`.
fn offLeg(p: Vec3, a: Vec3, b: Vec3) f32 {
    const ab: Vec3 = .init(b.x - a.x, 0, b.z - a.z);
    const ap: Vec3 = .init(p.x - a.x, 0, p.z - a.z);
    const len = ab.dot(ab);
    const t = if (len > 0) std.math.clamp(ap.dot(ab) / len, 0, 1) else 0;
    return ap.sub(ab.scale(t)).len();
}

fn stateOf(self: *Navigation, app: *App, e: Entity) Allocator.Error!*Agent {
    const entry = try self.agents.getOrPut(app.gpa, e);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    return entry.value_ptr;
}

/// The way found again for the agent where it is now.
fn refind(self: *Navigation, app: *App, e: Entity, agent: *NavigationAgent3D, state: *Agent, at: Vec3) !void {
    const whole = try self.way(app, at, agent.target_position, agent.radius);
    state.path.clearRetainingCapacity();
    state.marks.clearRetainingCapacity();
    for (self.scratch.points.items, self.scratch.marks.items) |p, m| {
        try state.path.append(app.gpa, fromNav(p));
        try state.marks.append(app.gpa, m);
    }
    state.partial = !whole;
    state.target = agent.target_position;
    state.found = true;
    state.moves_seen = self.obstacle_moves;
    state.found_at = app.time.elapsed;
    state.next = @min(1, state.path.items.len);
    state.reached_said = false;
    state.finished_said = false;
    agent.reached = false;
    agent.finished = state.path.items.len == 0;
    try app.signal(e, NavigationAgent3D, .path_changed).emit(.{});
}

/// Where the agent on `e` should head next: the next corner of its way, or
/// where it is once it has finished.
pub fn nextPathPosition(self: *Navigation, app: *App, e: Entity) !Vec3 {
    const agent = app.world.get(e, NavigationAgent3D) orelse return error.NotAnAgent;
    const at = hierarchy.globalPosition3D(&app.world, e) orelse return error.NotAnAgent;
    const state = try self.stateOf(app, e);

    var stale = !state.found or state.target.sub(agent.target_position).len() > 1e-4;
    if (!stale and state.next > 0 and state.next < state.path.items.len and !agent.finished) {
        stale = offLeg(at, state.path.items[state.next - 1], state.path.items[state.next]) > agent.path_max_distance;
    }
    // An obstacle that affects ways has moved: found again at once where
    // one stands on what is left of the way, and now and then otherwise,
    // for a shorter way where one has gone.
    if (!stale and state.moves_seen != self.obstacle_moves) {
        stale = app.time.elapsed - state.found_at > refind_seconds or try self.blocks(app, state, at, agent.radius);
    }
    if (stale) try self.refind(app, e, agent, state, at);
    const path = state.path.items;
    if (path.len == 0) return self.finish(app, e, agent, state, at);

    while (state.next < path.len - 1 and ground(at, path[state.next]) <= agent.path_desired_distance) {
        const mark = state.marks.items[state.next];
        // At a link's start: what walks the way makes the jump.
        if (mark.kind == .link_start) {
            const link: [2]Vec3 = .{ path[state.next], path[state.next + 1] };
            const said = if (state.crossing) |c| c[0].sub(link[0]).len() < 0.05 and c[1].sub(link[1]).len() < 0.05 else false;
            if (!said) try app.signal(e, NavigationAgent3D, .link_reached).emit(.{ .start = link[0], .end = link[1] });
            state.crossing = link;
        }
        if (mark.kind == .link_end) state.crossing = null;
        state.next += 1;
    }
    const last = path[path.len - 1];
    if (state.next >= path.len - 1 and ground(at, last) <= agent.target_desired_distance) return self.finish(app, e, agent, state, at);
    return path[@min(state.next, path.len - 1)];
}

/// How often an agent's way is found again while obstacles that affect ways
/// move, though none stands on it.
const refind_seconds = 0.5;

/// Whether an obstacle that affects ways stands on what is left of the
/// agent's way.
fn blocks(self: *Navigation, app: *App, state: *const Agent, at: Vec3, clearance: f32) Allocator.Error!bool {
    const path = state.path.items;
    if (state.next >= path.len) return false;
    for (try self.gatherBlockers(app)) |b| {
        const center = fromNav(b.center);
        var from = at;
        for (path[state.next..]) |to| {
            if (offLeg(center, from, to) < b.radius + clearance) return true;
            from = to;
        }
    }
    return false;
}

fn finish(self: *Navigation, app: *App, e: Entity, agent: *NavigationAgent3D, state: *Agent, at: Vec3) !Vec3 {
    _ = self;
    const reached = ground(at, agent.target_position) <= agent.target_desired_distance;
    agent.finished = true;
    if (reached) agent.reached = true;
    if (reached and !state.reached_said) {
        state.reached_said = true;
        try app.signal(e, NavigationAgent3D, .target_reached).emit(.{});
    }
    if (!state.finished_said) {
        state.finished_said = true;
        try app.signal(e, NavigationAgent3D, .navigation_finished).emit(.{});
    }
    return at;
}

/// Whether the agent has stopped: there, or as near as its way goes. One
/// whose target has moved since it was last asked has not.
pub fn isFinished(self: *Navigation, app: *App, e: Entity) bool {
    const agent = app.world.get(e, NavigationAgent3D) orelse return true;
    const state = self.agents.getPtr(e) orelse return false;
    if (!state.found or state.target.sub(agent.target_position).len() > 1e-4) return false;
    return agent.finished;
}

/// The agent's way as it is now, its corners from where it was when found.
pub fn pathOf(self: *Navigation, e: Entity) []const Vec3 {
    const state = self.agents.getPtr(e) orelse return &.{};
    return state.path.items;
}

/// The agent wants to go at `velocity`: what keeps it out of the others'
/// way comes back in `velocity_computed`, after this step's `.fixed`
/// systems.
pub fn setVelocity(self: *Navigation, app: *App, e: Entity, velocity: Vec3) AgentError!void {
    if (!app.world.has(e, NavigationAgent3D)) return error.NotAnAgent;
    const state = try self.stateOf(app, e);
    state.wanted = velocity;
}

/// Each obstacle's velocity from where it was a step before; an obstacle
/// that affects ways and has moved far enough has the ways round it found
/// again.
fn trackObstacles(self: *Navigation, app: *App, dt: f32) Allocator.Error!void {
    var it = ecs.Query(.{ components.Transform3D, NavigationObstacle3D }).over(&app.world) catch return;
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationObstacle3D)) |e, *obstacle| {
            const at = hierarchy.globalPosition3D(&app.world, e) orelse continue;
            const entry = try self.obstacles.getOrPut(app.gpa, e);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .last = at, .found_at = at };
                if (obstacle.affect_paths) self.obstacle_moves +%= 1;
                continue;
            }
            const was = entry.value_ptr;
            obstacle.velocity = if (dt > 0) at.sub(was.last).scale(1 / dt) else .zero;
            was.last = at;
            if (obstacle.affect_paths and at.sub(was.found_at).len() > 0.25) {
                was.found_at = at;
                self.obstacle_moves +%= 1;
            }
        }
    }
}

/// Each agent that said what velocity it wants is told what it gets: the
/// nearest that keeps out of the way of the other agents with avoidance
/// and of the obstacles, or the same where it has none.
pub fn avoid(self: *Navigation, app: *App, dt: f32) !void {
    try self.trackObstacles(app, dt);
    const gpa = app.gpa;
    var crowd: std.ArrayList(navmesh.avoidance.Agent) = .empty;
    defer crowd.deinit(gpa);
    var who: std.ArrayList(usize) = .empty;
    defer who.deinit(gpa);
    for (self.agents.keys(), self.agents.values(), 0..) |e, *state, i| {
        const agent = app.world.get(e, NavigationAgent3D) orelse continue;
        if (!agent.avoidance_enabled) continue;
        const at = hierarchy.globalPosition3D(&app.world, e) orelse continue;
        const wanted = state.wanted orelse Vec3.zero;
        try crowd.append(gpa, .{
            .position = .{ at.x, at.z },
            .velocity = .{ state.velocity.x, state.velocity.z },
            .preferred = .{ wanted.x, wanted.z },
            .radius = agent.radius,
            .max_speed = agent.max_speed,
            .neighbour_distance = agent.neighbor_distance,
            .max_neighbours = agent.max_neighbors,
            .time_horizon = agent.time_horizon,
        });
        try who.append(gpa, i);
    }
    // The obstacles, which keep on as they go.
    const agent_count = crowd.items.len;
    if (agent_count > 0) {
        var obstacles = ecs.Query(.{ components.Transform3D, NavigationObstacle3D }).over(&app.world) catch return;
        while (obstacles.next()) |chunk| {
            for (chunk.entities, chunk.slice(NavigationObstacle3D)) |e, obstacle| {
                if (!obstacle.avoidance_enabled) continue;
                const at = hierarchy.globalPosition3D(&app.world, e) orelse continue;
                try crowd.append(gpa, .{
                    .position = .{ at.x, at.z },
                    .velocity = .{ obstacle.velocity.x, obstacle.velocity.z },
                    .preferred = .{ obstacle.velocity.x, obstacle.velocity.z },
                    .radius = obstacle.radius,
                    .max_speed = obstacle.velocity.len(),
                    .avoids = false,
                });
            }
        }
    }
    const safe = try gpa.alloc(navmesh.avoidance.Vec2, crowd.items.len);
    defer gpa.free(safe);
    try navmesh.avoidance.solve(gpa, crowd.items, dt, safe);

    var avoided: usize = 0;
    var i: usize = 0;
    while (i < self.agents.count()) : (i += 1) {
        const e = self.agents.keys()[i];
        const state = &self.agents.values()[i];
        const wanted = state.wanted orelse {
            if (avoided < who.items.len and who.items[avoided] == i) {
                state.velocity = .init(safe[avoided][0], 0, safe[avoided][1]);
                avoided += 1;
            }
            continue;
        };
        state.wanted = null;
        var velocity = wanted;
        if (avoided < who.items.len and who.items[avoided] == i) {
            velocity = .init(safe[avoided][0], wanted.y, safe[avoided][1]);
            avoided += 1;
        }
        state.velocity = velocity;
        try app.signal(e, NavigationAgent3D, .velocity_computed).emit(.{ .safe_velocity = velocity });
    }
}

// -------------------------------------------------------------------------
// Baking
// -------------------------------------------------------------------------

pub const BakeError = sources.Error || navmesh.Error;

/// The navigation mesh of `region`, baked now from what it reaches.
pub fn bake(app: *App, region: Entity) BakeError!NavMesh {
    const settings = (app.world.get(region, NavigationRegion3D) orelse return error.NotARegion).*;
    var gathered = try sources.gather(app, region);
    defer gathered.deinit(app.gpa);
    return navmesh.bake(app.gpa, gathered.input(), settings.bakeSettings(), null);
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------

pub const mesh_color: debugdraw.Color = .hexa(0x3FB8F0FF);
pub const door_color: debugdraw.Color = .hexa(0x7CE38BFF);
pub const link_color: debugdraw.Color = .hexa(0xF08CE0FF);
pub const obstacle_color: debugdraw.Color = .hexa(0xF07A4AFF);
pub const path_color: debugdraw.Color = .hexa(0xF2D675FF);

/// Each region's mesh - its polygons' edges a little above it - where the
/// regions meet, the links, the obstacles, the boxes regions are cut to,
/// and each agent's way.
pub fn draw(self: *Navigation, app: *App, pen: debugdraw.Pen) void {
    const lift: Vec3 = .init(0, 0.03, 0);
    if (self.mapOf(app) catch null) |map| {
        for (map.parts) |part| {
            const mesh = part.mesh;
            for (mesh.polygons, 0..) |poly, i| {
                for (0..poly.count) |k| {
                    // Each shared edge once.
                    const across = poly.neighbours[k];
                    if (across != NavMesh.none and across < i) continue;
                    const a = fromNav(part.to_world.apply(mesh.corner(@intCast(i), k))).add(lift);
                    const b = fromNav(part.to_world.apply(mesh.corner(@intCast(i), (k + 1) % poly.count))).add(lift);
                    pen.line(a, b, if (across == NavMesh.none) mesh_color else mesh_color.withAlpha(0.45));
                }
            }
        }
        for (map.links) |link| {
            const a = fromNav(link.a).add(lift.scale(2));
            const b = fromNav(link.b).add(lift.scale(2));
            switch (link.kind) {
                .doorway => pen.line(a, b, door_color),
                .jump => {
                    // An arc over the gap.
                    const rise: Vec3 = .init(0, @max(0.4, a.sub(b).len() * 0.25), 0);
                    const middle = a.add(b).scale(0.5).add(rise);
                    pen.line(a, middle, link_color);
                    pen.line(middle, b, link_color);
                },
            }
        }
    }
    var obstacles = ecs.Query(.{ components.Transform3D, NavigationObstacle3D }).over(&app.world) catch return;
    while (obstacles.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationObstacle3D)) |e, obstacle| {
            const at = hierarchy.globalPosition3D(&app.world, e) orelse continue;
            pen.cylinder(at, at.add(.init(0, obstacle.height, 0)), obstacle.radius, if (obstacle.affect_paths) obstacle_color else obstacle_color.withAlpha(0.5));
        }
    }
    var regions = ecs.Query(.{NavigationRegion3D}).over(&app.world) catch return;
    while (regions.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationRegion3D)) |e, region| {
            const size = region.bake_bounds_size;
            if (size.x <= 0 or size.z <= 0) continue;
            const placed = app.worldTransform3D(e) orelse components.Transform3D{};
            const half = size.scale(0.5);
            pen.within(placed.matrix()).box(.{ .min = region.bake_bounds_center.sub(half), .max = region.bake_bounds_center.add(half) }, mesh_color.withAlpha(0.6));
        }
    }
    for (self.agents.values()) |state| {
        const path = state.path.items;
        if (path.len < 2) continue;
        for (path[0 .. path.len - 1], path[1..]) |a, b| pen.line(a.add(.init(0, 0.05, 0)), b.add(.init(0, 0.05, 0)), path_color);
    }
}
