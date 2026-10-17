local AddonName, OutLoud = ...

local GossipIntegration = {}
OutLoud.UI.GossipIntegration = GossipIntegration

local function IsUsableVoiceID(voiceID)
    return type(voiceID) == "number" and voiceID >= 0 and voiceID % 1 == 0
end

local function SameDialogue(first, second)
    return first and second and first.text == second.text and first.name == second.name
end

function GossipIntegration:GetCurrentText()
    if not self.Frame then return nil, "gossip-frame-unavailable" end
    if not self.Frame:IsShown() or not self.GreetingPanel:IsShown() then
        return nil, "gossip-frame-closed"
    end
    if not C_GossipInfo or type(C_GossipInfo.GetText) ~= "function" then
        return nil, "gossip-text-api-unavailable"
    end

    -- Forever's greeting uses this API separately from options and quest lists.
    local text = C_GossipInfo.GetText()
    if type(text) == "string" and text:find("%S") then return text end
    return nil, "empty-or-invalid-gossip-text"
end

function GossipIntegration:UpdateButtonVisibility()
    if not self.Button then return end
    local text = self:GetCurrentText()
    if text and self.GoodbyeButton:IsShown() then
        self.Button:Show()
    else
        self.Button:Hide()
    end
end

function GossipIntegration:CancelPendingAutoNarration()
    OutLoud.Narration:CancelAutoNarration(self)
end

function GossipIntegration:CaptureAutoNarration()
    local text = self:GetCurrentText()
    if not text or not self.GoodbyeButton:IsShown() then return end
    -- Quest pages have their own automatic activation; never read them as gossip.
    local questFrame = rawget(_G, "QuestFrame")
    if questFrame and questFrame:IsShown() then return end
    return { text = text, name = UnitExists("npc") and UnitName("npc") or "Unknown" }
end

function GossipIntegration:IsAutoNarrationCurrent(request)
    return self.AutoNarrationDialogue == request and OutLoud.Database:GetAutoNarrateQuests()
        and SameDialogue(request, self:CaptureAutoNarration())
end

function GossipIntegration:Refresh()
    self:UpdateButtonVisibility()
    local dialogue = self:CaptureAutoNarration()
    if SameDialogue(self.AutoNarrationDialogue, dialogue) then return end
    self:CancelPendingAutoNarration()
    -- Retain the observed dialogue after activation/cancellation so refreshes
    -- cannot restart a delay or undo STOP. Closing clears this identity.
    self.AutoNarrationDialogue = dialogue
    if not dialogue then return end
    OutLoud.Narration:ScheduleAutoNarration(self, dialogue,
        function(pending) return self:IsAutoNarrationCurrent(pending) end,
        function() self:StartCurrentNarration() end)
end

function GossipIntegration:OnHidden()
    -- Only the whole frame closes narration; greeting/options can change in place.
    if self.Frame:IsShown() then return end
    self.AutoNarrationDialogue = nil
    OutLoud.Narration:StopSource(self, "gossip-closed")
    self:UpdateButtonVisibility()
end

function GossipIntegration:OnTTSStop(reason)
    -- Finishing the previous response must not cancel the next response's delay.
    if reason ~= "finished" then self:CancelPendingAutoNarration() end
end

function GossipIntegration:StartCurrentNarration()
    local ok, message = pcall(self.SpeakCurrentText, self)
    if not ok then
        OutLoud:Error("Gossip read failed with Lua error:", tostring(message))
    end
end

function GossipIntegration:SpeakCurrentText()
    self:CancelPendingAutoNarration()
    -- Both activation paths capture current text/name; delayed data is only a guard.
    local text, reason = self:GetCurrentText()
    if not text then
        OutLoud:Error("Gossip read stopped:", reason)
        return
    end

    local npcExists = UnitExists("npc")
    local displayTitle = npcExists and UnitName("npc") or "Unknown"
    self.AutoNarrationDialogue = { text = text, name = displayTitle }
    local selection = OutLoud.VoiceSelection
    local speakerUnit = "player"
    local voiceID, info
    if selection:IsSingleVoiceMode() then
        voiceID, info = selection:ResolvePlayer()
    else
        if npcExists then
            local model = OutLoud.NPCInspection:LoadUnit("npc")
            voiceID, info = selection:Resolve("npc", model)
        else
            info = { reason = "unit-unavailable" }
        end
        if IsUsableVoiceID(voiceID) then
            speakerUnit = "npc"
        else
            OutLoud:Debug("Gossip NPC voice unavailable; falling back to player:", info.reason or "invalid-voice")
            voiceID, info = selection:ResolvePlayer()
        end
    end

    if not IsUsableVoiceID(voiceID) then
        if info.reason == "voice-not-set" then
            OutLoud:Error("Gossip read stopped: choose a player voice in Options for", info.family, info.gender)
        else
            OutLoud:Error("Gossip read stopped: narrator resolution failed:", info.reason or "invalid-voice")
        end
        return
    end

    return OutLoud.Narration:Speak(speakerUnit, text, voiceID, displayTitle, "Gossip", info.modelFileID, nil, self)
end

function GossipIntegration:Initialize()
    if self.Initialized then return end

    local frame = rawget(_G, "GossipFrame")
    local greeting = frame and frame.GreetingPanel
    local goodbye = greeting and greeting.GoodbyeButton
    if not frame or not greeting or not goodbye or type(frame.Update) ~= "function" then
        if not self.LoadFrame then
            self.LoadFrame = CreateFrame("Frame")
            self.LoadFrame:RegisterEvent("ADDON_LOADED")
            self.LoadFrame:SetScript("OnEvent", function()
                self:Initialize()
            end)
        end
        return
    end

    self.Frame, self.GreetingPanel, self.GoodbyeButton = frame, greeting, goodbye
    -- This helper is independent of QuestFrame's initialization and load order.
    OutLoud.NPCInspection:GetModel()

    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:Hide()
    button:SetSize(100, 22)
    button:SetText("Out Loud")
    button:SetPoint("RIGHT", goodbye, "LEFT", -8, 0)
    button:SetScript("OnClick", function()
        self:StartCurrentNarration()
    end)
    self.Button = button

    local function Refresh()
        self:Refresh()
    end
    -- Forever's CustomGossipFrameManager routes GOSSIP_SHOW/CLOSED to this UI.
    -- Reuse the existing post-update/visibility hooks, with no second event path.
    hooksecurefunc(frame, "Update", Refresh)
    frame:HookScript("OnShow", Refresh)
    frame:HookScript("OnHide", function() self:OnHidden() end)
    greeting:HookScript("OnShow", Refresh)
    greeting:HookScript("OnHide", Refresh)
    goodbye:HookScript("OnShow", Refresh)
    goodbye:HookScript("OnHide", Refresh)

    hooksecurefunc(OutLoud.Database, "SetAutoNarrateQuests", function()
        if not OutLoud.Database:GetAutoNarrateQuests() then
            self:CancelPendingAutoNarration()
        end
    end)
    hooksecurefunc(OutLoud.Narration, "Speak", function() self:CancelPendingAutoNarration() end)
    hooksecurefunc(OutLoud.Narration, "Stop", function() self:CancelPendingAutoNarration() end)
    hooksecurefunc(OutLoud.TTS, "Stop", function(_, reason) self:OnTTSStop(reason) end)
    hooksecurefunc(OutLoud.TTS, "StartSession", function() self:CancelPendingAutoNarration() end)

    self.Initialized = true
    if self.LoadFrame then
        self.LoadFrame:UnregisterEvent("ADDON_LOADED")
        self.LoadFrame:SetScript("OnEvent", nil)
    end
    self:Refresh()
end
