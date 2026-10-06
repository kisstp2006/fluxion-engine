// SPDX-License-Identifier: BSD-3-Clause

//! The components the 3D layer draws from: `MeshInstance3D` and what gives
//! it a mesh and a material - `PrimitiveMesh3D`, `Material3D`, and
//! `Material3DData`, what a material is - the `Camera3D`
//! it is seen through, the lights it is lit by - `DirectionalLight3D`,
//! `PointLight3D`, `SpotLight3D` - and the `Environment` round it all: the
//! light from everywhere, fog, and how the light is turned into a picture.
//! Each but the environment is beside a `Transform3D`, which says where it
//! is. See `render/renderer3d.zig`.
//!
//! ```zig
//! const red = try app.addMaterial("red", .{ .albedo_color = .hex(0xCC3333) });
//! _ = try app.world.spawnWith(.{
//!     fx.Transform3D.at(0, 0.5, 0),
//!     fx.MeshInstance3D{},
//!     fx.PrimitiveMesh3D{ .shape = .box },
//!     fx.Material3D{ .material = red },
//! });
//! var eye: fx.Transform3D = .at(0, 2, 5);
//! eye.lookAt(.zero, .unit_y);
//! _ = try app.world.spawnWith(.{ eye, fx.Camera3D{} });
//! ```

const std = @import("std");

const math = @import("fluxion_math");

const assets = @import("../assets/assets.zig");
const attr = @import("../reflect/attr.zig");
const Color = @import("../math/color.zig").Color;
const mesh = @import("mesh.zig");
const MaterialHandle = @import("materials.zig").MaterialHandle;
const shaders = @import("shaders.zig");

/// A mesh drawn where its `Transform3D` is: the one `mesh` names, or the
/// shape a `PrimitiveMesh3D` beside it says. How each of its surfaces looks
/// is, first found: the material of a `Material3D` beside it, the surface's
/// own material, or plain white and lit. `Appearance.visible` hides it and
/// `Appearance.modulate` tints it, as everything drawn.
pub const MeshInstance3D = extern struct {
    /// A `.mesh` file, a model's mesh, or a mesh made in code:
    /// `App.addMesh`. A `PrimitiveMesh3D` beside it is drawn in its place.
    mesh: mesh.MeshHandle = .none,
    /// The render layers it is on: a camera whose `cull_mask` has none of
    /// them does not see it.
    layers: u32 = 1,
    /// Whether it casts a shadow where a light that casts them reaches it.
    cast_shadow: bool = true,

    pub const reflect_name = "MeshInstance3D";
    pub const reflect_fields = .{
        .mesh = .{attr.Doc{ .text = "The mesh drawn; a PrimitiveMesh3D beside it is drawn instead" }},
        .layers = .{ attr.Layers{ .names = .render_3d }, attr.Doc{ .text = "The render layers it is on" } },
        .cast_shadow = .{attr.Doc{ .text = "Whether it throws a shadow" }},
    };
};

