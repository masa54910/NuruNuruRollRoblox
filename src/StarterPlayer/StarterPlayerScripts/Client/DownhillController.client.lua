local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local DownhillState = require(ReplicatedStorage.Shared.DownhillState)

local projectConfig = Config.Project or {}
if projectConfig.EnableDownhillController ~= true then
    return
end

local settings = Config.Downhill or {}

local START_SPEED = tonumber(settings.StartSpeed) or 24
local MIN_GROUND_SPEED = tonumber(settings.MinimumGroundSpeed) or 28
local BASE_TARGET_SPEED = tonumber(settings.BaseTargetSpeed) or 48
local GROUND_ACCEL = tonumber(settings.GroundAcceleration) or 36
local MAX_LATERAL_SPEED = tonumber(settings.MaximumLateralSpeed) or 24
local GROUND_STEER_ACCEL = tonumber(settings.GroundSteerAcceleration) or 55
local GROUND_STEER_RELEASE = tonumber(settings.GroundSteerRelease) or 22
local GROUND_RAY_DISTANCE = tonumber(settings.GroundRayDistance) or 7

local DEBUG_ENABLED = projectConfig.EnableDownhillDebug == true
local PROBE_LOGS_ENABLED = projectConfig.EnableDownhillProbeLogs == true
local CLIENT_IMPULSE_PROBE_ENABLED = projectConfig.EnableDownhillClientImpulseProbe == true
local DEBUG_INTERVAL_SECONDS = 1

local localPlayer = Players.LocalPlayer

local inputState = {
    left = false,
    right = false,
    gamepadX = 0,
}

local runtime = {
    playerModule = nil,
    controls = nil,
    controlsDisabled = false,

    character = nil,
    humanoid = nil,
    root = nil,
    head = nil,

    currentRoadIndex = 1,
    lastValidRoadIndex = 1,
    lastValidForward = Vector3.new(0, 0, -1),
    startForward = Vector3.new(0, 0, -1),
    horizontalStartForward = Vector3.new(0, 0, -1),

    ready = false,
    initialized = false,
    heartbeatConnection = nil,
    startedAt = 0,
    restartApplied = false,

    lastDebugAt = 0,

    humanoidDefaults = {
        WalkSpeed = 16,
        AutoRotate = true,
    },
}

local globalConnections = {}

local function moveTowards(current, target, maxDelta)
    if current < target then
        return math.min(current + maxDelta, target)
    end
    return math.max(current - maxDelta, target)
end

