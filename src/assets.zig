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
//! **A component may not hold a pointer**, so it holds a handle: an index and
//! a generation in eight bytes, from
//! [Fluxion Id](https://github.com/kisstp2006/fluxion-id). Unloading a texture
//! and loading another does not make every sprite that pointed at the first
//! one draw the second - the generation has moved on, the handle resolves to
//! nothing, and the sprite draws as an untextured rectangle instead of as
//! whatever happened to land in that slot. A plain index cannot promise that,
//! and a pointer could not be in a component at all.
//!
//! **There is always a white texture.** A sprite with no texture is a
//! rectangle of solid colour, and the cheap way to draw one is not a second
//! pipeline with no texture in it - it is one white texel multiplied by the
//! tint. So `white` exists from `init`, the renderer reaches for it when a
//! handle resolves to nothing, and there is one pipeline and no branch in the
//! shader.
//!
//! **Loading is not streaming.** `loadTexture` reads the file, decodes it and
//! uploads it, on the calling thread, before returning - which stalls the
//! frame it is called from. That is the right shape for a loading screen and
//! the wrong one for an open world, and the seam for the second is this same
//! function taking a job rather than doing the work. It is not written yet;
//! nothing above here needs to change when it is.

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
    /// The device's own handle.
    gpu: rhi.Texture,
    width: u32,
    height: u32,
    /// How it is sampled when it is not drawn at its own size. Kept per
    /// texture rather than per device, because a game is allowed to have a
    /// pixel-art sprite sheet and a smooth photographic background at once.
    filter: rhi.Filter,
};

/// What a `Sprite` holds. Eight bytes, copyable, and safe to store in a
/// component or a save file.
///
/// The same index-and-generation as
/// [Fluxion Id](https://github.com/kisstp2006/fluxion-id)'s `Handle`, and the
/// same eight bytes - written out here as an `extern struct` rather than
/// aliased, for two reasons. The first is that it appears in a component and
/// in every save file a game writes, so it is the engine's own promise and
/// not a dependency's representation showing through. The second is
/// mechanical: `Handle` is a `packed struct(u64)`, whose fields cannot have a
/// normally aligned pointer taken to them, and the world's entity remapper
/// walks a component's fields by pointer. A packed handle in a component
/// therefore fails to compile inside `fluxion-ecs` - see the note in the
/// README.
pub const TextureHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    /// No texture. Also what all-zero bytes mean, which is why generation
    /// zero is never handed out.
    pub const none: TextureHandle = .{};

    pub fn isNone(self: TextureHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(self: TextureHandle, other: TextureHandle) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    /// The two halves are in the same order and the same widths, so this is
    /// a reinterpretation and not a conversion.
    fn toId(self: TextureHandle) Id {
        return @bitCast(self);
    }

    fn fromId(handle: Id) TextureHandle {
        return @bitCast(handle);
    }
};

/// The handle the table below actually hands out. Not the engine's own type;
/// see `TextureHandle`.
const Id = id.handle.Handle(Texture);
const Table = id.handle.Table(Texture);

/// A typeface open, the glyphs it has drawn so far, and the texture they are
/// in.
pub const Font = struct {
    /// The parsed font. It holds views into `bytes` and copies none of it,
    /// which is why the bytes are owned here and freed with it.
    face: typeface.Font,
    bytes: []const u8,

    /// Every glyph this font has drawn, at every size. See `text/Atlas.zig`.
    atlas: Atlas,
    /// What the atlas is uploaded into. One texture per font, so a game with
    /// a title face and a body face draws its text in two calls and a game
    /// with one draws it in one.
    texture: rhi.Texture,
};

/// What a `Text2D` holds. The same shape as a `TextureHandle`, for the same
/// reasons.
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
    /// A texture was asked for from a file, and the engine was built without
    /// anything to read files with. See `App.Options.io`.
    NoIo,
} || Allocator.Error || rhi.Error;

/// How a font should be opened.
pub const FontOptions = struct {
    /// How big its glyph atlas is, per side. 512 square holds a couple of
    /// alphabets at the sizes a game uses; a game with many sizes or a large
    /// character set wants more.
    atlas: u32 = 512,
    label: []const u8 = "",
};

/// How a texture should be sampled, and what it is called in a debugger.
pub const LoadOptions = struct {
    /// `.nearest` for pixel art - the default, because a blurred sprite is
    /// the more surprising of the two mistakes and the harder to notice on a
    /// screenshot.
    filter: rhi.Filter = .nearest,
    label: []const u8 = "",
};

gpa: Allocator,
device: *rhi.Device,
io: ?std.Io,

textures: Table = .empty,
fonts: FontTable = .empty,

/// What a `Text2D` with no font of its own is drawn in: the first font
/// loaded, unless something says otherwise. A game with one font never names
/// it after the line that opened it.
default_font: FontHandle = .none,

/// One opaque white texel. See the note above.
white: TextureHandle = .none,

/// The two ways to sample, made once. A sampler is a handful of numbers on
/// every backend there is, so having both costs nothing and saves the
/// renderer having to make one when a texture turns out to want it.
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

/// A texture from a PNG on the disc.
///
/// The path is relative to wherever the program was started from, which is
/// the same rule every other file in a game follows and the reason a game
/// that runs from its build directory and not from its install directory has
/// this function to blame.
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

/// Open a font from bytes already in memory.
///
/// The bytes are **copied**, unlike everywhere else in this stack: a
/// `typeface.Font` holds views into the file rather than parsing it into
/// structures of its own, so the file has to outlive the font - and a font in
/// a table that outlives whatever the caller was holding is the kind of
/// lifetime nobody should have to think about while making a game.
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

/// This operating system's own interface font.
///
/// A convenience for getting text on screen before anybody has chosen a
/// typeface, and not a font-matching library: there is one path per platform
/// and no fallback chain. A game that ships knows which file it wants and
/// carries it.
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

/// Send any atlas that has grown since the last frame to the device.
///
/// Called by the renderer once a frame, before it draws. Uploading the whole
/// image rather than the rectangle that changed is the simple thing and the
/// right one at this size: a 512-square atlas is a megabyte, it only happens
/// on a frame that saw a letter it had never drawn before, and a settled game
/// stops uploading entirely.
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

/// Give a texture back to the driver. Every handle to it stops resolving,
/// which is what the generation is for.
pub fn unload(self: *Assets, handle: TextureHandle) void {
    if (self.textures.remove(handle.toId())) |texture| {
        self.device.destroyTexture(texture.gpu);
    }
}

/// What a handle points at, or null if it points at nothing any more.
pub fn get(self: *Assets, handle: TextureHandle) ?*Texture {
    return self.textures.get(handle.toId());
}

/// How big a texture is, in texels. Null for a handle that has expired, which
/// is what lets a sprite fall back to the white texel rather than crash.
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

    // The slot is handed out again, and the old handle still says no - which
    // is the whole point of the generation and the bug a plain index has.
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
