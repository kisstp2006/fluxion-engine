// SPDX-License-Identifier: BSD-3-Clause

//! A sky worked out as it is drawn: the air lit by the sun, the sun's disc,
//! and clouds of volume. See `Sky3D`.
//!
//! The air is the scattering of Preetham and Hoffman: how much of the
//! sun's light the air between the eye and the end of the sky turns toward
//! the eye - blue overhead, where the way through the air is short, white
//! toward the horizon, where it is long, red where the sun's own light has
//! come a long way through it. It costs a few dozen instructions a pixel,
//! and the same sum on the CPU gives the light from everywhere it sheds.
//!
//! The clouds are a layer between two heights. Where they are, and how
//! thick, is a coverage picture over the ground; their volume, a noise in
//! three dimensions that eats their edges away; their light, the sun's,
//! through what stands between it and each point - with more of it let
//! through than a single scattering would, as light scattered many times
//! is - and the sky's from above. A ray from the eye is marched through
//! the layer, and stops once nothing more is seen through it.
//!
//! The shader language reads flat pictures alone, and the noise in three
//! dimensions is read from one: a picture of random values in its red, and
//! in its green the same moved by (37, 239) - the next layer of a volume -
//! so one read and a mix is a value noise in three dimensions. Its blue
//! is the coverage, a sum of noises that tiles, made even so that a
//! coverage of a half covers half the sky.
//!
//! What it costs is held down three ways. The sky and its clouds are
//! worked out into a picture smaller than the frame - a half or a third of
//! it a side - before the frame's pass, at a few dozen steps a ray; the
//! frame then reads it, bilinearly, where nothing was drawn: behind the
//! surfaces, the depth test leaves it out. The sun's disc is added there,
//! sharp. And the clouds' shadow on the world below is one read of the
//! coverage a pixel, where the sun's way meets the middle of the layer.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const Color = @import("../math/color.zig").Color;
const Sky3D = @import("render3d_components.zig").Sky3D;
const View3D = @import("view3d.zig").View3D;
const fog_backdrop = @import("fog_backdrop.zig");
const material = @import("material.zig");

const log = std.log.scoped(.fluxion_engine);
const Vec3 = math.Vec3;

/// The noise picture, a side, in texels.
pub const noise_size = 256;
/// How far the next layer of the volume noise is moved in its picture.
const layer_step = [2]u32{ 37, 239 };
/// How many cells of the coverage's coarsest noise the picture holds, a
/// side: a cloud's size times this is how far before the coverage repeats.
const coverage_cells = 8;
/// The optical depth a metre of the thickest cloud has, at a density of one.
const extinction = 0.012;

/// The scattering of the air, per metre at sea level, red, green and blue;
/// and of the haze, at a haze of one.
const rayleigh = [3]f32{ 5.8e-6, 13.5e-6, 33.1e-6 };
const mie = 21e-6;
/// How high the air, and the haze, thin by e.
const rayleigh_height = 8000;
const mie_height = 1200;
/// How bright the air is against the sun's light, at an energy of one.
const air_brightness = 8;
/// How much the haze throws forward: its phase's g.
const mie_g = 0.76;

/// The functions both the sky and the 3D surfaces read the clouds with:
/// where they are, and how much of the sun they let through. They read
/// `SKY_NOISE`, `CLOUDS` and `CLOUD_SHAPE`, which each declares as its own.
pub const cloud_part =
    \\// How much cloud is over `q`, a place on the ground in metres: nought
    \\// none, one the thickest.
    \\float cloudCover(vec2 q) {
    \\    vec2 uv = (q + CLOUD_SHAPE.yz) * CLOUD_SHAPE.x;
    \\    float c = sample_level(SKY_NOISE, uv, 0.0).b;
    \\    float threshold = 1.0 - CLOUDS.x;
    \\    return clamp((c - threshold) / 0.32, 0.0, 1.0);
    \\}
    \\
    \\// How much of a sun's light, coming from `l`, the clouds let through to
    \\// `p`: their coverage where its way crosses the middle of their layer.
    \\float cloudShadow(vec3 p, vec3 l) {
    \\    if (CLOUD_SHAPE.w <= 0.0 || l.y <= 0.01 || p.y >= CLOUDS.z) {
    \\        return 1.0;
    \\    }
    \\    float middle = (CLOUDS.z + CLOUDS.w) * 0.5;
    \\    float c = cloudCover(p.xz + l.xz * ((middle - p.y) / l.y));
    \\    float depth = c * c * CLOUDS.y * (CLOUDS.w - CLOUDS.z) * 0.2;
    \\    return mix(1.0, exp(-depth), CLOUD_SHAPE.w);
    \\}
    \\
;

const sky_head =
    \\attribute vec3 POSITION : 0;
    \\
    \\varying vec3 WORLD_POSITION;
    \\varying vec4 CLIP;
    \\
    \\uniform Sky : 0 {
    \\    mat4 SKY_VIEW_PROJECTION;
    \\    // Where the view is seen from, and one in `w` for an orthographic one.
    \\    vec4 SKY_FROM;
    \\    vec4 SKY_FORWARD;
    \\    // Where the clouds are seen from, in the world's metres.
    \\    vec4 SKY_EYE;
    \\    // Toward the sun, and in `w` the cosine of half its disc.
    \\    vec4 SKY_SUN;
    \\    // The sun's light where it reaches the clouds, and in `w` how bright
    \\    // its disc is against it.
    \\    vec4 SKY_SUN_COLOR;
    \\    // The air's optical depth straight up, red, green and blue, and the
    \\    // haze's in `w`.
    \\    vec4 SKY_AIR;
    \\    // How bright the air is, and how much the haze throws forward.
    \\    vec4 SKY_LOOK;
    \\    // The ground under the horizon, lit.
    \\    vec4 SKY_GROUND;
    \\    // The sky's light on the clouds from above.
    \\    vec4 SKY_AMBIENT;
    \\    vec4 CLOUDS;
    \\    vec4 CLOUD_SHAPE;
    \\    // Steps along a ray, steps toward the sun, how far clouds are seen.
    \\    vec4 CLOUD_MARCH;
    \\    // The picture's width and height, and which way up it is read.
    \\    vec4 SKY_TARGET;
    \\    // What lights the clouds now - the sun by day, the moon by night -
    \\    // and its light.
    \\    vec4 SKY_LIGHT;
    \\    vec4 SKY_LIGHT_COLOR;
    \\    // Toward the moon, and the cosine of half its disc; its disc's light.
    \\    vec4 SKY_MOON;
    \\    vec4 SKY_MOON_COLOR;
    \\    // The night sky's own glow, and in `w` how bright the stars are.
    \\    vec4 SKY_NIGHT;
    \\}
    \\
    \\vertex {
    \\    WORLD_POSITION = POSITION;
    \\    vec4 at = SKY_VIEW_PROJECTION * vec4(POSITION, 1.0);
    \\    CLIP = at;
    \\    // At the far end: behind everything drawn.
    \\    position = vec4(at.xy, at.w, at.w);
    \\}
    \\
    \\// The way from the eye through the pixel.
    \\vec3 rayOf(vec3 world) {
    \\    return normalize(mix(world - SKY_FROM.xyz, SKY_FORWARD.xyz, SKY_FROM.w));
    \\}
    \\
