// SPDX-License-Identifier: BSD-3-Clause

//! A shader the 2D layer draws with: the fragment stage a `.shader` file
//! says, and everything else the engine's.
//!
//! ```
//! uniform Look : 1 {
//!     float strength = 0.4;
//!     vec4 glow = vec4(1.0, 0.8, 0.3, 1.0);
//! }
//!
//! fragment {
//!     vec4 picture = sample(TEXTURE, UV) * COLOR;
//!     float line = step(0.5, fract(SCREEN_UV.y * 180.0));
//!     target = mix(picture, picture * glow * line, strength);
//! }
//! ```
//!
//! The file is fluxion-shader's language, and is its fragment stage and what
//! that reads: functions, constants, and one uniform block of its own at
//! slot 1, whose fields - and their first values - are what a `Material`
//! gives it. The engine writes the rest after it: the vertex stage that
//! places a quad, and the names a material reads:
//!
//! | Name | What it is |
//! | --- | --- |
//! | `UV` | Where in its picture the pixel is, nought to one. |
//! | `COLOR` | The quad's colour: a sprite's tint, a control's. |
//! | `TEXTURE` | Its picture: a sprite's, a texture rect's, white for a colour rect. |
//! | `SCREEN_UV` | Where on the screen the pixel is, nought to one from the top left. |
//! | `SCREEN_TEXTURE` | What is drawn under it: the frame so far. |
//! | `SCREEN_PIXEL_SIZE` | One pixel of the screen, in `SCREEN_UV`'s units. |
//! | `TIME` | Seconds since the game started, as the interface's clock. |
//!
//! After the file rather than before, so a line a message names is the
//! file's own line. A texture is only declared when the file names it:
//! fluxion-shader refuses one that nothing reads.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const shader = @import("fluxion_shader");

const Sprite = @import("../components.zig").Sprite;

/// What every frame tells a material's shader, as its `Frame` block says:
/// `std140`, eighty bytes. `compile` holds the two to each other.
pub const Frame = extern struct {
    /// The world, or the interface's pixels, to clip space.
    projection: math.Mat4,
    screen_pixel_size: [2]f32,
    time: f32,
    /// Which way `SCREEN_UV` counts down: see `screenFlip`.
    screen_flip: f32,
};

/// A field of a material's block: its name, its type, where it is and what
/// it starts as.
pub const Field = shader.Field;
/// What a field holds: a number, a vector, a matrix.
pub const Type = shader.Type;

/// The file's own numbers are the block at this slot.
pub const params_slot = 1;

/// A shader compiled for the 2D layer, and a pipeline for each way it blends.
pub const Compiled = struct {
    module: shader.Module,
    gpu: rhi.Shader,
    pipelines: std.EnumArray(Sprite.Blend, rhi.Pipeline),
    /// Where `TEXTURE` and `SCREEN_TEXTURE` are bound, for a shader that
    /// reads them.
    texture_slot: ?u32 = null,
    screen_slot: ?u32 = null,
    /// The file's own block, whose fields a `Material` fills.
    params: ?shader.Block = null,

    pub fn deinit(self: *Compiled, device: *rhi.Device) void {
        for (self.pipelines.values) |pipeline| device.destroyPipeline(pipeline);
        device.destroyShader(self.gpu);
        self.module.deinit();
        self.* = undefined;
    }

    /// Whether it reads what is drawn under it, which has to be copied
    /// before it is drawn.
    pub fn readsScreen(self: *const Compiled) bool {
        return self.screen_slot != null;
    }
};

/// A picture, coloured: what a sprite is drawn with when it names no shader.
pub const plain =
    \\fragment {
    \\    target = sample(TEXTURE, UV) * COLOR;
    \\}
;

/// The attributes, in the order an `Instance` holds them after the corner:
/// the quad's corner, its place and size, its pivot and turn, its colour and
/// its part of the picture. What a file reads has its doc above it, which an
/// editor shows.
const engine_head =
    \\attribute vec2 CORNER : 0;
    \\attribute vec4 PLACEMENT : 1;
    \\attribute vec4 SPIN : 2;
    \\attribute vec4 TINT : 3;
    \\attribute vec4 REGION : 4;
    \\
    \\// Where on the picture this pixel is: from nought to one across and down.
    \\varying vec2 UV;
    \\// The sprite's tint, or the control's colour, with its fade.
    \\varying vec4 COLOR;
    \\// Where on the screen this pixel is: from nought to one across and down.
    \\varying vec2 SCREEN_UV;
    \\
    \\uniform Frame : 0 {
    \\    mat4 PROJECTION;
    \\    // How big a pixel of the screen is in SCREEN_UV: one over its width and height.
    \\    vec2 SCREEN_PIXEL_SIZE;
    \\    // Seconds since the game started.
    \\    float TIME;
    \\    float SCREEN_FLIP;
    \\}
    \\
