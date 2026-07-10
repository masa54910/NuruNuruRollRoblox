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

local settings = Config.DownhillStart or {}
local slideSettings = Config.GravitySlide or {}

local MAP_READY_TIMEOUT = tonumber(settings.MapReadyTimeoutSeconds) or 30
local REQUEST_COOLDOWN = tonumber(settings.StartRequestCooldownSeconds) or 0.75
local MAXIMUM_START_DISTANCE = tonumber(settings.MaximumStartDistance) or 80
local START_IMPULSE_SPEED = tonumber(settings.StartImpulseSpeed) or 10
local WAITING_WALK_SPEED = tonumber(settings.WaitingWalkSpeed) or 0
local WAITING_JUMP_POWER = tonumber(settings.WaitingJumpPower) or 0
local SLIDING_WALK_SPEED = tonumber(settings.SlidingWalkSpeed) or 0
local SLIDING_JUMP_POWER = tonumber(settings.SlidingJumpPower) or 0
local OFF_COURSE_GRACE = tonumber(settings.OffCourseGraceSeconds) or 3
local RECOVERY_RAY_DISTANCE = tonumber(settings.RecoveryRayDistance) or 60
local MAXIMUM_SAFE_SPEED = tonumber(settings.MaximumSafeSpeed) or 220
local RESPAWN_COOLDOWN = tonumber(settings.RespawnCooldownSeconds) or 2

local CHARACTER_DENSITY = tonumber(slideSettings.CharacterDensity) or 0.7
local CHARACTER_FRICTION = tonumber(slideSettings.CharacterFriction) or 0.05
local CHARACTER_ELASTICITY = tonumber(slideSettings.CharacterElasticity) or 0

local startRequest = Remotes.get().DownhillStartRequest

local states = {}
local characterConnections = {}
local playerConnections = {}

local function setPhase(player, phase)
    player:SetAttribute("DownhillPhase", phase)
end

local function waitForMapReady(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    while os.clock() < deadline do
        if Workspace:GetAttribute("NuruNuruRollMapReady") == true then
            return true
        end
        task.wait(0.1)
    end
    return Workspace:GetAttribute("NuruNuruRollMapReady") == true
end

local function getCourseSpawn()
    local mapRoot = Workspace:FindFirstChild("NuruNuruRollMap")
    local startFolder = mapRoot and mapRoot:FindFirstChild("Start")
    local spawn = startFolder and startFolder:FindFirstChild("CourseSpawn")
    if spawn and spawn:IsA("SpawnLocation") then
        return spawn
    end
    return nil
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

local function resolveStartForward(spawn)
    if DownhillCourse.ensureCache(5) then
        local forward = DownhillCourse.getForward(1, 1)
        if forward and forward.Magnitude > 0.001 then
            return forward.Unit
        end
    end

    local look = spawn.CFrame.LookVector
    if look.Magnitude > 0.001 then
        return look.Unit
    end
    return Vector3.new(0, 0, -1)
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

    local state = {
        character = character,
        humanoid = humanoid,
        root = root,
        waiting = false,
        lastRequestAt = 0,
        runId = (player:GetAttribute("DownhillRunId") or 0) + 1,
        offCourseSince = nil,
        lastRespawnAt = 0,
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
        if not waitForMapReady(MAP_READY_TIMEOUT) then
            if states[player] == state then
                setPhase(player, "Unavailable")
                warn(string.format("[DownhillStart] map readiness timeout player=%s", player.Name))
            end
            return
        end

        local spawn = getCourseSpawn()
        if not spawn then
            if states[player] == state then
                setPhase(player, "Unavailable")
                warn("[DownhillStart] CourseSpawn is missing")
            end
            return
        end

        if states[player] ~= state or player.Character ~= character or humanoid.Health <= 0 then
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

        applySlidingPhysicalProperties(character)

        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.Anchored = true

        humanoid.PlatformStand = false
        humanoid.AutoRotate = false
        humanoid.WalkSpeed = WAITING_WALK_SPEED
        humanoid.UseJumpPower = true
        humanoid.JumpPower = WAITING_JUMP_POWER
        humanoid.Sit = true

        state.waiting = true
        setPhase(player, "Waiting")

        print(string.format(
            "[DownhillStart] waiting player=%s distanceToSpawn=%.2f runId=%d",
            player.Name,
            distanceToSpawn,
            state.runId
        ))
    end)
end

local function startRun(player)
    local state = states[player]
    if not state or not state.waiting then
        return
    end

    local now = os.clock()
    if state.lastRequestAt > 0 and now - state.lastRequestAt < REQUEST_COOLDOWN then
        return
    end
    state.lastRequestAt = now

    if Workspace:GetAttribute("NuruNuruRollMapReady") ~= true then
        warn(string.format("[DownhillStart] rejected before map ready player=%s", player.Name))
        return
    end

    local character = state.character
    local humanoid = state.humanoid
    local root = state.root
    local spawn = getCourseSpawn()
    if not spawn or player.Character ~= character or not character.Parent or not root.Parent or humanoid.Health <= 0 then
        return
    end

    local distance = (root.Position - spawn.Position).Magnitude
    if distance > MAXIMUM_START_DISTANCE then
        warn(string.format(
            "[DownhillStart] rejected distance player=%s distance=%.2f max=%.2f",
            player.Name,
            distance,
            MAXIMUM_START_DISTANCE
        ))
        return
    end

    state.waiting = false
    setPhase(player, "Starting")

    humanoid.Sit = false
    humanoid.PlatformStand = false
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = SLIDING_WALK_SPEED
    humanoid.JumpPower = SLIDING_JUMP_POWER

    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = false

    local startedAt = Workspace:GetServerTimeNow()
    player:SetAttribute("DownhillStartedAt", startedAt)
    setPhase(player, "Sliding")

    local forward = resolveStartForward(spawn)
    root:ApplyImpulse(forward * root.AssemblyMass * START_IMPULSE_SPEED)

    local ownerText = "unknown"
    local ok, owner = pcall(function()
        return root:GetNetworkOwner()
    end)
    if ok then
        ownerText = owner and ("client:" .. owner.Name) or "server"
    end

    print(string.format(
        "[DownhillStart] started player=%s runId=%d startedAt=%.3f impulseSpeed=%.2f owner=%s",
        player.Name,
        state.runId,
        startedAt,
        START_IMPULSE_SPEED,
        ownerText
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
    startRun(player)
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

print("[DownhillStart] server start authority enabled")
