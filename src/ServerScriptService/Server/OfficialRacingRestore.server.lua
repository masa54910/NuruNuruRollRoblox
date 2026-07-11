local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local projectConfig = Config.Project or {}
if projectConfig.EnableOfficialRacingRestore ~= true then
    return
end

local MAP_ROOT_NAME = "NuruNuruRollMap"
local MAP_READY_ATTRIBUTE = "NuruNuruRollMapReady"
local SPAWN_LOCK_ATTRIBUTE = "NuruNuruOfficialRacingVehicleRestored"

local SPAWN_FORWARD_OFFSET = 4
local SPAWN_RAY_HEIGHT = 60
local SPAWN_RAY_DISTANCE = 220
local CAR_GROUND_CLEARANCE = 0.75

local state = {
    vehicleModel = nil,
    driverSeat = nil,
}

local function logFail(stage, reason)
    warn(string.format("[RacingRestoreFail] stage=%s reason=%s", tostring(stage), tostring(reason)))
end

local function getMapRoot()
    return Workspace:FindFirstChild(MAP_ROOT_NAME)
end

local function getCourseSpawn(mapRoot)
    local spawn = mapRoot and mapRoot:FindFirstChild("CourseSpawn", true)
    if spawn and spawn:IsA("BasePart") then
        return spawn
    end
    return nil
end

local function waitForCourseSpawn(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    repeat
        local mapRoot = getMapRoot()
        local mapReady = Workspace:GetAttribute(MAP_READY_ATTRIBUTE) == true
        local courseSpawn = getCourseSpawn(mapRoot)
        if mapReady and mapRoot and courseSpawn then
            return mapRoot, courseSpawn
        end
        task.wait(0.2)
    until os.clock() >= deadline

    return nil, nil
end

local function hasRacingShape(model)
    if not model or not model:IsA("Model") then
        return false
    end
    local hasSeat = model:FindFirstChild("DriverSeat", true)
    local hasChassis = model:FindFirstChild("Chassis", true)
    local hasInputs = model:FindFirstChild("Inputs", true)
    return hasSeat ~= nil and (hasChassis ~= nil or hasInputs ~= nil)
end

local function findExistingVehicle()
    for _, child in ipairs(Workspace:GetChildren()) do
        if hasRacingShape(child) then
            return child
        end
    end
    return nil
end

local function getDriverSeat(model)
    local seat = model and model:FindFirstChild("DriverSeat", true)
    if seat and seat:IsA("VehicleSeat") then
        return seat
    end
    return nil
end

local function getControllerFound(model)
    local scriptsFolder = model and model:FindFirstChild("Scripts", true)
    local controller = scriptsFolder and scriptsFolder:FindFirstChild("Controller", true)
    return controller ~= nil
end

local function getSpawnCFrame(mapRoot, courseSpawn)
    local rayOrigin = courseSpawn.Position
        + (courseSpawn.CFrame.LookVector * SPAWN_FORWARD_OFFSET)
        + Vector3.new(0, SPAWN_RAY_HEIGHT, 0)

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include
    rayParams.FilterDescendantsInstances = { mapRoot }
    rayParams.IgnoreWater = true

    local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -SPAWN_RAY_DISTANCE, 0), rayParams)
    if not rayResult then
        return nil, "road_raycast_failed"
    end

    local up = rayResult.Normal.Magnitude > 0.001 and rayResult.Normal.Unit or Vector3.yAxis
    local forward = courseSpawn.CFrame.LookVector - (up * courseSpawn.CFrame.LookVector:Dot(up))
    if forward.Magnitude <= 0.001 then
        forward = Vector3.new(0, 0, -1)
    else
        forward = forward.Unit
    end

    local provisionalPos = rayResult.Position + (up * 3)
    local provisionalCf = CFrame.lookAt(provisionalPos, provisionalPos + forward, up)
    return provisionalCf, nil
end

local function getCarPivotPart(carModel)
    local chassis = carModel and carModel:FindFirstChild("Chassis", true)
    if chassis and chassis:IsA("BasePart") then
        return chassis
    end
    if carModel and carModel.PrimaryPart and carModel.PrimaryPart:IsA("BasePart") then
        return carModel.PrimaryPart
    end
    return nil
end

local function spawnOfficialVehicle(spawnCFrame)
    local carSpawningScript = ServerScriptService:FindFirstChild("CarSpawning")
    if not carSpawningScript then
        return nil, "ServerScriptService.CarSpawning missing"
    end

    local spawnCarModule = carSpawningScript:FindFirstChild("spawnCar")
    if not spawnCarModule or not spawnCarModule:IsA("ModuleScript") then
        return nil, "CarSpawning.spawnCar missing"
    end

    local okRequire, spawnCarOrErr = pcall(require, spawnCarModule)
    if not okRequire or type(spawnCarOrErr) ~= "function" then
        return nil, "CarSpawning.spawnCar require failed"
    end

    local existing = {}
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") then
            existing[child] = true
        end
    end

    local okSpawn, spawnErr = pcall(function()
        spawnCarOrErr(spawnCFrame, nil)
    end)
    if not okSpawn then
        return nil, string.format("spawnCar runtime error: %s", tostring(spawnErr))
    end

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") and not existing[child] and hasRacingShape(child) then
            return child, nil
        end
    end

    local fallback = findExistingVehicle()
    if fallback then
        return fallback, nil
    end

    return nil, "spawned_vehicle_not_found"
