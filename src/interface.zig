// SPDX-License-Identifier: BSD-3-Clause

//! The interface layer: fluxion-ui, fed from `Input` before the game's
//! systems run, laid out by `.ui` systems, and drawn over the 2D layer.
//!
//! ```zig
//! fn pauseMenu(app: *App) !void {
//!     app.ui.open(.{ .id = "resume", .padding = .all(12), .focus = .{} });
//!     defer app.ui.close();
//!     app.ui.text("Resume", .{ .font_size = 24 });
//!     if (app.ui.justReleased()) app.time.scale = 1;
//! }
//! ```

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ui = @import("fluxion_ui");
const ui_rhi = @import("fluxion_ui_rhi");
const rhi = @import("fluxion_rhi");
const platform = @import("fluxion_platform");
const typeface = @import("fluxion_font");

const Assets = @import("assets.zig");
const Clipboard = @import("clipboard.zig");
const Input = @import("input.zig");
const Window = @import("window.zig");

const Interface = @This();
const log = std.log.scoped(.fluxion_engine);

/// How far one line of the system's wheel setting scrolls, in the
/// interface's own lengths: at the usual three lines a notch, the forty
/// pixels a notch has always scrolled. See `scroll_lines`.
pub const pixels_per_line: f32 = 40.0 / 3.0;

/// How much of the window a notch scrolls when the system scrolls a page at a
/// time: all of it less an eighth, as a browser does, so a line of what was
/// showing is still showing.
pub const page_fraction: f32 = 0.875;

/// How far a stick has to lean, past its dead zone, to step the focus.
pub const stick_step = 0.5;

/// What the interface is drawn and measured in. `.none` is the default font,
/// as for a `Text2D`.
font: Assets.FontHandle = .none,

/// Multiplies every length in the interface: what it is laid out at this
/// frame, `zoom` times `display_scale`, worked out by `App` at the top of
/// every frame. Read it - to size what a system draws beside the interface -
/// and set `zoom`. See `ui.Surface.scale`.
scale: f32 = 1,

/// The game's own multiplier for the interface, on top of the display's:
/// an "interface size" setting.
zoom: f32 = 1,

/// Pixels per logical unit of the display the window is on: 1 on an
/// ordinary display, 1.5 or 2 on a HiDPI one, and 1 with no window. Kept by
/// `App` from the window - at the start, and whenever the window moves to a
/// monitor with another - while `follow_display` is on.
display_scale: f32 = 1,

/// Whether the interface grows with the display, as the system's own
/// windows do. Off for a game that sizes its interface by the window alone.
follow_display: bool = true,

/// Whether the interface turns the platform's text input on while one of
/// its text inputs has the keyboard, and off when none has. Off for a game
/// that turns it on for a text box of its own. See `applyTextInput`.
owns_text_input: bool = true,

/// What the interface last asked text input to be.
typing: bool = false,

/// Where it last told the input method the caret was.
caret_area: ?platform.text.Area = null,

/// Whether the system has refused a caret's place once: told of it once.
caret_refused: bool = false,

/// What the system scrolls text by for a notch of the wheel, as `App` last
/// asked it: lines, or a page. See `pixels_per_line`.
scroll_lines: platform.ScrollLines = .{},

/// How far in from each edge of the framebuffer the interface keeps: a
/// phone's notch and gesture bar, a page's safe area. Filled from the
/// system every frame while `follow_safe_area` is on.
safe_area: ui.Padding = .none,

/// Whether the safe area follows the system's. Off, the game says what it
/// is - for a program that would rather draw into the notch itself.
follow_safe_area: bool = true,

/// What an image's texture number means. Borrowed: it has to outlive the
/// frames drawn from it.
textures: []const rhi.Texture = &.{},

renderer: ?ui_rhi.Renderer = null,
/// The face `renderer` was made with.
face: ?*const typeface.Font = null,
/// The `Assets.font_reloads` the renderer's glyphs were drawn at: a font
/// read again keeps its address, so the face alone cannot say.
font_reloads: u32 = 0,

