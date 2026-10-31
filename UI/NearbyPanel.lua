local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- NearbyPanel: challenges other players have published nearby, each with an
-- Accept button.
--
-- This is the front end for M4. Before it, contesting someone's deed meant
-- being told a uuid out of band and typing it into /deed adopt. Accepting
-- here builds the deed from the author's own definition, so both sides count
-- the same mobs against the same thresholds instead of hoping they agree.
-- ---------------------------------------------------------------------------

local Nearby = {}
ns.Nearby = Nearby

local ROWS = 6

local function describe(d)
    local m = d.match or {}
    local parts = {}
    if m.nameContains then
        parts[#parts + 1] = ('name has "%s"'):format(m.nameContains)
    end
    if m.npcIDs and #m.npcIDs > 0 then
        parts[#parts + 1] = ("%d NPC ID%s"):format(
            #m.npcIDs, #m.npcIDs == 1 and "" or "s")
    end
    if m.zone then parts[#parts + 1] = "in " .. m.zone end
    return (#parts > 0) and table.concat(parts, ", ") or "anything"
end

local function showTooltip(row)
    local d = row.deed
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.name or "?", 1, 1, 1)
    if d.origin then
        GameTooltip:AddLine(("published by %s"):format(d.origin), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Counts: %s"):format(describe(d)), 0.9, 0.9, 0.9)
    for i, tier in ipairs(d.tiers or {}) do
        GameTooltip:AddLine(("  %d. %s at %d"):format(i, tier.title, tier.count),
            1, 0.82, 0)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Accept copies this deed exactly, so you and the",
        0.6, 0.6, 0.6)
    GameTooltip:AddLine("author are counting the same thing.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function Nearby:GetFrame()
    return ns.MainFrame:PaneFrame("nearby")
end

local function buildNearbyPane(f)
    Nearby.frame = f

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    empty:SetPoint("CENTER", 0, 10)
    empty:SetText("Nothing heard yet.\n\n|cff999999Deeds appear when someone\n"
        .. "nearby publishes one.|r")
    f.empty = empty

    f.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(398, 32)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 36)
        row:EnableMouse(true)
        row:SetScript("OnEnter", showTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        row.text:SetPoint("TOPLEFT", 0, 0)
        row.text:SetWidth(310)
        row.text:SetJustifyH("LEFT")

        row.accept = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.accept:SetSize(72, 22)
        row.accept:SetPoint("TOPRIGHT", 0, 0)
        row.accept:SetText("Accept")

        row:Hide()
        f.rows[i] = row
    end

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(110, 24)
    refresh:SetPoint("BOTTOMLEFT", 4, 4)
    refresh:SetText("Ask Again")
    refresh:SetScript("OnClick", function()
        -- A HELLO prompts every client in range to resend what it publishes,
        -- which is also how a late arrival catches up.
        ns.Comm:Send({ type = "HELLO", ver = ns.version,
            name = ns.Rival:MyName(), guid = ns.Rival:MyGuid() })
        ns:Print("asked nearby players to resend their published deeds\226\128\166")
    end)
end

function Nearby:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    local f = self.frame
    local list = ns.Rival:NearbyDeeds()

    for i, row in ipairs(f.rows) do
        local d = list[i]
        if d then
            row.deed = d
            local tiers = d.tiers and #d.tiers or 0
            -- Deed name and author arrive over the wire as free text.
            row.text:SetText(("%s\n|cff999999   by %s \226\128\148 %d tier%s|r"):format(
                ns.Comm.Escape(d.name) or "?",
                ns.Comm.Escape(d.origin) or "someone",
                tiers, tiers == 1 and "" or "s"))
            local uuid = d.uuid
            row.accept:SetScript("OnClick", function()
                local t, why = ns.Rival:Adopt(uuid)
                if not t then
                    ns:Print("couldn't accept that:", why)
                else
                    ns:Print(("Accepted |cffffd100%s|r \226\128\148 now contesting it. "
                        .. "See the ladder with |cff66ccff/deed rivals %s|r")
                        :format(t.name, t.id))
                end
                Nearby:Refresh()
                if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
            end)
            row:Show()
        else
            row.deed = nil
            row:Hide()
        end
    end

    if #list > ROWS then
        ns:Print(("(%d more nearby deeds than fit \226\128\148 accept some to see the rest)")
            :format(#list - ROWS))
    end
    if f.empty then
        if #list == 0 then f.empty:Show() else f.empty:Hide() end
    end
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
