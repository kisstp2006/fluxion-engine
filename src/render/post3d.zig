// SPDX-License-Identifier: BSD-3-Clause

//! What the 3D layer is drawn into, and how it becomes a picture.
//!
//! The light a camera sees is worked out in a target of its own, as it adds
//! up - brighter than white where it is - in half floats where the device
//! draws into them: with several samples a pixel where the project asks for
//! them, averaged into one when the pass ends. Then, each a pass over the
//! whole of it:
//!
//! - **Glow**: what is brighter than the environment's threshold, taken
//!   out at half the size, made smaller and smaller, and added back up the
//!   way it came, each step spread a little: bloom. What the levels add up
//!   to is divided by how many there are, so the glow is as strong whatever
//!   the size of the picture.
//! - **Occlusion** (SSAO), before the frame's light is worked out, from the
//!   geometry pass: round each pixel a dozen points in the half above its
//!   surface, each looked for on the screen; those behind what is drawn
//!   there are hidden. At half the size, then smoothed where the depth is
//!   alike. The 3D surfaces read it as how much light from everywhere
//!   reaches them - not the sun's, which their shadows say.
//! - **Reflections** (SSR): from each smooth pixel the view's ray bounced
//!   off it is followed across the screen until it goes behind what is
//!   drawn there; what is seen there is added, as much as the surface's
//!   Fresnel says, fading toward the screen's edges and with distance.
//! - **The sun's rays**: from each pixel toward the sun on the screen, what
//!   is brighter than white and nothing stands in front of - the sky, its
//!   sun - added up and dimming with distance: shafts through what stands
//!   before it.
//! - **Tone**: the light times the exposure, with the glow added, brought
//!   into what a screen shows - as it is, Reinhard, filmic or ACES - and
//!   written as a picture's colours are - sharpened, graded for
//!   colourfulness, contrast and warmth, and darkened toward its corners.
//! - **Smoothing**, where the project asks for it: an edge smoother over
//!   the toned picture.
//!
//! The passes are one list, their numbers one buffer each binds a part of.
//! The targets are kept by size, as depth is, and let go of once nothing
//! has drawn at a size for a few frames.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const material = @import("material.zig");
const shader3d = @import("shader3d.zig");
const Environment = @import("render3d_components.zig").Environment;
const UniformBlocks = @import("uniform_blocks.zig").UniformBlocks;

const log = std.log.scoped(.fluxion_engine);

/// The most times the glow is made smaller.
const most_glow_levels = 6;

/// What every pass is told: the size of a pixel of what it reads, which way
/// up a picture drawn into is read, and the pass's own numbers.
const Post = extern struct {
    /// One over the source's width and height; how a target drawn into is
    /// read, as `material.screenFlip` says; nought.
    texel: [4]f32,
    knobs: [4]f32,
    /// The tone pass's grading: colourfulness, contrast, vignette and
    /// sharpening; and its white's colour.
    more: [4]f32 = @splat(0),
    grade: [4]f32 = .{ 1, 1, 1, 0 },
    /// The camera, for the passes that read the geometry: a point's place
    /// on the screen, and the way through a pixel - `forward`, with `right`
    /// and `up` as far as the picture's edges are from it a unit along.
    view_projection: math.Mat4 = .identity,
    eye: [4]f32 = @splat(0),
    forward: [4]f32 = @splat(0),
    right: [4]f32 = @splat(0),
    up: [4]f32 = @splat(0),
};

/// What the passes reading the geometry are told of the camera, and of the
/// sun for its rays.
pub const Camera = struct {
    view_projection: math.Mat4 = .identity,
    eye: math.Vec3 = .zero,
    forward: math.Vec3 = .zero,
    /// As far as the picture's right and top edges are from the middle, a
    /// unit along `forward`.
    right: math.Vec3 = .zero,
    up: math.Vec3 = .zero,
    /// Where the sun is on the screen, and how much of its rays are seen:
    /// nought behind the camera or far off the screen.
    sun_uv: [2]f32 = .{ 0, 0 },
    sun_seen: f32 = 0,
    /// The sun as it is seen, for its disc's rays and flare.
    sun_light: [3]f32 = .{ 0, 0, 0 },
    /// Toward the first sun, and the light it gives the world: what the air
    /// scatters toward the eye.
    sun_toward: math.Vec3 = .zero,
    sun_color: [3]f32 = .{ 0, 0, 0 },
    /// The shadows' numbers and their atlas, read as it is: where the air
    /// the sun lights is found. Null with no shadow of the first sun.
    shadows: ?rhi.Buffer = null,
    shadow_depth: ?rhi.Texture = null,
};

/// The three corners of a triangle that covers the whole target.
const corners = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };

const vertex_part =
    \\attribute vec2 CORNER : 0;
    \\varying vec2 UV;
    \\uniform Post : 0 {
    \\    vec4 TEXEL;
    \\    vec4 KNOBS;
    \\    vec4 MORE;
    \\    vec4 GRADE;
    \\    mat4 VIEW_PROJECTION;
    \\    vec4 EYE;
    \\    vec4 FORWARD;
    \\    vec4 RIGHT;
    \\    vec4 UP;
    \\}
    \\vertex {
    \\    UV = vec2(CORNER.x * 0.5 + 0.5, CORNER.y * 0.5 * TEXEL.z + 0.5);
    \\    position = vec4(CORNER, 0.0, 1.0);
    \\}
    \\
;

/// What is brighter than `KNOBS.x`, after the exposure in `KNOBS.y`: by
/// its brightest channel, so a deep red or orange glows as a white of the
/// same strength does, with a soft knee half the threshold wide so the glow
/// does not start at an edge. No pixel glows brighter than sixteen, so one
/// spark does not light the screen.
const bright_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec3 light = sample(SOURCE, UV).rgb;
    \\    vec3 seen = light * KNOBS.y;
    \\    float brightest = max(seen.r, max(seen.g, seen.b));
    \\    float knee = KNOBS.x * 0.5 + 0.0001;
    \\    float soft = clamp(brightest - KNOBS.x + knee, 0.0, 2.0 * knee);
    \\    soft = soft * soft / (4.0 * knee);
    \\    float kept = max(soft, brightest - KNOBS.x) / max(brightest, 0.0001);
    \\    vec3 glow = light * kept;
    \\    float peak = max(glow.r, max(glow.g, glow.b)) * KNOBS.y;
    \\    target = vec4(glow * (16.0 / max(peak, 16.0)), 1.0);
    \\}
;

/// Half the size: thirteen taps over the four by four pixels under each,
/// the middle ones counted most, which keeps a small bright thing from
/// flickering as it moves.
const down_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec2 t = TEXEL.xy;
    \\    vec3 a = sample(SOURCE, UV + t * vec2(-2.0, -2.0)).rgb;
    \\    vec3 b = sample(SOURCE, UV + t * vec2(0.0, -2.0)).rgb;
    \\    vec3 c = sample(SOURCE, UV + t * vec2(2.0, -2.0)).rgb;
    \\    vec3 d = sample(SOURCE, UV + t * vec2(-2.0, 0.0)).rgb;
    \\    vec3 e = sample(SOURCE, UV).rgb;
    \\    vec3 f = sample(SOURCE, UV + t * vec2(2.0, 0.0)).rgb;
    \\    vec3 g = sample(SOURCE, UV + t * vec2(-2.0, 2.0)).rgb;
    \\    vec3 h = sample(SOURCE, UV + t * vec2(0.0, 2.0)).rgb;
    \\    vec3 i = sample(SOURCE, UV + t * vec2(2.0, 2.0)).rgb;
    \\    vec3 j = sample(SOURCE, UV + t * vec2(-1.0, -1.0)).rgb;
    \\    vec3 k = sample(SOURCE, UV + t * vec2(1.0, -1.0)).rgb;
    \\    vec3 l = sample(SOURCE, UV + t * vec2(-1.0, 1.0)).rgb;
    \\    vec3 m = sample(SOURCE, UV + t * vec2(1.0, 1.0)).rgb;
    \\    vec3 sum = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    \\    target = vec4(sum, 1.0);
    \\}
;

