// Pins the shim that delivers this module's hooks without host wiring.
//
// A hook used to have to be in the host's LiveSocket at construction time. It
// no longer does: LiveView resolves a hook name when its element mounts, and
// falls back to a `<script data-phx-runtime-hook="Name">` whose
// `window.phx_hook_Name()` returns the callbacks. That call is SYNCHRONOUS,
// so the shim has to hand back a hook object before the real bundle can
// possibly have loaded, and forward to it afterwards.
//
// Which makes the ordering the whole risk. An element can be gone before the
// bundle lands, and then `mounted` would attach listeners and timers nothing
// will ever tear down, or `destroyed` would run against a hook that never set
// any of it up. Those are the cases this pins.
//
//   node test/js/runtime_hook_test.js

const { execFileSync } = require("child_process");
const path = require("path");
const assert = require("assert");

const ROOT = path.join(__dirname, "..", "..");

// The shim is generated from Elixir, so it is taken from there rather than
// restated — a copy here would pass while the emitted one was broken.
const html = execFileSync(
  "mix",
  [
    "run",
    "--no-start",
    "-e",
    `IO.puts(Phoenix.LiveViewTest.rendered_to_string(PhoenixKitBoards.Web.RuntimeHooks.scripts(%{nonce: nil, __changed__: nil})))`
  ],
  { cwd: ROOT, encoding: "utf8", env: { ...process.env, MIX_QUIET: "1" } }
);

const bodies = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
assert.strictEqual(bodies.length, 2, `expected two hook scripts, got ${bodies.length}`);

// ── a stand-in for the browser ──────────────────────────────────────────────

function browser() {
  // `injected` is every script ever appended, kept append-only so a test can
  // index it by attempt number. `head.children` is what is actually in the
  // document right now, which is a different question once the shim starts
  // removing the ones that failed.
  const injected = [];
  const win = {};

  const head = {
    children: [],
    appendChild: (el) => {
      el.parentNode = head;
      head.children.push(el);
      injected.push(el);
    },
    removeChild: (el) => {
      const at = head.children.indexOf(el);
      if (at >= 0) head.children.splice(at, 1);
      el.parentNode = null;
    }
  };

  win.document = { head, createElement: () => ({}) };
  win.console = { error: () => {} };
  win.injected = injected;
  // Absent by default. The shim degrades to a plain message when `fetch` is
  // missing, and leaving it undefined keeps every other case off the network
  // — Node has a real `fetch` global that the emitted script would otherwise
  // reach straight past this stand-in and use.
  win.fetch = undefined;
  return win;
}

// Evaluate the emitted shim against that stand-in, the way the browser would.
// `fetch` is passed explicitly for the same reason as the rest: whatever the
// shim reaches for has to come from the stand-in, not from Node.
function install(win) {
  const fn = new Function("window", "document", "console", "fetch", bodies.join("\n"));
  fn(win, win.document, win.console, win.fetch);
}

// The real hook, as the bundle would define it.
function realHooks(log) {
  const record = (name, cb) =>
    function () {
      log.push(`${name}.${cb}`);
    };
  const hook = (name) => ({
    mounted: record(name, "mounted"),
    updated: record(name, "updated"),
    destroyed: record(name, "destroyed")
  });
  return { BoardSync: hook("BoardSync"), BoardCursors: hook("BoardCursors") };
}

const settle = () => new Promise((r) => setImmediate(r));

// ── the ordinary case ───────────────────────────────────────────────────────

