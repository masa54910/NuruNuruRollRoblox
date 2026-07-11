local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local DownhillCourse = require(ReplicatedStorage.Shared.DownhillCourse)

local projectConfig = Config.Project or {}
if projectConfig.OverviewCameraEnabled ~= true then
    return
end

local settings = Config.OverviewCamera or {}

local OVERVIEW_FOV = tonumber(settings.OverviewCameraFieldOfView) or 60
local OVERVIEW_USE_COURSE_BOUNDS = settings.OverviewCameraUseCourseBounds ~= false
local OVERVIEW_PADDING = tonumber(settings.OverviewCameraPadding) or 1.35
local OVERVIEW_PITCH_DEGREES = tonumber(settings.OverviewCameraPitchDegrees) or -55
local OVERVIEW_INITIAL_YAW_DEGREES = tonumber(settings.OverviewCameraInitialYawDegrees) or 0
local OVERVIEW_ROT_SPEED_DEG_PER_SEC = tonumber(settings.OverviewRotationSpeedDegreesPerSecond) or 55
local OVERVIEW_MIN_DISTANCE = tonumber(settings.OverviewCameraMinimumDistance) or 700
local OVERVIEW_MAX_DISTANCE = tonumber(settings.OverviewCameraMaximumDistance) or 5000

local RENDER_BIND_NAME = "NuruNuruOverviewCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local localPlayer = Players.LocalPlayer

local runtime = {
    camera = Workspace.CurrentCamera,
    active = false,
    leftShiftDown = false,
    rightShiftDown = false,
    rotateLeft = false,
    rotateRight = false,
    renderBound = false,
    previous = nil,
    overviewBounds = nil,
    overviewDistance = nil,
    overviewYawDegrees = OVERVIEW_INITIAL_YAW_DEGREES,
    overviewPitchDegrees = OVERVIEW_PITCH_DEGREES,
    loggedBounds = false,
    lastRotateLogDirection = nil,
    characterConnections = {},
}

local function logInfo(message)
    print(message)
end

local function logFail(stage, reason)
    warn(string.format("[OverviewCameraFail] stage=%s reason=%s", tostring(stage), tostring(reason)))
end

local function getCamera()
    runtime.camera = Workspace.CurrentCamera
    return runtime.camera
end

local function toText(v)
    return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z)
end

local function saveCameraState(camera)
    runtime.previous = {
        cameraType = camera.CameraType,
        cameraSubject = camera.CameraSubject,
        cframe = camera.CFrame,
        focus = camera.Focus,
        fieldOfView = camera.FieldOfView,
    }
end

local function restoreCameraState()
    local camera = getCamera()
    local previous = runtime.previous
    if not camera or not previous then
        return
    end

    camera.CameraType = previous.cameraType or Enum.CameraType.Custom
    camera.CameraSubject = previous.cameraSubject
    camera.FieldOfView = previous.fieldOfView or camera.FieldOfView

    if previous.cameraType == Enum.CameraType.Scriptable then
        camera.CFrame = previous.cframe
        camera.Focus = previous.focus
    end
end

local function computeCourseBounds()
    if not OVERVIEW_USE_COURSE_BOUNDS then
        logFail("course_bounds", "OverviewCameraUseCourseBounds=false is not supported in C2")
        return nil
    end

    if not DownhillCourse.ensureCache(10) then
        logFail("course_bounds", "course_cache_not_ready")
        return nil
    end

    local roadCount = DownhillCourse.getRoadCount()
    if roadCount < 1 then
        logFail("course_bounds", "road_parts_not_found")
        return nil
    end

    local minVec = Vector3.new(math.huge, math.huge, math.huge)
    local maxVec = Vector3.new(-math.huge, -math.huge, -math.huge)

    local partCount = 0

    local function includePartBounds(part)
        local size = part.Size
        local cf = part.CFrame

        local x = cf.RightVector * (size.X * 0.5)
        local y = cf.UpVector * (size.Y * 0.5)
        local z = cf.LookVector * (size.Z * 0.5)

        local halfExtents = Vector3.new(
            math.abs(x.X) + math.abs(y.X) + math.abs(z.X),
            math.abs(x.Y) + math.abs(y.Y) + math.abs(z.Y),
            math.abs(x.Z) + math.abs(y.Z) + math.abs(z.Z)
        )

        local pmin = part.Position - halfExtents
        local pmax = part.Position + halfExtents

        minVec = Vector3.new(
            math.min(minVec.X, pmin.X),
            math.min(minVec.Y, pmin.Y),
            math.min(minVec.Z, pmin.Z)
        )
        maxVec = Vector3.new(
            math.max(maxVec.X, pmax.X),
            math.max(maxVec.Y, pmax.Y),
            math.max(maxVec.Z, pmax.Z)
        )
        partCount += 1
    end

    for i = 1, roadCount do
        local road = DownhillCourse.getRoad(i)
        if road and road:IsA("BasePart") then
            includePartBounds(road)
        end
    end

    if partCount < 1 then
        logFail("course_bounds", "road_parts_not_found")
        return nil
    end

    local center = (minVec + maxVec) * 0.5
    local size = maxVec - minVec

    if not runtime.loggedBounds then
        runtime.loggedBounds = true
        logInfo(string.format(
            "[OverviewCourseBounds] partCount=%d center=%s size=%s",
            partCount,
            toText(center),
            toText(size)
        ))
    end

    return {
        center = center,
        size = size,
        partCount = partCount,
    }
