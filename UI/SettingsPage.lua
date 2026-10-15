local AddonName, OutLoud = ...

local SettingsPage = {}
OutLoud.UI.SettingsPage = SettingsPage

local AUTO_NARRATION_LABEL = "Automatically read quest text"
local AUTO_NARRATION_DESCRIPTION = "Automatically starts narration when opening quest details, quest progress, or quest reward pages. Quest Log narration remains manual."
local AUTO_DELAY_DESCRIPTION = "Waits before automatically starting quest narration, allowing existing NPC dialogue to finish first. This delay does not affect manual narration."

local VOICES_LAYOUT = {
    -- Align family labels with the radio descriptions and narrator controls.
    leftPadding = 31,
    rightPadding = 0,

    raceWidth = 120,

    voiceControlWidth = 250,
    columnGap = 10,
}

function SettingsPage:Initialize()
    if self.Initialized then
        return
    end

    local panel = CreateFrame("Frame")
    local category = Settings.RegisterCanvasLayoutCategory(panel, "Out Loud")
    Settings.RegisterAddOnCategory(category)

    self.Panel = panel
    self.Category = category

    self:CreateScrollContainer()
    self:CreateHeader()

    self:CreateVoiceAssignmentSection()
    local voicesAnchor = self:CreateVoicesSection()
    self:CreateReadingSection(voicesAnchor)
    self:RefreshVoiceAssignment()
    self:UpdateScrollLayout()

    self.Initialized = true
end

function SettingsPage:CreateScrollContainer()
    local scroll = CreateFrame("ScrollFrame", nil, self.Panel)
    scroll:SetPoint("TOPLEFT", self.Panel, "TOPLEFT", 0, 0)
    -- Reserve room for the template's scrollbar outside the clipped viewport.
    scroll:SetPoint("BOTTOMRIGHT", self.Panel, "BOTTOMRIGHT", -32, 14)
    scroll:EnableMouseWheel(true)

    -- The Core API annotations omit the scrollbar methods supplied by this template.
    ---@class OutLoudSettingsScrollBar : EventFrame
    ---@field SetHideIfUnscrollable fun(self: OutLoudSettingsScrollBar, hide: boolean)
    ---@field SetScrollPercentage fun(self: OutLoudSettingsScrollBar, percentage: number, forceImmediate?: boolean)
    ---@field SetVisibleExtentPercentage fun(self: OutLoudSettingsScrollBar, percentage: number)
    ---@field SetPanExtentPercentage fun(self: OutLoudSettingsScrollBar, percentage: number)
    ---@field ScrollStepInDirection fun(self: OutLoudSettingsScrollBar, direction: number)
    local scrollBar = CreateFrame("EventFrame", nil, self.Panel, "MinimalScrollBar")
    ---@cast scrollBar OutLoudSettingsScrollBar
    scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 0)
    scrollBar:SetHideIfUnscrollable(true)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    content:SetPoint("TOPLEFT")
    scroll:SetScrollChild(content)

    self.ScrollFrame = scroll
    self.ScrollBar = scrollBar
    self.Content = content

    -- SetScrollPercentage emits OnScroll even when its value has not changed.
    local syncingScrollBar = false
    scroll:SetScript("OnVerticalScroll", function(_, offset)
        if syncingScrollBar then
            return
        end

        local range = math.max(0, scroll:GetVerticalScrollRange())
        local percentage = range > 0 and offset / range or 0
        syncingScrollBar = true
        scrollBar:SetScrollPercentage(percentage, ScrollBoxConstants.NoScrollInterpolation)
        syncingScrollBar = false
    end)
    scrollBar:RegisterCallback("OnScroll", function(_, percentage)
        if not syncingScrollBar then
            self:SetScrollPosition(percentage * math.max(0, scroll:GetVerticalScrollRange()))
        end
    end, scroll)

    scroll:SetScript("OnMouseWheel", function(_, delta)
        scrollBar:ScrollStepInDirection(-delta)
    end)
    scroll:SetScript("OnSizeChanged", function()
        self:UpdateScrollLayout()
    end)
    scroll:SetScript("OnShow", function()
        OutLoud.VoiceSelection:RefreshVoices()
        self:UpdateScrollLayout()
    end)
end

