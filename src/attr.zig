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

const std = @import("std");
const reflect = @import("fluxion_reflect");
const AssetKind = @import("asset_kind.zig").AssetKind;

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

/// A setting that has to say something: a project's name.
pub const Required = struct {};

/// A setting shown only with the advanced settings on.
pub const Advanced = struct {};

/// A setting that takes effect when the program starts again - the game's,
/// for a project's; the editor's, for an editor's.
pub const Restart = struct {};

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
pub const Radius = struct {};

/// Half a width and a height, drawn as a box around the middle with handles
/// on its sides and corners: the `extents` of a box.
pub const Extents = struct {};

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

/// A value a type reaches through its own methods rather than through a
/// field: read with `get`, written with `set`, both in its
/// `reflect_methods`. For words kept as a buffer and a length, which a
/// field-by-field edit would leave disagreeing - or anything else a setter
/// keeps right. On the type:
///
/// ```zig
/// pub const reflect_attributes = .{fx.attr.Property{ .name = "text", .get = "slice", .set = "set" }};
/// ```
///
/// `get` takes the value alone and returns what `set` takes after it;
/// `App.registerComponents` does not compile a property that does not.
pub const Property = struct {
    name: []const u8,
    get: []const u8,
    set: []const u8,
};

/// Words a component keeps beside it rather than in a field, as long as
/// they need to be: kept by the app under its entity - see `texts.zig`. A
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

/// Stop the build at a property of `T`'s that names a method `T` does not
/// list in `reflect_methods`, or a getter and a setter that do not agree -
/// and at a placement naming fields `T` does not have, or of other types.
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
        if (@TypeOf(attribute) != Property) continue;
        const where = "fluxion-engine: " ++ @typeName(T) ++ "'s property " ++ attribute.name;
        inline for (.{ attribute.get, attribute.set }) |name| {
            if (!listed(T, name)) @compileError(where ++ " names " ++ name ++ ", which its reflect_methods does not list");
        }
        const get = @typeInfo(@TypeOf(@field(T, attribute.get))).@"fn";
        const set = @typeInfo(@TypeOf(@field(T, attribute.set))).@"fn";
        if (get.params.len != 1 or set.params.len != 2 or get.return_type.? != set.params[1].type.?) {
            @compileError(where ++ ": " ++ attribute.get ++ " should take the value alone, and return what " ++ attribute.set ++ " takes after it");
        }
    }
}

/// Whether `T`'s `reflect_methods` has `name`, in either of its shapes: a
/// list of names, or names with attributes.
fn listed(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "reflect_methods") or !@hasDecl(T, name)) return false;
    const Spec = @TypeOf(T.reflect_methods);
    if (!@typeInfo(Spec).@"struct".is_tuple) return @hasField(Spec, name);
    inline for (T.reflect_methods) |entry| {
        const entry_name = switch (@typeInfo(@TypeOf(entry))) {
            .enum_literal => @tagName(entry),
            else => entry,
        };
        if (std.mem.eql(u8, entry_name, name)) return true;
    }
    return false;
}