;

/// The sky and its clouds, into the smaller picture.
const picture_source = sky_head ++
    \\texture2d SKY_NOISE : 0;
    \\
++ cloud_part ++
    \\
    \\// How much air a ray at `up` toward the zenith goes through, against
    \\// straight up: Kasten and Young's.
    \\float airMass(float up) {
    \\    float a = acos(clamp(up, 0.0, 1.0)) * 57.2957795;
    \\    return 1.0 / (max(up, 0.0) + 0.15 * pow(max(93.885 - a, 0.001), -1.253));
    \\}
    \\
    \\// The air's light from `d`.
    \\vec3 air(vec3 d) {
    \\    vec3 s = SKY_SUN.xyz;
    \\    vec3 tau = SKY_AIR.rgb + vec3(SKY_AIR.w);
    \\    vec3 through = exp(-tau * airMass(d.y));
    \\    float mu = dot(d, s);
    \\    float g = SKY_LOOK.y;
    \\    float rayleigh = 0.0596831 * (1.0 + mu * mu);
    \\    float haze = 0.1193662 * (1.0 - g * g) * (1.0 + mu * mu) / ((2.0 + g * g) * pow(max(1.0 + g * g - 2.0 * g * mu, 0.0001), 1.5));
    \\    vec3 scattered = (SKY_AIR.rgb * rayleigh + vec3(SKY_AIR.w * haze)) / tau;
    \\    // At night the sky keeps a glow of its own, more of it low down.
    \\    vec3 glow = SKY_NIGHT.rgb * (1.0 - 0.5 * max(d.y, 0.0));
    \\    return scattered * (vec3(1.0) - through) * SKY_SUN_COLOR.rgb * SKY_LOOK.x + glow;
    \\}
    \\
    \\// The sky's light from `d`: the air's, and under the horizon the ground's.
    \\vec3 sky(vec3 d) {
    \\    if (d.y >= 0.0) {
    \\        return air(d);
    \\    }
    \\    vec3 level = air(normalize(vec3(d.x, 0.0, d.z) + vec3(0.0, 0.0001, 0.0)));
    \\    return mix(level, SKY_GROUND.rgb, smoothstep(0.0, 0.08, -d.y));
    \\}
    \\
    \\// A value noise in three dimensions, from the picture: one read.
    \\float cloudNoise(vec3 x) {
    \\    vec3 p = floor(x);
    \\    vec3 f = fract(x);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    vec2 uv = p.xy + vec2(37.0, 239.0) * p.z + f.xy;
    \\    vec2 rg = sample_level(SKY_NOISE, (uv + vec2(0.5)) / 256.0, 0.0).rg;
    \\    return mix(rg.x, rg.y, f.z);
    \\}
    \\
    \\// How thick the cloud is at `pos`, where the coverage is `cover`, with
    \\// `octaves` of its noise: nought to one.
    \\float cloudDensity(vec3 pos, float cover, int octaves) {
    \\    float h = clamp((pos.y - CLOUDS.z) / max(CLOUDS.w - CLOUDS.z, 1.0), 0.0, 1.0);
    \\    // Flat underneath, rounded over, and the thicker the coverage the
    \\    // higher it towers: its sides lean in as it rises.
    \\    float top = mix(0.3, 1.0, cover);
    \\    float shape = sqrt(cover) * smoothstep(0.0, 0.1, h) * smoothstep(top, top * 0.45, h);
    \\    if (shape <= 0.0) {
    \\        return 0.0;
    \\    }
    \\    vec3 x = (pos + vec3(CLOUD_SHAPE.y, 0.0, CLOUD_SHAPE.z) * 1.3) * (CLOUD_SHAPE.x * 40.0);
    \\    // The finer noises left out are taken at their mean.
    \\    float n = cloudNoise(x) * 0.62;
    \\    if (octaves > 1) {
    \\        n = n + cloudNoise(x * 2.63 + vec3(0.37)) * 0.26;
    \\    } else {
    \\        n = n + 0.13;
    \\    }
    \\    if (octaves > 2) {
    \\        n = n + cloudNoise(x * 6.11 + vec3(0.71)) * 0.12;
    \\    } else {
    \\        n = n + 0.06;
    \\    }
    \\    float eaten = (1.0 - n) * 0.75;
    \\    return clamp((shape - eaten) / max(1.0 - eaten, 0.05), 0.0, 1.0);
    \\}
    \\
    \\// How much of the sun's light reaches `pos` through the cloud between.
    \\float toSun(vec3 pos, vec3 s, int steps) {
    \\    float way = min((CLOUDS.w - pos.y) / max(s.y, 0.15), 3000.0);
    \\    float depth = 0.0;
    \\    float along = 0.0;
    \\    float stride = way / float(steps);
    \\    for (int i = 0; i < steps; i = i + 1) {
    \\        float at = along + stride * 0.5;
    \\        vec3 q = pos + s * at;
    \\        float cover = cloudCover(q.xz);
    \\        if (cover > 0.0) {
    \\            depth = depth + cloudDensity(q, cover, 1) * stride;
    \\        }
    \\        along = along + stride;
    \\        stride = stride * 1.3;
    \\    }
    \\    depth = depth * CLOUDS.y;
    \\    // Light scattered many times gets further in than once: a part of it
    \\    // falls off far slower.
    \\    return exp(-depth) * 0.7 + exp(-depth * 0.18) * 0.3;
    \\}
    \\
    \\float phaseOf(float mu, float g) {
    \\    float gg = g * g;
    \\    return (1.0 - gg) / pow(max(1.0 + gg - 2.0 * g * mu, 0.0001), 1.5);
    \\}
    \\
    \\// The clouds along `d` from `eye`: the light they give the eye, and in
    \\// `a` how much of what is behind them is seen through.
    \\vec4 clouds(vec3 eye, vec3 d, float jitter) {
    \\    vec4 none = vec4(0.0, 0.0, 0.0, 1.0);
    \\    if (CLOUDS.x <= 0.0 || CLOUD_MARCH.x < 1.0) {
    \\        return none;
    \\    }
    \\    float bottom = CLOUDS.z;
    \\    float top = CLOUDS.w;
    \\    float t0 = 0.0;
    \\    float t1 = CLOUD_MARCH.z;
    \\    if (eye.y < bottom) {
    \\        if (d.y <= 0.0) {
    \\            return none;
    \\        }
    \\        t0 = (bottom - eye.y) / d.y;
    \\        t1 = (top - eye.y) / d.y;
    \\    } else {
    \\        if (eye.y > top) {
    \\            if (d.y >= 0.0) {
    \\                return none;
    \\            }
    \\            t0 = (top - eye.y) / d.y;
    \\            t1 = (bottom - eye.y) / d.y;
    \\        } else {
    \\            if (d.y > 0.0) {
    \\                t1 = (top - eye.y) / d.y;
    \\            }
    \\            if (d.y < 0.0) {
    \\                t1 = (bottom - eye.y) / d.y;
    \\            }
    \\        }
    \\    }
    \\    t1 = min(t1, CLOUD_MARCH.z);
    \\    if (t0 >= t1) {
    \\        return none;
    \\    }
    \\    int steps = int(CLOUD_MARCH.x + 0.5);
    \\    int light_steps = int(CLOUD_MARCH.y + 0.5);
    \\    float dt = (t1 - t0) / float(steps);
    \\    float t = t0 + dt * jitter;
    \\    vec3 s = SKY_LIGHT.xyz;
    \\    float mu = dot(d, s);
    \\    // Bright round the sun, a silver lining; a little thrown back.
    \\    float phase = mix(phaseOf(mu, 0.75), phaseOf(mu, -0.25), 0.35) * 0.0795775;
    \\    vec3 sun_light = SKY_LIGHT_COLOR.rgb * phase * 6.0;
    \\    float seen = 1.0;
    \\    vec3 light = vec3(0.0);
    \\    float sigma_scale = CLOUDS.y;
    \\    for (int i = 0; i < steps; i = i + 1) {
    \\        if (seen > 0.015) {
    \\            vec3 pos = eye + d * t;
    \\            float cover = cloudCover(pos.xz);
    \\            if (cover > 0.0) {
    \\                float dens = cloudDensity(pos, cover, 3);
    \\                if (dens > 0.0) {
    \\                    float sigma = dens * sigma_scale;
    \\                    float h = clamp((pos.y - bottom) / max(top - bottom, 1.0), 0.0, 1.0);
    \\                    vec3 lit = sun_light * toSun(pos, s, light_steps) + SKY_AMBIENT.rgb * mix(0.35, 1.0, h);
    \\                    float kept = exp(-sigma * dt);
    \\                    light = light + seen * lit * (1.0 - kept);
    \\                    seen = seen * kept;
    \\                }
    \\            }
    \\        }
    \\        t = t + dt;
    \\    }
    \\    // Far off, the clouds go into the haze.
    \\    float fade = exp(-t0 / (CLOUD_MARCH.z * 0.3));
    \\    return vec4(light * fade, mix(1.0, seen, fade));
    \\}
    \\
    \\fragment {
    \\    vec3 d = rayOf(WORLD_POSITION);
    \\    vec3 behind = sky(d);
    \\    // Each pixel starts its steps a little further on than its
    \\    // neighbours, so no step shows as a band.
    \\    vec2 pixel = floor((CLIP.xy / CLIP.w * 0.5 + vec2(0.5)) * SKY_TARGET.xy);
    \\    float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
    \\    vec4 c = clouds(SKY_EYE.xyz, d, jitter);
    \\    target = vec4(behind * c.a + c.rgb, c.a);
    \\}
