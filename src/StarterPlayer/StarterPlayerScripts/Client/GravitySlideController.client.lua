local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)

local projectConfig = Config.Project or {}
if projectConfig.EnableGravitySlideController ~= true then
    return
end

local settings = Config.GravitySlide or {}
local startSettings = Config.DownhillStart or {}

local GROUND_RAY_DISTANCE = tonumber(settings.GroundRayDistance) or 12
local GROUND_PROBE_HEIGHT = tonumber(settings.GroundProbeHeight) or 2
local STEERING_ACCELERATION = tonumber(settings.SteeringAcceleration) or 42
local LATERAL_DAMPING = tonumber(settings.LateralDamping) or 3.4
local ROLLING_DECELERATION = tonumber(settings.RollingDeceleration) or 1.6
local MINIMUM_ASSIST_SPEED = tonumber(settings.MinimumAssistSpeed) or 12
local MINIMUM_ASSIST_ACCELERATION = tonumber(settings.MinimumAssistAcceleration) or 7
local MAXIMUM_SPEED = tonumber(settings.MaximumSpeed) or 145
local OVERSPEED_BRAKE_ACCELERATION = tonumber(settings.OverspeedBrakeAcceleration) or 18
local UPHILL_THRESHOLD = tonumber(settings.UphillThreshold) or 0.015
local DEBUG_ENABLED = settings.Debug == true
local DEBUG_INTERVAL = tonumber(settings.DebugIntervalSeconds) or 1

local SLIDING_WALK_SPEED = tonumber(startSettings.SlidingWalkSpeed) or 0
local SLIDING_JUMP_POWER = tonumber(startSettings.SlidingJumpPower) or 0
local START_RETRY_SECONDS = (tonumber(startSettings.StartRequestCooldownSeconds) or 0.75) + 0.5

local localPlayer = Players.LocalPlayer

local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 20)
local remotesFolder = sharedFolder and sharedFolder:WaitForChild("NetworkRemotes", 20)
local startRequest = remotesFolder and remotesFolder:WaitForChild("DownhillStartRequest", 20)
if not startRequest or not startRequest:IsA("RemoteEvent") then
    warn("[GravitySlide] DownhillStartRequest is unavailable")
    return
end

local inputState = {
    left = false,
    right = false,
    gamepadX = 0,
}

local runtime = {
    character = nil,
    humanoid = nil,
    root = nil,
    force = nil,
    attachment = nil,
    controls = nil,
    controlsDisabled = false,
    currentRoadIndex = 1,
    lastForward = Vector3.new(0, 0, -1),
    lastDebugAt = 0,
    startRequested = false,
    defaults = {
        walkSpeed = 16,
        jumpPower = 50,
        autoRotate = true,
    },
}

local function ensureControls()
    if runtime.controls then
        return true
    end

    local playerScripts = localPlayer:FindFirstChild("PlayerScripts") or localPlayer:WaitForChild("PlayerScripts", 10)
    local playerModuleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
    if not playerModuleScript then
        return false
    end

    local ok, playerModule = pcall(require, playerModuleScript)
    if not ok or not playerModule then
        return false
    end

    runtime.controls = playerModule:GetControls()
    return runtime.controls ~= nil
end

local function disableControls()
    if runtime.controlsDisabled then
        return
    end
    if ensureControls() and runtime.controls then
        runtime.controls:Disable()
        runtime.controlsDisabled = true
    end
end

local function enableControls()
    if runtime.controls and runtime.controlsDisabled then
        runtime.controls:Enable()
    end
    runtime.controlsDisabled = false
end

local function createStartGui()
    local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
    if not playerGui then
        return nil
    end

    local oldGui = playerGui:FindFirstChild("DownhillStartGui")
    if oldGui then
        oldGui:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "DownhillStartGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.DisplayOrder = 20
    gui.Parent = playerGui

    local button = Instance.new("TextButton")
    button.Name = "StartButton"
    button.AnchorPoint = Vector2.new(0.5, 1)
    button.Position = UDim2.new(0.5, 0, 1, -36)
    button.Size = UDim2.fromOffset(180, 64)
    button.BackgroundColor3 = Color3.fromRGB(43, 183, 104)
    button.BorderSizePixel = 0
    button.Text = "START"
    button.TextColor3 = Color3.new(1, 1, 1)
    button.TextSize = 28
    button.Font = Enum.Font.GothamBold
    button.Visible = false
    button.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = button

    return button
end

local startButton = createStartGui()

local function getPhase()
    return localPlayer:GetAttribute("DownhillPhase") or "Loading"
end

