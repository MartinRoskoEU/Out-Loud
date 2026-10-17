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
    local head = { State = "Closed", Frame = { IsShown = function() return true end } }
    local addon = { UI = { TalkingHead = head }, TTS = {}, Database = {}, VoiceSelection = {},
        NPCInspection = { LoadUnit = function() return {} end }, Debug = function() end }
    function addon:Error(...) error(table.concat({ ... }, " ")) end
    function addon.Database:GetAutoNarrateQuests() return auto end
    function addon.Database:GetAutoNarrationDelay() return 2 end
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
    for _, path in ipairs({ "Clients/" .. client .. "/Config.lua", "Core/Narration.lua",
        "UI/QuestIntegration.lua", "UI/GossipIntegration.lua", "UI/ItemTextIntegration.lua",
        "UI/QuestLogIntegration.lua" }) do
        local chunk = assert(loadfile(path))
        setfenv(chunk, environment)
        chunk("OutLoud", addon)
    end
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
