local AddonName, OutLoud = ...

local Client = OutLoud.Client

function Client:CheckCompatibility()
    -- Preserve the established Forever initialization path.
    if self.ID ~= "Retail" then return true end

    local required = {
        { "C_VoiceChat.GetTtsVoices", C_VoiceChat and C_VoiceChat.GetTtsVoices },
        { "C_VoiceChat.SpeakText", C_VoiceChat and C_VoiceChat.SpeakText },
        { "C_VoiceChat.StopSpeakingText", C_VoiceChat and C_VoiceChat.StopSpeakingText },
        { "C_TTSSettings.SetSetting", C_TTSSettings and C_TTSSettings.SetSetting },
        { "C_Texture.GetAtlasExists", C_Texture and C_Texture.GetAtlasExists },
        { "Settings.RegisterCanvasLayoutCategory", Settings and Settings.RegisterCanvasLayoutCategory },
        { "Settings.RegisterAddOnCategory", Settings and Settings.RegisterAddOnCategory },
    }
    for _, api in ipairs(required) do
        if type(api[2]) ~= "function" then
            return false, "Retail API unavailable: " .. api[1]
        end
    end
    if not Enum or not Enum.TtsBoolSetting
        or Enum.TtsBoolSetting.PlaySoundSeparatingChatLineBreaks == nil then
        return false, "Retail TTS separator setting unavailable"
    end
    return true
end
