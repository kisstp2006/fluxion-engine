// SPDX-License-Identifier: BSD-3-Clause

//! What a field means, for an inspector to show it by: the five attributes
//! fluxion-reflect spells for every Fluxion tool, and the ones a game's
//! components want: how a number reads, and what a shape is to be dragged by. An attribute is found by its type, so one namespace is
//! all an inspector imports:
//!
//! ```zig
//! pub const reflect_fields = .{
//!     .heading = .{fx.attr.Angle{}},
//!     .speed = .{ fx.attr.Unit{ .text = "/s" }, fx.attr.Range{ .min = 0, .max = 400 } },
//!     .hits = .{fx.attr.Layers{}},
//! };
//!
//! if (field.attribute(fx.attr.Angle)) |_| degrees(value) else number(value);
//! ```
//!
//! Any value can be an attribute; these are the ones worth one spelling
//! between the engine, a game and an editor.

const reflect = @import("fluxion_reflect");
const AssetKind = @import("../assets/asset_kind.zig").AssetKind;

/// The span a number is meant to keep to, and the step to move it by.
pub const Range = reflect.attr.Range;

/// A line about it, for a tooltip.
pub const Doc = reflect.attr.Doc;

/// What a person sees instead of the name.
pub const Label = reflect.attr.Label;

/// Kept out of an inspector's view.
pub const Hidden = reflect.attr.Hidden;

/// Shown, and not to be changed by hand.
pub const ReadOnly = reflect.attr.ReadOnly;

/// The names of a method's parameters, `self` not among them: what a
/// script's completion shows.
pub const Params = reflect.attr.Params;

/// What a method's last parameters are when a call leaves them out:
/// `attr.defaults(.{ "", 1.0, false })`.
pub const defaults = reflect.attr.defaults;

/// A field written through a method of its type's that takes the new value:
/// a change with more to do than be stored. A script's write goes through it.
pub const Setter = reflect.attr.Setter;

/// State the engine works out while the game runs - whether a sprite plays,
/// what its pass saw last - never written to a scene, and so never an
/// instance's difference from its scene either.
pub const Unsaved = struct {};

/// An angle, kept in radians and shown in degrees. With a `Unit`, the unit
/// comes after the degrees: an angle a second.
pub const Angle = struct {};

/// What a number counts, written after it: `"px"`, `"s"`, `"/s"`.
pub const Unit = struct {
    text: []const u8,
};

/// An integer whose bits are each a layer, on or off: shown as a row of
/// toggles, one a bit, rather than as a number, each with the name the
/// project gives it.
pub const Layers = struct {
    /// Which of the project's lists names the layers.
    names: Names = .none,

    pub const Names = enum {
        /// None: the layers are their numbers.
        none,
        /// `layer_names.physics_2d` in `project.fluxion`.
        physics_2d,
        /// `layer_names.render_2d`.
        render_2d,
    };
};

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
//
// What a setting of a settings file is, besides its value: see
// `settings_file.zig`. An editor draws its settings windows by them.

/// Text that names a file of the project's - `res://` or `uid://`, or empty -
/// of this kind, or of any kind when it says none: checked when the file is
/// read and written, and shown as a field that takes a file of the kind.
pub const ProjectFile = struct {
    kind: ?AssetKind = null,
};

/// Text that names one of the project's audio buses - `audio.buses` - which
/// an editor offers to choose from.
pub const AudioBus = struct {};

/// Text that names one of the project's input actions - its own and the
/// built-in ones - which an editor offers to choose from.
pub const InputAction = struct {};

/// Text that names a locale - `hu-HU`, `en-US` - which an editor offers
/// from a list, and takes any the system knows.
pub const Locale = struct {};

/// A setting that has to say something: a project's name.
pub const Required = struct {};

/// A setting shown only with the advanced settings on.
pub const Advanced = struct {};

/// A setting that takes effect when the program starts again - the game's,
/// for a project's; the editor's, for an editor's.
pub const Restart = struct {};

/// On a field: it and the fields after it are a group, under this heading
/// in an editor - a component of many fields, read a part at a time.
pub const Group = struct { name: []const u8 };

/// On a component: whether a click in an editor's scene picks an entity
/// that has it, until the entity is told otherwise there. A `Control`'s is
/// false - a UI over the whole screen would take every click - and a game's
/// own component may say the same. An entity is passed over when any of its
/// components says false; the list of everything under the pointer still
/// offers it, and the tree picks it as ever.
///
/// ```zig
/// pub const reflect_attributes = .{fx.attr.Pickable{ .by_default = false }};
/// ```
pub const Pickable = struct { by_default: bool = true };

// -------------------------------------------------------------------------
// Geometry an editor can draw and drag
// -------------------------------------------------------------------------
//
// Each says what a field is in the entity's own space - the transform's, and
// then the component's `Placement` - so an editor draws and drags it without
// knowing the component.

/// A radius, drawn as a circle with a handle on it.
pub const Radius = struct { when: ?When = null };

/// Half a width and a height, drawn as a box around the middle with handles
/// on its sides and corners: the `extents` of a box.
pub const Extents = struct { when: ?When = null };

/// Half a height along `y`, with round ends of the radius in the field
/// `radius` names: a capsule standing up, drawn with handles on its ends and
/// its sides.
pub const Capsule = struct { radius: []const u8, when: ?When = null };

/// When a shape above is the component's: while its enum field `field`
/// holds one of the members `is` names. A collider's box is its shape only
/// while it is a rectangle.
pub const When = struct {
    field: []const u8,
    is: []const []const u8,
};

/// On a component whose geometry sits away from its entity's origin: the
/// fields that say where, which every field above is drawn from. A
/// `math.Vec2` and an angle in radians.
///
/// ```zig
/// pub const reflect_attributes = .{fx.attr.Placement{ .offset = "offset", .rotation = "rotation" }};
/// ```
pub const Placement = struct {
    offset: []const u8,
    rotation: []const u8,
};

/// Text that may run over several lines. On a function that takes text - a
/// setter - it says so of that text.
pub const Multiline = struct {};

/// Words a component keeps beside it rather than in a field, as long as
/// they need to be: kept by the app under its entity - see `component_texts.zig`. A
/// scene writes them among the component's fields, an editor shows them as
/// one, and a script reads and writes them as one: `label.text`.
///
/// ```zig
/// pub const reflect_attributes = .{fx.attr.Text{ .name = "text", .multiline = true }};
/// ```
pub const Text = struct {
    name: []const u8,
    /// Whether it may run over several lines.
    multiline: bool = false,
};

/// Stop the build at a placement of `T`'s naming fields `T` does not have,
/// or of other types.
pub fn check(comptime T: type) void {
    if (!@hasDecl(T, "reflect_attributes")) return;
    inline for (T.reflect_attributes) |attribute| {
        if (@TypeOf(attribute) == Placement) {
            const where = "fluxion-engine: " ++ @typeName(T) ++ "'s placement";
            if (!@hasField(T, attribute.offset) or @FieldType(T, attribute.offset) != @import("fluxion_math").Vec2) {
                @compileError(where ++ " names " ++ attribute.offset ++ ", which is not a math.Vec2 field of it");
            }
            if (!@hasField(T, attribute.rotation) or @FieldType(T, attribute.rotation) != f32) {
                @compileError(where ++ " names " ++ attribute.rotation ++ ", which is not an f32 field of it");
            }
        }
    }
}
