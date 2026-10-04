// SPDX-License-Identifier: BSD-3-Clause

//! What a 3D camera sees: where it is, which way it looks and how its
//! picture is made - and what follows from that: the matrix the 3D layer
//! draws through, the ray through a pixel, and where a point is on the
//! picture.
//!
//! ```zig
//! const view = app.currentView3D().?;
//! const ray = view.rayThrough(app.pointerPosition());
//! if (view.toScreen(enemy_head)) |at| try app.debug.circle(at, 8, .{});
//! ```
//!
//! An editor looks through one of its own, made with `looking`.

const std = @import("std");
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const Camera3D = @import("render3d_components.zig").Camera3D;
const RenderView = @import("render_components.zig").RenderView;
const Transform3D = @import("../scene/transform3d.zig").Transform3D;
const hierarchy = @import("../scene/hierarchy.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

/// The clip space the sums on the CPU are done in: any would do, as long
/// as they agree with each other.
const cpu_clip: math.Clip = .d3d;

pub const View3D = struct {
    /// The camera's place and turn in the world. Its scale is not the
    /// camera's: a camera under a scaled parent sees as any other.
    position: Vec3 = .zero,
    rotation: math.Quat = .identity,
    projection: Camera3D.Projection = .perspective,
    fov: f32 = std.math.degreesToRadians(75.0),
    size: f32 = 1,
    near: f32 = 0.05,
    far: f32 = 4000,
    /// The picture's size, in pixels: what its shape is, and what a pixel
    /// given to `rayThrough` and taken from `toScreen` is measured in.
    width: f32 = 1,
    height: f32 = 1,
    /// The render layers it sees.
    cull_mask: u32 = 0xFFFF_FFFF,
    /// The `RenderView` this is drawn for, if it is one's.
    render_view: ecs.Entity = .none,

    /// Through `camera`, from where `placed` - all parents applied - is.
    pub fn of(camera: Camera3D, placed: Transform3D, width: f32, height: f32) View3D {
        return .{
            .position = placed.position,
            .rotation = placed.rotation.quat().norm(),
            .projection = camera.projection,
            .fov = camera.fov,
            .size = camera.size,
            .near = camera.near,
            .far = camera.far,
            .width = width,
            .height = height,
            .cull_mask = camera.cull_mask,
        };
    }

    /// From `from`, looking at `target` with `up_hint` as near up as it can be:
    /// an editor's own camera.
    pub fn looking(from: Vec3, target: Vec3, up_hint: Vec3, camera: Camera3D, width: f32, height: f32) View3D {
        var placed: Transform3D = .{ .position = from };
        placed.lookAt(target, up_hint);
        return .of(camera, placed, width, height);
    }

    /// The way it looks: its `-z`.
    pub fn forward(self: View3D) Vec3 {
        return self.rotation.rotate(.init(0, 0, -1));
    }

    pub fn right(self: View3D) Vec3 {
        return self.rotation.rotate(.unit_x);
    }

    pub fn up(self: View3D) Vec3 {
        return self.rotation.rotate(.unit_y);
    }

    /// The camera's own space to the world's.
    pub fn eye(self: View3D) Mat4 {
        return .fromTrs(self.position, self.rotation, .one);
    }

    /// The world to the camera's own space.
    pub fn viewMatrix(self: View3D) Mat4 {
        return self.eye().inverseRigid();
    }

    fn aspect(self: View3D) f32 {
        return if (self.height > 0) self.width / self.height else 1;
    }

    /// The camera's own space to `clip`'s clip space.
    pub fn projectionMatrix(self: View3D, clip: math.Clip) Mat4 {
        const near = @max(self.near, 0.0001);
        const far = @max(self.far, near + 0.0001);
        return switch (self.projection) {
            .perspective => math.perspective(.{
                .fov_y = std.math.clamp(self.fov, 0.001, std.math.pi - 0.001),
                .aspect = self.aspect(),
                .near = near,
                .far = far,
                .clip = clip,
            }),
            .orthogonal => blk: {
                const half_height = @max(self.size, 0.0001) / 2;
                const half_width = half_height * self.aspect();
                break :blk math.orthographic(.{ .left = -half_width, .right = half_width, .bottom = -half_height, .top = half_height, .near = near, .far = far, .clip = clip });
            },
        };
    }

    /// The world to `clip`'s clip space: what the 3D layer draws through.
    pub fn matrix(self: View3D, clip: math.Clip) Mat4 {
        return self.projectionMatrix(clip).mul(self.viewMatrix());
    }

    /// What it can see, as six planes.
    pub fn frustum(self: View3D, clip: math.Clip) math.Frustum {
        return .fromViewProjection(self.matrix(clip), clip);
    }

    /// The ray from the camera through `pixel`, measured from the picture's
    /// top left: what is under a click. It starts at the near plane.
    pub fn rayThrough(self: View3D, pixel: Vec2) math.Ray {
        const inverse = self.matrix(cpu_clip).inverse() orelse return .init(self.position, self.forward());
        return math.Ray.throughPixel(inverse, pixel, self.width, self.height, cpu_clip) orelse .init(self.position, self.forward());
    }

    /// Where `point` is on the picture, in pixels from its top left - or
    /// null when it is behind the camera, and on no picture.
    pub fn toScreen(self: View3D, point: Vec3) ?Vec2 {
        const clipped = self.matrix(cpu_clip).mulVec4(point.point());
        if (clipped.w <= 0.000001 and self.projection == .perspective) return null;
        const w = if (self.projection == .perspective) clipped.w else 1;
        const x = clipped.x / w;
        const y = clipped.y / w;
        return .init((x + 1) / 2 * self.width, (1 - y) / 2 * self.height);
    }

    /// Whether `point` is behind the camera.
    pub fn isBehind(self: View3D, point: Vec3) bool {
        return point.sub(self.position).dot(self.forward()) < 0;
    }

    /// The point `depth` along the camera's way at `pixel`: where a pixel is
    /// that far away.
    pub fn atDepth(self: View3D, pixel: Vec2, depth: f32) Vec3 {
        const ray = self.rayThrough(pixel);
        const along = ray.direction.dot(self.forward());
        if (@abs(along) < 0.000001) return ray.origin;
        // The ray starts at the near plane; depth is from the camera.
        const from_camera = ray.origin.sub(self.position).dot(self.forward());
        return ray.origin.add(ray.direction.scale((depth - from_camera) / along));
    }
};

/// The camera the screen is seen through in 3D: of the cameras that draw no
/// picture of their own, the one that is `current`, or with none any - or
/// null when there is none.
pub fn currentCamera(app: *App) ?ecs.Entity {
    var any: ?ecs.Entity = null;
    var it = ecs.Query(.{ Transform3D, Camera3D }).over(&app.world) catch return null;
    while (it.next()) |chunk| {
        for (chunk.slice(Camera3D), chunk.entities) |camera, entity| {
            if (app.world.has(entity, RenderView)) continue;
            if (camera.current) return entity;
            if (any == null) any = entity;
        }
    }
    return any;
}

/// What a 3D camera sees, with its picture `width` by `height`: drawn where
/// it is this frame.
pub fn viewOf(app: *App, entity: ecs.Entity, width: f32, height: f32) ?View3D {
    const camera = app.world.get(entity, Camera3D) orelse return null;
    const placed = app.drawnTransform3D(entity) orelse return null;
    return .of(camera.*, placed, width, height);
}

/// Make `entity`'s camera the one the screen is seen through: `current`,
/// and every other not.
pub fn makeCurrent(app: *App, entity: ecs.Entity) error{NoCamera}!void {
    if (!app.world.has(entity, Camera3D)) return error.NoCamera;
    var it = ecs.Query(.{Camera3D}).over(&app.world) catch return;
    while (it.next()) |chunk| {
        for (chunk.slice(Camera3D), chunk.entities) |*camera, other| camera.current = other.eql(entity);
    }
}

test "a camera's ray goes through the pixel, and a point comes back to the pixel it is at" {
    var placed: Transform3D = .at(0, 0, 10);
    placed.lookAt(.zero, .unit_y);
    const view: View3D = .of(.{}, placed, 200, 100);

    // The middle looks straight ahead.
    const middle = view.rayThrough(.init(100, 50));
    try testing.expect(middle.direction.approxEql(.init(0, 0, -1)));
    const seen = view.toScreen(.zero).?;
    try testing.expectApproxEqAbs(@as(f32, 100), seen.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50), seen.y, 1e-3);

    // Up and to the right on the picture is up and to the right in the world.
    const corner = view.toScreen(.init(1, 1, 0)).?;
    try testing.expect(corner.x > 100 and corner.y < 50);
    const back = view.rayThrough(corner);
    const along = back.direction.dot(Vec3.init(1, 1, 0).sub(back.origin).norm());
    try testing.expectApproxEqAbs(@as(f32, 1), along, 1e-4);

    try testing.expect(view.toScreen(.init(0, 0, 20)) == null);
    try testing.expect(view.isBehind(.init(0, 0, 20)));
    try testing.expect(!view.isBehind(.zero));
    try testing.expect(view.atDepth(.init(100, 50), 10).approxEql(.zero));
}

