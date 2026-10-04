// SPDX-License-Identifier: BSD-3-Clause

//! `project.fluxion`: how a project is called, opened, drawn and moved, at
//! the root of its folder.
//!
//! ```json
//! {
//!   "fluxion_project": 2,
//!   "application": { "name": "Meadow", "icon": "res://icon.png", "main_scene": "res://levels/meadow.json", "tags": ["2d"] },
//!   "display": { "width": 1600, "height": 900, "mode": "maximized" },
//!   "physics_2d": { "default_gravity": 420 },
//!   "layer_names": { "physics_2d": ["world", "player"] },
//!   "gui": { "theme": "res://ui/game.theme" }
//! }
//! ```
//!
//! **Settings are data.** Each section is a struct below, each setting a
//! field of it with its default and its description; `settings_file.zig`
//! reads and writes any such struct, and an editor draws its Project
//! Settings from the same fields. A file says only what differs from the
//! defaults, and keeps the keys this build has no section for.
//!
//! **A game and an editor read the same file.** A project manager lists its
//! projects by reading theirs, with no `App` and no GPU - `Project.readSettings`
//! - and a game finds its own as it starts: `App.create` reads the one at its
//! root, and what it says of the window, the clear colour and the fixed step
//! is what the game opens with, unless the game's own `App.Options` say
//! otherwise. A folder with no project file is still somewhere to read files
//! from.
//!
//! **What is wrong is said, not guessed round.** A version other than this
//! one, a renderer with no name here, a path that is not the project's, a
//! project with no name: each is an error with where it is.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const json = @import("fluxion_json");
const math = @import("fluxion_math");

const App = @import("../App.zig");
const actions = @import("../input/actions.zig");
const audio = @import("../audio/audio.zig");
const attr = @import("../reflect/attr.zig");
const flux = @import("fluxion_script");
const Color = @import("../math/color.zig").Color;
const settings_file = @import("settings_file.zig");
const stretch = @import("../render/stretch.zig");
const geometry = @import("../math/geometry.zig");

/// What the file is called, at the root of a project's folder.
pub const file_name = "project.fluxion";

/// The version this writes, and the only one it reads.
pub const version = 2;

/// The top of the file: `"fluxion_project": 2`.
pub const header: settings_file.Header = .{ .header = "fluxion_project", .version = version, .what = "project file" };

/// Which family of graphics APIs a project is drawn with.
pub const Renderer = enum {
    /// Direct3D 11 and OpenGL 3.3, and WebGL 2 in a browser: what there is.
    compatibility,
    /// Direct3D 12 and Vulkan. Experimental: see `experimental`. Where it has
    /// no backend - a browser, macOS - a project that asks for it opens no
    /// window, rather than being drawn with something else.
    modern,

    /// The graphics APIs it means, in words, for a person choosing one.
    pub fn apis(self: Renderer) []const u8 {
        return switch (self) {
            .compatibility => "Direct3D 11 and OpenGL",
            .modern => "Direct3D 12 and Vulkan",
        };
    }

    /// Whether its backends are still being finished: see
    /// `App.Backend.experimental`.
    pub fn experimental(self: Renderer) bool {
        return self == .modern;
    }

    /// Its backends on an operating system, best first: the first is what
    /// `Backend.auto` opens, and the others are what the same game can be
    /// checked on. Nothing where it has none.
    pub fn backends(self: Renderer, os: std.Target.Os.Tag) []const App.Backend {
        return switch (self) {
            .compatibility => switch (os) {
                .windows => &.{ .d3d11, .gl },
                .freestanding, .emscripten, .wasi => &.{.webgl},
                else => &.{.gl},
            },
            .modern => switch (os) {
                .windows => &.{ .d3d12, .vulkan },
                .freestanding, .emscripten, .wasi, .macos, .ios => &.{},
                else => &.{.vulkan},
            },
        };
    }
};

/// What the project is and what it opens.
pub const Application = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    version: []const u8 = "",
    icon: []const u8 = "",
    main_scene: []const u8 = "",
    tags: []const []const u8 = &.{},
    max_fps: u16 = 0,
    autoload: []const []const u8 = &.{},
    boot_splash: BootSplash = .{},
    user_folder: []const u8 = "",
    quit_on_close: bool = true,

    /// What the window shows while the game opens. See `App.openProject`.
    pub const BootSplash = struct {
        show: bool = false,
        color: Color = Rendering.default_clear_color,
        image: []const u8 = "",

        pub const reflect_fields = .{
            .show = .{attr.Doc{ .text = "Show it while the scenes the game opens with are read." }},
            .color = .{attr.Doc{ .text = "What the window is filled with." }},
            .image = .{ attr.ProjectFile{ .kinds = &.{.texture} }, attr.Doc{ .text = "A picture in the middle of it." } },
        };
    };

    pub const reflect_fields = .{
        .name = .{ attr.Required{}, attr.Doc{ .text = "What the project is called: the game window's title, and what the project list shows." } },
        .description = .{ attr.Multiline{}, attr.Doc{ .text = "A line or two about the project, for the project list." } },
        .version = .{attr.Doc{ .text = "Which version of the game this is - 1.2.0, say - for its menus to show: app.gameVersion()." }},
        .icon = .{ attr.ProjectFile{ .kinds = &.{.texture} }, attr.Doc{ .text = "The project's picture: the game window's icon, and the project list's. Any size and shape: it is fitted into a square at each size the system draws an icon. A Windows program exported with an icon of its own shows that one." } },
        .main_scene = .{ attr.ProjectFile{ .kinds = &.{.scene} }, attr.Doc{ .text = "The scene the game opens with, and what Play runs." } },
        .tags = .{attr.Doc{ .text = "Words to find the project by in the project list." }},
        .max_fps = .{ attr.Range{ .min = 0, .max = 1000, .step = 1 }, attr.Advanced{}, attr.Doc{ .text = "The most frames a second the game draws; nought for no limit." } },
        .autoload = .{ attr.ProjectFile{ .kinds = &.{ .scene, .script } }, attr.Doc{ .text = "Scenes and scripts made before the main scene, each named after its file, and kept when the scene changes." } },
        .boot_splash = .{attr.Doc{ .text = "What the window shows while the game opens." }},
        .user_folder = .{ attr.Advanced{}, attr.Doc{ .text = "The folder user:// is, in the system's folder for programs' data: empty for the project's name. Studio/Game keeps a studio's games together." } },
        .quit_on_close = .{ attr.Advanced{}, attr.Doc{ .text = "Whether the window's close button quits at once. Off, it only asks: app.closeRequested() says so, and the game quits with app.quit() when it agrees - after saving, say." } },
    };
};

