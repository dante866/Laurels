# Forever API compatibility audit

**Date:** 2026-10-29
**Analyzed:** Laurels `master` @ M4 (`3478500`) — all addon source (excl. `tools/` tests)
**Against:** `docs/api.json` from [Atraeau/WoW-Addons](https://github.com/Atraeau/WoW-Addons)
(raw: `https://raw.githubusercontent.com/Atraeau/WoW-Addons/HEAD/docs/api.json`)

> ## ⚠️ Correction, 2026-11-04 (Forever launch, build 70790)
>
> **This audit's central conclusion was wrong.** It read the dump as a
> Classic/Mists-era client and treated the missing `CombatLogGetCurrentEventInfo`
> as "an older client that passes the combat log as event arguments". At launch,
> Forever refused even *registering* `COMBAT_LOG_EVENT_UNFILTERED`
> (`ADDON_ACTION_FORBIDDEN` on `Frame:RegisterEvent()`, three times at login).
> That broke kills, melee swings and deaths.
>
> **Forever is the modern engine with addon restrictions, and the combat log is
> closed to addons.** The function is missing *because* the combat log is
> closed, not because the client is old. The evidence was already in this same
> dump (build 70170). The audit checked only that each name existed, and
> `COMBAT_LOG_EVENT_UNFILTERED` does exist as an event:
>
> | In the dump | What it means |
> |---|---|
> | `CombatLogGetCurrentEventInfo` absent | addons are given no combat-log payload |
> | `C_RestrictedActions`, `C_Secrets.HasSecretRestrictions`, `issecretvalue`, `canaccessvalue` | the addon-restriction and secret-value systems are present |
> | `C_CombatLog.IsCombatLogRestricted`; `COMBAT_LOG_MESSAGE` "protected by a \|K string wrapper" | the combat log itself is restricted |
> | `PARTY_KILL`, `PLAYER_SWING`, `UNIT_DIED` as events of their own | replacements, which exist so addons can manage without the combat log |
>
> **What changed in code:** `Laurels.toc` declares `## X-CombatLog: closed`.
> There, `KillSource` uses `PARTY_KILL`, `SwingSource` uses `PLAYER_SWING` (which
> counts misses too, since the event doesn't say whether the swing hit), and
> `DeathSource` reads the cause from `C_DeathRecap`. MoP Classic keeps the combat
> log. `Core.lua` prints the name of any forbidden or blocked call in chat. The
> new paths are tested in `tools/test_forever.lua`.
>
> **Lesson for method:** checking that a name exists isn't enough. For anything
> central, also look in the dump for signs the call is *restricted* (the rows
> above), and treat a missing function that the modern engine normally has as
> a reason to ask why.
>
> §1, §5 and the recommended actions below are kept as written in October,
> with notes where they were wrong.

## Dump identity

| field | value |
|---|---|
| product | `wow_classic_beta` |
| interface | **16001** |
| version / build | 1.60.1 / 70170 |
| exported | 2026-10-01 |
| coverage | 6,598 functions · 1,806 events · 410 systems |

This is a **Classic/Mists-era** client, **not retail** — see §5.
*(Wrong; see the correction above. It is Classic-flavoured content on the
modern, restricted engine.)*

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

> **2026-11-04:** this fix direction was wrong. On Forever there are no
> varargs to read, because the event can't be registered at all. See the
> correction at the top.

### 🟡 2. GUID format assumption (same file)

`KillSource.lua:33` parses the NPC ID as a **retail dash-delimited GUID**
(`Creature-0-…-NPCID-spawnUID`, `select(6, strsplit("-", guid))`) — a WoD+ (6.0+) format.
On a Mists-era client GUIDs may use the old hex form, so this would silently return nil
NPC IDs. Same root cause as #1; verify against the live client.

### 🟢 Non-issue: `UIDropDownMenu_SetMaxHeight` — absent but already guarded

Also not in the dump, but `UI/AuthorForm.lua:307` wraps it:
`if UIDropDownMenu_SetMaxHeight then …`. Degrades gracefully; **no action needed.**

## §5 Version contradiction to reconcile

- `Laurels.toc` → `## Interface: 16001` — **matches the dump exactly.** ✅
- `Laurels_Mists.toc` → `## Interface: 50504` (MoP Classic 5.4).
- `README.md` still says target is **"retail-based API."**

The dump, the Mists toc, and the two absent APIs all indicate a **Classic/Mists** client.
The README's "retail-based" line is the likely origin of the Legion-era combat-log call
and the retail GUID parsing. Correcting that claim prevents the next round of these.

> **2026-11-04:** the "Classic/Mists client" reading was itself the mistake.
> The interface number and the content are Classic, but the engine is modern
> and restricted. The missing APIs point to restrictions, not to an old client.
> Forever also returns dash-format GUIDs.

## Recommended actions

1. Rewrite `KillSource:OnCombatLog` to read combat-log data from the `OnEvent` varargs
   (portable across both toc targets), and make `getNpcID` format-tolerant.
2. Fix the README's "retail-based API" line to state the actual target (interface 16001).
3. Adopt the standing rule (see repo-root `CLAUDE.md`): **check new WoW API usage against
   the Forever dump before adding it.**

*Clean items for reference:* all `C_*` calls, all registered events, and every other
global resolve against the dump — the addon is otherwise fully compatible.
*(2026-11-04: "all registered events resolve" was true, but
`COMBAT_LOG_EVENT_UNFILTERED` resolving didn't mean addons may register it.)*
