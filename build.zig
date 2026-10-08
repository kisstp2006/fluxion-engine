// SPDX-License-Identifier: BSD-3-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = androidVersioned(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const e = engine(b, target, optimize, true);
    const mod = e.mod;
    const ecs = e.ecs;
    const rhi = e.rhi;
    const platform = e.platform;
    const image = e.image;
    const typeface = e.typeface;
    const debugdraw = e.debugdraw;
    const ui = e.ui;
    const physics = e.physics;
    const script = e.script;
    const audio = e.audio;
    const vfs = e.vfs;
    const net = e.net;

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
    const lightmapper_tests = b.addTest(.{
        .name = "fluxion-lightmapper-tests",
        .root_module = e.lightmapper,
    });
    test_step.dependOn(&b.addRunArtifact(lightmapper_tests).step);
    const navmesh_tests = b.addTest(.{
        .name = "fluxion-navmesh-tests",
        .root_module = e.navmesh,
    });
    test_step.dependOn(&b.addRunArtifact(navmesh_tests).step);
    const csg_tests = b.addTest(.{
        .name = "fluxion-csg-tests",
        .root_module = e.csg,
    });
    test_step.dependOn(&b.addRunArtifact(csg_tests).step);

    const ndk = b.option([]const u8, "android-ndk", "The Android NDK, for a build for Android (default: ANDROID_NDK_HOME, then the newest in the Android SDK's ndk folder)");
    const program = runtime(b, e, target, optimize, ndk);
    const android = target.result.abi.isAndroid();
    const web = target.result.cpu.arch.isWasm();
    b.installArtifact(program);
    test_step.dependOn(&program.step);
    // And for a browser, whatever the target: a change that breaks the page's
    // build is found where the change is made.
    if (!web) {
        const browser = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
        test_step.dependOn(&runtime(b, engine(b, browser, .ReleaseSmall, false), browser, .ReleaseSmall, null).step);
    }

    // What a page needs around the runtime's module, a folder the export
    // copies beside it: runtime/web - the page, fluxion.js, the font - and
    // the libraries' glues, at the commits built in here (the WebGL one the
    // rhi's).
    const page_files = b.addWriteFiles();
    _ = page_files.addCopyDirectory(b.path("runtime/web"), "", .{});
    _ = page_files.addCopyFile(platform.namedLazyPath("fluxion-platform.js"), "fluxion-platform.js");
    _ = page_files.addCopyFile(rhi.builder.dependency("fluxion_webgl", .{ .target = target, .optimize = optimize }).namedLazyPath("glue"), "fluxion-webgl.js");
    _ = page_files.addCopyFile(audio.namedLazyPath("fluxion-audio.js"), "fluxion-audio.js");
    _ = page_files.addCopyFile(net.namedLazyPath("fluxion-net.js"), "fluxion-net.js");
    b.addNamedLazyPath("web", page_files.getDirectory());

    // The notices the libraries built into the runtime ask a program made
    // from them to carry - what an export writes beside a game as
    // LICENSES.txt - a file each. The runtime's own licence asks for none,
    // and nor do the Boost licence and CC0 the rest are under. stb_vorbis,
    // the Ogg decoder in fluxion-audio, is used under the Unlicense, which
    // asks for nothing either; it is named all the same.
    const notices = b.addWriteFiles();
    _ = notices.addCopyFile(b.path("LICENSE"), "fluxion-engine.txt");
    const noticed = [_]struct { []const u8, *std.Build.Dependency }{
        .{ "fluxion-ecs", ecs },         .{ "fluxion-rhi", rhi },             .{ "fluxion-image", image },
        .{ "fluxion-font", typeface },   .{ "fluxion-debugdraw", debugdraw }, .{ "fluxion-ui", ui },
        .{ "fluxion-physics", physics }, .{ "fluxion-script", script },       .{ "fluxion-vfs", vfs },
        .{ "fluxion-net", net },
    };
    for (noticed) |entry| _ = notices.addCopyFile(entry[1].path("LICENSE"), b.fmt("{s}.txt", .{entry[0]}));
    _ = notices.addCopyFile(audio.namedLazyPath("stb_vorbis.txt"), "stb_vorbis.txt");
    _ = notices.addCopyFile(.{ .cwd_relative = zigLicense(b) }, "zig-standard-library.txt");
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
        .{
            .name = "shapes",
            .step = "example-shapes",
            .about = "The 3D layer: shapes made from numbers, a camera going round them, the sun",
        },
    };

    const example_step = b.step("examples", "Build every example");
    // An Android program is the runtime's library, and a page's its module:
    // none of these is one.
    if (!android and !web) for (examples) |example| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .single_threaded = e.single_threaded,
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

