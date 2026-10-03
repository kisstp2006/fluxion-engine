// SPDX-License-Identifier: BSD-3-Clause

//! Scene files written and read through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const scene = @import("scene.zig");
const App = @import("../App.zig");
const Assets = @import("../assets/assets.zig");
const Entity = ecs.Entity;
const EntityJson = scene.EntityJson;
const FontHandle = Assets.FontHandle;
const Label = @import("../ui/control.zig").Label;
const LineEdit = @import("../ui/control.zig").LineEdit;
const Text2D = components.Text2D;
const TileMap = tilemap.TileMap;
const Uuid = @import("fluxion_id").Uuid;
const components = @import("components.zig");
const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const nameOf = scene.nameOf;
const read = scene.read;
const readInfo = scene.readInfo;
const rhi = @import("fluxion_rhi");
const tilemap = @import("../tiles/tilemap.zig");
const version = scene.version;
const write = scene.write;
const writeEmpty = scene.writeEmpty;

const image = @import("fluxion_image");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Camera2D = components.Camera2D;
const AnimatedSprite2D = @import("../animation/sprite_frames.zig").AnimatedSprite2D;

/// A game's own component, holding the kinds of thing a component can.
const Wander = extern struct {
    dx: f32,
    dy: f32 = 0,
    mood: Mood = .calm,
    /// Who it is following, if anyone.
    leader: Entity = .none,
    seed: u64 = 0,
    steps: [3]u8 = .{ 1, 2, 3 },

    const Mood = enum(u8) { calm, curious, cross };
};

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .io = testing.io });
}

/// UUIDs a test gives, so that what is written can be read off the page.
const fixed_uuids = [_]Uuid{
    .parseComptime("00000000-0000-4000-8000-000000000001"),
    .parseComptime("00000000-0000-4000-8000-000000000002"),
    .parseComptime("00000000-0000-4000-8000-000000000003"),
};

test "a scene reads as what it holds, and leaves out what is the default" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Wander});

    const camera = try app.world.spawnWith(.{ Transform2D.at(320, 180), Camera2D{} });
    try app.setName(camera, "camera");
    const words = try app.world.spawnWith(.{ Transform2D.at(0, -6), components.Parent.of(camera), Text2D{ .size = 13 } });
    try app.setText(words, Text2D, "text", "Hi");
    const wanderer = try app.world.spawnWith(.{Wander{ .dx = 1, .mood = .cross, .leader = camera }});
    for ([_]Entity{ camera, words, wanderer }, fixed_uuids) |e, uuid| try app.setUuid(e, uuid);

    const text = try write(app, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{
        \\  "fluxion_scene": 3,
        \\  "entities": [
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000001",
        \\      "name": "camera",
        \\      "Transform2D": { "x": 320.0, "y": 180.0 },
        \\      "Camera2D": {}
        \\    },
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000002",
        \\      "parent": "00000000-0000-4000-8000-000000000001",
        \\      "Transform2D": { "y": -6.0 },
        \\      "Text2D": { "text": "Hi", "size": 13.0 }
        \\    },
        \\    {
        \\      "uuid": "00000000-0000-4000-8000-000000000003",
        \\      "Wander": {
        \\        "dx": 1.0,
        \\        "mood": "cross",
        \\        "leader": "00000000-0000-4000-8000-000000000001"
        \\      }
        \\    }
        \\  ]
        \\}
    , text);
}

test "a UI label keeps its words through a scene round trip, however long" {
    const source = try headless();
    defer source.destroy();
    const words = try source.world.spawnWith(.{Label{ .outline_width = 2 }});
    try source.setName(words, "words");
    try source.setText(words, Label, "text", "Hello UI");
    const field = try source.world.spawnWith(.{LineEdit{}});
    try source.setName(field, "field");
    const long = "Player " ** 100;
    try source.setText(field, LineEdit, "text", long);
    try source.setText(field, LineEdit, "placeholder_text", "Name");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"text\": \"Hello UI\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"placeholder_text\": \"Name\"") != null);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});
    const label = copy.find("words").?;
    try testing.expectEqualStrings("Hello UI", copy.textOf(label, Label, "text"));
    try testing.expectEqual(@as(u16, 2), copy.world.get(label, Label).?.outline_width);
    const line = copy.find("field").?;
    try testing.expectEqualStrings(long, copy.textOf(line, LineEdit, "text"));
    try testing.expectEqualStrings("Name", copy.textOf(line, LineEdit, "placeholder_text"));
}

test "a 3D transform keeps its place, turn and size through a scene round trip" {
    const source = try headless();
    defer source.destroy();
    var placed: components.Transform3D = .at(1, 2, 3);
    placed.setRotationDegrees(.init(10, 45, 0));
    placed.scale = .init(2, 2, 2);
    const box = try source.world.spawnWith(.{placed});
    try source.setName(box, "box");
    const moved = try source.world.spawnWith(.{components.Transform3D.at(0, 0, -1)});
    try source.setName(moved, "nothing turned");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    // What is the default is left out: no rotation for the second.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"rotation\""));

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});
    const back = copy.world.get(copy.find("box").?, components.Transform3D).?;
    try testing.expectEqual(placed.position, back.position);
    try testing.expectEqual(placed.rotation, back.rotation);
    try testing.expectEqual(@as(f32, 2), back.scale.z);
    try testing.expectEqual(@as(f32, -1), copy.world.get(copy.find("nothing turned").?, components.Transform3D).?.position.z);
}

