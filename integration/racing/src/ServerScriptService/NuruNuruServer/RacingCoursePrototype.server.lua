local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("NuruNuruShared"):WaitForChild("Config"))

local BUILD_VERSION = "RACING_GATE_R1"
local MAP_READY_ATTRIBUTE = "NuruNuruRollMapReady"
local SPAWN_LOCK_ATTRIBUTE = "NuruNuruRacingGateR1Spawned"

local COURSE_SPAWN_FORWARD_OFFSET = 4
local COURSE_SPAWN_RAYCAST_HEIGHT = 60
local COURSE_SPAWN_RAYCAST_DISTANCE = 220
local CAR_GROUND_CLEARANCE = 0.75
local PLAYER_OFFSET_RIGHT = -8
local PLAYER_OFFSET_BACK = -7
local PLAYER_OFFSET_UP = 3

local wallConfig = Config.RacingWallBounce or {}
local WALL_SPEED_RETENTION = tonumber(wallConfig.WallSpeedRetention) or 1.0
local WALL_BOUNCE_COOLDOWN_SECONDS = tonumber(wallConfig.WallBounceCooldownSeconds) or 0.20
local WALL_SAME_NORMAL_DOT_THRESHOLD = tonumber(wallConfig.WallSameNormalDotThreshold) or 0.94
local WALL_SEPARATION_DISTANCE = tonumber(wallConfig.WallSeparationDistance) or 0.12
local WALL_ROAD_STICK_SPEED = tonumber(wallConfig.WallRoadStickSpeed) or 1.0
local WALL_MAX_ALLOWED_YAW_RATE = tonumber(wallConfig.WallMaximumAllowedYawRate) or 1.5
local WALL_YAW_CLAMP_DURATION_SECONDS = tonumber(wallConfig.WallYawClampDurationSeconds) or 0.20
local VISUAL_NORMAL_RESPONSE = tonumber(wallConfig.VisualNormalResponse) or 8
local VISUAL_MAX_TILT_DEGREES = tonumber(wallConfig.VisualMaximumTiltDegrees) or 25
local VISUAL_HEADING_RESPONSE = tonumber(wallConfig.VisualHeadingResponse) or 16
local WALL_VISUAL_HEADING_RESPONSE = tonumber(wallConfig.WallVisualHeadingResponse) or 24
local VISUAL_MIN_HEADING_SPEED = tonumber(wallConfig.VisualMinimumHeadingSpeed) or 2.0
local VISUAL_HEIGHT_OFFSET = tonumber(wallConfig.VisualHeightOffset) or 2.5
local VISUAL_POSE_PITCH_DEGREES = tonumber(wallConfig.VisualPosePitchDegrees) or -22
local VISUAL_POSE_YAW_DEGREES = tonumber(wallConfig.VisualPoseYawDegrees) or 180
local GROUND_ROTATION_GUARD_ENABLED = wallConfig.GroundRotationGuardEnabled ~= false
local GROUND_MAX_PITCH_ROLL_RATE = tonumber(wallConfig.GroundMaximumPitchRollRate) or 0.35
local GROUND_MAX_YAW_RATE = tonumber(wallConfig.GroundMaximumYawRate) or 2.0

local WALL_DETECT_MIN_SPEED = 4
local WALL_DETECT_MIN_DISTANCE = 2.5
local WALL_DETECT_FORWARD_MARGIN = 1.5
local WALL_DETECT_VERTICAL_PROBE = 8
local WALL_DETECT_VERTICAL_RANGE = 20
local GROUND_GUARD_AIR_SPEED_THRESHOLD = 8

local FIXED_SLIDE_POSE_OFFSET = CFrame.Angles(
    math.rad(VISUAL_POSE_PITCH_DEGREES),
    math.rad(VISUAL_POSE_YAW_DEGREES),
    0
)

local started = false

