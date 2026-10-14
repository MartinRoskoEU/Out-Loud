local AddonName, OutLoud = ...

local NPCInspection = {}
OutLoud.NPCInspection = NPCInspection

function NPCInspection:GetModel()
    if not self.Model then
        -- Preserve the verified unparented, unhidden inspection setup.
        self.Model = CreateFrame("PlayerModel")
    end
    return self.Model
end

function NPCInspection:LoadUnit(unit)
    if not unit or not UnitExists(unit) then return end

    local model = self:GetModel()
    -- Never let an unfinished load resolve the previous quest/gossip NPC.
    model:ClearModel()
    model:SetUnit(unit)
    return model
end
