local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)

local projectConfig = Config.Project or {}
local OWNER_PROBE_ENABLED = projectConfig.EnableDownhillServerOwnershipProbe == true
local SERVER_IMPULSE_PROBE_ENABLED = projectConfig.EnableDownhillServerImpulseProbe == true

if not OWNER_PROBE_ENABLED and not SERVER_IMPULSE_PROBE_ENABLED then
    return
end

local lastLogByPlayer = {}
local impulseAppliedByPlayer = {}

local function formatVector3(vector)
    if not vector then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", vector.X, vector.Y, vector.Z)
end

local function formatInstance(instance)
    if not instance then
        return "(nil)"
    end

    local ok, fullName = pcall(function()
        return instance:GetFullName()
    end)
    return ok and fullName or tostring(instance)
end

local function describeNetworkOwner(root)
    local ok, owner = pcall(function()
        return root:GetNetworkOwner()
    end)
    if not ok then
        return "unknown"
    end
    if owner == nil then
        return "server"
    end
    return "client:" .. owner.Name
end

local function applyServerImpulseOnce(player, character, humanoid, root)
    if impulseAppliedByPlayer[player] then
        return
    end
    impulseAppliedByPlayer[player] = true

    task.wait(3)

    if not root.Parent or player.Character ~= character then
        return
    end

    local look = root.CFrame.LookVector
    local testForward = Vector3.new(look.X, 0, look.Z)
    if testForward.Magnitude <= 0.001 then
        warn("[DownhillFailure] Server impulse probe could not resolve Character LookVector")
        return
    end
    testForward = testForward.Unit

    local before = root.AssemblyLinearVelocity
    local writeVelocity = (testForward * 40) + Vector3.new(0, before.Y, 0)
    root.AssemblyLinearVelocity = writeVelocity
    local afterWrite = root.AssemblyLinearVelocity

    print(string.format(
        "[DownhillServerWriteProbe]\nplayer=%s\nnetworkOwner=%s\nusedDirection=%s\nvelocityBefore=%s\nvelocityAfterWrite=%s\nhumanoidState=%s\nrootAnchored=%s\nassemblyRoot=%s\nmass=%.3f",
        player.Name,
        describeNetworkOwner(root),
        formatVector3(testForward),
        formatVector3(before),
        formatVector3(afterWrite),
        humanoid and tostring(humanoid:GetState()) or "(nil)",
        tostring(root.Anchored),
        formatInstance(root.AssemblyRootPart),
        root.AssemblyMass
    ))

    RunService.Heartbeat:Wait()
    local nextFrame = root.AssemblyLinearVelocity
    task.wait(0.1)
    local afterPointOne = root.AssemblyLinearVelocity
    task.wait(0.4)
    local afterPointFive = root.AssemblyLinearVelocity

    print(string.format(
        "[DownhillServerPersistenceProbe]\nplayer=%s\nvelocityNextFrame=%s\nvelocityAfter0_1s=%s\nvelocityAfter0_5s=%s\npositionAfter0_5s=%s\nforwardSpeed0_5=%.3f",
        player.Name,
        formatVector3(nextFrame),
        formatVector3(afterPointOne),
        formatVector3(afterPointFive),
        formatVector3(root.Position),
        afterPointFive:Dot(testForward)
    ))
end

local function hookCharacter(player, character)
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not root then
        return
    end

    if SERVER_IMPULSE_PROBE_ENABLED then
        task.spawn(function()
            applyServerImpulseOnce(player, character, humanoid, root)
        end)
    end
end

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function(character)
        impulseAppliedByPlayer[player] = false
        hookCharacter(player, character)
    end)
end)

for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterAdded:Connect(function(character)
        impulseAppliedByPlayer[player] = false
        hookCharacter(player, character)
    end)
    if player.Character then
        hookCharacter(player, player.Character)
    end
end

Players.PlayerRemoving:Connect(function(player)
    lastLogByPlayer[player] = nil
    impulseAppliedByPlayer[player] = nil
end)

RunService.Heartbeat:Connect(function()
    if not OWNER_PROBE_ENABLED then
        return
    end

    local now = os.clock()
    for _, player in ipairs(Players:GetPlayers()) do
        if now - (lastLogByPlayer[player] or 0) < 1 then
            continue
        end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if humanoid and root then
            lastLogByPlayer[player] = now
            print(string.format(
                "[DownhillServerOwnerProbe]\nplayer=%s\nnetworkOwner=%s\nrootVelocity=%s\nrootPosition=%s\nassemblyRoot=%s\nmass=%.3f\nanchored=%s\nhumanoidState=%s\nplatformStand=%s\nwalkSpeed=%.1f",
                player.Name,
                describeNetworkOwner(root),
                formatVector3(root.AssemblyLinearVelocity),
                formatVector3(root.Position),
                formatInstance(root.AssemblyRootPart),
                root.AssemblyMass,
                tostring(root.Anchored),
                tostring(humanoid:GetState()),
                tostring(humanoid.PlatformStand),
                humanoid.WalkSpeed
            ))
        end
    end
end)

print("[DownhillPhysicsProbe] server ownership probe initialized")
