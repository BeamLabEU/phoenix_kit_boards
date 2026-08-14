# PR #7 — etcher 0.12 lock + classify board uploads

**Author:** alexdont · **Branch:** `deps/etcher-0.12` · **Reviewed:** 2026-08-14
**Merged as:** `bccea24`

Two commits (plus a lock micro-bump to 0.12.1): move the etcher lock from
0.11.0 to 0.12.1, and stop hardcoding `file_type: "image"` on every board
upload.

## The lock bump is correct

`mix.exs` pins `etcher ~> 0.11`, which Elixir reads as `>= 0.11.0 and < 1.0.0`.
Only the lock was holding this module at 0.11.0. Verified against the call
sites this module actually uses:

- `onShapesMoving` / `applyShapesMoving` (live drags)
- `toolBadge` (cursor tool glyph)
- `setPrefs` / `etcher:prefs-changed` (opaque blob)
- `setImageUploader` / `setLinkUnfurler`
- `patchShape` / `setShapeOrder` / `applyMediaState`

All still present. The two new 0.12 prefs (snap toggle, remembered label
colour) ride the same blob `save_prefs/2` already merges into user
`custom_fields` without reading its keys. No constraint change needed.

## The classifier change is correct

`@image_accept` lists audio (`.mp3 .m4a .wav .ogg .opus`) and video
(`.mp4 .m4v .webm .mov`) next to images. `store/4` then passed `"image"`
into `Storage.store_file_in_buckets/6`. Confirmed in the PR body against a
live database (`video/mp4` rows with `file_type: "image"`).

`Storage.determine_file_type/2` is the one classifier every core upload path
already uses (media browser, media selector, upload controller). MIME prefix
first (`image/` / `video/` / `audio/`), filename fallback when the type is
`application/octet-stream` or unknown. The `store_data_url/2` path builds
`client_type: MIME.type(ext)` from a clipboard image, so it still classifies
as `"image"`.

---

## BUG - HIGH — checksum was MD5, the media library hashes SHA256

`file_checksum/1` hashed with `:md5`. Core's media browser, media selector
and `Auth.calculate_file_hash/1` hash with SHA256. `store_file_in_buckets/6`
dedupes on `user_uuid + file_checksum`, so the same bytes pasted onto a
board and later uploaded through the media page minted two rows.

That is the same class of "two lists that must stay in sync" bug the PR
fixed for `file_type` — boards invented its own hasher the way it used to
invent its own type.

**Fixed.** `file_checksum/1` now streams SHA256 and is pinned equal to
`Auth.calculate_file_hash/1`. Streamed rather than `File.read/1` because
`@image_max_bytes` is 256 MB and this path now correctly accepts video.

## BUG - HIGH — the upload watchdog fired while the server was still storing

`handle_image_progress/3` consumed the entry and called `store_image/3`
*inside* the `done?` branch. `push_event` only flushes when the callback
returns, so the client saw silence for the whole hash + bucket write. The
watchdog is 15 s of silence, rearmed only by `board:image-progress`. A video
anywhere near the 256 MB cap — the reason that cap exists — trips it, the
client embeds the bytes, and a late `board:image-uploaded` is consumed as a
tombstone. The board gets heavier, which is the failure this whole path
exists to prevent.

**Fixed.** On `done?` the LiveView pushes progress 100 and returns, then
stores from a follow-up `handle_info`. The hook treats 100% as "bytes
arrived, now storing" and rearms for five minutes rather than 15 seconds.
Pinned in `test/js/upload_watchdog_test.js`.

## IMPROVEMENT - MEDIUM — no test locked the new classifier in

The PR added a comment and swapped one argument. `determine_file_type/2` is
tested in core, but nothing here asserted that a `video/mp4` or `audio/mpeg`
entry is *not* stored as `"image"`, which is the regression this module can
reintroduce by hardcoding again.

**Fixed.** `file_type_for/1` is `@doc false` (same pattern as `decode_data_url/1`
and `diff/2`) and `test/board_upload_test.exs` walks the MIME types
`@image_accept` names.

## IMPROVEMENT - LOW — README still required `phoenix_kit ~> 1.7`

The pin moved to `~> 2.0` in 0.4.0. README and AGENTS.md were still on 1.7
/ fresco 0.10 / etcher 0.10. Corrected.

## NITPICK — no version bump on the PR

Observable behaviour change (new uploads get the right `file_type`; etcher
0.12 reaches hosts). Hex was still at 0.4.3. Bumped to **0.4.4** with this
review.

## Deliberately not fixed

- **`.m4v` + `application/octet-stream` classifies as `"other"`** in core:
  `MIME.from_path/1` does not know `.m4v`, and core's filename fallback only
  special-cases audio extensions. Browsers send `video/mp4` for `.m4v`, which
  classifies correctly. Forking the classifier here would recreate the drift
  the PR just closed.
- **`terminate/2` for leave** still depends on LiveView trapping exits. Known
  limitation; a monitor process is a larger change than this review.
- **IPv6 literals** are refused by the SSRF guard because `:inet` lookups
  fail-closed. Documented in `link_preview_test.exs`; left as-is.
