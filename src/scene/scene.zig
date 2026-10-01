// SPDX-License-Identifier: BSD-3-Clause

//! A world written down, and read back: as JSON to read and to diff, or as
//! CBOR, the same scene in fewer bytes. Reading tells the two apart itself.
//!
//! ```zig
//! try app.registerComponents(.{ Wander, Player });
//! try app.saveScene("res://levels/meadow.json", .{});
//! try app.saveScene("res://levels/meadow.scene", .{ .format = .cbor });
//! const loaded = try app.readScene("res://levels/meadow.scene", .{});
//! ```
//!
//! ```json
//! {
//!   "fluxion_scene": 3,
//!   "entities": [
//!     {
//!       "uuid": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c",
//!       "name": "player",
//!       "Transform2D": { "x": 320.0, "y": 180.0 },
//!       "Sprite": { "texture": "res://art/hero.png", "width": 48.0, "height": 48.0 }
//!     },
//!     {
//!       "uuid": "5c2d7e9f-0a1b-4c3d-8e5f-6a7b8c9d0e1f",
//!       "parent": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c",
//!       "name": "turret",
//!       "groups": ["guns"],
//!       "Transform2D": { "y": -6.0 },
//!       "Sprite": { "texture": "res://art/turret.png" }
//!     }
//!   ],
//!   "assets": {
//!     "res://art/hero.png": { "uid": "uid://2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34", "filter": "linear" },
//!     "res://art/turret.png": { "uid": "uid://9d1e4b7a-3c2f-4e8d-a1b6-0f5c7e2d9a83" }
//!   }
//! }
//! ```
//!
//! **An entity is an object of its components**, each under its type's name,
//! beside its UUID and its name. A component's field that holds its default
//! is left out, so a scene says what is particular about each thing - and a
//! field added to a component later reads as its default from every scene
//! written before it.
//!
//! **What a handle points at is written, not the handle.** An `Entity` is the
//! UUID of the one it names, which every entity written is given - so a scene
//! diffs cleanly when one is added at the top, and an editor's undo can bring
//! one back as what it was. A texture or a font is its file, by the path
//! `Project` names it by - `res://` inside the project, which opens from any
//! working directory - and in `assets`, by the UUID in the `.uid` file beside
//! it, which saving a scene makes where there is none. Reading goes by the
//! UUID first, so a file moved with its `.uid` file is found where it went,
//! and by the path when nothing holds that UUID. A texture made from pixels in
//! memory has no file, and is written as `null`.
//!
//! **Reading mints new entities**, gives each the UUID the file has for it -
//! or, when an entity in the world has that one already, as when a scene is
//! loaded twice, a new one - and points every reference at the right one: in
//! the scene first, then in the world, so a scene can name an entity another
//! scene brought.
//!
//! **A scene holds the components it has been told about.** The engine's are
//! registered from the start, and a game adds its own with
//! `App.registerComponents`. A component in a file that nothing here is
//! registered as is kept with its entity as the file has it, and written
//! back so when the scene is saved: a scene from a newer build still opens,
//! and an editor without a game's own components saves the game's scenes
//! whole. See `Unknown`. A scene of another version is refused, and the
//! refusal says which version it is.
//!
//! **A scene that is wrong is an error, never a crash**: what the file holds
//! is checked as it is read, and a mistake is returned with where it is,
//! leaving the world as it was - an editor shows it and goes on.

const std = @import("std");

const ecs = @import("fluxion_ecs");
const json = @import("fluxion_json");
const Uuid = @import("fluxion_id").Uuid;

const SceneHandle = @import("../assets/scene_table.zig").SceneHandle;

const Entity = ecs.Entity;

/// The version this writes, and the only one it reads.
pub const version = 3;

pub const SaveOptions = struct {
    format: json.Format = .json,
    /// Spaces per level of JSON. CBOR has no layout.
    indent: u8 = 2,
    /// Only this entity and what hangs from it, with no parent written for
    /// it: a branch saved as a scene of its own, which is then a scene to
    /// make instances of. Null writes the whole world.
    root: ?Entity = null,
};

