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
// Object URL cleanup should not keep this Node process alive.
const browserSetTimeout = global.setTimeout;
global.setTimeout = (fn, ms, ...args) => {
  const timer = browserSetTimeout(fn, ms, ...args);
  if (ms === 30000) timer.unref();
  return timer;
};
const tick = (ms) => new Promise((r) => setTimeout(r, ms || 0));

function world({ exportPdf, layerReadyAfter = 0, noFresco = false } = {}) {
  let readyAt = Date.now() + layerReadyAfter;
  const calls = [];
  const impl = exportPdf || (() => Promise.resolve({}));
  const handle = {
    exportPdf: (opts) => {
      calls.push(opts);
      return impl(opts);
    }
  };
  global.window = noFresco ? {} : {
    Fresco: { onReady: (id, cb) => { assert.strictEqual(id, "panel-export-1"); setTimeout(() => cb(handle), 0); } },
    Etcher: { layerFor: () => ({ isReady: () => Date.now() >= readyAt }) }
  };
  const downloads = [];
  global.URL = { createObjectURL: () => "blob:pdf", revokeObjectURL: () => {} };
  global.document = {
    body: { appendChild: () => {} },
    createElement: () => ({
      style: {},
      click() { downloads.push({ filename: this.download, href: this.href }); },
      remove() {}
    })
  };
  const sent = [];
  const hook = Object.create(hookDef);
  hook.el = { dataset: { frescoId: "panel-export-1", filename: "Q3 plan", seq: "1" } };
  hook.pushEventTo = (_t, name, payload) => sent.push({ name, payload });
  return { hook, sent, calls, downloads };
}

