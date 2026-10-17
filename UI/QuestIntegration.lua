local AddonName, OutLoud = ...

local QuestIntegration = {}
OutLoud.UI.QuestIntegration = QuestIntegration

-- Verified Forever events, also present in Retail source. Only this OnEvent path
-- can start automatic narration; Retail delivery/order requires a client check.
local autoNarrationEvents = {
    QUEST_DETAIL = "GetQuestText",
    QUEST_PROGRESS = "GetProgressText",
    QUEST_COMPLETE = "GetRewardText",
}

-- Panel names shared by both inspected exports; Forever text APIs verified in-game.
local dialoguePanels = {
    {
        name = "QuestFrameDetailPanel", textSource = "GetQuestText",
        rightButton = "QuestFrameDeclineButton", leftButton = "QuestFrameAcceptButton",
    },
    {
        name = "QuestFrameProgressPanel", textSource = "GetProgressText",
        rightButton = "QuestFrameGoodbyeButton", leftButton = "QuestFrameCompleteButton",
    },
    {
        name = "QuestFrameRewardPanel", textSource = "GetRewardText",
        rightButton = "QuestFrameCancelButton", leftButton = "QuestFrameCompleteQuestButton",
    },
}

local function IsUsableVoiceID(voiceID)
    return type(voiceID) == "number" and voiceID >= 0 and voiceID % 1 == 0
end

function QuestIntegration:GetCurrentText()
    if not self.Frame then
        return nil, "quest-frame-unavailable"
    end
    if not self.Frame:IsShown() then
        return nil, "quest-frame-closed"
    end
    if self.GreetingPanel:IsShown() then
        return nil, "greeting-panel-shown"
    end

    local textSource

    for _, panel in ipairs(self.Panels) do
        if panel.frame:IsShown() then
            -- A transition with multiple panels shown has no single speaker text.
            if textSource then
                return nil, "multiple-dialogue-panels-shown"
            end
            textSource = panel.textSource
        end
    end

    if not textSource then
        return nil, "no-dialogue-panel-shown"
    end

    local getter = _G[textSource]
    if type(getter) ~= "function" then
        return nil, "text-api-unavailable: " .. textSource
    end

    local text = getter()
    if type(text) == "string" and text:find("%S") then
        return text, nil, textSource
    end

    return nil, "empty-or-invalid-text: " .. textSource
end

function QuestIntegration:UpdateButtonVisibility()
    if not self.Button then
        return
    end

    local text, _, textSource = self:GetCurrentText()
    if text then
        for _, panel in ipairs(self.Panels) do
            if panel.textSource == textSource then
                self.Button:ClearAllPoints()
                if panel.leftButton and panel.leftButton:IsShown()
                    and panel.rightButton and panel.rightButton:IsShown() then
                    -- Span the gap so its center follows both native buttons.
                    self.ButtonGap:ClearAllPoints()
                    self.ButtonGap:SetPoint("TOPLEFT", panel.leftButton, "TOPRIGHT", 0, 0)
                    self.ButtonGap:SetPoint("BOTTOMRIGHT", panel.rightButton, "BOTTOMLEFT", 0, 0)
                    self.Button:SetPoint("CENTER", self.ButtonGap, "CENTER", 0, 0)
                elseif panel.rightButton and panel.rightButton:IsShown() then
                    self.Button:SetPoint("RIGHT", panel.rightButton, "LEFT", -8, 0)
                elseif panel.leftButton and panel.leftButton:IsShown() then
                    -- Some layouts omit Cancel; auto-accepted offers hide Decline.
                    self.Button:SetPoint("LEFT", panel.leftButton, "RIGHT", 8, 0)
                else
                    self.Button:Hide()
                    return
                end
                self.Button:Show()
                return
            end
        end
    end
    self.Button:Hide()
end

function QuestIntegration:CancelPendingAutoNarration()
    OutLoud.Narration:CancelAutoNarration(self)
