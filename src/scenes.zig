// SPDX-License-Identifier: BSD-3-Clause

//! Scenes as files a game holds: read once, found by a `SceneHandle`, and
//! made into entities as often as it likes - `App.instantiate` - or made the
//! scene the game is playing - `App.changeScene`.
//!
//! ```zig
//! const enemy = try app.loadScene("res://enemies/bat.json");
//! const bat = try app.instantiate(enemy, cave);      // its root, under `cave`
//! app.changeScene(try app.loadScene("res://levels/two.json"));
//! ```
//!
//! What is kept is the file's bytes, as they were read: a scene is read into
//! the world anew every time it is made, which is also what makes two of it
//! two different sets of entities.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const id = @import("fluxion_id");

const App = @import("App.zig");
const Project = @import("Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// A scene read: see `Scenes`. What a component names a scene by, and what
/// `App.instantiate` and `App.changeScene` take.
pub const SceneHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub const none: SceneHandle = .{};

    /// A tool shows `App.sceneSource` instead, as for a texture.
    pub const reflect_name = "SceneHandle";

    pub fn isNone(self: SceneHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(a: SceneHandle, b: SceneHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    fn toId(self: SceneHandle) Table.Handle {
        return @bitCast(self);
    }

    fn fromId(handle: Table.Handle) SceneHandle {
        return @bitCast(handle);
    }
};

/// One scene: where it came from, and what the file said.
pub const Scene = struct {
    /// The path or name it was read by: `res://` for a file of the project's.
    source: []u8,
    /// The file's bytes, JSON or CBOR.
    bytes: []u8,
    /// Whether it came from a file, which `reload` reads again.
    on_disc: bool,
};

const Table = id.handle.Table(Scene);

/// The biggest scene file read: past it, a mistake rather than a level.
pub const file_limit = 256 * 1024 * 1024;

/// Every scene read, and the handles they are found by.
pub const Scenes = struct {
    table: Table = .empty,

    pub fn deinit(self: *Scenes, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| free(gpa, entry.value);
        self.table.deinit(gpa);
    }

    fn free(gpa: Allocator, held: *Scene) void {
        gpa.free(held.source);
        gpa.free(held.bytes);
    }

    /// Read the scene at `path`, or find the one read from there already.
    /// Nothing is made of it here: whether it is a scene at all is found out
    /// when it is.
    pub fn load(self: *Scenes, app: *App, path: []const u8) !SceneHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        const io = app.io orelse return error.NoIo;

        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        errdefer app.gpa.free(bytes);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(app.gpa, source, bytes, true);
    }

    /// A scene from memory rather than a file: a test's, a tool's, or one a
    /// game wrote. `name` is what it is found and written by. A name given
    /// before gets the new bytes.
    pub fn add(self: *Scenes, gpa: Allocator, name: []const u8, bytes: []const u8) !SceneHandle {
        const copy = try gpa.dupe(u8, bytes);
        errdefer gpa.free(copy);
        if (self.find(name)) |known| {
            const held = self.table.get(known.toId()).?;
            gpa.free(held.bytes);
            held.bytes = copy;
            return known;
        }
        return self.keep(gpa, name, copy, false);
    }

    /// Kept, bytes and all: `bytes` is the table's from here.
    fn keep(self: *Scenes, gpa: Allocator, source: []const u8, bytes: []u8, on_disc: bool) !SceneHandle {
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        return .fromId(try self.table.add(gpa, .{ .source = name, .bytes = bytes, .on_disc = on_disc }));
    }

    /// Read a scene's file again: what an editor that has saved it asks, so
    /// what is made of it next is what it saved. Says whether there was a
    /// file to read.
    pub fn reload(self: *Scenes, app: *App, handle: SceneHandle) !bool {
        const held = self.table.get(handle.toId()) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        app.gpa.free(held.bytes);
        held.bytes = bytes;
        return true;
    }

    /// Let a scene go. What was made of it stays; its handle names nothing.
    pub fn unload(self: *Scenes, gpa: Allocator, handle: SceneHandle) void {
        const held = self.table.get(handle.toId()) orelse return;
        free(gpa, held);
        _ = self.table.remove(handle.toId());
    }

    /// The handle of a scene read already, by the path or name it was read by.
    pub fn find(self: *Scenes, source: []const u8) ?SceneHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return .fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *Scenes, handle: SceneHandle) ?*const Scene {
        return self.table.get(handle.toId());
    }

    pub fn sourceOf(self: *Scenes, handle: SceneHandle) ?[]const u8 {
        const held = self.table.get(handle.toId()) orelse return null;
        return held.source;
    }

    /// The file or folder at `old` is now at `new`: a scene read from under
    /// it is found at its new place.
    pub fn renamed(self: *Scenes, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};

test "a scene added is found by its name, given new bytes by the same name, and let go of" {
    var scenes: Scenes = .{};
    defer scenes.deinit(testing.allocator);
    const first = try scenes.add(testing.allocator, "level", "{ }");
    try testing.expect(scenes.find("level").?.eql(first));
    try testing.expect((try scenes.add(testing.allocator, "level", "{ \"a\": 1 }")).eql(first));
    try testing.expectEqualStrings("{ \"a\": 1 }", scenes.get(first).?.bytes);
    try testing.expectEqualStrings("level", scenes.sourceOf(first).?);
    scenes.unload(testing.allocator, first);
    try testing.expect(scenes.get(first) == null);
    try testing.expect(scenes.find("level") == null);
}
