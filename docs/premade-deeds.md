# Premade Deeds — Production Specification

**Status:** design / prep (not yet implemented)
**Branch:** `premade-deeds`
**Author of record:** charles.c.meyer@gmail.com
**Last updated:** 2026-10-22

---

## 1. Summary

A built-in, opt-in **catalog of kill deeds** covering killable mobs across the zones
of WoW-Forever. Each catalog entry, when a player adds it, becomes a normal tracker
(via the existing `ns.Engine:CreateTracker`) with four ascending kill-count **tiers**,
each granting an addon-rendered **title**:

| Tier | Example threshold | Title pattern | Example |
|------|-------------------|---------------|---------|
| 1 | 500 | `Enemy of the <plural>` | Enemy of the Kobolds |
| 2 | 1,000 | `<singular> Slayer` | Kobold Slayer |
| 3 | 10,000 | `<singular> Destroyer` | Kobold Destroyer |
| 4 | 25,000 (`10,000+`) | `Annihilator of the <plural>` | Annihilator of the Kobolds |

Thresholds above are the **"Abundant" band**; they scale **down** for less-common mobs
so the deed stays reachable (see §5). The top tier `10,000+` from the original idea is
pinned here to a concrete default of **25,000**, centrally tunable.

The catalog is **data, not active trackers.** Nothing is tracked until the player adds
it from the Premade browser. This keeps SavedVariables small and the engine fast
(§7).

---

## 2. Goals / Non-goals

**Goals**
- A browsable catalog, organized by **zone → mob**, with one-click "Add deed."
- Consistent, auto-generated tiers + titles so thousands of mobs need no hand-tuning.
- Tier thresholds that **scale to mob abundance** so rare/low-population mobs
  (e.g. the Dust Devils of Westfall) don't demand unreachable kill counts.
- Reuse the existing engine, sources, and SavedVariables patterns unchanged.

**Non-goals (for this section)**
- No changes to the tracking engine's matching logic (unless we adopt the optional
  zone-aware signal in §6.2 — called out explicitly as opt-in).
- Not the rival/steal layer (that's the separate v2 roadmap item).
- Not real WoW titles — these remain addon-rendered, as the rest of Deedkeeper.

---

## 3. Terminology

- **Mob family** — a named group tracked as one deed, e.g. "Kobold", "Dust Devil",
  "Defias". A family has a **singular** and **plural** display form for titles.
- **Catalog entry** — one addable deed = (mob family) scoped to (zone). "Dust Devils
  **of Westfall**" and "Dust Devils **of the Searing Gorge**" are two entries.
- **Abundance band** — a bucket (Abundant / Common / Uncommon / Scarce / …) that
  determines a catalog entry's tier thresholds (§5).
- **Band template** — the 4 threshold numbers for a band, defined once and shared.

---

## 4. Granularity decision (important)

"Every killable mob in every zone" could mean one deed per NPC ID (tens of thousands,
mostly unfun — "Kobold Vermin" vs "Kobold Laborer" as separate titles). Recommended
unit instead:

> **Catalog entry = mob family × zone.**

Rationale: it matches how titles read ("the Dust Devils **of Westfall**"), collapses
near-duplicate NPC variants into one satisfying goal, and is far more tractable to
generate and browse. A family groups all NPC variants sharing its significant name
token(s) within a zone (all Kobold * in Elwynn → "Kobolds of Elwynn").

Zone scoping has a data consequence — see §6.

---

## 5. Tier & title system

### 5.1 Title grammar

Titles need both a **singular** and a **plural** form of the family name:

- T1 `Enemy of the {plural}`
- T2 `{singular} Slayer`
- T3 `{singular} Destroyer`
- T4 `Annihilator of the {plural}`

Do **not** auto-pluralize naively. Store an explicit `{singular, plural}` per family,
seeded by a pluralizer with an **exceptions table** (e.g. Murloc→Murlocs, Harpy→Harpies,
Naga→Naga, Yeti→Yetis). Families whose name is already plural or a proper mass noun
(e.g. "Defias") get hand-set forms. Keep titles readable; no hard length cap since
they're addon-rendered, but aim ≤ ~24 chars.

### 5.2 Tiers are derived, not stored per entry

To avoid bloating the catalog with repeated numbers and strings (§7), a catalog entry
stores only: the **family key**, the **band id**, and the **match** data. Tiers and
title strings are **computed at display/add time** from:

- band id → band template (the 4 thresholds), and
- family key → `{singular, plural}` → the four title patterns.

So `Engine:CreateTracker` is handed a fully-expanded `{name, event, match, tiers}` only
at the moment of adding.

---

## 6. Matching & zone scoping

An entry must count kills of its family **in its zone**. The engine currently matches on
`nameContains` / `npcIDs` only (no zone). Two ways to honor "of <zone>":

### 6.1 Primary: per-zone `npcIDs` (no engine change)
Each entry carries the explicit list of NPC IDs for that family **in that zone**. The
same family in another zone has different IDs, so zone scoping falls out naturally.
Requires a reliable NPC-ID-per-zone dataset (§8) but needs **zero** engine changes.

### 6.2 Optional enhancement: zone-aware signal
Extend `KillSource` to include the current zone on each kill signal and add an optional
`zone` criterion to tracker `match`. Then an entry can match `nameContains="Dust Devil"`
+ `zone="Westfall"`. Cleaner data, but it **does** touch the engine/source and must be
coordinated with the main `master` session. Treat as a stretch goal; §6.1 is the
baseline.

---

## 7. Performance & footprint

- **Opt-in only.** Catalog entries are inert data; only *added* deeds become trackers
  the engine iterates. A player with 10 added deeds pays for 10, not 10,000.
- **Compact storage.** Per-entry data is minimal (family key, band id, npcID list).
  Shared band templates and derived titles mean no per-entry string/number duplication.
- **Split by zone.** Generate one data file per zone (`Premade/Catalog/<Zone>.lua`)
  plus a lightweight index. WoW parses all `.toc`-listed Lua at load, so if total size
  hurts load time, fall back to lazy-loading a zone's data on first browse (via a
  manifest + on-demand `LoadAddOn`-style split or a single compressed blob decoded when
  the panel opens). Decide once real data volume is known.

