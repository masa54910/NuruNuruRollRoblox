local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)
local SlideVehicleMath = require(ReplicatedStorage.Shared.SlideVehicleMath)

local projectConfig = Config.Project or {}
if projectConfig.EnableProxySlideVehicle ~= true then
    return
end

local settings = Config.ProxySlide or {}
local gravitySettings = Config.GravitySlide or {}
local startSettings = Config.DownhillStart or {}

local BUILD_ID = settings.BuildId or "PROXY_SLIDE_V8"
local DEBUG_ENABLED = RunService:IsStudio() and projectConfig.EnableDownhillDebug == true

local GROUND_RAY_DISTANCE = tonumber(gravitySettings.GroundRayDistance) or 12
local GROUND_PROBE_HEIGHT = tonumber(gravitySettings.GroundProbeHeight) or 2

local STEER_RESPONSE = tonumber(settings.ProxySteerResponse) or 8
local STEER_RETURN_RESPONSE = tonumber(settings.ProxySteerReturnResponse) or 6
local STEER_LOW_DPS = tonumber(settings.ProxySteerLowSpeedDegreesPerSecond) or 75
local STEER_HIGH_DPS = tonumber(settings.ProxySteerHighSpeedDegreesPerSecond) or 38
local STEER_HIGH_SPEED_THRESHOLD = tonumber(settings.ProxySteerHighSpeedThreshold) or 60
local VELOCITY_HEADING_RESPONSE = tonumber(settings.ProxyVelocityHeadingResponse) or 8

local WALL_NORMAL_DOT_THRESHOLD = tonumber(settings.ProxyWallNormalDotThreshold) or 0.45
local WALL_BOUNCE_COOLDOWN = tonumber(settings.ProxyWallBounceCooldown) or 0.10
local WALL_SAME_SURFACE_DOT_THRESHOLD = tonumber(settings.ProxyWallSameSurfaceDotThreshold) or 0.95
local WALL_SEPARATION_DISTANCE = tonumber(settings.ProxyWallSeparationDistance) or 0.08
local WALL_SPEED_RETENTION = tonumber(settings.ProxyWallSpeedRetention) or 1
local WALL_MIN_SPEED_RATIO = tonumber(settings.ProxyWallMinimumSpeedRatio) or 0.98
local WALL_MAX_SPEED_RATIO = tonumber(settings.ProxyWallMaximumSpeedRatio) or 1.02
local WALL_CAST_SAFETY_MARGIN = tonumber(settings.ProxyWallCastSafetyMargin) or 0.3
local WALL_CAST_MIN_DISTANCE = tonumber(settings.ProxyWallCastMinimumDistance) or 0.5

local ROAD_STICK_ACCELERATION = tonumber(settings.ProxyRoadStickAcceleration) or 18
local ROAD_STICK_MAXIMUM_SPEED = tonumber(settings.ProxyRoadStickMaximumSpeed) or 4

local FLAT_SLOPE_THRESHOLD = tonumber(settings.ProxyFlatSlopeThreshold) or 0.02
local MINIMUM_SLIDE_SPEED = tonumber(settings.ProxyMinimumSlideSpeed) or 12
local FLAT_ASSIST_ACCELERATION = tonumber(settings.ProxyFlatAssistAcceleration) or 7
local ROLLING_DECELERATION = tonumber(settings.ProxyRollingDeceleration) or 1.6
local MAXIMUM_SPEED = tonumber(settings.ProxyMaximumSpeed) or 145
local OVERSPEED_BRAKE_ACCELERATION = tonumber(settings.ProxyOverspeedBrakeAcceleration) or 18

local STEER_TEST_HOLD_SECONDS = tonumber(settings.ProxySteerTestHoldSeconds) or 0.5
local STEER_TEST_MIN_DEGREES = tonumber(settings.ProxySteerTestMinimumDegrees) or 5

