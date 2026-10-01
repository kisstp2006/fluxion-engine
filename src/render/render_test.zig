// SPDX-License-Identifier: BSD-3-Clause

//! The 2D layer, headless: sprites drawn through a `.shader`'s fragment
//! stage, the frame copied for a shader that reads it, a control's box left
//! for its shader, a material's numbers kept by a scene and written by a
//! script, and render views drawn into pictures a view texture shows.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const control = @import("../ui/control.zig");
const scene = @import("../scene/scene.zig");
const script = @import("../script/script.zig");
const shaders = @import("shaders.zig");

const Transform2D = components.Transform2D;
const Sprite = components.Sprite;
const Parent = components.Parent;
const Material = shaders.Material;

const glow_source =
    \\uniform Look : 1 {
    \\    float strength = 0.5;
    \\    vec4 glow = vec4(1.0, 0.8, 0.3, 1.0);
    \\}
    \\fragment {
    \\    target = sample(TEXTURE, UV) * COLOR * glow * strength;
    \\}
;

fn headless() !*App {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 64, .height = 64, .io = testing.io });
    return app;
}

test "a sprite with a material is drawn with its shader, and those giving the same numbers share a draw" {
    const app = try headless();
    defer app.destroy();
    const glow = try app.addShader("glow", glow_source);
    try testing.expect(app.shaders.compiledOf(glow) != null);

    _ = try app.world.spawnWith(.{ Transform2D.at(10, 10), Sprite.solid(.white, 8, 8) });
    const a = try app.world.spawnWith(.{ Transform2D.at(20, 10), Sprite.solid(.white, 8, 8), Material{ .shader = glow } });
    _ = try app.world.spawnWith(.{ Transform2D.at(30, 10), Sprite.solid(.white, 8, 8), Material{ .shader = glow } });
    const c = try app.world.spawnWith(.{ Transform2D.at(40, 10), Sprite.solid(.white, 8, 8), Material{ .shader = glow } });
    try app.setShaderParam(c, "strength", &.{1});
    _ = try app.step();
    // The plain one, the two giving the file's numbers, and the one giving its own.
    try testing.expectEqual(@as(u32, 4), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 3), app.sprites.draw_calls);

    // Its own numbers the same as another's, the two are one draw.
    try app.setShaderParam(c, "strength", &.{});
    try testing.expectEqual(@as(?[]const f32, null), app.shaderParam(c, "strength"));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);

    var buffer: [16]f32 = undefined;
    try app.setShaderParam(a, "glow", &.{ 0, 1, 0, 1 });
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 1 }, app.shaderParamOrDefault(a, "glow", &buffer).?);
    try testing.expectEqualSlices(f32, &.{0.5}, app.shaderParamOrDefault(a, "strength", &buffer).?);
    try testing.expect(app.shaderParamOrDefault(a, "nothing", &buffer) == null);
}

test "a sprite that multiplies what is under it is drawn apart, with or without a material" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(10, 10), Sprite.solid(.white, 8, 8) });
    _ = try app.world.spawnWith(.{ Transform2D.at(20, 10), Sprite{ .width = 8, .height = 8, .blend = .multiply, .tint = .rgba(1, 0, 0, 0.5) } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);

    // A material's shader gives the colour to multiply by itself.
    const glow = try app.addShader("glow", glow_source);
    _ = try app.world.spawnWith(.{ Transform2D.at(30, 10), Sprite{ .width = 8, .height = 8, .blend = .multiply }, Material{ .shader = glow } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.sprites.draw_calls);
}

test "a shader that does not compile says why and draws as none" {
    const app = try headless();
    defer app.destroy();
    const broken = try app.addShader("broken",
        \\fragment {
        \\    target = nothing;
        \\}
    );
    const held = app.shaderOf(broken).?;
    try testing.expect(held.compiled == null);
    try testing.expect(std.mem.startsWith(u8, held.problems, "2:"));
    _ = try app.world.spawnWith(.{ Transform2D.at(10, 10), Sprite.solid(.white, 8, 8), Material{ .shader = broken } });
    _ = try app.world.spawnWith(.{ Transform2D.at(20, 10), Sprite.solid(.white, 8, 8) });
    _ = try app.step();
    // As plain as the other, and drawn with it.
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);

    // Mended, it draws with its shader.
    try app.shaders.setText(app, broken, "fragment { target = sample(TEXTURE, UV) * COLOR; }");
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);
}

