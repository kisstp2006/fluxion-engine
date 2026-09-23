// SPDX-License-Identifier: BSD-3-Clause

//! A game: two paddles, a ball, and a scoreboard made of the same sprites as
//! everything else.
//!
//! ```bash
//! zig build example-pong
//! zig build example-pong -- --backend d3d11
//! zig build example-pong -- --frames 600
//! ```
//!
//! W and S on the left, up and down on the right, F11 to fill the screen,
//! Escape to leave. The ball serves itself a moment after each point, or at
//! once if you press space. A controller each works too: the left stick or
//! the d-pad moves a bat, A serves and Start begins again.
//!
//! It is here to be read as much as played, because it is the shortest honest
//! answer to "what does a game made with this look like". Five things are
//! worth noticing:
//!
//! **The game's components are the game's.** `Velocity`, `Paddle`, `Ball` and
//! `Score` are declared in this file and the engine has never heard of them.
//! What the engine knows is `Transform2D` and `Sprite`, because those are
//! what the renderer reads - everything else about what a thing *is* belongs
//! to whoever is making the thing.
//!
//! **The controls are data.** Each bat holds an `AxisBinding` - its keys, its
//! controller's stick and d-pad - so remapping them is writing a component,
//! and saving them is saving the world. `input.axisOf` adds the sources up.
//!
//! **Movement is in `.fixed`.** The ball moves at a constant step so it
//! bounces the same way on a fast machine and a slow one, and `time.delta` is
//! that step while the stage runs. The ball and the paddles are
//! `interpolated`, so on a screen faster than sixty hertz they are drawn
//! between their last two steps rather than jumping from one to the next.
//!
//! **The play field is a fixed size and the window is not.** The camera is
//! told the size of the field - `Camera2D.fitting` - and the engine scales it
//! to whatever the window is, so resizing changes how much of the screen the
//! game takes and never how the game plays.
//!
//! **The score is a component on an entity**, the only one of its kind, and
//! `app.single(Score)` is how every system finds it. A singleton entity is the
//! ECS answer to state that is not about a thing, and it is saved and loaded
//! with the world for free.

const std = @import("std");
const fx = @import("fluxion_engine");

const Transform2D = fx.Transform2D;
const Sprite = fx.Sprite;
const Camera2D = fx.Camera2D;
const Color = fx.Color;
const App = fx.App;

// -------------------------------------------------------------------------
// The rules
// -------------------------------------------------------------------------

/// The world the game is played in. Nothing here is in pixels: the camera
/// decides how many of those one unit is worth.
const field_width: f32 = 640;
const field_height: f32 = 360;

const paddle_width: f32 = 10;
const paddle_height: f32 = 64;
const paddle_inset: f32 = 28;
const ball_size: f32 = 10;

/// How much faster the ball gets on every return, and how fast it may end up.
const speed_up: f32 = 1.06;
const ball_start_speed: f32 = 240;
const ball_max_speed: f32 = 620;

/// Points to win, and how many pips a scoreboard has room for.
const winning_score: u8 = 9;

/// How long the ball sits in the middle before serving itself.
const serve_pause: f32 = 1.2;

const theme = struct {
    const background: Color = .hex(0x0B0E14);
    const ink: Color = .hex(0xE6E9EF);
    const left: Color = .oklch(0.72, 0.15, 250);
    const right: Color = .oklch(0.74, 0.15, 35);
    const net: Color = .hexa(0xE6E9EF22);
};

// -------------------------------------------------------------------------
// The game's own components
// -------------------------------------------------------------------------

/// Units a second. The engine has no opinion about this; it is a component
/// like any other, and the system below is what gives it meaning.
const Velocity = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A bat, and what drives it.
const Paddle = extern struct {
    /// Its keys, and the stick and d-pad of one controller: slot zero - on
    /// Windows, the first controller XInput numbers - for the left bat and
    /// slot one for the right, so two players with a pad each need no set-up.
    move: fx.AxisBinding,
    speed: f32 = 300,
};

/// There is one of these. Its speed is on it rather than in a constant so
/// that a rally can make it faster.
const Ball = extern struct {
    speed: f32 = ball_start_speed,
    /// Which way the next serve goes: 1 right, -1 left.
    towards: f32 = 1,
};

