# Forever API compatibility audit

**Date:** 2026-10-29
**Analyzed:** Deedkeeper `master` @ M4 (`3478500`) — all addon source (excl. `tools/` tests)
**Against:** `docs/api.json` from [Atraeau/WoW-Addons](https://github.com/Atraeau/WoW-Addons)
(raw: `https://raw.githubusercontent.com/Atraeau/WoW-Addons/HEAD/docs/api.json`)

## Dump identity

| field | value |
|---|---|
| product | `wow_classic_beta` |
| interface | **16001** |
| version / build | 1.60.1 / 70170 |
| exported | 2026-10-01 |
| coverage | 6,598 functions · 1,806 events · 410 systems |

This is a **Classic/Mists-era** client, **not retail** — see §5.

## Method

Extracted every C_ namespace call, registered event, and global-function call from the
addon, flattened the dump to 15,980 callable symbols + 1,806 events, and checked each.
Borderline cases confirmed against the raw JSON.

## Result: compatible except one call

| Checked | Verdict |
|---|---|
| C_ namespace calls (8): `C_Map.*`, `C_ChatInfo.*`, `C_Timer.After`, `C_AddOns.GetAddOnMetadata` | ✅ all present |
| Events (4): `ADDON_LOADED`, `PLAYER_LOGIN`, `CHAT_MSG_ADDON`, `COMBAT_LOG_EVENT_UNFILTERED` | ✅ all present |
| Globals (`CreateFrame`, `UnitGUID`, `UnitName`, `GetServerTime`, `GetZoneText`, `JoinTemporaryChannel`, `UIDropDownMenu_*`, …) | ✅ present **except two below** |

### 🔴 1. `CombatLogGetCurrentEventInfo` — ABSENT from the dump

`Tracking/Sources/KillSource.lua:51` calls it **unguarded**, and it is the core of all
kill tracking:

```lua
local _, subevent, _, sourceGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
```

The dump contains no `CombatLogGetCurrentEventInfo` anywhere, though it *does* list
`GetCurrentEventInfo` and the other `CombatLog*` globals. If accurate, this returns nil →
`attempt to call nil value` on **every** `COMBAT_LOG_EVENT_UNFILTERED` (constant in
combat), breaking kill tracking and spamming errors.

`CombatLogGetCurrentEventInfo()` is the **Legion (7.0+)** pattern. On a Mists/Classic
client the combat-log payload arrives as the **`OnEvent` varargs** instead.
**Fix direction:** read the data from the event args rather than the function —
`f:SetScript("OnEvent", function(self, event, ...) local _, subevent, ... = ... end)` —
and confirm in-game (dumps can occasionally omit a global).

### 🟡 2. GUID format assumption (same file)

`KillSource.lua:33` parses the NPC ID as a **retail dash-delimited GUID**
(`Creature-0-…-NPCID-spawnUID`, `select(6, strsplit("-", guid))`) — a WoD+ (6.0+) format.
On a Mists-era client GUIDs may use the old hex form, so this would silently return nil
NPC IDs. Same root cause as #1; verify against the live client.

### 🟢 Non-issue: `UIDropDownMenu_SetMaxHeight` — absent but already guarded

Also not in the dump, but `UI/AuthorForm.lua:307` wraps it:
`if UIDropDownMenu_SetMaxHeight then …`. Degrades gracefully; **no action needed.**

## §5 Version contradiction to reconcile

- `Deedkeeper.toc` → `## Interface: 16001` — **matches the dump exactly.** ✅
- `Deedkeeper_Mists.toc` → `## Interface: 50504` (MoP Classic 5.4).
- `README.md` still says target is **"retail-based API."**

The dump, the Mists toc, and the two absent APIs all indicate a **Classic/Mists** client.
The README's "retail-based" line is the likely origin of the Legion-era combat-log call
and the retail GUID parsing. Correcting that claim prevents the next round of these.

## Recommended actions

1. Rewrite `KillSource:OnCombatLog` to read combat-log data from the `OnEvent` varargs
   (portable across both toc targets), and make `getNpcID` format-tolerant.
2. Fix the README's "retail-based API" line to state the actual target (interface 16001).
3. Adopt the standing rule (see repo-root `CLAUDE.md`): **check new WoW API usage against
   the Forever dump before adding it.**

*Clean items for reference:* all `C_*` calls, all registered events, and every other
global resolve against the dump — the addon is otherwise fully compatible.
