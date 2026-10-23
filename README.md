# Deedkeeper

A WoW addon for **custom, player-authored achievements and titles** — for RP flavor
and for issuing challenges to other players. Define a deed ("kill Kobolds"), give it
title tiers ("Kobold Slayer" at 1,000, "Kobold Destroyer" at 10,000), and the addon
tracks your progress and awards the title. A later version lets other addon users
**contest and steal** a title by out-doing you.

> These titles/achievements are **addon-rendered**, not real WoW titles. The game
> server controls real titles; an addon can't grant them. Deedkeeper stores and
> displays them itself, and (v2) shares them peer-to-peer with other addon users.

Target client: **WoW-Forever (retail-based API)** — version `1.60.1`, build `70532`
(Oct 20 2026), which reports **TOC version `16001`**. That is the value in
`## Interface` in `Deedkeeper.toc`.

⚠️ After a client patch, re-check with `/run print(GetBuildInfo())` — it prints
*version, build, date, tocversion* and the **last** value is the one `## Interface`
needs. Don't use the build number: this client's TOC version (`16001`) and build
(`70532`) are nowhere near each other, and mixing them up makes the addon show as
incompatible and silently not load (no error, slash commands just don't register).

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
- [x] **GUID identity** — ladder keyed on player GUID, names display-only; fixes
      same-name collisions and a client logging itself as its own rival
- [x] **Channel transport** — `SAY`/`YELL` are refused by this client, so the
      ladder runs on one shared hidden channel, with built-in send throttling
- [ ] M4 published-deed definition sync (DEFPUB adopt) — currently two clients must
      share the same `uuid`; adoption makes that automatic
- [ ] M5 holder/rank in the panel UI + steal toasts

⚠️ **The ladder is server-wide, not nearby.** Addon messages over proximity
chat are rejected on this client (measured — `docs/rival-layer.md` §3), so
there is no range-limited transport. Everyone running the addon who has joined
the shared channel hears every published claim.

On login you will see the client's **Code of Conduct notice** in chat. That is
the game reacting to joining a channel, not an addon error.

Known limitations (by design, see `docs/rival-layer.md` §5):
- The rate cap only catches *acceleration* of a known rival; a brand-new contact's
  first absolute count can't be sanity-checked (no baseline). Social-trust covers this.
- Titles are per-character: GUIDs expose no account handle, so your own alts
  compete with each other.

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

**M4 — published-deed definition sync.** Today two clients must already share a
deed's `uuid` to contest it. `DEFPUB` lets an author publish the definition so
others can adopt it — which is the "issue a challenge" feature proper.

**M5 — UI.** Holder and your rank in the panel; "you took / lost the title"
toasts. The data is already there; nothing renders it yet.

**TRP3 integration (user idea).** Total RP 3 is the de-facto RP profile addon; hooking
it would be a great distribution + display surface. Plan: keep this core **TRP3-agnostic**
and add an *optional* `Integrations/TRP3.lua` shim that, only if TRP3 is loaded, surfaces
earned titles on the player's TRP3 profile/tooltip. Standalone when TRP3 is absent.
(A full TRP3-Extended "campaign/quest" module is heavier and would bind us to their data
model — revisit once the core is proven.)
