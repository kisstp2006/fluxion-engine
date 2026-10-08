// SPDX-License-Identifier: BSD-3-Clause

//! The 3D layer through a whole app, headless: what a camera sees drawn,
//! what it does not left out, meshes of one kind drawn together, a render
//! view's own camera, meshes made in code and by their numbers, what casts
//! a shadow, and the components through a scene.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const mesh = @import("mesh.zig");
const scene = @import("../scene/scene.zig");

const Transform3D = components.Transform3D;
const MeshInstance3D = components.MeshInstance3D;
const PrimitiveMesh3D = components.PrimitiveMesh3D;
const Material3D = components.Material3D;
const Camera3D = components.Camera3D;
const DirectionalLight3D = components.DirectionalLight3D;
const PointLight3D = components.PointLight3D;
const SpotLight3D = components.SpotLight3D;
const Environment = components.Environment;
const RenderView = components.RenderView;
const renderer3d = @import("renderer3d.zig");
const helpers = @import("../test_helpers.zig");
const Assets = @import("../assets/assets.zig");
const image = @import("fluxion_image");

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io });
}

/// A camera at `z` five, looking at the origin.
fn looking(app: *App) !@import("fluxion_ecs").Entity {
    var eye: Transform3D = .at(0, 0, 5);
    eye.lookAt(.zero, .unit_y);
    return app.world.spawnWith(.{ eye, Camera3D{} });
}

fn boxAt(app: *App, x: f32, y: f32, z: f32) !@import("fluxion_ecs").Entity {
    return app.world.spawnWith(.{ Transform3D.at(x, y, z), MeshInstance3D{}, PrimitiveMesh3D{} });
}

test "the boxes a camera sees are drawn together, and one behind it is left out" {
    const app = try headless();
    defer app.destroy();
    // Nothing 3D, no camera: the 3D layer draws nothing.
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.drawn);

    const camera = try looking(app);
    _ = try boxAt(app, 1, 0, 0);
    _ = try boxAt(app, -1, 0, 0);
    _ = try boxAt(app, 0, 0, 20);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.culled);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.draw_calls);

    // Another shape, both sides drawn, and see-through: a draw each.
    const ball = try app.world.spawnWith(.{ Transform3D.at(0, 1, 0), MeshInstance3D{}, PrimitiveMesh3D{ .shape = .sphere } });
    const sheet = try app.addMaterial("sheet", .{ .cull = .disabled });
    const glass = try app.addMaterial("glass", .{ .transparency = .alpha, .albedo_color = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, -1, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = sheet } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 1), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = glass } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 6), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 4), app.renderer3d.draw_calls);

    // Hidden, or on a layer the camera does not see: not drawn.
    try app.world.add(ball, Appearance{ .visible = false });
    app.world.get(camera, Camera3D).?.cull_mask = 0b1;
    app.world.get(try boxAt(app, 0, 0, 0), MeshInstance3D).?.layers = 0b10;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 5), app.renderer3d.drawn);
}

test "a mesh past its visibility range is not drawn, and every draw of a frame is counted together" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    // The camera is at z five: one box two metres off, one twenty.
    const near = try boxAt(app, 0, 0, 3);
    const far = try boxAt(app, 0, 0, -15);
    app.world.get(near, MeshInstance3D).?.visibility_range = 10;
    app.world.get(far, MeshInstance3D).?.visibility_range = 10;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.culled);
    // A box is twelve triangles; the frame's totals hold the draw's.
    try testing.expectEqual(@as(u64, 12), app.renderer3d.last_frame.triangles);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.last_frame.meshes);
    // Nought draws it however far.
    app.world.get(far, MeshInstance3D).?.visibility_range = 0;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.renderer3d.drawn);
}

