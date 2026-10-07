// SPDX-License-Identifier: BSD-3-Clause

//! Navigation meshes as files: what a `NavigationRegion3D` bakes - where an
//! agent's middle may go on the floor, as convex polygons in the region's
//! own space - kept under a `NavMeshHandle`.
//!
//! ```zig
//! const floor = try app.loadNavMesh("res://scenes/office.navmesh");
//! app.world.get(region, fx.NavigationRegion3D).?.navigation_mesh = floor;
//! ```
//!
//! A `.navmesh` is written by `fluxion_navmesh`'s `NavMesh.write`: its
//! magic, the agent it was baked for, then the corners and the polygons.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const navmesh = @import("fluxion_navmesh");

const App = @import("../App.zig");
const Project = @import("../project/Project.zig");
const file_table = @import("../assets/file_table.zig");

pub const NavMesh = navmesh.NavMesh;

/// What a navigation mesh's file ends in.
pub const extension = ".navmesh";

/// A navigation mesh, the way a `TextureHandle` is a picture.
pub const NavMeshHandle = file_table.Handle("NavMeshHandle");

pub const NavMeshes = struct {
    table: Inner = .empty,

    const Inner = id.handle.Table(Entry);

    const Entry = struct {
        source: []u8,
        on_disc: bool,
        mesh: NavMesh,
        /// Counts up each time it is replaced, for what keeps something of it.
        version: u32 = 0,
    };

    fn toId(handle: NavMeshHandle) Inner.Handle {
        return @bitCast(handle);
    }

    fn fromId(handle: Inner.Handle) NavMeshHandle {
        return @bitCast(handle);
    }

    pub fn deinit(self: *NavMeshes, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| free(gpa, entry.value);
        self.table.deinit(gpa);
        self.* = .{};
    }

    fn free(gpa: Allocator, entry: *Entry) void {
        gpa.free(entry.source);
        entry.mesh.deinit(gpa);
    }

    /// Keep `mesh`, which is the table's from here, under `name`: a name
    /// given before gets the new one, and keeps its handle.
    pub fn add(self: *NavMeshes, gpa: Allocator, name: []const u8, mesh: NavMesh) Allocator.Error!NavMeshHandle {
        return self.keep(gpa, name, mesh, false);
    }

    fn keep(self: *NavMeshes, gpa: Allocator, name: []const u8, mesh: NavMesh, on_disc: bool) Allocator.Error!NavMeshHandle {
        if (self.find(name)) |known| {
            const held = self.table.get(toId(known)).?;
            held.mesh.deinit(gpa);
            held.mesh = mesh;
            held.on_disc = on_disc;
            held.version +%= 1;
            return known;
        }
        const source = try gpa.dupe(u8, name);
        errdefer gpa.free(source);
        return fromId(try self.table.add(gpa, .{ .source = source, .on_disc = on_disc, .mesh = mesh }));
    }

    /// The mesh in the `.navmesh` file at `path`, read now unless it was
    /// read before.
    pub fn load(self: *NavMeshes, app: *App, path: []const u8) !NavMeshHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;
        var mesh = try readFile(app, source);
        errdefer mesh.deinit(app.gpa);
        if (Project.isProjectPath(source)) _ = app.project.uidOf(source) catch {};
        return self.keep(app.gpa, source, mesh, true);
    }

    fn readFile(app: *App, source: []const u8) !NavMesh {
        const bytes = try app.project.readFileAlloc(app.gpa, source, .limited(file_table.file_limit));
        defer app.gpa.free(bytes);
        return NavMesh.read(app.gpa, bytes);
    }

    /// Read a mesh's file again. Says whether it had one.
    pub fn reload(self: *NavMeshes, app: *App, handle: NavMeshHandle) !bool {
        const held = self.table.get(toId(handle)) orelse return false;
        if (!held.on_disc) return false;
        const mesh = try readFile(app, held.source);
        held.mesh.deinit(app.gpa);
        held.mesh = mesh;
        held.version +%= 1;
        return true;
    }

    pub fn unload(self: *NavMeshes, gpa: Allocator, handle: NavMeshHandle) void {
        const held = self.table.get(toId(handle)) orelse return;
        free(gpa, held);
        _ = self.table.remove(toId(handle));
    }

    pub fn find(self: *NavMeshes, source: []const u8) ?NavMeshHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn sourceOf(self: *NavMeshes, handle: NavMeshHandle) ?[]const u8 {
        const held = self.table.get(toId(handle)) orelse return null;
        return held.source;
    }

    pub fn get(self: *NavMeshes, handle: NavMeshHandle) ?*const NavMesh {
        const held = self.table.get(toId(handle)) orelse return null;
        return &held.mesh;
    }

    /// How many times the mesh under `handle` has been replaced.
    pub fn versionOf(self: *NavMeshes, handle: NavMeshHandle) u32 {
        const held = self.table.get(toId(handle)) orelse return 0;
        return held.version;
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *NavMeshes, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
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