test "a material that reads the screen has the frame drawn where it can be read, copied when more is drawn under it" {
    const app = try headless();
    defer app.destroy();
    const shade = try app.addShader("shade",
        \\fragment {
        \\    target = sample(SCREEN_TEXTURE, SCREEN_UV) * COLOR;
        \\}
    );
    _ = try app.step();
    try testing.expect(app.screen_texture.frame == null);

    var first = Sprite.solid(.white, 8, 8);
    first.order = 0;
    var between = Sprite.solid(.white, 8, 8);
    between.order = 1;
    var last = Sprite.solid(.white, 8, 8);
    last.order = 2;
    _ = try app.world.spawnWith(.{ Transform2D.at(10, 10), first, Material{ .shader = shade } });
    _ = try app.world.spawnWith(.{ Transform2D.at(20, 10), between });
    _ = try app.world.spawnWith(.{ Transform2D.at(30, 10), last, Material{ .shader = shade } });
    _ = try app.step();
    try testing.expect(app.screen_texture.frame != null);
    // Once before the first, and again after the plain one went down.
    try testing.expectEqual(@as(u32, 2), app.screen_texture.copies);
}

test "a colour rect with a material is drawn by its shader, in the box the interface leaves" {
    const app = try headless();
    defer app.destroy();
    try app.useControlNodes();
    const glow = try app.addShader("glow", glow_source);
    const root = try app.world.spawnWith(.{ control.Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, control.CanvasLayer{} });
    _ = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 20 }, .height = .{ .mode = .fixed, .value = 10 } },
        control.ColorRect{ .color = .hex(0xFF0000) },
        Material{ .shader = glow },
        Parent.of(root),
    });
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), app.control_tree.customs.items.len);
    var boxes: usize = 0;
    for (app.interface.commands) |command| {
        if (command.config == .custom) boxes += 1;
    }
    try testing.expectEqual(@as(usize, 1), boxes);
}

test "a scene keeps a material's numbers, and reads them back" {
    const app = try headless();
    defer app.destroy();
    const glow = try app.addShader("glow", glow_source);
    const lit = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite.solid(.white, 8, 8), Material{ .shader = glow } });
    try app.setShaderParam(lit, "strength", &.{0.75});
    try app.setShaderParam(lit, "glow", &.{ 0, 0.5, 1, 1 });

    const bytes = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"params\"") != null);

    app.clearWorld();
    _ = try scene.read(app, bytes, .{});
    var it = try @import("fluxion_ecs").Query(.{Material}).over(&app.world);
    const chunk = it.next().?;
    const again = chunk.entities[0];
    try testing.expectEqualSlices(f32, &.{0.75}, app.shaderParam(again, "strength").?);
    try testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 1 }, app.shaderParam(again, "glow").?);
}

test "a script reads and writes a material's numbers as its fields" {
    const app = try headless();
    defer app.destroy();
    try app.useScripts(.{});
    const glow = try app.addShader("glow", glow_source);
    const handle = try app.addScript("pulse.flux",
        \\var was = 0.0;
        \\struct Pulse {
        \\    fn ready(self) {
        \\        const material = self.entity.get(Material);
        \\        was = material.strength;
        \\        material.strength = 0.25;
        \\        material.glow = color(0.0, 1.0, 0.0, 1.0);
        \\    }
        \\}
    );
    const lit = try app.world.spawnWith(.{ Transform2D.at(0, 0), Sprite.solid(.white, 8, 8), Material{ .shader = glow } });
    try app.world.add(lit, script.Script.of(handle));
    _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.scripts.?.failures);
    const scripts = app.scripts.?;
    try testing.expectApproxEqAbs(@as(f64, 0.5), scripts.vm.get(scripts.moduleOf(handle).?, "was").?.asFloat(), 0.0001);
    try testing.expectEqualSlices(f32, &.{0.25}, app.shaderParam(lit, "strength").?);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 1 }, app.shaderParam(lit, "glow").?);
}

test "a render view draws what its camera sees into a picture a view texture shows, and the screen never looks through it" {
    const app = try headless();
    defer app.destroy();
    const arcade = try app.world.spawnWith(.{
        Transform2D.at(5000, 0),
        components.Camera2D{ .priority = 100 },
        components.RenderView{ .width = 48, .height = 24 },
    });
    _ = try app.world.spawnWith(.{ Transform2D.at(5000, 0), Sprite.solid(.white, 8, 8) });
    const screen = try app.world.spawnWith(.{ Transform2D.at(20, 20), Sprite{}, components.ViewTexture{ .view = arcade } });
    _ = try app.step();

    const picture = app.views.textureOf(arcade).?;
    const texture = app.assets.get(picture).?;
    try testing.expectEqual(@as(u32, 48), texture.width);
    try testing.expectEqual(@as(u32, 24), texture.height);
    // The screen looked through no camera: what it drew is the one showing
    // the picture, at the picture's size.
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    const corners = app.spriteCorners(screen).?;
    try testing.expectApproxEqAbs(@as(f32, 48), corners[1].x - corners[0].x, 0.001);
    const middle = app.screenToWorld(32, 32);
    try testing.expectApproxEqAbs(@as(f32, 32), middle.x, 0.001);

    // Asked a new size, the picture is made again under the same handle.
    app.world.get(arcade, components.RenderView).?.width = 64;
    _ = try app.step();
    try testing.expect(picture.eql(app.views.textureOf(arcade).?));
    try testing.expectEqual(@as(u32, 64), app.assets.get(picture).?.width);

    // And gone with its view.
    app.world.despawn(arcade);
    _ = try app.step();
    try testing.expect(app.views.textureOf(arcade) == null);
    try testing.expect(app.assets.get(picture) == null);
}