test "a dense mesh far off is drawn at a coarser level, near it whole, and with no bias always whole" {
    // A picture as large as a screen's: on a small one a level is chosen
    // by what so few pixels show.
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 1920, .height = 1080, .io = testing.io });
    defer app.destroy();
    _ = try looking(app);
    var dense = try mesh.sphere(testing.allocator, 1, 64, 96);
    dense.lods = try @import("lods.zig").make(testing.allocator, dense.vertices, dense.indices, dense.surfaces);
    try testing.expect(dense.lods.len >= 2);
    const whole: u64 = dense.indices.len / 3;
    const handle = try app.addMesh("dense", dense);
    const ball = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), MeshInstance3D{ .mesh = handle } });
    // Near: whole.
    _ = try app.step();
    try testing.expectEqual(whole, app.renderer3d.last_frame.triangles);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.lod_levels[0]);
    // Far off: a coarser level, fewer triangles.
    app.world.get(ball, Transform3D).?.position.z = -300;
    _ = try app.step();
    try testing.expect(app.renderer3d.last_frame.triangles * 2 < whole);
    try testing.expectEqual(@as(u32, 0), app.renderer3d.lod_levels[0]);
    // With no bias, whole however far.
    app.world.get(ball, MeshInstance3D).?.lod_bias = 0;
    _ = try app.step();
    try testing.expectEqual(whole, app.renderer3d.last_frame.triangles);
}

test "the project's 3D scale draws the 3D world smaller than the picture it goes into, and stretches it to fill it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const Project = @import("../project/Project.zig");
    try Project.writeSettings(testing.allocator, testing.io, root, .{ .application = .{ .name = "Scaled" }, .rendering = .{ .scale_3d = 0.5 } });
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io, .root = root });
    defer app.destroy();
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    const targets = app.renderer3d.post.?.targets.items;
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(@as(u32, 32), targets[0].width);
    try testing.expectEqual(@as(u32, 32), targets[0].height);
    // Its depth is not the picture's size: nothing is tested against it.
    try testing.expect(app.renderer3d.last_depth == null);
}

test "with the depth drawn first, every solid surface's depth is drawn before its light, and a see-through one's is not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const Project = @import("../project/Project.zig");
    try Project.writeSettings(testing.allocator, testing.io, root, .{ .application = .{ .name = "Depth" }, .rendering = .{ .depth_prepass = true } });
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io, .root = root });
    defer app.destroy();
    _ = try looking(app);
    _ = try boxAt(app, -1, 0, 0);
    _ = try boxAt(app, 1, 0, 0);
    const glass = try app.addMaterial("glass", .{ .transparency = .alpha, .albedo_color = .rgba(1, 1, 1, 0.5) });
    const pane = try boxAt(app, 0, 0, 1);
    try app.world.add(pane, Material3D{ .material = glass });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.renderer3d.drawn);
    var solid: usize = 0;
    for (app.renderer3d.items.items) |item| {
        try testing.expectEqual(!item.transparent, item.depth_first);
        solid += @intFromBool(item.depth_first);
    }
    try testing.expectEqual(@as(usize, 2), solid);
}

test "a mesh made in code is drawn by its handle, and nothing once it is let go" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    const made = try app.addMesh("crate", try mesh.box(testing.allocator, .init(1, 1, 1)));
    try testing.expectEqual(made, app.findMesh("crate").?);
    try testing.expectEqual(@as(usize, 12), app.meshOf(made).?.triangleCount());
    _ = try app.world.spawnWith(.{ Transform3D{}, MeshInstance3D{ .mesh = made } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);

    app.unloadMesh(made);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.drawn);
}

test "a render view beside a 3D camera draws the 3D world into its picture" {
    const app = try headless();
    defer app.destroy();
    var eye: Transform3D = .at(0, 0, 5);
    eye.lookAt(.zero, .unit_y);
    const monitor = try app.world.spawnWith(.{ eye, Camera3D{}, RenderView{ .width = 32, .height = 24 } });
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    // The screen has no camera of its own: the view's is not the screen's.
    try testing.expect(app.currentCamera3D() == null);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    try testing.expect(app.views.textureOf(monitor) != null);
}

test "the lamps the camera sees are kept, nearest first, and a mesh is lit by those that reach it" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 1, 0), PointLight3D{ .range = 5 } });
    // Too short to reach the box, but seen.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 3, 0), SpotLight3D{ .range = 2 } });
    // Hidden, dark, and behind the camera: none kept.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 1, 0), PointLight3D{}, Appearance{ .visible = false } });
    _ = try app.world.spawnWith(.{ Transform3D.at(1, 0, 0), PointLight3D{ .energy = 0 } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 50), PointLight3D{ .range = 1 } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.renderer3d.lamps_kept);
    try testing.expectEqual([4]f32{ 0, -1, -1, -1 }, app.renderer3d.gathered.items[0].lights[0]);
    try testing.expectEqual([4]f32{ -1, -1, -1, -1 }, app.renderer3d.gathered.items[0].lights[1]);
}

