local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

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

    local legacyLoaded = getLegacySlideScriptsLoaded()
    logInfo(string.format("[RacingIntegration] legacySlideScriptsLoaded=%s", tostring(legacyLoaded)))

    Workspace:SetAttribute(SPAWN_LOCK_ATTRIBUTE, true)
end

task.defer(run)
