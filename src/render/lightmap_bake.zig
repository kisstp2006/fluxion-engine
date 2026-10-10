// SPDX-License-Identifier: BSD-3-Clause

//! Baking a `LightmapGI`'s light. What the world's still meshes, their
//! materials and pictures, and its lights are now is gathered on the app's
//! thread into the plain numbers `fluxion_lightmapper` traces rays through,
//! on threads of its own; what it bakes is kept as a `.lightmap` the
//! `LightmapGI` then names.
//!
//! ```zig
//! const bake = try app.bakeLightmap(gi, "res://scenes/office.lightmap");
//! while (!bake.isFinished()) {
//!     const p = bake.progress(); // what it is on, how far
//!     ...
//! }
//! _ = try bake.finish(app); // written, and the LightmapGI names it
//! ```
//!
//! What is baked: every visible `MeshInstance3D` whose `gi_mode` is static,
//! each surface with its material - one drawn see-through lets light by,
//! one cut by its alpha lets it through its holes, one unshaded gives off
//! its colour - and every visible light whose `bake` is not none. The sky
//! is the first `Environment`'s ambient light. A mesh with no lightmap UVs
//! still stands in the light's way and bounces it, and is lit by the
//! probes; `notes` says which.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const math = @import("fluxion_math");
const lightmapper = @import("fluxion_lightmapper");

const App = @import("../App.zig");
const assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const components3d = @import("render3d_components.zig");
const lightmaps = @import("lightmaps.zig");
const materials = @import("materials.zig");
const csg_shapes = @import("csg_shapes.zig");
const mesh = @import("mesh.zig");
const renderer3d = @import("renderer3d.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;

const Uuid = id.Uuid;
const LightmapGI = components3d.LightmapGI;
const MeshInstance3D = components3d.MeshInstance3D;
const Material3D = components3d.Material3D;
const Material3DData = components3d.Material3DData;

pub const Progress = lightmapper.Progress;

/// A bake on its way: see the module's comment.
pub const LightmapBake = struct {
    /// What the baker's numbers are made with: memory any thread can ask
    /// for, where there are threads.
    gpa: Allocator,
    job: *lightmapper.Bake,
    triangles: []lightmapper.Triangle,
    instances: []lightmapper.Instance,
    materials: []lightmapper.Material,
    images: []lightmapper.Image,
    lights: []lightmapper.Light,
    /// Each instance's entity's UUID: what finds its mesh in the lightmap.
    uuids: []Uuid,
    gi: ecs.Entity,
    path: []u8,
    /// What was left out of the lightmap, or lit otherwise, and why: a line
    /// each.
    notes: std.ArrayList([]u8) = .empty,

    pub fn progress(self: *const LightmapBake) Progress {
        return self.job.progress();
    }

    pub fn isFinished(self: *const LightmapBake) bool {
        return self.job.isFinished();
    }

    /// Ask it to stop: `finish` then says `error.Cancelled`.
    pub fn cancel(self: *LightmapBake) void {
        self.job.cancel();
    }

    /// Wait for it, keep what it baked - written to its `.lightmap`, read
    /// as the app's, and named by the `LightmapGI` it was started for while
    /// that is there - and let the bake go. It is let go of whatever
    /// happens.
    pub fn finish(self: *LightmapBake, app: *App) !lightmaps.LightmapHandle {
        defer self.destroy();
        var result = try self.job.finish();
        defer result.deinit(self.gpa);
        const handle = try keep(app, self.path, try lightmaps.fromBaked(app.gpa, result, self.uuids));
        if (app.world.get(self.gi, LightmapGI)) |gi| gi.data = handle;
        return handle;
    }

    /// Stop it, and let it go with nothing kept.
    pub fn abandon(self: *LightmapBake) void {
        self.job.cancel();
        if (self.job.finish()) |result| {
            var dropped = result;
            dropped.deinit(self.gpa);
        } else |_| {}
        self.destroy();
    }

    fn destroy(self: *LightmapBake) void {
        const gpa = self.gpa;
        gpa.free(self.triangles);
        gpa.free(self.instances);
        gpa.free(self.materials);
        for (self.images) |image| gpa.free(image.pixels);
        gpa.free(self.images);
        gpa.free(self.lights);
        gpa.free(self.uuids);
        gpa.free(self.path);
        for (self.notes.items) |note| gpa.free(note);
        self.notes.deinit(gpa);
        gpa.destroy(self);
    }
};

/// What was baked written to `path` and read back as the app's - in place
/// of what was read from there before - or, where nothing can be written,
/// kept under that name in memory. `baked` is let go of, or the app's.
fn keep(app: *App, path: []const u8, baked: lightmaps.Lightmap) !lightmaps.LightmapHandle {
    var lightmap = baked;
    const io = app.io orelse {
        errdefer lightmap.deinit(app.gpa);
        return app.addLightmap(path, lightmap);
    };
    {
        defer lightmap.deinit(app.gpa);
        const bytes = try lightmaps.write(app.gpa, lightmap);
        defer app.gpa.free(bytes);
        const file = try app.project.osPath(app.gpa, path);
        defer app.gpa.free(file);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes });
    }
    if (app.findLightmap(path)) |known| {
        _ = try app.reloadLightmap(known);
        return known;
    }
    return app.loadLightmap(path);
}

