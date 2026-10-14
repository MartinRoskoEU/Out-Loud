local AddonName, OutLoud = ...

local TTS = {}
OutLoud.TTS = TTS

TTS.ReadingModes = {
    FULL = "full",
    SPLIT = "split",
}

function TTS:GetVoices()
    if self.Voices then
        return self.Voices
    end

    self.Voices = C_VoiceChat.GetTtsVoices() or {}

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
    return (text:gsub("[/\\|_~]", " "):gsub("%s+", " ")
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

function TTS:Stop()
    local session = self.CurrentSession

    if not session then
        return false
    end

    session.cancelled = true
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
        0,
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

function TTS:GetBookmarkSession(sessionID)
    local session = self.CurrentSession
    if session and session.id == sessionID then
        return session
    end
    -- The counter recognizes stale owned audio after old session tables are discarded.
    if sessionID > 0 and sessionID <= self.SessionID then
        if not self:Stop() then
            StopPlayback(self)
        end
    end
end

function TTS:OnBookmark(utteranceID, bookmark)
    if type(bookmark) ~= "string" or type(utteranceID) ~= "number" then
        return
    end

    local sessionID, token = bookmark:match("^OUTLOUD:SPEECH:(%d+):(%w+)$")
    sessionID = tonumber(sessionID)
    local chunk = tonumber(token)

    if not sessionID or (token ~= "WHOLE" and (not chunk or chunk < 1)) then
        return
    end

    local session = self:GetBookmarkSession(sessionID)
    if not session then return end

    if session.mode == self.ReadingModes.SPLIT then
        if not chunk or not session.queued[chunk] then
            return
        end

        if not session.utterances[utteranceID] then
            OutLoud:Debug("TTS playback identified: session:", sessionID, "chunk:", chunk, "utterance:", utteranceID)
        end
        session.utterances[utteranceID] = chunk
        NotifyPlaybackStarted(session)
        if not session.activeToken or chunk > session.activeToken then
            session.activeToken = chunk
            NotifyTextProgress(self, session, chunk, 0)
        end
        self:SubmitChunk(session, chunk + 1)
    elseif token == "WHOLE" then
        if not session.utterances[utteranceID] then
            OutLoud:Debug("TTS playback identified: session:", sessionID, "whole text, utterance:", utteranceID)
        end
        session.utterances[utteranceID] = token
        NotifyPlaybackStarted(session)
        if not session.activeToken then
            session.activeToken = token
            NotifyTextProgress(self, session, token, 0)
        end
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
            OutLoud:Debug("Failure is unidentified and may belong to other TTS; session state left unchanged.")
        end
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" and token then
        OutLoud:Debug("TTS playback finished: session:", session.id, "chunk:", token, "utterance:", utteranceID)
        session.utterances[utteranceID] = nil

        if token == "WHOLE" or token == session.lastChunk then
            session.finished = true
            self.CurrentSession = nil
            OutLoud:Debug("TTS session completed:", session.id)
            NotifySessionEnded(session, "finished")
        end
    end
end
