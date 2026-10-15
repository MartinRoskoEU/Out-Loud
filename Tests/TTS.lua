-- Execute only with explicit user approval, from the addon root with Lua 5.1: lua Tests/TTS.lua
-- The harness records addon calls; it models no native queue or stop acknowledgements.
-- Event inputs check Lua reactions, not guaranteed WoW ordering, timing, or survival.
-- Coordinator ownership and opening-start submission are checked separately in Tests/Narration.lua.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness(withoutDiagnostics)
    local test = { calls = {}, order = {}, diagnostics = {}, stops = 0, settings = 0, frames = 0 }
    local environment = setmetatable({}, { __index = _G })
    environment._G = environment
    test.clock = 0
    environment.GetTime = function() return test.clock end
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
        "Core/Namespace.lua", "Core/VoiceSelection.lua", "Core/Database.lua", "Core/TTSDiagnostics.lua", "Core/TTS.lua",
    }) do
        if path ~= "Core/TTSDiagnostics.lua" or not withoutDiagnostics then
            local chunk = assert(LoadFile(path))
            setfenv(chunk, environment)
            chunk("OutLoud", addon)
        end
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

Test("Speak forwards narration callbacks and source to streaming", function()
    local test = Harness()
    local ended, started, progress = function() end, function() end, function() end
    test.tts.SpeakStreaming = function(_, suppliedText, suppliedVoice, onEnded, onStarted, onProgress, source)
        Equal(suppliedText, text)
        Equal(suppliedVoice, 7)
        Equal(onEnded, ended)
        Equal(onStarted, started)
        Equal(onProgress, progress)
        Equal(source, "Quest")
        return false, "speech-failed"
    end
    local ok, reason = test.tts:Speak(text, 7, ended, started, progress, "Quest")
    Equal(ok, false)
    Equal(reason, "speech-failed")
end)

