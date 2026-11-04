local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Signals: helpers every source shares when describing what just happened.
-- Kept apart from any one source so all of them build signals identically --
-- the unit tooltip relies on a kill signal built ahead of time matching the
-- one the kill itself produces.
-- ---------------------------------------------------------------------------

local Signals = {}
ns.Signals = Signals

-- Where the player is standing right now. Both forms are returned because they
-- fail in opposite directions: the name is human-readable and what a deed
-- stores, but is localized; the uiMapID is language-proof but needs a mapping
-- table. Trackers match on either (see Engine's zone criterion).
function Signals.Zone()
    local name = GetZoneText and GetZoneText()
    if name == "" then name = nil end
    local id
    if C_Map and C_Map.GetBestMapForUnit then
        id = C_Map.GetBestMapForUnit("player")
    end
    return name, id
end

-- The NPC id inside a creature GUID, or nil for anything else.
function Signals.NpcID(guid)
    if type(guid) ~= "string" then return nil end
    -- Two GUID formats span the clients Laurels targets:
    --   * WoD+ dash form:  "Creature-0-serverID-instanceID-zoneUID-NPCID-spawnUID"
    --   * pre-WoD hex form: "0x<typebits><entry><spawn>" (e.g. Mists 5.x)
    -- Only npcID-matched deeds need this; name-matched deeds use destName and
    -- are unaffected either way.
    if guid:find("-", 1, true) then
        return tonumber((select(6, strsplit("-", guid))))
    end
    -- Legacy hex GUID: the creature entry sits in bytes 4-6 (hex chars 7-12).
    -- VERIFY this offset against a real Forever GUID before trusting npcID
    -- matches on the legacy client; the layout is client-specific.
    local hex = guid:match("^0[xX](%x+)$")
    if hex and #hex >= 12 then
        return tonumber(hex:sub(7, 12), 16)
    end
    return nil
end

-- A combat-log payload, read portably. Pre-Legion-style clients (both our
-- targets) deliver it as the event's varargs; Legion+ clients deliver nothing
-- there and require CombatLogGetCurrentEventInfo(). Returns nothing when
-- neither path yields one.
function Signals.CombatLog(...)
    if select("#", ...) > 0 then return ... end
    if CombatLogGetCurrentEventInfo then return CombatLogGetCurrentEventInfo() end
end

-- A signal of `kind`, stamped with where it happened.
function Signals.Make(kind, fields)
    fields.kind = kind
    if fields.zone == nil and fields.zoneID == nil then
        fields.zone, fields.zoneID = Signals.Zone()
    end
    fields.amount = fields.amount or 1
    return fields
end
