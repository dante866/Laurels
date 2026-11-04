local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- EmoteSource: emits an "emote" signal each time the player performs one.
--
-- Hooks the call every emote goes through rather than reading the emote's
-- chat line, which is localized ("You hug Rabbit."). The Forever dump has
-- both a global DoEmote and C_ChatInfo.PerformEmote; which one the slash
-- commands call (and whether one calls the other) isn't knowable from the
-- dump, so both are hooked and a repeat of the same emote within DUPLICATE
-- seconds is dropped.
--
-- The target is the name typed after the emote ("/hug Thrall"), or failing
-- that your current target -- which is who a bare "/hug" acts on.
-- ---------------------------------------------------------------------------

local EmoteSource = {}
ns.EmoteSource = EmoteSource

EmoteSource.DUPLICATE = 0.2 -- seconds

local function now() return (GetTime and GetTime()) or os.time() end

-- "hug", "/hug" or "HUG" -> the emote's token. Most slash commands match
-- their token, but not all (/lol is LAUGH), so the client's own command
-- table is consulted when it's there. Falls back to the word uppercased.
function EmoteSource.ResolveToken(text)
    local word = string.upper(tostring(text or ""):gsub("^%s*/?", ""):gsub("%s+$", ""))
    if word == "" then return nil end
    if type(hash_EmoteTokenList) == "table" and hash_EmoteTokenList["/" .. word] then
        return hash_EmoteTokenList["/" .. word]
    end
    -- The globals that table is built from, for a client that hasn't built it.
    for i = 1, (tonumber(MAXEMOTEINDEX) or 800) do
        local token = _G["EMOTE" .. i .. "_TOKEN"]
        if token then
            for j = 1, 6 do
                local cmd = _G["EMOTE" .. i .. "_CMD" .. j]
                if not cmd then break end
                if string.upper(cmd) == "/" .. word then return token end
            end
        end
    end
    return word
end

function EmoteSource:Init(engine)
    self.engine = engine
    if self.hooked or not hooksecurefunc then return end
    self.hooked = true
    if DoEmote then
        hooksecurefunc("DoEmote", function(token, target) self:OnEmote(token, target) end)
    end
    if C_ChatInfo and C_ChatInfo.PerformEmote then
        hooksecurefunc(C_ChatInfo, "PerformEmote",
            function(token, target) self:OnEmote(token, target) end)
    end
end

function EmoteSource:OnEmote(token, target)
    if type(token) ~= "string" or token == "" then return end
    token = string.upper(token)

    local t = now()
    if self.lastToken == token and t - (self.lastAt or 0) < self.DUPLICATE then return end
    self.lastToken, self.lastAt = token, t

    local name, npcID
    local hasTarget = UnitExists and UnitExists("target")
    if type(target) == "string" and target ~= "" and target ~= "none" then
        name = target
        -- The typed name only yields an NPC id when it is the unit targeted.
        if hasTarget and UnitName("target") == target then
            npcID = ns.Signals.NpcID(UnitGUID("target"))
        end
    elseif hasTarget then
        name = UnitName("target")
        npcID = ns.Signals.NpcID(UnitGUID("target"))
    end

    self.engine:ReportProgress(ns.Signals.Make("emote",
        { emote = token, name = name, id = npcID }))
end
