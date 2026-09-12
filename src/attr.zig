// SPDX-License-Identifier: BSD-3-Clause

//! What a field means, for an inspector to show it by: the five attributes
//! fluxion-reflect spells for every Fluxion tool, and five more that a game's
//! components want. An attribute is found by its type, so one namespace is
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
/// toggles, one a bit, rather than as a number.
pub const Layers = struct {};

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

/// Stop the build at a property of `T`'s that names a method `T` does not
/// list in `reflect_methods`, or a getter and a setter that do not agree.
pub fn check(comptime T: type) void {
    if (!@hasDecl(T, "reflect_attributes")) return;
    inline for (T.reflect_attributes) |attribute| {
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
