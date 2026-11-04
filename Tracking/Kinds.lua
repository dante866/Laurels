local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Kinds: every type of deed, described in one place.
--
-- A deed's `event` names its kind. Each kind's source emits signals of that
-- kind (see Tracking/Sources/), and everything that has to present or carry a
-- deed -- the authoring form, the Deeds and Nearby descriptions, the DEFPUB
-- encoding -- reads this table rather than special-casing kinds itself.
--
-- Every kind shares the same match vocabulary, so the engine's matcher needs
-- no per-kind code:
--   nameContains  text the signal's name must contain (mob, quest title,
--                 killer, emote target, spell, caught item)
--   ids / npcIDs  numeric ids (NPC, quest or spell). Kill deeds keep the
--                 original `npcIDs` key so existing deeds and older clients
--                 are untouched; every other kind uses `ids`.
--   zone/zoneID   where it happened
--   cause, emote  the one kind-specific `qualifier`, for deaths and emotes
-- ---------------------------------------------------------------------------

local Kinds = {}
ns.Kinds = Kinds

Kinds.ORDER = { "kill", "quest", "death", "emote", "spell", "fish" }

Kinds.defs = {
    kill = {
        label = "Kill", plural = "kills",
        nameLabel = "Mob name has", idsLabel = "NPC IDs", idNoun = "NPC ID",
        idsKey = "npcIDs",
        zoneHint = "optional \226\128\147 only counts kills in that zone",
        -- An unfiltered kill deed would count every kill in the game.
        needsFilter = true,
    },
    quest = {
        label = "Quest", plural = "quests turned in",
        nameLabel = "Quest title has", idsLabel = "Quest IDs", idNoun = "quest ID",
        zoneHint = "optional \226\128\147 the zone you hand the quest in",
    },
    death = {
        label = "Death", plural = "deaths",
        nameLabel = "Killer name has", idsLabel = "Killer NPC IDs",
        idNoun = "killer NPC ID", qualifier = "cause",
        zoneHint = "optional \226\128\147 only counts deaths in that zone",
    },
    emote = {
        label = "Emote", plural = "emotes",
        nameLabel = "Target name has", idsLabel = "Target NPC IDs",
        idNoun = "target NPC ID", qualifier = "emote",
        zoneHint = "optional \226\128\147 only counts emotes in that zone",
    },
    spell = {
        label = "Spell cast", plural = "casts",
        nameLabel = "Spell name has", idsLabel = "Spell IDs", idNoun = "spell ID",
        zoneHint = "optional \226\128\147 only counts casts in that zone",
        -- The client reports a stream of internal casts (auto-attacks, hidden
        -- procs), so "any spell" would count noise rather than anything chosen.
        needsFilter = true,
    },
    fish = {
        label = "Fishing", plural = "fishing catches",
        nameLabel = "Catch name has",
        -- No ids: a catch is a loot window, and item ids aren't asked for.
        zoneHint = "optional \226\128\147 only counts catches in that zone",
    },
}

-- Death causes, in menu order. `other` is what a death with no recent
-- damage on record reports; it is never offered as a filter.
Kinds.CAUSE_ORDER = { "creature", "player", "falling", "drowning", "fire",
                      "lava", "slime", "fatigue" }
Kinds.CAUSES = {
    creature = "Killed by a creature",
    player   = "Killed by a player",
    falling  = "Falling",
    drowning = "Drowning",
    fire     = "Fire",
    lava     = "Lava",
    slime    = "Slime",
    fatigue  = "Fatigue",
}

function Kinds.Get(kind)
    return Kinds.defs[kind or "kill"]
end

-- The id list, whichever key holds it.
function Kinds.IDs(m)
    return m and (m.ids or m.npcIDs)
end

-- One line saying what a deed counts, e.g.
--   kills: mob name has "Boar", in Durotar
--   deaths: falling
--   emotes: /hug, target name has "Rabbit"
function Kinds.Describe(kind, m)
    local def = Kinds.Get(kind)
    if not def then
        return ("a kind of deed this version can't count (%s)"):format(tostring(kind))
    end
    m = m or {}
    local parts = {}
    if m.cause then
        parts[#parts + 1] = string.lower(Kinds.CAUSES[m.cause] or m.cause)
    end
    if m.emote then
        parts[#parts + 1] = "/" .. string.lower(m.emote)
    end
    if m.nameContains then
        parts[#parts + 1] = ('%s "%s"'):format(string.lower(def.nameLabel), m.nameContains)
    end
    local ids = Kinds.IDs(m)
    if ids and #ids > 0 and def.idNoun then
        parts[#parts + 1] = ("%d %s%s"):format(#ids, def.idNoun, #ids == 1 and "" or "s")
    end
    if m.zone then
        parts[#parts + 1] = "in " .. m.zone
    elseif m.zoneID then
        parts[#parts + 1] = "in map " .. tostring(m.zoneID)
    end
    if #parts == 0 then return "any " .. def.plural end
    return def.plural .. ": " .. table.concat(parts, ", ")
end
