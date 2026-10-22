local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Engine: owns the tracker definitions, matches incoming progress "signals"
-- from sources against them, and resolves title tiers.
--
-- A "signal" is a normalized event emitted by a source, e.g.
--   { kind = "kill", name = "Kobold Vermin", npcID = 1234, amount = 1 }
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

    if criteria.nameContains then
        if not signal.name then return false end
        if not string.find(string.lower(signal.name),
                           string.lower(criteria.nameContains), 1, true) then
            return false
        end
    end

    if criteria.npcIDs then
        local ok = false
        for _, id in ipairs(criteria.npcIDs) do
            if tonumber(id) == tonumber(signal.npcID) then ok = true break end
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

function Engine:ReportProgress(signal)
    if not ns.db then return end
    local amount = signal.amount or 1
    for _, t in ipairs(ns.db.trackers) do
        if t.event == signal.kind and matches(t.match, signal) then
            self:Increment(t, amount)
        end
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
end

-- --- authoring API --------------------------------------------------------

function Engine:CreateTracker(def)
    assert(type(def) == "table", "tracker def must be a table")
    def.id = def.id or ("deed" .. tostring(time()) .. tostring(math.random(10000)))
    def.event = def.event or "kill"
    def.tiers = def.tiers or {}
    table.sort(def.tiers, function(a, b) return a.count < b.count end)
    table.insert(ns.db.trackers, def)
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    return def
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
