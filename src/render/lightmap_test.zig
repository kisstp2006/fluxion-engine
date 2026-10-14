// SPDX-License-Identifier: BSD-3-Clause

//! A world's light baked and read back: `App.bakeLightmap`, the `.lightmap`
//! it writes, and the 3D layer reading it.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const components3d = @import("render3d_components.zig");
const MeshInstance3D = components3d.MeshInstance3D;
const PrimitiveMesh3D = components3d.PrimitiveMesh3D;
const PointLight3D = components3d.PointLight3D;
const LightmapGI = components3d.LightmapGI;
const Camera3D = components3d.Camera3D;

/// A project in a folder of its own, deleted after.
const Folder = struct {
    tmp: testing.TmpDir,
    buffer: [160]u8 = undefined,

    fn root(self: *Folder) []const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}", .{self.tmp.sub_path}) catch unreachable;
    }

    fn init(folder: *Folder) !void {
        folder.* = .{ .tmp = testing.tmpDir(.{}) };
        try Project.writeSettings(testing.allocator, testing.io, folder.root(), .{ .application = .{ .name = "Baked" } });
    }

    fn deinit(self: *Folder) void {
        self.tmp.cleanup();
    }
};

/// A closed room six across: a thin box for each wall, round the origin.
fn room(app: *App) !void {
    const walls = [_][2][3]f32{
        .{ .{ 0, -3, 0 }, .{ 6, 0.2, 6 } }, .{ .{ 0, 3, 0 }, .{ 6, 0.2, 6 } },
        .{ .{ -3, 0, 0 }, .{ 0.2, 6, 6 } }, .{ .{ 3, 0, 0 }, .{ 0.2, 6, 6 } },
        .{ .{ 0, 0, -3 }, .{ 6, 6, 0.2 } }, .{ .{ 0, 0, 3 }, .{ 6, 6, 0.2 } },
    };
    for (walls) |wall| {
        _ = try app.world.spawnWith(.{
            Transform3D.at(wall[0][0], wall[0][1], wall[0][2]),
            MeshInstance3D{},
            PrimitiveMesh3D{ .shape = .box, .size = .init(wall[1][0], wall[1][1], wall[1][2]) },
        });
    }
}

test "a room baked: its walls read the lightmap, a ball that moves the probes, and a light baked whole is drawn no more" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = folder.root(), .width = 64, .height = 64 });
    defer app.destroy();

    try room(app);
    const lamp = try app.world.spawnWith(.{ Transform3D.at(0, 2, 0), PointLight3D{ .range = 10, .energy = 2, .bake = .all } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -1, 0), MeshInstance3D{ .gi_mode = .dynamic }, PrimitiveMesh3D{ .shape = .sphere } });
    var eye: Transform3D = .at(0, 0, 2.5);
    eye.lookAt(.init(0, -1, 0), .unit_y);
    _ = try app.world.spawnWith(.{ eye, Camera3D{} });
    const gi = try app.world.spawnWith(.{LightmapGI{ .texels_per_unit = 2, .quality = .low, .bounces = 2, .probe_spacing = 2 }});

    // Not baked yet: lit as without one.
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.lamps_kept);
    try testing.expectEqual(@as(u32, 0), app.renderer3d.gi_lightmapped);

    const bake = try app.bakeLightmap(gi, "res://room.lightmap");
    try testing.expectEqual(@as(usize, 0), bake.notes.items.len);
    const baked = try bake.finish(app);
    try testing.expect(app.world.get(gi, LightmapGI).?.data.eql(baked));
    const lightmap = app.lightmapOf(baked).?;
    // The six walls in it, and probes all through the room.
    try testing.expectEqual(@as(usize, 6), lightmap.places.len);
    try testing.expect(lightmap.probes.samples.len > 8);
    try testing.expectEqualStrings("res://room.lightmap", app.assetSource(baked).?);

    _ = try app.step();
    // The walls the camera sees from the lightmap, the ball from the probes,
    // and the lamp's light only from what was baked.
    try testing.expect(app.renderer3d.gi_lightmapped >= 3);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.gi_probed);
    try testing.expectEqual(@as(u32, 0), app.renderer3d.lamps_kept);
    // The probe under the lamp is lit from above more than from below.
    const under = lightmap.probeLight(.{ 0, -1, 0 }).?;
    try testing.expect(under[0] > 0);
    try testing.expect(under[2] > 0);

    // A lamp baked only for its bounces is drawn as well.
    app.world.get(lamp, PointLight3D).?.bake = .indirect;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.lamps_kept);

    // Read from its file again, the same.
    app.unloadLightmap(baked);
    const again = try app.loadLightmap("res://room.lightmap");
    try testing.expectEqual(@as(usize, 6), app.lightmapOf(again).?.places.len);
}

test "a bake cancelled keeps nothing, and the LightmapGI is as it was" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = folder.root(), .width = 64, .height = 64 });
    defer app.destroy();
    try room(app);
    const gi = try app.world.spawnWith(.{LightmapGI{ .texels_per_unit = 16, .quality = .ultra }});
    const bake = try app.bakeLightmap(gi, "res://room.lightmap");
    bake.cancel();
    try testing.expectError(error.Cancelled, bake.finish(app));
    try testing.expect(app.world.get(gi, LightmapGI).?.data.isNone());
    try testing.expect(app.findLightmap("res://room.lightmap") == null);
}

