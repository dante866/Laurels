local addonName, ns = ...

ns.name = addonName
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMeta and GetMeta(addonName, "Version")) or "0.1.0"

-- Which chat type carries addon messages differs per client, and each .toc is
-- already client-specific, so it declares its own default rather than the
-- addon sniffing at runtime. Validated and applied in Comm:BroadcastChannel.
ns.tocChannel = GetMeta and GetMeta(addonName, "X-BroadcastChannel")

-- Likewise whether addons may read the combat log. Where they can't, even
-- registering for it raises the game's "blocked from an action" popup, so
-- the sources must know before they register, not find out by trying.
ns.combatLogClosed = GetMeta and GetMeta(addonName, "X-CombatLog") == "closed"

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
        frame:AddMessage("|cff66ccffLaurels|r: " .. table.concat(parts, " "))
    end
end

-- The game's "blocked from an action" popup doesn't name the action, but
-- these two events do. Registered first thing so a block during loading is
-- caught too.
if CreateFrame then
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    watch:RegisterEvent("ADDON_ACTION_BLOCKED")
    watch:SetScript("OnEvent", function(_, event, who, fn)
        if who ~= addonName then return end
        ns:Print(("|cffff6060%s|r: the game stopped Laurels calling %s"):format(
            event == "ADDON_ACTION_FORBIDDEN" and "Forbidden" or "Blocked", tostring(fn)))
    end)
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
    LaurelsDB = LaurelsDB or {}
    LaurelsDB.trackers = LaurelsDB.trackers or deepcopy(DEFAULT_TRACKERS)
    -- Deeds heard published by others but not adopted. Offers, not trackers.
    LaurelsDB.known = LaurelsDB.known or {}

    LaurelsCharDB = LaurelsCharDB or {}
    LaurelsCharDB.progress = LaurelsCharDB.progress or {}  -- trackerId -> count
    LaurelsCharDB.earned   = LaurelsCharDB.earned   or {}  -- trackerId -> highest tier index earned

    ns.db = LaurelsDB
    ns.charDB = LaurelsCharDB
end

-- Shown once per account. A new player arrives with the sample Kobold deed
-- already tracking and no indication that authoring their own is the point of
-- the addon, so say so plainly rather than shipping a catalogue of premades.
local function showIntro()
    ns:Print("|cffffd100First time?|r A sample deed is already running: "
        .. "|cffffffffKobold Slaying|r.")
    ns:Print("  A deed is |cffffffffsomething to count|r plus the "
        .. "|cfffffffftitles|r you earn for it.")
    ns:Print("  e.g. count kills matching \"Murloc\": "
        .. "|cffffd100Murloc Menace|r at 500, |cffffd100Murloc Bane|r at 5000.")
    ns:Print("  Make your own with |cff66ccff/deed new|r. "
        .. "See a worked example with |cff66ccff/deed help|r.")
end

