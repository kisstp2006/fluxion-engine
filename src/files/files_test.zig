// SPDX-License-Identifier: BSD-3-Clause

//! A game's files through a whole app, headless: moving, throwing away, new scenes,
//! user:// and its folders, config, appending, hashing and sealing.

const std = @import("std");
const testing = std.testing;

const ConfigFile = @import("config_file.zig").ConfigFile;
const Project = @import("../project/Project.zig");
const components = @import("../scene/components.zig");
const platform = @import("fluxion_platform");
const scene = @import("../scene/scene.zig");
const helpers = @import("../test_helpers.zig");
const Files = helpers.Files;

test "a file moved takes what was read from it along, and the scene saved next names the new place" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/hero.png");
    const app = try files.app();
    defer app.destroy();

    const hero = try app.assets.loadTexture("res://art/hero.png", .{});
    _ = try app.world.spawnWith(.{ components.Transform2D.at(1, 2), components.Sprite.of(hero) });
    try app.saveScene("res://meadow.json", .{});
    const uid = app.project.knownUid("res://art/hero.png").?;

    try app.moveFile("res://art/hero.png", "res://art/ada.png");
    try testing.expectEqualStrings("res://art/ada.png", app.assets.textureSource(hero).?);
    try testing.expect(app.assets.findTexture("res://art/ada.png").?.eql(hero));

    // A folder, and what was read from inside it.
    try app.moveFile("res://art", "res://pictures");
    try testing.expectEqualStrings("res://pictures/ada.png", app.assets.textureSource(hero).?);
    try testing.expectEqualStrings("res://pictures/ada.png", (try app.project.pathOf(uid)).?);

    // Another run finds it by its UUID from the scene saved before the moves,
    // and the scene saved now names where it is.
    const other = try files.app();
    defer other.destroy();
    const loaded = try other.readScene("res://meadow.json", .{});
    try testing.expectEqual(@as(usize, 1), loaded.moved);
    try app.saveScene("res://meadow.json", .{});
    var said = (try app.sceneInfo("res://meadow.json", null)).?;
    defer said.deinit(testing.allocator);
    try testing.expectEqualStrings("res://pictures/ada.png", said.files[0].path);
    try testing.expect(said.files[0].uid.?.eql(uid));
}

test "a file thrown away goes to the trash with its UUID, which names nothing after it" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.picture("art/hero.png");
    const app = try files.app();
    defer app.destroy();
    if (comptime !@hasDecl(platform, "trash")) {
        try testing.expectError(error.Unsupported, app.moveToTrash("res://art/hero.png"));
        return;
    }
    // A trash of the test's own: the person's is not the test's to fill.
    var trash_buffer: [160]u8 = undefined;
    app.trash = try std.fmt.bufPrint(&trash_buffer, "{s}/Trash", .{try files.at()});
    const uid = try app.project.ensureUid("res://art/hero.png");

    try app.moveToTrash("res://art/hero.png");
    const dir = files.tmp.dir;
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/hero.png", .{}));
    try testing.expectError(error.FileNotFound, dir.access(testing.io, "art/hero.png.uid", .{}));
    try dir.access(testing.io, "Trash/files/hero.png", .{});
    try dir.access(testing.io, "Trash/files/hero.png.uid", .{});
    try dir.access(testing.io, "Trash/info/hero.png.trashinfo", .{});
    try testing.expect(app.project.knownUid("res://art/hero.png") == null);
    try testing.expect(app.project.by_uid.get(uid) == null);

    // Another of the same name, beside the first; a folder, whole.
    try files.picture("art/hero.png");
    try app.moveToTrash("res://art/hero.png");
    try dir.access(testing.io, "Trash/files/hero.png.2", .{});
    try app.moveToTrash("res://art");
    try dir.access(testing.io, "Trash/files/art", .{});
    try testing.expectError(error.FileNotFound, app.moveToTrash("res://art"));
}

test "a new scene is written empty, never over another, and says what it is without being loaded" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();

    try app.createScene("res://levels.json", .{});
    try testing.expectError(error.PathAlreadyExists, app.createScene("res://levels.json", .{ .format = .cbor }));
    var said = (try app.sceneInfo("res://levels.json", null)).?;
    defer said.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, scene.version), said.version);
    try testing.expectEqual(@as(usize, 0), said.entities);
    try testing.expectEqual(@as(usize, 0), (try app.readScene("res://levels.json", .{})).entities);

    try files.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.json", .data = "{ \"hello\": 1 }" });
    try testing.expect(try app.sceneInfo("res://notes.json", null) == null);
}

