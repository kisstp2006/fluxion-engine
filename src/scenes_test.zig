// SPDX-License-Identifier: BSD-3-Clause

//! Scenes as things a game makes: instances, instances inside scenes and
//! what a scene says of them, a scene changed for another, what a project
//! opens with, and a scene read in the background.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const image = @import("fluxion_image");
const Uuid = @import("fluxion_id").Uuid;

const App = @import("App.zig");
const Project = @import("Project.zig");
const components = @import("components.zig");
const scene = @import("scene.zig");
const script = @import("script.zig");

const Entity = ecs.Entity;
const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Area2D = components.Area2D;

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .io = testing.io });
}

const bat_text =
    \\{ "fluxion_scene": 3, "entities": [
    \\  { "uuid": "10000000-0000-4000-8000-000000000001", "name": "Bat", "Transform2D": { "x": 1 }, "Sprite": { "width": 8 } },
    \\  { "uuid": "10000000-0000-4000-8000-000000000002", "parent": "10000000-0000-4000-8000-000000000001", "name": "Wing", "Transform2D": { "x": 3 } }
    \\] }
;
const wing_in_file: Uuid = .parseComptime("10000000-0000-4000-8000-000000000002");

test "an instance is its scene's root under the parent given, with UUIDs of its own that are the same every time" {
    const app = try headless();
    defer app.destroy();
    const bat = try app.addScene("res://bat.json", bat_text);
    const cave = try app.world.spawnWith(.{Transform2D.at(100, 0)});

    const one = try app.instantiate(bat, cave);
    const two = try app.instantiate(bat, cave);
    try testing.expect(app.parentOf(one).eql(cave));
    try testing.expectEqualStrings("Bat", app.nameOf(one).?);
    // A name is its siblings' own.
    try testing.expectEqualStrings("Bat 2", app.nameOf(two).?);
    const wing = app.findPath(one, "Wing").?;
    try testing.expectEqual(@as(f32, 3), app.world.get(wing, Transform2D).?.x);

    // Each instance's UUIDs are made from its own: found again by them, and
    // never another instance's.
    try testing.expect(app.uuidOf(wing).?.eql(Uuid.fromName(app.uuidOf(one).?, &wing_in_file.bytes)));
    try testing.expect(!app.uuidOf(app.findPath(two, "Wing").?).?.eql(app.uuidOf(wing).?));

    // Remembered as an instance, with what it made.
    try testing.expect(app.instanceOf(one).?.scene.eql(bat));
    try testing.expect(app.instanceHolding(wing).?.eql(one));
    try testing.expectEqual(@as(usize, 1), app.instanceOf(one).?.members.len);

    // Made local, it is the world's own.
    app.makeLocal(two);
    try testing.expect(app.instanceOf(two) == null);

    // A scene of two roots makes no instance, and leaves nothing behind.
    const pair = try app.addScene("res://pair.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"Transform2D\": {} }, { \"Transform2D\": {} } ] }");
    const before = app.world.count();
    try testing.expectError(error.NotOneRoot, app.instantiate(pair, .none));
    try testing.expectEqual(before, app.world.count());

    // Nor does one that is an instance of itself: it would never end.
    const loop = try app.addScene("res://loop.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"name\": \"Me\", \"instance\": \"res://loop.json\" } ] }");
    try testing.expectError(error.SceneHoldsItself, app.instantiate(loop, .none));
    try testing.expectEqual(before, app.world.count());
}

