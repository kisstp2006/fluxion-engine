// SPDX-License-Identifier: BSD-3-Clause

//! The components the 3D layer draws from: `MeshInstance3D` and what gives
//! it a mesh and a look - `PrimitiveMesh3D`, `Material3D` - the `Camera3D`
//! it is seen through and the `DirectionalLight3D` it is lit by. Each is
//! beside a `Transform3D`, which says where it is. See `render/renderer3d.zig`.
//!
//! ```zig
//! _ = try app.world.spawnWith(.{
//!     fx.Transform3D.at(0, 0.5, 0),
//!     fx.MeshInstance3D{},
//!     fx.PrimitiveMesh3D{ .shape = .box },
//!     fx.Material3D{ .albedo_color = .hex(0xCC3333) },
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

/// A mesh drawn where its `Transform3D` is: the one `mesh` names, or the
/// shape a `PrimitiveMesh3D` beside it says. A `Material3D` beside it says
/// how it looks; without one it is plain white, lit. `Appearance.visible`
/// hides it and `Appearance.modulate` tints it, as everything drawn.
pub const MeshInstance3D = extern struct {
    /// A `.mesh` file, or a mesh made in code: `App.addMesh`. A
    /// `PrimitiveMesh3D` beside it is drawn in its place.
    mesh: mesh.MeshHandle = .none,
    /// The render layers it is on: a camera whose `cull_mask` has none of
    /// them does not see it.
    layers: u32 = 1,
    /// Whether it throws a shadow, once lights do.
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

/// How a `MeshInstance3D` beside it looks: its colour and its picture, lit
/// or not, and which of its sides are drawn.
pub const Material3D = extern struct {
    /// Multiplied into the picture; its alpha is how see-through it is,
    /// with `transparency` on.
    albedo_color: Color = .white,
    /// Laid over the mesh by its corners' places on a picture. None is white.
    albedo_texture: assets.TextureHandle = .none,
    /// How many times the picture is laid across the mesh, and how far it
    /// is moved, in pictures.
    uv_scale: math.Vec2 = .one,
    uv_offset: math.Vec2 = .zero,
    transparency: Transparency = .disabled,
    cull: Cull = .back,
    /// Drawn as its colour, with no light: a sign that glows, a sky.
    unshaded: bool = false,

    pub const Transparency = enum(u8) {
        /// Solid, drawn front to back.
        disabled,
        /// Laid over what is behind it by its alpha, drawn back to front
        /// after everything solid.
        alpha,
    };

    /// Which side of its triangles is left out: the back, which a closed
    /// mesh never shows; the front, to see into a room from outside; or
    /// neither, for a leaf, a sheet of paper.
    pub const Cull = enum(u8) { back, front, disabled };

    pub const reflect_name = "Material3D";
    pub const reflect_fields = .{
        .albedo_color = .{attr.Doc{ .text = "Multiplied into the picture; the alpha shows with transparency on" }},
        .albedo_texture = .{attr.Doc{ .text = "The picture laid over the mesh; none is white" }},
        .uv_scale = .{attr.Doc{ .text = "How many times the picture is laid across" }},
        .uv_offset = .{attr.Doc{ .text = "How far the picture is moved, in pictures" }},
        .transparency = .{attr.Doc{ .text = "Whether it is laid over what is behind it by its alpha" }},
        .cull = .{attr.Doc{ .text = "Which side of its triangles is not drawn" }},
        .unshaded = .{attr.Doc{ .text = "Drawn as its colour, with no light" }},
    };

    pub fn colored(color: Color) Material3D {
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
/// `-z`. Only the first one found lights the world, for now.
pub const DirectionalLight3D = extern struct {
    color: Color = .white,
    /// How bright: one is the colour as it is.
    energy: f32 = 1,

    pub const reflect_name = "DirectionalLight3D";
    pub const reflect_fields = .{
        .color = .{attr.Doc{ .text = "The light's colour" }},
        .energy = .{ attr.Range{ .min = 0, .max = 16 }, attr.Doc{ .text = "How bright: one is the colour as it is" } },
    };
};
