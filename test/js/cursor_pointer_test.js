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

// Same reason: the hook reads these timings from the enclosing IIFE, so they
// have to exist here. Read from the source rather than restated, or a change
// to any of them would leave the test asserting against stale numbers.
for (const name of [
  "CURSOR_SEND_MS", "CURSOR_GLIDE_MS", "CURSOR_MIN_GLIDE_MS",
  "CURSOR_MAX_GLIDE_MS", "CURSOR_STALE_GAP_MS"
]) {
  const m = new RegExp(`const ${name} = (\\d+);`).exec(src);
  assert.ok(m, `could not find ${name}`);
  global[name] = Number(m[1]);
}

// A cursor glides between the positions it is told about, over the interval
// they are actually arriving at. The bounds on that measurement are what has
// to hold: below a frame there is no motion to see, and above the ceiling a
// peer who stopped would keep drifting.
assert.ok(global.CURSOR_MIN_GLIDE_MS > 0 && global.CURSOR_MIN_GLIDE_MS <= 20,
  "the floor should be about one frame");
assert.ok(global.CURSOR_GLIDE_MS >= global.CURSOR_MIN_GLIDE_MS,
  "the opening estimate cannot start below the floor");
assert.ok(global.CURSOR_MAX_GLIDE_MS > global.CURSOR_GLIDE_MS,
  "the ceiling has to leave room above the starting estimate");
assert.ok(global.CURSOR_STALE_GAP_MS > global.CURSOR_MAX_GLIDE_MS,
  "a gap counted as stale must be longer than the longest real glide");

// The clock the interpolation runs on.
let clock = 0;
global.now_ = () => clock;

// rAF is driven by hand so frames can be stepped through deliberately.
let frames = [];
global.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
global.cancelAnimationFrame = () => {};
const frame = (ms) => {
  clock += ms === undefined ? 16 : ms;
  const due = frames;
  frames = [];
  due.forEach((fn) => fn());
};

