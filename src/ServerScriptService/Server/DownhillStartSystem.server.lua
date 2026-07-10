local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local projectConfig = Config.Project or {}
if projectConfig.EnableDownhillStartSystem ~= true then
    return
end

local BUILD_ID = "GATE1_SEAT_INPUT_FIX_V4"

local IS_STUDIO = RunService:IsStudio()
local START_FLOW_LOG_ENABLED = IS_STUDIO and projectConfig.EnableDownhillDebug == true

local settings = Config.DownhillStart or {}
local slideSettings = Config.GravitySlide or {}

local MAP_READY_TIMEOUT = tonumber(settings.MapReadyTimeoutSeconds) or 30
local REQUEST_COOLDOWN = tonumber(settings.StartRequestCooldownSeconds) or 0.75
local MAXIMUM_START_DISTANCE = tonumber(settings.MaximumStartDistance) or 80
local START_IMPULSE_SPEED = tonumber(settings.StartImpulseSpeed) or 10
local START_LAUNCH_SPEED = tonumber(settings.StartLaunchSpeed) or 24
local START_LAUNCH_DOWNWARD_SPEED = tonumber(settings.StartLaunchDownwardSpeed) or -2
local START_FORWARD_OFFSET_STUDS = tonumber(settings.StartForwardOffsetStuds) or 3
local START_LAUNCH_LINEAR_DURATION = tonumber(settings.StartLaunchLinearVelocityDuration) or 0.35
local WAITING_WALK_SPEED = tonumber(settings.WaitingWalkSpeed) or 0
local WAITING_JUMP_POWER = tonumber(settings.WaitingJumpPower) or 0
local SLIDING_WALK_SPEED = tonumber(settings.SlidingWalkSpeed) or 0
local SLIDING_JUMP_POWER = tonumber(settings.SlidingJumpPower) or 0
local OFF_COURSE_GRACE = tonumber(settings.OffCourseGraceSeconds) or 3
local RECOVERY_RAY_DISTANCE = tonumber(settings.RecoveryRayDistance) or 60
local MAXIMUM_SAFE_SPEED = tonumber(settings.MaximumSafeSpeed) or 220
local RESPAWN_COOLDOWN = tonumber(settings.RespawnCooldownSeconds) or 2
local START_MOTION_MIN_SPEED = tonumber(settings.StartMotionMinimumSpeed) or 3
local START_MOTION_RECOVERY_SPEED = tonumber(settings.StartMotionRecoverySpeed) or 18

local CHARACTER_DENSITY = tonumber(slideSettings.CharacterDensity) or 0.7
local CHARACTER_FRICTION = tonumber(slideSettings.CharacterFriction) or 0.05
local CHARACTER_ELASTICITY = tonumber(slideSettings.CharacterElasticity) or 0
local ROAD_FRICTION = tonumber(slideSettings.SlideRoadFriction)
local ROAD_FRICTION_WEIGHT = tonumber(slideSettings.SlideRoadFrictionWeight) or 1

local startRequest = Remotes.get().DownhillStartRequest

local states = {}
local characterConnections = {}
local playerConnections = {}
local roadPhysicalsApplied = false

local WAIT_CONSTRAINT_NAME_PATTERNS = {
    "DownhillWaitRestraint",
    "StartHold",
    "WaitingConstraint",
}

local function logStartFlowServer(message)
    if not START_FLOW_LOG_ENABLED then
        return
    end
    print(message)
end

local function rejectStart(player, stage, reason)
    if not START_FLOW_LOG_ENABLED then
        return
    end
    warn(string.format("[StartServerReject] reason=%s player=%s", tostring(reason), player and player.Name or "unknown"))
    warn(string.format("[StartFlowFail] stage=%s reason=%s", tostring(stage), tostring(reason)))
end

local function formatVector3(vector)
    if not vector then
        return "(nil,nil,nil)"
    end
    return string.format("(%.3f,%.3f,%.3f)", vector.X, vector.Y, vector.Z)
end

local function setPhase(player, phase)
    player:SetAttribute("DownhillPhase", phase)
