// SPDX-License-Identifier: BSD-3-Clause

//! Networked play: the game a server its players join over UDP, or a
//! player joined to one - fluxion-session's server and client, made by the
//! calls here, stepped every frame and their news kept for the game.
//!
//! ```zig
//! try app.hostSession(.{ .name = "My server", .info = "de_dust2" });
//! // or: try app.joinSession("192.168.1.20", null, "player name");
//! for (app.sessionEvents()) |event| switch (event.kind) {
//!     .peer_joined => welcome(event.peer, event.data),
//!     .message => handle(event.peer, event.data),
//!     else => {},
//! };
//! try app.sessionSend(peer, .unreliable, snapshot);
//! ```
//!
//! **Who is who.** Every end of a session is a peer, by a number: the
//! server is always 1 - and so is a game playing alone, which decides for
//! itself - and each player that joins gets the next number from 2, never
//! given again while the server runs, so news of one that left is never
//! taken for one that came after. The server tells each player its number,
//! and who else is there as they come and go: a player hears `peer_joined`
//! and `peer_left` of the others too. What a player sends another goes by
//! way of the server, which passes it on (`HostOptions.relay`).
//!
//! **Channels.** `unreliable`: arrives or not, in any order - what is sent
//! again soon anyway. `sequenced`: arrives or not, never after a newer one
//! - where things are, every tick. `reliable`: arrives once, in order - a
//! kill, a chat line, the round won. See fluxion-session's README.
//!
//! **The frame.** What came is taken at the top of every frame, even in the
//! background - a server whose window is behind another keeps its players
//! - and kept until the next frame the game runs: the scripts hear it
//! before the fixed steps, a Zig game reads `App.sessionEvents` in its
//! systems or after `App.step`. What was sent goes out at the end of the
//! frame it was sent in.
//!
//! **Finding servers.** `search` asks the LAN - its broadcast address, and
//! this machine - and every server that answers is listed with its name,
//! what it says of itself, its players and how long it took to answer.
//!
//! **Across the internet.** A server behind a NAT is reached through a
//! rendezvous server - `network.rendezvous` in the project, or
//! `setRendezvous` - which runs fluxion-session's `fluxion-rendezvous`. A
//! `public` server says it is there, every while, and is given an id; a
//! player finds it (`searchOnline`) and joins it by that id (`joinOnline`):
//! introduced to it, the two open their NATs to each other and the session
//! goes directly; where that does not open in `direct_ns`, it goes through
//! the rendezvous - sealed end to end, as ever.
//!
//! **Which game.** A server and a player meet only if their game and its
//! `network.session_version` are the same: the project's name and that
//! number are what fluxion-session calls the protocol.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fluxion_session");

const App = @import("../App.zig");
const settings = @import("../project/settings.zig");

const log = std.log.scoped(.fluxion_engine);

pub const Channel = fs.Channel;
pub const Reason = fs.Reason;
pub const Address = fs.Address;

/// The server's peer number, and a game's alone.
pub const server_peer: u32 = 1;
/// The first number a player that joins is given.
pub const first_player: u32 = 2;
/// The most news kept for a game that does not take it - one in the
/// background for long - before what comes is let go.
pub const most_events = 65536;
pub const most_event_bytes = 32 * 1024 * 1024;

/// How far a player joining through the rendezvous has got.
pub const OnlinePhase = enum {
    none,
    /// Waiting for the rendezvous's address: a name being looked up.
    waiting,
    /// Asking to be introduced to the server.
    asking,
    /// Joining it at the address the rendezvous gave.
    direct,
    /// Joining it through the rendezvous.
    relayed,
};

/// What this end of a session is.
pub const Role = enum {
    /// Playing alone: the game decides for itself, as a server does.
    offline,
    /// A server players join; with a player of its own, a listen server.
    server,
    /// On the way to a server: its name looked up, the handshake under way.
    joining,
    /// A player joined to a server.
    client,
};

/// What happened, for the game to hear.
pub const Event = struct {
    kind: Kind,
    /// Whose: the player that joined, left or sent - or, to a player, the
    /// server (1); to one that joined, its own number.
    peer: u32,
    channel: Channel = .reliable,
    /// A joining player's hello, or a message's bytes: good for the frame.
    data: []const u8 = &.{},
    /// Why a peer left, or why this end left its server.
    reason: Reason = .left,

    pub const Kind = enum {
        /// To a server: a player joined, saying `data`.
        peer_joined,
        /// To a server: a player left, for `reason`.
        peer_left,
        /// `peer` sent `data` on `channel`.
        message,
        /// To a player: taken in by the server, as `peer`.
        joined,
        /// To a player: off the server - or never let on - for `reason`.
        left,
    };
};

/// A server a search found: on the LAN, at its address; or by the
/// rendezvous, by its `id`.
pub const Found = struct {
    address: Address,
    /// The rendezvous's id for it, to `joinOnline`; nought for one on the
    /// LAN.
    id: u64 = 0,
    name: []const u8,
    info: []const u8,
    players: u16,
    most: u16,
    /// From the question to the answer.
    ping_ns: u64,
};

