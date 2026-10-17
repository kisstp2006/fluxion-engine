// SPDX-License-Identifier: BSD-3-Clause

//! What the GPU is holding, and the handles a component points at it with.
//!
//! ```zig
//! const hero = try app.assets.loadTexture("res://art/hero.png", .{});
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
//!
//! A file is named as `Project` names it: `res://` from the project's root,
//! `uid://` by the UUID beside it, or the operating system's path - and kept
//! by its `res://` path whenever it lies inside the project, however it was
//! asked for.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const mip_maker_table = @import("mip_maker.zig");
const bc = @import("bc.zig");
const id = @import("fluxion_id");
const typeface = @import("fluxion_font");
const platform = @import("fluxion_platform");

const Atlas = @import("../render/GlyphAtlas.zig");
const Project = @import("../project/Project.zig");

const Assets = @This();
const log = std.log.scoped(.fluxion_engine);

/// One texture on the device, and what the renderer needs to know about it
/// without asking the driver.
pub const Texture = struct {
    gpu: rhi.Texture,
    width: u32,
    height: u32,
    /// Per texture, so pixel art and a smooth background can be drawn at once.
    filter: rhi.Filter,
    wrap: rhi.Wrap,
    /// The file it was read from - `res://` inside the project, the
    /// operating system's absolute path outside it - or empty when it was
    /// made from pixels in memory. What a scene writes in the handle's place.
    source: []const u8 = "",
    /// Drawn into, and read bottom row first where the backend counts rows
    /// from the bottom: a picture of it is turned over to be shown. See
    /// `addRenderTexture`.
    upside_down: bool = false,
    /// A chain of levels below the picture, each half the one above, made
    /// on the GPU: what a sampler that filters between levels reads where
    /// the picture is drawn small - a 3D surface far off - so that it does
    /// not shimmer. See `LoadOptions.mips` and `wantMips`.
    mips: bool = false,
    /// Asked for a chain once already - given it, or with no file to make
    /// it from - so not asked again.
    mips_asked: bool = false,
    /// Writes invalidate a replacement being decoded or uploaded.
    revision: u64 = 0,
    /// Identical immutable RGBA pictures share device storage. Writes detach
    /// a shared picture, while its logical handle and sampler stay independent.
    fingerprint: ?[32]u8 = null,
    /// Drawn smaller than its picture, for `Assets.texture_max_size`: read
    /// again at its own size when the limit is raised.
    limited: bool = false,
    /// Its chain is made again from its file, the picture's own size held to
    /// the limit: asked when the limit or the compression changes.
    regrow: bool = false,
    /// How it is kept on the device: four bytes a texel, or BC's blocks.
    format: rhi.Format = .rgba8_unorm,
    /// What it is to a surface: a normal map is kept as two channels.
    role: Role = .color,
    /// Its own say over compression and size, where its import settings
    /// give one: null is the project's.
    compress: ?bool = null,
    max_size: ?u32 = null,
};

/// What a picture's own import settings say of it on a 3D surface: in
/// `<picture>.import` beside it, as a model's are, and what the editor's
/// inspector shows for it.
pub const TextureSettings = struct {
    /// Whether it is kept on the graphics card as BC's compressed blocks: as
    /// the project says, always, or never.
    compression: Compression = .project,
    /// The longest side it is kept at on the graphics card, halved until it
    /// fits: nought for the project's.
    max_size: u32 = 0,

    pub const Compression = enum { project, compressed, uncompressed };

    /// The settings beside the picture at `source`, or none where it has
    /// none or they do not read.
    pub fn of(gpa: Allocator, files: Project.Files, source: []const u8) TextureSettings {
        const path = std.mem.concat(gpa, u8, &.{ source, ".import" }) catch return .{};
        defer gpa.free(path);
        const bytes = files.read(gpa, path, .limited(16 * 1024)) catch return .{};
        defer gpa.free(bytes);
        const parsed = @import("fluxion_json").parseAs(TextureSettings, gpa, bytes, .{ .syntax = .json5 }) catch |err| {
            log.warn("{s} does not read, and the picture is kept as the project says: {t}", .{ path, err });
            return .{};
        };
        defer parsed.deinit();
        return parsed.value;
    }

    /// As a texture's own say: null for the project's.
    pub fn compress(self: TextureSettings) ?bool {
        return switch (self.compression) {
            .project => null,
            .compressed => true,
            .uncompressed => false,
        };
    }

    pub fn maxSize(self: TextureSettings) ?u32 {
        return if (self.max_size == 0) null else self.max_size;
    }
};

/// What a picture is to the surface it is on: a normal map's `x` and `y`
/// are kept as BC5's two channels, its `z` worked out where it is read.
pub const Role = enum(u8) { color, normal };

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

    /// Two numbers that mean something only to this run's `Assets`: a tool
    /// shows `Assets.textureSource` instead.
    pub const reflect_name = "TextureHandle";

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
    /// The file it was read from, or empty. See `Texture.source`.
    source: []const u8 = "",
    /// Which font of that file it is, when the file is a collection. See
    /// `FontOptions.member`.
    member: u32 = 0,
};

/// What a `Text2D` holds. Shaped like `TextureHandle`, for the same reasons.
pub const FontHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    /// No font of its own, which for a `Text2D` means the default one.
    pub const none: FontHandle = .{};

    /// A tool shows `Assets.fontSource` instead, as for a texture.
    pub const reflect_name = "FontHandle";

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

// Boxed, so a font keeps its address when the table grows: the interface's
// renderer holds on to the face.
const FontId = id.handle.Handle(*Font);
const FontTable = id.handle.Table(*Font);

const Samplers = std.EnumArray(rhi.Filter, std.EnumArray(rhi.Wrap, rhi.Sampler));

pub const Error = error{
    /// A file was asked for, and there is no `Io` to read it with. See
    /// `App.Options.io`.
    NoIo,
} || Allocator.Error || rhi.Error;

/// The biggest font file read: far past any typeface a game ships, and short
/// of reading a wrongly named video into memory.
const font_limit = 32 << 20;
/// The most a picture's file is read: a 16K by 16K PNG with nothing in it to
/// compress is a gigabyte, and one worth drawing is a fraction of that.
const picture_limit = 256 << 20;

/// How a font should be opened.
pub const FontOptions = struct {
    /// The glyph atlas's side. 512 holds a couple of alphabets at game sizes.
    atlas: u32 = 512,
    label: []const u8 = "",
    /// Which font of a TrueType collection - a `.ttc`, several fonts in one
    /// file - by its place in the file, and nought for a file that is one
    /// font. What the system's own lookup answers with the path: see
    /// `loadSystemFont`.
    member: u32 = 0,
    /// For `loadSystemFont`: the system's monospaced font - the one its
    /// terminal and its code editors use - rather than its interface font.
    mono: bool = false,
};

/// How a texture should be sampled, and what it is called in a debugger.
pub const LoadOptions = struct {
    /// `.nearest` by default: a blurred sprite is the harder mistake to spot.
    /// Null is `Assets.default_filter`.
    filter: ?rhi.Filter = null,
    wrap: rhi.Wrap = .clamp_to_edge,
    label: []const u8 = "",
    /// A chain of levels below the picture, for one drawn small: a 3D
    /// surface's. See `Texture.mips`.
    mips: bool = false,
    /// With a chain: what it is to its surface, and its own say over
    /// compression and size - null for the project's.
    role: Role = .color,
    compress: ?bool = null,
    max_size: ?u32 = null,
    /// What a loading thread read of the `.uid` file beside it: taken in
    /// rather than read again here, on the game's thread. See
    /// `Project.readUidWith`.
    uid: Project.UidRead = .unknown,
};

gpa: Allocator,
device: *rhi.Device,
io: ?std.Io,
/// What a path is resolved against, and the UUIDs of the files read.
project: *Project,

textures: Table = .empty,
fonts: FontTable = .empty,

/// What a `Text2D` with no font of its own is drawn in: the first font
/// loaded.
default_font: FontHandle = .none,

/// What every text falls back on, most wanted first, for an emoji and for a
/// character its own font has no glyph for: the system's emoji fonts, once
/// `loadEmojiFonts` has opened them.
fallback_fonts: [max_fallback_fonts]FontHandle = @splat(.none),
fallback_count: u8 = 0,

/// How many times a font has been read again, counting up. A font read
/// again keeps its address, so whoever holds glyphs drawn from one - the
/// interface's renderer - watches this to draw them again. See `reloadFont`.
font_reloads: u32 = 0,

/// One opaque white texel. See the module comment.
white: TextureHandle = .none,

/// A soft round glow, white and fading out to its edge: what a light with no
/// picture of its own shines through, and a particle with none is.
glow: TextureHandle = .none,

/// How a texture is sampled when what loads it does not say: the project's
/// `rendering.default_texture_filter`.
default_filter: rhi.Filter = .nearest,
/// The longest side a 3D surface's picture - one with a chain of levels - is
/// kept at on the device, halved until it fits: nought for its own size. A
/// 2048 picture is 21 MiB there and a 1024 one 5; sprites and the interface
/// are never made smaller. The project's `rendering.texture_max_size`, and
/// `setTextureMaxSize` as a game runs.
texture_max_size: u32 = 0,
/// Whether a 3D surface's picture is kept as BC's compressed blocks where
/// the device samples them: a quarter of its memory, or an eighth for one
/// with no alpha. The project's `rendering.texture_compression`.
texture_compression: bool = true,
/// How many textures have been made from images: the number in the next
/// one's name, `image://N`. See `images.toTexture`.
images_made: u32 = 0,

samplers: Samplers,
/// The same, filtering between the levels of a chain as well, and a linear
/// one anisotropically, as far as the device goes: what a 3D surface's
/// pictures are drawn with.
mip_samplers: Samplers,
/// The textures `wantMips` asked a chain for, made before the next frame
/// is drawn.
mips_wanted: std.ArrayListUnmanaged(TextureHandle) = .empty,
/// What reads the wanted pictures again, off this thread: started with the
/// first asked.
mip_maker: ?mip_maker_table.MipMaker(MipRequest) = null,
/// The old picture stays live while its replacement is filled over frames.
mip_upload: ?MipUpload = null,

/// A picture to read again and make into a chain, as it is wanted now: made
/// on the mip maker's thread, `prepare`, and only uploaded on the game's.
const MipRequest = struct {
    handle: TextureHandle,
    revision: u64 = 0,
    recipe: Recipe = .{},

    pub const Chain = Assets.Chain;

    pub fn prepare(self: MipRequest, gpa: Allocator, picture: *const image.Decoded) !Assets.Chain {
        return makeChain(gpa, picture.width, picture.height, picture.pixels, self.recipe);
    }
};

/// A chain filled over frames, the old picture drawn until it is done.
const MipUpload = struct {
    handle: TextureHandle,
    before: rhi.Texture,
    revision: u64,
    gpu: rhi.Texture,
    chain: Chain,
    /// The level being written, and how many of its rows - of texels, or of
    /// blocks - are.
    level: u32 = 0,
    row: u32 = 0,

    fn deinit(self: *MipUpload, assets: *Assets) void {
        if (!self.gpu.isNone()) assets.device.destroyTexture(self.gpu);
        self.chain.deinit(assets.gpa);
    }
};

