-- ResultSystem.server.lua
-- Calculates and publishes end-of-round results.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local remoteSet = Remotes.get()

local function getScore(player)
    local leaderstats = player:FindFirstChild("leaderstats")
    if not leaderstats then
        return 0
    end

    local score = leaderstats:FindFirstChild("Score")
    if not score then
        return 0
    end

    return score.Value
end

local function publishResults()
    local rows = {}
    for _, player in ipairs(Players:GetPlayers()) do
        table.insert(rows, {
            Name = player.Name,
            Score = getScore(player),
        })
    end

    table.sort(rows, function(a, b)
        return a.Score > b.Score
    end)

    remoteSet.RoundResult:FireAllClients(rows)
    print("[ResultSystem] published result for", #rows, "players")
end

local function resetRoundScores()
    for _, player in ipairs(Players:GetPlayers()) do
        local leaderstats = player:FindFirstChild("leaderstats")
        if leaderstats then
            local score = leaderstats:FindFirstChild("Score")
            local goals = leaderstats:FindFirstChild("Goals")
            if score then
                score.Value = 0
            end
            if goals then
                goals.Value = 0
            end
        end
    end
end

local function broadcastState(state, remainingSeconds)
    remoteSet.RoundState:FireAllClients(state, remainingSeconds)
end

task.spawn(function()
    while true do
        resetRoundScores()

        for remaining = Config.Round.IntermissionSeconds, 1, -1 do
            broadcastState("Intermission", remaining)
            task.wait(1)
        end

        for remaining = Config.Round.DurationSeconds, 1, -1 do
            broadcastState("Round", remaining)
            task.wait(1)
        end

        broadcastState("Result", 0)
        publishResults()
        task.wait(5)
    end
end)

print("[ResultSystem] round loop started")
