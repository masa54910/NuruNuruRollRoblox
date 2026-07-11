local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)

local projectConfig = Config.Project or {}
if projectConfig.EnableGravitySlideController ~= true then
    return
end

if projectConfig.EnableProxySlideVehicle == true then
    print("[ProxySlideLegacy] gravitySlideControllerDisabled=true")
    return
end

local BUILD_ID = "GATE1_FIXED_SLED_BOUNCE_V7"

local IS_STUDIO = RunService:IsStudio()
local DEBUG_ENABLED = IS_STUDIO and projectConfig.EnableDownhillDebug == true

local settings = Config.GravitySlide or {}
local startSettings = Config.DownhillStart or {}

local GROUND_RAY_DISTANCE = tonumber(settings.GroundRayDistance) or 12
local GROUND_PROBE_HEIGHT = tonumber(settings.GroundProbeHeight) or 2

local SLIDE_GRAVITY_MULTIPLIER = tonumber(settings.SlideGravityMultiplier) or 1
local SLIDE_FLAT_SLOPE_THRESHOLD = tonumber(settings.SlideFlatSlopeThreshold) or 0.02
local SLIDE_MINIMUM_SPEED = tonumber(settings.SlideMinimumSpeed) or 12
local SLIDE_FLAT_ASSIST_ACCELERATION = tonumber(settings.SlideFlatAssistAcceleration) or 7
local SLIDE_ROLLING_DECELERATION = tonumber(settings.RollingDeceleration) or 1.6
local SLIDE_MAXIMUM_SPEED = tonumber(settings.MaximumSpeed) or 145
local SLIDE_OVERSPEED_BRAKE_ACCELERATION = tonumber(settings.OverspeedBrakeAcceleration) or 18

local SLIDE_STEER_RESPONSE = tonumber(settings.SlideSteerResponse) or 7
local SLIDE_STEER_RETURN_RESPONSE = tonumber(settings.SlideSteerReturnResponse) or 5
local SLIDE_STEER_DEGREES_PER_SECOND = tonumber(settings.SlideSteerDegreesPerSecond) or 70
local SLIDE_HIGH_SPEED_STEER_DEGREES_PER_SECOND = tonumber(settings.SlideHighSpeedSteerDegreesPerSecond) or 38
local SLIDE_HIGH_SPEED_THRESHOLD = tonumber(settings.SlideHighSpeedThreshold) or 55
local SLIDE_STEER_DIRECTION_BLEND_GAIN = tonumber(settings.SlideSteerDirectionBlendGain) or 6

local SLIDE_ROAD_STICK_ACCELERATION = tonumber(settings.SlideRoadStickAcceleration) or 18
local SLIDE_ROAD_STICK_MAXIMUM_SPEED = tonumber(settings.SlideRoadStickMaximumSpeed) or 4
local SLIDE_ROAD_STICK_SPEED = tonumber(settings.SlideRoadStickSpeed) or 0.35

local SLIDE_COLLIDER_WIDTH = tonumber(settings.SlideColliderWidth) or 2.3
local SLIDE_COLLIDER_LENGTH = tonumber(settings.SlideColliderLength) or 4.6
local SLIDE_COLLIDER_THICKNESS = tonumber(settings.SlideColliderThickness) or 0.65
local SLIDE_COLLIDER_VERTICAL_OFFSET = tonumber(settings.SlideColliderVerticalOffset) or -1.35
local SLIDE_COLLIDER_DENSITY = tonumber(settings.SlideColliderDensity) or 1
local SLIDE_COLLIDER_FRICTION = tonumber(settings.SlideColliderFriction) or 0.02
local SLIDE_COLLIDER_ELASTICITY = tonumber(settings.SlideColliderElasticity) or 0
local SLIDE_COLLIDER_FRICTION_WEIGHT = tonumber(settings.SlideColliderFrictionWeight) or 100
local SLIDE_COLLIDER_ELASTICITY_WEIGHT = tonumber(settings.SlideColliderElasticityWeight) or 100

local SLIDE_POSE_PITCH_OFFSET = math.rad(tonumber(settings.SlidePosePitchOffsetDegrees) or 0)
local SLIDE_POSE_YAW_OFFSET = math.rad(tonumber(settings.SlidePoseYawOffsetDegrees) or 0)
local SLIDE_POSE_ROLL_OFFSET = math.rad(tonumber(settings.SlidePoseRollOffsetDegrees) or 0)

local SLIDE_NORMAL_ORIENTATION_RESPONSIVENESS = tonumber(settings.SlideNormalOrientationResponsiveness) or 12
local SLIDE_WALL_TURN_RESPONSIVENESS = tonumber(settings.SlideWallTurnResponsiveness) or 18
local SLIDE_ORIENTATION_MAX_TORQUE = tonumber(settings.SlideOrientationMaxTorque) or 35000