pub fn init(gpa: Allocator, device: *rhi.Device, io: ?std.Io, project: *Project) Error!Assets {
    var self: Assets = .{
        .gpa = gpa,
        .device = device,
        .io = io,
        .project = project,
        .samplers = .initFill(.initFill(.none)),
        .mip_samplers = .initFill(.initFill(.none)),
    };
    errdefer self.deinit();

    // A device with no border colour - WebGL - samples past a border
    // texture's edge as past a clamped one's.
    const border = device.caps().features.sampler_border;
    for (std.enums.values(rhi.Filter)) |filter| {
        for (std.enums.values(rhi.Wrap)) |wrap| {
            const made: rhi.Wrap = if (wrap == .border and !border) .clamp_to_edge else wrap;
            self.samplers.getPtr(filter).set(wrap, try device.createSampler(.{
                .min_filter = filter,
                .mag_filter = filter,
                .wrap_u = made,
                .wrap_v = made,
            }));
            // And along a stretched footprint where it filters linearly - a
            // floor seen at a slant - as far as the device goes.
            self.mip_samplers.getPtr(filter).set(wrap, try device.createSampler(.{
                .min_filter = filter,
                .mag_filter = filter,
                .mip_filter = if (filter == .linear) .linear else .nearest,
                .max_anisotropy = if (filter == .linear) 16 else 1,
                .wrap_u = made,
                .wrap_v = made,
            }));
        }
    }

    self.white = try self.textureFromPixels(1, 1, &.{ 255, 255, 255, 255 }, .{ .label = "white" });
    self.glow = try self.makeGlow();
    return self;
}

/// How many texels across the glow is.
const glow_side = 64;

fn makeGlow(self: *Assets) Error!TextureHandle {
    var pixels: [glow_side * glow_side * 4]u8 = undefined;
    const half: f32 = glow_side / 2;
    for (0..glow_side) |y| for (0..glow_side) |x| {
        const dx = (@as(f32, @floatFromInt(x)) + 0.5) / half - 1;
        const dy = (@as(f32, @floatFromInt(y)) + 0.5) / half - 1;
        // Falling off as the square of what is left of the way out.
        const left = @max(1 - @sqrt(dx * dx + dy * dy), 0);
        const at = (y * glow_side + x) * 4;
        pixels[at..][0..4].* = .{ 255, 255, 255, @intFromFloat(@round(left * left * 255)) };
    };
    return self.textureFromPixels(glow_side, glow_side, &pixels, .{ .filter = .linear, .label = "glow" });
}

pub fn deinit(self: *Assets) void {
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        const gpu = entry.value.gpu;
        entry.value.gpu = .none;
        self.releaseTexture(gpu, null);
        self.gpa.free(entry.value.source);
    }
    self.textures.deinit(self.gpa);

    var faces = self.fonts.iterator();
    while (faces.next()) |entry| {
        const font = entry.value.*;
        font.atlas.deinit();
        self.gpa.free(font.bytes);
        self.gpa.free(font.source);
        self.device.destroyTexture(font.texture);
        self.gpa.destroy(font);
    }
    self.fonts.deinit(self.gpa);
    for ([_]Samplers{ self.samplers, self.mip_samplers }) |samplers| {
        for (samplers.values) |by_wrap| {
            for (by_wrap.values) |sampler| if (!sampler.isNone()) self.device.destroySampler(sampler);
        }
    }
    if (self.mip_maker) |*maker| maker.deinit();
    if (self.mip_upload) |*upload| upload.deinit(self);
    self.mips_wanted.deinit(self.gpa);
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
    return self.addTexture(width, height, rgba, options, "");
}

/// Takes `source`, which is freed with the texture.
fn addTexture(
    self: *Assets,
    width: u32,
    height: u32,
    rgba: []const u8,
    options: LoadOptions,
    source: []const u8,
) Error!TextureHandle {
    const made = try self.makeTexture(width, height, rgba, options.label, .{ .mips = options.mips, .role = options.role, .compress = options.compress, .max_size = options.max_size });
    errdefer self.releaseTexture(made.gpu, null);

    return .fromId(try self.textures.add(self.gpa, .{
        .gpu = made.gpu,
        .width = made.width,
        .height = made.height,
        .filter = options.filter orelse self.default_filter,
        .wrap = options.wrap,
        .source = source,
        .mips = made.mips,
        .mips_asked = options.mips,
        .fingerprint = made.fingerprint,
        .limited = made.limited,
        .format = made.format,
        .role = options.role,
        .compress = options.compress,
        .max_size = options.max_size,
    }));
}

/// A texture of `rgba`, with a chain of levels below it if `want.mips`
/// asks and the device can make one - a texel has none below it. One with a
/// chain - a 3D surface's - is held to the size limit and kept as BC's
/// blocks where it can be: see `makeChain`.
fn makeTexture(self: *Assets, width: u32, height: u32, rgba: []const u8, label: []const u8, want: Want) Error!Made {
    if (!want.mips) {
        var fingerprint: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rgba, &fingerprint, .{});
        if (self.identicalTexture(width, height, false, fingerprint)) |gpu|
            return .{ .gpu = gpu, .mips = false, .fingerprint = fingerprint, .width = width, .height = height, .limited = false, .format = .rgba8_unorm };
        const gpu = try self.device.createTexture(.{ .width = width, .height = height, .data = rgba, .label = label });
        return .{ .gpu = gpu, .mips = false, .fingerprint = fingerprint, .width = width, .height = height, .limited = false, .format = .rgba8_unorm };
    }
    var chain = try makeChain(self.gpa, width, height, rgba, self.recipeOf(want));
    defer chain.deinit(self.gpa);
    return self.uploadChain(&chain, label);
}

/// A chain on the device whole: every level written now.
fn uploadChain(self: *Assets, chain: *const Chain, label: []const u8) Error!Made {
    const made: Made = .{ .gpu = .none, .mips = chain.mips(self.device), .fingerprint = chain.fingerprint, .width = chain.width, .height = chain.height, .limited = chain.limited, .format = chain.format };
    if (self.identicalTexture(chain.width, chain.height, made.mips, chain.fingerprint)) |gpu| {
        var shared = made;
        shared.gpu = gpu;
        return shared;
    }
    const gpu = try self.device.createTexture(.{
        .width = chain.width,
        .height = chain.height,
        .format = chain.format,
        .data = chain.levels[0],
        .label = label,
        .mip_levels = chain.levelCount(self.device),
    });
    errdefer self.device.destroyTexture(gpu);
    for (chain.levels[1..], 1..) |level, at| try self.device.writeTexture(gpu, .{ .mip = @intCast(at) }, level, 0, 0);
    if (chain.format == .rgba8_unorm and made.mips) try self.fillMips(gpu);
    var out = made;
    out.gpu = gpu;
    return out;
}

/// What a texture is made with: a chain or not, and for one with a chain
/// what it is to its surface and its own say over compression and size.
pub const Want = struct {
    mips: bool = false,
    role: Role = .color,
    compress: ?bool = null,
    max_size: ?u32 = null,
};

/// What `makeTexture` made, at the size and in the format it was made.
const Made = struct { gpu: rhi.Texture, mips: bool, fingerprint: [32]u8, width: u32, height: u32, limited: bool, format: rhi.Format };

/// How a chain is made: what the device and the project allow, and what
/// the picture is - worked out on the game's thread, used on any.
pub const Recipe = struct {
    max_size: u32 = 0,
    /// The BC formats the device samples, each where compression is on.
    bc1: bool = false,
    bc3: bool = false,
    bc5: bool = false,
    /// Whether a level of compressed blocks may be other than whole blocks.
    partial_blocks: bool = false,
    role: Role = .color,
};

fn recipeOf(self: *Assets, want: Want) Recipe {
    const caps = self.device.caps();
    const compress = want.compress orelse self.texture_compression;
    return .{
        .max_size = want.max_size orelse self.texture_max_size,
        .bc1 = compress and caps.formatSupport(.bc1_rgba_unorm).sampled,
        .bc3 = compress and caps.formatSupport(.bc3_rgba_unorm).sampled,
        .bc5 = compress and caps.formatSupport(.bc5_rg_unorm).sampled,
        .partial_blocks = caps.features.compressed_partial_blocks,
        .role = want.role,
    };
}

/// A 3D surface's picture as the device keeps it: held to the size limit,
/// and - where the recipe allows - its every level as BC's blocks, made
/// here, as a GPU cannot make the levels of a compressed texture. Otherwise
/// one level of RGBA, its chain made on the GPU.
pub const Chain = struct {
    width: u32,
    height: u32,
    format: rhi.Format,
    /// Each level, the largest first: one for RGBA.
    levels: [][]u8,
    limited: bool,
    /// The picture's at the size it is kept, and the format: two textures
    /// with the same share the device's.
    fingerprint: [32]u8,

    pub fn deinit(self: *Chain, gpa: Allocator) void {
        for (self.levels) |level| gpa.free(level);
        gpa.free(self.levels);
        self.* = undefined;
    }

    /// Whether it has levels below the first on `device`.
    fn mips(self: *const Chain, device: *rhi.Device) bool {
        if (self.width <= 1 and self.height <= 1) return false;
        return self.format != .rgba8_unorm or device.caps().formatSupport(.rgba8_unorm).generate_mips;
    }

    fn levelCount(self: *const Chain, device: *rhi.Device) u32 {
        if (self.format != .rgba8_unorm) return @intCast(self.levels.len);
        return if (self.mips(device)) 0 else 1;
    }
};

pub fn makeChain(gpa: Allocator, width: u32, height: u32, rgba: []const u8, recipe: Recipe) Allocator.Error!Chain {
    const size = limitedSize(width, height, recipe.max_size);
    const limited = size[0] != width or size[1] != height;
    const first = if (limited) try halved(gpa, width, height, rgba, size) else try gpa.dupe(u8, rgba[0 .. @as(usize, width) * height * 4]);
    errdefer gpa.free(first);
    const kind: ?bc.Kind = blk: {
        if (!recipe.partial_blocks and (size[0] % 4 != 0 or size[1] % 4 != 0)) break :blk null;
        if (recipe.role == .normal and recipe.bc5) break :blk .bc5;
        if (bc.isOpaque(first)) break :blk if (recipe.bc1) .bc1 else null;
        break :blk if (recipe.bc3) .bc3 else null;
    };
    const format: rhi.Format = if (kind) |k| switch (k) {
        .bc1 => .bc1_rgba_unorm,
        .bc3 => .bc3_rgba_unorm,
        .bc5 => .bc5_rg_unorm,
    } else .rgba8_unorm;
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    hash.update(first);
    // Four bytes a texel are known by their pixels alone, as any such
    // picture is; blocks by the format too.
    if (format != .rgba8_unorm) hash.update(@tagName(format));
    var fingerprint: [32]u8 = undefined;
    hash.final(&fingerprint);
    const k = kind orelse {
        const levels = try gpa.alloc([]u8, 1);
        levels[0] = first;
        return .{ .width = size[0], .height = size[1], .format = format, .levels = levels, .limited = limited, .fingerprint = fingerprint };
    };
    const levels = try gpa.alloc([]u8, rhi.fullMipCount(size[0], size[1], 1));
    var made: usize = 0;
    errdefer {
        for (levels[0..made]) |level| gpa.free(level);
        gpa.free(levels);
    }
    var pixels = first;
    defer gpa.free(pixels);
    var w = size[0];
    var h = size[1];
    for (levels) |*level| {
        level.* = try gpa.alloc(u8, k.size(w, h));
        made += 1;
        bc.encode(k, level.*, pixels, w, h);
        if (w == 1 and h == 1) break;
        const nw = @max(w / 2, 1);
        const nh = @max(h / 2, 1);
        const next = try halved(gpa, w, h, pixels, .{ nw, nh });
        gpa.free(pixels);
        pixels = next;
        w = nw;
        h = nh;
    }
    return .{ .width = size[0], .height = size[1], .format = format, .levels = levels, .limited = limited, .fingerprint = fingerprint };
}

