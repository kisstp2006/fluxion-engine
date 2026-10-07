// SPDX-License-Identifier: BSD-3-Clause

//! Agents keeping out of each other's way, on the ground: each says the
//! velocity it wants, and is given the nearest velocity that will not run
//! it into another within `time_horizon` - with each of two taking half of
//! the turning away (optimal reciprocal collision avoidance). Each other
//! agent near enough makes a half-plane of the velocities that keep clear
//! of it; the velocity chosen is the one in all of them, no faster than
//! the agent goes, nearest the one it wants. When there is none, the one
//! that goes least into them.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// On the ground: x and z.
pub const Vec2 = @Vector(2, f32);

pub const Agent = struct {
    position: Vec2,
    /// What it moved with last.
    velocity: Vec2,
    /// What it wants.
    preferred: Vec2,
    radius: f32,
    max_speed: f32,
    /// Others further than this are not looked at, and no more than
    /// `max_neighbours` of the nearest.
    neighbour_distance: f32 = 10,
    max_neighbours: usize = 10,
    /// How far ahead, in seconds, it keeps clear of the others.
    time_horizon: f32 = 1,
};

const Line = struct {
    point: Vec2,
    direction: Vec2,
};

const epsilon = 1e-5;

fn dot(a: Vec2, b: Vec2) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

