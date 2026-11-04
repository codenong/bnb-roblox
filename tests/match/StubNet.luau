-- Minimal Net stub for the headless match-flow test.
local Net = {}

function Net.init() end

function Net.get(name: string)
    return {
        FireAllClients = function() end,
        FireClient = function() end,
    }
end

function Net.broadcast(_name: string, _payload: any) end

function Net.send(_player: any, _name: string, _payload: any) end

return Net
