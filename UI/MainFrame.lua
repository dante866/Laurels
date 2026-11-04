local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- MainFrame: the single window everything lives in, laid out like TRP3's.
--
-- Deeds, Nearby and the authoring form used to be three separate movable
-- frames that overlapped each other and each needed closing by hand. They are
-- now panes in one window with a sidebar menu down the left, so there is one
-- thing to position, one thing to close, and switching between them is a
-- click.
--
-- Panes register themselves and are BUILT LAZILY on first selection: the
-- authoring form in particular is expensive (a zone tree walked out of the
-- client's map data), and most sessions never open it.
-- ---------------------------------------------------------------------------

local Main = {}
ns.MainFrame = Main

-- The standard dialog backdrop, in one place rather than copied into every
-- frame. Still used by the toast, which is an overlay and not part of the
-- main window's look.
function ns.ApplyDialogBackdrop(frame)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
end

-- Geometry. The content area is sized to what the panes were laid out for
-- (rows 398 wide at x=4), and the window is derived from it rather than the
-- other way round.
Main.SIDEBAR_WIDTH = 150
Main.WOOD          = 14   -- thickness of the wooden strips
Main.CONTENT_LEFT  = 4 + Main.SIDEBAR_WIDTH + Main.WOOD + 8
Main.CONTENT_WIDTH = 404
Main.WIDTH         = Main.CONTENT_LEFT + Main.CONTENT_WIDTH + 22
Main.HEIGHT        = 480

-- TRP3's frame border colour, so the two windows sit together.
local BORDER = { 0.48, 0.39, 0.32 }

-- Menu order lives here rather than in registration order, so it doesn't
-- silently depend on the order files appear in the .toc.
Main.TAB_ORDER = { "deeds", "nearby", "author" }

Main.panes = {}

-- When TRP3 is installed we borrow its frame art by path at runtime -- nothing
-- of TRP3's is shipped in this addon.
--
-- Gated on the files being INSTALLED, not on TRP3 being loaded: textures are
-- read straight off disk, so the art works on a character with TRP3 disabled.
-- (Measured: an IsAddOnLoaded gate fell back to stock art on a client that had
-- TRP3 in its AddOns folder.) The probe's SetTexture result is the final word.
local TRP3_ART = "Interface\\AddOns\\totalRP3\\Resources\\UI\\"

local function haveTRP3Art(f)
    local info = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    if not info then return false end
    local ok, name, _, _, _, reason = pcall(info, "totalRP3")
    if not ok or not name or reason == "MISSING" then return false end
    local probe = f:CreateTexture()
    local found = probe:SetTexture(TRP3_ART .. "ui-category-button")
    probe:Hide()
    return found ~= false
end

-- A wooden strip along one edge. Vertical strips tile down, horizontal ones
-- across; the texcoords are the halves of TRP3's border sheets.
local function woodStrip(f, vertical)
    local t = f:CreateTexture(nil, "BORDER")
    if vertical then
        t:SetTexture(TRP3_ART .. "!ui-frame-wooden-border", nil, "REPEAT")
        t:SetVertTile(true)
        t:SetTexCoord(0.0078125, 0.2265625, 0, 1)
        t:SetWidth(Main.WOOD)
    else
        t:SetTexture(TRP3_ART .. "_ui-frame-wooden-border", "REPEAT", nil)
        t:SetHorizTile(true)
        t:SetTexCoord(0, 1, 0.484375, 0.921875)
        t:SetHeight(Main.WOOD)
    end
    t:SetVertexColor(1, 0.8, 0.8)
    return t
end

local function applyShellArt(f)
    local trp3 = haveTRP3Art(f)
    Main.trp3Art = trp3

    -- Both background textures carry alpha, which let the world show through
    -- the window. An opaque base underneath fixes that.
    local base = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    base:SetPoint("TOPLEFT", 4, -4)
    base:SetPoint("BOTTOMRIGHT", -4, 4)
    base:SetColorTexture(0.11, 0.08, 0.06, 1)

    if f.SetBackdrop then
        f:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        if f.SetBackdropBorderColor then
            f:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3])
        end
    end

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 4, -4)
    bg:SetPoint("BOTTOMRIGHT", -4, 4)
    if trp3 then
        bg:SetTexture(TRP3_ART .. "ui-frame-neutral-background", "REPEAT", "REPEAT")
        bg:SetHorizTile(true)
        bg:SetVertTile(true)
        bg:SetVertexColor(0.6, 0.6, 0.6)
    else
        bg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background", "REPEAT", "REPEAT")
        bg:SetHorizTile(true)
        bg:SetVertTile(true)
        bg:SetVertexColor(1, 0.85, 0.7)
    end

    -- The sidebar sits on a slightly darker panel, as in TRP3.
    local side = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    side:SetPoint("TOPLEFT", 4, -4)
    side:SetPoint("BOTTOMLEFT", 4, 4)
    side:SetWidth(Main.SIDEBAR_WIDTH + Main.WOOD)
    side:SetColorTexture(0, 0, 0, 0.25)

    local dividerX = 4 + Main.SIDEBAR_WIDTH
    if trp3 then
        local l = woodStrip(f, true)
        l:SetPoint("TOPLEFT", 4, -4); l:SetPoint("BOTTOMLEFT", 4, 4)
        local r = woodStrip(f, true)
        r:SetPoint("TOPRIGHT", -4, -4); r:SetPoint("BOTTOMRIGHT", -4, 4)
        r:SetTexCoord(0.2265625, 0.0078125, 0, 1) -- mirrored
        local t = woodStrip(f, false)
        t:SetPoint("TOPLEFT", 4, -4); t:SetPoint("TOPRIGHT", -4, -4)
        local b = woodStrip(f, false)
        b:SetPoint("BOTTOMLEFT", 4, 4); b:SetPoint("BOTTOMRIGHT", -4, 4)
        b:SetTexCoord(0, 1, 0.015625, 0.453125)
        local d = woodStrip(f, true)
        d:SetPoint("TOPLEFT", dividerX, -4); d:SetPoint("BOTTOMLEFT", dividerX, 4)
    else
        local d = f:CreateTexture(nil, "BORDER")
        d:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 0.9)
        d:SetWidth(2)
        d:SetPoint("TOPLEFT", dividerX + Main.WOOD / 2, -6)
        d:SetPoint("BOTTOMLEFT", dividerX + Main.WOOD / 2, 6)
    end
