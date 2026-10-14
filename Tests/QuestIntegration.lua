-- Run from the addon root with Lua 5.1: lua Tests/QuestIntegration.lua
-- These mocks verify addon logic, not Forever's UI, event order, or model loading.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Frame(parent)
    local frame = { parent = parent, shown = false, scripts = {}, hooks = {}, events = {} }
    function frame:SetScript(script, callback) self.scripts[script] = callback end
    function frame:HookScript(script, callback)
        self.hooks[script] = self.hooks[script] or {}
        table.insert(self.hooks[script], callback)
    end
    function frame:Fire(script, ...)
        if self.scripts[script] then self.scripts[script](self, ...) end
        for _, callback in ipairs(self.hooks[script] or {}) do callback(self, ...) end
    end
    function frame:IsShown() return self.shown end
    function frame:Show()
        if self.shown then return end
        self.shown = true
        self:Fire("OnShow")
    end
    function frame:Hide()
        if not self.shown then return end
        self.shown = false
        self:Fire("OnHide")
    end
    function frame:SetSize(width, height) self.size = { width, height } end
    function frame:ClearAllPoints() self.point = nil end
    function frame:SetPoint(...) self.point = { ... } end
    function frame:SetText(text) self.text = text end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    return frame
end

local panelNames = {
    "QuestFrameDetailPanel", "QuestFrameProgressPanel",
    "QuestFrameRewardPanel", "QuestFrameGreetingPanel",
}

