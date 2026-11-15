# PR #12 — boards.manage, checked again after v0.7.0

**Author:** timujinne · **Reviewer:** Grok · **Merged as:** `4bfa3c8`
**Verdict:** one gap fixed in the post-v0.7.0 pass

Claude's review is `CLAUDE_REVIEW.md` in this directory. The backfill-flag fix there stands: `manage_backfilled?/0` reads the row with a query that raises, and `migrate_legacy/0` catches `:exit`. This note is the revocation gap that review called covered.

The cross-cutting write-up of everything since `v0.7.0` is `../11-pdf-export/GROK_REVIEW.md`.

## BUG - HIGH — Losing `boards.manage` did not leave the admin page (fixed)

Core will not evict this module when the base `boards` key remains. `permission_key_for_admin_view/2` resolves `PhoenixKitBoards.Web.IndexLive` and `BoardLive` to `"boards"` by namespace (the admin tab has no `:live_view`, and a `route_module/0` route cannot carry the sub-key). `scope_refresh_decision/4` then returns `:stay`, because `module_access?/2` for `"boards"` is still true.

`:stay` keeps the socket. `IndexLive` only re-checked `boards.manage` on the next click, so the open list kept showing every board, including other people's private ones. `BoardLive` re-checked within five seconds. `67e5f80` added those checks; it did not run on the scope refresh itself.

Core calls `phoenix_kit_scope_changed/1` after it has written the new scope and before the stay-or-leave decision. A `push_navigate` from that callback survives `:stay`.

**Fixed.** `IndexLive` and `BoardLive` export the callback. The list goes to the admin home. An open board runs `refresh_access/1` (admin home on `:show`, the existing not-found path on `:user`, including the overlay). The event hook and the five second timer remain for an assign that was replaced without the callback. `AdminHostLive` performs the callback, because in tests it is the LiveView and core's hook is not attached; `{:replace_scope, user}` updates the assign only, so those later checks still have a test.

## BUG - MEDIUM — The widget's menu kept manage actions (fixed)

`assign_access/1` rebuilt the scope on each refresh. `@admin?` was assigned only from the host's render, so the menu (rename, delete on someone else's board) stayed until the host re-rendered. Clicks were already re-checked.

**Fixed.** `:admin?` is set from that same scope inside `assign_access/1`.

## Left as they are

- A holder of `boards` and not `boards.manage` can still pass core's `can_access_admin_area?/1` when their other keys allow the admin area. Core decides that. These pages then send them to the admin home.
- Permission labels are translated in en, et, and ru.
