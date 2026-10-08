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
//! their first values - are what a material gives it in its file's
//! `params`, and an entity drawn with the material may give in their place,
//! as a 2D material's entity does. The fragment stage does not write `target`: it says
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
const shadows3d = @import("shadows3d.zig");
const fog_volumes = @import("fog_volumes.zig");
const Material3DData = @import("render3d_components.zig").Material3DData;

const log = std.log.scoped(.fluxion_engine);

/// What a 3D shader's file ends in.
pub const extension = ".shader3d";

/// The file's own numbers are the block at this slot.
pub const params_slot = 3;
/// Every shadow's numbers, `shadows3d.Shadows`, are the block at this slot,
/// and the atlas is read at these two: compared with, and as it is.
pub const shadows_slot = 4;
pub const shadow_map_slot = 5;
pub const shadow_depth_slot = 6;
/// How many textures a 3D shader reads: the material's five, the shadow
/// atlas twice, the lights' cookies and the lightmap.
pub const texture_count = 9;
pub const cookie_slot = 7;
/// The light from everywhere baked for a frame: the lightmap at this slot,
/// and the probes' samples, `Probes`, the block at this one.
pub const lightmap_slot = 8;
pub const probes_slot = 5;
/// For a mesh a skeleton bends: its bones, `Skin`, are the block at this
/// slot, and each vertex's bones and weights are a third vertex buffer.
pub const skin_slot = 6;

/// What a skinned mesh is bent by, as the shader's `Skin` block says: each
/// bone's place now times its inverse bind matrix, as the first three rows
/// of that matrix - three `vec4`s a bone, `mesh.max_bones` of them.
pub const Skin = extern struct {
    bones: [mesh.max_bones * 3][4]f32,
};

/// The most probe samples a frame holds: one each for the meshes that move
/// through a lightmap's probes, nearest the camera first.
pub const most_probe_samples = 256;

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
    /// The picture's width and height, in pixels.
    screen: [4]f32,
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
    /// A spot light's up - its cookie's top - and how wide its cone is: the
    /// tangent of half of it.
    ups: [most_lamps][4]f32,
    /// Where its cookie is in the cookie atlas: across and down from where,
    /// and how far for the whole picture; nought across for none.
    cookies: [most_lamps][4]f32,
};

/// One mesh drawn: read by the shader per instance.
pub const Instance = extern struct {
    /// Its own space to the world's, column by column. The shader turns its
    /// normals by the inverse of this turned over, worked out from it.
    model: [4][4]f32,
    /// What it inherits, linear.
    tint: [4]f32,
    /// The lamps it is lit by, by their place in `Lights`; -1 for none.
    lights: [2][4]f32,
    /// Where its light from everywhere comes from: with `x` above nought,
    /// the lightmap, at its lightmap UVs times `x` and `y` and moved by `z`
    /// and `w`; with `x` below nought, probe sample `-x - 1` of `Probes`;
    /// with nought, the environment's ambient light.
    gi: [4]f32 = @splat(0),
};

/// The probes' light for the meshes that move through them, as the
/// `Probes` block says: three numbers a colour, how bright a surface facing
/// each way is, `c0 + c1 x + c2 y + c3 z` of the way it faces.
pub const Probes = extern struct {
    /// Each sample's red, green and blue, one after another.
    samples: [most_probe_samples * 3][4]f32,
    /// What everything baked is multiplied by, in `x`.
    energy: [4]f32,
};

const engine_part = engine_head ++ fog_volumes.shader_part ++ engine_tail;

