-- src/server/RoundService.luau
-- 回合流程：Intermission（等待/倒计时）-> Playing -> Ended（结算）-> Intermission ...

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local MapRules = require(Shared:WaitForChild("MapRules"))
local Net = require(Shared:WaitForChild("Net"))

local BombService = require(script.Parent:WaitForChild("BombService"))
local MapService = require(script.Parent:WaitForChild("MapService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local RoundService = {}

local state = "Intermission"
local message = ""
local endsAtClock: number? = nil -- 服务端 os.clock() 时间，用于判断
local endsAtServer = 0 -- workspace:GetServerTimeNow() 时间，发给客户端显示倒计时
local startedCount = 0

local function setState(newState: string, newMessage: string, duration: number?)
    state = newState
    message = newMessage

    if duration then
        endsAtClock = os.clock() + duration
        endsAtServer = workspace:GetServerTimeNow() + duration
    else
        endsAtClock = nil
        endsAtServer = 0
    end

    Net.broadcast("RoundState", state, message, endsAtServer)
end

function RoundService.getInfo()
    return {
        state = state,
        message = message,
        endsAt = endsAtServer,
    }
end

function RoundService.isPlaying(): boolean
    return state == "Playing"
end

local function startRound()
    BombService.reset()
    local map = MapService.build()

    local participants = {}
    for _, player in Players:GetPlayers() do
        if #participants >= Constants.MAX_PLAYERS then
            break
        end
        table.insert(participants, player)
    end

    PlayerService.start(participants)
    startedCount = #participants

    -- 通知所有客户端：新地图、清空旧状态
    Net.broadcast("MapReset", map.width, map.height, MapRules.flatten(map))
    setState("Playing", "战斗开始！", nil)
end

function RoundService.start()
    setState("Intermission", "等待玩家加入…", nil)
end

function RoundService.update(now: number)
    if state == "Intermission" then
        local enough = #Players:GetPlayers() >= Constants.MIN_PLAYERS

        if enough and endsAtClock == nil then
            setState("Intermission", "即将开始", Constants.INTERMISSION)
        elseif not enough and endsAtClock ~= nil then
            setState("Intermission", "等待玩家加入…", nil)
        elseif enough and endsAtClock and now >= endsAtClock then
            startRound()
        end

    elseif state == "Playing" then
        local alive = PlayerService.aliveList()

        -- 多人对局：只剩 1 人（或 0 人）时结束；
        -- 单人测试：自己被淘汰时结束，方便反复测试
        local finished
        if startedCount >= 2 then
            finished = #alive <= 1
        else
            finished = #alive == 0
        end

        if finished then
            local text
            if #alive == 1 then
                text = alive[1].player.DisplayName .. " 获胜！"
            elseif startedCount >= 2 then
                text = "平局"
            else
                text = "本局结束"
            end
            setState("Ended", text, Constants.END_DELAY)
        end

    elseif state == "Ended" then
        if endsAtClock and now >= endsAtClock then
            setState("Intermission", "等待玩家加入…", nil)
        end
    end
end

return RoundService
