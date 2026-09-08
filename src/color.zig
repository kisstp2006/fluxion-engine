// SPDX-License-Identifier: BSD-3-Clause

//! A colour, and the three ways people write one down.
//!
//! ```zig
//! const sky: Color = .hex(0x14161A);      // what artwork is handed over as
//! const ghost: Color = .rgba(1, 1, 1, 0.4);
//! const accent: Color = .oklch(0.7, 0.14, 250);
//! ```
//!
//! Four floats from zero to one, which is what a GPU takes and what
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) hands to a clear
//! or a vertex buffer without touching.
//!
//! **This is deliberately the same shape as
//! [Fluxion UI](https://github.com/kisstp2006/fluxion-ui)'s `Color`** - the
//! same four fields in the same order, the same constructors, the same
//! meaning. When the interface layer arrives, one of the two becomes an alias
//! of the other and nothing that was written against either changes. Until
//! then the engine does not drag a layout library in to name a colour.

const std = @import("std");
const testing = std.testing;

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

    /// `0xRRGGBB`, opaque. The spelling artwork actually arrives in.
    pub inline fn hex(value: u24) Color {
        return .{
            .r = channel(@intCast((value >> 16) & 0xFF)),
            .g = channel(@intCast((value >> 8) & 0xFF)),
            .b = channel(@intCast(value & 0xFF)),
            .a = 1,
        };
    }

    /// `0xRRGGBBAA`. The alpha is last, as CSS writes it and as Windows does
    /// not - which is the mistake this sentence exists to prevent.
    pub inline fn hexa(value: u32) Color {
        return .{
            .r = channel(@intCast((value >> 24) & 0xFF)),
            .g = channel(@intCast((value >> 16) & 0xFF)),
            .b = channel(@intCast((value >> 8) & 0xFF)),
            .a = channel(@intCast(value & 0xFF)),
        };
    }

    pub inline fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub inline fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Lightness, chroma and hue, in OKLCH.
    ///
    /// Worth having because it is the only one of the three that behaves: two
    /// colours a fixed distance apart in hue look equally far apart, and
    /// changing `l` alone does not change how colourful something looks.
    /// Picking a palette in hex means eyeballing it; picking one here means
    /// walking the hue round in even steps, which is what a team colour, a
    /// damage-number gradient and a minimap key all want.
    ///
    /// `l` is 0 to 1, `c` is about 0 to 0.4, `hue_degrees` goes round.
    pub fn oklch(l: f32, c: f32, hue_degrees: f32) Color {
        const h = hue_degrees * std.math.pi / 180.0;
        return oklab(l, c * @cos(h), c * @sin(h));
    }

    /// The same, in the rectangular form the conversion is defined in.
    pub fn oklab(l: f32, a_axis: f32, b_axis: f32) Color {
        // Björn Ottosson's OKLab, straight through: to the cone responses,
        // cube them, then the matrix into linear sRGB.
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

    /// The same colour at another opacity. What a fade is made of.
    pub fn withAlpha(self: Color, a: f32) Color {
        var out = self;
        out.a = a;
        return out;
    }

    /// Part of the way from one colour to another.
    ///
    /// In the values as stored, which is to say in sRGB and not in a linear
    /// space - so a half-way point between two bright colours is a little
    /// darker than the eye expects. That is what every interface toolkit
    /// does, it is what an artist picking two colours assumes, and doing it
    /// properly means going through `oklab` and back, which `oklch` is there
    /// for when it matters.
    pub fn mix(from: Color, to: Color, t: f32) Color {
        const k = std.math.clamp(t, 0, 1);
        return .{
            .r = from.r + (to.r - from.r) * k,
            .g = from.g + (to.g - from.g) * k,
            .b = from.b + (to.b - from.b) * k,
            .a = from.a + (to.a - from.a) * k,
        };
    }

    /// The four numbers as an array, which is what a clear colour and a
    /// vertex buffer both take.
    pub fn array(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    inline fn channel(byte: u8) f32 {
        return @as(f32, @floatFromInt(byte)) / 255.0;
    }

    /// Linear light to sRGB, clamped. The last step of the OKLab conversion,
    /// and the reason a colour picked there lands where it looks like it
    /// should on screen.
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

test "oklch with no chroma is a grey" {
    const grey = Color.oklch(0.6, 0, 0);
    try testing.expectApproxEqAbs(grey.r, grey.g, 0.002);
    try testing.expectApproxEqAbs(grey.g, grey.b, 0.002);
}

test "mixing all the way is the other colour" {
    const mixed = Color.mix(.black, .white, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), mixed.r, 0.0001);
}
