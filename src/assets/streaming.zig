// SPDX-License-Identifier: BSD-3-Clause
//! Distance-driven static asset streaming. CPU parsing/decoding/LOD work
//! runs in background_load; the main thread adopts one bounded GPU operation
//! per frame. Packages have <=12k vertices and one material. Resident physics
//! is independent. Shared textures/materials are retained until the last
//! streamed package releases them. Assets that existed before streaming are
//! borrowed and never evicted. Separate load/unload radii and a grace period
//! prevent boundary thrashing. There is no blocking worker join in update.
const std = @import("std");
const ecs = @import("fluxion_ecs");
const math = @import("fluxion_math");
const App = @import("../App.zig");
const components = @import("../scene/components.zig");
const background = @import("background_load.zig");
const mesh = @import("../render/mesh.zig");
const log = std.log.scoped(.fluxion_engine);

pub const Streams = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    resources: std.ArrayListUnmanaged(Resource) = .empty,
    resident_bytes: usize = 0,
    memory_budget: usize = 2 * 1024 * 1024 * 1024,
    max_inflight: usize = 8,
    gpu_budget_ns: i96 = 1_500_000,
    last_ns: i96 = 0,
    max_ns: i96 = 0,
    uploads: usize = 0,
    desired: usize = 0,
    ready: usize = 0,
    lod_meshes: usize = 0,
    last_eye: ?math.Vec3 = null,
    scan_eye: math.Vec3 = .zero,
    scan_frame: u64 = 0,
    scene: @import("scene_table.zig").SceneHandle = .none,

    const Entry = struct {
        key: []u8,
        source: []u8,
        mesh_handle: mesh.MeshHandle = .none,
        owned_mesh: bool = false,
        has_lods: bool = false,
        requested: bool = false,
        failed: bool = false,
        seen: bool = false,
        wanted: bool = false,
        distance: f32 = std.math.inf(f32),
        last_near: f64 = 0,
        bytes: usize = 0,
        dependencies: std.ArrayListUnmanaged(usize) = .empty,
        retained: bool = false,
        users: std.ArrayListUnmanaged(ecs.Entity) = .empty,
    };
    const Resource = struct {
        source: []u8,
        texture: bool,
        owned: bool,
        refs: usize = 0,
        bytes: usize = 0,
    };

    pub fn deinit(self: *Streams, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            gpa.free(entry.key);
            gpa.free(entry.source);
            entry.dependencies.deinit(gpa);
            entry.users.deinit(gpa);
        }
        self.entries.deinit(gpa);
        self.index.deinit(gpa);
        for (self.resources.items) |resource| gpa.free(resource.source);
        self.resources.deinit(gpa);
    }

    fn entryFor(self: *Streams, app: *App, key: []const u8) !usize {
        if (self.index.get(key)) |at| return at;
        if (key.len == 0 or std.mem.startsWith(u8, key, "res://") or std.mem.indexOf(u8, key, "..") != null)
            return error.BadStreamPath;
        const owned = try app.gpa.dupe(u8, key);
        errdefer app.gpa.free(owned);
        const source = try std.mem.concat(app.gpa, u8, &.{ "res://", key });
        errdefer app.gpa.free(source);
        const at = self.entries.items.len;
        try self.entries.append(app.gpa, .{ .key = owned, .source = source });
        errdefer _ = self.entries.pop();
        try self.index.put(app.gpa, owned, at);
        return at;
    }

    fn retain(self: *Streams, app: *App, entry: *Entry, source: []const u8, texture: bool, bytes: usize) !void {
        var at: usize = 0;
        while (at < self.resources.items.len) : (at += 1) {
            const held = &self.resources.items[at];
            if (held.texture == texture and std.mem.eql(u8, held.source, source)) break;
        }
        if (at == self.resources.items.len) {
            const existed = if (texture) app.assets.findTexture(source) != null else app.materials.find(source) != null;
            const copy = try app.gpa.dupe(u8, source);
            errdefer app.gpa.free(copy);
            try self.resources.append(app.gpa, .{ .source = copy, .texture = texture, .owned = !existed, .bytes = bytes });
        }
        try entry.dependencies.append(app.gpa, at);
        const resource = &self.resources.items[at];
        if (resource.refs == 0) {
            // A tool/game may have loaded this asset while no streamed
            // package held it. Re-check ownership rather than steal it.
            resource.owned = if (texture) app.assets.findTexture(source) == null else app.materials.find(source) == null;
            resource.bytes = bytes;
        }
        if (resource.refs == 0 and resource.owned) self.resident_bytes += resource.bytes;
        resource.refs += 1;
    }

    fn release(self: *Streams, app: *App, entry: *Entry) void {
        // Materials first: no retained material ever points at an evicted map.
        for ([_]bool{ false, true }) |texture| {
            for (entry.dependencies.items) |at| {
                const resource = &self.resources.items[at];
                if (resource.texture != texture) continue;
                resource.refs -= 1;
                if (resource.refs != 0 or !resource.owned) continue;
                if (texture) {
                    if (app.assets.findTexture(resource.source)) |handle| app.assets.unload(handle);
                } else if (app.materials.find(resource.source)) |handle| app.unloadMaterial(handle);
                self.resident_bytes -|= resource.bytes;
            }
        }
        entry.dependencies.clearRetainingCapacity();
        entry.retained = false;
    }

    fn evict(self: *Streams, app: *App, entry: *Entry) void {
        if (!entry.mesh_handle.isNone() and entry.owned_mesh) app.unloadMesh(entry.mesh_handle);
        if (entry.has_lods) self.lod_meshes -|= 1;
        entry.has_lods = false;
        entry.mesh_handle = .none;
        bind(app, entry);
        if (!entry.owned_mesh and !entry.retained) return;
        entry.owned_mesh = false;
        var name: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&name, "{s}#material/0", .{entry.source})) |path| {
            if (app.materials.find(path)) |handle| app.unloadMaterial(handle);
        } else |_| {}
        if (app.scenes.find(entry.source)) |handle| app.unloadScene(handle);
        self.resident_bytes -|= entry.bytes;
        entry.bytes = 0;
        self.release(app, entry);
    }

    fn bind(app: *App, entry: *const Entry) void {
        for (entry.users.items) |entity| {
            if (!app.world.isAlive(entity)) continue;
            if (app.world.get(entity, components.MeshInstance3D)) |instance| instance.mesh = entry.mesh_handle;
        }
    }

    /// A progress query only; it never reads files or waits for workers.
    pub fn isReady(self: *const Streams) bool {
        return self.desired == self.ready;
    }

    pub fn update(self: *Streams, app: *App) !void {
        const io = app.io orelse return;
        const started: std.Io.Timestamp = .now(io, .awake);
        defer {
            self.last_ns = started.durationTo(.now(io, .awake)).nanoseconds;
            self.max_ns = @max(self.max_ns, self.last_ns);
        }
        const camera = app.currentCamera3D();
        const eye = if (camera) |entity| app.globalPosition3D(entity) orelse math.Vec3.zero else math.Vec3.zero;
        // Read ahead along movement, with a cap so teleporting does not
        // generate a corridor of irrelevant requests across the map.
        var ahead = eye;
        if (self.last_eye) |old| {
            const motion = eye.sub(old);
            const length = motion.len();
            if (length > 0.0001 and length < 5) ahead = eye.add(motion.scale(@min(12 / length, 0.75 / @max(app.time.unscaled_delta, 0.001))));
        }
        self.last_eye = eye;
        // Spatial classification is cached between ticks. GPU adoption and
        // retirement still progress every frame; camera turns need no rescan.
        if (app.time.frame == 0 or app.time.frame >= self.scan_frame + 6 or eye.sub(self.scan_eye).len() > 2 or !self.scene.eql(app.currentScene())) {
            self.scan_frame = app.time.frame;
            self.scan_eye = eye;
            self.scene = app.currentScene();
            for (self.entries.items) |*entry| {
                entry.seen = false;
                entry.wanted = false;
                entry.distance = std.math.inf(f32);
                entry.users.clearRetainingCapacity();
            }
            var it = try ecs.Query(.{ components.StreamMesh3D, components.MeshInstance3D }).over(&app.world);
            while (it.next()) |chunk| {
                for (chunk.slice(components.StreamMesh3D), chunk.slice(components.MeshInstance3D), chunk.entities) |stream, *instance, entity| {
                    const path = app.textOf(entity, components.StreamMesh3D, "source");
                    const at = self.entryFor(app, path) catch continue;
                    const entry = &self.entries.items[at];
                    entry.seen = true;
                    try entry.users.append(app.gpa, entity);
                    const center = app.globalPosition3D(entity) orelse continue;
                    const distance = @max(0, @min(center.sub(eye).len(), center.sub(ahead).len()) - stream.bounds_radius);
                    entry.distance = @min(entry.distance, distance);
                    if (distance <= stream.load_distance) entry.wanted = true;
                    if (distance <= @max(stream.load_distance, stream.unload_distance)) entry.last_near = app.time.elapsed;
                    instance.mesh = entry.mesh_handle;
                }
            }
        }
        const budget_started: std.Io.Timestamp = .now(io, .awake);
        var victim: ?usize = null;
        for (self.entries.items, 0..) |entry, at| {
            if (!entry.mesh_handle.isNone() and (!entry.seen or app.time.elapsed - entry.last_near > 8)) {
                if (victim == null or entry.distance > self.entries.items[victim.?].distance) victim = at;
            }
        }
        // Evict at most one package in a frame. Resource refcounts keep
        // shared PBR maps alive; scene changes also drain old packages here.
        if (victim) |at| self.evict(app, &self.entries.items[at]);
        // Cached geometry is often cheaper than a frame. Fill the worker
        // queue and adopt several completed operations within the same budget.
        // A hard operation cap also bounds bookkeeping on very fast devices.
        var operation: usize = 0;
        while (operation < 32) : (operation += 1) {
            if (budget_started.durationTo(.now(io, .awake)).nanoseconds >= self.gpu_budget_ns) break;
            self.desired = 0;
            self.ready = 0;
            var inflight: usize = 0;
            var nearest: ?usize = null;
            var finished: ?usize = null;
            for (self.entries.items, 0..) |entry, at| {
                if (entry.wanted) {
                    self.desired += 1;
                    if (!entry.mesh_handle.isNone()) self.ready += 1;
                }
                if (entry.requested) {
                    inflight += 1;
                    if (app.loads.of(entry.source)) |load| {
                        if (load.done() and (finished == null or entry.distance < self.entries.items[finished.?].distance)) finished = at;
                    }
                } else if (entry.wanted and entry.mesh_handle.isNone() and !entry.failed) {
                    if (nearest == null or entry.distance < self.entries.items[nearest.?].distance) nearest = at;
                }
            }
            var progressed = false;
            if (finished) |at| {
                progressed = true;
                const entry = &self.entries.items[at];
                if (!entry.wanted) {
                    _ = background.discardStreaming(app, entry.source);
                    entry.requested = false;
                    if (entry.retained) self.release(app, entry);
                } else {
                    if (!try background.refreshStreamingTextures(app, entry.source)) continue;
                    const load = app.loads.of(entry.source).?;
                    if (!entry.retained and load.failure == null) {
                        var bytes: usize = 0;
                        const held = load.prepared.?.model.meshes[0];
                        bytes += (held.vertices.len * @sizeOf(mesh.Vertex) + held.indices.len * 4) * 2;
                        for (held.lods) |lod| bytes += lod.indices.len * 8;
                        var texture_bytes: usize = 0;
                        for (load.pictures, load.decoded) |source, decoded| {
                            if (app.assets.findTexture(source) != null) continue;
                            if (decoded) |picture| texture_bytes += @as(usize, picture.width) * picture.height * 16 / 3;
                        }
                        if (self.resident_bytes + bytes + texture_bytes > self.memory_budget) return;
                        for (load.pictures, load.decoded) |source, decoded| {
                            const bytes_of_picture = if (decoded) |picture|
                                @as(usize, picture.width) * picture.height * 16 / 3
                            else if (app.assets.findTexture(source)) |handle| cached: {
                                const picture = app.assets.get(handle) orelse continue;
                                break :cached @as(usize, picture.width) * picture.height * 16 / 3;
                            } else continue;
                            try self.retain(app, entry, source, true, bytes_of_picture);
                        }
                        for (load.material_files) |file| try self.retain(app, entry, file.source, false, 0);
                        entry.retained = true;
                        entry.bytes = bytes;
                        self.resident_bytes += bytes;
                    }
                    const committed = background.commitStreaming(app, entry.source) catch |err| failed: {
                        log.warn("stream {s}: {t}", .{ entry.source, err });
                        _ = background.discardStreaming(app, entry.source);
                        entry.requested = false;
                        entry.failed = true;
                        self.evict(app, entry);
                        break :failed false;
                    };
                    self.uploads += 1;
                    if (committed) {
                        var name: [1024]u8 = undefined;
                        const path = try std.fmt.bufPrint(&name, "{s}#mesh/0", .{entry.source});
                        entry.mesh_handle = app.findMesh(path) orelse .none;
                        entry.owned_mesh = true;
                        bind(app, entry);
                        // Meshes normally upload lazily on first visibility.
                        // Prewarm here inside the streaming budget so turning
                        // toward several prefetched packages cannot upload them
                        // all together in the renderer later.
                        if (app.meshes.keptOf(entry.mesh_handle)) |kept| {
                            _ = kept.uploaded(&app.device) catch |err| {
                                log.warn("stream GPU {s}: {t}", .{ entry.source, err });
                                entry.failed = true;
                                self.evict(app, entry);
                                return;
                            };
                        }
                        if (app.meshOf(entry.mesh_handle)) |made| {
                            entry.has_lods = made.lods.len > 0;
                            if (entry.has_lods) self.lod_meshes += 1;
                        }
                        entry.requested = false;
                    }
                }
            }
            if (budget_started.durationTo(.now(io, .awake)).nanoseconds >= self.gpu_budget_ns) break;
            if (nearest) |at| if (inflight < self.max_inflight and self.resident_bytes < self.memory_budget) {
                const entry = &self.entries.items[at];
                var name: [1024]u8 = undefined;
                const path = try std.fmt.bufPrint(&name, "{s}#mesh/0", .{entry.source});
                if (app.findMesh(path)) |cached| {
                    entry.mesh_handle = cached;
                    bind(app, entry);
                    if (app.meshOf(cached)) |made| {
                        entry.has_lods = made.lods.len > 0;
                        if (entry.has_lods) self.lod_meshes += 1;
                    }
                    continue;
                }
                background.startStreaming(app, entry.source) catch |err| {
                    entry.failed = true;
                    log.warn("stream request {s}: {t}", .{ entry.source, err });
                    return;
                };
                entry.requested = true;
                progressed = true;
            };
            if (!progressed) break;
        }
        self.desired = 0;
        self.ready = 0;
        for (self.entries.items) |entry| if (entry.wanted) {
            self.desired += 1;
            if (!entry.mesh_handle.isNone()) self.ready += 1;
        };
    }
};

pub fn update(app: *App) !void {
    try app.streams.update(app);
}
