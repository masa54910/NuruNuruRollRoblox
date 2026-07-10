-- MapBuilder.server.lua
-- Restored wide street-like downhill course with lotion, decorations, and sea dive.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local MAP_ROOT_NAME = "NuruNuruRollMap"
local EXPECTED_SCRIPT_FULL_NAME = "ServerScriptService.Server.MapBuilder"
local TILE_LENGTH = 36
local TILE_OVERLAP = 10
local LOTION_EXTRA_WIDTH = 7
local WALL_HEIGHT = 9
local WALL_THICKNESS = 4
local WALL_OVERLAP_LENGTH = 12
local MIN_STEP_DROP = 0.18
local MIN_ROAD_NEIGHBOR_DROP = 0.05
local FLAT_ROAD_MAX_ABS_DY = 0.1
local MAX_ROAD_NEIGHBOR_DISTANCE = 90
local MAX_ROAD_TILE_LENGTH = 120
local BUILD_YIELD_EVERY_TILES = 40
local SAFE_REBUILD_WAIT_SECONDS = 0.12
local FLAT_SEGMENT_MAX_ABS_DY = 0.1
local GAP_MAX_DISTANCE = 2
local DEBUG_PATH_MARKER_EVERY_SEGMENTS = 12
local DEBUG_PATH_MARKER_SIZE = Vector3.new(8, 8, 8)
local HEALTH_MAX_START_TO_FIRST_DISTANCE = 160
local HEALTH_MAX_START_TO_FIRST_VERTICAL_DISTANCE = 90
local HEALTH_MIN_BBOX_SIZE = Vector3.new(24, 4, 24)
local HEALTH_MIN_WORLD_Y = -100000
local HEALTH_MAX_TRANSPARENCY = 0.98
local HEALTH_MIN_PART_AXIS = 0.25
local DEBUG_MARKER_SIZE = Vector3.new(28, 28, 28)
local COURSE_START_OFFSET_FROM_SPAWN = Vector3.new(0, -6, -6)
local BASEPLATE_BOTTOM_OFFSET_ABOVE_SPAWN = 750

local isGenerating = false
local hasGenerated = false
local lastBuildDiagnostics = nil
local generateMapCallCount = 0

local function cloneSegment(seg)
    local copy = {}
    for key, value in pairs(seg) do
        copy[key] = value
    end
    return copy
end

local function expandSegments(config)
    local course = config and config.Course
    local source = (course and course.Segments) or {}
    if #source == 0 then
        return {}
    end

    local repeatCount = math.max(1, tonumber(course.RepeatCount) or 1)
    local yawVariationDeg = tonumber(course.YawVariationDeg) or 0
    local lengthVariationRatio = tonumber(course.LengthVariationRatio) or 0
    local curveDensity = math.max(1, math.floor(tonumber(course.CurveDensityMultiplier) or 1))
    local bumpMultiplier = math.max(1, tonumber(course.BumpHeightMultiplier) or 1)

    local expanded = {}
    local baseTotalLength = 0
    for _, seg in ipairs(source) do
        baseTotalLength += tonumber(seg.length) or 0
    end

    for rep = 1, repeatCount do
        local repLengthFactor = 1 + ((((rep - 1) % 3) - 1) * lengthVariationRatio)
        local repYawNudge = (rep % 2 == 0) and yawVariationDeg or -yawVariationDeg

        for i = 1, #source do
            local baseSeg = cloneSegment(source[i])
            local baseLen = math.max(120, math.floor((tonumber(baseSeg.length) or 300) * repLengthFactor + 0.5))

            local targetYaw = tonumber(baseSeg.yawDeg) or 0
            if math.abs(targetYaw) >= 25 then
                targetYaw += repYawNudge
            else
                targetYaw += repYawNudge * 0.35
            end
            targetYaw = math.clamp(targetYaw, -120, 120)

            local targetDownDeg = math.max(10, tonumber(baseSeg.downDeg) or 12)
            local baseBumpHeight = tonumber(baseSeg.bumpHeight) or 0
            local microCount = curveDensity
            local accumulatedYaw = 0

            for micro = 1, microCount do
                local seg = cloneSegment(baseSeg)
                seg.name = string.format("%s_R%02d_M%02d", tostring(baseSeg.name), rep, micro)
                seg.length = math.max(120, math.floor(baseLen / microCount + 0.5))

                local shareYaw = targetYaw / microCount
                local wiggleAmp = math.min(math.max(math.abs(targetYaw) * 0.32, 8), 22)
                local wiggleSign = (micro % 2 == 0) and -1 or 1
                local microYaw = shareYaw + (wiggleSign * wiggleAmp)
                if micro == microCount then
                    microYaw = targetYaw - accumulatedYaw
                end
                accumulatedYaw += microYaw
                seg.yawDeg = math.clamp(microYaw, -120, 120)

                local wave = math.sin((micro / microCount) * math.pi)
                seg.downDeg = math.max(10, targetDownDeg + (wave * 2.5))

                if baseBumpHeight > 0 then
                    local bumpFactor = (rep % 2 == 0) and 1.12 or 0.92
                    local microBump = baseBumpHeight * bumpMultiplier * bumpFactor * (0.7 + (0.5 * wave))
                    seg.bumpHeight = math.max(10, math.floor(microBump + 0.5))
                else
                    seg.bumpHeight = nil
                end

                table.insert(expanded, seg)
            end
        end
    end

    -- Normalize to baseTotalLength * repeatCount so final track length matches requested multiplier.
    local expandedTotalLength = 0
    for _, seg in ipairs(expanded) do
        expandedTotalLength += tonumber(seg.length) or 0
    end

    local targetTotalLength = baseTotalLength * repeatCount
    if expandedTotalLength > 0 and targetTotalLength > 0 then
        local scale = targetTotalLength / expandedTotalLength
        for _, seg in ipairs(expanded) do
            seg.length = math.max(120, math.floor((tonumber(seg.length) or 120) * scale + 0.5))
        end
    end

    return expanded
end

local function ensureFolder(parent, name)
    local folder = parent:FindFirstChild(name)
    if folder and folder:IsA("Folder") then
        return folder
    end
    if folder then
        warn(string.format("[MapBuilder] Replacing non-folder %s at %s", name, parent:GetFullName()))
        folder:Destroy()
    end

    folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function clearChildren(folder)
    for _, child in ipairs(folder:GetChildren()) do
        child:Destroy()
    end
end

local function setMapReadyState(isReady)
    Workspace:SetAttribute("NuruNuruRollMapReady", isReady == true)
