local addonName, addon = ...

-- ── Frame Picker ────────────────────────────────────────────────────────────────

local strataValues = {
    BACKGROUND        = 0,
    LOW               = 1,
    MEDIUM            = 2,
    HIGH              = 3,
    DIALOG            = 4,
    FULLSCREEN        = 5,
    FULLSCREEN_DIALOG = 6,
    TOOLTIP           = 7,
}

local pickerOverlay, pickerTip, pickerList, pickerListButtons, pickerListDismiss

local BLACKLIST = {
    GlobalFXDialogModelScene     = true,
    GlobalFXBackgroundModelScene = true,
    GlobalFXMediumModelScene     = true,
    TimerTracker                 = true,
    MotionSicknessFrame          = true,
    WorldFrame                   = true,
    UIParent                     = true
}

local results = {}
local resultPool = {}

-- Returns all visible named frames under the cursor, sorted topmost first.
-- Uses IsMouseOver() to avoid restricted-region errors (e.g. nameplates in 12.0).
-- All frame API calls are wrapped in pcall to safely skip protected frames.
local function GetAllNamedFramesAtCursor()
    -- Recycle previous results to reduce garbage collection
    for i = #results, 1, -1 do
        resultPool[#resultPool + 1] = results[i]
        results[i] = nil
    end

    local f = EnumerateFrames()
    while f do
        if f ~= pickerOverlay then
            local visOk, vis = pcall(f.IsVisible, f)
            if visOk and vis then
                local overOk, over = pcall(f.IsMouseOver, f)
                ---@diagnostic disable-next-line: param-type-mismatch
                if overOk and not issecretvalue(over) and over then
                    local nameOk, name = pcall(f.GetName, f)
                    if nameOk and name and not BLACKLIST[name] then
                        local strataOk, strata = pcall(f.GetFrameStrata, f)
                        local levelOk, level   = pcall(f.GetFrameLevel, f)
                        local s                = (strataOk and strataValues[strata]) or 2
                        local l                = (levelOk and level) or 0

                        local data             = resultPool[#resultPool]
                        if data then
                            resultPool[#resultPool] = nil
                        else
                            data = {}
                        end
                        data.name = name
                        data.s = s
                        data.l = l

                        results[#results + 1] = data
                    end
                end
            end
        end
        f = EnumerateFrames(f)
    end
    table.sort(results, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return a.l > b.l
    end)
    return results
end

local function HideList()
    if pickerList then pickerList:Hide() end
    if pickerListDismiss then pickerListDismiss:Hide() end
end

-- Shows a popup list of named frames at the cursor position for the user to choose from.
local function ShowFrameList(frameData, onPick)
    if not pickerListDismiss then
        pickerListDismiss = CreateFrame('Frame', nil, UIParent)
        pickerListDismiss:SetAllPoints()
        pickerListDismiss:SetFrameStrata('FULLSCREEN')
        pickerListDismiss:EnableMouse(true)
        pickerListDismiss:SetAlpha(0)
        pickerListDismiss:SetScript('OnMouseDown', HideList)
    end
    pickerListDismiss:Show()

    if not pickerList then
        pickerListButtons = {}
        pickerList = CreateFrame('Frame', nil, UIParent, 'BackdropTemplate')
        pickerList:SetFrameStrata('FULLSCREEN_DIALOG')
        pickerList:SetBackdrop({
            bgFile   = 'Interface\\Tooltips\\UI-Tooltip-Background',
            edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
            edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        pickerList:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        pickerList:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        pickerList:EnableMouse(true)
        pickerList:SetScript('OnMouseDown', function() end) -- consume background clicks
    end

    for _, btn in ipairs(pickerListButtons) do btn:Hide() end

    local btnH  = 18
    local pad   = 6
    local listW = 260

    for i, data in ipairs(frameData) do
        local btn = pickerListButtons[i]
        if not btn then
            btn = CreateFrame('Button', nil, pickerList)
            local hl = btn:CreateTexture(nil, 'HIGHLIGHT')
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.1)
            local lbl = btn:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
            lbl:SetAllPoints()
            lbl:SetJustifyH('LEFT')
            btn.label = lbl
            pickerListButtons[i] = btn
        end
        btn:SetSize(listW - pad * 2, btnH)
        btn:ClearAllPoints()
        btn:SetPoint('TOPLEFT', pickerList, 'TOPLEFT', pad, -pad - (i - 1) * (btnH + 2))
        btn.label:SetText(data.name)
        local name = data.name
        btn:SetScript('OnClick', function()
            HideList()
            onPick(name)
        end)
        btn:Show()
    end

    local listH = pad * 2 + #frameData * (btnH + 2)
    pickerList:SetSize(listW, listH)

    local mx, my = GetCursorPosition()
    local scale  = UIParent:GetEffectiveScale()
    local uiW    = UIParent:GetWidth()
    local uiH    = UIParent:GetHeight()
    local x      = mx / scale + 10
    local y      = my / scale - 10
    -- Horizontal: flip left if list would go off right edge
    if x + listW > uiW then x = mx / scale - listW - 10 end
    -- Vertical: flip upward if list would go off bottom edge
    if y - listH < 0 then y = my / scale + 10 + listH end
    -- Clamp top edge to screen
    if y > uiH then y = uiH end
    pickerList:ClearAllPoints()
    pickerList:SetPoint('TOPLEFT', UIParent, 'BOTTOMLEFT', x, y)
    pickerList:Show()
end

-- Shows a fullscreen overlay that tracks named frames under the cursor.
-- Left-click opens a pick list; right-click or Escape cancels.
function addon:StartFramePicker(onPick)
    if not pickerOverlay then
        pickerOverlay = CreateFrame('Frame', nil, UIParent)
        pickerOverlay:SetAllPoints()
        pickerOverlay:SetFrameStrata('DIALOG')
        pickerOverlay:EnableMouse(true)
        pickerOverlay:EnableKeyboard(true)
        pickerOverlay:SetAlpha(0)

        pickerTip = CreateFrame('Frame', nil, UIParent)
        pickerTip:SetSize(300, 22)
        pickerTip:SetFrameStrata('TOOLTIP')
        local bg = pickerTip:CreateTexture(nil, 'BACKGROUND')
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.8)
        local lbl = pickerTip:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
        lbl:SetAllPoints()
        lbl:SetJustifyH('CENTER')
        pickerTip.label = lbl

        local throttle = 0
        pickerOverlay:SetScript('OnUpdate', function(_, elapsed)
            throttle = throttle + elapsed
            if throttle < 0.05 then return end
            throttle = 0

            if pickerList and pickerList:IsShown() then return end

            local frames = GetAllNamedFramesAtCursor()
            local mx, my = GetCursorPosition()
            local scale  = UIParent:GetEffectiveScale()
            pickerTip:ClearAllPoints()
            pickerTip:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMLEFT', mx / scale + 16, my / scale + 16)
            if #frames > 0 then
                local text = frames[1].name
                if #frames > 1 then text = text .. ' (+' .. (#frames - 1) .. ')' end
                pickerTip.label:SetText(text)
            else
                pickerTip.label:SetText('No named frame')
            end
            pickerTip:Show()
        end)

        pickerOverlay:SetScript('OnMouseDown', function(self, button)
            if button == 'LeftButton' then
                local frames = GetAllNamedFramesAtCursor()
                if #frames > 0 then
                    pickerTip:Hide()
                    self:Hide()
                    ShowFrameList(frames, self._callback)
                end
            else
                pickerTip:Hide()
                self:Hide()
            end
        end)

        pickerOverlay:SetScript('OnKeyDown', function(_, key)
            if key == 'ESCAPE' then
                HideList()
                pickerTip:Hide()
                pickerOverlay:Hide()
            end
        end)
    end

    pickerOverlay._callback = onPick
    pickerOverlay:Show()
end
