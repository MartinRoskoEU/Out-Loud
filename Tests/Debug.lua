-- Run from the addon root with Lua 5.1 only when explicitly requested.
-- Isolated slash-handler/logger checks; no native chat dispatch or UI is simulated.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness()
    local test = { messages = {}, saved = { debug = true, DebugEnabled = true } }
    local environment = setmetatable({ SlashCmdList = {}, OutLoudDB = test.saved }, { __index = _G })
    environment._G = environment
    environment.print = function(...) test.messages[#test.messages + 1] = { ... } end
    local addon = {}
    local function Load(path)
        local chunk = assert(LoadFile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    Load("Core/Namespace.lua")
    Load("Core/TTSDiagnostics.lua")
    addon:RegisterSlashCommands()
    test.addon, test.environment, test.Load = addon, environment, Load
    test.command = environment.SlashCmdList.OUTLOUD
    return test
end

local passed = 0
local function Test(name, callback)
    local ok, reason = pcall(callback)
    assert(ok, name .. ": " .. tostring(reason))
    passed = passed + 1
end

Test("Native command registration and default-off status", function()
    local test = Harness()
    Equal(test.environment.SLASH_OUTLOUD1, "/outloud")
    Equal(type(test.command), "function")
    Equal(test.addon.DebugEnabled, false, "Saved values cannot enable session debug")
    test.addon:Debug("Hidden message")
    test.addon.TTSDiagnostics:Record("hidden-event")
    Equal(#test.messages, 0)
    Equal(test.addon.TTSDiagnostics.count, 0)
    Equal(test.addon.TTSDiagnostics.sequence, 0)
    Equal(next(test.addon.TTSDiagnostics.entries), nil)
    test.command("debug")
    Equal(test.messages[1][1], "[Out Loud] Debug logging disabled.")
    Equal(test.addon.DebugEnabled, false, "Status query does not toggle logging")
end)

Test("Commands control the existing logger and recorder without persistence", function()
    local test = Harness()
    test.command("debug on")
    Equal(test.addon.DebugEnabled, true)
    Equal(test.messages[1][1], "[Out Loud] Debug logging enabled.")
    test.addon:Debug("Visible message")
    Equal(test.messages[2][1], "[Out Loud]")
    Equal(test.messages[2][2], "Visible message")
    test.addon.TTSDiagnostics:Record("visible-event")
    Equal(test.addon.TTSDiagnostics.count, 1)
    test.command("debug")
    Equal(test.messages[3][1], "[Out Loud] Debug logging enabled.")
    test.command("debug off")
    Equal(test.messages[4][1], "[Out Loud] Debug logging disabled.")
    local count = #test.messages
    test.addon:Debug("Hidden again")
    test.addon.TTSDiagnostics:Record("hidden-again")
    Equal(#test.messages, count)
    Equal(test.addon.TTSDiagnostics.count, 1)
    Equal(test.addon.TTSDiagnostics.sequence, 1)
    Equal(test.environment.OutLoudDB, test.saved)
    Equal(test.saved.debug, true)
    Equal(test.saved.DebugEnabled, true)
    local keys = 0
    for _ in pairs(test.saved) do keys = keys + 1 end
    Equal(keys, 2, "Commands add no SavedVariables keys")
end)

Test("Whitespace, repeated commands and invalid arguments preserve explicit state", function()
    local test = Harness()
    test.command("  DEBUG   ON  ")
    test.command("debug on")
    Equal(test.addon.DebugEnabled, true)
    for _, invalid in ipairs({ "", "other", "debug toggle", "debug off extra" }) do
        test.command(invalid)
        Equal(test.addon.DebugEnabled, true)
        Equal(test.messages[#test.messages][1], "[Out Loud] Usage: /outloud debug [on|off]")
    end
    test.command("debug off")
    test.command("debug off")
    Equal(test.addon.DebugEnabled, false)
end)

Test("Errors remain visible while debug is disabled", function()
    local test = Harness()
    test.addon:Error("Failure", 7)
    Equal(#test.messages, 1)
    Equal(test.messages[1][1], "|cffff0000[Out Loud] Failure 7|r")
    Equal(test.addon.DebugEnabled, false)
end)

Test("Narration does not send debug events to observers while disabled", function()
    local test = Harness()
    test.Load("Core/Narration.lua")
    local observed = 0
    test.addon.TTSDiagnostics.Record = function() observed = observed + 1 end
    local narration = test.addon.Narration
    narration.InternalStop = true
    narration.Narration = { id = 1, source = "Quest" }
    narration:OnClosing("manual")
    Equal(observed, 0)
    test.command("debug on")
    narration.Narration = { id = 2, source = "Quest" }
    narration:OnClosing("manual")
    Equal(observed, 1)
end)

Test("Module initialization resets session-only logging", function()
    local test = Harness()
    test.command("debug on")
    test.addon.TTSDiagnostics:Record("before-reinitialization")
    test.Load("Core/Namespace.lua")
    test.Load("Core/TTSDiagnostics.lua")
    Equal(test.addon.DebugEnabled, false)
    Equal(test.addon.TTSDiagnostics.count, 0)
    Equal(test.environment.OutLoudDB, test.saved)
    local count = #test.messages
    test.addon:Debug("Hidden after initialization")
    Equal(#test.messages, count)
end)

print("PASS: " .. passed .. " isolated debug command/logger checks; native slash dispatch unverified")
