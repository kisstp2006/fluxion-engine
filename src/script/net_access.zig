// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `net`: networked play - a server the players
//! join over UDP, or a player joined to one - and the servers of the LAN.
//! What is sent is any value a script holds: numbers, text, vectors,
//! colours, turns, lists, maps and a struct's fields, packed small; it
//! comes out on the other end as it went in, a struct as a map of its
//! fields and an enum's member as its name.
//!
//! ```
//! fn ready(self) {
//!     net.peer_joined.connect(fn (peer: int, hello: string) { print(f"{hello} joined as {peer}"); });
//!     net.message.connect(self.heard);
//!     net.host() catch |err| print("no server:", err);
//! }
//! fn heard(self, peer: int, value: any) {
//!     if (net.isServer()) net.sendAll({"said": value, "by": peer}, .reliable);
//! }
//! // A player:
//! net.join("192.168.1.20") catch |err| print("cannot join:", err);
//! net.joined.connect(fn (me: int) { net.send(1, {"hello": "there"}); });
//! ```
//!
//! **Peers.** The server is 1, and so is a game alone; each player that
//! joins gets the next number from 2. A player hears of the others as they
//! come and go, and what it sends another goes by way of the server.
//!
//! **Signals.** `peer_joined(peer, hello)` and `peer_left(peer, reason)` -
//! on a server, its players; on a player, the others. `message(peer,
//! value)`. `joined(peer)`, a player taken in, with its number;
//! `left(reason)`, a player off its server - `kicked`, `timed_out`,
//! `server_closed`, `full`, `refused` (no such server, or a name not
//! found). They are said before the frame's fixed steps.
//!
//! **Finding servers.** `net.search()` asks the LAN; `net.servers()` lists
//! what answered so far: each a map of `address`, `port`, `name`, `info`,
//! `players`, `max_players` and `ping` in seconds.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const reflect = @import("fluxion_reflect");
const sessions = @import("../net/session.zig");

const log = std.log.scoped(.fluxion_engine);

/// The channel a message goes on: see `net/session.zig`.
pub const NetChannel = enum {
    /// Arrives or not, in any order: what is sent again soon anyway.
    unreliable,
    /// Arrives or not, never after a newer one: where things are, each tick.
    sequenced,
    /// Arrives once, in order: a kill, a chat line, the round won.
    reliable,

    fn of(self: NetChannel) sessions.Channel {
        return switch (self) {
            .unreliable => .unreliable,
            .sequenced => .sequenced,
            .reliable => .reliable,
        };
    }
};

/// What this end of a session is.
pub const NetRole = enum {
    /// Playing alone: the game decides for itself, as a server does.
    offline,
    /// A server players join.
    server,
    /// On the way to a server.
    joining,
    /// A player joined to a server.
    client,
};

