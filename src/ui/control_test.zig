// SPDX-License-Identifier: BSD-3-Clause

//! Controls through a whole app, headless: the tree they declare, in the
//! screen and in the world, their themes and overrides, and what a scene
//! keeps of them.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");

const App = @import("../App.zig");
const Color = @import("../math/color.zig").Color;
const Parent = @import("../scene/components.zig").Parent;
const Transform2D = @import("../scene/components.zig").Transform2D;
const attr = @import("../reflect/attr.zig");
const control = @import("control.zig");
const control_tree = @import("control_tree.zig");

const BoxContainer = control.BoxContainer;
const Button = control.Button;
const CanvasLayer = control.CanvasLayer;
const CheckBox = control.CheckBox;
const ColorRect = control.ColorRect;
const Context = control_tree.Context;
const Control = control.Control;
const Entity = ecs.Entity;
const Label = control.Label;
const LineEdit = control.LineEdit;
const MarginContainer = control.MarginContainer;
const NinePatchRect = control.NinePatchRect;
const PanelContainer = control.PanelContainer;
const Popup = control.Popup;
const ProgressBar = control.ProgressBar;
const ScrollContainer = control.ScrollContainer;
const Slider = control.Slider;
const ThemeOverride = control.ThemeOverride;
const Viewport = control.Viewport;
const check_side = control_tree.check_side;
const idOf = control.idOf;
const paintCheck = control_tree.paintCheck;

test "an editor reads from a control's type that a click in its scene passes over it" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .io = testing.io });
    defer app.destroy();
    const panel = try app.world.spawnWith(.{ Control{}, PanelContainer{} });
    var found: [16]App.ComponentValue = undefined;
    var said: ?bool = null;
    for (app.componentsOf(panel, &found)) |component| {
        if (component.value.type.attribute(attr.Pickable)) |pickable| said = pickable.by_default;
    }
    try testing.expectEqual(@as(?bool, false), said);
}

test "control components build one screen-space Fluxion UI tree" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 128 }) catch return error.SkipZigTest;
    try app.useControlNodes();

    const root = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } },
        CanvasLayer{},
        BoxContainer{ .direction = .vertical, .separation = 6 },
        MarginContainer{ .margin = .all(10) },
    });
    const panel = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .fixed, .value = 100 }, .height = .{ .mode = .fixed, .value = 40 } },
        Parent.of(root),
        PanelContainer{},
        ScrollContainer{},
        Label{},
        NinePatchRect{ .texture = app.assets.white, .patch_margin = .all(4) },
    });
    try app.setText(panel, Label, "text", "Outlined");
    app.world.get(panel, Label).?.outline_width = 2;
    try app.run();

    var id: [48]u8 = undefined;
    const box = app.ui.boxOf(idOf(&id, panel)).?;
    try testing.expectEqual(@as(f32, 10), box.x);
    try testing.expectEqual(@as(f32, 10), box.y);
    try testing.expectEqual(@as(f32, 100), box.width);
    try testing.expect(app.ui.scrollOf(idOf(&id, panel)) != null);
    try testing.expectEqual(@as(usize, 1), app.interface.textures.len);
    var found_outline = false;
    var found_nine_slice = false;
    for (app.interface.commands) |command| switch (command.config) {
        .text => |text| found_outline = found_outline or text.outline != null,
        .image => |image| found_nine_slice = found_nine_slice or image.nine_slice != null,
        else => {},
    };
    try testing.expect(found_outline);
    try testing.expect(found_nine_slice);
}

