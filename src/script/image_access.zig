// SPDX-License-Identifier: BSD-3-Clause

//! What a script reaches as `images`, and an image it holds: pixels to read
//! and change, read from a file, captured from the frame or a texture, and
//! made a texture to draw.

const std = @import("std");
const Allocator = std.mem.Allocator;

const flux = @import("fluxion_script");
const App = @import("../App.zig");
const attr = @import("../reflect/attr.zig");
const Assets = @import("../assets/assets.zig");
const Color = @import("../math/color.zig").Color;
const Image = @import("../assets/images.zig").Image;

const FileAccess = @import("file_access.zig").FileAccess;
const mayRead = @import("file_access.zig").mayRead;

/// What a script reaches as `images`: pictures in memory, made, read from a
/// file, or caught from the screen, to change a pixel at a time, save, and
/// draw as a texture. An image is an `Image`: see `ImageRef`.
///
/// ```
/// const shot = images.capture();                     // the frame as it is
/// shot.resize(320, 180);
/// shot.saveJpg("user://saves/one.jpg", 0.85);        // a save's thumbnail
/// const map = images.new(64, 64, color(0, 0, 0, 1));
/// map.setPixel(10, 12, color(1, 1, 1));
/// sprite.texture = images.toTexture(map);            // "image://1"
/// ```
pub const ImagesAccess = struct {
    app: *App,

    pub const reflect_name = "Images";
    pub const reflect_opaque = true;
    pub const reflect_methods = .{
        .new = .{ attr.Params{ .names = &.{ "vm", "width", "height", "color" } }, attr.defaults(.{Color.transparent}), flux.Returns.of(ImageRef) },
        .read = .{ attr.Params{ .names = &.{ "vm", "path" } }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .capture = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .fromTexture = .{ attr.Params{ .names = &.{ "vm", "texture" } }, flux.Returns.of(ImageRef), flux.GivesErrors{} },
        .toTexture = .{ attr.Params{ .names = &.{ "vm", "image" } }, flux.Takes.of("image", ImageRef), flux.GivesErrors{} },
        .updateTexture = .{ attr.Params{ .names = &.{ "vm", "texture", "image" } }, flux.Takes.of("image", ImageRef), flux.GivesErrors{} },
    };

    /// One `width` by `height`, every pixel `color`: see-through when none
    /// is given.
    pub fn new(self: *ImagesAccess, vm: *flux.Vm, width: i64, height: i64, color: Color) anyerror!flux.Value {
        const made = try Image.init(vm.gpa, try side(width), try side(height), color);
        return imageValue(vm, self.app, made);
    }

    /// A picture's file, a PNG or a JPEG: the game's (`res://`) or the
    /// player's (`user://`).
    pub fn read(self: *ImagesAccess, vm: *flux.Vm, path: []const u8) anyerror!flux.Value {
        try mayRead(self.app, path);
        return imageValue(vm, self.app, try self.app.readImage(vm.gpa, path));
    }

    /// The frame drawn again, the window's size.
    pub fn capture(self: *ImagesAccess, vm: *flux.Vm) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.app.captureImage(vm.gpa));
    }

    /// What a texture holds, read back from the GPU.
    pub fn fromTexture(self: *ImagesAccess, vm: *flux.Vm, texture: Assets.TextureHandle) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.app.textureImage(vm.gpa, texture));
    }

    /// The image as a texture to draw, called `image://1`, `image://2`...:
    /// what a sprite's `texture` is given.
    pub fn toTexture(self: *ImagesAccess, vm: *flux.Vm, picture: flux.Value) anyerror!Assets.TextureHandle {
        return self.app.newTexture((try imageOf(vm, picture)).held, .{});
    }

    /// A texture given an image's pixels, the same size or another.
    pub fn updateTexture(self: *ImagesAccess, vm: *flux.Vm, texture: Assets.TextureHandle, picture: flux.Value) anyerror!void {
        try self.app.updateTexture(texture, (try imageOf(vm, picture)).held);
    }
};

fn side(n: i64) error{BadSize}!u32 {
    if (n <= 0 or n > Image.max_side) return error.BadSize;
    return @intCast(n);
}

