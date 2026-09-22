// SPDX-License-Identifier: BSD-3-Clause

//! Scene components that declare Fluxion UI. `Control` is the common box;
//! the other components add layout, appearance or behaviour to it.

const std = @import("std");
const ecs = @import("fluxion_ecs");
const rhi = @import("fluxion_rhi");
const ui = @import("fluxion_ui");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const Color = @import("color.zig").Color;
const Interface = @import("interface.zig");
const Region = @import("components.zig").Region;
const Transform2D = @import("components.zig").Transform2D;
const View = @import("render/view.zig").View;
const attr = @import("attr.zig");

pub const Entity = ecs.Entity;

pub fn idOf(buffer: []u8, entity: Entity) []const u8 {
    return std.fmt.bufPrint(buffer, "control-{d}-{d}", .{ entity.index, entity.generation }) catch "control";
}

pub const Size = extern struct {
    mode: Mode = .fit,
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    weight: f32 = 1,

    pub const Mode = enum(u8) { fit, fixed, grow, percent, ratio };

    fn layout(self: Size) ui.Sizing {
        return switch (self.mode) {
            .fit => .{ .kind = .fit, .min = self.min, .max = self.max },
            .fixed => .{ .kind = .fixed, .min = self.value, .max = self.value },
            .grow => .{ .kind = .grow, .min = self.min, .max = self.max, .weight = self.weight },
            .percent => .{ .kind = .percent, .min = self.min, .max = self.max, .fraction = self.value },
            .ratio => .{ .kind = .ratio, .min = self.min, .max = self.max, .fraction = self.value },
        };
    }
};

pub const Insets = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(value: u16) Insets {
        return .{ .left = value, .right = value, .top = value, .bottom = value };
    }

    fn padding(self: Insets) ui.Padding {
        return .{ .left = self.left, .right = self.right, .top = self.top, .bottom = self.bottom };
    }
};

pub const Corners = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Corners {
        return .{ .top_left = value, .top_right = value, .bottom_right = value, .bottom_left = value };
    }

    fn radius(self: Corners) ui.CornerRadius {
        return .{
            .top_left = self.top_left,
            .top_right = self.top_right,
            .bottom_right = self.bottom_right,
            .bottom_left = self.bottom_left,
        };
    }
};

pub const Theme = extern struct {
    fallback: Entity = .none,
    font: Assets.FontHandle = .none,
    font_size: u16 = 16,
    text_color: Color = .white,
    disabled_text_color: Color = .hex(0x808080),
    corner_radius: f32 = 6,
    border_width: u16 = 1,
    padding: Insets = .all(6),
    pub const reflect_name = "Theme";
};

pub const ThemePalette = extern struct {
    panel_color: Color = .hex(0x20242A),
    field_color: Color = .hex(0x171A1F),
    button_color: Color = .hex(0x3A6EA5),
    button_hover_color: Color = .hex(0x4B82BA),
    button_pressed_color: Color = .hex(0x285780),
    disabled_color: Color = .hex(0x30343A),
    accent_color: Color = .hex(0x3A80D8),
    border_color: Color = .hex(0x59616B),
    focus_color: Color = .hex(0x72A7E8),
    pub const reflect_name = "ThemePalette";
};

pub const StyleBox = extern struct {
    theme: Entity = .none,
    role: Role = .panel,
    state: State = .normal,
    background_color: Color = .transparent,
    border_color: Color = .transparent,
    border_width: u16 = 0,
    corner_radius: Corners = .{},
    padding: Insets = .{},

    pub const Role = enum(u8) { panel, button, check_box, line_edit, slider_track, slider_fill, progress_track, progress_fill, tab, tab_active, focus };
    pub const State = enum(u8) { normal, hover, pressed, disabled, focus };
    pub const reflect_name = "StyleBox";
};

pub const StyleBoxTexture = extern struct {
    texture: Assets.TextureHandle = .none,
    tint: Color = .white,
    source_left: f32 = 0.25,
    source_right: f32 = 0.25,
    source_top: f32 = 0.25,
    source_bottom: f32 = 0.25,
    patch_margin: Insets = .all(8),
    pub const reflect_name = "StyleBoxTexture";
    pub const reflect_fields = .{
        .source_left = .{attr.Range{ .min = 0, .max = 1 }},
        .source_right = .{attr.Range{ .min = 0, .max = 1 }},
        .source_top = .{attr.Range{ .min = 0, .max = 1 }},
        .source_bottom = .{attr.Range{ .min = 0, .max = 1 }},
    };
};

pub const StyleBoxText = extern struct {
    text_color: Color = .white,
    font: Assets.FontHandle = .none,
    font_size: u16 = 0,
    pub const reflect_name = "StyleBoxText";
};

/// The rectangular base of every UI entity.
pub const Control = extern struct {
    parent: Entity = .none,
    theme: Entity = .none,
    width: Size = .{},
    height: Size = .{},
    position: Position = .flow,
    anchor_x: AnchorX = .left,
    anchor_y: AnchorY = .top,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    visible: bool = true,
    clip: bool = false,
    mouse_filter: MouseFilter = .pass,
    z_index: i16 = 0,

    pub const Position = enum(u8) { flow, anchored };
    pub const AnchorX = enum(u8) { left, center, right };
    pub const AnchorY = enum(u8) { top, center, bottom };
    pub const MouseFilter = enum(u8) { stop, pass, ignore };

    pub const reflect_name = "Control";
    pub const reflect_fields = .{
        .parent = .{attr.Doc{ .text = "The UI entity whose box contains this one" }},
        .offset_x = .{attr.Unit{ .text = "px" }},
        .offset_y = .{attr.Unit{ .text = "px" }},
    };
};

