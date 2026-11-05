-- Headless test for Tracking/Engine.lua. Stubs the handful of WoW globals the
-- engine touches, loads it as a chunk, and asserts tier math / matching / delete.
-- Run from the addon root:  luajit tools/test_engine.lua

-- WoW provides these as globals; LuaJIT does not.
time = os.time
tinsert = table.insert

local messages = {}
local ns = {
    db = { trackers = {
        { id = "kobolds", name = "Kobold Slaying", event = "kill",
          match = { nameContains = "Kobold" },
          tiers = { { count = 1000, title = "Kobold Slayer" },
                    { count = 10000, title = "Kobold Destroyer" } } },
        { id = "boss", name = "Specific NPC", event = "kill",
          match = { npcIDs = { 11502 } },
          tiers = { { count = 1, title = "Dragonslayer" } } },
    } },
    charDB = { progress = {}, earned = {} },
}
function ns:Print(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
    table.insert(messages, table.concat(p, " "))
end

local chunk = assert(loadfile("Tracking/Engine.lua"))
chunk("Laurels", ns)
local Engine = ns.Engine
Engine:Init()

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end

-- 999 kobold kills: progress counts, no title yet.
for _ = 1, 999 do Engine:ReportProgress({ kind = "kill", name = "Kobold Vermin" }) end
check("999 kills counted", Engine:GetProgress("kobolds") == 999)
check("no title at 999", Engine:CurrentTitle(ns.db.trackers[1]) == nil)

-- 1000th kill flips the first tier.
Engine:ReportProgress({ kind = "kill", name = "Kobold Geomancer" })
check("1000 kills counted", Engine:GetProgress("kobolds") == 1000)
check("title earned at 1000", Engine:CurrentTitle(ns.db.trackers[1]) == "Kobold Slayer")
check("next tier is Destroyer", Engine:NextTier(ns.db.trackers[1]).title == "Kobold Destroyer")

-- Non-matching name must not touch the kobold tracker.
Engine:ReportProgress({ kind = "kill", name = "Murloc Oracle" })
check("non-match ignored", Engine:GetProgress("kobolds") == 1000)

-- npcID matching: right id counts, wrong id doesn't.
Engine:ReportProgress({ kind = "kill", name = "Onyxia", npcID = 99999 })
check("wrong npcID ignored", Engine:GetProgress("boss") == 0)
Engine:ReportProgress({ kind = "kill", name = "Onyxia", npcID = 11502 })
check("right npcID counted", Engine:GetProgress("boss") == 1)
check("npcID title earned", Engine:CurrentTitle(ns.db.trackers[2]) == "Dragonslayer")

-- Reset clears count + earned tier.
Engine:ResetProgress("kobolds")
check("reset zeroes progress", Engine:GetProgress("kobolds") == 0)
check("reset clears title", Engine:CurrentTitle(ns.db.trackers[1]) == nil)

-- Re-earning after reset should fire the title message again.
local before = #messages
for _ = 1, 1000 do Engine:ReportProgress({ kind = "kill", name = "Kobold" }) end
local reearned = false
for i = before + 1, #messages do
    if messages[i]:find("Kobold Slayer") then reearned = true end
end
check("title re-fires after reset", reearned)

-- Zone criterion: `zone` (a name) and `zoneID` (a uiMapID) assert one thing --
-- where the kill happened -- so either form alone is enough.
Engine:CreateTracker({ id = "zoned", name = "Westfall Devils", event = "kill",
    match = { nameContains = "Dust Devil", zone = "Westfall", zoneID = 52 },
    tiers = { { count = 2, title = "Devil Chaser" } } })
Engine:ReportProgress({ kind = "kill", name = "Dust Devil", zone = "Westfall" })
check("zone name matches", Engine:GetProgress("zoned") == 1)
Engine:ReportProgress({ kind = "kill", name = "Dust Devil", zone = "WESTFALL" })
check("zone match is case-insensitive", Engine:GetProgress("zoned") == 2)
Engine:ReportProgress({ kind = "kill", name = "Dust Devil", zone = "Duskwood" })
check("wrong zone rejected", Engine:GetProgress("zoned") == 2)
Engine:ReportProgress({ kind = "kill", name = "Dust Devil", zoneID = 52 })
check("uiMapID alone matches", Engine:GetProgress("zoned") == 3)
Engine:ReportProgress({ kind = "kill", name = "Dust Devil", zoneID = 47 })
check("wrong uiMapID rejected", Engine:GetProgress("zoned") == 3)
Engine:ReportProgress({ kind = "kill", name = "Dust Devil" })
check("zone-scoped deed ignores a zoneless signal", Engine:GetProgress("zoned") == 3)
Engine:DeleteTracker("zoned")

-- A tracker with no zone criterion must keep ignoring zone data on the signal,
-- so hand-authored deeds from before zone scoping behave exactly as they did.
Engine:ReportProgress({ kind = "kill", name = "Kobold Vermin", zone = "Durotar" })
check("zoneless tracker ignores the signal's zone", Engine:GetProgress("kobolds") == 1001)

-- Generated ids are typed by hand into /deed publish and friends, so they come
-- from the deed's name rather than a timestamp blob.
local boars = Engine:CreateTracker({ name = "Mottled Boars", event = "kill",
    match = { nameContains = "Mottled Boar" },
    tiers = { { count = 10, title = "Boar Botherer" } } })
check("id is a slug of the name", boars.id == "mottledboars")

local boars2 = Engine:CreateTracker({ name = "Mottled Boars!", event = "kill",
    match = { nameContains = "Mottled Boar" },
    tiers = { { count = 10, title = "Boar Botherer" } } })
check("a colliding name gets a suffix", boars2.id == "mottledboars2")

local odd = Engine:CreateTracker({ name = "!!!", event = "kill",
    match = { nameContains = "x" }, tiers = { { count = 1, title = "X" } } })
check("an unslugglable name still yields an id", type(odd.id) == "string" and #odd.id > 0)

local given = Engine:CreateTracker({ id = "keepme", name = "Explicit", event = "kill",
    match = { nameContains = "y" }, tiers = { { count = 1, title = "Y" } } })
check("an explicit id is left alone", given.id == "keepme")

Engine:DeleteTracker(boars.id)
Engine:DeleteTracker(boars2.id)
Engine:DeleteTracker(odd.id)
Engine:DeleteTracker(given.id)

-- Editing a deed keeps its id and progress, and re-resolves the earned tier,
-- which tier edits invalidate in both directions.
local ed = Engine:CreateTracker({ name = "Boar Hunt", event = "kill",
    match = { nameContains = "Boar" },
    tiers = { { count = 100, title = "Boar Hunter" },
              { count = 500, title = "Boar Slayer" } } })
for _ = 1, 120 do Engine:ReportProgress({ kind = "kill", name = "Mottled Boar" }) end
check("edit fixture counted", Engine:GetProgress(ed.id) == 120)
check("first tier earned", ns.charDB.earned[ed.id] == 1)

Engine:UpdateTracker(ed.id, { name = "Boar Hunting" })
check("rename keeps the id", Engine:GetTracker(ed.id) ~= nil)
check("rename applied", Engine:GetTracker(ed.id).name == "Boar Hunting")
check("rename keeps progress", Engine:GetProgress(ed.id) == 120)

-- Lowering a threshold below the current count should grant that title now.
Engine:UpdateTracker(ed.id, { tiers = { { count = 10, title = "Boar Hunter" },
                                        { count = 100, title = "Boar Slayer" } } })
check("earned re-resolves upward", ns.charDB.earned[ed.id] == 2)

-- Deleting tiers must not leave the earned index past the end of the list.
Engine:UpdateTracker(ed.id, { tiers = { { count = 10, title = "Boar Hunter" } } })
check("earned clamps down when tiers go", ns.charDB.earned[ed.id] == 1)
check("edit did not reset progress", Engine:GetProgress(ed.id) == 120)

-- Changing the match changes what counts from here on.
Engine:UpdateTracker(ed.id, { match = { nameContains = "Kodo" } })
Engine:ReportProgress({ kind = "kill", name = "Mottled Boar" })
check("old match no longer counts", Engine:GetProgress(ed.id) == 120)
Engine:ReportProgress({ kind = "kill", name = "Ornery Kodo" })
check("new match counts", Engine:GetProgress(ed.id) == 121)

check("editing an unknown deed is a no-op", Engine:UpdateTracker("nope", {}) == nil)
Engine:DeleteTracker(ed.id)

-- CreateTracker then DeleteTracker.
local def = Engine:CreateTracker({ name = "Temp", event = "kill",
    match = { nameContains = "Rat" }, tiers = { { count = 5, title = "Ratter" } } })
check("CreateTracker added it", Engine:GetTracker(def.id) ~= nil)
check("new tracker got an id", type(def.id) == "string" and #def.id > 0)
Engine:DeleteTracker(def.id)
check("DeleteTracker removed it", Engine:GetTracker(def.id) == nil)

-- TrackersMatching: the question the unit tooltip asks before a kill.
local hit = Engine:TrackersMatching({ kind = "kill", name = "Kobold Miner" })
check("TrackersMatching finds the kobold deed", #hit == 1 and hit[1].id == "kobolds")
check("TrackersMatching finds nothing for a boar",
    #Engine:TrackersMatching({ kind = "kill", name = "Mottled Boar" }) == 0)
check("TrackersMatching matches by npcID",
    #Engine:TrackersMatching({ kind = "kill", name = "Onyxia", npcID = 11502 }) == 1)

local scoped = Engine:CreateTracker({ name = "Elwynn Kobolds", event = "kill",
    match = { nameContains = "Kobold", zone = "Elwynn Forest" },
    tiers = { { count = 5, title = "Local Hero" } } })
check("zone-scoped deed shows in its zone", #Engine:TrackersMatching(
    { kind = "kill", name = "Kobold Miner", zone = "Elwynn Forest" }) == 2)
check("zone-scoped deed hidden elsewhere", #Engine:TrackersMatching(
    { kind = "kill", name = "Kobold Miner", zone = "Westfall" }) == 1)
Engine:DeleteTracker(scoped.id)

-- UnitTooltip.Line: "deed 1, deed 2, +x more".
assert(loadfile("Tracking/Signals.lua"))("Laurels", ns) -- for Readable
assert(loadfile("UI/UnitTooltip.lua"))("Laurels", ns)
local Line = ns.UnitTooltip.Line
local function deeds(n)
    local t = {}
    for i = 1, n do t[i] = { name = "D" .. i } end
    return t
end
check("tooltip line: none is nil", Line(deeds(0)) == nil)
check("tooltip line: one", Line(deeds(1)) == "D1")
check("tooltip line: two", Line(deeds(2)) == "D1, D2")
check("tooltip line: three collapses", Line(deeds(3)) == "D1, D2, +1 more")
check("tooltip line: five collapses", Line(deeds(5)) == "D1, D2, +3 more")

-- UnitTooltip.Attackable: friendly NPCs get no line; unknown means show it.
local Attackable = ns.UnitTooltip.Attackable
check("attackable: no API shows the line", Attackable("mouseover") == true)
UnitCanAttack = function(_, unit) return unit == "hostile" end
check("attackable: a hostile mob", Attackable("hostile") == true)
check("attackable: a friendly NPC", Attackable("friendly") == false)
UnitCanAttack = function() error("no unit") end
check("attackable: an error shows the line", Attackable("mouseover") == true)
UnitCanAttack = function() return "SECRET" end
issecretvalue = function(v) return v == "SECRET" end
check("attackable: a secret answer shows the line", Attackable("mouseover") == true)
UnitCanAttack, issecretvalue = nil, nil

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