test "a scene holds an instance of another, made from it, with what it says of its root over it, and saved as it was read" {
    const app = try headless();
    defer app.destroy();
    _ = try app.addScene("res://bat.json", bat_text);

    // Something of the level hangs from the bat's wing, named as the level
    // file names it: after the instance.
    const big_uuid: Uuid = .parseComptime("20000000-0000-4000-8000-000000000002");
    const wing_uuid = Uuid.fromName(big_uuid, &wing_in_file.bytes).toString();
    var buffer: [1024]u8 = undefined;
    const level = try std.fmt.bufPrint(&buffer,
        \\{{ "fluxion_scene": 3, "entities": [
        \\  {{ "uuid": "20000000-0000-4000-8000-000000000001", "name": "Cave", "Transform2D": {{}} }},
        \\  {{ "uuid": "20000000-0000-4000-8000-000000000002", "parent": "20000000-0000-4000-8000-000000000001", "name": "Big bat",
        \\    "instance": "res://bat.json", "Transform2D": {{ "x": 50 }}, "Area2D": {{}}, "removed": ["Sprite"] }},
        \\  {{ "name": "Bell", "parent": "{s}", "Transform2D": {{}} }}
        \\] }}
    , .{&wing_uuid});
    _ = try scene.read(app, level, .{});

    const check = struct {
        fn world(a: *App) !void {
            const big = a.find("Big bat").?;
            try testing.expectEqualStrings("Cave", a.nameOf(a.parentOf(big)).?);
            // What the level says, over what the scene gives.
            try testing.expectEqual(@as(f32, 50), a.world.get(big, Transform2D).?.x);
            try testing.expect(!a.world.has(big, Sprite));
            try testing.expect(a.world.has(big, Area2D));
            // And the rest of it the scene's.
            const wing = a.findPath(big, "Wing").?;
            try testing.expectEqual(@as(f32, 3), a.world.get(wing, Transform2D).?.x);
            try testing.expect(a.parentOf(a.find("Bell").?).eql(wing));
            try testing.expect(a.instanceOf(big) != null);
        }
    }.world;
    try check(app);

    // Written as it was read: the instance, and what differs from its scene.
    const saved = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"instance\": \"res://bat.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"removed\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"Wing\"") == null);
    app.clearWorld();
    _ = try scene.read(app, saved, .{});
    try check(app);
}

test "an instance's root changed in the world is saved as what differs from its scene" {
    const app = try headless();
    defer app.destroy();
    const bat = try app.addScene("res://bat.json", bat_text);
    const one = try app.instantiate(bat, .none);
    app.world.get(one, Transform2D).?.x = 7;
    _ = try app.world.add(one, Area2D{});

    const saved = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);
    // Its sprite is the scene's, so the file says nothing of it.
    try testing.expect(std.mem.indexOf(u8, saved, "\"Sprite\"") == null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"Area2D\"") != null);

    app.clearWorld();
    _ = try scene.read(app, saved, .{});
    const back = app.find("Bat").?;
    try testing.expectEqual(@as(f32, 7), app.world.get(back, Transform2D).?.x);
    try testing.expectEqual(@as(f32, 8), app.world.get(back, Sprite).?.width);
    try testing.expect(app.world.has(back, Area2D));
    try testing.expect(app.findPath(back, "Wing") != null);
}

test "a branch is saved as a scene of its own, with nothing it hangs from" {
    const app = try headless();
    defer app.destroy();
    const cave = try app.world.spawnWith(.{Transform2D.at(1, 0)});
    try app.setName(cave, "Cave");
    const rock = try app.world.spawnWith(.{ Transform2D.at(2, 0), components.Parent.of(cave) });
    try app.setName(rock, "Rock");
    const sky = try app.world.spawnWith(.{Transform2D.at(3, 0)});
    try app.setName(sky, "Sky");
    const top = try app.world.spawnWith(.{Transform2D{}});
    try app.setParent(cave, top, false);

    const saved = try scene.write(app, testing.allocator, .{ .root = cave });
    defer testing.allocator.free(saved);
    var info = (try scene.readInfo(testing.allocator, saved, null)).?;
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), info.entities);
    try testing.expectEqual(@as(usize, 1), info.roots);
    try testing.expect(std.mem.indexOf(u8, saved, "\"Sky\"") == null);

    // And so it is a scene an instance can be made of.
    const branch = try app.addScene("res://cave.json", saved);
    const copy = try app.instantiate(branch, .none);
    try testing.expect(app.findPath(copy, "Rock") != null);
}

test "a scene changed for another at the end of the frame takes its own with it, and leaves what is not its own" {
    const app = try headless();
    defer app.destroy();
    const first = try app.addScene("res://a.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"uuid\": \"30000000-0000-4000-8000-000000000001\", \"name\": \"A\", \"Transform2D\": {} }, { \"parent\": \"30000000-0000-4000-8000-000000000001\", \"name\": \"A child\", \"Transform2D\": {} } ] }");
    const second = try app.addScene("res://b.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"uuid\": \"30000000-0000-4000-8000-000000000002\", \"name\": \"B\", \"Transform2D\": {} } ] }");
    const music = try app.world.spawn();
    try app.setName(music, "Music");

    try app.openScene(first);
    try testing.expect(app.currentScene().eql(first));
    try testing.expect(app.find("A") != null);

    app.changeScene(second);
    try testing.expect(app.find("A") != null);
    _ = try app.step();
    try testing.expect(app.find("A") == null);
    try testing.expect(app.find("A child") == null);
    try testing.expect(app.find("B") != null);
    try testing.expect(app.find("Music") != null);
    try testing.expect(app.currentScene().eql(second));

    // The same scene again is read with its own UUIDs, not new ones.
    app.changeScene(second);
    _ = try app.step();
    try testing.expect(app.findUuid(.parseComptime("30000000-0000-4000-8000-000000000002")).?.eql(app.find("B").?));
}

