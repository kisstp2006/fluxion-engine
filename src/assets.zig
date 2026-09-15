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
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const id = @import("fluxion_id");
const typeface = @import("fluxion_font");
const platform = @import("fluxion_platform");

const Atlas = @import("text/Atlas.zig");
const Project = @import("Project.zig");

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
};

/// How a texture should be sampled, and what it is called in a debugger.
pub const LoadOptions = struct {
    /// `.nearest` by default: a blurred sprite is the harder mistake to spot.
    filter: rhi.Filter = .nearest,
    wrap: rhi.Wrap = .clamp_to_edge,
    label: []const u8 = "",
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

/// How many times a font has been read again, counting up. A font read
/// again keeps its address, so whoever holds glyphs drawn from one - the
/// interface's renderer - watches this to draw them again. See `reloadFont`.
font_reloads: u32 = 0,

/// One opaque white texel. See the module comment.
white: TextureHandle = .none,

samplers: Samplers,

pub fn init(gpa: Allocator, device: *rhi.Device, io: ?std.Io, project: *Project) Error!Assets {
    var self: Assets = .{
        .gpa = gpa,
        .device = device,
        .io = io,
        .project = project,
        .samplers = .initFill(.initFill(.none)),
    };
    errdefer self.deinit();

    for (std.enums.values(rhi.Filter)) |filter| {
        for (std.enums.values(rhi.Wrap)) |wrap| {
            self.samplers.getPtr(filter).set(wrap, try device.createSampler(.{
                .min_filter = filter,
                .mag_filter = filter,
                .wrap_u = wrap,
                .wrap_v = wrap,
            }));
        }
    }

    self.white = try self.textureFromPixels(1, 1, &.{ 255, 255, 255, 255 }, .{ .label = "white" });
    return self;
}

pub fn deinit(self: *Assets) void {
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        self.device.destroyTexture(entry.value.gpu);
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
    for (self.samplers.values) |by_wrap| {
        for (by_wrap.values) |sampler| self.device.destroySampler(sampler);
    }
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
        .wrap = options.wrap,
        .source = source,
    }));
}

/// A texture from a PNG: `res://art/hero.png`, `uid://...`, or the
/// operating system's path. Loading a file twice makes two textures -
/// `findTexture` first.
pub fn loadTexture(self: *Assets, path: []const u8, options: LoadOptions) !TextureHandle {
    const io = self.io orelse return Error.NoIo;
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    const file = try self.project.osPath(self.gpa, source);
    defer self.gpa.free(file);

    var decoded = try image.png.readFile(self.gpa, io, file, .{});
    defer decoded.deinit(self.gpa);
    self.learnUid(source);

    return self.addTexture(
        decoded.width,
        decoded.height,
        decoded.pixels,
        .{
            .filter = options.filter,
            .wrap = options.wrap,
            .label = if (options.label.len == 0) source else options.label,
        },
        source,
    );
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
    if (!Project.isProjectPath(source)) return;
    _ = self.project.uidOf(source) catch |err| {
        log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
    };
}

/// Give every file of the project's that is loaded, and has no UUID, one -
/// in a `.uid` file beside it. Saving a scene does it, so the scene can name
/// its files by their UUIDs.
pub fn ensureUids(self: *Assets) !void {
    var textures = self.textures.iterator();
    while (textures.next()) |entry| {
        if (Project.isProjectPath(entry.value.source)) _ = try self.project.ensureUid(entry.value.source);
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
/// platform, for a caller with no `Assets` at hand. `loadSystemFont` asks
/// the system instead, and is right where this is not - a Japanese Windows, a
/// Linux without DejaVu. A game that ships carries its own.
pub fn systemFontPath() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "C:/Windows/Fonts/segoeui.ttf",
        .macos => "/System/Library/Fonts/Supplemental/Arial.ttf",
        else => "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
}

/// Open the font the system's own dialogs use, as the system names it: the
/// message font on Windows - Segoe UI, and Yu Gothic UI on Japanese Windows,
/// which is the second font of a collection - what fontconfig makes of
/// sans-serif on Linux, and Roboto on Android. `options.member` is replaced by
/// the system's answer. For an editor's interface, or a game's debug text; a
/// game's own words are set in a font it ships.
pub fn loadSystemFont(self: *Assets, options: FontOptions) !FontHandle {
    const io = self.io orelse return Error.NoIo;
    const found = try platform.fonts.systemUi(self.gpa, io);
    defer found.deinit(self.gpa);
    var asked = options;
    asked.member = found.index;
    return self.loadFont(found.path, asked);
}

/// Open a TrueType file from the disc, named as `loadTexture` names one - or
/// one font of a collection, by `options.member`.
pub fn loadFont(self: *Assets, path: []const u8, options: FontOptions) !FontHandle {
    const io = self.io orelse return Error.NoIo;
    const source = try self.project.canonical(self.gpa, path);
    errdefer self.gpa.free(source);
    const file = try self.project.osPath(self.gpa, source);
    defer self.gpa.free(file);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, self.gpa, .limited(font_limit));
    defer self.gpa.free(bytes);
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
    const io = self.io orelse return Error.NoIo;
    const file = try self.project.osPath(self.gpa, texture.source);
    defer self.gpa.free(file);

    var decoded = try image.png.readFile(self.gpa, io, file, .{});
    defer decoded.deinit(self.gpa);

    if (decoded.width == texture.width and decoded.height == texture.height) {
        try self.device.updateTexture(texture.gpu, decoded.pixels, 0);
        return true;
    }
    // Another size is another texture on the device, and the old one's
    // `rhi` handle stops resolving - which is why whoever shows textures in
    // the interface hands their list over every frame.
    const gpu = try self.device.createTexture(.{
        .width = decoded.width,
        .height = decoded.height,
        .data = decoded.pixels,
        .label = texture.source,
    });
    self.device.destroyTexture(texture.gpu);
    texture.gpu = gpu;
    texture.width = decoded.width;
    texture.height = decoded.height;
    return true;
}

/// Read a font's file again, in place: the handle and the font's address
/// stay, and the glyphs drawn so far go, to be drawn again from the new
/// face. Says whether there was a file to read, as `reloadTexture` does.
pub fn reloadFont(self: *Assets, handle: FontHandle) !bool {
    const font = (self.fonts.get(handle.toId()) orelse return false).*;
    if (font.source.len == 0) return false;
    const io = self.io orelse return Error.NoIo;
    const file = try self.project.osPath(self.gpa, font.source);
    defer self.gpa.free(file);

    // Read into memory the font keeps, since the face holds views into it.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, self.gpa, .limited(font_limit));
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
        self.device.destroyTexture(texture.gpu);
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

/// How many textures are loaded, not counting the white texel.
pub fn count(self: *const Assets) usize {
    const total = self.textures.count();
    return if (total == 0) 0 else total - 1;
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

test "there is a white texel before anything is loaded" {
    var device: rhi.Device = try .init(testing.allocator, .{ .backend = .none });
    defer device.deinit();

    var project: Project = try .init(testing.allocator, null, null);
    defer project.deinit();
    var assets: Assets = try .init(testing.allocator, &device, null, &project);
    defer assets.deinit();

    try testing.expect(!assets.white.isNone());
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
    try writeSolid(png, 1, 1, 255);

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
