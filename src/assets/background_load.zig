// SPDX-License-Identifier: BSD-3-Clause

//! Files read while the game goes on, in steps shared out among a few
//! loading threads of the engine's own - or on a page, which has none, a few
//! steps a frame. What needs the GPU, the mixer and the world is left for
//! the game's own thread, when the file is taken:
//!
//! - a picture is decoded in a step, and made a texture when taken;
//! - a sound and a font are read, and made one when taken;
//! - a scene is read, then the pictures, the sounds and the models it names
//!   are each a step - or a load - of their own, on whichever thread is
//!   free, all made when it is taken;
//! - a model is read, then each of its meshes is made and each of its
//!   pictures decoded in a step of its own; see `assets/models.zig`;
//! - the engine's other files - a tile set, a theme, an animation - are read,
//!   and understood when taken, which is quick.
//!
//! ```zig
//! try app.loadInBackground("res://levels/two.json");
//! // each frame:
//! var words: [256]u8 = undefined;
//! const report = app.loadReport("res://levels/two.json", &words).?;
//! bar.value = report.fraction() * 100;               // and report.current: what is being read
//! if (report.finished) app.changeScene(try app.loadScene("res://levels/two.json"));
//! ```

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const image = @import("fluxion_image");
const json = @import("fluxion_json");

const App = @import("../App.zig");
const AssetKind = @import("asset_kind.zig").AssetKind;
const Project = @import("../project/Project.zig");
const file_table = @import("file_table.zig");
const gltf = @import("gltf.zig");
const models = @import("models.zig");

const log = std.log.scoped(.fluxion_engine);

/// Whether loads have threads to run on, or are worked a few steps a frame.
pub const threaded = !builtin.single_threaded and !builtin.target.cpu.arch.isWasm();

/// The most loading threads there are, whatever the machine has.
pub const most_threads = 6;

/// One step of a load's work.
const Step = struct {
    load: *Load,
    kind: Kind,
    index: u32 = 0,

    const Kind = enum { read, picture, sound, image, mesh };

    fn run(self: Step) void {
        const load = self.load;
        load.latest.store(self.ordinal(), .release);
        switch (self.kind) {
            .read => load.readStep(),
            .picture => load.decodePicture(self.index) catch |err| load.failStep(err),
            .sound => load.readSound(self.index) catch |err| load.failStep(err),
            .image => gltf.decodeImage(&load.prepared.?.model, self.index) catch |err| load.failStep(err),
            .mesh => gltf.buildMesh(&load.prepared.?.model, self.index) catch |err| load.failStep(err),
        }
        load.stepDone();
    }

    /// Where the step is among its load's, for what it is called.
    fn ordinal(self: Step) u32 {
        const load = self.load;
        return switch (self.kind) {
            .read => 0,
            .picture => 1 + self.index,
            .sound => 1 + @as(u32, @intCast(load.pictures.len)) + self.index,
            .image => 1 + self.index,
            .mesh => 1 + @as(u32, @intCast(load.prepared.?.model.images.len)) + self.index,
        };
    }
};

