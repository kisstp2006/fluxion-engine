// SPDX-License-Identifier: BSD-3-Clause

//! A picture as BC's compressed blocks, made on the CPU as it is read: what a
//! desktop GPU samples straight from, at a quarter or an eighth of the
//! memory of the picture's own bytes. Each block is four by four texels; an
//! edge block of a level not a whole number of them repeats its last texels.
//!
//! - BC1, eight bytes a block: colour with no alpha - a surface's colour, its
//!   metal and roughness, its occlusion.
//! - BC3, sixteen: BC1's colour and an alpha of its own - leaves, a fence.
//! - BC5, sixteen: two channels, each as finely as BC3's alpha - a normal
//!   map's `x` and `y`, its `z` worked out again where it is read.
//!
//! The colour's two ends are found along the way its texels spread most and
//! then fitted to the texels that chose them, as stb_dxt and Godot's
//! importer do; the single channels take their least and most.

const std = @import("std");
const builtin = @import("builtin");

/// Which blocks a picture becomes.
pub const Kind = enum {
    bc1,
    bc3,
    bc5,

    /// Bytes in one block.
    pub fn blockBytes(self: Kind) usize {
        return if (self == .bc1) 8 else 16;
    }

    /// Bytes `width` by `height` texels take: whole blocks.
    pub fn size(self: Kind, width: u32, height: u32) usize {
        return @as(usize, (width + 3) / 4) * ((height + 3) / 4) * self.blockBytes();
    }
};

/// `rgba`, `width` by `height`, as blocks of `kind` into `out`, which holds
/// `kind.size(width, height)` bytes. Rows of blocks are shared between
/// threads where the picture is large and the program has them.
pub fn encode(kind: Kind, out: []u8, rgba: []const u8, width: u32, height: u32) void {
    const rows = (height + 3) / 4;
    const blocks = @as(usize, (width + 3) / 4) * rows;
    const threads = if (builtin.single_threaded or blocks < 4096) 1 else @min(std.Thread.getCpuCount() catch 1, 8, rows);
    if (threads <= 1) return encodeRows(kind, out, rgba, width, height, 0, rows);
    var workers: [8]?std.Thread = @splat(null);
    const per = (rows + @as(u32, @intCast(threads)) - 1) / @as(u32, @intCast(threads));
    var first: u32 = 0;
    for (workers[0..threads]) |*worker| {
        const last = @min(first + per, rows);
        if (first >= last) break;
        worker.* = std.Thread.spawn(.{}, encodeRows, .{ kind, out, rgba, width, height, first, last }) catch blk: {
            encodeRows(kind, out, rgba, width, height, first, last);
            break :blk null;
        };
        first = last;
    }
    for (workers[0..threads]) |worker| if (worker) |held| held.join();
}

fn encodeRows(kind: Kind, out: []u8, rgba: []const u8, width: u32, height: u32, first: u32, last: u32) void {
    const across = (width + 3) / 4;
    var texels: [16][4]u8 = undefined;
    for (first..last) |by| for (0..across) |bx| {
        for (0..4) |y| for (0..4) |x| {
            const tx = @min(bx * 4 + x, width - 1);
            const ty = @min(by * 4 + y, height - 1);
            texels[y * 4 + x] = rgba[(ty * width + tx) * 4 ..][0..4].*;
        };
        const at = (by * across + bx) * kind.blockBytes();
        switch (kind) {
            .bc1 => out[at..][0..8].* = colourBlock(&texels),
            .bc3 => {
                out[at..][0..8].* = channelBlock(&texels, 3);
                out[at + 8 ..][0..8].* = colourBlock(&texels);
            },
            .bc5 => {
                out[at..][0..8].* = channelBlock(&texels, 0);
                out[at + 8 ..][0..8].* = channelBlock(&texels, 1);
            },
        }
    };
}

/// Whether every texel of `rgba` is opaque: BC1 holds it, or BC3 is needed.
pub fn isOpaque(rgba: []const u8) bool {
    var at: usize = 3;
    while (at < rgba.len) : (at += 4) if (rgba[at] != 255) return false;
    return true;
}

// -------------------------------------------------------------------------
// Colour: BC1's block
// -------------------------------------------------------------------------

const Vec3 = @Vector(3, f32);

fn colourOf(t: [4]u8) Vec3 {
    return .{ @floatFromInt(t[0]), @floatFromInt(t[1]), @floatFromInt(t[2]) };
}

/// A colour as five, six and five bits, rounded.
fn to565(c: Vec3) u16 {
    const r: u16 = @intFromFloat(@round(std.math.clamp(c[0], 0, 255) * 31.0 / 255.0));
    const g: u16 = @intFromFloat(@round(std.math.clamp(c[1], 0, 255) * 63.0 / 255.0));
    const b: u16 = @intFromFloat(@round(std.math.clamp(c[2], 0, 255) * 31.0 / 255.0));
    return (r << 11) | (g << 5) | b;
}

