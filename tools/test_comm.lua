-- Headless test for Rival/Comm.lua. Run from addon root:  luajit tools/test_comm.lua
local ns = {}
local printed = {}
function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, " ")
end
assert(loadfile("Tracking/Kinds.lua"))("Laurels", ns)
local chunk = assert(loadfile("Rival/Comm.lua"))
chunk("Laurels", ns)
local Comm = ns.Comm

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1; print("  ok   " .. label)
    else fail = fail + 1; print("  FAIL " .. label) end
end

-- HELLO round-trip, incl. a '|' in the name to prove escaping survives.
local h = Comm:Decode(Comm:Encode({ type = "HELLO", ver = "3.0", name = "Al|ice",
    guid = "Player-4618-00D1568C" }))
check("hello type", h.type == "HELLO")
check("hello escapes pipe in name", h.name == "Al|ice")
check("hello version", h.ver == "3.0")
check("hello carries guid", h.guid == "Player-4618-00D1568C")

-- CLAIM round-trip with numeric coercion.
local c = Comm:Decode(Comm:Encode({ type = "CLAIM", deedKey = "kob", count = 1500,
    tier = 2, name = "Bob", ts = 200, guid = "Player-4618-00FFFFFF" }))
check("claim deedKey", c.deedKey == "kob")
check("claim count is number", c.count == 1500)
check("claim tier is number", c.tier == 2)
check("claim ts is number", c.ts == 200)
check("claim carries guid", c.guid == "Player-4618-00FFFFFF")

-- A name containing a space must survive intact: this client's characters are
-- "First Last", so a split on whitespace anywhere would corrupt identity.
local sp = Comm:Decode(Comm:Encode({ type = "CLAIM", deedKey = "kob", count = 1,
    tier = 0, name = "Indira Resthaerl", ts = 1, guid = "g1" }))
check("two-part name survives encoding", sp.name == "Indira Resthaerl")

-- An absent guid decodes to nil, not "", so presence tests work.
local noGuid = Comm:Decode(Comm:Encode({ type = "CLAIM", deedKey = "kob",
    count = 1, tier = 0, name = "Bob", ts = 1 }))
check("absent guid decodes to nil", noGuid.guid == nil)

-- ASK round-trip.
local a = Comm:Decode(Comm:Encode({ type = "ASK", deedKey = "kob" }))
check("ask deedKey", a.deedKey == "kob")

-- Version gate: a mismatched proto must not dispatch.
local got = 0
Comm:On("CLAIM", function() got = got + 1 end)
Comm:HandleRaw("999|CLAIM|kob|5|0|Bob|1|g1", "Bob", "CHANNEL")
check("wrong proto ignored", got == 0)

-- Self-echo guard. On a shared channel our own messages come back to us, and
-- they must be dropped by GUID -- the sender string is a display name and
-- does not match what UnitName returns on this client.
local echoed = 0
Comm:On("CLAIM", function() echoed = echoed + 1 end)
Comm.myGuid = "Player-4618-00D1568C"
local mine = Comm:Encode({ type = "CLAIM", deedKey = "kob", count = 5, tier = 0,
    name = "Indira Resthaerl", ts = 1, guid = "Player-4618-00D1568C" })
Comm:HandleRaw(mine, "Indira Resthaerl", "CHANNEL")
check("our own echo is dropped", echoed == 0)

-- ...but a different player's message still gets through.
local theirs = Comm:Encode({ type = "CLAIM", deedKey = "kob", count = 5, tier = 0,
    name = "Indira Resthaerl", ts = 1, guid = "Player-4618-00FFFFFF" })
Comm:HandleRaw(theirs, "Indira Resthaerl", "CHANNEL")
check("a same-named rival still gets through", echoed == 1)
Comm.myGuid = nil

-- End-to-end: Send through a loopback transport, then dispatch the captured body.
local captured, capturedChannel
Comm:SetTransport({ Send = function(_, _, body, channel)
    captured, capturedChannel = body, channel
end })
Comm:Send({ type = "CLAIM", deedKey = "kob", count = 42, tier = 0, name = "Me", ts = 5 })
check("transport received a body", captured ~= nil)
check("defaults to the shared channel", capturedChannel == "CHANNEL")

