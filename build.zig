// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs = b.dependency("fluxion_ecs", .{ .target = target, .optimize = optimize });
    const rhi = b.dependency("fluxion_rhi", .{ .target = target, .optimize = optimize });
    const platform = b.dependency("fluxion_platform", .{ .target = target, .optimize = optimize });
    const image = b.dependency("fluxion_image", .{ .target = target, .optimize = optimize });
    const typeface = b.dependency("fluxion_font", .{ .target = target, .optimize = optimize });
    const shader = b.dependency("fluxion_shader", .{ .target = target, .optimize = optimize });
    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize });
    const id = b.dependency("fluxion_id", .{ .target = target, .optimize = optimize });
    // Without its renderer, which is built below from its source with this
    // package's rhi and shader.
    const debugdraw = b.dependency("fluxion_debugdraw", .{ .target = target, .optimize = optimize, .renderer = false });
    const ui = b.dependency("fluxion_ui", .{ .target = target, .optimize = optimize });
    const json = b.dependency("fluxion_json", .{ .target = target, .optimize = optimize });
    const physics = b.dependency("fluxion_physics", .{ .target = target, .optimize = optimize });
    const reflect = b.dependency("fluxion_reflect", .{ .target = target, .optimize = optimize });
    const script = b.dependency("fluxion_script", .{ .target = target, .optimize = optimize });
    const audio = b.dependency("fluxion_audio", .{ .target = target, .optimize = optimize });

    // The two renderers below are built from their packages' source with this
    // package's rhi, font and shader, so that a `Device` stays one type:
    // fluxion-ui and fluxion-debugdraw pin their own, at commits of their
    // choosing, which need not be this package's.
    const ui_rhi = b.createModule(.{
        .root_source_file = ui.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_ui", .module = ui.module("fluxion_ui") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_font", .module = typeface.module("fluxion_font") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
        },
    });
    const debugdraw_rhi = b.createModule(.{
        .root_source_file = debugdraw.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_debugdraw", .module = debugdraw.module("fluxion_debugdraw") },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
        },
    });

    // Nothing here is lazy, and that is the difference between an engine and
    // the libraries under it. A library keeps its window, its file reading
    // and its renderer behind `lazy` so a consumer never downloads what it
    // does not use; an engine uses all of it by definition, and a game that
    // depends on this wants every one of them.
    const mod = b.addModule("fluxion_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_ecs", .module = ecs.module("fluxion_ecs") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_platform", .module = platform.module("fluxion_platform") },
            .{ .name = "fluxion_image", .module = image.module("fluxion_image") },
            .{ .name = "fluxion_font", .module = typeface.module("fluxion_font") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_id", .module = id.module("fluxion_id") },
            .{ .name = "fluxion_debugdraw", .module = debugdraw.module("fluxion_debugdraw") },
            .{ .name = "fluxion_debugdraw_rhi", .module = debugdraw_rhi },
            .{ .name = "fluxion_ui", .module = ui.module("fluxion_ui") },
            .{ .name = "fluxion_ui_rhi", .module = ui_rhi },
            .{ .name = "fluxion_json", .module = json.module("fluxion_json") },
            .{ .name = "fluxion_physics", .module = physics.module("fluxion_physics") },
            .{ .name = "fluxion_reflect", .module = reflect.module("fluxion_reflect") },
            .{ .name = "fluxion_script", .module = script.module("fluxion_script") },
            .{ .name = "fluxion_audio", .module = audio.module("fluxion_audio") },
        },
    });

    // What the doc comments say of the types' members, for the scripts'
    // compiler to show: see tools/member_docs.zig.
    const member_docs = b.addExecutable(.{
        .name = "member_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/member_docs.zig"),
            .target = b.graph.host,
        }),
    });
    const write_docs = b.addRunArtifact(member_docs);
    const docs_zig = write_docs.addOutputFileArg("member_docs.zig");
    addSources(b, write_docs);
    mod.addAnonymousImport("member_docs", .{ .root_source_file = docs_zig });

    // zig build test
    //
    // Every one of these runs with no window and no GPU: `App.init` with
    // `.headless` opens the `none` backend, which accepts every call and
    // draws none of them, and steps the schedule from a clock the test
    // supplies. A build server has no display and must still be able to say
    // whether the frame is right.
    const tests = b.addTest(.{
        .name = "fluxion-engine-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the engine test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-engine",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
    }{
        .{
            .name = "pong",
            .step = "example-pong",
            .about = "A game: two paddles, a ball, and a scoreboard drawn over them",
        },
        .{
            .name = "creatures",
            .step = "example-creatures",
            .about = "A sprite sheet, animation, and things attached to other things",
        },
        .{
            .name = "crates",
            .step = "example-crates",
            .about = "Rigid bodies: crates, a ramp, a ball on a rod, and a basket that counts",
        },
    };

    const example_step = b.step("examples", "Build every example");
    for (examples) |example| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_engine", .module = mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = exe_mod,
        });
        b.installArtifact(exe);
        example_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);
    }
}

/// Every source file of the engine but its tests, as the arguments of `run`.
fn addSources(b: *std.Build, run: *std.Build.Step.Run) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |err| std.debug.panic("src: {t}", .{err});
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("src: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        const path = b.dupe(entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        run.addFileArg(b.path(b.fmt("src/{s}", .{path})));
    }
}