/// Five, six and five bits as the colour a GPU reads them as.
fn from565(v: u16) Vec3 {
    const r: u32 = (v >> 11) & 31;
    const g: u32 = (v >> 5) & 63;
    const b: u32 = v & 31;
    return .{ @floatFromInt((r << 3) | (r >> 2)), @floatFromInt((g << 2) | (g >> 4)), @floatFromInt((b << 3) | (b >> 2)) };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

/// Sixteen texels' colour as two ends and a two-bit step between them each,
/// the first end the larger: the four-colour block every BC reads.
fn colourBlock(texels: *const [16][4]u8) [8]u8 {
    var points: [16]Vec3 = undefined;
    var mean: Vec3 = @splat(0);
    for (texels, &points) |t, *p| {
        p.* = colourOf(t);
        mean += p.*;
    }
    mean /= @splat(16);
    // The way they spread most: the covariance's largest axis, by a few
    // rounds of multiplying a guess by it.
    var cov: [6]f32 = @splat(0);
    for (points) |p| {
        const d = p - mean;
        cov[0] += d[0] * d[0];
        cov[1] += d[0] * d[1];
        cov[2] += d[0] * d[2];
        cov[3] += d[1] * d[1];
        cov[4] += d[1] * d[2];
        cov[5] += d[2] * d[2];
    }
    var axis: Vec3 = .{ 1, 1, 1 };
    for (0..6) |_| {
        const next: Vec3 = .{
            cov[0] * axis[0] + cov[1] * axis[1] + cov[2] * axis[2],
            cov[1] * axis[0] + cov[3] * axis[1] + cov[4] * axis[2],
            cov[2] * axis[0] + cov[4] * axis[1] + cov[5] * axis[2],
        };
        const length = @sqrt(dot(next, next));
        if (length < 1e-6) break;
        axis = next / @as(Vec3, @splat(length));
    }
    var low: f32 = std.math.inf(f32);
    var high: f32 = -std.math.inf(f32);
    for (points) |p| {
        const along = dot(p - mean, axis);
        low = @min(low, along);
        high = @max(high, along);
    }
    var ends: [2]Vec3 = .{ mean + axis * @as(Vec3, @splat(high)), mean + axis * @as(Vec3, @splat(low)) };
    var block = packColour(&points, ends);
    // Fitted to the texels that chose each step, twice: the ends that make
    // the least error for those choices.
    for (0..2) |_| {
        var a: f32 = 0;
        var b: f32 = 0;
        var c: f32 = 0;
        var x0: Vec3 = @splat(0);
        var x1: Vec3 = @splat(0);
        const weights = [4]f32{ 0, 1, 1.0 / 3.0, 2.0 / 3.0 };
        for (points, 0..) |p, i| {
            const w = weights[(block.indices >> @intCast(i * 2)) & 3];
            a += (1 - w) * (1 - w);
            b += w * (1 - w);
            c += w * w;
            x0 += p * @as(Vec3, @splat(1 - w));
            x1 += p * @as(Vec3, @splat(w));
        }
        const det = a * c - b * b;
        if (@abs(det) < 1e-6) break;
        ends = .{ (x0 * @as(Vec3, @splat(c)) - x1 * @as(Vec3, @splat(b))) / @as(Vec3, @splat(det)), (x1 * @as(Vec3, @splat(a)) - x0 * @as(Vec3, @splat(b))) / @as(Vec3, @splat(det)) };
        const fitted = packColour(&points, ends);
        if (fitted.error_sum >= block.error_sum) break;
        block = fitted;
    }
    var out: [8]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], block.c0, .little);
    std.mem.writeInt(u16, out[2..4], block.c1, .little);
    std.mem.writeInt(u32, out[4..8], block.indices, .little);
    return out;
}

const Packed = struct { c0: u16, c1: u16, indices: u32, error_sum: f32 };

/// The ends as 5:6:5, the first the larger, and each texel's nearest step.
fn packColour(points: *const [16]Vec3, ends: [2]Vec3) Packed {
    var c0 = to565(ends[0]);
    var c1 = to565(ends[1]);
    if (c0 < c1) std.mem.swap(u16, &c0, &c1);
    if (c0 == c1) {
        // One colour: nothing between, every texel the first end.
        var sum: f32 = 0;
        const only = from565(c0);
        for (points) |p| sum += dot(p - only, p - only);
        return .{ .c0 = c0, .c1 = c1, .indices = 0, .error_sum = sum };
    }
    const e0 = from565(c0);
    const e1 = from565(c1);
    const palette = [4]Vec3{ e0, e1, (e0 * @as(Vec3, @splat(2)) + e1) / @as(Vec3, @splat(3)), (e0 + e1 * @as(Vec3, @splat(2))) / @as(Vec3, @splat(3)) };
    var indices: u32 = 0;
    var sum: f32 = 0;
    for (points, 0..) |p, i| {
        var best: u32 = 0;
        var nearest = std.math.inf(f32);
        for (palette, 0..) |q, k| {
            const d = dot(p - q, p - q);
            if (d < nearest) {
                nearest = d;
                best = @intCast(k);
            }
        }
        indices |= best << @intCast(i * 2);
        sum += nearest;
    }
    return .{ .c0 = c0, .c1 = c1, .indices = indices, .error_sum = sum };
}

