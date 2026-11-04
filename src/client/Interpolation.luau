-- src/client/Interpolation.luau
-- Keeps the previous and current snapshot and exposes a 0..1 blend factor.
-- Rendering one snapshot interval behind is intentional: 20Hz network data
-- becomes continuous 60Hz motion.

local Interpolation = {}
Interpolation.__index = Interpolation

local function clamp01(value: number): number
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

function Interpolation.new()
    return setmetatable({
        previous = nil,
        current = nil,
        previousAt = 0,
        currentAt = 0,
    }, Interpolation)
end

function Interpolation:reset()
    self.previous = nil
    self.current = nil
    self.previousAt = 0
    self.currentAt = 0
end

function Interpolation:push(snapshot)
    local now = os.clock()
    if not self.current then
        self.previous = snapshot
        self.current = snapshot
        self.previousAt = now
        self.currentAt = now
        return
    end

    self.previous = self.current
    self.previousAt = self.currentAt
    self.current = snapshot
    self.currentAt = now
end

function Interpolation:sample(now: number)
    if not self.current then
        return nil, nil, 1
    end
    if not self.previous or self.previous == self.current then
        return self.current, self.current, 1
    end

    local span = self.currentAt - self.previousAt
    if span <= 0.0001 then
        return self.current, self.current, 1
    end

    local alpha = clamp01((now - self.currentAt) / span)
    return self.previous, self.current, alpha
end

return Interpolation