pub const NetAccess = struct {
    app: *App,

    pub const reflect_name = "Net";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .host = .{ attr.Params{ .names = &.{ "port", "max_players", "name", "info" } }, attr.defaults(.{ @as(i64, 0), @as(i64, 0), "", "" }), flux.GivesErrors{} },
        .join = .{ attr.Params{ .names = &.{ "address", "port", "hello" } }, attr.defaults(.{ @as(i64, 0), "" }), flux.GivesErrors{} },
        .leave = .{},
        .send = .{ attr.Params{ .names = &.{ "vm", "peer", "value", "channel" } }, attr.defaults(.{NetChannel.reliable}) },
        .sendAll = .{ attr.Params{ .names = &.{ "vm", "value", "channel" } }, attr.defaults(.{NetChannel.reliable}) },
        .kick = .{attr.Params{ .names = &.{"peer"} }},
        .role = .{},
        .id = .{},
        .isServer = .{},
        .isOnline = .{},
        .port = .{},
        .peers = .{attr.Params{ .names = &.{"vm"} }},
        .ping = .{attr.Params{ .names = &.{"peer"} }},
        .address = .{ attr.Params{ .names = &.{ "vm", "peer" } } },
        .describe = .{attr.Params{ .names = &.{ "name", "info" } }},
        .search = .{ attr.Params{ .names = &.{"port"} }, attr.defaults(.{@as(i64, 0)}), flux.GivesErrors{} },
        .servers = .{attr.Params{ .names = &.{"vm"} }},
        .stopSearch = .{},
    };

    /// Be a server of this game, players joining it from now on: on `port`
    /// for `max_players` - nought for the project's `network.session_port`
    /// and `session_max_players` - answering LAN searches with `name` and
    /// `info`: the map, the mode. A session there was is left first. Fails
    /// with `CannotListen` where another program has the port.
    pub fn host(self: *NetAccess, on_port: i64, max_players: i64, name: []const u8, info: []const u8) anyerror!void {
        return self.app.hostSession(.{
            .port = portOf(on_port),
            .max_players = if (max_players > 0) @intCast(@min(max_players, std.math.maxInt(u16))) else null,
            .name = name,
            .info = info,
        });
    }

    /// Join the server at `address` - `192.168.1.20`, `localhost` or a
    /// name - on `port`, nought for the project's, saying `hello`: a name, a
    /// password. A session there was is left first. `joined` is said once
    /// in, `left` if not. Fails with `BadAddress` for an address that is
    /// none.
    pub fn join(self: *NetAccess, to: []const u8, on_port: i64, hello: []const u8) anyerror!void {
        return self.app.joinSession(to, portOf(on_port), hello);
    }

    /// Off the session: a server tells its players it is closing, a player
    /// its server it is going. Playing alone from now on.
    pub fn leave(self: *NetAccess) void {
        self.app.leaveSession();
    }

    /// `value` to `peer` on `channel`, at the end of the frame: a server's
    /// to a player, a player's to the server (1) or to another player.
    /// False where it cannot go: no such peer, not joined, too large - a
    /// reliable message 64 KiB, the others one datagram, about 1 KiB.
    pub fn send(self: *NetAccess, vm: *flux.Vm, peer: i64, value: flux.Value, channel: NetChannel) flux.Vm.Error!bool {
        const bytes = try packed_(vm, value);
        defer vm.gpa.free(bytes);
        if (peer <= 0 or peer > std.math.maxInt(u32)) return false;
        self.app.sessionSend(@intCast(peer), channel.of(), bytes) catch |err| {
            log.warn("a message to peer {d} is not sent: {t}", .{ peer, err });
            return false;
        };
        return true;
    }

    /// `value` to every other peer on `channel`, at the end of the frame.
    pub fn sendAll(self: *NetAccess, vm: *flux.Vm, value: flux.Value, channel: NetChannel) flux.Vm.Error!bool {
        const bytes = try packed_(vm, value);
        defer vm.gpa.free(bytes);
        self.app.sessionSendAll(channel.of(), bytes) catch |err| {
            if (err != error.NotConnected) log.warn("a message to everyone is not sent: {t}", .{err});
            return false;
        };
        return true;
    }

    /// A server's player sent away, told it was kicked.
    pub fn kick(self: *NetAccess, peer: i64) void {
        if (peer <= 0 or peer > std.math.maxInt(u32)) return;
        self.app.kickSessionPeer(@intCast(peer));
    }

    /// What this end is: alone, a server, joining one, or joined.
    pub fn role(self: *NetAccess) NetRole {
        return switch (self.app.sessionRole()) {
            .offline => .offline,
            .server => .server,
            .joining => .joining,
            .client => .client,
        };
    }

    /// This end's peer number: 1 for a server and a game alone, a player's
    /// own once joined, nought while joining.
    pub fn id(self: *NetAccess) i64 {
        return self.app.sessionPeer();
    }

    /// Whether this end decides: a server, or a game alone.
    pub fn isServer(self: *NetAccess) bool {
        return switch (self.app.sessionRole()) {
            .offline, .server => true,
            .joining, .client => false,
        };
    }

    /// Whether this end is a server or a player joined to one.
    pub fn isOnline(self: *NetAccess) bool {
        return switch (self.app.sessionRole()) {
            .server, .client => true,
            .offline, .joining => false,
        };
    }

    /// The UDP port this end is on: a server's, which its players join.
    /// Nought off a session.
    pub fn port(self: *NetAccess) i64 {
        return self.app.sessionPort();
    }

    /// The other peers: a server's players; a player's server and the
    /// other players.
    pub fn peers(self: *NetAccess, vm: *flux.Vm) flux.Vm.Error!flux.Value {
        var numbers: std.ArrayList(u32) = .empty;
        defer numbers.deinit(vm.gpa);
        try self.app.sessionPeers(vm.gpa, &numbers);
        var items: std.ArrayList(flux.Value) = .empty;
        defer items.deinit(vm.gpa);
        for (numbers.items) |n| try items.append(vm.gpa, .int(n));
        return vm.newList(.any, items.items);
    }

    /// The round trip to `peer`, in seconds; -1 for no such peer.
    pub fn ping(self: *NetAccess, peer: i64) f64 {
        if (peer <= 0 or peer > std.math.maxInt(u32)) return -1;
        return self.app.sessionRoundTrip(@intCast(peer)) orelse -1;
    }

    /// Where `peer` is, `192.168.1.20:27015`; "" for no such peer.
    pub fn address(self: *NetAccess, vm: *flux.Vm, peer: i64) flux.Vm.Error!flux.Value {
        if (peer <= 0 or peer > std.math.maxInt(u32)) return vm.string("");
        const where = self.app.sessionAddress(@intCast(peer)) orelse return vm.string("");
        var buffer: [80]u8 = undefined;
        var host_buffer: [64]u8 = undefined;
        const said = std.fmt.bufPrint(&buffer, "{s}:{d}", .{ sessions.hostText(where, &host_buffer), where.getPort() }) catch "";
        return vm.string(said);
    }

    /// What a server answers LAN searches with from now on: the map
    /// changed, the mode.
    pub fn describe(self: *NetAccess, name: []const u8, info: []const u8) void {
        self.app.describeSession(name, info);
    }

    /// Ask the LAN for this game's servers - on `port`, nought for the
    /// project's - and this machine. `servers()` lists what answers.
    pub fn search(self: *NetAccess, on_port: i64) anyerror!void {
        return self.app.searchSessions(portOf(on_port));
    }

    /// The servers found since the last `search`: each a map of `address`,
    /// `port`, `name`, `info`, `players`, `max_players` and `ping`.
    pub fn servers(self: *NetAccess, vm: *flux.Vm) flux.Vm.Error!flux.Value {
        var found: std.ArrayList(sessions.Found) = .empty;
        defer found.deinit(vm.gpa);
        try self.app.foundSessions(vm.gpa, &found);
        var items: std.ArrayList(flux.Value) = .empty;
        defer items.deinit(vm.gpa);
        defer for (items.items) |_| vm.popRoot();
        for (found.items) |one| {
            const made = blk: {
                var host_buffer: [64]u8 = undefined;
                const keys = [_][]const u8{ "address", "port", "name", "info", "players", "max_players", "ping" };
                var values: [keys.len]flux.Value = undefined;
                var key_values: [keys.len]flux.Value = undefined;
                // Each rooted until the map has it: making the next can
                // collect.
                var rooted: usize = 0;
                defer for (0..rooted) |_| vm.popRoot();
                values[0] = try vm.string(sessions.hostText(one.address, &host_buffer));
                try vm.pushRoot(values[0]);
                rooted += 1;
                values[1] = .int(one.address.getPort());
                values[2] = try vm.string(one.name);
                try vm.pushRoot(values[2]);
                rooted += 1;
                values[3] = try vm.string(one.info);
                try vm.pushRoot(values[3]);
                rooted += 1;
                values[4] = .int(one.players);
                values[5] = .int(one.most);
                values[6] = .float(@as(f64, @floatFromInt(one.ping_ns)) / std.time.ns_per_s);
                for (keys, &key_values) |key, *into| {
                    into.* = try vm.string(key);
                    try vm.pushRoot(into.*);
                    rooted += 1;
                }
                break :blk try vm.newMap(.any, .any, &key_values, &values);
            };
            try vm.pushRoot(made);
            items.append(vm.gpa, made) catch |err| {
                vm.popRoot();
                return err;
            };
        }
        return vm.newList(.any, items.items);
    }

    /// The LAN search let go of.
    pub fn stopSearch(self: *NetAccess) void {
        self.app.stopSessionSearch();
    }

    /// The signals of `net`'s a script reaches as members.
    pub const signal_names = [5][]const u8{ "peer_joined", "peer_left", "message", "joined", "left" };
    pub const signal_docs = [5][]const u8{
        "Said when a peer joins: on a server, a player, with the hello it said; on a player, another player. `net.peer_joined.connect(fn(peer: int, hello: string) { ... })`.",
        "Said when a peer leaves, with why: `left`, `kicked`, `timed_out`, `broken`. `net.peer_left.connect(fn(peer: int, reason: string) { ... })`.",
        "Said for each message that came, with who sent it and what: `net.message.connect(fn(peer: int, value: any) { ... })`.",
        "Said to a player taken in by its server, with its own peer number: `net.joined.connect(fn(me: int) { ... })`.",
        "Said to a player off its server, or never let on, with why: `kicked`, `timed_out`, `server_closed`, `full`, `refused`. `net.left.connect(fn(reason: string) { ... })`.",
    };
    pub const signal_args = [5]*const reflect.Type{
        reflect.typeOf(struct { peer: i64, hello: []const u8 }),
        reflect.typeOf(struct { peer: i64, reason: []const u8 }),
        reflect.typeOf(struct { peer: i64, value: flux.Value }),
        reflect.typeOf(struct { peer: i64 }),
        reflect.typeOf(struct { reason: []const u8 }),
    };

    pub const Signal = enum { peer_joined, peer_left, message, joined, left };
};

