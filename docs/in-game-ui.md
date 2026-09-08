# In-game UI: what the interface layer needs

Fluxion UI lays out beautifully and its renderer draws a whole window of
interface in one instanced call. What it is missing is not quality - it is the
handful of things that separate *an application's interface* from *a game's*.

This is that list, written from the engine side, in the order it blocks work.
Everything marked **UI** is a change in `fluxion-ui`; everything marked
**engine** is this repository's own job and is waiting on the UI half.

---

## 0. The blocker: draw on top of a frame, not instead of it

**UI. One argument. Nothing else on this page can be tested until this is
done.**

`render/rhi.zig`'s `draw` opens its pass with the load operation left at its
default, which is `.clear`:

```zig
try list.beginPass(.{ .color = .{
    .target = target,
    .clear_color = clear.array(),
} });
```

So the interface can only ever be the **first** thing in a target. Draw a
scene and then an interface, and the interface wipes the scene. The engine
composes 3D, then 2D, then interface into one surface, so as things stand the
third layer cannot exist.

The fix is two lines, and no existing caller changes - a `Color` coerces to
`?Color` on its own:

```zig
    pub fn draw(
        self: *Renderer,
        target: rhi.types.RenderTarget,
        size: ui.Dimensions,
        commands: []const ui.RenderCommand,
-       clear: ui.Color,
+       clear: ?ui.Color,
    ) Error!void {
...
        try list.beginPass(.{ .color = .{
            .target = target,
-           .clear_color = clear.array(),
+           .load = if (clear == null) .load else .clear,
+           .clear_color = if (clear) |colour| colour.array() else .{ 0, 0, 0, 1 },
        } });
```

**The better version, when there is time**: split `draw` into `build` (which
is already public) and `record(list: *rhi.CommandList)`, and let the caller
own the pass. Then the engine can put the interface's draws *inside* the same
pass as the 2D layer rather than opening a second one, and a future editor can
put interface into a pass it is already recording. `draw` stays as the
convenience that opens a pass and calls both.

## 1. Does the interface want this click?

**UI. Small, and the second thing a game hits.**

A game clicks to shoot. An interface clicks to press a button. When a button
is under the cursor, exactly one of those should happen - and today the game
has no way to ask.

```zig
ui.wantsPointer()    // the cursor is over something that would take a click
ui.wantsKeyboard()   // a text field has focus, so W does not mean "walk"
```

Dear ImGui calls these `WantCaptureMouse` and `WantCaptureKeyboard`, and every
program that embeds an interface into a game needs both. The information is
already there - `pointerOver` returns the elements under the cursor and
`isFocused` knows about the caret - it just is not asked as one question about
the frame.

The engine's side: `App` reads them after the `.ui` stage and before the
`.input` stage of the *next* frame, so a game system can simply say
`if (app.ui.wantsPointer()) return;`.

## 2. Interface anchored to things in the world

**UI, and the biggest one. Health bars, name plates, damage numbers,
interaction prompts.**

This is the difference in kind. An application's interface is one tree the
size of the window. A game's is that *plus* forty small trees, each floating
over something that is moving.

Two things are needed:

**A transform on the frame, not a viewport.** The renderer's `Frame` uniform
is `viewport: [4]f32` and the shader turns pixels into clip space with it. If
that were a `mat4` instead, the caller could hand it any transform - screen
space (what it does now), a world position projected to the screen, or a
billboard in a 3D scene later. The shader change is one line; the API change
is `draw` taking an optional matrix.

**More than one tree per frame.** `Ui.begin`/`end` is one tree, and the
retained state - scroll positions, focus, hover - is keyed by element name
across the whole `Ui`. Forty health bars declaring an element called `"bar"`
would collide.

Two ways out, and the first is probably right:

- **A push/pop of an id scope**: `ui.pushScope(entity.toInt())` … `popScope()`,
  mixed into the element hash. Cheap, no extra allocation, and it is what
  every immediate-mode interface does.
- Or an explicit `ui.root(.{ .transform = m, .id = scope })` that opens a
  second tree inside one frame, so one `end` returns all of them with their
  transforms attached.

The engine's side: a `WorldUi` component naming a system to declare it, and
the engine projecting the entity's transform through the 2D camera before
handing the matrix over. Cheap to write once the above exists.

## 3. Focus that moves with a stick

**UI. What makes it playable on a pad or on a handheld.**

Fluxion UI's focus is a text-field concept and its hit testing is a pointer
concept. A game interface has to be operable with nothing but a d-pad:

```zig
.focusable = true,                    // on the declaration
ui.moveFocus(.down);                  // to the nearest focusable that way
ui.activate();                        // press whatever has focus
ui.focusedElement();                  // for the game to draw a highlight
```

"Nearest that way" is the whole of the problem, and the answer that works is
the one every console interface uses: among the focusable boxes whose centre
lies in the 90-degree cone in that direction, take the one with the smallest
distance, weighting the off-axis component heavily so a box directly below
beats one that is nearer but off to the side. It is about forty lines over the
boxes the layout has already computed.

Also needed: `ui.setFocusVisible(bool)`, so the highlight appears when the pad
is used and disappears when the mouse moves - which is what a player expects
and what every toolkit gets wrong first.

## 4. Elements that can be pictures

**UI, and the one with a real cost in the renderer.**

A game's interface is not rounded rectangles. It is a panel with a carved
metal border, a health bar with a gradient, an item icon in a slot.

```zig
ui.open(.{
    .background_image = .{ .texture = panel, .region = .{ ... } },
    // Nine-slice: the corners keep their size, the edges stretch, the middle
    // fills. Without it every panel needs artwork at its exact size.
    .nine_slice = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
});
```

The cost is that the renderer currently binds exactly one texture - the glyph
atlas - and therefore never breaks its batch except on a scissor. Images mean
either:

