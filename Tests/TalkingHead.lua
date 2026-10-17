-- Run from the addon root with standalone Lua 5.1.
-- Static source regression checks only; no production module or WoW API is run.
local function Read(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return source
end

local head = Read("UI/TalkingHead.lua")
local narration = Read("Core/Narration.lua")
local portrait = assert(head:match("    self%.Model:ClearModel%(%)\n(.-)    self%.Model:SetAnimation%(0, 0%)"),
    "Keep portrait preparation before the existing idle animation")
local binding = [[    if speaker.unit == "player" then
        self.Model:SetUnit("player")
    elseif speaker.unit and UnitExists(speaker.unit) then
        self.Model:SetUnit(speaker.unit)
    else
        -- The NPC may disappear while the previous presentation finishes closing.
        self.Model:Hide()
    end
]]
assert(portrait:find(binding, 1, true),
    "Rebind player/NPC sources explicitly; hide only an unavailable speaker")
local show = assert(portrait:find("self.Model:Show()", 1, true), "Restore a previously hidden portrait")
assert(show < portrait:find(binding, 1, true), "Show before rebinding the previous unit")
local _, unitCalls = head:gsub(":SetUnit%(", "")
assert(unitCalls == 2, "One shared player branch and one shared NPC branch")
-- Both SetUnit calls above stand alone: their return values cannot reject a hidden-parent load.
for _, removed in ipairs({ "SetModel", "modelFileID", "UnitGUID", "speaker.guid", "OnModelLoaded",
    "TraceRetailPortrait", "LoadSpeakerModel", "Client.ID" }) do
    assert(not head:find(removed, 1, true), "Keep portrait rendering independent of " .. removed)
end
assert(head:find("if self.Model.SetPortraitZoom then\n        self.Model:SetPortraitZoom(1)", 1, true),
    "Keep existing portrait zoom")
local clear = assert(head:find("self.Model:ClearModel()", 1, true))
local rootShow = assert(head:find("self.Frame:Show()", clear, true))
local animations = assert(head:find("for _, group in ipairs(self.FadeInGroups) do", rootShow, true))
assert(head:find("onOpening(transition)", animations, true),
    "Keep portrait setup, root Show, entrance animations, and immediate opening callback order")
for _, removed in ipairs({ "UnitGUID", "speaker.guid" }) do
    assert(not narration:find(removed, 1, true), "No portrait identity capture: " .. removed)
end
assert(narration:find("modelFileID = modelFileID,", 1, true), "Retain resolved NPC model metadata")
assert(narration:find("self:Submit(request, transition)", 1, true), "Retain opening submission")

-- Inspection keeps its separate SetUnit responsibility for voice resolution.
local inspection = Read("Core/NPCInspection.lua")
assert(inspection:find("model:ClearModel()\n    model:SetUnit(unit)", 1, true),
    "Keep the separate inspection path")
for _, client in ipairs({ { "Forever", "Forever" }, { "Mainline", "Retail" } }) do
    local toc = Read("OutLoud_" .. client[1] .. ".toc"):gsub("\\", "/")
    assert(toc:find("UI/TalkingHead.lua", 1, true), "Each client loads the shared portrait")
    assert(toc:find("Clients/" .. client[2] .. "/VoiceMappings.lua", 1, true),
        "Keep each client's voice catalog")
end

print("PASS: static shared UnitToken portrait contract; native integration not exercised")
