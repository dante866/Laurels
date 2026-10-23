# Deedkeeper

A WoW addon for **custom, player-authored achievements and titles** — for RP flavor
and for issuing challenges to other players. Define a deed ("kill Kobolds"), give it
title tiers ("Kobold Slayer" at 1,000, "Kobold Destroyer" at 10,000), and the addon
tracks your progress and awards the title. A later version lets other addon users
**contest and steal** a title by out-doing you.

> These titles/achievements are **addon-rendered**, not real WoW titles. The game
> server controls real titles; an addon can't grant them. Deedkeeper stores and
> displays them itself, and (v2) shares them peer-to-peer with other addon users.

Target client: **WoW-Forever (retail-based API)**. ⚠️ *Verify the build* — in game run
`/run print((select(4, GetBuildInfo())))` and set `## Interface` in `Deedkeeper.toc`
to match, or the addon shows as out of date.

## Status

**v1 — tracking engine**
- [x] Tracker definitions with ascending title **tiers**
- [x] Pluggable **sources** feeding normalized "signals" into the engine
- [x] **KillSource** — counts killing blows via the combat log (name / npcID match)
- [x] Per-character progress + account-wide definitions (SavedVariables)
- [x] Minimal draggable panel + slash commands

**v2 — in-game authoring**
- [x] "New Deed" form: name, match (name-contains / NPC IDs), up to 5 title tiers
- [x] Per-row delete button; `/deed new`, `/deed delete <id>` commands

**v3 — rival / steal layer (current build)**
- [x] M1 Comm bus (`Rival/Comm.lua`) — encode/decode/dispatch over a swappable transport
- [x] M2 Ladder + holder resolution (`Rival/Ladder.lua`) — deterministic steal, rate cap
- [x] M3 Wire-up (`Rival/Rival.lua`) — publish a deed, auto-broadcast on tier change,
      inbound claims update the ladder and fire "you took / lost the title"
- [x] `/deed publish|unpublish|rivals <id>` commands
- [ ] M4 published-deed definition sync (DEFPUB adopt) — currently two clients must
      share the same `uuid`; adoption makes that automatic
- [ ] M5 holder/rank in the panel UI + steal toasts; vendor ChatThrottleLib

Known limitations (by design, see `docs/rival-layer.md` §5):
- The rate cap only catches *acceleration* of a known rival; a brand-new contact's
  first absolute count can't be sanity-checked (no baseline). Social-trust covers this.
- Claimants are keyed by chat sender name; connected-realm name suffixes may split a
  player into two entries until M4 normalizes identity.

### Developing

Syntax-check every file (LuaJIT = Lua 5.1, matches WoW):
`powershell -ExecutionPolicy Bypass -File tools\check.ps1`

Run all headless test suites (from the addon root):
`luajit tools\test_engine.lua` · `test_ladder.lua` · `test_comm.lua` · `test_rival.lua`

## Install

Copy the `Deedkeeper` folder into your client's AddOns directory, e.g.
`World of Warcraft\_retail_\Interface\AddOns\Deedkeeper\`
(WoW-Forever may use its own install folder — check its launcher).

## Try it

```
/deed                  toggle the panel
/deed list             list trackers + progress in chat
/deed test 1000 Kobold simulate 1000 Kobold kills (earns "Kobold Slayer")
/deed test 9000 Kobold ...9000 more earns "Kobold Destroyer"
/deed reset kobolds    reset that tracker
```

`/deed test` fires synthetic kill signals so you can verify tiers without farming mobs.

## Architecture

```
Core.lua                 lifecycle, SavedVariables, slash commands, defaults
Tracking/Engine.lua      owns trackers; matches signals -> increments -> tiers
Tracking/Sources/
  KillSource.lua         combat log -> { kind="kill", name, npcID }
UI/MiniPanel.lua         minimal list panel
```

A **source** turns WoW events into normalized **signals**:
`{ kind = "kill", name = "Kobold Vermin", npcID = 1234, amount = 1 }`.
The **engine** matches each signal against every tracker whose `event` equals the
signal `kind`, applies the tracker's `match` criteria (`nameContains`, `npcIDs`),
increments per-character progress, and resolves title tiers. Add new trackable things
(quests, items, zones, emotes) by writing a new source — the engine doesn't change.

Add a tracker from Lua (temporary, until the authoring UI exists):

```lua
local ns = select(2, ...)  -- or hook DeedkeeperDB directly
ns.Engine:CreateTracker({
  name = "Murloc Hunting",
  event = "kill",
  match = { nameContains = "Murloc" },
  tiers = {
    { count = 500,  title = "Murloc Menace" },
    { count = 5000, title = "Murloc Bane" },
  },
})
```

## Roadmap

**v2 — rival / steal layer (auto-broadcast nearby).** When you earn or extend a title,
broadcast `{trackerId, count, title}` on an addon comm channel; nearby Deedkeeper users
compare counts and the top count holds the title. Hooks left in `Engine:Increment`.
Open design questions: comm transport (addon message channels + throttling/versioning),
how shared tracker *definitions* propagate so two players count "the same" thing, and
anti-spoof (counts are client-trusted among a trusted RP community — acceptable for v1).

**TRP3 integration (user idea).** Total RP 3 is the de-facto RP profile addon; hooking
it would be a great distribution + display surface. Plan: keep this core **TRP3-agnostic**
and add an *optional* `Integrations/TRP3.lua` shim that, only if TRP3 is loaded, surfaces
earned titles on the player's TRP3 profile/tooltip. Standalone when TRP3 is absent.
(A full TRP3-Extended "campaign/quest" module is heavier and would bind us to their data
model — revisit once the core is proven.)