/// A mesh made from a few numbers, drawn by the `MeshInstance3D` beside it:
/// a box, a ball, a floor, a tube, a capsule. Its mesh is made once for its
/// numbers and shared by every shape that has them.
pub const PrimitiveMesh3D = extern struct {
    shape: Shape = .box,
    /// A box's width, height and depth; a plane's width and depth on `x`
    /// and `z`.
    size: math.Vec3 = .one,
    /// A sphere's, a cylinder's and a capsule's.
    radius: f32 = 0.5,
    /// A cylinder's and a capsule's, from end to end.
    height: f32 = 2,
    /// How many cuts from top to bottom: a sphere's and a capsule's.
    rings: u32 = 16,
    /// How many cuts round.
    segments: u32 = 32,

    pub const Shape = mesh.Primitive.Shape;

    pub const reflect_name = "PrimitiveMesh3D";
    pub const reflect_fields = .{
        .size = .{attr.Doc{ .text = "A box's width, height and depth; a plane's width and depth" }},
        .radius = .{ attr.Range{ .min = 0, .max = 1000 }, attr.Doc{ .text = "A sphere's, a cylinder's and a capsule's" } },
        .height = .{ attr.Range{ .min = 0, .max = 1000 }, attr.Doc{ .text = "A cylinder's and a capsule's, end to end" } },
        .rings = .{ attr.Range{ .min = mesh.min_rings, .max = mesh.max_rings, .step = 1 }, attr.Doc{ .text = "Cuts from top to bottom: a sphere's and a capsule's" } },
        .segments = .{ attr.Range{ .min = mesh.min_segments, .max = mesh.max_segments, .step = 1 }, attr.Doc{ .text = "Cuts round" } },
    };

    /// What makes its mesh.
    pub fn primitive(self: PrimitiveMesh3D) mesh.Primitive {
        return .{ .shape = self.shape, .size = self.size, .radius = self.radius, .height = self.height, .rings = self.rings, .segments = self.segments };
    }

    pub fn of(shape: Shape) PrimitiveMesh3D {
        return .{ .shape = shape };
    }
};

/// The material a mesh beside it is drawn with, every surface of it: a
/// `.mat3d` file, or one made in code - `App.addMaterial`. It holds nothing
/// else of how the mesh looks; the material does, and what changes it
/// changes every mesh drawn with it. With none, each surface is drawn with
/// its own material, and plain without one.
///
/// The numbers of a material's shader are the material's, and an entity can
/// give its own in their place - `App.setShaderParam` - written in a scene
/// as `params` beside `material`.
pub const Material3D = extern struct {
    material: MaterialHandle = .none,

    /// The numbers this entity gives the shader, kept by the app.
    pub const scene_beside = [_]@import("../scene/scene.zig").Beside{shaders.scene_params};

    pub const reflect_name = "Material3D";
    pub const reflect_fields = .{
        .material = .{attr.Doc{ .text = "The material every surface of the mesh is drawn with: a .mat3d file" }},
    };
};

