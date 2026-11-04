local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- FlightSource: emits a "flight" signal each time you take a flight.
--
-- Hooks TakeTaxiNode, which the flight map calls when you pick a
-- destination, but only counts the flight once you actually lose control to
-- the gryphon (PLAYER_CONTROL_LOST): picking a destination you can't afford
-- doesn't fly you anywhere. The zone is where you took off from.
-- ---------------------------------------------------------------------------

local FlightSource = {}
ns.FlightSource = FlightSource

-- How long after picking a destination the take-off may come.
FlightSource.WINDOW = 5 -- seconds

local function now() return (GetTime and GetTime()) or os.time() end

function FlightSource:Init(engine)
    self.engine = engine
    if self.frame then return end
    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("PLAYER_CONTROL_LOST")
    f:SetScript("OnEvent", function() self:OnControlLost() end)
    if hooksecurefunc and TakeTaxiNode then
        hooksecurefunc("TakeTaxiNode", function(slot) self:OnTakeTaxi(slot) end)
    end
end

function FlightSource:OnTakeTaxi(slot)
    local name = TaxiNodeName and TaxiNodeName(slot)
    -- Built now, so the zone is where you took off from.
    self.pending = { at = now(), signal = ns.Signals.Make("flight", { name = name }) }
end

function FlightSource:OnControlLost()
    local p = self.pending
    self.pending = nil
    if not p or now() - p.at > self.WINDOW then return end
    self.engine:ReportProgress(p.signal)
end