/// This frame's, from `ui.end`.
commands: []const ui.RenderCommand = &.{},

/// The pointer shape last put on the window.
shape: ui.CursorShape = .arrow,

/// Unscaled seconds since the first frame: what animated text moves on.
seconds: f64 = 0,

pub fn deinit(self: *Interface) void {
    if (self.renderer) |*renderer| renderer.deinit();
    self.* = undefined;
}

/// The surface this frame is laid out on.
pub fn surface(self: *const Interface, width: f32, height: f32) ui.Surface {
    return .{ .size = .init(width, height), .scale = self.scale, .safe_area = self.safe_area };
}

/// Hand this frame's input to the interface, before any system asks it
/// anything. A wheel the interface scrolled with is taken out of `input`.
///
/// Tab always moves the focus. The arrows, a d-pad and the left stick move it
/// only once something has it, so a game keeps them until a menu takes the
/// focus. Characters and editing keys reach a text input that has the focus,
/// copying and pasting through `clipboard`; Enter, Space and a pad's A press
/// whatever else has it.
pub fn feed(
    self: *Interface,
    gpa: Allocator,
    layout: *ui.Ui,
    input: *Input,
    clipboard: *Clipboard,
    dt: f32,
) Allocator.Error!void {
    layout.tick(dt);
    self.seconds += dt;

    layout.setShift(input.mods.shift);
    const down = input.buttonDown(.left);
    if (input.pointer.locked or (!input.pointer.inside and !down)) {
        layout.setPointer(-1, -1, false);
    } else {
        layout.setPointer(input.pointer.x, input.pointer.y, down);
    }

    for (input.typedThisFrame()) |typed| try receive(gpa, layout, clipboard, typed);

    if (input.wheel.x != 0 or input.wheel.y != 0) {
        // The wheel counts up as positive, and a scroll moves the content.
        const across, const up = self.wheelDistance(input.wheel.x, input.wheel.y, layout.surface.height);
        if (layout.scrollHovered(across, -up)) input.wheel = .{};
    }

    const pad = input.anyPad();
    layout.holdNavigation(if (layout.focus != 0) padDirection(pad) else null);

    const accept = input.isDown(.enter) or input.isDown(.kp_enter) or input.isDown(.space) or pad.down(.a);
    layout.setActivate(accept and !layout.wantsKeyboard());
}

/// How far a turn of the wheel scrolls, in pixels, sideways and up: notches
/// times the system's characters and lines at the interface's scale, or
/// times a page of `height`. Signed as the wheel is.
fn wheelDistance(self: *const Interface, notches_x: f32, notches_y: f32, height: f32) [2]f32 {
    const line = pixels_per_line * self.scale;
    const across = notches_x * self.scroll_lines.x * line;
    const up = if (self.scroll_lines.page)
        notches_y * height * page_fraction
    else
        notches_y * self.scroll_lines.y * line;
    return .{ across, up };
}

fn receive(gpa: Allocator, layout: *ui.Ui, clipboard: *Clipboard, typed: Input.Typed) Allocator.Error!void {
    switch (typed) {
        .character => |codepoint| {
            var utf8: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &utf8) catch return;
            layout.typeText(utf8[0..length]);
        },
        .key => |k| {
            if (k.key == .tab) {
                _ = layout.navigate(if (k.mods.shift) .previous else .next);
            } else if (layout.wantsKeyboard()) {
                try edit(gpa, layout, clipboard, k);
            } else if (layout.focus != 0) {
                if (arrow(k.key)) |toward| _ = layout.navigate(toward);
            }
        },
    }
}

/// A clipboard that says no costs the paste or the copy, not the frame.
fn edit(gpa: Allocator, layout: *ui.Ui, clipboard: *Clipboard, k: platform.event.KeyEvent) Allocator.Error!void {
    if (k.virtual == .v and command(k)) {
        const pasted = clipboard.read() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return log.warn("could not paste: {t}", .{err}),
        };
        _ = layout.textAction(.{ .paste = pasted });
        return;
    }
    const action = textAction(k) orelse return;
    const taken = layout.textAction(action) orelse return;
    clipboard.set(gpa, taken) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => log.warn("could not copy: {t}", .{err}),
    };
}