end

local function countMapRoots()
    local count = 0
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == MAP_ROOT_NAME then
            count += 1
        end
    end
    return count
end

local function moveBaseplateAboveCourseSpawn(courseSpawn)
    if not courseSpawn or not courseSpawn:IsA("BasePart") then
        return
    end

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("BasePart") and string.lower(child.Name) == "baseplate" then
            local oldPosition = child.Position
            local rotationOnly = child.CFrame - oldPosition
            local targetBottomY = courseSpawn.Position.Y + BASEPLATE_BOTTOM_OFFSET_ABOVE_SPAWN
            local targetCenterY = targetBottomY + (child.Size.Y * 0.5)

            child.Anchored = true
            child.CanCollide = false
            child.CanTouch = false
            child.CanQuery = false
            child.Transparency = 1
            child.CFrame = CFrame.new(oldPosition.X, targetCenterY, oldPosition.Z) * rotationOnly

            print(string.format(
                "[MapBuilder] Baseplate moved above CourseSpawn oldY=%.2f newCenterY=%.2f bottomY=%.2f courseSpawnY=%.2f",
                oldPosition.Y,
                child.Position.Y,
                child.Position.Y - (child.Size.Y * 0.5),
                courseSpawn.Position.Y
            ))
        end
    end
end

local function getScriptDebugId()
    local ok, debugId = pcall(function()
        return script:GetDebugId()
    end)
    return ok and tostring(debugId) or "(unavailable)"
end