/// What `App.hostSession` takes: what is not given, the project says.
pub const HostOptions = struct {
    /// Nought for any free one: `App.sessionPort` says which.
    port: ?u16 = null,
    max_players: ?u16 = null,
    /// What a LAN search is answered with: the server's name, and anything
    /// more - the map, the mode. 64 bytes each at most.
    name: []const u8 = "",
    info: []const u8 = "",
    /// Answer LAN searches at all.
    discoverable: bool = true,
    /// Pass on what a player sends another player. Off, a player reaches
    /// the server alone, and the others are not told of each other.
    relay: bool = true,
    /// Listed by the rendezvous, for players across the internet to find
    /// and join: see `setRendezvous`.
    public: bool = false,
};

/// How long a player joining through the rendezvous waits for the server
/// directly, before it goes through the rendezvous instead.
pub const direct_ns: u64 = 2500 * std.time.ns_per_ms;
/// How long it waits to be introduced at all.
pub const introduce_ns: u64 = 10 * std.time.ns_per_s;

/// The first byte of every message: what it is. A game's own are `game`;
/// the rest are the session's, and never reach the game as they are.
const Wire = enum(u8) {
    /// The game's, from the end that sent the datagram.
    game = 0,
    /// To a player: its number, as `u32`.
    welcome = 1,
    /// To a player: another is there, as `u32`.
    peer_joined = 2,
    /// To a player: another has gone, as `u32`, and why, a byte.
    peer_left = 3,
    /// To the server: pass this on to `u32` - nought for everyone.
    relay = 4,
    /// To a player: passed on from `u32`.
    relayed = 5,
};

/// Every peer: what `relay` names to send to everyone.
const everyone: u32 = 0;

pub const Error = error{
    NoIo,
    /// The address is neither a number nor a name.
    BadAddress,
    /// The port could not be had: another program has it.
    CannotListen,
    /// A hello longer than 256 bytes.
    TooLarge,
    /// This build cannot open a UDP socket: a page in a browser.
    Unsupported,
    OutOfMemory,
};

pub const SendError = error{
    /// Not on a session, or not joined yet.
    NotConnected,
    /// No such peer: a player sends to the server (1) alone.
    NoSuchPeer,
    /// Larger than the channel carries: a reliable message 64 KiB, the
    /// others one datagram.
    TooLarge,
    /// Too much reliable is waiting for that peer already.
    QueueFull,
    OutOfMemory,
};

/// A name being looked up, on a thread of its own: the frame never waits
/// for the name server.
const Lookup = struct {
    name: [std.Io.net.HostName.max_len]u8 = undefined,
    name_len: usize = 0,
    port: u16 = 0,
    done: std.atomic.Value(bool) = .init(false),
    found: ?Address = null,
    thread: ?std.Thread = null,

    fn run(self: *Lookup, io: std.Io) void {
        defer self.done.store(true, .release);
        const named = std.Io.net.HostName.init(self.name[0..self.name_len]) catch return;
        var buffer: [16]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buffer);
        named.lookup(io, &queue, .{ .port = self.port }) catch return;
        // A server listens on IPv4: its address first, the other if none.
        var other: ?Address = null;
        while (queue.getOneUncancelable(io)) |result| switch (result) {
            .address => |address| switch (address) {
                .ip4 => {
                    self.found = address;
                    return;
                },
                .ip6 => if (other == null) {
                    other = address;
                },
            },
            .canonical_name => {},
        } else |_| {}
        self.found = other;
    }
};

