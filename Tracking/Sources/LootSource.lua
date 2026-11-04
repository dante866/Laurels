local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- LootSource: emits a "loot" signal each time you loot an item.
--
-- Read from your own loot line, matched against the client's own format
-- strings so it works in every language:
--   LOOT_ITEM_SELF_MULTIPLE  "You receive loot: %sx%d."
--   LOOT_ITEM_SELF           "You receive loot: %s."
-- The stack size is the signal's amount, so "loot 100 Linen Cloth" counts
-- cloth, not loot windows. Other players' loot lines use other strings, and
-- items handed to you (quest rewards, crafting) use LOOT_ITEM_PUSHED_SELF,
-- so neither counts.
-- ---------------------------------------------------------------------------

local LootSource = {}
ns.LootSource = LootSource

local SELF_MULTIPLE = "You receive loot: %sx%d."
local SELF          = "You receive loot: %s."

function LootSource:Init(engine)
    self.engine = engine
    if self.frame then return end
    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("CHAT_MSG_LOOT")
    f:SetScript("OnEvent", function(_, _, text) self:OnLoot(text) end)
end

function LootSource:OnLoot(text)
    -- Multiple first: its line also matches the single-item format.
    local a = ns.Signals.MatchFormat(text, LOOT_ITEM_SELF_MULTIPLE or SELF_MULTIPLE)
    local count = a and tonumber(a[2])
    if not a then
        a = ns.Signals.MatchFormat(text, LOOT_ITEM_SELF or SELF)
        count = 1
    end
    if not (a and a[1]) then return end

    local id, name, quality = ns.Signals.ItemFromLink(a[1])
    self.engine:ReportProgress(ns.Signals.Make("loot", {
        id = id, name = name or a[1], quality = quality, amount = count or 1,
    }))
end
