<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/images/fluxion-logo-white.png">
    <img src=".github/images/fluxion-logo-black.png" width="460" alt="Fluxion">
  </picture>
</p>

<h1 align="center">Fluxion Engine</h1>

<p align="center">
  <strong>A window, a world, and the loop between them.</strong><br>
  A game engine for Zig 0.16: an ECS in the middle, a 2D renderer, an interface layer, physics, and scenes kept as JSON or CBOR.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.16-F7A41D?logo=zig&logoColor=white" alt="Zig 0.16">
  <img src="https://img.shields.io/badge/licence-BSD--3--Clause-blue" alt="Licence: BSD-3-Clause">
  <img src="https://img.shields.io/badge/renderer-OpenGL%20%7C%20Direct3D%2011-5c6bc0" alt="Renderer: OpenGL or Direct3D 11">
  <img src="https://img.shields.io/badge/tests-no%20window%2C%20no%20GPU-2ea44f" alt="Tests run with no window and no GPU">
  <img src="https://img.shields.io/badge/status-early%20development-orange" alt="Status: early development">
</p>

<p align="center">
  <a href="#-the-frame">The frame</a> ·
  <a href="#-the-2d-layer">The 2D layer</a> ·
  <a href="#-physics">Physics</a> ·
  <a href="#-scenes">Scenes</a> ·
  <a href="#-install">Install</a> ·
  <a href="#-examples">Examples</a> ·
  <a href="#-what-comes-next">What comes next</a>
</p>

![The creatures example: fourteen creatures with their names over them, the one the player steers ringed, and a heads-up line in the corner](.github/images/creatures.png)

| Module | What it is |
| --- | --- |
| `App` | The frame: what it owns, and the order it does things in. |
| `schedule` | When a game's systems run. |
| `components` | What the renderer knows how to read. |
| `assets` | What the GPU is holding, and the handles that name it. |
| `Input` | What the keyboard, the mouse and the controllers did, and the game's actions they set off. |
| `Time` | How long the last frame took, and the fixed step. |
| `color` | A colour, and the three ways to write one down. |
| `Window` | The window and the event queue. |
| `render.sprite` | The 2D layer, in one instanced draw per texture. |
| `render.view` | What the camera sees, and where the pointer is in the world. |
| `Interface` | The interface layer: fed from `Input`, laid out by `.ui` systems, drawn on top. |
| `text.Atlas` | Every glyph the game has drawn, in one texture. |
| `hierarchy` | Where a thing really is, once its parent has had its say. |
| `scene` | A world written down and read back, as JSON or as CBOR. |
| `Bodies` | Which body is which entity's: the physics world kept in step with the components. |
| `Clipboard` | Text copied and pasted: the system's, or the program's own with no window. |
| `dialog` | The system's file and folder dialogs: what `app.openFileDialog` asks for, and the answer `app.input` holds for a frame. |
| `Commands` | Spawns, despawns, adds and removes that wait for the system asking for them to return. |
| `States` | A game's own states, each an enum with one value at a time, and the systems that run in them. |
| `Project` | Where a game's files are: `res://` paths from the project's root, the UUIDs in the `.uid` files beside them, the player's own under `user://`, and `project.fluxion`, whose renderer chooses the backend. |
| `ConfigFile` | Settings a game keeps for itself, in sections of keys: the player's volume in `user://settings.cfg`. |
| `DebugViews` | What the engine draws into `app.debug` by itself: colliders, bodies, transforms, sprites, cameras, stats. |
| `attr` | What a component's field means, for an inspector to show it by: a range, an angle, a unit, layers, several lines, a value behind a getter and a setter. |

```zig
const fx = @import("fluxion_engine");

pub fn main(init: std.process.Init) !void {
    const app = try fx.App.create(init.gpa, .{ .title = "game", .io = init.io });
    defer app.destroy();

    try app.addSystem(.startup, "spawn", spawn);
    try app.addSystem(.fixed, "move", move);
    try app.run();
}

fn spawn(app: *fx.App) !void {
    _ = try app.world.spawnWith(.{
        fx.Transform2D.at(320, 180),
        fx.Sprite.solid(.hex(0x3AA0FF), 48, 48),
    });
}

fn move(app: *fx.App) !void {
    var it = try fx.Query(.{fx.Transform2D}).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.slice(fx.Transform2D)) |*place| {
            place.x += app.input.axisOf(.keys(.a, .d)) * 200 * app.time.delta;
        }
    }
}
```

**A scene is a world, and a node is an entity.** A game goes: open a window,
put things in a scene, give them behaviour, draw - and the thing in the
middle is an ECS rather than a tree of objects with virtual methods on
them. Everything of one shape lives in one table, so a system is a loop over
plain slices with no branch in it asking what this one is. That is
[Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs)' doing, not this
package's; what this package adds is the frame around it.

## 🥞 Three layers, one target

3D first with a depth test, then 2D blended with none, then the interface on
top of both, each its own render pass into the same surface. The first pass
clears and the rest load what the one before them left, which is the whole of
what layering costs - no extra textures, no compositing pass. What
`app.debug` draws goes over all three, last.

Today **the 2D layer and the interface are written**. The 3D pass has its
place in `App.drawLayers` and nothing in it.

## 🔁 The frame

Seven stages, and the list is the frame in order:

| Stage | When, and what belongs there |
| --- | --- |
| `startup` | Once, before the first frame. Spawn the world. |
| `input` | After the events are in. Turn keys into intent. |
| `fixed` | Zero or more times, at a constant delta, each followed by the physics step. Forces and steering. |
| `update` | Once, at whatever the frame took. Everything else. |
| `late` | After `update`, before anything is drawn. Cameras follow here. |
| `ui` | Last before drawing, inside the interface's frame: declare it into `app.ui`. |
| `shutdown` | Once, after the last frame. |

A system is `fn (*App) anyerror!void` - a plain function, not a closure and
not a method on a node. The state it works on is in the world it is handed, so
the function needs nothing of its own.

**`late` earns its place**: a camera that follows a player has to run after
the player has moved, and putting both in `update` makes that an accident of
registration order.

**The fixed stage runs as many times as the frame was worth**, and a frame
too long to catch up with is dropped rather than chased - so a stall shows up
as the world running slow for a moment instead of as a loop that never
finishes.

**A key pressed is one jump, whatever the frame rate.** On a 144 Hz screen
most frames run no fixed step at all, and on a slow machine one frame runs
two - so a `.fixed` system asking `justPressed` is answered from edges kept
since the last *step*, not since the top of the frame. Each press reaches
exactly one step, and a press made while the world is paused reaches none.
A controller's buttons work the same way.

**Every system is timed**, under the name it was added with.
`app.schedule.systemsIn(.update)` gives each one's `time_last_frame` - a
`.fixed` system's steps added up - and `{f}` prints them all:

```zig
std.debug.print("{f}", .{app.schedule});
// fixed     move ball                21.4us
```

## 🧾 Commands

```zig
fn hits(app: *fx.App) !void {
    var it = try fx.Query(.{ Bullet, fx.Transform2D }).over(&app.world);
    while (it.next()) |chunk| {
        for (chunk.entities, chunk.slice(fx.Transform2D)) |bullet, place| {
            if (!struck(app, place)) continue;
            try app.commands.despawn(bullet);                    // when this system returns
            const spark = try app.commands.spawn(.{ place, Spark{} });
            _ = try app.commands.spawn(.{ fx.Transform2D.at(0, -8), fx.Parent.of(spark), Glow{} });
        }
    }
}
```

- **A despawn, an `add` or a `remove` moves rows**, and a query is a walk
  over rows: done in the middle of one, it skips entities or visits them
  twice. `app.commands` keeps them instead, and the engine does them all, in
  the order they were asked for, when the system returns - so the next
  system sees them, and a system that failed leaves none of its own behind.
- **`spawn` hands back an entity that is alive at once** with nothing on it,
  and its components arrive with the rest: it can be named, hung from and
  kept in a component straight away.
- **A command for an entity that has died since is passed over**: two
  bullets despawning the enemy they both hit is not a mistake.
- **A parallel `Query.each` can ask too**, from every worker at once -
  `despawn`, `add` and `remove`; `spawn` only from the system's own thread.
- **`app.commands.apply()` does it all now**, for a system that needs what it
  asked for before it returns - a body for what it spawned, to join it to
  another - and is not inside a query when it asks.

## 🚦 States

```zig
const Mode = enum { menu, playing, paused, game_over };

try app.addState(Mode.menu);                                  // its first value otherwise
try app.addSystemIn(.update, Mode.playing, "move", move);     // only while playing
try app.onEnter(Mode.paused, "pause menu", showPauseMenu);
try app.onExit(Mode.paused, "hide pause menu", hidePauseMenu);
try app.addSystemIf(.update, bossAwake, "boss", boss);        // a condition of the game's own

if (app.input.justPressed(.escape)) try app.setState(Mode.paused);
if (app.state(Mode) == .game_over) showScore(app);
```

- **A state is an enum** with one value at a time, and a game has as many as
  it likes, each changed apart: a `Mode` and a `Weather`.
- **A change waits for the top of the next frame.** Every system of this
  frame sees the same value, whichever of them asked; then what leaves the
  old value runs, the value changes, and what enters the new one runs,
  before the frame's first stage. The last asked for in a frame wins, asking
  for the value it has does nothing, and a change asked for while entering
  waits for the frame after. The first value is entered after `.startup`.
- **A system in a state, or under a condition, is skipped rather than
  removed**: it keeps its place in its stage, and its time is its own.
- **Code that does not know it is being gated can be.**
  `app.addSystemsIn(value, register)` puts every system and hook `register`
  adds under that value too, on top of their own conditions. That is how an
  editor runs a game only in Play, with `time.scale` holding the world still
  and `time.stepOnce()` moving it on by one fixed step:

  ```zig
  const Play = enum { editing, playing, paused };
  try app.addSystemsIn(Play.playing, game.addSystems);

  try app.setState(Play.paused);   // editing and paused: the game's systems are out
  app.time.scale = 0;              // and the world holds still

  try app.setState(Play.playing);  // Step: one frame of the game,
  app.time.stepOnce();             // one fixed step of the world,
  // and back to Play.paused from the frame it ran in
  ```

## ⏸️ Pause

```zig
app.setPaused(true);                                           // the game waits
try app.world.add(pause_menu, fx.Processing{ .mode = .when_paused });
try app.addSystemAlways(.input, "pause key", togglePause);     // runs paused or not
try app.addSystemWhenPaused(.ui, "pause screen", drawPauseScreen);

if (app.isPaused()) ...
if (app.isProcessing(door)) ...
```

- **Paused, only what asked to run runs.** Everything else waits where it
  is: its script's `fixed` and `update`, its timers, its `await wait(...)`,
  its animation, its buttons and the pointer over it, and the game's
  systems. The physics stops for everything - there is one physics.
- **What an entity does is a `Processing`**, or the nearest one above it:
  `.pausable` - what a root with none is - `.when_paused`, `.always`, or
  `.disabled`, which never runs. So a pause menu says `.when_paused` once,
  at its top, and every button in it answers while the game waits.
- **A system runs while the game runs**, unless it was added with
  `addSystemAlways` - the key that pauses and unpauses - or
  `addSystemWhenPaused`. `.startup`, `.shutdown` and the systems run on a
  change of state run either way.
- **Time goes on.** A paused game still ticks, so a pause menu can fade in
  and a `.when_paused` timer counts; `time.scale` at nought is the other
  thing, a world held still, which is what an editor does to the scene it
  edits.
- **Worked out once a part of the frame**, as it is asked: see
  `inherited.zig`. A system that changes a `Processing` is heard from the
  next part - the next fixed step, the update, the drawing - on.

## 📨 Events

```zig
const Damage = struct { to: fx.Entity, amount: f32 };

fn hits(app: *fx.App) !void {
    // ... inside a query, as often as it likes:
    try app.send(Damage{ .to = enemy, .amount = 5 });
}

fn hurt(app: *fx.App) !void {
    const Place = struct { var damage: fx.EventReader(Damage) = .{} };
    var it = Place.damage.read(app.events(Damage));
    while (it.next()) |d| {
        if (app.world.get(d.to, Health)) |health| health.hp -= d.amount;
    }
}
```

- **An event is a value of any type**, and whoever reads that type hears it:
  the sender names no receiver and the reader no sender.
- **Sending only appends**, so a system can send from inside its own query's
  loop. Only from its own thread, though: a parallel `Query.each` worker
  cannot send.
- **An event lives two frames**, the one it was sent in and the next. A
  reader that runs before the sender still sees it once, a frame later. A
  reader that does not read for two frames misses what went by.
- **A reader is a place, not a queue.** An `fx.EventReader(T)` is a count of
  what it has read, kept wherever the system keeps its state. Two readers
  each see every event, once each.

## 📡 Signals

```zig
pub const Health = extern struct {
    hp: f32 = 100,
    pub const signals = .{ .died = struct {}, .hit = struct { damage: f32, by: fx.Entity } };
};

try app.addMethod("_on_player_hit", onPlayerHit);
fn onPlayerHit(app: *fx.App, self: fx.Entity, damage: f32, by: fx.Entity) !void { ... }
fn shake(app: *fx.App, args: struct { damage: f32, by: fx.Entity }) !void { ... }

const hit = app.signal(player, Health, .hit);                        // the player's hit
try hit.connect(.method(hud, "_on_player_hit"), .{});                // a method of hud's, by name
try hit.connectFn(shake, .{ .flags = .{ .one_shot = true } });       // a lambda
try app.emit(player, Health, .hit, .{ .damage = 5, .by = sword });   // checked as it is compiled
```

- **A component declares what it can say** as `pub const signals`: each
  signal's name, and the struct of its arguments. An entity has the signals
  of all its components. When two of them declare the same name, the signal
  is written `Health.hit`.
