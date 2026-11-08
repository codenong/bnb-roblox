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
        Fire = function(_, ...)
            local fn = Env.signals[name]
            if fn then
                fn(...)
            end
        end,
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
    setState = function(newState)
        Env.hudStates = Env.hudStates or {}
        table.insert(Env.hudStates, newState)
    end,
    applySnapshot = function() end,
    setMuted = function() end,
    setLoadingTimedOut = function(value)
        Env.loadingTimedOut = value == true
    end,
    setLobbyOpen = function(open)
        Env.lobbyOpen = open == true
    end,
    setLobbyTables = function(tables)
        Env.lobbyTables = tables
    end,
    setLobbyMessage = function(message)
        Env.lobbyMessage = message
    end,
    showNotice = function(message)
        Env.notices = Env.notices or {}
        table.insert(Env.notices, message)
    end,
    setRoomConfigResult = function(ok, message)
        Env.roomConfigResults = Env.roomConfigResults or {}
        table.insert(Env.roomConfigResults, { ok = ok == true, message = message })
    end,
    setShop = function(snapshot, open)
        Env.shopSnapshots = Env.shopSnapshots or {}
        table.insert(Env.shopSnapshots, { snapshot = snapshot, open = open })
    end,
    isShopOpen = function()
        return Env.shopOpen ~= false
    end,
    closeShop = function()
        Env.shopOpen = false
        Env.shopClosed = true
    end,
    setShopMessage = function(message)
        Env.shopMessages = Env.shopMessages or {}
        table.insert(Env.shopMessages, message)
    end,
    setMyItems = function(snapshot)
        Env.myItems = snapshot
        Env.myItemsCalls = (Env.myItemsCalls or 0) + 1
    end,
    charSelected = signal("charSelected"),
    colorSelected = signal("colorSelected"),
    mutePressed = signal("mutePressed"),
    loadingRetryPressed = signal("loadingRetryPressed"),
    lobbyRequested = signal("lobbyRequested"),
    tableSelected = signal("tableSelected"),
    roomConfigSubmitted = signal("roomConfigSubmitted"),
    shopRequested = signal("shopRequested"),
    purchaseRequested = signal("purchaseRequested"),
}

Stubs.Input = {
    init = function() end,
    setEnabled = function(value)
        Env.inputEnabled = value
    end,
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
            function remote:InvokeServer(...)
                self.invokes = (self.invokes or 0) + 1
                self.lastArgs = { ... }
                local response = Env.invokeResponses and Env.invokeResponses[name]
                if type(response) == "function" then
                    return response(...)
                elseif response ~= nil then
                    return response
                end
                return Env.syncResponse
            end
            Env.remotes[name] = remote
        end
        return remote
    end,
}

return Stubs
