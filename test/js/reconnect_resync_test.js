// Pins what BoardSync tells the server when its LiveView reconnects.
//
// A reconnect is a new LiveView process, mounted from the stored board, while
// the page still shows the board as it was when the line dropped — plus work
// done offline, which the server never got. The page snapshots the board on
// `disconnected` and, on `reconnected`, sends its whole list and which shapes
// changed since the snapshot, so the server can keep that work and send back
// only what the page lacks.
//
//   node test/js/reconnect_resync_test.js

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
global.UPLOAD_SILENCE_MS = 15000;
global.UPLOAD_STORING_MS = 5 * 60 * 1000;

const BoardSync = eval(
  "(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")"
);

// Etcher's getShapes: descriptors that share the LIVE geometry object, with
// null style/metadata spelled out and render-only fields alongside.
function makeLayer(shapes) {
  const layer = { shapes };
  layer.getShapes = () =>
    layer.shapes.map((s) => ({
      uuid: s.uuid,
      kind: s.kind,
      geometry: s.geometry,
      style: s.style || null,
      metadata: s.metadata || null,
      ...(s.readonly ? { readonly: true } : {})
    }));
  return layer;
}

function hookFor(layer) {
  const hook = Object.create(BoardSync);
  hook.layer = () => layer;
  hook.pushed = [];
  hook.pushEvent = (name, payload) => hook.pushed.push([name, payload]);
  return hook;
}

const rect = (uuid, x, extra) =>
  Object.assign({ uuid, kind: "rect", geometry: { x, y: 0 }, style: { color: "#f00" } }, extra);

// ── offline work is named, the rest is just listed ──────────────────────────
{
  const a = rect("a", 0);
  const b = rect("b", 5);
  const c = rect("c", 9);
  const layer = makeLayer([a, b, c]);
  const hook = hookFor(layer);

  hook.disconnected();

  // A drag mutates geometry IN PLACE; the snapshot must not follow it.
  a.geometry.x = 40;
  layer.shapes = [a, c, rect("d", 1)];
  // A later drop before the rejoin must not move the base.
  hook.disconnected();
  hook.reconnected();

  assert.strictEqual(hook.pushed.length, 1);
  const [name, payload] = hook.pushed[0];
  assert.strictEqual(name, "board:ready");
  assert.deepStrictEqual(payload.resync.created, ["d"]);
  assert.deepStrictEqual(payload.resync.updated, ["a"]);
  assert.deepStrictEqual(payload.resync.deleted, ["b"]);
  assert.deepStrictEqual(payload.resync.annotations.map((s) => s.uuid), ["a", "c", "d"]);
  assert.strictEqual(hook.offlineBase, null, "the base is spent");
}

// ── the list is what etcher would emit ──────────────────────────────────────
{
  const layer = makeLayer([
    { uuid: "n", kind: "text", geometry: { x: 1 }, readonly: true },
    { uuid: "v", kind: "video", geometry: { href: "" } },
    { uuid: "w", kind: "video", geometry: { href: "/media/w" } }
  ]);
  const hook = hookFor(layer);
  hook.disconnected();
  hook.reconnected();

  assert.deepStrictEqual(hook.pushed[0][1].resync.annotations, [
    { uuid: "n", kind: "text", geometry: { x: 1 } },
    { uuid: "w", kind: "video", geometry: { href: "/media/w" } }
  ], "no nulls, no readonly, no media card still uploading");
  assert.deepStrictEqual(hook.pushed[0][1].resync.updated, []);
}

// ── key order is not a change ───────────────────────────────────────────────
{
  const s = { uuid: "a", kind: "rect", geometry: { x: 1, y: 2 }, style: { color: "#f00", width: 2 } };
  const layer = makeLayer([s]);
  const hook = hookFor(layer);
  hook.disconnected();
  s.geometry = { y: 2, x: 1 };
  s.style = { width: 2, color: "#f00" };
  hook.reconnected();
  assert.deepStrictEqual(hook.pushed[0][1].resync.updated, []);
}

// ── no snapshot: nothing counts as local work, but the page still catches up ─
{
  const hook = hookFor(makeLayer([rect("a", 0)]));
  hook.reconnected();
  const { resync } = hook.pushed[0][1];
  assert.deepStrictEqual([resync.created, resync.updated, resync.deleted], [[], [], []]);
  assert.deepStrictEqual(resync.annotations.map((s) => s.uuid), ["a"]);
}

// ── no layer: the plain ping ────────────────────────────────────────────────
{
  const hook = hookFor(null);
  hook.disconnected();
  hook.reconnected();
  assert.deepStrictEqual(hook.pushed, [["board:ready", {}]]);
}

console.log("reconnect resync: all checks passed");
