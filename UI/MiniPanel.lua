local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- MiniPanel: minimal UI. A draggable frame listing every tracker with its
-- count, earned title, and next-tier goal, plus a delete button per row and
-- a "New Deed" button. Rebuilt on demand via Refresh().
-- ---------------------------------------------------------------------------

local UI = {}
ns.UI = UI

function UI:Init()
    -- Frame created lazily on first Toggle().
end

function UI:GetFrame()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "DeedkeeperPanel", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(360, 320)
    f:SetPoint("CENTER")
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    table.insert(UISpecialFrames, "DeedkeeperPanel") -- ESC closes

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Deedkeeper")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local newBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    newBtn:SetSize(110, 24)
    newBtn:SetPoint("BOTTOM", 0, 14)
    newBtn:SetText("New Deed")
    newBtn:SetScript("OnClick", function()
        if ns.AuthorForm then ns.AuthorForm:Open() end
    end)

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    empty:SetPoint("CENTER", 0, 10)
    empty:SetText("No deeds yet.\nClick \"New Deed\" below, or type |cff66ccff/deed new|r.\n\n"
        .. "|cff999999A deed is a thing to count\nplus the titles you earn for it.|r")
    empty:Hide()
    f.empty = empty

    f.rows = {}
    self.frame = f
    return f
end

-- One-line summary of what a deed counts, for the tooltip.
local function describeMatch(m)
    if not m then return "anything" end
    local parts = {}
    if m.nameContains then
        table.insert(parts, ('name has "%s"'):format(m.nameContains))
    end
    if m.npcIDs and #m.npcIDs > 0 then
        table.insert(parts, ("%d NPC ID%s"):format(
            #m.npcIDs, #m.npcIDs == 1 and "" or "s"))
    end
    if m.zone then table.insert(parts, "in " .. m.zone)
    elseif m.zoneID then table.insert(parts, "in map " .. tostring(m.zoneID)) end
    return (#parts > 0) and table.concat(parts, ", ") or "anything"
end

-- The id is the thing you need for /deed publish, reset and rivals, and it is
-- otherwise only visible via /deed list -- so the row shows it and the tooltip
-- spells out the commands that want it.
local function showRowTooltip(row)
    local t = row.trackerId and ns.Engine:GetTracker(row.trackerId)
    if not t then return end

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(t.name, 1, 1, 1)
    GameTooltip:AddLine(("ID: %s"):format(t.id), 1, 0.82, 0)
    GameTooltip:AddLine(" ")

    GameTooltip:AddLine(("Progress: %d"):format(ns.Engine:GetProgress(t.id)), 0.9, 0.9, 0.9)
    local curTitle = ns.Engine:CurrentTitle(t)
    GameTooltip:AddLine(("Title: %s"):format(curTitle or "none yet"), 0.9, 0.9, 0.9)
    local nextTier = ns.Engine:NextTier(t)
    if nextTier then
        GameTooltip:AddLine(("Next: %s at %d"):format(nextTier.title, nextTier.count),
            0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(("Counts: %s"):format(describeMatch(t.match)), 0.6, 0.6, 0.6)
    GameTooltip:AddLine(("Published: %s"):format(t.published and "yes" or "no"),
        0.6, 0.6, 0.6)

    GameTooltip:AddLine(" ")
    if not t.published then
        GameTooltip:AddLine(("/deed publish %s"):format(t.id), 0.4, 0.8, 1)
    else
        GameTooltip:AddLine(("/deed rivals %s"):format(t.id), 0.4, 0.8, 1)
        GameTooltip:AddLine(("/deed unpublish %s"):format(t.id), 0.4, 0.8, 1)
    end
    GameTooltip:AddLine(("/deed reset %s"):format(t.id), 0.4, 0.8, 1)
    GameTooltip:Show()
end

local function getRow(f, i)
    local row = f.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, f)
    row:SetSize(316, 34)
    row:EnableMouse(true)
    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
    row.text:SetPoint("TOPLEFT", 0, 0)
    row.text:SetWidth(238)
    row.text:SetJustifyH("LEFT")

    row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.del:SetSize(22, 22)
    row.del:SetPoint("TOPRIGHT", 4, 4)

    row.edit = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.edit:SetSize(38, 20)
    row.edit:SetPoint("TOPRIGHT", -22, -1)
    row.edit:SetText("Edit")

    f.rows[i] = row
    return row
end

function UI:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    local f = self.frame
    local y = -46
    local i = 0

    for _, t in ipairs(ns.db.trackers) do
        i = i + 1
        local row = getRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 20, y)

        local id = t.id
        row.trackerId = id
        row.del:SetScript("OnClick", function() ns.Engine:DeleteTracker(id) end)
        row.edit:SetScript("OnClick", function()
            if ns.AuthorForm then ns.AuthorForm:Open(id) end
        end)

        local count = ns.Engine:GetProgress(t.id)
        local curTitle = ns.Engine:CurrentTitle(t)
        local nextTier = ns.Engine:NextTier(t)

        local line
        if curTitle then
            line = ("|cffffd100%s|r  \226\128\148  %s: %d"):format(curTitle, t.name, count)
        else
            line = ("%s: %d"):format(t.name, count)
        end
        -- The id, dimmed: needed for every /deed command that takes one.
        line = line .. ("  |cff808080[%s]|r"):format(id)
        if nextTier then
            line = line .. ("\n|cff999999   next: %s at %d  (%d to go)|r"):format(
                nextTier.title, nextTier.count, nextTier.count - count)
        else
            line = line .. "\n|cff999999   (all titles earned)|r"
        end

        row.text:SetText(line)
        row:Show()
        y = y - 40
    end

    for j = i + 1, #f.rows do
        f.rows[j]:Hide()
    end

    if f.empty then
        if i == 0 then f.empty:Show() else f.empty:Hide() end
    end
end

function UI:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        self:Refresh()
    end
end
