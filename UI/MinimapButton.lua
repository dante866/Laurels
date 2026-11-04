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
-- Left-click toggles the window, right-click opens Nearby. /deed minimap
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

    -- The coin border sits off-centre in its texture, so it is offset; it is
    -- hosted in its own frame because UnitMode found Texture:SetPoint takes
    -- only one argument on a Classic 1.x client.
    local borderHost = CreateFrame("Frame", nil, b)
    borderHost:SetSize(53, 53)
    borderHost:SetPoint("CENTER", b, "CENTER", 10, -10)
    local border = borderHost:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("CENTER")

    -- The wreath is our own art (tools/make_icon.ps1), not a game icon.
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON)
    icon:SetPoint("CENTER")

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Laurels", 1, 0.82, 0)
        GameTooltip:AddLine("Click to open your deeds", 0.8, 0.8, 0.8)
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
            if mouse == "RightButton" then
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
