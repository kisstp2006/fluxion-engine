// SPDX-License-Identifier: BSD-3-Clause

//! Networked play on this machine: a server and its players, each an app of
//! its own over loopback UDP - joining, their numbers, who hears of whom,
//! messages on every channel and passed on between players, a kick, the
//! server closing, a LAN search - and the same from scripts, any value
//! sent and coming out as it went in.

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const flux = @import("fluxion_script");
const net_access = @import("../script/net_access.zig");

fn headless() !*App {
    return App.create(testing.allocator, .{ .headless = true, .io = testing.io });
}

/// A frame of each, until `done` holds - for five seconds at most.
fn until(apps: []const *App, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    var frames: usize = 0;
    while (frames < 1000) : (frames += 1) {
        for (apps) |app| _ = try app.step();
        if (done(context)) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TestTimedOut;
}

/// What an app heard, kept across frames.
const Heard = struct {
    events: std.ArrayList(Kept) = .empty,

    const Kept = struct { kind: App.SessionEvent.Kind, peer: u32, data: []u8, reason: App.SessionReason, channel: App.SessionChannel };

    fn take(self: *Heard, app: *App) !void {
        for (app.sessionEvents()) |e| try self.events.append(testing.allocator, .{
            .kind = e.kind,
            .peer = e.peer,
            .data = try testing.allocator.dupe(u8, e.data),
            .reason = e.reason,
            .channel = e.channel,
        });
    }

    fn deinit(self: *Heard) void {
        for (self.events.items) |e| testing.allocator.free(e.data);
        self.events.deinit(testing.allocator);
    }

    fn find(self: *const Heard, kind: App.SessionEvent.Kind, peer: ?u32, data: ?[]const u8) ?Kept {
        for (self.events.items) |e| {
            if (e.kind != kind) continue;
            if (peer) |p| if (e.peer != p) continue;
            if (data) |d| if (!std.mem.eql(u8, e.data, d)) continue;
            return e;
        }
        return null;
    }
};

/// Three apps and what each heard: a server and two players.
const Table = struct {
    server: *App,
    ann: *App,
    bob: *App,
    heard: [3]Heard = @splat(.{}),

    fn apps(t: *Table) [3]*App {
        return .{ t.server, t.ann, t.bob };
    }

    /// A frame of each, what each heard kept - until `done` holds.
    fn until(t: *Table, comptime done: fn (*Table) bool) !void {
        var frames: usize = 0;
        while (frames < 1000) : (frames += 1) {
            for (t.apps(), &t.heard) |app, *heard| {
                _ = try app.step();
                try heard.take(app);
            }
            if (done(t)) return;
            try testing.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestTimedOut;
    }

    fn deinit(t: *Table) void {
        for (&t.heard) |*h| h.deinit();
        t.bob.destroy();
        t.ann.destroy();
        t.server.destroy();
    }
};

test "a server and two players: their numbers, who hears of whom, messages each way and passed on, a kick, the server closing" {
    var t: Table = .{ .server = try headless(), .ann = undefined, .bob = undefined };
    t.ann = headless() catch |err| {
        t.server.destroy();
        return err;
    };
    t.bob = headless() catch |err| {
        t.ann.destroy();
        t.server.destroy();
        return err;
    };
    defer t.deinit();

    // Alone, a game is its own server.
    try testing.expectEqual(App.SessionRole.offline, t.server.sessionRole());
    try testing.expectEqual(@as(u32, 1), t.server.sessionPeer());
    try testing.expectError(error.NotConnected, t.server.sessionSendAll(.reliable, "nobody"));

    try t.server.hostSession(.{ .port = 0, .max_players = 4, .name = "Test server", .info = "de_test" });
    const port = t.server.sessionPort();
    try testing.expect(port != 0);
    try testing.expectEqual(App.SessionRole.server, t.server.sessionRole());

    try t.ann.joinSession("127.0.0.1", port, "Ann");
    try testing.expectEqual(App.SessionRole.joining, t.ann.sessionRole());
    try t.until(struct {
        fn done(table: *Table) bool {
            return table.heard[1].find(.joined, null, null) != null;
        }
    }.done);
    try t.bob.joinSession("localhost", port, "Bob");
    try t.until(struct {
        fn done(table: *Table) bool {
            return table.heard[2].find(.joined, null, null) != null and table.heard[1].find(.peer_joined, 3, null) != null;
        }
    }.done);

    // The numbers, as the server gave them; the hellos it heard.
    try testing.expectEqual(@as(u32, 2), t.ann.sessionPeer());
    try testing.expectEqual(@as(u32, 3), t.bob.sessionPeer());
    try testing.expect(t.heard[0].find(.peer_joined, 2, "Ann") != null);
    try testing.expect(t.heard[0].find(.peer_joined, 3, "Bob") != null);
    // Bob was told Ann was there before him.
    try testing.expect(t.heard[2].find(.peer_joined, 2, null) != null);
    var peers: std.ArrayList(u32) = .empty;
    defer peers.deinit(testing.allocator);
    try t.server.sessionPeers(testing.allocator, &peers);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, peers.items);
    peers.clearRetainingCapacity();
    try t.bob.sessionPeers(testing.allocator, &peers);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, peers.items);
    try testing.expect(t.server.sessionRoundTrip(2) != null);
    try testing.expect(t.server.sessionAddress(3) != null);

    // Each way, each channel; one player to the other by way of the server;
    // a player's to everyone reaching the server and the other.
    try t.ann.sessionSend(1, .reliable, "to the server");
    try t.server.sessionSend(3, .unreliable, "to Bob");
    try t.bob.sessionSend(2, .reliable, "Bob to Ann");
    try t.server.sessionSendAll(.sequenced, "to all");
    try t.ann.sessionSendAll(.reliable, "Ann to all");
    try testing.expectError(error.NoSuchPeer, t.ann.sessionSend(9, .reliable, "nobody"));
    try t.until(struct {
        fn done(table: *Table) bool {
            return table.heard[0].find(.message, 2, "to the server") != null and
                table.heard[2].find(.message, 1, "to Bob") != null and
                table.heard[1].find(.message, 3, "Bob to Ann") != null and
                table.heard[1].find(.message, 1, "to all") != null and
                table.heard[2].find(.message, 1, "to all") != null and
                table.heard[0].find(.message, 2, "Ann to all") != null and
                table.heard[2].find(.message, 2, "Ann to all") != null;
        }
    }.done);
    try testing.expectEqual(App.SessionChannel.sequenced, t.heard[2].find(.message, 1, "to all").?.channel);
    // A player's own message to everyone does not come back to it, nor to
    // the server twice.
    try testing.expect(t.heard[1].find(.message, 2, "Ann to all") == null);

    // Bob kicked: he hears why, Ann that he went.
    t.server.kickSessionPeer(3);
    try t.until(struct {
        fn done(table: *Table) bool {
            return table.heard[2].find(.left, null, null) != null and table.heard[1].find(.peer_left, 3, null) != null;
        }
    }.done);
    try testing.expectEqual(App.SessionReason.kicked, t.heard[2].find(.left, null, null).?.reason);
    try testing.expectEqual(App.SessionRole.offline, t.bob.sessionRole());
    try testing.expectEqual(@as(u32, 1), t.bob.sessionPeer());

    // The server closes: Ann hears so.
    t.server.leaveSession();
    try t.until(struct {
        fn done(table: *Table) bool {
            return table.heard[1].find(.left, null, null) != null;
        }
    }.done);
    try testing.expectEqual(App.SessionReason.server_closed, t.heard[1].find(.left, null, null).?.reason);
}

