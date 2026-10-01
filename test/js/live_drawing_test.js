const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

function board() {
  const timers = new Map();
  let timerId = 0;
  const channel = {
    joined: true, sent: [], buffered: [],
    canPush() { return socket.connected && this.joined; },
    join() {
      return { receive(event, callback) { if (event === "ok") callback(); return this; } };
    },
    push(event, payload) {
      (this.canPush() ? this.sent : this.buffered).push([event, payload]);
    },
    leave() {}
  };
  const socket = {
    connected: true, connect() {}, disconnect() {},
    isConnected() { return this.connected; },
    channel() { return channel; }
  };
  const calls = [];
  const layer = {
    onDrawing() {}, onShapesMoving() {},
    applyDrawing(id, draft) { calls.push(["drawing", id, draft]); },
    applyDrawingEnd(id) { calls.push(["end", id]); }
  };
  const window = {
    Phoenix: { Socket: function () { return socket; } },
    Etcher: { layerFor: () => layer }
  };
  const source = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_boards.js"), "utf8");
  // Expose the private connection manager from the shipped bundle.
  vm.runInNewContext(source.replace("  window.PhoenixKitBoardsHooks = Object.assign", "  window.testBoardLink = BoardLink;\n  window.PhoenixKitBoardsHooks = Object.assign"), {
    window,
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  const hook = Object.create(window.PhoenixKitBoardsHooks.BoardSync);
  hook.frescoId = "canvas";
  hook.openLink({ token: "token", topic: "board:uuid" });
  const receive = (event, payload) => channel.onMessage(event, payload);
  return { hook, link: window.testBoardLink, socket, channel, calls, timers, receive };
}

// An open transport can still have an errored/rejoining channel. Phoenix
// buffers pushes in that state; an old successful join is insufficient.
{
  const b = board();
  b.channel.joined = false;
  for (const event of ["cursor", "moving", "moved", "drawing", "drawn"]) {
    assert.strictEqual(b.link.push("canvas", event, {}), false, `${event} must be dropped during rejoin`);
  }
  assert.strictEqual(b.channel.buffered.length, 0, "nothing is queued for replay");
  b.channel.joined = true;
  assert.strictEqual(b.link.push("canvas", "drawing", {}), true, "stream resumes after rejoin");
  b.socket.connected = false;
  assert.strictEqual(b.link.push("canvas", "drawing", {}), false, "transport loss also drops frames");
}

const draft = { kind: "marker", geometry: { points: [[1, 2]] } };
{
  const b = board();
  b.receive("drawing", { id: "peer", stroke: 0, draft });
  const firstTimer = [...b.timers.keys()][0];
  b.receive("drawing", { id: "peer", stroke: 0, draft });
  assert.ok(!b.timers.has(firstTimer), "each frame renews the silence timeout");
  assert.strictEqual(b.timers.size, 1);
  [...b.timers.values()][0]();
  assert.strictEqual(b.calls.at(-1)[0], "end", "silence retires an abandoned stroke");
}
{
  const b = board();
  b.receive("drawing", { id: "peer", stroke: 2, draft });
  b.receive("drawing", { id: "peer", stroke: 1, draft });
  assert.strictEqual(b.calls.length, 1, "older frames are ignored even before their end arrives");
  b.receive("drawn", { id: "peer", stroke: 1 });
  assert.strictEqual(b.calls.length, 1, "an old end cannot retire a newer stroke");
  b.receive("drawing", { id: "peer", stroke: 0, draft });
  assert.strictEqual(b.calls.length, 1, "old frames cannot replace the newer stroke");
  b.receive("drawn", { id: "peer", stroke: 2 });
  assert.strictEqual(b.calls.at(-1)[0], "end");
  assert.strictEqual(b.timers.size, 0);
  const count = b.calls.length;
  b.receive("drawing", { id: "peer", stroke: 2, draft });
  assert.strictEqual(b.calls.length, count, "finished strokes stay finished");
  b.receive("drawing", { id: "peer", stroke: 3, draft });
  assert.strictEqual(b.calls.at(-1)[0], "drawing", "the next stroke can start");
}
{
  const b = board();
  b.receive("drawing", { id: "legacy", draft });
  b.receive("drawn", { id: "legacy" });
  assert.strictEqual(b.calls.at(-1)[0], "end", "unnumbered older clients still work");
}
{
  const b = board();
  b.receive("drawing", { id: "peer", stroke: 0, draft });
  b.hook.destroyed();
  assert.strictEqual(b.timers.size, 0, "closing the board cancels all ghost timers");
  assert.strictEqual(b.calls.at(-1)[0], "end", "closing also retires the ghost");
}
console.log("live drawing: all checks passed");
