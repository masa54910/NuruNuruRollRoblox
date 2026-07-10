local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)

local projectConfig = Config.Project or {}
if projectConfig.EnableGravitySlideController ~= true then
    return
end

local BUILD_ID = "GATE1_SEAT_INPUT_FIX_V4"

local IS_STUDIO = RunService:IsStudio()
local START_FLOW_LOG_ENABLED = IS_STUDIO and projectConfig.EnableDownhillDebug == true

local settings = Config.GravitySlide or {}
local startSettings = Config.DownhillStart or {}

local GROUND_RAY_DISTANCE = tonumber(settings.GroundRayDistance) or 12
local GROUND_PROBE_HEIGHT = tonumber(settings.GroundProbeHeight) or 2
local SLIDE_GRAVITY_MULTIPLIER = tonumber(settings.SlideGravityMultiplier) or 1
local FLAT_SLOPE_THRESHOLD = tonumber(settings.SlideFlatSlopeThreshold) or 0.02
local MINIMUM_SLIDE_SPEED = tonumber(settings.SlideMinimumSpeed) or tonumber(settings.MinimumAssistSpeed) or 12
local FLAT_ASSIST_ACCELERATION = tonumber(settings.SlideFlatAssistAcceleration) or tonumber(settings.MinimumAssistAcceleration) or 7
local STEERING_ACCELERATION = tonumber(settings.SteeringAcceleration) or 42
local LATERAL_DAMPING = tonumber(settings.LateralDamping) or 3.4
local ROLLING_DECELERATION = tonumber(settings.RollingDeceleration) or 1.6
local MAXIMUM_SPEED = tonumber(settings.MaximumSpeed) or 145
local OVERSPEED_BRAKE_ACCELERATION = tonumber(settings.OverspeedBrakeAcceleration) or 18
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
    lastStartRequestAt = 0,
    startActionBound = false,
    lastPhase = nil,
    lastGrounded = nil,
    lastGroundPartName = nil,
    lastSurfaceLogAt = 0,
    lastForceLogAt = 0,
    lastAirborneLogAt = 0,
    lastFailLogAt = 0,
    defaults = {
        walkSpeed = 16,
        jumpPower = 50,
        autoRotate = true,
    },
}

local START_ACTION_NAME = "DownhillStartAction"
local START_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 100

local function formatVector3(value)
    if not value then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", value.X, value.Y, value.Z)
end

local function logStartFlowClient(message)
    if not START_FLOW_LOG_ENABLED then
        return
    end
    print(message)
end

local function logSlideDebug(message)
    if not START_FLOW_LOG_ENABLED then
        return
    end
    print(message)
end

local function logSlideFail(reason, humanoid, groundPartName, velocity)
    if not START_FLOW_LOG_ENABLED then
        return
    end

    local now = os.clock()
    if now - runtime.lastFailLogAt < DEBUG_INTERVAL then
        return
    end
    runtime.lastFailLogAt = now

    warn(string.format(
        "[SlideFail] reason=%s phase=%s walkSpeed=%.1f platformStand=%s groundPart=%s velocity=%s",
        tostring(reason),
        tostring(getPhase()),
        humanoid and humanoid.WalkSpeed or -1,
        tostring(humanoid and humanoid.PlatformStand),
        tostring(groundPartName),
        formatVector3(velocity)
    ))
end

local function warnStartFlowClient(stage, reason)
    if not START_FLOW_LOG_ENABLED then
        return
    end
    warn(string.format("[StartFlowFail] stage=%s reason=%s", tostring(stage), tostring(reason)))
end

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
    local phase = getPhase()
    if phase ~= "Waiting" then
        warnStartFlowClient(2, "not_waiting")
        return
    end

    if runtime.startRequested then
        if os.clock() - runtime.lastStartRequestAt > START_RETRY_SECONDS then
            runtime.startRequested = false
        else
            warnStartFlowClient(2, "already_requested")
            return
        end
    end

    runtime.startRequested = true
    runtime.lastStartRequestAt = os.clock()
    logStartFlowClient("[StartFlow:2] remote fired")
    logStartFlowClient("[StartClient] start input accepted")
    logStartFlowClient("[StartClient] FireServer StartRequested")
    startRequest:FireServer()

    task.delay(START_RETRY_SECONDS, function()
        if getPhase() == "Waiting" then
            runtime.startRequested = false
            warnStartFlowClient(2, "request_timeout_retry_enabled")
        end
    end)
end

local function logStartInput(keyName, gameProcessed)
    if not START_FLOW_LOG_ENABLED then
        return
    end

    print(string.format(
        "[StartInput] key=%s processed=%s phase=%s requested=%s",
        keyName,
        tostring(gameProcessed),
        tostring(getPhase()),
        tostring(runtime.startRequested)
    ))
end