test "a control that clips cuts off what is anchored in it, however deep, but not a popup" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{} });
    // A window that clips, a box in its flow that does not, and a square
    // anchored in that box and reaching past the window's bottom edge.
    const window = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .fixed, .value = 100 }, .height = .{ .mode = .fixed, .value = 100 }, .clip = true },
        Parent.of(root),
    });
    const inside = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .fixed, .value = 40 }, .height = .{ .mode = .fixed, .value = 40 } },
        Parent.of(window),
    });
    _ = try app.world.spawnWith(.{
        Control{
            .position = .anchored,
            .offset_left = 60,
            .offset_top = 80,
            .width = .{ .mode = .fixed, .value = 30 },
            .height = .{ .mode = .fixed, .value = 30 },
        },
        Parent.of(inside),
        ColorRect{ .color = .white },
    });
    // A popup pinned at the same place, 20 tall: over everything, cut off by
    // nothing.
    _ = try app.world.spawnWith(.{
        Control{
            .position = .anchored,
            .offset_left = 60,
            .offset_top = 80,
            .width = .{ .mode = .fixed, .value = 30 },
            .height = .{ .mode = .fixed, .value = 20 },
        },
        Parent.of(inside),
        ColorRect{ .color = .white },
        Popup{ .open = true, .modal = false, .centered = false },
    });
    try app.run();

    // The square is drawn inside a scissor that is the window, the popup
    // inside none.
    var id: [48]u8 = undefined;
    const window_box = app.ui.boxOf(idOf(&id, window)).?;
    var scissors: [8]@TypeOf(window_box) = undefined;
    var depth: usize = 0;
    var square_cut: ?@TypeOf(window_box) = null;
    var popup_drawn = false;
    for (app.interface.commands) |command| switch (command.config) {
        .scissor_start => {
            scissors[depth] = command.bounding_box;
            depth += 1;
        },
        .scissor_end => depth -= 1,
        .rectangle => if (command.bounding_box.height == 30 and depth > 0) {
            square_cut = scissors[depth - 1];
        } else if (command.bounding_box.height == 20) {
            popup_drawn = true;
            try testing.expectEqual(@as(usize, 0), depth);
        },
        else => {},
    };
    try testing.expectEqual(window_box, square_cut.?);
    try testing.expect(popup_drawn);
}

test "a world Viewport projects its Control tree through the camera" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{
        Transform2D.at(100, 80),
        Control{},
        Viewport{ .width = 40, .height = 20 },
        PanelContainer{},
    });
    try app.run();

    _ = root;
    const box = app.interface.commands[0].bounding_box;
    try testing.expectApproxEqAbs(@as(f32, 80), box.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), box.y, 0.001);
    try testing.expectEqual(@as(f32, 40), box.width);
    try testing.expectEqual(@as(f32, 20), box.height);
}

test "form controls share the retained Control tree" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 400, .height = 300, .frames = 2, .io = testing.io });
    defer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 128 }) catch return error.SkipZigTest;
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{}, BoxContainer{ .direction = .vertical } });
    const check = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 140 }, .height = .{ .mode = .fixed, .value = 30 } }, Parent.of(root), CheckBox{ .checked = true }, Label{} });
    try app.setText(check, Label, "text", "Enabled");
    const field = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 32 } }, Parent.of(root), LineEdit{} });
    try app.setText(field, LineEdit, "text", "Player");
    const slider = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 20 } }, Parent.of(root), Slider{ .value = 50 } });
    const progress = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 20 } }, Parent.of(root), ProgressBar{ .value = 75 } });
    try app.run();

    for ([_]Entity{ check, field, slider, progress }) |entity| {
        var id: [48]u8 = undefined;
        try testing.expect(app.ui.boxOf(idOf(&id, entity)) != null);
    }
    try testing.expectEqualStrings("Player", app.textOf(field, LineEdit, "text"));
}

test "a check box that is ticked draws a tick, made once, and one that is not draws none" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100, .frames = 2 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{} });
    const box = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 40 }, .height = .{ .mode = .fixed, .value = 20 } }, Parent.of(root), CheckBox{} });
    try app.run();
    try testing.expect(app.control_tree.check_mark.isNone());

    app.world.get(box, CheckBox).?.checked = true;
    app.frames_left = 2;
    app.running = true;
    try app.run();
    const mark = app.control_tree.check_mark;
    try testing.expect(!mark.isNone());
    try testing.expect(std.mem.indexOfScalar(rhi.Texture, app.control_tree.textures.items, app.assets.get(mark).?.gpu) != null);

    // Solid on the stroke, clear in the corner.
    var pixels: [check_side * check_side * 4]u8 = undefined;
    paintCheck(&pixels);
    const bend = (@as(usize, @intFromFloat(0.76 * check_side)) * check_side + @as(usize, @intFromFloat(0.40 * check_side))) * 4;
    try testing.expectEqual(@as(u8, 255), pixels[bend + 3]);
    try testing.expectEqual(@as(u8, 0), pixels[3]);
}

