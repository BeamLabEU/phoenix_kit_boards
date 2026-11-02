// A pasted link's preview is asked for and answered as two events, paired by
// `ref`, so the server can fetch the page without holding the board.
//
//   node test/js/unfurl_pairing_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"),
  "utf8"
);
const start = src.indexOf("  const BoardSync = {");
const end = src.indexOf("\n  };", start);
global.UNFURL_TIMEOUT_MS = 25000;
const BoardSync = eval("(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")");

const timers = [];
global.setTimeout = (fn) => { timers.push(fn); return timers.length; };
global.clearTimeout = (id) => { if (id) timers[id - 1] = null; };

function hook() {
  const hk = Object.create(BoardSync);
  hk.pushed = [];
  hk.pushEvent = (name, payload) => hk.pushed.push({ name, payload });
  return hk;
}

(async () => {
  const hk = hook();
  const a = hk.unfurl("https://a.example");
  const b = hk.unfurl("https://b.example");

  assert.strictEqual(hk.pushed.length, 2);
  assert.ok(hk.pushed.every((p) => p.name === "board:unfurl" && p.payload.ref), "each ask carries a ref");
  assert.notStrictEqual(hk.pushed[0].payload.ref, hk.pushed[1].payload.ref);
  assert.ok(hk.pushed.every((p) => p.payload.ref.length <= 64), "the server's ref bound");

  // Answered out of order: each paste gets its own card.
  hk.unfurls[hk.pushed[1].payload.ref]({ ref: hk.pushed[1].payload.ref, svg: "<svg B/>" });
  hk.unfurls[hk.pushed[0].payload.ref]({ ref: hk.pushed[0].payload.ref, error: "blocked" });
  assert.strictEqual((await b).svg, "<svg B/>");
  await assert.rejects(a, (e) => e === "blocked");
  assert.deepStrictEqual(Object.keys(hk.unfurls), [], "answered asks are forgotten");

  // No answer: gives up on its own.
  const c = hook();
  const slow = c.unfurl("https://slow.example");
  timers.filter(Boolean).pop()();
  await assert.rejects(slow, (e) => /timed out/.test(e));

  // Closing the board settles what is still waiting.
  const d = hook();
  d.flushView = () => {};
  d.viewOff = [];
  global.BoardLink = { close: () => {} };
  global.window = { removeEventListener: () => {} };
  const pending = d.unfurl("https://x.example");
  d.destroyed();
  await assert.rejects(pending, (e) => e === "board closed");

  console.log("unfurl_pairing: ok");
})().catch((e) => { console.error(e); process.exit(1); });