end

-- TRP3's category button: a three-slice sheet (left edge, tiled centre,
-- right edge), with a border layer on top and an additive highlight pair.
-- Coordinates are TRP3's own, from UI/Sidebar/CategoryButton.xml/.lua.
local SHEET = TRP3_ART .. "ui-category-button"
local CATEGORY_STATES = {
    NORMAL  = { { 0.5, 0.75, 0, 0.125 },     { 0.75, 1, 0, 0.125 },     { 0, 1, 0.375, 0.5 } },
    PUSHED  = { { 0, 0.25, 0.25, 0.375 },    { 0.25, 0.5, 0.25, 0.375 }, { 0, 1, 0.5, 0.625 } },
}

local function threeSlice(button, layer, sub, alphaMode)
    local l = button:CreateTexture(nil, layer, nil, sub)
    l:SetTexture(SHEET); l:SetWidth(16)
    l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT")
    local r = button:CreateTexture(nil, layer, nil, sub)
    r:SetTexture(SHEET); r:SetWidth(16)
    r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT")
    local c = button:CreateTexture(nil, layer, nil, sub)
    c:SetTexture(SHEET, "REPEAT", nil); c:SetHorizTile(true)
    c:SetPoint("TOPLEFT", l, "TOPRIGHT"); c:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
    if alphaMode then
        l:SetBlendMode(alphaMode); r:SetBlendMode(alphaMode); c:SetBlendMode(alphaMode)
    end
    return l, r, c
end

local function setSlice(l, r, c, coords)
    l:SetTexCoord(unpack(coords[1]))
    r:SetTexCoord(unpack(coords[2]))
    c:SetTexCoord(unpack(coords[3]))
end

local function createCategoryButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(Main.SIDEBAR_WIDTH - 16, 32)

    local l, r, c = threeSlice(button, "BACKGROUND", 0)
    local bl, br, bc = threeSlice(button, "BORDER", 0)
    setSlice(bl, br, bc, { { 0, 0.25, 0, 0.125 }, { 0.25, 0.5, 0, 0.125 }, { 0, 1, 0.125, 0.25 } })
    local hl, hr, hc = threeSlice(button, "HIGHLIGHT", 0, "ADD")
    setSlice(hl, hr, hc, CATEGORY_STATES.PUSHED)
    local hbl, hbr, hbc = threeSlice(button, "HIGHLIGHT", 1, "ADD")
    setSlice(hbl, hbr, hbc, { { 0, 0.25, 0.75, 0.875 }, { 0.25, 0.5, 0.75, 0.875 }, { 0, 1, 0.875, 1 } })

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.label:SetPoint("LEFT", 14, 0)
    button.label:SetJustifyH("LEFT")

    function button:SetText(text) self.label:SetText(text) end
    -- Selected is drawn as TRP3's pushed state, held.
    function button:SetSelected(on)
        setSlice(l, r, c, on and CATEGORY_STATES.PUSHED or CATEGORY_STATES.NORMAL)
        if on then
            self.label:SetTextColor(1, 1, 1)
        else
            self.label:SetTextColor(1, 0.82, 0)
        end
    end
    return button
