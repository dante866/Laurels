local addonName, ns = ...

-- ---------------------------------------------------------------------------
-- Toast: the on-screen announcement when a title changes hands.
--
-- A steal was previously one chat line, which is a thin payoff for the whole
-- rival layer -- and in combat it scrolls away unseen, which is exactly when
-- it tends to happen. The chat line stays as the log; this is the moment.
--
-- Driven by OnUpdate rather than an AnimationGroup. Both targets are
-- Classic-flavoured clients where retail-only APIs cannot be assumed (see
-- CLAUDE.md), and an alpha ramp needs nothing beyond SetAlpha.
-- ---------------------------------------------------------------------------

local Toast = {}
ns.Toast = Toast

Toast.HOLD     = 4.0  -- seconds at full opacity
Toast.FADE_IN  = 0.25
Toast.FADE_OUT = 0.75
Toast.queue    = {}

-- Sound ids are guarded rather than assumed: SOUNDKIT's membership varies by
-- client and these have not been checked against the Forever dump. If any
-- piece is missing the toast is simply silent.
local function playSound(kind)
    if not PlaySound or not SOUNDKIT then return end
    if ns.db and ns.db.toastSound == false then return end
    local id = (kind == "took") and SOUNDKIT.ACHIEVEMENT_MENU_OPEN
                                 or SOUNDKIT.RAID_WARNING
    if id then pcall(PlaySound, id) end
end

function Toast:GetFrame()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "DeedkeeperToast", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(440, 88)
    f:SetPoint("CENTER", 0, 180)
    f:SetFrameStrata("HIGH")
    ns.ApplyDialogBackdrop(f)
    -- Never interactive: this appears mid-combat and must not eat a click.
    f:EnableMouse(false)
    f:SetAlpha(0)
    f:Hide()

    f.headline = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.headline:SetPoint("TOP", 0, -12)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.title:SetPoint("TOP", 0, -34)
    f.title:SetWidth(410)

    f.detail = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.detail:SetPoint("BOTTOM", 0, 12)

    self.frame = f
    return f
end

function Toast:Display(item)
    local f = self:GetFrame()
    f.headline:SetText(item.headline)
    f.headline:SetTextColor(item.color[1], item.color[2], item.color[3])
    f.title:SetText(item.title or "")
    f.detail:SetText(item.detail or "")
    f:SetAlpha(0)
    f:Show()
    playSound(item.kind)

    local elapsed = 0
    local total = self.FADE_IN + self.HOLD + self.FADE_OUT
    f:SetScript("OnUpdate", function(self_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed < Toast.FADE_IN then
            self_:SetAlpha(elapsed / Toast.FADE_IN)
        elseif elapsed < Toast.FADE_IN + Toast.HOLD then
            self_:SetAlpha(1)
        elseif elapsed < total then
            self_:SetAlpha(1 - (elapsed - Toast.FADE_IN - Toast.HOLD) / Toast.FADE_OUT)
        else
            self_:SetScript("OnUpdate", nil)
            self_:Hide()
            Toast:Next()
        end
    end)
end

-- Queued rather than shown immediately: trading a title back and forth with
-- someone produces steals in quick succession, and overlapping them would
-- mean seeing none of them.
function Toast:Enqueue(item)
    if ns.db and ns.db.toasts == false then return end
    table.insert(self.queue, item)
    if not (self.frame and self.frame:IsShown()) then self:Next() end
end

function Toast:Next()
    local item = table.remove(self.queue, 1)
    if item then self:Display(item) end
end

-- kind is "took" or "lost".
function Toast:Steal(kind, title, who, count)
    if kind == "took" then
        self:Enqueue({
            kind     = kind,
            headline = "TITLE TAKEN",
            color    = { 0.25, 1, 0.3 },
            title    = title,
            detail   = who and ("taken from " .. who) or nil,
        })
    else
        self:Enqueue({
            kind     = kind,
            headline = "TITLE LOST",
            color    = { 1, 0.35, 0.25 },
            title    = title,
            detail   = ("%s now has %d"):format(who or "Someone", count or 0),
        })
    end
end
