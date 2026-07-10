-- SledServerController.server.lua
-- Spawns and controls a simple one-seat sled for each player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local remoteSet = Remotes.get()

local MAP_ROOT_NAME = "NuruNuruRollMap"
local SLED_FOLDER_NAME = "Sleds"

local settings = Config.Sled or {}
local ENABLE_LEGACY_SLED_SYSTEM = Config.Project and Config.Project.EnableLegacySledSystem == true

if not ENABLE_LEGACY_SLED_SYSTEM then
    print("[Sled] Legacy sled system disabled by Config.Project.EnableLegacySledSystem")
    return
end

local DEBUG_SLED = settings.Debug == true
local MIN_SPEED = tonumber(settings.MinSpeed) or 42
local CRUISE_SPEED = tonumber(settings.CruiseSpeed) or 72
local MAX_SPEED = tonumber(settings.MaxSpeed) or 112
local THROTTLE_BOOST = tonumber(settings.ThrottleBoost) or 28
local BRAKE_DECEL = tonumber(settings.BrakeDeceleration) or 62
local BASE_ACCEL = tonumber(settings.BaseAcceleration) or 36
local STEERING_YAW_RATE = math.rad(tonumber(settings.SteeringYawRateDeg) or 82)
local STEERING_RESPONSE = tonumber(settings.SteeringResponse) or 8
local LATERAL_DAMPING = tonumber(settings.LateralDamping) or 3.2
local SLOPE_ASSIST = tonumber(settings.SlopeAssist) or 46
local GROUND_RAY_DISTANCE = tonumber(settings.GroundRayDistance) or 24
local GROUNDED_DISTANCE = tonumber(settings.GroundedDistance) or 2
local NEAR_GROUND_DISTANCE = tonumber(settings.NearGroundDistance) or 8
local MIN_SPEED_RECOVERY_ACCEL = tonumber(settings.MinSpeedRecoveryAccel) or 60
local STUCK_BOOST_ACCEL = tonumber(settings.StuckBoostAccel) or 95
local RESPAWN_Y_MARGIN = tonumber(settings.RespawnYMargin) or 120
local RESPAWN_UNSEATED_SECONDS = tonumber(settings.RespawnUnseatedSeconds) or 2.5
local RESPAWN_STOP_SECONDS = tonumber(settings.RespawnStopSeconds) or 3.5
local RESPAWN_TIPPED_SECONDS = tonumber(settings.RespawnTippedSeconds) or 2.2
local COUNTDOWN_SECONDS = tonumber(settings.CountdownSeconds) or 2

local ZERO = Vector3.new(0, 0, 0)
local UP = Vector3.new(0, 1, 0)
local GRAVITY_DIR = Vector3.new(0, -1, 0)

local statesByUserId = {}

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function flattenUnit(vector, fallback)
    local v = Vector3.new(vector.X, 0, vector.Z)
    if v.Magnitude <= 0.001 then
        return fallback
    end
    return v.Unit
end

local function ensureFolder(parent, name)
    local folder = parent:FindFirstChild(name)
    if folder and folder:IsA("Folder") then
        return folder
    end
    if folder then
        folder:Destroy()
    end

    folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function getMapFolders()
    local mapRoot = Workspace:FindFirstChild(MAP_ROOT_NAME)
    local courseFolder = mapRoot and mapRoot:FindFirstChild("Course")
    local lotionFolder = mapRoot and mapRoot:FindFirstChild("Lotion")
    local startFolder = mapRoot and mapRoot:FindFirstChild("Start")
    local wallFolder = mapRoot and mapRoot:FindFirstChild("CourseWalls")
    return mapRoot, courseFolder, lotionFolder, startFolder, wallFolder
end