/// Twice the size: a three by three tent, `KNOBS.x` pixels of the smaller
/// wide, times `KNOBS.y`, added to what is there.
const up_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\fragment {
    \\    vec2 t = TEXEL.xy * KNOBS.x;
    \\    vec3 sum = sample(SOURCE, UV + t * vec2(-1.0, -1.0)).rgb + sample(SOURCE, UV + t * vec2(1.0, -1.0)).rgb
    \\        + sample(SOURCE, UV + t * vec2(-1.0, 1.0)).rgb + sample(SOURCE, UV + t).rgb
    \\        + 2.0 * (sample(SOURCE, UV + t * vec2(0.0, -1.0)).rgb + sample(SOURCE, UV + t * vec2(-1.0, 0.0)).rgb
    \\        + sample(SOURCE, UV + t * vec2(1.0, 0.0)).rgb + sample(SOURCE, UV + t * vec2(0.0, 1.0)).rgb)
    \\        + 4.0 * sample(SOURCE, UV).rgb;
    \\    target = vec4(sum * (KNOBS.y / 16.0), 1.0);
    \\}
;

/// The light, times the exposure in `KNOBS.x`, with `KNOBS.w` of the glow,
/// toned by the curve `KNOBS.z` names with the white in `KNOBS.y`, and
/// written as a picture's colours are.
/// What the passes reading the geometry share: a surface's way back out
/// of its two numbers, its place from where on the screen it is and how
/// far, and a place's spot on the screen.
const geometry_part =
    \\texture2d GEOMETRY : 1;
    \\
    \\vec3 normalFrom(vec2 e) {
    \\    vec3 n = vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    \\    if (n.z < 0.0) {
    \\        vec2 folded = (vec2(1.0) - abs(vec2(n.y, n.x))) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    \\        n = vec3(folded.x, folded.y, n.z);
    \\    }
    \\    return normalize(n);
    \\}
    \\
    \\vec3 placeAt(vec2 uv, float depth) {
    \\    vec2 ndc = vec2(uv.x * 2.0 - 1.0, (uv.y - 0.5) * 2.0 * TEXEL.z);
    \\    return EYE.xyz + (FORWARD.xyz + RIGHT.xyz * ndc.x + UP.xyz * ndc.y) * depth;
    \\}
    \\
    \\vec2 uvOf(vec3 p) {
    \\    vec4 c = VIEW_PROJECTION * vec4(p, 1.0);
    \\    vec2 ndc = c.xy / max(c.w, 0.0001);
    \\    return vec2(ndc.x * 0.5 + 0.5, ndc.y * 0.5 * TEXEL.z + 0.5);
    \\}
    \\
    \\float alongView(vec3 p) {
    \\    return dot(p - EYE.xyz, FORWARD.xyz);
    \\}
    \\
    \\bool onScreen(vec2 uv) {
    \\    return uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
    \\}
    \\
;

/// How much light from everywhere reaches each pixel, at half the size:
/// `KNOBS.x` the radius, `KNOBS.y` how dark. `TEXEL` is the geometry's.
const occlusion_source = vertex_part ++
    \\texture2d UNUSED : 0;
    \\
++ geometry_part ++
    \\fragment {
    \\    vec4 g = sample_level(GEOMETRY, UV, 0.0);
    \\    float ao = 1.0 + sample_level(UNUSED, UV, 0.0).a * 0.0;
    \\    if (g.z > 0.0 && g.w < 2.0) {
    \\        vec3 p = placeAt(UV, g.z);
    \\        vec3 n = normalFrom(g.xy);
    \\        vec3 side = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    \\        vec3 t = normalize(cross(n, side));
    \\        vec3 b = cross(n, t);
    \\        vec2 pixel = floor(UV / TEXEL.xy);
    \\        float turn = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715)))) * 6.2831853;
    \\        float radius = KNOBS.x;
    \\        float hidden = 0.0;
    \\        for (int i = 0; i < 12; i = i + 1) {
    \\            float f = (float(i) + 0.5) / 12.0;
    \\            float a = float(i) * 2.39996323 + turn;
    \\            float lift = 0.3 + 0.7 * fract(f * 7.31);
    \\            vec3 way = normalize(t * cos(a) + b * sin(a) + n * lift);
    \\            vec3 at = p + n * (0.02 * radius) + way * (radius * (0.2 + 0.8 * f * f));
    \\            vec2 there = uvOf(at);
    \\            if (onScreen(there)) {
    \\                vec4 sg = sample_level(GEOMETRY, there, 0.0);
    \\                float own = alongView(at);
    \\                if (sg.z > 0.0 && sg.w < 2.0 && sg.z < own - 0.02 * radius) {
    \\                    hidden = hidden + clamp(radius / max(abs(g.z - sg.z), 0.0001), 0.0, 1.0);
    \\                }
    \\            }
    \\        }
    \\        ao = clamp(1.0 - hidden / 12.0 * KNOBS.y, 0.0, 1.0);
    \\    }
    \\    target = vec4(ao, ao, ao, 1.0);
    \\}
;

/// The occlusion smoothed over four by four of its pixels, each counted as
/// much as its depth is like the middle one's. `TEXEL` is the occlusion's.
const occlusion_blur_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
++ geometry_part ++
    \\fragment {
    \\    float middle = sample_level(GEOMETRY, UV, 0.0).z;
    \\    float sum = 0.0;
    \\    float weight = 0.0;
    \\    for (int i = 0; i < 16; i = i + 1) {
    \\        vec2 off = vec2(float(i % 4) - 1.5, float(i / 4) - 1.5) * TEXEL.xy;
    \\        float d = sample_level(GEOMETRY, UV + off, 0.0).z;
    \\        float w = exp(-abs(d - middle) / max(middle * 0.03, 0.01));
    \\        sum = sum + sample_level(SOURCE, UV + off, 0.0).r * w;
    \\        weight = weight + w;
    \\    }
    \\    float ao = sum / max(weight, 0.0001);
    \\    target = vec4(ao, ao, ao, 1.0);
    \\}
;

/// The light, with what smooth surfaces reflect of the screen added:
/// `KNOBS.x` how far a reflection is looked for, `KNOBS.y` how strong.
const reflect_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
++ geometry_part ++
    \\fragment {
    \\    vec4 light = sample_level(SOURCE, UV, 0.0);
    \\    vec4 g = sample_level(GEOMETRY, UV, 0.0);
    \\    vec3 result = light.rgb;
    \\    float gloss = abs(g.w);
    \\    if (g.z > 0.0 && gloss < 2.0 && gloss > 0.35) {
    \\        vec3 p = placeAt(UV, g.z);
    \\        vec3 n = normalFrom(g.xy);
    \\        vec3 v = normalize(p - EYE.xyz);
    \\        vec3 r = reflect(v, n);
    \\        vec3 from = p + n * (0.01 + g.z * 0.002);
    \\        float reach = KNOBS.x;
    \\        float t = 0.1;
    \\        float before = 0.0;
    \\        float stride = reach / 60.0;
    \\        float found = 0.0;
    \\        vec2 hit = UV;
    \\        for (int i = 0; i < 40; i = i + 1) {
    \\            if (found == 0.0) {
    \\                vec3 q = from + r * t;
    \\                vec2 there = uvOf(q);
    \\                float own = alongView(q);
    \\                if (!onScreen(there) || own <= 0.0 || t > reach) {
    \\                    found = -1.0;
    \\                } else {
    \\                    float depth = sample_level(GEOMETRY, there, 0.0).z;
    \\                    if (depth > 0.0 && own > depth && own - depth < max(0.3, stride * 1.5)) {
    \\                        found = 1.0;
    \\                        hit = there;
    \\                    } else {
    \\                        before = t;
    \\                        t = t + stride;
    \\                        stride = stride * 1.07;
    \\                    }
    \\                }
    \\            }
    \\        }
    \\        if (found > 0.5) {
    \\            float low = before;
    \\            float high = t;
    \\            for (int k = 0; k < 5; k = k + 1) {
    \\                float mid = (low + high) * 0.5;
    \\                vec3 q = from + r * mid;
    \\                vec2 there = uvOf(q);
    \\                float depth = sample_level(GEOMETRY, there, 0.0).z;
    \\                if (depth > 0.0 && alongView(q) > depth) {
    \\                    high = mid;
    \\                    hit = there;
    \\                } else {
    \\                    low = mid;
    \\                }
    \\            }
    \\            vec3 seen = sample_level(SOURCE, hit, 0.0).rgb;
    \\            float facing = clamp(dot(-v, n), 0.0, 1.0);
    \\            float f0 = g.w < 0.0 ? 0.6 : 0.04;
    \\            float fresnel = f0 + (1.0 - f0) * pow(1.0 - facing, 5.0);
    \\            vec2 edge = min(hit, vec2(1.0) - hit);
    \\            float fade = clamp(min(edge.x, edge.y) * 10.0, 0.0, 1.0) * clamp(1.0 - high / reach, 0.0, 1.0) * clamp((gloss - 0.35) / 0.3, 0.0, 1.0);
    \\            result = result + seen * (fresnel * fade * KNOBS.y);
    \\        }
    \\    }
    \\    target = vec4(result, light.a);
    \\}
