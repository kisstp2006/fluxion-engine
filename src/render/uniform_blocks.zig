// SPDX-License-Identifier: BSD-3-Clause

//! Uniform blocks laid one after another in one buffer, each where the device
//! binds a block from, and bound by range: a frame's numbers go up in one
//! upload, rather than a buffer to a block.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");

pub const UniformBlocks = struct {
    /// What the buffer is called in a debugger.
    label: []const u8,
    /// Grown when a frame's blocks do not fit, never shrunk.
    buffer: ?rhi.Buffer = null,
    room: u32 = 0,
    /// This frame's blocks, as they will be in the buffer.
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *UniformBlocks, gpa: Allocator, device: *rhi.Device) void {
        if (self.buffer) |buffer| device.destroyBuffer(buffer);
        self.bytes.deinit(gpa);
        self.* = undefined;
    }

    /// Start the blocks over, for another frame.
    pub fn clear(self: *UniformBlocks) void {
        self.bytes.clearRetainingCapacity();
    }

    /// `bytes` after the blocks so far, at the next place the device binds a
    /// block from: where it is, for `setUniformBufferRange`.
    pub fn place(self: *UniformBlocks, gpa: Allocator, device: *rhi.Device, bytes: []const u8) !u32 {
        const old = self.bytes.items.len;
        const at = std.mem.alignForward(usize, old, device.caps().limits.uniform_offset_alignment);
        try self.bytes.resize(gpa, at + bytes.len);
        @memset(self.bytes.items[old..at], 0);
        @memcpy(self.bytes.items[at..][0..bytes.len], bytes);
        return @intCast(at);
    }

    /// The blocks placed into the buffer, made larger first if they do not fit.
    pub fn upload(self: *UniformBlocks, device: *rhi.Device) !void {
        const size: u32 = @intCast(self.bytes.items.len);
        if (size == 0) return;
        if (self.room < size) {
            var room = @max(self.room, 4096);
            while (room < size) room *= 2;
            const grown = try device.createBuffer(.{ .kind = .uniform, .size = room, .dynamic = true, .label = self.label });
            if (self.buffer) |old| device.destroyBuffer(old);
            self.buffer = grown;
            self.room = room;
        }
        try device.updateBuffer(self.buffer.?, 0, self.bytes.items);
    }
};

test "blocks are placed where a block is bound from, and the buffer grows to hold them" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var blocks: UniformBlocks = .{ .label = "test blocks" };
    defer blocks.deinit(testing.allocator, &device);
    const alignment = device.caps().limits.uniform_offset_alignment;

    try testing.expectEqual(@as(u32, 0), try blocks.place(testing.allocator, &device, &(.{1} ** 16)));
    try testing.expectEqual(alignment, try blocks.place(testing.allocator, &device, &(.{2} ** 32)));
    // What lies between two blocks is zero.
    try testing.expectEqual(@as(u8, 0), blocks.bytes.items[16]);
    try blocks.upload(&device);
    try testing.expect(blocks.buffer != null);
    try testing.expectEqual(@as(u32, 4096), blocks.room);

    // A frame with more than there is room for gets a larger buffer.
    blocks.clear();
    for (0..20) |_| _ = try blocks.place(testing.allocator, &device, &(.{3} ** 64));
    try blocks.upload(&device);
    try testing.expect(blocks.room >= 19 * alignment + 64);
}