pub const Session = struct {
    role: Role = .offline,
    socket: ?fs.transport.Udp = null,
    server: ?fs.Server = null,
    client: ?fs.Client = null,
    /// The peer number of each of the server's slots: nought for an empty one.
    peers: []u32 = &.{},
    next_peer: u32 = first_player,
    /// A player's own number, once the server has said it.
    own_peer: u32 = 0,
    /// The other players a player was told of.
    others: std.ArrayList(u32) = .empty,
    /// Whether a server passes on what players send each other.
    relay: bool = true,
    /// A message with its kind in front, made here to be sent.
    outgoing: std.ArrayList(u8) = .empty,
    /// A name being looked up before joining, and what to say then.
    lookup: ?*Lookup = null,
    hello: std.ArrayList(u8) = .empty,
    /// The LAN search: its socket, and what it found.
    search_socket: ?fs.transport.Udp = null,
    browser: ?fs.Browser = null,
    /// The news of this frame and the frames before it the game did not
    /// run, and the bytes they carry.
    events: std.ArrayList(Event) = .empty,
    event_bytes: usize = 0,
    /// News let go of because the game took none for too long.
    dropped: u64 = 0,
    /// Why this end last left a server: what `left` said.
    last_reason: Reason = .left,
    /// Whether a whole frame - the game's - has run since the news was
    /// taken: the next frame's lets it go.
    heard: bool = false,

    // Across the internet.
    /// The rendezvous: as given, and once found, its address; a name being
    /// looked up.
    rendezvous_text: std.ArrayList(u8) = .empty,
    rendezvous: ?Address = null,
    rendezvous_lookup: ?*Lookup = null,
    /// The socket's way through NATs: a public server's, or a player's
    /// joining through the rendezvous. `Server` and `Client` are given its
    /// transport.
    nat: ?fs.Nat = null,
    /// A public server's listing: its name and what more it says.
    listing_name: std.ArrayList(u8) = .empty,
    listing_info: std.ArrayList(u8) = .empty,
    listed: bool = false,
    /// A player's join through the rendezvous: the server's id, how far it
    /// has got, and since when.
    online_id: u64 = 0,
    online_phase: OnlinePhase = .none,
    online_since: u64 = 0,
    /// Never directly: through the rendezvous at once - to try it.
    force_relay: bool = false,
    /// The search of the rendezvous: its own socket and way, and whether it
    /// waits for the rendezvous's address to ask.
    online_socket: ?fs.transport.Udp = null,
    online_nat: ?fs.Nat = null,
    online_wanted: bool = false,

    pub fn deinit(self: *Session, app: *App) void {
        leave(app);
        stopSearch(app);
        stopOnlineSearch(app);
        if (self.rendezvous_lookup) |lookup| {
            if (!builtin.single_threaded) if (lookup.thread) |thread| thread.join();
            app.gpa.destroy(lookup);
        }
        self.rendezvous_text.deinit(app.gpa);
        self.listing_name.deinit(app.gpa);
        self.listing_info.deinit(app.gpa);
        self.clearEvents(app.gpa);
        self.events.deinit(app.gpa);
        self.hello.deinit(app.gpa);
        self.others.deinit(app.gpa);
        self.outgoing.deinit(app.gpa);
        app.gpa.free(self.peers);
        self.* = undefined;
    }

    fn clearEvents(self: *Session, gpa: std.mem.Allocator) void {
        for (self.events.items) |event| gpa.free(event.data);
        self.events.clearRetainingCapacity();
        self.event_bytes = 0;
    }

    fn happen(self: *Session, gpa: std.mem.Allocator, event: Event) void {
        if (self.events.items.len >= most_events or self.event_bytes + event.data.len > most_event_bytes) {
            if (self.dropped == 0) log.warn("the game takes no network news: what comes is let go of", .{});
            self.dropped += 1;
            return;
        }
        const data = gpa.dupe(u8, event.data) catch {
            self.dropped += 1;
            return;
        };
        var kept = event;
        kept.data = data;
        self.events.append(gpa, kept) catch {
            gpa.free(data);
            self.dropped += 1;
            return;
        };
        self.event_bytes += data.len;
    }

    /// `kind`, the number after it when it has one, and `data`, into
    /// `outgoing`.
    fn message(self: *Session, gpa: std.mem.Allocator, kind: Wire, after: ?u32, data: []const u8) error{OutOfMemory}![]const u8 {
        self.outgoing.clearRetainingCapacity();
        try self.outgoing.ensureTotalCapacity(gpa, 5 + data.len);
        self.outgoing.appendAssumeCapacity(@intFromEnum(kind));
        if (after) |n| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, n, .little);
            self.outgoing.appendSliceAssumeCapacity(&bytes);
        }
        self.outgoing.appendSliceAssumeCapacity(data);
        return self.outgoing.items;
    }

    fn isOther(self: *const Session, peer: u32) bool {
        return std.mem.indexOfScalar(u32, self.others.items, peer) != null;
    }

    fn slotOf(self: *const Session, peer: u32) ?u16 {
        if (peer < first_player) return null;
        for (self.peers, 0..) |held, slot| if (held == peer) return @intCast(slot);
        return null;
    }
};

/// The protocol of the project's game: its name and its session version.
pub fn protocolOf(app: *const App) u64 {
    const project = app.project.settings orelse settings.Settings{};
    const name: u64 = std.hash.Fnv1a_32.hash(project.application.name);
    return name << 32 | project.network.session_version;
}

fn networkOf(app: *const App) settings.Network {
    return if (app.project.settings) |held| held.network else .{};
}

fn nowOf(io: std.Io) u64 {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    return if (now <= 0) 0 else @intCast(now);
}

fn openSocket(io: std.Io, port: u16, broadcast: bool) Error!fs.transport.Udp {
    if (builtin.cpu.arch.isWasm()) return error.Unsupported;
    return fs.transport.Udp.open(io, .{ .ip4 = .unspecified(port) }, .{ .broadcast = broadcast }) catch |err| {
        log.warn("no UDP socket on port {d}: {t}", .{ port, err });
        return error.CannotListen;
    };
}

/// A server of this game on `options.port`, players joining it from now
/// on. A session there was is left first.
pub fn host(app: *App, options: HostOptions) Error!void {
    const io = app.io orelse return error.NoIo;
    leave(app);
    const network = networkOf(app);
    const s = &app.session;
    const most = @max(options.max_players orelse network.session_max_players, 1);
    s.socket = try openSocket(io, options.port orelse network.session_port, false);
    errdefer {
        s.socket.?.close();
        s.socket = null;
    }
    const peers = try app.gpa.alloc(u32, most);
    errdefer app.gpa.free(peers);
    @memset(peers, 0);
    // A public server's datagrams pass its way through NATs first.
    if (options.public) try ensureRendezvous(app);
    const out = if (options.public) blk: {
        s.nat = fs.Nat.init(app.gpa, s.socket.?.transport(), unknownAddress(), protocolOf(app), .{}, seedOf(io));
        s.listing_name.clearRetainingCapacity();
        try s.listing_name.appendSlice(app.gpa, options.name);
        s.listing_info.clearRetainingCapacity();
        try s.listing_info.appendSlice(app.gpa, options.info);
        s.listed = false;
        break :blk s.nat.?.transport();
    } else s.socket.?.transport();
    s.server = fs.Server.init(app.gpa, io, out, .{
        .protocol = protocolOf(app),
        .max_clients = most,
        .discovery = if (options.discoverable) .{ .name = options.name, .info = options.info } else null,
    }) catch return error.OutOfMemory;
    app.gpa.free(s.peers);
    s.peers = peers;
    s.next_peer = first_player;
    s.relay = options.relay;
    s.role = .server;
    log.info("a server on UDP port {d}, for {d} players{s}", .{ s.socket.?.port(), most, if (options.public) ", listed by the rendezvous" else "" });
    if (options.public and s.rendezvous_text.items.len == 0) log.warn("a public server with no rendezvous: setRendezvous, or the project's network.rendezvous", .{});
}

