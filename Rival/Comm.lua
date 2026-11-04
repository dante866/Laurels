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

-- Order to fall back through when a client refuses the configured channel.
-- Measured: WoW-Forever carries CHANNEL and refuses SAY/YELL; MoP Classic is
-- the exact inverse. These differ in REACH, not just plumbing -- CHANNEL is
-- server-wide, YELL/SAY are proximity, GUILD is your guild -- so a fallback
-- changes who can contest your titles, and is announced rather than silent.
Comm.CHANNEL_PRIORITY = { "CHANNEL", "YELL", "GUILD", "SAY" }

Comm.CHANNEL_REACH = {
    CHANNEL = "server-wide",
    YELL    = "nearby players only",
    SAY     = "very nearby players only",
    GUILD   = "your guild",
    PARTY   = "your party",
    RAID    = "your raid",
}

function Comm:IsValidChannel(name)
    for _, c in ipairs(self.CHANNELS) do
        if c == name then return true end
    end
    return false
end

-- Precedence: what the player chose, then what this client's .toc declares,
-- then the built-in default. A bad or absent X-BroadcastChannel just falls
-- through rather than breaking the transport.
function Comm:BroadcastChannel()
    local chosen = ns.db and ns.db.commChannel
    if chosen and self:IsValidChannel(chosen) then return chosen end

    local fromToc = ns.tocChannel and string.upper(ns.tocChannel)
    if fromToc and self:IsValidChannel(fromToc) then return fromToc end

    return self.DEFAULT_CHANNEL
end

-- Did the client refuse this chat type? 0 is success, non-zero a refusal.
-- nil means we could not tell, which is not the same as success -- treating
-- "don't know" as "fine" is how the negotiation went blind under
-- ChatThrottleLib, whose send reports nothing at all synchronously.
function Comm:IsRefusal(result)
    local n = tonumber(result)
    return n ~= nil and n ~= 0
end

-- A client refused `channel`. Step to the next candidate it hasn't already
-- rejected, remember it, and say what changed about the ladder's reach.
function Comm:FallBackFrom(channel)
    self._refused = self._refused or {}
    self._refused[channel] = true

    for _, candidate in ipairs(self.CHANNEL_PRIORITY) do
        if not self._refused[candidate] then
            if ns.db then ns.db.commChannel = candidate end
            ns:Print(("|cffff8800%s is not allowed on this client.|r Switching to "
                .. "|cffffd100%s|r \226\128\148 rivals are now %s."):format(
                channel, candidate,
                self.CHANNEL_REACH[candidate] or "reachable on that channel"))
            if candidate == "CHANNEL" and JoinTemporaryChannel then
                JoinTemporaryChannel(self.CHANNEL_NAME)
            end
            return candidate
        end
    end

    ns:Print("|cffff8800No usable broadcast channel on this client.|r "
        .. "Rival claims can't be sent. Try /deed channel <type> manually.")
    return nil
end

-- Outbound rate limit. Every client hears every claim on a server-wide
-- channel, and flooding the addon-message pipe disconnects you, so sends are
-- queued and drained at a fixed rate rather than fired immediately.
Comm.SEND_INTERVAL = 0.4 -- seconds between queued sends
Comm.MAX_QUEUE = 64      -- drop oldest beyond this rather than grow forever

-- Player names can't contain '|', but deed keys/titles can, so escape text.
local function esc(s) return (tostring(s or ""):gsub("|", "\127")) end
local function unesc(s) return (tostring(s or ""):gsub("\127", "|")) end

-- Make a string safe to display. Chat frames and tooltips treat "|" as an
-- escape introducer, so an unescaped one swallows what follows ("PARTY|RAID"
-- rendered as "PARTYAID") and, in text supplied by another player, could
-- forge a colour code or a fake hyperlink. Doubling makes it literal.
--
-- Applied at display time rather than on decode: the ladder should keep the
-- true string, and our own format strings carry real colour codes that must
-- survive untouched.
function Comm.Escape(s)
    if type(s) ~= "string" then return s end
    return (string.gsub(s, "|", "||"))
end

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
    elseif t == "DEFPUB" then
        return self:EncodeDef(msg)
    end
end

-- DEFPUB carries a whole deed definition, not just a claim, so a rival can
-- adopt it without being told a uuid by hand. Layout is a fixed header then
-- variable count/title pairs:
--   DEFPUB|uuid|guid|ver|name|event|nameContains|ids|zone|zoneID|c|t|c|t...
--
-- Deed kinds beyond kills were added without changing that layout, because
-- the strict version gate means a new PROTO cuts new clients off from old
-- ones entirely. Instead:
--   * `ids` holds whichever id list the kind uses (NPC, quest or spell ids),
--     decoded back to `npcIDs` for kill deeds and `ids` for the rest;
--   * a kind's qualifier (a death cause, an emote) rides in the event field
--     as "kind:value", e.g. "death:falling", "emote:HUG".
-- So a kill deed encodes byte-for-byte as it always did. An older client
-- hearing a new kind sees an event name it has no source for, and the deed
-- simply never counts there.
--
-- Addon messages are capped at 255 bytes, and an over-long one fails to send
-- with a result code we would misread as the channel refusing us. So the
-- encoder measures itself and sheds trailing tiers until it fits, and returns
-- how many it kept as a second value -- shedding is otherwise invisible, and
-- a rival who accepts gets only the tiers that made it. Measured: with
-- 16-character titles about 7 tiers fit; 10-character, about 10.
Comm.MAX_BODY = 240