;

/// The sun's light at half the size: its rays toward it on the screen, at
/// `KNOBS.xy`, `KNOBS.z` of them - from what is far brighter than white
/// where nothing near is drawn, the sun's disc; where the picture's alpha is
/// nought, the world drawn over a skybox that holds the sky, the disc is put
/// there, `MORE.rgb` its light - its lens flare, `KNOBS.w` of it, as much as
/// the sun is seen; and the light in the air, `RAYS`, added.
const shafts_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
++ geometry_part ++
    \\texture2d RAYS : 2;
    \\
    \\// How much of the sun's disc is seen at `uv`: none behind what is drawn.
    \\float sunAt(vec2 uv) {
    \\    if (!onScreen(uv)) {
    \\        return 0.0;
    \\    }
    \\    vec4 c = sample_level(SOURCE, uv, 0.0);
    \\    if (c.a < 0.5) {
    \\        return 1.0;
    \\    }
    \\    float bright = max(c.r, max(c.g, c.b));
    \\    if (sample_level(GEOMETRY, uv, 0.0).z > 0.0) {
    \\        return 0.0;
    \\    }
    \\    return clamp((bright - 3.0) / 6.0, 0.0, 1.0);
    \\}
    \\
    \\// A soft round spot `size` across at `at`, in the picture's own
    \\// proportions.
    \\float spot(vec2 uv, vec2 at, float size, float aspect) {
    \\    vec2 off = (uv - at) * vec2(aspect, 1.0);
    \\    return smoothstep(size, size * 0.4, length(off));
    \\}
    \\
    \\fragment {
    \\    vec2 sun = KNOBS.xy;
    \\    float aspect = TEXEL.y / TEXEL.x;
    \\    vec3 sum = sample_level(RAYS, UV, 0.0).rgb;
    \\    if (KNOBS.z > 0.0) {
    \\        vec2 delta = (sun - UV) / 32.0;
    \\        // Each pixel starts a little further along than its neighbours,
    \\        // so the steps blur into grain, not into bands and blotches.
    \\        vec2 pixel = floor(UV / TEXEL.xy * 0.5);
    \\        float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
    \\        vec2 at = UV + delta * jitter;
    \\        float decay = 1.0;
    \\        vec3 rays = vec3(0.0);
    \\        for (int i = 0; i < 32; i = i + 1) {
    \\            at = at + delta;
    \\            float seen = sunAt(at) * spot(at, sun, 0.08, aspect);
    \\            rays = rays + MORE.rgb * (seen * decay);
    \\            decay = decay * 0.95;
    \\        }
    \\        sum = sum + rays * (KNOBS.z * 6.0 / 32.0);
    \\    }
    \\    if (KNOBS.w > 0.0) {
    \\        // How much of the disc is seen: a ring of readings round it.
    \\        float seen = 0.0;
    \\        for (int i = 0; i < 12; i = i + 1) {
    \\            float a = float(i) * 0.5235988;
    \\            seen = seen + sunAt(sun + vec2(cos(a) / aspect, sin(a)) * 0.006);
    \\        }
    \\        seen = seen / 12.0;
    \\        if (seen > 0.0) {
    \\            vec2 toward = vec2(0.5) - sun;
    \\            vec3 flare = vec3(0.0);
    \\            // Ghosts along the line through the middle, each its own size and tint.
    \\            flare = flare + vec3(0.5, 0.8, 1.0) * spot(UV, sun + toward * 0.45, 0.03, aspect) * 0.2;
    \\            flare = flare + vec3(1.0, 0.7, 0.4) * spot(UV, sun + toward * 0.8, 0.05, aspect) * 0.1;
    \\            flare = flare + vec3(0.6, 1.0, 0.6) * spot(UV, sun + toward * 1.25, 0.02, aspect) * 0.16;
    \\            flare = flare + vec3(0.7, 0.6, 1.0) * spot(UV, sun + toward * 1.6, 0.07, aspect) * 0.06;
    \\            flare = flare + vec3(1.0, 0.9, 0.7) * spot(UV, sun + toward * 2.1, 0.035, aspect) * 0.12;
    \\            // A halo round the sun, and a streak across it.
    \\            vec2 off = (UV - sun) * vec2(aspect, 1.0);
    \\            float d = length(off);
    \\            flare = flare + vec3(1.0, 0.95, 0.85) * (exp(-d * 22.0) * 0.35);
    \\            flare = flare + vec3(0.8, 0.9, 1.0) * (exp(-abs(off.y) * 160.0) * exp(-abs(off.x) * 4.0) * 0.3);
    \\            float ring = smoothstep(0.015, 0.0, abs(d - 0.32)) * 0.04;
    \\            flare = flare + vec3(0.9, 0.7, 1.0) * ring;
    \\            float bright = max(MORE.r, max(MORE.g, MORE.b));
    \\            sum = sum + flare * (MORE.rgb / max(bright, 0.0001)) * (min(bright, 3.0) * seen * KNOBS.w);
    \\        }
    \\    }
    \\    target = vec4(sum, 1.0);
    \\}
;

/// The light of the first sun the air scatters toward the eye, at half the
/// size: along the way from the eye to what is drawn - no further than
/// `KNOBS.y` - two dozen points, each lit or not as the sun's shadow says
/// there, the air `KNOBS.x` thick a metre, thrown forward as haze is,
/// `KNOBS.z` of it. Shafts of light through a window, a door, the gaps of a
/// roof: the light in the air, and its shadows.
const rays_source = vertex_part ++
    \\uniform Shadows : 1 {
++ shader3d.shadows_fields ++
    \\}
    \\
    \\texture2d UNUSED : 0;
    \\
++ geometry_part ++
    \\texture2d SHADOW_DEPTH : 2;
    \\
    \\// Whether the first sun sees `q`: one, nought behind what casts its
    \\// shadow, one past its shadow's reach.
    \\float sunSees(vec3 q) {
    \\    vec4 s = SUN_SHADOWS[0];
    \\    if (s.x < 0.0) {
    \\        return 1.0;
    \\    }
    \\    int first = int(s.x + 0.5);
    \\    int count = int(s.y + 0.5);
    \\    float result = -1.0;
    \\    for (int c = 0; c < count; c = c + 1) {
    \\        if (result < 0.0) {
    \\            vec4 at = SHADOW_MATRICES[first + c] * vec4(q, 1.0);
    \\            vec4 rect = SHADOW_RECTS[first + c];
    \\            if (at.x > rect.x && at.y > rect.y && at.x < rect.z && at.y < rect.w && at.z < 1.0) {
    \\                float depth = sample_level(SHADOW_DEPTH, at.xy, 0.0).r;
    \\                result = at.z <= depth + 0.0005 ? 1.0 : 0.0;
    \\            }
    \\        }
    \\    }
    \\    return result < 0.0 ? 1.0 : result;
    \\}
    \\
    \\fragment {
    \\    vec4 g = sample_level(GEOMETRY, UV, 0.0) + sample_level(UNUSED, UV, 0.0) * 0.0;
    \\    float reach = KNOBS.y;
    \\    float depth = reach;
    \\    if (g.z > 0.0) {
    \\        depth = min(g.z, reach);
    \\    }
    \\    // What is on the camera's front layers is held at the eye: no air
    \\    // between.
    \\    if (g.w >= 2.0) {
    \\        depth = 0.0;
    \\    }
    \\    vec3 way = placeAt(UV, 1.0) - EYE.xyz;
    \\    vec2 pixel = floor(UV / TEXEL.xy);
    \\    float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
    \\    float lit = 0.0;
    \\    for (int i = 0; i < 24; i = i + 1) {
    \\        float f = (float(i) + jitter) / 24.0;
    \\        lit = lit + sunSees(EYE.xyz + way * (depth * f));
    \\    }
    \\    lit = lit / 24.0;
    \\    float through = depth * length(way);
    \\    float mu = dot(normalize(way), GRADE.xyz);
    \\    float g2 = 0.36;
    \\    float phase = (1.0 - g2) / (12.5663706 * pow(max(1.0 + g2 - 1.2 * mu, 0.0001), 1.5));
    \\    float amount = 1.0 - exp(-KNOBS.x * through);
    \\    target = vec4(MORE.rgb * (lit * amount * phase * KNOBS.z), 1.0);
    \\}