/// The game's window. A game's own `App.Options` say otherwise when they
/// say anything.
pub const Display = struct {
    /// The size the game is made at: what its stretch scales from, and the
    /// window's size unless `window_width` and `window_height` say another.
    width: u32 = 1280,
    height: u32 = 720,
    window_width: u32 = 0,
    window_height: u32 = 0,
    mode: App.WindowMode = .windowed,
    /// Where the window opens, and on which screen.
    initial_position: InitialPosition = .center_of_primary_screen,
    screen: u16 = 0,
    position: geometry.Vec2i = .init(0, 0),
    resizable: bool = true,
    borderless: bool = false,
    always_on_top: bool = false,
    vsync_mode: App.VsyncMode = .enabled,
    /// How the game, made at `width` by `height`, is shown in a window of
    /// another size. See `stretch.zig`.
    stretch_mode: stretch.Mode = .disabled,
    stretch_aspect: stretch.Aspect = .keep,
    stretch_scale: f32 = 1,
    stretch_scale_mode: stretch.ScaleMode = .fractional,
    /// The least the player may drag the window to; nought is no least.
    min_width: u32 = 0,
    min_height: u32 = 0,
    /// A picture of the game's own for the pointer, and the point in it that
    /// points: see `App.setCustomCursor`.
    mouse_cursor: []const u8 = "",
    mouse_cursor_hotspot: math.Vec2 = .init(0, 0),
    keep_screen_on: bool = true,

    /// Where the window opens. See `App.InitialPosition`.
    pub const InitialPosition = App.InitialPosition;

    pub const reflect_fields = .{
        .width = .{ attr.Range{ .min = 1, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Doc{ .text = "How wide the game is made: what its stretch scales from, and how wide the window opens." } },
        .height = .{ attr.Range{ .min = 1, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Doc{ .text = "How tall the game is made: what its stretch scales from, and how tall the window opens." } },
        .window_width = .{ attr.Range{ .min = 0, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Advanced{}, attr.Doc{ .text = "How wide the window opens when not the game's width - a game made at 640 in a window of 1280, say; nought is the width above." } },
        .window_height = .{ attr.Range{ .min = 0, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Advanced{}, attr.Doc{ .text = "How tall the window opens when not the game's height; nought is the height above." } },
        .mode = .{attr.Doc{ .text = "How the window opens: a window, minimised, maximised, filling the screen at the resolution it has, or filling it exclusively - the display switched to the window's video mode." }},
        .initial_position = .{attr.Doc{ .text = "Where the window opens: in the middle of the primary screen, in the middle of the screen below, or at the position below." }},
        .screen = .{ attr.Range{ .min = 0, .max = 16, .step = 1 }, attr.Doc{ .text = "Which screen the window opens on, counting from nought, when it opens in the middle of one." } },
        .position = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "Where the top left of the window's content opens on the desktop, when it opens at a position." } },
        .resizable = .{attr.Doc{ .text = "Whether the player may drag the window's edges." }},
        .borderless = .{attr.Doc{ .text = "A window with no frame and no title bar of the system's." }},
        .always_on_top = .{ attr.Advanced{}, attr.Doc{ .text = "Keep the window over every window that is not kept so itself." } },
        .vsync_mode = .{attr.Doc{ .text = "How frames are shown against the screen's refresh. Disabled: as fast as they are drawn, and they may tear. Enabled: one a refresh, never tearing. Adaptive: one a refresh, a late one shown at once. Mailbox: the newest at each refresh, never waiting. One a backend has not is shown enabled." }},
        .stretch_mode = .{attr.Doc{ .text = "Disabled: a bigger window shows more. Canvas: laid out at the width and height above and drawn at the window's, scaled. Picture: drawn at that size and the picture scaled to the window, for pixel art." }},
        .stretch_aspect = .{attr.Doc{ .text = "Keep: always this shape, with bars where the window has room to spare. Expand: the spare room shows more. Keep width: as wide as made, a taller window showing more below. Keep height: as tall as made, a wider window showing more at the sides." }},
        .stretch_scale = .{ attr.Range{ .min = 0.25, .max = 8 }, attr.Advanced{}, attr.Doc{ .text = "How big the game is drawn on top of its stretch: two draws everything twice the size, showing half as much." } },
        .stretch_scale_mode = .{attr.Doc{ .text = "Fractional: scaled to fill the window. Integer: scaled only by a whole number, so every pixel of pixel art is the same size, with bars round what is left." }},
        .min_width = .{ attr.Range{ .min = 0, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Doc{ .text = "The narrowest the window may be dragged to; nought is no least." } },
        .min_height = .{ attr.Range{ .min = 0, .max = 16384, .step = 1 }, attr.Unit{ .text = "px" }, attr.Doc{ .text = "The lowest the window may be dragged to; nought is no least." } },
        .mouse_cursor = .{ attr.ProjectFile{ .kinds = &.{.texture} }, attr.Doc{ .text = "A picture for the pointer, instead of the system's arrow: 256 pixels a side at most." } },
        .mouse_cursor_hotspot = .{ attr.Unit{ .text = "px" }, attr.Doc{ .text = "The pixel of the pointer's picture that points: the tip of an arrow, the middle of a crosshair." } },
        .keep_screen_on = .{ attr.Advanced{}, attr.Doc{ .text = "Keep the screen from blanking, and the machine from sleeping, while the game runs: a game played with a pad sees no mouse or keyboard for a long while." } },
    };
};

/// How the project is drawn.
pub const Rendering = struct {
    renderer: Renderer = .compatibility,
    /// The backend each renderer is drawn with where there is a choice -
    /// Windows - and what is tried when it cannot open. See `backendsFor`.
    compatibility_backend: CompatibilityBackend = .auto,
    modern_backend: ModernBackend = .auto,
    fall_back: bool = true,
    fall_back_to_compatibility: bool = true,
    clear_color: Color = default_clear_color,
    /// How a texture is sampled when it does not say: nearest keeps pixel
    /// art's pixels square, linear smooths a painting.
    default_texture_filter: TextureFilter = .nearest,

    pub const TextureFilter = enum { nearest, linear };

    /// A Compatibility backend, or `auto` for the renderer's best on the
    /// system: Direct3D 11 on Windows, OpenGL elsewhere.
    pub const CompatibilityBackend = enum {
        auto,
        d3d11,
        gl,

        pub fn backend(self: CompatibilityBackend) ?App.Backend {
            return switch (self) {
                .auto => null,
                .d3d11 => .d3d11,
                .gl => .gl,
            };
        }
    };

    /// A Modern backend, or `auto` for the renderer's best on the system:
    /// Direct3D 12 on Windows, Vulkan elsewhere.
    pub const ModernBackend = enum {
        auto,
        d3d12,
        vulkan,

        pub fn backend(self: ModernBackend) ?App.Backend {
            return switch (self) {
                .auto => null,
                .d3d12 => .d3d12,
                .vulkan => .vulkan,
            };
        }
    };

    /// The backends a game is drawn with on an operating system, the one to
    /// try first first: the renderer's chosen one where it has it here - or
    /// its best - then, when `fall_back` is on, the rest of that renderer's,
    /// and a Modern game with `fall_back_to_compatibility` on, the
    /// Compatibility renderer's after them. Into `buffer`, which has room
    /// for every backend there is.
    pub fn backendsFor(self: Rendering, os: std.Target.Os.Tag, buffer: *[max_backends]App.Backend) []const App.Backend {
        var count: usize = 0;
        const add = struct {
            fn add(into: *[max_backends]App.Backend, at: *usize, backend: App.Backend) void {
                if (std.mem.indexOfScalar(App.Backend, into[0..at.*], backend) != null) return;
                into[at.*] = backend;
                at.* += 1;
            }
        }.add;
        const first_wanted: ?App.Backend = switch (self.renderer) {
            .compatibility => self.compatibility_backend.backend(),
            .modern => self.modern_backend.backend(),
        };
        const own = self.renderer.backends(os);
        if (first_wanted) |wanted| {
            if (std.mem.indexOfScalar(App.Backend, own, wanted) != null) add(buffer, &count, wanted);
        }
        for (own, 0..) |backend, i| {
            if (count > 0 and !self.fall_back) break;
            if (i == 0 or self.fall_back) add(buffer, &count, backend);
        }
        if (self.renderer == .modern and self.fall_back_to_compatibility) {
            const compatibility: Rendering = .{ .renderer = .compatibility, .compatibility_backend = self.compatibility_backend, .fall_back = self.fall_back };
            var more: [max_backends]App.Backend = undefined;
            for (compatibility.backendsFor(os, &more)) |backend| add(buffer, &count, backend);
        }
        return buffer[0..count];
    }

    /// Every backend there is, which is the most `backendsFor` can list.
    pub const max_backends = @typeInfo(App.Backend).@"enum".fields.len;

    pub const default_clear_color: Color = .hex(0x0E1013);

    pub const reflect_fields = .{
        .renderer = .{ attr.Restart{}, attr.Doc{ .text = "The family of graphics APIs the game is drawn with. Modern - Direct3D 12 and Vulkan - is experimental." } },
        .compatibility_backend = .{ attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "Which of the Compatibility renderer's backends the game is drawn with where there is a choice: Direct3D 11 or OpenGL on Windows. Auto is the best the system has." } },
        .modern_backend = .{ attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "Which of the Modern renderer's backends the game is drawn with where there is a choice: Direct3D 12 or Vulkan on Windows. Auto is the best the system has." } },
        .fall_back = .{ attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "Where the backend chosen cannot open on a machine, try the renderer's others." } },
        .fall_back_to_compatibility = .{ attr.Advanced{}, attr.Restart{}, attr.Doc{ .text = "Where no Modern backend opens on a machine, draw with the Compatibility renderer instead." } },
        .clear_color = .{ attr.Advanced{}, attr.Doc{ .text = "What every frame is cleared to, under the world." } },
        .default_texture_filter = .{ attr.Restart{}, attr.Doc{ .text = "How a texture is sampled when it does not say: nearest for pixel art, linear for a painting." } },
    };
};

