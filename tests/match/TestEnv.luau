-- Deterministic Roblox-independent globals for loading MatchService in the
-- Luau CLI. tests/run.sh prepends aliases for game/Random/warn to the server
-- module copies.
local TestEnv = {}

local seed = 12345
local rng = {}
function rng:NextNumber(a: number?, b: number?): number
    seed = (seed * 1103515245 + 12345) % 2147483648
    local unit = seed / 2147483648
    if a ~= nil and b ~= nil then
        return a + (b - a) * unit
    end
    return unit
end
function rng:NextInteger(a: number, b: number): number
    return math.floor(self:NextNumber(a, b + 1))
end

TestEnv.Random = {
    new = function()
        return rng
    end,
}

local replicatedStorage = {
    WaitForChild = function(_self, name: string)
        return { Name = name }
    end,
}
TestEnv.game = {
    GetService = function(_self, _name: string)
        return replicatedStorage
    end,
}

TestEnv.warn = function(message: any)
    print("WARN: " .. tostring(message))
end

return TestEnv