local DEBUG_VISIBLE = settings.ProxySlideDebugVisible == true
local DEBUG_INTERVAL = tonumber(settings.DebugIntervalSeconds) or 1
local START_RETRY_SECONDS = (tonumber(startSettings.StartRequestCooldownSeconds) or 0.75) + 0.5

local localPlayer = Players.LocalPlayer
local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 20)
local remotesFolder = sharedFolder and sharedFolder:WaitForChild("NetworkRemotes", 20)
local startRequest = remotesFolder and remotesFolder:WaitForChild("DownhillStartRequest", 20)
if not startRequest or not startRequest:IsA("RemoteEvent") then
    warn("[ProxySlideFail] reason=start_remote_unavailable")
    return
end

local START_ACTION_NAME = "ProxySlideStartAction"
local STEER_ACTION_NAME = "ProxySlideSteerAction"
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 100

local runtime = {
    character = nil,
    humanoid = nil,
    humanoidRootPart = nil,
    slideRoot = nil,

    orientationAlign = nil,
    orientationAttachment = nil,

    startActionBound = false,
    steerActionBound = false,

    startRequested = false,
    lastStartRequestAt = 0,

    currentHeading = nil,
    targetSteer = 0,
    smoothedSteer = 0,

    lastWallPart = nil,
    lastWallNormal = nil,
    lastWallHitAt = 0,

    steerHoldStart = nil,
    steerHoldInput = nil,
    steerHoldHeading = nil,

    debugFolder = nil,
    debugHeadingPart = nil,
    debugNormalPart = nil,
    debugRightPart = nil,

    lastGroundLogAt = 0,
    lastVelocityLogAt = 0,
    lastSteerLogAt = 0,
    lastSteerTestLogAt = 0,
    lastWallLogAt = 0,
}

local keyState = {
    A = false,
    D = false,
    Left = false,
    Right = false,
}

local function formatVector3(value)
    if not value then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", value.X, value.Y, value.Z)
end

local function getPhase()
    return localPlayer:GetAttribute("DownhillPhase") or "Loading"
end

local function logInfo(message)
    if DEBUG_ENABLED then
        print(message)
    end
end

local function logWarn(message)
    if DEBUG_ENABLED then
        warn(message)
    end
end

local function updateTargetSteer()
    local steer = 0
    if keyState.A or keyState.Left then
        steer -= 1
    end
    if keyState.D or keyState.Right then
        steer += 1
    end

    runtime.targetSteer = math.clamp(steer, -1, 1)
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

local function handleStartAction(_, inputStatePhase, inputObject)
    if getPhase() ~= "Waiting" then
        return Enum.ContextActionResult.Pass
    end

    if inputStatePhase == Enum.UserInputState.Begin then
        local keyName = inputObject and inputObject.KeyCode and inputObject.KeyCode.Name or "Unknown"
        if keyName == "W" or keyName == "Up" then
            if UserInputService:GetFocusedTextBox() then
                return Enum.ContextActionResult.Sink
            end

            if runtime.startRequested then
                if os.clock() - runtime.lastStartRequestAt <= START_RETRY_SECONDS then
                    return Enum.ContextActionResult.Sink
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

local function handleSteerAction(_, inputStatePhase, inputObject)
    if getPhase() ~= "Sliding" then
        return Enum.ContextActionResult.Pass
    end

    local keyName = keyNameFromInput(inputObject)
    if not keyName then
        return Enum.ContextActionResult.Pass
    end

    if inputStatePhase == Enum.UserInputState.Begin then
        keyState[keyName] = true
    elseif inputStatePhase == Enum.UserInputState.End or inputStatePhase == Enum.UserInputState.Cancel then
        keyState[keyName] = false
    end

    updateTargetSteer()

    logInfo(string.format(
        "[ProxySteerInput] key=%s state=%s target=%.2f sink=true",
        keyName,
        tostring(inputStatePhase),
        runtime.targetSteer
    ))

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

    keyState.A = false
    keyState.D = false
    keyState.Left = false
    keyState.Right = false
    runtime.targetSteer = 0