local SLIDE_WALL_NORMAL_DOT_THRESHOLD = tonumber(settings.SlideWallNormalDotThreshold) or 0.45
local SLIDE_WALL_BOUNCE_COOLDOWN = tonumber(settings.SlideWallBounceCooldown) or 0.10
local SLIDE_WALL_SAME_SURFACE_DOT_THRESHOLD = tonumber(settings.SlideWallSameSurfaceDotThreshold) or 0.95
local SLIDE_WALL_SEPARATION_DISTANCE = tonumber(settings.SlideWallSeparationDistance) or 0.08
local SLIDE_WALL_SPEED_RETENTION = tonumber(settings.SlideWallSpeedRetention) or 1
local SLIDE_WALL_MINIMUM_SPEED_RATIO = tonumber(settings.SlideWallMinimumSpeedRatio) or 0.98
local SLIDE_WALL_MAXIMUM_SPEED_RATIO = tonumber(settings.SlideWallMaximumSpeedRatio) or 1.02
local SLIDE_WALL_CAST_MIN_DISTANCE = tonumber(settings.SlideWallCastMinimumDistance) or 0.5
local SLIDE_WALL_CAST_SAFETY_MARGIN = tonumber(settings.SlideWallCastSafetyMargin) or 0.3

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

local getPhase

local inputState = {
    steerKeys = {
        A = false,
        D = false,
        Left = false,
        Right = false,
    },
    gamepadX = 0,
    rawSteer = 0,
    targetSteer = 0,
    currentSteer = 0,
}

local runtime = {
    character = nil,
    humanoid = nil,
    root = nil,

    force = nil,
    forceAttachment = nil,

    orientationAlign = nil,
    orientationAttachment = nil,

    slideCollider = nil,
    slideColliderWeld = nil,

    controls = nil,
    controlsDisabled = false,

    startRequested = false,
    lastStartRequestAt = 0,
    startActionBound = false,
    steerActionBound = false,

    lastPhase = nil,
    lastForward = Vector3.new(0, 0, -1),
    currentHeading = nil,
    targetHeading = nil,

    slidePoseEntered = false,
    animateScript = nil,
    animateWasDisabled = nil,
    motorTransforms = nil,
    partPhysicsState = nil,

    lastWallPart = nil,
    lastWallNormal = nil,
    lastWallHitAt = 0,

    lastSurfaceLogAt = 0,
    lastSteerLogAt = 0,
    lastWallLogAt = 0,
    lastFailLogAt = 0,
    lastPoseLogAt = 0,

    defaults = {
        walkSpeed = 16,
        jumpPower = 50,
        autoRotate = true,
    },
}

local START_ACTION_NAME = "DownhillStartAction"
local STEER_ACTION_NAME = "DownhillSteerAction"
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 100

local function formatVector3(value)
    if not value then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", value.X, value.Y, value.Z)
end

local function logDebug(message)
    if not DEBUG_ENABLED then
        return
    end
    print(message)
end

local function warnDebug(message)
    if not DEBUG_ENABLED then
        return
    end
    warn(message)
end

local function logSlideFail(reason, humanoid, groundPartName, velocity)
    if not DEBUG_ENABLED then
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

getPhase = function()
    return localPlayer:GetAttribute("DownhillPhase") or "Loading"
end

local function requestStart()
    if getPhase() ~= "Waiting" then
        return
    end

    if runtime.startRequested then
        if os.clock() - runtime.lastStartRequestAt > START_RETRY_SECONDS then
            runtime.startRequested = false
        else
            return
        end
    end

    runtime.startRequested = true
    runtime.lastStartRequestAt = os.clock()
    startRequest:FireServer()

    task.delay(START_RETRY_SECONDS, function()
        if getPhase() == "Waiting" then
            runtime.startRequested = false
        end
    end)
end

local function handleStartAction(_, inputStatePhase, inputObject)
    local phase = getPhase()
    if phase ~= "Waiting" then
        return Enum.ContextActionResult.Pass
    end

    if inputStatePhase == Enum.UserInputState.Begin then
        local keyName = inputObject and inputObject.KeyCode and inputObject.KeyCode.Name or "Unknown"
        if keyName == "W" or keyName == "Up" then
            if UserInputService:GetFocusedTextBox() then
                return Enum.ContextActionResult.Sink
            end
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
        ACTION_PRIORITY,
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

local function updateRawSteerInput()
    local value = 0
    if inputState.steerKeys.A or inputState.steerKeys.Left then
        value -= 1
    end
    if inputState.steerKeys.D or inputState.steerKeys.Right then
        value += 1
    end

    if math.abs(inputState.gamepadX) > math.abs(value) then
        value = inputState.gamepadX
    end

    inputState.rawSteer = math.clamp(value, -1, 1)
    inputState.targetSteer = inputState.rawSteer
end

local function keyNameFromInput(inputObject)
    if not inputObject then
        return nil
    end

    if inputObject.KeyCode == Enum.KeyCode.A then
        return "A"
    end
    if inputObject.KeyCode == Enum.KeyCode.D then
        return "D"
    end
    if inputObject.KeyCode == Enum.KeyCode.Left then
        return "Left"
    end
    if inputObject.KeyCode == Enum.KeyCode.Right then
        return "Right"
    end

    return nil
