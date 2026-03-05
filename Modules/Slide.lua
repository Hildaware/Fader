local addonName, addon = ...

-- Original position snapshot before any slide. Keyed by fade-target frame object.
-- nil = frame is at its home position; set = frame has been (or is being) slid.
local slideOrigins = {} -- [frame] = { point, relTo, relPoint, x, y, wasClamped }

-- Direction vectors for slide animations.
local SLIDE_VECTORS = {
    left  = { -1,  0 },
    right = {  1,  0 },
    up    = {  0,  1 },
    down  = {  0, -1 },
}

local function GetSlideOffset(direction, distance)
    local v = SLIDE_VECTORS[direction]
    if not v then return 0, 0 end
    return v[1] * distance, v[2] * distance
end

-- ── Slide via TranslateAnimation ─────────────────────────────────────────
-- TranslateAnimation is a GL transform applied after layout, so it bypasses
-- UIParent's scissor region and lets frames travel fully off-screen without
-- the squishing/clipping that SetPoint-based movement causes.

-- Cached AnimationGroups and active slide state, keyed by fade-target frame.
local frameSlideAGs   = {} -- [frame] = { ag, translate }
local activeSlideInfo = {} -- [frame] = { startX, startY, endX, endY, point, relTo, relPoint, duration }

-- slideData = { point, relTo, relPoint, startX, startY, endX, endY, onComplete? }
local function StartSlideAnimation(frame, fadeTime, slideData)
    -- If a slide is in progress, commit the current visual position before starting
    -- the new one so the frame doesn't snap back.
    local active = activeSlideInfo[frame]
    if active and frameSlideAGs[frame] then
        local ag = frameSlideAGs[frame].ag
        local t  = math.min(ag:GetElapsed() / active.duration, 1)
        ag:Stop()
        local cx = active.startX + (active.endX - active.startX) * t
        local cy = active.startY + (active.endY - active.startY) * t
        frame:ClearAllPoints()
        frame:SetPoint(active.point, active.relTo, active.relPoint, cx, cy)
        slideData.startX = cx
        slideData.startY = cy
        activeSlideInfo[frame] = nil
    end

    if fadeTime <= 0 then
        frame:ClearAllPoints()
        frame:SetPoint(slideData.point, slideData.relTo, slideData.relPoint, slideData.endX, slideData.endY)
        if slideData.onComplete then slideData.onComplete() end
        return
    end

    -- Create and cache the AnimationGroup (one per frame, reused).
    if not frameSlideAGs[frame] then
        local ag        = frame:CreateAnimationGroup()
        local translate = ag:CreateAnimation('Translation')
        translate:SetSmoothing('NONE')
        frameSlideAGs[frame] = { ag = ag, translate = translate }
    end

    local cache = frameSlideAGs[frame]
    local dx    = slideData.endX - slideData.startX
    local dy    = slideData.endY - slideData.startY

    cache.ag:Stop()
    cache.translate:SetOffset(dx, dy)
    cache.translate:SetDuration(fadeTime)

    -- Capture for the closure (slideData may be mutated by the caller after this call).
    local endX, endY   = slideData.endX, slideData.endY
    local pt, rt, rp   = slideData.point, slideData.relTo, slideData.relPoint
    local onComplete   = slideData.onComplete

    cache.ag:SetScript('OnFinished', function()
        activeSlideInfo[frame] = nil
        frame:ClearAllPoints()
        frame:SetPoint(pt, rt, rp, endX, endY)
        if onComplete then onComplete() end
    end)

    activeSlideInfo[frame] = {
        startX   = slideData.startX,
        startY   = slideData.startY,
        endX     = endX,
        endY     = endY,
        point    = pt,
        relTo    = rt,
        relPoint = rp,
        duration = fadeTime,
    }

    cache.ag:Play()
end

-- Starts a slide-out animation for fadeTarget based on the rule's slide settings.
-- No-op if the rule has slide disabled.
function addon:ApplySlide(fadeTarget, fadeTime, rule)
    if not rule.slideEnabled or not rule.slideDirection then return end

    local dx, dy = GetSlideOffset(rule.slideDirection, rule.slideDistance or 100)

    -- Capture home position once; don't overwrite if a slide is already in progress.
    if not slideOrigins[fadeTarget] then
        local point, relTo, relPoint, x, y = fadeTarget:GetPoint()
        if point then
            local wasClamped = fadeTarget:IsClampedToScreen()
            slideOrigins[fadeTarget] = { point = point, relTo = relTo, relPoint = relPoint, x = x, y = y, wasClamped = wasClamped }
            fadeTarget:SetClampedToScreen(false)
        end
    end

    local origin = slideOrigins[fadeTarget]
    if not origin then return end

    local _, _, _, curX, curY = fadeTarget:GetPoint()
    StartSlideAnimation(fadeTarget, fadeTime, {
        point    = origin.point,
        relTo    = origin.relTo,
        relPoint = origin.relPoint,
        startX   = curX or origin.x,
        startY   = curY or origin.y,
        endX     = origin.x + dx,
        endY     = origin.y + dy,
    })
end

-- Starts a slide-back animation returning fadeTarget to its home position.
-- No-op if the frame was never slid.
function addon:RestoreSlide(fadeTarget, fadeTime)
    local origin = slideOrigins[fadeTarget]
    if not origin then return end

    local _, _, _, curX, curY = fadeTarget:GetPoint()
    StartSlideAnimation(fadeTarget, fadeTime, {
        point    = origin.point,
        relTo    = origin.relTo,
        relPoint = origin.relPoint,
        startX   = curX or origin.x,
        startY   = curY or origin.y,
        endX     = origin.x,
        endY     = origin.y,
        onComplete = function()
            fadeTarget:SetClampedToScreen(origin.wasClamped)
            slideOrigins[fadeTarget] = nil
        end,
    })
end