test "a light that casts a shadow draws what it sees into the atlas: a spot one view, a point light six, a sun its cascades" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    // Under the spot light, but casting none, and laid over what is behind
    // it: neither is drawn into its view.
    _ = try app.world.spawnWith(.{ Transform3D.at(0.6, 0.5, 0), MeshInstance3D{ .cast_shadow = false }, PrimitiveMesh3D{} });
    const glass = try app.addMaterial("glass", .{ .transparency = .alpha });
    _ = try app.world.spawnWith(.{ Transform3D.at(-0.6, 0.5, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = glass } });
    // A light with none of its own takes no view.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 2, 2), PointLight3D{ .range = 6 } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.shadow_views);
    try testing.expect(app.renderer3d.atlas == null);

    var above: Transform3D = .at(0, 4, 0);
    above.lookAt(.zero, .unit_z);
    _ = try app.world.spawnWith(.{ above, SpotLight3D{ .range = 10, .shadow = true } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.shadow_views);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.shadow_casters);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.shadow_draws);
    try testing.expect(app.renderer3d.atlas != null);
    // Of the frame's two lamps, the block gives one a view.
    var shadowed: usize = 0;
    for (app.renderer3d.plan.block.lamps[0..2]) |lamp| {
        if (lamp[0] >= 0) shadowed += 1;
    }
    try testing.expectEqual(@as(usize, 1), shadowed);

    _ = try app.world.spawnWith(.{ Transform3D.at(3, 0.5, 0), PointLight3D{ .range = 5, .shadow = true } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1 + 6), app.renderer3d.shadow_views);

    var sun: Transform3D = .at(0, 10, 0);
    sun.lookAt(.init(1, 0, 0.5), .unit_y);
    _ = try app.world.spawnWith(.{ sun, DirectionalLight3D{ .shadow = true, .shadow_cascades = .two } });
    // Hidden, it casts nothing.
    _ = try app.world.spawnWith(.{ sun, DirectionalLight3D{ .shadow = true }, Appearance{ .visible = false } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2 + 1 + 6), app.renderer3d.shadow_views);
    try testing.expectEqual(@as(f32, 2), app.renderer3d.plan.block.suns[0][1]);

    // A few frames with no light that casts one, and the atlas is let go.
    var it = try @import("fluxion_ecs").Query(.{SpotLight3D}).over(&app.world);
    while (it.next()) |chunk| for (chunk.slice(SpotLight3D)) |*light| {
        light.shadow = false;
    };
    var point = try @import("fluxion_ecs").Query(.{PointLight3D}).over(&app.world);
    while (point.next()) |chunk| for (chunk.slice(PointLight3D)) |*light| {
        light.shadow = false;
    };
    var suns = try @import("fluxion_ecs").Query(.{DirectionalLight3D}).over(&app.world);
    while (suns.next()) |chunk| for (chunk.slice(DirectionalLight3D)) |*light| {
        light.shadow = false;
    };
    for (0..5) |_| _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.shadow_views);
    try testing.expect(app.renderer3d.atlas == null);
}

test "a shadow is drawn again only where its light or what casts it changed" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    const box = try boxAt(app, 0, 0, 0);
    var above: Transform3D = .at(0, 4, 0);
    above.lookAt(.zero, .unit_z);
    const spot = try app.world.spawnWith(.{ above, SpotLight3D{ .range = 10, .shadow = true } });
    // Far from the box: its six views see nothing of it.
    _ = try app.world.spawnWith(.{ Transform3D.at(2.5, 0, 0), PointLight3D{ .range = 1.5, .shadow = true } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1 + 6), app.renderer3d.shadow_views);
    try testing.expectEqual(@as(u32, 1 + 6), app.renderer3d.shadow_views_drawn);

    // Nothing moved: nothing drawn.
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1 + 6), app.renderer3d.shadow_views);
    try testing.expectEqual(@as(u32, 0), app.renderer3d.shadow_views_drawn);

    // The box moves: the spot light's view is drawn again, the point light's not.
    app.world.get(box, Transform3D).?.position.x = 0.2;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.shadow_views_drawn);

    // The spot light turns: its view again.
    app.world.get(spot, SpotLight3D).?.angle = 0.6;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.shadow_views_drawn);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.shadow_views_drawn);
}

