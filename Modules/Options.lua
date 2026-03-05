local addonName, addon = ...

-- ── Options ────────────────────────────────────────────────────────────────────

local frameArgs -- holds the live args table for dynamic rebuilding

-- ── Frame Highlights ─────────────────────────────────────────────────────────

local highlightEnabled = true
local overlay          = nil -- single shared overlay frame, created lazily

local function GetOverlay()
    if overlay then return overlay end
    overlay = CreateFrame('Frame', nil, UIParent)
    overlay:SetFrameStrata('TOOLTIP')
    overlay:Hide()
    local tex = overlay:CreateTexture(nil, 'BACKGROUND')
    tex:SetAllPoints()
    tex:SetColorTexture(0, 1, 0, 0.35)
    return overlay
end

local function ShowHighlightForEntry(id)
    local entry = addon.db.profile.frames[id]
    if not entry then
        if overlay then overlay:Hide() end
        return
    end
    local frameName = entry.frameName
    if not frameName or frameName == '' then
        if overlay then overlay:Hide() end
        return
    end
    local target = _G[frameName]
    if not target then
        if overlay then overlay:Hide() end
        return
    end
    local ov = GetOverlay()
    local ok = pcall(function()
        ov:ClearAllPoints()
        ov:SetAllPoints(target)
    end)
    if ok then ov:Show() end
end

function addon:HideHighlightOverlay()
    if overlay then overlay:Hide() end
end

-- Builds the args table for a single rule row inside a frame entry.
local function BuildRuleArgs(frameId, ruleIndex, totalRules)
    local function rule() return addon.db.profile.frames[frameId].rules[ruleIndex] end
    return {
        conditions = {
            name          = 'When',
            desc          = 'Fade is applied when any selected condition is met. You can select multiple conditions.',
            type          = 'multiselect',
            dialogControl = 'Dropdown',
            order         = 1,
            values        = function() return addon:GetConditionValues() end,
            get           = function(_, key)
                local conds = rule().conditions
                return conds and conds[key] or false
            end,
            set           = function(_, key, value)
                rule().conditions[key] = value or nil
                addon:Evaluate()
            end,
        },
        targetAlpha = {
            name  = 'Fade To',
            desc  = 'Alpha when this rule matches (0 = invisible, 100 = fully opaque).',
            type  = 'range',
            order = 2,
            min   = 0,
            max   = 100,
            step  = 1,
            get   = function() return rule().targetAlpha end,
            set   = function(_, value) rule().targetAlpha = value end,
        },
        fadeTime = {
            name  = 'Over (seconds)',
            desc  = 'Duration of the fade animation in seconds.',
            type  = 'range',
            order = 3,
            min   = 0.0,
            max   = 5.0,
            step  = 0.1,
            get   = function() return rule().fadeTime end,
            set   = function(_, value) rule().fadeTime = value end,
        },
        slideEnabled = {
            name  = 'Slide',
            desc  = 'Also slide the frame in a direction while fading.',
            type  = 'toggle',
            order = 4,
            get   = function() return rule().slideEnabled end,
            set   = function(_, v) rule().slideEnabled = v or nil end,
        },
        slideDirection = {
            name   = 'Direction',
            type   = 'select',
            order  = 5,
            hidden = function() return not rule().slideEnabled end,
            values = { left = 'Left', right = 'Right', up = 'Up', down = 'Down' },
            get    = function() return rule().slideDirection or 'left' end,
            set    = function(_, v) rule().slideDirection = v end,
        },
        slideDistance = {
            name   = 'Distance (px)',
            type   = 'range',
            order  = 6,
            hidden = function() return not rule().slideEnabled end,
            min    = 10,
            max    = 500,
            step   = 5,
            get    = function() return rule().slideDistance or 100 end,
            set    = function(_, v) rule().slideDistance = v end,
        },
        moveUp = {
            name   = 'Move Up',
            type   = 'execute',
            order  = 7,
            hidden = function() return ruleIndex <= 1 end,
            func   = function()
                local rules = addon.db.profile.frames[frameId].rules
                rules[ruleIndex], rules[ruleIndex - 1] = rules[ruleIndex - 1], rules[ruleIndex]
                addon:RebuildOptions()
            end,
        },
        moveDown = {
            name   = 'Move Down',
            type   = 'execute',
            order  = 8,
            hidden = function() return ruleIndex >= totalRules end,
            func   = function()
                local rules = addon.db.profile.frames[frameId].rules
                rules[ruleIndex], rules[ruleIndex + 1] = rules[ruleIndex + 1], rules[ruleIndex]
                addon:RebuildOptions()
            end,
        },
        removeRule = {
            name  = 'Remove Rule',
            type  = 'execute',
            order = 9,
            func  = function()
                table.remove(addon.db.profile.frames[frameId].rules, ruleIndex)
                addon:RebuildOptions()
            end,
        },
    }