test "a map writes its tiles with itself, and its chunks are not in the scene" {
    const source = try headless();
    defer source.destroy();
    const map = try source.world.spawnWith(.{ Transform2D{}, TileMap{} });
    try source.setName(map, "level");
    _ = try source.setTile(map, -2, 18, tilemap.Cell.at(1, 7, 3).with(tilemap.Cell.flip_h, true));
    _ = try source.setTile(map, 0, 0, .at(0, 1, 1));

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    // Two chunks of tiles, and no entity of their own for either.
    try testing.expect(std.mem.indexOf(u8, text, "\"cells\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"TileChunk\"") == null);
    // A kilobyte of tiles is a line, not a thousand numbers.
    try testing.expect(text.len < 4000);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});

    const loaded = copy.find("level").?;
    const cell = copy.tileAt(loaded, -2, 18);
    try testing.expectEqual(@as(u8, 1), cell.source);
    try testing.expectEqual(@as(u8, 7), cell.x);
    try testing.expectEqual(@as(u8, 3), cell.y);
    try testing.expect(cell.has(tilemap.Cell.flip_h));
    try testing.expect(copy.tileChunkAt(loaded, -1, 1) != null);
    try testing.expectEqual(@as(u8, 1), copy.tileAt(loaded, 0, 0).x);
    try testing.expect(copy.tileAt(loaded, 5, 5).isEmpty());
}

test "a map keeps the tile set it was saved with" {
    const source = try headless();
    defer source.destroy();
    const set = try source.addTileSet("res://terrain.tileset", "{ \"fluxion_tileset\": 1 }");
    const map = try source.world.spawnWith(.{ Transform2D{}, TileMap{ .tile_set = set } });
    try source.setName(map, "level");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "res://terrain.tileset") != null);
}