---

## 8. Data sourcing (the main production dependency)

Generating this catalog requires, per mob: **npcID, name, rank (normal/elite/rare/boss),
home zone, and a population/spawn signal.** Options, best first:

1. **Server / emulator world DB** (if obtainable). A creature spawn table
   (`creature` + `creature_template`-style) gives npcID, name, rank, zone, **and spawn
   counts** — the spawn count per zone *is* the population differential, letting §5
   banding be computed directly from data instead of guessed. Strongly preferred if
   WoW-Forever exposes or is built on an accessible DB. ⚠️ Verify whether it's a
   standard emulator schema or a bespoke retail-based build before assuming.
2. **Community/retail dataset** for the base build WoW-Forever derives from (Wowhead-
   style exports). Good for names/zones/rank; population is approximate.
3. **In-game harvesting companion.** A dev/opt-in mode that logs every killed/seen mob
   with zone over time, building an authoritative picture of what's actually live on the
   server. Slow, but ground truth; good for filling gaps and validating.

The data layer is the biggest risk/unknown. Lock down the source before generating.

---

## 9. Abundance banding

Each entry's tiers come from its band. Defaults (starting values — tune centrally):

| Band | Use for | T1 | T2 | T3 | T4 |
|------|---------|----|----|----|----|
| **Abundant** | dense zone trash, fast respawn, zone staple (Kobolds, Defias, Murlocs) | 500 | 1,000 | 10,000 | 25,000 |
| **Common** | ordinary packs, moderate density | 250 | 750 | 5,000 | 12,000 |
| **Uncommon** | sparse or roaming, lower density | 100 | 400 | 2,000 | 5,000 |
| **Scarce** | few spawns per zone (e.g. **Dust Devils of Westfall**) | 25 | 100 | 500 | 1,500 |
| **Trivial** | tiny-count or incidental killables | 10 | 50 | 200 | 500 |
| **Named/Rare elite** | unique/rare spawns — **not bulk-farmable** | *exclude by default* (see note) |

**Note on named/rare:** a unique rare that spawns one at a time can't support 4 kill
tiers. Default: **exclude** rares/bosses from the premade catalog. If desired later,
give them a separate single-milestone deed ("slay X" ×1/×10) rather than the 4-tier
template.

### 9.1 Assigning a band

If a real spawn-count exists (§8 option 1), map count → band by thresholds (define the
cutoffs once; e.g. ≥X spawns = Abundant, … ). Otherwise classify by this ladder:

1. rank is rare/boss, or creature is non-combat/critter → **exclude**.
2. else by density proxy (spawn points, roam vs fixed) → Abundant/Common/Uncommon/Scarce.
3. unknown → default **Common**.
4. a **curated overrides file** always wins (e.g. force "Dust Devil / Westfall" →
   Scarce). This is where the population-differential hand-tuning lives.

