// SPDX-License-Identifier: BSD-3-Clause

//! Data files: values for a Flux struct's `@export`s, kept in a file of
//! their own - a line of dialogue, an enemy's stats, a level's settings - so
//! a game makes the struct from the file and an editor fills the file in.
//!
//! ```json
//! { "fluxion_data": 1, "script": "res://dialogue/line.flux", "struct": "Line",
//!   "values": { "speaker": "Guard", "text": "Halt!", "mood": "angry" } }
//! ```
//!
//! The values are written as a scene writes an entity's `"exports"`, and a
//! field not given one keeps its default. From Flux the file is its struct,
//! made anew each time it is read:
//!
//! ```flux
//! const line = app.readData("res://dialogue/intro.data") catch return;
//! print(line.speaker);
//! ```
//!
//! The file is kept as its bytes, by a `DataHandle` - so a component can
//! name one - and read again by `App.reloadData`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const json = @import("fluxion_json");

const file_table = @import("file_table.zig");

/// A data file read: see `DataFiles`.
pub const DataHandle = file_table.Handle("DataHandle");

/// Every data file read, and the handles they are found by.
pub const DataFiles = file_table.Table(DataHandle);

pub const extension = ".data";

/// The member that says a file is one, and the version it is.
pub const header = "fluxion_data";
pub const version = 1;

/// What a data file says.
pub const Contents = struct {
    doc: json.Document,
    /// The script the struct is in.
    script: []const u8,
    /// The struct: empty for the one named after the script's file, as a
    /// `Script` component's is.
    struct_name: []const u8,
    /// What its fields are given, by name.
    values: json.Value,

    pub fn deinit(self: Contents) void {
        self.doc.deinit();
    }
};

pub const ReadError = error{
    /// It says nothing of being a data file.
    NotData,
    /// It is of a version this engine does not know.
    NewerVersion,
    /// It names no script, or its values are not an object.
    Malformed,
} || json.Error;

/// What `bytes` says, or why it is not a data file.
pub fn read(gpa: Allocator, bytes: []const u8) ReadError!Contents {
    const doc = try json.parse(gpa, bytes, .{});
    errdefer doc.deinit();
    const root = doc.root;
    if (root.asObject() == null or !root.has(header)) return error.NotData;
    if ((root.get(header).asInt(i64) orelse return error.Malformed) > version) return error.NewerVersion;
    const script = root.get("script").asString() orelse return error.Malformed;
    const values = root.get("values");
    if (values != .null and values.asObject() == null) return error.Malformed;
    return .{
        .doc = doc,
        .script = script,
        .struct_name = root.get("struct").asString() orelse "",
        .values = if (values == .null) try doc.object() else values,
    };
}

/// A data file saying that `struct_name` of `script` is given `values`.
pub fn write(gpa: Allocator, script: []const u8, struct_name: []const u8, values: json.Value) json.StringifyError![]u8 {
    const File = struct {
        fluxion_data: u32 = version,
        script: []const u8,
        @"struct": []const u8,
        values: json.Value,
    };
    return json.stringify(gpa, File{ .script = script, .@"struct" = struct_name, .values = values }, .{ .indent = 2 });
}

test "a data file is read back as it was written, and what is not one says so" {
    var given = try json.parse(testing.allocator, "{ \"speaker\": \"Guard\", \"lines\": [\"Halt!\"] }", .{});
    defer given.deinit();
    const text = try write(testing.allocator, "res://line.flux", "Line", given.root);
    defer testing.allocator.free(text);

    const back = try read(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("res://line.flux", back.script);
    try testing.expectEqualStrings("Line", back.struct_name);
    try testing.expectEqualStrings("Guard", back.values.get("speaker").asString().?);

    const plain = try read(testing.allocator, "{ \"fluxion_data\": 1, \"script\": \"res://a.flux\" }");
    defer plain.deinit();
    try testing.expectEqualStrings("", plain.struct_name);
    try testing.expectEqual(@as(usize, 0), plain.values.len());

    try testing.expectError(error.NotData, read(testing.allocator, "{ \"fluxion_scene\": 3 }"));
    try testing.expectError(error.NewerVersion, read(testing.allocator, "{ \"fluxion_data\": 2, \"script\": \"x\" }"));
    try testing.expectError(error.Malformed, read(testing.allocator, "{ \"fluxion_data\": 1 }"));
}