/// An address that is no one's: what a NAT's rendezvous is until found.
fn unknownAddress() Address {
    return .{ .ip4 = .unspecified(0) };
}

fn seedOf(io: std.Io) u64 {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    return seed;
}

/// The rendezvous server from now on: `host:port` - a number or a name -
/// or "" for none. A name is looked up on a thread of its own.
pub fn setRendezvous(app: *App, text: []const u8) Error!void {
    const s = &app.session;
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.mem.eql(u8, trimmed, s.rendezvous_text.items)) return;
    s.rendezvous_text.clearRetainingCapacity();
    try s.rendezvous_text.appendSlice(app.gpa, trimmed);
    s.rendezvous = null;
    s.listed = false;
    if (trimmed.len == 0) return;
    const io = app.io orelse return error.NoIo;
    // `host:port`: the port after the last colon, where it is one.
    var name = trimmed;
    var port: u16 = 27000;
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        if (std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10)) |given| {
            port = given;
            name = trimmed[0..colon];
        } else |_| {}
    }
    if (std.mem.eql(u8, name, "localhost")) {
        s.rendezvous = .{ .ip4 = .loopback(port) };
        return;
    }
    if (Address.parse(name, port)) |literal| {
        s.rendezvous = literal;
        return;
    } else |_| {}
    _ = std.Io.net.HostName.init(name) catch return error.BadAddress;
    if (s.rendezvous_lookup != null) return;
    const lookup = try app.gpa.create(Lookup);
    errdefer app.gpa.destroy(lookup);
    lookup.* = .{ .port = port, .name_len = name.len };
    @memcpy(lookup.name[0..name.len], name);
    if (builtin.single_threaded) lookup.run(io) else {
        lookup.thread = std.Thread.spawn(.{}, Lookup.run, .{ lookup, io }) catch return error.OutOfMemory;
    }
    s.rendezvous_lookup = lookup;
}

/// The project's rendezvous - `network.rendezvous` - where none was given.
fn ensureRendezvous(app: *App) Error!void {
    if (app.session.rendezvous_text.items.len > 0) return;
    const given = networkOf(app).rendezvous;
    if (given.len > 0) try setRendezvous(app, given);
}

/// The rendezvous as given: "" for none.
pub fn rendezvousText(app: *const App) []const u8 {
    return app.session.rendezvous_text.items;
}

/// Joined to the server the rendezvous knows as `id`, saying `hello`:
/// introduced to it, then directly - or, where that does not open in
/// `direct_ns`, through the rendezvous. A session there was is left first.
pub fn joinOnline(app: *App, id: u64, hello: []const u8) Error!void {
    const io = app.io orelse return error.NoIo;
    if (hello.len > 256) return error.TooLarge;
    try ensureRendezvous(app);
    if (app.session.rendezvous_text.items.len == 0) return error.BadAddress;
    leave(app);
    const s = &app.session;
    s.hello.clearRetainingCapacity();
    try s.hello.appendSlice(app.gpa, hello);
    s.socket = try openSocket(io, 0, false);
    s.nat = fs.Nat.init(app.gpa, s.socket.?.transport(), unknownAddress(), protocolOf(app), .{}, seedOf(io));
    s.client = .init(app.gpa, s.nat.?.transport(), .{ .protocol = protocolOf(app) });
    s.role = .joining;
    s.online_id = id;
    s.online_phase = .waiting;
    s.online_since = nowOf(io);
}

/// The rendezvous asked for this game's servers: they are in `found` too,
/// each with its id.
pub fn searchOnline(app: *App) Error!void {
    const io = app.io orelse return error.NoIo;
    const s = &app.session;
    try ensureRendezvous(app);
    if (s.rendezvous_text.items.len == 0) return error.BadAddress;
    if (s.online_socket == null) {
        s.online_socket = try openSocket(io, 0, false);
        s.online_nat = fs.Nat.init(app.gpa, s.online_socket.?.transport(), unknownAddress(), protocolOf(app), .{}, seedOf(io));
    }
    s.online_wanted = true;
}

/// The rendezvous's search let go of.
pub fn stopOnlineSearch(app: *App) void {
    const s = &app.session;
    if (s.online_nat) |*nat| nat.deinit();
    s.online_nat = null;
    if (s.online_socket) |*socket| socket.close();
    s.online_socket = null;
    s.online_wanted = false;
}

/// A public server's id at the rendezvous, and the address the world sees
/// it at: null until the rendezvous answers.
pub fn publicListing(app: *const App) ?struct { u64, Address } {
    const nat = if (app.session.nat) |*held| held else return null;
    return .{ nat.id orelse return null, nat.public orelse return null };
}

