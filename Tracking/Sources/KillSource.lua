local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- KillSource: watches the combat log and emits a "kill" signal whenever the
-- player (or their pet) lands a killing blow.
--
-- NOTE: this counts *killing blows*, which is simple and reliable but will
-- undercount tag/DoT/group kills where someone else gets the final hit. Good
-- enough for v1; a future version can add a UNIT_DIED + "did I damage it"
-- heuristic for fuller credit.
-- ---------------------------------------------------------------------------

local KillSource = {}
ns.KillSource = KillSource

-- Where the player is standing right now. Both forms are returned because they
-- fail in opposite directions: the name is human-readable and what a deed
-- stores, but is localized; the uiMapID is language-proof but needs a mapping
-- table. Trackers match on either (see Engine's zone criterion).
local function getZone()
    local name = GetZoneText and GetZoneText()
    if name == "" then name = nil end
    local id
    if C_Map and C_Map.GetBestMapForUnit then
        id = C_Map.GetBestMapForUnit("player")
    end
    return name, id
end

local function getNpcID(guid)
    if type(guid) ~= "string" then return nil end
    -- Two GUID formats span the clients Deedkeeper targets:
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

function KillSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function(_, event, ...)
        self:OnCombatLog(event, ...)
    end)
end

function KillSource:OnCombatLog(event, ...)
    -- Read the combat-log payload portably. Pre-Legion clients (our interface
    -- 16001 / Mists targets) deliver it as the event's varargs; Legion+ clients
    -- deliver nothing here and require CombatLogGetCurrentEventInfo(). Prefer the
    -- varargs when present so this works without that retail-only global.
    local subevent, sourceGUID, destGUID, destName
    if select("#", ...) > 0 then
        local _hideCaster, _sourceName, _sourceFlags, _sourceRaidFlags, _destFlags
        local _timestamp
        _timestamp, subevent, _hideCaster, sourceGUID, _sourceName, _sourceFlags,
            _sourceRaidFlags, destGUID, destName = ...
    elseif CombatLogGetCurrentEventInfo then
        local _
        _, subevent, _, sourceGUID, _, _, _, destGUID, destName =
            CombatLogGetCurrentEventInfo()
    else
        return
    end

    if subevent ~= "PARTY_KILL" then return end

    local playerGUID = UnitGUID("player")
    local petGUID = UnitGUID("pet")
    if sourceGUID ~= playerGUID and sourceGUID ~= petGUID then return end

    local zone, zoneID = getZone()
    self.engine:ReportProgress({
        kind   = "kill",
        name   = destName,
        npcID  = getNpcID(destGUID),
        zone   = zone,
        zoneID = zoneID,
        amount = 1,
    })
end