local recvCount, recvSender
Comm:On("CLAIM", function(m) recvCount = m.count; recvSender = m.sender end)
Comm:HandleRaw(captured, "Me", "CHANNEL")
check("dispatched handler saw count 42", recvCount == 42)
check("dispatched handler saw sender", recvSender == "Me")

-- Broadcast channel precedence: the player's choice wins, then whatever this
-- client's .toc declares, then the built-in default. Garbage in either slot
-- must fall through rather than break the transport.
check("falls back to the default", Comm:BroadcastChannel() == "CHANNEL")
ns.tocChannel = "YELL"
check("a .toc declaration is honoured", Comm:BroadcastChannel() == "YELL")
ns.tocChannel = "yell"
check(".toc value is case-insensitive", Comm:BroadcastChannel() == "YELL")
ns.tocChannel = "NONSENSE"
check("an invalid .toc value falls through", Comm:BroadcastChannel() == "CHANNEL")
ns.tocChannel = "YELL"
ns.db = { commChannel = "GUILD" }
check("the player's choice beats the .toc", Comm:BroadcastChannel() == "GUILD")
ns.db.commChannel = "NOPE"
check("an invalid saved choice falls through", Comm:BroadcastChannel() == "YELL")
ns.db, ns.tocChannel = nil, nil

-- Display escaping. A deed title is free text from an EditBox with no filter,
-- and travels to everyone who accepts the challenge, so a "|" in one would
-- otherwise be eaten by the chat frame as an escape introducer.
check("a pipe is doubled for display", Comm.Escape("Boar|rSlayer") == "Boar||rSlayer")
check("ordinary text is untouched", Comm.Escape("Boar Slayer") == "Boar Slayer")
check("non-strings pass through", Comm.Escape(nil) == nil)

-- Refusal detection. "Don't know" must not read as "fine": treating a nil
-- result as success is exactly how the negotiation went blind under
-- ChatThrottleLib, whose send reports nothing synchronously.
check("0 is success", Comm:IsRefusal(0) == false)
check("4 is a refusal", Comm:IsRefusal(4) == true)
check("nil is not success", Comm:IsRefusal(nil) == false)
check("a numeric string still counts", Comm:IsRefusal("4") == true)