test "a game's files are read, written whole, listed and taken out, under user:// and elsewhere" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();
    app.project.user_root = try std.fs.path.join(testing.allocator, &.{ try files.at(), "saves" });

    try testing.expect(!app.fileExists("user://slots/one.json"));
    try testing.expectError(error.FileNotFound, app.readText(testing.allocator, "user://slots/one.json"));
    try app.writeText("user://slots/one.json", "{ \"level\": 1 }");
    try app.writeText("user://slots/one.json", "{ \"level\": 2 }");
    try testing.expect(app.fileExists("user://slots/one.json"));
    const text = try app.readText(testing.allocator, "user://slots/one.json");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{ \"level\": 2 }", text);

    try app.makeDir("user://slots/old");
    try app.makeDir("user://slots/old");
    try app.writeText("user://slots/a.json", "{}");
    {
        const listed = try app.listDir(testing.allocator, "user://slots");
        defer listed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 3), listed.names.len);
        try testing.expectEqualStrings("a.json", listed.names[0]);
        try testing.expectEqualStrings("old/", listed.names[1]);
        try testing.expectEqualStrings("one.json", listed.names[2]);
    }
    try app.removeFile("user://slots/old");
    try app.removeFile("user://slots/a.json");
    try testing.expect(!app.fileExists("user://slots/a.json"));
    try testing.expectError(error.FileNotFound, app.removeFile("user://slots/a.json"));

    // The project's own files are read the same way.
    try files.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "hello" });
    const notes = try app.readText(testing.allocator, "res://notes.txt");
    defer testing.allocator.free(notes);
    try testing.expectEqualStrings("hello", notes);
}

test "a config file keeps a game's settings in user://, and is empty until there is one" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();
    app.project.user_root = try std.fs.path.join(testing.allocator, &.{ try files.at(), "saves" });

    var config = try ConfigFile.load(app, "user://settings.cfg");
    defer config.deinit();
    try testing.expectEqual(@as(usize, 0), config.sections().len);
    try config.set("audio", "music", 0.5);
    try config.save(app, "user://settings.cfg");

    var again = try ConfigFile.load(app, "user://settings.cfg");
    defer again.deinit();
    try testing.expectEqual(@as(f64, 0.5), again.getFloat("audio", "music", 1));
}

test "a file is added to, told of, hashed, and kept compressed or sealed" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();
    app.project.user_root = try std.fs.path.join(testing.allocator, &.{ try files.at(), "saves" });
    app.secret_cost = .cheapest;

    try app.appendText("user://logs/run.txt", "one\n");
    try app.appendText("user://logs/run.txt", "two\n");
    const written = try app.readText(testing.allocator, "user://logs/run.txt");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("one\ntwo\n", written);

    const info = try app.fileInfo("user://logs/run.txt");
    try testing.expectEqual(@as(u64, 8), info.size);
    try testing.expect(!info.folder);
    // Written a moment ago, by the clock the game tells the time with.
    try testing.expect(@abs(app.now().since(info.modified).us) < 60 * std.time.us_per_s);
    try testing.expect(app.isDir("user://logs"));
    try testing.expect(!app.isDir("user://logs/run.txt"));
    try testing.expect(!app.isDir("user://none"));
    try testing.expectError(error.FileNotFound, app.fileInfo("user://none"));

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("one\ntwo\n", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, &(try app.fileSha256("user://logs/run.txt")));

    const big = "a line of a save\n" ** 300;
    try app.writeCompressed("user://big.gz", big);
    try testing.expect((try app.fileInfo("user://big.gz")).size < big.len / 10);
    const unpacked = try app.readCompressed(testing.allocator, "user://big.gz");
    defer testing.allocator.free(unpacked);
    try testing.expectEqualStrings(big, unpacked);
    try testing.expectError(error.NotCompressed, app.readCompressed(testing.allocator, "user://logs/run.txt"));

    try app.writeSecret("user://progress.sav", "{\"gold\": 9}", "a password");
    const on_disc = try app.readText(testing.allocator, "user://progress.sav");
    defer testing.allocator.free(on_disc);
    try testing.expect(std.mem.indexOf(u8, on_disc, "gold") == null);
    const opened = try app.readSecret(testing.allocator, "user://progress.sav", "a password");
    defer testing.allocator.free(opened);
    try testing.expectEqualStrings("{\"gold\": 9}", opened);
    try testing.expectError(error.CannotOpen, app.readSecret(testing.allocator, "user://progress.sav", "another"));
    try testing.expectError(error.NotSealed, app.readSecret(testing.allocator, "user://logs/run.txt", "a password"));

    // Where a file is on this computer, and the name the game gives it back.
    const global = try app.project.osPath(testing.allocator, "user://logs/run.txt");
    defer testing.allocator.free(global);
    const local = try app.project.localPath(testing.allocator, global);
    defer testing.allocator.free(local);
    try testing.expectEqualStrings("user://logs/run.txt", local);
    const art = try app.project.osPath(testing.allocator, "res://art");
    defer testing.allocator.free(art);
    const named = try app.project.localPath(testing.allocator, art);
    defer testing.allocator.free(named);
    try testing.expectEqualStrings("res://art", named);

    // An address a browser opens, and nothing else.
    try testing.expectError(error.NotAllowed, app.openUrl("file:///C:/Windows/notepad.exe"));
    try testing.expectError(error.NotAllowed, app.openUrl("calc.exe"));
}

test "user:// is the folder the project names, a step or more, each a name any system keeps" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    try files.tmp.dir.writeFile(testing.io, .{ .sub_path = Project.file_name, .data =
        \\{ "fluxion_project": 2, "application": { "name": "Night", "user_folder": "Tiny Studio/Night: Two" } }
    });
    const app = try files.app();
    defer app.destroy();
    const where = app.project.userRoot() catch |err| switch (err) {
        // A machine with no folder for programs' data.
        error.NoUserFolder => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(std.mem.endsWith(u8, where, "Tiny Studio" ++ std.fs.path.sep_str ++ "Night_ Two"));
}
