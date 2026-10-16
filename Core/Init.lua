local AddonName, OutLoud = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, loadedAddonName)
    if event ~= "ADDON_LOADED" or loadedAddonName ~= AddonName then
        return
    end

    local compatible, reason = OutLoud.Client:CheckCompatibility()
    if not compatible then
        OutLoud:Error(reason)
        frame:UnregisterEvent("ADDON_LOADED")
        frame:SetScript("OnEvent", nil)
        return
    end

    OutLoud:RegisterSlashCommands()
    OutLoud.Database:Initialize()
    OutLoud.VoiceSelection:Initialize()
    OutLoud.UI.SettingsPage:Initialize()
    OutLoud.UI.TalkingHead:Initialize()
    OutLoud.UI.QuestIntegration:Initialize()
    OutLoud.UI.QuestLogIntegration:Initialize()
    OutLoud.UI.GossipIntegration:Initialize()
    OutLoud.UI.ItemTextIntegration:Initialize()

    OutLoud.Loaded = true
    frame:UnregisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", nil)
end)