local function resetStartRequestIfNeeded(phase)
    if phase == "Waiting" then
        runtime.startRequested = false
        return
    end

    if phase == "Sliding" or phase == "Dead" or phase == "Recovering" or phase == "Unavailable" then
        runtime.startRequested = false
    end
end

local function handleStartAction(_, inputState, inputObject)
    local phase = getPhase()
    if phase ~= "Waiting" then
        return Enum.ContextActionResult.Pass
    end

    if inputState == Enum.UserInputState.Begin then
        local keyName = inputObject and inputObject.KeyCode and inputObject.KeyCode.Name or "Unknown"
        if keyName == "W" or keyName == "Up" then
            if UserInputService:GetFocusedTextBox() then
                warnStartFlowClient(1, "textbox_focused")
                return Enum.ContextActionResult.Sink
            end

            if START_FLOW_LOG_ENABLED then
                print(string.format("[StartAction] key=%s inputState=Begin phase=%s sink=true", keyName, phase))
            end
            logStartFlowClient("[StartFlow:1] input detected")
            requestStart()
            return Enum.ContextActionResult.Sink
        end
    end

    return Enum.ContextActionResult.Sink
end

local function bindStartAction()
    if runtime.startActionBound then
        return
    end

    ContextActionService:BindActionAtPriority(
        START_ACTION_NAME,
        handleStartAction,
        false,
        START_ACTION_PRIORITY,
        Enum.KeyCode.W,
        Enum.KeyCode.Up
    )

    runtime.startActionBound = true
end

local function unbindStartAction()
    if not runtime.startActionBound then
        return
    end

    ContextActionService:UnbindAction(START_ACTION_NAME)
    runtime.startActionBound = false
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
    humanoid.Sit = false
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
    humanoid.PlatformStand = false
    if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
    end
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
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
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
    local previousPhase = runtime.lastPhase

    resetStartRequestIfNeeded(phase)

    if waiting or sliding or phase == "Loading" then
        disableControls()
    else
        enableControls()
    end

    if waiting then
        bindStartAction()
    else
        unbindStartAction()
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

    if START_FLOW_LOG_ENABLED and previousPhase ~= phase then
        if previousPhase then
            logSlideDebug(string.format("[SlideState] %s -> %s", previousPhase, phase))
        end
    end
    runtime.lastPhase = phase

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