test "the first visible environment is the one drawn with" {
    const app = try headless();
    defer app.destroy();
    try testing.expect(renderer3d.environmentOf(app) == null);
    _ = try app.world.spawnWith(.{ Environment{ .tonemap = .filmic }, Appearance{ .visible = false } });
    _ = try app.world.spawnWith(.{Environment{ .tonemap = .aces, .fog = true }});
    try testing.expectEqual(Environment.Tonemap.aces, renderer3d.environmentOf(app).?.tonemap);
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    // Smoothed as the project says; a headless one says nothing.
    try testing.expectEqual(@as(u32, 1), app.renderer3d.samples);
}

test "a material naming a 3D shader draws with it, given its numbers by the material and by the mesh's entity" {
    const app = try headless();
    defer app.destroy();
    _ = try looking(app);
    const waves = try app.addShader("waves.shader3d",
        \\uniform Look : 3 {
        \\    float speed = 1.0;
        \\}
        \\fragment {
        \\    EMISSION = vec3(sin(TIME * speed));
        \\}
    );
    try testing.expect(app.shaderOf(waves).?.is3D());
    try testing.expect(app.shaders.compiledOf(waves) == null);
    const surface = try app.addMaterial("waves", .{ .shader = waves });
    const one = try app.world.spawnWith(.{ Transform3D.at(-1, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = surface } });
    const two = try app.world.spawnWith(.{ Transform3D.at(1, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = surface } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.renderer3d.drawn);
    try testing.expect(app.renderer3d.items.items[0].compiled == app.shaders.compiled3DOf(waves).?);
    // The same numbers: one set, one draw.
    try testing.expectEqual(@as(usize, 1), app.renderer3d.param_sets.items.len);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.draw_calls);

    // The material's numbers are both meshes'; an entity's own, its alone.
    try app.setMaterialParam(surface, "speed", &.{3});
    var buffer: [16]f32 = undefined;
    try testing.expectEqualSlices(f32, &.{3}, app.shaderParamOrDefault(two, "speed", &buffer).?);
    try app.setShaderParam(one, "speed", &.{2});
    try testing.expectEqualSlices(f32, &.{2}, app.shaderParamOrDefault(one, "speed", &buffer).?);
    try testing.expectEqualSlices(f32, &.{3}, app.shaderParamOrDefault(two, "speed", &buffer).?);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 2), app.renderer3d.param_sets.items.len);
    try testing.expectEqual(@as(u32, 2), app.renderer3d.draw_calls);

    // One that does not compile draws as the engine's own.
    const broken = try app.addShader("broken.shader3d", "fragment { ALBEDO = 1; }");
    try testing.expect(!app.shaderOf(broken).?.works());
    app.world.get(one, Material3D).?.material = try app.addMaterial("broken", .{ .shader = broken });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.renderer3d.drawn);
    // The items are sorted by where their shaders are in memory, so either
    // one may come first.
    const items = app.renderer3d.items.items;
    const plain = &app.renderer3d.plain.?;
    const first_plain = items[0].compiled == plain;
    try testing.expect(items[if (first_plain) 0 else 1].compiled == plain);
    try testing.expect(items[if (first_plain) 1 else 0].compiled == app.shaders.compiled3DOf(waves).?);
}

test "a camera's ray and a point on the screen go through the game's pixels" {
    const app = try headless();
    defer app.destroy();
    const camera = try looking(app);
    _ = try app.step();
    try testing.expect(app.currentCamera3D().?.eql(camera));
    const middle: @import("fluxion_math").Vec2 = .init(32, 32);
    try testing.expect(app.projectRayNormal(camera, middle).?.approxEql(.init(0, 0, -1)));
    const seen = app.unprojectPosition(camera, .zero).?;
    try testing.expectApproxEqAbs(@as(f32, 32), seen.x, 1e-3);
    try testing.expect(app.isPositionBehind(camera, .init(0, 0, 9)));
    try testing.expect(app.projectPosition(camera, middle, 5).?.approxEql(.zero));
}

