local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- The Deeds pane: every tracker with its count, earned title, next-tier goal,
-- and (for published deeds) who currently holds it.
--
-- A pane inside MainFrame rather than a window of its own -- the shell owns
-- the backdrop, title, dragging and closing, and the sidebar menu replaced the
-- New Deed / Nearby buttons that used to sit along the bottom.
-- ---------------------------------------------------------------------------

local UI = {}
ns.UI = UI

-- Rows vary in height -- a published deed carries a holder/rank line that an
-- unpublished one doesn't -- so the list is laid out against a fixed budget
-- and anything that doesn't fit is reported as a count instead.
local MAX_CONTENT = 390

function UI:Init()
    -- Pane built lazily by MainFrame on first selection.
end

-- Kept so older call sites and the refresh paths keep working; the "frame"
-- is now the content holder MainFrame hands us, not a window.
function UI:GetFrame()
    return ns.MainFrame:PaneFrame("deeds")
end

local function buildDeedsPane(f)
    UI.frame = f

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    empty:SetPoint("CENTER", 0, 10)
    empty:SetText("No deeds yet.\nPick |cff66ccffNew Deed|r on the left.\n\n"
        .. "|cff999999A deed is a thing to count\nplus the titles you earn for it.|r")
    empty:Hide()
    f.empty = empty

    local more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    more:SetPoint("BOTTOM", 0, 6)
    more:Hide()
    f.more = more

    f.rows = {}
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
    GameTooltip:AddLine(("Counts: %s"):format(ns.Kinds.Describe(t.event, t.match)),
        0.6, 0.6, 0.6)
    GameTooltip:AddLine(("Published: %s"):format(t.published and "yes" or "no"),
        0.6, 0.6, 0.6)
    if t.published and t.uuid then
        -- The id a rival needs to adopt to contest this deed. Reachable from
        -- the Nearby panel now, but still worth being able to read directly.
        GameTooltip:AddLine(("Challenge id: %s"):format(t.uuid), 1, 0.82, 0)
    end

    -- The ladder itself, so checking where you stand doesn't mean typing
    -- /deed rivals every time.
    if t.published and ns.Rival and ns.Ladder then
        local key = ns.Rival:KeyFor(t)
        local board = ns.Ladder:GetStandings(key)
        if #board > 0 then
            local myGuid = ns.Rival:MyGuid()
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Ladder:", 1, 1, 1)
            for i = 1, math.min(#board, 5) do
                local e = board[i]
                local mine = (e.guid == myGuid)
                GameTooltip:AddLine(
                    ("  %d. %s \226\128\148 %d%s"):format(
                        i, e.name or "?", e.count or 0, mine and "  (you)" or ""),
                    mine and 0.2 or 0.8, mine and 1 or 0.8, mine and 0.2 or 0.8)
            end
            if #board > 5 then
                GameTooltip:AddLine(("  \226\128\166 and %d more"):format(#board - 5),
                    0.6, 0.6, 0.6)
            end
        end
    end

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

-- Who holds a published deed and where we sit on it. Returns nil for an
-- unpublished deed, which has no ladder to report -- that is what makes rows
-- vary in height rather than all carrying a blank third line.
local function standingsLine(t)
    if not t.published or not (ns.Rival and ns.Ladder) then return nil end

    local key = ns.Rival:KeyFor(t)
    local holder = ns.Ladder:GetHolder(key)
    if not holder then return nil end

    local myGuid = ns.Rival:MyGuid()
    local rank, total = ns.Ladder:GetRank(key, myGuid)

    if (total or 0) <= 1 then
        return "|cff999999   you hold it \226\128\148 no rivals yet|r"
    end
    if holder.guid == myGuid then
        return ("|cff00ff00   you hold it|r|cff999999   (#%d of %d)|r")
            :format(rank or 1, total)
    end
    -- GetRank returns nil when we have no claim on this deed yet. Say how
    -- many rivals there are rather than inventing a rank for ourselves.
    -- The holder's name came from another client; escape before display.
    local who = ns.Comm.Escape(holder.name) or "someone"
    if not rank then
        return ("|cffff8800   %s holds it|r|cff999999  %d   (%d on the ladder)|r")
            :format(who, holder.count or 0, total)
    end
    return ("|cffff8800   %s holds it|r|cff999999  %d   (you: #%d of %d)|r")
        :format(who, holder.count or 0, rank, total)
end

local function getRow(f, i)
    local row = f.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, f)
    row:SetSize(398, 34)
    row:EnableMouse(true)
    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
    row.text:SetPoint("TOPLEFT", 0, 0)
    row.text:SetWidth(318)
    row.text:SetJustifyH("LEFT")

    -- Delete is the circle-and-slash "prohibited" sign, not a red X: the X
    -- read as the window's close button, which sits just above it.
    row.del = CreateFrame("Button", nil, row)
    row.del:SetSize(18, 18)
    row.del:SetPoint("TOPRIGHT", 0, 0)
    local icon = row.del:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    -- The equipment manager's "ignore this slot" icon. Textures aren't in the
    -- Forever dump, so fall back to the vanilla loot Pass icon if it's absent.
    local path = "Interface\\PaperDollInfoFrame\\UI-GearManager-LeaveItem-Opaque"
    if icon:SetTexture(path) == false then
        path = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
        icon:SetTexture(path)
    end
    row.del:SetHighlightTexture(path, "ADD")
    row.del:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 1, -1) end)
    row.del:SetScript("OnMouseUp", function() icon:SetAllPoints() end)
    row.del:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete deed", 1, 0.3, 0.3)
        GameTooltip:Show()
    end)
    row.del:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.edit = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.edit:SetSize(38, 20)
    row.edit:SetPoint("TOPRIGHT", -24, 0)
    row.edit:SetText("Edit")

    f.rows[i] = row
    return row
