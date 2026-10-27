# Deedkeeper

A WoW addon for **custom, player-authored achievements and titles** — for RP flavor
and for issuing challenges to other players. Define a deed ("kill Kobolds"), give it
title tiers ("Kobold Slayer" at 1,000, "Kobold Destroyer" at 10,000), and the addon
tracks your progress and awards the title. A later version lets other addon users
**contest and steal** a title by out-doing you.

> These titles/achievements are **addon-rendered**, not real WoW titles. The game
> server controls real titles; an addon can't grant them. Deedkeeper stores and
> displays them itself, and (v2) shares them peer-to-peer with other addon users.

## Supported clients

Both are **modern-engine** clients (`C_ChatInfo`, `C_Timer`, `C_Map` all
present), so one codebase serves both. A client loads the `.toc` matching its
flavour and falls back to the plain one, so these coexist:

| Client | `.toc` | `## Interface` | Verified? |
|---|---|---|---|
| WoW-Forever 1.60.1 (build 70532) | `Deedkeeper.toc` | `16001` | ✅ measured in game |
| Mists of Pandaria Classic | `Deedkeeper_Mists.toc` | `50504` | ✅ measured in game |

Active development happens on **MoP Classic**; WoW-Forever is in beta until
early November. Note this is MoP *Classic*, on the modern client engine — not
original 5.4, which has no `C_ChatInfo` and would need real porting.

⚠️ After a client patch, re-check with `/run print(GetBuildInfo())`. It prints
*version, build, date, tocversion*, and the **last** value is what `## Interface`
needs — **not the build number**. On WoW-Forever those two are nowhere near each
other (`16001` vs `70532`), and mixing them up makes the addon show as
incompatible and silently not load: no error, slash commands just don't register.
If that happens, tick "Load out of date AddOns" at character select to load it
regardless while you correct the number.

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
- [x] **Adaptive transport** — the broadcast channel is negotiated per client
      rather than hardcoded, with built-in send throttling
- [ ] M4 published-deed definition sync (DEFPUB adopt) — currently two clients must
      share the same `uuid`; adoption makes that automatic
- [ ] M5 holder/rank in the panel UI + steal toasts

⚠️ **Never tested between two real clients.** Every test is headless against a
fake bus. Messages provably leave and your own come back, but no other
player's client has yet received, decoded and announced a claim — which is the
entire point of v3. M4 and M5 both build on that assumption.

### How far your ladder reaches

Which chat types carry addon messages is a **per-client fact**, and the two
targets are exact opposites:

| Channel | MoP Classic | WoW-Forever |
|---|---|---|
| `SAY` / `YELL` | ✅ works | rejected |
| custom `CHANNEL` | rejected | ✅ works |

So on **MoP Classic the ladder is proximity-based** and the original "nearby
rivals" design works as intended. On **WoW-Forever it can't be** — there is no
range-limited transport, so the ladder is server-wide over a shared hidden
channel and everyone with the addon hears every published claim.

Each `.toc` declares its own default via `X-BroadcastChannel`. If a client
refuses it anyway, the addon falls back down `CHANNEL → YELL → GUILD → SAY`,
remembers the result, and **tells you in chat** — the fallbacks differ in
*reach*, not just plumbing, so your ladder's radius changes with them.
Override with `/deed channel <type>`; `/deed commtest` shows what a client
accepts.

On WoW-Forever you'll see the client's **Code of Conduct notice** on login.
That's the game reacting to joining a channel, not an addon error.

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

Copy the `Deedkeeper` folder into your client's AddOns directory:

- **MoP Classic** — `World of Warcraft\_classic_\Interface\AddOns\Deedkeeper\`
- **WoW-Forever** — may use its own install folder; check its launcher.

Both `.toc` files ship together and the client picks the right one.

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

**Editing a deed.** Hit **Edit** on its row in `/deed`, or `/deed edit <id>`.
The form opens populated, and saving **keeps the deed's id and your progress** —
fixing a typo shouldn't cost you 400 boars.

The id itself can't be changed: progress is stored against it and the rival
ladder keys on it, so renaming would orphan both. Tier edits re-resolve which
title you've earned, so lowering a threshold below your count grants that
title immediately, and deleting tiers can take one back. Editing a *published*
deed warns you, since rivals are still contesting the version they have —
until M4, definitions don't propagate.

**Finding a deed's id.** `publish`, `unpublish`, `rivals` and `reset` all take
one, so it's shown in three places: dimmed at the end of each row in `/deed`,
in the hover tooltip on that row (along with the exact commands), and in
`/deed list`. Creating a deed prints its id too. Ids are derived from the deed
name — "Mottled Boars" becomes `mottledboars` — so they're typeable; a
collision gets a numeric suffix.

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
