local AddonName, OutLoud = ...

local Narration = {}
OutLoud.Narration = Narration

-- Shared presentation callbacks; TTS continues to own speech sessions/bookmarks.
function Narration:Speak(unit, text, voiceID, displayTitle)
    local talkingHead = OutLoud.UI.TalkingHead
    -- Replace ownership before Speak cancels the previous session.
    local narration = {}
    self.Narration = narration
    OutLoud:Debug("Showing Talking Head.")
    talkingHead:Show(unit, text, displayTitle)
    talkingHead:SetLoading(true)
    OutLoud:Debug("Talking Head visible:", talkingHead.Frame and talkingHead.Frame:IsShown() or false)

    OutLoud:Debug("Submitting speech. Reading mode:", OutLoud.Database:GetReadingMode())
    local ok, reason = OutLoud.TTS:Speak(text, voiceID, function(endReason)
        if self.Narration == narration then
            self.Narration = nil
            OutLoud:Debug("Narration ended:", endReason, "Hiding Talking Head.")
            talkingHead:FinishTextPlayback(endReason)
            talkingHead:Hide()
        end
    end, function()
        if self.Narration == narration then
            talkingHead:SetLoading(false)
        end
    end, function(spokenText, chunk, offset)
        if self.Narration == narration then
            talkingHead:OnTextProgress(spokenText, chunk, offset)
        end
    end)
    if not ok then
        OutLoud:Error("Read stopped: TTS rejected the request:", tostring(reason))
        if self.Narration == narration then
            self.Narration = nil
            talkingHead:Hide()
        end
    elseif self.Narration == narration then
        OutLoud:Debug("TTS submission accepted; waiting for playback events.")
    else
        OutLoud:Debug("TTS request ended during submission.")
    end

    return ok, reason
end
