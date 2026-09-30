// SPDX-License-Identifier: BSD-3-Clause

//! What a shipped game is made of, beside its files: where the program finds
//! its pack, and where the pack's key is kept in the program.
//!
//! **The pack is beside the program or inside it.** Beside it, it is the
//! program's name with `.fxpack` for its ending: `Game.fxpack` by `Game.exe`.
//! Inside it, it is written onto the program's end and followed by a
//! `Trailer` that says where it starts - which an operating system loading
//! the program never looks at. A Windows program signed afterwards has its
//! signature after that, where the PE header says it is, and the trailer is
//! looked for before it. On Android the pack is the APK's
//! `assets/game.fxpack`, stored as it is: `platform.bundle` opens it.
//!
//! **The key is written into the program** by the export, in the `Slot` the
//! program keeps for it, found by its magic in the program's writable data:
//! so a program is made once, and each game's key goes into its own copy of
//! it. The key is not
//! kept as it is but mixed with a mask, which keeps it from being the one
//! thing after a marker anybody can search for - and no more than that: the
//! key has to be in the program for the program to open its pack. The slot
//! also holds the public key a signed pack is checked against, all zero when
//! the game's pack is not signed.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const vfs = @import("fluxion_vfs");
const platform = @import("fluxion_platform");

/// What a pack beside a program ends in.
pub const pack_extension = ".fxpack";

/// What the pack is called inside an APK's `assets/`.
pub const android_pack = "game.fxpack";

/// Where a pack written onto a program is: the last bytes of the program, or
/// of what comes before its signature.
pub const Trailer = struct {
    start: u64,
    len: u64,

    pub const magic = "FXPKTAIL";
    pub const size = 8 + 8 + magic.len;

    pub fn bytes(t: Trailer) [size]u8 {
        var out: [size]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], t.start, .little);
        std.mem.writeInt(u64, out[8..16], t.len, .little);
        out[16..].* = magic.*;
        return out;
    }

    /// The trailer in `raw`, or null when it is none.
    pub fn read(raw: *const [size]u8) ?Trailer {
        if (!std.mem.eql(u8, raw[16..], magic)) return null;
        return .{ .start = std.mem.readInt(u64, raw[0..8], .little), .len = std.mem.readInt(u64, raw[8..16], .little) };
    }
};

/// A pack that is part of a file: from `start`, `len` bytes.
pub const Region = struct { start: u64, len: u64 };

pub const OpenError = vfs.Pack.Error || error{ OutOfMemory, NoGame };

/// The pack of the program running: the one `path` names, else the one
/// written onto the program, else the one beside it; on Android the APK's
/// `assets/game.fxpack`. `error.NoGame` when there is none.
pub fn openPack(gpa: std.mem.Allocator, io: Io, path: ?[]const u8, options: vfs.Pack.Options) OpenError!vfs.Pack {
    if (path) |named| return vfs.Pack.openFile(gpa, io, named, options);
    if (comptime @import("builtin").abi.isAndroid()) {
        const bundled = platform.bundle.open(android_pack) catch return error.NoGame;
        return owningRegion(gpa, io, bundled.file, .{ .start = bundled.start, .len = bundled.len }, options);
    }

    const program = std.process.executablePathAlloc(io, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoGame,
    };
    defer gpa.free(program);
    if (Io.Dir.cwd().openFile(io, program, .{})) |file| {
        const inside = inside: {
            const size = (file.stat(io) catch break :inside null).size;
            break :inside embedded(io, file, size) catch null;
        };
        if (inside) |region| return owningRegion(gpa, io, file, region, options);
        file.close(io);
    } else |_| {}

    const stem = std.fs.path.stem(program);
    const beside = try std.mem.concat(gpa, u8, &.{ program[0 .. program.len - std.fs.path.basename(program).len], stem, pack_extension });
    defer gpa.free(beside);
    return vfs.Pack.openFile(gpa, io, beside, options) catch |err| switch (err) {
        error.FileNotFound => error.NoGame,
        else => err,
    };
}

/// The pack in `region` of `file`, which the pack closes.
fn owningRegion(gpa: std.mem.Allocator, io: Io, file: Io.File, region: Region, options: vfs.Pack.Options) OpenError!vfs.Pack {
    errdefer file.close(io);
    var pack = try vfs.Pack.fromFileRegion(gpa, io, file, region.start, region.len, options);
    pack.storage.file.owned = true;
    return pack;
}