test "joining where no server is, or a name that is nowhere, ends in `left`; an address that is none is refused" {
    const app = try headless();
    defer app.destroy();
    try testing.expectError(error.BadAddress, app.joinSession("not an address!", 1, ""));
    try testing.expectError(error.BadAddress, app.joinSession("", 1, ""));
    try testing.expectError(error.TooLarge, app.joinSession("127.0.0.1", 1, &(@as([300]u8, @splat('x')))));

    // A name that cannot be found.
    try app.joinSession("no-such-host.invalid", 27999, "");
    try until(&.{app}, app, struct {
        fn done(a: *App) bool {
            for (a.sessionEvents()) |e| if (e.kind == .left) return true;
            return false;
        }
    }.done);
    try testing.expectEqual(App.SessionRole.offline, app.sessionRole());
}

test "a LAN search finds the server on this machine, with its name, what it says of itself and its players" {
    const server = try headless();
    defer server.destroy();
    const finder = try headless();
    defer finder.destroy();
    try server.hostSession(.{ .port = 0, .max_players = 8, .name = "Found me", .info = "de_dust2" });
    try finder.searchSessions(server.sessionPort());
    try until(&.{ server, finder }, finder, struct {
        fn done(a: *App) bool {
            return a.session.browser.?.found.items.len > 0;
        }
    }.done);
    var found: std.ArrayList(App.SessionFound) = .empty;
    defer found.deinit(testing.allocator);
    try finder.foundSessions(testing.allocator, &found);
    try testing.expectEqualStrings("Found me", found.items[0].name);
    try testing.expectEqualStrings("de_dust2", found.items[0].info);
    try testing.expectEqual(@as(u16, 8), found.items[0].most);
    try testing.expectEqual(server.sessionPort(), found.items[0].address.getPort());
    finder.stopSessionSearch();
}

