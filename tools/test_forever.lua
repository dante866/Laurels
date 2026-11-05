-- Headless test for the sources' closed-combat-log paths (Forever): kills
-- from PARTY_KILL, swings from PLAYER_SWING, death causes from the recap.
-- Run from the addon root:  luajit tools/test_forever.lua
--
-- On Forever, even registering COMBAT_LOG_EVENT_UNFILTERED raises the game's
-- "blocked from an action" popup, so the first thing checked is that no
-- source asks for it.

time = os.time
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

local PLAYER = "Player-4618-00D1568C"
local BOAR   = "Creature-0-3299-1-7-3098-000136DF22"
local OTHER  = "Player-4618-0BADBEEF"
local target = BOAR
UnitGUID = function(unit)
    if unit == "player" then return PLAYER end
    if unit == "target" then return target end
end
UnitName = function(unit)
    if unit == "player" then return "Indira" end
    if unit == "target" and target == BOAR then return "Bristleback Boar" end
end
UnitNameFromGUID = function(guid)
    if guid == BOAR then return "Bristleback Boar", "" end
end
GetZoneText = function() return "Durotar" end
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

-- A two-handed sword in the main hand, a dagger in the off hand.
GetInventoryItemID = function(_, slot) return ({ [16] = 1001, [17] = 1002 })[slot] end
GetItemInfoInstant = function(id)
    return id, nil, nil, nil, nil, 2, ({ [1001] = 8, [1002] = 15 })[id]
end

-- The death recap, newest killing blow by timestamp, deliberately not first.
local recap = {}
C_DeathRecap = { GetRecapEvents = function() return recap end }

local ns = { combatLogClosed = true }
local pending = {}
function ns.After(_, fn) pending[#pending + 1] = fn end
local function flush() local p = pending; pending = {}; for _, fn in ipairs(p) do fn() end end
function ns:Print() end

for _, f in ipairs({ "Tracking/Signals.lua", "Tracking/Sources/KillSource.lua",
        "Tracking/Sources/SwingSource.lua", "Tracking/Sources/DeathSource.lua" }) do
    assert(loadfile(f))("Laurels", ns)
end

local reported = {}
local engine = { ReportProgress = function(_, s) reported[#reported + 1] = s end }
ns.KillSource:Init(engine)
ns.SwingSource:Init(engine)
ns.DeathSource:Init(engine)

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end
local function last() return reported[#reported] end

-- --- registration ----------------------------------------------------------

local asked = false
for _, f in ipairs(frames) do
    if f.events.COMBAT_LOG_EVENT_UNFILTERED then asked = true end
end
check("no source registers the combat log", not asked)

-- --- kills -----------------------------------------------------------------

fire("PARTY_KILL", PLAYER, BOAR)
check("PARTY_KILL: our killing blow counts", #reported == 1 and last().kind == "kill")
check("PARTY_KILL: the name comes from the GUID", last().name == "Bristleback Boar")
check("PARTY_KILL: the npc id comes from the GUID", last().npcID == 3098)
fire("PARTY_KILL", OTHER, BOAR)
check("PARTY_KILL: a groupmate's kill doesn't", #reported == 1)

-- A secret GUID is unreadable, so it's ignored rather than erroring.
issecretvalue = function(v) return v == "SECRET" end
fire("PARTY_KILL", PLAYER, "SECRET")
check("PARTY_KILL: a secret target is skipped", #reported == 1)
issecretvalue = nil

-- --- swings ----------------------------------------------------------------

reported = {}
fire("PLAYER_SWING", 3.6, 0)
check("PLAYER_SWING: a main-hand swing counts", #reported == 1 and last().kind == "swing")
check("PLAYER_SWING: main hand is the two-hander", last().weapon == "sword2h"
    and last().weaponFamily == "sword")
check("PLAYER_SWING: the target is what you swing at", last().name == "Bristleback Boar")
fire("PLAYER_SWING", 1.8, 1)
check("PLAYER_SWING: an off-hand swing names the off hand", last().weapon == "dagger")
fire("PLAYER_SWING", 2.0, 2)
check("PLAYER_SWING: a ranged auto-shot isn't a swing", #reported == 2)
Enum = { PlayerSwingType = { MainHand = 5, OffHand = 6, Ranged = 7 } }
fire("PLAYER_SWING", 3.6, 5)
check("PLAYER_SWING: Enum values are preferred", last().weapon == "sword2h" and #reported == 3)
Enum = nil

-- --- deaths ----------------------------------------------------------------

reported = {}
recap = {
    { timestamp = 500, event = "SWING_DAMAGE", sourceGUID = OTHER, sourceName = "Bob" },
    { timestamp = 510, event = "SWING_DAMAGE", sourceGUID = BOAR, sourceName = "Bristleback Boar" },
}
fire("PLAYER_DEAD")
check("death: counted only once the recap has landed", #reported == 0)
flush()
check("death: the latest recap entry is the killing blow",
    #reported == 1 and last().cause == "creature" and last().name == "Bristleback Boar")

-- No new recap: the same entries again are the previous death's.
fire("PLAYER_DEAD"); flush()
check("death: a stale recap leaves the cause other", last().cause == "other" and last().name == nil)

recap = { { timestamp = 600, event = "ENVIRONMENTAL_DAMAGE", environmentalType = "Falling" } }
fire("PLAYER_DEAD"); flush()
check("death: environmental damage gives its type", last().cause == "falling")

recap = { { timestamp = 700, event = "SPELL_DAMAGE", sourceGUID = OTHER, sourceName = "Bob" } }
fire("PLAYER_DEAD"); flush()
check("death: a player's spell", last().cause == "player" and last().name == "Bob")

local lines = {}
ns.DeathSource:DumpRecap(function(l) lines[#lines + 1] = l end)
check("recap dump: lists every entry's fields", lines[1]
    and lines[1]:find("1 entries") and lines[2]:find("sourceName=Bob")
    and lines[2]:find("timestamp=700"))

C_DeathRecap = nil
fire("PLAYER_DEAD"); flush()
check("death: no recap API still counts the death", #reported == 5 and last().cause == "other")

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
