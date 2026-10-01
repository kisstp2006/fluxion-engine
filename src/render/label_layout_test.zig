// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");
const testing = std.testing;

const App = @import("../App.zig");
const label_layout = @import("label_layout.zig");
const Face = label_layout.Face;
const Faces = label_layout.Faces;
const Layout = label_layout.Layout;

/// An app with the system's font loaded, and the faces a label with no
/// font of its own is drawn in. Skipped where there is none.
fn systemFaces() !struct { app: *App, faces: Faces } {
    const app = try App.create(testing.allocator, .{ .headless = true, .io = testing.io });
    errdefer app.destroy();
    _ = app.assets.loadSystemFont(.{ .atlas = 256 }) catch return error.SkipZigTest;
    return .{ .app = app, .faces = Faces.of(&app.assets, .{}).? };
}

test "a label laid out with no wrap width is one line a newline, as wide as its widest" {
    const held = try systemFaces();
    defer held.app.destroy();
    var layout: Layout = .{};
    defer layout.deinit(testing.allocator);

    try layout.make(testing.allocator, held.faces, .{}, "Hello there");
    try testing.expectEqual(@as(usize, 10), layout.letters.items.len);
    const one_line = layout.height;
    const across = layout.width;
    try testing.expect(across > 0 and one_line > 0);
    for (layout.letters.items) |letter| try testing.expectEqual(layout.letters.items[0].baseline, letter.baseline);

    // A newline is another line as tall; the box is the wider of the two.
    try layout.make(testing.allocator, held.faces, .{}, "Hello there\nHi");
    try testing.expectApproxEqAbs(one_line * 2, layout.height, 0.001);
    try testing.expectApproxEqAbs(across, layout.width, 0.001);
    const last = layout.letters.items[layout.letters.items.len - 1];
    try testing.expect(last.baseline > layout.letters.items[0].baseline);
}

test "a wrap width breaks between words, and inside a word wider than a line" {
    const held = try systemFaces();
    defer held.app.destroy();
    var layout: Layout = .{};
    defer layout.deinit(testing.allocator);

    try layout.make(testing.allocator, held.faces, .{}, "Hello");
    const word = layout.width;
    try layout.make(testing.allocator, held.faces, .{}, "Hello Hello");
    const one_line = layout.height;

    // Room for one word: the second starts the next line at the left, and
    // the space between them counts to neither.
    try layout.make(testing.allocator, held.faces, .{ .wrap_width = word * 1.5 }, "Hello Hello");
    try testing.expectApproxEqAbs(one_line * 2, layout.height, 0.001);
    try testing.expectApproxEqAbs(word, layout.width, 0.001);
    const second = layout.letters.items[5];
    try testing.expectApproxEqAbs(layout.letters.items[0].x, second.x, 0.001);
    try testing.expect(second.baseline > layout.letters.items[4].baseline);

    // A word wider than a line breaks at a letter, and no line is wider than
    // the room unless a single letter is.
    try layout.make(testing.allocator, held.faces, .{ .wrap_width = word / 2 }, "Hello");
    try testing.expect(layout.height > one_line * 1.5);
    try testing.expect(layout.width <= word / 2);

    // Centred, each line is centred on the transform on its own.
    try layout.make(testing.allocator, held.faces, .{ .wrap_width = word * 1.5, .alignment = .center }, "Hello Hi");
    const hi = layout.letters.items[5];
    try testing.expectApproxEqAbs(-word / 2, layout.letters.items[0].x, 0.001);
    try testing.expect(hi.x > -word / 2);
    try testing.expectApproxEqAbs(-word / 2, layout.left, 0.001);
}

test "tags give letters a colour, a size, a shadow and a weight, and hide some while keeping their room" {
    const held = try systemFaces();
    defer held.app.destroy();
    var layout: Layout = .{};
    defer layout.deinit(testing.allocator);

    // Not read unless asked: the braces are words.
    try layout.make(testing.allocator, held.faces, .{}, "{b|A}");
    try testing.expectEqual(@as(usize, 5), layout.letters.items.len);

    try layout.make(testing.allocator, held.faces, .{ .markup = true }, "a{color=red|b}{size=40|C}{b|d}{shadow_color=black_offset=0.1,0.1|e}");
    const letters = layout.letters.items;
    try testing.expectEqual(@as(usize, 5), letters.len);
    try testing.expect(letters[0].color == null);
    try testing.expect(letters[1].color.?.r > 0.8 and letters[1].color.?.g < 0.1);
    try testing.expectEqual(@as(u16, 40), letters[2].size.pixels);
    try testing.expectEqual(@as(u16, 16), letters[3].size.pixels);
    // No bold font: the label's own, struck twice.
    try testing.expectEqual(Face.own, letters[3].face);
    try testing.expectApproxEqAbs(@as(f32, 1), letters[3].strike, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.6), letters[4].shadow.?.x, 0.001);
    // The big letter makes its line taller, and all share its baseline.
    const tall = letters[0].baseline;
    for (letters) |letter| try testing.expectEqual(tall, letter.baseline);
    try layout.make(testing.allocator, held.faces, .{}, "abd");
    try testing.expect(tall > layout.letters.items[0].baseline);

    // A bold font sets the heavy stretch, once.
    var bolder = held.faces;
    bolder.bold = held.faces.own;
    try layout.make(testing.allocator, bolder, .{ .markup = true }, "a{b|d}");
    try testing.expectEqual(Face.bold, layout.letters.items[1].face);
    try testing.expectEqual(@as(f32, 0), layout.letters.items[1].strike);

    // Hidden, a letter is not drawn and the next stays where it was.
    try layout.make(testing.allocator, held.faces, .{ .markup = true }, "abc");
    const c_at = layout.letters.items[2].x;
    try layout.make(testing.allocator, held.faces, .{ .markup = true }, "a{hide|b}c");
    try testing.expectEqual(@as(usize, 2), layout.letters.items.len);
    try testing.expectApproxEqAbs(c_at, layout.letters.items[1].x, 0.001);
}
