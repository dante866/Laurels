-- Headless test for the quest, death, emote, spell and fishing sources.
-- Run from the addon root:  luajit tools/test_sources.lua
--
-- Each source is driven through fake WoW events into the real Engine, and the
-- assertions are on deed progress -- so a pass means the whole path works,
-- event to signal to match to count. What can't be tested here is whether a
-- client actually fires these events the way the API dump describes.

time = os.time
tinsert = table.insert

-- --- fake client -----------------------------------------------------------

local clock = 100
GetTime = function() return clock end

local frames = {}
function CreateFrame()
    local f = { events = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:RegisterUnitEvent(e) self.events[e] = true end
    function f:SetScript(_, fn) self.handler = fn end
    frames[#frames + 1] = f
    return f
end
local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.handler then f.handler(f, event, ...) end
    end
end

function hooksecurefunc(a, b, c)
    local t, name, hook = _G, a, b
    if type(a) == "table" then t, name, hook = a, b, c end
    local orig = t[name]
    t[name] = function(...)
        local r = { orig(...) }
        hook(...)
        return unpack(r)
    end
end

local PLAYER = "Player-4618-00D1568C"
local RIVAL  = "Player-4618-00ABCDEF"
local HOGGER = "Creature-0-3299-0-7-448-000136DF22"
local RABBIT = "Creature-0-3299-0-7-721-000136DF99"

local target -- { name, guid } or nil
UnitGUID = function(unit)
    if unit == "player" then return PLAYER end
    if unit == "target" and target then return target.guid end
end
UnitName = function(unit) return unit == "target" and target and target.name or nil end
UnitExists = function(unit) return unit == "target" and target ~= nil end

local zoneName = "Elwynn Forest"
GetZoneText = function() return zoneName end

strsplit = function(delim, str)
    local parts, i = {}, 1
    while true do
        local j = string.find(str, delim, i, true)
        if not j then parts[#parts + 1] = string.sub(str, i); break end
        parts[#parts + 1] = string.sub(str, i, j - 1)
        i = j + 1
    end
    return unpack(parts)
end

-- Quests
local questTitles = { [62] = "The Fargodeep Mine" }
C_QuestLog = { GetTitleForQuestID = function(id) return questTitles[id] end }
local rewardTitle
GetTitleText = function() return rewardTitle end

-- Emotes: DoEmote calls PerformEmote, as it might on a real client, so a
-- single emote passes through both hooks.
C_ChatInfo = { PerformEmote = function() return true end }
DoEmote = function(token, tgt) return C_ChatInfo.PerformEmote(token, tgt) end

-- Spells
local spellNames = { [8690] = "Hearthstone", [7928] = "Silk Bandage" }
C_Spell = { GetSpellName = function(id) return spellNames[id] end }

-- Fishing
local fishing, loot = false, {}
IsFishingLoot = function() return fishing end
GetNumLootItems = function() return #loot end
GetLootSlotInfo = function(slot) return "icon", loot[slot], 1 end

-- Melee: slot -> itemID, itemID -> weapon subclass (class 2 = weapon).
local equipped = { [16] = 1001, [17] = 1002 }
local SUBCLASS = { [1001] = 7, [1002] = 15, [1003] = 1, [1004] = 8 }
GetInventoryItemID = function(_, slot) return equipped[slot] end
C_Item = { GetItemInfoInstant = function(id)
    return id, "Weapon", "?", "INVTYPE_WEAPON", "icon", 2, SUBCLASS[id]
end }

-- --- addon -----------------------------------------------------------------

local function deed(id, event, match)
    return { id = id, name = id, event = event, match = match,
             tiers = { { count = 1000, title = "T" } } }
end

local ns = {
    db = { trackers = {
        deed("anyquest",  "quest", {}),
        deed("minequest", "quest", { nameContains = "Mine" }),
        deed("quest62",   "quest", { ids = { 62 } }),
        deed("quest99",   "quest", { ids = { 99 } }),
        deed("westquest", "quest", { zone = "Westfall" }),

        deed("anydeath",  "death", {}),
        deed("fallen",    "death", { cause = "falling" }),
        deed("hoggered",  "death", { nameContains = "Hogger" }),
        deed("hogger448", "death", { ids = { 448 } }),
        deed("ganked",    "death", { cause = "player" }),

        deed("hugs",      "emote", { emote = "HUG" }),
        deed("bunnyhugs", "emote", { emote = "HUG", nameContains = "Rabbit" }),
        deed("rabbit721", "emote", { ids = { 721 } }),
        deed("anyemote",  "emote", {}),

        deed("hearth",    "spell", { nameContains = "Hearth" }),
        deed("hearth8690","spell", { ids = { 8690 } }),
        deed("duelspell", "spell", { ids = { 7266 } }),

        deed("anyfish",   "fish",  {}),
        deed("smallfish", "fish",  { nameContains = "Smallfish" }),

        deed("anyswing",  "swing", {}),
        deed("swordhits", "swing", { weapon = "sword" }),
        deed("daggerhits","swing", { weapon = "dagger" }),
        deed("axehits",   "swing", { weapon = "axe" }),
        deed("sword1h",   "swing", { weapon = "sword1h" }),
        deed("sword2h",   "swing", { weapon = "sword2h" }),
        deed("axe2h",     "swing", { weapon = "axe2h" }),
        deed("axe1h",     "swing", { weapon = "axe1h" }),
        deed("fisticuffs","swing", { weapon = "unarmed" }),
        deed("boarsword", "swing", { weapon = "sword", nameContains = "Boar" }),
    } },
    charDB = { progress = {}, earned = {} },
}
function ns:Print() end

for _, f in ipairs({ "Tracking/Kinds.lua", "Tracking/Signals.lua",
        "Tracking/Engine.lua", "Tracking/Sources/QuestSource.lua",
        "Tracking/Sources/DeathSource.lua", "Tracking/Sources/EmoteSource.lua",
        "Tracking/Sources/SpellSource.lua", "Tracking/Sources/FishSource.lua",
        "Tracking/Sources/SwingSource.lua" }) do
    assert(loadfile(f))("Laurels", ns)
end
local Engine = ns.Engine
Engine:Init()
for _, k in ipairs({ "Quest", "Death", "Emote", "Spell", "Fish", "Swing" }) do
    Engine:RegisterSource(string.lower(k), ns[k .. "Source"])
end

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end
local function p(id) return Engine:GetProgress(id) end

-- --- quests ----------------------------------------------------------------

fire("QUEST_TURNED_IN", 62, 100, 50)
check("quest: any-quest deed counts", p("anyquest") == 1)
check("quest: title filter matches", p("minequest") == 1)
check("quest: id filter matches", p("quest62") == 1)
check("quest: other id ignored", p("quest99") == 0)
check("quest: other zone ignored", p("westquest") == 0)

-- Title unknown by id: the reward panel's title is used instead.
rewardTitle = "Report to Goldshire Mine"
fire("QUEST_COMPLETE")
fire("QUEST_TURNED_IN", 99)
check("quest: falls back to the reward panel title", p("minequest") == 2)
check("quest: second id counts", p("quest99") == 1)
-- And the fallback doesn't leak into the next turn-in.
rewardTitle = nil
fire("QUEST_TURNED_IN", 5)
check("quest: fallback title cleared after use", p("minequest") == 2)
check("quest: untitled quest still counts as a quest", p("anyquest") == 3)

-- --- deaths ----------------------------------------------------------------

local function hit(subevent, srcGUID, srcName, dest, envType)
    fire("COMBAT_LOG_EVENT_UNFILTERED", clock, subevent, false, srcGUID, srcName,
        0, 0, dest or PLAYER, "Me", 0, 0, envType)
end

hit("ENVIRONMENTAL_DAMAGE", nil, nil, PLAYER, "Falling")
fire("PLAYER_DEAD")
check("death: falling counts as falling", p("fallen") == 1)
check("death: any-death deed counts", p("anydeath") == 1)
check("death: falling isn't Hogger", p("hoggered") == 0)

hit("SWING_DAMAGE", HOGGER, "Hogger")
hit("SWING_DAMAGE", RABBIT, "Rabbit", "Creature-0-1-1-1-1-1") -- not at me
fire("PLAYER_DEAD")
check("death: killer name matches", p("hoggered") == 1)
check("death: killer npc id matches", p("hogger448") == 1)
check("death: damage to others is ignored", p("anydeath") == 2)

hit("SPELL_DAMAGE", RIVAL, "Ganker")
fire("PLAYER_DEAD")
check("death: a player killer is cause player", p("ganked") == 1)
check("death: a player killer has no npc id", p("hogger448") == 1)

-- A hit long before the death isn't what killed you.
hit("ENVIRONMENTAL_DAMAGE", nil, nil, PLAYER, "Falling")
clock = clock + 60
fire("PLAYER_DEAD")
check("death: stale hit isn't the cause", p("fallen") == 1)
check("death: still counts as a death", p("anydeath") == 4)
-- And the remembered hit is spent by the death that used it.
fire("PLAYER_DEAD")
check("death: no hit on record is just a death", p("anydeath") == 5 and p("fallen") == 1)

-- --- emotes ----------------------------------------------------------------

target = { name = "Rabbit", guid = RABBIT }
DoEmote("HUG")
check("emote: one emote through both hooks counts once", p("hugs") == 1)
check("emote: target name filter matches", p("bunnyhugs") == 1)
check("emote: target npc id filter matches", p("rabbit721") == 1)

clock = clock + 1
DoEmote("WAVE")
check("emote: a different emote isn't a hug", p("hugs") == 1)
check("emote: any-emote deed counts it", p("anyemote") == 2)

clock = clock + 1
target = nil
DoEmote("HUG", "Thrall")
check("emote: typed target name is used", p("hugs") == 2 and p("bunnyhugs") == 1)

clock = clock + 1
DoEmote("HUG")
clock = clock + 1
DoEmote("HUG")
check("emote: repeats a second apart both count", p("hugs") == 4)

local R = ns.EmoteSource.ResolveToken
check("emote: plain word resolves to its token", R("hug") == "HUG")
check("emote: leading slash is ignored", R("/hug") == "HUG")
check("emote: blank is nil", R("  ") == nil)
hash_EmoteTokenList = { ["/LOL"] = "LAUGH" }
check("emote: client table maps /lol to LAUGH", R("lol") == "LAUGH")
hash_EmoteTokenList = nil
EMOTE7_TOKEN, EMOTE7_CMD1, EMOTE7_CMD2 = "LAUGH", "/laugh", "/lol"
check("emote: emote globals map /lol to LAUGH", R("/lol") == "LAUGH")

-- --- spells ----------------------------------------------------------------

fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 8690)
check("spell: name filter matches", p("hearth") == 1)
check("spell: id filter matches", p("hearth8690") == 1)

fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 7928)
check("spell: other spells don't count", p("hearth") == 1 and p("hearth8690") == 1)

fire("UNIT_SPELLCAST_SUCCEEDED", "target", "Cast-guid", 8690)
check("spell: someone else's cast is ignored", p("hearth") == 1)

-- Original MoP's argument order puts the id fifth.
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Hearthstone", "", 12, 8690)
check("spell: legacy argument order still yields the id", p("hearth8690") == 2)

-- Challenging someone to a duel is reported as a cast; it isn't one.
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 7266)
check("spell: a duel challenge isn't a cast", p("duelspell") == 0)

-- --- fishing ---------------------------------------------------------------

fishing, loot = true, { "Raw Longjaw Mud Snapper", "Raw Brilliant Smallfish" }
fire("LOOT_OPENED")
check("fish: a catch counts", p("anyfish") == 1)
check("fish: any item in the catch can match", p("smallfish") == 1)

fire("LOOT_OPENED")
check("fish: the same window reported twice counts once", p("anyfish") == 1)

clock = clock + 20
fishing = false
fire("LOOT_OPENED")
check("fish: ordinary loot isn't a catch", p("anyfish") == 1)

fishing, loot = true, { "Raw Longjaw Mud Snapper" }
fire("LOOT_OPENED")
check("fish: next catch counts", p("anyfish") == 2)
check("fish: catch without the item doesn't", p("smallfish") == 1)

-- --- melee swings ----------------------------------------------------------

local BOAR = "Creature-0-3299-0-7-3098-000136DF22"
local function swing(subevent, src, offHand, destName)
    -- 11 base values, then SWING_DAMAGE's 10: isOffHand is the 21st.
    fire("COMBAT_LOG_EVENT_UNFILTERED", clock, subevent, false, src, "Me", 0, 0,
        BOAR, destName or "Mottled Boar", 0, 0,
        12, 0, 1, 0, 0, 0, false, false, false, offHand)
end

swing("SWING_DAMAGE", PLAYER, false)
check("swing: a main-hand sword hit counts", p("swordhits") == 1)
check("swing: any-weapon deed counts it", p("anyswing") == 1)
check("swing: target filter matches", p("boarsword") == 1)
check("swing: a sword isn't a dagger", p("daggerhits") == 0)
check("swing: a one-handed sword is one-handed", p("sword1h") == 1 and p("sword2h") == 0)

swing("SWING_DAMAGE", PLAYER, true)
check("swing: an off-hand hit uses the off-hand weapon", p("daggerhits") == 1)
check("swing: and not the main hand's", p("swordhits") == 1)

swing("SWING_MISSED", PLAYER, false)
check("swing: a miss deals no damage, so doesn't count", p("anyswing") == 2)

swing("SWING_DAMAGE", RIVAL, false)
check("swing: someone else's swing is ignored", p("anyswing") == 2)

swing("SWING_DAMAGE", PLAYER, false, "Kobold Vermin")
check("swing: target filter rejects other mobs", p("boarsword") == 1 and p("swordhits") == 2)

-- Gear is cached until it changes.
equipped[16] = 1003 -- a two-handed axe
swing("SWING_DAMAGE", PLAYER, false)
check("swing: cached weapon until gear changes", p("swordhits") == 3 and p("axehits") == 0)
fire("PLAYER_EQUIPMENT_CHANGED")
swing("SWING_DAMAGE", PLAYER, false)
check("swing: two-handed axe counts as axe", p("axehits") == 1)
check("swing: and as a two-handed axe, not a one-handed one", p("axe2h") == 1 and p("axe1h") == 0)

equipped[16] = 1004 -- a two-handed sword
fire("PLAYER_EQUIPMENT_CHANGED")
swing("SWING_DAMAGE", PLAYER, false)
check("swing: two-handed sword counts as sword", p("swordhits") == 4)
check("swing: and as two-handed only", p("sword2h") == 1 and p("sword1h") == 3)

equipped[16], equipped[17] = nil, nil
fire("PLAYER_EQUIPMENT_CHANGED")
swing("SWING_DAMAGE", PLAYER, false)
check("swing: no weapon is unarmed", p("fisticuffs") == 1)

-- --- descriptions ----------------------------------------------------------

local D = ns.Kinds.Describe
check("describe: kill", D("kill", { nameContains = "Boar" }) == 'kills: mob name has "Boar"')
check("describe: unfiltered", D("death", {}) == "any deaths")
check("describe: cause", D("death", { cause = "falling" }) == "deaths: falling")
check("describe: emote with target", D("emote", { emote = "HUG", nameContains = "Rabbit" })
    == 'emotes: /hug, target name has "Rabbit"')
check("describe: ids", D("spell", { ids = { 8690, 8691 } }) == "casts: 2 spell IDs")
check("describe: weapon", D("swing", { weapon = "sword" }) == "melee hits: sword")
check("describe: weapon variant", D("swing", { weapon = "sword2h" }) == "melee hits: two-handed sword")
check("describe: titles held", D("hold", { nameContains = "Boar" })
    == 'contested deeds you lead: deed name has "Boar"')
check("describe: unknown kind says so", D("haircut", {}):find("can't count") ~= nil)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
