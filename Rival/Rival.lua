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
Rival.lastHolder = {}     -- deedKey -> guid of the last known holder
Rival.lastHolderName = {} -- deedKey -> that holder's display name
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

-- Display label only -- never an identity key. On WoW-Forever a character is
-- "First Last", and GetUnitName(player,false) is the only API that returns
-- both parts; UnitName("player") returns just "Indira" and puts the surname
-- in the slot where stock WoW puts the realm.
function Rival:MyName()
    if self._name then return self._name end
    if GetUnitName then
        local full = GetUnitName("player", false)
        if full and full ~= "" then return full end
    end
    return (UnitName and UnitName("player")) or "You"
end

-- The identity key for everything: ladder entries, holder comparison, and the
-- self-echo check. Unique per character and immune to renames and to the
-- two-name display format.
function Rival:MyGuid()
    return self._guid or (UnitGUID and UnitGUID("player")) or self:MyName()
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

-- The title a claim's tier index corresponds to, or nil below the first tier.
-- A claim carries the tier it reached, not the title text, so resolving it
-- needs the tracker -- which is why this is public: the ladder display needs
-- it as much as the steal announcements do.
function Rival:TitleFor(tracker, tierIndex)
    if tracker and tracker.tiers and tierIndex and tierIndex > 0 then
        local t = tracker.tiers[tierIndex]
        return t and t.title
    end
end

local function titleFor(tracker, tierIndex)
    return Rival:TitleFor(tracker, tierIndex)
end

-- Recompute the holder for a deed and announce if the title changed hands.
function Rival:AfterLadderChange(key, tracker)
    tracker = tracker or self:FindTracker(key)
    local holder = ns.Ladder:GetHolder(key)
    -- Compare holders by GUID; names are ambiguous (two "Indira"s collide)
    -- and can change, which would fire spurious steal announcements.
    local prevGuid = self.lastHolder[key]
    local prevName = self.lastHolderName[key]
    local newGuid = holder and holder.guid or nil
    self.lastHolder[key] = newGuid
    self.lastHolderName[key] = holder and holder.name or nil

    if holder and holder.tier and holder.tier > 0 and newGuid ~= prevGuid then
        local title = titleFor(tracker, holder.tier) or (tracker and tracker.name) or key
        local me = self:MyGuid()
        if newGuid == me and prevGuid and prevGuid ~= me then
            ns:Print(("You took |cffffd100%s|r from %s!")
                :format(title, prevName or "someone"))
        elseif prevGuid == me and newGuid ~= me then
            ns:Print(("%s took |cffffd100%s|r from you! (they have %d)")
                :format(holder.name or "Someone", title, holder.count))
        end
    end

    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    if self.onHolderChange then self.onHolderChange(key, holder, prevName) end
end

function Rival:ForceBroadcast(tracker)
    local key = self:KeyFor(tracker)
    local count = ns.Engine:GetProgress(tracker.id)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)
    local me, guid, ts = self:MyName(), self:MyGuid(), self:Now()
    self._bcast[key] = { tier = tier, t = ts }
    ns.Comm:Send({ type = "CLAIM", deedKey = key, count = count, tier = tier,
        name = me, guid = guid, ts = ts })
end

-- Called by Engine:Increment after every local progress tick.
function Rival:OnLocalProgress(tracker)
    if not self:ShouldBroadcast(tracker) then return end
    local key = self:KeyFor(tracker)
    local count = ns.Engine:GetProgress(tracker.id)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)
    local me, guid, ts = self:MyName(), self:MyGuid(), self:Now()

    -- Keep our own ladder entry current (local, trusted, no network).
    ns.Ladder:RecordClaim(key, guid, { name = me, count = count, tier = tier, ts = ts },
        { trusted = true })
    self:AfterLadderChange(key, tracker)

    -- Broadcast immediately on a tier change; otherwise at most once per HEARTBEAT.
    local st = self._bcast[key] or { tier = -1, t = 0 }
    if tier > st.tier or (ts - st.t) >= self.HEARTBEAT then
        self._bcast[key] = { tier = tier, t = ts }
        ns.Comm:Send({ type = "CLAIM", deedKey = key, count = count, tier = tier,
            name = me, guid = guid, ts = ts })
    end
end

-- Handlers -----------------------------------------------------------------

function Rival:OnClaim(msg)
    local key = msg.deedKey
    -- Key strictly on the GUID in the payload. The `sender` string is a
    -- display name and is not a stable identity on this client.
    local guid = msg.guid
    if not guid then return end
    ns.Ladder:RecordClaim(key, guid,
        { name = msg.name or msg.sender or guid, count = msg.count,
          tier = msg.tier, ts = msg.ts })
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
    self.lastHolderName = self.lastHolderName or {}
    self._bcast = self._bcast or {}
    ns.Comm:On("CLAIM", function(m) self:OnClaim(m) end)
    ns.Comm:On("HELLO", function(m) self:OnHello(m) end)
    ns.Comm:On("ASK", function(m) self:OnAsk(m) end)
end

function Rival:Init()
    self:WireHandlers()
    ns.Comm:InitTransport()
    -- Announce ourselves so other clients send us their current standings.
    -- Delayed because JoinTemporaryChannel has to land before the channel has
    -- an index to send on; the send queue retries, but this avoids the churn.
    ns.After(3, function()
        ns.Comm:Send({ type = "HELLO", ver = ns.version,
            name = self:MyName(), guid = self:MyGuid() })
    end)
end