// -------------------------------------------------------------------------
// From scripts
// -------------------------------------------------------------------------

const server_script =
    \\var joined: [int] = [];
    \\var hellos: [string] = [];
    \\var got: any = null;
    \\var from = 0;
    \\var gone = "";
    \\fn start(port: int) {
    \\    net.peer_joined.connect(fn (peer: int, hello: string) {
    \\        joined.push(peer);
    \\        hellos.push(hello);
    \\    });
    \\    net.peer_left.connect(fn (peer: int, reason: string) { gone = reason; });
    \\    net.message.connect(fn (peer: int, value: any) {
    \\        got = value;
    \\        from = peer;
    \\        net.send(peer, {"echo": value, "seen_by": net.id()}, .reliable);
    \\    });
    \\    net.host(port, 4, "Script server", "de_flux") catch |err| { gone = err.name; };
    \\}
    \\fn check() bool {
    \\    return got["int"] == -123456789012 and got["float"] == 0.1 and got["half"] == 0.5 and got["text"] == "árvíztűrő"
    \\        and got["yes"] == true and got["nothing"] == null and got["v2"] == vec2(1.5, -2.0) and got["v3"] == vec3(1.0, 2.0, 3.0)
    \\        and got["q"] == quat(0.0, 0.0, 0.0, 1.0) and got["c"] == color(1.0, 0.5, 0.25, 1.0)
    \\        and got["list"][1] == "two" and got["list"][2][0] == 3.5
    \\        and got["shot"]["at"] == vec3(1.0, 2.0, 3.0) and got["shot"]["damage"] == 27;
    \\}
;

const player_script =
    \\struct Shot { var at: vec3 = vec3(1.0, 2.0, 3.0); var damage: int = 27; }
    \\var me = 0;
    \\var echo: any = null;
    \\var why = "";
    \\var role = "";
    \\fn start(port: int) {
    \\    net.joined.connect(fn (peer: int) {
    \\        me = peer;
    \\        role = if (net.role() == .client) "client" else "other";
    \\        net.send(1, {
    \\            "int": -123456789012, "float": 0.1, "half": 0.5, "text": "árvíztűrő", "yes": true, "nothing": null,
    \\            "v2": vec2(1.5, -2.0), "v3": vec3(1.0, 2.0, 3.0), "q": quat(0.0, 0.0, 0.0, 1.0), "c": color(1.0, 0.5, 0.25, 1.0),
    \\            "list": [1, "two", [3.5]], "shot": Shot{},
    \\        });
    \\    });
    \\    net.message.connect(fn (peer: int, value: any) { echo = value; });
    \\    net.left.connect(fn (reason: string) { why = reason; });
    \\    net.join("127.0.0.1", port, "Flux player") catch |err| { why = err.name; };
    \\}
