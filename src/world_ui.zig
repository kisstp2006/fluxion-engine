// SPDX-License-Identifier: BSD-3-Clause

const ui = @import("fluxion_ui");

/// How an interface element is pinned to a point in the world.
pub const Placement = struct {
    anchor_x: ui.AlignX = .center,
    anchor_y: ui.AlignY = .bottom,
    offset: ui.geometry.Vec2 = .{ .x = 0, .y = 0 },
    z_index: i16 = 0,
    clip: bool = false,
};
