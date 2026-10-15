local AddonName, OutLoud = ...

local QuestLogIntegration = {}
OutLoud.UI.QuestLogIntegration = QuestLogIntegration

function QuestLogIntegration:GetCurrentText()
    if not self.Frame or not self.Frame:IsVisible() then
        return nil, "quest-log-closed"
    end
    if not self.DetailsFrame:IsVisible() or not self.TextScrollFrame:IsVisible()
        or not self.BackButton:IsVisible() then
        return nil, "quest-log-details-hidden"
    end

    local questID = C_QuestLog.GetSelectedQuest()
    if type(questID) ~= "number" or questID <= 0 or questID % 1 ~= 0 then
        return nil, "no-selected-quest"
    end
    if self.DetailsFrame.questID ~= questID then
        return nil, "selected-quest-not-displayed"
    end
    local questIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    if type(questIndex) ~= "number" or questIndex <= 0 or questIndex % 1 ~= 0 then
        return nil, "quest-log-index-unavailable"
    end

    -- Forever's verified API: use only the first return value, never objectives.
    local description = GetQuestLogQuestText(questIndex)
    if type(description) ~= "string" or not description:find("%S") then
        return nil, "quest-description-unavailable"
    end
    return description, nil, questID
end

function QuestLogIntegration:UpdateButtonVisibility()
    if not self.Button then return end
    local description = self:GetCurrentText()
    if not description then
        self.Button:Hide()
        return
    end

    -- Mirror Back's native LEFT anchor in BackFrame (11, 4 in the local XML).
    local _, _, _, inset, offsetY = self.BackButton:GetPoint(1)
    self.Button:ClearAllPoints()
    self.Button:SetPoint("RIGHT", self.Header, "RIGHT", -inset, offsetY)
    self.Button:Show()
end

function QuestLogIntegration:SpeakCurrentText()
    local description, reason, questID = self:GetCurrentText()
    if not description then
        OutLoud:Error("Quest Log read stopped:", reason)
        return
    end

    -- Use the ID captured with the description, independent of later selection changes.
    local displayTitle = type(C_QuestLog.GetTitleForQuestID) == "function"
        and C_QuestLog.GetTitleForQuestID(questID) or ""
    local voiceID, info = OutLoud.VoiceSelection:ResolvePlayer()
    if voiceID == nil then
        if info.reason == "voice-not-set" then
            OutLoud:Error("Quest Log read stopped: choose a voice in Options for", info.family, info.gender)
        elseif info.reason == "unknown-player-race" then
            OutLoud:Error("Quest Log read stopped: unmapped player race:", tostring(info.raceToken))
        else
            OutLoud:Error("Quest Log read stopped:", info.reason)
        end
        return
    end

    return OutLoud.Narration:Speak("player", description, voiceID, displayTitle, "Quest Log")
end

function QuestLogIntegration:Initialize()
    if self.Initialized then return end

    -- The Forever/Camelot TOC loads the shared Mainline QuestMapFrame layout.
    local frame = rawget(_G, "QuestMapFrame")
    local details = frame and frame.DetailsFrame
    local header = details and details.BackFrame
    local back = header and header.BackButton
    local scroll = details and details.ScrollFrame
    if not frame or not details or not header or not back or not scroll
        or type(QuestMapFrame_ShowQuestDetails) ~= "function"
        or type(QuestMapFrame_CloseQuestDetails) ~= "function" then
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
    self.DetailsFrame = details
    self.Header = header
    self.BackButton = back
    self.TextScrollFrame = scroll

    -- A sibling of Back, outside the quest description's scrolling content.
    local button = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    button:Hide()
    button:SetSize(back:GetWidth(), back:GetHeight())
    button:SetText("Out Loud")
    button:SetScript("OnClick", function()
        local ok, message = pcall(self.SpeakCurrentText, self)
        if not ok then
            OutLoud:Error("Quest Log read failed with Lua error:", tostring(message))
        end
    end)
    self.Button = button

    local function Refresh()
        self:UpdateButtonVisibility()
    end
    frame:HookScript("OnEvent", Refresh)
    for _, panel in ipairs({ frame, details, header, back, scroll, frame:GetParent() }) do
        panel:HookScript("OnShow", Refresh)
        panel:HookScript("OnHide", Refresh)
    end
    header:HookScript("OnSizeChanged", Refresh)
    -- Show() alone does not notify when switching quests in an already open detail view.
    hooksecurefunc("QuestMapFrame_ShowQuestDetails", Refresh)
    hooksecurefunc("QuestMapFrame_CloseQuestDetails", Refresh)

    self.Initialized = true
    if self.LoadFrame then
        self.LoadFrame:UnregisterEvent("ADDON_LOADED")
        self.LoadFrame:SetScript("OnEvent", nil)
    end
    self:UpdateButtonVisibility()
end