;

/// The light in the air smoothed over four by four of its pixels, each
/// counted as much as its depth is like the middle one's: its readings'
/// grain gone, its edges kept.
const rays_blur_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
++ geometry_part ++
    \\fragment {
    \\    float middle = sample_level(GEOMETRY, UV, 0.0).z;
    \\    vec3 sum = vec3(0.0);
    \\    float weight = 0.0;
    \\    for (int i = 0; i < 16; i = i + 1) {
    \\        vec2 off = vec2(float(i % 4) - 1.5, float(i / 4) - 1.5) * TEXEL.xy;
    \\        float d = sample_level(GEOMETRY, UV + off, 0.0).z;
    \\        float w = exp(-abs(d - middle) / max(middle * 0.05, 0.05));
    \\        sum = sum + sample_level(SOURCE, UV + off, 0.0).rgb * w;
    \\        weight = weight + w;
    \\    }
    \\    target = vec4(sum / max(weight, 0.0001), 1.0);
    \\}
;

const tone_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\texture2d GLOW : 1;
    \\texture2d SHAFTS : 2;
    \\
    \\// The film industry's curve, as Krzysztof Narkowicz fitted it.
    \\vec3 aces(vec3 x) {
    \\    return clamp((x * (2.51 * x + vec3(0.03))) / (x * (2.43 * x + vec3(0.59)) + vec3(0.14)), 0.0, 1.0);
    \\}
    \\
    \\// John Hable's filmic curve.
    \\vec3 hable(vec3 x) {
    \\    return ((x * (0.15 * x + vec3(0.05)) + vec3(0.004)) / (x * (0.15 * x + vec3(0.5)) + vec3(0.06))) - vec3(0.02 / 0.3);
    \\}
    \\
    \\vec3 toSrgb(vec3 light) {
    \\    vec3 x = clamp(light, vec3(0.0), vec3(1.0));
    \\    vec3 low = x * 12.92;
    \\    vec3 high = 1.055 * pow(x, vec3(1.0 / 2.4)) - vec3(0.055);
    \\    return mix(low, high, step(vec3(0.0031308), x));
    \\}
    \\
    \\// The sun's light from its picture at half the size, four readings
    \\// round the pixel: the grain of its steps smoothed away.
    \\vec3 sunLight(vec2 uv) {
    \\    vec2 t = TEXEL.xy * 1.5;
    \\    return (sample(SHAFTS, uv + vec2(-t.x, -t.y)).rgb + sample(SHAFTS, uv + vec2(t.x, -t.y)).rgb
    \\        + sample(SHAFTS, uv + vec2(-t.x, t.y)).rgb + sample(SHAFTS, uv + t).rgb) * 0.25;
    \\}
    \\
    \\fragment {
    \\    vec4 light = sample(SOURCE, UV);
    \\    vec3 c = light.rgb;
    \\    // Sharpened: the pixel pushed away from its neighbours' mean.
    \\    if (MORE.w > 0.0) {
    \\        vec3 around = sample(SOURCE, UV + vec2(TEXEL.x, 0.0)).rgb + sample(SOURCE, UV - vec2(TEXEL.x, 0.0)).rgb
    \\            + sample(SOURCE, UV + vec2(0.0, TEXEL.y)).rgb + sample(SOURCE, UV - vec2(0.0, TEXEL.y)).rgb;
    \\        c = max(c + (c - around * 0.25) * MORE.w, vec3(0.0));
    \\    }
    \\    vec3 seen = (c + sample(GLOW, UV).rgb * KNOBS.w + sunLight(UV)) * KNOBS.x * GRADE.rgb;
    \\    vec3 toned = seen;
    \\    if (KNOBS.z > 2.5) {
    \\        toned = aces(seen);
    \\    } else if (KNOBS.z > 1.5) {
    \\        toned = hable(seen * 2.0) / hable(vec3(11.2 * KNOBS.y));
    \\    } else if (KNOBS.z > 0.5) {
    \\        toned = seen * (vec3(1.0) + seen / vec3(KNOBS.y * KNOBS.y)) / (vec3(1.0) + seen);
    \\    }
    \\    // Graded: colourfulness about its brightness, contrast about the
    \\    // middle grey, and the corners darkened.
    \\    float luma = dot(toned, vec3(0.2126, 0.7152, 0.0722));
    \\    toned = max(mix(vec3(luma), toned, MORE.x), vec3(0.0));
    \\    toned = max((toned - vec3(0.18)) * MORE.y + vec3(0.18), vec3(0.0));
    \\    vec2 off = UV - vec2(0.5);
    \\    toned = toned * clamp(1.0 - dot(off, off) * MORE.z * 2.2, 0.0, 1.0);
    \\    target = vec4(toSrgb(toned), light.a);
    \\}
;

/// Edges smoothed: where the brightness changes across, the pixel is a mix
/// along the edge. Where it hardly changes, it is left as it is.
const smooth_source = vertex_part ++
    \\texture2d SOURCE : 0;
    \\
    \\float brightness(vec3 c) {
    \\    return dot(c, vec3(0.299, 0.587, 0.114));
    \\}
    \\
    \\fragment {
    \\    vec2 px = TEXEL.xy;
    \\    vec4 middle = sample(SOURCE, UV);
    \\    float b_nw = brightness(sample(SOURCE, UV + vec2(-px.x, -px.y)).rgb);
    \\    float b_ne = brightness(sample(SOURCE, UV + vec2(px.x, -px.y)).rgb);
    \\    float b_sw = brightness(sample(SOURCE, UV + vec2(-px.x, px.y)).rgb);
    \\    float b_se = brightness(sample(SOURCE, UV + px).rgb);
    \\    float b_m = brightness(middle.rgb);
    \\    float least = min(b_m, min(min(b_nw, b_ne), min(b_sw, b_se)));
    \\    float most = max(b_m, max(max(b_nw, b_ne), max(b_sw, b_se)));
    \\    vec4 result = middle;
    \\    if (most - least >= max(0.0312, most * 0.125)) {
    \\        vec2 along = vec2(-((b_nw + b_ne) - (b_sw + b_se)), (b_nw + b_sw) - (b_ne + b_se));
    \\        float reduce = max((b_nw + b_ne + b_sw + b_se) * 0.03125, 1.0 / 128.0);
    \\        float scale = 1.0 / (min(abs(along.x), abs(along.y)) + reduce);
    \\        along = clamp(along * scale, vec2(-8.0), vec2(8.0)) * px;
    \\        vec3 near = 0.5 * (sample(SOURCE, UV + along * (1.0 / 3.0 - 0.5)).rgb + sample(SOURCE, UV + along * (2.0 / 3.0 - 0.5)).rgb);
    \\        vec3 wide = near * 0.5 + 0.25 * (sample(SOURCE, UV - along * 0.5).rgb + sample(SOURCE, UV + along * 0.5).rgb);
    \\        float b_wide = brightness(wide);
    \\        result = vec4((b_wide < least || b_wide > most) ? near : wide, middle.a);
    \\    }
    \\    target = result;
    \\}
