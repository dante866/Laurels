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

-- A local copy helper rather than ns.deepcopy, which lives in Core.lua -- the
-- headless suites load only Engine/Ladder/Comm/Rival, and this file stays in
-- that set. An adopted deed must not share tables with the heard definition.
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

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
    -- Only parts a deed actually has are added, so a kill deed's key is the
    -- same as it was before other kinds existed.
    local list = m.ids or m.npcIDs
    if list then
        local ids = {}
        for _, id in ipairs(list) do ids[#ids + 1] = tonumber(id) end
        table.sort(ids)
        parts[#parts + 1] = "i=" .. table.concat(ids, ",")
    end
    if m.cause then parts[#parts + 1] = "c=" .. m.cause end
    if m.emote then parts[#parts + 1] = "e=" .. string.upper(m.emote) end
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

-- A title changed hands, in one of the two directions that involve us.
--
-- Both outputs on purpose: chat is the durable log you can scroll back to,
-- the toast is the moment. A steal tends to land mid-combat, which is exactly
-- when a chat line disappears unread. The toast is optional at runtime, so
-- the headless suites (which load no UI) still exercise this path.
function Rival:AnnounceSteal(kind, title, who, count)
    -- The rival's name and the deed's title both originate from another
    -- player, so they are escaped before being dropped into our own format
    -- strings -- whose colour codes are ours and must survive as-is.
    local safeTitle = ns.Comm.Escape(title)
    local safeWho = ns.Comm.Escape(who)
    if kind == "took" then
        ns:Print(("You took |cffffd100%s|r from %s!")
            :format(safeTitle, safeWho or "someone"))
    else
        ns:Print(("%s took |cffffd100%s|r from you! (they have %d)")
            :format(safeWho or "Someone", safeTitle, count or 0))
    end
    if ns.Toast then ns.Toast:Steal(kind, safeTitle, safeWho, count) end
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
            self:AnnounceSteal("took", title, prevName, holder.count)
        elseif prevGuid == me and newGuid ~= me then
            self:AnnounceSteal("lost", title, holder.name, holder.count)
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

-- Write our own standing into the ladder: local, trusted, no network.
--
-- Deliberately NOT gated on the deed being published. The ladder is what
-- /deed rivals renders, and you hold your own deed whether or not anyone else
-- can contest it -- gating this on publishing is why an unpublished deed
-- showed "no claims heard yet" while you were standing on 20 kills.
-- Publishing gates *broadcasting*, which is a separate thing.
function Rival:RecordOwnClaim(tracker)
    local key = self:KeyFor(tracker)
    local count = ns.Engine:GetProgress(tracker.id)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)
    ns.Ladder:RecordClaim(key, self:MyGuid(),
        { name = self:MyName(), count = count, tier = tier, ts = self:Now() },
        { trusted = true })
    return key, count, tier
end

-- Called by Engine:Increment after every local progress tick.
function Rival:OnLocalProgress(tracker)
    local key, count, tier = self:RecordOwnClaim(tracker)
    self:AfterLadderChange(key, tracker)

    -- Everything below is the network half, which publishing does gate.
    if not self:ShouldBroadcast(tracker) then return end

    local me, guid, ts = self:MyName(), self:MyGuid(), self:Now()
    -- Broadcast immediately on a tier change; otherwise at most once per HEARTBEAT.
    local st = self._bcast[key] or { tier = -1, t = 0 }
    if tier > st.tier or (ts - st.t) >= self.HEARTBEAT then
        self._bcast[key] = { tier = tier, t = ts }
        ns.Comm:Send({ type = "CLAIM", deedKey = key, count = count, tier = tier,
            name = me, guid = guid, ts = ts })
    end
end

-- Published-deed discovery (M4) ---------------------------------------------

-- Deeds we've heard published by other players but haven't adopted. Stored
-- account-wide and separately from ns.db.trackers: these are offers, not
-- things being tracked, and the engine must not iterate them.
function Rival:KnownDeeds()
    ns.db.known = ns.db.known or {}
    return ns.db.known
end

-- Have we already got a tracker contesting this challenge?
function Rival:AdoptedUUID(uuid)
    for _, t in ipairs(ns.db.trackers) do
        if t.uuid == uuid then return t end
    end
end

-- Offers worth showing: everything heard that we aren't already contesting.
function Rival:NearbyDeeds()
    local out = {}
    for uuid, d in pairs(self:KnownDeeds()) do
        if not self:AdoptedUUID(uuid) then
            out[#out + 1] = d
        end
    end
    table.sort(out, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return out
end

function Rival:BroadcastDef(tracker)
    if not self:ShouldBroadcast(tracker) or not tracker.uuid then return end
    ns.Comm:Send({ type = "DEFPUB", guid = self:MyGuid(), ver = ns.version,
        def = {
            uuid = tracker.uuid, name = tracker.name,
            event = tracker.event, match = tracker.match, tiers = tracker.tiers,
        } })
end

-- Turn a heard definition into a real tracker. This is what "Accept" does,
-- and taking the author's own match and tiers is the point: both sides then
-- count the same things against the same thresholds, which hand-copying a
-- uuid never guaranteed.
function Rival:Adopt(uuid)
    local existing = self:AdoptedUUID(uuid)
    if existing then return existing, "already adopted" end

    local d = self:KnownDeeds()[uuid]
    if not d then return nil, "no such deed heard nearby" end

    local t = ns.Engine:CreateTracker({
        name = d.name, event = d.event or "kill",
        match = copy(d.match or {}),
        tiers = copy(d.tiers or {}),
        uuid = uuid, published = true, origin = d.origin,
    })
    self:RecordOwnClaim(t)
    self:ForceBroadcast(t)
    return t
end

-- Simulation (development) --------------------------------------------------

-- Inject a claim as though another player had broadcast it.
--
-- Deliberately routed through Comm:HandleRaw rather than written straight to
-- the ladder: it goes encode -> decode -> version gate -> echo guard ->
-- OnClaim -> ladder -> holder recompute -> announcement, which is the whole
-- path a real rival exercises. Writing to the ladder directly would prove
-- almost nothing. This is what lets the rival layer be developed and watched
-- without a second person logged in.
--
-- Returns the resulting ladder entry (nil if the claim was refused) and the
-- fake GUID used.
function Rival:SimulateClaim(tracker, name, count)
    local key = self:KeyFor(tracker)
    local tier = ns.Engine:CurrentTierIndex(tracker, count)

    -- Stable per name, so simulating the same rival again updates that rival
    -- instead of inventing a new one each time.
    local guid = "Player-0-SIM" .. string.gsub(string.lower(name), "%s", "")

    local function entryFor()
        for _, e in ipairs(ns.Ladder:GetStandings(key)) do
            if e.guid == guid then return e end
        end
    end
    local existing = entryFor()

    -- Two things constrain the timestamp. A remote claim needs one strictly
    -- later than the last, and the anti-spoof rate cap refuses gains above
    -- MAX_RATE per second. So advance the simulated clock far enough that the
    -- jump reads as time spent farming rather than a teleport -- otherwise
    -- this tool could never move a rival by more than MAX_RATE per call,
    -- which would make it useless for setting up a steal.
    --
    -- The cap itself is untouched: real remote claims still face it.
    local step = 1
    if existing and count > existing.count then
        step = math.max(1,
            math.ceil((count - existing.count) / (ns.Ladder.MAX_RATE or 50)))
    end
    self._simTs = math.max(self._simTs or 0, self:Now(),
        existing and existing.ts or 0) + step

    ns.Comm:HandleRaw(ns.Comm:Encode({
        type = "CLAIM", deedKey = key, count = count, tier = tier,
        name = name, guid = guid, ts = self._simTs,
    }), name, "SIMULATED")

    return entryFor(), guid
end

-- Handlers -----------------------------------------------------------------

function Rival:OnDefPub(msg)
    local d = msg.def
    if not d or not d.uuid then return end
    -- Our own published deeds come back to us on a shared channel; they are
    -- not offers. AdoptedUUID covers that and the already-accepted case alike.
    if self:AdoptedUUID(d.uuid) then return end

    d.origin = msg.name or msg.sender
    d.seen = self:Now()
    self:KnownDeeds()[d.uuid] = d
    if ns.UI and ns.UI.RefreshNearby then ns.UI:RefreshNearby() end
end

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
    -- A newcomer appeared: resend each published deed's definition and our
    -- standing on it, so they can both see the offer and place us on it.
    for _, t in ipairs(ns.db.trackers) do
        if self:ShouldBroadcast(t) then
            self:BroadcastDef(t)
            self:ForceBroadcast(t)
        end
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
    ns.Comm:On("DEFPUB", function(m) self:OnDefPub(m) end)
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
