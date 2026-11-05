# Laurels — working notes for Claude

## ⚠️ FLAG: verify every new WoW API against the Forever dump BEFORE using it

The target client (**WoW-Forever**, `## Interface: 16001`, product
`wow_classic_beta`) has Classic-flavoured content on the **modern engine,
with addon restrictions**: secret values, and a combat log closed to addons.
It is neither an old client nor plain retail. Some retail functions are
missing, and some that exist may not be used by addons.

**Before adding or changing any WoW API call, event, or C_ namespace usage:**
check it actually exists in the Forever API dump, **and** check it isn't
restricted. A name being in the dump doesn't mean addons may use it. That's
how the combat log slipped through (see below). Signs of restriction to look
for: a related `C_RestrictedActions` / `C_Secrets` / `IsXRestricted` API, a
payload documented as "protected", a value that may be secret
(`issecretvalue`), or a standalone replacement event. A function the modern
engine normally has that's *missing* here usually means restricted, not old.

- Dump: `docs/api.json` in https://github.com/Atraeau/WoW-Addons
  (raw: `https://raw.githubusercontent.com/Atraeau/WoW-Addons/HEAD/docs/api.json`).
  Structure: `systems[]` (each with `namespace`, `functions`, `events`), and `globals`
  (keys = every global function / `C_*` table). Grep it; if a symbol isn't there,
  treat it as unavailable and find the era-appropriate equivalent.
- Prefer patterns that work on **both** toc targets (`Laurels.toc` = 16001 and
  `Laurels_Mists.toc` = 50504).

### Known gotchas
- **The combat log is closed to addons on Forever** (found at launch,
  2026-11-04). Even `RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")` raises the
  "blocked from an action" popup. `Laurels.toc` declares `## X-CombatLog: closed`
  (read into `ns.combatLogClosed`). There, kills use `PARTY_KILL`, swings use
  `PLAYER_SWING`, and deaths use `C_DeathRecap`. **Never register the combat log
  without checking `ns.combatLogClosed`.** The October audit got this wrong.
  It read the missing `CombatLogGetCurrentEventInfo()` as "old client, payload
  in varargs". That varargs path is still what MoP Classic uses.
- **Death recap on Forever (measured):** `C_DeathRecap.GetRecapEvents()`
  entries come newest first, with combat-log field names (`event`,
  `environmentalType`, `sourceName`, `sourceGUID`, `amount`, `currentHP`...)
  and wall-clock `timestamp`s. Right after `PLAYER_DEAD` it can still return
  the *previous* recap, so `DeathSource` retries until the killing blow is
  recent. `/deed recap` prints the raw recap.
- Forever has **secret values**: wrap anything read from the game in combat
  (GUIDs, names) in `ns.Signals.Readable`, which turns a secret into nil.
- `Core.lua` prints the name of any forbidden or blocked call in chat. The
  game's own popup doesn't name it.
- NPC-ID parsing assumed a retail dash-delimited GUID. ✅ **Fixed** — tolerates both the
  dash form and a legacy hex form. The hex byte offset is still **unverified** against a
  real Forever creature GUID; note `/deed whoami` measured Forever returning a
  dash-format *player* GUID (`Player-4618-00D1568C`), so that branch may never run there.
- `UIDropDownMenu_SetMaxHeight` is absent too, but already nil-guarded — fine as-is.

Full audit: `docs/forever-api-audit.md`.

### Testing reaches further than it used to
`tools/test_killsource.lua` drives `OnCombatLog` headlessly, including both payload
routes. `tools/test_forever.lua` covers the closed-combat-log paths, and
first checks that no source registers the combat log there. Headless tests
can't show what the game *allows*, so only a real login proves that. Note `/deed test` injects synthetic signals and **bypasses the combat log
entirely** — it is why the bug above stayed invisible. Don't treat it as proof that
kill tracking works on a client.