/// A screen-space UI root, independent of the 2D camera.
pub const CanvasLayer = extern struct {
    layer: i16 = 0,
    visible: bool = true,
    pub const reflect_name = "CanvasLayer";
};

/// A UI surface. In `.world` mode its entity's `Transform2D` is projected
/// through the active camera and the surface behaves as one Fluxion UI tree.
pub const Viewport = extern struct {
    space: Space = .world,
    width: f32 = 320,
    height: f32 = 180,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    layer: i16 = 0,
    visible: bool = true,

    pub const Space = enum(u8) { screen, world };
    pub const reflect_name = "Viewport";
    pub const reflect_fields = .{
        .width = .{ attr.Range{ .min = 1, .max = 16384 }, attr.Unit{ .text = "px" } },
        .height = .{ attr.Range{ .min = 1, .max = 16384 }, attr.Unit{ .text = "px" } },
        .offset_x = .{attr.Unit{ .text = "px" }},
        .offset_y = .{attr.Unit{ .text = "px" }},
    };
};

pub const BoxContainer = extern struct {
    direction: Direction = .vertical,
    separation: u16 = 0,
    wrap: bool = false,
    wrap_separation: u16 = 0,
    alignment_x: AlignX = .left,
    alignment_y: AlignY = .top,

    pub const Direction = enum(u8) { horizontal, vertical };
    pub const AlignX = enum(u8) { left, center, right };
    pub const AlignY = enum(u8) { top, center, bottom };
    pub const reflect_name = "BoxContainer";
};

pub const MarginContainer = extern struct {
    margin: Insets = .{},
    pub const reflect_name = "MarginContainer";
};

pub const CenterContainer = extern struct {
    horizontal: bool = true,
    vertical: bool = true,
    pub const reflect_name = "CenterContainer";
};

pub const ScrollContainer = extern struct {
    horizontal: bool = false,
    vertical: bool = true,
    drag: bool = true,
    scrollbar: bool = true,
    pub const reflect_name = "ScrollContainer";
};

pub const PanelContainer = extern struct {
    color: Color = .transparent,
    border_color: Color = .transparent,
    border_width: u16 = 0,
    corner_radius: Corners = .{},
    pub const reflect_name = "PanelContainer";
};

pub const Label = extern struct {
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,
    font: Assets.FontHandle = .none,
    font_size: u16 = 16,
    color: Color = .white,
    outline_color: Color = .black,
    outline_width: u16 = 0,
    wrap: Wrap = .words,
    use_theme: bool = true,

    pub const capacity = 127;
    pub const Wrap = enum(u8) { words, newline, none };
    pub const reflect_name = "Label";
    pub const reflect_attributes = .{attr.Property{ .name = "text", .get = "slice", .set = "set" }};
    pub const reflect_fields = .{
        .bytes = .{attr.Hidden{}},
        .len = .{attr.Hidden{}},
        .font_size = .{ attr.Range{ .min = 1, .max = 512 }, attr.Unit{ .text = "px" } },
    };
    pub const reflect_methods = .{
        .set = .{attr.Multiline{}},
        .slice = .{},
    };

    pub fn of(text: []const u8) Label {
        var out: Label = .{};
        out.set(text);
        return out;
    }

    pub fn set(self: *Label, text: []const u8) void {
        var cut = @min(text.len, capacity);
        while (cut > 0 and cut < text.len and text[cut] & 0xC0 == 0x80) cut -= 1;
        @memcpy(self.bytes[0..cut], text[0..cut]);
        self.len = @intCast(cut);
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..@min(self.len, capacity)];
    }
};

pub const Button = extern struct {
    disabled: bool = false,
    hovered: bool = false,
    held: bool = false,
    pub const reflect_name = "Button";
    pub const reflect_fields = .{ .hovered = .{attr.ReadOnly{}}, .held = .{attr.ReadOnly{}} };
    pub const signals = .{ .pressed = struct {} };
};

pub const CheckBox = extern struct {
    checked: bool = false,
    disabled: bool = false,
    box_color: Color = .hex(0x30343A),
    check_color: Color = .white,
    pub const reflect_name = "CheckBox";
    pub const signals = .{ .toggled = struct { checked: bool } };
};

pub const LineEdit = extern struct {
    bytes: [capacity]u8 = @splat(0),
    len: u16 = 0,
    placeholder: [capacity]u8 = @splat(0),
    placeholder_len: u16 = 0,
    font_size: u16 = 16,
    text_color: Color = .white,
    placeholder_color: Color = .hex(0x808080),
    cursor_color: Color = .white,
    multiline: bool = false,
    password: bool = false,
    disabled: bool = false,
    use_theme: bool = true,

    pub const capacity = 255;
    pub const reflect_name = "LineEdit";
    pub const reflect_attributes = .{
        attr.Property{ .name = "text", .get = "slice", .set = "set" },
        attr.Property{ .name = "placeholder_text", .get = "placeholderSlice", .set = "setPlaceholder" },
    };
    pub const reflect_fields = .{
        .bytes = .{attr.Hidden{}},
        .len = .{attr.Hidden{}},
        .placeholder = .{attr.Hidden{}},
        .placeholder_len = .{attr.Hidden{}},
        .font_size = .{ attr.Range{ .min = 1, .max = 512 }, attr.Unit{ .text = "px" } },
    };
    pub const reflect_methods = .{ .set = .{attr.Multiline{}}, .slice = .{}, .setPlaceholder = .{}, .placeholderSlice = .{} };
    pub const signals = .{ .changed = struct {}, .submitted = struct {} };

    pub fn of(text: []const u8) LineEdit {
        var out: LineEdit = .{};
        out.set(text);
        return out;
    }

    pub fn set(self: *LineEdit, text: []const u8) void {
        self.len = copyText(&self.bytes, text);
    }

    pub fn slice(self: *const LineEdit) []const u8 {
        return self.bytes[0..@min(self.len, capacity)];
    }

    pub fn setPlaceholder(self: *LineEdit, text: []const u8) void {
        self.placeholder_len = copyText(&self.placeholder, text);
    }

    pub fn placeholderSlice(self: *const LineEdit) []const u8 {
        return self.placeholder[0..@min(self.placeholder_len, capacity)];
    }
};

