local AddonName, OutLoud = ...

local Database = {}
OutLoud.Database = Database

Database.SingleVoiceAssignments = {
    ALL = "allCharacters",
    CHARACTER = "perCharacter",
}

Database.NarrationSources = { "quest", "gossip", "itemText" }

Database.AutoNarrationDelay = {
    DEFAULT = 2,
    MIN = 0,
    MAX = 5,
    STEP = 0.5,
}

Database.SpeechRate = {
    DEFAULT = 0,
    MIN = -10,
    MAX = 10,
    STEP = 1,
}

local function NormalizeSpeechRate(value)
    local range = Database.SpeechRate
    if type(value) ~= "number" or value % range.STEP ~= 0 then
        return range.DEFAULT
    end
    return math.max(range.MIN, math.min(range.MAX, value))
end

local function NormalizeAutoNarrationDelay(value)
    local range = Database.AutoNarrationDelay
    if type(value) ~= "number" or value ~= value then
        return range.DEFAULT
    end
    value = math.max(range.MIN, math.min(range.MAX, value))
    return math.floor(value / range.STEP + 0.5) * range.STEP
end

local function NormalizeVoiceMode(mode)
    local modes = OutLoud.VoiceSelection.AssignmentModes
    return mode == modes.SINGLE and modes.SINGLE or modes.RACE_GENDER
end

local function NormalizeSingleVoiceAssignment(assignment)
    local assignments = Database.SingleVoiceAssignments
    return assignment == assignments.CHARACTER and assignments.CHARACTER or assignments.ALL
end

local function CaptureVoice(voiceID)
    local name = OutLoud.VoiceSelection:GetVoiceName(voiceID)
    if name then return { name = name, voiceID = voiceID } end
end

local function ResolveVoice(container, key, clearedValue)
    local assignment = container[key]
    if type(assignment) ~= "table" then return nil end
    -- A failed first enumeration is not evidence that a voice was removed.
    OutLoud.TTS:GetVoices()
    if not OutLoud.TTS.VoicesReady then return nil end
    local voiceID = OutLoud.VoiceSelection:GetVoiceID(assignment.name)
    if voiceID == nil then
        container[key] = clearedValue
    else
        assignment.voiceID = voiceID
    end
    return voiceID
end

local function RetireNumericSingleVoice(db, clearedValue)
    if type(db.singleVoice) == "number" then
        -- Keep the old value for inspection, but never infer a name from it.
        if db.legacySingleVoiceID == nil then db.legacySingleVoiceID = db.singleVoice end
        db.singleVoice = clearedValue
    end
end

function Database:Initialize()
    if self.Initialized then
        return
    end

    -- Forever keeps its original table; Retail never reads or migrates it.
    local savedVariables = OutLoud.Client and OutLoud.Client.SavedVariables or "OutLoudDB"
    local db = _G[savedVariables]

    if type(db) ~= "table" then
        db = {}
        _G[savedVariables] = db
    end

    if type(db.voices) ~= "table" then
        db.voices = {}
    end

    if type(db.autoPlay) ~= "table" then db.autoPlay = {} end
    if type(db.autoClose) ~= "table" then db.autoClose = {} end
    for _, source in ipairs(self.NarrationSources) do
        -- Fill only missing values; newer source preferences win over legacy data.
        if db.autoPlay[source] == nil then
            db.autoPlay[source] = db.autoNarrateQuests == true
        end
        if db.autoClose[source] == nil then db.autoClose[source] = true end
    end
    db.autoNarrateQuests = nil
    -- Retire the obsolete preference without resetting other saved settings.
    db.readingMode = nil
    db.voiceMode = NormalizeVoiceMode(db.voiceMode)
    db.singleVoiceAssignment = NormalizeSingleVoiceAssignment(db.singleVoiceAssignment)
    db.autoNarrationDelay = NormalizeAutoNarrationDelay(db.autoNarrationDelay)
    db.speechRate = NormalizeSpeechRate(db.speechRate)

    self.DB = db
    OutLoud.DB = db

    local characterSavedVariables = OutLoud.Client and OutLoud.Client.SavedVariablesPerCharacter
        or "OutLoudCharacterDB"
    local characterDB = _G[characterSavedVariables]
    if type(characterDB) ~= "table" then
        characterDB = {}
        _G[characterSavedVariables] = characterDB
    end
    self.CharacterDB = characterDB

    for family, assignments in pairs(db.voices) do
        if type(assignments) == "table" then
            for sex, assignment in pairs(assignments) do
                if type(assignment) == "number" then
                    db.legacyVoiceIDs = db.legacyVoiceIDs or {}
                    db.legacyVoiceIDs[family] = db.legacyVoiceIDs[family] or {}
                    if db.legacyVoiceIDs[family][sex] == nil then
                        db.legacyVoiceIDs[family][sex] = assignment
                    end
                    assignments[sex] = nil
                end
            end
        end
    end
    RetireNumericSingleVoice(db)
    RetireNumericSingleVoice(characterDB, false)

    self.Initialized = true
