local addonName, addon = ...

---@class Fader: AceAddon, AceEvent-3.0, AceConsole-3.0
---@field db AceDBObject-3.0
---@field GetDefaults           fun(self: Fader): table                         -- Modules/Options.lua
---@field HideHighlightOverlay fun(self: Fader)                                -- Modules/Options.lua
---@field GetOptions       fun(self: Fader): string, table                      -- Modules/Options.lua
---@field RebuildOptions   fun(self: Fader)                                     -- Modules/Options.lua
---@field GetConditionDefs fun(self: Fader): table                              -- Modules/Conditions.lua
---@field Evaluate         fun(self: Fader)                                     -- Modules/Conditions.lua
---@field UpdatePoll       fun(self: Fader)                                     -- Modules/Conditions.lua
---@field CancelPoll       fun(self: Fader)                                     -- Modules/Conditions.lua
---@field ApplyRule        fun(self: Fader, frameEntry: table, rule: table)     -- Modules/Fade.lua
---@field RestoreFrame     fun(self: Fader, frameEntry: table)                  -- Modules/Fade.lua
---@field IsSafeHidden        fun(self: Fader, frameName: string): boolean              -- Modules/Force.lua
---@field SafeHideFrame       fun(self: Fader, entry: table)                           -- Modules/Force.lua
---@field SafeRestoreFrame    fun(self: Fader, entry: table)                           -- Modules/Force.lua
---@field SafeRestoreFrameName fun(self: Fader, frameName: string)                     -- Modules/Force.lua
---@field ForceFrame          fun(self: Fader, entry: table)                           -- Modules/Force.lua
---@field UnforceFrame        fun(self: Fader, entry: table)                           -- Modules/Force.lua
---@field UnforceFrameName    fun(self: Fader, frameName: string)                      -- Modules/Force.lua
---@field IsForced            fun(self: Fader, frameName: string): boolean             -- Modules/Force.lua
---@field GetFadeTarget       fun(self: Fader, entry: table, frameName: string): table? -- Modules/Force.lua
---@field StartFramePicker fun(self: Fader, onPick: fun(name: string))          -- Modules/FramePicker.lua
local fader = LibStub('AceAddon-3.0'):NewAddon(addon, addonName, 'AceEvent-3.0', 'AceConsole-3.0')

function fader:OnInitialize()
    self.db = LibStub('AceDB-3.0'):New('FaderDB', { profile = self:GetDefaults() }, true)
    local _, opts = self:GetOptions()
    LibStub('AceConfig-3.0'):RegisterOptionsTable(addonName, opts)
    LibStub('AceConfigDialog-3.0'):AddToBlizOptions(addonName, 'Fader')
    LibStub('AceConfigDialog-3.0'):SetDefaultSize(addonName, 800, 600)
    self:RegisterChatCommand('fader', function()
        local dialog = LibStub('AceConfigDialog-3.0')
        dialog:Open(addonName)
        local frame = dialog.OpenFrames[addonName]
        if frame then
            frame:EnableResize(false)
            -- Hook on the underlying WoW frame so we don't replace AceConfigDialog's
            -- own OnClose callback.  Guard against accumulating hooks on repeat opens.
            if not frame.frame.__faderHighlightHooked then
                frame.frame:HookScript('OnHide', function() self:HideHighlightOverlay() end)
                frame.frame.__faderHighlightHooked = true
            end
        end
    end)
    self:RebuildOptions()
end

function fader:OnEnable()
    -- Restore forced/safe-hidden state from saved settings.
    for _, frameEntry in pairs(self.db.profile.frames) do
        if frameEntry.justHide then self:SafeHideFrame(frameEntry) end
        if frameEntry.force    then self:ForceFrame(frameEntry)    end
    end

    -- Register every event used across all defined conditions (deduplicated).
    local registered = {}
    for _, def in pairs(self:GetConditionDefs()) do
        for _, event in ipairs(def.events) do
            if not registered[event] then
                self:RegisterEvent(event, 'Evaluate')
                registered[event] = true
            end
        end
    end
    self:Evaluate()
end

function fader:OnDisable()
    self:UnregisterAllEvents()
    self:CancelPoll()
    for _, frameEntry in pairs(self.db.profile.frames) do
        self:SafeRestoreFrame(frameEntry)
        self:RestoreFrame(frameEntry)
        if frameEntry.force then self:UnforceFrame(frameEntry) end
    end
end
