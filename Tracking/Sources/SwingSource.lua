local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- SwingSource: emits a "swing" signal for each auto-attack that deals damage.
--
-- Only SWING_DAMAGE counts: misses, dodges and parries deal no damage, and
-- special attacks (Heroic Strike, Sinister Strike) are spell casts, which
-- spell deeds already count. The signal names the weapon family in the hand
-- that swung -- SWING_DAMAGE flags off-hand hits -- so a dual-wielder with a
-- sword and a dagger feeds a Sword deed only from the sword's hits.
-- ---------------------------------------------------------------------------

local SwingSource = {}
ns.SwingSource = SwingSource

local MAIN_HAND, OFF_HAND = 16, 17

-- Weapon item subclass ids -> family. The ids are the client's item
-- subclass numbering, unchanged since vanilla; they aren't in the Forever
-- dump, so Enum.ItemWeaponSubclass is preferred when a client has it.
-- Read by subclass id rather than name, which would be localized.
local function familyTable()
    local E = Enum and Enum.ItemWeaponSubclass
    local function id(key, fallback) return (E and E[key]) or fallback end
    return {
        [id("Axe1H", 0)]     = "axe",     [id("Axe2H", 1)]   = "axe",
        [id("Mace1H", 4)]    = "mace",    [id("Mace2H", 5)]  = "mace",
        [id("Polearm", 6)]   = "polearm",
        [id("Sword1H", 7)]   = "sword",   [id("Sword2H", 8)] = "sword",
        [id("Staff", 10)]    = "staff",
        [id("Unarmed", 13)]  = "fist",    -- fist weapons
        [id("Dagger", 15)]   = "dagger",
    }
end
SwingSource.FAMILY = familyTable()

local function itemSubclass(itemID)
    local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not info then return nil end
    local ok, _, _, _, _, _, classID, subClassID = pcall(info, itemID)
    if ok then return classID, subClassID end
end

-- The family of the weapon in a slot: "unarmed" with nothing there, "other"
-- for anything held that isn't a melee family (a fishing pole, say).
function SwingSource.WeaponIn(slot)
    local itemID = GetInventoryItemID and GetInventoryItemID("player", slot)
    if not itemID then return "unarmed" end
    local _, subClassID = itemSubclass(itemID)
    return SwingSource.FAMILY[subClassID] or "other"
end

function SwingSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            self.weapons = nil -- re-read on the next swing
        else
            self:OnCombatLog(ns.Signals.CombatLog(...))
        end
    end)
end

-- Looked up once per gear change rather than on every swing.
function SwingSource:Weapon(offHand)
    if not self.weapons then
        self.weapons = { main = self.WeaponIn(MAIN_HAND), off = self.WeaponIn(OFF_HAND) }
    end
    return offHand and self.weapons.off or self.weapons.main
end

-- Takes the combat-log payload already unpacked. SWING_DAMAGE's suffix is
-- amount, overkill, school, resisted, blocked, absorbed, critical, glancing,
-- crushing, isOffHand -- the last being the 21st value overall.
function SwingSource:OnCombatLog(...)
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName = ...
    if subevent ~= "SWING_DAMAGE" then return end
    if sourceGUID ~= UnitGUID("player") then return end
    local offHand = select(21, ...) and true or false

    self.engine:ReportProgress(ns.Signals.Make("swing", {
        weapon = self:Weapon(offHand),
        name   = destName,
        id     = ns.Signals.NpcID(destGUID),
    }))
end