/// The keys no layout moves by where they are, and the letters by the name
/// the layout gives them: ctrl+Z is the Z the reader can see.
fn textAction(k: platform.event.KeyEvent) ?ui.text_input.Action {
    const shift = k.mods.shift;
    const ctrl = command(k);
    switch (k.key) {
        .left => return .moveTo(if (ctrl) .word_left else .left, shift),
        .right => return .moveTo(if (ctrl) .word_right else .right, shift),
        .up => return .moveTo(.up, shift),
        .down => return .moveTo(.down, shift),
        .home => return .moveTo(if (ctrl) .text_start else .start, shift),
        .end => return .moveTo(if (ctrl) .text_end else .end, shift),
        .backspace => return if (ctrl) .backspace_word else .backspace,
        .delete => return if (ctrl) .delete_word else .delete,
        .enter, .kp_enter => return .submit,
        else => {},
    }
    if (!ctrl) return null;
    return switch (k.virtual) {
        .a => .select_all,
        .c => .copy,
        .x => .cut,
        .z => if (shift) .redo else .undo,
        .y => .redo,
        else => null,
    };
}

/// Control held as a command, with alt or without. AltGr is not control: the
/// platform reports it as `alt_graph` on every system, so AltGr and V types
/// `@` on a Hungarian keyboard, and control and alt and V still pastes.
pub fn command(k: platform.event.KeyEvent) bool {
    return k.mods.control;
}

fn arrow(key: platform.Key) ?ui.Navigation {
    return switch (key) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        else => null,
    };
}

fn padDirection(pad: Input.Pad) ?ui.Navigation {
    if (pad.down(.dpad_up)) return .up;
    if (pad.down(.dpad_down)) return .down;
    if (pad.down(.dpad_left)) return .left;
    if (pad.down(.dpad_right)) return .right;

    const stick = pad.stick(.left);
    if (@abs(stick.x) < stick_step and @abs(stick.y) < stick_step) return null;
    if (@abs(stick.x) > @abs(stick.y)) return if (stick.x < 0) .left else .right;
    return if (stick.y < 0) .up else .down;
}

/// Measure the interface's text in `face`, the way the renderer draws it.
pub fn measurer(face: *const typeface.Font) ui.Measurer {
    return .{ .context = face, .measureFn = measure, .lineHeightFn = lineHeight };
}

fn measure(context: ?*const anyopaque, run: []const u8, style: ui.TextStyle) ui.text.Size {
    const scaled = faceOf(context).at(@floatFromInt(style.font_size));
    return .{ .width = scaled.measure(run) catch 0, .height = scaled.lineHeight() };
}

fn lineHeight(context: ?*const anyopaque, style: ui.TextStyle) f32 {
    return faceOf(context).at(@floatFromInt(style.font_size)).lineHeight();
}

fn faceOf(context: ?*const anyopaque) *const typeface.Font {
    return @ptrCast(@alignCast(context.?));
}

/// Draw this frame's interface over what `target` already holds. With no
/// font it is laid out and not drawn, as a `Text2D` is.
pub fn draw(
    self: *Interface,
    gpa: Allocator,
    device: *rhi.Device,
    face: ?*const typeface.Font,
    target: rhi.RenderTarget,
    width: f32,
    height: f32,
) !void {
    if (self.commands.len == 0) return;
    const drawn_in = face orelse return;

    const renderer = try self.rendererFor(gpa, device, drawn_in);
    renderer.setTextures(self.textures);
    renderer.setTime(self.seconds);
    try renderer.draw(target, .init(width, height), self.commands, null);
}

/// Let the renderer go, and the glyphs it drew: the next `draw` makes
/// another. For a font read again in place.
pub fn forgetRenderer(self: *Interface) void {
    if (self.renderer) |*renderer| renderer.deinit();
    self.renderer = null;
    self.face = null;
}