end

-- Deleting throws away the count and the deed's place on the rival ladder,
-- and there's no undo, so it asks first. Blizzard's own confirm dialog, the
-- same one used for destroying items. The id rides in the popup's data rather
-- than an upvalue, so a second click on another row can't confirm the wrong
-- deed.
StaticPopupDialogs["DEEDKEEPER_DELETE_DEED"] = {
    text = "Delete the deed \"%s\"?\n\nIts count and titles will be lost.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, id) ns.Engine:DeleteTracker(id) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3, -- dodges the taint other addons cause in slots 1-2
}

function UI:ConfirmDelete(id, name)
    StaticPopup_Show("DEEDKEEPER_DELETE_DEED", name or id, nil, id)
end

function UI:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    local f = self.frame
    local y = -4
    local i = 0
    local hidden = 0

    for _, t in ipairs(ns.db.trackers) do
        i = i + 1
        local row = getRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 4, y)

        local id = t.id
        row.trackerId = id
        local name = t.name
        row.del:SetScript("OnClick", function() UI:ConfirmDelete(id, name) end)
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

        -- Published deeds carry a third line; unpublished ones must not pay
        -- for a blank one, so the row advances by its real height.
        local standings = standingsLine(t)
        if standings then line = line .. "\n" .. standings end

        local step = standings and 54 or 40
        if -(y - step) > MAX_CONTENT then
            -- Out of room. Stop here and account for the rest rather than
            -- drawing rows through the bottom of the frame.
            i = i - 1
            hidden = #ns.db.trackers - i
            break
        end

        row:SetHeight(step - 6)
        row.text:SetText(line)
        row:Show()
        y = y - step
    end

    for j = i + 1, #f.rows do
        f.rows[j]:Hide()
    end

    if f.more then
        if hidden > 0 then
            f.more:SetText(("|cff999999+%d more \226\128\148 /deed list|r"):format(hidden))
            f.more:Show()
        else
            f.more:Hide()
        end
    end

    if f.empty then
        if i == 0 then f.empty:Show() else f.empty:Hide() end
    end
    self:RefreshNearby()
end

-- Called by the rival layer when a new published deed is heard. The pending
-- count rides on the menu entry itself, so an unopened Nearby pane still advertises
-- that something is waiting.
function UI:RefreshNearby()
    if ns.Nearby then ns.Nearby:Refresh() end
    if not ns.MainFrame:IsShown() then return end
    local pending = ns.Rival
        and (#ns.Rival:NearbyDeeds() + #ns.Rival:PendingUpdates()) or 0
    ns.MainFrame:SetTabLabel("nearby",
        pending > 0 and ("Nearby (%d)"):format(pending) or "Nearby")
end

function UI:Toggle()
    ns.MainFrame:Toggle("deeds")
end

ns.MainFrame:RegisterPane("deeds", "Deeds", buildDeedsPane)
ns.MainFrame:GetPane("deeds").OnShow = function() UI:Refresh() end