end

local function computeOverviewDistance(bounds)
    local horizontalSpan = math.max(bounds.size.X, bounds.size.Z)
    local verticalSpan = bounds.size.Y

    local baseDistance = (horizontalSpan * 0.9) + (verticalSpan * 1.5)

    local camera = getCamera()
    local viewport = camera and camera.ViewportSize or Vector2.new(16, 9)
    local aspect = math.max(viewport.X / math.max(viewport.Y, 1), 0.1)
    local halfFov = math.rad(OVERVIEW_FOV * 0.5)
    local horizontalFov = 2 * math.atan(math.tan(halfFov) * aspect)

    local fitByHeight = (bounds.size.Y * 0.5) / math.tan(math.max(halfFov, math.rad(1)))
    local fitByWidth = (horizontalSpan * 0.5) / math.tan(math.max(horizontalFov * 0.5, math.rad(1)))

    local distance = math.max(baseDistance, fitByHeight, fitByWidth)
    distance *= OVERVIEW_PADDING
    distance = math.clamp(distance, OVERVIEW_MIN_DISTANCE, OVERVIEW_MAX_DISTANCE)
    return distance
end

local function buildDirection(yawDegrees, pitchDegrees)
    local yaw = math.rad(yawDegrees)
    local pitch = math.rad(pitchDegrees)
    return Vector3.new(
        math.cos(pitch) * math.sin(yaw),
        math.sin(pitch),
        math.cos(pitch) * math.cos(yaw)
    ).Unit
end

local function buildOverviewCFrame(center, distance, yawDegrees, pitchDegrees)
    local direction = buildDirection(yawDegrees, pitchDegrees)
    local cameraPosition = center - (direction * distance)
    return CFrame.lookAt(cameraPosition, center, Vector3.yAxis)
end

local function applyOverviewCamera(dt)
    local camera = getCamera()
    if not camera then
        return
    end

    local bounds = runtime.overviewBounds
    local distance = runtime.overviewDistance
    if not bounds or not distance then
        return
    end

    local yawDelta = OVERVIEW_ROT_SPEED_DEG_PER_SEC * (dt or 0)
    if runtime.rotateLeft then
        runtime.overviewYawDegrees -= yawDelta
    end
    if runtime.rotateRight then
        runtime.overviewYawDegrees += yawDelta
    end

    local cframe = buildOverviewCFrame(bounds.center, distance, runtime.overviewYawDegrees, runtime.overviewPitchDegrees)

    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = cframe
    camera.Focus = CFrame.new(bounds.center)
    camera.FieldOfView = OVERVIEW_FOV
end

local function isShiftHeld()
    return runtime.leftShiftDown or runtime.rightShiftDown
end

local function bindRenderStep()
    if runtime.renderBound then
        return
    end
    runtime.renderBound = true

    RunService:BindToRenderStep(RENDER_BIND_NAME, RENDER_PRIORITY, function(dt)
        if runtime.active then
            applyOverviewCamera(dt)
        end
    end)
end

local function unbindRenderStep()
    if not runtime.renderBound then
        return
    end
    runtime.renderBound = false
    RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
end

local function exitOverviewCamera(reason)
    if not runtime.active then
        runtime.leftShiftDown = false
        runtime.rightShiftDown = false
        return
    end

    runtime.active = false
    runtime.leftShiftDown = false
    runtime.rightShiftDown = false
    runtime.rotateLeft = false
    runtime.rotateRight = false
    runtime.overviewBounds = nil
    runtime.overviewDistance = nil
    runtime.overviewYawDegrees = OVERVIEW_INITIAL_YAW_DEGREES
    runtime.overviewPitchDegrees = OVERVIEW_PITCH_DEGREES
    runtime.lastRotateLogDirection = nil

    unbindRenderStep()
    restoreCameraState()

    local camera = getCamera()
    local restoredType = camera and camera.CameraType.Name or "nil"
    local restoredSubject = camera and camera.CameraSubject and camera.CameraSubject:GetFullName() or "nil"
    logInfo(string.format("[OverviewCameraExit] restoredType=%s restoredSubject=%s reason=%s", restoredType, restoredSubject, tostring(reason)))