;

/// One pass over the whole of a target, waiting for its numbers to be
/// written with the rest.
const Pass = struct {
    pipeline: rhi.Pipeline,
    into: rhi.RenderTarget,
    width: u32,
    height: u32,
    load: rhi.LoadOp,
    sources: [3]rhi.Texture,
    source_count: u8,
    /// Which sources are read texel by texel, not blended: the geometry's.
    nearest: u8 = 0,
    /// A second block, at slot 1: the shadows' numbers.
    second: ?rhi.Buffer = null,
    knobs: Post,
    /// Where its numbers are in the buffer, once they are written.
    at: u32 = 0,
};

/// A pass's shader and the pipelines it is drawn with.
const Stage = struct {
    module: ?shader.Module = null,
    gpu: rhi.Shader = .none,
    pipeline: rhi.Pipeline = .none,
    /// The same, laid over what is there by its alpha.
    over: rhi.Pipeline = .none,

    fn deinit(self: *Stage, device: *rhi.Device) void {
        if (!self.over.isNone()) device.destroyPipeline(self.over);
        if (!self.pipeline.isNone()) device.destroyPipeline(self.pipeline);
        if (!self.gpu.isNone()) device.destroyShader(self.gpu);
        if (self.module) |*held| held.deinit();
        self.* = .{};
    }
};

/// What the 3D layer is drawn into at one size and one count of samples.
pub const Targets = struct {
    width: u32,
    height: u32,
    samples: u32,
    /// The light, one sample a pixel: what the passes read.
    light: rhi.Texture,
    /// Drawn into with several samples, and averaged into `light`; none
    /// with one.
    multisampled: ?rhi.Texture,
    /// The depth the meshes are tested against, as many samples as the
    /// colour.
    depth: rhi.Texture,
    /// The toned picture, before it is smoothed, where it is.
    toned: ?rhi.Texture = null,
    /// The glow, each half the one before; none until glow is asked for.
    glow: [most_glow_levels]?rhi.Texture = @splat(null),
    /// What the geometry pass draws - which way each pixel's surface faces,
    /// how far and how smooth - and the depth it is tested against, one
    /// sample a pixel; the occlusion at half the size, and smoothed; the
    /// light with its reflections; the sun's rays at half the size. Made
    /// the first time they are asked for.
    geometry: ?rhi.Texture = null,
    geometry_depth: ?rhi.Texture = null,
    occlusion: [2]?rhi.Texture = .{ null, null },
    reflected: ?rhi.Texture = null,
    shafts: ?rhi.Texture = null,
    /// The light in the air, at half the size, and smoothed.
    rays: [2]?rhi.Texture = .{ null, null },
    glow_levels: u32 = 0,
    /// The frame it was last drawn with.
    used: u64,

    fn deinit(self: *Targets, device: *rhi.Device) void {
        device.destroyTexture(self.light);
        if (self.multisampled) |held| device.destroyTexture(held);
        device.destroyTexture(self.depth);
        if (self.toned) |held| device.destroyTexture(held);
        for (self.glow) |held| if (held) |texture| device.destroyTexture(texture);
        for ([_]?rhi.Texture{ self.geometry, self.geometry_depth, self.occlusion[0], self.occlusion[1], self.reflected, self.shafts, self.rays[0], self.rays[1] }) |held| {
            if (held) |texture| device.destroyTexture(texture);
        }
    }

    /// Half its size, a side, at least one.
    pub fn half(self: Targets) [2]u32 {
        return .{ @max(self.width / 2, 1), @max(self.height / 2, 1) };
    }

    /// What the meshes are drawn into: the samples, or the light itself.
    pub fn drawnInto(self: Targets) rhi.Texture {
        return self.multisampled orelse self.light;
    }
};

/// How the light becomes a picture, from an `Environment` or what is there
/// without one.
pub const Look = struct {
    tonemap: Environment.Tonemap = .linear,
    exposure: f32 = 1,
    white: f32 = 1,
    glow: bool = false,
    glow_threshold: f32 = 1,
    glow_intensity: f32 = 0.8,
    glow_spread: f32 = 1,
    /// Smooth the edges of the toned picture.
    smooth: bool = false,
    ssao: bool = false,
    ssao_radius: f32 = 0.6,
    ssao_intensity: f32 = 1,
    ssr: bool = false,
    ssr_intensity: f32 = 1,
    ssr_distance: f32 = 30,
    sun_shafts: bool = false,
    sun_shafts_intensity: f32 = 0.6,
    god_rays: bool = false,
    god_rays_density: f32 = 0.015,
    god_rays_intensity: f32 = 1,
    lens_flare: bool = false,
    lens_flare_intensity: f32 = 0.5,
    saturation: f32 = 1,
    contrast: f32 = 1,
    temperature: f32 = 0,
    vignette: f32 = 0,
    sharpen: f32 = 0,

    /// Whether anything it asks for reads the geometry pass.
    pub fn readsGeometry(self: Look) bool {
        return self.ssao or self.ssr or self.sun_shafts or self.god_rays or self.lens_flare;
    }

    /// How far from the camera the geometry pass draws: what occlusion is
    /// seen on, and what reflections are looked for as far as.
    pub fn geometryReach(self: Look) f32 {
        return if (self.ssr) @max(self.ssr_distance, 40) else 40;
    }

    /// The same, with nothing that reads the geometry pass: for a draw that
    /// drew none.
    pub fn withoutGeometry(self: Look) Look {
        var out = self;
        out.ssao = false;
        out.ssr = false;
        out.sun_shafts = false;
        out.god_rays = false;
        out.lens_flare = false;
        return out;
    }

    pub fn of(environment: ?Environment, smooth: bool) Look {
        const held = environment orelse return .{ .smooth = smooth };
        return .{
            .ssao = held.ssao and held.ssao_intensity > 0,
            .ssao_radius = std.math.clamp(held.ssao_radius, 0.05, 8),
            .ssao_intensity = held.ssao_intensity,
            .ssr = held.ssr and held.ssr_intensity > 0,
            .ssr_intensity = held.ssr_intensity,
            .ssr_distance = std.math.clamp(held.ssr_distance, 1, 500),
            .sun_shafts = held.sun_shafts and held.sun_shafts_intensity > 0,
            .sun_shafts_intensity = held.sun_shafts_intensity,
            .god_rays = held.god_rays and held.god_rays_intensity > 0 and held.god_rays_density > 0,
            .god_rays_density = std.math.clamp(held.god_rays_density, 0, 1),
            .god_rays_intensity = held.god_rays_intensity,
            .lens_flare = held.lens_flare and held.lens_flare_intensity > 0,
            .lens_flare_intensity = held.lens_flare_intensity,
            .saturation = @max(held.saturation, 0),
            .contrast = std.math.clamp(held.contrast, 0.1, 4),
            .temperature = std.math.clamp(held.temperature, -1, 1),
            .vignette = std.math.clamp(held.vignette, 0, 1),
            .sharpen = std.math.clamp(held.sharpen, 0, 4),
            .tonemap = held.tonemap,
            .exposure = held.exposure,
            .white = @max(held.white, 0.01),
            .glow = held.glow and held.glow_intensity > 0,
            .glow_threshold = held.glow_threshold,
            .glow_intensity = held.glow_intensity,
            .glow_spread = std.math.clamp(held.glow_spread, 0, 1),
            .smooth = smooth,
        };
    }
};

