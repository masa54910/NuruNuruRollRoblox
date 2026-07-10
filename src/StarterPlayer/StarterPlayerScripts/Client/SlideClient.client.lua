-- SlideClient.client.lua
-- Passive HUD for round state and local character speed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local player = Players.LocalPlayer
local remoteSet = Remotes.get()

local function createHud()
    local playerGui = player:WaitForChild("PlayerGui")

    local existing = playerGui:FindFirstChild("SlideHud")
    if existing then
        existing:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "SlideHud"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui

    local stateLabel = Instance.new("TextLabel")
    stateLabel.Name = "StateLabel"
    stateLabel.Size = UDim2.fromOffset(420, 46)
    stateLabel.Position = UDim2.fromOffset(20, 20)
    stateLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    stateLabel.BackgroundTransparency = 0.25
    stateLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    stateLabel.TextScaled = true
    stateLabel.Font = Enum.Font.GothamBold
    stateLabel.Text = "Waiting..."
    stateLabel.Parent = screenGui

    local speedLabel = Instance.new("TextLabel")
    speedLabel.Name = "SpeedLabel"
    speedLabel.Size = UDim2.fromOffset(240, 40)
    speedLabel.Position = UDim2.new(0.5, -120, 1, -60)
    speedLabel.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
    speedLabel.BackgroundTransparency = 0.2
    speedLabel.TextColor3 = Color3.fromRGB(188, 234, 245)
    speedLabel.TextScaled = true
    speedLabel.Font = Enum.Font.GothamMedium
    speedLabel.Text = "Speed: 0"
    speedLabel.Parent = screenGui

    return stateLabel, speedLabel
end

local function initializeClient()
    local stateLabel, speedLabel = createHud()

    remoteSet.RoundState.OnClientEvent:Connect(function(state, remainingSeconds)
        stateLabel.Text = string.format("%s | %ds", tostring(state), tonumber(remainingSeconds) or 0)
    end)

    RunService.RenderStepped:Connect(function()
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then
            return
        end

        local horizontalVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
        local speed = horizontalVelocity.Magnitude
        speedLabel.Text = string.format("Speed: %d", math.floor(speed + 0.5))
    end)

    print("[SlideClient] initialized for", player.Name)
end

initializeClient()
