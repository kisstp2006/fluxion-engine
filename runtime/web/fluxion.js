// SPDX-License-Identifier: BSD-1-Clause
//
// What a page runs a game exported for the web with: it downloads the game's
// module, its pack and a font, showing how far it has got, and runs the
// module on the canvas with the libraries' glues - the platform's, WebGL's,
// sound's and the network's - each in a file of its own beside this one.
//
// The page says what to run in a JSON script of its own, which the export
// writes:
//
//   <canvas id="fluxion-canvas"></canvas>
//   <script type="application/json" id="fluxion-game">
//     {"module": "Game.wasm", "pack": "Game.fxpack", "storage": "Game"}
//   </script>
//   <script type="module" src="fluxion.js"></script>
//
// `module` and `pack` are where the two are; `font` the font a game writes
// with when its theme names none (`fonts/NotoSans-Regular.ttf`); `emoji` the
// fonts it draws emoji with, the flags second, or none (`[]`); `storage`
// the name the player's own files are kept under in the browser; `args` more
// of the game's command line; `clickToStart` whether it waits for a press
// first. The page's own address - `?level=3` - is what the game's
// `pageParameter` reads.
//
// Optional, and found by their ids: `fluxion-overlay`, shown while it loads
// and when it ends or fails; `fluxion-done`, a bar whose width is how much has
// come; `fluxion-say`, where it says what it is doing.
//
// This file is under the BSD 1-Clause licence, as the runtime is.

import { Platform } from "./fluxion-platform.js";
import { Fluxion } from "./fluxion-webgl.js";
import { Audio } from "./fluxion-audio.js";
import { Net } from "./fluxion-net.js";

const config = JSON.parse(document.getElementById("fluxion-game")?.textContent || "{}");
const canvas = document.getElementById("fluxion-canvas");
const overlay = document.getElementById("fluxion-overlay");

function say(text) {
  const where = document.getElementById("fluxion-say");
  if (where) where.textContent = text;
}

function showOverlay(shown) {
  if (overlay) overlay.hidden = !shown;
}

/// How much of every download has come, as one bar.
class Progress {
  constructor() {
    this.sizes = new Map();
  }

  /// `total` is what the server said, 0 when it did not.
  update(url, received, total) {
    this.sizes.set(url, { received, total });
    let receivedAll = 0;
    let totalAll = 0;
    for (const size of this.sizes.values()) {
      receivedAll += size.received;
      totalAll += Math.max(size.total, size.received);
    }
    const bar = document.getElementById("fluxion-done");
    if (bar && totalAll > 0) bar.style.width = `${Math.min(100, (100 * receivedAll) / totalAll)}%`;
  }
}

/// The bytes at `url`, counted into `progress` as they come.
async function download(url, progress) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} did not come: ${response.status} ${response.statusText}`);
  const total = Number(response.headers.get("content-length") ?? 0);
  if (!response.body) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    progress.update(url, bytes.length, total);
    return bytes;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    progress.update(url, received, total);
  }
  const bytes = new Uint8Array(received);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.length;
  }
  return bytes;
}

/// A press of anything on the page.
function pressed() {
  return new Promise((resolve) => {
    const kinds = ["pointerdown", "keydown"];
    const once = () => {
      for (const kind of kinds) removeEventListener(kind, once, true);
      resolve();
    };
    for (const kind of kinds) addEventListener(kind, once, true);
  });
}

async function main() {
  if (!canvas) throw new Error("the page has no canvas with the id fluxion-canvas");
  if (config.clickToStart) {
    say("Click to start");
    await pressed();
  }
  say("Loading...");
  const progress = new Progress();
  const emojiFiles = config.emoji ?? ["fonts/NotoColorEmoji.ttf", "fonts/NotoColorEmojiFlags.ttf"];
  const [module, pack, font, ...emoji] = await Promise.all([
    download(config.module, progress),
    download(config.pack, progress),
    download(config.font ?? "fonts/NotoSans-Regular.ttf", progress),
    ...emojiFiles.map((url) => download(url, progress)),
  ]);

  say("Starting...");
  const platform = new Platform({
    canvas,
    args: ["game", "--pack", "/game.fxpack", ...(config.args ?? [])],
    env: Object.fromEntries(new URLSearchParams(location.search)),
    storage: config.storage ?? config.module,
  });
  platform.files.put("/game.fxpack", pack);
  platform.files.put("/fonts/ui.ttf", font);
  // Where the platform looks for the system's emoji fonts.
  emoji.forEach((bytes, at) => platform.files.put(at === 0 ? "/fonts/emoji.ttf" : "/fonts/emoji-flags.ttf", bytes));
  // The WebGL context first, on the canvas the platform's window is.
  const webgl = new Fluxion(canvas);
  await platform.instantiate(module, { with: [webgl, new Audio(), new Net()] });

  // `init` runs as `start` is called, before its first frame.
  const running = platform.start();
  showOverlay(false);
  canvas.focus();
  await running;
  say("The game has ended.");
  showOverlay(true);
}

main().catch((error) => {
  console.error(error);
  say(`The game did not run: ${error.message ?? error}`);
  showOverlay(true);
});
