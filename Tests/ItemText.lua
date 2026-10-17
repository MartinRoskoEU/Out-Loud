-- Run from the addon root with Lua 5.1 only when explicitly requested.
-- Isolated item controller checks with supplied page data and call-recording doubles.
-- No native frame, event ordering, page loading, TTS queue or audio is simulated.
local LoadFile = assert(rawget(_G, "loadfile"), "Run tests with standalone Lua 5.1")

local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness(auto, delay)
    local test = { title = "Book", page = 3, text = "Third page. More text!", shown = true,
        hasNext = true, calls = {}, turns = 0, stops = 0, errors = 0,
        auto = auto, delay = delay or 0, timers = {} }
    local environment = setmetatable({
        ItemTextGetItem = function() return test.title end,
        ItemTextGetPage = function() return test.page end,
        ItemTextGetText = function() return test.text end,
        ItemTextHasNextPage = function() return test.hasNext end,
        ItemTextNextPage = function() test.turns = test.turns + 1 end,
        -- Record scheduling and supply callbacks explicitly; no clock is simulated.
        C_Timer = { NewTimer = function(seconds, callback)
            local timer = { seconds = seconds, callback = callback }
            function timer:Cancel() self.cancelled = true end
            test.timers[#test.timers + 1] = timer
            return timer
        end },
    }, { __index = _G })
    local addon = { UI = {}, Database = {}, VoiceSelection = {}, Narration = {} }
    function addon:Error() test.errors = test.errors + 1 end
    function addon.Database:GetAutoNarrateQuests() return test.auto end
    function addon.Database:GetAutoNarrationDelay() return test.delay end
    function addon.VoiceSelection:ResolvePlayer() return 7, {} end
    local narration = assert(LoadFile("Core/Narration.lua"))
    setfenv(narration, environment)
    narration("OutLoud", addon)
    function addon.Narration:Speak(...)
        local call = { ... }
        test.calls[#test.calls + 1] = call
        self.Narration = { onRequestEnded = call[7], owner = call[8], source = call[5] }
        return true
    end
    function addon.Narration:Stop()
        test.stops = test.stops + 1
        self.Narration = nil
    end
    local chunk = assert(LoadFile("UI/ItemTextIntegration.lua"))
    setfenv(chunk, environment)
    chunk("OutLoud", addon)
    local integration = addon.UI.ItemTextIntegration
    integration.Frame = { IsShown = function() return test.shown end }
    test.integration, test.addon, test.environment = integration, addon, environment
    return test
end

local passed = 0
local function Test(name, callback)
    local ok, reason = pcall(callback)
    assert(ok, name .. ": " .. tostring(reason))
    passed = passed + 1
end

Test("Manual reading starts on the displayed page using the player voice", function()
    local test = Harness(false)
    test.integration:OnReady()
    Equal(#test.calls, 0, "Wait for activation with automatic reading off")
    test.integration:SpeakCurrentText()
    Equal(#test.calls, 1)
    Equal(test.calls[1][1], "player")
    Equal(test.calls[1][2], test.text)
    Equal(test.calls[1][3], 7)
    Equal(test.calls[1][4], "Book")
    Equal(test.integration.Reading.current.page.number, 3)
    Equal(test.turns, 0, "Submission alone cannot turn a page")
end)

Test("Automatic item activation uses the configured shared delay once", function()
    for _, delay in ipairs({ 0, 2, 5 }) do
        local test = Harness(true, delay)
        test.integration:OnReady()
        if delay > 0 then
            Equal(#test.calls, 0, "No Narration request or Talking Head opening before activation")
            Equal(#test.timers, 1)
            Equal(test.timers[1].seconds, delay)
            test.integration:OnReady()
            Equal(#test.timers, 1, "Duplicate readiness cannot restart the delay")
            test.timers[1].callback()
            test.timers[1].callback()
        end
        Equal(#test.calls, 1)
        Equal(test.integration.PendingAutoNarration, nil)
        test.calls[1][7]("finished")
        Equal(test.turns, 1)
        test.page, test.text = 4, "Fourth page."
        test.integration:OnReady()
        Equal(#test.calls, 2, "Automatic page continuation has no extra activation delay")
        Equal(#test.timers, delay == 0 and 0 or 1)
    end
end)

Test("Cancelling or manually activating an item invalidates delayed Auto Play", function()
    for _, action in ipairs({ "stop", "close", "manual", "navigation", "disabled", "new-item" }) do
        local test = Harness(true, 2)
        test.integration:OnReady()
        local timer = test.timers[1]
        if action == "stop" then
            test.integration:OnTTSStop()
        elseif action == "close" then
            test.shown = false
            test.integration:OnHidden()
        elseif action == "manual" then
            test.integration:SpeakCurrentText()
            Equal(#test.calls, 1, "Manual activation bypasses the delay")
        elseif action == "navigation" then
            test.integration:OnManualNavigation(-1)
            test.page, test.text = 2, "Selected page."
            test.integration:OnReady()
            Equal(#test.calls, 1, "Manual navigation starts the selected page when ready")
        elseif action == "disabled" then
            test.auto = false
        else
            test.integration:OnEvent("ITEM_TEXT_BEGIN")
            test.integration:OnReady()
            Equal(#test.timers, 2)
        end
        local calls = #test.calls
        timer.callback()
        Equal(#test.calls, calls, "A cancelled or invalid activation cannot speak")
        if action == "new-item" then
            test.timers[2].callback()
            Equal(#test.calls, 1, "Only the new item's delayed activation is accepted")
        end
        Equal(test.turns, 0)
    end
end)

Test("Quest and item activation share scheduling and cancellation", function()
    local test = Harness(true, 2)
    test.environment.GetQuestID = function() return 42 end
    local chunk = assert(LoadFile("UI/QuestIntegration.lua"))
    setfenv(chunk, test.environment)
    chunk("OutLoud", test.addon)
    local quest, starts = test.addon.UI.QuestIntegration, 0
    function quest:GetCurrentText() return "Quest text.", nil, "GetQuestText" end
    function quest:StartCurrentNarration() starts = starts + 1 end
    quest:ScheduleAutoNarration("QUEST_DETAIL")
    Equal(starts, 0)
    Equal(test.timers[1].seconds, 2)
    quest:CancelPendingAutoNarration()
    Equal(test.timers[1].cancelled, true)
    test.timers[1].callback()
    Equal(starts, 0)
    quest:ScheduleAutoNarration("QUEST_DETAIL")
    test.timers[2].callback()
    Equal(starts, 1)
    test.delay = 0
    quest:ScheduleAutoNarration("QUEST_DETAIL")
    Equal(starts, 2, "Zero delay still activates quests immediately")
    Equal(#test.timers, 2)
end)

Test("Finished page waits for the expected ready page without collecting ahead", function()
    local test = Harness(true)
    test.integration:OnReady()
    local ended = test.calls[1][7]
    ended("finished")
    Equal(test.turns, 1)
    Equal(#test.calls, 1)
    ended("finished")
    Equal(test.turns, 1, "Duplicate completion cannot advance twice")
    test.integration:OnReady()
    Equal(#test.calls, 1, "Old page data cannot satisfy the pending turn")
    test.page, test.text = 4, "Fourth page."
    test.integration:OnReady()
    Equal(#test.calls, 2)
    Equal(test.calls[2][2], "Fourth page.")
    test.integration:OnReady()
    Equal(#test.calls, 2, "Duplicate readiness cannot restart the page")
    test.hasNext = false
    test.calls[2][7]("finished")
    Equal(test.integration.Reading, nil)
    Equal(test.turns, 1, "Last page completes naturally")
end)

Test("Manual navigation stops the old page and only reads the selected ready page", function()
    local test = Harness(false)
    test.integration:OnReady()
    test.integration:SpeakCurrentText()
    local oldEnded = test.calls[1][7]
    test.integration:OnManualNavigation(-1)
    Equal(test.stops, 1)
    Equal(test.integration.Reading.expectedPage, 2)
    oldEnded("finished")
    Equal(test.turns, 0, "The cancelled page cannot advance")
    test.integration:OnReady()
    Equal(#test.calls, 1, "Wait for selected-page readiness")
    test.page, test.text = 2, "Second page."
    test.integration:OnReady()
    Equal(#test.calls, 2)
    Equal(test.calls[2][2], "Second page.")
end)

Test("Page 2 to Prev page 1 preserves continuation after deferred Narration submission", function()
    for _, auto in ipairs({ false, true }) do
        local test = Harness(auto)
        test.page, test.text = 1, "First page."
        test.integration:OnReady()
        if not auto then test.integration:SpeakCurrentText() end
        local firstEnded = test.calls[1][7]
        test.integration:OnManualNavigation(1)
        test.page, test.text = 2, "Second page."
        test.integration:OnReady()
        local secondEnded = test.calls[2][7]
        test.integration:OnManualNavigation(-1)

        -- Exercise the production coordinator with supplied presentation state.
        -- No animations or native event/queue behavior are modeled here.
        local head = { State = "Closing", Frame = { IsShown = function() return true end } }
        function head:Initialize() end
        function head:Hide() end
        function head:FinishTextPlayback() end
        test.addon.UI.TalkingHead = head
        test.environment.UnitExists = function() return true end
        test.environment.UnitName = function() return "Player" end
        test.environment.UnitFactionGroup = function() return "Alliance" end
        test.addon.TTS = {}
        local calls = {}
        function test.addon.TTS:Stop(reason)
            if self.onStopRequested then self.onStopRequested(reason) end
            test.integration:OnTTSStop(reason)
        end
        function test.addon.TTS:Speak(...)
            -- Supplied controller notifications: production StartSession calls
            -- Stop("replaced") before its post-hook. This is not native event ordering.
            self:Stop("replaced")
            Equal(test.integration.Reading, test.reading, "Own startup STOP must preserve continuation")
            test.integration:OnTTSStartSession()
            Equal(test.integration.Reading, test.reading, "Own session startup must preserve continuation")
            calls[#calls + 1] = { ... }
            return true
        end
        local chunk = assert(LoadFile("Core/Narration.lua"))
        setfenv(chunk, test.environment)
        chunk("OutLoud", test.addon)

        test.page, test.text = 1, "First page."
        test.integration:OnReady()
        test.reading = test.integration.Reading
        Equal(#calls, 0, "Narration waits for the existing close to finish")
        Equal(test.integration.StartingPage, nil, "Speak's temporary guard has ended")
        local function SubmitPending()
            local request = test.addon.Narration.Narration
            assert(request and not request.submitted)
            head.State, head.Transition = "Opening", {}
            test.addon.Narration:Submit(request, head.Transition)
            Equal(test.integration.Reading, test.reading, "Deferred submission retains the book session")
        end
        SubmitPending()
        Equal(calls[1][1], "First page.")
        Equal(test.turns, 0, "Startup notifications cannot advance a page")
        calls[1][3]("finished")
        Equal(test.turns, 1, "Page 1 completion automatically advances to page 2")
        Equal(test.reading.expectedPage, 2)
        firstEnded("finished")
        secondEnded("finished")
        Equal(test.turns, 1, "Cancelled completions cannot advance again")
        for page = 2, 3 do
            head.State = "Closing"
            test.page, test.text, test.hasNext = page, "Page " .. page .. ".", page < 3
            test.integration:OnReady()
            SubmitPending()
            calls[page][3]("finished")
        end
        Equal(#calls, 3)
        Equal(test.turns, 2, "Continuation reaches the final page")
        Equal(test.integration.Reading, nil)
        Equal(test.errors, 0)
    end
end)

Test("Stop or closing invalidates pending page turns and old completions", function()
    for _, close in ipairs({ false, true }) do
        local test = Harness(true)
        test.integration:OnReady()
        local ended = test.calls[1][7]
        ended("finished")
        if close then
            test.shown = false
            test.integration:OnHidden()
        else
            test.integration:CancelReading("stopped", false)
        end
        test.page, test.text = 4, "Later page."
        test.integration:OnReady()
        ended("finished")
        Equal(#test.calls, 1)
        Equal(test.turns, 1)
        Equal(test.integration.Reading, nil)
    end
end)

Test("Explicit STOP and unrelated TTS startup still cancel continuation", function()
    for _, action in ipairs({ "stop", "foreign-start", "waiting-stop" }) do
        local test = Harness(true)
        test.integration:OnReady()
        local reading, ended = test.integration.Reading, test.calls[1][7]
        local request = test.addon.Narration.Narration
        test.addon.Narration.Submitting = request
        test.integration:OnTTSStop("replaced")
        Equal(test.integration.Reading, reading, "Own deferred startup is recognized")
        test.integration:OnTTSStartSession()
        Equal(test.integration.Reading, reading)
        if action == "foreign-start" then
            test.addon.Narration.Submitting = { onRequestEnded = request.onRequestEnded }
            test.integration:OnTTSStartSession()
        elseif action == "waiting-stop" then
            ended("finished")
            Equal(test.turns, 1)
            test.integration:OnTTSStop()
        else
            -- Explicit STOP is not a replacement notification, even while submitting.
            test.integration:OnTTSStop()
        end
        Equal(test.integration.Reading, nil)
        local turns = test.turns
        ended("finished")
        Equal(test.turns, turns, "Cancelled continuation cannot turn another page")
    end
end)

Test("Rapid navigation keeps only the latest expected page", function()
    local test = Harness(true)
    test.integration:OnReady()
    local ended = test.calls[1][7]
    test.integration:OnManualNavigation(1)
    test.page = 4
    test.integration:OnManualNavigation(1)
    Equal(test.integration.Reading.expectedPage, 5)
    test.text = "Intermediate page."
    test.integration:OnReady()
    Equal(#test.calls, 1)
    test.page, test.text = 5, "Selected page."
    test.integration:OnReady()
    Equal(#test.calls, 2)
    ended("finished")
    Equal(test.turns, 0)
    Equal(test.integration.Reading.current.page.number, 5)
end)

Test("STOP before initial readiness cancels automatic activation", function()
    local test = Harness(true)
    test.integration:OnEvent("ITEM_TEXT_BEGIN")
    test.integration:CancelReading("stopped", false)
    test.integration:OnReady()
    Equal(#test.calls, 0)
    Equal(test.integration.ReadyPage.number, 3, "The page is still available for manual activation")
    test.integration:SpeakCurrentText()
    Equal(#test.calls, 1)
end)

Test("New item identity prevents old callbacks even with identical titles", function()
    local test = Harness(true)
    test.integration:OnReady()
    local oldEnded = test.calls[1][7]
    local item = test.integration.Item
    test.integration:OnEvent("ITEM_TEXT_BEGIN")
    assert(test.integration.Item ~= item)
    test.integration:OnReady()
    Equal(#test.calls, 2)
    oldEnded("finished")
    Equal(test.turns, 0)
    Equal(test.integration.Reading.current.page.item, test.integration.Item)
end)

Test("Cancellation and voice failures cannot authorize page turns", function()
    local test = Harness(true)
    test.integration:OnReady()
    test.calls[1][7]("cancelled")
    Equal(test.turns, 0)
    Equal(test.integration.Reading, nil)
    test.integration:OnReady()
    Equal(#test.calls, 1, "Repeated ready data cannot undo STOP")
    function test.addon.VoiceSelection:ResolvePlayer() return nil, { reason = "voice-not-set" } end
    test.integration:SpeakCurrentText()
    Equal(test.integration.Reading, nil)
    Equal(#test.calls, 1)
    Equal(test.errors, 1)
end)

Test("Markup becomes readable text without changing the original page snapshot", function()
    local test = Harness(false)
    test.text = '<HTML><BODY><H1>Title</H1><P>A &amp; B.<BR/>Next &quot;line&quot;.</P></BODY></HTML>'
    test.integration:OnReady()
    Equal(test.integration.ReadyPage.text, 'Title A & B. Next "line".')
    Equal(test.integration.ReadyPage.rawText, test.text)
    test.integration:SpeakCurrentText()
    Equal(test.calls[1][2], 'Title A & B. Next "line".')
end)

print("PASS: " .. passed .. " isolated item narration checks; native ItemText/UI/audio unverified")