test "a branch on a render layer of its own is drawn only through a camera that sees that layer" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(32, 32), components.Camera2D{ .cull_mask = 0b01 } });
    const hidden = try app.world.spawnWith(.{ Transform2D.at(0, 0), @import("../scene/inherited.zig").Appearance{ .render_layers = 0b10 } });
    _ = try app.world.spawnWith(.{ Transform2D.at(30, 30), Sprite.solid(.white, 8, 8), Parent.of(hidden) });
    _ = try app.world.spawnWith(.{ Transform2D.at(34, 34), Sprite.solid(.white, 8, 8) });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    app.world.get(hidden, @import("../scene/inherited.zig").Appearance).?.render_layers = 0b11;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.sprites.drawn);
}

test "a texture rect with a view texture shows the view's picture" {
    const app = try headless();
    defer app.destroy();
    try app.useControlNodes();
    const view = try app.world.spawnWith(.{ Transform2D.at(0, 0), components.Camera2D{}, components.RenderView{ .width = 16, .height = 16 } });
    const picture = try app.viewTexture(view);
    const root = try app.world.spawnWith(.{ control.Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, control.CanvasLayer{} });
    _ = try app.world.spawnWith(.{
        control.Control{ .width = .{ .mode = .fixed, .value = 20 }, .height = .{ .mode = .fixed, .value = 10 } },
        control.TextureRect{},
        components.ViewTexture{ .view = view },
        Parent.of(root),
    });
    _ = try app.step();
    const gpu = app.assets.get(picture).?.gpu;
    var found = false;
    for (app.control_tree.textures.items) |held| found = found or std.meta.eql(held, gpu);
    try testing.expect(found);
    try testing.expectError(error.NotAView, app.viewTexture(root));
}

test "a stretched game is laid out at its own size, drawn apart and put on the window, and the pointer is in its pixels" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 128,
        .height = 80,
        .stretch = .{ .mode = .picture, .width = 32, .height = 16 },
    });
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(16, 8), Sprite.solid(.white, 4, 4) });
    _ = try app.step();
    // Four window pixels a picture pixel, and a bar of eight above and below.
    try testing.expectEqual(@as(u32, 32), app.game_area.width);
    try testing.expectEqual(@as(f32, 8), app.game_area.shown.y);
    try testing.expect(app.screen_texture.frame != null);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    app.input.apply(.{ .cursor = .{ .window = .none, .x = 64, .y = 40, .dx = 4, .dy = 0 } });
    try testing.expectEqual(@as(f32, 16), app.input.pointer.x);
    try testing.expectEqual(@as(f32, 8), app.input.pointer.y);
    try testing.expectEqual(@as(f32, 1), app.input.pointer.dx);
    const under = app.pointerInWorld();
    try testing.expectApproxEqAbs(@as(f32, 16), under.x, 0.001);

    // A canvas: the window's pixels, with everything four times the size.
    app.stretch.mode = .canvas;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 128), app.game_area.width);
    try testing.expectEqual(@as(f32, 4), app.game_area.scale);
    try testing.expectEqual(@as(f32, 4), app.currentView().zoom_x);
    try testing.expectEqual(@as(f32, 4), app.interface.scale);
    // With no camera, the made-at size's top left is the game area's.
    try testing.expectApproxEqAbs(@as(f32, 0), app.currentView().toScreen(.init(0, 0)).x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 128), app.currentView().toScreen(.init(32, 16)).x, 0.001);
}

