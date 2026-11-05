-- Recording stubs for the client modules Main.client depends on (everything
-- except Interpolation, which is the real module). tests/run.sh creates
-- Board/Hud/Input/Audio/Renderer/Net.luau files that forward to the tables here.
local Env = require("./ClientEnv")

-- Signals remember their handler so tests can fire them: Env.signals.charSelected(...)
Env.signals = {}
local function signal(name)
    return {
        Event = {
            Connect = function(_, fn)
                Env.signals[name] = fn
            end,
        },
    }
end

local Stubs = {}

Stubs.Board = {
    new = function()
        return {}
    end,
    setGrid = function(rows)
        Env.lastGrid = rows
        Env.gridCalls += 1
    end,
    setSliding = function() end,
}

Stubs.Hud = {
    init = function() end,
    getBoardHost = function()
        return {}
    end,
    setState = function() end,
    applySnapshot = function() end,
    setMuted = function() end,
    charSelected = signal("charSelected"),
    mutePressed = signal("mutePressed"),
}

Stubs.Input = {
    init = function() end,
    setEnabled = function() end,
    setControlsVisible = function() end,
    getDirs = function()
        return {}
    end,
    placePressed = signal("placePressed"),
    usePressed = signal("usePressed"),
}

Stubs.Audio = {
    init = function() end,
    onFx = function() end,
    playResult = function() end,
    toggleMuted = function()
        return false
    end,
}

Stubs.Renderer = {
    init = function() end,
    setRoster = function() end,
    setYourId = function() end,
    update = function() end,
    clear = function() end,
}

Stubs.Net = {
    get = function(name)
        local remote = Env.remotes[name]
        if not remote then
            remote = { sent = {} }
            remote.OnClientEvent = {
                Connect = function(_, fn)
                    remote.handler = fn
                end,
            }
            function remote:FireServer(...)
                table.insert(self.sent, { ... })
            end
            function remote:InvokeServer()
                return Env.syncResponse
            end
            Env.remotes[name] = remote
        end
        return remote
    end,
}

return Stubs
