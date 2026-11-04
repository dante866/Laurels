local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- AuthorForm: in-game form for creating a new deed (tracker) without editing
-- Lua. Name + match criteria + up to N title tiers. Kept intentionally plain.
-- ---------------------------------------------------------------------------

local AuthorForm = {}
ns.AuthorForm = AuthorForm

-- Tier rows shown on a blank form, and the most "Add 1 more tier" will give.
-- The cap is a form-usability choice, not a storage one: a deed can hold any
-- number of tiers, and a published one is sent in as many messages as its
-- tiers need (see Comm:EncodeDefParts).
local TIER_ROWS = 5
local MAX_TIERS = 20
local TIER_ROW_HEIGHT = 28

-- Longest deed name and tier title, in characters. A published deed is split
-- between messages a tier at a time, so one tier must always fit in a
-- message of its own; these keep it (and the head) comfortably inside 240
-- bytes even with every character escaped.
local MAX_NAME = 48
local MAX_TITLE = 48

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

-- Built when the dropdown opens, not when the form does: the form is reached
-- from the sidebar as well as from Open(), and only Open() used to build it,
-- which left the sidebar route with nothing but "Any zone". Built once and
-- kept, since the map tree doesn't change mid-session; an empty result (map
-- data not loaded yet) is retried on the next open.
local function loadZones(f)
    if f.zoneTree and (#f.zoneTree > 0 or f.zoneFallback) then return end
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
    return ns.MainFrame:PaneFrame("author")
end

local function buildAuthorPane(f)
    AuthorForm.frame = f

    -- The pane's own header: the window title belongs to the shell now, but
    -- creating and editing still need telling apart.
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -6)
    title:SetText("New Deed")
    f.titleText = title

    -- Only shown while editing: the id can't change (progress and the rival
    -- ladder are both keyed on it), so it's stated rather than offered.
    local idText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    idText:SetPoint("TOP", 0, -24)
    idText:Hide()
    f.idText = idText

    makeLabel(f, "Name", 20, -46)
    f.nameEdit = makeEdit(f, 230)
    f.nameEdit:SetMaxLetters(MAX_NAME)
    f.nameEdit:SetPoint("TOPLEFT", 120, -42)

    -- The kind of deed. Picking one relabels the filters below (and hides
    -- the ones a kind has no use for) without clearing what's typed.
    makeLabel(f, "Event", 20, -76)
    local evDrop = CreateFrame("Frame", "LaurelsEventDropDown", f,
        "UIDropDownMenuTemplate")
    evDrop:SetPoint("TOPLEFT", 104, -70)
    f.eventDrop = evDrop
    UIDropDownMenu_Initialize(evDrop, function()
        for _, kind in ipairs(ns.Kinds.ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ns.Kinds.Get(kind).label
            info.checked = (f.kind == kind)
            info.func = function()
                AuthorForm:SetKind(kind)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(evDrop, 90)

    -- A kind's pick-one qualifier (a death's cause, a swing's weapon), from
    -- the list in its `choices`. Sits beside the Event dropdown.
    local choiceDrop = CreateFrame("Frame", "LaurelsChoiceDropDown", f,
        "UIDropDownMenuTemplate")
    choiceDrop:SetPoint("TOPLEFT", 230, -70)
    f.choiceDrop = choiceDrop
    local function currentChoices()
        local def = ns.Kinds.Get(f.kind)
        return def and def.choices
    end
    local function choose(value)
        f.choice = value
        local c = currentChoices()
        if c then UIDropDownMenu_SetText(choiceDrop, value and c.labels[value] or c.any) end
        CloseDropDownMenus()
    end
    f.choose = choose
    UIDropDownMenu_Initialize(choiceDrop, function()
        local c = currentChoices()
        if not c then return end
        local info = UIDropDownMenu_CreateInfo()
        info.text = c.any
        info.checked = (f.choice == nil)
        info.func = function() choose(nil) end
        UIDropDownMenu_AddButton(info)
        for _, value in ipairs(c.order) do
            info = UIDropDownMenu_CreateInfo()
            info.text = c.labels[value]
            info.checked = (f.choice == value)
            info.func = function() choose(value) end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(choiceDrop, 120)

    -- Emotes: which one, typed as its slash command.
    f.emoteSlash = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.emoteSlash:SetPoint("TOPLEFT", 244, -76)
    f.emoteSlash:SetText("/")
    f.emoteEdit = makeEdit(f, 90)
    f.emoteEdit:SetPoint("TOPLEFT", 256, -72)
    f.emoteHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.emoteHint:SetPoint("TOPLEFT", 352, -77)
    f.emoteHint:SetText("e.g. hug")

    f.matchLabel = makeLabel(f, "Mob name has", 20, -106)
    f.matchEdit = makeEdit(f, 230)
    f.matchEdit:SetPoint("TOPLEFT", 120, -102)

    f.idsLabel = makeLabel(f, "NPC IDs", 20, -136)
    f.npcEdit = makeEdit(f, 230)
    f.npcEdit:SetPoint("TOPLEFT", 120, -132)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 122, -152)
    hint:SetText("optional, comma-separated \226\128\147 narrows the match")
    f.idsHint = hint

    f.zoneLabel = makeLabel(f, "Zone", 20, -178)
    local dd = CreateFrame("Frame", "LaurelsZoneDropDown", f,
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
            loadZones(f)
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
    zhint:SetText(ns.Kinds.Get("kill").zoneHint)
    f.zoneHint = zhint

    makeLabel(f, "Tiers  (count, then title)", 20, -224)

    -- The tier list scrolls, so "Add 1 more tier" can keep adding rows
    -- without the form outgrowing the window. UIPanelScrollFrameTemplate has
    -- been in every client since vanilla, but templates aren't in the API
    -- dump, so a bare ScrollFrame driven by the mouse wheel is the fallback.
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", "LaurelsTierScroll", f,
        "UIPanelScrollFrameTemplate")
    if not (ok and scroll) then
        scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local v = self:GetVerticalScroll() - delta * TIER_ROW_HEIGHT
            self:SetVerticalScroll(math.max(0, math.min(v, self:GetVerticalScrollRange())))
        end)
    end
    scroll:SetPoint("TOPLEFT", 0, -240)
    scroll:SetPoint("BOTTOMRIGHT", -26, 34) -- room for the scroll bar and Save
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(350, 1)
    scroll:SetScrollChild(child)
    f.tierScroll, f.tierChild = scroll, child
    f.tierRows = {}

    local add = CreateFrame("Button", nil, child, "UIPanelButtonTemplate")
    add:SetSize(130, 22)
    add:SetText("Add 1 more tier")
    add:SetScript("OnClick", function()
        AuthorForm:ShowTiers(AuthorForm.shownTiers + 1)
        local row = f.tierRows[AuthorForm.shownTiers]
        if row then row.count:SetFocus() end
    end)
    f.addTier = add

    AuthorForm:ShowTiers(TIER_ROWS)

    local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    save:SetSize(110, 24)
    save:SetPoint("BOTTOMRIGHT", -4, 4)
    save:SetText("Save")
    save:SetScript("OnClick", function() AuthorForm:Save() end)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(110, 24)
    cancel:SetPoint("BOTTOMLEFT", 4, 4)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function()
        -- Cancelling returns to the list rather than closing the window:
        -- the form is a tab now, not a dialog over the top of everything.
        AuthorForm:Reset()
        ns.MainFrame:Select("deeds")
    end)

    AuthorForm:SetKind("kill")
