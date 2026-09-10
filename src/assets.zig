// SPDX-License-Identifier: BSD-3-Clause

//! What the GPU is holding, and the handles a component points at it with.
//!
//! ```zig
//! const hero = try app.assets.loadTexture("art/hero.png", .{});
//! _ = try app.world.spawnWith(.{
//!     Transform2D{ .x = 100, .y = 80 },
//!     Sprite{ .texture = hero },
//! });
//! ```
//!
//! A component may not hold a pointer, so it holds a generational handle:
//! once a texture is unloaded, its old handles resolve to nothing rather than
//! to whatever reuses the slot. There is always a `white` texel, so an
//! untextured sprite is white times its tint - one pipeline, no branch in the
//! shader. Loading is synchronous: right for a loading screen, not for
//! streaming.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const id = @import("fluxion_id");
const typeface = @import("fluxion_font");

const Atlas = @import("text/Atlas.zig");

const Assets = @This();

/// One texture on the device, and what the renderer needs to know about it
/// without asking the driver.
pub const Texture = struct {
    gpu: rhi.Texture,
    width: u32,
    height: u32,
    /// Per texture, so pixel art and a smooth background can be drawn at once.
    filter: rhi.Filter,
};

/// What a `Sprite` holds: eight bytes, safe in a component or a save file.
///
/// The same layout as fluxion-id's `Handle`, but an `extern struct`: `Handle`
/// is a `packed struct(u64)`, and fluxion-ecs cannot take pointers to a
/// packed struct's fields when it remaps entities. See the README.
pub const TextureHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    /// No texture. Also what all-zero bytes mean: generation zero is never
    /// handed out.
    pub const none: TextureHandle = .{};

    pub fn isNone(self: TextureHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(self: TextureHandle, other: TextureHandle) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    /// The same fields in the same order, so a reinterpretation.
    fn toId(self: TextureHandle) Id {
        return @bitCast(self);
    }

    fn fromId(handle: Id) TextureHandle {
        return @bitCast(handle);
    }
};

const Id = id.handle.Handle(Texture);
const Table = id.handle.Table(Texture);

/// An open typeface, the glyphs it has drawn so far, and their texture.
pub const Font = struct {
    /// Holds views into `bytes`, which is why the bytes are owned here.
    face: typeface.Font,
    bytes: []const u8,

    atlas: Atlas,
    /// One texture per font, so each font's text is one draw call.
    texture: rhi.Texture,
};

/// What a `Text2D` holds. Shaped like `TextureHandle`, for the same reasons.
pub const FontHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    /// No font of its own, which for a `Text2D` means the default one.
    pub const none: FontHandle = .{};

    pub fn isNone(self: FontHandle) bool {
        return self.generation == 0;
    }

    fn toId(self: FontHandle) FontId {
        return @bitCast(self);
    }

    fn fromId(handle: FontId) FontHandle {
        return @bitCast(handle);
    }
};

const FontId = id.handle.Handle(Font);
const FontTable = id.handle.Table(Font);

pub const Error = error{
    /// A file was asked for, and there is no `Io` to read it with. See
    /// `App.Options.io`.
    NoIo,
} || Allocator.Error || rhi.Error;

/// How a font should be opened.
pub const FontOptions = struct {
    /// The glyph atlas's side. 512 holds a couple of alphabets at game sizes.
    atlas: u32 = 512,
    label: []const u8 = "",
};

/// How a texture should be sampled, and what it is called in a debugger.
pub const LoadOptions = struct {
    /// `.nearest` by default: a blurred sprite is the harder mistake to spot.
    filter: rhi.Filter = .nearest,
    label: []const u8 = "",
};

gpa: Allocator,
device: *rhi.Device,
io: ?std.Io,

textures: Table = .empty,
fonts: FontTable = .empty,

/// What a `Text2D` with no font of its own is drawn in: the first font
/// loaded.
default_font: FontHandle = .none,

/// One opaque white texel. See the module comment.
white: TextureHandle = .none,

/// Both ways to sample, made once.
nearest: rhi.Sampler,
linear: rhi.Sampler,

pub fn init(gpa: Allocator, device: *rhi.Device, io: ?std.Io) Error!Assets {
    var self: Assets = .{
        .gpa = gpa,
        .device = device,
        .io = io,
        .nearest = try device.createSampler(.nearest),
        .linear = try device.createSampler(.linear),
    };
    errdefer self.deinit();

    self.white = try self.textureFromPixels(1, 1, &.{ 255, 255, 255, 255 }, .{ .label = "white" });
    return self;
}

pub fn deinit(self: *Assets) void {
    var it = self.textures.iterator();
    while (it.next()) |entry| self.device.destroyTexture(entry.value.gpu);
    self.textures.deinit(self.gpa);

    var faces = self.fonts.iterator();
    while (faces.next()) |entry| {
        entry.value.atlas.deinit();
        self.gpa.free(entry.value.bytes);
        self.device.destroyTexture(entry.value.texture);
    }
    self.fonts.deinit(self.gpa);
    self.device.destroySampler(self.nearest);
    self.device.destroySampler(self.linear);
    self.* = undefined;
}

/// A texture from pixels already in memory, top row first, four bytes each.
pub fn textureFromPixels(
    self: *Assets,
    width: u32,
    height: u32,
    rgba: []const u8,
    options: LoadOptions,
) Error!TextureHandle {
    const gpu = try self.device.createTexture(.{
        .width = width,
        .height = height,
        .data = rgba,
        .label = options.label,
    });
    errdefer self.device.destroyTexture(gpu);

    return .fromId(try self.textures.add(self.gpa, .{
        .gpu = gpu,
        .width = width,
        .height = height,
        .filter = options.filter,
    }));
}