end

local function handleSteerAction(_, inputStatePhase, inputObject)
    if getPhase() ~= "Sliding" then
        return Enum.ContextActionResult.Pass
    end

    local keyName = keyNameFromInput(inputObject)
    if not keyName then
        return Enum.ContextActionResult.Pass
    end

    if inputStatePhase == Enum.UserInputState.Begin then
        inputState.steerKeys[keyName] = true
    elseif inputStatePhase == Enum.UserInputState.End or inputStatePhase == Enum.UserInputState.Cancel then
        inputState.steerKeys[keyName] = false
    end

    updateRawSteerInput()

    if DEBUG_ENABLED then
        logDebug(string.format(
            "[SteerInput] key=%s state=%s raw=%.2f phase=%s sink=true",
            keyName,
            tostring(inputStatePhase),
            inputState.rawSteer,
            tostring(getPhase())
        ))
    end

    return Enum.ContextActionResult.Sink
end

local function bindSteerAction()
    if runtime.steerActionBound then
        return
    end

    ContextActionService:BindActionAtPriority(
        STEER_ACTION_NAME,
        handleSteerAction,
        false,
        ACTION_PRIORITY,
        Enum.KeyCode.A,
        Enum.KeyCode.D,
        Enum.KeyCode.Left,
        Enum.KeyCode.Right
    )

    runtime.steerActionBound = true
end

local function unbindSteerAction()
    if not runtime.steerActionBound then
        return
    end

    ContextActionService:UnbindAction(STEER_ACTION_NAME)
    runtime.steerActionBound = false
end

if startButton then
    startButton.Activated:Connect(requestStart)
end

local function destroySlideForce()
    if runtime.force then
        runtime.force:Destroy()
        runtime.force = nil
    end
    if runtime.forceAttachment then
        runtime.forceAttachment:Destroy()
        runtime.forceAttachment = nil
    end
end

local function ensureSlideForce()
    local root = runtime.root
    if not root or not root.Parent then
        return nil
    end

    if runtime.force and runtime.force.Parent == root then
        return runtime.force
    end

    destroySlideForce()

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

    runtime.forceAttachment = attachment
    runtime.force = force

    return force
end

local function destroyOrientationConstraint()
    if runtime.orientationAlign then
        runtime.orientationAlign:Destroy()
        runtime.orientationAlign = nil
    end
    if runtime.orientationAttachment then
        runtime.orientationAttachment:Destroy()
        runtime.orientationAttachment = nil
    end
end

local function ensureOrientationConstraint()
    local root = runtime.root
    if not root or not root.Parent then
        return nil
    end

    if runtime.orientationAlign and runtime.orientationAlign.Parent == root then
        return runtime.orientationAlign
    end

    destroyOrientationConstraint()

    local attachment = Instance.new("Attachment")
    attachment.Name = "DownhillSlideOrientationAttachment"
    attachment.Parent = root

    local align = Instance.new("AlignOrientation")
    align.Name = "DownhillSlideOrientation"
    align.Attachment0 = attachment
    align.Mode = Enum.OrientationAlignmentMode.OneAttachment
    align.PrimaryAxisOnly = false
    align.ReactionTorqueEnabled = false
    align.RigidityEnabled = false
    align.Responsiveness = SLIDE_NORMAL_ORIENTATION_RESPONSIVENESS
    align.MaxTorque = SLIDE_ORIENTATION_MAX_TORQUE
    align.Parent = root

    runtime.orientationAttachment = attachment
    runtime.orientationAlign = align

    return align
end

local function destroySlideCollider()
    if runtime.slideColliderWeld then
        runtime.slideColliderWeld:Destroy()
        runtime.slideColliderWeld = nil
    end
    if runtime.slideCollider then
        runtime.slideCollider:Destroy()
        runtime.slideCollider = nil
    end
end

local function ensureSlideCollider()
    local root = runtime.root
    local character = runtime.character
    if not root or not character then
        return nil
    end

    if runtime.slideCollider and runtime.slideCollider.Parent == character then
        return runtime.slideCollider
    end

    destroySlideCollider()

    local collider = Instance.new("Part")
    collider.Name = "DownhillSlideCollider"
    collider.Size = Vector3.new(SLIDE_COLLIDER_WIDTH, SLIDE_COLLIDER_THICKNESS, SLIDE_COLLIDER_LENGTH)
    collider.Transparency = 1
    collider.CanCollide = true
    collider.CanTouch = true
    collider.CanQuery = false
    collider.CastShadow = false
    collider.Massless = false
    collider.Anchored = false
    collider.CFrame = root.CFrame * CFrame.new(0, SLIDE_COLLIDER_VERTICAL_OFFSET, 0)
    collider.CustomPhysicalProperties = PhysicalProperties.new(
        SLIDE_COLLIDER_DENSITY,
        SLIDE_COLLIDER_FRICTION,
        SLIDE_COLLIDER_ELASTICITY,
        SLIDE_COLLIDER_FRICTION_WEIGHT,
        SLIDE_COLLIDER_ELASTICITY_WEIGHT
    )
    collider.Parent = character

    local weld = Instance.new("WeldConstraint")
    weld.Name = "DownhillSlideColliderWeld"
    weld.Part0 = root
    weld.Part1 = collider
    weld.Parent = collider

    runtime.slideCollider = collider
    runtime.slideColliderWeld = weld

    return collider
