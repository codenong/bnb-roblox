-- src/shared/Net.luau
-- 所有 Remote 的统一入口。服务端先调用 Net.init() 创建，客户端用 Net.get() 等待并获取。
--
-- Input        C->S  RemoteEvent            (dirX, dirZ)  当前移动方向，变化时发送
-- PlaceBubble  C->S  RemoteEvent            (col, row)    请求在某格放泡泡
-- GameEvent    S->C  RemoteEvent            (name, ...)   可靠事件：回合状态、泡泡、爆炸、被困、死亡……
-- Snapshot     S->C  UnreliableRemoteEvent  (time, list)  玩家位置快照，丢包无所谓
-- GetSync      C->S  RemoteFunction         ()            客户端启动 / 晚加入时拉取完整状态

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "BnBRemotes"

local DEFINITIONS = {
    Input = "RemoteEvent",
    PlaceBubble = "RemoteEvent",
    GameEvent = "RemoteEvent",
    Snapshot = "UnreliableRemoteEvent",
    GetSync = "RemoteFunction",
}

local Net = {}

local cache = {}

-- 仅服务端调用一次
function Net.init()
    assert(RunService:IsServer(), "Net.init 只能在服务端调用")

    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME

    for name, className in DEFINITIONS do
        local remote = Instance.new(className)
        remote.Name = name
        remote.Parent = folder
        cache[name] = remote
    end

    folder.Parent = ReplicatedStorage
end

function Net.get(name: string)
    local remote = cache[name]
    if remote then
        return remote
    end

    local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
    remote = folder:WaitForChild(name)
    cache[name] = remote
    return remote
end

-- 服务端：向所有客户端广播一个可靠事件
function Net.broadcast(eventName: string, ...)
    Net.get("GameEvent"):FireAllClients(eventName, ...)
end

return Net
