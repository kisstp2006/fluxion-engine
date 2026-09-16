// SPDX-License-Identifier: BSD-3-Clause

//! Signals, as Godot 4 has them: a component says something happened, and
//! whoever is connected to it hears.
//!
//! ```zig
//! pub const Health = struct {
//!     hp: f32 = 100,
//!     pub const signals = .{ .died = struct {}, .hit = struct { damage: f32, by: fx.Entity } };
//! };
//!
//! const hit = app.signal(player, Health, .hit);          // Godot: player.hit
//! try hit.connect(.method(hud, "_on_player_hit"), .{});  // Godot: Callable(hud, "_on_player_hit")
//! try hit.connectFn(onHit, .{ .flags = .{ .one_shot = true } });
//! try app.emit(player, Health, .hit, .{ .damage = 5, .by = sword });
//! ```
//!
//! **A component declares what it can say**, as `pub const signals`: each a
//! name and the struct of its arguments, in order. An entity has the signals
//! of its components, and two components that say the same thing are told
//! apart as `Health.hit`.
//!
//! **A connection is data**, kept beside the world as the names are, never in
//! a component, and to one component's signal: another that says the same
//! thing, added later, does not make it two. A scene holds the ones made
//! with `.persist`, by UUID, and a connection to a signal or a method this
//! build knows nothing of is kept as it was read, written back as it was,
//! and never heard: an editor that has not got the game's components must
//! not lose the game's connections.
//!
//! **An emit is heard when the emitting system returns** - with the calls
//! and their arguments fixed as it emitted - at the sync point where
//! `app.commands` is done too, and never under the emitting system's query.
//! That is the one thing Godot does otherwise: its emit calls at once. A
//! `.deferred` connection is heard at the end of the frame instead, after
//! `.late`, as Godot's is at idle time.
//!
//! **A named connection is looked up when it is called**: a method one of the
//! target's components lists in its `reflect_methods`, one its script
//! declares, or one the game gave `App.addMethod`. Connecting never asks, as
//! Godot's never does - a tool connects to the game's methods, which it
//! cannot see.
//!
//! **A script's signals are its entity's**, under `Script`: a `signal died`
//! in the struct is `Script.died` in the table, listed, connected and saved
//! as a component's is, and a script's emit is heard by the table's
//! connections as a component's. See `script`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const reflect = @import("fluxion_reflect");
const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("App.zig");
const Color = @import("color.zig").Color;

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

pub const Error = error{
    /// No component of the entity declares a signal by that name.
    NoSuchSignal,
    /// Two of the entity's components declare it: name one, `Health.hit`.
    AmbiguousSignal,
    /// That callable is connected to that signal already. See
    /// `Flags.reference_counted`.
    AlreadyConnected,
    /// A Zig function cannot be saved with a scene, as Godot's lambdas cannot.
    NotPersistable,
    /// One drain made `Signals.max_calls` calls: a handler that emits what
    /// it hears, round and round.
    TooManyCalls,
} || Allocator.Error;

/// What a method call made for a signal can fail with, besides the method's
/// own error.
pub const CallError = error{
    /// Nothing on the target has a method by that name.
    NoSuchMethod,
    /// Two of the target's components have it: name one, `Text2D.set`.
    AmbiguousMethod,
    /// The call's arguments are not the method's, in number or in kind.
    WrongArguments,
};

/// One signal a component declares.
pub const Decl = struct {
    name: []const u8,
    /// The struct of its arguments: its fields are their names and types.
    args: *const reflect.Type,
};

/// The signals `T` declares, as its `pub const signals` lists them.
pub fn declsOf(comptime T: type) []const Decl {
    return comptime blk: {
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "signals")) break :blk &.{};
        const listed = T.signals;
        const fields = @typeInfo(@TypeOf(listed)).@"struct".fields;
        var decls: [fields.len]Decl = undefined;
        for (fields, 0..) |field, i| {
            const Args = @field(listed, field.name);
            if (@TypeOf(Args) != type or @typeInfo(Args) != .@"struct")
                @compileError("fluxion-engine: " ++ @typeName(T) ++ ".signals." ++ field.name ++ " is the struct of its arguments, as in `.hit = struct { damage: f32 }`");
            decls[i] = .{ .name = field.name, .args = reflect.typeOf(Args) };
        }
        const final = decls;
        break :blk &final;
    };
}