test "a control that names no theme is drawn with the project's, which the project file can change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "game.theme", .data = "{ \"fluxion_theme\": 1, \"types\": { \"Panel\": { \"styles\": { \"normal\": { \"background\": \"#123456\" } } } } }" });
    try @import("../project/Project.zig").create(testing.allocator, testing.io, root, .{ .application = .{ .name = "Themed" }, .gui = .{ .theme = "res://game.theme" } });
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .width = 200, .height = 100, .frames = 1 });
    defer app.destroy();
    try app.useControlNodes();
    const panel = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{}, PanelContainer{} });
    try app.run();

    const context: Context = .{ .app = app, .layout = &app.ui };
    try testing.expectEqual(Color.hex(0x123456), app.control_tree.resolvedStyle(context, panel, .panel, .normal).background_color);
    // The same theme is not read again a frame.
    const first = app.projectTheme();
    try testing.expect(first.eql(app.projectTheme()));

    // Named no more, the engine's own look is back.
    app.project.settings.?.gui.theme = "";
    try testing.expect(app.projectTheme().isNone());
    try testing.expect(!std.meta.eql(Color.hex(0x123456), app.control_tree.resolvedStyle(context, panel, .panel, .normal).background_color));
}

test "a line edit with the keyboard says how a phone's bar is to look: as its theme draws it, with its placeholder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "game.theme", .data =
        \\{ "fluxion_theme": 1, "types": {
        \\  "LineEdit": { "styles": { "normal": { "background": "#204060", "border_color": "#a0b0c0", "border": 2, "corners": 5, "font_color": "#f0e0d0" } } },
        \\  "Button": { "styles": { "normal": { "background": "#ff8800" } } },
        \\  "Panel": { "styles": { "normal": { "background": "#101010" } } } } }
    });
    try @import("../project/Project.zig").create(testing.allocator, testing.io, root, .{ .application = .{ .name = "Themed" }, .gui = .{ .theme = "res://game.theme" } });
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io, .root = root, .width = 200, .height = 100, .frames = 1 });
    defer app.destroy();
    try app.useControlNodes();
    const canvas = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{} });
    const field = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 32 } }, Parent.of(canvas), LineEdit{} });
    try app.setText(field, LineEdit, "placeholder_text", "Your name");
    try app.run();
    // Nothing has the keyboard: nothing to say.
    try testing.expect(app.interface.field_style == null);

    app.grabFocus(field);
    app.frames_left = 2;
    app.running = true;
    try app.run();
    const said = app.interface.field_style.?;
    try testing.expectEqualStrings("Your name", said.hint);
    const look = said.look.?;
    try testing.expectEqual(@as(u32, 0xFF204060), look.field.background);
    try testing.expectEqual(@as(u32, 0xFFA0B0C0), look.field.border);
    try testing.expectEqual(@as(f32, 2) * app.interface.scale, look.field.border_width);
    try testing.expectEqual(@as(f32, 5) * app.interface.scale, look.field.corner_radius);
    try testing.expectEqual(@as(u32, 0xFFFF8800), look.button.background);
    try testing.expectEqual(@as(u32, 0xFF101010), look.bar);
    // No face of its theme's own: the system's, as the interface's is.
    try testing.expectEqualStrings("", look.font);
}