;

test "from scripts: a server and a player, any value sent and coming out as it went in, and the server closing" {
    const server = try headless();
    defer server.destroy();
    const player = try headless();
    defer player.destroy();
    try server.useScripts(.{});
    try player.useScripts(.{});
    const server_module = server.scripts.?.moduleOf(try server.addScript("server.flux", server_script)).?;
    const player_module = player.scripts.?.moduleOf(try player.addScript("player.flux", player_script)).?;
    const s_vm = server.scripts.?.vm;
    const p_vm = player.scripts.?.vm;

    _ = try s_vm.callName(server_module, "start", &.{.int(0)});
    try testing.expectEqual(App.SessionRole.server, server.sessionRole());
    _ = try p_vm.callName(player_module, "start", &.{.int(server.sessionPort())});

    const Both = struct { s: *flux.Vm, sm: *flux.object.Module, p: *flux.Vm, pm: *flux.object.Module };
    const both: Both = .{ .s = s_vm, .sm = server_module, .p = p_vm, .pm = player_module };
    try until(&.{ server, player }, both, struct {
        fn done(b: Both) bool {
            return !b.p.get(b.pm, "echo").?.isNull();
        }
    }.done);

    try testing.expectEqual(@as(i64, 2), p_vm.get(player_module, "me").?.asInt());
    try testing.expectEqualStrings("client", p_vm.get(player_module, "role").?.as(flux.object.String).bytes());
    try testing.expectEqual(@as(i64, 2), s_vm.get(server_module, "from").?.asInt());
    const hellos = s_vm.get(server_module, "hellos").?.as(flux.object.List).items.items;
    try testing.expectEqualStrings("Flux player", hellos[0].as(flux.object.String).bytes());

    // What the server got, as it was sent: read back by a script of its own.
    try testing.expect((try s_vm.callName(server_module, "check", &.{})).asBool());
    // And it came back, with what the server added.
    const echo = p_vm.get(player_module, "echo").?;
    try testing.expect(echo.tag == .map);

    server.leaveSession();
    try until(&.{ server, player }, both, struct {
        fn done(b: Both) bool {
            return b.p.get(b.pm, "why").?.as(flux.object.String).bytes().len > 0;
        }
    }.done);
    try testing.expectEqualStrings("server_closed", p_vm.get(player_module, "why").?.as(flux.object.String).bytes());
}

test "a value packed is the value unpacked; bytes that are no value are refused, never trusted" {
    const app = try headless();
    defer app.destroy();
    try app.useScripts(.{});
    const vm = app.scripts.?.vm;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try net_access.pack(vm, &out, .int(std.math.minInt(i64)), 0);
    try testing.expectEqual(std.math.minInt(i64), (try net_access.unpack(vm, out.items)).asInt());
    out.clearRetainingCapacity();
    try net_access.pack(vm, &out, .vec3(1, 2, 3), 0);
    try testing.expectEqual(@as(usize, 13), out.items.len);

    // A list that says it holds more than there are bytes; a string past
    // the end; a tag that is none; something left over; nesting too deep.
    const lies = [_][]const u8{
        &.{ 11, 0xff, 0xff, 0xff, 0x0f },
        &.{ 6, 10, 'a' },
        &.{200},
        &.{ 0, 0 },
        &(@as([40]u8, @splat(11)) ++ [_]u8{0}),
        &.{},
    };
    for (lies) |bytes| try testing.expectError(error.Malformed, net_access.unpack(vm, bytes));

    // Noise: never a crash, never a leak.
    var prng: std.Random.DefaultPrng = .init(0x5E55);
    var noise: [64]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&noise);
        const len = prng.random().uintAtMost(usize, noise.len);
        _ = net_access.unpack(vm, noise[0..len]) catch {};
    }
}