pub const LoadOptions = struct {
    /// Where reading went wrong and why: a line and a column, or a byte of
    /// CBOR, and the path to the value, such as `/entities/3/Sprite/texture`.
    diagnostics: ?*json.Diagnostics = null,
    /// What the scene's roots - its entities with no parent in it - hang
    /// from: `.none` for the top of the tree.
    parent: Entity = .none,
    /// Read as an instance: its one root is given this UUID, and every other
    /// entity one made of this and the one the file gives it - the same each
    /// time for this instance, and others for another. See
    /// `App.instantiate`. A scene read so has one root, or it is a mistake.
    instance: ?Uuid = null,
    /// Every entity made is added to it, the ones inside instances too. On a
    /// mistake, the ones this read added are despawned again.
    spawned: ?*std.ArrayList(Entity) = null,
    /// The scenes being read around this one: a scene that is an instance
    /// of itself, however deep, is a mistake rather than a loop.
    within: ?*const Nesting = null,
};

/// A scene being read, and the one it is read inside.
pub const Nesting = struct {
    scene: SceneHandle,
    outer: ?*const Nesting = null,

    pub fn holds(self: ?*const Nesting, scene: SceneHandle) bool {
        var at = self;
        while (at) |nesting| : (at = nesting.outer) {
            if (nesting.scene.eql(scene)) return true;
        }
        return false;
    }
};

/// What a load did.
/// Counts, in 32 bits so the whole is small enough to hand a script back.
pub const Loaded = struct {
    /// How many entities it spawned, the ones inside instances too.
    entities: u32 = 0,
    /// Its entities with no parent in it: what hangs from `LoadOptions.parent`.
    roots: u32 = 0,
    /// The one of them, when there is one: what an instance is. `.none` for
    /// a scene of several.
    root: Entity = .none,
    /// Components the file has that nothing here is registered as: kept
    /// with their entities, saved back as they were, and never run. An
    /// editor without the game's components meets these. See `Unknown`.
    components_unknown: u32 = 0,
    /// Entities given a new UUID, because one in the world had the one the
    /// file gave them: the same scene loaded twice, say. References inside
    /// the scene still find them.
    reassigned: u32 = 0,
    /// Files found by their UUID at another path than the scene names: moved
    /// or renamed with their `.uid` files. Saving the scene again writes
    /// where they are now.
    moved: u32 = 0,
    /// Connections made to a signal no component of this build declares, or
    /// to a method the target has not got: kept, saved back as they were,
    /// and never heard. An editor without the game's components meets these.
    connections_unknown: u32 = 0,
    /// Connections passed over because one of their two ends is in neither
    /// the scene nor the world.
    connections_skipped: u32 = 0,
};

//
// Two passes over the tokens, and no tree. The first learns which components
// each entity has and spawns it with all of them, so that the second can
// write every value straight into its cell - and an entity named anywhere in
// the list already exists when a value names it. Numbers stay the digits the
// file has until a field asks for them as its own type, so a `u64` comes
// back to the last digit, which a tree's `i64` could not promise.

/// What scenes can hold, and the components they held that nothing here is
/// registered as. See `registry.zig`.
pub const Registry = @import("registry.zig").Registry;
pub const Unknown = @import("registry.zig").Unknown;
pub const nameOf = @import("registry.zig").nameOf;

/// Writing a world down: see `scene_write.zig`.
pub const save = @import("scene_write.zig").save;
pub const create = @import("scene_write.zig").create;
pub const write = @import("scene_write.zig").write;
pub const writeEmpty = @import("scene_write.zig").writeEmpty;
pub const entityTemplate = @import("scene_write.zig").entityTemplate;
pub const EntityJson = @import("scene_write.zig").EntityJson;

/// Reading one back: see `scene_read.zig`.
pub const load = @import("scene_read.zig").load;
pub const read = @import("scene_read.zig").read;
pub const found = @import("scene_read.zig").found;

/// What a scene says of itself without loading it: see `scene_info.zig`.
pub const Info = @import("scene_info.zig").Info;
pub const readInfo = @import("scene_info.zig").readInfo;
pub const infoOfFile = @import("scene_info.zig").ofFile;
