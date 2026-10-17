// SPDX-License-Identifier: BSD-3-Clause

//! Pictures read again for their chains of levels, off the game's thread.
//!
//! A picture is made with one level, as a sprite wants it. The first time a
//! 3D surface draws it, it is asked for its smaller levels (`Assets.wantMips`)
//! - and the texture, which was made without room for them, has to be made
//! again from its file. Reading and decoding that file is the slow part: a
//! few milliseconds a picture, and a turn of the camera can bring dozens into
//! view at once. Done in the frame, that is a stutter of a tenth of a second
//! or more.
//!
//! So a thread of its own reads and decodes, one picture after another, and
//! the game's thread takes what is ready - a few a frame - and gives each to
//! the device. A picture keeps its one level a few frames longer, and no
//! frame waits for a file.
//!
//! With no thread to give it - a page in a browser - one picture a frame is
//! made on the game's own.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const image = @import("fluxion_image");

const Project = @import("../project/Project.zig");
const background_load = @import("background_load.zig");
const helpers = @import("../test_helpers.zig");

/// Whether there is a thread to read on.
pub const threaded = background_load.threaded;

pub fn MipMaker(comptime Handle: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        io: std.Io,
        files: Project.Files,
        /// The largest file read.
        limit: usize,
        mutex: std.Io.Mutex = .init,
        waiting: std.Io.Condition = .init,
        /// Asked for and not yet read, the first asked first.
        asked: std.ArrayListUnmanaged(Job) = .empty,
        next: usize = 0,
        /// Read and decoded, waiting for the game's thread.
        made: std.ArrayListUnmanaged(Made) = .empty,
        thread: ?std.Thread = null,
        stopping: bool = false,

        const Job = struct { handle: Handle, source: []u8 };

        /// A picture read again: its handle, and its pixels - null where its
        /// file could not be read or is no picture any more.
        pub const Made = struct {
            handle: Handle,
            picture: ?image.Decoded,

            pub fn deinit(self: *Made, gpa: Allocator) void {
                if (self.picture) |*held| held.deinit(gpa);
                self.picture = null;
            }
        };

        pub fn init(gpa: Allocator, io: std.Io, files: Project.Files, limit: usize) Self {
            return .{ .gpa = gpa, .io = io, .files = files, .limit = limit };
        }

        /// The thread stopped after the picture it is on, and what was asked
        /// or made and not taken let go of.
        pub fn deinit(self: *Self) void {
            if (self.thread) |thread| {
                self.mutex.lockUncancelable(self.io);
                self.stopping = true;
                self.waiting.broadcast(self.io);
                self.mutex.unlock(self.io);
                thread.join();
            }
            for (self.asked.items[self.next..]) |job| self.gpa.free(job.source);
            self.asked.deinit(self.gpa);
            for (self.made.items) |*made| made.deinit(self.gpa);
            self.made.deinit(self.gpa);
            self.* = undefined;
        }

        /// The picture `handle` names, in the file at `source`, to be read
        /// again. The thread starts with the first asked.
        pub fn ask(self: *Self, handle: Handle, source: []const u8) Allocator.Error!void {
            const copy = try self.gpa.dupe(u8, source);
            errdefer self.gpa.free(copy);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.asked.append(self.gpa, .{ .handle = handle, .source = copy });
            if (comptime threaded) {
                if (self.thread == null) self.thread = std.Thread.spawn(.{}, work, .{self}) catch null;
                self.waiting.signal(self.io);
            }
        }

        /// One picture that is ready, the caller's; null when none is. With
        /// no thread, the next asked is read here and now.
        pub fn take(self: *Self) ?Made {
            if (self.thread == null) {
                const job = self.takeJob() orelse return null;
                return self.read(job);
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.made.items.len == 0) return null;
            const made = self.made.orderedRemove(0);
            self.waiting.signal(self.io);
            return made;
        }

        /// How many are asked or made and not yet taken.
        pub fn pending(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.asked.items.len - self.next + self.made.items.len;
        }

        fn takeJob(self: *Self) ?Job {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.takeLocked();
        }

        fn takeLocked(self: *Self) ?Job {
            if (self.next >= self.asked.items.len) return null;
            const job = self.asked.items[self.next];
            self.next += 1;
            if (self.next == self.asked.items.len) {
                self.asked.clearRetainingCapacity();
                self.next = 0;
            }
            return job;
        }

        fn read(self: *Self, job: Job) Made {
            defer self.gpa.free(job.source);
            const bytes = self.files.read(self.gpa, job.source, .limited(self.limit)) catch return .{ .handle = job.handle, .picture = null };
            defer self.gpa.free(bytes);
            const picture = image.decode(self.gpa, bytes) catch return .{ .handle = job.handle, .picture = null };
            return .{ .handle = job.handle, .picture = picture };
        }

        fn work(self: *Self) void {
            while (true) {
                self.mutex.lockUncancelable(self.io);
                // Keep one decoded picture ready. The frame thread can take
                // many frames to upload a large one; never decode the whole
                // queue into RAM while it does so.
                while (!self.stopping and (self.next >= self.asked.items.len or self.made.items.len > 0)) self.waiting.waitUncancelable(self.io, &self.mutex);
                if (self.stopping) {
                    self.mutex.unlock(self.io);
                    return;
                }
                const job = self.takeLocked().?;
                self.mutex.unlock(self.io);
                var made = self.read(job);
                self.mutex.lockUncancelable(self.io);
                self.made.append(self.gpa, made) catch made.deinit(self.gpa);
                self.mutex.unlock(self.io);
            }
        }
    };
}

