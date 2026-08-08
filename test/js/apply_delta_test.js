// Pins how a peer's edit is applied locally.
//
// The board used to delete and re-add every changed shape. That rebuilds the
// element — media reloads, images re-decode — and because re-adding appends,
// the layering had to be re-imposed afterwards, which touched every shape on
// the board. So watching someone drag one thing flashed all of it.
//
// A changed shape is now patched where it stands, and the order is only
// re-imposed when it can actually have moved. The two things worth guarding
// are that a plain move takes the patch path and disturbs nothing else, and
// that the cases patching CANNOT express still fall back to the rebuild
// rather than silently diverging from the sender.
//
//   node test/js/apply_delta_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"
);
const src = fs.readFileSync(SOURCE, "utf8");

// `patchInPlace` closes over this; evaluated from the source rather than
// reimplemented, since a test that compares keys differently proves nothing.
{
  const m = /  function sameKeys\(a, b\) \{[\s\S]*?\n  \}/.exec(src);
  assert.ok(m, "could not find sameKeys");
  global.sameKeys = eval("(" + m[0].trim().replace("function sameKeys", "function") + ")");
}

const start = src.indexOf("  const BoardSync = {");
assert.notStrictEqual(start, -1, "could not find BoardSync");
const end = src.indexOf("\n  };", start);
assert.notStrictEqual(end, -1, "could not find the end of BoardSync");
const BoardSync = eval(
  "(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")"
);

// ── a stand-in etcher layer that records what was done to it ────────────────

function makeLayer(shapes, opts) {
  const o = opts || {};
  const layer = {
    shapes: new Map((shapes || []).map((s) => [s.uuid, s])),
    calls: [],
    deleteShape(uuid) { layer.calls.push(["delete", uuid]); layer.shapes.delete(uuid); },
    addShape(shape) { layer.calls.push(["add", shape.uuid]); layer.shapes.set(shape.uuid, shape); },
    setShapeOrder(order) { layer.calls.push(["order", order]); },
    getShape(uuid) { return layer.shapes.get(uuid) || null; }
  };

  // An etcher too old to patch omits it entirely.
  if (!o.noPatch) {
    layer.patchShape = (uuid, fields) => {
      layer.calls.push(["patch", uuid]);
      Object.assign(layer.shapes.get(uuid), fields);
    };
  }
  return layer;
}

function hookFor(layer) {
  const hook = Object.create(BoardSync);
  hook.layer = () => layer;
  return hook;
}

const kinds = (layer) => layer.calls.map((c) => c[0]);

const rect = (uuid, x) => ({
  uuid,
  kind: "rect",
  geometry: { x, y: 0, w: 10, h: 10 },
  style: { color: "#f00" }
});

// ── a peer moves something ──────────────────────────────────────────────────

{
  const layer = makeLayer([rect("a", 0), rect("b", 50)]);
  hookFor(layer).apply({ updated: [rect("a", 25)], order: ["a", "b"], reordered: false });

  assert.deepStrictEqual(kinds(layer), ["patch"], "patched, not rebuilt");
  assert.deepStrictEqual(layer.shapes.get("a").geometry, { x: 25, y: 0, w: 10, h: 10 });
  // The whole point: nothing else on the board was touched.
  assert.ok(!kinds(layer).includes("order"), "layering left alone");
  assert.ok(!kinds(layer).includes("delete"), "nothing destroyed");
}

// ── when the order really can have moved ────────────────────────────────────

{
  const layer = makeLayer([rect("a", 0)]);
  hookFor(layer).apply({ created: [rect("c", 9)], order: ["a", "c"] });
  assert.ok(kinds(layer).includes("order"), "a new shape needs the order re-imposed");
}
{
  const layer = makeLayer([rect("a", 0), rect("b", 5)]);
  hookFor(layer).apply({ deleted: ["b"], order: ["a"] });
  assert.ok(kinds(layer).includes("order"), "so does a removed one");
}
{
  const layer = makeLayer([rect("a", 0), rect("b", 5)]);
  hookFor(layer).apply({ updated: [rect("a", 1)], order: ["b", "a"], reordered: true });
  assert.ok(kinds(layer).includes("order"), "and an actual reorder");
}

// ── what patching cannot express ────────────────────────────────────────────

// `patchShape` MERGES style and metadata, so a peer that REMOVED a key would
// leave a stale copy behind. Rebuilt instead — correctness over the flash.
{
  const layer = makeLayer([{ uuid: "a", kind: "rect", geometry: {}, style: { color: "#f00", fill: "solid" } }]);
  hookFor(layer).apply({ updated: [{ uuid: "a", kind: "rect", geometry: {}, style: { color: "#f00" } }] });
  assert.deepStrictEqual(kinds(layer), ["delete", "add"], "a removed style key forces a rebuild");
}
{
  const layer = makeLayer([{ uuid: "a", kind: "rect", geometry: {}, metadata: { title: "x" } }]);
  hookFor(layer).apply({ updated: [{ uuid: "a", kind: "rect", geometry: {} }] });
  assert.deepStrictEqual(kinds(layer), ["delete", "add"], "and a removed metadata key");
}

// A shape that changed KIND is a different shape as far as rendering goes.
{
  const layer = makeLayer([rect("a", 0)]);
  hookFor(layer).apply({ updated: [{ uuid: "a", kind: "ellipse", geometry: {}, style: { color: "#f00" } }] });
  assert.deepStrictEqual(kinds(layer), ["delete", "add"]);
}

// Nothing to patch: an update for a shape this viewer has never seen. Adding
// it is the point — otherwise the shape would simply be missing here.
{
  const layer = makeLayer([]);
  hookFor(layer).apply({ updated: [rect("ghost", 0)] });
  assert.deepStrictEqual(kinds(layer), ["delete", "add"]);
  assert.ok(layer.shapes.has("ghost"));
}

// An etcher without `patchShape` must still apply edits, just the old way.
{
  const layer = makeLayer([rect("a", 0)], { noPatch: true });
  hookFor(layer).apply({ updated: [rect("a", 25)], order: ["a"] });
  assert.deepStrictEqual(kinds(layer), ["delete", "add"]);
  assert.deepStrictEqual(layer.shapes.get("a").geometry.x, 25, "and the edit still lands");
}

// ── nothing to apply to ─────────────────────────────────────────────────────

{
  const hook = Object.create(BoardSync);
  hook.layer = () => null;
  hook.apply({ updated: [rect("a", 1)] });  // must not throw
}

// An empty delta does nothing at all — no order pass, no rebuild.
{
  const layer = makeLayer([rect("a", 0)]);
  hookFor(layer).apply({ created: [], updated: [], deleted: [], order: ["a"], reordered: false });
  assert.deepStrictEqual(layer.calls, []);
}

console.log("apply delta: all checks passed");
