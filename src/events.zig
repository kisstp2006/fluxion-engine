// SPDX-License-Identifier: BSD-3-Clause

//! Typed events: what one system tells any others that care, by type rather
//! than by who.
//!
//! ```zig
//! const Damage = struct { to: fx.Entity, amount: f32 };
//! try app.send(Damage{ .to = player, .amount = 5 });
//!
//! // Anywhere after - this frame or the next - by a reader that keeps its place:
//! const Hurt = struct { var damage: fx.EventReader(Damage) = .{} };
//! var it = Hurt.damage.read(app.events(Damage));
//! while (it.next()) |d| hurt(d.to, d.amount);
//! ```
//!
//! **Sending only appends**, so it is safe anywhere, a query's loop included.
//!
//! **An event lives two frames**, the one it was sent in and the next, so a
//! reader that runs before the sender still sees it - once, the frame after.
//!
//! **A reader is a place in the stream**, not a queue of its own: two
//! readers see the same events, and each sees each event once. One that
//! does not read for two frames misses what went by, as Bevy's does.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// The events of one type: last frame's and this frame's.
pub fn Events(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Sent last frame.
        older: std.ArrayList(T) = .empty,
        /// Sent this frame, and between the last one and this.
        newer: std.ArrayList(T) = .empty,
        /// How many went before `older`'s first, counted from the first ever
        /// sent: where a reader's place is measured from.
        start: u64 = 0,

        /// None, for a type nothing has sent.
        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.older.deinit(gpa);
            self.newer.deinit(gpa);
        }

        pub fn send(self: *Self, gpa: Allocator, event: T) Allocator.Error!void {
            try self.newer.append(gpa, event);
        }

        /// How many are held, last frame's and this frame's.
        pub fn len(self: *const Self) usize {
            return self.older.items.len + self.newer.items.len;
        }

        /// The frame turns: last frame's go, and this frame's are last
        /// frame's. Called by `App` at the top of every frame.
        pub fn update(self: *Self) void {
            self.start += self.older.items.len;
            self.older.clearRetainingCapacity();
            std.mem.swap(std.ArrayList(T), &self.older, &self.newer);
        }

        /// Every one gone, and every reader's place past them.
        pub fn clear(self: *Self) void {
            self.start += self.len();
            self.older.clearRetainingCapacity();
            self.newer.clearRetainingCapacity();
        }
    };
}

/// A place in the events of one type: what it has read, so it reads each
/// once.
pub fn Reader(comptime T: type) type {
    return struct {
        const Self = @This();

        /// How many of the events ever sent it has read.
        seen: u64 = 0,

        /// What it has not read yet, and its place moved past them. What
        /// is sent while it iterates is the next read's.
        pub fn read(self: *Self, events: *const Events(T)) Iterator(T) {
            const end = events.start + events.len();
            // What went before both frames is gone, read or not.
            const from = @max(self.seen, events.start);
            self.seen = end;
            return .{ .events = events, .at = @intCast(from - events.start), .end = @intCast(end - events.start) };
        }

        /// Its place moved past everything there is, unread.
        pub fn skip(self: *Self, events: *const Events(T)) void {
            self.seen = events.start + events.len();
        }
    };
}

/// The events one read has for its reader, oldest first.
pub fn Iterator(comptime T: type) type {
    return struct {
        events: *const Events(T),
        at: usize,
        end: usize,

        /// The next, by value: a send while iterating may move where they
        /// are kept.
        pub fn next(self: *@This()) ?T {
            if (self.at >= self.end) return null;
            defer self.at += 1;
            const older = self.events.older.items.len;
            return if (self.at < older) self.events.older.items[self.at] else self.events.newer.items[self.at - older];
        }

        pub fn remaining(self: *const @This()) usize {
            return self.end - self.at;
        }
    };
}

test "a reader sees each event once, over the two frames it lives" {
    const gpa = testing.allocator;
    var events: Events(u32) = .{};
    defer events.deinit(gpa);
    var early: Reader(u32) = .{};
    var late: Reader(u32) = .{};

    // The late reader runs after the sender, the early one before it.
    var it = early.read(&events);
    try testing.expect(it.next() == null);
    try events.send(gpa, 1);
    try events.send(gpa, 2);
    it = late.read(&events);
    try testing.expectEqual(@as(?u32, 1), it.next());
    try testing.expectEqual(@as(?u32, 2), it.next());
    try testing.expect(it.next() == null);

    // The next frame: the early reader sees them now, the late one not again.
    events.update();
    it = early.read(&events);
    try testing.expectEqual(@as(usize, 2), it.remaining());
    try testing.expectEqual(@as(?u32, 1), it.next());
    it = late.read(&events);
    try testing.expect(it.next() == null);

    // Two frames on they are gone, and a reader that slept missed them.
    var sleeper: Reader(u32) = .{};
    try events.send(gpa, 3);
    events.update();
    events.update();
    it = sleeper.read(&events);
    try testing.expect(it.next() == null);
}

test "a clear drops every event, and what is sent after is read" {
    const gpa = testing.allocator;
    var events: Events(u32) = .{};
    defer events.deinit(gpa);
    var reader: Reader(u32) = .{};
    try events.send(gpa, 1);
    events.update();
    try events.send(gpa, 2);
    var it = reader.read(&events);
    try testing.expectEqual(@as(usize, 2), it.remaining());
    events.clear();
    try testing.expectEqual(@as(usize, 0), events.len());
    // Sent before the reader looks again, and still what it reads.
    try events.send(gpa, 3);
    it = reader.read(&events);
    try testing.expectEqual(@as(?u32, 3), it.next());
    try testing.expect(it.next() == null);
}

test "what is sent while a reader iterates is its next read's" {
    const gpa = testing.allocator;
    var events: Events(u32) = .{};
    defer events.deinit(gpa);
    var reader: Reader(u32) = .{};
    try events.send(gpa, 7);
    var it = reader.read(&events);
    while (it.next()) |n| try events.send(gpa, n + 1);
    it = reader.read(&events);
    try testing.expectEqual(@as(?u32, 8), it.next());
    try testing.expect(it.next() == null);
}
