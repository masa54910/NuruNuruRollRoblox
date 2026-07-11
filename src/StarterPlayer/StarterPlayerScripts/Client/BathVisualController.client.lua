local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage.Shared.Config)
local projectConfig = Config.Project or {}
local visualConfig = Config.BathVisual or {}

if projectConfig.BathVisualEnabled ~= true then
    return
end

local VERSION = "BATH_DUMMY_V1"
local MODEL_NAME = "NuruNuruBathVisual"
local ASSET_FOLDER_NAME = "NuruNuruVisualAssets"
local TUB_TEMPLATE_NAME = "BathtubTemplate"
local DUMMY_TEMPLATE_NAME = "BathDummyTemplate"

local BATH_DUMMY_ENABLED = projectConfig.BathDummyEnabled == true
local HIDE_ORIGINAL_CHARACTER = projectConfig.HideOriginalCharacter == true
local USE_RENDER_TRACKING = projectConfig.BathVisualUseRenderTracking ~= false
local DEBUG_ENABLED = projectConfig.BathVisualDebugEnabled == true

local BATH_HEIGHT_OFFSET = tonumber(visualConfig.BathHeightOffset) or -1.6
local BATH_FORWARD_OFFSET = tonumber(visualConfig.BathForwardOffset) or 0
local BATH_SIDE_OFFSET = tonumber(visualConfig.BathSideOffset) or 0

local BATH_YAW_OFFSET_DEG = tonumber(visualConfig.BathYawOffsetDegrees) or 0
local BATH_PITCH_OFFSET_DEG = tonumber(visualConfig.BathPitchOffsetDegrees) or 0
local BATH_ROLL_OFFSET_DEG = tonumber(visualConfig.BathRollOffsetDegrees) or 0

local OLD_MAN_HEAD_HEIGHT_OFFSET = tonumber(visualConfig.OldManHeadHeightOffset) or 1.8
local OLD_MAN_TORSO_HEIGHT_OFFSET = tonumber(visualConfig.OldManTorsoHeightOffset) or 0.4
local OLD_MAN_FORWARD_OFFSET = tonumber(visualConfig.OldManForwardOffset) or 0.3
local OLD_MAN_SIDE_OFFSET = tonumber(visualConfig.OldManSideOffset) or 0
local OLD_MAN_ARM_HEIGHT_OFFSET = tonumber(visualConfig.OldManArmHeightOffset) or 1.0
local OLD_MAN_ARM_FORWARD_OFFSET = tonumber(visualConfig.OldManArmForwardOffset) or 0.15

local runtime = {
    character = nil,
    humanoidRootPart = nil,
    visualModel = nil,
    trackingConnection = nil,
    characterDescendantConnection = nil,
    trackingLogged = false,
}

local function logInfo(message)
    if DEBUG_ENABLED then
        print(message)
    end
end

local function getBathOffsetCFrame()
    return CFrame.new(
        BATH_SIDE_OFFSET,
        BATH_HEIGHT_OFFSET,
        -BATH_FORWARD_OFFSET
    )
        * CFrame.Angles(
            math.rad(BATH_PITCH_OFFSET_DEG),
            math.rad(BATH_YAW_OFFSET_DEG),
            math.rad(BATH_ROLL_OFFSET_DEG)
        )
end

local function setPartVisualOnly(part)
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.Massless = true
    part.CastShadow = true
end

local function setModelVisualOnly(model)
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            setPartVisualOnly(desc)
        end
    end
end

local function countBaseParts(instance)
    local count = 0
    for _, desc in ipairs(instance:GetDescendants()) do
        if desc:IsA("BasePart") then
            count += 1
        end
    end
    return count
end

local function destroyOwnedVisualModels()
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model")
            and child:GetAttribute("NuruNuruBathVisual") == true
            and child:GetAttribute("OwnerUserId") == player.UserId then
            child:Destroy()
        end
    end
end

local function createFallbackTub()
    local tub = Instance.new("Model")
    tub.Name = "Tub"

    local function createPart(name, size, cframe)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = cframe
        part.Material = Enum.Material.SmoothPlastic
        part.Color = Color3.fromRGB(227, 241, 249)
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.Parent = tub
        setPartVisualOnly(part)
        return part
    end

    local bottom = createPart("Bottom", Vector3.new(5.5, 0.5, 7), CFrame.new(0, 0, 0))
    createPart("FrontWall", Vector3.new(5.5, 2.2, 0.5), CFrame.new(0, 1.35, -3.25))
    createPart("BackWall", Vector3.new(5.5, 2.2, 0.5), CFrame.new(0, 1.35, 3.25))
    createPart("LeftWall", Vector3.new(0.5, 2.2, 6), CFrame.new(-2.5, 1.35, 0))
    createPart("RightWall", Vector3.new(0.5, 2.2, 6), CFrame.new(2.5, 1.35, 0))

    tub.PrimaryPart = bottom
    return tub
