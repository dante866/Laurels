local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- QuestSource: emits a "quest" signal each time the player turns a quest in.
--
-- QUEST_TURNED_IN carries the quest id. The title is looked up by id, with
-- the reward panel's title (captured on QUEST_COMPLETE, just before the
-- turn-in) as a fallback -- by the time QUEST_TURNED_IN fires the quest has
-- left the log, and a lookup by id can come back empty for a quest the client
-- hasn't cached.
--
-- The zone is where the quest is handed in, not where its objectives were.
-- ---------------------------------------------------------------------------

local QuestSource = {}
ns.QuestSource = QuestSource

local pendingTitle

local function titleFor(questID)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID and questID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and type(title) == "string" and title ~= "" then return title end
    end
    return pendingTitle
end

function QuestSource:Init(engine)
    self.engine = engine
    if self.frame then return end

    local f = CreateFrame("Frame")
    self.frame = f
    f:RegisterEvent("QUEST_COMPLETE")
    f:RegisterEvent("QUEST_TURNED_IN")
    f:SetScript("OnEvent", function(_, event, ...) self:OnEvent(event, ...) end)
end

function QuestSource:OnEvent(event, questID)
    if event == "QUEST_COMPLETE" then
        local title = GetTitleText and GetTitleText()
        pendingTitle = (title ~= "") and title or nil
        return
    end

    questID = tonumber(questID)
    local signal = ns.Signals.Make("quest", { id = questID, name = titleFor(questID) })
    pendingTitle = nil
    self.engine:ReportProgress(signal)
end
