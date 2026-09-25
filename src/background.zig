// SPDX-License-Identifier: BSD-3-Clause
//! A file read while the game goes on, on a thread of its own - or on a
//! page, which has none, a piece a frame. What needs the GPU, the mixer and
//! the world is left for the game's own thread, when the file is taken:
//!
//! - a picture is decoded here, and made a texture when taken;
//! - a sound and a font are read here, and made one when taken;
//! - a scene is read here with the pictures it names decoded and the sounds
//!   it names read, all made when it is taken;
//! - the engine's other files - a tile set, a theme, an animation - are read
//!   here, and understood when taken, which is quick.
//!
//! ```zig
//! try app.loadInBackground("res://levels/two.json");
//! try app.loadInBackground("res://music/night.ogg");
//! // each frame:
//! bar.value = app.loadProgress("res://levels/two.json") * 100;
//! if (bar.value >= 100) app.changeScene(try app.loadScene("res://levels/two.json"));
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const image = @import("fluxion_image");

const json = @import("fluxion_json");

const AssetKind = @import("asset_kind.zig").AssetKind;
const Project = @import("Project.zig");

/// Whether a load has a thread of its own, or is worked a piece a frame.
pub const threaded = !builtin.single_threaded and !builtin.target.cpu.arch.isWasm();