// Cursors go over the ephemeral channel when there is one and fall back to
// the LiveView when there isn't, so the thing that decides has to be here.
{
  const at = src.indexOf("  const BoardLink = {");
  assert.notStrictEqual(at, -1, "could not find BoardLink");
  const to = src.indexOf("\n  };", at);
  assert.notStrictEqual(to, -1, "could not find the end of BoardLink");
  global.BoardLink = eval(
    "(" + src.slice(at + "  const BoardLink = ".length, to + "\n  }".length) + ")"
  );
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
    const el = { style: { cssText: "" }, innerHTML: "", parentNode: null };
    // The name tag, which the tool glyph is drawn into. Every cursor has one
    // in a browser, so the stand-in always has one too — otherwise a change
    // that redrew it more often than it should would surface here as a
    // TypeError rather than as the assertion that describes the problem.
    el._tag = { innerHTML: "" };
    el.querySelector = () => el._tag;
    return el;
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

// ── what we send, and when ──────────────────────────────────────────────────

// Moving is a stream of events and the socket gets one every CURSOR_SEND_MS —
// but the LAST one always has to arrive. A bare throttle drops whatever falls
// inside the window, and the final move of a gesture is exactly that, so a
// peer's cursor stopped short of where the person left it and stayed there.
{
  const hook = makeHook(makeLayer());
  hook.lastSent = 0;
  hook.pushed = [];
  hook.pushEvent = (name, payload) => hook.pushed.push({ name, payload });
  hook.handle = { screenToImage: (p) => ({ x: p.x, y: p.y }) };

  let now = 1000;
  const realNow = Date.now;
  Date.now = () => now;

  let timer = null;
  const realSetTimeout = global.setTimeout;
  global.setTimeout = (fn, ms) => { timer = { fn, ms }; return 1; };
  global.clearTimeout = () => { timer = null; };

  const move = (x) => { hook.pending = { x, y: x }; hook.flushMove(); };

  move(1);
  assert.strictEqual(hook.pushed.length, 1, "the first move goes at once");
  assert.strictEqual(hook.pushed[0].payload.x, 1);

  // Three more inside the window: throttled, not lost.
  now += 5; move(2);
  now += 5; move(3);
  now += 5; move(4);
  assert.strictEqual(hook.pushed.length, 1, "still just the one");
  assert.ok(timer, "the last one is waiting its turn");
  assert.ok(timer.ms > 0 && timer.ms <= CURSOR_SEND_MS, `waits ${timer.ms}ms`);

  // The window passes and the timer fires. Cleared first, so anything armed
  // after this is a NEW timer rather than the one we just ran.
  const armed = timer;
  timer = null;
  now += armed.ms;
  armed.fn();
  assert.strictEqual(hook.pushed.length, 2, "and then it lands");
  assert.strictEqual(hook.pushed[1].payload.x, 4,
    "the position sent is where the pointer ended up, not where it was when the window closed");

  // A resting pointer must not keep sending, or rearm itself forever.
  assert.strictEqual(timer, null, "nothing rearmed");
  assert.ok(!hook.moveTimer, "and the hook is not holding one");
  hook.flushMove();
  assert.strictEqual(hook.pushed.length, 2, "a still pointer sends nothing");

  Date.now = realNow;
  global.setTimeout = realSetTimeout;
}

// ── how a peer's cursor is drawn between packets ────────────────────────────
//
// Positions arrive ~20 times a second; the screen redraws 60. The gap is
// filled by interpolating per frame, NOT by a CSS transition — a transition
// restarts every time the transform is set, so an early or late packet
// visibly changes the cursor's speed. That is the choppiness.

const xOf = (c) => {
  const m = /translate3d\((-?[\d.]+)px/.exec(c.el.style.transform || "");
  return m ? Number(m[1]) : null;
};

{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00" });
  const c = hook.cursors["p1"];

  // A second position 100 units away, one send-interval later.
  clock += CURSOR_SEND_MS;
  hook.update({ id: "p1", x: 100, y: 0, name: "Ada", color: "#f00" });

  frame(0);
  assert.strictEqual(xOf(c), 0, "starts where it was, not where it is going");

  // Part-way through the glide it is part-way there — the whole point.
  frame(c.span / 2);
  const mid = xOf(c);
  assert.ok(mid > 5 && mid < 95, `expected to be mid-flight, got ${mid}`);

  // A later frame is further along than an earlier one.
  frame(c.span / 4);
  assert.ok(xOf(c) > mid, "keeps moving");

  // And it arrives exactly, rather than stopping short or overshooting.
  frame(c.span);
  assert.strictEqual(xOf(c), 100, "arrives");

  // Having arrived, it stays put.
  frame(200);
  assert.strictEqual(xOf(c), 100, "and stays");
}

// The glide is measured, not assumed. A peer whose packets arrive slowly must
// glide slowly, or the cursor lands early and waits — the stutter again.
{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 0, y: 0, name: "A", color: "#f00" });
  const c = hook.cursors["p1"];
  const started = c.span;

  // Ten packets, each 160ms apart — a slower connection than the send rate.
  for (let i = 1; i <= 10; i++) {
    clock += 160;
    hook.update({ id: "p1", x: i, y: 0, name: "A", color: "#f00" });
  }

  assert.ok(c.span > started, `glide should have grown from ${started}, got ${c.span}`);
  assert.ok(c.span <= CURSOR_MAX_GLIDE_MS, "but never past the ceiling");
}

// Over the channel, positions arrive about once a frame — far faster than
// the rationed fallback rate. The glide has to follow them down, or every
// cursor would sit a fallback-interval behind for no reason: the measurement
// is what decides, and only a frame is allowed to floor it.
{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 0, y: 0, name: "A", color: "#f00" });
  const c = hook.cursors["p1"];

  for (let i = 1; i <= 20; i++) {
    clock += CURSOR_MIN_GLIDE_MS;
    hook.update({ id: "p1", x: i, y: 0, name: "A", color: "#f00" });
  }

  assert.ok(c.span < CURSOR_SEND_MS,
    `frame-rate packets should glide in under ${CURSOR_SEND_MS}ms, got ${c.span}`);
  assert.ok(c.span >= CURSOR_MIN_GLIDE_MS, "but never below a frame");
}

