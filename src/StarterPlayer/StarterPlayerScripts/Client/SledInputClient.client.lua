-- SledInputClient.client.lua
-- Sends steering/throttle input for sled control.

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local ENABLE_LEGACY_SLED_INPUT = Config.Project and Config.Project.EnableLegacySledInput == true
if not ENABLE_LEGACY_SLED_INPUT then
    print("[SledInput] Legacy sled input disabled")
    return
end

local player = Players.LocalPlayer
local remoteSet = Remotes.get()
local sledSettings = Config.Sled or {}

local DEBUG_INPUT = sledSettings.Debug == true
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value + 100
local ACTION_STEER_LEFT = "SledSteerLeft"
local ACTION_STEER_RIGHT = "SledSteerRight"
local ACTION_ACCELERATE = "SledAccelerate"
local ACTION_BRAKE = "SledBrake"

local state = {
    up = false,
    down = false,
    left = false,
    right = false,
    lastSteer = 0,
    lastThrottle = 0,
    lastSend = 0,
    wasActive = false,
    bound = false,
    forwardBoundLogged = false,
    steeringBoundLogged = false,
    movementStarted = false,
    lastCarrierRoot = nil,
}

local function getCarrierRootFromSeat(seatPart)
    if not seatPart or not seatPart:IsA("Seat") then
        return nil
    end

    local model = seatPart:FindFirstAncestorOfClass("Model")
    if not model then
        return seatPart.AssemblyRootPart
    end

    local base = model:FindFirstChild("Base", true)
    if base and base:IsA("BasePart") then
        return base
    end

    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
        return model.PrimaryPart
    end

    return seatPart.AssemblyRootPart
end

local function getCurrentSeat()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local seatPart = humanoid and humanoid.SeatPart
    if seatPart and seatPart.Name == "SledSeat" then
        local sledModel = seatPart:FindFirstAncestorOfClass("Model")
        if sledModel and sledModel:GetAttribute("IsSled") == true then
            return seatPart
        end
    end
    return nil
end

local function actionHandler(actionName, inputState)
    local isDown = inputState == Enum.UserInputState.Begin
    if inputState ~= Enum.UserInputState.Begin
        and inputState ~= Enum.UserInputState.End
        and inputState ~= Enum.UserInputState.Cancel then
        return Enum.ContextActionResult.Pass
    end

    if actionName == ACTION_STEER_LEFT then
        state.left = isDown
    elseif actionName == ACTION_STEER_RIGHT then
        state.right = isDown
    elseif actionName == ACTION_ACCELERATE then
        state.up = isDown
    elseif actionName == ACTION_BRAKE then
        state.down = isDown
    end

    return Enum.ContextActionResult.Sink
end

local function bindSledInput()
    if state.bound then
        return
    end
    state.bound = true

    ContextActionService:BindActionAtPriority(
        ACTION_STEER_LEFT,
        actionHandler,
        false,
        INPUT_PRIORITY,
        Enum.KeyCode.A,
        Enum.KeyCode.Left
    )

    ContextActionService:BindActionAtPriority(
        ACTION_STEER_RIGHT,
        actionHandler,
        false,
        INPUT_PRIORITY,
        Enum.KeyCode.D,
        Enum.KeyCode.Right
    )

    ContextActionService:BindActionAtPriority(
        ACTION_ACCELERATE,
        actionHandler,
        false,
        INPUT_PRIORITY,
        Enum.KeyCode.W,
        Enum.KeyCode.Up
    )

    ContextActionService:BindActionAtPriority(
        ACTION_BRAKE,
        actionHandler,
        false,
        INPUT_PRIORITY,
        Enum.KeyCode.S,
        Enum.KeyCode.Down
    )

    if not state.forwardBoundLogged or not state.steeringBoundLogged then
        state.forwardBoundLogged = true
        state.steeringBoundLogged = true
        print("[POVInput] forwardBound=true steeringBound=true")
    end
end

local function unbindSledInput()
    if not state.bound then
        return
    end
    state.bound = false

    ContextActionService:UnbindAction(ACTION_STEER_LEFT)
    ContextActionService:UnbindAction(ACTION_STEER_RIGHT)
    ContextActionService:UnbindAction(ACTION_ACCELERATE)
    ContextActionService:UnbindAction(ACTION_BRAKE)

    state.left = false
    state.right = false
    state.up = false
    state.down = false
    state.movementStarted = false
    state.lastCarrierRoot = nil
end

RunService.RenderStepped:Connect(function()
    local seat = getCurrentSeat()
    local now = os.clock()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local camera = workspace.CurrentCamera

    if not seat then
        unbindSledInput()

        if humanoid then
            humanoid.AutoRotate = true
        end
        if camera and humanoid then
            camera.CameraType = Enum.CameraType.Custom
            camera.CameraSubject = humanoid
        end

        if state.wasActive then
            remoteSet.SledInput:FireServer(0, 0)
            state.wasActive = false
        end
        return
    end

    bindSledInput()

    local carrierRoot = getCarrierRootFromSeat(seat)
    if carrierRoot and carrierRoot ~= state.lastCarrierRoot then
        state.lastCarrierRoot = carrierRoot
        local model = carrierRoot:FindFirstAncestorOfClass("Model")
        print(string.format(
            "[POVCarrier] model=%s rootPart=%s",
            model and model:GetFullName() or "(none)",
            carrierRoot:GetFullName()
        ))
    end

    if humanoid then
        humanoid.AutoRotate = false
    end
    if camera and carrierRoot then
        camera.CameraType = Enum.CameraType.Custom
        camera.CameraSubject = carrierRoot
    end

    local steering = 0
    if state.left then
        steering -= 1
    end
    if state.right then
        steering += 1
    end

    local throttle = 0
    if state.up then
        throttle += 1
    end
    if state.down then
        throttle -= 1
    end

    steering = math.clamp(steering, -1, 1)
    throttle = math.clamp(throttle, -1, 1)

    local shouldSend =
        not state.wasActive
        or steering ~= state.lastSteer
        or throttle ~= state.lastThrottle
        or (now - state.lastSend) >= 0.08

    if shouldSend then
        state.lastSteer = steering
        state.lastThrottle = throttle
        state.lastSend = now
        state.wasActive = true

        if DEBUG_INPUT then
            print(string.format("[SledInput] steering=%.1f throttle=%.1f", steering, throttle))
        end

        if throttle > 0 and not state.movementStarted then
            state.movementStarted = true
            print("[POVMovement] started=true input=W/Up")
        end

        remoteSet.SledInput:FireServer(steering, throttle)
    end
end)

print("[Sled] Input client initialized")