function SettingsPage:SetScrollPosition(position)
    local scroll = self.ScrollFrame
    local range = math.max(0, scroll:GetVerticalScrollRange())
    scroll:SetVerticalScroll(math.max(0, math.min(range, position)))
end

function SettingsPage:UpdateScrollLayout()
    local scroll, content = self.ScrollFrame, self.Content
    content:SetWidth(math.max(1, scroll:GetWidth()))

    if not self.AutoNarrateDescription then
        return
    end

    self:UpdateVoiceWidths(content:GetWidth())
    -- Keep the existing description width unless the viewport requires wrapping.
    local descriptionWidth = math.max(1, math.min(620, content:GetWidth() - 45))
    for _, description in ipairs({
        self.SingleVoiceDescription, self.RaceGenderDescription, self.NarratorVoiceDescription,
    }) do
        description:SetWidth(descriptionWidth)
    end
    if self.AutoNarrateDescription then
        self.AutoNarrateDescription:SetWidth(descriptionWidth)
    end
    if self.AutoNarrationDelayDescription then
        self.AutoNarrationDelayDescription:SetWidth(descriptionWidth)
    end
    if self.SpeechRateDescription then
        self.SpeechRateDescription:SetWidth(descriptionWidth)
    end

    local lastDescription = self.SpeechRateDescription or self.AutoNarrationDelayDescription
        or self.AutoNarrateDescription
    local top, bottom = content:GetTop(), lastDescription:GetBottom()
    if top and bottom then
        content:SetHeight(math.max(1, top - bottom + 24))
    end

    local position = scroll:GetVerticalScroll()
    scroll:UpdateScrollChildRect()
    local range = math.max(0, scroll:GetVerticalScrollRange())
    local visiblePercentage = 1
    if content:GetHeight() > 0 then
        visiblePercentage = math.max(0, math.min(1, scroll:GetHeight() / content:GetHeight()))
    end
    self.ScrollBar:SetVisibleExtentPercentage(visiblePercentage)
    self.ScrollBar:SetPanExtentPercentage(range > 0 and math.min(1, 36 / range) or 0)
    self:SetScrollPosition(position)
    local percentage = range > 0 and scroll:GetVerticalScroll() / range or 0
    self.ScrollBar:SetScrollPercentage(percentage, ScrollBoxConstants.NoScrollInterpolation)
end

function SettingsPage:UpdateVoiceWidths(contentWidth)
    self.VoicesColumns:SetWidth(math.max(1, contentWidth - 14))
    -- Preserve the 250-pixel controls unless the scrollbar gutter makes them crowd.
    local available = contentWidth - 14 - VOICES_LAYOUT.leftPadding
        - VOICES_LAYOUT.raceWidth - VOICES_LAYOUT.rightPadding
        - 2 * VOICES_LAYOUT.columnGap
    local width = math.max(100, math.min(VOICES_LAYOUT.voiceControlWidth, available / 2))

    for _, row in ipairs(self.VoiceRows) do
        for _, combo in ipairs({ row.MaleComboBox, row.FemaleComboBox }) do
            combo.Frame:SetWidth(width)
            combo.Dropdown:SetWidth(width - 80)
        end
    end

    local femaleCenter = VOICES_LAYOUT.rightPadding + width / 2
    local maleCenter = femaleCenter + width + VOICES_LAYOUT.columnGap
    self.VoicesMaleLabel:SetPoint("CENTER", self.VoicesColumns, "RIGHT", -maleCenter, 0)
    self.VoicesFemaleLabel:SetPoint("CENTER", self.VoicesColumns, "RIGHT", -femaleCenter, 0)
end

function SettingsPage:CreateHeader()
    local title = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", 7, -22)
    title:SetText(AddonName)

    local divider = self.Content:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 7, -50)
    divider:SetAtlas("Options_HorizontalDivider", true)
end

