-- Run from the addon root with Lua 5.1: lua Tests/GossipIntegration.lua
-- These mocks exercise real addon modules, not Forever's event timing or rendering.
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
    function frame:SetText(text) self.text = text end
    function frame:SetPoint(...) self.point = { ... } end
    function frame:ClearAllPoints() self.point = nil end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    return frame
end

local function Harness(deferredGossip)
    local h = { created = {}, calls = {}, heads = {}, progress = {}, timers = {}, stops = 0,
        gossipText = "Welcome. How can I help?", updates = 0,
        units = {
            npc = { exists = true, name = "Daniel", sex = 2, modelID = 1011653 },
            questnpc = { exists = true, name = "Quest NPC", sex = 3, modelID = 959310 },
            player = { exists = true, name = "Player", sex = 2 },
        } }
    local environment = setmetatable({}, { __index = _G })
    environment._G = environment
    h.environment = environment
    environment.print = function() end
    function environment.UnitExists(unit) return h.units[unit] and h.units[unit].exists end
    function environment.UnitName(unit) return h.units[unit].name end
    function environment.UnitSex(unit) return h.units[unit].sex end
    function environment.UnitRace(unit)
        Equal(unit, "player", "NPC voice resolution must not call UnitRace")
        return "Undead", "Scourge", 5
    end
    function environment.CreateFrame(kind, _name, parent, template)
        local frame = Frame(parent)
        frame.kind, frame.template = kind, template
        if kind == "PlayerModel" then
            function frame:ClearModel() self.modelID = 0 end
            function frame:SetUnit(unit)
                Equal(self.modelID, 0, "Clear previous quest/gossip model before loading")
                self.unit, self.modelID = unit, h.units[unit].modelID
            end
            function frame:GetModelFileID() return self.modelID end
        end
        h.created[#h.created + 1] = frame
        return frame
    end
    rawset(environment, "hooksecurefunc", function(owner, method, callback)
        local original = assert(owner[method])
        owner[method] = function(...)
            local result = { original(...) }
            callback(...)
            return unpack(result)
        end
    end)
    environment.C_GossipInfo = {
        GetText = function() return h.gossipText end,
        GetOptions = function() error("Do not narrate gossip options") end,
        GetActiveQuests = function() error("Do not narrate quest lists") end,
        GetAvailableQuests = function() error("Do not narrate quest lists") end,
    }
    environment.C_Timer = { NewTimer = function(delay, callback)
        local timer = { delay = delay }
        function timer:Cancel() self.cancelled = true end
        function timer:Fire() callback() end
        h.timers[#h.timers + 1] = timer
        return timer
    end }
    environment.Enum = { TtsBoolSetting = { PlaySoundSeparatingChatLineBreaks = 0 } }
    environment.C_TTSSettings = { SetSetting = function() end }
    environment.C_VoiceChat = {
        GetTtsVoices = function() return { { voiceID = 0 }, { voiceID = 7 }, { voiceID = 9 } } end,
        SpeakText = function(voiceID, text, rate)
            if h.failSpeech then error("Mock speech submission failure") end
            h.calls[#h.calls + 1] = { voiceID = voiceID, rate = rate,
                mark = text:match('^<bookmark mark="([^"]+)"/>'),
                speech = text:gsub('^<bookmark mark="[^"]+"/>', "") }
        end,
        StopSpeakingText = function() h.stops = h.stops + 1 end,
    }

    local addon = {}
    local function Load(path)
        local chunk = assert(LoadFile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    for _, path in ipairs({ "Core/Namespace.lua", "Data/VoiceMappings.lua", "Core/NPCInspection.lua",
        "Core/VoiceSelection.lua", "Core/Database.lua", "Core/TTS.lua", "Core/Narration.lua",
        "UI/QuestIntegration.lua", "UI/GossipIntegration.lua" }) do Load(path) end
    addon.UI.TalkingHead = {
        -- These integration fixtures finish animations immediately. The production
        -- animation lifecycle is exercised separately in Tests/TalkingHead.lua.
        State = "Closed", Initialize = function() end,
        Show = function(self, unit, text, title, onOpened)
            self.shown = true
            self.State = "Opening"
            h.heads[#h.heads + 1] = { unit = unit, text = text, title = title }
            self:SetLoading(true)
            self.opened = function()
                self.State = "Opened"
                onOpened()
            end
            if not h.deferAnimations then self.opened() end
            return true
        end,
        Hide = function(self, reason, trigger)
            if self.State == "Closed" or self.State == "Closing" then return end
            self.State = "Closing"
            addon.Narration:OnClosing(reason, trigger)
            self.shown, self.loading = false, false
            self.closed = function()
                self.State = "Closed"
                addon.Narration:OnClosed()
            end
            if not h.deferAnimations then self.closed() end
        end,
        SetLoading = function(self, loading) self.loading = loading end,
        FinishTextPlayback = function(_, reason) h.endReason = reason end,
        OnTextProgress = function(_, text, chunk)
            h.progress[#h.progress + 1] = { text = text, chunk = chunk }
        end,
    }
    addon.Database:Initialize()
    addon.Database:SetVoice("HUMAN", 2, 0)
    addon.Database:SetVoice("HUMAN", 3, 9)
    addon.Database:SetVoice("UNDEAD", 2, 7)
    addon.Database:SetVoice("UNDEAD", 3, 9)
    h.addon, h.integration = addon, addon.UI.GossipIntegration

    function h:CreateGossipUI()
        local frame = Frame()
        environment.GossipFrame = frame
        frame.GreetingPanel = Frame(frame)
        frame.GreetingPanel.GoodbyeButton = Frame(frame.GreetingPanel)
        frame.GreetingPanel.shown, frame.GreetingPanel.GoodbyeButton.shown = true, true
        frame.Update = function() self.updates = self.updates + 1 end
    end
    function h:Open()
        environment.GossipFrame:Show()
        environment.GossipFrame:Update()
    end
    function h:Click() self.integration.Button:Fire("OnClick") end
    function h:Models()
        local count = 0
        for _, frame in ipairs(self.created) do
            if frame.kind == "PlayerModel" then count = count + 1 end
        end
        return count
    end
    function h:CreateQuestUI()
        environment.QuestFrame = Frame()
        for _, name in ipairs({ "QuestFrameGreetingPanel", "QuestFrameDetailPanel",
            "QuestFrameProgressPanel", "QuestFrameRewardPanel" }) do
            environment[name] = Frame(environment.QuestFrame)
        end
        environment.QuestFrameAcceptButton = Frame(environment.QuestFrame)
        environment.QuestFrameDeclineButton = Frame(environment.QuestFrame)
        environment.QuestFrameAcceptButton.shown, environment.QuestFrameDeclineButton.shown = true, true
        environment.GetQuestText = function() return "Quest dialogue." end
        environment.GetQuestID = function() return 1 end
        environment.GetTitleText = function() return "Quest title" end
        addon.UI.QuestIntegration:Initialize()
        environment.QuestFrameDetailPanel:Show()
        environment.QuestFrame:Show()
    end
    if not deferredGossip then h:CreateGossipUI() end
    h.integration:Initialize()
    return h
end

local passed = 0
local function Test(name, callback)
    local ok, message = pcall(callback)
    assert(ok, name .. ": " .. tostring(message))
    passed = passed + 1
end

Test("One button and model, native anchor, manual-only updates", function()
    local h = Harness()
    local frame, button = h.environment.GossipFrame, h.integration.Button
    Equal(button.parent, frame)
    Equal(button.template, "UIPanelButtonTemplate")
    Equal(button.size[1], 100)
    Equal(button.size[2], 22)
    Equal(button.point[1], "RIGHT")
    Equal(button.point[2], frame.GreetingPanel.GoodbyeButton)
    Equal(button.point[3], "LEFT")
    Equal(button.point[4], -8)
    h.addon.Database:SetAutoNarrateQuests(true)
    local count = #h.created
    for _ = 1, 3 do
        h.integration:Initialize()
        h:Open()
        frame:Update()
        frame:Hide()
    end
    Equal(h.updates, 6, "Blizzard Update still runs")
    Equal(#h.calls, 0, "Opening and content updates never speak")
    Equal(#h.heads, 0)
    Equal(#h.timers, 0)
    Equal(#h.created, count)
    Equal(h:Models(), 1)
    Equal(#frame.hooks.OnShow, 1)
    Equal(#frame.hooks.OnHide, 1)
    Equal(button:IsShown(), false)
end)

Test("Read current greeting only; invalid, hidden and missing text hide controls", function()
    local h = Harness()
    h:Open()
    h.gossipText = "Current page, not the greeting captured on open."
    h:Click()
    Equal(h.heads[1].text, h.gossipText)
    for _, text in ipairs({ false, "", " \n\t", 123 }) do
        h.gossipText = text
        h.environment.GossipFrame:Update()
        Equal(h.integration.Button:IsShown(), false)
        h:Click()
    end
    h.gossipText = nil
    h.environment.GossipFrame:Update()
    Equal(h.integration.Button:IsShown(), false)
    h.gossipText = "Readable again."
    h.environment.C_GossipInfo.GetText = nil
    h.environment.GossipFrame:Update()
    h:Click()
    h.environment.C_GossipInfo = nil
    h:Click()
    Equal(#h.calls, 1, "No invalid or speculative speech")
    h.environment.C_GossipInfo = { GetText = function() return h.gossipText end }
    local goodbye = h.environment.GossipFrame.GreetingPanel.GoodbyeButton
    goodbye:Hide()
    Equal(h.integration.Button:IsShown(), false)
    goodbye:Show()
    Equal(h.integration.Button:IsShown(), true)
    h.environment.GossipFrame.GreetingPanel:Hide()
    h:Click()
    Equal(h.integration.Button:IsShown(), false)
    Equal(#h.calls, 1)
end)

Test("Multiple Voices uses live model and gender; Single Voice uses player and NPC title", function()
    local h = Harness()
    h:Open()
    h:Click()
    Equal(h.calls[1].voiceID, 0, "Daniel's real generated HUMAN model mapping")
    Equal(h.heads[1].unit, "npc")
    Equal(h.heads[1].title, "Daniel")
    h.units.npc.sex, h.units.npc.name = 3, "Female NPC"
    h:Click()
    Equal(h.calls[2].voiceID, 9)
    Equal(h.heads[2].title, "Female NPC")
    h.addon.Database:SetVoiceMode("single")
    h.addon.Database:SetSingleVoice(7)
    h.units.npc.modelID, h.units.npc.sex = 0, nil
    h:Click()
    Equal(h.calls[3].voiceID, 7, "Single Voice does not require an NPC model or gender")
    Equal(h.heads[3].unit, "player")
    Equal(h.heads[3].title, "Female NPC")
    h.addon.Database:SetSingleVoice(nil)
    h:Click()
    h.addon.Database:SetSingleVoice(999)
    h:Click()
    Equal(#h.calls, 3, "An unavailable Single Voice cannot choose a family voice")
end)

Test("NPC failures use the configured player; failed fallback starts nothing", function()
    local h = Harness()
    h:Open()
    h:Click()
    h.units.npc.modelID = 0
    h:Click()
    Equal(h.addon.NPCInspection.Model:GetModelFileID(), 0, "No previous Daniel model")
    h.units.npc.modelID = 999
    h:Click()
    h.units.npc.modelID, h.units.npc.sex = 1011653, 1
    h:Click()
    h.units.npc.sex = nil
    h:Click()
    h.units.npc.sex = 2
    h.addon.Database:SetVoice("HUMAN", 2, nil)
    h:Click()
    h.addon.Database:SetVoice("HUMAN", 2, 999)
    h:Click()
    h.units.npc.exists = false
    h:Click()
    for index = 2, #h.calls do
        Equal(h.calls[index].voiceID, 7)
        Equal(h.heads[index].unit, "player")
    end
    Equal(h.heads[#h.heads].title, "Unknown", "Missing NPC cannot reuse an old name")
    local count = #h.calls
    h.addon.Database:SetVoice("UNDEAD", 2, nil)
    h:Click()
    Equal(#h.calls, count)
    Equal(#h.heads, count)
end)

Test("Gossip before deferred QuestFrame and alternating NPC loads reuse one model", function()
    local h = Harness()
    local quest = h.addon.UI.QuestIntegration
    quest:Initialize()
    Equal(quest.Model, nil, "QuestFrame has not loaded")
    h:Open()
    h:Click()
    local model = h.addon.NPCInspection.Model
    h:CreateQuestUI()
    Equal(quest.Model, model)
    Equal(quest.LoadFrame.events.ADDON_LOADED, nil)
    for _ = 1, 3 do
        quest:SpeakCurrentText()
        Equal(model.unit, "questnpc")
        Equal(h.calls[#h.calls].voiceID, 9)
        h:Click()
        Equal(model.unit, "npc")
        Equal(h.calls[#h.calls].voiceID, 0)
    end
    Equal(h:Models(), 1)
    h.environment.GossipFrame:Hide()
    h:Click()
    local count = #h.calls
    h.units.npc = { exists = true, name = "New NPC", sex = 3, modelID = 959310 }
    h.gossipText = "A new conversation."
    h:Open()
    h:Click()
    Equal(#h.calls, count + 1)
    Equal(h.heads[#h.heads].title, "New NPC")
    Equal(h.heads[#h.heads].text, h.gossipText)
    Equal(model:GetModelFileID(), 959310)
end)

Test("Deferred Gossip initialization succeeds once with an existing quest model", function()
    local h = Harness(true)
    local observer = h.integration.LoadFrame
    observer:Fire("OnEvent", "ADDON_LOADED", "UnrelatedAddon")
    Equal(#h.created, 1, "One observer; no incomplete UI")
    h:CreateQuestUI()
    local model = h.addon.NPCInspection.Model
    h:CreateGossipUI()
    local goodbye = h.environment.GossipFrame.GreetingPanel.GoodbyeButton
    h.environment.GossipFrame.GreetingPanel.GoodbyeButton = nil
    observer:Fire("OnEvent", "ADDON_LOADED", "PartialUI")
    Equal(h.integration.Button, nil)
    h.environment.GossipFrame.GreetingPanel.GoodbyeButton = goodbye
    h:Open()
    observer:Fire("OnEvent", "ADDON_LOADED", "Blizzard_UIPanels_Game")
    Equal(h.integration.Button:IsShown(), true)
    Equal(observer.events.ADDON_LOADED, nil)
    Equal(observer.scripts.OnEvent, nil)
    Equal(h.addon.NPCInspection.Model, model)
    Equal(h:Models(), 1)
    local count = #h.created
    h.integration:Initialize()
    Equal(#h.created, count)
    Equal(#h.calls, 0)
end)

Test("Existing dispatcher preserves original display, sanitization, escaping, rate and bookmarks", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness()
        h.gossipText = "  A/B & C_<D>.\n Next|page~here!  "
        h.addon.Database:SetReadingMode(mode)
        h.addon.Database:SetSpeechRate(3)
        h:Open()
        h:Click()
        Equal(h.heads[1].text, h.gossipText)
        Equal(h.calls[1].rate, 3)
        Equal(h.calls[1].speech, mode == "full"
            and "A B &amp; C D . Next page here!" or "A B &amp; C D .")
        Equal(#h.calls, 1)
        local tts, head = h.addon.TTS, h.addon.UI.TalkingHead
        Equal(tts.CurrentSession.source, "Gossip", "Diagnostic source comes from the actual caller")
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, h.calls[1].mark)
        Equal(head.loading, false)
        Equal(h.progress[1].text, mode == "full" and h.gossipText or "A/B & C_<D>.")
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 101)
        if mode == "split" then
            Equal(#h.calls, 2, "Prefetch exactly one sentence ahead")
            Equal(h.calls[2].speech, "Next page here!")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 102, h.calls[2].mark)
            Equal(h.progress[2].text, "Next|page~here!")
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 102)
        end
        Equal(tts.CurrentSession, nil)
        Equal(head.shown, false)
        Equal(head.loading, false)
    end
end)

Test("Repeated clicks replace sessions; stale bookmarks cannot update the new conversation", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness()
        h.addon.Database:SetReadingMode(mode)
        h:Open()
        h:Click()
        local tts, head = h.addon.TTS, h.addon.UI.TalkingHead
        local pendingCall = 1
        if mode == "split" then
            tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 100, h.calls[1].mark)
            pendingCall = 2
        end
        local oldMark = h.calls[pendingCall].mark
        local progress = #h.progress
        h.units.npc.name, h.gossipText = "Next NPC", "Current text."
        h:Click()
        local replacement = tts.CurrentSession
        local newCall = #h.calls
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, oldMark)
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 101, oldMark)
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 101)
        local expectedStops = mode == "split" and 2 or 1
        Equal(h.stops, expectedStops, "Split may request one experimental stop; Full policy is preserved")
        Equal(tts.CurrentSession, replacement)
        Equal(head.loading, true)
        Equal(#h.progress, progress)
        Equal(h.heads[2].title, "Next NPC")
        Equal(h.heads[2].text, "Current text.")
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 102, h.calls[newCall].mark)
        Equal(head.loading, false, "New owned playback still clears loading")
        h.environment.GossipFrame:Hide()
        h:Click()
        Equal(#h.calls, newCall, "Closed UI cannot start a stale narration")
        Equal(head.shown, true, "Closing follows the existing quest playback convention")
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 102)
        Equal(replacement.finished, true)
        Equal(head.shown, false)
        Equal(head.loading, false)
        tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", 102, h.calls[newCall].mark)
        Equal(h.stops, expectedStops, "Completed bookmark does not request another stop")
    end
end)

Test("Manual Gossip narration cancels a pending automatic quest request", function()
    local h = Harness()
    h:CreateQuestUI()
    h.addon.Database:SetAutoNarrateQuests(true)
    h.environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    local timer = h.timers[1]
    Equal(timer.delay, 2, "Existing automatic delay remains unchanged")
    h:Open()
    Equal(#h.calls, 0)
    h:Click()
    Equal(timer.cancelled, true, "Existing StartSession hook cancels the quest delay")
    timer:Fire()
    Equal(#h.calls, 1, "No duplicate quest session after manual gossip")
end)

Test("Submission failures and empty sanitized text clean up presentation", function()
    for _, mode in ipairs({ "full", "split" }) do
        for _, fail in ipairs({ true, false }) do
            local h = Harness()
            h.addon.Database:SetReadingMode(mode)
            h.failSpeech = fail
            if not fail then h.gossipText = " / \\ | _ ~ " end
            h:Open()
            h:Click()
            Equal(h.addon.TTS.CurrentSession, nil)
            Equal(h.addon.UI.TalkingHead.shown, false)
            Equal(h.addon.UI.TalkingHead.loading, false)
        end
    end
end)

Test("Gossip requests cancel the automatic delay before opening completes", function()
    local h = Harness()
    h.deferAnimations = true
    h:CreateQuestUI()
    h.addon.Database:SetAutoNarrateQuests(true)
    h.environment.QuestFrame:Fire("OnEvent", "QUEST_DETAIL")
    local timer = h.timers[1]
    h:Open(); h:Click()
    Equal(timer.cancelled, true)
    Equal(#h.calls, 0, "Accepted presentation cancels the timer before any TTS session")
    timer:Fire()
    h.addon.UI.TalkingHead.opened()
    Equal(#h.calls, 1)
end)

Test("Changed or closed gossip invalidates speech waiting for animations", function()
    for _, change in ipairs({ "text", "npc", "hide", "refresh" }) do
        local h = Harness()
        h.deferAnimations = true
        h:Open(); h:Click()
        if change == "text" then h.gossipText = "New greeting."
        elseif change == "npc" then h.units.npc.name = "Other NPC"
        elseif change == "hide" then h.environment.GossipFrame:Hide()
        else h.environment.GossipFrame:Update() end
        h.addon.UI.TalkingHead.opened()
        Equal(#h.calls, 0)
        Equal(h.addon.Narration.Narration, nil)
    end
end)

print("GossipIntegration: " .. passed .. " mocked checks passed")
