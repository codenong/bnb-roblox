-- src/server/PlayerService.luau
-- 玩家的权威状态：位置、移动、被困、死亡。
-- 服务端不使用 Roblox 默认角色（Players.CharacterAutoLoads = false），
-- 玩家在逻辑上只是网格上的一个点，外观由客户端根据快照绘制。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local MapRules = require(Shared:WaitForChild("MapRules"))
local Movement = require(Shared:WaitForChild("Movement"))
local Net = require(Shared:WaitForChild("Net"))

local MapService = require(script.Parent:WaitForChild("MapService"))

local PlayerService = {}

-- [Player] = state
local states = {}

local function broadcast(eventName: string, ...)
    Net.broadcast(eventName, ...)
end

-- 当前这局所有的玩家状态（包含已死亡的，供结算使用）
function PlayerService.get(player: Player)
    return states[player]
end

function PlayerService.all()
    return states
end

function PlayerService.aliveList()
    local list = {}
    for _, state in states do
        if state.alive then
            table.insert(list, state)
        end
    end
    return list
end

function PlayerService.count(): number
    local n = 0
    for _ in states do
        n += 1
    end
    return n
end

function PlayerService.clear()
    table.clear(states)
end

-- 开始新的一局：给参赛玩家分配出生点并重置属性
function PlayerService.start(participants: { Player })
    table.clear(states)

    local map = MapService.map
    local spawns = MapRules.getSpawnPoints(map)

    for slot, player in ipairs(participants) do
        local spawn = spawns[slot]
        if spawn == nil then
            break
        end

        states[player] = {
            player = player,
            userId = player.UserId,
            slot = slot,
            x = spawn[1],
            z = spawn[2],
            dirX = 0,
            dirZ = 0,
            alive = true,
            trappedUntil = nil :: number?,
            speed = Constants.PLAYER_BASE_SPEED,
            maxBubbles = Constants.PLAYER_BASE_BUBBLES,
            power = Constants.PLAYER_BASE_POWER,
            activeBubbles = 0,
            ignore = {},
        }
    end
end

function PlayerService.remove(player: Player)
    local state = states[player]
    if state then
        states[player] = nil
        broadcast("PlayerDied", state.userId, "left")
    end
end

-- 客户端上报的移动方向。永远不信任客户端：类型检查 + 限制长度
function PlayerService.setInput(player: Player, dirX: any, dirZ: any)
    local state = states[player]
    if not state or not state.alive then
        return
    end

    if typeof(dirX) ~= "number" or typeof(dirZ) ~= "number" then
        return
    end
    -- NaN / inf 检查
    if dirX ~= dirX or dirZ ~= dirZ or math.abs(dirX) > 10 or math.abs(dirZ) > 10 then
        return
    end

    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    if length > 1 then
        dirX /= length
        dirZ /= length
    end

    state.dirX = dirX
    state.dirZ = dirZ
end

function PlayerService.isTrapped(state): boolean
    return state.trappedUntil ~= nil
end

function PlayerService.trap(state, now: number)
    if not state.alive or state.trappedUntil then
        return
    end

    state.trappedUntil = now + Constants.TRAP_DURATION
    broadcast("PlayerTrapped", state.userId)
end

function PlayerService.kill(state, reason: string)
    if not state.alive then
        return
    end

    state.alive = false
    state.dirX = 0
    state.dirZ = 0
    state.trappedUntil = nil
    broadcast("PlayerDied", state.userId, reason)
end

-- 把正好站在这些格子里的玩家困住。cellSet: { [Grid.key] = true }
function PlayerService.trapInCells(cellSet, now: number)
    for _, state in states do
        if state.alive and not state.trappedUntil then
            local col, row = Grid.cellOf(state.x, state.z)
            if cellSet[Grid.key(col, row)] then
                PlayerService.trap(state, now)
            end
        end
    end
end

-- 每帧推进所有玩家
function PlayerService.step(dt: number, now: number)
    local map = MapService.map
    if not map then
        return
    end

    for _, state in states do
        if state.alive then
            local speed = state.speed
            if state.trappedUntil then
                speed *= Constants.TRAP_SPEED_MULT
            end

            local isSolid = MapRules.makeSolidFn(map, state.ignore)
            state.x, state.z = Movement.step(isSolid, state.x, state.z, state.dirX, state.dirZ, speed, dt)
            Movement.refreshIgnore(state.ignore, state.x, state.z)
        end
    end

    -- 被困时间到：死亡；被其他未被困的玩家碰到：死亡
    for _, state in states do
        if state.alive and state.trappedUntil then
            if now >= state.trappedUntil then
                PlayerService.kill(state, "timeout")
            else
                for _, other in states do
                    if other ~= state and other.alive and not other.trappedUntil then
                        local dx = other.x - state.x
                        local dz = other.z - state.z
                        if dx * dx + dz * dz < Constants.TOUCH_KILL_DISTANCE ^ 2 then
                            PlayerService.kill(state, "touched")
                            break
                        end
                    end
                end
            end
        end
    end
end

-- 位置快照，全部用数组 + 数字，节省带宽（UnreliableRemoteEvent 单次上限 900 字节）
-- 每项： { userId, x, z, status(0 正常 / 1 被困), speed, slot }
function PlayerService.snapshot()
    local list = {}
    for _, state in states do
        if state.alive then
            table.insert(list, {
                state.userId,
                math.round(state.x * 1000) / 1000,
                math.round(state.z * 1000) / 1000,
                state.trappedUntil and 1 or 0,
                state.speed,
                state.slot,
            })
        end
    end
    return list
end

return PlayerService
