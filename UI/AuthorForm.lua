local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- AuthorForm: in-game form for creating a new deed (tracker) without editing
-- Lua. Name + match criteria + up to N title tiers. Kept intentionally plain.
-- ---------------------------------------------------------------------------

local AuthorForm = {}
ns.AuthorForm = AuthorForm

local TIER_ROWS = 5

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function makeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function makeEdit(parent, w, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetAutoFocus(false)
    e:SetSize(w, 20)
    e:SetFontObject("ChatFontNormal")
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

local function parseNpcIDs(str)
    str = trim(str)
    if str == "" then return nil end
    local ids = {}
    for token in string.gmatch(str, "[^,%s]+") do
        local n = tonumber(token)
        if n then table.insert(ids, n) end
    end
    return (#ids > 0) and ids or nil
end

function AuthorForm:GetFrame()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "DeedkeeperAuthorForm", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(390, 430)
    f:SetPoint("CENTER", 130, 0)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "DeedkeeperAuthorForm") -- ESC closes

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("New Deed")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    makeLabel(f, "Name", 20, -46)
    f.nameEdit = makeEdit(f, 230)
    f.nameEdit:SetPoint("TOPLEFT", 120, -42)

    makeLabel(f, "Event", 20, -76)
    local ev = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ev:SetPoint("TOPLEFT", 124, -76)
    ev:SetText("kill  |cff999999(more event types coming)|r")

    makeLabel(f, "Mob name has", 20, -106)
    f.matchEdit = makeEdit(f, 230)
    f.matchEdit:SetPoint("TOPLEFT", 120, -102)

    makeLabel(f, "NPC IDs", 20, -136)
    f.npcEdit = makeEdit(f, 230)
    f.npcEdit:SetPoint("TOPLEFT", 120, -132)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 122, -152)
    hint:SetText("optional, comma-separated \226\128\147 narrows the match")

    makeLabel(f, "Tiers  (count \226\134\146 title)", 20, -182)
    f.tierRows = {}
    for i = 1, TIER_ROWS do
        local y = -202 - (i - 1) * 28
        local cnt = makeEdit(f, 70, true)
        cnt:SetPoint("TOPLEFT", 30, y)
        local ttl = makeEdit(f, 210)
        ttl:SetPoint("TOPLEFT", 120, y)
        f.tierRows[i] = { count = cnt, title = ttl }
    end

    local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    save:SetSize(110, 24)
    save:SetPoint("BOTTOMRIGHT", -20, 16)
    save:SetText("Save")
    save:SetScript("OnClick", function() AuthorForm:Save() end)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(110, 24)
    cancel:SetPoint("BOTTOMLEFT", 20, 16)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() f:Hide() end)

    self.frame = f
    return f
end

function AuthorForm:Clear()
    local f = self.frame
    if not f then return end
    f.nameEdit:SetText("")
    f.matchEdit:SetText("")
    f.npcEdit:SetText("")
    for _, r in ipairs(f.tierRows) do
        r.count:SetText("")
        r.title:SetText("")
    end
end

function AuthorForm:Open()
    local f = self:GetFrame()
    self:Clear()
    f:Show()
    f.nameEdit:SetFocus()
end

function AuthorForm:Save()
    local f = self.frame
    if not f then return end

    local name = trim(f.nameEdit:GetText())
    if name == "" then
        ns:Print("A deed needs a name.")
        f.nameEdit:SetFocus()
        return
    end

    local match = {}
    local nameContains = trim(f.matchEdit:GetText())
    if nameContains ~= "" then match.nameContains = nameContains end
    local npcIDs = parseNpcIDs(f.npcEdit:GetText())
    if npcIDs then match.npcIDs = npcIDs end
    if not next(match) then
        ns:Print("Add a 'Mob name has' value or NPC IDs so the deed can match something.")
        return
    end

    local tiers = {}
    for _, r in ipairs(f.tierRows) do
        local c = tonumber(r.count:GetText())
        local tl = trim(r.title:GetText())
        if c and c > 0 and tl ~= "" then
            table.insert(tiers, { count = c, title = tl })
        end
    end
    if #tiers == 0 then
        ns:Print("Add at least one tier: a count and a title.")
        return
    end

    local def = ns.Engine:CreateTracker({
        name = name,
        event = "kill",
        match = match,
        tiers = tiers,
    })
    ns:Print(("Created deed: %s (%d tier%s)."):format(
        def.name, #tiers, #tiers == 1 and "" or "s"))
    f:Hide()
end