// -------------------------------------------------------------------------
// One channel: BC4's block, BC3's alpha and each half of BC5
// -------------------------------------------------------------------------

/// Channel `channel` of sixteen texels as its most and least and eight steps
/// between: the most first, so the block reads as eight steps, not six.
fn channelBlock(texels: *const [16][4]u8, channel: usize) [8]u8 {
    var high: u8 = 0;
    var low: u8 = 255;
    for (texels) |t| {
        high = @max(high, t[channel]);
        low = @min(low, t[channel]);
    }
    var out: [8]u8 = .{ high, low, 0, 0, 0, 0, 0, 0 };
    if (high == low) return out;
    var bits: u64 = 0;
    const span: f32 = @floatFromInt(high - low);
    for (texels, 0..) |t, i| {
        // How far up from the least, in sevenths: seven is the most (index
        // nought), nought the least (index one), and the rest 8 - steps.
        const steps: u64 = @intFromFloat(@round(@as(f32, @floatFromInt(t[channel] - low)) * 7.0 / span));
        const index: u64 = switch (steps) {
            7 => 0,
            0 => 1,
            else => 8 - steps,
        };
        bits |= index << @intCast(i * 3);
    }
    for (0..6) |k| out[2 + k] = @truncate(bits >> @intCast(k * 8));
    return out;
}

// -------------------------------------------------------------------------
// Reading blocks back, for the tests
// -------------------------------------------------------------------------

fn decodeColour(block: *const [8]u8, out: *[16][3]u8) void {
    const c0 = std.mem.readInt(u16, block[0..2], .little);
    const c1 = std.mem.readInt(u16, block[2..4], .little);
    const e0 = from565(c0);
    const e1 = from565(c1);
    const palette = [4]Vec3{ e0, e1, (e0 * @as(Vec3, @splat(2)) + e1) / @as(Vec3, @splat(3)), (e0 + e1 * @as(Vec3, @splat(2))) / @as(Vec3, @splat(3)) };
    const indices = std.mem.readInt(u32, block[4..8], .little);
    for (out, 0..) |*t, i| {
        const p = palette[(indices >> @intCast(i * 2)) & 3];
        t.* = .{ @intFromFloat(@round(p[0])), @intFromFloat(@round(p[1])), @intFromFloat(@round(p[2])) };
    }
}

fn decodeChannel(block: *const [8]u8, out: *[16]u8) void {
    const a0: f32 = @floatFromInt(block[0]);
    const a1: f32 = @floatFromInt(block[1]);
    var bits: u64 = 0;
    for (0..6) |k| bits |= @as(u64, block[2 + k]) << @intCast(k * 8);
    for (out, 0..) |*v, i| {
        const index: u32 = @intCast((bits >> @intCast(i * 3)) & 7);
        const value = switch (index) {
            0 => a0,
            1 => a1,
            else => (@as(f32, @floatFromInt(8 - index)) * a0 + @as(f32, @floatFromInt(index - 1)) * a1) / 7.0,
        };
        v.* = @intFromFloat(@round(value));
    }
}

const testing = std.testing;

/// How far, on average, a picture's texels come back from its blocks, in
/// eighths of a bit: the mean absolute difference over the channels read.
fn meanError(kind: Kind, rgba: []const u8, width: u32, height: u32) !f32 {
    const blocks = try testing.allocator.alloc(u8, kind.size(width, height));
    defer testing.allocator.free(blocks);
    encode(kind, blocks, rgba, width, height);
    var sum: f64 = 0;
    var count: f64 = 0;
    const across = (width + 3) / 4;
    for (0..height) |y| for (0..width) |x| {
        const at = ((y / 4) * across + x / 4) * kind.blockBytes();
        const i = (y % 4) * 4 + x % 4;
        const t = rgba[(y * width + x) * 4 ..][0..4];
        switch (kind) {
            .bc1, .bc3 => {
                var colours: [16][3]u8 = undefined;
                decodeColour(blocks[at + (if (kind == .bc3) @as(usize, 8) else 0) ..][0..8], &colours);
                for (0..3) |ch| sum += @abs(@as(f64, @floatFromInt(colours[i][ch])) - @as(f64, @floatFromInt(t[ch])));
                count += 3;
                if (kind == .bc3) {
                    var alpha: [16]u8 = undefined;
                    decodeChannel(blocks[at..][0..8], &alpha);
                    sum += @abs(@as(f64, @floatFromInt(alpha[i])) - @as(f64, @floatFromInt(t[3])));
                    count += 1;
                }
            },
            .bc5 => for (0..2) |ch| {
                var values: [16]u8 = undefined;
                decodeChannel(blocks[at + ch * 8 ..][0..8], &values);
                sum += @abs(@as(f64, @floatFromInt(values[i])) - @as(f64, @floatFromInt(t[ch])));
                count += 1;
            },
        }
    };
    return @floatCast(sum / count);
}