/// The loading threads and the steps they take, first come first taken.
pub const Pool = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    waiting: std.Io.Condition = .init,
    queue: std.ArrayListUnmanaged(Step) = .empty,
    /// The next step to take: steps before it were taken.
    next: usize = 0,
    threads: [most_threads]?std.Thread = @splat(null),
    started: bool = false,
    stopping: bool = false,

    /// Start the threads, if there are to be any and they are not started.
    fn start(self: *Pool) void {
        if (comptime !threaded) return;
        if (self.started) return;
        self.started = true;
        const cores = std.Thread.getCpuCount() catch 2;
        const count = std.math.clamp(cores -| 1, 1, most_threads);
        for (self.threads[0..count]) |*slot| slot.* = std.Thread.spawn(.{}, work, .{self}) catch null;
    }

    fn push(self: *Pool, step: Step) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.queue.append(self.gpa, step);
        self.waiting.signal(self.io);
    }

    /// Take the next step, if there is one, under the lock.
    fn take(self: *Pool) ?Step {
        if (self.next >= self.queue.items.len) return null;
        const step = self.queue.items[self.next];
        self.next += 1;
        // Taken all: the list starts again from nought.
        if (self.next == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.next = 0;
        }
        return step;
    }

    /// One step run on the thread that asks, if one is waiting: what a
    /// thread waiting for a load does, and what a page does each frame.
    pub fn runOne(self: *Pool) bool {
        self.mutex.lockUncancelable(self.io);
        const step = self.take();
        self.mutex.unlock(self.io);
        (step orelse return false).run();
        return true;
    }

    fn work(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.next >= self.queue.items.len) self.waiting.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const step = self.take().?;
            self.mutex.unlock(self.io);
            step.run();
        }
    }

    /// The threads stopped, each after the step it is on; steps not taken
    /// are not run.
    pub fn deinit(self: *Pool) void {
        if (comptime threaded) {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.waiting.broadcast(self.io);
            self.mutex.unlock(self.io);
            for (&self.threads) |*slot| if (slot.*) |thread| {
                thread.join();
                slot.* = null;
            };
        }
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    /// Steps of `load`'s let go of before they run: it is going.
    fn forget(self: *Pool, load: *Load) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var at = self.next;
        while (at < self.queue.items.len) {
            if (self.queue.items[at].load == load) {
                _ = self.queue.orderedRemove(at);
                load.stepDone();
            } else at += 1;
        }
    }
};