function Comm:EncodeDef(msg, tierLimit)
    local d = msg.def or {}
    local m = d.match or {}
    local event = d.event or "kill"
    local kind = ns.Kinds and ns.Kinds.Get(event)
    local qualifier = kind and kind.qualifier and m[kind.qualifier]
    if qualifier then event = event .. ":" .. tostring(qualifier) end
    local ids = m.ids or m.npcIDs
    local parts = {
        self.PROTO, "DEFPUB", esc(d.uuid), esc(msg.guid), esc(msg.ver),
        esc(d.name), esc(event),
        esc(m.nameContains),
        esc(ids and table.concat(ids, ",") or ""),
        esc(m.zone), tostring(m.zoneID or ""),
    }
    local tiers = d.tiers or {}
    local limit = math.min(tierLimit or #tiers, #tiers)
    for i = 1, limit do
        parts[#parts + 1] = tostring(tiers[i].count or 0)
        parts[#parts + 1] = esc(tiers[i].title)
    end

    local body = table.concat(parts, "|")
    if #body > self.MAX_BODY and limit > 1 then
        return self:EncodeDef(msg, limit - 1) -- shed a tier and remeasure
    end
    return body, limit
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
    elseif t == "DEFPUB" then
        local m = {}
        local event, qualifier = string.match(orNil(unesc(f[7])) or "kill", "^([^:]*):?(.*)$")
        if event == "" then event = "kill" end
        local kind = ns.Kinds and ns.Kinds.Get(event)
        if kind and kind.qualifier and qualifier ~= "" then
            m[kind.qualifier] = qualifier
        end
        local idsKey = (event == "kill") and "npcIDs" or "ids"

        local nameContains = orNil(unesc(f[8]))
        if nameContains then m.nameContains = nameContains end

        local ids = orNil(unesc(f[9]))
        if ids then
            local list = {}
            for tok in string.gmatch(ids, "[^,]+") do
                local n = tonumber(tok)
                if n then list[#list + 1] = n end
            end
            if #list > 0 then m[idsKey] = list end
        end

        local zone = orNil(unesc(f[10]))
        if zone then m.zone = zone end
        local zoneID = tonumber(f[11])
        if zoneID then m.zoneID = zoneID end

        local tiers = {}
        local i = 12
        while f[i] and f[i + 1] do
            local count = tonumber(f[i])
            local title = unesc(f[i + 1])
            if count and title ~= "" then
                tiers[#tiers + 1] = { count = count, title = title }
            end
            i = i + 2
        end

        return { proto = proto, type = "DEFPUB",
            uuid = orNil(unesc(f[3])), guid = orNil(unesc(f[4])),
            ver = unesc(f[5]),
            def = { uuid = orNil(unesc(f[3])), name = unesc(f[6]),
                    event = event,
                    match = m, tiers = tiers } }
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
    -- Never hand the client an over-long body: it fails with a result code
    -- the fallback logic would misread as this channel being refused, and we
    -- would switch transports over a message that was simply too big.
    if #body > self.MAX_BODY then
        if ns.Print then
            ns:Print(("|cffff8800Skipped an oversized %s message (%d bytes).|r")
                :format(tostring(msg.type), #body))
        end
        return
    end
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
    local draining = false
    local drain -- assigned below; referenced from the result handler

    -- One place decides what a send result means, so the throttled and the
    -- direct paths cannot drift apart. Called synchronously when we send
    -- ourselves, and asynchronously from ChatThrottleLib's callback.
    local function handleResult(item, channel, result)
        if not Comm:IsRefusal(result) or item.retried then return end

        -- The client refused this chat type. Move to one it allows and resend
        -- there rather than dropping the message. Marked so it can't bounce
        -- around the priority list indefinitely.
        local nextChannel = Comm:FallBackFrom(channel)
        if not nextChannel then return end

        item.channel, item.target, item.retried = nextChannel, nil, true
        table.insert(queue, 1, item)
        -- The queue may have drained while we waited on a callback, so the
        -- pump needs restarting rather than assuming it is still running.
        if not draining then
            draining = true
            ns.After(0, drain)
        end
    end

    local function rawSend(item, channel, target)
        if ChatThrottleLib then
            -- CTL sends later and returns nothing, so the result arrives via
            -- its callback (callbackArg, didSend, sendResult). Without this
            -- the channel negotiation is blind on every client where some
            -- other addon has loaded CTL -- on Forever, anyone running TRP3.
            --
            -- Note CTL *errors* on a body over 255 bytes rather than failing
            -- soft, which makes Comm:Send's MAX_BODY check load-bearing.
            ChatThrottleLib:SendAddonMessage("NORMAL", item.prefix, item.body,
                channel, target, nil,
                function(_, _didSend, sendResult)
                    handleResult(item, channel, sendResult)
                end)
            return
        end

        local send = Comm:SendFn()
        if not send then return end
        local ok, res = pcall(send, item.prefix, item.body, channel, target)
        if ok then handleResult(item, channel, res) end
    end

    drain = function()
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
        rawSend(item, channel, target)
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