test "every entity written is given a UUID, and keeps it" {
    const app = try headless();
    defer app.destroy();
    const camera = try app.world.spawnWith(.{Transform2D{}});
    try testing.expect(app.uuidOf(camera) == null);

    const first = try write(app, testing.allocator, .{});
    defer testing.allocator.free(first);
    const given = app.uuidOf(camera).?;
    try testing.expectEqual(@as(u4, 4), given.version());

    const second = try write(app, testing.allocator, .{});
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "one entity is written as a scene writes it, or with every field for an inspector" {
    const app = try headless();
    defer app.destroy();
    const camera = try app.world.spawnWith(.{ Transform2D.at(4, 8), Camera2D{} });
    try app.setName(camera, "camera");
    const child = try app.world.spawnWith(.{ Transform2D.at(0, 2), components.Parent.of(camera) });
    try app.setUuid(camera, fixed_uuids[0]);
    try app.setUuid(child, fixed_uuids[1]);

    const brief = try json.stringify(testing.allocator, EntityJson{ .app = app, .entity = child }, .{});
    defer testing.allocator.free(brief);
    try testing.expectEqualStrings(
        "{\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"parent\":\"00000000-0000-4000-8000-000000000001\",\"Transform2D\":{\"y\":2.0}}",
        brief,
    );

    const doc = try json.Document.init(testing.allocator);
    defer doc.deinit();
    const whole = try doc.from(EntityJson{ .app = app, .entity = camera, .every_field = true });
    try testing.expectEqualStrings("camera", whole.get("name").asString().?);
    try testing.expectEqual(@as(?f32, 1), whole.get("Transform2D").get("scale_x").asFloat(f32));
    try testing.expectEqual(@as(?bool, true), whole.get("Camera2D").get("active").asBool());
}

test "a scene comes back as it went, from JSON and from CBOR" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var png_buf: [160]u8 = undefined;
    const png = try std.fmt.bufPrint(&png_buf, "{s}/hero.png", .{dir});
    try image.png.writeFile(testing.allocator, testing.io, png, .{
        .width = 2,
        .height = 2,
        .pixels = &(.{255} ** 16),
        .row_pitch = 8,
    }, .{ .keep_alpha = true });

    const source = try headless();
    defer source.destroy();
    try source.registerComponents(.{Wander});
    const hero = try source.assets.loadTexture(png, .{ .filter = .linear });
    const typeface = source.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 }) catch FontHandle.none;

    const strip = try source.addGridFrames("hero.frames", hero, 4, 2, &.{.{ .name = "walk", .cells = &.{ 0, 1, 2, 3 }, .speed = 8 }});
    var walking: AnimatedSprite2D = .autoplaying(strip, "walk");
    walking.frame = 2;
    walking.flip_h = true;
    // What the engine keeps while it plays is not saved.
    walking.playing = true;
    walking.frame_count = 4;
    const body = try source.world.spawnWith(.{
        Transform2D.at(10, 20).interpolated(),
        Sprite{ .texture = hero, .tint = .rgba(0.5, 0.25, 1, 0.75), .region = .cell(3, 4, 2), .blend = .additive },
        walking,
    });
    try source.setName(body, "hero");
    _ = try source.world.spawnWith(.{ Transform2D.at(-7, -4), components.Parent.of(body), Sprite.solid(.white, 9, 9) });
    const label = try source.world.spawnWith(.{ Transform2D{ .inherit_rotation = false }, components.Parent.of(body), Text2D{ .font = typeface } });
    try source.setText(label, Text2D, "text", "Zoë ✓");
    _ = try source.world.spawnWith(.{Wander{
        .dx = 0.1,
        .dy = std.math.inf(f32),
        .leader = body,
        .seed = std.math.maxInt(u64),
        .steps = .{ 7, 8, 9 },
        .mood = .curious,
    }});

    // Saved once first, which gives the texture its `.uid` file, so what is
    // written below names it by that as a copy will.
    var first_buf: [160]u8 = undefined;
    try source.saveScene(try std.fmt.bufPrint(&first_buf, "{s}/first.json", .{dir}), .{});
    const expected = try write(source, testing.allocator, .{});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, expected, "\"filter\": \"linear\"") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "\"autoplay\": \"walk\"") != null);
    try testing.expect(std.mem.indexOf(u8, expected, "playing") == null);
    try testing.expect(std.mem.indexOf(u8, expected, "frame_count") == null);
    try testing.expect(std.mem.indexOf(u8, expected, "\"uid\": \"uid://") != null);

    for ([_]json.Format{ .json, .cbor }) |format| {
        var path_buf: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/level.{t}", .{ dir, format });
        try source.saveScene(path, .{ .format = format });

        const copy = try headless();
        defer copy.destroy();
        try copy.registerComponents(.{Wander});
        // Made in code, as the source's were: no file to read them from.
        _ = try copy.addGridFrames("hero.frames", .none, 4, 2, &.{.{ .name = "walk", .cells = &.{ 0, 1, 2, 3 }, .speed = 8 }});
        const loaded = try copy.readScene(path, .{});
        try testing.expectEqual(@as(usize, 4), loaded.entities);
        try testing.expectEqual(@as(usize, 0), loaded.components_unknown);

        const again = try write(copy, testing.allocator, .{});
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(expected, again);

        const leader = copy.find("hero").?;
        const wander = copy.singleton(Wander).?;
        try testing.expect(wander.leader.eql(leader));
        try testing.expectEqual(@as(u64, std.math.maxInt(u64)), wander.seed);
        const sheet = copy.world.get(leader, Sprite).?.texture;
        try testing.expectEqual(rhi.Filter.linear, copy.assets.get(sheet).?.filter);
    }
}

/// A project of a test's own: a directory, a PNG in it, and its path.
const Game = struct {
    tmp: testing.TmpDir,
    buffer: [128]u8 = undefined,
    root: []const u8 = "",

    fn init() !Game {
        var game: Game = .{ .tmp = testing.tmpDir(.{}) };
        try game.tmp.dir.createDirPath(testing.io, "art");
        return game;
    }

    fn at(game: *Game) ![]const u8 {
        game.root = try std.fmt.bufPrint(&game.buffer, ".zig-cache/tmp/{s}", .{game.tmp.sub_path});
        return game.root;
    }

    fn picture(game: *Game, path: []const u8) !void {
        var buffer: [192]u8 = undefined;
        const file = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ game.root, path });
        try image.png.writeFile(testing.allocator, testing.io, file, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});
    }

    fn app(game: *Game) !*App {
        return App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = game.root });
    }
};

test "a project's file is written by its res:// path and its UUID, and found by the UUID when it moves" {
    var game: Game = try .init();
    defer game.tmp.cleanup();
    _ = try game.at();
    try game.picture("art/hero.png");

    const source = try game.app();
    defer source.destroy();
    // By the operating system's path: kept by the project's all the same.
    var buffer: [192]u8 = undefined;
    const hero = try source.assets.loadTexture(try std.fmt.bufPrint(&buffer, "{s}/art/hero.png", .{game.root}), .{});
    _ = try source.world.spawnWith(.{ Transform2D.at(1, 2), Sprite.of(hero) });
    try source.saveScene("res://levels/meadow.json", .{});
    const uid = source.project.knownUid("res://art/hero.png").?;

    var saved_buffer: [2048]u8 = undefined;
    const saved = try game.tmp.dir.readFile(testing.io, "levels/meadow.json", &saved_buffer);
    try testing.expect(std.mem.indexOf(u8, saved, "\"texture\": \"res://art/hero.png\"") != null);
    var line: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, saved, try std.fmt.bufPrint(&line, "\"uid\": \"uid://{f}\"", .{uid})) != null);

    // Moved and renamed, with its `.uid` file.
    try game.tmp.dir.createDirPath(testing.io, "art/people");
    try game.tmp.dir.rename("art/hero.png", game.tmp.dir, "art/people/ada.png", testing.io);
    try game.tmp.dir.rename("art/hero.png.uid", game.tmp.dir, "art/people/ada.png.uid", testing.io);

    const copy = try game.app();
    defer copy.destroy();
    const loaded = try copy.readScene("res://levels/meadow.json", .{});
    try testing.expectEqual(@as(usize, 1), loaded.moved);
    const sheet = copy.singleton(Sprite).?.texture;
    try testing.expectEqualStrings("res://art/people/ada.png", copy.assets.textureSource(sheet).?);
}

