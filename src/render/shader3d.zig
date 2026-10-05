// SPDX-License-Identifier: BSD-3-Clause

//! What a mesh is drawn with: a surface a `.shader3d` file says, lit by the
//! engine.
//!
//! ```
//! uniform Look : 3 {
//!     float speed = 0.5;
//!     vec4 glow = vec4(1.0, 0.4, 0.1, 1.0);
//! }
//!
//! fragment {
//!     float wave = sin(WORLD_POSITION.y * 4.0 - TIME * speed) * 0.5 + 0.5;
//!     ALBEDO = ALBEDO * (0.5 + 0.5 * wave);
//!     EMISSION = glow.rgb * wave;
//!     ROUGHNESS = 0.3;
//! }
//! ```
//!
//! The file is fluxion-shader's language: its fragment stage, functions,
//! constants, and one uniform block of its own at slot 3, whose fields - and
//! their first values - are what a `Material3D` beside a mesh gives it, as a
//! 2D material's are. The fragment stage does not write `target`: it says
//! what the surface is, and the engine lights it. Each of these starts as
//! the material says - its colours, numbers and pictures - and is what the
//! stage leaves it as:
//!
//! | Name | What it is |
//! | --- | --- |
//! | `ALBEDO` | `vec3`: its colour, as light adds up - a picture's colours made linear. |
//! | `ALPHA` | `float`: how solid it is, where the material is see-through or cut. |
//! | `METALLIC` | `float`: nought to one. |
//! | `ROUGHNESS` | `float`: nought, a mirror, to one. |
//! | `EMISSION` | `vec3`: the light it gives off, brighter than white where it is. |
//! | `NORMAL_MAP` | `vec3`: which way the surface faces, as a normal map's colour is: blue straight out. |
//! | `AO` | `float`: how much of the light from everywhere reaches it. |
//!
//! And what it reads:
//!
//! | Name | What it is |
//! | --- | --- |
//! | `UV` | Where on its pictures the pixel is, the material's scale and offset counted. |
//! | `COLOR` | The mesh's corners' colours where the material counts them, and the tint it inherits. |
//! | `WORLD_POSITION`, `WORLD_NORMAL` | Where the pixel is, and which way the mesh faces there. |
//! | `CAMERA_POSITION` | Where it is seen from. |
//! | `TIME` | Seconds since the game started, as the interface's clock. |
//! | `ALBEDO_TEXTURE`, `EMISSION_TEXTURE`, `SURFACE_TEXTURE`, `NORMAL_TEXTURE`, `OCCLUSION_TEXTURE` | The material's pictures; white, or flat, for none. |
//!
//! The engine's part goes after the file, and what it does at the start and
//! the end of the fragment stage is written on the lines of its braces, so a
//! line a message names is the file's own. The engine's own shader is this
//! with a fragment stage that changes nothing.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const material = @import("material.zig");
const mesh = @import("mesh.zig");
const Material3D = @import("render3d_components.zig").Material3D;

const log = std.log.scoped(.fluxion_engine);

/// What a 3D shader's file ends in.
pub const extension = ".shader3d";

/// The file's own numbers are the block at this slot.
pub const params_slot = 3;

/// The most suns a frame is lit by.
pub const most_suns = 4;
/// The most lamps - point and spot lights - a frame holds, and the most
/// one mesh is lit by.
pub const most_lamps = 64;
pub const lamps_per_mesh = 8;

/// What every draw of a frame tells the shader, as its `Frame` block says.
pub const Frame = extern struct {
    view_projection: math.Mat4,
    camera_position: [4]f32,
    /// The way the camera looks, and one in `w` for an orthographic one:
    /// then every pixel is seen from that way.
    camera_forward: [4]f32,
    /// Toward each sun; nought for none.
    sun_directions: [most_suns][4]f32,
    /// Each sun's colour times its energy.
    sun_colors: [most_suns][4]f32,
    ambient: [4]f32,
    /// The fog's colour, and in `w` how thick it is everywhere.
    fog_color: [4]f32,
    /// The height under which it thickens, how much thicker a unit lower,
    /// and one where there is fog.
    fog_height: [4]f32,
    time: f32,
    _pad: [3]f32 = @splat(0),
};

