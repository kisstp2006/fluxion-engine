// SPDX-License-Identifier: BSD-3-Clause

//! Textures, animation and things attached to other things.
//!
//! ```bash
//! zig build example-creatures
//! zig build example-creatures -- --backend d3d11
//! zig build example-creatures -- --frames 300 --capture creatures.png
//! ```
//!
//! Arrow keys or WASD steer the one with the ring round it; the rest wander.
//! Escape leaves.
//!
//! Where `pong` shows the loop and the world, this shows the three things a
//! 2D game needs from the *renderer* and how each is spelt:
//!
//! **A sprite sheet is one texture and a `Region`.** Every creature, every
//! eye and every shadow in the window comes out of one PNG, so the whole
//! frame is one draw call however many of them there are. `Region.cell`
//! turns "the third picture along" into the four numbers the shader wants.
//!
//! **An `Animation` is the sheet and a rate.** The engine steps it and writes
//! the cell into the sprite; nothing in this file touches `Sprite.region`
//! after the creature is spawned.
//!
//! **A transform's `parent` is how one thing rides on another.** Each creature
//! is five entities - a body, two eyes, a shadow and a name - and only the
//! body is ever moved. The eyes turn with it because they inherit its
//! rotation; the shadow and the name do not, because neither should tip over
//! when the thing they belong to leans. A child's own numbers stay in its
//! parent's space, so `-4` above the eyes means four above the body wherever
//! the body has got to.
//!
//! **A `Text2D` carries its own words.** The name over each creature is a
//! child entity like an eye is, and the line in the corner is a child of the
//! *camera* - which is the whole of what a heads-up display is here. Every
//! letter of both comes out of one glyph atlas, so all the text in the window
//! is one more draw call and not one per label.
//!
//! The atlas is read from `examples/atlas.png`, and this program is what drew
//! it: `-- --write-atlas examples/atlas.png` puts it back. That is the same
//! bargain `fluxion-rhi` makes with its own atlas - the one binary file in
//! the repository is one the code can account for - and if the file is
//! missing the same pixels are used straight from memory, so a fresh checkout
//! still runs.

const std = @import("std");
const fx = @import("fluxion_engine");

const Transform2D = fx.Transform2D;
const Sprite = fx.Sprite;
const Camera2D = fx.Camera2D;
const Animation = fx.Animation;
const Text2D = fx.Text2D;
const Color = fx.Color;
const App = fx.App;

// -------------------------------------------------------------------------
// The world
// -------------------------------------------------------------------------

const field_width: f32 = 640;
const field_height: f32 = 360;

/// How many wander about. All of them, and everything hanging off them, are
/// one draw call.
const herd = 14;

const walk_speed: f32 = 70;
const player_speed: f32 = 140;

const theme = struct {
    const background: Color = .hex(0x101720);
    const ground: Color = .hex(0x16202B);
    const shadow: Color = .hexa(0x00000055);
    const player: Color = .oklch(0.78, 0.15, 145);
    const eye: Color = .hex(0xF2F5F8);
    const name: Color = .hexa(0xE6E9EFCC);
    const heading: Color = .hex(0x8FA6BF);
};

/// The sheet is four cells across and two down, each 32 pixels square.
const atlas_columns = 4;
const atlas_rows = 2;
const cell_size = 32;

/// Which cell is what. The body is the first row, as four frames of one
/// animation; the second row is the pieces that do not move.
const cell = struct {
    const body_first = 0;
    const body_frames = 4;
    const eye = 4;
    const shadow = 5;
    const ring = 6;
};

// -------------------------------------------------------------------------
// The game's own components
// -------------------------------------------------------------------------

/// Where a creature is heading, and how fast.
const Wander = extern struct {
    dx: f32,
    dy: f32,
    /// Seconds until it picks somewhere else to go.
    until_turn: f32 = 0,
    /// A number of its own, so a herd does not bob in lockstep.
    phase: f32 = 0,
};

/// The one the keys drive. One entity has this; the rest do not.
const Player = extern struct {
    speed: f32 = player_speed,
};

