// The widget's paste behaviour: when it listens, and what it asks for.
//
//   node test/js/panel_paste_test.js

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "boards_panel_paste.js"),
  "utf8"
);
const hookDef = eval(src);

function editableNode() {
  return { isContentEditable: false, closest: (sel) => (/textarea|input/.test(sel) ? {} : null) };
}
const plainNode = { isContentEditable: false, closest: () => null };

function mount(dataset) {
  const listeners = {};
  const sent = [];
  const uploadInput = { dataset: { phxActiveRefs: "" } };
  const el = {
    dataset: { paste: "on", pasteImages: "on", pasteText: "on", ...dataset },
    addEventListener: (n, f) => { listeners[n] = f; },
    removeEventListener: (n) => { delete listeners[n]; },
    contains: () => false,
    querySelector: () => uploadInput,
    focus: () => { el.focused = true; }
  };
  const hook = Object.create(hookDef);
  hook.el = el;
  hook.pushEventTo = (_t, name, payload) => sent.push({ kind: "push", name, payload });
  hook.uploadTo = (_t, name, files) => sent.push({ kind: "upload", name, files });
  hook.mounted();
  return { el, hook, listeners, sent, uploadInput };
}

function paste(target, { files = [], text = "" } = {}) {
  let prevented = false;
  return {
    target,
    clipboardData: { files, getData: (t) => (t === "text/plain" ? text : "") },
    preventDefault: () => { prevented = true; },
    get prevented() { return prevented; }
  };
}

const png = { type: "image/png", name: "a.png" };

// Text alone → a note.
let m = mount();
let e = paste(plainNode, { text: "buy milk" });
m.listeners.paste(e);
assert.deepStrictEqual(m.sent, [{ kind: "push", name: "paste_text", payload: { text: "buy milk" } }]);
assert.ok(e.prevented, "a paste that was taken is not also pasted into the page");

// Images → context first, then the upload; the text rides along.
m = mount();
e = paste(plainNode, { files: [png, png], text: "tiles" });
m.listeners.paste(e);
assert.deepStrictEqual(m.sent.map((s) => s.name), ["paste_context", "quick_image"]);
assert.strictEqual(m.sent[0].payload.text, "tiles");
assert.strictEqual(m.sent[1].files.length, 2);
assert.ok(e.prevented);

// A second image paste waits, even before the first upload is registered.
m = mount();
m.listeners.paste(paste(plainNode, { files: [png], text: "first" }));
m.listeners.paste(paste(plainNode, { files: [png], text: "second" }));
assert.deepStrictEqual(m.sent.map((s) => s.name), ["paste_context", "quick_image"]);
m.hook.updated();
assert.strictEqual(m.sent.length, 2, "a context-only patch cannot release the next paste");
m.uploadInput.dataset.phxActiveRefs = "first-ref";
m.hook.updated();
m.uploadInput.dataset.phxActiveRefs = "";
m.hook.updated();
assert.deepStrictEqual(m.sent.map((s) => s.name), ["paste_context", "quick_image", "paste_context", "quick_image"]);
assert.strictEqual(m.sent[0].payload.text, "first");
assert.strictEqual(m.sent[2].payload.text, "second");

// A picker/drop upload already in flight is also a separate collection.
m = mount();
m.uploadInput.dataset.phxActiveRefs = "picker-ref";
m.listeners.paste(paste(plainNode, { files: [png], text: "queued" }));
assert.strictEqual(m.sent.length, 0);
m.uploadInput.dataset.phxActiveRefs = "";
m.hook.updated();
assert.strictEqual(m.sent[0].payload.text, "queued");

// Pending clipboard data cannot follow a widget to another user/place.
m = mount({ pasteContext: "old" });
m.listeners.paste(paste(plainNode, { files: [png], text: "old first" }));
m.listeners.paste(paste(plainNode, { files: [png], text: "old pending" }));
m.el.dataset.pasteContext = "new";
m.hook.updated();
assert.deepStrictEqual(m.hook.imageQueue, []);
assert.strictEqual(m.sent.length, 2, "queued images were discarded on context change");

// Only images count; other files are left alone.
m = mount();
m.listeners.paste(paste(plainNode, { files: [{ type: "application/pdf" }] }));
assert.deepStrictEqual(m.sent, [], "a pdf is not a board");

// At most eight pictures.
m = mount();
m.listeners.paste(paste(plainNode, { files: Array(12).fill(png) }));
assert.strictEqual(m.sent[1].files.length, 8);

// Typing in a field inside the widget is never intercepted.
m = mount();
e = paste(editableNode(), { text: "I am writing a note" });
m.listeners.paste(e);
assert.deepStrictEqual(m.sent, []);
assert.ok(!e.prevented, "the field gets its paste");

// Switched off, or not offered: nothing.
m = mount({ paste: "off" });
m.listeners.paste(paste(plainNode, { text: "x", files: [png] }));
assert.deepStrictEqual(m.sent, []);

m = mount({ pasteImages: "off" });
m.listeners.paste(paste(plainNode, { files: [png] }));
assert.deepStrictEqual(m.sent, [], "no picture upload where images are not offered");

m = mount({ pasteText: "off" });
e = paste(plainNode, { text: "words" });
m.listeners.paste(e);
assert.deepStrictEqual(m.sent, []);
assert.ok(!e.prevented);

// Nothing useful on the clipboard: left alone.
m = mount();
e = paste(plainNode, { text: "   \n" });
m.listeners.paste(e);
assert.deepStrictEqual(m.sent, []);
assert.ok(!e.prevented);

// A click in the widget makes it the active one (for browsers that do not
// focus a clicked button) — but not when the click lands in a field.
const timers = [];
global.setTimeout = (fn) => timers.push(fn);
global.document = { activeElement: null };
m = mount();
m.listeners.pointerdown({ target: plainNode });
timers.shift()();
assert.ok(m.el.focused, "the widget takes focus after a click that focused nothing");

// ...and one that already put focus inside it is not disturbed.
m = mount();
m.el.contains = () => true;
m.listeners.pointerdown({ target: plainNode });
timers.shift()();
assert.ok(!m.el.focused, "focus already inside the widget stays where it is");

m = mount();
m.listeners.pointerdown({ target: editableNode() });
assert.strictEqual(timers.length, 0, "a click into a field is left to the field");

// Torn down cleanly.
m = mount();
m.hook.destroyed();
assert.deepStrictEqual(Object.keys(m.listeners), []);

console.log("panel_paste: ok");