end

local function capturePartPhysicsState(character)
    local captured = {}

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            captured[descendant] = {
                canCollide = descendant.CanCollide,
                canTouch = descendant.CanTouch,
                massless = descendant.Massless,
                customPhysicalProperties = descendant.CustomPhysicalProperties,
            }
        end
    end

    return captured
end

local function applySlidePartPhysics(character)
    if not runtime.partPhysicsState then
        runtime.partPhysicsState = capturePartPhysicsState(character)
    end

    for part in pairs(runtime.partPhysicsState) do
        if part and part.Parent then
            if part ~= runtime.slideCollider then
                part.CanCollide = false
                part.CanTouch = false
                if part ~= runtime.root then
                    part.Massless = true
                end
            end
        end
    end
end

local function restorePartPhysicsState()
    if not runtime.partPhysicsState then
        return
    end

    for part, state in pairs(runtime.partPhysicsState) do
        if part and part.Parent then
            part.CanCollide = state.canCollide
            part.CanTouch = state.canTouch
            part.Massless = state.massless
            part.CustomPhysicalProperties = state.customPhysicalProperties
        end
    end

    runtime.partPhysicsState = nil
end

local function getSlideMotorTransform(motor)
    local name = motor.Name

    if name == "Waist" then
        return CFrame.Angles(math.rad(-16), 0, 0)
    end
    if name == "Neck" then
        return CFrame.Angles(math.rad(8), 0, 0)
    end
    if name == "LeftShoulder" then
        return CFrame.Angles(math.rad(12), 0, math.rad(-10))
    end
    if name == "RightShoulder" then
        return CFrame.Angles(math.rad(12), 0, math.rad(10))
    end
    if name == "LeftHip" then
        return CFrame.Angles(math.rad(-20), 0, math.rad(-3))
    end
    if name == "RightHip" then
        return CFrame.Angles(math.rad(-20), 0, math.rad(3))
    end
    if name == "LeftKnee" then
        return CFrame.Angles(math.rad(14), 0, 0)
    end
    if name == "RightKnee" then
        return CFrame.Angles(math.rad(14), 0, 0)
    end

    if name == "Left Shoulder" then
        return CFrame.Angles(math.rad(10), 0, math.rad(-8))
    end
    if name == "Right Shoulder" then
        return CFrame.Angles(math.rad(10), 0, math.rad(8))
    end
    if name == "Left Hip" then
        return CFrame.Angles(math.rad(-16), 0, math.rad(-2))
    end
    if name == "Right Hip" then
        return CFrame.Angles(math.rad(-16), 0, math.rad(2))
    end

    return nil
end

local function stopAnimationTracks(humanoid)
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        return 0
    end

    local stoppedTracks = 0
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        track:Stop(0.1)
        stoppedTracks += 1
    end

    return stoppedTracks
end

local function applySlidePose()
    if runtime.slidePoseEntered then
        return
    end

    local character = runtime.character
    local humanoid = runtime.humanoid
    if not character or not humanoid then
        return
    end

    runtime.animateScript = character:FindFirstChild("Animate")
    runtime.animateWasDisabled = runtime.animateScript and runtime.animateScript.Disabled or nil

    if runtime.animateScript then
        runtime.animateScript.Disabled = true
    end

    local stoppedTracks = stopAnimationTracks(humanoid)

    local transforms = {}
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("Motor6D") then
            transforms[descendant] = descendant.Transform
            local slideTransform = getSlideMotorTransform(descendant)
            if slideTransform then
                descendant.Transform = slideTransform
            end
        end
    end

    runtime.motorTransforms = transforms
    runtime.slidePoseEntered = true

    logDebug(string.format(
        "[SlidePose] entered=true animateDisabled=%s stoppedTracks=%d rigType=%s",
        tostring(runtime.animateScript and runtime.animateScript.Disabled or false),
        stoppedTracks,
        tostring(humanoid.RigType)
    ))
end

local function restoreSlidePose()
    if runtime.motorTransforms then
        for motor, transform in pairs(runtime.motorTransforms) do
            if motor and motor.Parent then
                motor.Transform = transform
            end
        end
    end

    runtime.motorTransforms = nil

    if runtime.animateScript and runtime.animateScript.Parent then
        if runtime.animateWasDisabled ~= nil then
            runtime.animateScript.Disabled = runtime.animateWasDisabled
        else
            runtime.animateScript.Disabled = false
        end
    end

    runtime.animateScript = nil
    runtime.animateWasDisabled = nil

    if runtime.slidePoseEntered then
        logDebug("[SlidePose] entered=false animateRestored=true motorsRestored=true")
    end

    runtime.slidePoseEntered = false
end

