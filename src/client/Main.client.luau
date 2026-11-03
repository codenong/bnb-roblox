-- src/client/Main.client.luau
-- 客户端入口。
--
-- 网络模型：
--   * 服务端是权威：所有碰撞、泡泡、爆炸、生死都由服务端判定。
--   * 自己的移动在本地"预测"（用和服务端同一份 Movement 代码），所以操作没有延迟；
--     服务端位置偏差太大时才会被强制拉回。
--   * 别人的位置用服务端快照做插值，延迟 INTERP_DELAY 秒显示，看起来更平滑。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local MapRules = require(Shared:WaitForChild("MapRules"))
local Movement = require(Shared:WaitForChild("Movement"))
local Net = require(Shared:WaitForChild("Net"))

local Avatars = require(script.Parent:WaitForChild("Avatars"))
local CameraRig = require(script.Parent:WaitForChild("CameraRig"))
local Input = require(script.Parent:WaitForChild("Input"))
local UI = require(script.Parent:WaitForChild("UI"))

local TILE = Constants.TILE
local localPlayer = Players.LocalPlayer
local myUserId = localPlayer.UserId

---------------------------------------------------------------- 状态

local map = MapRules.createEmptyMap()

-- 自己的预测状态。为 nil 表示当前没有在场上（等待中 / 已淘汰 / 观战）
local localSim = nil

-- 其他玩家：[userId] = { samples = { {t,x,z}, ... }, status, slot }
local remotes = {}

-- [userId] = 最近一次在快照里出现的时间（os.clock）
local lastSeen = {}

local lastSentX, lastSentZ, lastSendTime = nil, nil, 0

---------------------------------------------------------------- 界面 / 镜头 / 输入

local gui = UI.init()
Input.init(gui)
CameraRig.start()

local function resetPlayers()
    localSim = nil
    lastSentX, lastSentZ = nil, nil
    table.clear(remotes)
    table.clear(lastSeen)
    Avatars.clear()
    UI.setLocalStatus("")
end

local function applyMap(width: number, height: number, flat: { number })
    map = MapRules.unflatten(width, height, flat)
    CameraRig.setMapSize(width, height)
end

---------------------------------------------------------------- 服务端事件

local handlers = {}

function handlers.RoundState(state: string, message: string, endsAt: number)
    UI.setRound(state, message, endsAt)
end

function handlers.MapReset(width: number, height: number, flat: { number })
    resetPlayers()
    applyMap(width, height, flat)
end

function handlers.BubblePlaced(col: number, row: number, _ownerUserId: number)
    local key = Grid.key(col, row)
    map.bubbles[key] = true

    if localSim then
        Movement.addIgnoreIfOverlap(localSim.ignore, key, col, row, localSim.x, localSim.z)
    end
end

function handlers.Explosion(removedBubbles: { number }, brokenCrates: { number }, _flameCells: { number })
    for i = 1, #removedBubbles, 2 do
        local key = Grid.key(removedBubbles[i], removedBubbles[i + 1])
        map.bubbles[key] = nil
        if localSim then
            localSim.ignore[key] = nil
        end
    end

    for i = 1, #brokenCrates, 2 do
        MapRules.setCell(map, brokenCrates[i], brokenCrates[i + 1], TILE.EMPTY)
    end
end

function handlers.PlayerTrapped(userId: number)
    if userId == myUserId then
        UI.setLocalStatus("你被泡泡困住了！")
    end
end

function handlers.PlayerDied(userId: number, _reason: string)
    Avatars.remove(userId)
    remotes[userId] = nil
    lastSeen[userId] = nil

    if userId == myUserId then
        localSim = nil
        lastSentX, lastSentZ = nil, nil
        UI.setLocalStatus("你被淘汰了")
    end
end

Net.get("GameEvent").OnClientEvent:Connect(function(eventName: string, ...)
    local handler = handlers[eventName]
    if handler then
        handler(...)
    end
end)

---------------------------------------------------------------- 位置快照

