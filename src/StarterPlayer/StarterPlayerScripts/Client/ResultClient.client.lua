-- ResultClient.client.lua
-- Displays round results UI on the client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local ENABLE_LEGACY_RESULT_UI = Config.Project and Config.Project.EnableLegacyResultUi == true
if not ENABLE_LEGACY_RESULT_UI then
    print("[ResultClient] Legacy result UI disabled")
    return
end

local player = Players.LocalPlayer
local remoteSet = Remotes.get()

local function createResultGui()
    local playerGui = player:WaitForChild("PlayerGui")

    local existing = playerGui:FindFirstChild("ResultHud")
    if existing then
        existing:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "ResultHud"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui

    local resultBox = Instance.new("TextLabel")
    resultBox.Name = "ResultBox"
    resultBox.Size = UDim2.fromOffset(520, 220)
    resultBox.Position = UDim2.new(0.5, -260, 0.5, -110)
    resultBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    resultBox.BackgroundTransparency = 0.3
    resultBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    resultBox.TextScaled = false
    resultBox.TextSize = 22
    resultBox.Font = Enum.Font.GothamBold
    resultBox.TextWrapped = true
    resultBox.Visible = false
    resultBox.Text = ""
    resultBox.Parent = screenGui

    local toast = Instance.new("TextLabel")
    toast.Name = "GoalToast"
    toast.Size = UDim2.fromOffset(420, 42)
    toast.Position = UDim2.new(0.5, -210, 0, 80)
    toast.BackgroundColor3 = Color3.fromRGB(255, 217, 61)
    toast.BackgroundTransparency = 0.15
    toast.TextColor3 = Color3.fromRGB(20, 20, 20)
    toast.TextScaled = true
    toast.Font = Enum.Font.GothamBold
    toast.Visible = false
    toast.Text = ""
    toast.Parent = screenGui

    return resultBox, toast
end

local function initializeResultUi()
    local resultBox, toast = createResultGui()

    remoteSet.RoundResult.OnClientEvent:Connect(function(rows)
        if typeof(rows) ~= "table" then
            return
        end

        local lines = { "Round Result" }
        for rank, row in ipairs(rows) do
            table.insert(lines, string.format("%d. %s - %d", rank, tostring(row.Name), tonumber(row.Score) or 0))
            if rank >= 5 then
                break
            end
        end

        resultBox.Text = table.concat(lines, "\n")
        resultBox.Visible = true
        task.delay(5, function()
            if resultBox.Parent then
                resultBox.Visible = false
            end
        end)
    end)

    remoteSet.GoalScored.OnClientEvent:Connect(function(playerName, scoreValue, goalCount)
        toast.Text = string.format("%s scored! Score %d | Goals %d", tostring(playerName), tonumber(scoreValue) or 0, tonumber(goalCount) or 0)
        toast.Visible = true
        task.delay(1.5, function()
            if toast.Parent then
                toast.Visible = false
            end
        end)
    end)

    print("[ResultClient] initialized for", player.Name)
end

initializeResultUi()
