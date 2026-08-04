# PR #2 Review — Board images to storage, link previews, and z-order sync fixes

**Reviewer:** Claude | **Date:** 2026-08-04 | **Verdict:** Approve with fixes
applied post-merge.

The four threads of this PR are each the right call, and the z-order and
migration fixes are genuinely good catches — both were silent failures that
would have been miserable to diagnose from a bug report. The reasoning in the
comments is unusually careful and mostly correct.

The problems are concentrated in one place: **`LinkPreview` is the first code
in this repo that makes the server fetch a URL a user supplied**, and it is not
yet as careful as its own moduledoc claims. Two of its three guards are
narrower than advertised, and the whole thing runs unrescued in the LiveView
process. Everything found is fixed below.

## Scope of what we reviewed

The full merge diff (`git show a636904 -m --first-parent`) with surrounding
context: `board_live.ex` in full, the new `link_preview.ex`, `migrations.ex`,
the JS hook bundle, and both new test files. Claims were checked against the
producing code rather than the descriptions — `deps/etcher`'s README, CHANGELOG
and `etcher.js` for the client-side contracts, `deps/req` for what its options
actually do, `deps/open_fresco` for the Scene API and its escaping, and
`deps/phoenix_kit`'s `Modules.Storage` for the upload path.

---

## What we fixed ourselves

### `BUG - HIGH` — the hero-image fetch follows redirects straight past the SSRF guard *(fixed)*

The moduledoc says the address check runs "again on each redirect, because a
public host is free to redirect to a private one". That is true of `fetch/1`,
which sets `redirect: false` and walks hops by hand. It was not true of
`fetch_image/1`, the sibling that fetches the `og:image`:

```elixir
Req.get(URI.to_string(uri), receive_timeout: @timeout_ms, max_retries: 0)
```

Req's `:redirect` option **defaults to `true`** (`Req.Steps.redirect/1`, up to
10 hops). So the guard checked the first address and then followed a `Location`
header anywhere — including into the private range it exists to keep out. An
`og:image` is exactly as attacker-controlled as the page it came from: put
`<meta property="og:image" content="https://attacker.example/x">` on any page,
302 that to `http://169.254.169.254/…`, and the request is made from inside the
server's network. Any response whose content-type starts with `image/` is then
base64-inlined into the SVG handed back to the user who pasted the link.

Two more consequences of the same line:

- With redirects enabled, exceeding `max_redirects` makes Req **raise**
  (`RuntimeError: too many redirects`) rather than return an error — see the
  next finding for why that mattered.
- `@max_bytes` was checked against `byte_size(body)` *after* Req had already
  buffered the whole response, so the size cap did not bound memory at all.

**Fix:** the two fetchers were collapsed into a single guarded `walk/3`. They
differed only in the headers they send and what they do with a 200, and that
is now all `fetch/3` and `fetch_image/3` supply; `redirect: false`, the
per-hop `safe_uri/1` check and the body cap live in one place. Making them
mirror each other would have fixed the bug; making there be only one of them
is what stops it recurring — two hand-written copies of a guard is exactly how
one of them came to be missing it. The moduledoc gained a sentence saying the
hero goes through the same walk, since the wrong belief was already written
down there.

### `BUG - HIGH` — an unfurl that raises takes the whole board down *(fixed)*

