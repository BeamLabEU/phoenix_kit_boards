# PR #12 — Split the boards permission into a user key and boards.manage

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one follow-up applied

Merged into `main` as 4bfa3c8. It merged cleanly.

`boards` is now the user's key: the widget and `/dashboard/boards/:id`, where the host's `:authorize` hook decides
the place. `boards.manage` is a new sub-permission, declared through `permission_metadata/0`'s `sub_permissions`,
with labels translated by the module's own gettext backend. It opens `/admin/boards*` and every board in every
place, and the hook is not asked. `migrate_legacy/0` grants `boards.manage` once to every role that held `boards`,
then sets `boards_manage_backfilled`.

Checked and fine:
- **Core's model.** `Scope.can?/2` honours a sub-key only while its base is held and the module is enabled. Core's
  admin sweep (`sweep_admin_grants`) auto-grants module sub-keys to Admin. So a fresh install, or a host that enables
  the module after the flag is set, still gives Admin `boards.manage`. Owner passes by construction.
- **Every former check of `boards`.** `rg` over `lib/` finds `Access.admin?/1` (now `boards.manage`), the admin tab
  (`permission: "boards.manage"`), `IndexLive` and the admin `BoardLive :show`. The router only checks the base key
  on `route_module/0` routes, so both pages check `boards.manage` themselves: on mount, on every event (`IndexLive`
  through an `attach_hook`), and on the board page's 5 s access timer.
- **The channel.** `BoardChannel` takes nothing on trust: its token names one board and the LiveView pid, and it
  dies with the page. When access is withdrawn the LiveView navigates away, and that closes the channel too.
- **Revocation.** Pages read the session scope that core refreshes on `{:phoenix_kit_scope_roles_updated, _}`, and
  `BoardsPanel` builds a fresh scope at every check.
- **Gettext.** The three new msgids are translated in en/et/ru, with no fuzzy entries.

## Findings

### BUG - MEDIUM — The backfill flag was read through a reader that answers nil on failure (fixed)

`migrate_legacy/0` checked `Settings.get_setting("boards_manage_backfilled") == "true"`. That reader rescues every
database error, and the exits too, to `nil`. It also answers `nil` in `update_mode`. A boot where that one read
failed but the role query worked would run the backfill again. Every role given the narrow user key `boards` since
the split would then become a `boards.manage` admin, silently and for good. The PR already guarded the role lookup
against exactly this "error reads as nothing" problem (`role_grants/0`), but not the flag.

Fix: `manage_backfilled?/0` reads the row with `PhoenixKit.Settings.Queries.get_setting_by_key/1`, which raises.
This is how core reads its own backfill flags (`Permissions.run_backfill/4`). `migrate_legacy/0` now also catches
`:exit` (a dead pool exits rather than raises) and logs only the reason's tag. New test: with the flag set and
`update_mode` on, `Settings.get_setting/1` reads nil and `migrate_legacy/0` still grants nothing. Swapping the old
read back in fails that test.

### NITPICK — A holder of only `boards` passes the admin-area gate (not changed)

`Scope.can_access_admin_area?/1` is true for any single permission holder, so a user given just the user key reaches
`/admin` and sees an admin shell with no boards entry. Core treats `integrations` and `api_personal_keys` the same
way. Changing that is core's decision, not this module's.

### NITPICK — Flash text and the new labels have no translations past en/et/ru (not changed)

The refusal flash ("You do not have access to the boards admin.") is a plain string, like the rest of the module's
UI copy. The permission labels fall back to English in core's other six locales.