;

/// The engine's two textures, and what each is: declared only in a file
/// that names it.
pub const texture_doc = "The picture it is drawn with: the sprite's, or the rect's.";
pub const screen_texture_doc = "What is drawn under it so far this frame.";

/// `CORNER` is a unit square: the pivot taken off it, scaled to the quad's
/// size, turned, and put where the quad is.
const engine_vertex =
    \\vertex {
    \\    vec2 vertex_local = (CORNER - SPIN.xy) * PLACEMENT.zw;
    \\    vec2 vertex_turned = vec2(
    \\        vertex_local.x * SPIN.z - vertex_local.y * SPIN.w,
    \\        vertex_local.x * SPIN.w + vertex_local.y * SPIN.z
    \\    );
    \\    UV = mix(REGION.xy, REGION.zw, CORNER);
    \\    COLOR = TINT;
    \\    vec4 vertex_clip = PROJECTION * vec4(PLACEMENT.xy + vertex_turned, 0.0, 1.0);
    \\    SCREEN_UV = vec2(
    \\        vertex_clip.x / vertex_clip.w * 0.5 + 0.5,
    \\        vertex_clip.y / vertex_clip.w * 0.5 * SCREEN_FLIP + 0.5
    \\    );
    \\    position = vertex_clip;
    \\}
    \\
;

/// Which vertex buffer an attribute is read from: the corner is the quad
/// that never changes, and everything else is per instance.
pub fn bufferOf(name: []const u8) u32 {
    return if (std.mem.eql(u8, name, "CORNER")) 0 else 1;
}

fn vertexFormat(ty: shader.Type) ?rhi.VertexFormat {
    return switch (ty) {
        .float => .float,
        .vec2 => .float2,
        .vec3 => .float3,
        .vec4 => .float4,
        else => null,
    };
}

/// `SCREEN_FLIP` for a device: how clip space's `y` becomes a row of a
/// texture drawn into - down from the top, or up from the bottom where the
/// device says what it draws is stored bottom row first.
pub fn screenFlip(device: *const rhi.Device) f32 {
    return if (device.caps().features.render_target_origin_bottom_left) 1 else -1;
}

/// A `.shader` file's text with the engine's part after it: what `compile`
/// compiles, and what an editor's analysis reads.
pub const Whole = struct {
    source: []u8,
    /// The line of the whole the engine's part starts on, from one.
    engine_line: usize,
    texture_slot: ?u32 = null,
    screen_slot: ?u32 = null,
    /// How many textures the engine declared for it.
    textures: u32 = 0,
    /// Where the file declares something that is the engine's, if it does.
    trespass: ?Trespass = null,

    pub const Trespass = struct { offset: u32, what: []const u8 };

    /// What a trespass is said as, at the file's own line and column.
    pub fn trespassMessage(self: Whole, gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
        const where = self.trespass orelse return null;
        const at = lineAndColumn(text, where.offset);
        return try std.fmt.allocPrint(gpa, "{d}:{d}: {s} is the engine's: a material's shader is its fragment stage, and what that reads", .{ at.line, at.column, where.what });
    }
};

/// The file's text, then the engine's part: its attributes, varyings and
/// `Frame`, the textures the file names, and the vertex stage. The caller
/// owns `source`.
pub fn whole(gpa: Allocator, text: []const u8) Allocator.Error!Whole {
    const found = try scan(gpa, text);
    var full: std.Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    const w = &full.writer;
    w.writeAll(text) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    var out: Whole = .{ .source = &.{}, .engine_line = std.mem.count(u8, full.written(), "\n") + 1 };
    if (found.trespass) |t| out.trespass = .{ .offset = t.offset, .what = t.what };
    w.writeAll(engine_head) catch return error.OutOfMemory;
    if (found.texture) {
        out.texture_slot = out.textures;
        w.print("// {s}\ntexture2d TEXTURE : {d};\n", .{ texture_doc, out.textures }) catch return error.OutOfMemory;
        out.textures += 1;
    }
    if (found.screen) {
        out.screen_slot = out.textures;
        w.print("// {s}\ntexture2d SCREEN_TEXTURE : {d};\n", .{ screen_texture_doc, out.textures }) catch return error.OutOfMemory;
        out.textures += 1;
    }
    w.writeAll(engine_vertex) catch return error.OutOfMemory;
    out.source = full.toOwnedSlice() catch return error.OutOfMemory;
    return out;
}