test "a version 1 scene is refused, and says so, rather than read another way" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.UnsupportedVersion, read(app,
        \\{ "fluxion_scene": 1, "entities": [
        \\  { "name": "tank" },
        \\  { "parent": 0, "Transform2D": {} }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 1, an older one this engine no longer reads: it reads version 3", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());

    // Nor is an entity named by its place in the list any more.
    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 3, "entities": [{ "name": "tank" }, { "parent": 0, "Transform2D": {} }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected an entity's UUID, or null, found the number 0", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());
}

test "a scene loaded twice gives the second copy UUIDs of its own, and its references stay inside it" {
    const app = try headless();
    defer app.destroy();
    const text =
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "uuid": "11111111-1111-4111-8111-111111111111", "name": "tank", "Transform2D": { "x": 1 } },
        \\  { "uuid": "22222222-2222-4222-8222-222222222222", "parent": "11111111-1111-4111-8111-111111111111", "Transform2D": {} }
        \\] }
    ;
    const tank_uuid: Uuid = .parseComptime("11111111-1111-4111-8111-111111111111");
    try testing.expectEqual(@as(usize, 0), (try read(app, text, .{})).reassigned);
    const tank = app.findUuid(tank_uuid).?;
    try testing.expect(tank.eql(app.find("tank").?));

    app.clearWorld();
    try testing.expect(app.findUuid(tank_uuid) == null);
    try testing.expectEqual(@as(usize, 0), (try read(app, text, .{})).reassigned);
    const again = app.findUuid(tank_uuid).?;

    // The same scene beside it: new UUIDs, a child of its own tank, and the
    // next free name among the roots.
    try testing.expectEqual(@as(usize, 2), (try read(app, text, .{})).reassigned);
    try testing.expect(app.findUuid(tank_uuid).?.eql(again));
    try testing.expect(app.find("tank").?.eql(again));
    const second_tank = app.find("tank 2").?;
    try testing.expect(!app.uuidOf(second_tank).?.eql(tank_uuid));

    var parents: [2]Entity = undefined;
    var count: usize = 0;
    var it = try ecs.Query(.{components.Parent}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(components.Parent)) |held| {
            parents[count] = held.entity;
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(parents[0].eql(again) != parents[1].eql(again));
    try testing.expect(parents[0].eql(second_tank) or parents[1].eql(second_tank));
}

test "an entity another scene brought is found by its UUID" {
    const app = try headless();
    defer app.destroy();
    const door = try app.world.spawnWith(.{Transform2D.at(3, 4)});
    try app.setUuid(door, fixed_uuids[2]);
    _ = try read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "name": "handle", "parent": "00000000-0000-4000-8000-000000000003", "Transform2D": {} }
        \\] }
    , .{});
    try testing.expect(app.parentOf(app.find("handle").?).eql(door));
}

test "parents, names and groups go through a scene and back" {
    const app = try headless();
    defer app.destroy();
    const tank = try app.world.spawnWith(.{Transform2D.at(1, 2)});
    try app.setName(tank, "tank");
    try app.addToGroup(tank, "vehicles");
    const turret = try app.world.spawnWith(.{ Transform2D.at(0, -6), components.Parent.of(tank) });
    try app.setName(turret, "turret");
    try app.addToGroup(turret, "guns");
    try app.addToGroup(turret, "vehicles");
    // A timer hangs in the tree with no transform of its own.
    const reload = try app.world.spawnWith(.{ @import("../time/timer.zig").Timer{}, components.Parent.of(turret) });
    try app.setName(reload, "reload");

    const saved = try write(app, testing.allocator, .{});
    defer testing.allocator.free(saved);
    app.clearWorld();
    _ = try read(app, saved, .{});

    const back = app.find("tank").?;
    try testing.expect(app.findPath(back, "turret/reload") != null);
    const gun = app.findPath(back, "turret").?;
    try testing.expect(app.parentOf(gun).eql(back));
    try testing.expect(app.isInGroup(gun, "guns"));
    try testing.expect(app.isInGroup(gun, "vehicles"));
    try testing.expect(app.isInGroup(back, "vehicles"));
    try testing.expect(!app.isInGroup(back, "guns"));
}

