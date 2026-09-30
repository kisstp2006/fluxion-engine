// SPDX-License-Identifier: BSD-3-Clause

//! A game that shipped as a pack: its project file, its pictures, scenes and
//! text read out of the pack, by path and by UUID, in the game's thread and
//! in the background; a project path with no file of its own on the disc to
//! write; and a sealed pack opened with its key.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const Project = @import("Project.zig");
const scene = @import("scene.zig");
const image = @import("fluxion_image");
const vfs = @import("fluxion_vfs");

const gpa = testing.allocator;

const project_text =
    \\{ "fluxion_project": 2, "application": { "name": "Packed" } }
;
const hello_text = "hello from inside the pack";
const dot_uid = "uid://4b1a8e2c-7d3f-4a51-9c6e-2f0d8b7a1e93";

/// A pack with a project file, a picture known by a UUID, a scene and a
/// text in folders, sealed with `key` when there is one.
fn buildPack(key: ?vfs.Pack.Key) ![]u8 {
    return buildPackWith(key, &.{});
}

fn buildPackWith(key: ?vfs.Pack.Key, more: []const vfs.Pack.Builder.Item) ![]u8 {
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const png = try image.png.encodeAlloc(gpa, .{ .width = 2, .height = 2, .pixels = &pixels, .row_pitch = 8 }, .{ .keep_alpha = true });
    defer gpa.free(png);
    const level = try scene.writeEmpty(gpa, .{});
    defer gpa.free(level);

    const options: vfs.Pack.Builder.Options = if (key) |k| .{ .seal = .{ .key = k, .salt = [_]u8{3} ** 16 } } else .{};
    var items: std.ArrayList(vfs.Pack.Builder.Item) = .empty;
    defer items.deinit(gpa);
    try items.appendSlice(gpa, &.{
        .{ .path = Project.file_name, .bytes = project_text },
        .{ .path = "art/dot.png", .bytes = png, .how = .store },
        .{ .path = "data/hello.txt", .bytes = hello_text },
        .{ .path = "levels/one.json", .bytes = level },
        .{ .path = Project.uid_table, .bytes = dot_uid ++ " res://art/dot.png\n" },
    });
    try items.appendSlice(gpa, more);
    return vfs.Pack.buildWith(gpa, options, items.items);
}

fn userRoot(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "a game that shipped as a pack reads its project, pictures, scenes and text out of it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;

    const bytes = try buildPack(null);
    defer gpa.free(bytes);
    const pack: vfs.Pack = try .fromBytes(gpa, bytes, .{});
    const app = try App.create(gpa, .{ .headless = true, .io = testing.io, .user_root = try userRoot(&tmp, &buffer), .pack = pack });
    defer app.destroy();

    // The project file is the pack's.
    try testing.expectEqualStrings("Packed", app.project.settings.?.application.name);

    const text = try app.readText(gpa, "res://data/hello.txt");
    defer gpa.free(text);
    try testing.expectEqualStrings(hello_text, text);

    try testing.expect(app.fileExists("res://data/hello.txt"));
    try testing.expect(app.fileExists("res://data"));
    try testing.expect(!app.fileExists("res://data/gone.txt"));
    try testing.expectEqual(@as(u64, hello_text.len), (try app.fileInfo("res://data/hello.txt")).size);
    try testing.expect((try app.fileInfo("res://art")).folder);

    const listing = try app.listDir(gpa, "res://");
    defer listing.deinit(gpa);
    const want = [_][]const u8{ "art/", "data/", "levels/", Project.file_name, Project.uid_table };
    try testing.expectEqual(want.len, listing.names.len);
    for (want, listing.names) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectError(error.FileNotFound, app.listDir(gpa, "res://nowhere"));

    // By its UUID, which the pack's table stands for the `.uid` file.
    const dot = try app.assets.loadTexture(dot_uid, .{});
    try testing.expectEqual(@as(f32, 2), app.assets.sizeOf(dot).?.width);
    try testing.expectEqualStrings("res://art/dot.png", app.assets.textureSource(dot).?);

    // In the background, the same: the scene, then read into the world.
    try app.loadInBackground("res://levels/one.json");
    try app.finishLoad("res://levels/one.json");
    try testing.expect(app.loadStatus("res://levels/one.json") == .done);
    _ = try app.readScene("res://levels/one.json", .{});

    // A path that is the system's stays so, though the working directory
    // holds it: a system font is read from the disc, not from the pack.
    const system_path = try std.fs.path.join(gpa, &.{ app.project.cwd, "some.ttf" });
    defer gpa.free(system_path);
    const kept = try app.project.canonical(gpa, system_path);
    defer gpa.free(kept);
    try testing.expectEqualStrings(system_path, kept);

    // A pack is never written, and the player's folder still is.
    try testing.expectError(error.InPack, app.writeText("res://data/new.txt", "no"));
    try app.writeText("user://save.txt", "yes");
    const saved = try app.readText(gpa, "user://save.txt");
    defer gpa.free(saved);
    try testing.expectEqualStrings("yes", saved);
}

test "a sealed pack is the project once it is opened with its key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const key = [_]u8{0x5C} ** 32;

    const bytes = try buildPack(key);
    defer gpa.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, hello_text) == null);
    try testing.expectError(error.KeyNeeded, vfs.Pack.fromBytes(gpa, bytes, .{}));

    const pack: vfs.Pack = try .fromBytes(gpa, bytes, .{ .key = key });
    const app = try App.create(gpa, .{ .headless = true, .io = testing.io, .user_root = try userRoot(&tmp, &buffer), .pack = pack });
    defer app.destroy();
    const text = try app.readText(gpa, "res://data/hello.txt");
    defer gpa.free(text);
    try testing.expectEqualStrings(hello_text, text);
}

test "a script shipped compiled runs from the pack as its text did" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const io = testing.io;

    // What an export does: the scripts compiled by an app that does not run
    // them, the one importing the other.
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.flux", .data = "fn greeting() string { return \"compiled\"; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.flux", .data =
        \\const shared = @import("res://shared.flux");
        \\struct Main {
        \\    fn ready(self) { print(shared.greeting()); }
        \\}
        \\
    });
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const images = blk: {
        const editor = try App.create(gpa, .{ .headless = true, .io = io, .root = root, .user_root = try userRoot(&tmp, &buffer) });
        defer editor.destroy();
        try editor.useScripts(.{ .run = false });
        const main = try editor.compiledScript(try editor.loadScript("res://main.flux"), gpa, .{});
        errdefer gpa.free(main);
        const shared = try editor.compiledScript(try editor.loadScript("res://shared.flux"), gpa, .{ .lines = false });
        break :blk [2][]u8{ main, shared };
    };
    defer for (images) |held| gpa.free(held);
    try testing.expect(std.mem.indexOf(u8, images[0], "greeting") != null);

    const bytes = try buildPackWith(null, &.{
        .{ .path = "main.flux", .bytes = images[0] },
        .{ .path = "shared.flux", .bytes = images[1] },
    });
    defer gpa.free(bytes);
    const pack: vfs.Pack = try .fromBytes(gpa, bytes, .{});
    const app = try App.create(gpa, .{ .headless = true, .io = io, .user_root = try userRoot(&tmp, &buffer), .pack = pack });
    defer app.destroy();
    var printed: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&printed);
    try app.useScripts(.{ .out = &out });
    const main = try app.loadScript("res://main.flux");
    _ = try app.world.spawnWith(.{@import("script.zig").Script.of(main)});
    try app.startup();
    _ = try app.step();
    try testing.expectEqualStrings("compiled\n", out.buffered());
}
