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
  const injected = [];
  const win = {};

  win.document = {
    head: { appendChild: (el) => injected.push(el) },
    createElement: () => ({})
  };

  win.console = { error: () => {} };
  win.injected = injected;
  return win;
}

// Evaluate the emitted shim against that stand-in, the way the browser would.
function install(win) {
  const fn = new Function("window", "document", "console", bodies.join("\n"));
  fn(win, win.document, win.console);
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

    // A later mount asks again rather than reusing the failure.
    const second = win["phx_hook_BoardSync"]();
    second.mounted.call(second);
    assert.strictEqual(win.injected.length, 2, "retried on the next mount");

    const log = [];
    win.PhoenixKitBoardsHooks = realHooks(log);
    win.injected[1].onload();
    await settle();

    assert.deepStrictEqual(log, ["BoardSync.mounted"], "and recovers");
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
