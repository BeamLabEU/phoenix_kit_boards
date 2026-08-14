// Pins the upload watchdog: 15 s of silence during the transfer, and a much
// longer budget once the bytes have arrived and the server is storing them.
//
// `handle_image_progress` used to consume the entry and write to storage
// inside the `done?` branch. `push_event` only flushes when that callback
// returns, so the client saw silence for the whole hash + bucket write. The
// watchdog is 15 s of silence — a video at the 256 MB cap trips it, the
// client embeds the bytes, and the board gets heavier, which is the failure
// the upload path exists to prevent.
//
// The LiveView now pushes progress 100 and returns before it stores. 100%
// means "bytes arrived, now storing" and must rearm for the long budget,
// not the transfer one.
//
//   node test/js/upload_watchdog_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"
);
const src = fs.readFileSync(SOURCE, "utf8");

assert.match(src, /const UPLOAD_SILENCE_MS = 15000/);
assert.match(src, /const UPLOAD_STORING_MS = 5 \* 60 \* 1000/);

global.UPLOAD_SILENCE_MS = 15000;
global.UPLOAD_STORING_MS = 5 * 60 * 1000;
global.sameKeys = () => true;

const delays = [];
global.setTimeout = (_fn, ms) => {
  delays.push(ms);
  return delays.length;
};
global.clearTimeout = () => {};

const start = src.indexOf("  const BoardSync = {");
assert.notStrictEqual(start, -1, "could not find BoardSync");
const end = src.indexOf("\n  };", start);
assert.notStrictEqual(end, -1, "could not find the end of BoardSync");
const BoardSync = eval(
  "(" + src.slice(start + "  const BoardSync = ".length, end + "\n  }".length) + ")"
);

function makeHook() {
  const hook = Object.create(BoardSync);
  hook.frescoId = "board-canvas";
  hook.handlers = {};
  hook.el = {
    dataset: { frescoId: "board-canvas" },
    addEventListener() {},
    removeEventListener() {}
  };
  hook.pushEvent = () => {};
  hook.handleEvent = (name, fn) => { hook.handlers[name] = fn; };
  hook.layer = () => ({
    selectTool() {},
    getMode() { return true; },
    setMode() {},
    setImageUploader() {},
    setLinkUnfurler() {}
  });
  return hook;
}

const hook = makeHook();
try { BoardSync.mounted.call(hook); } catch (_) {}

hook.pendingUploads = [{
  settled: false,
  onProgress: null,
  timer: null,
  resolve() {},
  reject() {}
}];

delays.length = 0;
hook.handlers["board:image-progress"]({ progress: 40 });
assert.deepStrictEqual(delays, [15000], "mid-transfer silence stays at 15s");

delays.length = 0;
hook.handlers["board:image-progress"]({ progress: 100 });
assert.deepStrictEqual(
  delays,
  [5 * 60 * 1000],
  "100% means the server is storing — five minutes, not 15 seconds"
);

// A timed-out slot is a tombstone. Rearming it would hide the pairing-by-order
// rule `settleUpload` exists for.
hook.pendingUploads[0].settled = true;
delays.length = 0;
hook.handlers["board:image-progress"]({ progress: 100 });
assert.deepStrictEqual(delays, [], "a tombstone is not rearmed");

console.log("ok - upload watchdog");
