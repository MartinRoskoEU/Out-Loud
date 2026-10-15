-- Execute only with explicit user approval, from the addon root with Lua 5.1: lua Tests/VoiceSelection.lua
-- Isolated production lookup/resolver and saved-value logic, using supplied scalar inputs.
-- No frames, templates, event delivery, model loading, native voices, or WoW persistence are verified.
local environment = setmetatable({}, { __index = _G })
environment._G = environment
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local sex, exists = 2, true
function environment.UnitSex() return sex end
function environment.UnitExists() return exists end
function environment.UnitName() return "Test NPC" end
local availableVoices = {}
for id = 0, 60 do
    availableVoices[#availableVoices + 1] = { voiceID = id, name = "Voice " .. id }
end
local addon = {
    TTS = {
        GetVoices = function() return availableVoices end,
    },
}
local function Load(path)
    local chunk = assert(LoadFile(path))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
end
for _, path in ipairs({ "Core/Namespace.lua", "Data/VoiceMappings.lua",
    "Core/VoiceSelection.lua", "Core/Database.lua" }) do
    Load(path)
end

local selection = addon.VoiceSelection
local exportedMappings = addon.VoiceMappings
local exportedFamilies = {}
local exportedCount = 0
for _, family in pairs(exportedMappings.Families) do
    if not exportedFamilies[family] then
        exportedFamilies[family] = true
        exportedCount = exportedCount + 1
    end
end
Equal(#selection:GetFamilies(), exportedCount, "Generated family catalog")
for fileDataID, family in pairs(exportedMappings.Models) do
    Equal(type(family), "string", "Generated model maps directly to a family")
    assert(exportedFamilies[family], "Model family is missing from the catalog")
    Equal(selection:GetFamily(fileDataID), family, "Generated model lookup")
end

local savedVariables = {
    voices = {
        UNDEAD = { [2] = 50, [3] = 41 },
        SKYBORNE = { [2] = 10, [3] = 11 },
        HUMAN = { [2] = 0, [3] = 13 },
    },
    readingMode = "retired",
}
environment.OutLoudDB = savedVariables

addon.Database:Initialize()

Equal(addon.Database:GetVoice("UNDEAD", 2), 50, "Keep saved male assignment")
Equal(addon.Database:GetVoice("UNDEAD", 3), 41, "Keep saved female assignment")
Equal(savedVariables.readingMode, nil, "Remove the obsolete preference without resetting voice assignments")
Equal(addon.Database:GetVoiceMode(), "raceGender", "Existing users default to Multiple Voices")
Equal(addon.Database:GetSingleVoice(), nil, "No arbitrary narrator voice is chosen")

Equal(addon.Database:GetAutoNarrationDelay(), 2, "Automatic delay default")

Equal(addon.Database:GetSpeechRate(), 0, "Existing SavedVariables receive the normal rate")

local humanVoices = savedVariables.voices.HUMAN
savedVariables.voices.HUMAN = false
Equal(addon.Database:GetVoice("HUMAN", 2), nil, "Malformed family settings are unresolved")
addon.Database:SetVoice("HUMAN", 2, 0)
Equal(addon.Database:GetVoice("HUMAN", 2), 0, "The setter can repair malformed family settings")
savedVariables.voices.HUMAN = humanVoices

local modelID = 959310
local model = { GetModelFileID = function() return modelID end }
local function Resolve(id, unitSex, family, gender, voice)
    modelID, sex = id, unitSex
    local voiceID, info = selection:Resolve("questnpc", model)
    Equal(info.name, "Test NPC", "NPC name")
    Equal(info.modelFileID, id, "Model ID")
    Equal(info.family, family, "Family")
    Equal(info.sex, unitSex, "Runtime sex")
    Equal(info.gender, gender, "Gender")
    Equal(voiceID, voice, "Configured voice")
    Equal(info.reason, nil, "Successful lookup")
end

Resolve(959310, 2, "UNDEAD", "MALE", 50)
Resolve(997378, 3, "UNDEAD", "FEMALE", 41)
Resolve(7478487, 2, "SKYBORNE", "MALE", 10)
Resolve(7478494, 3, "SKYBORNE", "FEMALE", 11)
Resolve(1000764, 2, "HUMAN", "MALE", 0)
Resolve(1011653, 3, "HUMAN", "FEMALE", 13)

-- Supplied mappings isolate shared-family lookup from the generated catalog.
addon.VoiceMappings = {
    Families = {
        HUMAN = "HUMAN", UNDEAD = "UNDEAD", SKYBORNE = "SKYBORNE",
    },
    Models = {
        [959310] = "UNDEAD", [7478487] = "SKYBORNE",
        [7478494] = "SKYBORNE", [100] = "HUMAN", [101] = "HUMAN",
    },
}

Resolve(959310, 2, "UNDEAD", "MALE", 50)
Resolve(959310, 3, "UNDEAD", "FEMALE", 41)
Resolve(7478487, 2, "SKYBORNE", "MALE", 10)
Resolve(7478494, 3, "SKYBORNE", "FEMALE", 11)
-- Deliberately swap sex on the same Skyborne model IDs.
Resolve(7478487, 3, "SKYBORNE", "FEMALE", 11)
Resolve(7478494, 2, "SKYBORNE", "MALE", 10)
Resolve(100, 2, "HUMAN", "MALE", 0)
Resolve(101, 2, "HUMAN", "MALE", 0)
Resolve(100, 3, "HUMAN", "FEMALE", 13)
Resolve(101, 3, "HUMAN", "FEMALE", 13)

local function Unresolved(id, unitSex, reason)
    modelID, sex = id, unitSex
    local voice, info = selection:Resolve("questnpc", model)
    Equal(voice, nil, "Unresolved voice")
    Equal(info.reason, reason, "Unresolved reason")
    if reason == "unknown-sex" then Equal(info.gender, nil, "No invented gender") end
end
for _, unitSex in ipairs({ 1, 0, 4, "2" }) do
    Unresolved(959310, unitSex, "unknown-sex")
end
Unresolved(959310, nil, "unknown-sex")
Unresolved(999999, 2, "unknown-model")
Unresolved(0, 2, "model-unavailable")
Unresolved(nil, 2, "model-unavailable")
exists = false
Unresolved(959310, 2, "unit-unavailable")
exists = true

addon.Database:SetVoice("UNDEAD", 3, nil)
addon.Database.Initialized = false
addon.Database:Initialize()
Equal(addon.Database:GetVoice("UNDEAD", 3), nil, "Cleared voice remains unset after reinitialization")
Unresolved(959310, 3, "voice-not-set")

local voices = savedVariables.voices
local skyborneMale, skyborneFemale = voices.SKYBORNE[2], voices.SKYBORNE[3]

addon.Database:SetVoiceMode("single")
addon.Database:SetSingleVoice(20)

-- Single mode has no dependency on model mappings, race tokens, or runtime sex.
modelID = 999999
local originalUnitSex = environment.UnitSex
environment.UnitSex = function() error("Single Voice must not require gender") end
environment.UnitRace = function() error("Single Voice must not require player race") end
local singleVoice, singleInfo = selection:Resolve("questnpc", model)
Equal(singleVoice, 20, "Unknown NPC family uses the narrator voice")
Equal(singleInfo.modelFileID, 999999, "Retain model information for speaker presentation")
Equal(singleInfo.family, nil)
Equal(selection:ResolvePlayer(), 20, "Player narration uses the same voice")
environment.UnitSex = originalUnitSex
addon.Database:SetSingleVoice(0)
Equal(selection:ResolvePlayer(), 0, "Voice ID zero remains valid")
addon.Database:SetSingleVoice(nil)
singleVoice, singleInfo = selection:ResolvePlayer()
Equal(singleVoice, nil)
Equal(singleInfo.reason, "single-voice-not-set")

for _, unavailable in ipairs({ 999, -1, 1.5, "invalid" }) do
    addon.Database:SetSingleVoice(unavailable)
    singleVoice, singleInfo = selection:ResolvePlayer()
    Equal(singleVoice, nil, "Unavailable narrator never falls back to family voices")
    Equal(singleInfo.reason, "single-voice-unavailable")
    Equal(addon.Database:GetSingleVoice(), unavailable, "Unavailable narrator setting is preserved")
end

addon.Database:SetSingleVoice(20)
addon.Database:SetVoiceMode("raceGender")

Equal(savedVariables.voices, voices, "Mode switching retains the family table")
Equal(voices.SKYBORNE[2], skyborneMale)
Equal(voices.SKYBORNE[3], skyborneFemale)
Equal(addon.Database:GetSingleVoice(), 20, "Inactive narrator selection is retained")
Resolve(959310, 2, "UNDEAD", "MALE", 50)
addon.Database:SetVoiceMode("single")

-- Reload only the Lua module against the same saved-value table, without client persistence.
local reloaded = { VoiceSelection = selection, TTS = addon.TTS }
local reloadDatabase = assert(LoadFile("Core/Database.lua"))
addon.Database:SetSpeechRate(4)
setfenv(reloadDatabase, environment)
reloadDatabase("OutLoud", reloaded)
reloaded.Database:Initialize()
Equal(reloaded.Database:GetVoiceMode(), "single", "Assignment mode survives module reinitialization")
Equal(reloaded.Database:GetSingleVoice(), 20, "Narrator voice survives module reinitialization")
Equal(reloaded.Database:GetVoice("SKYBORNE", 2), skyborneMale, "Family assignments survive module reinitialization")
Equal(reloaded.Database:GetSpeechRate(), 4, "Speech rate survives module reinitialization")
addon.Database:SetSpeechRate(0)
addon.Database:SetVoiceMode("invalid")
Equal(addon.Database:GetVoiceMode(), "raceGender", "Invalid modes normalize to the existing behavior")

print("PASS: isolated voice-selection and saved-value logic; WoW runtime behavior unverified")
