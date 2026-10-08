// SPDX-License-Identifier: BSD-3-Clause

//! What each frame cost, kept while `--stats report.json` asks: how long it
//! took from the one before, the work in it - its fixed steps, the game's
//! systems, the draw - and what the 3D layer drew. At the end it is written
//! as JSON, for a person or a script to set one backend, one machine or one
//! change beside another, and said in the log.
//!
//! ```bash
//! game --stats vulkan.json --vsync disabled --frames 600
//! ```
//!
//! The first `warm_up` frames are left out: shaders are made and pictures
//! read then. With the refresh waited on - vsync - a frame takes at least a
//! refresh whatever its work: `work_ms` is the time a frame worked, the
//! wait for the next one left out.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");

const log = std.log.scoped(.fluxion_engine);

/// One frame.
pub const Frame = struct {
    /// From the frame before to this one.
    frame_ms: f32,
    /// What the frame did, from its start to its end, the wait for the next
    /// left out.
    work_ms: f32,
    /// Its fixed steps: the physics and the game's `fixed` systems.
    fixed_ms: f32,
    /// The game's systems, every stage.
    systems_ms: f32,
    /// Drawing and showing it.
    draw_ms: f32,
    /// What the 3D layer drew, every view of it this frame together.
    meshes: u32,
    draw_calls: u32,
    triangles: u64,
    culled: u32,
    shadow_views_drawn: u32,
};

/// The frames, while there is somewhere to write them.
pub const FrameStats = struct {
    /// Where the report goes: a path on this machine. Null keeps nothing.
    path: ?[]const u8 = null,
    frames: std.ArrayList(Frame) = .empty,
    /// The frame under way: when it began, and how long its parts took.
    began: ?std.Io.Timestamp = null,
    fixed_ns: i96 = 0,
    draw_ns: i96 = 0,

    /// The frames left out at the start.
    pub const warm_up = 10;
    /// The most frames kept: an hour at sixty a second, and then the
    /// report is of the first hour.
    pub const most = 60 * 60 * 60;

    pub fn deinit(self: *FrameStats, gpa: Allocator) void {
        self.frames.deinit(gpa);
    }

    pub fn keeping(self: *const FrameStats) bool {
        return self.path != null;
    }

    /// A frame begins.
    pub fn begin(self: *FrameStats, io: ?std.Io) void {
        if (!self.keeping()) return;
        self.began = if (io) |held| std.Io.Timestamp.now(held, .awake) else null;
        self.fixed_ns = 0;
        self.draw_ns = 0;
    }

    /// When a part of the frame starts, to be given to `took`.
    pub fn start(self: *const FrameStats, io: ?std.Io) ?std.Io.Timestamp {
        if (!self.keeping()) return null;
        const held = io orelse return null;
        return std.Io.Timestamp.now(held, .awake);
    }

    /// How long since `started`, in nanoseconds; nought when not kept.
    pub fn took(io: ?std.Io, started: ?std.Io.Timestamp) i96 {
        const then = started orelse return 0;
        return then.durationTo(.now(io.?, .awake)).nanoseconds;
    }

    /// The frame ends: kept with what `rest` says of it.
    pub fn end(self: *FrameStats, gpa: Allocator, io: ?std.Io, frame_seconds: f32, systems_ns: i96, rest: Frame) void {
        if (!self.keeping() or self.frames.items.len >= most) return;
        var frame = rest;
        frame.frame_ms = frame_seconds * 1000;
        frame.work_ms = ms(took(io, self.began));
        frame.fixed_ms = ms(self.fixed_ns);
        frame.draw_ms = ms(self.draw_ns);
        frame.systems_ms = ms(systems_ns);
        self.frames.append(gpa, frame) catch {};
    }

    fn ms(ns: i96) f32 {
        return @floatCast(@as(f64, @floatFromInt(ns)) / 1e6);
    }

    /// The middle and the spread of one number over the frames.
    pub const Spread = struct {
        mean: f64 = 0,
        p50: f64 = 0,
        p95: f64 = 0,
        p99: f64 = 0,
        max: f64 = 0,
    };

    /// What the report says.
    pub const Report = struct {
        fluxion_frame_stats: u32 = 1,
        backend: []const u8 = "",
        frames: usize = 0,
        frame_ms: Spread = .{},
        work_ms: Spread = .{},
        fixed_ms: Spread = .{},
        systems_ms: Spread = .{},
        draw_ms: Spread = .{},
        /// Means over the frames.
        meshes: f64 = 0,
        draw_calls: f64 = 0,
        triangles: f64 = 0,
        culled: f64 = 0,
        shadow_views_drawn: f64 = 0,
    };

    /// The frames after the warm-up, summed up.
    pub fn report(self: *const FrameStats, gpa: Allocator, backend: []const u8) Allocator.Error!Report {
        const all = self.frames.items;
        const kept = if (all.len > warm_up * 2) all[warm_up..] else all;
        var out: Report = .{ .backend = backend, .frames = kept.len };
        if (kept.len == 0) return out;
        const numbers = try gpa.alloc(f64, kept.len);
        defer gpa.free(numbers);
        inline for (.{ "frame_ms", "work_ms", "fixed_ms", "systems_ms", "draw_ms" }) |name| {
            for (kept, numbers) |frame, *n| n.* = @field(frame, name);
            @field(out, name) = spreadOf(numbers);
        }
        inline for (.{ "meshes", "draw_calls", "triangles", "culled", "shadow_views_drawn" }) |name| {
            var sum: f64 = 0;
            for (kept) |frame| sum += @floatFromInt(@field(frame, name));
            @field(out, name) = sum / @as(f64, @floatFromInt(kept.len));
        }
        return out;
    }

    /// Write the report to `path`, and say it in the log.
    pub fn finish(self: *const FrameStats, gpa: Allocator, io: ?std.Io, backend: []const u8) void {
        const path = self.path orelse return;
        const made = self.report(gpa, backend) catch return;
        log.info("{d} frames: {d:.2} ms a frame ({d:.2} at the 95th, {d:.2} at most), {d:.2} ms of work, {d:.2} drawing; {d:.0} meshes in {d:.0} draws, {d:.0} triangles", .{
            made.frames, made.frame_ms.mean, made.frame_ms.p95, made.frame_ms.max, made.work_ms.mean, made.draw_ms.mean,
            made.meshes, made.draw_calls,    made.triangles,
        });
        const held = io orelse return;
        json.save(held, path, made, .{ .indent = 2 }) catch |err| log.warn("the frame stats were not written to {s}: {t}", .{ path, err });
    }
};

