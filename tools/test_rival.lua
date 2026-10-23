-- Integration test for M3: two full clients (Engine+Ladder+Comm+Rival) wired
-- over a loopback bus. Proves auto-broadcast, the steal, announcements, the
-- rate cap, and HELLO convergence end-to-end. Run:  luajit tools/test_rival.lua
time = os.time

local KEY = "DEED-KOBOLD"

-- A single monotonic clock shared by all clients (stands in for server time).
local clock = 0
local function now() clock = clock + 1; return clock end

local function makeClient(name)
    local c = { name = name, messages = {} }
    local ns = { db = { trackers = {} }, charDB = { progress = {}, earned = {} }, version = "test" }
    function ns:Print(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        table.insert(c.messages, table.concat(p, " "))
    end
    for _, f in ipairs({ "Tracking/Engine.lua", "Rival/Ladder.lua", "Rival/Comm.lua", "Rival/Rival.lua" }) do
        assert(loadfile(f))("Deedkeeper", ns)
    end
    -- Everyone contests the SAME published deed (shared uuid = as if adopted).
    ns.db.trackers[1] = {
        id = "kob", name = "Kobold Slaying", event = "kill",
        match = { nameContains = "Kobold" }, published = true, uuid = KEY,
        tiers = { { count = 1000, title = "Kobold Slayer" },
                  { count = 10000, title = "Kobold Destroyer" } },
    }
    ns.Engine:Init()
    ns.Rival._name = name
    ns.Rival._nowFn = now
    ns.Rival:WireHandlers()
    c.ns = ns
    return c
end

-- Connect clients: a YELL send from one is delivered to every other.
local function connect(clients)
    for _, c in ipairs(clients) do
        c.ns.Comm:SetTransport({
            Send = function(_, _, body, channel)
                for _, other in ipairs(clients) do
                    if other ~= c then other.ns.Comm:HandleRaw(body, c.name, channel) end
                end
            end,
        })
    end
end

local function farm(c, mob, n)
    for _ = 1, n do c.ns.Engine:ReportProgress({ kind = "kill", name = mob }) end
end

local function has(c, sub)
    for _, m in ipairs(c.messages) do if m:find(sub, 1, true) then return true end end
    return false
end

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1; print("  ok   " .. label)
    else fail = fail + 1; print("  FAIL " .. label) end
end

local A = makeClient("Alice")
local B = makeClient("Bob")
connect({ A, B })

-- 1. Alice earns the title; her claim auto-broadcasts to Bob at the tier flip.
farm(A, "Kobold", 1000)
check("Alice holds it on her client", A.ns.Ladder:GetHolder(KEY).name == "Alice")
check("claim auto-reached Bob", B.ns.Ladder:GetHolder(KEY) and B.ns.Ladder:GetHolder(KEY).name == "Alice")
check("Bob heard Alice's count", B.ns.Ladder:GetHolder(KEY).count == 1000)

-- 2. Bob out-farms her and steals it.
farm(B, "Kobold", 1500)
B.ns.Rival:ForceBroadcast(B.ns.db.trackers[1]) -- settle the final count
check("Bob holds it on his client", B.ns.Ladder:GetHolder(KEY).name == "Bob")
check("steal propagated to Alice", A.ns.Ladder:GetHolder(KEY).name == "Bob")
check("Alice sees Bob's final 1500", A.ns.Ladder:GetHolder(KEY).count == 1500)

-- 3. Announcements fired on both sides.
check("Bob was told he took it", has(B, "You took") and has(B, "Kobold Slayer"))
check("Alice was told she lost it", has(A, "from you"))

-- 4. Rate cap: a forged jump for an already-known rival is rejected.
local before = A.ns.Ladder:GetHolder(KEY).count
A.ns.Comm:HandleRaw(A.ns.Comm:Encode(
    { type = "CLAIM", deedKey = KEY, count = 100000000, tier = 2, name = "Bob", ts = now() }), "Bob", "YELL")
check("forged jump for known rival rejected", A.ns.Ladder:GetHolder(KEY).count == before)

-- 5. HELLO convergence: a late joiner learns the current standings.
local C = makeClient("Cara")
connect({ A, B, C })
C.ns.Comm:Send({ type = "HELLO", ver = "test", name = "Cara" }, "YELL")
check("newcomer learned the holder via HELLO",
    C.ns.Ladder:GetHolder(KEY) and C.ns.Ladder:GetHolder(KEY).name == "Bob")

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