fn portOf(port: i64) ?u16 {
    if (port <= 0 or port > std.math.maxInt(u16)) return null;
    return @intCast(port);
}

// -------------------------------------------------------------------------
// Values, packed
// -------------------------------------------------------------------------
//
// A byte saying what follows, then it: numbers as small as they go - an
// integer zigzagged in seven-bit groups, a float in four bytes where that
// loses nothing - vectors, colours and turns as four-byte floats, text and
// lists and maps with their length first.

const Tag = enum(u8) {
    null = 0,
    false = 1,
    true = 2,
    int = 3,
    float32 = 4,
    float64 = 5,
    string = 6,
    vec2 = 7,
    vec3 = 8,
    color = 9,
    quat = 10,
    list = 11,
    map = 12,
};

/// How deep lists and maps may be nested in a message.
const most_depth = 32;

fn packed_(vm: *flux.Vm, value: flux.Value) flux.Vm.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.gpa);
    pack(vm, &out, value, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return vm.fail("net cannot send {s}", .{@import("script.zig").typeName(value)}),
        error.TooDeep => return vm.fail("net: the value is nested too deeply, or holds itself", .{}),
    };
    return out.toOwnedSlice(vm.gpa);
}

const PackError = error{ OutOfMemory, Unsupported, TooDeep };

