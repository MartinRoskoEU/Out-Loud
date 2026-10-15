-- Run from the addon root with Lua 5.1: lua Tests/TalkingHead.lua
-- Real TalkingHead, Narration, TTS, settings and diagnostics; mocked UI/native APIs.
-- Animation callbacks are explicit inputs, not proof of Forever rendering/timing.
local LoadFile = assert(rawget(_G, "loadfile"))

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function Node()
    local node = { scripts = {}, hooks = {}, shown = false, width = 400, height = 100 }
    function node:SetScript(event, callback) self.scripts[event] = callback end
    function node:HookScript(event, callback)
        self.hooks[event] = self.hooks[event] or {}
        table.insert(self.hooks[event], callback)
    end
    function node:Fire(event, ...)
        if self.scripts[event] then self.scripts[event](self, ...) end
        for _, callback in ipairs(self.hooks[event] or {}) do callback(self, ...) end
    end
    function node:Show() self.shown = true; self:Fire("OnShow") end
    function node:Hide()
        if not self.shown then return end
        self.shown = false
        self:Fire("OnHide")
    end
    function node:IsShown() return self.shown end
    function node:SetAlpha(alpha) self.alpha = alpha end
    function node:SetSize(width, height) self.width, self.height = width, height end
    function node:GetWidth() return self.width end
    function node:GetHeight() return self.height end
    function node:SetWidth(width) self.width = width end
    function node:SetHeight(height) self.height = height end
    function node:SetText(text) self.text = text end
    function node:GetStringHeight() return 40 end -- No overflow/scroll timers in these cases.
    function node:SetUnit(unit) self.unit = unit end
    function node:SetAnimation(animation) self.animation = animation end
    function node:SetAtlas(atlas) self.atlas = atlas end
    function node:SetVerticalScroll(offset) self.offset = offset end
    function node:GetVerticalScroll() return self.offset or 0 end
    function node:RegisterCallback(event, callback) self.scripts[event] = callback end
    function node:SetScrollPercentage(percentage) self:Fire("OnScroll", percentage) end
    function node:GetThumb() return self.thumb end
    function node:GetTrack() return self.track end
    for _, method in ipairs({ "SetPoint", "ClearAllPoints", "SetScale", "SetFrameStrata",
        "SetFrameLevel", "SetClipsChildren", "EnableMouseWheel", "SetShadowColor", "SetTextColor",
        "SetWordWrap", "SetPortraitZoom", "SetHideIfUnscrollable", "SetVisibleExtentPercentage",
        "SetPanExtentPercentage", "UnregisterUpdate", "UpdateScrollChildRect", "RegisterEvent" }) do
        node[method] = function() end
    end
    return node
end

local function Group()
    local group = Node()
    function group:Play() self.playing = true; self.plays = (self.plays or 0) + 1 end
    function group:Stop() self.playing = false end
    function group:IsPlaying() return self.playing end
    function group:Finish() self.playing = false; self:Fire("OnFinished") end
    return group
end

local function Template()
    local frame = Node()
    frame.NameFrame, frame.TextFrame, frame.BackgroundFrame, frame.PortraitFrame = Node(), Node(), Node(), Node()
    frame.NameFrame.Name, frame.BackgroundFrame.TextBackground, frame.PortraitFrame.Portrait = Node(), Node(), Node()
    frame.TextFrame.Scroll = Node()
    frame.TextFrame.Scroll.Content = Node()
    frame.TextFrame.Scroll.Content.Text = Node()
    for _, part in ipairs({ frame.NameFrame, frame.TextFrame, frame.BackgroundFrame, frame.PortraitFrame }) do
        part.Fadein, part.Close = Group(), Group()
    end
    frame.TextFrame.SentenceOut, frame.TextFrame.SentenceIn = Group(), Group()
    local main = Node()
    frame.MainFrame = main
    main.Model, main.CloseButton, main.Sheen, main.TextSheen = Node(), Node(), Node(), Node()
    main.Model.PortraitBg = Node()
    main.Overlay = { Glow_TopBar = Node(), Glow_LeftBar = Node(), Glow_RightBar = Node() }
    main.TalkingHeadsInAnim, main.Close = Group(), Group()
    return frame
end