test "the 3D components keep what they hold through a scene round trip" {
    const source = try headless();
    defer source.destroy();
    var eye: Transform3D = .at(0, 2, 5);
    eye.lookAt(.zero, .unit_y);
    const camera = try source.world.spawnWith(.{ eye, Camera3D{ .fov = 1, .projection = .orthogonal, .current = true, .cull_mask = 0b101 } });
    try source.setName(camera, "eye");
    const pill = try source.world.spawnWith(.{
        Transform3D.at(1, 0, 0),
        MeshInstance3D{ .layers = 0b100, .cast_shadow = false },
        PrimitiveMesh3D{ .shape = .capsule, .radius = 0.25, .height = 1.5, .segments = 12 },
        Material3D{ .material = try source.addMaterial("blue", .{ .albedo_color = .hex(0x336699), .cull = .front }) },
    });
    try source.setName(pill, "pill");
    const sun = try source.world.spawnWith(.{ Transform3D{}, DirectionalLight3D{ .energy = 2 } });
    try source.setName(sun, "sun");
    const lamp = try source.world.spawnWith(.{ Transform3D{}, PointLight3D{ .range = 3, .attenuation = 2, .distance_fade = true, .distance_fade_begin = 8, .distance_fade_length = 4 } });
    try source.setName(lamp, "lamp");
    const spot = try source.world.spawnWith(.{ Transform3D{}, SpotLight3D{ .angle = 0.5, .angle_attenuation = 3, .distance_fade = true, .distance_fade_begin = 12, .distance_fade_length = 6 } });
    try source.setName(spot, "spot");
    const around = try source.world.spawnWith(.{Environment{ .background = .color, .tonemap = .aces, .fog = true, .fog_height = 2, .glow = true, .glow_threshold = 0.7 }});
    try source.setName(around, "around");
    const shiny = try source.world.spawnWith(.{ Transform3D{}, MeshInstance3D{}, Material3D{ .material = try source.addMaterial("shiny", .{ .metallic = 1, .roughness = 0.2 }) } });
    try source.setName(shiny, "shiny");
    try source.setShaderParam(shiny, "speed", &.{ 1, 2 });

    const text = try scene.write(source, testing.allocator, .{});
    defer testing.allocator.free(text);
    const copy = try headless();
    defer copy.destroy();
    // Made in code, as in the first: a scene names a material by its name.
    const blue = try copy.addMaterial("blue", .{});
    const shiny_material = try copy.addMaterial("shiny", .{});
    _ = try scene.read(copy, text, .{});

    const seen = copy.world.get(copy.find("eye").?, Camera3D).?;
    try testing.expectEqual(source.world.get(camera, Camera3D).?.*, seen.*);
    const back = copy.find("pill").?;
    try testing.expectEqual(source.world.get(pill, MeshInstance3D).?.*, copy.world.get(back, MeshInstance3D).?.*);
    try testing.expectEqual(source.world.get(pill, PrimitiveMesh3D).?.*, copy.world.get(back, PrimitiveMesh3D).?.*);
    try testing.expect(copy.world.get(back, Material3D).?.material.eql(blue));
    try testing.expectEqual(@as(f32, 2), copy.world.get(copy.find("sun").?, DirectionalLight3D).?.energy);
    try testing.expectEqual(source.world.get(lamp, PointLight3D).?.*, copy.world.get(copy.find("lamp").?, PointLight3D).?.*);
    try testing.expectEqual(source.world.get(spot, SpotLight3D).?.*, copy.world.get(copy.find("spot").?, SpotLight3D).?.*);
    try testing.expectEqual(source.world.get(around, Environment).?.*, copy.world.get(copy.find("around").?, Environment).?.*);
    const shiny_back = copy.find("shiny").?;
    try testing.expect(copy.world.get(shiny_back, Material3D).?.material.eql(shiny_material));
    try testing.expectEqualSlices(f32, &.{ 1, 2 }, copy.shader_params.get(shiny_back, "speed").?);
}

