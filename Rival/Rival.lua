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
Rival.partial = {}        -- uuid -> a definition still receiving its tiers (session only)

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
    if m.weapon then parts[#parts + 1] = "w=" .. m.weapon end
    for _, k in ipairs({ "target", "result", "quality", "roll" }) do
        if m[k] then parts[#parts + 1] = k:sub(1, 1) .. k:sub(-1) .. "=" .. m[k] end
    end
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

-- How to show a ladder entry's player: their TRP3 name when the integration
-- is loaded and knows them, else the name their claim carried. Guarded so
-- the headless suites, which don't load Integrations/, still run this path.
local function displayName(e)
    if not e then return nil end
    return (ns.Names and ns.Names.ForEntry(e)) or e.name
end
Rival.DisplayName = displayName

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
    self.lastHolderName[key] = displayName(holder)

    if holder and holder.tier and holder.tier > 0 and newGuid ~= prevGuid then
        local title = titleFor(tracker, holder.tier) or (tracker and tracker.name) or key
        local me = self:MyGuid()
        if newGuid == me and prevGuid and prevGuid ~= me then
            self:AnnounceSteal("took", title, prevName, holder.count)
        elseif prevGuid == me and newGuid ~= me then
            self:AnnounceSteal("lost", title, displayName(holder), holder.count)
        end
    end

    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    if self.onHolderChange then self.onHolderChange(key, holder, prevName) end
    -- A holder change can change how many deeds we lead.
    if ns.HoldSource then ns.HoldSource:Recompute() end
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

-- Challenge ids the player has turned down. A declined deed is ignored when
-- it's broadcast again, or it would reappear on the author's next resend.
function Rival:Declined()
    ns.db.declined = ns.db.declined or {}
    return ns.db.declined
end

-- Newer versions of deeds we've accepted, waiting on the player's OK. An
-- accepted deed never changes underneath you: the author's edits arrive
-- here, and only Accept Update applies them.
function Rival:Updates()
    ns.db.updates = ns.db.updates or {}
    return ns.db.updates
end

-- Who published a deed: the sender name Blizzard's server attaches to the
-- addon message. That can't be forged, unlike the GUID inside the payload,
-- which the sending addon writes itself. Deeds stored before `author`
-- existed carry the same value as `origin`, which DEFPUB has always set from
-- the sender.
local function authorOf(d)
    return d and (d.author or d.origin)
end

-- The author of a tracker we accepted, or nil for one we made ourselves
-- (ours are published with our own name as origin, and take no updates).
function Rival:TrackerAuthor(t)
    if t.author then return t.author end
    if t.origin and t.origin ~= self:MyName() and t.origin ~= "adopted" then
        return t.origin
    end
end

-- Two versions of a deed are the same if they encode the same. Reusing the
-- wire encoding means "same" is exactly "a rival would receive the same" --
-- every part of it, so a change in the last tier of a long deed still counts.
local function signature(d)
    local parts = ns.Comm:EncodeDefParts({ guid = "", ver = "", def = {
        uuid = "", name = d.name, event = d.event,
        match = d.match, tiers = d.tiers } })
    return table.concat(parts, "\n")
end
Rival.Signature = signature

-- A seconds clock for arrival timing. Session time, not server time:
-- follow-ups arrive within seconds, and GetTime is finer than GetServerTime.
function Rival:Clock()
    if self._clockFn then return self._clockFn() end
    return (GetTime and GetTime()) or os.time()
end

-- How many of a heard deed's tiers haven't arrived yet.
function Rival:MissingTiers(d)
    local n = 0
    for i = 1, d.tierTotal or #(d.tiers or {}) do
        if not (d.tiers and d.tiers[i]) then n = n + 1 end
    end
    return n
end

-- For a deed still arriving: how far along, a rough wait, and whether it has
-- stalled. Nil once it's whole. The author's addon sends one message every
-- Comm.SEND_INTERVAL seconds, so parts outstanding times that interval is
-- the wait; a part overdue by several intervals has most likely been lost.
-- A partial deed from an earlier session has nothing more coming.
function Rival:Arrival(d)
    local missing = self:MissingTiers(d)
    if missing == 0 then return nil end
    local total = d.tierTotal or #(d.tiers or {})
    local interval = ns.Comm.SEND_INTERVAL or 0.4
    local left = math.max(1, (d.partCount or 1) - (d.partsReceived or 0))
    local since = self:Clock() - (d.lastPartAt or 0)
    local live = self.partial[d.uuid] == d
    return {
        missing  = missing,
        received = total - missing,
        total    = total,
        seconds  = math.max(1, math.ceil(left * interval - since)),
        stalled  = not live or since > math.max(5, left * interval * 4),
    }
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

local function defMessage(self, tracker)
    return { type = "DEFPUB", guid = self:MyGuid(), ver = ns.version,
        def = {
            uuid = tracker.uuid, name = tracker.name,
            event = tracker.event, match = tracker.match, tiers = tracker.tiers,
        } }
end

-- The head, then any follow-ups, back to back through the send queue.
function Rival:BroadcastDef(tracker)
    if not self:ShouldBroadcast(tracker) or not tracker.uuid then return end
    for _, body in ipairs(ns.Comm:EncodeDefParts(defMessage(self, tracker))) do
        ns.Comm:SendEncoded(body, "DEFPUB")
    end
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
    -- Nothing is accepted half-received: you'd be contesting thresholds you
    -- never saw.
    if self:MissingTiers(d) > 0 then return nil, "it's still arriving" end

    local t = ns.Engine:CreateTracker({
        name = d.name, event = d.event or "kill",
        match = copy(d.match or {}),
        tiers = copy(d.tiers or {}),
        uuid = uuid, published = true, origin = d.origin,
        author = authorOf(d), authorGuid = d.authorGuid,
    })
    self:Updates()[uuid] = nil
    self:RecordOwnClaim(t)
    self:ForceBroadcast(t)
    return t
end

-- Simulation (development) --------------------------------------------------

-- A published deed from a player who isn't there, for trying Nearby's
-- Preview / Accept / Decline and the update flow solo. Like SimulateClaim it
-- goes through Comm:HandleRaw, so the decode and the author check are the
-- real ones. Variants:
--   nil       the offer, from "Simulated Rival"
--   "update"  the same deed edited by its author (renamed, a tier added)
--   "forge"   the same challenge id sent by someone else -- must be ignored
--   "long"    a separate 14-tier deed, whose follow-ups arrive at the real
--             send rate, so the greyed-out Accept and its wait are visible
--   "stall"   that long deed with its last follow-up lost
-- Returns a sentence saying what happened, for the slash command to print.
Rival.SIM_UUID      = "D-SIMOFFER"
Rival.SIM_LONG_UUID = "D-SIMLONG"
Rival.SIM_AUTHOR    = "Simulated Rival"
local SIM_GUID      = "Player-0-SIMOFFER"

local LONG_TITLES = { "Boar Botherer", "Boar Bane", "Boar Legend", "Tusk Taker",
    "Bristle Breaker", "Snout Smasher", "Hog Hunter", "Razorback Ruin",
    "Quillboar Quieter", "Sty Scourge", "Swine Slayer", "Bacon Baron",
    "Lord of Boars", "Boar God" }

function Rival:SimulateLongOffer(stall)
    local uuid = self.SIM_LONG_UUID
    self.partial[uuid] = nil
    self:KnownDeeds()[uuid] = nil
    local def = { uuid = uuid, name = "The Long Hunt", event = "kill",
        match = { nameContains = "Boar" }, tiers = {} }
    for i, title in ipairs(LONG_TITLES) do
        def.tiers[i] = { count = i * 25, title = title }
    end
    local bodies = ns.Comm:EncodeDefParts({ guid = SIM_GUID, ver = ns.version, def = def })
    -- The head now; follow-ups one send interval apart, as a real author's
    -- queue would deliver them.
    ns.Comm:HandleRaw(bodies[1], self.SIM_AUTHOR, "SIM")
    local last = stall and #bodies - 1 or #bodies
    for i = 2, last do
        local deliver = function() ns.Comm:HandleRaw(bodies[i], self.SIM_AUTHOR, "SIM") end
        if ns.After then ns.After((i - 1) * ns.Comm.SEND_INTERVAL, deliver) else deliver() end
    end
    return (stall
        and "\"The Long Hunt\" (%d tiers, %d messages) is arriving with one message lost: "
            .. "preview it in Nearby."
        or "\"The Long Hunt\" (%d tiers, %d messages) is arriving: preview it in Nearby now.")
        :format(#def.tiers, #bodies)
end

function Rival:SimulateOffer(variant)
    if variant == "long" or variant == "stall" then
        return self:SimulateLongOffer(variant == "stall")
    end
    local uuid = self.SIM_UUID
    local heard = self:KnownDeeds()[uuid] or self:AdoptedUUID(uuid)

    local def = { uuid = uuid, name = "Boar Botherer's Challenge", event = "kill",
        match = { nameContains = "Boar" },
        tiers = { { count = 10, title = "Boar Botherer" },
                  { count = 50, title = "Boar Bane" },
                  { count = 100, title = "Boar Legend" } } }
    local sender = self.SIM_AUTHOR

    if variant == "update" then
        def.name = "Boar Botherer's Grand Challenge"
        def.tiers[3] = { count = 150, title = "Boar Legend" }
        def.tiers[4] = { count = 500, title = "Boar God" }
    elseif variant == "forge" then
        -- Forging only means something against a deed already heard:
        -- against nothing, the impostor would simply be its first author.
        if not heard then
            return "Nothing to forge yet: run /deed simoffer first."
        end
        sender = "Impostor"
        def.name = "lol"
        def.tiers = { { count = 1, title = "|cffff0000gibberish|r" } }
    end

    -- What we hold before, so a forge can be judged by whether it changed.
    local offerBefore, updateBefore = self:KnownDeeds()[uuid], self:Updates()[uuid]

    local body = ns.Comm:Encode({ type = "DEFPUB", guid = SIM_GUID,
        ver = ns.version, def = def })
    ns.Comm:HandleRaw(body, sender, "SIM")

    if variant == "forge" then
        local ignored = self:KnownDeeds()[uuid] == offerBefore
            and self:Updates()[uuid] == updateBefore
        return ignored and "An impostor resent it as \"lol\" with one tier, and it was ignored."
            or "|cffff4040The forged copy got through -- please report this.|r"
    end
    if self:Declined()[uuid] then
        return "It's declined, so it was ignored. /deed undecline to see it again."
    end
    local tracker = self:AdoptedUUID(uuid)
    if tracker then
        return self:Updates()[uuid] and "An update is waiting in Nearby: preview it."
            or "No change from the version you accepted."
    end
    return ("%s published a deed: open Nearby and Preview it."):format(self.SIM_AUTHOR)
end

-- Forget the simulated offer, its update and any decline of it. A copy
-- you accepted stays in Deeds; delete it there like any other.
function Rival:ClearSimulatedOffer()
    for _, uuid in ipairs({ self.SIM_UUID, self.SIM_LONG_UUID }) do
        self:KnownDeeds()[uuid] = nil
        self:Updates()[uuid] = nil
        self:Declined()[uuid] = nil
        self.partial[uuid] = nil
    end
end

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

-- A heard definition. Only its author may ever change what we hold for a
-- challenge id: the first sender we hear for an id owns it, and a message
-- for that id from anyone else is dropped. Ids are random and only learned
-- from the author's own broadcast, so nobody can claim one first.
--
-- A long definition arrives as a head and DEFTIERS follow-ups. Until every
-- tier is in, it waits in `partial` (this session only) and is never stored
-- as an update or accepted. A brand-new offer shows in Nearby meanwhile,
-- marked as still arriving; a deed we already hold keeps its current version
-- until the replacement is whole, so a resend never leaves you holding half.
function Rival:OnDefPub(msg)
    local d = msg.def
    if not d or not d.uuid then return end
    d.author = msg.sender
    d.authorGuid = msg.guid
    d.origin = msg.name or msg.sender
    d.seen = self:Now()
    d.tierTotal = d.tierTotal or #(d.tiers or {})
    d.partsReceived = 0
    d.lastPartAt = self:Clock()

    local tracker = self:AdoptedUUID(d.uuid)
    if tracker then
        -- One we made (our own echo) or one we've accepted. Ours takes no
        -- updates; an accepted one only from its author, and never directly.
        local author = self:TrackerAuthor(tracker)
        if not author or author ~= d.author then return end
    else
        if self:Declined()[d.uuid] then return end
        local author = authorOf(self:KnownDeeds()[d.uuid])
        if author and author ~= d.author then return end -- not theirs to change
    end

    if self:MissingTiers(d) > 0 then
        self.partial[d.uuid] = d
        if not tracker and not self:KnownDeeds()[d.uuid] then
            self:KnownDeeds()[d.uuid] = d
        end
        if ns.UI and ns.UI.RefreshNearby then ns.UI:RefreshNearby() end
        return
    end
    self.partial[d.uuid] = nil
    self:StoreDef(d, tracker)
end

-- A follow-up: more tiers for a definition still arriving. Only its
-- author's, and only for the version whose head we hold.
function Rival:OnDefTiers(msg)
    local d = msg.uuid and self.partial[msg.uuid]
    if not d or msg.sender ~= d.author then return end
    for i, tier in pairs(msg.tiers or {}) do
        if i >= 1 and i <= d.tierTotal then d.tiers[i] = tier end
    end
    d.partsReceived = (d.partsReceived or 0) + 1
    d.lastPartAt = self:Clock()

    if self:MissingTiers(d) == 0 then
        self.partial[d.uuid] = nil
        self:StoreDef(d, self:AdoptedUUID(d.uuid))
    elseif ns.UI and ns.UI.RefreshNearby then
        ns.UI:RefreshNearby()
    end
end

-- A complete definition from its author: the offer, or an update to the
-- deed we accepted if it differs from ours.
function Rival:StoreDef(d, tracker)
    if tracker then
        local sig = signature(d)
        if sig == signature(tracker) or sig == tracker.ignoredUpdate then
            self:Updates()[d.uuid] = nil -- nothing new, or already turned down
        else
            self:Updates()[d.uuid] = d
        end
    else
        self:KnownDeeds()[d.uuid] = d
    end
    if ns.UI and ns.UI.RefreshNearby then ns.UI:RefreshNearby() end
end

-- Turn an offer down. It leaves Nearby and stays gone when rebroadcast.
function Rival:Decline(uuid)
    local d = self:KnownDeeds()[uuid]
    if not d then return nil, "no such deed heard nearby" end
    self:Declined()[uuid] = { name = d.name, author = authorOf(d), at = self:Now() }
    self:KnownDeeds()[uuid] = nil
    self.partial[uuid] = nil
    return true
end

-- Forget every decline, so those deeds can be offered again.
function Rival:ClearDeclined()
    local n = 0
    for uuid in pairs(self:Declined()) do
        self:Declined()[uuid] = nil
        n = n + 1
    end
    return n
end

-- Pending updates to accepted deeds, as { deed = newVersion, tracker = ours }.
function Rival:PendingUpdates()
    local out = {}
    for uuid, d in pairs(self:Updates()) do
        local t = self:AdoptedUUID(uuid)
        if t then
            out[#out + 1] = { deed = d, tracker = t }
        else
            self:Updates()[uuid] = nil -- we stopped contesting it
        end
    end
    table.sort(out, function(a, b) return (a.deed.name or "") < (b.deed.name or "") end)
    return out
end

-- Apply the author's newer version. Progress is kept, as with any edit.
function Rival:AcceptUpdate(uuid)
    local d = self:Updates()[uuid]
    local t = self:AdoptedUUID(uuid)
    if not (d and t) then return nil, "no update waiting for that deed" end
    ns.Engine:UpdateTracker(t.id, { name = d.name, event = d.event,
        match = copy(d.match or {}), tiers = copy(d.tiers or {}) })
    t.ignoredUpdate = nil
    self:Updates()[uuid] = nil
    return t
end

-- Keep our version. This exact update won't be offered again; a later,
-- different one will.
function Rival:IgnoreUpdate(uuid)
    local d = self:Updates()[uuid]
    local t = self:AdoptedUUID(uuid)
    if not (d and t) then return nil, "no update waiting for that deed" end
    t.ignoredUpdate = signature(d)
    self:Updates()[uuid] = nil
    return true
end

-- What an update would change, one line per difference, for the preview.
-- Text is raw (from the wire); the caller escapes it for display.
function Rival:DescribeChanges(t, d)
    local lines = {}
    if (t.name or "") ~= (d.name or "") then
        lines[#lines + 1] = ('Name: "%s" becomes "%s"'):format(t.name or "", d.name or "")
    end
    local was = ns.Kinds.Describe(t.event, t.match)
    local now = ns.Kinds.Describe(d.event, d.match)
    if was ~= now then
        lines[#lines + 1] = "Counts: " .. was
        lines[#lines + 1] = "  becomes: " .. now
    end
    local old, new = t.tiers or {}, d.tiers or {}
    for i = 1, math.max(#old, #new) do
        local a, b = old[i], new[i]
        local function show(x) return ("%s at %d"):format(x.title or "?", x.count or 0) end
        if a and not b then
            lines[#lines + 1] = ("Tier %d removed: %s"):format(i, show(a))
        elseif b and not a then
            lines[#lines + 1] = ("Tier %d added: %s"):format(i, show(b))
        elseif a.title ~= b.title or a.count ~= b.count then
            lines[#lines + 1] = ("Tier %d: %s becomes %s"):format(i, show(a), show(b))
        end
    end
    return lines
end

function Rival:OnClaim(msg)
    local key = msg.deedKey
    -- Key strictly on the GUID in the payload. The `sender` string is a
    -- display name and is not a stable identity on this client.
    local guid = msg.guid
    if not guid then return end
    ns.Ladder:RecordClaim(key, guid,
        { name = msg.name or msg.sender or guid, sender = msg.sender, count = msg.count,
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
    ns.Comm:On("DEFTIERS", function(m) self:OnDefTiers(m) end)
    self.partial = self.partial or {}
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
