-- src/server/Main.server.luau
-- 服务端入口：初始化、连接网络事件、驱动主循环

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- 不使用 Roblox 默认角色，玩家外观由客户端根据网格位置绘制。
-- 必须尽早设置，在任何玩家加载角色之前。
Players.CharacterAutoLoads = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local MapRules = require(Shared:WaitForChild("MapRules"))
local Net = require(Shared:WaitForChild("Net"))

Net.init()

local BombService = require(script.Parent:WaitForChild("BombService"))
local MapService = require(script.Parent:WaitForChild("MapService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))

-- 大厅里也先生成一张地图，进游戏就能看到
MapService.build()
RoundService.start()

---------------------------------------------------------------- 网络事件

Net.get("Input").OnServerEvent:Connect(function(player, dirX, dirZ)
    PlayerService.setInput(player, dirX, dirZ)
end)

Net.get("PlaceBubble").OnServerEvent:Connect(function(player, col, row)
    if not RoundService.isPlaying() then
        return
    end

    local state = PlayerService.get(player)
    if state then
        BombService.place(state, col, row, os.clock())
    end
end)

-- 客户端启动 / 晚加入时拉取完整状态
Net.get("GetSync").OnServerInvoke = function(_player)
    local map = MapService.map
    return {
        width = map.width,
        height = map.height,
        cells = MapRules.flatten(map),
        bubbles = BombService.flatList(),
        round = RoundService.getInfo(),
    }
end

---------------------------------------------------------------- 玩家进出

local function onPlayerAdded(player: Player)
    -- 保险：万一仍然生成了默认角色，直接删掉
    player.CharacterAdded:Connect(function(character)
        task.defer(function()
            character:Destroy()
        end)
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
    onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
    PlayerService.remove(player)
end)

---------------------------------------------------------------- 主循环

local snapshotInterval = 1 / Constants.SNAPSHOT_RATE
local snapshotTimer = 0
local snapshotRemote = Net.get("Snapshot")

RunService.Heartbeat:Connect(function(dt)
    local now = os.clock()

    PlayerService.step(dt, now)
    BombService.update(now)
    RoundService.update(now)

    snapshotTimer += dt
    if snapshotTimer >= snapshotInterval then
        snapshotTimer = 0
        snapshotRemote:FireAllClients(workspace:GetServerTimeNow(), PlayerService.snapshot())
    end
end)