/// Memory any thread can ask for, where there are threads; the app's own
/// where there are none.
fn bakeAllocator(app: *App) Allocator {
    return if (builtin.single_threaded) app.gpa else std.heap.smp_allocator;
}

/// Gather what the `LightmapGI` on `gi` lights, and start baking it into
/// `path`. See `App.bakeLightmap`.
pub fn start(app: *App, gi: ecs.Entity, path: []const u8) !*LightmapBake {
    const settings_of = app.world.get(gi, LightmapGI) orelse return error.NoLightmapGI;
    const gpa = bakeAllocator(app);
    var gathering: Gathering = .{ .app = app, .gpa = gpa };
    defer gathering.deinit();
    try gathering.gatherMeshes();
    try gathering.gatherLights();

    const sky = skyOf(app);
    const settings: lightmapper.Settings = .{
        .texels_per_unit = @max(settings_of.texels_per_unit, 0.01),
        .max_size = settings_of.max_size.texels(),
        .bounces = std.math.clamp(settings_of.bounces, 1, 16),
        .rays = settings_of.quality.rays(),
        .light_rays = std.math.clamp(settings_of.quality.rays() / 4, 4, 64),
        .denoise = settings_of.denoise,
        .probe_spacing = @max(settings_of.probe_spacing, 0.05),
        .sky = sky,
    };

    const self = try gpa.create(LightmapBake);
    errdefer gpa.destroy(self);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const triangles = try gathering.triangles.toOwnedSlice(gpa);
    errdefer gpa.free(triangles);
    const instances = try gathering.instances.toOwnedSlice(gpa);
    errdefer gpa.free(instances);
    const baked_materials = try gathering.materials.toOwnedSlice(gpa);
    errdefer gpa.free(baked_materials);
    const lights = try gathering.lights.toOwnedSlice(gpa);
    errdefer gpa.free(lights);
    const uuids = try gathering.uuids.toOwnedSlice(gpa);
    errdefer gpa.free(uuids);
    // The pictures last: their pixels are let go of with them from here.
    const images = try gathering.images.toOwnedSlice(gpa);
    errdefer {
        for (images) |image| gpa.free(image.pixels);
        gpa.free(images);
    }
    const job = try lightmapper.Bake.start(gpa, .{
        .triangles = triangles,
        .instances = instances,
        .materials = baked_materials,
        .images = images,
        .lights = lights,
    }, settings);
    self.* = .{
        .gpa = gpa,
        .job = job,
        .triangles = triangles,
        .instances = instances,
        .materials = baked_materials,
        .images = images,
        .lights = lights,
        .uuids = uuids,
        .gi = gi,
        .path = owned_path,
        .notes = gathering.notes,
    };
    gathering.notes = .empty;
    return self;
}

/// The sky's light: the first `Environment`'s ambient light, as the
/// renderer lights with it.
fn skyOf(app: *App) [3]f32 {
    if (renderer3d.environmentOf(app)) |held| {
        const c = linear(held.ambient_color);
        const e = @max(held.ambient_energy, 0);
        return .{ c[0] * e, c[1] * e, c[2] * e };
    }
    const c = linear(renderer3d.ambient);
    return .{ c[0], c[1], c[2] };
}

fn linear(c: Color) [4]f32 {
    return .{ toLinear(c.r), toLinear(c.g), toLinear(c.b), c.a };
}

fn toLinear(x: f32) f32 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