/// Whether `peer` is reached through the rendezvous: a server's player, or
/// a player's server.
pub fn isRelayed(app: *const App, peer: u32) bool {
    const at = addressOf(app, peer) orelse return false;
    return fs.Nat.isRelayed(at);
}

/// The rendezvous's address found, the NATs' ways told it; a public
/// server listed and kept so; a player's join through it moved on.
fn pumpNat(app: *App, now: u64) void {
    const s = &app.session;
    if (s.rendezvous_lookup) |lookup| if (lookup.done.load(.acquire)) {
        if (!builtin.single_threaded) if (lookup.thread) |thread| thread.join();
        if (lookup.found) |found| s.rendezvous = found else log.warn("no address found for the rendezvous \"{s}\"", .{lookup.name[0..lookup.name_len]});
        app.gpa.destroy(lookup);
        s.rendezvous_lookup = null;
    };
    const rendezvous = s.rendezvous orelse return;
    if (s.nat) |*nat| {
        nat.rendezvous = rendezvous;
        if (s.server) |*server| {
            nat.register(now, s.listing_name.items, s.listing_info.items, server.clients(), @intCast(s.peers.len));
            if (!s.listed and nat.id != null) {
                s.listed = true;
                var buffer: [64]u8 = undefined;
                log.info("listed by the rendezvous as {x}, seen at {s}:{d}", .{ nat.id.?, hostText(nat.public.?, &buffer), nat.public.?.getPort() });
            }
        }
        nat.update(now);
    }
    if (s.client != null and s.nat != null) joinOnlineStep(app, now);
    if (s.online_nat) |*nat| {
        nat.rendezvous = rendezvous;
        if (s.online_wanted) {
            s.online_wanted = false;
            nat.search();
        }
        nat.update(now);
        // Nothing else reads its socket: what came, taken here.
        var buffer: [fs.transport.max_datagram + 1]u8 = undefined;
        while (nat.transport().receive(&buffer)) |_| {}
    }
}

fn joinOnlineStep(app: *App, now: u64) void {
    const s = &app.session;
    const nat = &s.nat.?;
    const client = &s.client.?;
    switch (s.online_phase) {
        .none => {},
        .waiting => {
            nat.introduce(now, s.online_id);
            s.online_phase = .asking;
            s.online_since = now;
        },
        .asking => {
            if (nat.gone or now -| s.online_since > introduce_ns) return failOnline(app, .refused);
            if (s.force_relay) {
                goRelayed(app, now);
            } else if (nat.direct) |address| {
                client.connect(app.io.?, now, address, s.hello.items) catch return failOnline(app, .refused);
                s.online_phase = .direct;
                s.online_since = now;
            }
        },
        .direct => if (s.role == .joining and now -| s.online_since > direct_ns) goRelayed(app, now),
        .relayed => {},
    }
}

fn goRelayed(app: *App, now: u64) void {
    const s = &app.session;
    log.info("joining through the rendezvous", .{});
    s.client.?.connect(app.io.?, now, fs.Nat.relayed(s.online_id), s.hello.items) catch return failOnline(app, .refused);
    s.online_phase = .relayed;
    s.online_since = now;
}

fn failOnline(app: *App, reason: Reason) void {
    const s = &app.session;
    leave(app);
    s.last_reason = reason;
    s.happen(app.gpa, .{ .kind = .left, .peer = server_peer, .reason = reason });
}

/// Joined to the server at `address` - a number, `192.168.1.20` or
/// `::1`, or a name, looked up first - on `port`, saying `hello`: a name, a
/// password, a token. A session there was is left first. The game hears
/// `joined` once it is in, or `left` with why it is not.
pub fn join(app: *App, address: []const u8, port: ?u16, hello: []const u8) Error!void {
    const io = app.io orelse return error.NoIo;
    if (hello.len > 256) return error.TooLarge;
    leave(app);
    const s = &app.session;
    const to_port = port orelse networkOf(app).session_port;
    const trimmed = std.mem.trim(u8, address, " \t");
    if (trimmed.len == 0) return error.BadAddress;
    s.hello.clearRetainingCapacity();
    try s.hello.appendSlice(app.gpa, hello);
    s.socket = try openSocket(io, 0, false);
    s.client = .init(app.gpa, s.socket.?.transport(), .{ .protocol = protocolOf(app) });
    s.role = .joining;
    errdefer leave(app);
    if (std.mem.eql(u8, trimmed, "localhost")) return start(app, .{ .ip4 = .loopback(to_port) });
    if (Address.parse(trimmed, to_port)) |literal| return start(app, literal) else |_| {}
    // A name: looked up on a thread of its own, joined once it is found.
    _ = std.Io.net.HostName.init(trimmed) catch return error.BadAddress;
    const lookup = try app.gpa.create(Lookup);
    errdefer app.gpa.destroy(lookup);
    lookup.* = .{ .port = to_port, .name_len = trimmed.len };
    @memcpy(lookup.name[0..trimmed.len], trimmed);
    if (builtin.single_threaded) {
        // No thread to give it - a page in a browser, which opens no UDP
        // socket anyway: looked up here.
        lookup.run(io);
    } else {
        lookup.thread = std.Thread.spawn(.{}, Lookup.run, .{ lookup, io }) catch return error.OutOfMemory;
    }
    s.lookup = lookup;
}

