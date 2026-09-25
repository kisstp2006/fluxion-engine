// SPDX-License-Identifier: BSD-3-Clause

//! A property of an entity: a component's field named by text, found once
//! and written from then on as fast as a field is - what a tween and an
//! animation's track move.
//!
//! ```zig
//! const alpha = try Property.compile(app, "Appearance.modulate.a");
//! _ = alpha.write(app, panel, .{ .number = 0.5 });
//! const place = try Property.compile(app, "Transform2D.x,y");   // two numbers as a vector
//! const where = place.read(app, panel).?.vec2;
//! ```
//!
//! **The text** is the component's scene name, a dot, and the field's path
//! in it as Zig spells it: `Transform2D.rotation`, `Sprite.tint`,
//! `Appearance.modulate.a`, `Control.offset_left`. Two paths after the dot,
//! with a comma between, are one vector: `Transform2D.x,y`,
//! `Transform2D.scale_x,scale_y`, `Control.offset_left,offset_top`.
//!
//! **What moves**: a number - any float or integer, an integer rounded -, a
//! `Vec2`, a `Color`, and a `bool`, which does not go between two values
//! but jumps from one to the other at the end. So does a name kept in a
//! `[N]u8` - an animated sprite's `animation` -, cut to fit the field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const math = @import("fluxion_math");
const reflect = @import("fluxion_reflect");
const ecs = @import("fluxion_ecs");

const App = @import("App.zig");
const Color = @import("color.zig").Color;

