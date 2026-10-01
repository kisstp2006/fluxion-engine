// SPDX-License-Identifier: BSD-3-Clause

//! File and folder dialogs: the system's own, opened over the window and
//! answered a frame or more later.
//!
//! ```zig
//! browsing = try app.openFolderDialog(.{ .title = "Where the project goes" });
//!
//! // In a system, any frame after:
//! if (app.input.dialogAnswer(browsing)) |paths| {
//!     if (paths.len > 0) useFolder(paths[0]); // none: it was cancelled
//! }
//! ```
//!
//! **Asking returns at once**, with an id, and the loop goes on while the
//! dialog is open. The answer is `app.input`'s in the frame it arrives, for
//! every system of that frame, and gone in the next: the paths are lent, so
//! copy what you keep. One dialog is open at a time - asking while one is
//! open is `error.Unavailable` - and a platform with no dialogs yet answers
//! the same: X11, Wayland, Android.
//!
//! **Headless, a dialog is never answered by itself.** The app hands out ids,
//! and a test answers for the person who is not there with
//! `app.input.answerDialog`, as it clicks with `app.input.apply`.

const platform = @import("fluxion_platform");

/// Whether this build's fluxion-platform has dialogs: every commit from the
/// one that added them. Before it, asking with a window is
/// `error.Unavailable`, and a headless app is the same either way.
pub const available = @hasDecl(platform, "dialog");

pub const Error = platform.Error;

/// Which dialog an answer belongs to. Never `.none` once handed out.
pub const Id = enum(u32) {
    none = 0,
    _,
};

/// One entry in a file dialog's list of types: `.{ .name = "Images",
/// .extensions = &.{ "png", "jpg" } }`, and `"*"` for any file.
pub const Filter = if (available) platform.dialog.Filter else struct {
    name: []const u8,
    extensions: []const []const u8,
};

/// A dialog that picks one file, or several.
pub const FileOptions = struct {
    /// The system's own when null: "Open".
    title: ?[]const u8 = null,
    multiple: bool = false,
    /// None shows every file.
    filters: []const Filter = &.{},
    /// Where it starts, rather than wherever the system remembers.
    initial_folder: ?[]const u8 = null,
};

/// A dialog that picks a folder.
pub const FolderOptions = struct {
    title: ?[]const u8 = null,
    initial_folder: ?[]const u8 = null,
};

/// What a dialog came back with.
pub const Answer = struct {
    id: Id,
    /// Absolute paths - names, in a browser, and for a folder every file in
    /// it - and none when the dialog was cancelled. Lent until the next
    /// frame.
    paths: []const []const u8,
};
