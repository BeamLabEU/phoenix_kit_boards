// Export as PDF from a board's tile: the hook waits for the off-screen board
// to be drawn, runs Fresco's export, and always tells the server when it is
// done — so the copy is taken down whatever happened.
//
//   node test/js/panel_export_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "boards_panel_export.js"),
  "utf8"
);
const hookDef = eval(src);

global.requestAnimationFrame = (f) => setTimeout(f, 0);
const tick = (ms) => new Promise((r) => setTimeout(r, ms || 0));

function world({ exportPdf, layerReadyAfter = 0, noFresco = false } = {}) {
  let readyAt = Date.now() + layerReadyAfter;
  const calls = [];
  const handle = { exportPdf: exportPdf || ((o) => { calls.push(o); return Promise.resolve({}); }) };
  global.window = noFresco ? {} : {
    Fresco: { onReady: (id, cb) => { assert.strictEqual(id, "panel-export-1"); setTimeout(() => cb(handle), 0); } },
    Etcher: { layerFor: () => ({ isReady: () => Date.now() >= readyAt }) }
  };
  const sent = [];
  const hook = Object.create(hookDef);
  hook.el = { dataset: { frescoId: "panel-export-1", filename: "Q3 plan" } };
  hook.pushEventTo = (_t, name, payload) => sent.push({ name, payload });
  return { hook, sent, calls };
}

(async function () {
  // Exported once the layer has drawn, under the board's name.
  {
    const w = world({ layerReadyAfter: 250 });
    w.hook.mounted();
    await tick(100);
    assert.deepStrictEqual(w.calls, [], "not before the shapes are drawn");
    await tick(400);
    assert.deepStrictEqual(w.calls, [{ filename: "Q3 plan" }]);
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: true, reason: null } }]);
    w.hook.destroyed();
  }

  // A failed export is reported, once.
  {
    const w = world({ exportPdf: () => Promise.reject(new Error("tainted")) });
    w.hook.mounted();
    await tick(200);
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: false, reason: "tainted" } }]);
    w.hook.destroyed();
  }

  // No viewer on the page: reported at once, never left hanging.
  {
    const w = world({ noFresco: true });
    w.hook.mounted();
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: false, reason: "viewer not loaded" } }]);
    w.hook.destroyed();
  }

  // A viewer too old to export.
  {
    const w = world();
    global.window.Fresco.onReady = (_id, cb) => cb({});
    w.hook.mounted();
    await tick(50);
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: false, reason: "this viewer cannot export" } }]);
    w.hook.destroyed();
  }

  console.log("Panel export: all checks passed");
})().catch((e) => { console.error(e); process.exit(1); });