/// The size a picture `width` by `height` is kept at with `max_size` at most
/// a side: halved, as its levels are, until it fits. Nought keeps it.
pub fn limitedSize(width: u32, height: u32, max_size: u32) [2]u32 {
    var w = width;
    var h = height;
    if (max_size == 0) return .{ w, h };
    while (@max(w, h) > max_size and (w > 1 or h > 1)) {
        w = @max(w / 2, 1);
        h = @max(h / 2, 1);
    }
    return .{ w, h };
}

/// `rgba`, `width` by `height`, halved until it is `to`: each texel the mean
/// of the two by two above it, as a level below it would be.
fn halved(gpa: Allocator, width: u32, height: u32, rgba: []const u8, to: [2]u32) Allocator.Error![]u8 {
    var w = width;
    var h = height;
    // The picture given is read, never copied whole: each level is made
    // from the one above it.
    var from: ?[]u8 = null;
    errdefer if (from) |held| gpa.free(held);
    while (w != to[0] or h != to[1]) {
        const nw = @max(w / 2, 1);
        const nh = @max(h / 2, 1);
        const next = try gpa.alloc(u8, @as(usize, nw) * nh * 4);
        halveOnce(from orelse rgba, w, h, next, nw, nh);
        if (from) |held| gpa.free(held);
        from = next;
        w = nw;
        h = nh;
    }
    return from orelse gpa.dupe(u8, rgba[0 .. @as(usize, w) * h * 4]);
}

/// One level down: rows shared between threads where the picture is large.
fn halveOnce(from: []const u8, w: u32, h: u32, to: []u8, nw: u32, nh: u32) void {
    const threads: u32 = if (builtin.single_threaded or @as(usize, nw) * nh < 256 * 256) 1 else @intCast(@min(std.Thread.getCpuCount() catch 1, 8, nh));
    if (threads <= 1) return halveRows(from, w, h, to, nw, 0, nh);
    var workers: [8]?std.Thread = @splat(null);
    const per = (nh + threads - 1) / threads;
    var first: u32 = 0;
    for (workers[0..threads]) |*worker| {
        const last = @min(first + per, nh);
        if (first >= last) break;
        worker.* = std.Thread.spawn(.{}, halveRows, .{ from, w, h, to, nw, first, last }) catch blk: {
            halveRows(from, w, h, to, nw, first, last);
            break :blk null;
        };
        first = last;
    }
    for (workers[0..threads]) |worker| if (worker) |held| held.join();
}

fn halveRows(from: []const u8, w: u32, h: u32, to: []u8, nw: u32, first: u32, last: u32) void {
    for (first..last) |y| {
        const y0 = @min(y * 2, h - 1);
        const y1 = @min(y * 2 + 1, h - 1);
        const row0 = from[y0 * w * 4 ..][0 .. w * 4];
        const row1 = from[y1 * w * 4 ..][0 .. w * 4];
        const out = to[y * nw * 4 ..][0 .. nw * 4];
        // Two texels of each row a texel, four channels at once.
        for (0..nw) |x| {
            const x0 = @min(x * 2, w - 1) * 4;
            const x1 = @min(x * 2 + 1, w - 1) * 4;
            const a: @Vector(4, u16) = row0[x0..][0..4].*;
            const b: @Vector(4, u16) = row0[x1..][0..4].*;
            const c: @Vector(4, u16) = row1[x0..][0..4].*;
            const d: @Vector(4, u16) = row1[x1..][0..4].*;
            const mean: @Vector(4, u8) = @intCast((a + b + c + d + @as(@Vector(4, u16), @splat(2))) >> @splat(2));
            out[x * 4 ..][0..4].* = mean;
        }
    }
}

/// Hold every 3D surface's picture to `size` a side - nought for none - from
/// now on, and those on the device already: each is read again from its
/// file - or from its model, for a model's picture - and made again at the
/// size that fits, the one there drawn until it is. One made from pixels in
/// memory has nothing to be read from, and keeps the size it has.
pub fn setTextureMaxSize(self: *Assets, size: u32) void {
    if (size == self.texture_max_size) return;
    self.texture_max_size = size;
    self.remakeChains();
}

/// Keep every 3D surface's picture as BC's blocks where the device has them,
/// or as four bytes a texel - those on the device already made again, as
/// `setTextureMaxSize` does.
pub fn setTextureCompression(self: *Assets, on: bool) void {
    if (on == self.texture_compression) return;
    self.texture_compression = on;
    self.remakeChains();
}

/// A texture's pixels at the size it is kept, four bytes a texel, top row
/// first: read back from the device - or, for one kept as compressed
/// blocks, which a device does not give back, read again from its file and
/// made the size it is. The caller's, freed with `gpa`.
pub fn readPixels(self: *Assets, handle: TextureHandle, gpa: Allocator) ![]u8 {
    const held = self.get(handle) orelse return error.NoSuchTexture;
    if (held.format == .rgba8_unorm) return self.device.readTexture(held.gpu, gpa);
    if (self.project.io == null) return error.NoIo;
    const bytes = try mip_maker_table.readPicture(gpa, self.project.files(), held.source, picture_limit);
    defer gpa.free(bytes);
    var decoded = try image.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    return halved(gpa, decoded.width, decoded.height, decoded.pixels, limitedSize(decoded.width, decoded.height, @max(held.width, held.height)));
}

/// Give the picture `handle` names its own say over compression and size -
/// what its import settings say now - and make it again with them, from its
/// file, the one there drawn until it is.
pub fn applyTextureSettings(self: *Assets, handle: TextureHandle, settings: TextureSettings) void {
    const held = self.get(handle) orelse return;
    held.compress = settings.compress();
    held.max_size = settings.maxSize();
    if (!held.mips or held.upside_down or held.source.len == 0) return;
    held.regrow = true;
    held.mips_asked = false;
    self.wantMips(handle);
}

/// Every picture with a chain and a file made again as it would be now.
fn remakeChains(self: *Assets) void {
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        const held = entry.value;
        if (!held.mips or held.upside_down or held.source.len == 0) continue;
        held.regrow = true;
        held.mips_asked = false;
        self.wantMips(.fromId(entry.handle));
    }
}

/// Only asset creation, mutation and destruction search this table; rendering
/// still resolves a handle directly. Sampler state and source paths belong to
/// the logical asset, not to the shared RHI image. No decoded CPU copy is kept.
fn identicalTexture(self: *Assets, width: u32, height: u32, mips: bool, fingerprint: [32]u8) ?rhi.Texture {
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        const held = entry.value;
        if (!held.upside_down and held.width == width and held.height == height and held.mips == mips) {
            if (held.fingerprint) |key| if (std.mem.eql(u8, &key, &fingerprint)) return held.gpu;
        }
    }
    return null;
}

fn sharedTexture(self: *Assets, gpu: rhi.Texture, except: ?*Texture) bool {
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        if (entry.value != except and std.meta.eql(entry.value.gpu, gpu)) return true;
    }
    return false;
}

fn releaseTexture(self: *Assets, gpu: rhi.Texture, except: ?*Texture) void {
    if (!gpu.isNone() and !self.sharedTexture(gpu, except)) self.device.destroyTexture(gpu);
}

/// Owned RGBA asset storage, including mip levels. Driver heaps, render
/// targets outside Assets and other applications are not included.
pub const TextureMemory = struct {
    logical_textures: usize = 0,
    resident_textures: usize = 0,
    logical_bytes: u64 = 0,
    resident_bytes: u64 = 0,
};

/// A diagnostic snapshot, requested explicitly rather than in the draw loop.
pub fn textureMemory(self: *Assets) TextureMemory {
    var out: TextureMemory = .{};
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        const held = entry.value;
        var bytes: u64 = 0;
        var w = held.width;
        var h = held.height;
        while (true) {
            bytes += held.format.imageBytes(w, h);
            if (!held.mips or (w == 1 and h == 1)) break;
            w = @max(w / 2, 1);
            h = @max(h / 2, 1);
        }
        out.logical_textures += 1;
        out.logical_bytes += bytes;
        var earlier = self.textures.iterator();
        var duplicate = false;
        while (earlier.next()) |other| {
            if (other.value == held) break;
            if (std.meta.eql(other.value.gpu, held.gpu)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            out.resident_textures += 1;
            out.resident_bytes += bytes;
        }
    }
    return out;
}

/// Every level below the first, made from it on the GPU. Between frames:
/// a submit of its own.
fn fillMips(self: *Assets, gpu: rhi.Texture) Error!void {
    const list = self.device.begin();
    try list.generateMips(gpu);
    try self.device.submit();
}

/// Ask for a chain of levels below `handle`'s picture, if it has none: what
/// the 3D renderer asks of a surface's pictures. Made before the next frame
/// is drawn (`makeWantedMips`), from its file read again; one made from
/// pixels in memory, or drawn into, keeps the one level it has. Asked once.
pub fn wantMips(self: *Assets, handle: TextureHandle) void {
    const held = self.textures.get(handle.toId()) orelse return;
    if (held.mips_asked) return;
    held.mips_asked = true;
    self.mips_wanted.append(self.gpa, handle) catch {};
}

/// The chains `wantMips` asked for, each texture made again under its
/// handle with its levels. Between frames, as the engine does before it
/// draws one.
///
/// Reading and decoding a picture's file again takes milliseconds, and a
/// turn of the camera asks for dozens: a thread of its own does that
/// (`mip_maker.zig`), and here only what is ready is given to the device,
/// a few a frame within `mips_time_a_frame`, so no frame waits for a file.
/// A picture keeps its one level a few frames longer.
pub fn makeWantedMips(self: *Assets) void {
    const io = self.io orelse {
        // Nothing to read with: none can be made again.
        self.mips_wanted.clearRetainingCapacity();
        return;
    };
    if (self.mips_wanted.items.len > 0) {
        if (self.mip_maker == null) self.mip_maker = .init(self.gpa, io, self.project.files(), picture_limit);
        for (self.mips_wanted.items) |handle| {
            const held = self.textures.get(handle.toId()) orelse continue;
            if ((held.mips and !held.regrow) or held.upside_down or held.source.len == 0) continue;
            const recipe = self.recipeOf(.{ .mips = true, .role = held.role, .compress = held.compress, .max_size = held.max_size });
            self.mip_maker.?.ask(.{ .handle = handle, .revision = held.revision, .recipe = recipe }, held.source) catch {};
        }
        self.mips_wanted.clearRetainingCapacity();
    }
    const maker = &(self.mip_maker orelse return);
    // Decoding is off this thread; uploads are bounded in bytes as well
    // as time. A large picture must not spend its whole upload in one frame.
    const began = std.Io.Timestamp.now(io, .awake);
    var given: usize = 0;
    while (given < mips_a_frame) : (given += 1) {
        if (self.mip_upload == null) {
            var made = maker.take() orelse break;
            defer made.deinit(self.gpa);
            self.beginMips(&made) catch |err| {
                log.warn("the levels of a texture were not made: {t}", .{err});
                continue;
            };
            // Allocating a large replacement may itself take the budget.
            // Its first upload can wait for the following frame.
            if (began.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds > mips_time_a_frame) break;
        }
        self.advanceMips() catch |err| {
            if (self.mip_upload) |*upload| upload.deinit(self);
            self.mip_upload = null;
            log.warn("the levels of a texture were not made: {t}", .{err});
        };
        if (began.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds > mips_time_a_frame) break;
    }
}