/// A label that belongs to the corner of the screen rather than to a place in
/// the world.
///
/// It is a child of the camera, and the system below puts it where the corner
/// is and scales it against the zoom - so it stays the same size on screen
/// however far in the camera is, which is the whole difference between a
/// heads-up display and a sign in the world. That arithmetic is what the
/// interface layer will do for a game once it exists; until then it is four
/// lines and worth seeing written out.
const Heading = extern struct {
    /// Pixels in from the corner.
    margin: f32 = 14,
};

/// Names to hand out, so a creature is somebody rather than a colour.
const names = [_][]const u8{
    "Bo",   "Pip",  "Ada",  "Juno", "Rex",  "Momo", "Fig",
    "Nell", "Otto", "Sage", "Tam",  "Wren", "Yuki", "Zed",
};

/// What the camera is told to look at.
const Follow = extern struct {
    /// How much of the way to the target the camera moves each second. A
    /// camera that snapped would shake with every step the player takes.
    stiffness: f32 = 6,
};

// -------------------------------------------------------------------------
// Setting the table
// -------------------------------------------------------------------------

fn spawn(app: *App) !void {
    const world = &app.world;

    const sheet = app.assets.loadTexture(atlas_path, .{ .filter = .nearest }) catch |err| blk: {
        // A fresh checkout has no PNG in it until somebody writes one, and a
        // missing file should not be the difference between a program that
        // runs and one that does not.
        std.log.warn("could not read '{s}' ({t}); drawing from the generated atlas", .{ atlas_path, err });
        const pixels = makeAtlas();
        break :blk try app.assets.textureFromPixels(
            atlas_columns * cell_size,
            atlas_rows * cell_size,
            &pixels,
            .{ .filter = .nearest, .label = "atlas" },
        );
    };

    // The first font opened becomes the default, so nothing below has to name
    // it. A missing font is not fatal: the labels simply do not draw.
    _ = app.assets.loadFont(fx.Assets.systemFontPath(), .{}) catch |err| {
        std.log.warn("no font ({t}); the labels will not draw", .{err});
        return;
    };

    _ = try world.spawnWith(.{
        Transform2D.at(field_width / 2, field_height / 2),
        Camera2D{ .zoom = 1 },
        Follow{},
    });

    // A line of text pinned to the camera rather than to the world, which is
    // what a heads-up display is: a child of the camera, so it slides along
    // with it and stays the same size on screen whatever the world does.
    var heading: Text2D = .of("");
    heading.size = 15;
    heading.color = theme.heading;
    heading.layer = 50;

    // The camera is the last thing spawned above, so it is the entity before
    // this one. Naming it directly is what a scene file would do.
    const camera = (try fx.Query(.{ Transform2D, Camera2D }).first(world)).?.entities[0];
    _ = try world.spawnWith(.{
        // Where in the camera's space it goes is worked out every frame by
        // `pinHeading`; this only says whose corner it is.
        Transform2D{ .parent = camera, .inherit_rotation = false },
        heading,
        Heading{},
    });

    // The ground, as one big untextured rectangle behind everything. A sprite
    // with no texture at all, which is why it costs no artwork.
    _ = try world.spawnWith(.{
        Transform2D.at(field_width / 2, field_height / 2),
        Sprite{
            .tint = theme.ground,
            .width = field_width,
            .height = field_height,
            .layer = -100,
        },
    });

    var random: std.Random.DefaultPrng = .init(0x5EED);
    const rand = random.random();

    for (0..herd) |i| {
        const is_player = i == 0;
        const angle = rand.float(f32) * std.math.tau;
        const tint: Color = if (is_player)
            theme.player
        else
            .oklch(0.7, 0.13, rand.float(f32) * 360);

        const body = try world.spawnWith(.{
            // Moved in the fixed stage, so it asks to be drawn between steps.
            Transform2D.at(
                40 + rand.float(f32) * (field_width - 80),
                40 + rand.float(f32) * (field_height - 80),
            ).interpolated(),
            Sprite{
                .texture = sheet,
                .tint = tint,
                .width = 34,
                .height = 34,
                .layer = 0,
            },
            // Four cells of the first row, at eight a second, each creature
            // starting somewhere else in the loop.
            Animation{
                .first = cell.body_first,
                .length = cell.body_frames,
                .columns = atlas_columns,
                .rows = atlas_rows,
                .fps = 8,
                .time = rand.float(f32),
            },
            Wander{
                .dx = @cos(angle),
                .dy = @sin(angle),
                .phase = rand.float(f32) * std.math.tau,
            },
        });

        if (is_player) {
            try world.add(body, Player{});

            // A ring round the one being driven, so it can be found in a
            // crowd. Parented, so it never has to be moved.
            _ = try world.spawnWith(.{
                Transform2D{ .parent = body, .inherit_rotation = false },
                Sprite{
                    .texture = sheet,
                    .region = .cell(cell.ring, atlas_columns, atlas_rows),
                    .tint = tint,
                    .width = 46,
                    .height = 46,
                    .layer = -1,
                },
            });
        }

        // The shadow does not inherit the body's rotation: a shadow on the
        // ground stays flat however much the thing above it leans.
        _ = try world.spawnWith(.{
            Transform2D{ .x = 0, .y = 15, .parent = body, .inherit_rotation = false },
            Sprite{
                .texture = sheet,
                .region = .cell(cell.shadow, atlas_columns, atlas_rows),
                .tint = theme.shadow,
                .width = 30,
                .height = 12,
                .layer = -2,
            },
        });

        // Two eyes, which do turn with it - that is the whole point of them.
        for ([_]f32{ -7, 7 }) |offset| {
            _ = try world.spawnWith(.{
                Transform2D.childOf(body, offset, -4),
                Sprite{
                    .texture = sheet,
                    .region = .cell(cell.eye, atlas_columns, atlas_rows),
                    .tint = theme.eye,
                    .width = 9,
                    .height = 9,
                    .layer = 1,
                },
            });
        }

        // A name over its head. Parented like everything else, so it never
        // has to be moved - and not inheriting the lean, because a name plate
        // that tips over with the thing it names is a name plate nobody can
        // read.
        var plate: Text2D = .of(names[i % names.len]);
        plate.size = 13;
        plate.color = theme.name;
        plate.alignment = .center;
        plate.layer = 2;

        _ = try world.spawnWith(.{
            Transform2D{ .x = 0, .y = -32, .parent = body, .inherit_rotation = false },
            plate,
        });
    }
}