local function isFiniteNumber(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector3(vector)
    if not vector then
        return false
    end

    return isFiniteNumber(vector.X)
        and isFiniteNumber(vector.Y)
        and isFiniteNumber(vector.Z)
end

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

local function getCourseSpawn()
    local mapRoot = Workspace:FindFirstChild("NuruNuruRollMap")
    local startFolder = mapRoot and mapRoot:FindFirstChild("Start")
    local spawn = startFolder and startFolder:FindFirstChild("CourseSpawn")
    if spawn and spawn:IsA("BasePart") then
        return spawn
    end

    spawn = mapRoot and mapRoot:FindFirstChild("CourseSpawn", true)
    if spawn and spawn:IsA("BasePart") then
        return spawn
    end

    return nil
end

local function getFrontHit(root, forward)
    if not root or not forward or forward.Magnitude <= 0.001 then
        return nil
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { runtime.character }
    params.IgnoreWater = true

    return Workspace:Raycast(root.Position, forward.Unit * 15, params)
end

local function printInitProbe(road1, road2, startForward, horizontalForward)
    if not PROBE_LOGS_ENABLED then
        return
    end

    local root = runtime.root
    local humanoid = runtime.humanoid
    local spawn = getCourseSpawn()
    local roadDelta = road2 and road1 and (road2.Position - road1.Position) or nil
    local frontHit = root and getFrontHit(root, horizontalForward)

    local spawnToRoad1 = (spawn and road1) and (road1.Position - spawn.Position).Magnitude or nil
    local spawnToRoad2 = (spawn and road2) and (road2.Position - spawn.Position).Magnitude or nil
    local lookDot = (road1 and horizontalForward and horizontalForward.Magnitude > 0.001) and horizontalForward:Dot(road1.CFrame.LookVector) or nil
    local rightDot = (road1 and horizontalForward and horizontalForward.Magnitude > 0.001) and horizontalForward:Dot(road1.CFrame.RightVector) or nil

    print(string.format(
        "[DownhillInitProbe]\nrootPosition=%s\nrootVelocity=%s\nrootAssemblyRoot=%s\nrootMass=%.3f\nrootAnchored=%s\nhumanoidState=%s\nfloorMaterial=%s\nmoveDirection=%s\ncontrolsDisabled=%s\nroad1Position=%s\nroad2Position=%s\ncourseSpawnPosition=%s\nspawnToRoad1=%s\nspawnToRoad2=%s\nrawForward=%s\nhorizontalForward=%s\nforwardMagnitude=%.3f\nroad1LookVector=%s\nroad1RightVector=%s\nroad1Size=%s\nforwardDotLook=%s\nforwardDotRight=%s\nfrontHit=%s\nfrontHitDistance=%s\nnetworkOwner=clientUnknown",
        formatVector3(root and root.Position),
        formatVector3(root and root.AssemblyLinearVelocity),
        formatInstance(root and root.AssemblyRootPart),
        root and root.AssemblyMass or 0,
        tostring(root and root.Anchored),
        humanoid and tostring(humanoid:GetState()) or "(nil)",
        humanoid and tostring(humanoid.FloorMaterial) or "(nil)",
        formatVector3(humanoid and humanoid.MoveDirection),
        tostring(runtime.controlsDisabled),
        formatVector3(road1 and road1.Position),
        formatVector3(road2 and road2.Position),
        formatVector3(spawn and spawn.Position),
        spawnToRoad1 and string.format("%.3f", spawnToRoad1) or "(nil)",
        spawnToRoad2 and string.format("%.3f", spawnToRoad2) or "(nil)",
        formatVector3(roadDelta),
        formatVector3(horizontalForward),
        horizontalForward and horizontalForward.Magnitude or 0,
        formatVector3(road1 and road1.CFrame.LookVector),
        formatVector3(road1 and road1.CFrame.RightVector),
        formatVector3(road1 and road1.Size),
        lookDot and string.format("%.3f", lookDot) or "(nil)",
        rightDot and string.format("%.3f", rightDot) or "(nil)",
        formatInstance(frontHit and frontHit.Instance),
        frontHit and string.format("%.3f", frontHit.Distance) or "(nil)"
    ))
end

local function runClientImpulseProbe()
    local root = runtime.root
    local humanoid = runtime.humanoid
    if not root or not humanoid then
        return
    end

    root.Anchored = false
    humanoid.AutoRotate = true
    humanoid.PlatformStand = false
    humanoid.WalkSpeed = 16
    enableControls()

    task.wait(3)

    if root ~= runtime.root or not root.Parent then
        return
    end

    local look = root.CFrame.LookVector
    local testForward = Vector3.new(look.X, 0, look.Z)
    if testForward.Magnitude <= 0.001 then
        warn("[DownhillFailure] Client impulse probe could not resolve Character LookVector")
        return
    end
    testForward = testForward.Unit

    local before = root.AssemblyLinearVelocity
    local writeVelocity = (testForward * 40) + Vector3.new(0, before.Y, 0)
    root.AssemblyLinearVelocity = writeVelocity
    local afterWrite = root.AssemblyLinearVelocity

    print(string.format(
        "[DownhillWriteProbe]\nmode=ClientImpulseOnce\nusedDirection=%s\nvelocityBefore=%s\nvelocityAfterWrite=%s\nrootPosition=%s\nhumanoidState=%s\nfloorMaterial=%s\nrootAnchored=%s\nrootAssemblyRoot=%s",
        formatVector3(testForward),
        formatVector3(before),
        formatVector3(afterWrite),
        formatVector3(root.Position),
        tostring(humanoid:GetState()),
        tostring(humanoid.FloorMaterial),
        tostring(root.Anchored),
        formatInstance(root.AssemblyRootPart)
    ))

    RunService.Heartbeat:Wait()
    local nextFrame = root.AssemblyLinearVelocity
    task.wait(0.1)
    local afterPointOne = root.AssemblyLinearVelocity
    task.wait(0.4)
    local afterPointFive = root.AssemblyLinearVelocity

    print(string.format(
        "[DownhillPersistenceProbe]\nmode=ClientImpulseOnce\nvelocityNextFrame=%s\nvelocityAfter0_1s=%s\nvelocityAfter0_5s=%s\npositionAfter0_5s=%s\nforwardSpeedNext=%.3f\nforwardSpeed0_5=%.3f",
        formatVector3(nextFrame),
        formatVector3(afterPointOne),
        formatVector3(afterPointFive),
        formatVector3(root.Position),
        nextFrame:Dot(testForward),
        afterPointFive:Dot(testForward)
    ))
end

local function logError(message)
    warn(string.format("[DownhillError] %s", message))
end

local function getSteerInput()
    local steer = 0
    if inputState.left then
        steer -= 1
    end
    if inputState.right then
        steer += 1
    end

    if math.abs(inputState.gamepadX) > math.abs(steer) then
        steer = inputState.gamepadX
    end

    return math.clamp(steer, -1, 1)
end

local function getLookAheadFromSpeed(speed)
    if speed < 45 then
        return 1
    end
    if speed < 75 then
        return 2
    end
    if speed < 100 then
        return 3
    end
    return 4
end

local function ensureControls()
    if runtime.controls then
        return true
    end

    local playerScripts = localPlayer:FindFirstChild("PlayerScripts") or localPlayer:WaitForChild("PlayerScripts", 10)
    if not playerScripts then
        return false
    end

    local playerModuleScript = playerScripts:FindFirstChild("PlayerModule")
    if not playerModuleScript then
        return false
    end

    local ok, playerModule = pcall(require, playerModuleScript)
    if not ok or not playerModule then
        return false
    end

    runtime.playerModule = playerModule
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

local function restoreHumanoidFallback()
    local humanoid = runtime.humanoid
    if not humanoid or not humanoid.Parent then
        return
    end

    humanoid.WalkSpeed = 16
    humanoid.AutoRotate = true
end

local function restoreHumanoidDefaults()
    local humanoid = runtime.humanoid
    if not humanoid or not humanoid.Parent then
        return
    end

    humanoid.WalkSpeed = runtime.humanoidDefaults.WalkSpeed
    humanoid.AutoRotate = runtime.humanoidDefaults.AutoRotate
end

local function applyMinimalHumanoidSettings()
    local humanoid = runtime.humanoid
    if not humanoid then
        return
    end

    runtime.humanoidDefaults.WalkSpeed = humanoid.WalkSpeed
    runtime.humanoidDefaults.AutoRotate = humanoid.AutoRotate

    humanoid.WalkSpeed = 0
    humanoid.AutoRotate = true
end

local function clearHeartbeat()
    if runtime.heartbeatConnection then
        runtime.heartbeatConnection:Disconnect()
        runtime.heartbeatConnection = nil
    end
end

local function cleanupCharacterState()
    clearHeartbeat()
    enableControls()
    restoreHumanoidDefaults()
    DownhillState.reset()

    runtime.character = nil
    runtime.humanoid = nil
    runtime.root = nil
    runtime.head = nil

    runtime.currentRoadIndex = 1
    runtime.lastValidRoadIndex = 1
    runtime.lastValidForward = Vector3.new(0, 0, -1)
    runtime.startForward = Vector3.new(0, 0, -1)
    runtime.horizontalStartForward = Vector3.new(0, 0, -1)
    runtime.startedAt = 0
    runtime.restartApplied = false

    runtime.ready = false
    runtime.initialized = false
end

local function resolveStartForward(road1, road2)
    if not road1 or not road2 then
        return nil, "Road_0001 or Road_0002 is missing"
    end

    local rawStartForward = road2.Position - road1.Position
    if rawStartForward.Magnitude < 0.1 then
        return nil, "Invalid start direction (too short)"
    end

    local startForward = rawStartForward.Unit
    if not isFiniteVector3(startForward) then
        return nil, "Invalid start direction (NaN/Inf)"
    end

    if math.abs(startForward.Y) > 0.95 then
        return nil, "Start direction is nearly vertical"
    end

    return startForward, nil
end

local function updateRoadIndexFromRaycast(rootPosition)
    local sample = DownhillCourse.raycastRoad(rootPosition + Vector3.new(0, 1.5, 0), GROUND_RAY_DISTANCE)
    if not sample or not sample.index then
        runtime.currentRoadIndex = runtime.lastValidRoadIndex
        return
    end

    local detectedIndex = sample.index
    local currentIndex = runtime.currentRoadIndex

    if detectedIndex >= (currentIndex - 1) then
        runtime.currentRoadIndex = math.max(detectedIndex, 1)
        runtime.lastValidRoadIndex = runtime.currentRoadIndex
    else
        runtime.currentRoadIndex = runtime.lastValidRoadIndex
    end
end

local function updateDownhill(dt)
    if not runtime.ready or not runtime.root or not runtime.humanoid then
        return
    end

    if runtime.humanoid.Health <= 0 then
        return
    end

    local root = runtime.root
    local currentVelocity = root.AssemblyLinearVelocity

    updateRoadIndexFromRaycast(root.Position)

    local currentRoad = DownhillCourse.getRoad(runtime.currentRoadIndex)
    local nextIndex = DownhillCourse.getNextIndex(runtime.currentRoadIndex, 1)

    local sample = DownhillCourse.raycastRoad(root.Position + Vector3.new(0, 1.5, 0), GROUND_RAY_DISTANCE)
    local groundedNow = sample ~= nil

    local trackForward = runtime.startForward
    local horizontalForward = runtime.horizontalStartForward

    if not isFiniteVector3(trackForward) then
        logError("startForward is invalid")
        return
    end

    if horizontalForward.Magnitude < 0.1 then
        logError("horizontalForward is invalid")
        return
    end

    horizontalForward = horizontalForward.Unit

    local trackRight = horizontalForward:Cross(Vector3.yAxis)
    if trackRight.Magnitude < 0.1 then
        logError("trackRight is invalid")
        return
    end
    trackRight = trackRight.Unit

    local horizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z)
    local forwardSpeed = horizontalVelocity:Dot(horizontalForward)
    local lateralSpeed = horizontalVelocity:Dot(trackRight)
    local steerInput = getSteerInput()

    local targetForwardSpeed = BASE_TARGET_SPEED
    if targetForwardSpeed <= 0 then
        logError("targetForwardSpeed is zero")
        return
    end

    local newForwardSpeed = moveTowards(
        forwardSpeed,
        targetForwardSpeed,
        GROUND_ACCEL * dt
    )

    if newForwardSpeed < MIN_GROUND_SPEED then
        newForwardSpeed = math.min(
            MIN_GROUND_SPEED,
            forwardSpeed + (GROUND_ACCEL * dt)
        )
    end

    local targetLateralSpeed = steerInput * MAX_LATERAL_SPEED
    local newLateralSpeed

    if math.abs(steerInput) > 0.001 then
        newLateralSpeed = moveTowards(
            lateralSpeed,
            targetLateralSpeed,
            GROUND_STEER_ACCEL * dt
        )
    else
        newLateralSpeed = moveTowards(
            lateralSpeed,
            0,
            GROUND_STEER_RELEASE * dt
        )
    end

    local desiredHorizontal =
        horizontalForward * newForwardSpeed
        + trackRight * newLateralSpeed

    root.AssemblyLinearVelocity = Vector3.new(
        desiredHorizontal.X,
        currentVelocity.Y,
        desiredHorizontal.Z
    )

    local elapsedFromStart = os.clock() - runtime.startedAt
    if elapsedFromStart >= 3 and forwardSpeed < 2 and not runtime.restartApplied then
        root.AssemblyLinearVelocity =
            horizontalForward * START_SPEED
            + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)

        runtime.restartApplied = true
    end

    if horizontalForward.Magnitude < 0.9 then
        logError("Invalid horizontalForward")
    end

    DownhillState.update({
        active = true,
        grounded = groundedNow,
        roadName = currentRoad and currentRoad.Name or "",
        speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude,
        targetSpeed = targetForwardSpeed,
        lateral = newLateralSpeed,
        slope = 0,
        lookAhead = 1,
        steerInput = steerInput,
        forward = trackForward,
        groundNormal = Vector3.yAxis,
        headPosition = runtime.head and runtime.head.Position or root.Position,
        rootPosition = root.Position,
    })

    local now = os.clock()
    if DEBUG_ENABLED and now >= runtime.lastDebugAt then
        runtime.lastDebugAt = now + DEBUG_INTERVAL_SECONDS

        print(string.format(
            "[DownhillForward]\nstartForward=%s\nhorizontalForward=%s\nvelocity=%s\nforwardSpeed=%.3f\nnewForwardSpeed=%.3f\ntargetSpeed=%.3f\nlateralSpeed=%.3f\ngrounded=%s\nrootAnchored=%s",
            formatVector3(runtime.startForward),
            formatVector3(horizontalForward),
            formatVector3(root.AssemblyLinearVelocity),
            forwardSpeed,
            newForwardSpeed,
            targetForwardSpeed,
            newLateralSpeed,
            tostring(groundedNow),
            tostring(root.Anchored)
        ))
    end