end

-- Tab / Shift-Tab walk the fields in reading order, wrapping at the ends.
-- Dropdowns aren't edit boxes, so focus steps over them, and over any box
-- hidden by the current kind or beyond the tiers shown. Rebuilt whenever a
-- tier row is created, since the order has to include it.
local function rebuildTabOrder(f)
    local order = { f.nameEdit, f.emoteEdit, f.matchEdit, f.npcEdit }
    for _, r in ipairs(f.tierRows) do
        order[#order + 1] = r.count
        order[#order + 1] = r.title
    end
    for i, e in ipairs(order) do
        e:SetScript("OnTabPressed", function()
            local dir = IsShiftKeyDown() and -1 or 1
            local j = i
            for _ = 1, #order do
                j = (j - 1 + dir) % #order + 1
                if order[j]:IsShown() then order[j]:SetFocus() return end
            end
        end)
    end
end

-- Scroll the tier list just enough to show row i -- Tab into a row below
-- the fold would otherwise type into a box you can't see.
local function revealTier(f, i)
    local scroll = f.tierScroll
    scroll:UpdateScrollChildRect()
    local top = (i - 1) * TIER_ROW_HEIGHT
    local bottom = top + TIER_ROW_HEIGHT + 4
    local view = scroll:GetHeight()
    local cur = scroll:GetVerticalScroll()
    if top < cur then
        scroll:SetVerticalScroll(top)
    elseif bottom > cur + view then
        scroll:SetVerticalScroll(math.min(bottom - view, scroll:GetVerticalScrollRange()))
    end
end

local function makeTierRow(f, i)
    local y = -4 - (i - 1) * TIER_ROW_HEIGHT
    local cnt = makeEdit(f.tierChild, 70, true)
    cnt:SetPoint("TOPLEFT", 30, y)
    local ttl = makeEdit(f.tierChild, 210)
    ttl:SetMaxLetters(MAX_TITLE)
    ttl:SetPoint("TOPLEFT", 120, y)
    for _, e in ipairs({ cnt, ttl }) do
        e:HookScript("OnEditFocusGained", function() revealTier(f, i) end)
    end
    f.tierRows[i] = { count = cnt, title = ttl }
end

-- Show the first n tier rows (creating any that don't exist yet), hide the
-- rest, and park "Add 1 more tier" under the last one shown.
function AuthorForm:ShowTiers(n)
    local f = self.frame
    if not f then return end
    -- Not capped here: editing a deed that already has more tiers than the
    -- button would allow must show them all, or saving would drop the rest.
    n = math.max(1, n)
    local created = false
    for i = #f.tierRows + 1, n do
        makeTierRow(f, i)
        created = true
    end
    if created then rebuildTabOrder(f) end

    for i, r in ipairs(f.tierRows) do
        r.count:SetShown(i <= n)
        r.title:SetShown(i <= n)
    end
    self.shownTiers = n

    f.addTier:ClearAllPoints()
    f.addTier:SetPoint("TOPLEFT", 26, -4 - n * TIER_ROW_HEIGHT)
    f.addTier:SetShown(n < MAX_TIERS)
    f.tierChild:SetHeight(8 + n * TIER_ROW_HEIGHT + 26)
end

-- Back to a blank "New Deed", including the menu label, after a save or a
-- cancel -- otherwise the menu would keep claiming to be editing.
function AuthorForm:Reset()
    self.editing = nil
    ns.MainFrame:SetTabLabel("author", "New Deed")
    if self.frame then
        self.frame.titleText:SetText("New Deed")
        self.frame.idText:Hide()
        -- Blank too: the sidebar returns to this pane without Open(), and
        -- would otherwise show the last deed's values as a "New Deed".
        self:Clear()
    end
end

-- Show the controls a kind uses, relabelled for it. Typed values stay put,
-- so switching kinds back and forth loses nothing.
function AuthorForm:SetKind(kind)
    local f = self.frame
    local def = ns.Kinds.Get(kind)
    if not (f and def) then return end
    local changed = f.kind ~= kind
    f.kind = kind
    UIDropDownMenu_SetText(f.eventDrop, def.label)

    -- Unlike typed text, a picked cause means nothing as a weapon, so the
    -- pick resets when the kind changes.
    f.choiceDrop:SetShown(def.choices ~= nil)
    if changed then f.choose(nil) end
    local emote = def.qualifier == "emote"
    f.emoteSlash:SetShown(emote)
    f.emoteEdit:SetShown(emote)
    f.emoteHint:SetShown(emote)

    f.matchLabel:SetText(def.nameLabel)
    local ids = def.idsLabel ~= nil
    f.idsLabel:SetShown(ids)
    f.npcEdit:SetShown(ids)
    f.idsHint:SetShown(ids)
    if ids then f.idsLabel:SetText(def.idsLabel) end

    -- Kinds with no "where" (titles held) hide the zone row entirely.
    local zone = not def.noZone
    f.zoneLabel:SetShown(zone)
    f.zoneDrop:SetShown(zone)
    f.zoneHint:SetShown(zone)
    f.zoneHint:SetText(def.zoneHint or "")
end

function AuthorForm:Clear()
    local f = self.frame
    if not f then return end
    f.nameEdit:SetText("")
    f.matchEdit:SetText("")
    f.npcEdit:SetText("")
    f.emoteEdit:SetText("")
    f.choose(nil)
    self:SetKind("kill")
    f.zoneChoice = nil
    if f.zoneDrop then UIDropDownMenu_SetText(f.zoneDrop, ANY_ZONE) end
    for _, r in ipairs(f.tierRows) do
        r.count:SetText("")
        r.title:SetText("")
    end
    self:ShowTiers(TIER_ROWS)
    f.tierScroll:SetVerticalScroll(0)
end

-- Fill the form from an existing deed so editing starts from what's there.
function AuthorForm:Load(t)
    local f = self.frame
    f.nameEdit:SetText(t.name or "")

    local m = t.match or {}
    self:SetKind(t.event or "kill")
    f.matchEdit:SetText(m.nameContains or "")
    local ids = ns.Kinds.IDs(m)
    f.npcEdit:SetText(ids and table.concat(ids, ", ") or "")
    local def = ns.Kinds.Get(t.event or "kill")
    f.choose(def and def.choices and m[def.qualifier] or nil)
    f.emoteEdit:SetText(m.emote and string.lower(m.emote) or "")

    if m.zone or m.zoneID then
        f.zoneChoice = { zone = m.zone, zoneID = m.zoneID }
        UIDropDownMenu_SetText(f.zoneDrop, m.zone or ("map " .. tostring(m.zoneID)))
    end

    self:ShowTiers(math.max(TIER_ROWS, t.tiers and #t.tiers or 0))
    for i, r in ipairs(f.tierRows) do
        local tier = t.tiers and t.tiers[i]
        if tier then
            r.count:SetText(tostring(tier.count or ""))
            r.title:SetText(tier.title or "")
        end
    end
end

-- Open blank to author a deed, or pass an id to edit that one in place.
function AuthorForm:Open(trackerId)
    local f = self:GetFrame()
    self:Clear()

    local existing = trackerId and ns.Engine:GetTracker(trackerId)
    if trackerId and not existing then
        ns:Print("no deed with id:", trackerId)
        return
    end

    self.editing = existing and existing.id or nil
    if existing then
        f.titleText:SetText("Edit Deed")
        f.idText:SetText(("id: %s \226\128\148 progress is kept"):format(existing.id))
        f.idText:Show()
        ns.MainFrame:SetTabLabel("author", "Edit Deed")
        self:Load(existing)
    else
        f.titleText:SetText("New Deed")
        f.idText:Hide()
        ns.MainFrame:SetTabLabel("author", "New Deed")
    end

    ns.MainFrame:Show("author")
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

    local kind = f.kind or "kill"
    local def = ns.Kinds.Get(kind)

    -- Only the fields this kind shows are read: a value typed under another
    -- kind and then hidden by switching mustn't quietly narrow the deed.
    local match = {}
    local nameContains = trim(f.matchEdit:GetText())
    if nameContains ~= "" then match.nameContains = nameContains end
    if def.idsLabel then
        local ids = parseNpcIDs(f.npcEdit:GetText())
        if ids then match[def.idsKey or "ids"] = ids end
    end
    if def.choices and f.choice then
        match[def.qualifier] = f.choice
    elseif def.qualifier == "emote" then
        local token = ns.EmoteSource.ResolveToken(f.emoteEdit:GetText())
        if token then match.emote = token end
    end

    -- A zone on its own is a legitimate deed ("500 kills in Westfall"), so it
    -- counts toward the deed matching something.
    local zc = (not def.noZone) and f.zoneChoice
    if zc then
        if zc.zone then match.zone = zc.zone end
        if zc.zoneID then match.zoneID = zc.zoneID end
    end

    -- Most kinds are fine unfiltered ("die 100 times"); kills and casts
    -- would count everything.
    if def.needsFilter and not next(match) then
        ns:Print(("Give the deed something to match: a '%s' value, %s, or a zone.")
            :format(def.nameLabel, def.idsLabel or "ids"))
        return
    end

    local tiers = {}
    for i = 1, self.shownTiers do
        local r = f.tierRows[i]
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

    if self.editing then
        local t = ns.Engine:UpdateTracker(self.editing,
            { name = name, event = kind, match = match, tiers = tiers })
        if not t then
            ns:Print("that deed no longer exists \226\128\148 nothing saved.")
        else
            ns:Print(("Updated deed: |cffffd100%s|r (%d tier%s)%s. "
                .. "Progress kept."):format(
                ns.Comm.Escape(t.name), #tiers, #tiers == 1 and "" or "s",
                match.zone and (" in " .. match.zone) or ""))
            -- Sent now rather than at the next HELLO, so rivals who accepted
            -- it are offered the change straight away. Only deeds we
            -- published are ours to resend; an accepted one stays the
            -- author's (its edit is local, and they'd ignore ours anyway).
            if t.published and not ns.Rival:TrackerAuthor(t) then
                ns.Rival:BroadcastDef(t)
                ns:Print("  |cffff8800It's published|r \226\128\148 sent; rivals who accepted "
                    .. "it are offered the change as an update.")
            elseif t.published then
                ns:Print("  You accepted this deed from its author, so this edit "
                    .. "is only yours. Rivals keep the author's version.")
            end
        end
        self:Reset()
        ns.MainFrame:Select("deeds")
        return
    end

    local created = ns.Engine:CreateTracker({
        name = name,
        event = kind,
        match = match,
        tiers = tiers,
    })
    ns:Print(("Created deed: |cffffd100%s|r (%d tier%s)%s."):format(
        ns.Comm.Escape(created.name), #tiers, #tiers == 1 and "" or "s",
        match.zone and (" in " .. match.zone) or ""))
    -- Surface the id here: it is what every other command takes, and the
    -- obvious next step after authoring a deed is publishing it.
    ns:Print(("  id |cffffd100%s|r \226\128\148 publish it with |cff66ccff/deed publish %s|r")
        :format(created.id, created.id))
    -- Straight back to the list, where the new deed now appears.
    self:Reset()
    ns.MainFrame:Select("deeds")
end

ns.MainFrame:RegisterPane("author", "New Deed", buildAuthorPane)