const lights = @import("lights.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const Assets = @import("../assets/assets.zig");
const View = @import("view.zig").View;
const Drawing2D = @import("drawing.zig").Drawing2D;
const image = @import("fluxion_image");
const helpers = @import("../test_helpers.zig");
const pressOf = helpers.pressOf;

test "a light the view sees lights the world through a buffer of its own, and what is unshaded is drawn over it" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(32, 32), Sprite.solid(.white, 8, 8) });
    const sign = try app.world.spawnWith(.{ Transform2D.at(20, 20), Sprite{ .width = 8, .height = 8, .layer = -5 }, Appearance{ .lighting = .unshaded } });
    _ = try app.step();
    // Nothing lit: one draw, the layers as they are.
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.lights_drawn);
    try testing.expect(app.sprites.items.items[0].unshaded);

    const lamp = try app.world.spawnWith(.{ Transform2D.at(32, 32), lights.PointLight2D{ .radius = 30 } });
    _ = try app.step();
    // The lit sprite, the lamp into the buffer, the buffer over the world,
    // and the sign over that: drawn last whatever its layer.
    try testing.expectEqual(@as(u32, 1), app.sprites.lighting.lights_drawn);
    try testing.expectEqual(@as(u32, 4), app.sprites.draw_calls);
    try testing.expect(app.sprites.items.items[1].unshaded);
    try testing.expect(!app.sprites.items.items[0].unshaded);

    // A lamp the view does not reach lights nothing, and neither does one
    // switched off: the world is drawn as it is.
    app.world.get(lamp, Transform2D).?.x = 5000;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);
    app.world.get(lamp, Transform2D).?.x = 32;
    app.world.get(lamp, lights.PointLight2D).?.enabled = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.sprites.draw_calls);

    // The dark alone is lighting too: the world, the buffer over it, the
    // sign. Its colour is what the buffer starts as, halved.
    _ = try app.world.spawnWith(.{lights.AmbientLight2D{ .color = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 } }});
    _ = try app.step();
    try testing.expectEqual(@as(u32, 3), app.sprites.draw_calls);
    try testing.expectApproxEqAbs(@as(f32, 0.2), app.sprites.lighting.clearColor().g, 1e-6);

    // Lit again, the sign is lit with the rest.
    app.world.get(sign, Appearance).?.lighting = .lit;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);
}

test "a light on render layers a camera does not see does not light what it sees" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(32, 32), components.Camera2D{ .cull_mask = 0b01 } });
    _ = try app.world.spawnWith(.{ Transform2D.at(32, 32), Sprite.solid(.white, 8, 8) });
    const lamp = try app.world.spawnWith(.{ Transform2D.at(32, 32), lights.PointLight2D{}, Appearance{ .render_layers = 0b10 } });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.lights_drawn);
    app.world.get(lamp, Appearance).?.render_layers = 0b01;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.sprites.lighting.lights_drawn);
}

test "an occluder, and a map's solid tiles when it says so, cast the shadows of a light that has them" {
    const app = try headless();
    defer app.destroy();
    const lamp = try app.world.spawnWith(.{ Transform2D.at(32, 32), lights.PointLight2D{ .radius = 30, .shadows = true } });
    // Sized by its sprite.
    const crate = try app.world.spawnWith(.{ Transform2D.at(44, 32), Sprite.solid(.white, 6, 6), lights.LightOccluder2D{} });
    _ = try app.step();
    try testing.expect(app.sprites.lighting.shadows_drawn > 0);
    // Its reach marked, the shadows, and the light where it is not shadowed.
    try testing.expectEqual(app.sprites.lighting.shadows_drawn + 2, @as(u32, @intCast(app.sprites.lighting.draws.items.len)));

    // Switched off, it casts nothing, and the lamp is drawn as one without
    // shadows is.
    app.world.get(crate, lights.LightOccluder2D).?.enabled = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.shadows_drawn);
    try testing.expectEqual(@as(usize, 1), app.sprites.lighting.draws.items.len);

    const set = try app.addTileSet("walls.tileset",
        \\{
        \\  "fluxion_tileset": 1,
        \\  "tile_size": [8, 8],
        \\  "sources": [{ "id": 0, "tiles": [{ "at": [0, 0], "collision": "full" }] }]
        \\}
    );
    const map = try app.world.spawnWith(.{ Transform2D{}, @import("../tiles/tilemap.zig").TileMap{ .tile_set = set } });
    _ = try app.setTile(map, 5, 3, .at(0, 0, 0));
    _ = try app.setTile(map, 5, 4, .at(0, 0, 0));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.shadows_drawn);
    app.world.get(map, @import("../tiles/tilemap.zig").TileMap).?.light_occlusion = true;
    _ = try app.step();
    // The two tiles are one box.
    try testing.expectEqual(@as(usize, 1), app.sprites.lighting.outlines.items.len);
    try testing.expect(app.sprites.lighting.shadows_drawn > 0);

    // A lamp without shadows passes through it all.
    app.world.get(lamp, lights.PointLight2D).?.shadows = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.shadows_drawn);
}

