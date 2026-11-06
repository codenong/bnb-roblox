-- src/shared/Net.luau
-- Remote protocol for BnB. Server calls Net.init() once before use; client uses
-- Net.get() after the folder replicates.
--
-- Input        C->S RemoteEvent      dirs: {string}        oldest press first, newest last
-- Action       C->S RemoteEvent      "place" | "use"      place also detonates remotes
-- SelectChar   C->S RemoteEvent      "baobao" | "haidao"  waiting phase only
-- LeaveTable    C<=>S RemoteFunction () -> ok, reason    leave the current room
-- RoundState   S->C RemoteEvent      phase/room/mode/roster/timers/yourId/grid/spawns
-- Snapshot     S->C RemoteEvent      20Hz simulation snapshot (grid only on change)
-- Fx           S->C RemoteEvent      {kind, ...} sound/visual cues
-- RoundEnd     S->C RemoteEvent      winnerId/name/char/colorIndex/duration/alive
-- GetSync      C<=>S RemoteFunction  () -> full phase/room/roster/snapshot payload
-- GetTables    C<=>S RemoteFunction  () -> versus table summaries
-- JoinTable    C<=>S RemoteFunction  ("practice" | "versus" | tableId | {mode, tableId?})
--                                    -> ok, reason, roomId
--
-- Server sends are room-scoped: Room.luau uses Net.send() for its members.
-- Net.broadcast() remains available for server-wide notices only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "BnBRemotes"

local DEFINITIONS = {
    Input = "RemoteEvent",
    Action = "RemoteEvent",
    SelectChar = "RemoteEvent",
    RoundState = "RemoteEvent",
    Snapshot = "RemoteEvent",
    Fx = "RemoteEvent",
    RoundEnd = "RemoteEvent",
    GetSync = "RemoteFunction",
    GetTables = "RemoteFunction",
    JoinTable = "RemoteFunction",
    LeaveTable = "RemoteFunction",
}

local Net = {}
local cache = {}

local function ensure(folder, name, className)
    local remote = folder:FindFirstChild(name)
    if remote and remote.ClassName ~= className then
        remote:Destroy()
        remote = nil
    end
    if not remote then
        remote = Instance.new(className)
        remote.Name = name
        remote.Parent = folder
    end
    return remote
end

-- Server only. Safe to call twice (reuses an existing folder).
function Net.init()
    assert(RunService:IsServer(), "Net.init is server-only")

    local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = ReplicatedStorage
    end

    for name, className in pairs(DEFINITIONS) do
        cache[name] = ensure(folder, name, className)
    end
end

function Net.get(name: string)
    local remote = cache[name]
    if remote then
        return remote
    end

    assert(DEFINITIONS[name], string.format("unknown remote %q", name))
    local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
    remote = folder:WaitForChild(name)
    cache[name] = remote
    return remote
end

function Net.broadcast(name: string, ...)
    assert(RunService:IsServer(), "Net.broadcast is server-only")
    Net.get(name):FireAllClients(...)
end

function Net.send(player: Player, name: string, ...)
    assert(RunService:IsServer(), "Net.send is server-only")
    Net.get(name):FireClient(player, ...)
end

return Net
