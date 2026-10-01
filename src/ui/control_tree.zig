// SPDX-License-Identifier: BSD-3-Clause

//! The controls as the Fluxion UI tree they declare, built again each frame
//! from the `Control` components and the components beside them: the roots
//! and their layers, each control's box, style and content, its tooltip, and
//! the signals the pointer and the keys give it. An editor draws the same
//! tree into a texture of its own as a preview.

const std = @import("std");

const rhi = @import("fluxion_rhi");
const ui = @import("fluxion_ui");

const App = @import("../App.zig");
const Appearance = @import("../scene/inherited.zig").Appearance;
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const Interface = @import("interface.zig");
const Material = @import("../render/shaders.zig").Material;
const Rect2 = @import("../math/geometry.zig").Rect2;
const Region = @import("../scene/components.zig").Region;
const ShaderHandle = @import("../render/shaders.zig").ShaderHandle;
const Style = @import("theme.zig").Style;
const TouchButton = @import("touch_button.zig").TouchButton;
const View = @import("../render/view.zig").View;
const hierarchy = @import("../scene/hierarchy.zig");

const AlignX = @import("control.zig").AlignX;
const AlignY = @import("control.zig").AlignY;
const BoxContainer = @import("control.zig").BoxContainer;
const Button = @import("control.zig").Button;
const CanvasLayer = @import("control.zig").CanvasLayer;
const CenterContainer = @import("control.zig").CenterContainer;
const CheckBox = @import("control.zig").CheckBox;
const ColorRect = @import("control.zig").ColorRect;
const Control = @import("control.zig").Control;
const Corners = @import("control.zig").Corners;
const Entity = @import("control.zig").Entity;
const Focus = @import("control.zig").Focus;
const Insets = @import("control.zig").Insets;
const Label = @import("control.zig").Label;
const LineEdit = @import("control.zig").LineEdit;
const MarginContainer = @import("control.zig").MarginContainer;
const MouseCursor = @import("control.zig").MouseCursor;
const NinePatchRect = @import("control.zig").NinePatchRect;
const PanelContainer = @import("control.zig").PanelContainer;
const Part = @import("control.zig").Part;
const Popup = @import("control.zig").Popup;
const ProgressBar = @import("control.zig").ProgressBar;
const RichText = @import("control.zig").RichText;
const ScrollContainer = @import("control.zig").ScrollContainer;
const Size = @import("control.zig").Size;
const Slider = @import("control.zig").Slider;
const State = @import("control.zig").State;
const TabContainer = @import("control.zig").TabContainer;
const TextureRect = @import("control.zig").TextureRect;
const ThemeHandle = @import("control.zig").ThemeHandle;
const ThemeOverride = @import("control.zig").ThemeOverride;
const Viewport = @import("control.zig").Viewport;
const idOf = @import("control.zig").idOf;

