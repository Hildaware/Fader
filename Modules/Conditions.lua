local addonName, addon = ...

-- Each condition defines:
--   label  : display name shown in the settings UI
--   events : WoW events that can change this condition's state
--   check  : returns true when condition is met (receives rule, frameEntry)
--   poll   : true if this condition requires continuous polling (no WoW event available)
---@type table<string, Condition>
local CONDITIONS = {
    always = {
        label  = 'Always',
        events = {},
        check  = function() return true end,
    },
    inCombat = {
        label  = 'In Combat',
        events = { 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED' },
        check  = function() return InCombatLockdown() end,
    },
    hovered = {
        label  = 'Hovered',
        events = {},
        poll   = true,
        check  = function(_, frameEntry)
            local frameName = frameEntry.frameName
            if frameName and frameName ~= '' then
                local frame = _G[frameName]
                if frame then
                    local ok, isOver = pcall(frame.IsMouseOver, frame)
                    if ok and isOver then return true end
                end
            end
            return false
        end,
    },
    isMounted = {
        label  = 'Mounted',
        events = { 'PLAYER_MOUNT_DISPLAY_CHANGED' },
        check  = function() return IsMounted() end,
    },
    inInstance = {
        label  = 'In Instance',
        events = { 'PLAYER_ENTERING_WORLD' },
        check  = function() return IsInInstance() end,
    },
    inParty = {
        label  = 'In Party',
        events = { 'GROUP_ROSTER_UPDATE' },
        check  = function() return IsInGroup() and not IsInRaid() end,
    },
    inRaid = {
        label  = 'In Raid',
        events = { 'GROUP_ROSTER_UPDATE' },
        check  = function() return IsInRaid() end,
    },
    inPetBattle = {
        label  = 'In Pet Battle',
        events = { 'PET_BATTLE_OPENING_START', 'PET_BATTLE_CLOSE' },
        check  = function() return C_PetBattles.IsInBattle() end,
    },
    inVehicle = {
        label  = 'In Vehicle',
        events = { 'UNIT_ENTERED_VEHICLE', 'UNIT_EXITED_VEHICLE' },
        check  = function() return UnitInVehicle('player') end,
    },
    inBattleground = {
        label  = 'In Battleground',
        events = { 'PLAYER_ENTERING_WORLD' },
        check  = function() return select(2, IsInInstance()) == 'pvp' end,
    },
    inArena = {
        label  = 'In Arena',
        events = { 'PLAYER_ENTERING_WORLD' },
        check  = function() return select(2, IsInInstance()) == 'arena' end,
    },
    hasTarget = {
        label  = 'Has Target',
        events = { 'PLAYER_TARGET_CHANGED' },
        check  = function() return UnitExists('target') end,
    },
    isAFK = {
        label  = 'Is AFK',
        events = { 'PLAYER_FLAGS_CHANGED' },
        check  = function() return UnitIsAFK('player') end,
    },
}

-- Returns the raw CONDITIONS table (used by OnEnable for event registration).
function addon:GetConditionDefs()
    return CONDITIONS
end

-- Returns a { conditionKey = label } table suitable for an AceConfig select widget.
function addon:GetConditionValues()
    local values = {}
    for id, def in pairs(CONDITIONS) do
        values[id] = def.label
    end
    return values
end

-- Returns true if any of the rule's selected conditions are currently met.
local function ConditionsMet(rule, frameEntry)
    if not rule.conditions then return false end
    for condKey, enabled in pairs(rule.conditions) do
        if enabled then
            local def = CONDITIONS[condKey]
            if def and def.check(rule, frameEntry) then return true end
        end
    end
    return false
end

local pollTicker = nil

function addon:CancelPoll()
    if pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
end

-- Returns true if the frame entry has at least one enabled poll-based condition across any rule.
local function HasPollCondition(frameEntry)
    for _, rule in ipairs(frameEntry.rules or {}) do
        for condKey, enabled in pairs(rule.conditions or {}) do
            if enabled then
                local def = CONDITIONS[condKey]
                if def and def.poll then return true end
            end
        end
    end
    return false
end

-- Starts or stops the poll ticker based on whether any enabled entry has a poll-based condition active.
function addon:UpdatePoll()
    local needsPoll = false
    for _, frameEntry in pairs(self.db.profile.frames) do
        if frameEntry.enabled and HasPollCondition(frameEntry) then
            needsPoll = true
            break
        end
    end

    if needsPoll and not pollTicker then
        pollTicker = C_Timer.NewTicker(0.1, function() addon:EvaluatePolled() end)
    elseif not needsPoll and pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
end

-- Evaluates only frame entries that have poll-based conditions (called by the poll ticker).
function addon:EvaluatePolled()
    for _, frameEntry in pairs(self.db.profile.frames) do
        if frameEntry.enabled and not frameEntry.justHide and HasPollCondition(frameEntry) then
            local matched = nil
            for _, rule in ipairs(frameEntry.rules or {}) do
                if ConditionsMet(rule, frameEntry) then
                    matched = rule
                    break
                end
            end
            if matched then
                self:ApplyRule(frameEntry, matched)
            else
                self:RestoreFrame(frameEntry)
            end
        end
    end
end

-- Re-evaluate every frame entry: walk rules top-to-bottom, apply first match or restore default.
function addon:Evaluate()
    for _, frameEntry in pairs(self.db.profile.frames) do
        if frameEntry.enabled then
            if frameEntry.justHide then
                self:SafeHideFrame(frameEntry)
            else
                local matched = nil
                for _, rule in ipairs(frameEntry.rules or {}) do
                    if ConditionsMet(rule, frameEntry) then
                        matched = rule
                        break
                    end
                end
                if matched then
                    self:ApplyRule(frameEntry, matched)
                else
                    self:RestoreFrame(frameEntry)
                end
            end
        end
    end
end
