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
local h = Comm:Decode(Comm:Encode({ type = "HELLO", ver = "3.0", name = "Al|ice" }))
check("hello type", h.type == "HELLO")
check("hello escapes pipe in name", h.name == "Al|ice")
check("hello version", h.ver == "3.0")

-- CLAIM round-trip with numeric coercion.
local c = Comm:Decode(Comm:Encode({ type = "CLAIM", deedKey = "kob", count = 1500, tier = 2, name = "Bob", ts = 200 }))
check("claim deedKey", c.deedKey == "kob")
check("claim count is number", c.count == 1500)
check("claim tier is number", c.tier == 2)
check("claim ts is number", c.ts == 200)

-- ASK round-trip.
local a = Comm:Decode(Comm:Encode({ type = "ASK", deedKey = "kob" }))
check("ask deedKey", a.deedKey == "kob")

-- Version gate: a mismatched proto must not dispatch.
local got = 0
Comm:On("CLAIM", function() got = got + 1 end)
Comm:HandleRaw("999|CLAIM|kob|5|0|Bob|1", "Bob", "YELL")
check("wrong proto ignored", got == 0)

-- End-to-end: Send through a loopback transport, then dispatch the captured body.
local captured
Comm:SetTransport({ Send = function(_, _, body) captured = body end })
Comm:Send({ type = "CLAIM", deedKey = "kob", count = 42, tier = 0, name = "Me", ts = 5 }, "YELL")
check("transport received a body", captured ~= nil)

local recvCount, recvSender
Comm:On("CLAIM", function(m) recvCount = m.count; recvSender = m.sender end)
Comm:HandleRaw(captured, "Me", "YELL")
check("dispatched handler saw count 42", recvCount == 42)
check("dispatched handler saw sender", recvSender == "Me")

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