- **one texture per interface** (the game packs its interface art and its
  glyphs into one atlas, and the renderer takes the atlas from outside rather
  than owning it), which keeps one draw call and pushes the packing onto the
  game; or
- **a batch break per texture change**, sorted so that identical textures are
  adjacent, which is what the engine's sprite renderer already does.

The first is better for a game and needs the atlas to be an argument rather
than a private field. The engine can supply it: it already owns
`assets.Assets` and could hand over a texture the interface writes its glyphs
into.

## 5. Text that a game can read

**UI. Three separate things, in order of how much they are missed.**

1. **An outline or a shadow.** Text over a bright scene is unreadable without
   one, and every game has one. It is a per-style field
   (`.outline = .{ .color = ..., .width = 2 }`) and, in the shader, either a
   second draw offset by a pixel in eight directions - cheap and ugly - or a
   signed-distance-field atlas, which is the right answer and a bigger change
   to `fluxion-font`.
2. **More than one face.** A title font and a body font is the minimum, and
   the measurer is one function pointer holding one `*font.Font`. A
   `.font = .title` on the style, and a small table of faces in the renderer,
   covers it.
3. **A number that does not reflow the layout.** A score counting up from 0 to
   1000 changes width every frame and shoves everything beside it. Either
   tabular figures from the font, or a `.min_width` on text - the second is
   two lines and works with any font.

## 6. Interface that scales

**UI, small.** `Ui.begin(.init(width, height))` takes pixels. A game running
at 3840 by 2160 wants its interface twice the size, not twice as much of it,
and a game on a television needs to keep clear of the edges.

```zig
ui.begin(.{ .size = .init(w, h), .scale = 2.0, .safe_area = .all(48) });
```

`scale` multiplies every fixed size, padding, gap, corner radius and font
size; `safe_area` insets the root. Both are arithmetic at the top of the
layout, and doing it there rather than in the game is what stops every game
writing its own multiplication and getting the font sizes wrong.

## 7. An escape hatch in the command list

**UI, tiny, and it unlocks a lot.** One more variant:

```zig
pub const RenderCommand = union(enum) {
    // ... rectangle, border, text, scissor ...
    /// The layout worked out where this goes; what goes in it is the
    /// caller's business.
    custom: struct { id: u64, box: BoundingBox },
};
```

A minimap, a character portrait rendered from the 3D scene, a video, a
particle preview - all of them are "put my own drawing in this rectangle, in
the right order, clipped by the right scissor". Without it, an interface can
only ever contain what the interface library knows how to draw.

## 8. Smaller things, each worth a line

| What | Why |
| --- | --- |
| `tick` in seconds, not frames | `hide_after_frames` on a scrollbar is wrong at any frame rate but the one it was tuned at. The engine already has `Time.delta`; the layout should take seconds. |
| Wheel to whatever is under the pointer | `scrollBy` takes an element name, so a game with two lists has to work out which one is hovered. `ui.scrollHovered(dx, dy)` is the call every program actually wants. |
| A requested cursor shape | An interface knows when the pointer is over a text field or a resize handle. `ui.cursor()` returning a `platform.CursorShape` lets the engine set it. |
| Clipboard in and out | `textAction(.copy)` hands back the text and `.paste` takes it, which is right - the engine should wire both to the platform. That is the engine's job and is listed here so it is not forgotten. |
| A tooltip that survives the frame | Anything that appears after a hover delay needs per-element time, which is item 9. |

## 9. Per-element state that outlives a frame

**UI. The one that turns a static interface into a moving one.**

The README is explicit that the scroll position is "the one piece of state
that outlives a frame", and that is the right instinct - a layout should be a
pure function of its declaration. But a game interface animates: menus slide
in, buttons swell when pressed, a health bar catches up with the number behind
it, a damage figure floats and fades.

The smallest thing that covers all of it:

```zig
/// Somewhere to keep a number between frames, per element, for as long as
/// the element keeps being declared. Forgotten when it stops.
pub fn stateOf(self: *Ui, name: []const u8, comptime T: type) *T;
```

with the same lifetime rule the scroll position already has - kept while
declared, dropped when not. Hover fades, press scales, open and close
transitions and tooltip delays are all four lines on top of that, written by
the game rather than by the library.

---

## What is already right, and should not change

Worth writing down so that none of the above is taken as a reason to disturb
it:

- **The command list is the seam.** A layout that emits rectangles and knows
  nothing about a GPU is why any of this is possible, and why the engine can
  have its own renderer if it needs one.
- **`ui.text` copies its string.** A game formats a score into a stack buffer
  every frame. Borrowing would be a use-after-free in the first game anybody
  wrote.
- **Four pointer states rather than a boolean**, and `justReleased` as the one
  to hang a button on.
- **Answers are one frame old.** Every immediate-mode interface works this
  way; the alternative is two layout passes for something nobody notices.
- **Markup in the string.** `{color=red|Escape}` is exactly what a game's
  localised text needs, and it is already there.

## The order to do them in

1. **§0 compose over a scene** - two lines, unblocks the engine's third layer.
2. **§1 wants-pointer** - small, and every game hits it on day one.
3. **§8 tick in seconds** - one line, and it is a correctness bug today.
4. **§6 scale and safe area** - small, and painful to retrofit into games
   later.
5. **§5.1 text outline** - the difference between readable and not.
6. **§3 focus navigation** - the difference between playable on a pad and not.
7. **§9 per-element state** - unlocks all animation, written once.
8. **§4 images and nine-slice** - the biggest renderer change; worth doing
   after the atlas ownership question above is answered.
9. **§2 world-anchored trees** - the biggest design change, and the one that
   most wants the others to be settled first.
10. **§7 custom command** - tiny, and can land at any point.
