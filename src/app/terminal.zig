// SPDX-License-Identifier: BSD-3-Clause

//! A dedicated server's terminal: the lines typed into its standard input,
//! read on a thread of their own and taken by the game once a frame
//! (`App.terminalLines`), and the lines it writes back on standard output
//! (`App.printTerminal`).
//!
//! The thread is never joined: it waits on the terminal, and a program
//! ending does not wait for a line. It is started only where asked -
//! `fluxion-server` does - so a game's own program reads nothing it was not
//! meant to.

const std = @import("std");
const builtin = @import("builtin");

pub const Terminal = struct {
    gpa: std.mem.Allocator = undefined,
    io: ?std.Io = null,
    lock: std.Io.Mutex = .init,
    /// Typed and not yet taken.
    pending: std.ArrayList([]u8) = .empty,
    /// Taken last: the game's until the next take.
    taken: std.ArrayList([]u8) = .empty,
    /// Whether standard input is read.
    reading: bool = false,
    /// Let go of: what the thread reads after is dropped.
    closed: bool = false,
    /// The line being typed, the reading thread's alone.
    partial: std.ArrayList(u8) = .empty,

    /// Standard input read from now on, on a thread of its own. Nothing
    /// where there are no threads.
    pub fn start(self: *Terminal, gpa: std.mem.Allocator, io: std.Io) error{ OutOfMemory, SystemResources }!void {
        if (builtin.single_threaded or self.reading) return;
        self.gpa = gpa;
        self.io = io;
        const thread = std.Thread.spawn(.{}, read, .{self}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SystemResources,
        };
        thread.detach();
        self.reading = true;
    }

    fn read(self: *Terminal) void {
        const io = self.io.?;
        const input: std.Io.File = .stdin();
        var buffer: [1024]u8 = undefined;
        while (true) {
            const count = input.readStreaming(io, &.{&buffer}) catch break;
            for (buffer[0..count]) |c| switch (c) {
                '\n' => self.finishLine(),
                '\r' => {},
                else => self.partial.append(self.gpa, c) catch {},
            };
        }
        if (self.partial.items.len > 0) self.finishLine();
    }

    fn finishLine(self: *Terminal) void {
        defer self.partial.clearRetainingCapacity();
        const text = std.mem.trim(u8, self.partial.items, " \t");
        if (text.len == 0) return;
        const line = self.gpa.dupe(u8, text) catch return;
        self.lock.lockUncancelable(self.io.?);
        defer self.lock.unlock(self.io.?);
        if (self.closed) {
            self.gpa.free(line);
            return;
        }
        self.pending.append(self.gpa, line) catch self.gpa.free(line);
    }

    /// The lines typed since the last take, the oldest first: valid until
    /// the next.
    pub fn take(self: *Terminal) []const []const u8 {
        if (!self.reading) return &.{};
        for (self.taken.items) |line| self.gpa.free(line);
        self.taken.clearRetainingCapacity();
        self.lock.lockUncancelable(self.io.?);
        defer self.lock.unlock(self.io.?);
        std.mem.swap(std.ArrayList([]u8), &self.pending, &self.taken);
        return self.taken.items;
    }

    pub fn deinit(self: *Terminal) void {
        if (!self.reading) return;
        for (self.taken.items) |line| self.gpa.free(line);
        self.taken.deinit(self.gpa);
        self.lock.lockUncancelable(self.io.?);
        defer self.lock.unlock(self.io.?);
        for (self.pending.items) |line| self.gpa.free(line);
        self.pending.deinit(self.gpa);
        self.pending = .empty;
        self.closed = true;
    }
};

/// `text` and a line's end on standard output, as it is: no log's prefix.
pub fn print(io: std.Io, text: []const u8) void {
    const out: std.Io.File = .stdout();
    out.writeStreamingAll(io, text) catch return;
    out.writeStreamingAll(io, "\n") catch return;
}

test "a terminal not started gives no lines" {
    var terminal: Terminal = .{};
    try std.testing.expectEqual(@as(usize, 0), terminal.take().len);
    terminal.deinit();
}
