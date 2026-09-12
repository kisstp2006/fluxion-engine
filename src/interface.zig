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
const Input = @import("input.zig");
const Window = @import("window.zig");

const Interface = @This();

/// How far one notch of the wheel scrolls, in pixels.
pub const pixels_per_notch = 40;

/// How far a stick has to lean, past its dead zone, to step the focus.
pub const stick_step = 0.5;

/// What the interface is drawn and measured in. `.none` is the default font,
/// as for a `Text2D`.
font: Assets.FontHandle = .none,

/// Multiplies every length in the interface. See `ui.Surface.scale`.
scale: f32 = 1,

/// How far in from each edge of the window the interface keeps.
safe_area: ui.Padding = .none,

/// What an image's texture number means. Borrowed: it has to outlive the
/// frames drawn from it.
textures: []const rhi.Texture = &.{},

renderer: ?ui_rhi.Renderer = null,
/// The face `renderer` was made with.
face: ?*const typeface.Font = null,

/// This frame's, from `ui.end`.
commands: []const ui.RenderCommand = &.{},

/// What Ctrl+C and Ctrl+X took, for Ctrl+V: fluxion-platform has no clipboard
/// yet, so it only reaches as far as this program.
clipboard: std.ArrayList(u8) = .empty,

/// The pointer shape last put on the window.
shape: ui.CursorShape = .arrow,

/// Unscaled seconds since the first frame: what animated text moves on.
seconds: f64 = 0,

pub fn deinit(self: *Interface, gpa: Allocator) void {
    if (self.renderer) |*renderer| renderer.deinit();
    self.clipboard.deinit(gpa);
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
/// focus. Characters and editing keys reach a text input that has the focus;
/// Enter, Space and a pad's A press whatever else has it.
pub fn feed(self: *Interface, gpa: Allocator, layout: *ui.Ui, input: *Input, dt: f32) Allocator.Error!void {
    layout.tick(dt);
    self.seconds += dt;

    layout.setShift(input.mods.shift);
    const down = input.buttonDown(.left);
    if (input.pointer.locked or (!input.pointer.inside and !down)) {
        layout.setPointer(-1, -1, false);
    } else {
        layout.setPointer(input.pointer.x, input.pointer.y, down);
    }

    for (input.typedThisFrame()) |typed| try self.receive(gpa, layout, typed);

    if (input.wheel.x != 0 or input.wheel.y != 0) {
        const dx = input.wheel.x * pixels_per_notch;
        const dy = -input.wheel.y * pixels_per_notch;
        if (layout.scrollHovered(dx, dy)) input.wheel = .{};
    }

    const pad = input.anyPad();
    layout.holdNavigation(if (layout.focus != 0) padDirection(pad) else null);

    const accept = input.isDown(.enter) or input.isDown(.kp_enter) or input.isDown(.space) or pad.down(.a);
    layout.setActivate(accept and !layout.wantsKeyboard());
}

fn receive(self: *Interface, gpa: Allocator, layout: *ui.Ui, typed: Input.Typed) Allocator.Error!void {
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
                try self.edit(gpa, layout, k);
            } else if (layout.focus != 0) {
                if (arrow(k.key)) |toward| _ = layout.navigate(toward);
            }
        },
    }
}

fn edit(self: *Interface, gpa: Allocator, layout: *ui.Ui, k: platform.event.KeyEvent) Allocator.Error!void {
    if (k.virtual == .v and command(k)) {
        _ = layout.textAction(.{ .paste = self.clipboard.items });
        return;
    }
    const action = textAction(k) orelse return;
    const taken = layout.textAction(action) orelse return;
    self.clipboard.clearRetainingCapacity();
    try self.clipboard.appendSlice(gpa, taken);
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

/// Control held as a command, and not AltGr: Windows reports AltGr as control
/// and alt together, and on a Hungarian keyboard AltGr and V types `@`.
pub fn command(k: platform.event.KeyEvent) bool {
    return k.mods.control and !k.mods.alt;
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

    fn init() Fixture {
        var layout: ui.Ui = .init(testing.allocator);
        layout.setMeasurer(.monospace(0.5, 1));
        return .{ .layout = layout };
    }

    fn deinit(self: *Fixture) void {
        self.interface.deinit(testing.allocator);
        self.layout.deinit();
    }

    fn frame(self: *Fixture, declare: *const fn (*ui.Ui) void) !void {
        try self.interface.feed(testing.allocator, &self.layout, &self.input, 1.0 / 60.0);
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
    fixture.input.apply(keyOn(.v, .v, .{ .control = true, .alt = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("a", fixture.layout.textValueOf("name").?);

    fixture.input.apply(keyOn(.y, .z, .{ .control = true }));
    try fixture.frame(nameField);
    try testing.expectEqualStrings("", fixture.layout.textValueOf("name").?);
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
    try fixture.interface.feed(testing.allocator, &fixture.layout, &fixture.input, 0);
    try testing.expectEqual(@as(f32, 0), fixture.input.wheel.y);

    fixture.input.apply(pointerAt(150, 80));
    fixture.input.apply(wheelTurned(-1));
    try fixture.interface.feed(testing.allocator, &fixture.layout, &fixture.input, 0);
    try testing.expectEqual(@as(f32, -1), fixture.input.wheel.y);
}

test "a locked pointer points at nothing in the interface" {
    var fixture: Fixture = .init();
    defer fixture.deinit();

    try fixture.frame(longList);
    fixture.input.apply(pointerAt(10, 10));
    fixture.input.pointer.locked = true;
    try fixture.interface.feed(testing.allocator, &fixture.layout, &fixture.input, 0);
    try testing.expect(!fixture.layout.wantsPointer());

    fixture.input.pointer.locked = false;
    try fixture.interface.feed(testing.allocator, &fixture.layout, &fixture.input, 0);
    try testing.expect(fixture.layout.wantsPointer());
}