/// At most four uploads and a millisecond and a half of CPU time per frame.
/// One row is the minimum, even for a texture wider than the byte budget.
pub const mips_a_frame = 4;
pub const mips_time_a_frame = 1_500_000;
pub const mips_bytes_an_upload = 1024 * 1024;

/// Whether every chain asked for has been made: for a test, or a tool that
/// waits for the picture to settle.
pub fn mipsPending(self: *Assets) usize {
    return self.mips_wanted.items.len + @as(usize, if (self.mip_upload != null) 1 else 0) + if (self.mip_maker) |*maker| maker.pending() else 0;
}

fn beginMips(self: *Assets, made: *mip_maker_table.MipMaker(MipRequest).Made) !void {
    const chain = made.chain orelse return;
    const held = self.textures.get(made.handle.handle.toId()) orelse return;
    if ((held.mips and !held.regrow) or held.upside_down or held.source.len == 0 or held.revision != made.handle.revision) return;
    const gpu = try self.device.createTexture(.{
        .width = chain.width,
        .height = chain.height,
        .format = chain.format,
        .mip_levels = chain.levelCount(self.device),
        .label = held.source,
    });
    self.mip_upload = .{ .handle = made.handle.handle, .before = held.gpu, .revision = held.revision, .gpu = gpu, .chain = chain };
    made.chain = null;
}

/// Another share of the chain on its way: a level, or the rows of one that
/// fit `mips_bytes_an_upload` - and the texture in its place once all are.
fn advanceMips(self: *Assets) !void {
    const upload = if (self.mip_upload) |*held| held else return;
    const held = self.textures.get(upload.handle.toId());
    // An unload or reload while the replacement was on its way wins.
    if (held == null or held.?.revision != upload.revision or !std.meta.eql(held.?.gpu, upload.before)) {
        upload.deinit(self);
        self.mip_upload = null;
        return;
    }
    const chain = &upload.chain;
    if (upload.level < chain.levels.len) {
        const lw = rhi.mipExtent(chain.width, upload.level);
        const lh = rhi.mipExtent(chain.height, upload.level);
        const row_bytes = chain.format.rowBytes(lw);
        const all_rows = chain.format.rowCount(lh);
        const rows: u32 = @intCast(@min(all_rows - upload.row, @max(1, mips_bytes_an_upload / row_bytes)));
        const tall = chain.format.info().block_height;
        const top = upload.row * tall;
        try self.device.writeTexture(upload.gpu, .{ .mip = upload.level, .y = top, .width = lw, .height = @min(rows * tall, lh - top) }, chain.levels[upload.level][@as(usize, upload.row) * row_bytes ..][0 .. rows * row_bytes], row_bytes, 0);
        upload.row += rows;
        if (upload.row < all_rows) return;
        upload.level += 1;
        upload.row = 0;
        if (upload.level < chain.levels.len) return;
    }
    const mips = chain.mips(self.device);
    if (chain.format == .rgba8_unorm and mips) try self.fillMips(upload.gpu);
    const gpu = self.identicalTexture(chain.width, chain.height, mips, chain.fingerprint) orelse upload.gpu;
    if (!std.meta.eql(gpu, held.?.gpu)) self.releaseTexture(held.?.gpu, held.?);
    if (!std.meta.eql(gpu, upload.gpu)) self.device.destroyTexture(upload.gpu);
    held.?.gpu = gpu;
    held.?.width = chain.width;
    held.?.height = chain.height;
    held.?.mips = mips;
    held.?.format = chain.format;
    held.?.fingerprint = chain.fingerprint;
    held.?.limited = chain.limited;
    held.?.regrow = false;
    upload.gpu = .none;
    upload.deinit(self);
    self.mip_upload = null;
}

/// A texture to draw into, `width` by `height` and cleared: what a
/// `RenderView` draws its picture in. `clear` is the colour it is mostly
/// cleared to (see `rhi.TextureDesc.clear_color`). `upside_down` is whether
/// the backend counts its rows from the bottom, so that what shows it turns
/// it over.
pub fn addRenderTexture(self: *Assets, width: u32, height: u32, filter: rhi.Filter, clear: [4]f32, upside_down: bool, label: []const u8) Error!TextureHandle {
    const gpu = try self.device.createTexture(.{
        .width = @max(width, 1),
        .height = @max(height, 1),
        .usage = .{ .sampled = true, .render_target = true },
        .clear_color = clear,
        .label = label,
    });
    errdefer self.device.destroyTexture(gpu);
    return .fromId(try self.textures.add(self.gpa, .{
        .gpu = gpu,
        .width = @max(width, 1),
        .height = @max(height, 1),
        .filter = filter,
        .wrap = .clamp_to_edge,
        .upside_down = upside_down,
    }));
}

/// Make a texture to draw into `width` by `height`, if it is not: its
/// handle stays, and what it held is gone.
pub fn resizeRenderTexture(self: *Assets, handle: TextureHandle, width: u32, height: u32, filter: rhi.Filter, clear: [4]f32) Error!void {
    const texture = self.textures.get(handle.toId()) orelse return;
    texture.filter = filter;
    if (texture.width == @max(width, 1) and texture.height == @max(height, 1)) return;
    const gpu = try self.device.createTexture(.{
        .width = @max(width, 1),
        .height = @max(height, 1),
        .usage = .{ .sampled = true, .render_target = true },
        .clear_color = clear,
        .label = "render view",
    });
    self.device.destroyTexture(texture.gpu);
    texture.gpu = gpu;
    texture.width = @max(width, 1);
    texture.height = @max(height, 1);
}

/// A texture from a PNG or a JPEG - which, its first bytes say, not its
/// name: `res://art/hero.png`, `uid://...`, or the operating system's path.
/// Loading twice makes independent handles; identical pixels and mip layouts
/// share device storage until a write. Use `findTexture` to share a handle.
pub fn loadTexture(self: *Assets, path: []const u8, options: LoadOptions) !TextureHandle {
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    const bytes = try self.project.readFileAlloc(self.gpa, source, .limited(picture_limit));
    defer self.gpa.free(bytes);

    var decoded = try image.decode(self.gpa, bytes);
    defer decoded.deinit(self.gpa);
    self.learnUid(source);
    // A 3D surface's picture as its own import settings say, where the one
    // loading it does not.
    const own: TextureSettings = if (options.mips and self.project.io != null) .of(self.gpa, self.project.files(), source) else .{};

    return self.addTexture(
        decoded.width,
        decoded.height,
        decoded.pixels,
        .{
            .filter = options.filter orelse self.default_filter,
            .wrap = options.wrap,
            .label = if (options.label.len == 0) source else options.label,
            .mips = options.mips,
            .role = options.role,
            .compress = options.compress orelse own.compress(),
            .max_size = options.max_size orelse own.maxSize(),
        },
        source,
    );
}

/// A texture read and decoded elsewhere - a scene loading in the background
/// - made under the file it came from, so what names that file finds it.
pub fn adoptTexture(self: *Assets, path: []const u8, width: u32, height: u32, rgba: []const u8, options: LoadOptions) !TextureHandle {
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    self.learnUidRead(source, options.uid);
    // A file's own import settings; a model's picture has its model's.
    const own: TextureSettings = if (options.mips and self.project.io != null and std.mem.indexOfScalar(u8, source, '#') == null) .of(self.gpa, self.project.files(), source) else .{};
    return self.addTexture(width, height, rgba, .{
        .filter = options.filter orelse self.default_filter,
        .wrap = options.wrap,
        .label = if (options.label.len == 0) source else options.label,
        .mips = options.mips,
        .role = options.role,
        .compress = options.compress orelse own.compress(),
        .max_size = options.max_size orelse own.maxSize(),
    }, source);
}

/// Give a texture new pixels, `width` by `height`, top row first: written in
/// place for a private picture of the same size; a shared picture detaches
/// before a write. Another size is made anew under the same handle -
/// and its chain of levels, if it has one, made again from them.
pub fn setTexturePixels(self: *Assets, handle: TextureHandle, width: u32, height: u32, rgba: []const u8) !void {
    const held = self.get(handle) orelse return error.NoSuchTexture;
    if (!held.mips and held.width == width and held.height == height and !held.upside_down and !self.sharedTexture(held.gpu, held)) {
        held.fingerprint = null;
        held.revision +%= 1;
        try self.device.updateTexture(held.gpu, rgba, 0);
        if (held.mips) try self.fillMips(held.gpu);
        var fingerprint: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rgba, &fingerprint, .{});
        held.fingerprint = fingerprint;
        return;
    }
    const made = try self.makeTexture(width, height, rgba, held.source, .{ .mips = held.mips, .role = held.role, .compress = held.compress, .max_size = held.max_size });
    if (!std.meta.eql(made.gpu, held.gpu)) self.releaseTexture(held.gpu, held);
    held.gpu = made.gpu;
    held.width = made.width;
    held.height = made.height;
    held.upside_down = false;
    held.mips = made.mips;
    held.format = made.format;
    held.fingerprint = made.fingerprint;
    held.limited = made.limited;
    held.regrow = false;
    held.revision +%= 1;
}

/// The texture already read from `path`, if one was: the same file, however
/// either was spelt - `res://art/a.png`, `art/a.png` from the root, its
/// absolute path.
pub fn findTexture(self: *Assets, path: []const u8) ?TextureHandle {
    const named = self.project.canonical(self.gpa, path) catch null;
    defer if (named) |text| self.gpa.free(text);
    const wanted = named orelse path;
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value.source, wanted)) return .fromId(entry.handle);
    }
    return null;
}

/// Remember the UUID beside a project's file, for the scene that names it.
/// A `.uid` file that does not read is said so, and the file loads without.
fn learnUid(self: *Assets, source: []const u8) void {
    self.learnUidRead(source, .unknown);
}

/// `learnUid`, from what a loading thread read where it read one.
fn learnUidRead(self: *Assets, source: []const u8, read: Project.UidRead) void {
    if (!Project.isProjectPath(source) or Project.isPart(source)) return;
    self.project.learnUid(source, read) catch |err| {
        log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
    };
}