// -------------------------------------------------------------------------
// The systems
// -------------------------------------------------------------------------

const Wanderers = fx.Query(.{ Transform2D, Wander });
const Players = fx.Query(.{ Transform2D, Wander, Player });
const Cameras = fx.Query(.{ Transform2D, Camera2D, Follow });

fn readKeys(app: *App) !void {
    if (app.input.justPressed(.escape)) app.quit();
}

/// Everything that wanders picks a new direction now and then, and turns to
/// face the way it is going.
fn wander(app: *App) !void {
    const dt = app.time.fixed_delta;
    const elapsed: f32 = @floatCast(app.time.elapsed);

    var it = try Wanderers.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Wander)) |*place, *drift| {
            drift.until_turn -= dt;
            if (drift.until_turn <= 0) {
                // Deterministic and cheap: the phase is a number per creature
                // and the clock does the rest, so a capture at frame three
                // hundred is the same picture every run.
                const angle = @sin(elapsed * 0.7 + drift.phase) * std.math.tau;
                drift.dx = @cos(angle);
                drift.dy = @sin(angle);
                drift.until_turn = 1.5 + @abs(@sin(drift.phase)) * 2;
            }

            place.x += drift.dx * walk_speed * dt;
            place.y += drift.dy * walk_speed * dt;

            // Turned back at the edges rather than wrapped, so nothing ever
            // teleports across the screen and every creature stays in shot.
            if (place.x < 20 or place.x > field_width - 20) {
                drift.dx = -drift.dx;
                place.x = std.math.clamp(place.x, 20, field_width - 20);
            }
            if (place.y < 20 or place.y > field_height - 20) {
                drift.dy = -drift.dy;
                place.y = std.math.clamp(place.y, 20, field_height - 20);
            }

            // A gentle lean into the direction of travel. Because the eyes
            // are parented, they lean with it and the shadow does not.
            place.rotation = drift.dx * 0.25;
        }
    }
}