/// The pause before a serve: the ball's own `fx.Timer`, counted by fixed
/// steps so the pause is the same length on every machine. Its `timeout`
/// serves; space cuts it short.
const serve_wait: fx.Timer = .{ .wait_time = serve_pause, .one_shot = true, .autostart = true, .clock = .fixed };

/// The whole of the game's state, on one entity.
const Score = extern struct {
    left: u8 = 0,
    right: u8 = 0,
    /// Zero while the game is on; 1 or 2 once somebody has won.
    winner: u8 = 0,
};

/// One square of a scoreboard. `index` is which point it stands for.
const Pip = extern struct {
    index: u8,
    /// 1 for the left player, 2 for the right.
    side: u8,
};

// -------------------------------------------------------------------------
// Setting the table
// -------------------------------------------------------------------------

fn spawn(app: *App) !void {
    const world = &app.world;

    // The camera looks at the middle of the field and always shows all of
    // it, whatever shape the window is: the engine works out the zoom.
    _ = try world.spawnWith(.{
        Transform2D.at(field_width / 2, field_height / 2),
        Camera2D.fitting(field_width, field_height),
    });

    // The net, drawn as a column of faint dashes. Sprites with no texture at
    // all: the renderer reaches for its white texel and the tint is the
    // colour, which is why a rectangle costs no artwork and no second
    // pipeline.
    var y: f32 = 12;
    while (y < field_height) : (y += 26) {
        _ = try world.spawnWith(.{
            Transform2D.at(field_width / 2, y),
            Sprite{ .tint = theme.net, .width = 3, .height = 14, .layer = -10 },
        });
    }

    _ = try world.spawnWith(.{
        Transform2D.at(paddle_inset, field_height / 2).interpolated(),
        Sprite{ .tint = theme.left, .width = paddle_width, .height = paddle_height },
        Velocity{},
        Paddle{ .move = fx.AxisBinding.keys(.w, .s).withPadY(0) },
    });

    _ = try world.spawnWith(.{
        Transform2D.at(field_width - paddle_inset, field_height / 2).interpolated(),
        Sprite{ .tint = theme.right, .width = paddle_width, .height = paddle_height },
        Velocity{},
        Paddle{ .move = fx.AxisBinding.keys(.up, .down).withPadY(1) },
    });

    const ball = try world.spawnWith(.{
        Transform2D.at(field_width / 2, field_height / 2).interpolated(),
        Sprite{ .tint = theme.ink, .width = ball_size, .height = ball_size, .layer = 10 },
        Velocity{},
        Ball{},
        serve_wait,
    });
    try app.signal(ball, fx.Timer, .timeout).connectFn(serve, .{});

    _ = try world.spawnWith(.{Score{}});

    // The scoreboard, spawned once and hidden. Toggling `visible` costs a
    // byte; spawning and despawning would move rows between archetypes every
    // time somebody scored.
    for (0..winning_score) |i| {
        const at: f32 = @floatFromInt(i);
        _ = try world.spawnWith(.{
            Transform2D.at(field_width / 2 - 30 - at * 14, 26),
            Sprite{ .tint = theme.left, .width = 9, .height = 9, .visible = false },
            Pip{ .index = @intCast(i), .side = 1 },
        });
        _ = try world.spawnWith(.{
            Transform2D.at(field_width / 2 + 30 + at * 14, 26),
            Sprite{ .tint = theme.right, .width = 9, .height = 9, .visible = false },
            Pip{ .index = @intCast(i), .side = 2 },
        });
    }
}

// -------------------------------------------------------------------------
// The systems
// -------------------------------------------------------------------------

const Paddles = fx.Query(.{ Transform2D, Velocity, Paddle });
const Balls = fx.Query(.{ Transform2D, Velocity, Ball, fx.Timer });
const Pips = fx.Query(.{ Sprite, Pip });

/// Space serves and R starts again - and A and Start on any controller do
/// the same. Escape and F11 are the engine's; see `main`.
fn readKeys(app: *App) !void {
    // Any controller, not a particular one: whoever reaches for a button
    // first may press it.
    const pads = app.input.anyPad();

    if (app.input.justPressed(.r) or pads.justPressed(.start)) {
        if (app.single(Score)) |score| score.* = .{};
        try resetBall(app, 1);
    }

    if (app.input.justPressed(.space) or pads.justPressed(.a)) {
        var it = try Balls.over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(fx.Timer)) |*wait| {
                if (wait.isStopped()) continue;
                wait.stop();
                try serve(app, .{});
            }
        }
    }
}