/// Give every file of the project's that is loaded, and has no UUID, one -
/// in a `.uid` file beside it. Saving a scene does it, so the scene can name
/// its files by their UUIDs.
pub fn ensureUids(self: *Assets) !void {
    var textures = self.textures.iterator();
    while (textures.next()) |entry| {
        const source = entry.value.source;
        if (Project.isProjectPath(source) and !Project.isPart(source)) _ = try self.project.ensureUid(source);
    }
    var faces = self.fonts.iterator();
    while (faces.next()) |entry| {
        if (Project.isProjectPath(entry.value.*.source)) _ = try self.project.ensureUid(entry.value.*.source);
    }
}

/// Open a font from bytes in memory. The bytes are copied, because the
/// parsed font keeps views into them.
pub fn fontFromBytes(self: *Assets, bytes: []const u8, options: FontOptions) !FontHandle {
    return self.addFont(bytes, options, "");
}

/// Takes `source`, which is freed with the font.
fn addFont(self: *Assets, bytes: []const u8, options: FontOptions, source: []const u8) !FontHandle {
    const owned = try self.gpa.dupe(u8, bytes);
    errdefer self.gpa.free(owned);

    const face: typeface.Font = try .initMember(owned, options.member);

    var atlas: Atlas = try .init(self.gpa, options.atlas, options.atlas);
    errdefer atlas.deinit();

    const texture = try self.device.createTexture(.{
        .width = options.atlas,
        .height = options.atlas,
        .data = atlas.pixels,
        .label = if (options.label.len == 0) "glyphs" else options.label,
    });
    errdefer self.device.destroyTexture(texture);

    const font = try self.gpa.create(Font);
    errdefer self.gpa.destroy(font);
    font.* = .{
        .face = face,
        .bytes = owned,
        .atlas = atlas,
        .texture = texture,
        .source = source,
        .member = options.member,
    };

    const handle: FontHandle = .fromId(try self.fonts.add(self.gpa, font));

    if (self.default_font.isNone()) self.default_font = handle;
    return handle;
}

/// A fixed guess at the operating system's interface font: one path per
/// platform, for a caller with no `Assets` at hand. On Linux, the first of a
/// few common places that is there: DejaVu Sans where Debian, Fedora and Arch
/// put it, then Liberation Sans. `loadSystemFont` asks the system instead,
/// and is right where this is not - a Japanese Windows, a Linux with neither
/// font. A game that ships carries its own.
pub fn systemFontPath() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/segoeui.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        .linux => for (linux_font_paths) |path| {
            if (std.os.linux.access(path, std.posix.F_OK) == 0) break path;
        } else linux_font_paths[0],
        else => linux_font_paths[0],
    };
}

const linux_font_paths = [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf",
};

/// Open the font the system's own dialogs use, as the system names it: the
/// message font on Windows - Segoe UI, and Yu Gothic UI on Japanese Windows,
/// which is the second font of a collection - what fontconfig makes of
/// sans-serif on Linux, and Roboto on Android. `options.member` is replaced by
/// the system's answer. For an editor's interface, or a game's debug text; a
/// game's own words are set in a font it ships.
///
/// With `options.mono`, the monospaced one instead: Cascadia Mono or Consolas
/// on Windows, fontconfig's monospace on Linux, Menlo on a Mac, Droid Sans
/// Mono on Android - for a code editor, or a console.
pub fn loadSystemFont(self: *Assets, options: FontOptions) !FontHandle {
    const io = self.io orelse return Error.NoIo;
    const found = if (options.mono) try platform.fonts.systemMono(self.gpa, io) else try platform.fonts.systemUi(self.gpa, io);
    defer found.deinit(self.gpa);
    var asked = options;
    asked.member = found.index;
    return self.loadFont(found.path, asked);
}

/// The most fonts text falls back on.
pub const max_fallback_fonts = 4;

/// Open the system's emoji fonts - Segoe UI Emoji on Windows, Noto Color
/// Emoji and its flags on a phone, what fontconfig names on Linux, what a
/// page put in its files in a browser - for every text to fall back on: an
/// emoji in a game's words, or in the editor's fields, is drawn in colour
/// from them. A font that will not open is said in the log and passed over;
/// none at all is not an error. Opened after the default font, which they
/// never become.
pub fn loadEmojiFonts(self: *Assets) !void {
    const io = self.io orelse return Error.NoIo;
    const faces = platform.fonts.systemEmoji(self.gpa, io) catch |err| switch (err) {
        error.Unsupported => return,
        else => return err,
    };
    defer platform.fonts.freeAll(self.gpa, faces);
    const default = self.default_font;
    defer self.default_font = default;
    for (faces) |face| {
        if (self.fallback_count == max_fallback_fonts) break;
        const handle = self.loadFont(face.path, .{ .member = face.index, .label = "emoji" }) catch |err| {
            std.log.scoped(.fluxion_engine).warn("the emoji font {s} does not open: {s}", .{ face.path, @errorName(err) });
            continue;
        };
        self.fallback_fonts[self.fallback_count] = handle;
        self.fallback_count += 1;
    }
}

/// The fonts text falls back on, in `out`, as they are now: one that has
/// been let go of is left out.
pub fn fallbacks(self: *Assets, out: *[max_fallback_fonts]*Font) []*Font {
    var held: usize = 0;
    for (self.fallback_fonts[0..self.fallback_count]) |handle| {
        const found = self.fonts.get(handle.toId()) orelse continue;
        out[held] = found.*;
        held += 1;
    }
    return out[0..held];
}

/// Open a TrueType file from the disc, named as `loadTexture` names one - or
/// one font of a collection, by `options.member`.
pub fn loadFont(self: *Assets, path: []const u8, options: FontOptions) !FontHandle {
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    const bytes = try self.project.readFileAlloc(self.gpa, source, .limited(font_limit));
    defer self.gpa.free(bytes);
    self.learnUid(source);

    return self.addFont(bytes, .{
        .atlas = options.atlas,
        .label = if (options.label.len == 0) source else options.label,
        .member = options.member,
    }, source);
}

/// A font of a file read already - by a background load - kept by `path`,
/// as `loadFont` keeps it.
pub fn adoptFont(self: *Assets, path: []const u8, bytes: []const u8, options: FontOptions) !FontHandle {
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    self.learnUid(source);
    return self.addFont(bytes, .{
        .atlas = options.atlas,
        .label = if (options.label.len == 0) source else options.label,
        .member = options.member,
    }, source);
}

/// The font already read from `path`, if one was: the first font of the
/// file, as `loadFont` opens one by default. See `findTexture`, and
/// `findFontMember` for another font of a collection.
pub fn findFont(self: *Assets, path: []const u8) ?FontHandle {
    return self.findFontMember(path, 0);
}

/// The font already read from `path` at this place in it.
pub fn findFontMember(self: *Assets, path: []const u8, member: u32) ?FontHandle {
    const named = self.project.canonical(self.gpa, path) catch null;
    defer if (named) |text| self.gpa.free(text);
    const wanted = named orelse path;
    var it = self.fonts.iterator();
    while (it.next()) |entry| {
        const font = entry.value.*;
        if (font.member == member and std.mem.eql(u8, font.source, wanted)) return .fromId(entry.handle);
    }
    return null;
}

/// The file a font handle's font was read from. Null for `.none`, for an
/// expired handle, and for a font opened from bytes.
pub fn fontSource(self: *Assets, handle: FontHandle) ?[]const u8 {
    const font = self.fonts.get(handle.toId()) orelse return null;
    return if (font.*.source.len == 0) null else font.*.source;
}

/// Which font of its file a font handle's font is: nought for a file that is
/// one font, for `.none`, and for an expired handle.
pub fn fontMember(self: *Assets, handle: FontHandle) u32 {
    const font = self.fonts.get(handle.toId()) orelse return 0;
    return font.*.member;
}

/// What a font handle points at, or the default font when it points at
/// nothing. Null only when there is no font at all.
pub fn fontOf(self: *Assets, handle: FontHandle) ?*Font {
    if (self.fonts.get(handle.toId())) |found| return found.*;
    if (handle.isNone() and !self.default_font.isNone()) {
        const default = self.fonts.get(self.default_font.toId()) orelse return null;
        return default.*;
    }
    return null;
}

/// The biggest side a font's atlas grows to.
pub const max_atlas: u32 = 4096;

/// The biggest size, in whole pixels, a glyph is drawn into an atlas at:
/// bigger text is these glyphs scaled up.
pub const max_glyph: u16 = 512;

/// `font`'s atlas twice as big and blank, with a texture to match: what a
/// frame whose letters do not fit an emptied atlas asks for. False once it
/// is `max_atlas` a side, or as big as the device's textures go.
pub fn growAtlas(self: *Assets, font: *Font) !bool {
    const most = @min(max_atlas, self.device.caps().limits.max_texture_2d);
    const now = @max(font.atlas.width, font.atlas.height);
    if (now >= most) return false;
    const side = @min(now * 2, most);
    var atlas: Atlas = try .init(self.gpa, side, side);
    errdefer atlas.deinit();
    const texture = try self.device.createTexture(.{ .width = side, .height = side, .data = atlas.pixels, .label = "glyphs" });
    self.device.destroyTexture(font.texture);
    font.atlas.deinit();
    font.atlas = atlas;
    font.texture = texture;
    return true;
}

/// Upload every atlas that grew since the last frame. The whole image, which
/// is cheap at this size, and a settled game uploads nothing.
pub fn flushFonts(self: *Assets) !void {
    var it = self.fonts.iterator();
    while (it.next()) |entry| {
        const font = entry.value.*;
        if (!font.atlas.dirty) continue;
        try self.device.updateTexture(font.texture, font.atlas.pixels, font.atlas.rowPitch());
        font.atlas.markClean();
    }
}

/// Read a texture's file again, in place: the handle stays, so every sprite
/// and field holding it shows the new pixels, at the new size when the size
/// changed. Says whether there was a file to read - not for an expired
/// handle, nor for a texture made from pixels. A file that no longer reads
/// is an error, and the texture keeps what it had.
pub fn reloadTexture(self: *Assets, handle: TextureHandle) !bool {
    const texture = self.textures.get(handle.toId()) orelse return false;
    if (texture.source.len == 0) return false;
    const bytes = try self.project.readFileAlloc(self.gpa, texture.source, .limited(picture_limit));
    defer self.gpa.free(bytes);

    var decoded = try image.decode(self.gpa, bytes);
    defer decoded.deinit(self.gpa);

    try self.setTexturePixels(handle, decoded.width, decoded.height, decoded.pixels);
    return true;
}

/// Read a font's file again, in place: the handle and the font's address
/// stay, and the glyphs drawn so far go, to be drawn again from the new
/// face. Says whether there was a file to read, as `reloadTexture` does.
pub fn reloadFont(self: *Assets, handle: FontHandle) !bool {
    const font = (self.fonts.get(handle.toId()) orelse return false).*;
    if (font.source.len == 0) return false;
    // Read into memory the font keeps, since the face holds views into it.
    const bytes = try self.project.readFileAlloc(self.gpa, font.source, .limited(font_limit));
    errdefer self.gpa.free(bytes);
    const face: typeface.Font = try .initMember(bytes, font.member);
    var atlas: Atlas = try .init(self.gpa, font.atlas.width, font.atlas.height);
    // Blank, and uploaded so at the next flush: the old glyphs leave the
    // texture as well as the table.
    atlas.dirty = true;

    // Nothing can fail from here, so the font is never half the old one.
    font.atlas.deinit();
    self.gpa.free(font.bytes);
    font.face = face;
    font.bytes = bytes;
    font.atlas = atlas;
    self.font_reloads +%= 1;
    return true;
}

