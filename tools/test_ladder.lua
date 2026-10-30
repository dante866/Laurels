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

-- Our own claims are authoritative and must not be dropped by the timestamp
-- check: the clock has one-second resolution, so several kills inside one
-- second share a ts and all but the first would be discarded as "stale",
-- freezing our ladder entry behind our real progress.
L:RecordClaim("sec", "G-ME", { name = "Me", count = 1, tier = 0, ts = 500 },
    { trusted = true })
check("same-second trusted update is kept",
    L:RecordClaim("sec", "G-ME", { name = "Me", count = 5, tier = 1, ts = 500 },
        { trusted = true }) == "updated")
check("count moved despite the identical ts", L:GetHolder("sec").count == 5)
check("an older ts still counts when trusted",
    L:RecordClaim("sec", "G-ME", { name = "Me", count = 9, tier = 1, ts = 400 },
        { trusted = true }) == "updated")
check("trusted claim with no change is a no-op",
    L:RecordClaim("sec", "G-ME", { name = "Me", count = 9, tier = 1, ts = 900 },
        { trusted = true }) == "stale")
check("the no-op preserved the earlier ts", L:GetHolder("sec").ts == 400)

-- A reset must be able to move our own count back down.
check("trusted claim can lower the count",
    L:RecordClaim("sec", "G-ME", { name = "Me", count = 0, tier = 0, ts = 950 },
        { trusted = true }) == "updated")
check("count went back to zero", L:GetHolder("sec").count == 0)

-- Ranking.
check("Bob ranks #1", (select(1, L:GetRank("kob", "G-B"))) == 1)
check("Alice ranks #2", (select(1, L:GetRank("kob", "G-A"))) == 2)

-- Someone with no claim has no rank, but the total is still reported. The
-- panel relies on this: it must say how many rivals there are rather than
-- inventing a position for a player who isn't on the board.
local rank, total = L:GetRank("kob", "G-NOBODY")
check("an unranked player has no rank", rank == nil)
check("but the total still comes back", total == 2)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
