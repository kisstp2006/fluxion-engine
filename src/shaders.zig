// SPDX-License-Identifier: BSD-3-Clause

//! Shaders from `.shader` files, and the numbers each `Material` gives the
//! one it names.
//!
//! ```zig
//! const crt = try app.loadShader("res://shaders/crt.shader");
//! try app.world.add(screen, fx.Material{ .shader = crt });
//! try app.setShaderParam(screen, "strength", &.{0.6});
//! ```
//!
//! A `.shader` file is the fragment stage of fluxion-shader's language and
//! what that reads; the engine writes the rest. See `render/material.zig` for
//! what one says and the names it reads.
//!
//! **A `Material` beside a `Sprite`, a `ColorRect` or a `TextureRect` draws
//! it with the shader** instead of as a plain picture. The shader's own
//! uniform block holds its numbers, and what each field starts as is what
//! the file writes after it - `float strength = 0.4;` - until a material
//! says otherwise. The numbers are the app's, kept under the entity and the
//! field's name, as a label's words are: written in a scene as the
//! material's `params`, and from Flux as the material's own fields -
//! `self.entity.get("Material").strength = 0.6`.
//!
//! A file that does not compile keeps its handle, says why in the log, and
//! draws as though it named none, so a scene with a broken shader still
//! shows its sprites.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const rhi = @import("fluxion_rhi");
const shader = @import("fluxion_shader");

const App = @import("App.zig");
const Project = @import("Project.zig");
const attr = @import("attr.zig");
const file_table = @import("file_table.zig");
pub const material = @import("render/material.zig");
/// What an editor asks about a `.shader` file being written.
pub const edit = @import("shader_edit.zig");

const Entity = ecs.Entity;
const log = std.log.scoped(.fluxion_engine);

/// What a shader's file ends in.
pub const extension = ".shader";

/// A `.shader` file, the way a `TextureHandle` is a picture.
pub const ShaderHandle = file_table.Handle("ShaderHandle");

/// What an entity is drawn with, when not as a plain picture: beside a
/// `Sprite`, a `ColorRect` or a `TextureRect`. Its numbers are the app's,
/// under the entity: see `App.setShaderParam`.
pub const Material = extern struct {
    shader: ShaderHandle = .none,

    pub const reflect_name = "Material";
    pub const reflect_fields = .{
        .shader = .{attr.Doc{ .text = "The .shader file it is drawn with; none draws it as it would be without" }},
    };
};

/// One `.shader` file, and what it came to.
pub const Shader = struct {
    /// The path or name it was read by.
    source: []u8,
    on_disc: bool,
    /// The file's text.
    text: []u8 = &.{},
    /// Null when it did not compile.
    compiled: ?material.Compiled = null,
    /// Why it did not, at the file's lines; empty when it did.
    problems: []u8 = &.{},
    /// Counts up each time it is given new text.
    revision: u32 = 0,

    fn deinitContent(self: *Shader, gpa: Allocator, device: *rhi.Device) void {
        if (self.compiled) |*held| held.deinit(device);
        self.compiled = null;
        gpa.free(self.text);
        gpa.free(self.problems);
        self.text = &.{};
        self.problems = &.{};
    }

    /// The fields a material fills: the file's own block's, or none.
    pub fn params(self: *const Shader) []const shader.Field {
        const compiled = self.compiled orelse return &.{};
        const block = compiled.params orelse return &.{};
        return block.fields;
    }
};

const Table = id.handle.Table(Shader);

fn toId(handle: ShaderHandle) Table.Handle {
    return @bitCast(handle);
}

fn fromId(handle: Table.Handle) ShaderHandle {
    return @bitCast(handle);
}

