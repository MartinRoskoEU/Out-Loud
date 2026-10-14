local AddonName, OutLoud = ...

local ComboBox = {}
ComboBox.__index = ComboBox

OutLoud.Classes.ComboBox = ComboBox

function ComboBox:New(parent, width)
    local instance = setmetatable({}, self)

    local control = CreateFrame("Frame", nil, parent, "SettingsDropdownWithButtonsTemplate")
    control:SetWidth(width)
    control.Label:Hide()

    local dropdown = control.Dropdown
    dropdown:SetWidth(width - 80)

    instance.Frame = control
    instance.Dropdown = dropdown
    instance.Enabled = true

    return instance
end

function ComboBox:Setup(options, getValue, setValue)
    self.Dropdown:SetSelectionText(function()
        local value = getValue()
        for _, option in ipairs(options) do
            if option.value == value then
                return option.label
            end
        end
        return "Unavailable (voice " .. tostring(value) .. ")"
    end)
    self.Dropdown:SetupMenu(function(_, rootDescription)
        for _, option in ipairs(options) do
            rootDescription:CreateRadio(
                option.label,
                function(value)
                    return getValue() == value
                end,
                function(value)
                    if self.Enabled then
                        setValue(value)
                    end
                end,
                option.value
            )
        end
    end)
end

function ComboBox:SetEnabled(enabled)
    self.Enabled = enabled == true
    if not self.Enabled then
        self.Dropdown:CloseMenu()
    end
    -- Native mixin disables the dropdown and both stepper buttons.
    self.Frame:SetEnabled(self.Enabled)
end

function ComboBox:Refresh()
    self.Dropdown:GenerateMenu()
end