;

/// The picture read over the frame where nothing was drawn, and the sun's
/// disc on it, where the clouds let it be seen.
const over_source = sky_head ++
    \\texture2d SKY_PICTURE : 0;
    \\texture2d SKY_NOISE : 1;
    \\
    \\vec3 hash3(vec3 p) {
    \\    vec3 q = fract(p * vec3(0.1031, 0.1030, 0.0973));
    \\    q = q + vec3(dot(q, q.yxz + vec3(33.33)));
    \\    return fract((q.xxy + q.yxx) * q.zyx);
    \\}
    \\
    \\// The stars toward `d`, where a pixel spans `pixel` of their grid: one
    \\// in a few of its cells holds one, a point a pixel or two across
    \\// whatever the view's width, a few bright and most faint, bluer or
    \\// redder, each flickering in its own time.
    \\vec3 starsOf(vec3 d, float pixel) {
    \\    vec3 q = d * 160.0;
    \\    vec3 cell = floor(q);
    \\    vec3 h = hash3(cell);
    \\    if (h.x < 0.78) {
    \\        return vec3(0.0);
    \\    }
    \\    vec3 at = cell + vec3(0.3) + h.yzx * 0.4;
    \\    float size = max(pixel * 0.9, 0.03);
    \\    float spot = clamp(1.0 - length(q - at) / size, 0.0, 1.0);
    \\    float strength = pow((h.x - 0.78) / 0.22, 4.0) * 10.0 + 0.5;
    \\    float flicker = 0.75 + 0.25 * sin(SKY_EYE.w * (1.5 + h.y * 4.0) + h.z * 40.0);
    \\    vec3 tint = mix(vec3(0.7, 0.8, 1.0), vec3(1.0, 0.85, 0.7), h.z);
    \\    return tint * (spot * spot * strength * flicker * min(0.03 / size, 1.0));
    \\}
    \\
    \\// The band of the galaxy: faint, and clumped.
    \\vec3 galaxyOf(vec3 d) {
    \\    float across = dot(d, normalize(vec3(0.35, 0.55, 0.75)));
    \\    float band = exp(-across * across * 22.0);
    \\    vec2 at = d.xz / (1.0 + abs(d.y)) * 1.7;
    \\    float clumps = sample_level(SKY_NOISE, at, 0.0).b;
    \\    return vec3(0.55, 0.6, 0.8) * (band * clumps * clumps * 0.035);
    \\}
    \\
    \\fragment {
    \\    vec3 d = rayOf(WORLD_POSITION);
    \\    float pixel = (length(ddx(d)) + length(ddy(d))) * 0.5 * 160.0;
    \\    vec2 ndc = CLIP.xy / CLIP.w;
    \\    vec2 uv = vec2(ndc.x * 0.5 + 0.5, ndc.y * 0.5 * SKY_TARGET.z + 0.5);
    \\    // Four reads round the pixel: the smaller picture's steps smoothed
    \\    // as it is spread over the frame.
    \\    vec2 texel = vec2(0.5) / SKY_TARGET.xy;
    \\    vec4 back = (sample_level(SKY_PICTURE, uv + vec2(-texel.x, -texel.y), 0.0) + sample_level(SKY_PICTURE, uv + vec2(texel.x, -texel.y), 0.0)
    \\        + sample_level(SKY_PICTURE, uv + vec2(-texel.x, texel.y), 0.0) + sample_level(SKY_PICTURE, uv + vec2(texel.x, texel.y), 0.0)) * 0.25;
    \\    float mu = dot(d, SKY_SUN.xyz);
    \\    float edge = 1.0 - SKY_SUN.w;
    \\    // The disc, darker toward its rim, and a glow just round it.
    \\    float disc = smoothstep(SKY_SUN.w - edge * 0.08, SKY_SUN.w + edge * 0.08, mu);
    \\    float rim = clamp((mu - SKY_SUN.w) / max(edge, 0.000001), 0.0, 1.0);
    \\    float limb = 0.6 + 0.4 * sqrt(rim);
    \\    float above = smoothstep(-0.01, 0.01, d.y);
    \\    vec3 sun = SKY_SUN_COLOR.rgb * (SKY_SUN_COLOR.w * disc * limb * above);
    \\    // The moon: its disc, with its darker seas.
    \\    float moon_mu = dot(d, SKY_MOON.xyz);
    \\    float moon_edge = 1.0 - SKY_MOON.w;
    \\    float moon_disc = smoothstep(SKY_MOON.w - moon_edge * 0.1, SKY_MOON.w + moon_edge * 0.1, moon_mu);
    \\    vec3 off = (d - SKY_MOON.xyz * moon_mu) / sqrt(max(moon_edge * 2.0, 0.0000001));
    \\    float seas = sample_level(SKY_NOISE, off.xz * 0.35 + vec2(0.5, 0.5) + off.yy * 0.2, 0.0).b;
    \\    vec3 moon = SKY_MOON_COLOR.rgb * (moon_disc * (0.7 + 0.3 * seas) * above);
    \\    // The stars and the galaxy, under the moon, dimmed through the air low down.
    \\    float clear = smoothstep(0.0, 0.2, d.y) * (1.0 - moon_disc);
    \\    vec3 night = (starsOf(d, pixel) + galaxyOf(d)) * (SKY_NIGHT.w * clear);
    \\    target = vec4(back.rgb + (sun + moon + night) * back.a, 1.0);
    \\}