/// Read again everything read from `path`, however either was spelt: every
/// texture and every font. What a tool calls when a file changed on the disc.
/// Says whether anything had been read from it. Stops at the first that
/// fails to read, as the rest would.
pub fn reloadFile(self: *Assets, path: []const u8) !bool {
    const named = self.project.canonical(self.gpa, path) catch null;
    defer if (named) |text| self.gpa.free(text);
    const wanted = named orelse path;

    var any = false;
    var textures = self.textures.iterator();
    while (textures.next()) |entry| {
        if (!std.mem.eql(u8, entry.value.source, wanted)) continue;
        if (try self.reloadTexture(.fromId(entry.handle))) any = true;
    }
    var faces = self.fonts.iterator();
    while (faces.next()) |entry| {
        if (!std.mem.eql(u8, entry.value.*.source, wanted)) continue;
        if (try self.reloadFont(.fromId(entry.handle))) any = true;
    }
    return any;
}

/// That the file or folder at `old` is at `new` now, both as
/// `Project.canonical` names them: what was read from it is kept by where it
/// is, so it is found there, and a scene saved next names the new place.
pub fn renamed(self: *Assets, old: []const u8, new: []const u8) Allocator.Error!void {
    var textures = self.textures.iterator();
    while (textures.next()) |entry| try self.moveSource(&entry.value.source, old, new);
    var faces = self.fonts.iterator();
    while (faces.next()) |entry| try self.moveSource(&entry.value.*.source, old, new);
}

fn moveSource(self: *Assets, source: *[]const u8, old: []const u8, new: []const u8) Allocator.Error!void {
    if (source.*.len == 0) return;
    const rest = Project.under(source.*, old) orelse return;
    const moved = try std.mem.concat(self.gpa, u8, &.{ new, rest });
    // In the separators its kind of path is kept in: `/` in a project's, the
    // system's own in the system's.
    if (std.fs.path.sep != '/') {
        if (Project.isProjectPath(moved))
            std.mem.replaceScalar(u8, moved, std.fs.path.sep, '/')
        else
            std.mem.replaceScalar(u8, moved, '/', std.fs.path.sep);
    }
    self.gpa.free(source.*);
    source.* = moved;
}

/// Give a texture back to the driver. Every handle to it stops resolving.
pub fn unload(self: *Assets, handle: TextureHandle) void {
    if (self.textures.remove(handle.toId())) |texture| {
        self.releaseTexture(texture.gpu, null);
        self.gpa.free(texture.source);
    }
}

/// The file a texture handle's texture was read from. Null for `.none`,
/// for an expired handle, and for a texture made from pixels.
pub fn textureSource(self: *Assets, handle: TextureHandle) ?[]const u8 {
    const texture = self.textures.get(handle.toId()) orelse return null;
    return if (texture.source.len == 0) null else texture.source;
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
pub fn samplerFor(self: *const Assets, filter: rhi.Filter, wrap: rhi.Wrap) rhi.Sampler {
    return self.samplers.get(filter).get(wrap);
}

/// The same, reading between the levels of a chain with `filter` too: for
/// a texture with `mips`, and harmless for one without.
pub fn mipSamplerFor(self: *const Assets, filter: rhi.Filter, wrap: rhi.Wrap) rhi.Sampler {
    return self.mip_samplers.get(filter).get(wrap);
}

/// How many textures are loaded, not counting the white texel and the glow.
pub fn count(self: *const Assets) usize {
    return self.textures.count() -| 2;
}

test "a handle stops resolving when what it named is unloaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
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

test "there is a white texel and a glow before anything is loaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    try testing.expect(!assets.white.isNone());
    try testing.expect(!assets.glow.isNone());
    try testing.expectEqual(@as(usize, 0), assets.count());
}

test "the first font opened becomes the default" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    try testing.expect(assets.default_font.isNone());
    try testing.expect(assets.fontOf(.none) == null);
}

test "a font keeps its address when more are loaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const first = assets.loadFont(systemFontPath(), .{ .atlas = 64 }) catch return error.SkipZigTest;
    const face = &assets.fontOf(first).?.face;
    for (0..8) |_| _ = try assets.loadFont(systemFontPath(), .{ .atlas = 64 });

    try testing.expectEqual(face, &assets.fontOf(first).?.face);
}

/// A TrueType collection the system has, by its path, or null: Yu Gothic
/// beside Yu Gothic UI on Windows, the Noto CJK fonts on a Linux box.
fn systemCollection() ?[]const u8 {
    const candidates = [_][]const u8{
        "C:/Windows/Fonts/YuGothM.ttc",
        "C:/Windows/Fonts/cambria.ttc",
        "C:/Windows/Fonts/msgothic.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(testing.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

test "a font of a collection is opened at its place, found by it, and read again at it" {
    const path = systemCollection() orelse return error.SkipZigTest;
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const first = try assets.loadFont(path, .{ .atlas = 64 });
    const second = try assets.loadFont(path, .{ .atlas = 64, .member = 1 });
    try testing.expectEqual(@as(u32, 0), assets.fontMember(first));
    try testing.expectEqual(@as(u32, 1), assets.fontMember(second));
    const at = assets.fontOf(second).?.face.file.directory_at;
    try testing.expect(assets.fontOf(first).?.face.file.directory_at != at);

    try testing.expectEqual(first, assets.findFont(path).?);
    try testing.expectEqual(second, assets.findFontMember(path, 1).?);
    try testing.expect(assets.findFontMember(path, 2) == null);

    // Read again, it is the same font of the file, not the first.
    try testing.expect(try assets.reloadFont(second));
    try testing.expectEqual(at, assets.fontOf(second).?.face.file.directory_at);

    // A place the file has not got is refused rather than read as another.
    try testing.expectError(error.OutOfBounds, assets.loadFont(path, .{ .atlas = 64, .member = 1000 }));
}

test "the system's own interface font is the one the system names" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const handle = assets.loadSystemFont(.{ .atlas = 64 }) catch return error.SkipZigTest;
    try testing.expect(assets.fontSource(handle) != null);
    try testing.expect(assets.fontOf(handle).?.face.has('A'));
}

test "the system's monospaced font gives every letter the same width" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const mono = assets.loadSystemFont(.{ .atlas = 64, .mono = true }) catch return error.SkipZigTest;
    const plain = assets.loadSystemFont(.{ .atlas = 64 }) catch return error.SkipZigTest;
    try testing.expect(!std.mem.eql(u8, assets.fontSource(mono).?, assets.fontSource(plain).?));

    // What makes it monospaced: a narrow letter is as wide as a wide one,
    // which in the interface font it is not.
    const code = assets.fontOf(mono).?.face.at(16);
    try testing.expectApproxEqAbs(try code.measure("iiii"), try code.measure("WWWW"), 0.01);
    const words = assets.fontOf(plain).?.face.at(16);
    try testing.expect(try words.measure("iiii") < try words.measure("WWWW"));
}

test "every filter and wrap has a sampler of its own" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    const tile = try assets.textureFromPixels(1, 1, &.{ 255, 255, 255, 255 }, .{ .wrap = .repeat });
    try testing.expectEqual(rhi.Wrap.repeat, assets.get(tile).?.wrap);
    try testing.expect(!std.meta.eql(assets.samplerFor(.nearest, .repeat), assets.samplerFor(.nearest, .clamp_to_edge)));
    try testing.expect(!std.meta.eql(assets.samplerFor(.nearest, .repeat), assets.samplerFor(.linear, .repeat)));
}

test "reading a file without an Io says so rather than crashing" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    try testing.expectError(Error.NoIo, assets.loadTexture("nothing.png", .{}));
}

test "a file inside the project is kept by its res:// path, and found by any spelling of it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "art");
    var png_buffer: [160]u8 = undefined;
    const png = try std.fmt.bufPrint(&png_buffer, "{s}/art/hero.png", .{root});
    try image.png.writeFile(testing.allocator, testing.io, png, .{ .width = 1, .height = 1, .pixels = &.{ 255, 255, 255, 255 }, .row_pitch = 4 }, .{});

    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, testing.io, root);
    defer project.deinit();
    const uid = try project.ensureUid("res://art/hero.png");

    // Another run, which learns the UUID from the file beside the texture.
    var fresh: Project = try .init(testing.allocator, testing.io, root);
    defer fresh.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &fresh);
    defer assets.deinit();

    const hero = try assets.loadTexture(png, .{});
    try testing.expectEqualStrings("res://art/hero.png", assets.textureSource(hero).?);
    try testing.expect(fresh.knownUid("res://art/hero.png").?.eql(uid));

    try testing.expect(assets.findTexture("res://art/hero.png").?.eql(hero));
    try testing.expect(assets.findTexture("res://art/./hero.png").?.eql(hero));
    try testing.expect(assets.findTexture(png).?.eql(hero));
    var by_uid: [64]u8 = undefined;
    try testing.expect(assets.findTexture(try std.fmt.bufPrint(&by_uid, "uid://{f}", .{uid})).?.eql(hero));
    try testing.expect(assets.findTexture("res://art/villain.png") == null);
}

test "a JPEG is a texture as a PNG is, and a picture is read by what it is, not by its name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // Six by four, all one red, as Pillow writes it.
    const photo = [_]u8{
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43, 0x00, 0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02,
        0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x04, 0x03, 0x02, 0x02, 0x02, 0x02, 0x05, 0x04,
        0x04, 0x03, 0x04, 0x06, 0x05, 0x06, 0x06, 0x06, 0x05, 0x06, 0x06, 0x06, 0x07, 0x09, 0x08, 0x06,
        0x07, 0x09, 0x07, 0x06, 0x06, 0x08, 0x0b, 0x08, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x06, 0x08,
        0x0b, 0x0c, 0x0b, 0x0a, 0x0c, 0x09, 0x0a, 0x0a, 0x0a, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x02, 0x02,
        0x02, 0x02, 0x02, 0x02, 0x05, 0x03, 0x03, 0x05, 0x0a, 0x07, 0x06, 0x07, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0xff, 0xc0,
        0x00, 0x11, 0x08, 0x00, 0x04, 0x00, 0x06, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
        0x01, 0xff, 0xc4, 0x00, 0x1f, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05,
        0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7d, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21,
        0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23,
        0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a,
        0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,
        0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
        0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
        0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
        0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5,
        0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1,
        0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xff, 0xc4, 0x00, 0x1f, 0x01, 0x00, 0x03,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x11, 0x00,
        0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, 0x00,
        0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13,
        0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15,
        0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27,
        0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88,
        0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6,
        0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4,
        0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9,
        0xfa, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00, 0xf9,
        0x7e, 0xbf, 0x13, 0x3f, 0xd4, 0x03, 0xff, 0xd9,
    };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "photo.jpg", .data = &photo });
    var png_buffer: [160]u8 = undefined;
    try writeSolid(try std.fmt.bufPrint(&png_buffer, "{s}/named wrong.jpeg", .{root}), 3, 5, 90);

    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, testing.io, root);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const red = assets.textures.get((try assets.loadTexture("res://photo.jpg", .{})).toId()).?;
    try testing.expectEqual(@as(u32, 6), red.width);
    try testing.expectEqual(@as(u32, 4), red.height);
    const grey = assets.textures.get((try assets.loadTexture("res://named wrong.jpeg", .{})).toId()).?;
    try testing.expectEqual(@as(u32, 3), grey.width);

    try testing.expectEqual(@import("asset_kind.zig").AssetKind.texture, @import("asset_kind.zig").AssetKind.ofPath("res://Photo.JPG").?);
}