end

local function ensureOrientation()
    local slideRoot = runtime.slideRoot
    if not slideRoot or not slideRoot.Parent then
        return nil
    end

    if runtime.orientationAlign and runtime.orientationAlign.Parent == slideRoot then
        return runtime.orientationAlign
    end

    if runtime.orientationAlign then
        runtime.orientationAlign:Destroy()
        runtime.orientationAlign = nil
    end
    if runtime.orientationAttachment then
        runtime.orientationAttachment:Destroy()
        runtime.orientationAttachment = nil
    end

    local attachment = Instance.new("Attachment")
    attachment.Name = "ProxySlideAttachment"
    attachment.Parent = slideRoot

    local align = Instance.new("AlignOrientation")
    align.Name = "ProxySlideOrientation"
    align.Attachment0 = attachment
    align.Mode = Enum.OrientationAlignmentMode.OneAttachment
    align.RigidityEnabled = settings.ProxyOrientationRigidityEnabled == true
    align.ReactionTorqueEnabled = false
    align.Responsiveness = tonumber(settings.ProxyOrientationResponsiveness) or 16
    align.MaxTorque = tonumber(settings.ProxyOrientationMaxTorque) or 65000
    align.MaxAngularVelocity = tonumber(settings.ProxyOrientationMaxAngularVelocity) or 24
    align.Parent = slideRoot

    runtime.orientationAttachment = attachment
    runtime.orientationAlign = align

    return align
end

local function clearDebugParts()
    if runtime.debugFolder then
        runtime.debugFolder:Destroy()
    end

    runtime.debugFolder = nil
    runtime.debugHeadingPart = nil
    runtime.debugNormalPart = nil
    runtime.debugRightPart = nil
end

local function createDebugPart(name, color)
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Color = color
    part.Transparency = 0.2
    part.Parent = runtime.debugFolder
    return part
end

local function ensureDebugParts()
    if not DEBUG_ENABLED or not DEBUG_VISIBLE then
        clearDebugParts()
        return
    end

    if runtime.debugFolder and runtime.debugFolder.Parent then
        return
    end

    local folder = Instance.new("Folder")
    folder.Name = "ProxySlideDebug"
    folder.Parent = Workspace

    runtime.debugFolder = folder
    runtime.debugHeadingPart = createDebugPart("Heading", Color3.fromRGB(40, 220, 100))
    runtime.debugNormalPart = createDebugPart("Normal", Color3.fromRGB(40, 110, 255))
    runtime.debugRightPart = createDebugPart("Right", Color3.fromRGB(255, 70, 70))
end

local function updateDebugVectors(position, heading, normal, right)
    if not runtime.debugHeadingPart then
        return
    end

    local function updatePart(part, direction, length)
        local dir = SlideVehicleMath.safeUnit(direction, Vector3.new(0, 1, 0))
        part.Size = Vector3.new(0.12, 0.12, length)
        local center = position + (dir * (length * 0.5))
        part.CFrame = CFrame.lookAt(center, center + dir)
    end

    updatePart(runtime.debugHeadingPart, heading, 5)
    updatePart(runtime.debugNormalPart, normal, 3.5)
    updatePart(runtime.debugRightPart, right, 3)
end

local function computeTurnRateDegrees(speed)
    local t = math.clamp(speed / math.max(STEER_HIGH_SPEED_THRESHOLD, 1), 0, 1)
    return STEER_LOW_DPS + ((STEER_HIGH_DPS - STEER_LOW_DPS) * t)
end

local function getSlideRoot(character)
    if runtime.slideRoot and runtime.slideRoot.Parent == character then
        return runtime.slideRoot
    end

    local slideRoot = character:FindFirstChild("DownhillSlideRoot")
    if slideRoot and slideRoot:IsA("BasePart") then
        runtime.slideRoot = slideRoot
        logInfo(string.format("[ProxySlideCreated] root=%s", slideRoot:GetFullName()))
        return slideRoot
    end

    runtime.slideRoot = nil
    return nil
