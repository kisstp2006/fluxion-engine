// SPDX-License-Identifier: BSD-3-Clause

//! Files a game keeps as the bytes they were read as, each found by a handle
//! of its kind's own: scenes, which are read into the world anew each time
//! one is made, and data files, whose struct is made anew each time one is
//! read. What a file says is found out when something is made of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const id = @import("fluxion_id");

const App = @import("App.zig");
const Project = @import("Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// The handle one kind of file is found by: `name` is what reflection calls
/// it, which keeps two kinds apart.
pub fn Handle(comptime name: [:0]const u8) type {
    return extern struct {
        index: u32 = 0,
        generation: u32 = 0,

        const Self = @This();

        pub const none: Self = .{};

        /// A tool shows the file's source instead, as for a texture.
        pub const reflect_name = name;

        pub fn isNone(self: Self) bool {
            return self.generation == 0;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }
    };
}

/// One file: where it came from, and what it said.
pub const File = struct {
    /// The path or name it was read by: `res://` for a file of the project's.
    source: []u8,
    /// The file's bytes.
    bytes: []u8,
    /// Whether it came from a file, which `reload` reads again.
    on_disc: bool,
};

/// The biggest file read: past it, a mistake rather than a level.
pub const file_limit = 256 * 1024 * 1024;

/// Every file of one kind read, and the handles `H` they are found by.
pub fn Table(comptime H: type) type {
    return struct {
        table: Inner = .empty,

        const Self = @This();
        const Inner = id.handle.Table(File);

        fn toId(handle: H) Inner.Handle {
            return @bitCast(handle);
        }

        fn fromId(handle: Inner.Handle) H {
            return @bitCast(handle);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            var it = self.table.iterator();
            while (it.next()) |entry| free(gpa, entry.value);
            self.table.deinit(gpa);
        }

        fn free(gpa: Allocator, held: *File) void {
            gpa.free(held.source);
            gpa.free(held.bytes);
        }

        /// Read the file at `path`, or find the one read from there already.
        pub fn load(self: *Self, app: *App, path: []const u8) !H {
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

        /// A file from memory rather than from disc: a test's, a tool's, or
        /// one a game wrote. `name` is what it is found and written by. A name
        /// given before gets the new bytes.
        pub fn add(self: *Self, gpa: Allocator, name: []const u8, bytes: []const u8) !H {
            const copy = try gpa.dupe(u8, bytes);
            errdefer gpa.free(copy);
            if (self.find(name)) |known| {
                const held = self.table.get(toId(known)).?;
                gpa.free(held.bytes);
                held.bytes = copy;
                return known;
            }
            return self.keep(gpa, name, copy, false);
        }

        /// Kept, bytes and all: `bytes` is the table's from here.
        fn keep(self: *Self, gpa: Allocator, source: []const u8, bytes: []u8, on_disc: bool) !H {
            const name = try gpa.dupe(u8, source);
            errdefer gpa.free(name);
            return fromId(try self.table.add(gpa, .{ .source = name, .bytes = bytes, .on_disc = on_disc }));
        }

        /// Read a file again: what an editor that has saved it asks, so what
        /// is made of it next is what it saved. Says whether there was a file
        /// to read.
        pub fn reload(self: *Self, app: *App, handle: H) !bool {
            const held = self.table.get(toId(handle)) orelse return false;
            if (!held.on_disc) return false;
            const io = app.io orelse return error.NoIo;
            const file = try app.project.osPath(app.gpa, held.source);
            defer app.gpa.free(file);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
            app.gpa.free(held.bytes);
            held.bytes = bytes;
            return true;
        }

        /// Let a file go. What was made of it stays; its handle names nothing.
        pub fn unload(self: *Self, gpa: Allocator, handle: H) void {
            const held = self.table.get(toId(handle)) orelse return;
            free(gpa, held);
            _ = self.table.remove(toId(handle));
        }

        /// The handle of a file read already, by the path or name it was read by.
        pub fn find(self: *Self, source: []const u8) ?H {
            var it = self.table.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
            }
            return null;
        }

        pub fn get(self: *Self, handle: H) ?*const File {
            return self.table.get(toId(handle));
        }

        pub fn sourceOf(self: *Self, handle: H) ?[]const u8 {
            const held = self.table.get(toId(handle)) orelse return null;
            return held.source;
        }

        /// The file or folder at `old` is now at `new`: a file read from under
        /// it is found at its new place.
        pub fn renamed(self: *Self, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
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
}

test "a file added is found by its name, given new bytes by the same name, and let go of" {
    const Note = Handle("Note");
    var notes: Table(Note) = .{};
    defer notes.deinit(testing.allocator);
    const first = try notes.add(testing.allocator, "level", "{ }");
    try testing.expect(notes.find("level").?.eql(first));
    try testing.expect((try notes.add(testing.allocator, "level", "{ \"a\": 1 }")).eql(first));
    try testing.expectEqualStrings("{ \"a\": 1 }", notes.get(first).?.bytes);
    try testing.expectEqualStrings("level", notes.sourceOf(first).?);
    notes.unload(testing.allocator, first);
    try testing.expect(notes.get(first) == null);
    try testing.expect(notes.find("level") == null);
}

test "two kinds of handle are two types" {
    try testing.expect(Handle("SceneHandle") != Handle("DataHandle"));
}