local function applySlidingHumanoidSettings()
    local humanoid = runtime.humanoid
    if not humanoid or not humanoid.Parent then
        return
    end

    humanoid.Sit = false
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
    humanoid.PlatformStand = true
    humanoid:ChangeState(Enum.HumanoidStateType.Physics)

    humanoid.AutoRotate = false
    humanoid.WalkSpeed = SLIDING_WALK_SPEED
    humanoid.UseJumpPower = true
    humanoid.JumpPower = SLIDING_JUMP_POWER
    humanoid:Move(Vector3.zero, false)
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

    local gravityAcceleration = Vector3.new(0, -Workspace.Gravity, 0)
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

local function updateSteerSmoothing(dt)
    local response = SLIDE_STEER_RESPONSE
    if math.abs(inputState.targetSteer) <= 0.001 then
        response = SLIDE_STEER_RETURN_RESPONSE
    end

    local alpha = math.clamp((dt or (1 / 60)) * response, 0, 1)
    inputState.currentSteer += (inputState.targetSteer - inputState.currentSteer) * alpha
end

local function computeSteerRateDegrees(speed)
    local t = math.clamp(math.abs(speed) / math.max(SLIDE_HIGH_SPEED_THRESHOLD, 1), 0, 1)
    return SLIDE_STEER_DEGREES_PER_SECOND + ((SLIDE_HIGH_SPEED_STEER_DEGREES_PER_SECOND - SLIDE_STEER_DEGREES_PER_SECOND) * t)
end

local function updateHeading(surfaceNormal, baseHeading, speed, dt)
    local steerRateDegrees = computeSteerRateDegrees(speed)
    local turnAngle = math.rad(steerRateDegrees) * inputState.currentSteer * (dt or (1 / 60))

    local rotation = CFrame.fromAxisAngle(surfaceNormal, turnAngle)
    local headingBefore = runtime.currentHeading or baseHeading
    local rotated = rotation:VectorToWorldSpace(headingBefore)
    local target = projectOntoSurface(rotated, surfaceNormal) or headingBefore

    runtime.targetHeading = target

    local blend = math.clamp((dt or (1 / 60)) * SLIDE_STEER_DIRECTION_BLEND_GAIN, 0, 1)
    local blended = headingBefore:Lerp(runtime.targetHeading, blend)
    local headingAfter = projectOntoSurface(blended, surfaceNormal) or headingBefore

    runtime.currentHeading = headingAfter

    local now = os.clock()
    if DEBUG_ENABLED and now - runtime.lastSteerLogAt >= DEBUG_INTERVAL then
        runtime.lastSteerLogAt = now
        logDebug(string.format(
            "[SlideSteer] input=%.2f speed=%.3f headingBefore=%s headingAfter=%s turnRate=%.2f",
            inputState.currentSteer,
            speed,
            formatVector3(headingBefore),
            formatVector3(headingAfter),
            steerRateDegrees
        ))
    end

    return headingBefore, headingAfter, steerRateDegrees
end

local function getWallCastOrigins(root, rightOnSurface)
    local collider = runtime.slideCollider
    local center = collider and collider.Position or root.Position

    if not rightOnSurface or rightOnSurface.Magnitude <= 0.001 then
        return { center }
    end

    local lateralOffset = ((collider and collider.Size.X) or SLIDE_COLLIDER_WIDTH) * 0.45
    return {
        center,
        center + (rightOnSurface * lateralOffset),
        center - (rightOnSurface * lateralOffset),
    }
end

local function detectWallAhead(root, character, surfaceNormal, rightOnSurface, tangentVelocity, dt)
    local speed = tangentVelocity.Magnitude
    if speed <= 1 then
        return nil
    end

    local direction = tangentVelocity.Unit
    local castDistance = math.max(SLIDE_WALL_CAST_MIN_DISTANCE, (speed * (dt or (1 / 60))) + SLIDE_WALL_CAST_SAFETY_MARGIN)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.IgnoreWater = true

    local bestHit = nil
    local bestDistance = math.huge

    for _, origin in ipairs(getWallCastOrigins(root, rightOnSurface)) do
        local result = Workspace:Raycast(origin, direction * castDistance, params)
        if result and result.Instance and result.Instance.CanCollide then
            local hitNormal = result.Normal
            local wallDot = math.abs(hitNormal:Dot(surfaceNormal))
            local movingIntoWall = tangentVelocity:Dot(hitNormal) < -0.1

            if wallDot < SLIDE_WALL_NORMAL_DOT_THRESHOLD and movingIntoWall and not DownhillCourse.isRoadPart(result.Instance) then
                if result.Distance < bestDistance then
                    bestDistance = result.Distance
                    bestHit = {
                        result = result,
                        wallDot = wallDot,
                    }
                end
            end
        end
    end

    if bestHit and DEBUG_ENABLED and (os.clock() - runtime.lastWallLogAt >= DEBUG_INTERVAL) then
        runtime.lastWallLogAt = os.clock()
        logDebug(string.format(
            "[WallDetect] part=%s hitNormal=%s wallNormalOnSurface=%s distance=%.3f",
            bestHit.result.Instance:GetFullName(),
            formatVector3(bestHit.result.Normal),
            "(pending)",
            bestHit.result.Distance
        ))
    end

    return bestHit