/// What a property holds, as a tween and a track move it.
pub const Value = union(enum) {
    number: f64,
    vec2: [2]f32,
    color: [4]f32,
    flag: bool,
    /// Text in a `[N]u8`, padded with zeros: see `nameOf` and `text`.
    name: [name_len]u8,

    /// The longest name a value holds: short enough that the whole value is
    /// one a script can hand `App.tweenProperty`, which takes an argument of
    /// 64 bytes at most.
    pub const name_len = 56;

    comptime {
        std.debug.assert(@sizeOf(Value) <= 64);
    }

    /// `text` as a name, cut to `name_len` bytes.
    pub fn nameOf(said: []const u8) Value {
        var out: [name_len]u8 = @splat(0);
        const kept = @min(said.len, name_len);
        @memcpy(out[0..kept], said[0..kept]);
        return .{ .name = out };
    }

    /// A name's text, without the zeros after it.
    pub fn text(self: *const Value) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub const reflect_name = "AnimatedValue";

    /// Part `t` of the way from `a` to `b`, `t` as a curve has shaped it and
    /// so perhaps past either end. A flag is `a` until the end, and a value
    /// of another kind than `a`'s is `b`.
    pub fn lerp(a: Value, b: Value, t: f32) Value {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return b;
        return switch (a) {
            .number => |from| .{ .number = from + (b.number - from) * t },
            .vec2 => |from| .{ .vec2 = .{ from[0] + (b.vec2[0] - from[0]) * t, from[1] + (b.vec2[1] - from[1]) * t } },
            .color => |from| blk: {
                var out: [4]f32 = undefined;
                for (&out, from, b.color) |*into, x, y| into.* = x + (y - x) * t;
                break :blk .{ .color = out };
            },
            .flag, .name => if (t >= 1) b else a,
        };
    }

    /// `b` added to `a`: what a move by is from where it starts.
    pub fn plus(a: Value, b: Value) Value {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return b;
        return switch (a) {
            .number => |x| .{ .number = x + b.number },
            .vec2 => |x| .{ .vec2 = .{ x[0] + b.vec2[0], x[1] + b.vec2[1] } },
            .color => |x| .{ .color = .{ x[0] + b.color[0], x[1] + b.color[1], x[2] + b.color[2], x[3] + b.color[3] } },
            .flag, .name => b,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.meta.eql(a, b);
    }

    /// Of the kind `kind`, from what `self` is: a number to a flag by
    /// whether it is nought, a flag to a number as 0 or 1. Null for what
    /// does not become one.
    pub fn as(self: Value, kind: Kind) ?Value {
        if (std.meta.activeTag(self) == kind) return self;
        return switch (kind) {
            .number => switch (self) {
                .flag => |on| .{ .number = if (on) 1 else 0 },
                else => null,
            },
            .flag => switch (self) {
                .number => |x| .{ .flag = x != 0 },
                else => null,
            },
            else => null,
        };
    }
};

pub const Kind = std.meta.Tag(Value);

pub const Error = error{
    /// No `Component.` before the path.
    NoComponent,
    /// No component is registered under that name.
    NoSuchComponent,
    /// The component has no field on that path.
    NoSuchField,
    /// A field of a kind nothing moves: a slice, a list, a handle.
    NotAnimatable,
    /// Two paths that are not both numbers.
    NotAVector,
};

/// One field a property writes: where in the component, and what it is.
const Leaf = struct {
    offset: usize,
    scalar: Scalar,
    /// How many bytes a name's field holds.
    len: usize = 0,
};

const Scalar = enum { f32, f64, i8, i16, i32, i64, u8, u16, u32, u64, bool, vec2, color, name };

pub const Property = struct {
    /// The component, by its place among `app.scene_components`.
    component: usize,
    kind: Kind,
    leaves: [2]Leaf,
    /// One, or two for a vector made of two numbers.
    count: u8,

    /// The property `path` names. See the top of this file.
    pub fn compile(app: *App, path: []const u8) Error!Property {
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse return error.NoComponent;
        const name = path[0..dot];
        const entries = app.scene_components.entries.items;
        const component = for (entries, 0..) |entry, at| {
            if (std.mem.eql(u8, entry.name, name)) break at;
        } else return error.NoSuchComponent;
        const owner = entries[component].type;
        const rest = path[dot + 1 ..];

        if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
            const first = try leafAt(owner, rest[0..comma]);
            const second = try leafAt(owner, rest[comma + 1 ..]);
            if (!isNumber(first.scalar) or !isNumber(second.scalar)) return error.NotAVector;
            return .{ .component = component, .kind = .vec2, .leaves = .{ first, second }, .count = 2 };
        }
        const leaf = try leafAt(owner, rest);
        const kind: Kind = switch (leaf.scalar) {
            .vec2 => .vec2,
            .color => .color,
            .bool => .flag,
            .name => .name,
            else => .number,
        };
        return .{ .component = component, .kind = kind, .leaves = .{ leaf, leaf }, .count = 1 };
    }

    /// What it holds on `entity`, or null for an entity without its
    /// component.
    pub fn read(self: Property, app: *App, entity: ecs.Entity) ?Value {
        const cell = self.cellOf(app, entity) orelse return null;
        if (self.count == 2) return .{ .vec2 = .{
            @floatCast(numberAt(cell + self.leaves[0].offset, self.leaves[0].scalar)),
            @floatCast(numberAt(cell + self.leaves[1].offset, self.leaves[1].scalar)),
        } };
        const leaf = self.leaves[0];
        const at = cell + leaf.offset;
        return switch (leaf.scalar) {
            .bool => .{ .flag = @as(*const bool, @ptrCast(at)).* },
            .vec2 => .{ .vec2 = @as(*align(1) const [2]f32, @ptrCast(at)).* },
            .color => .{ .color = @as(*align(1) const [4]f32, @ptrCast(at)).* },
            .name => Value.nameOf(std.mem.sliceTo(at[0..leaf.len], 0)),
            else => .{ .number = numberAt(at, leaf.scalar) },
        };
    }

    /// Give `entity`'s component `value`, made the kind the property holds.
    /// False for an entity without its component, or a value that is not
    /// one of its kind.
    pub fn write(self: Property, app: *App, entity: ecs.Entity, value: Value) bool {
        const given = value.as(self.kind) orelse return false;
        const cell = self.cellOf(app, entity) orelse return false;
        if (self.count == 2) {
            setNumber(cell + self.leaves[0].offset, self.leaves[0].scalar, given.vec2[0]);
            setNumber(cell + self.leaves[1].offset, self.leaves[1].scalar, given.vec2[1]);
            return true;
        }
        const leaf = self.leaves[0];
        const at = cell + leaf.offset;
        switch (leaf.scalar) {
            .bool => @as(*bool, @ptrCast(at)).* = given.flag,
            .vec2 => @as(*align(1) [2]f32, @ptrCast(at)).* = given.vec2,
            .color => @as(*align(1) [4]f32, @ptrCast(at)).* = given.color,
            .name => {
                const into = at[0..leaf.len];
                const said = given.text();
                const kept = @min(said.len, into.len);
                @memset(into, 0);
                @memcpy(into[0..kept], said[0..kept]);
            },
            else => setNumber(at, leaf.scalar, given.number),
        }
        return true;
    }

    fn cellOf(self: Property, app: *App, entity: ecs.Entity) ?[*]u8 {
        const entry = &app.scene_components.entries.items[self.component];
        const id = entry.findIdIn(&app.world) orelse return null;
        return app.world.cellOf(entity, id);
    }
};

