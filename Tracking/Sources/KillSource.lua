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
    if not guid then return nil end
    -- Retail GUID: "Creature-0-serverID-instanceID-zoneUID-NPCID-spawnUID"
    local npcID = select(6, strsplit("-", guid))
    return tonumber(npcID)
end

function KillSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function()
        self:OnCombatLog()
    end)
end

function KillSource:OnCombatLog()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName =
        CombatLogGetCurrentEventInfo()

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