function SettingsPage:CreateVoiceAssignmentSection()
    local header = CreateFrame("Frame", nil, self.Content, "SettingsListSectionHeaderTemplate")
    header:SetPoint("TOPLEFT", 7, -70)
    header:SetPoint("TOPRIGHT", -7, -70)
    header.Title:SetText("Voice Assignment")
    self.VoiceAssignmentHeader = header

    local modes = OutLoud.VoiceSelection.AssignmentModes
    local previous = header
    for _, option in ipairs({
        { mode = modes.SINGLE, label = "Single Voice", key = "SingleVoice",
            description = "Use one selected voice for all narration, regardless of the speaker's family or gender." },
        { mode = modes.RACE_GENDER, label = "Multiple Voices", key = "RaceGender",
            description = "Assign different voices based on the speaker's family and gender." },
    }) do
        local mode = option.mode
        local button = CreateFrame("CheckButton", nil, self.Content, "UIRadioButtonTemplate")
        button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", previous == header and 10 or -21, -16)
        button.text:SetFontObject(GameFontNormal)
        button.text:SetText(option.label)
        button:SetScript("OnClick", function()
            OutLoud.Database:SetVoiceMode(mode)
            self:RefreshVoiceAssignment()
        end)

        local description = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        description:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 21, -5)
        description:SetWidth(620)
        description:SetJustifyH("LEFT")
        description:SetJustifyV("TOP")
        description:SetWordWrap(true)
        description:SetText(option.description)
        self[option.key .. "Button"] = button
        self[option.key .. "Description"] = description
        previous = description
    end

    local label = self.Content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", self.SingleVoiceDescription, "BOTTOMLEFT", 0, -18)
    label:SetText("Narrator Voice")
    local combo = OutLoud.Classes.ComboBox:New(self.Content, VOICES_LAYOUT.voiceControlWidth)
    combo.Frame:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    combo:Setup(self:GetVoiceOptions(), function()
        return OutLoud.Database:GetSingleVoice()
    end, function(voiceID)
        OutLoud.Database:SetSingleVoice(voiceID)
    end)

    local description = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", combo.Frame, "BOTTOMLEFT", 0, -8)
    description:SetWidth(620)
    description:SetJustifyH("LEFT")
    description:SetJustifyV("TOP")
    description:SetWordWrap(true)
    description:SetText("Select the voice used for all quest narration.")
    self.SingleVoiceComboBox = combo
    self.NarratorVoiceLabel = label
    self.NarratorVoiceDescription = description

    self.RaceGenderButton:ClearAllPoints()
    self.RaceGenderButton:SetPoint("TOPLEFT", description, "BOTTOMLEFT", -21, -24)
end

function SettingsPage:RefreshVoiceAssignment()
    if not self.SingleVoiceComboBox then return end
    local single = OutLoud.VoiceSelection:IsSingleVoiceMode()
    self.SingleVoiceButton:SetChecked(single)
    self.RaceGenderButton:SetChecked(not single)
    self.SingleVoiceComboBox:SetEnabled(single)
    self.SingleVoiceComboBox:Refresh()
    self.NarratorVoiceLabel:SetFontObject(single and GameFontNormal or GameFontDisable)
    self.NarratorVoiceDescription:SetFontObject(single and GameFontHighlightSmall or GameFontDisableSmall)
    for _, row in ipairs(self.VoiceRows or {}) do
        row:SetEnabled(not single)
        row.MaleComboBox:Refresh()
        row.FemaleComboBox:Refresh()
    end
    if self.VoicesMaleLabel then
        self.VoicesFamilyLabel:SetFontObject(single and GameFontDisable or GameFontNormal)
        self.VoicesMaleLabel:SetFontObject(single and GameFontDisable or GameFontNormal)
        self.VoicesFemaleLabel:SetFontObject(single and GameFontDisable or GameFontNormal)
    end
end