/// How a 2D world moves when nothing else says so, and how many fixed steps
/// it takes a second. A game with no project file takes
/// `App.Options.physics_2d`.
pub const Physics2D = struct {
    default_gravity: f32 = 98,
    default_gravity_vector: math.Vec2 = .init(0, 1),
    default_linear_damp: f32 = 0.1,
    default_angular_damp: f32 = 1,
    ticks_per_second: u16 = 60,
    max_steps_per_frame: u16 = 8,

    pub const reflect_attributes = .{attr.Label{ .text = "Physics 2D" }};
    pub const reflect_fields = .{
        .default_gravity = .{ attr.Range{ .min = 0, .max = 10000 }, attr.Unit{ .text = "px/s²" }, attr.Doc{ .text = "How hard everything falls: 98 when a unit is a pixel; a world of a hundred units to the metre that wants Earth's says 981." } },
        .default_gravity_vector = .{attr.Doc{ .text = "Which way things fall: down the screen." }},
        .default_linear_damp = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How much of its speed a body loses a second, when its own linear damp is minus one." } },
        .default_angular_damp = .{ attr.Range{ .min = 0, .max = 100 }, attr.Doc{ .text = "How much of its spin a body loses a second, when its own angular damp is minus one." } },
        .ticks_per_second = .{ attr.Range{ .min = 1, .max = 1000, .step = 1 }, attr.Advanced{}, attr.Doc{ .text = "How many fixed steps a second the physics and the fixed systems take." } },
        .max_steps_per_frame = .{ attr.Range{ .min = 1, .max = 100, .step = 1 }, attr.Advanced{}, attr.Doc{ .text = "The most fixed steps one frame takes to catch up after a slow one: past them the game runs slower rather than stalling." } },
    };

    /// The gravity as the physics takes it: the vector, scaled.
    pub fn gravity(self: Physics2D) math.Vec2 {
        return self.default_gravity_vector.scale(self.default_gravity);
    }
};