local function Harness(mode, withoutDiagnostics)
    local h = { calls = {}, stops = 0, errors = {}, mode = mode or "full", exists = true }
    local environment = setmetatable({}, { __index = _G })
    environment._G, environment.UIParent = environment, Node()
    environment.print = function(...) h.errors[#h.errors + 1] = { ... } end
    environment.GetTime = function() return 0 end
    environment.UnitExists = function() return h.exists end
    environment.UnitName = function(unit) return unit end
    environment.UnitFactionGroup = function() return "Alliance" end
    environment.C_Texture = { GetAtlasExists = function() return true end }
    environment.ScrollBoxConstants = { NoScrollInterpolation = true }
    environment.C_Timer = { NewTimer = function() error("Lifecycle must not use timers") end,
        After = function() error("Lifecycle must not use timers") end }
    environment.Enum = { TtsBoolSetting = { PlaySoundSeparatingChatLineBreaks = 0 } }
    environment.C_TTSSettings = { SetSetting = function() end }
    environment.CreateFrame = function(_, _, _, template)
        if template == "OutLoudTalkingHeadTemplate" then return Template() end
        local frame = Node()
        if template == "MinimalScrollBar" then frame.thumb, frame.track = Node(), Node() end
        return frame
    end
    rawset(environment, "hooksecurefunc", function(owner, method, callback)
        local original = assert(owner[method])
        owner[method] = function(...)
            local results = { original(...) }
            callback(...)
            return unpack(results)
        end
    end)
    environment.C_VoiceChat = {
        SpeakText = function(voiceID, text)
            if not h.directSpeech then
                Equal(h.head.State, "Opened", "Native speech is gated by completed opening")
            end
            if h.failSpeech then error("Mock submission error") end
            h.calls[#h.calls + 1] = { voiceID = voiceID, text = text,
                mark = text:match('^<bookmark mark="([^"]+)"/>') }
            if h.onSpeak then h.onSpeak() end
        end,
        StopSpeakingText = function()
            h.stops = h.stops + 1
            if h.onStop then h.onStop() end
        end,
    }
    local addon = {}
    for _, path in ipairs({ "Core/Namespace.lua", "Core/VoiceSelection.lua", "Core/Database.lua",
        "Core/TTSDiagnostics.lua", "Core/TTS.lua", "Core/Narration.lua", "UI/TalkingHead.lua" }) do
        if not withoutDiagnostics or path ~= "Core/TTSDiagnostics.lua" then
            local chunk = assert(LoadFile(path))
            setfenv(chunk, environment)
            chunk("OutLoud", addon)
        end
    end
    addon.Database:Initialize()
    addon.Database:SetReadingMode(h.mode)
    h.addon, h.head, h.narration, h.tts = addon, addon.UI.TalkingHead, addon.Narration, addon.TTS
    h.head:Initialize()
    h.open = h.head.Frame.MainFrame.TalkingHeadsInAnim
    h.close = h.head.Frame.MainFrame.Close
    function h:Speak(text, isCurrent)
        return self.narration:Speak("player", text or "First. Second. Third.", 7, "Title", "Quest", isCurrent)
    end
    function h:ManualClose() self.head.CloseButton:Fire("OnClick") end
    function h:Bookmark(index, id) self.tts:OnEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", id, self.calls[index].mark) end
    return h
end

local passed = 0
local function Test(name, callback)
    local ok, message = pcall(callback)
    assert(ok, name .. ": " .. tostring(message))
    passed = passed + 1
end

Test("Only main opening completion starts speech; duplicate completion is inert", function()
    for _, mode in ipairs({ "full", "split" }) do
        local h = Harness(mode)
        Equal(h.head.State, "Closed")
        Equal(h:Speak(), true)
        Equal(h.head.State, "Opening")
        Equal(#h.calls, 0)
        Equal(h.tts.CurrentSession, nil)
        for index = 2, #h.head.FadeInGroups do h.head.FadeInGroups[index]:Finish() end
        Equal(#h.calls, 0, "Shorter fades do not open the speech gate")
        h.open:Finish()
        Equal(h.head.State, "Opened")
        Equal(#h.calls, 1)
        Equal(h.tts.CurrentSession.mode, mode)
        Equal(h.head.DialogText.text, mode == "full" and "First. Second. Third." or "First.")
        Equal(h.head.Spinner:IsShown(), true, "Completion of opening is not playback ownership")
        h.open:Finish()
        Equal(#h.calls, 1)
        h:Bookmark(1, 101)
        Equal(h.head.Spinner:IsShown(), false)
        Equal(#h.calls, mode == "split" and 2 or 1, "Split still prefetches exactly one")
        h:Bookmark(1, 101)
        Equal(#h.calls, mode == "split" and 2 or 1)
    end
end)

Test("Replacement stops immediately, completes closing, then completes opening", function()
    local h = Harness()
    h:Speak("Old."); h.open:Finish()
    local oldSession = h.tts.CurrentSession
    h:Speak("New.")
    Equal(h.head.State, "Closing")
    Equal(h.tts.CurrentSession, nil)
    Equal(oldSession.cancelled, true)
    Equal(oldSession.stopTrigger, "replacement:Quest")
    Equal(h.stops, 1)
    Equal(h.head.Frame:IsShown(), true, "Keep outgoing content for its exit")
    Equal(h.head.DialogText.text, "Old.")
    for index = 1, #h.head.CloseGroups - 1 do h.head.CloseGroups[index]:Finish() end
    Equal(h.head.State, "Closing")
    Equal(#h.calls, 1)
    h.close:Finish()
    Equal(h.head.State, "Opening")
    Equal(h.head.DialogText.text, "New.")
    Equal(#h.calls, 1)
    h.open:Finish()
    Equal(#h.calls, 2)
end)

Test("Rapid requests retain only the latest; obsolete opening and close callbacks are inert", function()
    local h = Harness()
    h:Speak("A.")
    local oldOpen = h.open.scripts.OnFinished
    h:Speak("B.")
    local oldClose = h.close.scripts.OnFinished
    h:Speak("C.")
    Equal(h.close.plays, 1, "Do not restart an existing exit")
    oldOpen()
    Equal(#h.calls, 0)
    h.close:Finish()
    Equal(h.head.DialogText.text, "C.")
    oldOpen(); oldClose()
    Equal(h.head.State, "Opening")
    Equal(#h.calls, 0)
    h:Speak("D.")
    oldClose()
    Equal(h.head.State, "Closing", "Prior close cannot finish a newer exit")
    h.close:Finish(); h.open:Finish()
    Equal(#h.calls, 1)
    assert(h.calls[1].text:find("D.", 1, true))
end)

Test("Manual close cancels opening, active and replacement requests immediately", function()
    for _, phase in ipairs({ "Opening", "Opened", "Closing" }) do
        local h = Harness("split")
        h:Speak()
        local opening = h.open.scripts.OnFinished
        if phase ~= "Opening" then h.open:Finish(); h:Bookmark(1, 101) end
        if phase == "Closing" then h:Speak("Pending.") end
        local calls, stops = #h.calls, h.stops
        h:ManualClose()
        Equal(h.narration.Narration, nil)
        Equal(h.tts.CurrentSession, nil)
        Equal(h.head.State, "Closing")
        Equal(h.head.Spinner:IsShown(), false)
        Equal(h.stops, stops + (phase == "Opened" and 1 or 0))
        opening(); h.close:Finish(); opening()
        Equal(h.head.State, "Closed")
        Equal(#h.calls, calls, "Cancelled entrances cannot submit speech")
        if calls > 1 then
            h:Bookmark(2, 102)
            Equal(#h.calls, calls, "Cancelled prefetch cannot advance")
        end
    end
end)

Test("Direct STOP and direct TTS replacement cancel requests before submission", function()
    for _, phase in ipairs({ "Opening", "Closing" }) do
        local h = Harness()
        h:Speak()
        if phase == "Closing" then h:Speak("Pending.") end
        Equal(h.tts:Stop(), false, "No TTS session exists yet")
        Equal(h.narration.Narration, nil)
        h.close:Finish(); h.open:Finish()
        Equal(#h.calls, 0)
    end
    local h = Harness()
    h:Speak()
    -- Observe direct speech separately; it intentionally has no Talking Head gate.
    h.directSpeech = true
    h.tts:SpeakWholeText("Direct.", 7)
    h.directSpeech = nil
    Equal(h.narration.Narration, nil)
    Equal(#h.calls, 1)
    h.close:Finish(); h.open:Finish()
    Equal(#h.calls, 1)
    Equal(h.tts.CurrentSession.source, "Direct TTS")
end)

Test("Source validity is checked both before delayed Show and at opening completion", function()
    local h = Harness()
    local current = true
    h:Speak("A.")
    h:Speak("B.", function() return current end)
    current = false
    h.close:Finish()
    Equal(h.head.State, "Closed")
    Equal(h.narration.Narration, nil)
    current = true
    h:Speak("C.", function() return current end)
    current = false
    h.open:Finish()
    Equal(h.head.State, "Closing")
    Equal(#h.calls, 0)
end)

Test("Unexpected root Hide and direct TalkingHead Hide cannot revive pending narration", function()
    for _, root in ipairs({ true, false }) do
        local h = Harness()
        h:Speak()
        local opening = h.open.scripts.OnFinished
        if root then h.head.Frame:Hide() else h.head:Hide() end
        Equal(h.narration.Narration, nil)
        opening(); h.close:Finish()
        Equal(h.head.State, "Closed")
        Equal(#h.calls, 0)
    end
end)

Test("Owned finish/failure and submission rejection close in both modes", function()
    for _, mode in ipairs({ "full", "split" }) do
        for _, outcome in ipairs({ "finished", "failed", "submission", "empty" }) do
            local h = Harness(mode)
            h.failSpeech = outcome == "submission"
            h:Speak(outcome == "empty" and " / | _ ~ " or "One.")
            h.open:Finish()
            if outcome == "finished" or outcome == "failed" then
                h:Bookmark(1, 101)
                h.tts:OnEvent(outcome == "finished" and "VOICE_CHAT_TTS_PLAYBACK_FINISHED"
                    or "VOICE_CHAT_TTS_PLAYBACK_FAILED", 101, 13)
            end
            Equal(h.head.State, "Closing")
            Equal(h.narration.Narration, nil)
            Equal(h.tts.CurrentSession, nil)
            Equal(h.head.Spinner:IsShown(), false)
            h.close:Finish()
            Equal(h.head.State, "Closed")
        end
    end
end)

Test("Stale Split bookmarks preserve idle STOP, Emergency STOP and diagnostics", function()
    local h = Harness("split")
    h:Speak(); h.open:Finish(); h:Bookmark(1, 101)
    h:Speak("Replacement.")
    local calls = #h.calls
    h:Bookmark(2, 102)
    Equal(h.stops, 2, "Existing idle stale-bookmark follow-up remains active while closing")
    Equal(#h.calls, calls)
    h.close:Finish(); h.open:Finish()
    local active = Harness("split")
    active:Speak(); active.open:Finish(); active:Bookmark(1, 101)
    active:Speak("New."); active.close:Finish(); active.open:Finish()
    local current = active.tts.CurrentSession
    active:Bookmark(2, 102)
    Equal(active.stops, 2, "Existing Emergency STOP remains available after the entrance")
    Equal(current.emergencyRecoveryAttempted, true)
    Equal(active.tts.CurrentSession, current)
    Equal(#active.calls, 3, "Emergency STOP does not resubmit")
    active:Bookmark(2, 102)
    Equal(active.stops, 2)
    local report = h.addon.TTSDiagnostics:GetReport()
    assert(report:find("narration-requested", 1, true))
    assert(report:find("source=Quest", 1, true))
    assert(report:find("trigger=replacement:Quest", 1, true))
end)

Test("No diagnostics dependency; reading-mode changes during opening stay consistent", function()
    local h = Harness("full", true)
    h:Speak()
    h.addon.Database:SetReadingMode("split")
    h.open:Finish()
    Equal(h.head.DisplayChunk, 1)
    Equal(h.head.DialogText.text, "First.")
    Equal(h.tts.CurrentSession.mode, "split")
    h:ManualClose(); h.close:Finish()
    Equal(h.head.State, "Closed")
end)

Test("Native STOP reentrancy keeps the latest request and ignores obsolete speech callbacks", function()
    for _, external in ipairs({ false, true }) do
        local h = Harness()
        h:Speak("Old."); h.open:Finish()
        local old = h.tts.CurrentSession
        local ended, started, progress = old.onSessionEnded, old.onPlaybackStarted, old.onTextProgress
        h.onStop = function()
            h.onStop = nil
            h:Speak("Latest.")
        end
        if external then h.tts:Stop() else h:Speak("Intermediate.") end
        Equal(h.narration.Narration.text, "Latest.")
        Equal(h.head.State, "Closing")
        Equal(h.stops, 1)
        h.close:Finish(); h.open:Finish()
        Equal(#h.calls, 2)
        assert(h.calls[2].text:find("Latest.", 1, true))
        ended("cancelled"); started(); progress("Obsolete.", 5, 0)
        Equal(h.head.State, "Opened")
        Equal(h.head.Spinner:IsShown(), true)
        Equal(h.head.DialogText.text, "Latest.")
    end
end)

Test("Manual close during native submission cannot resurrect presentation", function()
    local h = Harness()
    h.onSpeak = function() h:ManualClose() end
    h:Speak()
    local opening = h.open.scripts.OnFinished
    h.open:Finish()
    Equal(h.head.State, "Closing")
    Equal(h.tts.CurrentSession, nil)
    Equal(h.narration.Narration, nil)
    Equal(h.stops, 1)
    h.close:Finish(); opening()
    Equal(h.head.State, "Closed")
    Equal(#h.calls, 1)
end)

Test("Unavailable unit rejects delayed opening instead of submitting invisible speech", function()
    local h = Harness()
    h:Speak("Old."); h.open:Finish()
    h:Speak("New.")
    h.exists = false
    h.close:Finish()
    Equal(h.head.State, "Closed")
    Equal(h.narration.Narration, nil)
    Equal(#h.calls, 1)
end)

print("TalkingHead: " .. passed .. " mocked lifecycle checks passed")