fn start(app: *App, address: Address) Error!void {
    const s = &app.session;
    s.client.?.connect(app.io.?, nowOf(app.io.?), address, s.hello.items) catch return error.TooLarge;
}

/// Off the session: a server tells its players it is closing, a player
/// tells its server it is going. Nothing is said to the game of its own
/// leaving.
pub fn leave(app: *App) void {
    const s = &app.session;
    const io = app.io orelse return;
    const now = nowOf(io);
    if (s.lookup) |lookup| {
        if (!builtin.single_threaded) if (lookup.thread) |thread| thread.join();
        app.gpa.destroy(lookup);
        s.lookup = null;
    }
    if (s.server) |*server| {
        server.close(now);
        // What says so goes now: the socket closes next.
        server.update(now);
        server.deinit();
        s.server = null;
    }
    if (s.client) |*client| {
        client.disconnect(now);
        client.deinit();
        s.client = null;
    }
    if (s.nat) |*nat| nat.deinit();
    s.nat = null;
    s.online_phase = .none;
    s.listed = false;
    if (s.socket) |*socket| socket.close();
    s.socket = null;
    @memset(s.peers, 0);
    s.own_peer = 0;
    s.others.clearRetainingCapacity();
    s.role = .offline;
}

/// What came taken - and what waits sent - into the frame's news: the news
/// of the frame before let go of first, once it was a whole frame the game
/// heard it in. A pass of every frame's, in the background too, where what
/// comes is kept for the game: see `app/frame_steps.zig`.
pub fn collect(app: *App) anyerror!void {
    const s = &app.session;
    if (s.heard) {
        s.clearEvents(app.gpa);
        s.heard = false;
    }
    pump(app);
}

/// What the frame sent gone out, nothing taken: what comes now is the next
/// frame's. The frame's news is still there for whoever reads it after the
/// frame, until the next one starts. A pass at the end of the frame.
pub fn endOfFrame(app: *App) anyerror!void {
    const s = &app.session;
    s.heard = true;
    const io = app.io orelse return;
    const now = nowOf(io);
    if (s.server) |*server| {
        for (0..server.slots.len) |slot| {
            const c = server.connection(@intCast(slot)) orelse continue;
            const to = server.addressOf(@intCast(slot)) orelse continue;
            c.flush(now, server.transport, &to);
        }
    }
    if (s.client) |*client| {
        if (client.state == .connected) client.connection.?.flush(now, client.transport, &client.server);
    }
}

fn pump(app: *App) void {
    const s = &app.session;
    const io = app.io orelse return;
    const now = nowOf(io);
    if (s.lookup) |lookup| if (lookup.done.load(.acquire)) {
        if (!builtin.single_threaded) if (lookup.thread) |thread| thread.join();
        const found = lookup.found;
        const name = lookup.name[0..lookup.name_len];
        if (found == null) log.warn("no address found for \"{s}\"", .{name});
        app.gpa.destroy(lookup);
        s.lookup = null;
        if (found) |address| start(app, address) catch {} else {
            leave(app);
            s.last_reason = .refused;
            s.happen(app.gpa, .{ .kind = .left, .peer = server_peer, .reason = .refused });
        }
    };
    pumpNat(app, now);
    if (s.server != null) serverNews(app, now);
    if (s.client != null) clientNews(app, now);
    if (s.browser) |*browser| browser.update(now);
}

fn numberIn(data: []const u8) ?u32 {
    if (data.len < 5) return null;
    return std.mem.readInt(u32, data[1..5], .little);
}

fn serverNews(app: *App, now: u64) void {
    const s = &app.session;
    const server = &s.server.?;
    server.update(now);
    while (server.next()) |event| switch (event) {
        .connected => |c| {
            const peer = s.next_peer;
            s.next_peer += 1;
            s.peers[c.client] = peer;
            // Its number first, then who is there; and the others told.
            if (s.message(app.gpa, .welcome, peer, &.{})) |m| server.send(c.client, .reliable, m) catch {} else |_| {}
            if (s.relay) for (s.peers, 0..) |other, slot| {
                if (other == 0 or slot == c.client) continue;
                if (s.message(app.gpa, .peer_joined, other, &.{})) |m| server.send(c.client, .reliable, m) catch {} else |_| {}
                if (s.message(app.gpa, .peer_joined, peer, &.{})) |m| server.send(@intCast(slot), .reliable, m) catch {} else |_| {}
            };
            s.happen(app.gpa, .{ .kind = .peer_joined, .peer = peer, .data = c.hello });
        },
        .disconnected => |d| {
            const peer = s.peers[d.client];
            s.peers[d.client] = 0;
            if (peer == 0) continue;
            tellLeft(app, peer, d.reason);
            s.happen(app.gpa, .{ .kind = .peer_left, .peer = peer, .reason = d.reason });
        },
        .message => |m| {
            const from = s.peers[m.client];
            if (from == 0 or m.data.len == 0) continue;
            switch (m.data[0]) {
                @intFromEnum(Wire.game) => s.happen(app.gpa, .{ .kind = .message, .peer = from, .channel = m.channel, .data = m.data[1..] }),
                @intFromEnum(Wire.relay) => {
                    const to = numberIn(m.data) orelse continue;
                    const data = m.data[5..];
                    if (to == server_peer or to == everyone) s.happen(app.gpa, .{ .kind = .message, .peer = from, .channel = m.channel, .data = data });
                    if (!s.relay or to == server_peer) continue;
                    const passed = s.message(app.gpa, .relayed, from, data) catch continue;
                    for (s.peers, 0..) |peer, slot| {
                        if (peer == 0 or peer == from or (to != everyone and peer != to)) continue;
                        server.send(@intCast(slot), m.channel, passed) catch {};
                    }
                },
                // Nothing else is a player's to send.
                else => {},
            }
        },
    };
}