test "a picture asked for is read off the thread and taken when ready; a file that is none comes back empty" {
    const io = testing.io;
    var files: helpers.Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/one.png");
    {
        var buffer: [192]u8 = undefined;
        const none = try std.fmt.bufPrint(&buffer, "{s}/art/none.png", .{try files.at()});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = none, .data = "not a picture" });
    }

    var maker: MipMaker(u32) = .init(testing.allocator, io, .{ .io = io, .root = try files.at(), .pack = null }, 1 << 20);
    defer maker.deinit();
    try maker.ask(7, "res://art/one.png");
    try maker.ask(8, "res://art/none.png");
    try maker.ask(9, "res://art/missing.png");
    var got: [3]?bool = .{ null, null, null };
    var tries: usize = 0;
    while (tries < 20000 and (got[0] == null or got[1] == null or got[2] == null)) : (tries += 1) {
        var made = maker.take() orelse {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        defer made.deinit(testing.allocator);
        got[made.handle - 7] = made.picture != null;
        if (made.picture) |picture| {
            try testing.expectEqual(@as(u32, 1), picture.width);
            try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, picture.pixels);
        }
    }
    try testing.expectEqual([3]?bool{ true, false, false }, got);
    try testing.expectEqual(@as(usize, 0), maker.pending());
}

test "decoded mip pictures wait for the consumer instead of filling memory" {
    if (!threaded) return error.SkipZigTest;
    const io = testing.io;
    var files: helpers.Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/one.png");
    var maker: MipMaker(u32) = .init(testing.allocator, io, .{ .io = io, .root = try files.at(), .pack = null }, 1 << 20);
    defer maker.deinit();
    for (0..8) |i| try maker.ask(@intCast(i), "res://art/one.png");
    var ready = false;
    for (0..2000) |_| {
        maker.mutex.lockUncancelable(io);
        ready = maker.made.items.len == 1;
        maker.mutex.unlock(io);
        if (ready) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(ready);
    try io.sleep(.fromMilliseconds(20), .awake);
    maker.mutex.lockUncancelable(io);
    const count = maker.made.items.len;
    const remaining = maker.asked.items.len - maker.next;
    maker.mutex.unlock(io);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(usize, 7), remaining);
    // deinit wakes and joins a producer blocked behind the ready picture.
}
