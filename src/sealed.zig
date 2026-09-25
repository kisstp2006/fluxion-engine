// SPDX-License-Identifier: BSD-3-Clause
//! Text kept packed in a file: compressed, and - given a password - sealed,
//! so a player can neither read a save nor change it and have the game take
//! it. What `App.writeCompressed`, `App.writeSecret` and their readers, and
//! `files` in a script, write and read.
//!
//! **Compressed** is gzip: any tool opens it. **Sealed** is compressed, then
//! encrypted with AES-256-GCM under a key made from the password with
//! Argon2id, a new salt and nonce each time. GCM checks what it opens, so a
//! file changed by one bit, or opened with another password, is
//! `error.CannotOpen` - never a text the game would take as a save.
//!
//! A sealed file, byte by byte: `FLXS`, the version (1), Argon2's passes and
//! its memory in KiB (four bytes each, little-endian), the salt (16), the
//! nonce (12), what was encrypted, and GCM's tag (16). All before what was
//! encrypted is checked with it.
//!
//! A password in a game's code is found by whoever looks for it: this keeps
//! a save from being read or changed by hand, not from a determined player.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;
const argon2 = std.crypto.pwhash.argon2;
const Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const testing = std.testing;

/// How hard a password is made to guess: Argon2id's passes, and the memory
/// each guess takes. Written in the file, so it is read as it was sealed.
pub const Cost = struct {
    passes: u32,
    memory_kib: u32,

    /// What OWASP recommends: 19 MiB and two passes, about a tenth of a
    /// second on a phone.
    pub const default: Cost = .{ .passes = 2, .memory_kib = 19 * 1024 };
    /// Next to nothing, for tests that seal many times.
    pub const cheapest: Cost = .{ .passes = 1, .memory_kib = 8 };
    /// More than this in a file is refused: somebody made it to stall the
    /// game that opens it.
    pub const most_memory_kib = 1024 * 1024;
};

pub const magic = "FLXS";
const version = 1;
const salt_length = 16;
const header_length = magic.len + 1 + 4 + 4 + salt_length + Gcm.nonce_length;

pub const OpenError = error{
    /// Not a sealed file, or one this build cannot read.
    NotSealed,
    /// Another password, or a file changed since it was sealed.
    CannotOpen,
} || DecompressError;

pub const DecompressError = error{
    /// Not gzip.
    NotCompressed,
    /// Gzip that does not read: cut short, or changed.
    BadCompressed,
    /// Opens to more than `limit`.
    TooLarge,
} || Allocator.Error;

/// `text` as gzip.
pub fn compress(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, text.len / 2 + 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    // A quarter of a megabyte of tables: not for the stack.
    const packer = try gpa.create(flate.Compress);
    defer gpa.destroy(packer);
    packer.* = flate.Compress.init(&out.writer, window, .gzip, .default) catch return error.OutOfMemory;
    packer.writer.writeAll(text) catch return error.OutOfMemory;
    packer.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What gzip `bytes` hold, up to `limit` bytes of it.
pub fn decompress(gpa: Allocator, bytes: []const u8, limit: usize) DecompressError![]u8 {
    if (!isCompressed(bytes)) return error.NotCompressed;
    var input: Io.Reader = .fixed(bytes);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var unpacker: flate.Decompress = .init(&input, .gzip, window);
    return unpacker.reader.allocRemaining(gpa, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.BadCompressed,
    };
}

/// Whether `bytes` start as gzip does.
pub fn isCompressed(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, &.{ 0x1f, 0x8b });
}

