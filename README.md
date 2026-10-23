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

## Making a deed

Authoring your own is the point of the addon, so the only content it ships is
one sample deed (Kobold Slaying) and a first-run explanation. There is
deliberately **no catalogue of premade deeds** — a library of ready-made deeds
would make the common case "pick one of ours" when it should be "invent one
and dare people to beat it."

Open `/deed new` (or the **New Deed** button) and fill in two things:

| Field | Example |
|---|---|
| **Name** | Murloc Hunting |
| **Match** | name contains `Murloc`, or specific NPC IDs |
| **Tiers** | *Murloc Menace* at 500, *Murloc Bane* at 5000 |

Every matching kill then counts, and the title is yours at 500. Check it
without farming via `/deed test 500 Murloc`, and `/deed help` prints this same
worked example in-game. To let others contest the title, `/deed publish <id>`.

**Zone scoping (optional).** A deed's `match` can also carry a `zone` (name) or
`zoneID` (uiMapID), making "Kobolds of Elwynn" a different deed from kobolds
everywhere. The two are one assertion — *where the kill happened* — so either
alone is enough: a name survives a map we have no ID for, an ID survives
localization. A deed with no zone criterion ignores zone entirely.

`/deed new` has a **Zone** dropdown: *Any zone* (the default), *Current zone*,
or any zone the client knows about. The list is read from the client's own map
data and discovers the map root by walking up from where you're standing, so it
doesn't depend on retail's map IDs. If a client won't answer, the dropdown
still offers *Any zone* and *Current zone*.

A zone on its own is a valid deed — "500 kills in Westfall", no mob filter.

`/deed test` sends the zone you're standing in, so append `@Zone` to test a
deed for somewhere else: `/deed test 25 Dust Devil @Westfall`.

## Architecture

```
Core.lua                 lifecycle, SavedVariables, slash commands, defaults
Tracking/Engine.lua      owns trackers; matches signals -> increments -> tiers
Tracking/Sources/
  KillSource.lua         combat log -> { kind="kill", name, npcID }
UI/MiniPanel.lua         minimal list panel
```

A **source** turns WoW events into normalized **signals**:
`{ kind = "kill", name = "Kobold Vermin", npcID = 1234, zone = "Elwynn Forest",
zoneID = 37, amount = 1 }`.
The **engine** matches each signal against every tracker whose `event` equals the
signal `kind`, applies the tracker's `match` criteria (`nameContains`, `npcIDs`,
`zone`/`zoneID`),
increments per-character progress, and resolves title tiers. Add new trackable things
(quests, items, zones, emotes) by writing a new source — the engine doesn't change.

Add a tracker from Lua (the in-game `/deed new` form is the normal route;
this is for scripting or seeding defaults):

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
