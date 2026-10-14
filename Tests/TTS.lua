-- Run from the addon root with Lua 5.1: lua Tests/TTS.lua
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness()
    local test = { calls = {}, order = {}, diagnostics = {}, stops = 0, settings = 0, frames = 0 }
    local environment = setmetatable({}, { __index = _G })
    environment._G = environment
    environment.print = function(...)
        test.diagnostics[#test.diagnostics + 1] = { ... }
    end
    environment.C_Timer = { After = function() error("Speech must not use timers") end }
    environment.VoiceSelection = nil
    environment.Enum = { TtsBoolSetting = { PlaySoundSeparatingChatLineBreaks = 0 } }
    environment.C_TTSSettings = { SetSetting = function(setting, value)
        Equal(setting, 0, "Only the separator setting is changed")
        Equal(value, false, "Disable separator sound")
        test.settings = test.settings + 1
    end }
    environment.CreateFrame = function()
        test.frames = test.frames + 1
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:SetScript(event, callback)
            Equal(event, "OnEvent")
            self.callback = callback
        end
        test.frame = frame
        return frame
    end
    environment.C_VoiceChat = {
        GetTtsVoices = function() error("Speech must use the supplied voice ID") end,
        SpeakText = function(voiceID, text, rate, volume, overlap)
            local call = {
                voiceID = voiceID, text = text, rate = rate,
                volume = volume, overlap = overlap,
                mark = text:match('^<bookmark mark="([^"]+)"/>'),
                spoken = text:gsub('^<bookmark mark="[^"]+"/>', ""),
            }
            test.calls[#test.calls + 1] = call
            test.order[#test.order + 1] = "speak"

            if test.onSpeak then return test.onSpeak(#test.calls) end
        end,
        StopSpeakingText = function()
            test.stops = test.stops + 1
            test.order[#test.order + 1] = "stop"
            if test.onStop then test.onStop() end
        end,
    }

    local addon = {}
    for _, path in ipairs({
        "Core/Namespace.lua", "Core/VoiceSelection.lua", "Core/Database.lua", "Core/TTS.lua",
    }) do
        local chunk = assert(LoadFile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    addon.Database:Initialize()
    test.tts = addon.TTS
    test.db = addon.Database
    test.environment = environment
    test.addon = addon
    test.voiceSelection = addon.VoiceSelection
    -- No classifier or NPC/quest API is available to the controller.
    addon.VoiceSelection = nil

    function test:Event(event, ...)
        self.frame.callback(self.frame, "VOICE_CHAT_TTS_PLAYBACK_" .. event, ...)
    end
    function test:Bookmark(callIndex, utteranceID)
        self:Event("BOOKMARK", utteranceID, self.calls[callIndex].mark)
    end

    return test
end

local passed = 0
local function Test(name, callback)
    local ok, reason = pcall(callback)
    assert(ok, name .. ": " .. tostring(reason))
    passed = passed + 1
end

local text = "First sentence. Second sentence. Third sentence."

Test("Streaming submits immediately and stays one sentence ahead", function()
    local test = Harness()
    Equal(test.tts:SpeakStreaming(text, 0), true)
    Equal(#test.calls, 1, "Only sentence 1 is initially submitted")
    Equal(test.calls[1].spoken, "First sentence.")
    test:Event("STARTED", 101)
    test:Event("BOOKMARK", 101, "Start")
    Equal(#test.calls, 1, "Only our bookmark authorizes prefetch")
    test:Bookmark(1, 101)
    Equal(#test.calls, 2)
    Equal(test.calls[2].spoken, "Second sentence.")
    test:Event("FINISHED", 101)
    assert(test.tts.CurrentSession, "An intermediate finish must not end the session")
    Equal(#test.calls, 2, "Finish does not prefetch")
    test:Bookmark(2, 102)
    Equal(#test.calls, 3)
    Equal(test.calls[3].spoken, "Third sentence.")
    test:Bookmark(3, 103)
    Equal(#test.calls, 3)
end)

Test("Tested splitter preserves punctuation and normalizes whitespace", function()
    local test = Harness()
    test.tts:SpeakStreaming("  Hello!\n How\tare you? I am fine.  ", 7)
    test:Bookmark(1, 101)
    test:Bookmark(2, 102)
    Equal(#test.calls, 3)
    Equal(test.calls[1].spoken, "Hello!")
    Equal(test.calls[2].spoken, "How are you?")
    Equal(test.calls[3].spoken, "I am fine.")
    for _, call in ipairs(test.calls) do
        Equal(call.voiceID, 7)
        Equal(call.rate, 0)
        Equal(call.volume, 100)
        Equal(call.overlap, false)
    end
end)

Test("Whole text normalizes speech whitespace in exactly one request", function()
    local test = Harness()
    local whole = "  First sentence.\nSecond sentence.\tThird sentence.  "
    Equal(test.tts:SpeakWholeText(whole, 7), true)
    Equal(#test.calls, 1)
    Equal(test.calls[1].spoken, text, "Normalize speech without splitting the request")
    Equal(test.tts.CurrentSession.text, whole, "Keep the full original display text")
    Equal(test.calls[1].mark, "OUTLOUD:SPEECH:1:WHOLE")
    Equal(test.tts.CurrentSession.sentences, nil)
    Equal(test.tts.CurrentSession.queued, nil)
    test:Bookmark(1, 101)
    Equal(#test.calls, 1, "Whole bookmark never prefetches")
    test:Event("FINISHED", 101)
    Equal(test.tts.CurrentSession, nil)
end)

Test("Dispatcher uses the existing saved readingMode", function()
    local test = Harness()
    local stream, whole = 0, 0
    test.tts.SpeakStreaming = function(_, suppliedText, suppliedVoice)
        Equal(suppliedText, text)
        Equal(suppliedVoice, 7)
        stream = stream + 1
        return true
    end
    test.tts.SpeakWholeText = function(_, suppliedText, suppliedVoice)
        Equal(suppliedText, text)
        Equal(suppliedVoice, 7)
        whole = whole + 1
        return true
    end
    test.tts:Speak(text, 7)
    Equal(whole, 1, "Existing default is full")
    test.db:SetReadingMode(test.tts.ReadingModes.SPLIT)
    test.tts:Speak(text, 7)
    Equal(stream, 1)
    Equal(whole, 1)
    test.db:SetReadingMode(test.tts.ReadingModes.FULL)
    test.tts:Speak(text, 7)
    Equal(whole, 2)
    Equal(stream, 1)
end)

for _, modes in ipairs({
    { "SpeakStreaming", "SpeakStreaming" },
    { "SpeakStreaming", "SpeakWholeText" },
    { "SpeakWholeText", "SpeakStreaming" },
    { "SpeakWholeText", "SpeakWholeText" },
}) do
    Test("Cancellation " .. modes[1] .. " -> " .. modes[2], function()
        local test = Harness()
        test.tts[modes[1]](test.tts, text, 7)
        local old = test.tts.CurrentSession
        test.tts[modes[2]](test.tts, "New narration.", 8)
        Equal(old.cancelled, true)
        Equal(test.tts.CurrentSession.id, old.id + 1)
        Equal(test.stops, 1)
        Equal(#test.calls, 2, "Start replacement immediately")
        Equal(test.order[2], "stop")
        Equal(test.order[3], "speak")
        Equal(test.calls[2].voiceID, 8)
        assert(test.calls[1].mark ~= test.calls[2].mark, "Unique session bookmarks")
    end)
end

Test("Stale prefetched bookmarks cannot stop or advance newer narration", function()
    for _, method in ipairs({ "SpeakStreaming", "SpeakWholeText" }) do
        local test = Harness()
        test.tts:SpeakStreaming(text .. " Fourth sentence.", 7)
        local old = test.tts.CurrentSession
        test:Bookmark(1, 101)
        test:Bookmark(2, 102)
        Equal(#test.calls, 3, "Sentence three is already submitted while sentence two plays")
        test.tts[method](test.tts, "New sentence. Another sentence.", 7)
        local replacement = test.tts.CurrentSession
        test:Bookmark(3, 103)
        test:Bookmark(3, 103)
        Equal(#test.calls, 4, "The delayed old bookmark cannot submit sentence four")
        Equal(old.queued[4], nil)
        Equal(test.stops, 1, "Only initial replacement stops playback")
        Equal(replacement.cancelled, nil)
        Equal(test.tts.CurrentSession, replacement)
        test:Bookmark(4, 104)
        Equal(replacement.playbackStarted, true, "New narration continues normally")
        test:Event("FINISHED", 104)
        if method == "SpeakStreaming" then
            Equal(#test.calls, 5, "New session keeps one-sentence-ahead prefetch")
            Equal(test.calls[5].spoken, "Another sentence.")
            test:Bookmark(5, 105)
            test:Event("FINISHED", 105)
        end
        Equal(replacement.finished, true)
        Equal(test.tts.CurrentSession, nil)
        test:Bookmark(3, 103)
        Equal(test.stops, 1, "An ignored active-session bookmark cannot stop unrelated audio later")
    end
end)

Test("Late bookmarks remain recognizable after Stop and cleanup", function()
    for _, method in ipairs({ "SpeakStreaming", "SpeakWholeText" }) do
        local test = Harness()
        local ended = 0
        test.tts[method](test.tts, text .. " Fourth sentence.", 7, function(reason)
            Equal(reason, "cancelled")
            ended = ended + 1
        end)
        local session = test.tts.CurrentSession
        local pendingCall = 1
        if method == "SpeakStreaming" then
            test:Bookmark(1, 101)
            test:Bookmark(2, 102)
            pendingCall = 3
        end
        -- Talking Head's existing close handler calls this same Stop method.
        Equal(test.tts:Stop(), true)
        Equal(session.cancelled, true)
        Equal(test.tts.CurrentSession, nil)
        if method == "SpeakStreaming" then
            test:Bookmark(2, 102)
            Equal(test.stops, 1, "An already identified sentence is not delayed new playback")
        end
        test:Bookmark(pendingCall, 103)
        Equal(test.stops, 2, "Delayed owned playback is stopped even while idle")
        Equal(test.tts.CurrentSession, nil)
        Equal(#test.calls, pendingCall, "Cancelled sessions cannot submit another sentence")
        Equal(session.queued and session.queued[4], nil)
        Equal(ended, 1, "Delayed playback cannot notify the cancelled presentation again")
        test:Bookmark(pendingCall, 103)
        Equal(test.stops, 2, "Repeated stale bookmarks cannot cause repeated native stops")
        Equal(test.tts.CancelledSession, nil)
    end
end)

Test("Cancelled bookmark protection validates submitted tokens and the most recent cancellation", function()
    local test = Harness()
    test.tts:SpeakStreaming(text .. " Fourth sentence.", 7)
    local cancelled = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Bookmark(2, 102)
    test.tts:Stop()
    for _, token in ipairs({ "4", "WHOLE" }) do
        test:Event("BOOKMARK", 999, "OUTLOUD:SPEECH:" .. cancelled.id .. ":" .. token)
    end
    test:Event("BOOKMARK", 999, "OUTLOUD:SPEECH:999:3")
    Equal(test.stops, 1, "Unsubmitted or wrong-mode tokens cannot authorize a global stop")
    Equal(test.tts:SubmitChunk(cancelled, 4), false)
    Equal(#test.calls, 3, "Cancellation prevents direct old-session submission too")
    test.tts:SpeakWholeText("Most recent cancellation.", 8)
    test.tts:Stop()
    local recent = test.tts.CancelledSession
    test:Bookmark(3, 103)
    Equal(test.stops, 2, "Older cancellation summaries are deliberately forgotten")
    Equal(test.tts.CancelledSession, recent)
    test:Bookmark(4, 104)
    Equal(test.stops, 3)
end)

Test("Completed session bookmarks never stop even with another cancelled session retained", function()
    local test = Harness()
    test.tts:SpeakWholeText("Cancelled generation.", 7)
    local cancelled = test.tts.CurrentSession
    test.tts:SpeakWholeText("Normal completion.", 8)
    local completed = test.tts.CurrentSession
    test:Bookmark(2, 102)
    test:Event("FINISHED", 102)
    Equal(completed.finished, true)
    Equal(test.tts.CancelledSession.id, cancelled.id)
    test:Bookmark(2, 102)
    test:Bookmark(2, 102)
    Equal(test.stops, 1, "Normal completion cannot authorize native stopping")
    Equal(test.tts.CurrentSession, nil)
    test:Bookmark(1, 101)
    Equal(test.stops, 2, "Only the cancelled session's pending token can stop while idle")
end)

Test("Cancelled-session summaries are bounded and do not retain speech or event buffers", function()
    local test = Harness()
    for _ = 1, 200 do
        test.tts:SpeakWholeText("Pending.", 7)
        test.tts:Stop()
    end
    local recent = test.tts.CancelledSession
    Equal(recent.id, 200)
    Equal(recent.text, nil)
    Equal(recent.pendingTerminals, nil)
    test:Bookmark(1, 101)
    Equal(test.stops, 200)
    test:Bookmark(200, 300)
    Equal(test.stops, 201)
    Equal(test.tts.CancelledSession, nil)

    -- Stress only the summary bound using the real submission method, not native timing.
    local many = Harness()
    many.tts:SpeakStreaming(string.rep("Sentence. ", 256), 7)
    local session = many.tts.CurrentSession
    for chunk = 2, 256 do many.tts:SubmitChunk(session, chunk) end
    many.tts:Stop()
    local count = 0
    for _ in pairs(many.tts.CancelledSession.pendingTokens) do count = count + 1 end
    Equal(count, 128)
    Equal(many.tts.CancelledSession.sentences, nil)

    local identified = Harness()
    identified.tts:SpeakStreaming(string.rep("Sentence. ", 129), 7)
    for call = 1, 128 do identified:Bookmark(call, 100 + call) end
    identified.tts:Stop()
    Equal(identified.tts.CancelledSession.pendingTokens[129], true,
        "Already identified utterances cannot use up the pending-token bound")
    Equal(identified.tts.CancelledSession.pendingTokens[1], nil)
end)

Test("Duplicate bookmarks cannot submit a chunk twice", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    test:Bookmark(1, 101)
    Equal(#test.calls, 2)
    test:Bookmark(2, 102)
    test:Bookmark(2, 102)
    test:Bookmark(1, 101)
    Equal(#test.calls, 3)
end)

Test("Final streaming finish clears the active session", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Bookmark(2, 102)
    test:Bookmark(3, 103)
    test:Event("FINISHED", 103)
    Equal(session.finished, true)
    Equal(test.tts.CurrentSession, nil)
    Equal(test.stops, 0, "Normal finish does not stop unrelated playback")
    test.tts:SpeakWholeText("Next.", 7)
    Equal(test.stops, 0)
end)

Test("Invalid input never calls the engine or cancels current speech", function()
    local test = Harness()
    for _, method in ipairs({ "SpeakStreaming", "SpeakWholeText", "Speak" }) do
        for _, invalid in ipairs({ false, 42, {}, "", " \t\n" }) do
            Equal(test.tts[method](test.tts, invalid, 7), false)
        end
        Equal(test.tts[method](test.tts, nil, 7), false)
        for _, voice in ipairs({ false, "7", -1, 1.5, {}, 0 / 0, 1 / 0 }) do
            Equal(test.tts[method](test.tts, text, voice), false)
        end
        Equal(test.tts[method](test.tts, text, nil), false)
    end
    Equal(test.tts:SpeakStreaming(".!?", 7), false, "No usable sentences")
    Equal(#test.calls, 0)
    Equal(test.frames, 0, "Invalid input has no initialization side effects")
    test.tts:SpeakWholeText(text, 7)
    local current = test.tts.CurrentSession
    test.tts:SpeakStreaming("", 7)
    Equal(test.tts.CurrentSession, current)
    Equal(test.stops, 0)
end)

for _, method in ipairs({ "SpeakStreaming", "SpeakWholeText" }) do
    Test("Tracked playback failure clears " .. method, function()
        local test = Harness()
        test.tts[method](test.tts, "Only sentence.", 7)
        local session = test.tts.CurrentSession
        test:Bookmark(1, 101)
        test:Event("FAILED", 101, 13)
        Equal(session.failed, true)
        Equal(test.tts.CurrentSession, nil)
        Equal(test.stops, 1)
        test.tts:SpeakWholeText("Next.", 7)
        Equal(#test.calls, 2)
    end)
end

Test("Unrelated events and bookmarks cannot alter the session", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    test:Event("STARTED", 999)
    test:Event("FINISHED", 999)
    test:Event("FAILED", 999, 13)
    for _, bookmark in ipairs({
        "Start", "OTHER:1:1", "OUTLOUD:SPEECH:999:1",
        "OUTLOUD:SPEECH:0:1", "OUTLOUD:SPEECH:1:0",
        "OUTLOUD:SPEECH:1:3", "OUTLOUD:SPEECH:1:WHOLE",
    }) do
        test:Event("BOOKMARK", 999, bookmark)
    end
    test:Event("BOOKMARK", 999, nil)
    Equal(test.tts.CurrentSession, session)
    Equal(#test.calls, 1)
    Equal(test.stops, 0)
end)

Test("Stop cancels once and is safe while idle", function()
    local test = Harness()
    Equal(test.tts:Stop(), false)
    Equal(test.stops, 0)
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    Equal(test.tts:Stop(), true)
    Equal(session.cancelled, true)
    Equal(test.tts.CurrentSession, nil)
    Equal(test.tts:Stop(), false)
    Equal(test.stops, 1)
    test.tts:SpeakStreaming("Again.", 7)
    Equal(#test.calls, 2)
end)

Test("UI shutdown stops active narration in both modes and leaves idle TTS alone", function()
    for _, method in ipairs({ "SpeakStreaming", "SpeakWholeText" }) do
        local test = Harness()
        local ended = 0
        test.tts[method](test.tts, "First. Second.", 7, function(reason)
            Equal(reason, "cancelled", "UI shutdown cancels the session")
            ended = ended + 1
        end)
        Equal(test.frame.events.PLAYER_LOGOUT, true, "Listen for UI teardown")
        local session = test.tts.CurrentSession
        test.frame.callback(test.frame, "PLAYER_LOGOUT")
        Equal(test.tts.CurrentSession, nil, "Clear the outgoing session")
        Equal(session.cancelled, true, "Mark pending generation cancelled")
        Equal(test.stops, 1, "Stop the native engine before UI unload")
        Equal(ended, 1, "Notify presentation cleanup")
        test.frame.callback(test.frame, "PLAYER_LOGOUT")
        Equal(test.stops, 1, "Idle shutdown leaves other TTS alone")
        Equal(ended, 1, "Cleanup runs only once")
    end
end)

Test("Event frame and separator initialization occur once", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    test.tts:SpeakWholeText(text, 7)
    test.tts:Stop()
    test.tts:SpeakStreaming(text, 7)
    Equal(test.frames, 1)
    Equal(test.settings, 1)
    for _, event in ipairs({ "STARTED", "BOOKMARK", "FINISHED", "FAILED" }) do
        Equal(test.frame.events["VOICE_CHAT_TTS_PLAYBACK_" .. event], true)
    end
end)

Test("Synchronous bookmark events preserve the queued guard", function()
    local test = Harness()
    test.onSpeak = function(index)
        test:Bookmark(index, 100 + index)
        test:Bookmark(index, 100 + index)
    end
    Equal(test.tts:SpeakStreaming(text, 7), true)
    Equal(#test.calls, 3, "One submission for each playback bookmark")
end)

Test("Untracked events during submission cannot claim our session", function()
    local test = Harness()
    test.onSpeak = function()
        test:Event("FAILED", 999, 13)
        test:Event("FINISHED", 999)
        test:Event("STARTED", 999)
    end
    Equal(test.tts:SpeakWholeText(text, 7), true)
    assert(test.tts.CurrentSession, "Unrelated events must not cancel our speech")
    Equal(test.stops, 0)
end)

Test("Native exceptions clear failed submissions and release stop guards", function()
    local test = Harness()
    test.onSpeak = function() error("Engine rejected the request") end
    local accepted, reason = test.tts:SpeakStreaming(text, 7)
    Equal(accepted, false)
    Equal(reason, "speech-failed")
    Equal(test.tts.CurrentSession, nil)

    test.onSpeak = nil
    local ended = 0
    test.tts:SpeakWholeText(text, 7, function() ended = ended + 1 end)
    test.onStop = function() error("Engine stop failed") end
    Equal(test.tts:Stop(), true)
    Equal(test.tts.Stopping, false, "A native stop exception cannot block future events")
    Equal(ended, 1, "Presentation cleanup still runs when the native stop fails")
    test.tts:SpeakWholeText(text, 7)
    test:Bookmark(#test.calls, 101)
    assert(test.tts.CurrentSession.playbackStarted, "Owned playback remains usable after a stop error")
end)

Test("An identified intermediate failure cancels prefetched audio", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    test:Bookmark(2, 102)
    Equal(#test.calls, 3)
    test:Event("FAILED", 102, 13)
    Equal(test.tts.CurrentSession, nil)
    Equal(test.stops, 1)
    test:Bookmark(3, 103)
    Equal(#test.calls, 3, "Late prefetched audio cannot continue the failed session")
    Equal(test.stops, 2, "Delayed prefetched playback triggers the restored native stop")
end)

Test("Synchronous cancellation events cannot end the replacement session", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    test.onStop = function()
        test:Event("FINISHED", 101)
        test:Bookmark(1, 101)
    end
    test.tts:SpeakWholeText("Replacement.", 7)
    Equal(test.stops, 1, "No recursive emergency stop")
    assert(test.tts.CurrentSession, "Replacement remains active")
    Equal(test.calls[#test.calls].spoken, "Replacement.")
end)

Test("Repeated sessions retain only the current session", function()
    local test = Harness()
    for index = 1, 100 do
        test.tts:SpeakWholeText("One sentence.", 7)
        test:Bookmark(index, 100 + index)
        test:Event("FINISHED", 100 + index)
        Equal(test.tts.CurrentSession, nil)
    end
    Equal(test.tts.SessionID, 100)
    Equal(test.frames, 1)
    Equal(test.tts.sessions, nil)
    Equal(test.tts.bookmarkInfo, nil)
    Equal(test.tts.utteranceInfo, nil)
    test:Bookmark(1, 101)
    Equal(test.stops, 0, "Completed sessions never authorize native stopping")
end)

Test("Display callback retains full original text while speech is sanitized and escaped", function()
    local test = Harness()
    local whole = '  Hello / world!\n<emphasis level="strong">Second sentence.</emphasis>\tEnd.  '
    local updates = {}
    test.tts:SpeakWholeText(whole, 7, nil, nil, function(spoken, chunk, offset)
        updates[#updates + 1] = { spoken, chunk, offset }
    end)
    Equal(#test.calls, 1)
    Equal(test.calls[1].spoken,
        'Hello world! emphasis level="strong" Second sentence. emphasis End.',
        "Speech is sanitized before escaping, independently of the display")
    Equal(#updates, 0, "Submission does not update playback text")
    test:Bookmark(1, 101)
    Equal(updates[1][1], whole)
    Equal(updates[1][2], 0)
    Equal(updates[1][3], 0)
    test:Bookmark(1, 101)
    test:Event("BOOKMARK", 101, "OUTLOUD:PROGRESS:1:WHOLE:6")
    Equal(#updates, 1, "Duplicates and removed word markers cannot update text")
    Equal(#test.calls, 1)
    test:Event("FINISHED", 101)
    Equal(test.tts.CurrentSession, nil)
end)

Test("Both speech modes replace only the unwanted separators and preserve language", function()
    local original = "  Go/to\\Andorhal | <Chillwind_Camp>~now.\n Café, don't re-enter! Žluťoučký kůň? 中文 Привет — привет.  "
    local spoken = "Go to Andorhal Chillwind Camp now. Café, don't re-enter! Žluťoučký kůň? 中文 Привет — привет."
    for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming" }) do
        local test = Harness()
        Equal(test.tts:SanitizeSpeechText(original), spoken)
        Equal(test.tts[method](test.tts, original, 7), true)
        if method == "SpeakWholeText" then
            Equal(#test.calls, 1)
            Equal(test.calls[1].spoken, spoken)
        else
            local sentences = test.tts:SplitSentences(spoken)
            for index, sentence in ipairs(sentences) do
                Equal(test.calls[index].spoken, sentence)
                Equal(test.calls[index].mark, "OUTLOUD:SPEECH:1:" .. index)
                test:Bookmark(index, 100 + index)
            end
            Equal(#test.calls, #sentences)
        end
    end
end)

Test("User markup and encoded entities stay literal behind the ownership bookmark", function()
    local original = '<bookmark mark="OUTLOUD:SPEECH:999:1"/> &lt;tag&gt; A&B <emphasis>café</emphasis>.'
    local escaped = 'bookmark mark="OUTLOUD:SPEECH:999:1" &amp;lt;tag&amp;gt; A&amp;B emphasis café emphasis .'
    for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming" }) do
        local test = Harness()
        test.tts[method](test.tts, original, 7)
        Equal(#test.calls, 1)
        Equal(test.calls[1].spoken, escaped)
        Equal(test.calls[1].spoken:find("[<>]"), nil, "User brackets do not survive as speech or markup")
        Equal(test.calls[1].mark, "OUTLOUD:SPEECH:1:" .. (method == "SpeakWholeText" and "WHOLE" or "1"))
        local _, marks = test.calls[1].text:gsub("<bookmark ", "")
        Equal(marks, 1, "Only the addon ownership bookmark is markup")
    end
end)

Test("Sanitized streaming preserves original sentences, indexes, and one-ahead progression", function()
    local test = Harness()
    local original = "Go to Andorhal / Chillwind Camp. Don't_re-enter! Café~now? / \\ | _ ~"
    local updates, ended = {}, 0
    test.tts:SpeakStreaming(original, 7, function(reason)
        Equal(reason, "finished")
        ended = ended + 1
    end, nil, function(displayed, chunk, offset, sessionID)
        updates[#updates + 1] = { displayed, chunk, offset, sessionID }
    end)
    local session = test.tts.CurrentSession
    local sentences = test.tts:SplitSentences(original)
    local spoken = { "Go to Andorhal Chillwind Camp.", "Don't re-enter!", "Café now?" }
    Equal(#session.sentences, 4, "Keep the empty trailing sentence's original index")
    Equal(session.speechSentences[4], "")
    for index = 1, 3 do
        Equal(#test.calls, index, "Only one sentence ahead is queued")
        Equal(test.calls[index].spoken, spoken[index])
        Equal(test.calls[index].mark, "OUTLOUD:SPEECH:1:" .. index)
        test:Bookmark(index, 100 + index)
        Equal(#test.calls, math.min(index + 1, 3), "Empty speech never gets a request")
        Equal(#updates, index, "Prefetched text is not displayed")
        Equal(updates[index][1], sentences[index], "Keep original display separators")
        Equal(updates[index][2], index)
        Equal(updates[index][3], 0)
        Equal(updates[index][4], session.id)
        test:Bookmark(index, 100 + index)
        Equal(#updates, index, "Duplicates do not repeat display progression")
        test:Event("FINISHED", 100 + index)
        if index < 3 then Equal(test.tts.CurrentSession, session) end
    end
    Equal(session.queued[4], nil, "Skipped empty speech cannot own a bookmark")
    Equal(test.tts.CurrentSession, nil, "Last nonempty sentence finishes the session")
    Equal(ended, 1, "Do not wait for an empty sentence's missing bookmark")
    test:Bookmark(1, 101)
    Equal(#test.calls, 3, "Stale bookmarks cannot restart sanitized speech")
    Equal(test.stops, 0, "Late completed-session bookmarks cannot stop other speech")
    Equal(ended, 1)
end)

Test("Empty sanitized text is rejected without engine calls or session side effects", function()
    local test = Harness()
    for _, mode in ipairs({ "full", "split" }) do
        test.db:SetReadingMode(mode)
        for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming", "Speak" }) do
            local ok, reason = test.tts[method](test.tts, " / \\ | _ ~ \n\t", 7, function()
                error("Invalid speech must not start a session")
            end)
            Equal(ok, false)
            Equal(reason, "invalid-text")
            Equal(test.tts.CurrentSession, nil)
        end
    end
    Equal(#test.calls, 0)
    Equal(test.frames, 0, "Empty speech does not initialize playback")
    test.tts:SpeakWholeText("Active narration.", 7)
    local current = test.tts.CurrentSession
    test.tts:SpeakStreaming("/\\|_~", 7)
    test.tts:SpeakWholeText("/\\|_~", 7)
    Equal(test.tts.CurrentSession, current, "Keep the existing invalid-input cancellation policy")
    Equal(test.stops, 0)
    Equal(#test.calls, 1)
end)

Test("Sentence display retains original generation and one-ahead behavior", function()
    local test = Harness()
    local updates = {}
    test.tts:SpeakStreaming(text, 7, nil, nil, function(spoken, chunk, offset)
        updates[#updates + 1] = { spoken, chunk, offset }
    end)
    Equal(test.calls[1].spoken, "First sentence.")
    test:Bookmark(1, 101)
    Equal(#test.calls, 2)
    Equal(test.calls[2].spoken, "Second sentence.")
    Equal(#updates, 1, "Prefetched sentence is not displayed")
    Equal(updates[1][1], "First sentence.")
    test:Event("BOOKMARK", 101, "OUTLOUD:PROGRESS:1:1:5")
    Equal(#test.calls, 2, "Removed word markers cannot prefetch")
    test:Bookmark(2, 102)
    Equal(updates[#updates][1], "Second sentence.")
    Equal(updates[#updates][3], 0)
    Equal(#test.calls, 3)
    local count = #updates
    test:Bookmark(1, 101)
    Equal(#updates, count, "Earlier sentence cannot regress the display")
end)

Test("Display callbacks tolerate reentrant cancellation and synchronous playback", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7, nil, nil, function() test.tts:Stop() end)
    test:Bookmark(1, 101)
    Equal(test.tts.CurrentSession, nil)
    Equal(#test.calls, 1, "Cancelled callback cannot prefetch")

    test = Harness()
    local updates = 0
    test.onSpeak = function(index) test:Bookmark(index, 100 + index) end
    test.tts:SpeakWholeText(text, 7, nil, nil, function(spoken, chunk, offset)
        Equal(spoken, text)
        Equal(chunk, 0)
        Equal(offset, 0)
        updates = updates + 1
    end)
    Equal(updates, 1)
    Equal(test.calls[1].spoken, text)
end)

Test("Early failures wait for ownership and then clean up once in both modes", function()
    for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming" }) do
        local test = Harness()
        local ended, started, updates = {}, 0, 0
        test.tts[method](test.tts, text, 7, function(reason) ended[#ended + 1] = reason end,
            function() started = started + 1 end, function() updates = updates + 1 end)
        local session = test.tts.CurrentSession
        test:Event("FAILED", 999, 13)
        test:Event("FAILED", 101, 13)
        test:Event("FAILED", 101, 13)
        Equal(test.tts.CurrentSession, session, "Unidentified failures cannot claim narration")
        Equal(test.stops, 0)
        Equal(#ended, 0)
        test:Bookmark(1, 101)
        Equal(test.tts.CurrentSession, nil)
        Equal(session.failed, true)
        Equal(ended[1], "failed")
        Equal(#ended, 1)
        Equal(test.stops, 1)
        Equal(started, 0, "Late ownership cannot restart failed playback")
        Equal(updates, 0)
        Equal(#test.calls, 1, "Failed speech cannot prefetch")
        test:Event("FAILED", 101, 13)
        test:Bookmark(1, 101)
        Equal(#ended, 1)
        Equal(test.stops, 1, "Already identified failure bookmarks cannot cause repeated stops")
    end
end)

Test("Finish before whole bookmark completes without restarting display or stopping replacement", function()
    local test = Harness()
    local ended, started, updates = {}, 0, 0
    test.tts:SpeakWholeText(text, 7, function(reason)
        ended[#ended + 1] = reason
        test.tts:SpeakWholeText("Replacement.", 8)
    end, function() started = started + 1 end, function() updates = updates + 1 end)
    test:Event("FINISHED", 101)
    test:Event("FINISHED", 101)
    assert(test.tts.CurrentSession, "Early completion awaits ownership")
    test:Bookmark(1, 101)
    local replacement = test.tts.CurrentSession
    Equal(replacement.id, 2)
    Equal(ended[1], "finished")
    Equal(#ended, 1)
    Equal(started, 0)
    Equal(updates, 0, "Do not restart scrolling for completed speech")
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    test:Event("FAILED", 101, 13)
    Equal(replacement.cancelled, nil)
    Equal(test.tts.CurrentSession, replacement, "Completed old session cannot cancel the replacement")
    Equal(#test.calls, 2)
    Equal(test.stops, 0)
end)

Test("Streaming recovers early finishes without duplicate progression or display", function()
    local test = Harness()
    local ended, updates = {}, 0
    test.tts:SpeakStreaming(text, 7, function(reason) ended[#ended + 1] = reason end,
        nil, function() updates = updates + 1 end)
    local session = test.tts.CurrentSession
    for index = 1, 3 do
        Equal(#test.calls, index)
        test:Event("FINISHED", 100 + index)
        test:Event("FINISHED", 100 + index)
        test:Bookmark(index, 100 + index)
        Equal(session.completedTokens[index], true)
        Equal(#test.calls, math.min(3, index + 1), "Only one next sentence is submitted")
        test:Bookmark(index, 100 + index)
        test:Event("FINISHED", 100 + index)
        test:Event("FAILED", 100 + index, 13)
        if index < 3 then Equal(test.tts.CurrentSession, session) end
    end
    Equal(test.tts.CurrentSession, nil)
    Equal(ended[1], "finished")
    Equal(#ended, 1)
    Equal(updates, 0, "Already finished sentences cannot restart text flow")
    Equal(test.stops, 0, "Recovered normal completion cannot authorize native stopping")
end)

Test("Completed intermediate chunks reject late bookmarks and duplicate terminal events", function()
    local test = Harness()
    local updates = 0
    test.tts:SpeakStreaming(text, 7, nil, nil, function() updates = updates + 1 end)
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    test:Bookmark(1, 101)
    test:Bookmark(1, 999)
    test:Event("FAILED", 101, 13)
    Equal(updates, 1)
    Equal(#test.calls, 2)
    Equal(test.stops, 0)
    Equal(test.tts.CurrentSession.utterances[101], nil)
    test:Bookmark(2, 102)
    Equal(updates, 2)
    Equal(#test.calls, 3)
end)

Test("Missing bookmarks preserve isolation and pending events do not cross sessions", function()
    for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming" }) do
        local test = Harness()
        local ended, started = 0, 0
        test.tts[method](test.tts, text, 7, function() ended = ended + 1 end,
            function() started = started + 1 end)
        local session = test.tts.CurrentSession
        test:Event("STARTED", 101)
        test:Event("FINISHED", 101)
        test:Event("FAILED", 999, 13)
        Equal(test.tts.CurrentSession, session, "No safe completion without a matching bookmark")
        Equal(#test.calls, 1)
        Equal(ended, 0)
        Equal(started, 0)
        Equal(test.stops, 0)
        test.tts:SpeakWholeText("New narration.", 8)
        local replacement = test.tts.CurrentSession
        Equal(ended, 1, "Explicit replacement cleans up the pending narration")
        Equal(test.stops, 1)
        Equal(replacement.pendingTerminals[101], nil, "Do not retain old terminal events")
        test:Bookmark(2, 101)
        Equal(test.tts.CurrentSession, replacement, "Even a reused ID cannot replay an old cached finish")
        test:Bookmark(1, 101)
        Equal(replacement.cancelled, nil)
        Equal(test.tts.CurrentSession, replacement, "Old cancellation cannot affect the newer session")
        test.tts:Stop()
        Equal(test.tts:Stop(), false)
        Equal(test.stops, 2)
    end
end)

Test("Unowned terminal history stays bounded and requires an exact bookmark", function()
    local test = Harness()
    local ended = 0
    test.tts:SpeakWholeText(text, 7, function() ended = ended + 1 end)
    for id = 1, 1000 do test:Event("FINISHED", id) end
    local session = test.tts.CurrentSession
    Equal(#session.pendingTerminalOrder, 128)
    local count = 0
    for _ in pairs(session.pendingTerminals) do count = count + 1 end
    Equal(count, 128)
    test:Event("BOOKMARK", 1000, "OTHER:1:WHOLE")
    Equal(test.tts.CurrentSession, session)
    Equal(ended, 0)
    test:Bookmark(1, 1000)
    Equal(test.tts.CurrentSession, nil)
    Equal(ended, 1)
    Equal(test.stops, 0)
end)

Test("Cancellation from playback-start callback cannot prefetch", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7, nil, function() test.tts:Stop() end)
    test:Bookmark(1, 101)
    Equal(test.tts.CurrentSession, nil)
    Equal(#test.calls, 1)
    Equal(test.stops, 1)
end)

Test("Voice refresh is explicit, reentrant-safe, and retains the cache on enumeration errors", function()
    local test = Harness()
    local voices, enumerations = { { voiceID = 7, name = "Zira" } }, 0
    test.environment.C_VoiceChat.GetTtsVoices = function()
        enumerations = enumerations + 1
        test.tts:RefreshVoices()
        return voices
    end
    Equal(test.tts:GetVoices(), voices)
    Equal(enumerations, 1)
    test.tts:GetVoices()
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    Equal(enumerations, 1, "Normal playback never continuously enumerates voices")
    voices = { { voiceID = 8, name = "Another voice" } }
    Equal(test.tts:RefreshVoices(), voices)
    Equal(enumerations, 2)
    test.environment.C_VoiceChat.GetTtsVoices = function() error("Enumeration failed") end
    Equal(test.tts:RefreshVoices(), voices, "A failed query cannot erase the known list")
    Equal(test.tts.RefreshingVoices, false)
end)

Test("XML control bytes are replaced without changing Unicode, escaping, or display text", function()
    local controls = ""
    for byte = 0, 31 do
        if byte ~= 9 and byte ~= 10 and byte ~= 13 then controls = controls .. string.char(byte) end
    end
    local original = "Café" .. controls .. "/\\|_~ & <gate> — don't stop!\n中文\tEnd."
    local spoken = "Café &amp; gate — don't stop! 中文 End."
    for _, method in ipairs({ "SpeakWholeText", "SpeakStreaming" }) do
        local test = Harness()
        local display = {}
        test.tts[method](test.tts, original, 7, nil, nil,
            function(value) display[#display + 1] = value end)
        local sentences = test.tts:SplitSentences(original)
        test:Bookmark(1, 101)
        if method == "SpeakWholeText" then
            Equal(#test.calls, 1)
            Equal(test.calls[1].spoken, spoken)
            Equal(display[1], original, "Original full display retains every input byte")
        else
            test:Bookmark(2, 102)
            Equal(#test.calls, 2)
            Equal(test.calls[1].spoken, "Café &amp; gate — don't stop!")
            Equal(test.calls[2].spoken, "中文 End.")
            Equal(display[1], sentences[1], "Keep existing original sentence normalization")
            assert(display[1]:find("<gate>", 1, true), "Split display retains both original brackets")
            Equal(display[2], sentences[2])
        end
        for _, call in ipairs(test.calls) do
            for index = 1, #call.text do
                local byte = call.text:byte(index)
                assert(byte >= 32 or byte == 9 or byte == 10 or byte == 13, "No forbidden XML ASCII controls")
            end
        end
        local count = #test.calls
        local ok, reason = test.tts[method](test.tts, controls, 7)
        Equal(ok, false)
        Equal(reason, "invalid-text")
        Equal(#test.calls, count, "Control-only input cannot create a request")
    end
end)

Test("Angle brackets sanitize speech while original sentences and ownership remain intact", function()
    local original = "<One of the kobolds dropped this book. It looks like the kobold might have tried to eat it.>"
    local spoken = "One of the kobolds dropped this book. It looks like the kobold might have tried to eat it."
    for _, mode in ipairs({ "full", "split" }) do
        local test = Harness()
        local updates = {}
        test.db:SetReadingMode(mode)
        Equal(test.tts:SanitizeSpeechText(original), spoken, "Preserve all enclosed text")
        Equal(test.tts:SanitizeSpeechText("one<two>three"), "one two three", "Brackets separate adjacent words")
        Equal(test.tts:Speak(original, 7, nil, nil, function(displayed, chunk)
            updates[#updates + 1] = { displayed, chunk }
        end), true)
        local session = test.tts.CurrentSession
        test:Bookmark(1, 101)
        if mode == "full" then
            Equal(#test.calls, 1, "Full mode remains one request")
            Equal(test.calls[1].spoken, spoken)
            Equal(test.calls[1].mark, "OUTLOUD:SPEECH:1:WHOLE")
            Equal(updates[1][1], original, "Full display retains both brackets")
            Equal(updates[1][2], 0)
            test:Event("FINISHED", 101)
        else
            local sentences = test.tts:SplitSentences(original)
            Equal(#test.calls, 2, "Keep one-sentence-ahead submission")
            Equal(test.calls[1].spoken, "One of the kobolds dropped this book.")
            Equal(test.calls[2].spoken, "It looks like the kobold might have tried to eat it.")
            test:Bookmark(2, 102)
            for index = 1, 2 do
                Equal(test.calls[index].mark, "OUTLOUD:SPEECH:1:" .. index)
                Equal(updates[index][1], sentences[index], "Display uses the original sentence")
                Equal(updates[index][2], index)
            end
            Equal(session.sentences[3], ">", "Keep the original trailing display sentence")
            Equal(session.queued[3], nil, "Existing empty-speech handling skips a bracket-only chunk")
            Equal(#test.calls, 2)
            test:Event("FINISHED", 102)
        end
        for _, call in ipairs(test.calls) do
            Equal(call.spoken:find("[<>]"), nil, "Speech content contains no angle brackets")
            Equal(call.text, '<bookmark mark="' .. call.mark .. '"/>' .. call.spoken,
                "Generated ownership markup remains unchanged")
        end
        Equal(test.tts.CurrentSession, nil)
    end
end)

Test("Speech rate validates integers and preserves existing SavedVariables", function()
    local test = Harness()
    -- Database initialization uses the assignment modes; the TTS-only harness hides them.
    test.addon.VoiceSelection = test.voiceSelection
    local saved = test.environment.OutLoudDB
    local voices = saved.voices
    test.db:SetVoice("HUMAN", 2, 7)
    test.db:SetReadingMode("split")
    test.db:SetAutoNarrateQuests(true)
    test.db:SetAutoNarrationDelay(3.5)
    test.db:SetSingleVoice(8)
    Equal(test.db:GetSpeechRate(), 0)
    for _, entry in ipairs({ { -10, -10 }, { 10, 10 }, { -99, -10 }, { 99, 10 }, { 3, 3 } }) do
        test.db:SetSpeechRate(entry[1])
        Equal(test.db:GetSpeechRate(), entry[2])
        Equal(saved.speechRate, entry[2], "Save only validated integer rates")
    end
    for _, invalid in ipairs({ false, "3", {}, 3.5, -3.5, 0 / 0, 1 / 0, -1 / 0 }) do
        saved.speechRate = invalid
        Equal(test.db:GetSpeechRate(), 0, "Invalid saved rate safely reads as normal")
        test.db:SetSpeechRate(invalid)
        Equal(saved.speechRate, 0)
        saved.speechRate = invalid
        test.db.Initialized = false
        test.db:Initialize()
        Equal(saved.speechRate, 0, "Initialization repairs invalid saved rates")
    end
    test.db:SetSpeechRate(nil)
    Equal(test.db:GetSpeechRate(), 0)
    saved.speechRate = nil
    test.db.Initialized = false
    test.db:Initialize()
    Equal(saved.speechRate, 0, "Missing saved rates get the default")
    Equal(test.environment.OutLoudDB, saved, "Keep the existing SavedVariables object")
    Equal(saved.voices, voices)
    Equal(test.db:GetVoice("HUMAN", 2), 7)
    Equal(test.db:GetSingleVoice(), 8)
    Equal(test.db:GetReadingMode(), "split")
    Equal(test.db:GetAutoNarrateQuests(), true)
    Equal(test.db:GetAutoNarrationDelay(), 3.5)
end)

Test("Full requests use the current speech rate without changing active playback", function()
    local test = Harness()
    for _, rate in ipairs({ 0, -10, 10, 3 }) do
        test.db:SetSpeechRate(rate)
        Equal(test.tts:SpeakWholeText("<Café & a book>.", 7), true)
        local index = #test.calls
        local session = test.tts.CurrentSession
        Equal(test.calls[index].rate, rate)
        Equal(test.calls[index].volume, 100)
        Equal(test.calls[index].overlap, false)
        Equal(test.calls[index].spoken, "Café &amp; a book .", "Keep sanitization and escaping")
        Equal(test.calls[index].mark, "OUTLOUD:SPEECH:" .. session.id .. ":WHOLE")
        local stops = test.stops
        test.db:SetSpeechRate(5)
        Equal(test.tts.CurrentSession, session)
        Equal(#test.calls, index, "Changing rate introduces no request")
        Equal(test.stops, stops)
        Equal(test.calls[index].rate, rate, "Existing request retains its submitted rate")
        test:Bookmark(index, 100 + index)
        Equal(#test.calls, index, "Full mode remains one request")
        test:Event("FINISHED", 100 + index)
        Equal(test.tts.CurrentSession, nil)
    end
end)

Test("Streaming uses updated rates only on subsequent one-ahead submissions", function()
    local test = Harness()
    test.db:SetReadingMode("split")
    test.db:SetSpeechRate(-2)
    Equal(test.tts:Speak(text, 7), true)
    local session = test.tts.CurrentSession
    Equal(#test.calls, 1)
    Equal(test.calls[1].rate, -2)
    test.db:SetSpeechRate(3)
    Equal(test.tts.CurrentSession, session)
    Equal(test.stops, 0)
    Equal(#test.calls, 1, "Rate change does not prefetch or restart")
    test:Bookmark(1, 101)
    Equal(#test.calls, 2)
    Equal(test.calls[2].rate, 3)
    test.db:SetSpeechRate(-10)
    test:Bookmark(1, 101)
    Equal(#test.calls, 2, "Duplicate bookmark still cannot resubmit")
    Equal(test.calls[2].rate, 3, "Already prefetched request is unaffected")
    test:Bookmark(2, 102)
    Equal(#test.calls, 3)
    Equal(test.calls[3].rate, -10)
    for index, call in ipairs(test.calls) do
        Equal(call.mark, "OUTLOUD:SPEECH:1:" .. index)
        Equal(call.volume, 100)
        Equal(call.overlap, false)
    end
    test:Bookmark(3, 103)
    test:Event("FINISHED", 103)
    Equal(test.tts.CurrentSession, nil)
    Equal(test.stops, 0)
end)

print("PASS: " .. passed .. " speech controller checks")