---

## 10. Catalog data format (illustrative)

Derived-at-runtime schema. Band templates and families defined once; entries are terse.

```lua
-- Premade/Bands.lua
return {
  abundant = { 500, 1000, 10000, 25000 },
  common   = { 250,  750,  5000, 12000 },
  uncommon = { 100,  400,  2000,  5000 },
  scarce   = {  25,  100,   500,  1500 },
  trivial  = {  10,   50,   200,   500 },
}

-- Premade/Families.lua   (key -> display forms)
return {
  kobold    = { singular = "Kobold",     plural = "Kobolds" },
  dustdevil = { singular = "Dust Devil", plural = "Dust Devils" },
  defias    = { singular = "Defias",     plural = "Defias" },   -- hand-set
}

-- Premade/Catalog/Westfall.lua   (one file per zone)
return {
  zone = "Westfall",
  entries = {
    { family = "defias",    band = "abundant", npcIDs = { 448, 457, 458, 459 } },
    { family = "dustdevil", band = "scarce",   npcIDs = { 456 } },
    -- ...
  },
}
```

Title + tier expansion happens when browsing/adding:

```lua
-- pseudocode
local fam   = Families[entry.family]
local th    = Bands[entry.band]
local tiers = {
  { count = th[1], title = ("Enemy of the %s"):format(fam.plural) },
  { count = th[2], title = ("%s Slayer"):format(fam.singular) },
  { count = th[3], title = ("%s Destroyer"):format(fam.singular) },
  { count = th[4], title = ("Annihilator of the %s"):format(fam.plural) },
}
ns.Engine:CreateTracker{
  name  = ("%s of %s"):format(fam.plural, zone),
  event = "kill",
  match = { npcIDs = entry.npcIDs },   -- or nameContains + zone (§6.2)
  tiers = tiers,
}
```

---

## 11. UI (`UI/PremadePanel.lua`)

- Entry point: a button on the existing MiniPanel and a slash verb, e.g. `/deed premade`.
- Layout: zone list → mob-family list within a zone. Each row shows family name, band,
  and the four tier/title previews; an **Add** button; a check/greyed state if already
  added. Search box filtering by mob or zone. Match existing UI style/patterns.
- Adding calls the expansion in §10 → `CreateTracker`. Re-adding an existing deed is a
  no-op (or offers "reset").

---

## 12. Edge cases

- **Mob in multiple zones** → separate entry per zone (by design, §4).
- **Already-plural / proper-noun names** ("Defias", "Naga") → hand-set family forms.
- **Critters / non-hostile killables** → excluded by default; optional "Critters" novelty
  band later.
- **Faction/phase/event-only mobs** → flag in data; may exclude or label.
- **Grammatically awkward titles** → overridable per family (store explicit title strings
  on the family to bypass the pattern).
- **Band feels wrong in play** → fix via the overrides file, not by editing thousands of
  entries.

---

## 13. Suggested phased implementation

1. **Spine, hardcoded sample.** Bands.lua, Families.lua, one hand-written zone
   (Elwynn or Westfall), the §10 expansion, and `CreateTracker` wiring. Register files
   in `Deedkeeper.toc`. Prove the end-to-end add flow with `tools/check.ps1` +
   `tools/test_engine.lua`.
2. **UI.** `PremadePanel.lua` browser over the sample zone; Add / already-added states.
3. **Data layer.** Lock the source (§8); build the generator (source → classify → band →
   families → per-zone Lua). Keep the overrides file for population tuning.
4. **Full generation.** Produce all zones; measure footprint/load time; apply §7 lazy
   loading if needed.
5. **Polish.** Title exceptions pass, band tuning pass, search, edge-case flags.

---

## 14. Open questions for the user

1. **Zone scoping** — OK to require per-zone NPC-ID lists (§6.1, no engine change), or do
   you want the zone-aware signal (§6.2) coordinated with the main session?
2. **Granularity** — confirm "mob family × zone" (§4) vs literally per-NPC-ID.
3. **Rares/bosses** — exclude from premades (recommended) or give them a special
   single-milestone deed?
4. **Data source** — is the WoW-Forever creature/spawn DB reachable? That single answer
   decides whether banding is data-driven (ideal) or heuristic + curated.
5. **Top tier** — keep 25,000 as the `10,000+` tier, or a different ceiling?
```
