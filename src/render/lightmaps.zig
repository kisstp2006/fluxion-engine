// SPDX-License-Identifier: BSD-3-Clause

//! Lightmaps as files: what a `LightmapGI` bakes - the light from
//! everywhere on the world's still meshes, a picture of their lightmap UVs
//! side by side, and probes for the meshes that move - kept under a
//! `LightmapHandle`.
//!
//! ```zig
//! const baked = try app.loadLightmap("res://scenes/office.lightmap");
//! app.world.get(gi, fx.LightmapGI).?.data = baked;
//! ```
//!
//! Each mesh is found in it by its entity's UUID, which a scene keeps: an
//! entity made in code has none until it is given one, and is not in a
//! lightmap until it is baked with it. A `.lightmap` is `magic`, then
//! little-endian: the picture's width and height, how many meshes are in
//! it, the probes' counts each way, where the first is and how far apart
//! they are; each mesh's UUID and its place - what its lightmap UVs are
//! multiplied by and moved by; each probe's twelve numbers and a byte
//! saying whether it is in the open; and the picture, a texel's colour as
//! three bytes sharing a fourth's power of two, compressed with zlib.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const rhi = @import("fluxion_rhi");
const lightmapper = @import("fluxion_lightmapper");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const file_table = @import("../assets/file_table.zig");

const Uuid = id.Uuid;

/// What a lightmap's file ends in.
pub const extension = ".lightmap";

fn toHalf(x: f32) u16 {
    return @bitCast(@as(f16, @floatCast(std.math.clamp(x, -65504, 65504))));
}

/// A lightmap, the way a `TextureHandle` is a picture.
pub const LightmapHandle = file_table.Handle("LightmapHandle");

pub const Probes = lightmapper.Probes;

/// A mesh's place in a lightmap's picture: its lightmap UVs times `x` and
/// `y`, moved by `z` and `w`.
pub const Place = struct {
    uuid: Uuid,
    rect: [4]f32,
};

pub const Lightmap = struct {
    width: u32,
    height: u32,
    /// Linear light, a texel a word - red and green in eleven bits, blue in
    /// ten, each a small float - its top row first: what the device is
    /// given, at half the size of half floats. Let go of once it is on the
    /// device: then empty.
    pixels: []u32,
    /// How much of the first sun's light reaches each texel, a byte each -
    /// its shadow, baked: what stands between it and the sun for good.
    /// Empty where the file holds none, and once it is on the device.
    sun: []u8 = &.{},
    places: []Place,
    probes: Probes = .{},
    /// Each place's mesh by its UUID.
    by_uuid: std.AutoHashMapUnmanaged(Uuid, u32) = .empty,

    pub fn deinit(self: *Lightmap, gpa: Allocator) void {
        gpa.free(self.pixels);
        gpa.free(self.sun);
        gpa.free(self.places);
        self.probes.deinit(gpa);
        self.by_uuid.deinit(gpa);
        self.* = undefined;
    }

    /// Where the mesh of the entity with `uuid` is, if it was baked.
    pub fn placeOf(self: *const Lightmap, uuid: Uuid) ?[4]f32 {
        const at = self.by_uuid.get(uuid) orelse return null;
        return self.places[at].rect;
    }

    fn index(self: *Lightmap, gpa: Allocator) Allocator.Error!void {
        self.by_uuid.clearRetainingCapacity();
        try self.by_uuid.ensureTotalCapacity(gpa, @intCast(self.places.len));
        for (self.places, 0..) |place, at| self.by_uuid.putAssumeCapacity(place.uuid, @intCast(at));
    }

    /// How lit a surface facing `n` is at `at` from the probes round it, as
    /// three times four numbers; null where none are.
    pub fn probeLight(self: *const Lightmap, at: [3]f32) ?[12]f32 {
        return lightmapper.probeLight(self.probes, at);
    }

    /// How much of the first sun reaches what moves at `at`, from the
    /// probes round it; null where they hold none.
    pub fn probeSun(self: *const Lightmap, at: [3]f32) ?f32 {
        return lightmapper.probeSun(self.probes, at);
    }
};