`LinkPreview.unfurl/1` was called straight from `handle_event/3` with nothing
around it. The design contract is stated plainly in the same comment — "the
link is already on the canvas as text" — but the code did not enforce it.
Untrusted input reaches every step: Req (raising on too many redirects, per
above, or on a URL it won't accept), `Floki.parse_document/1`, and
`OpenFresco.render_svg/2` on a scene built from strings off somebody else's
page. Any raise kills the LiveView, and the user loses their board view and
reconnects — for a failed link preview.

**Fix:** extracted `unfurl_reply/1` with a `rescue` that logs and answers
`%{"error" => "unfurl_failed"}`, which is the same thing Etcher does with any
rejection: leave the URL as text.

### `BUG - MEDIUM` — the 2MB page cap ran after the whole body was in memory *(fixed)*

`ensure_small_enough/1` checked `byte_size(body)` on a response Req had already
read in full, so a URL serving multiple GB cost multiple GB in the LiveView
process before being rejected. The moduledoc lists "a page of arbitrary size
buffered into memory" among the things the cap prevents.

**Fix:** both fetchers now pass `into: capped_into()`, a collector that
accumulates and returns `{:halt, …}` the moment the body crosses `@max_bytes`,
dropping the connection there. `ensure_small_enough/1` turned into the place a
halted stream becomes `{:error, :too_large}`.

One thing worth knowing before touching this again: streaming disables Req's
`decompress_body` step. That is safe *only* because the `compressed` step also
skips setting `accept-encoding` when `:into` is set, so a server has no reason
to send an encoding that would arrive undecoded. Both halves are in
`Req.Steps`; don't change one without the other.

### `BUG - MEDIUM` — the storage short-circuit skips core's self-healing dedupe *(fixed)*

```elixir
case Storage.get_file_by_user_checksum(...) do
  nil -> ... Storage.store_file_in_buckets(...)
  existing -> {:ok, existing}
end
```

`store_file_in_buckets/6` performs that exact same per-user lookup itself — but
on a hit it does more than return the row. It checks the object is *still in
the bucket* (`verify_file_in_storage/1`) and calls `restore_missing_file/5` or
`recreate_file_instances/5` when it isn't. The pre-check here returned the row
before any of that ran, so once an object went missing from storage — bucket
lifecycle rule, manual cleanup, a failed multipart — every subsequent paste of
that image would hand back a URL to a 404, permanently, with no way to heal it.

**Fix:** dropped the pre-check; `store/4` calls `store_file_in_buckets/6`
unconditionally. The dedupe behaviour is unchanged (core does it), the repair
behaviour is restored, and the function got shorter. The `normalize_stored/1`
comment lost its inaccurate rationale — it claimed the pre-check "doesn't catch
that, since it keys on the user", but core keys on the user identically; the
3-tuple flattening is still needed, just for a simpler reason.

### `BUG - MEDIUM` — the upload extension came only from the filename *(fixed)*

The `@image_accept` comment explains that MIME types are listed alongside
extensions because "a file off the clipboard is not guaranteed to arrive with a
usable filename, but it always carries a type" — and then the code derived the
stored object's extension from `Path.extname(entry.client_name)` alone. An
entry with no usable name stored with `ext: ""`, which is what names the object
and decides how it is served back.

**Fix:** `ext_for/1` falls back to `MIME.extensions(entry.client_type)` when
the filename has nothing to give. The accept list is the reason this can't
produce a surprise: `client_type` is always one of the four allowed types.

### `BUG - MEDIUM` (JS) — a late reply after a watchdog timeout settles the wrong upload *(fixed)*

Uploads are paired with their replies **by arrival order** — `settleUpload`
`shift()`s the queue. That is sound while the queue mirrors the requests, and
`uploadImage` serialises pastes to keep it that way. But the watchdog broke the
invariant it depended on:

```javascript
const idx = this.pendingUploads.indexOf(pending);
if (idx !== -1) this.pendingUploads.splice(idx, 1);
pending.reject("no word from the server about this upload");
```

Splicing the timed-out entry out shifts the queue under a reply that may still
be in flight. The server's answer for upload A then arrives, finds upload B at
the head, and resolves B with **A's URL** — the pasted picture is silently
replaced by a different one. Wrong-image-without-warning is a worse outcome
than any of the failures this path is designed around.

**Fix:** the watchdog now marks the entry `settled` and leaves it in place as a
tombstone, so replies keep landing on the request that produced them;
`settleUpload` consumes the slot and returns. The progress handler rearms the
first *unsettled* entry rather than the head.

Residual limitation, on record: a tombstone whose reply never arrives at all
holds its slot. In practice the case where no reply comes is a dropped socket,
which destroys the hook and clears the queue — and trading a stuck fallback for
a silently-wrong image is the right way round.

### `BUG - MEDIUM` (latent) — `up/1` can stamp a table with a version it doesn't have *(fixed)*

The new final clause runs when the installed version is at *or beyond* the
target, and wrote the target unconditionally:

```elixir
_ -> record_version(opts, opts.version)
```

With a future V2 installed, `up(version: 1)` runs no steps — correctly — and
then stamps the table `"1"`. That is the same lie the `:incompatible` clause
four lines above refuses to tell: a marker asserting a shape the table doesn't
have. Only latent while `@current_version` is 1, but it is exactly the sort of
thing that bites the release that adds V2.

**Fix:** `record_version(opts, max(initial, opts.version))`.

### `IMPROVEMENT - HIGH` — the unfurl blocks the LiveView for up to ~50 seconds *(mitigated, not removed)*

`handle_event/3` has to return `{:reply, …}`, so the fetch runs inline in the
LiveView process. The timeouts compounded: four page hops at 10s each plus a
10s hero fetch. While blocked the socket handles nothing — not the user's own
edits, not peers' annotation deltas, not cursors.

Making it genuinely async means abandoning `{:reply, …}` for the same
order-paired `push_event` protocol the uploads use, which is precisely where
the previous finding lives. Trading a bounded stall for a second instance of
the fragile pairing is not a good trade for a link preview.

**Fix applied instead:** one wall-clock budget (`@budget_ms 12_000`) for the
whole unfurl, threaded as a deadline through the page fetch, its redirects, and
the hero. Each request gets `min(@timeout_ms, time_left)` and the walk bails
with `{:error, :timeout}` once the budget is spent. Worst case is ~12s rather
than compounding per hop; the synchronous shape is unchanged.

### `IMPROVEMENT - MEDIUM` — `private_address?/1` missed several reserved ranges *(fixed)*

Loopback, RFC1918, link-local, CGNAT and `0.0.0.0/8` were covered. Added:
`192.0.0.0/24` (IETF protocol assignments), `198.18.0.0/15` (benchmarking),
`224.0.0.0/4` (multicast) and `240.0.0.0/4` (reserved, which takes the
`255.255.255.255` broadcast address with it). Cheap, and none of them is
somewhere a link preview has business sending a request.

### `NITPICK` — documentation that the PR made untrue *(fixed)*

- `AGENTS.md` still said `fresco ~> 0.6` / `etcher ~> 0.7`, listed neither
  `req`, `floki` nor `open_fresco`, and opened with "No files, no external
  storage" — which this PR is precisely the negation of. Updated, with new
  sections for the delta's z-order rule and for the image/link paths.
- `README.md`'s new `max_frame_size` section closed by proposing "uploading
  pasted images to storage and keeping a URL in the shape … is the actual fix"
  as future work — in the same PR that implements it. Rewritten as what it now
  is: headroom for the fallback path when an upload fails.
- `handle_image_progress/3`'s comment said progress "feeds the bar on the
  half-transparent placeholder"; commit `b0a12b1` had already made the client
  draw nothing from it (it only rearms the watchdog).
- The `board:unfurl` comment said the handler "stores it like any other board
  image, and replies with its URL". It replies with an SVG; the client
  rasterises it and *then* sends it through the upload path.
- User-supplied URLs were interpolated raw into log lines. Wrapped in
  `inspect/1` — a URL with a newline in it should not be able to forge a log
  entry.

---

## Reviewed and deliberately left alone

**DNS rebinding.** `safe_uri/1` resolves the host, then hands Req the *name*,
which resolves it again. A DNS answer that changes between the two is not
caught. Closing it means pinning the checked address and carrying the original
host through as a `Host` header and SNI name — a meaningful amount of machinery
for a surface only an authenticated admin can reach. Documented as a known
limit in the moduledoc rather than fixed, so the next person doesn't have to
rediscover that it was considered.

**IPv6 is unreachable.** `:inet.getaddrs(host, :inet)` asks only for A records,
so an AAAA-only host fails with `{:dns, :nxdomain}` and an IPv6 literal never
resolves. This fails *closed*, so it is not a hole — but it is a functional gap
(some sites are IPv6-only), and fixing it means writing the equivalent range
table for `::1`, `fc00::/7`, `fe80::/10` and IPv4-mapped addresses. Left as
known behaviour with a test pinning the current answer.

**No rate limit on `board:unfurl`.** A user can make the server fetch URLs as
fast as they can paste. The board pages are behind admin auth, and the budget
above bounds each one; a limiter is worth adding if this ever reaches a
non-admin surface.

**`Etcher.layer` client contracts.** Checked rather than assumed: `getMode`,
`setMode`, `selectTool`, `tools`, `setShapeOrder`, `setImageUploader` and
`setLinkUnfurler` all exist on the layer handle in the pinned etcher 0.10, and
`setShapeOrder` does emit nothing — so applying a peer's order can't echo. The
`~> 0.10` pin is correctly justified in `mix.exs`.

**The z-order fix itself.** `reordered?/2` compares the two lists restricted to
their shared uuids, which is the right way to keep a create or delete from
masquerading as a reshuffle, and `test/board_delta_test.exs` covers append,
prepend, middle-delete and reorder-alongside-create. Nothing to add.

---

## Tests added

`test/link_preview_test.exs` — the guard every fetch hop now goes through, plus
the render path:

- `safe_uri/1` refuses non-http schemes, hostless URLs, loopback (including
  spelled as an integer and in octal), the cloud metadata endpoint, RFC1918,
  CGNAT, `0.0.0.0/8`, the newly-added reserved ranges, and IPv6 literals.
- `private_address?/1` does not over-reach: `172.15`/`172.32` and
  `100.63`/`100.128` stay public.
- `metadata/2` prefers OpenGraph, falls back to `<title>` then the host,
  resolves relative `og:image` paths, and clips a runaway title.
- `scene/1` + `svg/1` render at the declared size and **escape markup carried
  in from the fetched page** — the title lands in an SVG the client rasterises,
  so this asserts open_fresco's escaping rather than trusting it.

Worth stating why there is no end-to-end redirect test: a test HTTP server sits
on 127.0.0.1, which is exactly what the guard blocks. The redirect fix is
structural rather than conditional — there is now one walk, it never lets Req
follow a `Location`, and every hop goes through `safe_uri/1` — so the guard's
own tests are where the coverage lives.

## Gate

`mix format`, then `mix precommit` (compile `--warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
`credo --strict`, `dialyzer`) — green, no credo issues, 0 dialyzer errors.
`mix test`: 40 tests, 0 failures.
