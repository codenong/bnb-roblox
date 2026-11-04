-- src/client/Main.client.luau
-- Client entry: receive snapshots, interpolate, render the 2D board and HUD,
-- and send only input/action intents. No movement or collision runs here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local Audio = require(script.Parent:WaitForChild("Audio"))
local Board = require(script.Parent:WaitForChild("Board"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local Input = require(script.Parent:WaitForChild("Input"))
local Interpolation = require(script.Parent:WaitForChild("Interpolation"))
local Renderer = require(script.Parent:WaitForChild("Renderer"))

---------------------------------------------------------------- 界面

local gui = Instance.new("ScreenGui")
gui.Name = "BnB"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.DisplayOrder = 10
gui.Parent = playerGui

Hud.init(gui)
local board = Board.new(Hud.getBoardHost())
Renderer.init(board)
Input.init(gui)
Audio.init()

local inputRemote = Net.get("Input")
local actionRemote = Net.get("Action")
local selectCharRemote = Net.get("SelectChar")
local roundStateRemote = Net.get("RoundState")
local snapshotRemote = Net.get("Snapshot")
local fxRemote = Net.get("Fx")
local roundEndRemote = Net.get("RoundEnd")
local getSyncRemote = Net.get("GetSync")

---------------------------------------------------------------- 状态

local interp = Interpolation.new()
local currentState = nil
local lastSnapshot = nil
local lastSentInput = nil
local lastInputAt = 0

local function setInputEnabled(enabled)
    Input.setEnabled(enabled)
    Input.setControlsVisible(enabled and UserInputService.TouchEnabled)
end

local function resetVisibleRound()
    interp:reset()
    lastSnapshot = nil
    lastSentInput = nil
    Renderer.clear()
    Board.setSliding({})
end

local function applySnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return
    end

    -- 地图 grid 只在变化时随快照下发一次，必须在收到的这一刻就应用。
    -- 不能留到渲染时再从"当前快照"里取：同一帧里连收两个快照（掉帧、网络抖动后的
    -- 突发）时，带 grid 的那个会变成"上一个快照"而被跳过，被炸掉的箱子会一直留在画面上。
    if snapshot.grid then
        Board.setGrid(snapshot.grid)
    end

    lastSnapshot = snapshot
    interp:push(snapshot)
    Hud.applySnapshot(snapshot)
end

local function applyState(newState)
    if type(newState) ~= "table" or type(newState.phase) ~= "string" then
        return
    end

    local previous = currentState
    local reset = previous == nil
        or previous.roundId ~= newState.roundId
        or (previous.phase ~= "waiting" and newState.phase == "waiting")

    currentState = newState

    if reset then
        resetVisibleRound()
    end

    Renderer.setRoster(newState.roster or {})
    Renderer.setYourId(newState.yourId)
    if newState.grid then
        Board.setGrid(newState.grid)
    end
    Hud.setState(newState)

    local playing = newState.phase == "playing" and newState.yourId ~= nil
    setInputEnabled(playing)

    if newState.snapshot then
        resetVisibleRound()
        applySnapshot(newState.snapshot)
    end
end

---------------------------------------------------------------- 网络事件

roundStateRemote.OnClientEvent:Connect(applyState)

snapshotRemote.OnClientEvent:Connect(function(snapshot)
    local phase = currentState and currentState.phase
    if phase ~= "playing" and phase ~= "ended" then
        return
    end
    applySnapshot(snapshot)
end)

fxRemote.OnClientEvent:Connect(function(event)
    Audio.onFx(event)
end)

roundEndRemote.OnClientEvent:Connect(function(result)
    Audio.playResult(result, currentState and currentState.yourId)
end)

Hud.charSelected.Event:Connect(function(charId)
    if currentState and currentState.phase == "waiting" then
        selectCharRemote:FireServer(charId)
    end
end)

Hud.mutePressed.Event:Connect(function()
    Hud.setMuted(Audio.toggleMuted())
end)

Input.placePressed.Event:Connect(function()
    if currentState and currentState.phase == "playing" and currentState.yourId then
        actionRemote:FireServer("place")
    end
end)

Input.usePressed.Event:Connect(function()
    if currentState and currentState.phase == "playing" and currentState.yourId then
        actionRemote:FireServer("use")
    end
end)

---------------------------------------------------------------- 初始同步

local ok, sync = pcall(function()
    return getSyncRemote:InvokeServer()
end)
if ok and type(sync) == "table" then
    applyState(sync)
end

---------------------------------------------------------------- 每帧

RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local previous, current, alpha = interp:sample(now)

    if current then
        local warmup = current.warmup or 0
        Renderer.update(previous, current, alpha, now, warmup)
    else
        Renderer.update(nil, nil, 1, now, 0)
    end

    if currentState and currentState.phase == "playing" and currentState.yourId then
        local dirs = Input.getDirs()
        local key = table.concat(dirs, ",")
        if key ~= lastSentInput then
            lastSentInput = key
            lastInputAt = now
            inputRemote:FireServer(dirs)
        elseif #dirs > 0 and now - lastInputAt > 1 then
            -- A new round clears the server's input; resend held directions
            -- occasionally so a player who never releases a key keeps moving.
            lastInputAt = now
            inputRemote:FireServer(dirs)
        end
    end
end)
