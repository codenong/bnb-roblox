-- src/server/SnapshotService.luau
-- 20Hz snapshot cadence inside the fixed 30Hz simulation. Called once per
-- simulation tick with DT; 30 ticks therefore produce ~20 snapshots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))

local SnapshotService = {}

local accumulator = 0
local interval = 1 / Constants.SNAPSHOT_RATE

function SnapshotService.reset()
    accumulator = 0
end

function SnapshotService.step(game)
    accumulator += Constants.DT
    if accumulator + 1e-9 >= interval then
        accumulator -= interval
        if accumulator < 0 then
            accumulator = 0
        end
        Net.broadcast("Snapshot", game:snapshot())
    end
end

return SnapshotService
