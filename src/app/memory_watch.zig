// SPDX-License-Identifier: BSD-3-Clause

//! The card's memory, watched where its driver says how full it is
//! (`rhi.Device.memory`). A card shared with another program - an editor
//! with the same map open beside the game, a second game - fills, and the
//! driver makes room by moving what was there into the machine's own memory.
//! What it moves stays there after the other program lets go: a render
//! target drawn into every frame is then drawn into across the bus, and a
//! game on a 6 GB card that drew a frame in 13 ms took 75. A window resized
//! makes them again, back in the card - which is what this does, once the
//! driver has moved anything and there is room again.
//!
//! ```zig
//! if (watch.due(delta)) if (watch.saw(device.memory())) renderer.remakeTargets();
//! ```

const std = @import("std");
const testing = std.testing;

const rhi = @import("fluxion_rhi");

pub const MemoryWatch = struct {
    /// Seconds until the driver is asked again.
    wait: f32 = 0,
    /// The driver's count of what it moved out, when last asked.
    evictions: ?u64 = null,
    /// Moved out since the targets were last made: they may have been.
    moved: bool = false,
    /// Seconds since the targets were last made by this.
    since_remade: f32 = at_most_every,

    /// Seconds between asking the driver.
    pub const every: f32 = 1;
    /// What has to be free before the targets are made again: room for
    /// them, and some, or they would be made in the machine's memory again.
    pub const room_kib: u64 = 384 * 1024;
    /// The fewest seconds between two makings, so a card that stays full
    /// does not have them made again and again.
    pub const at_most_every: f32 = 8;

    /// Whether to ask the driver this frame, `delta` seconds after the last.
    pub fn due(self: *MemoryWatch, delta: f32) bool {
        self.since_remade += delta;
        self.wait -= delta;
        if (self.wait > 0) return false;
        self.wait = every;
        return true;
    }

    /// What the driver said: true when the targets are to be made again
    /// now. Null - a driver that says nothing - never asks for it.
    pub fn saw(self: *MemoryWatch, memory: ?rhi.Memory) bool {
        const now = memory orelse return false;
        if (self.evictions) |before| {
            if (now.evictions > before) self.moved = true;
        }
        self.evictions = now.evictions;
        if (!self.moved or now.available_kib < room_kib or self.since_remade < at_most_every) return false;
        self.moved = false;
        self.since_remade = 0;
        return true;
    }
};

test "the targets are made again once something was moved out of the card and there is room again" {
    var watch: MemoryWatch = .{};
    const full: rhi.Memory = .{ .total_kib = 6 << 20, .available_kib = 40 << 10, .evictions = 3 };
    // The first look only learns the count.
    try testing.expect(!watch.saw(full));
    // Moved out while the card is full: nothing yet.
    var moved = full;
    moved.evictions = 9;
    try testing.expect(!watch.saw(moved));
    // The other program gone: room again, and the targets are made.
    var roomy = moved;
    roomy.available_kib = 2 << 20;
    try testing.expect(watch.saw(roomy));
    // Once: nothing moved since.
    watch.since_remade = MemoryWatch.at_most_every;
    try testing.expect(!watch.saw(roomy));
}

test "they are not made again more often than at_most_every, nor for a driver that says nothing" {
    var watch: MemoryWatch = .{};
    try testing.expect(!watch.saw(null));
    var memory: rhi.Memory = .{ .total_kib = 6 << 20, .available_kib = 2 << 20, .evictions = 0 };
    _ = watch.saw(memory);
    memory.evictions = 1;
    try testing.expect(watch.saw(memory));
    memory.evictions = 2;
    try testing.expect(!watch.saw(memory));
    // Seconds go by, a look each `every`.
    var asked: u32 = 0;
    for (0..60 * 9) |_| {
        if (watch.due(1.0 / 60.0)) asked += 1;
    }
    try testing.expect(asked >= 8 and asked <= 10);
    try testing.expect(watch.saw(memory));
}
