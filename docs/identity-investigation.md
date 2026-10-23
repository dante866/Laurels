# Identity investigation — **RESOLVED**

**Status:** closed. The probe was run in-game on WoW-Forever 1.60.1 (build
70532, TOC 16001) and the answer was conclusive. GUID keying is implemented;
names are display-only. Kept as a record of what was measured and why the
design looks the way it does.

Run `/deed whoami` again after a client patch if identity ever looks wrong.

## What the probe returned

```
UnitName("player") #1       = Indira
UnitName("player") #2       = Resthaerl
GetUnitName(player, false)  = Indira Resthaerl
GetUnitName(player, true)   = Indira Resthaerl
UnitFullName name / realm   = Indira / Resthaerl
GetRealmName()              = Classic Beta PvE
GetNormalizedRealmName()    = ClassicBetaPvE
UnitGUID("player")          = Player-4618-00D1568C
  GUID fields               = Player | 4618 | 00D1568C
CHAT_MSG_ADDON sender       = Indira Resthaerl   (via /deed commtest)
```

## The finding: `Resthaerl` is a surname, not a realm

This doc previously assumed the second return of `UnitName` was a realm. It is
not. Three independent confirmations:

1. `GetRealmName()` is `Classic Beta PvE`. That is the realm. `Resthaerl` is
   something else.
2. `GetUnitName(player, false)` and `(player, true)` return **the same
   string**. In stock WoW that flag controls whether the realm is appended, so
   identical returns mean the surname is part of the name itself.
3. The separator is a **space**. Stock WoW realm suffixes are `-Realm`, never
   spaced.

So the client packs `First Last` into the name APIs and puts the surname where
stock WoW puts the realm.

## Why this mattered — two live bugs

Per the original decision tree this is the *"both names surface in different
APIs"* branch, which mandates GUID keying. Both predicted failures were real:

- **Identity collision.** `MyName()` used `UnitName("player")`, capturing only
  `Indira`. Every other character with that first name shared one ladder entry.
- **Broken self-echo guard.** The guard compared `sender` against
  `UnitName("player")` — `Indira Resthaerl` vs `Indira` — which never matched.
  On a shared channel a client processed its own broadcasts and appeared on
  its own leaderboard as a rival.

A cheaper fix existed: `GetUnitName("player", false)` returns exactly the
string `sender` carries, so name keying *could* have been made to work. GUID
was chosen anyway — it survives renames, cannot collide, and travelling in the
payload makes the protocol independent of `sender`'s format entirely.

## What was implemented

- Protocol bumped to **2**; `HELLO` and `CLAIM` carry `guid`.
- `Ladder` was already GUID-keyed by design — `Rival` was feeding it names.
  Fixed at all four touchpoints: `MyGuid()`, local claim recording, `OnClaim`,
  and holder comparison in `AfterLadderChange` (the fourth was not in the
  original list of three).
- The echo guard moved into `Comm:HandleRaw`, comparing GUIDs after decode.
  It could not live in the receive frame, which has no decoded payload.
- `MyName()` now uses `GetUnitName("player", false)` for the full two-part
  name, as a display label only.

## Still open

1. **Per-character or per-account?** The GUID is per-character and exposes no
   account handle, so alts compete with each other. Per-account would require
   manual alt-grouping. Currently per-character.
2. **Which name to display** — currently the full `Indira Resthaerl`.
