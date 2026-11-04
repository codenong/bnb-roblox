-- Recording Net stub for room/snapshot audience tests.
local Net = {}

local sends = {}
local broadcasts = {}

local function playerKey(player)
    -- Tests sometimes pass a PlayerService record instead of the Player.
    if type(player) == "table" and player.player then
        player = player.player
    end
    return tostring(player and player.UserId or player)
end

function Net.reset()
    sends = {}
    broadcasts = {}
end

function Net.init() end

function Net.get(name: string)
    return {
        FireAllClients = function() end,
        FireClient = function() end,
    }
end

function Net.broadcast(name: string, _payload: any)
    broadcasts[name] = (broadcasts[name] or 0) + 1
end

function Net.send(player: any, name: string, _payload: any)
    local key = playerKey(player)
    sends[key] = sends[key] or {}
    sends[key][name] = (sends[key][name] or 0) + 1
end

function Net.sentCount(player: any, name: string): number
    local perPlayer = sends[playerKey(player)]
    return if perPlayer then (perPlayer[name] or 0) else 0
end

function Net.broadcastCount(name: string): number
    return broadcasts[name] or 0
end

return Net
