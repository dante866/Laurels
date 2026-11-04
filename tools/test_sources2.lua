-- Headless test for the second batch of deed types: player kills, duels,
-- loot, flights, loot rolls and boss kills.
-- Run from the addon root:  luajit tools/test_sources2.lua
--
-- As in test_sources.lua, each source is driven by fake WoW events into the
-- real Engine, and the assertions are on deed progress.

time = os.time
tinsert = table.insert

local clock = 100
GetTime = function() return clock end

local frames = {}
function CreateFrame()
    local f = { events = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:SetScript(_, fn) self.handler = fn end
    frames[#frames + 1] = f
    return f
end
local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.handler then f.handler(f, event, ...) end
    end
end
function hooksecurefunc(name, hook)
    local orig = _G[name]
    _G[name] = function(...) local r = { orig(...) }; hook(...); return unpack(r) end
end

local PLAYER = "Player-4618-00D1568C"
UnitGUID = function(unit) if unit == "player" then return PLAYER end end
UnitName = function(unit) if unit == "player" then return "Indira" end end
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

-- Player kills: GetPlayerInfoByGUID describes the victim.
local victims = {
    ["Player-1-ORCMAGE"] = { "Mage", "MAGE", "Orc", "Orc" },
    ["Player-1-HUMANDK"] = { "Death Knight", "DEATHKNIGHT", "Human", "Human" },
    ["Player-1-PANDA"]   = { "Monk", "MONK", "Pandaren", "Pandaren" },
}
GetPlayerInfoByGUID = function(guid)
    local v = victims[guid]
    if v then return v[1], v[2], v[3], v[4], 2, "Victim", "" end
end

-- Flights and rolls.
TakeTaxiNode = function() end
TaxiNodeName = function(slot) return ({ [3] = "Ironforge, Dun Morogh" })[slot] end
RollOnLoot = function() end
local rollLinks = {
    [7] = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r",
    [8] = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r",
    [9] = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r",
    [10] = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r",
}
GetLootRollItemLink = function(id) return rollLinks[id] end

local function deed(id, event, match)
    return { id = id, name = id, event = event, match = match,
             tiers = { { count = 1000, title = "T" } } }
end

local ns = {
    db = { trackers = {
        deed("anypvp",   "pvp",  {}),
        deed("horde",    "pvp",  { target = "horde" }),
        deed("alliance", "pvp",  { target = "alliance" }),
        deed("mages",    "pvp",  { target = "mage" }),
        deed("dks",      "pvp",  { target = "deathknight" }),
        deed("monks",    "pvp",  { target = "monk" }),

        deed("duels",    "duel", {}),
        deed("wins",     "duel", { result = "won" }),
        deed("losses",   "duel", { result = "lost" }),
        deed("bobduels", "duel", { nameContains = "Bob" }),

        deed("linen",    "loot", { nameContains = "Linen" }),
        deed("linen2589","loot", { ids = { 2589 } }),
        deed("greens",   "loot", { quality = "uncommon" }),
        deed("anyloot",  "loot", {}),

        deed("flights",  "flight", {}),
        deed("toIF",     "flight", { nameContains = "Ironforge" }),
        deed("fromElwynn","flight", { zone = "Elwynn Forest" }),

        deed("needs",    "roll", { roll = "need" }),
        deed("greeds",   "roll", { roll = "greed" }),
        deed("passes",   "roll", { roll = "pass" }),
        deed("anyroll",  "roll", {}),

        deed("bosses",   "boss", {}),
        deed("ony",      "boss", { ids = { 1084 } }),
    } },
    charDB = { progress = {}, earned = {} },
}
function ns:Print() end

for _, f in ipairs({ "Tracking/Kinds.lua", "Tracking/Signals.lua", "Tracking/Engine.lua",
        "Tracking/Sources/KillSource.lua", "Tracking/Sources/DuelSource.lua",
        "Tracking/Sources/LootSource.lua", "Tracking/Sources/FlightSource.lua",
        "Tracking/Sources/RollSource.lua", "Tracking/Sources/BossSource.lua" }) do
    assert(loadfile(f))("Laurels", ns)
end
local Engine = ns.Engine
Engine:Init()
for _, k in ipairs({ "Kill", "Duel", "Loot", "Flight", "Roll", "Boss" }) do
    Engine:RegisterSource(string.lower(k), ns[k .. "Source"])
end

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end
local function p(id) return Engine:GetProgress(id) end

-- --- player kills ----------------------------------------------------------

local function killed(guid, name)
    fire("COMBAT_LOG_EVENT_UNFILTERED", clock, "PARTY_KILL", false, PLAYER, "Me",
        0, 0, guid, name, 0, 0)
end
killed("Player-1-ORCMAGE", "Grunt")
check("pvp: a player kill counts", p("anypvp") == 1)
check("pvp: an orc is horde", p("horde") == 1 and p("alliance") == 0)
check("pvp: the class filter matches", p("mages") == 1)
killed("Player-1-HUMANDK", "Arthas")
check("pvp: a human is alliance", p("alliance") == 1)
check("pvp: DEATHKNIGHT becomes deathknight", p("dks") == 1)
killed("Player-1-PANDA", "Chen")
check("pvp: a pandaren has no faction", p("horde") == 1 and p("alliance") == 1)
check("pvp: but the class still counts", p("monks") == 1)
killed("Creature-0-1-1-1-448-1", "Hogger")
check("pvp: an NPC isn't a player kill", p("anypvp") == 3)

-- --- duels -----------------------------------------------------------------

local function system(line) fire("CHAT_MSG_SYSTEM", line) end
system("Indira has defeated Bob in a duel")
check("duel: a knockout win", p("wins") == 1 and p("losses") == 0)
check("duel: opponent name filter", p("bobduels") == 1)
system("Bob has defeated Indira in a duel")
check("duel: a knockout loss", p("losses") == 1)
system("Bob has fled from Indira in a duel")
check("duel: they fled, so we won", p("wins") == 2)
system("Indira has fled from Al in a duel")
check("duel: we fled, so we lost", p("losses") == 2)
check("duel: the opponent filter skips Al", p("bobduels") == 3)
system("Al has defeated Bob in a duel")
check("duel: someone else's duel is ignored", p("duels") == 4)
system("Indira Resthaerl has defeated Bob in a duel")
check("duel: a two-part name is still us", p("wins") == 3)
system("Indira-Stormrage has defeated Bob in a duel")
check("duel: a realm-qualified name is still us", p("wins") == 4)
-- A translation that reorders the arguments.
DUEL_WINNER_KNOCKOUT = "%2$s wurde von %1$s im Duell besiegt"
system("Bob wurde von Indira im Duell besiegt")
check("duel: positional arguments in a translated format", p("wins") == 5)
DUEL_WINNER_KNOCKOUT = nil

-- --- loot ------------------------------------------------------------------

local function loot(line) fire("CHAT_MSG_LOOT", line) end
local LINEN = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
loot("You receive loot: " .. LINEN .. "x5.")
check("loot: a stack counts its size", p("linen") == 5)
check("loot: item id filter", p("linen2589") == 5)
check("loot: quality from the link colour", p("greens") == 5)
loot("You receive loot: |cffffffff|Hitem:117::::::::60:::::|h[Tough Jerky]|h|r.")
check("loot: a single item counts one", p("anyloot") == 6 and p("greens") == 5)
loot("Bob receives loot: " .. LINEN .. ".")
check("loot: someone else's loot is ignored", p("anyloot") == 6)
loot("You receive item: " .. LINEN .. ".")
check("loot: an item handed to you isn't loot", p("anyloot") == 6)

-- --- flights ---------------------------------------------------------------

TakeTaxiNode(3)
zoneName = "Dun Morogh"
fire("PLAYER_CONTROL_LOST")
check("flight: taking off counts", p("flights") == 1)
check("flight: destination filter", p("toIF") == 1)
check("flight: the zone is where you took off", p("fromElwynn") == 1)
fire("PLAYER_CONTROL_LOST")
check("flight: losing control without a flight doesn't", p("flights") == 1)
TakeTaxiNode(3)
clock = clock + 30
fire("PLAYER_CONTROL_LOST")
check("flight: a destination picked long ago doesn't", p("flights") == 1)

-- --- loot rolls ------------------------------------------------------------

RollOnLoot(7, 1)
check("roll: need counts", p("needs") == 1)
RollOnLoot(7, 1)
check("roll: the same roll twice counts once", p("needs") == 1)
RollOnLoot(8, 2)
RollOnLoot(9, 0)
check("roll: greed and pass count", p("greeds") == 1 and p("passes") == 1)
RollOnLoot(10, 3)
check("roll: disenchant isn't counted", p("anyroll") == 3)

-- --- bosses ----------------------------------------------------------------

fire("ENCOUNTER_END", 1084, "Onyxia", 1, 40, 1)
check("boss: a kill counts", p("bosses") == 1 and p("ony") == 1)
fire("BOSS_KILL", 1084, "Onyxia")
check("boss: the same kill through BOSS_KILL counts once", p("bosses") == 1)
fire("ENCOUNTER_END", 1085, "Ragnaros", 1, 40, 0)
check("boss: a wipe doesn't count", p("bosses") == 1)
clock = clock + 60
fire("BOSS_KILL", 1084, "Onyxia")
check("boss: a later kill counts again", p("bosses") == 2)

-- --- descriptions ----------------------------------------------------------

local D = ns.Kinds.Describe
check("describe: pvp", D("pvp", { target = "horde" }) == "player kills: horde")
check("describe: duel", D("duel", { result = "won" }) == "duels: won")
check("describe: loot", D("loot", { quality = "epic" }) == "items looted: epic")
check("describe: roll", D("roll", { roll = "need" }) == "loot rolls: need")

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
