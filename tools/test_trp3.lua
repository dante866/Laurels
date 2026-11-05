-- Headless test for Integrations/TRP3.lua against a fake TRP3.
-- Run from the addon root:  luajit tools/test_trp3.lua
--
-- The fake mirrors what the real one does in the cases that matter
-- (totalRP3/Core/Player.lua): CreateFromGUID asserts on a GUID it can't
-- resolve, and GetRoleplayingName falls back to the game name for a player
-- with no profile.

time = os.time

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1; print("  ok   " .. label)
    else failed = failed + 1; print("  FAIL " .. label) end
end

local ns = { db = {} }
assert(loadfile("Integrations/TRP3.lua"))("Laurels", ns)
local Names = ns.Names

-- Without TRP3 at all.
check("no TRP3: disabled", not Names.Enabled())
check("no TRP3: no RP name", Names.RPName("Player-1-AAAA", "Vessa-Realm") == nil)
check("no TRP3: entry shows its game name",
    Names.ForEntry({ guid = "Player-1-AAAA", sender = "Vessa-Realm", name = "Vessa" }) == "Vessa")

-- A fake TRP3. Profiles by character id; GUIDs it can resolve.
local profiles = {
    ["Vessa-Realm"]       = { FN = "Lady Vessa", LN = "Thornwood" },
    ["Indira Resthaerl"]  = { FN = "Indira" },
    ["Painted-Realm"]     = { FN = "|cffff0000Crimson|r", LN = "Jack" },
}
local guids = { ["Player-1-AAAA"] = "Vessa-Realm" }
local function makePlayer(id)
    local p = {}
    function p:GetFirstName() return profiles[id] and profiles[id].FN end
    function p:GetLastName() return profiles[id] and profiles[id].LN end
    function p:GetRoleplayingName()
        local name = self:GetFirstName() or id:match("^[^-]+")
        if self:GetLastName() then name = name .. " " .. self:GetLastName() end
        return name
    end
    return p
end
AddOn_TotalRP3 = { Player = {
    CreateFromGUID = function(guid)
        assert(guids[guid], "attempted to construct a Player object from an invalid guid")
        return makePlayer(guids[guid])
    end,
    CreateFromCharacterID = function(id)
        assert(type(id) == "string")
        return makePlayer(id)
    end,
} }

check("TRP3 present: enabled", Names.Enabled())
check("found by GUID", Names.RPName("Player-1-AAAA", nil) == "Lady Vessa Thornwood")
check("an unresolvable GUID falls back to the sender",
    Names.RPName("Player-1-ZZZZ", "Indira Resthaerl") == "Indira")
check("a stranger (no profile) has no RP name", Names.RPName(nil, "Nobody-Realm") == nil)
check("so the entry keeps its game name",
    Names.ForEntry({ sender = "Nobody-Realm", name = "Nobody" }) == "Nobody")
check("colour codes are dropped", Names.RPName(nil, "Painted-Realm") == "Crimson Jack")
check("a non-player GUID isn't looked up",
    Names.RPName("Creature-0-1-1-1-448-1", "Vessa-Realm") == "Lady Vessa Thornwood")
check("a deed's author by its sender",
    Names.ForDeed({ author = "Vessa-Realm", origin = "Vessa-Realm" }) == "Lady Vessa Thornwood")

-- A TRP3 that errors anywhere degrades to the game name, never an error.
local real = AddOn_TotalRP3.Player.CreateFromCharacterID
AddOn_TotalRP3.Player.CreateFromCharacterID = function() error("TRP3 not ready") end
check("a failing TRP3 falls back quietly",
    Names.ForEntry({ guid = "Player-1-ZZZZ", sender = "Vessa-Realm", name = "Vessa" }) == "Vessa")
AddOn_TotalRP3.Player.CreateFromCharacterID = real

