-- Isolated production settings callbacks with scalar native-setting inputs.
-- Supplied value/enabled receivers are not frames or a simulated WoW UI.
-- Rendering, native widget interaction, persistence and audio remain unverified.
local LoadFile = assert(loadfile, "Run from the addon root using Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness(client)
    local test = { volume = 42, writes = {}, reads = 0, refreshCallbacks = 0, messages = {} }
    local environment = setmetatable({}, { __index = _G })
    environment.print = function(...) test.messages[#test.messages + 1] = { ... } end
    environment.C_TTSSettings = {
        GetSpeechVolume = function() test.reads = test.reads + 1; return test.volume end,
        SetSpeechVolume = function(value)
            test.writes[#test.writes + 1] = value
            test.volume = value
        end,
    }
    environment.GameFontNormal, environment.GameFontDisable = "normal", "disabled"
    environment.GameFontHighlightSmall, environment.GameFontDisableSmall = "description", "disabled-description"
    environment.CreateFrame = function() error("Logic checks must not construct frames") end
    local addon = {}
    for _, path in ipairs({ "Core/Namespace.lua", "Clients/" .. client .. "/Config.lua",
        "Core/TTS.lua", "UI/SettingsPage.lua" }) do
        local chunk = assert(LoadFile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    local page = addon.UI.SettingsPage
    -- Deliberately deliver a value-change callback even for programmatic refresh:
    -- the production guard must suppress writes regardless of widget behavior.
    page.TTSVolumeSlider = {
        SetValue = function(_, value)
            test.displayed = value
            test.refreshCallbacks = test.refreshCallbacks + 1
            page:OnTTSVolumeChanged(value)
        end,
        SetEnabled = function(_, enabled) test.enabled = enabled end,
    }
    page.TTSVolumeLabel = { SetFontObject = function(_, font) test.labelFont = font end }
    page.TTSVolumeDescription = { SetFontObject = function(_, font) test.descriptionFont = font end }
    test.page, test.environment, test.addon = page, environment, addon
    return test
end

local passed = 0
local function Test(name, callback)
    local ok, reason = pcall(callback)
    assert(ok, name .. ": " .. tostring(reason))
    passed = passed + 1
end

for _, client in ipairs({ "Forever", "Retail" }) do
    Test(client .. " display refresh follows native settings and never writes", function()
        local test = Harness(client)
        for _, value in ipairs({ 42, 0, 100, 67 }) do
            test.volume = value
            test.page:RefreshTTSVolume()
            Equal(test.displayed, value)
            Equal(test.enabled, true)
            Equal(test.labelFont, "normal")
            Equal(test.descriptionFont, "description")
            Equal(#test.writes, 0, "Opening/reopening must preserve native settings")
        end
        Equal(test.refreshCallbacks, 4, "Programmatic callback guard was exercised")
        Equal(test.page.SyncingTTSVolume, false)
    end)

    Test(client .. " user changes write once and refresh from native readback", function()
        local test = Harness(client)
        for index, value in ipairs({ 0, 100, 53 }) do
            test.page:OnTTSVolumeChanged(value)
            Equal(#test.writes, index, "Refresh must not write a second time")
            Equal(test.writes[index], value)
            Equal(test.displayed, value)
            Equal(test.addon.TTS:GetSpeechVolume(), value, "Playback shares the native value")
        end
        -- Read back what the native setter actually retained.
        test.environment.C_TTSSettings.SetSpeechVolume = function(value)
            test.writes[#test.writes + 1] = value
            test.volume = 39
        end
        test.page:OnTTSVolumeChanged(40)
        Equal(test.displayed, 39)
        Equal(#test.writes, 4)
        Equal(#test.messages, 0, "Volume logging remains opt-in")
        test.addon.DebugEnabled = true
        test.page:OnTTSVolumeChanged(40)
        Equal(test.messages[1][2], "TTS volume change: requested:")
        Equal(test.messages[1][3], 40)
        Equal(test.messages[2][2], "TTS volume refresh: native:")
        Equal(test.messages[2][3], "39", "Log native readback rather than the requested value")
    end)

    Test(client .. " missing APIs or invalid native values disable without writing", function()
        for _, configure in ipairs({
            function(test) test.environment.C_TTSSettings = nil end,
            function(test) test.environment.C_TTSSettings.GetSpeechVolume = nil end,
            function(test) test.environment.C_TTSSettings.GetSpeechVolume = true end,
            function(test) test.environment.C_TTSSettings.SetSpeechVolume = nil end,
            function(test) test.environment.C_TTSSettings.SetSpeechVolume = true end,
            function(test) test.volume = nil end,
            function(test) test.volume = "42" end,
            function(test) test.volume = -1 end,
            function(test) test.volume = 101 end,
            function(test) test.volume = 0 / 0 end,
        }) do
            local test = Harness(client)
            configure(test)
            test.page:RefreshTTSVolume()
            Equal(test.enabled, false)
            Equal(test.labelFont, "disabled")
            Equal(test.descriptionFont, "disabled-description")
            test.page:OnTTSVolumeChanged(10)
            Equal(#test.writes, 0)
        end
    end)

    Test(client .. " availability is rechecked after opening", function()
        local test = Harness(client)
        local native = test.environment.C_TTSSettings
        test.page:RefreshTTSVolume()
        test.environment.C_TTSSettings = nil
        test.page:OnTTSVolumeChanged(10)
        Equal(test.enabled, false)
        Equal(#test.writes, 0)
        test.environment.C_TTSSettings = native
        test.volume = 24
        test.page:RefreshTTSVolume()
        Equal(test.enabled, true)
        Equal(test.displayed, 24)
        Equal(#test.writes, 0)
    end)
end

print("PASS: " .. passed .. " isolated native-volume settings checks; native UI/audio unverified")
