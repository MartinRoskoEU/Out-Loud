local AddonName, OutLoud = ...

local TTS = {}
OutLoud.TTS = TTS

local MAX_PENDING_TERMINALS = 128
local MAX_CANCELLED_TOKENS = 128
local MAX_HISTORY_SESSIONS = 8
local MAX_HISTORY_ATTEMPTS = 128
local MAX_ATTEMPT_UTTERANCES = 2

local function Now()
    return GetTime and GetTime() or 0
end

-- Optional observer. Playback never reads diagnostic state.
local function Record(event, sessionID, chunk, attemptID, utteranceID, detail)
    local recorder = OutLoud.TTSDiagnostics
    if recorder then
        pcall(recorder.Record, recorder, event, sessionID, chunk, attemptID, utteranceID, detail)
    end
end

local function SetSentenceState(sentence, state)
    if sentence.state == state then return end
    Record("sentence-state", sentence.sessionID, sentence.index, nil, nil,
        sentence.state .. "->" .. state)
    sentence.state = state
    sentence.changedAt = Now()
end

local function TerminalKnown(attempt)
    if attempt.evidenceOverflow or attempt.ambiguous then return false end
    local found = false
    for _, observation in pairs(attempt.utterances) do
        if not observation.terminal then return false end
        found = true
    end
    return found
end

local function RefreshNativeState(attempt)
    local previous = attempt.nativeState
    if TerminalKnown(attempt) then
        attempt.nativeState = attempt.playbackFailed and "failed-reported" or "finished-reported"
        attempt.unresolved = false
    else
        attempt.unresolved = true
        attempt.nativeState = attempt.stopCount > 0 and "unknown-after-stop"
            or (attempt.ownershipConfirmed and "bookmark-observed" or "waiting-unconfirmed")
    end
    if previous ~= attempt.nativeState then
        Record("attempt-state", attempt.sessionID, attempt.sentenceIndex, attempt.id, attempt.utteranceID,
            previous .. "->" .. attempt.nativeState)
    end
end

local function SplitBuffer()
    return { pendingTerminals = {}, pendingTerminalOrder = {}, pendingStarts = {}, pendingStartOrder = {},
        unidentifiedPlayback = {}, unidentifiedPlaybackCount = 0 }
end

local function RetainUnidentifiedPlayback(buffer, utteranceID, evidence)
    local count, oldestID, oldestAt = 0
    for id, retained in pairs(buffer.unidentifiedPlayback) do
        count = count + 1
        if retained.terminal and (not oldestAt or retained.lastAt < oldestAt) then
            oldestID, oldestAt = id, retained.lastAt
        end
    end
    if count >= MAX_PENDING_TERMINALS then
        if oldestID then
            buffer.unidentifiedPlayback[oldestID] = nil
        else
            -- Losing unresolved evidence must not permit a global recovery stop.
            if not evidence.terminal then buffer.recoveryEvidenceLost = true end
            return false
        end
    end
    buffer.unidentifiedPlayback[utteranceID] = evidence
    if not evidence.terminal then buffer.unidentifiedPlaybackCount = buffer.unidentifiedPlaybackCount + 1 end
    return true
end

local function CarryRecoveryEvidence(source, target)
    if not source or not target.unidentifiedPlayback then return end
    target.recoveryEvidenceLost = target.recoveryEvidenceLost or source.recoveryEvidenceLost
    target.recoveryOwnershipAmbiguous = target.recoveryOwnershipAmbiguous or source.recoveryOwnershipAmbiguous
    for utteranceID, evidence in pairs(source.unidentifiedPlayback or {}) do
        if not target.unidentifiedPlayback[utteranceID] then
            RetainUnidentifiedPlayback(target, utteranceID, evidence)
        end
    end
end