test "a surface's pictures are given a chain of levels, before the frame after the one that drew them" {
    var files: helpers.Files = try .init();
    defer files.tmp.cleanup();
    var path: [192]u8 = undefined;
    var pixels: [8 * 8 * 4]u8 = @splat(200);
    try image.png.writeFile(testing.allocator, testing.io, try std.fmt.bufPrint(&path, "{s}/art/brick.png", .{try files.at()}), .{ .width = 8, .height = 8, .pixels = &pixels, .row_pitch = 8 * 4 }, .{});
    const app = try files.app();
    defer app.destroy();

    const brick = try app.assets.loadTexture("res://art/brick.png", .{});
    const loose = try app.assets.textureFromPixels(4, 4, pixels[0 .. 4 * 4 * 4], .{});
    try testing.expect(!app.assets.get(brick).?.mips);
    const surface = try app.addMaterial("brick", .{ .albedo_texture = brick, .emission_texture = loose });
    _ = try looking(app);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = surface } });
    // Drawn, and asked for; made before the next frame is drawn.
    _ = try app.step();
    _ = try app.step();
    const held = app.assets.get(brick).?;
    try testing.expect(held.mips);
    try testing.expectEqual(@as(u32, 4), (try app.device.textureInfo(held.gpu)).mip_levels);
    // One made from pixels in memory has no file to make it from, and keeps its one level.
    try testing.expect(!app.assets.get(loose).?.mips);
    try testing.expectEqual(@as(u32, 1), (try app.device.textureInfo(app.assets.get(loose).?.gpu)).mip_levels);

    // New pixels, of another size, keep a chain.
    var bigger: [16 * 16 * 4]u8 = @splat(9);
    try app.assets.setTexturePixels(brick, 16, 16, &bigger);
    try testing.expectEqual(@as(u32, 5), (try app.device.textureInfo(app.assets.get(brick).?.gpu)).mip_levels);
}

test "a mesh a skeleton bends is drawn in the skeleton's space with its bones, and culled where they are" {
    const app = try headless();
    defer app.destroy();
    const skeleton_table = @import("skeleton.zig");
    const math = @import("fluxion_math");
    // Two bones, the second one up; a box whose top hangs from the second.
    const binds = [_]math.Mat4{ .identity, .fromTranslation(.init(0, -0.5, 0)) };
    var bones = [_]skeleton_table.Bone{
        .{ .name = "Low" },
        .{ .name = "High", .parent = 0, .rest = .{ .translation = .init(0, 0.5, 0) }, .inverse_bind = binds[1] },
    };
    const skeleton = try app.addSkeleton("bones", try skeleton_table.Skeleton.init(app.gpa, &bones));
    var bent = try mesh.box(app.gpa, .init(1, 1, 1));
    bent.skin = try app.gpa.alloc(mesh.SkinVertex, bent.vertices.len);
    for (bent.vertices, bent.skin) |v, *on| on.* = .{ .joints = .{ if (v.position[1] > 0) 1 else 0, 0, 0, 0 } };
    bent.bone_bounds = try mesh.boneBounds(app.gpa, bent.vertices, bent.skin, &binds);
    const handle = try app.addMesh("bent", bent);

    _ = try looking(app);
    const body = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), components.Skeleton3D{ .skeleton = skeleton } });
    // Its own place is not where it is drawn: the skeleton's is.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 50), MeshInstance3D{ .mesh = handle, .skeleton = body } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    try testing.expectEqual(@as(usize, 1), app.renderer3d.skins.items.len);
    const item = app.renderer3d.items.items[0];
    try testing.expect(item.compiled.skin);
    try testing.expectEqual(@as(u32, 0), item.skin);
    // The second bone at rest: its place times its inverse bind is nothing moved.
    try testing.expectEqual([4]f32{ 0, 1, 0, 0 }, app.renderer3d.skins.items[0].bones[3 * 1 + 1]);

    // The top lifted: the bones are written anew, and the box goes with them.
    app.setBonePosition(body, 1, .init(0, 2.5, 0));
    _ = try app.step();
    try testing.expectEqual([4]f32{ 0, 1, 0, 2 }, app.renderer3d.skins.items[0].bones[3 * 1 + 1]);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    // Both bones behind the camera: the mesh is left out, wherever its own place says.
    app.setBonePosition(body, 0, .init(0, 0, 40));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.culled);
}