/// A signal an entity has: which of its components declares it, and what
/// it says. Godot's `get_signal_list` entry.
pub const Info = struct {
    /// What a scene calls the component: `Script` for a signal the
    /// entity's script declares.
    component: []const u8,
    name: []const u8,
    /// The struct of its arguments. A script's signal has no Zig struct, and
    /// this has no fields: `signature` and `arity` say what it gives.
    args: *const reflect.Type,
    /// A script's signal, its parameters as written: `by: string, hp: int`.
    /// Empty for a component's.
    signature: []const u8 = "",
    /// How many arguments a script's signal gives. Null for a component's,
    /// whose `args` says.
    arity: ?u8 = null,
};

/// Godot's `ConnectFlags`.
pub const Flags = packed struct(u8) {
    /// Heard at the end of the frame, after `.late`, rather than as the
    /// emitting system returns. Godot's `CONNECT_DEFERRED`.
    deferred: bool = false,
    /// Saved with the scene. What an editor's connections are, and what
    /// every connection a scene made is. Godot's `CONNECT_PERSIST`.
    persist: bool = false,
    /// Taken away as it is emitted, before it is heard. With
    /// `reference_counted`, each emit takes one count.
    one_shot: bool = false,
    /// A second connect counts up rather than failing, and each disconnect
    /// counts down.
    reference_counted: bool = false,
    /// The entity that emitted, after the emitted arguments and before the
    /// binds. Godot 4.5's `CONNECT_APPEND_SOURCE_OBJECT`.
    append_source: bool = false,
    _: u3 = 0,
};

/// A value a connection hands its method after the signal's own: what a
/// scene can write, as Godot's binds are Variants.
pub const Bind = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    vec2: math.Vec2,
    color: Color,
    entity: Entity,

    fn value(self: *const Bind) reflect.Value {
        return switch (self.*) {
            inline else => |*held| .of(held),
        };
    }

    fn dupe(self: Bind, gpa: Allocator) Allocator.Error!Bind {
        return switch (self) {
            .string => |text| .{ .string = try gpa.dupe(u8, text) },
            else => self,
        };
    }

    fn free(self: Bind, gpa: Allocator) void {
        if (self == .string) gpa.free(self.string);
    }

    pub fn eql(a: Bind, b: Bind) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |text| std.mem.eql(u8, text, b.string),
            .entity => |e| e.eql(b.entity),
            inline else => |held, tag| std.meta.eql(held, @field(b, @tagName(tag))),
        };
    }
};

/// How a connection is made. Godot's flags, and the arguments it drops and
/// adds.
pub const Options = struct {
    flags: Flags = .{},
    /// How many of the emitted arguments, from the last, the method is not
    /// handed. Godot's `Callable.unbind`.
    unbinds: u8 = 0,
    /// Handed to the method after the rest. Godot's `Callable.bind`.
    binds: []const Bind = &.{},
};

/// What a signal calls. Godot's `Callable`.
pub const Callable = union(enum) {
    /// A method, looked up by name on `target` when it is called.
    named: Named,
    /// A Zig function: Godot's lambda. Never saved with a scene.
    zig: ZigFn,

    pub const Named = struct {
        target: Entity,
        /// A method one of the target's components lists, or one given to
        /// `App.addMethod`; `Component.method` when two components have it.
        name: []const u8,
    };

    pub const ZigFn = struct {
        call: *const fn (app: *App, source: Entity, args: []const reflect.Value) anyerror!void,
        /// The function it calls, by address: what makes two of one the same.
        id: usize,
    };

    /// The method called `name` on `target`: Godot's
    /// `Callable(target, "name")`.
    pub fn method(target: Entity, name: []const u8) Callable {
        return .{ .named = .{ .target = target, .name = name } };
    }

    /// A Zig function taking the app and the signal's arguments as their
    /// struct - `fn (app: *App, args: Health.Hit) !void` - handed each as
    /// the emit gave it.
    pub fn function(comptime f: anytype) Callable {
        const Args = @typeInfo(@TypeOf(f)).@"fn".params[1].type.?;
        const Wrapper = struct {
            fn call(app: *App, _: Entity, args: []const reflect.Value) anyerror!void {
                var typed: Args = undefined;
                const fields = @typeInfo(Args).@"struct".fields;
                if (args.len != fields.len) return error.WrongArguments;
                inline for (fields, 0..) |field, i| {
                    reflect.Value.of(&@field(typed, field.name)).convertFrom(args[i]) catch return error.WrongArguments;
                }
                return f(app, typed);
            }
        };
        return .{ .zig = .{ .call = Wrapper.call, .id = @intFromPtr(&f) } };
    }

    pub fn eql(a: Callable, b: Callable) bool {
        return switch (a) {
            .named => |n| b == .named and n.target.eql(b.named.target) and std.mem.eql(u8, n.name, b.named.name),
            .zig => |z| b == .zig and z.id == b.zig.id,
        };
    }
};

