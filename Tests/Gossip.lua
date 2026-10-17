-- Run from the addon root with standalone Lua 5.1.
-- Production controller/resolver checks with supplied dialogue data and call recorders.
-- No native frames, UI events, timer timing, models, TTS queue or audio are simulated.
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
local function Harness(client, auto, delay)
    local test = { auto = auto, delay = delay, text = "Hello there.", name = "Supplied NPC",
        shown = true, goodbye = true, quest = false, sex = 2, modelID = 959310,
        timers = {}, calls = {}, errors = 0, stops = 0 }
    local environment = setmetatable({
        UnitExists = function() return true end,
        UnitName = function(unit) return unit == "npc" and test.name or "Player" end,
        UnitRace = function() return "Human", "Human", 1 end,
        UnitSex = function(unit) return unit == "npc" and test.sex or 2 end,
        -- Record scheduling; callbacks below are explicitly supplied, not clock-driven.
        C_Timer = { NewTimer = function(seconds, callback)
            local timer = { seconds = seconds, callback = callback }
            function timer:Cancel() self.cancelled = true end
            test.timers[#test.timers + 1] = timer
            return timer
        end },
        -- Only the quest-visibility predicate is supplied, not a native frame.
        QuestFrame = { IsShown = function() return test.quest end },
    }, { __index = _G })
    environment._G = environment
    for _, key in ipairs({ "OutLoudDB", "OutLoudRetailDB" }) do
        environment[key] = { voices = { HUMAN = { [2] = 8 }, UNDEAD = { [2] = 7 } },
            singleVoice = 9, autoNarrateQuests = auto, autoNarrationDelay = delay }
    end
    local addon = { UI = {}, TTS = { GetVoices = function()
        return { { voiceID = 7 }, { voiceID = 8 }, { voiceID = 9 } }
    end }, Debug = function() end }
    function addon:Error() test.errors = test.errors + 1 end
    for _, path in ipairs({ "Clients/" .. client .. "/Config.lua", "Clients/" .. client .. "/VoiceMappings.lua",
        "Core/VoiceSelection.lua", "Core/Database.lua", "Core/Narration.lua", "UI/GossipIntegration.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    addon.Database:Initialize()
    addon.NPCInspection = { LoadUnit = function(_, unit)
        Equal(unit, "npc")
        return { GetModelFileID = function() return test.modelID end }
    end }
    -- Exercise speech forwarding only, without creating a presentation or native speech.
    function addon.Narration:Speak(...)
        test.calls[#test.calls + 1] = { ... }
        if test.onSpeak then test.onSpeak() end
        return true
    end
    function addon.Narration:Stop() test.stops = test.stops + 1 end
    local gossip = addon.UI.GossipIntegration
    function gossip:GetCurrentText()
        if test.shown and type(test.text) == "string" and test.text:find("%S") then return test.text end
    end
    gossip.GoodbyeButton = { IsShown = function() return test.goodbye end }
    test.gossip, test.addon = gossip, addon
    return test
end
local passed = 0
local function Test(name, callback)
    for _, client in ipairs({ "Forever", "Retail" }) do
        local ok, message = pcall(callback, client)
        assert(ok, client .. " " .. name .. ": " .. tostring(message))
    end
    passed = passed + 1
end
Test("Auto Play off preserves manual NPC narration", function(client)
    local test = Harness(client, false, 2)
    test.gossip:Refresh()
    test.gossip:Refresh()
    Equal(#test.timers, 0)
    Equal(#test.calls, 0)
    test.gossip:StartCurrentNarration()
    Equal(#test.calls, 1)
    Equal(test.calls[1][1], "npc")
    Equal(test.calls[1][2], test.text)
    Equal(test.calls[1][3], 7)
    Equal(test.calls[1][4], test.name)
    Equal(test.calls[1][5], "Gossip")
    Equal(test.calls[1][6], 959310)
    test.text = "Another response."
    test.gossip:Refresh()
    Equal(#test.timers, 0)
    test.gossip:StartCurrentNarration()
    Equal(#test.calls, 2)
end)
Test("Shared delay and repeated refresh/completion do not duplicate activation", function(client)
    for _, delay in ipairs({ 0, 2, 5 }) do
        local test = Harness(client, true, delay)
        test.gossip:Refresh()
        local dialogue = test.gossip.AutoNarrationDialogue
        test.gossip:Refresh()
        Equal(test.gossip.AutoNarrationDialogue, dialogue)
        Equal(#test.timers, delay == 0 and 0 or 1)
        if delay > 0 then
            Equal(#test.calls, 0)
            Equal(test.timers[1].seconds, delay)
            test.timers[1].callback()
            test.timers[1].callback()
        end
        Equal(#test.calls, 1)
        test.gossip:Refresh()
        Equal(#test.calls, 1)
        Equal(test.gossip.PendingAutoNarration, nil)
        test.text = "Next response."
        test.gossip:Refresh()
        test.gossip:Refresh()
        if delay > 0 then test.timers[2].callback() end
        Equal(#test.calls, 2, "Later gossip text uses the same activation path")
        test.text = "Hello there."
        test.gossip:Refresh()
        if delay > 0 then test.timers[3].callback() end
        Equal(#test.calls, 3, "Returning to previous text is a new dialogue change")
    end
end)
Test("Text/name changes and close cancel old callbacks; reopening can read again", function(client)
    local test = Harness(client, true, 2)
    test.gossip:Refresh()
    test.text = "Changed response."
    test.gossip:Refresh()
    Equal(test.timers[1].cancelled, true)
    test.timers[1].callback()
    Equal(#test.calls, 0)
    test.name = "Another NPC"
    test.gossip:Refresh()
    Equal(test.timers[2].cancelled, true)
    test.timers[2].callback()
    Equal(#test.calls, 0)
    test.shown = false
    test.gossip:OnHidden()
    Equal(test.timers[3].cancelled, true)
    test.timers[3].callback()
    Equal(#test.calls, 0)
    test.shown = true
    test.gossip:Refresh()
    test.timers[4].callback()
    Equal(#test.calls, 1)
    Equal(test.calls[1][2], "Changed response.")
    Equal(test.calls[1][4], "Another NPC")
    test.shown = false
    test.gossip:OnHidden()
    Equal(test.stops, 0, "Closing leaves an accepted narration snapshot alone")
end)
Test("Activation revalidates changed data even before a UI refresh", function(client)
    local test = Harness(client, true, 2)
    test.gossip:Refresh()
    test.text = "New text before refresh."
    test.timers[1].callback()
    Equal(#test.calls, 0)
    test.gossip:Refresh()
    test.timers[2].callback()
    Equal(#test.calls, 1)
end)
Test("Manual activation, cancellation and disabling cannot be undone by refresh", function(client)
    for _, action in ipairs({ "manual", "cancel", "disabled" }) do
        local test = Harness(client, true, 2)
        test.gossip:Refresh()
        if action == "manual" then
            test.gossip:StartCurrentNarration()
            Equal(#test.calls, 1, "Manual button bypasses the delay")
        else
            if action == "disabled" then test.addon.Database:SetAutoNarrateQuests(false) end
            -- Same production cancellation method used by STOP/other-source/settings post-hooks.
            test.gossip:OnTTSStop()
        end
        Equal(test.timers[1].cancelled, true)
        test.timers[1].callback()
        test.gossip:Refresh()
        Equal(#test.calls, action == "manual" and 1 or 0)
        Equal(#test.timers, 1, "Unchanged text cannot rearm a cancelled request")
    end
end)
Test("Finishing an old response preserves the next delay; interruption cancels it", function(client)
    local test = Harness(client, true, 0)
    test.gossip:Refresh()
    Equal(#test.calls, 1)
    test.addon.Database:SetAutoNarrationDelay(2)
    test.text = "Next response."
    test.gossip:Refresh()
    test.gossip:OnTTSStop("finished")
    Equal(test.timers[1].cancelled, nil)
    test.timers[1].callback()
    Equal(#test.calls, 2, "Natural completion cannot discard a subsequent dialogue")
    for _, reason in ipairs({ "manual", "replaced", "playback-failed" }) do
        test.text = "Response after " .. reason
        test.gossip:Refresh()
        local timer = test.timers[#test.timers]
        test.gossip:OnTTSStop(reason)
        Equal(timer.cancelled, true)
        timer.callback()
        test.gossip:Refresh()
        Equal(#test.calls, 2)
    end
end)
Test("Unreadable/hidden controls and quest dialogue do not auto-play", function(client)
    for _, condition in ipairs({ "empty", "hidden", "goodbye", "quest" }) do
        local test = Harness(client, true, 2)
        if condition == "empty" then test.text = "  "
        elseif condition == "hidden" then test.shown = false
        elseif condition == "goodbye" then test.goodbye = false
        else test.quest = true end
        test.gossip:Refresh()
        Equal(#test.timers, 0)
        Equal(#test.calls, 0)
    end
    local test = Harness(client, true, 2)
    test.gossip:Refresh()
    test.quest = true
    test.timers[1].callback()
    Equal(#test.calls, 0, "A quest appearing during the delay takes precedence")
    test.gossip:Refresh()
    Equal(test.gossip.PendingAutoNarration, nil)
    test.quest = false
    test.gossip:Refresh()
    test.timers[2].callback()
    Equal(#test.calls, 1, "Gossip can activate when returning from quest UI")
end)
Test("Single Voice and existing NPC fallback share the manual pipeline", function(client)
    for _, mode in ipairs({ "single", "unknown-model", "unknown-sex" }) do
        local test = Harness(client, true, 0)
        if mode == "single" then test.addon.Database:SetVoiceMode("single")
        elseif mode == "unknown-model" then test.modelID = 999999
        else test.sex = 1 end
        test.gossip:Refresh()
        Equal(test.calls[1][1], "player")
        Equal(test.calls[1][3], mode == "single" and 9 or 8)
        Equal(test.calls[1][4], test.name)
    end
end)
Test("Zero-delay reentrancy and unavailable voices do not retry unchanged text", function(client)
    local test = Harness(client, true, 0)
    test.onSpeak = function() test.gossip:Refresh() end
    test.gossip:Refresh()
    Equal(#test.calls, 1)
    test = Harness(client, true, 0)
    test.addon.Database:SetVoiceMode("single")
    test.addon.Database:SetSingleVoice(999)
    test.gossip:Refresh()
    test.gossip:Refresh()
    Equal(#test.calls, 0)
    Equal(test.errors, 1)
end)
-- Static hook/load-path contracts, without constructing frames or dispatching events.
local source = Read("UI/GossipIntegration.lua")
for _, hook in ipairs({
    'hooksecurefunc(frame, "Update", Refresh)', 'frame:HookScript("OnShow", Refresh)',
    'frame:HookScript("OnHide", function() self:OnHidden() end)',
    'hooksecurefunc(OutLoud.Database, "SetAutoNarrateQuests", function()',
    'hooksecurefunc(OutLoud.Narration, "Speak", function() self:CancelPendingAutoNarration() end)',
    'hooksecurefunc(OutLoud.Narration, "Stop", function() self:CancelPendingAutoNarration() end)',
    'hooksecurefunc(OutLoud.TTS, "Stop", function(_, reason) self:OnTTSStop(reason) end)',
    'hooksecurefunc(OutLoud.TTS, "StartSession", function() self:CancelPendingAutoNarration() end)',
    'OutLoud.Narration:ScheduleAutoNarration(self, dialogue,',
    'function() self:StartCurrentNarration() end)',
}) do assert(source:find(hook, 1, true), "Missing shared activation/cancellation hook: " .. hook) end
local _, speaks = source:gsub("OutLoud%.Narration:Speak%(", "")
Equal(speaks, 1, "One existing speech forwarding path")
assert(not source:find('RegisterEvent("GOSSIP_', 1, true), "No second gossip event activation path")
assert(not source:find('Client.ID', 1, true), "Shared behavior for both clients")
for _, toc in ipairs({ "OutLoud_Forever.toc", "OutLoud_Mainline.toc" }) do
    assert(Read(toc):gsub("\\", "/"):find("UI/GossipIntegration.lua", 1, true))
end
print("PASS: " .. passed .. " gossip controller checks in both clients plus static hook contracts; native UI/events/audio unverified")
