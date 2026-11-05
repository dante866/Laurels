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

-- Whether you could attack this unit, so a friendly NPC whose name happens
-- to match a deed ("Night" in a town guard's name) doesn't advertise a kill
-- you can't make. Neutral (yellow) mobs are attackable and keep the line.
-- Where the answer can't be read (no API, an error, a secret value) the line
-- shows as it always did.
function UnitTooltip.Attackable(unit)
    if not UnitCanAttack then return true end
    local ok, can = pcall(UnitCanAttack, "player", unit)
    if not ok then return true end
    can = ns.Signals.Readable(can)
    if can == nil then return true end
    return can and true or false
end

local PREFIX = "|cffffd100Deeds:|r "

-- Whether this tooltip already carries our line. Both hooks are installed (see
-- Init) and a client may fire both for one tooltip, so the tooltip itself is
-- the record of whether we've been here -- no flag to clear on hide.
local function alreadyAdded(tooltip)
    -- NumLines isn't in the Forever dump, but nor are AddLine/SetOwner, which
    -- work: the dump doesn't cover GameTooltip methods. Guarded regardless.
    local name = tooltip.GetName and tooltip:GetName()
    if not name or not tooltip.NumLines then return false end
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and string.sub(text, 1, #PREFIX) == PREFIX then return true end
    end
    return false
end

-- Diagnostics for /deed tiptest: which hooks went in, which have fired.
UnitTooltip.stats = { installed = {}, fired = {} }

local function onUnit(tooltip, via)
    UnitTooltip.stats.fired[via] = (UnitTooltip.stats.fired[via] or 0) + 1
    if tooltip ~= GameTooltip or not tooltip.GetUnit then return end
    local _, unit = tooltip:GetUnit()
    -- Players aren't kills a deed counts (KillSource only sees creatures).
    if not unit or UnitIsPlayer(unit) then return end
    if not UnitTooltip.Attackable(unit) then return end
    if not (ns.db and ns.db.trackers and #ns.db.trackers > 0) then return end
    if alreadyAdded(tooltip) then return end

    local signal = ns.KillSource.SignalFor(UnitName(unit), UnitGUID(unit))
    local text = UnitTooltip.Line(ns.Engine:TrackersMatching(signal))
    if not text then return end

    -- Deed names are free text, and an accepted one came from another player.
    tooltip:AddLine(PREFIX .. ns.Comm.Escape(text), 1, 1, 1, true)
    tooltip:Show() -- resize to fit the new line
end

-- Neither hook appears in the Forever dump: both are Blizzard Lua UI code,
-- not C API. BOTH are installed, because having one is no proof it fires:
-- with only TooltipDataProcessor installed, MoP Classic showed no line at all.
-- The likely reason (unconfirmed -- /deed tiptest reports it) is that the
-- client defines TooltipDataProcessor as code shared with retail while its
-- mouseover tooltips never route through it. alreadyAdded() stops a client that fires both from
-- adding the line twice. HookScript is pcall'd because it errors on a script
-- the frame doesn't have.
function UnitTooltip:Init()
    if self.hooked then return end
    self.hooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
       and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        local ok = pcall(TooltipDataProcessor.AddTooltipPostCall,
            Enum.TooltipDataType.Unit,
            function(tooltip) onUnit(tooltip, "TooltipDataProcessor") end)
        self.stats.installed.TooltipDataProcessor = ok
    end
    if GameTooltip and GameTooltip.HookScript then
        local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit",
            function(tooltip) onUnit(tooltip, "OnTooltipSetUnit") end)
        self.stats.installed.OnTooltipSetUnit = ok
    end
end

-- /deed tiptest: mouse over (or target) a mob, then run it.
function UnitTooltip:Report()
    local function yn(v) return v and "|cff40ff40yes|r" or "|cffff4040no|r" end
    for _, via in ipairs({ "TooltipDataProcessor", "OnTooltipSetUnit" }) do
        ns:Print(("%s: installed %s, fired %d time(s)"):format(
            via, yn(self.stats.installed[via]), self.stats.fired[via] or 0))
    end
    local unit = (UnitExists("mouseover") and "mouseover")
        or (UnitExists("target") and "target") or nil
    if not unit then
        ns:Print("no mouseover or target -- point at a mob and run again")
        return
    end
    local signal = ns.KillSource.SignalFor(UnitName(unit), UnitGUID(unit))
    ns:Print(("%s: name=%s npcID=%s zone=%s zoneID=%s"):format(unit,
        tostring(signal.name), tostring(signal.npcID),
        tostring(signal.zone), tostring(signal.zoneID)))
    ns:Print("attackable: " .. yn(UnitTooltip.Attackable(unit))
        .. " (a deed line only shows on units you can attack)")
    local hits = ns.Engine:TrackersMatching(signal)
    ns:Print("matching deeds: " .. (UnitTooltip.Line(hits) or "none"))
end

UnitTooltip:Init()
