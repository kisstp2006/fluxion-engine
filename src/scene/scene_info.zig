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

    fn deinit(glance: *Glance) void {
        for (glance.files.items) |named| glance.gpa.free(named.path);
        glance.files.deinit(glance.gpa);
    }

    fn scene(glance: *Glance) json.Reader.Error!void {
        if (try glance.next() != .object_begin) return;
        while (try glance.key()) |name| {
            // Told apart before the next token, which the name does not
            // outlive.
            const member = std.meta.stringToEnum(enum { fluxion_scene, entities, assets }, name) orelse {
                try glance.reader.skipValue();
                continue;
            };
            switch (member) {
                .fluxion_scene => {
                    const number = switch (try glance.next()) {
                        .number => |n| n.asInt(u32),
                        else => null,
                    } orelse return;
                    glance.said.version = number;
                    glance.versioned = true;
                },
                .entities => {
                    if (try glance.peek() != .array_begin) {
                        try glance.reader.skipValue();
                        continue;
                    }
                    _ = try glance.next();
                    while (try glance.peek() != .array_end) {
                        glance.said.entities += 1;
                        if (!try glance.parented()) glance.said.roots += 1;
                    }
                    _ = try glance.next();
                },
                .assets => {
                    if (try glance.peek() != .object_begin) {
                        try glance.reader.skipValue();
                        continue;
                    }
                    _ = try glance.next();
                    while (try glance.key()) |path| {
                        try glance.files.ensureUnusedCapacity(glance.gpa, 1);
                        glance.files.appendAssumeCapacity(.{ .path = try glance.gpa.dupe(u8, path) });
                        glance.files.items[glance.files.items.len - 1].uid = try glance.uid();
                    }
                },
            }
        }
    }

    /// Whether the entity next names a parent. The entity is passed over.
    fn parented(glance: *Glance) json.Reader.Error!bool {
        if (try glance.peek() != .object_begin) {
            try glance.reader.skipValue();
            return false;
        }
        _ = try glance.next();
        var found_parent = false;
        while (try glance.key()) |name| {
            if (std.mem.eql(u8, name, "parent")) found_parent = true;
            try glance.reader.skipValue();
        }
        return found_parent;
    }

    /// The UUID in what `assets` says of one file, when it says one that
    /// reads.
    fn uid(glance: *Glance) json.Reader.Error!?Uuid {
        if (try glance.peek() != .object_begin) {
            try glance.reader.skipValue();
            return null;
        }
        _ = try glance.next();
        var found_uid: ?Uuid = null;
        while (try glance.key()) |field| {
            if (!std.mem.eql(u8, field, "uid") or try glance.peek() != .string) {
                try glance.reader.skipValue();
                continue;
            }
            const text = (try glance.next()).string;
            const body = if (std.mem.startsWith(u8, text, Project.uid_scheme)) text[Project.uid_scheme.len..] else text;
            found_uid = Uuid.parse(body) catch null;
        }
        return found_uid;
    }

    /// The next token. The input ending where a value should be is a
    /// mistake, never the end of a loop.
    fn next(glance: *Glance) json.Reader.Error!Token {
        return (try glance.reader.next()) orelse glance.endsTooSoon();
    }

    fn peek(glance: *Glance) json.Reader.Error!json.Reader.Kind {
        return (try glance.reader.peek()) orelse glance.endsTooSoon();
    }

    fn endsTooSoon(glance: *Glance) json.Reader.Error {
        glance.reader.report("the scene ends too soon", .{});
        return error.SyntaxError;
    }

    /// The next member's name, or null at the end of the object.
    fn key(glance: *Glance) json.Reader.Error!?[]const u8 {
        return switch (try glance.next()) {
            .key => |name| name,
            else => null,
        };
    }
};
