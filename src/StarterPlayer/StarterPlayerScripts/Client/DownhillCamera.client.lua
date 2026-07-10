local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)

local projectConfig = Config.Project or {}
if projectConfig.EnableDownhillCamera ~= true then
    return
end

local settings = Config.Downhill or {}

local BACK_OFFSET = tonumber(settings.CameraBackOffset) or 0.65
local UP_OFFSET = tonumber(settings.CameraUpOffset) or 0.85
local LOOK_AHEAD_MIN = tonumber(settings.CameraLookAheadMin) or 18
local LOOK_AHEAD_MAX = tonumber(settings.CameraLookAheadMax) or 48
local POSITION_RESPONSIVENESS = tonumber(settings.CameraPositionResponsiveness) or 14
local ROTATION_RESPONSIVENESS = tonumber(settings.CameraRotationResponsiveness) or 11
local BASE_FOV = tonumber(settings.CameraBaseFov) or 78
local MAX_FOV = tonumber(settings.CameraMaximumFov) or 96
local FOV_SPEED_REF = tonumber(settings.CameraFovSpeedReference) or 115
local MAX_ROLL_DEGREES = tonumber(settings.CameraMaximumRollDegrees) or 6

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local runtime = {
    character = nil,
    root = nil,
    head = nil,
    currentPosition = nil,
    currentLookAt = nil,
    transparencyParts = {},
    connections = {},
}

local function alphaFromResponsiveness(value, dt)
    return 1 - math.exp(-value * dt)
end

local function clearConnections()
    for _, connection in ipairs(runtime.connections) do
        connection:Disconnect()
    end
    table.clear(runtime.connections)
end

local function restoreLocalTransparency()
    for part, previous in pairs(runtime.transparencyParts) do
        if part and part.Parent then
            part.LocalTransparencyModifier = previous
        end
    end
    table.clear(runtime.transparencyParts)
end

local function applyLocalTransparency(character)
    restoreLocalTransparency()

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local name = descendant.Name
            if name == "Head" then
                runtime.transparencyParts[descendant] = descendant.LocalTransparencyModifier
                descendant.LocalTransparencyModifier = 1
            elseif name == "UpperTorso" or name == "LowerTorso" then
                runtime.transparencyParts[descendant] = descendant.LocalTransparencyModifier
                descendant.LocalTransparencyModifier = 0.65
            elseif descendant.Parent and descendant.Parent:IsA("Accessory") then
                runtime.transparencyParts[descendant] = descendant.LocalTransparencyModifier
                descendant.LocalTransparencyModifier = 0.9
            end
        end
    end
end

local function restoreCameraDefaults()
    if camera then
        camera.CameraType = Enum.CameraType.Custom
        camera.FieldOfView = 70
    end
end

local function cleanupCharacterState()
    restoreLocalTransparency()
    restoreCameraDefaults()

    runtime.character = nil
    runtime.root = nil
    runtime.head = nil
    runtime.currentPosition = nil
    runtime.currentLookAt = nil
end

local function resolveCameraCollision(desiredPosition, lookAtPosition)
    local direction = desiredPosition - lookAtPosition
    if direction.Magnitude <= 0.001 then
        return desiredPosition
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { runtime.character }
    params.IgnoreWater = true

    local result = Workspace:Raycast(lookAtPosition, direction, params)
    if not result then
        return desiredPosition
    end

    return result.Position + (result.Normal * 0.35)
end

local function updateCamera(dt)
    local state = DownhillState.get()
    if not state.active or not runtime.root or not runtime.head then
        return
    end

    if not camera then
        camera = Workspace.CurrentCamera
        if not camera then
            return
        end
    end

    local forward = state.forward
    if not forward or forward.Magnitude <= 0.001 then
        forward = runtime.root.CFrame.LookVector
    end

    local speedAlpha = math.clamp(state.speed / math.max(FOV_SPEED_REF, 1), 0, 1)
    local lookAhead = LOOK_AHEAD_MIN + ((LOOK_AHEAD_MAX - LOOK_AHEAD_MIN) * speedAlpha)

    local backDistance = 4 + (BACK_OFFSET * 6)
    local upDistance = 1 + (UP_OFFSET * 3)

    local headPosition = runtime.head.Position
    local desiredLookAt = headPosition + (forward * lookAhead)
    local desiredPosition = headPosition - (forward * backDistance) + Vector3.new(0, upDistance, 0)

    local landingShake, wallShake = DownhillState.step(dt)
    local totalShake = (landingShake * 0.35) + (wallShake * 0.2)
    if totalShake > 0 then
        desiredPosition += Vector3.new(0, totalShake, 0)
    end

    desiredPosition = resolveCameraCollision(desiredPosition, desiredLookAt)

    if not runtime.currentPosition then
        runtime.currentPosition = desiredPosition
        runtime.currentLookAt = desiredLookAt
    end

    local posAlpha = alphaFromResponsiveness(POSITION_RESPONSIVENESS, dt)
    local rotAlpha = alphaFromResponsiveness(ROTATION_RESPONSIVENESS, dt)

    runtime.currentPosition = runtime.currentPosition:Lerp(desiredPosition, posAlpha)
    runtime.currentLookAt = runtime.currentLookAt:Lerp(desiredLookAt, rotAlpha)

    local rollRadians = math.rad(MAX_ROLL_DEGREES * math.clamp(state.steerInput or 0, -1, 1))
    local lookCFrame = CFrame.lookAt(runtime.currentPosition, runtime.currentLookAt, Vector3.yAxis)

    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = lookCFrame * CFrame.Angles(0, 0, rollRadians)

    local targetFov = BASE_FOV + ((MAX_FOV - BASE_FOV) * speedAlpha)
    local fovAlpha = alphaFromResponsiveness(6, dt)
    camera.FieldOfView = camera.FieldOfView + ((targetFov - camera.FieldOfView) * fovAlpha)
end

local function setupCharacter(character)
    cleanupCharacterState()

    runtime.character = character
    runtime.root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    runtime.head = character:FindFirstChild("Head") or runtime.root

    if not runtime.root then
        return
    end

    applyLocalTransparency(character)
end

clearConnections()
table.insert(runtime.connections, RunService.RenderStepped:Connect(updateCamera))
table.insert(runtime.connections, localPlayer.CharacterAdded:Connect(setupCharacter))
table.insert(runtime.connections, localPlayer.CharacterRemoving:Connect(function()
    cleanupCharacterState()
end))

if localPlayer.Character then
    task.defer(function()
        setupCharacter(localPlayer.Character)
    end)
end