pub const Slider = extern struct {
    min: f32 = 0,
    max: f32 = 100,
    value: f32 = 0,
    step: f32 = 1,
    vertical: bool = false,
    disabled: bool = false,
    track_color: Color = .hex(0x30343A),
    fill_color: Color = .hex(0x3A80D8),
    pub const reflect_name = "Slider";
    pub const signals = .{ .changed = struct { value: f32 } };
};

pub const ProgressBar = extern struct {
    min: f32 = 0,
    max: f32 = 100,
    value: f32 = 0,
    show_percentage: bool = true,
    track_color: Color = .hex(0x30343A),
    fill_color: Color = .hex(0x3A80D8),
    text_color: Color = .white,
    pub const reflect_name = "ProgressBar";
};

pub const TabContainer = extern struct {
    current: u16 = 0,
    separation: u16 = 4,
    tab_color: Color = .hex(0x30343A),
    active_color: Color = .hex(0x3A80D8),
    pub const reflect_name = "TabContainer";
    pub const signals = .{ .tab_changed = struct { index: u16 } };
};

pub const TextureRect = extern struct {
    texture: Assets.TextureHandle = .none,
    tint: Color = .white,
    region: Region = .full,
    stretch: Stretch = .fill,

    pub const Stretch = enum(u8) { fill, contain, cover };
    pub const reflect_name = "TextureRect";
};

pub const NinePatchRect = extern struct {
    texture: Assets.TextureHandle = .none,
    tint: Color = .white,
    region: Region = .full,
    source_left: f32 = 0.25,
    source_right: f32 = 0.25,
    source_top: f32 = 0.25,
    source_bottom: f32 = 0.25,
    patch_margin: Insets = .all(8),

    pub const reflect_name = "NinePatchRect";
    pub const reflect_fields = .{
        .source_left = .{attr.Range{ .min = 0, .max = 1 }},
        .source_right = .{attr.Range{ .min = 0, .max = 1 }},
        .source_top = .{attr.Range{ .min = 0, .max = 1 }},
        .source_bottom = .{attr.Range{ .min = 0, .max = 1 }},
    };
};

