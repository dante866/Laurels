local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- MainFrame: the single window everything lives in, TRP3-style.
--
-- Deeds, Nearby and the authoring form used to be three separate movable
-- frames that overlapped each other and each needed closing by hand. They are
-- now panes in one window with a tab row, so there is one thing to position,
-- one thing to close, and switching between them is a click.
--
-- Panes register themselves and are BUILT LAZILY on first selection: the
-- authoring form in particular is expensive (a zone tree walked out of the
-- client's map data), and most sessions never open it.
-- ---------------------------------------------------------------------------

local Main = {}
ns.MainFrame = Main

-- The standard dialog backdrop, in one place rather than copied into every
-- frame. BackdropTemplateMixin is guarded because it does not exist on every
-- client we target.
function ns.ApplyDialogBackdrop(frame)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
end

Main.WIDTH  = 430
Main.HEIGHT = 520

-- Tab order lives here rather than in registration order, so it doesn't
-- silently depend on the order files appear in the .toc.
Main.TAB_ORDER = { "deeds", "nearby", "author" }

Main.panes = {}

-- Blizzard's top-tab template gives the proper notched look, but XML
-- templates can't be checked against the Forever API dump (it lists functions
-- and events, not templates) and these are Classic-flavoured clients. So try
-- it, and fall back to the button template already used everywhere else.
-- PanelTopTabButtonTemplate specifically, not the CharacterFrame one, whose
-- notch points downward for tabs hanging under a frame.
local function createTabButton(parent)
    local ok, button = pcall(CreateFrame, "Button", nil, parent,
        "PanelTopTabButtonTemplate")
    if ok and button then return button, true end
    button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    return button, false
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
    ns.ApplyDialogBackdrop(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:Hide()
    table.insert(UISpecialFrames, "DeedkeeperFrame") -- ESC closes

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -14)
    f.title:SetText("Deedkeeper")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- Tab row, directly under the title.
    f.tabs = {}
    local x = 16
    for _, key in ipairs(self.TAB_ORDER) do
        local pane = self.panes[key]
        if pane then
            local button, native = createTabButton(f)
            button:SetPoint("TOPLEFT", x, -38)
            button:SetText(pane.label)
            if native then
                -- The notched template sizes itself from its text.
                if PanelTemplates_TabResize then
                    PanelTemplates_TabResize(button, 0)
                end
            else
                button:SetSize(math.max(72, string.len(pane.label) * 9 + 20), 22)
            end
            button:SetScript("OnClick", function() Main:Select(key) end)
            x = x + button:GetWidth() + 4
            f.tabs[key] = button
        end
    end

    -- Everything a pane draws goes in here, so panes never touch the shell.
    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", 12, -66)
    f.content:SetPoint("BOTTOMRIGHT", -12, 12)

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
        if button then
            -- The current tab is disabled: it reads as "selected" on the
            -- notched template and as greyed-out on the fallback, and either
            -- way clicking it again is a no-op.
            if otherKey == key then button:Disable() else button:Enable() end
        end
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
