local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Comm: the peer-to-peer message bus. Encode/decode/dispatch are pure logic
-- (headlessly testable); the WoW wiring (prefix registration, CHAT_MSG_ADDON,
-- ChatThrottleLib) lives in InitTransport and is swapped for a fake in tests.
--
-- Wire format:  <proto>|<TYPE>|<field>|<field>...   (pipes in text escaped)
-- Types: HELLO | CLAIM | ASK   (DEFPUB for published deeds lands in M4)
-- ---------------------------------------------------------------------------

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "DEEDK"
Comm.PROTO = 1
Comm.handlers = {}

-- Player names can't contain '|', but deed keys/titles can, so escape text.
local function esc(s) return (tostring(s or ""):gsub("|", "\127")) end
local function unesc(s) return (tostring(s or ""):gsub("\127", "|")) end

local function split(s, sep)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out + 1] = string.sub(s, i); break end
        out[#out + 1] = string.sub(s, i, j - 1)
        i = j + 1
    end
    return out
end

function Comm:Encode(msg)
    local t = msg.type
    if t == "HELLO" then
        return table.concat({ self.PROTO, "HELLO", esc(msg.ver), esc(msg.name) }, "|")
    elseif t == "CLAIM" then
        return table.concat({ self.PROTO, "CLAIM", esc(msg.deedKey),
            msg.count or 0, msg.tier or 0, esc(msg.name), msg.ts or 0 }, "|")
    elseif t == "ASK" then
        return table.concat({ self.PROTO, "ASK", esc(msg.deedKey) }, "|")
    end
end

function Comm:Decode(body)
    local f = split(body, "|")
    local proto = tonumber(f[1])
    if not proto then return nil end
    local t = f[2]
    if t == "HELLO" then
        return { proto = proto, type = "HELLO", ver = unesc(f[3]), name = unesc(f[4]) }
    elseif t == "CLAIM" then
        return { proto = proto, type = "CLAIM", deedKey = unesc(f[3]),
            count = tonumber(f[4]) or 0, tier = tonumber(f[5]) or 0,
            name = unesc(f[6]), ts = tonumber(f[7]) or 0 }
    elseif t == "ASK" then
        return { proto = proto, type = "ASK", deedKey = unesc(f[3]) }
    end
    return { proto = proto, type = t }
end

function Comm:On(msgType, fn)
    self.handlers[msgType] = fn
end

-- Decode an incoming body, version-gate it, and dispatch to the handler.
function Comm:HandleRaw(body, sender, channel)
    local msg = self:Decode(body)
    if not msg then return end
    if msg.proto ~= self.PROTO then return end -- strict version gate for v1
    msg.sender = sender
    msg.channel = channel
    local h = self.handlers[msg.type]
    if h then h(msg) end
    return msg
end

function Comm:SetTransport(tp)
    self.transport = tp
end

function Comm:Send(msg, channel, target)
    local body = self:Encode(msg)
    if not body or not self.transport then return end
    self.transport:Send(self.PREFIX, body, channel or "YELL", target)
end

-- WoW-only wiring. Not exercised by headless tests.
function Comm:InitTransport()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    end

    local real = {}
    function real:Send(prefix, body, channel, target)
        if ChatThrottleLib then
            ChatThrottleLib:SendAddonMessage("NORMAL", prefix, body, channel, target)
        elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
            C_ChatInfo.SendAddonMessage(prefix, body, channel, target)
        end
    end
    self:SetTransport(real)

    local me = UnitName and UnitName("player")
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, body, channel, sender)
        if prefix ~= self.PREFIX then return end
        if sender == me then return end -- ignore our own echo
        self:HandleRaw(body, sender, channel)
    end)
end