end

function Database:GetVoice(family, gender)
    local familyVoices = self.DB.voices[family]

    if type(familyVoices) ~= "table" then
        return nil
    end

    return ResolveVoice(familyVoices, gender)
end

function Database:SetVoice(family, gender, voiceID)
    local voices = self.DB.voices

    if type(voices[family]) ~= "table" then
        voices[family] = {}
    end

    voices[family][gender] = CaptureVoice(voiceID)
end

function Database:GetVoiceMode()
    return NormalizeVoiceMode(self.DB.voiceMode)
end

function Database:SetVoiceMode(mode)
    self.DB.voiceMode = NormalizeVoiceMode(mode)
end

function Database:GetSingleVoice()
    if self:GetSingleVoiceAssignment() == self.SingleVoiceAssignments.CHARACTER
        and self:HasCharacterSingleVoice() then
        return ResolveVoice(self.CharacterDB, "singleVoice", false)
    end
    return ResolveVoice(self.DB, "singleVoice")
end

function Database:SetSingleVoice(voiceID)
    if self:GetSingleVoiceAssignment() == self.SingleVoiceAssignments.CHARACTER then
        -- false is an explicit Not set override; nil means inherit global.
        self.CharacterDB.singleVoice = CaptureVoice(voiceID) or false
    else
        self.DB.singleVoice = CaptureVoice(voiceID)
    end
end

function Database:RefreshVoiceAssignments()
    if not self.Initialized then return end
    for _, assignments in pairs(self.DB.voices) do
        if type(assignments) == "table" then
            for sex in pairs(assignments) do ResolveVoice(assignments, sex) end
        end
    end
    ResolveVoice(self.DB, "singleVoice")
    ResolveVoice(self.CharacterDB, "singleVoice", false)
end

function Database:GetSingleVoiceAssignment()
    return NormalizeSingleVoiceAssignment(self.DB.singleVoiceAssignment)
end

function Database:SetSingleVoiceAssignment(assignment)
    self.DB.singleVoiceAssignment = NormalizeSingleVoiceAssignment(assignment)
end

function Database:HasCharacterSingleVoice()
    return self.CharacterDB.singleVoice ~= nil
end

function Database:ResetCharacterSingleVoice()
    self.CharacterDB.singleVoice = nil
end

function Database:GetAutoPlay(source)
    return self.DB.autoPlay[source] == true
end

function Database:SetAutoPlay(source, enabled)
    if self.DB.autoPlay[source] == nil then return end
    self.DB.autoPlay[source] = enabled == true
end

function Database:HasAutoPlay()
    for _, source in ipairs(self.NarrationSources) do
        if self:GetAutoPlay(source) then return true end
    end
    return false
end

function Database:GetAutoClose(source)
    return self.DB.autoClose[source] == true
end

function Database:SetAutoClose(source, enabled)
    if self.DB.autoClose[source] == nil then return end
    self.DB.autoClose[source] = enabled == true
end

function Database:GetAutoNarrationDelay()
    return NormalizeAutoNarrationDelay(self.DB.autoNarrationDelay)
end

function Database:SetAutoNarrationDelay(delay)
    self.DB.autoNarrationDelay = NormalizeAutoNarrationDelay(delay)
end

function Database:GetSpeechRate()
    return NormalizeSpeechRate(self.DB.speechRate)
end

function Database:SetSpeechRate(rate)
    self.DB.speechRate = NormalizeSpeechRate(rate)
end
