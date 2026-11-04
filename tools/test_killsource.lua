-- Headless test for Tracking/Sources/KillSource.lua.
-- Run from the addon root:  luajit tools/test_killsource.lua
--
-- This module had no coverage, and it is exactly where a retail-only API
-- (CombatLogGetCurrentEventInfo) left kills silently uncounted on the Forever
-- client. Nothing caught it because /deed test injects synthetic signals and
-- never touches the combat log. These tests drive OnCombatLog directly.

local ns = {}
local messages = {}
function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    messages[#messages + 1] = table.concat(parts, " ")
end

-- WoW globals the module touches. C_Map is deliberately left undefined to
-- prove the zone lookup degrades instead of erroring.
local PLAYER = "Player-4618-00D1568C"
local PET    = "Creature-0-3299-1-7-510-000136DF01"
UnitGUID = function(unit)
    if unit == "player" then return PLAYER end
    if unit == "pet" then return PET end
end
GetZoneText = function() return "Durotar" end
-- WoW's strsplit: splits on a literal delimiter, returns the parts as values.
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

assert(loadfile("Tracking/Signals.lua"))("Laurels", ns)
assert(loadfile("Tracking/Sources/KillSource.lua"))("Laurels", ns)
local KS = ns.KillSource

local reported = {}
KS.engine = { ReportProgress = function(_, signal)
    reported[#reported + 1] = signal
end }

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1; print("  ok   " .. label)
    else fail = fail + 1; print("  FAIL " .. label) end
end

local BOAR = "Creature-0-3299-1-7-3098-000136DF22"

-- --- GUID parsing ---------------------------------------------------------

check("dash GUID yields its npcID", KS.ParseNpcID(BOAR) == 3098)
check("nil GUID is nil", KS.ParseNpcID(nil) == nil)
check("non-string GUID is nil", KS.ParseNpcID(12345) == nil)
check("garbage GUID is nil", KS.ParseNpcID("not-a-guid-at-all") == nil)
-- The legacy hex branch's byte offset is explicitly unverified against a real
-- Forever GUID; this pins current behaviour rather than blessing the offset.
check("legacy hex GUID parses to a number",
    type(KS.ParseNpcID("0xF13000264F000CF1")) == "number")
check("a too-short hex GUID is nil", KS.ParseNpcID("0xF130") == nil)

-- --- combat log via event varargs (pre-Legion clients) --------------------

local function fire(...)
    KS:OnCombatLog("COMBAT_LOG_EVENT_UNFILTERED", ...)
end

fire(1, "PARTY_KILL", false, PLAYER, "Me", 0, 0, BOAR, "Mottled Boar")
check("a killing blow is counted", #reported == 1)
check("the mob name is carried", reported[1].name == "Mottled Boar")
check("the npcID is parsed", reported[1].npcID == 3098)
check("the zone is stamped", reported[1].zone == "Durotar")
check("it is a kill signal", reported[1].kind == "kill")

fire(2, "SPELL_DAMAGE", false, PLAYER, "Me", 0, 0, BOAR, "Mottled Boar")
check("a non-kill subevent is ignored", #reported == 1)

fire(3, "PARTY_KILL", false, "Player-4618-SOMEONEELSE", "Them", 0, 0, BOAR, "Mottled Boar")
check("someone else's killing blow is ignored", #reported == 1)

fire(4, "PARTY_KILL", false, PET, "Pet", 0, 0, BOAR, "Mottled Boar")
check("our pet's killing blow counts", #reported == 2)

-- --- fallback to the retail API when there are no varargs -----------------

CombatLogGetCurrentEventInfo = function()
    return 5, "PARTY_KILL", false, PLAYER, "Me", 0, 0,
        "Creature-0-3299-1-7-4949-000136DF33", "Ornery Kodo"
end
KS:OnCombatLog("COMBAT_LOG_EVENT_UNFILTERED")
check("falls back to CombatLogGetCurrentEventInfo", #reported == 3)
check("the fallback carries the name", reported[3].name == "Ornery Kodo")
check("the fallback parses its npcID", reported[3].npcID == 4949)
CombatLogGetCurrentEventInfo = nil

-- --- neither route available: must complain, not go quiet -----------------

local before = #reported
KS:OnCombatLog("COMBAT_LOG_EVENT_UNFILTERED")
check("nothing is counted when the log is unreadable", #reported == before)
check("and it says so rather than failing silently", #messages == 1)

KS:OnCombatLog("COMBAT_LOG_EVENT_UNFILTERED")
check("but it only says so once", #messages == 1)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
