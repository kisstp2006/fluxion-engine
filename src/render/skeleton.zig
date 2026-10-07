// SPDX-License-Identifier: BSD-3-Clause

//! Skeletons: the bones a mesh is bent by. A skeleton is kept by the app
//! under a `SkeletonHandle` - a model's, read with it as
//! `res://robot.glb#skeleton/0`, a `.skeleton` file's, or one made in code -
//! and a `Skeleton3D` holds one, with a pose of its own: where each of its
//! bones is now, as an animation or a script left it.
//!
//! ```zig
//! const robot = try app.instantiate("res://robot.glb", .none);
//! const body = app.findPath(robot, "Armature").?;
//! const arm = app.findBone(body, "UpperArm.L");
//! app.setBoneRotation(body, @intCast(arm), .fromAxisAngle(.unit_z, 0.5));
//! ```
//!
//! **A bone** has a name, a parent - another bone, or none for one at the
//! root of the skeleton, in the space of the entity its `Skeleton3D` is on -
//! a place, turn and size from that parent at rest, and its inverse bind
//! matrix: what takes a vertex from where the mesh was made to the bone's own
//! space. **A mesh it bends** is a `MeshInstance3D` whose `skeleton` names
//! that entity: it is drawn in the entity's space, each vertex moved by its
//! bones' places now times their inverse bind matrices. **A bone's bones
//! are not entities**: a skeleton of a hundred bones is one entity. What
//! hangs from a bone - a hand's prop, a hat - is an entity with a
//! `BoneAttachment3D` under the skeleton's, which the engine moves to the
//! bone each frame.
//!
//! A `.skeleton` file is JSON:
//!
//! ```json
//! { "fluxion_skeleton": 1,
//!   "bones": [
//!     { "name": "Hips", "position": [0, 1, 0] },
//!     { "name": "Spine", "parent": 0, "position": [0, 0.2, 0], "rotation": [0, 0, 0, 1],
//!       "scale": [1, 1, 1], "inverse_bind": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1.2, 0, 1] } ] }
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const attr = @import("../reflect/attr.zig");
const file_table = @import("../assets/file_table.zig");
const property = @import("../reflect/property.zig");
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const Rotation = @import("../scene/transform3d.zig").Rotation;

const Entity = ecs.Entity;
const Mat4 = math.Mat4;

/// What a skeleton's file ends in.
pub const extension = ".skeleton";

/// A skeleton, the way a `MeshHandle` is a mesh.
pub const SkeletonHandle = file_table.Handle("SkeletonHandle");

/// How long a bone's name may be where a component holds one.
pub const name_len = property.Value.name_len;

pub const Bone = struct {
    name: []const u8,
    /// Its parent's place in the list, or none for a bone at the root.
    parent: ?u16 = null,
    /// Where it is from its parent at rest.
    rest: math.Transform = .{},
    /// What takes a vertex from where a mesh it bends was made to the
    /// bone's own space.
    inverse_bind: Mat4 = .identity,
};

/// Bones, each with its parent before it in `order`.
pub const Skeleton = struct {
    bones: []Bone,
    /// Every bone's place, each parent before its children: the order a
    /// pose is worked out in.
    order: []u16,
    /// Each bone's place by its name; the first of two of one name.
    names: std.StringHashMapUnmanaged(u16) = .empty,

    /// A skeleton of copies of `bones`. `error.BadSkeleton` for more than
    /// `max_bones` of them, a parent past them, or a parent that is its own
    /// ancestor.
    pub fn init(gpa: Allocator, bones: []const Bone) (Allocator.Error || error{BadSkeleton})!Skeleton {
        if (bones.len > max_bones) return error.BadSkeleton;
        const own = try gpa.alloc(Bone, bones.len);
        var named: usize = 0;
        errdefer {
            for (own[0..named]) |bone| gpa.free(bone.name);
            gpa.free(own);
        }
        for (bones, own) |bone, *out| {
            if (bone.parent) |parent| if (parent >= bones.len) return error.BadSkeleton;
            out.* = bone;
            out.name = try gpa.dupe(u8, bone.name);
            named += 1;
        }
        const order = try orderOf(gpa, own);
        errdefer gpa.free(order);
        var names: std.StringHashMapUnmanaged(u16) = .empty;
        errdefer names.deinit(gpa);
        for (own, 0..) |bone, at| {
            const entry = try names.getOrPut(gpa, bone.name);
            if (!entry.found_existing) entry.value_ptr.* = @intCast(at);
        }
        return .{ .bones = own, .order = order, .names = names };
    }

    pub fn deinit(self: *Skeleton, gpa: Allocator) void {
        self.names.deinit(gpa);
        for (self.bones) |bone| gpa.free(bone.name);
        gpa.free(self.bones);
        gpa.free(self.order);
        self.* = undefined;
    }

    /// The place of the bone called `name`, if there is one.
    pub fn find(self: *const Skeleton, name: []const u8) ?u16 {
        return self.names.get(name);
    }

    /// Each bone's place from the skeleton's root, at rest.
    pub fn restGlobals(self: *const Skeleton, out: []Mat4) void {
        for (self.order) |at| {
            const bone = self.bones[at];
            const local = bone.rest.toMat4();
            out[at] = if (bone.parent) |parent| out[parent].mul(local) else local;
        }
    }
};

