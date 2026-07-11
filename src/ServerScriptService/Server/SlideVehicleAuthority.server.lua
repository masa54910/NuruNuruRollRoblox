local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local projectConfig = Config.Project or {}
if projectConfig.EnableProxySlideVehicle ~= true then
    return
end

local settings = Config.ProxySlide or {}

local BUILD_ID = settings.BuildId or "PROXY_SLIDE_V8"
local DEBUG_VISIBLE = settings.ProxySlideDebugVisible == true

local ROOT_SIZE = Vector3.new(
    tonumber(settings.ProxySlideWidth) or 2.2,
    tonumber(settings.ProxySlideThickness) or 0.65,
    tonumber(settings.ProxySlideLength) or 4.8
)

local ROOT_PHYSICS = PhysicalProperties.new(
    tonumber(settings.ProxySlideDensity) or 1,
    tonumber(settings.ProxySlideFriction) or 0.02,
    tonumber(settings.ProxySlideElasticity) or 0,
    tonumber(settings.ProxySlideFrictionWeight) or 100,
    tonumber(settings.ProxySlideElasticityWeight) or 100
)

local GROUP_VEHICLE = "SlideVehicle"
local GROUP_VISUAL = "SlideVisual"

local states = {}

local function ensureCollisionGroup(name)
    local found = false
    for _, group in ipairs(PhysicsService:GetCollisionGroups()) do
        if group.name == name then
            found = true
            break
        end
    end

    if not found then
        pcall(function()
            PhysicsService:RegisterCollisionGroup(name)
        end)
    end
end

local function configureCollisionMatrix()
    ensureCollisionGroup(GROUP_VEHICLE)
    ensureCollisionGroup(GROUP_VISUAL)

    PhysicsService:CollisionGroupSetCollidable(GROUP_VISUAL, GROUP_VISUAL, false)
    PhysicsService:CollisionGroupSetCollidable(GROUP_VISUAL, "Default", false)
    PhysicsService:CollisionGroupSetCollidable(GROUP_VEHICLE, GROUP_VISUAL, false)
    PhysicsService:CollisionGroupSetCollidable(GROUP_VEHICLE, "Default", true)
end

local function setCollisionGroup(part, group)
    if not part then
        return
    end

    local ok = pcall(function()
        part.CollisionGroup = group
    end)

    if not ok then
        pcall(function()
            PhysicsService:SetPartCollisionGroup(part, group)
        end)
    end
end

local function saveAndApplyVisualPhysics(state)
    local character = state.character
    if not character then
        return
    end

    state.savedParts = state.savedParts or {}

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            if descendant ~= state.slideRoot then
                state.savedParts[descendant] = {
                    canCollide = descendant.CanCollide,
                    canTouch = descendant.CanTouch,
                    canQuery = descendant.CanQuery,
                    massless = descendant.Massless,
                    collisionGroup = descendant.CollisionGroup,
                    customPhysicalProperties = descendant.CustomPhysicalProperties,
                }

                descendant.CanCollide = false
                descendant.CanTouch = false
                descendant.CanQuery = false
                descendant.Massless = true
                setCollisionGroup(descendant, GROUP_VISUAL)
            end
        end
    end
end

local function restoreVisualPhysics(state)
    if not state.savedParts then
        return
    end

    for part, snapshot in pairs(state.savedParts) do
        if part and part.Parent then
            part.CanCollide = snapshot.canCollide
            part.CanTouch = snapshot.canTouch
            part.CanQuery = snapshot.canQuery
            part.Massless = snapshot.massless
            setCollisionGroup(part, snapshot.collisionGroup)
            part.CustomPhysicalProperties = snapshot.customPhysicalProperties
        end
    end

    state.savedParts = nil
end

local function getBodyOffset(humanoid)
    local isR6 = humanoid and humanoid.RigType == Enum.HumanoidRigType.R6

    local height = tonumber(settings.ProxyBodyHeightOffset) or 0.8
    local pitch = tonumber(settings.ProxyBodyPitchDegrees) or 90
    local yaw = tonumber(settings.ProxyBodyYawDegrees) or 180
    local roll = tonumber(settings.ProxyBodyRollDegrees) or 0

    if isR6 then
        height = tonumber(settings.ProxyBodyHeightOffsetR6) or height
        pitch = tonumber(settings.ProxyBodyPitchDegreesR6) or pitch
        yaw = tonumber(settings.ProxyBodyYawDegreesR6) or yaw
        roll = tonumber(settings.ProxyBodyRollDegreesR6) or roll
    end

    return CFrame.new(0, height, 0) * CFrame.Angles(math.rad(pitch), math.rad(yaw), math.rad(roll))
end

local function setNetworkOwner(root, player)
    local success = pcall(function()
        root:SetNetworkOwner(player)
    end)

    local ownerText = "unknown"
    local ownerOk, owner = pcall(function()
        return root:GetNetworkOwner()
    end)
    if ownerOk then
        ownerText = owner and owner.Name or "server"
    end

    print(string.format("[ProxySlideNetwork] owner=%s success=%s", ownerText, tostring(success)))