for _, modes in ipairs({
    { "SpeakStreaming", "SpeakStreaming" },
    { "SpeakStreaming", "Speak" },
    { "Speak", "SpeakStreaming" },
    { "Speak", "Speak" },
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

Test("Observed cancelled prefetch requests one Emergency STOP without resubmission", function()
    local test = Harness()
    test.addon.DebugEnabled = true
    test.tts:SpeakStreaming(text, 7)
    local old = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    test:Bookmark(2, 102)
    Equal(#test.calls, 3)
    test.clock = 2101.680
    test.tts:SpeakStreaming("New sentence. Another sentence.", 8)
    local current = test.tts.CurrentSession
    local records, callback = current.sentenceStates, current.onSessionEnded
    local submitted = records[1].attempts[1]
    test.clock = 2102.177
    test:Bookmark(3, 103)
    Equal(test.stops, 2, "Initial replacement stop plus one experimental request")
    Equal(test.tts.CurrentSession, current)
    Equal(current.sentenceStates, records)
    Equal(current.onSessionEnded, callback)
    Equal(current.state, "active")
    Equal(current.emergencyRecoveryAttempted, true)
    Equal(records[1].attempts[1], submitted)
    Equal(submitted.submissionState, "returned")
    Equal(submitted.nativeState, "unknown-after-stop")
    Equal(submitted.stopCount, 1)
    Equal(#test.calls, 4, "No new request is resubmitted; native survival is unconfirmed")
    Equal(old.sentenceStates[3].state, "cancelled")
    -- Repeat the handler input solely to check Out Loud's idempotence.
    test:Bookmark(3, 103)
    Equal(test.stops, 2)
    test.clock = 2104.268
    test:Event("FINISHED", 103)
    Equal(test.tts.CurrentSession, current)
    Equal(old.sentenceStates[3].state, "cancelled")
    Equal(old.sentenceStates[3].attempts[1].nativeState, "finished-reported")
    Equal(#test.calls, 4)
    local report = test.addon.GetTTSReport()
    assert(report:find("emergency-stop-performed", 1, true))
    assert(report:find("duplicate-stale-bookmark", 1, true))
end)

Test("Late bookmarks remain recognizable after Stop and cleanup", function()
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
        local test = Harness()
        local ended = 0
        test.tts[method](test.tts, text .. " Fourth sentence.", 7, function(reason)
            Equal(reason, "cancelled")
            ended = ended + 1
        end)
        local session = test.tts.CurrentSession
        test:Bookmark(1, 101)
        test:Bookmark(2, 102)
        local pendingCall = 3
        -- Talking Head's existing close handler calls this same Stop method.
        Equal(test.tts:Stop(), true)
        Equal(session.cancelled, true)
        Equal(test.tts.CurrentSession, nil)
        test:Bookmark(2, 102)
        Equal(test.stops, 1, "An already identified sentence is not delayed new playback")
        test:Bookmark(pendingCall, 103)
        Equal(test.stops, 2, "Addon requests one idle follow-up stop")
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
    for _, token in ipairs({ "4", "INVALID" }) do
        test:Event("BOOKMARK", 999, "OUTLOUD:SPEECH:" .. cancelled.id .. ":" .. token)
    end
    test:Event("BOOKMARK", 999, "OUTLOUD:SPEECH:999:3")
    Equal(test.stops, 1, "Unsubmitted or nonnumeric tokens cannot authorize a global stop")
    Equal(test.tts:SubmitChunk(cancelled, 4), false)
    Equal(#test.calls, 3, "Cancellation prevents direct old-session submission too")
    test.tts:Speak("Most recent cancellation.", 8)
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
    test.tts:Speak("Cancelled generation.", 7)
    local cancelled = test.tts.CurrentSession
    test.tts:Speak("Normal completion.", 8)
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
        test.tts:Speak("Pending.", 7)
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
    test.tts:Speak("Next.", 7)
    Equal(test.stops, 0)
end)

Test("Invalid input never calls the engine or cancels current speech", function()
    local test = Harness()
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
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
    test.tts:Speak(text, 7)
    local current = test.tts.CurrentSession
    test.tts:SpeakStreaming("", 7)
    Equal(test.tts.CurrentSession, current)
    Equal(test.stops, 0)
end)

for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
    Test("Tracked playback failure clears " .. method, function()
        local test = Harness()
        test.tts[method](test.tts, "Only sentence.", 7)
        local session = test.tts.CurrentSession
        test:Bookmark(1, 101)
        test:Event("FAILED", 101, 13)
        Equal(session.failed, true)
        Equal(test.tts.CurrentSession, nil)
        Equal(test.stops, 1)
        test.tts:Speak("Next.", 7)
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
        "OUTLOUD:SPEECH:1:3", "OUTLOUD:SPEECH:1:INVALID",
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

Test("UI shutdown stops active narration through both speech entry points and leaves idle TTS alone", function()
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
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
        Equal(test.stops, 1, "Request native stop before UI unload")
        Equal(ended, 1, "Notify presentation cleanup")
        test.frame.callback(test.frame, "PLAYER_LOGOUT")
        Equal(test.stops, 1, "Idle shutdown leaves other TTS alone")
        Equal(ended, 1, "Cleanup runs only once")
    end
end)

Test("Event frame and separator initialization occur once", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    test.tts:Speak(text, 7)
    test.tts:Stop()
    test.tts:SpeakStreaming(text, 7)
    Equal(test.frames, 1)
    Equal(test.settings, 1)
    for _, event in ipairs({ "STARTED", "BOOKMARK", "FINISHED", "FAILED" }) do
        Equal(test.frame.events["VOICE_CHAT_TTS_PLAYBACK_" .. event], true)
    end
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
    test.tts:Speak(text, 7, function() ended = ended + 1 end)
    test.onStop = function() error("Engine stop failed") end
    Equal(test.tts:Stop(), true)
    Equal(test.tts.Stopping, false, "A native stop exception cannot block future events")
    Equal(ended, 1, "Presentation cleanup still runs when the native stop fails")
    test.tts:Speak(text, 7)
    test:Bookmark(#test.calls, 101)
    assert(test.tts.CurrentSession.playbackStarted, "Owned playback remains usable after a stop error")
end)

Test("Owned failure logically cancels remaining sentences and requests stop", function()
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

Test("Repeated sessions retain only the current session", function()
    local test = Harness()
    for index = 1, 100 do
        test.tts:Speak("One sentence.", 7)
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

Test("Speech entry points replace only the unwanted separators and preserve language", function()
    local original = "  Go/to\\Andorhal | <Chillwind_Camp>~now.\n Café, don't re-enter! Žluťoučký kůň? 中文 Привет — привет.  "
    local spoken = "Go to Andorhal Chillwind Camp now. Café, don't re-enter! Žluťoučký kůň? 中文 Привет — привет."
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
        local test = Harness()
        Equal(test.tts:SanitizeSpeechText(original), spoken)
        Equal(test.tts[method](test.tts, original, 7), true)
        local sentences = test.tts:SplitSentences(spoken)
        for index, sentence in ipairs(sentences) do
            Equal(test.calls[index].spoken, sentence)
            Equal(test.calls[index].mark, "OUTLOUD:SPEECH:1:" .. index)
            test:Bookmark(index, 100 + index)
        end
        Equal(#test.calls, #sentences)
    end
end)

Test("User markup and encoded entities stay literal behind the ownership bookmark", function()
    local original = '<bookmark mark="OUTLOUD:SPEECH:999:1"/> &lt;tag&gt; A&B <emphasis>café</emphasis>.'
    local escaped = 'bookmark mark="OUTLOUD:SPEECH:999:1" &amp;lt;tag&amp;gt; A&amp;B emphasis café emphasis .'
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
        local test = Harness()
        test.tts[method](test.tts, original, 7)
        Equal(#test.calls, 1)
        Equal(test.calls[1].spoken, escaped)
        Equal(test.calls[1].spoken:find("[<>]"), nil, "User brackets do not survive as speech or markup")
        Equal(test.calls[1].mark, "OUTLOUD:SPEECH:1:1")
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
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
        local ok, reason = test.tts[method](test.tts, " / \\ | _ ~ \n\t", 7, function()
            error("Invalid speech must not start a session")
        end)
        Equal(ok, false)
        Equal(reason, "invalid-text")
        Equal(test.tts.CurrentSession, nil)
    end
    Equal(#test.calls, 0)
    Equal(test.frames, 0, "Empty speech does not initialize playback")
    test.tts:Speak("Active narration.", 7)
    local current = test.tts.CurrentSession
    test.tts:SpeakStreaming("/\\|_~", 7)
    test.tts:Speak("/\\|_~", 7)
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

Test("Display callbacks can cancel before prefetch", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7, nil, nil, function() test.tts:Stop() end)
    test:Bookmark(1, 101)
    Equal(test.tts.CurrentSession, nil)
    Equal(#test.calls, 1, "Cancelled callback cannot prefetch")
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
    Equal(test.tts.CurrentSession.sentenceStates[1].state, "completed")
    test:Bookmark(2, 102)
    Equal(updates, 2)
    Equal(#test.calls, 3)
end)

Test("Missing bookmarks preserve isolation and pending events do not cross sessions", function()
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
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
        test.tts:Speak("New narration.", 8)
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
    test.tts:Speak("Only sentence.", 7, function() ended = ended + 1 end)
    for id = 1, 1000 do test:Event("FINISHED", id) end
    local session = test.tts.CurrentSession
    Equal(#session.pendingTerminalOrder, 128)
    local count = 0
    for _ in pairs(session.pendingTerminals) do count = count + 1 end
    Equal(count, 128)
    test:Event("BOOKMARK", 1000, "OTHER:1:INVALID")
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
    for _, method in ipairs({ "SpeakStreaming", "Speak" }) do
        local test = Harness()
        local display = {}
        test.tts[method](test.tts, original, 7, nil, nil,
            function(value) display[#display + 1] = value end)
        local sentences = test.tts:SplitSentences(original)
        test:Bookmark(1, 101)
        test:Bookmark(2, 102)
        Equal(#test.calls, 2)
        Equal(test.calls[1].spoken, "Café &amp; gate — don't stop!")
        Equal(test.calls[2].spoken, "中文 End.")
        Equal(display[1], sentences[1], "Keep existing original sentence normalization")
        assert(display[1]:find("<gate>", 1, true), "Split display retains both original brackets")
        Equal(display[2], sentences[2])
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
    local test = Harness()
    local updates = {}
    Equal(test.tts:SanitizeSpeechText(original), spoken, "Preserve all enclosed text")
    Equal(test.tts:SanitizeSpeechText("one<two>three"), "one two three", "Brackets separate adjacent words")
    Equal(test.tts:Speak(original, 7, nil, nil, function(displayed, chunk)
        updates[#updates + 1] = { displayed, chunk }
    end), true)
    local session = test.tts.CurrentSession
    test:Bookmark(1, 101)
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
    for _, call in ipairs(test.calls) do
        Equal(call.spoken:find("[<>]"), nil, "Speech content contains no angle brackets")
        Equal(call.text, '<bookmark mark="' .. call.mark .. '"/>' .. call.spoken,
            "Generated ownership markup remains unchanged")
    end
    Equal(test.tts.CurrentSession, nil)
end)

Test("Speech rate validates integers and preserves existing SavedVariables", function()
    local test = Harness()
    -- Database initialization uses the assignment modes; the TTS-only harness hides them.
    test.addon.VoiceSelection = test.voiceSelection
    local saved = test.environment.OutLoudDB
    local voices = saved.voices
    test.db:SetVoice("HUMAN", 2, 7)
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
    Equal(test.db:GetAutoNarrateQuests(), true)
    Equal(test.db:GetAutoNarrationDelay(), 3.5)
end)

Test("Single-sentence requests use the current speech rate without changing active playback", function()
    local test = Harness()
    for _, rate in ipairs({ 0, -10, 10, 3 }) do
        test.db:SetSpeechRate(rate)
        Equal(test.tts:Speak("<Café & a book>.", 7), true)
        local index = #test.calls
        local session = test.tts.CurrentSession
        Equal(test.calls[index].rate, rate)
        Equal(test.calls[index].volume, 100)
        Equal(test.calls[index].overlap, false)
        Equal(test.calls[index].spoken, "Café &amp; a book .", "Keep sanitization and escaping")
        Equal(test.calls[index].mark, "OUTLOUD:SPEECH:" .. session.id .. ":1")
        local stops = test.stops
        test.db:SetSpeechRate(5)
        Equal(test.tts.CurrentSession, session)
        Equal(#test.calls, index, "Changing rate introduces no request")
        Equal(test.stops, stops)
        Equal(test.calls[index].rate, rate, "Existing request retains its submitted rate")
        test:Bookmark(index, 100 + index)
        Equal(#test.calls, index, "A single sentence creates one request")
        test:Event("FINISHED", 100 + index)
        Equal(test.tts.CurrentSession, nil)
    end
end)

Test("Streaming uses updated rates only on subsequent one-ahead submissions", function()
    local test = Harness()
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

local function RetiredSentence(test, sessionID, index)
    for _, session in ipairs(test.tts.SplitHistory or {}) do
        if session.id == sessionID then return session.sentenceStates[index], session end
    end
end

Test("Split records submission, ownership, early STARTED, and completion independently", function()
    local test = Harness()
    test.clock = 10
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    local first, second = session.sentenceStates[1], session.sentenceStates[2]
    local attempt = first.attempts[1]
    Equal(session.state, "active")
    Equal(first.sessionID, session.id)
    Equal(first.index, 1)
    Equal(first.state, "submitted")
    Equal(attempt.id, 1)
    Equal(attempt.submissionState, "returned")
    Equal(attempt.submittedAt, 10)
    Equal(attempt.bookmark, test.calls[1].mark)
    Equal(attempt.nativeState, "waiting-unconfirmed")
    Equal(second.state, "planned")
    Equal(#second.attempts, 0)
    test.clock = 11
    test:Event("STARTED", 101)
    Equal(attempt.ownershipConfirmed, nil, "STARTED cannot assign an attempt")
    Equal(#test.calls, 1)
    test.clock = 12
    test:Bookmark(1, 101)
    Equal(first.state, "playback-confirmed")
    Equal(attempt.ownershipConfirmed, true)
    Equal(attempt.utterances[101].startedAt, 11)
    Equal(attempt.nativeState, "bookmark-observed")
    Equal(second.state, "submitted")
    Equal(#test.calls, 2)
    test:Event("FINISHED", 101)
    Equal(first.state, "completed")
    Equal(attempt.nativeState, "finished-reported")
    Equal(attempt.unresolved, false)
    test:Bookmark(2, 102)
    test:Event("FINISHED", 102)
    test:Bookmark(3, 103)
    test:Event("FINISHED", 103)
    Equal(session.state, "completed")
    Equal(session.sentences, nil, "Release retired quest text")
    Equal(session.speechSentences, nil)
    Equal(session.onSessionEnded, nil)
    Equal(RetiredSentence(test, session.id, 1), first)
end)

Test("Manual cancellation preserves unknown native disposition without native acknowledgement", function()
    local test = Harness()
    local ended = 0
    test.tts:SpeakStreaming(text, 7, function() ended = ended + 1 end)
    local session = test.tts.CurrentSession
    test:Bookmark(1, 101)
    local first, prefetched, planned = unpack(session.sentenceStates)
    test.clock = 20
    test.tts:Stop()
    Equal(session.state, "cancelled")
    Equal(session.stopReason, "manual")
    Equal(session.stoppedAt, 20)
    Equal(first.state, "cancelled")
    Equal(first.attempts[1].nativeState, "unknown-after-stop")
    Equal(first.attempts[1].interruptionPossible, true)
    Equal(prefetched.state, "cancelled")
    Equal(prefetched.attempts[1].nativeState, "unknown-after-stop")
    Equal(prefetched.attempts[1].lastStopResult, "returned")
    Equal(planned.state, "cancelled")
    Equal(planned.submissionState, "not-submitted")
    Equal(#planned.attempts, 0)
    Equal(ended, 1)
    Equal(test.stops, 1)
    Equal(#test.calls, 2)
end)

Test("Emergency eligibility depends on recorded ownership and ambiguity", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local old = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    test:Bookmark(2, 102)
    test:Event("STARTED", 901)
    test.tts:SpeakStreaming("New.", 8)
    local current = test.tts.CurrentSession
    local attempt = old.sentenceStates[3].attempts[1]
    -- Predicate checks over record values, not simulated native queue outcomes.
    attempt.ownershipConfirmed, attempt.utteranceID = true, 103
    attempt.utterances[103] = { bookmarkAt = 2102.177 }
    local function Eligible()
        local decision = test.tts:GetSplitRecoveryEligibility(attempt, 103, true)
        Equal(decision.retryEligible, false)
        return decision.emergencyStopEligible
    end
    Equal(current.unidentifiedPlaybackCount, 1, "Replacement STOP cannot clear unidentified evidence")
    Equal(Eligible(), false)
    test:Event("FINISHED", 901)
    Equal(current.unidentifiedPlaybackCount, 0, "An observed terminal resolves the unidentified blocker")
    Equal(Eligible(), true)
    current.ownershipEvidenceObserved = true
    Equal(Eligible(), false)
    current.ownershipEvidenceObserved = nil
    test:Event("STARTED", 902)
    Equal(Eligible(), false)
    test:Event("FAILED", 902, 13)
    current.recoveryEvidenceLost = true
    Equal(Eligible(), false)
    current.recoveryEvidenceLost = nil
    current.emergencyRecoveryAttempted = true
    Equal(Eligible(), false)
    current.emergencyRecoveryAttempted = nil
    attempt.ownedAtCancellation = true
    Equal(Eligible(), false)
    attempt.ownedAtCancellation = false
    attempt.ambiguous = true
    Equal(Eligible(), false)
    attempt.ambiguous = nil
    attempt.utterances[103].terminal = "finished"
    Equal(Eligible(), false)
    attempt.utterances[103].terminal = nil
    Equal(test.tts:GetSplitRecoveryEligibility(attempt, 103, false).emergencyStopEligible, false)
    Equal(test.stops, 1, "Eligibility inspection does not issue native calls")
end)

Test("Unidentified terminals stop blocking without losing late ownership correlation", function()
    for _, terminal in ipairs({ "FINISHED", "FAILED" }) do
        local test = Harness()
        test.tts:SpeakStreaming("Only.", 7)
        local session = test.tts.CurrentSession
        test.clock = 1
        test:Event("STARTED", 901)
        test.clock = 2
        test:Event("BOOKMARK", 901, "Start")
        Equal(session.unidentifiedPlaybackCount, 1)
        test.clock = 3
        test:Event(terminal, 901, terminal == "FAILED" and 13 or nil)
        Equal(session.unidentifiedPlaybackCount, 0)
        Equal(test.tts.CurrentSession, session, "An unowned terminal cannot end narration")
        local evidence = session.unidentifiedPlayback[901]
        Equal(evidence.utteranceID, 901)
        Equal(evidence.firstEvent, "VOICE_CHAT_TTS_PLAYBACK_STARTED")
        Equal(evidence.firstAt, 1)
        Equal(evidence.lastEvent, "VOICE_CHAT_TTS_PLAYBACK_" .. terminal)
        Equal(evidence.lastAt, 3)
        Equal(evidence.terminal, terminal == "FINISHED" and "finished" or "failed")
        Equal(evidence.terminalAt, 3)
        test.clock = 4
        test:Event("STARTED", 901)
        test:Event(terminal, 901)
        Equal(session.unidentifiedPlaybackCount, 0, "Delayed/duplicate events do not reopen a retained terminal")
        test:Bookmark(1, 901)
        Equal(session.state, terminal == "FINISHED" and "completed" or "failed")
        Equal(session.sentenceStates[1].attempts[1].utterances[901].terminal, evidence.terminal)
        Equal(session.sentenceStates[1].attempts[1].utterances[901].startedAt, 1)
        Equal(#test.calls, 1, "Bookkeeping never resubmits")
    end
end)

Test("Idle diagnostics retain terminal records and distinguish blockers and cancellation source", function()
    local test = Harness()
    test.addon.DebugEnabled = true
    test.tts:SpeakStreaming(text, 7, nil, nil, nil, "Quest")
    test:Bookmark(1, 101)
    test:Bookmark(2, 102)
    test.clock = 1
    test:Event("STARTED", 901)
    test:Event("FINISHED", 901)
    test:Event("FAILED", 903, 13)
    test.clock = 2
    test:Event("STARTED", 902)
    test:Event("BOOKMARK", 902, "Start")
    local old = test.tts.CurrentSession
    test.tts:SpeakStreaming("New.", 8, nil, nil, nil, "Gossip")
    local current = test.tts.CurrentSession
    Equal(current.unidentifiedPlaybackCount, 1, "Replacement carries only unresolved blockers in the count")
    Equal(current.unidentifiedPlayback[901].terminal, "finished")
    Equal(current.unidentifiedPlayback[903].firstEvent, "VOICE_CHAT_TTS_PLAYBACK_FAILED")
    test:Bookmark(3, 103)
    Equal(test.stops, 1, "Unresolved evidence blocks the emergency call")
    local report = test.addon.GetTTSReport()
    assert(report:find("emergency-stop-blocker", 1, true))
    assert(report:find("utterance=902 state=unresolved", 1, true))
    assert(report:find("observed-source=Quest source=Gossip", 1, true))
    assert(report:find("trigger=replacement:Gossip", 1, true))
    test:Event("FINISHED", 902)
    Equal(current.unidentifiedPlaybackCount, 0)
    test:Bookmark(3, 103)
    Equal(test.stops, 1, "Resolving evidence does not retry a previously skipped stale bookmark")
    test.tts:Stop(nil, nil, "Talking Head close")
    local idle = test.tts.IdleSplitEvents
    Equal(idle.unidentifiedPlaybackCount, 0)
    Equal(idle.unidentifiedPlayback[902].terminal, "finished")
    report = test.addon.GetTTSReport()
    assert(report:find("Current: idle", 1, true))
    assert(report:find("Unidentified playback: unresolved=0", 1, true))
    assert(report:find("utterance=902 first=VOICE_CHAT_TTS_PLAYBACK_STARTED at=2", 1, true))
    assert(report:find("terminal=finished at=2", 1, true))
    assert(report:find("source=Gossip trigger=Talking Head close", 1, true))
    Equal(old.source, "Quest")
    Equal(current.stopReason, "manual", "Diagnostic trigger preserves the cancellation reason")
end)

Test("Unidentified retention evicts terminal metadata before losing unresolved evidence", function()
    local test = Harness()
    test.tts:SpeakStreaming("Only.", 7)
    local session = test.tts.CurrentSession
    for id = 1000, 1127 do test:Event("STARTED", id) end
    Equal(session.unidentifiedPlaybackCount, 128)
    test:Event("FINISHED", 2000)
    Equal(session.recoveryEvidenceLost, nil, "Discarding terminal metadata does not lose unresolved evidence")
    test:Event("FINISHED", 1000)
    Equal(session.unidentifiedPlaybackCount, 127)
    test:Event("STARTED", 2001)
    Equal(session.unidentifiedPlayback[1000], nil, "Prefer eviction of resolved metadata")
    Equal(session.unidentifiedPlaybackCount, 128)
    test:Event("STARTED", 2002)
    Equal(session.unidentifiedPlaybackCount, 128)
    Equal(session.recoveryEvidenceLost, true)
    local retained = 0
    for _ in pairs(session.unidentifiedPlayback) do retained = retained + 1 end
    Equal(retained, 128)
end)

Test("Emergency event deferral protects Lua state until the stop guard is released", function()
    local test = Harness()
    local started, progress = 0, 0
    test.tts:SpeakStreaming(text, 7, nil, function() started = started + 1 end,
        function() progress = progress + 1 end)
    local current = test.tts.CurrentSession
    -- Hold the Lua guard directly: the mock native STOP emits no events.
    test.tts.Stopping, test.tts.EmergencyStopEvents = true, {}
    test:Event("STARTED", 101)
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    Equal(current.sentenceStates[1].state, "submitted")
    Equal(started, 0)
    Equal(progress, 0)
    Equal(#test.calls, 1)
    Equal(#test.tts.EmergencyStopEvents, 3)
    test.tts.Stopping = false
    test.tts:ReplayEmergencyStopEvents()
    Equal(test.tts.CurrentSession, current)
    Equal(current.sentenceStates[1].state, "completed")
    Equal(current.sentenceStates[1].attempts[1].utterances[101].duringStop, true)
    Equal(current.unidentifiedPlaybackCount, 0)
    Equal(started, 1)
    Equal(progress, 1)
    Equal(#test.calls, 2, "Ownership resumes normal one-ahead prefetch")
    Equal(test.tts.EmergencyStopEvents, nil)
    Equal(test.tts.ReplayingEmergencyStop, nil)
    -- Direct cache isolation check; this asserts no native timing or STOP outcome.
    test.tts:SpeakStreaming("Replacement.", 8)
    local newer = test.tts.CurrentSession
    test.tts.EmergencyStopEvents = { {
        event = "VOICE_CHAT_TTS_PLAYBACK_FAILED", utteranceID = 999,
        sessionID = current.id, bookmark = 13,
    } }
    test.tts:ReplayEmergencyStopEvents()
    Equal(newer.pendingTerminals[999], nil, "Old unowned status cannot enter a replacement's terminal buffer")
    Equal(test.tts.CurrentSession, newer)
end)

Test("Split records playback failure separately from cancellation of its peers", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Event("FAILED", 101, 13)
    local failed, prefetched, planned = unpack(session.sentenceStates)
    Equal(session.state, "failed")
    Equal(session.stopReason, "playback-failed")
    Equal(failed.state, "failed")
    Equal(failed.attempts[1].nativeState, "failed-reported")
    Equal(failed.attempts[1].utterances[101].status, 13)
    Equal(prefetched.state, "cancelled")
    Equal(prefetched.attempts[1].playbackFailed, nil)
    Equal(prefetched.attempts[1].nativeState, "unknown-after-stop")
    Equal(planned.state, "cancelled")

    test = Harness()
    test.onSpeak = function() error("Mock submission exception") end
    local ok, reason = test.tts:SpeakStreaming(text, 7)
    Equal(ok, false)
    Equal(reason, "speech-failed")
    local submission = RetiredSentence(test, 1, 1)
    Equal(submission.state, "failed")
    Equal(submission.attempts[1].submissionState, "error")
    Equal(submission.attempts[1].submissionFailed, true)
    Equal(submission.attempts[1].playbackFailed, nil)
    Equal(submission.attempts[1].nativeState, "unknown-after-stop")
end)

Test("Additional native utterances are bounded evidence without duplicate progression", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local session = test.tts.CurrentSession
    local sentence = session.sentenceStates[1]
    local attempt = sentence.attempts[1]
    test:Bookmark(1, 101)
    test:Bookmark(1, 901)
    test:Event("FINISHED", 901)
    Equal(attempt.additionalUtterance, true)
    Equal(sentence.state, "playback-confirmed", "Secondary finish cannot complete the primary sentence")
    Equal(#test.calls, 2)
    for id = 902, 1000 do test:Bookmark(1, id) end
    Equal(attempt.utteranceCount, 2)
    Equal(attempt.evidenceOverflow, true)
    test:Event("FINISHED", 101)
    test:Event("FAILED", 101, 13)
    Equal(sentence.state, "completed", "Delayed contradictory events cannot regress completion")
    Equal(attempt.unresolved, true, "Unretained duplicate candidates remain uncertain")
    Equal(#test.calls, 2)
    Equal(#sentence.attempts, 1)
    Equal(test.stops, 0)
end)

Test("Nonnumeric and noncanonical bookmarks cannot claim Split ownership", function()
    local test = Harness()
    local started, updates = 0, 0
    test.tts:SpeakStreaming(text, 7, nil, function() started = started + 1 end,
        function() updates = updates + 1 end)
    local session = test.tts.CurrentSession
    for _, mark in ipairs({ "OUTLOUD:SPEECH:1:INVALID", "OUTLOUD:SPEECH:1:01",
        "OUTLOUD:SPEECH:01:1", "OUTLOUD:SPEECH:1:1:2" }) do
        test:Event("BOOKMARK", 999, mark)
    end
    Equal(started, 0)
    Equal(updates, 0)
    Equal(session.activeToken, nil)
    Equal(session.sentenceStates[1].attempts[1].ownershipConfirmed, nil)
    Equal(#test.calls, 1)
    test:Bookmark(1, 101)
    Equal(started, 1)
    Equal(updates, 1)
    Equal(#test.calls, 2)
end)

Test("Rapid switches correlate older cancellations without affecting the latest session", function()
    local test = Harness()
    local ids = {}
    for index = 1, 6 do
        test.tts:SpeakStreaming("First. Second.", 7)
        ids[index] = test.tts.CurrentSession.id
        test:Bookmark(#test.calls, 100 + index)
    end
    local current = test.tts.CurrentSession
    local calls, stops = #test.calls, test.stops
    for index = 1, 5 do
        test:Bookmark(index * 2, 200 + index)
        test:Event("STARTED", 200 + index)
        test:Event("FINISHED", 200 + index)
        test:Event("FAILED", 200 + index, 13)
        local sentence = RetiredSentence(test, ids[index], 2)
        Equal(sentence.state, "cancelled")
        Equal(sentence.attempts[1].playbackFinished, true)
        Equal(test.tts.CurrentSession, current)
    end
    Equal(current.state, "active")
    Equal(#test.calls, calls)
    Equal(test.stops, stops)
    test:Bookmark(calls, 300)
    test:Event("FINISHED", 300)
    Equal(current.state, "completed")
end)

Test("Reused native IDs are ambiguous and cannot fail newer narration", function()
    local test = Harness()
    test.tts:SpeakStreaming("Old.", 7)
    test:Bookmark(1, 101)
    test.tts:SpeakStreaming("New.", 8)
    local current = test.tts.CurrentSession
    test:Bookmark(2, 101)
    Equal(current.sentenceStates[1].attempts[1].ambiguous, true)
    test:Event("FAILED", 101, 13)
    test:Event("FINISHED", 101)
    Equal(test.tts.CurrentSession, current)
    Equal(current.state, "active")
    Equal(test.stops, 1)
end)

Test("Replacement callback narration cannot be overwritten by the enclosing request", function()
    local test = Harness()
    test.tts:SpeakStreaming("Old.", 7, function()
        test.tts:SpeakStreaming("Newest callback request.", 8)
    end)
    local ok, reason = test.tts:SpeakStreaming("Enclosing request.", 9)
    Equal(ok, false)
    Equal(reason, "session-replaced")
    Equal(test.tts.CurrentSession.id, 3)
    Equal(test.tts.CurrentSession.voiceID, 8)
    Equal(test.calls[2].spoken, "Newest callback request.")
    Equal(#test.calls, 2)
    Equal(test.stops, 1)
end)

Test("Split history is compact and bounded while all outgoing attempts record stop exposure", function()
    local test = Harness()
    test.tts:SpeakStreaming(string.rep("Private quest text. ", 256), 7)
    local outgoing = test.tts.CurrentSession
    for index = 2, 256 do test.tts:SubmitChunk(outgoing, index) end
    test.tts:Stop()
    Equal(outgoing.sentenceStates[1].attempts[1].stopCount, 1)
    Equal(#test.tts.SplitHistory[1].order, 128)
    Equal(RetiredSentence(test, outgoing.id, 1), nil, "Eviction is not native completion")
    Equal(test.tts.CancelledSession.pendingTokens[256], true)
    Equal(test.tts.CancelledSession.pendingTokens[1], nil)
    test:Bookmark(256, 1256)
    Equal(test.stops, 2, "Bounded stop eligibility retains the most recent submitted requests")
    for index = 1, 20 do
        test.tts:SpeakStreaming("Private quest text.", 7, function() end)
        test.tts:Stop()
    end
    Equal(#test.tts.SplitHistory, 8)
    local count = 0
    for _, session in ipairs(test.tts.SplitHistory) do
        Equal(session.sentences, nil)
        Equal(session.speechSentences, nil)
        Equal(session.onSessionEnded, nil)
        Equal(session.pendingTerminals, nil)
        for _, sentence in pairs(session.sentenceStates) do
            Equal(sentence.text, nil)
            Equal(sentence.session, nil)
            count = count + #sentence.attempts
        end
    end
    assert(count <= 128)
    local report = test.addon.GetTTSReport()
    assert(report:find("Retired Split metadata", 1, true))
    Equal(report:find("Private quest text.", 1, true), nil, "Retired snapshots never retain narration text")
end)

Test("Diagnostics return one bounded text-free report and do not drive playback", function()
    local test = Harness()
    test.addon.DebugEnabled = true
    assert(test.addon.GetTTSReport():find("Current: idle", 1, true), "Reporting before TTS initialization is safe")
    local private = "Unique private quest narration."
    test.tts:SpeakStreaming(private, 7)
    local session = test.tts.CurrentSession
    for id = 1, 1000 do
        test.clock = id
        test:Event("STARTED", 1000 + id)
        test:Event("FINISHED", 1000 + id)
    end
    Equal(#session.pendingStartOrder, 128)
    Equal(#session.pendingTerminalOrder, 128)
    Equal(session.unidentifiedPlaybackCount, 0, "Completed unidentified IDs cannot accumulate active blockers")
    Equal(session.recoveryEvidenceLost, nil, "Evicting resolved records does not weaken recovery evidence")
    Equal(test.tts.CurrentSession, session, "Unowned events cannot authorize retry or completion")
    Equal(#test.calls, 1)
    Equal(test.stops, 0)
    Equal(test.addon.TTSDiagnostics.count, 200)
    Equal(#test.addon.TTSDiagnostics.entries, 200)
    local chatCount = #test.diagnostics
    local report = test.environment._G.OutLoud.GetTTSReport()
    Equal(type(report), "string")
    Equal(report:find(private, 1, true), nil)
    assert(report:find("waiting-unconfirmed", 1, true))
    assert(report:find("1000.000 event-FINISHED", 1, true))
    Equal(report:find("#1 ", 1, true), nil, "Old events are discarded")
    Equal(#test.diagnostics, chatCount, "Obtaining a report never prints to chat")

    test = Harness(true)
    Equal(test.addon.TTSDiagnostics, nil)
    Equal(test.addon.GetTTSReport, nil)
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    test.tts:Stop()
    test:Bookmark(2, 102)
    Equal(test.stops, 2, "Recorder removal leaves cancellation policy functional")
    Equal(#test.calls, 2)

    test = Harness()
    test.addon.DebugEnabled = true
    test.addon.TTSDiagnostics.Record = function() error("Broken optional observer") end
    test.tts:SpeakStreaming("Only.", 7)
    local current = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test:Event("FINISHED", 101)
    Equal(current.state, "completed", "Observer errors cannot alter controller decisions")
end)

Test("Debug-off playback makes no observer calls or chat messages", function()
    local test = Harness()
    local recorder, observed = test.addon.TTSDiagnostics, 0
    local originalRecord = recorder.Record
    recorder.Record = function(self, ...)
        observed = observed + 1
        return originalRecord(self, ...)
    end
    Equal(test.addon.DebugEnabled, false)
    test.tts:SpeakStreaming(text, 7)
    test:Bookmark(1, 101)
    Equal(#test.calls, 2, "Debug-off preserves one-ahead submission")
    Equal(observed, 0)
    Equal(recorder.count, 0)
    Equal(#test.diagnostics, 0)
    test.addon.DebugEnabled = true
    test:Bookmark(2, 102)
    assert(observed > 0 and recorder.count > 0)
    test.addon.DebugEnabled = false
    local count, sequence, chats, calls = recorder.count, recorder.sequence, #test.diagnostics, observed
    test.tts:Stop()
    test:Bookmark(3, 103)
    Equal(test.stops, 2, "Disabling diagnostics preserves stale-playback STOP protection")
    Equal(observed, calls)
    Equal(recorder.count, count)
    Equal(recorder.sequence, sequence)
    Equal(#test.diagnostics, chats)
end)

Test("A failed Split native stop retains uncertainty and allows a new session", function()
    local test = Harness()
    test.tts:SpeakStreaming(text, 7)
    local old = test.tts.CurrentSession
    test:Bookmark(1, 101)
    test.onStop = function() error("Mock stop exception") end
    test.tts:Stop()
    Equal(old.state, "cancelled")
    Equal(old.sentenceStates[2].attempts[1].lastStopResult, "error")
    Equal(old.sentenceStates[2].attempts[1].nativeState, "unknown-after-stop")
    Equal(test.tts.Stopping, false)
    test.onStop = nil
    test.tts:SpeakStreaming("New.", 8)
    local current = test.tts.CurrentSession
    test:Bookmark(3, 103)
    test:Event("FINISHED", 103)
    Equal(current.state, "completed")
    Equal(#test.calls, 3)
end)

print("PASS: " .. passed .. " isolated controller logic checks; native TTS behavior unverified")
