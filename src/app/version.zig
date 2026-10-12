// SPDX-License-Identifier: BSD-3-Clause

//! How far along a version is, and how it is written with it: `0.3.2-alpha`,
//! `0.3.2-beta`, `0.3.2-rc`, and `0.3.2` once it is released. The engine
//! says its own here, and an editor made with it says its own the same way.
//!
//! A project's file keeps the versions it was last opened with -
//! `application.engine_version` and `editor_version` - so that an editor
//! can say when it is another one's.

const std = @import("std");

pub const Stage = enum {
    /// Being made: what is there may change, and what it writes with it.
    /// Whoever opens it is told so.
    alpha,
    /// All there, and being tried. Said where a version is asked after, and
    /// nowhere else.
    beta,
    /// What the release will be, unless something is found: a release
    /// candidate.
    rc,
    release,

    /// What comes after a version's numbers: `-alpha`, and nothing for a
    /// release.
    pub fn suffix(self: Stage) []const u8 {
        return switch (self) {
            .alpha => "-alpha",
            .beta => "-beta",
            .rc => "-rc",
            .release => "",
        };
    }

    /// The stage as a person reads it, or "" for a release.
    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .alpha => "alpha",
            .beta => "beta",
            .rc => "release candidate",
            .release => "",
        };
    }

    /// Whether whoever opens a version at this stage is warned of it: an
    /// alpha's alone. A beta and a release candidate say what they are
    /// where a version is asked after.
    pub fn warns(self: Stage) bool {
        return self == .alpha;
    }

    /// A version's numbers with its stage after them: `0.3.2-alpha`.
    pub fn text(comptime number: []const u8, comptime of: Stage) []const u8 {
        return number ++ comptime of.suffix();
    }
};

/// How far along this version of the engine is.
pub const stage: Stage = .beta;

/// This engine's version as it is written and shown: `0.3.2-alpha`.
pub const text = Stage.text(@import("engine_options").version, stage);

test "a version is written with its stage after its numbers, but for a release; an alpha alone warns" {
    try std.testing.expectEqualStrings("0.3.2-alpha", Stage.text("0.3.2", .alpha));
    try std.testing.expectEqualStrings("0.3.2-rc", Stage.text("0.3.2", .rc));
    try std.testing.expectEqualStrings("1.0.0", Stage.text("1.0.0", .release));
    try std.testing.expect(Stage.alpha.warns());
    for ([_]Stage{ .beta, .rc, .release }) |stage_of| try std.testing.expect(!stage_of.warns());
    try std.testing.expectEqualStrings("release candidate", Stage.rc.label());
}