/// The pack written onto the program `file` - `len` bytes long - or null
/// when none is.
pub fn embedded(io: Io, file: Io.File, len: u64) !?Region {
    var end = len;
    // A signed Windows program: the pack is before the signature.
    var head: [1024]u8 = undefined;
    const head_len = try file.readPositionalAll(io, head[0..@min(head.len, len)], 0);
    if (certificateStart(head[0..head_len])) |cert| {
        if (cert.start < len and cert.start + cert.len == len) end = cert.start;
    }
    if (end < Trailer.size) return null;
    var raw: [Trailer.size]u8 = undefined;
    if (try file.readPositionalAll(io, &raw, end - Trailer.size) != raw.len) return null;
    const trailer = Trailer.read(&raw) orelse return null;
    if (trailer.start > end - Trailer.size or trailer.len > end - Trailer.size - trailer.start) return null;
    return .{ .start = trailer.start, .len = trailer.len };
}

/// Where a Windows program's signature is, from the start of its file:
/// what the PE header's security directory says. Null for a file that is no
/// PE program, or one that is not signed.
pub fn certificateStart(head: []const u8) ?Region {
    if (head.len < 0x40 or !std.mem.eql(u8, head[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, head[0x3C..][0..4], .little);
    // The signature, the COFF header, and the optional header's magic.
    if (pe > head.len - 24 or !std.mem.eql(u8, head[pe..][0..4], "PE\x00\x00")) return null;
    const optional = pe + 4 + 20;
    const directories: usize = switch (std.mem.readInt(u16, head[optional..][0..2], .little)) {
        0x10b => optional + 96, // PE32
        0x20b => optional + 112, // PE32+
        else => return null,
    };
    // The fifth directory is the security one.
    const security = directories + 4 * 8;
    if (security + 8 > head.len) return null;
    const start = std.mem.readInt(u32, head[security..][0..4], .little);
    const size = std.mem.readInt(u32, head[security + 4 ..][0..4], .little);
    if (start == 0 or size == 0) return null;
    return .{ .start = start, .len = size };
}

/// Where a program keeps its pack's key: an `export var` of the program, so
/// the export finds it by `magic` and writes the key in. Only a copy in a
/// section the program writes is the slot: a debug build has the first value
/// among its debug information too, and constants a debug build keeps.
pub const Slot = extern struct {
    marker: [16]u8,
    /// The pack's key, mixed with `mask`; all zero for a pack that is not
    /// sealed.
    key: [32]u8,
    /// The key a signed pack is checked against; all zero when it is not.
    public: [32]u8,

    /// What a program's slot starts as: `export var slot: Slot =
    /// .unwritten();`. A function and not a constant, and the magic written
    /// out in it: a debug build keeps a copy of each constant it names, and
    /// every copy of the magic is one more place that looks like the slot.
    pub fn unwritten() Slot {
        return .{ .marker = "fluxion:key-slot".*, .key = @splat(0), .public = @splat(0) };
    }

    /// What the slot is found by.
    pub const magic = unwritten().marker;

    /// What the key is mixed with.
    pub const mask: [32]u8 = blk: {
        @setEvalBranchQuota(10_000);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("fluxion: the mask of a pack's key", &digest, .{});
        break :blk digest;
    };

    /// The pack's key and the public key, as the program has them. A program
    /// reads its own through a volatile pointer: the export writes it after
    /// the program was built, which the compiler cannot know.
    pub fn keys(slot: *const volatile Slot) struct { key: ?vfs.Pack.Key, public: ?vfs.Pack.PublicKey } {
        const held: Slot = slot.*;
        var key: vfs.Pack.Key = undefined;
        for (&key, held.key, mask) |*k, stored, m| k.* = stored ^ m;
        const none = std.mem.allEqual(u8, &held.key, 0);
        const unsigned = std.mem.allEqual(u8, &held.public, 0);
        return .{ .key = if (none) null else key, .public = if (unsigned) null else held.public };
    }

    /// Write `key` and `public` into the slot of the program in `program`, a
    /// PE or an ELF file. `error.NoSlot` for a program that has none, or more
    /// than one.
    pub fn write(program: []u8, key: ?vfs.Pack.Key, public: ?vfs.Pack.PublicKey) error{NoSlot}!void {
        var found: ?usize = null;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, program, from, &magic)) |at| : (from = at + 1) {
            if (!writable(program, at, @sizeOf(Slot))) continue;
            if (found != null) return error.NoSlot;
            found = at;
        }
        const at = found orelse return error.NoSlot;
        var slot: Slot = .unwritten();
        if (key) |k| for (&slot.key, k, mask) |*stored, byte, m| {
            stored.* = byte ^ m;
        };
        if (public) |p| slot.public = p;
        @memcpy(program[at..][0..@sizeOf(Slot)], std.mem.asBytes(&slot));
    }
};

