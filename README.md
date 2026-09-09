# Fluxion Engine

A window, a world, and the loop between them. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `App` | The frame: what it owns, and the order it does things in. |
| `schedule` | When a game's systems run. |
| `components` | What the renderer knows how to read. |
| `assets` | What the GPU is holding, and the handles that name it. |
| `Input` | What the keyboard and the mouse did. |
| `Time` | How long the last frame took, and the fixed step. |
| `color` | A colour, and the three ways to write one down. |
| `Window` | The window and the event queue. |
| `render.sprite` | The 2D layer, in one instanced draw per texture. |
| `text.Atlas` | Every glyph the game has drawn, in one texture. |
| `hierarchy` | Where a thing really is, once its parent has had its say. |

```zig
const fx = @import("fluxion_engine");

pub fn main(init: std.process.Init) !void {
    const app = try fx.App.create(init.gpa, .{ .title = "game", .io = init.io });
    defer app.destroy();

    try app.addSystem(.startup, spawn);
    try app.addSystem(.fixed, move);
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
            place.x += app.input.axis(.a, .d) * 200 * app.time.fixed_delta;
        }
    }
}
```

**A scene is a world, and a node is an entity.** The shape is Godot's - open a
window, put things in a scene, give them behaviour, draw - and the thing in
the middle is an ECS rather than a tree of objects with virtual methods on
them. Everything of one shape lives in one table, so a system is a loop over
plain slices with no branch in it asking what this one is. That is
[Fluxion ECS](https://github.com/kisstp2006/fluxion-ecs)' doing, not this
package's; what this package adds is the frame around it.

## Three layers, one target

3D first with a depth test, then 2D blended with none, then the interface on
top of both, each its own render pass into the same surface. The first pass
clears and the rest load what the one before them left, which is the whole of
what layering costs - no extra textures, no compositing pass.

Today **the 2D layer is the only one written**. The 3D pass has its place in
`App.render` and nothing in it. The interface layer is waiting on one argument
in `fluxion-ui`: its renderer opens its pass with the load operation left at
`.clear`, so it can only ever be the *first* thing in a target - draw a scene
and then an interface, and the interface wipes the scene. A `clear: ?Color`
that loads when it is null is the whole of the change, and a `Color` coerces to
the optional on its own, so no existing caller reads any differently.

## The frame

Seven stages, and the list is the frame in order:

| Stage | When, and what belongs there |
| --- | --- |
| `startup` | Once, before the first frame. Spawn the world. |
| `input` | After the events are in. Turn keys into intent. |
| `fixed` | Zero or more times, at a constant delta. Physics. |
| `update` | Once, at whatever the frame took. Everything else. |
| `late` | After `update`, before anything is drawn. Cameras follow here. |
| `ui` | Inside the interface's own frame. Not wired up yet. |
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

## The 2D layer

One quad in a vertex buffer and a second buffer stepping once per instance
with where each sprite goes, how big, which way round, what colour and which
part of which texture. A thousand sprites sharing a texture is one draw call.

```zig
_ = try world.spawnWith(.{
    fx.Transform2D{ .x = 100, .y = 80, .rotation = 0.4 },
    fx.Sprite{ .texture = hero, .region = .cell(2, 4, 1), .layer = 5 },
});
```

- **Sorted back to front, blended, with no depth test.** A depth buffer and
  half-transparent pixels disagree about what is behind what. The sort is by
  `layer`, then `order`, then texture, then the order the sprites were found
  in - so sprites of one layer sharing a texture come out as one run and
  therefore one call, and two overlapping sprites that tie on everything are
  drawn the same way round every frame.
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
- **A transform's `parent` attaches one entity to another**, so a turret rides
  on a tank and a health bar rides over an enemy. The numbers in a transform
  are *local* - in the parent's space, and in the world's only when there is
  no parent - which is Unity's `Transform` and Godot's `Node2D`.
  `app.worldTransform(entity)` is the other one, and it costs a walk up the
  chain rather than a field read. `inherit_rotation = false` is the shadow
  that does not tip over.
- **An `Animation` is a sheet and a rate**, and the engine writes the cell it
  lands on into `Sprite.region` once a frame. One sheet holds a walk, an idle
  and an attack; swapping between them is writing two numbers.
- **A `Text2D` is words at a transform**, drawn through the same pass as
  everything else: each glyph is a quad out of a glyph atlas, so a label sorts
  against sprites by the same `layer` and `order` and all the text in one font
  is one draw call. The text lives *in* the component, in a fixed buffer, and
  `label.print("{d} points", .{score})` is what a game actually does with it.
- **What the camera cannot see is dropped before it costs anything**, one
  comparison per sprite, which is the difference between a renderer that costs
  what is drawn and one that costs what exists.
- **The camera is an entity** with a `Transform2D` and a `Camera2D`, and its
  position is the *centre* of the view. With no camera in the world at all,
  the origin is the top left corner and one unit is one pixel - the same
  coordinate system the interface layer uses, so a game that has not thought
  about cameras yet can lay things out in screen coordinates.
- **The shader is written once**, in
  [Fluxion Shader](https://github.com/kisstp2006/fluxion-shader)'s language,
  and comes out as GLSL and as HLSL. Two hand-written copies would drift, and
  the drift shows up as one backend drawing correctly and the other not.

## It runs with no window and no GPU

```zig
const app = try fx.App.create(gpa, .{ .headless = true, .frames = 60 });
```

The `none` backend accepts every call and draws none of them, the frame goes
into a texture instead of a swapchain image, and the clock advances by a fixed
amount whether or not any time passed. Every test in this package runs that
way, which is why `zig build test` passes on a machine with no display.

For a picture on such a machine, `app.capture(gpa, w, h)` draws one frame into
a texture of its own and hands back the pixels - the same passes, somewhere
else. `zig build example-pong -- --frames 420 --capture out.png` is that, and
it is how the screenshot in a pull request gets made.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-engine
```

```zig
const fluxion = b.dependency("fluxion_engine", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_engine", fluxion.module("fluxion_engine"));
```

Seven dependencies come with it and **none of them is lazy**, which is the
difference between an engine and the libraries under it. A library keeps its
window and its file reading behind `lazy` so a consumer never downloads what
it does not use; an engine uses all of it by definition.

[ECS](https://github.com/kisstp2006/fluxion-ecs) ·
[RHI](https://github.com/kisstp2006/fluxion-rhi) ·
[Platform](https://github.com/kisstp2006/fluxion-platform) ·
[Shader](https://github.com/kisstp2006/fluxion-shader) ·
[Image](https://github.com/kisstp2006/fluxion-image) ·
[Math](https://github.com/kisstp2006/fluxion-math) ·
[Id](https://github.com/kisstp2006/fluxion-id)

**`fluxion-math` and `fluxion-id` are pinned rather than pathed**, and they
have to be: `Device.clip()` returns a `math.Clip` and `math.orthographic`
takes one, so the two must be the *same* type - and a Zig package is
identified by where it came from. A path here and a pin inside `fluxion-rhi`
makes two copies of one library and a compiler message reading
`expected type 'proj.Clip', found 'proj.Clip'`.

## Examples

```bash
zig build example-pong
zig build example-pong -- --backend d3d11
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
eyes, a shadow and a name - where only the body is ever moved. Arrows or WASD
steer the one with the ring; the camera follows it and stops at the edge of
the field. The line in the corner is a label parented to the *camera* and
scaled against its zoom, which is the whole of what a heads-up display is
until the interface layer arrives.

Its sheet is `examples/atlas.png`, and the example is what drew it:
`-- --write-atlas examples/atlas.png` puts it back, so the one binary file in
this repository is one the code can account for.

## What is here, and what is not

Here, and checked by the tests:

- The loop, the seven stages, the fixed step and its backlog.
- Keyboard and mouse as levels and edges, with typing kept in order.
- Textures loaded from PNG, handed out as generational handles, and a white
  texel for everything untextured.
- The 2D pass: transforms, regions, tints, pivots, layers, order within a
  layer, visibility, interpolation between fixed steps, and a camera with
  zoom and rotation.
- Parenting, one entity to another, resolved where it is needed rather than
  cached into a second component.
- Sprite animation over a sheet, looping or one-shot.
- Text: a shelf-packed glyph atlas per font, kerning, several lines, three
  alignments, and a label that formats into itself. Not here yet: wrapping, an
  outline, more than sixty-three bytes in one label, and more than one font in
  one label.
- Culling against the camera, sprites and labels alike.
- Headless everything, and `capture` for a picture without a screen.

## What comes next

In order, and the order is an argument rather than a wish list: each of these
either unblocks the one after it or is the thing most missed by somebody
trying to finish a game with what is here.

### 1. Things touching other things

`pong` works out where its ball is with eight lines of arithmetic, which is
the honest amount for a game that size. A bigger one needs the engine to
answer three questions: what is at this point, what does this box overlap, and
what does this ray hit first.

That is a `Collider2D` component - a box or a circle - a uniform grid to sort
them into so the answer is not every pair, and three functions on `App`. Not a
physics engine: no solver, no restitution, no joints. A game that wants those
can build them on the queries, and most 2D games only ever wanted the
queries.

### 2. Controls a player can change

The keys are written into the game today - `pong` puts them in a component,
which is better than most and still means the game knows what a key is. What
belongs in the engine is an action map: a name, the keys and buttons and stick
axes bound to it, and `input.action("jump")`. `fluxion-platform` already reads
gamepads and this engine ignores them entirely, which is the other half of the
same job.

### 3. A world that survives being closed

`fluxion-ecs` writes a world to bytes and reads it back, and the engine does
not offer it. The one real problem is that a `TextureHandle` means nothing in
the next process: saving has to write the *name* a texture was loaded from and
loading has to resolve it again, which means the asset table has to remember
its own paths. Everything else is two calls.

### 4. Tilemaps

A `Tilemap` component holding a grid of indices into one sheet, drawn in
chunks so a level larger than the screen is a handful of instanced draws
rather than one per tile. It wants nothing that is not already here, and it is
what makes the difference between demonstrations and levels.

### 5. The interface layer

One argument away in `fluxion-ui` - see the note under "Three layers, one
target" - and then the things a game's interface wants that an application's
does not: a frame-level "did the interface take this click", focus that moves
with a d-pad, interface anchored to a point in the world, per-element state so
a menu can animate, and pictures on elements rather than only rounded
rectangles.

### 6. The 3D pass

Meshes, a depth attachment, a `Camera3D`, and the pass drawn before the 2D one
into the same target. The place it goes is marked in `App.render`, and
`fluxion-rhi` has had depth states, cull modes and depth attachments since
before this package existed - the seam was cut for it deliberately.

## Not on the list yet

- **Audio.** There is no `fluxion-audio`, and it is a library and a set of
  platform backends rather than an afternoon in this repository.
- **Resources** - a typed store for state that is not a component. A singleton
  entity is the answer today, it saves and loads with the world for free, and
  the case for a second mechanism has not been made.
- **Parallel systems.** Work inside a system already goes on every core
  through `Query.each`; running two whole systems at once needs each to
  declare what it touches, which is a change to what a system *is* and should
  wait until there is a game slow enough to want it.
- **Hot reload**, which is what [Fluxion VFS](https://github.com/kisstp2006/fluxion-vfs)
  is for and is not wired up.
- **An editor.** A separate program, one licence tier up, and a long way
  after all of the above.

### Two things that will catch you once

**Writing a texture back out as a PNG drops its alpha.** `fluxion-image`'s
`Options.keep_alpha` defaults to false, because a screenshot has no alpha
worth keeping and a texture has nothing but. A sheet written without it draws
as a row of black squares, which is exactly what it looks like.

### What counts as a component

Five: `Transform2D`, `Sprite`, `Text2D`, `Animation` and `Camera2D`. Each one
is something a person making a game would name, which is the test.

Two things that used to be on that list are not any more, and the reason is
the same for both. `Parent` was a component holding a link and an offset; it
is a field of `Transform2D` now, because parenting is what a transform *does*
- Unity puts it on `Transform`, Godot puts it in the tree - and nobody
building a scene thinks "I will add a Parent to this". `Previous2D` held where
something was a step ago; that is the engine's own bookkeeping and a game
should never have to declare it, so it is a flag on the transform and a table
beside the world.

The rule that falls out: **a component is a thing, not a mechanism.** If it
exists so that the engine can do its job rather than so that the game can say
what something is, it belongs inside another component or beside the world.

### One thing to know about components

A component may not contain a `packed struct`. Not by rule - by accident:
`fluxion-ecs` walks a component's fields by pointer to remap entities, and a
field of a packed struct cannot have an ordinary pointer taken to it, so it
fails to compile inside the ECS with a message about pointer host sizes. It is
one line to fix there (skip packed layouts, which cannot hold an `Entity`
anyway); until then, this package's `TextureHandle` is an `extern struct` for
that reason and a game's components should be too.

## Licence

BSD-3-Clause. Tier four of [the ladder](../licensing/README.md): the same as
`fluxion-ecs`, one rung above the subsystems it is built from, and one below
the editor.
