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

| Client | `.toc` | `## Interface` | Verified? |
|---|---|---|---|
| WoW-Forever 1.60.1 (build 70532) | `Deedkeeper.toc` | `16001` | ✅ measured in game |
| Mists of Pandaria Classic | `Deedkeeper_Mists.toc` | `50504` | ✅ measured in game |

Both are **Classic-flavoured clients on the modern engine** — WoW-Forever
reports product `wow_classic_beta` — and one codebase serves both. A client
loads the `.toc` matching its flavour and falls back to the plain one, so the
two coexist.

⚠️ **"Modern engine" does not mean "retail API".** Some modern namespaces are
present — `C_ChatInfo`, `C_Timer` and `C_Map` are all measured as available,
and the pre-Legion globals `SendAddonMessage` / `RegisterAddonMessagePrefix`
are measured as *absent* — but plenty of retail-only functions are missing.
`CombatLogGetCurrentEventInfo` is one of them, and assuming it cost us a
silently dead kill tracker on Forever.

**Before using any WoW API, check the Forever dump** rather than assuming:
`docs/api.json` in [Atraeau/WoW-Addons](https://github.com/Atraeau/WoW-Addons).
See [CLAUDE.md](CLAUDE.md) and `docs/forever-api-audit.md`.

Active development happens on **MoP Classic**; WoW-Forever is in beta until
early November. This is MoP *Classic*, not original 5.4 — original 5.4 has no
`C_ChatInfo` at all and would need a real port.

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
- [x] Single tabbed window (**Deeds** / **Nearby** / **New Deed**) + slash commands

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
- [x] **M4 published-deed sync** (`DEFPUB`) — definitions travel, so a rival
      sees a challenge by name under **Nearby** and accepts it in one click,
      getting the author's exact match rules and thresholds
- [x] **M5.0 simulated rivals** — `/deed simrival` fakes a claim through the
      real receive path, so stealing can be tested without a second player
- [x] **M5.1 holder + rank in the panel** — published deeds show who holds the
      title and where you stand; the row tooltip carries the full ladder
- [x] **M5.2 steal toasts** — a title changing hands shows on screen, not just
      in chat where it scrolls past mid-fight. `/deed toasts on|off|quiet|test`

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

**Testing a steal on your own.** `/deed simrival <deedId> <count> <name>`
fakes a rival's claim through the real receive path — decode, echo guard,
ladder, holder recompute, announcement — so you can watch a title change hands
without a second player:

```
/deed simrival boarsmustdie 25 Thrall    they take it off you
/deed test 30 Mottled Boar               you take it back
```

Each change of hands raises an on-screen toast as well as the chat line.
`/deed toasts test` previews both without needing a rival; `off` or `quiet`
if they get in the way.

Known limitations (by design, see `docs/rival-layer.md` §5):
- The rate cap only catches *acceleration* of a known rival; a brand-new contact's
  first absolute count can't be sanity-checked (no baseline). Social-trust covers this.
- Titles are **per-character**, so your own alts can take a title off you.
  That's deliberate — whether an alt competes is your call, made by choosing
  whether to track the deed on that character.

### Developing

Syntax-check every file (LuaJIT = Lua 5.1, matches WoW):
`powershell -ExecutionPolicy Bypass -File tools\check.ps1`

Run all headless test suites (from the addon root):
`luajit tools\test_engine.lua` · `test_ladder.lua` · `test_comm.lua` ·
`test_rival.lua` · `test_killsource.lua`

## Install

Copy the `Deedkeeper` folder into your client's AddOns directory:

- **MoP Classic** — `World of Warcraft\_classic_\Interface\AddOns\Deedkeeper\`
- **WoW-Forever** — may use its own install folder; check its launcher.

Both `.toc` files ship together and the client picks the right one.

## Try it

Everything lives in one TRP3-style window with a sidebar menu — **Deeds**, **Nearby** and
**New Deed** — rather than separate frames stacking on top of each other.
The slash commands below just open it on the right page. With TRP3 installed
it borrows TRP3's wooden frame art; without it, the same layout in stock textures.

```
/deed                  toggle the window (Deeds tab)
/deed nearby           open it on the Nearby tab
/deed new              open it on the New Deed tab
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

Open the **New Deed** tab (or `/deed new`) and fill in two things:

| Field | Example |
|---|---|
| **Name** | Murloc Hunting |
| **Match** | name contains `Murloc`, or specific NPC IDs |
| **Tiers** | *Murloc Menace* at 500, *Murloc Bane* at 5000 |

Every matching kill then counts, and the title is yours at 500. Check it
without farming via `/deed test 500 Murloc`, and `/deed help` prints this same
worked example in-game. To let others contest the title, `/deed publish <id>`.

**Competing with someone.** Publish a deed and nearby players can accept it:

1. You: `/deed publish boarsmustdie`
2. Them: the **Nearby** tab in `/deed` (or `/deed nearby`) → your deed is
   listed by name, with its tiers in the tooltip → **Accept**
3. Both kill things, within `YELL` range of each other

Accepting builds the deed from **your** definition — the same match rules and
the same thresholds — so the two of you are provably counting the same thing.
Nobody types a challenge id.

Definitions travel on publish and whenever a client says hello, so someone
logging in later picks up what's already out there; **Ask Again** re-requests
on demand.

`/deed adopt <yourDeedId> <challengeId>` still exists for pasting an id
directly, but **Nearby** is the easy path.

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
UI/MainFrame.lua         the window: sidebar menu, panes, lazy pane building
UI/MiniPanel.lua         Deeds pane -- the tracker list
UI/NearbyPanel.lua       Nearby pane -- challenges heard, with Accept
UI/AuthorForm.lua        New Deed / Edit Deed pane
UI/Toast.lua             steal banners (its own overlay, not a pane)
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