fn rendererFor(self: *Interface, gpa: Allocator, device: *rhi.Device, face: *const typeface.Font) !*ui_rhi.Renderer {
    if (self.renderer) |*renderer| {
        if (self.face == face) return renderer;
        renderer.deinit();
        self.renderer = null;
    }
    self.renderer = try .init(gpa, device, face);
    self.face = face;
    return &self.renderer.?;
}

/// Put the pointer shape the interface worked out on the window, when it
/// changes.
pub fn applyCursor(self: *Interface, layout: *ui.Ui, window: *Window) void {
    const wanted = layout.cursor();
    if (wanted == self.shape) return;
    window.setCursorShape(platformShape(wanted)) catch return;
    self.shape = wanted;
}

/// Turn the platform's text input on while one of the interface's text
/// inputs has the keyboard - the soft keyboard on a phone or a page, and an
/// input method's composition on a desktop - and off when none has, so an
/// input method never sits between a game and its keys. And tell the input
/// method where the caret is, so its composition and its list of candidates
/// sit beside the text rather than across it. Each only when it changes, and
/// neither with `owns_text_input` off.
pub fn applyTextInput(self: *Interface, layout: *ui.Ui, window: *Window) void {
    if (!self.owns_text_input) return;
    const wanted = layout.wantsKeyboard();
    if (wanted != self.typing) {
        // Asked once per change, so a system that refuses is told once.
        self.typing = wanted;
        self.caret_area = null;
        window.setTextInput(wanted) catch |err| {
            log.warn("could not turn text input {s}: {t}", .{ if (wanted) "on" else "off", err });
        };
    }
    if (!wanted) return;

    const at = layout.caret() orelse return;
    const area = caretArea(at) orelse return;
    if (self.caret_area) |told| {
        if (std.meta.eql(told, area)) return;
    }
    self.caret_area = area;
    window.setTextInputArea(area) catch |err| {
        if (!self.caret_refused) log.warn("could not say where the caret is: {t}", .{err});
        self.caret_refused = true;
    };
}

/// The caret's box in whole pixels round it, or null for one no window could
/// be told of: a layout gone wrong is a caret not placed, never a crash. The
/// framebuffer's pixels, which the platform places an input method by on
/// every backend, as it reports the pointer in them.
fn caretArea(at: ui.BoundingBox) ?platform.text.Area {
    const limit: f32 = 1 << 30;
    for ([_]f32{ at.x, at.y, at.width, at.height }) |value| {
        if (!std.math.isFinite(value) or @abs(value) >= limit) return null;
    }
    return .{
        .x = @intFromFloat(@floor(at.x)),
        .y = @intFromFloat(@floor(at.y)),
        .width = @intFromFloat(@max(0, @ceil(at.width))),
        .height = @intFromFloat(@max(0, @ceil(at.height))),
    };
}