test "a scene keeps its lights and occluders" {
    const app = try headless();
    defer app.destroy();
    _ = try app.world.spawnWith(.{ Transform2D.at(1, 2), lights.PointLight2D{ .radius = 90, .blend = .subtract, .shadows = true, .shadow_color = .{ .r = 0.1, .g = 0, .b = 0.2, .a = 0.5 } } });
    _ = try app.world.spawnWith(.{ Transform2D.at(3, 4), lights.LightOccluder2D{ .shape = .capsule, .radius = 4, .extents = .init(0, 12) } });
    _ = try app.world.spawnWith(.{ lights.DirectionalLight2D{ .energy = 0.25 }, lights.AmbientLight2D{}, Appearance{ .lighting = .unshaded } });
    const bytes = try scene.write(app, testing.allocator, .{});
    defer testing.allocator.free(bytes);
    app.clearWorld();
    _ = try scene.read(app, bytes, .{});

    const ecs = @import("fluxion_ecs");
    var points = try ecs.Query(.{lights.PointLight2D}).over(&app.world);
    const lamp = points.next().?.slice(lights.PointLight2D)[0];
    try testing.expectEqual(lights.Blend.subtract, lamp.blend);
    try testing.expectEqual(@as(f32, 90), lamp.radius);
    try testing.expectEqual(@as(f32, 0.5), lamp.shadow_color.a);
    var walls = try ecs.Query(.{lights.LightOccluder2D}).over(&app.world);
    try testing.expectEqual(lights.LightOccluder2D.Shape.capsule, walls.next().?.slice(lights.LightOccluder2D)[0].shape);
    var suns = try ecs.Query(.{ lights.DirectionalLight2D, Appearance }).over(&app.world);
    const sun = suns.next().?;
    try testing.expectEqual(@as(f32, 0.25), sun.slice(lights.DirectionalLight2D)[0].energy);
    try testing.expectEqual(Appearance.Lighting.unshaded, sun.slice(Appearance)[0].lighting);
}

test "a sprite nowhere near the camera is not drawn" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
    });
    defer app.destroy();

    // With no camera, the view is the window.
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(160, 120),
        components.Sprite.solid(.white, 16, 16),
    });
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(9000, 9000),
        components.Sprite.solid(.white, 16, 16),
    });

    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.culled);
}

test "the world is drawn into a texture through a view of its own" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240 });
    defer app.destroy();
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(1000, 1000),
        components.Sprite.solid(.white, 16, 16),
    });
    const panel = try app.device.createTexture(.{
        .width = 64,
        .height = 64,
        .usage = .{ .sampled = true, .render_target = true },
    });
    defer app.device.destroyTexture(panel);

    // The window's view is nowhere near it; this one is right over it.
    var view: View = .screen(64, 64);
    view.x = 1000;
    view.y = 1000;
    try app.drawWorld(panel, view);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    view.x = 0;
    try app.drawWorld(panel, view);
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 1), app.sprites.culled);
    try testing.expect(!app.drawnUpsideDown());
}

test "with the world off the screen, a frame draws none of it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 320, .height = 240 });
    defer app.destroy();
    app.world_on_screen = false;
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(160, 120),
        components.Sprite.solid(.white, 16, 16),
    });

    try app.run();
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 0), app.sprites.draw_calls);
}

test "a sprite half off the edge is still drawn" {
    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
    });
    defer app.destroy();

    _ = try app.world.spawnWith(.{
        components.Transform2D.at(-4, 120),
        components.Sprite.solid(.white, 40, 40),
    });

    try app.run();

    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 0), app.sprites.culled);
}

test "every letter of a label is drawn however full its font's atlas gets, and at any size" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 1280, .height = 720, .io = threaded.io() });
    defer app.destroy();
    // An atlas a few big letters fill.
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 64 }) catch
        return error.SkipZigTest;

    const words = "The quick brown fox jumps over the lazy dog";
    const long = try app.world.spawnWith(.{ components.Transform2D.at(0, 100), components.Text2D{ .size = 40 } });
    try app.setText(long, components.Text2D, "text", words);
    // Taller than the atlas is.
    const big = try app.world.spawnWith(.{ components.Transform2D.at(0, 300), components.Text2D{ .size = 120 } });
    try app.setText(big, components.Text2D, "text", "Big");
    const letters = words.len - std.mem.count(u8, words, " ") + 3;

    try app.run();
    try testing.expectEqual(@as(u32, @intCast(letters)), app.sprites.drawn);
    var tallest: f32 = 0;
    for (app.sprites.items.items) |item| tallest = @max(tallest, item.instance.shape[1]);
    try testing.expect(tallest > 70);

    // And every frame after, from the atlas as the last left it.
    _ = try app.step();
    try testing.expectEqual(@as(u32, @intCast(letters)), app.sprites.drawn);
}

test "a label with no font loaded draws nothing and does not fall over" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const label = try app.world.spawnWith(.{
        components.Transform2D.at(10, 10),
        components.Text2D{},
    });
    try app.setText(label, components.Text2D, "text", "nobody can read this");

    try app.run();
    try testing.expectEqual(@as(u32, 0), app.sprites.drawn);
}

