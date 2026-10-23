local addonName, ns = ...

ns.name = addonName
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMeta and GetMeta(addonName, "Version")) or "0.1.0"

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end
ns.deepcopy = deepcopy

-- Run fn after `delay` seconds. C_Timer is 6.0+; fall back to an OnUpdate
-- ticker so this still works on clients that predate it. Returns nothing.
function ns.After(delay, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
        return
    end
    if not CreateFrame then return end
    local f = CreateFrame("Frame")
    local elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            fn()
        end
    end)
end

function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    local frame = DEFAULT_CHAT_FRAME
    if frame then
        frame:AddMessage("|cff66ccffDeedkeeper|r: " .. table.concat(parts, " "))
    end
end

-- ---------------------------------------------------------------------------
-- Default definitions (account-wide, created on first ever load)
-- ---------------------------------------------------------------------------

local DEFAULT_TRACKERS = {
    {
        id = "kobolds",
        name = "Kobold Slaying",
        event = "kill",
        match = { nameContains = "Kobold" },
        tiers = {
            { count = 1000,  title = "Kobold Slayer" },
            { count = 10000, title = "Kobold Destroyer" },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function initDB()
    DeedkeeperDB = DeedkeeperDB or {}
    DeedkeeperDB.trackers = DeedkeeperDB.trackers or deepcopy(DEFAULT_TRACKERS)

    DeedkeeperCharDB = DeedkeeperCharDB or {}
    DeedkeeperCharDB.progress = DeedkeeperCharDB.progress or {}  -- trackerId -> count
    DeedkeeperCharDB.earned   = DeedkeeperCharDB.earned   or {}  -- trackerId -> highest tier index earned

    ns.db = DeedkeeperDB
    ns.charDB = DeedkeeperCharDB
end

-- Shown once per account. A new player arrives with the sample Kobold deed
-- already tracking and no indication that authoring their own is the point of
-- the addon, so say so plainly rather than shipping a catalogue of premades.
local function showIntro()
    ns:Print("|cffffd100First time?|r A sample deed is already running: "
        .. "|cffffffffKobold Slaying|r.")
    ns:Print("  A deed is |cffffffffsomething to count|r plus the "
        .. "|cfffffffftitles|r you earn for it.")
    ns:Print("  e.g. count kills matching \"Murloc\" \226\134\146 "
        .. "|cffffd100Murloc Menace|r at 500, |cffffd100Murloc Bane|r at 5000.")
    ns:Print("  Make your own with |cff66ccff/deed new|r. "
        .. "See a worked example with |cff66ccff/deed help|r.")
end

local function initModules()
    ns.Engine:Init()
    ns.Engine:RegisterSource("kill", ns.KillSource)
    if ns.UI and ns.UI.Init then ns.UI:Init() end
    if ns.Rival and ns.Rival.Init then ns.Rival:Init() end
    ns:Print(("v%s loaded. /deed to open the panel, /deed help for commands.")
        :format(ns.version))
    if not ns.db.seenIntro then
        ns.db.seenIntro = true
        showIntro()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        initDB()
    elseif event == "PLAYER_LOGIN" then
        initModules()
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_DEEDKEEPER1 = "/deed"
SLASH_DEEDKEEPER2 = "/deedkeeper"
SlashCmdList.DEEDKEEPER = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        if ns.UI then ns.UI:Toggle() end

    elseif cmd == "new" then
        if ns.AuthorForm then ns.AuthorForm:Open() end

    elseif cmd == "delete" then
        if rest ~= "" then
            ns.Engine:DeleteTracker(rest)
            ns:Print("deleted tracker:", rest)
        else
            ns:Print("usage: /deed delete <trackerId>")
        end

    elseif cmd == "publish" then
        local t = ns.Engine:GetTracker(rest)
        if not t then
            ns:Print("no tracker with id:", rest ~= "" and rest or "(none given)")
        else
            t.published = true
            t.uuid = t.uuid or ns.genUUID()
            t.origin = t.origin or ns.Rival:MyName()
            ns:Print(("published '%s' (shared id %s). Nearby addon users can now contest it.")
                :format(t.name, t.uuid))
            ns.Rival:ForceBroadcast(t)
        end

    elseif cmd == "unpublish" then
        local t = ns.Engine:GetTracker(rest)
        if t then
            t.published = false
            ns:Print("unpublished:", t.name)
        else
            ns:Print("no tracker with id:", rest ~= "" and rest or "(none given)")
        end

    elseif cmd == "whoami" then
        if ns.Diag then ns.Diag:WhoAmI() end

    elseif cmd == "commtest" then
        if ns.Diag then ns.Diag:CommTest() end

    elseif cmd == "rivals" then
        local t = ns.Engine:GetTracker(rest)
        if not t then
            ns:Print("usage: /deed rivals <trackerId>")
        else
            local standings = ns.Ladder:GetStandings(ns.Rival:KeyFor(t))
            if #standings == 0 then
                ns:Print("no claims heard yet for:", t.name)
            else
                ns:Print(("Rivals for %s:"):format(t.name))
                for i, e in ipairs(standings) do
                    ns:Print(("  %d. %s \226\128\148 %d%s"):format(
                        i, e.name, e.count, (i == 1) and "  (holder)" or ""))
                end
            end
        end

    elseif cmd == "list" then
        ns:Print("Trackers:")
        for _, t in ipairs(ns.db.trackers) do
            local title = ns.Engine:CurrentTitle(t)
            ns:Print(("  [%s] %s = %d  %s"):format(
                t.id, t.name, ns.Engine:GetProgress(t.id),
                title and ("<" .. title .. ">") or ""))
        end

    elseif cmd == "reset" then
        if rest ~= "" then
            ns.Engine:ResetProgress(rest)
            ns:Print("reset progress for:", rest)
        else
            ns:Print("usage: /deed reset <trackerId>")
        end

    elseif cmd == "test" then
        -- Simulate kills without needing mobs:  /deed test 1000 Kobold
        -- A zone-scoped deed would never match a zoneless signal, so the
        -- synthetic kill carries the zone you are standing in. Append "@Zone"
        -- to pretend otherwise:  /deed test 25 Dust Devil @Westfall
        local zoneOverride
        local body = rest:gsub("%s*@(.+)$", function(z)
            zoneOverride = (z:gsub("^%s+", ""):gsub("%s+$", ""))
            return ""
        end)

        local n, name = body:match("^(%d+)%s+(.+)$")
        if n then
            n = tonumber(n)
        else
            n = 1
            name = (body ~= "" and body) or "Kobold Vermin"
        end

        local zone, zoneID
        if zoneOverride then
            zone = zoneOverride
        else
            zone = GetZoneText and GetZoneText()
            if zone == "" then zone = nil end
            if C_Map and C_Map.GetBestMapForUnit then
                zoneID = C_Map.GetBestMapForUnit("player")
            end
        end

        for _ = 1, n do
            ns.Engine:ReportProgress({ kind = "kill", name = name,
                zone = zone, zoneID = zoneID })
        end
        ns:Print(("simulated %d kill(s): %s in %s"):format(
            n, name, zone or "an unknown zone"))

    elseif cmd == "help" then
        ns:Print("commands:")
        ns:Print("  /deed                 toggle the panel")
        ns:Print("  /deed new             open the create-a-deed form")
        ns:Print("  /deed list            list trackers + progress")
        ns:Print("  /deed delete <id>     delete a tracker")
        ns:Print("  /deed reset <id>      reset a tracker's progress")
        ns:Print("  /deed publish <id>    publish a deed so others can contest it")
        ns:Print("  /deed unpublish <id>  stop broadcasting a deed")
        ns:Print("  /deed rivals <id>     show the leaderboard for a deed")
        ns:Print("  /deed whoami          dump name/GUID identity info (diagnostic)")
        ns:Print("  /deed commtest        test whether addon messages work (diagnostic)")
        ns:Print("  /deed test <n> <name> simulate n kills of <name> (for testing)")
        ns:Print(" ")
        ns:Print("|cffffd100Making a deed|r \226\128\148 two things: what to count, and the")
        ns:Print("titles it earns. Open |cff66ccff/deed new|r and fill in:")
        ns:Print("  |cffffffffName|r    Murloc Hunting")
        ns:Print("  |cffffffffMatch|r   name contains \"Murloc\"  (or specific NPC IDs)")
        ns:Print("  |cffffffffTiers|r   Murloc Menace at 500, Murloc Bane at 5000")
        ns:Print("Then every matching kill counts, and the title is yours at 500.")
        ns:Print("Try it without farming: |cff66ccff/deed test 500 Murloc|r")
        ns:Print("Want others to compete for it? |cff66ccff/deed publish <id>|r")

    else
        ns:Print("unknown command. try /deed help")
    end
end
