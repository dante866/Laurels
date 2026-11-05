local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Integrations/TRP3: show players by their Total RP 3 name.
--
-- Ladders, steal pop-ups and deed authors show a rival's RP name ("Lady
-- Vessa Thornwood") when TRP3 knows their profile, and their game name when
-- it doesn't. Inert without TRP3. /deed rpnames turns it off.
--
-- Uses TRP3's public Player API only, read from its source (Core/Player.lua):
--   AddOn_TotalRP3.Player.CreateFromGUID(guid)
--   AddOn_TotalRP3.Player.CreateFromCharacterID(characterID)
--   player:GetFirstName(), player:GetLastName(), player:GetRoleplayingName()
-- A player is looked up by GUID first, then by the sender name the server
-- put on their message. The GUID route needs the client to have seen the
-- player recently (TRP3 resolves it through GetPlayerInfoByGUID); the sender
-- name is already TRP3's character-ID form on both clients -- "Name-Realm" on
-- MoP Classic, the two-part regional name on Forever -- so TRP3's own name
-- rules apply and this file needs none.
-- ---------------------------------------------------------------------------

local Names = {}
ns.Names = Names

function Names.Enabled()
    if ns.db and ns.db.rpNames == false then return false end
    local P = AddOn_TotalRP3 and AddOn_TotalRP3.Player
    return P and P.CreateFromGUID and P.CreateFromCharacterID and true or false
end

-- TRP3 lets players colour their names; drop colour codes so a name reads as
-- text. Escaping for display still happens at the call site.
local function plain(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The RP name for a player, or nil when TRP3 has no profile for them (or
-- isn't there). TRP3 asserts on ids it can't resolve, hence the pcalls.
function Names.RPName(guid, sender)
    if not Names.Enabled() then return nil end
    local P = AddOn_TotalRP3.Player
    local player
    if type(guid) == "string" and guid:find("^Player") then
        local ok, p = pcall(P.CreateFromGUID, guid)
        if ok then player = p end
    end
    if not player and type(sender) == "string" and sender ~= "" then
        local ok, p = pcall(P.CreateFromCharacterID, sender)
        if ok then player = p end
    end
    if not player then return nil end

    -- GetRoleplayingName falls back to the game name for a stranger; only an
    -- actual first or last name means TRP3 knows who this is.
    local ok, first, last = pcall(function() return player:GetFirstName(), player:GetLastName() end)
    if not ok or not ((first and first ~= "") or (last and last ~= "")) then return nil end
    local okName, name = pcall(player.GetRoleplayingName, player)
    if not okName or type(name) ~= "string" or name == "" then return nil end
    name = plain(name)
    return name ~= "" and name or nil
end

-- A ladder entry ({ guid, sender, name }).
function Names.ForEntry(e)
    if not e then return nil end
    return Names.RPName(e.guid, e.sender) or e.name
end

-- A heard deed's author.
function Names.ForDeed(d)
    if not d then return nil end
    return Names.RPName(d.authorGuid, d.author) or d.origin
end

-- /deed rpnames. Returns the new state.
function Names.Toggle()
    ns.db.rpNames = (ns.db.rpNames == false)
    return ns.db.rpNames
end

-- ---------------------------------------------------------------------------
-- Titles on TRP3's character tooltip.
--
--   Lady Vessa Thornwood
--   < Lady of the Thorn >
--   ...
--   Laurels: Boar Smasher, Night Stalker, +1 more
--
-- Lists the titles a player holds (leads the ladder for) in deeds you've
-- accepted too. That's all Laurels knows of anyone else: ladders exist only
-- for deeds both of you play, so a title from a deed you haven't accepted
-- can't show.
--
-- TRP3 has no extension point for this tooltip. Read from its source
-- (Modules/Register/Main/RegisterTooltip.lua): it draws into its own frame,
-- TRP3_CharacterTooltip, keeps the character id it's showing in `.target`,
-- and ends every build with :Show(). So Show is post-hooked and the line
-- added there. If TRP3 renames any of that, the line just doesn't appear.
-- ---------------------------------------------------------------------------

local Titles = {}
ns.TRP3Titles = Titles

-- Names compared without separators: Forever's two-part names come as
-- "Name Realm" in some places and "Name-Realm" in others.
local function bare(s) return (tostring(s):gsub("[%s%-]", "")) end

-- A deed's title at a count: the highest tier reached.
local function titleAt(tracker, count)
    local title
    for _, tier in ipairs(tracker.tiers or {}) do
        if (tonumber(count) or 0) >= (tier.count or math.huge) then title = tier.title end
    end
    return title
end

-- The titles this player holds, as tracker-shaped { name = title } entries
-- (what UnitTooltip.Line takes). Matched by GUID, or by the sender name the
-- server put on their claims, which is TRP3's character id give or take a
-- separator.
function Titles.HeldBy(guid, characterID)
    local held = {}
    if not (ns.db and ns.Rival and ns.Ladder) then return held end
    for _, t in ipairs(ns.db.trackers or {}) do
        if t.published and t.event ~= "hold" then
            local h = ns.Ladder:GetHolder(ns.Rival:KeyFor(t))
            local isThem = h and ((guid and h.guid == guid)
                or (characterID and h.sender and bare(h.sender) == bare(characterID)))
            local title = isThem and titleAt(t, h.count)
            if title then held[#held + 1] = { name = title } end
        end
    end
    return held
end

local PREFIX = "|cffffd100Laurels:|r "

local function alreadyAdded(tooltip)
    local name = tooltip.GetName and tooltip:GetName()
    if not name or not tooltip.NumLines then return false end
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and string.sub(text, 1, #PREFIX) == PREFIX then return true end
    end
    return false
end

-- The GUID of the player the tooltip is for, when a unit token still says so.
local function tooltipGuid(characterID)
    local R = ns.Signals and ns.Signals.Readable or function(v) return v end
    for _, unit in ipairs({ "mouseover", "target" }) do
        local ok, isPlayer = pcall(UnitIsPlayer, unit)
        if ok and R(isPlayer) then
            local guid = R(UnitGUID(unit))
            local okID, id = pcall(function()
                local n, realm = UnitNameUnmodified(unit)
                return realm and realm ~= "" and (n .. "-" .. realm) or n
            end)
            -- Only trust the unit if it's the one TRP3 is describing.
            id = okID and R(id)
            if guid and id and bare(id) == bare(characterID) then
                return guid
            end
        end
    end
end

function Titles.AddLine(tooltip)
    if Titles.adding or alreadyAdded(tooltip) then return end
    local id = tooltip.target
    if type(id) ~= "string" then return end
    local ok, guid = pcall(tooltipGuid, id)
    local text = ns.UnitTooltip and ns.UnitTooltip.Line(Titles.HeldBy(ok and guid or nil, id))
    if not text then return end
    Titles.adding = true -- our own Show() below lands back in this hook
    tooltip:AddLine(PREFIX .. ns.Comm.Escape(text), 1, 1, 1, true)
    tooltip:Show()
    Titles.adding = false
end

function Titles:Init()
    if self.hooked or not (hooksecurefunc and TRP3_CharacterTooltip) then return end
    self.hooked = true
    hooksecurefunc(TRP3_CharacterTooltip, "Show", function(tooltip)
        local ok = pcall(Titles.AddLine, tooltip)
        if not ok then Titles.adding = false end
    end)
end