/// Every `.shader` file read, compiled for the 2D layer.
pub const Shaders = struct {
    table: Table = .empty,

    pub fn deinit(self: *Shaders, gpa: Allocator, device: *rhi.Device) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value.deinitContent(gpa, device);
            gpa.free(entry.value.source);
        }
        self.table.deinit(gpa);
    }

    /// Read a `.shader` file, or find the one read from there already.
    pub fn load(self: *Shaders, app: *App, path: []const u8) !ShaderHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_table.file_limit));
        defer app.gpa.free(text);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(app, source, text, true);
    }

    /// A shader from text rather than a file: a test's, or a tool's. A name
    /// given before gets the new text.
    pub fn add(self: *Shaders, app: *App, name: []const u8, text: []const u8) !ShaderHandle {
        if (self.find(name)) |known| {
            try self.setText(app, known, text);
            return known;
        }
        return self.keep(app, name, text, false);
    }

    fn keep(self: *Shaders, app: *App, source: []const u8, text: []const u8, on_disc: bool) !ShaderHandle {
        const name = try app.gpa.dupe(u8, source);
        errdefer app.gpa.free(name);
        var made: Shader = .{ .source = name, .on_disc = on_disc };
        try build(app, &made, text, .say);
        errdefer made.deinitContent(app.gpa, &app.device);
        return fromId(try self.table.add(app.gpa, made));
    }

    /// New text for a shader: an editor's, before it saves. Compiled again,
    /// and what does not compile says why and draws as none.
    pub fn setText(self: *Shaders, app: *App, handle: ShaderHandle, text: []const u8) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchShader;
        var fresh: Shader = .{ .source = held.source, .on_disc = held.on_disc, .revision = held.revision +% 1 };
        try build(app, &fresh, text, .say);
        held.deinitContent(app.gpa, &app.device);
        held.* = fresh;
    }

    /// Text an editor has open and not saved, as it is typed: compiled
    /// again, and when it does not compile, what did last keeps drawing -
    /// a scene does not flash plain at every half-typed word - and the log
    /// is not told. `problems` says why all the same. `reload` goes back to
    /// the file.
    pub fn preview(self: *Shaders, app: *App, handle: ShaderHandle, text: []const u8) !void {
        const held = self.table.get(toId(handle)) orelse return error.NoSuchShader;
        var fresh: Shader = .{ .source = held.source, .on_disc = held.on_disc, .revision = held.revision +% 1 };
        try build(app, &fresh, text, .quiet);
        if (fresh.compiled == null) {
            fresh.compiled = held.compiled;
            held.compiled = null;
        }
        held.deinitContent(app.gpa, &app.device);
        held.* = fresh;
    }

    /// Read a shader's file again. Says whether there was a file to read.
    pub fn reload(self: *Shaders, app: *App, handle: ShaderHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_table.file_limit));
        defer app.gpa.free(text);
        try self.setText(app, handle, text);
        return true;
    }

    /// The handle of a shader read already, by the path or name it was read by.
    pub fn find(self: *Shaders, source: []const u8) ?ShaderHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *const Shaders, handle: ShaderHandle) ?*const Shader {
        return @constCast(&self.table).get(toId(handle));
    }

    /// What a shader compiled to, or null for none, or one that did not.
    pub fn compiledOf(self: *const Shaders, handle: ShaderHandle) ?*const material.Compiled {
        const held = self.get(handle) orelse return null;
        return if (held.compiled) |*compiled| compiled else null;
    }

    pub fn sourceOf(self: *const Shaders, handle: ShaderHandle) ?[]const u8 {
        const held = self.get(handle) orelse return null;
        return held.source;
    }

    /// Let a shader go: what named it draws as though it named none.
    pub fn unload(self: *Shaders, gpa: Allocator, device: *rhi.Device, handle: ShaderHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        held.deinitContent(gpa, device);
        gpa.free(held.source);
        _ = self.table.remove(toId(handle));
    }

    /// The file or folder at `old` is now at `new`: a shader read from under
    /// it is found at its new place.
    pub fn renamed(self: *Shaders, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
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

/// Keep `text` and compile it: what fails is kept to be asked for, and
/// said in the log unless `quiet`.
fn build(app: *App, into: *Shader, text: []const u8, tell: enum { say, quiet }) !void {
    const gpa = app.gpa;
    into.text = try gpa.dupe(u8, text);
    errdefer gpa.free(into.text);
    var problems: std.Io.Writer.Allocating = .init(gpa);
    defer problems.deinit();
    into.compiled = material.compile(gpa, &app.device, text, into.source, &problems.writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            if (tell == .say) {
                const placed = try withPlaces(gpa, into.source, problems.written());
                defer gpa.free(placed);
                log.warn("{s} did not compile:\n{s}", .{ into.source, placed });
            }
            break :blk null;
        },
    };
    into.problems = try gpa.dupe(u8, problems.written());
}