fn det(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

fn scale(a: Vec2, s: f32) Vec2 {
    return a * @as(Vec2, @splat(s));
}

fn normalize(a: Vec2) Vec2 {
    const l = @sqrt(dot(a, a));
    return if (l > 0) scale(a, 1 / l) else a;
}

/// Each agent's velocity, in `out`: `dt` is the step it will move by.
pub fn solve(gpa: Allocator, agents: []const Agent, dt: f32, out: []Vec2) Allocator.Error!void {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    var near: std.ArrayList(Near) = .empty;
    defer near.deinit(gpa);
    var projected: std.ArrayList(Line) = .empty;
    defer projected.deinit(gpa);

    for (agents, out, 0..) |a, *result, i| {
        lines.clearRetainingCapacity();
        near.clearRetainingCapacity();
        for (agents, 0..) |b, j| {
            if (i == j) continue;
            const d = b.position - a.position;
            const dist_sq = dot(d, d);
            if (dist_sq > a.neighbour_distance * a.neighbour_distance) continue;
            try near.append(gpa, .{ .index = j, .dist_sq = dist_sq });
        }
        std.mem.sort(Near, near.items, {}, Near.less);
        const count = @min(near.items.len, a.max_neighbours);

        const inv_horizon = 1 / @max(a.time_horizon, epsilon);
        for (near.items[0..count]) |n| {
            const b = agents[n.index];
            const relative_position = b.position - a.position;
            const relative_velocity = a.velocity - b.velocity;
            const dist_sq = n.dist_sq;
            const combined_radius = a.radius + b.radius;
            const combined_sq = combined_radius * combined_radius;
            var line: Line = undefined;
            var u: Vec2 = undefined;
            if (dist_sq > combined_sq) {
                // Apart: the cut-off circle's edge, or a leg of the cone.
                const w = relative_velocity - scale(relative_position, inv_horizon);
                const w_len_sq = dot(w, w);
                const dot1 = dot(w, relative_position);
                if (dot1 < 0 and dot1 * dot1 > combined_sq * w_len_sq) {
                    const w_len = @sqrt(w_len_sq);
                    const unit_w = scale(w, 1 / w_len);
                    line.direction = .{ unit_w[1], -unit_w[0] };
                    u = scale(unit_w, combined_radius * inv_horizon - w_len);
                } else {
                    const leg = @sqrt(dist_sq - combined_sq);
                    const rp = relative_position;
                    if (det(rp, w) > 0) {
                        line.direction = scale(.{ rp[0] * leg - rp[1] * combined_radius, rp[0] * combined_radius + rp[1] * leg }, 1 / dist_sq);
                    } else {
                        line.direction = scale(.{ rp[0] * leg + rp[1] * combined_radius, -rp[0] * combined_radius + rp[1] * leg }, -1 / dist_sq);
                    }
                    const dot2 = dot(relative_velocity, line.direction);
                    u = scale(line.direction, dot2) - relative_velocity;
                }
            } else {
                // Already touching: out within the step.
                const inv_dt = 1 / @max(dt, epsilon);
                const w = relative_velocity - scale(relative_position, inv_dt);
                const w_len = @sqrt(dot(w, w));
                const unit_w = if (w_len > 0) scale(w, 1 / w_len) else Vec2{ 1, 0 };
                line.direction = .{ unit_w[1], -unit_w[0] };
                u = scale(unit_w, combined_radius * inv_dt - w_len);
            }
            // Each of the two turns half of the way.
            line.point = a.velocity + scale(u, 0.5);
            try lines.append(gpa, line);
        }

        var velocity: Vec2 = undefined;
        const failed = program2(lines.items, a.max_speed, a.preferred, false, &velocity);
        if (failed < lines.items.len) try program3(gpa, lines.items, failed, a.max_speed, &velocity, &projected);
        result.* = velocity;
    }
}

const Near = struct {
    index: usize,
    dist_sq: f32,

    fn less(_: void, a: Near, b: Near) bool {
        return a.dist_sq < b.dist_sq;
    }
};

/// The best velocity on line `n`, within the others before it and the
/// speed limit.
fn program1(lines: []const Line, n: usize, radius: f32, preferred: Vec2, direction_only: bool, result: *Vec2) bool {
    const line = lines[n];
    const dot_product = dot(line.point, line.direction);
    const discriminant = dot_product * dot_product + radius * radius - dot(line.point, line.point);
    if (discriminant < 0) return false;
    const root = @sqrt(discriminant);
    var t_left = -dot_product - root;
    var t_right = -dot_product + root;
    for (lines[0..n]) |other| {
        const denominator = det(line.direction, other.direction);
        const numerator = det(other.direction, line.point - other.point);
        if (@abs(denominator) <= epsilon) {
            if (numerator < 0) return false;
            continue;
        }
        const t = numerator / denominator;
        if (denominator >= 0) t_right = @min(t_right, t) else t_left = @max(t_left, t);
        if (t_left > t_right) return false;
    }
    if (direction_only) {
        result.* = line.point + scale(line.direction, if (dot(preferred, line.direction) > 0) t_right else t_left);
    } else {
        const t = dot(line.direction, preferred - line.point);
        result.* = line.point + scale(line.direction, std.math.clamp(t, t_left, t_right));
    }
    return true;
}

/// The velocity in every half-plane nearest the one wanted: the index of
/// the first line that could not be kept, or the count when all were.
fn program2(lines: []const Line, radius: f32, preferred: Vec2, direction_only: bool, result: *Vec2) usize {
    if (direction_only) {
        result.* = scale(preferred, radius);
    } else if (dot(preferred, preferred) > radius * radius) {
        result.* = scale(normalize(preferred), radius);
    } else result.* = preferred;
    for (lines, 0..) |line, i| {
        if (det(line.direction, line.point - result.*) > 0) {
            const kept = result.*;
            if (!program1(lines, i, radius, preferred, direction_only, result)) {
                result.* = kept;
                return i;
            }
        }
    }
    return lines.len;
}

/// With no velocity in all of them: the one that goes least far into any.
fn program3(gpa: Allocator, lines: []const Line, begin: usize, radius: f32, result: *Vec2, projected: *std.ArrayList(Line)) Allocator.Error!void {
    var distance: f32 = 0;
    for (lines[begin..], begin..) |line, i| {
        if (det(line.direction, line.point - result.*) <= distance) continue;
        projected.clearRetainingCapacity();
        for (lines[0..i]) |other| {
            var p: Line = undefined;
            const determinant = det(line.direction, other.direction);
            if (@abs(determinant) <= epsilon) {
                if (dot(line.direction, other.direction) > 0) continue;
                p.point = scale(line.point + other.point, 0.5);
            } else {
                p.point = line.point + scale(line.direction, det(other.direction, line.point - other.point) / determinant);
            }
            p.direction = normalize(other.direction - line.direction);
            try projected.append(gpa, p);
        }
        const kept = result.*;
        if (program2(projected.items, radius, .{ -line.direction[1], line.direction[0] }, true, result) < projected.items.len) result.* = kept;
        distance = det(line.direction, line.point - result.*);
    }
}

test "an agent alone goes as it wants, no faster than it can" {
    var out: [1]Vec2 = undefined;
    try solve(testing.allocator, &.{.{ .position = .{ 0, 0 }, .velocity = .{ 0, 0 }, .preferred = .{ 3, 4 }, .radius = 0.5, .max_speed = 10 }}, 0.1, &out);
    try testing.expectEqual(Vec2{ 3, 4 }, out[0]);
    try solve(testing.allocator, &.{.{ .position = .{ 0, 0 }, .velocity = .{ 0, 0 }, .preferred = .{ 30, 40 }, .radius = 0.5, .max_speed = 5 }}, 0.1, &out);
    try testing.expectApproxEqAbs(@as(f32, 5), @sqrt(dot(out[0], out[0])), 1e-4);
}

test "two agents walking at each other each turn aside, and pass without touching" {
    var agents = [_]Agent{
        .{ .position = .{ -5, 0.05 }, .velocity = .{ 1, 0 }, .preferred = .{ 1, 0 }, .radius = 0.5, .max_speed = 1.5, .time_horizon = 3 },
        .{ .position = .{ 5, -0.05 }, .velocity = .{ -1, 0 }, .preferred = .{ -1, 0 }, .radius = 0.5, .max_speed = 1.5, .time_horizon = 3 },
    };
    var out: [2]Vec2 = undefined;
    const dt = 0.05;
    var closest: f32 = std.math.inf(f32);
    for (0..400) |_| {
        try solve(testing.allocator, &agents, dt, &out);
        for (&agents, out) |*a, v| {
            a.velocity = v;
            a.position += scale(v, dt);
            a.preferred = .{ if (a.preferred[0] > 0) 1 else -1, 0 };
        }
        const d = agents[1].position - agents[0].position;
        closest = @min(closest, @sqrt(dot(d, d)));
    }
    // Never nearer than their two radii, give or take.
    try testing.expect(closest > 0.95);
    // And past each other.
    try testing.expect(agents[0].position[0] > 4 and agents[1].position[0] < -4);
}
