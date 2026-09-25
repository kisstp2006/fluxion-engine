// SPDX-License-Identifier: BSD-3-Clause

//! Sound: clips read from `.wav`, `.ogg` and `.mp3` files, played by the
//! entities that have an `AudioPlayer`, and mixed on the project's buses.
//!
//! ```zig
//! const door = try app.loadAudio("res://sounds/door.ogg");
//! const creak = try app.world.spawnWith(.{ fx.Transform2D.at(400, 300), fx.AudioPlayer{ .clip = door }, fx.AudioSpatial2D{} });
//! app.world.get(creak, fx.AudioPlayer).?.play(0);
//! try app.signal(creak, fx.AudioPlayer, .finished).connect(.method(creak, "_on_creak_finished"), .{});
//! _ = app.setBusVolumeDb("Music", -6);
//! ```
//!
//! **A player is data.** Its clip, its volume in decibels, its pitch - which
//! plays it faster and higher, as a record sped up does - its bus, whether it
//! loops, whether it is held: what the engine's audio pass makes its sound
//! do, once a frame after the game's `.late` systems. `play`, `stop` and
//! `seek` ask that pass, and `playing` and `position` say what it found.
//! `finished` is said when a sound that does not loop comes to its end.
//!
//! **A player plays while its entity runs.** A paused game's sounds are held
//! where they are, but for those under something whose `Processing` runs
//! while it is paused - a pause menu's. And a frame that gives no time starts
//! nothing: an editor, whose world never has time, never starts the sounds
//! of the scene it edits.
//!
//! **In the world**, with an `AudioSpatial2D` beside it, a player is quieter
//! the farther it is from the listener - the `AudioListener2D` that is
//! `current`, or with none the middle of what the camera shows - and panned
//! to the side it is on.
//!
//! **Buses** are the project's `audio.buses`: each with its volume, muted or
//! not, and sending into another; `Master` is always there, and everything
//! ends in it. A game turns them up and down with `setBusVolumeDb`, from Zig
//! and from Flux.
//!
//! **With no sound device** - headless, or on a machine with none - the
//! engine mixes each frame's sound itself and plays it nowhere, so a game
//! hears `finished` and reads `position` the same everywhere. `Options.audio`
//! asks for that on purpose.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ecs = @import("fluxion_ecs");
const id = @import("fluxion_id");
const math = @import("fluxion_math");
const sound = @import("fluxion_audio");

const App = @import("App.zig");
const Project = @import("Project.zig");
const attr = @import("attr.zig");
const file_table = @import("file_table.zig");
const View = @import("render/view.zig").View;

const Entity = ecs.Entity;
const Vec2 = math.Vec2;
const log = std.log.scoped(.fluxion_engine);

/// A clip read: see `Audio`. What a player names its sound by.
pub const AudioClipHandle = file_table.Handle("AudioClipHandle");

/// WAVE files, read and written: what a test or a tool makes a sound of.
pub const wav = sound.wav;

/// The endings of the files a clip is read from.
pub const extensions = [_][]const u8{ ".wav", ".ogg", ".mp3" };

/// The name of the bus everything ends in, which is always there.
pub const master = "Master";

/// What is taken as silence, in decibels, and the loudest a bus or a player
/// is turned up to.
pub const silent_db: f32 = -80;
pub const loudest_db: f32 = 24;

/// Decibels as the factor they multiply a sound by: 0 is 1, -6 about a half,
/// and `silent_db` or below nothing.
pub fn dbToLinear(db: f32) f32 {
    if (db <= silent_db) return 0;
    return std.math.pow(f32, 10, db / 20);
}

/// The other way: 1 is 0, a half about -6, and nothing `silent_db`.
pub fn linearToDb(linear: f32) f32 {
    if (!(linear > 0)) return silent_db;
    return @max(20 * std.math.log10(linear), silent_db);
}

/// How long a bus's name may be, in a player.
pub const bus_name_len = 32;