/// The other players told `peer` has gone.
fn tellLeft(app: *App, peer: u32, reason: Reason) void {
    const s = &app.session;
    if (!s.relay) return;
    const m = s.message(app.gpa, .peer_left, peer, &.{@intFromEnum(reason)}) catch return;
    s.server.?.broadcast(.reliable, m);
}

fn clientNews(app: *App, now: u64) void {
    const s = &app.session;
    const client = &s.client.?;
    client.update(now);
    var gone: ?Reason = null;
    while (client.next()) |event| switch (event) {
        // In, but not yet told its number: `welcome` says it.
        .connected => {},
        .disconnected => |reason| gone = reason,
        .message => |m| {
            if (m.data.len == 0) continue;
            switch (m.data[0]) {
                @intFromEnum(Wire.welcome) => if (s.role == .joining) {
                    s.own_peer = numberIn(m.data) orelse continue;
                    s.role = .client;
                    s.happen(app.gpa, .{ .kind = .joined, .peer = s.own_peer });
                },
                // What came before the number is let go of: unreliable,
                // it would have come again; nothing reliable comes first.
                @intFromEnum(Wire.game) => if (s.role == .client) {
                    s.happen(app.gpa, .{ .kind = .message, .peer = server_peer, .channel = m.channel, .data = m.data[1..] });
                },
                @intFromEnum(Wire.peer_joined) => {
                    const peer = numberIn(m.data) orelse continue;
                    if (s.isOther(peer)) continue;
                    s.others.append(app.gpa, peer) catch continue;
                    s.happen(app.gpa, .{ .kind = .peer_joined, .peer = peer });
                },
                @intFromEnum(Wire.peer_left) => {
                    const peer = numberIn(m.data) orelse continue;
                    const at = std.mem.indexOfScalar(u32, s.others.items, peer) orelse continue;
                    _ = s.others.swapRemove(at);
                    const reason: Reason = if (m.data.len > 5) std.enums.fromInt(Reason, m.data[5]) orelse .left else .left;
                    s.happen(app.gpa, .{ .kind = .peer_left, .peer = peer, .reason = reason });
                },
                @intFromEnum(Wire.relayed) => if (s.role == .client) {
                    const from = numberIn(m.data) orelse continue;
                    s.happen(app.gpa, .{ .kind = .message, .peer = from, .channel = m.channel, .data = m.data[5..] });
                },
                else => {},
            }
        },
    };
    if (gone) |reason| {
        leave(app);
        s.last_reason = reason;
        s.happen(app.gpa, .{ .kind = .left, .peer = server_peer, .reason = reason });
    }
}

/// `data` to `peer` on `channel`: from a server to one of its players, from
/// a player to the server (1) or, by way of it, to another player. It goes
/// at the end of the frame.
pub fn send(app: *App, peer: u32, channel: Channel, data: []const u8) SendError!void {
    const s = &app.session;
    switch (s.role) {
        .server => {
            const slot = s.slotOf(peer) orelse return error.NoSuchPeer;
            const m = try s.message(app.gpa, .game, null, data);
            s.server.?.send(slot, channel, m) catch |err| return sendError(err);
        },
        .client => {
            const m = if (peer == server_peer)
                try s.message(app.gpa, .game, null, data)
            else if (s.isOther(peer))
                try s.message(app.gpa, .relay, peer, data)
            else
                return error.NoSuchPeer;
            s.client.?.send(channel, m) catch |err| return sendError(err);
        },
        .offline, .joining => return error.NotConnected,
    }
}

/// `data` to every other peer: a server's every player; a player's server
/// and, by way of it, every other player - one message, passed on.
pub fn sendAll(app: *App, channel: Channel, data: []const u8) SendError!void {
    const s = &app.session;
    switch (s.role) {
        .server => {
            const m = try s.message(app.gpa, .game, null, data);
            for (s.peers, 0..) |peer, slot| {
                if (peer == 0) continue;
                s.server.?.send(@intCast(slot), channel, m) catch |err| switch (err) {
                    // One whose queue is full misses it; the rest do not.
                    error.QueueFull => {},
                    else => return sendError(err),
                };
            }
        },
        .client => {
            const m = if (s.others.items.len == 0) try s.message(app.gpa, .game, null, data) else try s.message(app.gpa, .relay, everyone, data);
            s.client.?.send(channel, m) catch |err| return sendError(err);
        },
        .offline, .joining => return error.NotConnected,
    }
}

fn sendError(err: anyerror) SendError {
    return switch (err) {
        error.TooLarge => error.TooLarge,
        error.QueueFull => error.QueueFull,
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotConnected,
    };
}