/// A smooth picture with some grain: what a surface's picture is like.
fn surface(comptime width: u32, comptime height: u32) [width * height * 4]u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [width * height * 4]u8 = undefined;
    var seed: u32 = 12345;
    for (0..height) |y| for (0..width) |x| {
        seed = seed *% 1103515245 +% 12345;
        const grain: i32 = @as(i32, @intCast((seed >> 16) % 17)) - 8;
        const base = [4]i32{ @intCast(x * 255 / width), @intCast(y * 255 / height), @intCast((x + y) * 127 / width), @intCast(255 - y * 200 / height) };
        for (0..4) |ch| out[(y * width + x) * 4 + ch] = @intCast(std.math.clamp(base[ch] + grain, 0, 255));
    };
    return out;
}

test "a colour block holds one colour exactly, and the step between its ends where it lies" {
    var texels: [16][4]u8 = @splat(.{ 255, 0, 0, 255 });
    var colours: [16][3]u8 = undefined;
    decodeColour(&colourBlock(&texels), &colours);
    for (colours) |c| try testing.expectEqual([3]u8{ 255, 0, 0 }, c);
    // Half black and half white: both ends, each texel the one it is.
    for (&texels, 0..) |*t, i| t.* = if (i < 8) .{ 0, 0, 0, 255 } else .{ 255, 255, 255, 255 };
    decodeColour(&colourBlock(&texels), &colours);
    for (colours, 0..) |c, i| try testing.expectEqual(if (i < 8) [3]u8{ 0, 0, 0 } else [3]u8{ 255, 255, 255 }, c);
}

test "a channel block holds its least and most, and the eight steps between" {
    var texels: [16][4]u8 = undefined;
    for (&texels, 0..) |*t, i| t.* = .{ @intCast(i * 17), 0, 0, 0 };
    var values: [16]u8 = undefined;
    decodeChannel(&channelBlock(&texels, 0), &values);
    try testing.expectEqual(@as(u8, 0), values[0]);
    try testing.expectEqual(@as(u8, 255), values[15]);
    for (texels, values) |t, v| try testing.expect(@abs(@as(i32, t[0]) - v) <= 19);
    for (&texels) |*t| t.* = .{ 77, 0, 0, 0 };
    decodeChannel(&channelBlock(&texels, 0), &values);
    for (values) |v| try testing.expectEqual(@as(u8, 77), v);
}

test "a surface's picture comes back from BC1, BC3 and BC5 within a few steps a channel" {
    const picture = surface(64, 48);
    try testing.expect(try meanError(.bc1, &picture, 64, 48) < 6);
    try testing.expect(try meanError(.bc3, &picture, 64, 48) < 6);
    try testing.expect(try meanError(.bc5, &picture, 64, 48) < 3);
    // A level not a whole number of blocks: its edge block repeats its last texels.
    try testing.expect(try meanError(.bc1, picture[0 .. 5 * 3 * 4], 5, 3) < 8);
    try testing.expectEqual(@as(usize, 8), Kind.bc1.size(2, 2));
    try testing.expectEqual(@as(usize, 32), Kind.bc5.size(5, 3));
    try testing.expect(isOpaque(&[_]u8{ 1, 2, 3, 255 }));
    try testing.expect(!isOpaque(&[_]u8{ 1, 2, 3, 254 }));
}

test "a large picture is shared between threads and comes out as it would on one" {
    const width = 256;
    const height = 256;
    const picture = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(picture);
    for (picture, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    const together = try testing.allocator.alloc(u8, Kind.bc3.size(width, height));
    defer testing.allocator.free(together);
    const alone = try testing.allocator.alloc(u8, Kind.bc3.size(width, height));
    defer testing.allocator.free(alone);
    encode(.bc3, together, picture, width, height);
    encodeRows(.bc3, alone, picture, width, height, 0, height / 4);
    try testing.expectEqualSlices(u8, alone, together);
}
