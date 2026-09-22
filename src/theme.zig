// SPDX-License-Identifier: BSD-3-Clause

//! How a game's interface looks, as a file says it: Godot's Theme resource.
//!
//! ```json
//! {
//!   "fluxion_theme": 1,
//!   "base": "res://ui/base.theme",
//!   "font": "res://fonts/ui.ttf",
//!   "font_size": 16,
//!   "types": {
//!     "Button": {
//!       "font_color": "#F2EEF8",
//!       "styles": {
//!         "normal":  { "background": "#6B4FC8", "corners": 6, "padding": [10, 5] },
//!         "hover":   { "background": "#8F72E8" },
//!         "pressed": { "background": "#4E3899" },
//!         "focus":   { "border": 2, "border_color": "#F5B942" }
//!       }
//!     },
//!     "Header": { "base_type": "Label", "font_size": 20, "font_color": "#F5B942" }
//!   }
//! }
//! ```
//!
//! A type is a kind of control - `Button`, `Panel`, `LineEdit` - or a name a
//! `Control` asks for by its `type_variation`, which says what it is built on
//! with `base_type`. Nothing has to be said twice: a field a state leaves out
//! comes from `normal`, a field the type leaves out comes from its
//! `base_type`, then from the `base` theme, and at the end from the look this
//! engine is born with. So a theme file holds what a game changed, and
//! nothing else.
//!
//! Kept beside the world and pointed at by a handle, as tile sets are: see
//! `tileset.zig`, whose shape this follows.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const id = @import("fluxion_id");
const json = @import("fluxion_json");

const App = @import("App.zig");
const Assets = @import("assets.zig");
const Color = @import("color.zig").Color;
const Project = @import("Project.zig");

const log = std.log.scoped(.fluxion_engine);

/// What a theme's file ends in.
pub const extension = ".theme";

/// The version this reads.
pub const version = 1;

/// The largest theme file read.
const file_limit = 4 << 20;

/// How far a chain of `base` themes or `base_type` types is followed before
/// it is called a loop.
const most_links = 8;

pub const ThemeHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub const none: ThemeHandle = .{};

    /// A tool shows `App.themeSource` instead, as it does for a texture.
    pub const reflect_name = "ThemeHandle";

    pub fn isNone(self: ThemeHandle) bool {
        return self.generation == 0;
    }

    pub fn eql(a: ThemeHandle, b: ThemeHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    fn toId(self: ThemeHandle) Table.Handle {
        return @bitCast(self);
    }

    fn fromId(handle: Table.Handle) ThemeHandle {
        return @bitCast(handle);
    }
};

const Table = id.handle.Table(Theme);

/// Room inside a box, in pixels.
pub const Insets = extern struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(value: u16) Insets {
        return .{ .left = value, .right = value, .top = value, .bottom = value };
    }

    /// Across and down, which is how a file says it.
    pub fn xy(across: u16, down: u16) Insets {
        return .{ .left = across, .right = across, .top = down, .bottom = down };
    }
};

/// How round a box's corners are.
pub const Corners = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Corners {
        return .{ .top_left = value, .top_right = value, .bottom_right = value, .bottom_left = value };
    }
};

/// Which piece of a control is being drawn. A theme calls each of them by
/// the name in `typeName`.
pub const Part = enum(u8) {
    panel,
    button,
    check_box,
    line_edit,
    slider_track,
    slider_fill,
    progress_track,
    progress_fill,
    tab,
    tab_active,
    focus,
    label,

    /// What a theme file calls it.
    pub fn typeName(self: Part) []const u8 {
        return switch (self) {
            .panel => "Panel",
            .button => "Button",
            .check_box => "CheckBox",
            .line_edit => "LineEdit",
            .slider_track => "Slider",
            .slider_fill => "SliderFill",
            .progress_track => "ProgressBar",
            .progress_fill => "ProgressBarFill",
            .tab => "Tab",
            .tab_active => "TabActive",
            .focus => "Focus",
            .label => "Label",
        };
    }
};

/// What a control is doing, which is what a theme draws it by.
pub const State = enum(u8) { normal, hover, pressed, disabled, focus };

