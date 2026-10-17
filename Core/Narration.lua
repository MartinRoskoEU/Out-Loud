local AddonName, OutLoud = ...

local Narration = {}
OutLoud.Narration = Narration

local function Record(event, request, detail)
    if not OutLoud.DebugEnabled then return end
    local recorder = OutLoud.TTSDiagnostics
    if recorder and request then
        pcall(recorder.Record, recorder, event, nil, nil, nil, nil,
            "request=" .. request.id .. " source=" .. request.source .. " " .. (detail or ""))
    end
end

local function NotifyRequestEnded(request, reason)
    if not request or request.ended then return end
    request.ended = true
    local callback = request.onRequestEnded
    request.onRequestEnded = nil
    if type(callback) == "function" then
        local ok, message = pcall(callback, reason, request.id)
        if not ok then OutLoud:Error("Narration request-end callback failed:", tostring(message)) end
    end
end

local function CancelRequest(self, reason)
    local request = self.Narration
    self.Narration = nil
    Record("narration-cancelled", request, reason or "manual")
    NotifyRequestEnded(request, reason or "manual")
end

local function OwnsPresentation(self, request, transition)
    local talkingHead = OutLoud.UI.TalkingHead
    return self.Narration == request and talkingHead.Transition == transition
        and (talkingHead.State == "Opening" or talkingHead.State == "Opened")
        and talkingHead.Frame:IsShown()
end

function Narration:CancelAutoNarration(owner)
    local request = owner.PendingAutoNarration
    owner.PendingAutoNarration = nil
    if request and request.timer then
        request.timer:Cancel()
        request.timer = nil
    end
end

-- Shared activation delay; speech still submits immediately at opening start.
-- Each integration retains its source-specific readiness/identity predicate.
function Narration:ScheduleAutoNarration(owner, request, isCurrent, start)
    self:CancelAutoNarration(owner)
    if not OutLoud.Database:GetAutoNarrateQuests() then return end
    local delay = OutLoud.Database:GetAutoNarrationDelay()
    if delay == 0 then
        if isCurrent(request) then start() end
        return
    end
    owner.PendingAutoNarration = request
    request.timer = C_Timer.NewTimer(delay, function()
        if owner.PendingAutoNarration ~= request then return end
        request.timer = nil
        owner.PendingAutoNarration = nil
        if OutLoud.Database:GetAutoNarrateQuests() and isCurrent(request) then start() end
    end)
end

function Narration:Initialize()
    if self.Initialized then return end
    -- Stop must also cancel an opening/pending request with no TTS session yet.
    OutLoud.TTS.onStopRequested = function(reason, _, diagnosticTrigger)
        if self.InternalStop or (self.Submitting and self.Submitting == self.Narration and reason == "replaced") then return end
        if not self.Narration then return end
        -- The caller's Stop will do native cancellation after this notification.
        self.InternalStop = true
        local ok, message = pcall(self.Stop, self, reason, diagnosticTrigger or "TTS stop")
        self.InternalStop = nil
        if not ok then OutLoud:Error("Narration stop failed:", tostring(message)) end
    end
    self.Initialized = true
end

function Narration:OnClosing(reason, diagnosticTrigger)
    if reason ~= "replaced" then
        -- Also handle direct TalkingHead:Hide(), without reopening its request.
        CancelRequest(self, reason)
    end
    if self.InternalStop then return end
    self.InternalStop = true
    OutLoud.TTS:Stop(reason, nil, diagnosticTrigger)
    self.InternalStop = nil
end

function Narration:Stop(reason, diagnosticTrigger)
    CancelRequest(self, reason)
    -- A request-end callback may already have installed newer narration.
    if self.Narration then return end
    local talkingHead = OutLoud.UI.TalkingHead
    if talkingHead.State == "Closed" or talkingHead.State == "Closing" then
        self:OnClosing(reason, diagnosticTrigger)
    else
        talkingHead:Hide(reason, diagnosticTrigger)
    end