fn platformShape(shape: ui.CursorShape) platform.CursorShape {
    return switch (shape) {
        inline else => |named| @field(platform.CursorShape, @tagName(named)),
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn keyOn(physical: platform.Key, virtual: platform.Key, mods: platform.Mods) platform.Event {
    return .{ .key = .{
        .window = .none,
        .key = physical,
        .virtual = virtual,
        .scancode = @enumFromInt(0),
        .action = .press,
        .mods = mods,
    } };
}

fn keyDown(key: platform.Key, mods: platform.Mods) platform.Event {
    return keyOn(key, key, mods);
}

fn character(codepoint: u21) platform.Event {
    return .{ .char = .{ .window = .none, .codepoint = codepoint, .mods = .{} } };
}

fn pointerAt(x: f64, y: f64) platform.Event {
    return .{ .cursor = .{ .window = .none, .x = x, .y = y, .dx = 0, .dy = 0 } };
}

fn wheelTurned(notches: f64) platform.Event {
    return .{ .scroll = .{ .window = .none, .x = 0, .y = notches, .mods = .{} } };
}

const Fixture = struct {
    layout: ui.Ui,
    interface: Interface = .{},
    input: Input = .{},
    /// The program's own, as with no window: a test never overwrites what
    /// the person running it had copied.
    clipboard: Clipboard = .{},

    fn init() Fixture {
        var layout: ui.Ui = .init(testing.allocator);
        layout.setMeasurer(.monospace(0.5, 1));
        return .{ .layout = layout };
    }

    fn deinit(self: *Fixture) void {
        self.interface.deinit();
        self.clipboard.deinit(testing.allocator);
        self.layout.deinit();
    }

    fn feed(self: *Fixture, dt: f32) !void {
        try self.interface.feed(testing.allocator, &self.layout, &self.input, &self.clipboard, dt);
    }

    fn frame(self: *Fixture, declare: *const fn (*ui.Ui) void) !void {
        try self.feed(1.0 / 60.0);
        self.input.beginFrame();
        self.layout.begin(.init(200, 100));
        self.layout.open(.{});
        declare(&self.layout);
        self.layout.close();
        _ = try self.layout.end();
    }
};

fn nameField(layout: *ui.Ui) void {
    layout.textInput(.{ .id = "name", .width = .fixed(120) }, .{});
}

fn twoButtons(layout: *ui.Ui) void {
    layout.open(.{ .direction = .top_to_bottom });
    defer layout.close();
    layout.empty(.{ .id = "play", .width = .fixed(80), .height = .fixed(20), .focus = .{} });
    layout.empty(.{ .id = "quit", .width = .fixed(80), .height = .fixed(20), .focus = .{} });
}

fn longList(layout: *ui.Ui) void {
    layout.open(.{ .id = "list", .width = .fixed(100), .height = .fixed(50), .clip = .scrollY, .direction = .top_to_bottom });
    defer layout.close();
    for (0..10) |_| layout.empty(.{ .width = .fixed(100), .height = .fixed(20), .background_color = .white });
}

test "typing reaches the text input that has the focus" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    fixture.layout.setFocus("name");
    fixture.input.apply(character('h'));
    fixture.input.apply(character('i'));
    try fixture.frame(nameField);

    try testing.expectEqualStrings("hi", fixture.layout.textValueOf("name").?);
}

test "what Ctrl+C takes, Ctrl+V puts back" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    fixture.layout.setFocus("name");
    fixture.input.apply(character('a'));
    fixture.input.apply(character('b'));
    fixture.input.apply(keyDown(.a, .{ .control = true }));
    fixture.input.apply(keyDown(.c, .{ .control = true }));
    fixture.input.apply(keyDown(.end, .{}));
    fixture.input.apply(keyDown(.v, .{ .control = true }));
    try fixture.frame(nameField);

    try testing.expectEqualStrings("abab", fixture.layout.textValueOf("name").?);
}

