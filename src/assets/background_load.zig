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

const image = @import("fluxion_image");

const json = @import("fluxion_json");

const App = @import("../App.zig");
const AssetKind = @import("asset_kind.zig").AssetKind;
const Project = @import("../project/Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// Whether a load has a thread of its own, or is worked a piece a frame.
pub const threaded = !builtin.single_threaded and !builtin.target.cpu.arch.isWasm();

/// One file on its way. Made by `start`, and let go of when `App.loadAsset`
/// - or a kind's own load - takes it.
pub const Load = struct {
    /// Everything the thread touches is its own or behind these atomics:
    /// memory from an allocator that takes calls from any thread.
    gpa: Allocator,
    kind: AssetKind,
    /// The file as it is found: `res://`, `user://`, or the system's own.
    source: []u8,
    /// What `files` reads it by, worked out before the thread starts: the
    /// system's path, or a `res://` one in a pack.
    file: []u8,
    /// The project's reading, for the file and the ones a scene names. The
    /// project outlives every load.
    files: Project.Files,
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
        self.bytes = try self.files.read(self.gpa, self.file, .limited(@import("file_table.zig").file_limit));
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
        const bytes = try self.files.read(self.gpa, source, .limited(@import("file_table.zig").file_limit));
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
        const bytes = try self.files.read(self.gpa, source, .limited(@import("file_table.zig").file_limit));
        errdefer self.gpa.free(bytes);
        const named = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(named);
        try self.heard.append(self.gpa, .{ .source = named, .bytes = bytes });
    }

    /// Wait for the thread, if it has not finished.
    pub fn join(self: *Load) void {
        // Not even a thread's type where there are none (a browser's).
        if (comptime !threaded) return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Let go of everything it holds. The thread is waited for first.
    pub fn deinit(self: *Load) void {
        self.join();
        const gpa = self.gpa;
        gpa.free(self.source);
        gpa.free(self.file);
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

/// Every file reading in the background, each made with memory any thread
/// can ask for.
pub const Loads = struct {
    list: std.ArrayListUnmanaged(*Load) = .empty,

    /// Every load let go of, done or not.
    pub fn deinit(self: *Loads, gpa: Allocator) void {
        while (self.list.pop()) |load| destroy(load);
        self.list.deinit(gpa);
    }

    /// The load of the file at `source`, as `Project.canonical` spells it.
    pub fn of(self: *const Loads, source: []const u8) ?*Load {
        for (self.list.items) |load| if (std.mem.eql(u8, load.source, source)) return load;
        return null;
    }

    /// A piece of each load's work, where a load has no thread of its own:
    /// once a frame.
    pub fn work(self: *Loads) void {
        if (threaded) return;
        for (self.list.items) |load| _ = load.work();
    }

    /// A load let go of, whether it was taken or not.
    fn drop(self: *Loads, load: *Load) void {
        for (self.list.items, 0..) |held, at| {
            if (held != load) continue;
            _ = self.list.swapRemove(at);
            break;
        }
        destroy(load);
    }

    fn destroy(load: *Load) void {
        load.deinit();
        load.gpa.destroy(load);
    }
};

/// Read a file beside the game on a thread of its own: see
/// `App.loadInBackground`. `error.NotAnAsset` for a file the engine does
/// not read by its ending.
pub fn start(app: *App, path: []const u8) !void {
    if (app.io == null) return error.NoIo;
    // Memory any thread can ask for, since the load's thread does - the
    // app's own where there is no other thread.
    const gpa = if (threaded) std.heap.smp_allocator else app.gpa;
    const source = try app.project.canonical(gpa, path);
    errdefer gpa.free(source);
    const kind = kindOf(source) orelse return error.NotAnAsset;
    if (isRead(app, kind, source) or app.loads.of(source) != null) {
        gpa.free(source);
        return;
    }
    // A pack's file is read out of the pack, by its own name.
    const file = if (app.project.pack != null and Project.isProjectPath(source))
        try gpa.dupe(u8, source)
    else
        try app.project.osPath(gpa, source);
    errdefer gpa.free(file);
    const load = try gpa.create(Load);
    errdefer gpa.destroy(load);
    load.* = .{ .gpa = gpa, .kind = kind, .source = source, .file = file, .files = app.project.files() };
    try app.loads.list.append(app.gpa, load);
    if (threaded) {
        load.thread = std.Thread.spawn(.{}, Load.run, .{load}) catch null;
        // No thread to be had: a piece a frame, as on a page.
        if (load.thread == null) load.run();
    }
}

/// How far the file at `path` has got, from nought to one: one once it is
/// read, in the background or not, and nought while nothing is reading it.
pub fn progress(app: *App, path: []const u8) f32 {
    const named = app.project.canonical(app.gpa, path) catch return 0;
    defer app.gpa.free(named);
    if (kindOf(named)) |kind| if (isRead(app, kind, named)) return 1;
    const load = app.loads.of(named) orelse return 0;
    // One only once it can be taken without a wait.
    return if (load.done()) 1 else @min(load.progress(), 0.99);
}

/// Where a file is in `start`: `done` once it is read - in the background or
/// not - `failed` for a load that did not read, which says why when it is
/// taken, and `none` when nothing is reading it.
pub const LoadStatus = enum { none, loading, done, failed };

pub fn status(app: *App, path: []const u8) LoadStatus {
    const named = app.project.canonical(app.gpa, path) catch return .none;
    defer app.gpa.free(named);
    if (kindOf(named)) |kind| if (isRead(app, kind, named)) return .done;
    const load = app.loads.of(named) orelse return .none;
    if (!load.done()) return .loading;
    return if (load.failure != null) .failed else .done;
}

/// Wait for the background load of `path`, if there is one, and make what
/// it read what it is: the next load of the file finds it. What went wrong
/// is its error. Nothing when nothing is reading it.
pub fn finish(app: *App, path: []const u8) !void {
    if (app.loads.list.items.len == 0) return;
    const named = try app.project.canonical(app.gpa, path);
    defer app.gpa.free(named);
    if (app.loads.of(named)) |load| try take(app, load);
}

/// What a file is to `start`: what its ending says, and a scene for a
/// `.json`, which is the one a game loads.
fn kindOf(path: []const u8) ?AssetKind {
    if (AssetKind.ofPath(path)) |kind| return kind;
    return if (std.ascii.endsWithIgnoreCase(path, ".json")) .scene else null;
}

/// Whether the file at `path`, of `kind`, is read into its table.
fn isRead(app: *App, kind: AssetKind, path: []const u8) bool {
    return switch (kind) {
        inline else => |k| app.findAsset(k.Handle(), path) != null,
    };
}

/// What a load read, once it is done - waited for, if it is not - made what
/// it is: the pictures textures, the sounds clips, the scene a scene. The
/// engine's other files are read again by their own loads, which is quick.
/// The load is let go of either way. A file that did not read is its error.
fn take(app: *App, load: *Load) !void {
    defer app.loads.drop(load);
    load.join();
    while (load.work()) {}
    if (load.failure) |err| return err;
    for (load.decoded.items) |picture| {
        if (app.assets.findTexture(picture.source) != null) continue;
        _ = app.assets.adoptTexture(picture.source, picture.width, picture.height, picture.pixels, .{}) catch |err|
            log.warn("the picture {s} did not reach the GPU: {t}", .{ picture.source, err });
    }
    for (load.heard.items) |sound| {
        if (app.audio.find(sound.source) != null) continue;
        _ = app.audio.adopt(app, sound.source, sound.bytes) catch |err|
            log.warn("the sound {s} was not taken: {t}", .{ sound.source, err });
    }
    switch (load.kind) {
        .scene => if (app.scenes.find(load.source) == null) {
            _ = try app.scenes.add(app.gpa, load.source, load.bytes);
        },
        .audio => if (app.audio.find(load.source) == null) {
            _ = try app.audio.adopt(app, load.source, load.bytes);
        },
        .font => if (app.assets.findFont(load.source) == null) {
            _ = try app.assets.adoptFont(load.source, load.bytes, .{});
        },
        else => {},
    }
}