/// What a material tells the shader, per draw, as its `Material` block says.
pub const Look = extern struct {
    /// Linear, as light adds up.
    albedo_color: [4]f32,
    /// Its energy counted in.
    emission_color: [4]f32,
    /// The pictures' scale, then their offset.
    uv_place: [4]f32,
    /// Metallic, roughness, the normal map's strength and the occlusion's.
    surface: [4]f32,
    /// One where it is unshaded, one where its corners' colours count, the
    /// alpha under which nothing is drawn, and one where its normal map is
    /// read.
    feel: [4]f32,
    /// One where its back is lit as a side of its own: a material that
    /// does not cull its back.
    facing: [4]f32,
};

/// Every lamp of a frame, as the `Lights` block says.
pub const Lights = extern struct {
    /// Where each is, and its range.
    places: [most_lamps][4]f32,
    /// Its colour times its energy, and how it fades with distance.
    colors: [most_lamps][4]f32,
    /// The way it shines, and the cosine of the edge of its cone; -2 for a
    /// point light.
    aims: [most_lamps][4]f32,
    /// How its light fades toward the edge of its cone.
    cones: [most_lamps][4]f32,
};

/// One mesh drawn: read by the shader per instance.
pub const Instance = extern struct {
    /// Its own space to the world's, column by column.
    model: [4][4]f32,
    /// Its normals to the world's: the model's inverse turned over, which
    /// keeps them square to a surface its scale has stretched.
    normal: [3][3]f32,
    /// What it inherits, linear.
    tint: [4]f32,
    /// The lamps it is lit by, by their place in `Lights`; -1 for none.
    lights: [2][4]f32,
};