test "a skeleton that shows its bones draws a line from each to its parent and a dot at each" {
    const app = try headless();
    defer app.destroy();
    const skeleton_table = @import("skeleton.zig");
    var bones = [_]skeleton_table.Bone{
        .{ .name = "Low" },
        .{ .name = "High", .parent = 0, .rest = .{ .translation = .init(0, 0.5, 0) } },
    };
    const skeleton = try app.addSkeleton("bones", try skeleton_table.Skeleton.init(app.gpa, &bones));
    const body = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), components.Skeleton3D{ .skeleton = skeleton } });
    _ = try app.step();
    app.debug_3d_frame.clear();
    try skeleton_table.drawBones(app);
    try testing.expect(app.debug_3d_frame.isEmpty());
    app.world.get(body, components.Skeleton3D).?.show_bones = true;
    try skeleton_table.drawBones(app);
    // One line, two dots.
    try testing.expectEqual(@as(usize, 3), app.debug_3d_frame.lines.items.len);
}

test "a surface's pictures are read as its material says: smoothly, texel by texel, or as the picture is sampled" {
    const app = try headless();
    defer app.destroy();
    const pixels: [16]u8 = @splat(255);
    const picture = try app.assets.adoptTexture("check", 2, 2, &pixels, .{ .filter = .nearest, .mips = true });
    const material = try app.addMaterial("checked", .{ .albedo_texture = picture });
    _ = try looking(app);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Material3D{ .material = material } });

    // Smooth by default, whatever the picture says of itself.
    _ = try app.step();
    try testing.expect(app.renderer3d.items.items[0].sampler.eql(app.assets.mipSamplerFor(.linear, .repeat)));
    app.materialOf(material).?.texture_filter = .nearest;
    _ = try app.step();
    try testing.expect(app.renderer3d.items.items[0].sampler.eql(app.assets.mipSamplerFor(.nearest, .repeat)));
    app.materialOf(material).?.texture_filter = .texture;
    _ = try app.step();
    try testing.expect(app.renderer3d.items.items[0].sampler.eql(app.assets.mipSamplerFor(.nearest, .repeat)));
}

test "a World3D is a world of its own: seen by a camera in it, lit by its own lights, and by no other camera" {
    const app = try headless();
    defer app.destroy();
    const World3D = components.World3D;
    const Parent = components.Parent;
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 2, 0), PointLight3D{} });
    // The arcade's world: two boxes, a lamp and a camera drawing a picture.
    const arcade = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), World3D{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0.5, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Parent.of(arcade) });
    _ = try app.world.spawnWith(.{ Transform3D.at(-0.5, 0, 0), MeshInstance3D{}, PrimitiveMesh3D{}, Parent.of(arcade) });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 2, 1), PointLight3D{}, Parent.of(arcade) });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 2, -1), PointLight3D{}, Parent.of(arcade) });
    var eye: Transform3D = .at(0, 0, 5);
    eye.lookAt(.zero, .unit_y);
    const screen_in_game = try app.world.spawnWith(.{ eye, Camera3D{ .current = true }, RenderView{ .width = 16, .height = 16 }, Parent.of(arcade) });

    // The render view draws first, then the screen: the last draw is the
    // screen's, which sees the main world alone.
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 1), app.renderer3d.lamps_kept);
    try testing.expect(app.views.textureOf(screen_in_game) != null);
    // A current camera in the arcade is not the screen's.
    try testing.expect(!app.currentCamera3D().?.eql(screen_in_game));

    // Its own view sees its own world.
    var through = app.cameraView3D(screen_in_game).?;
    through.world = arcade;
    const texture = try app.device.createTexture(.{ .width = 16, .height = 16, .usage = .{ .sampled = true, .render_target = true }, .label = "test" });
    defer app.device.destroyTexture(texture);
    try app.renderer3d.draw(app, .{ .texture = texture }, 16, 16, through, .black, .{});
    try testing.expectEqual(@as(u32, 2), app.renderer3d.drawn);
    try testing.expectEqual(@as(u32, 2), app.renderer3d.lamps_kept);

    // An editor sees them all; turned off, the arcade is the main world's.
    try app.drawWorld3D(texture, through, .{});
    try testing.expectEqual(@as(u32, 3), app.renderer3d.drawn);
    app.world.get(arcade, World3D).?.enabled = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.renderer3d.drawn);
}

