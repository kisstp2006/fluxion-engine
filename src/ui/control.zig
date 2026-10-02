// SPDX-License-Identifier: BSD-3-Clause

//! Scene components that declare Fluxion UI. `Control` is the common box;
//! the other components add layout, appearance or behaviour to it.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const ui = @import("fluxion_ui");

const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const Region = @import("../scene/components.zig").Region;
const attr = @import("../reflect/attr.zig");
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

/// Where something sits across the room it has: words in a label, a
/// button's face, a box container's children.
pub const AlignX = enum(u8) { left, center, right };
/// The same, down.
pub const AlignY = enum(u8) { top, center, bottom };

pub const Size = extern struct {
    mode: Mode = .fit,
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    weight: f32 = 1,

    pub const Mode = enum(u8) { fit, fixed, grow, percent, ratio };

    pub fn layout(self: Size) ui.Sizing {
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

/// The rectangular base of every UI entity.
pub const Control = extern struct {
    /// The `.theme` file this control and everything under it is drawn from.
    /// `.none` takes whatever the control above it uses. Its text
    /// `type_variation` is a name in that theme to be drawn as, over the kind
    /// of control this is: a "Header" built on "Label" is one Label among
    /// many that is drawn differently.
    theme: ThemeHandle = .none,
    width: Size = .{},
    height: Size = .{},
    position: Position = .flow,
    /// Where an anchored control is held in its parent, as parts of it:
    /// nought is the parent's left or top edge, one its right or bottom. See
    /// `Position.anchored`.
    anchor_left: f32 = 0,
    anchor_top: f32 = 0,
    anchor_right: f32 = 0,
    anchor_bottom: f32 = 0,
    /// Pixels from each anchor to the control's edge.
    offset_left: f32 = 0,
    offset_top: f32 = 0,
    offset_right: f32 = 0,
    offset_bottom: f32 = 0,
    /// Which way a pinned control grows from its anchor: see `Grow`.
    grow_horizontal: Grow = .end,
    grow_vertical: Grow = .end,
    visible: bool = true,
    /// Whether what it holds is cut off at its edges: all of it, in its flow
    /// or anchored.
    clip: bool = false,
    mouse_filter: MouseFilter = .pass,
    z_index: i16 = 0,
    /// How big it and everything in it is drawn, about its middle: one as it
    /// is laid out. The layout does not change, and neither does the room
    /// it takes: what a button popping in is drawn with.
    scale: f32 = 1,

    /// In its parent's flow - one after another, as a box container lays
    /// them out - or **anchored**: held between two points of its parent on
    /// each axis, `anchor_left` and `anchor_right` across, `anchor_top` and
    /// `anchor_bottom` down. Two that differ **stretch** it: its edges are
    /// its offsets from them, and it resizes with its parent. Two that are
    /// the same **pin** it: it keeps its own `width` or `height`, and sits
    /// `offset_left` or `offset_top` from the point, growing the way `Grow`
    /// says.
    pub const Position = enum(u8) { flow, anchored };
    /// Which way a pinned control grows from its anchor: right or down from
    /// it, `end`; left or up, `begin`; or both, with its middle on it.
    pub const Grow = enum(u8) { begin, end, both };
    /// What the pointer does at a control. `stop`: it is taken here, and what
    /// the control is inside hears nothing of it. `pass`: it is found here and
    /// by what the control is inside, and not by what is behind it. `ignore`:
    /// it goes through to what is behind, as if the control were not there -
    /// a veil that fades in and out, a picture laid over buttons - and the
    /// control answers nothing; what is inside it still does. The root of a
    /// tree, which is inside nothing and is a whole layer, passes it on to the
    /// layers under it unless it stops it.
    pub const MouseFilter = enum(u8) { stop, pass, ignore };

    /// Where an anchored control goes, in one word.
    pub const AnchorsPreset = enum(u8) {
        top_left,
        top,
        top_right,
        left,
        center,
        right,
        bottom_left,
        bottom,
        bottom_right,
        left_wide,
        top_wide,
        right_wide,
        bottom_wide,
        vcenter_wide,
        hcenter_wide,
        full_rect,
    };

    /// The pointer came over it, and went; it took the keys, and lost them.
    pub const signals = .{
        .mouse_entered = struct {},
        .mouse_exited = struct {},
        .focus_entered = struct {},
        .focus_exited = struct {},
    };

    pub const reflect_name = "Control";
    pub const reflect_attributes = .{
        attr.Text{ .name = "type_variation" },
        attr.Text{ .name = "tooltip_text", .multiline = true },
        // A UI over the whole screen would take every click in the scene.
        attr.Pickable{ .by_default = false },
    };
    pub const reflect_fields = .{
        .anchor_left = .{attr.Range{ .min = 0, .max = 1 }},
        .anchor_top = .{attr.Range{ .min = 0, .max = 1 }},
        .anchor_right = .{attr.Range{ .min = 0, .max = 1 }},
        .anchor_bottom = .{attr.Range{ .min = 0, .max = 1 }},
        .offset_left = .{attr.Unit{ .text = "px" }},
        .offset_top = .{attr.Unit{ .text = "px" }},
        .offset_right = .{attr.Unit{ .text = "px" }},
        .offset_bottom = .{attr.Unit{ .text = "px" }},
    };
    pub const reflect_methods = .{
        .setAnchorsPreset = .{attr.Params{ .names = &.{"preset"} }},
    };

    /// Anchored where `preset` says, flush with its parent's edges or on its
    /// points: its offsets are nought, and a pinned axis grows away from the
    /// edge it is pinned to.
    pub fn setAnchorsPreset(self: *Control, preset: AnchorsPreset) void {
        const place: struct { l: f32, t: f32, r: f32, b: f32 } = switch (preset) {
            .top_left => .{ .l = 0, .t = 0, .r = 0, .b = 0 },
            .top => .{ .l = 0.5, .t = 0, .r = 0.5, .b = 0 },
            .top_right => .{ .l = 1, .t = 0, .r = 1, .b = 0 },
            .left => .{ .l = 0, .t = 0.5, .r = 0, .b = 0.5 },
            .center => .{ .l = 0.5, .t = 0.5, .r = 0.5, .b = 0.5 },
            .right => .{ .l = 1, .t = 0.5, .r = 1, .b = 0.5 },
            .bottom_left => .{ .l = 0, .t = 1, .r = 0, .b = 1 },
            .bottom => .{ .l = 0.5, .t = 1, .r = 0.5, .b = 1 },
            .bottom_right => .{ .l = 1, .t = 1, .r = 1, .b = 1 },
            .left_wide => .{ .l = 0, .t = 0, .r = 0, .b = 1 },
            .top_wide => .{ .l = 0, .t = 0, .r = 1, .b = 0 },
            .right_wide => .{ .l = 1, .t = 0, .r = 1, .b = 1 },
            .bottom_wide => .{ .l = 0, .t = 1, .r = 1, .b = 1 },
            .vcenter_wide => .{ .l = 0.5, .t = 0, .r = 0.5, .b = 1 },
            .hcenter_wide => .{ .l = 0, .t = 0.5, .r = 1, .b = 0.5 },
            .full_rect => .{ .l = 0, .t = 0, .r = 1, .b = 1 },
        };
        self.position = .anchored;
        self.anchor_left = place.l;
        self.anchor_top = place.t;
        self.anchor_right = place.r;
        self.anchor_bottom = place.b;
        self.offset_left = 0;
        self.offset_top = 0;
        self.offset_right = 0;
        self.offset_bottom = 0;
        self.grow_horizontal = growFrom(place.l);
        self.grow_vertical = growFrom(place.t);
    }

    fn growFrom(anchor: f32) Grow {
        if (anchor >= 1) return .begin;
        if (anchor > 0) return .both;
        return .end;
    }

    /// Which preset its anchors are, if they are one.
    pub fn anchorsPreset(self: *const Control) ?AnchorsPreset {
        if (self.position != .anchored) return null;
        for (std.enums.values(AnchorsPreset)) |preset| {
            var probe: Control = .{};
            probe.setAnchorsPreset(preset);
            if (probe.anchor_left == self.anchor_left and probe.anchor_top == self.anchor_top and
                probe.anchor_right == self.anchor_right and probe.anchor_bottom == self.anchor_bottom) return preset;
        }
        return null;
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

/// What one control says of its own look, over its theme: its theme
/// overrides. Each is the control's own only while its switch is on; the
/// rest stays the theme's. It lies over what every theme says of the normal
/// look and under what one says of hovering, pressing and the rest, so a
/// button of its own colour still answers the pointer where its theme says
/// how. It is the control's own part it changes - a slider's track, not its
/// fill - and not its children's.
pub const ThemeOverride = extern struct {
    override_font_color: bool = false,
    font_color: Color = .white,
    override_font_size: bool = false,
    font_size: u16 = 16,
    override_font: bool = false,
    font: Assets.FontHandle = .none,
    override_background: bool = false,
    background: Color = .black,
    override_border: bool = false,
    border_color: Color = .white,
    border_width: u16 = 1,
    override_corners: bool = false,
    corner_radius: f32 = 4,
    override_padding: bool = false,
    padding: Insets = .{},

    pub const reflect_name = "ThemeOverride";
    pub const reflect_fields = .{
        .font_size = .{attr.Range{ .min = 1, .max = 256 }},
        .border_width = .{ attr.Range{ .min = 0, .max = 64 }, attr.Unit{ .text = "px" } },
        .corner_radius = .{ attr.Range{ .min = 0, .max = 128 }, attr.Unit{ .text = "px" } },
    };
    pub const reflect_methods = .{ .styleBox = .{}, .setStyleBox = .{attr.Params{ .names = &.{"box"} }} };

    /// Its box as one value: what it says of the background, the border, the
    /// corners and the padding.
    pub fn styleBox(self: *const ThemeOverride) StyleBox {
        return .{
            .background = self.background,
            .border_color = self.border_color,
            .border_width = self.border_width,
            .corner_radius = self.corner_radius,
            .padding = self.padding,
        };
    }

    /// Say all of `box` of its box, each switched on.
    pub fn setStyleBox(self: *ThemeOverride, box: StyleBox) void {
        self.override_background = true;
        self.background = box.background;
        self.override_border = true;
        self.border_color = box.border_color;
        self.border_width = box.border_width;
        self.override_corners = true;
        self.corner_radius = box.corner_radius;
        self.override_padding = true;
        self.padding = box.padding;
    }

    /// What it says, as a theme says it: only what is switched on.
    pub fn style(self: ThemeOverride) theme_file.Style {
        var out: theme_file.Style = .{};
        if (self.override_font_color) out.font_color = self.font_color;
        if (self.override_font_size) out.font_size = self.font_size;
        if (self.override_font) out.font = self.font;
        if (self.override_background) out.background = self.background;
        if (self.override_border) {
            out.border_color = self.border_color;
            out.border_width = self.border_width;
        }
        if (self.override_corners) out.corners = .all(self.corner_radius);
        if (self.override_padding) out.padding = self.padding;
        return out;
    }
};

/// Words in a control. What they say is the app's, as long as it is: see
/// `component_texts.zig`.
pub const Label = extern struct {
    /// Drawn round the letters, which no theme says: a label over a picture
    /// needs it and a label on a panel does not.
    outline_color: Color = .black,
    outline_width: u16 = 0,
    /// What the words do where the label has no room for them: never run
    /// out of it. `words` breaks between words, and inside a word too long
    /// for a line; `newline` breaks only at the text's own newlines, a line
    /// too long ending in an ellipsis; `none` is one line, the first,
    /// ending in an ellipsis where it does not fit.
    wrap: Wrap = .words,
    /// Where the words sit in the label's box, and each line among the
    /// others: a title across the top in the middle, a number on the right.
    horizontal_alignment: AlignX = .left,
    vertical_alignment: AlignY = .top,

    pub const Wrap = enum(u8) { words, newline, none };
    pub const reflect_name = "Label";
    pub const reflect_attributes = .{attr.Text{ .name = "text", .multiline = true }};
};

/// A box that says what it does and hears that it was clicked. It carries
/// its own words and picture: a button is one thing, not a button with a
/// label inside it.
pub const Button = extern struct {
    /// Drawn before the words, where there is one.
    icon: Assets.TextureHandle = .none,
    disabled: bool = false,
    /// Whether it stays down when clicked, as a switch does.
    toggle_mode: bool = false,
    /// Whether it is down now, for one that stays down.
    button_pressed: bool = false,
    hovered: bool = false,
    held: bool = false,
    /// Where its picture and words sit across its box. Down, they are in its
    /// middle.
    alignment: AlignX = .center,

    pub const reflect_name = "Button";
    pub const reflect_attributes = .{attr.Text{ .name = "text" }};
    pub const reflect_fields = .{
        .hovered = .{attr.ReadOnly{}},
        .held = .{attr.ReadOnly{}},
    };
    /// Pressed is a press let go over it; `button_down` and `button_up` are
    /// the button going down on it and coming up again.
    pub const signals = .{ .pressed = struct {}, .toggled = struct { pressed: bool }, .button_down = struct {}, .button_up = struct {} };
};

pub const CheckBox = extern struct {
    checked: bool = false,
    disabled: bool = false,
    pub const reflect_name = "CheckBox";
    pub const signals = .{ .toggled = struct { checked: bool } };
};

/// Words to type. What is typed, and what shows before anything is, are
/// the app's: see `component_texts.zig`.
pub const LineEdit = extern struct {
    multiline: bool = false,
    password: bool = false,
    disabled: bool = false,
    /// How many characters may be typed; nought for no end.
    max_length: u32 = 0,

    pub const reflect_name = "LineEdit";
    pub const reflect_attributes = .{
        attr.Text{ .name = "text", .multiline = true },
        attr.Text{ .name = "placeholder_text" },
    };
    pub const signals = .{ .text_changed = struct {}, .text_submitted = struct {} };
};

pub const Slider = extern struct {
    min: f32 = 0,
    max: f32 = 100,
    value: f32 = 0,
    step: f32 = 1,
    vertical: bool = false,
    disabled: bool = false,
    pub const reflect_name = "Slider";
    pub const signals = .{ .value_changed = struct { value: f32 } };
};

pub const ProgressBar = extern struct {
    min: f32 = 0,
    max: f32 = 100,
    value: f32 = 0,
    show_percentage: bool = true,
    pub const reflect_name = "ProgressBar";
};

/// The pointer's shape over the control it is on - the hand, the caret, a
/// resize arrow - in place of the one its kind calls for: the hand over what
/// can be pressed, the caret over text, the game's default elsewhere (see
/// `App.setDefaultCursorShape`). A picture the game gave the shape is what
/// shows: see `App.setCustomCursor`.
pub const MouseCursor = extern struct {
    shape: Shape = .arrow,

    pub const Shape = enum(u8) {
        arrow,
        ibeam,
        crosshair,
        pointing_hand,
        resize_ew,
        resize_ns,
        resize_nwse,
        resize_nesw,
        resize_all,
        not_allowed,
    };
    pub const reflect_name = "MouseCursor";
};

/// How a control takes the keyboard's and a pad's focus, beside its
/// `Control`: without one, a button, a box and a slider take it from a press,
/// Tab and the arrows, and the rest do not; a field always does.
pub const Focus = extern struct {
    mode: Mode = .all,
    /// Where the arrows, Tab and Shift+Tab go from it, when not to the
    /// nearest that way or the next declared. `.none` for that.
    left: Entity = .none,
    right: Entity = .none,
    up: Entity = .none,
    down: Entity = .none,
    next: Entity = .none,
    previous: Entity = .none,

    /// `none`; `click`, from a press on it and nothing else; `all`, from a
    /// press, Tab and the arrows.
    pub const Mode = enum(u8) { none, click, all };
    pub const reflect_name = "Focus";
};

/// A box of one colour: a backdrop, a fade to black, a bar.
pub const ColorRect = extern struct {
    color: Color = .white,
    pub const reflect_name = "ColorRect";
};

/// Words with styles written into them - `{color=red|...}`, `{b|heavy}`,
/// `{size=24|large}`, `{img=res://icons/key.png|}` and every other tag
/// fluxion-ui's markup reads - wrapping between words, each set in its own
/// size and weight. The words are the app's: see `component_texts.zig`.
///
/// **One letter after another**, for credits and a line of dialogue: with a
/// `reveal_speed`, `reveal()` shows them from the first at that many a
/// second, each keeping its room so nothing moves as they come, and
/// `revealed` is said when the last shows. `visible_characters` is how many
/// show, -1 for all of them.
pub const RichText = extern struct {
    visible_characters: i32 = -1,
    /// Characters a second `reveal()` shows them at.
    reveal_speed: f32 = 30,
    /// The font a `{b|...}` stretch is set in; `.none` draws the words' own
    /// font with an outline of their colour.
    bold_font: Assets.FontHandle = .none,
    /// How far the reveal has come, in characters.
    revealed: f32 = 0,

    pub const reflect_name = "RichText";
    pub const reflect_attributes = .{attr.Text{ .name = "text", .multiline = true }};
    pub const reflect_fields = .{
        .reveal_speed = .{attr.Unit{ .text = "/s" }},
        .revealed = .{attr.Hidden{}},
    };
    pub const reflect_methods = .{ .reveal = .{}, .showAll = .{} };
    pub const signals = .{ .revealed = struct {} };

    /// Show the words from the first, one after another.
    pub fn reveal(self: *RichText) void {
        self.revealed = 0;
        self.visible_characters = 0;
    }

    /// Show all of them at once.
    pub fn showAll(self: *RichText) void {
        self.visible_characters = -1;
    }
};

/// A box over everything else while it is open, in the middle of the screen
/// or where its control's own place says: a dialog, a pause menu. What is in
/// it is its children, drawn as any control's are.
///
/// **Modal**, what is under it takes no clicks, behind a veil. A press
/// outside it, or the `ui_cancel` action, closes it when it says so, and
/// `closed` is said whenever it closes.
pub const Popup = extern struct {
    open: bool = false,
    modal: bool = true,
    close_on_click_outside: bool = true,
    /// In the middle of the screen; off, where its control's place puts it.
    centered: bool = true,
    /// The veil drawn over what is under a modal one.
    veil: Color = .rgba(0, 0, 0, 0.5),
    /// Open when it was last drawn, to say `closed` when it no longer is.
    was_open: bool = false,

    pub const reflect_name = "Popup";
    pub const reflect_fields = .{ .was_open = .{attr.Hidden{}} };
    pub const reflect_methods = .{ .popup = .{}, .hide = .{} };
    pub const signals = .{ .closed = struct {} };

    pub fn popup(self: *Popup) void {
        self.open = true;
    }

    pub fn hide(self: *Popup) void {
        self.open = false;
    }
};

/// What a `ThemeOverride` says of a control's box, as one value: from a
/// script, `override.setStyleBox(box)` after `var box = override.styleBox()`.
pub const StyleBox = extern struct {
    background: Color = .black,
    border_color: Color = .white,
    border_width: u16 = 0,
    corner_radius: f32 = 0,
    padding: Insets = .{},
    pub const reflect_name = "StyleBox";
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