/// How a mesh looks: its colour and its picture, the light it gives off,
/// lit or not, see-through or not, and which of its sides are drawn - what
/// a `.mat3d` file holds, and what a `Material3D` or a mesh's surface
/// names. See `render/materials.zig`.
///
/// Light falls on it as on a real surface: how much of it is metal, and how
/// rough it is, say how sharp what it reflects is and of what colour.
/// Colours are written as a picture shows them, and lit as light adds up.
pub const Material3DData = extern struct {
    /// Multiplied into the picture; its alpha is how see-through it is,
    /// with `transparency` on.
    albedo_color: Color = .white,
    /// Laid over the mesh by its corners' places on a picture. None is white.
    albedo_texture: assets.TextureHandle = .none,
    /// The colours the mesh's corners hold - a model's painted shading -
    /// multiplied in too.
    vertex_color: bool = false,
    /// How much of it is metal: nought for wood, stone, plastic and skin,
    /// one for metal, which reflects in its own colour.
    metallic: f32 = 0,
    /// How rough it is: nought is a mirror, one is chalk.
    roughness: f32 = 1,
    /// Times `metallic` in its blue and `roughness` in its green, as a glTF
    /// model's are.
    metallic_roughness_texture: assets.TextureHandle = .none,
    /// Which way its surface faces at each point, against the mesh's own: a
    /// normal map, blue straight out, as a model's are drawn.
    normal_texture: assets.TextureHandle = .none,
    /// How strongly the normal map tilts the surface: nought is flat.
    normal_scale: f32 = 1,
    /// How much of the light from everywhere reaches each point, in its red:
    /// the creases a model's maker darkened.
    occlusion_texture: assets.TextureHandle = .none,
    occlusion_strength: f32 = 1,
    /// How many times the pictures are laid across the mesh, and how far
    /// they are moved, in pictures.
    uv_scale: math.Vec2 = .one,
    uv_offset: math.Vec2 = .zero,
    /// Light it gives off whatever lights it, times `emission_energy`, and
    /// times `emission_texture` where it has one: a screen, a lamp's bulb.
    emission: Color = .black,
    emission_energy: f32 = 1,
    emission_texture: assets.TextureHandle = .none,
    transparency: Transparency = .disabled,
    /// Under this alpha nothing is drawn, with `transparency` at `scissor`.
    alpha_scissor_threshold: f32 = 0.5,
    cull: Cull = .back,
    /// Drawn as its colour, with no light: a sign that glows, a sky.
    unshaded: bool = false,
    /// A `.shader3d` file that says what the surface is, from what this
    /// says it is; none draws it as this says. Its numbers are the mesh's
    /// entity's, as a 2D material's are: see `App.setShaderParam`.
    shader: shaders.ShaderHandle = .none,

    /// Its shader's numbers, kept with it, written under `params`.
    pub const scene_beside = [_]@import("../scene/scene.zig").Beside{shaders.scene_params};

    pub const Transparency = enum(u8) {
        /// Solid, drawn front to back.
        disabled,
        /// Laid over what is behind it by its alpha, drawn back to front
        /// after everything solid.
        alpha,
        /// Solid where its alpha reaches `alpha_scissor_threshold`, and not
        /// there at all elsewhere: leaves, a fence.
        scissor,
    };

    /// Which side of its triangles is left out: the back, which a closed
    /// mesh never shows; the front, to see into a room from outside; or
    /// neither, for a leaf, a sheet of paper.
    pub const Cull = enum(u8) { back, front, disabled };

    pub const reflect_name = "Material3DData";
    pub const reflect_fields = .{
        .albedo_color = .{attr.Doc{ .text = "Multiplied into the picture; the alpha shows with transparency on" }},
        .albedo_texture = .{attr.Doc{ .text = "The picture laid over the mesh; none is white" }},
        .vertex_color = .{attr.Doc{ .text = "The colours the mesh's corners hold, multiplied in" }},
        .metallic = .{ attr.Group{ .name = "Metal and roughness" }, attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How much of it is metal: nought for wood, stone and plastic, one for metal" } },
        .roughness = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How rough it is: nought is a mirror, one is chalk" } },
        .metallic_roughness_texture = .{attr.Doc{ .text = "Times metallic in its blue and roughness in its green" }},
        .normal_texture = .{ attr.Group{ .name = "Normal map" }, attr.Doc{ .text = "Which way the surface faces at each point: a normal map" } },
        .normal_scale = .{ attr.Range{ .min = 0, .max = 4 }, attr.Doc{ .text = "How strongly the normal map tilts the surface" } },
        .occlusion_texture = .{ attr.Group{ .name = "Occlusion" }, attr.Doc{ .text = "How much of the light from everywhere reaches each point, in its red" } },
        .occlusion_strength = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How much the occlusion picture darkens" } },
        .emission = .{ attr.Group{ .name = "Light it gives off" }, attr.Doc{ .text = "Light it gives off whatever lights it" } },
        .emission_energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright the light it gives off is" } },
        .emission_texture = .{attr.Doc{ .text = "Where on the mesh it gives off light, times the emission" }},
        .alpha_scissor_threshold = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "Under this alpha nothing is drawn, with transparency at scissor" } },
        .uv_scale = .{ attr.Group{ .name = "Where the pictures lie" }, attr.Doc{ .text = "How many times the pictures are laid across" } },
        .uv_offset = .{attr.Doc{ .text = "How far the pictures are moved, in pictures" }},
        .transparency = .{ attr.Group{ .name = "Drawing" }, attr.Doc{ .text = "Whether it is laid over what is behind it by its alpha, or cut where that is low" } },
        .cull = .{attr.Doc{ .text = "Which side of its triangles is not drawn" }},
        .unshaded = .{attr.Doc{ .text = "Drawn as its colour, with no light" }},
        .shader = .{ attr.Group{ .name = "Shader" }, attr.Doc{ .text = "A .shader3d file that says what the surface is; none draws it as these fields say" } },
    };

    pub fn colored(color: Color) Material3DData {
        return .{ .albedo_color = color };
    }
};

