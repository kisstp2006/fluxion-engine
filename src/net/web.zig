// SPDX-License-Identifier: BSD-3-Clause

//! The game's web requests: fluxion-net's client, made the first time the
//! game asks, its answers collected once a frame - even in the background,
//! so nothing on its way is lost - and kept until whoever asked takes them.
//! A script's are taken by the scripts the same frame; a Zig game takes its
//! own with `App.takeWebAnswer`.
//!
//! ```zig
//! const asked = try app.webSend(.{ .url = "https://example.com/scores" });
//! // a frame or a few later:
//! if (app.takeWebAnswer(asked)) |answer| {
//!     var done = answer;
//!     defer done.deinit();
//!     const response = done.result catch |err| return log(err, done.reason);
//!     show(response.body);
//! }
//! ```

const std = @import("std");
const net = @import("fluxion_net");

const App = @import("../App.zig");

const log = std.log.scoped(.fluxion_engine);

pub const Request = net.Request;
pub const Response = net.Response;
pub const Done = net.Done;
pub const Id = net.Id;
pub const Progress = net.Progress;
pub const Error = net.Error;

/// How long a program that is ending waits for what it asked last - a
/// session closed, a score sent as the player quit.
pub const last_wait_ms = 3000;

pub const Web = struct {
    client: ?net.Client = null,
    /// Answers collected and not yet taken.
    answers: std.ArrayList(Done) = .empty,

    /// What a program that ends asked last is waited for, a moment, before
    /// anything still on its way is stopped.
    pub fn deinit(web: *Web, app: *App) void {
        if (web.client) |*client| {
            if (client.pending() > 0) {
                const io = app.io.?;
                const until = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(last_wait_ms));
                while (client.pending() > 0 and std.Io.Clock.awake.now(io).nanoseconds < until.nanoseconds) {
                    collect(app) catch break;
                    io.sleep(.fromMilliseconds(5), .awake) catch break;
                }
            }
            client.deinit();
        }
        for (web.answers.items) |*done| done.deinit();
        web.answers.deinit(app.gpa);
        web.* = undefined;
    }

    fn clientOf(web: *Web, app: *App) error{NoIo}!*net.Client {
        if (web.client) |*made| return made;
        const io = app.io orelse return error.NoIo;
        const network = if (app.project.settings) |s| s.network else @import("../project/settings.zig").Network{};
        web.client = .init(app.gpa, io, .{
            .max_running = @max(network.max_requests, 1),
            .allow_plain_http = network.allow_plain_http,
            .user_agent = "fluxion-engine",
        });
        return &web.client.?;
    }
};

/// Asks: see `net.Request`. Its answer is kept, once it comes, for
/// `takeAnswer`.
pub fn send(app: *App, request: Request) (error{ NoIo, OutOfMemory })!Id {
    const client = try app.web.clientOf(app);
    return client.send(request);
}

/// The answer to a request, once it has come; null before. Taken: the
/// caller `deinit`s it.
pub fn takeAnswer(app: *App, id: Id) ?Done {
    for (app.web.answers.items, 0..) |done, i| {
        if (done.id == id) return app.web.answers.orderedRemove(i);
    }
    return null;
}

/// How far a request has come; null for one that has ended or never was.
pub fn progress(app: *App, id: Id) ?Progress {
    const client = if (app.web.client) |*made| made else return null;
    return client.progress(id);
}

/// Stops a request: its answer, when collected, is `error.Cancelled`.
pub fn cancel(app: *App, id: Id) void {
    if (app.web.client) |*client| client.cancel(id);
}

/// The answers that came since the last frame, kept for whoever asked. A
/// pass of every frame's: see `app/frame_steps.zig`.
pub fn collect(app: *App) anyerror!void {
    const client = if (app.web.client) |*made| made else return;
    var into: [16]Done = undefined;
    while (true) {
        const done = client.update(&into);
        for (done, 0..) |d, i| {
            app.web.answers.append(app.gpa, d) catch |err| {
                for (done[i..]) |*rest| rest.deinit();
                return err;
            };
        }
        if (done.len < into.len) return;
    }
}