/// What the project calls its layers.
pub const LayerNames = struct {
    /// The 2D physics layers, first to last, `""` for one with no name - at
    /// most 32: what an editor shows beside a layer's toggle.
    physics_2d: []const []const u8 = &.{},
    /// The 2D render layers, the same way: what an `Appearance` puts a
    /// branch on and a camera sees.
    render_2d: []const []const u8 = &.{},
    /// The 3D render layers: what a `MeshInstance3D` is on and a
    /// `Camera3D` sees.
    render_3d: []const []const u8 = &.{},

    pub const max = 32;

    pub const reflect_attributes = .{attr.Label{ .text = "Layer Names" }};
    pub const reflect_fields = .{
        .physics_2d = .{
            attr.Label{ .text = "2D Physics" },
            attr.Layers{ .names = .physics_2d },
            attr.Range{ .min = 0, .max = max },
            attr.Doc{ .text = "A name for each 2D physics layer, shown beside its toggle." },
        },
        .render_2d = .{
            attr.Label{ .text = "2D Render" },
            attr.Layers{ .names = .render_2d },
            attr.Range{ .min = 0, .max = max },
            attr.Doc{ .text = "A name for each 2D render layer, shown beside its toggle." },
        },
        .render_3d = .{
            attr.Label{ .text = "3D Render" },
            attr.Layers{ .names = .render_3d },
            attr.Range{ .min = 0, .max = max },
            attr.Doc{ .text = "A name for each 3D render layer, shown beside its toggle." },
        },
    };

    /// The name of the 2D physics layer numbered from 0, or `""`.
    pub fn physics2d(self: LayerNames, layer: usize) []const u8 {
        return if (layer < self.physics_2d.len) self.physics_2d[layer] else "";
    }

    /// The name of the 2D render layer numbered from 0, or `""`.
    pub fn render2d(self: LayerNames, layer: usize) []const u8 {
        return if (layer < self.render_2d.len) self.render_2d[layer] else "";
    }

    /// The name of the 3D render layer numbered from 0, or `""`.
    pub fn render3d(self: LayerNames, layer: usize) []const u8 {
        return if (layer < self.render_3d.len) self.render_3d[layer] else "";
    }
};

/// How the project's interface looks when nothing nearer says.
pub const Gui = struct {
    theme: []const u8 = "",
    /// Seconds the pointer rests on a control before its tooltip shows.
    tooltip_delay: f32 = 0.5,
    /// What every length of the interface is multiplied by, on top of the
    /// display's scale: `App.setInterfaceZoom`.
    scale: f32 = 1,

    pub const reflect_attributes = .{attr.Label{ .text = "GUI" }};
    pub const reflect_fields = .{
        .theme = .{ attr.ProjectFile{ .kinds = &.{.theme} }, attr.Doc{ .text = "The .theme every control is drawn with, under the one it names itself." } },
        .tooltip_delay = .{ attr.Unit{ .text = "s" }, attr.Range{ .min = 0, .max = 10 }, attr.Doc{ .text = "How long the pointer rests on a control before its tooltip shows." } },
        .scale = .{ attr.Range{ .min = 0.25, .max = 4 }, attr.Doc{ .text = "How big the interface is drawn, on top of the display's own scale: two for twice the size." } },
    };
};