pub const Nodes = struct {
    textures: std.ArrayList(rhi.Texture) = .empty,
    styles: std.ArrayList(StyleEntry) = .empty,
    preview_ui: ?ui.Ui = null,
    preview_interface: Interface = .{},
    enabled: bool = false,

    pub fn deinit(self: *Nodes, gpa: std.mem.Allocator) void {
        self.textures.deinit(gpa);
        self.styles.deinit(gpa);
        if (self.preview_ui) |*held_ui| held_ui.deinit();
        self.preview_interface.deinit();
        self.* = .{};
    }

    pub fn enable(self: *Nodes, app: *App) !void {
        if (self.enabled) return;
        self.enabled = true;
        try app.addSystem(.ui, "control nodes", draw);
    }

    fn draw(app: *App) !void {
        const self = &app.control_nodes;
        try self.drawRoots(.{ .app = app, .layout = &app.ui, .interactive = true });
        app.interface.textures = self.textures.items;
    }

    fn drawRoots(self: *Nodes, context: Context) !void {
        const app = context.app;
        self.textures.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
        for (app.world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |entity| {
                const style = app.world.get(entity, StyleBox) orelse continue;
                try self.styles.append(app.gpa, .{ .theme = style.theme, .role = style.role, .state = style.state, .entity = entity });
            }
        }
        for (app.world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |entity| {
                if (!app.world.has(entity, Control)) continue;
                if (app.world.get(entity, CanvasLayer)) |layer| {
                    if (layer.visible) try self.root(context, entity, .screen, 0, 0, layer.layer);
                } else if (app.world.get(entity, Viewport)) |viewport| {
                    if (!viewport.visible) continue;
                    try self.root(context, entity, viewport.space, viewport.width, viewport.height, viewport.layer);
                }
            }
        }
    }

    fn root(self: *Nodes, context: Context, entity: Entity, space: Viewport.Space, width: f32, height: f32, layer: i16) !void {
        const app = context.app;
        const layout = context.layout;
        const control = app.world.get(entity, Control) orelse return;
        if (!control.visible or !control.parent.isNone()) return;
        var declared = self.declaration(context, entity, control.*);
        declared.z_index += layer;
        declared.floating = null;
        if (width > 0) declared.width = .fixed(width) else declared.width = .grow;
        if (height > 0) declared.height = .fixed(height) else declared.height = .grow;

        if (space == .world and context.view == null) {
            const place = app.worldTransform(entity) orelse return;
            const viewport = app.world.get(entity, Viewport).?;
            app.openWorldUi(.init(place.x, place.y), declared, .{
                .offset = .{ .x = viewport.offset_x, .y = viewport.offset_y },
                .z_index = layer,
            });
        } else {
            if (space == .world) {
                const place = app.worldTransform(entity) orelse return;
                const at = context.view.?.toScreen(.init(place.x, place.y));
                declared.floating = .{ .attach = .root, .offset = .{ .x = at.x - width / 2, .y = at.y - height / 2 }, .z_index = layer };
            } else declared.floating = .{ .attach = .root, .z_index = layer };
            layout.open(declared);
        }
        defer layout.close();
        try self.content(context, entity);
        try self.children(context, entity, 0);
    }

    fn children(self: *Nodes, context: Context, parent: Entity, depth: u8) anyerror!void {
        const app = context.app;
        if (depth >= 32) return;
        var found: [256]Entity = undefined;
        const children_of = app.childrenOf(parent, &found);
        if (app.world.get(parent, TabContainer)) |tab_container| {
            try self.drawTabs(context, parent, children_of, tab_container, depth);
            return;
        }
        for (children_of) |entity| {
            const control = app.world.get(entity, Control) orelse continue;
            if (!control.visible) continue;
            try self.node(context, entity, control.*, depth);
        }
    }

    fn node(self: *Nodes, context: Context, entity: Entity, control: Control, depth: u8) anyerror!void {
        context.layout.open(self.declaration(context, entity, control));
        defer context.layout.close();
        try self.content(context, entity);
        try self.children(context, entity, depth + 1);
    }

    fn declaration(self: *Nodes, context: Context, entity: Entity, control: Control) ui.Declaration {
        const app = context.app;
        var id: [48]u8 = undefined;
        const name = idOf(&id, entity);
        var out: ui.Declaration = .{
            .id = name,
            .width = control.width.layout(),
            .height = control.height.layout(),
            .clip = if (control.clip) .both else .none,
            .z_index = control.z_index,
            .capture = control.mouse_filter == .stop,
        };
        if (control.position == .anchored) out.floating = .{
            .anchor = .{
                .element_x = alignX(control.anchor_x),
                .element_y = alignY(control.anchor_y),
                .parent_x = alignX(control.anchor_x),
                .parent_y = alignY(control.anchor_y),
            },
            .offset = .{ .x = control.offset_x, .y = control.offset_y },
        };
        if (app.world.get(entity, BoxContainer)) |box| {
            out.direction = if (box.direction == .horizontal) .left_to_right else .top_to_bottom;
            out.gap = box.separation;
            out.wrap = box.wrap;
            out.wrap_gap = box.wrap_separation;
            out.align_x = boxAlignX(box.alignment_x);
            out.align_y = boxAlignY(box.alignment_y);
        }
        if (app.world.get(entity, MarginContainer)) |margin| out.padding = margin.margin.padding();
        if (app.world.get(entity, CenterContainer)) |center| {
            if (center.horizontal) out.align_x = .center;
            if (center.vertical) out.align_y = .center;
        }
        if (app.world.get(entity, ScrollContainer)) |scroll| out.clip = .{
            .horizontal = scroll.horizontal,
            .vertical = scroll.vertical,
            .scroll_x = scroll.horizontal,
            .scroll_y = scroll.vertical,
            .no_drag_scroll = !scroll.drag,
            .scrollbar = if (scroll.scrollbar) .{} else null,
        };
        if (app.world.get(entity, PanelContainer)) |panel| {
            out.background_color = color(panel.color);
            out.corner_radius = panel.corner_radius.radius();
            if (panel.border_width > 0) out.border = .all(color(panel.border_color), panel.border_width);
        }
        if (app.world.get(entity, ProgressBar)) |progress| out.background_color = color(progress.track_color);
        if (app.world.get(entity, TextureRect)) |picture| if (self.image(app, picture.texture, picture.tint, picture.region)) |drawn| {
            out.image = drawn;
            switch (picture.stretch) {
                .fill => {},
                .contain => out.contain = ratio(app, picture.texture),
                .cover => out.cover = ratio(app, picture.texture),
            }
        };
        if (app.world.get(entity, NinePatchRect)) |picture| if (self.image(app, picture.texture, picture.tint, picture.region)) |drawn| {
            out.image = drawn;
            out.image.?.nine_slice = .{
                .source_left = picture.source_left,
                .source_right = picture.source_right,
                .source_top = picture.source_top,
                .source_bottom = picture.source_bottom,
                .border = picture.patch_margin.padding(),
            };
        };
        if ((app.world.has(entity, Button) or app.world.has(entity, CheckBox) or app.world.has(entity, Slider)) and control.mouse_filter != .ignore) {
            out.focus = .{};
            out.cursor = .pointing_hand;
            out.capture = true;
        }
        if (roleOf(app, entity)) |role| if (self.resolvedStyle(context, entity, role, stateOf(context, entity))) |style| self.applyStyle(app, &out, style);
        return out;
    }

    fn content(self: *Nodes, context: Context, entity: Entity) !void {
        const app = context.app;
        if (app.world.get(entity, CheckBox)) |checkbox| {
            try checkboxContent(context, entity, checkbox, self.resolvedStyle(context, entity, .check_box, stateOf(context, entity)));
            return;
        }
        if (app.world.get(entity, LineEdit)) |line| {
            try lineEditContent(context, entity, line, self.resolvedStyle(context, entity, .line_edit, stateOf(context, entity)));
            return;
        }
        if (app.world.get(entity, Slider)) |slider| {
            try sliderContent(context, entity, slider, self.resolvedStyle(context, entity, .slider_fill, stateOf(context, entity)));
            return;
        }
        if (app.world.get(entity, ProgressBar)) |progress| {
            progressContent(context.layout, progress, self.resolvedStyle(context, entity, .progress_fill, .normal));
            return;
        }
        if (app.world.get(entity, Label)) |label| drawLabel(context, label, self.resolvedStyle(context, entity, roleOf(app, entity) orelse .panel, stateOf(context, entity)));
        if (app.world.get(entity, Button)) |button| {
            const control = app.world.get(entity, Control).?;
            if (control.mouse_filter == .ignore) {
                button.hovered = false;
                button.held = false;
                return;
            }
            button.hovered = context.interactive and context.layout.hovered();
            button.held = context.interactive and !button.disabled and context.layout.pressed();
            if (context.interactive and !button.disabled and context.layout.justReleased()) try app.signal(entity, Button, .pressed).emit(.{});
        }
    }

    fn drawTabs(self: *Nodes, context: Context, parent: Entity, children_of: []const Entity, tab_container: *TabContainer, depth: u8) !void {
        const app = context.app;
        const layout = context.layout;
        layout.open(.{ .width = .grow, .height = .fit, .gap = tab_container.separation });
        for (children_of, 0..) |child, index| {
            if (!app.world.has(child, Control)) continue;
            var id: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&id, "tab-{d}-{d}", .{ child.index, child.generation }) catch "tab";
            const state: StyleBox.State = if (!context.interactive)
                .normal
            else if (layout.isElementPressed(name))
                .pressed
            else if (layout.isPointerOver(name))
                .hover
            else if (layout.isFocused(name))
                .focus
            else
                .normal;
            const role: StyleBox.Role = if (index == tab_container.current) .tab_active else .tab;
            const style = self.resolvedStyle(context, parent, role, state);
            var tab_decl: ui.Declaration = .{
                .id = name,
                .padding = .xy(10, 6),
                .background_color = color(if (index == tab_container.current) tab_container.active_color else tab_container.tab_color),
                .focus = .{},
                .capture = true,
            };
            if (style) |held| self.applyStyle(app, &tab_decl, held);
            layout.open(tab_decl);
            layout.text(app.nameOf(child) orelse "Tab", .{ .wrap = .none, .font = app.interface.addFont(if (style) |held| held.font else .none) catch 0, .font_size = if (style) |held| held.font_size else 16, .color = color(if (style) |held| held.text_color else .white) });
            if (context.interactive and layout.justReleased() and index != tab_container.current) {
                tab_container.current = @intCast(index);
                try app.signal(parent, TabContainer, .tab_changed).emit(.{ .index = tab_container.current });
            }
            layout.close();
        }
        layout.close();
        if (tab_container.current >= children_of.len) tab_container.current = 0;
        if (children_of.len == 0) return;
        const child = children_of[tab_container.current];
        const control = app.world.get(child, Control) orelse return;
        if (control.visible) try self.node(context, child, control.*, depth);
    }

    fn resolvedStyle(self: *Nodes, context: Context, entity: Entity, role: StyleBox.Role, state: StyleBox.State) ?ResolvedStyle {
        const app = context.app;
        var theme_entity = themeOf(app, entity) orelse return null;
        const base_theme = app.world.get(theme_entity, Theme) orelse return null;
        const base = themedStyle(base_theme.*, app.world.get(theme_entity, ThemePalette) orelse &.{}, role, state);
        for (0..9) |_| {
            if (self.findStyle(theme_entity, role, state)) |style| return inheritStyle(app, base, style);
            if (state != .normal) if (self.findStyle(theme_entity, role, .normal)) |style| return inheritStyle(app, base, style);
            if (state == .focus) if (self.findStyle(theme_entity, .focus, .normal)) |style| return inheritStyle(app, base, style);
            const theme = app.world.get(theme_entity, Theme) orelse break;
            if (theme.fallback.isNone() or !app.world.isAlive(theme.fallback)) break;
            theme_entity = theme.fallback;
        }
        return base;
    }

    fn findStyle(self: *Nodes, theme: Entity, role: StyleBox.Role, state: StyleBox.State) ?Entity {
        var found: ?Entity = null;
        for (self.styles.items) |entry| {
            if (!entry.theme.eql(theme) or entry.role != role or entry.state != state) continue;
            if (found == null or entry.entity.index > found.?.index or (entry.entity.index == found.?.index and entry.entity.generation > found.?.generation)) found = entry.entity;
        }
        return found;
    }

    fn applyStyle(self: *Nodes, app: *App, out: *ui.Declaration, style: ResolvedStyle) void {
        out.background_color = color(style.background_color);
        out.border = if (style.border_width > 0) .all(color(style.border_color), style.border_width) else .{};
        out.corner_radius = style.corner_radius.radius();
        out.padding = style.padding.padding();
        if (self.image(app, style.texture, style.tint, .full)) |drawn| {
            out.image = drawn;
            out.image.?.nine_slice = .{
                .source_left = style.source_left,
                .source_right = style.source_right,
                .source_top = style.source_top,
                .source_bottom = style.source_bottom,
                .border = style.patch_margin.padding(),
            };
        }
    }

    pub fn preview(self: *Nodes, app: *App, into: rhi.Texture, view: View, width: f32, height: f32, faces: Interface.Faces) !void {
        if (self.preview_ui == null) self.preview_ui = .init(app.gpa);
        const layout = &self.preview_ui.?;
        if (faces.len > 0) layout.setMeasurer(Interface.measurer(&faces));
        self.preview_interface.scale = app.interface.scale;
        layout.begin(self.preview_interface.surface(width, height));
        layout.open(.{ .width = .grow, .height = .grow });
        try self.drawRoots(.{ .app = app, .layout = layout, .view = view });
        layout.close();
        self.preview_interface.commands = try layout.end();
        self.preview_interface.textures = self.textures.items;
        try self.preview_interface.draw(app.gpa, &app.device, faces.slice(), .{ .texture = into }, width, height);
    }

    pub fn previewBox(self: *Nodes, entity: Entity) ?ui.BoundingBox {
        const layout = if (self.preview_ui) |*held| held else return null;
        var id: [48]u8 = undefined;
        return layout.boxOf(idOf(&id, entity));
    }

    fn image(self: *Nodes, app: *App, handle: Assets.TextureHandle, tint: Color, region: Region) ?ui.layout.Image {
        const texture = app.assets.get(handle) orelse return null;
        var slot: ?u32 = null;
        for (self.textures.items, 0..) |held, index| if (std.meta.eql(held, texture.gpu)) {
            slot = @intCast(index);
            break;
        };
        if (slot == null) {
            self.textures.append(app.gpa, texture.gpu) catch return null;
            slot = @intCast(self.textures.items.len - 1);
        }
        return .{
            .texture = slot.?,
            .source = .init(region.u0, region.v0, region.u1 - region.u0, region.v1 - region.v0),
            .tint = color(tint),
        };
    }
};