- **The engine declares its own**: an `Area2D` says what came into it and
  what left. See [Areas](#-areas-what-is-in-a-place).
- **A connection is to one component's signal.** If a component that
  declares the same name is added later - a `Shield` that also has `hit` -
  the connection is only written differently, as `Health.hit`, and still
  hears only `Health`.
- **A connection is data, kept beside the world** as names and UUIDs are,
  never in a component. `app.connectionsFrom`, `app.connectionsTo` and
  `signal.connections` list them, and `app.connectionCount` counts them.
- **An emit is heard when the emitting system returns.** The calls run at the
  same sync point as `app.commands`, in the order the connections were
  made, and never under the emitting system's query. **No handler runs at
  the emit itself.**
  - The arguments are copied as the emit happens, text included, so a
    handler reads what was said.
  - What a handler emits is heard in the same round.
  - Ten thousand calls in one round is taken as a loop: it is stopped and
    returns `error.TooManyCalls`.
- **A `.deferred` connection is heard at the end of the frame**, after
  `.late`.
- **The rest of the flags**:
  - `.persist`: saved with the scene;
  - `.one_shot`: gone as it is emitted;
  - `.reference_counted`: a second connect counts up, and each disconnect
    counts down;
  - `.append_source`: the emitting entity is handed after the emitted
    arguments and before the binds.

  `unbinds` is how many of the emitted arguments, from the last, the method
  is not handed, and `binds` are handed to it after the rest. An `fx.Bind`
  is a bool, an integer, a float, text, a `Vec2`, a colour or an entity.
- **A method is found by name when it is called, not when it is connected.**
  The engine looks first among the methods the target's components list in
  `reflect_methods`, then among those the game gave `app.addMethod`. A
  connect checks neither, and that is what lets a tool connect to methods it
  cannot see.
  - A failed call is logged, counted in `app.signals.failures`, and the other
    connections are still heard. A call fails when the method is missing,
    the arguments are wrong, or the method returns an error.
  - Until scripts have methods of their own, those two lists are where
    methods come from. `app.methodsOf(entity, &buffer)` lists both, with what
    each method takes.
- **Death undoes connections.** A call to an entity that has died since the
  emit is not made. The connections from and to the dead go at the end of
  the frame.
- **A Zig function is never saved**: `connectFn` with `.persist` returns
  `error.NotPersistable`.
- **By name, for code that was not compiled against the game** - an editor, a
  console, a scene:
  - `app.signalNamed(entity, "hit")`, `app.emitNamed`, `app.hasSignal`;
  - `app.signalsOf(entity, &buffer)` and `app.signalsOfComponent("Health", &buffer)`,
    each signal with its arguments' names and types;
  - `app.connectNamed` and `app.disconnectNamed`, which keep a connection
    whether or not any component declares its signal;
  - `app.hasMethod` and `app.callMethodOn`.
- **An editor turns them off.** With `app.signals.dispatch = false`, every
  connection is kept, saved and listed, and none is called.
  `app.setBlockSignals(entity, true)` silences one entity.

A scene keeps the connections made with `.persist`, by UUID, in a list of
their own:

```json
"connections": [
  { "from": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c", "signal": "hit",
    "to": "5c2d7e9f-0a1b-4c3d-8e5f-6a7b8c9d0e1f", "method": "_on_player_hit" },
  { "from": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c", "signal": "died",
    "to": "5c2d7e9f-0a1b-4c3d-8e5f-6a7b8c9d0e1f", "method": "_game_over",
    "flags": ["deferred", "one_shot"], "binds": [3, "easy", { "vec2": [1.0, 2.0] }] }
]
```

`signal` is the bare name, or `Component.name` when the bare one is
ambiguous on that entity, and reading takes either.

A connection whose signal or method this build does not know is kept, and
written back as it was read; `loaded.connections_unknown` counts them. An
editor without the game's components must not lose the game's connections.
- **Such a connection is never heard**, even after its component arrives.
  Connecting the same thing again makes it a known one, in the same place.
- **A bare name that two of the entity's components now declare** is kept
  the same way, and heard by neither.
- **One whose `from` or `to` is nowhere** is passed over, and counted in
  `loaded.connections_skipped`.

## 🕹️ Actions

```zig
if (app.input.actionJustPressed("jump")) jump();
const walk = app.input.actionVector("move_left", "move_right", "move_up", "move_down");
var words: [32]u8 = undefined;
const key = app.input.describeAction(&words, "interact");   // "E", or "Pad X" on a controller

try app.input.actions.bind(gpa, "jump", .keyOf(.j));         // the player's own keys
try app.saveInputMap("user://input.json");                   // kept, and read back with loadInputMap
```

```json
"input": { "actions": [
  { "name": "jump", "bindings": [ { "type": "key", "key": "space" }, { "type": "pad_button", "button": "a" } ] },
  { "name": "move_left", "deadzone": 0.2, "bindings": [ { "type": "key", "key": "a" }, { "type": "pad_axis", "axis": "left_x", "direction": "negative" } ] }
] }
```

- **A game asks for what the player means, not for a key.** An action is a
  name and the inputs that set it off - keys, mouse buttons, a controller's
  buttons, a way a stick or a trigger is pushed - in the project file's
  `input` section, which the editor's Input Map tab writes. A key is bound
  where it sits on a US layout, which is what WASD wants, or with
  `"physical": false` by the letter the player's layout puts on it; a
  controller's input on any controller, or with `"pad"` on one.
- **An action is down while any of its inputs is.** Its edges are its own:
  a second key pressed while the first is held is no new press, and letting
  go of one of two is no release. A tap inside one frame is a press and a
  release, and a `.fixed` system hears each exactly once, as it does a key's.
- **How far, as well as whether**: `actionStrength` is one for a key, and
  for a stick or a trigger how far past the action's dead zone it is, from
  nought to one. `actionAxis` makes two actions an axis, and `actionVector`
  four of them a direction no longer than one, up negative.
- **Held from code**: `pressAction("fire", 1)` holds an action down, with its
  edge, until `releaseAction` - what a button on a touch screen does.
- **Six are always there**: `ui_accept`, `ui_cancel`, `ui_left`,
  `ui_right`, `ui_up` and `ui_down`, what the interface moves by. A
  project's action of the same name takes the place of one.
- **The player can change them.** `app.input.actions` is where the game's
  actions stand as it runs - `bind`, `unbind`, `unbindAll`, `setDeadzone`,
  `add`, `rename` - and `saveInputMap` keeps them in a file of the player's
  own. `loadInputMap` takes what it says of the actions the game still has,
  and passes over the rest, so a save from before an update still reads.
- **Named as the player last used them**: `describeAction` says the input on
  the keyboard or the controller, whichever was pressed last, for "Press E to
  open".
- **From a script**: `app.actionDown`, `actionJustPressed`,
  `actionJustReleased`, `actionStrength`, `actionAxis`, `actionVector`,
  `pressAction`, `releaseAction`, `describeAction`, `saveInputMap` and
  `loadInputMap`. Inside the quotes of any of them, the language service
  `app.scriptSetup()` sets up offers the project's actions by name, each
  with its inputs - so an editor completes `app.actionDown("ju` to `jump`.
- **A program whose keys are its own** - an editor - leaves
  `Options.project_input` off, and moves round its interface with the six
  alone.

## 🎮 Controllers and the pointer

```zig
const pad = app.input.anyPad();            // or app.input.pad(1) for player two
const walk = pad.stick(.left);             // a Vec2, dead zone already out
if (pad.justPressed(.a)) jump();

try app.setCursor(.locked);                // a first-person camera, or a drag
const turn = app.input.pointer.dx;
```

- **Controllers are read, not heard.** A stick is a position rather than a
  thing that happened, so the platform polls every controller once a frame
  and "pressed this frame" is this frame's buttons against the last. XInput
  on Windows, evdev on Linux, Android's own, and SDL's mapping format for the
  pad nobody recognises - `app.addGamepadMappings(text)`.
- **`anyPad()` is every controller as one**, for a game with one player who
  should be able to pick up whichever is nearest; `pad(slot)` is one of them,
  and a slot is the controller's for as long as it stays plugged in, which
  makes slots player numbers.
- **The dead zone is round.** On the stick's distance from the middle rather
  than on each axis, so a nearly diagonal push does not snap to a straight
  line, and rescaled so the first movement past it is small rather than a
  jump. `Input.stick_deadzone` is a fifth by default.
- **`setCursor` takes five modes**: `.normal`, `.hidden` for a game that
  draws its own pointer, `.confined` to hold it inside the window,
  `.confined_hidden` for both at once, and `.locked` to take it away and
  report movement with no edge to stop at, unaccelerated where the system
  allows. While locked, `input.pointer` holds still where it was and only
  `dx` and `dy` move; `.confined_hidden` keeps saying where it is.
- **The pointer's shape is the system's**, `app.setCursorShape(.pointing_hand)`
  or any other of the seventeen, or a picture of the game's own with
  `app.setCursorImage(.{ .pixels = rgba, .width = 32, .height = 32, .hot_x = 4, .hot_y = 2 })`.
  A browser quietly keeps its arrow past 128 by 128, so a cursor a page
  will see should be small.
- **Where the pointer is, and how fast**: `input.pointer.x/y` in the
  framebuffer's pixels, `app.pointerInWorld()` through the camera,
  `app.pointerIn(entity)` in one entity's own space, and
  `input.pointer.velocity` in pixels a second, worked out over at least a
  tenth of a second and nought once it has been still for three. A game
  puts it somewhere itself with `app.warpPointer(x, y)`.
- **A double click is the system's own**: `input.doubleClicked(.left)` for
  the press that made one, by Windows' setting or four hundred
  milliseconds within a few pixels elsewhere.
- **A held pointer is let go when the window loses the keyboard**, and taken
  back when it returns - so a player who alt-tabs away from a locked game gets
  their mouse back, and the lock is still a lock when they come back to it. A
  lock asked for while the window is in the background waits for it.

## 🪟 The window

```zig
try app.setWindowTitle("Level 3");
try app.setWindowSize(1280, 720);
try app.setWindowSizeLimits(.{ .min_width = 640, .min_height = 360 });
try app.setWindowState(.maximized);         // .normal, .maximized, .minimized
if (app.resized) layOutAgain(app.width, app.height);
```

- **`app.resized` is true for the one frame the size changed in** - an edge
  dragged, a maximise, fullscreen - and false again the frame after. The
  engine always had to notice, because the swapchain had to be resized; now
  the systems hear about it too, instead of keeping last frame's size to
  compare with.
- **Sizes are the content area, in the units of `Options.width` and
  `height`**: pixels, on every backend there is today.
- **A fullscreen, maximised or minimised window is made an ordinary one
  before it is sized or moved**, because none of them has a size of its own.
  `.normal` means the window's own size even for one that was maximised
  before it was minimised, which Windows would otherwise bring back
  maximised.
- **Limits apply at once.** A window already outside new limits is brought
  inside them when they are set, and one that is maximised, minimised or
  fullscreen when it is a window again.
- **The window's own picture** is `app.setWindowIcon(&.{ big, small })`,
  straight RGBA rows in as many sizes as a game has, and the system takes
  the one it wants. An empty list puts the system's own back. Wayland has
  none - a window's picture comes from its desktop file there.
- **The close button can ask rather than close.** With
  `Options.ask_before_closing`, pressing it - or Alt+F4 - only sets
  `app.close_pressed`, and the run goes on until the program calls `quit`:
  an editor asks about work not saved first. A game leaves it off and closes
  at once.
- **`Options.resizable` and `Options.maximized`** say what can only be said
  when the window is made. Without a window - headless - all of this is
  nothing, and says so without failing.

## 📋 The clipboard

```zig
try app.setClipboardText(seed);                     // for the player to paste anywhere
const pasted = try app.clipboardText();             // what they copied, anywhere
const can_paste = app.hasClipboardText();           // a Paste entry that greys out
```

- **It is the system's**, through
  [Fluxion Platform](https://github.com/kisstp2006/fluxion-platform): what a
  game copies reaches every other program and what they copied reaches the
  game, as UTF-8 with `\n` between lines whatever put it there. The
  interface's Ctrl+C, Ctrl+X and Ctrl+V go through the same one.
- **What `clipboardText` gives is lent** until the next read - the
  interface's paste is one - so a game that keeps it keeps a copy. Read it
  when it is wanted rather than every frame: on X11 and Wayland a read waits
  on the program that owns the clipboard.
- **`hasClipboardText` asks without reading**, which is also the quiet way on
  Android, where every read shows the player a notice.
- **A system may refuse** with `error.Unavailable`: text that is not UTF-8,
  Wayland asked by a window without the keyboard, a page with no clipboard.
  The interface warns and carries on; a copy that failed is lost, not the
  frame.
- **Without a window - headless, in a test - the clipboard is the program's
  own**, so copying and pasting still work inside it, and a test never
  overwrites what the person running it had copied.

## 📂 File and folder dialogs

```zig
browsing = try app.openFolderDialog(.{ .title = "Where the project goes" });
picking = try app.openFileDialog(.{
    .multiple = true,
    .filters = &.{.{ .name = "Images", .extensions = &.{ "png", "jpg" } }},
});

// In any system, a frame or more later:
if (app.input.dialogAnswer(browsing)) |paths| {
    if (paths.len > 0) try useFolder(paths[0]); // none: it was cancelled
}
```

- **They are the system's own**, through
  [Fluxion Platform](https://github.com/kisstp2006/fluxion-platform): over
  the window and modal to it, with the places and the recent files the player
  already knows.
- **Asking returns at once**, with an id, and the game goes on running and
  drawing while the dialog is open. The answer is in `app.input` for every
  system of the frame it arrives in, and gone in the next;
  `app.input.dialogAnswers()` is all of that frame's.
- **A cancel is an answer too**, with no paths, so every dialog is answered
  exactly once.
- **The paths are lent** until the frame ends - they are the platform's, and
  its next pump frees them - so a game that keeps one keeps a copy. A frame
  whose system failed lets them go all the same, so a loop that carries on
  after an error never reads one that is gone.
- **One dialog at a time.** Asking while one is open is `error.Unavailable`,
  and so is a filter two systems would read differently - `"*.png"`,
  `"png;jpg"` - and a platform with no dialogs yet: X11, Wayland, Android.
  `fx.dialog.available` says whether the fluxion-platform this was built with
  has them at all.
- **Without a window, a dialog is never answered by itself.** The app still
  hands out ids, and a test answers for the person who is not there, the way
  it presses keys for them:

```zig
const id = try app.openFolderDialog(.{});
app.input.answerDialog(.{ .id = id, .paths = &.{"C:/games/meadow"} });
_ = try app.step(); // this frame's systems see it, the next frame's do not
```

## 📥 Files dropped on the window

```zig
for (app.input.dropped()) |drop| {
    for (drop.paths) |path| try bringIn(path, drop.x, drop.y); // where they were let go
}
```

- **A drop is input**, as a dialog's answer is: everything let go in one
  armful is one `Dropped`, there for every system of the frame it arrives in
  and gone in the next, its paths lent until the frame ends.
- **`x` and `y` are where it was let go**, in the pixels `input.pointer` is
  in - into the folder under it, onto the thing under it. A fluxion-platform
  from before drops said where gives the pointer's last place instead.
- **Windows and the web drop files**; X11 and Wayland do not yet.
- **A test drops them itself**: `app.input.dropFiles(.{ .paths = &.{"C:/Art/hero.png"}, .x = 40, .y = 60 })`.

## ⌛ Frame pacing

```zig
try app.setVsync(false);
app.time.max_fps = 144;                     // null is no cap
if (!app.input.focused) app.setPaused(true);
```

- **A project caps its frames with `application.max_fps`** - nought for no
  cap - and a game's `Options.max_fps` overrules it.

- **The cap keeps a schedule**, so a late frame is caught up with and the
  average holds; after a stall longer than `time.max_delta` it starts again.
  On Windows a sleep is only as precise as the system timer - 15.6 ms unless
  something asks for better - so a cap above about 60 is right on average and
  uneven frame to frame.
- **A minimised window is not drawn**, and the loop wakes ten times a second
  instead of spinning. The fixed steps keep the simulation in real time.
- **On `d3d11`, vsync off does not yet go past the refresh rate**: the
  flip-model swapchain in fluxion-rhi has two buffers and no tearing support.
  It is the backend Windows opens by default now.

## ⏲️ Timers

```zig
const door = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Timer{ .wait_time = 2, .one_shot = true, .autostart = true } });
try app.signal(door, fx.Timer, .timeout).connect(.method(door, "_on_timer_timeout"), .{});

app.world.get(door, fx.Timer).?.start(5);      // five seconds from now; start(-1) is wait_time
const fuse = try app.createTimer(1.5);         // one to connect to and forget
try app.signal(fuse, fx.Timer, .timeout).connectFn(explode, .{});
```

- **A timer is a component.**
  - `wait_time`, `one_shot`, `autostart`, `paused` and `time_left`.
  - `start`, `stop` and `isStopped`.
  - The `timeout` signal, and it is saved with a scene.
- **Counted by the engine**: once a frame before the `.update` systems, or
  with `clock = .fixed` once a fixed step before `.fixed`, so a wait the
  game's simulation depends on is the same length on every machine.
  - What it says is heard before that stage's systems run.
  - A repeating timer keeps what a frame ran past, so it keeps its rhythm.
- **Counted while its entity runs.** A paused game's timers wait - but for
  those whose `Processing` runs while it is paused - and a frame with no
  time counts nothing: an editor, which gives its world no time, starts none
  in the scene it edits. A timer read back from a scene saved while it ran
  goes on from where it was.
- **`app.createTimer(seconds)`** makes a one-shot timer on an entity of its
  own, which goes once it has said `timeout`.

## 📱 In the background

```zig
fn keep(app: *fx.App) !void {
    if (app.input.justSuspended()) try app.saveScene("res://save.json", .{}); // the last word
    if (app.input.lowMemory()) forgetWhatCanBeLoadedAgain(app);
}
```

- **Only a phone and a page go into the background.** A desktop program
  never does, and none of this happens to it.
- **The frame the news comes in runs as usual**, and `justSuspended()` is a
  system's last chance to save: Android may end a program in the background
  without another word. The frames after it run no systems and draw
  nothing until `justResumed()`, and the clock starts again then, so the
  time away is not one long frame throwing everything forward.
- **Nothing is drawn while Android has taken the surface away**, and the
  swapchain is made again at the size the new one comes back at.
- **`lowMemory()` is the system asking for memory back**, for the one frame
  it asked in: a game lets go of what it can load again.
- **The notch and the gesture bar are kept out of.** `app.safeArea()` is
  how far in from each edge of the framebuffer the part nothing covers
  starts, and the interface keeps its root inside it, which is all a game
  with an `.ui` system has to do. `app.interface.follow_safe_area = false`
  for a game that would rather draw into the notch itself. Nought on every
  desktop; a page gets it only with `viewport-fit=cover` in its viewport
  meta tag, and what it answers there is the page's own edges in the
  canvas's pixels - exact for a canvas that fills the page, which is what a
  game is, and an over-estimate for one with a page above it.

## 🌳 One tree

```zig
const tank = try app.world.spawnWith(.{ fx.Transform2D.at(100, 100), fx.Sprite.of(hull) });
const turret = try app.world.spawnWith(.{ fx.Transform2D.at(0, -6), fx.Parent.of(tank), fx.Sprite.of(gun) });
try app.setName(turret, "turret");
const reload = try app.world.spawnWith(.{ fx.Timer{ .wait_time = 2 }, fx.Parent.of(turret) });  // no transform: a clock
try app.addToGroup(tank, "enemies");

const barrel = app.findPath(tank, "turret/barrel");   // null until there is one
try app.callGroup("enemies", "alert");
```

- **`Parent` is the one link between entities.** Whatever an entity is - a
  sprite, a control, a timer, something with only a script - it hangs from
  its `Parent`, or it is a root. A transform's numbers are in the space of the
  transform above it, a control is laid out in the control above it, and a
  timer or a sound belongs to what it hangs from. **What hangs from something
  goes with it**: despawn the tank and the turret goes at the end of the
  frame, and the clock on the turret with it - or all of it at once, with
  `app.despawnTree`.
- **`app.setParent(entity, parent, keep_global)` moves an entity in the
  tree**, `.none` for the roots, last among its new siblings. With
  `keep_global` it stays where it is in the world, its own transform written
  to land there; without, its numbers stay and it moves with the new parent.
  A loop - the entity itself, or something under it - is `error.Loop`.
  `app.parentOf` and `app.hangsFrom` read it. A `Parent` written straight
  into the component is seen after the next spawn, despawn or change of
  components, and renames nothing, so an inspector shows it read-only and
  leaves the move to `setParent`.
- **A parent's children keep an order**: `app.childrenOf(parent, &buf)` in
  it - `.none` for the roots - `app.childCount` and `app.childAt` one at a
  time, `app.siblingIndex(entity)` for one's place, and
  `app.setSiblingIndex(entity, i)` to move one, the ones from there on moving
  along. A child never placed comes after the ones that were, in the order it
  was made. A scene writes its list in this order and a read keeps it, so the
  tree comes back as it was, after whatever was in the world already.
  `app.siblingBefore` sorts siblings a caller has grouped itself. The
  families are an index kept beside the world and built again when the world
  changes shape, so asking every frame is a lookup, not a walk over the world.
- **A name is its siblings' own.** Two children of one parent - or two roots
  - cannot share one: `app.setName` says `error.NameTaken`, and
  `app.setFreeName` takes the first free one after it, "Rock 2", which is
  what a scene read into a family and `setParent` do. Two copies of a scene
  keep the names inside them. `app.find(name)` answers with the first living
  entity given it; `app.findPath(from, "Arm/Hand")` follows names down, `..`
  up and a leading `/` from the roots; `app.findIn(root, name)` looks
  anywhere under a root.
- **A group is a name many entities are put under**, wherever they are in the
  tree: `addToGroup`, `removeFromGroup`, `isInGroup`, `groupMembers`,
  `groupSize` and `groupMember`, `groupsOf`, and `callGroup(group, method)`,
  which calls a method - a component's, the script's, or one `addMethod` gave
  - on every member that has it. Groups are kept beside the world, as names
  are, because one entity is in any number of them; a scene writes them with
  each entity, and the dead leave at the end of the frame.
- **All of it is a script's too**: `app.setParent(self.entity,
  app.find("ship"), true)`, `app.findPath(self.entity, "../Door")`,
  `app.callGroup("lights", "flicker")`.

## 🎨 The 2D layer

One quad in a vertex buffer and a second buffer stepping once per instance
with where each sprite goes, how big, which way round, what colour and which
part of which texture. A thousand sprites sharing a texture is one draw call.

```zig
_ = try world.spawnWith(.{
    fx.Transform2D{ .x = 100, .y = 80, .rotation = 0.4 },
    fx.Sprite{ .texture = hero, .region = .cell(2, 4, 1), .layer = 5 },
});
```

- **An `Appearance` shows what hangs from it.** `visible` false hides the
  entity and everything under it; `modulate` is multiplied into its own
  colour - a sprite's `tint`, a label's `color`, a tile map's `tint` - and
  into everything under it; `z` raises the layer it and everything under it
  is drawn on, added to the one it inherits unless `z_relative` is off. It is
  optional, as `Processing` is: an entity without one is shown as its parent
  is. A control takes the alpha and the visibility: see
  [Controls and themes](#-controls-and-themes).
- **Sorted back to front, blended, with no depth test.** A depth buffer and
  half-transparent pixels disagree about what is behind what. The sort is by
  `layer`, then `order`, then blend mode, then texture, then the order the
  sprites were found in - so sprites of one layer sharing a texture come out
  as one run and therefore one call, and two overlapping sprites that tie on
  everything are drawn the same way round every frame.
- **`Sprite.blend = .additive` adds light** instead of covering what is
  behind: sparks, glows, lasers. It is a second pipeline, and additive sprites
  of one layer and order are grouped so they stay one draw call.
- **A texture loaded with `.wrap = .repeat` tiles** across a region that goes
  past its edge: `.region = .repeated(8, 4)` draws it eight times across and
  four down.
- **`Sprite.order` is the sort inside a layer.** Zero by default, which keeps
  the texture grouping. A top-down game writes `transform.y` into it from a
  `.late` system and gets things sorted by their feet.
- **Set `interpolate` on anything moved in `.fixed`** and it is drawn between
  its last two steps, at `Time.alpha`. The engine remembers where it was; the
  game's own systems never touch that. Without it, a sixty-hertz step on a
  hundred-and-forty-four-hertz screen shows every step twice and some three
  times.
- **The whole instance buffer goes up in one call.** Not one per sprite: on
  Direct3D 11 a dynamic buffer is re-sent whole on every map, so a call per
  sprite is quadratic in the number of sprites.
- **A sprite with no texture is a rectangle of solid colour**, because the
  renderer falls back to a one-texel white texture and the tint does the rest.
  One pipeline, no branch in the shader, no artwork for a health bar.
- **A sprite with no size is the size of its own artwork**, so most sprites
  need no size at all.
- **A transform's numbers are *local*** - in the space of the transform it
  hangs from through its `Parent`, so a turret rides on a tank and a health
  bar rides over an enemy, and in the world's only when there is none above.
  `app.worldTransform(entity)` is the other one, and it costs a walk up the
  chain rather than a field read. `inherit_rotation = false` is the shadow
  that does not tip over. See [One tree](#-one-tree).
- **Calls on the app work through the chain**:
  - `globalPosition`, `globalRotation`, `globalScale` and `worldTransform` read where an entity is in the world, and their `set` twins put it there under the parents it keeps.
  - `globalTranslate` moves it by an amount in the world, and `toLocal`/`toGlobal` take a point in and out of its space.
  - `lookAt` turns its `+x` to a point, and `getAngleTo` says how far that is.
  - `moveLocalX`/`moveLocalY`, `rotate` and `applyScale` change its own numbers along its own axes.
  - `getRelativeTransformToParent` says where it is in an ancestor's space.
  - These are where the entity is. What an entity that `interpolate`s is drawn at between two steps is `drawnTransform`.
- **An `Animation` is a sheet and a rate**, and the engine writes the cell it
  lands on into `Sprite.region` once a frame. One sheet holds a walk, an idle
  and an attack; swapping between them is writing two numbers.
- **A `Text2D` is words at a transform**, drawn through the same pass as
  everything else: each glyph is a quad out of a glyph atlas, so a label sorts
  against sprites by the same `layer` and `order` and all the text in one font
  is one draw call. The text lives *in* the component, in a fixed buffer, and
  `label.print("{d} points", .{score})` is what a game actually does with it.
- **A font is a file, or one font of a collection.** `app.assets.loadFont`
  opens a `.ttf` or an `.otf`, and `.member = n` the nth font of a `.ttc`,
  which is what Windows ships its Chinese, Japanese and Korean fonts in.
  `app.assets.loadSystemFont(.{})` asks the system which font its own
  dialogs use - Segoe UI, Yu Gothic UI on Japanese Windows, what fontconfig
  makes of sans-serif, Roboto - and opens that, at whatever place in its file
  the system names: for a tool's interface, or a game's debug text.
  `.mono = true` opens its monospaced font instead - Cascadia Mono or
  Consolas, fontconfig's monospace, Menlo, Droid Sans Mono - for a code
  editor or a console. A game's own words are set in a font it ships.
- **What the camera cannot see is dropped before it costs anything**, one
  comparison per sprite, which is the difference between a renderer that costs
  what is drawn and one that costs what exists.
- **The camera is an entity** with a `Transform2D` and a `Camera2D`, and its
  position is the *centre* of the view. With no camera in the world at all,
  the origin is the top left corner and one unit is one pixel - the same
  coordinate system the interface layer uses, so a game that has not thought
  about cameras yet can lay things out in screen coordinates. A game designed
  at one size says so - `Camera2D.fitting(640, 360)` - and the whole of that
  area is on screen in any window, with `zoom` multiplying it.
- **The pointer is found in the world through the same camera.**
  `app.pointerInWorld()`, `app.screenToWorld(x, y)` and
  `app.worldToScreen(x, y)` run the view the renderer draws with, forwards
  and backwards, and a test holds the arithmetic against the matrix the
  shader is given - so what is under the mouse is what is drawn under the
  mouse, zoomed and turned. `app.spriteCorners(entity)` is where a sprite's
  four corners land in the world, by the vertex shader's own arithmetic,
  for asking whether a click hit it; `app.textCorners(entity)` is the same
  for a label, the box its lines are laid out in, and
  `app.drawnCorners(entity)` is whichever of the two an entity is drawn as.
- **The world can be drawn through another camera, somewhere else.**
  `app.drawWorld(texture, view)` draws the sprites, the text and `debug` into
  a texture through any `fx.View` - a minimap, a picture-in-picture, an
  editor's scene panel. With `app.world_on_screen = false` the window shows
  only the background and the interface, and a texture is the one place the
  world appears. Drawn into on OpenGL, a texture comes out with its bottom row
  first, and `app.drawnUpsideDown()` says when a picture of it wants turning.
- **The shader is written once**, in
  [Fluxion Shader](https://github.com/kisstp2006/fluxion-shader)'s language,
  and comes out as GLSL and as HLSL. Two hand-written copies would drift, and
  the drift shows up as one backend drawing correctly and the other not.

## 🧱 Tile maps

```zig
const set = try app.loadTileSet("res://tiles/terrain.tileset");
const map = try app.world.spawnWith(.{ fx.Transform2D{}, fx.TileMap{ .tile_set = set } });
_ = try app.setTile(map, 3, 2, .at(0, 1, 0));                          // source 0, column 1, row 0
_ = try app.setTile(map, 4, 2, fx.Cell.at(0, 1, 0).with(fx.Cell.flip_h, true));
const hurts = app.tileDataAt(map, app.pointerInWorld(), "damage");     // what the tile set says of it
```

- **A `TileMap` is a grid of cells over a tile set**, drawn with the sprites
  of its `layer` and sorted by its `order`, tinted, and stopping what its
  `collision_layer` and `collision_mask` say.
- **A cell is four bytes**: which source of the set, the column and row of
  the tile in it, and whether it is flipped across, flipped over or turned -
  `Cell.flip_h`, `flip_v` and `transpose`, three of which make every quarter
  turn. A tile added to the sheet later leaves every painted cell where it
  was, since a cell names its tile by place and not by number.
- **Cells live in chunks of sixteen by sixteen**, entities of their own that
  a map owns: a level larger than the screen is a handful of instanced draws,
  and the camera drops the chunks it cannot see. `app.setTile` and
  `app.tileAt` go through an index, not a walk of the world. The chunks are
  the engine's - a scene writes the map's cells under the map itself,
  `"cells": { "0,0": "<base64>" }`, and builds the chunks again when it reads
  them.
- **What stops at a tile is the tile set's word**: the whole tile - whole
  tiles side by side are merged into as few boxes as cover them - or a shape
  of up to eight corners, turned and flipped the way its cell is. A map's
  solid tiles are one static body per chunk.
- **A tile set is a file**, `.tileset`, read once however many maps name
  it, and kept by a handle as a texture is. A source is a sheet cut into a
  grid past its margin and between its gaps; a source with no texture is one
  tile of the white texel, which a map's tint colours - a level blocked out
  before its art exists.

  ```json
  {
    "fluxion_tileset": 1,
    "tile_size": [16, 16],
    "data_layers": [{ "name": "damage", "type": "int" }, { "name": "water", "type": "bool" }],
    "sources": [{
      "id": 0, "texture": "res://art/terrain.png", "margin": [0, 0], "separation": [0, 0],
      "tiles": [
        { "at": [0, 0], "collision": "full" },
        { "at": [2, 0], "collision": "polygon", "polygon": [[0, 16], [16, 0], [16, 16]] },
        { "at": [1, 0], "probability": 0.5, "data": { "damage": 2 } }
      ]
    }]
  }
  ```

  `tiles` lists only the tiles with something to say. What a tile does not
  say is its default, and is not written back.
- **Data layers are values a tile carries under a name** - how much it
  hurts, whether it is water - whole numbers, numbers or truths, eight at
  most. `app.tileData(map, x, y, "damage")` asks a cell,
  `app.tileDataAt(map, point, "damage")` the cell under a point of the world,
  and a Flux script gets the number or the truth itself:
  `app.tileDataAt(ground, vec2(x, y + 20.0), "water") == true`.
- **`probability`** is how often a random brush picks the tile against the
  others it picks among: an editor's, since a game places its own tiles.
- **Where a map is**: `app.cellAt(map, point)` is the cell a point of the
  world is in, and `app.usedCells(map)` the smallest rectangle holding every
  painted cell.
- **A tile set's file can be written back**: `app.tile_sets.textOf` and
  `save` are what an editor keeps undo steps with and saves, and
  `reloadTileSet` reads one again - everything built from it, a map's body
  included, is built again.

## 🔘 The interface

```zig
fn pauseMenu(app: *fx.App) !void {
    app.ui.open(.{ .id = "resume", .padding = .all(12), .background_color = .hex(0x2E343D), .focus = .{} });
    defer app.ui.close();
    app.ui.text("Resume", .{ .font_size = 24 });
    if (app.ui.justReleased()) app.time.scale = 1;
}

fn shoot(app: *fx.App) !void {
    if (app.ui.wantsPointer()) return;   // that click was the interface's
    // ...
}

try app.addSystem(.ui, "pause menu", pauseMenu);
```

- **`app.ui` is a [Fluxion UI](https://github.com/kisstp2006/fluxion-ui)
  layout.** Every `.ui` system declares into one root the size of the window,
  after `.late`, every frame. It is drawn in the default font -
  `app.interface.font` names another - over the 2D layer, in a pass that loads
  what that one left. With no font loaded it is laid out and not drawn, as a
  `Text2D` is.
- **More than one font.** `app.interface.addFont(handle)` gives back the
  index a style names the font by: `.font = code` measures and draws that
  run in it, and every other run stays in `app.interface.font`, index 0. The
  layout measures and the renderer draws from one table, so a code editor's
  carets land where its monospaced letters are. An index that names no font,
  or a font since let go of, is measured and drawn in the first. The glyphs
  of every face share one atlas, so text in two fonts is still one draw.

  ```zig
  const mono = try app.assets.loadSystemFont(.{ .mono = true });
  const code = try app.interface.addFont(mono);
  app.ui.text("const x = 1;", .{ .font = code, .font_size = 14 });
  ```
- **It hears the input before the game does**, so an `.input` or `.update`
  system can ask `app.ui.wantsPointer()` and `wantsKeyboard()` about this
  frame. The wheel goes to the list under the pointer first, and only what the
  interface did not use reaches `input.wheel`.
- **The keys it takes.** Tab always moves the focus. The `ui_left`,
  `ui_right`, `ui_up` and `ui_down` actions - the arrows, a d-pad and the
  left stick, unless the project says otherwise - move it, held to repeat,
  only once something that takes the focus has it, so a game keeps them
  until a menu takes the focus with `app.ui.setFocus`. While a text input
  has it, only a controller moves it on. `ui_accept` - Enter, Space and a
  pad's A - presses what has it, and typing and the editing keys reach a
  text input that has it. Ctrl+C, Ctrl+X and Ctrl+V go through the system
  clipboard - see [the clipboard](#-the-clipboard) - so text moves between a
  text input and every other program. AltGr is never Ctrl: AltGr and V types
  `@` on a Hungarian keyboard, and Ctrl+Alt+V still pastes.
- **The pointer's shape is the interface's** once there is a `.ui` system: an
  I-beam over a text input, the arrows over a resize handle, and
  `app.ui.setCursor` for a game that wants its own. A locked pointer points at
  nothing in it.
- **It is the size the display asks for.** `app.interface.scale`, what it is
  laid out at, is the game's own `app.interface.zoom` - an interface-size
  setting - times the scale of the display the window is on: 1.25 or 2 on a
  HiDPI screen, followed as the window is dragged to another monitor.
  `follow_display = false` sizes it by the window alone. `safe_area` keeps it
  clear of a television's edges, and a picture on an element names one of
  `app.interface.textures` by its index.
- **Typing brings up the right keyboard.** While a text input has the
  keyboard, the platform's text input is on: a phone's soft keyboard comes
  up, a page's hidden field takes the typing, and an input method -
  Japanese, Chinese, Korean - composes at the caret with its candidates
  beside it. It is off again the moment none has, so an input method never
  sits between a game and its keys. `owns_text_input = false` leaves it to a
  game with a text box of its own.
- **The wheel scrolls as the system says**: the lines a notch is set to in
  Windows' mouse settings or KDE's, a page at a time where that was chosen,
  and three lines elsewhere. `input.wheel` stays in notches, which is what a
  zoom wants.
- **Without a `.ui` system none of this happens.** Nothing is fed, laid out or
  drawn, and a game that never asks for an interface runs as it did.

## 🔲 Controls and themes

```zig
try app.useControlNodes();
const ui_theme = try app.loadTheme("res://ui/game.theme");
const root = try app.world.spawnWith(.{ fx.Control{ .theme = ui_theme, .width = .{ .mode = .grow }, .height = .{ .mode = .grow } }, fx.CanvasLayer{} });
const play = try app.world.spawnWith(.{ fx.Control{}, fx.Parent.of(root), fx.Button.of("Play") });
try app.signal(play, fx.Button, .pressed).connect(.method(menu, "start"), .{});   // menu: an entity whose script has start()
```

- **Controls are components.** A `Control` is the box - its size as fit,
  fixed, grow, a share or a ratio, and in the flow of the control it hangs
  from or anchored to one of nine places in it. What it is comes
  beside it: `Label`, `Button`, `CheckBox`, `LineEdit`, `Slider`,
  `ProgressBar`, `TabContainer`, `TextureRect`, `NinePatchRect`, and the
  containers `PanelContainer`, `BoxContainer`, `MarginContainer`,
  `CenterContainer` and `ScrollContainer`. A root is a `Control` with a
  `CanvasLayer` over the screen, or a `Viewport` placed in the world.
  `app.useControlNodes()` lays them out into the interface every frame.
- **They fade and pop.** A control's `Appearance` - and whatever is above
  its tree, controls or not - fades it and everything in it by its
  `modulate`'s alpha and hides it with `visible`; its `scale` draws it and
  everything in it bigger or smaller about its middle, and the layout does
  not move. A paused game's controls do not answer the pointer, unless their
  `Processing` says so. See [Pause](#️-pause).
- **They say what happened as signals**: `pressed` and
  `toggled` on a button, `toggled` on a check box, `changed` and `submitted`
  on a line edit, `changed` on a slider, `tab_changed` on tabs - connected in
  code or kept in a scene.
- **A button is one thing**: its words, its icon, whether it stays down,
  and whether it is down - not a button with a label inside it.
- **How they look is a file**, `.theme`:

  ```json
  {
    "fluxion_theme": 1,
    "base": "res://ui/base.theme",
    "font": "res://fonts/ui.ttf",
    "font_size": 16,
    "types": {
      "Button": {
        "font_color": "#F2EEF8",
        "styles": {
          "normal":  { "background": "#6B4FC8", "corners": 6, "padding": [10, 5] },
          "hover":   { "background": "#8F72E8" },
          "pressed": { "background": "#4E3899" },
          "focus":   { "border": 2, "border_color": "#F5B942" }
        }
      },
      "Danger": { "base_type": "Button", "styles": { "normal": { "background": "#C8434F" } } },
      "Header": { "base_type": "Label", "font_size": 20, "font_color": "#F5B942" }
    }
  }
  ```

  A type is a kind of control - `Panel`, `Button`, `CheckBox`, `LineEdit`,
  `Slider` and `SliderFill`, `ProgressBar` and `ProgressBarFill`, `Tab` and
  `TabActive`, `Focus`, `Label` - or a name of the game's own built on one,
  which a control asks for with `type_variation`: one `Danger` button among
  many. A style says a background, a border, corners, padding, a texture cut
  in nine with its tint, and the text's colour, font and size; the states
  are `normal`, `hover`, `pressed`, `disabled` and `focus`.
- **A theme says only what it changes.** What a control is drawn with is
  looked up in layers: the engine's own look; every theme's word on the
  normal look - the project's, its base themes, the control's own theme and
  its base themes, the nearer over the further, a variation over the type it
  is built on; then what the control says of itself; then every theme's word
  on the state it is in. So a state a theme does not mention looks as
  `normal` does, and a `Danger` button's hover is its `Button`'s until it
  says one of its own: a style is found by its state's name.
- **A control's theme is the nearest one named up its tree**, and under
  all of them is the project's: `"gui": { "theme": "res://ui/game.theme" }`
  in `project.fluxion`, which `app.projectTheme()` reads the first time it is
  asked and again when the file names another.
- **One control's own look is a `ThemeOverride`**: its text's colour and
  size, its background, border, corners and padding, each with a switch
  beside it - what is switched off stays the theme's. It lies over every
  theme's normal look and under what they say of hovering and pressing, so a
  button of its own colour still answers the pointer. It changes the part
  the control is - a slider's track, not its fill - and none of its children.
- **A theme's file can be written back** - `app.themes.textOf` and `save`,
  as a tile set's - and `app.themes.styleOf` is the lookup the game draws
  with, for an editor's preview to draw with too.

## 🐞 Debug drawing

```zig
fn watchBall(app: *fx.App) !void {
    const ball = app.find("ball") orelse return;
    const place = app.worldTransform(ball) orelse return;
    const at: fx.Vec2 = .init(place.x, place.y);

    app.debug.circle2d(at, 12, .green);
    app.debug.with(.{ .seconds = 2 }).cross2d(at, 6, .red);   // stays for two seconds
    app.debug.screen().print2d(.init(8, 8), "{d:.0} fps", .{app.time.fps()}, .white);
}
```

- **`app.debug` is a [Fluxion Debug Draw](https://github.com/kisstp2006/fluxion-debugdraw)
  pen**: lines, shapes and text, seen through the same camera as the 2D
  layer. The functions ending in `2d` take a `Vec2`, and the filled ones start
  with `solid`.
- **A shape lasts one frame**, or as many seconds as its style says. Drawn
  inside `.fixed` it lasts until the next step instead, so what a step drew
  is still there in the frames between steps rather than flickering on a fast
  screen.
- **`screen()` draws in pixels** from the top left, for a readout that stays
  where it is while the camera moves; `within2d(at, angle)` draws in
  something's own frame.
- **`app.debug_under` draws under the world** instead of over it: after the
  frame is cleared and before the sprites, so the game covers its lines. An
  editor's grid, a level's guide lines. It is the same pen, and it makes no
  pass of its own on a frame it holds nothing.
- **Drawing never fails.** No `try`: a shape there is no memory for is
  counted and dropped rather than stopping the frame.
- **It has its own font**, ASCII at a fixed size in pixels, so a number on
  the screen needs nothing loaded. It is drawn wherever the world is - over
  the interface on screen, and into the texture `drawWorld` draws - and with
  `world_on_screen` off the window shows none of it.

**The engine draws some things itself**, each off until asked for:

```zig
app.debug_views.colliders = true;       // what the physics sees, in its body's colour
app.debug_views.stats = true;           // fps, frame time and what is in the world
app.debug_visible = false;              // none of it, the game's own shapes included
```

| View | What it draws |
| --- | --- |
| `colliders` | Every collider's shape: green static, blue kinematic, orange moving, grey asleep, cyan a sensor. |
| `bodies` | Each moving body's centre of mass, and an arrow a tenth of a second of its travel long. |
| `transforms` | Each transform's axes, `x` red and `y` green, and a line to what it hangs from. |
| `sprites` | Each visible sprite's outline. |
| `cameras` | What the camera shows, and the area a camera fits. |
| `stats` | The frame's rate and length, entities and bodies, and sprites and draw calls, top left. |

- **A view is drawn where the renderer draws**: a body's outline follows its
  entity's transform between fixed steps, as its sprite does, so it stays on
  the sprite on a fast screen.
- **`debug_visible` is the one switch** for everything `debug` holds, and
  `Options.debug_key` - F3, say - flips it. Hidden, the views are not even
  worked out.
- **An editor lists them by walking the struct**, so a View menu needs no
  list of its own and gains an entry when a view is added:

  ```zig
  inline for (std.meta.fields(fx.DebugViews)) |view| {
      if (menu.checkbox(view.name, @field(app.debug_views, view.name))) |on| @field(app.debug_views, view.name) = on;
  }
  ```

## 💥 Physics

```zig
fn spawn(app: *fx.App) !void {
    _ = try app.world.spawnWith(.{                     // a floor: a static body of its own
        fx.Transform2D.at(480, 520),
        fx.Sprite.solid(.hex(0x2B3442), 960, 40),
        fx.Collider2D{},                               // the size of its sprite
    });
    _ = try app.world.spawnWith(.{
        fx.Transform2D.at(480, 100).interpolated(),
        fx.Sprite.of(crate),
        fx.RigidBody2D{},
        fx.Collider2D{ .bounce = 0.3 },
    });
}

fn jump(app: *fx.App) !void {                          // a .fixed system
    const player = app.find("player") orelse return;
    const body = app.world.get(player, fx.RigidBody2D) orelse return;
    if (app.input.justPressed(.space)) body.linear_velocity.y = -500;
}
```

- **A `RigidBody2D` is a body and a `Collider2D` its shape**, both plain
  data. The engine makes the body in
  [Fluxion Physics](https://github.com/kisstp2006/fluxion-physics), changes it
  when the components change, and takes it away with the entity. The handle
  is kept beside the world, as a name is, so a scene saves bodies like any
  other component and an editor's inspector shows them.
- **A collider on its own is a static body**: a floor, a wall, a tile. On an
  entity hanging from a body it is part of that body, where the entity is -
  a compound shape is a body and a few children.
- **A collider with no size is its sprite's**, pivot and all, and the
  transform's scale scales it. `.rectangle(half_width, half_height)` says
  otherwise, in half sizes, and so does `.circle(r)`.
- **Names and rules.**
  - Two colliders touch when either one's `collision_mask` has the other's `collision_layer`: 32 bits, one for each layer. The project file names them.
  - A pair's `friction` is the smaller of the two, and its `bounce` the two added, no more than one.
  - A body's `linear_damp` and `angular_damp` of minus one take the project's.
  - `continuous_cd` sweeps a fast body against other moving bodies too; the level stops one either way.
- **A platform to jump up through** is a collider with `one_way_collision`.
  - What comes onto it from its entity's `-y`, up the screen, stands on it; what comes from below or the side goes through.
  - It is decided when the two first touch and kept while they touch.
  - Turn the entity, or the collider's `rotation`, and the side turns with it.
- **`disabled` takes a collider out** until it is turned back on: nothing
  touches it, and what stood on it falls.
- **Two bodies can be kept apart by name**:
  `app.addCollisionExceptionWith(a, b)`, whatever their layers say.
  - Counted: `removeCollisionExceptionWith` takes one back.
  - `collisionExceptionsOf(body, &buffer)` lists them.
  - It lasts through a body made anew and goes with either entity.
- **The world steps after each `.fixed` stage**, on the same scheduler as the
  queries, so what a `.fixed` system wrote is in that step. Then each moving
  body's place goes into its transform and its speed into `linear_velocity`;
  set `interpolate` on the transform to draw it between steps.
- **Writing is moving.** A transform the game writes puts the body there,
  and a `linear_velocity` it writes sets the body going. For a force or an impulse,
  `app.bodyOf(entity)` is the body itself. A body is in the world's space: a
  moving parent does not carry it, and its place is written back in the
  parent's space.
- **Contacts come back as entities, once.** `app.contactsBegun()` and
  `contactsEnded()` list what touched and what parted in this frame's steps,
  each once however many steps ran; a `.fixed` system hears those of the
  step before. A sensor pushes nothing and is still heard. An ended contact
  may name a despawned entity - often that is why it ended.
- **The three questions, answered in entities**: `app.castRay(from, to, .{})`,
  `app.overlapPoint(point)` and `app.overlapBox(min, max, &buffer)`.
- **How the world moves is the project's**: `physics_2d` in `project.fluxion`
  - and its layers' names, `layer_names.physics_2d` - or `Options.physics_2d`
  for a game with none.
  - By default, gravity is 98 down the screen, and damping 0.1 and 1.
  - A game of a hundred pixels to the metre that wants Earth's gravity says `.default_gravity = 981`.
- **Everything else is `app.physics`**: settings, and joints between the
  handles `app.bodyIdOf` gives. `Options.physics` starts at a hundred units a
  metre, which scales the physics' tolerances.

**When the bodies catch up.** Before every fixed step the engine compares
each body and collider with what it last made, and on a paused frame - and
the first, which has no time to step - at the top of the frame. So a query
sees what was spawned as of the last step, a static collider moved is found
where it went after the next one, and a system that needs a body at once -
to join it to another just spawned - calls `app.syncBodies()`. The
comparison is one pass over every collider, about 17 ns each on the machine
this was measured on: 131 us a step for 7,500, where the step itself takes
75 us resting and 267 us falling. A level of thousands of tiles wants the
tilemap below rather than an entity a tile.

### 🚪 Areas: what is in a place

```zig
const door = try app.world.spawnWith(.{ fx.Transform2D.at(320, 180), fx.Area2D{}, fx.Collider2D.rectangle(20, 40) });
try app.signal(door, fx.Area2D, .body_entered).connect(.method(door, "_on_body_entered"), .{});

fn onBodyEntered(app: *fx.App, self: fx.Entity, body: fx.Entity) !void {
    if (app.world.has(body, Player)) open(app, self);
}

// Or asked, instead of heard:
if (app.hasOverlappingBodies(door)) open(app, door);
```

- **An `Area2D` is a place that tells what is in it and pushes nothing**:
  a trigger, a pickup, a hurtbox, a door's threshold. Its shapes are its own
  `Collider2D` and the ones hanging from it, every one of them a sensor
  whatever its collider says, and in the physics it is a kinematic body that
  goes where its transform goes.
- **It says eight things**, naming each collider by its entity:
  `body_entered` and `body_exited`,
  `area_entered` and `area_exited`, and a `*_shape_entered` and
  `*_shape_exited` for each, which name the two colliders as well.
  `body_entered` comes once for a body however many of its shapes are in
  there: at the first shape pair, and `body_exited` after the last.
- **`body` is the collision object**, not the collider: the entity the
  collider belongs to, which `app.collisionObjectOf` gives - its own entity
  when that has an `Area2D` or a `RigidBody2D`, else the nearest one above
  it that has, else itself, being its own static body.
- **Who is told is the asking side's business.** An area reports what its
  own shape's `mask` takes, whatever the other side's mask says, so a
  hitbox and a hurtbox work: a hitbox is on the hitboxes layer and asks for
  nothing, a hurtbox asks for hitboxes and is on no layer, and only the
  hurtbox is told. An area is reported to another area only while its
  `monitorable` is true.
- **The questions, as of the last step:** `app.overlappingBodies(area, &buf)`,
  `app.overlappingAreas(area, &buf)`, `app.hasOverlappingBodies(area)`,
  `app.hasOverlappingAreas(area)`, `app.overlapsBody(area, body)` and
  `app.overlapsArea(area, other)`. With `monitoring` off they are empty and
  say so in the log once.
- **`monitoring` turned off leaves what was in it with an exit**, and turning
  it on again finds what is in it and says so. So do a mask changed, an area
  that becomes monitorable, and a component taken away: what an area says is
  worked out again after every step, from the pairs the physics holds.
- **An exit is also said when the other side despawns**, naming the entity
  that has died, as an ended contact does.
- **The signals are emitted after the step and heard before the systems of
  the next one**, so a `.fixed` system that moves a player sees the doors it
  opened on its next turn.
- **An entity is an area or a body, not both.** One with an `Area2D` and a
  `RigidBody2D` is a body, its area does nothing, and the log says so once.
- **An area has no `priority`, no gravity or damping overrides and no audio
  bus**: this is what overlaps, not a place that changes physics.
  `input_pickable` is here and does nothing yet; picking comes next.

### 🖱️ Picking: what the pointer is on

```zig
const lamp = try app.world.spawnWith(.{
    fx.Transform2D.at(200, 120),
    fx.Sprite.of(bulb),
    fx.Area2D{},            // input_pickable is true on an area
    fx.Collider2D{},        // the sprite's size
});
try app.addMethod("_on_input_event", onLampInput);
try app.signal(lamp, fx.Area2D, .input_event).connect(.method(lamp, "_on_input_event"), .{});

fn onLampInput(app: *fx.App, self: fx.Entity, event: fx.InputEvent, shape: fx.Entity) !void {
    _ = shape;
    if (!event.isPressed(.left)) return;
    toggle(app, self);
    app.input.setAsHandled();   // the room behind it does not hear the click
}
```

- **Once a frame, after the `.input` stage and before the first fixed step.**
  A game's own `.input` system sees the pointer first and can keep it with
  `app.input.setAsHandled()`; picking then does nothing at all. It does not
  wait for a physics tick, so it has no lag.
- **What can be picked** is an `Area2D` or a `RigidBody2D` with
  `input_pickable` - true on an area and false on a body -
  through a collider that holds the point, is on a layer (a `collision_layer`
  of nought is never picked, and there is no picking mask), and whose object,
  if it is drawn at all, is visible. A lone `Collider2D`, which is its own
  static body, is not a collision object to pick: give it an `Area2D` or a
  static body with the flag.
- **Every pointer event of the frame goes to it, in order**: presses,
  releases, the wheel's notches as presses and releases of wheel buttons,
  and one motion event for the frame's moving. `app.input.pointerEvents()`
  is the same list, for a game that would rather read it itself, and
  `app.input.buttonMask()` says what is held.
- **What is on top hears first**: higher `Sprite.layer`, then higher
  `Sprite.order`, then the later entity. It sorts unless
  `app.physics_object_picking_sort` is false.
- **Each shape under the point hears**, so an object with two
  colliders under the pointer hears twice, with `shape` saying which. With
  `app.physics_object_picking_first_only` only the first hears.
- **A handler stops the rest** by calling `app.input.setAsHandled()`: the
  objects under it hear nothing of that event.
  The handlers run as each object is told, so the next one sees it.
- **`mouse_entered` and `mouse_exited`** come with the pointer, and
  `mouse_shape_entered` and `mouse_shape_exited` for each collider. Hover is
  worked out on every frame, event or no event, so a thing that moves under
  a still pointer is entered; a thing that dies under it drops out
  silently; and one that stops being pickable is left at the next pass.
- **Nothing is picked** while picking is off, while the cursor is `.locked`,
  while the pointer is outside the window, or while the interface wants it -
  `app.ui.wantsPointer()`. In each case what was hovered is left with its
  exits.
- **An editor turns it off** with `app.physics_object_picking = false`,
  beside `app.signals.dispatch = false`.
- **`event.position` is in the window's pixels**. `app.screenToWorld(x, y)`
  takes it into the world.

Not here yet: polygons, joints as components, and a view of the colliders in
`debug`.

## 📁 The project's files

```zig
const hero = try app.assets.loadTexture("res://art/hero.png", .{});  // from the project's root
try app.saveScene("res://levels/meadow.json", .{});
const font = try app.assets.loadFont("C:/Windows/Fonts/segoeui.ttf", .{}); // the operating system's
```

```bash
game --root ../my-game          # or App.Options.root; the working directory otherwise
```

- **A `res://` path is the project's**: `res://art/hero.png` is
  `art/hero.png` under the project's root, whichever directory the program
  was started in. Any other path is the operating system's, as it always
  was - a system font, where a screenshot goes - and every call that takes a
  path takes both: `loadTexture`, `loadFont`, `loadScene`, `readScene`,
  `saveScene`, `saveCapture`.
- **A file inside the root is kept by its `res://` path however it was
  asked for** - `art/hero.png` from the root, its absolute path, `art\hero.png`
  - so `textureSource` gives the project's name for it, `findTexture` finds
  it by any spelling, and a scene never holds one machine's directories. A
  `res://` path that climbs out with `..` is `error.OutsideProject`.
- **A file can have a UUID**, kept beside it in a `.uid` file -
  `art/hero.png.uid`, one line, `uid://...`.
  Saving a scene gives one to every loaded file of the project's that has
  none, and a scene names each file by its UUID as well as its path; reading
  goes by the UUID first, so a texture moved or renamed together with its
  `.uid` file is found where it went (`loaded.moved` counts them). Commit the
  `.uid` files with the files they sit beside.
- **`uid://...` is a path too**, anywhere a `res://` one is taken.
  `app.project.pathOf(uid)` answers from the `.uid` files read so far, and a
  UUID none of them holds sends it through the project once, passing over
  hidden directories, `zig-out` and `zig-pkg`; `app.project.rescan()` looks
  again after files moved while the program ran.
- **The root is `Options.root`**, or `--root` among the engine's flags - the
  folder, or the `project.fluxion` in it - or else the working directory.

```zig
const kind = fx.AssetKind.ofPath("res://ui/game.theme").?;                    // .theme
const set = try app.loadAsset(fx.TileSetHandle, "res://tiles/terrain.tileset"); // read once, found after
const path = app.assetSource(sprite.texture) orelse "made in memory";          // the file a handle holds
```

- **Every kind of file is one entry in `fx.AssetKind`**: textures, fonts,
  scenes, scripts, tile sets and themes - what each is called, the endings
  of its files, and the handle a component holds one by
  (`AssetKind.Handle(.texture)`, `AssetKind.of(fx.TextureHandle)`).
  `app.assetSource`, `app.loadAsset` and `app.findAsset` take any handle
  type. A scene writes and reads every handle through them, a project
  setting names a file of a kind with `attr.ProjectFile{ .kind = .scene }`,
  and an editor draws a field for each kind the list has.

```zig
try app.moveFile("res://art/hero.png", "res://art/people/ada.png"); // with its .uid, and what was read from it
try app.copyFile("res://art/people", "res://art/crowd");             // folders too; a copy gets a UUID of its own
try app.moveToTrash("res://art/old.png");                            // where the person can take it back from
_ = try app.assets.reloadFile("res://art/hero.png");                 // changed on the disc: read again in place
```

- **A file moved takes its UUID along.** `app.moveFile` moves or renames a
  file or a folder with the `.uid` files that go with it, tells the project
  where each UUID is now, and moves what was read from it too: a texture's
  `textureSource` is its new place, so the scene saved next names it, and a
  scene saved before finds it by its UUID. Moving and `app.copyFile` never
  write over a file (`error.PathAlreadyExists`) or go into themselves
  (`error.InsideItself`), and a copy of a file with a UUID is given a new
  one, so two files never share one.
- **Throwing away can be taken back.** `app.moveToTrash` moves a file or a
  folder to the Recycle Bin or the freedesktop.org trash, its `.uid` file
  after it, and forgets its UUIDs; what was loaded from it stays loaded.
  `fx.App.trash_available` says whether this system has a trash, and
  `app.trash` names a folder that stands in for it - what a test uses, which
  must not fill the person's own.
- **A file changed on the disc is read again in place.**
  `app.assets.reloadFile` reads every texture and font read from it again,
  under the same handles - a sprite shows the new pixels, at the new size,
  and text draws its glyphs again - and `reloadTexture`/`reloadFont` do one.
  A file that no longer reads is an error, and what was loaded stays as it
  was.

### The project file

```json
{
  "fluxion_project": 2,
  "application": { "name": "Meadow", "icon": "res://icon.png", "main_scene": "res://levels/meadow.json", "tags": ["2d"] },
  "display": { "width": 1600, "height": 900, "mode": "maximized" },
  "physics_2d": { "default_gravity": 420 },
  "layer_names": { "physics_2d": ["world", "player"] },
  "gui": { "theme": "res://ui/game.theme" },
  "my_game": { "lives": 3 }
}
```

```zig
var settings = try fx.Project.readSettings(gpa, io, "games/meadow", &diagnostics);  // no App, no GPU
defer settings.deinit();
try fx.Project.create(gpa, io, "games/pasture", .{ .application = .{ .name = "Pasture" } });  // error.ProjectExists over one
try fx.Project.writeSettings(gpa, io, "games/pasture", renamed);                    // written beside, then moved over
const mine = try settings.section(MyGame, "my_game", arena);                          // a game's own section
```

- **`project.fluxion` marks a project's folder.**
  A game and an editor read the same file: `App.create` reads the one at the
  root - `app.project.settings` - before anything opens, and a project
  manager lists projects with `Project.readSettings`. A root without one
  starts as it always did, with `settings` null.
- **Settings are data.** A section is a plain struct - `Application`,
  `Display`, `Rendering`, `Physics2D`, `LayerNames`, `Gui` - and a setting
  a field of it, with its default and its description in `reflect_fields`:
  `attr.Doc`, `attr.Range`, and `attr.ProjectFile`, `attr.Required`,
  `attr.Advanced` and `attr.Restart` for what a setting is besides its value.
  `fx.settings_file` reads and writes any such struct, and an editor draws
  its Project Settings from the same fields: a new setting is a new field.
- **A file says only what differs**: a setting at its
  default is not written, nor a section all of whose settings are. A key
  naming no section of this build - a newer one's, or a game's own - is kept
  and written back; the game reads its own with `settings.section`. A key
  inside a section that no setting reads is passed over with a warning.
- **The project says how the game opens**: the window's `width`, `height`,
  `resizable`, `mode` (`windowed`, `maximized`, `fullscreen`) and `vsync`,
  the `clear_color`, the `ticks_per_second` of the fixed step, and the
  `icon` on the window. What the game's own `App.Options` say overrules it,
  field by field; what neither says is the sections' defaults, so a folder
  with no project file opens as it always did.
- **`application.name` is all it must have.** The name is the window's
  title when the game gives none.
- **What is wrong is said, with where it is**, and stops the start rather
  than being guessed round: another version - version 1, the flat file
  before sections, is refused, and says it was written for an older
  Fluxion - a value of the wrong kind, with its line, a path that is not the
  project's, and no name, each by its key: `application.icon`.
  `Options.project_diagnostics` is where it is said; without one it is said
  in the log.

### The renderer chooses the backend

| Renderer | APIs | Windows | Linux, macOS, Android | Browser |
| --- | --- | --- | --- | --- |
| `compatibility` | Direct3D 11, OpenGL 3.3 | Direct3D 11, then OpenGL | OpenGL | WebGL 2 |
| `modern` | Direct3D 12, Vulkan | not built yet | not built yet | not built yet |

- **`Backend.auto` opens the best of the project's renderer** - the first of
  `Renderer.backends(os)` - and a folder with no project file is drawn with
  the compatibility renderer. So on Windows a game opens Direct3D 11 unless
  asked otherwise, examples and editor included.
- **A renderer that is not built opens nothing**: a `modern` project stops
  with `error.RendererNotBuilt` and says to choose `compatibility`, rather
  than being drawn with something it will not look like.
- **`--backend` wins over the project**, so one game can be checked on every
  backend of its renderer - `--backend gl` on Windows - and one outside it is
  allowed, and said in the log.

## 💾 Saves and settings

```zig
try app.writeText("user://slots/one.json", text);           // written beside, then put in place
const again = try app.readText(gpa, "user://slots/one.json"); // error.FileNotFound before the first save
const slots = try app.listDir(gpa, "user://slots");          // sorted; a folder's name ends with "/"
defer slots.deinit(gpa);

var config = try fx.ConfigFile.load(app, "user://settings.cfg"); // empty on the first run
defer config.deinit();
const music = config.getFloat("audio", "music", 0.8);
try config.set("display", "fullscreen", true);
try config.save(app, "user://settings.cfg");
```

- **`user://` is the player's folder**, one of the game's own under the one
  the system keeps for programs' data: `%APPDATA%` on Windows,
  `~/.local/share` on Linux, `~/Library/Application Support` on a Mac. It is
  named after the project's `application.name`, or the title a game gives
  with no project, and made when the first file is written in it.
  `Options.user_root` puts it somewhere else: a test's folder, or beside a
  game kept on a stick. A `user://` path that climbs out with `..` is
  `error.OutsideProject`, as a `res://` one is.
- **Files by any path.** `readText`, `writeText`, `fileExists`, `makeDir`,
  `listDir` and `removeFile` take `res://`, `user://`, `uid://` and the
  system's own paths. `writeText` makes the folders on the way and writes
  the new text beside the old before putting it in place, so a game that
  stops halfway through a save leaves the last one whole. `removeFile` takes
  a file, or a folder with nothing in it.
- **A config file needs no declaring.** `ConfigFile` is sections of keys, a
  JSON object of objects to read and to edit by hand, with comments allowed.
  A key is whatever it was last set to - a bool, a number, text - read with
  `getFloat`, `getInt`, `getBool` and `getString` and a default for one it
  has not got. What the file holds that the game does not ask for, written
  by a newer build or by hand, is kept and saved back. A game whose
  settings have a shape of their own reads them into a struct with
  `fx.settings_file` instead, as the project file is read.
- **A script saves the same way**, with `files` and the language's `json`
  module: see [Scripts](#️-scripts).

## 🆔 UUIDs

```zig
const door = app.findUuid(door_uuid) orelse return;    // the same door after a save and a load
const uuid = try app.ensureUuid(entity);               // one, if it had none
try app.setUuid(respawned, uuid);                      // an editor's undo brings it back as it was
```

- **A handle is new every run; a UUID is for good.** `fx.Uuid` is
  [Fluxion Id](https://github.com/kisstp2006/fluxion-id)'s: 128 bits, random
  (version 4) from a generator the operating system seeds, `{f}` to print
  and `Uuid.parse` to read.
- **An entity's UUID is its own, not a component** - kept beside the world,
  as its name is. One living entity has a UUID at a time (`error.UuidTaken`),
  the nil UUID is no UUID (`error.NilUuid`), and a despawned entity's is free
  at once and forgotten at the end of the frame. `app.newUuid()` makes one
  for anything else a game wants named for good.
- **A scene gives every entity it writes one**, and every entity it reads the
  one it had - unless an entity in the world has that one already, as when
  the same scene is loaded twice, and then a new one (`loaded.reassigned`);
  references inside the scene still find their own.

## 🎲 Chance, points and boxes

```zig
const roll = app.randomInt(1, 6);                // either end can come up
if (app.randomChance(0.25)) try spawnRat(app);   // one time in four
app.seedRandom(1234);                            // a replay draws the same numbers again

const cell = app.cellAt(map, app.pointerInWorld()).?;  // an fx.Vec2i
const used = app.usedCells(map).?;                      // an fx.Rect2i
if (used.hasPoint(cell)) try paint(app, cell);

const red = fx.Color.parse("#C8434F").?;         // #RGB, #RGBA, #RRGGBB, #RRGGBBAA
```

- **The game's chance is its own**, apart from what UUIDs are drawn from:
  `randomFloat`, `randomRange`, `randomInt`, `randomChance` and
  `randomIndex` (a place in a list, to pick one of it). The operating system
  seeds it when the app is made, `Options.random_seed` or `seedRandom`
  instead, so a run seeded the same draws the same; `randomize` seeds it
  from the system again. A script calls the same:
  `app.randomInt(1, 6)`. Not for secrets.
- **`fx.Vec2i` is a point of a grid** - a cell, a pixel, a window's place -
  and `fx.Rect2` and `fx.Rect2i` are boxes by where they start and how big
  they are, with fractions and without. `end` is the first point past a
  box, so two boxes side by side share no point; `hasPoint`, `intersection`,
  `merge`, `grow`, `expandTo`, and for cells `fromCells` and `last`. A map's
  cells are `Vec2i`s and its used cells a `Rect2i`, from Zig and from a
  script alike.
- **A colour reads from text** with `fx.Color.parse`, as a theme file and a
  colour field write one.

## 🎬 Scenes

```zig
try app.registerComponents(.{ Wander, Player });                       // the game's own
try app.saveScene("res://levels/meadow.json", .{});                    // to read, diff and edit
try app.saveScene("res://levels/meadow.scene", .{ .format = .cbor });  // the same, in fewer bytes
const loaded = try app.readScene("res://levels/meadow.scene", .{});    // either: it can tell

const bat = try app.loadScene("res://enemies/bat.json");               // a scene to make things of
const one = try app.instantiate(bat, cave);                            // its root, under cave
app.changeScene(try app.loadScene("res://levels/two.json"));          // at the end of the frame
```

### Scenes as things a game makes

- **A scene is a file a game holds**: `loadScene` reads it once and gives a
  `SceneHandle`, which a component can hold like a texture, and
  `readScene` reads a file straight into the world, beside what is there -
  what an editor opens one with.
- **`instantiate(scene, parent)` makes one**: the scene's one root, under
  `parent`, with the rest of it under the root. Each instance's entities get
  UUIDs of their own, made from the instance's and the file's - so two are
  never confused, and something that names an entity inside one finds it
  again every time the file is read. A scene of more than one root is
  `error.NotOneRoot`: `saveScene(path, .{ .root = branch })` saves a branch,
  with nothing it hangs from, as a scene of one. `makeLocal(root)` makes an
  instance the world's own.
- **A scene can hold an instance of another.** Its entry is the instance's
  root: its UUID, its parent, its name and groups, `"instance"` - the file
  it is of - and what its root has that the file does not give it: a
  field that differs, a component it was given, and in `"removed"` a
  component it has not. The rest is made from the file each time it is
  read, so an edit of the file reaches every instance of it, and a scene
  saved with an instance in it writes it the same way. A scene that is an
  instance of itself, however deep, is a mistake rather than a loop.

  ```json
  { "uuid": "…", "parent": "…", "name": "Big bat", "instance": "res://enemies/bat.json",
    "Transform2D": { "x": 50.0 }, "Area2D": {}, "removed": ["Sprite"] }
  ```

- **The scene the game plays** is changed with `changeScene` at the end of
  the frame - `openScene` now - and `currentScene` says which it is. What
  it brought goes with everything that hangs from it, and what is not its
  own stays: an autoload, what the game spawned itself at the top of the
  tree.
- **A project opens itself**: `openProject` - or `Options.open_project`, at
  `startup` - shows its `application.boot_splash`, makes its
  `application.autoload` list - scenes and scripts, each an entity named
  after its file that a scene change leaves - and opens its
  `application.main_scene`.
- **A scene can be read in the background**: `loadInBackground(path)` reads
  its file and decodes the pictures it names on a thread of its own - on a
  page, which has none, a piece a frame - and says how far it has got with
  `progress()` and `done()`. `takeScene` makes the pictures textures and
  gives the scene, ready to change to without a pause.

```json
{
  "fluxion_scene": 3,
  "entities": [
    {
      "uuid": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c",
      "name": "player",
      "groups": ["heroes"],
      "Transform2D": { "x": 320.0, "y": 180.0 },
      "Sprite": { "texture": "res://art/hero.png", "width": 48.0, "height": 48.0 }
    },
    {
      "uuid": "5c2d7e9f-0a1b-4c3d-8e5f-6a7b8c9d0e1f",
      "parent": "0b8e3c1a-5f2d-4c6e-9a7b-1d2e3f4a5b6c",
      "name": "turret",
      "Transform2D": { "y": -6.0 },
      "Sprite": { "texture": "res://art/turret.png" }
    }
  ],
  "assets": {
    "res://art/hero.png": { "uid": "uid://2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34", "filter": "linear" },
    "res://art/turret.png": { "uid": "uid://9d1e4b7a-3c2f-4e8d-a1b6-0f5c7e2d9a83" }
  }
}
```

- **An entity is an object of its components**, each under its type's name,
  with the entity's UUID, its parent, its name and its groups beside them. A
  name taken among the siblings it is read into becomes the next free one. A field that holds its default
  is left out, so the file says what is particular about each thing - and a
  field added to a component later reads as its default from every scene
  written before it.
- **What a handle points at is written, not the handle.** An entity in a
  field - an entity's `parent`, a game's `leader` - is that entity's UUID,
  so adding one at the top changes no other line of the file. A texture or a
  font is its file's `res://` path - `{ "file": ..., "member": 1 }` for a
  font of a collection past its first - and in `assets` its UUID and, for a
  texture sampled otherwise than by default, how. Loading mints new
  entities, points every reference at them - in the scene first, then in the
  world, so one scene can name an entity another brought - and loads the
  files or finds them already loaded. A texture made from pixels has no
  file, and is written as `null`.
- **Only version 3 is read.** An older scene - a version 2 one with its
  parent inside a `Transform2D` or a `Control`, or a version 1 one with
  references by their place in the list - is refused with a message that says
  so, and so is a newer one.
- **JSON and CBOR are one scene in two spellings.**
  [Fluxion JSON](https://github.com/kisstp2006/fluxion-json) writes and reads
  both, and loading tells them apart by the bytes CBOR starts with. CBOR is
  the smaller file; JSON is the one to read, to diff, and to edit by hand,
  comments and all.
- **A scene holds what it has been told about.** The eight engine components
  are registered from the start, and a game's own under their type's name -
  or a `pub const scene_name`, for two types called the same, or failing
  that its `reflect_name`. A component in a file that nothing here is
  registered as is kept with its entity as the file has it, and saved back
  that way, counted in `loaded.components_unknown`. So a scene from a newer
  build still opens, and an editor without a game's own components saves
  the game's scenes whole. `app.unknownComponentsOf(entity)` lists them,
  each with its value as JSON, and `app.removeComponentNamed` takes one off.
- **A mistake says where it is** - the line and column, or the byte in CBOR,
  and the path to the value - and leaves the world as it was:

  ```
  meadow.json:3:32: no entity in this scene or in the world has the UUID 77777777-7777-4777-8777-777777777777 (at /entities/1/parent)
  ```

- **A scene that is wrong is an error, never a crash**, so an editor shows it
  and goes on. Numbers no hand would give still load - JSON5 keeps NaN and the
  infinities - and the frames after them do not stop either: an animation of
  no columns or an endless rate shows its first cell, a collider with a NaN in
  its shape gets no shape, a label's size is held to what its atlas can keep.

- **A load goes beside what is there.** A level over another is
  `app.clearWorld()` - every entity, name and UUID gone at once - and then
  the load. The font a `Text2D` with no font of its own is drawn in belongs
  to the program, not the scene: whichever was loaded first.
- **The connections a game made with `.persist` go with it**, in a
  `connections` list after the entities, by UUID, including the ones this
  build does not know. See [Signals](#-signals).
- **One entity on its own** is `scene.EntityJson`, for `json.stringify` or
  `json.Document.from`: the same object a scene holds, and with
  `.every_field = true` every field, which is what an editor's inspector
  shows.
- **A scene can be asked what it is without loading it.**
  `app.sceneInfo(path, null)` reads its version, its format, how many
  entities it has and the files its `assets` names, with their UUIDs - what
  an editor lists of a scene it has not opened - and is null for a file that
  is not a scene; a scene of another version is told, not refused.
  `scene.readInfo` does the same from memory, with no `App`.
  `app.createScene(path, .{})` writes an empty one, never over another.

`zig build example-creatures -- --frames 1 --save-scene creatures.json` writes
the example's world - JSON for a path ending in `.json`, CBOR for any other -
and `-- --scene creatures.json` starts from that file instead of from the code
that built the world. Its 74 entities take 36 KB as JSON and 19 KB as CBOR -
a UUID each and one for every reference, 6 KB of either - and the saving
leaves `examples/atlas.png.uid` beside the sheet it names.

## 🪞 Reflection

```zig
const place = app.componentOf(player, "Transform2D").?;       // by the name a scene gives it
try (try place.field("x")).setFloat(320);                      // written where it is
for (place.type.fields()) |field| inspect(field, try place.field(field.name.slice()));

var found: [16]fx.App.ComponentValue = undefined;
for (app.componentsOf(player, &found)) |component| show(component.name, component.value);
_ = try app.addComponentNamed(player, "Collider2D");           // an inspector's Add Component

var title: []const u8 = "Level 2";
try app.callNamed("setWindowTitle", &.{.of(&title)}, null);    // the engine, called by name
try app.setStateNamed("Mode", "paused");                       // a state, by its names
```

An inspector, a console and a script want the game's types while it runs -
long after Zig's own reflection has finished with them.
[Fluxion Reflect](https://github.com/kisstp2006/fluxion-reflect) keeps them
as data, and the engine hands its components and its calls out through it.

- **Every component is described**: its fields, their types, offsets and
  defaults, and what a number means where its name does not say, from
  `fx.attr` - a `Range` for a slider on a sprite's pivot, a colour's
  channels, a collider's friction and bounce; `Angle` on every rotation,
  kept in radians and shown in degrees; a `Unit` after a number (`px`, `s`,
  `/s`); `Layers` on a collider's layer and mask, a toggle a bit named from
  the project's list; `Extents` and `Radius` on its size and `Placement` on
  the collider itself, for an editor's handles; a `Doc`
  for a zero that is not zero ("zero is the sprite's width"); `Hidden` on
  `Text2D`'s buffer, whose words are a `Property` instead - `text`, read
  with its method `slice` and written with `set`, which keeps the length and
  the UTF-8 right and is `Multiline`; `ReadOnly` on an animation's
  `finished`, which only the engine sets. A descriptor is made at compile
  time and kept in the binary: nothing is registered or allocated to have
  one.
- **A component is found by the name a scene gives it**, so a scene, an
  inspector and a console say the same thing. `componentsOf` lists an
  entity's in the order they were registered, as many as the buffer holds.
  What comes back points into the world - writing it is writing the
  component - and lasts as a `world.get` pointer does, until rows next move.
  `addComponentNamed` and `removeComponentNamed` move them, so they are for
  between frames and not for inside a query.
- **A game's components are described the same way** once
  `registerComponents` has them, and say more about themselves with the
  declarations the engine's use:

  ```zig
  const Health = extern struct {
      points: f32 = 100,
      regen: f32 = 0,

      pub const reflect_name = "Health";   // its scene name too, unless it has a scene_name
      pub const reflect_fields = .{
          .points = .{fx.attr.Range{ .min = 0, .max = 100 }},
          .regen = .{ fx.attr.Unit{ .text = "/s" }, fx.attr.Doc{ .text = "Points back a second" } },
      };
      pub const reflect_methods = .{.heal};

      pub fn heal(self: *Health, amount: f32) void {
          self.points = @min(self.points + amount, 100);
      }
  };
  ```

  Two types given one `reflect_name` are `error.ComponentNameTaken`: a name
  is what a description is found by. A `Property` in `reflect_attributes`
  is checked when the component is registered: a getter or a setter it
  names that `reflect_methods` does not list, or a getter that does not
  return what the setter takes, stops the build.
- **A component says how an editor's scene treats what has it.**
  `fx.attr.Pickable{ .by_default = false }` in its `reflect_attributes` has
  a click in the scene pass over an entity that has it, until the editor
  is told otherwise for that entity. `Control`'s says so, so that a UI over
  the whole screen does not take every click meant for the world; an editor
  reads it with `app.componentsOf` and `Type.attribute`.
- **`App` is described by its calls, not its insides.** `App.reflect_methods`
  lists the ones that take and give plain values - names, the window, the
  clipboard, scenes, components and states by name - and `app.callNamed`
  makes one with values for arguments. An error the call returns is
  returned, where a bare `reflect.Value.call` would put it in a result, or
  nowhere. A console finds the call, parses each word into its parameter's
  type - `Value.parse` reads Zig's own syntax - and calls it.
- **`app.types` holds every type by name**: the eight components, the values
  inside them - `Color`, `Region`, the texture and font handles -
  `DebugViews`, and a game's components as they are registered. A game's own
  console commands go in beside them with `app.types.addFunction("give", give)`,
  to be called through `reflect.call`.
- **`App`'s calls are compiled in only where they are used** - by a
  `callNamed` somewhere in the program, or by `app.types.add(fx.App)`, which
  puts it beside the rest - because a listed call comes with everything it
  reaches. When every `create` registered `App`, that cost a ReleaseSmall
  `pong` 69 KB (1,247 KB to 1,316 KB), `crates` 64 KB, and `creatures`,
  which reads scenes already, 33 KB.
- **States by name, too.** A state is an enum the engine was never compiled
  against, so `app.stateNamed("Mode")` and `app.setStateNamed("Mode", "paused")`
  name it as a scene names a component. An editor's state panel walks
  `app.states.slots`, each with its type and so the names of its values.

## ✍️ Scripts

Flux scripts go on entities. A `Script` component names a `.flux` file and a
struct in it, and the entity gets an instance of that struct with itself in
it as `self.entity`.

```zig
try app.useScripts(.{});
const door = try app.loadScript("res://scripts/door.flux");
_ = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Script.of(door) });
```

```zig
// res://scripts/door.flux
struct Door {
    var open: bool = false;

    fn ready(self) {
        print("a door called", self.entity.name());
    }

    fn update(self, dt: float) {
        if (self.open) self.entity.get("Transform2D").rotation += dt;
    }
}
```

- **What is called, and when.**
  - `ready(self)` comes first.
  - `fixed(self, dt)` runs every fixed step, before the game's `.fixed` systems.
  - `update(self, dt)` runs every frame, before its `.update` systems.
  - Both only while the entity runs: see [Pause](#️-pause). A task a script starts - a call of a function that `await`s - is the entity's, and its waits stand still while the entity does not run.
  - `exit(self)` runs at the end of the frame in which the entity dies, or its `Script` is taken off or turned off, and when the world is cleared.

  A method the struct does not declare is not called. One with the wrong parameters is said once in the log and not called.
- **One VM, only in a game that asks.** `useScripts` makes the VM and
  registers `Script`. The frame reaches the scripts through pointers that
  only `useScripts` sets, so a game that never calls it has none of the
  language in it: the ReleaseSmall examples grew by half a kilobyte, and the
  one that saves and reads scenes by two.
- **What a script reaches.** `app` is the engine, with the calls
  `App.reflect_methods` lists. `self.entity` has `alive()`, `name()`,
  `uuid()`, `has(name)`, `get(name)`, `add(name)` and `remove(name)`.
  `files` reads the game's files and reads and writes the player's - see
  below.
  - A component from `get` is looked up again each time the script uses it, so keeping it in a field is safe while the world's rows move.
  - Once it is gone, using it stops the script with a panic saying so.
  - An entity is one handle wherever a script is handed it: `self.entity`, `app.find("door")`, a field such as `Parent.entity`, a signal's argument. So `app.find("door") == self.entity` says whether it is this one, and none is null.
  - Where a call or a field wants an entity, `app.nameOf(app.find("door"))`, the script gives that handle, a scripted entity's instance, or null. Anything else stops it with a panic saying what it gave.
- **A script cannot stop the game.**
  - Each call has a budget of loop rounds, `Options.budget`, ten million by default, and a call that runs past it is stopped.
  - A panic is said in the log with its line, once for each instance's method, and counted in `app.scripts.?.failures`; the other scripts go on.
  - `print` goes to the log, or to `Options.out`.
- **Read again while the game runs.**
  - `app.reloadScript(handle)` reads the file again. Every instance keeps its fields and goes on in the new code.
  - Text that does not compile leaves the old code running, with the reasons in the log.
  - `app.setScriptText` does the same from text, such as an editor's unsaved buffer.
  - With `.watch = 0.5` in the options, the files are looked at every half second, and one saved since is read again before that frame's scripts run. A game started from an editor as its own program takes what the editor saves; a shipped game leaves it off.
  - A file that does not compile at all still gets a handle, so a scene holding it opens, and it runs once a reload compiles.
- **Signals both ways.** A script's signals are its entity's, under `Script`:
  - `signal opened(by: string)` in the struct is listed by `app.signalsOf`, with its `signature` and `arity`, as soon as the entity has the `Script`.
  - It is connected by `app.connectNamed(door, "opened", ...)`, and saved with a scene.
  - It is heard by the table's connections when the script emits it.
  - A signal from a component, or another script's, calls a method the target's script declares, listed by `app.methodsOf`.
  - An `Entity` argument arrives as the entity's handle, and the script's instance or its entity's handle goes back to the engine as an `Entity`.
  - A connection made while its script did not compile is heard once it does.
- **A script keeps a save in the player's folder, and reaches no other.**
  `files.readText(path)`, `writeText(path, text)`, `exists(path)`,
  `makeDir(path)`, `list(path)` and `remove(path)` read under `res://` and
  `user://`, and write under `user://` only. Any other path is
  `error.NotAllowed`, so a script neither reads the player's documents nor
  breaks the game it came with. A call that fails gives an error to `catch`:

  ```zig
  const json = @import("json");

  fn save(slot: any) {
      files.writeText("user://save.json", json.stringify(slot, 2)) catch |e| print("not saved:", e.name);
  }

  fn load() any {
      const text = files.readText("user://save.json") catch return null;
      return json.parse(text) catch null;
  }
  ```
- **In a scene**, a `Script` is its file's path and its struct, and once the
  scene is saved, the file's UUID as well. Reading the scene loads the file:
  `"Script": { "source": "res://scripts/door.flux", "struct_name": "Door" }`
- **An editor checks scripts as the game compiles them.**
  `app.scriptSetup()` gives the language service's `flux.service.Options`
  with `app` and `self.entity` declared. This is for completions and
  diagnostics, and it needs no `useScripts`.
- **An editor has the scripts and runs none of them**, with
  `useScripts(.{ .run = false })`.
  - Each file is compiled and never run: not its top level, a default, `ready` or `update`. So a script cannot change the scene being edited.
  - Its structs' signals and methods are still listed and connected to, and the scene still writes the script.

## 🧪 It runs with no window and no GPU

```zig
const app = try fx.App.create(gpa, .{ .headless = true, .frames = 60 });
```

The `none` backend accepts every call and draws none of them, the frame goes
into a texture instead of a swapchain image, and the clock advances by a fixed
amount whether or not any time passed. Every test in this package runs that
way, which is why `zig build test` passes on a machine with no display.

For a picture on such a machine, `app.capture(gpa, w, h)` draws one frame into
a texture of its own and hands back the pixels - the same passes, somewhere
else - and `app.saveCapture(path)` writes them to a PNG.
`zig build example-pong -- --frames 420 --capture out.png` is that, and it is
how the screenshot in a pull request gets made.

Those are the engine's own flags, and a game gets them in two lines:

```zig
const flags = try App.parseFlags(App.Flags, arguments);  // --backend --width --height --frames --capture --root
const app = try App.create(gpa, flags.apply(.{ .title = "game", .io = io }));
```

`parseFlags` reads any struct of optional fields by name - `write_atlas` is
`--write-atlas` - and a struct inside it as flags too, so a game puts
`App.Flags` beside its own. `apply` lays the flags over the game's options,
and makes a capture reproducible: every frame one fixed step, whatever the
clock says, so the same flags draw the same picture on every machine.

## 📦 Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-engine
```

```zig
const fluxion = b.dependency("fluxion_engine", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_engine", fluxion.module("fluxion_engine"));
```

Fourteen dependencies come with it and **none of them is lazy**, which is the
difference between an engine and the libraries under it. A library keeps its
window and its file reading behind `lazy` so a consumer never downloads what
it does not use; an engine uses all of it by definition.

[ECS](https://github.com/kisstp2006/fluxion-ecs) ·
[RHI](https://github.com/kisstp2006/fluxion-rhi) ·
[Platform](https://github.com/kisstp2006/fluxion-platform) ·
[UI](https://github.com/kisstp2006/fluxion-ui) ·
[Shader](https://github.com/kisstp2006/fluxion-shader) ·
[Image](https://github.com/kisstp2006/fluxion-image) ·
[Font](https://github.com/kisstp2006/fluxion-font) ·
[Debug draw](https://github.com/kisstp2006/fluxion-debugdraw) ·
[JSON](https://github.com/kisstp2006/fluxion-json) ·
[Physics](https://github.com/kisstp2006/fluxion-physics) ·
[Reflect](https://github.com/kisstp2006/fluxion-reflect) ·
[Script](https://github.com/kisstp2006/fluxion-script) ·
[Math](https://github.com/kisstp2006/fluxion-math) ·
[Id](https://github.com/kisstp2006/fluxion-id)

**Every dependency is pinned to a pushed commit**, so `zig fetch` builds the
engine anywhere and not only beside the repositories it is made of. A change
pushed to one of them reaches the engine when its pin moves:

```bash
zig fetch --save=fluxion_rhi git+https://github.com/kisstp2006/fluxion-rhi#<commit>
```

**Some pins have to agree.** `Device.clip()` returns a `math.Clip` and
`math.orthographic` takes one, so the two must be the *same* type - and a Zig
package is identified by what it holds. `fluxion-math` and `fluxion-id` are
pinned where `fluxion-rhi` pins them; another commit would be two copies of
one library and a compiler message reading
`expected type 'proj.Clip', found 'proj.Clip'`. The same goes for
`fluxion-jobs`, which this package never names: `fluxion-physics` pins it
where `fluxion-ecs` does, so a step runs on the scheduler `app.jobs` already
is. And the two renderers that draw with `fluxion-rhi` - fluxion-ui's and
fluxion-debugdraw's - are built here from their source with this package's
rhi, because one pins its own at a commit of its choosing and the other names
it by path.

## 👾 Examples

<table>
  <tr>
    <td width="50%"><img src=".github/images/pong.png" alt="pong: two bats, a ball, a dashed line down the middle and the score in small squares"></td>
    <td width="50%"><img src=".github/images/crates.png" alt="crates: a pile of crates, a ramp, a ball on a rod, a sensor basket with two balls in it and a red ray"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>pong</b> - <code>--frames 420 --capture</code> drew it</sub></td>
    <td align="center"><sub><b>crates</b> - <code>--frames 240 --capture</code> drew it</sub></td>
  </tr>
</table>

```bash
zig build example-pong                      # Direct3D 11 on Windows, OpenGL elsewhere
zig build example-pong -- --backend gl      # OpenGL on Windows too
zig build example-pong -- --frames 420 --capture pong.png
```

**`pong`** is two paddles, a ball, and a scoreboard made of the same sprites
as everything else. It is there to be read as much as played: the game's own
components are declared in that file and the engine has never heard of them,
which is the whole point of the arrangement.

```bash
zig build example-creatures
zig build example-creatures -- --frames 300 --capture creatures.png
```

**`creatures`** is the renderer's half: one sprite sheet, an `Animation` over
its cells, and fourteen creatures each made of five entities - a body, two
eyes, a shadow and a name - where only the body is ever moved. Arrows, WASD
or a controller's left stick steer the one with the ring, and so does holding
the left mouse button where it should go: that is `app.pointerInWorld()` at
work, through a camera that follows the creature and stops at the edge of the
field. Dragging with the right button locks the pointer and pulls the view
around. The line in the corner is a label parented to the *camera* and scaled
against its zoom: a heads-up display drawn by the 2D layer rather than by the
interface. The camera and the player are found by name -
`app.find("camera")` - rather than by a query that happens to match only one.
In both examples F11 fills the screen, and in `pong` a controller each drives
the bats.

Its sheet is `examples/atlas.png`, and the example is what drew it:
`-- --write-atlas examples/atlas.png` puts it back, so the one binary file the
code reads is one the code can account for. The screenshots on this page are
accounted for the same way: each is what its example's `--capture` wrote.

```bash
zig build example-crates
zig build example-crates -- --frames 240 --capture crates.png
zig build example-crates -- --views on
```

**`crates`** is the physics: a floor, walls and a ramp that are colliders
with no body, a pile of crates, a ball on a rod from a pin, and a basket -
a sensor - that counts what falls into it from `app.contactsBegun()` and
`contactsEnded()`. Nothing in it makes a body. Left click drops a crate,
right click a ball, and space writes a velocity into every crate at once;
the red line is `app.castRay`, stopped at whatever crosses it first. F3 -
or `--views on` - turns on the colliders, bodies and stats debug views.

## ✅ What is here, and what is not

Here, and checked by the tests:

- The loop, the seven stages, the fixed step and its backlog, and
  `time.delta` that is the step inside it.
- Commands: spawn, despawn, add and remove asked for from inside a query -
  from parallel workers too - and done in order when the system returns.
- States: enums with one value at a time, changed between frames; systems in
  a state or under a condition of the game's own; systems run on entering
  and leaving; code gated by a state it has never heard of; and a paused
  clock moved on by one step.
- Events of any type, sent from inside a query and read once by each
  reader over the two frames they live.
- Signals on components:
  - connections to methods by name or to Zig functions, heard when the
    emitting system returns or, deferred, at the end of the frame;
  - flags, unbinds and binds;
  - loops stopped, failures counted, and the dead let go;
  - everything by name for an editor;
  - connections kept in scenes, including ones this build does not know.
- Keyboard and mouse as levels and edges, with typing kept in order, and
  edges that a fixed step hears exactly once.
- Controls as data: an `AxisBinding` holds two keys, a second two, a stick
  and a d-pad, lives in a component and saves with the world.
- Actions: named in the project, their edges their own, strengths past a
  dead zone, held from code, rebound and kept in the player's own file, and
  the interface moved by six built-in ones.
- A timer as a component, with `timeout` and `app.createTimer`;
  `app.single` for the component there is
  one of, and engine shortcuts for quitting and fullscreen, off unless asked
  for.
- Names that belong to the entity rather than to a component:
  `app.setName`, `app.find` and `app.nameOf`, unique among siblings, found by
  a path of them, and free again the moment their entity dies; and groups, one
  entity in any number, called together.
- The engine's command-line flags, read into a struct by name with room for
  a game's own, and captures that are the same picture on every machine.
- Controllers: sixteen slots, levels and edges, round dead zones, any pad or
  one pad, and SDL mappings for the ones the system does not know.
- The pointer in world coordinates, through the camera; locked, confined or
  hidden, and let go whenever the window loses the keyboard.
- Fullscreen - borderless, or exclusive at a chosen mode - on whichever
  monitor the window is on, at `create` or at any time after, and a no-op
  without a window.
- The window changed while it runs: title, size, position, size limits,
  maximised and minimised, and `resized` for the frame the size changed in.
- The system clipboard, for the interface's copy and paste and for the
  game's own - `setClipboardText`, `clipboardText`, `hasClipboardText` - and
  the program's own clipboard when there is no window.
- The system's file and folder dialogs, `openFileDialog` and
  `openFolderDialog`, answered in `app.input` a frame or more later, and
  answered by a test when there is no window.
- Files dropped on the window, with where they were let go, in `app.input`
  for a frame.
- The interface at the display's scale, followed from monitor to monitor,
  under a game's own zoom; the platform's text input switched with its focus,
  for a phone's soft keyboard and an input method composing at the caret;
  and the wheel scrolling the lines, or the page, the system is set to.
- The background on a phone or a page: a frame to save in, nothing run or
  drawn until the program is back, and the system's call for memory.
- Frame pacing: vsync switched while running, a frame cap that holds its
  average, and a minimised window that sleeps instead of drawing.
- A pause that stops what did not ask to run - systems, scripts and their
  tasks, timers, animation, controls, the pointer and the physics - with
  `Processing` inherited down the tree, and an `Appearance` that hides,
  colours and raises everything under it.
- Every system timed, under the name it was added with: its time over the
  last frame, and the whole schedule printable with `{f}`.
- Textures loaded from PNG, handed out as generational handles, and a white
  texel for everything untextured.
- The 2D pass: transforms, regions, tints, pivots, layers, order within a
  layer, visibility, additive blending, textures that repeat, interpolation
  between fixed steps, and a camera with zoom, rotation and an area it always
  fits to the window.
- One tree of every entity through `Parent`, whatever the entity is: placing
  resolved where it is needed rather than cached into a second component, the
  families in an index built again when the world changes shape, and what
  hangs from something taken down with it.
- Sprite animation over a sheet, looping or one-shot.
- Text: a shelf-packed glyph atlas per font, kerning, several lines, three
  alignments, and a label that formats into itself. Not here yet: wrapping, an
  outline, more than sixty-three bytes in one label, and more than one font in
  one label.
- Fonts from a `.ttf`, an `.otf`, or one font of a `.ttc` collection, and
  the system's own interface font and its monospaced one, as the system
  names them.
- Culling against the camera, sprites and labels alike.
- Tile maps: four-byte cells turned and flipped, in chunks found through an
  index, written compactly in scenes; `.tileset` files with sheets, shapes
  the physics stops at, probabilities and data layers asked for from Zig and
  from Flux.
- Controls as components, laid out into the interface with containers and
  signals, and drawn from `.theme` files: types, variations,
  states, base themes, a project theme under all and a control's own
  overrides over them.
- The interface: fluxion-ui laid out by `.ui` systems into one root, drawn
  over the 2D layer, fed from the keyboard, the mouse and the pads before the
  game's systems, keeping the wheel it used, and setting the pointer's shape;
  up to sixteen fonts, a run measured and drawn in the one its style names.
- Debug drawing: lines, shapes and text over the world or in screen pixels,
  for a frame, for some seconds, or until the next fixed step; views of
  colliders, bodies, transforms, sprites, cameras and frame stats the engine
  draws itself; one switch for all of it, and a key for the switch.
- Physics: bodies and colliders as components, made, changed and taken away
  with them; boxes and circles sized by their sprites; compound bodies from
  children; places and speeds written back after each step; contacts once per
  frame or per step; rays, points and boxes asked in entities.
- Areas: what is in a place - the eight overlap signals,
  the shapes forced to sensors, the asking side's mask deciding who is
  told, monitoring turned off and on again, and the six questions.
- Picking: what the pointer is on and what it did there -
  `input_event`, `mouse_entered` and their shape pairs, the topmost first,
  a handler that stops the rest, hover worked out every frame, and the
  pointer's own events with the wheel as buttons.
- The pointer itself: its speed, a warp, a point in an entity's own space,
  double clicks the system counted, every cursor mode and shape, a cursor
  picture of the game's own, and the window's icon.
- A phone's safe area, kept out of by the interface.
- Scenes: the world, its names, its UUIDs and every registered component
  written as JSON or CBOR and read back, with entity references by UUID -
  inside the scene first, then in the world - textures and fonts found again
  by their `.uid` files or their `res://` paths, and a mistake reported at
  its line and column rather than crashing - nor do the frames after a
  scene of NaNs and zeroes.
- The project's files: `res://` paths from a root the program can be started
  away from, `uid://` for a file by the UUID beside it, files moved with
  their `.uid` files found where they went, and entities' UUIDs kept beside
  the world as names are.
- The player's own files under `user://`, written whole or not at all, a
  `ConfigFile` of sections that keeps what it does not know, and scripts
  that save there and reach nowhere else.
- Files moved, copied and thrown away as an editor does it: UUIDs moved
  along and copies given their own, what was loaded following its file, the
  system's trash, and textures and fonts read again in place when their
  files change.
- `project.fluxion`: sections of settings as plain structs, read and
  written by one generic reader that writes only what differs and keeps what
  it does not know; read with no App for a project manager, read by every
  game as it starts - its window, clear colour, fixed step and icon - and its
  renderer choosing the backend - Direct3D 11 first on Windows - with
  `--backend` still over it.
- Reflection: every component described - fields, defaults, ranges, units -
  and found on an entity by its scene name, read and written in place, added
  and taken off; the engine's calls and a game's states made by name, errors
  and all.
- Flux scripts on entities: `ready`, `physics`, `update` and `exit`,
  `self.entity` and its components found again at each use, a budget and a
  log for what goes wrong, code read again into running instances, scripts
  in scenes, and an editor's checking set up as the game's.
- The world drawn into a texture through a view of its own, and a window
  that shows only the interface: an editor's scene panel, or a minimap.
- Headless everything, and `capture` for a picture without a screen.

## 🧭 What comes next

In order, and the order is an argument rather than a wish list: each of these
either unblocks the one after it or is the thing most missed by somebody
trying to finish a game with what is here.

### 1. Interface anchored to the world

The layer is here. What a game's interface still wants from fluxion-ui is
interface floating over a point in the world - health bars, name plates -
which needs an id scope so forty of them can share one declaration, state per
element so a menu can animate, and nine-slice pictures.

### 2. The 3D pass

Meshes, a depth attachment, a `Camera3D`, and the pass drawn before the 2D one
into the same target. The place it goes is marked in `App.drawLayers`, and
`fluxion-rhi` has had depth states, cull modes and depth attachments since
before this package existed - the seam was cut for it deliberately.

## 💭 Not on the list yet

- **Audio.** There is no `fluxion-audio`, and it is a library and a set of
  platform backends rather than an afternoon in this repository.
- **Resources** - a typed store for state that is not a component. A singleton
  entity is the answer today - `app.single(Score)` finds it - it saves and
  loads with the world for free, and the case for a second mechanism has not
  been made.
- **Parallel systems.** Work inside a system already goes on every core
  through `Query.each`; running two whole systems at once needs each to
  declare what it touches, which is a change to what a system *is* and should
  wait until there is a game slow enough to want it.
- **Hot reload**, which is what [Fluxion VFS](https://github.com/kisstp2006/fluxion-vfs)
  is for and is not wired up.
- **An editor.** A separate program one licence tier up, `fluxion-editor`,
  begun on the interface layer; what it needs from here is its own list.

## 🧩 What counts as a component

`Parent`, `Processing` and `Appearance`, which every entity may have. In 2D: `Transform2D`, `Sprite`,
`Text2D`, `Animation`, `Camera2D`, `RigidBody2D`, `Collider2D`, `Area2D` and
`TileMap`; `Timer`; and the interface's `Control` with what goes beside it -
see [Controls and themes](#-controls-and-themes). Each one is something a
person making a game would name, which is the test. A map's chunks are
entities of the engine's own, which a scene never writes.

`Parent` is on the list because what something hangs from is not a
transform's business alone: a timer, a sound or a control belongs somewhere
in the tree too, with no transform, and one link for all of them is one tree
rather than one for things in the world and another for the interface.
`Previous2D` is not on it: it held where something was a step ago, which is
the engine's own bookkeeping and a game should never have to declare, so it
is a flag on the transform and a table beside the world.

The rule that falls out: **a component is a thing, not a mechanism.** If it
exists so that the engine can do its job rather than so that the game can say
what something is, it belongs inside another component or beside the world.

**A name is not a component either.** It is what an entity is called rather
than something it has, so the engine keeps it beside the world, the way it
keeps where things were a step ago:

```zig
fn spawn(app: *fx.App) !void {
    const camera = try app.world.spawnWith(.{ fx.Transform2D.at(0, 0), fx.Camera2D{} });
    try app.setName(camera, "camera");
}

fn pan(app: *fx.App) !void {
    const camera = app.find("camera") orelse return;
    const place = app.world.get(camera, fx.Transform2D) orelse return;
    place.x += app.input.axisOf(.keys(.left, .right)) * 200 * app.time.delta;
}
```

Naming something does not move it into another table or change which queries
match it. A name picks out one child of a parent - a sibling with it already
is `error.NameTaken` - so a path of names leads to one thing, and two copies
of a scene keep the names inside them. Many things of one kind are a component and a
query; a name is for the camera, the player, the door to the next room.

**Nor is a body's handle.** `RigidBody2D` says that something falls and
how, and `Collider2D` what shape it is - what a game means. The body
`fluxion-physics` makes from them is the engine's business, so its handle is
kept beside the world with the names, and the components stay what a scene
can write down and an inspector can show.

## 🪤 Two things that will catch you once

**Writing a texture back out as a PNG drops its alpha.** `fluxion-image`'s
`Options.keep_alpha` defaults to false, because a screenshot has no alpha
worth keeping and a texture has nothing but. A sheet written without it draws
as a row of black squares, which is exactly what it looks like.

**A component may not contain a `packed struct`.** Not by rule - by accident:
`fluxion-ecs` walks a component's fields by pointer to remap entities, and a
field of a packed struct cannot have an ordinary pointer taken to it, so it
fails to compile inside the ECS with a message about pointer host sizes. It is
one line to fix there (skip packed layouts, which cannot hold an `Entity`
anyway); until then, this package's `TextureHandle` is an `extern struct` for
that reason and a game's components should be too.

## 📜 Licence

BSD-3-Clause. Tier four of [the ladder](../licensing/README.md): the same as
`fluxion-ecs`, one rung above the subsystems it is built from, and one below
the editor.