/// A compiler's messages with where each is under it, `--> path:line:column`,
/// as a script's are, for an editor to take a click on it there.
fn withPlaces(gpa: Allocator, source: []const u8, said: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var place: ?[2]usize = null;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, said, "\n"), '\n');
    while (lines.next()) |line| {
        if (material.headOf(line)) |head| {
            if (place) |at| out.writer.print("  --> {s}:{d}:{d}\n", .{ source, at[0], at[1] }) catch return error.OutOfMemory;
            place = .{ head.line, head.column };
        }
        out.writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
    }
    if (place) |at| out.writer.print("  --> {s}:{d}:{d}\n", .{ source, at[0], at[1] }) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

test "a compiler's messages are told with where each is, as a script's" {
    const placed = try withPlaces(testing.allocator, "res://a.shader", "2:5: wrong\n    x\n    ^\n3:1: also\n");
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings("2:5: wrong\n    x\n    ^\n  --> res://a.shader:2:5\n3:1: also\n  --> res://a.shader:3:1\n", placed);
}

/// A number a material gives its shader, by the name of the field it fills.
pub const Param = struct {
    name: []u8,
    /// A float per component; a matrix column by column.
    numbers: [16]f32 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const Param) []const f32 {
        return self.numbers[0..self.len];
    }
};

/// The numbers each entity's material gives its shader, kept beside the
/// world as its words are, and gone with it.
pub const Params = struct {
    map: std.AutoHashMapUnmanaged(Entity, std.ArrayListUnmanaged(Param)) = .empty,

    pub fn deinit(self: *Params, gpa: Allocator) void {
        self.clear(gpa);
        self.map.deinit(gpa);
    }

    /// Every number an entity gives, in the order it was first given.
    pub fn of(self: *const Params, entity: Entity) []const Param {
        const held = self.map.getPtr(entity) orelse return &.{};
        return held.items;
    }

    pub fn get(self: *const Params, entity: Entity, name: []const u8) ?[]const f32 {
        for (self.of(entity)) |*param| {
            if (std.mem.eql(u8, param.name, name)) return param.slice();
        }
        return null;
    }

    /// Give a field `numbers` - at most sixteen - or, for none, what the
    /// file says again.
    pub fn set(self: *Params, gpa: Allocator, entity: Entity, name: []const u8, numbers: []const f32) Allocator.Error!void {
        const slot = try self.map.getOrPut(gpa, entity);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        const list = slot.value_ptr;
        for (list.items, 0..) |*param, index| {
            if (!std.mem.eql(u8, param.name, name)) continue;
            if (numbers.len == 0) {
                gpa.free(param.name);
                _ = list.orderedRemove(index);
            } else fill(param, numbers);
            return;
        }
        if (numbers.len == 0) return;
        var made: Param = .{ .name = try gpa.dupe(u8, name) };
        errdefer gpa.free(made.name);
        fill(&made, numbers);
        try list.append(gpa, made);
    }

    fn fill(param: *Param, numbers: []const f32) void {
        const len = @min(numbers.len, param.numbers.len);
        @memcpy(param.numbers[0..len], numbers[0..len]);
        param.len = @intCast(len);
    }

    /// Forget every number an entity gives.
    pub fn clearOf(self: *Params, gpa: Allocator, entity: Entity) void {
        var gone = self.map.fetchRemove(entity) orelse return;
        freeList(gpa, &gone.value);
    }

    /// Let go of what the dead gave. Once a frame.
    pub fn forgetDead(self: *Params, gpa: Allocator, world: *const ecs.World) void {
        var dead: std.ArrayList(Entity) = .empty;
        defer dead.deinit(gpa);
        var it = self.map.keyIterator();
        while (it.next()) |entity| {
            if (!world.isAlive(entity.*)) dead.append(gpa, entity.*) catch break;
        }
        for (dead.items) |entity| self.clearOf(gpa, entity);
    }

    pub fn clear(self: *Params, gpa: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| freeList(gpa, list);
        self.map.clearRetainingCapacity();
    }

    fn freeList(gpa: Allocator, list: *std.ArrayListUnmanaged(Param)) void {
        for (list.items) |param| gpa.free(param.name);
        list.deinit(gpa);
    }
};

