-- Run from the addon root with Lua 5.1: lua Tests/VoiceSelection.lua
-- Keep mock APIs local so the editor cannot infer game API types from them.
local environment = setmetatable({}, { __index = _G })
environment._G = environment

-- Standalone Lua supplies these APIs; the WoW editor configuration omits them.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")
local FileIO = assert(rawget(_G, "io"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Frame(parent)
    local frame = { scripts = {}, points = {}, callbacks = {}, events = {}, parent = parent, shown = true,
        heightValue = 0, widthValue = 800, scrollValue = 0, enabled = true }
    local methods = {
        SetScript = function(self, event, callback) self.scripts[event] = callback end,
        RegisterEvent = function(self, event) self.events[event] = true end,
        UnregisterEvent = function(self, event) self.events[event] = nil end,
        HookScript = function(self, event, callback)
            local previous = self.scripts[event]
            self.scripts[event] = function(...)
                if previous then previous(...) end
                callback(...)
            end
        end,
        RegisterCallback = function(self, event, callback, owner)
            self.callbacks[event] = function(...) callback(owner, ...) end
        end,
        GetScript = function(self, event) return self.scripts[event] end,
        SetText = function(self, text) self.textValue = text end,
        SetFontObject = function(self, font) self.fontObject = font end,
        SetChecked = function(self, checked) self.checked = checked end,
        SetEnabled = function(self, enabled) self.enabled = enabled end,
        IsEnabled = function(self) return self.enabled end,
        SetSelectionText = function(self, callback) self.selectionText = callback end,
        GenerateMenu = function(self)
            if self.selectionText then self.textValue = self.selectionText() end
        end,
        CloseMenu = function(self) self.menuOpen = false end,
        GetStringWidth = function(self) return #(self.textValue or "") * 8 end,
        SetWidth = function(self, width) self.widthValue = width end,
        GetWidth = function(self) return self.widthValue end,
        SetHeight = function(self, height)
            local changed = self.heightValue ~= height
            self.heightValue = height
            if changed and self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self) end
        end,
        GetHeight = function(self) return self.heightValue end,
        SetSize = function(self, width, height) self.widthValue, self.heightValue = width, height end,
        SetPoint = function(self, point, relative, relativePoint, x, y)
            if type(relative) == "number" then
                x, y, relativePoint, relative = relative, relativePoint, point, rawget(self, "parent")
            elseif not relative then
                relative, relativePoint = rawget(self, "parent"), point
            end
            self.points[point] = { relative = relative, point = relativePoint, x = x or 0, y = y or 0 }
        end,
        ClearAllPoints = function(self) self.points = {} end,
        GetTop = function(self)
            local anchor = self.points.TOPLEFT or self.points.TOPRIGHT or self.points.TOP
            if not anchor then return 600 end
            local top = 600
            if anchor.relative then
                top = anchor.point:find("BOTTOM") and anchor.relative:GetBottom() or anchor.relative:GetTop()
            end
            return top + anchor.y
        end,
        GetBottom = function(self) return self:GetTop() - self:GetHeight() end,
        Show = function(self) self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,
        SetScrollChild = function(self, child) self.scrollChild = child end,
        GetVerticalScroll = function(self) return self.scrollValue end,
        GetVerticalScrollRange = function(self)
            return math.max(0, self.scrollChild:GetHeight() - self:GetHeight())
        end,
        SetVerticalScroll = function(self, value) self.scrollValue = value end,
        CreateFontString = function(self)
            local font = Frame(self)
            font:SetHeight(32) -- Simulated text height, not proof of real font wrapping.
            return font
        end,
        CreateTexture = function(self) return Frame(self) end,
        SetupMenu = function(self, callback) self.menu = callback end,
    }
    setmetatable(frame, { __index = function(self, key)
        if key == "Title" or key == "Label" or key == "Dropdown" or key == "text"
            or key == "HoverBackground" or key == "IncrementButton" or key == "DecrementButton" then
            local child = Frame(self)
            rawset(self, key, child)
            return child
        end
        return methods[key] or function() end
    end })
    return frame
end

local frames = {}
function environment.CreateFrame(kind, _name, parent, template)
    local frame = Frame(parent)
    frame.template = template
    if template == "SettingsListSectionHeaderTemplate" then frame:SetHeight(20) end
    if template == "UIRadioButtonTemplate" then frame:SetSize(16, 16) end
    if template == "SettingsCheckboxTemplate" then
        for _, name in ipairs({ "Normal", "Pushed", "Checked", "DisabledChecked" }) do
            local texture = Frame(frame)
            frame["Get" .. name .. "Texture"] = function() return texture end
        end
        function frame:Init(value) self.value = value end
        function frame:SetValue(value) self.value = value end
    elseif template == "MinimalSliderWithSteppersTemplate" then
        frame:SetSize(250, 40)
        frame.Label = { Right = 2, Min = 4, Max = 5 }
        frame.Event = { OnValueChanged = "OnValueChanged" }
        function frame:Init(value, minimum, maximum, steps, formatters)
            self.value, self.minimum, self.maximum = value, minimum, maximum
            self.step, self.formatters = (maximum - minimum) / steps, formatters
        end
        function frame:SetValue(value)
            self.value = value
            if self.callbacks.OnValueChanged then self.callbacks.OnValueChanged(value) end
        end
        function frame:SetEnabled(enabled) self.enabled = enabled end
    elseif template == "MinimalScrollBar" then
        function frame:SetScrollPercentage(value)
            self.percentage = math.max(0, math.min(1, value))
            if self.callbacks.OnScroll then self.callbacks.OnScroll(self.percentage) end
        end
        function frame:SetVisibleExtentPercentage(value) self.shown = value < 1 end
        function frame:SetPanExtentPercentage(value) self.pan = value end
        function frame:ScrollStepInDirection(direction)
            self:SetScrollPercentage(self.percentage + direction * self.pan)
        end
    elseif template == "SettingsDropdownWithButtonsTemplate" then
        -- Mirror the exported mixin's propagation to dropdown and steppers.
        function frame:SetEnabled(enabled)
            self.Dropdown:SetEnabled(enabled)
            self.DecrementButton:SetEnabled(enabled)
            self.IncrementButton:SetEnabled(enabled)
        end
    end
    if kind == "ScrollFrame" then
        frame:SetSize(760, 420)
    end
    table.insert(frames, frame)
    return frame
end

local sex, exists = 2, true
function environment.UnitSex() return sex end
function environment.UnitExists() return exists end
function environment.UnitName() return "Test NPC" end
environment.Settings = {
    RegisterCanvasLayoutCategory = function(_panel, _name) return {} end,
    RegisterAddOnCategory = function(_category) end,
}
environment.SettingsCheckboxMixin = { Event = { OnValueChanged = "OnValueChanged" } }
environment.ScrollBoxConstants = { NoScrollInterpolation = true }
for _, font in ipairs({ "GameFontNormal", "GameFontHighlight", "GameFontHighlightSmall",
    "GameFontDisable", "GameFontDisableSmall" }) do
    environment[font] = font
end
local availableVoices, enumerations = {}, 0
for id = 0, 60 do
    availableVoices[#availableVoices + 1] = { voiceID = id, name = "Voice " .. id }
end
environment.C_VoiceChat = { GetTtsVoices = function()
    enumerations = enumerations + 1
    return availableVoices
end }

local addon = {}
local function Load(path)
    local chunk = assert(LoadFile(path))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
end

-- Load the real files in their declared order and exercise ADDON_LOADED.
for line in FileIO.lines("OutLoud.toc") do
    if line:match("%.lua$") then
        Load((line:gsub("\\", "/")))
        if line == "UI\\TalkingHead.lua" then
            -- XML rendering cannot be reproduced here; the real Settings controls are exercised.
            addon.UI.TalkingHead.Initialize = function() end
        end
    end
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
    readingMode = "split",
}
environment.OutLoudDB = savedVariables
local initFrame = frames[#frames]
initFrame.scripts.OnEvent(initFrame, "ADDON_LOADED", "OtherAddon")
Equal(addon.Loaded, false, "Ignore unrelated addon event")
initFrame.scripts.OnEvent(initFrame, "ADDON_LOADED", "OutLoud")
Equal(addon.Loaded, true, "TOC initialization")
assert(addon.UI.QuestIntegration.LoadFrame, "Quest integration initializes and waits for Blizzard UI")
local settingsPage = addon.UI.SettingsPage
Equal(settingsPage.ScrollFrame.parent, settingsPage.Panel, "Fixed page owns viewport")
Equal(settingsPage.Content.parent, settingsPage.ScrollFrame, "Viewport owns scroll child")
Equal(settingsPage.ScrollFrame.scrollChild, settingsPage.Content, "Native scroll child set")
Equal(settingsPage.VoiceRows[1].Frame.parent, settingsPage.Content, "Voice rows inside content")
Equal(settingsPage.FullTextButton.parent, settingsPage.Content, "Reading controls inside content")
Equal(settingsPage.ScrollFrame.points.BOTTOMRIGHT.x, -32, "Scrollbar gutter reserved")
assert(settingsPage.Content:GetHeight() > settingsPage.ScrollFrame:GetHeight(), "Dynamic rows exceed viewport")
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 0, "Initial scroll at top")
Equal(addon.Database:GetVoice("UNDEAD", 2), 50, "Keep saved male assignment")
Equal(addon.Database:GetVoice("UNDEAD", 3), 41, "Keep saved female assignment")
Equal(addon.Database:GetReadingMode(), "split", "Keep reading settings")
Equal(addon.Database:GetVoiceMode(), "raceGender", "Existing users default to Race & Gender")
Equal(addon.Database:GetSingleVoice(), nil, "No arbitrary narrator voice is chosen")
Equal(settingsPage.RaceGenderButton.checked, true, "Default radio selection is clear")
Equal(settingsPage.SingleVoiceButton.checked, false)
Equal(settingsPage.SingleVoiceComboBox.Dropdown:IsEnabled(), false, "Inactive Single Voice is disabled")
Equal(settingsPage.VoiceRows[1].MaleComboBox.Dropdown:IsEnabled(), true)
Equal(initFrame.scripts.OnEvent, nil, "Release initialization callback after loading")
Equal(addon.Database:GetAutoNarrationDelay(), 2, "Automatic delay default")
Equal(settingsPage.AutoNarrationDelaySlider.enabled, false, "Delay control disabled by default")
Equal(addon.Database:GetSpeechRate(), 0, "Existing SavedVariables receive the normal rate")
local rateSlider = settingsPage.SpeechRateSlider
Equal(rateSlider.template, settingsPage.AutoNarrationDelaySlider.template, "Reuse the same native slider")
Equal(rateSlider.parent, settingsPage.Content, "Rate slider remains inside scroll content")
Equal(rateSlider.minimum, -10)
Equal(rateSlider.maximum, 10)
Equal(rateSlider.step, 1, "Native rate step is exactly one")
Equal(rateSlider.enabled, true, "Rate remains enabled when automatic narration is off")
Equal(rateSlider.value, 0)
Equal(rateSlider.formatters[rateSlider.Label.Right](0), "0")
Equal(rateSlider.formatters[rateSlider.Label.Right](3), "+3")
Equal(rateSlider.formatters[rateSlider.Label.Right](-3), "-3")
Equal(rateSlider.formatters[rateSlider.Label.Min](-10), "-10 (Slower)")
Equal(rateSlider.formatters[rateSlider.Label.Max](10), "+10 (Faster)")
rateSlider:SetValue(3)
Equal(addon.Database:GetSpeechRate(), 3, "Slider changes persist immediately")
addon.Database:SetAutoNarrateQuests(true)
settingsPage:RefreshAutoNarrationDelay()
Equal(rateSlider.enabled, true, "Automatic narration does not gate speech rate")
addon.Database:SetAutoNarrateQuests(false)
settingsPage:RefreshAutoNarrationDelay()
Equal(rateSlider.enabled, true)
settingsPage.SpeechRateResetButton.scripts.OnClick()
Equal(addon.Database:GetSpeechRate(), 0, "Reset restores normal rate")
Equal(rateSlider.value, 0, "Reset refreshes the native slider")
addon.Database:SetSpeechRate(-4)
rateSlider:Show()
Equal(rateSlider.value, -4, "Opening the control reads the saved rate")
addon.Database:SetSpeechRate(0)
settingsPage:RefreshSpeechRate()
addon.Database:SetReadingMode("invalid")
Equal(addon.Database:GetReadingMode(), "full", "Invalid reading mode uses the existing full default")
addon.Database:SetReadingMode("split")
local humanVoices = savedVariables.voices.HUMAN
savedVariables.voices.HUMAN = false
Equal(addon.Database:GetVoice("HUMAN", 2), nil, "Malformed family settings are unresolved")
addon.Database:SetVoice("HUMAN", 2, 0)
Equal(addon.Database:GetVoice("HUMAN", 2), 0, "A selector can repair malformed family settings")
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

-- Verify Options and runtime selection against the actual generated export first.
Equal(#addon.UI.SettingsPage.VoiceRows, exportedCount, "Generated Options row count")
local exportedSkyborneRows = 0
for _, row in ipairs(addon.UI.SettingsPage.VoiceRows) do
    if row.RaceLabel.textValue == "Skyborne" then
        exportedSkyborneRows = exportedSkyborneRows + 1
        assert(row.MaleComboBox and row.FemaleComboBox, "Both generated Skyborne selectors")
    end
end
Equal(exportedSkyborneRows, 1, "Generated export has one Skyborne row")
Resolve(959310, 2, "UNDEAD", "MALE", 50)
Resolve(997378, 3, "UNDEAD", "FEMALE", 41)
Resolve(7478487, 2, "SKYBORNE", "MALE", 10)
Resolve(7478494, 3, "SKYBORNE", "FEMALE", 11)
Resolve(1000764, 2, "HUMAN", "MALE", 0)
Resolve(1011653, 3, "HUMAN", "FEMALE", 13)

-- Replace the export completely: no Races, Genders, or GetRaces helper.
addon.VoiceMappings = {
    Families = {
        HUMAN = "HUMAN", UNDEAD = "UNDEAD", SKYBORNE = "SKYBORNE",
        SKYBORNE_ALIAS = "SKYBORNE", NIGHT_ELF = "NIGHT_ELF",
        FUTURE_FAMILY = "FUTURE_FAMILY",
    },
    Models = {
        [959310] = "UNDEAD", [7478487] = "SKYBORNE",
        [7478494] = "SKYBORNE", [100] = "HUMAN", [101] = "HUMAN",
    },
}
addon.UI.SettingsPage:CreateVoiceRows(addon.UI.SettingsPage.VoicesColumns)

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

local rows = addon.UI.SettingsPage.VoiceRows
Equal(#rows, 5, "One row per unique catalog family, including unmodeled families")
local byName, skyborneCount = {}, 0
for _, row in ipairs(rows) do
    local name = row.RaceLabel.textValue
    byName[name] = row
    if name == "Skyborne" then skyborneCount = skyborneCount + 1 end
end
Equal(skyborneCount, 1, "Only one Skyborne row")
assert(byName["Night Elf"] and byName["Future Family"], "Readable dynamic family names")
local selectors = 0
for _, combo in ipairs({ byName.Skyborne.MaleComboBox, byName.Skyborne.FemaleComboBox }) do
    local entries = {}
    combo.Dropdown.menu(nil, { CreateRadio = function(_, label, get, set, value)
        if value == 20 then entries[1] = { get = get, set = set } end
    end })
    entries[1].set(20)
    Equal(entries[1].get(20), true, "Dropdown read/write callback")
    selectors = selectors + 1
end
Equal(selectors, 2, "Separate Skyborne selectors")
Equal(addon.Database:GetVoice("SKYBORNE", 2), 20, "Male selector saves family")
Equal(addon.Database:GetVoice("SKYBORNE", 3), 20, "Female selector saves family")
Equal(addon.Database:GetVoice("UNDEAD", 2), 50, "Callbacks do not capture another family")

addon.Database:SetVoice("UNDEAD", 3, nil)
addon.Database.Initialized = false
addon.Database:Initialize()
Equal(addon.Database:GetVoice("UNDEAD", 3), nil, "Cleared voice remains unset after reinitialization")
Unresolved(959310, 3, "voice-not-set")

-- Both assignment areas use the exact same available options and native controls.
local function MenuEntries(combo)
    local entries = {}
    combo.Dropdown.menu(nil, { CreateRadio = function(_, label, get, set, value)
        entries[#entries + 1] = { label = label, value = value, get = get, set = set }
    end })
    return entries
end
local narrator = settingsPage.SingleVoiceComboBox
local narratorEntries = MenuEntries(narrator)
local familyEntries = MenuEntries(settingsPage.VoiceRows[1].MaleComboBox)
Equal(#narratorEntries, #familyEntries, "Same voice count, including Not set")
for index, entry in ipairs(narratorEntries) do
    Equal(entry.label, familyEntries[index].label)
    Equal(entry.value, familyEntries[index].value, "No separate voice filtering")
end
narratorEntries[22].set(20)
Equal(addon.Database:GetSingleVoice(), nil, "Disabled narrator ignores stale menu actions")
local voices = savedVariables.voices
local skyborneMale, skyborneFemale = voices.SKYBORNE[2], voices.SKYBORNE[3]
settingsPage.SingleVoiceButton.scripts.OnClick()
Equal(addon.Database:GetVoiceMode(), "single")
Equal(settingsPage.SingleVoiceButton.checked, true)
Equal(settingsPage.RaceGenderButton.checked, false)
Equal(narrator.Dropdown:IsEnabled(), true)
Equal(settingsPage.NarratorVoiceLabel.fontObject, "GameFontNormal")
for _, row in ipairs(settingsPage.VoiceRows) do
    for _, combo in ipairs({ row.MaleComboBox, row.FemaleComboBox }) do
        Equal(combo.Dropdown:IsEnabled(), false, "Inactive family dropdown is disabled")
        Equal(combo.Frame.IncrementButton:IsEnabled(), false, "Inactive increment is disabled")
        Equal(combo.Frame.DecrementButton:IsEnabled(), false, "Inactive decrement is disabled")
    end
    Equal(row.RaceLabel.fontObject, "GameFontDisable", "Inactive family label is dimmed")
end
familyEntries[22].set(20)
Equal(addon.Database:GetVoice("FUTURE_FAMILY", 2), nil, "Inactive family callbacks cannot write settings")
narratorEntries[22].set(20)
Equal(addon.Database:GetSingleVoice(), 20, "Enabled narrator selector saves the same numeric ID convention")
Equal(narratorEntries[22].get(20), true)

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
narrator:Refresh()
Equal(narrator.Dropdown.textValue, "Not set")
for _, unavailable in ipairs({ 999, -1, 1.5, "invalid" }) do
    addon.Database:SetSingleVoice(unavailable)
    singleVoice, singleInfo = selection:ResolvePlayer()
    Equal(singleVoice, nil, "Unavailable narrator never falls back to family voices")
    Equal(singleInfo.reason, "single-voice-unavailable")
    settingsPage:RefreshVoiceAssignment()
    Equal(addon.Database:GetSingleVoice(), unavailable, "Unavailable narrator setting is preserved")
    Equal(narrator.Dropdown.textValue, "Unavailable (voice " .. unavailable .. ")")
end
addon.Database:SetSingleVoice(20)
settingsPage.RaceGenderButton.scripts.OnClick()
Equal(narrator.Dropdown:IsEnabled(), false)
Equal(settingsPage.NarratorVoiceLabel.fontObject, "GameFontDisable")
Equal(savedVariables.voices, voices, "Mode switching retains the family table")
Equal(voices.SKYBORNE[2], skyborneMale)
Equal(voices.SKYBORNE[3], skyborneFemale)
Equal(addon.Database:GetSingleVoice(), 20, "Inactive narrator selection is retained")
Resolve(959310, 2, "UNDEAD", "MALE", 50)
addon.Database:SetVoiceMode("single")
settingsPage.ScrollFrame:Show()
Equal(settingsPage.SingleVoiceButton.checked, true, "Opening Settings refreshes saved mode")
Equal(narrator.Dropdown:IsEnabled(), true)
Equal(settingsPage.VoiceRows[1].MaleComboBox.Dropdown:IsEnabled(), false)
addon.Database:SetVoice("HUMAN", 2, 999)
settingsPage:CreateVoiceRows(settingsPage.VoicesColumns)
Equal(addon.Database:GetVoice("HUMAN", 2), 999, "Rebuilding Settings preserves unavailable family assignments")
addon.Database:SetVoice("HUMAN", 2, 0)

-- A freshly loaded database reads both independent settings from SavedVariables.
local reloaded = { VoiceSelection = selection, TTS = addon.TTS }
local reloadDatabase = assert(LoadFile("Core/Database.lua"))
addon.Database:SetSpeechRate(4)
setfenv(reloadDatabase, environment)
reloadDatabase("OutLoud", reloaded)
reloaded.Database:Initialize()
Equal(reloaded.Database:GetVoiceMode(), "single", "Assignment mode persists after reload")
Equal(reloaded.Database:GetSingleVoice(), 20, "Narrator voice persists after reload")
Equal(reloaded.Database:GetVoice("SKYBORNE", 2), skyborneMale, "Family assignments persist after reload")
Equal(reloaded.Database:GetSpeechRate(), 4, "Speech rate persists in a freshly loaded database")
addon.Database:SetSpeechRate(0)
addon.Database:SetVoiceMode("invalid")
Equal(addon.Database:GetVoiceMode(), "raceGender", "Invalid modes normalize to the existing behavior")
settingsPage:RefreshVoiceAssignment()

-- Voice updates refresh the existing shared menus without touching saved IDs or playback.
local originalVoices = availableVoices
local sharedOptions = settingsPage:GetVoiceOptions()
local activeSession = { id = 123, voiceID = 50 }
addon.TTS.CurrentSession = activeSession
Equal(selection.Frame.events.VOICE_CHAT_TTS_VOICES_UPDATE, true, "Observe the documented voice-update event")
availableVoices = { { voiceID = 20, name = "Voice 20" }, { voiceID = 61, name = "Third-party voice" } }
local beforeRefresh = enumerations
selection.Frame.scripts.OnEvent(selection.Frame, "VOICE_CHAT_TTS_VOICES_UPDATE")
Equal(enumerations, beforeRefresh + 1, "Voice-update event performs one enumeration")
Equal(settingsPage:GetVoiceOptions(), sharedOptions, "Existing selector callbacks retain the same options table")
Equal(#sharedOptions, 3)
Equal(addon.TTS.CurrentSession, activeSession, "Refreshing availability leaves active playback untouched")
local newNarratorEntries = MenuEntries(narrator)
local newFamilyEntries = MenuEntries(settingsPage.VoiceRows[1].MaleComboBox)
Equal(newNarratorEntries[3].value, 61, "New third-party voice appears in the narrator selector")
Equal(newFamilyEntries[3].value, 61, "The same new voice appears in family selectors")
local unavailableVoice, unavailableInfo = selection:Resolve("questnpc", model)
Equal(unavailableVoice, nil)
Equal(unavailableInfo.reason, "voice-unavailable", "Removed family voice fails gracefully")
Equal(addon.Database:GetVoice("UNDEAD", 2), 50, "Unavailable family assignment is preserved")
local humanRow
for _, row in ipairs(settingsPage.VoiceRows) do
    if row.RaceLabel.textValue == "Human" then humanRow = row end
end
Equal(humanRow.MaleComboBox.Dropdown.textValue, "Unavailable (voice 0)")
settingsPage.SingleVoiceButton.scripts.OnClick()
newNarratorEntries[3].set(61)
Equal(selection:ResolvePlayer(), 61, "Runtime resolution uses the refreshed availability")
Equal(enumerations, beforeRefresh + 1, "Resolution does not continuously enumerate voices")

-- No name matching or reassignment, including ambiguous duplicate names.
addon.Database:SetSingleVoice(20)
availableVoices = { { voiceID = 61, name = "Duplicate voice" }, { voiceID = 62, name = "Duplicate voice" } }
selection.Frame.scripts.OnEvent(selection.Frame, "VOICE_CHAT_TTS_VOICES_UPDATE")
unavailableVoice, unavailableInfo = selection:ResolvePlayer()
Equal(unavailableVoice, nil)
Equal(unavailableInfo.reason, "single-voice-unavailable")
Equal(addon.Database:GetSingleVoice(), 20, "Do not replace a missing voice with an ambiguous name match")
Equal(narrator.Dropdown.textValue, "Unavailable (voice 20)")
availableVoices = originalVoices
beforeRefresh = enumerations
settingsPage.ScrollFrame:Hide()
settingsPage.ScrollFrame:Show()
Equal(enumerations, beforeRefresh + 1, "Settings opening explicitly refreshes availability")
Equal(selection:ResolvePlayer(), 20, "A restored voice resolves without rewriting its saved ID")
Equal(narrator.Dropdown.textValue, "Voice 20")
Equal(addon.TTS.CurrentSession, activeSession)
addon.TTS.CurrentSession = nil
settingsPage.RaceGenderButton.scripts.OnClick()

-- Empty exports still anchor the Reading section safely.
addon.VoiceMappings.Families = {}
local anchor = settingsPage.VoicesColumns
Equal(addon.UI.SettingsPage:CreateVoiceRows(anchor), anchor, "Empty catalog anchor")
Equal(#addon.UI.SettingsPage.VoiceRows, 0, "No rows from model entries")

-- Exercise scroll layout against rebuilt real controls, using simulated geometry.
local emptyHeight = settingsPage.Content:GetHeight()
local function RebuildFamilies(count)
    local families = {}
    for index = 1, count do families[index] = "SCROLL_FAMILY_" .. index end
    addon.VoiceMappings.Families = families
    settingsPage:CreateVoiceRows(settingsPage.VoicesColumns)
end
RebuildFamilies(30)
Equal(settingsPage.Content:GetHeight(), emptyHeight + 30 * 36, "Every family adds its row height and gap")
local maximum = settingsPage.ScrollFrame:GetVerticalScrollRange()
Equal(maximum, settingsPage.Content:GetHeight() - settingsPage.ScrollFrame:GetHeight(), "Range follows content")
Equal(settingsPage.ScrollBar:IsShown(), true, "Overflow shows native scrollbar")
local wheel = settingsPage.ScrollFrame.scripts.OnMouseWheel
wheel(settingsPage.ScrollFrame, -1)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 36, "Wheel down moves down")
wheel(settingsPage.ScrollFrame, 1)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 0, "Wheel up moves up")
wheel(settingsPage.ScrollFrame, -10000)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), maximum, "Clamp at bottom")
wheel(settingsPage.ScrollFrame, 10000)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 0, "Clamp at top")
settingsPage:SetScrollPosition(72)
local oldRows = settingsPage.VoiceRows
RebuildFamilies(31)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 72, "Preserve valid offset on rebuild")
Equal(oldRows[1].Frame:IsShown(), false, "Replaced controls hidden")
Equal(next(oldRows[1].Frame.points), nil, "Old controls detached from layout")
settingsPage.ScrollFrame:Hide()
settingsPage.ScrollFrame:Show()
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 72, "Reopening keeps session position")
settingsPage.FullTextButton.scripts.OnClick()
Equal(addon.Database:GetReadingMode(), "full", "Reading selector works while scrolled")
settingsPage.SplitTextButton.scripts.OnClick()
Equal(addon.Database:GetReadingMode(), "split", "Split selector works while scrolled")
settingsPage:SetScrollPosition(10000)
RebuildFamilies(0)
Equal(settingsPage.Content:GetHeight(), emptyHeight, "Shorter rebuild updates content height")
local shortRange = math.max(0, emptyHeight - settingsPage.ScrollFrame:GetHeight())
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), shortRange, "Shorter content clamps old position")
Equal(settingsPage.ScrollFrame:GetVerticalScrollRange(), shortRange, "Range follows all Narration controls")
Equal(settingsPage.ScrollBar:IsShown(), shortRange > 0, "Scrollbar follows remaining overflow")
RebuildFamilies(30)
settingsPage:SetScrollPosition(10000)
settingsPage.ScrollFrame:SetHeight(settingsPage.Content:GetHeight() + 100)
Equal(settingsPage.ScrollFrame:GetVerticalScroll(), 0, "Viewport resize clamps position")
Equal(settingsPage.ScrollBar:IsShown(), false, "Larger viewport needs no scrollbar")
settingsPage.ScrollFrame:SetHeight(420)
Equal(settingsPage.ScrollBar:IsShown(), true, "Smaller viewport restores scrolling")
settingsPage.ScrollFrame:SetWidth(600)
settingsPage:UpdateScrollLayout()
Equal(settingsPage.Content:GetWidth(), 600, "Content follows viewport width")
Equal(settingsPage.SplitDescription:GetWidth(), 555, "Descriptions fit narrower content")
Equal(settingsPage.SpeechRateDescription:GetWidth(), 555, "Speech-rate description follows the same wrapping")
Equal(settingsPage.VoiceRows[1].MaleComboBox.Frame:GetWidth(), 207.5, "Voice columns fit the current indented layout")
Equal(settingsPage.VoiceRows[1].MaleComboBox.Dropdown:GetWidth(), 127.5, "Dropdown follows control width")
settingsPage.ScrollFrame:SetWidth(760)
settingsPage:UpdateScrollLayout()
Equal(settingsPage.VoiceRows[1].MaleComboBox.Frame:GetWidth(), 250, "Existing sizing restored when it fits")

print("PASS: classification, Options selectors and scrolling, TOC load order, and saved settings")
