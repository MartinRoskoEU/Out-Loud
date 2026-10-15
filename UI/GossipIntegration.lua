local AddonName, OutLoud = ...

local GossipIntegration = {}
OutLoud.UI.GossipIntegration = GossipIntegration

local function IsUsableVoiceID(voiceID)
    return type(voiceID) == "number" and voiceID >= 0 and voiceID % 1 == 0
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

function GossipIntegration:StartCurrentNarration()
    local ok, message = pcall(self.SpeakCurrentText, self)
    if not ok then
        OutLoud:Error("Gossip read failed with Lua error:", tostring(message))
    end
end

function GossipIntegration:SpeakCurrentText()
    -- Capture text and identity at the click; never cache a unit token's identity.
    local text, reason = self:GetCurrentText()
    if not text then
        OutLoud:Error("Gossip read stopped:", reason)
        return
    end

    local npcExists = UnitExists("npc")
    local displayTitle = npcExists and UnitName("npc") or "Unknown"
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

    return OutLoud.Narration:Speak(speakerUnit, text, voiceID, displayTitle, "Gossip", info.modelFileID)
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
        self:UpdateButtonVisibility()
    end
    -- Forever's CustomGossipFrameManager routes GOSSIP_SHOW/CLOSED to this UI.
    -- HandleShow and content changes call Update; none of these hooks speak.
    hooksecurefunc(frame, "Update", Refresh)
    frame:HookScript("OnShow", Refresh)
    frame:HookScript("OnHide", Refresh)
    greeting:HookScript("OnShow", Refresh)
    greeting:HookScript("OnHide", Refresh)
    goodbye:HookScript("OnShow", Refresh)
    goodbye:HookScript("OnHide", Refresh)

    self.Initialized = true
    if self.LoadFrame then
        self.LoadFrame:UnregisterEvent("ADDON_LOADED")
        self.LoadFrame:SetScript("OnEvent", nil)
    end
    self:UpdateButtonVisibility()
end
