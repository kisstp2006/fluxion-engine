// SPDX-License-Identifier: BSD-3-Clause

//! Agents finding their way across the navigation regions: `app.navigation`.
//!
//! Each `NavigationRegion3D` that is on and has a mesh is a piece of the
//! map, its mesh in the region's own space, so a region moved carries its
//! floor with it. A way is found on the region whose mesh is nearest the
//! start: A* from polygon to polygon, pulled tight through the doorways.
//! It does not cross from one region to another; a target off the region
//! is gone towards as near as the region reaches.
//!
//! A `NavigationAgent3D`'s way is found when it is asked where to go next -
//! `nextPathPosition` - and found again when its target moves or it strays
//! further than `path_max_distance` from it. Corners nearer than
//! `path_desired_distance` are passed; within `target_desired_distance` of
//! the end it has finished. Distances are on the ground: an agent's middle
//! is above the floor its way is on.
//!
//! An agent with `avoidance_enabled` gives the velocity it wants to
//! `setAgentVelocity`; after the game's `.fixed` systems each is given the
//! nearest velocity that keeps out of the others' way for `time_horizon`
//! seconds, in `velocity_computed`, before the physics step.

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
const navmeshes = @import("navmeshes.zig");
const sources = @import("sources.zig");

const Entity = ecs.Entity;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const NavigationRegion3D = nav.NavigationRegion3D;
const NavigationAgent3D = nav.NavigationAgent3D;
const NavMesh = navmesh.NavMesh;

const Navigation = @This();

const Agent = struct {
    /// Its way, in the world, from where it was when found.
    path: std.ArrayList(Vec3) = .empty,
    /// The corner it is heading for.
    next: usize = 0,
    /// The target the way was found for.
    target: Vec3 = .zero,
    found: bool = false,
    /// It could not get all the way.
    partial: bool = false,
    reached_said: bool = false,
    finished_said: bool = false,
    /// What it wants this step, and what it last moved with.
    wanted: ?Vec3 = null,
    velocity: Vec3 = .zero,

    fn deinit(self: *Agent, gpa: Allocator) void {
        self.path.deinit(gpa);
    }
};

agents: std.AutoArrayHashMapUnmanaged(Entity, Agent) = .empty,
/// A way asked for with `findPath`, good until the next.
asked: std.ArrayList(Vec3) = .empty,
scratch: NavMesh.Path = .{},

pub fn deinit(self: *Navigation, gpa: Allocator) void {
    for (self.agents.values()) |*a| a.deinit(gpa);
    self.agents.deinit(gpa);
    self.asked.deinit(gpa);
    self.scratch.deinit(gpa);
    self.* = undefined;
}

pub fn clear(self: *Navigation, app: *App) void {
    for (self.agents.values()) |*a| a.deinit(app.gpa);
    self.agents.clearRetainingCapacity();
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
}

// -------------------------------------------------------------------------
// The map
// -------------------------------------------------------------------------

/// A region's mesh where the region is now.
pub const Placed = struct {
    region: Entity,
    mesh: *const NavMesh,
    to_world: Mat4,
    to_local: Mat4,

    pub fn local(self: Placed, p: Vec3) navmesh.Vec3 {
        const q = self.to_local.mulPoint(p);
        return .{ q.x, q.y, q.z };
    }

    pub fn world(self: Placed, p: navmesh.Vec3) Vec3 {
        return self.to_world.mulPoint(.init(p[0], p[1], p[2]));
    }
};

fn placedRegion(app: *App, e: Entity, region: NavigationRegion3D) ?Placed {
    if (!region.enabled) return null;
    const mesh = app.navmeshes.get(region.navigation_mesh) orelse return null;
    if (mesh.polygons.len == 0) return null;
    const placed = app.worldTransform3D(e) orelse components.Transform3D{};
    const to_world = placed.matrix();
    const to_local = to_world.inverse() orelse return null;
    return .{ .region = e, .mesh = mesh, .to_world = to_world, .to_local = to_local };
}

/// The region whose mesh is nearest `p`, and how far.
pub fn regionNear(app: *App, p: Vec3) ?Placed {
    var best: ?Placed = null;
    var best_d: f32 = std.math.inf(f32);
    var it = ecs.Query(.{NavigationRegion3D}).over(&app.world) catch return null;
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationRegion3D)) |e, region| {
            const placed = placedRegion(app, e, region) orelse continue;
            const near = placed.mesh.closestPoint(placed.local(p)) orelse continue;
            const d = placed.world(near.point).sub(p).len();
            if (d < best_d) {
                best_d = d;
                best = placed;
            }
        }
    }
    return best;
}

/// The point of the map nearest `p`; `p` itself with no map.
pub fn closestPoint(app: *App, p: Vec3) Vec3 {
    const placed = regionNear(app, p) orelse return p;
    const near = placed.mesh.closestPoint(placed.local(p)) orelse return p;
    return placed.world(near.point);
}

