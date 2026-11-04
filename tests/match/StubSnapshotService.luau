-- Snapshot cadence is visual-only; getSync still exercises Game:snapshot().
local SnapshotService = {}

function SnapshotService.reset() end

function SnapshotService.step(_game) end

return SnapshotService
