local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Engine: owns the tracker definitions, matches incoming progress "signals"
-- from sources against them, and resolves title tiers.
--
-- A "signal" is a normalized event emitted by a source, e.g.
--   { kind = "kill", name = "Kobold Vermin", npcID = 1234, amount = 1,
--     zone = "Westfall", zoneID = 52 }
-- Other kinds (quest, death, emote, spell, fish) carry `id` for their numeric
-- id, plus `cause` or `emote` where the kind has one. See Tracking/Kinds.lua.
--
-- A "tracker" (stored in DeedkeeperDB.trackers) looks like:
--   { id, name, event = "kill", match = {...}, tiers = { {count, title}, ... } }
-- ---------------------------------------------------------------------------

local Engine = {}
ns.Engine = Engine
Engine.sources = {}

-- --- matching -------------------------------------------------------------

local function matches(criteria, signal)
    if not criteria then return true end

    -- A signal names one thing, or several (a fishing catch is a loot window
    -- of items); the text only has to appear in one of them.
    if criteria.nameContains then
        local needle = string.lower(criteria.nameContains)
        local names = signal.names or { signal.name }
        local ok = false
        for _, n in ipairs(names) do
            if type(n) == "string"
               and string.find(string.lower(n), needle, 1, true) then
                ok = true break
            end
        end
        if not ok then return false end
    end

    -- Kill deeds and kill signals keep their original npcIDs/npcID keys;
    -- every other kind uses ids/id. Same criterion either way.
    local wanted = criteria.ids or criteria.npcIDs
    if wanted then
        local have = tonumber(signal.id or signal.npcID)
        local ok = false
        for _, id in ipairs(wanted) do
            if tonumber(id) == have then ok = true break end
        end
        if not ok then return false end
    end

    -- The kind-specific qualifiers. Each only constrains signals of the kind
    -- that carries it, because only deeds of that kind ever set it.
    if criteria.cause and criteria.cause ~= signal.cause then return false end
    -- A weapon choice is either exact ("sword2h") or a family ("sword").
    if criteria.weapon and criteria.weapon ~= signal.weapon
       and criteria.weapon ~= signal.weaponFamily then
        return false
    end
    if criteria.emote
       and string.upper(criteria.emote) ~= string.upper(signal.emote or "") then
        return false
    end

    -- Optional zone scoping, so a deed can be "Kobolds of Elwynn" rather than
    -- kobolds everywhere. `zone` (a name) and `zoneID` (a uiMapID) are two
    -- spellings of ONE assertion -- "the kill happened here" -- so the
    -- criterion passes if either supplied form matches, rather than requiring
    -- both. That keeps a deed counting when the client reports a zone name we
    -- hold no ID for, or an ID whose name is localized away from our spelling.
    -- A tracker with no zone criterion ignores a signal's zone entirely, so
    -- existing deeds are unaffected.
    if criteria.zone or criteria.zoneID then
        local ok = false
        if criteria.zone and signal.zone
           and string.lower(criteria.zone) == string.lower(signal.zone) then
            ok = true
        end
        if not ok and criteria.zoneID and signal.zoneID
           and tonumber(criteria.zoneID) == tonumber(signal.zoneID) then
            ok = true
        end
        if not ok then return false end
    end

    return true
end

-- --- lifecycle ------------------------------------------------------------

function Engine:Init()
    -- Ensure every tracker's tiers are sorted ascending so tier math is simple.
    for _, t in ipairs(ns.db.trackers) do
        if t.tiers then
            table.sort(t.tiers, function(a, b) return a.count < b.count end)
        end
    end
    self.initialized = true
end

function Engine:RegisterSource(key, source)
    if not source then return end
    self.sources[key] = source
    if source.Init then source:Init(self) end
end

-- --- tier math ------------------------------------------------------------

function Engine:GetProgress(id)
    return ns.charDB.progress[id] or 0
end

function Engine:CurrentTierIndex(tracker, count)
    count = count or self:GetProgress(tracker.id)
    local idx = 0
    for i, tier in ipairs(tracker.tiers or {}) do
        if count >= tier.count then idx = i else break end
    end
    return idx
end

function Engine:CurrentTitle(tracker)
    local idx = self:CurrentTierIndex(tracker)
    local tier = tracker.tiers and tracker.tiers[idx]
    return tier and tier.title or nil, idx
end

function Engine:NextTier(tracker)
    local idx = self:CurrentTierIndex(tracker)
    return tracker.tiers and tracker.tiers[idx + 1] or nil
end

-- --- progress -------------------------------------------------------------