/// What the 3D layer is seen through: from its `Transform3D`, looking down
/// its `-z` with `+y` up. Of the cameras that draw no picture of their own,
/// the one that is `current` is looked through - or, with none, any.
pub const Camera3D = extern struct {
    projection: Projection = .perspective,
    /// From the bottom of the picture to the top, in radians: a perspective
    /// camera's.
    fov: f32 = std.math.degreesToRadians(75.0),
    /// From the bottom of the picture to the top, in world units: an
    /// orthogonal camera's.
    size: f32 = 1,
    /// Nothing nearer than `near` nor further than `far` is drawn. The
    /// further the near one is, the less two faces close together fight.
    near: f32 = 0.05,
    far: f32 = 4000,
    /// The one looked through. `App.makeCurrent3D` makes it so and the rest
    /// not.
    current: bool = false,
    /// The render layers it sees.
    cull_mask: u32 = 0xFFFF_FFFF,

    pub const Projection = enum(u8) {
        /// Further is smaller.
        perspective,
        /// Everything its size whatever how far: a plan, a map.
        orthogonal,
    };

    pub const reflect_name = "Camera3D";
    pub const reflect_fields = .{
        .fov = .{ attr.Angle{}, attr.Range{ .min = std.math.degreesToRadians(1.0), .max = std.math.degreesToRadians(179.0) }, attr.Doc{ .text = "From the bottom of the picture to the top: a perspective camera's" } },
        .size = .{ attr.Range{ .min = 0.001, .max = 10000 }, attr.Doc{ .text = "From the bottom of the picture to the top, in units: an orthogonal camera's" } },
        .near = .{ attr.Range{ .min = 0.001, .max = 10000 }, attr.Doc{ .text = "Nothing nearer is drawn" } },
        .far = .{ attr.Range{ .min = 0.01, .max = 1_000_000 }, attr.Doc{ .text = "Nothing further is drawn" } },
        .current = .{attr.Doc{ .text = "The one the screen is seen through" }},
        .cull_mask = .{ attr.Layers{ .names = .render_3d }, attr.Doc{ .text = "The render layers it sees" } },
    };
};

/// Light from far away, all one way - the sun: along its `Transform3D`'s
/// `-z`. The first four found light the world.
///
/// With `shadow`, what it lights casts a shadow, up to `shadow_max_distance`
/// from the camera, fading out before it. The view is cut into
/// `shadow_cascades`, nearest smallest, so near shadows stay sharp.
pub const DirectionalLight3D = extern struct {
    color: Color = .white,
    /// How bright: one is the colour as it is.
    energy: f32 = 1,
    shadow: bool = false,
    shadow_bias: f32 = 1,
    shadow_normal_bias: f32 = 1.5,
    shadow_blur: f32 = 1,
    shadow_cascades: ShadowCascades = .four,
    shadow_max_distance: f32 = 100,
    /// How wide it looks across, in radians: a wider one's shadows soften
    /// the further they fall from what casts them. The sun is about half a
    /// degree; nought is a point.
    angular_size: f32 = 0,

    pub const ShadowCascades = enum(u8) {
        one,
        two,
        four,

        pub fn count(self: ShadowCascades) u32 {
            return switch (self) {
                .one => 1,
                .two => 2,
                .four => 4,
            };
        }
    };

    pub const reflect_name = "DirectionalLight3D";
    pub const reflect_fields = .{
        .color = .{attr.Doc{ .text = "The light's colour" }},
        .energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright: one is the colour as it is" } },
        .shadow = .{ attr.Group{ .name = "Shadow" }, attr.Doc{ .text = "Whether what it lights casts a shadow" } },
        .shadow_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far the point a shadow is looked up for is moved toward the light, in the shadow's texels: more keeps a surface from shadowing itself, and moves the shadow off what casts it" } },
        .shadow_normal_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far it is moved out along its surface, in the shadow's texels: what keeps a slope from shadowing itself" } },
        .shadow_blur = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How soft the shadow's edge is: one is the project's shadow filter as it is, nought a hard edge" } },
        .shadow_cascades = .{attr.Doc{ .text = "How many pieces the view is cut into for its shadow, nearest smallest: more keeps near shadows sharper" }},
        .shadow_max_distance = .{ attr.Range{ .min = 0.1, .max = 100_000 }, attr.Doc{ .text = "How far from the camera there are shadows: they fade out before it" } },
        .angular_size = .{ attr.Angle{}, attr.Range{ .min = 0, .max = std.math.degreesToRadians(10.0) }, attr.Doc{ .text = "How wide it looks across: a wider one's shadows soften the further they fall from what casts them" } },
    };
};

