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
    empty:SetText("No deeds yet.\nClick \"New Deed\" to start.")
    empty:Hide()
    f.empty = empty

    f.rows = {}
    self.frame = f
    return f
end

local function getRow(f, i)
    local row = f.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, f)
    row:SetSize(316, 34)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
    row.text:SetPoint("TOPLEFT", 0, 0)
    row.text:SetWidth(284)
    row.text:SetJustifyH("LEFT")

    row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.del:SetSize(22, 22)
    row.del:SetPoint("TOPRIGHT", 4, 4)

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
        row.del:SetScript("OnClick", function() ns.Engine:DeleteTracker(id) end)

        local count = ns.Engine:GetProgress(t.id)
        local curTitle = ns.Engine:CurrentTitle(t)
        local nextTier = ns.Engine:NextTier(t)

        local line
        if curTitle then
            line = ("|cffffd100%s|r  \226\128\148  %s: %d"):format(curTitle, t.name, count)
        else
            line = ("%s: %d"):format(t.name, count)
        end
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
