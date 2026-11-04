# Laurels — working notes for Claude

## ⚠️ FLAG: verify every new WoW API against the Forever dump BEFORE using it

The target client (**WoW-Forever**) is a **Classic/Mists-era** build —
`## Interface: 16001`, product `wow_classic_beta` — **not retail**, despite any
"retail-based API" wording still in `README.md`. Retail-only globals, namespaces,
events, and GUID formats may be absent or behave differently.

**Before adding or changing any WoW API call, event, or C_ namespace usage:**
check it actually exists in the Forever API dump. Do not assume retail availability.

- Dump: `docs/api.json` in https://github.com/Atraeau/WoW-Addons
  (raw: `https://raw.githubusercontent.com/Atraeau/WoW-Addons/HEAD/docs/api.json`).
  Structure: `systems[]` (each with `namespace`, `functions`, `events`), and `globals`
  (keys = every global function / `C_*` table). Grep it; if a symbol isn't there,
  treat it as unavailable and find the era-appropriate equivalent.
- Prefer patterns that work on **both** toc targets (`Laurels.toc` = 16001 and
  `Laurels_Mists.toc` = 50504).

### Known gotchas found in the 2026-10-29 audit
- `CombatLogGetCurrentEventInfo()` is **absent** from the dump. ✅ **Fixed** —
  `KillSource` now reads the payload from the `OnEvent` varargs and only falls back to
  that global where it exists. If neither route works it says so in chat rather than
  counting nothing in silence.
- NPC-ID parsing assumed a retail dash-delimited GUID. ✅ **Fixed** — tolerates both the
  dash form and a legacy hex form. The hex byte offset is still **unverified** against a
  real Forever creature GUID; note `/deed whoami` measured Forever returning a
  dash-format *player* GUID (`Player-4618-00D1568C`), so that branch may never run there.
- `UIDropDownMenu_SetMaxHeight` is absent too, but already nil-guarded — fine as-is.

Full audit: `docs/forever-api-audit.md`.

### Testing reaches further than it used to
`tools/test_killsource.lua` drives `OnCombatLog` headlessly, including both payload
routes. Note `/deed test` injects synthetic signals and **bypasses the combat log
entirely** — it is why the bug above stayed invisible. Don't treat it as proof that
kill tracking works on a client.
