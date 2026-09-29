// SPDX-License-Identifier: BSD-3-Clause

//! The 2D layer, headless: sprites drawn through a `.shader`'s fragment
//! stage, the frame copied for a shader that reads it, a control's box left
//! for its shader, a material's numbers kept by a scene and written by a
//! script, and render views drawn into pictures a view texture shows.

const std = @import("std");
const testing = std.testing;

const App = @import("App.zig");
const components = @import("components.zig");
const control = @import("control.zig");
const scene = @import("scene.zig");
const script = @import("script.zig");
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
    try testing.expect(app.screen.frame == null);

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
    try testing.expect(app.screen.frame != null);
    // Once before the first, and again after the plain one went down.
    try testing.expectEqual(@as(u32, 2), app.screen.copies);
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
    try testing.expectEqual(@as(usize, 1), app.control_nodes.customs.items.len);
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
    const hidden = try app.world.spawnWith(.{ Transform2D.at(0, 0), @import("inherited.zig").Appearance{ .render_layers = 0b10 } });
    _ = try app.world.spawnWith(.{ Transform2D.at(30, 30), Sprite.solid(.white, 8, 8), Parent.of(hidden) });
    _ = try app.world.spawnWith(.{ Transform2D.at(34, 34), Sprite.solid(.white, 8, 8) });
    _ = try app.step();
    try testing.expectEqual(@as(u32, 1), app.sprites.drawn);

    app.world.get(hidden, @import("inherited.zig").Appearance).?.render_layers = 0b11;
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
    for (app.control_nodes.textures.items) |held| found = found or std.meta.eql(held, gpu);
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
    try testing.expectEqual(@as(u32, 32), app.frame.width);
    try testing.expectEqual(@as(f32, 8), app.frame.shown.y);
    try testing.expect(app.screen.frame != null);
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
    try testing.expectEqual(@as(u32, 128), app.frame.width);
    try testing.expectEqual(@as(f32, 4), app.frame.scale);
    try testing.expectEqual(@as(f32, 4), app.currentView().zoom_x);
    try testing.expectEqual(@as(f32, 4), app.interface.scale);
    // With no camera, the made-at size's top left is the frame's.
    try testing.expectApproxEqAbs(@as(f32, 0), app.currentView().toScreen(.init(0, 0)).x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 128), app.currentView().toScreen(.init(32, 16)).x, 0.001);
}

const lights = @import("lights.zig");
const Appearance = @import("inherited.zig").Appearance;

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
    const map = try app.world.spawnWith(.{ Transform2D{}, @import("tilemap.zig").TileMap{ .tile_set = set } });
    _ = try app.setTile(map, 5, 3, .at(0, 0, 0));
    _ = try app.setTile(map, 5, 4, .at(0, 0, 0));
    _ = try app.step();
    try testing.expectEqual(@as(u32, 0), app.sprites.lighting.shadows_drawn);
    app.world.get(map, @import("tilemap.zig").TileMap).?.light_occlusion = true;
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