/// Light from a point, every way: a bulb, a candle. It reaches `range` from
/// where its `Transform3D` is, and fades on the way. A mesh is lit by the
/// eight of these and of `SpotLight3D` nearest it that reach it. With a
/// `cookie` - a panorama, all the way round it - its light takes the
/// picture's colours: the middle of the picture along its `-z`, the top
/// toward its `+y`.
pub const PointLight3D = extern struct {
    color: Color = .white,
    /// How bright: one is the colour as it is, next to it.
    energy: f32 = 1,
    /// How far it reaches, in units: nothing further is lit by it.
    range: f32 = 5,
    /// How it fades toward `range`: one evenly, more sooner, less later.
    attenuation: f32 = 1,
    /// Whether it fades out as the camera moves away from it.
    distance_fade: bool = false,
    /// How far from the camera it starts to fade.
    distance_fade_begin: f32 = 40,
    /// How much further it takes to disappear.
    distance_fade_length: f32 = 10,
    /// Whether what it lights casts a shadow.
    shadow: bool = false,
    shadow_bias: f32 = 1,
    shadow_normal_bias: f32 = 1.5,
    shadow_blur: f32 = 1,
    /// How big it is, in units: a bigger one's shadows soften the further
    /// they fall from what casts them. Nought is a point.
    size: f32 = 0,
    cookie: assets.TextureHandle = .none,

    pub const reflect_name = "PointLight3D";
    pub const reflect_fields = .{
        .color = .{attr.Doc{ .text = "The light's colour" }},
        .energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright: one is the colour as it is, next to it" } },
        .range = .{ attr.Range{ .min = 0.01, .max = 4096 }, attr.Doc{ .text = "How far it reaches: nothing further is lit by it" } },
        .attenuation = .{ attr.Range{ .min = 0.01, .max = 16 }, attr.Doc{ .text = "How it fades toward its range: one evenly, more sooner, less later" } },
        .distance_fade = .{ attr.Group{ .name = "Distance fade" }, attr.Doc{ .text = "Whether it fades out as the camera moves away from it" } },
        .distance_fade_begin = .{ attr.Range{ .min = 0, .max = 1_000_000 }, attr.Doc{ .text = "How far from the camera it starts to fade" } },
        .distance_fade_length = .{ attr.Range{ .min = 0.01, .max = 1_000_000 }, attr.Doc{ .text = "How much further it takes to disappear" } },
        .shadow = .{ attr.Group{ .name = "Shadow" }, attr.Doc{ .text = "Whether what it lights casts a shadow" } },
        .shadow_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far the point a shadow is looked up for is moved toward the light, in the shadow's texels: more keeps a surface from shadowing itself, and moves the shadow off what casts it" } },
        .shadow_normal_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far it is moved out along its surface, in the shadow's texels: what keeps a slope from shadowing itself" } },
        .shadow_blur = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How soft the shadow's edge is: one is the project's shadow filter as it is, nought a hard edge" } },
        .size = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How big it is: a bigger one's shadows soften the further they fall from what casts them" } },
        .cookie = .{ attr.Group{ .name = "Cookie" }, attr.Doc{ .text = "A panorama it shines through, all the way round: its middle along the light's way, its top toward its up" } },
    };
};