/// A server's player sent away, and told so.
pub fn kick(app: *App, peer: u32) void {
    const s = &app.session;
    if (s.role != .server) return;
    const slot = s.slotOf(peer) orelse return;
    const io = app.io orelse return;
    s.server.?.kick(nowOf(io), slot);
    s.peers[slot] = 0;
    tellLeft(app, peer, .kicked);
    s.happen(app.gpa, .{ .kind = .peer_left, .peer = peer, .reason = .kicked });
}

/// This end's peer number: 1 for a server and a game alone, a player's
/// own once joined, nought while joining.
pub fn ownPeer(app: *const App) u32 {
    return switch (app.session.role) {
        .offline, .server => server_peer,
        .joining => 0,
        .client => app.session.own_peer,
    };
}

/// The other peers: a server's players; a player's server and the other
/// players it was told of.
pub fn peersInto(app: *const App, into: *std.ArrayList(u32), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const s = &app.session;
    switch (s.role) {
        .server => for (s.peers) |peer| {
            if (peer != 0) try into.append(gpa, peer);
        },
        .client => {
            try into.append(gpa, server_peer);
            try into.appendSlice(gpa, s.others.items);
        },
        .offline, .joining => {},
    }
}

/// The round trip to `peer`, in seconds; null for no such peer.
pub fn roundTrip(app: *App, peer: u32) ?f64 {
    const s = &app.session;
    const ns = switch (s.role) {
        .server => blk: {
            const slot = s.slotOf(peer) orelse return null;
            break :blk (s.server.?.connection(slot) orelse return null).rtt_ns;
        },
        .client => if (peer == server_peer) s.client.?.rtt() orelse return null else return null,
        .offline, .joining => return null,
    };
    return ns / std.time.ns_per_s;
}

/// How much went each way to `peer`, and how much was lost.
pub fn statsOf(app: *App, peer: u32) ?fs.Connection.Stats {
    const s = &app.session;
    const connection = switch (s.role) {
        .server => s.server.?.connection(s.slotOf(peer) orelse return null) orelse return null,
        .client => if (peer == server_peer) (if (s.client.?.connection) |*c| c else return null) else return null,
        .offline, .joining => return null,
    };
    return connection.stats;
}

/// Where `peer` is: a server's player's address and port.
pub fn addressOf(app: *const App, peer: u32) ?Address {
    const s = &app.session;
    return switch (s.role) {
        .server => s.server.?.addressOf(s.slotOf(peer) orelse return null),
        .client => if (peer == server_peer) s.client.?.server else null,
        .offline, .joining => null,
    };
}

/// The UDP port this end's socket is on: a server's, which players join;
/// nought off a session.
pub fn boundPort(app: *const App) u16 {
    const socket = app.session.socket orelse return 0;
    return socket.port();
}

/// What a LAN search is answered with from now on.
pub fn describe(app: *App, name: []const u8, info: []const u8) void {
    if (app.session.server) |*server| server.describe(name, info);
}

/// The servers of the LAN asked - on `port`, or the project's - by the
/// broadcast address and this machine: what answers is in `found`. What was
/// found before is forgotten.
pub fn search(app: *App, port: ?u16) Error!void {
    const io = app.io orelse return error.NoIo;
    const s = &app.session;
    if (s.browser == null) {
        s.search_socket = try openSocket(io, 0, true);
        s.browser = .init(app.gpa, s.search_socket.?.transport(), protocolOf(app));
    }
    const to = port orelse networkOf(app).session_port;
    const browser = &s.browser.?;
    browser.search(io, nowOf(io), .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = to } });
    // A server on this machine, which a broadcast may not come back to.
    browser.ask(.{ .ip4 = .loopback(to) });
}

/// The search let go of: its socket closed, what it found forgotten.
pub fn stopSearch(app: *App) void {
    const s = &app.session;
    if (s.browser) |*browser| browser.deinit();
    s.browser = null;
    if (s.search_socket) |*socket| socket.close();
    s.search_socket = null;
}

/// The servers found since the last `search`, good until the next frame.
pub fn foundInto(app: *const App, into: *std.ArrayList(Found), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (app.session.browser) |*browser| for (browser.found.items) |*found| try into.append(gpa, .{
        .address = found.address,
        .name = found.name(),
        .info = found.info(),
        .players = found.players,
        .most = found.most,
        .ping_ns = found.ping_ns,
    });
    const nat = if (app.session.online_nat) |*held| held else return;
    for (nat.found()) |*found| try into.append(gpa, .{
        .address = unknownAddress(),
        .id = found.id,
        .name = found.nameText(),
        .info = found.infoText(),
        .players = found.players,
        .most = found.most,
        .ping_ns = 0,
    });
}

/// `address` as text, without its port: `192.168.1.20`, `::1`.
pub fn hostText(address: Address, buffer: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    switch (address) {
        .ip4 => |a| w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch {},
        .ip6 => |a| {
            var with_port: [64]u8 = undefined;
            var all: std.Io.Writer = .fixed(&with_port);
            a.format(&all) catch {};
            // `[::1]:27015`: what is between the brackets.
            const text = all.buffered();
            const close = std.mem.lastIndexOfScalar(u8, text, ']') orelse text.len;
            w.writeAll(text[@min(1, text.len)..close]) catch {};
        },
    }
    return w.buffered();
}