local function ArchiveSplitSession(self, session)
    self.SplitHistory = self.SplitHistory or {}
    local history = {
        id = session.id, mode = session.mode, state = session.state,
        createdAt = session.createdAt, endedAt = session.endedAt,
        endReason = session.endReason, stopReason = session.stopReason, stoppedAt = session.stoppedAt,
        replacedBy = session.replacedBy,
        source = session.source, stopTrigger = session.stopTrigger,
        emergencyRecoveryAttempted = session.emergencyRecoveryAttempted,
        emergencyRecoveryAt = session.emergencyRecoveryAt,
        emergencyRecoveryResult = session.emergencyRecoveryResult,
        emergencyRecoveredFrom = session.emergencyRecoveredFrom,
        recoveryEvidenceLost = session.recoveryEvidenceLost,
        sentenceCount = #session.sentenceStates, sentenceStates = {}, order = {},
    }
    -- These records contain IDs/evidence only, never text, callbacks or parent objects.
    for index, sentence in ipairs(session.sentenceStates) do
        if #sentence.attempts > 0 then
            history.sentenceStates[index] = sentence
            history.order[#history.order + 1] = index
        end
    end
    self.SplitHistory[#self.SplitHistory + 1] = history
    while #self.SplitHistory > MAX_HISTORY_SESSIONS do
        table.remove(self.SplitHistory, 1)
    end
    local count = 0
    for _, retired in ipairs(self.SplitHistory) do
        for _, sentence in pairs(retired.sentenceStates) do count = count + #sentence.attempts end
    end
    for _, retired in ipairs(self.SplitHistory) do
        while count > MAX_HISTORY_ATTEMPTS and #retired.order > 0 do
            local index = table.remove(retired.order, 1)
            count = count - #retired.sentenceStates[index].attempts
            retired.sentenceStates[index] = nil
        end
    end
end

local function ReleaseSplitSession(session)
    session.sentences, session.speechSentences = nil, nil
    session.onSessionEnded, session.onPlaybackStarted, session.onTextProgress = nil, nil, nil
    session.pendingTerminals, session.pendingTerminalOrder = {}, {}
    session.pendingStarts, session.pendingStartOrder = {}, {}
    session.attemptBindings = {}
    session.unidentifiedPlayback, session.unidentifiedPlaybackCount = {}, 0
end

local function FindRetiredSentence(self, sessionID, chunk)
    for _, retired in ipairs(self.SplitHistory or {}) do
        if retired.id == sessionID then return retired.sentenceStates[chunk], retired end
    end
end

local function FindSplitOwner(self, utteranceID)
    local session = self.CurrentSession
    local owner = session and session.attemptBindings and session.attemptBindings[utteranceID]
    local conflict = false
    for _, retired in ipairs(self.SplitHistory or {}) do
        for _, sentence in pairs(retired.sentenceStates) do
            for _, attempt in ipairs(sentence.attempts) do
                if attempt.utterances[utteranceID] then
                    if owner and owner ~= attempt then conflict = true else owner = attempt end
                end
            end
        end
    end
    -- A Full-mode binding can also conflict with a retired Split utterance.
    if owner and session and session.mode == "full" and session.utterances[utteranceID] then
        conflict = true
    end
    return owner, conflict
end

local function EachSplitAttempt(self, callback, outgoing)
    local seen = {}
    local function Visit(session)
        for _, sentence in pairs(session and session.sentenceStates or {}) do
            for _, attempt in ipairs(sentence.attempts) do
                if not seen[attempt] then seen[attempt] = true; callback(attempt) end
            end
        end
    end
    Visit(outgoing)
    Visit(self.CurrentSession)
    for _, retired in ipairs(self.SplitHistory or {}) do
        Visit(retired)
    end
end

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

local function StopPlayback(self, reason, outgoing)
    -- StopSpeakingText can itself emit playback events synchronously.
    if self.Stopping then
        return
    end

    self.Stopping = true
    self.StopID = (self.StopID or 0) + 1
    local stopID, stoppedAt = self.StopID, Now()
    EachSplitAttempt(self, function(attempt)
        if not TerminalKnown(attempt) then
            attempt.stopCount = attempt.stopCount + 1
            attempt.interruptionPossible = true
            attempt.lastStopID, attempt.lastStopAt, attempt.lastStopResult = stopID, stoppedAt, "calling"
            RefreshNativeState(attempt)
        end
    end, outgoing)
    Record("native-stop", nil, nil, nil, nil, "id=" .. stopID .. " reason=" .. (reason or "unknown"))
    local ok, message = pcall(C_VoiceChat.StopSpeakingText)
    self.Stopping = false
    EachSplitAttempt(self, function(attempt)
        if attempt.lastStopID == stopID then attempt.lastStopResult = ok and "returned" or "error" end
    end, outgoing)
    Record("native-stop-result", nil, nil, nil, nil, "id=" .. stopID .. " result=" .. (ok and "returned" or "error"))
    if not ok then
        OutLoud:Error("TTS stop failed:", tostring(message))
    end
    return ok
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
        -- Prefer recent submissions, matching compact history's retention order.
        for chunk = #session.sentenceStates, 1, -1 do
            local sentence = session.sentenceStates[chunk]
            local attempt = sentence.attempts[1]
            if attempt and not attempt.ownershipConfirmed and not TerminalKnown(attempt)
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

function TTS:Stop(reason, replacedBy, diagnosticTrigger)
    -- Notify before native code can reenter, including when no session exists yet.
    if type(self.onStopRequested) == "function" then
        local ok, message = pcall(self.onStopRequested, reason, replacedBy, diagnosticTrigger)
        if not ok then OutLoud:Error("TTS stop observer failed:", tostring(message)) end
    end
    local session = self.CurrentSession

    if not session then
        return false
    end

    session.cancelled = true
    session.state = session.failed and "failed" or "cancelled"
    session.stopReason = reason or "manual"
    session.stopTrigger = diagnosticTrigger or session.stopReason
    session.stoppedAt, session.endedAt = Now(), Now()
    session.endReason = session.failed and "failed" or "cancelled"
    session.replacedBy = replacedBy
    RememberCancelledSession(self, session)
    self.CurrentSession = nil
    self.IdleSplitEvents = SplitBuffer()
    CarryRecoveryEvidence(session, self.IdleSplitEvents)
    if session.sentenceStates then
        for _, sentence in ipairs(session.sentenceStates) do
            if sentence.state ~= "completed" and sentence.state ~= "skipped" then
                sentence.logicalCancelled, sentence.cancelledAt = true, session.stoppedAt
                if sentence.state ~= "failed" then SetSentenceState(sentence, "cancelled") end
            end
            for _, attempt in ipairs(sentence.attempts) do
                attempt.logicalCancelled = sentence.logicalCancelled == true
                attempt.ownedAtCancellation = attempt.ownershipConfirmed == true
            end
        end
        ArchiveSplitSession(self, session)
    end
    Record("session-" .. session.state, session.id, nil, nil, nil,
        "reason=" .. session.stopReason .. " replacement=" .. tostring(replacedBy or "-")
        .. " source=" .. session.source .. " trigger=" .. session.stopTrigger)
    if replacedBy then Record("session-replaced", session.id, nil, nil, nil, "new=" .. replacedBy) end
    OutLoud:Debug("TTS stopping session:", session.id)
    StopPlayback(self, session.stopReason, session)
    NotifySessionEnded(session, session.failed and "failed" or "cancelled")
    if session.sentenceStates then ReleaseSplitSession(session) end

    return true
end

function TTS:StartSession(mode, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
    self:Initialize()
    -- Reserve this request's identity before callbacks can request newer narration.
    self.SessionID = self.SessionID + 1

    local session = {
        id = self.SessionID,
        mode = mode,
        voiceID = voiceID,
        state = "active",
        source = type(diagnosticSource) == "string" and diagnosticSource or "Direct TTS",
        createdAt = Now(),
        utterances = {},
        completedTokens = {},
        completedUtterances = {},
        pendingTerminals = {},
        pendingTerminalOrder = {},
        pendingStarts = {},
        pendingStartOrder = {},
        attemptBindings = {},
        onSessionEnded = onSessionEnded,
        onPlaybackStarted = onPlaybackStarted,
        onTextProgress = onTextProgress,
    }
    -- Metadata only in Full mode; its playback handling/recovery policy is unchanged.
    session.unidentifiedPlayback, session.unidentifiedPlaybackCount = {}, 0

    Record("session-created", session.id, nil, nil, nil, "mode=" .. mode .. " source=" .. session.source)
    self:Stop("replaced", session.id, "replacement:" .. session.source)
    if self.SessionID ~= session.id then
        session.cancelled, session.state, session.stopReason = true, "cancelled", "superseded-during-replacement"
        session.endReason, session.endedAt = "cancelled", Now()
        Record("session-cancelled", session.id, nil, nil, nil, session.stopReason)
        return session
    end
    CarryRecoveryEvidence(self.IdleSplitEvents, session)
    self.IdleSplitEvents = nil
    self.CurrentSession = session
    Record("session-active", session.id)
    OutLoud:Debug("TTS session:", session.id, "mode:", mode, "voice:", voiceID)

    return session
end

function TTS:SubmitText(session, text, chunk)
    if text == "" then
        return false, "invalid-text"
    end

    local token = chunk or "WHOLE"
    local mark = "OUTLOUD:SPEECH:" .. session.id .. ":" .. token
    local attempt
    if session.mode == self.ReadingModes.SPLIT then
        if self.CurrentSession ~= session or session.state ~= "active" then return false end
        local sentence = session.sentenceStates[chunk]
        if not sentence or sentence.state ~= "planned" then return false end
        attempt = {
            sessionID = session.id, sentenceIndex = chunk, id = #sentence.attempts + 1,
            bookmark = mark, submissionState = "calling", submittedAt = Now(),
            voiceID = session.voiceID, rate = OutLoud.Database:GetSpeechRate(),
            utterances = {}, utteranceCount = 0, stopCount = 0,
            nativeState = "waiting-unconfirmed", unresolved = true,
        }
        sentence.attempts[#sentence.attempts + 1] = attempt
        sentence.submissionState, sentence.bookmark = "calling", mark
        SetSentenceState(sentence, "submitted")
        -- Compatibility views only; Split decisions use the lifecycle records.
        session.queued[chunk] = true
    end
    local rate = attempt and attempt.rate or OutLoud.Database:GetSpeechRate()
    Record("submission", session.id, token, attempt and attempt.id, nil, "rate=" .. rate)
    OutLoud:Debug("TTS SpeakText call: session:", session.id, "chunk:", token, "bytes:", #text)
    local ok, message = pcall(
        C_VoiceChat.SpeakText,
        session.voiceID,
        '<bookmark mark="' .. mark .. '"/>' .. EscapeSpeechText(text),
        rate,
        100,
        false
    )

    if attempt then
        -- Synchronous native events may already have completed/cancelled this attempt.
        attempt.submissionState = ok and "returned" or "error"
        attempt.submissionReturnedAt = Now()
        session.sentenceStates[chunk].submissionState = attempt.submissionState
        if not ok then
            attempt.submissionFailed = true
            local sentence = session.sentenceStates[chunk]
            if session.state == "active" and sentence.state ~= "completed" then SetSentenceState(sentence, "failed") end
        end
    end
    Record("submission-result", session.id, token, attempt and attempt.id, nil, ok and "returned" or "error")

    if not ok then
        OutLoud:Error("TTS SpeakText failed: session:", session.id, "error:", tostring(message))
        if session.state == "active" then session.failed = true end
        if self.CurrentSession == session then
            self:Stop("submission-failed")
        end
        return false, "speech-failed"
    end

    if session.failed then
        return false, "speech-failed"
    end

    return true
end

function TTS:SubmitChunk(session, chunk)
    if self.CurrentSession ~= session or session.state ~= "active" then
        return false
    end

    -- Empty speech has no playback bookmark; advance without renumbering display text.
    while session.sentenceStates[chunk] and session.sentenceStates[chunk].state == "skipped" do
        chunk = chunk + 1
    end

    local record = session.sentenceStates[chunk]
    if not record or record.state ~= "planned" then
        return false
    end

    local sentence = session.speechSentences[chunk]

    if not sentence then
        return false
    end

    return self:SubmitText(session, sentence, chunk)
end

function TTS:SpeakStreaming(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
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

    local session = self:StartSession(self.ReadingModes.SPLIT, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
    if self.CurrentSession ~= session then return false, "session-replaced" end
    session.sentences = sentences
    session.speechSentences = speechSentences
    session.lastChunk = lastChunk
    session.queued = {}
    session.sentenceStates = {}
    for chunk = 1, #sentences do
        session.sentenceStates[chunk] = {
            sessionID = session.id, index = chunk, attempts = {},
            state = speechSentences[chunk] == "" and "skipped" or "planned",
            submissionState = "not-submitted", changedAt = Now(),
        }
    end

    return self:SubmitChunk(session, 1)
end

function TTS:SpeakWholeText(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
    local valid, reason = ValidInput(text, voiceID)

    if not valid then
        return false, reason
    end

    local speechText = self:SanitizeSpeechText(text)
    if speechText == "" then
        return false, "invalid-text"
    end

    local session = self:StartSession(self.ReadingModes.FULL, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
    if self.CurrentSession ~= session then return false, "session-replaced" end
    session.text = text
    return self:SubmitText(session, speechText)
end

function TTS:Speak(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource, readingMode)
    if (readingMode or OutLoud.Database:GetReadingMode()) == self.ReadingModes.SPLIT then
        return self:SpeakStreaming(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
    end

    return self:SpeakWholeText(text, voiceID, onSessionEnded, onPlaybackStarted, onTextProgress, diagnosticSource)
end

function TTS:GetBookmarkSession(sessionID, token, allowStop)
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
    if allowStop == false then
        if not next(cancelled.pendingTokens) then self.CancelledSession = nil end
        return
    end
    -- One follow-up for delayed unbookmarked playback, only while Out Loud is idle.
    -- This is still a global native stop and can interrupt unrelated TTS.
    self.CancelledSession = nil
    StopPlayback(self, "idle-stale-bookmark")
end

local RememberTerminal

local function RememberStart(buffer, utteranceID)
    if buffer.pendingStarts[utteranceID] then return end
    if #buffer.pendingStartOrder >= MAX_PENDING_TERMINALS then
        local oldest = table.remove(buffer.pendingStartOrder, 1)
        if buffer.pendingStarts[oldest.utteranceID] == oldest then buffer.pendingStarts[oldest.utteranceID] = nil end
    end
    local pending = { utteranceID = utteranceID, at = Now() }
    buffer.pendingStarts[utteranceID] = pending
    buffer.pendingStartOrder[#buffer.pendingStartOrder + 1] = pending
end

function TTS:GetSplitRecoveryEligibility(attempt, utteranceID, fresh)
    local eligibility = { idleStopEligible = false, emergencyStopEligible = false, retryEligible = false }
    local cancelled = self.CancelledSession
    if not attempt.logicalCancelled then
        eligibility.reason = "not-logically-cancelled"
    elseif TerminalKnown(attempt) then
        eligibility.reason = "terminal-observed"
    elseif self.CurrentSession then
        local session = self.CurrentSession
        local sentence, retired = FindRetiredSentence(self, attempt.sessionID, attempt.sentenceIndex)
        local observation = attempt.utterances[utteranceID or attempt.utteranceID]
        if session.mode ~= self.ReadingModes.SPLIT then
            eligibility.reason = "full-mode-preserved"
        elseif session.state ~= "active" or session.id <= attempt.sessionID then
            eligibility.reason = "no-newer-active-session"
        elseif not retired or not sentence or retired.state ~= "cancelled" or not sentence.logicalCancelled then
            eligibility.reason = "source-session-not-cancelled"
        elseif fresh == false then
            eligibility.reason = "duplicate-stale-bookmark"
        elseif not attempt.ownershipConfirmed or not observation then
            eligibility.reason = "stale-ownership-unconfirmed"
        elseif observation.terminal then
            eligibility.reason = "stale-utterance-terminal"
        elseif attempt.ownedAtCancellation then
            eligibility.reason = "ownership-already-known-at-cancellation"
        elseif attempt.ambiguous or attempt.evidenceOverflow or attempt.additionalUtterance then
            eligibility.reason = "stale-ownership-ambiguous"
        elseif attempt.submissionState ~= "returned" or attempt.stopCount == 0 or attempt.lastStopResult ~= "returned" then
            eligibility.reason = "submission-or-initial-stop-unresolved"
        elseif session.emergencyRecoveryAttempted then
            eligibility.reason = "emergency-budget-used"
        elseif self.Stopping or self.ReplayingEmergencyStop then
            eligibility.reason = "native-stop-or-replay-in-progress"
        elseif session.ownershipEvidenceObserved or session.playbackStarted then
            eligibility.reason = "newer-ownership-observed"
        elseif session.recoveryEvidenceLost or session.recoveryOwnershipAmbiguous then
            eligibility.reason = "playback-evidence-incomplete-or-ambiguous"
        elseif session.unidentifiedPlaybackCount > 0 then
            eligibility.reason = "other-unidentified-playback"
        else
            eligibility.emergencyStopEligible = true
            eligibility.reason = "experimental-stale-owned-newer-unowned"
        end
    elseif cancelled and cancelled.id == attempt.sessionID
        and cancelled.pendingTokens[attempt.sentenceIndex] and not attempt.ownedAtCancellation then
        eligibility.idleStopEligible = true
        eligibility.reason = "idle-cancelled-unidentified-follow-up"
    else
        eligibility.reason = "native-state-unknown-no-safe-retry"
    end
    return eligibility
end

local function ClearUnidentifiedPlayback(session, utteranceID)
    if session and session.unidentifiedPlayback and session.unidentifiedPlayback[utteranceID] then
        local evidence = session.unidentifiedPlayback[utteranceID]
        session.unidentifiedPlayback[utteranceID] = nil
        if not evidence.terminal then session.unidentifiedPlaybackCount = session.unidentifiedPlaybackCount - 1 end
    end
end

local function TrackUnidentifiedPlayback(self, event, utteranceID, status)
    local session = self.CurrentSession
    local buffer = session or self.IdleSplitEvents
    if not buffer then return end
    -- Full does not collect new IDs; only update Split evidence carried into it.
    if session and session.mode ~= self.ReadingModes.SPLIT
        and not buffer.unidentifiedPlayback[utteranceID] then return end
    if type(utteranceID) ~= "number" or utteranceID ~= utteranceID then
        buffer.recoveryEvidenceLost = true
        return
    end
    local owner, conflict = FindSplitOwner(self, utteranceID)
    if conflict or (owner and owner.ambiguous) then
        buffer.recoveryOwnershipAmbiguous = true
    elseif owner or (session and session.mode == self.ReadingModes.FULL and session.utterances[utteranceID]) then
        ClearUnidentifiedPlayback(buffer, utteranceID)
        return
    end
    local terminal = event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" and "finished"
        or (event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" and "failed")
    local now = Now()
    local evidence = buffer.unidentifiedPlayback[utteranceID]
    if not evidence then
        evidence = { utteranceID = utteranceID, event = event, at = now,
            firstEvent = event, firstAt = now, lastEvent = event, lastAt = now,
            terminal = terminal, terminalAt = terminal and now or nil,
            observedSessionID = session and session.id, observedSource = session and session.source }
        if not RetainUnidentifiedPlayback(buffer, utteranceID, evidence) then return end
    elseif terminal and not evidence.terminal then
        evidence.terminal, evidence.terminalAt = terminal, now
        buffer.unidentifiedPlaybackCount = buffer.unidentifiedPlaybackCount - 1
    end
    -- Delayed/duplicate nonterminal events do not reopen a retained terminal ID.
    evidence.lastEvent, evidence.lastAt = event, now
    if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then evidence.startedAt = evidence.startedAt or now end
    if terminal == "failed" and type(status) == "number" then evidence.status = status end
end

function TTS:ReplayEmergencyStopEvents()
    local events = self.EmergencyStopEvents or {}
    self.EmergencyStopEvents = nil
    self.ReplayingEmergencyStop = true
    for _, pending in ipairs(events) do
        Record("emergency-event-replayed", pending.sessionID, nil, nil, pending.utteranceID, pending.event)
        local current = self.CurrentSession
        local owner = FindSplitOwner(self, pending.utteranceID)
        -- Unidentified evidence from an earlier controller epoch cannot claim a replacement.
        if (current and current.id == pending.sessionID) or owner or type(pending.bookmark) == "string" then
            local terminalBefore = owner and owner.utterances[pending.utteranceID].terminal
            self:DispatchPlaybackEvent(pending.event, pending.utteranceID, pending.bookmark)
            if not terminalBefore and (pending.event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED"
                or pending.event == "VOICE_CHAT_TTS_PLAYBACK_FAILED") then
                local identified = FindSplitOwner(self, pending.utteranceID)
                local observation = identified and identified.utterances[pending.utteranceID]
                if observation and observation.terminal then observation.duringStop = true end
                local active = self.CurrentSession
                local unowned = active and active.pendingTerminals[pending.utteranceID]
                if unowned then unowned.duringStop = true end
            end
        else
            Record("emergency-event-unresolved", pending.sessionID, nil, nil, pending.utteranceID,
                "controller-session-ended-or-replaced")
        end
    end
    self.ReplayingEmergencyStop = nil
end

local function EmergencyStop(self, attempt, utteranceID)
    local session = self.CurrentSession
    -- Consume the budget before calling native code, including a failed stop call.
    session.emergencyRecoveryAttempted, session.emergencyRecoveryAt = true, Now()
    session.emergencyRecoveredFrom = attempt.sessionID
    self.EmergencyStopEvents = {}
    Record("emergency-stop-performed", session.id, attempt.sentenceIndex, attempt.id, utteranceID,
        "stale-session=" .. attempt.sessionID .. " no-resubmission")
    local ok = StopPlayback(self, "emergency-stale-bookmark")
    session.emergencyRecoveryResult = ok and "returned" or "error"
    Record("emergency-stop-result", session.id, attempt.sentenceIndex, attempt.id, utteranceID,
        session.emergencyRecoveryResult)
    self:ReplayEmergencyStopEvents()
end

local function ObserveBookmark(self, attempt, utteranceID)
    local observation = attempt.utterances[utteranceID]
    if observation then
        attempt.duplicateEvents = (attempt.duplicateEvents or 0) + 1
        Record("duplicate-bookmark", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
        return observation, false
    end
    local owner, conflict = FindSplitOwner(self, utteranceID)
    if conflict or (owner and owner ~= attempt) then
        attempt.ambiguous = true
        if owner then owner.ambiguous = true; RefreshNativeState(owner) end
        Record("ambiguous-utterance", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
    end
    if attempt.utteranceCount >= MAX_ATTEMPT_UTTERANCES then
        attempt.evidenceOverflow = true
        RefreshNativeState(attempt)
        Record("utterance-bound", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
        return nil, false
    end
    observation = { bookmarkAt = Now() }
    attempt.utterances[utteranceID] = observation
    attempt.utteranceCount = attempt.utteranceCount + 1
    attempt.ownershipConfirmed, attempt.playbackConfirmed = true, true
    attempt.firstBookmarkAt = attempt.firstBookmarkAt or observation.bookmarkAt
    if not attempt.utteranceID then
        attempt.utteranceID = utteranceID
    else
        attempt.additionalUtterance = true
        Record("additional-native-utterance", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
    end
    RefreshNativeState(attempt)
    return observation, true
end

local function ObserveSplitEvent(attempt, event, utteranceID, status)
    local observation = attempt.utterances[utteranceID]
    if not observation then return false end
    if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
        if observation.startedAt then
            attempt.duplicateEvents = (attempt.duplicateEvents or 0) + 1
            Record("duplicate-start", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
        else
            observation.startedAt, attempt.startedEventObserved = Now(), true
        end
        return false
    end
    local terminal = event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" and "finished"
        or (event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" and "failed")
    if not terminal then return false end
    if observation.terminal then
        if observation.terminal == terminal then
            attempt.duplicateEvents = (attempt.duplicateEvents or 0) + 1
        else
            attempt.conflictingEvents = (attempt.conflictingEvents or 0) + 1
        end
        Record(observation.terminal == terminal and "duplicate-terminal" or "conflicting-terminal",
            attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID)
        return false
    end
    observation.terminal, observation.terminalAt = terminal, Now()
    observation.status = type(status) == "number" and status or nil
    if terminal == "finished" then attempt.playbackFinished = true else attempt.playbackFailed = true end
    RefreshNativeState(attempt)
    Record("attempt-terminal", attempt.sessionID, attempt.sentenceIndex, attempt.id, utteranceID, terminal)
    return true
end

local function CompleteSplitSession(self, session)
    session.finished, session.state, session.endReason, session.endedAt = true, "completed", "finished", Now()
    self.CurrentSession = nil
    self.IdleSplitEvents = SplitBuffer()
    CarryRecoveryEvidence(session, self.IdleSplitEvents)
    for _, sentence in ipairs(session.sentenceStates) do
        if sentence.state ~= "completed" and sentence.state ~= "failed" and sentence.state ~= "skipped" then
            SetSentenceState(sentence, "closed-unresolved")
        end
    end
    ArchiveSplitSession(self, session)
    Record("session-completed", session.id)
    NotifySessionEnded(session, "finished")
    ReleaseSplitSession(session)
end

local function ApplySplitTerminal(self, attempt, event, utteranceID, status)
    if not ObserveSplitEvent(attempt, event, utteranceID, status) then return end
    attempt.utterances[utteranceID].duringStop = self.Stopping == true
    local session = self.CurrentSession
    -- Secondary/ambiguous native utterances are evidence, never progression authority.
    if self.Stopping or attempt.ambiguous or utteranceID ~= attempt.utteranceID
        or not session or session.id ~= attempt.sessionID or session.state ~= "active" then return end
    local sentence = session.sentenceStates[attempt.sentenceIndex]
    if sentence.state == "completed" or sentence.state == "failed" then return end
    if event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" then
        sentence.playbackFailed = true
        SetSentenceState(sentence, "failed")
        session.failed = true
        OutLoud:Error("TTS playback failed: session:", session.id, "status:", tostring(status))
        self:Stop("playback-failed")
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" then
        sentence.playbackFinished = true
        SetSentenceState(sentence, "completed")
        session.utterances[utteranceID] = nil
        session.completedTokens[sentence.index], session.completedUtterances[utteranceID] = true, true
        if sentence.index == session.lastChunk then CompleteSplitSession(self, session) end
    end
end

function TTS:OnSplitBookmark(sessionID, chunk, utteranceID, bookmark)
    local session = self.CurrentSession
    local sentence = session and session.id == sessionID and session.sentenceStates
        and session.sentenceStates[chunk] or FindRetiredSentence(self, sessionID, chunk)
    local attempt = sentence and sentence.attempts[1]
    if not attempt or (bookmark and bookmark ~= attempt.bookmark) then
        Record("untracked-bookmark", sessionID, chunk, nil, utteranceID)
        if session and sessionID < session.id then
            Record("emergency-stop-skipped", session.id, chunk, nil, utteranceID,
                "untracked-or-unissued-bookmark stale-session=" .. sessionID)
        end
        return
    end
    local observation, fresh = ObserveBookmark(self, attempt, utteranceID)
    if not observation then return end
    sentence.playbackConfirmed = true
    sentence.utteranceID = attempt.utteranceID
    local current = session and session.id == sessionID and session.state == "active"
    if current then session.ownershipEvidenceObserved = true end
    if not attempt.ambiguous then ClearUnidentifiedPlayback(session or self.IdleSplitEvents, utteranceID) end
    if current and not attempt.ambiguous then session.attemptBindings[utteranceID] = attempt end
    -- Unowned evidence is scoped to the current controller epoch; never carry old buffers forward.
    local buffer = session or self.IdleSplitEvents
    if buffer and not attempt.ambiguous then
        local started = buffer.pendingStarts and buffer.pendingStarts[utteranceID]
        if started then
            observation.startedAt, attempt.startedEventObserved = started.at, true
            buffer.pendingStarts[utteranceID] = nil
        end
        local pending = buffer.pendingTerminals[utteranceID]
        if pending then
            buffer.pendingTerminals[utteranceID] = nil
            ApplySplitTerminal(self, attempt, pending.event, utteranceID, pending.status)
            if pending.duringStop then observation.duringStop = true end
        end
    end
    if not current then
        attempt.staleBookmarkObserved, attempt.staleBookmarkAt = true, Now()
        local eligibility = self:GetSplitRecoveryEligibility(attempt, utteranceID, fresh)
        attempt.recoveryReason = eligibility.reason
        Record("stale-bookmark", sessionID, chunk, attempt.id, utteranceID, eligibility.reason)
        if session then
            if eligibility.emergencyStopEligible then
                EmergencyStop(self, attempt, utteranceID)
            else
                Record("emergency-stop-skipped", session.id, chunk, attempt.id, utteranceID,
                    eligibility.reason .. " stale-session=" .. sessionID)
                if eligibility.reason == "other-unidentified-playback" then
                    for id, evidence in pairs(session.unidentifiedPlayback) do
                        if not evidence.terminal then
                            Record("emergency-stop-blocker", session.id, chunk, attempt.id, id,
                                "state=unresolved first=" .. tostring(evidence.firstEvent or evidence.event)
                                .. " at=" .. tostring(evidence.firstAt or evidence.at)
                                .. " last=" .. tostring(evidence.lastEvent or evidence.event)
                                .. " at=" .. tostring(evidence.lastAt or evidence.at)
                                .. " observed-session=" .. tostring(evidence.observedSessionID or "-")
                                .. " observed-source=" .. tostring(evidence.observedSource or "-")
                                .. " source=" .. session.source)
                        end
                    end
                end
            end
        end
        if not self.Stopping then
            self:GetBookmarkSession(sessionID, chunk, fresh and eligibility.idleStopEligible)
        end
        return
    end
    if self.Stopping or self.CurrentSession ~= session or attempt.ambiguous
        or utteranceID ~= attempt.utteranceID or attempt.ownershipHandled then return end
    attempt.ownershipHandled = true
    if sentence.state ~= "completed" and sentence.state ~= "failed" then
        SetSentenceState(sentence, "playback-confirmed")
        NotifyPlaybackStarted(session)
        if self.CurrentSession ~= session then return end
        if not session.activeToken or chunk > session.activeToken then
            session.activeToken = chunk
            NotifyTextProgress(self, session, chunk, 0)
        end
    end
    -- Includes a recovered intermediate finish. SubmitChunk rechecks callback ownership.
    local submitted = self:SubmitChunk(session, chunk + 1)
    Record("prefetch-decision", sessionID, chunk, attempt.id, utteranceID,
        "next=" .. (chunk + 1) .. " submitted=" .. tostring(submitted == true))
end

local function HandleSplitEvent(self, event, utteranceID, status)
    if type(utteranceID) ~= "number" or utteranceID ~= utteranceID then return false end
    local owner, conflict = FindSplitOwner(self, utteranceID)
    if conflict then
        Record("ambiguous-native-event", nil, nil, nil, utteranceID)
        return true
    end
    if owner then
        if owner.ambiguous then
            Record("unresolved-native-event", owner.sessionID, owner.sentenceIndex, owner.id, utteranceID)
        elseif event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
            ObserveSplitEvent(owner, event, utteranceID)
        else
            ApplySplitTerminal(self, owner, event, utteranceID, status)
        end
        return true
    end
    local session = self.CurrentSession
    local buffer = session and session.mode == self.ReadingModes.SPLIT and session
        or (not session and self.IdleSplitEvents)
    if not buffer then return false end
    if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
        RememberStart(buffer, utteranceID)
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" or event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" then
        RememberTerminal(buffer, event, utteranceID, status)
    end
    Record("awaiting-ownership", session and session.id, nil, nil, utteranceID)
    return true
end

RememberTerminal = function(session, event, utteranceID, status)
    if type(utteranceID) ~= "number" or utteranceID ~= utteranceID
        or (session.completedUtterances and session.completedUtterances[utteranceID]) then
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

    if chunk then
        self:OnSplitBookmark(sessionID, chunk, utteranceID, bookmark)
        return
    end

    if self.CurrentSession and sessionID < self.CurrentSession.id then
        Record("emergency-stop-skipped", self.CurrentSession.id, token, nil, utteranceID,
            "full-mode-source-preserved stale-session=" .. sessionID)
    end
    local session = self:GetBookmarkSession(sessionID, chunk or token)
    if not session or session.mode ~= self.ReadingModes.FULL then return end

    if token ~= "WHOLE" then return end

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
        return
    end

    OutLoud:Debug("TTS playback identified: session:", sessionID, "chunk:", token, "utterance:", utteranceID)
    NotifyPlaybackStarted(session)
    if self.CurrentSession ~= session then return end
    if not session.activeToken then
        session.activeToken = token
        NotifyTextProgress(self, session, token, 0)
    end
end

function TTS:OnEvent(event, utteranceID, bookmark)
    if event:match("^VOICE_CHAT_TTS_PLAYBACK_") then
        local sid, chunk, attemptID
        if type(bookmark) == "string" then sid, chunk = bookmark:match("^OUTLOUD:SPEECH:(%d+):(%w+)$") end
        if type(utteranceID) == "number" and not sid then
            local owner = FindSplitOwner(self, utteranceID)
            if owner then sid, chunk, attemptID = owner.sessionID, owner.sentenceIndex, owner.id end
        end
        Record(event:gsub("VOICE_CHAT_TTS_PLAYBACK_", "event-"), tonumber(sid), chunk, attemptID,
            type(utteranceID) == "number" and utteranceID or nil,
            self.Stopping and "during-stop" or nil)
        if self.EmergencyStopEvents then
            local session = self.CurrentSession
            if #self.EmergencyStopEvents >= MAX_PENDING_TERMINALS then
                if session then session.recoveryEvidenceLost = true end
                Record("emergency-event-overflow", session and session.id, nil, nil, utteranceID)
            else
                -- Store only native IDs/status and ownership markup, never arbitrary bookmark text.
                local ownedMark = type(bookmark) == "string" and
                    (bookmark:match("^OUTLOUD:SPEECH:%d+:%d+$") or bookmark:match("^OUTLOUD:SPEECH:%d+:WHOLE$")) or nil
                self.EmergencyStopEvents[#self.EmergencyStopEvents + 1] = {
                    event = event, utteranceID = utteranceID, sessionID = session and session.id,
                    bookmark = ownedMark or (type(bookmark) == "number" and bookmark or nil),
                }
                Record("emergency-event-deferred", session and session.id, nil, nil, utteranceID, event)
            end
            return
        end
    end
    self:DispatchPlaybackEvent(event, utteranceID, bookmark)
end

function TTS:DispatchPlaybackEvent(event, utteranceID, bookmark)
    if event:match("^VOICE_CHAT_TTS_PLAYBACK_") then TrackUnidentifiedPlayback(self, event, utteranceID, bookmark) end
    if event == "PLAYER_LOGOUT" then
        -- Also emitted when /reload tears down the current UI.
        self:Stop("logout")
        return
    end

    if event == "VOICE_CHAT_TTS_PLAYBACK_BOOKMARK" then
        if self.Stopping and type(bookmark) == "string" and bookmark:match(":WHOLE$") then return end
        self:OnBookmark(utteranceID, bookmark)
        return
    end

    if HandleSplitEvent(self, event, utteranceID, bookmark) then return end
    if self.Stopping then return end

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
            self:Stop("playback-failed")
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

        if token == "WHOLE" then
            session.finished = true
            session.state, session.endReason, session.endedAt = "completed", "finished", Now()
            self.CurrentSession = nil
            if self.SplitHistory and #self.SplitHistory > 0 then
                self.IdleSplitEvents = SplitBuffer()
                CarryRecoveryEvidence(session, self.IdleSplitEvents)
            end
            Record("session-completed", session.id)
            OutLoud:Debug("TTS session completed:", session.id)
            NotifySessionEnded(session, "finished")
        end
    end
end
