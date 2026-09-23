// SPDX-License-Identifier: BSD-3-Clause

//! A colour, and the three ways people write one down.
//!
//! ```zig
//! const sky: Color = .hex(0x14161A);
//! const ghost: Color = .rgba(1, 1, 1, 0.4);
//! const accent: Color = .oklch(0.7, 0.14, 250);
//! ```
//!
//! Four floats from zero to one, as the GPU takes them. The same shape as
//! fluxion-ui's `Color`, so one can become an alias of the other when the
//! interface layer arrives.

const std = @import("std");
const testing = std.testing;

const attr = @import("attr.zig");

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

    pub const reflect_name = "Color";
    pub const reflect_fields = .{
        .r = .{attr.Range{ .min = 0, .max = 1 }},
        .g = .{attr.Range{ .min = 0, .max = 1 }},
        .b = .{attr.Range{ .min = 0, .max = 1 }},
        .a = .{attr.Range{ .min = 0, .max = 1 }},
    };

    /// `0xRRGGBB`, opaque.
    pub inline fn hex(value: u24) Color {
        return .{
            .r = channel(@intCast((value >> 16) & 0xFF)),
            .g = channel(@intCast((value >> 8) & 0xFF)),
            .b = channel(@intCast(value & 0xFF)),
            .a = 1,
        };
    }

    /// `0xRRGGBBAA`: the alpha is last, as in CSS.
    pub inline fn hexa(value: u32) Color {
        return .{
            .r = channel(@intCast((value >> 24) & 0xFF)),
            .g = channel(@intCast((value >> 16) & 0xFF)),
            .b = channel(@intCast((value >> 8) & 0xFF)),
            .a = channel(@intCast(value & 0xFF)),
        };
    }

    /// A colour written as text: `#RRGGBB` or `#RRGGBBAA`, or the short
    /// `#RGB` and `#RGBA`, the `#` optional and spaces round it allowed.
    /// Null for anything else.
    pub fn parse(text: []const u8) ?Color {
        const digits = std.mem.trimStart(u8, std.mem.trim(u8, text, " "), "#");
        var bytes: [4]u8 = .{ 0, 0, 0, 255 };
        switch (digits.len) {
            3, 4 => for (digits, 0..) |digit, i| {
                const nibble = std.fmt.charToDigit(digit, 16) catch return null;
                bytes[i] = nibble * 17;
            },
            6, 8 => for (0..digits.len / 2) |i| {
                bytes[i] = std.fmt.parseInt(u8, digits[i * 2 ..][0..2], 16) catch return null;
            },
            else => return null,
        }
        return .{ .r = channel(bytes[0]), .g = channel(bytes[1]), .b = channel(bytes[2]), .a = channel(bytes[3]) };
    }

    pub inline fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub inline fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Lightness, chroma and hue, in OKLCH: even steps of hue look evenly
    /// spaced, and changing `l` alone does not change how colourful it looks.
    /// `l` is 0 to 1, `c` is about 0 to 0.4, `hue_degrees` goes round.
    pub fn oklch(l: f32, c: f32, hue_degrees: f32) Color {
        const h = hue_degrees * std.math.pi / 180.0;
        return oklab(l, c * @cos(h), c * @sin(h));
    }

    /// The same, in rectangular form.
    pub fn oklab(l: f32, a_axis: f32, b_axis: f32) Color {
        // Björn Ottosson's OKLab: to cone responses, cubed, then into linear
        // sRGB.
        const long = l + 0.3963377774 * a_axis + 0.2158037573 * b_axis;
        const medium = l - 0.1055613458 * a_axis - 0.0638541728 * b_axis;
        const short = l - 0.0894841775 * a_axis - 1.2914855480 * b_axis;

        const l3 = long * long * long;
        const m3 = medium * medium * medium;
        const s3 = short * short * short;

        return .{
            .r = encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            .g = encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            .b = encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
            .a = 1,
        };
    }

    /// The same colour at another opacity.
    pub fn withAlpha(self: Color, a: f32) Color {
        var out = self;
        out.a = a;
        return out;
    }

    /// Part of the way from one colour to another, in sRGB as stored - so the
    /// middle of two bright colours is a little dark. Go through `oklch` when
    /// that matters.
    pub fn mix(from: Color, to: Color, t: f32) Color {
        const k = std.math.clamp(t, 0, 1);
        return .{
            .r = from.r + (to.r - from.r) * k,
            .g = from.g + (to.g - from.g) * k,
            .b = from.b + (to.b - from.b) * k,
            .a = from.a + (to.a - from.a) * k,
        };
    }

    /// The four numbers as an array, as a clear colour and a vertex buffer
    /// take them.
    pub fn array(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    inline fn channel(byte: u8) f32 {
        return @as(f32, @floatFromInt(byte)) / 255.0;
    }

    /// Linear light to sRGB, clamped.
    fn encode(linear: f32) f32 {
        const x = std.math.clamp(linear, 0, 1);
        return if (x <= 0.0031308)
            12.92 * x
        else
            1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
    }
};

test "hex is the bytes divided down" {
    const c: Color = .hex(0xFF8000);
    try testing.expectApproxEqAbs(@as(f32, 1), c.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5019), c.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.b, 0.001);
    try testing.expectEqual(@as(f32, 1), c.a);
}

test "the alpha of hexa is the last byte, not the first" {
    const c: Color = .hexa(0x102030_80);
    try testing.expectApproxEqAbs(@as(f32, 0.502), c.a, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.0627), c.r, 0.001);
}

test "a colour is read from the ways it is written as text, and nothing else is" {
    try testing.expectEqual(Color.hex(0xFF8000), Color.parse("#FF8000").?);
    try testing.expectEqual(Color.hexa(0x10203080), Color.parse("10203080").?);
    try testing.expectEqual(Color.hex(0xFF8800), Color.parse(" #f80 ").?);
    try testing.expectEqual(Color.hexa(0xFF880044), Color.parse("#F804").?);
    try testing.expect(Color.parse("#12345") == null);
    try testing.expect(Color.parse("#GG0000") == null);
    try testing.expect(Color.parse("") == null);
}

test "oklch with no chroma is a grey" {
    const grey = Color.oklch(0.6, 0, 0);
    try testing.expectApproxEqAbs(grey.r, grey.g, 0.002);
    try testing.expectApproxEqAbs(grey.g, grey.b, 0.002);
}

test "mixing all the way is the other colour" {
    const mixed = Color.mix(.black, .white, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), mixed.r, 0.0001);
}
