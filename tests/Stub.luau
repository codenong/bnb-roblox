-- 最小的 Roblox 环境桩，仅用于在 Roblox 之外跑服务端流程测试
local Stub = {}

Stub.clock = 0
Stub.players = {}
Stub.sent = {} -- 服务端广播的所有 GameEvent：{ name = ..., args = {...} }

local function newInstance(className)
    local inst = { ClassName = className, Name = "", Parent = nil, destroyed = false }
    function inst.Destroy(self)
        self.destroyed = true
    end
    function inst.ClearAllChildren() end
    function inst.FireAllClients(_, name, ...)
        table.insert(Stub.sent, { name = name, args = { ... } })
    end
    function inst.FireClient() end
    return inst
end

Stub.Instance = { new = newInstance }

Stub.Vector3 = {
    new = function(x, y, z)
        return { X = x, Y = y, Z = z }
    end,
}
Stub.Vector3.zero = Stub.Vector3.new(0, 0, 0)

Stub.Color3 = {
    fromRGB = function(r, g, b)
        return { r, g, b }
    end,
    new = function(r, g, b)
        return { r, g, b }
    end,
}

-- Enum.X.Y 随便取都返回字符串
Stub.Enum = setmetatable({}, {
    __index = function(t, k)
        local v = setmetatable({}, {
            __index = function(_, k2)
                return k .. "." .. k2
            end,
        })
        rawset(t, k, v)
        return v
    end,
})

Stub.os = {
    clock = function()
        return Stub.clock
    end,
}

Stub.workspace = {
    FindFirstChild = function()
        return nil
    end,
    GetServerTimeNow = function()
        return Stub.clock
    end,
}

local sharedStub = {
    WaitForChild = function(_, name)
        return "./" .. name
    end,
}

local services = {
    ReplicatedStorage = {
        -- Net.init 之后 Remote 都在 Net 自己的缓存里，不会走到这里的 BnBRemotes
        WaitForChild = function(_, name)
            if name == "Shared" then
                return sharedStub
            end
            error("unexpected WaitForChild: " .. tostring(name))
        end,
    },
    Players = {
        GetPlayers = function()
            return Stub.players
        end,
    },
    RunService = {
        IsServer = function()
            return true
        end,
    },
    Debris = {
        AddItem = function() end,
    },
}

Stub.game = {
    GetService = function(_, name)
        return services[name]
    end,
}

Stub.script = {
    Parent = {
        WaitForChild = function(_, name)
            return "./" .. name
        end,
    },
}

return Stub