test "the fog volumes a camera sees are kept, nearest first, eight at most, and those of another world are not" {
    const app = try headless();
    defer app.destroy();
    const FogVolume = components.FogVolume;
    _ = try looking(app);
    _ = try boxAt(app, 0, 0, 0);
    for (0..10) |i| _ = try app.world.spawnWith(.{ Transform3D.at(@floatFromInt(i), 0, 0), FogVolume{} });
    // Behind the camera, and with no density: not walked through.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 40), FogVolume{} });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, -2), FogVolume{ .density = 0 } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 8), app.renderer3d.fog_volumes_kept);

    // Moved into a world of their own: the camera sees none.
    const arcade = try app.world.spawnWith(.{ Transform3D{}, components.World3D{} });
    var fogs: std.ArrayList(@import("fluxion_ecs").Entity) = .empty;
    defer fogs.deinit(testing.allocator);
    var it = try @import("fluxion_ecs").Query(.{FogVolume}).over(&app.world);
    while (it.next()) |chunk| try fogs.appendSlice(testing.allocator, chunk.entities);
    for (fogs.items) |fog| try app.setParent(fog, arcade, false);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.renderer3d.fog_volumes_kept);
}

test "sprites, labels and particles are drawn as quads in the 3D pass, those of another world and those behind the camera left out" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = threaded.io() });
    defer app.destroy();
    const Sprite3D = components.Sprite3D;
    const Label3D = components.Label3D;
    const Particles3D = components.Particles3D;
    _ = try looking(app);
    // A sign: its picture, and two words over it - in a font of its own
    // atlas, which they fill and which is made room in.
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 0), Sprite3D{ .texture = app.assets.white, .pixel_size = 1 } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, -40), Sprite3D{ .texture = app.assets.white } });
    _ = try app.world.spawnWith(.{ Transform3D.at(0, 0, 9), Sprite3D{ .texture = app.assets.white } });
    const loaded = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 });
    const sign = try app.world.spawnWith(.{ Transform3D.at(0, 1, 0), Label3D{ .billboard = .enabled, .size = 48 } });
    try app.setText(sign, Label3D, "text", "Exit");
    // A burst of eight sparks.
    const sparks = try app.world.spawnWith(.{ Transform3D.at(0, -1, 0), Particles3D{ .amount = 8, .explosiveness = 1, .one_shot = true, .lifetime = 0.5, .gravity = .zero, .blend = .additive } });

    app.time.source = .{ .fixed = 1.0 / 60.0 };
    _ = try app.step();
    const flat = &app.renderer3d.billboards.?;
    const letters: u32 = if (loaded) |_| 4 else |_| 0;
    // The sign's picture, its letters and the sparks; the far one is there,
    // the one behind the camera is not.
    try testing.expectEqual(@as(u32, 2 + letters + 8), flat.quads);
    try testing.expectEqual(@as(usize, 8), app.particleCount(sparks));

    // A burst over, `finished` said and the sparks gone.
    for (0..40) |_| _ = try app.step();
    try testing.expect(!app.world.get(sparks, Particles3D).?.emitting);
    try testing.expectEqual(@as(u32, 2 + letters), flat.quads);
    try app.restartParticles(sparks);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 8), app.particleCount(sparks));
    try app.emitParticles(sparks, 5);
    try testing.expectEqual(@as(usize, 13), app.particleCount(sparks));

    // In a world of their own, the screen's camera sees none of them.
    const arcade = try app.world.spawnWith(.{ Transform3D{}, components.World3D{} });
    var flats: std.ArrayList(@import("fluxion_ecs").Entity) = .empty;
    defer flats.deinit(testing.allocator);
    inline for (.{ Sprite3D, Label3D, Particles3D }) |C| {
        var it = try @import("fluxion_ecs").Query(.{C}).over(&app.world);
        while (it.next()) |chunk| try flats.appendSlice(testing.allocator, chunk.entities);
    }
    for (flats.items) |entity| try app.setParent(entity, arcade, true);
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), flat.quads);
}