function SettingsPage:CreateVoicesSection()
    local columns = CreateFrame("Frame", nil, self.Content)
    columns:SetPoint("TOPLEFT", self.RaceGenderDescription, "BOTTOMLEFT", -VOICES_LAYOUT.leftPadding, -18)
    columns:SetWidth(math.max(1, self.Content:GetWidth() - 14))
    columns:SetHeight(32)

    local raceLabel = columns:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontNormal"
    )

    raceLabel:SetPoint(
        "LEFT",
        columns,
        "LEFT",
        VOICES_LAYOUT.leftPadding,
        0
    )

    raceLabel:SetWidth(VOICES_LAYOUT.raceWidth)
    raceLabel:SetJustifyH("LEFT")
    raceLabel:SetText("Family")

    local femaleCenter = VOICES_LAYOUT.rightPadding
        + (VOICES_LAYOUT.voiceControlWidth / 2)

    local maleCenter = VOICES_LAYOUT.rightPadding
        + VOICES_LAYOUT.voiceControlWidth
        + VOICES_LAYOUT.columnGap
        + (VOICES_LAYOUT.voiceControlWidth / 2)

    local maleLabel = columns:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontNormal"
    )

    maleLabel:SetPoint(
        "CENTER",
        columns,
        "RIGHT",
        -maleCenter,
        0
    )

    maleLabel:SetText("Male")

    local femaleLabel = columns:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontNormal"
    )

    femaleLabel:SetPoint(
        "CENTER",
        columns,
        "RIGHT",
        -femaleCenter,
        0
    )

    femaleLabel:SetText("Female")

    self.VoicesFamilyLabel = raceLabel
    self.VoicesColumns = columns
    self.VoicesMaleLabel = maleLabel
    self.VoicesFemaleLabel = femaleLabel

    return self:CreateVoiceRows(columns)
end

function SettingsPage:GetVoiceOptions()
    if self.VoiceOptions then
        return self.VoiceOptions
    end

    return self:RefreshVoiceOptions()
end

function SettingsPage:RefreshVoiceOptions()
    -- Existing dropdown callbacks share this table; refresh it in place.
    local options = self.VoiceOptions or {}
    for index = #options, 1, -1 do options[index] = nil end
    options[1] = { label = "Not set", value = nil }

    for _, voice in ipairs(OutLoud.TTS:GetVoices()) do
        table.insert(options, {
            label = voice.name,
            value = voice.voiceID,
        })
    end

    self.VoiceOptions = options

    return options
end

function SettingsPage:CreateVoiceRows(anchor)
    local selection = OutLoud.VoiceSelection
    local families = selection:GetFamilies()
    local voiceOptions = self:GetVoiceOptions()

    for _, row in ipairs(self.VoiceRows or {}) do
        row.Frame:Hide()
        row.Frame:ClearAllPoints()
    end
    self.VoiceRows = {}

    local previousFrame

    for _, family in ipairs(families) do
        local currentFamily = family

        local row = OutLoud.Classes.VoiceRow:New(
            self.Content,
            VOICES_LAYOUT
        )

        if previousFrame then
            row.Frame:SetPoint(
                "TOPLEFT",
                previousFrame,
                "BOTTOMLEFT",
                0,
                -4
            )

            row.Frame:SetPoint(
                "TOPRIGHT",
                previousFrame,
                "BOTTOMRIGHT",
                0,
                -4
            )
        else
            row.Frame:SetPoint(
                "TOPLEFT",
                anchor,
                "BOTTOMLEFT",
                0,
                -4
            )

            row.Frame:SetPoint(
                "TOPRIGHT",
                anchor,
                "BOTTOMRIGHT",
                0,
                -4
            )
        end

        row:Setup(
            selection:GetFamilyName(currentFamily),
            voiceOptions,

            function()
                return OutLoud.Database:GetVoice(
                    currentFamily,
                    selection.Genders.MALE
                )
            end,

            function(voiceID)
                OutLoud.Database:SetVoice(
                    currentFamily,
                    selection.Genders.MALE,
                    voiceID
                )
            end,

            function()
                return OutLoud.Database:GetVoice(
                    currentFamily,
                    selection.Genders.FEMALE
                )
            end,

            function(voiceID)
                OutLoud.Database:SetVoice(
                    currentFamily,
                    selection.Genders.FEMALE,
                    voiceID
                )
            end
        )

        table.insert(self.VoiceRows, row)
        previousFrame = row.Frame
    end

    local lastFrame = previousFrame or anchor
    self:RefreshVoiceAssignment()
    if self.ReadingHeader then
        self:AnchorReadingSection(lastFrame)
        self:UpdateScrollLayout()
    end

    return lastFrame
end

function SettingsPage:AnchorReadingSection(anchor)
    local header = self.ReadingHeader
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -24)
    header:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -24)
end

function SettingsPage:RefreshAutoNarrationDelay()
    local control = self.AutoNarrationDelaySlider
    if not control then return end
    local enabled = OutLoud.Database:GetAutoNarrateQuests()
    self.SyncingAutoNarrationDelay = true
    control:SetValue(OutLoud.Database:GetAutoNarrationDelay())
    self.SyncingAutoNarrationDelay = false
    control:SetEnabled(enabled)
    self.AutoNarrationDelayLabel:SetFontObject(enabled and GameFontNormal or GameFontDisable)
    self.AutoNarrationDelayDescription:SetFontObject(enabled and GameFontHighlightSmall or GameFontDisableSmall)