/// Light from a point, in a cone: a torch, a stage light. It shines along
/// its `Transform3D`'s `-z`, `angle` either side of it, and reaches `range`.
/// With a `cookie`, it shines through that picture: its light takes the
/// picture's colours across the cone, the picture's top toward its `+y`.
pub const SpotLight3D = extern struct {
    color: Color = .white,
    energy: f32 = 1,
    range: f32 = 5,
    attenuation: f32 = 1,
    /// From the middle of the cone to its edge, in radians.
    angle: f32 = std.math.degreesToRadians(45.0),
    /// How it fades toward the edge of the cone: one evenly, more sooner.
    angle_attenuation: f32 = 1,
    distance_fade: bool = false,
    distance_fade_begin: f32 = 40,
    distance_fade_length: f32 = 10,
    shadow: bool = false,
    shadow_bias: f32 = 1,
    shadow_normal_bias: f32 = 1.5,
    shadow_blur: f32 = 1,
    size: f32 = 0,
    cookie: assets.TextureHandle = .none,

    pub const reflect_name = "SpotLight3D";
    pub const reflect_fields = .{
        .color = .{attr.Doc{ .text = "The light's colour" }},
        .energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright: one is the colour as it is, next to it" } },
        .range = .{ attr.Range{ .min = 0.01, .max = 4096 }, attr.Doc{ .text = "How far it reaches: nothing further is lit by it" } },
        .attenuation = .{ attr.Range{ .min = 0.01, .max = 16 }, attr.Doc{ .text = "How it fades toward its range: one evenly, more sooner, less later" } },
        .angle = .{ attr.Angle{}, attr.Range{ .min = std.math.degreesToRadians(0.1), .max = std.math.degreesToRadians(89.9) }, attr.Doc{ .text = "From the middle of the cone to its edge" } },
        .angle_attenuation = .{ attr.Range{ .min = 0.01, .max = 16 }, attr.Doc{ .text = "How it fades toward the edge of the cone: one evenly, more sooner" } },
        .distance_fade = .{ attr.Group{ .name = "Distance fade" }, attr.Doc{ .text = "Whether it fades out as the camera moves away from it" } },
        .distance_fade_begin = .{ attr.Range{ .min = 0, .max = 1_000_000 }, attr.Doc{ .text = "How far from the camera it starts to fade" } },
        .distance_fade_length = .{ attr.Range{ .min = 0.01, .max = 1_000_000 }, attr.Doc{ .text = "How much further it takes to disappear" } },
        .shadow = .{ attr.Group{ .name = "Shadow" }, attr.Doc{ .text = "Whether what it lights casts a shadow" } },
        .shadow_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far the point a shadow is looked up for is moved toward the light, in the shadow's texels: more keeps a surface from shadowing itself, and moves the shadow off what casts it" } },
        .shadow_normal_bias = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How far it is moved out along its surface, in the shadow's texels: what keeps a slope from shadowing itself" } },
        .shadow_blur = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How soft the shadow's edge is: one is the project's shadow filter as it is, nought a hard edge" } },
        .size = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How big it is: a bigger one's shadows soften the further they fall from what casts them" } },
        .cookie = .{ attr.Group{ .name = "Cookie" }, attr.Doc{ .text = "A picture it shines through: its light takes the picture's colours across its cone, the top toward its up" } },
    };
};

