-- Approved isolated SavedVariables logic and static UI checks; no client runtime.
local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Open(client, globals)
    local environment = setmetatable(globals, { __index = _G })
    environment._G = environment
    local addon = { VoiceSelection = { AssignmentModes = { SINGLE = "single", RACE_GENDER = "raceGender" } } }
    for _, path in ipairs({ "Clients/" .. client .. "/Config.lua", "Core/Database.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    addon.Database:Initialize()
    return addon.Database
end

for _, client in ipairs({ "Forever", "Retail" }) do
    local saved = client == "Forever" and "OutLoudDB" or "OutLoudRetailDB"
    for _, legacy in ipairs({ false, true, "absent" }) do
        local voices = { HUMAN = { [2] = 7 } }
        local profile = { voices = voices, speechRate = 3, autoNarrationDelay = 4, unrelated = "kept" }
        if legacy ~= "absent" then profile.autoNarrateQuests = legacy end
        local globals = { [saved] = profile }
        local db = Open(client, globals)
        for _, source in ipairs(db.NarrationSources) do
            Equal(db:GetAutoPlay(source), legacy == true, "Legacy activation migrates to each source")
            Equal(db:GetAutoClose(source), true, "Close defaults preserve existing behavior")
        end
        Equal(profile.autoNarrateQuests, nil, "Retire the global preference after migration")
        Equal(db.DB, profile)
        Equal(profile.voices, voices)
        Equal(profile.speechRate, 3)
        Equal(profile.autoNarrationDelay, 4)
        Equal(profile.unrelated, "kept")
        db:SetAutoPlay("quest", false)
        db:SetAutoPlay("gossip", true)
        db:SetAutoClose("itemText", false)
        local play, close = profile.autoPlay, profile.autoClose
        profile.autoNarrateQuests = true -- stale legacy data must not overwrite newer values
        db = Open(client, globals)
        Equal(db:GetAutoPlay("quest"), false)
        Equal(db:GetAutoPlay("gossip"), true)
        Equal(db:GetAutoClose("itemText"), false)
        Equal(profile.autoPlay, play)
        Equal(profile.autoClose, close)
        db:SetAutoPlay("gossip", false)
        db:SetAutoPlay("itemText", false)
        Equal(db:HasAutoPlay(), false)
        db:SetAutoPlay("itemText", true)
        Equal(db:HasAutoPlay(), true, "Shared delay remains enabled for any active source")
        Equal(db:GetAutoPlay("quest"), false)
        Equal(db:GetAutoClose("quest"), true)
    end
    local profile = { autoNarrateQuests = true, autoPlay = { quest = false }, autoClose = { gossip = false } }
    local db = Open(client, { [saved] = profile })
    Equal(db:GetAutoPlay("quest"), false, "Partial source preferences win")
    Equal(db:GetAutoPlay("gossip"), true, "Missing sources inherit legacy preference")
    Equal(db:GetAutoPlay("itemText"), true)
    Equal(db:GetAutoClose("gossip"), false)
    Equal(db:GetAutoClose("quest"), true)
end

local globals = { OutLoudDB = { autoNarrateQuests = true }, OutLoudRetailDB = { autoNarrateQuests = false } }
local forever = Open("Forever", globals)
Equal(globals.OutLoudRetailDB.autoPlay, nil, "Forever does not migrate Retail")
local retail = Open("Retail", globals)
forever:SetAutoPlay("quest", false)
retail:SetAutoPlay("gossip", true)
forever:SetAutoClose("itemText", false)
Equal(forever:GetAutoPlay("gossip"), true)
Equal(retail:GetAutoPlay("quest"), false)
Equal(retail:GetAutoClose("itemText"), true, "Client profiles remain isolated")

local function Read(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return source
end
local ui = Read("UI/SettingsPage.lua")
for _, text in ipairs({ 'header.Title:SetText("Auto Play")', 'closeHeader.Title:SetText("Auto Close")',
    'delayLabel:SetText("Auto Play Delay")', 'header, "GetAutoPlay", "SetAutoPlay"',
    'closeHeader, "GetAutoClose", "SetAutoClose"', '{ key = "quest", label = "Quest" }',
    '{ key = "gossip", label = "Gossip" }', '{ key = "itemText", label = "Item Text" }',
    'self.AutoCloseDescription:SetWidth(descriptionWidth)' }) do
    assert(ui:find(text, 1, true), "Missing settings contract: " .. text)
end
assert(not ui:find("GetAutoNarrateQuests", 1, true))
assert(not ui:find("AutoNarrateQuestsCheckbox", 1, true))
for _, name in ipairs({ "Quest", "Gossip", "ItemText" }) do
    local source = Read("UI/" .. name .. "Integration.lua")
    assert(source:find('hooksecurefunc(OutLoud.Database, "SetAutoPlay", function(_, source)\n        self:OnAutoPlayChanged(source)', 1, true))
end
assert(not Read("UI/QuestLogIntegration.lua"):find("GetAutoClose", 1, true))
assert(not Read("UI/TalkingHead.lua"):find("GetAutoClose", 1, true))
print("PASS: per-source settings migration, reloads, partial preferences, client isolation, and static UI/hook contracts")
