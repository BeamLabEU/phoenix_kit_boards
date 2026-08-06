// Pins how a peer's cursor is drawn when they are presenting with the red
// pointer.
//
// One person is one cursor. While they present, that cursor is a red laser
// dot drawn by etcher (which owns what a pointer looks like, and draws in
// canvas coordinates so it lands on the same spot for everyone); the rest of
// the time it is the arrow-with-a-name-tag drawn here. The bug this guards
// against is showing BOTH — two markers in the same place, reading as two
// people — or getting stuck in one of the two states, which is worse: a
// presenter who stops pointing and leaves a red dot on everyone's board has
// no way to clear it.
//
// The transitions are the whole feature, so they are driven here directly
// rather than through a LiveView.
//
//   node test/js/cursor_pointer_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"
);
const src = fs.readFileSync(SOURCE, "utf8");

// `buildCursor` closes over the file's escaping helpers, so they have to be
// in scope here too — evaluated from the source rather than reimplemented,
// since a test that escapes differently from the code proves nothing.
for (const fn of ["escapeHtml", "escapeAttr"]) {
  const m = new RegExp(`  function ${fn}\\(s\\) \\{[\\s\\S]*?\\n  \\}`).exec(src);
  assert.ok(m, `could not find ${fn}`);
  global[fn] = eval("(" + m[0].trim().replace(`function ${fn}`, "function") + ")");
}

// The hook is a plain object literal inside an IIFE — take it by name and
// evaluate it on its own, so a rename fails loudly instead of quietly
// testing nothing.
const start = src.indexOf("  const BoardCursors = {");
assert.notStrictEqual(start, -1, "could not find BoardCursors");
const end = src.indexOf("\n  };", start);
assert.notStrictEqual(end, -1, "could not find the end of BoardCursors");
const literal = src.slice(start + "  const BoardCursors = ".length, end + "\n  }".length);
const BoardCursors = eval("(" + literal + ")");

// ── stand-ins ───────────────────────────────────────────────────────────────

function makeLayer() {
  return {
    pointerMode: false,
    applied: [],
    removed: [],
    isPointerMode() { return this.pointerMode; },
    applyRemotePointer(id, state) { this.applied.push({ id, ...state }); return true; },
    removeRemotePointer(id) { this.removed.push(id); return true; }
  };
}

// A hook instance with the DOM and the fresco handle stubbed. `update` only
// reaches for the handle's imageToScreen and the overlay's rect.
function makeHook(layer) {
  const children = [];
  const hook = Object.create(BoardCursors);
  hook.frescoId = "board-canvas";
  hook.cursors = {};
  hook.handle = { imageToScreen: (p) => ({ x: p.x, y: p.y }) };
  hook.el = {
    children,
    getBoundingClientRect: () => ({ left: 0, top: 0 }),
    appendChild(c) { children.push(c); c.parentNode = hook.el; },
    removeChild(c) {
      const i = children.indexOf(c);
      if (i !== -1) children.splice(i, 1);
      c.parentNode = null;
    }
  };
  hook.layer = () => layer;
  return hook;
}

global.document = {
  createElement() {
    return { style: { cssText: "" }, innerHTML: "", parentNode: null };
  }
};

const arrows = (hook) => Object.keys(hook.cursors);

// ── a peer who is not pointing ──────────────────────────────────────────────

{
  const layer = makeLayer();
  const hook = makeHook(layer);
  hook.update({ id: "p1", x: 10, y: 20, name: "Ada", color: "#f00" });
  assert.deepStrictEqual(arrows(hook), ["p1"], "drawn as an ordinary cursor");
  assert.strictEqual(layer.applied.length, 0, "etcher is not involved");
}

// ── a peer who IS pointing ──────────────────────────────────────────────────

{
  const layer = makeLayer();
  const hook = makeHook(layer);
  hook.update({ id: "p1", x: 10, y: 20, name: "Ada", color: "#f00", pointer: true });
  assert.deepStrictEqual(arrows(hook), [], "no arrow while presenting");
  assert.strictEqual(layer.applied.length, 1, "etcher draws them instead");
  assert.strictEqual(layer.applied[0].id, "p1");
  assert.strictEqual(layer.applied[0].x, 10);
  assert.strictEqual(layer.applied[0].y, 20);
  // Canvas coordinates are passed straight through: etcher converts them for
  // whatever zoom this viewer is at, which is the point of sending them.
  assert.ok(!("screenX" in layer.applied[0]));
}