/// The engine's module for `target`, and the packages it is made of. The
/// build's own target's is the one a dependant imports (`exported`); another
/// is for a check - the browser's, built by the tests.
fn engine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, exported: bool) Engine {
    // A browser runs the program on the page's one thread: built without
    // threads, it has no atomics to ask for (wasm32 without them has none).
    const single_threaded: ?bool = if (target.result.cpu.arch.isWasm()) true else null;

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
    const physics3d = b.dependency("fluxion_physics3d", .{ .target = target, .optimize = optimize });
    const reflect = b.dependency("fluxion_reflect", .{ .target = target, .optimize = optimize });
    const script = b.dependency("fluxion_script", .{ .target = target, .optimize = optimize });
    const audio = b.dependency("fluxion_audio", .{ .target = target, .optimize = optimize });
    if (target.result.abi.isAndroid()) {
        // Its C imports read the NDK's headers, which want to know the
        // Android they are for; Zig's own C front end does not say, as the
        // NDK's compiler does from the target.
        const level = b.fmt("{d}", .{target.result.os.version_range.linux.android});
        audio.module("fluxion_audio").addCMacro("__ANDROID_API__", level);
        audio.module("fluxion_audio").addCMacro("__ANDROID_MIN_SDK_VERSION__", level);
    }
    const vfs = b.dependency("fluxion_vfs", .{ .target = target, .optimize = optimize });
    const net = b.dependency("fluxion_net", .{ .target = target, .optimize = optimize });

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

    // The lightmap baker traces rays, which is nearly all of a bake's time:
    // built for speed whatever the engine is built as. It needs nothing but
    // the standard library.
    const lightmapper = b.createModule(.{
        .root_source_file = b.path("src/bake/lightmapper.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = single_threaded,
    });

    // The navigation mesh baker and the way across one: the same, for a bake
    // of a level is nearly all rasterizing.
    const navmesh = b.createModule(.{
        .root_source_file = b.path("src/navmesh/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = single_threaded,
    });

    // Solids joined and cut: the same, for a level of them is remade as
    // its pieces are dragged.
    const csg = b.createModule(.{
        .root_source_file = b.path("src/csg/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = single_threaded,
    });

    // Nothing here is lazy, and that is the difference between an engine and
    // the libraries under it. A library keeps its window, its file reading
    // and its renderer behind `lazy` so a consumer never downloads what it
    // does not use; an engine uses all of it by definition, and a game that
    // depends on this wants every one of them.
    const mod_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
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
            .{ .name = "fluxion_physics3d", .module = physics3d.module("fluxion_physics3d") },
            .{ .name = "fluxion_reflect", .module = reflect.module("fluxion_reflect") },
            .{ .name = "fluxion_script", .module = script.module("fluxion_script") },
            .{ .name = "fluxion_audio", .module = audio.module("fluxion_audio") },
            .{ .name = "fluxion_vfs", .module = vfs.module("fluxion_vfs") },
            .{ .name = "fluxion_net", .module = net.module("fluxion_net") },
            .{ .name = "fluxion_lightmapper", .module = lightmapper },
            .{ .name = "fluxion_navmesh", .module = navmesh },
            .{ .name = "fluxion_csg", .module = csg },
        },
    };
    const mod = if (exported) b.addModule("fluxion_engine", mod_options) else b.createModule(mod_options);

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

    // The engine's version, said in one place - `build.zig.zon` - for a
    // plugin's manifest to be checked against.
    const engine_options = b.addOptions();
    engine_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addImport("engine_options", engine_options.createModule());

    return .{
        .mod = mod,
        .ecs = ecs,
        .rhi = rhi,
        .platform = platform,
        .image = image,
        .typeface = typeface,
        .debugdraw = debugdraw,
        .ui = ui,
        .physics = physics,
        .script = script,
        .audio = audio,
        .vfs = vfs,
        .net = net,
        .lightmapper = lightmapper,
        .navmesh = navmesh,
        .csg = csg,
        .single_threaded = single_threaded,
    };
}

const Engine = struct {
    mod: *std.Build.Module,
    ecs: *std.Build.Dependency,
    rhi: *std.Build.Dependency,
    platform: *std.Build.Dependency,
    image: *std.Build.Dependency,
    typeface: *std.Build.Dependency,
    debugdraw: *std.Build.Dependency,
    ui: *std.Build.Dependency,
    physics: *std.Build.Dependency,
    script: *std.Build.Dependency,
    audio: *std.Build.Dependency,
    vfs: *std.Build.Dependency,
    net: *std.Build.Dependency,
    lightmapper: *std.Build.Module,
    navmesh: *std.Build.Module,
    csg: *std.Build.Module,
    single_threaded: ?bool,
};

/// The program a game is shipped as, from `mod`: see runtime/main.zig. On
/// Android it is the library the platform's activity loads, the APK's
/// libmain.so; in a browser, the page's module. A release build on Windows
/// opens a window and no console; the export can still turn a game's into
/// one with a console.
fn runtime(b: *std.Build, e: Engine, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ndk: ?[]const u8) *std.Build.Step.Compile {
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = e.single_threaded,
        // A game as it ships carries no debug information: a debug build
        // is the one to find a fault with.
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
        .imports = &.{.{ .name = "fluxion_engine", .module = e.mod }},
    });
    const android = target.result.abi.isAndroid();
    const program = if (android)
        b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = runtime_mod })
    else
        b.addExecutable(.{ .name = "fluxion-runtime", .root_module = runtime_mod });
    if (android) useAndroidNdk(b, program, ndk);
    if (target.result.os.tag == .windows and optimize != .Debug) program.subsystem = .windows;
    if (target.result.cpu.arch.isWasm()) {
        // A page's module, for wasm32-wasi: no `main` - the page calls
        // `init`, `frame` and `deinit` - its exports kept, and a reactor,
        // whose C library `_initialize` sets up before the first call.
        program.entry = .disabled;
        program.rdynamic = true;
        program.wasi_exec_model = .reactor;
    }
    return program;
}