test "a UUID given twice, or naming nothing, is a mistake that says where it is" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.DuplicateUuid, read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "uuid": "11111111-1111-4111-8111-111111111111" },
        \\  { "uuid": "11111111-1111-4111-8111-111111111111" }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("another entity in this scene has this UUID already", diagnostics.message());
    try testing.expectEqualStrings("/entities/1/uuid", diagnostics.path());

    try testing.expectError(error.NoSuchEntity, read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "parent": "44444444-4444-4444-8444-444444444444", "Transform2D": {} }
        \\] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("no entity in this scene or in the world has the UUID 44444444-4444-4444-8444-444444444444", diagnostics.message());
    try testing.expectEqualStrings("/entities/0/parent", diagnostics.path());

    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 3, "entities": [{ "uuid": "tank" }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("\"tank\" is not a UUID", diagnostics.message());
    try testing.expectEqual(@as(usize, 0), app.world.count());
}

test "a component nothing here knows is kept, a field or a member nothing knows is passed over, and what a scene lacks is the default" {
    const app = try headless();
    defer app.destroy();
    const loaded = try read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "name": "odd", "Transform2D": { "x": 5, "wobble": 3 }, "Mystery": { "a": [1, 2] } },
        \\  { "name": "empty" }
        \\], "future": true }
    , .{});
    try testing.expectEqual(@as(usize, 2), loaded.entities);
    try testing.expectEqual(@as(usize, 1), loaded.components_unknown);
    const kept = app.unknownComponentsOf(app.find("odd").?);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("Mystery", kept[0].name);
    try testing.expectEqualStrings("{\"a\":[1,2]}", kept[0].value);
    try testing.expectEqual(@as(usize, 0), app.unknownComponentsOf(app.find("empty").?).len);

    const place = app.singleton(Transform2D).?;
    try testing.expectEqual(@as(f32, 5), place.x);
    try testing.expectEqual(@as(f32, 1), place.scale_x);
    try testing.expect(app.parentOf(app.find("odd").?).isNone());
    try testing.expect(app.find("empty") != null);
}

/// A game's component that an editor meets only later, if at all.
const Later = extern struct {
    n: i32 = 0,

    pub const scene_name = "Later";
};

test "a component nothing here knows is written back as it was read, from JSON and from CBOR" {
    const app = try headless();
    defer app.destroy();
    const loaded = try read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "name": "odd", "Mystery": { "big": 18446744073709551615, "half": -0.5, "odd": NaN,
        \\      "text": "a \"quoted\"\nline ✓", "list": [true, false, null, { "deep": [[]] }] },
        \\    "Transform2D": { "x": 5 }, "Later": 7 },
        \\  { "name": "plain", "Transform2D": {} }
        \\] }
    , .{});
    try testing.expectEqual(@as(usize, 2), loaded.components_unknown);
    const odd = app.find("odd").?;
    const mystery = "{\"big\":18446744073709551615,\"half\":-0.5,\"odd\":NaN,\"text\":\"a \\\"quoted\\\"\\nline ✓\",\"list\":[true,false,null,{\"deep\":[[]]}]}";
    const kept = app.unknownComponentsOf(odd);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("Mystery", kept[0].name);
    try testing.expectEqualStrings(mystery, kept[0].value);
    try testing.expectEqualStrings("Later", kept[1].name);
    try testing.expectEqualStrings("7", kept[1].value);

    // Written after the registered ones, in the order read.
    const text = try write(app, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"Transform2D\":{\"x\":5.0},\"Mystery\":" ++ mystery ++ ",\"Later\":7}") != null);
    const one = try json.stringify(testing.allocator, EntityJson{ .app = app, .entity = odd }, .{});
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "\"Later\":7") != null);

    // Through CBOR and back, every digit and every character stays.
    const bytes = try write(app, testing.allocator, .{ .format = .cbor });
    defer testing.allocator.free(bytes);
    const again = try headless();
    defer again.destroy();
    _ = try read(again, bytes, .{});
    const round = again.unknownComponentsOf(again.find("odd").?);
    try testing.expectEqual(@as(usize, 2), round.len);
    try testing.expectEqualStrings(mystery, round[0].value);
    try testing.expectEqualStrings("7", round[1].value);
    const text_again = try write(again, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(text_again);
    try testing.expectEqualStrings(text, text_again);

    // Once the game's component is here and on the entity, it is what the
    // entity holds, and what is written.
    try app.registerComponents(.{Later});
    _ = try app.addComponentNamed(odd, "Later");
    const known = try write(app, testing.allocator, .{ .indent = 0 });
    defer testing.allocator.free(known);
    try testing.expect(std.mem.indexOf(u8, known, "\"Later\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, known, "\"Later\":7") == null);

    // Taken off by name, and forgotten with the entity or the world.
    try app.removeComponentNamed(odd, "Mystery");
    try testing.expectEqual(@as(usize, 1), app.unknownComponentsOf(odd).len);
    try testing.expectError(error.NoSuchComponent, app.removeComponentNamed(odd, "Mystery"));
    const plain = again.find("plain").?;
    try testing.expectError(error.NoSuchComponent, again.removeComponentNamed(plain, "Mystery"));
    app.world.despawn(odd);
    try testing.expectEqual(@as(usize, 0), app.unknownComponentsOf(odd).len);
    try testing.expectError(error.NoSuchEntity, app.removeComponentNamed(odd, "Later2"));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.unknown_components.by_entity.count());
    _ = try again.step();
    try testing.expectEqual(@as(usize, 1), again.unknown_components.by_entity.count());
    again.clearWorld();
    try testing.expectEqual(@as(usize, 0), again.unknown_components.by_entity.count());
}