/// One file on its way. Made by `start`, and let go of when `App.loadAsset`
/// - or a kind's own load - takes it.
pub const Load = struct {
    /// Everything the steps touch is the load's own or behind these atomics
    /// and its lock: memory from an allocator that takes calls from any
    /// thread.
    gpa: Allocator,
    pool: *Pool,
    kind: AssetKind,
    /// A model, read as glTF: see `assets/models.zig`.
    model: bool,
    /// The file as it is found: `res://`, `user://`, or the system's own.
    source: []u8,
    /// What `files` reads it by, worked out before the steps start: the
    /// system's path, or a `res://` one in a pack.
    file: []u8,
    /// The project's reading, for the file and the ones a scene names. The
    /// project outlives every load.
    files: Project.Files,
    /// Steps not finished yet: none left, it is done.
    pending: std.atomic.Value(u32) = .init(1),
    steps: std.atomic.Value(u32) = .init(1),
    steps_done: std.atomic.Value(u32) = .init(0),
    /// The step started last, by `Step.ordinal`: what it is said to be on.
    latest: std.atomic.Value(u32) = .init(0),
    /// Whether the first step has found what else there is to do: what
    /// names the others are read under, which are not changed after.
    named: std.atomic.Value(bool) = .init(false),
    lock: std.Io.Mutex = .init,
    failure: ?anyerror = null,
    // The steps' until the load is done, the taker's after.
    bytes: []u8 = &.{},
    pictures: [][]u8 = &.{},
    decoded: []?Decoded = &.{},
    sounds: [][]u8 = &.{},
    heard: []?Read = &.{},
    /// The models a scene names, each a load of its own.
    children: []*Load = &.{},
    prepared: ?models.Prepared = null,

    /// A picture decoded, waiting for the GPU.
    pub const Decoded = struct {
        width: u32,
        height: u32,
        pixels: []u8,
    };

    /// A sound's file read, waiting for the mixer.
    pub const Read = struct {
        bytes: []u8,
    };

    /// How far it has got, from nought to one, the models a scene names
    /// counted in.
    pub fn progress(self: *const Load) f32 {
        const counted = self.count();
        if (counted.total == 0) return 1;
        return @min(1, @as(f32, @floatFromInt(counted.done)) / @as(f32, @floatFromInt(counted.total)));
    }

    /// Steps done, and how many there are so far: more come as the files
    /// say what else they name.
    pub fn count(self: *const Load) struct { done: u32, total: u32 } {
        var done_steps = self.steps_done.load(.acquire);
        var total = self.steps.load(.acquire);
        if (self.named.load(.acquire)) for (self.children) |child| {
            const theirs = child.count();
            done_steps += theirs.done;
            total += theirs.total;
        };
        return .{ .done = done_steps, .total = total };
    }

    /// Whether it - and every model it names - has got as far as it will:
    /// taking it then waits for nothing.
    pub fn done(self: *const Load) bool {
        if (self.pending.load(.acquire) != 0) return false;
        for (self.children) |child| if (!child.done()) return false;
        return true;
    }

    /// What it is on, in words, into `buffer`.
    pub fn current(self: *const Load, buffer: []u8) []const u8 {
        if (self.done()) return std.fmt.bufPrint(buffer, "{s}", .{self.source}) catch buffer[0..0];
        // A model a scene names, once the scene's own steps are done.
        if (self.pending.load(.acquire) == 0) for (self.children) |child| {
            if (!child.done()) return child.current(buffer);
        };
        const at = self.latest.load(.acquire);
        if (at == 0 or !self.named.load(.acquire)) return std.fmt.bufPrint(buffer, "Reading {s}", .{self.source}) catch buffer[0..0];
        if (self.prepared) |*held| {
            const model = &held.model;
            if (at <= model.images.len) return std.fmt.bufPrint(buffer, "{s}: decoding {s}", .{ self.source, model.images[at - 1].name }) catch buffer[0..0];
            const m = at - 1 - model.images.len;
            if (m < model.meshes.len) return std.fmt.bufPrint(buffer, "{s}: making {s}", .{ self.source, model.meshes[m].name }) catch buffer[0..0];
        }
        if (at <= self.pictures.len) return std.fmt.bufPrint(buffer, "Decoding {s}", .{self.pictures[at - 1]}) catch buffer[0..0];
        const s = at - 1 - self.pictures.len;
        if (s < self.sounds.len) return std.fmt.bufPrint(buffer, "Reading {s}", .{self.sounds[s]}) catch buffer[0..0];
        return std.fmt.bufPrint(buffer, "{s}", .{self.source}) catch buffer[0..0];
    }

    fn stepDone(self: *Load) void {
        _ = self.steps_done.fetchAdd(1, .acq_rel);
        _ = self.pending.fetchSub(1, .acq_rel);
    }

    fn failStep(self: *Load, err: anyerror) void {
        self.lock.lockUncancelable(self.pool.io);
        defer self.lock.unlock(self.pool.io);
        if (self.failure == null) self.failure = err;
    }

    /// Steps more to wait for, counted before they are queued so the load
    /// is not done between.
    fn expect(self: *Load, more: u32) void {
        _ = self.pending.fetchAdd(more, .acq_rel);
        _ = self.steps.fetchAdd(more, .acq_rel);
    }

    /// The file read, and what else it names found: each a step, or a load,
    /// of its own.
    fn readStep(self: *Load) void {
        self.readFile() catch |err| self.failStep(err);
        self.named.store(true, .release);
    }

    fn readFile(self: *Load) !void {
        if (self.model) {
            // Kept as long as the load: a GLB's pictures and meshes are read
            // from its binary part by the steps after this one.
            self.bytes = try self.files.read(self.gpa, self.file, .limited(file_table.file_limit));
            var beside: models.Beside = .{ .files = self.files, .folder = models.folderOf(self.file) };
            self.prepared = .{ .model = try gltf.parse(self.gpa, self.bytes, beside.fetch()), .settings = models.settingsOf(self.gpa, self.files, self.file) };
            const model = &self.prepared.?.model;
            const more: u32 = @intCast(model.images.len + model.meshes.len);
            self.expect(more);
            for (0..model.images.len) |at| try self.pool.push(.{ .load = self, .kind = .image, .index = @intCast(at) });
            for (0..model.meshes.len) |at| try self.pool.push(.{ .load = self, .kind = .mesh, .index = @intCast(at) });
            return;
        }
        self.bytes = try self.files.read(self.gpa, self.file, .limited(file_table.file_limit));
        switch (self.kind) {
            .texture => {
                var picture = try image.decode(self.gpa, self.bytes);
                errdefer picture.deinit(self.gpa);
                self.decoded = try self.gpa.alloc(?Decoded, 1);
                self.decoded[0] = .{ .width = picture.width, .height = picture.height, .pixels = picture.pixels };
            },
            .scene => try self.findNamed(),
            else => {},
        }
    }

    /// The pictures, sounds and models a scene names, wherever it names
    /// them: what takes the longest to make of it.
    fn findNamed(self: *Load) !void {
        var pictures: std.ArrayListUnmanaged([]u8) = .empty;
        var sounds: std.ArrayListUnmanaged([]u8) = .empty;
        var named_models: std.ArrayListUnmanaged([]u8) = .empty;
        defer named_models.deinit(self.gpa);
        defer for (named_models.items) |held| self.gpa.free(held);
        errdefer {
            for (pictures.items) |held| self.gpa.free(held);
            pictures.deinit(self.gpa);
            for (sounds.items) |held| self.gpa.free(held);
            sounds.deinit(self.gpa);
        }
        var reader: json.Reader = .init(self.gpa, self.bytes, .{ .syntax = .json5 });
        defer reader.deinit();
        while (try reader.next()) |token| {
            const text = switch (token) {
                .string, .key => |held| held,
                else => continue,
            };
            if (!std.mem.startsWith(u8, text, Project.scheme)) continue;
            const path = models.baseOf(text) orelse text;
            const list = if (models.isModel(path)) &named_models else switch (AssetKind.ofPath(path) orelse continue) {
                .texture => &pictures,
                .audio => &sounds,
                else => continue,
            };
            if (names(list.items, path)) continue;
            const copy = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(copy);
            try list.append(self.gpa, copy);
        }
        self.pictures = try pictures.toOwnedSlice(self.gpa);
        self.sounds = try sounds.toOwnedSlice(self.gpa);
        self.decoded = try self.gpa.alloc(?Decoded, self.pictures.len);
        @memset(self.decoded, null);
        self.heard = try self.gpa.alloc(?Read, self.sounds.len);
        @memset(self.heard, null);
        // Each model its own load, under this one.
        var children: std.ArrayListUnmanaged(*Load) = .empty;
        errdefer {
            for (children.items) |child| destroy(child);
            children.deinit(self.gpa);
        }
        for (named_models.items) |path| {
            const made_load = (try self.modelLoad(path)) orelse continue;
            try children.append(self.gpa, made_load);
        }
        self.children = try children.toOwnedSlice(self.gpa);
        const more: u32 = @intCast(self.pictures.len + self.sounds.len);
        self.expect(more);
        for (0..self.pictures.len) |at| try self.pool.push(.{ .load = self, .kind = .picture, .index = @intCast(at) });
        for (0..self.sounds.len) |at| try self.pool.push(.{ .load = self, .kind = .sound, .index = @intCast(at) });
        for (self.children) |child| try self.pool.push(.{ .load = child, .kind = .read });
    }

    /// A load of the model at `source`, under this one: its file as this
    /// one's are read. Null for one whose file there is no saying.
    fn modelLoad(self: *Load, source: []const u8) !?*Load {
        const readable = try models.readablePath(self.gpa, source);
        defer self.gpa.free(readable);
        // A scene names a model by its `res://` path, which `files` reads
        // under the root or out of the pack.
        if (!std.mem.startsWith(u8, readable, Project.scheme)) return null;
        const file = try self.gpa.dupe(u8, readable);
        errdefer self.gpa.free(file);
        const owned = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(owned);
        const load = try self.gpa.create(Load);
        load.* = .{ .gpa = self.gpa, .pool = self.pool, .kind = .scene, .model = true, .source = owned, .file = file, .files = self.files };
        return load;
    }

    fn names(held: []const []u8, path: []const u8) bool {
        for (held) |one| {
            if (std.mem.eql(u8, one, path)) return true;
        }
        return false;
    }

    fn decodePicture(self: *Load, at: u32) !void {
        const bytes = try self.files.read(self.gpa, self.pictures[at], .limited(file_table.file_limit));
        defer self.gpa.free(bytes);
        const picture = try image.decode(self.gpa, bytes);
        self.decoded[at] = .{ .width = picture.width, .height = picture.height, .pixels = picture.pixels };
    }

    fn readSound(self: *Load, at: u32) !void {
        self.heard[at] = .{ .bytes = try self.files.read(self.gpa, self.sounds[at], .limited(file_table.file_limit)) };
    }

    /// Wait for every step, running waiting steps on this thread meanwhile.
    pub fn finish(self: *Load) void {
        while (!self.done()) {
            if (!self.pool.runOne()) {
                if (comptime threaded) std.Thread.yield() catch {};
            }
        }
    }

    /// Let go of everything it holds. Its steps not run are forgotten and
    /// the one running waited for.
    pub fn deinit(self: *Load) void {
        self.pool.forget(self);
        for (self.children) |held| self.pool.forget(held);
        while (!self.done()) {
            if (!self.pool.runOne()) {
                if (comptime threaded) std.Thread.yield() catch {};
            }
        }
        const gpa = self.gpa;
        for (self.children) |held| destroy(held);
        gpa.free(self.children);
        gpa.free(self.source);
        gpa.free(self.file);
        gpa.free(self.bytes);
        for (self.pictures) |held| gpa.free(held);
        gpa.free(self.pictures);
        for (self.decoded) |held| if (held) |picture| gpa.free(picture.pixels);
        gpa.free(self.decoded);
        for (self.sounds) |held| gpa.free(held);
        gpa.free(self.sounds);
        for (self.heard) |held| if (held) |sound| gpa.free(sound.bytes);
        gpa.free(self.heard);
        if (self.prepared) |*held| held.deinit();
    }
};