test "a label becomes one quad per letter" {
    // A real font off this machine; skipped where there is none, as on a
    // build server.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .frames = 1,
        .width = 320,
        .height = 240,
        .io = threaded.io(),
    });
    defer app.destroy();

    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch
        return error.SkipZigTest;

    const label = try app.world.spawnWith(.{
        components.Transform2D.at(20, 20),
        components.Text2D{},
    });
    try app.setText(label, components.Text2D, "text", "Hi!");

    try app.run();

    // Three letters, three quads, and three glyphs in the atlas.
    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    const face = app.assets.fontOf(.none).?;
    try testing.expectEqual(@as(usize, 3), face.atlas.count());

    // The second frame rasterises none of them again.
    app.running = true;
    app.frames_left = 1;
    _ = try app.step();
    try testing.expectEqual(@as(usize, 3), face.atlas.count());
}

test "a label is laid out once, and again when its words or its atlas change" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1, .width = 320, .height = 240, .io = threaded.io(), .fixed_frame_time = true });
    defer app.destroy();
    _ = app.assets.loadFont(Assets.systemFontPath(), .{ .atlas = 256 }) catch
        return error.SkipZigTest;

    const label = try app.world.spawnWith(.{ components.Transform2D.at(20, 20), components.Text2D{} });
    try app.setText(label, components.Text2D, "text", "Hi!");
    try app.run();
    app.running = true;
    app.frames_left = null;
    const first = app.sprites.laid.get(label.toInt()).?.hash;
    const left = app.sprites.items.items[0].instance.place[0];

    // Moved, it is placed again from the same layout: a few frames on, past
    // the steps it is drawn between.
    app.world.get(label, components.Transform2D).?.x = 60;
    for (0..3) |_| _ = try app.step();
    try testing.expectEqual(first, app.sprites.laid.get(label.toInt()).?.hash);
    try testing.expectApproxEqAbs(left + 40, app.sprites.items.items[0].instance.place[0], 0.001);

    // New words are laid out anew.
    try app.setText(label, components.Text2D, "text", "Hello");
    _ = try app.step();
    const second = app.sprites.laid.get(label.toInt()).?;
    try testing.expect(second.hash != first);
    try testing.expectEqual(@as(usize, 5), second.glyphs.items.len);
    try testing.expectEqual(@as(u32, 5), app.sprites.drawn);

    // So are the words of an atlas emptied since: their places in it are gone.
    app.assets.fontOf(.none).?.atlas.clear();
    _ = try app.step();
    try testing.expect(app.sprites.laid.get(label.toInt()).?.hash != second.hash);
    try testing.expectEqual(@as(u32, 5), app.sprites.drawn);
    try testing.expectEqual(@as(usize, 4), app.assets.fontOf(.none).?.atlas.count());

    // A label gone is let go of in time.
    app.world.despawn(label);
    for (0..130) |_| _ = try app.step();
    try testing.expectEqual(@as(usize, 0), app.sprites.laid.count());
}

test "a capture is saved as a PNG the size of the target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const app = try App.create(testing.allocator, .{
        .headless = true,
        .width = 32,
        .height = 16,
        .frames = 1,
        .io = testing.io,
    });
    defer app.destroy();
    try app.run();

    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/shot.png", .{tmp.sub_path});
    try app.saveCapture(path);

    var decoded = try image.png.readFile(testing.allocator, testing.io, path, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 32), decoded.width);
    try testing.expectEqual(@as(u32, 16), decoded.height);
}

test "a capture with nothing to write files with says so" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();
    try app.run();
    try testing.expectError(error.NoIo, app.saveCapture("nowhere.png"));
}

test "additive sprites get a draw of their own, and share it with each other" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    for ([_]components.Sprite.Blend{ .additive, .alpha, .additive }, 0..) |blend, i| {
        var glow = components.Sprite.solid(.white, 8, 8);
        glow.blend = blend;
        _ = try app.world.spawnWith(.{ components.Transform2D.at(@floatFromInt(10 + i * 10), 10), glow });
    }
    try app.run();

    try testing.expectEqual(@as(u32, 3), app.sprites.drawn);
    try testing.expectEqual(@as(u32, 2), app.sprites.draw_calls);
}

