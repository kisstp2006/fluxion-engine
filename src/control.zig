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
const theme_file = @import("theme.zig");

/// What a control looks like lives in a `.theme` file rather than in the
/// world: see `theme.zig`. These are its words.
pub const ThemeHandle = theme_file.ThemeHandle;
pub const Part = theme_file.Part;
pub const State = theme_file.State;

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

pub const Insets = theme_file.Insets;
pub const Corners = theme_file.Corners;

fn padding(self: Insets) ui.Padding {
    return .{ .left = self.left, .right = self.right, .top = self.top, .bottom = self.bottom };
}

fn radius(self: Corners) ui.CornerRadius {
    return .{
        .top_left = self.top_left,
        .top_right = self.top_right,
        .bottom_right = self.bottom_right,
        .bottom_left = self.bottom_left,
    };
}

/// The rectangular base of every UI entity.
pub const Control = extern struct {
    parent: Entity = .none,
    /// The `.theme` file this control and everything under it is drawn from.
    /// `.none` takes whatever the control above it uses.
    theme: ThemeHandle = .none,
    /// A name in that theme to be drawn as, over the kind of control this is:
    /// Godot's type variation. A "Header" built on "Label" is one Label among
    /// many that is drawn differently.
    variation: [variation_capacity]u8 = @splat(0),
    variation_len: u8 = 0,
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

    pub const variation_capacity = 31;
    pub const Position = enum(u8) { flow, anchored };
    pub const AnchorX = enum(u8) { left, center, right };
    pub const AnchorY = enum(u8) { top, center, bottom };
    pub const MouseFilter = enum(u8) { stop, pass, ignore };

    pub const reflect_name = "Control";
    pub const reflect_attributes = .{attr.Property{ .name = "type_variation", .get = "variationSlice", .set = "setVariation" }};
    pub const reflect_fields = .{
        .parent = .{attr.Doc{ .text = "The UI entity whose box contains this one" }},
        .variation = .{attr.Hidden{}},
        .variation_len = .{attr.Hidden{}},
        .offset_x = .{attr.Unit{ .text = "px" }},
        .offset_y = .{attr.Unit{ .text = "px" }},
    };
    pub const reflect_methods = .{ .setVariation = .{}, .variationSlice = .{} };

    pub fn setVariation(self: *Control, name: []const u8) void {
        var cut = @min(name.len, variation_capacity);
        while (cut > 0 and cut < name.len and name[cut] & 0xC0 == 0x80) cut -= 1;
        @memcpy(self.variation[0..cut], name[0..cut]);
        self.variation_len = @intCast(cut);
    }

    pub fn variationSlice(self: *const Control) []const u8 {
        return self.variation[0..@min(self.variation_len, variation_capacity)];
    }
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

/// A box drawn in the theme's `Panel` style. What it looks like is the
/// theme's to say; what it holds is its children's.
pub const PanelContainer = extern struct {
    /// Whether the theme's panel is drawn behind its children at all. Off,
    /// it is a box that only holds things together.
    background: bool = true,
    pub const reflect_name = "PanelContainer";
};

pub const Label = extern struct {
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,
    /// Drawn round the letters, which no theme says: a label over a picture
    /// needs it and a label on a panel does not.
    outline_color: Color = .black,
    outline_width: u16 = 0,
    wrap: Wrap = .words,

    pub const capacity = 127;
    pub const Wrap = enum(u8) { words, newline, none };
    pub const reflect_name = "Label";
    pub const reflect_attributes = .{attr.Property{ .name = "text", .get = "slice", .set = "set" }};
    pub const reflect_fields = .{
        .bytes = .{attr.Hidden{}},
        .len = .{attr.Hidden{}},
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

/// A box that says what it does and hears that it was clicked. It carries
/// its own words and picture: a button is one thing, not a button with a
/// label inside it.
pub const Button = extern struct {
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,
    /// Drawn before the words, where there is one.
    icon: Assets.TextureHandle = .none,
    disabled: bool = false,
    /// Whether it stays down when clicked, as a switch does.
    toggle_mode: bool = false,
    /// Whether it is down now, for one that stays down.
    button_pressed: bool = false,
    hovered: bool = false,
    held: bool = false,

    pub const capacity = 63;
    pub const reflect_name = "Button";
    pub const reflect_attributes = .{attr.Property{ .name = "text", .get = "slice", .set = "set" }};
    pub const reflect_fields = .{
        .bytes = .{attr.Hidden{}},
        .len = .{attr.Hidden{}},
        .hovered = .{attr.ReadOnly{}},
        .held = .{attr.ReadOnly{}},
    };
    pub const reflect_methods = .{ .set = .{}, .slice = .{} };
    pub const signals = .{ .pressed = struct {}, .toggled = struct { pressed: bool } };

    pub fn of(text: []const u8) Button {
        var out: Button = .{};
        out.set(text);
        return out;
    }

    pub fn set(self: *Button, text: []const u8) void {
        var cut = @min(text.len, capacity);
        while (cut > 0 and cut < text.len and text[cut] & 0xC0 == 0x80) cut -= 1;
        @memcpy(self.bytes[0..cut], text[0..cut]);
        self.len = @intCast(cut);
    }

    pub fn slice(self: *const Button) []const u8 {
        return self.bytes[0..@min(self.len, capacity)];
    }
};

pub const CheckBox = extern struct {
    checked: bool = false,
    disabled: bool = false,
    pub const reflect_name = "CheckBox";
    pub const signals = .{ .toggled = struct { checked: bool } };
};

pub const LineEdit = extern struct {
    bytes: [capacity]u8 = @splat(0),
    len: u16 = 0,
    placeholder: [capacity]u8 = @splat(0),
    placeholder_len: u16 = 0,
    multiline: bool = false,
    password: bool = false,
    disabled: bool = false,

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
    pub const reflect_name = "Slider";
    pub const signals = .{ .changed = struct { value: f32 } };
};

pub const ProgressBar = extern struct {
    min: f32 = 0,
    max: f32 = 100,
    value: f32 = 0,
    show_percentage: bool = true,
    pub const reflect_name = "ProgressBar";
};

pub const TabContainer = extern struct {
    current: u16 = 0,
    separation: u16 = 4,
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
    preview_ui: ?ui.Ui = null,
    preview_interface: Interface = .{},
    enabled: bool = false,

    pub fn deinit(self: *Nodes, gpa: std.mem.Allocator) void {
        self.textures.deinit(gpa);
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
        if (app.world.get(entity, MarginContainer)) |margin| out.padding = padding(margin.margin);
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
                .border = padding(picture.patch_margin),
            };
        };
        if ((app.world.has(entity, Button) or app.world.has(entity, CheckBox) or app.world.has(entity, Slider)) and control.mouse_filter != .ignore) {
            out.focus = .{};
            out.cursor = .pointing_hand;
            out.capture = true;
        }
        if (roleOf(app, entity)) |role| {
            // A label is words, not a box: it takes the theme's text but none
            // of its background. Nor does a panel told not to draw one.
            const plain = role == .label or
                (app.world.get(entity, PanelContainer) != null and !app.world.get(entity, PanelContainer).?.background);
            if (!plain) self.applyStyle(app, &out, self.resolvedStyle(context, entity, role, stateOf(context, entity)));
        }
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
        const style = self.resolvedStyle(context, entity, roleOf(app, entity) orelse .panel, stateOf(context, entity));
        if (app.world.get(entity, Label)) |label| drawLabel(context, label, style);
        if (app.world.get(entity, Button)) |button| {
            // Its own face, unless the entity carries a Label that has
            // already drawn one: that is how scenes said it before.
            if (!app.world.has(entity, Label)) buttonFace(self, context, button, style);
            const control = app.world.get(entity, Control).?;
            if (control.mouse_filter == .ignore) {
                button.hovered = false;
                button.held = false;
                return;
            }
            button.hovered = context.interactive and context.layout.hovered();
            button.held = context.interactive and !button.disabled and context.layout.pressed();
            if (context.interactive and !button.disabled and context.layout.justReleased()) {
                if (button.toggle_mode) {
                    button.button_pressed = !button.button_pressed;
                    try app.signal(entity, Button, .toggled).emit(.{ .pressed = button.button_pressed });
                }
                try app.signal(entity, Button, .pressed).emit(.{});
            }
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
            const state: State = if (!context.interactive)
                .normal
            else if (layout.isElementPressed(name))
                .pressed
            else if (layout.isPointerOver(name))
                .hover
            else if (layout.isFocused(name))
                .focus
            else
                .normal;
            const role: Part = if (index == tab_container.current) .tab_active else .tab;
            const style = self.resolvedStyle(context, parent, role, state);
            var tab_decl: ui.Declaration = .{
                .id = name,
                .padding = .xy(10, 6),
                .focus = .{},
                .capture = true,
            };
            self.applyStyle(app, &tab_decl, style);
            layout.open(tab_decl);
            layout.text(app.nameOf(child) orelse "Tab", .{ .wrap = .none, .font = app.interface.addFont(style.font) catch 0, .font_size = style.font_size, .color = color(style.text_color) });
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

    /// What a piece of a control looks like: what the theme it is under says,
    /// over the look this engine is born with. There is always one, so a
    /// scene with no theme at all still draws.
    fn resolvedStyle(self: *Nodes, context: Context, entity: Entity, part: Part, state: State) ResolvedStyle {
        _ = self;
        const app = context.app;
        const found = themeOf(app, entity);
        return .from(app.themes.styleOf(found.handle, part, state, found.variation));
    }

    fn applyStyle(self: *Nodes, app: *App, out: *ui.Declaration, style: ResolvedStyle) void {
        out.background_color = color(style.background_color);
        out.border = if (style.border_width > 0) .all(color(style.border_color), style.border_width) else .{};
        out.corner_radius = radius(style.corner_radius);
        out.padding = padding(style.padding);
        if (self.image(app, style.texture, style.tint, .full)) |drawn| {
            out.image = drawn;
            out.image.?.nine_slice = .{
                .source_left = style.source_left,
                .source_right = style.source_right,
                .source_top = style.source_top,
                .source_bottom = style.source_bottom,
                .border = padding(style.patch_margin),
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

/// A theme's style with every question answered: what the drawing code
/// reads. Whatever the theme leaves unsaid the engine's own look fills in,
/// so nothing here is optional.
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

    fn from(style: theme_file.Style) ResolvedStyle {
        var out: ResolvedStyle = .{};
        if (style.background) |value| out.background_color = value;
        if (style.border_color) |value| out.border_color = value;
        if (style.border_width) |value| out.border_width = value;
        if (style.corners) |value| out.corner_radius = value;
        if (style.padding) |value| out.padding = value;
        if (style.texture) |value| out.texture = value;
        if (style.tint) |value| out.tint = value;
        if (style.slices) |value| {
            out.source_left = value[0];
            out.source_right = value[1];
            out.source_top = value[2];
            out.source_bottom = value[3];
        }
        if (style.patch_margin) |value| out.patch_margin = value;
        if (style.font_color) |value| out.text_color = value;
        if (style.font) |value| out.font = value;
        if (style.font_size) |value| out.font_size = value;
        return out;
    }
};

fn roleOf(app: *App, entity: Entity) ?Part {
    const world = &app.world;
    if (world.has(entity, Button)) return .button;
    if (world.has(entity, CheckBox)) return .check_box;
    if (world.has(entity, LineEdit)) return .line_edit;
    if (world.has(entity, Slider)) return .slider_track;
    if (world.has(entity, ProgressBar)) return .progress_track;
    if (world.has(entity, PanelContainer)) return .panel;
    if (world.has(entity, Label)) return .label;
    return null;
}

fn stateOf(context: Context, entity: Entity) State {
    const app = context.app;
    if (app.world.get(entity, Button)) |button| {
        if (button.disabled) return .disabled;
        // One that stays down is drawn down, whatever the pointer is doing.
        if (button.toggle_mode and button.button_pressed) return .pressed;
    }
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

/// Which theme a control is drawn from, and the name it asked to be drawn
/// as: its own, or the nearest one above it that names either.
fn themeOf(app: *App, entity: Entity) struct { handle: ThemeHandle, variation: []const u8 } {
    var found: ThemeHandle = .none;
    var variation: []const u8 = "";
    var at = entity;
    for (0..33) |_| {
        const control = app.world.get(at, Control) orelse break;
        // The control's own name, not one inherited: a variation says what
        // this control is, and saying it once should not paint its children.
        if (at.eql(entity)) variation = control.variationSlice();
        if (!control.theme.isNone()) {
            found = control.theme;
            break;
        }
        if (control.parent.isNone() or !app.world.isAlive(control.parent)) break;
        at = control.parent;
    }
    return .{ .handle = found, .variation = variation };
}

fn checkboxContent(context: Context, entity: Entity, checkbox: *CheckBox, style: ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    const ignored = app.world.get(entity, Control).?.mouse_filter == .ignore;
    if (context.interactive and !ignored and !checkbox.disabled and layout.justReleased()) {
        checkbox.checked = !checkbox.checked;
        try app.signal(entity, CheckBox, .toggled).emit(.{ .checked = checkbox.checked });
    }
    // As tall as the words beside it, so the pair agrees at any text size
    // rather than only at the one this was written for.
    const side: f32 = @max(12, @as(f32, @floatFromInt(style.font_size)));
    layout.open(.{
        .width = .fixed(side),
        .height = .fixed(side),
        .padding = .all(@intFromFloat(@round(side / 6))),
        .background_color = color(style.background_color),
        .corner_radius = .all(3),
    });
    // The tick is the box's mark, drawn in what the theme writes its words
    // in: one colour for the pair, rather than two that can disagree.
    if (checkbox.checked) layout.empty(.{ .width = .grow, .height = .grow, .background_color = color(style.text_color), .corner_radius = .all(2) });
    layout.close();
    if (app.world.get(entity, Label)) |label| drawLabel(context, label, style);
}

fn lineEditContent(context: Context, entity: Entity, line: *LineEdit, style: ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    var id: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&id, "control-{d}-{d}-input", .{ entity.index, entity.generation }) catch "control-input";
    // What is not there yet is written the way anything disabled is.
    const quiet = ResolvedStyle.from(app.themes.styleOf(themeOf(app, entity).handle, .line_edit, .disabled, "")).text_color;
    if (line.disabled) {
        layout.text(if (line.len > 0) line.slice() else line.placeholderSlice(), .{
            .font_size = style.font_size,
            .color = color(if (line.len > 0) style.text_color else quiet),
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
        .font_size = style.font_size,
        .text_color = color(style.text_color),
        .placeholder_color = color(quiet),
        .cursor_color = color(style.text_color),
    });
    if (context.interactive and layout.textChanged(name)) {
        line.set(layout.textValueOf(name) orelse "");
        try app.signal(entity, LineEdit, .changed).emit(.{});
    } else if (layout.textValueOf(name)) |held| {
        if (!std.mem.eql(u8, held, line.slice())) layout.setTextValue(name, line.slice());
    }
    if (context.interactive and layout.textSubmitted(name)) try app.signal(entity, LineEdit, .submitted).emit(.{});
}

fn sliderContent(context: Context, entity: Entity, slider: *Slider, fill_style: ResolvedStyle) !void {
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
    // The track is the slider's own box, which the theme has already drawn;
    // only the fill is left.
    layout.open(.{ .width = .grow, .height = .grow });
    layout.empty(.{
        .width = if (slider.vertical) .grow else .percent(fraction),
        .height = if (slider.vertical) .percent(fraction) else .grow,
        .background_color = color(fill_style.background_color),
        .corner_radius = radius(fill_style.corner_radius),
    });
    layout.close();
}

fn progressContent(layout: *ui.Ui, progress: *const ProgressBar, fill_style: ResolvedStyle) void {
    const span = progress.max - progress.min;
    const fraction = std.math.clamp(if (span > 0) (progress.value - progress.min) / span else 0, 0, 1);
    layout.empty(.{
        .width = .percent(fraction),
        .height = .grow,
        .background_color = color(fill_style.background_color),
        .corner_radius = radius(fill_style.corner_radius),
    });
    if (progress.show_percentage) {
        var text: [16]u8 = undefined;
        layout.text(std.fmt.bufPrint(&text, "{d:.0}%", .{fraction * 100}) catch "", .{ .color = color(fill_style.text_color), .wrap = .none });
    }
}

/// What a button shows: its picture, then its words.
fn buttonFace(self: *Nodes, context: Context, button: *const Button, style: ResolvedStyle) void {
    const layout = context.layout;
    if (self.image(context.app, button.icon, .white, .full)) |drawn| {
        const side: f32 = @floatFromInt(@max(style.font_size, 1));
        var picture = drawn;
        picture.background_color = .transparent;
        layout.empty(.{ .width = .fixed(side), .height = .fixed(side), .image = picture });
    }
    if (button.len == 0) return;
    layout.text(button.slice(), .{
        .font = context.app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
        .wrap = .none,
    });
}

fn drawLabel(context: Context, label: *const Label, style: ResolvedStyle) void {
    context.layout.text(label.slice(), .{
        .font = context.app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
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
        PanelContainer{},
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

test "a scene keeps the theme a control names, what it is drawn as, and a button's words" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.addTheme("ui.theme",
        \\{ "fluxion_theme": 1, "types": { "Danger": { "base_type": "Button", "styles": { "normal": { "background": "#C8434F" } } } } }
    );
    const loaded = try @import("scene.zig").read(app,
        \\{ "fluxion_scene": 2, "entities": [
        \\  { "uuid": "40000000-0000-4000-8000-000000000001", "name": "Delete",
        \\    "Control": { "theme": "ui.theme", "type_variation": "Danger" },
        \\    "Button": { "text": "Delete" } }
        \\] }
    , .{});
    _ = loaded;

    const entity = app.find("Delete").?;
    const control = app.world.get(entity, Control).?;
    try testing.expectEqualStrings("Danger", control.variationSlice());
    try testing.expectEqualStrings("Delete", app.world.get(entity, Button).?.slice());
    try testing.expect(!control.theme.isNone());

    const style = app.control_nodes.resolvedStyle(.{ .app = app, .layout = &app.ui }, entity, .button, .normal);
    try testing.expectEqual(@import("theme.zig").parseHex("#C8434F").?, style.background_color);
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
    const button = try app.world.spawnWith(.{ Control{ .parent = root }, Button{}, Label.of("Styled") });
    var loud: Control = .{ .parent = root };
    loud.setVariation("Loud");
    const shouty = try app.world.spawnWith(.{ loud, Button{}, Label.of("Loud") });
    try app.run();

    const context: Context = .{ .app = app, .layout = &app.ui };
    const style = app.control_nodes.resolvedStyle(context, button, .button, .pressed);
    try testing.expectEqual(Color.hex(0xAABBCC), style.background_color);
    try testing.expectEqual(Color.hex(0xDDEEFF), style.text_color);
    try testing.expectEqual(@as(u16, 18), style.font_size);
    try testing.expectEqual(@as(u16, 9), style.padding.left);
    // Nothing was said about the border, so the engine's own look holds.
    try testing.expectEqual(@import("theme.zig").Palette.border_width, style.border_width);

    // The theme is the root's, and the variation is this control's own.
    const louder = app.control_nodes.resolvedStyle(context, shouty, .button, .pressed);
    try testing.expectEqual(@as(u16, 23), louder.font_size);
    try testing.expectEqual(Color.hex(0xAABBCC), louder.background_color);
}
