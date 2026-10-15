-- Run from the addon root with Lua 5.1 only when explicitly requested.
-- Isolated coordinator predicates and calls using supplied presentation state.
-- No native frames, animations, events, timers, queue or audio are simulated.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness()
    local test = { calls = {}, presentations = {}, shown = true, hidden = 0, errors = 0 }
    local head = {
        State = "Closed",
        Frame = { IsShown = function() return test.shown end },
    }
    local addon = { UI = { TalkingHead = head }, TTS = {} }
    function addon:Error() test.errors = test.errors + 1 end
    function head:Show(speaker, text, onOpening)
        test.presentations[#test.presentations + 1] = { speaker, text, onOpening }
        return true
    end
    function head:Hide() test.hidden = test.hidden + 1 end
    function head:SetLoading(value) test.loading = value end
    function head:OnTextProgress(text) test.progress = text end
    function head:FinishTextPlayback(reason) test.finished = reason end
    function addon.TTS:Speak(...)
        test.calls[#test.calls + 1] = { ... }
        if test.onSpeak then test.onSpeak() end
        return true
    end
    function addon.TTS:Stop() error("Unexpected coordinator stop") end
    local environment = setmetatable({
        C_Timer = { NewTimer = function() error("Narration must not schedule submission") end },
    }, { __index = _G })
    local chunk = assert(LoadFile("Core/Narration.lua"))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
    test.head, test.addon, test.narration = head, addon, addon.Narration
    test.environment = environment
    test.request = { id = 1, speaker = {}, text = "First. Second.", voiceID = 7, source = "Quest" }
    test.narration.Narration = test.request
    return test
end

local passed = 0
local function Test(name, callback)
    local ok, reason = pcall(callback)
    assert(ok, name .. ": " .. tostring(reason))
    passed = passed + 1
end

Test("Opening callback submits immediately and only once", function()
    local test = Harness()
    test.narration:OnClosed()
    Equal(#test.calls, 0, "Wait for opening start")
    local presentation = test.presentations[1]
    Equal(presentation[1], test.request.speaker)
    Equal(presentation[2], test.request.text)
    local transition = {}
    test.head.State, test.head.Transition = "Opening", transition
    presentation[3](transition)
    Equal(#test.calls, 1, "Submit within the opening callback without a timer")
    Equal(test.calls[1][1], test.request.text)
    Equal(test.calls[1][2], 7)
    Equal(test.calls[1][6], "Quest")
    Equal(test.request.submitted, true)
    presentation[3](transition)
    Equal(#test.calls, 1, "Duplicate callback cannot submit twice")
end)

Test("Closing cannot open or submit a pending request", function()
    local test = Harness()
    test.head.State = "Closing"
    test.narration:OnClosed()
    Equal(#test.presentations, 0)
    Equal(#test.calls, 0)
    test.head.State = "Closed"
    test.narration:OnClosed()
    Equal(#test.presentations, 1, "Presentation is accepted only after closing")
end)

Test("Submission rejects stale ownership, transitions, phases and hidden state", function()
    local test = Harness()
    local transition = {}
    test.head.State, test.head.Transition = "Opening", transition
    test.narration:Submit(test.request, {})
    test.narration:Submit({}, transition)
    test.head.State = "Closing"
    test.narration:Submit(test.request, transition)
    test.head.State, test.shown = "Opening", false
    test.narration:Submit(test.request, transition)
    Equal(#test.calls, 0)
    test.shown = true
    test.narration:Submit(test.request, transition)
    Equal(#test.calls, 1)
end)

Test("Replacement notifications during submission preserve the incoming owner", function()
    local test = Harness()
    test.narration:Initialize()
    local transition = {}
    test.head.State, test.head.Transition = "Opening", transition
    test.onSpeak = function()
        test.addon.TTS.onStopRequested("replaced")
        test.narration:Submit(test.request, transition)
    end
    test.narration:Submit(test.request, transition)
    Equal(test.narration.Narration, test.request)
    Equal(#test.calls, 1, "Reentrant submission cannot duplicate speech")
    Equal(test.hidden, 0)
end)

Test("Presentation callbacks remain guarded after immediate submission", function()
    local test = Harness()
    local transition = {}
    test.head.State, test.head.Transition = "Opening", transition
    test.narration:Submit(test.request, transition)
    local call = test.calls[1]
    call[4]()
    Equal(test.loading, false)
    call[5]("First.", 1, 0)
    Equal(test.progress, "First.")
    test.narration.Narration = {}
    call[3]("finished")
    call[5]("Stale.", 2, 0)
    Equal(test.progress, "First.")
    Equal(test.hidden, 0)
    Equal(test.finished, nil)
end)

Test("Request completion notifies once after presentation cleanup", function()
    local test = Harness()
    local transition, ended = {}, 0
    test.head.State, test.head.Transition = "Opening", transition
    test.request.onRequestEnded = function(reason, requestID)
        Equal(reason, "finished")
        Equal(requestID, test.request.id)
        Equal(test.hidden, 1, "Begin closing before invoking the continuation")
        Equal(test.narration.Narration, nil)
        ended = ended + 1
    end
    test.narration:Submit(test.request, transition)
    test.calls[1][3]("finished")
    test.calls[1][3]("finished")
    Equal(ended, 1)
    Equal(test.request.onRequestEnded, nil, "Release callback ownership")
end)

Test("Stopping a pending request notifies cancellation once", function()
    local test = Harness()
    local ended = 0
    test.head.State = "Opening"
    test.request.onRequestEnded = function(reason)
        Equal(reason, "manual")
        ended = ended + 1
    end
    test.narration:Stop("manual")
    test.narration:Stop("manual")
    Equal(ended, 1)
    Equal(test.request.ended, true)
end)

Test("A reentrant request-end replacement keeps the newest request", function()
    for _, action in ipairs({ "replace", "stop" }) do
        local test = Harness()
        local stops = 0
        test.environment.UnitExists = function() return true end
        test.environment.UnitName = function() return "Player" end
        test.environment.UnitFactionGroup = function() return "Alliance" end
        function test.head:Initialize() end
        function test.addon.TTS:Stop() stops = stops + 1 end
        test.request.onRequestEnded = function()
            test.narration:Speak("player", "Newest.", 7)
        end
        if action == "replace" then
            test.narration:Speak("player", "Superseded.", 7)
        else
            test.narration:Stop("manual")
        end
        Equal(test.narration.Narration.text, "Newest.")
        Equal(stops, 1, "Superseded outer request cannot stop the newer request")
        Equal(#test.presentations, 1)
        Equal(test.presentations[1][2], "Newest.")
    end
end)

print("PASS: " .. passed .. " isolated narration coordinator checks; native UI and audio unverified")
