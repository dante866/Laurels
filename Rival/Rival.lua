local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Rival: the wire-up that ties Engine -> Comm -> Ladder together.
--   * local progress  -> record own (trusted) claim + throttled broadcast
--   * inbound CLAIM    -> record into ladder -> detect holder change -> announce
--   * HELLO / ASK      -> resend our standings so newcomers converge
--
-- Pure logic lives here; the WoW-only transport is set up by Comm:InitTransport.
-- WireHandlers() is separated from Init() so tests can wire two clients over a
-- fake bus without touching WoW globals.
-- ---------------------------------------------------------------------------

local Rival = {}
ns.Rival = Rival

Rival.HEARTBEAT = 30 -- seconds between rebroadcasts of unchanged progress
Rival.lastHolder = {}
Rival._bcast = {}

local function genUUID()
    return string.format("D-%x-%x", (time and time()) or os.time(), math.random(0, 0xffffff))
end
ns.genUUID = genUUID

function Rival:Now()
    if self._nowFn then return self._nowFn() end
    if GetServerTime then return GetServerTime() end
    if time then return time() end
    return os.time()
end

function Rival:MyName()
    return self._name or (UnitName and UnitName("player")) or "You"
end

-- Stable identity for a deed across players. Published deeds share the author's
-- uuid (so everyone contests the same thing); personal deeds fall back to a key
-- derived from their match, but those never broadcast (ShouldBroadcast=false).
function Rival:KeyFor(tracker)
    if tracker.uuid then return tracker.uuid end
    local m = tracker.match or {}
    local parts = { tracker.event or "kill" }
    if m.nameContains then parts[#parts + 1] = "n=" .. string.lower(m.nameContains) end
    if m.npcIDs then
        local ids = {}
        for _, id in ipairs(m.npcIDs) do ids[#ids + 1] = tonumber(id) end
        table.sort(ids)
        parts[#parts + 1] = "i=" .. table.concat(ids, ",")
    end
    return table.concat(parts, "~")
end

function Rival:ShouldBroadcast(tracker)
    return tracker.published == true
end

function Rival:FindTracker(key)
    for _, t in ipairs(ns.db.trackers) do
        if self:KeyFor(t) == key then return t end
    end
end

local function titleFor(tracker, tierIndex)
    if tracker and tracker.tiers and tierIndex and tierIndex > 0 then
        local t = tracker.tiers[tierIndex]
        return t and t.title
    end
end

-- Recompute the holder for a deed and announce if the title changed hands.
function Rival:AfterLadderChange(key, tracker)
    tracker = tracker or self:FindTracker(key)
    local holder = ns.Ladder:GetHolder(key)
    local prevName = self.lastHolder[key]
    local newName = holder and holder.name or nil
    self.lastHolder[key] = newName

    if holder and holder.tier and holder.tier > 0 and newName ~= prevName then
        local title = titleFor(tracker, holder.tier) or (tracker and tracker.name) or key
        local me = self:MyName()
        if newName == me and prevName and prevName ~= me then
            ns:Print(("You took |cffffd100%s|r from %s!"):format(title, prevName))
        elseif prevName == me and newName ~= me then
            ns:Print(("%s took |cffffd100%s|r from you! (they have %d)")
                :format(newName, title, holder.count))
        end
    end

    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    if self.onHolderChange then self.onHolderChange(key, holder, prevName) end
end

function Rival:ForceBroadcast(tracker)
    local key = self:KeyFor(tracker)
    local count = ns.Engine:GetProgress(tracker.id)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)
    local me, ts = self:MyName(), self:Now()
    self._bcast[key] = { tier = tier, t = ts }
    ns.Comm:Send({ type = "CLAIM", deedKey = key, count = count, tier = tier, name = me, ts = ts }, "YELL")
end

-- Called by Engine:Increment after every local progress tick.
function Rival:OnLocalProgress(tracker)
    if not self:ShouldBroadcast(tracker) then return end
    local key = self:KeyFor(tracker)
    local count = ns.Engine:GetProgress(tracker.id)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)
    local me, ts = self:MyName(), self:Now()

    -- Keep our own ladder entry current (local, trusted, no network).
    ns.Ladder:RecordClaim(key, me, { name = me, count = count, tier = tier, ts = ts }, { trusted = true })
    self:AfterLadderChange(key, tracker)

    -- Broadcast immediately on a tier change; otherwise at most once per HEARTBEAT.
    local st = self._bcast[key] or { tier = -1, t = 0 }
    if tier > st.tier or (ts - st.t) >= self.HEARTBEAT then
        self._bcast[key] = { tier = tier, t = ts }
        ns.Comm:Send({ type = "CLAIM", deedKey = key, count = count, tier = tier, name = me, ts = ts }, "YELL")
    end
end

-- Handlers -----------------------------------------------------------------

function Rival:OnClaim(msg)
    local key = msg.deedKey
    local who = msg.sender or msg.name
    if not who then return end
    ns.Ladder:RecordClaim(key, who,
        { name = msg.name or who, count = msg.count, tier = msg.tier, ts = msg.ts })
    self:AfterLadderChange(key)
end

function Rival:OnHello()
    -- A newcomer appeared: resend our standing for each published deed.
    for _, t in ipairs(ns.db.trackers) do
        if self:ShouldBroadcast(t) then self:ForceBroadcast(t) end
    end
end

function Rival:OnAsk(msg)
    local t = self:FindTracker(msg.deedKey)
    if t and self:ShouldBroadcast(t) then self:ForceBroadcast(t) end
end

-- Lifecycle ----------------------------------------------------------------

function Rival:WireHandlers()
    self.lastHolder = self.lastHolder or {}
    self._bcast = self._bcast or {}
    ns.Comm:On("CLAIM", function(m) self:OnClaim(m) end)
    ns.Comm:On("HELLO", function(m) self:OnHello(m) end)
    ns.Comm:On("ASK", function(m) self:OnAsk(m) end)
end

function Rival:Init()
    self:WireHandlers()
    ns.Comm:InitTransport()
    -- Announce ourselves so nearby clients send us their current standings.
    ns.Comm:Send({ type = "HELLO", ver = ns.version, name = self:MyName() }, "YELL")
end