-- /deed rpnames.
check("toggle turns it off", Names.Toggle() == false and not Names.Enabled())
check("off shows game names",
    Names.ForEntry({ guid = "Player-1-AAAA", name = "Vessa" }) == "Vessa")
check("toggle turns it back on", Names.Toggle() == true and Names.Enabled())

-- The ladder keeps the sender a claim arrived with, which the lookup needs.
local lns = { db = {} }
assert(loadfile("Rival/Ladder.lua"))("Laurels", lns)
lns.Ladder:RecordClaim("k", "Player-1-BBBB", { name = "Vessa", sender = "Vessa-Realm",
    count = 5, tier = 1, ts = 1 })
check("standings carry the sender", lns.Ladder:GetStandings("k")[1].sender == "Vessa-Realm")
check("and so does the holder", lns.Ladder:GetHolder("k").sender == "Vessa-Realm")

-- --- titles on TRP3's character tooltip --------------------------------------

ns.db.ladder = {}
assert(loadfile("Rival/Ladder.lua"))("Laurels", ns)
assert(loadfile("UI/UnitTooltip.lua"))("Laurels", ns)
ns.Rival = { KeyFor = function(_, t) return t.uuid end }
ns.Comm = { Escape = function(s) return (s:gsub("|", "||")) end }
local function tiered(uuid, name, published)
    return { uuid = uuid, name = name, event = "kill", published = published,
        tiers = { { count = 10, title = name .. " I" }, { count = 20, title = name .. " II" } } }
end
ns.db.trackers = {
    tiered("boar", "Boar", true), tiered("wolf", "Wolf", true),
    tiered("bear", "Bear", true), tiered("private", "Private", false),
    { uuid = "hoard", name = "Hoard", event = "hold", published = true,
      tiers = { { count = 1, title = "Hoarder" } } },
}
local VESSA = "Player-1-AAAA"
local function claim(key, guid, sender, count)
    ns.Ladder:RecordClaim(key, guid, { name = "x", sender = sender, count = count, ts = 1 })
end
claim("boar", VESSA, "Vessa-Realm", 25); claim("boar", "Player-1-ME", nil, 3)
claim("wolf", VESSA, "Vessa-Realm", 12); claim("wolf", "Player-1-ME", nil, 30)
claim("bear", VESSA, "Vessa-Realm", 4)
claim("private", VESSA, "Vessa-Realm", 99)
claim("hoard", VESSA, "Vessa-Realm", 5)

local T = ns.TRP3Titles
local function titles(guid, id)
    local out = {}
    for _, e in ipairs(T.HeldBy(guid, id)) do out[#out + 1] = e.name end
    return table.concat(out, ",")
end
check("titles: only deeds they lead, at their tier", titles(VESSA, nil) == "Boar II")
check("titles: found by sender name too", titles(nil, "Vessa-Realm") == "Boar II")
check("titles: a separator doesn't matter", titles(nil, "Vessa Realm") == "Boar II")
check("titles: someone with none", titles("Player-1-NOBODY", "Nobody-Realm") == "")

-- The tooltip itself: a fake TRP3_CharacterTooltip whose Show is hooked.
local lines = {}
local tip = { target = "Vessa-Realm", shows = 0 }
function tip:GetName() return "FakeTRP3Tip" end
function tip:NumLines() return #lines end
function tip:AddLine(text) lines[#lines + 1] = text
    _G["FakeTRP3TipTextLeft" .. #lines] = { GetText = function() return text end } end
function tip:Show() self.shows = self.shows + 1 end
TRP3_CharacterTooltip = tip
hooksecurefunc = function(t, name, hook)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); hook(...); return r end
end
UnitIsPlayer = function() return false end
T:Init()
tip:Show()
check("tooltip: the line is added", lines[1] == "|cffffd100Laurels:|r Boar II")
tip:Show()
check("tooltip: and only once", #lines == 1)
lines = {}; tip.target = "Nobody-Realm"; tip:Show()
check("tooltip: no line for a player with no titles", #lines == 0)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