/// Whether the `len` bytes of `program` from `at` are in a section the
/// program writes, of a PE or an ELF file.
fn writable(program: []const u8, at: usize, len: usize) bool {
    if (std.mem.startsWith(u8, program, "\x7fELF")) return writableElf(program, at, len);
    if (std.mem.startsWith(u8, program, "MZ")) return writablePe(program, at, len);
    return false;
}

fn writablePe(program: []const u8, at: usize, len: usize) bool {
    if (program.len < 0x40) return false;
    const pe = std.mem.readInt(u32, program[0x3C..][0..4], .little);
    if (pe > program.len - 24 or !std.mem.eql(u8, program[pe..][0..4], "PE\x00\x00")) return false;
    const sections = std.mem.readInt(u16, program[pe + 6 ..][0..2], .little);
    var row = pe + 24 + std.mem.readInt(u16, program[pe + 20 ..][0..2], .little);
    for (0..sections) |_| {
        if (row + 40 > program.len) return false;
        const size = std.mem.readInt(u32, program[row + 16 ..][0..4], .little);
        const start = std.mem.readInt(u32, program[row + 20 ..][0..4], .little);
        const flags = std.mem.readInt(u32, program[row + 36 ..][0..4], .little);
        const memory_write = 0x80000000;
        if (flags & memory_write != 0 and at >= start and at + len <= @as(u64, start) + size) return true;
        row += 40;
    }
    return false;
}