const engine_head =
    \\// The engine's part: what a 3D shader's file reads, and the vertex stage.
    \\
    \\attribute vec3 VERTEX_POSITION : 0;
    \\attribute vec3 VERTEX_NORMAL : 1;
    \\attribute vec2 VERTEX_UV : 2;
    \\attribute vec4 VERTEX_COLOR : 3;
    \\attribute vec4 VERTEX_TANGENT : 4;
    \\attribute vec2 VERTEX_UV2 : 5;
    \\attribute vec4 MODEL_0 : 6;
    \\attribute vec4 MODEL_1 : 7;
    \\attribute vec4 MODEL_2 : 8;
    \\attribute vec4 MODEL_3 : 9;
    \\attribute vec4 TINT : 10;
    \\attribute vec4 LIGHTS_0 : 11;
    \\attribute vec4 LIGHTS_1 : 12;
    \\attribute vec4 GI : 13;
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
    \\// Where on the lightmap, or which probe sample, and which of the two.
    \\varying vec4 GI_AT;
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
    \\    vec4 SCREEN;
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
    \\    vec4 LIGHT_UPS[64];
    \\    vec4 LIGHT_COOKIES[64];
    \\}
    \\
    \\uniform Shadows : 4 {
    \\    mat4 SHADOW_MATRICES[128];
    \\    vec4 SHADOW_RECTS[128];
    \\    vec4 SHADOW_VIEWS[128];
    \\    vec4 LAMP_SHADOWS[64];
    \\    vec4 LAMP_SOFTNESS[64];
    \\    vec4 SUN_SHADOWS[4];
    \\    vec4 SUN_SPLITS[4];
    \\    vec4 SUN_SOFTNESS[4];
    \\    vec4 SHADOW_ATLAS;
    \\}
    \\
    \\uniform Probes : 5 {
    \\    vec4 PROBE_SAMPLES[768];
    \\    vec4 GI_ENERGY;
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
    \\// Every shadow's depth, compared with.
    \\texture2d_shadow SHADOW_MAP : 5;
    \\// The same, read as it is: how near its light what casts a shadow is.
    \\texture2d SHADOW_DEPTH : 6;
    \\// The lights' cookies.
    \\texture2d COOKIE_ATLAS : 7;
    \\// The light from everywhere, baked.
    \\texture2d LIGHTMAP : 8;
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
    \\// How far from its light a depth seen in a shadow view is: `info` is the
    \\// view's near, far, texel and whether it is seen in perspective.
    \\float shadowDistance(vec4 info, float depth) {
    \\    if (info.w > 0.5) {
    \\        return info.x * info.y / max(info.y - depth * (info.y - info.x), 0.000001);
    \\    }
    \\    return info.x + depth * (info.y - info.x);
    \\}
    \\
    \\// The `i`th of `count` points spread evenly over a disc one across,
    \\// turned by `turn`.
    \\vec2 spiral(int i, int count, float turn) {
    \\    float r = sqrt((float(i) + 0.5) / float(count));
    \\    float a = float(i) * 2.39996323 + turn;
    \\    return vec2(cos(a), sin(a)) * r;
    \\}
    \\
    \\// How much a pixel's readings of a shadow are turned: by where on the
    \\// screen `p` is, so neighbouring pixels read different points round it.
    \\float pixelTurn(vec3 p) {
    \\    vec4 onto = VIEW_PROJECTION * vec4(p, 1.0);
    \\    vec2 pixel = floor((onto.xy / onto.w * 0.5 + vec2(0.5)) * SCREEN.xy);
    \\    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715)))) * 6.2831853;
    \\}
    \\
    \\// How lit `p`, on a surface facing `ng`, is in shadow view `view` of a
    \\// light that is `l` from it: one where nothing nearer the light stands
    \\// between, nought where something does. `how` is the light's bias toward
    \\// it and along the surface, in texels, its blur in texels, and its size;
    \\// `turn` turns the readings, pixel by pixel.
    \\float shadowOf(int view, vec3 p, vec3 ng, vec3 l, vec4 how, float turn) {
    \\    vec4 info = SHADOW_VIEWS[view];
    \\    mat4 m = SHADOW_MATRICES[view];
    \\    vec4 seen = m * vec4(p, 1.0);
    \\    float texel = info.z * mix(1.0, seen.w, info.w);
    \\    vec3 side = ng;
    \\    if (dot(ng, l) < 0.0) {
    \\        side = -ng;
    \\    }
    \\    vec4 at = m * vec4(p + side * (how.y * texel) + l * (how.x * texel), 1.0);
    \\    vec3 here = at.xyz / at.w;
    \\    vec4 rect = SHADOW_RECTS[view];
    \\    float one = SHADOW_ATLAS.x;
    \\    float radius = how.z;
    \\    int taps = int(SHADOW_ATLAS.y + 0.5);
    \\    if (how.w > 0.0 && taps > 1) {
    \\        // What casts it, found: the shadow spreads with how far it falls.
    \\        float search = clamp(radius + how.w / texel, 2.0, 24.0);
    \\        float blockers = 0.0;
    \\        float found = 0.0;
    \\        for (int i = 0; i < taps; i = i + 1) {
    \\            vec2 tap = here.xy + spiral(i, taps, turn) * (search * one);
    \\            float depth = sample_level(SHADOW_DEPTH, clamp(tap, rect.xy, rect.zw), 0.0).r;
    \\            if (depth < here.z) {
    \\                blockers = blockers + depth;
    \\                found = found + 1.0;
    \\            }
    \\        }
    \\        if (found < 0.5) {
    \\            return 1.0;
    \\        }
    \\        float caster = shadowDistance(info, blockers / found);
    \\        float receiver = shadowDistance(info, here.z);
    \\        float spread = how.w * max(receiver - caster, 0.0) / mix(1.0, caster, info.w);
    \\        radius = min(radius + spread / texel, 32.0);
    \\    }
    \\    if (taps <= 1 || radius <= 0.0) {
    \\        return sample_compare(SHADOW_MAP, clamp(here.xy, rect.xy, rect.zw), here.z);
    \\    }
    \\    float amount = 0.0;
    \\    for (int i = 0; i < taps; i = i + 1) {
    \\        vec2 tap = here.xy + spiral(i, taps, turn) * (radius * one);
    \\        amount = amount + sample_compare(SHADOW_MAP, clamp(tap, rect.xy, rect.zw), here.z);
    \\    }
    \\    return amount / float(taps);
    \\}
    \\
    \\// How lit `p` is by sun `which`: its cascade for how far along the
    \\// camera's view `p` is, fading out toward the end of its shadow.
    \\float sunShadow(int which, vec3 p, vec3 ng, float turn) {
    \\    vec4 s = SUN_SHADOWS[which];
    \\    if (s.x < 0.0) {
    \\        return 1.0;
    \\    }
    \\    vec4 soft = SUN_SOFTNESS[which];
    \\    float d = dot(p - CAMERA_POSITION.xyz, CAMERA_FORWARD.xyz);
    \\    if (d >= soft.w) {
    \\        return 1.0;
    \\    }
    \\    vec4 splits = SUN_SPLITS[which];
    \\    int cascade = 0;
    \\    if (d > splits.x) {
    \\        cascade = 1;
    \\    }
    \\    if (d > splits.y) {
    \\        cascade = 2;
    \\    }
    \\    if (d > splits.z) {
    \\        cascade = 3;
    \\    }
    \\    if (cascade >= int(s.y + 0.5)) {
    \\        return 1.0;
    \\    }
    \\    int first = int(s.x + 0.5);
    \\    vec3 l = SUN_DIRECTIONS[which].xyz;
    \\    vec4 how = vec4(s.z, s.w, soft.x, soft.y);
    \\    float amount = shadowOf(first + cascade, p, ng, l, how, turn);
    \\    // Over the last tenth of a cascade the next is mixed in, so where one
    \\    // ends does not show.
    \\    float begin = 0.0;
    \\    float end = splits.x;
    \\    if (cascade == 1) {
    \\        begin = splits.x;
    \\        end = splits.y;
    \\    }
    \\    if (cascade == 2) {
    \\        begin = splits.y;
    \\        end = splits.z;
    \\    }
    \\    if (cascade == 3) {
    \\        begin = splits.z;
    \\        end = splits.w;
    \\    }
    \\    float band = (end - begin) * 0.1;
    \\    if (cascade + 1 < int(s.y + 0.5) && d > end - band) {
    \\        amount = mix(amount, shadowOf(first + cascade + 1, p, ng, l, how, turn), (d - (end - band)) / band);
    \\    }
    \\    return mix(amount, 1.0, smoothstep(soft.z, soft.w, d));
    \\}
    \\
    \\// How lit `p` is by lamp `at`, which is `l` from it: a point light's
    \\// view is the side of it `p` is on.
    \\float lampShadow(int at, vec3 p, vec3 ng, vec3 l, float turn) {
    \\    vec4 s = LAMP_SHADOWS[at];
    \\    if (s.x < 0.0) {
    \\        return 1.0;
    \\    }
    \\    int view = int(s.x + 0.5);
    \\    if (s.y > 1.5) {
    \\        vec3 a = abs(l);
    \\        if (a.x >= a.y && a.x >= a.z) {
    \\            if (l.x > 0.0) {
    \\                view = view + 1;
    \\            }
    \\        } else {
    \\            if (a.y >= a.z) {
    \\                view = view + 2;
    \\                if (l.y > 0.0) {
    \\                    view = view + 1;
    \\                }
    \\            } else {
    \\                view = view + 4;
    \\                if (l.z > 0.0) {
    \\                    view = view + 1;
    \\                }
    \\            }
    \\        }
    \\    }
    \\    vec4 soft = LAMP_SOFTNESS[at];
    \\    return shadowOf(view, p, ng, l, vec4(s.z, s.w, soft.x, soft.y), turn);
    \\}
    \\
    \\// One sun's light on a surface at `p`, which faces `ng` and is lit as
    \\// though it faced `n`.
    \\vec3 sun(int which, vec3 p, vec3 ng, vec3 n, vec3 v, vec3 albedo, float metallic, float roughness, float turn) {
    \\    vec3 light = shine(n, v, SUN_DIRECTIONS[which].xyz, albedo, metallic, roughness) * SUN_COLORS[which].rgb;
    \\    if (light.r + light.g + light.b <= 0.0) {
    \\        return light;
    \\    }
    \\    return light * sunShadow(which, p, ng, turn);
    \\}
    \\
    \\// One lamp's light on a surface at `p`: none for -1.
    \\vec3 lamp(float which, vec3 p, vec3 ng, vec3 n, vec3 v, vec3 albedo, float metallic, float roughness, float turn) {
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
    \\    vec4 cookie = LIGHT_COOKIES[at];
    \\    if (cookie.z > 0.0) {
    \\        // Where in its picture `p` is, the top toward its up: across the
    \\        // cone for a spot light, all the way round for a point light.
    \\        vec4 up = LIGHT_UPS[at];
    \\        vec3 off = p - place.xyz;
    \\        vec3 right = cross(aim.xyz, up.xyz);
    \\        vec2 uv = vec2(0.5);
    \\        if (aim.w > -1.5) {
    \\            float along = max(dot(off, aim.xyz), 0.0001) * up.w;
    \\            uv = vec2(0.5 + 0.5 * dot(off, right) / along, 0.5 - 0.5 * dot(off, up.xyz) / along);
    \\        } else {
    \\            uv = vec2(0.5 + atan2(dot(-l, right), dot(-l, aim.xyz)) / 6.2831853, acos(clamp(dot(-l, up.xyz), -1.0, 1.0)) / 3.14159265);
    \\        }
    \\        uv = clamp(uv, vec2(0.002), vec2(0.998));
    \\        color = vec4(color.rgb * toLinear(sample_level(COOKIE_ATLAS, cookie.xy + uv * cookie.zw, 0.0).rgb), color.w);
    \\    }
    \\    vec3 light = shine(n, v, l, albedo, metallic, roughness) * color.rgb * fade;
    \\    if (light.r + light.g + light.b <= 0.0) {
    \\        return light;
    \\    }
    \\    return light * lampShadow(at, p, ng, l, turn);
    \\}
    \\
    \\// How lit a surface facing `n` is by light whose mean over every way is
    \\// `c.x` and which leans along `c.yzw`, as a probe holds it: the lean
    \\// read as a lobe that is never below nought - a light from one way
    \\// lights its side as that light does, and the far side not at all.
    \\float leaning(vec4 c, vec3 n) {
    \\    float mean = max(c.x, 0.0);
    \\    vec3 lean = c.yzw * 0.5;
    \\    float size = length(lean);
    \\    if (mean <= 0.0 || size <= mean * 0.0001) {
    \\        return mean;
    \\    }
    \\    float k = min(size / mean, 1.0);
    \\    float q = max(0.5 * (1.0 + dot(lean / size, n)), 0.0);
    \\    float p = 1.0 + 2.0 * k;
    \\    float a = (1.0 - k) / (1.0 + k);
    \\    return mean * (a + (1.0 - a) * (p + 1.0) * pow(q, p));
    \\}
    \\
    \\// The light from everywhere on a surface facing `n`: baked into the
    \\// lightmap, the probes' round a mesh that moves, or the environment's.
    \\vec3 indirect(vec3 n, vec4 at) {
    \\    if (at.w > 1.5) {
    \\        int i = int(at.z + 0.5) * 3;
    \\        vec3 c = vec3(leaning(PROBE_SAMPLES[i], n), leaning(PROBE_SAMPLES[i + 1], n), leaning(PROBE_SAMPLES[i + 2], n));
    \\        return c * GI_ENERGY.x;
    \\    }
    \\    if (at.w > 0.5) {
    \\        return sample_level(LIGHTMAP, at.xy, 0.0).rgb * GI_ENERGY.x;
    \\    }
    \\    return AMBIENT.rgb;
    \\}
    \\