end

local function createSlideRoot(state)
    if state.slideRoot and state.slideRoot.Parent then
        return state.slideRoot
    end

    local character = state.character
    local root = state.humanoidRootPart
    if not character or not root then
        return nil
    end

    local slideRoot = Instance.new("Part")
    slideRoot.Name = "DownhillSlideRoot"
    slideRoot.Size = ROOT_SIZE
    slideRoot.Anchored = false
    slideRoot.CanCollide = true
    slideRoot.CanTouch = true
    slideRoot.CanQuery = true
    slideRoot.CastShadow = false
    slideRoot.Massless = false
    slideRoot.RootPriority = 127
    slideRoot.Transparency = DEBUG_VISIBLE and 0.5 or 1
    slideRoot.Color = Color3.fromRGB(255, 140, 0)
    slideRoot.Material = Enum.Material.SmoothPlastic
    slideRoot.CustomPhysicalProperties = ROOT_PHYSICS
    slideRoot.CFrame = root.CFrame
    setCollisionGroup(slideRoot, GROUP_VEHICLE)
    slideRoot.Parent = character

    state.slideRoot = slideRoot

    print(string.format("[ProxySlideCreated] player=%s root=%s", state.player.Name, slideRoot:GetFullName()))

    return slideRoot
end

local function destroySlideRoot(state)
    if state.bodyWeld then
        state.bodyWeld:Destroy()
        state.bodyWeld = nil
    end

    if state.slideRoot and state.slideRoot.Parent then
        state.slideRoot:Destroy()
    end

    state.slideRoot = nil
end

local function enterSliding(state)
    local humanoid = state.humanoid
    local hrp = state.humanoidRootPart
    if not humanoid or not hrp or humanoid.Health <= 0 then
        return
    end

    local slideRoot = createSlideRoot(state)
    if not slideRoot then
        return
    end

    saveAndApplyVisualPhysics(state)

    local bodyOffset = getBodyOffset(humanoid)
    hrp.CFrame = slideRoot.CFrame * bodyOffset

    if state.bodyWeld then
        state.bodyWeld:Destroy()
        state.bodyWeld = nil
    end

    local bodyWeld = Instance.new("WeldConstraint")
    bodyWeld.Name = "ProxySlideBodyWeld"
    bodyWeld.Part0 = slideRoot
    bodyWeld.Part1 = hrp
    bodyWeld.Parent = slideRoot
    state.bodyWeld = bodyWeld

    slideRoot.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity
    slideRoot.AssemblyAngularVelocity = Vector3.zero

    humanoid.WalkSpeed = 0
    humanoid.UseJumpPower = true
    humanoid.JumpPower = 0
    humanoid.AutoRotate = false
    humanoid.Sit = false
    humanoid.PlatformStand = true

    setNetworkOwner(slideRoot, state.player)

    print(string.format("[ProxySlideWeld] player=%s offsetApplied=true", state.player.Name))
end

local function exitSliding(state)
    restoreVisualPhysics(state)
    destroySlideRoot(state)

    local humanoid = state.humanoid
    if humanoid and humanoid.Parent then
        humanoid.PlatformStand = false
    end
end

local function onPhaseChanged(state)
    if not state.player or not state.player.Parent then
        return
    end

    local phase = state.player:GetAttribute("DownhillPhase")
    if phase == "Sliding" or phase == "Starting" then
        enterSliding(state)
    else
        exitSliding(state)
    end
end

local function disconnectAll(state)
    if state.phaseConn then
        state.phaseConn:Disconnect()
        state.phaseConn = nil
    end

    if state.diedConn then
        state.diedConn:Disconnect()
        state.diedConn = nil
    end

    if state.characterRemovingConn then
        state.characterRemovingConn:Disconnect()
        state.characterRemovingConn = nil
    end
end

local function clearState(player)
    local state = states[player]
    if not state then
        return
    end

    exitSliding(state)
    disconnectAll(state)
    states[player] = nil
end

local function setupCharacter(player, character)
    clearState(player)

    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)

    if not humanoid or not hrp then
        return
    end

    local state = {
        player = player,
        character = character,
        humanoid = humanoid,
        humanoidRootPart = hrp,
        savedParts = nil,
        slideRoot = nil,
        bodyWeld = nil,
    }

    states[player] = state

    state.phaseConn = player:GetAttributeChangedSignal("DownhillPhase"):Connect(function()
        onPhaseChanged(state)
    end)

    state.diedConn = humanoid.Died:Connect(function()
        exitSliding(state)
    end)

    state.characterRemovingConn = player.CharacterRemoving:Connect(function(removingCharacter)
        if removingCharacter == character then
            exitSliding(state)
        end
    end)

    onPhaseChanged(state)
end

local function setupPlayer(player)
    player.CharacterAdded:Connect(function(character)
        setupCharacter(player, character)
    end)

    if player.Character then
        task.defer(setupCharacter, player, player.Character)
    end
end

configureCollisionMatrix()

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
    clearState(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end

print(string.format("[ProxySlideBuild] server=%s", BUILD_ID))