/// The keys drive one creature, over the top of its wandering.
fn drive(app: *App) !void {
    const dt = app.time.fixed_delta;
    const dx = app.input.axis(.a, .d) + app.input.axis(.left, .right);
    const dy = app.input.axis(.w, .s) + app.input.axis(.up, .down);
    if (dx == 0 and dy == 0) return;

    const length = @sqrt(dx * dx + dy * dy);

    var it = try Players.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Wander), chunk.slice(Player)) |*place, *drift, player| {
            place.x += dx / length * player.speed * dt;
            place.y += dy / length * player.speed * dt;
            place.x = std.math.clamp(place.x, 20, field_width - 20);
            place.y = std.math.clamp(place.y, 20, field_height - 20);

            // Keep the wandering pointed the way the player is going, so
            // letting go does not snap it round.
            drift.dx = dx / length;
            drift.dy = dy / length;
            drift.until_turn = 1;
        }
    }
}

const Headings = fx.Query(.{ Text2D, Heading, Transform2D });

/// Write what is going on into the pinned label, and hold it in the corner.
///
/// `print` formats straight into the component, which is what a score, a
/// timer and a frame counter all are: a number that changed since last frame.
///
/// In `.late` and after the camera has been moved, because where the corner
/// of the screen *is* depends on where the camera ended up and how far in it
/// is - and the engine resolves parents after this stage, so writing the
/// offset here is writing it in time.
fn pinHeading(app: *App) !void {
    const zoom = blk: {
        var cameras = try fx.Query(.{Camera2D}).over(&app.world);
        while (cameras.next()) |chunk| {
            const found = chunk.slice(Camera2D);
            if (found.len > 0) break :blk @max(found[0].zoom, 0.0001);
        }
        break :blk 1;
    };

    const half_width = @as(f32, @floatFromInt(app.width)) / (2 * zoom);
    const half_height = @as(f32, @floatFromInt(app.height)) / (2 * zoom);

    var it = try Headings.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Text2D), chunk.slice(Heading), chunk.slice(Transform2D)) |*label, pinned, *place| {
            label.print("{d} creatures  {d} fps", .{
                herd,
                @as(u32, @intFromFloat(app.time.fps())),
            });

            // The top left corner of the view, in the camera's own space -
            // which is what this transform is in, because the camera is its
            // parent - and a scale that undoes the zoom, so the letters are
            // the size they say they are in pixels.
            const inset = pinned.margin / zoom;
            place.x = -half_width + inset;
            place.y = -half_height + inset;
            place.scale_x = 1 / zoom;
            place.scale_y = 1 / zoom;
        }
    }
}

/// The camera follows the player, part of the way each frame.
///
/// In `.late`, so it reads where the player ended up this frame rather than
/// where it was at the end of the last one.
fn followPlayer(app: *App) !void {
    var target: ?Transform2D = null;
    {
        var it = try Players.over(&app.world);
        while (it.next()) |chunk| {
            const places = chunk.slice(Transform2D);
            if (places.len > 0) target = places[0];
        }
    }
    const looking_at = target orelse return;

    const width: f32 = @floatFromInt(app.width);
    const height: f32 = @floatFromInt(app.height);
    const dt = app.time.delta;

    var it = try Cameras.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Camera2D), chunk.slice(Follow)) |*place, *camera, follow| {
            // Frame-rate independent easing: the fraction left over shrinks
            // exponentially, which a plain `lerp(a, b, k)` does not do and is
            // why a camera tuned at sixty hertz drifts at a hundred and
            // forty-four.
            const k = 1 - @exp(-follow.stiffness * dt);
            place.x += (looking_at.x - place.x) * k;
            place.y += (looking_at.y - place.y) * k;

            // Close enough to fill the window with rather less than the whole
            // field, so following it is worth doing at all.
            camera.zoom = @min(width / (field_width * 0.7), height / (field_height * 0.7));

            // Held inside the field, which is Godot's camera limits and the
            // difference between a game and a demonstration: without it, a
            // player walking into a corner is looking at half a screen of
            // nothing. Half the *view* is the margin, and a view wider than
            // the field is centred rather than clamped to a range that has
            // its ends the wrong way round.
            const half_view_x = width / (2 * camera.zoom);
            const half_view_y = height / (2 * camera.zoom);
            place.x = if (half_view_x * 2 >= field_width)
                field_width / 2
            else
                std.math.clamp(place.x, half_view_x, field_width - half_view_x);
            place.y = if (half_view_y * 2 >= field_height)
                field_height / 2
            else
                std.math.clamp(place.y, half_view_y, field_height - half_view_y);
        }
    }
}

