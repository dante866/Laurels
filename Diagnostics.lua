local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Diagnostics: in-game probes. The important one is /deed whoami, which reports
-- exactly what the name/GUID APIs return AND what the CHAT_MSG_ADDON `sender`
-- field looks like in practice -- the unknown that decides how we key player
-- identity under WoW-Forever's two-name system. See docs/identity-investigation.md.
-- ---------------------------------------------------------------------------

local Diag = {}
ns.Diag = Diag

local PROBE_PREFIX = "DEEDKPROBE"

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