/// Which language and region the game writes dates, times and spans of time
/// in. See `App.culture`.
pub const Internationalization = struct {
    /// A BCP 47 tag - `hu-HU`, `en-US`, `pt-BR` - or empty for the player's
    /// own, with the choices they made in the system's settings.
    locale: []const u8 = "",

    pub const reflect_fields = .{
        .locale = .{ attr.Locale{}, attr.Doc{ .text = "The language and region dates, times and spans are written in: a tag such as hu-HU, or empty for the player's own." } },
    };
};

/// How the game's scripts are compiled.
pub const Scripting = struct {
    /// What the compiler makes of an error nothing handles - a value that
    /// may be one used as what it would be, no `try`, no `catch`. See
    /// `flux.Vm.Unhandled`.
    unhandled_errors: flux.Vm.Unhandled = .warn,

    pub const reflect_fields = .{
        .unhandled_errors = .{attr.Doc{ .text = "An error nothing handles, no try and no catch: strict refuses the script; warn takes it and says so, quiet says nothing. Taken, the error is passed on where the function returns errors, and elsewhere the script stops if it is one." }},
    };
};

/// How the game's sound is mixed. See `audio.zig`.
pub const Audio = struct {
    /// The buses sound is mixed on, each into the one it sends to, and all
    /// at last into `Master`, which is always there: one of that name here
    /// says its volume.
    buses: []const audio.Bus = &.{},

    pub const reflect_attributes = .{attr.Label{ .text = "Audio" }};
    pub const reflect_fields = .{
        .buses = .{attr.Doc{ .text = "Each with its volume and the bus it goes into; Master is always there." }},
    };
};

/// The game's actions and the inputs that set them off - over the built-in
/// ones, of which one of the same name takes the place. An editor gives
/// them a tab of their own rather than a page. See `actions.zig`.
pub const InputMap = struct {
    actions: []const actions.Action = &.{},

    pub const reflect_attributes = .{ attr.Label{ .text = "Input Map" }, attr.Hidden{} };
    pub const reflect_fields = .{
        .actions = .{attr.Doc{ .text = "The game's actions: a name, a dead zone, and the keys, buttons and sticks that set it off." }},
    };
};

test "a project's actions are written as the inputs they are, and read back the same" {
    var settings: Settings = .{ .application = .{ .name = "Keys" } };
    settings.input.actions = &.{.{ .name = "look", .deadzone = 0.25, .bindings = &.{ .padAxisOf(.right_x, .negative), .{ .key = .{ .key = .q, .physical = false } } } }};
    const written = try settings_file.stringify(Settings, header, testing.allocator, &settings);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"type\": \"pad_axis\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"direction\": \"negative\"") != null);

    var back = try settings_file.parse(Settings, header, testing.allocator, written, file_name, null);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.input.actions.len);
    const look = back.input.actions[0];
    try testing.expectEqualStrings("look", look.name);
    try testing.expectEqual(@as(f32, 0.25), look.deadzone);
    try testing.expect(look.bindings[0].eql(.padAxisOf(.right_x, .negative)));
    try testing.expect(look.bindings[1].eql(.{ .key = .{ .key = .q, .physical = false } }));
}

/// How a touch screen and a mouse stand in for each other.
pub const Touch = struct {
    /// The first finger is the mouse as well: see `Input.mouse_from_touch`.
    mouse_from_touch: bool = true,
    /// The left mouse button is a finger as well: see
    /// `Input.touch_from_mouse`.
    touch_from_mouse: bool = false,
    /// A wheel turned with Ctrl is a pinch as well: see
    /// `Input.pinch_from_ctrl_wheel`.
    pinch_from_ctrl_wheel: bool = true,

    pub const reflect_attributes = .{attr.Label{ .text = "Touch" }};
    pub const reflect_fields = .{
        .mouse_from_touch = .{attr.Doc{ .text = "The first finger on a touch screen is the mouse as well: it moves the pointer and holds the left button, so the interface and whatever is made for a mouse work under a finger." }},
        .touch_from_mouse = .{attr.Doc{ .text = "The left mouse button is a finger as well, so a game made for a touch screen - its touch buttons, its fingers - can be tried with a mouse." }},
        .pinch_from_ctrl_wheel = .{attr.Doc{ .text = "A wheel turned with Ctrl is a pinch as well, at the pointer: what a laptop touchpad's pinch is on Windows and in a browser. The wheel's own event comes too." }},
    };
};

/// What the game may ask of the web. See `net/web.zig`.
pub const Network = struct {
    /// How many of the game's requests are on their way at once; the rest
    /// wait their turn.
    max_requests: u8 = 4,
    /// Whether `http://` addresses are asked, not only `https://` ones.
    allow_plain_http: bool = false,

    pub const reflect_attributes = .{attr.Label{ .text = "Network" }};
    pub const reflect_fields = .{
        .max_requests = .{ attr.Doc{ .text = "How many of the game's web requests are on their way at once; the rest wait their turn." }, attr.Range{ .min = 1, .max = 16, .step = 1 } },
        .allow_plain_http = .{attr.Doc{ .text = "Ask http:// addresses too, not only https:// ones. Off, a request over plain HTTP fails with NotSecure: what it carries - keys, scores, a player's name - anyone on the way could read and change." }},
    };
};