fn named(comptime text: []const u8) [bus_name_len]u8 {
    var out: [bus_name_len]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

fn nameIn(buffer: *const [bus_name_len]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

// -------------------------------------------------------------------------
// Components
// -------------------------------------------------------------------------

/// A sound its entity plays. See the top of this file.
pub const AudioPlayer = extern struct {
    clip: AudioClipHandle = .none,
    /// 0 plays the clip as loud as it is; -6 about half as loud.
    volume_db: f32 = 0,
    /// Above 1 faster and higher, below 1 slower and lower: 2 is an octave
    /// up at twice the speed. For a sound a little different each time.
    pitch: f32 = 1,
    /// The bus it is mixed on, by name. See `busName` and `setBus`.
    bus: [bus_name_len]u8 = named(master),
    /// Whether it starts by itself the first time the game plays its entity.
    autoplay: bool = false,
    /// From the start again at the end, rather than stopping.
    loop: bool = false,
    /// Held where it is while on.
    paused: bool = false,
    /// Whether it plays - held or not - as of this frame's audio pass, and
    /// at once from a `play`.
    playing: bool = false,
    /// Seconds into the clip, as of this frame's audio pass.
    position: f32 = 0,
    /// What `play`, `stop` and `seek` asked the audio pass for.
    request: Request = .none,
    /// Where `play` and `seek` asked to go, in seconds.
    from: f32 = 0,
    /// Whether the audio pass has looked at it yet, and so at `autoplay`.
    started: bool = false,

    pub const Request = enum(u8) { none, play, stop, seek };

    pub const signals = .{ .finished = struct {} };

    pub const reflect_name = "AudioPlayer";
    pub const reflect_fields = .{
        .volume_db = .{ attr.Unit{ .text = "dB" }, attr.Range{ .min = silent_db, .max = loudest_db } },
        .pitch = .{ attr.Range{ .min = 0.01, .max = 4 }, attr.Doc{ .text = "Faster and higher above 1, slower and lower below" } },
        .bus = .{ attr.AudioBus{}, attr.Doc{ .text = "The bus it is mixed on" } },
        .autoplay = .{attr.Doc{ .text = "Starts by itself when the game first plays its entity" }},
        .loop = .{attr.Doc{ .text = "From the start again at the end" }},
        .paused = .{attr.Doc{ .text = "Held where it is" }},
        .playing = .{attr.ReadOnly{}},
        .position = .{ attr.ReadOnly{}, attr.Unit{ .text = "s" } },
        .request = .{attr.Hidden{}},
        .from = .{attr.Hidden{}},
        .started = .{attr.Hidden{}},
    };
    pub const reflect_methods = .{ .play, .stop, .seek, .busName, .setBus };

    /// Play from `from` seconds in - from the start of the sound it plays
    /// already, too.
    pub fn play(self: *AudioPlayer, from: f32) void {
        self.request = .play;
        self.from = @max(from, 0);
        self.playing = true;
    }

    /// Stop, back at the start, saying nothing.
    pub fn stop(self: *AudioPlayer) void {
        self.request = .stop;
        self.playing = false;
    }

    /// To `to` seconds in, playing or held as it is.
    pub fn seek(self: *AudioPlayer, to: f32) void {
        if (self.request == .play) {
            self.from = @max(to, 0);
            return;
        }
        self.request = .seek;
        self.from = @max(to, 0);
    }

    pub fn busName(self: *const AudioPlayer) []const u8 {
        return nameIn(&self.bus);
    }

    /// Mixed on the bus called `name` - cut at `bus_name_len` - from the
    /// next audio pass. A bus the project has not is `Master`.
    pub fn setBus(self: *AudioPlayer, name: []const u8) void {
        self.bus = @splat(0);
        const kept = @min(name.len, bus_name_len);
        @memcpy(self.bus[0..kept], name[0..kept]);
    }
};

/// Beside an `AudioPlayer` and a `Transform2D`: the player is quieter the
/// farther it is from the listener, and panned to the side it is on.
pub const AudioSpatial2D = extern struct {
    /// Past this far from the listener it is not heard at all.
    max_distance: f32 = 2000,
    /// How it falls off: 1 evenly with the distance, more sooner, less later.
    attenuation: f32 = 1,
    /// How far to the side it is panned, from none to all the way.
    panning: f32 = 1,

    pub const reflect_name = "AudioSpatial2D";
    pub const reflect_fields = .{
        .max_distance = .{ attr.Unit{ .text = "px" }, attr.Range{ .min = 1, .max = 100000 } },
        .attenuation = .{ attr.Range{ .min = 0.01, .max = 16 }, attr.Doc{ .text = "1 falls off evenly; more falls off sooner" } },
        .panning = .{ attr.Range{ .min = 0, .max = 1 }, attr.Doc{ .text = "How far to the side it is panned" } },
    };
};

/// Where the sounds in the world are heard from, beside a `Transform2D`:
/// the first found that is `current`. With none, the middle of what the
/// camera shows.
pub const AudioListener2D = extern struct {
    current: bool = true,

    pub const reflect_name = "AudioListener2D";
};

// -------------------------------------------------------------------------
// The project's buses
// -------------------------------------------------------------------------

/// A bus, as the project's `audio.buses` lists it.
pub const Bus = struct {
    name: []const u8 = "",
    volume_db: f32 = 0,
    mute: bool = false,
    /// The bus it is mixed into: `Master`, or another, which must not come
    /// back round to it.
    send: []const u8 = master,

    pub const reflect_fields = .{
        .volume_db = .{ attr.Unit{ .text = "dB" }, attr.Range{ .min = silent_db, .max = loudest_db } },
        .send = .{ attr.AudioBus{}, attr.Doc{ .text = "The bus it is mixed into" } },
    };
};

// -------------------------------------------------------------------------
// The sound device, the clips, and what plays
// -------------------------------------------------------------------------

/// What `Options.audio` asks for.
pub const Output = enum {
    /// The machine's sound device - and with none, or headless, `silent`.
    auto,
    /// No sound device: each frame's sound is mixed and played nowhere.
    silent,
};

/// The rate and the channels sound is mixed at when nothing plays it.
const silent_rate = 44100;
const silent_channels = 2;

/// One clip read.
pub const Clip = struct {
    /// The path or name it was read by.
    source: []u8,
    clip: sound.Clip,
    info: sound.ClipInfo,
    /// Whether it came from a file.
    on_disc: bool,
};

const Clips = id.handle.Table(Clip);

fn toId(handle: AudioClipHandle) Clips.Handle {
    return @bitCast(handle);
}

fn fromId(handle: Clips.Handle) AudioClipHandle {
    return @bitCast(handle);
}

/// A bus as it is mixed: `app.audio.buses`, `Master` first.
pub const MixedBus = struct {
    name: []u8,
    submix: sound.Submix,
    volume_db: f32,
    mute: bool,
    /// Which of the buses it is mixed into; `Master`'s is its own.
    send: usize,
};

/// What an entity's player is playing, and what its voice was last told.
const Playing = struct {
    voice: sound.Voice,
    clip: AudioClipHandle,
    /// How many times the voice had ended when last looked at.
    ends: u32,
    gain: f32,
    pan: f32,
    speed: f32,
    loop: bool,
    held: bool,
    bus: usize,
};

/// The app's sound: `app.audio`.
pub const Audio = struct {
    gpa: Allocator,
    device: sound.Device,
    /// Whether nothing plays the device's sound, so the engine mixes each
    /// frame's worth itself.
    silent: bool,
    clips: Clips = .empty,
    buses: std.ArrayList(MixedBus) = .empty,
    /// What each entity's player is playing.
    voices: std.AutoArrayHashMapUnmanaged(Entity, Playing) = .empty,
    /// A clip an editor plays to be heard, of no entity's.
    preview: ?sound.Voice = null,
    /// Where a silent device's sound is mixed, and the part of a frame the
    /// last mix owed.
    scratch: std.ArrayList(f32) = .empty,
    owed: f64 = 0,
    /// The players whose sound ended this pass, to say so after it.
    ended: std.ArrayList(Entity) = .empty,

    pub fn init(gpa: Allocator, output: Output, headless: bool, buses: []const Bus) !Audio {
        const real = output == .auto and !headless;
        const device: sound.Device, const silent: bool = if (real) blk: {
            if (soundCard()) |which| {
                if (sound.Device.init(gpa, .{ .backend = which })) |opened| break :blk .{ opened, false } else |err| {
                    log.warn("the sound device did not open ({t}): sound is mixed and heard nowhere", .{err});
                }
            }
            break :blk .{ try sound.Device.init(gpa, .{ .backend = .mixer }), true };
        } else .{ try sound.Device.init(gpa, .{ .backend = .mixer }), true };

        var self: Audio = .{ .gpa = gpa, .device = device, .silent = silent };
        errdefer self.deinit();
        try self.makeBuses(buses);
        return self;
    }

    /// The backend that plays through this machine's sound card, if this
    /// build has one.
    fn soundCard() ?sound.Backend {
        for (sound.available()) |which| switch (which) {
            .none, .mixer, .other => {},
            else => return which,
        };
        return null;
    }

    pub fn deinit(self: *Audio) void {
        const gpa = self.gpa;
        var it = self.clips.iterator();
        while (it.next()) |entry| gpa.free(entry.value.source);
        self.clips.deinit(gpa);
        for (self.buses.items) |bus| gpa.free(bus.name);
        self.buses.deinit(gpa);
        self.voices.deinit(gpa);
        self.scratch.deinit(gpa);
        self.ended.deinit(gpa);
        // Every voice, clip and submix goes with the device.
        self.device.deinit();
        self.* = undefined;
    }

    // ---------------------------------------------------------------------
    // Clips
    // ---------------------------------------------------------------------

    /// Read the clip at `path`, or find the one read from there already.
    pub fn load(self: *Audio, app: *App, path: []const u8) !AudioClipHandle {
        if (self.find(path)) |known| return known;
        const source = try app.project.canonical(self.gpa, path);
        defer self.gpa.free(source);
        if (self.find(source)) |known| return known;
        const io = app.io orelse return error.NoIo;

        const file = try app.project.osPath(self.gpa, source);
        defer self.gpa.free(file);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, self.gpa, .limited(file_table.file_limit));
        defer self.gpa.free(bytes);
        if (Project.isProjectPath(source)) {
            _ = app.project.uidOf(source) catch |err|
                log.warn("the {s} file beside {s} does not read: {t}", .{ Project.uid_extension, source, err });
        }
        return self.keep(source, bytes, true);
    }

    /// A clip from memory rather than a file: a test's, or a tool's. Its
    /// format is what its bytes say, or else its name's ending.
    pub fn add(self: *Audio, name: []const u8, bytes: []const u8) !AudioClipHandle {
        return self.keep(name, bytes, false);
    }

    fn keep(self: *Audio, source: []const u8, bytes: []const u8, on_disc: bool) !AudioClipHandle {
        const format = formatOf(source, bytes) orelse return error.UnknownAudioFormat;
        const clip = try self.device.loadClip(.{ .format = format, .bytes = bytes });
        errdefer self.device.unloadClip(clip);
        const name = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(name);
        return fromId(try self.clips.add(self.gpa, .{ .source = name, .clip = clip, .info = self.device.clipInfo(clip).?, .on_disc = on_disc }));
    }

    /// The handle of a clip read already, by the path or name it was read by.
    pub fn find(self: *Audio, source: []const u8) ?AudioClipHandle {
        var it = self.clips.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value.source, source)) return fromId(entry.handle);
        }
        return null;
    }

    pub fn get(self: *Audio, handle: AudioClipHandle) ?*const Clip {
        return self.clips.get(toId(handle));
    }

    pub fn sourceOf(self: *Audio, handle: AudioClipHandle) ?[]const u8 {
        const held = self.get(handle) orelse return null;
        return held.source;
    }

    /// Let a clip go, and whatever plays it stop.
    pub fn unload(self: *Audio, handle: AudioClipHandle) void {
        const held = self.clips.get(toId(handle)) orelse return;
        self.device.unloadClip(held.clip);
        self.gpa.free(held.source);
        _ = self.clips.remove(toId(handle));
    }

    /// The file or folder at `old` is now at `new`.
    pub fn renamed(self: *Audio, old: []const u8, new: []const u8) Allocator.Error!void {
        var it = self.clips.iterator();
        while (it.next()) |entry| {
            if (!entry.value.on_disc) continue;
            const rest = Project.under(entry.value.source, old) orelse continue;
            const moved = try std.mem.concat(self.gpa, u8, &.{ new, rest });
            self.gpa.free(entry.value.source);
            entry.value.source = moved;
        }
    }

    // ---------------------------------------------------------------------
    // Buses
    // ---------------------------------------------------------------------

    fn makeBuses(self: *Audio, given: []const Bus) !void {
        // `Master` first, as the project says it or at its defaults.
        var first: Bus = .{ .name = master };
        for (given) |bus| {
            if (std.mem.eql(u8, bus.name, master)) first = bus;
        }
        try self.addBus(first);
        for (given) |bus| {
            if (bus.name.len == 0 or std.mem.eql(u8, bus.name, master) or self.busIndex(bus.name) != null) continue;
            try self.addBus(bus);
        }
        // Where each goes, once all are there, in the project's order: one
        // that would come back round to itself through those before it goes
        // into `Master`.
        for (self.buses.items[1..], 1..) |*bus, at| {
            for (given) |said| {
                if (!std.mem.eql(u8, said.name, bus.name)) continue;
                bus.send = self.busIndex(said.send) orelse 0;
                break;
            }
            if (self.comesBack(at)) {
                log.warn("the bus {s} sends round to itself: it goes into {s}", .{ bus.name, master });
                bus.send = 0;
            }
            try self.device.setSubmixOutput(bus.submix, self.buses.items[bus.send].submix);
        }
    }

    fn addBus(self: *Audio, bus: Bus) !void {
        const name = try self.gpa.dupe(u8, bus.name);
        errdefer self.gpa.free(name);
        const submix = try self.device.createSubmix(.{ .volume = gainOf(bus.volume_db, bus.mute) });
        errdefer self.device.destroySubmix(submix);
        try self.buses.append(self.gpa, .{ .name = name, .submix = submix, .volume_db = bus.volume_db, .mute = bus.mute, .send = 0 });
    }

    fn comesBack(self: *const Audio, from: usize) bool {
        var at = self.buses.items[from].send;
        for (0..self.buses.items.len) |_| {
            if (at == 0) return false;
            if (at == from) return true;
            at = self.buses.items[at].send;
        }
        return true;
    }

    fn gainOf(db: f32, mute: bool) f32 {
        return if (mute) 0 else dbToLinear(db);
    }

    pub fn busIndex(self: *const Audio, name: []const u8) ?usize {
        for (self.buses.items, 0..) |bus, at| {
            if (std.mem.eql(u8, bus.name, name)) return at;
        }
        return null;
    }

    /// False for a bus there is none of.
    pub fn setBusVolumeDb(self: *Audio, name: []const u8, db: f32) bool {
        const at = self.busIndex(name) orelse return false;
        const bus = &self.buses.items[at];
        bus.volume_db = std.math.clamp(db, silent_db, loudest_db);
        self.device.setSubmixVolume(bus.submix, gainOf(bus.volume_db, bus.mute)) catch {};
        return true;
    }

    pub fn busVolumeDb(self: *const Audio, name: []const u8) ?f32 {
        const at = self.busIndex(name) orelse return null;
        return self.buses.items[at].volume_db;
    }

    pub fn setBusMute(self: *Audio, name: []const u8, mute: bool) bool {
        const at = self.busIndex(name) orelse return false;
        const bus = &self.buses.items[at];
        bus.mute = mute;
        self.device.setSubmixVolume(bus.submix, gainOf(bus.volume_db, bus.mute)) catch {};
        return true;
    }

    pub fn isBusMuted(self: *const Audio, name: []const u8) bool {
        const at = self.busIndex(name) orelse return false;
        return self.buses.items[at].mute;
    }

    // ---------------------------------------------------------------------
    // An editor's
    // ---------------------------------------------------------------------

    /// Play `handle` to be heard - of no entity, on `Master` - in place of
    /// what was played so before.
    pub fn playPreview(self: *Audio, handle: AudioClipHandle) !void {
        self.stopPreview();
        const held = self.get(handle) orelse return error.NoSuchClip;
        self.preview = try self.device.play(held.clip, .{ .output = self.buses.items[0].submix });
    }

    pub fn stopPreview(self: *Audio) void {
        const voice = self.preview orelse return;
        self.device.stop(voice);
        self.preview = null;
    }

    pub fn isPreviewing(self: *Audio) bool {
        const voice = self.preview orelse return false;
        return self.device.isPlaying(voice);
    }

    // ---------------------------------------------------------------------
    // The frame
    // ---------------------------------------------------------------------

    /// Stop everything the players play: the world is cleared.
    pub fn clear(self: *Audio) void {
        for (self.voices.values()) |playing| self.device.stop(playing.voice);
        self.voices.clearRetainingCapacity();
    }

    /// Once a frame, after the game's `.late` systems: every player's
    /// sound as its component says, and `finished` said for the ones that
    /// came to their end.
    pub fn update(self: *Audio, app: *App) !void {
        if (self.silent) try self.mixSilently(app.time.unscaled_delta);
        const flowing = app.time.delta > 0;
        const listener = listenerOf(app);
        self.ended.clearRetainingCapacity();

        var it = ecs.Query(.{AudioPlayer}).over(&app.world) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooManyComponents => return self.forgetTheUnplayed(app),
        };
        while (it.next()) |chunk| {
            for (chunk.entities, chunk.slice(AudioPlayer)) |e, *player| try self.hear(app, e, player, flowing, listener);
        }
        self.forgetTheUnplayed(app);
        for (self.ended.items) |e| try app.emit(e, AudioPlayer, .finished, .{});
    }

    fn hear(self: *Audio, app: *App, e: Entity, player: *AudioPlayer, flowing: bool, listener: Vec2) !void {
        // A clip let go of, or another put in its place, stops the sound.
        if (self.voices.get(e)) |playing| {
            if (self.get(playing.clip) == null or !playing.clip.eql(player.clip)) {
                self.stopOf(e);
                if (player.request != .play) player.playing = false;
            }
        }

        switch (player.request) {
            .none => {},
            .stop => {
                self.stopOf(e);
                player.playing = false;
                player.position = 0;
                player.request = .none;
            },
            // Nothing starts in a frame with no time: it waits for one.
            .play => if (flowing) {
                player.request = .none;
                try self.start(app, e, player, player.from, listener);
            },
            .seek => {
                player.request = .none;
                if (self.voices.get(e)) |playing| {
                    self.device.seek(playing.voice, player.from) catch {};
                    player.position = player.from;
                }
            },
        }
        if (!player.started and flowing) {
            player.started = true;
            if (player.autoplay and player.request == .none and !self.voices.contains(e)) {
                player.playing = true;
                try self.start(app, e, player, 0, listener);
            }
        }
        // A player read back from a save while it played has no voice: it
        // goes on from where it was.
        if (player.playing and player.request == .none and flowing and !self.voices.contains(e)) {
            try self.start(app, e, player, player.position, listener);
        }

        const playing = self.voices.getPtr(e) orelse {
            if (player.request != .play) player.playing = false;
            return;
        };
        const status = self.device.status(playing.voice);
        if (status.ends != playing.ends) {
            self.stopOf(e);
            player.playing = false;
            player.position = 0;
            try self.ended.append(self.gpa, e);
            return;
        }
        player.playing = true;
        player.position = @floatCast(status.position);

        // What changed of the component since the voice was last told.
        const held = player.paused or !app.isProcessing(e);
        if (held != playing.held) {
            self.device.setPaused(playing.voice, held) catch {};
            playing.held = held;
        }
        const heard = heardAs(app, e, player, listener);
        if (@abs(heard.gain - playing.gain) > 1e-4) {
            self.device.setVolume(playing.voice, heard.gain) catch {};
            playing.gain = heard.gain;
        }
        if (@abs(heard.pan - playing.pan) > 1e-4) {
            self.device.setPan(playing.voice, heard.pan) catch {};
            playing.pan = heard.pan;
        }
        const speed = speedOf(player);
        if (speed != playing.speed) {
            self.device.setSpeed(playing.voice, speed) catch {};
            playing.speed = speed;
        }
        if (player.loop != playing.loop) {
            self.device.setLooping(playing.voice, player.loop) catch {};
            playing.loop = player.loop;
        }
        const bus = self.busOf(player);
        if (bus != playing.bus) {
            self.device.setOutput(playing.voice, self.buses.items[bus].submix) catch {};
            playing.bus = bus;
        }
    }

    fn start(self: *Audio, app: *App, e: Entity, player: *AudioPlayer, from: f32, listener: Vec2) !void {
        self.stopOf(e);
        const held_clip = self.get(player.clip) orelse {
            player.playing = false;
            return;
        };
        const heard = heardAs(app, e, player, listener);
        const bus = self.busOf(player);
        const held = player.paused or !app.isProcessing(e);
        const speed = speedOf(player);
        const voice = self.device.play(held_clip.clip, .{
            .volume = heard.gain,
            .pan = heard.pan,
            .speed = speed,
            .loop = player.loop,
            .start = from,
            .paused = held,
            .output = self.buses.items[bus].submix,
        }) catch |err| {
            log.warn("{f} did not play {s}: {t}", .{ e, held_clip.source, err });
            player.playing = false;
            return;
        };
        errdefer self.device.stop(voice);
        try self.voices.put(self.gpa, e, .{
            .voice = voice,
            .clip = player.clip,
            .ends = self.device.status(voice).ends,
            .gain = heard.gain,
            .pan = heard.pan,
            .speed = speed,
            .loop = player.loop,
            .held = held,
            .bus = bus,
        });
        player.playing = true;
        player.position = from;
    }

    fn stopOf(self: *Audio, e: Entity) void {
        const gone = self.voices.fetchSwapRemove(e) orelse return;
        self.device.stop(gone.value.voice);
    }

    /// The voices of the dead, and of entities that lost their player.
    fn forgetTheUnplayed(self: *Audio, app: *App) void {
        var at = self.voices.count();
        while (at > 0) {
            at -= 1;
            const e = self.voices.keys()[at];
            if (app.world.isAlive(e) and app.world.getConst(e, AudioPlayer) != null) continue;
            self.device.stop(self.voices.values()[at].voice);
            self.voices.swapRemoveAt(at);
        }
    }

    fn busOf(self: *const Audio, player: *const AudioPlayer) usize {
        return self.busIndex(player.busName()) orelse 0;
    }

    /// The frame's sound mixed and let go of, as a sound card would have
    /// played it.
    fn mixSilently(self: *Audio, seconds: f32) !void {
        const exact = @as(f64, seconds) * silent_rate + self.owed;
        const frames: usize = @intFromFloat(@max(exact, 0));
        self.owed = exact - @as(f64, @floatFromInt(frames));
        if (frames == 0) return;
        try self.scratch.resize(self.gpa, frames * silent_channels);
        self.device.mix(silent_channels, silent_rate, self.scratch.items);
    }

    /// The loudest sample the last frame mixed, for a silent device: what a
    /// test listens to.
    pub fn loudest(self: *const Audio) f32 {
        var most: f32 = 0;
        for (self.scratch.items) |sample| most = @max(most, @abs(sample));
        return most;
    }
};