local function waitForMapReady(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    while os.clock() < deadline do
        local mapReady = Workspace:GetAttribute("NuruNuruRollMapReady") == true
        local mapRoot, _, _, startFolder = getMapFolders()
        local spawn = startFolder and startFolder:FindFirstChild("CourseSpawn")
        if mapReady and mapRoot and spawn and spawn:IsA("BasePart") then
            return mapRoot, startFolder, spawn
        end
        task.wait(0.2)
    end

    return nil, nil, nil
end

local function createSledModel(player, spawnCFrame)
    local model = Instance.new("Model")
    model.Name = string.format("Sled_%d", player.UserId)
    model:SetAttribute("OwnerUserId", player.UserId)
    model:SetAttribute("IsSled", true)

    local base = Instance.new("Part")
    base.Name = "Base"
    base.Size = Vector3.new(7, 1.2, 11)
    base.Material = Enum.Material.SmoothPlastic
    base.Color = Color3.fromRGB(120, 180, 255)
    base.CFrame = spawnCFrame
    base.TopSurface = Enum.SurfaceType.Smooth
    base.BottomSurface = Enum.SurfaceType.Smooth
    base.Anchored = false
    base.CanCollide = true
    base.Massless = false
    base.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0.1, 1, 1)
    base.Parent = model

    local seat = Instance.new("Seat")
    seat.Name = "SledSeat"
    seat.Size = Vector3.new(2.4, 1.1, 2.8)
    seat.Material = Enum.Material.SmoothPlastic
    seat.Color = Color3.fromRGB(40, 40, 48)
    seat.CFrame = spawnCFrame * CFrame.new(0, 1.35, 0.8)
    seat.TopSurface = Enum.SurfaceType.Smooth
    seat.BottomSurface = Enum.SurfaceType.Smooth
    seat.Anchored = false
    seat.CanCollide = false
    seat.Massless = true
    seat.Parent = model

    local leftRail = Instance.new("Part")
    leftRail.Name = "LeftRail"
    leftRail.Size = Vector3.new(0.7, 0.9, 10)
    leftRail.Material = Enum.Material.Metal
    leftRail.Color = Color3.fromRGB(190, 190, 190)
    leftRail.CFrame = spawnCFrame * CFrame.new(-2.2, -0.45, 0)
    leftRail.TopSurface = Enum.SurfaceType.Smooth
    leftRail.BottomSurface = Enum.SurfaceType.Smooth
    leftRail.Anchored = false
    leftRail.CanCollide = false
    leftRail.Massless = true
    leftRail.Parent = model

    local rightRail = leftRail:Clone()
    rightRail.Name = "RightRail"
    rightRail.CFrame = spawnCFrame * CFrame.new(2.2, -0.45, 0)
    rightRail.Parent = model

    local baseAttachment = Instance.new("Attachment")
    baseAttachment.Name = "RootAttachment"
    baseAttachment.Parent = base

    local align = Instance.new("AlignOrientation")
    align.Name = "StabilityAlign"
    align.Attachment0 = baseAttachment
    align.Mode = Enum.OrientationAlignmentMode.OneAttachment
    align.RigidityEnabled = false
    align.MaxTorque = 65000
    align.MaxAngularVelocity = 14
    align.Responsiveness = 20
    align.Enabled = true
    align.Parent = base

    local function weldToBase(part)
        local weld = Instance.new("WeldConstraint")
        weld.Part0 = base
        weld.Part1 = part
        weld.Parent = base
    end

    weldToBase(seat)
    weldToBase(leftRail)
    weldToBase(rightRail)

    model.PrimaryPart = base
    return model, base, seat, align
end

