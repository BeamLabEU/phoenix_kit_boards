const fs = require("fs");
const path = require("path");
const assert = require("assert");
const hookDef = eval(fs.readFileSync(
  path.join(__dirname, "../../priv/static/assets/boards_panel_viewer.js"), "utf8"
));

class FrameWindow extends EventTarget {
  constructor() { super(); this.document = {}; }
}

function key(target, key = "Escape", consumed = false, tagName = "DIV") {
  const event = new Event("keydown", { cancelable: true });
  event.key = key;
  // EventTarget has no DOM ancestors; describe the focused child explicitly.
  Object.defineProperty(event, "target", { value: { tagName } });
  if (consumed) event.preventDefault();
  target.dispatchEvent(event);
}

const sent = [];
const frame = new EventTarget();
frame.contentWindow = new FrameWindow();
const hook = Object.assign(Object.create(hookDef), {
  el: frame,
  pushEventTo: (el, event, payload) => {
    assert.strictEqual(el, frame);
    sent.push({ event, payload });
  }
});
hook.mounted();
key(frame.contentWindow, "Enter");
key(frame.contentWindow, "Escape", true); // Etcher cancelled a draft or selection.
key(frame.contentWindow, "Escape", false, "INPUT");
key(frame.contentWindow, "Escape", false, "TEXTAREA");
assert.deepStrictEqual(sent, []);
key(frame.contentWindow);
assert.deepStrictEqual(sent, [{ event: "close_board", payload: {} }]);

// Navigating/reloading the embedded board replaces its listeners.
const oldWindow = frame.contentWindow;
frame.contentWindow = new FrameWindow();
frame.dispatchEvent(new Event("load"));
key(oldWindow);
assert.strictEqual(sent.length, 1);
key(frame.contentWindow);
assert.strictEqual(sent.length, 2);

// Repeated loads never double-subscribe, and removal detaches everything.
frame.dispatchEvent(new Event("load"));
key(frame.contentWindow);
assert.strictEqual(sent.length, 3);
hook.destroyed();
key(frame.contentWindow);
frame.dispatchEvent(new Event("load"));
key(frame.contentWindow);
assert.strictEqual(sent.length, 3);

// A redirect to another origin must leave the parent close button usable.
Object.defineProperty(frame, "contentWindow", {
  get() { throw new Error("cross-origin access"); }
});
assert.doesNotThrow(() => hook.mounted());
assert.doesNotThrow(() => hook.destroyed());
console.log("Panel viewer: all checks passed");