end

-- Builds the args table for a single frame entry (frame-level fields + rules sub-list).
local function BuildFrameEntryArgs(id)
    local function cfg() return addon.db.profile.frames[id] end

    local args = {
        copyFrom = {
            name   = 'Copy Settings',
            desc   = 'Copy all settings & rules from another entry.',
            type   = 'select',
            order  = 4,
            width  = 'normal',
            values = function()
                local vals = {}
                for otherId, entry in pairs(addon.db.profile.frames) do
                    if otherId ~= id then
                        vals[otherId] = (entry.frameName ~= '' and entry.frameName) or '(no frame)'
                    end
                end
                return vals
            end,
            get    = function() return nil end,
            set    = function(_, sourceId)
                local source = addon.db.profile.frames[sourceId]
                if not source then return end
                local dest        = cfg()
                dest.enabled      = source.enabled
                dest.defaultAlpha = source.defaultAlpha
                dest.justHide     = source.justHide
                dest.force        = source.force
                dest.rules        = {}
                for i, rule in ipairs(source.rules) do
                    local copy = { conditions = {}, targetAlpha = rule.targetAlpha, fadeTime = rule.fadeTime }
                    for k, v in pairs(rule.conditions or {}) do copy.conditions[k] = v end
                    dest.rules[i] = copy
                end
                addon:RebuildOptions()
                addon:Evaluate()
            end,
        },
        frameName = {
            name  = 'Frame',
            desc  = 'Global name of the WoW frame to fade (e.g. Minimap).',
            type  = 'input',
            order = 1,
            get   = function() return cfg().frameName end,
            set   = function(_, value)
                local old = cfg().frameName
                if old and old ~= '' then addon:UnforceFrameName(old) end
                cfg().frameName = value
                LibStub('AceConfigRegistry-3.0'):NotifyChange(addonName)
            end,
        },
        pickFrame = {
            name  = 'Select Frame',
            desc  =
            'Hover over a frame and click to set it. Left-click shows all named frames under the cursor. Right-click or Escape cancels.',
            type  = 'execute',
            order = 2,
            func  = function()
                addon:StartFramePicker(function(frameName)
                    local old = cfg().frameName
                    if old and old ~= '' then addon:UnforceFrameName(old) end
                    cfg().frameName = frameName
                    addon:RebuildOptions()
                end)
            end,
        },
        spacer = {
            name  = '',
            type  = 'description',
            order = 3,
        }
    }

    local rulesArgs = {
        addRule = {
            name  = 'Add Rule',
            type  = 'execute',
            order = 1,
            func  = function()
                local rules = cfg().rules
                rules[#rules + 1] = {
                    conditions  = { inCombat = true },
                    targetAlpha = 50,
                    fadeTime    = 0.5,
                }
                addon:RebuildOptions()
            end,
        },
        force = {
            name  = 'Brute Force',
            desc  = "Useful if you can't get the frame to fade / hide properly. MIGHT work in certain circumstances.",
            type  = 'toggle',
            order = 2,
            get   = function() return cfg().force end,
            set   = function(_, value)
                cfg().force = value
                if value then addon:ForceFrame(cfg()) else addon:UnforceFrame(cfg()) end
                addon:Evaluate()
            end,
        },
    }

    local rules = cfg() and cfg().rules or {}
    local ruleCount = #rules
    for i = 1, ruleCount do
        if i > 1 then
            rulesArgs['rulesep_' .. i] = {
                name  = '',
                type  = 'header',
                order = 10 + i - 0.5,
                width = 'half',
            }
        end
        rulesArgs['rule_' .. i] = {
            name   = '',
            type   = 'group',
            order  = 10 + i,
            inline = true,
            args   = BuildRuleArgs(id, i, ruleCount),
        }
    end

    -- When this entry's page is selected, AceConfig calls name() for every
    -- visible widget in it.  The sentinel below fires ShowHighlightForEntry so
    -- the overlay tracks whichever entry is currently open in the tree.
    args._highlight = {
        name   = function()
            if highlightEnabled then ShowHighlightForEntry(id) end
            return ''
        end,
        type   = 'description',
        order  = 0,
        width  = 'full',
        hidden = function() return not highlightEnabled end,
    }

    args.settingsGroup = {
        name   = 'Settings',
        type   = 'group',
        order  = 5,
        inline = true,
        args   = {
            defaultAlpha = {
                name  = 'Fallback Alpha',
                desc  = 'Alpha when no rule matches (0 = invisible, 100 = fully opaque).',
                type  = 'range',
                order = 1,
                min   = 0,
                max   = 100,
                step  = 1,
                get   = function() return cfg().defaultAlpha end,
                set   = function(_, value) cfg().defaultAlpha = value end,
            },
            _spacer = {
                name  = '',
                type  = 'description',
                order = 2,
            },
            justHide = {
                name  = '|cffFF8000Just Hide It|r',
                desc  = 'Completely hides the frame, ignoring all rules.',
                type  = 'toggle',
                order = 3,
                get   = function() return cfg().justHide end,
                set   = function(_, value)
                    cfg().justHide = value
                    if not value then
                        addon:SafeRestoreFrame(cfg())
                    end
                    addon:Evaluate()
                end,
            },
        },
    }

    args.rulesGroup = {
        name   = 'Rules  (first match wins)',
        type   = 'group',
        order  = 7,
        inline = true,
        hidden = function() return cfg().justHide end,
        args   = rulesArgs,
    }

    args.remove = {
        name  = 'Delete',
        desc  = 'Remove the Frame from being modified by Fader',
        type  = 'execute',
        order = 8,
        func  = function()
            local entry = cfg()
            if overlay then overlay:Hide() end
            addon:SafeRestoreFrame(entry)
            addon:UnforceFrame(entry)
            addon:RestoreFrame(entry)
            addon.db.profile.frames[id] = nil
            addon:RebuildOptions()
        end,
    }

    return args