local function setNetworkOwnerServer(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            pcall(function()
                d:SetNetworkOwner(nil)
            end)
        end
    end
end

local function buildSpawnCFrame(spawnPart)
    local basePos = spawnPart.Position + Vector3.new(0, 3.5, 0)
    local look = spawnPart.CFrame.LookVector
    local flatLook = flattenUnit(look, Vector3.new(0, 0, -1))
    return CFrame.lookAt(basePos, basePos + flatLook, UP)
end

local function setHumanoidAutorotate(humanoid, value)
    if humanoid and humanoid.Parent then
        humanoid.AutoRotate = value
    end
end

local function clearSledState(state)
    if not state then
        return
    end

    if state.activeHumanoid then
        setHumanoidAutorotate(state.activeHumanoid, true)
        state.activeHumanoid = nil
    end

    if state.model and state.model.Parent then
        state.model:Destroy()
    end
end

local function seatPlayer(player, seat)
    task.defer(function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid and seat and seat.Parent then
            seat:Sit(humanoid)
            setHumanoidAutorotate(humanoid, false)
            print("[Sled] Player seated")
        end
    end)
end

local function createOrReplaceSled(player)
    local old = statesByUserId[player.UserId]
    if old then
        clearSledState(old)
    end

    local mapRoot, _, spawn = waitForMapReady(10)
    if not mapRoot or not spawn then
        return
    end

    local sledFolder = ensureFolder(mapRoot, SLED_FOLDER_NAME)
    local spawnCFrame = buildSpawnCFrame(spawn)
    local model, base, seat, align = createSledModel(player, spawnCFrame)
    model.Parent = sledFolder
    model:PivotTo(spawnCFrame)
    setNetworkOwnerServer(model)

    local initialHeading = flattenUnit(base.CFrame.LookVector, Vector3.new(0, 0, -1))
    local state = {
        player = player,
        model = model,
        base = base,
        seat = seat,
        align = align,
        heading = initialHeading,
        throttle = 0,
        steering = 0,
        controlEnableAt = os.clock() + COUNTDOWN_SECONDS,
        inputEnabledLogged = false,
        lastSafeCFrame = spawnCFrame,
        lastSafeTime = os.clock(),
        tippedSince = nil,
        lowSpeedSince = nil,
        veryLowSpeedSince = nil,
        unseatedSince = nil,
        spawnCFrame = spawnCFrame,
        respawnY = spawnCFrame.Position.Y - RESPAWN_Y_MARGIN,
        activeHumanoid = nil,
        finished = false,
        lastDebugLog = 0,
        debugStuckTime = 0,
    }

    base.Touched:Connect(function(hit)
        if not hit then
            return
        end
        local wallFolder = model.Parent and model.Parent.Parent and model.Parent.Parent:FindFirstChild("CourseWalls")
        if wallFolder and hit:IsDescendantOf(wallFolder) then
            local v = base.AssemblyLinearVelocity
            local right = base.CFrame.RightVector
            local lateral = v:Dot(right)
            base.AssemblyLinearVelocity = v - (right * lateral * 0.55)
        end
    end)

    statesByUserId[player.UserId] = state
    seatPlayer(player, seat)
    print("[Sled] Sled spawned")
end

local function respawnState(state, reason)
    if not state or not state.model or not state.model.Parent then
        return
    end

    local base = state.base
    if not base then
        return
    end

    local target = state.lastSafeCFrame or state.spawnCFrame
    base.AssemblyLinearVelocity = ZERO
    base.AssemblyAngularVelocity = ZERO
    state.model:PivotTo(target)
    state.heading = flattenUnit(target.LookVector, state.heading)

    state.tippedSince = nil
    state.lowSpeedSince = nil
    state.veryLowSpeedSince = nil
    state.unseatedSince = nil
    state.controlEnableAt = os.clock() + 0.5
    state.finished = false

    seatPlayer(state.player, state.seat)
    print(string.format("[Sled] Respawned (%s)", tostring(reason)))
end

local function getGroundInfo(state)
    local base = state.base
    local mapRoot, courseFolder, lotionFolder = getMapFolders()
    if not base or not mapRoot then
        return {
            grounded = false,
            nearGround = false,
            airborne = true,
            normal = UP,
            distance = math.huge,
        }
    end

    local character = state.player and state.player.Character

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { state.model, character }

    local ray = Workspace:Raycast(base.Position, Vector3.new(0, -GROUND_RAY_DISTANCE, 0), params)
    if not ray then
        return {
            grounded = false,
            nearGround = false,
            airborne = true,
            normal = UP,
            distance = math.huge,
        }
    end

    local hit = ray.Instance
    local onCourse = false
    if courseFolder and hit:IsDescendantOf(courseFolder) then
        onCourse = true
    elseif lotionFolder and hit:IsDescendantOf(lotionFolder) then
        onCourse = true
    end

    if not onCourse then
        return {
            grounded = false,
            nearGround = false,
            airborne = true,
            normal = UP,
            distance = (base.Position - ray.Position).Magnitude,
        }
    end

    local distance = (base.Position - ray.Position).Magnitude
    return {
        grounded = distance <= GROUNDED_DISTANCE,
        nearGround = distance <= NEAR_GROUND_DISTANCE,
        airborne = distance > NEAR_GROUND_DISTANCE,
        normal = ray.Normal,
        distance = distance,
    }
end

local function moveTowards(current, target, delta)
    if current < target then
        return math.min(target, current + delta)
    end
    return math.max(target, current - delta)
end

local function applyInputToHeading(state, dt)
    local steering = state.steering
    if math.abs(steering) <= 0.001 then
        return
    end

    local yawDelta = STEERING_YAW_RATE * steering * dt
    local rotation = CFrame.fromAxisAngle(UP, yawDelta)
    local rotated = rotation:VectorToWorldSpace(state.heading)
    state.heading = flattenUnit(rotated, state.heading)
end

local function debugState(state, data)
    if not DEBUG_SLED then
        return
    end

    local now = os.clock()
    if now - (state.lastDebugLog or 0) < 1 then
        return
    end
    state.lastDebugLog = now

    local p = data.position
    local h = state.heading
    local v = data.velocity
    print(string.format(
        "[SledDebug] speed=%.1f horizontal=%.1f steering=%.1f throttle=%.1f grounded=%s nearGround=%s occupied=%s stuck=%.1f heading=(%.2f, %.2f, %.2f) vel=(%.1f, %.1f, %.1f) pos=(%.1f, %.1f, %.1f)",
        data.speed,
        data.horizontalSpeed,
        state.steering,
        state.throttle,
        tostring(data.grounded),
        tostring(data.nearGround),
        tostring(data.occupied),
        state.debugStuckTime or 0,
        h.X,
        h.Y,
        h.Z,
        v.X,
        v.Y,
        v.Z,
        p.X,
        p.Y,
        p.Z
    ))
end

local function updateState(state, dt)
    local base = state.base
    local seat = state.seat
    local align = state.align
    if not (base and seat and align and state.model and state.model.Parent) then
        return
    end

    local now = os.clock()
    local occupied = seat.Occupant ~= nil
    if occupied then
        local humanoid = seat.Occupant
        state.activeHumanoid = humanoid
        setHumanoidAutorotate(humanoid, false)
        state.unseatedSince = nil
    else
        if state.activeHumanoid then
            setHumanoidAutorotate(state.activeHumanoid, true)
            state.activeHumanoid = nil
        end
        state.unseatedSince = state.unseatedSince or now
        if now - state.unseatedSince > RESPAWN_UNSEATED_SECONDS then
            respawnState(state, "unseated")
            return
        end
    end

    if now >= state.controlEnableAt and not state.inputEnabledLogged then
        state.inputEnabledLogged = true
        print("[Sled] Input controller enabled")
    end

    local inputEnabled = now >= state.controlEnableAt and occupied and not state.finished
    if not inputEnabled then
        state.steering = 0
        state.throttle = 0
    end

    applyInputToHeading(state, dt)

    local ground = getGroundInfo(state)
    local upVector = (ground.grounded or ground.nearGround) and ground.normal or UP

    local downhill = GRAVITY_DIR - (upVector * GRAVITY_DIR:Dot(upVector))
    local downhillDir
    if downhill.Magnitude > 0.05 then
        downhillDir = downhill.Unit
    else
        downhillDir = state.heading
    end

    local velocity = base.AssemblyLinearVelocity
    local horizontalVel = Vector3.new(velocity.X, 0, velocity.Z)
    local horizontalSpeed = horizontalVel.Magnitude
    local currentSpeed = velocity.Magnitude

    local right = Vector3.new(state.heading.Z, 0, -state.heading.X)
    if right.Magnitude > 0.001 then
        right = right.Unit
    else
        right = Vector3.new(1, 0, 0)
    end

    local forwardSpeed = horizontalVel:Dot(state.heading)
    local lateralSpeed = horizontalVel:Dot(right)

    local slopeFactor = math.max(0, state.heading:Dot(downhillDir))
    local targetSpeed = math.max(MIN_SPEED, CRUISE_SPEED + (slopeFactor * SLOPE_ASSIST))

    if state.throttle > 0 then
        targetSpeed += state.throttle * THROTTLE_BOOST
    elseif state.throttle < 0 then
        targetSpeed += state.throttle * BRAKE_DECEL
    end

    if state.finished then
        targetSpeed = 0
    end

    targetSpeed = clamp(targetSpeed, 0, MAX_SPEED)

    local accel = BASE_ACCEL
    if state.throttle < 0 and forwardSpeed > targetSpeed then
        accel = BRAKE_DECEL
    end

    local nextForwardSpeed = moveTowards(forwardSpeed, targetSpeed, accel * dt)
    local nextLateralSpeed = lateralSpeed * clamp(1 - (LATERAL_DAMPING * dt), 0, 1)

    local desiredHorizontal = (state.heading * nextForwardSpeed) + (right * nextLateralSpeed)
    local steerWeight = clamp(STEERING_RESPONSE * dt * ((math.abs(state.steering) > 0.01) and 1 or 0.45), 0, 1)
    local newHorizontal = horizontalVel:Lerp(desiredHorizontal, steerWeight)

    if occupied and not state.finished and ground.nearGround then
        local speedNow = newHorizontal.Magnitude
        if speedNow < MIN_SPEED then
            local missing = MIN_SPEED - speedNow
            local assist = math.min(missing, MIN_SPEED_RECOVERY_ACCEL * dt)
            newHorizontal += state.heading * assist
        end
    end

    local speedForStuck = newHorizontal.Magnitude
    if occupied and not state.finished and ground.nearGround and now > state.controlEnableAt then
        if speedForStuck < 10 then
            state.lowSpeedSince = state.lowSpeedSince or now
            state.debugStuckTime = now - state.lowSpeedSince
            if state.debugStuckTime > 1.0 then
                newHorizontal += state.heading * (STUCK_BOOST_ACCEL * dt)
            end
        else
            state.lowSpeedSince = nil
            state.debugStuckTime = 0
        end

        if speedForStuck < 5 then
            state.veryLowSpeedSince = state.veryLowSpeedSince or now
            if now - state.veryLowSpeedSince > math.max(RESPAWN_STOP_SECONDS, 4.0) then
                respawnState(state, "stuck")
                return
            end
        else
            state.veryLowSpeedSince = nil
        end
    else
        state.lowSpeedSince = nil
        state.veryLowSpeedSince = nil
        state.debugStuckTime = 0
    end

    if newHorizontal.Magnitude > MAX_SPEED then
        newHorizontal = newHorizontal.Unit * MAX_SPEED
    end

    base.AssemblyLinearVelocity = Vector3.new(newHorizontal.X, velocity.Y, newHorizontal.Z)

    local yawRate = state.steering * STEERING_YAW_RATE * clamp(newHorizontal.Magnitude / MAX_SPEED, 0.2, 1)
    base.AssemblyAngularVelocity = Vector3.new(0, yawRate, 0)

    align.CFrame = CFrame.lookAt(base.Position, base.Position + state.heading, upVector)

    if ground.nearGround and newHorizontal.Magnitude > 12 and base.CFrame.UpVector:Dot(UP) > 0.65 then
        state.lastSafeCFrame = base.CFrame
        state.lastSafeTime = now
    end

    if base.Position.Y < state.respawnY then
        respawnState(state, "fell")
        return
    end

    local tipped = base.CFrame.UpVector:Dot(UP) < 0.35
    if tipped then
        state.tippedSince = state.tippedSince or now
        if now - state.tippedSince > RESPAWN_TIPPED_SECONDS then
            respawnState(state, "tipped")
            return
        end
    else
        state.tippedSince = nil
    end

    debugState(state, {
        speed = currentSpeed,
        horizontalSpeed = newHorizontal.Magnitude,
        steering = state.steering,
        throttle = state.throttle,
        grounded = ground.grounded,
        nearGround = ground.nearGround,
        occupied = occupied,
        velocity = base.AssemblyLinearVelocity,
        position = base.Position,
    })
end

local function ensureSled(player)
    task.defer(function()
        createOrReplaceSled(player)
    end)
end

remoteSet.SledInput.OnServerEvent:Connect(function(player, steeringInput, throttleInput)
    local state = statesByUserId[player.UserId]
    if not state then
        return
    end

    local oldSteering = state.steering
    local oldThrottle = state.throttle

    state.steering = clamp(tonumber(steeringInput) or 0, -1, 1)
    state.throttle = clamp(tonumber(throttleInput) or 0, -1, 1)

    if DEBUG_SLED and (oldSteering ~= state.steering or oldThrottle ~= state.throttle) then
        print(string.format("[SledServerInput] player=%s steering=%.1f throttle=%.1f", player.Name, state.steering, state.throttle))
    end
end)

remoteSet.GoalReachedServer.Event:Connect(function(player)
    local state = statesByUserId[player.UserId]
    if not state then
        return
    end

    state.finished = true
    state.throttle = 0
    state.steering = 0
    print("[Sled] Goal reached")
end)

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function()
        ensureSled(player)
    end)
end)

for _, player in ipairs(Players:GetPlayers()) do
    player.CharacterAdded:Connect(function()
        ensureSled(player)
    end)
    if player.Character then
        ensureSled(player)
    end
end

Players.PlayerRemoving:Connect(function(player)
    local state = statesByUserId[player.UserId]
    if state then
        clearSledState(state)
        statesByUserId[player.UserId] = nil
    end
end)

Workspace:GetAttributeChangedSignal("NuruNuruRollMapReady"):Connect(function()
    if Workspace:GetAttribute("NuruNuruRollMapReady") == true then
        print("[Sled] MapReady received")
        for _, player in ipairs(Players:GetPlayers()) do
            ensureSled(player)
        end
    end
end)

RunService.Heartbeat:Connect(function(dt)
    local clampedDt = clamp(dt, 0, 0.05)
    for userId, state in pairs(statesByUserId) do
        if not state.model or not state.model.Parent then
            statesByUserId[userId] = nil
        else
            updateState(state, clampedDt)
        end
    end
end)

print("[Sled] SledServerController initialized")