/// The plugins the project turns on: see `plugins.zig`.
pub const Plugins = struct {
    /// Their folders under `res://addons/`, in order.
    enabled: []const []const u8 = &.{},

    pub const reflect_attributes = .{ attr.Label{ .text = "Plugins" }, attr.Hidden{} };
};

/// What a project file says: a section a field.
pub const Settings = struct {
    application: Application = .{},
    display: Display = .{},
    rendering: Rendering = .{},
    physics_2d: Physics2D = .{},
    audio: Audio = .{},
    layer_names: LayerNames = .{},
    gui: Gui = .{},
    internationalization: Internationalization = .{},
    scripting: Scripting = .{},
    input: InputMap = .{},
    touch: Touch = .{},
    network: Network = .{},
    plugins: Plugins = .{},
    /// The memory the text above is kept in, and the file's keys this build
    /// has no section for.
    kept: settings_file.Kept = .{},

    pub const json_ignore = .{.kept};

    /// Give back what reading them took. Nothing, for settings written in
    /// code.
    pub fn deinit(self: *Settings) void {
        self.kept.deinit();
        self.* = undefined;
    }

    /// A section the game keeps in the project file itself, read into `S`:
    /// `"my_game": { ... }` beside the engine's. Null when there is none.
    pub fn section(self: *const Settings, comptime S: type, name: []const u8, into: Allocator) json.Error!?S {
        return settings_file.readSection(S, &self.kept, name, into);
    }
};

pub const ReadError = settings_file.ReadError || std.Io.Dir.ReadFileAllocError;

pub const WriteError = settings_file.WriteError || Allocator.Error;

pub const CreateError = error{
    /// The folder has a project file already.
    ProjectExists,
} || WriteError || std.Io.Dir.AccessError;

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// The project file in the folder `dir` - `error.FileNotFound` when it has
/// none. What went wrong, and where, goes into `diagnostics`, under the
/// file's path: `games/meadow/project.fluxion:3:14: ...`.
pub fn read(gpa: Allocator, io: std.Io, dir: []const u8, diagnostics: ?*json.Diagnostics) ReadError!Settings {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    if (diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        if (diagnostics) |d| d.setMessage("cannot read the file: {t}", .{err});
        return err;
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, path, diagnostics);
}

/// Settings from a project file's text; `name` is what a warning calls the
/// file. JSON5, so a file edited by hand may say why in a comment.
pub fn parse(gpa: Allocator, bytes: []const u8, name: []const u8, diagnostics: ?*json.Diagnostics) settings_file.ReadError!Settings {
    // Reading starts the diagnostics afresh; which file it is, is said again.
    var file_buffer: [240]u8 = undefined;
    const file: []const u8 = if (diagnostics) |d| blk: {
        const len = @min(d.file().len, file_buffer.len);
        @memcpy(file_buffer[0..len], d.file()[0..len]);
        break :blk file_buffer[0..len];
    } else "";
    var settings = settings_file.parse(Settings, header, gpa, bytes, name, diagnostics) catch |err| {
        if (diagnostics) |d| d.setFile(file);
        return err;
    };
    errdefer settings.deinit();
    if (diagnostics) |d| d.setFile(file);
    if (settings.layer_names.physics_2d.len > LayerNames.max) {
        if (diagnostics) |d| d.setMessage("there are 32 physics layers, and \"layer_names.physics_2d\" names more", .{});
        return error.WrongType;
    }
    return settings;
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `settings` as the project file in the folder `dir`, in place of the
/// one there: written beside it and then moved over it, so a crash halfway
/// leaves the old file whole. Folders on the way are made. Only what differs
/// from the defaults is written.
pub fn write(gpa: Allocator, io: std.Io, dir: []const u8, settings: Settings) WriteError!void {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try settings_file.save(Settings, header, io, path, &settings);
}

/// The project file's text, as `write` writes it.
pub fn text(gpa: Allocator, settings: *const Settings) WriteError![]u8 {
    return settings_file.stringify(Settings, header, gpa, settings);
}

/// Make a new project: its folder, with every folder above it that is
/// missing, and its project file. `error.ProjectExists` when the folder has
/// one already, which is left as it was.
pub fn create(gpa: Allocator, io: std.Io, dir: []const u8, settings: Settings) CreateError!void {
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        return error.ProjectExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    // `write` makes the folders on the way, as fluxion-json's `save` does.
    try write(gpa, io, dir, settings);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A folder of a test's own, and its path from the working directory.
const Folder = struct {
    tmp: testing.TmpDir,
    buffer: [160]u8 = undefined,

    fn init() Folder {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn at(self: *Folder, inside: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}{s}", .{ self.tmp.sub_path, inside });
    }

    fn put(self: *Folder, content: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = content });
    }
};

