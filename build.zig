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
    const vfs = b.dependency("fluxion_vfs", .{ .target = target, .optimize = optimize });

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
            .{ .name = "fluxion_vfs", .module = vfs.module("fluxion_vfs") },
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

    // The program a game is shipped as: see runtime/main.zig. On Android it
    // is the library the platform's activity loads, the APK's libmain.so.
    // A release build on Windows opens a window and no console; the export
    // can still turn a game's into one with a console.
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_engine", .module = mod }},
    });
    const android = target.result.abi.isAndroid();
    const runtime = if (android)
        b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = runtime_mod })
    else
        b.addExecutable(.{ .name = "fluxion-runtime", .root_module = runtime_mod });
    if (android) useAndroidNdk(b, runtime, b.option([]const u8, "android-ndk", "The Android NDK, for a build for Android (default: ANDROID_NDK_HOME, then the newest in the Android SDK's ndk folder)"));
    if (target.result.os.tag == .windows and optimize != .Debug) runtime.subsystem = .windows;
    b.installArtifact(runtime);
    test_step.dependOn(&runtime.step);

    // The notices the libraries built into the runtime ask a program made
    // from them to carry - what an export writes beside a game as
    // LICENSES.txt - a file each. The runtime's own licence asks for none,
    // and nor do the Boost licence and CC0 the rest are under.
    const notices = b.addWriteFiles();
    _ = notices.addCopyFile(b.path("LICENSE"), "fluxion-engine.txt");
    const noticed = [_]struct { []const u8, *std.Build.Dependency }{
        .{ "fluxion-ecs", ecs },         .{ "fluxion-rhi", rhi },             .{ "fluxion-image", image },
        .{ "fluxion-font", typeface },   .{ "fluxion-debugdraw", debugdraw }, .{ "fluxion-ui", ui },
        .{ "fluxion-physics", physics }, .{ "fluxion-script", script },       .{ "fluxion-vfs", vfs },
    };
    for (noticed) |entry| _ = notices.addCopyFile(entry[1].path("LICENSE"), b.fmt("{s}.txt", .{entry[0]}));
    _ = notices.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path orelse ".", "..", "LICENSE" }) }, "zig-standard-library.txt");
    b.addNamedLazyPath("notices", notices.getDirectory());

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
    // An Android program is the runtime's library: none of these is one.
    if (!android) for (examples) |example| {
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
        // The tests compile them too, so a change to the engine that breaks
        // one is found where the change is made.
        test_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);
    };
}

/// The lowest Android the runtime is for: 10. The platform's activity is
/// compiled for it too.
pub const android_api = 29;

/// Build `library` against the Android NDK's C library and system
/// libraries, for the Android it is compiled for. A build with no NDK to find
/// fails, and says where it looked.
fn useAndroidNdk(b: *std.Build, library: *std.Build.Step.Compile, asked: ?[]const u8) void {
    const ndk = asked orelse findAndroidNdk(b) orelse {
        library.step.dependOn(&b.addFail("a build for Android needs the Android NDK: -Dandroid-ndk=<path>, ANDROID_NDK_HOME, or one installed in the Android SDK").step);
        return;
    };
    const host = switch (b.graph.host.result.os.tag) {
        .windows => "windows-x86_64",
        .macos => "darwin-x86_64",
        else => "linux-x86_64",
    };
    const target = library.rootModuleTarget();
    const triple = switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => {
            library.step.dependOn(&b.addFail("the Android NDK has no C library for this processor").step);
            return;
        },
    };
    const sysroot = b.pathJoin(&.{ ndk, "toolchains", "llvm", "prebuilt", host, "sysroot", "usr" });
    const libraries = b.pathJoin(&.{ sysroot, "lib", triple, b.fmt("{d}", .{android_api}) });
    const libc = b.addWriteFiles().add("android.libc", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ b.pathJoin(&.{ sysroot, "include" }), b.pathJoin(&.{ sysroot, "include", triple }), libraries }));
    library.setLibCFile(libc);
    library.root_module.addLibraryPath(.{ .cwd_relative = libraries });
    library.root_module.linkSystemLibrary("log", .{});
}

/// The Android NDK the environment names, or the newest one in the Android
/// SDK. Public for a build that builds the runtime for Android as a
/// dependency, and would rather leave it out than fail with none.
pub fn findAndroidNdk(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk| return ndk;
    const folder = b.pathJoin(&.{ findAndroidSdk(b) orelse return null, "ndk" });
    return b.pathJoin(&.{ folder, newestVersion(b, folder, "") orelse return null });
}

/// The Android SDK the environment names, or the one its installer puts in
/// the user's folder, if it is there.
pub fn findAndroidSdk(b: *std.Build) ?[]const u8 {
    const env = &b.graph.environ_map;
    const sdk = env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT") orelse switch (b.graph.host.result.os.tag) {
        .windows => b.pathJoin(&.{ env.get("LOCALAPPDATA") orelse return null, "Android", "Sdk" }),
        .macos => b.pathJoin(&.{ env.get("HOME") orelse return null, "Library", "Android", "sdk" }),
        else => b.pathJoin(&.{ env.get("HOME") orelse return null, "Android", "Sdk" }),
    };
    std.Io.Dir.cwd().access(b.graph.io, sdk, .{}) catch return null;
    return sdk;
}

/// The name of the folder in `folder` with the highest version after
/// `prefix` - `27.2.12479018` of the NDKs, `android-36` of the SDK's
/// platforms - or null when there is none. A version may have one, two or
/// three numbers.
pub fn newestVersion(b: *std.Build, folder: []const u8, prefix: []const u8) ?[]const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var newest: ?[]const u8 = null;
    var newest_version: std.SemanticVersion = undefined;
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        const version = looseVersion(entry.name[prefix.len..]) orelse continue;
        if (newest != null and version.order(newest_version) != .gt) continue;
        newest = b.dupe(entry.name);
        newest_version = version;
    }
    return newest;
}

fn looseVersion(text: []const u8) ?std.SemanticVersion {
    var parts: [3]usize = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, text, '.');
    for (&parts) |*part| {
        const piece = it.next() orelse break;
        part.* = std.fmt.parseInt(usize, piece, 10) catch return null;
    }
    if (it.next() != null) return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
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
