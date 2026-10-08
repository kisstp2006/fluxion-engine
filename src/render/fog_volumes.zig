// SPDX-License-Identifier: BSD-3-Clause

//! Fog in a box: each `FogVolume` the camera sees some of - the eight
//! nearest it - in one uniform block, and what the surfaces' shader does
//! with them: the way from the camera to each pixel of a surface is cut to
//! the box, walked in eight steps, and the fog met on the way - thinner at
//! the box's soft edges, in clumps where it has noise, drifting with its
//! wind - hides the surface behind its colour.
//!
//! Only a surface is seen through it: where nothing is behind the fog, the
//! empty background shows as it is. A room, a corridor, a hollow - what has
//! walls or a floor behind it - is where a fog volume goes.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const Color = @import("../math/color.zig").Color;
const hierarchy = @import("../scene/hierarchy.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const FogVolume = @import("render3d_components.zig").FogVolume;
const View3D = @import("view3d.zig").View3D;
const worlds3d = @import("worlds3d.zig");

/// The most a frame holds.
pub const most = 8;
/// The uniform block's slot, in the surfaces' shader and the billboards'.
pub const slot = 7;
/// Six `vec4`s a volume.
const rows = 6;

/// The volumes, as the shader's `FogVolumes` block says: each its world to
/// its own space - its box from minus one to one - as three rows, its colour
/// and density, its knobs and its noise's drift; and how many there are.
pub const Block = extern struct {
    volumes: [most * rows][4]f32 = @splat(@splat(0)),
    count: [4]f32 = @splat(0),
};

/// The shader's part: the block, and what fogs a colour seen at a point.
/// Uses `CAMERA_POSITION` and `CAMERA_FORWARD` of the `Frame` block.
pub const shader_part =
    \\uniform FogVolumes : 7 {
    \\    vec4 FOG_VOLUMES[48];
    \\    vec4 FOG_VOLUME_COUNT;
    \\}
    \\
    \\// A number from nought to one for a point of space.
    \\float fogHash(vec3 p) {
    \\    vec3 q = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419)) * 17.0;
    \\    return fract(q.x * q.y * q.z * (q.x + q.y + q.z));
    \\}
    \\
    \\// Smooth noise from nought to one: the corners round a point, blended.
    \\float fogNoise(vec3 p) {
    \\    vec3 i = floor(p);
    \\    vec3 f = fract(p);
    \\    vec3 u = f * f * (vec3(3.0) - 2.0 * f);
    \\    float a = mix(fogHash(i), fogHash(i + vec3(1.0, 0.0, 0.0)), u.x);
    \\    float b = mix(fogHash(i + vec3(0.0, 1.0, 0.0)), fogHash(i + vec3(1.0, 1.0, 0.0)), u.x);
    \\    float c = mix(fogHash(i + vec3(0.0, 0.0, 1.0)), fogHash(i + vec3(1.0, 0.0, 1.0)), u.x);
    \\    float d = mix(fogHash(i + vec3(0.0, 1.0, 1.0)), fogHash(i + vec3(1.0, 1.0, 1.0)), u.x);
    \\    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
    \\}
    \\
    \\// How thick a volume is at `q`, in its own space from minus one to one:
    \\// whole inside, thinning to nothing over its soft edge (`knobs.x`); a box,
    \\// or a ball for `knobs.w`.
    \\float fogShape(vec3 q, vec4 knobs) {
    \\    float inside = knobs.w > 0.5 ? 1.0 - length(q) : 1.0 - max(abs(q.x), max(abs(q.y), abs(q.z)));
    \\    return clamp(inside / max(knobs.x, 0.0001), 0.0, 1.0);
    \\}
    \\
    \\// A colour seen at `p`, behind the fog volumes on the way to it.
    \\vec3 fogVolumes(vec3 color, vec3 p) {
    \\    vec3 eye = CAMERA_POSITION.xyz;
    \\    if (CAMERA_FORWARD.w > 0.5) {
    \\        eye = p - CAMERA_FORWARD.xyz * dot(p - CAMERA_POSITION.xyz, CAMERA_FORWARD.xyz);
    \\    }
    \\    float far = distance(eye, p);
    \\    vec3 result = color;
    \\    for (int v = 0; v < 8; v = v + 1) {
    \\        if (float(v) < FOG_VOLUME_COUNT.x) {
    \\            int b = v * 6;
    \\            vec4 r0 = FOG_VOLUMES[b];
    \\            vec4 r1 = FOG_VOLUMES[b + 1];
    \\            vec4 r2 = FOG_VOLUMES[b + 2];
    \\            vec4 tint = FOG_VOLUMES[b + 3];
    \\            vec4 knobs = FOG_VOLUMES[b + 4];
    \\            vec4 drift = FOG_VOLUMES[b + 5];
    \\            vec3 a = vec3(dot(r0.xyz, eye) + r0.w, dot(r1.xyz, eye) + r1.w, dot(r2.xyz, eye) + r2.w);
    \\            vec3 e = vec3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
    \\            vec3 d = e - a;
    \\            vec3 safe = mix(vec3(0.000001), d, step(vec3(0.000001), abs(d)));
    \\            vec3 t0 = (vec3(-1.0) - a) / safe;
    \\            vec3 t1 = (vec3(1.0) - a) / safe;
    \\            vec3 lo = min(t0, t1);
    \\            vec3 hi = max(t0, t1);
    \\            float enter = max(max(lo.x, max(lo.y, lo.z)), 0.0);
    \\            float leave = min(min(hi.x, min(hi.y, hi.z)), 1.0);
    \\            if (leave > enter) {
    \\                float sum = 0.0;
    \\                for (int i = 0; i < 8; i = i + 1) {
    \\                    float t = enter + (leave - enter) * (float(i) + 0.5) / 8.0;
    \\                    float thick = fogShape(a + d * t, knobs);
    \\                    if (knobs.z > 0.0) {
    \\                        vec3 w = (eye + (p - eye) * t) * knobs.y + drift.xyz;
    \\                        thick = thick * mix(1.0, fogNoise(w) * 2.0, knobs.z);
    \\                    }
    \\                    sum = sum + thick;
    \\                }
    \\                float hidden = sum / 8.0 * (leave - enter) * far * tint.w;
    \\                result = mix(tint.rgb, result, exp(-hidden));
    \\            }
    \\        }
    \\    }
    \\    return result;
    \\}
    \\
