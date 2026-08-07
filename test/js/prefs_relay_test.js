// Pins the host half of the preferences contract: carrying them between
// etcher and the server.
//
// Etcher emits every preference as a DOM event when any of them changes, and
// takes the whole set back through `setPrefs`. Everything between those two
// points belongs to the host — here, a user's custom_fields — and etcher
// knows nothing about it. Another host storing them in a cookie or a
// per-board row satisfies the same contract.
//
// Two things are worth guarding. The stored set arrives with the mount reply,
// which can beat etcher's own setup because it lazy-loads its script; dropping
// it there leaves the board on its defaults and the user watching their setup
// not apply. And an empty set has to mean "nothing stored" rather than
// "everything off", or a first-time user gets a board with no tools on it.
//
//   node test/js/prefs_relay_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"
);
const src = fs.readFileSync(SOURCE, "utf8");

const start = src.indexOf("  const BoardSync = {");
assert.notStrictEqual(start, -1, "could not find BoardSync");
const end = src.indexOf("\n  };", start);
assert.notStrictEqual(end, -1, "could not find the end of BoardSync");
const BoardSync = eval(
  "(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")"
);

// ── stand-ins ───────────────────────────────────────────────────────────────

let clockQueue = [];
global.setTimeout = (fn) => { clockQueue.push(fn); return clockQueue.length; };
global.clearTimeout = () => {};
const tick = () => { const q = clockQueue; clockQueue = []; q.forEach((fn) => fn()); };

function makeHook(layer) {
  const hook = Object.create(BoardSync);
  hook.frescoId = "board-canvas";
  hook.pushed = [];
  hook.handlers = {};
  hook.listeners = {};
  hook.el = {
    dataset: { frescoId: "board-canvas" },
    addEventListener(type, fn) { hook.listeners[type] = fn; },
    removeEventListener(type) { delete hook.listeners[type]; }
  };
  hook.pushEvent = (name, payload) => hook.pushed.push({ name, payload });
  hook.handleEvent = (name, fn) => { hook.handlers[name] = fn; };
  hook.layer = () => (typeof layer === "function" ? layer() : layer);
  return hook;
}

// `setPrefs` is what these checks are about; the rest is whatever else
// `mounted` reaches for on its way past, stubbed so it no-ops rather than
// throwing and taking the preferences path down with it.
function makeLayer() {
  return {
    received: [],
    setPrefs(p) { this.received.push(p); return true; },
    selectTool() {},
    getMode() { return true; },
    setMode() {},
    setImageUploader() {},
    setLinkUnfurler() {}
  };
}

// `mounted` does a great deal besides preferences; only the parts under test
// are stubbed, and the rest is allowed to no-op.
function mount(hook) {
  hook.pendingUploads = [];
  try { BoardSync.mounted.call(hook); } catch (_) {}
}

// ── changes go to the server ────────────────────────────────────────────────

{
  const hook = makeHook(makeLayer());
  mount(hook);
  assert.ok(hook.listeners["etcher:prefs-changed"], "listening for etcher's event");

  const prefs = { panel: "compact", grid: false, tools: ["line"] };
  hook.listeners["etcher:prefs-changed"]({ detail: prefs });

  const sent = hook.pushed.filter((p) => p.name === "etcher:prefs-changed");
  assert.strictEqual(sent.length, 1);
  // The WHOLE set, not a diff — the server stores it verbatim and the last
  // one to arrive is the answer, so there is nothing to reconcile.
  assert.deepStrictEqual(sent[0].payload, prefs);
}

// An event with nothing on it must still be a well-formed push rather than
// undefined reaching the server.
{
  const hook = makeHook(makeLayer());
  mount(hook);
  hook.listeners["etcher:prefs-changed"]({});
  assert.deepStrictEqual(hook.pushed[0].payload, {});
}

// ── stored preferences come back ────────────────────────────────────────────

{
  const layer = makeLayer();
  const hook = makeHook(layer);
  mount(hook);
  hook.handlers["board:prefs"]({ prefs: { panel: "hidden" } });
  tick();
  assert.deepStrictEqual(layer.received, [{ panel: "hidden" }]);
  // Handing them back must NOT look like a change, or every page load would
  // write them straight back to the server.
  assert.deepStrictEqual(hook.pushed, []);
}

// Nothing stored is the common case — a user who has never changed anything.
// Etcher must be left on its own defaults rather than handed an empty set,
// which it would merge as "no tools, no colours".
{
  const layer = makeLayer();
  const hook = makeHook(layer);
  mount(hook);
  for (const empty of [null, undefined, {}]) {
    hook.handlers["board:prefs"]({ prefs: empty });
  }
  tick();
  assert.deepStrictEqual(layer.received, [], "nothing stored, nothing applied");
}

// ── the layer is not ready yet ──────────────────────────────────────────────

// The mount reply can beat etcher's setup, because etcher lazy-loads its
// script. The preferences have to wait for it rather than being dropped.
{
  const layer = makeLayer();
  let ready = false;
  const hook = makeHook(() => (ready ? layer : null));
  mount(hook);

  hook.handlers["board:prefs"]({ prefs: { panel: "compact" } });
  tick();
  assert.deepStrictEqual(layer.received, [], "nothing to apply them to yet");

  ready = true;
  tick();
  assert.deepStrictEqual(layer.received, [{ panel: "compact" }],
    "applied once etcher is up");
}

// It gives up rather than retrying forever — a page with no etcher on it at
// all must not leave a timer running for the life of the tab.
{
  const hook = makeHook(null);
  mount(hook);
  hook.handlers["board:prefs"]({ prefs: { panel: "compact" } });
  let rounds = 0;
  while (clockQueue.length && rounds < 500) { tick(); rounds++; }
  assert.ok(rounds < 500, `gave up after ${rounds} rounds`);
  assert.strictEqual(clockQueue.length, 0, "no timer left running");
}

// An etcher too old to know about preferences is not a crash.
{
  const hook = makeHook({});
  mount(hook);
  hook.handlers["board:prefs"]({ prefs: { panel: "compact" } });
  tick();
}

// ── teardown ────────────────────────────────────────────────────────────────

// The listener is on an element that outlives the hook across a LiveView
// patch, so leaving it attached would push a preference change once per
// mount the page has ever had.
{
  const hook = makeHook(makeLayer());
  mount(hook);
  assert.ok(hook.listeners["etcher:prefs-changed"]);
  try { BoardSync.destroyed.call(hook); } catch (_) {}
  assert.ok(!hook.listeners["etcher:prefs-changed"], "unbound on teardown");
}

console.log("prefs relay: all checks passed");