/// How many floats a field of this type is given as.
pub fn componentsOf(ty: shader.Type) u32 {
    return switch (ty) {
        .float, .int, .bool => 1,
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
        .mat2 => 4,
        .mat3 => 9,
        .mat4 => 16,
        else => 0,
    };
}

/// A block's bytes, as its uniform buffer holds them: each field as the file
/// says it starts, and then as `given` says, where it says.
pub fn pack(block: shader.Block, given: []const Param, out: []u8) void {
    @memset(out[0..block.size], 0);
    for (block.fields) |field| {
        var numbers: [16]f32 = @splat(0);
        const count = componentsOf(field.ty);
        if (field.default) |first| @memcpy(numbers[0..@min(first.len, count)], first[0..@min(first.len, count)]);
        for (given) |*param| {
            if (!std.mem.eql(u8, param.name, field.name)) continue;
            const len = @min(param.len, count);
            @memcpy(numbers[0..len], param.numbers[0..len]);
        }
        write(field.ty, numbers[0..count], out[field.offset..]);
    }
}

fn write(ty: shader.Type, numbers: []const f32, out: []u8) void {
    switch (ty) {
        .int, .bool => std.mem.writeInt(i32, out[0..4], @intFromFloat(std.math.clamp(@round(numbers[0]), -2147483648.0, 2147483520.0)), .little),
        .mat2, .mat3, .mat4 => {
            // A register a column.
            const size: usize = if (ty == .mat2) 2 else if (ty == .mat3) 3 else 4;
            for (0..size) |column| {
                for (0..size) |row| {
                    const at = column * 16 + row * 4;
                    std.mem.writeInt(u32, out[at..][0..4], @bitCast(numbers[column * size + row]), .little);
                }
            }
        },
        else => for (numbers, 0..) |number, index| {
            std.mem.writeInt(u32, out[index * 4 ..][0..4], @bitCast(number), .little);
        },
    }
}

test "a material's numbers are the file's first values, then its own" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var problems: std.Io.Writer.Allocating = .init(testing.allocator);
    defer problems.deinit();
    var compiled = try material.compile(testing.allocator, &device,
        \\uniform Look : 1 {
        \\    float strength = 0.25;
        \\    vec4 glow = vec4(1.0, 0.5, 0.0, 1.0);
        \\    int steps = 3;
        \\}
        \\fragment { target = sample(TEXTURE, UV) * glow * strength * float(steps); }
    , "look", &problems.writer);
    defer compiled.deinit(&device);
    const block = compiled.params.?;

    var params: Params = .{};
    defer params.deinit(testing.allocator);
    const e: Entity = .{ .index = 1, .generation = 1 };
    try params.set(testing.allocator, e, "glow", &.{ 0, 1, 0, 1 });
    try params.set(testing.allocator, e, "steps", &.{5});

    var bytes: [64]u8 = undefined;
    pack(block, params.of(e), &bytes);
    const floats = std.mem.bytesAsSlice(f32, bytes[0..block.size]);
    // Its own glow, the file's strength, its own steps as a whole number.
    try testing.expectEqual(@as(f32, 0.25), floats[block.offsetOf("strength").? / 4]);
    try testing.expectEqual(@as(f32, 1), floats[block.offsetOf("glow").? / 4 + 1]);
    try testing.expectEqual(@as(f32, 0), floats[block.offsetOf("glow").? / 4]);
    try testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bytes[block.offsetOf("steps").?..][0..4], .little));

    // Given nothing again, the file's own.
    try params.set(testing.allocator, e, "glow", &.{});
    pack(block, params.of(e), &bytes);
    try testing.expectEqual(@as(f32, 1), std.mem.bytesAsSlice(f32, bytes[0..block.size])[block.offsetOf("glow").? / 4]);
    try testing.expectEqual(@as(usize, 1), params.of(e).len);
}