/// A texture from a PNG. The path is relative to the working directory.
pub fn loadTexture(self: *Assets, path: []const u8, options: LoadOptions) !TextureHandle {
    const io = self.io orelse return Error.NoIo;

    var decoded = try image.png.readFile(self.gpa, io, path, .{});
    defer decoded.deinit(self.gpa);

    return self.textureFromPixels(
        decoded.width,
        decoded.height,
        decoded.pixels,
        .{
            .filter = options.filter,
            .label = if (options.label.len == 0) path else options.label,
        },
    );
}

/// Open a font from bytes in memory. The bytes are copied, because the
/// parsed font keeps views into them.
pub fn fontFromBytes(self: *Assets, bytes: []const u8, options: FontOptions) !FontHandle {
    const owned = try self.gpa.dupe(u8, bytes);
    errdefer self.gpa.free(owned);

    const face: typeface.Font = try .init(owned);

    var atlas: Atlas = try .init(self.gpa, options.atlas, options.atlas);
    errdefer atlas.deinit();

    const texture = try self.device.createTexture(.{
        .width = options.atlas,
        .height = options.atlas,
        .data = atlas.pixels,
        .label = if (options.label.len == 0) "glyphs" else options.label,
    });
    errdefer self.device.destroyTexture(texture);

    const handle: FontHandle = .fromId(try self.fonts.add(self.gpa, .{
        .face = face,
        .bytes = owned,
        .atlas = atlas,
        .texture = texture,
    }));

    if (self.default_font.isNone()) self.default_font = handle;
    return handle;
}

/// The operating system's own interface font: one path per platform and no
/// fallback. A game that ships carries its own.
pub fn systemFontPath() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/segoeui.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
}

/// Open a TrueType file from the disc.
pub fn loadFont(self: *Assets, path: []const u8, options: FontOptions) !FontHandle {
    const io = self.io orelse return Error.NoIo;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(32 << 20));
    defer self.gpa.free(bytes);

    return self.fontFromBytes(bytes, .{
        .atlas = options.atlas,
        .label = if (options.label.len == 0) path else options.label,
    });
}

/// What a font handle points at, or the default font when it points at
/// nothing. Null only when there is no font at all.
pub fn fontOf(self: *Assets, handle: FontHandle) ?*Font {
    if (self.fonts.get(handle.toId())) |found| return found;
    if (handle.isNone() and !self.default_font.isNone()) {
        return self.fonts.get(self.default_font.toId());
    }
    return null;
}

/// Upload every atlas that grew since the last frame. The whole image, which
/// is cheap at this size, and a settled game uploads nothing.
pub fn flushFonts(self: *Assets) !void {
    var it = self.fonts.iterator();
    while (it.next()) |entry| {
        if (!entry.value.atlas.dirty) continue;
        try self.device.updateTexture(
            entry.value.texture,
            entry.value.atlas.pixels,
            entry.value.atlas.rowPitch(),
        );
        entry.value.atlas.markClean();
    }
}

/// Give a texture back to the driver. Every handle to it stops resolving.
pub fn unload(self: *Assets, handle: TextureHandle) void {
    if (self.textures.remove(handle.toId())) |texture| {
        self.device.destroyTexture(texture.gpu);
    }
}

/// What a handle points at, or null if it points at nothing any more.
pub fn get(self: *Assets, handle: TextureHandle) ?*Texture {
    return self.textures.get(handle.toId());
}

/// How big a texture is, in texels. Null for an expired handle, so a sprite
/// falls back to the white texel.
pub fn sizeOf(self: *Assets, handle: TextureHandle) ?struct { width: f32, height: f32 } {
    const texture = self.textures.get(handle.toId()) orelse return null;
    return .{
        .width = @floatFromInt(texture.width),
        .height = @floatFromInt(texture.height),
    };
}

/// The sampler a texture asked for.
pub fn samplerFor(self: *const Assets, filter: rhi.Filter) rhi.Sampler {
    return switch (filter) {
        .nearest => self.nearest,
        .linear => self.linear,
    };
}

/// How many textures are loaded, not counting the white texel.
pub fn count(self: *const Assets) usize {
    const total = self.textures.count();
    return if (total == 0) 0 else total - 1;
}

test "a handle stops resolving when what it named is unloaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var assets: Assets = try .init(testing.allocator, &device, null);
    defer assets.deinit();

    const handle = try assets.textureFromPixels(2, 2, &(.{255} ** 16), .{});
    try testing.expect(assets.get(handle) != null);

    assets.unload(handle);
    try testing.expect(assets.get(handle) == null);

    // The slot is handed out again, and the old handle still says no.
    const second = try assets.textureFromPixels(2, 2, &(.{128} ** 16), .{});
    try testing.expect(assets.get(second) != null);
    try testing.expect(assets.get(handle) == null);
}

test "there is a white texel before anything is loaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var assets: Assets = try .init(testing.allocator, &device, null);
    defer assets.deinit();

    try testing.expect(!assets.white.isNone());
    try testing.expectEqual(@as(usize, 0), assets.count());
}

test "the first font opened becomes the default" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var assets: Assets = try .init(testing.allocator, &device, null);
    defer assets.deinit();

    try testing.expect(assets.default_font.isNone());
    try testing.expect(assets.fontOf(.none) == null);
}

test "reading a file without an Io says so rather than crashing" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var assets: Assets = try .init(testing.allocator, &device, null);
    defer assets.deinit();

    try testing.expectError(Error.NoIo, assets.loadTexture("nothing.png", .{}));
}
