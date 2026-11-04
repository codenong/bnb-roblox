-- Roblox-independent globals for loading the real Main.client.luau in the Luau
-- CLI. tests/run.sh prepends aliases for game/Instance/Enum/script to the copy.
local Env = {
    remotes = {}, -- name -> fake remote (handler = OnClientEvent callback)
    renderStepped = nil, -- RenderStepped callback captured from Main
    syncResponse = nil, -- what GetSync:InvokeServer() returns
    lastGrid = nil,
    gridCalls = 0,
}

-- Property sets are stored; any method call is a harmless no-op.
local function newInstance()
    return setmetatable({}, {
        __index = function()
            return function() end
        end,
    })
end

Env.Instance = {
    new = function()
        return newInstance()
    end,
}

Env.Enum = setmetatable({}, {
    __index = function(t, k)
        local group = setmetatable({}, {
            __index = function(_, name)
                return k .. "." .. name
            end,
        })
        rawset(t, k, group)
        return group
    end,
})

local services = {
    Players = {
        LocalPlayer = {
            WaitForChild = function()
                return {}
            end,
        },
    },
    ReplicatedStorage = {
        WaitForChild = function()
            return {
                WaitForChild = function(_, name)
                    return "./" .. name
                end,
            }
        end,
    },
    RunService = {
        RenderStepped = {
            Connect = function(_, fn)
                Env.renderStepped = fn
            end,
        },
    },
    UserInputService = { TouchEnabled = false },
}

Env.game = {
    GetService = function(_, name)
        return services[name]
    end,
}

Env.script = {
    Parent = {
        WaitForChild = function(_, name)
            return "./" .. name
        end,
    },
}

return Env
