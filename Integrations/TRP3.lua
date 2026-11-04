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