end

-- A sidebar menu entry. Plain buttons rather than a template: the selected
-- state is drawn here, so it looks the same on every client.
local function createMenuButton(parent)
    if Main.trp3Art then return createCategoryButton(parent) end

    local button = CreateFrame("Button", nil, parent)
    button:SetSize(Main.SIDEBAR_WIDTH - 20, 26)

    button.selected = button:CreateTexture(nil, "BACKGROUND")
    button.selected:SetAllPoints()
    button.selected:SetColorTexture(1, 0.82, 0, 0.14)
    button.selected:Hide()

    button.accent = button:CreateTexture(nil, "ARTWORK")
    button.accent:SetPoint("TOPLEFT"); button.accent:SetPoint("BOTTOMLEFT")
    button.accent:SetWidth(3)
    button.accent:SetColorTexture(1, 0.82, 0, 0.9)
    button.accent:Hide()

    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.label:SetPoint("LEFT", 12, 0)
    button.label:SetJustifyH("LEFT")

    function button:SetText(text) self.label:SetText(text) end
    function button:SetSelected(on)
        self.selected:SetShown(on)
        self.accent:SetShown(on)
        if on then
            self.label:SetTextColor(1, 1, 1)
        else
            self.label:SetTextColor(1, 0.82, 0)
        end
    end
    return button
end

function Main:RegisterPane(key, label, build)
    self.panes[key] = { key = key, label = label, build = build }
end

function Main:GetPane(key)
    return self.panes[key]
end

function Main:GetFrame()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "DeedkeeperFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(self.WIDTH, self.HEIGHT)
    f:SetPoint("CENTER")
    applyShellArt(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:Hide()
    table.insert(UISpecialFrames, "DeedkeeperFrame") -- ESC closes

    local menuLeft = 4 + self.WOOD + 2

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", menuLeft + 4, -(self.WOOD + 14))
    f.title:SetText("Deedkeeper")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetFrameLevel(f:GetFrameLevel() + 5)

    -- Sidebar menu, under the title.
    f.tabs = {}
    local y = -(self.WOOD + 46)
    for _, key in ipairs(self.TAB_ORDER) do
        local pane = self.panes[key]
        if pane then
            local button = createMenuButton(f)
            button:SetPoint("TOPLEFT", menuLeft, y)
            button:SetText(pane.label)
            button:SetSelected(false)
            button:SetScript("OnClick", function() Main:Select(key) end)
            y = y - (self.trp3Art and 36 or 30)
            f.tabs[key] = button
        end
    end

    -- Everything a pane draws goes in here, so panes never touch the shell.
    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", self.CONTENT_LEFT, -(self.WOOD + 10))
    f.content:SetPoint("BOTTOMRIGHT", -22, self.WOOD + 8)

    self.frame = f
    return f
end

-- A pane's frame, built on first request.
function Main:PaneFrame(key)
    local pane = self.panes[key]
    if not pane then return nil end
    if pane.frame then return pane.frame end

    local f = self:GetFrame()
    local holder = CreateFrame("Frame", nil, f.content)
    holder:SetAllPoints(f.content)
    holder:Hide()
    pane.frame = holder
    if pane.build then pane.build(holder) end
    return holder
end

function Main:SetTabLabel(key, label)
    local pane = self.panes[key]
    if pane then pane.label = label end
    if self.frame and self.frame.tabs[key] then
        self.frame.tabs[key]:SetText(label)
    end
end

function Main:Select(key)
    local f = self:GetFrame()
    if not self.panes[key] then return end

    for _, otherKey in ipairs(self.TAB_ORDER) do
        local pane = self.panes[otherKey]
        if pane and pane.frame then pane.frame:Hide() end
        local button = f.tabs[otherKey]
        if button then button:SetSelected(otherKey == key) end
    end

    self.current = key
    local holder = self:PaneFrame(key)
    if holder then holder:Show() end

    local pane = self.panes[key]
    if pane and pane.OnShow then pane.OnShow() end
end

function Main:Show(key)
    local f = self:GetFrame()
    f:Show()
    self:Select(key or self.current or self.TAB_ORDER[1])
end

function Main:Hide()
    if self.frame then self.frame:Hide() end
end

function Main:IsShown()
    return self.frame and self.frame:IsShown()
end

-- Toggling with a key already shown closes; with a different one, switches.
function Main:Toggle(key)
    key = key or self.TAB_ORDER[1]
    if self:IsShown() and self.current == key then
        self:Hide()
    else
        self:Show(key)
    end
end