const engine_part =
    \\// The engine's part: what a 3D shader's file reads, and the vertex stage.
    \\
    \\attribute vec3 VERTEX_POSITION : 0;
    \\attribute vec3 VERTEX_NORMAL : 1;
    \\attribute vec2 VERTEX_UV : 2;
    \\attribute vec4 VERTEX_COLOR : 3;
    \\attribute vec4 VERTEX_TANGENT : 4;
    \\attribute vec4 MODEL_0 : 5;
    \\attribute vec4 MODEL_1 : 6;
    \\attribute vec4 MODEL_2 : 7;
    \\attribute vec4 MODEL_3 : 8;
    \\attribute vec3 TURN_0 : 9;
    \\attribute vec3 TURN_1 : 10;
    \\attribute vec3 TURN_2 : 11;
    \\attribute vec4 TINT : 12;
    \\attribute vec4 LIGHTS_0 : 13;
    \\attribute vec4 LIGHTS_1 : 14;
    \\
    \\// Where the pixel is, in the world.
    \\varying vec3 WORLD_POSITION;
    \\// Which way the mesh faces there, in the world.
    \\varying vec3 WORLD_NORMAL;
    \\varying vec4 WORLD_TANGENT;
    \\// Where on its pictures the pixel is.
    \\varying vec2 UV;
    \\// The mesh's corners' colours, where its material counts them, times its tint.
    \\varying vec4 COLOR;
    \\varying vec4 LIGHT_LIST_0;
    \\varying vec4 LIGHT_LIST_1;
    \\
    \\uniform Frame : 0 {
    \\    mat4 VIEW_PROJECTION;
    \\    // Where it is seen from.
    \\    vec4 CAMERA_POSITION;
    \\    vec4 CAMERA_FORWARD;
    \\    vec4 SUN_DIRECTIONS[4];
    \\    vec4 SUN_COLORS[4];
    \\    vec4 AMBIENT;
    \\    vec4 FOG_COLOR;
    \\    vec4 FOG_HEIGHT;
    \\    // Seconds since the game started.
    \\    float TIME;
    \\}
    \\
    \\uniform Material : 1 {
    \\    vec4 ALBEDO_COLOR;
    \\    vec4 EMISSION_COLOR;
    \\    vec4 UV_PLACE;
    \\    vec4 SURFACE;
    \\    vec4 FEEL;
    \\    vec4 FACING;
    \\}
    \\
    \\uniform Lights : 2 {
    \\    vec4 LIGHT_PLACES[64];
    \\    vec4 LIGHT_COLORS[64];
    \\    vec4 LIGHT_AIMS[64];
    \\    vec4 LIGHT_CONES[64];
    \\}
    \\
    \\// The material's picture.
    \\texture2d ALBEDO_TEXTURE : 0;
    \\// The light the material gives off, as a picture.
    \\texture2d EMISSION_TEXTURE : 1;
    \\// How metal the material is in its blue, how rough in its green.
    \\texture2d SURFACE_TEXTURE : 2;
    \\// Which way the material faces, as a normal map: blue straight out.
    \\texture2d NORMAL_TEXTURE : 3;
    \\// How much light from everywhere reaches the material, in its red.
    \\texture2d OCCLUSION_TEXTURE : 4;
    \\
    \\const float PI = 3.14159265;
    \\
    \\// A picture's colour, as light adds up.
    \\vec3 toLinear(vec3 c) {
    \\    vec3 x = max(c, vec3(0.0));
    \\    vec3 low = x / 12.92;
    \\    vec3 high = pow((x + vec3(0.055)) / 1.055, vec3(2.4));
    \\    return mix(low, high, step(vec3(0.04045), x));
    \\}
    \\
    \\// The light that leaves a surface toward the eye, of one that comes
    \\// from `l`, a unit of it: what it scatters, and what it reflects.
    \\vec3 shine(vec3 n, vec3 v, vec3 l, vec3 albedo, float metallic, float roughness) {
    \\    float n_l = max(dot(n, l), 0.0);
    \\    if (n_l <= 0.0) {
    \\        return vec3(0.0);
    \\    }
    \\    vec3 h = normalize(v + l);
    \\    float n_v = max(dot(n, v), 0.0001);
    \\    float n_h = max(dot(n, h), 0.0);
    \\    float h_v = max(dot(h, v), 0.0);
    \\    float rough = max(roughness, 0.045);
    \\    float a = rough * rough;
    \\    float a2 = a * a;
    \\    float d = n_h * n_h * (a2 - 1.0) + 1.0;
    \\    float spread = a2 / (PI * d * d);
    \\    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    \\    float hidden = (n_v / (n_v * (1.0 - k) + k)) * (n_l / (n_l * (1.0 - k) + k));
    \\    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    \\    vec3 fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - h_v, 5.0);
    \\    vec3 reflected = fresnel * (spread * hidden / (4.0 * n_v * n_l + 0.0001));
    \\    vec3 scattered = (vec3(1.0) - fresnel) * (1.0 - metallic) * albedo;
    \\    return (scattered + reflected * PI) * n_l;
    \\}
    \\
    \\// One sun's light on a surface.
    \\vec3 sun(int which, vec3 n, vec3 v, vec3 albedo, float metallic, float roughness) {
    \\    return shine(n, v, SUN_DIRECTIONS[which].xyz, albedo, metallic, roughness) * SUN_COLORS[which].rgb;
    \\}
    \\
    \\// One lamp's light on a surface at `p`: none for -1.
    \\vec3 lamp(float which, vec3 p, vec3 n, vec3 v, vec3 albedo, float metallic, float roughness) {
    \\    if (which < 0.0) {
    \\        return vec3(0.0);
    \\    }
    \\    int at = int(which + 0.5);
    \\    vec4 place = LIGHT_PLACES[at];
    \\    vec3 to = place.xyz - p;
    \\    float d = length(to);
    \\    if (d >= place.w) {
    \\        return vec3(0.0);
    \\    }
    \\    vec3 l = to / max(d, 0.0001);
    \\    vec4 color = LIGHT_COLORS[at];
    \\    float fade = pow(max(1.0 - d / place.w, 0.0), color.w);
    \\    vec4 aim = LIGHT_AIMS[at];
    \\    if (aim.w > -1.5) {
    \\        float t = clamp((dot(-l, aim.xyz) - aim.w) / max(1.0 - aim.w, 0.0001), 0.0, 1.0);
    \\        fade = fade * pow(t, LIGHT_CONES[at].x);
    \\    }
    \\    return shine(n, v, l, albedo, metallic, roughness) * color.rgb * fade;
    \\}
    \\
    \\// A surface lit: by the suns, its lamps and the light from everywhere,
    \\// with what it gives off, in the fog.
    \\vec3 lit(vec3 albedo, float metallic, float roughness, vec3 emission, vec3 normal_map, float ao,
    \\        vec3 p, vec3 normal, vec4 tangent, vec4 lamps_0, vec4 lamps_1) {
    \\    vec3 v = normalize(mix(CAMERA_POSITION.xyz - p, -CAMERA_FORWARD.xyz, CAMERA_FORWARD.w));
    \\    vec3 n = normalize(normal);
    \\    if (FACING.x > 0.5 && dot(n, v) < 0.0) {
    \\        n = -n;
    \\    }
    \\    if (FEEL.w > 0.5) {
    \\        vec3 t = normalize(tangent.xyz - n * dot(n, tangent.xyz));
    \\        vec3 b = cross(n, t) * tangent.w;
    \\        vec3 tilt = normal_map * 2.0 - vec3(1.0);
    \\        n = normalize(t * (tilt.x * SURFACE.z) + b * (tilt.y * SURFACE.z) + n * tilt.z);
    \\    }
    \\    float m = clamp(metallic, 0.0, 1.0);
    \\    vec3 light = sun(0, n, v, albedo, m, roughness) + sun(1, n, v, albedo, m, roughness)
    \\        + sun(2, n, v, albedo, m, roughness) + sun(3, n, v, albedo, m, roughness);
    \\    light = light + lamp(lamps_0.x, p, n, v, albedo, m, roughness) + lamp(lamps_0.y, p, n, v, albedo, m, roughness)
    \\        + lamp(lamps_0.z, p, n, v, albedo, m, roughness) + lamp(lamps_0.w, p, n, v, albedo, m, roughness);
    \\    light = light + lamp(lamps_1.x, p, n, v, albedo, m, roughness) + lamp(lamps_1.y, p, n, v, albedo, m, roughness)
    \\        + lamp(lamps_1.z, p, n, v, albedo, m, roughness) + lamp(lamps_1.w, p, n, v, albedo, m, roughness);
    \\    vec3 f0 = mix(vec3(0.04), albedo, m);
    \\    light = light + (albedo * (1.0 - m) + f0) * AMBIENT.rgb * ao;
    \\    vec3 color = mix(light, albedo, FEEL.x) + emission;
    \\    float far = length(p - CAMERA_POSITION.xyz);
    \\    float thick = FOG_COLOR.w + max(FOG_HEIGHT.x - p.y, 0.0) * FOG_HEIGHT.y;
    \\    float fog = (1.0 - exp(-thick * far)) * FOG_HEIGHT.z;
    \\    return clamp(mix(color, FOG_COLOR.rgb, clamp(fog, 0.0, 1.0)), vec3(0.0), vec3(1024.0));
    \\}
    \\
    \\vertex {
    \\    vec4 world = MODEL_0 * VERTEX_POSITION.x + MODEL_1 * VERTEX_POSITION.y + MODEL_2 * VERTEX_POSITION.z + MODEL_3;
    \\    WORLD_POSITION = world.xyz;
    \\    WORLD_NORMAL = TURN_0 * VERTEX_NORMAL.x + TURN_1 * VERTEX_NORMAL.y + TURN_2 * VERTEX_NORMAL.z;
    \\    vec3 tangent = MODEL_0.xyz * VERTEX_TANGENT.x + MODEL_1.xyz * VERTEX_TANGENT.y + MODEL_2.xyz * VERTEX_TANGENT.z;
    \\    WORLD_TANGENT = vec4(tangent, VERTEX_TANGENT.w);
    \\    UV = VERTEX_UV * UV_PLACE.xy + UV_PLACE.zw;
    \\    COLOR = mix(vec4(1.0), vec4(toLinear(VERTEX_COLOR.rgb), VERTEX_COLOR.a), FEEL.y) * TINT;
    \\    LIGHT_LIST_0 = LIGHTS_0;
    \\    LIGHT_LIST_1 = LIGHTS_1;
    \\    position = VIEW_PROJECTION * world;
    \\}
    \\
