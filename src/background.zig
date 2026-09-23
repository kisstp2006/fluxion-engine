// SPDX-License-Identifier: BSD-3-Clause

//! A scene read while the game goes on: its file, and the pictures it
//! names decoded, on a thread of its own - or on a page, which has none, a
//! piece a frame. What needs the GPU and the world is left for the game's own
//! thread, when it takes the scene.
//!
//! ```zig
//! const next = try app.loadInBackground("res://levels/two.json");
//! // each frame:
//! bar.value = next.progress() * 100;
//! if (next.done()) app.changeScene(try app.takeScene(next));
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const image = @import("fluxion_image");

const json = @import("fluxion_json");

const Project = @import("Project.zig");

/// Whether a load has a thread of its own, or is worked a piece a frame.
pub const threaded = !builtin.single_threaded and !builtin.target.cpu.arch.isWasm();

/// One scene on its way. Made by `App.loadInBackground`, and let go of by
/// `App.takeScene`.
pub const SceneLoad = struct {
    /// Everything the thread touches is its own or behind these atomics:
    /// memory from an allocator that takes calls from any thread.
    gpa: Allocator,
    io: std.Io,
    /// The scene as it is found: `res://`.
    source: []u8,
    /// The project's root, for the files the scene names.
    root: []u8,
    state: std.atomic.Value(State) = .init(.reading),
    /// Steps done, and how many there are: one for the scene's file and one
    /// for each picture it names, once the file has said how many.
    steps_done: std.atomic.Value(u32) = .init(0),
    steps: std.atomic.Value(u32) = .init(1),
    thread: ?std.Thread = null,

    // The thread's until `done`, the taker's after.
    bytes: []u8 = &.{},
    pictures: std.ArrayListUnmanaged([]u8) = .empty,
    decoded: std.ArrayListUnmanaged(Decoded) = .empty,
    next_picture: usize = 0,
    failure: ?anyerror = null,

    pub const State = enum(u8) { reading, decoding, done };

    /// A picture decoded, waiting for the GPU.
    pub const Decoded = struct {
        source: []u8,
        width: u32,
        height: u32,
        pixels: []u8,
    };

    /// How far it has got, from nought to one.
    pub fn progress(self: *const SceneLoad) f32 {
        const steps = self.steps.load(.acquire);
        const done_steps = self.steps_done.load(.acquire);
        if (steps == 0) return 1;
        return @min(1, @as(f32, @floatFromInt(done_steps)) / @as(f32, @floatFromInt(steps)));
    }

    /// Whether it has got as far as it will: `App.takeScene` then waits for
    /// nothing.
    pub fn done(self: *const SceneLoad) bool {
        return self.state.load(.acquire) == .done;
    }

    /// The thread's whole work, a step after another.
    pub fn run(self: *SceneLoad) void {
        while (self.work()) {}
    }

    /// One step, and whether there is another: read the file, then decode
    /// one picture. A mistake ends it, kept for `App.takeScene` to say.
    pub fn work(self: *SceneLoad) bool {
        switch (self.state.load(.acquire)) {
            .reading => {
                self.readFile() catch |err| return self.fail(err);
                self.steps.store(@intCast(1 + self.pictures.items.len), .release);
                self.steps_done.store(1, .release);
                self.state.store(if (self.pictures.items.len == 0) .done else .decoding, .release);
                return self.pictures.items.len > 0;
            },
            .decoding => {
                const at = self.next_picture;
                self.next_picture += 1;
                // A picture that does not read is left for the scene to say
                // when it is taken, as it would have been read then anyway.
                self.decode(self.pictures.items[at]) catch {};
                self.steps_done.store(@intCast(1 + self.next_picture), .release);
                if (self.next_picture < self.pictures.items.len) return true;
                self.state.store(.done, .release);
                return false;
            },
            .done => return false,
        }
    }

    fn fail(self: *SceneLoad, err: anyerror) bool {
        self.failure = err;
        self.state.store(.done, .release);
        return false;
    }

    fn readFile(self: *SceneLoad) !void {
        const file = try Project.underRoot(self.gpa, self.root, self.source);
        defer self.gpa.free(file);
        self.bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(@import("scenes.zig").file_limit));
        // The pictures it names, wherever it names them: what takes the
        // longest to make of a file.
        var reader: json.Reader = .init(self.gpa, self.bytes, .{ .syntax = .json5 });
        defer reader.deinit();
        while (try reader.next()) |token| {
            const text = switch (token) {
                .string, .key => |held| held,
                else => continue,
            };
            if (!std.mem.startsWith(u8, text, Project.scheme) or !std.ascii.endsWithIgnoreCase(text, ".png")) continue;
            if (self.names(text)) continue;
            const copy = try self.gpa.dupe(u8, text);
            errdefer self.gpa.free(copy);
            try self.pictures.append(self.gpa, copy);
        }
    }

    /// Whether a picture is on the list already.
    fn names(self: *const SceneLoad, path: []const u8) bool {
        for (self.pictures.items) |held| {
            if (std.mem.eql(u8, held, path)) return true;
        }
        return false;
    }

    fn decode(self: *SceneLoad, source: []const u8) !void {
        const file = try Project.underRoot(self.gpa, self.root, source);
        defer self.gpa.free(file);
        var picture = try image.png.readFile(self.gpa, self.io, file, .{});
        errdefer picture.deinit(self.gpa);
        const named = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(named);
        try self.decoded.append(self.gpa, .{ .source = named, .width = picture.width, .height = picture.height, .pixels = picture.pixels });
    }

    /// Wait for the thread, if it has not finished.
    pub fn join(self: *SceneLoad) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Let go of everything it holds. The thread is waited for first.
    pub fn deinit(self: *SceneLoad) void {
        self.join();
        const gpa = self.gpa;
        gpa.free(self.source);
        gpa.free(self.root);
        gpa.free(self.bytes);
        for (self.pictures.items) |held| gpa.free(held);
        self.pictures.deinit(gpa);
        for (self.decoded.items) |held| {
            gpa.free(held.source);
            gpa.free(held.pixels);
        }
        self.decoded.deinit(gpa);
    }
};