end

function SettingsPage:RefreshSpeechRate()
    local control = self.SpeechRateSlider
    if not control then return end
    self.SyncingSpeechRate = true
    control:SetValue(OutLoud.Database:GetSpeechRate())
    self.SyncingSpeechRate = false
    control:SetEnabled(true)
end

function SettingsPage:CreateSpeechRateControl(anchor)
    local label = self.Content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -21, -18)
    label:SetText("Speech Rate")

    local control = CreateFrame("Frame", nil, self.Content, "MinimalSliderWithSteppersTemplate")
    ---@cast control OutLoudSettingsDelaySlider
    control:SetWidth(250)
    control:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    local range = OutLoud.Database.SpeechRate
    control:Init(OutLoud.Database:GetSpeechRate(), range.MIN, range.MAX,
        (range.MAX - range.MIN) / range.STEP, {
            [control.Label.Right] = function(value)
                return string.format(value > 0 and "+%d" or "%d", value)
            end,
            [control.Label.Min] = function() return "-10 (Slower)" end,
            [control.Label.Max] = function() return "+10 (Faster)" end,
        })
    control:RegisterCallback(control.Event.OnValueChanged, function(_, value)
        if not self.SyncingSpeechRate then
            OutLoud.Database:SetSpeechRate(value)
            self:RefreshSpeechRate()
        end
    end, self)
    control:HookScript("OnShow", function() self:RefreshSpeechRate() end)

    local reset = CreateFrame("Button", nil, self.Content, "UIPanelButtonTemplate")
    reset:SetSize(100, 22)
    reset:SetPoint("LEFT", control, "RIGHT", 72, 0)
    reset:SetText("Reset to 0")
    reset:SetScript("OnClick", function()
        OutLoud.Database:SetSpeechRate(range.DEFAULT)
        self:RefreshSpeechRate()
    end)

    local description = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", control, "BOTTOMLEFT", 21, -18)
    description:SetWidth(620)
    description:SetJustifyH("LEFT")
    description:SetJustifyV("TOP")
    description:SetWordWrap(true)
    description:SetText("Adjusts the speed of spoken narration. Zero is the normal speech rate.")
    self.SpeechRateSlider = control
    self.SpeechRateLabel = label
    self.SpeechRateResetButton = reset
    self.SpeechRateDescription = description
    self:RefreshSpeechRate()
end

