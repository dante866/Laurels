local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- RollSource: emits a "roll" signal each time you roll Need, Greed or Pass.
--
-- Hooks RollOnLoot(rollID, rollType), which every roll button goes through.
-- Roll types: 0 pass, 1 need, 2 greed (3, disenchant, isn't offered as a
-- filter and doesn't count). A roll is counted once per roll id, since a
-- Bind on Pickup item can route the same choice through a second call.
-- Note a roll counts when you click it: cancelling a Bind on Pickup warning
-- afterwards doesn't take it back.
-- ---------------------------------------------------------------------------

local RollSource = {}
ns.RollSource = RollSource

local ROLL = { [0] = "pass", [1] = "need", [2] = "greed" }

function RollSource:Init(engine)
    self.engine = engine
    self.counted = self.counted or {}
    if self.hooked or not (hooksecurefunc and RollOnLoot) then return end
    self.hooked = true
    hooksecurefunc("RollOnLoot", function(rollID, rollType) self:OnRoll(rollID, rollType) end)
end

function RollSource:OnRoll(rollID, rollType)
    local roll = ROLL[tonumber(rollType)]
    if not roll or rollID == nil or self.counted[rollID] then return end
    self.counted[rollID] = true
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    local id, name = ns.Signals.ItemFromLink(link)
    self.engine:ReportProgress(ns.Signals.Make("roll", { roll = roll, id = id, name = name }))
end