test "a drawing is drawn at its entity: boxes, lines, circles and polygons among the sprites, in the order drawn" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const canvas = try app.world.spawnWith(.{components.Transform2D.at(100, 50)});
    try app.drawRect(canvas, .init(0, 0), .init(10, 4), .rgba(1, 0, 0, 1), true, 1);
    try app.drawLine(canvas, .init(0, 0), .init(20, 0), .white, 2);
    try app.drawCircle(canvas, .init(0, 0), 20, .white, true, 1);
    try app.drawPolygon(canvas, &.{ .init(0, 0), .init(8, 0), .init(8, 8), .init(0, 8) }, .white);
    try testing.expect(app.world.has(canvas, Drawing2D));
    // A sprite on a layer over it.
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite{ .width = 4, .height = 4, .layer = 1 } });
    _ = try app.step();

    // A box, a line, a circle in fifteen pieces and a square in two.
    const items = app.sprites.items.items;
    try testing.expectEqual(@as(usize, 1 + 1 + 15 + 2 + 1), items.len);
    // In the order drawn, the sprite over them all.
    const box = items[0].instance;
    try testing.expect(box.corner(0, 0).approxEql(.init(100, 50)));
    try testing.expect(box.corner(1, 1).approxEql(.init(110, 54)));
    try testing.expectEqual(@as(f32, 1), box.tint[0]);
    const line = items[1].instance;
    try testing.expect(line.corner(0, 0).approxEql(.init(100, 49)));
    try testing.expect(line.corner(1, 1).approxEql(.init(120, 51)));
    // A triangle folds its fourth corner onto its third.
    const piece = items[2].instance;
    try testing.expect(piece.corner(1, 1).approxEql(piece.corner(0, 1)));
    try testing.expectEqual(@as(f32, 4), items[items.len - 1].instance.shape[1]);

    // Cleared, nothing of it is drawn.
    app.clearDrawing(canvas);
    _ = try app.step();
    try testing.expectEqual(@as(usize, 1), app.sprites.items.items.len);
}

test "a repeating texture tiles across a region past its edge" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 1 });
    defer app.destroy();

    const tile = try app.assets.textureFromPixels(2, 2, &(.{255} ** 16), .{ .wrap = .repeat });
    _ = try app.world.spawnWith(.{
        components.Transform2D.at(32, 32),
        components.Sprite{ .texture = tile, .region = .repeated(4, 2) },
    });
    try app.run();

    const drawn = app.sprites.items.items[0];
    try testing.expect(std.meta.eql(app.assets.samplers.get(.nearest).get(.repeat), drawn.sampler));
    try testing.expectEqual(@as(f32, 8), drawn.instance.place[2]);
    try testing.expectEqual(@as(f32, 4), drawn.instance.shape[1]);
}

const Scribble = struct {
    var every_frame: bool = true;

    fn line(app: *App) anyerror!void {
        if (every_frame) app.debug.line2d(.init(0, 0), .init(10, 10), .red);
    }

    fn circle(app: *App) anyerror!void {
        app.debug.with(.{ .segments = 16 }).circle2d(.init(20, 20), 5, .green);
    }

    fn lasting(app: *App) anyerror!void {
        if (app.time.frame == 1) app.debug.with(.{ .seconds = 0.05 }).cross2d(.init(5, 5), 4, .white);
    }
};

test "a debug shape is drawn in the frame it was drawn in, and not in the next" {
    Scribble.every_frame = true;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "line", Scribble.line);

    try app.startup();
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.debug_renderer.stats.lines);

    Scribble.every_frame = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_renderer.stats.lines);
}

test "a debug shape drawn in a fixed step is there in every frame until the next step" {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 1.0 / 64.0 });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 256.0 };
    try app.addSystem(.fixed, "circle", Scribble.circle);

    try app.startup();
    for (1..13) |frame| {
        _ = try app.step();
        try testing.expectEqual(@as(u32, if (frame < 4) 0 else 16), app.debug_renderer.stats.lines);
    }

    app.time.source = .{ .fixed = 1.0 / 32.0 };
    _ = try app.step();
    try testing.expectEqual(@as(u32, 16), app.debug_renderer.stats.lines);
}

test "a lasting debug shape stays for its seconds of game time" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 64.0 };
    try app.addSystem(.update, "lasting", Scribble.lasting);

    try app.startup();
    var frames_with_it: u32 = 0;
    for (0..10) |_| {
        _ = try app.step();
        if (app.debug_renderer.stats.lines > 0) frames_with_it += 1;
    }
    try testing.expectEqual(@as(u32, 4), frames_with_it);
}

test "with debug hidden nothing of it is drawn, a game's own shapes nor the engine's views" {
    Scribble.every_frame = true;
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "line", Scribble.line);
    app.debug_views.transforms = true;
    _ = try app.world.spawnWith(.{components.Transform2D.at(1, 1)});
    app.debug_visible = false;

    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_renderer.stats.lines);
    try testing.expectEqual(@as(u32, 1), app.debug_frame.count(.world).lines);

    app.debug_visible = true;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1 + 2), app.debug_renderer.stats.lines);
}

/// F3 pressed on the second frame.
fn debugKeyOnSecond(app: *App) anyerror!void {
    if (app.time.frame == 2) app.input.apply(pressOf(.f3));
}