local function initModules()
    ns.Engine:Init()
    ns.Engine:RegisterSource("kill", ns.KillSource)
    ns.Engine:RegisterSource("swing", ns.SwingSource)
    ns.Engine:RegisterSource("quest", ns.QuestSource)
    ns.Engine:RegisterSource("death", ns.DeathSource)
    ns.Engine:RegisterSource("emote", ns.EmoteSource)
    ns.Engine:RegisterSource("spell", ns.SpellSource)
    ns.Engine:RegisterSource("fish", ns.FishSource)
    ns.Engine:RegisterSource("hold", ns.HoldSource)
    ns.Engine:RegisterSource("duel", ns.DuelSource)
    ns.Engine:RegisterSource("loot", ns.LootSource)
    ns.Engine:RegisterSource("flight", ns.FlightSource)
    ns.Engine:RegisterSource("roll", ns.RollSource)
    ns.Engine:RegisterSource("boss", ns.BossSource)
    if ns.UI and ns.UI.Init then ns.UI:Init() end
    if ns.MinimapButton then ns.MinimapButton:Init() end
    if ns.TRP3Titles then ns.TRP3Titles:Init() end
    if ns.Rival and ns.Rival.Init then ns.Rival:Init() end
    -- After the rival layer, whose ladders it reads.
    if ns.HoldSource then ns.HoldSource:Recompute() end
    ns:Print(("v%s loaded. /laurels or /deed to open the panel, /deed help for commands.")
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

-- /laurels is the addon's name; /deed is shorter and reads as what you do
-- ("/deed new"), so the help text uses it. Both run the same commands.
SLASH_LAURELS1 = "/laurels"
SLASH_LAURELS2 = "/deed"
SlashCmdList.LAURELS = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        if ns.UI then ns.UI:Toggle() end

    elseif cmd == "new" then
        if ns.AuthorForm then ns.AuthorForm:Open() end

    elseif cmd == "edit" then
        if rest == "" then
            ns:Print("usage: /deed edit <trackerId>   (ids show in /deed list)")
        elseif ns.AuthorForm then
            ns.AuthorForm:Open(rest)
        end

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
            ns:Print(("published |cffffd100%s|r \226\128\148 challenge id |cffffd100%s|r")
                :format(ns.Comm.Escape(t.name), t.uuid))
            -- Until M4 carries definitions over the wire, a rival has to be
            -- told the challenge id out of band. Print the exact command so
            -- it can be pasted straight into chat.
            ns:Print("  Rivals nearby will see it under |cff66ccff/deed nearby|r.")
            ns.Rival:RecordOwnClaim(t)
            -- Send the definition, not just the claim: that is what lets a
            -- rival accept it by name instead of being told a uuid by hand.
            ns.Rival:BroadcastDef(t)
            ns.Rival:ForceBroadcast(t)
            if ns.HoldSource then ns.HoldSource:Recompute() end
        end

    elseif cmd == "rpnames" then
        local on = ns.Names.Toggle()
        ns:Print(on and "Showing players by their TRP3 names where TRP3 knows them."
            or "Showing players by their game names.")
        if on and not ns.Names.Enabled() then
            ns:Print("  TRP3 isn't loaded, so game names are shown for now.")
        end

    elseif cmd == "minimap" then
        local shown = ns.MinimapButton:Toggle()
        ns:Print(shown and "Minimap button shown."
            or "Minimap button hidden. /deed minimap brings it back.")

    elseif cmd == "toasts" then
        local want = rest:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if want == "off" then
            ns.db.toasts = false
            ns:Print("steal toasts off. Chat announcements still happen.")
        elseif want == "on" then
            ns.db.toasts = true
            ns.db.toastSound = true
            ns:Print("steal toasts on.")
        elseif want == "quiet" then
            ns.db.toasts = true
            ns.db.toastSound = false
            ns:Print("steal toasts on, without sound.")
        elseif want == "test" and ns.Toast then
            ns.Toast:Steal("took", "Boar Smasher", "Thrall", 1500)
            ns.Toast:Steal("lost", "Boar Smasher", "Thrall", 1600)
        else
            ns:Print(("toasts are %s%s"):format(
                (ns.db.toasts == false) and "off" or "on",
                (ns.db.toastSound == false) and ", muted" or ""))
            ns:Print("  /deed toasts on | off | quiet | test")
        end

    elseif cmd == "simoffer" then
        -- A fake published deed, to try Nearby's Preview / Accept / Decline
        -- and the update flow without a second player.
        local variant = rest ~= "" and string.lower(rest) or nil
        if variant == "clear" then
            ns.Rival:ClearSimulatedOffer()
            ns:Print("Forgot the simulated offer. A copy you accepted stays in "
                .. "Deeds; delete it there.")
        elseif variant and not ({ update = true, forge = true, long = true, stall = true })[variant] then
            ns:Print("usage: /deed simoffer [update|forge|long|stall|clear]")
        else
            ns:Print(ns.Rival:SimulateOffer(variant))
        end
        if ns.UI and ns.UI.RefreshNearby then ns.UI:RefreshNearby() end

    elseif cmd == "simrival" then
        -- Fake a rival so the steal mechanic can be exercised solo.
        local id, count, name = rest:match("^(%S+)%s+(%d+)%s+(.+)$")
        if not id then
            ns:Print("usage: /deed simrival <deedId> <count> <rivalName>")
            ns:Print("  fakes a rival's claim through the real receive path")
            ns:Print("  e.g. |cff66ccff/deed simrival boarsmustdie 25 Thrall|r")
        else
            local t = ns.Engine:GetTracker(id)
            if not t then
                ns:Print("no deed with id:", id)
            else
                count = tonumber(count)
                local entry = ns.Rival:SimulateClaim(t, name, count)
                if not entry then
                    ns:Print(("%s's claim was not recorded at all."):format(name))
                elseif entry.count ~= count then
                    -- Worth saying out loud: this is the anti-spoof rate cap
                    -- doing its job, not the simulation failing.
                    ns:Print(("%s is on %d, not %d \226\128\148 the rate cap rejected "
                        .. "that jump as implausible for a known rival.")
                        :format(name, entry.count, count))
                else
                    ns:Print(("simulated |cffffd100%s|r at %d \226\128\148 see "
                        .. "|cff66ccff/deed rivals %s|r"):format(name, count, t.id))
                end
            end
        end

    elseif cmd == "nearby" then
        if ns.Nearby then ns.Nearby:Toggle() end

    elseif cmd == "undecline" then
        local n = ns.Rival:ClearDeclined()
        ns:Print(("Forgot %d declined deed%s; they'll be offered again when "
            .. "next broadcast; Ask Again in Nearby asks for them now.")
            :format(n, n == 1 and "" or "s"))

    elseif cmd == "unpublish" then
        local t = ns.Engine:GetTracker(rest)
        if t then
            t.published = false
            if ns.HoldSource then ns.HoldSource:Recompute() end
            ns:Print("unpublished:", ns.Comm.Escape(t.name))
        else
            ns:Print("no tracker with id:", rest ~= "" and rest or "(none given)")
        end

    elseif cmd == "channel" then
        -- Which chat types carry addon messages differs per client, so this is
        -- a setting rather than a constant. /deed commtest tells you which
        -- ones this client actually accepts.
        local want = rest:gsub("^%s+", ""):gsub("%s+$", ""):upper()
        if want == "" then
            ns:Print(("broadcasting on: |cffffd100%s|r"):format(
                ns.Comm:BroadcastChannel()))
            -- Separated with "/" rather than "|": the chat frame treats "|"
            -- as an escape introducer, so "PARTY|RAID" was being rendered as
            -- "PARTYAID" with the |R eaten as a colour reset.
            ns:Print("  change with /deed channel <" ..
                table.concat(ns.Comm.CHANNELS, " / ") .. ">")
            ns:Print("  /deed commtest shows which ones this client accepts.")
        else
            if not ns.Comm:IsValidChannel(want) then
                ns:Print("not a channel I can use:", want)
                ns:Print("  try one of: " .. table.concat(ns.Comm.CHANNELS, ", "))
            else
                ns.db.commChannel = want
                ns:Print(("broadcasting on |cffffd100%s|r from now on. "
                    .. "/reload to re-register."):format(want))
            end
        end

    elseif cmd == "whoami" then
        if ns.Diag then ns.Diag:WhoAmI() end

    elseif cmd == "commtest" then
        if ns.Diag then ns.Diag:CommTest() end

    elseif cmd == "clubtest" then
        if ns.Diag then ns.Diag:ClubTest(rest) end

    elseif cmd == "recap" then
        ns.DeathSource:DumpRecap(function(line) ns:Print(line) end)

    elseif cmd == "tiptest" then
        if ns.UnitTooltip then ns.UnitTooltip:Report() end

    elseif cmd == "sources" then
        -- Is each kind of deed being fed at all, and with what? The last
        -- signal's id is also how to find a spell or quest id for a deed.
        ns:Print("signals seen this session:")
        for _, kind in ipairs(ns.Kinds.ORDER) do
            local s = ns.Engine.seen[kind]
            if not s then
                ns:Print(("  %s: none yet"):format(kind))
            else
                local l = s.last
                local detail = {}
                if l.cause then detail[#detail + 1] = "cause=" .. l.cause end
                if l.weapon then detail[#detail + 1] = "weapon=" .. l.weapon end
                for _, k in ipairs({ "result", "quality", "roll", "faction", "class" }) do
                    if l[k] then detail[#detail + 1] = k .. "=" .. l[k] end
                end
                if l.emote then detail[#detail + 1] = "emote=" .. l.emote end
                detail[#detail + 1] = "name=" .. tostring(l.names
                    and table.concat(l.names, "/") or l.name)
                detail[#detail + 1] = "id=" .. tostring(l.id or l.npcID)
                detail[#detail + 1] = "zone=" .. tostring(l.zone)
                ns:Print(("  %s: %d, last %s"):format(kind, s.count,
                    table.concat(detail, " ")))
            end
        end

    elseif cmd == "rivals" then
        local t = ns.Engine:GetTracker(rest)
        if not t then
            ns:Print("usage: /deed rivals <trackerId>")
        else
            -- Refresh our own standing before rendering: progress banked
            -- before the deed ever entered the ladder would otherwise not
            -- show up until the next kill landed.
            ns.Rival:RecordOwnClaim(t)
            local standings = ns.Ladder:GetStandings(ns.Rival:KeyFor(t))
            if #standings == 0 then
                ns:Print("no claims heard yet for:", ns.Comm.Escape(t.name))
            else
                ns:Print(("Rivals for %s:"):format(ns.Comm.Escape(t.name)))
                local myGuid = ns.Rival:MyGuid()
                for i, e in ipairs(standings) do
                    -- A claim stores the tier it reached, not the title text,
                    -- so resolve it against this deed's tiers.
                    local title = ns.Rival:TitleFor(t, e.tier)
                    ns:Print(("  %d. %s \226\128\148 %d  %s%s%s"):format(
                        i, ns.Comm.Escape(ns.Rival.DisplayName(e)), e.count,
                        title and ("|cffffd100<" .. ns.Comm.Escape(title) .. ">|r")
                               or "|cff999999(no title yet)|r",
                        (i == 1) and "  (holder)" or "",
                        (e.guid == myGuid) and "  |cff00ff00(you)|r" or ""))
                end
                if not t.published then
                    ns:Print(("  |cff999999Unpublished \226\128\148 no one else can "
                        .. "contest it yet. /deed publish %s|r"):format(t.id))
                end
            end
        end

    elseif cmd == "list" then
        ns:Print("Trackers:")
        for _, t in ipairs(ns.db.trackers) do
            local title = ns.Engine:CurrentTitle(t)
            ns:Print(("  [%s] %s = %d  %s"):format(
                t.id, ns.Comm.Escape(t.name), ns.Engine:GetProgress(t.id),
                title and ("<" .. ns.Comm.Escape(title) .. ">") or ""))
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
        ns:Print("commands (/laurels works for every one of these too):")
        ns:Print("  /deed                 toggle the panel")
        ns:Print("  /deed new             open the create-a-deed form")
        ns:Print("  /deed edit <id>       edit a deed (keeps its progress)")
        ns:Print("  /deed list            list trackers + progress")
        ns:Print("  /deed delete <id>     delete a tracker")
        ns:Print("  /deed reset <id>      reset a tracker's progress")
        ns:Print("  /deed publish <id>    publish a deed so others can contest it")
        ns:Print("  /deed nearby          browse challenges published nearby")
        ns:Print("  /deed undecline       offer every declined challenge again")
        ns:Print("  /deed unpublish <id>  stop broadcasting a deed")
        ns:Print("  /deed rivals <id>     show the leaderboard for a deed")
        ns:Print("  /deed whoami          dump name/GUID identity info (diagnostic)")
        ns:Print("  /deed commtest        test whether addon messages work (diagnostic)")
        ns:Print("  /deed clubtest [name] what Laurels can do in a community (diagnostic)")
        ns:Print("  /deed tiptest         why a mob's tooltip does/doesn't list deeds (diagnostic)")
        ns:Print("  /deed recap           what the last death recap holds (diagnostic)")
        ns:Print("  /deed sources         what each deed type has seen this session,")
        ns:Print("                        with the last name/id (finds spell ids)")
        ns:Print("  /deed simrival <id> <count> <name>")
        ns:Print("                        fake a rival, to test stealing solo")
        ns:Print("  /deed simoffer [update|forge|long|stall|clear]")
        ns:Print("                        fake a published deed, to test Nearby solo")
        ns:Print("  /deed minimap         hide or show the minimap button")
        ns:Print("  /deed rpnames         show rivals by TRP3 name (on) or game name")
        ns:Print("  /deed toasts [on|off|quiet|test]")
        ns:Print("                        steal pop-ups: show, mute or preview")
        ns:Print("  /deed channel [type]  show or set the broadcast channel")
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