;

const engine_tail =
    \\// A surface lit: by the suns, its lamps and the light from everywhere,
    \\// with what it gives off, in the fog and the fog volumes.
    \\vec3 lit(vec3 albedo, float metallic, float roughness, vec3 emission, vec3 normal_map, float ao,
    \\        vec3 p, vec3 normal, vec4 tangent, vec4 lamps_0, vec4 lamps_1, vec4 gi_at) {
    \\    vec3 v = normalize(mix(CAMERA_POSITION.xyz - p, -CAMERA_FORWARD.xyz, CAMERA_FORWARD.w));
    \\    vec3 ng = normalize(normal);
    \\    vec3 n = ng;
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
    \\    float turn = pixelTurn(p);
    \\    vec3 light = sun(0, p, ng, n, v, albedo, m, roughness, turn) + sun(1, p, ng, n, v, albedo, m, roughness, turn)
    \\        + sun(2, p, ng, n, v, albedo, m, roughness, turn) + sun(3, p, ng, n, v, albedo, m, roughness, turn);
    \\    light = light + lamp(lamps_0.x, p, ng, n, v, albedo, m, roughness, turn) + lamp(lamps_0.y, p, ng, n, v, albedo, m, roughness, turn)
    \\        + lamp(lamps_0.z, p, ng, n, v, albedo, m, roughness, turn) + lamp(lamps_0.w, p, ng, n, v, albedo, m, roughness, turn);
    \\    light = light + lamp(lamps_1.x, p, ng, n, v, albedo, m, roughness, turn) + lamp(lamps_1.y, p, ng, n, v, albedo, m, roughness, turn)
    \\        + lamp(lamps_1.z, p, ng, n, v, albedo, m, roughness, turn) + lamp(lamps_1.w, p, ng, n, v, albedo, m, roughness, turn);
    \\    vec3 f0 = mix(vec3(0.04), albedo, m);
    \\    light = light + (albedo * (1.0 - m) + f0) * indirect(n, gi_at) * ao;
    \\    vec3 color = mix(light, albedo, FEEL.x) + emission;
    \\    float far = length(p - CAMERA_POSITION.xyz);
    \\    float thick = FOG_COLOR.w + max(FOG_HEIGHT.x - p.y, 0.0) * FOG_HEIGHT.y;
    \\    float fog = (1.0 - exp(-thick * far)) * FOG_HEIGHT.z;
    \\    return clamp(fogVolumes(mix(color, FOG_COLOR.rgb, clamp(fog, 0.0, 1.0)), p), vec3(0.0), vec3(1024.0));
    \\}
    \\
    \\vertex {
    \\    vec3 here = VERTEX_POSITION;
    \\    vec3 facing = VERTEX_NORMAL;
    \\    vec3 along = VERTEX_TANGENT.xyz;
    \\    // A mesh a skeleton bends is bent here.
    \\    vec4 world = MODEL_0 * here.x + MODEL_1 * here.y + MODEL_2 * here.z + MODEL_3;
    \\    WORLD_POSITION = world.xyz;
    \\    // The normal turned by the model's inverse turned over: its columns'
    \\    // crossings, which are that times how much it grows - one way, or
    \\    // the other where it is mirrored.
    \\    vec3 a = MODEL_0.xyz;
    \\    vec3 b = MODEL_1.xyz;
    \\    vec3 c = MODEL_2.xyz;
    \\    vec3 turned = cross(b, c) * facing.x + cross(c, a) * facing.y + cross(a, b) * facing.z;
    \\    WORLD_NORMAL = turned * sign(dot(a, cross(b, c)));
    \\    vec3 tangent = MODEL_0.xyz * along.x + MODEL_1.xyz * along.y + MODEL_2.xyz * along.z;
    \\    WORLD_TANGENT = vec4(tangent, VERTEX_TANGENT.w);
    \\    UV = VERTEX_UV * UV_PLACE.xy + UV_PLACE.zw;
    \\    COLOR = mix(vec4(1.0), vec4(toLinear(VERTEX_COLOR.rgb), VERTEX_COLOR.a), FEEL.y) * TINT;
    \\    LIGHT_LIST_0 = LIGHTS_0;
    \\    LIGHT_LIST_1 = LIGHTS_1;
    \\    GI_AT = vec4(0.0);
    \\    if (GI.x > 0.0) {
    \\        GI_AT = vec4(VERTEX_UV2 * GI.xy + GI.zw, 0.0, 1.0);
    \\    }
    \\    if (GI.x < 0.0) {
    \\        GI_AT = vec4(0.0, 0.0, -GI.x - 1.0, 2.0);
    \\    }
    \\    position = VIEW_PROJECTION * world;
    \\}
    \\
