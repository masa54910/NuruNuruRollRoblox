local SlideVehicleMath = {}

function SlideVehicleMath.safeUnit(vector, fallback)
    if not vector then
        return fallback
    end

    if vector.Magnitude <= 0.001 then
        return fallback
    end

    return vector.Unit
end

function SlideVehicleMath.projectOnPlane(vector, normal)
    if not vector or not normal then
        return nil
    end

    local projected = vector - (normal * vector:Dot(normal))
    return projected
end

function SlideVehicleMath.projectDirectionOnPlane(direction, normal, fallback)
    local projected = SlideVehicleMath.projectOnPlane(direction, normal)
    if not projected or projected.Magnitude <= 0.001 then
        return fallback
    end

    return projected.Unit
end

function SlideVehicleMath.slopeAcceleration(surfaceNormal, gravityMagnitude)
    local gravity = Vector3.new(0, -(gravityMagnitude or workspace.Gravity), 0)
    return gravity - (surfaceNormal * gravity:Dot(surfaceNormal))
end

function SlideVehicleMath.rotateHeadingOnSurface(currentHeading, surfaceNormal, turnRadians)
    local rotation = CFrame.fromAxisAngle(surfaceNormal, turnRadians)
    local rotated = rotation:VectorToWorldSpace(currentHeading)
    return SlideVehicleMath.projectDirectionOnPlane(rotated, surfaceNormal, currentHeading)
end

function SlideVehicleMath.reflectTangentVelocity(tangentVelocity, surfaceNormal, wallNormal)
    local wallNormalOnSurface = SlideVehicleMath.projectOnPlane(wallNormal, surfaceNormal)
    if not wallNormalOnSurface or wallNormalOnSurface.Magnitude <= 0.001 then
        return nil, nil
    end

    wallNormalOnSurface = wallNormalOnSurface.Unit
    local reflected = tangentVelocity - (2 * tangentVelocity:Dot(wallNormalOnSurface) * wallNormalOnSurface)

    return reflected, wallNormalOnSurface
end

function SlideVehicleMath.clampSpeedRatio(speedBefore, speedAfter, minRatio, maxRatio)
    local ratio = speedAfter / math.max(speedBefore, 0.001)
    local clamped = math.clamp(ratio, minRatio, maxRatio)
    return clamped
end

function SlideVehicleMath.angleBetweenDegrees(a, b)
    if not a or not b or a.Magnitude <= 0.001 or b.Magnitude <= 0.001 then
        return 0
    end

    local dotValue = math.clamp(a.Unit:Dot(b.Unit), -1, 1)
    return math.deg(math.acos(dotValue))
end

return SlideVehicleMath
