local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- HoldSource: "titles held" deeds -- how many contested deeds you lead.
--
-- Not an event source. A held-titles deed's progress is a current state,
-- read off the rival ladders and set (Engine:SetProgress) whenever they might
-- have changed: a claim arriving, a steal, publishing, adding or deleting a
-- deed. It goes down when someone takes a title from you; a held-titles
-- title already earned is kept.
--
-- A deed counts when it's published, at least one other player is on its
-- ladder, and you're its holder (rank 1). The "other player" rule keeps it
-- honest: publishing five deeds nobody else plays would otherwise make you
-- a hoarder of five. Held-titles deeds never count themselves, and the
-- optional "Deed name has" filter narrows which deeds count.
-- ---------------------------------------------------------------------------

local HoldSource = {}
ns.HoldSource = HoldSource

function HoldSource:Init(engine)
    self.engine = engine
end

-- Is this deed one we lead, against at least one rival?
local function leads(t)
    if not t.published or t.event == "hold" then return false end
    if not (ns.Rival and ns.Ladder) then return false end
    local key = ns.Rival:KeyFor(t)
    if #ns.Ladder:GetStandings(key) < 2 then return false end
    local holder = ns.Ladder:GetHolder(key)
    return holder ~= nil and holder.guid == ns.Rival:MyGuid()
end

-- How many deeds a held-titles deed currently counts.
function HoldSource:Count(tracker)
    local needle = tracker.match and tracker.match.nameContains
    needle = needle and string.lower(needle)
    local n = 0
    for _, t in ipairs(ns.db and ns.db.trackers or {}) do
        if leads(t) and (not needle
                or string.find(string.lower(t.name or ""), needle, 1, true)) then
            n = n + 1
        end
    end
    return n
end

-- Bring every held-titles deed up to date. Re-entrancy guarded: setting
-- progress broadcasts our claim, which can land back here.
function HoldSource:Recompute()
    if self.busy or not (self.engine and ns.db) then return end
    self.busy = true
    for _, t in ipairs(ns.db.trackers) do
        if t.event == "hold" then self.engine:SetProgress(t, self:Count(t)) end
    end
    self.busy = false
end