test "a project file is written and read back as it was, saying only what differs" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const tags = [_][]const u8{ "2d", "jam" };
    const layers = [_][]const u8{ "world", "", "", "wolves" };
    try write(testing.allocator, testing.io, try folder.at(""), .{
        .application = .{
            .name = "Meadow",
            .description = "Sheep, and a wolf",
            .icon = "res://icon.png",
            .main_scene = "res://levels/meadow.json",
            .tags = &tags,
        },
        .display = .{ .width = 1600, .mode = .maximized },
        .physics_2d = .{
            .default_gravity = 981,
            .default_gravity_vector = .init(0.6, 0.8),
            .default_linear_damp = 0,
            .default_angular_damp = 0.5,
        },
        .layer_names = .{ .physics_2d = &layers },
        .gui = .{ .theme = "res://ui/game.theme" },
    });

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    const application = settings.application;
    try testing.expectEqualStrings("Meadow", application.name);
    try testing.expectEqualStrings("Sheep, and a wolf", application.description);
    try testing.expectEqualStrings("res://icon.png", application.icon);
    try testing.expectEqualStrings("res://levels/meadow.json", application.main_scene);
    try testing.expectEqual(@as(usize, 2), application.tags.len);
    try testing.expectEqualStrings("jam", application.tags[1]);
    try testing.expectEqual(@as(u32, 1600), settings.display.width);
    try testing.expectEqual(@as(u32, 720), settings.display.height);
    try testing.expectEqual(App.WindowMode.maximized, settings.display.mode);
    try testing.expectEqual(Renderer.compatibility, settings.rendering.renderer);
    const physics = settings.physics_2d;
    try testing.expectEqual(@as(f32, 981), physics.default_gravity);
    try testing.expectEqual(@as(f32, 0.8), physics.default_gravity_vector.y);
    try testing.expectEqual(@as(f32, 0), physics.default_linear_damp);
    try testing.expectEqual(@as(f32, 0.5), physics.default_angular_damp);
    try testing.expectApproxEqAbs(@as(f32, 784.8), physics.gravity().y, 0.01);
    try testing.expectEqualStrings("wolves", settings.layer_names.physics2d(3));
    try testing.expectEqualStrings("", settings.layer_names.physics2d(2));
    try testing.expectEqualStrings("", settings.layer_names.physics2d(31));
    try testing.expectEqualStrings("res://ui/game.theme", settings.gui.theme);

    // What was left at its default is not written: no height, no renderer.
    var kept: [2048]u8 = undefined;
    const written = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.startsWith(u8, written, "{\n  \"fluxion_project\": 2,\n  \"application\": {"));
    try testing.expect(std.mem.indexOf(u8, written, "\"height\"") == null);
    try testing.expect(std.mem.indexOf(u8, written, "\"rendering\"") == null);

    // A theme that is not the project's is not written.
    try testing.expectError(error.WrongType, write(testing.allocator, testing.io, try folder.at(""), .{ .application = .{ .name = "Out" }, .gui = .{ .theme = "C:/elsewhere.theme" } }));
}

test "the window's, the renderer's and the rest of the newer settings are written as the words they are, and read back the same" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    try write(testing.allocator, testing.io, try folder.at(""), .{
        .application = .{ .name = "Settled", .version = "1.2.0", .quit_on_close = false },
        .display = .{
            .window_width = 1920,
            .window_height = 1080,
            .mode = .exclusive_fullscreen,
            .initial_position = .center_of_screen,
            .screen = 1,
            .position = .init(40, -20),
            .borderless = true,
            .always_on_top = true,
            .vsync_mode = .mailbox,
            .stretch_aspect = .keep_height,
            .stretch_scale = 2,
            .stretch_scale_mode = .integer,
            .keep_screen_on = false,
        },
        .rendering = .{ .renderer = .modern, .modern_backend = .vulkan, .compatibility_backend = .gl, .fall_back = false, .fall_back_to_compatibility = false },
        .physics_2d = .{ .max_steps_per_frame = 4 },
        .gui = .{ .scale = 1.25 },
    });
    var kept: [4096]u8 = undefined;
    const written = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.indexOf(u8, written, "\"mode\": \"exclusive_fullscreen\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"vsync_mode\": \"mailbox\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"modern_backend\": \"vulkan\"") != null);

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    try testing.expectEqualStrings("1.2.0", settings.application.version);
    try testing.expect(!settings.application.quit_on_close);
    const display = settings.display;
    try testing.expectEqual(@as(u32, 1920), display.window_width);
    try testing.expectEqual(App.WindowMode.exclusive_fullscreen, display.mode);
    try testing.expectEqual(Display.InitialPosition.center_of_screen, display.initial_position);
    try testing.expectEqual(@as(u16, 1), display.screen);
    try testing.expectEqual(@as(i32, -20), display.position.y);
    try testing.expect(display.borderless and display.always_on_top and !display.keep_screen_on);
    try testing.expectEqual(App.VsyncMode.mailbox, display.vsync_mode);
    try testing.expectEqual(stretch.Aspect.keep_height, display.stretch_aspect);
    try testing.expectEqual(stretch.ScaleMode.integer, display.stretch_scale_mode);
    try testing.expectEqual(@as(f32, 2), display.stretch_scale);
    try testing.expectEqual(Rendering.ModernBackend.vulkan, settings.rendering.modern_backend);
    try testing.expectEqual(Rendering.CompatibilityBackend.gl, settings.rendering.compatibility_backend);
    try testing.expect(!settings.rendering.fall_back and !settings.rendering.fall_back_to_compatibility);
    try testing.expectEqual(@as(u16, 4), settings.physics_2d.max_steps_per_frame);
    try testing.expectEqual(@as(f32, 1.25), settings.gui.scale);
}