const Context = struct {
    app: *App,
    layout: *ui.Ui,
    interactive: bool = false,
    view: ?View = null,
};

const StyleEntry = struct {
    theme: Entity,
    role: StyleBox.Role,
    state: StyleBox.State,
    entity: Entity,
};

const ResolvedStyle = struct {
    background_color: Color = .transparent,
    border_color: Color = .transparent,
    border_width: u16 = 0,
    corner_radius: Corners = .{},
    padding: Insets = .{},
    texture: Assets.TextureHandle = .none,
    tint: Color = .white,
    source_left: f32 = 0.25,
    source_right: f32 = 0.25,
    source_top: f32 = 0.25,
    source_bottom: f32 = 0.25,
    patch_margin: Insets = .all(8),
    text_color: Color = .white,
    font: Assets.FontHandle = .none,
    font_size: u16 = 16,
};

fn roleOf(app: *App, entity: Entity) ?StyleBox.Role {
    const world = &app.world;
    if (world.has(entity, Button)) return .button;
    if (world.has(entity, CheckBox)) return .check_box;
    if (world.has(entity, LineEdit)) return .line_edit;
    if (world.has(entity, Slider)) return .slider_track;
    if (world.has(entity, ProgressBar)) return .progress_track;
    if (world.has(entity, PanelContainer)) return .panel;
    return null;
}