const Gathering = struct {
    app: *App,
    gpa: Allocator,
    triangles: std.ArrayList(lightmapper.Triangle) = .empty,
    instances: std.ArrayList(lightmapper.Instance) = .empty,
    materials: std.ArrayList(lightmapper.Material) = .empty,
    images: std.ArrayList(lightmapper.Image) = .empty,
    lights: std.ArrayList(lightmapper.Light) = .empty,
    uuids: std.ArrayList(Uuid) = .empty,
    notes: std.ArrayList([]u8) = .empty,
    /// Each material and picture by its handle, once: what a triangle
    /// names, or null for one left out (see-through).
    material_found: std.AutoHashMapUnmanaged(materials.MaterialHandle, ?u32) = .empty,
    image_found: std.AutoHashMapUnmanaged(assets.TextureHandle, ?u32) = .empty,

    fn deinit(self: *Gathering) void {
        const gpa = self.gpa;
        self.triangles.deinit(gpa);
        self.instances.deinit(gpa);
        self.materials.deinit(gpa);
        for (self.images.items) |image| gpa.free(image.pixels);
        self.images.deinit(gpa);
        self.lights.deinit(gpa);
        self.uuids.deinit(gpa);
        for (self.notes.items) |said| gpa.free(said);
        self.notes.deinit(gpa);
        self.material_found.deinit(gpa);
        self.image_found.deinit(gpa);
    }

    fn note(self: *Gathering, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.notes.append(self.gpa, try std.fmt.allocPrint(self.gpa, fmt, args));
    }

    fn gatherMeshes(self: *Gathering) !void {
        const app = self.app;
        var it = try ecs.Query(.{ Transform3D, MeshInstance3D }).over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(MeshInstance3D), chunk.entities) |instance, entity| {
                if (instance.gi_mode != .static) continue;
                if (!app.inherited.of(app.gpa, &app.world, entity).visible) continue;
                const kept: *mesh.Kept = try app.meshDrawnBy(entity, instance) orelse continue;
                // A CSG shape's mesh made again as it moved has no
                // lightmap UVs yet.
                if (app.world.has(entity, csg_shapes.CSGShape3D)) try csg_shapes.unwrap(app, kept);
                const made = &kept.mesh;
                if (made.indices.len == 0) continue;
                const placed = app.drawnTransform3D(entity) orelse continue;
                const model = placed.matrix();
                const turn = model.normalMatrix() orelse math.Mat3.identity;
                const own: materials.MaterialHandle = if (app.world.get(entity, Material3D)) |held| held.material else .none;
                if (made.uv2_texels == 0) {
                    try self.note("{s}: its mesh has no lightmap UVs, so it is lit by the probes", .{app.nameOf(entity) orelse "A mesh"});
                }
                const at: u32 = @intCast(self.instances.items.len);
                try self.instances.append(self.gpa, .{ .lit = made.uv2_texels > 0, .least_texels = made.uv2_texels });
                try self.uuids.append(self.gpa, try app.ensureUuid(entity));
                for (made.surfaces) |surface| {
                    const chosen = if (!own.isNone() and app.materials.get(own) != null) own else surface.material;
                    const material = try self.materialOf(chosen) orelse continue;
                    const look = materialData(app, chosen);
                    var k = surface.first_index;
                    while (k + 3 <= surface.first_index + surface.index_count) : (k += 3) {
                        var t: lightmapper.Triangle = undefined;
                        t.instance = at;
                        t.material = material;
                        for (0..3) |c| {
                            const v = made.vertices[made.indices[k + c]];
                            t.positions[c] = model.mulPoint(.fromArray(v.position)).array();
                            t.normals[c] = (turn.mulVec3(.fromArray(v.normal)).tryNorm() orelse math.Vec3.unit_y).array();
                            t.uvs[c] = .{ v.uv[0] * look.uv_scale.x + look.uv_offset.x, v.uv[1] * look.uv_scale.y + look.uv_offset.y };
                            t.lightmap_uvs[c] = v.uv2;
                        }
                        try self.triangles.append(self.gpa, t);
                    }
                }
            }
        }
    }

    /// The baker's material for a mesh's surface: what bounces, what is
    /// given off, what is cut. Null for one drawn see-through, which lets
    /// light by.
    fn materialOf(self: *Gathering, handle: materials.MaterialHandle) !?u32 {
        const found = try self.material_found.getOrPut(self.gpa, handle);
        if (found.found_existing) return found.value_ptr.*;
        found.value_ptr.* = null;
        const look = materialData(self.app, handle);
        if (look.transparency == .alpha) return null;
        const albedo = linear(look.albedo_color);
        const diffuse = 1 - std.math.clamp(look.metallic, 0, 1);
        const glow = linear(look.emission);
        const e = @max(look.emission_energy, 0);
        var made: lightmapper.Material = .{
            .albedo = .{ albedo[0] * diffuse, albedo[1] * diffuse, albedo[2] * diffuse },
            .albedo_image = try self.imageOf(look.albedo_texture),
            .emission = .{ glow[0] * e, glow[1] * e, glow[2] * e },
            .emission_image = try self.imageOf(look.emission_texture),
            .alpha = albedo[3],
            .cut = if (look.transparency == .scissor) look.alpha_scissor_threshold else null,
            .two_sided = look.cull == .disabled,
        };
        if (look.unshaded) {
            // Drawn as its colour whatever lights it: it gives that off.
            made.emission = .{ albedo[0], albedo[1], albedo[2] };
            made.emission_image = made.albedo_image;
            made.albedo = .{ 0, 0, 0 };
        }
        const at: u32 = @intCast(self.materials.items.len);
        try self.materials.append(self.gpa, made);
        found.value_ptr.* = at;
        return at;
    }

    /// A picture as the baker reads it, read back from the device once.
    /// Null for none, or one that cannot be read.
    fn imageOf(self: *Gathering, handle: assets.TextureHandle) !?u32 {
        if (handle.isNone()) return null;
        const found = try self.image_found.getOrPut(self.gpa, handle);
        if (found.found_existing) return found.value_ptr.*;
        found.value_ptr.* = null;
        const held = self.app.assets.get(handle) orelse return null;
        if (held.upside_down) return null;
        const pixels = self.app.device.readTexture(held.gpu, self.gpa) catch return null;
        if (pixels.len != @as(usize, held.width) * held.height * 4) {
            self.gpa.free(pixels);
            return null;
        }
        const at: u32 = @intCast(self.images.items.len);
        self.images.append(self.gpa, .{ .width = held.width, .height = held.height, .pixels = pixels }) catch |err| {
            self.gpa.free(pixels);
            return err;
        };
        found.value_ptr.* = at;
        return at;
    }

    fn gatherLights(self: *Gathering) !void {
        const app = self.app;
        {
            var it = try ecs.Query(.{ Transform3D, components3d.DirectionalLight3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(components3d.DirectionalLight3D), chunk.entities) |light, entity| {
                    if (light.bake == .none) continue;
                    const placed = placedLight(app, entity) orelse continue;
                    const toward = placed.back().tryNorm() orelse continue;
                    try self.addLight(.{
                        .kind = .sun,
                        .direction = toward.array(),
                        .color = colorOf(light.color, light.energy),
                        .size = std.math.clamp(light.angular_size, 0, 1),
                        .direct = light.bake == .all,
                    });
                }
            }
        }
        {
            var it = try ecs.Query(.{ Transform3D, components3d.PointLight3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(components3d.PointLight3D), chunk.entities) |light, entity| {
                    if (light.bake == .none) continue;
                    const placed = placedLight(app, entity) orelse continue;
                    try self.addLight(.{
                        .kind = .point,
                        .position = placed.position.array(),
                        .direction = (placed.forward().tryNorm() orelse math.Vec3.init(0, 0, -1)).array(),
                        .up = (placed.up().tryNorm() orelse math.Vec3.unit_y).array(),
                        .color = colorOf(light.color, light.energy),
                        .range = @max(light.range, 0.001),
                        .attenuation = if (light.falloff == .distance) @max(light.attenuation, 0) else @max(light.attenuation, 0.01),
                        .by_distance = light.falloff == .distance,
                        .size = @max(light.size, 0),
                        .cookie = try self.imageOf(light.cookie),
                        .direct = light.bake == .all,
                    });
                }
            }
        }
        {
            var it = try ecs.Query(.{ Transform3D, components3d.SpotLight3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(components3d.SpotLight3D), chunk.entities) |light, entity| {
                    if (light.bake == .none) continue;
                    const placed = placedLight(app, entity) orelse continue;
                    const aim = placed.forward().tryNorm() orelse continue;
                    const angle = std.math.clamp(light.angle, 0, std.math.degreesToRadians(89.9));
                    try self.addLight(.{
                        .kind = .spot,
                        .position = placed.position.array(),
                        .direction = aim.array(),
                        .up = (placed.up().tryNorm() orelse math.Vec3.unit_y).array(),
                        .color = colorOf(light.color, light.energy),
                        .range = @max(light.range, 0.001),
                        .attenuation = if (light.falloff == .distance) @max(light.attenuation, 0) else @max(light.attenuation, 0.01),
                        .by_distance = light.falloff == .distance,
                        .cone = @cos(angle),
                        .cone_attenuation = @max(light.angle_attenuation, 0.01),
                        .spread = @tan(angle),
                        .size = @max(light.size, 0),
                        .cookie = try self.imageOf(light.cookie),
                        .direct = light.bake == .all,
                    });
                }
            }
        }
    }

    fn addLight(self: *Gathering, light: lightmapper.Light) Allocator.Error!void {
        if (light.color[0] + light.color[1] + light.color[2] <= 0) return;
        try self.lights.append(self.gpa, light);
    }
};

fn colorOf(color: Color, energy: f32) [3]f32 {
    const c = linear(color);
    const e = @max(energy, 0);
    return .{ c[0] * e, c[1] * e, c[2] * e };
}

fn materialData(app: *App, handle: materials.MaterialHandle) Material3DData {
    if (!handle.isNone()) if (app.materials.get(handle)) |held| return held.*;
    return .{};
}

/// Where a light is, when it is visible.
fn placedLight(app: *App, entity: ecs.Entity) ?Transform3D {
    if (!app.inherited.of(app.gpa, &app.world, entity).visible) return null;
    return app.drawnTransform3D(entity);
}