;

/// What the sky's shaders are told, as their `Sky` block says.
pub const Block = extern struct {
    view_projection: math.Mat4,
    from: [4]f32,
    forward: [4]f32,
    eye: [4]f32,
    sun: [4]f32,
    sun_color: [4]f32,
    air: [4]f32,
    look: [4]f32,
    ground: [4]f32,
    ambient: [4]f32,
    clouds: [4]f32,
    cloud_shape: [4]f32,
    cloud_march: [4]f32,
    target: [4]f32,
    light: [4]f32,
    light_color: [4]f32,
    moon: [4]f32,
    moon_color: [4]f32,
    night: [4]f32,
};

/// A sky, and the sun it is lit by: toward it, and its light, linear.
pub const Lit = struct {
    sky: Sky3D,
    toward: Vec3,
    light: [3]f32,
};

/// How finely each `Sky3D.CloudQuality` is worked out: the picture's side
/// against the frame's, steps along a ray and toward the sun.
const Quality = struct { scale: f32, steps: f32, light_steps: f32 };

fn qualityOf(q: Sky3D.CloudQuality) Quality {
    return switch (q) {
        .low => .{ .scale = 1.0 / 3.0, .steps = 24, .light_steps = 3 },
        .medium => .{ .scale = 0.5, .steps = 40, .light_steps = 4 },
        .high => .{ .scale = 0.5, .steps = 64, .light_steps = 6 },
    };
}

// --- The sums on the CPU ---------------------------------------------------

fn airDepth(sky: Sky3D) [4]f32 {
    const r = @max(sky.rayleigh, 0);
    const h = @max(sky.haze, 0);
    return .{ rayleigh[0] * rayleigh_height * r, rayleigh[1] * rayleigh_height * r, rayleigh[2] * rayleigh_height * r, mie * mie_height * h };
}

fn airMass(up: f32) f32 {
    const a = std.math.acos(std.math.clamp(up, 0, 1)) * (180.0 / std.math.pi);
    return 1.0 / (@max(up, 0) + 0.15 * std.math.pow(f32, @max(93.885 - a, 0.001), -1.253));
}

/// How much of the sun's light comes through the air to the ground, red,
/// green and blue, with it `toward` - against how much does at noon.
pub fn sunThrough(sky: Sky3D, toward: Vec3) [3]f32 {
    const depth = airDepth(sky);
    const m = airMass(toward.y);
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const tau = depth[i] + depth[3];
        out[i] = @exp(-tau * m) / @exp(-tau);
    }
    return out;
}

/// The air's light from `d`, with the sun `toward` and its light `light`:
/// the shader's `air`, on the CPU.
pub fn airLight(sky: Sky3D, d: Vec3, toward: Vec3, light: [3]f32) [3]f32 {
    const depth = airDepth(sky);
    const mu = d.dot(toward);
    const g: f32 = mie_g;
    const ray_phase = 0.0596831 * (1 + mu * mu);
    const haze_phase = 0.1193662 * (1 - g * g) * (1 + mu * mu) / ((2 + g * g) * std.math.pow(f32, @max(1 + g * g - 2 * g * mu, 0.0001), 1.5));
    const m = airMass(d.y);
    const bright = air_brightness * @max(sky.energy, 0);
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const tau = depth[i] + depth[3];
        const through = @exp(-tau * m);
        const scattered = (depth[i] * ray_phase + depth[3] * haze_phase) / @max(tau, 1e-9);
        out[i] = scattered * (1 - through) * light[i] * bright;
    }
    return out;
}

/// The light from everywhere the sky sheds on the ground: its light
/// averaged over the half above, as a surface facing up takes it, made
/// greyer the more cloud covers it - and by night its own glow and the
/// moon's light it scatters.
pub fn ambientOf(lit: Lit) [3]f32 {
    const now = nowOf(lit);
    var out = dayAmbient(.{ .sky = lit.sky, .toward = lit.toward, .light = twilight(lit) });
    const glow = nightGlow(lit.sky);
    for (0..3) |i| out[i] += (glow[i] + now.moon_light[i] * 0.15) * @max(lit.sky.ambient_energy, 0);
    return out;
}

