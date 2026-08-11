// Pins the join handshake between the hooks and the LiveView.
//
// Anything a LiveView pushes from its connected mount rides the join reply and
// is dispatched the moment it lands. That was safe while hooks were registered
// on the host's LiveSocket at construction time — `mounted` had already run.
// Under this module's runtime-hook delivery it is a race that is always lost:
// the shim's `mounted` starts a ~40 KB fetch, and the real hook's
// `handleEvent` registrations do not exist until it resolves.
//
// The result was a board that rendered, edited and saved while cursors, live
// drags and stored preferences never appeared — the channel token and the
// prefs had both been dispatched to nobody. A host log showed twelve
// successful bundle fetches and zero BoardSocket connections.
//
// So the hooks announce themselves and the server answers. What has to hold:
// every handler is registered BEFORE the ping goes out, and both hooks ping,
// since either may mount last.
//
//   node test/js/ready_handshake_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_boards.js"
);
const src = fs.readFileSync(SOURCE, "utf8");

function hookLiteral(name) {
  const start = src.indexOf(`  const ${name} = {`);
  assert.notStrictEqual(start, -1, `could not find ${name}`);
  const end = src.indexOf("\n  };", start);
  assert.notStrictEqual(end, -1, `could not find the end of ${name}`);
  return src.slice(start + `  const ${name} = `.length, end + "\n  }".length);
}

// Everything the hooks close over. Only shapes the mounts touch are modelled.
global.sameKeys = () => true;
global.now_ = () => 0;
global.CURSOR_SEND_MS = 25;
global.CURSOR_GLIDE_MS = 24;
global.CURSOR_MIN_GLIDE_MS = 16;
global.CURSOR_MAX_GLIDE_MS = 250;
global.CURSOR_STALE_GAP_MS = 500;
global.escapeHtml = (s) => s;
global.escapeAttr = (s) => s;
global.BoardLink = { ensure: () => null, get: () => null, on: () => {}, push: () => false, close: () => {} };
global.window = { Etcher: undefined, Fresco: undefined };
global.document = { createElement: () => ({ style: {}, querySelector: () => ({}) }) };
global.setTimeout = () => 1;
global.clearTimeout = () => {};
global.setInterval = () => 1;
global.clearInterval = () => {};
global.requestAnimationFrame = () => 1;
global.cancelAnimationFrame = () => {};

const BoardSync = eval("(" + hookLiteral("BoardSync") + ")");
const BoardCursors = eval("(" + hookLiteral("BoardCursors") + ")");

// A hook instance that records the ORDER of handler registrations and pushes,
// which is the whole question here.
function mount(hookLiteralObj) {
  const events = [];
  const hook = Object.create(hookLiteralObj);

  hook.frescoId = "board-canvas";
  hook.el = {
    dataset: { frescoId: "board-canvas" },
    addEventListener: () => {},
    removeEventListener: () => {},
    parentElement: { addEventListener: () => {}, removeEventListener: () => {} }
  };
  hook.handleEvent = (name) => events.push({ kind: "handle", name });
  hook.pushEvent = (name) => events.push({ kind: "push", name });
  hook.upload = () => {};

  try {
    hookLiteralObj.mounted.call(hook);
  } catch (error) {
    assert.fail(`mounted threw: ${error && error.message}`);
  }

  return events;
}

// ── both hooks announce themselves ──────────────────────────────────────────

for (const [name, literal] of [["BoardSync", BoardSync], ["BoardCursors", BoardCursors]]) {
  const events = mount(literal);
  const pings = events.filter((e) => e.kind === "push" && e.name === "board:ready");

  assert.strictEqual(pings.length, 1, `${name} should ping exactly once, got ${pings.length}`);
}

// ── the ping is the LAST thing, after every handler ──────────────────────────

// The point of the ping is that the reply has somewhere to land. A handler
// registered after it is a handler the reply can still outrun.
for (const [name, literal] of [["BoardSync", BoardSync], ["BoardCursors", BoardCursors]]) {
  const events = mount(literal);
  const pingAt = events.findIndex((e) => e.kind === "push" && e.name === "board:ready");
  const lastHandlerAt = events.map((e) => e.kind).lastIndexOf("handle");

  assert.ok(pingAt > -1, `${name} never pinged`);
  assert.ok(
    lastHandlerAt < pingAt,
    `${name} registers a handler AFTER announcing itself — the reply can outrun it`
  );
}

// ── the events the reply carries are handled ────────────────────────────────

// Named explicitly: these two are what the mount used to push and what the
// handshake exists to deliver.
{
  const sync = mount(BoardSync).filter((e) => e.kind === "handle").map((e) => e.name);
  const cursors = mount(BoardCursors).filter((e) => e.kind === "handle").map((e) => e.name);
  const handled = new Set([...sync, ...cursors]);

  for (const event of ["board:prefs", "board:channel"]) {
    assert.ok(handled.has(event), `nothing handles ${event}, so the ready reply is lost again`);
  }
}

// ── the server no longer pushes at mount ────────────────────────────────────

// The other half of the fix, and the half a JS test can still see: if the
// LiveView goes back to pushing from `mount_connected`, this race returns for
// every host on runtime-hook delivery.
{
  const live = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_boards", "web", "board_live.ex"),
    "utf8"
  );

  const mountBody = live.slice(
    live.indexOf("defp mount_connected"),
    live.indexOf("defp migrate_embedded_images")
  );

  assert.ok(mountBody.length > 0, "could not isolate mount_connected");
  assert.ok(
    !mountBody.includes("push_event("),
    "mount_connected pushes an event again — under runtime-hook delivery nothing is listening yet"
  );
  assert.ok(
    live.includes('def handle_event("board:ready"'),
    "the ready handler is gone"
  );
}

console.log("ready handshake: all checks passed");
