local AddonName, OutLoud = ...

_G.OutLoud = OutLoud

OutLoud.Name = AddonName
OutLoud.Loaded = false

OutLoud.UI = {}
OutLoud.Classes = {}

-- Routine diagnostics are opt-in for the current login.
OutLoud.DebugEnabled = false

function OutLoud:Debug(...)
    if self.DebugEnabled then
        print("[Out Loud]", ...)
    end
end

function OutLoud:HandleSlashCommand(message)
    local command, value = (message or ""):lower():match("^%s*(%S+)%s*(.-)%s*$")
    if command ~= "debug" or (value ~= "" and value ~= "on" and value ~= "off") then
        print("[Out Loud] Usage: /outloud debug [on|off]")
        return
    end
    if value == "on" then
        self.DebugEnabled = true
    elseif value == "off" then
        self.DebugEnabled = false
    end
    print("[Out Loud] Debug logging " .. (self.DebugEnabled and "enabled." or "disabled."))
end

function OutLoud:RegisterSlashCommands()
    _G.SLASH_OUTLOUD1 = "/outloud"
    SlashCmdList.OUTLOUD = function(message) self:HandleSlashCommand(message) end
end

function OutLoud:Error(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    print("|cffff0000[Out Loud] " .. table.concat(parts, " ") .. "|r")
end