/// The most bones a skeleton may have: what a mesh's vertex can name.
pub const max_bones = @import("mesh.zig").max_bones;

/// Each parent before its children; `error.BadSkeleton` where a parent is
/// its own ancestor.
fn orderOf(gpa: Allocator, bones: []const Bone) (Allocator.Error || error{BadSkeleton})![]u16 {
    const order = try gpa.alloc(u16, bones.len);
    errdefer gpa.free(order);
    const placed = try gpa.alloc(bool, bones.len);
    defer gpa.free(placed);
    @memset(placed, false);
    var count: usize = 0;
    while (count < bones.len) {
        const before = count;
        for (bones, 0..) |bone, at| {
            if (placed[at]) continue;
            if (bone.parent) |parent| if (!placed[parent]) continue;
            placed[at] = true;
            order[count] = @intCast(at);
            count += 1;
        }
        if (count == before) return error.BadSkeleton;
    }
    return order;
}

// -------------------------------------------------------------------------
// The file
// -------------------------------------------------------------------------

const header = "fluxion_skeleton";
const version = 1;

const FileBone = struct {
    name: []const u8 = "",
    parent: ?u32 = null,
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    inverse_bind: [16]f32 = Mat4.identity.array(),
};

const File = struct {
    fluxion_skeleton: u32 = 0,
    bones: []const FileBone = &.{},
};

/// A `.skeleton` file's text as a skeleton, the caller's. `error.BadSkeleton`
/// for one that is not one.
pub fn read(gpa: Allocator, text: []const u8) (Allocator.Error || error{BadSkeleton})!Skeleton {
    const parsed = json.parseAs(File, gpa, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadSkeleton,
    };
    defer parsed.deinit();
    const file = parsed.value;
    if (file.fluxion_skeleton != version) return error.BadSkeleton;
    const bones = try gpa.alloc(Bone, file.bones.len);
    defer gpa.free(bones);
    for (file.bones, bones) |given, *out| {
        if (given.parent) |parent| if (parent > std.math.maxInt(u16)) return error.BadSkeleton;
        out.* = .{
            .name = given.name,
            .parent = if (given.parent) |parent| @intCast(parent) else null,
            .rest = .{
                .translation = .fromArray(given.position),
                .rotation = (math.Quat{ .x = given.rotation[0], .y = given.rotation[1], .z = given.rotation[2], .w = given.rotation[3] }).norm(),
                .scale = .fromArray(given.scale),
            },
            .inverse_bind = .fromArray(given.inverse_bind),
        };
    }
    return Skeleton.init(gpa, bones);
}