// -------------------------------------------------------------------------
// The atlas
// -------------------------------------------------------------------------

const atlas_path = "examples/atlas.png";

/// The sheet this example draws from, and the code that drew it.
///
/// Four frames of a body squashing and stretching, then an eye, a shadow and
/// a ring. White on transparent throughout, so the tint in each sprite is
/// what gives it its colour - which is why fourteen differently coloured
/// creatures are still one texture and one draw call.
fn makeAtlas() [atlas_columns * cell_size * atlas_rows * cell_size * 4]u8 {
    const width = atlas_columns * cell_size;
    const height = atlas_rows * cell_size;
    var pixels: [width * height * 4]u8 = @splat(0);

    for (0..height) |y| {
        for (0..width) |x| {
            const index = (y * width + x) * 4;
            const column = x / cell_size;
            const row = y / cell_size;
            const which = row * atlas_columns + column;

            // Where this pixel is inside its own cell, from -16 to 16.
            const cx = @as(f32, @floatFromInt(x % cell_size)) + 0.5 - cell_size / 2;
            const cy = @as(f32, @floatFromInt(y % cell_size)) + 0.5 - cell_size / 2;

            var level: f32 = 0;
            var white: f32 = 1;

            switch (which) {
                // The body, squashing and stretching over four frames.
                0, 1, 2, 3 => {
                    // Named, because Zig will not index an array literal
                    // where it stands - it has to be something with an
                    // address before it can be subscripted.
                    const squashes = [_]f32{ 1.0, 0.92, 1.0, 1.08 };
                    const squash = squashes[which];
                    const rx = 13.0 / squash;
                    const ry = 13.0 * squash;
                    level = coverage(1 - @sqrt((cx / rx) * (cx / rx) + (cy / ry) * (cy / ry)), 0.06);
                },
                // An eye: white, with a dark pupil looking slightly down.
                cell.eye => {
                    level = coverage(1 - @sqrt(cx * cx + cy * cy) / 7.0, 0.12);
                    const pupil = coverage(1 - @sqrt(cx * cx + (cy - 1.5) * (cy - 1.5)) / 3.0, 0.3);
                    white = 1 - pupil;
                },
                // A shadow: a wide, soft ellipse.
                cell.shadow => {
                    const d = @sqrt((cx / 14.0) * (cx / 14.0) + (cy / 6.0) * (cy / 6.0));
                    level = coverage(1 - d, 0.45);
                },
                // A ring, for marking the one being driven.
                cell.ring => {
                    const r = @sqrt(cx * cx + cy * cy);
                    level = coverage(1 - @abs(r - 13.5) / 1.6, 0.5);
                },
                else => {},
            }

            if (level <= 0) continue;
            const shade: u8 = @intFromFloat(std.math.clamp(white, 0, 1) * 255);
            pixels[index + 0] = shade;
            pixels[index + 1] = shade;
            pixels[index + 2] = shade;
            pixels[index + 3] = @intFromFloat(std.math.clamp(level, 0, 1) * 255);
        }
    }
    return pixels;
}

/// A soft edge: one inside the shape, zero outside, and a `softness`-wide
/// ramp between. Without it every curve in the sheet is a staircase.
fn coverage(signed: f32, softness: f32) f32 {
    return std.math.clamp(signed / softness + 0.5, 0, 1);
}

// -------------------------------------------------------------------------
// The program
// -------------------------------------------------------------------------

