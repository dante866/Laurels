local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- KillSource: emits a "kill" signal whenever the player (or their pet) lands
-- a killing blow -- from the combat log, or from PARTY_KILL on clients that
-- close the combat log to addons (Forever).
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

-- Factions by the combat log's English race names, which don't change with
-- the client's language. Pandaren pick a side at level 10 and their race
-- doesn't say which, so they carry no faction (class filters still work).
local FACTION = {
    Human = "alliance", Dwarf = "alliance", NightElf = "alliance",
    Gnome = "alliance", Draenei = "alliance", Worgen = "alliance",
    Orc = "horde", Scourge = "horde", Tauren = "horde", Troll = "horde",
    BloodElf = "horde", Goblin = "horde",
}

-- A killing blow on another player: the player-kill deed's signal, with the
-- victim's class and faction. Nil for anything that isn't a player, or a
-- player the client can't describe (GetPlayerInfoByGUID has nothing on them).
function KillSource.PvpSignalFor(name, guid)
    if type(guid) ~= "string" or not guid:find("^Player") or not GetPlayerInfoByGUID then
        return nil
    end
    local ok, _, englishClass, _, englishRace = pcall(GetPlayerInfoByGUID, guid)
    if not ok then return nil end
    return ns.Signals.Make("pvp", {
        name    = name,
        class   = englishClass and string.lower(englishClass):gsub("_", "") or nil,
        faction = englishRace and FACTION[englishRace] or nil,
    })
end

function KillSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    if ns.combatLogClosed then
        -- No combat log here; PARTY_KILL carries the same killing blow.
        f:RegisterEvent("PARTY_KILL")
        f:SetScript("OnEvent", function(_, _, attackerGUID, targetGUID)
            self:OnPartyKill(attackerGUID, targetGUID)
        end)
    else
        f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        f:SetScript("OnEvent", function(_, event, ...)
            self:OnCombatLog(event, ...)
        end)
    end
end

-- PARTY_KILL fires for anyone in the group; only our own (or our pet's)
-- killing blows count. The event gives GUIDs only, so the name comes from the
-- client, which still knows a unit it just saw die.
function KillSource:OnPartyKill(attackerGUID, targetGUID)
    local R = ns.Signals.Readable
    attackerGUID, targetGUID = R(attackerGUID), R(targetGUID)
    if not targetGUID then return end
    self:OnKillingBlow(attackerGUID, targetGUID, ns.Signals.NameFromGUID(targetGUID))
end

function KillSource:OnKillingBlow(sourceGUID, destGUID, destName)
    local playerGUID = UnitGUID("player")
    local petGUID = UnitGUID("pet")
    if sourceGUID ~= playerGUID and sourceGUID ~= petGUID then return end

    self.engine:ReportProgress(KillSource.SignalFor(destName, destGUID))
    -- A player victim is also a player kill. Kill deeds still see it too,
    -- as they always have; only a name filter would ever match a player.
    local pvp = KillSource.PvpSignalFor(destName, destGUID)
    if pvp then self.engine:ReportProgress(pvp) end
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
    self:OnKillingBlow(sourceGUID, destGUID, destName)
end
