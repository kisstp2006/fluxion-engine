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
    try testing.expect(app.renderer3d.items.items[0].compiled == &app.renderer3d.plain.?);
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