/// The air's part of `ambientOf`, under a sun whose light, as it reaches
/// the ground, is `lit.light`.
fn dayAmbient(lit: Lit) [3]f32 {
    var sum: [3]f32 = @splat(0);
    var weight: f32 = 0;
    const rings = [_]f32{ 0.08, 0.35, 0.7, 0.97 };
    for (rings) |up| {
        const across = @sqrt(1 - up * up);
        for (0..8) |k| {
            const a = @as(f32, @floatFromInt(k)) * (std.math.pi / 4.0);
            const d: Vec3 = .init(@cos(a) * across, up, @sin(a) * across);
            const c = airLight(lit.sky, d, lit.toward, lit.light);
            // As a surface facing up takes it: by how high it comes from.
            for (0..3) |i| sum[i] += c[i] * up;
            weight += up;
        }
    }
    var out: [3]f32 = undefined;
    for (0..3) |i| out[i] = sum[i] / weight;
    if (lit.sky.clouds) {
        const grey = (out[0] + out[1] + out[2]) / 3;
        const cover = std.math.clamp(lit.sky.cloud_coverage, 0, 1) * 0.6;
        for (&out) |*c| c.* = std.math.lerp(c.*, grey, cover);
    }
    for (&out) |*c| c.* *= @max(lit.sky.ambient_energy, 0);
    return out;
}

/// The clouds as the 3D surfaces' frame says them: their coverage,
/// thickness and heights, and their size, where the wind has taken them
/// after `seconds`, and how dark their shadow is.
pub fn cloudsOf(sky: Sky3D, seconds: f64) struct { clouds: [4]f32, shape: [4]f32 } {
    if (!sky.clouds) return .{ .clouds = @splat(0), .shape = @splat(0) };
    const bottom = sky.cloud_bottom;
    const top = @max(sky.cloud_top, bottom + 1);
    const size = @max(sky.cloud_size, 1);
    const tile: f64 = @as(f64, size) * coverage_cells;
    // The wind's way, kept within a turn of the coverage so it never loses
    // precision however long the game runs: the coverage repeats there.
    const travelled = @as(f64, @max(sky.wind_speed, 0)) * seconds;
    const x = @mod(@cos(@as(f64, sky.wind_direction)) * travelled, tile * 64);
    const z = @mod(@sin(@as(f64, sky.wind_direction)) * travelled, tile * 64);
    return .{
        .clouds = .{ std.math.clamp(sky.cloud_coverage, 0, 1), @max(sky.cloud_density, 0) * extinction, bottom, top },
        .shape = .{ @floatCast(1.0 / tile), @floatCast(-x), @floatCast(-z), std.math.clamp(sky.cloud_shadows, 0, 1) },
    };
}

/// What lights the world and the clouds now, and the night's part of it.
pub const Now = struct {
    /// Toward what lights them - the sun by day, the moon by night - and
    /// its light.
    toward: Vec3,
    light: [3]f32,
    /// The sun's light as it reaches the ground, and the moon's.
    sun_light: [3]f32,
    moon_toward: Vec3,
    moon_light: [3]f32,
    /// Nought by day, one once the sun is well down.
    night: f32,
};

/// The sun by day, and once it has set the moon, opposite it, its light
/// growing as the sun goes down - each faded out at the horizon, so the
/// one gives way to the other where both are dark.
pub fn nowOf(lit: Lit) Now {
    const sun = sunLight(lit);
    const night = std.math.clamp((-lit.toward.y - 0.03) * 10, 0, 1);
    const moon_toward = lit.toward.neg();
    var moon: [3]f32 = @splat(0);
    if (lit.sky.moon) {
        const e = @max(lit.sky.moon_energy, 0) * night * std.math.clamp(moon_toward.y * 12 + 0.6, 0, 1);
        moon = .{ 0.75 * e, 0.82 * e, e };
    }
    const by_moon = moon[0] + moon[1] + moon[2] > sun[0] + sun[1] + sun[2];
    return .{
        .toward = if (by_moon) moon_toward else lit.toward,
        .light = if (by_moon) moon else sun,
        .sun_light = sun,
        .moon_toward = moon_toward,
        .moon_light = moon,
        .night = night,
    };
}

/// The sun's light as the air takes it: as `sunLight`, but faded out
/// further under the horizon, where the sky is still lit after the ground.
fn twilight(lit: Lit) [3]f32 {
    const up = std.math.clamp(lit.toward.y * 8 + 0.9, 0, 1);
    var light: [3]f32 = undefined;
    if (lit.sky.tint_sun) {
        const through = sunThrough(lit.sky, lit.toward);
        for (0..3) |i| light[i] = lit.light[i] * through[i] * up;
    } else {
        // A light whose colour is its own - a warm sun set by hand - is
        // taken as already coloured by the air: over the air it is white,
        // as bright, and the sky under it as blue as under any sun.
        const bright = 0.2126 * lit.light[0] + 0.7152 * lit.light[1] + 0.0722 * lit.light[2];
        for (0..3) |i| light[i] = bright * up;
    }
    return light;
}

/// The night sky's own glow, linear.
pub fn nightGlow(sky: Sky3D) [3]f32 {
    const c = linear(sky.night_color);
    const e = @max(sky.night_energy, 0);
    return .{ c[0] * e, c[1] * e, c[2] * e };
}

/// The sun's light as it reaches the ground under `lit`: reddened by the
/// air it came through where the sky says so, and gone once it is under
/// the horizon.
pub fn sunLight(lit: Lit) [3]f32 {
    const through = if (lit.sky.tint_sun) sunThrough(lit.sky, lit.toward) else [3]f32{ 1, 1, 1 };
    const up = std.math.clamp(lit.toward.y * 12 + 0.6, 0, 1);
    var light: [3]f32 = undefined;
    for (0..3) |i| light[i] = lit.light[i] * through[i] * up;
    return light;
}