/// `numbers`' mean, middle, 95th and 99th from the bottom, and most;
/// sorted in place.
pub fn spreadOf(numbers: []f64) FrameStats.Spread {
    if (numbers.len == 0) return .{};
    var sum: f64 = 0;
    for (numbers) |n| sum += n;
    std.mem.sort(f64, numbers, {}, std.sort.asc(f64));
    return .{
        .mean = sum / @as(f64, @floatFromInt(numbers.len)),
        .p50 = at(numbers, 0.5),
        .p95 = at(numbers, 0.95),
        .p99 = at(numbers, 0.99),
        .max = numbers[numbers.len - 1],
    };
}

fn at(sorted: []const f64, share: f64) f64 {
    const last: f64 = @floatFromInt(sorted.len - 1);
    return sorted[@intFromFloat(@round(last * share))];
}

test "the spread of a frame's times: the mean, the middle, the slow ones, the slowest" {
    var numbers = [_]f64{ 5, 1, 4, 2, 3, 100, 6, 7, 8, 9 };
    const spread = spreadOf(&numbers);
    try testing.expectApproxEqAbs(@as(f64, 14.5), spread.mean, 1e-9);
    try testing.expectEqual(@as(f64, 6), spread.p50);
    try testing.expectEqual(@as(f64, 100), spread.p95);
    try testing.expectEqual(@as(f64, 100), spread.max);
}

test "a report leaves the warm-up out, and nothing is kept without a path" {
    var stats: FrameStats = .{};
    defer stats.deinit(testing.allocator);
    stats.begin(null);
    stats.end(testing.allocator, null, 0.016, 0, std.mem.zeroes(Frame));
    try testing.expectEqual(@as(usize, 0), stats.frames.items.len);

    stats.path = "unused.json";
    for (0..30) |i| {
        var frame = std.mem.zeroes(Frame);
        frame.meshes = if (i < FrameStats.warm_up) 1000 else 10;
        stats.begin(null);
        stats.end(testing.allocator, null, 0.016, 0, frame);
    }
    const made = try stats.report(testing.allocator, "test");
    try testing.expectEqual(@as(usize, 20), made.frames);
    try testing.expectApproxEqAbs(@as(f64, 10), made.meshes, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 16), made.frame_ms.mean, 1e-3);
}
