local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Diagnostics: in-game probes. The important one is /deed whoami, which reports
-- exactly what the name/GUID APIs return AND what the CHAT_MSG_ADDON `sender`
-- field looks like in practice -- the unknown that decides how we key player
-- identity under WoW-Forever's two-name system. See docs/identity-investigation.md.
-- ---------------------------------------------------------------------------

local Diag = {}
ns.Diag = Diag

local PROBE_PREFIX = "LAURELSPROBE"

local function line(label, value)
    ns:Print(("  %s = %s"):format(label, tostring(value)))
end

function Diag:WhoAmI()
    ns:Print("=== identity probe (copy this to Claude) ===")

    local name, realm = UnitName("player")
    line("UnitName(player) #1", name)
    line("UnitName(player) #2 (realm)", realm)

    if GetUnitName then
        line("GetUnitName(player,false)", GetUnitName("player", false))
        line("GetUnitName(player,true)", GetUnitName("player", true))
    end
    if UnitFullName then
        local n, r = UnitFullName("player")
        line("UnitFullName name", n)
        line("UnitFullName realm", r)
    end
    if GetRealmName then line("GetRealmName()", GetRealmName()) end
    if GetNormalizedRealmName then line("GetNormalizedRealmName()", GetNormalizedRealmName()) end

    local guid = UnitGUID and UnitGUID("player")
    line("UnitGUID(player)", guid)
    if guid and strsplit then
        local parts = { strsplit("-", guid) }
        for i = 1, #parts do line(("  GUID field %d"):format(i), parts[i]) end
    end

    self:ProbeSenderFormat(name)
    ns:Print("(sender-format result prints in a second; include it too)")
end

-- Send an addon message over YELL to ourselves and report the exact `sender`
-- string the client echoes back. This mirrors the real CLAIM transport, so it
-- tells us whether the echo guard and remote ladder keying can trust the name.
function Diag:ProbeSenderFormat(myName)
    self._probeName = myName

    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
        ns:Print("  (no C_ChatInfo.SendAddonMessage; cannot probe sender format)")
        return
    end
    if C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
    end

    if not self.frame then
        local f = CreateFrame("Frame")
        self.frame = f
        f:RegisterEvent("CHAT_MSG_ADDON")
        f:SetScript("OnEvent", function(_, _, prefix, msg, channel, sender)
            if prefix ~= PROBE_PREFIX then return end
            ns:Print("--- sender-format probe result ---")
            line("CHAT_MSG_ADDON sender", sender)
            line("channel", channel)
            line("payload", msg)
            line("sender == UnitName?",
                (sender == self._probeName) and "YES -> name keying is safe"
                or "NO -> MUST key identity on GUID")
            ns:Print("----------------------------------")
        end)
    end

    C_ChatInfo.SendAddonMessage(PROBE_PREFIX, "PING", "YELL")
end

-- ---------------------------------------------------------------------------
-- /deed commtest -- isolate WHY addon messages aren't round-tripping.
--
-- WhoAmI's sender probe going silent tells us a message left but never came
-- back; it does not tell us which link broke. This walks the whole chain:
-- API surface -> prefix registration (and its return value) -> send (per
-- channel, errors captured) -> receive. The whole v3 rival layer rides on
-- this pipe, so we find out before building more on top of it.
-- ---------------------------------------------------------------------------

local COMM_TEST_PREFIX = "LAURELSTEST"
local TEST_CHANNEL = "LaurelsTest"

local after = ns.After -- shared timer helper from Core.lua