local function printRuntimeBootDiagnostics()
    print("[MapBuilder] SCRIPT_FULL_NAME=" .. script:GetFullName())
    print("[MapBuilder] SCRIPT_DEBUG_ID=" .. getScriptDebugId())
    print(string.format("[MapBuilder] BOOT_TIME=%.3f", os.clock()))
    print("[MapBuilder] existing NuruNuruRollMap count=" .. tostring(countMapRoots()))

    local scriptMatches = {}
    for _, inst in ipairs(ServerScriptService:GetDescendants()) do
        local isScriptLike = inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript")
        if isScriptLike and string.find(inst.Name, "MapBuilder") then
            table.insert(scriptMatches, inst:GetFullName())
        end
    end
    table.sort(scriptMatches)

    print("[MapBuilder] MapBuilder script count=" .. tostring(#scriptMatches))
    for i, fullName in ipairs(scriptMatches) do
        print(string.format("[MapBuilder] MapBuilder script[%d]=%s", i, fullName))
    end

    if script:GetFullName() ~= EXPECTED_SCRIPT_FULL_NAME then
        warn(string.format(
            "[MapBuilder] Unexpected script location. expected=%s actual=%s",
            EXPECTED_SCRIPT_FULL_NAME,
            script:GetFullName()
        ))
    end
end

local function countBaseParts(folder)
    if not folder then
        return 0
    end

    local count = 0
    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("BasePart") then
            count += 1
        end
    end
    return count
end

local function gatherBaseParts(folder)
    local parts = {}
    if not folder then
        return parts
    end

    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("BasePart") then
            table.insert(parts, d)
        end
    end

    table.sort(parts, function(a, b)
        local aRoad = string.match(a.Name, "^Road_(%d+)$")
        local bRoad = string.match(b.Name, "^Road_(%d+)$")
        if aRoad and bRoad then
            return tonumber(aRoad) < tonumber(bRoad)
        end
        if aRoad then
            return true
        end
        if bRoad then
            return false
        end
        return a.Name < b.Name
    end)
    return parts
end

local function vecToText(v)
    if not v then
        return "(nil)"
    end
    return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

local function getBoundsFromParts(parts)
    if #parts == 0 then
        return nil
    end

    local minV = Vector3.new(math.huge, math.huge, math.huge)
    local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)

    for _, part in ipairs(parts) do
        local extentsCf = part.ExtentsCFrame
        local half = part.ExtentsSize * 0.5
        local pMin = extentsCf.Position - half
        local pMax = extentsCf.Position + half

        minV = Vector3.new(
            math.min(minV.X, pMin.X),
            math.min(minV.Y, pMin.Y),
            math.min(minV.Z, pMin.Z)
        )
        maxV = Vector3.new(
            math.max(maxV.X, pMax.X),
            math.max(maxV.Y, pMax.Y),
            math.max(maxV.Z, pMax.Z)
        )
    end

    local size = maxV - minV
    local center = minV + (size * 0.5)
    return {
        center = center,
        size = size,
        min = minV,
        max = maxV,
    }
end

local function findFirstCoursePart(parts)
    for _, part in ipairs(parts) do
        if string.find(part.Name, "Road_", 1, true) == 1 then
            return part
        end
    end
    return parts[1]
end

local function getMapChildrenList(mapRoot)
    if not mapRoot then
        return "(none)"
    end

    local names = {}
    for _, child in ipairs(mapRoot:GetChildren()) do
        table.insert(names, child.Name)
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "(empty)"
end

local function translateFolderParts(folder, delta)
    if not folder then
        return
    end
    if delta.Magnitude <= 0.001 then
        return
    end

    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("BasePart") then
            d.CFrame = d.CFrame + delta
        end
    end
end

local function createDebugMarker(parent, name, position, color, size)
    if not parent or not position then
        return nil
    end

    local existing = parent:FindFirstChild(name)
    if existing then
        existing:Destroy()
    end

    local marker = Instance.new("Part")
    marker.Name = name
    marker.Shape = Enum.PartType.Ball
    marker.Size = size or DEBUG_MARKER_SIZE
    marker.CFrame = CFrame.new(position)
    marker.Anchored = true
    marker.CanCollide = false
    marker.Transparency = 0
    marker.Material = Enum.Material.Neon
    marker.Color = color
    marker.TopSurface = Enum.SurfaceType.Smooth
    marker.BottomSurface = Enum.SurfaceType.Smooth
    marker.Parent = parent
    return marker
end

local function collectMapDiagnostics()
    local mapRoot = Workspace:FindFirstChild(MAP_ROOT_NAME)
    local courseFolder = mapRoot and mapRoot:FindFirstChild("Course")
    local lotionFolder = mapRoot and mapRoot:FindFirstChild("Lotion")
    local startFolder = mapRoot and mapRoot:FindFirstChild("Start")
    local goalFolder = mapRoot and mapRoot:FindFirstChild("Goal")
    local goalTrigger = goalFolder and goalFolder:FindFirstChild("GoalTrigger")
    local spawn = mapRoot and mapRoot:FindFirstChild("CourseSpawn", true)
    local startPad = startFolder and startFolder:FindFirstChild("StartPad")

    local startPos = nil
    if spawn and spawn:IsA("BasePart") then
        startPos = spawn.Position
    elseif startPad and startPad:IsA("BasePart") then
        startPos = startPad.Position
    end

    local courseParts = gatherBaseParts(courseFolder)
    local lotionParts = gatherBaseParts(lotionFolder)
    local firstCoursePart = findFirstCoursePart(courseParts)
    local midCoursePart = courseParts[math.max(1, math.floor(#courseParts * 0.5))]
    local bbox = getBoundsFromParts(courseParts)
    local startToFirstDistance = nil
    if startPos and firstCoursePart then
        startToFirstDistance = (startPos - firstCoursePart.Position).Magnitude
    end

    return {
        mapRoot = mapRoot,
        mapChildren = getMapChildrenList(mapRoot),
        courseFolder = courseFolder,
        lotionFolder = lotionFolder,
        startFolder = startFolder,
        goalFolder = goalFolder,
        goalTrigger = goalTrigger,
        spawn = spawn,
        startPos = startPos,
        courseParts = courseParts,
        lotionParts = lotionParts,
        firstCoursePart = firstCoursePart,
        midCoursePart = midCoursePart,
        bbox = bbox,
        startToFirstDistance = startToFirstDistance,
    }
end

local function printDiagnostics(diag)
    print("[MapBuilder][Diag] Workspace mapRoot count:", tostring(countMapRoots()))
    print("[MapBuilder][Diag] Workspace has mapRoot:", tostring(diag.mapRoot ~= nil))
    print("[MapBuilder][Diag] mapRoot parentIsWorkspace:", tostring(diag.mapRoot and diag.mapRoot.Parent == Workspace))
    print("[MapBuilder][Diag] mapRoot children:", diag.mapChildren)
    print(string.format(
        "[MapBuilder][Diag] folders course=%s lotion=%s start=%s goal=%s",
        tostring(diag.courseFolder ~= nil),
        tostring(diag.lotionFolder ~= nil),
        tostring(diag.startFolder ~= nil),
        tostring(diag.goalFolder ~= nil)
    ))

    print(string.format(
        "[MapBuilder][Diag] counts courseParts=%d lotionParts=%d",
        #diag.courseParts,
        #diag.lotionParts
    ))

    local sampleCount = math.min(10, #diag.courseParts)
    for i = 1, sampleCount do
        local part = diag.courseParts[i]
        local parentPath = (part.Parent and part.Parent:GetFullName()) or "(nil)"
        print(string.format(
            "[MapBuilder][Diag] CoursePart[%d] name=%s pos=%s size=%s trans=%.2f anchored=%s canCollide=%s parent=%s",
            i,
            part.Name,
            vecToText(part.Position),
            vecToText(part.Size),
            part.Transparency,
            tostring(part.Anchored),
            tostring(part.CanCollide),
            parentPath
        ))
    end

    if diag.bbox then
        print(string.format(
            "[MapBuilder][Diag] CourseBBox center=%s size=%s min=%s max=%s",
            vecToText(diag.bbox.center),
            vecToText(diag.bbox.size),
            vecToText(diag.bbox.min),
            vecToText(diag.bbox.max)
        ))
    else
        warn("[MapBuilder][Diag] CourseBBox unavailable (no course parts)")
    end

    print("[MapBuilder][Diag] Start position:", vecToText(diag.startPos))
    if diag.firstCoursePart then
        print("[MapBuilder][Diag] First course part position:", vecToText(diag.firstCoursePart.Position))
    end
    print("[MapBuilder][Diag] Start->First distance:", diag.startToFirstDistance and string.format("%.2f", diag.startToFirstDistance) or "(nil)")

    local goalPos = (diag.goalTrigger and diag.goalTrigger:IsA("BasePart")) and diag.goalTrigger.Position or nil
    print("[MapBuilder][Diag] GoalTrigger position:", vecToText(goalPos))
    print("[MapBuilder][Diag] Workspace mapReady attribute:", tostring(Workspace:GetAttribute("NuruNuruRollMapReady")))
end

local function placeDebugMarkers(diag, config)
    local mapRoot = diag.mapRoot
    if not mapRoot then
        return
    end

    local projectConfig = config and config.Project
    local enableStartRedBall = projectConfig and projectConfig.EnableStartRedBall == true

    local startMarkerPos = diag.firstCoursePart and (diag.firstCoursePart.Position + Vector3.new(0, 22, 0))
    local midMarkerPos = diag.midCoursePart and (diag.midCoursePart.Position + Vector3.new(0, 22, 0))
    local goalMarkerPos = (diag.goalTrigger and diag.goalTrigger:IsA("BasePart")) and (diag.goalTrigger.Position + Vector3.new(0, 22, 0)) or nil

    if enableStartRedBall then
        createDebugMarker(mapRoot, "Debug_StartCourseMarker", startMarkerPos, Color3.fromRGB(255, 64, 64))
    else
        local oldStartMarker = mapRoot:FindFirstChild("Debug_StartCourseMarker")
        if oldStartMarker then
            oldStartMarker:Destroy()
        end
    end
    createDebugMarker(mapRoot, "Debug_MidCourseMarker", midMarkerPos, Color3.fromRGB(255, 228, 76))
    createDebugMarker(mapRoot, "Debug_GoalMarker", goalMarkerPos, Color3.fromRGB(82, 255, 130))
end

local function printBuildDiagnostics(buildDiag)
    if not buildDiag then
        warn("[MapBuilder][PathDiag] No build diagnostics were recorded")
        return
    end

    print("--- NuruNuruRoll Map Diagnosis ---")
    print(string.format("[MapBuilder][PathDiag] Total Segments: %d", buildDiag.segmentCount or 0))
    print(string.format("[MapBuilder][PathDiag] Total Length: %.2f", buildDiag.totalLength or 0))
    print(string.format("[MapBuilder][PathDiag] Min Y: %.2f", buildDiag.minY or 0))
    print(string.format("[MapBuilder][PathDiag] Max Y: %.2f", buildDiag.maxY or 0))
    print(string.format("[MapBuilder][PathDiag] Flat Zone Count: %d", buildDiag.flatZoneCount or 0))
    print(string.format("[MapBuilder][PathDiag] Gap Zone Count: %d", buildDiag.gapZoneCount or 0))
    print(string.format("[MapBuilder][PathDiag] Uphill/NonDownhill Count: %d", buildDiag.uphillCount or 0))
    print("--- Diagnosis End ---")
end

local function collectRoadParts(courseParts)
    local roadParts = {}
    for _, part in ipairs(courseParts or {}) do
        local roadIndex = string.match(part.Name, "^Road_(%d+)$")
        if roadIndex then
            table.insert(roadParts, {
                index = tonumber(roadIndex),
                part = part,
            })
        end
    end

    table.sort(roadParts, function(a, b)
        return a.index < b.index
    end)

    return roadParts
end

local function analyzeRoadContinuity(courseParts)
    local roadParts = collectRoadParts(courseParts)
    local diag = {
        roadPartCount = #roadParts,
        flatRoadPartCount = 0,
        consecutiveFlatCount = 0,
        maxConsecutiveFlatCount = 0,
        gapCount = 0,
        uphillCount = 0,
        giantRoadPartCount = 0,
        maxNeighborDistance = 0,
        maxNeighborDistanceIndex = nil,
    }

    print("--- NuruNuruRoll Road Continuity Diagnosis ---")
    print(string.format("[MapBuilder][RoadDiag] roadPartCount=%d", #roadParts))

    for i, item in ipairs(roadParts) do
        local part = item.part
        if part.Size.Z > MAX_ROAD_TILE_LENGTH then
            diag.giantRoadPartCount += 1
            warn(string.format(
                "[MapBuilder][RoadDiag][GIANT] index=%d name=%s pos=%s size=%s",
                item.index,
                part.Name,
                vecToText(part.Position),
                vecToText(part.Size)
            ))
        end

        if i == 1 then
            print(string.format(
                "[MapBuilder][RoadDiag] index=%d name=%s pos=%s size=%s prevDistance=(none) prevDY=(none) down=(start) flat=false gap=false",
                item.index,
                part.Name,
                vecToText(part.Position),
                vecToText(part.Size)
            ))
        else
            local previous = roadParts[i - 1].part
            local distance = (part.Position - previous.Position).Magnitude
            local deltaY = part.Position.Y - previous.Position.Y
            local isFlat = math.abs(deltaY) <= FLAT_ROAD_MAX_ABS_DY
            local isGap = distance > MAX_ROAD_NEIGHBOR_DISTANCE
            local isUphill = deltaY > MIN_ROAD_NEIGHBOR_DROP
            local isDown = deltaY < -MIN_ROAD_NEIGHBOR_DROP

            if distance > diag.maxNeighborDistance then
                diag.maxNeighborDistance = distance
                diag.maxNeighborDistanceIndex = item.index
            end
            if isFlat then
                diag.flatRoadPartCount += 1
                diag.consecutiveFlatCount += 1
                diag.maxConsecutiveFlatCount = math.max(diag.maxConsecutiveFlatCount, diag.consecutiveFlatCount)
            else
                diag.consecutiveFlatCount = 0
            end
            if isGap then
                diag.gapCount += 1
            end
            if isUphill then
                diag.uphillCount += 1
            end

            print(string.format(
                "[MapBuilder][RoadDiag] index=%d name=%s pos=%s size=%s prevDistance=%.2f prevDY=%.2f down=%s flat=%s gap=%s uphill=%s",
                item.index,
                part.Name,
                vecToText(part.Position),
                vecToText(part.Size),
                distance,
                deltaY,
                tostring(isDown),
                tostring(isFlat),
                tostring(isGap),
                tostring(isUphill)
            ))

            if isFlat or isGap or isUphill then
                warn(string.format(
                    "[MapBuilder][RoadDiag][NG] index=%d prev=%s current=%s distance=%.2f dY=%.2f flat=%s gap=%s uphill=%s",
                    item.index,
                    previous.Name,
                    part.Name,
                    distance,
                    deltaY,
                    tostring(isFlat),
                    tostring(isGap),
                    tostring(isUphill)
                ))
            end
        end
    end

    print(string.format(
        "[MapBuilder][RoadDiagSummary] flatRoadPartCount=%d consecutiveFlatCount=%d maxNeighborDistance=%.2f maxNeighborDistanceIndex=%s gapCount=%d uphillCount=%d giantRoadPartCount=%d",
        diag.flatRoadPartCount,
        diag.maxConsecutiveFlatCount,
        diag.maxNeighborDistance,
        tostring(diag.maxNeighborDistanceIndex),
        diag.gapCount,
        diag.uphillCount,
        diag.giantRoadPartCount
    ))
    print("--- Road Continuity Diagnosis End ---")

    return diag
end

local function tryFixCoursePlacement(diag)
    if not diag.mapRoot or not diag.firstCoursePart or not diag.startPos then
        return false
    end

    local delta = Vector3.new(0, 0, 0)
    local needsFix = false
    local reasons = {}

    local firstVerticalDistance = math.huge
    if diag.firstCoursePart and diag.startPos then
        firstVerticalDistance = math.abs(diag.firstCoursePart.Position.Y - diag.startPos.Y)
    end

    if (diag.startToFirstDistance and diag.startToFirstDistance > HEALTH_MAX_START_TO_FIRST_DISTANCE)
        or firstVerticalDistance > HEALTH_MAX_START_TO_FIRST_VERTICAL_DISTANCE then
        local desiredFirst = diag.startPos + COURSE_START_OFFSET_FROM_SPAWN
        delta += (desiredFirst - diag.firstCoursePart.Position)
        needsFix = true
        table.insert(reasons, string.format(
            "startToFirst=%.2f firstVertical=%.2f",
            diag.startToFirstDistance or -1,
            firstVerticalDistance
        ))
    end

    if not needsFix then
        return false
    end

    translateFolderParts(diag.mapRoot:FindFirstChild("Course"), delta)
    translateFolderParts(diag.mapRoot:FindFirstChild("Lotion"), delta)
    translateFolderParts(diag.mapRoot:FindFirstChild("Decorations"), delta)
    translateFolderParts(diag.mapRoot:FindFirstChild("Goal"), delta)

    warn(string.format(
        "[MapBuilder] Applied placement correction delta=%s reasons=%s",
        vecToText(delta),
        table.concat(reasons, ",")
    ))

    return true
end

local function runHealthCheck(config)
    local diag = collectMapDiagnostics()
    printDiagnostics(diag)
    printBuildDiagnostics(lastBuildDiagnostics)
    placeDebugMarkers(diag, config)

    if tryFixCoursePlacement(diag) then
        diag = collectMapDiagnostics()
        print("[MapBuilder][Diag] Re-collected diagnostics after placement correction")
        printDiagnostics(diag)
        placeDebugMarkers(diag, config)
    end

    local roadDiag = analyzeRoadContinuity(diag.courseParts)

    local coursePartsCount = #diag.courseParts
    local lotionPartsCount = #diag.lotionParts
    local spawnExists = diag.spawn ~= nil
    local goalExists = diag.goalTrigger ~= nil
    local mapRootCount = countMapRoots()

    local bbox = diag.bbox
    local bboxTooSmall = (bbox ~= nil)
        and (bbox.size.X < HEALTH_MIN_BBOX_SIZE.X or bbox.size.Y < HEALTH_MIN_BBOX_SIZE.Y or bbox.size.Z < HEALTH_MIN_BBOX_SIZE.Z)

    local firstVerticalDistance = math.huge
    if diag.firstCoursePart and diag.startPos then
        firstVerticalDistance = math.abs(diag.firstCoursePart.Position.Y - diag.startPos.Y)
    end

    local courseTooLow = (bbox ~= nil) and (bbox.min.Y < HEALTH_MIN_WORLD_Y)
    local firstPartTooHighOrLow = firstVerticalDistance > HEALTH_MAX_START_TO_FIRST_VERTICAL_DISTANCE
    local startTooFar = diag.startToFirstDistance ~= nil and diag.startToFirstDistance > HEALTH_MAX_START_TO_FIRST_DISTANCE
    local firstPartInvisible = diag.firstCoursePart ~= nil and diag.firstCoursePart.Transparency >= HEALTH_MAX_TRANSPARENCY
    local flatZoneDetected = lastBuildDiagnostics ~= nil and (lastBuildDiagnostics.flatZoneCount or 0) > 0
    local gapZoneDetected = lastBuildDiagnostics ~= nil and (lastBuildDiagnostics.gapZoneCount or 0) > 0
    local uphillDetected = lastBuildDiagnostics ~= nil and (lastBuildDiagnostics.uphillCount or 0) > 0
    local flatRoadPartDetected = roadDiag.flatRoadPartCount > 0
    local consecutiveFlatDetected = roadDiag.maxConsecutiveFlatCount >= 3
    local roadGapDetected = roadDiag.gapCount > 0 or roadDiag.maxNeighborDistance > MAX_ROAD_NEIGHBOR_DISTANCE
    local roadUphillDetected = roadDiag.uphillCount > 0
    local giantRoadPartDetected = roadDiag.giantRoadPartCount > 0
    local duplicateMapRootDetected = mapRootCount ~= 1

    local hasNearInvisiblePart = false
    local hasTinyPart = false
    for _, part in ipairs(diag.courseParts) do
        if part.Transparency >= HEALTH_MAX_TRANSPARENCY then
            hasNearInvisiblePart = true
        end
        if part.Size.X < HEALTH_MIN_PART_AXIS or part.Size.Y < HEALTH_MIN_PART_AXIS or part.Size.Z < HEALTH_MIN_PART_AXIS then
            hasTinyPart = true
        end
        if hasNearInvisiblePart and hasTinyPart then
            break
        end
    end

    local mapRoot = diag.mapRoot
    local courseFolder = diag.courseFolder
    local lotionFolder = diag.lotionFolder
    local startFolder = diag.startFolder
    local goalFolder = diag.goalFolder

    local ok = (mapRoot ~= nil)
        and (mapRoot.Parent == Workspace)
        and (not duplicateMapRootDetected)
        and (courseFolder ~= nil)
        and (lotionFolder ~= nil)
        and (startFolder ~= nil)
        and (goalFolder ~= nil)
        and (coursePartsCount > 0)
        and (lotionPartsCount > 0)
        and spawnExists
        and goalExists
        and (not bboxTooSmall)
        and (not startTooFar)
        and (not courseTooLow)
        and (not firstPartTooHighOrLow)
        and (not hasNearInvisiblePart)
        and (not hasTinyPart)
        and (not flatZoneDetected)
        and (not gapZoneDetected)
        and (not uphillDetected)
        and (not flatRoadPartDetected)
        and (not consecutiveFlatDetected)
        and (not roadGapDetected)
        and (not roadUphillDetected)
        and (not giantRoadPartDetected)

    if ok then
        print(string.format(
            "[MapBuilder] HealthCheck OK mapRootCount=%d courseParts=%d lotionParts=%d spawn=%s goal=%s bboxSize=%s startDist=%s firstVertical=%s startTooFar=%s firstPartInvisible=%s tinyPart=%s flatRoadPartCount=%d consecutiveFlatCount=%d gapCount=%d uphillCount=%d maxNeighborDistance=%.2f",
            mapRootCount,
            coursePartsCount,
            lotionPartsCount,
            tostring(spawnExists),
            tostring(goalExists),
            bbox and vecToText(bbox.size) or "(nil)",
            diag.startToFirstDistance and string.format("%.2f", diag.startToFirstDistance) or "(nil)",
            firstVerticalDistance < math.huge and string.format("%.2f", firstVerticalDistance) or "(nil)",
            tostring(startTooFar),
            tostring(firstPartInvisible),
            tostring(hasTinyPart),
            roadDiag.flatRoadPartCount,
            roadDiag.maxConsecutiveFlatCount,
            roadDiag.gapCount,
            roadDiag.uphillCount,
            roadDiag.maxNeighborDistance
        ))
    else
        warn(string.format(
            "[MapBuilder] HealthCheck NG map=%s mapRootCount=%d parentWorkspace=%s course=%s lotion=%s start=%s goalFolder=%s courseParts=%d lotionParts=%d spawn=%s goal=%s bboxTooSmall=%s startTooFar=%s firstPartTooHighOrLow=%s firstPartInvisible=%s courseTooLow=%s nearInvisible=%s tinyPart=%s flatRoadPartCount=%d consecutiveFlatCount=%d gapCount=%d uphillCount=%d maxNeighborDistance=%.2f giantRoadPartCount=%d segmentFlat=%s segmentGap=%s segmentUphill=%s",
            tostring(mapRoot ~= nil),
            mapRootCount,
            tostring(mapRoot and mapRoot.Parent == Workspace),
            tostring(courseFolder ~= nil),
            tostring(lotionFolder ~= nil),
            tostring(startFolder ~= nil),
            tostring(goalFolder ~= nil),
            coursePartsCount,
            lotionPartsCount,
            tostring(spawnExists),
            tostring(goalExists),
            tostring(bboxTooSmall),
            tostring(startTooFar),
            tostring(firstPartTooHighOrLow),
            tostring(firstPartInvisible),
            tostring(courseTooLow),
            tostring(hasNearInvisiblePart),
            tostring(hasTinyPart),
            roadDiag.flatRoadPartCount,
            roadDiag.maxConsecutiveFlatCount,
            roadDiag.gapCount,
            roadDiag.uphillCount,
            roadDiag.maxNeighborDistance,
            roadDiag.giantRoadPartCount,
            tostring(flatZoneDetected),
            tostring(gapZoneDetected),
            tostring(uphillDetected)
        ))
    end

    return ok
end

local function safeClearExistingMap()
    local removedCount = 0
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == MAP_ROOT_NAME then
            child:Destroy()
            removedCount += 1
        end
    end

    if removedCount > 0 then
        print(string.format("[MapBuilder][Diag] Removed existing map roots: %d", removedCount))
        task.wait(SAFE_REBUILD_WAIT_SECONDS)
    end
end

local function makePart(parent, name, size, cf, color, material, canCollide, transparency)
    local p = Instance.new("Part")
    p.Name = name
    p.Anchored = true
    p.CanCollide = canCollide ~= false
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    p.Size = size
    p.CFrame = cf
    p.Color = color
    p.Material = material
    p.Transparency = transparency or 0
    p.Parent = parent
    return p
end

local function placeStreetDecoration(decorFolder, tileCf, roadWidth, rnd, tileIndex)
    if tileIndex % 6 ~= 0 then
        return
    end

    local prefabFolder = ServerStorage:FindFirstChild("CreatorStorePrefabs")
    for _, side in ipairs({ -1, 1 }) do
        local edge = roadWidth * 0.5
        local nearX = side * (edge + 18)
        local deepX = side * (edge + 38)

        if prefabFolder and #prefabFolder:GetChildren() > 0 then
            local list = prefabFolder:GetChildren()
            local prefab = list[rnd:NextInteger(1, #list)]:Clone()
            prefab.Name = string.format("Prefab_%04d_%s", tileIndex, side < 0 and "L" or "R")
            prefab.Parent = decorFolder

            local pivot = tileCf * CFrame.new(deepX, -4, 0)
            if prefab:IsA("Model") then
                prefab:PivotTo(pivot)
            elseif prefab:IsA("BasePart") then
                prefab.Anchored = true
                prefab.CanCollide = false
                prefab.CFrame = pivot
            end
        else
            makePart(
                decorFolder,
                string.format("House_%04d_%s", tileIndex, side < 0 and "L" or "R"),
                Vector3.new(rnd:NextNumber(30, 46), rnd:NextNumber(48, 96), rnd:NextNumber(30, 46)),
                tileCf * CFrame.new(deepX, 22, 0),
                Color3.fromRGB(rnd:NextInteger(180, 230), rnd:NextInteger(165, 215), rnd:NextInteger(145, 195)),
                Enum.Material.SmoothPlastic,
                false
            )
        end

        makePart(
            decorFolder,
            string.format("StreetLampPole_%04d_%s", tileIndex, side < 0 and "L" or "R"),
            Vector3.new(2, 20, 2),
            tileCf * CFrame.new(nearX, 10, -14),
            Color3.fromRGB(70, 70, 70),
            Enum.Material.Metal,
            false
        )

        makePart(
            decorFolder,
            string.format("StreetLampHead_%04d_%s", tileIndex, side < 0 and "L" or "R"),
            Vector3.new(4, 2, 4),
            tileCf * CFrame.new(nearX, 20, -14),
            Color3.fromRGB(255, 231, 170),
            Enum.Material.Neon,
            false
        )
    end
end

local function placeTile(courseFolder, lotionFolder, wallFolder, decorFolder, rnd, tileIndex, startPos, endPos, roadWidth, wallCount)
    local vec = endPos - startPos
    local len = vec.Magnitude
    if len < 0.1 then
        return
    end

    local dir = vec.Unit
    local center = startPos + (vec * 0.5)
    local cf = CFrame.lookAt(center, center + dir)
    local tileLen = len + TILE_OVERLAP

    local road = makePart(
        courseFolder,
        string.format("Road_%04d", tileIndex),
        Vector3.new(roadWidth, 8, tileLen),
        cf,
        Color3.fromRGB(128, 128, 124),
        Enum.Material.Cobblestone,
        true
    )
    road.CustomPhysicalProperties = nil

    local lotion = makePart(
        lotionFolder,
        string.format("Lotion_%04d", tileIndex),
        Vector3.new(roadWidth + LOTION_EXTRA_WIDTH, 1.4, tileLen + 8),
        cf * CFrame.new(0, 4.9, 0),
        Color3.fromRGB(190, 235, 247),
        Enum.Material.SmoothPlastic,
        true,
        0.18
    )
    lotion.CustomPhysicalProperties = nil

    local wallLen = tileLen + WALL_OVERLAP_LENGTH
    local wallY = (WALL_HEIGHT * 0.5) + 4
    local wallOffset = (roadWidth * 0.5) + (WALL_THICKNESS * 0.5)

    local leftWall = makePart(
        wallFolder,
        string.format("WallLeft_%04d", tileIndex),
        Vector3.new(WALL_THICKNESS, WALL_HEIGHT, wallLen),
        cf * CFrame.new(-wallOffset, wallY, 0),
        Color3.fromRGB(190, 205, 215),
        Enum.Material.Concrete,
        true
    )
    leftWall.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.35, 0.05, 100, 1)

    local rightWall = makePart(
        wallFolder,
        string.format("WallRight_%04d", tileIndex),
        Vector3.new(WALL_THICKNESS, WALL_HEIGHT, wallLen),
        cf * CFrame.new(wallOffset, wallY, 0),
        Color3.fromRGB(190, 205, 215),
        Enum.Material.Concrete,
        true
    )
    rightWall.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.35, 0.05, 100, 1)

    if wallCount then
        wallCount.left += 1
        wallCount.right += 1
    end

    placeStreetDecoration(decorFolder, cf, roadWidth, rnd, tileIndex)
end

local function buildCourse(config)
    local mapRoot = ensureFolder(Workspace, MAP_ROOT_NAME)
    local courseFolder = ensureFolder(mapRoot, "Course")
    local lotionFolder = ensureFolder(mapRoot, "Lotion")
    local wallFolder = ensureFolder(mapRoot, "CourseWalls")
    local decorFolder = ensureFolder(mapRoot, "Decorations")
    local goalFolder = ensureFolder(mapRoot, "Goal")
    local startFolder = ensureFolder(mapRoot, "Start")
    local debugFolder = ensureFolder(mapRoot, "Debug")

    clearChildren(courseFolder)
    clearChildren(lotionFolder)
    clearChildren(wallFolder)
    clearChildren(decorFolder)
    clearChildren(goalFolder)
    clearChildren(startFolder)
    clearChildren(debugFolder)

    local segments = expandSegments(config)
    local startHeight = (config and config.Course and config.Course.StartHeight) or 320
    local finalWidth = (#segments > 0 and segments[#segments].width) or 128

    local startPadCf = CFrame.new(0, startHeight + 6, 24)
    local startPad = makePart(
        startFolder,
        "StartPad",
        Vector3.new(finalWidth, 8, 76),
        startPadCf,
        Color3.fromRGB(220, 220, 220),
        Enum.Material.Concrete,
        false,
        0.85
    )
    startPad.CanTouch = false

    local spawn = Instance.new("SpawnLocation")
    spawn.Name = "CourseSpawn"
    spawn.Anchored = true
    spawn.Neutral = true
    spawn.Size = Vector3.new(12, 1, 12)
    spawn.Transparency = 1
    spawn.Color = Color3.fromRGB(79, 255, 131)
    spawn.CFrame = startPadCf * CFrame.new(0, 4, -8)
    spawn.CanCollide = false
    spawn.CanTouch = false
    spawn.Parent = startFolder
    moveBaseplateAboveCourseSpawn(spawn)

    local rnd = Random.new(20260709)
    local pos = spawn.Position + COURSE_START_OFFSET_FROM_SPAWN
    local yawDeg = 0
    local lastDir = Vector3.new(0, 0, -1)

    local tileIndex = 0
    local humpCount = 0
    local curveLeftCount = 0
    local curveRightCount = 0
    local sCurveCount = 0
    local hairpinCount = 0
    local totalLength = 0
    local pathDiag = {
        segmentCount = #segments,
        totalLength = 0,
        minY = pos.Y,
        maxY = pos.Y,
        flatZoneCount = 0,
        gapZoneCount = 0,
        uphillCount = 0,
    }
    local wallCount = {
        left = 0,
        right = 0,
    }
    local previousSegmentEnd = nil

    for segIndex, seg in ipairs(segments) do
        local segmentStart = pos
        if previousSegmentEnd then
            local gapDistance = (segmentStart - previousSegmentEnd).Magnitude
            if gapDistance > GAP_MAX_DISTANCE then
                pathDiag.gapZoneCount += 1
                warn(string.format(
                    "[MapBuilder][Gap] seg=%d name=%s distance=%.2f prevEnd=%s start=%s",
                    segIndex,
                    tostring(seg.name),
                    gapDistance,
                    vecToText(previousSegmentEnd),
                    vecToText(segmentStart)
                ))
                createDebugMarker(
                    debugFolder,
                    string.format("Debug_Gap_%04d", segIndex),
                    segmentStart + Vector3.new(0, 12, 0),
                    Color3.fromRGB(255, 220, 0),
                    DEBUG_PATH_MARKER_SIZE
                )
            end
        end

        local segName = tostring(seg.name or "")
        if string.find(segName, "SLeft") or string.find(segName, "SRight") then
            sCurveCount += 1
        end

        local segYaw = tonumber(seg.yawDeg) or 0
        if segYaw >= 12 then
            curveRightCount += 1
        elseif segYaw <= -12 then
            curveLeftCount += 1
        end
        if math.abs(segYaw) >= 70 then
            hairpinCount += 1
        end

        local steps = math.max(4, math.floor(seg.length / TILE_LENGTH))
        local stepLen = seg.length / steps
        local yawStart = yawDeg
        local yawEnd = yawDeg + seg.yawDeg
        local baseDropTotal = math.tan(math.rad(seg.downDeg)) * seg.length
        local bumpHeight = seg.bumpHeight or 0
        if bumpHeight > 0 then
            humpCount += 1
        end

        local stepWeights = table.create(steps)
        local weightSum = 0
        for step = 1, steps do
            local phase = (step - 0.5) / steps
            local wave = math.sin(phase * math.pi * 2)
            local bumpWeight = bumpHeight * 0.015
            local weight = 1 + (wave * bumpWeight)
            weight = math.max(0.2, weight)
            stepWeights[step] = weight
            weightSum += weight
        end
        if weightSum <= 0 then
            weightSum = steps
            for step = 1, steps do
                stepWeights[step] = 1
            end
        end

        for step = 1, steps do
            local yawMidDeg = yawStart + ((yawEnd - yawStart) * ((step - 0.5) / steps))
            local yawRad = math.rad(yawMidDeg)

            local horizontalDir = Vector3.new(math.sin(yawRad), 0, -math.cos(yawRad)).Unit
            local nextX = pos.X + (horizontalDir.X * stepLen)
            local nextZ = pos.Z + (horizontalDir.Z * stepLen)

            local stepDrop = (baseDropTotal * (stepWeights[step] / weightSum))
            stepDrop = math.max(MIN_STEP_DROP, stepDrop)
            local nextY = pos.Y - stepDrop

            local nextPos = Vector3.new(nextX, nextY, nextZ)
            local stepDir = (nextPos - pos).Magnitude > 0 and (nextPos - pos).Unit or lastDir
            tileIndex += 1
            placeTile(courseFolder, lotionFolder, wallFolder, decorFolder, rnd, tileIndex, pos, nextPos, seg.width, wallCount)
            totalLength += stepLen
            pathDiag.totalLength += stepLen
            pathDiag.minY = math.min(pathDiag.minY, nextPos.Y)
            pathDiag.maxY = math.max(pathDiag.maxY, nextPos.Y)
            lastDir = stepDir
            pos = nextPos

            if tileIndex % BUILD_YIELD_EVERY_TILES == 0 then
                task.wait()
            end
        end

        yawDeg = yawEnd

        local segmentEnd = pos
        local horizontalDistance = Vector3.new(
            segmentEnd.X - segmentStart.X,
            0,
            segmentEnd.Z - segmentStart.Z
        ).Magnitude
        local deltaY = segmentEnd.Y - segmentStart.Y
        local slope = horizontalDistance > 0 and (deltaY / horizontalDistance) or 0
        local status = "OK"
        if math.abs(deltaY) < FLAT_SEGMENT_MAX_ABS_DY then
            pathDiag.flatZoneCount += 1
            status = "FLAT"
        end
        if deltaY >= -FLAT_SEGMENT_MAX_ABS_DY then
            pathDiag.uphillCount += 1
            if status == "OK" then
                status = "NON_DOWNHILL"
            end
        end

        print(string.format(
            "[MapBuilder][SegmentY] seg=%d/%d name=%s startY=%.2f endY=%.2f dY=%.2f horiz=%.2f slope=%.4f start=%s end=%s status=%s",
            segIndex,
            #segments,
            tostring(seg.name),
            segmentStart.Y,
            segmentEnd.Y,
            deltaY,
            horizontalDistance,
            slope,
            vecToText(segmentStart),
            vecToText(segmentEnd),
            status
        ))

        if status ~= "OK" then
            warn(string.format(
                "[WARNING] Flat/NonDownhill Zone Detected: seg=%d -> %d dY=%.2f",
                math.max(1, tileIndex - steps + 1),
                tileIndex,
                deltaY
            ))
            createDebugMarker(
                debugFolder,
                string.format("Debug_Flat_%04d", segIndex),
                segmentEnd + Vector3.new(0, 12, 0),
                Color3.fromRGB(255, 56, 56),
                DEBUG_PATH_MARKER_SIZE
            )
        elseif segIndex % DEBUG_PATH_MARKER_EVERY_SEGMENTS == 0 then
            createDebugMarker(
                debugFolder,
                string.format("Debug_Downhill_%04d", segIndex),
                segmentEnd + Vector3.new(0, 12, 0),
                Color3.fromRGB(68, 255, 118),
                DEBUG_PATH_MARKER_SIZE
            )
        end

        previousSegmentEnd = segmentEnd
    end

    lastBuildDiagnostics = pathDiag

    local finishCenter = pos + (lastDir * 90) + Vector3.new(0, -10, 0)
    local finishCf = CFrame.lookAt(finishCenter, finishCenter + lastDir)

    local finishRamp = makePart(
        courseFolder,
        "FinishRamp",
        Vector3.new(finalWidth + 12, 8, 180),
        finishCf,
        Color3.fromRGB(128, 128, 124),
        Enum.Material.Cobblestone,
        true
    )
    finishRamp.CustomPhysicalProperties = nil

    local finishLotion = makePart(
        lotionFolder,
        "FinishLotion",
        Vector3.new(finalWidth + LOTION_EXTRA_WIDTH + 2, 1.4, 188),
        finishCf * CFrame.new(0, 4.9, 0),
        Color3.fromRGB(190, 235, 247),
        Enum.Material.SmoothPlastic,
        true,
        0.18
    )
    finishLotion.CustomPhysicalProperties = nil

    local seaCenter = finishCenter + (lastDir * 260) + Vector3.new(0, -42, 0)
    makePart(
        courseFolder,
        "Sea",
        Vector3.new(2200, 16, 2200),
        CFrame.new(seaCenter),
        Color3.fromRGB(70, 140, 204),
        Enum.Material.Water,
        false
    )

    local goal = makePart(
        goalFolder,
        "GoalTrigger",
        Vector3.new(finalWidth + 12, 56, 14),
        CFrame.new(finishCenter + (lastDir * 120) + Vector3.new(0, 24, 0)),
        Color3.fromRGB(255, 217, 61),
        Enum.Material.Neon,
        true,
        0.45
    )
    goal.CanTouch = true

    print(string.format("[CourseWall] Left walls: %d", wallCount.left))
    print(string.format("[CourseWall] Right walls: %d", wallCount.right))

    print(string.format(
        "[MapBuilder] length=%.0f curves(L/R)=%d/%d sCurves=%d hairpins=%d humps=%d minStepDrop=%.2f",
        totalLength,
        curveLeftCount,
        curveRightCount,
        sCurveCount,
        hairpinCount,
        humpCount,
        MIN_STEP_DROP
    ))
end

local function generateMapOnce(config)
    generateMapCallCount += 1
    print(string.format("[MapBuilder] generateMap called count=%d", generateMapCallCount))
    print("[MapBuilder] existing NuruNuruRollMap count=" .. tostring(countMapRoots()))
    setMapReadyState(false)
    lastBuildDiagnostics = nil
    safeClearExistingMap()
    task.wait(0.03)
    buildCourse(config)
    return runHealthCheck(config)
end

local function rebuildMapInternal(reason)
    if isGenerating then
        warn("[MapBuilder] Rebuild skipped because generation is already running")
        return false
    end

    isGenerating = true
    local ok, buildError = pcall(function()
        local config = require(ReplicatedStorage.Shared.Config)
        local healthOk = generateMapOnce(config)

        if not healthOk then
            warn("[MapBuilder] HealthCheck failed. Retrying map generation...")
            healthOk = generateMapOnce(config)
        end

        if not healthOk then
            error("Map generation failed after retry")
        end
    end)

    isGenerating = false

    if ok then
        hasGenerated = true
        setMapReadyState(true)
        print("[MapBuilder][Diag] Workspace mapReady attribute after success:", tostring(Workspace:GetAttribute("NuruNuruRollMapReady")))
        print("[NuruNuruRoll] Course generated")
        if reason then
            print("[MapBuilder] Rebuild reason:", reason)
        end
        return true
    end

    setMapReadyState(false)
    warn("[NuruNuruRoll] MapBuilder failed:", buildError)
    return false
end

printRuntimeBootDiagnostics()

local shouldRunBuilder = script:GetFullName() == EXPECTED_SCRIPT_FULL_NAME
local scriptDebugId = getScriptDebugId()
if shouldRunBuilder and _G.NuruNuruRollMapBuilderRunner ~= nil then
    shouldRunBuilder = false
    warn(string.format(
        "[MapBuilder] Duplicate active MapBuilder detected. current=%s existingRunner=%s. This script will not generate.",
        scriptDebugId,
        tostring(_G.NuruNuruRollMapBuilderRunner)
    ))
elseif shouldRunBuilder then
    _G.NuruNuruRollMapBuilderRunner = scriptDebugId
end

if shouldRunBuilder then
    print("[NuruNuruRoll] MapBuilder started")
    setMapReadyState(false)

    if not hasGenerated then
        rebuildMapInternal("ServerStartup")
    end

    _G.RebuildNuruNuruRollMap = function()
        return rebuildMapInternal("ManualRebuildCommand")
    end
else
    warn("[MapBuilder] MapBuilder startup skipped for this script instance")
end