pub fn padding(self: Insets) ui.Padding {
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

pub const ControlTree = struct {
    textures: std.ArrayList(rhi.Texture) = .empty,
    /// The boxes this frame's controls leave for their materials, by the
    /// number the interface hands back: see `drawCustom`.
    customs: std.ArrayList(Custom) = .empty,
    /// The names a control is declared with - its own, and the neighbours
    /// its focus goes to - kept until it is opened, which is when the
    /// interface reads them.
    names: [7][48]u8 = undefined,
    /// The control with words to show whose box the pointer is over, found
    /// as the controls are declared, and the one it was last frame, and for
    /// how long the pointer has rested there.
    tooltip_under: Entity = .none,
    tooltip_was: Entity = .none,
    tooltip_rested: f32 = 0,
    /// Seconds the pointer rests on a control before its `tooltip_text`
    /// shows: the project's `gui.tooltip_delay`.
    tooltip_delay: f32 = 0.5,
    /// A check box's tick, white on clear, made the first time one is
    /// drawn and tinted with the theme's words.
    check_mark: Assets.TextureHandle = .none,
    preview_ui: ?ui.Ui = null,
    /// What an editor has picked while it draws a preview: a popup that is
    /// shut is shown only while it, or something in it, is one of them.
    preview_editing: []const Entity = &.{},
    /// Where an editor's preview puts the game's screen: its size in the
    /// interface's units, and its top left, the world's origin, in the same.
    preview_canvas: ?struct { width: f32, height: f32, x: f32, y: f32 } = null,
    preview_interface: Interface = .{},
    enabled: bool = false,
    /// Whether the pointer was over each control and it had the keys, as of
    /// the frame it was last drawn: what its `mouse_entered` and the rest are
    /// said by.
    seen: std.AutoArrayHashMapUnmanaged(Entity, Seen) = .empty,
    /// Moved on each frame, so a control not drawn in one is found.
    seen_mark: u32 = 0,

    const Seen = struct { hovered: bool = false, focused: bool = false, mark: u32 = 0 };

    pub fn deinit(self: *ControlTree, gpa: std.mem.Allocator) void {
        self.textures.deinit(gpa);
        self.customs.deinit(gpa);
        self.seen.deinit(gpa);
        if (self.preview_ui) |*held_ui| held_ui.deinit();
        self.preview_interface.deinit();
        self.* = .{};
    }

    pub fn enable(self: *ControlTree, app: *App) !void {
        if (self.enabled) return;
        self.enabled = true;
        // Drawn paused or not: which of them answer the pointer is each
        // one's `Processing`.
        try app.addSystemAlways(.ui, "control nodes", draw);
    }

    fn draw(app: *App) !void {
        const self = &app.control_tree;
        self.tooltip_under = .none;
        self.seen_mark +%= 1;
        try self.drawRoots(.{ .app = app, .layout = &app.ui, .interactive = true });
        try self.forgetUnseen(app);
        try self.tooltip(app);
        app.interface.textures = self.textures.items;
    }

    /// Say what changed for a control since the frame before: the pointer
    /// over it or not, the keys its or not.
    fn notice(self: *ControlTree, app: *App, entity: Entity, hovered: bool) !void {
        const focused = app.hasFocus(entity);
        const entry = try self.seen.getOrPut(app.gpa, entity);
        const was: Seen = if (entry.found_existing) entry.value_ptr.* else .{};
        entry.value_ptr.* = .{ .hovered = hovered, .focused = focused, .mark = self.seen_mark };
        if (hovered and !was.hovered) try app.signal(entity, Control, .mouse_entered).emit(.{});
        if (!hovered and was.hovered) try app.signal(entity, Control, .mouse_exited).emit(.{});
        if (focused and !was.focused) try app.signal(entity, Control, .focus_entered).emit(.{});
        if (!focused and was.focused) try app.signal(entity, Control, .focus_exited).emit(.{});
    }

    /// A control not drawn this frame - hidden, taken away, dead - has the
    /// pointer and the keys no more.
    fn forgetUnseen(self: *ControlTree, app: *App) !void {
        var at = self.seen.count();
        while (at > 0) {
            at -= 1;
            const held = self.seen.values()[at];
            if (held.mark == self.seen_mark) continue;
            const entity = self.seen.keys()[at];
            self.seen.swapRemoveAt(at);
            if (!app.world.has(entity, Control)) continue;
            if (held.hovered) try app.signal(entity, Control, .mouse_exited).emit(.{});
            if (held.focused) try app.signal(entity, Control, .focus_exited).emit(.{});
        }
    }

    /// The widest a tooltip is, in the interface's units, before its lines
    /// break.
    const tooltip_width = 360;

    /// The words of the control the pointer has rested on long enough, by
    /// the pointer, over everything.
    fn tooltip(self: *ControlTree, app: *App) !void {
        const under = self.tooltip_under;
        if (under.isNone() or !under.eql(self.tooltip_was)) {
            self.tooltip_was = under;
            self.tooltip_rested = 0;
            return;
        }
        self.tooltip_rested += app.time.unscaled_delta;
        const delay = if (app.project.settings) |project| project.gui.tooltip_delay else self.tooltip_delay;
        if (self.tooltip_rested < delay) return;
        const words = app.textOf(under, Control, "tooltip_text");
        const context: Context = .{ .app = app, .layout = &app.ui };
        const style = self.resolvedStyle(context, under, .tooltip, .normal);
        const scale = @max(app.interface.scale, 0.01);
        // Its lines as they are written, and a long one broken: never wider
        // than a reader follows easily, and never off the window.
        var box: ui.Declaration = .{
            .id = "control-tooltip",
            .width = .fitBetween(0, tooltip_width),
            .floating = .{
                .attach = .root,
                .offset = .{ .x = app.input.pointer.x / scale + 12, .y = app.input.pointer.y / scale + 18 },
                .z_index = 1000,
                .keep_on_screen = true,
            },
        };
        self.applyStyle(app, &box, style);
        app.ui.open(box);
        defer app.ui.close();
        app.ui.text(words, .{
            .font = app.interface.addFont(style.font) catch 0,
            .font_size = style.font_size,
            .color = color(style.text_color),
            .wrap = .words,
        });
    }

    fn drawRoots(self: *ControlTree, context: Context) !void {
        const app = context.app;
        self.textures.clearRetainingCapacity();
        self.customs.clearRetainingCapacity();
        for (app.world.archetypeSlice()) |*archetype| {
            for (archetype.entities.items) |entity| {
                if (!app.world.has(entity, Control)) continue;
                if (app.world.get(entity, CanvasLayer)) |layer| {
                    if (layer.visible) try self.root(context, entity, .screen, 0, 0, layer.layer);
                } else if (app.world.get(entity, Viewport)) |viewport| {
                    if (!viewport.visible) continue;
                    try self.root(context, entity, viewport.space, viewport.width, viewport.height, viewport.layer);
                } else if (context.view != null) {
                    // A tree with no root of its own - a scene made to be put
                    // under another's interface - is shown over the screen
                    // in an editor, to be laid out.
                    try self.root(context, entity, .screen, 0, 0, 0);
                }
            }
        }
    }

    fn root(self: *ControlTree, context: Context, entity: Entity, space: Viewport.Space, width: f32, height: f32, layer: i16) !void {
        const app = context.app;
        const layout = context.layout;
        const control = app.world.get(entity, Control) orelse return;
        // A layer inside another control's tree is drawn with it.
        if (!control.visible or app.world.has(hierarchy.parentOf(&app.world, entity), Control)) return;
        // Whatever is above it counts here: the root of a tree may hang from
        // something that is no control, faded or hidden.
        const shown = app.resolvedAppearance(entity);
        if (!shown.visible) return;
        const own = context.at(entity);
        var declared = self.declaration(own, entity, control.*);
        declared.tint = color(shown.modulate);
        // A layer covers the screen whatever is in it: what is not on it
        // reaches the layers under it, unless the layer stops everything.
        declared.passthrough = control.mouse_filter != .stop;
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
                const scale = @max(self.preview_interface.scale, 0.0001);
                declared.floating = .{ .attach = .root, .offset = .{ .x = at.x / scale - width / 2, .y = at.y / scale - height / 2 }, .z_index = layer };
            } else if (self.preview_canvas) |canvas| {
                // An editor's preview: the game's screen, where the world's
                // origin is and as big as the view is zoomed.
                declared.width = .fixed(canvas.width);
                declared.height = .fixed(canvas.height);
                declared.floating = .{ .attach = .root, .offset = .{ .x = canvas.x, .y = canvas.y }, .z_index = layer };
            } else declared.floating = .{ .attach = .root, .z_index = layer };
            layout.open(declared);
        }
        defer layout.close();
        try self.content(own, entity);
        try self.children(context, entity, 0);
    }

    fn children(self: *ControlTree, context: Context, parent: Entity, depth: u8) anyerror!void {
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

    /// A control inside a tree: its own `Appearance` hides and fades it,
    /// and fluxion-ui takes that on to what is inside it. What it answers is
    /// its own `Processing`'s, and its children's theirs.
    fn node(self: *ControlTree, context: Context, entity: Entity, control: Control, depth: u8) anyerror!void {
        const app = context.app;
        var tint: Color = .white;
        if (app.world.get(entity, Appearance)) |looks| {
            if (!looks.visible) return;
            tint = looks.modulate;
        }
        // Shown only on a touch screen, and this is none - but in an editor,
        // which lays it out where the game would.
        if (app.world.get(entity, TouchButton)) |button| {
            if (context.layout == &app.ui and !button.shown(app.input.touchscreen)) return;
        }
        const own = context.at(entity);
        const popup = app.world.get(entity, Popup);
        if (popup) |held| {
            // Said once it is shut, however it was.
            if (held.was_open and !held.open and own.interactive) {
                held.was_open = false;
                try app.signal(entity, Popup, .closed).emit(.{});
            }
            // An editor, which draws it without answering anything, shows it
            // as it would be open while it or something in it is picked, to
            // be laid out; the rest of the time as the game would.
            if (!held.open and (own.interactive or !self.isEditing(app, entity))) return;
            if (own.interactive) held.was_open = true;
        }
        var declared = self.declaration(own, entity, control);
        declared.tint = color(tint);
        if (popup) |held| {
            const z: i16 = 900 +| control.z_index;
            if (held.modal and own.interactive) context.layout.empty(.{
                .width = .grow,
                .height = .grow,
                .background_color = color(held.veil),
                .capture = true,
                .floating = .{ .attach = .root, .z_index = z - 1 },
            });
            if (held.centered) {
                declared.floating = .{ .attach = .root, .anchor = .centered, .z_index = z };
            } else if (declared.floating) |*float| {
                float.z_index = z;
            } else declared.floating = .{ .z_index = z };
        }
        context.layout.open(declared);
        defer context.layout.close();
        if (own.interactive and app.textOf(entity, Control, "tooltip_text").len > 0 and context.layout.hovered()) self.tooltip_under = entity;
        if (own.interactive) try self.notice(app, entity, control.mouse_filter != .ignore and context.layout.hovered());
        try self.content(own, entity);
        try self.children(context, entity, depth + 1);
        if (popup) |held| if (own.interactive) {
            const layout = context.layout;
            const outside = layout.pointer.justPressed() and !layout.isPointerOver(self.idFor(entity));
            if ((held.close_on_click_outside and outside) or app.input.actionJustPressed("ui_cancel")) held.open = false;
        };
    }

    /// Whether an editor has picked `entity`, or something under it.
    fn isEditing(self: *const ControlTree, app: *App, entity: Entity) bool {
        for (self.preview_editing) |picked| {
            var at = picked;
            for (0..64) |_| {
                if (at.isNone() or !app.world.isAlive(at)) break;
                if (at.eql(entity)) return true;
                at = hierarchy.parentOf(&app.world, at);
            }
        }
        return false;
    }

    /// The name a control is declared with, into the first of `names`.
    fn idFor(self: *ControlTree, entity: Entity) []const u8 {
        return idOf(&self.names[0], entity);
    }

    fn declaration(self: *ControlTree, context: Context, entity: Entity, control: Control) ui.Declaration {
        const app = context.app;
        const name = self.idFor(entity);
        var out: ui.Declaration = .{
            .id = name,
            .width = control.width.layout(),
            .height = control.height.layout(),
            .clip = if (control.clip) .both else .none,
            .z_index = control.z_index,
            .capture = control.mouse_filter == .stop,
            .passthrough = control.mouse_filter == .ignore,
            .scale = if (control.scale != 1) .by(control.scale) else null,
        };
        if (control.position == .anchored) {
            // Stretched between two points of its parent, or pinned to one
            // and its own size: see `Control.Position`.
            const across = control.anchor_right > control.anchor_left;
            const down = control.anchor_bottom > control.anchor_top;
            if (across) out.width = stretched(control.width, control.anchor_right - control.anchor_left, control.offset_right - control.offset_left);
            if (down) out.height = stretched(control.height, control.anchor_bottom - control.anchor_top, control.offset_bottom - control.offset_top);
            out.floating = .{
                .fractions = .{
                    .element_x = if (across) 0 else growFraction(control.grow_horizontal),
                    .element_y = if (down) 0 else growFraction(control.grow_vertical),
                    .target_x = control.anchor_left,
                    .target_y = control.anchor_top,
                },
                .offset = .{ .x = control.offset_left, .y = control.offset_top },
            };
        }
        if (app.world.get(entity, ColorRect)) |rect| out.background_color = color(rect.color);
        if (app.world.get(entity, BoxContainer)) |box| {
            out.direction = if (box.direction == .horizontal) .left_to_right else .top_to_bottom;
            out.gap = box.separation;
            out.wrap = box.wrap;
            out.wrap_gap = box.wrap_separation;
            out.align_x = boxAlignX(box.alignment_x);
            out.align_y = boxAlignY(box.alignment_y);
        }
        if (app.world.get(entity, Label)) |label| {
            out.align_x = boxAlignX(label.horizontal_alignment);
            out.align_y = boxAlignY(label.vertical_alignment);
        }
        if (app.world.get(entity, Button)) |button| {
            out.align_x = boxAlignX(button.alignment);
            out.align_y = .center;
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
        if (app.world.get(entity, TextureRect)) |picture| {
            const shown = shownTexture(app, entity, picture.texture);
            if (self.image(app, shown, picture.tint, picture.region)) |drawn| {
                out.image = drawn;
                switch (picture.stretch) {
                    .fill => {},
                    .contain => out.contain = ratio(app, shown),
                    .cover => out.cover = ratio(app, shown),
                }
            }
        }
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
        // A colour or a picture with a material is drawn by its shader, in
        // the box the interface leaves for it.
        if (self.customOf(app, entity)) |index| {
            out.custom = index;
            out.background_color = .transparent;
            out.image = null;
        }
        const pressable = app.world.has(entity, Button) or app.world.has(entity, CheckBox) or app.world.has(entity, Slider);
        if (pressable and control.mouse_filter != .ignore) {
            out.cursor = .pointing_hand;
            out.capture = true;
        }
        if (app.world.get(entity, MouseCursor)) |own| {
            if (control.mouse_filter != .ignore) out.cursor = cursorShape(own.shape);
        }
        const asked: Focus = if (app.world.get(entity, Focus)) |own| own.* else .{ .mode = if (pressable) .all else .none };
        if (asked.mode != .none and control.mouse_filter != .ignore) {
            out.focus = .{
                .tab_stop = asked.mode == .all,
                .left = self.neighbour(app, 1, asked.left),
                .right = self.neighbour(app, 2, asked.right),
                .up = self.neighbour(app, 3, asked.up),
                .down = self.neighbour(app, 4, asked.down),
                .next = self.neighbour(app, 5, asked.next),
                .previous = self.neighbour(app, 6, asked.previous),
            };
            // A slider keeps the focus along its own way, and the arrows
            // and a pad move its value instead: see `sliderContent`.
            if (app.world.get(entity, Slider)) |slider| {
                if (slider.vertical) {
                    out.focus.?.up = name;
                    out.focus.?.down = name;
                } else {
                    out.focus.?.left = name;
                    out.focus.?.right = name;
                }
            }
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

    /// The name a neighbour of the focus takes the keyboard by, into the
    /// `slot`th of `names`: null for none.
    fn neighbour(self: *ControlTree, app: *App, slot: usize, entity: Entity) ?[]const u8 {
        if (entity.isNone() or !app.world.isAlive(entity)) return null;
        return focusIdOf(app, &self.names[slot], entity);
    }

    fn content(self: *ControlTree, context: Context, entity: Entity) !void {
        const app = context.app;
        if (app.world.get(entity, RichText)) |rich| {
            try richContent(self, context, entity, rich, self.resolvedStyle(context, entity, .label, stateOf(context, entity)));
            return;
        }
        if (app.world.get(entity, CheckBox)) |checkbox| {
            try checkboxContent(self, context, entity, checkbox, self.resolvedStyle(context, entity, .check_box, stateOf(context, entity)));
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
            progressContent(
                context,
                progress,
                self.resolvedStyle(context, entity, .progress_track, .normal),
                self.resolvedStyle(context, entity, .progress_fill, .normal),
            );
            return;
        }
        const style = self.resolvedStyle(context, entity, roleOf(app, entity) orelse .panel, stateOf(context, entity));
        if (app.world.get(entity, Label)) |label| drawLabel(context, entity, label, style);
        if (app.world.get(entity, Button)) |button| {
            buttonFace(self, context, entity, button, style);
            const control = app.world.get(entity, Control).?;
            if (control.mouse_filter == .ignore) {
                button.hovered = false;
                button.held = false;
                return;
            }
            button.hovered = context.interactive and context.layout.hovered();
            const was_held = button.held;
            button.held = context.interactive and !button.disabled and context.layout.pressed();
            if (button.held and !was_held) try app.signal(entity, Button, .button_down).emit(.{});
            if (!button.held and was_held) try app.signal(entity, Button, .button_up).emit(.{});
            if (context.interactive and !button.disabled and context.layout.justReleased()) {
                if (button.toggle_mode) {
                    button.button_pressed = !button.button_pressed;
                    try app.signal(entity, Button, .toggled).emit(.{ .pressed = button.button_pressed });
                }
                try app.signal(entity, Button, .pressed).emit(.{});
            }
        }
    }

    fn drawTabs(self: *ControlTree, context: Context, parent: Entity, children_of: []const Entity, tab_container: *TabContainer, depth: u8) !void {
        const app = context.app;
        const layout = context.layout;
        // The tabs are the container's to answer; what they show, its own.
        const own = context.at(parent);
        layout.open(.{ .width = .grow, .height = .fit, .gap = tab_container.separation });
        for (children_of, 0..) |child, index| {
            if (!app.world.has(child, Control)) continue;
            var id: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&id, "tab-{d}-{d}", .{ child.index, child.generation }) catch "tab";
            const state: State = if (!own.interactive)
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
            if (own.interactive and layout.justReleased() and index != tab_container.current) {
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
    /// The control's theme over the project's, with its own overrides where
    /// `part` is the one the control is - not a slider's fill or a focus ring.
    pub fn resolvedStyle(self: *ControlTree, context: Context, entity: Entity, part: Part, state: State) ResolvedStyle {
        _ = self;
        const app = context.app;
        const found = themeOf(app, entity);
        const own: Style = if (app.world.get(entity, ThemeOverride)) |override|
            (if (part == roleOf(app, entity) orelse .panel) override.style() else .{})
        else
            .{};
        return .from(app.themes.styleWith(found.handle, app.projectTheme(), part, state, found.variation, own));
    }

    fn applyStyle(self: *ControlTree, app: *App, out: *ui.Declaration, style: ResolvedStyle) void {
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

    pub fn preview(self: *ControlTree, app: *App, into: rhi.Texture, view: View, width: f32, height: f32, faces: Interface.Faces, editing: []const Entity) !void {
        self.preview_editing = editing;
        defer self.preview_editing = &.{};
        if (self.preview_ui == null) self.preview_ui = .init(app.gpa);
        const layout = &self.preview_ui.?;
        if (faces.len > 0) layout.setMeasurer(Interface.measurer(&faces));
        // The interface is laid out at the game's size, over what the camera
        // shows, and drawn as big as the world is there: a view zoomed in
        // shows it bigger, as it shows a sprite bigger.
        const screen = app.screenInWorld();
        const zoom = @max(view.zoom_x * screen.units_per_pixel, 0.0001);
        self.preview_interface.scale = zoom;
        const size = app.gameSize();
        const origin = view.toScreen(screen.top_left);
        self.preview_canvas = .{ .width = size[0], .height = size[1], .x = origin.x / zoom, .y = origin.y / zoom };
        defer self.preview_canvas = null;
        layout.begin(self.preview_interface.surface(width, height));
        layout.open(.{ .width = .grow, .height = .grow });
        try self.drawRoots(.{ .app = app, .layout = layout, .view = view });
        layout.close();
        self.preview_interface.commands = try layout.end();
        self.preview_interface.textures = self.textures.items;
        self.preview_interface.custom = app.interface.custom;
        try self.preview_interface.draw(app.gpa, &app.device, faces.slice(), .{ .texture = into }, width, height);
    }

    /// The number of the box a `ColorRect` or a `TextureRect` with a
    /// material leaves for its shader, kept for `drawCustom`; null for one
    /// drawn as it is.
    fn customOf(self: *ControlTree, app: *App, entity: Entity) ?u32 {
        const held = app.world.get(entity, Material) orelse return null;
        if (app.shaders.compiledOf(held.shader) == null) return null;
        var made: Custom = .{ .entity = entity, .shader = held.shader, .texture = app.assets.white };
        if (app.world.get(entity, ColorRect)) |rect| {
            made.tint = rect.color;
        } else if (app.world.get(entity, TextureRect)) |picture| {
            const shown = shownTexture(app, entity, picture.texture);
            const texture = app.assets.get(shown) orelse return null;
            made.texture = shown;
            made.tint = picture.tint;
            made.region = if (texture.upside_down) picture.region.flippedY() else picture.region;
        } else return null;
        self.customs.append(app.gpa, made) catch return null;
        return @intCast(self.customs.items.len - 1);
    }

    /// Draw one of the boxes controls left for their materials: a quad over
    /// the box, through the shader, with the picture and the colour the
    /// control would have had. What the interface hands over between its
    /// passes; see `ui_rhi.CustomDraw`.
    pub fn drawCustom(self: *ControlTree, app: *App, command: ui.RenderCommand, scissor: ?rhi.Rect, into: rhi.RenderTarget, size: ui.Dimensions) !void {
        const index = command.config.custom.data;
        if (index >= self.customs.items.len) return;
        const made = self.customs.items[index];
        const texture = app.assets.get(made.texture) orelse app.assets.get(app.assets.white) orelse return;
        const box = command.bounding_box;
        const faded = command.config.custom.tint;
        try app.sprites.drawQuad(app.gpa, made.entity, made.shader, into, size.width, size.height, .{
            .place = .{ box.x, box.y, box.width, 0 },
            .shape = .{ 0, box.height, 0, 0 },
            .tint = .{ made.tint.r * faded.r, made.tint.g * faded.g, made.tint.b * faded.b, made.tint.a * faded.a },
            .uv_rect = .{ made.region.u0, made.region.v0, made.region.u1, made.region.v1 },
        }, texture.gpu, app.assets.samplerFor(texture.filter, texture.wrap), scissor);
    }

    pub fn previewBox(self: *ControlTree, entity: Entity) ?ui.BoundingBox {
        const layout = if (self.preview_ui) |*held| held else return null;
        var id: [48]u8 = undefined;
        return layout.boxOf(idOf(&id, entity));
    }

    fn image(self: *ControlTree, app: *App, handle: Assets.TextureHandle, tint: Color, own_region: Region) ?ui.layout.Image {
        const texture = app.assets.get(handle) orelse return null;
        // A picture drawn into, on a backend that counts rows from the
        // bottom, is shown turned over.
        const region = if (texture.upside_down) own_region.flippedY() else own_region;
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

/// The texture a texture rect shows: a render view's picture, for one with a
/// `ViewTexture`, or its own.
fn shownTexture(app: *App, entity: Entity, own: Assets.TextureHandle) Assets.TextureHandle {
    return app.views.shown(&app.world, entity, own);
}

/// A box a control left for its material, and what to draw in it.
const Custom = struct {
    entity: Entity,
    shader: ShaderHandle,
    texture: Assets.TextureHandle,
    tint: Color = .white,
    region: Region = .full,
};

pub const Context = struct {
    app: *App,
    layout: *ui.Ui,
    interactive: bool = false,
    view: ?View = null,

    /// The same, for one entity: which answers the pointer and the keys
    /// only while it runs. See `App.setPaused`.
    fn at(self: Context, entity: Entity) Context {
        var own = self;
        own.interactive = self.interactive and self.app.isProcessing(entity);
        return own;
    }
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

    fn from(style: Style) ResolvedStyle {
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
    if (world.has(entity, RichText)) return .label;
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
        const above = hierarchy.parentOf(&app.world, at);
        if (above.isNone() or !app.world.isAlive(above)) break;
        at = above;
    }
    return .{ .handle = found, .variation = variation };
}

fn checkboxContent(self: *ControlTree, context: Context, entity: Entity, checkbox: *CheckBox, style: ResolvedStyle) !void {
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
    // Framed in the words' colour too: the box is the check box's own style
    // on the check box's own style, and without a frame an empty one would
    // not show at all.
    layout.open(.{
        .width = .fixed(side),
        .height = .fixed(side),
        .padding = .all(@intFromFloat(@round(side / 6))),
        .background_color = color(style.background_color),
        .corner_radius = .all(3),
        .border = .all(color(style.text_color), 1),
    });
    // The tick is drawn in what the theme writes its words in: one colour for
    // the pair, rather than two that can disagree.
    if (checkbox.checked) {
        if (self.image(app, try checkMark(self, app), style.text_color, .full)) |tick| layout.empty(.{ .width = .grow, .height = .grow, .image = tick });
    }
    layout.close();
    if (app.world.get(entity, Label)) |label| drawLabel(context, entity, label, style);
}

/// How many pixels across the tick is drawn at: enough to stay smooth at
/// any size a check box is shown at.
pub const check_side = 64;

/// The tick, made once: two strokes, their edges soft over a pixel.
fn checkMark(self: *ControlTree, app: *App) !Assets.TextureHandle {
    if (app.assets.get(self.check_mark) != null) return self.check_mark;
    var pixels: [check_side * check_side * 4]u8 = undefined;
    paintCheck(&pixels);
    self.check_mark = try app.assets.textureFromPixels(check_side, check_side, &pixels, .{});
    return self.check_mark;
}

pub fn paintCheck(pixels: *[check_side * check_side * 4]u8) void {
    const side: f32 = check_side;
    const a: [2]f32 = .{ 0.16 * side, 0.52 * side };
    const b: [2]f32 = .{ 0.40 * side, 0.76 * side };
    const c: [2]f32 = .{ 0.84 * side, 0.26 * side };
    const half = 0.075 * side;
    for (0..check_side) |row| for (0..check_side) |column| {
        const p: [2]f32 = .{ @as(f32, @floatFromInt(column)) + 0.5, @as(f32, @floatFromInt(row)) + 0.5 };
        const away = @min(toSegment(p, a, b), toSegment(p, b, c));
        const cover = std.math.clamp(half - away + 0.5, 0, 1);
        const at = (row * check_side + column) * 4;
        pixels[at..][0..4].* = .{ 255, 255, 255, @intFromFloat(@round(cover * 255)) };
    };
}

/// How far `p` is from the segment from `a` to `b`.
fn toSegment(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const along = [2]f32{ b[0] - a[0], b[1] - a[1] };
    const to_p = [2]f32{ p[0] - a[0], p[1] - a[1] };
    const length = along[0] * along[0] + along[1] * along[1];
    const t = if (length <= 0) 0 else std.math.clamp((to_p[0] * along[0] + to_p[1] * along[1]) / length, 0, 1);
    const dx = to_p[0] - t * along[0];
    const dy = to_p[1] - t * along[1];
    return @sqrt(dx * dx + dy * dy);
}

fn lineEditContent(context: Context, entity: Entity, line: *LineEdit, style: ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    var id: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&id, "control-{d}-{d}-input", .{ entity.index, entity.generation }) catch "control-input";
    // What is not there yet is written the way anything disabled is.
    const quiet = ResolvedStyle.from(app.themes.styleOf(themeOf(app, entity).handle, .line_edit, .disabled, "")).text_color;
    const typed = app.textOf(entity, LineEdit, "text");
    const placeholder = app.textOf(entity, LineEdit, "placeholder_text");
    if (line.disabled) {
        layout.text(if (typed.len > 0) typed else placeholder, .{
            .font_size = style.font_size,
            .color = color(if (typed.len > 0) style.text_color else quiet),
            .wrap = if (line.multiline) .words else .none,
        });
        return;
    }
    layout.textInput(.{ .id = name, .width = .grow, .height = .grow }, .{
        .placeholder = placeholder,
        .max_length = if (line.max_length == 0) null else line.max_length,
        .password = line.password,
        .multiline = line.multiline,
        .drag_select = true,
        .font_size = style.font_size,
        .text_color = color(style.text_color),
        .placeholder_color = color(quiet),
        .cursor_color = color(style.text_color),
    });
    if (context.interactive and layout.textChanged(name)) {
        try app.setText(entity, LineEdit, "text", layout.textValueOf(name) orelse "");
        try app.signal(entity, LineEdit, .text_changed).emit(.{});
    } else if (layout.textValueOf(name)) |held| {
        if (!std.mem.eql(u8, held, typed)) layout.setTextValue(name, typed);
    }
    if (context.interactive and layout.textSubmitted(name)) try app.signal(entity, LineEdit, .text_submitted).emit(.{});
}

fn sliderContent(context: Context, entity: Entity, slider: *Slider, fill_style: ResolvedStyle) !void {
    const app = context.app;
    const layout = context.layout;
    const span = slider.max - slider.min;
    // With the focus, the arrows and a pad step it - held, as they repeat.
    if (context.interactive and !slider.disabled) if (layout.stepped()) |way| {
        var id: [48]u8 = undefined;
        if (layout.isFocused(idOf(&id, entity))) {
            const down = if (slider.vertical) way == .down else way == .left;
            const up = if (slider.vertical) way == .up else way == .right;
            if (down or up) {
                const step = if (slider.step > 0) slider.step else span / 100;
                const next = std.math.clamp(slider.value + if (up) step else -step, @min(slider.min, slider.max), @max(slider.min, slider.max));
                if (next != slider.value) {
                    slider.value = next;
                    try app.signal(entity, Slider, .value_changed).emit(.{ .value = next });
                }
            }
        }
    };
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
                try app.signal(entity, Slider, .value_changed).emit(.{ .value = next });
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

fn progressContent(context: Context, progress: *const ProgressBar, style: ResolvedStyle, fill_style: ResolvedStyle) void {
    const layout = context.layout;
    const span = progress.max - progress.min;
    const fraction = std.math.clamp(if (span > 0) (progress.value - progress.min) / span else 0, 0, 1);
    layout.empty(.{
        .width = .percent(fraction),
        .height = .grow,
        .background_color = color(fill_style.background_color),
        .corner_radius = radius(fill_style.corner_radius),
    });
    if (!progress.show_percentage) return;
    // Over the middle of the whole bar, not after the filled part: the
    // number says how full the bar is, so it belongs to the bar and not to
    // the fill, and floating keeps it from pushing the fill about.
    layout.open(.{
        .floating = .{
            .anchor = .{ .element_x = .center, .element_y = .center, .parent_x = .center, .parent_y = .center },
            .z_index = 1,
        },
    });
    defer layout.close();
    var text: [16]u8 = undefined;
    layout.text(std.fmt.bufPrint(&text, "{d:.0}%", .{fraction * 100}) catch "", .{
        .font = context.app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
        .wrap = .none,
    });
}

/// What a button shows: its picture, then its words.
fn buttonFace(self: *ControlTree, context: Context, entity: Entity, button: *const Button, style: ResolvedStyle) void {
    const layout = context.layout;
    const words = context.app.textOf(entity, Button, "text");
    if (self.image(context.app, button.icon, .white, .full)) |drawn| {
        const side: f32 = @floatFromInt(@max(style.font_size, 1));
        var picture = drawn;
        picture.background_color = .transparent;
        layout.empty(.{ .width = .fixed(side), .height = .fixed(side), .image = picture });
    }
    if (words.len == 0) return;
    layout.text(words, .{
        .font = context.app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
        .wrap = .none,
        .alignment = boxAlignX(button.alignment),
    });
}

fn drawLabel(context: Context, entity: Entity, label: *const Label, style: ResolvedStyle) void {
    context.layout.text(context.app.textOf(entity, Label, "text"), .{
        .font = context.app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
        .outline = if (label.outline_width > 0) .{ .color = color(label.outline_color), .width = label.outline_width } else null,
        .alignment = boxAlignX(label.horizontal_alignment),
        .wrap = switch (label.wrap) {
            .words => .words,
            .newline => .newline,
            .none => .none,
        },
    });
}

/// Words with styles written into them, shown one letter after another
/// while a reveal is under way.
fn richContent(self: *ControlTree, context: Context, entity: Entity, rich: *RichText, style: ResolvedStyle) !void {
    const app = context.app;
    const words = app.textOf(entity, RichText, "text");
    if (rich.visible_characters >= 0 and context.interactive and app.time.delta > 0) {
        rich.revealed += app.time.delta * @max(rich.reveal_speed, 0);
        const total = characters(app.gpa, words);
        const reached: usize = @intFromFloat(@max(0, @floor(rich.revealed)));
        if (reached >= total) {
            rich.visible_characters = -1;
            try app.signal(entity, RichText, .revealed).emit(.{});
        } else rich.visible_characters = @intCast(reached);
    }
    var pictures: Pictures = .{ .nodes = self, .app = app };
    context.layout.richText(words, .{
        .font = app.interface.addFont(style.font) catch 0,
        .font_size = style.font_size,
        .color = color(style.text_color),
    }, .{
        .bold_font = if (rich.bold_font.isNone()) null else app.interface.addFont(rich.bold_font) catch null,
        .visible = if (rich.visible_characters >= 0) @intCast(rich.visible_characters) else null,
        .image = .{ .context = &pictures, .find = Pictures.find },
    });
}

/// How many characters of markup a reader sees: its tags taken out.
fn characters(gpa: std.mem.Allocator, raw: []const u8) usize {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var spans: std.ArrayList(ui.markup.Span) = .empty;
    defer spans.deinit(gpa);
    const parsed = ui.markup.parse(&text, &spans, null, null, gpa, raw, null) catch return raw.len;
    return std.unicode.utf8CountCodepoints(parsed.text) catch parsed.text.len;
}

/// The pictures a rich text's `{img=...|}` tags name: textures by their
/// paths, read the first time one is named.
const Pictures = struct {
    nodes: *ControlTree,
    app: *App,

    fn find(context: ?*anyopaque, name: []const u8) ?ui.layout.Image {
        const self: *Pictures = @ptrCast(@alignCast(context.?));
        const handle = self.app.loadAsset(Assets.TextureHandle, name) catch return null;
        return self.nodes.image(self.app, handle, .white, .full);
    }
};

/// Where a control was laid out when the interface was last drawn, in the
/// units its anchors and offsets are in: see `App.controlRect`.
pub fn rectOf(app: *App, entity: Entity) ?Rect2 {
    var id: [48]u8 = undefined;
    const box = app.ui.boxOf(idOf(&id, entity)) orelse return null;
    const scale = if (app.interface.scale > 0) app.interface.scale else 1;
    return .init(box.x / scale, box.y / scale, box.width / scale, box.height / scale);
}

/// The name the element that takes a control's focus is declared with: a
/// field's is the input inside it.
pub fn focusIdOf(app: *App, buffer: []u8, entity: Entity) []const u8 {
    if (app.world.has(entity, LineEdit)) return std.fmt.bufPrint(buffer, "control-{d}-{d}-input", .{ entity.index, entity.generation }) catch "control-input";
    return idOf(buffer, entity);
}

/// A size between two anchors: that part of the parent, and the offsets'
/// difference more, within the size's own bounds.
fn stretched(size: Size, part: f32, pixels: f32) ui.Sizing {
    return .{ .kind = .percent, .fraction = part, .extra = pixels, .min = size.min, .max = size.max };
}

/// Which point of a pinned control is on its anchor, across or down.
fn growFraction(grow: Control.Grow) f32 {
    return switch (grow) {
        .end => 0,
        .begin => 1,
        .both => 0.5,
    };
}

pub fn color(value: Color) ui.Color {
    return .rgba(value.r, value.g, value.b, value.a);
}

fn boxAlignX(value: AlignX) ui.AlignX {
    return switch (value) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
}

fn boxAlignY(value: AlignY) ui.AlignY {
    return switch (value) {
        .top => .top,
        .center => .center,
        .bottom => .bottom,
    };
}

pub fn ratio(app: *App, handle: Assets.TextureHandle) ?f32 {
    const texture = app.assets.get(handle) orelse return null;
    return if (texture.height > 0) @as(f32, @floatFromInt(texture.width)) / @as(f32, @floatFromInt(texture.height)) else null;
}

/// The interface's shape for a control's choice of pointer.
fn cursorShape(choice: MouseCursor.Shape) ui.CursorShape {
    return switch (choice) {
        inline else => |named| @field(ui.CursorShape, @tagName(named)),
    };
}