fn stateOf(context: Context, entity: Entity) StyleBox.State {
    const app = context.app;
    if (app.world.get(entity, Button)) |button| if (button.disabled) return .disabled;
    if (app.world.get(entity, CheckBox)) |checkbox| if (checkbox.disabled) return .disabled;
    if (app.world.get(entity, LineEdit)) |line| if (line.disabled) return .disabled;
    if (app.world.get(entity, Slider)) |slider| if (slider.disabled) return .disabled;
    if (!context.interactive) return .normal;
    var id: [64]u8 = undefined;
    const name = idOf(&id, entity);
    if (context.layout.isElementPressed(name)) return .pressed;
    if (context.layout.isPointerOver(name)) return .hover;
    if (context.layout.isFocused(name)) return .focus;
    if (app.world.has(entity, LineEdit)) {
        const input = std.fmt.bufPrint(&id, "control-{d}-{d}-input", .{ entity.index, entity.generation }) catch return .normal;
        if (context.layout.isFocused(input)) return .focus;
    }
    return .normal;
}

fn themeOf(app: *App, entity: Entity) ?Entity {
    var at = entity;
    for (0..33) |_| {
        if (app.world.get(at, Control)) |control| {
            if (!control.theme.isNone() and app.world.has(control.theme, Theme)) return control.theme;
            if (app.world.has(at, Theme)) return at;
            if (control.parent.isNone() or !app.world.isAlive(control.parent)) return null;
            at = control.parent;
        } else return if (app.world.has(at, Theme)) at else null;
    }
    return null;
}

fn themedStyle(theme: Theme, palette: *const ThemePalette, role: StyleBox.Role, state: StyleBox.State) ResolvedStyle {
    const disabled = state == .disabled;
    const background: Color = switch (role) {
        .panel => palette.panel_color,
        .line_edit => if (disabled) palette.disabled_color else palette.field_color,
        .button, .tab, .tab_active => if (disabled)
            palette.disabled_color
        else switch (state) {
            .hover, .focus => palette.button_hover_color,
            .pressed => palette.button_pressed_color,
            else => if (role == .tab_active) palette.accent_color else palette.button_color,
        },
        .check_box => Color.transparent,
        .slider_track, .progress_track => if (disabled) palette.disabled_color else palette.field_color,
        .slider_fill, .progress_fill => if (disabled) palette.disabled_color else palette.accent_color,
        .focus => Color.transparent,
    };
    return .{
        .background_color = background,
        .border_color = if (state == .focus) palette.focus_color else palette.border_color,
        .border_width = theme.border_width,
        .corner_radius = .all(theme.corner_radius),
        .padding = theme.padding,
        .text_color = if (disabled) theme.disabled_text_color else theme.text_color,
        .font = theme.font,
        .font_size = theme.font_size,
    };
}