/// `value` packed onto `out`.
pub fn pack(vm: *flux.Vm, out: *std.ArrayList(u8), value: flux.Value, depth: u32) PackError!void {
    if (depth > most_depth) return error.TooDeep;
    const gpa = vm.gpa;
    switch (value.tag) {
        .null => try out.append(gpa, @intFromEnum(Tag.null)),
        .bool => try out.append(gpa, @intFromEnum(if (value.asBool()) Tag.true else Tag.false)),
        .int => {
            try out.append(gpa, @intFromEnum(Tag.int));
            const n = value.asInt();
            try varint(gpa, out, @bitCast((n << 1) ^ (n >> 63)));
        },
        .float => {
            const x = value.asFloat();
            const narrow: f32 = @floatCast(x);
            if (@as(f64, narrow) == x or std.math.isNan(x)) {
                try out.append(gpa, @intFromEnum(Tag.float32));
                try floats(gpa, out, &.{narrow});
            } else {
                try out.append(gpa, @intFromEnum(Tag.float64));
                try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(x))));
            }
        },
        .string => try text(gpa, out, value.as(flux.object.String).bytes()),
        .enum_value => try text(gpa, out, flux.object.EnumType.from(value.obj()).members[value.extra].bytes()),
        .vec2 => {
            try out.append(gpa, @intFromEnum(Tag.vec2));
            try floats(gpa, out, &value.asVec2());
        },
        .vec3 => {
            try out.append(gpa, @intFromEnum(Tag.vec3));
            try floats(gpa, out, &value.asVec3());
        },
        .color => {
            try out.append(gpa, @intFromEnum(Tag.color));
            try floats(gpa, out, &value.as(flux.object.Color).rgba);
        },
        .quat => {
            try out.append(gpa, @intFromEnum(Tag.quat));
            try floats(gpa, out, &value.as(flux.object.Quat).xyzw);
        },
        .list => {
            const items = value.as(flux.object.List).items.items;
            try out.append(gpa, @intFromEnum(Tag.list));
            try varint(gpa, out, items.len);
            for (items) |item| try pack(vm, out, item, depth + 1);
        },
        .map => {
            const table = &value.as(flux.object.Map).table;
            try out.append(gpa, @intFromEnum(Tag.map));
            try varint(gpa, out, table.count());
            var it = table.iterator();
            while (it.next()) |entry| {
                try pack(vm, out, entry.key, depth + 1);
                try pack(vm, out, entry.value, depth + 1);
            }
        },
        // A struct's own fields, as a map of them by name.
        .instance => {
            const instance = value.as(flux.object.Instance);
            var count: usize = 0;
            for (instance.class.fields) |f| count += @intFromBool(!f.is_signal and !f.host);
            try out.append(gpa, @intFromEnum(Tag.map));
            try varint(gpa, out, count);
            for (instance.class.fields, instance.fields()) |f, x| {
                if (f.is_signal or f.host) continue;
                try text(gpa, out, f.name.bytes());
                try pack(vm, out, x, depth + 1);
            }
        },
        else => return error.Unsupported,
    }
}