/// The `Sky` block for drawing `lit` through `view`, its clouds seen from
/// `eye` in the world's metres, into a picture `width` by `height`.
pub fn blockOf(lit: Lit, view: View3D, view_projection: math.Mat4, eye: Vec3, seconds: f64, width: u32, height: u32, flip: f32) Block {
    const sky = lit.sky;
    const forward = view.forward();
    const clouds = cloudsOf(sky, seconds);
    const quality = qualityOf(sky.cloud_quality);
    const toward = lit.toward;
    const now = nowOf(lit);
    const light = now.sun_light;
    // The air keeps the sun's light a little after the ground has lost it:
    // twilight, till the sun is six degrees and more under the horizon.
    const air_light = twilight(lit);
    const zenith = airLight(sky, .init(0, 1, 0), toward, air_light);
    const ground_color = linear(sky.ground_color);
    const ambient = ambientOf(lit);
    var ground: [4]f32 = .{ 0, 0, 0, 1 };
    for (0..3) |i| ground[i] = ground_color[i] * ((light[i] * @max(toward.y, 0) + now.moon_light[i] * @max(now.moon_toward.y, 0)) / std.math.pi + ambient[i]);
    const glow = nightGlow(sky);
    const moon_half = std.math.clamp(sky.moon_size, 0.0001, 0.5) / 2;
    const moon_shown: f32 = if (sky.moon) 1.4 * std.math.lerp(0.2, 1.0, now.night) else 0;
    const half = std.math.clamp(sky.sun_size, 0.0001, 0.5) / 2;
    return .{
        .view_projection = view_projection,
        .from = .{ view.position.x, view.position.y, view.position.z, if (view.projection == .orthogonal) 1 else 0 },
        .forward = .{ forward.x, forward.y, forward.z, 0 },
        .eye = .{ eye.x, eye.y, eye.z, @floatCast(@mod(seconds, 3600)) },
        .sun = .{ toward.x, toward.y, toward.z, @cos(half) },
        .sun_color = .{ air_light[0], air_light[1], air_light[2], @max(sky.sun_brightness, 0) },
        .air = airDepth(sky),
        .look = .{ air_brightness * @max(sky.energy, 0), mie_g, 0, 0 },
        .ground = ground,
        // Inside a cloud, its own light scattered round, besides the sky's.
        .ambient = .{ zenith[0] * 2.5 + ambient[0] + now.light[0] * 0.08, zenith[1] * 2.5 + ambient[1] + now.light[1] * 0.08, zenith[2] * 2.5 + ambient[2] + now.light[2] * 0.08, 0 },
        .clouds = clouds.clouds,
        .cloud_shape = clouds.shape,
        .cloud_march = .{ quality.steps, quality.light_steps, @max(sky.cloud_distance, 1), 0 },
        .target = .{ @floatFromInt(width), @floatFromInt(height), flip, 0 },
        .light = .{ now.toward.x, now.toward.y, now.toward.z, 0 },
        .light_color = .{ now.light[0], now.light[1], now.light[2], 0 },
        .moon = .{ now.moon_toward.x, now.moon_toward.y, now.moon_toward.z, @cos(moon_half) },
        .moon_color = .{ 0.9 * moon_shown, 0.92 * moon_shown, moon_shown, 0 },
        .night = .{ glow[0], glow[1], glow[2], @max(sky.stars, 0) * now.night },
    };
}

/// The size of the picture the sky is worked out into for a frame
/// `width` by `height`.
pub fn pictureSize(sky: Sky3D, width: u32, height: u32) [2]u32 {
    const scale = qualityOf(sky.cloud_quality).scale;
    return .{
        @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(width)) * scale)))),
        @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) * scale)))),
    };
}

fn linear(c: Color) [3]f32 {
    return .{ toLinear(c.r), toLinear(c.g), toLinear(c.b) };
}

fn toLinear(v: f32) f32 {
    const x = @max(v, 0);
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

// --- The noise picture -----------------------------------------------------

/// The noise picture's texels, `noise_size` a side, RGBA: the volume's
/// noise in red and, a layer on, green; the coverage in blue; and a finer
/// coverage in alpha. Each tiles; the same every time.
pub fn noiseTexels(gpa: Allocator) ![]u8 {
    const n = noise_size;
    const texels = try gpa.alloc(u8, n * n * 4);
    errdefer gpa.free(texels);
    var random: std.Random.DefaultPrng = .init(0x5C1E_C10D);
    const r = random.random();
    for (0..n * n) |i| texels[i * 4] = r.int(u8);
    for (0..n) |y| for (0..n) |x| {
        const from = ((y + layer_step[1]) % n) * n + (x + layer_step[0]) % n;
        texels[(y * n + x) * 4 + 1] = texels[from * 4];
    };
    const cover = try gpa.alloc(f32, n * n);
    defer gpa.free(cover);
    try coverage(gpa, cover, r, coverage_cells);
    for (cover, 0..) |v, i| texels[i * 4 + 2] = @intFromFloat(@round(v * 255));
    try coverage(gpa, cover, r, coverage_cells * 4);
    for (cover, 0..) |v, i| texels[i * 4 + 3] = @intFromFloat(@round(v * 255));
    return texels;
}

/// A sum of four noises that tile, the coarsest `cells` a side, into
/// `out` - made even, so that its values spread evenly from nought to one.
fn coverage(gpa: Allocator, out: []f32, r: std.Random, cells: u32) !void {
    const n = noise_size;
    @memset(out, 0);
    const lattice = try gpa.alloc(f32, (cells << 3) * (cells << 3));
    defer gpa.free(lattice);
    var period = cells;
    var amplitude: f32 = 1;
    for (0..4) |_| {
        for (lattice[0 .. period * period]) |*v| v.* = r.float(f32);
        for (0..n) |y| for (0..n) |x| {
            const fx = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(period)) / n;
            const fy = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(period)) / n;
            const x0: u32 = @intFromFloat(@floor(fx));
            const y0: u32 = @intFromFloat(@floor(fy));
            const tx = smooth(fx - @floor(fx));
            const ty = smooth(fy - @floor(fy));
            const x1 = (x0 + 1) % period;
            const y1 = (y0 + 1) % period;
            const a = std.math.lerp(lattice[y0 * period + x0], lattice[y0 * period + x1], tx);
            const b = std.math.lerp(lattice[y1 * period + x0], lattice[y1 * period + x1], tx);
            out[y * n + x] += std.math.lerp(a, b, ty) * amplitude;
        };
        period *= 2;
        amplitude *= 0.5;
    }
    // Even: each value its rank.
    const order = try gpa.alloc(u32, out.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, out, struct {
        fn less(values: []f32, a: u32, b: u32) bool {
            return values[a] < values[b];
        }
    }.less);
    const last: f32 = @floatFromInt(out.len - 1);
    const ranked = try gpa.alloc(f32, out.len);
    defer gpa.free(ranked);
    for (order, 0..) |at, rank| ranked[at] = @as(f32, @floatFromInt(rank)) / last;
    @memcpy(out, ranked);
}

fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

// --- Drawing ---------------------------------------------------------------