end

local function enterOverviewCamera(keyName)
    if runtime.active then
        return
    end

    local camera = getCamera()
    if not camera then
        logFail("enter", "current_camera_missing")
        return
    end

    saveCameraState(camera)

    local bounds = computeCourseBounds()
    if not bounds then
        logFail("course_bounds", "road_parts_not_found")
        return
    end

    runtime.overviewBounds = bounds
    runtime.overviewDistance = computeOverviewDistance(bounds)
    runtime.overviewYawDegrees = OVERVIEW_INITIAL_YAW_DEGREES
    runtime.overviewPitchDegrees = OVERVIEW_PITCH_DEGREES
    runtime.rotateLeft = false
    runtime.rotateRight = false
    runtime.active = true

    bindRenderStep()
    applyOverviewCamera(0)

    logInfo(string.format(
        "[OverviewCameraEnter] key=%s center=%s size=%s distance=%.2f yaw=%.1f pitch=%.1f fov=%.1f",
        tostring(keyName),
        toText(bounds.center),
        toText(bounds.size),
        runtime.overviewDistance,
        runtime.overviewYawDegrees,
        runtime.overviewPitchDegrees,
        OVERVIEW_FOV
    ))
end

local function onInputBegan(input, gameProcessedEvent)
    if gameProcessedEvent then
        return
    end

    if UserInputService:GetFocusedTextBox() then
        return
    end

    if input.KeyCode == Enum.KeyCode.LeftShift then
        runtime.leftShiftDown = true
        enterOverviewCamera("LeftShift")
    elseif input.KeyCode == Enum.KeyCode.RightShift then
        runtime.rightShiftDown = true
        enterOverviewCamera("RightShift")
    elseif runtime.active and (input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.A) then
        runtime.rotateLeft = true
        if runtime.lastRotateLogDirection ~= "left" then
            runtime.lastRotateLogDirection = "left"
            logInfo("[OverviewCameraRotate] direction=left")
        end
    elseif runtime.active and (input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.D) then
        runtime.rotateRight = true
        if runtime.lastRotateLogDirection ~= "right" then
            runtime.lastRotateLogDirection = "right"
            logInfo("[OverviewCameraRotate] direction=right")
        end
    end
end

local function onInputEnded(input)
    if input.KeyCode == Enum.KeyCode.LeftShift then
        runtime.leftShiftDown = false
    elseif input.KeyCode == Enum.KeyCode.RightShift then
        runtime.rightShiftDown = false
    elseif input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.A then
        runtime.rotateLeft = false
        if not runtime.rotateRight then
            runtime.lastRotateLogDirection = nil
        end
        return
    elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.D then
        runtime.rotateRight = false
        if not runtime.rotateLeft then
            runtime.lastRotateLogDirection = nil
        end
        return
    else
        return
    end

    if not isShiftHeld() then
        exitOverviewCamera("shift_released")
    end
end

local function disconnectCharacterConnections()
    for _, connection in ipairs(runtime.characterConnections) do
        connection:Disconnect()
    end
    table.clear(runtime.characterConnections)
end

local function bindCharacterLifecycle(character)
    disconnectCharacterConnections()
    local humanoid = character and (character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10))
    if humanoid then
        table.insert(runtime.characterConnections, humanoid.Died:Connect(function()
            exitOverviewCamera("humanoid_died")
        end))
    end
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    runtime.camera = Workspace.CurrentCamera
    if runtime.active then
        applyOverviewCamera(0)
    end
end)

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)
UserInputService.WindowFocusReleased:Connect(function()
    runtime.rotateLeft = false
    runtime.rotateRight = false
    exitOverviewCamera("window_focus_released")
end)

localPlayer.CharacterAdded:Connect(function(character)
    bindCharacterLifecycle(character)
end)

localPlayer.CharacterRemoving:Connect(function()
    exitOverviewCamera("character_removing")
    disconnectCharacterConnections()
end)

script.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
        exitOverviewCamera("script_removed")
        disconnectCharacterConnections()
    end
end)

if localPlayer.Character then
    bindCharacterLifecycle(localPlayer.Character)
end

logInfo("[OverviewCamera] enabled=true mode=hold_shift")