end

-- A source close only owns its delay and its accepted request, including one
-- waiting for the previous presentation to finish closing. Reuse normal STOP.
function Narration:StopSource(owner, reason)
    if not owner then return end
    self:CancelAutoNarration(owner)
    local request = self.Narration
    if request and request.owner == owner then
        self:Stop(reason, request.source)
    end
end

function Narration:OnClosed()
    local talkingHead = OutLoud.UI.TalkingHead
    local request = self.Narration
    if not request or request.submitted or talkingHead.State ~= "Closed" then return end
    local ok, reason = talkingHead:Show(request.speaker, request.text, function(transition)
        if not OwnsPresentation(self, request, transition) then return end
        Record("narration-opening-started", request)
        self:Submit(request, transition)
    end)
    if not ok and self.Narration == request then
        OutLoud:Error("Read stopped: Talking Head could not open:", tostring(reason))
        self:Stop(reason)
    end
end

function Narration:Submit(request, transition)
    local talkingHead = OutLoud.UI.TalkingHead
    if not OwnsPresentation(self, request, transition) or request.submitted then return end
    request.submitted = true
    Record("narration-submitting", request)
    local submitting = self.Submitting
    self.Submitting = request
    local ok, reason = OutLoud.TTS:Speak(request.text, request.voiceID, function(endReason)
        if not OwnsPresentation(self, request, transition) then return end
        self.Narration = nil
        talkingHead:FinishTextPlayback(endReason)
        talkingHead:Hide(endReason)
        NotifyRequestEnded(request, endReason)
    end, function()
        if OwnsPresentation(self, request, transition) then talkingHead:SetLoading(false) end
    end, function(spokenText, chunk, offset)
        if OwnsPresentation(self, request, transition) then talkingHead:OnTextProgress(spokenText, chunk, offset) end
    end, request.source)
    self.Submitting = submitting
    if not ok then
        OutLoud:Error("Read stopped: TTS rejected the request:", tostring(reason))
        if self.Narration == request then self:Stop(reason) end
    end
end

-- Capture once; navigation cannot change an accepted narration's content.
-- Returns acceptance; a replacement may wait for the current presentation to close.
function Narration:Speak(unit, text, voiceID, displayTitle, diagnosticSource, modelFileID, onRequestEnded, sourceOwner)
    self:Initialize()
    if not unit or not UnitExists(unit) then return false, "unit-unavailable" end
    local speaker = {
        unit = unit, name = UnitName(unit) or "Unknown", faction = UnitFactionGroup(unit),
        modelFileID = modelFileID,
    }
    if displayTitle ~= nil then
        speaker.name = type(displayTitle) == "string" and displayTitle:find("%S") and displayTitle or "Quest"
    end
    self.RequestID = (self.RequestID or 0) + 1
    local request = {
        id = self.RequestID, speaker = speaker, text = text, voiceID = voiceID,
        source = type(diagnosticSource) == "string" and diagnosticSource or "Narration",
        onRequestEnded = onRequestEnded, owner = sourceOwner,
    }
    -- Change ownership before native STOP can synchronously notify the outgoing session.
    local previous = self.Narration
    self.Narration = request
    Record("narration-cancelled", previous, "replaced")
    NotifyRequestEnded(previous, "replaced")
    if self.Narration ~= request then return true end
    Record("narration-requested", request, "unit=" .. unit .. " model=" .. tostring(modelFileID or "-"))
    local talkingHead = OutLoud.UI.TalkingHead
    self:OnClosing("replaced", "replacement:" .. request.source)
    if self.Narration ~= request then return true end
    talkingHead:Initialize()
    if self.Narration ~= request then return true end
    if talkingHead.State == "Closed" then
        self:OnClosed()
    else
        talkingHead:Hide("replaced", "replacement:" .. request.source)
    end
    return true
end
