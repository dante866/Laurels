local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Comm: the peer-to-peer message bus. Encode/decode/dispatch are pure logic
-- (headlessly testable); the WoW wiring (prefix registration, CHAT_MSG_ADDON,
-- ChatThrottleLib) lives in InitTransport and is swapped for a fake in tests.
--
-- Wire format:  <proto>|<TYPE>|<field>|<field>...   (pipes in text escaped)
-- Types: HELLO | CLAIM | ASK   (DEFPUB for published deeds lands in M4)
--
-- Transport: a hidden custom channel, NOT proximity chat. Measured on
-- WoW-Forever 1.60.1 (build 70532): SendAddonMessage over SAY and YELL is
-- refused (result 4), while WHISPER and CHANNEL both return 0 and deliver.
-- There is therefore no range-limited transport available, so the ladder is
-- server-wide over one shared channel. See docs/rival-layer.md section 3.
--
-- Identity is the player GUID, never the name. The same client measurement
-- showed CHAT_MSG_ADDON `sender` is the full two-part name ("Indira
-- Resthaerl") while UnitName("player") returns only "Indira", so a
-- name-based self-check compares unequal and a client logs itself as its own
-- rival. GUIDs travel in the payload, which also makes the protocol immune
-- to whatever format `sender` happens to take.
-- ---------------------------------------------------------------------------

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "DEEDK"
Comm.PROTO = 2 -- bumped from 1: HELLO/CLAIM now carry a guid field
Comm.handlers = {}

-- The shared channel every client joins. Hidden from the chat UI because
-- clients join it temporarily and never print its traffic.
Comm.CHANNEL_NAME = "Deedkeeper"
Comm.DEFAULT_CHANNEL = "CHANNEL"

-- Which chat types a client will carry addon messages over is a per-client
-- fact, not a constant: WoW-Forever refuses SAY and YELL outright. So the
-- broadcast channel is a setting (/deed channel) rather than a hardcoded
-- value, and adapting to a new client is a chat command instead of a patch.
Comm.CHANNELS = { "CHANNEL", "GUILD", "PARTY", "RAID", "SAY", "YELL" }

function Comm:BroadcastChannel()
    return (ns.db and ns.db.commChannel) or self.DEFAULT_CHANNEL
end

-- Outbound rate limit. Every client hears every claim on a server-wide
-- channel, and flooding the addon-message pipe disconnects you, so sends are
-- queued and drained at a fixed rate rather than fired immediately.
Comm.SEND_INTERVAL = 0.4 -- seconds between queued sends
Comm.MAX_QUEUE = 64      -- drop oldest beyond this rather than grow forever

-- Player names can't contain '|', but deed keys/titles can, so escape text.
local function esc(s) return (tostring(s or ""):gsub("|", "\127")) end
local function unesc(s) return (tostring(s or ""):gsub("\127", "|")) end

-- An absent optional field arrives as "" after a round trip; keep it nil so
-- callers can test presence rather than comparing against an empty string.
local function orNil(s)
    if s == nil or s == "" then return nil end
    return s
end

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
        return table.concat({ self.PROTO, "HELLO", esc(msg.ver), esc(msg.name),
            esc(msg.guid) }, "|")
    elseif t == "CLAIM" then
        return table.concat({ self.PROTO, "CLAIM", esc(msg.deedKey),
            msg.count or 0, msg.tier or 0, esc(msg.name), msg.ts or 0,
            esc(msg.guid) }, "|")
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
        return { proto = proto, type = "HELLO", ver = unesc(f[3]),
            name = unesc(f[4]), guid = orNil(unesc(f[5])) }
    elseif t == "CLAIM" then
        return { proto = proto, type = "CLAIM", deedKey = unesc(f[3]),
            count = tonumber(f[4]) or 0, tier = tonumber(f[5]) or 0,
            name = unesc(f[6]), ts = tonumber(f[7]) or 0,
            guid = orNil(unesc(f[8])) }
    elseif t == "ASK" then
        return { proto = proto, type = "ASK", deedKey = unesc(f[3]) }
    end
    return { proto = proto, type = t }
end

function Comm:On(msgType, fn)
    self.handlers[msgType] = fn
end

-- Decode an incoming body, version-gate it, drop our own echo, and dispatch.
--
-- The echo check lives here rather than in the receive frame because it has
-- to compare GUIDs, and the GUID is only available after decoding. Comparing
-- the `sender` string against UnitName (the previous approach) compares a
-- full two-part name against a first name and never matches, so a client
-- treated its own broadcasts as a rival's.
function Comm:HandleRaw(body, sender, channel)
    local msg = self:Decode(body)
    if not msg then return end
    if msg.proto ~= self.PROTO then return end -- strict version gate
    if self.myGuid and msg.guid and msg.guid == self.myGuid then return end
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
    -- Channel resolution is the transport's job, so this stays pure and the
    -- headless tests can swap in a fake that ignores `channel` entirely.
    self.transport:Send(self.PREFIX, body, channel or self:BroadcastChannel(), target)
end

-- Addon-message API, preferring the modern namespace but falling back to the
-- globals. Both WoW-Forever and MoP Classic are modern-engine and expose
-- C_ChatInfo; the globals are cheap insurance for any client that doesn't.
function Comm:SendFn()
    return (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
end

function Comm:RegisterFn()
    return (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix)
        or RegisterAddonMessagePrefix
end

-- Current index of our shared channel, or 0 if we aren't in it yet. Indices
-- are per-session and shift as the player joins and leaves other channels,
-- so this is resolved per send and never cached.
function Comm:ChannelIndex()
    if not GetChannelName then return 0 end
    local idx = GetChannelName(self.CHANNEL_NAME)
    return tonumber(idx) or 0
end

-- WoW-only wiring. Not exercised by headless tests.
function Comm:InitTransport()
    local register = self:RegisterFn()
    if register then register(self.PREFIX) end
    -- Only worth joining if we actually broadcast over a custom channel.
    if JoinTemporaryChannel and self:BroadcastChannel() == "CHANNEL" then
        JoinTemporaryChannel(self.CHANNEL_NAME)
    end

    self.myGuid = UnitGUID and UnitGUID("player")

    local queue = {}
    local function rawSend(prefix, body, channel, target)
        if ChatThrottleLib then
            ChatThrottleLib:SendAddonMessage("NORMAL", prefix, body, channel, target)
            return
        end
        local send = Comm:SendFn()
        if send then send(prefix, body, channel, target) end
    end

    local draining = false
    local function drain()
        local item = table.remove(queue, 1)
        if not item then draining = false; return end
        -- Resolve the channel index at send time, not enqueue time.
        local channel, target = item.channel, item.target
        if channel == "CHANNEL" and not target then
            target = Comm:ChannelIndex()
            if target == 0 then
                -- Not in the channel yet; put it back and retry shortly.
                table.insert(queue, 1, item)
                ns.After(1, drain)
                return
            end
        end
        rawSend(item.prefix, item.body, channel, target)
        ns.After(Comm.SEND_INTERVAL, drain)
    end

    local real = {}
    function real:Send(prefix, body, channel, target)
        if #queue >= Comm.MAX_QUEUE then table.remove(queue, 1) end
        queue[#queue + 1] = { prefix = prefix, body = body,
            channel = channel, target = target }
        if not draining then
            draining = true
            ns.After(0, drain)
        end
    end
    self:SetTransport(real)

    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, body, channel, sender)
        if prefix ~= self.PREFIX then return end
        self:HandleRaw(body, sender, channel) -- echo dropped by GUID in HandleRaw
    end)
end