end

local function reflectOnWall(root, character, surfaceNormal, tangentVelocity, wallHit)
    local hitPart = wallHit.result.Instance
    local hitNormal = wallHit.result.Normal

    local wallNormalOnSurfaceVector = hitNormal - (surfaceNormal * hitNormal:Dot(surfaceNormal))
    if wallNormalOnSurfaceVector.Magnitude <= 0.001 then
        return false
    end
    wallNormalOnSurfaceVector = wallNormalOnSurfaceVector.Unit

    local now = os.clock()
    if runtime.lastWallPart == hitPart and runtime.lastWallNormal then
        local normalDot = runtime.lastWallNormal:Dot(wallNormalOnSurfaceVector)
        if now - runtime.lastWallHitAt < SLIDE_WALL_BOUNCE_COOLDOWN and normalDot >= SLIDE_WALL_SAME_SURFACE_DOT_THRESHOLD then
            logDebug("[WallBounceIgnored] reason=same_wall_cooldown")
            return false
        end
    end

    local speedBefore = tangentVelocity.Magnitude
    if speedBefore <= 0.1 then
        return false
    end

    local reflected = tangentVelocity - (2 * tangentVelocity:Dot(wallNormalOnSurfaceVector) * wallNormalOnSurfaceVector)
    if reflected.Magnitude <= 0.001 then
        return false
    end

    local reflectedDirection = reflected.Unit
    local targetSpeed = speedBefore * SLIDE_WALL_SPEED_RETENTION
    local preservedVelocity = reflectedDirection * targetSpeed

    local speedAfter = preservedVelocity.Magnitude
    local ratio = speedAfter / math.max(speedBefore, 0.001)
    local clampedRatio = math.clamp(ratio, SLIDE_WALL_MINIMUM_SPEED_RATIO, SLIDE_WALL_MAXIMUM_SPEED_RATIO)
    if math.abs(clampedRatio - ratio) > 0.0001 then
        preservedVelocity = preservedVelocity.Unit * (speedBefore * clampedRatio)
        speedAfter = preservedVelocity.Magnitude
    end

    local finalVelocity = preservedVelocity

    local normalSpeed = finalVelocity:Dot(surfaceNormal)
    local removedSurfaceNormalSpeed = 0
    if normalSpeed > 0 then
        removedSurfaceNormalSpeed = normalSpeed
        finalVelocity -= surfaceNormal * normalSpeed
    end

    finalVelocity -= surfaceNormal * SLIDE_ROAD_STICK_SPEED

    root.AssemblyLinearVelocity = finalVelocity

    if SLIDE_WALL_SEPARATION_DISTANCE > 0 then
        character:PivotTo(character:GetPivot() + (wallNormalOnSurfaceVector * SLIDE_WALL_SEPARATION_DISTANCE))
    end

    runtime.currentHeading = reflectedDirection
    runtime.targetHeading = reflectedDirection

    runtime.lastWallPart = hitPart
    runtime.lastWallNormal = wallNormalOnSurfaceVector
    runtime.lastWallHitAt = now

    if runtime.orientationAlign then
        runtime.orientationAlign.Responsiveness = SLIDE_WALL_TURN_RESPONSIVENESS
    end

    logDebug(string.format(
        "[WallBounce] speedBefore=%.3f speedAfter=%.3f speedRatio=%.3f directionBefore=%s directionAfter=%s",
        speedBefore,
        speedAfter,
        speedAfter / math.max(speedBefore, 0.001),
        formatVector3(tangentVelocity.Unit),
        formatVector3(reflectedDirection)
    ))

    if removedSurfaceNormalSpeed > 0 or SLIDE_ROAD_STICK_SPEED > 0 then
        logDebug(string.format(
            "[WallBounceClamp] removedSurfaceNormalSpeed=%.3f roadStickApplied=%.3f",
            removedSurfaceNormalSpeed,
            SLIDE_ROAD_STICK_SPEED
        ))
    end

    return true
end

local function updateOrientation(root, surfaceNormal, feetDirection)
    local align = runtime.orientationAlign
    if not align then
        return
    end

    local base = CFrame.lookAt(root.Position, root.Position + feetDirection, surfaceNormal)
    local offset = CFrame.Angles(SLIDE_POSE_PITCH_OFFSET, SLIDE_POSE_YAW_OFFSET, SLIDE_POSE_ROLL_OFFSET)
    align.CFrame = base * offset

    local feetFirstDot = feetDirection:Dot((base * offset).LookVector)
    local chestNormalDot = (base * offset).UpVector:Dot(surfaceNormal)

    if DEBUG_ENABLED and (os.clock() - runtime.lastPoseLogAt) >= DEBUG_INTERVAL then
        runtime.lastPoseLogAt = os.clock()
        logDebug(string.format(
            "[SlidePose] feetFirstDot=%.3f chestNormalDot=%.3f platformStand=%s animateDisabled=%s",
            feetFirstDot,
            chestNormalDot,
            tostring(runtime.humanoid and runtime.humanoid.PlatformStand),
            tostring(runtime.animateScript and runtime.animateScript.Disabled)
        ))
    end