end

local function createFallbackDummy()
    local dummy = Instance.new("Model")
    dummy.Name = "OldManDummy"

    local function createPart(name, size, cframe)
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.CFrame = cframe
        part.Material = Enum.Material.SmoothPlastic
        part.Color = Color3.fromRGB(246, 209, 178)
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.Parent = dummy
        setPartVisualOnly(part)
        return part
    end

    local torsoPos = CFrame.new(OLD_MAN_SIDE_OFFSET, OLD_MAN_TORSO_HEIGHT_OFFSET, -OLD_MAN_FORWARD_OFFSET)
    local torso = createPart("Torso", Vector3.new(2.0, 2.3, 1.2), torsoPos)
    createPart("Head", Vector3.new(1.5, 1.5, 1.5), torsoPos * CFrame.new(0, OLD_MAN_HEAD_HEIGHT_OFFSET, 0))
    createPart(
        "LeftUpperArm",
        Vector3.new(0.7, 1.5, 0.7),
        torsoPos * CFrame.new(-1.35, OLD_MAN_ARM_HEIGHT_OFFSET, -OLD_MAN_ARM_FORWARD_OFFSET) * CFrame.Angles(math.rad(18), 0, math.rad(18))
    )
    createPart(
        "RightUpperArm",
        Vector3.new(0.7, 1.5, 0.7),
        torsoPos * CFrame.new(1.35, OLD_MAN_ARM_HEIGHT_OFFSET, -OLD_MAN_ARM_FORWARD_OFFSET) * CFrame.Angles(math.rad(18), 0, math.rad(-18))
    )
    createPart(
        "LeftHand",
        Vector3.new(0.55, 0.5, 0.55),
        torsoPos * CFrame.new(-1.75, OLD_MAN_ARM_HEIGHT_OFFSET + 0.25, 0.6) * CFrame.Angles(math.rad(10), 0, math.rad(8))
    )
    createPart(
        "RightHand",
        Vector3.new(0.55, 0.5, 0.55),
        torsoPos * CFrame.new(1.75, OLD_MAN_ARM_HEIGHT_OFFSET + 0.25, 0.6) * CFrame.Angles(math.rad(10), 0, math.rad(-8))
    )

    dummy.PrimaryPart = torso
    return dummy
end

local function cloneTemplateModel(assetsFolder, templateName)
    local template = assetsFolder and assetsFolder:FindFirstChild(templateName)
    if template and template:IsA("Model") then
        return template:Clone()
    end
    return nil
end

local function createTubModel(assetsFolder)
    local template = cloneTemplateModel(assetsFolder, TUB_TEMPLATE_NAME)
    if template then
        template.Name = "Tub"
        setModelVisualOnly(template)
        return template, "template"
    end

    return createFallbackTub(), "fallback"
end

local function createDummyModel(assetsFolder)
    if not BATH_DUMMY_ENABLED then
        return nil, "disabled"
    end

    local template = cloneTemplateModel(assetsFolder, DUMMY_TEMPLATE_NAME)
    if template then
        template.Name = "OldManDummy"
        setModelVisualOnly(template)
        return template, "template"
    end

    return createFallbackDummy(), "fallback"
end

local function setCharacterVisibility(character, hidden)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        if hidden then
            humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
        end
    end

    for _, desc in ipairs(character:GetDescendants()) do
        if desc:IsA("BasePart") then
            desc.LocalTransparencyModifier = hidden and 1 or 0
            desc.CastShadow = not hidden
        elseif desc:IsA("Decal") or desc:IsA("Texture") then
            desc.Transparency = hidden and 1 or 0
        elseif desc:IsA("ForceField") then
            desc.Visible = not hidden
        elseif desc:IsA("BillboardGui") then
            desc.Enabled = not hidden
        end
    end

    if runtime.characterDescendantConnection then
        runtime.characterDescendantConnection:Disconnect()
        runtime.characterDescendantConnection = nil
    end

    runtime.characterDescendantConnection = character.DescendantAdded:Connect(function(desc)
        if desc:IsA("BasePart") then
            desc.LocalTransparencyModifier = hidden and 1 or 0
            desc.CastShadow = not hidden
        elseif desc:IsA("Decal") or desc:IsA("Texture") then
            desc.Transparency = hidden and 1 or 0
        elseif desc:IsA("ForceField") then
            desc.Visible = not hidden
        elseif desc:IsA("BillboardGui") then
            desc.Enabled = not hidden
        end
    end)

    local visibleParts = 0
    local visibleAccessories = 0
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.LocalTransparencyModifier < 1 then
            visibleParts += 1
            if descendant.Parent and descendant.Parent:IsA("Accessory") then
                visibleAccessories += 1
            end
        end
    end

    logInfo(string.format(
        "[BathSlideCharacter] hidden=%s visibleCharacterParts=%d visibleAccessories=%d forceFieldVisible=%s",
        tostring(hidden),
        visibleParts,
        visibleAccessories,
        tostring(false)
    ))