test "a mesh with no lightmap UVs is said, and lit by the probes" {
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = folder.root(), .width = 64, .height = 64 });
    defer app.destroy();
    const fx_mesh = @import("mesh.zig");
    const tri = [_]fx_mesh.Vertex{
        .{ .position = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 } },
        .{ .position = .{ 1, 0, 0 }, .normal = .{ 0, 0, 1 } },
        .{ .position = .{ 0, 1, 0 }, .normal = .{ 0, 0, 1 } },
    };
    const made = try app.addMesh("tri", try fx_mesh.Mesh.init(testing.allocator, &tri, &.{ 0, 1, 2 }));
    const holder = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), MeshInstance3D{ .mesh = made } });
    try app.setName(holder, "Sign");
    const gi = try app.world.spawnWith(.{LightmapGI{ .quality = .low }});
    const bake = try app.bakeLightmap(gi, "res://sign.lightmap");
    try testing.expectEqual(@as(usize, 1), bake.notes.items.len);
    try testing.expect(std.mem.startsWith(u8, bake.notes.items[0], "Sign: its mesh has no lightmap UVs"));
    const baked = try bake.finish(app);
    try testing.expectEqual(@as(usize, 0), app.lightmapOf(baked).?.places.len);
}

test "a sun whose shadow is baked: the still walls take it from the lightmap, what moves from the probes, and only what moves casts it live" {
    const lightmaps = @import("lightmaps.zig");
    const DirectionalLight3D = components3d.DirectionalLight3D;
    const shadows3d = @import("shadows3d.zig");
    var folder: Folder = undefined;
    try folder.init();
    defer folder.deinit();
    const gpa = testing.allocator;
    const app = try App.create(gpa, .{ .headless = true, .io = testing.io, .root = folder.root(), .width = 64, .height = 64 });
    defer app.destroy();

    try room(app);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -1, 0), MeshInstance3D{ .gi_mode = .dynamic }, PrimitiveMesh3D{ .shape = .sphere } });
    var eye: Transform3D = .at(0, 0, 2.5);
    eye.lookAt(.init(0, -1, 0), .unit_y);
    _ = try app.world.spawnWith(.{ eye, Camera3D{} });
    var high: Transform3D = .at(0, 10, 0);
    high.lookAt(.init(1, 0, 0.5), .unit_y);
    const sun = try app.world.spawnWith(.{ high, DirectionalLight3D{ .shadow = true, .bake = .shadows, .shadow_cascades = .two } });
    const gi = try app.world.spawnWith(.{LightmapGI{ .texels_per_unit = 2, .quality = .low, .bounces = 1, .probe_spacing = 2 }});
    const bake = try app.bakeLightmap(gi, "res://room.lightmap");
    const baked = try bake.finish(app);

    // The engine's bake holds no shadow of the sun: drawn as `indirect`,
    // every wall casting live.
    _ = try app.step();
    try testing.expect(!app.renderer3d.sun_baked);
    const every = app.renderer3d.shadow_casters;
    try testing.expect(every > 0);

    // The same lightmap with the sun's shadow in it, as a game's tools write
    // one: the walls' picture lit, the probes' hidden.
    // (Drawn once, its picture is on the device and gone from it: read again.)
    app.unloadLightmap(baked);
    const reread = try app.loadLightmap("res://room.lightmap");
    var made = app.lightmapOf(reread).?.*;
    const lit = try gpa.alloc(u8, @as(usize, made.width) * made.height);
    defer gpa.free(lit);
    @memset(lit, 255);
    const hidden = try gpa.alloc(u8, made.probes.valid.len);
    defer gpa.free(hidden);
    @memset(hidden, 0);
    made.sun = lit;
    made.probes.sun = hidden;
    const bytes = try lightmaps.write(gpa, made);
    defer gpa.free(bytes);
    var path: [192]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&path, "{s}/sunlit.lightmap", .{folder.root()}), .data = bytes });
    app.world.get(gi, LightmapGI).?.data = try app.loadLightmap("res://sunlit.lightmap");
    app.unloadLightmap(reread);

    _ = try app.step();
    try testing.expect(app.renderer3d.sun_baked);
    try testing.expectEqual(@as(f32, 1), app.renderer3d.probe_data.energy[2]);
    // The ball takes the probes' shadow - hidden here - and is all the sun's
    // live shadow draws: no wall casts into its views.
    var probed = false;
    for (app.renderer3d.gathered.items) |instance| if (instance.gi[0] < 0) {
        probed = true;
        try testing.expectEqual(@as(f32, 0), instance.gi[1]);
    };
    try testing.expect(probed);
    for (app.renderer3d.shadow_items.items) |shadowed| {
        const view = app.renderer3d.plan.views.items[shadowed.view];
        if (view.key.light != shadows3d.sunKey(0)) continue;
        try testing.expect(app.renderer3d.gathered.items[shadowed.item.instance].gi[0] <= 0);
    }
    try testing.expect(app.renderer3d.shadow_casters < every);

    // Its shadow drawn live again: every wall casts, and the probes' shadow is not read.
    app.world.get(sun, DirectionalLight3D).?.bake = .indirect;
    _ = try app.step();
    try testing.expect(!app.renderer3d.sun_baked);
    try testing.expectEqual(@as(f32, 0), app.renderer3d.probe_data.energy[2]);
    try testing.expectEqual(every, app.renderer3d.shadow_casters);
}