;

/// What the fragment stage starts with: the surface as the material says.
/// One line, written after the stage's `{`.
const prologue = " vec3 ALBEDO = toLinear(sample(ALBEDO_TEXTURE, UV).rgb) * ALBEDO_COLOR.rgb * COLOR.rgb;" ++
    " float ALPHA = sample(ALBEDO_TEXTURE, UV).a * ALBEDO_COLOR.a * COLOR.a;" ++
    " float METALLIC = SURFACE.x * sample(SURFACE_TEXTURE, UV).b;" ++
    " float ROUGHNESS = SURFACE.y * sample(SURFACE_TEXTURE, UV).g;" ++
    " vec3 EMISSION = toLinear(sample(EMISSION_TEXTURE, UV).rgb) * EMISSION_COLOR.rgb;" ++
    " vec3 NORMAL_MAP = sample(NORMAL_TEXTURE, UV).rgb;" ++
    " float AO = mix(1.0, sample(OCCLUSION_TEXTURE, UV).r, SURFACE.w);";

pub const prologue_len: u32 = prologue.len;

/// What it ends with: the surface lit. One line, written before the
/// stage's `}`.
const epilogue = " if (ALPHA < FEEL.z) { discard; }" ++
    " target = vec4(lit(ALBEDO, METALLIC, ROUGHNESS, EMISSION, NORMAL_MAP, AO, WORLD_POSITION, WORLD_NORMAL, WORLD_TANGENT, LIGHT_LIST_0, LIGHT_LIST_1), ALPHA); ";

