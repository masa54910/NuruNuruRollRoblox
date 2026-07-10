-- GoalSystem.server.lua
-- Detects goal events and awards points.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Config = require(ReplicatedStorage.Shared.Config)

local ENABLE_LEGACY_GOAL_SYSTEM = Config.Project and Config.Project.EnableLegacyGoalSystem == true
if not ENABLE_LEGACY_GOAL_SYSTEM then
    print("[GoalSystem] Legacy goal system disabled")
    return
end

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local remoteSet = Remotes.get()
local touchCooldown = {}

local function getOrCreateLeaderstats(player)
    local leaderstats = player:FindFirstChild("leaderstats")
    if not leaderstats then
        leaderstats = Instance.new("Folder")
        leaderstats.Name = "leaderstats"
        leaderstats.Parent = player
    end

    local score = leaderstats:FindFirstChild("Score")
    if not score then
        score = Instance.new("IntValue")
        score.Name = "Score"
        score.Parent = leaderstats
    end

    local goals = leaderstats:FindFirstChild("Goals")
    if not goals then
        goals = Instance.new("IntValue")
        goals.Name = "Goals"
        goals.Parent = leaderstats
    end

    return score, goals
end

local function resolvePlayerFromHit(hit)
    if not hit then
        return nil
    end

    local character = hit:FindFirstAncestorOfClass("Model")
    if character then
        local playerFromCharacter = Players:GetPlayerFromCharacter(character)
        if playerFromCharacter then
            return playerFromCharacter
        end

        local ownerUserId = character:GetAttribute("OwnerUserId")
        if typeof(ownerUserId) == "number" then
            return Players:GetPlayerByUserId(ownerUserId)
        end
    end

    return nil
end

local function onGoalScored(player)
    if not player then
        return
    end

    local score, goals = getOrCreateLeaderstats(player)
    score.Value += Config.Goal.PointsPerGoal
    goals.Value += 1

    remoteSet.GoalScored:FireAllClients(player.Name, score.Value, goals.Value)
    remoteSet.GoalReachedServer:Fire(player)
    print("[GoalSystem] Goal scored by", player.Name, "points=", Config.Goal.PointsPerGoal)
end

local function waitForGoalTrigger(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    local lastSeenGoalTrigger = nil

    while os.clock() < deadline do
        local mapReady = Workspace:GetAttribute("NuruNuruRollMapReady")
        local mapRoot = Workspace:FindFirstChild("NuruNuruRollMap")
        local goalFolder = mapRoot and mapRoot:FindFirstChild("Goal")
        local goalTrigger = goalFolder and goalFolder:FindFirstChild("GoalTrigger")

        if mapReady == true and goalTrigger then
            return goalTrigger
        end

        if goalTrigger then
            lastSeenGoalTrigger = goalTrigger
        end

        task.wait(0.25)
    end

    return lastSeenGoalTrigger
end

local function hookGoalTrigger()
    local goalTrigger = waitForGoalTrigger(10)
    if not goalTrigger then
        warn("[GoalSystem] GoalTrigger was not found within timeout")
        return
    end

    goalTrigger.Touched:Connect(function(hit)
        local player = resolvePlayerFromHit(hit)
        if not player then
            return
        end

        local now = os.clock()
        local last = touchCooldown[player.UserId] or 0
        if now - last < 1.5 then
            return
        end

        touchCooldown[player.UserId] = now
        onGoalScored(player)
    end)
end

Players.PlayerAdded:Connect(function(player)
    getOrCreateLeaderstats(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
    getOrCreateLeaderstats(player)
end

hookGoalTrigger()
print("[GoalSystem] goal trigger hooked")
