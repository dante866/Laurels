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

-- --- zones -----------------------------------------------------------------

local ANY_ZONE = "Any zone  |cff999999(not scoped)|r"

local function currentZone()
    local name = GetZoneText and GetZoneText()
    if name == "" then name = nil end
    local id
    if C_Map and C_Map.GetBestMapForUnit then
        id = C_Map.GetBestMapForUnit("player")
    end
    return name, id
end

-- Walk up from where the player is standing to the top of the map tree rather
-- than hardcoding a world uiMapID. This is a custom server and may renumber
-- maps, so discovering the root is safer than assuming retail's.
local function rootMapID()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then return nil end
    local id = C_Map.GetBestMapForUnit("player")
    for _ = 1, 20 do -- bounded: a cycle in the map tree must not hang the UI
        if not id then return nil end
        local info = C_Map.GetMapInfo(id)
        if not info or not info.parentMapID or info.parentMapID == 0 then return id end
        id = info.parentMapID
    end
    return id
end

local MAPTYPE_CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local MAPTYPE_ZONE      = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

-- Most menu rows a leaf list may hold. Eastern Kingdoms has ~25 zones, which
-- overflowed the top of the screen as one submenu -- and UIDropDownMenu's
-- maxHeight only governs the top-level list, not submenus, so the cap has to
-- come from how we build the tree rather than from the widget.
local MAX_LEAF = 15