fn destroy(load: *Load) void {
    const gpa = load.gpa;
    load.deinit();
    gpa.destroy(load);
}

/// Every file reading in the background, and the threads that read them.
pub const Loads = struct {
    list: std.ArrayListUnmanaged(*Load) = .empty,
    pool: ?*Pool = null,

    /// Every load let go of, done or not, and the threads stopped.
    pub fn deinit(self: *Loads, gpa: Allocator) void {
        // Each load's steps forgotten, and those running waited for, while
        // the pool is there to say which; then the threads stopped.
        while (self.list.pop()) |load| destroy(load);
        self.list.deinit(gpa);
        if (self.pool) |pool| {
            pool.deinit();
            poolAllocator(gpa).destroy(pool);
        }
        self.pool = null;
    }

    fn poolOf(self: *Loads, gpa: Allocator, io: std.Io) Allocator.Error!*Pool {
        if (self.pool) |held| return held;
        const allocator = poolAllocator(gpa);
        const pool = try allocator.create(Pool);
        pool.* = .{ .gpa = allocator, .io = io };
        self.pool = pool;
        return pool;
    }

    /// The load of the file at `source`, as `Project.canonical` spells it.
    pub fn of(self: *const Loads, source: []const u8) ?*Load {
        for (self.list.items) |load| if (std.mem.eql(u8, load.source, source)) return load;
        return null;
    }

    /// A few steps on this thread, where there are no loading threads: once
    /// a frame.
    pub fn work(self: *Loads) void {
        if (threaded) return;
        const pool = self.pool orelse return;
        for (0..steps_a_frame) |_| if (!pool.runOne()) return;
    }

    /// How many steps a page works a frame.
    const steps_a_frame = 4;

    /// A load let go of, whether it was taken or not.
    fn drop(self: *Loads, load: *Load) void {
        for (self.list.items, 0..) |held, at| {
            if (held != load) continue;
            _ = self.list.swapRemove(at);
            break;
        }
        destroy(load);
    }

    /// Every load at once: steps done and how many, and what one of them is
    /// on - what a window says while a scene opens and files are brought in.
    pub fn report(self: *const Loads, buffer: []u8) Report {
        var out: Report = .{ .current = buffer[0..0] };
        for (self.list.items) |load| {
            const counted = load.count();
            out.done += counted.done;
            out.total += counted.total;
            if (out.current.len == 0 and !load.done()) out.current = load.current(buffer);
        }
        out.finished = out.done >= out.total;
        return out;
    }
};

