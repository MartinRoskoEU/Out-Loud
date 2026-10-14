local AddonName, OutLoud = ...

local TTS = {}
OutLoud.TTS = TTS

local MAX_PENDING_TERMINALS = 128
local MAX_CANCELLED_TOKENS = 128

TTS.ReadingModes = {
    FULL = "full",
    SPLIT = "split",
}

function TTS:GetVoices()
    if self.Voices then
        return self.Voices
    end

    return self:RefreshVoices()
end

function TTS:RefreshVoices()
    self.Voices = self.Voices or {}
    if self.RefreshingVoices then return self.Voices end
    self.RefreshingVoices = true
    local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
    self.RefreshingVoices = false
    if ok and type(voices) == "table" then
        self.Voices = voices
    else
        OutLoud:Error("TTS voice enumeration failed; retaining the last available list:", tostring(voices))
    end
    return self.Voices
end

local function ValidInput(text, voiceID)
    if type(text) ~= "string" or not text:find("%S") then
        return false, "invalid-text"
    end

    if type(voiceID) ~= "number" or voiceID < 0 or voiceID % 1 ~= 0 then
        return false, "invalid-voice"
    end

    return true
end

local function StopPlayback(self)
    -- StopSpeakingText can itself emit playback events synchronously.
    if self.Stopping then
        return
    end

    self.Stopping = true
    local ok, message = pcall(C_VoiceChat.StopSpeakingText)
    self.Stopping = false
    if not ok then
        OutLoud:Error("TTS stop failed:", tostring(message))
    end
end

local function NotifySessionEnded(session, reason)
    if type(session.onSessionEnded) == "function" then
        local ok, message = pcall(session.onSessionEnded, reason, session.id)
        if not ok then
            OutLoud:Error("TTS session-end callback failed:", tostring(message))
        end
    end
end

local function NotifyPlaybackStarted(session)
    if session.playbackStarted then
        return
    end

    session.playbackStarted = true
    if type(session.onPlaybackStarted) == "function" then
        pcall(session.onPlaybackStarted, session.id)
    end
end

local function NotifyTextProgress(self, session, token, offset)
    if self.CurrentSession ~= session or type(session.onTextProgress) ~= "function" then
        return
    end
    local text = token == "WHOLE" and session.text or session.sentences[token]
    local ok, message = pcall(session.onTextProgress, text,
        token == "WHOLE" and 0 or token, offset, session.id)
    if not ok then
        OutLoud:Error("TTS text-progress callback failed:", tostring(message))
    end
end

function TTS:SplitSentences(text)
    local sentences = {}
    text = text:gsub("%s+", " ")
    for sentence in text:gmatch("[^.!?]+[.!?]*") do
        sentence = sentence:gsub("^%s+", ""):gsub("%s+$", "")
        if sentence ~= "" then
            sentences[#sentences + 1] = sentence
        end
    end
    return sentences
end

function TTS:SanitizeSpeechText(text)
    -- XML 1.0 forbids these ASCII controls, including NUL. UTF-8 bytes stay intact.
    return (text:gsub("[%z\1-\8\11\12\14-\31]", " ")
        :gsub("[/\\|_~<>]", " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", ""))
end

local function EscapeSpeechText(text)
    -- Escape only speech, before adding trusted ownership markup.
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function TTS:Initialize()
    if self.Initialized then
        return
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_STARTED")
    frame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_BOOKMARK")
    frame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED")
    frame:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED")
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)

    C_TTSSettings.SetSetting(
        Enum.TtsBoolSetting.PlaySoundSeparatingChatLineBreaks,
        false
    )

    self.Frame = frame
    self.SessionID = 0
    self.Initialized = true
end

local function RememberCancelledSession(self, session)
    local pendingTokens, count = {}, 0
    local identifiedTokens = {}
    for _, token in pairs(session.utterances) do identifiedTokens[token] = true end
    if session.mode == self.ReadingModes.SPLIT then
        for chunk in pairs(session.queued or {}) do
            if not session.completedTokens[chunk] and not identifiedTokens[chunk]
                and count < MAX_CANCELLED_TOKENS then
                pendingTokens[chunk] = true
                count = count + 1
            end
        end
    elseif session.text and not session.completedTokens.WHOLE and not identifiedTokens.WHOLE then
        pendingTokens.WHOLE = true
    end
    -- Keep only a bounded summary of the most recent cancellation, without text/buffers.
    self.CancelledSession = next(pendingTokens)
        and { id = session.id, pendingTokens = pendingTokens } or nil
end