-- Every tracker a signal would advance, in list order. Counting goes through
-- this, and so does the unit tooltip, which asks the same question before the
-- kill -- so the tooltip can never promise a deed the kill won't count.
function Engine:TrackersMatching(signal)
    local out = {}
    if not ns.db then return out end
    for _, t in ipairs(ns.db.trackers) do
        if t.event == signal.kind and matches(t.match, signal) then
            table.insert(out, t)
        end
    end
    return out
end

-- Per-kind tally of signals seen this session, for /deed sources. Answers
-- "is this source firing at all?" in game, and the last signal shows the
-- exact name and id a source reported -- the easy way to find a spell id.
Engine.seen = {}

function Engine:ReportProgress(signal)
    local s = self.seen[signal.kind] or { count = 0 }
    s.count = s.count + 1
    s.last = signal
    self.seen[signal.kind] = s

    local amount = signal.amount or 1
    for _, t in ipairs(self:TrackersMatching(signal)) do
        self:Increment(t, amount)
    end
end

function Engine:Increment(tracker, amount)
    local progress = ns.charDB.progress
    local cur = (progress[tracker.id] or 0) + (amount or 1)
    progress[tracker.id] = cur

    local newTier = self:CurrentTierIndex(tracker, cur)
    local earned = ns.charDB.earned
    local prev = earned[tracker.id] or 0

    if newTier > prev then
        earned[tracker.id] = newTier
        local tier = tracker.tiers[newTier]
        ns:Print(("New title earned: |cffffd100%s|r  (%s: %d)")
            :format(tier.title, tracker.name, cur))
        -- TODO (v2 rival layer): broadcast {tracker.id, cur, title} over an
        -- addon comm channel so nearby Deedkeeper users can contest it.
    end

    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end

    -- Rival layer: record/broadcast our own claim (no-op for unpublished deeds).
    if ns.Rival and ns.Rival.OnLocalProgress then
        ns.Rival:OnLocalProgress(tracker)
    end
end

-- --- authoring API --------------------------------------------------------

-- Deed ids are typed by hand (/deed publish <id>, /deed reset <id>), so they
-- are derived from the name rather than generated: "Mottled Boars" -> boars-ish
-- "mottledboars", not "deed17619234567823". Collisions get a numeric suffix.
local function slugify(name)
    local s = string.gsub(string.lower(tostring(name or "")), "[^%a%d]", "")
    if s == "" then return "deed" end
    return string.sub(s, 1, 24)
end

function Engine:GenerateID(name)
    local base = slugify(name)
    if not self:GetTracker(base) then return base end
    for i = 2, 999 do
        local candidate = base .. i
        if not self:GetTracker(candidate) then return candidate end
    end
    -- Pathological: fall back to something guaranteed unique.
    return base .. tostring((time and time()) or os.time())
end

function Engine:CreateTracker(def)
    assert(type(def) == "table", "tracker def must be a table")
    def.id = def.id or self:GenerateID(def.name)
    def.event = def.event or "kill"
    def.tiers = def.tiers or {}
    table.sort(def.tiers, function(a, b) return a.count < b.count end)
    table.insert(ns.db.trackers, def)
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    return def
end

-- Apply edits to an existing deed, keeping its id and its progress -- fixing a
-- typo shouldn't cost you 400 boars.
--
-- The id is deliberately immutable: progress lives at charDB.progress[id] and
-- the rival ladder keys on it, so renaming it would orphan both.
--
-- `earned` (the highest tier index reached) is re-resolved rather than left
-- alone, because tier edits invalidate it in both directions: lowering a
-- threshold below your count should show that title at once, and deleting
-- tiers must not leave the index pointing past the end of the list.
function Engine:UpdateTracker(id, changes)
    local t = self:GetTracker(id)
    if not t then return nil end

    if changes.name then t.name = changes.name end
    if changes.event then t.event = changes.event end
    if changes.match then t.match = changes.match end
    if changes.tiers then
        t.tiers = changes.tiers
        table.sort(t.tiers, function(a, b) return a.count < b.count end)
    end

    ns.charDB.earned[id] = self:CurrentTierIndex(t)
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    return t
end

function Engine:ResetProgress(id)
    ns.charDB.progress[id] = 0
    ns.charDB.earned[id] = 0
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function Engine:GetTracker(id)
    for _, t in ipairs(ns.db.trackers) do
        if t.id == id then return t end
    end
end

function Engine:DeleteTracker(id)
    for i, t in ipairs(ns.db.trackers) do
        if t.id == id then
            table.remove(ns.db.trackers, i)
            break
        end
    end
    ns.charDB.progress[id] = nil
    ns.charDB.earned[id] = nil
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end
