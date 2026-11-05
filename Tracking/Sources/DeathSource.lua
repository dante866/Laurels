local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- DeathSource: emits a "death" signal when the player dies, saying what did
-- it.
--
-- PLAYER_DEAD says only that you died. The cause comes from the combat log:
-- the last damage you took is remembered, and if it landed within RECENT
-- seconds of the death it is taken as the killing blow --
--   * environmental damage gives its type (falling, drowning, lava, ...)
--   * otherwise the source was a player or a creature, and its name and NPC
--     id let a deed say "died to Hogger"
-- A death with nothing recent on record (a dot outlasting its log entry, an
-- unlogged scripted death) reports cause "other", which only an any-cause
-- deed counts.
--
-- Where the combat log is closed (Forever), the death recap stands in for
-- it; see HitFromRecap.
--
-- Feign Death doesn't fire PLAYER_DEAD, so it never counts.
-- ---------------------------------------------------------------------------

local DeathSource = {}
ns.DeathSource = DeathSource

DeathSource.RECENT = 10 -- seconds
DeathSource.RECAP_DELAY = 1 -- seconds between looks at the recap
DeathSource.RECAP_TRIES = 5

local DAMAGE = {
    SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true, ENVIRONMENTAL_DAMAGE = true,
    DAMAGE_SHIELD = true, DAMAGE_SPLIT = true,
}

-- The combat log's environmentalType strings.
local ENVIRONMENT = {
    FALLING = "falling", DROWNING = "drowning", FATIGUE = "fatigue",
    FIRE = "fire", LAVA = "lava", SLIME = "slime",
}

local function now() return (GetTime and GetTime()) or os.time() end

function DeathSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    if not ns.combatLogClosed then
        f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
    f:RegisterEvent("PLAYER_DEAD")
    f:SetScript("OnEvent", function(_, event, ...)
        if event ~= "PLAYER_DEAD" then
            self:OnCombatLog(ns.Signals.CombatLog(...))
        elseif ns.combatLogClosed then
            self:AwaitRecap(1)
        else
            self:OnDeath()
        end
    end)
end

-- What a damaging hit says about the cause of death.
local function describeHit(subevent, sourceGUID, sourceName, environmentalType)
    local hit = { at = now() }
    if subevent == "ENVIRONMENTAL_DAMAGE" or environmentalType then
        hit.cause = ENVIRONMENT[string.upper(tostring(environmentalType))] or "other"
    elseif type(sourceGUID) == "string" and sourceGUID:find("^Player") then
        hit.cause = "player"
        hit.name = sourceName
    else
        hit.cause = "creature"
        hit.name = sourceName
        hit.npcID = ns.Signals.NpcID(sourceGUID)
    end
    return hit
end

-- Takes the combat-log payload already unpacked.
function DeathSource:OnCombatLog(_timestamp, subevent, _hideCaster, sourceGUID,
        sourceName, _sourceFlags, _sourceRaidFlags, destGUID, _destName,
        _destFlags, _destRaidFlags, environmentalType)
    if not DAMAGE[subevent] then return end
    if destGUID ~= UnitGUID("player") then return end

    self.lastHit = describeHit(subevent, sourceGUID, sourceName,
        subevent == "ENVIRONMENTAL_DAMAGE" and environmentalType or nil)
end

-- Forever has no combat log for addons, but it keeps the death recap (the
-- "You died. Click to view death recap" link), whose entries are the last
-- hits you took. The dump doesn't list the entries' fields, so they're read
-- by the names Blizzard's own recap frame uses, and anything missing or
-- secret just leaves the cause "other". The killing blow is the entry with
-- the latest timestamp (measured: entries come newest first). Returns the hit,
-- or nil and true when the recap is a previous death's.
function DeathSource:HitFromRecap()
    local D = C_DeathRecap
    if not (D and D.GetRecapEvents) then return nil end
    local ok, events = pcall(D.GetRecapEvents)
    if not ok or type(events) ~= "table" then return nil end
    local R = ns.Signals.Readable
    local best, bestAt
    for _, e in ipairs(events) do
        if type(e) == "table" then
            local at = tonumber(R(e.timestamp))
            if not best or (at and (not bestAt or at > bestAt)) then best, bestAt = e, at end
        end
    end
    if not best then return nil end
    -- Until this death's recap is written, the game hands back the previous
    -- one. Measured on Forever: entry timestamps are wall-clock seconds, so
    -- an old killing blow, or the same one as last time, is a stale recap.
    local clock = (GetServerTime and GetServerTime()) or (time and time())
    if bestAt and clock and clock - bestAt > self.RECENT then return nil, true end
    if bestAt and bestAt == self.lastRecapAt then return nil, true end
    self.lastRecapAt = bestAt
    return describeHit(R(best.event), R(best.sourceGUID), R(best.sourceName),
        R(best.environmentalType))
end

-- /deed recap: everything the death recap holds, raw. The dump doesn't
-- document the entries, so this is how to see what they really contain.
function DeathSource:DumpRecap(print)
    local D = C_DeathRecap
    if not (D and D.GetRecapEvents) then print("no death recap on this client"); return end
    local R = ns.Signals.Readable
    local function show(v)
        v = R(v)
        if v == nil then return "?" end
        return (tostring(v):gsub("|", "||"))
    end
    if D.HasRecapEvents then
        local ok, has = pcall(D.HasRecapEvents)
        print("HasRecapEvents: " .. (ok and show(has) or "error"))
    end
    if D.GetRecapLink then
        local ok, link = pcall(D.GetRecapLink)
        print("GetRecapLink: " .. (ok and show(link) or "error"))
    end
    local ok, events = pcall(D.GetRecapEvents)
    if not ok or type(events) ~= "table" then print("GetRecapEvents: nothing"); return end
    print(("GetRecapEvents: %d entries"):format(#events))
    for i, e in ipairs(events) do
        if type(e) == "table" then
            local keys = {}
            for k in pairs(e) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. show(e[k]) end
            print(("  [%d] %s"):format(i, table.concat(parts, " ")))
        else
            print(("  [%d] %s"):format(i, show(e)))
        end
    end
end

-- The recap is written as you die, sometimes after PLAYER_DEAD. A fall
-- death in Teldrassil read the previous recap and blamed the last duel
-- opponent. So look again, a few times, until a recap from this death turns
-- up; failing that the death still counts, as "other".
function DeathSource:AwaitRecap(try)
    ns.After(self.RECAP_DELAY, function()
        local hit, stale = self:HitFromRecap()
        if stale and try < self.RECAP_TRIES then return self:AwaitRecap(try + 1) end
        self:OnDeath(hit, true)
    end)
end

-- The hit is the combat log's last one, unless it comes from the recap.
function DeathSource:OnDeath(hit, fromRecap)
    if not fromRecap then hit = self.lastHit end
    self.lastHit = nil
    if hit and now() - hit.at > self.RECENT then hit = nil end

    self.engine:ReportProgress(ns.Signals.Make("death", {
        cause = hit and hit.cause or "other",
        name  = hit and hit.name,
        id    = hit and hit.npcID,
    }))
end
