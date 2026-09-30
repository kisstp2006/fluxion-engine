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
//! program keeps for it, found by the slot's marker: so a program is made
//! once, and each game's key goes into its own copy of it. The key is not
//! kept as it is but mixed with a mask, which keeps it from being the one
//! thing after a marker anybody can search for - and no more than that: the
//! key has to be in the program for the program to open its pack. The slot
//! also holds the public key a signed pack is checked against, all zero when
//! the game's pack is not signed.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const vfs = @import("fluxion_vfs");

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

/// Where a program keeps its pack's key: `export var` in the program, so the
/// export finds it by `magic` and writes the key in.
pub const Slot = extern struct {
    marker: [16]u8,
    /// The pack's key, mixed with `mask`; all zero for a pack that is not
    /// sealed.
    key: [32]u8,
    /// The key a signed pack is checked against; all zero when it is not.
    public: [32]u8,

    /// What a program's slot starts as.
    pub const empty: Slot = .{ .marker = magic, .key = @splat(0), .public = @splat(0) };

    /// What the slot is found by: in a program only once, in its slot.
    pub const magic = "fluxion:key-slot".*;

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

    /// Write `key` and `public` into the slot of the program in `program`.
    /// `error.NoSlot` for a program that has none, or more than one.
    pub fn write(program: []u8, key: ?vfs.Pack.Key, public: ?vfs.Pack.PublicKey) error{NoSlot}!void {
        const at = std.mem.indexOf(u8, program, &magic) orelse return error.NoSlot;
        if (std.mem.indexOfPos(u8, program, at + 1, &magic) != null) return error.NoSlot;
        if (at + @sizeOf(Slot) > program.len) return error.NoSlot;
        var slot: Slot = .empty;
        if (key) |k| for (&slot.key, k, mask) |*stored, byte, m| {
            stored.* = byte ^ m;
        };
        if (public) |p| slot.public = p;
        @memcpy(program[at..][0..@sizeOf(Slot)], std.mem.asBytes(&slot));
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a key written into a program's slot is the key the program reads" {
    var program: [300]u8 = @splat(0xAA);
    @memcpy(program[100..][0..@sizeOf(Slot)], std.mem.asBytes(&Slot.empty));

    const key: vfs.Pack.Key = @splat(0x42);
    const public: vfs.Pack.PublicKey = @splat(0x17);
    try Slot.write(&program, key, public);
    // Not there as it is.
    try testing.expect(std.mem.indexOf(u8, &program, &key) == null);

    const slot: *const Slot = @ptrCast(@alignCast(&program[100]));
    const read = Slot.keys(slot);
    try testing.expectEqualSlices(u8, &key, &read.key.?);
    try testing.expectEqualSlices(u8, &public, &read.public.?);

    try Slot.write(&program, null, null);
    try testing.expect(Slot.keys(slot).key == null);
    try testing.expect(Slot.keys(slot).public == null);

    var none: [64]u8 = @splat(0);
    try testing.expectError(error.NoSlot, Slot.write(&none, key, null));
    var twice: [200]u8 = @splat(0);
    @memcpy(twice[0..16], &Slot.magic);
    @memcpy(twice[100..116], &Slot.magic);
    try testing.expectError(error.NoSlot, Slot.write(&twice, key, null));
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