test "what a project file leaves out takes its default, and a key it does not know is kept" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    try folder.put(
        \\// Written by hand.
        \\{ "fluxion_project": 2, "application": { "name": "Bare", "colour": "green" }, "my_game": { "lives": 3 } }
    );
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    var settings = try read(testing.allocator, testing.io, try folder.at(""), null);
    defer settings.deinit();
    try testing.expectEqualStrings("Bare", settings.application.name);
    try testing.expectEqualStrings("", settings.application.icon);
    try testing.expectEqual(Renderer.compatibility, settings.rendering.renderer);
    try testing.expectEqual(@as(usize, 0), settings.application.tags.len);
    // The default physics, which a new project has.
    try testing.expectEqual(@as(f32, 98), settings.physics_2d.default_gravity);
    try testing.expectEqual(@as(f32, 1), settings.physics_2d.default_gravity_vector.y);
    try testing.expectEqual(@as(u16, 60), settings.physics_2d.ticks_per_second);

    // The game's own section, read by the game; and written back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Game = struct { lives: u8 = 1 };
    try testing.expectEqual(@as(u8, 3), (try settings.section(Game, "my_game", arena.allocator())).?.lives);
    try write(testing.allocator, testing.io, try folder.at(""), settings);
    var kept: [1024]u8 = undefined;
    const written = try folder.tmp.dir.readFile(testing.io, file_name, &kept);
    try testing.expect(std.mem.indexOf(u8, written, "\"my_game\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"colour\"") == null);
}

test "a project file that is wrong says what and where, and one that is not there says so" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    var diagnostics: json.Diagnostics = .{};

    try testing.expectError(error.FileNotFound, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));

    const cases = [_]struct { text: []const u8, err: ReadError, message: []const u8 }{
        .{
            .text = "{ \"fluxion_project\": 1, \"name\": \"Old\" }",
            .err = error.UnsupportedVersion,
            .message = "this project file is version 1, written for an older Fluxion; this one reads version 2",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"application\": { \"name\": \"Lost\", \"icon\": \"C:/art/icon.png\" } }",
            .err = error.WrongType,
            .message = "\"application.icon\" is a res:// or uid:// path, or empty, and this is \"C:/art/icon.png\"",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"rendering\": { \"renderer\": \"modern\" } }",
            .err = error.MissingField,
            .message = "\"application.name\" has to say something, and says nothing",
        },
        .{
            .text = "{ \"application\": { \"name\": \"Meadow\" } }",
            .err = error.NotSettings,
            .message = "this is not a project file: it has no \"fluxion_project\" version",
        },
        .{
            .text = "{ \"fluxion_project\": 2, \"application\": { \"name\": \"Many\" }, \"layer_names\": { \"physics_2d\": [" ++
                ("\"\", " ** 32) ++ "\"thirty-third\"] } }",
            .err = error.WrongType,
            .message = "there are 32 physics layers, and \"layer_names.physics_2d\" names more",
        },
    };
    for (cases) |case| {
        try folder.put(case.text);
        try testing.expectError(case.err, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
        try testing.expectEqualStrings(case.message, diagnostics.message());
        try testing.expect(std.mem.endsWith(u8, diagnostics.file(), file_name));
    }

    // The line of what is wrong.
    try folder.put("{\n  \"fluxion_project\": 2,\n  \"application\": { \"name\": \"Shiny\" },\n  \"rendering\": { \"renderer\": \"raytraced\" }\n}");
    try testing.expectError(error.UnknownTag, read(testing.allocator, testing.io, try folder.at(""), &diagnostics));
    try testing.expectEqual(@as(u32, 4), diagnostics.line);
}

test "a project is made in a folder that was not there, and not over one that is" {
    var folder: Folder = .init();
    defer folder.tmp.cleanup();
    const dir = try folder.at("/games/meadow");
    try create(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Meadow" }, .rendering = .{ .renderer = .modern } });

    var settings = try read(testing.allocator, testing.io, dir, null);
    defer settings.deinit();
    try testing.expectEqual(Renderer.modern, settings.rendering.renderer);

    try testing.expectError(error.ProjectExists, create(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Other" } }));
    var again = try read(testing.allocator, testing.io, dir, null);
    defer again.deinit();
    try testing.expectEqualStrings("Meadow", again.application.name);

    try testing.expectError(error.WrongType, write(testing.allocator, testing.io, dir, .{ .application = .{ .name = "Lost", .icon = "icon.png" } }));
}

test "a renderer's backends, best first, on each system" {
    try testing.expectEqualSlices(App.Backend, &.{ .d3d11, .gl }, Renderer.compatibility.backends(.windows));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.linux));
    try testing.expectEqualSlices(App.Backend, &.{.gl}, Renderer.compatibility.backends(.macos));
    try testing.expectEqualSlices(App.Backend, &.{.webgl}, Renderer.compatibility.backends(.emscripten));
    try testing.expectEqualSlices(App.Backend, &.{ .d3d12, .vulkan }, Renderer.modern.backends(.windows));
    try testing.expectEqualSlices(App.Backend, &.{.vulkan}, Renderer.modern.backends(.linux));
    try testing.expectEqual(@as(usize, 0), Renderer.modern.backends(.macos).len);
    try testing.expectEqual(@as(usize, 0), Renderer.modern.backends(.emscripten).len);
    try testing.expect(Renderer.modern.experimental() and !Renderer.compatibility.experimental());
}
