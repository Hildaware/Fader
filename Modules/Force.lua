local addonName, addon = ...

local RegisterUnitWatch = RegisterUnitWatch ---@type fun(frame: Frame, asState: boolean?)

-- ── Permanent hidden parent (never shown) ─────────────────────────────────
-- Frames reparented here cannot be shown by Blizzard's unit-watch system.
local safeHiddenParent = CreateFrame('Frame')
safeHiddenParent:Hide()

-- State tables
local forcedParents       = {} -- [frameName] = { parentFrame, origParent, origPoint, ... }
local safeHiddenFrames    = {} -- [frameName] = { origParent, origPoint, ... }
local hookedOnShow        = {} -- [frame] = true
local reusableParents     = {} -- [frameName] = parentFrame

-- Child bars present on known Blizzard unit frames that re-fire events
-- and need to be silenced when the frame is safe-hidden.
local UNIT_FRAME_CHILDREN = {
    PlayerFrame = { 'healthbar', 'manabar', 'powerBarAlt', 'spellbar' },
    TargetFrame = { 'healthbar', 'manabar', 'spellbar' },
    FocusFrame  = { 'healthbar', 'manabar', 'spellbar' },
    PetFrame    = { 'healthbar', 'manabar' },
}

local function GetManagedFrame(frameName)
    return frameName ~= '' and _G[frameName] or nil
end

-- ── SafeHide ──────────────────────────────────────────────────────────────

---Returns true if the named frame is currently safe-hidden under the hidden parent.
---@param frameName string
---@return boolean
function addon:IsSafeHidden(frameName)
    return safeHiddenFrames[frameName] ~= nil
end

--   UnregisterUnitWatch → Hide → UnregisterAllEvents → SetParent(safeHiddenParent)
--   → OnShow hook → silence child bars
-- This avoids taint from repeated Hide() calls triggered by OnHide scripts.
local function SafeHideFrameName(frameName)
    if frameName == '' then return end
    if safeHiddenFrames[frameName] then return end -- already safe-hidden
    if InCombatLockdown() then return end          -- can't reparent in combat

    local target = GetManagedFrame(frameName)
    if not target then return end

    local origParent                                       = target:GetParent()
    local origPoint, origRelTo, origRelPoint, origX, origY = target:GetPoint()

    pcall(UnregisterUnitWatch, target)
    target:Hide()
    target:UnregisterAllEvents()
    target:SetParent(safeHiddenParent)

    -- Prevent Blizzard's unit-watch or layout code from re-showing this frame.
    if not hookedOnShow[target] then
        target:HookScript('OnShow', function(f)
            if safeHiddenFrames[frameName] and not InCombatLockdown() then f:Hide() end
        end)
        hookedOnShow[target] = true
    end

    -- Silence event-driven child bars on known Blizzard unit frames.
    local children = UNIT_FRAME_CHILDREN[frameName]
    if children then
        for _, field in ipairs(children) do
            local child = target[field]
            if child then pcall(child.UnregisterAllEvents, child) end
        end
    end

    safeHiddenFrames[frameName] = {
        origParent   = origParent,
        origPoint    = origPoint,
        origRelTo    = origRelTo,
        origRelPoint = origRelPoint,
        origX        = origX,
        origY        = origY,
    }
end

-- Restores a safe-hidden frame to its original parent and position.
local function SafeRestoreFrameName(frameName)
    local saved = safeHiddenFrames[frameName]
    if not saved then return end
    if InCombatLockdown() then return end -- can't reparent in combat

    safeHiddenFrames[frameName] = nil

    local target = GetManagedFrame(frameName)
    if not target then return end

    target:SetParent(saved.origParent)
    target:ClearAllPoints()
    if saved.origPoint then
        target:SetPoint(saved.origPoint, saved.origRelTo, saved.origRelPoint, saved.origX, saved.origY)
    end
    pcall(RegisterUnitWatch, target)
    target:Show()
end