/// What a `.lightmap` file starts with, its version in the last two letters.
pub const magic = "FXLMAP01";
/// The same file with, after the picture, how much of the first sun's light
/// reaches each texel: its length compressed, and a byte a texel, nought
/// hidden and 255 lit, laid out as the picture is. A length of nought is
/// none.
pub const magic_with_sun = "FXLMAP02";
/// The same with, after the sun's shadow on the picture, its shadow at
/// each probe - how much of the sun reaches what moves there: its length
/// compressed, and a byte a probe, in the probes' order. A length of
/// nought is none.
pub const magic_with_probe_sun = "FXLMAP03";

/// A lightmap as its file's bytes, the caller's.
pub fn write(gpa: Allocator, lightmap: Lightmap) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    const probe_sun = lightmap.probes.sun.len > 0;
    writeAll(w, if (probe_sun) magic_with_probe_sun else if (lightmap.sun.len > 0) magic_with_sun else magic) catch return error.OutOfMemory;
    const probes = lightmap.probes;
    for ([_]u32{ lightmap.width, lightmap.height, @intCast(lightmap.places.len), probes.counts[0], probes.counts[1], probes.counts[2] }) |n| try int(w, n);
    for (probes.origin ++ [1]f32{probes.spacing}) |x| try int(w, @bitCast(x));
    for (lightmap.places) |place| {
        writeAll(w, &place.uuid.bytes) catch return error.OutOfMemory;
        for (place.rect) |x| try int(w, @bitCast(x));
    }
    for (probes.samples) |sample| for (sample) |x| try int(w, @bitCast(x));
    for (probes.valid) |v| writeAll(w, &.{@intFromBool(v)}) catch return error.OutOfMemory;

    // The picture, three bytes and a power of two a texel, compressed.
    std.debug.assert(lightmap.pixels.len == @as(usize, lightmap.width) * lightmap.height);
    const shared = try gpa.alloc(u8, lightmap.pixels.len * 4);
    defer gpa.free(shared);
    for (lightmap.pixels, 0..) |texel, t| shared[t * 4 ..][0..4].* = toShared(unpack(texel));
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, shared.len / 4 + 4096);
    defer compressed.deinit();
    {
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        const deflate = try gpa.create(std.compress.flate.Compress);
        defer gpa.destroy(deflate);
        deflate.* = std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default) catch return error.OutOfMemory;
        deflate.writer.writeAll(shared) catch return error.OutOfMemory;
        deflate.finish() catch return error.OutOfMemory;
    }
    try int(w, @intCast(compressed.written().len));
    writeAll(w, compressed.written()) catch return error.OutOfMemory;
    if (lightmap.sun.len > 0 or probe_sun) {
        std.debug.assert(lightmap.sun.len == 0 or lightmap.sun.len == lightmap.pixels.len);
        try writeCompressed(gpa, w, lightmap.sun);
    }
    if (probe_sun) {
        std.debug.assert(lightmap.probes.sun.len == lightmap.probes.valid.len);
        try writeCompressed(gpa, w, lightmap.probes.sun);
    }
    return out.toOwnedSlice();
}

/// `bytes` zlib-compressed after their compressed length; none, a length
/// of nought.
fn writeCompressed(gpa: Allocator, w: *std.Io.Writer, bytes: []const u8) Allocator.Error!void {
    if (bytes.len == 0) return int(w, 0);
    var packed_bytes: std.Io.Writer.Allocating = try .initCapacity(gpa, bytes.len / 8 + 4096);
    defer packed_bytes.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const deflate = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(deflate);
    deflate.* = std.compress.flate.Compress.init(&packed_bytes.writer, window, .zlib, .default) catch return error.OutOfMemory;
    deflate.writer.writeAll(bytes) catch return error.OutOfMemory;
    deflate.finish() catch return error.OutOfMemory;
    try int(w, @intCast(packed_bytes.written().len));
    try writeAll(w, packed_bytes.written());
}

