local AddonName, OutLoud = ...

-- Temporary observer: remove this file and its TOC entry after manual testing.
-- No controller decision depends on this recorder or report.
local Diagnostics = { limit = 200, entries = {}, count = 0, nextEntry = 1, sequence = 0 }
OutLoud.TTSDiagnostics = Diagnostics

function Diagnostics:Record(event, sessionID, chunk, attemptID, utteranceID, detail)
    self.sequence = self.sequence + 1
    self.entries[self.nextEntry] = {
        sequence = self.sequence, at = GetTime and GetTime() or 0,
        event = event, sessionID = sessionID, chunk = chunk,
        attemptID = attemptID, utteranceID = utteranceID, detail = detail,
    }
    self.nextEntry = self.nextEntry % self.limit + 1
    self.count = math.min(self.count + 1, self.limit)
end

local function Value(value)
    return value == nil and "-" or tostring(value)
end

local function AddSentence(lines, sentence)
    for _, attempt in ipairs(sentence.attempts) do
        local native = {}
        for utteranceID, observation in pairs(attempt.utterances) do
            native[#native + 1] = Value(utteranceID) .. ":"
                .. (observation.terminal or "bookmark")
                .. (observation.startedAt and "+STARTED" or "")
                .. (observation.duringStop and "+during-stop" or "")
                .. (observation.status and ":status=" .. observation.status or "")
        end
        table.sort(native)
        lines[#lines + 1] = string.format(
            "  s=%s chunk=%s attempt=%s logical=%s cancelled=%s submit=%s at=%.3f bookmark-at=%s native=%s unresolved=%s utterances=[%s] stops=%s last-stop=%s/%s at=%s recovery=%s",
            Value(sentence.sessionID), Value(sentence.index), Value(attempt.id), sentence.state,
            Value(sentence.logicalCancelled == true), attempt.submissionState, attempt.submittedAt,
            Value(attempt.firstBookmarkAt), attempt.nativeState,
            Value(attempt.unresolved), table.concat(native, ","), Value(attempt.stopCount),
            Value(attempt.lastStopID), Value(attempt.lastStopResult), Value(attempt.lastStopAt), Value(attempt.recoveryReason))
    end
end

local function AddUnidentified(lines, buffer)
    if not buffer then return end
    lines[#lines + 1] = "Unidentified playback: unresolved=" .. Value(buffer.unidentifiedPlaybackCount)
        .. " evidence-lost=" .. Value(buffer.recoveryEvidenceLost == true)
        .. " ambiguous=" .. Value(buffer.recoveryOwnershipAmbiguous == true)
    local ids = {}
    for utteranceID in pairs(buffer.unidentifiedPlayback or {}) do ids[#ids + 1] = utteranceID end
    table.sort(ids)
    for _, utteranceID in ipairs(ids) do
        local evidence = buffer.unidentifiedPlayback[utteranceID]
        lines[#lines + 1] = "  utterance=" .. Value(utteranceID)
            .. " first=" .. Value(evidence.firstEvent or evidence.event) .. " at=" .. Value(evidence.firstAt or evidence.at)
            .. " last=" .. Value(evidence.lastEvent or evidence.event) .. " at=" .. Value(evidence.lastAt or evidence.at)
            .. " terminal=" .. Value(evidence.terminal) .. " at=" .. Value(evidence.terminalAt)
            .. " status=" .. Value(evidence.status)
            .. " observed-session=" .. Value(evidence.observedSessionID)
            .. " observed-source=" .. Value(evidence.observedSource)
    end
end

function Diagnostics:GetReport()
    local lines = {
        "Out Loud TTS lifecycle report",
        "Times use GetTime() seconds. Experimental Emergency STOP: once per newer unowned Split session; native queue removal/survival unconfirmed; no resubmission.",
    }
    local tts = OutLoud.TTS
    local session = tts and tts.CurrentSession
    if session then
        lines[#lines + 1] = string.format("Current: s=%s state=%s created=%.3f source=%s",
            session.id, session.state, session.createdAt, Value(session.source))
        if session.sentenceStates then
            lines[#lines + 1] = string.format("Recovery: attempted=%s result=%s from=%s unidentified=%s evidence-lost=%s",
                Value(session.emergencyRecoveryAttempted == true), Value(session.emergencyRecoveryResult),
                Value(session.emergencyRecoveredFrom), Value(session.unidentifiedPlaybackCount),
                Value(session.recoveryEvidenceLost == true or session.recoveryOwnershipAmbiguous == true))
        end
        if session.sentenceStates then
            local counts, submitted = {}, {}
            for _, sentence in ipairs(session.sentenceStates) do
                counts[sentence.state] = (counts[sentence.state] or 0) + 1
                if #sentence.attempts > 0 then submitted[#submitted + 1] = sentence.index end
            end
            local states = {}
            for state, count in pairs(counts) do states[#states + 1] = state .. "=" .. count end
            table.sort(states)
            lines[#lines + 1] = "Sentences: " .. table.concat(states, " ")
            -- Bound the snapshot too; planned text/sentences never appear in the report.
            for index = math.max(1, #submitted - 127), #submitted do
                AddSentence(lines, session.sentenceStates[submitted[index]])
            end
        end
    else
        lines[#lines + 1] = "Current: idle"
    end
    AddUnidentified(lines, session or (tts and tts.IdleSplitEvents))
    lines[#lines + 1] = "Retired Split metadata (maximum 8 sessions / 128 attempts):"
    for _, retired in ipairs(tts and tts.SplitHistory or {}) do
        lines[#lines + 1] = string.format("s=%s state=%s reason=%s replacement=%s ended=%.3f sentences=%s retained=%s source=%s trigger=%s",
            retired.id, retired.state, Value(retired.stopReason or retired.endReason), Value(retired.replacedBy),
            retired.endedAt, retired.sentenceCount, #retired.order, Value(retired.source), Value(retired.stopTrigger))
        if retired.emergencyRecoveryAttempted then
            lines[#lines + 1] = "  emergency-stop=" .. Value(retired.emergencyRecoveryResult)
                .. " from=" .. Value(retired.emergencyRecoveredFrom) .. " at=" .. Value(retired.emergencyRecoveryAt)
        end
        for _, index in ipairs(retired.order) do AddSentence(lines, retired.sentenceStates[index]) end
    end
    lines[#lines + 1] = string.format("Events: latest %d of %d (limit %d)", self.count, self.sequence, self.limit)
    local first = self.count == self.limit and self.nextEntry or 1
    for offset = 0, self.count - 1 do
        local entry = self.entries[(first + offset - 1) % self.limit + 1]
        lines[#lines + 1] = string.format("#%d %.3f %s s=%s chunk=%s attempt=%s utterance=%s%s",
            entry.sequence, entry.at, entry.event, Value(entry.sessionID), Value(entry.chunk),
            Value(entry.attemptID), Value(entry.utteranceID), entry.detail and " " .. entry.detail or "")
    end
    return table.concat(lines, "\n")
end

function OutLoud.GetTTSReport()
    return Diagnostics:GetReport()
end
