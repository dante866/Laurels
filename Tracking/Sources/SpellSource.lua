local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- SpellSource: emits a "spell" signal each time the player finishes a cast.
--
-- Using an item counts too: an item's use is a spell cast (Hearthstone,
-- bandages, potions), and so is crafting. Spell deeds must name the spell or
-- give its id -- the client reports a steady stream of internal casts, so an
-- unfiltered spell deed would count noise. /deed sources shows the last cast
-- seen with its id, which is the easy way to find one.
-- ---------------------------------------------------------------------------

local SpellSource = {}
ns.SpellSource = SpellSource

-- Actions the client reports as casts that aren't spells to anyone playing.
-- Challenging someone to a duel is spell 7266; the duel itself is the duel
-- deed's, so it isn't a cast too.
SpellSource.NOT_SPELLS = {
    [7266] = true, -- Duel
}

local function spellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and name then return name end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        -- A table on clients where it moved into C_Spell's shape.
        if ok and type(name) == "table" then return name.name end
        if ok then return name end
    end
end

function SpellSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    if f.RegisterUnitEvent then
        f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end
    f:SetScript("OnEvent", function(_, _, ...) self:OnCast(...) end)
end

-- The Forever dump gives (unitTarget, castGUID, spellID). Original MoP sent
-- (unit, spellName, rank, lineID, spellID); the fifth argument is read if the
-- third isn't a number, in case either client still does.
function SpellSource:OnCast(unit, _, third, _, fifth)
    if unit ~= "player" then return end
    local spellID = tonumber(third) or tonumber(fifth)
    if not spellID or self.NOT_SPELLS[spellID] then return end
    self.engine:ReportProgress(ns.Signals.Make("spell",
        { id = spellID, name = spellName(spellID) }))
end