function SettingsPage:CreateReadingSection(anchor)
    local header = CreateFrame(
        "Frame",
        nil,
        self.Content,
        "SettingsListSectionHeaderTemplate"
    )

    self.ReadingHeader = header
    self:AnchorReadingSection(anchor)

    header.Title:SetText("Narration")

    -- Native checkbox used by Forever's modern Settings controls.
    ---@class OutLoudSettingsCheckbox : CheckButton
    ---@field Init fun(self: OutLoudSettingsCheckbox, value: boolean, initTooltip?: function)
    ---@field SetValue fun(self: OutLoudSettingsCheckbox, value: boolean)
    ---@field RegisterCallback fun(self: OutLoudSettingsCheckbox, event: string, callback: function, owner: table)
    ---@field HoverBackground Texture
    local autoButton = CreateFrame("CheckButton", nil, self.Content, "SettingsCheckboxTemplate")
    ---@cast autoButton OutLoudSettingsCheckbox
    autoButton:SetSize(self.SingleVoiceButton:GetWidth(), self.SingleVoiceButton:GetHeight())
    autoButton:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 10, -18)
    -- Keep the modern artwork within the same bounds as the radio controls.
    for _, texture in ipairs({
        autoButton:GetNormalTexture(), autoButton:GetPushedTexture(),
        autoButton:GetCheckedTexture(), autoButton:GetDisabledCheckedTexture(),
    }) do
        texture:ClearAllPoints()
        texture:SetAllPoints(autoButton)
    end
    autoButton:Init(OutLoud.Database:GetAutoNarrateQuests(), nil)
    autoButton:SetScript("OnEnter", nil)
    autoButton:SetScript("OnLeave", nil)
    -- The native hover region anchors to the settings row's parent by default.
    autoButton.HoverBackground:ClearAllPoints()
    autoButton.HoverBackground:SetAllPoints(autoButton)
    autoButton.HoverBackground:SetAlpha(0)
    autoButton.HoverBackground:Hide()
    autoButton:RegisterCallback(SettingsCheckboxMixin.Event.OnValueChanged, function(_, value)
        OutLoud.Database:SetAutoNarrateQuests(value)
        self:RefreshAutoNarrationDelay()
    end, self)
    autoButton:SetScript("OnShow", function()
        autoButton:SetValue(OutLoud.Database:GetAutoNarrateQuests())
        self:RefreshAutoNarrationDelay()
    end)

    local autoLabel = autoButton:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    autoLabel:SetPoint("LEFT", autoButton, "RIGHT", 5, 0)
    autoLabel:SetText(AUTO_NARRATION_LABEL)
    -- Include only the label in the click area, leaving the description inactive.
    autoButton:SetHitRectInsets(0, -(5 + autoLabel:GetStringWidth()), 0, 0)

    local autoDescription = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    autoDescription:SetPoint("TOPLEFT", autoButton, "BOTTOMLEFT", 21, -5)
    autoDescription:SetWidth(620)
    autoDescription:SetJustifyH("LEFT")
    autoDescription:SetJustifyV("TOP")
    autoDescription:SetWordWrap(true)
    autoDescription:SetText(AUTO_NARRATION_DESCRIPTION)

    local delayLabel = self.Content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    delayLabel:SetPoint("TOPLEFT", autoDescription, "BOTTOMLEFT", -21, -18)
    delayLabel:SetText("Automatic narration delay")

    -- The same native slider/stepper implementation used by Forever Settings.
    ---@class OutLoudSettingsDelaySlider : Frame
    ---@field Init fun(self: OutLoudSettingsDelaySlider, value: number, minimum: number, maximum: number, steps: number, formatters: table)
    ---@field SetValue fun(self: OutLoudSettingsDelaySlider, value: number)
    ---@field SetEnabled fun(self: OutLoudSettingsDelaySlider, enabled: boolean)
    ---@field RegisterCallback fun(self: OutLoudSettingsDelaySlider, event: string, callback: function, owner: table)
    ---@field Label table
    ---@field Event table
    local delayControl = CreateFrame("Frame", nil, self.Content, "MinimalSliderWithSteppersTemplate")
    ---@cast delayControl OutLoudSettingsDelaySlider
    delayControl:SetWidth(250)
    delayControl:SetPoint("TOPLEFT", delayLabel, "BOTTOMLEFT", 0, -8)
    local range = OutLoud.Database.AutoNarrationDelay
    delayControl:Init(OutLoud.Database:GetAutoNarrationDelay(), range.MIN, range.MAX,
        (range.MAX - range.MIN) / range.STEP, {
            [delayControl.Label.Right] = function(value)
                return string.format("%g s", value)
            end,
        })
    delayControl:RegisterCallback(delayControl.Event.OnValueChanged, function(_, value)
        if not self.SyncingAutoNarrationDelay and OutLoud.Database:GetAutoNarrateQuests() then
            OutLoud.Database:SetAutoNarrationDelay(value)
        end
    end, self)
    delayControl:HookScript("OnShow", function()
        self:RefreshAutoNarrationDelay()
    end)

    local delayDescription = self.Content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    delayDescription:SetPoint("TOPLEFT", delayControl, "BOTTOMLEFT", 21, -8)
    delayDescription:SetWidth(620)
    delayDescription:SetJustifyH("LEFT")
    delayDescription:SetJustifyV("TOP")
    delayDescription:SetWordWrap(true)
    delayDescription:SetText(AUTO_DELAY_DESCRIPTION)

    self.AutoNarrateQuestsCheckbox = autoButton
    self.AutoNarrateDescription = autoDescription
    self.AutoNarrationDelaySlider = delayControl
    self.AutoNarrationDelayLabel = delayLabel
    self.AutoNarrationDelayDescription = delayDescription
    self:RefreshAutoNarrationDelay()
    self:CreateSpeechRateControl(delayDescription)
end