local function sendFn()
    return (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
end

function Diag:CommTest()
    ns:Print("=== comm transport test (copy ALL of this to Claude) ===")
    self._heard = 0

    -- 1. What does this client actually expose?
    line("C_ChatInfo", C_ChatInfo and "present" or "MISSING")
    if C_ChatInfo then
        line("  .SendAddonMessage", C_ChatInfo.SendAddonMessage and "yes" or "MISSING")
        line("  .RegisterAddonMessagePrefix", C_ChatInfo.RegisterAddonMessagePrefix and "yes" or "MISSING")
        line("  .IsAddonMessagePrefixRegistered", C_ChatInfo.IsAddonMessagePrefixRegistered and "yes" or "MISSING")
    end
    line("global SendAddonMessage", SendAddonMessage and "present" or "MISSING")
    line("global RegisterAddonMessagePrefix", RegisterAddonMessagePrefix and "present" or "MISSING")
    line("C_Timer.After", (C_Timer and C_Timer.After) and "present" or "MISSING")

    -- 2. Registration -- the return value matters. Retail hands back a success
    -- bool, and there is a hard cap on registered prefixes per client; if some
    -- other addon exhausted it, ours is refused and every message is filtered.
    local reg = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix)
                or RegisterAddonMessagePrefix
    if not reg then
        ns:Print("  !! no way to register a prefix; addon comms impossible here")
        return
    end
    local ok, ret = pcall(reg, COMM_TEST_PREFIX)
    line("Register... call succeeded", ok)
    line("Register... returned", ret)
    if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
        local ok2, ret2 = pcall(C_ChatInfo.IsAddonMessagePrefixRegistered, COMM_TEST_PREFIX)
        line("IsAddonMessagePrefixRegistered", ok2 and tostring(ret2) or "errored")
    end

    -- 3. Listen for EVERY addon message, not just ours. The client only
    -- delivers prefixes some addon has registered, so chatter from other
    -- addons still proves the pipe itself is alive -- which separates
    -- "comms are dead" from "our prefix specifically is being dropped".
    if not self.testFrame then
        local f = CreateFrame("Frame")
        self.testFrame = f
        f:RegisterEvent("CHAT_MSG_ADDON")
        f:SetScript("OnEvent", function(_, _, prefix, body, channel, sender)
            Diag._heard = (Diag._heard or 0) + 1
            local mine = (prefix == COMM_TEST_PREFIX) and "  <== OURS" or ""
            ns:Print(("  <- prefix=%s channel=%s sender=%s body=%s%s"):format(
                tostring(prefix), tostring(channel),
                tostring(sender), tostring(body), mine))
        end)
    end

    -- 4. Join a hidden custom channel. With SAY/YELL refused, a custom channel
    -- is the only remaining candidate for an ad-hoc (non-guild, non-group)
    -- ladder, so test whether addon traffic is permitted over one.
    if JoinTemporaryChannel then
        local jok, jerr = pcall(JoinTemporaryChannel, TEST_CHANNEL)
        line("JoinTemporaryChannel call", jok and "ok" or ("ERROR: " .. tostring(jerr)))
    else
        line("JoinTemporaryChannel", "MISSING")
    end

    -- 5. Send on each channel after a pause. Registering and sending in the
    -- same frame is a known way to miss your own echo, so give it 2s first;
    -- that also gives the channel join time to land.
    ns:Print("  (registered; sending in 2s, results in ~8s)")
    after(2, function()
        local send = sendFn()
        if not send then
            ns:Print("  !! no SendAddonMessage available")
            return
        end

        local targets = {
            { "YELL" },
            { "SAY" },
        }
        if IsInGuild and IsInGuild() then
            targets[#targets + 1] = { "GUILD" }
        end
        if IsInGroup and IsInGroup() then
            targets[#targets + 1] = { "PARTY" }
        end
        local me = GetUnitName and GetUnitName("player", false)
        if me then
            targets[#targets + 1] = { "WHISPER", me }
        end
        local chanIndex = GetChannelName and GetChannelName(TEST_CHANNEL)
        line("custom channel index", chanIndex)
        if chanIndex and chanIndex > 0 then
            targets[#targets + 1] = { "CHANNEL", chanIndex }
        else
            ns:Print("  (not in the custom channel; CHANNEL untested)")
        end

        for i = 1, #targets do
            local channel, target = targets[i][1], targets[i][2]
            local sok, sret = pcall(send, COMM_TEST_PREFIX,
                "PING-" .. channel, channel, target)
            ns:Print(("  -> %s%s: %s"):format(
                channel,
                target and (" to " .. tostring(target)) or "",
                sok and ("sent, returned " .. tostring(sret))
                     or ("ERROR: " .. tostring(sret))))
        end

        after(6, function()
            ns:Print(("=== result: %d addon message(s) received ==="):format(Diag._heard or 0))
            if (Diag._heard or 0) == 0 then
                ns:Print("  none at all -> this client/server does not deliver")
                ns:Print("  addon messages back to the sender, or blocks them.")
            end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- /deed clubtest [community] -- can Laurels use a Blizzard Community?
--
-- Forever drops addon messages on custom channels (measured 2026-11-07), and
-- a community could stand in: deeds posted to a stream persist, and the
-- member list names who to whisper. Every C_Club call used here is in the
-- Forever dump, but the dump doesn't say which ones an addon may make or
-- whether what comes back is a secret value -- the combat log taught us
-- that. So this walks it: list communities -> streams -> members -> read
-- recent history -> post one visible test message and read it back.
-- ---------------------------------------------------------------------------

local CLUB_TEST_TEXT = "[Laurels test] ping %d -- please ignore"

-- A value as text, saying so when it's a secret the addon can't read.
local function shown(v)
    if v ~= nil and ns.Signals.Readable(v) == nil then return "<secret>" end
    return tostring(v)
end

-- pcall that reports a failure under `label`.
local function try(label, fn, ...)
    local ok, a = pcall(fn, ...)
    if not ok then line(label, "ERROR: " .. tostring(a)) end
    return ok, a
end

local function pickClub(clubs, want)
    want = (want and want ~= "") and string.lower(want) or "laurels"
    for _, c in ipairs(clubs) do
        local name = ns.Signals.Readable(c.name)
        if name and string.find(string.lower(name), want, 1, true) then return c end
    end
end

-- The first stream anyone can post in (normally General).
local function pickStream(streams)
    for _, s in ipairs(streams) do
        if not s.leadersAndModeratorsOnly then return s end
    end
    return streams[1]
end

function Diag:ClubTest(want)
    ns:Print("=== community test (copy ALL of this to Claude) ===")
    local C = C_Club
    if not C then
        ns:Print("  !! no C_Club on this client")
        return
    end

    -- 1. Is the system on, and is anything restricted?
    local function flag(label, fn)
        if not fn then line(label, "MISSING"); return end
        local ok, v = try(label, fn)
        if ok then line(label, shown(v)) end
    end
    flag("C_Club.IsEnabled", C.IsEnabled)
    flag("C_Club.IsRestricted", C.IsRestricted)
    if C_ChatInfo then
        flag("AreOutgoingAddonChatMessagesRestricted",
            C_ChatInfo.AreOutgoingAddonChatMessagesRestricted)
        flag("InChatMessagingLockdown", C_ChatInfo.InChatMessagingLockdown)
    end

    -- 2. Communities we're in.
    local ok, clubs = try("GetSubscribedClubs", C.GetSubscribedClubs)
    if not ok or type(clubs) ~= "table" then return end
    line("communities", #clubs)
    for _, c in ipairs(clubs) do
        ns:Print(("    %s  type=%s members=%s crossFaction=%s"):format(
            shown(c.name), shown(c.clubType), shown(c.memberCount),
            shown(c.crossFaction)))
    end
    local club = pickClub(clubs, want)
    if not club then
        ns:Print("  !! no community matching that name -- run /deed clubtest <part of its name>")
        return
    end
    local clubId = club.clubId
    ns:Print("  testing: " .. shown(club.name))

    -- 3. Streams (the community's chat channels).
    local sok, streams = try("GetStreams", C.GetStreams, clubId)
    if not sok or type(streams) ~= "table" or #streams == 0 then
        line("streams", "none")
        return
    end
    for _, s in ipairs(streams) do
        ns:Print(("    stream %s  modsOnly=%s"):format(
            shown(s.name), shown(s.leadersAndModeratorsOnly)))
    end
    local stream = pickStream(streams)
    local streamId = stream.streamId
    ns:Print("  using stream: " .. shown(stream.name))

    -- 4. Members: are the names (who we'd whisper) readable?
    local mok, members = try("GetClubMembers", C.GetClubMembers, clubId)
    if mok and type(members) == "table" then
        line("members", #members)
        for i = 1, math.min(#members, 5) do
            local iok, info = try("GetMemberInfo", C.GetMemberInfo, clubId, members[i])
            if iok and info then
                ns:Print(("    %s  guid=%s presence=%s self=%s"):format(
                    shown(info.name), shown(info.guid),
                    shown(info.presence), shown(info.isSelf)))
            end
        end
    end

    -- 5. Ask for recent history, then post. Watch what arrives. The frame is
    -- dropped at the end so it doesn't keep printing (commtest's does).
    local sent = CLUB_TEST_TEXT:format(math.random(1000, 9999))
    local f = CreateFrame("Frame")
    local heard = 0
    for _, ev in ipairs({ "CLUB_MESSAGE_ADDED", "CLUB_MESSAGE_HISTORY_RECEIVED" }) do
        try("RegisterEvent " .. ev, f.RegisterEvent, f, ev)
    end
    f:SetScript("OnEvent", function(_, ev, cId, sId, msgId)
        if cId ~= clubId or sId ~= streamId then return end
        if ev == "CLUB_MESSAGE_HISTORY_RECEIVED" then
            ns:Print("  <- history received")
            return
        end
        heard = heard + 1
        local gok, msg = pcall(C.GetMessageInfo, clubId, streamId, msgId)
        if not gok or not msg then
            ns:Print("  <- message added, but GetMessageInfo gave nothing")
            return
        end
        local mine = (ns.Signals.Readable(msg.content) == sent)
            and "  <== OURS, read back intact" or ""
        ns:Print(("  <- message added: author=%s content=%s%s"):format(
            shown(msg.author and msg.author.name), shown(msg.content), mine))
    end)

    if C.FocusStream then try("FocusStream", C.FocusStream, clubId, streamId) end
    if C.RequestMoreMessagesBefore then
        try("RequestMoreMessagesBefore", C.RequestMoreMessagesBefore,
            clubId, streamId, nil, 5)
    end
    ns:Print("  (reading history in 3s, then posting one visible test message)")

    after(3, function()
        local rok, ranges = try("GetMessageRanges", C.GetMessageRanges, clubId, streamId)
        local last = rok and type(ranges) == "table" and ranges[#ranges]
        if last and last.newestMessageId then
            local bok, msgs = try("GetMessagesBefore", C.GetMessagesBefore,
                clubId, streamId, last.newestMessageId, 3)
            if bok and type(msgs) == "table" then
                line("recent messages read", #msgs)
                for _, m in ipairs(msgs) do
                    ns:Print(("    %s: %s"):format(
                        shown(m.author and m.author.name), shown(m.content)))
                end
            end
        else
            line("recent messages", "none downloaded")
        end

        -- SendMessage returns nothing; a block shows up as an error here or
        -- as Core's "Forbidden/Blocked" line.
        local pok, perr = pcall(C.SendMessage, clubId, streamId, sent)
        line("SendMessage call", pok and "ok (no error)" or ("ERROR: " .. tostring(perr)))

        after(5, function()
            f:UnregisterAllEvents()
            if C.UnfocusStream then pcall(C.UnfocusStream, clubId, streamId) end
            ns:Print(("=== result: %d message(s) seen arriving ==="):format(heard))
            if heard == 0 then
                ns:Print("  nothing arrived -> posting is blocked or the event is withheld;")
                ns:Print("  check the community window for: " .. sent)
            end
        end)
    end)
end
