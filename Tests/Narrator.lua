-- Run from the addon root with standalone Lua 5.1.
-- Isolated production saved-table/resolver logic and static UI/TOC checks only.
-- Supplied tables stand for separate saved files; no native persistence or UI is simulated.
local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end
local function Read(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return source
end
local function Load(path, addon, environment)
    local chunk = assert(loadfile(path))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
end
local globals = {
    OutLoudDB = { singleVoice = 7, voiceMode = "single", voices = { UNDEAD = { [2] = 31 } }, speechRate = 3 },
    OutLoudRetailDB = { singleVoice = 8, voiceMode = "single", voices = { UNDEAD = { [2] = 31 } }, speechRate = 4 },
}
local available = { { voiceID = 0 }, { voiceID = 7 }, { voiceID = 8 },
    { voiceID = 9 }, { voiceID = 10 }, { voiceID = 31 } }
for _, client in ipairs({ "Forever", "Retail" }) do
    local saved = client == "Forever" and "OutLoudDB" or "OutLoudRetailDB"
    local characterSaved = client == "Forever" and "OutLoudCharacterDB" or "OutLoudRetailCharacterDB"
    local global = globals[saved]
    local character1, character2 = {}, {}
    local otherCharacter = { singleVoice = 31 }
    local otherKey = client == "Forever" and "OutLoudRetailCharacterDB" or "OutLoudCharacterDB"
    local otherSaved = client == "Forever" and "OutLoudRetailDB" or "OutLoudDB"
    local otherGlobal = globals[otherSaved]
    local otherVoice, otherAssignment = otherGlobal.singleVoice, otherGlobal.singleVoiceAssignment
    local environment = setmetatable({
        UnitExists = function() return true end,
        UnitName = function() return "Supplied speaker" end,
        UnitSex = function() return 2 end,
        UnitRace = function() return "Human", "Human", 1 end,
    }, { __index = _G })
    environment._G = environment
    environment.OutLoudDB, environment.OutLoudRetailDB = globals.OutLoudDB, globals.OutLoudRetailDB
    environment[otherKey] = otherCharacter
    local function Open(character)
        environment[characterSaved] = character
        local addon = { TTS = { GetVoices = function() return available end } }
        for _, path in ipairs({ "Clients/" .. client .. "/Config.lua",
            "Clients/" .. client .. "/VoiceMappings.lua", "Core/VoiceSelection.lua", "Core/Database.lua" }) do
            Load(path, addon, environment)
        end
        Equal(addon.Client.SavedVariables, saved)
        Equal(addon.Client.SavedVariablesPerCharacter, characterSaved)
        addon.Database:Initialize()
        Equal(addon.Database.DB, global, "Preserve the existing global table")
        Equal(addon.Database.CharacterDB, environment[characterSaved])
        return addon
    end
    local addon = Open(character1)
    local db, selection = addon.Database, addon.VoiceSelection
    local assignments = db.SingleVoiceAssignments
    local originalGlobal, familyTable = global.singleVoice, global.voices
    Equal(db:GetSingleVoiceAssignment(), assignments.ALL, "Existing users default to global assignment")
    Equal(db:GetSingleVoice(), originalGlobal)
    Equal(selection:ResolvePlayer(), originalGlobal, "Existing narrator stays active")
    Equal(db:HasCharacterSingleVoice(), false)
    Equal(next(character1), nil, "Initialization must not create a voice override")

    db:SetSingleVoiceAssignment(assignments.CHARACTER)
    for _ = 1, 2 do
        Equal(db:GetSingleVoice(), originalGlobal, "Inherit without writing")
        Equal(selection:ResolvePlayer(), originalGlobal)
        Equal(selection:Resolve("questnpc", { GetModelFileID = function() return 959310 end }), originalGlobal)
    end
    Equal(next(character1), nil, "Reads must not materialize inheritance")
    db:SetSingleVoice(9)
    Equal(character1.singleVoice, 9)
    Equal(global.singleVoice, originalGlobal, "Character edit cannot write global voice")
    Equal(selection:ResolvePlayer(), 9)
    db:SetSingleVoiceAssignment(assignments.ALL)
    Equal(db:GetSingleVoice(), originalGlobal, "Global mode displays the global voice")
    Equal(character1.singleVoice, 9, "Mode switching retains override")
    db:SetSingleVoice(10)
    Equal(global.singleVoice, 10)
    Equal(character1.singleVoice, 9)
    db:SetSingleVoiceAssignment(assignments.CHARACTER)
    Equal(db:GetSingleVoice(), 9, "Switching back restores the override")

    local second = Open(character2)
    Equal(second.Database:GetSingleVoice(), 10, "Another character inherits the updated global voice")
    Equal(next(character2), nil, "Opening another character creates no override")
    Equal(character1.singleVoice, 9, "Characters are isolated")
    second.Database:SetSingleVoice(0)
    Equal(second.Database:HasCharacterSingleVoice(), true, "Voice zero is an override")
    Equal(second.VoiceSelection:ResolvePlayer(), 0)
    Equal(character1.singleVoice, 9)

    -- Reload production modules with the same supplied saved tables.
    local reloaded = Open(character1)
    db, selection = reloaded.Database, reloaded.VoiceSelection
    Equal(db:GetSingleVoiceAssignment(), assignments.CHARACTER, "Assignment survives module reload")
    Equal(db:GetSingleVoice(), 9, "Character selection survives module reload")
    Equal(global.singleVoice, 10, "Global selection survives module reload")
    db:ResetCharacterSingleVoice()
    Equal(character1.singleVoice, nil)
    Equal(db:HasCharacterSingleVoice(), false)
    Equal(db:GetSingleVoice(), 10, "Reset restores inheritance")
    local resetReload = Open(character1)
    Equal(resetReload.Database:HasCharacterSingleVoice(), false, "Reset survives module reload")
    Equal(resetReload.Database:GetSingleVoice(), 10)
    Equal(character2.singleVoice, 0, "Reset affects only this character")
    db:SetSingleVoiceAssignment(assignments.ALL)
    db:SetSingleVoice(originalGlobal)
    db:SetSingleVoiceAssignment(assignments.CHARACTER)
    Equal(db:GetSingleVoice(), originalGlobal, "Reset inherits later global edits")
    Equal(character1.singleVoice, nil)
    db:SetSingleVoice(originalGlobal)
    Equal(db:HasCharacterSingleVoice(), true, "Selecting the global value still creates an explicit override")
    db:SetSingleVoiceAssignment(assignments.ALL)
    db:SetSingleVoice(10)
    db:SetSingleVoiceAssignment(assignments.CHARACTER)
    Equal(db:GetSingleVoice(), originalGlobal, "Equal-valued overrides are not dynamic inheritance")
    db:SetSingleVoice(nil)
    Equal(db:GetSingleVoice(), 10, "Not set clears the override and inherits")
    db:SetSingleVoice(999)
    local voice, info = selection:ResolvePlayer()
    Equal(voice, nil)
    Equal(info.reason, "single-voice-unavailable", "Unavailable override is retained, not silently replaced")
    Equal(character1.singleVoice, 999)

    db:SetVoiceMode("raceGender")
    Equal(selection:Resolve("questnpc", { GetModelFileID = function() return 959310 end }), 31,
        "Multiple Voices ignores narrator assignment")
    Equal(global.voices, familyTable, "Family settings are preserved")
    Equal(global.speechRate, client == "Forever" and 3 or 4)
    Equal(environment[otherKey], otherCharacter, "Other client character storage is untouched")
    Equal(otherCharacter.singleVoice, 31)
    Equal(environment[otherSaved], otherGlobal, "Other client's global table is untouched")
    Equal(otherGlobal.singleVoice, otherVoice)
    Equal(otherGlobal.singleVoiceAssignment, otherAssignment)
    db:SetSingleVoiceAssignment("invalid")
    Equal(db:GetSingleVoiceAssignment(), assignments.ALL)
    Equal(character1.singleVoice, 999, "Normalization cannot erase an override")
    db:SetSingleVoiceAssignment(assignments.CHARACTER)
    local final = Open(character1)
    Equal(final.Database:GetSingleVoice(), 999)
    Equal(final.Database:GetVoiceMode(), "raceGender")
    Equal(final.Database.DB.singleVoice, 10)
    -- Missing saved files receive an empty character table, never a copy of global settings.
    local fresh = Open(nil)
    Equal(fresh.Database:HasCharacterSingleVoice(), false)
    Equal(fresh.Database:GetSingleVoice(), 10)
    Equal(next(fresh.Database.CharacterDB), nil)

    local toc = Read(client == "Forever" and "OutLoud_Forever.toc" or "OutLoud_Mainline.toc")
    assert(toc:find("## SavedVariables: " .. saved .. "\n", 1, true))
    assert(toc:find("## SavedVariablesPerCharacter: " .. characterSaved .. "\n", 1, true))
end
Equal(globals.OutLoudDB.singleVoice, 10)
Equal(globals.OutLoudRetailDB.singleVoice, 10)
local ui = Read("UI/SettingsPage.lua")
local section = assert(ui:match("function SettingsPage:CreateVoiceAssignmentSection%(%)\n(.-)\nfunction SettingsPage:RefreshVoiceAssignment"))
local _, dropdowns = section:gsub("ComboBox:New%(", "")
Equal(dropdowns, 1, "Reuse one narrator dropdown")
for _, label in ipairs({ '"Voice Assignment"', '"All Characters"', '"Per Character"', '"Reset to Global"' }) do
    assert(section:find(label, 1, true), "Required settings label: " .. label)
end
for _, setter in ipairs({ "SetSingleVoiceAssignment(assignment)", "SetSingleVoice(voiceID)", "ResetCharacterSingleVoice()" }) do
    local _, setterEnd = section:find(setter, 1, true)
    assert(setterEnd and section:sub(setterEnd + 1):match("^%s+self:RefreshVoiceAssignment%(%)"),
        "Immediately refresh after " .. setter)
end
assert(ui:find("return OutLoud.Database:GetSingleVoice()", 1, true), "Dropdown reads the effective narrator")
assert(ui:find("SetEnabled(single and character and OutLoud.Database:HasCharacterSingleVoice())", 1, true),
    "Reset is enabled only for an active character override")
print("PASS: narrator inheritance, overrides/reset, switching, saved-table reloads, character/client isolation, resolver and static UI/TOC checks")