/// Serve the ball: what its pause's `timeout` calls.
///
/// Heard before the fixed stage of the step the pause ran out in, so a
/// capture taken at frame two hundred shows the same rally every time it is
/// run.
fn serve(app: *App, _: struct {}) !void {
    var it = try Balls.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Ball), chunk.slice(Velocity)) |*ball, *velocity| {
            // Never quite flat, so a serve always has somewhere to go.
            velocity.* = .{
                .x = ball.speed * ball.towards,
                .y = ball.speed * 0.35 * ball.towards,
            };
        }
    }
}

/// Turn the controls into speeds, and the speeds into positions.
///
/// Both halves are in the fixed stage, so how fast a paddle moves does not
/// depend on how fast the machine draws. A held key and a pushed stick are
/// levels rather than edges, so they are safe to read here.
fn drivePaddles(app: *App) !void {
    var it = try Paddles.over(&app.world);
    while (it.next()) |chunk| {
        // Three slices over one archetype's rows, lined up. This is the loop
        // the whole archetype layout exists for: no pointer chasing, no
        // branch asking what each entity is.
        const places = chunk.slice(Transform2D);
        const speeds = chunk.slice(Velocity);
        const paddles = chunk.slice(Paddle);

        for (places, speeds, paddles) |*place, *speed, paddle| {
            speed.y = app.input.axisOf(paddle.move) * paddle.speed;
            place.y += speed.y * app.time.delta;
            place.y = std.math.clamp(
                place.y,
                paddle_height / 2,
                field_height - paddle_height / 2,
            );
        }
    }
}

/// The ball: move it, bounce it, and give a point away when it goes past.
fn moveBall(app: *App) !void {
    const dt = app.time.delta;

    // The paddles are collected first rather than queried inside the ball
    // loop, because two iterators over one world at once is a thing that
    // works right up until one of them changes it.
    var bats: [4]Bat = undefined;
    var bat_count: usize = 0;
    {
        var it = try Paddles.over(&app.world);
        while (it.next()) |chunk| {
            for (chunk.slice(Transform2D)) |place| {
                if (bat_count == bats.len) break;
                bats[bat_count] = .{ .x = place.x, .y = place.y };
                bat_count += 1;
            }
        }
    }

    var scored: f32 = 0;

    var it = try Balls.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Velocity), chunk.slice(Ball), chunk.slice(fx.Timer)) |*place, *speed, *ball, wait| {
            if (!wait.isStopped()) continue;

            place.x += speed.x * dt;
            place.y += speed.y * dt;

            // The top and the bottom of the field.
            const half = ball_size / 2;
            if (place.y < half and speed.y < 0) {
                place.y = half;
                speed.y = -speed.y;
            }
            if (place.y > field_height - half and speed.y > 0) {
                place.y = field_height - half;
                speed.y = -speed.y;
            }

            for (bats[0..bat_count]) |bat| {
                if (!overlaps(place.*, bat)) continue;
                // Only turn a ball that is heading into the bat. Without this
                // a ball that clips a corner gets caught inside it and
                // flickers, which is the oldest bug in the oldest game.
                const heading_in = (bat.x < field_width / 2 and speed.x < 0) or
                    (bat.x > field_width / 2 and speed.x > 0);
                if (!heading_in) continue;

                // Where it hit decides where it goes: the middle sends it
                // back flat, the edges send it away at an angle. That one
                // line is the whole of what makes the game playable.
                const offset = (place.y - bat.y) / (paddle_height / 2);
                ball.speed = @min(ball.speed * speed_up, ball_max_speed);
                speed.x = if (speed.x < 0) ball.speed else -ball.speed;
                speed.y = std.math.clamp(offset, -1, 1) * ball.speed * 0.75;
                place.x = if (speed.x > 0)
                    bat.x + paddle_width / 2 + half
                else
                    bat.x - paddle_width / 2 - half;
            }

            if (place.x < -ball_size) scored = 2;
            if (place.x > field_width + ball_size) scored = 1;
        }
    }

    if (scored != 0) {
        const winner: u8 = if (scored == 1) 1 else 2;
        award(app, winner);
        // Served towards whoever just lost the point, which is the rule
        // everywhere and stops one player being served at twice running.
        try resetBall(app, if (winner == 1) -1 else 1);
    }
}