/// A PNG of one colour, `width` by `height`, written to `path`.
fn writeSolid(path: []const u8, width: u32, height: u32, grey: u8) !void {
    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * height * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, grey);
    try image.png.writeFile(testing.allocator, testing.io, path, .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .row_pitch = @as(usize, width) * 4,
    }, .{});
}

test "a texture read again keeps its handle and its sampling, at the file's new size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var png_buffer: [160]u8 = undefined;
    const png = try std.fmt.bufPrint(&png_buffer, "{s}/hero.png", .{root});
    // Use a private picture; the built-in white texel is shared.
    try writeSolid(png, 1, 1, 200);

    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, testing.io, root);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const hero = try assets.loadTexture("res://hero.png", .{ .filter = .linear });
    const first = assets.get(hero).?.gpu;

    // The same size: the same texture on the device, filled again.
    try writeSolid(png, 1, 1, 128);
    try testing.expect(try assets.reloadTexture(hero));
    try testing.expect(std.meta.eql(first, assets.get(hero).?.gpu));

    // Another size: another texture on the device, under the same handle -
    // and found by the file's other spelling.
    try writeSolid(png, 2, 3, 64);
    try testing.expect(try assets.reloadFile(png));
    const now = assets.get(hero).?;
    try testing.expectEqual(@as(u32, 2), now.width);
    try testing.expectEqual(@as(u32, 3), now.height);
    try testing.expectEqual(rhi.Filter.linear, now.filter);
    try testing.expectEqual(@as(u32, 3), (try device.textureSize(now.gpu)).height);
    try testing.expectError(error.InvalidHandle, device.textureSize(first));
    try testing.expectEqual(@as(usize, 1), assets.count());
}

test "a texture whose file no longer reads keeps what it had" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var png_buffer: [160]u8 = undefined;
    const png = try std.fmt.bufPrint(&png_buffer, "{s}/hero.png", .{root});
    try writeSolid(png, 2, 2, 255);

    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, testing.io, root);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();
    const hero = try assets.loadTexture(png, .{});

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hero.png", .data = "not a picture" });
    try testing.expect(std.meta.isError(assets.reloadTexture(hero)));
    try testing.expectEqual(@as(u32, 2), assets.get(hero).?.width);
    try testing.expectEqual(@as(u32, 2), (try device.textureSize(assets.get(hero).?.gpu)).width);
}

test "what has no file has nothing to read again" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    const made = try assets.textureFromPixels(1, 1, &(.{255} ** 4), .{});
    try testing.expect(!try assets.reloadTexture(made));
    assets.unload(made);
    try testing.expect(!try assets.reloadTexture(made));
    try testing.expect(!try assets.reloadFont(.none));
    try testing.expect(!try assets.reloadFile("res://nothing.png"));
}

test "a font read again keeps its handle and its address, and draws its glyphs again" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, testing.io, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, testing.io, &project);
    defer assets.deinit();

    const handle = assets.loadFont(systemFontPath(), .{ .atlas = 64 }) catch return error.SkipZigTest;
    const font = assets.fontOf(handle).?;
    _ = try font.atlas.glyph(&font.face, font.face.glyphFor('A'), 16);
    try assets.flushFonts();
    const old_bytes = font.bytes.ptr;

    try testing.expect(try assets.reloadFile(systemFontPath()));
    try testing.expectEqual(font, assets.fontOf(handle).?);
    try testing.expect(font.bytes.ptr != old_bytes);
    try testing.expectEqual(@as(usize, 0), font.atlas.count());
    // Uploaded blank at the next flush, so the old glyphs leave the texture.
    try testing.expect(font.atlas.dirty);
    try testing.expectEqual(@as(u32, 1), assets.font_reloads);
}

test "a large mip replacement stays hidden until complete and a reload cancels it" {
    var device = rhi.Device.init(testing.allocator, .{ .backend = .vulkan }) catch |err| switch (err) {
        error.NoDevice, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer device.deinit();
    if (!device.caps().formatSupport(.rgba8_unorm).generate_mips) return error.SkipZigTest;
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    const handle = try assets.adoptTexture("res://strip.png", 1, 1, &.{ 255, 255, 255, 255 }, .{});
    const before = assets.get(handle).?.gpu;
    const pixels = try testing.allocator.alloc(u8, 1024 * 257 * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 200);
    var made: mip_maker_table.MipMaker(MipRequest).Made = .{ .handle = .{ .handle = handle }, .picture = null, .chain = try makeChain(testing.allocator, 1024, 257, pixels, .{}) };
    defer made.deinit(testing.allocator);
    try assets.beginMips(&made);
    try testing.expect(made.chain == null);
    try assets.advanceMips();
    try testing.expectEqual(@as(u32, 256), assets.mip_upload.?.row);
    try testing.expectEqual(before, assets.get(handle).?.gpu);
    try testing.expect(!assets.get(handle).?.mips);
    try testing.expectEqual(@as(usize, 1), assets.mipsPending());
    try assets.advanceMips();
    try testing.expect(assets.mip_upload == null);
    try testing.expect(assets.get(handle).?.mips);
    const picture = try device.readTexture(assets.get(handle).?.gpu, testing.allocator);
    defer testing.allocator.free(picture);
    for (picture) |byte| try testing.expectEqual(@as(u8, 200), byte);
    try testing.expectEqual(@as(usize, 0), assets.mipsPending());

    const other = try assets.adoptTexture("res://cancel.png", 1, 1, &.{ 1, 2, 3, 4 }, .{});
    const next = [_]u8{100} ** (2 * 2 * 4);
    var cancelled: mip_maker_table.MipMaker(MipRequest).Made = .{ .handle = .{ .handle = other }, .picture = null, .chain = try makeChain(testing.allocator, 2, 2, &next, .{}) };
    defer cancelled.deinit(testing.allocator);
    try assets.beginMips(&cancelled);
    try assets.setTexturePixels(other, 1, 1, &.{ 5, 6, 7, 8 });
    const reloaded = assets.get(other).?.gpu;
    try assets.advanceMips();
    try testing.expect(assets.mip_upload == null);
    try testing.expectEqual(reloaded, assets.get(other).?.gpu);
    try testing.expect(!assets.get(other).?.mips);
}

test "identical pictures share storage but mutation and unload remain independent" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    const pixels = .{ 25, 50, 75, 255 } ** 4;
    const a = try assets.adoptTexture("res://a.png", 2, 2, &pixels, .{ .filter = .nearest });
    const b = try assets.adoptTexture("res://b.png", 2, 2, &pixels, .{ .filter = .linear, .wrap = .repeat });
    try testing.expect(!std.meta.eql(a, b));
    const shared = assets.get(a).?.gpu;
    try testing.expectEqual(shared, assets.get(b).?.gpu);
    try testing.expectEqualStrings("res://b.png", assets.textureSource(b).?);
    try testing.expectEqual(rhi.Filter.linear, assets.get(b).?.filter);
    const memory = assets.textureMemory();
    try testing.expectEqual(memory.logical_bytes - 16, memory.resident_bytes);
    try assets.setTexturePixels(a, 2, 2, &(.{ 1, 2, 3, 255 } ** 4));
    try testing.expect(!std.meta.eql(shared, assets.get(a).?.gpu));
    try testing.expectEqual(shared, assets.get(b).?.gpu);
    assets.unload(a);
    _ = try device.textureSize(shared);
    const c = try assets.adoptTexture("res://c.png", 2, 2, &pixels, .{});
    try testing.expectEqual(shared, assets.get(c).?.gpu);
    assets.unload(b);
    _ = try device.textureSize(shared);
    assets.unload(c);
    try testing.expectError(error.InvalidHandle, device.textureSize(shared));
}

test "shared pictures detach for a resized update and render targets never share" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    const a = try assets.textureFromPixels(2, 2, &(.{ 25, 50, 75, 255 } ** 4), .{});
    const b = try assets.textureFromPixels(2, 2, &(.{ 25, 50, 75, 255 } ** 4), .{});
    const old = assets.get(b).?.gpu;
    try assets.setTexturePixels(a, 1, 1, &.{ 1, 2, 3, 255 });
    try testing.expectEqual(@as(u32, 2), (try device.textureSize(old)).width);
    try testing.expectEqual(@as(u32, 1), assets.get(a).?.width);
    const target1 = try assets.addRenderTexture(2, 2, .linear, .{ 0, 0, 0, 0 }, false, "one");
    const target2 = try assets.addRenderTexture(2, 2, .linear, .{ 0, 0, 0, 0 }, false, "two");
    try testing.expect(!std.meta.eql(assets.get(target1).?.gpu, assets.get(target2).?.gpu));
}