pub const SkyDraw = struct {
    noise: rhi.Texture,
    /// The noise read repeating, and the picture read clamped.
    repeating: rhi.Sampler,
    clamped: rhi.Sampler,
    block: rhi.Buffer,
    corners: rhi.Buffer,
    shaders: ?Shaders = null,
    refused: bool = false,
    picture_pipeline: ?rhi.Pipeline = null,
    picture_format: rhi.Format = .rgba8_unorm,
    /// By samples a pixel.
    over_pipelines: std.AutoHashMapUnmanaged(u32, rhi.Pipeline) = .empty,
    picture: ?rhi.Texture = null,
    picture_size: [2]u32 = .{ 0, 0 },
    /// Whether a picture was worked out for the frame being drawn.
    ready: bool = false,

    const Shaders = struct {
        picture: shader.Module,
        picture_gpu: rhi.Shader,
        over: shader.Module,
        over_gpu: rhi.Shader,
    };

    /// The noise and what reads it: made with the renderer, as the 3D
    /// surfaces read the clouds' shadow from it. The shaders wait for the
    /// first sky.
    pub fn init(gpa: Allocator, device: *rhi.Device) !SkyDraw {
        const texels = try noiseTexels(gpa);
        defer gpa.free(texels);
        const noise = try device.createTexture(.{ .width = noise_size, .height = noise_size, .data = texels, .label = "sky noise" });
        errdefer device.destroyTexture(noise);
        const repeating = try device.createSampler(.{ .wrap_u = .repeat, .wrap_v = .repeat });
        errdefer device.destroySampler(repeating);
        const clamped = try device.createSampler(.{});
        errdefer device.destroySampler(clamped);
        const block = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Block), .dynamic = true, .label = "sky" });
        errdefer device.destroyBuffer(block);
        const corners = try device.createBuffer(.{ .kind = .vertex, .size = 4 * @sizeOf([3]f32), .dynamic = true, .label = "sky" });
        return .{ .noise = noise, .repeating = repeating, .clamped = clamped, .block = block, .corners = corners };
    }

    pub fn deinit(self: *SkyDraw, gpa: Allocator, device: *rhi.Device) void {
        if (self.picture_pipeline) |p| device.destroyPipeline(p);
        var it = self.over_pipelines.valueIterator();
        while (it.next()) |p| device.destroyPipeline(p.*);
        self.over_pipelines.deinit(gpa);
        if (self.shaders) |*held| {
            device.destroyShader(held.picture_gpu);
            device.destroyShader(held.over_gpu);
            held.picture.deinit();
            held.over.deinit();
        }
        if (self.picture) |p| device.destroyTexture(p);
        device.destroyBuffer(self.corners);
        device.destroyBuffer(self.block);
        device.destroySampler(self.clamped);
        device.destroySampler(self.repeating);
        device.destroyTexture(self.noise);
        self.* = undefined;
    }

    fn compiled(self: *SkyDraw, gpa: Allocator, device: *rhi.Device) !*Shaders {
        if (self.shaders) |*held| return held;
        if (self.refused) return error.Refused;
        errdefer self.refused = true;
        var picture = try compileOne(gpa, picture_source, "the sky's shader");
        errdefer picture.deinit();
        const picture_gpu = try gpuOf(device, &picture, "sky");
        errdefer device.destroyShader(picture_gpu);
        var over = try compileOne(gpa, over_source, "the sky's shader over the frame");
        errdefer over.deinit();
        const over_gpu = try gpuOf(device, &over, "sky over");
        self.shaders = .{ .picture = picture, .picture_gpu = picture_gpu, .over = over, .over_gpu = over_gpu };
        return &self.shaders.?;
    }

    /// The sky and its clouds, as `block` says, worked out into the picture
    /// - `size` a side, of `format` - in a pass of its own, before the
    /// frame's. False where it cannot be.
    pub fn drawPicture(self: *SkyDraw, gpa: Allocator, device: *rhi.Device, list: *rhi.CommandList, view: View3D, block: Block, size: [2]u32, format: rhi.Format) !bool {
        self.ready = false;
        const held = self.compiled(gpa, device) catch return false;
        if (self.picture == null or self.picture_size[0] != size[0] or self.picture_size[1] != size[1] or self.picture_format != format) {
            if (self.picture) |p| device.destroyTexture(p);
            self.picture = null;
            self.picture = try device.createTexture(.{ .width = size[0], .height = size[1], .format = format, .usage = .{ .sampled = true, .render_target = true }, .label = "sky" });
            self.picture_size = size;
        }
        if (self.picture_pipeline == null or self.picture_format != format) {
            if (self.picture_pipeline) |p| device.destroyPipeline(p);
            self.picture_pipeline = null;
            self.picture_format = format;
            self.picture_pipeline = self.pipelineOf(device, &held.picture, held.picture_gpu, .{}, format, null, 1, "sky") catch {
                self.refused = true;
                return false;
            };
        }
        const corners = fog_backdrop.cornersOf(view);
        try device.updateBuffer(self.corners, 0, std.mem.sliceAsBytes(&corners));
        try device.updateBuffer(self.block, 0, std.mem.asBytes(&block));
        try list.beginPass(.{ .color = .{ .target = .{ .texture = self.picture.? }, .load = .clear, .clear_color = .{ 0, 0, 0, 1 } } });
        try list.setViewport(.{ .width = @floatFromInt(size[0]), .height = @floatFromInt(size[1]) });
        try list.setPipeline(self.picture_pipeline.?);
        try list.setUniformBuffer(0, self.block);
        try list.setTexture(0, self.noise, self.repeating);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.draw(.{ .vertex_count = 4 });
        try list.endPass();
        self.ready = true;
        return true;
    }

    /// Into the frame's pass `list` has begun: the picture, where nothing
    /// was drawn, and the sun's disc. After the solid surfaces, which hide
    /// it, and before what is seen through.
    pub fn drawOver(self: *SkyDraw, gpa: Allocator, device: *rhi.Device, list: *rhi.CommandList, color_format: rhi.Format, depth_format: rhi.Format, samples: u32) !void {
        if (!self.ready) return;
        self.ready = false;
        const held = self.compiled(gpa, device) catch return;
        const pipeline = self.over_pipelines.get(samples) orelse made: {
            const made = self.pipelineOf(device, &held.over, held.over_gpu, .{ .test_enabled = true, .write = false, .compare = .less_equal }, color_format, depth_format, samples, "sky over") catch {
                self.refused = true;
                return;
            };
            try self.over_pipelines.put(gpa, samples, made);
            break :made made;
        };
        try list.setPipeline(pipeline);
        try list.setUniformBuffer(0, self.block);
        try list.setTexture(0, self.picture.?, self.clamped);
        try list.setTexture(1, self.noise, self.repeating);
        try list.setVertexBuffer(0, self.corners, 0);
        try list.draw(.{ .vertex_count = 4 });
    }

    fn pipelineOf(self: *SkyDraw, device: *rhi.Device, module: *shader.Module, gpu: rhi.Shader, depth: rhi.DepthState, color_format: rhi.Format, depth_format: ?rhi.Format, samples: u32, label: []const u8) !rhi.Pipeline {
        _ = self;
        return device.createPipeline(.{
            .shader = gpu,
            .attributes = &.{.{ .location = 0, .format = .float3, .offset = 0 }},
            .buffers = &.{.{ .stride = @sizeOf([3]f32) }},
            .topology = .triangle_strip,
            .depth = depth,
            .color_format = color_format,
            .depth_format = depth_format,
            .samples = samples,
            .uniform_blocks = (try module.uniformBlockNames()) orelse return error.ShaderFailed,
            .textures = (try module.textureNames()) orelse return error.ShaderFailed,
            .label = label,
        }) catch |err| {
            log.err("the graphics driver refused the {s} pipeline: {s}", .{ label, device.diagnostics() });
            return err;
        };
    }
};