test "a control's own overrides change its own part and not its children's, and a scene keeps them" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 200, .height = 100, .frames = 1 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{ Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, CanvasLayer{}, PanelContainer{} });
    const slider = try app.world.spawnWith(.{ Control{}, Parent.of(root), Slider{ .value = 50 }, ThemeOverride{
        .override_background = true,
        .background = .hex(0xFF0000),
        .override_font_size = true,
        .font_size = 30,
    } });
    try app.run();

    const context: Context = .{ .app = app, .layout = &app.ui };
    const track = app.control_tree.resolvedStyle(context, slider, .slider_track, .normal);
    try testing.expectEqual(Color.hex(0xFF0000), track.background_color);
    try testing.expectEqual(@as(u16, 30), track.font_size);
    // Its fill, and the panel it sits in, are the theme's.
    const fill = app.control_tree.resolvedStyle(context, slider, .slider_fill, .normal);
    try testing.expect(!std.meta.eql(Color.hex(0xFF0000), fill.background_color));
    const panel = app.control_tree.resolvedStyle(context, root, .panel, .normal);
    try testing.expect(!std.meta.eql(Color.hex(0xFF0000), panel.background_color));

    // Written and read back: the switches and the values both.
    const text = try @import("../scene/scene.zig").write(app, testing.allocator, .{});
    defer testing.allocator.free(text);
    app.clearWorld();
    _ = try @import("../scene/scene.zig").read(app, text, .{});
    var found = false;
    for (app.world.archetypeSlice()) |*archetype| for (archetype.entities.items) |entity| {
        const held = app.world.get(entity, ThemeOverride) orelse continue;
        try testing.expect(held.override_background and held.override_font_size and !held.override_border);
        try testing.expectEqual(@as(u16, 30), held.font_size);
        found = true;
    };
    try testing.expect(found);
}

test "a scene keeps the theme a control names, what it is drawn as, and a button's words" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.addTheme("ui.theme",
        \\{ "fluxion_theme": 1, "types": { "Danger": { "base_type": "Button", "styles": { "normal": { "background": "#C8434F" } } } } }
    );
    const loaded = try @import("../scene/scene.zig").read(app,
        \\{ "fluxion_scene": 3, "entities": [
        \\  { "uuid": "40000000-0000-4000-8000-000000000001", "name": "Delete",
        \\    "Control": { "theme": "ui.theme", "type_variation": "Danger" },
        \\    "Button": { "text": "Delete" } }
        \\] }
    , .{});
    _ = loaded;

    const entity = app.find("Delete").?;
    try testing.expectEqualStrings("Danger", app.textOf(entity, Control, "type_variation"));
    try testing.expectEqualStrings("Delete", app.textOf(entity, Button, "text"));
    try testing.expect(!app.world.get(entity, Control).?.theme.isNone());

    const style = app.control_tree.resolvedStyle(.{ .app = app, .layout = &app.ui }, entity, .button, .normal);
    try testing.expectEqual(Color.parse("#C8434F").?, style.background_color);
}

test "a control is drawn from the theme the control above it names" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 200, .frames = 1 });
    defer app.destroy();
    try app.useControlNodes();

    const handle = try app.addTheme("ui.theme",
        \\{
        \\  "fluxion_theme": 1,
        \\  "font_size": 18,
        \\  "types": {
        \\    "Button": {
        \\      "font_color": "#DDEEFF",
        \\      "styles": { "pressed": { "background": "#AABBCC", "padding": [9, 9] } }
        \\    },
        \\    "Loud": { "base_type": "Button", "font_size": 23 }
        \\  }
        \\}
    );
    const root = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow }, .theme = handle },
        CanvasLayer{},
    });
    const button = try app.world.spawnWith(.{ Control{}, Parent.of(root), Button{} });
    try app.setText(button, Button, "text", "Styled");
    const shouty = try app.world.spawnWith(.{ Control{}, Parent.of(root), Button{} });
    try app.setText(shouty, Control, "type_variation", "Loud");
    try app.setText(shouty, Button, "text", "Loud");
    try app.run();

    const context: Context = .{ .app = app, .layout = &app.ui };
    const style = app.control_tree.resolvedStyle(context, button, .button, .pressed);
    try testing.expectEqual(Color.hex(0xAABBCC), style.background_color);
    try testing.expectEqual(Color.hex(0xDDEEFF), style.text_color);
    try testing.expectEqual(@as(u16, 18), style.font_size);
    try testing.expectEqual(@as(u16, 9), style.padding.left);
    // Nothing was said about the border, so the engine's own look holds.
    try testing.expectEqual(@import("theme.zig").Palette.border_width, style.border_width);

    // The theme is the root's, and the variation is this control's own.
    const louder = app.control_tree.resolvedStyle(context, shouty, .button, .pressed);
    try testing.expectEqual(@as(u16, 23), louder.font_size);
    try testing.expectEqual(Color.hex(0xAABBCC), louder.background_color);
}