test "shared mipmapped pictures keep the other asset pixels across writes and unload" {
    var device = rhi.Device.init(testing.allocator, .{ .backend = .vulkan }) catch |err| switch (err) {
        error.NoDevice, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer device.deinit();
    if (!device.caps().formatSupport(.rgba8_unorm).generate_mips) return error.SkipZigTest;
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    const red = .{ 255, 0, 0, 255 } ** 4;
    const blue = .{ 0, 0, 255, 255 } ** 4;
    // Four bytes a texel, to be read back.
    assets.texture_compression = false;
    const a = try assets.adoptTexture("res://first.png", 2, 2, &red, .{ .mips = true });
    const b = try assets.adoptTexture("res://second.png", 2, 2, &red, .{ .mips = true });
    const gpu = assets.get(b).?.gpu;
    try testing.expectEqual(gpu, assets.get(a).?.gpu);
    const plain = try assets.textureFromPixels(2, 2, &red, .{});
    try testing.expect(!std.meta.eql(gpu, assets.get(plain).?.gpu));
    try assets.setTexturePixels(a, 2, 2, &blue);
    const red_pixels = try device.readTexture(gpu, testing.allocator);
    defer testing.allocator.free(red_pixels);
    const blue_pixels = try device.readTexture(assets.get(a).?.gpu, testing.allocator);
    defer testing.allocator.free(blue_pixels);
    try testing.expectEqualSlices(u8, &red, red_pixels);
    try testing.expectEqualSlices(u8, &blue, blue_pixels);
    try testing.expect(assets.get(a).?.mips);
    try testing.expect(assets.get(b).?.mips);
    assets.unload(a);
    _ = try device.textureSize(gpu);
}

test "deferred mip upgrades converge on shared storage and preserve one-texel aliases" {
    var device = rhi.Device.init(testing.allocator, .{ .backend = .vulkan }) catch |err| switch (err) {
        error.NoDevice, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer device.deinit();
    if (!device.caps().formatSupport(.rgba8_unorm).generate_mips) return error.SkipZigTest;
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    const pixels = .{ 123, 45, 67, 255 } ** 4;
    const a = try assets.adoptTexture("res://deferred-a.png", 2, 2, &pixels, .{});
    const b = try assets.adoptTexture("res://deferred-b.png", 2, 2, &pixels, .{});
    for ([_]TextureHandle{ a, b }) |handle| {
        var made: mip_maker_table.MipMaker(MipRequest).Made = .{ .handle = .{ .handle = handle }, .picture = null, .chain = try makeChain(testing.allocator, 2, 2, &pixels, .{}) };
        defer made.deinit(testing.allocator);
        try assets.beginMips(&made);
        try assets.advanceMips();
    }
    try testing.expectEqual(assets.get(a).?.gpu, assets.get(b).?.gpu);
    const gpu = assets.get(a).?.gpu;
    assets.unload(b);
    const read = try device.readTexture(gpu, testing.allocator);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, &pixels, read);
    const small = try assets.adoptTexture("res://one.png", 1, 1, &.{ 99, 88, 77, 255 }, .{});
    const original = assets.get(small).?.gpu;
    var made: mip_maker_table.MipMaker(MipRequest).Made = .{ .handle = .{ .handle = small }, .picture = null, .chain = try makeChain(testing.allocator, 1, 1, &.{ 99, 88, 77, 255 }, .{}) };
    defer made.deinit(testing.allocator);
    try assets.beginMips(&made);
    try assets.advanceMips();
    try testing.expectEqual(original, assets.get(small).?.gpu);
    _ = try device.textureSize(original);
}

test "a 3D surface's picture is held to the size limit, halved, and a sprite's is not" {
    try testing.expectEqual([2]u32{ 2048, 1024 }, limitedSize(2048, 1024, 0));
    try testing.expectEqual([2]u32{ 1024, 512 }, limitedSize(2048, 1024, 1024));
    try testing.expectEqual([2]u32{ 512, 1 }, limitedSize(4096, 8, 512));
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();
    assets.texture_max_size = 2;
    // Left half dark, right half light: halved, each side keeps its own.
    var pixels: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        const v: u8 = if (x < 2) 10 else 250;
        pixels[(y * 4 + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    const surface = try assets.adoptTexture("res://wall.png", 4, 4, &pixels, .{ .mips = true });
    try testing.expectEqual(@as(u32, 2), assets.get(surface).?.width);
    try testing.expect(assets.get(surface).?.limited);
    const sprite = try assets.adoptTexture("res://hero.png", 4, 4, &pixels, .{});
    try testing.expectEqual(@as(u32, 4), assets.get(sprite).?.width);
    try testing.expect(!assets.get(sprite).?.limited);
    const smaller = try halved(testing.allocator, 4, 4, &pixels, .{ 2, 2 });
    defer testing.allocator.free(smaller);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255, 250, 250, 250, 255 }, smaller[0..8]);
}

/// A project on disk with `art/` in it, and a Vulkan device: what the tests
/// of pictures read again from their files need.
const DiskAssets = struct {
    tmp: testing.TmpDir,
    root_buffer: [128]u8 = undefined,
    root: []const u8 = "",
    device: rhi.Device,
    project: Project,
    assets: Assets,

    fn open(self: *DiskAssets) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = try std.fmt.bufPrint(&self.root_buffer, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        try self.tmp.dir.createDirPath(testing.io, "art");
        self.device = rhi.Device.init(testing.allocator, .{ .backend = .vulkan }) catch |err| switch (err) {
            error.NoDevice, error.Unsupported => return error.SkipZigTest,
            else => return err,
        };
        errdefer self.device.deinit();
        if (!self.device.caps().formatSupport(.bc1_rgba_unorm).sampled) return error.SkipZigTest;
        self.project = try .init(testing.allocator, testing.io, self.root);
        errdefer self.project.deinit();
        self.assets = try .init(testing.allocator, &self.device, testing.io, &self.project);
    }

    fn close(self: *DiskAssets) void {
        self.assets.deinit();
        self.project.deinit();
        self.device.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *DiskAssets, buffer: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/art/{s}", .{ self.root, name });
    }

    /// Every chain asked for made, as frames would make them.
    fn settle(self: *DiskAssets) !void {
        var tries: usize = 0;
        while (self.assets.mipsPending() > 0) : (tries += 1) {
            if (tries > 20000) return error.Timeout;
            self.assets.makeWantedMips();
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

test "a 3D surface's picture is kept as BC1, as BC3 with alpha and as BC5 for a normal map, and a sprite's as it is" {
    var disk: DiskAssets = undefined;
    try disk.open();
    defer disk.close();
    var buffer: [192]u8 = undefined;
    try writeSolid(try disk.path(&buffer, "wall.png"), 16, 16, 255);
    try writeSolid(try disk.path(&buffer, "leaf.png"), 16, 16, 200);
    // See-through: its alpha is not all 255.
    {
        var pixels = [_]u8{ 50, 60, 70, 128 } ** (16 * 16);
        try image.png.writeFile(testing.allocator, testing.io, try disk.path(&buffer, "glass.png"), .{ .width = 16, .height = 16, .pixels = &pixels, .row_pitch = 64 }, .{ .keep_alpha = true });
    }
    const wall = try disk.assets.loadTexture(try disk.path(&buffer, "wall.png"), .{ .mips = true });
    try testing.expectEqual(rhi.Format.bc1_rgba_unorm, disk.assets.get(wall).?.format);
    try testing.expect(disk.assets.get(wall).?.mips);
    const glass = try disk.assets.loadTexture(try disk.path(&buffer, "glass.png"), .{ .mips = true });
    try testing.expectEqual(rhi.Format.bc3_rgba_unorm, disk.assets.get(glass).?.format);
    const bumps = try disk.assets.loadTexture(try disk.path(&buffer, "leaf.png"), .{ .mips = true, .role = .normal });
    try testing.expectEqual(rhi.Format.bc5_rg_unorm, disk.assets.get(bumps).?.format);
    const sprite = try disk.assets.loadTexture(try disk.path(&buffer, "wall.png"), .{});
    try testing.expectEqual(rhi.Format.rgba8_unorm, disk.assets.get(sprite).?.format);
    // An eighth of the memory: a block of eight bytes for sixteen texels.
    try testing.expectEqual(@as(usize, 128), disk.assets.get(wall).?.format.imageBytes(16, 16));
    // A compressed one read back is read again from its file.
    const pixels = try disk.assets.readPixels(wall, testing.allocator);
    defer testing.allocator.free(pixels);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, pixels[0..4]);
}

test "a lower limit, a higher one and compression switched off make the pictures again from their files" {
    var disk: DiskAssets = undefined;
    try disk.open();
    defer disk.close();
    var buffer: [192]u8 = undefined;
    try writeSolid(try disk.path(&buffer, "floor.png"), 64, 64, 255);
    const floor = try disk.assets.loadTexture(try disk.path(&buffer, "floor.png"), .{ .mips = true });
    disk.assets.setTextureMaxSize(16);
    // Drawn as it was until its replacement is made.
    try testing.expectEqual(@as(u32, 64), disk.assets.get(floor).?.width);
    try disk.settle();
    try testing.expectEqual(@as(u32, 16), disk.assets.get(floor).?.width);
    try testing.expect(disk.assets.get(floor).?.limited);
    disk.assets.setTextureMaxSize(0);
    try disk.settle();
    try testing.expectEqual(@as(u32, 64), disk.assets.get(floor).?.width);
    try testing.expectEqual(rhi.Format.bc1_rgba_unorm, disk.assets.get(floor).?.format);
    disk.assets.setTextureCompression(false);
    try disk.settle();
    try testing.expectEqual(rhi.Format.rgba8_unorm, disk.assets.get(floor).?.format);
    try testing.expect(disk.assets.get(floor).?.mips);
}

test "a picture's own import settings keep it uncompressed and smaller than the project would" {
    var disk: DiskAssets = undefined;
    try disk.open();
    defer disk.close();
    var buffer: [192]u8 = undefined;
    try writeSolid(try disk.path(&buffer, "sign.png"), 32, 32, 255);
    try disk.tmp.dir.writeFile(testing.io, .{ .sub_path = "art/sign.png.import", .data = "{\"compression\": \"uncompressed\", \"max_size\": 8}" });
    const sign = try disk.assets.loadTexture(try disk.path(&buffer, "sign.png"), .{ .mips = true });
    try testing.expectEqual(rhi.Format.rgba8_unorm, disk.assets.get(sign).?.format);
    try testing.expectEqual(@as(u32, 8), disk.assets.get(sign).?.width);
}

test "a picture inside a model is read again out of the model's file" {
    var disk: DiskAssets = undefined;
    try disk.open();
    defer disk.close();
    // A GLB with one PNG in its binary part.
    const bin = try image.png.encodeAlloc(testing.allocator, .{ .width = 2, .height = 2, .pixels = &(.{ 9, 8, 7, 255 } ** 4), .row_pitch = 8 }, .{});
    defer testing.allocator.free(bin);
    const padded = std.mem.alignForward(usize, bin.len, 4);
    var text_buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "{{\"asset\":{{\"version\":\"2.0\"}},\"buffers\":[{{\"byteLength\":{d}}}],\"bufferViews\":[{{\"buffer\":0,\"byteLength\":{d}}}],\"images\":[{{\"bufferView\":0,\"mimeType\":\"image/png\"}}]}}", .{ padded, bin.len });
    const text_len = std.mem.alignForward(usize, text.len, 4);
    var glb: std.ArrayList(u8) = .empty;
    defer glb.deinit(testing.allocator);
    const total: u32 = @intCast(12 + 8 + text_len + 8 + padded);
    for ([_]u32{ 0x46546C67, 2, total, @intCast(text_len), 0x4E4F534A }) |word| try glb.appendSlice(testing.allocator, std.mem.asBytes(&word));
    try glb.appendSlice(testing.allocator, text);
    try glb.appendNTimes(testing.allocator, ' ', text_len - text.len);
    for ([_]u32{ @intCast(padded), 0x004E4942 }) |word| try glb.appendSlice(testing.allocator, std.mem.asBytes(&word));
    try glb.appendSlice(testing.allocator, bin);
    try glb.appendNTimes(testing.allocator, 0, padded - bin.len);
    try disk.tmp.dir.writeFile(testing.io, .{ .sub_path = "art/crate.glb", .data = glb.items });
    const bytes = try mip_maker_table.readPicture(testing.allocator, disk.project.files(), "res://art/crate.glb#image/0", 1 << 20);
    defer testing.allocator.free(bytes);
    var decoded = try image.decode(testing.allocator, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7, 255 }, decoded.pixels[0..4]);
    try testing.expectError(error.FileNotFound, mip_maker_table.readPicture(testing.allocator, disk.project.files(), "res://art/crate.glb#image/1", 1 << 20));
}