test "a mistake in a scene says where it is, and leaves the world as it was" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{Transform2D.at(1, 1)});

    const text =
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "name": "first", "Transform2D": { "x": 5 } },
        \\  { "parent": "77777777-7777-4777-8777-777777777777", "Transform2D": {} }
        \\] }
    ;
    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.NoSuchEntity, read(app, text, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("no entity in this scene or in the world has the UUID 77777777-7777-4777-8777-777777777777", diagnostics.message());
    try testing.expectEqualStrings("/entities/1/parent", diagnostics.path());
    try testing.expectEqual(@as(u32, 3), diagnostics.line);
    try testing.expectEqual(@as(u32, 15), diagnostics.column);
    try testing.expectEqual(@as(usize, 1), app.world.count());
    try testing.expect(app.find("first") == null);

    // The same mistake in CBOR is at a byte.
    const binary = try json.reformat(testing.allocator, text, .{}, .{ .format = .cbor });
    defer testing.allocator.free(binary);
    try testing.expectError(error.NoSuchEntity, read(app, binary, .{ .diagnostics = &diagnostics }));
    try testing.expect(diagnostics.binary);
    try testing.expectEqualStrings("/entities/1/parent", diagnostics.path());

    try testing.expectError(error.WrongType, read(app,
        \\{ "fluxion_scene": 3, "entities": [{ "Sprite": { "width": "wide" } }] }
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a number, found the string \"wide\"", diagnostics.message());
    try testing.expectEqualStrings("/entities/0/Sprite/width", diagnostics.path());
    try testing.expectEqual(@as(usize, 1), app.world.count());
}

test "numbers no hand would give load, and the frames after them do not crash" {
    // The colliders that get no shape are said so in warnings, which are the
    // point and need not fill the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    const app = try headless();
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 }) catch {};
    _ = try app.addGridFrames("strip.frames", .none, 4, 1, &.{.{ .name = "walk", .cells = &.{ 0, 1, 2, 3 }, .speed = 4 }});
    const loaded = try read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "Transform2D": { "x": NaN, "y": Infinity, "scale_x": 0 }, "Sprite": { "width": NaN },
        \\    "AnimatedSprite2D": { "speed_scale": 1e39, "frame_progress": NaN, "sprite_frames": "strip.frames", "autoplay": "walk" } },
        \\  { "Transform2D": {}, "Sprite": {}, "AnimatedSprite2D": { "speed_scale": -1e39, "frame_progress": Infinity, "frame": -7, "sprite_frames": "strip.frames", "autoplay": "walk" } },
        \\  { "Transform2D": { "x": 1 }, "Camera2D": { "zoom": 0, "fit_width": NaN, "fit_height": Infinity } },
        \\  { "Transform2D": { "rotation": NaN }, "RigidBody2D": { "velocity": { "x": NaN, "y": 1 } },
        \\    "Collider2D": { "shape": "circle", "radius": -1 } },
        \\  { "Transform2D": {}, "RigidBody2D": { "gravity_scale": NaN },
        \\    "Collider2D": { "width": 10, "height": 10, "rotation": NaN } },
        \\  { "Transform2D": {}, "RigidBody2D": {}, "Collider2D": { "shape": "circle", "radius": -1, "offset_x": Infinity } },
        \\  { "Transform2D": { "x": Infinity }, "Collider2D": { "width": 4, "height": 4 } },
        \\  { "Transform2D": { "x": 5 }, "Text2D": { "text": "Hi", "size": 1e30, "line_spacing": NaN } },
        \\  { "Transform2D": { "x": 5 }, "Text2D": { "text": "Hi", "size": NaN } },
        \\  { "Transform2D": { "y": 50 },
        \\    "RigidBody2D": { "velocity": { "x": NaN, "y": Infinity }, "angular_velocity": NaN, "linear_damping": NaN, "gravity_scale": Infinity },
        \\    "Collider2D": { "width": 4, "height": 4, "density": NaN, "friction": NaN, "restitution": NaN } },
        \\  { "Transform2D": { "y": 51 }, "RigidBody2D": { "type": "static" }, "Collider2D": { "width": 40, "height": 4, "density": -1 } }
        \\] }
    , .{});
    try testing.expectEqual(@as(usize, 11), loaded.entities);

    // Words that are not UTF-8 never reach a label: a lone surrogate written
    // as an escape is read as U+FFFD, and a byte no UTF-8 has is a mistake.
    _ = try read(app,
        \\{ "fluxion_scene": 3, "entities": [{ "name": "surrogate", "Transform2D": {}, "Text2D": { "text": "a\uD800b" } }] }
    , .{});
    try testing.expectEqualStrings("a\u{FFFD}b", app.textOf(app.find("surrogate").?, Text2D, "text"));
    try testing.expectError(error.SyntaxError, read(app, "{ \"fluxion_scene\": 3, \"entities\": [{ \"Text2D\": { \"text\": \"a\xffb\" } }] }", .{}));

    // And a label's words set from code that are not UTF-8 are not drawn,
    // and are saved without falling over.
    const broken = try app.world.spawnWith(.{ Transform2D{}, Text2D{} });
    try app.setText(broken, Text2D, "text", &.{ 0xFF, 'o', 'k' });
    const saved = try write(app, testing.allocator, .{});
    testing.allocator.free(saved);

    // Edited, and paused: bodies are made at the top of every frame.
    app.time.scale = 0;
    for (0..3) |_| _ = try app.step();
    // Played.
    app.time.scale = 1;
    for (0..5) |_| _ = try app.step();
}