-- Split a long sorted zone list into alphabetical chunks ("A - D"), so every
-- leaf menu stays short enough to fit on screen whatever its anchor.
local function chunkZones(zones)
    if #zones <= MAX_LEAF then return nil end
    local chunks = {}
    local i = 1
    while i <= #zones do
        local last = math.min(i + MAX_LEAF - 1, #zones)
        local part = {}
        for k = i, last do part[#part + 1] = zones[k] end
        local a = string.upper(string.sub(zones[i].zone, 1, 1))
        local b = string.upper(string.sub(zones[last].zone, 1, 1))
        table.insert(chunks, {
            label = (a == b) and a or (a .. " \226\128\147 " .. b),
            zones = part,
        })
        i = last + 1
    end
    return chunks
end

local function zoneListFrom(mapID)
    local out, seen = {}, {}
    local ok, kids = pcall(C_Map.GetMapChildrenInfo, mapID, MAPTYPE_ZONE, true)
    if not ok or type(kids) ~= "table" then return out end
    for _, info in ipairs(kids) do
        if info.name and info.name ~= "" and not seen[info.name] then
            seen[info.name] = true
            table.insert(out, { zone = info.name, zoneID = info.mapID })
        end
    end
    table.sort(out, function(a, b) return a.zone < b.zone end)
    return out
end

-- Zones grouped by continent. A flat list of every zone runs off the bottom of
-- the screen -- there are ~80 of them -- so the dropdown nests one level, which
-- also matches how players think about where a zone is. Returns an empty tree
-- on any client that won't answer; the caller falls back to a flat list, and
-- "Any zone" / "Current zone" are always offered regardless.
local function collectZoneTree()
    local tree = {}
    if not (C_Map and C_Map.GetMapChildrenInfo) then return tree end
    local root = rootMapID()
    if not root then return tree end

    local ok, continents = pcall(C_Map.GetMapChildrenInfo, root, MAPTYPE_CONTINENT, true)
    if not ok or type(continents) ~= "table" then return tree end

    for _, cont in ipairs(continents) do
        local zones = zoneListFrom(cont.mapID)
        if #zones > 0 then
            table.insert(tree, { name = cont.name or "?", zones = zones,
                chunks = chunkZones(zones) })
        end
    end
    table.sort(tree, function(a, b) return a.name < b.name end)
    return tree
end

-- Flat fallback for a client that reports zones but no continents.
local function collectZones()
    if not (C_Map and C_Map.GetMapChildrenInfo) then return {} end
    local root = rootMapID()
    if not root then return {} end
    return zoneListFrom(root)
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
    f:SetSize(390, 472)
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

    makeLabel(f, "Zone", 20, -178)
    local dd = CreateFrame("Frame", "DeedkeeperZoneDropDown", f,
        "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", 104, -172)
    f.zoneDrop = dd
    f.zoneChoice = nil -- nil = any zone; otherwise { zone, zoneID }

    local function chooseZone(choice, label)
        f.zoneChoice = choice
        UIDropDownMenu_SetText(dd, label)
        CloseDropDownMenus()
    end

    UIDropDownMenu_Initialize(dd, function(_, level, menuList)
        level = level or 1

        if level == 1 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = ANY_ZONE
            info.notCheckable = true
            info.func = function() chooseZone(nil, ANY_ZONE) end
            UIDropDownMenu_AddButton(info, level)

            local here, hereID = currentZone()
            if here then
                info = UIDropDownMenu_CreateInfo()
                info.text = ("Current zone \226\128\148 %s"):format(here)
                info.notCheckable = true
                -- Resolved now rather than at save time, so the deed means the
                -- zone you picked it in, not wherever you are when you Save.
                info.func = function()
                    chooseZone({ zone = here, zoneID = hereID }, here)
                end
                UIDropDownMenu_AddButton(info, level)
            end

            -- One submenu per continent, so no single list can outgrow the
            -- screen the way a flat ~80-entry list does.
            for _, cont in ipairs(f.zoneTree or {}) do
                info = UIDropDownMenu_CreateInfo()
                info.text = cont.name
                info.notCheckable = true
                info.hasArrow = true
                info.keepShownOnClick = true
                info.menuList = cont
                UIDropDownMenu_AddButton(info, level)
            end

            -- Only reached on a client that reports zones but no continents.
            -- Chunked the same way, since a flat list is the longest of all.
            local flat = f.zoneFallback
            if flat and flat.chunks then
                for _, chunk in ipairs(flat.chunks) do
                    info = UIDropDownMenu_CreateInfo()
                    info.text = chunk.label
                    info.notCheckable = true
                    info.hasArrow = true
                    info.keepShownOnClick = true
                    info.menuList = chunk
                    UIDropDownMenu_AddButton(info, level)
                end
            elseif flat then
                for _, z in ipairs(flat.zones) do
                    info = UIDropDownMenu_CreateInfo()
                    info.text = z.zone
                    info.notCheckable = true
                    info.func = function() chooseZone(z, z.zone) end
                    UIDropDownMenu_AddButton(info, level)
                end
            end

        elseif type(menuList) == "table" then
            -- A node either fans out into alphabetical chunks (a continent
            -- with too many zones to show at once) or is a leaf list of zones.
            -- Chunks are checked first: a chunked continent carries both.
            if menuList.chunks then
                for _, chunk in ipairs(menuList.chunks) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = chunk.label
                    info.notCheckable = true
                    info.hasArrow = true
                    info.keepShownOnClick = true
                    info.menuList = chunk
                    UIDropDownMenu_AddButton(info, level)
                end
            elseif menuList.zones then
                for _, z in ipairs(menuList.zones) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = z.zone
                    info.notCheckable = true
                    info.func = function() chooseZone(z, z.zone) end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end
    end)
    -- Backstop: even a single continent's list scrolls rather than overflowing.
    if UIDropDownMenu_SetMaxHeight then UIDropDownMenu_SetMaxHeight(dd, 380) end
    UIDropDownMenu_SetWidth(dd, 210)
    UIDropDownMenu_SetText(dd, ANY_ZONE)

    local zhint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    zhint:SetPoint("TOPLEFT", 122, -198)
    zhint:SetText("optional \226\128\147 only counts kills in that zone")

    makeLabel(f, "Tiers  (count \226\134\146 title)", 20, -224)
    f.tierRows = {}
    for i = 1, TIER_ROWS do
        local y = -244 - (i - 1) * 28
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
    f.zoneChoice = nil
    if f.zoneDrop then UIDropDownMenu_SetText(f.zoneDrop, ANY_ZONE) end
    for _, r in ipairs(f.tierRows) do
        r.count:SetText("")
        r.title:SetText("")
    end
end

function AuthorForm:Open()
    local f = self:GetFrame()
    -- Rebuilt per open: the zone list needs a loaded map tree, which isn't
    -- guaranteed at addon load, and "Current zone" should follow the player.
    f.zoneTree = collectZoneTree()
    -- Flat list only as a fallback, so a client reporting no continents still
    -- gets a browsable list instead of nothing.
    f.zoneFallback = nil
    if #f.zoneTree == 0 then
        local flat = collectZones()
        if #flat > 0 then
            f.zoneFallback = { zones = flat, chunks = chunkZones(flat) }
        end
    end
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

    -- A zone on its own is a legitimate deed ("500 kills in Westfall"), so it
    -- counts toward the deed matching something.
    local zc = f.zoneChoice
    if zc then
        if zc.zone then match.zone = zc.zone end
        if zc.zoneID then match.zoneID = zc.zoneID end
    end

    if not next(match) then
        ns:Print("Give the deed something to match: a 'Mob name has' value, "
            .. "NPC IDs, or a zone.")
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
    ns:Print(("Created deed: %s (%d tier%s)%s."):format(
        def.name, #tiers, #tiers == 1 and "" or "s",
        match.zone and (" in " .. match.zone) or ""))
    f:Hide()
end
