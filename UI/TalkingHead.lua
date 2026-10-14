local AddonName, OutLoud = ...

local TalkingHead = {}
OutLoud.UI.TalkingHead = TalkingHead

local INITIAL_SCROLL_DELAY = 10
local SCROLL_PAUSE = 10
local SCROLL_SPEED = 18 -- UI pixels per second, independent of speech duration.
local SCROLL_PAGE_FACTOR = 1.0
local MANUAL_SCROLL_STEP = 24
local TEXT_TOP_OFFSET = 6 -- Space between the speaker name and the text viewport's top.
local TEXT_BOTTOM_OFFSET = 24 -- Space between the text viewport and the frame's bottom.

local function CanAutoScroll(self)
    return self.PlaybackActive and not self.ManualScrollPaused and not self.PendingSentence
        and not self.IsClosing and self.Frame:IsShown()
end

local function AtlasOrFallback(primary, fallback)
    if C_Texture.GetAtlasExists(primary) then
        return primary
    end

    return fallback
end

function TalkingHead:Initialize()
    if self.Initialized then
        return
    end

    -- Only the visual template is copied; no Blizzard Talking Head mixins/events.
    local frame = CreateFrame("Frame", nil, UIParent, "OutLoudTalkingHeadTemplate")
    frame:Hide()
    frame:SetAlpha(1)
    frame:SetSize(570, 155)
    frame:ClearAllPoints()
    frame:SetPoint(
        "TOP",
        UIParent,
        "TOP",
        0,
        -60
    )
    frame:SetScale(1.05)
    frame:SetFrameStrata("BACKGROUND")
    frame:SetFrameLevel(1)

    local main = frame.MainFrame
    local textFrame = frame.TextFrame
    local viewport = textFrame.Scroll
    viewport:SetPoint("TOPLEFT", frame.NameFrame.Name, "BOTTOMLEFT", 0, -TEXT_TOP_OFFSET)
    viewport:SetPoint("BOTTOMRIGHT", textFrame, "BOTTOMRIGHT", -64, TEXT_BOTTOM_OFFSET)
    local dialogText = viewport.Content.Text
    viewport:SetClipsChildren(true)
    viewport:EnableMouseWheel(true)

    -- Methods supplied by Blizzard's native MinimalScrollBar template.
    ---@class OutLoudTalkingHeadScrollBar : EventFrame
    ---@field SetHideIfUnscrollable fun(self: OutLoudTalkingHeadScrollBar, hide: boolean)
    ---@field SetScrollPercentage fun(self: OutLoudTalkingHeadScrollBar, percentage: number, forceImmediate?: boolean)
    ---@field SetVisibleExtentPercentage fun(self: OutLoudTalkingHeadScrollBar, percentage: number)
    ---@field SetPanExtentPercentage fun(self: OutLoudTalkingHeadScrollBar, percentage: number)
    ---@field ScrollStepInDirection fun(self: OutLoudTalkingHeadScrollBar, direction: number)
    ---@field GetThumb fun(self: OutLoudTalkingHeadScrollBar): Button
    ---@field GetTrack fun(self: OutLoudTalkingHeadScrollBar): Frame
    ---@field UnregisterUpdate fun(self: OutLoudTalkingHeadScrollBar)
    local scrollBar = CreateFrame("EventFrame", nil, textFrame, "MinimalScrollBar")
    ---@cast scrollBar OutLoudTalkingHeadScrollBar
    scrollBar:SetPoint("TOPLEFT", viewport, "TOPRIGHT", 8, -4)
    scrollBar:SetPoint("BOTTOMLEFT", viewport, "BOTTOMRIGHT", 8, 10)
    -- Use smaller arrow gaps for this short viewport, keeping the native artwork.
    scrollBar:GetTrack():SetPoint("TOP", scrollBar, "TOP", 0, -12)
    scrollBar:GetTrack():SetPoint("BOTTOM", scrollBar, "BOTTOM", 0, 12)
    scrollBar:SetHideIfUnscrollable(true)
    local name = frame.NameFrame.Name
    name:SetPoint("TOPLEFT", frame.PortraitFrame.Portrait, "TOPRIGHT", 2, -19)
    name:SetShadowColor(0, 0, 0, 0)
    dialogText:SetTextColor(0, 0, 0, 1)
    dialogText:SetShadowColor(0, 0, 0, 0)

    main.CloseButton:SetScript("OnClick", function()
        self:Hide()
        OutLoud.TTS:Stop()
    end)

    local spinner = CreateFrame("Frame", nil, frame, "LoadingSpinnerTemplate")
    spinner:Hide()
    spinner:SetSize(24, 24)
    spinner:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 18)

    self.Frame = frame
    self.Background = frame.BackgroundFrame.TextBackground
    self.Model = main.Model
    self.PortraitBackground = main.Model.PortraitBg
    self.PortraitFrame = frame.PortraitFrame.Portrait
    self.NameText = name
    self.DialogText = dialogText
    self.TextViewport = viewport
    self.TextContent = viewport.Content
    self.TextScrollBar = scrollBar
    self.DialogText:SetWordWrap(true)
    self.CloseButton = main.CloseButton
    self.Spinner = spinner
    self.IsLoading = false

    self.FadeInGroups = {
        main.TalkingHeadsInAnim, frame.NameFrame.Fadein, frame.TextFrame.Fadein,
        frame.BackgroundFrame.Fadein, frame.PortraitFrame.Fadein,
    }
    self.CloseGroups = {
        frame.NameFrame.Close, frame.TextFrame.Close,
        frame.BackgroundFrame.Close, frame.PortraitFrame.Close, main.Close,
    }
    self.AnimationGroups = {}
    for _, group in ipairs(self.FadeInGroups) do
        self.AnimationGroups[#self.AnimationGroups + 1] = group
    end
    for _, group in ipairs(self.CloseGroups) do
        self.AnimationGroups[#self.AnimationGroups + 1] = group
    end
    self.AnimationGroups[#self.AnimationGroups + 1] = textFrame.SentenceOut
    self.AnimationGroups[#self.AnimationGroups + 1] = textFrame.SentenceIn

    viewport:SetScript("OnSizeChanged", function()
        self:UpdateTextLayout()
    end)
    viewport:SetScript("OnShow", function()
        self:UpdateTextLayout()
    end)
    viewport:SetScript("OnVerticalScroll", function(_, offset)
        if not self.SyncingScrollBar then
            self:SetTextScroll(offset)
        end
    end)
    viewport:SetScript("OnMouseWheel", function(_, delta)
        self:PauseAutoScroll()
        scrollBar:ScrollStepInDirection(-delta)
    end)
    scrollBar:RegisterCallback("OnScroll", function(_, percentage)
        -- Native SetScrollPercentage also emits OnScroll for programmatic updates.
        if not self.SyncingScrollBar then
            self:PauseAutoScroll()
            self:SetTextScroll(percentage * (self.ScrollMax or 0))
        end
    end, self)
    scrollBar:GetThumb():HookScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            self:PauseAutoScroll()
        end
    end)
    scrollBar:HookScript("OnHide", function()
        scrollBar:UnregisterUpdate()
    end)
    frame:HookScript("OnHide", function()
        self:StopTextFlow(true)
    end)
    textFrame.SentenceOut:SetScript("OnFinished", function()
        local pending = self.PendingSentence
        if not pending or self.IsClosing then return end
        self.PendingSentence = nil
        self:SetDisplayedText(pending.text)
        self.ManualScrollPaused = pending.manualScrollPaused
        self.PlaybackActive = true
        textFrame.SentenceIn:Play()
        self:StartAutoScroll()
    end)

    self.Decorations = {
        main.Sheen, main.TextSheen, main.Overlay.Glow_TopBar,
        main.Overlay.Glow_LeftBar, main.Overlay.Glow_RightBar,
    }
    self.AnimatedRegions = {
        self.Background, self.Model, self.PortraitBackground, self.PortraitFrame,
        self.NameText, self.DialogText, self.CloseButton,
    }
    for _, region in ipairs(self.Decorations) do
        self.AnimatedRegions[#self.AnimatedRegions + 1] = region
    end

    main.Close:SetScript("OnFinished", function()
        if self.IsClosing then
            self.IsClosing = false
            frame:Hide()
        end
    end)

    self:ResetAnimations()
    self.Initialized = true
end

function TalkingHead:StopAnimations()
    for _, group in ipairs(self.AnimationGroups) do
        group:Stop()
    end
end

function TalkingHead:ResetAnimations()
    -- Clear closing first so a replaced exit cannot hide a new narration.
    self.IsClosing = false
    self:StopTextFlow(true)
    self:StopAnimations()
    self.Frame:SetAlpha(1)
    for _, region in ipairs(self.AnimatedRegions) do
        region:SetAlpha(0.01)
    end
end

function TalkingHead:Show(unit, text, displayTitle)
    if not unit or not UnitExists(unit) then
        self:Hide()
        return
    end

    self:Initialize()
    self:ResetAnimations()

    local faction = UnitFactionGroup(unit)

    local textureKit
    if faction == "Horde" then
        textureKit = "TalkingHeads-Horde"
    elseif faction == "Alliance" then
        textureKit = "TalkingHeads-Alliance"
    else
        textureKit = "TalkingHeads-Neutral"
    end

    self.Background:SetAtlas(
        AtlasOrFallback(
            textureKit .. "-TextBackground",
            "TalkingHeads-TextBackground"
        ),
        true
    )

    self.PortraitBackground:SetAtlas(
        AtlasOrFallback(
            textureKit .. "-PortraitBg",
            "TalkingHeads-PortraitBg"
        ),
        true
    )

    self.PortraitFrame:SetAtlas(
        AtlasOrFallback(
            textureKit .. "-PortraitFrame",
            "TalkingHeads-Alliance-PortraitFrame"
        ),
        true
    )

    self.Model:SetUnit(unit)
    self.Model:SetAnimation(0, 0)

    if self.Model.SetPortraitZoom then
        self.Model:SetPortraitZoom(1)
    end

    if displayTitle == nil then
        displayTitle = UnitName(unit) or "Unknown"
    elseif type(displayTitle) ~= "string" or not displayTitle:find("%S") then
        displayTitle = "Quest"
    end
    self.NameText:SetText(displayTitle)
    local readingMode = OutLoud.Database:GetReadingMode()
    self.DisplayChunk = readingMode == OutLoud.TTS.ReadingModes.SPLIT and 1 or 0
    local displayed = text or ""
    if readingMode == OutLoud.TTS.ReadingModes.SPLIT then
        displayed = OutLoud.TTS:SplitSentences(displayed)[1] or ""
    end
    self:SetDisplayedText(displayed)

    if faction == "Alliance" then
        self.NameText:SetTextColor(0.02, 0.17, 0.33, 1)
    elseif faction == "Horde" then
        self.NameText:SetTextColor(0.28, 0.02, 0.02, 1)
    else
        self.NameText:SetTextColor(0.33, 0.16, 0.02, 1)
    end

    self.Frame:Show()
    for _, group in ipairs(self.FadeInGroups) do
        group:Play()
    end
end

function TalkingHead:StopTextFlow(resetScroll)
    self:StopAutoScroll()
    self.PlaybackActive = false
    self.TextScrollBar:UnregisterUpdate()
    self.Frame.TextFrame.SentenceOut:Stop()
    self.Frame.TextFrame.SentenceIn:Stop()
    self.PendingSentence = nil
    if resetScroll then
        self.ManualScrollPaused = false
        self:SetTextScroll(0)
    end
end

function TalkingHead:SetTextScroll(position)
    local range = self.ScrollMax or 0
    local clamped = math.max(0, math.min(range, position))
    self.ScrollPosition = clamped
    self.SyncingScrollBar = true
    self.TextViewport:SetVerticalScroll(clamped)
    self.TextScrollBar:SetScrollPercentage(
        range > 0 and clamped / range or 0, ScrollBoxConstants.NoScrollInterpolation
    )
    self.SyncingScrollBar = false
end

function TalkingHead:UpdateTextLayout()
    local width = self.TextViewport:GetWidth()
    local height = self.TextViewport:GetHeight()
    if width <= 0 or height <= 0 then return end
    self.DialogText:SetWidth(width)
    self.DialogText:SetHeight(0)
    local textHeight = self.DialogText:GetStringHeight()
    self.DialogText:SetHeight(textHeight)
    self.TextContent:SetSize(width, math.max(height, textHeight))
    self.TextViewport:UpdateScrollChildRect()
    self.ScrollMax = math.max(0, textHeight - height)
    self.SyncingScrollBar = true
    self.TextScrollBar:SetVisibleExtentPercentage(height / math.max(height, textHeight))
    self.TextScrollBar:SetPanExtentPercentage(
        self.ScrollMax > 0 and math.min(1, MANUAL_SCROLL_STEP / self.ScrollMax) or 0
    )
    self.SyncingScrollBar = false
    self:SetTextScroll(self.ScrollPosition or self.TextViewport:GetVerticalScroll())
    if self.ScrollPosition >= self.ScrollMax then
        self:StopAutoScroll()
    elseif not self.AutoScrolling and not self.AutoScrollDelayTimer then
        -- Layout updates must not restart an active page or its pending pause.
        self:StartAutoScroll()
    end
end

function TalkingHead:SetDisplayedText(text)
    self:StopAutoScroll()
    self.TextScrollBar:UnregisterUpdate()
    self.PlaybackActive = false
    self.ManualScrollPaused = false
    self.DialogText:SetText(text)
    self:UpdateTextLayout()
    self:SetTextScroll(0)
end

function TalkingHead:CancelAutoScrollDelay()
    local timer = self.AutoScrollDelayTimer
    self.AutoScrollDelayTimer = nil
    if timer then
        timer:Cancel()
    end
end

function TalkingHead:StopAutoScroll()
    self:CancelAutoScrollDelay()
    if self.TextViewport then
        self.TextViewport:SetScript("OnUpdate", nil)
    end
    self.AutoScrolling = false
end

function TalkingHead:PauseAutoScroll()
    self.ManualScrollPaused = true
    if self.PendingSentence then
        self.PendingSentence.manualScrollPaused = true
    end
    self:StopAutoScroll()
end

function TalkingHead:StartAutoScroll(delay)
    self:StopAutoScroll()
    local viewport = self.TextViewport
    local start = self.ScrollPosition or viewport:GetVerticalScroll()
    if not CanAutoScroll(self)
        or start >= (self.ScrollMax or 0) or viewport:GetHeight() <= 0 then
        return
    end

    local delayTimer
    delayTimer = C_Timer.NewTimer(delay or INITIAL_SCROLL_DELAY, function()
        -- A cancelled/replaced delay must never resume a newer display.
        if self.AutoScrollDelayTimer ~= delayTimer then return end
        self.AutoScrollDelayTimer = nil
        local position = self.ScrollPosition or viewport:GetVerticalScroll()
        if not CanAutoScroll(self)
            or position >= (self.ScrollMax or 0) then
            return
        end

        local pageDistance = viewport:GetHeight() * SCROLL_PAGE_FACTOR
        local target = math.min(position + pageDistance, self.ScrollMax or 0)
        if target <= position then return end

        self.AutoScrolling = true
        viewport:SetScript("OnUpdate", function(_, elapsed)
            if not self.AutoScrolling then return end
            if not CanAutoScroll(self) then
                self:StopAutoScroll()
                return
            end

            local maximum = self.ScrollMax or 0
            local pageTarget = math.min(target, maximum)
            local nextPosition = (self.ScrollPosition or 0) + SCROLL_SPEED * elapsed
            if nextPosition >= pageTarget then
                self:SetTextScroll(pageTarget)
                self:StopAutoScroll()
                if self.ScrollPosition < maximum then
                    self:StartAutoScroll(SCROLL_PAUSE)
                end
                return
            end
            self:SetTextScroll(nextPosition)
        end)
    end)
    self.AutoScrollDelayTimer = delayTimer
end

function TalkingHead:OnTextProgress(text, chunk)
    if not self.Frame or not self.Frame:IsShown() or self.IsClosing then return end
    if chunk < self.DisplayChunk then return end
    if chunk > self.DisplayChunk then
        self.DisplayChunk = chunk
        self.PendingSentence = { text = text }
        self:StopAutoScroll()
        self.TextScrollBar:UnregisterUpdate()
        self.PlaybackActive = false
        self.ManualScrollPaused = false
        local textFrame = self.Frame.TextFrame
        textFrame.Fadein:Stop()
        textFrame.SentenceIn:Stop()
        if not textFrame.SentenceOut:IsPlaying() then
            textFrame.SentenceOut:Play()
        end
    elseif not self.PendingSentence and not self.PlaybackActive then
        -- Quest integration forwards this only for a current owned playback bookmark.
        self.PlaybackActive = true
        self:StartAutoScroll()
    end
end

function TalkingHead:FinishTextPlayback(reason)
    self.Model:SetAnimation(0, 0)
    if reason == "finished" and not self.IsClosing then
        if self.PendingSentence then
            self:SetDisplayedText(self.PendingSentence.text)
        end
        self:UpdateTextLayout()
    end
    self:StopTextFlow(reason ~= "finished")
    if reason == "finished" and not self.IsClosing then
        self.DialogText:SetAlpha(1)
    end
end

function TalkingHead:SetLoading(isLoading)
    self:Initialize()

    self.IsLoading = not not isLoading

    if self.IsLoading then
        self.Spinner:Show()
    else
        self.Spinner:Hide()
    end
end

function TalkingHead:Hide()
    if self.Model then
        self.Model:SetAnimation(0, 0)
    end
    self.IsLoading = false

    if self.Spinner then
        self.Spinner:Hide()
    end

    if not self.Frame or not self.Frame:IsShown() or self.IsClosing then
        return
    end

    self:StopTextFlow(false)
    -- Native Stop resets Scale/Translation effects before the one-second exit.
    self:StopAnimations()
    for _, region in ipairs(self.Decorations) do
        region:SetAlpha(0)
    end
    self.IsClosing = true
    for _, group in ipairs(self.CloseGroups) do
        group:Play()
    end
end