// A pause is not a slow connection. Someone who stops for a second and starts
// again must not leave the estimate believing every packet takes a second.
{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 0, y: 0, name: "A", color: "#f00" });
  const c = hook.cursors["p1"];

  for (let i = 1; i <= 5; i++) {
    clock += CURSOR_SEND_MS;
    hook.update({ id: "p1", x: i, y: 0, name: "A", color: "#f00" });
  }
  const settled = c.interval;

  clock += CURSOR_STALE_GAP_MS * 3; // wandered off, came back
  hook.update({ id: "p1", x: 99, y: 0, name: "A", color: "#f00" });

  assert.strictEqual(c.interval, settled, "a pause left the estimate alone");
}

// The loop keeps running while anyone is on the board, so a peer standing
// still stays on the spot they are pointing at while THIS viewer pans. If it
// settled instead, their cursor would stick to the glass.
{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 10, y: 10, name: "A", color: "#f00" });
  frame(1000);
  assert.strictEqual(frames.length, 1, "still drawing after everyone settled");

  // The viewer zooms: the same canvas point is now somewhere else on screen.
  hook.handle.imageToScreen = (p) => ({ x: p.x * 3, y: p.y * 3 });
  frame();
  assert.strictEqual(xOf(hook.cursors["p1"]), 30, "followed the view");
}

// With nobody left, the loop stops rather than spinning forever.
{
  const hook = makeHook(makeLayer());
  clock = 0;
  frames = [];

  hook.update({ id: "p1", x: 1, y: 1, name: "A", color: "#f00" });
  frame();
  assert.strictEqual(frames.length, 1);

  hook.remove("p1");
  frame();
  assert.strictEqual(frames.length, 0, "no peers, no loop");
}

// ── which pipe a cursor goes down ───────────────────────────────────────────
//
// The ephemeral channel when there is one — that is the point of having it.
// The LiveView when there isn't, which is where cursors used to go and what a
// host that hasn't mounted the socket still gets.

{
  const hook = makeHook(makeLayer());
  hook.frescoId = "board-canvas";
  hook.lastSent = 0;
  hook.pushed = [];
  hook.pushEvent = (name, payload) => hook.pushed.push({ name, payload });
  hook.handle = { screenToImage: (p) => ({ x: p.x, y: p.y }) };

  const realNow = Date.now;
  let t = 100000;
  Date.now = () => t;

  // No channel joined: straight to the LiveView.
  BoardLink.links = {};
  hook.pending = { x: 5, y: 6 };
  hook.flushMove();
  assert.strictEqual(hook.pushed.length, 1, "fell back to the LiveView");
  assert.strictEqual(hook.pushed[0].name, "cursor:move");
  assert.deepStrictEqual(hook.pushed[0].payload, { x: 5, y: 6, pointer: false, tool: null });

  // Joined: down the channel instead, and NOT also through the LiveView —
  // sending both would have every peer told twice.
  const sent = [];
  BoardLink.links["board-canvas"] = {
    joined: true,
    topic: "board:x",
    handlers: {},
    channel: { push: (event, payload) => sent.push({ event, payload }) }
  };

  // Paced by the display rather than a timer, so nothing goes until the
  // frame does — and several moves inside one frame collapse to the last.
  frames = [];
  hook.pending = { x: 6, y: 7 };
  hook.flushMove();
  hook.pending = { x: 7, y: 8 };
  hook.flushMove();
  assert.strictEqual(sent.length, 0, "waits for the frame");
  assert.strictEqual(frames.length, 1, "and only asks for one");

  frame();
  assert.strictEqual(sent.length, 1, "went down the channel");
  assert.strictEqual(sent[0].event, "cursor");
  assert.deepStrictEqual(sent[0].payload, { x: 7, y: 8, pointer: false, tool: null },
    "the position sent is the latest, not the one that opened the frame");
  assert.strictEqual(hook.pushed.length, 1, "and not through the LiveView as well");

  // A still pointer stops asking for frames rather than spinning.
  hook.flushMove();
  assert.strictEqual(frames.length, 0, "nothing pending, nothing scheduled");

  // A channel that exists but hasn't finished joining is not a channel yet.
  BoardLink.links["board-canvas"].joined = false;
  t += CURSOR_SEND_MS;
  hook.pending = { x: 9, y: 10 };
  hook.flushMove();
  assert.strictEqual(sent.length, 1, "nothing sent to an unjoined channel");
  assert.strictEqual(hook.pushed.length, 2, "fell back while it joins");

  // A channel that throws must not lose the cursor either.
  BoardLink.links["board-canvas"] = {
    joined: true,
    topic: "board:x",
    handlers: {},
    channel: { push: () => { throw new Error("socket died"); } }
  };
  frames = [];
  hook.pending = { x: 11, y: 12 };
  hook.flushMove();
  frame();
  assert.strictEqual(hook.pushed.length, 3, "a broken channel falls back too");
  assert.deepStrictEqual(hook.pushed[2].payload, { x: 11, y: 12, pointer: false, tool: null });

  BoardLink.links = {};
  Date.now = realNow;
}

