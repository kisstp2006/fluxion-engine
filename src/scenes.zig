// SPDX-License-Identifier: BSD-3-Clause

//! Scenes as files a game holds: read once, found by a `SceneHandle`, and
//! made into entities as often as it likes - `App.instantiate` - or made the
//! scene the game is playing - `App.changeScene`.
//!
//! ```zig
//! const enemy = try app.loadScene("res://enemies/bat.json");
//! const bat = try app.instantiate(enemy, cave);      // its root, under `cave`
//! app.changeScene(try app.loadScene("res://levels/two.json"));
//! ```
//!
//! What is kept is the file's bytes, as they were read: a scene is read into
//! the world anew every time it is made, which is also what makes two of it
//! two different sets of entities. Nothing is made of it when it is read:
//! whether it is a scene at all is found out when it is.

const file_table = @import("file_table.zig");

/// A scene read: see `Scenes`. What a component names a scene by, and what
/// `App.instantiate` and `App.changeScene` take.
pub const SceneHandle = file_table.Handle("SceneHandle");

/// One scene: where it came from, and what the file said, JSON or CBOR.
pub const Scene = file_table.File;

/// Every scene read, and the handles they are found by.
pub const Scenes = file_table.Table(SceneHandle);
