-- Integration test for M3: two full clients (Engine+Ladder+Comm+Rival) wired
-- over a loopback bus. Proves auto-broadcast, the steal, announcements, the
-- rate cap, and HELLO convergence end-to-end. Run:  luajit tools/test_rival.lua
time = os.time

local KEY = "DEED-KOBOLD"

-- A single monotonic clock shared by all clients (stands in for server time).
local clock = 0
local function now() clock = clock + 1; return clock end

-- GUIDs look like the real thing (Player-<realmID>-<hex>) so the tests
-- exercise the same shape the client produces.
local function guidFor(name)
    return "Player-4618-" .. name
end

local function makeClient(name, guid)
    local c = { name = name, guid = guid or guidFor(name), messages = {} }
    local ns = { db = { trackers = {} }, charDB = { progress = {}, earned = {} }, version = "test" }
    function ns:Print(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        table.insert(c.messages, table.concat(p, " "))
    end
    for _, f in ipairs({ "Tracking/Kinds.lua", "Tracking/Engine.lua", "Rival/Ladder.lua", "Rival/Comm.lua", "Rival/Rival.lua" }) do
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
    ns.Rival._guid = c.guid
    ns.Rival._nowFn = now
    ns.Comm.myGuid = c.guid -- so the self-echo guard has something to compare
    ns.Rival:WireHandlers()
    c.ns = ns
    return c
end

-- Connect clients over a shared bus. Two details make this match the real
-- client rather than a convenient fiction:
--   * delivery goes to EVERY client including the sender, as a shared
--     channel does, so the self-echo path is actually exercised;
--   * the sender string deliberately differs from the name a client knows
--     itself by, because CHAT_MSG_ADDON hands back the full "Indira
--     Resthaerl" while UnitName("player") returns only "Indira". Keying on
--     anything derived from these strings is what broke before.
local function senderFor(c) return c.name .. " Resthaerl" end

local function connect(clients)
    for _, c in ipairs(clients) do
        c.ns.Comm:SetTransport({
            Send = function(_, _, body, channel)
                for _, other in ipairs(clients) do
                    other.ns.Comm:HandleRaw(body, senderFor(c), channel)
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
    { type = "CLAIM", deedKey = KEY, count = 100000000, tier = 2, name = "Bob",
      guid = B.guid, ts = now() }), "Bob", "CHANNEL")
check("forged jump for known rival rejected", A.ns.Ladder:GetHolder(KEY).count == before)

-- 5. HELLO convergence: a late joiner learns the current standings.
local C = makeClient("Cara")
connect({ A, B, C })
C.ns.Comm:Send({ type = "HELLO", ver = "test", name = "Cara", guid = C.guid })
check("newcomer learned the holder via HELLO",
    C.ns.Ladder:GetHolder(KEY) and C.ns.Ladder:GetHolder(KEY).name == "Bob")

-- 6. Self-echo. On a shared channel your own broadcast comes straight back
-- with a sender string ("Solo Resthaerl") that does not match the name the
-- client knows itself by ("Solo"). Under the old name keying the echo landed
-- under a second key and you appeared on your own leaderboard twice, as your
-- own rival. Keying on GUID collapses it to the one entry it should be.
local S = makeClient("Solo")
connect({ S })
farm(S, "Kobold", 1000)
check("own echo did not create a second entry", #S.ns.Ladder:GetStandings(KEY) == 1)
check("that entry is keyed by our guid", S.ns.Ladder:GetHolder(KEY).guid == S.guid)

-- 7. Two characters sharing a display name must stay distinct. Under the old
-- name keying they collapsed into one ladder entry and overwrote each other.
local D1 = makeClient("Indira", "Player-4618-00D1568C")
local D2 = makeClient("Indira", "Player-4618-00FFFFFF")
connect({ D1, D2 })
farm(D1, "Kobold", 1000)
farm(D2, "Kobold", 2000)
D2.ns.Rival:ForceBroadcast(D2.ns.db.trackers[1])
check("same-name characters are separate rivals", #D1.ns.Ladder:GetStandings(KEY) == 2)
check("the higher count holds despite identical names",
    D1.ns.Ladder:GetHolder(KEY).count == 2000)

-- 8. Standings carry the tier each rival reached, and that resolves to the
-- title text the ladder display shows alongside the count.
local tracker = A.ns.db.trackers[1]
local board = A.ns.Ladder:GetStandings(KEY)
check("standings expose a tier", board[1].tier ~= nil and board[1].tier > 0)
check("tier resolves to its title",
    A.ns.Rival:TitleFor(tracker, board[1].tier) == "Kobold Slayer")
check("tier 0 has no title yet", A.ns.Rival:TitleFor(tracker, 0) == nil)
check("a tier past the list is nil", A.ns.Rival:TitleFor(tracker, 99) == nil)

-- 9. You hold your own UNPUBLISHED deed. Recording was previously gated on
-- the same flag as broadcasting, so a private deed showed an empty ladder
-- while you stood on a full count -- /deed rivals said "no claims heard yet".
local P = makeClient("Agdamar")
P.ns.db.trackers[1].published = false
P.ns.db.trackers[1].uuid = nil -- unpublished deeds fall back to a derived key
local PKEY = P.ns.Rival:KeyFor(P.ns.db.trackers[1])
farm(P, "Kobold", 1000)
local mine = P.ns.Ladder:GetHolder(PKEY)
check("an unpublished deed still records us", mine ~= nil)
check("with our real count", mine and mine.count == 1000)
check("and our earned tier", mine and mine.tier == 1)
check("and it is us", mine and mine.guid == P.guid)

-- Nothing was broadcast, though: that half stays gated on publishing.
local Q = makeClient("Watcher")
connect({ P, Q })
farm(P, "Kobold", 10)
check("an unpublished deed broadcasts nothing",
    Q.ns.Ladder:GetHolder(PKEY) == nil)

-- 10. M4: a published deed's DEFINITION travels, so a rival discovers it by
-- name and accepts it, instead of being told a uuid out of band.
local Author = makeClient("Author")
local Taker  = makeClient("Taker")
-- The taker starts with no deed at all -- discovery has to supply everything.
Taker.ns.db.trackers = {}
Author.ns.db.trackers[1].published = true
connect({ Author, Taker })

Author.ns.Rival:BroadcastDef(Author.ns.db.trackers[1])
local offers = Taker.ns.Rival:NearbyDeeds()
check("the taker heard one offer", #offers == 1)
check("with the author's deed name", offers[1] and offers[1].name == "Kobold Slaying")
check("and the author's tiers", offers[1] and #offers[1].tiers == 2)
check("and the author's match",
    offers[1] and offers[1].match.nameContains == "Kobold")
check("credited to the author", offers[1] and offers[1].origin ~= nil)

local adopted = Taker.ns.Rival:Adopt(KEY)
check("accepting builds a real tracker", adopted ~= nil)
check("it carries the challenge id", adopted and adopted.uuid == KEY)
check("it copies the author's thresholds",
    adopted and adopted.tiers[1].count == 1000)
check("it is no longer offered", #Taker.ns.Rival:NearbyDeeds() == 0)
check("accepting twice is a no-op",
    select(2, Taker.ns.Rival:Adopt(KEY)) == "already adopted")

-- The author must not be offered their own deed back off the shared channel.
check("the author is not offered their own deed",
    #Author.ns.Rival:NearbyDeeds() == 0)

-- And now the two actually compete, with no uuid ever typed by hand.
farm(Taker, "Kobold", 1200)
check("the taker now holds it on the author's client",
    Author.ns.Ladder:GetHolder(KEY).name == "Taker")

-- An oversized definition sheds tiers rather than failing to send.
local long = { uuid = "u", name = string.rep("N", 60), event = "kill",
    match = { nameContains = string.rep("m", 40) }, tiers = {} }
for i = 1, 5 do
    long.tiers[i] = { count = i * 1000, title = string.rep("T", 40) }
end
local body = Author.ns.Comm:EncodeDef({ def = long, guid = "g", ver = "1" })
check("an oversized definition is trimmed to fit", #body <= Author.ns.Comm.MAX_BODY)

-- 11. Simulated rivals drive the whole receive path, so the steal mechanic
-- can be developed and watched without a second player logged in.
local Lone = makeClient("Lone")
farm(Lone, "Kobold", 1000)
check("we hold it to begin with", Lone.ns.Ladder:GetHolder(KEY).name == "Lone")

local tracker1 = Lone.ns.db.trackers[1]
local sim = Lone.ns.Rival:SimulateClaim(tracker1, "Thrall", 1500)
check("the simulated rival lands on the ladder", sim ~= nil and sim.count == 1500)
check("they take the title", Lone.ns.Ladder:GetHolder(KEY).name == "Thrall")
check("and we are told we lost it", has(Lone, "took") and has(Lone, "from you"))
check("their tier was resolved, not guessed", sim.tier == 1)

-- Simulating the same rival again updates them rather than cloning them.
local before = #Lone.ns.Ladder:GetStandings(KEY)
Lone.ns.Rival:SimulateClaim(tracker1, "Thrall", 1600)
check("simulating the same name again updates them",
    #Lone.ns.Ladder:GetStandings(KEY) == before)
check("their count moved", Lone.ns.Ladder:GetHolder(KEY).count == 1600)

-- A big jump is allowed, because the simulated clock advances enough to make
-- it plausible. Without that the rate cap would refuse any gain over
-- MAX_RATE and the tool could never set up a steal worth watching.
local big = Lone.ns.Rival:SimulateClaim(tracker1, "Thrall", 50000)
check("a large jump is allowed by advancing the clock", big and big.count == 50000)

-- The cap itself is untouched: a hand-built claim that jumps instantly is
-- still refused, so simulation has not quietly disarmed the anti-spoofing.
local far = Lone.ns.Ladder:GetStandings(KEY)[1]
Lone.ns.Comm:HandleRaw(Lone.ns.Comm:Encode({
    type = "CLAIM", deedKey = KEY, count = 99999999, tier = 2, name = "Thrall",
    guid = "Player-0-SIMthrall", ts = far.ts + 1 }), "Thrall", "SIMULATED")
check("an instant jump is still refused",
    Lone.ns.Ladder:GetHolder(KEY).count == 50000)

-- And we can take it back by out-farming them.
farm(Lone, "Kobold", 50000)
check("we hold it again", Lone.ns.Ladder:GetHolder(KEY).name == "Lone")
check("and were told we took it", has(Lone, "You took"))

-- 12. Steals announce through one path, so chat and the toast can't drift
-- apart. The toast layer is optional -- no UI is loaded here -- and the
-- announcement must still happen without it.
local Ann = makeClient("Ann")
local seen = {}
Ann.ns.Toast = { Steal = function(_, kind, title, who, count)
    seen[#seen + 1] = { kind = kind, title = title, who = who, count = count }
end }

farm(Ann, "Kobold", 1000)
Ann.ns.Rival:SimulateClaim(Ann.ns.db.trackers[1], "Garrosh", 2000)
check("losing a title toasts", #seen == 1 and seen[1].kind == "lost")
check("the toast names the title", seen[1] and seen[1].title == "Kobold Slayer")
check("and names the rival", seen[1] and seen[1].who == "Garrosh")
check("and carries their count", seen[1] and seen[1].count == 2000)
check("chat said so too", has(Ann, "took") and has(Ann, "from you"))

farm(Ann, "Kobold", 2000) -- 3000, we take it back
check("taking it back toasts", #seen == 2 and seen[2].kind == "took")
check("naming who we took it from", seen[2] and seen[2].who == "Garrosh")

-- Personal-deed keys. A kill deed's must not change now that other kinds
-- add key parts, or its stored ladder entries would be orphaned.
local KeyFor = function(t) return A.ns.Rival:KeyFor(t) end
check("kill key unchanged", KeyFor({ event = "kill",
    match = { nameContains = "Boar", npcIDs = { 3, 1 } } }) == "kill~n=boar~i=1,3")
check("death causes key apart",
    KeyFor({ event = "death", match = { cause = "falling" } })
    ~= KeyFor({ event = "death", match = { cause = "drowning" } }))
check("emotes key apart",
    KeyFor({ event = "emote", match = { emote = "HUG" } })
    ~= KeyFor({ event = "emote", match = { emote = "WAVE" } }))
check("quest ids are in the key",
    KeyFor({ event = "quest", match = { ids = { 62 } } }) == "quest~i=62")

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