fn varint(gpa: Allocator, out: *std.ArrayList(u8), value: u64) error{OutOfMemory}!void {
    var n = value;
    while (n >= 0x80) : (n >>= 7) try out.append(gpa, @as(u8, @truncate(n)) | 0x80);
    try out.append(gpa, @truncate(n));
}

fn floats(gpa: Allocator, out: *std.ArrayList(u8), xs: []const f32) error{OutOfMemory}!void {
    for (xs) |x| try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(x))));
}

fn text(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) error{OutOfMemory}!void {
    try out.append(gpa, @intFromEnum(Tag.string));
    try varint(gpa, out, bytes.len);
    try out.appendSlice(gpa, bytes);
}

/// What `pack` packed, made again; `error.Malformed` for bytes that are not
/// a value - a peer's that lies.
pub fn unpack(vm: *flux.Vm, bytes: []const u8) (flux.Vm.Error || error{Malformed})!flux.Value {
    var reader: Reader = .{ .bytes = bytes };
    const value = try reader.value(vm, 0);
    if (reader.at != bytes.len) return error.Malformed;
    return value;
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(r: *Reader) error{Malformed}!u8 {
        if (r.at >= r.bytes.len) return error.Malformed;
        defer r.at += 1;
        return r.bytes[r.at];
    }

    fn varint(r: *Reader) error{Malformed}!u64 {
        var n: u64 = 0;
        var shift: u7 = 0;
        while (shift < 64) : (shift += 7) {
            const b = try r.byte();
            n |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b < 0x80) return n;
        }
        return error.Malformed;
    }

    /// A count of things each at least a byte: never more than are left.
    fn count(r: *Reader) error{Malformed}!usize {
        const n = try r.varint();
        if (n > r.bytes.len - r.at) return error.Malformed;
        return @intCast(n);
    }

    fn take(r: *Reader, n: usize) error{Malformed}![]const u8 {
        if (n > r.bytes.len - r.at) return error.Malformed;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn floats(r: *Reader, comptime n: usize) error{Malformed}![n]f32 {
        var out: [n]f32 = undefined;
        for (&out) |*x| x.* = @bitCast(std.mem.littleToNative(u32, std.mem.bytesToValue(u32, try r.take(4))));
        return out;
    }

    fn value(r: *Reader, vm: *flux.Vm, depth: u32) (flux.Vm.Error || error{Malformed})!flux.Value {
        if (depth > most_depth) return error.Malformed;
        const tag = std.enums.fromInt(Tag, try r.byte()) orelse return error.Malformed;
        switch (tag) {
            .null => return .null,
            .false => return .boolean(false),
            .true => return .boolean(true),
            .int => {
                const z = try r.varint();
                return .int(@bitCast((z >> 1) ^ (0 -% (z & 1))));
            },
            .float32 => return .float((try r.floats(1))[0]),
            .float64 => return .float(@bitCast(std.mem.littleToNative(u64, std.mem.bytesToValue(u64, try r.take(8))))),
            .string => return vm.string(try r.take(try r.count())),
            .vec2 => {
                const xy = try r.floats(2);
                return .vec2(xy[0], xy[1]);
            },
            .vec3 => {
                const xyz = try r.floats(3);
                return .vec3(xyz[0], xyz[1], xyz[2]);
            },
            .color => return vm.newColor(try r.floats(4)),
            .quat => return vm.newQuat(try r.floats(4)),
            .list => {
                const n = try r.count();
                var items: std.ArrayList(flux.Value) = .empty;
                defer items.deinit(vm.gpa);
                defer for (items.items) |_| vm.popRoot();
                try items.ensureTotalCapacity(vm.gpa, n);
                for (0..n) |_| {
                    const item = try r.value(vm, depth + 1);
                    try vm.pushRoot(item);
                    items.appendAssumeCapacity(item);
                }
                return vm.newList(.any, items.items);
            },
            .map => {
                const n = try r.count();
                var keys: std.ArrayList(flux.Value) = .empty;
                defer keys.deinit(vm.gpa);
                var values: std.ArrayList(flux.Value) = .empty;
                defer values.deinit(vm.gpa);
                defer for (0..keys.items.len + values.items.len) |_| vm.popRoot();
                try keys.ensureTotalCapacity(vm.gpa, n);
                try values.ensureTotalCapacity(vm.gpa, n);
                for (0..n) |_| {
                    const key = try r.value(vm, depth + 1);
                    try vm.pushRoot(key);
                    keys.appendAssumeCapacity(key);
                    // A map's key is a value that can be one: not a float
                    // that is no number.
                    if (key.tag == .float and std.math.isNan(key.asFloat())) return error.Malformed;
                    const item = try r.value(vm, depth + 1);
                    try vm.pushRoot(item);
                    values.appendAssumeCapacity(item);
                }
                return vm.newMap(.any, .any, keys.items, values.items);
            },
        }
    }
};
