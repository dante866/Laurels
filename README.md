# Laurels

A WoW addon for **custom, player-authored achievements and titles** — for RP flavor
and for issuing challenges to other players. Define a deed ("kill Kobolds"), give it
title tiers ("Kobold Slayer" at 1,000, "Kobold Destroyer" at 10,000), and the addon
tracks your progress and awards the title. A later version lets other addon users
**contest and steal** a title by out-doing you.

> These titles/achievements are **addon-rendered**, not real WoW titles. The game
> server controls real titles; an addon can't grant them. Laurels stores and
> displays them itself, and (v2) shares them peer-to-peer with other addon users.

## Supported clients

| Client | `.toc` | `## Interface` | Verified? |
|---|---|---|---|
| WoW-Forever 1.60.1 (build 70532) | `Laurels.toc` | `16001` | ✅ measured in game |
| Mists of Pandaria Classic | `Laurels_Mists.toc` | `50504` | ✅ measured in game |

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
- [x] **Quests, deaths, emotes, spell casts, fishing** — five more deed types
  (see [Deed types](#deed-types))
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

**Testing Nearby on your own.** `/deed simoffer` fakes a published deed from
"Simulated Rival", again through the real receive path, so you can Preview,
Accept or Decline it solo:

```
/deed simoffer           the offer appears in Nearby
/deed simoffer forge     an impostor resends it with gibberish -- ignored
/deed simoffer update    its author edits it -- an Update to preview
/deed simoffer long      a 14-tier deed arriving in parts -- Accept waits
/deed simoffer stall     the same with a part lost -- shows the stalled state
/deed simoffer clear     forget the offer (an accepted copy stays in Deeds)
```

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
`test_rival.lua` · `test_killsource.lua` · `test_sources.lua` · `test_sources2.lua` · `test_trp3.lua`

## Install

Copy the `Laurels` folder into your client's AddOns directory:

- **MoP Classic** — `World of Warcraft\_classic_\Interface\AddOns\Laurels\`
- **WoW-Forever** — may use its own install folder; check its launcher.

Both `.toc` files ship together and the client picks the right one.

## Try it

Everything lives in one TRP3-style window with a sidebar menu — **Deeds**, **Nearby** and
**New Deed** — rather than separate frames stacking on top of each other.
The slash commands below just open it on the right page. With TRP3 installed
it borrows TRP3's wooden frame art; without it, the same layout in stock textures.

The **wreath on the minimap** opens it too: click for your deeds, shift-click
for a new one, right-click for Nearby (its tooltip says how many are waiting),
drag to move it around the minimap edge. `/deed minimap` hides or shows it.

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

### Deed types

The **Event** dropdown picks what a deed counts. Every type can be narrowed by
a name filter and a zone; the labels change to say what the name refers to.

| Type | Counts | Filters | Example |
|---|---|---|---|
| **Kill** | your killing blows | mob name, NPC IDs | 500 kills, name has "Murloc" |
| **Melee swing** | your auto-attacks that deal damage | weapon (sword, axe or mace — either hand, or one-/two-handed only; dagger, fist, staff, polearm, unarmed), target name, target NPC IDs | 1000 hits with a sword |
| **Quest** | quests turned in | quest title, quest IDs | 100 quests in Westfall |
| **Death** | your deaths | cause, killer name, killer NPC IDs | 25 deaths, cause Falling |
| **Emote** | emotes you perform | which emote, target name, target NPC IDs | 50 `/hug`s, target has "Rabbit" |
| **Spell cast** | casts you finish, including item use and crafting | spell name, spell IDs | 100 Hearthstones |
| **Fishing** | catches (one per loot window) | caught item name | 1000 catches |
| **Player kill** | killing blows on other players | faction or class, victim name | 50 Horde |
| **Boss kill** | dungeon and raid bosses your group kills | boss name, encounter IDs | 10 Onyxia kills |
| **Duel** | duels you win or lose | won / lost, opponent name | 25 duels won |
| **Loot an item** | items you loot, by stack size | quality, item name, item IDs | 500 Linen Cloth |
| **Loot roll** | Need, Greed and Pass clicks | which roll, item name, item IDs | Need on 100 items |
| **Flight** | flights you take | destination name; zone is where you take off | 50 flights |
| **Titles held** | contested deeds you currently lead | deed name | *Title Hoarder*: lead 5 |

Kill and spell deeds need at least one filter — unfiltered they would count
every kill or every internal cast. The others are fine unfiltered ("die 100
times").

**Titles held** isn't counted from events: it's how many of your published
deeds you hold rank 1 in right now, read off the ladders, so it goes down
when someone takes one from you. A title you've earned from it is kept. Only
**contested** deeds count — at least one other player on the ladder — so
publishing deeds nobody else plays doesn't make you a hoarder.

Things to know:
- **Player kills** are killing blows, like kill deeds. Factions come from the
  victim's race; Pandaren don't say which side they chose, so only class
  filters catch them.
- **Duels** and **loot** read the game's own messages through its own
  templates, so they work in any game language.
- **Boss kills** count the group's kill, not just your killing blow. Whether
  Forever reports them for its dungeons is unconfirmed; a kill deed on the
  boss's NPC ID works either way.
- **Loot rolls** count when you click, even if you then cancel a Bind on
  Pickup warning.
- **Melee swings** count hits, not misses, dodges or parries. Special attacks
  (Heroic Strike) are spell casts, not swings. Dual-wielding, each hit counts
  for the weapon in the hand that swung. "Sword" takes one- and two-handed
  swords; "One-handed sword" and "Two-handed sword" take only that kind.
- **Quest zone** is where you *hand the quest in*, not where its objectives were.
- **Death cause** comes from the last damage you took within 10 seconds of
  dying. A death with nothing recent on record counts only for "any cause".
  Feign Death never counts.
- **Emotes** are typed as their slash command (`hug`, `lol`); the form turns
  them into the client's emote token. A bare `/hug` uses your current target.
- **Finding ids:** `/deed sources` prints the last thing each type saw this
  session, with its id — cast a spell, then run it to read the spell id.
- **Tiers:** the form starts with 5 rows; **Add 1 more tier** goes up to 20.
  Names and tier titles are capped at 48 characters.

**Long deeds travel in parts.** An addon message holds 255 bytes, about 7
tiers, so a published deed is sent as a `DEFPUB` head plus `DEFTIERS`
follow-ups (see `Rival/Comm.lua`). The head says how many tiers and parts
to expect. Until every tier is in, Nearby shows the deed as arriving, with
**Accept greyed out** and a note saying roughly how long — the author's addon
sends one message every 0.4 seconds, so it's usually a second or two. If a
part is lost the note says so after a few seconds, and **Ask Again** asks for
the deed again. A deed you already hold whole stays as it is until a resent
version has fully arrived, and an update to an accepted deed is only offered
once it's complete.

**Competing with someone.** Publish a deed and nearby players can accept it:

1. You: `/deed publish boarsmustdie`
2. Them: the **Nearby** tab in `/deed` (or `/deed nearby`) → your deed is
   listed by name → **Preview** shows all of it → **Accept** or **Decline**
3. Both kill things, within `YELL` range of each other

Accepting builds the deed from **your** definition — the same match rules and
the same thresholds — so the two of you are provably counting the same thing.
Nobody types a challenge id.

Definitions travel on publish and whenever a client says hello, so someone
logging in later picks up what's already out there; **Ask Again** re-requests
on demand.

**Only the author can change a deed, and only with your OK.** An offer is
tied to whoever first broadcast it, by the sender name Blizzard's server
attaches to each addon message, which another addon can't fake. A message
reusing that challenge id from anyone else is ignored. Once you've accepted a
deed, the author's later edits arrive in Nearby as an **Update** to preview:
**Accept Update** applies it (your progress is kept), **Keep Mine** turns that
version down. **Decline** hides an offer for good; `/deed undecline` brings
declined offers back.

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
Tracking/Kinds.lua       every deed type: labels, filters, descriptions
Tracking/Signals.lua     shared signal helpers: zone, NPC id from GUID, combat log
Tracking/Engine.lua      owns trackers; matches signals -> increments -> tiers
Tracking/Sources/
  KillSource.lua         combat log -> { kind="kill", name, npcID }
  SwingSource.lua        combat log SWING_DAMAGE -> { kind="swing", weapon, name, id }
  QuestSource.lua        QUEST_TURNED_IN -> { kind="quest", id, name }
  DeathSource.lua        PLAYER_DEAD + last hit -> { kind="death", cause, name, id }
  EmoteSource.lua        DoEmote/PerformEmote hooks -> { kind="emote", emote, name, id }
  SpellSource.lua        UNIT_SPELLCAST_SUCCEEDED -> { kind="spell", id, name }
  FishSource.lua         fishing loot window -> { kind="fish", names }
  HoldSource.lua         ladders -> how many contested deeds you lead (set, not counted)
  DuelSource.lua         your duel results, from the system line -> { kind="duel", result, name }
  LootSource.lua         your loot line -> { kind="loot", id, name, quality, amount }
  FlightSource.lua       TakeTaxiNode + take-off -> { kind="flight", name }
  RollSource.lua         RollOnLoot hook -> { kind="roll", roll, id, name }
  BossSource.lua         ENCOUNTER_END / BOSS_KILL -> { kind="boss", id, name }
Integrations/TRP3.lua    TRP3 names for rivals and authors (inert without TRP3)
UI/MainFrame.lua         the window: sidebar menu, panes, lazy pane building
UI/MiniPanel.lua         Deeds pane -- the tracker list
UI/NearbyPanel.lua       Nearby pane -- challenges heard, with Accept
UI/AuthorForm.lua        New Deed / Edit Deed pane
UI/Toast.lua             steal banners (its own overlay, not a pane)
UI/UnitTooltip.lua       "Deeds: ..." line on a mob's tooltip
UI/MinimapButton.lua     the wreath button on the minimap
Media/LaurelsIcon.tga    the wreath (original art, drawn by tools/make_icon.ps1)
```

A **source** turns WoW events into normalized **signals**:
`{ kind = "kill", name = "Kobold Vermin", npcID = 1234, zone = "Elwynn Forest",
zoneID = 37, amount = 1 }`.
The **engine** matches each signal against every tracker whose `event` equals the
signal `kind`, applies the tracker's `match` criteria (`nameContains`,
`npcIDs`/`ids`, `zone`/`zoneID`, and `cause`/`weapon`/`emote` qualifiers),
increments per-character progress, and resolves title tiers. A new deed type is
a new source plus an entry in `Tracking/Kinds.lua` — the engine doesn't change.

Add a tracker from Lua (the in-game `/deed new` form is the normal route;
this is for scripting or seeding defaults):

```lua
local ns = select(2, ...)  -- or hook LaurelsDB directly
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

**TRP3 integration.** Done for names: with Total RP 3 installed, ladders,
steal pop-ups and deed authors show players by their **TRP3 name** where TRP3
knows their profile, and by game name otherwise (`Integrations/TRP3.lua`,
public TRP3 API only; `/deed rpnames` turns it off). The core stays
TRP3-agnostic and works the same without it. Showing *earned titles* on a
TRP3 profile, or a TRP3-Extended "campaign/quest" module, would bind us to
their data model — revisit once the core is proven between real players.