test "shortcuts follow the letters the layout shows, and AltGr is not one" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    fixture.layout.setFocus("name");
    fixture.input.apply(character('a'));
    fixture.input.apply(keyDown(.a, .{ .control = true }));
    fixture.input.apply(keyDown(.c, .{ .control = true }));
    fixture.input.apply(keyDown(.end, .{}));
    fixture.input.apply(keyOn(.v, .v, .{ .alt_graph = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("a", fixture.layout.textValueOf("name").?);

    fixture.input.apply(keyOn(.y, .z, .{ .control = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("", fixture.layout.textValueOf("name").?);
}

test "control is a command with alt held too" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    fixture.layout.setFocus("name");
    fixture.input.apply(character('a'));
    fixture.input.apply(keyDown(.a, .{ .control = true }));
    fixture.input.apply(keyDown(.c, .{ .control = true }));
    fixture.input.apply(keyDown(.end, .{}));
    fixture.input.apply(keyOn(.v, .v, .{ .control = true, .alt = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("aa", fixture.layout.textValueOf("name").?);
}

test "the arrows are the game's until the interface has the focus" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(twoButtons);
    fixture.input.apply(keyDown(.down, .{}));
    try fixture.frame(twoButtons);
    try testing.expect(!fixture.layout.isFocused("play"));
    try testing.expect(!fixture.layout.isFocused("quit"));

    fixture.input.apply(keyDown(.tab, .{}));
    try fixture.frame(twoButtons);
    try testing.expect(fixture.layout.isFocused("play"));

    fixture.input.apply(keyDown(.down, .{}));
    try fixture.frame(twoButtons);
    try testing.expect(fixture.layout.isFocused("quit"));
}

test "a wheel the interface scrolled with does not reach the game" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(longList);
    fixture.input.apply(pointerAt(10, 10));
    fixture.input.apply(wheelTurned(-1));
    try fixture.feed(0);
    try testing.expectEqual(@as(f32, 0), fixture.input.wheel.y);

    fixture.input.apply(pointerAt(150, 80));
    fixture.input.apply(wheelTurned(-1));
    try fixture.feed(0);
    try testing.expectEqual(@as(f32, -1), fixture.input.wheel.y);
}

test "a notch scrolls the lines the system says, at the interface's scale, or a page" {
    const Case = struct { lines: platform.ScrollLines = .{}, scale: f32 = 1, moved: f32 };
    for ([_]Case{
        // The usual three lines: the forty pixels a notch always was.
        .{ .moved = 40 },
        .{ .lines = .{ .y = 6 }, .moved = 80 },
        .{ .scale = 2, .moved = 80 },
        // A page at a time: the surface's hundred pixels, less an eighth.
        .{ .lines = .{ .y = 1, .page = true }, .moved = 87.5 },
    }) |case| {
        var fixture: Fixture = .init();
        defer fixture.deinit();
        fixture.interface.scroll_lines = case.lines;
        fixture.interface.scale = case.scale;

        try fixture.frame(longList);
        fixture.input.apply(pointerAt(10, 10));
        fixture.input.apply(wheelTurned(-1));
        try fixture.feed(0);
        try testing.expectApproxEqAbs(case.moved, fixture.layout.scrollOf("list").?.position.y, 0.001);
    }
}

test "the caret is told in whole pixels round it, and a caret with no place is not told" {
    const area = caretArea(.{ .x = 10.6, .y = 20.2, .width = 1.5, .height = 17.1 }).?;
    try testing.expectEqual(platform.text.Area{ .x = 10, .y = 20, .width = 2, .height = 18 }, area);

    try testing.expect(caretArea(.{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 }) == null);
    try testing.expect(caretArea(.{ .x = 0, .y = std.math.inf(f32), .width = 1, .height = 1 }) == null);
    try testing.expect(caretArea(.{ .x = 0, .y = 0, .width = 1e30, .height = 1 }) == null);
}

test "the caret of the text input with the keyboard is where the input method is told" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    try testing.expect(fixture.layout.caret() == null);
    fixture.layout.setFocus("name");
    try fixture.frame(nameField);
    const at = fixture.layout.caret().?;
    try testing.expect(caretArea(at) != null);
}

test "a locked pointer points at nothing in the interface" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(longList);
    fixture.input.apply(pointerAt(10, 10));
    fixture.input.pointer.locked = true;
    try fixture.feed(0);
    try testing.expect(!fixture.layout.wantsPointer());

    fixture.input.pointer.locked = false;
    try fixture.feed(0);
    try testing.expect(fixture.layout.wantsPointer());
}

test "the interface pastes what the game put on the clipboard, and the game reads what it copied" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(nameField);
    fixture.layout.setFocus("name");
    try fixture.clipboard.set(testing.allocator, "Kovács");
    fixture.input.apply(keyDown(.v, .{ .control = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("Kovács", fixture.layout.textValueOf("name").?);

    fixture.input.apply(keyDown(.left, .{ .shift = true }));
    fixture.input.apply(keyDown(.left, .{ .shift = true }));
    fixture.input.apply(keyDown(.x, .{ .control = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("Ková", fixture.layout.textValueOf("name").?);
    try testing.expectEqualStrings("cs", try fixture.clipboard.read());
}