end

function QuestIntegration:OnHidden()
    -- Panel/stage changes are not closure of the containing quest dialogue.
    if self.Frame:IsShown() then return end
    OutLoud.Narration:StopSource(self, "quest-closed")
    self:UpdateButtonVisibility()
end

function QuestIntegration:IsAutoNarrationCurrent(request)
    -- This guards activation before capture, never an accepted narration snapshot.
    if not OutLoud.Database:GetAutoNarrateQuests() or GetQuestID() ~= request.questID then
        return false
    end
    local text, _, textSource = self:GetCurrentText()
    return text ~= nil and text == request.text and textSource == request.textSource
end

function QuestIntegration:ScheduleAutoNarration(event)
    self:CancelPendingAutoNarration()
    if not OutLoud.Database:GetAutoNarrateQuests() then return end
    local text, _, textSource = self:GetCurrentText()
    if not text or textSource ~= autoNarrationEvents[event] then return end

    local request = { questID = GetQuestID(), text = text, textSource = textSource }
    OutLoud.Narration:ScheduleAutoNarration(self, request,
        function(pending) return self:IsAutoNarrationCurrent(pending) end,
        function() self:StartCurrentNarration() end)
end

function QuestIntegration:StartCurrentNarration()
    local ok, message = pcall(self.SpeakCurrentText, self)
    if not ok then
        OutLoud:Error("Read failed with Lua error:", tostring(message))
    end
end

