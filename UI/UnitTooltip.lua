local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- UnitTooltip: adds a line to a mob's tooltip naming the deeds that killing
-- it would count toward.
--
--   Mottled Boar
--   Level 3 Beast
--   Deeds: Boar Annoyer, Pig Sticker, +2 more
--
-- The question is put to the engine exactly as a kill would put it (same
-- signal builder, same matcher), so the tooltip can't promise a deed the kill
-- won't count. Zone-scoped deeds therefore only show in their zone.
-- ---------------------------------------------------------------------------

local UnitTooltip = {}
ns.UnitTooltip = UnitTooltip

-- Deeds named before the rest collapse into "+N more".
UnitTooltip.MAX_NAMED = 2

-- The text after "Deeds: ", or nil when nothing matches. Pure, so it can be
-- tested headlessly.
function UnitTooltip.Line(trackers)
    if not trackers or #trackers == 0 then return nil end
    local names = {}
    for i = 1, math.min(#trackers, UnitTooltip.MAX_NAMED) do
        names[i] = trackers[i].name or trackers[i].id
    end
    local extra = #trackers - #names
    if extra > 0 then
        table.insert(names, ("+%d more"):format(extra))
    end
    return table.concat(names, ", ")
end

local function onUnit(tooltip)
    if tooltip ~= GameTooltip or not tooltip.GetUnit then return end
    local _, unit = tooltip:GetUnit()
    -- Players aren't kills a deed counts (KillSource only sees creatures).
    if not unit or UnitIsPlayer(unit) then return end
    if not (ns.db and ns.db.trackers and #ns.db.trackers > 0) then return end

    local signal = ns.KillSource.SignalFor(UnitName(unit), UnitGUID(unit))
    local text = UnitTooltip.Line(ns.Engine:TrackersMatching(signal))
    if not text then return end

    tooltip:AddLine("|cffffd100Deeds:|r " .. text, 1, 1, 1, true)
    tooltip:Show() -- resize to fit the new line
end

-- Neither hook appears in the Forever dump: both are Blizzard Lua UI code,
-- not C API. TooltipDataProcessor is the modern-engine route; the older
-- OnTooltipSetUnit script is kept as a fallback, and pcall'd because
-- HookScript errors on a script a frame doesn't have. Only one is installed,
-- or the line would be added twice.
function UnitTooltip:Init()
    if self.hooked then return end
    self.hooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
       and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, onUnit)
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", onUnit)
    end
end

UnitTooltip:Init()
