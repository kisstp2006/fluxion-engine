// SPDX-License-Identifier: BSD-3-Clause

//! What a scene says of itself - its version, its format, how many entities
//! and which files - read without loading it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const scene = @import("scene.zig");
const scene_read = @import("scene_read.zig");

const Token = scene_read.Token;

/// What a scene says of itself, read without loading it: see `readInfo`.
pub const Info = struct {
    /// The version the file says it is. Only `version` loads; another is told
    /// rather than refused, so a tool can say which it is.
    version: u32,
    format: json.Format,
    /// How many entities it lists.
    entities: usize = 0,
    /// How many of them name no parent: a scene of one is one an instance
    /// can be made of.
    roots: usize = 0,
    /// The files its `assets` table lists, in the file's order: for a scene
    /// `save` wrote, every file of the project's that it names.
    files: []File = &.{},

    pub const File = struct {
        /// As the scene gives it: `res://` for a file of the project's.
        path: []const u8,
        /// The UUID the scene knows it by, which finds it where it moved.
        uid: ?Uuid = null,
    };

    pub fn deinit(self: *Info, gpa: Allocator) void {
        for (self.files) |named| gpa.free(named.path);
        gpa.free(self.files);
        self.* = undefined;
    }
};

/// What starts every CBOR scene: the self-described tag, which is also how
/// the reader tells the two formats apart.
const cbor_start = "\xD9\xD9\xF7";

/// What the scene at `path` says of itself, read without loading it: see
/// `App.sceneInfo`.
pub fn ofFile(app: *App, path: []const u8, diagnostics: ?*json.Diagnostics) !?Info {
    const bytes = try app.project.readFileAlloc(app.gpa, path, .unlimited);
    defer app.gpa.free(bytes);
    return readInfo(app.gpa, bytes, diagnostics);
}

/// What the scene in `bytes` says of itself - its version, its format, how
/// many entities and which files - with no world to load it into: what an
/// editor shows of a scene it has not opened. Null when the bytes are not a
/// scene, which is anything that has not said `fluxion_scene` before it
/// stops making sense. A scene damaged after that is an error, and where
/// is in `diagnostics`. Free it with `Info.deinit`.
pub fn readInfo(gpa: Allocator, bytes: []const u8, diagnostics: ?*json.Diagnostics) !?Info {
    var reader: json.Reader = .init(gpa, bytes, .{ .syntax = .json5, .diagnostics = diagnostics });
    defer reader.deinit();

    var glance: Glance = .{
        .gpa = gpa,
        .reader = &reader,
        .said = .{ .version = 0, .format = if (std.mem.startsWith(u8, bytes, cbor_start)) .cbor else .json },
    };
    defer glance.deinit();
    glance.scene() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError, error.TooDeep => if (glance.versioned) return err else return null,
    };
    if (!glance.versioned) return null;

    var said = glance.said;
    said.files = try glance.files.toOwnedSlice(gpa);
    return said;
}

/// `readInfo`'s one pass: the members it wants, and the rest passed over.
/// Nothing a scene holds is checked but its shape where `readInfo` looks, so a
/// scene of another version is told as far as it can be.
const Glance = struct {
    gpa: Allocator,
    reader: *json.Reader,
    said: Info,
    /// Whether the scene has said its version: from then on, it is one.
    versioned: bool = false,
    files: std.ArrayList(Info.File) = .empty,

    fn deinit(g: *Glance) void {
        for (g.files.items) |named| g.gpa.free(named.path);
        g.files.deinit(g.gpa);
    }

    fn scene(g: *Glance) json.Reader.Error!void {
        if (try g.next() != .object_begin) return;
        while (try g.key()) |name| {
            // Told apart before the next token, which the name does not
            // outlive.
            const member = std.meta.stringToEnum(enum { fluxion_scene, entities, assets }, name) orelse {
                try g.reader.skipValue();
                continue;
            };
            switch (member) {
                .fluxion_scene => {
                    const number = switch (try g.next()) {
                        .number => |n| n.asInt(u32),
                        else => null,
                    } orelse return;
                    g.said.version = number;
                    g.versioned = true;
                },
                .entities => {
                    if (try g.peek() != .array_begin) {
                        try g.reader.skipValue();
                        continue;
                    }
                    _ = try g.next();
                    while (try g.peek() != .array_end) {
                        g.said.entities += 1;
                        if (!try g.parented()) g.said.roots += 1;
                    }
                    _ = try g.next();
                },
                .assets => {
                    if (try g.peek() != .object_begin) {
                        try g.reader.skipValue();
                        continue;
                    }
                    _ = try g.next();
                    while (try g.key()) |path| {
                        try g.files.ensureUnusedCapacity(g.gpa, 1);
                        g.files.appendAssumeCapacity(.{ .path = try g.gpa.dupe(u8, path) });
                        g.files.items[g.files.items.len - 1].uid = try g.uid();
                    }
                },
            }
        }
    }

    /// Whether the entity next names a parent. The entity is passed over.
    fn parented(g: *Glance) json.Reader.Error!bool {
        if (try g.peek() != .object_begin) {
            try g.reader.skipValue();
            return false;
        }
        _ = try g.next();
        var found_parent = false;
        while (try g.key()) |name| {
            if (std.mem.eql(u8, name, "parent")) found_parent = true;
            try g.reader.skipValue();
        }
        return found_parent;
    }

    /// The UUID in what `assets` says of one file, when it says one that
    /// reads.
    fn uid(g: *Glance) json.Reader.Error!?Uuid {
        if (try g.peek() != .object_begin) {
            try g.reader.skipValue();
            return null;
        }
        _ = try g.next();
        var found_uid: ?Uuid = null;
        while (try g.key()) |field| {
            if (!std.mem.eql(u8, field, "uid") or try g.peek() != .string) {
                try g.reader.skipValue();
                continue;
            }
            const text = (try g.next()).string;
            const body = if (std.mem.startsWith(u8, text, Project.uid_scheme)) text[Project.uid_scheme.len..] else text;
            found_uid = Uuid.parse(body) catch null;
        }
        return found_uid;
    }

    /// The next token. The input ending where a value should be is a
    /// mistake, never the end of a loop.
    fn next(g: *Glance) json.Reader.Error!Token {
        return (try g.reader.next()) orelse g.endsTooSoon();
    }

    fn peek(g: *Glance) json.Reader.Error!json.Reader.Kind {
        return (try g.reader.peek()) orelse g.endsTooSoon();
    }

    fn endsTooSoon(g: *Glance) json.Reader.Error {
        g.reader.report("the scene ends too soon", .{});
        return error.SyntaxError;
    }

    /// The next member's name, or null at the end of the object.
    fn key(g: *Glance) json.Reader.Error!?[]const u8 {
        return switch (try g.next()) {
            .key => |name| name,
            else => null,
        };
    }
};