end

local function stopTracking()
    if runtime.trackingConnection then
        runtime.trackingConnection:Disconnect()
        runtime.trackingConnection = nil
    end
end

local function startTracking()
    if not runtime.visualModel or not runtime.humanoidRootPart then
        return
    end

    stopTracking()

    local update = function()
        local visualModel = runtime.visualModel
        local rootPart = runtime.humanoidRootPart
        if not visualModel or not visualModel.Parent or not rootPart or not rootPart.Parent then
            return
        end
        visualModel:PivotTo(rootPart.CFrame * getBathOffsetCFrame())
    end

    if USE_RENDER_TRACKING then
        runtime.trackingConnection = RunService.RenderStepped:Connect(update)
    else
        runtime.trackingConnection = RunService.Heartbeat:Connect(update)
    end

    update()

    if not runtime.trackingLogged then
        runtime.trackingLogged = true
        logInfo("[BathSlideTracking] target=HumanoidRootPart usesPhysics=false usesWeld=false")
    end
end

local function createVisualModelForCharacter(character)
    destroyOwnedVisualModels()

    local assetsFolder = ReplicatedStorage:FindFirstChild(ASSET_FOLDER_NAME)
    local tub, tubSource = createTubModel(assetsFolder)
    local dummy, dummySource = createDummyModel(assetsFolder)

    local bathVisual = Instance.new("Model")
    bathVisual.Name = MODEL_NAME
    bathVisual:SetAttribute("NuruNuruBathVisual", true)
    bathVisual:SetAttribute("OwnerUserId", player.UserId)
    bathVisual:SetAttribute("BathVisualVersion", VERSION)

    tub.Parent = bathVisual
    if dummy then
        dummy.Parent = bathVisual
    end

    setModelVisualOnly(bathVisual)
    bathVisual.Parent = workspace

    runtime.visualModel = bathVisual
    runtime.character = character

    local partCount = countBaseParts(bathVisual)
    logInfo(string.format("[BathOldManDummy] source=%s humanoid=false animator=false partCount=%d", dummySource, dummy and countBaseParts(dummy) or 0))
    logInfo(string.format("[BathVisualAsset] tubSource=%s dummySource=%s", tubSource, dummySource))
    logInfo(string.format("[BathVisualCreated] model=%s partCount=%d physical=false", bathVisual.Name, partCount))
end

local function applyToCharacter(character)
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 10)
    if not humanoidRootPart then
        return
    end

    runtime.humanoidRootPart = humanoidRootPart
    logInfo(string.format(
        "[BathVisualCharacter] character=%s rootFound=%s",
        character:GetFullName(),
        tostring(humanoidRootPart ~= nil)
    ))

    createVisualModelForCharacter(character)
    setCharacterVisibility(character, HIDE_ORIGINAL_CHARACTER)
    startTracking()
end

local function cleanupRuntime()
    stopTracking()
    if runtime.characterDescendantConnection then
        runtime.characterDescendantConnection:Disconnect()
        runtime.characterDescendantConnection = nil
    end
    if runtime.visualModel and runtime.visualModel.Parent then
        runtime.visualModel:Destroy()
    end
    runtime.visualModel = nil
    runtime.character = nil
    runtime.humanoidRootPart = nil
end

local function initialize()
    logInfo(string.format("[BathSlideVisual] enabled=true version=%s", VERSION))
    runtime.trackingLogged = false

    player.CharacterAdded:Connect(function(character)
        cleanupRuntime()
        applyToCharacter(character)
    end)

    player.CharacterRemoving:Connect(function()
        cleanupRuntime()
    end)

    if player.Character then
        applyToCharacter(player.Character)
    end
end

initialize()