;

/// A volume the frame keeps, before the nearest are chosen.
const Kept = struct {
    rows: [rows][4]f32,
    distance: f32,

    fn nearer(_: void, a: Kept, b: Kept) bool {
        return a.distance < b.distance;
    }
};

/// The block for what `view` sees through `frustum`: the visible volumes
/// in `world` - the world a `World3D` makes, or the main one for none -
/// nearest the camera first, at most `most`. `seconds` drifts their noise.
pub fn gather(app: *App, view: View3D, frustum: math.Frustum, seconds: f32, worlds: worlds3d.Filter) !Block {
    var kept: [64]Kept = undefined;
    var count: usize = 0;
    var it = try ecs.Query(.{ Transform3D, FogVolume }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform3D), chunk.slice(FogVolume), chunk.entities) |local, fog, entity| {
            if (!(fog.density > 0)) continue;
            if (!worlds.admits(app, entity)) continue;
            if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
            const placed = hierarchy.resolve3D(&app.world, &app.snapshots3d, entity, local, app.time.alpha()) orelse continue;
            const half = fog.size.scale(0.5);
            if (!(half.x > 0 and half.y > 0 and half.z > 0)) continue;
            const model = placed.matrix().mul(.fromScale(half));
            const bounds = (math.Aabb{ .min = .splat(-1), .max = .splat(1) }).transformed(model);
            if (frustum.testAabb(bounds) == .outside) continue;
            const volume = rowsOf(fog, model, seconds) orelse continue;
            const distance = bounds.center().sub(view.position).len();
            if (count < kept.len) {
                kept[count] = .{ .rows = volume, .distance = distance };
                count += 1;
            }
        }
    }
    std.mem.sort(Kept, kept[0..count], {}, Kept.nearer);
    var block: Block = .{};
    const shown = @min(count, most);
    for (kept[0..shown], 0..) |volume, at| @memcpy(block.volumes[at * rows ..][0..rows], &volume.rows);
    block.count = .{ @floatFromInt(shown), 0, 0, 0 };
    return block;
}

/// One volume's rows of the block: its world to its own space, made
/// from `model`, its box's; null where that cannot be undone.
pub fn rowsOf(fog: FogVolume, model: math.Mat4, seconds: f32) ?[rows][4]f32 {
    const inverse = model.inverse() orelse return null;
    const color = linear(fog.color);
    const scale = if (fog.noise_scale > 0) 1 / fog.noise_scale else 0;
    const strength = if (scale > 0) std.math.clamp(fog.noise_strength, 0, 1) else 0;
    const drift = fog.wind.scale(-seconds * scale);
    return .{
        inverse.row(0).array(),
        inverse.row(1).array(),
        inverse.row(2).array(),
        .{ color[0], color[1], color[2], @max(fog.density, 0) },
        .{ std.math.clamp(fog.edge_fade, 0, 1), scale, strength, if (fog.shape == .ellipsoid) 1 else 0 },
        .{ drift.x, drift.y, drift.z, 0 },
    };
}

fn linear(c: Color) [3]f32 {
    return .{ toLinear(c.r), toLinear(c.g), toLinear(c.b) };
}

fn toLinear(v: f32) f32 {
    const x = @max(v, 0);
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

test "a volume's rows take the world into its box, from minus one to one" {
    var placed: Transform3D = .at(10, 0, 0);
    placed.scale = .init(2, 1, 1);
    const fog: FogVolume = .{ .size = .init(4, 2, 6), .noise_scale = 2, .noise_strength = 0.5, .wind = .init(1, 0, 0) };
    const model = placed.matrix().mul(.fromScale(fog.size.scale(0.5)));
    const volume = rowsOf(fog, model, 3).?;
    const corner: math.Vec3 = .init(14, 1, 3);
    for (volume[0..3], [_]f32{ 1, 1, 1 }) |row, want| {
        try testing.expectApproxEqAbs(want, row[0] * corner.x + row[1] * corner.y + row[2] * corner.z + row[3], 1e-5);
    }
    // Half the noise's size: a metre a second of wind is half a unit of it.
    try testing.expectApproxEqAbs(@as(f32, -1.5), volume[5][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), volume[4][1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), volume[4][2], 1e-5);
}