/// What a theme says about one piece in one state. Every field is a field
/// that may be left unsaid, so that what a file does not mention is taken
/// from somewhere else rather than written over with a zero.
pub const Style = struct {
    background: ?Color = null,
    border_color: ?Color = null,
    border_width: ?u16 = null,
    corners: ?Corners = null,
    padding: ?Insets = null,
    texture: ?Assets.TextureHandle = null,
    tint: ?Color = null,
    /// Where a textured box is cut for its nine slices, as fractions of the
    /// texture: left, right, top, bottom.
    slices: ?[4]f32 = null,
    /// How wide the drawn edges of those slices are.
    patch_margin: ?Insets = null,
    font_color: ?Color = null,
    font: ?Assets.FontHandle = null,
    font_size: ?u16 = null,

    /// This style laid over `under`: what this one says wins, and what it
    /// leaves unsaid `under` keeps. The order every part of the lookup uses.
    pub fn over(self: Style, under: Style) Style {
        var out = under;
        inline for (@typeInfo(Style).@"struct".fields) |field| {
            if (@field(self, field.name)) |value| @field(out, field.name) = value;
        }
        return out;
    }

    /// Whether nothing at all is said here.
    pub fn isEmpty(self: Style) bool {
        inline for (@typeInfo(Style).@"struct".fields) |field| {
            if (@field(self, field.name) != null) return false;
        }
        return true;
    }
};

/// One kind of control, as a theme describes it.
pub const Type = struct {
    /// What a control asks for it by: a part's `typeName`, or a name a
    /// `Control` gives as its `type_variation`.
    name: []const u8,
    /// The type it is built on, or empty.
    base_type: []const u8 = "",
    /// What holds in every state.
    shared: Style = .{},
    /// What holds in one state, over `shared`.
    states: [@typeInfo(State).@"enum".fields.len]Style = @splat(.{}),

    pub fn state(self: *const Type, which: State) Style {
        return self.states[@intFromEnum(which)];
    }
};

/// A theme, as read from its file.
pub const Theme = struct {
    /// The path it was read from, as `Project.canonical` spells it, or the
    /// name it was given.
    source: []const u8,
    /// Whether there is a file to read again, or only text it was given.
    on_disc: bool,
    /// The theme this one is laid over, or `.none`, and the path it was
    /// named by. The path is kept because the theme it names is read after
    /// this one, not while it is being read: a theme that reads another
    /// while the table is being changed would be reading a moving table.
    base: ThemeHandle = .none,
    base_path: []const u8 = "",
    /// What text is drawn in where nothing nearer says.
    font: Assets.FontHandle = .none,
    font_size: u16 = 0,
    types: std.ArrayList(Type) = .empty,
    /// Stepped whenever what it says changes, so that what was drawn from it
    /// knows to be drawn again.
    revision: u32 = 1,
    /// Holds the type names, and the list they are in.
    arena: std.heap.ArenaAllocator,

    pub fn typeNamed(self: *const Theme, name: []const u8) ?*const Type {
        for (self.types.items) |*held| {
            if (std.mem.eql(u8, held.name, name)) return held;
        }
        return null;
    }

    /// The same, to change: for the theme editor.
    pub fn typeMut(self: *Theme, name: []const u8) ?*Type {
        for (self.types.items) |*held| {
            if (std.mem.eql(u8, held.name, name)) return held;
        }
        return null;
    }

    /// The type called `name`, made if the theme has none.
    pub fn ensureType(self: *Theme, name: []const u8) !*Type {
        if (self.typeMut(name)) |held| return held;
        const gpa = self.arena.allocator();
        try self.types.append(gpa, .{ .name = try gpa.dupe(u8, name) });
        return &self.types.items[self.types.items.len - 1];
    }

    /// Say that what it holds has changed, so that what was drawn from it is
    /// drawn again.
    pub fn touched(self: *Theme) void {
        self.revision +%= 1;
    }

    fn deinitContent(self: *Theme, gpa: Allocator) void {
        _ = gpa;
        self.arena.deinit();
    }
};