(async () => {
  {
    const win = browser();
    install(win);

    assert.strictEqual(typeof win["phx_hook_BoardSync"], "function", "BoardSync registered");
    assert.strictEqual(typeof win["phx_hook_BoardCursors"], "function", "BoardCursors registered");

    // LiveView calls this synchronously and expects a hook object back — it
    // cannot wait for the bundle.
    const shim = win["phx_hook_BoardSync"]();
    assert.strictEqual(typeof shim.mounted, "function", "usable before anything has loaded");

    const log = [];
    const ctx = shim;
    shim.mounted.call(ctx);

    // One script requested, and nothing forwarded yet.
    assert.strictEqual(win.injected.length, 1, "asked for the bundle once");
    assert.deepStrictEqual(log, [], "nothing forwarded before it arrives");

    // The bundle lands.
    win.PhoenixKitBoardsHooks = realHooks(log);
    win.injected[0].onload();
    await settle();

    assert.deepStrictEqual(log, ["BoardSync.mounted"], "forwarded once it has");

    shim.updated.call(ctx);
    await settle();
    assert.deepStrictEqual(log, ["BoardSync.mounted", "BoardSync.updated"]);

    shim.destroyed.call(ctx);
    await settle();
    assert.deepStrictEqual(log, ["BoardSync.mounted", "BoardSync.updated", "BoardSync.destroyed"]);
  }

  // ── one request, however many hooks ───────────────────────────────────────

  {
    const win = browser();
    install(win);

    const a = win["phx_hook_BoardSync"]();
    const b = win["phx_hook_BoardCursors"]();
    a.mounted.call(a);
    b.mounted.call(b);

    assert.strictEqual(win.injected.length, 1, "both hooks share the one load");

    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    win.injected[0].onload();
    await settle();

    assert.deepStrictEqual(log.sort(), ["BoardCursors.mounted", "BoardSync.mounted"]);
  }

  // ── the element goes away before the bundle lands ─────────────────────────

  // Mounting then would attach listeners and timers to a dead element, and
  // nothing would ever tear them down.
  {
    const win = browser();
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    shim.destroyed.call(shim);

    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    win.injected[0].onload();
    await settle();

    assert.deepStrictEqual(log, [], "neither mounted nor destroyed ran");
  }

  // ── the bundle never arrives ──────────────────────────────────────────────

  // A board that cannot load its hooks is a board that does not collaborate.
  // It must still be usable, and must not leave callbacks pending forever.
  {
    const win = browser();
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    win.injected[0].onerror();
    await settle();

    // The failure has to SETTLE the load, not leave it pending — otherwise
    // every callback for the life of the page queues behind a promise that
    // will never resolve. Proven by giving it something to forward to
    // afterwards: it only arrives if the promise resolved.
    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    shim.updated.call(shim);
    await settle();

    assert.deepStrictEqual(log, ["BoardSync.updated"], "callbacks settle rather than hang");
  }

  // ── a failure is not permanent ────────────────────────────────────────────

  // Memoizing a failed load would turn one bad response — a blip, a restart
  // mid-deploy, a route that was misconfigured until a moment ago — into a tab
  // that stays non-collaborative until someone reloads it, and navigating
  // between boards would never retry.
  {
    const win = browser();
    install(win);

    const first = win["phx_hook_BoardSync"]();
    first.mounted.call(first);
    assert.strictEqual(win.injected.length, 1);
    win.injected[0].onerror();
    await settle();

    // The dead node goes with it. Retrying appends a fresh script each time,
    // so keeping the failures would leave a `<head>` full of tags for a file
    // that never arrived.
    assert.strictEqual(win.document.head.children.length, 0, "dead script removed");

    // A later mount asks again rather than reusing the failure.
    const second = win["phx_hook_BoardSync"]();
    second.mounted.call(second);
    assert.strictEqual(win.injected.length, 2, "retried on the next mount");

    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    win.injected[1].onload();
    await settle();

    assert.deepStrictEqual(log, ["BoardSync.mounted"], "and recovers");
    assert.strictEqual(win.document.head.children.length, 1, "the one that worked stayed");
  }

  // ── what a failure says ───────────────────────────────────────────────────

  // A script element's error event carries no status, so the shim refetches to
  // find out. The status is the whole diagnostic value — a 403 from CSRF's
  // cross-origin-script guard is obvious the moment the number is on screen
  // and baffling until then.
  {
    const win = browser();
    const errors = [];
    win.console = { error: (msg) => errors.push(msg) };
    win.fetch = () => Promise.resolve({ status: 403, ok: false });
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    win.injected[0].onerror();
    await settle();
    await settle();

    assert.strictEqual(errors.length, 1, `one message, got: ${errors.join(" | ")}`);
    assert.ok(/HTTP 403/.test(errors[0]), `no status: ${errors[0]}`);
    assert.ok(/forgery protection/.test(errors[0]), `no cause named: ${errors[0]}`);

    // And specifically NOT the "loaded but defined no hooks" line: the bundle
    // did not load at all, so that message contradicts this one. `forward`
    // reaches that branch on every failure — it is only silent because the
    // error path claims the once-per-page warning.
    shim.updated.call(shim);
    await settle();
    assert.strictEqual(errors.length, 1, `contradicted itself: ${errors.join(" | ")}`);
  }

  // ── a failure the status cannot explain ───────────────────────────────────

  // The refetch succeeding means the URL and the response are both fine and
  // something stopped the browser executing the script — a CSP, usually. A
  // bare "(HTTP 200)" on a line that says it could not load reads as a
  // contradiction rather than as the clue it is.
  {
    const win = browser();
    const errors = [];
    win.console = { error: (msg) => errors.push(msg) };
    win.fetch = () => Promise.resolve({ status: 200, ok: true });
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    win.injected[0].onerror();
    await settle();
    await settle();

    assert.ok(/HTTP 200/.test(errors[0]), `no status: ${errors[0]}`);
    assert.ok(/Content-Security-Policy/.test(errors[0]), `no cause named: ${errors[0]}`);
  }

  // ── no fetch to refetch with ──────────────────────────────────────────────

  {
    const win = browser();
    const errors = [];
    win.console = { error: (msg) => errors.push(msg) };
    install(win);  // `win.fetch` is undefined

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    win.injected[0].onerror();
    await settle();

    assert.strictEqual(errors.length, 1, "still says something");
    assert.ok(/could not load/.test(errors[0]), `unhelpful message: ${errors[0]}`);
  }

  // ── an already-loaded bundle ──────────────────────────────────────────────

  // A host that DOES run the compiler has the hooks in its LiveSocket, which
  // LiveView prefers — but if this shim is reached anyway it must not fetch a
  // bundle that is already there.
  {
    const win = browser();
    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    await settle();

    assert.strictEqual(win.injected.length, 0, "no request when it is already loaded");
    assert.deepStrictEqual(log, ["BoardSync.mounted"], "and it still forwards");
  }

  // ── the request is answered by something that isn't the bundle ────────────

  // An auth redirect resolving to a login page, a proxy error page, a CSP
  // that blocked it: the script "loads" and defines nothing. That is the
  // silent single-player state this whole mechanism exists to remove, so it
  // has to say so — once, not per callback.
  {
    const win = browser();
    const errors = [];
    win.console = { error: (msg) => errors.push(msg) };
    install(win);

    const shim = win["phx_hook_BoardSync"]();
    shim.mounted.call(shim);
    win.injected[0].onload();  // resolves, but nothing was defined
    await settle();

    assert.strictEqual(errors.length, 1, "said so");
    assert.ok(/defined no hooks/.test(errors[0]), `unhelpful message: ${errors[0]}`);

    // Not once per callback, and not once per hook.
    shim.updated.call(shim);
    const other = win["phx_hook_BoardCursors"]();
    other.mounted.call(other);
    await settle();
    assert.strictEqual(errors.length, 1, "and only once");
  }

  // ── a bundle without the hook in it ───────────────────────────────────────

  {
    const win = browser();
    install(win);

    const shim = win["phx_hook_BoardCursors"]();
    shim.mounted.call(shim);
    win.PhoenixKitBoardsHooks = { BoardSync: {} };
    win.injected[0].onload();
    await settle();  // must not throw
  }

  console.log("runtime hook: all checks passed");
})();
