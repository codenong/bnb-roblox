-- src/client/Main.client.luau
-- Client entry: receive snapshots, interpolate, render the 2D board and HUD,
-- and send input/action intents. The local player's movement is predicted with
-- the same shared Movement code as the server, then reconciled against
-- acknowledged snapshots; the server stays authoritative for everything else.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))

local Audio = require(script.Parent:WaitForChild("Audio"))
local Board = require(script.Parent:WaitForChild("Board"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local Input = require(script.Parent:WaitForChild("Input"))
local Interpolation = require(script.Parent:WaitForChild("Interpolation"))
local Prediction = require(script.Parent:WaitForChild("Prediction"))
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

-- The native chat sits above the ScreenGui. Hide it by default so it cannot
-- cover the board; the HUD chat button is the only way to bring it back.
local chatOpen = false
local function setChatOpen(open: boolean)
    chatOpen = open == true
    local window = TextChatService and TextChatService.ChatWindowConfiguration
    local input = TextChatService and TextChatService.ChatInputBarConfiguration
    if window then
        window.Enabled = chatOpen
    end
    if input then
        input.Enabled = chatOpen
    end
    Hud.setChatOpen(chatOpen)
end
setChatOpen(false)
Hud.chatPressed.Event:Connect(function()
    setChatOpen(not chatOpen)
end)

local board = Board.new(Hud.getBoardHost())
Renderer.init(board)
Input.init(gui)
Audio.init()

-- Lightweight flattening is the default look. It is a session-only visual
-- preference: collision, snapshots and saved profiles are untouched.
local flatVisual = true
local function setFlatVisual(enabled: boolean)
    flatVisual = enabled == true
    Board.setFlatMode(flatVisual)
    Renderer.setFlatMode(flatVisual)
    Hud.setFlatMode(flatVisual)
end
Hud.flatToggled.Event:Connect(function()
    setFlatVisual(not flatVisual)
end)
setFlatVisual(flatVisual)

local inputRemote = Net.get("Input")
local actionRemote = Net.get("Action")
local selectCharRemote = Net.get("SelectChar")
local selectColorRemote = Net.get("SelectColor")
local roundStateRemote = Net.get("RoundState")
local snapshotRemote = Net.get("Snapshot")
local fxRemote = Net.get("Fx")
local roundEndRemote = Net.get("RoundEnd")
local getSyncRemote = Net.get("GetSync")
local getTablesRemote = Net.get("GetTables")
local joinTableRemote = Net.get("JoinTable")
local leaveTableRemote = Net.get("LeaveTable")
local setRoomConfigRemote = Net.get("SetRoomConfig")
local getShopRemote = Net.get("GetShop")
local shopUpdateRemote = Net.get("ShopUpdate")
local noticeRemote = Net.get("Notice")

---------------------------------------------------------------- 状态

local interp = Interpolation.new()
local prediction = Prediction.new()
local currentState = nil
local lastSnapshot = nil
-- Highest map version (snapshot/RoundState gridVer) applied to the board.
-- Grid rows ride on whichever snapshot or broadcast was built first after the
-- map changed; with reordering at high RTT that carrier can arrive behind a
-- newer snapshot, and blindly applying it would draw an older map (crates that
-- are already gone reappear). Applying by version keeps the board, the
-- predictor and the server on the same map. nil = nothing applied yet.
local appliedGridVer = nil
-- One sequenced command per 30Hz tick. Sequence numbers stay monotonic for the
-- whole session; the server scopes them to the current round.
local inputSeq = 0
local inputAccumulator = 0
local inputStarted = false
-- True after "换桌" leaves the room and before a new mode is chosen. The server
-- has no room for this player then, so a stale RoundState already in flight must
-- not close the browser or make the board look like a live round.
local browsing = false
-- A placement press rides inside the next ordered input command. Cleared after
-- that command (or whenever the round is left) so one press places one bomb.
local pendingPlace = false

local function setInputEnabled(enabled)
    Input.setEnabled(enabled)
    Input.setControlsVisible(enabled and UserInputService.TouchEnabled)
end

local function resetVisibleRound()
    interp:reset()
    lastSnapshot = nil
    prediction:reset()
    pendingPlace = false
    inputStarted = false
    inputAccumulator = 0
    appliedGridVer = nil
    Renderer.clear()
    Board.setSliding({})
end

-- One place decides whether map rows reach the board and the predictor. Rows
-- without a version (old server) always apply; versioned rows apply only when
-- the version advances, in both the Snapshot and RoundState paths.
local function applyMapRows(rows, ver)
    if type(rows) ~= "table" then
        return
    end
    if type(ver) == "number" then
        if appliedGridVer ~= nil and ver <= appliedGridVer then
            return
        end
        appliedGridVer = ver
    end
    Board.setGrid(rows)
    prediction:setGrid(rows, ver)
end

local function applySnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return
    end

    -- 地图 grid 只在变化时随快照下发一次，必须在收到的这一刻就应用。
    -- 不能留到渲染时再从"当前快照"里取：同一帧里连收两个快照（掉帧、网络抖动后的
    -- 突发）时，带 grid 的那个会变成"上一个快照"而被跳过，被炸掉的箱子会一直留在画面上。
    -- 另外快照可能乱序：带 grid 的旧快照不能把已经更新的棋盘倒退回去，
    -- 所以按 gridVer 单调应用（applyMapRows）。
    if snapshot.grid then
        applyMapRows(snapshot.grid, snapshot.gridVer)
    end

    lastSnapshot = snapshot
    interp:push(snapshot)
    if currentState and currentState.phase == "playing" then
        prediction:onSnapshot(snapshot, currentState.yourId, os.clock())
    end
    Hud.applySnapshot(snapshot)
end

local function applyState(newState)
    if type(newState) ~= "table" or type(newState.phase) ~= "string" then
        return
    end
    if browsing then
        return
    end

    if newState.phase == "loading" then
        -- The server is still loading this player's profile, so there is no room
        -- yet. Show the loading screen only. A placeholder must never replace a
        -- real state that already arrived (events and GetSync answers can cross).
        if currentState ~= nil and currentState.phase ~= "loading" then
            return
        end
        currentState = newState
        Hud.setState(newState)
        setInputEnabled(false)
        return
    end

    local previous = currentState
    local reset = previous == nil
        or previous.roomId ~= newState.roomId
        or previous.roundId ~= newState.roundId
        or (previous.phase ~= "waiting" and newState.phase == "waiting")

    currentState = newState

    -- Entering a live round closes an intentionally opened chat so it cannot
    -- cover the board. The player can still reopen it with the chat button.
    if newState.phase == "playing" and (previous == nil or previous.phase ~= "playing") then
        setChatOpen(false)
    end

    if reset then
        resetVisibleRound()
    end

    Renderer.setRoster(newState.roster or {})
    Renderer.setYourId(newState.yourId)
    if newState.grid then
        -- RoundState always carries the map and arrives before the first round
        -- snapshot, which only includes the grid when it changes. A RoundState
        -- that crosses a newer snapshot must not roll the map back, so the
        -- same monotonic version rule applies here.
        applyMapRows(newState.grid, newState.gridVer)
    end
    Hud.setState(newState)

    local playing = newState.phase == "playing" and newState.yourId ~= nil
    setInputEnabled(playing)
    if not playing then
        prediction:reset()
        pendingPlace = false
        inputStarted = false
        inputAccumulator = 0
    end

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
    -- Our own sequenced placement already played locally the moment the
    -- predicted bomb appeared. Fx and Snapshot are independent remotes, so the
    -- confirmation can arrive in either order; the suppression survives it.
    if type(event) == "table"
        and event.kind == "bomb_set"
        and currentState ~= nil
        and event.ownerId == currentState.yourId
        and type(event.seq) == "number"
        and prediction:consumePlaceFx(event.seq)
    then
        return
    end
    Audio.onFx(event)
end)

roundEndRemote.OnClientEvent:Connect(function(result)
    Audio.playResult(result, currentState and currentState.yourId)
end)

-- Targeted transient toast, currently used when a seatless versus room sends its
-- spectators back to practice.
noticeRemote.OnClientEvent:Connect(function(payload)
    local message = if type(payload) == "table" then payload.message elseif type(payload) == "string" then payload else nil
    if type(message) == "string" and message ~= "" then
        Hud.showNotice(message)
    end
end)

Hud.charSelected.Event:Connect(function(charId)
    -- The server rejects picks inside the lock window; do not even send them.
    if currentState and currentState.phase == "waiting" and not currentState.charLocked then
        selectCharRemote:FireServer(charId)
    end
end)

Hud.colorSelected.Event:Connect(function(colorKey)
    if currentState and currentState.phase == "waiting" and not currentState.charLocked then
        selectColorRemote:FireServer(colorKey)
    end
end)

Hud.mutePressed.Event:Connect(function()
    Hud.setMuted(Audio.toggleMuted())
end)

Input.placePressed.Event:Connect(function()
    if not currentState or browsing
        or currentState.phase ~= "playing"
        or currentState.yourId == nil
    then
        return
    end
    if currentState.placeSequenced == true then
        -- Tie the request to the next command's seq. The server places with the
        -- same pre-move position the client used to predict, so no client tile
        -- ever needs to be trusted. Prediction being inactive (trapped, warmup)
        -- does not block the request; the server decides.
        pendingPlace = true
    else
        -- Old server: keep the legacy immediate action so placing still works.
        actionRemote:FireServer("place")
    end
end)

Input.usePressed.Event:Connect(function()
    if currentState and currentState.phase == "playing" and currentState.yourId then
        actionRemote:FireServer("use")
    end
end)

---------------------------------------------------------------- 初始同步

local LOADING_POLL_SECONDS = 1
local LOADING_POLL_LIMIT = 60 -- fallback only; the server kicks with a reason on its own timeout
local loadingPolling = false

local function requestSync()
    local ok, sync = pcall(function()
        return getSyncRemote:InvokeServer()
    end)
    if ok and type(sync) == "table" then
        applyState(sync)
    end
end

local function isLoading()
    return currentState == nil or currentState.phase == "loading"
end

local function startLoadingPoll()
    if loadingPolling or not isLoading() then
        return
    end
    loadingPolling = true
    task.spawn(function()
        for _ = 1, LOADING_POLL_LIMIT do
            task.wait(LOADING_POLL_SECONDS)
            if not isLoading() then
                loadingPolling = false
                return
            end
            requestSync()
        end
        loadingPolling = false
        if isLoading() then
            -- A lost RoundState plus a server that never answers GetSync would
            -- otherwise leave the player on the loading screen forever.
            Hud.setLoadingTimedOut(true)
        end
    end)
end

Hud.loadingRetryPressed.Event:Connect(function()
    if isLoading() then
        Hud.setLoadingTimedOut(false)
        startLoadingPoll()
    end
end)

---------------------------------------------------------------- 大厅 / 换桌

local JOIN_ERRORS = {
    not_loaded = "数据仍在加载，请稍后再试",
    invalid_target = "无法进入该房间",
    invalid_table = "桌子编号无效",
    no_table = "这张桌子已经不存在",
    no_tables = "没有可直接加入的桌子；密码房请在列表中选择",
    table_full = "桌子已满，请换一张",
    password_required = "请输入房间密码",
    wrong_password = "密码错误",
    too_many_attempts = "密码错误次数过多，请稍后再试",
    join_failed = "加入失败，请重试",
}

local CONFIG_ERRORS = {
    not_loaded = "数据仍在加载，请稍后再试",
    not_in_room = "你已不在该房间",
    not_versus = "练习房间不能修改设置",
    not_host = "只有房主可以修改设置",
    not_waiting = "对局开始后无法修改设置",
    invalid_request = "设置内容无效",
    invalid_name = "房间名不可用：最多 30 个字符，至少 5 个可见，且不能含不可见或控制字符",
    filter_failed = "房间名包含不可用内容，请换一个",
    invalid_password = "密码需为 4–6 位数字",
    config_rate_limited = "操作太频繁，请稍后再试",
}

local SHOP_ERRORS = {
    not_loaded = "数据仍在加载，请稍后再试",
}

local function loadLobbyTables()
    Hud.setLobbyMessage("正在读取桌子…")
    local ok, tables = pcall(function()
        return getTablesRemote:InvokeServer()
    end)
    if ok and type(tables) == "table" then
        Hud.setLobbyTables(tables)
    else
        Hud.setLobbyMessage("读取桌子失败，请点刷新重试")
    end
end

-- "我的道具" uses the same GetShop snapshot as the shop panel. It is read-only:
-- every versus round computes its own automatic carry on the server.
local function loadMyItems()
    local ok, snapshot = pcall(function()
        return getShopRemote:InvokeServer()
    end)
    if ok and type(snapshot) == "table" and snapshot.ok == true then
        Hud.setMyItems(snapshot)
    else
        Hud.setMyItems(nil)
    end
end

-- "换桌" and opening the shop both leave the current room. This is a real
-- server-side seat exit (the old countdown is cancelled or the round is
-- forfeited as usual), not a paused timer. The player has no room until they
-- choose practice or a versus table; leaving the browser means returning to a
-- fresh practice room. Mark the client as browsing before the request so an
-- in-flight RoundState from the old room cannot take over the UI while the
-- server is removing the seat.
local function leaveToLobby(fetchInventory: boolean?)
    local wasBrowsing = browsing
    browsing = true
    prediction:reset()
    pendingPlace = false
    inputStarted = false
    inputAccumulator = 0
    local ok, result = pcall(function()
        return leaveTableRemote:InvokeServer()
    end)
    if not ok or type(result) ~= "table" or not result.ok then
        browsing = wasBrowsing
        return false, if type(result) == "table" then result.reason else nil
    end
    Hud.setLobbyOpen(true)
    loadLobbyTables()
    -- The shop flow asks for a fresh snapshot itself, so it skips this call.
    if fetchInventory ~= false then
        loadMyItems()
    end
    return true
end

Hud.lobbyRequested.Event:Connect(function()
    if browsing then
        -- The refresh button also uses this signal; the player is already out
        -- of a room, so only the table list and inventory need reloading.
        loadLobbyTables()
        loadMyItems()
        return
    end
    leaveToLobby(true)
end)

Hud.tableSelected.Event:Connect(function(target)
    local ok, result = pcall(function()
        return joinTableRemote:InvokeServer(target)
    end)
    if not ok or type(result) ~= "table" or not result.ok then
        local reason = if type(result) == "table" then result.reason else nil
        Hud.setLobbyMessage(JOIN_ERRORS[reason] or "加入失败，请重试")
        return
    end
    browsing = false
    Hud.setLobbyOpen(false)
    requestSync()
end)

-- The HUD only emits intent; all validation and filtering happen on the server.
Hud.roomConfigSubmitted.Event:Connect(function(request)
    if type(request) ~= "table" then
        Hud.setRoomConfigResult(false, CONFIG_ERRORS.invalid_request)
        return
    end
    local ok, result = pcall(function()
        return setRoomConfigRemote:InvokeServer(request)
    end)
    if not ok or type(result) ~= "table" then
        Hud.setRoomConfigResult(false, "保存失败，请重试")
        return
    end
    if result.ok then
        Hud.setRoomConfigResult(true, nil)
    else
        Hud.setRoomConfigResult(false, CONFIG_ERRORS[result.reason] or "保存失败，请重试")
    end
end)

-- Opening the shop is an exit from the room, exactly like "换桌": the seat is
-- released before the shop snapshot is requested, so no other player's waiting
-- countdown is affected and the native Roblox purchase prompt cannot hold up a
-- table. The room browser opens underneath the shop; closing the shop leaves the
-- player there to choose practice or another table.
Hud.shopRequested.Event:Connect(function()
    if not browsing then
        local left, reason = leaveToLobby(false)
        if not left then
            Hud.closeShop()
            Hud.showNotice(JOIN_ERRORS[reason] or "暂时无法离开房间，请稍后再试")
            return
        end
    end

    local ok, snapshot = pcall(function()
        return getShopRemote:InvokeServer()
    end)
    if not ok or type(snapshot) ~= "table" then
        Hud.setShopMessage("读取道具失败，请稍后再试")
        return
    end
    if not snapshot.ok then
        Hud.setShopMessage(SHOP_ERRORS[snapshot.reason] or "读取道具失败，请稍后再试")
        return
    end
    Hud.setMyItems(snapshot)
    -- The player may have closed the panel while the leave/snapshot requests
    -- were in flight; do not pop it open again in that case.
    Hud.setShop(snapshot, Hud.isShopOpen())
end)

Hud.purchaseRequested.Event:Connect(function(productId)
    if type(productId) ~= "number" then
        return
    end
    local ok, err = pcall(function()
        MarketplaceService:PromptProductPurchase(player, productId)
    end)
    if not ok then
        warn("[BnB] PromptProductPurchase failed: " .. tostring(err))
        Hud.setShopMessage("无法打开购买窗口，请稍后再试")
    end
end)

shopUpdateRemote.OnClientEvent:Connect(function(snapshot)
    Hud.setShop(snapshot, false)
    Hud.setMyItems(snapshot)
end)

requestSync()

-- No usable state yet: the profile is still loading, or the answer was empty.
-- Show the loading screen and keep asking until a real state arrives. The server
-- also pushes the room state the moment the player is seated, so polling is only
-- a safety net for an event that was missed or sent before this script listened.
if currentState == nil then
    applyState({ phase = "loading" })
end
startLoadingPoll()

---------------------------------------------------------------- 每帧

local INPUT_INTERVAL = 1 / Constants.TICK_RATE
-- A long frame must not fire a burst of catch-up commands. The server buffer is
-- short, so the client simply skips the missed ticks and reconciles from the
-- next authoritative snapshot.
local MAX_INPUT_CATCHUP = 3

RunService.RenderStepped:Connect(function(dt)
    local now = os.clock()
    -- Roblox always supplies dt; the headless tests call the captured callback
    -- without one and treat a frame as 60Hz.
    if type(dt) ~= "number" or dt <= 0 then
        dt = 1 / 60
    end
    prediction:update(dt)

    -- `browsing` means "换桌"/shop already left the room; the last RoundState is
    -- still cached, so do not keep streaming input or drawing a frozen player.
    local playing = currentState ~= nil
        and not browsing
        and currentState.phase == "playing"
        and currentState.yourId ~= nil

    if playing then
        if not inputStarted then
            -- Send the first command on the first frame of the round instead of
            -- waiting a full tick to accumulate.
            inputStarted = true
            inputAccumulator = INPUT_INTERVAL
        end
        inputAccumulator = math.min(
            inputAccumulator + dt,
            INPUT_INTERVAL * (MAX_INPUT_CATCHUP + 1)
        )
        local sent = 0
        while inputAccumulator >= INPUT_INTERVAL and sent < MAX_INPUT_CATCHUP do
            inputAccumulator -= INPUT_INTERVAL
            sent += 1
            inputSeq += 1
            local dirs = Input.getDirs()
            local place = pendingPlace and currentState.placeSequenced == true
            pendingPlace = false
            local payload = {
                seq = inputSeq,
                roundId = currentState.roundId,
                dirs = dirs,
            }
            -- Omit the field entirely on ordinary commands; only a true boolean
            -- ever requests a placement.
            if place then
                payload.place = true
            end
            inputRemote:FireServer(payload)
            -- The shadow advances on the same timeline as the command stream:
            -- one command, one 30Hz step, exactly like the server buffer.
            local _, placePredicted = prediction:step(inputSeq, dirs, now, place)
            if placePredicted == true then
                Audio.play("bomb_set")
            end
        end
    else
        inputStarted = false
        inputAccumulator = 0
        pendingPlace = false
    end

    local previous, current, alpha = interp:sample(now)

    local localPos = nil
    if playing then
        local x, y = prediction:getRenderPosition(now)
        if x ~= nil and y ~= nil then
            localPos = { id = currentState.yourId, x = x, y = y }
        end
    end

    local predictedBombs = if playing then prediction:getPredictedBombs() else nil
    if current then
        local warmup = current.warmup or 0
        Renderer.update(previous, current, alpha, now, warmup, localPos, predictedBombs)
    else
        Renderer.update(nil, nil, 1, now, 0, localPos, predictedBombs)
    end
end)
