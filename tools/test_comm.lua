-- Headless test for Rival/Comm.lua. Run from addon root:  luajit tools/test_comm.lua
local ns = {}
local chunk = assert(loadfile("Rival/Comm.lua"))
chunk("Deedkeeper", ns)
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

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
