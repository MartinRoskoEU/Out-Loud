-- Isolated client catalogs, resolver/fallback forwarding, and saved-value logic.
-- No native UI, model readiness, events, audio, or WoW persistence are simulated.
local LoadFile = assert(loadfile, "Run from the addon root using Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end

local environment = setmetatable({}, { __index = _G })
environment._G = environment
local sex, race, modelID = 2, "Human", 1000764
environment.UnitExists = function() return true end
environment.UnitName = function() return "Supplied speaker" end
environment.UnitSex = function(unit) return unit == "player" and 2 or sex end
environment.UnitRace = function() return race, race, 1 end
environment.OutLoudDB = { voices = { HUMAN = { [2] = 7 } }, speechRate = 3 }
environment.OutLoudRetailDB = { voices = { HUMAN = { [2] = 8 }, RETIRED = { [3] = 9 } } }
local foreverDB, retailDB = environment.OutLoudDB, environment.OutLoudRetailDB
local function Load(path, addon)
    local chunk = assert(LoadFile(path))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
end

for _, client in ipairs({ "Forever", "Retail" }) do
    local addon = { TTS = { GetVoices = function()
        return { { voiceID = 7 }, { voiceID = 8 }, { voiceID = 9 } }
    end } }
    for _, path in ipairs({ "Core/Namespace.lua", "Clients/" .. client .. "/Config.lua",
        "Core/Client.lua", "Clients/" .. client .. "/VoiceMappings.lua",
        "Core/VoiceSelection.lua", "Core/Database.lua", "UI/QuestIntegration.lua", "UI/GossipIntegration.lua" }) do
        Load(path, addon)
    end
    local selection = addon.VoiceSelection
    local mappings = addon.VoiceMappings
    Equal(#selection:GetFamilies(), client == "Forever" and 12 or 27, client .. " families")
    local count = 0
    for id, family in pairs(mappings.Models) do
        count = count + 1
        Equal(type(id), "number")
        Equal(type(family), "string", "No model gender data")
        Equal(mappings.Families[family], family, "Mapped family is in catalog")
    end
    Equal(count, client == "Forever" and 26 or 60, client .. " models")
    addon.Database:Initialize()
    Equal(addon.DB, client == "Forever" and foreverDB or retailDB, "Correct saved table")
    Equal(addon.Database:GetVoice("HUMAN", 2), client == "Forever" and 7 or 8)
    Equal(environment.OutLoudDB, foreverDB, "Forever table is never replaced")
    Equal(environment.OutLoudRetailDB, retailDB, "Retail table is never replaced")
    Equal(retailDB.voices.RETIRED[3], 9, "Unavailable family values retained")
    local model = { GetModelFileID = function() return modelID end }
    sex, race = 2, "Human"
    for _, id in ipairs({ 1000764, 1011653 }) do
        modelID = id
        local voice, info = selection:Resolve("questnpc", model)
        Equal(voice, client == "Forever" and 7 or nil, "Conflicting IDs excluded in Retail")
        if client == "Retail" then Equal(info.reason, "unknown-model") end
    end
    if client == "Retail" then
        Equal(mappings.Families.HUMAN, "HUMAN", "Human available without a model")
        Equal(mappings.Families.GILNEAN, "GILNEAN", "Gilnean available without a model")
        for _, family in pairs(mappings.Models) do assert(family ~= "HUMAN" and family ~= "GILNEAN") end
        Equal(selection:ResolvePlayer(), 8, "Player Human lookup is independent of NPC models")
        race = "Vulpera"
        addon.Database:SetVoice("VULPERA", 2, 9)
        Equal(selection:ResolvePlayer(), 9, "Retail playable family")
        race = "Dracthyr"
        local voice, info = selection:ResolvePlayer()
        Equal(voice, nil, "No speculative Dracthyr to Visage alias")
        Equal(info.reason, "unknown-player-race")
        race = "Human"
    end

    -- Exercise the existing production QuestFrame fallback with scalar inputs;
    -- substitute only text acquisition, model ID reading, and speech forwarding.
    local quest, captured = addon.UI.QuestIntegration
    quest.GetCurrentText = function() return "Supplied dialogue.", nil, "GetQuestText" end
    quest.Model = model
    addon.NPCInspection = { LoadUnit = function() return model end }
    addon.Narration = {
        CancelAutoNarration = function() end,
        Speak = function(_, unit, text, voice) captured = { unit, text, voice }; return true end,
    }
    modelID = client == "Retail" and 1000764 or 999999
    quest:SpeakCurrentText()
    Equal(captured[1], "player", "Unknown NPC uses existing Player Narrator fallback")
    Equal(captured[2], "Supplied dialogue.")
    Equal(captured[3], client == "Forever" and 7 or 8)
    modelID, sex = 959310, 1
    local voice, info = selection:Resolve("questnpc", model)
    Equal(voice, nil)
    Equal(info.reason, "unknown-sex", "Unknown gender remains unresolved")
    quest:SpeakCurrentText()
    Equal(captured[1], "player", "Unknown NPC gender uses existing Player Narrator fallback")
    Equal(captured[3], client == "Forever" and 7 or 8)
    modelID, sex = 0, 2
    quest:SpeakCurrentText()
    Equal(captured[1], "player", "An inspection result that is not ready keeps the existing player fallback")
    Equal(captured[3], client == "Forever" and 7 or 8)
    local gossip = addon.UI.GossipIntegration
    gossip.GetCurrentText = quest.GetCurrentText
    for _, inputs in ipairs({ { 999999, 2 }, { 959310, 1 }, { 0, 2 } }) do
        modelID, sex = inputs[1], inputs[2]
        gossip:SpeakCurrentText()
        Equal(captured[1], "player", "Gossip preserves unknown-model/sex fallback")
        Equal(captured[3], client == "Forever" and 7 or 8)
    end
    Equal(foreverDB.speechRate, 3, "Retail never changes Forever preferences")

    if client == "Retail" then
        local ok, reason = addon.Client:CheckCompatibility()
        Equal(ok, false, "Missing Retail API is rejected explicitly")
        Equal(reason, "Retail API unavailable: C_VoiceChat.GetTtsVoices")
        local function APIInput() error("Compatibility predicates must not call native APIs") end
        environment.C_VoiceChat = { GetTtsVoices = APIInput, SpeakText = APIInput, StopSpeakingText = APIInput }
        environment.C_TTSSettings = { SetSetting = APIInput }
        environment.C_Texture = { GetAtlasExists = APIInput }
        environment.Settings = { RegisterCanvasLayoutCategory = APIInput, RegisterAddOnCategory = APIInput }
        environment.Enum = { TtsBoolSetting = { PlaySoundSeparatingChatLineBreaks = 0 } }
        Equal(addon.Client:CheckCompatibility(), true, "Available API predicates accept setting zero")
        environment.C_Texture.GetAtlasExists = nil
        ok, reason = addon.Client:CheckCompatibility()
        Equal(ok, false)
        Equal(reason, "Retail API unavailable: C_Texture.GetAtlasExists")
        environment.C_Texture.GetAtlasExists = APIInput
        environment.Enum.TtsBoolSetting = nil
        ok, reason = addon.Client:CheckCompatibility()
        Equal(ok, false)
        Equal(reason, "Retail TTS separator setting unavailable")
        environment.OutLoudRetailDB = nil
        addon.Database.Initialized = false
        addon.Database:Initialize()
        assert(addon.DB ~= foreverDB and addon.DB ~= retailDB, "A new Retail profile must be independent")
        Equal(addon.Database:GetVoice("HUMAN", 2), nil, "Retail never imports Forever voice IDs")
        Equal(environment.OutLoudDB, foreverDB)
    end
end

print("PASS: dual-client catalog, saved-value isolation, and fallback forwarding; in-game behavior unverified")
