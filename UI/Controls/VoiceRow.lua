local AddonName, OutLoud = ...

local VoiceRow = {}
VoiceRow.__index = VoiceRow

OutLoud.Classes.VoiceRow = VoiceRow

function VoiceRow:New(parent, layout)
    local instance = setmetatable({}, self)

    instance.Frame = CreateFrame("Frame", nil, parent)
    instance.Frame:SetHeight(32)

    local raceLabel = instance.Frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    raceLabel:SetPoint(
        "LEFT",
        instance.Frame,
        "LEFT",
        layout.leftPadding,
        0
    )
    raceLabel:SetWidth(layout.raceWidth)
    raceLabel:SetJustifyH("LEFT")

    instance.RaceLabel = raceLabel

    instance.FemaleComboBox = OutLoud.Classes.ComboBox:New(
        instance.Frame,
        layout.voiceControlWidth
    )

    instance.FemaleComboBox.Frame:SetPoint(
        "RIGHT",
        instance.Frame,
        "RIGHT",
        -layout.rightPadding,
        0
    )

    instance.MaleComboBox = OutLoud.Classes.ComboBox:New(
        instance.Frame,
        layout.voiceControlWidth
    )

    instance.MaleComboBox.Frame:SetPoint(
        "RIGHT",
        instance.FemaleComboBox.Frame,
        "LEFT",
        -layout.columnGap,
        0
    )

    return instance
end

function VoiceRow:Setup(
    raceName,
    voiceOptions,
    getMaleVoice,
    setMaleVoice,
    getFemaleVoice,
    setFemaleVoice
)
    self.RaceLabel:SetText(raceName)

    self.MaleComboBox:Setup(
        voiceOptions,
        getMaleVoice,
        setMaleVoice
    )

    self.FemaleComboBox:Setup(
        voiceOptions,
        getFemaleVoice,
        setFemaleVoice
    )
end

function VoiceRow:SetEnabled(enabled)
    self.MaleComboBox:SetEnabled(enabled)
    self.FemaleComboBox:SetEnabled(enabled)
    self.RaceLabel:SetFontObject(enabled and GameFontHighlight or GameFontDisable)
end
