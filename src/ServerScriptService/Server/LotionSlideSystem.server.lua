-- LotionSlideSystem.server.lua
-- Slide physics is intentionally disabled. Keep humanoids in normal Roblox movement state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

if Config.Project and Config.Project.EnableDownhillStartSystem == true then
    print("[LotionSlideSystem] disabled while DownhillStartSystem owns Humanoid setup")
    return
end

local function restoreHumanoidDefaults(character)
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    if not humanoid then
        return
    end

    humanoid.PlatformStand = false
    humanoid.AutoRotate = true
    humanoid.WalkSpeed = 16
    humanoid.UseJumpPower = true
    humanoid.JumpPower = 50
end

for _, player in ipairs(Players:GetPlayers()) do
    if player.Character then
        restoreHumanoidDefaults(player.Character)
    end
    player.CharacterAdded:Connect(restoreHumanoidDefaults)
end

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(restoreHumanoidDefaults)
end)

print("[LotionSlideSystem] slide physics disabled; normal character movement restored")
