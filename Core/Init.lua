local AddonName, OutLoud = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, loadedAddonName)
    if event ~= "ADDON_LOADED" or loadedAddonName ~= AddonName then
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