/// The lowest Android the runtime is for: 10. The platform's activity is
/// compiled for it too.
pub const android_api = 29;

/// `target`, for Android with `android_api` as its version when it names
/// none: newer NDKs' headers refuse a target without one.
fn androidVersioned(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (!target.result.abi.isAndroid() or target.query.android_api_level != null) return target;
    var query = target.query;
    query.android_api_level = android_api;
    return b.resolveTargetQuery(query);
}

/// Zig's own licence, for the standard library built into the runtime:
/// beside the `lib` folder in Zig's own download, and where a system's
/// package of Zig keeps its licences.
fn zigLicense(b: *std.Build) []const u8 {
    const lib = b.graph.zig_lib_directory.path orelse ".";
    const places = [_][]const u8{
        b.pathJoin(&.{ lib, "..", "LICENSE" }),
        b.pathJoin(&.{ lib, "..", "..", "share", "licenses", "zig", "LICENSE" }),
        b.pathJoin(&.{ lib, "..", "..", "share", "doc", "zig", "LICENSE" }),
        "/usr/share/licenses/zig/LICENSE",
        "/usr/share/doc/zig/LICENSE",
    };
    for (places) |place| {
        std.Io.Dir.cwd().access(b.graph.io, place, .{}) catch continue;
        return place;
    }
    return places[0];
}

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
    // A device may have pages of 16 KB, and maps the library's segments by
    // them: none may be laid on a smaller step.
    library.link_z_max_page_size = 16 << 10;
    library.link_z_common_page_size = 16 << 10;
    library.root_module.addLibraryPath(.{ .cwd_relative = libraries });
    library.root_module.linkSystemLibrary("log", .{});
    // LLVM and LLD, for a debug build too: Zig's own x86_64 code generator
    // and linker, which one would take, lay the segments on 4 KB and out of
    // order, and Android's loader refuses the library.
    library.use_llvm = true;
    library.use_lld = true;
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