end

function addon:GetDefaults()
    return {
        frames = {},
        -- [id] = { enabled, frameName, defaultAlpha, force, rules }
        -- rule  = { conditions, targetAlpha, fadeTime }
    }
end

function addon:GetOptions()
    frameArgs = {
        description = {
            name  = 'Add or Select a Frame to be modified by Fader.',
            type  = 'description',
            order = 1,
        },
        addButton = {
            name  = 'Manual Add',
            desc  = 'Add a new Frame to be modified by Fader.',
            type  = 'execute',
            order = 3,
            func  = function()
                local id = tostring(GetTime())
                addon.db.profile.frames[id] = {
                    enabled      = true,
                    frameName    = '',
                    defaultAlpha = 100,
                    force        = false,
                    rules        = {
                        { conditions = { inCombat = true }, targetAlpha = 50, fadeTime = 0.5 },
                    },
                }
                addon:RebuildOptions()
            end,
        },
        pickButton = {
            name  = 'Select Frame',
            desc  =
            'Hover over any UI frame and click to create a new entry for it. Left-click opens a list of named frames under the cursor. Right-click or Escape cancels.',
            type  = 'execute',
            order = 2,
            func  = function()
                addon:StartFramePicker(function(frameName)
                    local id = tostring(GetTime())
                    addon.db.profile.frames[id] = {
                        enabled      = true,
                        frameName    = frameName,
                        defaultAlpha = 100,
                        force        = false,
                        rules        = {
                            { conditions = { inCombat = true }, targetAlpha = 50, fadeTime = 0.5 },
                        },
                    }
                    addon:RebuildOptions()
                end)
            end,
        },
        highlight = {
            name  = 'Highlight',
            desc  = 'When checked, shows a green overlay on whichever frame entry is currently selected.',
            type  = 'toggle',
            order = 4,
            get   = function() return highlightEnabled end,
            set   = function(_, value)
                highlightEnabled = value
                if not value and overlay then overlay:Hide() end
                LibStub('AceConfigRegistry-3.0'):NotifyChange(addonName)
            end,
        },
    }
    return 'fader', {
        name = 'Fader',
        type = 'group',
        args = frameArgs,
    }
end

function addon:RebuildOptions()
    for key in pairs(frameArgs) do
        if key ~= 'description' and key ~= 'addButton' and key ~= 'pickButton' and key ~= 'highlight' then
            frameArgs[key] = nil
        end
    end

    local sorted = {}
    for id in pairs(addon.db.profile.frames) do sorted[#sorted + 1] = id end
    table.sort(sorted, function(a, b)
        local ea, eb = addon.db.profile.frames[a], addon.db.profile.frames[b]
        return (ea.frameName or '') < (eb.frameName or '')
    end)

    for i, id in ipairs(sorted) do
        frameArgs['entry_' .. id] = {
            name  = function()
                local e = addon.db.profile.frames[id]
                if not e then return '(removed)' end
                return (e.frameName ~= '' and e.frameName) or '(no frame)'
            end,
            type  = 'group',
            order = 10 + i,
            args  = BuildFrameEntryArgs(id),
        }
    end

    addon:UpdatePoll()
    LibStub('AceConfigRegistry-3.0'):NotifyChange(addonName)
end
