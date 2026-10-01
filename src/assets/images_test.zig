// SPDX-License-Identifier: BSD-3-Clause

//! Images through a whole app, headless.

const std = @import("std");
const testing = std.testing;

const Assets = @import("assets.zig");
const Image = @import("images.zig").Image;
const helpers = @import("../test_helpers.zig");
const Files = helpers.Files;

test "an image is saved and read, made a texture found by its name, changed, and read back from the GPU" {
    var files: Files = try .init();
    defer files.tmp.cleanup();
    const app = try files.app();
    defer app.destroy();
    app.project.user_root = try std.fs.path.join(testing.allocator, &.{ try files.at(), "saves" });
    const gpa = testing.allocator;

    var picture = try Image.init(gpa, 3, 2, .black);
    defer picture.deinit(gpa);
    _ = picture.setPixel(2, 1, .white);
    try app.saveImage(picture, "user://pictures/one.png", .{});
    try app.saveImage(picture, "user://pictures/one.jpg", .{ .quality = 95 });
    try testing.expectError(error.UnknownImageFormat, app.saveImage(picture, "user://pictures/one.bmp", .{}));
    var back = try app.readImage(gpa, "user://pictures/one.png");
    defer back.deinit(gpa);
    try testing.expectEqualSlices(u8, picture.pixels, back.pixels);
    var photo = try app.readImage(gpa, "user://pictures/one.jpg");
    defer photo.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), photo.width);

    // A texture of it, found by the name it was given, as a script names it.
    const texture = try app.newTexture(picture, .{});
    try testing.expectEqualStrings("image://1", app.assets.textureSource(texture).?);
    try testing.expect(app.assets.findTexture("image://1").?.eql(texture));
    try testing.expect((try app.loadAsset(Assets.TextureHandle, "image://1")).eql(texture));
    // Read back, it is its size: the headless device keeps no pixels, and
    // answers black ones.
    var read_back = try app.textureImage(gpa, texture);
    defer read_back.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), read_back.width);
    try testing.expectEqual(@as(u32, 2), read_back.height);

    // Changed to another size, it is still the one texture.
    var bigger = try picture.resized(gpa, 6, 4, false);
    defer bigger.deinit(gpa);
    try app.updateTexture(texture, bigger);
    try testing.expectEqual(@as(f32, 6), app.assets.sizeOf(texture).?.width);
    var changed = try app.textureImage(gpa, texture);
    defer changed.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), changed.height);

    _ = try app.step();
    var shot = try app.captureImage(gpa);
    defer shot.deinit(gpa);
    try testing.expectEqual(app.width, shot.width);
}
