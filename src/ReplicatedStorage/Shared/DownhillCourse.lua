local Workspace = game:GetService("Workspace")

local DownhillCourse = {}

local MAP_ROOT_NAME = "NuruNuruRollMap"
local COURSE_FOLDER_NAME = "Course"
local DEFAULT_TIMEOUT = 30

local cache = {
    mapRoot = nil,
    courseFolder = nil,
    roads = {},
    indexByPart = {},
}

local function clearCache()
    cache.mapRoot = nil
    cache.courseFolder = nil
    table.clear(cache.roads)
    table.clear(cache.indexByPart)
end

local function extractRoadIndex(name)
    local value = string.match(name or "", "^Road_(%d+)$")
    if not value then
        return nil
    end
    return tonumber(value)
end

local function getRoadNumber(road)
    if not road then
        return nil
    end
    return extractRoadIndex(road.Name)
end

function DownhillCourse.isRoadPart(part)
    if not part or not part:IsA("BasePart") then
        return false
    end

    if extractRoadIndex(part.Name) then
        return true
    end

    return part.Name == "FinishRamp"
end

local function sortRoadParts(courseFolder)
    local roads = {}
    local finishRamp = nil

    for _, child in ipairs(courseFolder:GetChildren()) do
        if child:IsA("BasePart") then
            if getRoadNumber(child) then
                table.insert(roads, child)
            elseif child.Name == "FinishRamp" then
                finishRamp = child
            end
        end
    end

    table.sort(roads, function(a, b)
        local aIndex = getRoadNumber(a)
        local bIndex = getRoadNumber(b)

        if not aIndex or not bIndex then
            return a.Name < b.Name
        end

        return aIndex < bIndex
    end)

    local ordered = {}
    for _, road in ipairs(roads) do
        table.insert(ordered, road)
    end

    if finishRamp then
        table.insert(ordered, finishRamp)
    end

    return ordered
end

function DownhillCourse.buildCache(courseFolder)
    clearCache()

    if not courseFolder or not courseFolder:IsA("Folder") then
        return false
    end

    cache.courseFolder = courseFolder
    cache.mapRoot = courseFolder.Parent
    cache.roads = sortRoadParts(courseFolder)

    for index, part in ipairs(cache.roads) do
        cache.indexByPart[part] = index
    end

    return #cache.roads >= 2
end

function DownhillCourse.waitForCourse(timeoutSeconds)
    local timeout = timeoutSeconds or DEFAULT_TIMEOUT
    local mapRoot = Workspace:WaitForChild(MAP_ROOT_NAME, timeout)
    if not mapRoot then
        return nil, nil
    end

    local courseFolder = mapRoot:WaitForChild(COURSE_FOLDER_NAME, timeout)
    if not courseFolder or not courseFolder:IsA("Folder") then
        return mapRoot, nil
    end

    return mapRoot, courseFolder
end

function DownhillCourse.ensureCache(timeoutSeconds)
    if cache.courseFolder and cache.courseFolder.Parent and #cache.roads > 0 then
        return true
    end

    local _, courseFolder = DownhillCourse.waitForCourse(timeoutSeconds)
    if not courseFolder then
        return false
    end

    return DownhillCourse.buildCache(courseFolder)
end

function DownhillCourse.getCourseFolder()
    return cache.courseFolder
end

function DownhillCourse.getRoadCount()
    return #cache.roads
end

function DownhillCourse.getRoad(index)
    return cache.roads[index]
end

function DownhillCourse.getIndexFromPart(part)
    return cache.indexByPart[part]
end

function DownhillCourse.getNextIndex(index, offset)
    local count = #cache.roads
    if count == 0 then
        return nil
    end

    local step = offset or 1
    return math.clamp(index + step, 1, count)
end

function DownhillCourse.getPreviousIndex(index, offset)
    return DownhillCourse.getNextIndex(index, -(offset or 1))
end

function DownhillCourse.raycastRoad(origin, rayDistance)
    if not cache.courseFolder then
        return nil
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { cache.courseFolder }
    params.IgnoreWater = true

    local direction = Vector3.new(0, -math.abs(rayDistance), 0)
    local result = Workspace:Raycast(origin, direction, params)
    if not result then
        return nil
    end

    if not DownhillCourse.isRoadPart(result.Instance) then
        return nil
    end

    local index = DownhillCourse.getIndexFromPart(result.Instance)
    if not index then
        return nil
    end

    return {
        result = result,
        index = index,
        road = result.Instance,
    }
end

function DownhillCourse.findNearestRoadIndex(position, currentIndex, backRange, forwardRange)
    local count = #cache.roads
    if count == 0 then
        return nil
    end

    local anchor = math.clamp(currentIndex or 1, 1, count)
    local minIndex = math.clamp(anchor - (backRange or 3), 1, count)
    local maxIndex = math.clamp(anchor + (forwardRange or 8), 1, count)

    local bestIndex = nil
    local bestDistance = math.huge

    for index = minIndex, maxIndex do
        local road = cache.roads[index]
        if road then
            local distance = (road.Position - position).Magnitude
            if distance < bestDistance then
                bestDistance = distance
                bestIndex = index
            end
        end
    end

    return bestIndex
end

function DownhillCourse.getForward(index, lookAhead)
    local count = #cache.roads
    if count == 0 then
        return nil
    end

    local currentIndex = math.clamp(index or 1, 1, count)
    local step = math.max(1, lookAhead or 1)
    local nextIndex = math.clamp(currentIndex + step, 1, count)

    local currentRoad = cache.roads[currentIndex]
    local nextRoad = cache.roads[nextIndex]
    if not currentRoad or not nextRoad then
        return nil
    end

    local forward = nextRoad.Position - currentRoad.Position
    if forward.Magnitude <= 0.001 then
        forward = currentRoad.CFrame.LookVector
    end

    if forward.Magnitude <= 0.001 then
        return nil
    end

    return forward.Unit
end

function DownhillCourse.getCurveAngle(index, lookAhead)
    local baseForward = DownhillCourse.getForward(index, 1)
    local aheadForward = DownhillCourse.getForward(index, lookAhead)
    if not baseForward or not aheadForward then
        return 0
    end

    local dotValue = math.clamp(baseForward:Dot(aheadForward), -1, 1)
    return math.deg(math.acos(dotValue))
end

function DownhillCourse.getHalfWidth(index)
    local road = cache.roads[index]
    if not road then
        return 0
    end
    return road.Size.X * 0.5
end

function DownhillCourse.getLateralOffset(position, index, right)
    local road = cache.roads[index]
    if not road then
        return 0
    end

    return (position - road.Position):Dot(right)
end

return DownhillCourse
