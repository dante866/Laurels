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
chunk("Deedkeeper", ns)
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

-- CreateTracker then DeleteTracker.
local def = Engine:CreateTracker({ name = "Temp", event = "kill",
    match = { nameContains = "Rat" }, tiers = { { count = 5, title = "Ratter" } } })
check("CreateTracker added it", Engine:GetTracker(def.id) ~= nil)
check("new tracker got an id", type(def.id) == "string" and #def.id > 0)
Engine:DeleteTracker(def.id)
check("DeleteTracker removed it", Engine:GetTracker(def.id) == nil)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
