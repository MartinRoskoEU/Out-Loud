local AddonName, OutLoud = ...

local ItemTextIntegration = {}
OutLoud.UI.ItemTextIntegration = ItemTextIntegration

local function SamePage(first, second)
    return first and second and first.item == second.item and first.title == second.title
        and first.number == second.number and first.rawText == second.rawText
end

function ItemTextIntegration:NormalizeText(text)
    -- ItemTextPageText is SimpleHTML. Speak its content, not its layout tags.
    local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
    return (text:gsub("<[^>]+>", " "):gsub("&(%a+);", function(entity)
        return entities[entity] or ("&" .. entity .. ";")
    end):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function ItemTextIntegration:CapturePage()
    if not self.Frame or not self.Frame:IsShown() then return nil, "item-text-closed" end
    local title, number, text = ItemTextGetItem(), ItemTextGetPage(), ItemTextGetText()
    if type(title) ~= "string" or not title:find("%S") or type(number) ~= "number"
        or type(text) ~= "string" then return nil, "item-text-unavailable" end
    local normalized = self:NormalizeText(text)
    if not normalized:find("%S") then return nil, "empty-item-text" end
    return { item = self.Item, title = title, number = number, rawText = text, text = normalized }
end

function ItemTextIntegration:IsPageCurrent(page)
    return page and self.ReadyPage == page and self.Item == page.item and self.Frame:IsShown()
        and ItemTextGetItem() == page.title and ItemTextGetPage() == page.number
        and ItemTextGetText() == page.rawText
end

function ItemTextIntegration:UpdateButtonVisibility()
    if not self.Button then return end
    self.Button:SetShown(self:IsPageCurrent(self.ReadyPage) == true)
end

function ItemTextIntegration:CancelReading(reason, stopNarration)
    OutLoud.Narration:CancelAutoNarration(self)
    local reading = self.Reading
    self.Reading = nil
    self.AutoPlayPending = nil
    if not reading or not stopNarration then return end
    local request = OutLoud.Narration.Narration
    if request and reading.current and request.onRequestEnded == reading.current.onEnded then
        OutLoud.Narration:Stop(reason, "Item Text")
    end
end

function ItemTextIntegration:StartPage(reading, page)
    if self.Reading ~= reading or reading.item ~= self.Item or not self:IsPageCurrent(page) then return end
    local voiceID, info = OutLoud.VoiceSelection:ResolvePlayer()
    if voiceID == nil then
        self:CancelReading("voice-unavailable", false)
        OutLoud:Error("Item read stopped: choose an available player voice in Options:", info.reason)
        return
    end

    local current = { page = page }
    reading.current, reading.waiting, reading.expectedPage = current, nil, nil
    current.onEnded = function(reason)
        self:OnPageEnded(reading, current, reason)
    end
    -- Install ownership before Speak: submission and completion may be synchronous.
    local starting = self.StartingPage
    self.StartingPage = reading
    local called, ok, reason = pcall(OutLoud.Narration.Speak, OutLoud.Narration, "player", page.text, voiceID, page.title,
        "Item Text", nil, current.onEnded)
    self.StartingPage = starting
    if not called then
        if self.Reading == reading then self:CancelReading("lua-error", true) end
        OutLoud:Error("Item read failed with Lua error:", tostring(ok))
        return
    end
    if not ok and self.Reading == reading and reading.current == current then
        self:CancelReading(reason, false)
        OutLoud:Error("Item read stopped:", tostring(reason))
    end
end

function ItemTextIntegration:SpeakCurrentText()
    local page = self.ReadyPage
    if not self:IsPageCurrent(page) then return false, "item-text-not-ready" end
    self:CancelReading("replaced", true)
    local reading = { item = self.Item }
    self.Reading = reading
    self:StartPage(reading, page)
    return self.Reading == reading
end

function ItemTextIntegration:ScheduleAutoNarration(page)
    OutLoud.Narration:ScheduleAutoNarration(self, { page = page },
        function(pending) return self:IsPageCurrent(pending.page) end,
        function() self:SpeakCurrentText() end)
end

function ItemTextIntegration:OnPageEnded(reading, current, reason)
    if self.Reading ~= reading or reading.current ~= current then return end
    if reason ~= "finished" or not self:IsPageCurrent(current.page) then
        self:CancelReading(reason, false)
        return
    end
    reading.current = nil
    if not ItemTextHasNextPage() then
        self:CancelReading("finished", false)
        return
    end
    reading.waiting, reading.expectedPage = true, current.page.number + 1
    self.ReadyPage = nil
    self:UpdateButtonVisibility()
    -- Automatic turns call the API directly; native button PreClick hooks are manual only.
    local ok, message = pcall(ItemTextNextPage)
    if not ok and self.Reading == reading then
        self:CancelReading("page-turn-failed", false)
        OutLoud:Error("Item page turn failed:", tostring(message))
    end
end

function ItemTextIntegration:OnManualNavigation(direction)
    if not self.Frame:IsShown() then return end
    local resume = self.Reading ~= nil or OutLoud.Database:GetAutoNarrateQuests()
    local number = ItemTextGetPage()
    self:CancelReading("item-page-changed", true)
    self.ReadyPage = nil
    if resume and type(number) == "number" then
        self.Reading = { item = self.Item, waiting = true, expectedPage = number + direction }
    end
    self:UpdateButtonVisibility()
end

function ItemTextIntegration:OnReady()
    if not self.Frame:IsShown() then return end
    if not self.Item then
        self.Item, self.AutoPlayPending = {}, true
    end
    local page = self:CapturePage()
    if not page then
        self.ReadyPage = nil
        self:CancelReading("empty-item-text", true)
        self:UpdateButtonVisibility()
        return
    end
    local autoStart = not self.HasReady and self.AutoPlayPending and OutLoud.Database:GetAutoNarrateQuests()
    self.HasReady = true
    self.AutoPlayPending = nil
    local reading = self.Reading
    if reading and reading.waiting and page.number ~= reading.expectedPage then return end
    if SamePage(self.ReadyPage, page) then return end
    OutLoud.Narration:CancelAutoNarration(self)
    self.ReadyPage = page
    self:UpdateButtonVisibility()
    if reading and reading.item == self.Item and reading.waiting then
        self:StartPage(reading, page)
    elseif reading then
        -- Also catch native navigation that did not originate from a page button.
        self:CancelReading("item-page-changed", true)
        self.Reading = { item = self.Item }
        self:StartPage(self.Reading, page)
    elseif autoStart then
        self:ScheduleAutoNarration(page)
    end
end

function ItemTextIntegration:OnEvent(event)
    if event == "ITEM_TEXT_BEGIN" then
        self:CancelReading("item-changed", true)
        self.Item, self.ReadyPage, self.HasReady, self.AutoPlayPending = {}, nil, false, true
        self:UpdateButtonVisibility()
    elseif event == "ITEM_TEXT_READY" then
        self:OnReady()
    elseif event == "ITEM_TEXT_CLOSED" then
        self:OnHidden()
    end
end

function ItemTextIntegration:OnHidden()
    self:CancelReading("item-text-closed", true)
    self.Item, self.ReadyPage, self.HasReady, self.AutoPlayPending = nil, nil, nil, nil
    if self.Button then self.Button:Hide() end
end

function ItemTextIntegration:IsStartingPage()
    local reading = self.Reading
    if not reading then return false end
    if self.StartingPage == reading then return true end
    -- Speak may return while Talking Head closes. The coordinator owns the
    -- eventual submission, identified by this page's request-end callback.
    local narration = OutLoud.Narration
    local request, current = narration.Submitting, reading.current
    return request ~= nil and current ~= nil and request == narration.Narration
        and request.onRequestEnded == current.onEnded
end

function ItemTextIntegration:OnTTSStop(reason)
    if reason ~= "finished" and (reason ~= "replaced" or not self:IsStartingPage()) then
        self:CancelReading("stopped", false)
    end
end

function ItemTextIntegration:OnTTSStartSession()
    if not self:IsStartingPage() then self:CancelReading("replaced", false) end
end

function ItemTextIntegration:Initialize()
    if self.Initialized then return end
    local frame = rawget(_G, "ItemTextFrame")
    local scroll = rawget(_G, "ItemTextScrollFrame")
    local nextButton, prevButton = rawget(_G, "ItemTextNextPageButton"), rawget(_G, "ItemTextPrevPageButton")
    if not frame or not scroll or not nextButton or not prevButton then
        if not self.LoadFrame then
            self.LoadFrame = CreateFrame("Frame")
            self.LoadFrame:RegisterEvent("ADDON_LOADED")
            self.LoadFrame:SetScript("OnEvent", function() self:Initialize() end)
        end
        return
    end
    self.Frame = frame
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:Hide()
    button:SetSize(100, 22)
    button:SetFrameLevel(scroll:GetFrameLevel() + 3)
    button:SetText("Out Loud")
    button:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -8, 8)
    button:SetScript("OnClick", function()
        local ok, message = pcall(self.SpeakCurrentText, self)
        if not ok then
            self:CancelReading("lua-error", true)
            OutLoud:Error("Item read failed with Lua error:", tostring(message))
        end
    end)
    self.Button = button
    for _, control in ipairs({
        { nextButton, 1 }, { prevButton, -1 },
        { rawget(_G, "GamepadItemTextNextPageButton"), 1 },
        { rawget(_G, "GamepadItemTextPrevPageButton"), -1 },
    }) do
        local direction = control[2]
        if control[1] then
            control[1]:HookScript("PreClick", function() self:OnManualNavigation(direction) end)
        end
    end
    -- Runs after Blizzard has updated text, layout, page controls and frame visibility.
    frame:HookScript("OnEvent", function(_, event) self:OnEvent(event) end)
    frame:HookScript("OnHide", function() self:OnHidden() end)
    hooksecurefunc(OutLoud.Database, "SetAutoNarrateQuests", function()
        if not OutLoud.Database:GetAutoNarrateQuests() then
            OutLoud.Narration:CancelAutoNarration(self)
            self.AutoPlayPending = nil
        end
    end)
    hooksecurefunc(OutLoud.Narration, "Speak", function()
        local request = OutLoud.Narration.Narration
        if request and request.source ~= "Item Text" then self:CancelReading("replaced", false) end
    end)
    hooksecurefunc(OutLoud.Narration, "Stop", function() self:CancelReading("stopped", false) end)
    hooksecurefunc(OutLoud.TTS, "Stop", function(_, reason)
        self:OnTTSStop(reason)
    end)
    hooksecurefunc(OutLoud.TTS, "StartSession", function()
        self:OnTTSStartSession()
    end)
    self.Initialized = true
    if self.LoadFrame then
        self.LoadFrame:UnregisterEvent("ADDON_LOADED")
        self.LoadFrame:SetScript("OnEvent", nil)
    end
    if frame:IsShown() then self:OnReady() end
end