Net.get("Snapshot").OnClientEvent:Connect(function(serverTime: number, list)
    local now = os.clock()

    for _, entry in list do
        local userId, x, z, status, speed, slot = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
        lastSeen[userId] = now

        if userId == myUserId then
            if localSim == nil then
                -- 新一局开始，或刚加入：以服务端位置为准
                localSim = { x = x, z = z, ignore = {}, status = status, speed = speed, slot = slot }
                lastSentX, lastSentZ = nil, nil
                UI.setLocalStatus("")
            else
                localSim.status = status
                localSim.speed = speed
                localSim.slot = slot
                localSim.serverX, localSim.serverZ = x, z

                -- 预测偏差过大（被撞回、作弊、严重卡顿）：直接拉回
                local dx, dz = x - localSim.x, z - localSim.z
                if dx * dx + dz * dz > Constants.RECONCILE_DISTANCE ^ 2 then
                    localSim.x, localSim.z = x, z
                end
            end
        else
            local remote = remotes[userId]
            if remote == nil then
                remote = { samples = {}, status = status, slot = slot }
                remotes[userId] = remote
            end

            local samples = remote.samples
            local last = samples[#samples]
            -- 不可靠通道可能乱序，丢掉过期的
            if last == nil or serverTime > last.t then
                table.insert(samples, { t = serverTime, x = x, z = z })
                if #samples > 20 then
                    table.remove(samples, 1)
                end
            end
            remote.status = status
            remote.slot = slot
        end
    end
end)

-- 在样本序列里按时间 t 取插值位置
local function sample(samples, t: number): (number?, number?)
    local count = #samples
    if count == 0 then
        return nil, nil
    end

    if t <= samples[1].t then
        return samples[1].x, samples[1].z
    end

    for i = count, 2, -1 do
        local a, b = samples[i - 1], samples[i]
        if t >= a.t and t <= b.t then
            local alpha = (t - a.t) / math.max(b.t - a.t, 1e-6)
            return a.x + (b.x - a.x) * alpha, a.z + (b.z - a.z) * alpha
        end
    end

    -- 比最新样本还新：停在最新位置（不外推）
    local latest = samples[count]
    return latest.x, latest.z
end

---------------------------------------------------------------- 放泡泡

Input.BombPressed.Event:Connect(function()
    if localSim == nil or localSim.status == 1 then
        return
    end

    local col, row = Grid.cellOf(localSim.x, localSim.z)
    Net.get("PlaceBubble"):FireServer(col, row)
end)

---------------------------------------------------------------- 每帧

RunService.RenderStepped:Connect(function(dt: number)
    local now = os.clock()

    if localSim then
        local dirX, dirZ = Input.getDirection()

        -- 方向变化时通知服务端。摇杆这类模拟输入限制到 20 次/秒，停下则立即发送
        local changed = lastSentX == nil
            or math.abs(dirX - lastSentX) > 0.02
            or math.abs(dirZ - lastSentZ) > 0.02
        local stopping = dirX == 0 and dirZ == 0
        if changed and (stopping or now - lastSendTime >= 0.05) then
            Net.get("Input"):FireServer(dirX, dirZ)
            lastSentX, lastSentZ, lastSendTime = dirX, dirZ, now
        end

        -- 本地预测移动
        local speed = localSim.speed
        if localSim.status == 1 then
            speed *= Constants.TRAP_SPEED_MULT
        end
        local isSolid = MapRules.makeSolidFn(map, localSim.ignore)
        localSim.x, localSim.z = Movement.step(isSolid, localSim.x, localSim.z, dirX, dirZ, speed, dt)
        Movement.refreshIgnore(localSim.ignore, localSim.x, localSim.z)

        -- 站着不动时，慢慢收敛到服务端位置，消除累积的细小误差
        if stopping and localSim.serverX then
            local alpha = math.min(1, dt * 8)
            localSim.x += (localSim.serverX - localSim.x) * alpha
            localSim.z += (localSim.serverZ - localSim.z) * alpha
        end

        Avatars.update(myUserId, localSim.slot, localSim.x, localSim.z, localSim.status == 1)

        -- 太久没收到自己的快照，说明已经不在场上
        if now - (lastSeen[myUserId] or now) > 1 then
            localSim = nil
            Avatars.remove(myUserId)
        end
    end

    -- 其他玩家
    local renderTime = workspace:GetServerTimeNow() - Constants.INTERP_DELAY
    for userId, remote in remotes do
        if now - (lastSeen[userId] or 0) > 0.5 then
            Avatars.remove(userId)
            remotes[userId] = nil
        else
            local x, z = sample(remote.samples, renderTime)
            if x and z then
                Avatars.update(userId, remote.slot, x, z, remote.status == 1)
            end
        end
    end

    UI.update()
end)

---------------------------------------------------------------- 启动：拉取完整状态

-- 事件监听都已经连好，再请求一次完整同步（处理中途加入）
local sync = Net.get("GetSync"):InvokeServer()
if sync then
    applyMap(sync.width, sync.height, sync.cells)
    for i = 1, #sync.bubbles, 2 do
        map.bubbles[Grid.key(sync.bubbles[i], sync.bubbles[i + 1])] = true
    end
    UI.setRound(sync.round.state, sync.round.message, sync.round.endsAt)
end