fn inheritStyle(app: *App, base: ResolvedStyle, entity: Entity) ResolvedStyle {
    const style = app.world.get(entity, StyleBox) orelse return base;
    var out: ResolvedStyle = .{
        .background_color = style.background_color,
        .border_color = style.border_color,
        .border_width = style.border_width,
        .corner_radius = style.corner_radius,
        .padding = style.padding,
        .text_color = base.text_color,
        .font = base.font,
        .font_size = base.font_size,
    };
    if (app.world.get(entity, StyleBoxTexture)) |texture| {
        out.texture = texture.texture;
        out.tint = texture.tint;
        out.source_left = texture.source_left;
        out.source_right = texture.source_right;
        out.source_top = texture.source_top;
        out.source_bottom = texture.source_bottom;
        out.patch_margin = texture.patch_margin;
    }
    if (app.world.get(entity, StyleBoxText)) |text_style| {
        out.text_color = text_style.text_color;
        if (!text_style.font.isNone()) out.font = text_style.font;
        if (text_style.font_size > 0) out.font_size = text_style.font_size;
    }
    return out;
}

fn checkboxContent(context: Context, entity: Entity, checkbox: *CheckBox, style: ?ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    const ignored = app.world.get(entity, Control).?.mouse_filter == .ignore;
    if (context.interactive and !ignored and !checkbox.disabled and layout.justReleased()) {
        checkbox.checked = !checkbox.checked;
        try app.signal(entity, CheckBox, .toggled).emit(.{ .checked = checkbox.checked });
    }
    layout.open(.{
        .width = .fixed(18),
        .height = .fixed(18),
        .padding = .all(3),
        .background_color = color(checkbox.box_color),
        .corner_radius = .all(3),
    });
    if (checkbox.checked) layout.empty(.{ .width = .grow, .height = .grow, .background_color = color(checkbox.check_color), .corner_radius = .all(2) });
    layout.close();
    if (app.world.get(entity, Label)) |label| drawLabel(context, label, style);
}

fn lineEditContent(context: Context, entity: Entity, line: *LineEdit, style: ?ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    var id: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&id, "control-{d}-{d}-input", .{ entity.index, entity.generation }) catch "control-input";
    if (line.disabled) {
        layout.text(if (line.len > 0) line.slice() else line.placeholderSlice(), .{
            .font_size = if (line.use_theme and style != null) style.?.font_size else line.font_size,
            .color = color(if (line.len > 0 and line.use_theme and style != null) style.?.text_color else if (line.len > 0) line.text_color else line.placeholder_color),
            .wrap = if (line.multiline) .words else .none,
        });
        return;
    }
    layout.textInput(.{ .id = name, .width = .grow, .height = .grow }, .{
        .placeholder = line.placeholderSlice(),
        .max_length = LineEdit.capacity,
        .password = line.password,
        .multiline = line.multiline,
        .drag_select = true,
        .font_size = if (line.use_theme and style != null) style.?.font_size else line.font_size,
        .text_color = color(if (line.use_theme and style != null) style.?.text_color else line.text_color),
        .placeholder_color = color(line.placeholder_color),
        .cursor_color = color(line.cursor_color),
    });
    if (context.interactive and layout.textChanged(name)) {
        line.set(layout.textValueOf(name) orelse "");
        try app.signal(entity, LineEdit, .changed).emit(.{});
    } else if (layout.textValueOf(name)) |held| {
        if (!std.mem.eql(u8, held, line.slice())) layout.setTextValue(name, line.slice());
    }
    if (context.interactive and layout.textSubmitted(name)) try app.signal(entity, LineEdit, .submitted).emit(.{});
}

fn sliderContent(context: Context, entity: Entity, slider: *Slider, fill_style: ?ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    const span = slider.max - slider.min;
    var fraction = if (span > 0) (slider.value - slider.min) / span else 0;
    fraction = std.math.clamp(fraction, 0, 1);
    if (context.interactive and !slider.disabled and app.world.get(entity, Control).?.mouse_filter != .ignore and layout.pressed()) {
        var id: [48]u8 = undefined;
        if (layout.boxOf(idOf(&id, entity))) |box| {
            const raw = if (slider.vertical)
                (app.input.pointer.y - box.y) / @max(box.height, 1)
            else
                (app.input.pointer.x - box.x) / @max(box.width, 1);
            var next = slider.min + std.math.clamp(raw, 0, 1) * span;
            if (slider.step > 0) next = slider.min + @round((next - slider.min) / slider.step) * slider.step;
            next = std.math.clamp(next, @min(slider.min, slider.max), @max(slider.min, slider.max));
            if (next != slider.value) {
                slider.value = next;
                try app.signal(entity, Slider, .changed).emit(.{ .value = next });
                fraction = if (span > 0) (next - slider.min) / span else 0;
            }
        }
    }
    layout.open(.{ .width = .grow, .height = .grow, .background_color = color(slider.track_color), .corner_radius = .all(4) });
    layout.empty(.{
        .width = if (slider.vertical) .grow else .percent(fraction),
        .height = if (slider.vertical) .percent(fraction) else .grow,
        .background_color = color(if (fill_style) |style| style.background_color else slider.fill_color),
        .corner_radius = if (fill_style) |style| style.corner_radius.radius() else .all(4),
    });
    layout.close();
}

fn progressContent(layout: *ui.Ui, progress: *const ProgressBar, fill_style: ?ResolvedStyle) void {
    const span = progress.max - progress.min;
    const fraction = std.math.clamp(if (span > 0) (progress.value - progress.min) / span else 0, 0, 1);
    layout.empty(.{
        .width = .percent(fraction),
        .height = .grow,
        .background_color = color(if (fill_style) |style| style.background_color else progress.fill_color),
        .corner_radius = if (fill_style) |style| style.corner_radius.radius() else .all(4),
    });
    if (progress.show_percentage) {
        var text: [16]u8 = undefined;
        layout.text(std.fmt.bufPrint(&text, "{d:.0}%", .{fraction * 100}) catch "", .{ .color = color(progress.text_color), .wrap = .none });
    }
}

