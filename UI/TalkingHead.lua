local AddonName, OutLoud = ...

local TalkingHead = { State = "Closed" }
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
        and self.State == "Opened" and self.Frame:IsShown()
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
    ---@field Back Button
    ---@field Forward Button
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
        OutLoud.Narration:Stop(nil, "Talking Head close")
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
        if self.State ~= "Opening" and self.State ~= "Opened" then return end
        self:PauseAutoScroll()
        scrollBar:ScrollStepInDirection(-delta)
    end)
    scrollBar:RegisterCallback("OnScroll", function(_, percentage)
        -- Native SetScrollPercentage also emits OnScroll for programmatic updates.
        if not self.SyncingScrollBar and (self.State == "Opening" or self.State == "Opened") then
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
        self:SetScrollInteractionEnabled(false)
        self:StopTextFlow(true)
        if self.State ~= "Closed" then
            -- An external Hide must also invalidate an unfinished entrance.
            self.State, self.Transition = "Closed", nil
            main.TalkingHeadsInAnim:SetScript("OnFinished", nil)
            main.Close:SetScript("OnFinished", nil)
            self:StopAnimations()
            self:SetLoading(false)
            OutLoud.Narration:Stop(nil, "Talking Head hidden")
        end
    end)
    self.Decorations = {
        main.Sheen, main.TextSheen, main.Overlay.Glow_TopBar,
        main.Overlay.Glow_LeftBar, main.Overlay.Glow_RightBar,
    }
    self.AnimatedRegions = {
        self.Background, self.Model, self.PortraitBackground, self.PortraitFrame,
        self.NameText, self.CloseButton,
    }
    for _, region in ipairs(self.Decorations) do
        self.AnimatedRegions[#self.AnimatedRegions + 1] = region
    end

    self:ResetAnimations()
    self.Initialized = true
end

function TalkingHead:SetScrollInteractionEnabled(enabled)
    self.TextViewport:EnableMouseWheel(enabled)
    local scrollBar = self.TextScrollBar
    scrollBar:EnableMouseWheel(enabled)
    scrollBar:GetTrack():EnableMouse(enabled)
    scrollBar:GetThumb():EnableMouse(enabled)
    scrollBar.Back:EnableMouse(enabled)
    scrollBar.Forward:EnableMouse(enabled)
    if not enabled then scrollBar:UnregisterUpdate() end
end

function TalkingHead:StopAnimations()
    for _, group in ipairs(self.AnimationGroups) do
        group:Stop()
    end
end

function TalkingHead:ResetAnimations()
    self:StopTextFlow(true)
    self:StopAnimations()
    self.Frame:SetAlpha(1)
    self.Frame.TextFrame:SetAlpha(0)
    self:SetScrollInteractionEnabled(false)
    for _, region in ipairs(self.AnimatedRegions) do
        region:SetAlpha(0.01)
    end
end

function TalkingHead:Show(speaker, text, onOpening)
    self:Initialize()
    if self.State ~= "Closed" then return false, "talking-head-busy" end

    self:ResetAnimations()
    local transition = {}
    self.State, self.Transition = "Opening", transition
    self.Frame.MainFrame.TalkingHeadsInAnim:SetScript("OnFinished", function()
        if self.State ~= "Opening" or self.Transition ~= transition then return end
        self.State = "Opened"
        self.Frame.MainFrame.TalkingHeadsInAnim:SetScript("OnFinished", nil)
        local progress = self.OpeningProgress
        self.OpeningProgress = nil
        if progress then self:OnTextProgress(progress.text, progress.chunk) end
    end)

    local faction = speaker.faction

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

    self.Model:ClearModel()
    if speaker.unit == "player" then
        -- Player identity is stable; never look up a live questnpc/npc after capture.
        self.Model:SetUnit("player")
    elseif type(speaker.modelFileID) == "number" and speaker.modelFileID > 0 then
        -- Render the captured asset, even if the original NPC token has changed.
        local ok, message = pcall(self.Model.SetModel, self.Model, speaker.modelFileID)
        if not ok then OutLoud:Debug("Talking Head snapshot portrait unavailable:", tostring(message)) end
    end
    self.Model:SetAnimation(0, 0)

    if self.Model.SetPortraitZoom then
        self.Model:SetPortraitZoom(1)
    end

    self.NameText:SetText(speaker.name)
    self:PrepareText(text)

    if faction == "Alliance" then
        self.NameText:SetTextColor(0.02, 0.17, 0.33, 1)
    elseif faction == "Horde" then
        self.NameText:SetTextColor(0.28, 0.02, 0.02, 1)
    else
        self.NameText:SetTextColor(0.33, 0.16, 0.02, 1)
    end

    self.Frame:Show()
    if self.State ~= "Opening" or self.Transition ~= transition then return true end
    self:SetLoading(true)
    self:SetScrollInteractionEnabled(true)
    for _, group in ipairs(self.FadeInGroups) do
        group:Play()
    end
    if self.State == "Opening" and self.Transition == transition and onOpening then
        onOpening(transition)
    end
    return true
end

function TalkingHead:PrepareText(text)
    self.DisplayChunk = 1
    self:SetDisplayedText(OutLoud.TTS:SplitSentences(text or "")[1] or "")
end

function TalkingHead:StopTextFlow(resetScroll)
    self:StopAutoScroll()
    self.PlaybackActive = false
    self.TextScrollBar:UnregisterUpdate()
    self.PendingSentence, self.OpeningProgress, self.SentenceTransition = nil, nil, nil
    self.Frame.TextFrame.SentenceOut:SetScript("OnFinished", nil)
    self.Frame.TextFrame.SentenceOut:Stop()
    self.Frame.TextFrame.SentenceIn:Stop()
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
    if self.State == "Opening" then
        -- Preserve the entrance fades while speech/bookmarks can already progress.
        self.OpeningProgress = { text = text, chunk = chunk }
        return
    end
    if not self.Frame or not self.Frame:IsShown() or self.State ~= "Opened" then return end
    if chunk < self.DisplayChunk then return end
    if chunk > self.DisplayChunk then
        self.DisplayChunk = chunk
        self.PendingSentence = { text = text }
        self:StopAutoScroll()
        self.TextScrollBar:UnregisterUpdate()
        self.PlaybackActive = false
        self.ManualScrollPaused = false
        local textFrame = self.Frame.TextFrame
        if not textFrame.SentenceOut:IsPlaying() then
            local alpha = textFrame:GetAlpha()
            textFrame.Fadein:Stop()
            textFrame.SentenceIn:Stop()
            textFrame:SetAlpha(alpha)
            textFrame.SentenceOut.Alpha:SetFromAlpha(alpha)
            local transition, sentenceTransition = self.Transition, {}
            self.SentenceTransition = sentenceTransition
            textFrame.SentenceOut:SetScript("OnFinished", function()
                if self.State ~= "Opened" or self.Transition ~= transition
                    or self.SentenceTransition ~= sentenceTransition then return end
                self.SentenceTransition = nil
                textFrame.SentenceOut:SetScript("OnFinished", nil)
                local pending = self.PendingSentence
                if not pending then return end
                self.PendingSentence = nil
                self:SetDisplayedText(pending.text)
                self.ManualScrollPaused = pending.manualScrollPaused
                self.PlaybackActive = true
                textFrame:SetAlpha(0)
                textFrame.SentenceIn:Play()
                self:StartAutoScroll()
            end)
            textFrame.SentenceOut:Play()
        end
    elseif not self.PendingSentence and not self.PlaybackActive then
        -- Narration forwards this only for a current owned playback bookmark.
        self.PlaybackActive = true
        self:StartAutoScroll()
    end
end

function TalkingHead:FinishTextPlayback(reason)
    self.Model:SetAnimation(0, 0)
    if reason == "finished" and self.State == "Opened" then
        if self.PendingSentence then
            self:SetDisplayedText(self.PendingSentence.text)
        end
        self:UpdateTextLayout()
    end
    local textFrame = self.Frame.TextFrame
    local alpha = textFrame:GetAlpha()
    self:StopTextFlow(reason ~= "finished")
    textFrame:SetAlpha(alpha)
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

function TalkingHead:Hide(reason, diagnosticTrigger)
    if self.State == "Closed" or self.State == "Closing" then return end
    local transition = {}
    self.State, self.Transition = "Closing", transition
    self:SetScrollInteractionEnabled(false)
    self.Frame.MainFrame.TalkingHeadsInAnim:SetScript("OnFinished", nil)
    -- Invalidate opening first; native STOP may synchronously emit playback events.
    OutLoud.Narration:OnClosing(reason, diagnosticTrigger)
    if self.State ~= "Closing" or self.Transition ~= transition then return end
    if self.Model then
        self.Model:SetAnimation(0, 0)
    end
    self.IsLoading = false

    if self.Spinner then
        self.Spinner:Hide()
    end

    local textFrame = self.Frame.TextFrame
    local alpha = textFrame:GetAlpha()
    self:StopTextFlow(reason ~= "finished")
    -- Native Stop resets Scale/Translation effects before the one-second exit.
    self:StopAnimations()
    textFrame:SetAlpha(alpha)
    textFrame.Close.Alpha:SetFromAlpha(alpha)
    for _, region in ipairs(self.Decorations) do
        region:SetAlpha(0)
    end
    self.Frame.MainFrame.Close:SetScript("OnFinished", function()
        if self.State ~= "Closing" or self.Transition ~= transition then return end
        self.State, self.Transition = "Closed", nil
        self.Frame.MainFrame.Close:SetScript("OnFinished", nil)
        self.Frame:Hide()
        OutLoud.Narration:OnClosed()
    end)
    for _, group in ipairs(self.CloseGroups) do
        group:Play()
    end
end