// ── what a peer is holding ──────────────────────────────────────────────────
//
// Five identical arrows say nothing about what anyone is doing. The tool
// rides the cursor message and is drawn in that person's name tag, using
// etcher's own glyph — the same one it puts on the local cursor — so nothing
// here knows the set of tools.

function makeTagHook(badges) {
  const layer = makeLayer();
  layer.toolBadge = (key) => badges[key] || null;
  const hook = makeHook(layer);
  hook._restore = () => {};
  return hook;
}

const BADGES = { marker: "<path d='M1 1'/>", text: "<path d='M2 2'/>" };

// The arrow, for reference: what a peer looks like with no tool in hand.
const ARROW = "M4 2 L20 12 L13 13 L11 20 Z";

{
  const hook = makeTagHook(BADGES);
  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00", tool: "marker" });

  const c = hook.cursors["p1"];
  const html = c.el.innerHTML;

  assert.strictEqual(c.tool, "marker", "remembered what they are holding");
  assert.ok(html.includes(BADGES.marker), "drawn as the marker cursor");
  assert.ok(!html.includes(ARROW), "not as a generic arrow");
  // Their colour, not etcher's black — that is what tells two people apart.
  assert.ok(html.includes('stroke="#f00"'), "in their own colour");
  assert.ok(html.includes('stroke="#fff"'), "over a white underlay, to stay legible");
  assert.ok(html.includes("Ada"), "and still named");
  hook._restore();
}

// Someone with no tool in hand keeps the arrow, which is what the local
// cursor does in that case too.
{
  const hook = makeTagHook(BADGES);
  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00" });
  const html = hook.cursors["p1"].el.innerHTML;
  assert.ok(html.includes(ARROW), "arrow when holding nothing");
  assert.ok(html.includes("Ada"));
  hook._restore();
}

// Picking up something else redraws them — but only then. This runs on every
// packet, and rebuilding the cursor sixty times a second would be churn.
{
  const hook = makeTagHook(BADGES);
  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00", tool: "marker" });
  const c = hook.cursors["p1"];

  let writes = 0;
  let html = c.el.innerHTML;
  Object.defineProperty(c.el, "innerHTML", {
    set(v) { writes++; html = v; },
    get() { return html; }
  });

  hook.update({ id: "p1", x: 1, y: 1, name: "Ada", color: "#f00", tool: "marker" });
  hook.update({ id: "p1", x: 2, y: 2, name: "Ada", color: "#f00", tool: "marker" });
  assert.strictEqual(writes, 0, "same tool, no redraw");

  hook.update({ id: "p1", x: 3, y: 3, name: "Ada", color: "#f00", tool: "text" });
  assert.strictEqual(writes, 1, "changed tool, one redraw");
  assert.ok(c.el.innerHTML.includes(BADGES.text), "now the text cursor");
  assert.ok(!c.el.innerHTML.includes(BADGES.marker), "and no longer the marker");
  assert.ok(c.el.innerHTML.includes("Ada"), "the name survives the redraw");

  // Putting the tool down returns them to the arrow rather than leaving a
  // stale glyph.
  hook.update({ id: "p1", x: 4, y: 4, name: "Ada", color: "#f00" });
  assert.strictEqual(writes, 2);
  assert.ok(!c.el.innerHTML.includes(BADGES.text), "glyph gone");
  assert.ok(c.el.innerHTML.includes(ARROW), "back to the arrow");
  hook._restore();
}