/// The way from `from` to `to` on the region nearest `from`, into `out`;
/// whether it gets all the way. Empty with no map.
fn wayInto(self: *Navigation, app: *App, from: Vec3, to: Vec3, out: *std.ArrayList(Vec3)) Allocator.Error!bool {
    out.clearRetainingCapacity();
    const placed = regionNear(app, from) orelse return false;
    try placed.mesh.findPath(app.gpa, placed.local(from), placed.local(to), &self.scratch);
    for (self.scratch.points.items) |p| try out.append(app.gpa, placed.world(p));
    return !self.scratch.partial and out.items.len > 0;
}

/// The way from `from` to `to`, its corners from the start to the end: good
/// until the next call.
pub fn findPath(self: *Navigation, app: *App, from: Vec3, to: Vec3) Allocator.Error![]const Vec3 {
    _ = try self.wayInto(app, from, to, &self.asked);
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
    const whole = try self.wayInto(app, at, agent.target_position, &state.path);
    state.partial = !whole;
    state.target = agent.target_position;
    state.found = true;
    state.next = @min(1, state.path.items.len);
    state.reached_said = false;
    state.finished_said = false;
    agent.target_reached = false;
    agent.navigation_finished = state.path.items.len == 0;
    try app.signal(e, NavigationAgent3D, .path_changed).emit(.{});
}

/// Where the agent on `e` should head next: the next corner of its way, or
/// where it is once it has finished.
pub fn nextPathPosition(self: *Navigation, app: *App, e: Entity) !Vec3 {
    const agent = app.world.get(e, NavigationAgent3D) orelse return error.NotAnAgent;
    const at = hierarchy.globalPosition3D(&app.world, e) orelse return error.NotAnAgent;
    const state = try self.stateOf(app, e);

    var stale = !state.found or state.target.sub(agent.target_position).len() > 1e-4;
    if (!stale and state.next > 0 and state.next < state.path.items.len and !agent.navigation_finished) {
        stale = offLeg(at, state.path.items[state.next - 1], state.path.items[state.next]) > agent.path_max_distance;
    }
    if (stale) try self.refind(app, e, agent, state, at);
    const path = state.path.items;
    if (path.len == 0) return self.finish(app, e, agent, state, at);

    while (state.next < path.len - 1 and ground(at, path[state.next]) <= agent.path_desired_distance) state.next += 1;
    const last = path[path.len - 1];
    if (state.next >= path.len - 1 and ground(at, last) <= agent.target_desired_distance) return self.finish(app, e, agent, state, at);
    return path[@min(state.next, path.len - 1)];
}

fn finish(self: *Navigation, app: *App, e: Entity, agent: *NavigationAgent3D, state: *Agent, at: Vec3) !Vec3 {
    _ = self;
    const reached = ground(at, agent.target_position) <= agent.target_desired_distance;
    agent.navigation_finished = true;
    if (reached) agent.target_reached = true;
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
    return agent.navigation_finished;
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

/// Each agent that said what velocity it wants is told what it gets: the
/// nearest that keeps out of the way of the other agents with avoidance,
/// or the same where it has none.
pub fn avoid(self: *Navigation, app: *App, dt: f32) !void {
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
pub const path_color: debugdraw.Color = .hexa(0xF2D675FF);

/// Each region's mesh, its polygons' edges a little above it, and each
/// agent's way.
pub fn draw(self: *Navigation, app: *App, pen: debugdraw.Pen) void {
    var it = ecs.Query(.{NavigationRegion3D}).over(&app.world) catch return;
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(NavigationRegion3D)) |e, region| {
            const placed = placedRegion(app, e, region) orelse continue;
            drawMesh(placed, pen);
        }
    }
    for (self.agents.values()) |state| {
        const path = state.path.items;
        if (path.len < 2) continue;
        for (path[0 .. path.len - 1], path[1..]) |a, b| pen.line(a.add(.init(0, 0.05, 0)), b.add(.init(0, 0.05, 0)), path_color);
    }
}

pub fn drawMesh(placed: Placed, pen: debugdraw.Pen) void {
    const lift: navmesh.Vec3 = .{ 0, 0.03, 0 };
    for (placed.mesh.polygons, 0..) |p, i| {
        for (0..p.count) |k| {
            // Each shared edge once.
            const across = p.neighbours[k];
            if (across != NavMesh.none and across < i) continue;
            const a = placed.mesh.corner(@intCast(i), k) + lift;
            const b = placed.mesh.corner(@intCast(i), (k + 1) % p.count) + lift;
            pen.line(placed.world(a), placed.world(b), if (across == NavMesh.none) mesh_color else mesh_color.withAlpha(0.45));
        }
    }
}