;

/// What a skinned variant's engine part has after its attributes: each
/// vertex's bones and weights, and the bones.
const skin_head =
    \\attribute vec4 SKIN_JOINTS : 14;
    \\attribute vec4 SKIN_WEIGHTS : 15;
    \\
    \\// Each bone's place now times its inverse bind matrix: the first three
    \\// rows of it, three in a row a bone.
    \\uniform Skin : 6 {
    \\    vec4 BONES[768];
    \\}
    \\
;

/// Where a skinned variant's engine part says what is above.
/// What bends a vertex of a skinned mesh: the rows of its four bones'
/// matrices, weighted, times its place, its normal and its tangent.
const skin_bend =
    \\    vec4 bones = SKIN_JOINTS * 255.0 + vec4(0.5);
    \\    int b0 = int(bones.x) * 3;
    \\    int b1 = int(bones.y) * 3;
    \\    int b2 = int(bones.z) * 3;
    \\    int b3 = int(bones.w) * 3;
    \\    vec4 w = SKIN_WEIGHTS;
    \\    vec4 row0 = BONES[b0] * w.x + BONES[b1] * w.y + BONES[b2] * w.z + BONES[b3] * w.w;
    \\    vec4 row1 = BONES[b0 + 1] * w.x + BONES[b1 + 1] * w.y + BONES[b2 + 1] * w.z + BONES[b3 + 1] * w.w;
    \\    vec4 row2 = BONES[b0 + 2] * w.x + BONES[b1 + 2] * w.y + BONES[b2 + 2] * w.z + BONES[b3 + 2] * w.w;
    \\    vec4 corner = vec4(here, 1.0);
    \\    here = vec3(dot(row0, corner), dot(row1, corner), dot(row2, corner));
    \\    facing = vec3(dot(row0.xyz, facing), dot(row1.xyz, facing), dot(row2.xyz, facing));
    \\    along = vec3(dot(row0.xyz, along), dot(row1.xyz, along), dot(row2.xyz, along));
    \\