function TTS:Stop()
    local session = self.CurrentSession

    if not session then
        return false
    end

    session.cancelled = true
    RememberCancelledSession(self, session)
    self.CurrentSession = nil
    OutLoud:Debug("TTS stopping session:", session.id)
    StopPlayback(self)
    NotifySessionEnded(session, session.failed and "failed" or "cancelled")

    return true
end

function TTS:StartSession(mode, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    self:Initialize()
    self:Stop()

    self.SessionID = self.SessionID + 1

    local session = {
        id = self.SessionID,
        mode = mode,
        voiceID = voiceID,
        utterances = {},
        completedTokens = {},
        completedUtterances = {},
        pendingTerminals = {},
        pendingTerminalOrder = {},
        onSessionEnded = onSessionEnded,
        onPlaybackStarted = onPlaybackStarted,
        onTextProgress = onTextProgress,
    }

    self.CurrentSession = session
    OutLoud:Debug("TTS session:", session.id, "mode:", mode, "voice:", voiceID)

    return session
end

function TTS:SubmitText(session, text, chunk)
    if text == "" then
        return false, "invalid-text"
    end

    local token = chunk or "WHOLE"
    local mark = "OUTLOUD:SPEECH:" .. session.id .. ":" .. token
    OutLoud:Debug("TTS SpeakText call: session:", session.id, "chunk:", token, "bytes:", #text)
    local ok, message = pcall(
        C_VoiceChat.SpeakText,
        session.voiceID,
        '<bookmark mark="' .. mark .. '"/>' .. EscapeSpeechText(text),
        OutLoud.Database:GetSpeechRate(),
        100,
        false
    )

    if not ok then
        OutLoud:Error("TTS SpeakText failed: session:", session.id, "error:", tostring(message))
        session.failed = true

        if self.CurrentSession == session then
            self:Stop()
        end
    end

    if session.failed then
        return false, "speech-failed"
    end

    return true
end

function TTS:SubmitChunk(session, chunk)
    if self.CurrentSession ~= session then
        return false
    end

    -- Empty speech has no playback bookmark; advance without renumbering display text.
    while session.speechSentences[chunk] == "" do
        chunk = chunk + 1
    end

    if session.queued[chunk] then
        return false
    end

    local sentence = session.speechSentences[chunk]

    if not sentence then
        return false
    end

    -- Set before calling the engine because events may arrive synchronously.
    session.queued[chunk] = true
    return self:SubmitText(session, sentence, chunk)
end

function TTS:SpeakStreaming(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    local valid, reason = ValidInput(text, voiceID)

    if not valid then
        return false, reason
    end

    local sentences = self:SplitSentences(text)

    if #sentences == 0 then
        return false, "no-sentences"
    end

    local speechSentences = {}
    local lastChunk
    for chunk, sentence in ipairs(sentences) do
        speechSentences[chunk] = self:SanitizeSpeechText(sentence)
        if speechSentences[chunk] ~= "" then
            lastChunk = chunk
        end
    end
    if not lastChunk then
        return false, "invalid-text"
    end

    local session = self:StartSession(self.ReadingModes.SPLIT, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    session.sentences = sentences
    session.speechSentences = speechSentences
    session.lastChunk = lastChunk
    session.queued = {}

    return self:SubmitChunk(session, 1)
end

function TTS:SpeakWholeText(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    local valid, reason = ValidInput(text, voiceID)

    if not valid then
        return false, reason
    end

    local speechText = self:SanitizeSpeechText(text)
    if speechText == "" then
        return false, "invalid-text"
    end

    local session = self:StartSession(self.ReadingModes.FULL, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    session.text = text
    return self:SubmitText(session, speechText)
end

function TTS:Speak(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    if OutLoud.Database:GetReadingMode() == self.ReadingModes.SPLIT then
        return self:SpeakStreaming(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
    end

    return self:SpeakWholeText(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress)
end

function TTS:GetBookmarkSession(sessionID, token)
    local session = self.CurrentSession
    if session and session.id == sessionID then
        return session
    end
    local cancelled = self.CancelledSession
    if not cancelled or cancelled.id ~= sessionID or not cancelled.pendingTokens[token] then
        return
    end
    -- Consume even an ignored active-session notification so a repeat while idle is harmless.
    cancelled.pendingTokens[token] = nil
    if session then
        if not next(cancelled.pendingTokens) then self.CancelledSession = nil end
        return
    end
    -- One follow-up for delayed unbookmarked playback, only while Out Loud is idle.
    -- This is still a global native stop and can interrupt unrelated TTS.
    self.CancelledSession = nil
    StopPlayback(self)
end

local function RememberTerminal(session, event, utteranceID, status)
    if type(utteranceID) ~= "number" or utteranceID ~= utteranceID
        or session.completedUtterances[utteranceID] then
        return
    end

    local pending = session.pendingTerminals[utteranceID]
    if pending then
        if event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" then
            pending.event, pending.status = event, status
        end
        return
    end

    local order = session.pendingTerminalOrder
    if #order >= MAX_PENDING_TERMINALS then
        local oldest = table.remove(order, 1)
        if session.pendingTerminals[oldest.utteranceID] == oldest then
            session.pendingTerminals[oldest.utteranceID] = nil
        end
    end
    pending = { event = event, utteranceID = utteranceID, status = status }
    session.pendingTerminals[utteranceID] = pending
    order[#order + 1] = pending
end

function TTS:OnBookmark(utteranceID, bookmark)
    if type(bookmark) ~= "string" or type(utteranceID) ~= "number"
        or utteranceID ~= utteranceID then
        return
    end

    local sessionID, token = bookmark:match("^OUTLOUD:SPEECH:(%d+):(%w+)$")
    sessionID = tonumber(sessionID)
    local chunk = tonumber(token)

    if not sessionID or (token ~= "WHOLE" and (not chunk or chunk < 1)) then
        return
    end

    local session = self:GetBookmarkSession(sessionID, chunk or token)
    if not session then return end

    if session.mode == self.ReadingModes.SPLIT then
        if not chunk or not session.queued[chunk] then
            return
        end

        token = chunk
    elseif token ~= "WHOLE" then
        return
    end

    if session.completedTokens[token] or session.completedUtterances[utteranceID] then
        return
    end
    local identified = session.utterances[utteranceID]
    if identified and identified ~= token then return end
    session.utterances[utteranceID] = token

    -- Only this matching bookmark proves ownership of a previously seen event.
    local pending = session.pendingTerminals[utteranceID]
    if pending then
        session.pendingTerminals[utteranceID] = nil
        self:OnEvent(pending.event, utteranceID, pending.status)
        if self.CurrentSession == session and session.mode == self.ReadingModes.SPLIT then
            self:SubmitChunk(session, chunk + 1)
        end
        return
    end

    OutLoud:Debug("TTS playback identified: session:", sessionID, "chunk:", token, "utterance:", utteranceID)
    NotifyPlaybackStarted(session)
    if self.CurrentSession ~= session then return end
    if not session.activeToken or (chunk and chunk > session.activeToken) then
        session.activeToken = token
        NotifyTextProgress(self, session, token, 0)
    end
    if session.mode == self.ReadingModes.SPLIT then
        self:SubmitChunk(session, chunk + 1)
    end
end

function TTS:OnEvent(event, utteranceID, bookmark)
    if event == "PLAYER_LOGOUT" then
        -- Also emitted when /reload tears down the current UI.
        self:Stop()
        return
    end

    if self.Stopping then
        return
    end

    if event == "VOICE_CHAT_TTS_PLAYBACK_BOOKMARK" then
        self:OnBookmark(utteranceID, bookmark)
        return
    end

    -- STARTED alone cannot establish ownership or authorize prefetching.
    local session = self.CurrentSession

    if not session then
        return
    end

    local token = session.utterances[utteranceID]
    if token and session.completedTokens[token] then
        session.utterances[utteranceID] = nil
        session.completedUtterances[utteranceID] = true
        return
    end

    if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
        OutLoud:Debug("TTS PLAYBACK_STARTED: utterance:", tostring(utteranceID),
            "owned:", token ~= nil, "Awaiting ownership bookmark if unidentified.")
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" then
        OutLoud:Debug("TTS PLAYBACK_FAILED: utterance:", tostring(utteranceID),
            "status:", tostring(bookmark), "owned:", token ~= nil)
        -- Without an ownership bookmark, a failure could belong to other TTS.
        if token then
            OutLoud:Error("TTS playback failed: session:", session.id, "status:", tostring(bookmark))
            session.failed = true
            self:Stop()
        else
            RememberTerminal(session, event, utteranceID, bookmark)
            OutLoud:Debug("Failure is unidentified; retained pending a matching ownership bookmark.")
        end
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" then
        if not token then
            RememberTerminal(session, event, utteranceID)
            return
        end
        OutLoud:Debug("TTS playback finished: session:", session.id, "chunk:", token, "utterance:", utteranceID)
        session.utterances[utteranceID] = nil
        session.completedTokens[token] = true
        session.completedUtterances[utteranceID] = true

        if token == "WHOLE" or token == session.lastChunk then
            session.finished = true
            self.CurrentSession = nil
            OutLoud:Debug("TTS session completed:", session.id)
            NotifySessionEnded(session, "finished")
        end
    end
end