(async function () {
  // Exported once the layer has drawn, under the board's name.
  {
    const w = world({ layerReadyAfter: 250 });
    w.hook.mounted();
    await tick(100);
    assert.deepStrictEqual(w.calls, [], "not before the shapes are drawn");
    await tick(400);
    assert.deepStrictEqual(w.calls, [{ filename: "Q3 plan.pdf", download: false }]);
    assert.deepStrictEqual(w.sent, [
      { name: "export_started", payload: { seq: "1" } },
      { name: "export_done", payload: { ok: true, seq: "1", reason: null } }
    ]);
    assert.deepStrictEqual(w.downloads, [{ filename: "Q3 plan.pdf", href: "blob:pdf" }]);
    w.hook.destroyed();
  }

  // Rasterisation may finish after the host has timed out or changed place.
  // Fresco returns the blob without downloading; only a live hook saves it.
  {
    let resolve;
    const w = world({ exportPdf: () => new Promise((r) => { resolve = r; }) });
    w.hook.mounted();
    await tick(50);
    assert.deepStrictEqual(w.calls, [{ filename: "Q3 plan.pdf", download: false }]);
    w.hook.destroyed();
    resolve({});
    await tick();
    assert.deepStrictEqual(w.downloads, [], "no download after the export was taken down");
    assert.deepStrictEqual(w.sent.map((s) => s.name), ["export_started"]);
  }

  // A failed export is reported, once.
  {
    const w = world({ exportPdf: () => Promise.reject(new Error("tainted")) });
    w.hook.mounted();
    await tick(200);
    assert.deepStrictEqual(w.sent, [
      { name: "export_started", payload: { seq: "1" } },
      { name: "export_done", payload: { ok: false, seq: "1", reason: "tainted" } }
    ]);
    w.hook.destroyed();
  }

  // No viewer on the page: reported at once, never left hanging.
  {
    const w = world({ noFresco: true });
    w.hook.mounted();
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: false, seq: "1", reason: "viewer not loaded" } }]);
    w.hook.destroyed();
  }

  // A viewer too old to export.
  {
    const w = world();
    global.window.Fresco.onReady = (_id, cb) => cb({});
    w.hook.mounted();
    await tick(50);
    assert.deepStrictEqual(w.sent, [{ name: "export_done", payload: { ok: false, seq: "1", reason: "this viewer cannot export" } }]);
    w.hook.destroyed();
  }

  // Taken down before the layer was ready: it stops waiting and never
  // reports, so a late answer cannot land on the export after it.
  {
    const w = world({ layerReadyAfter: 300 });
    w.hook.mounted();
    await tick(100);
    w.hook.destroyed();
    await tick(400);
    assert.deepStrictEqual(w.calls, [], "no export after it was taken down");
    assert.deepStrictEqual(w.sent, [], "no report after it was taken down");
  }

  // Taken down after the layer is ready, before the frames run: no download.
  {
    const frames = [];
    const realFrame = global.requestAnimationFrame;
    global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
    try {
      const w = world({ layerReadyAfter: 0 });
      w.hook.mounted();
      await tick(0);
      assert.strictEqual(frames.length, 1, "the first frame is queued once the layer is ready");
      w.hook.destroyed();
      frames[0]();
      assert.strictEqual(frames.length, 1, "a destroyed export does not queue the next frame");
      assert.deepStrictEqual(w.calls, []);
      assert.deepStrictEqual(w.sent, []);
    } finally {
      global.requestAnimationFrame = realFrame;
    }
  }

  // And after the first frame has queued the second.
  {
    const frames = [];
    const realFrame = global.requestAnimationFrame;
    global.requestAnimationFrame = (f) => { frames.push(f); return frames.length; };
    try {
      const w = world({ layerReadyAfter: 0 });
      w.hook.mounted();
      await tick(0);
      frames[0]();
      assert.strictEqual(frames.length, 2);
      w.hook.destroyed();
      frames[1]();
      assert.deepStrictEqual(w.calls, []);
      assert.deepStrictEqual(w.sent, []);
    } finally {
      global.requestAnimationFrame = realFrame;
    }
  }

  // The 30s give-up is only for a layer that never gets ready. Once the
  // export starts it is cleared, and the server is told before exportPdf.
  {
    const realSet = global.setTimeout;
    const realClear = global.clearTimeout;
    const long = [];
    const cleared = [];
    global.setTimeout = (fn, ms, ...rest) => {
      const id = realSet(fn, ms, ...rest);
      if (ms === 30000) long.push(id);
      return id;
    };
    global.clearTimeout = (id) => {
      cleared.push(id);
      return realClear(id);
    };
    try {
      const w = world({ exportPdf: () => new Promise(() => {}) });
      w.hook.mounted();
      await tick(50);
      assert.strictEqual(long.length, 1);
      assert.ok(cleared.includes(long[0]), "the 30s give-up is cleared once export starts");
      assert.deepStrictEqual(w.sent.map((s) => s.name), ["export_started"]);
      assert.deepStrictEqual(w.calls, [{ filename: "Q3 plan.pdf", download: false }]);
      w.hook.destroyed();
    } finally {
      global.setTimeout = realSet;
      global.clearTimeout = realClear;
    }
  }

  // exportPdf throwing still reports, once, after the start.
  {
    const w = world({ exportPdf: () => { throw new Error("boom"); } });
    w.hook.mounted();
    await tick(50);
    assert.deepStrictEqual(w.sent, [
      { name: "export_started", payload: { seq: "1" } },
      { name: "export_done", payload: { ok: false, seq: "1", reason: "boom" } }
    ]);
    w.hook.destroyed();
  }

  // Same cleaning as BoardsPanel.pdf_filename/1. Keep the two in step.
  {
    const names = {
      "Q3 plan": "Q3 plan.pdf",
      "Q3 plan.pdf": "Q3 plan.pdf",
      "notes.PDF": "notes.pdf",
      "Q3: plan": "Q3_ plan.pdf",
      "a/b\\c*d?e\"f<g>h|i": "a_b_c_d_e_f_g_h_i.pdf",
      "Q3:\nplan": "Q3_plan.pdf",
      "   ": "board.pdf",
      "...": "board.pdf",
      "...hidden": "hidden.pdf",
      ".pdf": "board.pdf"
    };
    for (const [raw, expected] of Object.entries(names)) {
      const w = world({ layerReadyAfter: 0 });
      w.hook.el.dataset.filename = raw;
      w.hook.mounted();
      await tick(20);
      assert.deepStrictEqual(w.calls, [{ filename: expected, download: false }], raw);
      w.hook.destroyed();
    }
  }

  console.log("Panel export: all checks passed");
})().catch((e) => { console.error(e); process.exit(1); });
