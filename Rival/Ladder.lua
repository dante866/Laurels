local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Ladder: per-deed record of every claim this client has heard, and the
-- deterministic holder resolution that makes the "steal" emergent. Pure logic
-- (no WoW globals) so it can be unit-tested headlessly.
--
-- A claim: { name, count, tier, ts }   keyed by player GUID, per deedKey.
-- Stored in ns.db.ladder[deedKey][guid].
-- ---------------------------------------------------------------------------

local Ladder = {}
ns.Ladder = Ladder

-- Max plausible increase per second for a *remote* claim. Anything above this
-- is treated as a spoof and rejected (social-trust + rate cap, see docs §5).
Ladder.MAX_RATE = 50

local function store(deedKey)
    local db = ns.db
    db.ladder = db.ladder or {}
    db.ladder[deedKey] = db.ladder[deedKey] or {}
    return db.ladder[deedKey]
end

-- Record/merge a claim. opts.trusted = true for your own local claim (skips the
-- rate cap). Returns: "new" | "updated" | "stale" | "rejected".
function Ladder:RecordClaim(deedKey, guid, claim, opts)
    opts = opts or {}
    local s = store(deedKey)
    local existing = s[guid]

    -- Last-writer-wins by timestamp; older/equal timestamps are stale.
    if existing and claim.ts <= existing.ts then
        return "stale"
    end

    -- Rate sanity cap on remote increases only.
    if not opts.trusted and existing and claim.count > existing.count then
        local dt = math.max(1, claim.ts - existing.ts)
        if (claim.count - existing.count) / dt > self.MAX_RATE then
            return "rejected"
        end
    end

    s[guid] = {
        name = claim.name,
        count = claim.count,
        tier = claim.tier or 0,
        ts = claim.ts,
    }
    return existing and "updated" or "new"
end

-- Is claim `a` stronger than claim `b`? Every client applies the same order so
-- they all agree on the holder without a server:
--   1. higher count   2. earlier ts to reach it   3. lower guid (tiebreak)
local function better(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.ts ~= b.ts then return a.ts < b.ts end
    return tostring(a.guid) < tostring(b.guid)
end

function Ladder:GetHolder(deedKey)
    local s = ns.db.ladder and ns.db.ladder[deedKey]
    if not s then return nil end
    local bestGuid
    for guid, claim in pairs(s) do
        local cand = { count = claim.count, ts = claim.ts, guid = guid }
        if not bestGuid or better(cand, {
            count = s[bestGuid].count, ts = s[bestGuid].ts, guid = bestGuid,
        }) then
            bestGuid = guid
        end
    end
    if not bestGuid then return nil end
    local w = s[bestGuid]
    return { guid = bestGuid, name = w.name, count = w.count, tier = w.tier, ts = w.ts }
end

function Ladder:GetStandings(deedKey)
    local s = ns.db.ladder and ns.db.ladder[deedKey]
    local list = {}
    if not s then return list end
    for guid, claim in pairs(s) do
        table.insert(list, {
            guid = guid, name = claim.name, count = claim.count,
            tier = claim.tier, ts = claim.ts,
        })
    end
    table.sort(list, better)
    return list
end

-- Returns rank (1 = holder), total.
function Ladder:GetRank(deedKey, guid)
    local list = self:GetStandings(deedKey)
    for i, e in ipairs(list) do
        if e.guid == guid then return i, #list end
    end
    return nil, #list
end