;

/// Where the vertex stage bends a skinned mesh.
const skin_bend_at = "    // A mesh a skeleton bends is bent here.\n";

/// The engine's part, for a skinned mesh or not.
fn enginePart(skinned: bool) []const u8 {
    if (!skinned) return engine_part;
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        const head_at = std.mem.indexOf(u8, engine_part, "attribute vec4 GI : 13;\n").? + "attribute vec4 GI : 13;\n".len;
        const bend_at = std.mem.indexOf(u8, engine_part, skin_bend_at).? + skin_bend_at.len;
        break :blk engine_part[0..head_at] ++ skin_head ++ engine_part[head_at..bend_at] ++ skin_bend ++ engine_part[bend_at..];
    };
}

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
    " target = vec4(lit(ALBEDO, METALLIC, ROUGHNESS, EMISSION, NORMAL_MAP, AO, WORLD_POSITION, WORLD_NORMAL, WORLD_TANGENT, LIGHT_LIST_0, LIGHT_LIST_1, GI_AT), ALPHA); ";

pub const epilogue_len: u32 = epilogue.len;

/// What a shadow caster's ends with: only what its alpha leaves out. It is
/// compiled to give no colour at all.
const caster_epilogue = " if (ALPHA < FEEL.z) { discard; } ";

/// What a `.shader3d` file is compiled as: the surface lit, or what casts
/// its shadow - the same surface, its depth alone.
pub const Variant = enum { lit, caster };

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
    \\// What a material gives this shader: each field starts as it says here,
    \\// and the Inspector changes it for the material, or for one entity.
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
    return wholeAs(gpa, text, .lit);
}

/// `whole` for `variant`: a caster's stage ends by leaving out what its alpha
/// does, and writes nothing.
pub fn wholeAs(gpa: Allocator, text: []const u8, variant: Variant) Allocator.Error!Whole {
    return wholeOf(gpa, text, variant, false);
}