/// A skeleton as a `.skeleton` file's text, the caller's.
pub fn write(gpa: Allocator, skeleton: Skeleton) Allocator.Error![]u8 {
    const bones = try gpa.alloc(FileBone, skeleton.bones.len);
    defer gpa.free(bones);
    for (skeleton.bones, bones) |bone, *out| {
        const r = bone.rest.rotation;
        out.* = .{
            .name = bone.name,
            .parent = if (bone.parent) |parent| parent else null,
            .position = bone.rest.translation.array(),
            .rotation = .{ r.x, r.y, r.z, r.w },
            .scale = bone.rest.scale.array(),
            .inverse_bind = bone.inverse_bind.array(),
        };
    }
    return json.stringify(gpa, File{ .fluxion_skeleton = version, .bones = bones }, .{ .indent = 2 }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

// -------------------------------------------------------------------------
// The app's skeletons
// -------------------------------------------------------------------------

/// Every skeleton read or made, under its handle.
pub const Skeletons = struct {
    table: Inner = .empty,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        source: []u8,
        on_disc: bool,
        skeleton: Skeleton,
        /// Counts up each time it is replaced: a pose made for the one
        /// before is made again.
        version: u32 = 0,
    };

    fn toId(handle: SkeletonHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) SkeletonHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *Skeletons, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value.source);
            entry.value.skeleton.deinit(gpa);
        }
        self.table.deinit(gpa);
        self.* = .{};
    }

    /// Keep `skeleton`, which is the table's from here, under `name`: a
    /// name given before gets the new one, and keeps its handle.
    pub fn add(self: *Skeletons, gpa: Allocator, name: []const u8, skeleton: Skeleton) Allocator.Error!SkeletonHandle {
        return self.keep(gpa, name, skeleton, false);
    }

    fn keep(self: *Skeletons, gpa: Allocator, name: []const u8, skeleton: Skeleton, on_disc: bool) Allocator.Error!SkeletonHandle {
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.skeleton.deinit(gpa);
            held.skeleton = skeleton;
            held.on_disc = on_disc;
            held.version +%= 1;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .skeleton = skeleton }));
    }

    /// The skeleton in the `.skeleton` file at `path`, read now unless it
    /// was read before.
    pub fn load(self: *Skeletons, app: *App, path: []const u8) !SkeletonHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        var skeleton = try readFile(app, source);
        errdefer skeleton.deinit(app.gpa);
        if (Project.isProjectPath(source)) _ = app.project.uidOf(source) catch {};
        return self.keep(app.gpa, source, skeleton, true);
    }

    fn readFile(app: *App, source: []const u8) !Skeleton {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return read(app.gpa, bytes);
    }

    /// Read a skeleton's file again. Says whether it had one.
    pub fn reload(self: *Skeletons, app: *App, handle: SkeletonHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const skeleton = try readFile(app, held.source);
        held.skeleton.deinit(app.gpa);
        held.skeleton = skeleton;
        held.version +%= 1;
        return true;
    }

    pub fn unload(self: *Skeletons, gpa: Allocator, handle: SkeletonHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        gpa.free(held.source);
        held.skeleton.deinit(gpa);
        _ = self.table.remove(toId(handle));
    }

    pub fn find(self: *Skeletons, source: []const u8) ?SkeletonHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *Skeletons, handle: SkeletonHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn get(self: *Skeletons, handle: SkeletonHandle) ?*const Skeleton {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.skeleton;
    }

    /// How many times the skeleton under `handle` has been replaced.
    pub fn versionOf(self: *Skeletons, handle: SkeletonHandle) u32 {
        const held = self.table.get(toId(handle)) orelse return 0;
        return held.version;
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Skeletons, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
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
// The components
// -------------------------------------------------------------------------

/// A skeleton on its entity, posed: the bones a `MeshInstance3D` whose
/// `skeleton` names this entity is bent by, in this entity's space. Its pose
/// starts at rest, and is what an `AnimationPlayer`'s bone tracks and
/// `App.setBonePosition` and the rest leave it.
pub const Skeleton3D = extern struct {
    /// A model's skeleton, a `.skeleton` file, or one made in code:
    /// `App.addSkeleton`.
    skeleton: SkeletonHandle = .none,
    /// Whether its bones are drawn over the picture, each a line to its
    /// parent, while the debug drawing is shown.
    show_bones: bool = false,

    pub const reflect_name = "Skeleton3D";
    pub const reflect_fields = .{
        .skeleton = .{attr.Doc{ .text = "The bones: a model's skeleton or a .skeleton file" }},
        .show_bones = .{attr.Doc{ .text = "Whether its bones are drawn, each a line to its parent, with the debug drawing" }},
    };
};

/// An entity that hangs from a bone: under an entity with a `Skeleton3D`,
/// moved to the bone called `bone` each frame - its `Transform3D` is the
/// bone's place in the skeleton's space. What hangs under it moves with it:
/// a prop in a hand, a hat on a head.
pub const BoneAttachment3D = extern struct {
    bone: [name_len]u8 = @splat(0),

    pub const reflect_name = "BoneAttachment3D";
    pub const reflect_fields = .{
        .bone = .{attr.Doc{ .text = "The bone it hangs from, by its name, of the skeleton of the entity it is under" }},
    };

    /// One that hangs from the bone called `name`.
    pub fn of(name: []const u8) BoneAttachment3D {
        var out: BoneAttachment3D = .{};
        @memcpy(out.bone[0..@min(name.len, name_len)], name[0..@min(name.len, name_len)]);
        return out;
    }

    pub fn boneName(self: *const BoneAttachment3D) []const u8 {
        return std.mem.sliceTo(&self.bone, 0);
    }
};

// -------------------------------------------------------------------------
// Poses
// -------------------------------------------------------------------------

/// Where each bone of one `Skeleton3D` is now.
pub const Pose = struct {
    skeleton: SkeletonHandle,
    /// Of the skeleton, when the pose was made for it.
    version: u32,
    /// Each bone's place from its parent, as it was left.
    locals: []math.Transform,
    /// Each bone's place in the skeleton's space, worked out from `locals`
    /// whenever one moved.
    globals: []Mat4,
    /// Counts up each time a bone moves: what keeps something drawn of the
    /// pose - a shadow - knows to draw it again.
    revision: u32 = 0,
    stale: bool = true,

    fn deinit(self: *Pose, gpa: Allocator) void {
        gpa.free(self.locals);
        gpa.free(self.globals);
    }

    /// Bone `bone` moved: the globals are worked out again when next asked.
    pub fn moved(self: *Pose) void {
        self.stale = true;
        self.revision +%= 1;
    }
};

/// Every `Skeleton3D`'s pose, beside the world.
pub const Poses = struct {
    of_entity: std.AutoArrayHashMapUnmanaged(Entity, Pose) = .empty,

    pub fn deinit(self: *Poses, gpa: Allocator) void {
        for (self.of_entity.values()) |*pose| pose.deinit(gpa);
        self.of_entity.deinit(gpa);
    }

    pub fn clear(self: *Poses, app: *App) void {
        for (self.of_entity.values()) |*pose| pose.deinit(app.gpa);
        self.of_entity.clearRetainingCapacity();
    }

    pub fn forgetDead(self: *Poses, app: *App) void {
        var at = self.of_entity.count();
        while (at > 0) {
            at -= 1;
            const entity = self.of_entity.keys()[at];
            if (app.world.isAlive(entity) and app.world.get(entity, Skeleton3D) != null) continue;
            self.of_entity.values()[at].deinit(app.gpa);
            self.of_entity.swapRemoveAt(at);
        }
    }

    /// The pose of `entity`'s `Skeleton3D`, made at rest the first time it
    /// is asked for and whenever its skeleton changed; null where it has no
    /// `Skeleton3D`, or its skeleton is not there.
    pub fn of(self: *Poses, app: *App, entity: Entity) ?*Pose {
        const component = app.world.get(entity, Skeleton3D) orelse return null;
        const skeleton = app.skeletons.get(component.skeleton) orelse return null;
        const now = app.skeletons.versionOf(component.skeleton);
        const entry = self.of_entity.getOrPut(app.gpa, entity) catch return null;
        if (entry.found_existing) {
            const held = entry.value_ptr;
            if (held.skeleton.eql(component.skeleton) and held.version == now and held.locals.len == skeleton.bones.len) return held;
            held.deinit(app.gpa);
        }
        const made = makePose(app.gpa, component.skeleton, now, skeleton) catch {
            self.of_entity.swapRemoveAt(entry.index);
            return null;
        };
        entry.value_ptr.* = made;
        return entry.value_ptr;
    }

    /// Each bone's place in the skeleton's space, worked out now if a bone
    /// moved since.
    pub fn globalsOf(self: *Poses, app: *App, entity: Entity) ?[]const Mat4 {
        const pose = self.of(app, entity) orelse return null;
        const skeleton = app.skeletons.get(pose.skeleton).?;
        if (pose.stale) {
            for (skeleton.order) |at| {
                const local = pose.locals[at].toMat4();
                pose.globals[at] = if (skeleton.bones[at].parent) |parent| pose.globals[parent].mul(local) else local;
            }
            pose.stale = false;
        }
        return pose.globals;
    }
};

fn makePose(gpa: Allocator, handle: SkeletonHandle, now: u32, skeleton: *const Skeleton) Allocator.Error!Pose {
    const locals = try gpa.alloc(math.Transform, skeleton.bones.len);
    errdefer gpa.free(locals);
    for (skeleton.bones, locals) |bone, *local| local.* = bone.rest;
    const globals = try gpa.alloc(Mat4, skeleton.bones.len);
    return .{ .skeleton = handle, .version = now, .locals = locals, .globals = globals };
}

/// Every `BoneAttachment3D` moved to its bone, the poses worked out where
/// bones moved: once after the animations, so the scripts find them where
/// they are, and once before the frame is drawn, for what the scripts
/// moved.
pub fn update(app: *App) !void {
    var it = try ecs.Query(.{ BoneAttachment3D, Transform3D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(BoneAttachment3D), chunk.slice(Transform3D), chunk.entities) |*attached, *transform, entity| {
            const parent = app.parentOf(entity);
            if (parent.isNone()) continue;
            const pose = app.poses.of(app, parent) orelse continue;
            const skeleton = app.skeletons.get(pose.skeleton).?;
            const bone = skeleton.find(attached.boneName()) orelse continue;
            const globals = app.poses.globalsOf(app, parent).?;
            const placed = math.Transform.fromMat4(globals[bone]);
            transform.position = placed.translation;
            transform.rotation = .of(placed.rotation);
            transform.scale = placed.scale;
        }
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Three bones up the y axis, a unit apart, the third a sibling of the
/// second.
fn threeBones() [3]Bone {
    return .{
        .{ .name = "Hips", .rest = .{ .translation = .init(0, 1, 0) } },
        .{ .name = "Spine", .parent = 0, .rest = .{ .translation = .init(0, 1, 0) }, .inverse_bind = .fromTranslation(.init(0, -2, 0)) },
        .{ .name = "Tail", .parent = 0, .rest = .{ .translation = .init(0, -0.5, 0) } },
    };
}

test "a skeleton orders its bones parents first, finds one by its name, and refuses a loop" {
    var bones = threeBones();
    // Listed child before parent: worked out in the other order.
    bones[0].parent = 1;
    bones[1].parent = null;
    var skeleton = try Skeleton.init(testing.allocator, &bones);
    defer skeleton.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), skeleton.order[0]);
    try testing.expectEqual(@as(?u16, 2), skeleton.find("Tail"));
    try testing.expect(skeleton.find("Head") == null);
    var globals: [3]Mat4 = undefined;
    skeleton.restGlobals(&globals);
    try testing.expect(globals[0].translation().approxEql(.init(0, 2, 0)));

    bones[1].parent = 0;
    try testing.expectError(error.BadSkeleton, Skeleton.init(testing.allocator, &bones));
    bones[1].parent = 9;
    try testing.expectError(error.BadSkeleton, Skeleton.init(testing.allocator, &bones));
}

test "a skeleton's file reads back as it was written, and one that is not one is refused" {
    var skeleton = try Skeleton.init(testing.allocator, &threeBones());
    defer skeleton.deinit(testing.allocator);
    skeleton.bones[2].rest.rotation = .fromAxisAngle(.unit_z, 0.5);
    const text = try write(testing.allocator, skeleton);
    defer testing.allocator.free(text);
    var back = try read(testing.allocator, text);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), back.bones.len);
    try testing.expectEqualStrings("Spine", back.bones[1].name);
    try testing.expectEqual(@as(?u16, 0), back.bones[1].parent);
    try testing.expect(back.bones[1].inverse_bind.translation().approxEql(.init(0, -2, 0)));
    try testing.expectApproxEqAbs(skeleton.bones[2].rest.rotation.z, back.bones[2].rest.rotation.z, 1e-6);

    try testing.expectError(error.BadSkeleton, read(testing.allocator, "{ \"bones\": [] }"));
    try testing.expectError(error.BadSkeleton, read(testing.allocator, "not json"));
    try testing.expectError(error.BadSkeleton, read(testing.allocator, "{ \"fluxion_skeleton\": 1, \"bones\": [{ \"parent\": 3 }] }"));
}