/// Every theme read, and the handles they are found by.
pub const Themes = struct {
    table: Table = .empty,

    pub fn deinit(self: *Themes, gpa: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.value.source);
            entry.value.deinitContent(gpa);
        }
        self.table.deinit(gpa);
    }

    /// Read a `.theme` file, or find the one read from there already. A file
    /// that reads and does not make sense is kept, empty, and why is said in
    /// the log.
    pub fn load(self: *Themes, app: *App, path: []const u8) !ThemeHandle {
        // One read already under this very name is the one meant, whether it
        // came from a file or from text a tool gave.
        if (self.find(path)) |known| return known;
        const io = app.io orelse return error.NoIo;
        const source = try app.project.canonical(app.gpa, path);
        defer app.gpa.free(source);
        if (self.find(source)) |known| return known;

        const file = try app.project.osPath(app.gpa, source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        defer app.gpa.free(text);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(app, source, text, true);
    }

    /// A theme from text, not a file: a test's, or a tool's.
    pub fn add(self: *Themes, app: *App, name: []const u8, text: []const u8) !ThemeHandle {
        if (self.find(name)) |known| {
            try self.setText(app, known, text);
            return known;
        }
        return self.keep(app, name, text, false);
    }

    fn keep(self: *Themes, app: *App, source: []const u8, text: []const u8, on_disc: bool) !ThemeHandle {
        const gpa = app.gpa;
        const name = try gpa.dupe(u8, source);
        errdefer gpa.free(name);
        var made: Theme = .{ .source = name, .on_disc = on_disc, .arena = .init(gpa) };
        read(app, &made, text) catch |err| switch (err) {
            error.OutOfMemory => {
                made.deinitContent(gpa);
                return error.OutOfMemory;
            },
            // Said already; kept empty, so what names it still opens.
            else => {},
        };
        errdefer made.deinitContent(gpa);
        const handle: ThemeHandle = .fromId(try self.table.add(gpa, made));
        try self.resolveBase(app, handle);
        return handle;
    }

    /// Read the theme a theme is laid over, once the one naming it is in the
    /// table: reading it sooner would be reading a table being written to.
    /// Its errors are said here rather than passed on, which is also what
    /// keeps `load` from reaching back into itself through this.
    fn resolveBase(self: *Themes, app: *App, handle: ThemeHandle) Allocator.Error!void {
        const path = blk: {
            const held = self.table.get(handle.toId()) orelse return;
            if (held.base_path.len == 0) break :blk null;
            break :blk try app.gpa.dupe(u8, held.base_path);
        } orelse return;
        defer app.gpa.free(path);
        const based = self.load(app, path) catch |err| {
            const held = self.table.get(handle.toId()) orelse return;
            log.warn("{s}: the base theme {s} does not read: {t}", .{ held.source, path, err });
            return;
        };
        const held = self.table.get(handle.toId()) orelse return;
        if (!based.eql(handle)) held.base = based;
    }

    /// New text for a theme: an editor's, before it saves. Text that does not
    /// make sense leaves what the theme said before, and says why.
    pub fn setText(self: *Themes, app: *App, handle: ThemeHandle, text: []const u8) !void {
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTheme;
        var fresh: Theme = .{
            .source = held.source,
            .on_disc = held.on_disc,
            .revision = held.revision +% 1,
            .arena = .init(app.gpa),
        };
        read(app, &fresh, text) catch |err| {
            fresh.deinitContent(app.gpa);
            return if (err == error.OutOfMemory) error.OutOfMemory else {};
        };
        held.deinitContent(app.gpa);
        held.* = fresh;
        try self.resolveBase(app, handle);
    }

    /// Read a theme's file again. Says whether there was a file to read.
    pub fn reload(self: *Themes, app: *App, handle: ThemeHandle) !bool {
        const held = self.table.get(handle.toId()) orelse return false;
        if (!held.on_disc) return false;
        const io = app.io orelse return error.NoIo;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, file, app.gpa, .limited(file_limit));
        defer app.gpa.free(text);
        try self.setText(app, handle, text);
        return true;
    }

    /// The handle of a theme read already, by the path or name it was read by.
    pub fn find(self: *Themes, source: []const u8) ?ThemeHandle {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return .fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *Themes, handle: ThemeHandle) ?*const Theme {
        return self.table.get(handle.toId());
    }

    /// A theme to change, for a tool: the theme editor.
    pub fn edit(self: *Themes, handle: ThemeHandle) ?*Theme {
        return self.table.get(handle.toId());
    }

    pub fn sourceOf(self: *Themes, handle: ThemeHandle) ?[]const u8 {
        const held = self.table.get(handle.toId()) orelse return null;
        return held.source;
    }

    /// What a control is drawn with: what the theme says about `part` in
    /// `state`, laid over what this engine is born with.
    ///
    /// `variation` is a name a `Control` asked for; it is looked at first, and
    /// what it does not say its `base_type` does. Nothing found anywhere
    /// leaves the built-in look, so a scene with no theme still draws.
    pub fn styleOf(self: *Themes, handle: ThemeHandle, part: Part, state: State, variation: []const u8) Style {
        var out: Style = builtIn(part, state);
        // The oldest base theme first, so that a nearer one lies over it.
        var chain: [most_links]ThemeHandle = undefined;
        var count: usize = 0;
        var at = handle;
        while (count < most_links) : (count += 1) {
            const held = self.table.get(at.toId()) orelse break;
            chain[count] = at;
            if (held.base.isNone() or held.base.eql(at)) {
                count += 1;
                break;
            }
            at = held.base;
        }
        while (count > 0) {
            count -= 1;
            const held = self.table.get(chain[count].toId()) orelse continue;
            out = self.fromTheme(held, part.typeName(), state).over(out);
            if (variation.len > 0) out = self.fromTheme(held, variation, state).over(out);
        }
        return out;
    }

    /// What one theme says about a type, with what it is built on under it.
    fn fromTheme(self: *Themes, theme: *const Theme, name: []const u8, state: State) Style {
        _ = self;
        var out: Style = .{};
        // The type it is built on first, so that the type itself wins.
        var chain: [most_links][]const u8 = undefined;
        var count: usize = 0;
        var at = name;
        while (count < most_links) : (count += 1) {
            chain[count] = at;
            const held = theme.typeNamed(at) orelse {
                count += 1;
                break;
            };
            if (held.base_type.len == 0 or std.mem.eql(u8, held.base_type, at)) {
                count += 1;
                break;
            }
            at = held.base_type;
        }
        while (count > 0) {
            count -= 1;
            const held = theme.typeNamed(chain[count]) orelse continue;
            out = held.shared.over(out);
            // A state says only what it changes; the rest is `normal`.
            out = held.state(.normal).over(out);
            if (state != .normal) out = held.state(state).over(out);
        }
        if (out.font == null and !theme.font.isNone()) out.font = theme.font;
        if (out.font_size == null and theme.font_size > 0) out.font_size = theme.font_size;
        return out;
    }

    /// Give each theme of the project's that has no UUID one, in a `.uid`
    /// file beside it, as `Assets.ensureUids` does for textures.
    pub fn ensureUids(self: *Themes, project: *Project) !void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (entry.value.on_disc and Project.isProjectPath(entry.value.source)) _ = try project.ensureUid(entry.value.source);
        }
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Themes, gpa: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(gpa, u8, &.{ new, rest });
            gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }

    /// The theme as its file would be, into fresh memory. The caller frees it.
    pub fn textOf(self: *Themes, app: *App, gpa: Allocator, handle: ThemeHandle) ![]u8 {
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTheme;
        return json.stringify(gpa, Document{ .theme = held, .themes = self, .assets = &app.assets }, write_options);
    }

    /// Write a theme back to the file it was read from, and give it a UUID if
    /// it has none.
    pub fn save(self: *Themes, app: *App, handle: ThemeHandle) !void {
        const io = app.io orelse return error.NoIo;
        const held = self.table.get(handle.toId()) orelse return error.NoSuchTheme;
        if (!held.on_disc) return error.NotAFile;
        const file = try app.project.osPath(app.gpa, held.source);
        defer app.gpa.free(file);
        try json.save(io, file, Document{ .theme = held, .themes = self, .assets = &app.assets }, write_options);
        if (Project.isProjectPath(held.source)) _ = try app.project.ensureUid(held.source);
    }
};