test "a file that is not a scene, or a newer one, is refused" {
    const app = try headless();
    defer app.destroy();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.NotAScene, read(app, "{ \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this is not a scene: it has no \"fluxion_scene\" version", diagnostics.message());

    try testing.expectError(error.UnsupportedVersion, read(app, "{ \"fluxion_scene\": 4, \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 4, newer than this engine, which reads version 3", diagnostics.message());

    try testing.expectError(error.UnsupportedVersion, read(app, "{ \"fluxion_scene\": 2, \"entities\": [] }", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("this scene is version 2, an older one this engine no longer reads: it reads version 3", diagnostics.message());

    try testing.expectError(error.WrongType, read(app, "[1, 2]", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("expected a scene, which is an object, found a list", diagnostics.message());
}

test "a scene says what it is and which files it names, without being loaded" {
    const text =
        \\{
        \\  // By hand, with what nothing here knows beside what it does.
        \\  "fluxion_scene": 3,
        \\  "made_by": { "tool": "an editor", "entities": [1, 2, 3] },
        \\  "entities": [
        \\    { "uuid": "00000000-0000-4000-8000-000000000001", "Sprite": { "texture": "res://art/hero.png" } },
        \\    { "Sprite": { "texture": "res://art/tree.png" } }
        \\  ],
        \\  "assets": {
        \\    "res://art/hero.png": { "uid": "uid://2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34", "filter": "linear" },
        \\    "res://art/tree.png": { "wrap": "repeat" },
        \\    "res://art/odd.png": { "uid": "not a uuid" }
        \\  }
        \\}
    ;
    var said = (try readInfo(testing.allocator, text, null)).?;
    defer said.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), said.version);
    try testing.expectEqual(json.Format.json, said.format);
    try testing.expectEqual(@as(usize, 2), said.entities);
    try testing.expectEqual(@as(usize, 3), said.files.len);
    try testing.expectEqualStrings("res://art/hero.png", said.files[0].path);
    try testing.expect(said.files[0].uid.?.eql(.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34")));
    try testing.expectEqualStrings("res://art/tree.png", said.files[1].path);
    try testing.expect(said.files[1].uid == null);
    try testing.expect(said.files[2].uid == null);
}

test "a scene in CBOR, or of another version, is told as it is" {
    const app = try headless();
    defer app.destroy();
    for (0..3) |_| _ = try app.world.spawnWith(.{Transform2D.at(1, 2)});
    const bytes = try write(app, testing.allocator, .{ .format = .cbor });
    defer testing.allocator.free(bytes);

    var binary = (try readInfo(testing.allocator, bytes, null)).?;
    defer binary.deinit(testing.allocator);
    try testing.expectEqual(json.Format.cbor, binary.format);
    try testing.expectEqual(@as(usize, 3), binary.entities);
    try testing.expectEqual(@as(u32, version), binary.version);

    // Refused by `read`, and told here, so a tool can say which it is.
    var old = (try readInfo(testing.allocator, "{ \"fluxion_scene\": 1, \"entities\": [{}, {}] }", null)).?;
    defer old.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), old.version);
    try testing.expectEqual(@as(usize, 2), old.entities);
}

test "what is not a scene is null, and a scene damaged past its version is a mistake that says where" {
    const gpa = testing.allocator;
    try testing.expect(try readInfo(gpa, "", null) == null);
    try testing.expect(try readInfo(gpa, "not JSON at all", null) == null);
    try testing.expect(try readInfo(gpa, "[1, 2]", null) == null);
    try testing.expect(try readInfo(gpa, "{ \"entities\": [] }", null) == null);
    try testing.expect(try readInfo(gpa, "{ \"fluxion_scene\": \"two\" }", null) == null);
    // Broken before it said it was a scene: as far as can be told, it is not.
    try testing.expect(try readInfo(gpa, "{ \"entities\": [ { , ], \"fluxion_scene\": 2 }", null) == null);

    var diagnostics: json.Diagnostics = .{};
    try testing.expectError(error.SyntaxError, readInfo(gpa, "{ \"fluxion_scene\": 2, \"entities\": [{}, ", &diagnostics));
    try testing.expectError(error.SyntaxError, readInfo(gpa, "{ \"fluxion_scene\": 2, \"assets\": { \"res://a.png\": { \"uid\": ", null));
    try testing.expect(diagnostics.message().len > 0);
}

test "an empty scene is a scene, with nothing in it, in either format" {
    const app = try headless();
    defer app.destroy();
    for ([_]json.Format{ .json, .cbor }) |format| {
        const bytes = try writeEmpty(testing.allocator, .{ .format = format });
        defer testing.allocator.free(bytes);

        var said = (try readInfo(testing.allocator, bytes, null)).?;
        defer said.deinit(testing.allocator);
        try testing.expectEqual(format, said.format);
        try testing.expectEqual(@as(usize, 0), said.entities);

        const loaded = try read(app, bytes, .{});
        try testing.expectEqual(@as(usize, 0), loaded.entities);
        // An empty list rather than none, for a person reading it.
        if (format == .json) try testing.expect(std.mem.indexOf(u8, bytes, "\"entities\": []") != null);
    }
    try testing.expectEqual(@as(usize, 0), app.world.count());
}

/// Two components called the same, in two places.
const Twins = struct {
    const First = struct {
        const Marker = extern struct { v: u8 = 0 };
    };
    const Second = struct {
        const Marker = extern struct { w: u8 = 0 };
    };
    const Renamed = extern struct {
        w: u8 = 0,
        pub const scene_name = "OtherMarker";
    };
    const Described = extern struct {
        w: u8 = 0,
        pub const reflect_name = "DescribedMarker";
    };
    const Both = extern struct {
        w: u8 = 0,
        pub const reflect_name = "DescribedMarker";
        pub const scene_name = "WrittenMarker";
    };
};

test "a component's scene name is its scene_name, then its reflect_name, then its own" {
    try testing.expectEqualStrings("Marker", nameOf(Twins.First.Marker));
    try testing.expectEqualStrings("OtherMarker", nameOf(Twins.Renamed));
    try testing.expectEqualStrings("DescribedMarker", nameOf(Twins.Described));
    try testing.expectEqualStrings("WrittenMarker", nameOf(Twins.Both));
}

test "two components of one name need a scene_name to tell them apart" {
    const app = try headless();
    defer app.destroy();
    try app.registerComponents(.{Twins.First.Marker});
    try app.registerComponents(.{Twins.First.Marker});
    try testing.expectError(error.ComponentNameTaken, app.registerComponents(.{Twins.Second.Marker}));
    try app.registerComponents(.{Twins.Renamed});
    try testing.expect(app.scene_components.find("Marker") != null);
    try testing.expect(app.scene_components.find("OtherMarker") != null);

    // Two scene names and one reflect_name: the descriptions would clash, and
    // the second is refused before a scene can hold it.
    try app.registerComponents(.{Twins.Described});
    try testing.expectError(error.ComponentNameTaken, app.registerComponents(.{Twins.Both}));
    try testing.expect(app.scene_components.find("WrittenMarker") == null);
}

/// A TrueType collection the system has, by its path, or null. See
/// `Assets`' tests.
fn systemCollection() ?[]const u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/YuGothM.ttc",
        "C:/Windows/Fonts/cambria.ttc",
        "C:/Windows/Fonts/msgothic.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(testing.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

test "a font of a collection is written as its file and member, and read back as that font" {
    const path = systemCollection() orelse return error.SkipZigTest;
    const source = try headless();
    defer source.destroy();
    const first = try source.assets.loadFont(path, .{ .atlas = 64 });
    const second = try source.assets.loadFont(path, .{ .atlas = 64, .member = 1 });

    const upright = try source.world.spawnWith(.{ Transform2D{}, Text2D{ .font = first } });
    try source.setName(upright, "first");
    try source.setText(upright, Text2D, "text", "a");
    const other = try source.world.spawnWith(.{ Transform2D{}, Text2D{ .font = second } });
    try source.setName(other, "second");
    try source.setText(other, Text2D, "text", "b");

    const text = try write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"member\": 1") != null);

    const copy = try headless();
    defer copy.destroy();
    _ = try read(copy, text, .{});
    const a = copy.world.get(copy.find("first").?, Text2D).?.font;
    const b = copy.world.get(copy.find("second").?, Text2D).?.font;
    try testing.expectEqual(@as(u32, 0), copy.assets.fontMember(a));
    try testing.expectEqual(@as(u32, 1), copy.assets.fontMember(b));
    try testing.expect(!std.meta.eql(a, b));

    // Written again, it is what was read.
    const again = try write(copy, testing.allocator, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);

    // An object with no file is a mistake that says so, not a crash.
    try testing.expectError(error.WrongType, read(copy,
        \\{ "fluxion_scene": 3, "entities": [{ "Transform2D": {}, "Text2D": { "font": { "member": 1 } } }] }
    , .{}));
}