fn writableElf(program: []const u8, at: usize, len: usize) bool {
    if (program.len < 0x40 or program[5] != 1) return false;
    const wide = program[4] == 2;
    const word = struct {
        fn read(bytes: []const u8, offset: usize, is_wide: bool) u64 {
            return if (is_wide) std.mem.readInt(u64, bytes[offset..][0..8], .little) else std.mem.readInt(u32, bytes[offset..][0..4], .little);
        }
    }.read;
    const table = word(program, if (wide) 0x28 else 0x20, wide);
    const row_size = std.mem.readInt(u16, program[if (wide) 0x3A else 0x2E..][0..2], .little);
    const rows = std.mem.readInt(u16, program[if (wide) 0x3C else 0x30..][0..2], .little);
    if (row_size < @as(u16, if (wide) 40 else 24)) return false;
    for (0..rows) |i| {
        const row = table + @as(u64, i) * row_size;
        if (row + row_size > program.len) return false;
        const r: usize = @intCast(row);
        const kind = std.mem.readInt(u32, program[r + 4 ..][0..4], .little);
        const flags = word(program, r + 8, wide);
        const start = word(program, r + if (wide) @as(usize, 24) else 16, wide);
        const size = word(program, r + if (wide) @as(usize, 32) else 20, wide);
        const progbits = 1;
        const write_flag = 1;
        if (kind == progbits and flags & write_flag != 0 and at >= start and at + len <= start +| size) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A little ELF file: a section of constants with a copy of the slot's first
/// value in it, as a debug build has, and a writable one with the slot.
fn testElf(buffer: *[0x400]u8) usize {
    @memset(buffer, 0);
    @memcpy(buffer[0..4], "\x7fELF");
    buffer[4] = 2;
    buffer[5] = 1;
    const table = 0x300;
    std.mem.writeInt(u64, buffer[0x28..][0..8], table, .little);
    std.mem.writeInt(u16, buffer[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, buffer[0x3C..][0..2], 3, .little);
    const Row = struct { flags: u64, start: u64, size: u64 };
    for ([_]Row{ .{ .flags = 0, .start = 0x100, .size = 0x80 }, .{ .flags = 3, .start = 0x200, .size = 0x100 } }, 1..) |row, i| {
        const at = table + i * 64;
        std.mem.writeInt(u32, buffer[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u64, buffer[at + 8 ..][0..8], row.flags, .little);
        std.mem.writeInt(u64, buffer[at + 24 ..][0..8], row.start, .little);
        std.mem.writeInt(u64, buffer[at + 32 ..][0..8], row.size, .little);
    }
    @memcpy(buffer[0x100..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.unwritten()));
    @memcpy(buffer[0x210..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.unwritten()));
    return 0x210;
}

test "a key written into a program's slot is the key the program reads" {
    var program: [0x400]u8 = undefined;
    const at = testElf(&program);

    const key: vfs.Pack.Key = @splat(0x42);
    const public: vfs.Pack.PublicKey = @splat(0x17);
    try Slot.write(&program, key, public);
    // Not there as it is.
    try testing.expect(std.mem.indexOf(u8, &program, &key) == null);
    // The copy among the constants is left alone.
    try testing.expectEqualSlices(u8, std.mem.asBytes(&Slot.unwritten()), program[0x100..][0..@sizeOf(Slot)]);

    const slot: *const Slot = @ptrCast(@alignCast(&program[at]));
    const read = Slot.keys(slot);
    try testing.expectEqualSlices(u8, &key, &read.key.?);
    try testing.expectEqualSlices(u8, &public, &read.public.?);

    try Slot.write(&program, null, null);
    try testing.expect(Slot.keys(slot).key == null);
    try testing.expect(Slot.keys(slot).public == null);

    // Two slots in writable data are one too many; none is none.
    @memcpy(program[0x260..][0..16], &Slot.magic);
    try testing.expectError(error.NoSlot, Slot.write(&program, key, null));
    var plain: [0x400]u8 = @splat(0);
    @memcpy(plain[0x100..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.unwritten()));
    try testing.expectError(error.NoSlot, Slot.write(&plain, key, null));
}

test "the slot of a PE program is the one in its writable section" {
    var program: [0x400]u8 = @splat(0);
    program[0] = 'M';
    program[1] = 'Z';
    const pe = 0x80;
    std.mem.writeInt(u32, program[0x3C..][0..4], pe, .little);
    @memcpy(program[pe..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, program[pe + 6 ..][0..2], 2, .little);
    std.mem.writeInt(u16, program[pe + 20 ..][0..2], 0xF0, .little);
    const Row = struct { flags: u32, start: u32 };
    for ([_]Row{ .{ .flags = 0x40000040, .start = 0x200 }, .{ .flags = 0xC0000040, .start = 0x300 } }, 0..) |row, i| {
        const at = pe + 24 + 0xF0 + i * 40;
        std.mem.writeInt(u32, program[at + 16 ..][0..4], 0x100, .little);
        std.mem.writeInt(u32, program[at + 20 ..][0..4], row.start, .little);
        std.mem.writeInt(u32, program[at + 36 ..][0..4], row.flags, .little);
    }
    @memcpy(program[0x220..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.unwritten()));
    @memcpy(program[0x340..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.unwritten()));

    const key: vfs.Pack.Key = @splat(0x9);
    try Slot.write(&program, key, null);
    const slot: *const Slot = @ptrCast(@alignCast(&program[0x340]));
    try testing.expectEqualSlices(u8, &key, &Slot.keys(slot).key.?);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&Slot.unwritten()), program[0x220..][0..@sizeOf(Slot)]);
}

test "a pack written onto a program is found by its trailer, before a signature too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // A PE program's first bytes: "MZ", where the header is, "PE", and a
    // PE32+ optional header whose security directory says a signature
    // follows the pack.
    var program: [512]u8 = @splat(0);
    program[0] = 'M';
    program[1] = 'Z';
    std.mem.writeInt(u32, program[0x3C..][0..4], 0x80, .little);
    @memcpy(program[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, program[0x80 + 24 ..][0..2], 0x20b, .little);

    const pack = "the pack's own bytes";
    const trailer = (Trailer{ .start = program.len, .len = pack.len }).bytes();
    const signature = "a signature, after everything";
    const cert_start = program.len + pack.len + trailer.len;
    const security = 0x80 + 24 + 112 + 4 * 8;
    std.mem.writeInt(u32, program[security..][0..4], cert_start, .little);
    std.mem.writeInt(u32, program[security + 4 ..][0..4], signature.len, .little);

    const whole = try std.mem.concat(testing.allocator, u8, &.{ &program, pack, &trailer, signature });
    defer testing.allocator.free(whole);
    try tmp.dir.writeFile(io, .{ .sub_path = "Game.exe", .data = whole });
    const file = try tmp.dir.openFile(io, "Game.exe", .{});
    defer file.close(io);
    const found = (try embedded(io, file, whole.len)).?;
    try testing.expectEqual(@as(u64, program.len), found.start);
    try testing.expectEqual(@as(u64, pack.len), found.len);

    // A program with nothing written onto it has no pack in it.
    try tmp.dir.writeFile(io, .{ .sub_path = "Plain.exe", .data = &program });
    const plain = try tmp.dir.openFile(io, "Plain.exe", .{});
    defer plain.close(io);
    try testing.expect(try embedded(io, plain, program.len) == null);
}