function QuestIntegration:SpeakCurrentText()
    self:CancelPendingAutoNarration()
    OutLoud:Debug("Quest narration requested.")
    -- Re-read at narration start; the automatic timer's snapshot is only a guard.
    local text, textReason, textSource = self:GetCurrentText()
    if not text then
        OutLoud:Error("Read stopped:", textReason)
        return
    end
    OutLoud:Debug("Quest text:", textSource, "bytes:", #text)

    local singleVoice = OutLoud.VoiceSelection:IsSingleVoiceMode()
    local displayTitle
    if singleVoice then
        -- Capture the dialogue title now; later quest UI changes cannot replace it.
        displayTitle = type(GetTitleText) == "function" and GetTitleText() or ""
    end

    local speakerUnit = "questnpc"
    local voiceID, info
    if not UnitExists("questnpc") then
        info = { reason = "unit-unavailable" }
    elseif not self.Model then
        info = { reason = "model-unavailable" }
    else
        OutLoud:Debug("Loading questnpc model for:", tostring(UnitName("questnpc")))
        OutLoud.NPCInspection:LoadUnit("questnpc")

        voiceID, info = OutLoud.VoiceSelection:Resolve("questnpc", self.Model)
        OutLoud:Debug("Voice resolution: NPC:", tostring(info.name),
            "ModelFileID:", tostring(info.modelFileID), "Family:", tostring(info.family),
            "UnitSex:", tostring(info.sex), "Gender:", info.gender or "UNKNOWN",
            "Voice:", tostring(voiceID), "Reason:", info.reason or "resolved")
    end

    if not IsUsableVoiceID(voiceID) then
        OutLoud:Debug("NPC voice unavailable; falling back to player:", info.reason or "invalid-voice")
        speakerUnit = "player"
        voiceID, info = OutLoud.VoiceSelection:ResolvePlayer()
        if not IsUsableVoiceID(voiceID) then
            if info.reason == "voice-not-set" then
                OutLoud:Error("Read stopped: choose a player voice in Options for", info.family, info.gender)
            else
                OutLoud:Error("Read stopped: player fallback failed:", info.reason or "invalid-voice")
            end
            return
        end
        OutLoud:Debug("Player fallback resolved:", tostring(info.name),
            "Family:", tostring(info.family), "Gender:", info.gender,
            "Voice:", tostring(voiceID))
    end

    if singleVoice then
        speakerUnit = "player"
    end
    return OutLoud.Narration:Speak(speakerUnit, text, voiceID, displayTitle, "Quest", info.modelFileID, nil, self)
end

function QuestIntegration:Initialize()
    if self.Initialized then
        return
    end

    local frame = rawget(_G, "QuestFrame")
    local greetingPanel = rawget(_G, "QuestFrameGreetingPanel")
    local panels = {}
    local available = frame and greetingPanel

    for _, panel in ipairs(dialoguePanels) do
        local panelFrame = _G[panel.name]
        local rightButton = _G[panel.rightButton]
        local leftButton = _G[panel.leftButton]
        -- Action buttons vary by layout; a missing optional anchor must not
        -- prevent controls from being created for every quest panel.
        available = available and panelFrame
        panels[#panels + 1] = {
            frame = panelFrame, textSource = panel.textSource,
            rightButton = rightButton, leftButton = leftButton,
        }
    end

    if not available then
        -- Do not force-load Blizzard UI or install hooks on an incomplete layout.
        if not self.LoadFrame then
            self.LoadFrame = CreateFrame("Frame")
            self.LoadFrame:RegisterEvent("ADDON_LOADED")
            self.LoadFrame:SetScript("OnEvent", function()
                self:Initialize()
            end)
        end
        return
    end

    self.Frame = frame
    self.GreetingPanel = greetingPanel
    self.Panels = panels

    -- Keep the control on QuestFrame, outside all scrollable content.
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(100, 22)
    button:SetText("Out Loud")
    button:SetScript("OnClick", function()
        self:StartCurrentNarration()
    end)
    self.Button = button
    self.ButtonGap = CreateFrame("Frame", nil, frame)

    self.Model = OutLoud.NPCInspection:GetModel()

    local function Refresh()
        local request = self.PendingAutoNarration
        if request and not self:IsAutoNarrationCurrent(request) then
            self:CancelPendingAutoNarration()
        end
        self:UpdateButtonVisibility()
    end

    -- HookScript runs after Blizzard's own handlers, preserving their behavior.
    frame:HookScript("OnEvent", function(_, event)
        Refresh()
        if autoNarrationEvents[event] then
            self:ScheduleAutoNarration(event)
        end
    end)
    frame:HookScript("OnShow", Refresh)
    frame:HookScript("OnHide", function() self:OnHidden() end)
    greetingPanel:HookScript("OnShow", Refresh)
    greetingPanel:HookScript("OnHide", Refresh)
    for _, panel in ipairs(panels) do
        panel.frame:HookScript("OnShow", Refresh)
        panel.frame:HookScript("OnHide", Refresh)
        if panel.rightButton then
            panel.rightButton:HookScript("OnShow", Refresh)
            panel.rightButton:HookScript("OnHide", Refresh)
        end
        if panel.leftButton then
            panel.leftButton:HookScript("OnShow", Refresh)
            panel.leftButton:HookScript("OnHide", Refresh)
        end
    end

    hooksecurefunc(OutLoud.Database, "SetAutoNarrateQuests", function()
        if not OutLoud.Database:GetAutoNarrateQuests() then
            self:CancelPendingAutoNarration()
        end
    end)
    -- Accepted presentation requests replace the delay before TTS submission exists.
    hooksecurefunc(OutLoud.Narration, "Speak", function()
        self:CancelPendingAutoNarration()
    end)
    hooksecurefunc(OutLoud.Narration, "Stop", function()
        self:CancelPendingAutoNarration()
    end)
    -- Direct TTS has no presentation request, so retain its session hook.
    hooksecurefunc(OutLoud.TTS, "StartSession", function()
        self:CancelPendingAutoNarration()
    end)

    self.Initialized = true
    if self.LoadFrame then
        self.LoadFrame:UnregisterEvent("ADDON_LOADED")
        self.LoadFrame:SetScript("OnEvent", nil)
    end
    self:UpdateButtonVisibility()
end
