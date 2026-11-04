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

-- Exposed so the GUID parsing can be tested headlessly. The parser lives in
-- Signals now (deaths and emotes need it too); this alias keeps the tests'
-- entry point.
KillSource.ParseNpcID = ns.Signals.NpcID

-- The signal killing this mob here would produce. Shared by the real kill and
-- the unit tooltip, so both describe a mob identically.
function KillSource.SignalFor(name, guid)
    return ns.Signals.Make("kill", { name = name, npcID = ns.Signals.NpcID(guid) })
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
        -- Neither path yields a payload. Say so, once: a combat log we cannot
        -- read means NOTHING is ever counted, and it was precisely that
        -- silence which hid this bug -- /deed test injects synthetic signals
        -- and bypasses the combat log, so everything looked fine.
        if not self._warnedNoCombatLog then
            self._warnedNoCombatLog = true
            if ns.Print then
                ns:Print("|cffff8800Can't read the combat log on this client.|r "
                    .. "Kills will not count. Please report this.")
            end
        end
        return
    end

    if subevent ~= "PARTY_KILL" then return end

    local playerGUID = UnitGUID("player")
    local petGUID = UnitGUID("pet")
    if sourceGUID ~= playerGUID and sourceGUID ~= petGUID then return end

    self.engine:ReportProgress(KillSource.SignalFor(destName, destGUID))
end
