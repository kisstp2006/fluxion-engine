// SPDX-License-Identifier: BSD-1-Clause

//! The program a game is shipped as. The editor's export takes a copy of it
//! for each platform, named after the game, and puts the game's pack beside
//! it: see the engine's `pack_locator.zig`.
//!
//! It opens the pack it finds, and in it the project, as the game opened in
//! the editor: its boot splash, its autoloads, its main scene, its scripts
//! running. Its log goes to standard error, and to `logs/game.log` in the
//! player's folder for the game - where a player finds it to send, from a
//! program with no console.
//!
//! ```bash
//! game                        # Game.fxpack beside it
//! game --pack other.fxpack    # that pack instead
//! game --root my-game         # a project's folder, no pack: a quick look
//! game --frames 300 --capture shot.png
//! ```
//!
//! This file is under the BSD 1-Clause licence, and so is the program built
//! from it: a game shipped with it owes nobody a notice for it. The engine
//! and the libraries built into it are under their own - the export writes
//! theirs beside the game, in `LICENSES.txt`.

const std = @import("std");
const builtin = @import("builtin");

const fx = @import("fluxion_engine");
const App = fx.App;
const shipped = fx.shipped;

const log = std.log.scoped(.game);
const android = builtin.abi.isAndroid();

pub const std_options: std.Options = .{ .logFn = logFn };

const Flags = struct {
    app: App.Flags = .{},
    /// `--pack game.fxpack`: this pack, instead of the one the program
    /// looks for.
    pack: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    // A flag nobody knows - a launcher's own - leaves the game to start
    // with none, rather than not at all.
    const flags = App.parseFlags(Flags, arguments) catch |err| blk: {
        log.warn("the command line was passed over: {t}", .{err});
        break :blk Flags{};
    };
    // What went wrong is in the log already.
    run(init.gpa, init.io, flags) catch std.process.exit(1);
}

/// What the platform's activity runs, on a thread of its own: Android has
/// no `main`.
fn fluxionMain() callconv(.c) void {
    const gpa = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    run(gpa, threaded.io(), .{}) catch {};
}

comptime {
    if (android) @export(&fluxionMain, .{ .name = "fluxionMain" });
}

/// The game, until it ends. What goes wrong is logged.
fn run(gpa: std.mem.Allocator, io: std.Io, flags: Flags) !void {
    // A project's folder when one is named, and no pack is: a game looked at
    // without exporting it.
    const pack: ?fx.vfs.Pack = if (flags.app.root != null and flags.pack == null) null else pack: {
        break :pack shipped.openPack(gpa, io, flags.pack) catch |err| {
            switch (err) {
                error.NoGame => log.err("there is no game here: no pack beside this program", .{}),
                else => log.err("the game's pack did not open: {t}", .{err}),
            }
            return err;
        };
    };

    var options = flags.app.apply(.{});
    // Android has OpenGL ES and Vulkan, and the engine draws with Vulkan.
    if (android and flags.app.backend == null) options.backend = .vulkan;
    options.io = io;
    options.pack = pack;
    options.open_project = true;
    const app = App.create(gpa, options) catch |err| {
        log.err("the game did not start: {t}", .{err});
        return err;
    };
    defer app.destroy();
    journal.open(app);
    defer journal.close();

    // A label with no font of its own is drawn in the first font loaded.
    _ = app.assets.loadSystemFont(.{ .label = "default font" }) catch |err| log.warn("the system's font did not open: {t}", .{err});
    app.useScripts(.{}) catch |err| return failed(app, err);
    app.useControlNodes() catch |err| return failed(app, err);

    app.startup() catch |err| return failed(app, err);
    while (app.step() catch |err| return failed(app, err)) {}
    if (flags.app.capture) |path| {
        if (app.saveCapture(path)) |_| log.info("wrote {s}", .{path}) else |err| log.err("{s} was not written: {t}", .{ path, err });
    }
    app.stop() catch |err| return failed(app, err);
}

fn failed(app: *App, err: anyerror) anyerror {
    if (app.schedule.failed) |failure| log.err("{f}", .{failure}) else log.err("the game stopped: {t}", .{err});
    return err;
}

/// The log's copy in the player's folder, once the game knows where that
/// is. Written a line at a time, from any thread.
var journal: Journal = .{};

const Journal = struct {
    io: ?std.Io = null,
    file: ?std.Io.File = null,
    at: u64 = 0,
    lock: std.Io.Mutex = .init,

    const name = "logs/game.log";

    fn open(self: *Journal, app: *App) void {
        const io = app.io orelse return;
        const root = app.project.userRoot() catch return;
        var folder = std.Io.Dir.cwd().createDirPathOpen(io, root, .{}) catch return;
        defer folder.close(io);
        folder.createDirPath(io, std.fs.path.dirname(name).?) catch return;
        const file = folder.createFile(io, name, .{}) catch return;
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.io = io;
        self.file = file;
    }

    fn close(self: *Journal) void {
        const io = self.io orelse return;
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.file) |file| file.close(io);
        self.file = null;
    }

    fn write(self: *Journal, line: []const u8) void {
        const io = self.io orelse return;
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        const file = self.file orelse return;
        file.writePositionalAll(io, line, self.at) catch return;
        self.at += line.len;
    }
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buffer: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, level.asText() ++ prefix ++ format ++ "\n", args) catch cut: {
        @memcpy(buffer[buffer.len - 4 ..], "...\n");
        break :cut &buffer;
    };
    if (android) {
        buffer[@min(line.len, buffer.len - 1)] = 0;
        _ = logcat.write(switch (level) {
            .err => 6,
            .warn => 5,
            .info => 4,
            .debug => 3,
        }, "fluxion", @ptrCast(line.ptr));
    } else std.log.defaultLog(level, scope, format, args);
    journal.write(line);
}

/// Android's log, which `adb logcat` shows.
const logcat = struct {
    extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
    const write = __android_log_write;
};
