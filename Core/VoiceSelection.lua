local AddonName, OutLoud = ...

local VoiceSelection = {}
OutLoud.VoiceSelection = VoiceSelection

VoiceSelection.AssignmentModes = {
    SINGLE = "single",
    RACE_GENDER = "raceGender",
}

-- Runtime UnitSex values, independent of generated model data.
VoiceSelection.Genders = {
    MALE = 2,
    FEMALE = 3,
}

-- Locale-stable playable race tokens, restricted to established Voice Families.
local playerRaceFamilies = {
    Human = "HUMAN",
    Orc = "ORC",
    Dwarf = "DWARF",
    NightElf = "NIGHT_ELF",
    Scourge = "UNDEAD",
    Tauren = "TAUREN",
    Gnome = "GNOME",
    Troll = "TROLL",
    BloodElf = "BLOOD_ELF",
    Draenei = "DRAENEI",
    Goblin = "GOBLIN",
}

local function GetGender(sex)
    if sex == VoiceSelection.Genders.MALE then
        return "MALE"
    elseif sex == VoiceSelection.Genders.FEMALE then
        return "FEMALE"
    end
end

local function ResolveConfiguredVoice(info)
    if not info.gender then
        info.reason = "unknown-sex"
        return nil, info
    end

    info.voiceID = OutLoud.Database:GetVoice(info.family, info.sex)
    if info.voiceID == nil then
        info.reason = "voice-not-set"
    end
    return info.voiceID, info
end

function VoiceSelection:IsSingleVoiceMode()
    return OutLoud.Database:GetVoiceMode() == self.AssignmentModes.SINGLE
end

local function ResolveSingleVoice(info)
    local voiceID = OutLoud.Database:GetSingleVoice()
    if voiceID == nil then
        info.reason = "single-voice-not-set"
        return nil, info
    end

    if type(voiceID) == "number" and voiceID >= 0 and voiceID % 1 == 0 then
        for _, voice in ipairs(OutLoud.TTS:GetVoices()) do
            if voice.voiceID == voiceID then
                info.voiceID = voiceID
                return voiceID, info
            end
        end
    end
    info.reason = "single-voice-unavailable"
    return nil, info
end

function VoiceSelection:ResolvePlayer()
    local info = {}
    if not UnitExists("player") then
        info.reason = "unit-unavailable"
        return nil, info
    end

    info.name = UnitName("player")
    if self:IsSingleVoiceMode() then
        return ResolveSingleVoice(info)
    end
    info.raceName, info.raceToken, info.raceID = UnitRace("player")
    info.sex = UnitSex("player")
    info.gender = GetGender(info.sex)

    local familyKey = playerRaceFamilies[info.raceToken]
    info.family = familyKey and OutLoud.VoiceMappings.Families[familyKey]
    if not info.family then
        info.reason = "unknown-player-race"
        return nil, info
    end
    return ResolveConfiguredVoice(info)
end

function VoiceSelection:GetFamilies()
    local mappings = OutLoud.VoiceMappings
    local unique = {}

    for _, family in pairs(mappings.Families) do
        unique[family] = true
    end

    local families = {}

    for family in pairs(unique) do
        table.insert(families, family)
    end

    table.sort(families)

    return families
end

function VoiceSelection:GetFamilyName(family)
    local name = family:gsub("_", " "):lower()
    return (name:gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end))
end

function VoiceSelection:GetFamily(fileDataID)
    return OutLoud.VoiceMappings.Models[fileDataID]
end

-- The caller supplies a PlayerModel already loaded for this unit.
-- Returns the configured voice ID (or nil) and inspection details.
function VoiceSelection:Resolve(unit, model)
    local info = {}

    if not unit or not UnitExists(unit) then
        info.reason = "unit-unavailable"
        return nil, info
    end

    info.name = UnitName(unit)
    local singleVoice = self:IsSingleVoiceMode()
    if not singleVoice then
        info.sex = UnitSex(unit)
        info.gender = GetGender(info.sex)
    end

    info.modelFileID = model and model:GetModelFileID()

    if not info.modelFileID or info.modelFileID == 0 then
        info.reason = "model-unavailable"
        return nil, info
    end

    -- Model readiness still determines NPC presentation; family/gender do not
    -- determine the voice in Single Voice mode.
    if singleVoice then
        return ResolveSingleVoice(info)
    end

    info.family = self:GetFamily(info.modelFileID)

    if not info.family then
        info.reason = "unknown-model"
        return nil, info
    end

    return ResolveConfiguredVoice(info)
end