test "an orthogonal camera's rays go the same way, its size from bottom to top" {
    const view: View3D = .{ .projection = .orthogonal, .size = 4, .width = 100, .height = 100, .position = .init(0, 0, 5) };
    const left = view.rayThrough(.init(0, 50));
    const right = view.rayThrough(.init(100, 50));
    try testing.expect(left.direction.approxEql(right.direction));
    try testing.expectApproxEqAbs(@as(f32, 4), right.origin.x - left.origin.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 25), view.toScreen(.init(-1, 0, 0)).?.x, 1e-3);
}

test "the screen is seen through the current camera, or any, but never a render view's" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    try testing.expect(currentCamera(app) == null);
    const first = try app.world.spawnWith(.{ Transform3D{}, Camera3D{} });
    const second = try app.world.spawnWith(.{ Transform3D{}, Camera3D{} });
    _ = try app.world.spawnWith(.{ Transform3D{}, Camera3D{ .current = true }, RenderView{} });
    try testing.expect(currentCamera(app) != null);
    try makeCurrent(app, second);
    try testing.expect(currentCamera(app).?.eql(second));
    try testing.expect(!app.world.get(first, Camera3D).?.current);
    try testing.expectError(error.NoCamera, makeCurrent(app, try app.world.spawn()));
}