---Reparents the entry's frame under the hidden parent so it cannot be shown by Blizzard.
---@param entry FrameEntry
function addon:SafeHideFrame(entry)
    SafeHideFrameName(entry.frameName or '')
end

---Restores the entry's frame to its original parent and position.
---@param entry FrameEntry
function addon:SafeRestoreFrame(entry)
    SafeRestoreFrameName(entry.frameName or '')
end

---Restores a single named frame by name. Called from Options on frame name change.
---@param frameName string
function addon:SafeRestoreFrameName(frameName)
    SafeRestoreFrameName(frameName)
end

-- ── Force (alpha-wrapper) ─────────────────────────────────────────────────

---Returns true if the named frame currently has an active force-wrapper parent.
---@param frameName string
---@return boolean
function addon:IsForced(frameName)
    return forcedParents[frameName] ~= nil
end

---Returns the frame object that alpha/fade operations should target. For forced
---entries this is the wrapper parentFrame; otherwise the named global frame.
---@param entry     FrameEntry
---@param frameName string
---@return Frame?
function addon:GetFadeTarget(entry, frameName)
    if entry.force and forcedParents[frameName] then
        return forcedParents[frameName].parentFrame
    end
    return GetManagedFrame(frameName)
end

-- Reparents a single named frame under a sized wrapper for guaranteed alpha control.
local function ForceFrameName(frameName)
    if frameName == '' then return end
    if forcedParents[frameName] then return end -- already forced

    local target = GetManagedFrame(frameName)
    if not target then return end

    local left, bottom = target:GetLeft(), target:GetBottom()
    if not left or not bottom then return end -- frame not yet on screen

    local origParent                                       = target:GetParent()
    local origPoint, origRelTo, origRelPoint, origX, origY = target:GetPoint()

    local parentFrame                                      = reusableParents[frameName]
    if not parentFrame then
        parentFrame = CreateFrame('Frame', frameName .. 'FaderParent', UIParent)
        reusableParents[frameName] = parentFrame
    end
    parentFrame:Show()
    parentFrame:SetSize(target:GetWidth(), target:GetHeight())
    parentFrame:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMLEFT', left, bottom)

    -- Disable clamping on the original frame so that when the wrapper slides
    -- off-screen, WoW's layout system doesn't push the child back into bounds.
    local origClamped = target:IsClampedToScreen()
    pcall(target.SetClampedToScreen, target, false)

    target:SetParent(parentFrame)
    target:ClearAllPoints()
    target:SetPoint('TOPLEFT', parentFrame, 'TOPLEFT', 0, 0)

    forcedParents[frameName] = {
        parentFrame  = parentFrame,
        origParent   = origParent,
        origPoint    = origPoint,
        origRelTo    = origRelTo,
        origRelPoint = origRelPoint,
        origX        = origX,
        origY        = origY,
        origClamped  = origClamped,
    }
end

-- Reverts a single named forced frame.
local function UnforceFrameName(frameName)
    local forced = forcedParents[frameName]
    if not forced then return end

    local target = GetManagedFrame(frameName)
    if target then
        pcall(target.SetClampedToScreen, target, forced.origClamped)
        target:SetParent(forced.origParent)
        target:ClearAllPoints()
        target:SetPoint(forced.origPoint, forced.origRelTo, forced.origRelPoint, forced.origX, forced.origY)
        target:SetAlpha(1.0)
    end

    forced.parentFrame:Hide()
    forcedParents[frameName] = nil
end

---Reparents the entry's frame under a sized wrapper for guaranteed alpha control.
---@param entry FrameEntry
function addon:ForceFrame(entry)
    ForceFrameName(entry.frameName or '')
end

---Removes the force wrapper and restores the entry's frame to its original parent.
---@param entry FrameEntry
function addon:UnforceFrame(entry)
    UnforceFrameName(entry.frameName or '')
end

---Removes the force wrapper for a frame by name. Called from Options on frame name change.
---@param frameName string
function addon:UnforceFrameName(frameName)
    UnforceFrameName(frameName)
end