/// One file on its way. Made by `App.loadInBackground`, and let go of when
/// `App.loadAsset` - or a kind's own load - takes it.
pub const Load = struct {
    /// Everything the thread touches is its own or behind these atomics:
    /// memory from an allocator that takes calls from any thread.
    gpa: Allocator,
    io: std.Io,
    kind: AssetKind,
    /// The file as it is found: `res://`, `user://`, or the system's own.
    source: []u8,
    /// Where it is on the disc, worked out before the thread starts.
    file: []u8,
    /// The project's root, for the files a scene names.
    root: []u8,
    state: std.atomic.Value(State) = .init(.reading),
    /// Steps done, and how many there are: one for the file and one for each
    /// picture and sound a scene names, once the file has said how many.
    steps_done: std.atomic.Value(u32) = .init(0),
    steps: std.atomic.Value(u32) = .init(1),
    thread: ?std.Thread = null,
    // The thread's until `done`, the taker's after.
    bytes: []u8 = &.{},
    pictures: std.ArrayListUnmanaged([]u8) = .empty,
    sounds: std.ArrayListUnmanaged([]u8) = .empty,
    decoded: std.ArrayListUnmanaged(Decoded) = .empty,
    heard: std.ArrayListUnmanaged(Read) = .empty,
    next: usize = 0,
    failure: ?anyerror = null,

    pub const State = enum(u8) { reading, working, done };

    /// A picture decoded, waiting for the GPU.
    pub const Decoded = struct {
        source: []u8,
        width: u32,
        height: u32,
        pixels: []u8,
    };

    /// A sound's file read, waiting for the mixer.
    pub const Read = struct {
        source: []u8,
        bytes: []u8,
    };

    /// How far it has got, from nought to one.
    pub fn progress(self: *const Load) f32 {
        const steps = self.steps.load(.acquire);
        const done_steps = self.steps_done.load(.acquire);
        if (steps == 0) return 1;
        return @min(1, @as(f32, @floatFromInt(done_steps)) / @as(f32, @floatFromInt(steps)));
    }

    /// Whether it has got as far as it will: taking it then waits for
    /// nothing.
    pub fn done(self: *const Load) bool {
        return self.state.load(.acquire) == .done;
    }

    /// The thread's whole work, a step after another.
    pub fn run(self: *Load) void {
        while (self.work()) {}
    }

    /// One step, and whether there is another: read the file, then decode
    /// or read one thing a scene names. A mistake ends it, kept for the
    /// taker to say.
    pub fn work(self: *Load) bool {
        switch (self.state.load(.acquire)) {
            .reading => {
                self.readFile() catch |err| return self.fail(err);
                const more = self.pictures.items.len + self.sounds.items.len;
                self.steps.store(@intCast(1 + more), .release);
                self.steps_done.store(1, .release);
                self.state.store(if (more == 0) .done else .working, .release);
                return more > 0;
            },
            .working => {
                const at = self.next;
                self.next += 1;
                // What does not read is left for the scene to say when it
                // is taken, as it would have been read then anyway.
                if (at < self.pictures.items.len) {
                    self.decodeFile(self.pictures.items[at]) catch {};
                } else {
                    self.readSound(self.sounds.items[at - self.pictures.items.len]) catch {};
                }
                self.steps_done.store(@intCast(1 + self.next), .release);
                if (self.next < self.pictures.items.len + self.sounds.items.len) return true;
                self.state.store(.done, .release);
                return false;
            },
            .done => return false,
        }
    }

    fn fail(self: *Load, err: anyerror) bool {
        self.failure = err;
        self.state.store(.done, .release);
        return false;
    }

    fn readFile(self: *Load) !void {
        self.bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, self.file, self.gpa, .limited(@import("file_table.zig").file_limit));
        switch (self.kind) {
            .texture => try self.decode(self.source, self.bytes),
            .scene => try self.findNamed(),
            else => {},
        }
    }

    /// The pictures and sounds a scene names, wherever it names them: what
    /// takes the longest to make of it.
    fn findNamed(self: *Load) !void {
        var reader: json.Reader = .init(self.gpa, self.bytes, .{ .syntax = .json5 });
        defer reader.deinit();
        while (try reader.next()) |token| {
            const text = switch (token) {
                .string, .key => |held| held,
                else => continue,
            };
            if (!std.mem.startsWith(u8, text, Project.scheme)) continue;
            const list = switch (AssetKind.ofPath(text) orelse continue) {
                .texture => &self.pictures,
                .audio => &self.sounds,
                else => continue,
            };
            if (names(list.items, text)) continue;
            const copy = try self.gpa.dupe(u8, text);
            errdefer self.gpa.free(copy);
            try list.append(self.gpa, copy);
        }
    }

    fn names(held: []const []u8, path: []const u8) bool {
        for (held) |one| {
            if (std.mem.eql(u8, one, path)) return true;
        }
        return false;
    }

    fn decodeFile(self: *Load, source: []const u8) !void {
        const file = try Project.underRoot(self.gpa, self.root, source);
        defer self.gpa.free(file);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(@import("file_table.zig").file_limit));
        defer self.gpa.free(bytes);
        try self.decode(source, bytes);
    }

    fn decode(self: *Load, source: []const u8, bytes: []const u8) !void {
        var picture = try image.decode(self.gpa, bytes);
        errdefer picture.deinit(self.gpa);
        const named = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(named);
        try self.decoded.append(self.gpa, .{ .source = named, .width = picture.width, .height = picture.height, .pixels = picture.pixels });
    }

    fn readSound(self: *Load, source: []const u8) !void {
        const file = try Project.underRoot(self.gpa, self.root, source);
        defer self.gpa.free(file);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, file, self.gpa, .limited(@import("file_table.zig").file_limit));
        errdefer self.gpa.free(bytes);
        const named = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(named);
        try self.heard.append(self.gpa, .{ .source = named, .bytes = bytes });
    }

    /// Wait for the thread, if it has not finished.
    pub fn join(self: *Load) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Let go of everything it holds. The thread is waited for first.
    pub fn deinit(self: *Load) void {
        self.join();
        const gpa = self.gpa;
        gpa.free(self.source);
        gpa.free(self.file);
        gpa.free(self.root);
        gpa.free(self.bytes);
        for (self.pictures.items) |held| gpa.free(held);
        self.pictures.deinit(gpa);
        for (self.sounds.items) |held| gpa.free(held);
        self.sounds.deinit(gpa);
        for (self.decoded.items) |held| {
            gpa.free(held.source);
            gpa.free(held.pixels);
        }
        self.decoded.deinit(gpa);
        for (self.heard.items) |held| {
            gpa.free(held.source);
            gpa.free(held.bytes);
        }
        self.heard.deinit(gpa);
    }
};