/// What `compile` finds in a file before compiling it.
const Scan = struct {
    texture: bool = false,
    screen: bool = false,
    /// Where it declares something that is the engine's, if it does.
    trespass: ?struct { offset: u32, what: []const u8 } = null,
};

fn scan(gpa: Allocator, text: []const u8) Allocator.Error!Scan {
    var failure: shader.lex.Failure = undefined;
    // A file that does not even lex is left for the compiler to say so,
    // with the engine's part after it.
    const tokens = shader.lex.tokenize(gpa, text, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    defer gpa.free(tokens);
    var out: Scan = .{};
    for (tokens) |token| switch (token.kind) {
        .identifier => {
            if (std.mem.eql(u8, token.bytes, "TEXTURE")) out.texture = true;
            if (std.mem.eql(u8, token.bytes, "SCREEN_TEXTURE")) out.screen = true;
        },
        .kw_vertex, .kw_attribute, .kw_varying => if (out.trespass == null) {
            out.trespass = .{ .offset = token.offset, .what = token.kind.describe() };
        },
        else => {},
    };
    return out;
}

/// The line and column `offset` is on, from one.
fn lineAndColumn(text: []const u8, offset: u32) struct { line: usize, column: usize } {
    const at = @min(offset, text.len);
    const line = std.mem.count(u8, text[0..at], "\n") + 1;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    return .{ .line = line, .column = at - start + 1 };
}

/// Compile a `.shader` file's text - `plain` for the engine's own - with the
/// engine's part after it, and make its pipelines. What is wrong with it is
/// written to `problems`, at the file's own lines, and is
/// `error.ShaderFailed`.
pub fn compile(
    gpa: Allocator,
    device: *rhi.Device,
    text: []const u8,
    label: []const u8,
    problems: *std.Io.Writer,
) (error{ShaderFailed} || Allocator.Error || rhi.Error)!Compiled {
    const built = try whole(gpa, text);
    defer gpa.free(built.source);
    if (try built.trespassMessage(gpa, text)) |message| {
        defer gpa.free(message);
        problems.print("{s}\n", .{message}) catch {};
        return error.ShaderFailed;
    }
    const slot = built.textures;
    const texture_slot = built.texture_slot;
    const screen_slot = built.screen_slot;

    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var module = shader.compile(gpa, built.source, &log.writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {
            tellOfLines(log.written(), built.engine_line, problems);
            return error.ShaderFailed;
        },
    };
    errdefer module.deinit();

    // One block of its own, at its slot, and no textures but the engine's.
    var params: ?shader.Block = null;
    for (module.blocks) |block| {
        if (std.mem.eql(u8, block.name, "Frame")) continue;
        if (block.slot != params_slot or params != null) {
            problems.print("a material's own numbers are one uniform block, at slot {d}: `{s}` is at {d}\n", .{ params_slot, block.name, block.slot }) catch {};
            return error.ShaderFailed;
        }
        params = block;
    }
    if (module.textures.len != slot) {
        problems.writeAll("a material reads TEXTURE and SCREEN_TEXTURE; textures of its own are not here yet\n") catch {};
        return error.ShaderFailed;
    }
    const frame = module.block("Frame") orelse return error.ShaderFailed;
    inline for (.{ .{ "PROJECTION", "projection" }, .{ "SCREEN_PIXEL_SIZE", "screen_pixel_size" }, .{ "TIME", "time" }, .{ "SCREEN_FLIP", "screen_flip" } }) |pair| {
        std.debug.assert(frame.offsetOf(pair[0]).? == @offsetOf(Frame, pair[1]));
    }
    std.debug.assert(frame.size == @sizeOf(Frame));

    const gpu = device.createShader(.{
        .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
        .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
        .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
        .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
        .label = label,
    }) catch |err| {
        problems.print("the graphics driver refused it: {s}\n", .{device.diagnostics()}) catch {};
        return err;
    };
    errdefer device.destroyShader(gpu);

    // Locations and formats come from the shader; only which buffer each is
    // packed into is decided here, by `bufferOf`.
    var attributes: [8]rhi.VertexAttribute = undefined;
    var strides: [2]u32 = @splat(0);
    for (module.attributes, 0..) |a, i| {
        const buffer = bufferOf(a.name);
        const format = vertexFormat(a.ty) orelse return error.ShaderFailed;
        attributes[i] = .{ .location = a.location, .format = format, .offset = strides[buffer], .buffer = buffer };
        strides[buffer] += format.size();
    }

    var pipelines: std.EnumArray(Sprite.Blend, rhi.Pipeline) = .initFill(.none);
    errdefer for (pipelines.values) |pipeline| device.destroyPipeline(pipeline);
    for (std.enums.values(Sprite.Blend)) |blend| {
        pipelines.set(blend, device.createPipeline(.{
            .shader = gpu,
            .attributes = attributes[0..module.attributes.len],
            .buffers = &.{
                .{ .stride = strides[0] },
                .{ .stride = strides[1], .step = .instance },
            },
            .topology = .triangle_strip,
            .blend = switch (blend) {
                .alpha => .alpha,
                .additive => .additive,
            },
            // Both lists come out of the shader, in slot order.
            .uniform_blocks = (try module.uniformBlockNames()) orelse return error.ShaderFailed,
            .textures = (try module.textureNames()) orelse return error.ShaderFailed,
            .label = label,
        }) catch |err| {
            problems.print("the graphics driver refused its pipeline: {s}\n", .{device.diagnostics()}) catch {};
            return err;
        });
    }

    return .{
        .module = module,
        .gpu = gpu,
        .pipelines = pipelines,
        .texture_slot = texture_slot,
        .screen_slot = screen_slot,
        .params = params,
    };
}

/// The compiler's messages, with a line of the engine's part said to be
/// one: a file whose names clash with the engine's is told so, not sent to
/// a line it never wrote.
fn tellOfLines(said: []const u8, engine_line: usize, out: *std.Io.Writer) void {
    var lines = std.mem.splitScalar(u8, said, '\n');
    while (lines.next()) |line| {
        const at = headOf(line);
        if (at) |head| if (head.line >= engine_line) {
            out.print("the engine's part, {d}:{d}:{s}\n", .{ head.line - engine_line + 1, head.column, line[head.len..] }) catch return;
            continue;
        };
        out.print("{s}\n", .{line}) catch return;
    }
}

/// `12:5:` at the start of a message: its line, its column, and how long it is.
pub fn headOf(line: []const u8) ?struct { line: usize, column: usize, len: usize } {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const number = std.fmt.parseInt(usize, line[0..first], 10) catch return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const column = std.fmt.parseInt(usize, rest[0..second], 10) catch return null;
    return .{ .line = number, .column = column, .len = first + 1 + second + 1 };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn testDevice() !rhi.Device {
    return rhi.Device.init(testing.allocator, .{ .backend = .none });
}

test "a file names what it reads, and only that is declared" {
    var device = try testDevice();
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();

    var drawn = try compile(testing.allocator, &device, plain, "plain", &problems.writer);
    defer drawn.deinit(&device);
    try testing.expectEqual(@as(?u32, 0), drawn.texture_slot);
    try testing.expect(!drawn.readsScreen());
    try testing.expect(drawn.params == null);

    var glowing = try compile(testing.allocator, &device,
        \\uniform Look : 1 {
        \\    float strength = 0.25;
        \\}
        \\fragment {
        \\    target = mix(sample(SCREEN_TEXTURE, SCREEN_UV), COLOR, strength + TIME * 0.0);
        \\}
    , "glow", &problems.writer);
    defer glowing.deinit(&device);
    // No TEXTURE named, so none declared; the screen takes the first slot.
    try testing.expectEqual(@as(?u32, null), glowing.texture_slot);
    try testing.expectEqual(@as(?u32, 0), glowing.screen_slot);
    try testing.expect(glowing.readsScreen());
    const look = glowing.params.?;
    try testing.expectEqualStrings("strength", look.fields[0].name);
    try testing.expectEqualSlices(f32, &.{0.25}, look.fields[0].default.?);
}

test "a mistake is at the file's own line, and a clash with the engine's names is said to be one" {
    var device = try testDevice();
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();

    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\fragment {
        \\    vec3 wrong = 1.0 + vec2(1.0);
        \\    target = vec4(1.0);
        \\}
    , "broken", &problems.writer));
    try testing.expect(std.mem.startsWith(u8, problems.written(), "2:"));

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\const float TIME = 1.0;
        \\fragment { target = vec4(TIME); }
    , "clash", &problems.writer));
    try testing.expect(std.mem.indexOf(u8, problems.written(), "the engine's part") != null);

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "trespass", &problems.writer));
    try testing.expect(std.mem.startsWith(u8, problems.written(), "1:1: `vertex` is the engine's"));

    problems.clearRetainingCapacity();
    try testing.expectError(error.ShaderFailed, compile(testing.allocator, &device,
        \\uniform Look : 2 { float strength; }
        \\fragment { target = vec4(strength); }
    , "slot", &problems.writer));
    try testing.expect(std.mem.indexOf(u8, problems.written(), "one uniform block, at slot 1") != null);
}
