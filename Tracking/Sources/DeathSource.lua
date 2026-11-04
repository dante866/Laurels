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
-- Feign Death doesn't fire PLAYER_DEAD, so it never counts.
-- ---------------------------------------------------------------------------

local DeathSource = {}
ns.DeathSource = DeathSource

DeathSource.RECENT = 10 -- seconds

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
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("PLAYER_DEAD")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_DEAD" then
            self:OnDeath()
        else
            self:OnCombatLog(ns.Signals.CombatLog(...))
        end
    end)
end

-- Takes the combat-log payload already unpacked.
function DeathSource:OnCombatLog(_timestamp, subevent, _hideCaster, sourceGUID,
        sourceName, _sourceFlags, _sourceRaidFlags, destGUID, _destName,
        _destFlags, _destRaidFlags, environmentalType)
    if not DAMAGE[subevent] then return end
    if destGUID ~= UnitGUID("player") then return end

    local hit = { at = now() }
    if subevent == "ENVIRONMENTAL_DAMAGE" then
        hit.cause = ENVIRONMENT[string.upper(tostring(environmentalType))] or "other"
    elseif type(sourceGUID) == "string" and sourceGUID:find("^Player") then
        hit.cause = "player"
        hit.name = sourceName
    else
        hit.cause = "creature"
        hit.name = sourceName
        hit.npcID = ns.Signals.NpcID(sourceGUID)
    end
    self.lastHit = hit
end

function DeathSource:OnDeath()
    local hit = self.lastHit
    self.lastHit = nil
    if hit and now() - hit.at > self.RECENT then hit = nil end

    self.engine:ReportProgress(ns.Signals.Make("death", {
        cause = hit and hit.cause or "other",
        name  = hit and hit.name,
        id    = hit and hit.npcID,
    }))
end