end

local function placeVehicleAtSpawn(carModel, mapRoot, courseSpawn)
    local provisionalCf, spawnErr = getSpawnCFrame(mapRoot, courseSpawn)
    if not provisionalCf then
        return false, spawnErr
    end

    carModel:PivotTo(provisionalCf)

    local rayOrigin = provisionalCf.Position + Vector3.new(0, SPAWN_RAY_HEIGHT, 0)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include
    rayParams.FilterDescendantsInstances = { mapRoot }
    rayParams.IgnoreWater = true
    local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -SPAWN_RAY_DISTANCE, 0), rayParams)
    if not rayResult then
        return false, "grounding_raycast_failed"
    end

    local up = rayResult.Normal.Magnitude > 0.001 and rayResult.Normal.Unit or Vector3.yAxis
    local forward = provisionalCf.LookVector - (up * provisionalCf.LookVector:Dot(up))
    if forward.Magnitude <= 0.001 then
        forward = Vector3.new(0, 0, -1)
    else
        forward = forward.Unit
    end

    local extentsY = carModel:GetExtentsSize().Y
    local finalPos = rayResult.Position + (up * ((extentsY * 0.5) + CAR_GROUND_CLEARANCE))
    local finalCf = CFrame.lookAt(finalPos, finalPos + forward, up)
    carModel:PivotTo(finalCf)

    return true, nil
end

local function seatPlayer(player)
    local driverSeat = state.driverSeat
    if not driverSeat or not driverSeat.Parent then
        logFail("seat", "driver_seat_missing")
        return
    end

    local character = player.Character
    if not character then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not hrp then
        return
    end

    hrp.CFrame = driverSeat.CFrame * CFrame.new(0, 3, 0)
    task.wait()
    driverSeat:Sit(humanoid)

    local occupied = false
    local deadline = os.clock() + 1.5
    repeat
        occupied = humanoid.SeatPart == driverSeat and driverSeat.Occupant == humanoid
        if occupied then
            break
        end
        task.wait(0.1)
    until os.clock() >= deadline

    print(string.format(
        "[RacingSeatRestore] player=%s seat=%s occupied=%s",
        player.Name,
        driverSeat:GetFullName(),
        tostring(occupied)
    ))

    if not occupied then
        logFail("seat", string.format("sit_failed player=%s", player.Name))
    end
end

local function connectSeatForPlayer(player)
    player.CharacterAdded:Connect(function()
        task.delay(0.25, function()
            seatPlayer(player)
        end)
    end)

    if player.Character then
        task.delay(0.25, function()
            seatPlayer(player)
        end)
    end
end

local function runRestore()
    local mapRoot, courseSpawn = waitForCourseSpawn(120)
    if not mapRoot or not courseSpawn then
        logFail("vehicle_spawn", "course_spawn_not_found")
        return
    end

    local vehicle = findExistingVehicle()
    local vehicleFound = vehicle ~= nil
    local vehicleSpawned = false

    if not vehicle then
        local spawnCf, spawnErr = getSpawnCFrame(mapRoot, courseSpawn)
        if not spawnCf then
            logFail("vehicle_spawn", spawnErr or "spawn_cf_failed")
            return
        end

        local spawned, err = spawnOfficialVehicle(spawnCf)
        if not spawned then
            logFail("vehicle_spawn", err or "spawn_failed")
            return
        end

        vehicle = spawned
        vehicleSpawned = true
    end

    if not vehicle then
        logFail("vehicle_spawn", "vehicle_not_found")
        return
    end

    local placed, placeErr = placeVehicleAtSpawn(vehicle, mapRoot, courseSpawn)
    if not placed then
        logFail("vehicle_spawn", placeErr or "spawn_place_failed")
        return
    end

    local driverSeat = getDriverSeat(vehicle)
    local controllerFound = getControllerFound(vehicle)
    local driverSeatFound = driverSeat ~= nil

    print(string.format(
        "[RacingVehicleRestore] vehicleFound=%s vehicleSpawned=%s driverSeatFound=%s controllerFound=%s",
        tostring(vehicleFound),
        tostring(vehicleSpawned),
        tostring(driverSeatFound),
        tostring(controllerFound)
    ))

    if not driverSeat then
        logFail("seat", "driver_seat_not_found")
        return
    end

    state.vehicleModel = vehicle
    state.driverSeat = driverSeat

    for _, player in ipairs(Players:GetPlayers()) do
        connectSeatForPlayer(player)
    end

    Players.PlayerAdded:Connect(function(player)
        connectSeatForPlayer(player)
    end)

    Workspace:SetAttribute(SPAWN_LOCK_ATTRIBUTE, true)
    print("[RacingRestore] vehicle=true driverSeat=true occupant=false inputBound=false cameraBound=false")
end

if Workspace:GetAttribute(SPAWN_LOCK_ATTRIBUTE) == true then
    local existingVehicle = findExistingVehicle()
    state.vehicleModel = existingVehicle
    state.driverSeat = getDriverSeat(existingVehicle)
    if state.vehicleModel and state.driverSeat then
        for _, player in ipairs(Players:GetPlayers()) do
            connectSeatForPlayer(player)
        end
        Players.PlayerAdded:Connect(function(player)
            connectSeatForPlayer(player)
        end)
    end
else
    task.defer(runRestore)
end