pub const epilogue_len: u32 = epilogue.len;

/// The engine's own: the surface as the material says.
pub const plain =
    \\fragment {
    \\}
;

/// What a new `.shader3d` file says.
pub const template =
    \\// A 3D shader: what the surface is. The engine lights it.
    \\// ALBEDO, ALPHA, METALLIC, ROUGHNESS, EMISSION, NORMAL_MAP and AO start
    \\// as the material says; UV, COLOR, WORLD_POSITION, WORLD_NORMAL,
    \\// CAMERA_POSITION and TIME are there to read.
    \\
    \\// What a Material3D gives this shader: each field starts as it says here,
    \\// and the Inspector changes it for one entity.
    \\uniform Look : 3 {
    \\    vec4 tint = vec4(1.0, 1.0, 1.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    ALBEDO = ALBEDO * tint.rgb;
    \\}
    \\
;

/// A `.shader3d` file's text with the engine's put in it: what `compile`
/// compiles, and what an editor's analysis reads.
pub const Whole = struct {
    source: []u8,
    /// The line of the whole the engine's part starts on, from one.
    engine_line: usize,
    /// Where the file declares something that is the engine's, or has no
    /// fragment stage, if so.
    trespass: ?material.Whole.Trespass = null,
    /// Whether the file writes `NORMAL_MAP`: then it is read whatever the
    /// material's picture.
    writes_normal_map: bool = false,
    /// Where in the file's text the engine's start of the fragment stage
    /// is written - just after its `{` - and its end - just before its
    /// `}` - when it has one: `prologue_len` and `epilogue_len` bytes.
    open: ?u32 = null,
    close: u32 = 0,

    pub fn trespassMessage(self: Whole, gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
        const where = self.trespass orelse return null;
        const at = lineAndColumn(text, where.offset);
        return try std.fmt.allocPrint(gpa, "{d}:{d}: {s}: a 3D shader's fragment stage says what the surface is - ALBEDO, ALPHA and the rest - and the engine lights it", .{ at.line, at.column, where.what });
    }
};

/// The file's text, with what the engine does at the start and the end of
/// its fragment stage written on the lines of its braces, and the engine's
/// part after it. The caller owns `source`.
pub fn whole(gpa: Allocator, text: []const u8) Allocator.Error!Whole {
    var failure: shader.lex.Failure = undefined;
    const tokens = shader.lex.tokenize(gpa, text, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A file that does not even lex is left for the compiler to say so.
        else => &.{},
    };
    defer if (tokens.len != 0) gpa.free(tokens);

    var out: Whole = .{ .source = &.{}, .engine_line = 0 };
    var open: ?usize = null;
    var close: ?usize = null;
    var depth: usize = 0;
    var in_fragment = false;
    for (tokens, 0..) |token, at| switch (token.kind) {
        .kw_vertex, .kw_attribute, .kw_varying => if (out.trespass == null) {
            out.trespass = .{ .offset = token.offset, .what = token.kind.describe() };
        },
        .identifier => {
            if (std.mem.eql(u8, token.bytes, "target") and out.trespass == null)
                out.trespass = .{ .offset = token.offset, .what = "`target` is the engine's" };
            if (std.mem.eql(u8, token.bytes, "NORMAL_MAP")) out.writes_normal_map = true;
        },
        .kw_fragment => if (open == null) {
            if (at + 1 < tokens.len and tokens[at + 1].kind == .l_brace) {
                in_fragment = true;
            }
        },
        .l_brace => if (in_fragment) {
            if (depth == 0 and open == null) open = token.offset;
            depth += 1;
        },
        .r_brace => if (in_fragment and depth > 0) {
            depth -= 1;
            if (depth == 0) {
                close = token.offset;
                in_fragment = false;
            }
        },
        else => {},
    };
    if ((open == null or close == null) and tokens.len != 0 and out.trespass == null)
        out.trespass = .{ .offset = 0, .what = "there is no fragment stage" };

    var full: std.Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    const w = &full.writer;
    if (open != null and close != null) {
        const start = open.? + 1;
        const end = close.?;
        out.open = @intCast(start);
        out.close = @intCast(end);
        w.writeAll(text[0..start]) catch return error.OutOfMemory;
        w.writeAll(prologue) catch return error.OutOfMemory;
        w.writeAll(text[start..end]) catch return error.OutOfMemory;
        w.writeAll(epilogue) catch return error.OutOfMemory;
        w.writeAll(text[end..]) catch return error.OutOfMemory;
    } else w.writeAll(text) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    out.engine_line = std.mem.count(u8, full.written(), "\n") + 1;
    w.writeAll(engine_part) catch return error.OutOfMemory;
    out.source = full.toOwnedSlice() catch return error.OutOfMemory;
    return out;
}

/// The line and column `offset` is on, from one.
fn lineAndColumn(text: []const u8, offset: u32) struct { line: usize, column: usize } {
    const at = @min(offset, text.len);
    const line = std.mem.count(u8, text[0..at], "\n") + 1;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    return .{ .line = line, .column = at - start + 1 };
}

/// How a surface is drawn, past its pictures: which sides, and whether laid
/// over what is behind it. A surface cut by its alpha is solid: the shader
/// leaves out what is under the threshold.
pub const Way = struct {
    cull: Material3D.Cull,
    blend: bool,

    pub const count = 6;

    pub fn index(self: Way) usize {
        return @as(usize, @intFromEnum(self.cull)) * 2 + @intFromBool(self.blend);
    }

    pub fn of(at: usize) Way {
        return .{ .cull = @enumFromInt(at / 2), .blend = at % 2 == 1 };
    }
};

/// The sample counts a pipeline is made for: one, two, four and eight.
pub const sample_counts = 4;

/// A 3D shader, compiled.
pub const Compiled = struct {
    module: shader.Module,
    gpu: rhi.Shader,
    /// The file's own block, whose fields a `Material3D` beside a mesh
    /// fills.
    params: ?shader.Block = null,
    writes_normal_map: bool = false,
    /// By the count of samples it draws into - its power of two - and way:
    /// made the first time it is drawn so.
    pipelines: [sample_counts][Way.count]rhi.Pipeline = @splat(@splat(.none)),
    /// Whether the device refused a pipeline of it: then what names it is
    /// drawn as though it named none.
    refused: bool = false,

    pub fn deinit(self: *Compiled, device: *rhi.Device) void {
        for (self.pipelines) |row| for (row) |pipeline| if (!pipeline.isNone()) device.destroyPipeline(pipeline);
        device.destroyShader(self.gpu);
        self.module.deinit();
        self.* = undefined;
    }

    /// The pipeline it is drawn with into `color_format` and `depth_format`,
    /// with `samples` a pixel, `way`.
    pub fn pipelineOf(self: *Compiled, device: *rhi.Device, color_format: rhi.Format, depth_format: rhi.Format, samples: u32, way: Way) !rhi.Pipeline {
        const row = std.math.log2_int(u32, samples);
        const held = &self.pipelines[row][way.index()];
        if (!held.isNone()) return held.*;
        const module = &self.module;
        var attributes: [16]rhi.VertexAttribute = undefined;
        var strides: [2]u32 = @splat(0);
        for (module.attributes, 0..) |a, i| {
            const buffer = bufferOf(a.name);
            const format = vertexFormat(a.name, a.ty).?;
            attributes[i] = .{ .location = a.location, .format = format, .offset = strides[buffer], .buffer = buffer };
            strides[buffer] += format.size();
        }
        std.debug.assert(strides[0] == @sizeOf(mesh.Vertex));
        std.debug.assert(strides[1] == @sizeOf(Instance));
        const see_through = way.blend;
        held.* = device.createPipeline(.{
            .shader = self.gpu,
            .attributes = attributes[0..module.attributes.len],
            .buffers = &.{
                .{ .stride = strides[0] },
                .{ .stride = strides[1], .step = .instance },
            },
            .topology = .triangles,
            .blend = if (see_through) .alpha else .solid,
            // See-through meshes are tested against the solid ones and
            // write no depth: one behind another still shows through.
            .depth = .{ .test_enabled = true, .write = !see_through, .compare = .less },
            .cull = switch (way.cull) {
                .back => .back,
                .front => .front,
                .disabled => .none,
            },
            .front_face = .ccw,
            .color_format = color_format,
            .depth_format = depth_format,
            .samples = samples,
            .uniform_blocks = (try module.uniformBlockNames()).?,
            .textures = (try module.textureNames()).?,
            .label = "3D",
        }) catch |err| {
            self.refused = true;
            log.err("the graphics driver refused a 3D shader's pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        return held.*;
    }
};

/// Which attributes are the mesh's own; the rest are per instance.
fn bufferOf(name: []const u8) u32 {
    return if (std.mem.startsWith(u8, name, "VERTEX_")) 0 else 1;
}

/// What an attribute is read as: its type's floats, but a vertex's colour,
/// which is four bytes.
fn vertexFormat(name: []const u8, ty: shader.Type) ?rhi.VertexFormat {
    if (std.mem.eql(u8, name, "VERTEX_COLOR")) return .ubyte4_norm;
    return switch (ty) {
        .float => .float,
        .vec2 => .float2,
        .vec3 => .float3,
        .vec4 => .float4,
        else => null,
    };
}

/// Compile a `.shader3d` file's text - `plain` for the engine's own - with
/// the engine's part in it. What is wrong with it is written to
/// `problems`, at the file's own lines, and is `error.ShaderFailed`.
/// Its pipelines are made when it is first drawn.
pub fn compile(gpa: Allocator, device: *rhi.Device, text: []const u8, label: []const u8, problems: *std.Io.Writer) (error{ShaderFailed} || Allocator.Error || rhi.Error)!Compiled {
    const built = try whole(gpa, text);
    defer gpa.free(built.source);
    if (try built.trespassMessage(gpa, text)) |message| {
        defer gpa.free(message);
        problems.print("{s}\n", .{message}) catch {};
        return error.ShaderFailed;
    }
    var said: std.Io.Writer.Allocating = .init(gpa);
    defer said.deinit();
    var module = shader.compile(gpa, built.source, &said.writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {
            material.tellOfLines(said.written(), built.engine_line, problems);
            return error.ShaderFailed;
        },
    };
    errdefer module.deinit();

    // One block of its own, at its slot, and no textures but the engine's.
    var params: ?shader.Block = null;
    for (module.blocks) |block| {
        if (block.slot < params_slot) continue;
        if (block.slot != params_slot or params != null) {
            problems.print("a 3D shader's own numbers are one uniform block, at slot {d}: `{s}` is at {d}\n", .{ params_slot, block.name, block.slot }) catch {};
            return error.ShaderFailed;
        }
        params = block;
    }
    if (module.textures.len != 5) {
        problems.writeAll("a 3D shader reads the material's pictures; textures of its own are not here yet\n") catch {};
        return error.ShaderFailed;
    }
    checkLayout(&module);

    const gpu = device.createShader(.{
        .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
        .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
        .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
        .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
        .label = label,
    }) catch |err| {
        problems.print("the graphics driver refused it: {s}\n", .{device.diagnostics()}) catch {};
        return err;
    };
    return .{ .module = module, .gpu = gpu, .params = params, .writes_normal_map = built.writes_normal_map };
}

/// The blocks are where the engine writes them.
fn checkLayout(module: *const shader.Module) void {
    const frame = module.block("Frame").?;
    inline for (.{
        .{ "VIEW_PROJECTION", "view_projection" }, .{ "CAMERA_POSITION", "camera_position" }, .{ "CAMERA_FORWARD", "camera_forward" },
        .{ "SUN_DIRECTIONS", "sun_directions" },   .{ "SUN_COLORS", "sun_colors" },           .{ "AMBIENT", "ambient" },
        .{ "FOG_COLOR", "fog_color" },             .{ "FOG_HEIGHT", "fog_height" },           .{ "TIME", "time" },
    }) |pair| std.debug.assert(frame.offsetOf(pair[0]).? == @offsetOf(Frame, pair[1]));
    std.debug.assert(frame.size <= @sizeOf(Frame));
    const look = module.block("Material").?;
    inline for (.{
        .{ "ALBEDO_COLOR", "albedo_color" }, .{ "EMISSION_COLOR", "emission_color" }, .{ "UV_PLACE", "uv_place" },
        .{ "SURFACE", "surface" },           .{ "FEEL", "feel" },                     .{ "FACING", "facing" },
    }) |pair| std.debug.assert(look.offsetOf(pair[0]).? == @offsetOf(Look, pair[1]));
    std.debug.assert(look.size == @sizeOf(Look));
    const lights = module.block("Lights").?;
    inline for (.{ .{ "LIGHT_PLACES", "places" }, .{ "LIGHT_COLORS", "colors" }, .{ "LIGHT_AIMS", "aims" }, .{ "LIGHT_CONES", "cones" } }) |pair| {
        std.debug.assert(lights.offsetOf(pair[0]).? == @offsetOf(Lights, pair[1]));
    }
    std.debug.assert(lights.size == @sizeOf(Lights));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the blocks and an instance are laid out as the shader reads them" {
    try testing.expectEqual(@as(usize, 288), @sizeOf(Frame));
    try testing.expectEqual(@as(usize, 96), @sizeOf(Look));
    try testing.expectEqual(@as(usize, 4096), @sizeOf(Lights));
    try testing.expectEqual(@as(usize, 148), @sizeOf(Instance));
    try testing.expectEqual(@as(usize, 52), @sizeOf(mesh.Vertex));
    for (0..Way.count) |at| try testing.expectEqual(at, Way.of(at).index());
}

test "the engine's own shader and a file's compile for every backend, with the file's own numbers" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();

    var own = compile(testing.allocator, &device, plain, "plain", &problems.writer) catch |err| {
        std.debug.print("{s}\n", .{problems.written()});
        return err;
    };
    defer own.deinit(&device);
    try testing.expect(own.params == null);
    try testing.expect(!own.writes_normal_map);

    var waving = compile(testing.allocator, &device,
        \\uniform Look : 3 {
        \\    float speed = 0.5;
        \\}
        \\fragment {
        \\    ALBEDO = ALBEDO * (0.5 + 0.5 * sin(WORLD_POSITION.y - TIME * speed));
        \\    NORMAL_MAP = vec3(0.5, 0.5, 1.0);
        \\    ROUGHNESS = 0.2;
        \\}
    , "waving", &problems.writer) catch |err| {
        std.debug.print("{s}\n", .{problems.written()});
        return err;
    };
    defer waving.deinit(&device);
    try testing.expectEqualStrings("speed", waving.params.?.fields[0].name);
    try testing.expect(waving.writes_normal_map);

    var templated = try compile(testing.allocator, &device, template, "template", &problems.writer);
    defer templated.deinit(&device);
    try testing.expectEqualStrings("tint", templated.params.?.fields[0].name);
}

test "a mistake is at the file's own line, and what is the engine's is said to be" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();

    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\fragment {
        \\    ALBEDO = 1.0 + vec2(1.0);
        \\}
    , "broken", &problems.writer));
    try testing.expect(std.mem.startsWith(u8, problems.written(), "2:"));

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\fragment {
        \\    target = vec4(1.0);
        \\}
    , "target", &problems.writer));
    try testing.expect(std.mem.indexOf(u8, problems.written(), "2:5: `target` is the engine's") != null);

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\uniform Mine : 4 { float x = 1.0; }
        \\fragment {
        \\    ALBEDO = vec3(x);
        \\}
    , "slot", &problems.writer));

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device, "const float X = 1.0;\n", "empty", &problems.writer));
    try testing.expect(std.mem.indexOf(u8, problems.written(), "no fragment stage") != null);
}