local function evaluateSurface(root)
    local sample = DownhillCourse.raycastRoad(
        root.Position + Vector3.new(0, GROUND_PROBE_HEIGHT, 0),
        GROUND_RAY_DISTANCE + GROUND_PROBE_HEIGHT
    )

    if not sample then
        return nil
    end

    local normal = sample.result.Normal
    if normal.Magnitude <= 0.001 then
        return nil
    end
    normal = normal.Unit

    local gravityAcceleration = Vector3.new(0, -workspace.Gravity, 0)
    local slopeAcceleration = gravityAcceleration - (normal * gravityAcceleration:Dot(normal))
    local slopeMagnitude = slopeAcceleration.Magnitude
    local downhillDirection = nil
    if slopeMagnitude > 0.001 then
        downhillDirection = slopeAcceleration.Unit
    end

    local tangentForward = nil
    local roadForward = DownhillCourse.getForward(sample.index, 1) or runtime.lastForward
    if roadForward then
        tangentForward = projectOntoSurface(roadForward, normal)
    end

    return {
        sample = sample,
        normal = normal,
        slopeAcceleration = slopeAcceleration,
        slopeMagnitude = slopeMagnitude,
        downhillDirection = downhillDirection,
        tangentForward = tangentForward,
    }
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

    local velocity = root.AssemblyLinearVelocity
    local surface = evaluateSurface(root)

    if not surface then
        force.Force = Vector3.zero

        if runtime.lastGrounded ~= false then
            logSlideDebug("[SlideSurface] part=nil normal=(0.000,0.000,0.000) grounded=false")
        end

        if runtime.lastGrounded ~= false or (os.clock() - runtime.lastAirborneLogAt) >= DEBUG_INTERVAL then
            runtime.lastAirborneLogAt = os.clock()
            logSlideDebug("[SlideAirborne] forceDisabled=true")
        end
        runtime.lastGrounded = false
        runtime.lastGroundPartName = nil

        DownhillState.update({
            active = true,
            grounded = false,
            speed = velocity.Magnitude,
            steerInput = getSteerInput(),
            rootPosition = root.Position,
        })
        return
    end

    local sample = surface.sample
    local normal = surface.normal
    local slopeAcceleration = surface.slopeAcceleration
    local slopeMagnitude = surface.slopeMagnitude
    local downhillDirection = surface.downhillDirection
    local tangentForward = surface.tangentForward

    runtime.currentRoadIndex = sample.index
    if tangentForward then
        runtime.lastForward = tangentForward
    end

    if runtime.lastGrounded ~= true
        or runtime.lastGroundPartName ~= sample.road.Name
        or (os.clock() - runtime.lastSurfaceLogAt) >= DEBUG_INTERVAL then
        runtime.lastSurfaceLogAt = os.clock()
        logSlideDebug(string.format(
            "[SlideSurface] part=%s normal=%s slopeAcceleration=%s grounded=true",
            sample.road:GetFullName(),
            formatVector3(normal),
            formatVector3(slopeAcceleration)
        ))
    end
    runtime.lastGrounded = true
    runtime.lastGroundPartName = sample.road.Name

    local rightBase = tangentForward or runtime.lastForward
    local right = rightBase:Cross(normal)
    if right.Magnitude <= 0.001 then
        force.Force = Vector3.zero
        logSlideFail("invalid_right", humanoid, sample.road.Name, root.AssemblyLinearVelocity)
        return
    end
    right = right.Unit

    if humanoid.WalkSpeed > 0.05 then
        logSlideFail("walkspeed_not_zero", humanoid, sample.road.Name, root.AssemblyLinearVelocity)
    end

    local tangentVelocity = velocity - normal * velocity:Dot(normal)
    local tangentSpeed = tangentVelocity.Magnitude
    local downhillSpeed = 0
    local isMovingUphill = false
    if downhillDirection then
        downhillSpeed = tangentVelocity:Dot(downhillDirection)
        isMovingUphill = downhillSpeed < -0.05
    end
    local lateralSpeed = tangentVelocity:Dot(right)
    local steerInput = getSteerInput()

    local acceleration = slopeAcceleration * SLIDE_GRAVITY_MULTIPLIER
    acceleration += right * ((steerInput * STEERING_ACCELERATION) - (lateralSpeed * LATERAL_DAMPING))

    if tangentSpeed > 0.5 then
        acceleration -= tangentVelocity.Unit * ROLLING_DECELERATION
    end

    local flatAssist = 0
    local onFlat = slopeMagnitude <= FLAT_SLOPE_THRESHOLD
    if onFlat and downhillDirection and not isMovingUphill and tangentSpeed < MINIMUM_SLIDE_SPEED then
        local assistRatio = math.clamp(1 - (tangentSpeed / math.max(MINIMUM_SLIDE_SPEED, 1)), 0, 1)
        flatAssist = FLAT_ASSIST_ACCELERATION * assistRatio
        acceleration += downhillDirection * flatAssist
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
        slope = slopeMagnitude,
        lookAhead = 1,
        steerInput = steerInput,
        forward = downhillDirection or rightBase,
        groundNormal = normal,
        rootPosition = root.Position,
    })

    local now = os.clock()
    if (DEBUG_ENABLED or START_FLOW_LOG_ENABLED) and now >= runtime.lastForceLogAt then
        runtime.lastForceLogAt = now + DEBUG_INTERVAL
        logSlideDebug(string.format(
            "[SlideForce] slopeForce=%s flatAssist=%.3f speed=%.3f grounded=true",
            formatVector3(slopeAcceleration * root.AssemblyMass * SLIDE_GRAVITY_MULTIPLIER),
            flatAssist,
            tangentSpeed
        ))
    end

    if DEBUG_ENABLED and now >= runtime.lastDebugAt then
        runtime.lastDebugAt = now + DEBUG_INTERVAL
        print(string.format(
            "[GravitySlide] phase=Sliding road=%s speed=%.2f downhillSpeed=%.2f lateralSpeed=%.2f slope=%.3f steer=%.2f force=%.2f",
            sample.road.Name,
            tangentSpeed,
            downhillSpeed,
            lateralSpeed,
            slopeMagnitude,
            steerInput,
            force.Force.Magnitude
        ))
    end
end

local function cleanupCharacter()
    destroyForce()
    unbindStartAction()
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
    local phase = getPhase()
    if phase == "Waiting" then
        if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
            local keyName = (input.KeyCode == Enum.KeyCode.W) and "W" or "Up"
            logStartInput(keyName, gameProcessed)
            if START_FLOW_LOG_ENABLED then
                print(string.format("[StartInputProbe] key=%s processed=%s", keyName, tostring(gameProcessed)))
            end
        end
        return
    end

    if gameProcessed then
        return
    end

    if phase ~= "Sliding" then
        return
    end
    if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
        if START_FLOW_LOG_ENABLED then
            print("[SteerInput] key=Left phase=Sliding")
        end
        inputState.left = true
    elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
        if START_FLOW_LOG_ENABLED then
            print("[SteerInput] key=Right phase=Sliding")
        end
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

print(string.format("[Gate1Build] client=%s", BUILD_ID))
logSlideDebug("[SlideSystem] enabled")
if START_FLOW_LOG_ENABLED then
    print(string.format("[StartClient] remote=%s", startRequest:GetFullName()))
end
print("[GravitySlide] client controller enabled")