fn speedOf(player: *const AudioPlayer) f32 {
    return std.math.clamp(player.pitch, 0.01, 16);
}

const Heard = struct { gain: f32, pan: f32 };

/// How loud and how far to the side a player is heard, its `AudioSpatial2D`
/// counted.
fn heardAs(app: *App, e: Entity, player: *const AudioPlayer, listener: Vec2) Heard {
    var heard: Heard = .{ .gain = dbToLinear(player.volume_db), .pan = 0 };
    const spatial = app.world.getConst(e, AudioSpatial2D) orelse return heard;
    const at = app.globalPosition(e) orelse return heard;
    const reach = @max(spatial.max_distance, 1);
    const dx = at.x - listener.x;
    const dy = at.y - listener.y;
    const near = std.math.clamp(1 - @sqrt(dx * dx + dy * dy) / reach, 0, 1);
    heard.gain *= std.math.pow(f32, near, @max(spatial.attenuation, 0.01));
    heard.pan = std.math.clamp(dx / (reach * 0.5), -1, 1) * std.math.clamp(spatial.panning, 0, 1);
    return heard;
}

/// Where the world is heard from: the current `AudioListener2D`, or the
/// middle of what the camera shows.
fn listenerOf(app: *App) Vec2 {
    var it = ecs.Query(.{AudioListener2D}).over(&app.world) catch return cameraMiddle(app);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(AudioListener2D)) |e, listener| {
            if (!listener.current) continue;
            if (app.globalPosition(e)) |at| return at;
        }
    }
    return cameraMiddle(app);
}

