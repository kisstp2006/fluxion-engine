// SPDX-License-Identifier: BSD-3-Clause

//! Navigation: where an agent can walk, worked out from a world's
//! triangles, and the way across it.
//!
//! - `bake` makes a `NavMesh` from triangles: the solid in columns, what
//!   can be stood on kept, worn back from the walls by the agent's radius,
//!   cut into regions, outlined, and the outlines made convex polygons.
//! - A `NavMesh` says where on it a point is nearest, and the way from one
//!   point to another: A* from polygon to polygon, pulled tight through the
//!   doorways between them. It is written to and read from a `.navmesh`.
//! - `avoidance` keeps agents out of each other's way.
//!
//! It is given plain numbers and gives back plain numbers: the engine
//! gathers the triangles from its world (`navigation/`). Like the lightmap
//! baker it is built for speed whatever the engine is built as, and needs
//! nothing but the standard library.

pub const vec = @import("vec.zig");
pub const Vec3 = vec.Vec3;
pub const NavMesh = @import("NavMesh.zig");
pub const Map = @import("Map.zig");
pub const avoidance = @import("avoidance.zig");
const bake_mod = @import("bake.zig");
pub const bake = bake_mod.bake;
pub const Settings = bake_mod.Settings;
pub const Input = bake_mod.Input;
pub const Report = bake_mod.Report;
pub const Error = bake_mod.Error;

test {
    _ = @import("Heightfield.zig");
    _ = @import("Compact.zig");
    _ = @import("contours.zig");
    _ = @import("polymesh.zig");
    _ = NavMesh;
    _ = Map;
    _ = avoidance;
    _ = bake_mod;
}