/// Memory any thread can ask for, where there are threads; the app's own
/// where there are none.
fn poolAllocator(gpa: Allocator) Allocator {
    return if (threaded) std.heap.smp_allocator else gpa;
}

/// How far loading has got: see `App.loadReport`.
pub const Report = struct {
    done: u32 = 0,
    total: u32 = 0,
    /// What it is on, in words.
    current: []const u8,
    /// Got as far as it will: taking it waits for nothing.
    finished: bool = false,

    pub fn fraction(self: Report) f32 {
        if (self.total == 0) return 1;
        return @min(1, @as(f32, @floatFromInt(self.done)) / @as(f32, @floatFromInt(self.total)));
    }
};

/// Read a file beside the game in the background: see
/// `App.loadInBackground`. `error.NotAnAsset` for a file the engine does
/// not read by its ending.
pub fn start(app: *App, path: []const u8) !void {
    if (app.io == null) return error.NoIo;
    const gpa = poolAllocator(app.gpa);
    const source = try app.project.canonical(gpa, path);
    errdefer gpa.free(source);
    const kind = kindOf(source) orelse return error.NotAnAsset;
    if (isRead(app, kind, source) or app.loads.of(source) != null) {
        gpa.free(source);
        return;
    }
    const model = models.isModel(source);
    const readable = if (model) try models.readablePath(gpa, source) else try gpa.dupe(u8, source);
    defer gpa.free(readable);
    // A `res://` path `files` reads under the root or out of the pack; any
    // other is the system's.
    const file = if (std.mem.startsWith(u8, readable, Project.scheme)) try gpa.dupe(u8, readable) else try app.project.osPath(gpa, readable);
    errdefer gpa.free(file);
    const pool = try app.loads.poolOf(app.gpa, app.io.?);
    pool.start();
    const load = try gpa.create(Load);
    errdefer gpa.destroy(load);
    load.* = .{ .gpa = gpa, .pool = pool, .kind = kind, .model = model, .source = source, .file = file, .files = app.project.files() };
    try app.loads.list.append(app.gpa, load);
    try pool.push(.{ .load = load, .kind = .read });
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

/// How far the file at `path` has got, and what it is on, in words in
/// `buffer`; null while nothing is reading it.
pub fn report(app: *App, path: []const u8, buffer: []u8) ?Report {
    const named = app.project.canonical(app.gpa, path) catch return null;
    defer app.gpa.free(named);
    const load = app.loads.of(named) orelse return null;
    const counted = load.count();
    return .{ .done = counted.done, .total = counted.total, .current = load.current(buffer), .finished = load.done() };
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
/// it is: the models scenes, the pictures textures, the sounds clips, the
/// scene a scene. The engine's other files are read again by their own
/// loads, which is quick. The load is let go of either way. A file that did
/// not read is its error.
fn take(app: *App, load: *Load) !void {
    defer app.loads.drop(load);
    load.finish();
    try made(app, load);
}

fn made(app: *App, load: *Load) !void {
    for (load.children) |child| {
        // A model that does not read is left for the scene to say, as it
        // would have been read then anyway.
        made(app, child) catch {};
    }
    if (load.failure) |err| return err;
    if (load.model) {
        if (app.scenes.find(load.source) == null) _ = try models.take(app, load.source, &load.prepared.?);
        return;
    }
    for (load.decoded, 0..) |held, at| {
        const picture = held orelse continue;
        const source = if (load.kind == .texture) load.source else load.pictures[at];
        if (app.assets.findTexture(source) != null) continue;
        _ = app.assets.adoptTexture(source, picture.width, picture.height, picture.pixels, .{}) catch |err|
            log.warn("the picture {s} did not reach the GPU: {t}", .{ source, err });
    }
    for (load.heard, 0..) |held, at| {
        const sound = held orelse continue;
        const source = load.sounds[at];
        if (app.audio.find(source) != null) continue;
        _ = app.audio.adopt(app, source, sound.bytes) catch |err|
            log.warn("the sound {s} was not taken: {t}", .{ source, err });
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
