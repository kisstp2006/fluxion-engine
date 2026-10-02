// SPDX-License-Identifier: BSD-3-Clause

//! A plugin in a project: found, its singleton opened before the project's
//! own autoloads, its settings read from the project file and the secrets.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const plugins = @import("plugins.zig");
const flux = @import("fluxion_script");

const files = [_]struct { []const u8, []const u8 }{
    .{
        "project.fluxion",
        \\{
        \\  "fluxion_project": 2,
        \\  "application": { "name": "Plugged", "autoload": ["res://main.flux"] },
        \\  "plugins": { "enabled": ["gamejolt", "off_plugin"] },
        \\  "game_jolt": { "game_id": 42 }
        \\}
    },
    .{
        "addons/gamejolt/plugin.fluxion",
        \\{
        \\  "fluxion_plugin": 1,
        \\  "name": "Game Jolt API",
        \\  "version": "1.0.0",
        \\  "editor": "editor.flux",
        \\  "autoload": [{ "name": "GameJolt", "path": "game_jolt.flux" }],
        \\  "settings": { "section": "game_jolt", "label": "Game Jolt", "script": "settings.flux" },
        \\  "some_newer_key": true
        \\}
    },
    .{
        "addons/gamejolt/settings.flux",
        \\struct Settings {
        \\    @export var game_id: int = 0;
        \\    @export @secret var private_key: string = "";
        \\}
    },
    .{
        "addons/gamejolt/game_jolt.flux",
        \\var id = 0;
        \\var key = "";
        \\struct GameJolt {
        \\    fn ready(self) {
        \\        const s = app.pluginSettings("game_jolt") catch return;
        \\        id = s.game_id;
        \\        key = s.private_key;
        \\    }
        \\}
    },
    .{
        "main.flux",
        \\var saw_it = false;
        \\struct Main {
        \\    fn ready(self) {
        \\        saw_it = app.find("GameJolt") != null;
        \\    }
        \\}
    },
    .{ ".fluxion/secrets.json", "{ \"game_jolt\": { \"private_key\": \"abc\" } }" },
    .{ "addons/off_plugin/plugin.fluxion", "{ \"fluxion_plugin\": 1, \"requires\": [{ \"plugin\": \"nothing\" }], \"autoload\": [{ \"name\": \"Off\", \"path\": \"off.flux\" }] }" },
    .{ "addons/broken/plugin.fluxion", "{ not json" },
    .{ "addons/no_manifest/readme.txt", "just a folder" },
};

test "a plugin's singleton opens before the project's autoloads, and reads its settings and secrets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |parent| try tmp.dir.createDirPath(testing.io, parent);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(testing.io, &root)];

    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = path, .open_project = true });
    defer app.destroy();
    try app.useScripts(.{});

    var found = try plugins.discover(app, testing.allocator);
    defer found.deinit();
    try testing.expectEqual(@as(usize, 3), found.plugins.len);
    try testing.expect(found.named("broken").?.problem != null);
    try testing.expectEqualStrings("Game Jolt API", found.named("gamejolt").?.label());
    try testing.expect(found.named("no_manifest") == null);

    try app.startup();
    _ = try app.step();
    try testing.expect(app.find("GameJolt") != null);
    // Turned on, it needs what is not there: it does not start.
    try testing.expect(app.find("Off") == null);

    const scripts = app.scripts.?;
    const jolt = scripts.moduleOf(scripts.find("res://addons/gamejolt/game_jolt.flux").?).?;
    try testing.expectEqual(@as(i64, 42), scripts.vm.get(jolt, "id").?.asInt());
    try testing.expectEqualStrings("abc", scripts.vm.get(jolt, "key").?.as(flux.object.String).bytes());
    const main = scripts.moduleOf(scripts.find("res://main.flux").?).?;
    try testing.expect(scripts.vm.get(main, "saw_it").?.asBool());
}
