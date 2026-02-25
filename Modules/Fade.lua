local addonName, addon = ...

-- Tracks the fadeTime from the most recently applied rule per frame name.
-- Used to match restore speed to the fade that preceded it.
local lastFadeTime = {}

-- Tracks active timers for forced visibility to prevent race conditions.
local fadeTimers = {}

local function FadeFrame(frame, fadeTime, targetAlpha)
    if targetAlpha > 0 then
        frame:Show()
    end
    UIFrameFadeOut(frame, fadeTime, frame:GetAlpha(), targetAlpha)
end

local function HandleForcedVisibility(self, frameName, fadeTime, targetAlpha)
    if not self:IsForced(frameName) then return end

    local entryFrame = _G[frameName]
    if not entryFrame then return end

    -- Cancel any pending hide timer for this frame to avoid race conditions
    if fadeTimers[frameName] then
        fadeTimers[frameName]:Cancel()
        fadeTimers[frameName] = nil
    end

    if targetAlpha == 0 then
        fadeTimers[frameName] = C_Timer.NewTimer(fadeTime, function()
            entryFrame:Hide()
            fadeTimers[frameName] = nil
        end)
    else
        entryFrame:Show()
    end
end

-- Applies a matched rule's fade to the frame entry's named frame.
function addon:ApplyRule(frameEntry, rule)
    if not frameEntry.enabled then return end
    local frameName = frameEntry.frameName
    if not frameName or frameName == '' then return end

    local frame = self:GetFadeTarget(frameEntry, frameName)
    if not frame then return end

    local targetAlpha = rule.targetAlpha / 100
    FadeFrame(frame, rule.fadeTime, targetAlpha)
    lastFadeTime[frameName] = rule.fadeTime

    HandleForcedVisibility(self, frameName, rule.fadeTime, targetAlpha)
end

-- Restores the frame to its defaultAlpha (no rule currently matched).
function addon:RestoreFrame(frameEntry)
    local frameName = frameEntry.frameName
    if not frameName or frameName == '' then return end

    local frame = self:GetFadeTarget(frameEntry, frameName)
    if not frame then return end

    local alpha    = (frameEntry.defaultAlpha or 100) / 100
    local fadeTime = lastFadeTime[frameName] or 0.3
    FadeFrame(frame, fadeTime, alpha)

    HandleForcedVisibility(self, frameName, fadeTime, alpha)
end