test "the debug key shows and hides what debug draws" {
    const app = try App.create(testing.allocator, .{ .headless = true, .frames = 3, .debug_key = .f3 });
    defer app.destroy();
    try app.addSystem(.input, "f3 on second", debugKeyOnSecond);
    try app.run();
    try testing.expect(!app.debug_visible);
}

test "a label's corners are the box its lines are laid out in" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;

    const one = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D{},
    });
    try app.setText(one, components.Text2D, "text", "Hello");
    const corners = app.textCorners(one).?;
    // The transform is the top left of the first line, and the box goes
    // right and down from it.
    try testing.expectApproxEqAbs(@as(f32, 100), corners[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), corners[0].y, 0.001);
    try testing.expect(corners[2].x > corners[0].x);
    try testing.expect(corners[2].y > corners[0].y);
    const width = corners[2].x - corners[0].x;
    const height = corners[2].y - corners[0].y;

    // A second line is another line's height, and no wider for the same
    // words.
    const two = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D{},
    });
    try app.setText(two, components.Text2D, "text", "Hello\nHello");
    const taller = app.textCorners(two).?;
    try testing.expectApproxEqAbs(width, taller[2].x - taller[0].x, 0.001);
    try testing.expectApproxEqAbs(height * 2, taller[2].y - taller[0].y, 0.01);

    // Centred, the same box sits astride the transform.
    const middle = try app.world.spawnWith(.{
        components.Transform2D.at(100, 50),
        components.Text2D{ .alignment = .center },
    });
    try app.setText(middle, components.Text2D, "text", "Hello");
    const centred = app.textCorners(middle).?;
    try testing.expectApproxEqAbs(100 - width / 2, centred[0].x, 0.001);
    try testing.expectApproxEqAbs(100 + width / 2, centred[2].x, 0.001);

    // Nothing to draw, nothing to outline: no words, and bytes that are
    // not words either, which the renderer passes over as well.
    const empty = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Text2D{} });
    try testing.expect(app.textCorners(empty) == null);
    try app.setText(empty, components.Text2D, "text", &.{ 0xff, 0xfe });
    try testing.expect(app.textCorners(empty) == null);
    try testing.expect(app.textCorners(.none) == null);
}

test "an entity is outlined by whichever of the two it is drawn as" {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;

    const drawn = try app.world.spawnWith(.{
        components.Transform2D.at(0, 0),
        components.Sprite.solid(.white, 20, 10),
    });
    const written = try app.world.spawnWith(.{
        components.Transform2D.at(0, 0),
        components.Text2D{},
    });
    try app.setText(written, components.Text2D, "text", "Hello");
    const neither = try app.world.spawnWith(.{components.Transform2D.at(0, 0)});

    const box = app.drawnCorners(drawn).?;
    try testing.expectApproxEqAbs(@as(f32, 20), box[2].x - box[0].x, 0.001);
    try testing.expect(app.drawnCorners(written) != null);
    try testing.expect(app.spriteCorners(written) == null);
    try testing.expect(app.drawnCorners(neither) == null);
}

const Beneath = struct {
    fn grid(app: *App) anyerror!void {
        app.debug_under.line2d(.init(-50, 0), .init(50, 0), .white);
        app.debug_under.line2d(.init(0, -50), .init(0, 50), .white);
    }

    fn stepped(app: *App) anyerror!void {
        app.debug_under.line2d(.init(0, 0), .init(1, 1), .white);
    }
};

test "what is drawn under the world is drawn in a pass of its own, before the sprites" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try app.addSystem(.update, "grid", Beneath.grid);
    try app.addSystem(.update, "line", Scribble.line);
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 8, 8) });

    _ = try app.step();
    // Two under, one over, each counted where it was drawn.
    try testing.expectEqual(@as(u32, 2), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.debug_renderer.stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    // Hidden with the rest of `debug`.
    app.debug_visible = false;
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "nothing under the world makes no pass of its own" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.world.spawnWith(.{ components.Transform2D.at(0, 0), components.Sprite.solid(.white, 8, 8) });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.debug_under_stats.lines);
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);
}

test "under the world as over it, a fixed step's shapes last until the next step" {
    const app = try App.create(testing.allocator, .{ .headless = true, .fixed_delta = 1.0 / 64.0 });
    defer app.destroy();
    app.time.source = .{ .fixed = 1.0 / 256.0 };
    try app.addSystem(.fixed, "stepped", Beneath.stepped);

    // A step every fourth frame: its line is there from the first step on,
    // in the frames between the steps as well.
    try app.startup();
    for (1..13) |frame| {
        _ = try app.step();
        try testing.expectEqual(@as(u32, if (frame < 4) 0 else 1), app.debug_under_stats.lines);
    }
    try testing.expect(app.debug_under.canvas == &app.debug_under_frame);
}