pub const Post3D = struct {
    device: *rhi.Device,
    /// What the light is kept in: half floats where the device draws into,
    /// filters and blends them, and a picture's bytes where it does not.
    light_format: rhi.Format,
    depth_format: rhi.Format,
    corners: rhi.Buffer,
    /// A black picture: no glow.
    black: rhi.Texture,
    sampler: rhi.Sampler,
    bright: Stage = .{},
    down: Stage = .{},
    up: Stage = .{},
    tone: Stage = .{},
    smooth: Stage = .{},
    occlusion: Stage = .{},
    occlusion_blur: Stage = .{},
    reflect: Stage = .{},
    shafts: Stage = .{},
    rays: Stage = .{},
    rays_blur: Stage = .{},
    /// What the geometry is read with: texel by texel.
    nearest: rhi.Sampler,
    /// The camera of the draw being finished, for the passes that read the
    /// geometry.
    camera: Camera = .{},
    targets: std.ArrayList(Targets) = .empty,
    /// This draw's passes, recorded into one list once their numbers are
    /// written.
    passes: std.ArrayList(Pass) = .empty,
    /// Every pass's numbers, in one buffer a pass binds a part of.
    blocks: UniformBlocks = .{ .label = "3D post" },
    clock: u64 = 0,

    pub fn init(gpa: Allocator, device: *rhi.Device, depth_format: rhi.Format) !Post3D {
        const caps = device.caps();
        const half = caps.formatSupport(.rgba16_float);
        const light_format: rhi.Format = if (half.render_target and half.sampled and half.filterable and half.blendable) .rgba16_float else .rgba8_unorm;
        if (light_format != .rgba16_float) log.info("the {t} backend draws into no half floats here: 3D light brighter than white is cut off", .{device.info().backend});
        const buffer = try device.createBuffer(.{ .kind = .vertex, .size = @sizeOf(@TypeOf(corners)), .data = std.mem.asBytes(&corners), .label = "3D post corners" });
        errdefer device.destroyBuffer(buffer);
        const black_texel = [4]u8{ 0, 0, 0, 255 };
        const black = try device.createTexture(.{ .width = 1, .height = 1, .data = &black_texel, .label = "no glow" });
        errdefer device.destroyTexture(black);
        var self: Post3D = .{
            .device = device,
            .light_format = light_format,
            .depth_format = depth_format,
            .corners = buffer,
            .black = black,
            .sampler = try device.createSampler(.{ .min_filter = .linear, .mag_filter = .linear, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge }),
            .nearest = try device.createSampler(.nearest),
        };
        errdefer self.deinit(gpa);
        try self.compile(gpa, &self.bright, bright_source, light_format, false, "3D glow, bright");
        try self.compile(gpa, &self.down, down_source, light_format, false, "3D glow, down");
        try self.compile(gpa, &self.up, up_source, light_format, true, "3D glow, up");
        try self.compile(gpa, &self.tone, tone_source, .rgba8_unorm, false, "3D tone");
        try self.compile(gpa, &self.smooth, smooth_source, .rgba8_unorm, false, "3D smoothing");
        try self.compile(gpa, &self.occlusion, occlusion_source, .rgba8_unorm, false, "3D occlusion");
        try self.compile(gpa, &self.occlusion_blur, occlusion_blur_source, .rgba8_unorm, false, "3D occlusion, smoothed");
        try self.compile(gpa, &self.reflect, reflect_source, light_format, false, "3D reflections");
        try self.compile(gpa, &self.shafts, shafts_source, light_format, false, "3D sun's rays");
        try self.compile(gpa, &self.rays, rays_source, light_format, false, "3D light in the air");
        try self.compile(gpa, &self.rays_blur, rays_blur_source, light_format, false, "3D light in the air, smoothed");
        return self;
    }

    pub fn deinit(self: *Post3D, gpa: Allocator) void {
        const device = self.device;
        for (self.targets.items) |*held| held.deinit(device);
        self.targets.deinit(gpa);
        self.blocks.deinit(gpa, device);
        self.passes.deinit(gpa);
        for ([_]*Stage{ &self.bright, &self.down, &self.up, &self.tone, &self.smooth, &self.occlusion, &self.occlusion_blur, &self.reflect, &self.shafts, &self.rays, &self.rays_blur }) |stage| stage.deinit(device);
        device.destroySampler(self.nearest);
        device.destroySampler(self.sampler);
        device.destroyTexture(self.black);
        device.destroyBuffer(self.corners);
    }

    /// A pass's shader, and its pipeline into `format`: adding what it
    /// draws to what is there with `adds`. The tone pass also gets one laid
    /// over what is there by its alpha.
    fn compile(self: *Post3D, gpa: Allocator, stage: *Stage, source: []const u8, format: rhi.Format, adds: bool, label: []const u8) !void {
        const device = self.device;
        var said: std.Io.Writer.Allocating = .init(gpa);
        defer said.deinit();
        stage.module = shader.compile(gpa, source, &said.writer) catch |err| {
            log.err("{s}: {s}", .{ label, said.written() });
            return err;
        };
        const module = &stage.module.?;
        std.debug.assert(module.block("Post").?.size == @sizeOf(Post));
        stage.gpu = try device.createShader(.{
            .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
            .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
            .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
            .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
            .label = label,
        });
        var desc: rhi.PipelineDesc = .{
            .shader = stage.gpu,
            .attributes = &.{.{ .location = 0, .format = .float2, .offset = 0 }},
            .buffers = &.{.{ .stride = @sizeOf([2]f32) }},
            .topology = .triangles,
            .blend = if (adds) .additive else .solid,
            .color_format = format,
            .uniform_blocks = (try module.uniformBlockNames()).?,
            .textures = (try module.textureNames()).?,
            .label = label,
        };
        stage.pipeline = try device.createPipeline(desc);
        if (stage == &self.tone or stage == &self.smooth) {
            desc.blend = .alpha;
            stage.over = try device.createPipeline(desc);
        }
    }

    /// The targets at a size and a count of samples, made the first time
    /// they are drawn at.
    pub fn targetsAt(self: *Post3D, gpa: Allocator, width: u32, height: u32, samples: u32) !*Targets {
        for (self.targets.items) |*held| {
            if (held.width == width and held.height == height and held.samples == samples) {
                held.used = self.clock;
                return held;
            }
        }
        const device = self.device;
        const light = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.light_format,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "3D light",
        });
        errdefer device.destroyTexture(light);
        const multisampled: ?rhi.Texture = if (samples > 1) try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.light_format,
            .samples = samples,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D light, multisampled",
        }) else null;
        errdefer if (multisampled) |held| device.destroyTexture(held);
        const depth = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = self.depth_format,
            .samples = samples,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D depth",
        });
        errdefer device.destroyTexture(depth);
        try self.targets.append(gpa, .{ .width = width, .height = height, .samples = samples, .light = light, .multisampled = multisampled, .depth = depth, .used = self.clock });
        return &self.targets.items[self.targets.items.len - 1];
    }

    /// Every target let go of, each made again by the next draw that asks
    /// for it - what a window resized does to them, in place: see
    /// `Renderer3D.remakeTargets`.
    pub fn forgetTargets(self: *Post3D) void {
        for (self.targets.items) |*held| held.deinit(self.device);
        self.targets.clearRetainingCapacity();
    }

    /// The most samples a pixel the device draws the light and the depth
    /// with, up to `wanted`.
    pub fn samplesFor(self: *const Post3D, wanted: u32) u32 {
        const caps = self.device.caps();
        var count = wanted;
        while (count > 1) : (count /= 2) {
            if (caps.formatSupport(self.light_format).supportsSamples(count) and caps.formatSupport(self.depth_format).supportsSamples(count)) return count;
        }
        return 1;
    }

    /// One more frame: targets no draw has used for a few are let go.
    pub fn tick(self: *Post3D) void {
        self.clock += 1;
        var at: usize = 0;
        while (at < self.targets.items.len) {
            if (self.targets.items[at].used + 3 < self.clock) {
                self.targets.items[at].deinit(self.device);
                _ = self.targets.swapRemove(at);
            } else at += 1;
        }
    }

    /// Turn the light in `targets` into a picture in `into`, `out_width` by
    /// `out_height` - larger or smaller than the targets where the 3D world
    /// is drawn at a scale of its own: glow, tone and smoothing as `look`
    /// says. Over what `into` holds by the light's alpha with `over`, or in
    /// place of it.
    pub fn finish(self: *Post3D, gpa: Allocator, targets: *Targets, into: rhi.RenderTarget, out_width: u32, out_height: u32, look: Look, over: bool) !void {
        const device = self.device;
        self.passes.clearRetainingCapacity();
        const flip = material.screenFlip(device);
        const width = targets.width;
        const height = targets.height;

        // The light with what smooth surfaces reflect, where asked for.
        var source = targets.light;
        if (look.ssr) if (targets.geometry) |geometry| {
            if (targets.reflected == null) targets.reflected = try device.createTexture(.{
                .width = width,
                .height = height,
                .format = self.light_format,
                .usage = .{ .sampled = true, .render_target = true },
                .label = "3D reflected",
            });
            try self.queueReading(gpa, self.reflect.pipeline, .{ .texture = targets.reflected.? }, width, height, .dont_care, &.{ targets.light, geometry }, 0b10, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
                .knobs = .{ look.ssr_distance, look.ssr_intensity, 0, 0 },
            });
            source = targets.reflected.?;
        };
        const glow: Glow = if (look.glow) try self.glowOf(gpa, targets, source, look, flip) else .{ .texture = self.black, .weight = 1 };
        // The sun's light in the air, its rays and its flare, at half the
        // size: one picture added in the tone pass.
        var shafts = self.black;
        const c = self.camera;
        const in_air = look.god_rays and c.shadows != null and c.shadow_depth != null;
        const at_sun = (look.sun_shafts or look.lens_flare) and c.sun_seen > 0;
        if (in_air or at_sun) if (targets.geometry) |geometry| {
            const size = targets.half();
            const half_texel: [4]f32 = .{ 1 / @as(f32, @floatFromInt(size[0])), 1 / @as(f32, @floatFromInt(size[1])), flip, 0 };
            for ([_]*?rhi.Texture{ &targets.shafts, &targets.rays[0], &targets.rays[1] }) |made| if (made.* == null) {
                made.* = try device.createTexture(.{
                    .width = size[0],
                    .height = size[1],
                    .format = self.light_format,
                    .usage = .{ .sampled = true, .render_target = true },
                    .label = "3D sun's light",
                });
            };
            var air = self.black;
            if (in_air) {
                try self.queueReading(gpa, self.rays.pipeline, .{ .texture = targets.rays[0].? }, size[0], size[1], .dont_care, &.{ geometry, geometry, c.shadow_depth.? }, 0b111, .{
                    .texel = half_texel,
                    .knobs = .{ look.god_rays_density, look.geometryReach() * 1.5, look.god_rays_intensity, 0 },
                    .more = .{ c.sun_color[0], c.sun_color[1], c.sun_color[2], 0 },
                    .grade = .{ c.sun_toward.x, c.sun_toward.y, c.sun_toward.z, 0 },
                });
                self.passes.items[self.passes.items.len - 1].second = c.shadows.?;
                try self.queueReading(gpa, self.rays_blur.pipeline, .{ .texture = targets.rays[1].? }, size[0], size[1], .dont_care, &.{ targets.rays[0].?, geometry }, 0b10, .{
                    .texel = half_texel,
                    .knobs = @splat(0),
                });
                air = targets.rays[1].?;
            }
            try self.queueReading(gpa, self.shafts.pipeline, .{ .texture = targets.shafts.? }, size[0], size[1], .dont_care, &.{ source, geometry, air }, 0b10, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
                .knobs = .{ c.sun_uv[0], c.sun_uv[1], if (look.sun_shafts) look.sun_shafts_intensity * c.sun_seen else 0, if (look.lens_flare) look.lens_flare_intensity * c.sun_seen else 0 },
                .more = .{ c.sun_light[0], c.sun_light[1], c.sun_light[2], 0 },
            });
            shafts = targets.shafts.?;
        };

        // Toned into the picture - or into a picture of its own first,
        // where it is smoothed after.
        const smoothing = look.smooth;
        if (smoothing and targets.toned == null) targets.toned = try device.createTexture(.{
            .width = width,
            .height = height,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "3D toned",
        });
        const tone_into: rhi.RenderTarget = if (smoothing) .{ .texture = targets.toned.? } else into;
        const tone_width = if (smoothing) width else out_width;
        const tone_height = if (smoothing) height else out_height;
        const curve: f32 = switch (look.tonemap) {
            .linear => 0,
            .reinhard => 1,
            .filmic => 2,
            .aces => 3,
        };
        try self.queue(gpa, if (over and !smoothing) self.tone.over else self.tone.pipeline, tone_into, tone_width, tone_height, if (over and !smoothing) .load else .dont_care, &.{ source, glow.texture, shafts }, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
            .knobs = .{ look.exposure, look.white, curve, if (look.glow) look.glow_intensity / glow.weight else 0 },
            .more = .{ look.saturation, look.contrast, look.vignette, look.sharpen },
            .grade = whiteOf(look.temperature),
        });
        if (smoothing) try self.queue(gpa, if (over) self.smooth.over else self.smooth.pipeline, into, out_width, out_height, if (over) .load else .dont_care, &.{targets.toned.?}, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(width)), 1 / @as(f32, @floatFromInt(height)), flip, 0 },
            .knobs = @splat(0),
        });
        try self.run(gpa);
    }

    /// The geometry pass's targets, at the targets' size, one sample a
    /// pixel: made the first time.
    pub fn geometryOf(self: *Post3D, targets: *Targets) !struct { color: rhi.Texture, depth: rhi.Texture } {
        const device = self.device;
        if (targets.geometry == null) targets.geometry = try device.createTexture(.{
            .width = targets.width,
            .height = targets.height,
            .format = .rgba16_float,
            .usage = .{ .sampled = true, .render_target = true },
            .label = "3D geometry",
        });
        if (targets.geometry_depth == null) targets.geometry_depth = try device.createTexture(.{
            .width = targets.width,
            .height = targets.height,
            .format = self.depth_format,
            .usage = .{ .sampled = false, .render_target = true },
            .label = "3D geometry depth",
        });
        return .{ .color = targets.geometry.?, .depth = targets.geometry_depth.? };
    }

    /// Whether the device draws the geometry pass: half floats it draws
    /// into and reads.
    pub fn drawsGeometry(self: *const Post3D) bool {
        const support = self.device.caps().formatSupport(.rgba16_float);
        return support.render_target and support.sampled;
    }

    /// How much light from everywhere reaches each pixel, from the geometry
    /// drawn into `targets`, at half the size and smoothed: what the 3D
    /// surfaces read as the screen's occlusion. Run at once.
    pub fn occlusionOf(self: *Post3D, gpa: Allocator, targets: *Targets, look: Look) !rhi.Texture {
        const device = self.device;
        const flip = material.screenFlip(device);
        const size = targets.half();
        for (&targets.occlusion) |*held| if (held.* == null) {
            held.* = try device.createTexture(.{
                .width = size[0],
                .height = size[1],
                .usage = .{ .sampled = true, .render_target = true },
                .label = "3D occlusion",
            });
        };
        const geometry = targets.geometry.?;
        self.passes.clearRetainingCapacity();
        try self.queueReading(gpa, self.occlusion.pipeline, .{ .texture = targets.occlusion[0].? }, size[0], size[1], .dont_care, &.{ geometry, geometry }, 0b11, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(size[0])), 1 / @as(f32, @floatFromInt(size[1])), flip, 0 },
            .knobs = .{ look.ssao_radius, look.ssao_intensity, 0, 0 },
        });
        try self.queueReading(gpa, self.occlusion_blur.pipeline, .{ .texture = targets.occlusion[1].? }, size[0], size[1], .dont_care, &.{ targets.occlusion[0].?, geometry }, 0b10, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(size[0])), 1 / @as(f32, @floatFromInt(size[1])), flip, 0 },
            .knobs = @splat(0),
        });
        try self.run(gpa);
        return targets.occlusion[1].?;
    }

    /// The glow, and what its levels add up to: what it is divided by.
    const Glow = struct { texture: rhi.Texture, weight: f32 };

    /// The glow of what is bright in `targets`: taken out at half the size,
    /// made smaller level by level, and added back up the way it came. The
    /// half-size level, which holds all of it, and how many times over.
    fn glowOf(self: *Post3D, gpa: Allocator, targets: *Targets, source: rhi.Texture, look: Look, flip: f32) !Glow {
        const device = self.device;
        if (targets.glow_levels == 0) {
            var w = @max(targets.width / 2, 1);
            var h = @max(targets.height / 2, 1);
            var level: u32 = 0;
            errdefer {
                for (targets.glow[0..level]) |*texture| {
                    if (texture.*) |made| device.destroyTexture(made);
                    texture.* = null;
                }
            }
            while (level < most_glow_levels and (level == 0 or (w >= 4 and h >= 4))) : (level += 1) {
                targets.glow[level] = try device.createTexture(.{
                    .width = w,
                    .height = h,
                    .format = self.light_format,
                    .usage = .{ .sampled = true, .render_target = true },
                    .label = "3D glow",
                });
                w = @max(w / 2, 1);
                h = @max(h / 2, 1);
            }
            targets.glow_levels = level;
        }
        const levels = targets.glow_levels;
        const sizeOf = struct {
            fn at(t: *const Targets, level: u32) [2]u32 {
                return .{ @max(t.width >> @intCast(level + 1), 1), @max(t.height >> @intCast(level + 1), 1) };
            }
        }.at;

        // What is bright, at half the size.
        const first = sizeOf(targets, 0);
        try self.queue(gpa, self.bright.pipeline, .{ .texture = targets.glow[0].? }, first[0], first[1], .dont_care, &.{source}, .{
            .texel = .{ 1 / @as(f32, @floatFromInt(targets.width)), 1 / @as(f32, @floatFromInt(targets.height)), flip, 0 },
            .knobs = .{ look.glow_threshold, look.exposure, 0, 0 },
        });
        // Down: each level half the one before.
        var level: u32 = 1;
        while (level < levels) : (level += 1) {
            const from = sizeOf(targets, level - 1);
            const size = sizeOf(targets, level);
            try self.queue(gpa, self.down.pipeline, .{ .texture = targets.glow[level].? }, size[0], size[1], .dont_care, &.{targets.glow[level - 1].?}, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(from[0])), 1 / @as(f32, @floatFromInt(from[1])), flip, 0 },
                .knobs = @splat(0),
            });
        }
        // Up: each level added to the one above it, spread a little; the
        // further down, the less with a small spread. A level counts as many
        // times as the weights on its way up multiply to.
        var weights: [most_glow_levels]f32 = @splat(1);
        for (1..levels) |at| {
            const reach: f32 = @as(f32, @floatFromInt(at)) / @as(f32, @floatFromInt(@max(levels - 1, 1)));
            weights[at] = if (look.glow_spread >= reach) 1 else look.glow_spread / @max(reach, 0.0001);
        }
        var total: f32 = 1;
        var carried: f32 = 1;
        for (1..levels) |at| {
            carried *= weights[at];
            total += carried;
        }
        level = levels;
        while (level > 1) {
            level -= 1;
            const from = sizeOf(targets, level);
            const size = sizeOf(targets, level - 1);
            try self.queue(gpa, self.up.pipeline, .{ .texture = targets.glow[level - 1].? }, size[0], size[1], .load, &.{targets.glow[level].?}, .{
                .texel = .{ 1 / @as(f32, @floatFromInt(from[0])), 1 / @as(f32, @floatFromInt(from[1])), flip, 0 },
                .knobs = .{ 1, weights[level], 0, 0 },
            });
        }
        return .{ .texture = targets.glow[0].?, .weight = total };
    }

    /// One pass over the whole of `into`, reading `sources`: kept for `run`.
    fn queue(self: *Post3D, gpa: Allocator, pipeline: rhi.Pipeline, into: rhi.RenderTarget, width: u32, height: u32, load: rhi.LoadOp, sources: []const rhi.Texture, knobs: Post) !void {
        return self.queueReading(gpa, pipeline, into, width, height, load, sources, 0, knobs);
    }

    /// `queue`, the sources whose bits are set in `nearest` read texel by
    /// texel; with the camera told.
    fn queueReading(self: *Post3D, gpa: Allocator, pipeline: rhi.Pipeline, into: rhi.RenderTarget, width: u32, height: u32, load: rhi.LoadOp, sources: []const rhi.Texture, nearest: u8, given: Post) !void {
        var knobs = given;
        const c = self.camera;
        knobs.view_projection = c.view_projection;
        knobs.eye = .{ c.eye.x, c.eye.y, c.eye.z, 0 };
        knobs.forward = .{ c.forward.x, c.forward.y, c.forward.z, 0 };
        knobs.right = .{ c.right.x, c.right.y, c.right.z, 0 };
        knobs.up = .{ c.up.x, c.up.y, c.up.z, 0 };
        var held: Pass = .{ .pipeline = pipeline, .into = into, .width = width, .height = height, .load = load, .sources = undefined, .source_count = @intCast(sources.len), .nearest = nearest, .knobs = knobs };
        @memcpy(held.sources[0..sources.len], sources);
        try self.passes.append(gpa, held);
    }

    /// Every pass queued: their numbers into the buffer at once, each where
    /// the device binds a block from, and the passes one list.
    fn run(self: *Post3D, gpa: Allocator) !void {
        const device = self.device;
        const passes = self.passes.items;
        if (passes.len == 0) return;
        self.blocks.clear();
        for (passes) |*held| held.at = try self.blocks.place(gpa, device, std.mem.asBytes(&held.knobs));
        try self.blocks.upload(device);
        const buffer = self.blocks.buffer.?;
        const list = device.begin();
        for (passes) |held| {
            try list.beginPass(.{ .color = .{ .target = held.into, .load = held.load, .clear_color = .{ 0, 0, 0, 0 } } });
            try list.setViewport(.{ .width = @floatFromInt(held.width), .height = @floatFromInt(held.height) });
            try list.setPipeline(held.pipeline);
            try list.setUniformBufferRange(0, buffer, held.at, @sizeOf(Post));
            if (held.second) |second| try list.setUniformBuffer(1, second);
            for (held.sources[0..held.source_count], 0..) |source, slot| {
                const texel_by_texel = held.nearest & (@as(u8, 1) << @intCast(slot)) != 0;
                try list.setTexture(@intCast(slot), source, if (texel_by_texel) self.nearest else self.sampler);
            }
            try list.setVertexBuffer(0, self.corners, 0);
            try list.draw(.{ .vertex_count = 3 });
            try list.endPass();
        }
        try device.submit();
    }
};

