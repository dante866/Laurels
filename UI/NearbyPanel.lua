local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- NearbyPanel: challenges other players have published nearby, and newer
-- versions of ones you've accepted.
--
-- This is the front end for M4. Before it, contesting someone's deed meant
-- being told a uuid out of band and typing it into /deed adopt. Accepting
-- here builds the deed from the author's own definition, so both sides count
-- the same mobs against the same thresholds instead of hoping they agree.
--
-- Nothing reaches your deeds without a click. Each row opens a preview of
-- the whole deed, and the preview is where you Accept or Decline it. An
-- author's later edits to a deed you've accepted show up here as an update
-- to preview, never as a silent change.
-- ---------------------------------------------------------------------------

local Nearby = {}
ns.Nearby = Nearby

local ROWS = 6

local function esc(s) return ns.Comm.Escape(s) end

local function describe(d)
    return ns.Kinds.Describe(d.event, d.match)
end

local function tierLine(i, tier)
    return ("  %d. %s at %d"):format(i, esc(tier.title) or "?", tier.count or 0)
end

-- The list's hover tooltip: a glance, while Preview is the full read.
local function showTooltip(row)
    local item = row.item
    if not item then return end
    local d = item.deed
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(esc(d.name) or "?", 1, 1, 1)
    if d.origin then
        GameTooltip:AddLine(("published by %s"):format(esc(d.origin)), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Counts: %s"):format(esc(describe(d))), 0.9, 0.9, 0.9)
    for i, tier in ipairs(d.tiers or {}) do
        GameTooltip:AddLine(tierLine(i, tier), 1, 0.82, 0)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Preview to accept or decline it.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function Nearby:GetFrame()
    return ns.MainFrame:PaneFrame("nearby")
end

-- Everything waiting: updates to accepted deeds first (they're about deeds
-- you already care about), then new offers.
function Nearby:Items()
    local items = {}
    for _, u in ipairs(ns.Rival:PendingUpdates()) do
        items[#items + 1] = { kind = "update", uuid = u.deed.uuid, deed = u.deed,
                              tracker = u.tracker }
    end
    for _, d in ipairs(ns.Rival:NearbyDeeds()) do
        items[#items + 1] = { kind = "offer", uuid = d.uuid, deed = d }
    end
    return items
end

local function buildDetail(f)
    local v = CreateFrame("Frame", nil, f)
    v:SetAllPoints()
    v:Hide()

    v.title = v:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    v.title:SetPoint("TOPLEFT", 4, -4)
    v.title:SetWidth(398)
    v.title:SetJustifyH("LEFT")

    v.byline = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v.byline:SetPoint("TOPLEFT", v.title, "BOTTOMLEFT", 0, -4)
    v.byline:SetWidth(398)
    v.byline:SetJustifyH("LEFT")

    v.body = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
    v.body:SetPoint("TOPLEFT", v.byline, "BOTTOMLEFT", 0, -12)
    v.body:SetWidth(398)
    v.body:SetJustifyH("LEFT")
    v.body:SetJustifyV("TOP")

    local function button(label, point, x)
        local b = CreateFrame("Button", nil, v, "UIPanelButtonTemplate")
        b:SetSize(120, 24)
        b:SetPoint(point, x, 4)
        b:SetText(label)
        return b
    end
    v.back    = button("Back", "BOTTOMLEFT", 4)
    v.decline = button("Decline", "BOTTOM", 0)
    v.accept  = button("Accept", "BOTTOMRIGHT", -4)
    v.back:SetScript("OnClick", function() Nearby:ClosePreview() end)

    -- While a deed is still arriving: why Accept is greyed out, and how long
    -- for. Sits just above the buttons.
    v.note = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v.note:SetPoint("BOTTOMLEFT", 4, 34)
    v.note:SetPoint("BOTTOMRIGHT", -132, 34)
    v.note:SetJustifyH("LEFT")
    v.note:Hide()

    -- Shown only when a part seems lost: asks the author to send it all again.
    v.ask = CreateFrame("Button", nil, v, "UIPanelButtonTemplate")
    v.ask:SetSize(120, 22)
    v.ask:SetPoint("BOTTOMRIGHT", -4, 32)
    v.ask:SetText("Ask Again")
    v.ask:SetScript("OnClick", function() Nearby:AskAgain() end)
    v.ask:Hide()

    f.detail = v
end

-- A HELLO prompts every client in range to resend what it publishes, which
-- is also how a late arrival -- or a lost follow-up -- catches up.
function Nearby:AskAgain()
    ns.Comm:Send({ type = "HELLO", ver = ns.version,
        name = ns.Rival:MyName(), guid = ns.Rival:MyGuid() })
    ns:Print("asked nearby players to resend their published deeds\226\128\166")
end

-- While a preview shows a deed still arriving, re-render it every second so
-- the wait counts down and a stall shows up. One timer at a time.
function Nearby:TickWhileArriving()
    if self.ticking or not ns.After then return end
    self.ticking = true
    ns.After(1, function()
        self.ticking = false
        if self.previewing and self.frame and self.frame:IsShown() then
            self:Refresh()
        end
    end)
end

local function buildNearbyPane(f)
    Nearby.frame = f

    local list = CreateFrame("Frame", nil, f)
    list:SetAllPoints()
    f.list = list

    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    empty:SetPoint("CENTER", 0, 10)
    empty:SetText("Nothing heard yet.\n\n|cff999999Deeds appear when someone\n"
        .. "nearby publishes one.|r")
    f.empty = empty

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, list)
        row:SetSize(398, 32)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 36)
        row:EnableMouse(true)
        row:SetScript("OnEnter", showTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        row.text:SetPoint("TOPLEFT", 0, 0)
        row.text:SetWidth(310)
        row.text:SetJustifyH("LEFT")

        row.preview = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.preview:SetSize(72, 22)
        row.preview:SetPoint("TOPRIGHT", 0, 0)
        row.preview:SetText("Preview")

        row:Hide()
        f.rows[i] = row
    end

    local refresh = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
    refresh:SetSize(110, 24)
    refresh:SetPoint("BOTTOMLEFT", 4, 4)
    refresh:SetText("Ask Again")
    refresh:SetScript("OnClick", function() Nearby:AskAgain() end)

    buildDetail(f)
end

function Nearby:Preview(uuid)
    self.previewing = uuid
    self:Refresh()
end

function Nearby:ClosePreview()
    self.previewing = nil
    self:Refresh()
end

-- After Accept / Decline: back to the list, with every count refreshed.
local function done()
    Nearby:ClosePreview()
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    if ns.UI and ns.UI.RefreshNearby then ns.UI:RefreshNearby() end
end

function Nearby:ShowDetail(item)
    local v = self.frame.detail
    local d = item.deed
    local lines = {}
    -- Updates are only ever stored whole, so only an offer can be arriving.
    local arrival = item.kind == "offer" and ns.Rival:Arrival(d) or nil

    if item.kind == "update" then
        v.title:SetText("Update: " .. (esc(d.name) or "?"))
        v.byline:SetText(("from %s, for a deed you've accepted"):format(
            esc(d.origin) or "its author"))
        lines[#lines + 1] = "|cffffd100What changes|r"
        for _, l in ipairs(ns.Rival:DescribeChanges(item.tracker, d)) do
            lines[#lines + 1] = "  " .. esc(l)
        end
        lines[#lines + 1] = " "
        lines[#lines + 1] = "|cff999999Accepting replaces your copy's name, filters"
        lines[#lines + 1] = "and tiers with the author's. Your progress is kept.|r"
        v.accept:SetText("Accept Update")
        v.decline:SetText("Keep Mine")
        v.accept:SetScript("OnClick", function()
            local t, why = ns.Rival:AcceptUpdate(item.uuid)
            if t then
                ns:Print(("Updated |cffffd100%s|r to the author's version."):format(esc(t.name)))
            else
                ns:Print("couldn't apply that:", why)
            end
            done()
        end)
        v.decline:SetScript("OnClick", function()
            ns.Rival:IgnoreUpdate(item.uuid)
            ns:Print("Kept your version. You'll be offered the author's next change.")
            done()
        end)
    else
        v.title:SetText(esc(d.name) or "?")
        v.byline:SetText(("published by %s"):format(esc(d.origin) or "someone"))
        lines[#lines + 1] = "|cffffd100Counts|r  " .. esc(describe(d))
        lines[#lines + 1] = " "
        lines[#lines + 1] = "|cffffd100Tiers|r"
        for i = 1, d.tierTotal or #(d.tiers or {}) do
            local tier = d.tiers and d.tiers[i]
            lines[#lines + 1] = tier and tierLine(i, tier)
                or ("  %d. |cff808080(still arriving)|r"):format(i)
        end
        lines[#lines + 1] = " "
        lines[#lines + 1] = "|cff999999Accept copies this deed exactly, so you and the"
        lines[#lines + 1] = "author count the same thing. Decline hides it for good.|r"
        v.accept:SetText("Accept")
        v.decline:SetText("Decline")
        v.accept:SetScript("OnClick", function()
            local t, why = ns.Rival:Adopt(item.uuid)
            if not t then
                ns:Print("couldn't accept that:", why)
            else
                ns:Print(("Accepted |cffffd100%s|r \226\128\148 now contesting it. "
                    .. "See the ladder with |cff66ccff/deed rivals %s|r")
                    :format(esc(t.name), t.id))
            end
            done()
        end)
        v.decline:SetScript("OnClick", function()
            ns.Rival:Decline(item.uuid)
            ns:Print(("Declined |cffffd100%s|r. |cff66ccff/deed undecline|r "
                .. "brings back everything you've declined."):format(esc(d.name) or "?"))
            done()
        end)
    end

    -- A deed still arriving can't be accepted: you'd be contesting
    -- thresholds you never saw. Decline still works.
    if arrival then
        v.accept:Disable()
        if arrival.stalled then
            v.note:SetText(("|cffff8800%d of its %d tiers haven't arrived.|r A message "
                .. "was probably lost; Ask Again requests the deed again.")
                :format(arrival.missing, arrival.total))
            v.ask:Show()
        else
            v.note:SetText(("|cffffd100Receiving tiers: %d of %d|r, about %d second%s. "
                .. "Accept unlocks when they're all here.")
                :format(arrival.received, arrival.total, arrival.seconds,
                    arrival.seconds == 1 and "" or "s"))
            v.ask:Hide()
        end
        v.note:Show()
        self:TickWhileArriving()
    else
        v.accept:Enable()
        v.note:Hide()
        v.ask:Hide()
    end

    v.body:SetText(table.concat(lines, "\n"))
    self.frame.list:Hide()
    v:Show()
end

function Nearby:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    local f = self.frame
    local items = self:Items()

    -- Still previewing something that's still there? Show it; it may have
    -- been accepted from elsewhere, or a newer update replaced it.
    if self.previewing then
        for _, item in ipairs(items) do
            if item.uuid == self.previewing then
                self:ShowDetail(item)
                return
            end
        end
        self.previewing = nil
    end
    f.detail:Hide()
    f.list:Show()

    for i, row in ipairs(f.rows) do
        local item = items[i]
        if item then
            local d = item.deed
            row.item = item
            local tiers = d.tierTotal or (d.tiers and #d.tiers) or 0
            local arrival = item.kind == "offer" and ns.Rival:Arrival(d)
            if item.kind == "update" then
                local n = #ns.Rival:DescribeChanges(item.tracker, d)
                row.text:SetText(("|cffffd100Update:|r %s\n|cff999999   by %s \226\128\148 %d change%s|r")
                    :format(esc(d.name) or "?", esc(d.origin) or "its author",
                        n, n == 1 and "" or "s"))
            else
                -- Deed name and author arrive over the wire as free text.
                local status = arrival
                    and (arrival.stalled and ("  |cffff8800(%d of %d tiers, stalled)|r")
                        or ("  |cffffd100(receiving %d of %d)|r"))
                        :format(arrival.received, arrival.total)
                    or ""
                row.text:SetText(("%s\n|cff999999   by %s \226\128\148 %d tier%s|r%s"):format(
                    esc(d.name) or "?", esc(d.origin) or "someone",
                    tiers, tiers == 1 and "" or "s", status))
            end
            local uuid = item.uuid
            row.preview:SetScript("OnClick", function() Nearby:Preview(uuid) end)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end

    if #items > ROWS then
        ns:Print(("(%d more nearby deeds than fit \226\128\148 accept or decline some "
            .. "to see the rest)"):format(#items - ROWS))
    end
    if #items == 0 then f.empty:Show() else f.empty:Hide() end
end

function Nearby:Toggle()
    ns.MainFrame:Toggle("nearby")
end

ns.MainFrame:RegisterPane("nearby", "Nearby", buildNearbyPane)
ns.MainFrame:GetPane("nearby").OnShow = function()
    Nearby:Refresh()
    -- Ask on open so the list is current rather than whatever we happened to
    -- overhear earlier.
    ns.Comm:Send({ type = "HELLO", ver = ns.version,
        name = ns.Rival:MyName(), guid = ns.Rival:MyGuid() })
end
