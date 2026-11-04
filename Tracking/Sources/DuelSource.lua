local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- DuelSource: emits a "duel" signal for each duel you win or lose.
--
-- DUEL_FINISHED carries nothing, not even who won. The result comes from the
-- system line the game prints, matched against the client's own format
-- strings so it works in every language:
--   DUEL_WINNER_KNOCKOUT  "%1$s has defeated %2$s in a duel"
--   DUEL_WINNER_RETREAT   "%2$s has fled from %1$s in a duel"
-- In both, argument 1 is the winner. Nearby players see the same line for
-- duels they aren't in, so a line naming neither side as you is ignored.
-- ---------------------------------------------------------------------------

local DuelSource = {}
ns.DuelSource = DuelSource

-- English fallbacks, for a client that doesn't expose the GlobalStrings.
local KNOCKOUT = "%1$s has defeated %2$s in a duel"
local RETREAT  = "%2$s has fled from %1$s in a duel"

-- Is a name in a system line ours? Names there may carry a realm ("Name-
-- Realm", MoP) or a family name ("Indira Resthaerl", Forever), while
-- UnitName("player") gives just "Name" / "Indira".
function DuelSource.IsMe(name)
    local me = UnitName and UnitName("player")
    if type(name) ~= "string" or not me then return false end
    if name == me then return true end
    local base = string.match(name, "^([^-]+)%-")
    if base == me then return true end
    return string.sub(name, 1, #me + 1) == me .. " "
end

function DuelSource:Init(engine)
    self.engine = engine
    if self.frame then return end
    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:SetScript("OnEvent", function(_, _, text) self:OnSystem(text) end)
end

function DuelSource:OnSystem(text)
    for _, fmt in ipairs({ DUEL_WINNER_KNOCKOUT or KNOCKOUT, DUEL_WINNER_RETREAT or RETREAT }) do
        local a = ns.Signals.MatchFormat(text, fmt)
        if a and a[1] and a[2] then
            local winner, loser = a[1], a[2]
            local result, opponent
            if DuelSource.IsMe(loser) then
                result, opponent = "lost", winner
            elseif DuelSource.IsMe(winner) then
                result, opponent = "won", loser
            else
                return -- someone else's duel
            end
            self.engine:ReportProgress(ns.Signals.Make("duel",
                { result = result, name = opponent }))
            return
        end
    end
end