end

local function updateSlide(dt)
    local phase = getPhase()
    local root = runtime.root
    local humanoid = runtime.humanoid
    local character = runtime.character
    local force = runtime.force

    if phase ~= "Sliding" or not root or not humanoid or not character or humanoid.Health <= 0 or not force then
        if force then
            force.Force = Vector3.zero
        end
        return
    end

    applySlidingHumanoidSettings()
    updateSteerSmoothing(dt)

    local velocity = root.AssemblyLinearVelocity
    local surface = evaluateSurface(root)

    if not surface then
        force.Force = Vector3.zero
        DownhillState.update({
            active = true,
            grounded = false,
            speed = velocity.Magnitude,
            steerInput = inputState.currentSteer,
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

    local tangentVelocity = velocity - (normal * velocity:Dot(normal))
    local tangentSpeed = tangentVelocity.Magnitude

    local baseHeading = tangentForward or runtime.lastForward
    if downhillDirection and downhillDirection.Magnitude > 0.001 then
        baseHeading = downhillDirection
    end

    if tangentForward and tangentForward.Magnitude > 0.001 then
        runtime.lastForward = tangentForward
    end

    if not runtime.currentHeading or runtime.currentHeading.Magnitude <= 0.001 then
        if tangentSpeed > 0.5 then
            runtime.currentHeading = tangentVelocity.Unit
        else
            runtime.currentHeading = baseHeading
        end
        runtime.targetHeading = runtime.currentHeading
    end

    local headingBefore, headingAfter = updateHeading(normal, baseHeading, tangentSpeed, dt)
    local rightOnSurface = headingAfter:Cross(normal)
    if rightOnSurface.Magnitude <= 0.001 then
        force.Force = Vector3.zero
        logSlideFail("invalid_right_axis", humanoid, sample.road.Name, velocity)
        return
    end
    rightOnSurface = rightOnSurface.Unit

    local wallHit = detectWallAhead(root, character, normal, rightOnSurface, tangentVelocity, dt)
    if wallHit then
        local bounced = reflectOnWall(root, character, normal, tangentVelocity, wallHit)
        if bounced then
            tangentVelocity = root.AssemblyLinearVelocity - (normal * root.AssemblyLinearVelocity:Dot(normal))
            tangentSpeed = tangentVelocity.Magnitude
            headingAfter = runtime.currentHeading or headingAfter
        end
    else
        runtime.lastWallPart = nil
        runtime.lastWallNormal = nil
    end

    local desiredTangentVelocity = headingAfter * tangentSpeed
    local steerAcceleration = (desiredTangentVelocity - tangentVelocity) * SLIDE_STEER_DIRECTION_BLEND_GAIN

    local acceleration = slopeAcceleration * SLIDE_GRAVITY_MULTIPLIER
    acceleration += steerAcceleration

    if tangentSpeed > 0.5 then
        acceleration -= tangentVelocity.Unit * SLIDE_ROLLING_DECELERATION
    end

    local isMovingUphill = downhillDirection and tangentVelocity:Dot(downhillDirection) < -0.05 or false
    local flatAssist = 0
    local onFlat = slopeMagnitude <= SLIDE_FLAT_SLOPE_THRESHOLD
    if onFlat and downhillDirection and not isMovingUphill and tangentSpeed < SLIDE_MINIMUM_SPEED then
        local assistRatio = math.clamp(1 - (tangentSpeed / math.max(SLIDE_MINIMUM_SPEED, 1)), 0, 1)
        flatAssist = SLIDE_FLAT_ASSIST_ACCELERATION * assistRatio
        acceleration += downhillDirection * flatAssist
    end

    if tangentSpeed > SLIDE_MAXIMUM_SPEED then
        local excessRatio = math.clamp((tangentSpeed - SLIDE_MAXIMUM_SPEED) / math.max(SLIDE_MAXIMUM_SPEED, 1), 0, 1)
        acceleration -= tangentVelocity.Unit * (SLIDE_OVERSPEED_BRAKE_ACCELERATION * excessRatio)
    end

    local surfaceVerticalSpeed = velocity:Dot(normal)
    if surfaceVerticalSpeed > -SLIDE_ROAD_STICK_MAXIMUM_SPEED then
        acceleration -= normal * SLIDE_ROAD_STICK_ACCELERATION
    end

    force.Force = acceleration * root.AssemblyMass

    if runtime.orientationAlign then
        if os.clock() - runtime.lastWallHitAt > 0.20 then
            runtime.orientationAlign.Responsiveness = SLIDE_NORMAL_ORIENTATION_RESPONSIVENESS
        end
    end
    updateOrientation(root, normal, headingAfter)

    if DEBUG_ENABLED and (os.clock() - runtime.lastSurfaceLogAt) >= DEBUG_INTERVAL then
        runtime.lastSurfaceLogAt = os.clock()
        logDebug(string.format(
            "[SlideSurface] part=%s normal=%s grounded=true",
            sample.road:GetFullName(),
            formatVector3(normal)
        ))
    end

    DownhillState.update({
        phase = "Sliding",
        active = true,
        grounded = true,
        roadName = sample.road.Name,
        speed = tangentSpeed,
        targetSpeed = 0,
        lateral = tangentVelocity:Dot(rightOnSurface),
        slope = slopeMagnitude,
        lookAhead = 1,
        steerInput = inputState.currentSteer,
        forward = headingAfter,
        groundNormal = normal,
        rootPosition = root.Position,
    })

    local now = os.clock()
    if DEBUG_ENABLED and now - runtime.lastWallLogAt >= DEBUG_INTERVAL then
        runtime.lastWallLogAt = now
        logDebug(string.format(
            "[SlideForce] slopeForce=%s flatAssist=%.3f speed=%.3f grounded=true",
            formatVector3(slopeAcceleration * root.AssemblyMass * SLIDE_GRAVITY_MULTIPLIER),
            flatAssist,
            tangentSpeed
        ))
    end

    if DEBUG_ENABLED and now - runtime.lastSteerLogAt >= DEBUG_INTERVAL then
        runtime.lastSteerLogAt = now
        logDebug(string.format(
            "[SteerPhysics] speed=%.3f forwardSpeed=%.3f lateralSpeed=%.3f desiredLateralSpeed=%.3f steerMultiplier=%.3f force=%s",
            tangentSpeed,
            tangentVelocity:Dot(headingAfter),
            tangentVelocity:Dot(rightOnSurface),
            desiredTangentVelocity:Dot(rightOnSurface),
            computeSteerRateDegrees(tangentSpeed),
            formatVector3(steerAcceleration * root.AssemblyMass)
        ))
    end

    if DEBUG_ENABLED and now - runtime.lastFailLogAt >= DEBUG_INTERVAL then
        runtime.lastFailLogAt = now
        logDebug(string.format(
            "[SlideSteer] input=%.2f speed=%.3f headingBefore=%s headingAfter=%s turnRate=%.2f",
            inputState.currentSteer,
            tangentSpeed,
            formatVector3(headingBefore),
            formatVector3(headingAfter),
            computeSteerRateDegrees(tangentSpeed)
        ))
    end
end

local function exitSlideMode()
    restoreSlidePose()
    restorePartPhysicsState()
    destroySlideCollider()
    destroyOrientationConstraint()
end

local function enterSlideMode()
    local character = runtime.character
    if not character then
        return
    end

    ensureSlideForce()
    ensureOrientationConstraint()
    ensureSlideCollider()
    applySlidePartPhysics(character)
    applySlidePose()
end

local function updatePhase()
    local phase = getPhase()
    local waiting = phase == "Waiting"
    local sliding = phase == "Sliding" or phase == "Starting"

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

    if sliding then
        bindSteerAction()
        enterSlideMode()
        applySlidingHumanoidSettings()
    else
        unbindSteerAction()
        inputState.targetSteer = 0
        inputState.currentSteer = 0
        inputState.rawSteer = 0
        inputState.steerKeys.A = false
        inputState.steerKeys.D = false
        inputState.steerKeys.Left = false
        inputState.steerKeys.Right = false

        if runtime.force then
            runtime.force.Force = Vector3.zero
        end

        exitSlideMode()
    end

    runtime.startRequested = false

    runtime.lastPhase = phase

    DownhillState.update({
        phase = phase,
        active = sliding,
        startedAt = localPlayer:GetAttribute("DownhillStartedAt") or 0,
    })
end

local function cleanupCharacter()
    destroySlideForce()
    exitSlideMode()

    unbindStartAction()
    unbindSteerAction()
    restoreHumanoidSettings()
    enableControls()

    runtime.character = nil
    runtime.humanoid = nil
    runtime.root = nil
    runtime.startRequested = false
    runtime.currentHeading = nil
    runtime.targetHeading = nil
    runtime.lastForward = Vector3.new(0, 0, -1)

    inputState.steerKeys.A = false
    inputState.steerKeys.D = false
    inputState.steerKeys.Left = false
    inputState.steerKeys.Right = false
    inputState.gamepadX = 0
    inputState.rawSteer = 0
    inputState.targetSteer = 0
    inputState.currentSteer = 0

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
            if DEBUG_ENABLED then
                print(string.format("[StartInputProbe] key=%s processed=%s", keyName, tostring(gameProcessed)))
            end
        end
        return
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
        local x = input.Position.X
        inputState.gamepadX = math.abs(x) >= 0.08 and math.clamp(x, -1, 1) or 0
        updateRawSteerInput()
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
logDebug("[SlideSystem] enabled")
if DEBUG_ENABLED then
    print(string.format("[StartClient] remote=%s", startRequest:GetFullName()))
end
print("[GravitySlide] client controller enabled")