/// A connection as it is kept. Godot's `get_signal_connection_list` entry,
/// with the flags and the binds besides.
pub const Connection = struct {
    /// The entity whose signal it is.
    source: Entity,
    /// In a listing and a scene, the bare name, or `Component.name` when
    /// another of the entity's components declares the same name; one this
    /// build does not know, as it was written. The table itself keeps a
    /// known one as `Component.name` always, so a component added later
    /// cannot make it two signals.
    signal: []const u8,
    callable: Callable,
    options: Options,
    /// How many times it was connected, with `reference_counted`.
    count: u32,
    /// Whether one of the entity's components declared the signal when it
    /// was connected. One that did not is kept, listed and saved as it was
    /// written, and never heard - as Godot keeps what a scene says of a
    /// script it has not got.
    known: bool,
};

/// Which signal a connection is to, as the table finds it.
pub const Key = struct {
    /// What a scene calls the component that declares it; empty for a
    /// signal no component here declares, whose `name` is then as written.
    component: []const u8 = "",
    name: []const u8,

    /// Whether the connection kept under `held` is to this signal.
    fn keeps(self: Key, held: []const u8) bool {
        if (self.component.len == 0) return std.mem.eql(u8, held, self.name);
        return matches(held, self.component, self.name);
    }
};

/// A signal of one entity: Godot 4's `Signal`, what `connect` and `emit` are
/// asked of. A value, as cheap to make again as to keep. See `App.signal`
/// and `App.signalNamed`.
pub const Signal = struct {
    app: *App,
    source: Entity,
    /// What a scene calls the component that declares it.
    component: []const u8,
    name: []const u8,

    pub fn key(self: Signal) Key {
        return .{ .component = self.component, .name = self.name };
    }

    /// Godot's `connect`: `callable` hears every emit from now on, until it
    /// is disconnected or either entity dies. A second connect of the same
    /// callable is `error.AlreadyConnected`, unless `reference_counted`.
    pub fn connect(self: Signal, callable: Callable, options: Options) Error!void {
        return self.app.signals.connect(self.source, self.key(), callable, options);
    }

    /// A Zig function, Godot's lambda: `fn (app: *App, args: Health.Hit) !void`.
    /// Never saved with a scene.
    pub fn connectFn(self: Signal, comptime f: anytype, options: Options) Error!void {
        return self.connect(.function(f), options);
    }

    pub fn disconnect(self: Signal, callable: Callable) void {
        _ = self.app.signals.disconnect(self.source, self.key(), callable);
    }

    pub fn isConnected(self: Signal, callable: Callable) bool {
        return self.app.signals.isConnected(self.source, self.key(), callable);
    }

    pub fn hasConnections(self: Signal) bool {
        var one: [1]Connection = undefined;
        return self.connections(&one).len != 0;
    }

    /// Its connections, in the order they were made - the order they are
    /// heard in - as many as `found` holds. One the table keeps unknown is
    /// not among them, being never heard; `App.connectionsFrom` lists it.
    pub fn connections(self: Signal, found: []Connection) []Connection {
        const listed = self.app.signals.connectionsOf(self.source, self.component, self.name, found);
        for (listed) |*c| c.signal = self.app.signalWritten(c.*);
        return listed;
    }

    /// Godot's `emit`: every connection hears it when the emitting system
    /// returns - a deferred one at the end of the frame - with these
    /// arguments, in the declared order. Each is converted to what the
    /// method takes as it is called, so `.{ .damage = 5 }` does for an
    /// `f32`; `App.emit` checks them as it is compiled instead.
    pub fn emit(self: Signal, args: anytype) Error!void {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        // A literal's numbers have no type yet, and so no place: given one.
        var ints: [fields.len]i64 = undefined;
        var floats: [fields.len]f64 = undefined;
        const held = args;
        _ = &held;
        var values: [fields.len]reflect.Value = undefined;
        inline for (fields, 0..) |field, i| {
            values[i] = switch (@typeInfo(field.type)) {
                .comptime_int => blk: {
                    ints[i] = @field(args, field.name);
                    break :blk .of(&ints[i]);
                },
                .comptime_float => blk: {
                    floats[i] = @field(args, field.name);
                    break :blk .of(&floats[i]);
                },
                else => .of(&@field(held, field.name)),
            };
        }
        return self.emitValues(&values);
    }

    /// `emit`, with the arguments as values: what a console or a script
    /// emits with.
    pub fn emitValues(self: Signal, values: []const reflect.Value) Error!void {
        return self.app.signals.emit(self.source, self.component, self.name, values);
    }
};