test "a branch is despawned now, and all of it" {
    const app = try headless();
    defer app.destroy();
    const trunk = try app.world.spawn();
    const branch = try app.world.spawnWith(.{components.Parent.of(trunk)});
    const leaf = try app.world.spawnWith(.{components.Parent.of(branch)});
    const other = try app.world.spawn();
    try app.despawnTree(trunk);
    try testing.expect(!app.world.isAlive(trunk));
    try testing.expect(!app.world.isAlive(branch));
    try testing.expect(!app.world.isAlive(leaf));
    try testing.expect(app.world.isAlive(other));
}

/// A project on disk: its folder, under the test's own.
const Folder = struct {
    tmp: std.testing.TmpDir,
    buffer: [160]u8 = undefined,
    root: []const u8 = "",

    fn init() Folder {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn at(folder: *Folder) ![]const u8 {
        folder.root = try std.fmt.bufPrint(&folder.buffer, ".zig-cache/tmp/{s}", .{folder.tmp.sub_path});
        return folder.root;
    }

    fn put(folder: *Folder, name: []const u8, text: []const u8) !void {
        try folder.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    }
};

test "a project opens with its autoloads, named after their files, and then its main scene" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const root = try folder.at();
    try folder.put("main.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"name\": \"Menu\", \"Transform2D\": {} } ] }");
    try folder.put("music.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"name\": \"Player\", \"Transform2D\": {} } ] }");
    try folder.put("state.flux", "struct State { }");
    try Project.writeSettings(testing.allocator, testing.io, root, .{ .application = .{
        .name = "Opened",
        .main_scene = "res://main.json",
        .autoload = &.{ "res://music.json", "res://state.flux" },
    } });

    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .open_project = true });
    defer app.destroy();
    try app.useScripts(.{});
    try app.startup();
    try testing.expect(app.find("Menu") != null);
    try testing.expect(app.find("music") != null);
    try testing.expect(app.world.has(app.find("state").?, script.Script));

    // A scene changed keeps them.
    app.changeScene(try app.addScene("res://other.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"name\": \"Level\" } ] }"));
    _ = try app.step();
    try testing.expect(app.find("Menu") == null);
    try testing.expect(app.find("music") != null);
    try testing.expect(app.find("state") != null);
}

test "a scene read in the background has its pictures made when it is taken" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const root = try folder.at();
    try Project.writeSettings(testing.allocator, testing.io, root, .{ .application = .{ .name = "Loading" } });
    var pixels: [4 * 4 * 4]u8 = @splat(200);
    var path_buffer: [200]u8 = undefined;
    const picture_path = try std.fmt.bufPrint(&path_buffer, "{s}/hero.png", .{root});
    try image.png.writeFile(testing.allocator, testing.io, picture_path, .{ .width = 4, .height = 4, .pixels = &pixels, .row_pitch = 16 }, .{});
    try folder.put("level.json", "{ \"fluxion_scene\": 3, \"entities\": [ { \"name\": \"Hero\", \"Transform2D\": {}, \"Sprite\": { \"texture\": \"res://hero.png\" } } ] }");

    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root });
    defer app.destroy();
    const load = try app.loadInBackground("res://level.json");
    // Nothing waits on it but this test.
    var frames: usize = 0;
    while (!load.done() and frames < 1000) : (frames += 1) _ = try app.step();
    try testing.expect(load.done());
    try testing.expectEqual(@as(f32, 1), load.progress());
    const level = try app.takeScene(load);
    // The picture is a texture already, which the scene finds rather than reads.
    try testing.expect(app.assets.findTexture("res://hero.png") != null);
    try app.openScene(level);
    const hero = app.find("Hero").?;
    try testing.expect(app.world.get(hero, Sprite).?.texture.eql(app.assets.findTexture("res://hero.png").?));

    // A scene that is not there says so when it is taken.
    const missing = try app.loadInBackground("res://nowhere.json");
    try testing.expectError(error.FileNotFound, app.takeScene(missing));
}
