local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- MinimapButton: a wreath on the minimap edge, so opening Laurels doesn't
-- mean typing /laurels.
--
-- Built the same way as UnitMode's button rather than through LibDBIcon:
-- a plain Button parented to Minimap, Blizzard's tracking-ring border, and a
-- drag that walks it around the minimap edge. The angle is saved per
-- character, since minimap layouts differ between characters.
--
-- Left-click toggles the window, shift-click opens a blank New Deed,
-- right-click opens Nearby. /deed minimap
-- hides or shows it.
-- ---------------------------------------------------------------------------

local MB = {}
ns.MinimapButton = MB

MB.RADIUS = 80                -- minimap centre to button centre
MB.DEFAULT_ANGLE = math.rad(225) -- lower left, clear of the zoom buttons

local ICON = "Interface\\AddOns\\" .. addonName .. "\\Media\\LaurelsIcon"

local function settings()
    ns.charDB.minimap = ns.charDB.minimap or {}
    return ns.charDB.minimap
end

function MB:UpdatePosition(angle)
    self.button:ClearAllPoints()
    self.button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * self.RADIUS, math.sin(angle) * self.RADIUS)
end

local function pendingCount()
    if not ns.Rival then return 0 end
    return #ns.Rival:NearbyDeeds() + #ns.Rival:PendingUpdates()
end

local function makeButton()
    local b = CreateFrame("Button", "LaurelsMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Geometry is LibDBIcon's Classic layout (read from the copy TRP3
    -- bundles), because the ring sits off-centre in its texture and its hole
    -- is NOT at the button's centre. Centring the icon on the button, as
    -- UnitMode does, left it visibly low and left in the ring.
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    -- The wreath is our own art (tools/make_icon.ps1), not a game icon. It
    -- sits 1px left and 1px down of the dark disc: at the disc's own offset
    -- it looked high and right in the ring in game (judged by eye, since the
    -- ring texture's hole isn't exactly centred either).
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 6, -6)
    icon:SetTexture(ICON)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Laurels", 1, 0.82, 0)
        GameTooltip:AddLine("Click to open your deeds", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Shift-click: New Deed", 0.8, 0.8, 0.8)
        local n = pendingCount()
        if n > 0 then
            GameTooltip:AddLine(("Right-click: Nearby (%d waiting)"):format(n), 0.4, 1, 0.4)
        else
            GameTooltip:AddLine("Right-click: Nearby", 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine("Drag to move  \194\183  /deed minimap to hide", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- A click that ends a drag isn't a click.
    b:SetScript("OnClick", function(self, mouse)
        if not self.wasDragging then
            if mouse == "LeftButton" and IsShiftKeyDown() then
                ns.AuthorForm:Open() -- a blank New Deed
            elseif mouse == "RightButton" then
                ns.MainFrame:Show("nearby")
            else
                ns.MainFrame:Toggle("deeds")
            end
        end
        self.wasDragging = false
    end)

    -- Drag around the minimap edge.
    b:SetScript("OnMouseDown", function(self, mouse)
        if mouse ~= "LeftButton" then return end
        self.dragging, self.wasDragging = true, false
        local scale = UIParent:GetEffectiveScale()
        local x, y = GetCursorPosition()
        self.dragStartX, self.dragStartY = x / scale, y / scale
    end)
    b:SetScript("OnMouseUp", function(self, mouse)
        if mouse == "LeftButton" then self.dragging = false end
    end)
    b:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local mx, my = Minimap:GetCenter()
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
        -- Movement from the press point, not from the minimap centre.
        if not self.wasDragging
           and (math.abs(cx - self.dragStartX) > 4 or math.abs(cy - self.dragStartY) > 4) then
            self.wasDragging = true
        end
        if self.wasDragging then
            local angle = math.atan2(cy - my, cx - mx)
            settings().angle = angle
            MB:UpdatePosition(angle)
        end
    end)

    return b
end

function MB:Init()
    if self.button or not Minimap then return end
    self.button = makeButton()
    self:UpdatePosition(settings().angle or self.DEFAULT_ANGLE)
    self.button:SetShown(not settings().hidden)
end

-- /deed minimap: hide or show. Returns the new state for the message.
function MB:Toggle()
    local s = settings()
    s.hidden = not s.hidden
    if self.button then self.button:SetShown(not s.hidden) end
    return not s.hidden
end