fn drawLabel(context: Context, label: *const Label, style: ?ResolvedStyle) void {
    const themed = label.use_theme and style != null;
    context.layout.text(label.slice(), .{
        .font = context.app.interface.addFont(if (themed) style.?.font else label.font) catch 0,
        .font_size = if (themed) style.?.font_size else label.font_size,
        .color = color(if (themed) style.?.text_color else label.color),
        .outline = if (label.outline_width > 0) .{ .color = color(label.outline_color), .width = label.outline_width } else null,
        .wrap = switch (label.wrap) {
            .words => .words,
            .newline => .newline,
            .none => .none,
        },
    });
}

fn copyText(out: *[LineEdit.capacity]u8, text: []const u8) u16 {
    var len = @min(text.len, out.len);
    while (len > 0 and len < text.len and text[len] & 0xC0 == 0x80) len -= 1;
    @memcpy(out[0..len], text[0..len]);
    return @intCast(len);
}

fn color(value: Color) ui.Color {
    return .rgba(value.r, value.g, value.b, value.a);
}

fn alignX(value: Control.AnchorX) ui.AlignX {
    return switch (value) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
}

fn alignY(value: Control.AnchorY) ui.AlignY {
    return switch (value) {
        .top => .top,
        .center => .center,
        .bottom => .bottom,
    };
}

fn boxAlignX(value: BoxContainer.AlignX) ui.AlignX {
    return switch (value) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
}

fn boxAlignY(value: BoxContainer.AlignY) ui.AlignY {
    return switch (value) {
        .top => .top,
        .center => .center,
        .bottom => .bottom,
    };
}

fn ratio(app: *App, handle: Assets.TextureHandle) ?f32 {
    const texture = app.assets.get(handle) orelse return null;
    return if (texture.height > 0) @as(f32, @floatFromInt(texture.width)) / @as(f32, @floatFromInt(texture.height)) else null;
}

const testing = std.testing;

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
        Control{ .parent = root, .width = .{ .mode = .fixed, .value = 100 }, .height = .{ .mode = .fixed, .value = 40 } },
        PanelContainer{ .color = .hex(0x223344), .corner_radius = .all(5) },
        ScrollContainer{},
        Label.of("Outlined"),
        NinePatchRect{ .texture = app.assets.white, .patch_margin = .all(4) },
    });
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

test "a world Viewport projects its Control tree through the camera" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 240, .frames = 2 });
    defer app.destroy();
    try app.useControlNodes();
    const root = try app.world.spawnWith(.{
        Transform2D.at(100, 80),
        Control{},
        Viewport{ .width = 40, .height = 20 },
        PanelContainer{ .color = .white },
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
    const check = try app.world.spawnWith(.{ Control{ .parent = root, .width = .{ .mode = .fixed, .value = 140 }, .height = .{ .mode = .fixed, .value = 30 } }, CheckBox{ .checked = true }, Label.of("Enabled") });
    const field = try app.world.spawnWith(.{ Control{ .parent = root, .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 32 } }, LineEdit.of("Player") });
    const slider = try app.world.spawnWith(.{ Control{ .parent = root, .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 20 } }, Slider{ .value = 50 } });
    const progress = try app.world.spawnWith(.{ Control{ .parent = root, .width = .{ .mode = .fixed, .value = 180 }, .height = .{ .mode = .fixed, .value = 20 } }, ProgressBar{ .value = 75 } });
    try app.run();

    for ([_]Entity{ check, field, slider, progress }) |entity| {
        var id: [48]u8 = undefined;
        try testing.expect(app.ui.boxOf(idOf(&id, entity)) != null);
    }
    try testing.expectEqualStrings("Player", app.world.get(field, LineEdit).?.slice());
}

test "themes inherit registered StyleBox parts by role and state" {
    const app = try App.create(testing.allocator, .{ .headless = true, .width = 320, .height = 200, .frames = 1 });
    defer app.destroy();
    try app.useControlNodes();

    const fallback = try app.world.spawnWith(.{ Theme{}, ThemePalette{} });
    const root = try app.world.spawnWith(.{
        Control{ .width = .{ .mode = .grow }, .height = .{ .mode = .grow } },
        CanvasLayer{},
        Theme{ .fallback = fallback, .font_size = 18 },
        ThemePalette{ .button_color = .hex(0x112233) },
    });
    const button = try app.world.spawnWith(.{ Control{ .parent = root }, Button{}, Label.of("Styled") });
    _ = try app.world.spawnWith(.{
        StyleBox{ .theme = fallback, .role = .button, .background_color = .hex(0xAABBCC), .padding = .all(9) },
        StyleBoxText{ .text_color = .hex(0xDDEEFF), .font_size = 23 },
        StyleBoxTexture{ .texture = app.assets.white, .patch_margin = .all(5) },
    });
    try app.run();

    const style = app.control_nodes.resolvedStyle(.{ .app = app, .layout = &app.ui }, button, .button, .pressed).?;
    try testing.expectEqual(Color.hex(0xAABBCC), style.background_color);
    try testing.expectEqual(Color.hex(0xDDEEFF), style.text_color);
    try testing.expectEqual(@as(u16, 23), style.font_size);
    try testing.expectEqual(@as(u16, 9), style.padding.left);
    try testing.expectEqual(@as(u16, 5), style.patch_margin.left);
    try testing.expect(style.texture.eql(app.assets.white));
}