const Bat = struct { x: f32, y: f32 };

fn overlaps(place: Transform2D, bat: Bat) bool {
    return @abs(place.x - bat.x) < (paddle_width + ball_size) / 2 and
        @abs(place.y - bat.y) < (paddle_height + ball_size) / 2;
}

fn award(app: *App, side: u8) void {
    const score = app.single(Score) orelse return;
    if (score.winner != 0) return;

    if (side == 1) score.left += 1 else score.right += 1;
    if (score.left >= winning_score) score.winner = 1;
    if (score.right >= winning_score) score.winner = 2;
}

fn resetBall(app: *App, towards: f32) !void {
    var it = try Balls.over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(Transform2D), chunk.slice(Velocity), chunk.slice(Ball), chunk.slice(fx.Timer)) |*place, *speed, *ball, *wait| {
            place.* = Transform2D.at(field_width / 2, field_height / 2).interpolated();
            speed.* = .{};
            ball.* = .{ .towards = if (towards == 0) ball.towards else towards };
            wait.start(-1);
        }
    }
}

/// Show one pip per point. The scoreboard is sprites, like everything else.
fn showScore(app: *App) !void {
    const score = app.single(Score) orelse return;

    var it = try Pips.over(&app.world);
    while (it.next()) |pips| {
        for (pips.slice(Sprite), pips.slice(Pip)) |*sprite, pip| {
            const points = if (pip.side == 1) score.left else score.right;
            sprite.visible = pip.index < points;
        }
    }
}

/// A won game pulses the winner's colour, which is the whole of the
/// celebration a game with no text can manage.
fn celebrate(app: *App) !void {
    const score = app.single(Score) orelse return;
    if (score.winner == 0) return;

    const pulse = 0.5 + 0.5 * @sin(@as(f32, @floatCast(app.time.elapsed)) * 6);
    const base = if (score.winner == 1) theme.left else theme.right;
    app.background = Color.mix(theme.background, base.withAlpha(1), pulse * 0.25);
}

// -------------------------------------------------------------------------
// The program
// -------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    // The engine's own flags - `--backend`, `--width`, `--height`, `--frames`
    // and `--capture` - and no others: pong has none of its own.
    const flags = try App.parseFlags(App.Flags, try init.minimal.args.toSlice(init.arena.allocator()));

    const app = App.create(gpa, flags.apply(.{
        .title = "Pong - Fluxion Engine",
        .width = 960,
        .height = 540,
        .background = theme.background,
        .io = init.io,
        .quit_key = .escape,
        .fullscreen_key = .f11,
    })) catch |err| switch (err) {
        error.NoDisplay => {
            try out.print("no display, so nothing to play on\n", .{});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer app.destroy();

    // The camera fits the field to whatever the window is, so any size plays
    // the same - down to about half the field, below which the ball is a
    // speck. Said once here, and the window is never dragged smaller.
    try app.setWindowSizeLimits(.{
        .min_width = @intFromFloat(field_width / 2),
        .min_height = @intFromFloat(field_height / 2),
    });

    try out.print("{f}\n", .{app.device.info()});
    try out.print("W/S and Up/Down to play, space to serve, R to start again, F11 to fill the screen, Escape to leave.\n", .{});
    try out.print("Or a controller each: left stick or d-pad to move, A to serve, Start to begin again.\n", .{});
    try out.flush();

    try app.addSystem(.startup, "spawn", spawn);
    try app.addSystem(.input, "read keys", readKeys);
    try app.addSystem(.fixed, "drive paddles", drivePaddles);
    try app.addSystem(.fixed, "move ball", moveBall);
    try app.addSystem(.update, "show score", showScore);
    try app.addSystem(.update, "celebrate", celebrate);

    app.run() catch |err| {
        // The schedule remembers which system it was, which the error value
        // cannot say on its own.
        if (app.schedule.failed) |failure| try out.print("{f}\n", .{failure});
        try out.flush();
        return err;
    };

    try out.print(
        "{d} frames, {d} sprites in {d} draw call(s) on the last one\n",
        .{ app.time.frame, app.sprites.drawn, app.sprites.draw_calls },
    );
    try out.print("time per system on the last frame:\n{f}", .{app.schedule});

    if (flags.capture) |path| {
        try app.saveCapture(path);
        try out.print("wrote {s}\n", .{path});
    }

    try out.flush();
}