-- Falling back steps through the priority order, never revisits a channel
-- the client already refused, and stops when they are exhausted.
ns.db = {}
Comm._refused = nil
check("CHANNEL falls back to YELL", Comm:FallBackFrom("CHANNEL") == "YELL")
check("the choice is remembered", ns.db.commChannel == "YELL")
check("YELL falls back to GUILD", Comm:FallBackFrom("YELL") == "GUILD")
check("GUILD falls back to SAY", Comm:FallBackFrom("GUILD") == "SAY")
check("then there is nowhere left", Comm:FallBackFrom("SAY") == nil)
check("and it says so", #printed > 0)
ns.db, Comm._refused = nil, nil

-- --- deed kinds beyond kills over DEFPUB ------------------------------------

local function roundTrip(def)
    return Comm:Decode(Comm:Encode({ type = "DEFPUB", guid = "Player-1-AB",
        ver = "t", def = def })).def
end
local tiers = { { count = 5, title = "T" } }

-- The head's layout, pinned: tier total and follow-up count sit between the
-- match fields and the tiers.
local killBody = Comm:Encode({ type = "DEFPUB", guid = "G", ver = "t", def = {
    uuid = "U", name = "Boars", event = "kill",
    match = { nameContains = "Boar", npcIDs = { 3098 } }, tiers = tiers } })
check("DEFPUB head layout",
    killBody == Comm.PROTO .. "|DEFPUB|U|G|t|Boars|kill|Boar|3098|||1|0|5|T")
local k = roundTrip({ uuid = "U", name = "Boars", event = "kill",
    match = { npcIDs = { 3098 } }, tiers = tiers })
check("kill ids decode to npcIDs", k.match.npcIDs and k.match.npcIDs[1] == 3098
    and k.match.ids == nil)

local d = roundTrip({ uuid = "U", name = "Splat", event = "death",
    match = { cause = "falling", zone = "Thousand Needles" }, tiers = tiers })
check("death kind survives", d.event == "death")
check("death cause survives", d.match.cause == "falling")
check("death zone survives", d.match.zone == "Thousand Needles")

local e = roundTrip({ uuid = "U", name = "Hugs", event = "emote",
    match = { emote = "HUG", nameContains = "Rabbit" }, tiers = tiers })
check("emote kind and token survive", e.event == "emote" and e.match.emote == "HUG")
check("emote target filter survives", e.match.nameContains == "Rabbit")

local s = roundTrip({ uuid = "U", name = "Sword Master", event = "swing",
    match = { weapon = "sword" }, tiers = tiers })
check("swing weapon survives", s.event == "swing" and s.match.weapon == "sword")
for _, c in ipairs({ { "pvp", "target", "horde" }, { "duel", "result", "won" },
        { "loot", "quality", "epic" }, { "roll", "roll", "need" } }) do
    local back = roundTrip({ uuid = "U", name = "N", event = c[1],
        match = { [c[2]] = c[3] }, tiers = tiers })
    check(c[1] .. " " .. c[2] .. " survives", back.event == c[1] and back.match[c[2]] == c[3])
end

local q = roundTrip({ uuid = "U", name = "Mines", event = "quest",
    match = { ids = { 62, 76 } }, tiers = tiers })
check("quest ids decode to ids, not npcIDs",
    q.match.ids and q.match.ids[2] == 76 and q.match.npcIDs == nil)

local plain = roundTrip({ uuid = "U", name = "Dead", event = "death",
    match = {}, tiers = tiers })
check("an any-cause death has no cause", plain.event == "death" and plain.match.cause == nil)

local unknown = Comm:Decode(Comm.PROTO .. "|DEFPUB|U|G|t|X|haircut:bald||||||5|T")
check("an unknown kind decodes without its qualifier",
    unknown.def.event == "haircut" and next(unknown.def.match) == nil)

-- --- long deeds split into a head and follow-ups ----------------------------

local function longMsg(n, titleLen)
    local list = {}
    for i = 1, n do
        list[i] = { count = i * 1000, title = string.rep("T", titleLen - 2) .. string.format("%02d", i) }
    end
    return { type = "DEFPUB", guid = "Player-4618-00D1568C", ver = "0.2.0",
        def = { uuid = "D-6727a6c0-abcdef", name = "Boar Annoyer", event = "kill",
                match = { nameContains = "Boar" }, tiers = list } }
end

local bodies = Comm:EncodeDefParts(longMsg(20, 16))
check("a 20-tier deed needs more than one message", #bodies > 1)
local allFit = true
for _, b in ipairs(bodies) do if #b > Comm.MAX_BODY then allFit = false end end
check("and every message fits", allFit)

local head = Comm:Decode(bodies[1])
check("the head says how many tiers there are", head.def.tierTotal == 20)
check("and how many follow-ups are coming", head.def.partCount == #bodies - 1)

-- Reassemble: every tier exactly once, each at its own position.
local got = {}
for i, t in pairs(head.def.tiers) do got[i] = t end
for p = 2, #bodies do
    local part = Comm:Decode(bodies[p])
    check(("follow-up %d decodes as DEFTIERS"):format(p - 1),
        part.type == "DEFTIERS" and part.uuid == "D-6727a6c0-abcdef" and part.part == p - 1)
    for i, t in pairs(part.tiers) do
        check(("tier %d isn't sent twice"):format(i), got[i] == nil)
        got[i] = t
    end
end
local intact = true
for i = 1, 20 do
    if not (got[i] and got[i].count == i * 1000 and got[i].title:sub(-2) == string.format("%02d", i)) then
        intact = false
    end
end
check("all 20 tiers reassemble in order", intact)

-- Titles at the form's 48-character cap still split cleanly.
local capped = Comm:EncodeDefParts(longMsg(20, 48))
local cappedFit = true
for _, b in ipairs(capped) do if #b > Comm.MAX_BODY then cappedFit = false end end
check("48-character titles still fit, one or more per message", cappedFit)

check("a short deed is a single message",
    #Comm:EncodeDefParts({ guid = "G", ver = "t", def = { uuid = "U", name = "N",
        event = "kill", match = {}, tiers = tiers } }) == 1)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
