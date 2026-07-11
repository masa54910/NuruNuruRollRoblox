local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local projectConfig = Config.Project or {}

if projectConfig.EnableOfficialRacingClientProbe ~= true then
    return
end

local player = Players.LocalPlayer

local state = {
    forwardPressed = false,
    steeringPressed = false,
    lastSummary = "",
}

local function getCharacterHumanoid()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return character, humanoid
end

local function isDriverSeatOccupiedByLocalPlayer()
    local _, humanoid = getCharacterHumanoid()
    if not humanoid then
        return false, nil, nil
    end

    local seatPart = humanoid.SeatPart
    if not seatPart or not seatPart:IsA("VehicleSeat") then
        return false, nil, nil
    end

    if seatPart.Name ~= "DriverSeat" then
        return false, nil, nil
    end

    local model = seatPart:FindFirstAncestorOfClass("Model")
    return true, seatPart, model
end

local function controllerPresent()
    local playerScripts = player:FindFirstChildOfClass("PlayerScripts")
    if not playerScripts then
        return false
    end

    for _, desc in ipairs(playerScripts:GetDescendants()) do
        if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
            if desc.Name == "ClientController" then
                return true
            end
        end
    end

    return false
end

local function isInputBoundToVehicle(vehicleModel)
    if not vehicleModel then
        return false
    end

    local inputs = vehicleModel:FindFirstChild("Inputs", true)
    if not inputs then
        return false
    end

    local hasSteer = typeof(inputs:GetAttribute("steeringInput")) == "number"
    local hasThrottle = typeof(inputs:GetAttribute("throttleInput")) == "number"
    return hasSteer or hasThrottle
end

local function cameraBoundToVehicle(seat, vehicleModel)
    local camera = workspace.CurrentCamera
    if not camera then
        return false
    end

    if camera.CameraType == Enum.CameraType.Scriptable then
        return true
    end

    local subject = camera.CameraSubject
    if not subject then
        return false
    end

    if subject == seat or subject == vehicleModel then
        return true
    end

    if subject:IsA("Instance") and vehicleModel and subject:IsDescendantOf(vehicleModel) then
        return true
    end

    return false
end

local function resetCharacterVisualAndHumanoid(character)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.AutoRotate = true
        humanoid.PlatformStand = false
    end

    for _, desc in ipairs(character:GetDescendants()) do
        if desc:IsA("BasePart") then
            desc.LocalTransparencyModifier = 0
        end
    end

    local animate = character:FindFirstChild("Animate")
    if animate and animate:IsA("LocalScript") then
        animate.Enabled = true
    end
end

player.CharacterAdded:Connect(function(character)
    resetCharacterVisualAndHumanoid(character)
end)

if player.Character then
    resetCharacterVisualAndHumanoid(player.Character)
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
        state.forwardPressed = true
    end

    if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.D
        or input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.Right then
        state.steeringPressed = true
    end
end)

local lastReportAt = 0
RunService.RenderStepped:Connect(function()
    local now = os.clock()
    if now - lastReportAt < 0.5 then
        return
    end
    lastReportAt = now

    local occupied, seat, vehicleModel = isDriverSeatOccupiedByLocalPlayer()
    local vehicle = vehicleModel ~= nil
    local driverSeat = seat ~= nil
    local clientController = controllerPresent()
    local boundToVehicle = occupied and isInputBoundToVehicle(vehicleModel)
    local cameraBound = occupied and cameraBoundToVehicle(seat, vehicleModel)

    if occupied and (state.forwardPressed or state.steeringPressed) then
        print(string.format(
            "[RacingInputRestore] clientController=%s boundToVehicle=%s forward=%s steering=%s",
            tostring(clientController),
            tostring(boundToVehicle),
            tostring(state.forwardPressed),
            tostring(state.steeringPressed)
        ))
        state.forwardPressed = false
        state.steeringPressed = false
    end

    local summary = string.format(
        "vehicle=%s driverSeat=%s occupant=%s inputBound=%s cameraBound=%s",
        tostring(vehicle),
        tostring(driverSeat),
        tostring(occupied),
        tostring(boundToVehicle),
        tostring(cameraBound)
    )

    if summary ~= state.lastSummary then
        state.lastSummary = summary
        print("[RacingRestore] " .. summary)
    end
end)