local function requestStart()
    if getPhase() ~= "Waiting" or runtime.startRequested then
        return
    end
    runtime.startRequested = true
    startRequest:FireServer()
    task.delay(START_RETRY_SECONDS, function()
        if getPhase() == "Waiting" then
            runtime.startRequested = false
        end
    end)
end

if startButton then
    startButton.Activated:Connect(requestStart)
end

local function destroyForce()
    if runtime.force then
        runtime.force:Destroy()
        runtime.force = nil
    end
    if runtime.attachment then
        runtime.attachment:Destroy()
        runtime.attachment = nil
    end
end

local function ensureForce()
    local root = runtime.root
    if not root or not root.Parent then
        return nil
    end
    if runtime.force and runtime.force.Parent == root then
        return runtime.force
    end

    destroyForce()

    local oldAttachment = root:FindFirstChild("GravitySlideAttachment")
    if oldAttachment then
        oldAttachment:Destroy()
    end
    local oldForce = root:FindFirstChild("GravitySlideForce")
    if oldForce then
        oldForce:Destroy()
    end

    local attachment = Instance.new("Attachment")
    attachment.Name = "GravitySlideAttachment"
    attachment.Parent = root

    local force = Instance.new("VectorForce")
    force.Name = "GravitySlideForce"
    force.Attachment0 = attachment
    force.ApplyAtCenterOfMass = true
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.Force = Vector3.zero
    force.Parent = root

    runtime.attachment = attachment
    runtime.force = force
    return force
end

local function applySlidingHumanoidSettings()
    local humanoid = runtime.humanoid
    if not humanoid or not humanoid.Parent then
        return
    end
    humanoid.PlatformStand = false
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = SLIDING_WALK_SPEED
    humanoid.UseJumpPower = true
    humanoid.JumpPower = SLIDING_JUMP_POWER
end

local function restoreHumanoidSettings()
    local humanoid = runtime.humanoid
    if not humanoid or not humanoid.Parent then
        return
    end
    humanoid.PlatformStand = false
    humanoid.AutoRotate = runtime.defaults.autoRotate
    humanoid.WalkSpeed = runtime.defaults.walkSpeed
    humanoid.UseJumpPower = true
    humanoid.JumpPower = runtime.defaults.jumpPower
end

local function updatePhase()
    local phase = getPhase()
    local waiting = phase == "Waiting"
    local sliding = phase == "Sliding" or phase == "Starting"

    if waiting then
        runtime.startRequested = false
    end

    if waiting or sliding or phase == "Loading" then
        disableControls()
    else
        enableControls()
    end

    if startButton then
        startButton.Visible = waiting and UserInputService.TouchEnabled
        startButton.Active = waiting
    end

    if sliding then
        applySlidingHumanoidSettings()
        ensureForce()
    elseif runtime.force then
        runtime.force.Force = Vector3.zero
    end

    DownhillState.update({
        phase = phase,
        active = sliding,
        startedAt = localPlayer:GetAttribute("DownhillStartedAt") or 0,
    })
end

local function getSteerInput()
    local value = 0
    if inputState.left then
        value -= 1
    end
    if inputState.right then
        value += 1
    end
    if math.abs(inputState.gamepadX) > math.abs(value) then
        value = inputState.gamepadX
    end
    return math.clamp(value, -1, 1)
end

local function projectOntoSurface(direction, normal)
    local projected = direction - normal * direction:Dot(normal)
    if projected.Magnitude <= 0.001 then
        return nil
    end
    return projected.Unit
end