fn compileOne(gpa: Allocator, source: []const u8, what: []const u8) !shader.Module {
    var said: std.Io.Writer.Allocating = .init(gpa);
    defer said.deinit();
    return shader.compile(gpa, source, &said.writer) catch |err| {
        log.err("{s}: {s}", .{ what, said.written() });
        return err;
    };
}

fn gpuOf(device: *rhi.Device, module: *const shader.Module, label: []const u8) !rhi.Shader {
    return device.createShader(.{
        .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
        .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
        .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
        .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
        .label = label,
    });
}

/// Which way up a target drawn into is read, as the post passes take it.
pub fn flipOf(device: *const rhi.Device) f32 {
    return material.screenFlip(device);
}

// --- Tests -----------------------------------------------------------------

test "the sky's shaders compile for every target, and their block is where it is written" {
    for ([_][]const u8{ picture_source, over_source }) |source| {
        var module = try compileOne(testing.allocator, source, "test");
        defer module.deinit();
        const block = module.block("Sky").?;
        try testing.expectEqual(@as(usize, @sizeOf(Block)), block.size);
        try testing.expectEqual(@as(?u32, @offsetOf(Block, "clouds")), block.offsetOf("CLOUDS"));
        try testing.expectEqual(@as(?u32, @offsetOf(Block, "target")), block.offsetOf("SKY_TARGET"));
    }
}

test "the noise's green is its red a layer on, and its coverage spreads evenly" {
    const texels = try noiseTexels(testing.allocator);
    defer testing.allocator.free(texels);
    const n = noise_size;
    for ([_][2]usize{ .{ 0, 0 }, .{ 10, 200 }, .{ 255, 255 }, .{ 230, 30 } }) |at| {
        const x = at[0];
        const y = at[1];
        const moved = ((y + layer_step[1]) % n) * n + (x + layer_step[0]) % n;
        try testing.expectEqual(texels[moved * 4], texels[(y * n + x) * 4 + 1]);
    }
    // Half the coverage is over a half.
    var over: usize = 0;
    for (0..n * n) |i| over += @intFromBool(texels[i * 4 + 2] >= 128);
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, @floatFromInt(over)) / (n * n), 0.01);
    // The same every time.
    const again = try noiseTexels(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, texels, again);
}

test "the air is blue overhead, paler at the horizon, and red when the sun is low" {
    const sky: Sky3D = .{};
    const high: Vec3 = Vec3.init(0.3, 0.9, 0.2).norm();
    const white = [3]f32{ 1, 1, 1 };
    const up = airLight(sky, .init(0, 1, 0), high, white);
    try testing.expect(up[2] > up[1] and up[1] > up[0]);
    const level = airLight(sky, Vec3.init(-1, 0.02, 0).norm(), high, white);
    // Toward the horizon nearer white: red closer to blue.
    try testing.expect(level[0] / level[2] > up[0] / up[2]);
    // The sun low: its light comes through redder.
    const low = sunThrough(sky, Vec3.init(1, 0.03, 0).norm());
    try testing.expect(low[0] > low[1] and low[1] > low[2]);
    const noon = sunThrough(sky, .init(0, 1, 0));
    try testing.expectApproxEqAbs(@as(f32, 1), noon[2], 1e-3);
    // The light from everywhere is bluish under a clear sky.
    const ambient = ambientOf(.{ .sky = .{ .clouds = false }, .toward = high, .light = white });
    try testing.expect(ambient[2] > ambient[0]);
}

test "by night the moon lights the world, opposite the sun, and the stars come out" {
    const white = [3]f32{ 1, 1, 1 };
    const day = nowOf(.{ .sky = .{}, .toward = Vec3.init(0.2, 0.8, 0.1).norm(), .light = white });
    try testing.expectEqual(@as(f32, 0), day.night);
    try testing.expect(day.toward.y > 0);
    const night = nowOf(.{ .sky = .{}, .toward = Vec3.init(0.2, -0.6, 0.1).norm(), .light = white });
    try testing.expectEqual(@as(f32, 1), night.night);
    try testing.expect(night.toward.y > 0 and night.light[2] > night.light[0] and night.light[2] > 0);
    const dark = nowOf(.{ .sky = .{ .moon = false }, .toward = Vec3.init(0.2, -0.6, 0.1).norm(), .light = white });
    try testing.expectEqual(@as(f32, 0), dark.light[0] + dark.light[1] + dark.light[2]);
    const block = blockOf(.{ .sky = .{}, .toward = Vec3.init(0.2, -0.6, 0.1).norm(), .light = white }, .{}, .identity, .zero, 0, 8, 8, 1);
    try testing.expect(block.night[3] > 0.9);
}

test "the clouds' wind is kept small, and they say nothing when off" {
    const sky: Sky3D = .{ .wind_speed = 30 };
    const later = cloudsOf(sky, 1e7);
    const tile = @as(f32, sky.cloud_size) * coverage_cells;
    try testing.expect(@abs(later.shape[1]) <= tile * 64 and @abs(later.shape[2]) <= tile * 64);
    const off = cloudsOf(.{ .clouds = false }, 10);
    try testing.expectEqual(@as(f32, 0), off.clouds[0]);
    try testing.expectEqual(@as(f32, 0), off.shape[3]);
}

test "the picture is a part of the frame, by the clouds' quality" {
    try testing.expectEqual([2]u32{ 960, 540 }, pictureSize(.{ .cloud_quality = .medium }, 1920, 1080));
    try testing.expectEqual([2]u32{ 640, 360 }, pictureSize(.{ .cloud_quality = .low }, 1920, 1080));
}
