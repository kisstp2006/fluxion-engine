// SPDX-License-Identifier: BSD-3-Clause

//! Words kept in a buffer of a fixed size, ending at its first nought: the
//! names a component holds in itself - an animation's, a bus's, an
//! action's - so that it keeps nothing beside it. A scene writes one as the
//! text it is, and a script reads it so.

const std = @import("std");
const testing = std.testing;

/// The words in `buffer`: up to its first nought, or all of it.
pub fn get(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

/// `text` put in `buffer`, the rest of it noughts. What does not fit is cut
/// where a character starts, so what is kept is whole characters.
pub fn set(buffer: []u8, text: []const u8) void {
    var cut = @min(text.len, buffer.len);
    while (cut > 0 and cut < text.len and text[cut] & 0xC0 == 0x80) cut -= 1;
    @memcpy(buffer[0..cut], text[0..cut]);
    @memset(buffer[cut..], 0);
}

/// `text` in a buffer of `len`: a default value, or a name written in code.
pub fn of(comptime len: usize, comptime text: []const u8) [len]u8 {
    comptime std.debug.assert(text.len <= len);
    var out: [len]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

test "words are kept to the first nought, and what does not fit is cut between characters" {
    var buffer: [6]u8 = of(6, "Master");
    try testing.expectEqualStrings("Master", get(&buffer));
    set(&buffer, "Music");
    try testing.expectEqualStrings("Music", get(&buffer));
    set(&buffer, "");
    try testing.expectEqualStrings("", get(&buffer));
    // "Zenéé" is seven bytes; six would end in half an é.
    set(&buffer, "Zenéé");
    try testing.expectEqualStrings("Zené", get(&buffer));
}
