-- src/server/SnapshotService.luau
-- Per-room 20Hz snapshot cadence inside the fixed 30Hz simulation. Each Room
-- owns an instance, so two rooms never share an accumulator or a recipient
-- list. The caller supplies the send callback (room-scoped, not broadcast).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local SnapshotService = {}
local Snapshot = {}
Snapshot.__index = Snapshot

local interval = 1 / Constants.SNAPSHOT_RATE

function SnapshotService.new()
    return setmetatable({
        accumulator = 0,
    }, Snapshot)
end

function Snapshot:reset()
    self.accumulator = 0
end

function Snapshot:step(simulation, send)
    self.accumulator += Constants.DT
    if self.accumulator + 1e-9 >= interval then
        self.accumulator -= interval
        if self.accumulator < 0 then
            self.accumulator = 0
        end
        send(simulation:snapshot())
    end
end

return table.freeze(SnapshotService)