local function Harness(deferred, realTTS)
    local h = { created = {}, speech = {}, heads = {}, flow = {}, diagnostics = {}, exists = true, sex = 2, modelID = 100,
        nativeCalls = {}, progress = {}, stops = 0, timers = {}, playerExists = true, playerSex = 2, questID = 1,
        voices = { { voiceID = 0, name = "Voice zero" }, { voiceID = 7, name = "Narrator" } },
        texts = { detail = "Offer text.\n Objectives elsewhere.",
            progress = "Progress text!", reward = "Reward text?" }, resolveCalls = 0 }
    local environment = setmetatable({}, { __index = _G })
    environment._G = environment
    h.environment = environment

    function environment.CreateFrame(kind, _name, parent, template)
        local frame = Frame(parent)
        frame.kind, frame.template = kind, template
        if kind == "PlayerModel" then
            function frame:ClearModel()
                self.modelID = 0
                self.clearCalls = (self.clearCalls or 0) + 1
            end
            function frame:SetUnit(unit)
                Equal(unit, "questnpc", "Load the speaking NPC")
                Equal(self.modelID, 0, "Clear stale model before loading")
                self.unit, self.modelID = unit, h.modelID
                h.flow[#h.flow + 1] = "model"
            end
            function frame:GetModelFileID() return self.modelID end
        end
        table.insert(h.created, frame)
        return frame
    end
    function environment.UnitExists(unit)
        return unit == "player" and h.playerExists or unit == "questnpc" and h.exists
    end
    function environment.UnitSex(unit)
        if unit == "player" then return h.playerSex end
        return h.sex
    end
    function environment.UnitName(unit) return unit == "player" and "Test Player" or "Quest NPC" end
    function environment.UnitRace() return "Human", h.playerRaceToken or "Human", 1 end
    function environment.GetQuestID() return h.questID end
    -- Keep the table-form mock separate from the editor's global API overloads.
    rawset(environment, "hooksecurefunc", function(owner, method, callback)
        local original = assert(owner[method])
        owner[method] = function(...)
            local result = { original(...) }
            callback(...)
            return unpack(result)
        end
    end)
    function environment.GetQuestText() return h.texts.detail end
    function environment.GetProgressText() return h.texts.progress end
    function environment.GetRewardText() return h.texts.reward end
    function environment.GetQuestLogQuestText() error("Do not read quest-log text") end
    function environment.GetGreetingText() error("Do not narrate greeting text") end
    function environment.print(...)
        h.diagnostics[#h.diagnostics + 1] = { ... }
    end
    environment.C_Timer = {
        After = function() error("Narration delays must be cancellable") end,
        NewTimer = function(delay, callback)
            local timer = { delay = delay }
            function timer:Cancel() self.cancelled = true end
            -- Allow firing cancelled callbacks to exercise request ownership guards.
            function timer:Fire() callback() end
            h.timers[#h.timers + 1] = timer
            return timer
        end,
    }

    local addon = {}
    local function Load(path)
        local chunk = assert(LoadFile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    Load("Core/Namespace.lua")
    addon.VoiceMappings = {
        Families = { HUMAN = "HUMAN", UNDEAD = "UNDEAD" }, Models = { [100] = "UNDEAD" },
    }
    Load("Core/VoiceSelection.lua")
    Load("Core/Database.lua")
    local resolve = addon.VoiceSelection.Resolve
    function addon.VoiceSelection:Resolve(unit, model)
        h.resolveCalls = h.resolveCalls + 1
        h.flow[#h.flow + 1] = "resolve"
        Equal(model.unit, unit, "SetUnit precedes Resolve")
        return resolve(self, unit, model)
    end
    addon.UI.TalkingHead = {
        Show = function(self, unit, text)
            self.shown = true
            h.heads[#h.heads + 1] = { unit = unit, text = text }
            h.flow[#h.flow + 1] = "head"
        end,
        SetLoading = function(self, loading)
            self.loading = loading
            h.flow[#h.flow + 1] = loading and "loading" or "idle"
        end,
        Hide = function(self)
            self.shown, self.loading = false, false
            h.flow[#h.flow + 1] = "hide"
        end,
        FinishTextPlayback = function(_, reason) h.endReason = reason end,
        OnTextProgress = function(_, text, chunk, offset)
            h.progress[#h.progress + 1] = { text = text, chunk = chunk, offset = offset }
        end,
    }
    local speak
    if realTTS then
        environment.Enum = { TtsBoolSetting = { PlaySoundSeparatingChatLineBreaks = 0 } }
        environment.C_TTSSettings = { SetSetting = function(_setting, _value) end }
        environment.C_VoiceChat = {
            GetTtsVoices = function() return h.voices end,
            SpeakText = function(voiceID, text, _rate, _volume, _overlap)
                if h.failSpeech then error("Mock native submission failure") end
                h.nativeCalls[#h.nativeCalls + 1] = { voiceID = voiceID,
                    text = text:gsub('^<bookmark mark="[^"]+"/>', "") }
                if h.onSpeak then h.onSpeak(text) end
            end,
            StopSpeakingText = function() h.stops = h.stops + 1 end,
        }
        Load("Core/TTS.lua")
        speak = addon.TTS.Speak
    else
        addon.TTS = { ReadingModes = { FULL = "full", SPLIT = "split" }, StartSession = function() end,
            GetVoices = function() return h.voices end }
        speak = function() return true end
    end
    addon.Database:Initialize()
    addon.Database:SetVoice("HUMAN", 2, 0)
    addon.Database:SetVoice("HUMAN", 3, 7)
    addon.Database:SetVoice("UNDEAD", 2, 0)
    addon.Database:SetVoice("UNDEAD", 3, 7)
    function addon.TTS:Speak(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
        table.insert(h.speech, { text = text, voiceID = voiceID })
        h.flow[#h.flow + 1] = "speak"
        return speak(self, text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    end
    Load("Core/Narration.lua")
    Load("UI/QuestIntegration.lua")
    h.addon, h.integration = addon, addon.UI.QuestIntegration

    function h:CreateQuestUI()
        environment.QuestFrame = Frame()
        for _, name in ipairs(panelNames) do
            environment[name] = Frame(environment.QuestFrame)
        end
        for _, name in ipairs({
            "QuestFrameAcceptButton", "QuestFrameDeclineButton",
            "QuestFrameCompleteButton", "QuestFrameGoodbyeButton",
            "QuestFrameCompleteQuestButton", "QuestFrameCancelButton",
        }) do
            environment[name] = Frame(environment.QuestFrame)
            environment[name].shown = true
        end
    end
    function h:Panel(name)
        for _, otherName in ipairs(panelNames) do
            if otherName ~= name then environment[otherName]:Hide() end
        end
        environment[name]:Show()
    end
    function h:Click() self.integration.Button:Fire("OnClick") end
    function h:CreateQuestLogNarrator()
        Load("UI/QuestLogIntegration.lua")
        local questLog = addon.UI.QuestLogIntegration
        for _, field in ipairs({ "Frame", "DetailsFrame", "TextScrollFrame", "BackButton" }) do
            questLog[field] = Frame()
            questLog[field].shown = true
            questLog[field].IsVisible = questLog[field].IsShown
        end
        questLog.DetailsFrame.questID = h.questID
        environment.C_QuestLog = {
            GetSelectedQuest = function() return h.questID end,
            GetLogIndexForQuestID = function() return 1 end,
        }
        environment.GetQuestLogQuestText = function(index)
            Equal(index, 1)
            return h.texts.detail, "Objectives must not be narrated."
        end
        return questLog
    end
    if not deferred then h:CreateQuestUI() end
    h.integration:Initialize()
    return h
end

local passed = 0
local function Test(name, callback)
    local ok, message = pcall(callback)
    assert(ok, name .. ": " .. tostring(message))
    passed = passed + 1
end

Test("Create once and preserve Blizzard handlers", function()
    local h = Harness()
    local button, model = h.integration.Button, h.integration.Model
    Equal(#h.created, 3, "One button, its gap anchor, and one model")
    Equal(button.parent, h.environment.QuestFrame, "QuestFrame parent")
    Equal(button.template, "UIPanelButtonTemplate", "Native button template")
    Equal(button.text, "Out Loud", "Button caption")
    Equal(model.parent, nil, "Inspection model uses the verified unparented setup")
    h.integration:Initialize()
    Equal(#h.created, 3, "Repeated initialization creates nothing")
    local originalCalls = 0
    h.environment.QuestFrame:SetScript("OnShow", function() originalCalls = originalCalls + 1 end)
    h:Panel("QuestFrameDetailPanel")
    h.environment.QuestFrame:Show()
    Equal(originalCalls, 1, "Blizzard's handler is preserved")
    Equal(button:IsShown(), true, "OnShow refresh")
    Equal(#h.speech, 0, "Opening dialogue never speaks")
    Equal(#h.heads, 0, "Opening dialogue never shows Talking Head")
end)

Test("Dialogue panels show; greeting and close hide", function()
    local h = Harness()
    local button = h.integration.Button
    Equal(button:IsShown(), false, "Initially closed")
    h.environment.QuestFrame:Show()
    Equal(button:IsShown(), false, "Open with no dialogue")
    for _, name in ipairs(panelNames) do
        h:Panel(name)
        Equal(button:IsShown(), name ~= "QuestFrameGreetingPanel", name)
    end
    h:Panel("QuestFrameDetailPanel")
    h.environment.QuestFrame:Hide()
    Equal(button:IsShown(), false, "Closing clears button shown flag")
    h:Click()
    Equal(#h.speech, 0, "Closed click cannot narrate")
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameGreetingPanel")
    h:Click()
    Equal(button:IsShown(), false, "Return to greeting")
    Equal(#h.speech, 0, "Greeting cannot narrate")
    Equal(#h.heads, 0, "Closed and greeting clicks leave Talking Head alone")
end)

Test("Click uses each panel's current text unchanged and real resolver", function()
    local h = Harness()
    h.environment.QuestFrame:Show()
    local sources = { "detail", "progress", "reward" }
    for index, source in ipairs(sources) do
        h:Panel(panelNames[index])
        h:Click()
        Equal(h.speech[index].text, h.texts[source], "State-specific text")
        Equal(h.speech[index].voiceID, 0, "Configured voice zero is valid")
        Equal(h.heads[index].unit, "questnpc", "Talking Head speaker")
        Equal(h.heads[index].text, h.texts[source], "Talking Head receives exact dialogue")
        Equal(h.addon.UI.TalkingHead.loading, true, "Loading starts on submission")
        local offset = (index - 1) * 5
        Equal(table.concat(h.flow, ",", offset + 1, offset + 5),
            "model,resolve,head,loading,speak", "Resolve before UI, loading before speech")
    end
    h.texts.reward = "Updated reward text."
    h.sex = 3
    h:Click()
    Equal(h.speech[4].text, h.texts.reward, "Read fresh text on repeated click")
    Equal(h.speech[4].voiceID, 7, "Runtime female voice")
    Equal(h.heads[4].text, h.texts.reward, "Repeated click updates Talking Head")
    Equal(#h.created, 3, "Clicks reuse the same model")
    Equal(h.integration.Model.clearCalls, 4, "Old model cleared on each load")
    Equal(h.resolveCalls, 4, "Existing VoiceSelection called")
end)

Test("After-event refresh handles unchanged panel and Blizzard transitions", function()
    local h = Harness()
    local environment = h.environment
    environment.QuestFrame:SetScript("OnEvent", function(_, event)
        if event == "QUEST_DETAIL" then h:Panel("QuestFrameDetailPanel")
        elseif event == "QUEST_PROGRESS" then h:Panel("QuestFrameProgressPanel")
        elseif event == "QUEST_COMPLETE" then h:Panel("QuestFrameRewardPanel")
        elseif event == "QUEST_GREETING" then h:Panel("QuestFrameGreetingPanel")
        elseif event == "QUEST_FINISHED" then environment.QuestFrame:Hide(); return end
        environment.QuestFrame:Show()
    end)
    for _, event in ipairs({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }) do
        environment.QuestFrame:Fire("OnEvent", event)
        Equal(h.integration.Button:IsShown(), true, event)
    end
    h.texts.reward = " \n\t"
    environment.QuestFrame:Fire("OnEvent", "QUEST_ITEM_UPDATE")
    Equal(h.integration.Button:IsShown(), false, "Empty text on same panel")
    h.texts.reward = "Restored reward text."
    environment.QuestFrame:Fire("OnEvent", "QUEST_ITEM_UPDATE")
    Equal(h.integration.Button:IsShown(), true, "Text refresh on same panel")
    environment.QuestFrame:Fire("OnEvent", "QUEST_GREETING")
    Equal(h.integration.Button:IsShown(), false, "Greeting event")
    environment.QuestFrame:Fire("OnEvent", "QUEST_FINISHED")
    Equal(h.integration.Button:IsShown(), false, "Finished event")
    Equal(#h.speech, 0, "Events only refresh visibility")
    Equal(#h.heads, 0, "Events do not open Talking Head")

    h.addon.Database:SetAutoNarrateQuests(true)
    environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    local timer = h.timers[#h.timers]
    Equal(timer.delay, 2, "Automatic delay defaults to two seconds")
    Equal(#h.speech, 0, "Automatic narration waits")
    h:Click()
    Equal(timer.cancelled, true, "Manual click cancels pending automatic narration")
    Equal(#h.speech, 1, "Manual click starts immediately")
    timer:Fire()
    Equal(#h.speech, 1, "Cancelled callback cannot duplicate manual narration")

    environment.QuestFrame:Fire("OnEvent", "QUEST_PROGRESS")
    timer = h.timers[#h.timers]
    environment.QuestFrame:Hide()
    Equal(timer.cancelled, true, "Closing cancels the pending request")
    timer:Fire()
    Equal(#h.speech, 1, "Closed request cannot start narration")

    environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    timer = h.timers[#h.timers]
    environment.QuestFrame:Fire("OnEvent", "QUEST_PROGRESS")
    Equal(timer.cancelled, true, "A new automatic event replaces the pending timer")
    timer:Fire()
    Equal(#h.speech, 1, "Replaced callbacks cannot narrate an old page")
    timer = h.timers[#h.timers]
    h.questID = 2
    timer:Fire()
    Equal(#h.speech, 1, "Changed quest identity invalidates a delayed callback")

    environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    timer = h.timers[#h.timers]
    h.addon.Database:SetAutoNarrateQuests(false)
    Equal(timer.cancelled, true, "Disabling automatic narration cancels the timer immediately")
    timer:Fire()
    Equal(#h.speech, 1, "Disabled callbacks cannot narrate")

    h.addon.Database:SetAutoNarrateQuests(true)
    h.addon.Database:SetAutoNarrationDelay(0)
    environment.QuestFrame:Fire("OnEvent", "QUEST_COMPLETE")
    Equal(#h.speech, 2, "Zero delay starts automatically without a timer")
end)

Test("Empty, missing, and ambiguous dialogue fails safely", function()
    local h = Harness()
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    for _, text in ipairs({ false, "", " \n\t", 123 }) do
        h.texts.detail = text
        h.integration:UpdateButtonVisibility()
        Equal(h.integration.Button:IsShown(), false, "Invalid text")
        h:Click()
    end
    h.texts.detail = nil
    h:Click()
    h.texts.detail = "Offer text."
    rawset(h.environment, "GetQuestText", nil)
    h.integration:UpdateButtonVisibility()
    Equal(h.integration.Button:IsShown(), false, "Missing text API")
    h:Click()
    h.environment.GetQuestText = function() return h.texts.detail end
    h.environment.QuestFrameProgressPanel:Show()
    Equal(h.integration.Button:IsShown(), false, "Multiple dialogue panels")
    h:Click()
    h.environment.QuestFrameGreetingPanel:Show()
    Equal(h.integration.Button:IsShown(), false, "Greeting overrides stale panels")
    h:Click()
    Equal(#h.speech, 0, "No speculative narration")
    Equal(#h.heads, 0, "Invalid text does not show Talking Head")
end)

Test("NPC failures use the player; failed player resolution does not start speech", function()
    local h = Harness()
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    h.exists = false
    h:Click()
    Equal(h.resolveCalls, 0, "Missing NPC skips model/resolve")
    Equal(h.heads[#h.heads].unit, "player", "Missing NPC uses the player presentation")
    h.exists = true
    h:Click()
    Equal(#h.speech, 2, "Baseline NPC narration after player fallback")
    h.modelID = 0
    h:Click()
    Equal(h.integration.Model:GetModelFileID(), 0, "No stale previous model")
    h.modelID = nil
    h:Click()
    h.modelID = 999
    h:Click()
    h.modelID = 100
    for _, sex in ipairs({ 1, 0, 4 }) do h.sex = sex; h:Click() end
    h.sex = nil
    h:Click()
    h.sex = 2
    h.addon.Database:SetVoice("UNDEAD", 2, nil)
    h:Click()
    h.integration.Model = nil
    h:Click()
    Equal(#h.speech, 11, "Every unresolved NPC uses the configured player voice")
    Equal(h.heads[#h.heads].unit, "player", "Fallback uses the player model/name")
    local count = #h.speech
    h.playerExists = false
    h:Click()
    Equal(#h.speech, count, "Unavailable player cannot start narration")
    Equal(#h.heads, count, "Failed player resolution leaves presentation alone")
end)

Test("Real TTS dispatcher honors reading modes and owns replacement", function()
    local h = Harness(false, true)
    local tts = h.addon.TTS
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    h:Click()
    Equal(#h.speech, 1, "Quest integration enters through Speak")
    Equal(tts.CurrentSession.mode, "full", "Existing full-text default")
    Equal(h.nativeCalls[1].text, "Offer text. Objectives elsewhere.", "Whole speech whitespace is normalized")
    Equal(h.heads[1].text, h.texts.detail, "Full mode display keeps original whitespace")
    Equal(h.stops, 0, "First narration needs no cancellation")
    h.addon.Database:SetReadingMode("split")
    h:Click()
    Equal(#h.speech, 2, "Second click enters through Speak again")
    Equal(tts.CurrentSession.mode, "split", "Existing saved split setting")
    Equal(h.nativeCalls[2].text, "Offer text.", "TTS performs splitting")
    Equal(h.heads[2].text, h.texts.detail, "Talking Head keeps full original text")
    Equal(h.stops, 1, "TTS alone replaces the previous session")
    h.environment.QuestFrame:Hide()
    Equal(h.stops, 1, "QuestFrame close does not stop narration")
    Equal(h.addon.UI.TalkingHead.shown, true, "QuestFrame close leaves presentation visible")
    Equal(h.addon.UI.TalkingHead.loading, true, "Loading remains until the first owned bookmark")

    h.environment.QuestFrame:Show()
    h.addon.Database:SetAutoNarrateQuests(true)
    h.environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    local timer = h.timers[#h.timers]
    tts:SpeakWholeText("Another caller starts a session.", 7)
    Equal(timer.cancelled, true, "A new TTS session cancels pending automatic narration")
    local count = #h.nativeCalls
    timer:Fire()
    Equal(#h.nativeCalls, count, "Replaced automatic request cannot interrupt another caller")
end)

Test("Single Voice covers manual, automatic, fallback, and Quest Log with independent speakers", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness(false, true)
        h.addon.Database:SetReadingMode(mode)
        h.addon.Database:SetVoiceMode("single")
        h.addon.Database:SetSingleVoice(7)
        h.texts.detail = "Go to Andorhal / Chillwind Camp. Next_sentence!"
        h.sex, h.playerSex, h.playerRaceToken = nil, nil, "UnmappedRace"
        h.environment.QuestFrame:Show()
        h:Panel("QuestFrameDetailPanel")

        h:Click()
        Equal(h.nativeCalls[1].voiceID, 7, "Known NPC uses the narrator")
        Equal(h.heads[1].unit, "questnpc", "Known NPC retains its portrait and name")
        h.modelID = 999
        h:Click()
        Equal(h.nativeCalls[2].voiceID, 7)
        Equal(h.heads[2].unit, "questnpc", "Unmapped NPC with a valid model remains the speaker")
        local session = h.addon.TTS.CurrentSession
        Equal(session.voiceID, 7)
        Equal(h.nativeCalls[2].text, mode == "full"
            and "Go to Andorhal Chillwind Camp. Next sentence!"
            or "Go to Andorhal Chillwind Camp.", "Both modes keep the sanitized speech path")

        h.addon.Database:SetAutoNarrateQuests(true)
        h.addon.Database:SetAutoNarrationDelay(3)
        h.environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
        Equal(#h.nativeCalls, 2, "Automatic narration still waits for its configured delay")
        local timer = h.timers[#h.timers]
        Equal(timer.delay, 3)
        timer:Fire()
        Equal(#h.nativeCalls, 3, "Automatic narration starts one session")
        Equal(h.nativeCalls[3].voiceID, 7)
        Equal(h.heads[3].unit, "questnpc", "Automatic narration also keeps an unmapped NPC")

        h.modelID = 0
        h:Click()
        Equal(h.heads[4].unit, "player", "Unavailable NPC model uses player presentation")
        Equal(h.nativeCalls[4].voiceID, 7, "Fallback keeps the narrator despite unknown player race/sex")
        h.modelID = nil
        h:Click()
        Equal(h.heads[5].unit, "player", "Unready NPC model falls back")
        h.exists = false
        h:Click()
        Equal(h.heads[6].unit, "player", "Missing NPC uses player presentation")
        h.exists = true
        h.integration.Model = nil
        h:Click()
        Equal(h.heads[7].unit, "player", "Missing inspection model uses player presentation")
        local questLog = h:CreateQuestLogNarrator()
        Equal(questLog:SpeakCurrentText(), true)
        Equal(h.heads[8].unit, "player", "Quest Log remains player narration")
        Equal(#h.nativeCalls, 8, "One initial request per narration session")
        for _, call in ipairs(h.nativeCalls) do Equal(call.voiceID, 7, "Every source uses the same narrator") end
        Equal(h.stops, 7, "Only new narration replaces playback")
    end
end)

Test("Missing or unavailable Single Voice never falls back to family assignments", function()
    for _, unavailable in ipairs({ false, 999 }) do
        local h = Harness(false, true)
        h.addon.Database:SetVoiceMode("single")
        h.addon.Database:SetSingleVoice(unavailable or nil)
        h.environment.QuestFrame:Show()
        h:Panel("QuestFrameDetailPanel")
        h:Click()
        h.exists = false
        h:Click()
        h:CreateQuestLogNarrator():SpeakCurrentText()
        Equal(#h.nativeCalls, 0, "Do not use configured NPC/player family voices")
        Equal(#h.heads, 0, "Missing voice leaves presentation alone")
        Equal(h.addon.TTS.CurrentSession, nil)
        Equal(h.addon.Database:GetVoiceMode(), "single", "Do not silently change assignment mode")
        Equal(h.addon.Database:GetSingleVoice(), unavailable or nil, "Do not discard an unavailable selection")
        assert(#h.diagnostics > 0, "Missing voices use existing error reporting")
    end
end)

Test("Changing voice settings preserves active playback and introduces no sessions or delays", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness(false, true)
        h.addon.Database:SetVoiceMode("single")
        h.addon.Database:SetSingleVoice(7)
        h.addon.Database:SetReadingMode(mode)
        h.environment.QuestFrame:Show()
        h:Panel("QuestFrameDetailPanel")
        h:Click()
        local session = h.addon.TTS.CurrentSession
        h.addon.Database:SetVoiceMode("raceGender")
        h.addon.Database:SetSingleVoice(0)
        h.addon.Database:SetVoiceMode("single")
        Equal(h.addon.TTS.CurrentSession, session)
        Equal(session.voiceID, 7, "Active session retains its resolved voice")
        Equal(h.addon.TTS.SessionID, 1)
        Equal(#h.nativeCalls, 1)
        Equal(h.stops, 0)
        Equal(#h.timers, 0)
        Equal(h.addon.UI.TalkingHead.shown, true)
    end
end)

Test("QuestFrame and Quest Log sanitize speech while keeping original Talking Head text", function()
    for _, source in ipairs({ "QuestFrame", "QuestLog" }) do
        for _, mode in ipairs({ "full", "split" }) do
            local h = Harness(false, true)
            local original = "  Go to Andorhal / Chillwind Camp.\n Café_雪\\now|please~again!  "
            h.texts.detail = original
            h.addon.Database:SetReadingMode(mode)
            local narrator
            if source == "QuestFrame" then
                h.environment.QuestFrame:Show()
                h:Panel("QuestFrameDetailPanel")
                narrator = h.integration
            else
                narrator = h:CreateQuestLogNarrator()
            end
            Equal(narrator:SpeakCurrentText(), true)
            Equal(h.speech[1].text, original, "Source passes original text to the shared dispatcher")
            Equal(h.heads[1].text, original, "Talking Head receives unchanged original text")
            Equal(#h.nativeCalls, 1, "Both modes start with one request")
            local tts = h.addon.TTS
            local mark = "OUTLOUD:SPEECH:" .. tts.CurrentSession.id .. ":"
            local token = mode == "full" and "WHOLE" or "1"
            Equal(h.nativeCalls[1].text, mode == "full"
                and "Go to Andorhal Chillwind Camp. Café 雪 now please again!"
                or "Go to Andorhal Chillwind Camp.")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, mark .. token)
            Equal(h.addon.UI.TalkingHead.loading, false, "Owned playback clears loading")
            Equal(h.progress[1].text, mode == "full" and original or "Go to Andorhal / Chillwind Camp.")
            Equal(h.progress[1].chunk, mode == "full" and 0 or 1)
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 101)
            if mode == "split" then
                Equal(#h.nativeCalls, 2, "Prefetch only the next sentence")
                Equal(h.nativeCalls[2].text, "Café 雪 now please again!")
                tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 102, mark .. "2")
                Equal(h.progress[2].text, "Café_雪\\now|please~again!", "Display keeps sentence separators")
                Equal(h.progress[2].chunk, 2)
                tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 102)
            else
                Equal(#h.nativeCalls, 1, "Full mode remains one request")
            end
            Equal(tts.CurrentSession, nil)
            Equal(h.addon.UI.TalkingHead.shown, false, "Completion cleans up presentation")
        end
    end
end)

Test("Empty sanitized quest narration clears Talking Head and loading in both sources and modes", function()
    for _, source in ipairs({ "QuestFrame", "QuestLog" }) do
        for _, mode in ipairs({ "full", "split" }) do
            local h = Harness(false, true)
            h.texts.detail = " / \\ | _ ~ \t\n"
            h.addon.Database:SetReadingMode(mode)
            local narrator
            if source == "QuestFrame" then
                h.environment.QuestFrame:Show()
                h:Panel("QuestFrameDetailPanel")
                narrator = h.integration
            else
                narrator = h:CreateQuestLogNarrator()
            end
            local ok, reason = narrator:SpeakCurrentText()
            Equal(ok, false)
            Equal(reason, "invalid-text")
            Equal(#h.nativeCalls, 0, "Empty speech never reaches the native engine")
            Equal(h.addon.TTS.CurrentSession, nil)
            Equal(h.addon.Narration.Narration, nil, "Release presentation ownership")
            Equal(h.addon.UI.TalkingHead.shown, false)
            Equal(h.addon.UI.TalkingHead.loading, false)
        end
    end
end)

Test("Talking Head closes on owned completion in both reading modes", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness(false, true)
        h.texts.detail = "First sentence. Second sentence."
        h.environment.QuestFrame:Show()
        h:Panel("QuestFrameDetailPanel")
        h.addon.Database:SetReadingMode(mode)
        h:Click()
        local tts, head = h.addon.TTS, h.addon.UI.TalkingHead
        local mark = "OUTLOUD:SPEECH:" .. tts.CurrentSession.id .. ":"
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 999)
        Equal(head.shown, true, "Unidentified playback cannot close narration")
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, mark .. (mode == "full" and "WHOLE" or "1"))
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 101)
        if mode == "split" then
            Equal(head.shown, true, "First sentence finishing keeps the UI open")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 102, mark .. "2")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 102)
        end
        Equal(head.shown, false, "Session completion closes Talking Head")
        Equal(head.loading, false, "Session completion clears the spinner")
        Equal(h.addon.Narration.Narration, nil, "Release presentation ownership")
    end
end)

Test("Talking Head closes on explicit stop and owned playback failure", function()
    for _, fail in ipairs({ false, true }) do
        local h = Harness(false, true)
        h.environment.QuestFrame:Show()
        h:Panel("QuestFrameDetailPanel")
        h:Click()
        local tts = h.addon.TTS
        if fail then
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101,
                "OUTLOUD:SPEECH:" .. tts.CurrentSession.id .. ":WHOLE")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED", 101, 13)
        else
            tts:Stop()
        end
        Equal(h.addon.UI.TalkingHead.shown, false, "Ended narration closes the UI")
        Equal(h.addon.UI.TalkingHead.loading, false, "Ended narration clears the spinner")
    end
end)

Test("Completion during native submission also closes Talking Head", function()
    local h = Harness(false, true)
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    h.onSpeak = function(text)
        local tts = h.addon.TTS
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, text:match('<bookmark mark="([^"]+)"/>'))
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 101)
    end
    h:Click()
    Equal(h.addon.TTS.CurrentSession, nil, "Synchronous completion ends the session")
    Equal(h.addon.UI.TalkingHead.shown, false, "Do not reopen completed narration")
end)

Test("Failed speech submission hides Talking Head and clears loading", function()
    local h = Harness(false, true)
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    h.failSpeech = true
    local ok, reason = h.integration:SpeakCurrentText()
    Equal(ok, false, "Preserve TTS submission result")
    Equal(reason, "speech-failed", "Preserve TTS failure reason")
    Equal(#h.heads, 1, "Presentation opened before attempted speech")
    Equal(h.addon.UI.TalkingHead.shown, false, "Do not leave failed narration visible")
    Equal(h.addon.UI.TalkingHead.loading, false, "Do not leave failed narration loading")
    Equal(table.concat(h.flow, ","), "model,resolve,head,loading,speak,hide", "Failure cleanup order")
end)

Test("Deferred Blizzard UI installs once after its globals exist", function()
    local h = Harness(true)
    Equal(h.integration.Button, nil, "No incomplete UI hooks")
    local loadFrame = h.integration.LoadFrame
    Equal(loadFrame.events.ADDON_LOADED, true, "Observe UI loading")
    loadFrame:Fire("OnEvent", "ADDON_LOADED", "UnrelatedAddon")
    Equal(#h.created, 1, "Only one load observer")
    h:CreateQuestUI()
    local greeting = h.environment.QuestFrameGreetingPanel
    h.environment.QuestFrameGreetingPanel = nil
    loadFrame:Fire("OnEvent", "ADDON_LOADED", "PartialBlizzardUI")
    Equal(h.integration.Button, nil, "Wait for all required panels")
    h.environment.QuestFrameGreetingPanel = greeting
    h.environment.QuestFrame:Show()
    h:Panel("QuestFrameDetailPanel")
    loadFrame:Fire("OnEvent", "ADDON_LOADED", "Blizzard_UIPanels_Game")
    Equal(h.integration.Button:IsShown(), true, "Refresh existing dialogue on late init")
    Equal(loadFrame.events.ADDON_LOADED, nil, "Stop observing after setup")
    Equal(loadFrame.scripts.OnEvent, nil, "Release observer callback")
    h.integration:Initialize()
    Equal(#h.created, 4, "Observer, button, gap anchor, and model created only once")
    Equal(#h.environment.QuestFrame.hooks.OnEvent, 1, "One event hook")
end)

Test("Late ownership resolves early terminal events and cleans up Talking Head", function()
    for _, mode in ipairs({ "full", "split" }) do
        for _, event in ipairs({ "FAILED", "FINISHED" }) do
            local h = Harness(false, true)
            h.texts.detail = "Only sentence."
            h.addon.Database:SetReadingMode(mode)
            h.environment.QuestFrame:Show()
            h:Panel("QuestFrameDetailPanel")
            h:Click()
            local tts, head = h.addon.TTS, h.addon.UI.TalkingHead
            local session = tts.CurrentSession
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_" .. event, 101, 13)
            Equal(tts.CurrentSession, session, "Unidentified terminal events do not claim narration")
            Equal(head.shown, true)
            Equal(head.loading, true)
            local mark = "OUTLOUD:SPEECH:" .. session.id .. ":" .. (mode == "full" and "WHOLE" or "1")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, mark)
            Equal(tts.CurrentSession, nil)
            Equal(head.shown, false, "Proven terminal event closes Talking Head")
            Equal(head.loading, false, "Cleanup clears the spinner")
            Equal(h.endReason, event == "FAILED" and "failed" or "finished")
            Equal(#h.progress, 0, "Late bookmark cannot restart scrolling or sentence transitions")
            local stops = h.stops
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, mark)
            Equal(h.stops, stops, "Late notifications never call global stop")
        end
    end
end)

print("QuestIntegration: " .. passed .. " mocked checks passed")