local LEGACY_SCRIPT_NAMES = {
    GravitySlideController = true,
    SlideVehicleController = true,
    SlideVehicleAuthority = true,
    SlideVehicleMath = true,
    DownhillStartSystem = true,
    LotionSlideSystem = true,
    SledInputClient = true,
    SledServerController = true,
}

local function logInfo(message)
    if RunService:IsStudio() then
        print(message)
    end
end

local function formatVector3(v)
    if not v then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", v.X, v.Y, v.Z)
end

local function logFail(stage, reason)
    warn(string.format("[RacingIntegrationFail] stage=%s reason=%s", stage, reason))
end

local function findMapRoot()
    return Workspace:FindFirstChild("NuruNuruRollMap")
end

local function collectRoads(mapRoot)
    local roads = {}
    if not mapRoot then
        return roads
    end

    for _, descendant in ipairs(mapRoot:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local indexText = string.match(descendant.Name, "^Road_(%d+)$")
            if indexText then
                table.insert(roads, {
                    index = tonumber(indexText),
                    part = descendant,
                })
            end
        end
    end

    table.sort(roads, function(a, b)
        return a.index < b.index
    end)

    return roads
end

local function findGoalTrigger(mapRoot)
    if not mapRoot then
        return nil
    end

    for _, descendant in ipairs(mapRoot:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name == "GoalTrigger" then
            return descendant
        end
    end

    return nil
end

local function waitForCourseSpawn(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds

    repeat
        local mapRoot = findMapRoot()
        if mapRoot then
            local spawnPart = mapRoot:FindFirstChild("CourseSpawn", true)
            if spawnPart and spawnPart:IsA("BasePart") then
                return mapRoot, spawnPart
            end
        end
        task.wait(0.2)
    until os.clock() >= deadline

    return nil, nil
end

local function getDownhillDirection(roads, fallbackForward, surfaceNormal)
    local fallback = fallbackForward
    if fallback.Magnitude <= 0.001 then
        fallback = Vector3.new(0, 0, -1)
    end

    local downhill = fallback

    if #roads >= 2 then
        local a = roads[1].part.Position
        local b = roads[2].part.Position
        local segmentDir = b - a
        if segmentDir.Magnitude > 0.001 then
            downhill = segmentDir.Unit
        end
    end

    downhill = downhill - (surfaceNormal * downhill:Dot(surfaceNormal))
    if downhill.Magnitude <= 0.001 then
        downhill = fallback - (surfaceNormal * fallback:Dot(surfaceNormal))
    end

    if downhill.Magnitude <= 0.001 then
        return Vector3.new(0, 0, -1)
    end

    return downhill.Unit
end

local function getLegacySlideScriptsLoaded()
    for _, inst in ipairs(game:GetDescendants()) do
        local isScript = inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript")
        if isScript and LEGACY_SCRIPT_NAMES[inst.Name] then
            return true
        end
    end
    return false
end

local function isRoadPart(part)
    if not part or not part:IsA("BasePart") then
        return false
    end
    if string.match(part.Name, "^Road_%d+$") then
        return true
    end
    if part.Name == "CourseSpawn" or part.Name == "StartPad" or part.Name == "GoalTrigger" then
        return true
    end
    return false
end

local function getCarTemplateInfo()
    local carTemplate = ReplicatedStorage:FindFirstChild("Car")
    if not carTemplate or not carTemplate:IsA("Model") then
        return nil
    end

    local scriptsFolder = carTemplate:FindFirstChild("Scripts")
    local controller = scriptsFolder and scriptsFolder:FindFirstChild("Controller", true)
    local driverSeat = carTemplate:FindFirstChild("DriverSeat", true)

    return {
        model = carTemplate,
        controllerFound = controller and controller:IsA("ModuleScript") or false,
        driverSeatFound = driverSeat and driverSeat:IsA("VehicleSeat") or false,
    }
end

local function spawnOfficialCar(spawnCFrame)
    local carSpawningScript = ServerScriptService:FindFirstChild("CarSpawning")
    if not carSpawningScript then
        return nil, "ServerScriptService.CarSpawning missing"
    end

    local spawnCarModule = carSpawningScript:FindFirstChild("spawnCar")
    if not spawnCarModule or not spawnCarModule:IsA("ModuleScript") then
        return nil, "CarSpawning.spawnCar missing"
    end

    local spawnCar = require(spawnCarModule)

    local existing = {}
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") then
            existing[child] = true
        end
    end

    spawnCar(spawnCFrame, nil)

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") and not existing[child] then
            local hasChassis = child:FindFirstChild("Chassis", true) ~= nil
            local hasDriverSeat = child:FindFirstChild("DriverSeat", true) ~= nil
            if hasChassis or hasDriverSeat then
                return child, nil
            end
        end
    end

    return nil, "spawned_car_not_found"
end

local function getCarPivotPart(carModel)
    local chassis = carModel:FindFirstChild("Chassis", true)
    if chassis and chassis:IsA("BasePart") then
        return chassis
    end

    if carModel.PrimaryPart and carModel.PrimaryPart:IsA("BasePart") then
        return carModel.PrimaryPart
    end

    return nil
end

local function getAssemblyRoot(part)
    if not part then
        return nil
    end

    local root = part.AssemblyRootPart
    if root and root:IsA("BasePart") then
        return root
    end

    return part
end

local function getSurfaceSample(mapRoot, assemblyRoot)
    local origin = assemblyRoot.Position + Vector3.new(0, WALL_DETECT_VERTICAL_PROBE, 0)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { mapRoot }
    params.IgnoreWater = true

    local result = Workspace:Raycast(origin, Vector3.new(0, -WALL_DETECT_VERTICAL_RANGE, 0), params)
    if not result or not result.Instance then
        return nil
    end

    local normal = result.Normal.Magnitude > 0.001 and result.Normal.Unit or Vector3.yAxis
    return {
        part = result.Instance,
        normal = normal,
        position = result.Position,
    }
end

local function flattenDirection(direction, up)
    local flattened = direction - (up * direction:Dot(up))
    if flattened.Magnitude <= 0.001 then
        return nil
    end
    return flattened.Unit
end

local function blendUnitVector(fromDir, toDir, alpha)
    if not fromDir then
        return toDir
    end
    local mixed = fromDir:Lerp(toDir, math.clamp(alpha, 0, 1))
    if mixed.Magnitude <= 0.001 then
        return toDir
    end
    return mixed.Unit
end

local function clampMagnitude(value, maxMagnitude)
    local magnitude = value.Magnitude
    if magnitude <= maxMagnitude or magnitude <= 0.001 then
        return value
    end
    return value.Unit * maxMagnitude
end

local function readHeadingVectorFromAttributes(container)
    if not container then
        return nil
    end

    local candidateKeys = {
        "targetHeading",
        "TargetHeading",
        "desiredHeading",
        "DesiredHeading",
    }

    for _, key in ipairs(candidateKeys) do
        local value = container:GetAttribute(key)
        if typeof(value) == "Vector3" and value.Magnitude > 0.001 then
            return value.Unit
        end
    end

    local x = container:GetAttribute("targetHeadingX")
    local y = container:GetAttribute("targetHeadingY")
    local z = container:GetAttribute("targetHeadingZ")
    if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" then
        local fromXYZ = Vector3.new(x, y, z)
        if fromXYZ.Magnitude > 0.001 then
            return fromXYZ.Unit
        end
    end

    return nil
end

local function getSteeringInputMagnitude(inputs)
    if not inputs or not inputs:IsA("Configuration") then
        return 0
    end

    local steer = inputs:GetAttribute("steeringInput")
    if typeof(steer) ~= "number" then
        return 0
    end

    return math.abs(steer)
end

local function ensureVisualRig(carModel)
    local rigPart = carModel:FindFirstChild("VisualSlideRig")
    if rigPart and rigPart:IsA("BasePart") then
        rigPart.Anchored = true
        rigPart.CanCollide = false
        rigPart.CanTouch = false
        rigPart.CanQuery = false
        rigPart.Massless = true
        return rigPart
    end

    local visualRig = Instance.new("Part")
    visualRig.Name = "VisualSlideRig"
    visualRig.Size = Vector3.new(2, 3, 4)
    visualRig.Anchored = true
    visualRig.CanCollide = false
    visualRig.CanTouch = false
    visualRig.CanQuery = false
    visualRig.Transparency = 1
    visualRig.Massless = true
    visualRig.CastShadow = false
    visualRig.Parent = carModel

    return visualRig
end

local function isVisualRigWelded(carModel, visualRig)
    for _, desc in ipairs(carModel:GetDescendants()) do
        if desc:IsA("WeldConstraint") then
            if desc.Part0 == visualRig or desc.Part1 == visualRig then
                return true
            end
        end
    end
    return false
end

local function resolveHeadingSource(state, inputs, tangentVelocity, surfaceNormal, chassisLook, courseForward)
    local inputHeading = readHeadingVectorFromAttributes(inputs)
    if inputHeading then
        local projectedInput = flattenDirection(inputHeading, surfaceNormal)
        if projectedInput then
            return projectedInput, "targetHeading"
        end
    end

    if tangentVelocity.Magnitude >= VISUAL_MIN_HEADING_SPEED then
        local velocityHeading = flattenDirection(tangentVelocity, surfaceNormal)
        if velocityHeading then
            return velocityHeading, "velocity"
        end
    end

    local lookProjected = flattenDirection(chassisLook, surfaceNormal)
    if lookProjected then
        return lookProjected, "chassisLook"
    end

    if courseForward and courseForward.Magnitude > 0.001 then
        local courseProjected = flattenDirection(courseForward, surfaceNormal)
        if courseProjected then
            return courseProjected, "course"
        end
    end

    if state.visualHeading and state.visualHeading.Magnitude > 0.001 then
        return state.visualHeading, "previous"
    end

    return Vector3.new(0, 0, -1), "fallback"
end

local function applyGroundRotationGuard(state, assemblyRoot, surfaceNormal, isGrounded, allowYawOnly)
    if not GROUND_ROTATION_GUARD_ENABLED or not isGrounded then
        return
    end

    local angularBefore = assemblyRoot.AssemblyAngularVelocity
    local yawSigned = surfaceNormal * angularBefore:Dot(surfaceNormal)
    local yawClamped = clampMagnitude(yawSigned, GROUND_MAX_YAW_RATE)
    local pitchRollBefore = angularBefore - yawSigned

    local shouldClampPitchRoll = pitchRollBefore.Magnitude > GROUND_MAX_PITCH_ROLL_RATE
    local shouldClampYaw = yawSigned.Magnitude > GROUND_MAX_YAW_RATE

    if not shouldClampPitchRoll and not shouldClampYaw then
        return
    end

    local newAngular = yawClamped
    if not allowYawOnly and not shouldClampPitchRoll then
        newAngular = yawClamped + pitchRollBefore
    end

    assemblyRoot.AssemblyAngularVelocity = newAngular

    local pitchRollAfter = newAngular - (surfaceNormal * newAngular:Dot(surfaceNormal))
    logInfo(string.format(
        "[GroundRotationGuard] pitchRollBefore=%.3f pitchRollAfter=%.3f yaw=%.3f",
        pitchRollBefore.Magnitude,
        pitchRollAfter.Magnitude,
        yawClamped.Magnitude
    ))
end

local function getWallHit(carModel, assemblyRoot, surfaceNormal, deltaTime)
    local velocity = assemblyRoot.AssemblyLinearVelocity
    local tangentVelocity = velocity - (surfaceNormal * velocity:Dot(surfaceNormal))
    local speed = tangentVelocity.Magnitude
    if speed < WALL_DETECT_MIN_SPEED then
        return nil
    end

    local direction = tangentVelocity.Unit
    local castDistance = math.max(WALL_DETECT_MIN_DISTANCE, (speed * deltaTime) + WALL_DETECT_FORWARD_MARGIN)
    local castSize = assemblyRoot.Size + Vector3.new(0.4, 0.2, 0.4)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { carModel }
    params.IgnoreWater = true

    local result = Workspace:Blockcast(assemblyRoot.CFrame, castSize, direction * castDistance, params)
    if not result or not result.Instance then
        return nil
    end

    if not result.Instance:IsA("BasePart") then
        return nil
    end
    if not result.Instance.CanCollide then
        return nil
    end
    if isRoadPart(result.Instance) then
        return nil
    end

    return {
        part = result.Instance,
        normal = result.Normal,
        position = result.Position,
        velocity = velocity,
        tangentVelocity = tangentVelocity,
    }
end

local function applyWallDirectionChange(state, carModel, assemblyRoot, surfaceNormal, wallHit)
    local now = os.clock()
    local wallNormal = wallHit.normal.Magnitude > 0.001 and wallHit.normal.Unit or nil
    if not wallNormal then
        logFail("wall_direction", "invalid_wall_normal")
        return
    end

    local velocityBefore = wallHit.velocity
    local movingIntoWall = velocityBefore:Dot(wallNormal) < 0
    if not movingIntoWall then
        logInfo("[WallDirectionChangeIgnored] reason=moving_away")
        return
    end

    if state.lastWallPart == wallHit.part then
        local elapsed = now - (state.lastWallBounceAt or 0)
        if elapsed <= WALL_BOUNCE_COOLDOWN_SECONDS and state.lastWallNormal then
            local dotValue = wallNormal:Dot(state.lastWallNormal)
            if dotValue >= WALL_SAME_NORMAL_DOT_THRESHOLD then
                logInfo("[WallDirectionChangeIgnored] reason=cooldown")
                return
            end
        end
    end

    local wallNormalOnSurface = wallNormal - (surfaceNormal * wallNormal:Dot(surfaceNormal))
    if wallNormalOnSurface.Magnitude <= 0.001 then
        logFail("wall_direction", "wall_normal_on_surface_too_small")
        return
    end
    wallNormalOnSurface = wallNormalOnSurface.Unit

    local normalVelocity = surfaceNormal * velocityBefore:Dot(surfaceNormal)
    local tangentVelocity = velocityBefore - normalVelocity
    local speedBefore = tangentVelocity.Magnitude
    if speedBefore <= 0.001 then
        logInfo("[WallDirectionChangeIgnored] reason=low_speed")
        return
    end

    local reflectedVelocity = tangentVelocity
        - (2 * tangentVelocity:Dot(wallNormalOnSurface) * wallNormalOnSurface)
    if reflectedVelocity.Magnitude <= 0.001 then
        logInfo("[WallDirectionChangeIgnored] reason=degenerate_reflection")
        return
    end

    local reflectedDirection = reflectedVelocity.Unit
    local finalTangentVelocity = reflectedDirection * (speedBefore * WALL_SPEED_RETENTION)
    local finalVelocity = finalTangentVelocity - (surfaceNormal * WALL_ROAD_STICK_SPEED)

    local upwardSpeed = finalVelocity:Dot(surfaceNormal)
    if upwardSpeed > 0 then
        finalVelocity -= surfaceNormal * upwardSpeed
    end

    local speedAfter = finalVelocity.Magnitude

    logInfo(string.format(
        "[WallDirectionChange] linearSpeedBefore=%.3f linearSpeedAfter=%.3f angularSpinAdded=false",
        speedBefore,
        speedAfter
    ))

    local currentPivot = carModel:GetPivot()
    local separatedPivot = currentPivot + (wallNormalOnSurface * WALL_SEPARATION_DISTANCE)
    carModel:PivotTo(separatedPivot)

    assemblyRoot.AssemblyLinearVelocity = finalVelocity

    state.lastWallPart = wallHit.part
    state.lastWallNormal = wallNormal
    state.lastWallBounceAt = now
    state.wallYawClampUntil = now + WALL_YAW_CLAMP_DURATION_SECONDS

    state.desiredHeading = reflectedDirection
    state.headingSource = "targetHeading"
    state.headingResponse = WALL_VISUAL_HEADING_RESPONSE
end

local function startWallDirectionAndVisualRigMonitor(carModel, mapRoot, courseForward)
    local chassis = getCarPivotPart(carModel)
    if not chassis then
        logFail("direction_monitor", "chassis_not_found")
        return
    end

    local visualRig = ensureVisualRig(carModel)
    local state = {
        visualRig = visualRig,
        lastWallPart = nil,
        lastWallNormal = nil,
        lastWallBounceAt = 0,
        wallYawClampUntil = 0,
        desiredHeading = nil,
        headingSource = "fallback",
        visualHeading = nil,
        visualUp = nil,
        headingResponse = VISUAL_HEADING_RESPONSE,
        lastVisualHeadingLogAt = 0,
        lastAuditAt = 0,
    }

    local inputs = carModel:FindFirstChild("Inputs")

    local heartbeatConnection
    heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        if not carModel:IsDescendantOf(Workspace) then
            if heartbeatConnection then
                heartbeatConnection:Disconnect()
            end
            return
        end

        local assemblyRoot = getAssemblyRoot(chassis)
        if not assemblyRoot then
            return
        end

        local surfaceSample = getSurfaceSample(mapRoot, assemblyRoot)
        local surfaceNormal = surfaceSample and surfaceSample.normal or Vector3.yAxis
        local isGrounded = surfaceSample ~= nil

        local tangentVelocity = assemblyRoot.AssemblyLinearVelocity - (surfaceNormal * assemblyRoot.AssemblyLinearVelocity:Dot(surfaceNormal))
        if tangentVelocity.Magnitude > VISUAL_MIN_HEADING_SPEED then
            local tangentDir = tangentVelocity.Unit
            if not state.desiredHeading then
                state.desiredHeading = tangentDir
            end
            state.desiredHeading = tangentDir
            state.headingSource = "velocity"
        end

        local wallHit = getWallHit(carModel, assemblyRoot, surfaceNormal, deltaTime)
        if wallHit then
            applyWallDirectionChange(state, carModel, assemblyRoot, surfaceNormal, wallHit)
        end

        local resolvedHeading, headingSource = resolveHeadingSource(
            state,
            inputs,
            tangentVelocity,
            surfaceNormal,
            assemblyRoot.CFrame.LookVector,
            courseForward
        )
        if not state.desiredHeading then
            state.desiredHeading = resolvedHeading
        end
        state.headingSource = headingSource

        local headingResponse = state.headingResponse or VISUAL_HEADING_RESPONSE
        state.headingResponse = VISUAL_HEADING_RESPONSE
        local headingAlpha = math.clamp(headingResponse * deltaTime, 0, 1)
        state.visualHeading = blendUnitVector(state.visualHeading, state.desiredHeading, headingAlpha)

        local upAlpha = math.clamp(VISUAL_NORMAL_RESPONSE * deltaTime, 0, 1)
        state.visualUp = blendUnitVector(state.visualUp, surfaceNormal, upAlpha)
        local visualUp = state.visualUp or Vector3.yAxis

        local flattenedHeading = flattenDirection(state.visualHeading or resolvedHeading, visualUp) or resolvedHeading
        state.visualHeading = flattenedHeading

        local limitedUp = visualUp
        local maxTilt = math.rad(VISUAL_MAX_TILT_DEGREES)
        local tilt = math.acos(math.clamp(visualUp:Dot(Vector3.yAxis), -1, 1))
        if tilt > maxTilt then
            local blend = maxTilt / tilt
            limitedUp = blendUnitVector(Vector3.yAxis, visualUp, blend)
        end

        local visualPosition = assemblyRoot.Position + (limitedUp * VISUAL_HEIGHT_OFFSET)
        local visualCf = CFrame.lookAt(visualPosition, visualPosition + flattenedHeading, limitedUp) * FIXED_SLIDE_POSE_OFFSET
        state.visualRig:PivotTo(visualCf)

        local now = os.clock()

        local wallClampActive = now < state.wallYawClampUntil
        if wallClampActive then
            local angular = assemblyRoot.AssemblyAngularVelocity
            local yaw = surfaceNormal * angular:Dot(surfaceNormal)
            assemblyRoot.AssemblyAngularVelocity = clampMagnitude(yaw, WALL_MAX_ALLOWED_YAW_RATE)
        end

        local steeringMagnitude = getSteeringInputMagnitude(inputs)
        local isCurving = steeringMagnitude > 0.20 and tangentVelocity.Magnitude > 8
        local verticalSpeed = math.abs(assemblyRoot.AssemblyLinearVelocity:Dot(surfaceNormal))
        local isLikelyAir = verticalSpeed > GROUND_GUARD_AIR_SPEED_THRESHOLD and not isGrounded
        if not isLikelyAir and not isCurving then
            applyGroundRotationGuard(state, assemblyRoot, surfaceNormal, isGrounded, wallClampActive)
        end

        if (now - state.lastVisualHeadingLogAt) >= 0.25 then
            state.lastVisualHeadingLogAt = now
            logInfo(string.format(
                "[VisualHeading] source=%s heading=%s",
                state.headingSource,
                formatVector3(flattenedHeading)
            ))
        end

        if (now - state.lastAuditAt) >= 1.0 then
            state.lastAuditAt = now
            local visualRigPhysicsActive = (not state.visualRig.Anchored)
                or state.visualRig.CanCollide
                or state.visualRig.CanTouch
                or state.visualRig.CanQuery
                or (not state.visualRig.Massless)
            logInfo(string.format(
                "[RotationAudit] customSpinCodeActive=false visualRigPhysicsActive=%s",
                tostring(visualRigPhysicsActive)
            ))
        end
    end)

    logInfo(string.format(
        "[VisualSlideRig] physical=false anchored=%s weldedToVehicle=%s",
        tostring(visualRig.Anchored),
        tostring(isVisualRigWelded(carModel, visualRig))
    ))
end

local function placePlayersNearCar(carModel)
    local pivotPart = getCarPivotPart(carModel)
    if not pivotPart then
        return
    end

    local function placeCharacter(character, player)
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            hrp = character:WaitForChild("HumanoidRootPart", 10)
        end
        if not hrp then
            return
        end

        local baseCf = pivotPart.CFrame
        local targetPos = baseCf.Position
            + (baseCf.RightVector * PLAYER_OFFSET_RIGHT)
            + (baseCf.LookVector * PLAYER_OFFSET_BACK)
            + Vector3.new(0, PLAYER_OFFSET_UP, 0)

        hrp.CFrame = CFrame.new(targetPos, targetPos + baseCf.LookVector)

        local distance = (targetPos - baseCf.Position).Magnitude
        logInfo(string.format("[RacingPlayerPlacement] player=%s distanceFromVehicle=%.2f", player.Name, distance))
    end

    for _, player in ipairs(Players:GetPlayers()) do
        player.CharacterAdded:Connect(function(character)
            task.defer(placeCharacter, character, player)
        end)

        if player.Character then
            task.defer(placeCharacter, player.Character, player)
        end
    end
end

local function run()
    if started then
        return
    end
    started = true

    logInfo(string.format("[RacingIntegrationBuild] version=%s", BUILD_VERSION))

    if Workspace:GetAttribute(SPAWN_LOCK_ATTRIBUTE) == true then
        logFail("startup", "spawn_lock_already_set")
        return
    end

    local mapRoot, courseSpawn = waitForCourseSpawn(120)
    if not mapRoot or not courseSpawn then
        logFail("course", "course_spawn_not_found")
        return
    end

    local roads = collectRoads(mapRoot)
    local goalTrigger = findGoalTrigger(mapRoot)

    logInfo(string.format(
        "[RacingCourse] courseSpawnFound=%s roadCount=%d goalFound=%s",
        tostring(courseSpawn ~= nil),
        #roads,
        tostring(goalTrigger ~= nil)
    ))

    local carInfo = getCarTemplateInfo()
    if not carInfo then
        logFail("vehicle_source", "replicatedstorage_car_missing")
        return
    end

    logInfo(string.format(
        "[RacingVehicleSource] path=%s spawnMethod=%s controllerFound=%s driverSeatFound=%s",
        "ReplicatedStorage.Car",
        "ServerScriptService.CarSpawning.spawnCar",
        tostring(carInfo.controllerFound),
        tostring(carInfo.driverSeatFound)
    ))

    local rayOrigin = courseSpawn.Position + (courseSpawn.CFrame.LookVector * COURSE_SPAWN_FORWARD_OFFSET) + Vector3.new(0, COURSE_SPAWN_RAYCAST_HEIGHT, 0)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include
    rayParams.FilterDescendantsInstances = { mapRoot }
    rayParams.IgnoreWater = true

    local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -COURSE_SPAWN_RAYCAST_DISTANCE, 0), rayParams)
    if not rayResult then
        logFail("spawn", "road_raycast_failed")
        return
    end

    local up = rayResult.Normal.Magnitude > 0.001 and rayResult.Normal.Unit or Vector3.yAxis
    local forward = getDownhillDirection(roads, courseSpawn.CFrame.LookVector, up)

    local provisionalCf = CFrame.lookAt(rayResult.Position + (up * 3), rayResult.Position + (up * 3) + forward, up)
    local carModel, spawnErr = spawnOfficialCar(provisionalCf)
    if not carModel then
        logFail("spawn", spawnErr or "spawn_failed")
        return
    end

    local extentsY = carModel:GetExtentsSize().Y
    local finalPos = rayResult.Position + (up * ((extentsY * 0.5) + CAR_GROUND_CLEARANCE))
    local finalCf = CFrame.lookAt(finalPos, finalPos + forward, up)
    carModel:PivotTo(finalCf)

    local chassis = getCarPivotPart(carModel)
    local ownerText = "server"
    if chassis then
        local ok, owner = pcall(function()
            return chassis:GetNetworkOwner()
        end)
        if ok and owner then
            ownerText = owner.Name
        end
    end

    logInfo(string.format(
        "[RacingVehicleSpawn] model=%s chassis=%s position=(%.2f,%.2f,%.2f) forward=(%.3f,%.3f,%.3f) networkOwner=%s",
        carModel:GetFullName(),
        chassis and chassis:GetFullName() or "(none)",
        finalPos.X,
        finalPos.Y,
        finalPos.Z,
        forward.X,
        forward.Y,
        forward.Z,
        ownerText
    ))

    placePlayersNearCar(carModel)
    startWallDirectionAndVisualRigMonitor(carModel, mapRoot, forward)

    local legacyLoaded = getLegacySlideScriptsLoaded()
    logInfo(string.format("[RacingIntegration] legacySlideScriptsLoaded=%s", tostring(legacyLoaded)))

    Workspace:SetAttribute(SPAWN_LOCK_ATTRIBUTE, true)
end

task.defer(run)