end

local function evaluateGround(slideRoot)
    local sample = DownhillCourse.raycastRoad(
        slideRoot.Position + Vector3.new(0, GROUND_PROBE_HEIGHT, 0),
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

    return {
        sample = sample,
        surfaceNormal = normal,
        slopeAcceleration = SlideVehicleMath.slopeAcceleration(normal, Workspace.Gravity),
    }
end

local function computeTangentVelocity(velocity, normal)
    return SlideVehicleMath.projectOnPlane(velocity, normal)
end

local function detectWall(slideRoot, character, surfaceNormal, headingDirection, tangentVelocity, dt)
    local speed = tangentVelocity.Magnitude
    if speed <= 0.5 then
        return nil
    end

    local direction = SlideVehicleMath.safeUnit(headingDirection, tangentVelocity.Unit)
    local castDistance = math.max(WALL_CAST_MIN_DISTANCE, (speed * dt) + WALL_CAST_SAFETY_MARGIN)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.IgnoreWater = true

    local result = Workspace:Blockcast(slideRoot.CFrame, slideRoot.Size, direction * castDistance, params)
    if not result or not result.Instance then
        return nil
    end

    if DownhillCourse.isRoadPart(result.Instance) then
        return nil
    end

    if not result.Instance.CanCollide then
        return nil
    end

    local wallDot = math.abs(result.Normal:Dot(surfaceNormal))
    if wallDot >= WALL_NORMAL_DOT_THRESHOLD then
        return nil
    end

    if tangentVelocity:Dot(result.Normal) >= -0.05 then
        return nil
    end

    return {
        part = result.Instance,
        normal = result.Normal,
        position = result.Position,
        distance = result.Distance,
    }
end

local function applyWallBounce(slideRoot, groundInfo, tangentVelocity, wallInfo)
    local now = os.clock()

    local surfaceNormal = groundInfo.surfaceNormal

    local reflected, wallNormalOnSurface = SlideVehicleMath.reflectTangentVelocity(
        tangentVelocity,
        surfaceNormal,
        wallInfo.normal
    )

    if not reflected or not wallNormalOnSurface then
        return false
    end

    if runtime.lastWallPart == wallInfo.part and runtime.lastWallNormal then
        local sameNormal = runtime.lastWallNormal:Dot(wallNormalOnSurface) >= WALL_SAME_SURFACE_DOT_THRESHOLD
        if sameNormal and now - runtime.lastWallHitAt < WALL_BOUNCE_COOLDOWN then
            logInfo("[ProxyWallBounceIgnored] reason=same_wall_cooldown")
            return false
        end
    end

    local speedBefore = tangentVelocity.Magnitude
    if speedBefore <= 0.001 then
        return false
    end

    local reflectedDirection = reflected.Unit
    local preserved = reflectedDirection * (speedBefore * WALL_SPEED_RETENTION)

    local speedAfter = preserved.Magnitude
    local clampedRatio = SlideVehicleMath.clampSpeedRatio(
        speedBefore,
        speedAfter,
        WALL_MIN_SPEED_RATIO,
        WALL_MAX_SPEED_RATIO
    )

    preserved = reflectedDirection * (speedBefore * clampedRatio)

    local vertical = slideRoot.AssemblyLinearVelocity - tangentVelocity
    local finalVelocity = preserved + vertical

    local normalSpeed = finalVelocity:Dot(surfaceNormal)
    if normalSpeed > 0 then
        finalVelocity -= surfaceNormal * normalSpeed
    end

    slideRoot.AssemblyLinearVelocity = finalVelocity
    slideRoot.CFrame += wallNormalOnSurface * WALL_SEPARATION_DISTANCE

    runtime.currentHeading = reflectedDirection

    runtime.lastWallPart = wallInfo.part
    runtime.lastWallNormal = wallNormalOnSurface
    runtime.lastWallHitAt = now

    logInfo(string.format(
        "[ProxyWallBounce] speedBefore=%.3f speedAfter=%.3f speedRatio=%.3f directionBefore=%s directionAfter=%s",
        speedBefore,
        preserved.Magnitude,
        preserved.Magnitude / math.max(speedBefore, 0.001),
        formatVector3(tangentVelocity.Unit),
        formatVector3(reflectedDirection)
    ))

    return true
end

local function updateSteerTest(speed)
    local now = os.clock()

    if math.abs(runtime.targetSteer) >= 0.2 then
        if not runtime.steerHoldStart then
            runtime.steerHoldStart = now
            runtime.steerHoldInput = runtime.targetSteer
            runtime.steerHoldHeading = runtime.currentHeading
        end

        if runtime.steerHoldStart and runtime.currentHeading and runtime.steerHoldHeading then
            local held = now - runtime.steerHoldStart
            if held >= STEER_TEST_HOLD_SECONDS then
                local changed = SlideVehicleMath.angleBetweenDegrees(runtime.steerHoldHeading, runtime.currentHeading)
                local passed = changed >= STEER_TEST_MIN_DEGREES

                logInfo(string.format(
                    "[ProxySteerTest] input=%s headingChangedDegrees=%.3f speed=%.3f passed=%s",
                    runtime.steerHoldInput > 0 and "Right" or "Left",
                    changed,
                    speed,
                    tostring(passed)
                ))

                if not passed then
                    logWarn(string.format(
                        "[ProxySlideFail] reason=steering_heading_not_changed targetSteer=%.2f smoothedSteer=%.2f turnRate=%.2f currentHeading=%s velocityDirection=%s surfaceNormal=%s",
                        runtime.targetSteer,
                        runtime.smoothedSteer,
                        computeTurnRateDegrees(speed),
                        formatVector3(runtime.currentHeading),
                        formatVector3(runtime.currentHeading),
                        "(logged in ground loop)"
                    ))
                end

                runtime.steerHoldStart = nil
                runtime.steerHoldInput = nil
                runtime.steerHoldHeading = nil
            end
        end
    else
        runtime.steerHoldStart = nil
        runtime.steerHoldInput = nil
        runtime.steerHoldHeading = nil
    end
end

local function applySlidePose()
    local character = runtime.character
    local humanoid = runtime.humanoid
    if not character or not humanoid then
        return
    end

    local animateScript = character:FindFirstChild("Animate")
    if animateScript then
        animateScript.Disabled = true
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            track:Stop(0.1)
        end
    end

    humanoid.WalkSpeed = 0
    humanoid.UseJumpPower = true
    humanoid.JumpPower = 0
    humanoid.AutoRotate = false
    humanoid.Sit = false
    humanoid.PlatformStand = true
    humanoid:Move(Vector3.zero, false)
    humanoid:ChangeState(Enum.HumanoidStateType.Physics)

    logInfo("[ProxySlidePose] applied=true")
end

local function restoreHumanoidPose()
    local humanoid = runtime.humanoid
    if humanoid and humanoid.Parent then
        humanoid.PlatformStand = false
    end
end

local function onPhaseChanged()
    local phase = getPhase()

    if phase == "Waiting" then
        runtime.startRequested = false
        bindStartAction()
        unbindSteerAction()
    elseif phase == "Sliding" then
        unbindStartAction()
        bindSteerAction()
        applySlidePose()
    else
        unbindStartAction()
        unbindSteerAction()
        restoreHumanoidPose()
    end
end

local function resetRuntimeState()
    runtime.slideRoot = nil
    runtime.currentHeading = nil
    runtime.smoothedSteer = 0
    runtime.targetSteer = 0

    runtime.lastWallPart = nil
    runtime.lastWallNormal = nil
    runtime.lastWallHitAt = 0

    runtime.steerHoldStart = nil
    runtime.steerHoldInput = nil
    runtime.steerHoldHeading = nil
end

local function initializeCharacter(character)
    runtime.character = character
    runtime.humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    runtime.humanoidRootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)

    resetRuntimeState()
    onPhaseChanged()