/// The field on `path` in a value of `owner`, and where it is.
fn leafAt(owner: *const reflect.Type, path: []const u8) Error!Leaf {
    if (path.len == 0) return error.NoSuchField;
    var kind = owner;
    var offset: usize = 0;
    var steps = std.mem.splitScalar(u8, path, '.');
    while (steps.next()) |name| {
        // A vector's or a colour's own fields are numbers like any other.
        const field = kind.field(name) orelse return error.NoSuchField;
        if (field.is_bit_field or field.is_comptime) return error.NotAnimatable;
        offset += field.offset;
        kind = field.type;
    }
    return .{ .offset = offset, .scalar = try scalarOf(kind), .len = kind.size };
}

fn scalarOf(kind: *const reflect.Type) Error!Scalar {
    if (kind.is(math.Vec2)) return .vec2;
    if (kind.is(Color)) return .color;
    return switch (kind.kind) {
        .array => if (kind.isString()) .name else error.NotAnimatable,
        .bool => .bool,
        .float => switch (kind.size) {
            4 => .f32,
            8 => .f64,
            else => error.NotAnimatable,
        },
        .int => {
            const info = kind.info.int;
            return switch (info.bits) {
                8 => if (info.signed) .i8 else .u8,
                16 => if (info.signed) .i16 else .u16,
                32 => if (info.signed) .i32 else .u32,
                64 => if (info.signed) .i64 else .u64,
                else => error.NotAnimatable,
            };
        },
        else => error.NotAnimatable,
    };
}

fn isNumber(scalar: Scalar) bool {
    return switch (scalar) {
        .bool, .vec2, .color, .name => false,
        else => true,
    };
}

fn numberAt(at: [*]u8, scalar: Scalar) f64 {
    return switch (scalar) {
        .f32 => @as(*align(1) const f32, @ptrCast(at)).*,
        .f64 => @as(*align(1) const f64, @ptrCast(at)).*,
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |which| @floatFromInt(@as(*align(1) const IntOf(which), @ptrCast(at)).*),
        .bool, .vec2, .color, .name => 0,
    };
}

fn setNumber(at: [*]u8, scalar: Scalar, value: f64) void {
    switch (scalar) {
        .f32 => @as(*align(1) f32, @ptrCast(at)).* = @floatCast(value),
        .f64 => @as(*align(1) f64, @ptrCast(at)).* = value,
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |which| {
            const T = IntOf(which);
            const rounded = @round(if (std.math.isFinite(value)) value else 0);
            const kept = std.math.clamp(rounded, @as(f64, @floatFromInt(std.math.minInt(T))), @as(f64, @floatFromInt(std.math.maxInt(T))));
            @as(*align(1) T, @ptrCast(at)).* = @intFromFloat(kept);
        },
        .bool, .vec2, .color, .name => {},
    }
}

fn IntOf(comptime scalar: Scalar) type {
    return switch (scalar) {
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        else => unreachable,
    };
}

test "a value goes part of the way to another, a flag at the end" {
    try testing.expectEqual(@as(f64, 2.5), (Value.lerp(.{ .number = 0 }, .{ .number = 10 }, 0.25)).number);
    const half = Value.lerp(.{ .color = .{ 0, 0, 0, 1 } }, .{ .color = .{ 1, 1, 1, 0 } }, 0.5).color;
    try testing.expectEqual(@as(f32, 0.5), half[3]);
    try testing.expect(!Value.lerp(.{ .flag = false }, .{ .flag = true }, 0.99).flag);
    try testing.expect(Value.lerp(.{ .flag = false }, .{ .flag = true }, 1).flag);
    try testing.expectEqual(@as(f64, 1), (Value{ .flag = true }).as(.number).?.number);
    try testing.expect((Value{ .vec2 = .{ 1, 2 } }).as(.color) == null);
    const run = Value.nameOf("run");
    try testing.expectEqualStrings("run", run.text());
    try testing.expectEqualStrings("idle", Value.lerp(.nameOf("idle"), run, 0.99).text());
    try testing.expectEqualStrings("run", Value.lerp(.nameOf("idle"), run, 1).text());
    try testing.expect(run.as(.number) == null);
}