/// A method `App.addMethod` was given, taking the target and the arguments.
pub const Method = *const fn (app: *App, self: Entity, args: []const reflect.Value) anyerror!void;

/// A method as `App.addMethod` keeps it: the call, and what it takes.
pub const Registered = struct {
    call: Method,
    /// Its parameters after the app and the target.
    params: []const reflect.Param,
};

/// A method a connection to an entity can name: Godot's `get_method_list`
/// entry, what an editor's method picker lists.
pub const MethodInfo = struct {
    /// What a scene calls the component whose method it is - `Script` for
    /// one the entity's script declares - and empty for one given to
    /// `App.addMethod`, which every entity has.
    component: []const u8,
    name: []const u8,
    /// What a call hands it, in order: not the component, nor the app and
    /// the target. Empty for a script's, whose parameters have no Zig types:
    /// `signature` and `arity` say what it takes.
    params: []const reflect.Param,
    /// A script's method, its parameters as written: `damage: float, by`.
    /// Empty for a Zig one.
    signature: []const u8 = "",
    /// How many arguments a script's method takes. Null for a Zig one,
    /// whose `params` says.
    arity: ?u8 = null,
};

/// `f`, a method for `App.addMethod`, kept with its parameters described.
pub fn registered(comptime f: anytype) Registered {
    const described = comptime blk: {
        const params = @typeInfo(@TypeOf(f)).@"fn".params;
        var list: [params.len -| 2]reflect.Param = undefined;
        for (params[@min(2, params.len)..], &list) |p, *into| {
            into.* = .{ .type = reflect.typeOf(p.type.?), .is_noalias = p.is_noalias };
        }
        const final = list;
        break :blk &final;
    };
    return .{ .call = methodOf(f), .params = described };
}

/// `f` - `fn (app: *App, self: Entity, damage: f32, by: Entity) !void` - as a
/// `Method`: the values converted to its parameters, and their number
/// checked, when it is called.
pub fn methodOf(comptime f: anytype) Method {
    const F = @TypeOf(f);
    const params = @typeInfo(F).@"fn".params;
    if (params.len < 2 or params[0].type != *App or params[1].type != Entity)
        @compileError("fluxion-engine: a method a signal calls is `fn (app: *App, self: Entity, ...) !void`");
    return struct {
        fn call(app: *App, self: Entity, args: []const reflect.Value) anyerror!void {
            if (args.len != params.len - 2) return error.WrongArguments;
            var tuple: std.meta.ArgsTuple(F) = undefined;
            tuple[0] = app;
            tuple[1] = self;
            inline for (params[2..], 0..) |_, i| {
                reflect.Value.of(&tuple[i + 2]).convertFrom(args[i]) catch return error.WrongArguments;
            }
            const returned = @call(.auto, f, tuple);
            if (@typeInfo(@TypeOf(returned)) == .error_union) try returned;
        }
    }.call;
}

