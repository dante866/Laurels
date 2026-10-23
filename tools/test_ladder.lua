-- Headless test for Rival/Ladder.lua. Run from addon root:  luajit tools/test_ladder.lua
local ns = { db = {} }
local chunk = assert(loadfile("Rival/Ladder.lua"))
chunk("Deedkeeper", ns)
local L = ns.Ladder

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1; print("  ok   " .. label)
    else fail = fail + 1; print("  FAIL " .. label) end
end

-- Record + holder.
check("new claim", L:RecordClaim("kob", "G-A", { name = "Alice", count = 1000, tier = 1, ts = 100 }) == "new")
check("holder is Alice", L:GetHolder("kob").name == "Alice")

-- Older timestamp is stale even if count is higher.
check("stale ignored", L:RecordClaim("kob", "G-A", { name = "Alice", count = 1200, tier = 1, ts = 90 }) == "stale")
check("count unchanged after stale", L:GetHolder("kob").count == 1000)

-- Bob overtakes -> the steal.
check("bob recorded", L:RecordClaim("kob", "G-B", { name = "Bob", count = 1500, tier = 1, ts = 200 }) == "new")
check("holder is now Bob", L:GetHolder("kob").name == "Bob")

-- Tie on count -> earliest ts wins.
L:RecordClaim("tie", "G-X", { name = "X", count = 50, tier = 0, ts = 300 })
L:RecordClaim("tie", "G-Y", { name = "Y", count = 50, tier = 0, ts = 250 })
check("tie resolves to earliest ts (Y)", L:GetHolder("tie").name == "Y")

-- Rate cap rejects implausible remote jump; trusted (local) bypasses it.
L:RecordClaim("rate", "G-C", { name = "Cheat", count = 10, tier = 0, ts = 1000 })
check("implausible remote jump rejected",
    L:RecordClaim("rate", "G-C", { name = "Cheat", count = 1000000, tier = 5, ts = 1001 }) == "rejected")
check("rejected update kept old count", L:GetHolder("rate").count == 10)
check("trusted local bypasses cap",
    L:RecordClaim("rate", "G-C", { name = "Cheat", count = 1000000, tier = 5, ts = 1002 }, { trusted = true }) == "updated")

-- Ranking.
check("Bob ranks #1", (select(1, L:GetRank("kob", "G-B"))) == 1)
check("Alice ranks #2", (select(1, L:GetRank("kob", "G-A"))) == 2)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
