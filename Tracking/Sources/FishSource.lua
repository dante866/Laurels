local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- FishSource: emits a "fish" signal for each catch.
--
-- A catch is a loot window that IsFishingLoot() says came from fishing. It
-- counts once however many items are in it, and the signal carries every
-- item's name, so "Catch name has: Smallfish" counts any catch containing
-- one. A cast that catches nothing opens no window and doesn't count.
-- ---------------------------------------------------------------------------

local FishSource = {}
ns.FishSource = FishSource

-- A loot window can report itself opened twice; a real second catch is at
-- least a cast-and-bite away.
FishSource.DUPLICATE = 1.5 -- seconds

local function now() return (GetTime and GetTime()) or os.time() end

function FishSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("LOOT_OPENED")
    f:SetScript("OnEvent", function() self:OnLoot() end)
end

function FishSource:OnLoot()
    if not (IsFishingLoot and IsFishingLoot()) then return end

    local t = now()
    if t - (self.lastAt or -math.huge) < self.DUPLICATE then return end
    self.lastAt = t

    local names = {}
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local _, name = GetLootSlotInfo(slot)
        if type(name) == "string" and name ~= "" then names[#names + 1] = name end
    end
    self.engine:ReportProgress(ns.Signals.Make("fish",
        { name = names[1], names = names }))
end
