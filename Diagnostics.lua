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
