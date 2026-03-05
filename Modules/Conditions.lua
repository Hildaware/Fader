local addonName, addon = ...

-- Cached condition state for all event-based conditions.
-- Updated by condUpdatesByEvent handlers before any check runs.
local condState = {}

---@type table<string, Condition>
local CONDITIONS = {
    always = {
        label  = 'Always',
        events = {},
        check  = function() return true end,
    },
    inCombat = {
        label   = 'In Combat',
        events  = { 'PLAYER_REGEN_DISABLED', 'PLAYER_REGEN_ENABLED' },
        init    = function() condState.inCombat = InCombatLockdown() and true or false end,
        onEvent = {
            -- Use event-driven state to avoid InCombatLockdown() timing issues
            -- where the API hasn't updated yet when PLAYER_REGEN_DISABLED fires.
            PLAYER_REGEN_DISABLED = function() condState.inCombat = true end,
            PLAYER_REGEN_ENABLED  = function() condState.inCombat = false end,
        },
        check   = function() return condState.inCombat end,
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
        init   = function() condState.isMounted = IsMounted() and true or false end,
        check  = function() return condState.isMounted end,
    },
    inInstance = {
        label  = 'In Instance',
        events = { 'PLAYER_ENTERING_WORLD' },
        init   = function() condState.inInstance = IsInInstance() and true or false end,
        check  = function() return condState.inInstance end,
    },
    inParty = {
        label  = 'In Party',
        events = { 'GROUP_ROSTER_UPDATE' },
        init   = function() condState.inParty = IsInGroup() and not IsInRaid() end,
        check  = function() return condState.inParty end,
    },
    inRaid = {
        label  = 'In Raid',
        events = { 'GROUP_ROSTER_UPDATE' },
        init   = function() condState.inRaid = IsInRaid() and true or false end,
        check  = function() return condState.inRaid end,
    },
    inPetBattle = {
        label   = 'In Pet Battle',
        events  = { 'PET_BATTLE_OPENING_START', 'PET_BATTLE_CLOSE' },
        init    = function() condState.inPetBattle = C_PetBattles.IsInBattle() and true or false end,
        onEvent = {
            PET_BATTLE_OPENING_START = function() condState.inPetBattle = true end,
            PET_BATTLE_CLOSE         = function() condState.inPetBattle = false end,
        },
        check   = function() return condState.inPetBattle end,
    },
    inVehicle = {
        label   = 'In Vehicle',
        events  = { 'UNIT_ENTERED_VEHICLE', 'UNIT_EXITED_VEHICLE' },
        init    = function() condState.inVehicle = UnitInVehicle('player') and true or false end,
        onEvent = {
            UNIT_ENTERED_VEHICLE = function() condState.inVehicle = true end,
            UNIT_EXITED_VEHICLE  = function() condState.inVehicle = false end,
        },
        check   = function() return condState.inVehicle end,
    },
    inBattleground = {
        label  = 'In Battleground',
        events = { 'PLAYER_ENTERING_WORLD' },
        init   = function() condState.inBattleground = select(2, IsInInstance()) == 'pvp' end,
        check  = function() return condState.inBattleground end,
    },
    inArena = {
        label  = 'In Arena',
        events = { 'PLAYER_ENTERING_WORLD' },
        init   = function() condState.inArena = select(2, IsInInstance()) == 'arena' end,
        check  = function() return condState.inArena end,
    },
    hasTarget = {
        label  = 'Has Target',
        events = { 'PLAYER_TARGET_CHANGED' },
        init   = function() condState.hasTarget = UnitExists('target') and true or false end,
        check  = function() return condState.hasTarget end,
    },
    isAFK = {
        label  = 'Is AFK',
        events = { 'PLAYER_FLAGS_CHANGED' },
        init   = function() condState.isAFK = UnitIsAFK('player') and true or false end,
        check  = function() return condState.isAFK end,
    },
}