// ── turning it on, then off ─────────────────────────────────────────────────

// The transition both ways is what has to be exact. At no point may there be
// two markers for one person, and at no point may there be none.
{
  const layer = makeLayer();
  const hook = makeHook(layer);

  hook.update({ id: "p1", x: 1, y: 1, name: "Ada", color: "#f00" });
  assert.deepStrictEqual(arrows(hook), ["p1"]);

  // arms the pointer
  hook.update({ id: "p1", x: 2, y: 2, name: "Ada", color: "#f00", pointer: true });
  assert.deepStrictEqual(arrows(hook), [], "the arrow goes away");
  assert.strictEqual(layer.applied.length, 1);

  // keeps pointing — must not keep re-removing or start stacking arrows
  hook.update({ id: "p1", x: 3, y: 3, name: "Ada", color: "#f00", pointer: true });
  assert.deepStrictEqual(arrows(hook), []);
  assert.strictEqual(layer.applied.length, 2, "just moves");

  // puts it away
  hook.update({ id: "p1", x: 4, y: 4, name: "Ada", color: "#f00" });
  assert.deepStrictEqual(layer.removed, ["p1"], "the dot is taken back");
  assert.deepStrictEqual(arrows(hook), ["p1"], "and the arrow comes back");
}

// Two people, one presenting: they do not interfere.
{
  const layer = makeLayer();
  const hook = makeHook(layer);
  hook.update({ id: "teacher", x: 1, y: 1, name: "T", color: "#f00", pointer: true });
  hook.update({ id: "student", x: 2, y: 2, name: "S", color: "#00f" });
  assert.deepStrictEqual(arrows(hook), ["student"]);
  assert.strictEqual(layer.applied.length, 1);
  assert.strictEqual(layer.applied[0].id, "teacher");
}

// ── leaving ─────────────────────────────────────────────────────────────────

// A presenter who closes the tab must not leave a dot behind. Etcher times
// pointers out on its own, but a clean leave should not wait for that.
{
  const layer = makeLayer();
  const hook = makeHook(layer);
  hook.update({ id: "p1", x: 1, y: 1, name: "Ada", color: "#f00", pointer: true });
  hook.remove("p1");
  hook.dropPointer("p1");
  assert.deepStrictEqual(layer.removed, ["p1"]);
  assert.deepStrictEqual(arrows(hook), []);
}

// Dropping a pointer nobody has is not an error — the leave path runs for
// every peer, most of whom were never pointing.
{
  const layer = makeLayer();
  const hook = makeHook(layer);
  hook.dropPointer("never-pointed");
  assert.deepStrictEqual(layer.removed, []);
}

// ── a page with no etcher on it ─────────────────────────────────────────────

// The board is etcher's host, but the hook must not blank a peer out if the
// layer isn't there — better an arrow than nothing.
{
  const hook = makeHook(null);
  hook.update({ id: "p1", x: 1, y: 1, name: "Ada", color: "#f00", pointer: true });
  assert.deepStrictEqual(arrows(hook), ["p1"],
    "falls back to an ordinary cursor rather than losing them");
}

// ── what we send ────────────────────────────────────────────────────────────

// The flag is read from the live layer each time, so arming the tool takes
// effect on the very next move rather than at the next reload.
{
  const layer = makeLayer();
  const hook = makeHook(layer);
  assert.strictEqual(hook.pointing(), false);
  layer.pointerMode = true;
  assert.strictEqual(hook.pointing(), true);
}
{
  const hook = makeHook(null);
  assert.strictEqual(hook.pointing(), false, "no layer means not pointing");
}
{
  const hook = makeHook({});                       // an older etcher
  assert.strictEqual(hook.pointing(), false,
    "an etcher without the pointer API means not pointing, not a crash");
}

console.log("cursor pointer: all checks passed");
