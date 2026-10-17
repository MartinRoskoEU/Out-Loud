-- Run from the addon root with standalone Lua 5.1 only when approved.
-- Production source/coordinator logic with supplied visibility/page predicates
-- and call recorders. No frames, events, animations, native queue or timing run.
local function Equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end

local function Harness(client, auto)
    local test = { shown = { Quest = true, Gossip = true, Item = true, Log = true },
        details = true, greeting = true, goodbye = true, stage = "GetQuestText",
        page = 1, text = "First page.", gossipText = "First response.",
        timers = {}, stops = {}, hides = {}, speaks = {}, presentations = {}, turns = 0 }
    local environment = setmetatable({
        UnitExists = function() return true end,
        UnitName = function() return "Supplied speaker" end,
        UnitFactionGroup = function() return "Alliance" end,
        GetQuestID = function() return 42 end,
        GetQuestText = function() return "Quest detail." end,
        GetProgressText = function() return "Quest progress." end,
        GetRewardText = function() return "Quest reward." end,
        GetQuestLogQuestText = function() return "Quest description." end,
        C_QuestLog = {
            GetSelectedQuest = function() return 42 end,
            GetLogIndexForQuestID = function() return 1 end,
            GetTitleForQuestID = function() return "Quest title" end,
        },
        C_GossipInfo = { GetText = function() return test.gossipText end },
        ItemTextGetItem = function() return "Book" end,
        ItemTextGetPage = function() return test.page end,
        ItemTextGetText = function() return test.text end,
        ItemTextHasNextPage = function() return true end,
        ItemTextNextPage = function() test.turns = test.turns + 1 end,
        C_Timer = { NewTimer = function(_, callback)
            local timer = { callback = callback }
            function timer:Cancel() self.cancelled = true end
            test.timers[#test.timers + 1] = timer
            return timer
        end },
        CreateFrame = function() error("Source closure checks must not construct frames") end,
    }, { __index = _G })
    environment._G = environment
    environment.OutLoudDB = { autoNarrateQuests = auto }
    environment.OutLoudRetailDB = { autoNarrateQuests = auto }
    local head = { State = "Closed", Frame = { IsShown = function() return true end } }
    local addon = { UI = { TalkingHead = head }, TTS = {}, Database = {}, VoiceSelection = {},
        NPCInspection = { LoadUnit = function() return {} end }, Debug = function() end }
    function addon:Error(...) error(table.concat({ ... }, " ")) end
    addon.VoiceSelection.AssignmentModes = { SINGLE = "single", RACE_GENDER = "raceGender" }
    function addon.VoiceSelection:IsSingleVoiceMode() return false end
    function addon.VoiceSelection:Resolve() return 7, {} end
    function addon.VoiceSelection:ResolvePlayer() return 7, {} end
    function addon.TTS:Stop(reason) test.stops[#test.stops + 1] = reason or "manual" end
    function addon.TTS:Speak(...)
        test.speaks[#test.speaks + 1] = { ... }
        return true
    end
    function head:Initialize() end
    function head:Show(...)
        test.presentations[#test.presentations + 1] = { ... }
        return true
    end
    function head:Hide(...) test.hides[#test.hides + 1] = { ... } end
    function head:FinishTextPlayback() end
    for _, path in ipairs({ "Clients/" .. client .. "/Config.lua", "Core/Database.lua", "Core/Narration.lua",
        "UI/QuestIntegration.lua", "UI/GossipIntegration.lua", "UI/ItemTextIntegration.lua",
        "UI/QuestLogIntegration.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
    addon.Database:Initialize()
    local function Visibility(key)
        return { IsShown = function() return test.shown[key] end,
            IsVisible = function() return test.shown[key] end }
    end
    local quest, gossip = addon.UI.QuestIntegration, addon.UI.GossipIntegration
    local item, log = addon.UI.ItemTextIntegration, addon.UI.QuestLogIntegration
    quest.Frame, quest.Model = Visibility("Quest"), {}
    quest.GreetingPanel = { IsShown = function() return false end }
    quest.Panels = {}
    for _, source in ipairs({ "GetQuestText", "GetProgressText", "GetRewardText" }) do
        quest.Panels[#quest.Panels + 1] = { textSource = source,
            frame = { IsShown = function() return test.stage == source end } }
    end
    gossip.Frame = Visibility("Gossip")
    gossip.GreetingPanel = { IsShown = function() return test.greeting end }
    gossip.GoodbyeButton = { IsShown = function() return test.goodbye end }
    item.Frame = Visibility("Item")
    log.Frame = Visibility("Log")
    log.DetailsFrame = { questID = 42, IsVisible = function() return test.details end }
    log.TextScrollFrame = { IsVisible = function() return test.details end }
    log.BackButton = { IsVisible = function() return test.details end }
    test.sources = { Quest = quest, Gossip = gossip, Item = item, Log = log }
    test.addon, test.narration, test.head = addon, addon.Narration, head
    function test:SetAutoPlay(key, value)
        local source = self.sources[key].SettingsSource
        addon.Database:SetAutoPlay(source, value)
        -- Supply the post-hook notification; native hooks are inspected statically.
        for _, owner in pairs(self.sources) do
            if owner.OnAutoPlayChanged then owner:OnAutoPlayChanged(source) end
        end
    end
    function test:Start(key, pending)
        if key == "Item" then item:OnReady() end
        self.sources[key]:SpeakCurrentText()
        local request = self.narration.Narration
        Equal(request.owner, self.sources[key], "Speech captures explicit source ownership")
        if not pending then
            -- Supply presentation state, without running opening/closing animations.
            head.State, head.Transition = "Opening", {}
            self.narration:Submit(request, head.Transition)
        end
        return request
    end
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

Test("Every source closes active manual and automatic narration through normal STOP", function(client)
    for _, auto in ipairs({ false, true }) do
        for _, key in ipairs({ "Quest", "Gossip", "Item", "Log" }) do
            local test = Harness(client, auto)
            local owner = test.sources[key]
            if auto and key == "Quest" then
                owner:ScheduleAutoNarration("QUEST_DETAIL")
                test.timers[1].callback()
            elseif auto and key == "Gossip" then
                owner:Refresh()
                test.timers[1].callback()
            elseif auto and key == "Item" then
                owner:OnReady()
                test.timers[1].callback()
            else
                test:Start(key, true)
            end
            local request = test.narration.Narration
            Equal(request.owner, owner)
            test.head.State, test.head.Transition = "Opening", {}
            test.narration:Submit(request, test.head.Transition)
            local callback, hides = test.speaks[1][3], #test.hides
            test.shown[key] = false
            owner:OnHidden()
            Equal(test.narration.Narration, nil)
            Equal(#test.hides, hides + 1, "Use the existing presentation close entry point")
            Equal(request.ended, true)
            local reason = test.hides[#test.hides][1]
            test.narration:OnClosing(reason) -- explicitly supply the existing close notification
            Equal(test.stops[#test.stops], reason, "Close notification forwards native cancellation")
            callback("finished")
            Equal(test.turns, 0, "Stale completion cannot turn a closed book's page")
            owner:OnHidden()
            Equal(#test.hides, hides + 1, "Duplicate closure cannot issue another STOP")
        end
    end
end)

Test("Closure cancels delayed Auto Play and pre-readiness item activation", function(client)
    for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
        local test = Harness(client, true)
        local owner = test.sources[key]
        if key == "Quest" then owner:ScheduleAutoNarration("QUEST_DETAIL")
        elseif key == "Gossip" then owner:Refresh()
        else owner:OnReady() end
        local timer = test.timers[1]
        test.shown[key] = false
        owner:OnHidden()
        Equal(timer.cancelled, true)
        timer.callback()
        Equal(test.narration.Narration, nil)
        Equal(#test.presentations, 0)
        Equal(#test.stops, 0, "No unrelated native STOP for an unstarted delay")
    end
    local test = Harness(client, true)
    test.sources.Item:OnEvent("ITEM_TEXT_BEGIN")
    test.shown.Item = false
    test.sources.Item:OnHidden()
    test.sources.Item:OnReady()
    Equal(test.sources.Item.AutoPlayPending, nil)
    Equal(#test.timers, 0)
end)

Test("Closure cancels a request waiting for an earlier presentation to close", function(client)
    for _, key in ipairs({ "Quest", "Gossip", "Item", "Log" }) do
        local test = Harness(client, false)
        test.head.State = "Closing"
        local request = test:Start(key, true)
        Equal(request.submitted, nil)
        test.shown[key] = false
        test.sources[key]:OnHidden()
        Equal(request.ended, true)
        test.head.State = "Closed"
        test.narration:OnClosed()
        Equal(#test.presentations, 0, "Cancelled request cannot reopen after closing finishes")
        Equal(#test.speaks, 0)
    end
end)

Test("Late closure from any outgoing source preserves every other owner", function(client)
    for _, outgoing in ipairs({ "Quest", "Gossip", "Item", "Log" }) do
        for _, incoming in ipairs({ "Quest", "Gossip", "Item", "Log" }) do
            if outgoing ~= incoming then
                local test = Harness(client, false)
                test:Start(outgoing)
                local request = test:Start(incoming)
                local hides, stops = #test.hides, #test.stops
                test.shown[outgoing] = false
                test.sources[outgoing]:OnHidden()
                Equal(test.narration.Narration, request)
                Equal(#test.hides, hides)
                Equal(#test.stops, stops)
            end
        end
    end
end)

Test("Stale closure cannot discard another source's pending Auto Play", function(client)
    local test = Harness(client, true)
    test.sources.Quest:ScheduleAutoNarration("QUEST_DETAIL")
    test.shown.Gossip = false
    test.sources.Gossip:OnHidden()
    Equal(test.timers[1].cancelled, nil)
    test.timers[1].callback()
    Equal(test.narration.Narration.owner, test.sources.Quest)
end)

Test("Outgoing closure preserves a new owner still waiting for presentation", function(client)
    local test = Harness(client, false)
    test:Start("Quest")
    test.head.State = "Closing"
    local incoming = test:Start("Gossip", true)
    test.shown.Quest = false
    test.sources.Quest:OnHidden()
    Equal(test.narration.Narration, incoming)
    Equal(incoming.submitted, nil)
    test.head.State = "Closed"
    test.narration:OnClosed()
    Equal(test.presentations[#test.presentations][2], incoming.text)
end)

Test("Visible source refreshes preserve gossip navigation and quest stage replacements", function(client)
    local test = Harness(client, false)
    local gossip = test.sources.Gossip
    local request = test:Start("Gossip")
    test.greeting, test.goodbye = false, false
    gossip:Refresh()
    gossip:OnHidden() -- stale notification while the containing dialogue is still shown
    Equal(test.narration.Narration, request)
    test.greeting, test.goodbye, test.gossipText = true, true, "Submenu response."
    gossip:Refresh()
    request = test:Start("Gossip")
    gossip:OnHidden()
    Equal(test.narration.Narration, request)
    for _, stage in ipairs({ "GetQuestText", "GetProgressText", "GetRewardText" }) do
        test.stage = stage
        request = test:Start("Quest")
        test.sources.Quest:OnHidden()
        Equal(test.narration.Narration, request)
    end
end)

Test("Quest Log Back/detail closure stops only its request", function(client)
    local test = Harness(client, false)
    local request = test:Start("Log")
    test.sources.Log:OnHidden()
    Equal(test.narration.Narration, request, "Visible details preserve selection changes")
    test.details = false
    test.sources.Log:OnHidden()
    Equal(test.narration.Narration, nil)
end)

Test("Item page changes retain manual interruption and automatic continuation", function(client)
    local test = Harness(client, false)
    local item = test.sources.Item
    test:Start("Item")
    local oldEnded = test.speaks[1][3]
    item:OnManualNavigation(1)
    test.page, test.text = 2, "Second page."
    item:OnReady()
    local request = test.narration.Narration
    item:OnHidden()
    item:OnEvent("ITEM_TEXT_CLOSED") -- ignored if the frame has already reopened/is still shown
    Equal(test.narration.Narration, request)
    Equal(item.Reading.current.page.number, 2)
    oldEnded("finished")
    Equal(test.turns, 0)
    test.head.State, test.head.Transition = "Opening", {}
    test.narration:Submit(request, test.head.Transition)
    local current = item.Reading.current
    -- Supply completion after the coordinator has relinquished the finished request.
    test.narration.Narration = nil
    item:OnPageEnded(item.Reading, current, "finished")
    Equal(test.turns, 1)
    test.page, test.text = 3, "Third page."
    item:OnReady()
    Equal(test.narration.Narration.owner, item)
    Equal(item.Reading.current.page.number, 3)
    test.shown.Item = false
    item:OnHidden()
    item:OnEvent("ITEM_TEXT_CLOSED")
    Equal(item.Reading, nil)
    Equal(test.narration.Narration, nil)
end)

Test("Source STOP preserves a reentrant replacement and generic STOP leaves source UI alone", function(client)
    local test = Harness(client, false)
    local request = test:Start("Quest")
    request.onRequestEnded = function() test:Start("Gossip") end
    test.shown.Quest = false
    test.sources.Quest:OnHidden()
    Equal(test.narration.Narration.owner, test.sources.Gossip)
    test.narration:Stop("manual")
    Equal(test.shown.Gossip, true)
    Equal(test.narration.Narration, nil)
    test:Start("Log")
    test.narration:StopSource(nil, "stale")
    Equal(test.narration.Narration.owner, test.sources.Log)
    test.narration.Narration.source = "Quest"
    test.narration:StopSource(test.sources.Quest, "stale")
    Equal(test.narration.Narration.owner, test.sources.Log, "Diagnostic labels do not confer ownership")
end)

Test("Item closure cancels its accepted request even after continuation was cleared", function(client)
    local test = Harness(client, false)
    test:Start("Item")
    test.sources.Item:CancelReading("stopped", false)
    Equal(test.sources.Item.Reading, nil)
    test.shown.Item = false
    test.sources.Item:OnHidden()
    Equal(test.narration.Narration, nil)
end)

local function Schedule(test, key)
    local owner = test.sources[key]
    if key == "Quest" then owner:ScheduleAutoNarration("QUEST_DETAIL")
    elseif key == "Gossip" then owner:Refresh()
    else owner:OnReady() end
end

Test("Each Auto Play switch independently gates activation and preserves manual playback", function(client)
    for _, enabledKey in ipairs({ "Quest", "Gossip", "Item" }) do
        local test = Harness(client, false)
        test:SetAutoPlay(enabledKey, true)
        for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
            Schedule(test, key)
            Equal(test.sources[key].PendingAutoNarration ~= nil, key == enabledKey)
        end
        test.timers[1].callback()
        Equal(test.narration.Narration.owner, test.sources[enabledKey])
        for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
            test:SetAutoPlay(key, false)
            local request = test:Start(key, true)
            Equal(request.owner, test.sources[key], "Manual playback bypasses source Auto Play")
        end
    end
end)

Test("Disabling one source cancels only its delay and rejects stale callbacks", function(client)
    for _, disabled in ipairs({ "Quest", "Gossip", "Item" }) do
        local test, pending = Harness(client, true), {}
        for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
            Schedule(test, key)
            pending[key] = test.sources[key].PendingAutoNarration
        end
        test:SetAutoPlay(disabled, false)
        for key, request in pairs(pending) do
            if key == disabled then
                Equal(test.sources[key].PendingAutoNarration, nil)
                -- Keep the supplied callback after production clears request.timer.
            else
                Equal(test.sources[key].PendingAutoNarration, request)
                Equal(request.timer.cancelled, nil)
            end
        end
        local index = disabled == "Quest" and 1 or disabled == "Gossip" and 2 or 3
        Equal(test.timers[index].cancelled, true)
        test.timers[index].callback()
        Equal(test.narration.Narration, nil)
    end
end)

Test("Auto Close is independent for each source and retains captured requests when disabled", function(client)
    for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
        for _, enabled in ipairs({ false, true }) do
            for _, pending in ipairs({ false, true }) do
                local test = Harness(client, false)
                test.addon.Database:SetAutoClose(test.sources[key].SettingsSource, enabled)
                local request = test:Start(key, pending)
                local hides, stops = #test.hides, #test.stops
                test.shown[key] = false
                test.sources[key]:OnHidden()
                if enabled then
                    Equal(test.narration.Narration, nil)
                    Equal(request.ended, true)
                else
                    Equal(test.narration.Narration, request)
                    Equal(request.ended, nil)
                    Equal(#test.hides, hides)
                    Equal(#test.stops, stops)
                    if pending then
                        test.head.State = "Closed"
                        test.narration:OnClosed()
                        Equal(test.presentations[#test.presentations][2], request.text)
                    end
                    if key == "Item" then
                        Equal(test.sources.Item.Reading, nil, "Closed books relinquish continuation only")
                    end
                    test.narration:Stop(nil, "Talking Head close")
                    Equal(test.narration.Narration, nil, "Explicit closure/STOP stays unconditional")
                end
            end
        end
    end
end)

Test("Closing with Auto Close off still cancels unaccepted automatic activation", function(client)
    for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
        local test = Harness(client, true)
        test.addon.Database:SetAutoClose(test.sources[key].SettingsSource, false)
        Schedule(test, key)
        local timer = test.timers[1]
        test.shown[key] = false
        test.sources[key]:OnHidden()
        Equal(timer.cancelled, true)
        timer.callback()
        Equal(test.narration.Narration, nil)
        Equal(#test.hides, 0)
    end
end)

Test("Temporary item hides preserve manual and automatic deferred page readiness", function(client)
    for _, manual in ipairs({ false, true }) do
        local test = Harness(client, false)
        local item = test.sources.Item
        test:Start("Item")
        if manual then item:OnManualNavigation(1)
        else item:OnPageEnded(item.Reading, item.Reading.current, "finished") end
        local reading = item.Reading
        test.shown.Item = false
        item:OnHidden()
        Equal(item.Reading, reading)
        item:OnEvent("ITEM_TEXT_READY") -- not ready while still hidden
        Equal(item.Reading, reading)
        test.shown.Item, test.page, test.text = true, 2, "Second page."
        item:OnEvent("ITEM_TEXT_READY")
        Equal(item.Reading, reading)
        Equal(item.Reading.current.page.number, 2)
        item:OnEvent("ITEM_TEXT_CLOSED") -- stale closure after page readiness
        Equal(item.Reading, reading)
    end
end)

Test("Confirmed item closure clears deferred loading with either Auto Close setting", function(client)
    for _, enabled in ipairs({ false, true }) do
        local test = Harness(client, false)
        local item = test.sources.Item
        test.addon.Database:SetAutoClose("itemText", enabled)
        test:Start("Item")
        local ended = test.speaks[1][3]
        item:OnManualNavigation(1)
        test.shown.Item = false
        item:OnHidden()
        item:OnEvent("ITEM_TEXT_CLOSED")
        Equal(item.Reading, nil)
        Equal(item.Item, nil)
        test.page, test.text = 2, "Second page."
        item:OnReady()
        ended("finished")
        Equal(test.turns, 0)
        Equal(item.Reading, nil)
        Equal(item.PendingAutoNarration, nil)
    end
end)

Test("Disabling item activation cancels pending navigation but preserves ongoing readings", function(client)
    local test = Harness(client, false)
    local item = test.sources.Item
    item:OnReady()
    test:SetAutoPlay("Item", true)
    item:OnManualNavigation(1)
    test.page = 2
    item:OnManualNavigation(1)
    test:SetAutoPlay("Item", false)
    Equal(item.Reading.silent, true, "Cancel activation while preserving page navigation readiness")
    test.page, test.text = 3, "Third page."
    item:OnReady()
    Equal(test.narration.Narration, nil)
    test:Start("Item")
    item:OnManualNavigation(-1)
    local reading = item.Reading
    test:SetAutoPlay("Item", false)
    Equal(item.Reading, reading)
    test.page, test.text = 2, "Second page."
    item:OnReady()
    Equal(item.Reading.current.page.number, 2)
end)

Test("Silent item navigation never becomes source closure or automatic playback", function(client)
    local test = Harness(client, false)
    local item = test.sources.Item
    item:OnReady()
    local identity = item.Item
    item:OnManualNavigation(1)
    test.shown.Item = false
    item:OnHidden()
    Equal(item.Item, identity)
    Equal(item.Reading.silent, true)
    test.shown.Item, test.page, test.text = true, 2, "Second page."
    item:OnReady()
    Equal(item.Item, identity)
    Equal(item.Reading, nil)
    Equal(test.narration.Narration, nil)
    Equal(item.ReadyPage.number, 2)
end)

Test("Disabling Auto Play cancels only unsubmitted automatic requests from that source", function(client)
    for _, key in ipairs({ "Quest", "Gossip", "Item" }) do
        for _, submitted in ipairs({ false, true }) do
            local test = Harness(client, true)
            test.head.State = "Closing"
            Schedule(test, key)
            test.timers[1].callback()
            local request = test.narration.Narration
            Equal(request.automatic, true)
            if submitted then
                test.head.State, test.head.Transition = "Opening", {}
                test.narration:Submit(request, test.head.Transition)
            end
            test:SetAutoPlay(key, false)
            if submitted then
                Equal(test.narration.Narration, request, "Disabling activation leaves current speech alone")
            else
                Equal(test.narration.Narration, nil)
                test.head.State = "Closed"
                test.narration:OnClosed()
                Equal(#test.presentations, 0, "A cancelled automatic request cannot open later")
            end
            test:SetAutoPlay(key, true)
            request = test:Start(key, true)
            Equal(request.automatic, false)
            test:SetAutoPlay(key, false)
            Equal(test.narration.Narration, request, "Manual requests survive the source setting change")
            local incoming = test:Start("Log", true)
            test:SetAutoPlay(key, false)
            Equal(test.narration.Narration, incoming, "Settings cannot cancel a newer source")
        end
    end
end)

Test("Detached item completion and closure cannot affect a newer narration source", function(client)
    local test = Harness(client, false)
    test.addon.Database:SetAutoClose("itemText", false)
    test:Start("Item")
    local ended = test.speaks[1][3]
    test.shown.Item = false
    test.sources.Item:OnHidden()
    local incoming = test:Start("Gossip")
    local hides = #test.hides
    ended("finished")
    test.sources.Item:OnEvent("ITEM_TEXT_CLOSED")
    Equal(test.narration.Narration, incoming)
    Equal(test.turns, 0)
    Equal(#test.hides, hides)
end)

Test("Closed items can finish captured pending speech without advancing pages", function(client)
    for _, pending in ipairs({ false, true }) do
        local test = Harness(client, false)
        local item = test.sources.Item
        test.addon.Database:SetAutoClose("itemText", false)
        if pending then test.head.State = "Closing" end
        local request = test:Start("Item", pending)
        test.shown.Item = false
        item:OnEvent("ITEM_TEXT_CLOSED")
        Equal(test.narration.Narration, request)
        Equal(item.Reading, nil)
        if pending then
            test.head.State, test.head.Transition = "Opening", {}
            test.narration:Submit(request, test.head.Transition)
        end
        test.speaks[1][3]("finished")
        Equal(test.narration.Narration, nil)
        Equal(test.turns, 0)
        item:OnEvent("ITEM_TEXT_READY")
        Equal(item.Reading, nil)
        Equal(item.ReadyPage, nil)
    end
end)

Test("Cancelling an accepted Auto Play request preserves another source's delay", function(client)
    local test = Harness(client, true)
    test.head.State = "Closing"
    Schedule(test, "Quest")
    test.timers[1].callback()
    local request = test.narration.Narration
    Schedule(test, "Gossip")
    local pending, timer = test.sources.Gossip.PendingAutoNarration, test.timers[2]
    local stops, hides = #test.stops, #test.hides
    test:SetAutoPlay("Quest", false)
    Equal(request.ended, true)
    Equal(test.narration.Narration, nil)
    Equal(test.sources.Gossip.PendingAutoNarration, pending)
    Equal(timer.cancelled, nil)
    Equal(#test.stops, stops)
    Equal(#test.hides, hides)
    timer.callback()
    Equal(test.narration.Narration.owner, test.sources.Gossip)
end)

-- Static hook contracts: no UI construction or authoritative event ordering.
local function Read(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return source
end
for _, name in ipairs({ "Quest", "Gossip", "ItemText" }) do
    local source = Read("UI/" .. name .. "Integration.lua")
    local _, count = source:gsub('frame:HookScript%("OnHide", function%(%) self:OnHidden%(%) end%)', "")
    Equal(count, 1, name .. " uses one existing whole-frame close hook")
end
local log = Read("UI/QuestLogIntegration.lua")
assert(log:find('self:OnHidden()\n        self:UpdateButtonVisibility()', 1, true))
assert(log:find('panel:HookScript("OnHide", Refresh)', 1, true))
assert(log:find('hooksecurefunc("QuestMapFrame_CloseQuestDetails", Refresh)', 1, true))
for _, toc in ipairs({ "OutLoud_Forever.toc", "OutLoud_Mainline.toc" }) do
    local source = Read(toc):gsub("\\", "/")
    for _, module in ipairs({ "Core/Narration.lua", "UI/QuestIntegration.lua", "UI/GossipIntegration.lua",
        "UI/ItemTextIntegration.lua", "UI/QuestLogIntegration.lua" }) do
        assert(source:find(module, 1, true), toc .. " missing shared module " .. module)
    end
end
print("PASS: " .. passed .. " source closure logic checks in both clients plus static hook contracts; native UI/events/audio unverified")