end

local function onInputBegan(input, gameProcessed)
    if gameProcessed then
        return
    end

    if input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
            inputState.left = true
        elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
            inputState.right = true
        end
    end
end

local function onInputEnded(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
            inputState.left = false
        elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
            inputState.right = false
        end
    end
end

local function onInputChanged(input)
    if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
        local x = input.Position.X
        if math.abs(x) < 0.08 then
            x = 0
        end
        inputState.gamepadX = math.clamp(x, -1, 1)
    end
end

local function initializeCharacter(character)
    cleanupCharacterState()

    runtime.character = character
    runtime.humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    runtime.root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    runtime.head = character:FindFirstChild("Head") or runtime.root

    if not runtime.humanoid or not runtime.root then
        logError("Humanoid or HumanoidRootPart is missing")
        restoreHumanoidFallback()
        enableControls()
        return
    end

    local camera = Workspace.CurrentCamera
    if camera then
        camera.CameraType = Enum.CameraType.Custom
    end

    if not DownhillCourse.ensureCache(30) then
        logError("Course cache is not ready")
        restoreHumanoidFallback()
        enableControls()
        return
    end

    if DownhillCourse.getRoadCount() < 2 then
        logError("Road count is less than 2")
        restoreHumanoidFallback()
        enableControls()
        return
    end

    local road1 = DownhillCourse.getRoad(1)
    local road2 = DownhillCourse.getRoad(2)

    if not road1 or not road2 then
        logError("Road_0001 or Road_0002 is missing")
        restoreHumanoidFallback()
        enableControls()
        return
    end

    if road1.Name ~= "Road_0001" or road2.Name ~= "Road_0002" then
        logError(string.format("Unexpected road order: road1=%s road2=%s", road1.Name, road2.Name))
        restoreHumanoidFallback()
        enableControls()
        return
    end

    local startForward, forwardError = resolveStartForward(road1, road2)
    if not startForward then
        logError(forwardError or "Invalid startForward")
        restoreHumanoidFallback()
        enableControls()
        return
    end

    local horizontalStartForward = Vector3.new(startForward.X, 0, startForward.Z)
    if horizontalStartForward.Magnitude < 0.1 then
        logError("Horizontal start direction is invalid")
        restoreHumanoidFallback()
        enableControls()
        return
    end
    horizontalStartForward = horizontalStartForward.Unit

    runtime.currentRoadIndex = 1
    runtime.lastValidRoadIndex = 1
    runtime.lastValidForward = startForward
    runtime.startForward = startForward
    runtime.horizontalStartForward = horizontalStartForward
    runtime.startedAt = os.clock()
    runtime.restartApplied = false

    printInitProbe(road1, road2, startForward, horizontalStartForward)

    if CLIENT_IMPULSE_PROBE_ENABLED then
        clearHeartbeat()
        runtime.root.Anchored = false
        runtime.root.AssemblyAngularVelocity = Vector3.zero
        runtime.ready = false
        runtime.initialized = true
        restoreHumanoidFallback()
        enableControls()
        task.spawn(runClientImpulseProbe)
        print("[DownhillInit] Client impulse probe mode enabled; downhill Heartbeat movement is paused")
        return
    end

    clearHeartbeat()
    runtime.heartbeatConnection = RunService.Heartbeat:Connect(updateDownhill)

    runtime.root.Anchored = false
    runtime.root.AssemblyAngularVelocity = Vector3.zero

    local initialTrackRight = horizontalStartForward:Cross(Vector3.yAxis)
    if initialTrackRight.Magnitude < 0.1 then
        logError("Initial trackRight is invalid")
        restoreHumanoidFallback()
        enableControls()
        return
    end
    initialTrackRight = initialTrackRight.Unit

    local velocity = runtime.root.AssemblyLinearVelocity
    local verticalVelocity = Vector3.new(0, velocity.Y, 0)
    local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
    local currentLateralSpeed = horizontalVelocity:Dot(initialTrackRight)

    runtime.root.AssemblyLinearVelocity =
        horizontalStartForward * START_SPEED
        + initialTrackRight * currentLateralSpeed
        + verticalVelocity

    runtime.ready = true
    runtime.initialized = true

    applyMinimalHumanoidSettings()
    runtime.humanoid.PlatformStand = false
    runtime.humanoid:Move(Vector3.zero, false)
    disableControls()

    print(string.format(
        "[DownhillInit]\nroad1=%s\nroad2=%s\nstartForward=%s\ncontrolsDisabled=%s",
        road1.Name,
        road2.Name,
        formatVector3(startForward),
        tostring(runtime.controlsDisabled)
    ))
end

table.insert(globalConnections, UserInputService.InputBegan:Connect(onInputBegan))
table.insert(globalConnections, UserInputService.InputEnded:Connect(onInputEnded))
table.insert(globalConnections, UserInputService.InputChanged:Connect(onInputChanged))
table.insert(globalConnections, localPlayer.CharacterAdded:Connect(initializeCharacter))
table.insert(globalConnections, localPlayer.CharacterRemoving:Connect(function()
    cleanupCharacterState()
end))

if localPlayer.Character then
    task.defer(function()
        initializeCharacter(localPlayer.Character)
    end)
end