end

local function cleanupCharacter()
    unbindStartAction()
    unbindSteerAction()
    clearDebugParts()
    restoreHumanoidPose()

    runtime.character = nil
    runtime.humanoid = nil
    runtime.humanoidRootPart = nil
    runtime.orientationAlign = nil
    runtime.orientationAttachment = nil

    resetRuntimeState()
end

local function updateSlide(dt)
    if getPhase() ~= "Sliding" then
        return
    end

    local character = runtime.character
    if not character or not runtime.humanoid then
        return
    end

    local slideRoot = getSlideRoot(character)
    if not slideRoot then
        return
    end

    ensureOrientation()
    ensureDebugParts()

    local ground = evaluateGround(slideRoot)
    if not ground then
        DownhillState.update({
            phase = "Sliding",
            active = true,
            grounded = false,
            speed = slideRoot.AssemblyLinearVelocity.Magnitude,
            steerInput = runtime.smoothedSteer,
            rootPosition = slideRoot.Position,
        })
        return
    end

    local velocity = slideRoot.AssemblyLinearVelocity
    local tangentVelocity = computeTangentVelocity(velocity, ground.surfaceNormal)

    if tangentVelocity.Magnitude <= 0.001 then
        local seed = DownhillCourse.getForward(ground.sample.index, 1) or Vector3.new(0, 0, -1)
        tangentVelocity = SlideVehicleMath.projectOnPlane(seed * 0.01, ground.surfaceNormal)
    end

    if not runtime.currentHeading or runtime.currentHeading.Magnitude <= 0.001 then
        local fallback = DownhillCourse.getForward(ground.sample.index, 1) or Vector3.new(0, 0, -1)
        local headingSeed = tangentVelocity.Magnitude > 0.1 and tangentVelocity.Unit or fallback
        runtime.currentHeading = SlideVehicleMath.projectDirectionOnPlane(headingSeed, ground.surfaceNormal, Vector3.new(0, 0, -1))
    end

    local speed = tangentVelocity.Magnitude

    local response = math.abs(runtime.targetSteer) <= 0.001 and STEER_RETURN_RESPONSE or STEER_RESPONSE
    local steerAlpha = math.clamp(dt * response, 0, 1)
    runtime.smoothedSteer += (runtime.targetSteer - runtime.smoothedSteer) * steerAlpha

    local turnRateDegrees = computeTurnRateDegrees(speed)
    local turnRadians = math.rad(turnRateDegrees) * runtime.smoothedSteer * dt
    runtime.currentHeading = SlideVehicleMath.rotateHeadingOnSurface(runtime.currentHeading, ground.surfaceNormal, turnRadians)

    local desiredTangentVelocity = runtime.currentHeading * speed
    local headingBlend = math.clamp(dt * VELOCITY_HEADING_RESPONSE, 0, 1)
    local newTangentVelocity = tangentVelocity:Lerp(desiredTangentVelocity, headingBlend)

    local slopeAcceleration = ground.slopeAcceleration
    local slopeMagnitude = slopeAcceleration.Magnitude
    local downhillDirection = slopeMagnitude > 0.001 and slopeAcceleration.Unit or nil
    local movingUphill = downhillDirection and newTangentVelocity:Dot(downhillDirection) < -0.05 or false

    if slopeMagnitude <= FLAT_SLOPE_THRESHOLD and downhillDirection and not movingUphill and speed < MINIMUM_SLIDE_SPEED then
        local assistRatio = math.clamp(1 - (speed / math.max(MINIMUM_SLIDE_SPEED, 1)), 0, 1)
        newTangentVelocity += downhillDirection * (FLAT_ASSIST_ACCELERATION * assistRatio * dt)
    end

    if newTangentVelocity.Magnitude > 0.5 then
        newTangentVelocity -= newTangentVelocity.Unit * (ROLLING_DECELERATION * dt)
    end

    if newTangentVelocity.Magnitude > MAXIMUM_SPEED then
        local excessRatio = math.clamp((newTangentVelocity.Magnitude - MAXIMUM_SPEED) / math.max(MAXIMUM_SPEED, 1), 0, 1)
        newTangentVelocity -= newTangentVelocity.Unit * (OVERSPEED_BRAKE_ACCELERATION * excessRatio * dt)
    end

    local wallHit = detectWall(slideRoot, character, ground.surfaceNormal, runtime.currentHeading, newTangentVelocity, dt)

    if wallHit then
        logInfo(string.format(
            "[ProxyWallDetect] part=%s hitNormal=%s wallNormalOnSurface=%s distance=%.3f",
            wallHit.part:GetFullName(),
            formatVector3(wallHit.normal),
            "(computed on bounce)",
            wallHit.distance
        ))
        local bounced = applyWallBounce(slideRoot, ground, newTangentVelocity, wallHit)
        if bounced then
            velocity = slideRoot.AssemblyLinearVelocity
            newTangentVelocity = computeTangentVelocity(velocity, ground.surfaceNormal)
            speed = newTangentVelocity.Magnitude
        end
    else
        runtime.lastWallPart = nil
        runtime.lastWallNormal = nil
    end

    local currentNormalSpeed = velocity:Dot(ground.surfaceNormal)
    if currentNormalSpeed > -ROAD_STICK_MAXIMUM_SPEED then
        currentNormalSpeed -= ROAD_STICK_ACCELERATION * dt
    end

    slideRoot.AssemblyLinearVelocity = newTangentVelocity + (ground.surfaceNormal * currentNormalSpeed)

    if runtime.orientationAlign then
        runtime.orientationAlign.CFrame = CFrame.lookAt(
            Vector3.zero,
            runtime.currentHeading,
            ground.surfaceNormal
        )
    end

    local right = runtime.currentHeading:Cross(ground.surfaceNormal)
    updateDebugVectors(slideRoot.Position, runtime.currentHeading, ground.surfaceNormal, right)

    updateSteerTest(speed)

    local now = os.clock()
    if DEBUG_ENABLED and now - runtime.lastGroundLogAt >= DEBUG_INTERVAL then
        runtime.lastGroundLogAt = now
        logInfo(string.format(
            "[ProxySlideGround] part=%s normal=%s grounded=true",
            ground.sample.road:GetFullName(),
            formatVector3(ground.surfaceNormal)
        ))
    end

    if DEBUG_ENABLED and now - runtime.lastVelocityLogAt >= DEBUG_INTERVAL then
        runtime.lastVelocityLogAt = now
        logInfo(string.format(
            "[ProxySlideVelocity] speed=%.3f heading=%s velocity=%s",
            speed,
            formatVector3(runtime.currentHeading),
            formatVector3(slideRoot.AssemblyLinearVelocity)
        ))
    end

    DownhillState.update({
        phase = "Sliding",
        active = true,
        grounded = true,
        roadName = ground.sample.road.Name,
        speed = speed,
        steerInput = runtime.smoothedSteer,
        forward = runtime.currentHeading,
        groundNormal = ground.surfaceNormal,
        rootPosition = slideRoot.Position,
    })
end

localPlayer:GetAttributeChangedSignal("DownhillPhase"):Connect(onPhaseChanged)
localPlayer.CharacterAdded:Connect(initializeCharacter)
localPlayer.CharacterRemoving:Connect(cleanupCharacter)
RunService.Heartbeat:Connect(updateSlide)

if localPlayer.Character then
    task.defer(initializeCharacter, localPlayer.Character)
end

print(string.format("[ProxySlideBuild] client=%s", BUILD_ID))
print("[ProxySlideLegacy] gravitySlideControllerDisabled=true")