/// What a block `writeCompressed` wrote holds, `count` bytes - or nothing,
/// for one of length nought - after the block's end is `at`.
fn readCompressed(gpa: Allocator, bytes: []const u8, at: *usize, count: usize) (Allocator.Error || error{BadLightmap})![]u8 {
    const len = (try takeInts(bytes, at, 1))[0];
    if (at.* + len > bytes.len) return error.BadLightmap;
    defer at.* += len;
    if (len == 0) return &.{};
    const out = try gpa.alloc(u8, count);
    errdefer gpa.free(out);
    var in: std.Io.Reader = .fixed(bytes[at.*..][0..len]);
    var into: std.Io.Writer = .fixed(out);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var inflate: std.compress.flate.Decompress = .init(&in, .zlib, window);
    const got = inflate.reader.streamRemaining(&into) catch return error.BadLightmap;
    if (got != out.len) return error.BadLightmap;
    return out;
}

fn writeAll(w: *std.Io.Writer, bytes: []const u8) error{OutOfMemory}!void {
    w.writeAll(bytes) catch return error.OutOfMemory;
}

fn int(w: *std.Io.Writer, n: u32) error{OutOfMemory}!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, n, .little);
    try writeAll(w, &bytes);
}

/// A `.lightmap` file's bytes as a lightmap, the caller's.
/// `error.BadLightmap` for one that is not one, or is cut short.
pub fn read(gpa: Allocator, bytes: []const u8) (Allocator.Error || error{BadLightmap})!Lightmap {
    if (bytes.len < magic.len) return error.BadLightmap;
    const with_probe_sun = std.mem.eql(u8, bytes[0..magic.len], magic_with_probe_sun);
    const with_sun = with_probe_sun or std.mem.eql(u8, bytes[0..magic.len], magic_with_sun);
    if (!with_sun and !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadLightmap;
    var at: usize = magic.len;
    const head = try takeInts(bytes, &at, 10);
    const width = head[0];
    const height = head[1];
    const place_count = head[2];
    const counts = [3]u32{ head[3], head[4], head[5] };
    if (width > 16384 or height > 16384) return error.BadLightmap;
    const probe_count = @as(u64, counts[0]) * counts[1] * counts[2];
    if (probe_count > 1 << 20) return error.BadLightmap;

    const places = try gpa.alloc(Place, place_count);
    errdefer gpa.free(places);
    for (places) |*place| {
        if (at + 16 + 16 > bytes.len) return error.BadLightmap;
        place.uuid = .fromBytes(bytes[at..][0..16].*);
        at += 16;
        const rect = try takeInts(bytes, &at, 4);
        place.rect = .{ @bitCast(rect[0]), @bitCast(rect[1]), @bitCast(rect[2]), @bitCast(rect[3]) };
    }
    var probes: Probes = .{
        .origin = .{ @bitCast(head[6]), @bitCast(head[7]), @bitCast(head[8]) },
        .spacing = @bitCast(head[9]),
        .counts = counts,
    };
    probes.samples = try gpa.alloc([12]f32, @intCast(probe_count));
    errdefer gpa.free(probes.samples);
    probes.valid = try gpa.alloc(bool, @intCast(probe_count));
    errdefer gpa.free(probes.valid);
    errdefer gpa.free(probes.sun);
    for (probes.samples) |*sample| {
        const numbers = try takeInts(bytes, &at, 12);
        for (sample, numbers) |*x, n| x.* = @bitCast(n);
    }
    if (at + probes.valid.len > bytes.len) return error.BadLightmap;
    for (probes.valid, bytes[at..][0..probes.valid.len]) |*v, b| v.* = b != 0;
    at += probes.valid.len;

    const compressed_len = (try takeInts(bytes, &at, 1))[0];
    if (at + compressed_len > bytes.len or (!with_sun and at + compressed_len != bytes.len)) return error.BadLightmap;
    const picture_end = at + compressed_len;
    const texels = @as(usize, width) * height;
    const shared = try gpa.alloc(u8, texels * 4);
    defer gpa.free(shared);
    {
        var in: std.Io.Reader = .fixed(bytes[at..picture_end]);
        var into: std.Io.Writer = .fixed(shared);
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var inflate: std.compress.flate.Decompress = .init(&in, .zlib, window);
        const got = inflate.reader.streamRemaining(&into) catch return error.BadLightmap;
        if (got != shared.len) return error.BadLightmap;
    }
    const pixels = try gpa.alloc(u32, texels);
    errdefer gpa.free(pixels);
    for (pixels, 0..) |*texel, t| texel.* = pack(fromShared(shared[t * 4 ..][0..4].*));
    // The sun's baked shadow, where the file has it, and at the probes.
    var sun: []u8 = &.{};
    errdefer gpa.free(sun);
    if (with_sun) {
        at = picture_end;
        sun = try readCompressed(gpa, bytes, &at, texels);
        if (with_probe_sun) {
            probes.sun = try readCompressed(gpa, bytes, &at, probes.valid.len);
        }
        if (at != bytes.len) return error.BadLightmap;
    }
    var out: Lightmap = .{ .width = width, .height = height, .pixels = pixels, .sun = sun, .places = places, .probes = probes };
    errdefer out.by_uuid.deinit(gpa);
    try out.index(gpa);
    return out;
}

fn takeInts(bytes: []const u8, at: *usize, comptime n: usize) error{BadLightmap}![n]u32 {
    if (at.* + n * 4 > bytes.len) return error.BadLightmap;
    var out: [n]u32 = undefined;
    for (&out) |*x| {
        x.* = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
    }
    return out;
}

/// What was baked, as a lightmap of half floats, each instance's place
/// under the UUID given for it; instances not in the picture are left out.
pub fn fromBaked(gpa: Allocator, baked: lightmapper.Result, uuids: []const Uuid) Allocator.Error!Lightmap {
    const pixels = try gpa.alloc(u32, baked.pixels.len);
    errdefer gpa.free(pixels);
    for (baked.pixels, pixels) |p, *texel| texel.* = pack(p);
    var count: usize = 0;
    for (baked.places) |place| {
        if (place[0] > 0) count += 1;
    }
    const places = try gpa.alloc(Place, count);
    errdefer gpa.free(places);
    var at: usize = 0;
    for (baked.places, uuids) |place, uuid| {
        if (place[0] <= 0) continue;
        places[at] = .{ .uuid = uuid, .rect = place };
        at += 1;
    }
    var probes: Probes = .{ .origin = baked.probes.origin, .spacing = baked.probes.spacing, .counts = baked.probes.counts };
    probes.samples = try gpa.dupe([12]f32, baked.probes.samples);
    errdefer gpa.free(probes.samples);
    probes.valid = try gpa.dupe(bool, baked.probes.valid);
    errdefer gpa.free(probes.valid);
    var out: Lightmap = .{ .width = baked.width, .height = baked.height, .pixels = pixels, .places = places, .probes = probes };
    errdefer out.by_uuid.deinit(gpa);
    try out.index(gpa);
    return out;
}

/// Light as three bytes sharing the fourth's power of two.
fn toShared(rgb: [3]f32) [4]u8 {
    const most = @max(rgb[0], rgb[1], rgb[2]);
    if (!(most > 1e-32)) return .{ 0, 0, 0, 0 };
    const split = std.math.frexp(most);
    const scale = split.significand * 256 / most;
    var out: [4]u8 = undefined;
    for (0..3) |c| out[c] = @intFromFloat(std.math.clamp(@max(rgb[c], 0) * scale, 0, 255));
    out[3] = @intCast(std.math.clamp(split.exponent + 128, 0, 255));
    return out;
}

fn fromShared(texel: [4]u8) [3]f32 {
    if (texel[3] == 0) return .{ 0, 0, 0 };
    const f = std.math.ldexp(@as(f32, 1), @as(i32, texel[3]) - 136);
    return .{ (@as(f32, @floatFromInt(texel[0])) + 0.5) * f, (@as(f32, @floatFromInt(texel[1])) + 0.5) * f, (@as(f32, @floatFromInt(texel[2])) + 0.5) * f };
}

/// Light as three small floats in a word: red and green as a half float's
/// exponent and its top six bits, blue its top five, none of them signed -
/// what devices call R11G11B10.
pub fn pack(rgb: [3]f32) u32 {
    var word: u32 = 0;
    const shifts = [3]u5{ 0, 11, 22 };
    const dropped = [3]u4{ 4, 4, 5 };
    for (0..3) |c| {
        const h: u32 = @as(u16, @bitCast(@as(f16, @floatCast(std.math.clamp(rgb[c], 0, 65000)))));
        // Rounded to the nearest, the carry into the exponent as it falls.
        const half_step = @as(u32, 1) << (dropped[c] - 1);
        const most: u32 = if (c == 2) 0x3df else 0x7bf;
        const small = @min((h + half_step) >> dropped[c], most);
        word |= small << shifts[c];
    }
    return word;
}

pub fn unpack(word: u32) [3]f32 {
    const r: u16 = @intCast((word & 0x7ff) << 4);
    const g: u16 = @intCast(((word >> 11) & 0x7ff) << 4);
    const b: u16 = @intCast(((word >> 22) & 0x3ff) << 5);
    return .{ @floatCast(@as(f16, @bitCast(r))), @floatCast(@as(f16, @bitCast(g))), @floatCast(@as(f16, @bitCast(b))) };
}

/// Every lightmap read or made, under its handle, and its picture on the
/// device once drawn with.
pub const Lightmaps = struct {
    table: Inner = .empty,
    /// What its lightmaps were made with: what a picture let go of once on
    /// the device is given back to.
    gpa: Allocator = undefined,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        source: []u8,
        on_disc: bool,
        lightmap: Lightmap,
        texture: ?rhi.Texture = null,
        /// The sun's baked shadow on the device, where the lightmap has one.
        sun_texture: ?rhi.Texture = null,
        /// Whether it has one, kept once the bytes are let go of.
        has_sun: bool = false,
        /// Counts up each time it is replaced, for what keeps something of it.
        version: u32 = 0,
    };

    fn toId(handle: LightmapHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) LightmapHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *Lightmaps, gpa: Allocator, device: *rhi.Device) void {
        var it = self.table.iterator();
        while (it.next()) |entry| free(gpa, device, entry.value);
        self.table.deinit(gpa);
        self.* = .{};
    }

    fn free(gpa: Allocator, device: *rhi.Device, entry: *Entry) void {
        gpa.free(entry.source);
        entry.lightmap.deinit(gpa);
        if (entry.texture) |texture| device.destroyTexture(texture);
        if (entry.sun_texture) |texture| device.destroyTexture(texture);
    }

    /// Keep `lightmap`, which is the table's from here, under `name`: a
    /// name given before gets the new one, and keeps its handle.
    pub fn add(self: *Lightmaps, gpa: Allocator, device: *rhi.Device, name: []const u8, lightmap: Lightmap) Allocator.Error!LightmapHandle {
        return self.keep(gpa, device, name, lightmap, false);
    }

    fn keep(self: *Lightmaps, gpa: Allocator, device: *rhi.Device, name: []const u8, lightmap: Lightmap, on_disc: bool) Allocator.Error!LightmapHandle {
        self.gpa = gpa;
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.lightmap.deinit(gpa);
            if (held.texture) |texture| device.destroyTexture(texture);
            held.texture = null;
            if (held.sun_texture) |texture| device.destroyTexture(texture);
            held.sun_texture = null;
            held.has_sun = false;
            held.lightmap = lightmap;
            held.on_disc = on_disc;
            held.version +%= 1;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .lightmap = lightmap }));
    }

    /// The lightmap in the `.lightmap` file at `path`, read now unless it
    /// was read before.
    pub fn load(self: *Lightmaps, app: *App, path: []const u8) !LightmapHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        var lightmap = try readFile(app, source);
        errdefer lightmap.deinit(app.gpa);
        if (Project.isProjectPath(source)) _ = app.project.uidOf(source) catch {};
        return self.keep(app.gpa, &app.device, source, lightmap, true);
    }

    fn readFile(app: *App, source: []const u8) !Lightmap {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return read(app.gpa, bytes);
    }

    /// Read a lightmap's file again. Says whether it had one.
    pub fn reload(self: *Lightmaps, app: *App, handle: LightmapHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const lightmap = try readFile(app, held.source);
        held.lightmap.deinit(app.gpa);
        if (held.texture) |texture| app.device.destroyTexture(texture);
        held.texture = null;
        held.lightmap = lightmap;
        held.version +%= 1;
        return true;
    }

    pub fn unload(self: *Lightmaps, gpa: Allocator, device: *rhi.Device, handle: LightmapHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        free(gpa, device, held);
        _ = self.table.remove(toId(handle));
    }

    pub fn find(self: *Lightmaps, source: []const u8) ?LightmapHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *Lightmaps, handle: LightmapHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn get(self: *Lightmaps, handle: LightmapHandle) ?*const Lightmap {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.lightmap;
    }

    /// How many times the lightmap under `handle` has been replaced.
    pub fn versionOf(self: *Lightmaps, handle: LightmapHandle) u32 {
        const held = self.table.get(toId(handle)) orelse return 0;
        return held.version;
    }

    /// The sun's baked shadow on the device, made the first time it is asked
    /// for; null where the lightmap holds none.
    pub fn sunTextureOf(self: *Lightmaps, device: *rhi.Device, handle: LightmapHandle) rhi.Error!?rhi.Texture {
        const held = self.table.get(toId(handle)) orelse return null;
        if (held.sun_texture) |texture| return texture;
        const lightmap = &held.lightmap;
        if (lightmap.sun.len == 0 or lightmap.width == 0 or lightmap.height == 0) return null;
        held.sun_texture = try device.createTexture(.{
            .width = lightmap.width,
            .height = lightmap.height,
            .format = .r8_unorm,
            .data = lightmap.sun,
            .label = "lightmap, sun",
        });
        held.has_sun = true;
        self.gpa.free(lightmap.sun);
        lightmap.sun = &.{};
        return held.sun_texture;
    }

    /// Its picture on the device, made the first time it is asked for.
    pub fn textureOf(self: *Lightmaps, device: *rhi.Device, handle: LightmapHandle) rhi.Error!?rhi.Texture {
        const held = self.table.get(toId(handle)) orelse return null;
        if (held.texture) |texture| return texture;
        const lightmap = &held.lightmap;
        if (lightmap.width == 0 or lightmap.height == 0 or lightmap.pixels.len == 0) return null;
        const support = device.caps().formatSupport(.rg11b10_float);
        if (support.sampled and support.filterable) {
            held.texture = try device.createTexture(.{
                .width = lightmap.width,
                .height = lightmap.height,
                .format = .rg11b10_float,
                .data = std.mem.sliceAsBytes(lightmap.pixels),
                .label = "lightmap",
            });
        } else {
            // A device that reads no small floats is given half floats,
            // made for it and let go of.
            const halves = self.gpa.alloc(u16, lightmap.pixels.len * 4) catch return error.OutOfMemory;
            defer self.gpa.free(halves);
            for (lightmap.pixels, 0..) |texel, t| {
                const rgb = unpack(texel);
                halves[t * 4 ..][0..4].* = .{ toHalf(rgb[0]), toHalf(rgb[1]), toHalf(rgb[2]), toHalf(1) };
            }
            held.texture = try device.createTexture(.{
                .width = lightmap.width,
                .height = lightmap.height,
                .format = .rgba16_float,
                .data = std.mem.sliceAsBytes(halves),
                .label = "lightmap",
            });
        }
        // On the device it is not read again: the places and the probes are
        // what is kept.
        self.gpa.free(lightmap.pixels);
        lightmap.pixels = &.{};
        return held.texture;
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Lightmaps, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a lightmap's file reads back as it was written, near enough, and one cut short is refused" {
    const gpa = testing.allocator;
    var baked_pixels = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0.5, 0.25 }, .{ 40, 2, 0.001 }, .{ 0.2, 0.2, 0.2 } };
    var baked_places = [_][4]f32{ .{ 0.5, 0.5, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0.5, 0.5, 0.5, 0.5 } };
    var samples = [_][12]f32{ @splat(0.5), @splat(0.25) };
    var valid = [_]bool{ true, false };
    const baked: lightmapper.Result = .{
        .width = 2,
        .height = 2,
        .pixels = &baked_pixels,
        .places = &baked_places,
        .probes = .{ .origin = .{ 1, 2, 3 }, .spacing = 2, .counts = .{ 2, 1, 1 }, .samples = &samples, .valid = &valid },
    };
    const uuids = [_]Uuid{ .fromBytes(@splat(1)), .fromBytes(@splat(2)), .fromBytes(@splat(3)) };
    var lightmap = try fromBaked(gpa, baked, &uuids);
    defer lightmap.deinit(gpa);
    // The one not in the picture left out.
    try testing.expectEqual(@as(usize, 2), lightmap.places.len);
    try testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 0.5 }, lightmap.placeOf(uuids[2]).?);
    try testing.expect(lightmap.placeOf(uuids[1]) == null);

    const bytes = try write(gpa, lightmap);
    defer gpa.free(bytes);
    var back = try read(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqual(lightmap.width, back.width);
    try testing.expectEqual([4]f32{ 0.5, 0.5, 0, 0 }, back.placeOf(uuids[0]).?);
    try testing.expectEqualSlices([12]f32, &samples, back.probes.samples);
    try testing.expectEqualSlices(bool, &valid, back.probes.valid);
    try testing.expectEqual([3]f32{ 1, 2, 3 }, back.probes.origin);
    // Each channel within a step of the texel's brightest: three bytes
    // share one power of two.
    for (baked_pixels, 0..) |p, t| for (0..3) |c| {
        const was = p[c];
        const now = unpack(back.pixels[t])[c];
        try testing.expectApproxEqAbs(was, now, @max(@max(p[0], p[1], p[2]) / 128, was / 24, 0.002));
    };

    try testing.expectError(error.BadLightmap, read(gpa, bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.BadLightmap, read(gpa, "FXLMAP99"));

    // With the sun's baked shadow, a byte a texel, after the picture.
    try testing.expectEqual(@as(usize, 0), back.sun.len);
    var shaded = try read(gpa, bytes);
    defer shaded.deinit(gpa);
    shaded.sun = try gpa.dupe(u8, &.{ 0, 255, 128, 7 });
    const with_sun = try write(gpa, shaded);
    defer gpa.free(with_sun);
    try testing.expectEqualStrings(magic_with_sun, with_sun[0..magic_with_sun.len]);
    var again = try read(gpa, with_sun);
    defer again.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 128, 7 }, again.sun);
    try testing.expectEqual([4]f32{ 0.5, 0.5, 0, 0 }, again.placeOf(uuids[0]).?);
    try testing.expectError(error.BadLightmap, read(gpa, with_sun[0 .. with_sun.len - 1]));
    try testing.expect(again.probeSun(.{ 1, 2, 3 }) == null);

    // And the sun's shadow at each probe, after that: read where what moves
    // is, from the probes round it in the open - the second is inside
    // something, so the first's holds across.
    again.probes.sun = try gpa.dupe(u8, &.{ 255, 0 });
    const with_probes = try write(gpa, again);
    defer gpa.free(with_probes);
    try testing.expectEqualStrings(magic_with_probe_sun, with_probes[0..magic_with_probe_sun.len]);
    var probed = try read(gpa, with_probes);
    defer probed.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0 }, probed.probes.sun);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 128, 7 }, probed.sun);
    try testing.expectEqual(@as(f32, 1), probed.probeSun(.{ 2, 2, 3 }).?);
    probed.probes.valid[1] = true;
    try testing.expectApproxEqAbs(@as(f32, 0.5), probed.probeSun(.{ 2, 2, 3 }).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), probed.probeSun(.{ 3, 2, 3 }).?, 0.001);
    try testing.expectError(error.BadLightmap, read(gpa, with_probes[0 .. with_probes.len - 1]));
    // A sun on the probes alone, none on the picture: an empty block for it.
    gpa.free(again.sun);
    again.sun = &.{};
    const probes_only = try write(gpa, again);
    defer gpa.free(probes_only);
    var only = try read(gpa, probes_only);
    defer only.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), only.sun.len);
    try testing.expectEqualSlices(u8, &.{ 255, 0 }, only.probes.sun);
}
