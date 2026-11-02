// A board opens where the person left it.
//
// The view (visible canvas rectangle) is kept per board in localStorage and put
// back through the handle's `fitBounds` once the layout has settled. What has
// to hold: it is restored before it is watched (the opening view is never
// saved as a choice), it is keyed by board, and nothing saved or unusable ever
// breaks the board.
//
//   node test/js/remember_view_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"),
  "utf8"
);
const start = src.indexOf("  const BoardSync = {");
const end = src.indexOf("\n  };", start);
const BoardSync = eval("(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")");

global.BoardLink = { close: () => {} };
const store = {};
global.localStorage = {
  getItem: (k) => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); }
};
const timers = [];
global.setTimeout = (fn) => { timers.push(fn); return timers.length; };
global.clearTimeout = () => {};
const windowEvents = {};
global.window = {
  addEventListener: (n, f) => { windowEvents[n] = f; },
  removeEventListener: (n) => { delete windowEvents[n]; }
};

function handle(bounds) {
  const listeners = {};
  const h = {
    bounds,
    fitted: [],
    getViewportBounds: () => h.bounds,
    fitBounds: (r) => { h.fitted.push(r); h.bounds = { ...r }; },
    whenLayoutSettled: () => Promise.resolve(),
    on: (n, f) => { listeners[n] = f; return () => delete listeners[n]; },
    fire: (n) => listeners[n] && listeners[n](),
    listeners
  };
  return h;
}

function hook(boardId, h) {
  const hk = Object.create(BoardSync);
  hk.frescoId = "board-canvas";
  hk.el = { dataset: { boardId } };
  window.Fresco = { onReady: (_id, cb) => cb(h) };
  hk.rememberView();
  return hk;
}

const tick = () => new Promise((r) => setImmediate(r));
const flush = () => { while (timers.length) timers.shift()(); };

(async () => {
  // Nothing saved: the opening view is left alone and not recorded.
  let h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  let hk = hook("b1", h);
  await tick();
  assert.deepStrictEqual(h.fitted, [], "no saved view, nothing to restore");
  flush();
  assert.strictEqual(store["phoenix_kit_boards:view:b1"], undefined, "the opening view is not a choice");

  // The person pans and zooms: saved after the debounce.
  h.bounds = { x: 500, y: 300, width: 250, height: 200 };
  h.fire("pan");
  assert.strictEqual(store["phoenix_kit_boards:view:b1"], undefined, "debounced, not saved per frame");
  flush();
  assert.deepStrictEqual(JSON.parse(store["phoenix_kit_boards:view:b1"]), { x: 500, y: 300, width: 250, height: 200 });

  // Back on the same board: put back where they were.
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hook("b1", h);
  await tick();
  assert.deepStrictEqual(h.fitted, [{ x: 500, y: 300, width: 250, height: 200 }]);

  // Another board is untouched by it.
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hook("b2", h);
  await tick();
  assert.deepStrictEqual(h.fitted, [], "views are per board");

  // Closing flushes what the debounce had not yet written.
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hk = hook("b3", h);
  await tick();
  h.bounds = { x: 10, y: 20, width: 30, height: 40 };
  h.fire("zoom");
  hk.destroyed();
  assert.deepStrictEqual(JSON.parse(store["phoenix_kit_boards:view:b3"]), { x: 10, y: 20, width: 30, height: 40 });
  assert.strictEqual(windowEvents.pagehide, undefined, "the pagehide listener is removed");

  // A hook torn down with the canvas already gone must not save a collapsed view.
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hk = hook("b4", h);
  await tick();
  h.bounds = { x: 5, y: 5, width: 0, height: 0 };
  hk.flushView();
  assert.strictEqual(store["phoenix_kit_boards:view:b4"], undefined, "a zero-size view is never saved");

  // Garbage in storage is ignored.
  store["phoenix_kit_boards:view:b5"] = "not json";
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hook("b5", h);
  await tick();
  assert.deepStrictEqual(h.fitted, []);
  store["phoenix_kit_boards:view:b6"] = JSON.stringify({ x: 1, y: 1, width: -5, height: 3 });
  h = handle({ x: 0, y: 0, width: 1000, height: 800 });
  hook("b6", h);
  await tick();
  assert.deepStrictEqual(h.fitted, []);

  // No board id (an old page), no Fresco: quietly nothing.
  const bare = Object.create(BoardSync);
  bare.el = { dataset: {} };
  bare.rememberView();

  console.log("remember_view: ok");
})().catch((e) => { console.error(e); process.exit(1); });