/// The colour white is graded to at `temperature`, from cool at minus one
/// to warm at one, as bright as white.
fn whiteOf(temperature: f32) [4]f32 {
    const t = std.math.clamp(temperature, -1, 1);
    const r = 1 + 0.16 * t;
    const g = 1 + 0.02 * t;
    const b = 1 - 0.16 * t;
    const bright = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return .{ r / bright, g / bright, b / bright, 0 };
}

test "every pass's shader compiles for every backend, and its numbers are laid out as the engine writes them" {
    for ([_][]const u8{ bright_source, down_source, up_source, tone_source, smooth_source, occlusion_source, occlusion_blur_source, reflect_source, shafts_source, rays_source, rays_blur_source }) |source| {
        var said: std.Io.Writer.Allocating = .init(testing.allocator);
        defer said.deinit();
        var module = shader.compile(testing.allocator, source, &said.writer) catch |err| {
            std.debug.print("{s}\n", .{said.written()});
            return err;
        };
        defer module.deinit();
        try testing.expectEqual(@as(u32, @sizeOf(Post)), module.block("Post").?.size);
    }
}

test "a look is what an environment says, or light as it is without one" {
    const plain: Look = .of(null, false);
    try testing.expectEqual(Environment.Tonemap.linear, plain.tonemap);
    try testing.expect(!plain.glow);
    const glowing: Look = .of(.{ .glow = true, .tonemap = .aces, .exposure = 2 }, true);
    try testing.expect(glowing.glow and glowing.smooth);
    try testing.expectEqual(@as(f32, 2), glowing.exposure);
    // No glow added where there is none to add.
    try testing.expect(!Look.of(.{ .glow = true, .glow_intensity = 0 }, false).glow);
}

test "tone and smoothing can both be laid over an existing picture" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var post = try Post3D.init(testing.allocator, &device, .depth32_float);
    defer post.deinit(testing.allocator);
    try testing.expect(!post.tone.over.isNone());
    try testing.expect(!post.smooth.over.isNone());
}