/// A picture in memory as a script holds it. Its pixels are let go of with
/// it. A pixel outside it is `error.OutsideImage` to read or write; a
/// rectangle is cut to what is inside.
///
/// ```
/// const picture = images.read("res://art/map.png") catch return;
/// const under = picture.getPixel(3, 4);
/// picture.fillRect(0, 0, 8, 8, color(1, 0, 0));
/// picture.blend(images.read("res://art/pin.png") catch return, 20, 30);
/// picture.savePng("user://map.png");
/// ```
pub const ImageRef = struct {
    app: *App,
    held: Image,

    pub const reflect_name = "Image";
    pub const reflect_opaque = true;
    pub const reflect_drop = release;
    pub const reflect_methods = .{
        .width = .{},
        .height = .{},
        .getPixel = .{attr.Params{ .names = &.{ "x", "y" } }},
        .setPixel = .{attr.Params{ .names = &.{ "x", "y", "color" } }},
        .fill = .{attr.Params{ .names = &.{"color"} }},
        .fillRect = .{attr.Params{ .names = &.{ "x", "y", "width", "height", "color" } }},
        .region = .{ attr.Params{ .names = &.{ "vm", "x", "y", "width", "height" } }, flux.Returns.of(ImageRef) },
        .blit = .{ attr.Params{ .names = &.{ "vm", "source", "x", "y" } }, flux.Takes.of("source", ImageRef) },
        .blend = .{ attr.Params{ .names = &.{ "vm", "source", "x", "y" } }, flux.Takes.of("source", ImageRef) },
        .resize = .{ attr.Params{ .names = &.{ "vm", "width", "height", "smooth" } }, attr.defaults(.{true}) },
        .flipX = .{},
        .flipY = .{},
        .copy = .{ attr.Params{ .names = &.{"vm"} }, flux.Returns.of(ImageRef) },
        .savePng = .{ attr.Params{ .names = &.{"path"} }, flux.GivesErrors{} },
        .saveJpg = .{ attr.Params{ .names = &.{ "path", "quality" } }, attr.defaults(.{0.9}), flux.GivesErrors{} },
    };

    fn release(self: *ImageRef, gpa: Allocator) void {
        self.held.deinit(gpa);
    }

    pub fn width(self: *ImageRef) i64 {
        return self.held.width;
    }

    pub fn height(self: *ImageRef) i64 {
        return self.held.height;
    }

    pub fn getPixel(self: *ImageRef, x: i64, y: i64) anyerror!Color {
        return self.held.getPixel(x, y) orelse error.OutsideImage;
    }

    pub fn setPixel(self: *ImageRef, x: i64, y: i64, color: Color) anyerror!void {
        if (!self.held.setPixel(x, y, color)) return error.OutsideImage;
    }

    pub fn fill(self: *ImageRef, color: Color) void {
        self.held.fill(color);
    }

    pub fn fillRect(self: *ImageRef, x: i64, y: i64, w: i64, h: i64, color: Color) void {
        self.held.fillRect(x, y, w, h, color);
    }

    /// A new image of a rectangle of this one.
    pub fn region(self: *ImageRef, vm: *flux.Vm, x: i64, y: i64, w: i64, h: i64) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.held.region(vm.gpa, x, y, w, h));
    }

    /// Another image copied in, its top left at (`x`, `y`), alpha and all.
    pub fn blit(self: *ImageRef, vm: *flux.Vm, source: flux.Value, x: i64, y: i64) anyerror!void {
        self.held.blit((try imageOf(vm, source)).held, x, y);
    }

    /// Another image drawn over, its top left at (`x`, `y`).
    pub fn blend(self: *ImageRef, vm: *flux.Vm, source: flux.Value, x: i64, y: i64) anyerror!void {
        self.held.blend((try imageOf(vm, source)).held, x, y);
    }

    /// Made `width` by `height`: smooth, or each pixel the nearest - for
    /// pixel art.
    pub fn resize(self: *ImageRef, vm: *flux.Vm, w: i64, h: i64, smooth: bool) anyerror!void {
        const made = try self.held.resized(vm.gpa, try side(w), try side(h), smooth);
        self.held.deinit(vm.gpa);
        self.held = made;
    }

    pub fn flipX(self: *ImageRef) void {
        self.held.flipX();
    }

    pub fn flipY(self: *ImageRef) void {
        self.held.flipY();
    }

    pub fn copy(self: *ImageRef, vm: *flux.Vm) anyerror!flux.Value {
        return imageValue(vm, self.app, try self.held.clone(vm.gpa));
    }

    /// Write it as a PNG under `user://`.
    pub fn savePng(self: *ImageRef, path: []const u8) anyerror!void {
        try FileAccess.writable(path);
        const bytes = try self.held.encodePng(self.app.gpa);
        defer self.app.gpa.free(bytes);
        try self.app.writeText(path, bytes);
    }

    /// Write it as a JPEG under `user://`, at a quality from 0 to 1.
    pub fn saveJpg(self: *ImageRef, path: []const u8, quality: f64) anyerror!void {
        try FileAccess.writable(path);
        const scaled: u8 = @intFromFloat(std.math.clamp(@round(quality * 100), 1, 100));
        const bytes = try self.held.encodeJpg(self.app.gpa, scaled);
        defer self.app.gpa.free(bytes);
        try self.app.writeText(path, bytes);
    }
};

/// An image made the scripts' value, which lets go of its pixels.
fn imageValue(vm: *flux.Vm, app: *App, made: Image) flux.Vm.Error!flux.Value {
    var held = made;
    const ref = vm.gpa.create(ImageRef) catch |err| {
        held.deinit(vm.gpa);
        return err;
    };
    ref.* = .{ .app = app, .held = held };
    return vm.adoptHandle(ref) catch |err| {
        ref.held.deinit(vm.gpa);
        vm.gpa.destroy(ref);
        return err;
    };
}

/// The image a script's value is, or `error.NotAnImage`.
fn imageOf(vm: *flux.Vm, value: flux.Value) error{NotAnImage}!*const ImageRef {
    if (vm.reflectOf(value)) |held| if (held.asConst(ImageRef)) |ref| return ref;
    return error.NotAnImage;
}
