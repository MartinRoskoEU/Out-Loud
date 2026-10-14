local AddonName, OutLoud = ...

local Database = {}
OutLoud.Database = Database

Database.AutoNarrationDelay = {
    DEFAULT = 2,
    MIN = 0,
    MAX = 5,
    STEP = 0.5,
}

local function NormalizeAutoNarrationDelay(value)
    local range = Database.AutoNarrationDelay
    if type(value) ~= "number" or value ~= value then
        return range.DEFAULT
    end
    value = math.max(range.MIN, math.min(range.MAX, value))
    return math.floor(value / range.STEP + 0.5) * range.STEP
end

local function NormalizeReadingMode(mode)
    local modes = OutLoud.TTS.ReadingModes
    return mode == modes.SPLIT and modes.SPLIT or modes.FULL
end

local function NormalizeVoiceMode(mode)
    local modes = OutLoud.VoiceSelection.AssignmentModes
    return mode == modes.SINGLE and modes.SINGLE or modes.RACE_GENDER
end

function Database:Initialize()
    if self.Initialized then
        return
    end

    local db = OutLoudDB

    if type(db) ~= "table" then
        db = {}
        OutLoudDB = db
    end

    if type(db.voices) ~= "table" then
        db.voices = {}
    end

    if db.autoNarrateQuests == nil then
        db.autoNarrateQuests = false
    end
    db.readingMode = NormalizeReadingMode(db.readingMode)
    db.voiceMode = NormalizeVoiceMode(db.voiceMode)
    db.autoNarrationDelay = NormalizeAutoNarrationDelay(db.autoNarrationDelay)

    self.DB = db
    OutLoud.DB = db

    self.Initialized = true
end

function Database:GetVoice(family, gender)
    local familyVoices = self.DB.voices[family]

    if type(familyVoices) ~= "table" then
        return nil
    end

    return familyVoices[gender]
end

function Database:SetVoice(family, gender, voiceID)
    local voices = self.DB.voices

    if type(voices[family]) ~= "table" then
        voices[family] = {}
    end

    voices[family][gender] = voiceID
end

function Database:GetVoiceMode()
    return NormalizeVoiceMode(self.DB.voiceMode)
end

function Database:SetVoiceMode(mode)
    self.DB.voiceMode = NormalizeVoiceMode(mode)
end

function Database:GetSingleVoice()
    return self.DB.singleVoice
end

function Database:SetSingleVoice(voiceID)
    self.DB.singleVoice = voiceID
end

function Database:GetReadingMode()
    return NormalizeReadingMode(self.DB.readingMode)
end

function Database:SetReadingMode(mode)
    self.DB.readingMode = NormalizeReadingMode(mode)
end

function Database:GetAutoNarrateQuests()
    return self.DB.autoNarrateQuests == true
end

function Database:SetAutoNarrateQuests(enabled)
    self.DB.autoNarrateQuests = enabled == true
end

function Database:GetAutoNarrationDelay()
    return NormalizeAutoNarrationDelay(self.DB.autoNarrationDelay)
end

function Database:SetAutoNarrationDelay(delay)
    self.DB.autoNarrationDelay = NormalizeAutoNarrationDelay(delay)
end