/// Whether `bytes` start as a sealed file does.
pub fn isSealed(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

/// `text` compressed and sealed with `password`. `io` gives the salt and the
/// nonce, and the threads Argon2 may use.
pub fn seal(gpa: Allocator, io: Io, text: []const u8, password: []const u8, cost: Cost) (Allocator.Error || error{WeakPassword})![]u8 {
    const packed_text = try compress(gpa, text);
    defer gpa.free(packed_text);

    const out = try gpa.alloc(u8, header_length + packed_text.len + Gcm.tag_length);
    errdefer gpa.free(out);
    var header = out[0..header_length];
    @memcpy(header[0..magic.len], magic);
    header[magic.len] = version;
    std.mem.writeInt(u32, header[magic.len + 1 ..][0..4], cost.passes, .little);
    std.mem.writeInt(u32, header[magic.len + 5 ..][0..4], cost.memory_kib, .little);
    const salt = header[magic.len + 9 ..][0..salt_length];
    const nonce = header[magic.len + 9 + salt_length ..][0..Gcm.nonce_length];
    io.random(salt);
    io.random(nonce);

    const key = try keyOf(gpa, io, password, salt, cost);
    const body = out[header_length..][0..packed_text.len];
    const tag = out[header_length + packed_text.len ..][0..Gcm.tag_length];
    Gcm.encrypt(body, tag, packed_text, header, nonce.*, key);
    return out;
}

/// The text `bytes` were sealed from with `password`, up to `limit` bytes.
pub fn open(gpa: Allocator, io: Io, bytes: []const u8, password: []const u8, limit: usize) (OpenError || error{WeakPassword})![]u8 {
    if (!isSealed(bytes) or bytes.len < header_length + Gcm.tag_length) return error.NotSealed;
    const header = bytes[0..header_length];
    if (header[magic.len] != version) return error.NotSealed;
    const cost: Cost = .{
        .passes = std.mem.readInt(u32, header[magic.len + 1 ..][0..4], .little),
        .memory_kib = std.mem.readInt(u32, header[magic.len + 5 ..][0..4], .little),
    };
    if (cost.passes == 0 or cost.passes > 64 or cost.memory_kib < 8 or cost.memory_kib > Cost.most_memory_kib) return error.CannotOpen;
    const salt = header[magic.len + 9 ..][0..salt_length];
    const nonce = header[magic.len + 9 + salt_length ..][0..Gcm.nonce_length];

    const key = try keyOf(gpa, io, password, salt, cost);
    const body = bytes[header_length .. bytes.len - Gcm.tag_length];
    const tag = bytes[bytes.len - Gcm.tag_length ..][0..Gcm.tag_length];
    const packed_text = try gpa.alloc(u8, body.len);
    defer gpa.free(packed_text);
    Gcm.decrypt(packed_text, body, tag.*, header, nonce.*, key) catch return error.CannotOpen;
    return decompress(gpa, packed_text, limit) catch |err| switch (err) {
        // Checked by GCM, so it is what was sealed: a text too big.
        error.NotCompressed, error.BadCompressed => error.CannotOpen,
        else => |e| e,
    };
}

fn keyOf(gpa: Allocator, io: Io, password: []const u8, salt: *const [salt_length]u8, cost: Cost) (Allocator.Error || error{WeakPassword})![Gcm.key_length]u8 {
    var key: [Gcm.key_length]u8 = undefined;
    argon2.kdf(gpa, &key, password, salt, .{ .t = cost.passes, .m = cost.memory_kib, .p = 1 }, .argon2id, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WeakPassword,
    };
    return key;
}

test "compressed text comes back as it was, and is smaller" {
    const text = "the same line again\n" ** 200;
    const small = try compress(testing.allocator, text);
    defer testing.allocator.free(small);
    try testing.expect(small.len < text.len / 10);
    try testing.expect(isCompressed(small));

    const back = try decompress(testing.allocator, small, 1 << 20);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(text, back);

    try testing.expectError(error.TooLarge, decompress(testing.allocator, small, 100));
    try testing.expectError(error.NotCompressed, decompress(testing.allocator, "plain", 100));
    try testing.expectError(error.BadCompressed, decompress(testing.allocator, small[0 .. small.len / 2], 1 << 20));
}

test "a sealed text opens with its password, and with nothing else" {
    const io = testing.io;
    const text = "{\"gold\": 120, \"level\": 3}";
    const sealed = try seal(testing.allocator, io, text, "blue door", .cheapest);
    defer testing.allocator.free(sealed);
    try testing.expect(isSealed(sealed));
    try testing.expect(std.mem.indexOf(u8, sealed, "gold") == null);

    const back = try open(testing.allocator, io, sealed, "blue door", 1 << 20);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(text, back);

    try testing.expectError(error.CannotOpen, open(testing.allocator, io, sealed, "red door", 1 << 20));

    // One bit changed anywhere - in what was sealed, or in the header - and
    // it does not open.
    for ([_]usize{ 6, sealed.len - 20, sealed.len - 1 }) |at| {
        const changed = try testing.allocator.dupe(u8, sealed);
        defer testing.allocator.free(changed);
        changed[at] ^= 1;
        try testing.expectError(error.CannotOpen, open(testing.allocator, io, changed, "blue door", 1 << 20));
    }
    try testing.expectError(error.NotSealed, open(testing.allocator, io, text, "blue door", 1 << 20));

    // Sealed twice, it is written twice differently: a new salt and nonce.
    const again = try seal(testing.allocator, io, text, "blue door", .cheapest);
    defer testing.allocator.free(again);
    try testing.expect(!std.mem.eql(u8, sealed, again));
}