// A tool etcher has no glyph for, and an etcher too old to have any, both
// read as a plain named arrow rather than breaking the cursor.
{
  const hook = makeTagHook(BADGES);
  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00", tool: "nosuchtool" });
  const html = hook.cursors["p1"].el.innerHTML;
  assert.ok(html.includes(ARROW), "unknown tool falls back to the arrow");
  assert.ok(html.includes("Ada"));
  hook._restore();
}
{
  const hook = makeHook(makeLayer()); // no toolBadge on the layer at all
  hook.update({ id: "p1", x: 0, y: 0, name: "Ada", color: "#f00", tool: "marker" });
  assert.deepStrictEqual(arrows(hook), ["p1"], "still drawn");
  assert.ok(hook.cursors["p1"].el.innerHTML.includes(ARROW));
}

// The markup is built by hand on both paths, so neither may become a way in.
{
  const hook = makeTagHook(BADGES);
  const evil = "<img src=x onerror=alert(1)>";

  hook.update({ id: "p1", x: 0, y: 0, name: evil, color: "#f00", tool: "marker" });
  assert.ok(!hook.cursors["p1"].el.innerHTML.includes("<img"), "escaped when first drawn");

  hook.update({ id: "p1", x: 1, y: 1, name: evil, color: "#f00", tool: "text" });
  const html = hook.cursors["p1"].el.innerHTML;
  assert.ok(!html.includes("<img"), `unescaped name survived the redraw: ${html}`);
  assert.ok(html.includes("&lt;img"), "escaped instead");

  // The colour is interpolated into a style attribute and into stroke=""; a
  // peer's colour comes from the server, but it is still markup being built.
  hook.update({ id: "p2", x: 0, y: 0, name: "Bob", color: '"><script>x</script>', tool: "marker" });
  assert.ok(!hook.cursors["p2"].el.innerHTML.includes("<script>"), "colour escaped too");
  hook._restore();
}

// ── leaving the board ───────────────────────────────────────────────────────
//
// The socket is opened here but lives on `BoardLink`, which outlives the page.
// Nothing else closes it, so walking back to the board list left it connected
// and still joined — with the "cursor" handler holding a hook whose element is
// no longer in the document. Every packet from a peer then appended a cursor
// to nothing and restarted the draw loop, which by then had nothing left to
// cancel it: one endless rAF loop per board opened, for the life of the tab.

{
  const hook = makeHook(makeLayer());
  const closed = [];
  BoardLink.links["board-canvas"] = {
    joined: true,
    topic: "board:x",
    handlers: {},
    channel: { push: () => {}, leave: () => closed.push("channel") },
    socket: { disconnect: () => closed.push("socket") }
  };
  BoardLink.on("board-canvas", "cursor", (p) => hook.update(p));

  hook.update({ id: "p1", x: 1, y: 1, name: "Ada", color: "#f00" });
  assert.deepStrictEqual(arrows(hook), ["p1"]);

  frames = [];
  hook.destroyed();

  assert.deepStrictEqual(closed, ["channel", "socket"], "the channel goes with the page");
  assert.strictEqual(BoardLink.links["board-canvas"], undefined, "and is forgotten");

  // A packet that raced the close must land nowhere rather than start the
  // loop again.
  const drawn = hook.el.children.length;
  hook.update({ id: "p2", x: 2, y: 2, name: "Bob", color: "#00f" });
  assert.strictEqual(hook.el.children.length, drawn, "nothing drawn after teardown");
  assert.strictEqual(frames.length, 0, "and no frame asked for");

  BoardLink.links = {};
}

console.log("cursor pointer: all checks passed");
