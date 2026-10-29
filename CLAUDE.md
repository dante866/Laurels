# Deedkeeper — working notes for Claude

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
- Prefer patterns that work on **both** toc targets (`Deedkeeper.toc` = 16001 and
  `Deedkeeper_Mists.toc` = 50504).

### Known gotchas found in the 2026-10-29 audit
- `CombatLogGetCurrentEventInfo()` is **absent** from the dump. Read combat-log data from
  the `OnEvent` varargs instead (`OnEvent = function(self, event, ...) ... end`).
  Currently used unguarded at `Tracking/Sources/KillSource.lua:51`.
- NPC-ID parsing assumes a retail dash-delimited GUID (`KillSource.lua:33`); Mists-era
  GUIDs may differ. Make it format-tolerant.
- `UIDropDownMenu_SetMaxHeight` is absent too, but already nil-guarded — fine as-is.

Full audit: `docs/forever-api-audit.md` (on the `premade-deeds` branch until merged).