/// What surrounds the 3D world: the colour behind it, the light that comes
/// from everywhere, fog, glow round what is bright, and how the light
/// worked out is turned into a picture. The first one found is the world's;
/// with none, the project's clear colour is behind it, a little grey light
/// comes from everywhere, and light is shown as it is.
pub const Environment = extern struct {
    background: Background = .clear_color,
    background_color: Color = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
    /// Light from everywhere, times `ambient_energy`: what a shadow is lit
    /// by.
    ambient_color: Color = .white,
    ambient_energy: f32 = 0.25,
    /// How light brighter than white is brought into the picture.
    tonemap: Tonemap = .linear,
    /// Every light times this before it is toned: more is brighter.
    exposure: f32 = 1,
    /// The brightness that comes out white, with Reinhard and filmic.
    white: f32 = 1,
    /// Fog, thicker the further, and below `fog_height` the deeper.
    fog: bool = false,
    fog_color: Color = .{ .r = 0.6, .g = 0.65, .b = 0.72, .a = 1 },
    /// How much of the way a unit of fog hides.
    fog_density: f32 = 0.02,
    /// Below this height the fog thickens, by `fog_height_density` a unit
    /// down; nought for none.
    fog_height: f32 = 0,
    fog_height_density: f32 = 0,
    /// Glow round what is brighter than `glow_threshold`, spread out and
    /// added back, `glow_intensity` of it: bloom.
    glow: bool = false,
    glow_threshold: f32 = 1,
    glow_intensity: f32 = 0.8,
    /// How far it spreads: one is the whole of it, less keeps it close.
    glow_spread: f32 = 1,

    pub const Background = enum(u8) {
        /// The project's clear colour.
        clear_color,
        /// `background_color`.
        color,
    };

    pub const Tonemap = enum(u8) {
        /// As it is, brighter than white cut off.
        linear,
        /// Bright light brought down gently, never quite white.
        reinhard,
        /// As film takes light: a soft toe and shoulder.
        filmic,
        /// The film industry's curve: rich and contrasting.
        aces,
    };

    pub const reflect_name = "Environment";
    pub const reflect_fields = .{
        .background = .{attr.Doc{ .text = "What is behind the 3D world: the project's clear colour, or the colour below" }},
        .background_color = .{attr.Doc{ .text = "Behind the 3D world, with the background at colour" }},
        .ambient_color = .{ attr.Group{ .name = "Ambient light" }, attr.Doc{ .text = "Light from everywhere: what a shadow is lit by" } },
        .ambient_energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright the light from everywhere is" } },
        .tonemap = .{ attr.Group{ .name = "Tonemap" }, attr.Doc{ .text = "How light brighter than white is brought into the picture" } },
        .exposure = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "Every light times this before it is toned" } },
        .white = .{ attr.Range{ .min = 0.1, .max = 16 }, attr.Doc{ .text = "The brightness that comes out white, with Reinhard and filmic" } },
        .fog = .{ attr.Group{ .name = "Fog" }, attr.Doc{ .text = "Fog, thicker the further, and below its height the deeper" } },
        .fog_color = .{attr.Doc{ .text = "The fog's colour" }},
        .fog_density = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How much of the way a unit of fog hides" } },
        .fog_height = .{attr.Doc{ .text = "Below this height the fog thickens" }},
        .fog_height_density = .{ attr.Range{ .min = 0, .max = 4 }, attr.Doc{ .text = "How much thicker a unit further down: nought for no fog by height" } },
        .glow = .{ attr.Group{ .name = "Glow" }, attr.Doc{ .text = "Glow round what is brighter than the threshold" } },
        .glow_threshold = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "Light brighter than this glows" } },
        .glow_intensity = .{ attr.Range{ .min = 0, .max = 8 }, attr.Doc{ .text = "How much of the glow is added back" } },
        .glow_spread = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How far it spreads: one is the whole of it, less keeps it close" } },
    };
};