local function updateSlide()
    local force = runtime.force
    local root = runtime.root
    local humanoid = runtime.humanoid
    if getPhase() ~= "Sliding" or not force or not root or not humanoid or humanoid.Health <= 0 then
        if force then
            force.Force = Vector3.zero
        end
        return
    end

    local sample = DownhillCourse.raycastRoad(
        root.Position + Vector3.new(0, GROUND_PROBE_HEIGHT, 0),
        GROUND_RAY_DISTANCE + GROUND_PROBE_HEIGHT
    )

    local velocity = root.AssemblyLinearVelocity
    if not sample then
        force.Force = Vector3.zero
        DownhillState.update({
            active = true,
            grounded = false,
            speed = velocity.Magnitude,
            steerInput = getSteerInput(),
            rootPosition = root.Position,
        })
        return
    end

    runtime.currentRoadIndex = sample.index
    local normal = sample.result.Normal
    local roadForward = DownhillCourse.getForward(sample.index, 1) or runtime.lastForward
    local forward = projectOntoSurface(roadForward, normal)
    if not forward then
        force.Force = Vector3.zero
        return
    end
    runtime.lastForward = forward

    local right = forward:Cross(normal)
    if right.Magnitude <= 0.001 then
        force.Force = Vector3.zero
        return
    end
    right = right.Unit

    local tangentVelocity = velocity - normal * velocity:Dot(normal)
    local tangentSpeed = tangentVelocity.Magnitude
    local forwardSpeed = tangentVelocity:Dot(forward)
    local lateralSpeed = tangentVelocity:Dot(right)
    local steerInput = getSteerInput()

    local acceleration = right * ((steerInput * STEERING_ACCELERATION) - (lateralSpeed * LATERAL_DAMPING))

    if tangentSpeed > 0.5 then
        acceleration -= tangentVelocity.Unit * ROLLING_DECELERATION
    end

    local isUphill = forward.Y > UPHILL_THRESHOLD
    if not isUphill and forwardSpeed < MINIMUM_ASSIST_SPEED then
        local assistRatio = math.clamp(1 - (forwardSpeed / math.max(MINIMUM_ASSIST_SPEED, 1)), 0, 1.5)
        acceleration += forward * (MINIMUM_ASSIST_ACCELERATION * assistRatio)
    end

    if tangentSpeed > MAXIMUM_SPEED then
        local excessRatio = math.clamp((tangentSpeed - MAXIMUM_SPEED) / math.max(MAXIMUM_SPEED, 1), 0, 1)
        acceleration -= tangentVelocity.Unit * (OVERSPEED_BRAKE_ACCELERATION * excessRatio)
    end

    force.Force = acceleration * root.AssemblyMass

    DownhillState.update({
        phase = "Sliding",
        active = true,
        grounded = true,
        roadName = sample.road.Name,
        speed = tangentSpeed,
        targetSpeed = 0,
        lateral = lateralSpeed,
        slope = -forward.Y,
        lookAhead = 1,
        steerInput = steerInput,
        forward = forward,
        groundNormal = normal,
        rootPosition = root.Position,
    })

    local now = os.clock()
    if DEBUG_ENABLED and now >= runtime.lastDebugAt then
        runtime.lastDebugAt = now + DEBUG_INTERVAL
        print(string.format(
            "[GravitySlide] phase=Sliding road=%s speed=%.2f forwardSpeed=%.2f lateralSpeed=%.2f slope=%.3f steer=%.2f force=%.2f",
            sample.road.Name,
            tangentSpeed,
            forwardSpeed,
            lateralSpeed,
            -forward.Y,
            steerInput,
            force.Force.Magnitude
        ))
    end
end

local function cleanupCharacter()
    destroyForce()
    restoreHumanoidSettings()
    enableControls()
    runtime.character = nil
    runtime.humanoid = nil
    runtime.root = nil
    runtime.currentRoadIndex = 1
    runtime.lastForward = Vector3.new(0, 0, -1)
    runtime.startRequested = false
    inputState.left = false
    inputState.right = false
    inputState.gamepadX = 0
    DownhillState.reset()
end

local function initializeCharacter(character)
    cleanupCharacter()

    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not root or not root:IsA("BasePart") then
        warn("[GravitySlide] character initialization failed")
        return
    end

    runtime.character = character
    runtime.humanoid = humanoid
    runtime.root = root
    runtime.defaults.walkSpeed = humanoid.WalkSpeed
    runtime.defaults.jumpPower = humanoid.JumpPower
    runtime.defaults.autoRotate = humanoid.AutoRotate

    if not DownhillCourse.ensureCache(30) then
        warn("[GravitySlide] course cache is unavailable")
        enableControls()
        return
    end

    updatePhase()
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end

    if getPhase() == "Waiting" then
        if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
            requestStart()
        end
        return
    end

    if getPhase() ~= "Sliding" then
        return
    end
    if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
        inputState.left = true
    elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
        inputState.right = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
        inputState.left = false
    elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
        inputState.right = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
        local x = input.Position.X
        inputState.gamepadX = math.abs(x) >= 0.08 and math.clamp(x, -1, 1) or 0
    end
end)

localPlayer:GetAttributeChangedSignal("DownhillPhase"):Connect(updatePhase)
localPlayer:GetAttributeChangedSignal("DownhillStartedAt"):Connect(updatePhase)
localPlayer.CharacterAdded:Connect(initializeCharacter)
localPlayer.CharacterRemoving:Connect(cleanupCharacter)
RunService.Heartbeat:Connect(updateSlide)

if localPlayer.Character then
    task.defer(initializeCharacter, localPlayer.Character)
end

print("[GravitySlide] client controller enabled")
