local DownhillState = {}

local state = {
    phase = "Inactive",
    startedAt = 0,
    active = false,
    grounded = false,
    roadName = "",
    speed = 0,
    targetSpeed = 0,
    lateral = 0,
    slope = 0,
    lookAhead = 1,
    steerInput = 0,
    forward = Vector3.new(0, 0, -1),
    groundNormal = Vector3.yAxis,
    headPosition = Vector3.zero,
    rootPosition = Vector3.zero,
    landingShake = 0,
    wallShake = 0,
}

function DownhillState.reset()
    state.phase = "Inactive"
    state.startedAt = 0
    state.active = false
    state.grounded = false
    state.roadName = ""
    state.speed = 0
    state.targetSpeed = 0
    state.lateral = 0
    state.slope = 0
    state.lookAhead = 1
    state.steerInput = 0
    state.forward = Vector3.new(0, 0, -1)
    state.groundNormal = Vector3.yAxis
    state.headPosition = Vector3.zero
    state.rootPosition = Vector3.zero
    state.landingShake = 0
    state.wallShake = 0
end

function DownhillState.update(values)
    for key, value in pairs(values) do
        state[key] = value
    end
end

function DownhillState.get()
    return state
end

function DownhillState.pushLandingShake(amount)
    if amount <= 0 then
        return
    end
    state.landingShake = math.max(state.landingShake, amount)
end

function DownhillState.pushWallShake(amount)
    if amount <= 0 then
        return
    end
    state.wallShake = math.max(state.wallShake, amount)
end

function DownhillState.step(dt)
    local landingDecay = math.clamp(1 - (8 * dt), 0, 1)
    local wallDecay = math.clamp(1 - (10 * dt), 0, 1)

    state.landingShake *= landingDecay
    state.wallShake *= wallDecay

    return state.landingShake, state.wallShake
end

return DownhillState
