local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- BossSource: emits a "boss" signal each time your group kills a dungeon or
-- raid boss.
--
-- From ENCOUNTER_END with success = 1, falling back to BOSS_KILL. A client
-- can fire both for one kill, so an encounter counted in the last DUPLICATE
-- seconds isn't counted again. Unlike a kill deed, this doesn't need your
-- killing blow: the whole group's kill counts for everyone in it.
--
-- Both events are in the Forever API dump, but whether Forever fires them
-- for its dungeons is unverified. A kill deed on the boss's NPC id works
-- either way.
-- ---------------------------------------------------------------------------

local BossSource = {}
ns.BossSource = BossSource

BossSource.DUPLICATE = 10 -- seconds

local function now() return (GetTime and GetTime()) or os.time() end

function BossSource:Init(engine)
    self.engine = engine
    self.recent = self.recent or {}
    if self.frame then return end
    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("BOSS_KILL")
    f:SetScript("OnEvent", function(_, event, ...) self:OnEvent(event, ...) end)
end

function BossSource:OnEvent(event, encounterID, encounterName, _, _, success)
    if event == "ENCOUNTER_END" and tonumber(success) ~= 1 then return end -- a wipe
    local id = tonumber(encounterID)
    if not id then return end
    local t = now()
    if self.recent[id] and t - self.recent[id] < self.DUPLICATE then return end
    self.recent[id] = t
    self.engine:ReportProgress(ns.Signals.Make("boss", { id = id, name = encounterName }))
end