-- Static index: maps each WoW event to the condState update functions that must run
-- before checking conditions. Built once at module load from the CONDITIONS table.
local condUpdatesByEvent = {}
for _, def in pairs(CONDITIONS) do
    for _, event in ipairs(def.events or {}) do
        if not condUpdatesByEvent[event] then condUpdatesByEvent[event] = {} end
        local fn = (def.onEvent and def.onEvent[event]) or def.init
        if fn then
            condUpdatesByEvent[event][#condUpdatesByEvent[event] + 1] = fn
        end
    end
end

---@return table<string, Condition>
function addon:GetConditionDefs()
    return CONDITIONS
end

---@return table<string, string>
function addon:GetConditionValues()
    local values = {}
    for id, def in pairs(CONDITIONS) do
        values[id] = def.label
    end
    return values
end

function addon:InitConditionState()
    for _, def in pairs(CONDITIONS) do
        if def.init then def.init() end
    end
end

---@param rule       Rule
---@param frameEntry FrameEntry
---@return boolean
local function ConditionsMet(rule, frameEntry)
    for _, condKey in ipairs(rule._active or {}) do
        local def = CONDITIONS[condKey]
        if def and def.check(rule, frameEntry) then return true end
    end
    return false
end

-- ── Runtime frame indexes ──────────────────────────────────────────────────
-- Rebuilt by RebuildIndex() whenever frame settings change.

---@type table<string, FrameEntry[]>
local byEvent         = {}
---@type FrameEntry[]
local byPoll          = {}
---@type FrameEntry[]
local justHideEntries = {}

local pollTicker      = nil

---Cancels the poll ticker if it is running.
function addon:CancelPoll()
    if pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
end

---Rebuilds byEvent, byPoll, justHideEntries, and rule._active from the current
---profile. Also starts or stops the poll ticker as needed. Called from
---Evaluate() (no-event path) and RebuildOptions().
function addon:RebuildIndex()
    wipe(byEvent)
    wipe(byPoll)
    wipe(justHideEntries)

    for _, frameEntry in pairs(self.db.profile.frames) do
        if frameEntry.enabled then
            if frameEntry.justHide then
                justHideEntries[#justHideEntries + 1] = frameEntry
            else
                local hasPoll    = false
                local usedEvents = {}

                for _, rule in ipairs(frameEntry.rules or {}) do
                    rule._active = {}
                    for condKey, enabled in pairs(rule.conditions or {}) do
                        if enabled then
                            rule._active[#rule._active + 1] = condKey
                            local def = CONDITIONS[condKey]
                            if def then
                                if def.poll then
                                    hasPoll = true
                                else
                                    for _, e in ipairs(def.events) do
                                        usedEvents[e] = true
                                    end
                                end
                            end
                        end
                    end
                end

                if hasPoll then byPoll[#byPoll + 1] = frameEntry end

                for event in pairs(usedEvents) do
                    if not byEvent[event] then byEvent[event] = {} end
                    byEvent[event][#byEvent[event] + 1] = frameEntry
                end
            end
        end
    end

    -- Start or stop the poll ticker based on whether any entry needs polling.
    if #byPoll > 0 and not pollTicker then
        pollTicker = C_Timer.NewTicker(0.1, function() addon:EvaluatePolled() end)
    elseif #byPoll == 0 and pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
end

---Evaluates frame entries that have poll-based conditions. Called by the poll ticker.
function addon:EvaluatePolled()
    for _, frameEntry in ipairs(byPoll) do
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

---Re-evaluates frame entries. With an event, updates condState and processes only
---the frames indexed for that event. Without an event (load or options change),
---rebuilds the index and evaluates all enabled frames.
---@param event string? WoW event name, or nil for a full re-evaluation
function addon:Evaluate(event)
    if event then
        -- Update condState for all conditions triggered by this event.
        for _, fn in ipairs(condUpdatesByEvent[event] or {}) do fn() end

        -- justHide frames are re-applied on every event as a defensive measure.
        for _, frameEntry in ipairs(justHideEntries) do
            self:SafeHideFrame(frameEntry)
        end

        for _, frameEntry in ipairs(byEvent[event] or {}) do
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
    else
        -- Full re-evaluation (settings change or initial load).
        self:RebuildIndex()
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
end