/// `wholeAs` for a mesh a skeleton bends, or not: a skinned one's engine
/// part reads each vertex's bones and the `Skin` block, and bends it.
pub fn wholeOf(gpa: Allocator, text: []const u8, variant: Variant, skinned: bool) Allocator.Error!Whole {
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
        w.writeAll(if (variant == .lit) epilogue else caster_epilogue) catch return error.OutOfMemory;
        w.writeAll(text[end..]) catch return error.OutOfMemory;
    } else w.writeAll(text) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    out.engine_line = std.mem.count(u8, full.written(), "\n") + 1;
    w.writeAll(enginePart(skinned)) catch return error.OutOfMemory;
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
    cull: Material3DData.Cull,
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
    /// The file's own block, whose fields a material fills, and an entity
    /// over it.
    params: ?shader.Block = null,
    writes_normal_map: bool = false,
    /// By the count of samples it draws into - its power of two - and way:
    /// made the first time it is drawn so.
    pipelines: [sample_counts][Way.count]rhi.Pipeline = @splat(@splat(.none)),
    /// The same for a solid surface whose depth a pass before drew: tested
    /// against it as far as it and no further, and writing none.
    after_depth: [sample_counts][Way.count]rhi.Pipeline = @splat(@splat(.none)),
    /// Whether the device refused a pipeline of it: then what names it is
    /// drawn as though it named none.
    refused: bool = false,
    /// What casts its shadow: the same surface, drawn as depth alone.
    caster: Caster,
    /// Whether the file reads `TIME`: then what it casts may change while
    /// nothing moves, and a shadow it is in is drawn again every time.
    reads_time: bool = false,
    /// Whether it is the variant that bends a mesh a skeleton bends.
    skin: bool = false,
    /// That variant of it, compiled the first time a skinned mesh is drawn
    /// with it; see `skinnedOf`.
    skinned: ?*Compiled = null,
    skin_refused: bool = false,
    /// What it was compiled from, for that.
    gpa: Allocator,
    text: []u8 = &.{},
    label: []u8 = &.{},

    /// The caster variant, and its pipelines by the side culled.
    pub const Caster = struct {
        module: shader.Module,
        gpu: rhi.Shader,
        pipelines: [3]rhi.Pipeline = @splat(.none),
        /// Its depth drawn first into the picture's own depth, by samples
        /// and side culled.
        depth_first: [sample_counts][3]rhi.Pipeline = @splat(@splat(.none)),
        refused: bool = false,
    };

    pub fn deinit(self: *Compiled, device: *rhi.Device) void {
        if (self.skinned) |held| {
            held.deinit(device);
            self.gpa.destroy(held);
        }
        self.gpa.free(self.text);
        self.gpa.free(self.label);
        for (self.pipelines) |row| for (row) |pipeline| if (!pipeline.isNone()) device.destroyPipeline(pipeline);
        for (self.after_depth) |row| for (row) |pipeline| if (!pipeline.isNone()) device.destroyPipeline(pipeline);
        for (self.caster.pipelines) |pipeline| if (!pipeline.isNone()) device.destroyPipeline(pipeline);
        for (self.caster.depth_first) |row| for (row) |pipeline| if (!pipeline.isNone()) device.destroyPipeline(pipeline);
        device.destroyShader(self.gpu);
        device.destroyShader(self.caster.gpu);
        self.module.deinit();
        self.caster.module.deinit();
        self.* = undefined;
    }

    /// The variant that bends a mesh a skeleton bends: compiled the first
    /// time it is asked for, or null where it does not compile - such a
    /// mesh is then drawn as it was made.
    pub fn skinnedOf(self: *Compiled, device: *rhi.Device) ?*Compiled {
        if (self.skin) return self;
        if (self.skinned) |held| return held;
        if (self.skin_refused) return null;
        var problems: std.Io.Writer.Allocating = .init(self.gpa);
        defer problems.deinit();
        const made = self.gpa.create(Compiled) catch return null;
        made.* = compileWith(self.gpa, device, self.text, self.label, true, &problems.writer) catch {
            self.gpa.destroy(made);
            self.skin_refused = true;
            log.err("a 3D shader's skinned variant did not compile: {s}", .{problems.written()});
            return null;
        };
        self.skinned = made;
        return made;
    }

    /// The pipeline it is drawn with into `color_format` and `depth_format`,
    /// with `samples` a pixel, `way`.
    pub fn pipelineOf(self: *Compiled, device: *rhi.Device, color_format: rhi.Format, depth_format: rhi.Format, samples: u32, way: Way) !rhi.Pipeline {
        const row = std.math.log2_int(u32, samples);
        const held = &self.pipelines[row][way.index()];
        if (!held.isNone()) return held.*;
        const see_through = way.blend;
        held.* = makePipeline(device, &self.module, self.gpu, self.skin, .{
            .blend = if (see_through) .alpha else .solid,
            // See-through meshes are tested against the solid ones and
            // write no depth: one behind another still shows through.
            .depth = .{ .test_enabled = true, .write = !see_through, .compare = .less },
            .cull = cullOf(way.cull),
            .color_format = color_format,
            .depth_format = depth_format,
            .samples = samples,
            .label = "3D",
        }) catch |err| {
            self.refused = true;
            log.err("the graphics driver refused a 3D shader's pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        return held.*;
    }

    /// `pipelineOf` for a solid surface whose depth `depthFirstPipelineOf`
    /// drew before: the depth test passes where it is that very depth, and
    /// writes none. A see-through one's is its own.
    pub fn afterDepthPipelineOf(self: *Compiled, device: *rhi.Device, color_format: rhi.Format, depth_format: rhi.Format, samples: u32, way: Way) !rhi.Pipeline {
        if (way.blend) return self.pipelineOf(device, color_format, depth_format, samples, way);
        const row = std.math.log2_int(u32, samples);
        const held = &self.after_depth[row][way.index()];
        if (!held.isNone()) return held.*;
        held.* = makePipeline(device, &self.module, self.gpu, self.skin, .{
            .depth = .{ .test_enabled = true, .write = false, .compare = .less_equal },
            .cull = cullOf(way.cull),
            .color_format = color_format,
            .depth_format = depth_format,
            .samples = samples,
            .label = "3D after its depth",
        }) catch |err| {
            log.err("the graphics driver refused a 3D shader's pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        return held.*;
    }

    /// The pipeline a solid surface's depth is drawn with before its light,
    /// into the picture's own depth: the caster's, with no push back.
    pub fn depthFirstPipelineOf(self: *Compiled, device: *rhi.Device, depth_format: rhi.Format, samples: u32, cull: Material3DData.Cull) !rhi.Pipeline {
        const row = std.math.log2_int(u32, samples);
        const held = &self.caster.depth_first[row][@intFromEnum(cull)];
        if (!held.isNone()) return held.*;
        held.* = makePipeline(device, &self.caster.module, self.caster.gpu, self.skin, .{
            .depth = .{ .test_enabled = true, .write = true, .compare = .less },
            .cull = cullOf(cull),
            .color_format = null,
            .depth_format = depth_format,
            .samples = samples,
            .label = "3D depth first",
        }) catch |err| {
            log.err("the graphics driver refused a 3D shader's depth pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        return held.*;
    }

    /// The pipeline what it draws casts a shadow with, into a `depth_format`
    /// atlas: depth alone, pushed back by its slope, so a surface does not
    /// shadow itself.
    pub fn casterPipelineOf(self: *Compiled, device: *rhi.Device, depth_format: rhi.Format, cull: Material3DData.Cull) !rhi.Pipeline {
        const held = &self.caster.pipelines[@intFromEnum(cull)];
        if (!held.isNone()) return held.*;
        held.* = makePipeline(device, &self.caster.module, self.caster.gpu, self.skin, .{
            .depth = .{ .test_enabled = true, .write = true, .compare = .less, .slope_bias = caster_slope_bias },
            .cull = cullOf(cull),
            .color_format = null,
            .depth_format = depth_format,
            .label = "3D shadow",
        }) catch |err| {
            self.caster.refused = true;
            log.err("the graphics driver refused a 3D shader's shadow pipeline: {s}", .{device.diagnostics()});
            return err;
        };
        return held.*;
    }
};

/// How far what casts a shadow is pushed back, times its depth's slope.
pub const caster_slope_bias = 1.5;

/// What a 3D pipeline is drawn into, and how.
const PipelineWay = struct {
    blend: rhi.BlendState = .solid,
    depth: rhi.DepthState,
    cull: rhi.CullMode,
    color_format: ?rhi.Format,
    depth_format: rhi.Format,
    samples: u32 = 1,
    label: []const u8,
};

fn makePipeline(device: *rhi.Device, module: *shader.Module, gpu: rhi.Shader, skinned: bool, way: PipelineWay) !rhi.Pipeline {
    var attributes: [16]rhi.VertexAttribute = undefined;
    var strides: [3]u32 = @splat(0);
    for (module.attributes, 0..) |a, i| {
        const buffer = bufferOf(a.name);
        const format = vertexFormat(a.name, a.ty).?;
        attributes[i] = .{ .location = a.location, .format = format, .offset = strides[buffer], .buffer = buffer };
        strides[buffer] += format.size();
    }
    std.debug.assert(strides[0] == @sizeOf(mesh.Vertex));
    std.debug.assert(strides[1] == @sizeOf(Instance));
    std.debug.assert(strides[2] == if (skinned) @as(u32, @sizeOf(mesh.SkinVertex)) else 0);
    const buffers = [_]rhi.VertexBufferLayout{
        .{ .stride = strides[0] },
        .{ .stride = strides[1], .step = .instance },
        .{ .stride = strides[2] },
    };
    return device.createPipeline(.{
        .shader = gpu,
        .attributes = attributes[0..module.attributes.len],
        .buffers = buffers[0..if (skinned) 3 else 2],
        .topology = .triangles,
        .blend = way.blend,
        .depth = way.depth,
        .cull = way.cull,
        .front_face = .ccw,
        .color_format = way.color_format,
        .depth_format = way.depth_format,
        .samples = way.samples,
        .uniform_blocks = try blockNames(module),
        .textures = (try module.textureNames()).?,
        .label = way.label,
    });
}

/// Its blocks' names by slot: none at the file's own slot when it has no
/// block there, which the device binds nothing to.
fn blockNames(module: *shader.Module) ![]const [:0]const u8 {
    const arena = module.arena.allocator();
    const names = try arena.alloc([:0]const u8, @max(@max(@max(shadows_slot, probes_slot), skin_slot), fog_volumes.slot) + 1);
    @memset(names, "");
    for (module.blocks) |block| names[block.slot] = try arena.dupeZ(u8, block.name);
    return names;
}

fn cullOf(cull: Material3DData.Cull) rhi.CullMode {
    return switch (cull) {
        .back => .back,
        .front => .front,
        .disabled => .none,
    };
}

/// Which attributes are the mesh's own, which its skin's - a third buffer -
/// and which per instance.
fn bufferOf(name: []const u8) u32 {
    if (std.mem.startsWith(u8, name, "VERTEX_")) return 0;
    if (std.mem.startsWith(u8, name, "SKIN_")) return 2;
    return 1;
}

/// What an attribute is read as: its type's floats, but a vertex's colour
/// and its bones, which are four bytes.
fn vertexFormat(name: []const u8, ty: shader.Type) ?rhi.VertexFormat {
    if (std.mem.eql(u8, name, "VERTEX_COLOR") or std.mem.eql(u8, name, "SKIN_JOINTS")) return .ubyte4_norm;
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
    return compileWith(gpa, device, text, label, false, problems);
}

/// `compile`, as the variant that bends a mesh a skeleton bends or not.
fn compileWith(gpa: Allocator, device: *rhi.Device, text: []const u8, label: []const u8, skinned: bool, problems: *std.Io.Writer) (error{ShaderFailed} || Allocator.Error || rhi.Error)!Compiled {
    var lit = try compileAs(gpa, device, text, label, .lit, skinned, problems);
    errdefer {
        device.destroyShader(lit.gpu);
        lit.module.deinit();
    }
    // The caster is the same file: what is wrong with it was said above.
    var caster = try compileAs(gpa, device, text, label, .caster, skinned, problems);
    errdefer {
        device.destroyShader(caster.gpu);
        caster.module.deinit();
    }
    const own_text = try gpa.dupe(u8, text);
    errdefer gpa.free(own_text);
    const own_label = try gpa.dupe(u8, label);
    return .{
        .module = lit.module,
        .gpu = lit.gpu,
        .params = lit.params,
        .writes_normal_map = lit.writes_normal_map,
        .caster = .{ .module = caster.module, .gpu = caster.gpu },
        .reads_time = std.mem.indexOf(u8, text, "TIME") != null,
        .skin = skinned,
        .gpa = gpa,
        .text = own_text,
        .label = own_label,
    };
}

const Variant3D = struct {
    module: shader.Module,
    gpu: rhi.Shader,
    params: ?shader.Block,
    writes_normal_map: bool,
};

fn compileAs(gpa: Allocator, device: *rhi.Device, text: []const u8, label: []const u8, variant: Variant, skinned: bool, problems: *std.Io.Writer) (error{ShaderFailed} || Allocator.Error || rhi.Error)!Variant3D {
    const built = try wholeOf(gpa, text, variant, skinned);
    defer gpa.free(built.source);
    if (try built.trespassMessage(gpa, text)) |message| {
        defer gpa.free(message);
        problems.print("{s}\n", .{message}) catch {};
        return error.ShaderFailed;
    }
    var said: std.Io.Writer.Allocating = .init(gpa);
    defer said.deinit();
    var module = shader.compileWith(gpa, built.source, &said.writer, .{ .depth_only = variant == .caster }) catch |err| switch (err) {
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
        if (block.slot < params_slot or block.slot == shadows_slot or block.slot == probes_slot or block.slot == fog_volumes.slot or (skinned and block.slot == skin_slot)) continue;
        if (block.slot != params_slot or params != null) {
            problems.print("a 3D shader's own numbers are one uniform block, at slot {d}: `{s}` is at {d}\n", .{ params_slot, block.name, block.slot }) catch {};
            return error.ShaderFailed;
        }
        params = block;
    }
    if (module.textures.len != texture_count) {
        problems.writeAll("a 3D shader reads the material's pictures; textures of its own are not here yet\n") catch {};
        return error.ShaderFailed;
    }
    checkLayout(&module);
    if (skinned) std.debug.assert(module.block("Skin").?.size == @sizeOf(Skin));

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
        .{ "FOG_COLOR", "fog_color" },             .{ "FOG_HEIGHT", "fog_height" },           .{ "SCREEN", "screen" },
        .{ "TIME", "time" },
    }) |pair| std.debug.assert(frame.offsetOf(pair[0]).? == @offsetOf(Frame, pair[1]));
    std.debug.assert(frame.size <= @sizeOf(Frame));
    const look = module.block("Material").?;
    inline for (.{
        .{ "ALBEDO_COLOR", "albedo_color" }, .{ "EMISSION_COLOR", "emission_color" }, .{ "UV_PLACE", "uv_place" },
        .{ "SURFACE", "surface" },           .{ "FEEL", "feel" },                     .{ "FACING", "facing" },
    }) |pair| std.debug.assert(look.offsetOf(pair[0]).? == @offsetOf(Look, pair[1]));
    std.debug.assert(look.size == @sizeOf(Look));
    const lights = module.block("Lights").?;
    inline for (.{ .{ "LIGHT_PLACES", "places" }, .{ "LIGHT_COLORS", "colors" }, .{ "LIGHT_AIMS", "aims" }, .{ "LIGHT_CONES", "cones" }, .{ "LIGHT_UPS", "ups" }, .{ "LIGHT_COOKIES", "cookies" } }) |pair| {
        std.debug.assert(lights.offsetOf(pair[0]).? == @offsetOf(Lights, pair[1]));
    }
    std.debug.assert(lights.size == @sizeOf(Lights));
    const shadows = module.block("Shadows").?;
    inline for (.{
        .{ "SHADOW_MATRICES", "matrices" }, .{ "SHADOW_RECTS", "rects" },          .{ "SHADOW_VIEWS", "views" },
        .{ "LAMP_SHADOWS", "lamps" },       .{ "LAMP_SOFTNESS", "lamp_softness" }, .{ "SUN_SHADOWS", "suns" },
        .{ "SUN_SPLITS", "sun_splits" },    .{ "SUN_SOFTNESS", "sun_softness" },   .{ "SHADOW_ATLAS", "atlas" },
    }) |pair| std.debug.assert(shadows.offsetOf(pair[0]).? == @offsetOf(shadows3d.Shadows, pair[1]));
    std.debug.assert(shadows.size == @sizeOf(shadows3d.Shadows));
    std.debug.assert(module.textures[shadow_map_slot].shadow and !module.textures[shadow_depth_slot].shadow);
    const probes = module.block("Probes").?;
    std.debug.assert(probes.offsetOf("PROBE_SAMPLES").? == @offsetOf(Probes, "samples"));
    std.debug.assert(probes.offsetOf("GI_ENERGY").? == @offsetOf(Probes, "energy"));
    std.debug.assert(probes.size == @sizeOf(Probes));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the blocks and an instance are laid out as the shader reads them" {
    try testing.expectEqual(@as(usize, 304), @sizeOf(Frame));
    try testing.expectEqual(@as(usize, 96), @sizeOf(Look));
    try testing.expectEqual(@as(usize, 6144), @sizeOf(Lights));
    // Under the sixteen kilobytes every device binds a block of.
    try testing.expect(@sizeOf(shadows3d.Shadows) <= 16384);
    try testing.expectEqual(@as(usize, 128), @sizeOf(Instance));
    try testing.expectEqual(@as(usize, 60), @sizeOf(mesh.Vertex));
    try testing.expect(@sizeOf(Probes) <= 16384);
    // As many bones as a vertex names, and under the sixteen kilobytes too.
    try testing.expectEqual(@as(usize, 12288), @sizeOf(Skin));
    try testing.expectEqual(@as(usize, 20), @sizeOf(mesh.SkinVertex));
    for (0..Way.count) |at| try testing.expectEqual(at, Way.of(at).index());
}

test "a shader's skinned variant is compiled when first asked for, for every backend, and kept" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();
    var own = try compile(testing.allocator, &device, plain, "plain", &problems.writer);
    defer own.deinit(&device);
    try testing.expect(own.skinned == null);

    const skinned = own.skinnedOf(&device).?;
    try testing.expect(skinned.skin);
    try testing.expectEqual(skinned, own.skinnedOf(&device).?);
    try testing.expectEqual(skinned, skinned.skinnedOf(&device).?);
    // Its bones at the last two places, and its block at its slot.
    var found: u32 = 0;
    for (skinned.module.attributes) |a| {
        if (std.mem.eql(u8, a.name, "SKIN_JOINTS")) found += @intFromBool(a.location == 14);
        if (std.mem.eql(u8, a.name, "SKIN_WEIGHTS")) found += @intFromBool(a.location == 15);
    }
    try testing.expectEqual(@as(u32, 2), found);
    try testing.expectEqual(@as(u32, skin_slot), skinned.module.block("Skin").?.slot);
    for ([_][]const u8{ skinned.module.glsl.vertex, skinned.module.glsl_es.vertex, skinned.module.hlsl.vertex }) |source| {
        try testing.expect(std.mem.indexOf(u8, source, "BONES") != null);
    }
    try testing.expect(skinned.module.spirv.vertex.len > 0);
    try testing.expect(skinned.caster.module.block("Skin") != null);
    // Its pipelines take the third buffer; the plain ones do not.
    _ = try skinned.pipelineOf(&device, .rgba16_float, .depth32_float, 1, .{ .cull = .back, .blend = false });
    _ = try skinned.casterPipelineOf(&device, .depth32_float, .back);
    _ = try own.pipelineOf(&device, .rgba16_float, .depth32_float, 1, .{ .cull = .back, .blend = false });
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