// -------------------------------------------------------------------------
// The look this engine is born with
// -------------------------------------------------------------------------

/// The few colours every built-in style is mixed from. A theme file that
/// says nothing leaves exactly this, which is the look the engine had before
/// there were theme files at all.
pub const Palette = struct {
    pub const panel: Color = .hex(0x20242A);
    pub const field: Color = .hex(0x171A1F);
    pub const button: Color = .hex(0x3A6EA5);
    pub const button_hover: Color = .hex(0x4B82BA);
    pub const button_pressed: Color = .hex(0x285780);
    pub const disabled: Color = .hex(0x30343A);
    pub const accent: Color = .hex(0x3A80D8);
    pub const border: Color = .hex(0x59616B);
    pub const focus: Color = .hex(0x72A7E8);
    pub const text: Color = .white;
    pub const disabled_text: Color = .hex(0x808080);
    pub const corner_radius: f32 = 6;
    pub const border_width: u16 = 1;
    pub const padding: Insets = .all(6);
    pub const font_size: u16 = 16;
};

/// What a part looks like in a state before any theme is asked.
pub fn builtIn(part: Part, state: State) Style {
    const off = state == .disabled;
    const background: Color = switch (part) {
        .panel => Palette.panel,
        .line_edit => if (off) Palette.disabled else Palette.field,
        .button, .tab, .tab_active => if (off) Palette.disabled else switch (state) {
            .hover, .focus => Palette.button_hover,
            .pressed => Palette.button_pressed,
            else => if (part == .tab_active) Palette.accent else Palette.button,
        },
        .check_box, .focus, .label => .transparent,
        .slider_track, .progress_track => if (off) Palette.disabled else Palette.field,
        .slider_fill, .progress_fill => if (off) Palette.disabled else Palette.accent,
    };
    return .{
        .background = background,
        .border_color = if (state == .focus) Palette.focus else Palette.border,
        .border_width = if (part == .label) 0 else Palette.border_width,
        .corners = .all(Palette.corner_radius),
        .padding = Palette.padding,
        .font_color = if (off) Palette.disabled_text else Palette.text,
        .font_size = Palette.font_size,
    };
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// Fill `into`, which has no content yet, from a file's text.
fn read(app: *App, into: *Theme, text: []const u8) !void {
    const gpa = app.gpa;
    var diagnostics: json.Diagnostics = .{};
    diagnostics.setFile(into.source);
    var document = json.parse(gpa, text, .{ .syntax = .json5, .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("{f}", .{diagnostics});
            return err;
        },
    };
    defer document.deinit();
    const root = document.root;

    const said = root.get("fluxion_theme").asInt(u32) orelse {
        log.warn("{s} is not a theme: it has no fluxion_theme version", .{into.source});
        return error.NotATheme;
    };
    if (said != version) {
        log.warn("{s} is theme version {d}, and this engine reads version {d}", .{ into.source, said, version });
        return error.UnsupportedVersion;
    }

    if (root.get("base").asString()) |path| {
        if (std.mem.eql(u8, path, into.source)) {
            log.warn("{s} is its own base theme; it is left without one", .{into.source});
        } else {
            into.base_path = try into.arena.allocator().dupe(u8, path);
        }
    }
    if (root.get("font").asString()) |path| into.font = fontOf(app, into.source, path);
    if (root.get("font_size").asInt(u16)) |size| into.font_size = size;

    const types = root.get("types");
    const object = switch (types) {
        .object => |held| held,
        .null => return,
        else => {
            log.warn("{s}: `types` is not an object", .{into.source});
            return error.WrongType;
        },
    };
    const arena = into.arena.allocator();
    for (object.map.keys(), object.map.values()) |name, given| {
        if (into.typeNamed(name) != null) {
            log.warn("{s} says `{s}` twice; the second is passed over", .{ into.source, name });
            continue;
        }
        var made: Type = .{ .name = try arena.dupe(u8, name) };
        if (given.get("base_type").asString()) |base| made.base_type = try arena.dupe(u8, base);
        made.shared = try readStyle(app, into, given);
        const styles = given.get("styles");
        if (styles == .object) {
            for (styles.object.map.keys(), styles.object.map.values()) |state_name, style| {
                const which = stateNamed(state_name) orelse {
                    log.warn("{s}: `{s}` is not a state of {s}", .{ into.source, state_name, name });
                    continue;
                };
                made.states[@intFromEnum(which)] = try readStyle(app, into, style);
            }
        }
        try into.types.append(arena, made);
    }
}

/// What one object says about how a box is drawn. Everything is optional:
/// what is not there is not said.
fn readStyle(app: *App, into: *Theme, given: json.Value) !Style {
    var out: Style = .{};
    if (given != .object) return out;
    out.background = colorOf(into.source, given.get("background"));
    out.border_color = colorOf(into.source, given.get("border_color"));
    out.border_width = given.get("border").asInt(u16);
    if (given.get("corners").asFloat(f32)) |radius| out.corners = .all(radius);
    out.padding = insetsOf(given.get("padding"));
    if (given.get("texture").asString()) |path| {
        out.texture = app.assets.findTexture(path) orelse app.assets.loadTexture(path, .{}) catch |err| blk: {
            log.warn("{s}: the texture {s} does not read: {t}", .{ into.source, path, err });
            break :blk .none;
        };
    }
    out.tint = colorOf(into.source, given.get("tint"));
    const slices = given.get("slices");
    if (slices == .array and slices.array.len() == 4) {
        out.slices = .{
            slices.get(@as(usize, 0)).asFloat(f32) orelse 0.25,
            slices.get(@as(usize, 1)).asFloat(f32) orelse 0.25,
            slices.get(@as(usize, 2)).asFloat(f32) orelse 0.25,
            slices.get(@as(usize, 3)).asFloat(f32) orelse 0.25,
        };
    }
    out.patch_margin = insetsOf(given.get("patch_margin"));
    out.font_color = colorOf(into.source, given.get("font_color"));
    if (given.get("font").asString()) |path| out.font = fontOf(app, into.source, path);
    out.font_size = given.get("font_size").asInt(u16);
    return out;
}

fn fontOf(app: *App, source: []const u8, path: []const u8) Assets.FontHandle {
    return app.assets.findFont(path) orelse app.assets.loadFont(path, .{}) catch |err| blk: {
        log.warn("{s}: the font {s} does not read: {t}", .{ source, path, err });
        break :blk .none;
    };
}

/// `[across, down]`, or one number for both.
fn insetsOf(given: json.Value) ?Insets {
    if (given.asInt(u16)) |same| return .all(same);
    if (given != .array or given.array.len() != 2) return null;
    return .xy(
        given.get(@as(usize, 0)).asInt(u16) orelse 0,
        given.get(@as(usize, 1)).asInt(u16) orelse 0,
    );
}

/// `#RRGGBB` or `#RRGGBBAA`, as a stylesheet writes one.
fn colorOf(source: []const u8, given: json.Value) ?Color {
    const text = given.asString() orelse return null;
    return parseHex(text) orelse {
        log.warn("{s}: {s} is not a colour; one is written #RRGGBB or #RRGGBBAA", .{ source, text });
        return null;
    };
}

pub fn parseHex(text: []const u8) ?Color {
    const digits = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (digits.len != 6 and digits.len != 8) return null;
    var value: u32 = 0;
    for (digits) |digit| {
        const nibble = std.fmt.charToDigit(digit, 16) catch return null;
        value = value << 4 | nibble;
    }
    return if (digits.len == 6) .hex(@intCast(value)) else .hexa(value);
}

fn stateNamed(name: []const u8) ?State {
    inline for (@typeInfo(State).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return @enumFromInt(field.value);
    }
    return null;
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Two spaces and a newline, as the rest of the project's files are written.
const write_options: json.WriteOptions = .{ .indent = 2 };

/// A theme as its file, for `json.save` and `json.stringify`. Only what the
/// theme says is written: a field nothing set stays unsaid.
const Document = struct {
    theme: *const Theme,
    themes: *Themes,
    assets: *Assets,

    pub fn toJson(self: Document, w: *json.Writer) json.Writer.Error!void {
        try w.beginObject();
        try w.field("fluxion_theme", @as(u32, version));
        if (self.themes.sourceOf(self.theme.base) orelse emptyAsNull(self.theme.base_path)) |path| try w.field("base", path);
        if (self.assets.fontSource(self.theme.font)) |path| try w.field("font", path);
        if (self.theme.font_size > 0) try w.field("font_size", self.theme.font_size);
        try w.key("types");
        try w.beginObject();
        for (self.theme.types.items) |*held| try self.writeType(w, held);
        try w.endObject();
        try w.endObject();
    }

    fn writeType(self: Document, w: *json.Writer, held: *const Type) json.Writer.Error!void {
        try w.key(held.name);
        try w.beginObject();
        if (held.base_type.len > 0) try w.field("base_type", held.base_type);
        try self.writeStyle(w, held.shared);
        var any = false;
        for (held.states) |style| any = any or !style.isEmpty();
        if (any) {
            try w.key("styles");
            try w.beginObject();
            inline for (@typeInfo(State).@"enum".fields) |field| {
                const style = held.states[field.value];
                if (!style.isEmpty()) {
                    try w.key(field.name);
                    try w.beginObject();
                    try self.writeStyle(w, style);
                    try w.endObject();
                }
            }
            try w.endObject();
        }
        try w.endObject();
    }

    /// The fields of a style that were said, inside an object the caller
    /// opened.
    fn writeStyle(self: Document, w: *json.Writer, style: Style) json.Writer.Error!void {
        var buffer: [16]u8 = undefined;
        if (style.background) |value| try w.field("background", hexOf(&buffer, value));
        if (style.border_color) |value| try w.field("border_color", hexOf(&buffer, value));
        if (style.border_width) |value| try w.field("border", value);
        if (style.corners) |value| try w.field("corners", value.top_left);
        if (style.padding) |value| try w.field("padding", [2]u16{ value.left, value.top });
        if (style.texture) |value| {
            if (self.assets.get(value)) |texture| try w.field("texture", texture.source);
        }
        if (style.tint) |value| try w.field("tint", hexOf(&buffer, value));
        if (style.slices) |value| try w.field("slices", value);
        if (style.patch_margin) |value| try w.field("patch_margin", [2]u16{ value.left, value.top });
        if (style.font_color) |value| try w.field("font_color", hexOf(&buffer, value));
        if (style.font) |value| {
            if (self.assets.fontSource(value)) |path| try w.field("font", path);
        }
        if (style.font_size) |value| try w.field("font_size", value);
    }
};

/// `#RRGGBB`, or `#RRGGBBAA` where it is not opaque.
pub fn hexOf(buffer: []u8, value: Color) []const u8 {
    const r = byteOf(value.r);
    const g = byteOf(value.g);
    const b = byteOf(value.b);
    const a = byteOf(value.a);
    return if (a == 255)
        std.fmt.bufPrint(buffer, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch ""
    else
        std.fmt.bufPrint(buffer, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a }) catch "";
}

fn emptyAsNull(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

fn byteOf(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const purple =
    \\{
    \\  "fluxion_theme": 1,
    \\  "font_size": 18,
    \\  "types": {
    \\    "Button": {
    \\      "font_color": "#F2EEF8",
    \\      "styles": {
    \\        "normal": { "background": "#6B4FC8", "corners": 4, "padding": [10, 5] },
    \\        "hover": { "background": "#8F72E8" }
    \\      }
    \\    },
    \\    "Header": { "base_type": "Button", "font_size": 24 }
    \\  }
    \\}
;

test "a theme says what it changes, and the rest is what the engine is born with" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const handle = try app.themes.add(app, "purple.theme", purple);

    const normal = app.themes.styleOf(handle, .button, .normal, "");
    try testing.expectEqual(@as(f32, 4), normal.corners.?.top_left);
    try testing.expectEqualDeep(parseHex("#6B4FC8").?, normal.background.?);
    try testing.expectEqual(@as(u16, 10), normal.padding.?.left);
    try testing.expectEqual(@as(u16, 5), normal.padding.?.top);
    // Said by the theme, not by the part.
    try testing.expectEqual(@as(u16, 18), normal.font_size.?);
    // Left unsaid, so the built-in look holds.
    try testing.expectEqual(Palette.border_width, normal.border_width.?);

    // A state says only what it changes; the rest comes from `normal`.
    const hover = app.themes.styleOf(handle, .button, .hover, "");
    try testing.expectEqualDeep(parseHex("#8F72E8").?, hover.background.?);
    try testing.expectEqual(@as(f32, 4), hover.corners.?.top_left);

    // A part the theme never mentions is drawn as it always was.
    const panel = app.themes.styleOf(handle, .panel, .normal, "");
    try testing.expectEqualDeep(Palette.panel, panel.background.?);
}

test "a variation is laid over the type it is built on" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const handle = try app.themes.add(app, "purple.theme", purple);

    const header = app.themes.styleOf(handle, .button, .normal, "Header");
    try testing.expectEqual(@as(u16, 24), header.font_size.?);
    // What the variation does not say, the type it is built on does.
    try testing.expectEqualDeep(parseHex("#6B4FC8").?, header.background.?);
    // And a control that does not ask for it is untouched.
    const plain = app.themes.styleOf(handle, .button, .normal, "");
    try testing.expectEqual(@as(u16, 18), plain.font_size.?);
}

test "a base theme is under the theme that names it" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    _ = try app.themes.add(app, "base.theme",
        \\{ "fluxion_theme": 1, "types": { "Button": { "styles": { "normal": { "background": "#111111", "corners": 9 } } } } }
    );
    const handle = try app.themes.add(app, "over.theme",
        \\{ "fluxion_theme": 1, "base": "base.theme", "types": { "Button": { "styles": { "normal": { "background": "#222222" } } } } }
    );

    const style = app.themes.styleOf(handle, .button, .normal, "");
    try testing.expectEqualDeep(parseHex("#222222").?, style.background.?);
    try testing.expectEqual(@as(f32, 9), style.corners.?.top_left);
}

test "a theme written back reads as the theme it was" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();
    const handle = try app.themes.add(app, "purple.theme", purple);

    const text = try app.themes.textOf(app, testing.allocator, handle);
    defer testing.allocator.free(text);
    const again = try app.themes.add(app, "again.theme", text);
    const style = app.themes.styleOf(again, .button, .hover, "");
    try testing.expectEqualDeep(parseHex("#8F72E8").?, style.background.?);
    try testing.expectEqual(@as(u16, 18), style.font_size.?);
    try testing.expectEqual(@as(u16, 24), app.themes.styleOf(again, .button, .normal, "Header").font_size.?);

    // Written twice, the same file both times.
    const twice = try app.themes.textOf(app, testing.allocator, again);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(text, twice);
}

test "a theme that does not read is kept empty, and new text that does not read leaves the old" {
    const app = try App.create(testing.allocator, .{ .headless = true });
    defer app.destroy();

    const broken = try app.themes.add(app, "broken.theme", "{ \"fluxion_theme\": 1, \"types\": 7 }");
    try testing.expectEqual(@as(usize, 0), app.themes.get(broken).?.types.items.len);

    const handle = try app.themes.add(app, "purple.theme", purple);
    const before = app.themes.get(handle).?.revision;
    try app.themes.setText(app, handle, "{ not a theme");
    try testing.expectEqual(before, app.themes.get(handle).?.revision);
    try testing.expectEqualDeep(parseHex("#6B4FC8").?, app.themes.styleOf(handle, .button, .normal, "").background.?);
}

test "a colour is read and written the way a stylesheet writes one" {
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("#6B4FC8", hexOf(&buffer, parseHex("#6b4fc8").?));
    try testing.expectEqualStrings("#12345680", hexOf(&buffer, parseHex("#12345680").?));
    try testing.expect(parseHex("#12345") == null);
    try testing.expect(parseHex("purple") == null);
}