end

local function isMapAttributeReady()
    return Workspace:GetAttribute("NuruNuruRollMapReady") == true
end

local function getMapRoot()
    return Workspace:FindFirstChild("NuruNuruRollMap")
end

local function getStartFolder()
    local mapRoot = getMapRoot()
    return mapRoot and mapRoot:FindFirstChild("Start")
end

local function getStartPad()
    local startFolder = getStartFolder()
    local startPad = startFolder and startFolder:FindFirstChild("StartPad")
    if startPad and startPad:IsA("BasePart") then
        return startPad
    end
    return nil
end

local function getCourseSpawn()
    local startFolder = getStartFolder()
    local spawn = startFolder and startFolder:FindFirstChild("CourseSpawn")
    if spawn and spawn:IsA("BasePart") then
        return spawn
    end
    return nil
end

local function hasOperationalMapObjects()
    local spawn = getCourseSpawn()
    local startPad = getStartPad()
    local hasCourse = DownhillCourse.ensureCache(1)
    return spawn ~= nil and startPad ~= nil and hasCourse
end

local function isOperationalMapReady()
    if isMapAttributeReady() then
        return true
    end
    return hasOperationalMapObjects()
end

local function waitForOperationalMapReady(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    while os.clock() < deadline do
        if isOperationalMapReady() then
            return true
        end
        task.wait(0.1)
    end
    return isOperationalMapReady()
end

local function disconnectCharacter(player)
    local connection = characterConnections[player]
    if connection then
        connection:Disconnect()
        characterConnections[player] = nil
    end
end

local function applySlidingPhysicalProperties(character)
    local properties = PhysicalProperties.new(
        CHARACTER_DENSITY,
        CHARACTER_FRICTION,
        CHARACTER_ELASTICITY,
        100,
        1
    )

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.CustomPhysicalProperties = properties
        end
    end
end

local function applyRoadSlidePhysicalProperties()
    if roadPhysicalsApplied then
        return
    end

    if not ROAD_FRICTION then
        return
    end

    if not DownhillCourse.ensureCache(5) then
        return
    end

    local applied = 0
    local index = 1
    while true do
        local road = DownhillCourse.getRoad(index)
        if not road then
            break
        end

        if road:IsA("BasePart") then
            local existing = road.CustomPhysicalProperties
            local density = existing and existing.Density or 0.7
            local elasticity = existing and existing.Elasticity or 0
            local elasticityWeight = existing and existing.ElasticityWeight or 1

            road.CustomPhysicalProperties = PhysicalProperties.new(
                density,
                ROAD_FRICTION,
                elasticity,
                ROAD_FRICTION_WEIGHT,
                elasticityWeight
            )
            applied += 1
        end

        index += 1
    end

    roadPhysicalsApplied = true

    logStartFlowServer(string.format(
        "[SlideRoadFriction] appliedParts=%d friction=%.3f frictionWeight=%.3f",
        applied,
        ROAD_FRICTION,
        ROAD_FRICTION_WEIGHT
    ))
end

local function matchesWaitConstraintName(name)
    for _, pattern in ipairs(WAIT_CONSTRAINT_NAME_PATTERNS) do
        if string.find(name, pattern) then
            return true
        end
    end
    return false
end

local function isWaitConstraint(instance)
    if not instance then
        return false
    end

    if instance:GetAttribute("DownhillWaitRestraint") == true then
        return true
    end

    if matchesWaitConstraintName(instance.Name or "") then
        return true
    end

    if instance:IsA("WeldConstraint")
        or instance:IsA("AlignPosition")
        or instance:IsA("AlignOrientation")
        or instance:IsA("LinearVelocity")
        or instance:IsA("VectorForce")
        or instance:IsA("BodyPosition")
        or instance:IsA("BodyVelocity")
        or instance:IsA("BodyGyro") then
        return matchesWaitConstraintName(instance.Name or "")
    end

    return false
end

local function releaseWaitConstraints(character)
    local removed = 0
    for _, descendant in ipairs(character:GetDescendants()) do
        if isWaitConstraint(descendant) then
            descendant:Destroy()
            removed += 1
        end
    end
    return removed
end

local function removeSeatWelds(character)
    local removed = 0
    local names = {}

    for _, descendant in ipairs(character:GetDescendants()) do
        local isSeatWeld = (descendant.Name == "SeatWeld")
            and (descendant:IsA("Weld") or descendant:IsA("WeldConstraint"))

        if isSeatWeld then
            table.insert(names, descendant:GetFullName())
            descendant:Destroy()
            removed += 1
        end
    end

    return removed, names
end

local function unanchorCharacterParts(character)
    local stillAnchored = {}

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = false
        end
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Anchored then
            table.insert(stillAnchored, descendant:GetFullName())
        end
    end

    return #stillAnchored, stillAnchored
end

local function collectAnchoredPartNames(character)
    local names = {}
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Anchored then
            table.insert(names, descendant:GetFullName())
        end
    end
    return names
end

local function countActiveWaitConstraints(character)
    local count = 0
    local names = {}

    for _, descendant in ipairs(character:GetDescendants()) do
        if isWaitConstraint(descendant) then
            count += 1
            table.insert(names, descendant:GetFullName())
        end
    end

    return count, names
end

local function collectLinearVelocityNames(character)
    local names = {}
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("LinearVelocity") then
            table.insert(names, descendant:GetFullName())
        end
    end
    return names
end

local function getSeatInfo(humanoid)
    local seatPart = humanoid and humanoid.SeatPart or nil
    if not seatPart then
        return nil, nil
    end

    return seatPart:GetFullName(), seatPart.ClassName
end

local function resolveStartDirection(spawn, startPad)
    local source = "Fallback"
    local direction = nil

    if DownhillCourse.ensureCache(3) then
        local road1 = DownhillCourse.getRoad(1)
        if road1 then
            local fromSpawn = road1.Position - spawn.Position
            if fromSpawn.Magnitude > 0.1 then
                direction = fromSpawn.Unit
                source = "FirstRoad"
            end
        end

        if not direction then
            local forward = DownhillCourse.getForward(1, 1)
            if forward and forward.Magnitude > 0.001 then
                direction = forward.Unit
                source = "DownhillCourse"
            end
        end
    end

    if not direction and startPad then
        local padLook = startPad.CFrame.LookVector
        if padLook.Magnitude > 0.001 then
            direction = padLook.Unit
            source = "StartPadLook"
        end
    end

    if not direction then
        local spawnLook = spawn.CFrame.LookVector
        if spawnLook.Magnitude > 0.001 then
            direction = spawnLook.Unit
            source = "SpawnLook"
        end
    end

    if not direction or direction.Magnitude <= 0.001 then
        direction = Vector3.new(0, 0, -1)
        source = "Fallback"
    end

    local horizontal = Vector3.new(direction.X, 0, direction.Z)
    if horizontal.Magnitude > 0.001 then
        horizontal = horizontal.Unit
    else
        local spawnLook = spawn.CFrame.LookVector
        horizontal = Vector3.new(spawnLook.X, 0, spawnLook.Z)
        if horizontal.Magnitude <= 0.001 then
            horizontal = Vector3.new(0, 0, -1)
        else
            horizontal = horizontal.Unit
        end
    end

    local launchDirection = (horizontal + Vector3.new(0, -0.15, 0)).Unit
    local dotWithSpawnLook = launchDirection:Dot(spawn.CFrame.LookVector)

    logStartFlowServer(string.format(
        "[StartDirection] source=%s vector=%s dotWithSpawnLook=%.3f",
        source,
        formatVector3(launchDirection),
        dotWithSpawnLook
    ))

    return launchDirection, source
end

local function placeCharacterOnGround(character, root, humanoid, spawn, downhillDirection)
    local horizontal = Vector3.new(downhillDirection.X, 0, downhillDirection.Z)
    if horizontal.Magnitude <= 0.001 then
        horizontal = Vector3.new(0, 0, -1)
    else
        horizontal = horizontal.Unit
    end

    local desiredCenter = spawn.Position + (horizontal * START_FORWARD_OFFSET_STUDS)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.IgnoreWater = true

    local rayOrigin = desiredCenter + Vector3.new(0, 24, 0)
    local rayDirection = Vector3.new(0, -120, 0)
    local result = Workspace:Raycast(rayOrigin, rayDirection, params)

    local groundY = desiredCenter.Y
    local groundPart = nil
    if result and result.Instance and DownhillCourse.isRoadPart(result.Instance) then
        groundY = result.Position.Y
        groundPart = result.Instance:GetFullName()
    elseif result and result.Instance then
        groundY = result.Position.Y
        groundPart = result.Instance:GetFullName()
    end

    local rootHeight = humanoid.HipHeight + (root.Size.Y * 0.5)
    local targetPosition = Vector3.new(desiredCenter.X, groundY + rootHeight + 0.05, desiredCenter.Z)

    character:PivotTo(CFrame.lookAt(targetPosition, targetPosition + horizontal, Vector3.yAxis))

    local heightFromGround = root.Position.Y - groundY

    logStartFlowServer(string.format(
        "[WaitPlacement] groundPart=%s groundY=%.3f rootY=%.3f heightFromGround=%.3f sit=%s seatPart=%s",
        tostring(groundPart),
        groundY,
        root.Position.Y,
        heightFromGround,
        tostring(humanoid.Sit),
        tostring(humanoid.SeatPart)
    ))
end

local function collectActiveSystemNames()
    local active = {}

    if projectConfig.EnableDownhillStartSystem == true then
        table.insert(active, "DownhillStartSystem")
    end
    if projectConfig.EnableGravitySlideController == true then
        table.insert(active, "GravitySlideController")
    end
    if projectConfig.EnableDownhillController == true then
        table.insert(active, "DownhillController")
    end
    if projectConfig.EnableLegacySledSystem == true then
        table.insert(active, "LegacySledSystem")
    end
    if projectConfig.EnableLegacySledInput == true then
        table.insert(active, "LegacySledInput")
    end

    if #active == 0 then
        return "(none)"
    end

    return table.concat(active, ",")
end

local function scheduleStartMotionDiagnostics(player, state, launchDirection)
    local startRoot = state.root
    local startCharacter = state.character
    local startGeneration = state.generation
    local startPosition = startRoot.Position
    local launchRecovered = false

    task.spawn(function()
        task.wait(0.2)

        if states[player] ~= state then
            return
        end
        if state.generation ~= startGeneration then
            return
        end
        if player:GetAttribute("DownhillPhase") ~= "Sliding" then
            return
        end
        if not startRoot.Parent then
            return
        end

        local velocityNow = startRoot.AssemblyLinearVelocity
        local speedNow = velocityNow.Magnitude
        local deltaNow = (startRoot.Position - startPosition).Magnitude

        logStartFlowServer(string.format(
            "[StartMotionCheck] t=0.20 distance=%.3f speed=%.3f sit=%s seatPart=%s rootAnchored=%s",
            deltaNow,
            speedNow,
            tostring(state.humanoid.Sit),
            tostring(state.humanoid.SeatPart),
            tostring(startRoot.Anchored)
        ))

        if speedNow < START_MOTION_MIN_SPEED and not launchRecovered then
            local recoveryVelocity = launchDirection * START_MOTION_RECOVERY_SPEED + Vector3.new(0, START_LAUNCH_DOWNWARD_SPEED, 0)
            startRoot.AssemblyLinearVelocity = recoveryVelocity
            launchRecovered = true
            logStartFlowServer("[StartMotionRecovery] reapplied=true")
        end

        task.wait(0.4)

        if states[player] ~= state then
            return
        end
        if state.generation ~= startGeneration then
            return
        end
        if not startRoot.Parent then
            return
        end

        local finalVelocity = startRoot.AssemblyLinearVelocity
        local finalSpeed = finalVelocity.Magnitude
        local finalDelta = (startRoot.Position - startPosition).Magnitude
        local moved = finalDelta > 1.0

        logStartFlowServer(string.format(
            "[StartMotionCheck] t=0.60 distance=%.3f speed=%.3f sit=%s seatPart=%s rootAnchored=%s",
            finalDelta,
            finalSpeed,
            tostring(state.humanoid.Sit),
            tostring(state.humanoid.SeatPart),
            tostring(startRoot.Anchored)
        ))

        logStartFlowServer(string.format(
            "[StartResult] moved=%s distance=%.3f speed=%.3f phase=%s",
            tostring(moved),
            finalDelta,
            finalSpeed,
            tostring(player:GetAttribute("DownhillPhase"))
        ))

        if not moved then
            local anchoredNames = collectAnchoredPartNames(startCharacter)
            local waitConstraintCount, waitConstraintNames = countActiveWaitConstraints(startCharacter)
            local linearVelocityNames = collectLinearVelocityNames(startCharacter)
            local seatWeldCount, seatWeldNames = removeSeatWelds(startCharacter)

            warn(string.format(
                "[StartMotionFail] sit=%s seatPart=%s humanoidState=%s rootAnchored=%s anchoredParts=%s waitConstraints=%d waitConstraintNames=%s linearVelocities=%s seatWeldRemoved=%d seatWeldNames=%s phase=%s velocity=%s activeSystems=%s",
                tostring(state.humanoid.Sit),
                tostring(state.humanoid.SeatPart),
                tostring(state.humanoid:GetState()),
                tostring(startRoot.Anchored),
                table.concat(anchoredNames, "|"),
                waitConstraintCount,
                table.concat(waitConstraintNames, "|"),
                table.concat(linearVelocityNames, "|"),
                seatWeldCount,
                table.concat(seatWeldNames, "|"),
                tostring(player:GetAttribute("DownhillPhase")),
                formatVector3(startRoot.AssemblyLinearVelocity),
                collectActiveSystemNames()
            ))
        end
    end)
end

local function applyWaitingState(player, state, spawn, startPad)
    local character = state.character
    local humanoid = state.humanoid
    local root = state.root

    if not character.Parent or not root.Parent or humanoid.Health <= 0 then
        return false
    end

    local launchDirection = resolveStartDirection(spawn, startPad)

    applySlidingPhysicalProperties(character)
    placeCharacterOnGround(character, root, humanoid, spawn, launchDirection)

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = true

    humanoid.Sit = false
    humanoid.PlatformStand = false
    humanoid.Jump = false
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = WAITING_WALK_SPEED
    humanoid.UseJumpPower = true
    humanoid.JumpPower = WAITING_JUMP_POWER
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
    humanoid:ChangeState(Enum.HumanoidStateType.Running)

    local seatPath, seatClass = getSeatInfo(humanoid)
    if seatPath then
        warn(string.format("[WaitSeatDetected] seat=%s seatClass=%s", seatPath, tostring(seatClass)))
    end

    logStartFlowServer(string.format(
        "[WaitState] sit=%s seatPart=%s rootAnchored=%s phase=Waiting",
        tostring(humanoid.Sit),
        tostring(humanoid.SeatPart),
        tostring(root.Anchored)
    ))

    state.waiting = true
    state.launchDirection = launchDirection
    state.startCommitted = false
    state.pendingStart = false
    setPhase(player, "Waiting")

    return true
end

local function prepareCharacter(player, character)
    disconnectCharacter(player)

    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not root or not root:IsA("BasePart") then
        warn(string.format("[DownhillStart] missing Humanoid or HumanoidRootPart player=%s", player.Name))
        setPhase(player, "Unavailable")
        return
    end

    local generation = (player:GetAttribute("DownhillGeneration") or 0) + 1
    player:SetAttribute("DownhillGeneration", generation)
    character:SetAttribute("DownhillGeneration", generation)

    local state = {
        character = character,
        humanoid = humanoid,
        root = root,
        waiting = false,
        lastRequestAt = 0,
        runId = (player:GetAttribute("DownhillRunId") or 0) + 1,
        offCourseSince = nil,
        lastRespawnAt = 0,
        generation = generation,
        pendingStart = false,
        launchDirection = Vector3.new(0, 0, -1),
        startCommitted = false,
    }
    states[player] = state

    player:SetAttribute("DownhillRunId", state.runId)
    player:SetAttribute("DownhillStartedAt", 0)
    setPhase(player, "Loading")

    characterConnections[player] = humanoid.Died:Connect(function()
        if states[player] == state then
            state.waiting = false
            setPhase(player, "Dead")
        end
    end)

    task.spawn(function()
        if not waitForOperationalMapReady(MAP_READY_TIMEOUT) then
            if states[player] == state then
                setPhase(player, "Unavailable")
                warn(string.format("[DownhillStart] map readiness timeout player=%s", player.Name))
            end
            return
        end

        applyRoadSlidePhysicalProperties()

        local spawn = getCourseSpawn()
        local startPad = getStartPad()
        if not spawn or not startPad then
            if states[player] == state then
                setPhase(player, "Unavailable")
                warn("[DownhillStart] CourseSpawn or StartPad is missing")
            end
            return
        end

        if states[player] ~= state or state.generation ~= generation then
            return
        end
        if player.Character ~= character or humanoid.Health <= 0 then
            return
        end
        if player:GetAttribute("DownhillPhase") == "Sliding" then
            return
        end

        player.RespawnLocation = spawn

        local distanceToSpawn = (root.Position - spawn.Position).Magnitude
        if distanceToSpawn > MAXIMUM_START_DISTANCE then
            setPhase(player, "Recovering")
            warn(string.format(
                "[DownhillStart] reloading off-spawn character player=%s distance=%.2f",
                player.Name,
                distanceToSpawn
            ))
            player:LoadCharacter()
            return
        end

        local ok = applyWaitingState(player, state, spawn, startPad)
        if not ok then
            return
        end

        print(string.format(
            "[DownhillStart] waiting player=%s distanceToSpawn=%.2f runId=%d",
            player.Name,
            distanceToSpawn,
            state.runId
        ))
    end)
end

local function executeStart(player, options)
    options = options or {}

    local phase = player:GetAttribute("DownhillPhase")
    local mapReady = isOperationalMapReady()

    logStartFlowServer(string.format(
        "[StartReceive] player=%s phase=%s mapReady=%s character=%s root=%s",
        player.Name,
        tostring(phase),
        tostring(mapReady),
        tostring(player.Character ~= nil),
        tostring(states[player] and states[player].root ~= nil)
    ))

    logStartFlowServer(string.format("[StartFlow:3] server received player=%s", player.Name))

    local state = states[player]
    if not state then
        rejectStart(player, 3, "state_missing")
        return
    end

    if not state.waiting then
        rejectStart(player, 3, "not_waiting")
        return
    end

    local now = os.clock()
    if not options.bypassCooldown then
        if state.lastRequestAt > 0 and now - state.lastRequestAt < REQUEST_COOLDOWN then
            rejectStart(player, 3, "cooldown")
            return
        end
        state.lastRequestAt = now
    end

    if not mapReady then
        if not state.pendingStart then
            state.pendingStart = true
            local pendingGeneration = state.generation

            task.spawn(function()
                local ready = waitForOperationalMapReady(MAP_READY_TIMEOUT)
                if not ready then
                    if states[player] == state and state.pendingStart and state.generation == pendingGeneration then
                        state.pendingStart = false
                        rejectStart(player, 3, "map_not_ready_timeout")
                    end
                    return
                end

                if states[player] ~= state then
                    return
                end
                if state.generation ~= pendingGeneration then
                    return
                end
                if not state.pendingStart then
                    return
                end

                state.pendingStart = false
                executeStart(player, { bypassCooldown = true })
            end)
        end

        rejectStart(player, 3, "map_not_ready_pending")
        return
    end

    local character = state.character
    local humanoid = state.humanoid
    local root = state.root
    local spawn = getCourseSpawn()
    local startPad = getStartPad()

    if not spawn then
        rejectStart(player, 3, "spawn_missing")
        return
    end

    if not startPad then
        rejectStart(player, 3, "startpad_missing")
        return
    end

    if player.Character ~= character then
        rejectStart(player, 3, "character_mismatch")
        return
    end

    if not character.Parent then
        rejectStart(player, 3, "character_missing")
        return
    end

    if not root.Parent then
        rejectStart(player, 3, "root_missing")
        return
    end

    if humanoid.Health <= 0 then
        rejectStart(player, 3, "humanoid_dead")
        return
    end

    local distance = (root.Position - spawn.Position).Magnitude
    if distance > MAXIMUM_START_DISTANCE then
        rejectStart(player, 3, "too_far_from_spawn")
        warn(string.format(
            "[DownhillStart] rejected distance player=%s distance=%.2f max=%.2f",
            player.Name,
            distance,
            MAXIMUM_START_DISTANCE
        ))
        return
    end

    logStartFlowServer(string.format("[StartFlow:4] validation passed player=%s", player.Name))

    state.waiting = false
    state.pendingStart = false
    state.startCommitted = true

    setPhase(player, "Starting")

    humanoid.Sit = false
    humanoid.Jump = false
    humanoid.PlatformStand = false
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
    humanoid:ChangeState(Enum.HumanoidStateType.Running)

    local seatWeldRemoved, seatWeldNames = removeSeatWelds(character)
    local releaseRemoved = releaseWaitConstraints(character)
    local anchoredCount, anchoredNames = unanchorCharacterParts(character)
    local activeWaitConstraints, waitConstraintNames = countActiveWaitConstraints(character)

    logStartFlowServer(string.format(
        "[StartRelease] sit=%s seatPart=%s anchoredParts=%d waitConstraints=%d rootAnchored=%s",
        tostring(humanoid.Sit),
        tostring(humanoid.SeatPart),
        anchoredCount,
        activeWaitConstraints,
        tostring(root.Anchored)
    ))

    if anchoredCount > 0 then
        warn(string.format("[DownhillStart] still anchored parts: %s", table.concat(anchoredNames, "|")))
        rejectStart(player, 5, "anchored_parts_remaining")
        state.waiting = true
        setPhase(player, "Waiting")
        root.Anchored = true
        return
    end

    if activeWaitConstraints > 0 then
        warn(string.format("[DownhillStart] active wait constraints remained: %s", table.concat(waitConstraintNames, "|")))
        rejectStart(player, 5, "wait_constraints_remaining")
    end

    if seatWeldRemoved > 0 then
        warn(string.format("[DownhillStart] removed SeatWeld(s): %s", table.concat(seatWeldNames, "|")))
    end

    humanoid.AutoRotate = false
    humanoid.WalkSpeed = SLIDING_WALK_SPEED
    humanoid.JumpPower = SLIDING_JUMP_POWER

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero

    logStartFlowServer(string.format("[StartFlow:5] waiting restraint released player=%s", player.Name))

    local startedAt = Workspace:GetServerTimeNow()
    player:SetAttribute("DownhillStartedAt", startedAt)
    setPhase(player, "Sliding")

    logStartFlowServer(string.format("[StartFlow:6] slide state enabled player=%s", player.Name))

    local launchDirection, directionSource = resolveStartDirection(spawn, startPad)

    local speedBefore = root.AssemblyLinearVelocity.Magnitude
    local launchVelocityValue = (launchDirection * START_LAUNCH_SPEED) + Vector3.new(0, START_LAUNCH_DOWNWARD_SPEED, 0)
    root.AssemblyLinearVelocity = launchVelocityValue

    local launchAttachment = Instance.new("Attachment")
    launchAttachment.Name = "DownhillStartAttachment"
    launchAttachment.Parent = root

    local launchVelocity = Instance.new("LinearVelocity")
    launchVelocity.Name = "DownhillStartLaunch"
    launchVelocity.Attachment0 = launchAttachment
    launchVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    launchVelocity.MaxForce = math.huge
    launchVelocity.VectorVelocity = launchVelocityValue
    launchVelocity.Parent = root

    root:ApplyImpulse(launchDirection * root.AssemblyMass * START_IMPULSE_SPEED)

    task.delay(START_LAUNCH_LINEAR_DURATION, function()
        if launchVelocity and launchVelocity.Parent then
            launchVelocity:Destroy()
        end
        if launchAttachment and launchAttachment.Parent then
            launchAttachment:Destroy()
        end
    end)

    logStartFlowServer(string.format(
        "[StartLaunch] direction=%s directionSource=%s speedBefore=%.3f speed=%.3f linearVelocityCreated=true duration=%.2f velocity=%s",
        formatVector3(launchDirection),
        directionSource,
        speedBefore,
        START_LAUNCH_SPEED,
        START_LAUNCH_LINEAR_DURATION,
        formatVector3(root.AssemblyLinearVelocity)
    ))

    logStartFlowServer(string.format("[StartFlow:7] initial movement applied player=%s", player.Name))

    local canSetOwner = true
    local setOk = pcall(function()
        root:SetNetworkOwner(player)
    end)
    if not setOk then
        canSetOwner = false
    end

    local ownerText = "unknown"
    local ownerOk, owner = pcall(function()
        return root:GetNetworkOwner()
    end)
    if ownerOk then
        ownerText = owner and ("client:" .. owner.Name) or "server"
    end

    logStartFlowServer(string.format("[StartNetwork] canSet=%s owner=%s", tostring(canSetOwner), ownerText))

    scheduleStartMotionDiagnostics(player, state, launchDirection)

    print(string.format(
        "[DownhillStart] started player=%s runId=%d startedAt=%.3f launchSpeed=%.2f",
        player.Name,
        state.runId,
        startedAt,
        START_LAUNCH_SPEED
    ))
end

local function isFiniteNumber(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local recoveryAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
    recoveryAccumulator += dt
    if recoveryAccumulator < 0.25 then
        return
    end
    recoveryAccumulator = 0

    for player, state in pairs(states) do
        if not state.waiting and player:GetAttribute("DownhillPhase") == "Sliding" then
            local root = state.root
            local humanoid = state.humanoid
            if root and root.Parent and humanoid and humanoid.Health > 0 then
                local speed = root.AssemblyLinearVelocity.Magnitude
                local grounded = DownhillCourse.raycastRoad(
                    root.Position + Vector3.new(0, 2, 0),
                    RECOVERY_RAY_DISTANCE
                ) ~= nil

                if grounded and isFiniteNumber(speed) and speed <= MAXIMUM_SAFE_SPEED then
                    state.offCourseSince = nil
                else
                    state.offCourseSince = state.offCourseSince or os.clock()
                    local canRespawn = os.clock() - state.lastRespawnAt >= RESPAWN_COOLDOWN
                    if canRespawn and os.clock() - state.offCourseSince >= OFF_COURSE_GRACE then
                        state.lastRespawnAt = os.clock()
                        setPhase(player, "Recovering")
                        warn(string.format(
                            "[DownhillStart] respawning player=%s grounded=%s speed=%.2f",
                            player.Name,
                            tostring(grounded),
                            speed
                        ))
                        player:LoadCharacter()
                    end
                end
            end
        end
    end
end)

local function setupPlayer(player)
    setPhase(player, "Loading")
    player:SetAttribute("DownhillStartedAt", 0)
    playerConnections[player] = player.CharacterAdded:Connect(function(character)
        prepareCharacter(player, character)
    end)

    if player.Character then
        task.defer(prepareCharacter, player, player.Character)
    end
end

startRequest.OnServerEvent:Connect(function(player)
    executeStart(player)
end)

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
    disconnectCharacter(player)
    local connection = playerConnections[player]
    if connection then
        connection:Disconnect()
        playerConnections[player] = nil
    end
    states[player] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end

print(string.format("[Gate1Build] server=%s", BUILD_ID))
print("[DownhillStart] server start authority enabled")