/// Whether a connection the table keeps under `held` is to the signal
/// `component` declares as `name`: whether `held` is `Component.name`.
fn matches(held: []const u8, component: []const u8, name: []const u8) bool {
    return held.len == component.len + 1 + name.len and
        std.mem.startsWith(u8, held, component) and held[component.len] == '.' and
        std.mem.endsWith(u8, held, name);
}

/// A call an emit made, waiting for its sync point.
const Call = struct {
    source: Entity,
    callable: Callable,
    /// `Component.name`, for a message.
    component: []const u8,
    signal: []const u8,
    args: []const reflect.Value,
};

/// Every connection, the calls waiting to be made, and the switch that
/// makes none: `app.signals`.
pub const Signals = struct {
    gpa: Allocator,

    /// Whether an emit calls anything. Off in an editor, which edits a scene
    /// rather than plays it: the connections are kept, saved and listed, and
    /// nothing hears them. Godot's editor runs no scripts but tool ones.
    dispatch: bool = true,

    /// Every connection, by the entity whose signal it is, each list in the
    /// order its connections were made: the order they are heard in.
    from: std.AutoArrayHashMapUnmanaged(Entity, std.ArrayList(Connection)) = .empty,

    /// Entities whose emits do nothing. Godot's `set_block_signals`.
    blocked: std.AutoHashMapUnmanaged(Entity, void) = .empty,

    /// What `App.addMethod` was given.
    methods: std.StringHashMapUnmanaged(Registered) = .empty,

    /// Heard when the emitting system returns.
    queue: std.ArrayList(Call) = .empty,
    /// Heard at the end of the frame.
    deferred: std.ArrayList(Call) = .empty,
    /// Where waiting calls keep their arguments, and copies of the names
    /// they need; let go once nothing waits.
    arena: std.heap.ArenaAllocator,

    /// The most calls one drain makes before it calls it a loop.
    max_calls: usize = 10_000,
    /// How many calls failed - the method missing or wrong, or its error -
    /// each also said in the log.
    failures: usize = 0,

    pub fn init(gpa: Allocator) Signals {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Signals) void {
        self.clear();
        self.from.deinit(self.gpa);
        self.blocked.deinit(self.gpa);
        var names = self.methods.keyIterator();
        while (names.next()) |name| self.gpa.free(name.*);
        self.methods.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.deferred.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Every connection gone, and every call waiting: a world cleared.
    /// The methods stay, being the game's rather than the world's.
    pub fn clear(self: *Signals) void {
        for (self.from.values()) |*list| {
            for (list.items) |c| self.freeConnection(c);
            list.deinit(self.gpa);
        }
        self.from.clearRetainingCapacity();
        self.blocked.clearRetainingCapacity();
        self.queue.clearRetainingCapacity();
        self.deferred.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    fn freeConnection(self: *Signals, c: Connection) void {
        self.gpa.free(c.signal);
        if (c.callable == .named) self.gpa.free(c.callable.named.name);
        for (c.options.binds) |b| b.free(self.gpa);
        self.gpa.free(c.options.binds);
    }

    /// Connect `callable` to a signal of `source`: one a component declares,
    /// heard, or one kept as written, never heard. See `Signal.connect`,
    /// which is how a game does it, and `App.connectNamed`.
    pub fn connect(self: *Signals, source: Entity, key: Key, callable: Callable, options: Options) Error!void {
        if (callable == .zig and options.flags.persist) return error.NotPersistable;
        const known = key.component.len != 0;
        const entry = try self.from.getOrPut(self.gpa, source);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const list = entry.value_ptr;

        var replacing: ?*Connection = null;
        for (list.items) |*held| {
            if (!key.keeps(held.signal) or !held.callable.eql(callable)) continue;
            // One a scene made before the component was there is made
            // anew, in its place: it is heard from now on.
            if (known and !held.known) {
                replacing = held;
                break;
            }
            if (!held.options.flags.reference_counted) return error.AlreadyConnected;
            held.count += 1;
            return;
        }

        const signal = if (known)
            try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ key.component, key.name })
        else
            try self.gpa.dupe(u8, key.name);
        errdefer self.gpa.free(signal);
        var kept = callable;
        if (callable == .named) kept.named.name = try self.gpa.dupe(u8, callable.named.name);
        errdefer if (kept == .named) self.gpa.free(kept.named.name);
        const binds = try self.gpa.alloc(Bind, options.binds.len);
        var made: usize = 0;
        errdefer {
            for (binds[0..made]) |b| b.free(self.gpa);
            self.gpa.free(binds);
        }
        for (options.binds, binds) |b, *into| {
            into.* = try b.dupe(self.gpa);
            made += 1;
        }
        const connection: Connection = .{
            .source = source,
            .signal = signal,
            .callable = kept,
            .options = .{ .flags = options.flags, .unbinds = options.unbinds, .binds = binds },
            .count = 1,
            .known = known,
        };
        if (replacing) |held| {
            self.freeConnection(held.*);
            held.* = connection;
        } else try list.append(self.gpa, connection);
    }

    /// Every connection of `source` kept unknown under `written`, made a
    /// connection to the signal `key` names where it is: heard from now on,
    /// in the order it was made. For a signal that became known after its
    /// connections were read - a script's, once it compiles.
    pub fn know(self: *Signals, source: Entity, written: []const u8, key: Key) Allocator.Error!void {
        const list = self.from.getPtr(source) orelse return;
        for (list.items) |*held| {
            if (held.known or !std.mem.eql(u8, held.signal, written)) continue;
            const signal = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ key.component, key.name });
            self.gpa.free(held.signal);
            held.signal = signal;
            held.known = true;
        }
    }

    /// Take a connection away, or one count of it, and say whether there
    /// was one.
    pub fn disconnect(self: *Signals, source: Entity, key: Key, callable: Callable) bool {
        const list = self.from.getPtr(source) orelse return false;
        for (list.items, 0..) |*held, i| {
            if (!key.keeps(held.signal) or !held.callable.eql(callable)) continue;
            if (held.options.flags.reference_counted and held.count > 1) {
                held.count -= 1;
                return true;
            }
            self.freeConnection(held.*);
            _ = list.orderedRemove(i);
            return true;
        }
        return false;
    }

    pub fn isConnected(self: *const Signals, source: Entity, key: Key, callable: Callable) bool {
        const list = self.from.getPtr(source) orelse return false;
        for (list.items) |held| {
            if (key.keeps(held.signal) and held.callable.eql(callable)) return true;
        }
        return false;
    }

    /// The connections that hear one signal of `source`, as the table keeps
    /// them, as many as `found` holds.
    pub fn connectionsOf(self: *const Signals, source: Entity, component: []const u8, name: []const u8, found: []Connection) []Connection {
        const list = self.from.getPtr(source) orelse return found[0..0];
        var count: usize = 0;
        for (list.items) |held| {
            if (count == found.len) break;
            if (!held.known or !matches(held.signal, component, name)) continue;
            found[count] = held;
            count += 1;
        }
        return found[0..count];
    }

    /// Every connection to `target`'s methods, from anything. Godot's
    /// `get_incoming_connections`.
    pub fn connectionsTo(self: *const Signals, target: Entity, found: []Connection) []Connection {
        var count: usize = 0;
        for (self.from.values()) |list| {
            for (list.items) |held| {
                if (count == found.len) return found[0..count];
                if (held.callable != .named or !held.callable.named.target.eql(target)) continue;
                found[count] = held;
                count += 1;
            }
        }
        return found[0..count];
    }

    /// Every connection of `source`'s signals.
    pub fn connectionsFrom(self: *const Signals, source: Entity, found: []Connection) []Connection {
        const list = self.from.getPtr(source) orelse return found[0..0];
        const n = @min(found.len, list.items.len);
        @memcpy(found[0..n], list.items[0..n]);
        return found[0..n];
    }

    /// Queue the calls one emit makes: every connection of that signal of
    /// `source`, as it is now, with the arguments as they are now - so what
    /// is connected or changed after is not what this emit calls. A one-shot
    /// connection goes before anything is heard.
    pub fn emit(self: *Signals, source: Entity, component: []const u8, name: []const u8, args: []const reflect.Value) Error!void {
        if (!self.dispatch) return;
        const list = self.from.getPtr(source) orelse return;
        if (self.blocked.contains(source)) return;

        // Copied once, into what waits, whatever number of calls share them.
        var copied: ?[]reflect.Value = null;
        var at: usize = 0;
        while (at < list.items.len) {
            const held = &list.items[at];
            if (!held.known or !matches(held.signal, component, name)) {
                at += 1;
                continue;
            }
            const values = copied orelse try self.copyArgs(args);
            copied = values;
            const call: Call = .{
                .source = source,
                .callable = try self.keepCallable(held.callable),
                .component = try self.arena.allocator().dupe(u8, component),
                .signal = try self.arena.allocator().dupe(u8, name),
                .args = try self.handed(values, held.*, source),
            };
            if (held.options.flags.deferred) try self.deferred.append(self.gpa, call) else try self.queue.append(self.gpa, call);

            if (held.options.flags.one_shot) {
                if (held.options.flags.reference_counted and held.count > 1) {
                    held.count -= 1;
                } else {
                    self.freeConnection(held.*);
                    _ = list.orderedRemove(at);
                    continue;
                }
            }
            at += 1;
        }
    }

    /// The arguments, each copied into the arena - text too, so a buffer the
    /// emitter reuses is not what a deferred call reads.
    fn copyArgs(self: *Signals, args: []const reflect.Value) Allocator.Error![]reflect.Value {
        const arena = self.arena.allocator();
        const values = try arena.alloc(reflect.Value, args.len);
        for (args, values) |arg, *into| {
            const size = arg.type.size;
            // The alignment is the type's, known only now: `rawAlloc` takes
            // one at run time, as `alignedAlloc` does not.
            const alignment: std.mem.Alignment = .fromByteUnits(@max(arg.type.alignment, 1));
            const bytes = arena.rawAlloc(@max(size, 1), alignment, @returnAddress()) orelse return error.OutOfMemory;
            if (arg.is_bit_field) {
                // A packed field has no address to copy from: read it whole.
                const whole: reflect.Value = .init(arg.type, bytes);
                whole.copyFrom(arg) catch @memset(bytes[0..@max(size, 1)], 0);
            } else {
                @memcpy(bytes[0..size], @as([*]const u8, @ptrCast(arg.ptr))[0..size]);
            }
            into.* = .init(arg.type, bytes);
            if (arg.type.isString()) {
                const text: *[]const u8 = @ptrCast(@alignCast(bytes));
                text.* = try arena.dupe(u8, text.*);
            }
        }
        return values;
    }

    /// What one connection's method is handed: the emitted arguments less
    /// the unbound ones, the source when asked for, then the binds.
    fn handed(self: *Signals, values: []const reflect.Value, held: Connection, source: Entity) Allocator.Error![]const reflect.Value {
        const flags = held.options.flags;
        const kept = values.len -| held.options.unbinds;
        if (kept == values.len and !flags.append_source and held.options.binds.len == 0) return values;
        const arena = self.arena.allocator();
        const extra: usize = @intFromBool(flags.append_source) + held.options.binds.len;
        const out = try arena.alloc(reflect.Value, kept + extra);
        @memcpy(out[0..kept], values[0..kept]);
        var at = kept;
        if (flags.append_source) {
            const from = try arena.create(Entity);
            from.* = source;
            out[at] = .of(from);
            at += 1;
        }
        for (held.options.binds) |b| {
            const copy = try arena.create(Bind);
            copy.* = try b.dupe(arena);
            out[at] = copy.value();
            at += 1;
        }
        return out;
    }

    fn keepCallable(self: *Signals, callable: Callable) Allocator.Error!Callable {
        return switch (callable) {
            .named => |n| .method(n.target, try self.arena.allocator().dupe(u8, n.name)),
            .zig => callable,
        };
    }

    /// Make the calls waiting for this sync point, and the ones they make
    /// in turn. A call that fails is said and counted, and the rest are
    /// made: one broken handler does not silence the others.
    pub fn drain(self: *Signals, app: *App) Error!void {
        var made: usize = 0;
        var at: usize = 0;
        while (at < self.queue.items.len) : (at += 1) {
            made += 1;
            if (made > self.max_calls) {
                const runaway = self.queue.items[at];
                log.warn("signal {s}.{s} made more than {d} calls in one drain; the rest are dropped", .{ runaway.component, runaway.signal, self.max_calls });
                self.queue.clearRetainingCapacity();
                return error.TooManyCalls;
            }
            // By value: a call may append, and the list move.
            self.make(app, self.queue.items[at]);
        }
        self.queue.clearRetainingCapacity();
        self.letGo();
    }

    /// Make the deferred calls, at the end of the frame: first in, first
    /// out, with the ones they defer made in this same flush, and what
    /// each emits at once heard as it returns.
    pub fn flushDeferred(self: *Signals, app: *App) Error!void {
        var made: usize = 0;
        var at: usize = 0;
        while (at < self.deferred.items.len) : (at += 1) {
            made += 1;
            if (made > self.max_calls) {
                self.deferred.clearRetainingCapacity();
                return error.TooManyCalls;
            }
            self.make(app, self.deferred.items[at]);
            try self.drain(app);
        }
        self.deferred.clearRetainingCapacity();
        self.letGo();
    }

    /// The arena let go of once nothing waits on it.
    fn letGo(self: *Signals) void {
        if (self.queue.items.len == 0 and self.deferred.items.len == 0) _ = self.arena.reset(.retain_capacity);
    }

    fn make(self: *Signals, app: *App, call: Call) void {
        switch (call.callable) {
            .zig => |f| f.call(app, call.source, call.args) catch |err| self.failed(call, "a Zig function", err),
            .named => |n| {
                // A call to what has died since the emit is not made.
                if (!app.world.isAlive(n.target)) return;
                app.callMethodOn(n.target, n.name, call.args) catch |err| self.failed(call, n.name, err);
            },
        }
    }

    fn failed(self: *Signals, call: Call, method: []const u8, err: anyerror) void {
        self.failures += 1;
        log.warn("signal {s}.{s} of entity {d} could not call {s}: {t}", .{ call.component, call.signal, call.source.index, method, err });
    }

    /// Let go of the connections of and to whatever has died, and of their
    /// blocks. Once a frame, with the names.
    pub fn forgetDead(self: *Signals, world: *const ecs.World) void {
        var at = self.from.count();
        while (at > 0) {
            at -= 1;
            const source = self.from.keys()[at];
            const list = &self.from.values()[at];
            if (!world.isAlive(source)) {
                for (list.items) |c| self.freeConnection(c);
                list.deinit(self.gpa);
                self.from.swapRemoveAt(at);
                continue;
            }
            var kept: usize = 0;
            for (list.items) |c| {
                if (c.callable == .named and !world.isAlive(c.callable.named.target)) {
                    self.freeConnection(c);
                    continue;
                }
                list.items[kept] = c;
                kept += 1;
            }
            list.shrinkRetainingCapacity(kept);
        }
        var blocks = self.blocked.keyIterator();
        while (blocks.next()) |e| {
            if (!world.isAlive(e.*)) {
                _ = self.blocked.remove(e.*);
                // Removing invalidates the iterator: start again.
                blocks = self.blocked.keyIterator();
            }
        }
    }
};

test "a connection is kept under its component and its name, and found by both" {
    try testing.expect(matches("Health.hit", "Health", "hit"));
    try testing.expect(!matches("hit", "Health", "hit"));
    try testing.expect(!matches("Armour.hit", "Health", "hit"));
    try testing.expect(!matches("Health.hi", "Health", "hit"));
    try testing.expect(!matches("Healths.hit", "Health", "hit"));

    // As written, for what nothing declares: the text itself.
    const unknown: Key = .{ .name = "Inventory.dropped" };
    try testing.expect(unknown.keeps("Inventory.dropped"));
    try testing.expect(!unknown.keeps("dropped"));
}