const Options = struct {
    backend: App.Backend = .auto,
    frames: ?u32 = null,
    width: u32 = 960,
    height: u32 = 540,
    capture: ?[]const u8 = null,
    /// Write the sheet this repository ships and stop.
    write_atlas: ?[]const u8 = null,
};

fn parse(arguments: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        const argument = arguments[i];
        const value = if (i + 1 < arguments.len) arguments[i + 1] else null;

        if (std.mem.eql(u8, argument, "--backend")) {
            const name = value orelse return error.MissingValue;
            options.backend = if (std.mem.eql(u8, name, "d3d11"))
                .d3d11
            else if (std.mem.eql(u8, name, "gl"))
                .gl
            else
                return error.UnknownBackend;
            i += 1;
        } else if (std.mem.eql(u8, argument, "--frames")) {
            options.frames = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
            i += 1;
        } else if (std.mem.eql(u8, argument, "--width")) {
            options.width = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
            i += 1;
        } else if (std.mem.eql(u8, argument, "--height")) {
            options.height = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
            i += 1;
        } else if (std.mem.eql(u8, argument, "--capture")) {
            options.capture = value orelse return error.MissingValue;
            i += 1;
        } else if (std.mem.eql(u8, argument, "--write-atlas")) {
            options.write_atlas = value orelse return error.MissingValue;
            i += 1;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    const options = try parse(try init.minimal.args.toSlice(init.arena.allocator()));

    // Writing the sheet needs no window, no device and no display.
    if (options.write_atlas) |path| {
        const pixels = makeAtlas();
        try fx.image.png.writeFile(gpa, init.io, path, .{
            .width = atlas_columns * cell_size,
            .height = atlas_rows * cell_size,
            .pixels = &pixels,
            .row_pitch = atlas_columns * cell_size * 4,
            // Without this the alpha is dropped on the way out - the default
            // is off, because a screenshot has no alpha worth keeping and a
            // texture has nothing but. A sheet written without it draws as a
            // row of black squares, which is exactly what it looks like.
        }, .{ .keep_alpha = true });
        try out.print("wrote {s}\n", .{path});
        try out.flush();
        return;
    }

    const app = App.create(gpa, .{
        .title = "Creatures - Fluxion Engine",
        .width = options.width,
        .height = options.height,
        .backend = options.backend,
        .frames = if (options.capture != null) options.frames orelse 300 else options.frames,
        .background = theme.background,
        .io = init.io,
    }) catch |err| switch (err) {
        error.NoDisplay => {
            try out.print("no display, so nothing to look at\n", .{});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer app.destroy();

    // A capture must not depend on how long the machine took.
    if (options.capture != null) app.time.source = .{ .fixed = 1.0 / 60.0 };

    try out.print("{f}\n", .{app.device.info()});
    try out.print("Arrows or WASD to steer the one with the ring; Escape to leave.\n", .{});
    try out.flush();

    try app.addNamedSystem(.startup, "spawn", spawn);
    try app.addNamedSystem(.input, "read keys", readKeys);
    try app.addNamedSystem(.fixed, "wander", wander);
    try app.addNamedSystem(.fixed, "drive", drive);
    try app.addNamedSystem(.late, "follow player", followPlayer);
    try app.addNamedSystem(.late, "pin heading", pinHeading);

    app.run() catch |err| {
        if (app.schedule.failed) |failure| {
            try out.print(
                "the '{s}' system in stage .{t} failed: {t}\n",
                .{ failure.name, failure.stage, failure.err },
            );
            try out.flush();
        }
        return err;
    };

    try out.print(
        "{d} frames, {d} entities, {d} sprites in {d} draw call(s) on the last one\n",
        .{ app.time.frame, app.world.count(), app.sprites.drawn, app.sprites.draw_calls },
    );

    if (options.capture) |path| {
        const pixels = try app.capture(gpa, options.width, options.height);
        defer gpa.free(pixels);

        try fx.image.png.writeFile(gpa, init.io, path, .{
            .width = options.width,
            .height = options.height,
            .pixels = pixels,
            .row_pitch = options.width * 4,
        }, .{});
        try out.print("wrote {s}\n", .{path});
    }

    try out.flush();
}