fn cameraMiddle(app: *App) Vec2 {
    const view = app.currentView();
    return .init(view.x, view.y);
}

/// What the bytes are, by what they begin with, or else by the name's
/// ending.
pub fn formatOf(name: []const u8, bytes: []const u8) ?sound.ClipFormat {
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE")) return .wav;
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) return .vorbis;
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) return .mp3;
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] & 0xE0 == 0xE0) return .mp3;
    const ending = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ending, ".wav")) return .wav;
    if (std.ascii.eqlIgnoreCase(ending, ".ogg")) return .vorbis;
    if (std.ascii.eqlIgnoreCase(ending, ".mp3")) return .mp3;
    return null;
}

test "decibels and the factor they are go both ways, and silence is a floor" {
    try testing.expectApproxEqAbs(@as(f32, 1), dbToLinear(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5012), dbToLinear(-6), 1e-3);
    try testing.expectEqual(@as(f32, 0), dbToLinear(silent_db));
    try testing.expectApproxEqAbs(@as(f32, -6.0206), linearToDb(0.5), 1e-3);
    try testing.expectEqual(silent_db, linearToDb(0));
}

test "a clip's format is what its bytes say, or else its name" {
    try testing.expectEqual(sound.ClipFormat.wav, formatOf("x", "RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try testing.expectEqual(sound.ClipFormat.vorbis, formatOf("x.mp3", "OggS....").?);
    try testing.expectEqual(sound.ClipFormat.mp3, formatOf("x", "ID3\x04").?);
    try testing.expectEqual(sound.ClipFormat.mp3, formatOf("song.MP3", "").?);
    try testing.expect(formatOf("notes.txt", "hello") == null);
}
