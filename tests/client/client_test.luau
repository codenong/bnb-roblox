-- Regression tests for the client entry point (Main.client.luau): snapshot
-- handling with the real Interpolation module and recording stubs elsewhere.
local TestLib = require("./testlib")
local Env = require("./ClientEnv")

local check = TestLib.check

-- Grids are opaque tokens here; only identity matters.
local gridSync, gridSyncSnapshot = { "sync-state" }, { "sync-snapshot" }

-- Late join: GetSync returns the phase plus a forced-grid snapshot.
Env.syncResponse = {
    phase = "playing",
    roundId = 1,
    roster = {},
    yourId = "u1",
    grid = gridSync,
    snapshot = { grid = gridSyncSnapshot, players = {}, bombs = {}, items = {} },
}
require("./Main")

local function fire(name, ...)
    Env.remotes[name].handler(...)
end
local function frame()
    Env.renderStepped()
end
local function playing(roundId, grid)
    fire("RoundState", {
        phase = "playing",
        roundId = roundId,
        roster = {},
        yourId = "u1",
        grid = grid,
    })
end

---------------------------------------------------------------- 晚加入
check("late join applies the sync snapshot grid", Env.lastGrid == gridSyncSnapshot)

---------------------------------------------------------------- 聊天窗口默认隐藏，按钮切换，进对局自动收起
do
    local textChat = Env.textChat
    local window = textChat.ChatWindowConfiguration
    local input = textChat.ChatInputBarConfiguration

    check("chat window starts hidden", window.Enabled == false)
    check("chat input starts hidden", input.Enabled == false)
    check("the chat button starts closed", Env.chatOpen == false)

    Env.signals.chatPressed()
    check("the chat button opens the native window", window.Enabled == true)
    check("the chat button opens the native input", input.Enabled == true)
    check("the chat button shows its open state", Env.chatOpen == true)

    Env.signals.chatPressed()
    check("the chat button closes the native window", window.Enabled == false)
    check("the chat button closes the native input", input.Enabled == false)
    check("the chat button shows its closed state", Env.chatOpen == false)

    fire("RoundState", { phase = "waiting", roundId = 30, roster = {}, yourId = "u1", grid = { "w" } })
    Env.signals.chatPressed()
    check("chat can be opened while waiting", Env.chatOpen == true)

    fire("RoundState", { phase = "playing", roundId = 31, roster = {}, yourId = "u1", grid = { "p" } })
    check("entering a live round closes chat", Env.chatOpen == false)
    check("entering a live round closes the native window", window.Enabled == false)
end

---------------------------------------------------------------- 视觉扁平化开关
do
    check("visual mode starts flat in every renderer", Env.boardFlat == true
        and Env.rendererFlat == true
        and Env.hudFlat == true)

    Env.signals.flatToggled()
    check("the toggle switches the board to legacy 3D", Env.boardFlat == false)
    check("the toggle switches characters to legacy 3D", Env.rendererFlat == false)
    check("the toggle updates the button state", Env.hudFlat == false)

    Env.signals.flatToggled()
    check("the toggle switches every layer back to flat", Env.boardFlat == true
        and Env.rendererFlat == true
        and Env.hudFlat == true)
end

---------------------------------------------------------------- 到达即应用
local roundGrid = { "round-1" }
playing(2, roundGrid)
check("RoundState grid applied", Env.lastGrid == roundGrid)

local gridA = { "A" }
fire("Snapshot", { grid = gridA, players = {} })
check("snapshot grid applied on arrival (before any frame is rendered)", Env.lastGrid == gridA)

---------------------------------------------------------------- 回归：同一帧连收两个快照
local gridB = { "B" }
fire("Snapshot", { grid = gridB, players = {} }) -- 带 grid，随后被下一个快照顶成"上一个"
fire("Snapshot", { players = {} }) -- 不带 grid
frame()
check("grid survives two snapshots landing in one frame", Env.lastGrid == gridB)

local gridC = { "C" }
fire("Snapshot", { grid = gridC, players = {} })
fire("Snapshot", { players = {} })
fire("Snapshot", { players = {} })
frame()
check("grid survives three snapshots landing in one frame", Env.lastGrid == gridC)

---------------------------------------------------------------- 不带 grid 的快照不应触碰地图
local before = Env.gridCalls
fire("Snapshot", { players = {} })
frame()
check("snapshot without grid leaves the board alone", Env.gridCalls == before)

---------------------------------------------------------------- gridVer：乱序到达的旧地图不能倒退棋盘
-- 带 grid 的快照可能乱序（grid 只随地图变化后的第一个快照下发）。客户端按
-- gridVer 单调应用：旧版本既不能把棋盘画回旧地图，也不能绕过预测器。
local gridV3 = { "v3" }
fire("Snapshot", { grid = gridV3, gridVer = 3, players = {} })
check("a versioned grid applies when newer", Env.lastGrid == gridV3)

fire("Snapshot", { grid = { "v2" }, gridVer = 2, players = {} })
check("an older map version cannot roll the board back", Env.lastGrid == gridV3)

fire("Snapshot", { grid = { "v3-again" }, gridVer = 3, players = {} })
check("the same map version is ignored", Env.lastGrid == gridV3)

local gridV4 = { "v4" }
fire("Snapshot", { grid = gridV4, gridVer = 4, players = {} })
check("a newer map version applies immediately", Env.lastGrid == gridV4)

---------------------------------------------------------------- gridVer：新对局重置版本
local gridRound2 = { "round-2" }
playing(3, gridRound2)
check("a new round applies its fresh unversioned map", Env.lastGrid == gridRound2)

local gridR2V1 = { "r2-v1" }
fire("Snapshot", { grid = gridR2V1, gridVer = 1, players = {} })
check("the fresh round's versioned map applies", Env.lastGrid == gridR2V1)

local gridR2V2 = { "r2-v2" }
fire("RoundState", {
    phase = "playing",
    roundId = 3,
    roster = {},
    yourId = "u1",
    grid = gridR2V2,
    gridVer = 2,
})
check("a versioned RoundState grid applies when newer", Env.lastGrid == gridR2V2)

fire("RoundState", {
    phase = "playing",
    roundId = 3,
    roster = {},
    yourId = "u1",
    grid = { "r2-stale" },
    gridVer = 1,
})
check("a stale versioned RoundState cannot roll the map back", Env.lastGrid == gridR2V2)

---------------------------------------------------------------- 非对战阶段的快照被忽略
local waitingGrid, stray = { "waiting" }, { "stray" }
fire("RoundState", { phase = "waiting", roundId = 3, roster = {}, grid = waitingGrid })
fire("Snapshot", { grid = stray, players = {} })
check("snapshots are ignored while waiting", Env.lastGrid == waitingGrid)

---------------------------------------------------------------- 选角锁定：不向服务端发送无效请求
do
    local selectRemote = Env.remotes.SelectChar
    local function picks()
        return #selectRemote.sent
    end

    fire("RoundState", { phase = "waiting", roundId = 10, roster = {}, yourId = "u1", charLocked = false, grid = { "w" } })
    local before = picks()
    Env.signals.charSelected("haidao")
    check("pick is sent while waiting and unlocked", picks() == before + 1, picks() - before)

    fire("RoundState", { phase = "waiting", roundId = 10, roster = {}, yourId = "u1", charLocked = true, grid = { "w" } })
    before = picks()
    Env.signals.charSelected("baobao")
    check("pick is not sent while locked", picks() == before, picks() - before)

    fire("RoundState", { phase = "waiting", roundId = 10, roster = {}, yourId = "u1", charLocked = false, grid = { "w" } })
    before = picks()
    Env.signals.charSelected("baobao")
    check("pick is sent again once unlocked", picks() == before + 1, picks() - before)

    fire("RoundState", { phase = "playing", roundId = 11, roster = {}, yourId = "u1", charLocked = false, grid = { "p" } })
    before = picks()
    Env.signals.charSelected("haidao")
    check("pick is not sent while playing", picks() == before, picks() - before)
end

---------------------------------------------------------------- 选色锁定：与选角共用等待窗口
do
    local colorRemote = Env.remotes.SelectColor
    check("the color remote exists", colorRemote ~= nil)
    local function picks()
        return #colorRemote.sent
    end
    local function waitingState(locked)
        fire("RoundState", {
            phase = "waiting",
            roundId = 20,
            roster = {},
            yourId = "u1",
            charLocked = locked,
            selectedChar = "baobao",
            selectedColor = "red",
            charColors = { baobao = "red", haidao = "blue" },
            grid = { "c" },
        })
    end

    waitingState(false)
    local before = picks()
    Env.signals.colorSelected("green")
    check("color is sent while waiting and unlocked", picks() == before + 1, picks() - before)
    check("the color remote sends the color key", colorRemote.sent[#colorRemote.sent][1] == "green",
        colorRemote.sent[#colorRemote.sent][1])

    waitingState(true)
    before = picks()
    Env.signals.colorSelected("purple")
    check("color is not sent while locked", picks() == before, picks() - before)

    waitingState(false)
    before = picks()
    Env.signals.colorSelected("orange")
    check("color is sent again once unlocked", picks() == before + 1, picks() - before)

    fire("RoundState", { phase = "playing", roundId = 21, roster = {}, yourId = "u1", charLocked = false, grid = { "p" } })
    before = picks()
    Env.signals.colorSelected("red")
    check("color is not sent while playing", picks() == before, picks() - before)
end

---------------------------------------------------------------- 大厅列表与换桌
do
    fire("RoundState", {
        phase = "waiting",
        roomId = 1,
        roundId = 12,
        roster = {},
        yourId = "u1",
        grid = { "lobby" },
    })

    local tables = { { id = 7, phase = "waiting", seats = {}, joinable = true } }
    local getTablesCalls = 0
    Env.invokeResponses.GetTables = function()
        getTablesCalls += 1
        return tables
    end
    local leaveRemote = Env.remotes.LeaveTable
    Env.invokeResponses.LeaveTable = function()
        return { ok = false, reason = "not_loaded" }
    end
    Env.signals.lobbyRequested()
    check("a rejected leave does not open the browser", Env.lobbyOpen ~= true)
    check("the browser does not load tables before the leave succeeds",
        getTablesCalls == 0, getTablesCalls)

    Env.invokeResponses.LeaveTable = function()
        return { ok = true }
    end
    Env.signals.lobbyRequested()
    check("lobby request opens the overlay after leaving", Env.lobbyOpen == true)
    check("opening the lobby leaves the current room", leaveRemote.invokes == 2,
        leaveRemote.invokes)
    check("lobby requests the table list", getTablesCalls == 1, getTablesCalls)
    check("lobby receives the table list", Env.lobbyTables == tables)

    -- A RoundState already in flight when the leave was accepted describes the
    -- room the player just left. It must not close the browser or render a round
    -- the server no longer has them in.
    local lobbyGrid = Env.lastGrid
    fire("RoundState", {
        phase = "playing",
        roomId = 1,
        roundId = 98,
        roster = {},
        yourId = "u1",
        grid = { "stale-round" },
    })
    check("a stale round state does not close the browser", Env.lobbyOpen == true)
    check("a stale round state does not replace the board", Env.lastGrid == lobbyGrid)

    Env.syncResponse = {
        phase = "waiting",
        roomId = 7,
        roundId = 0,
        roster = {},
        yourId = "u1",
        grid = { "joined" },
    }
    local joinRemote = Env.remotes.JoinTable
    Env.invokeResponses.JoinTable = function(target)
        return { ok = true, roomId = target.tableId }
    end
    local syncBefore = Env.remotes.GetSync.invokes
    Env.signals.tableSelected({ mode = "versus", tableId = 7 })
    check("table choice reaches the server", joinRemote.lastArgs[1].tableId == 7)
    check("successful join closes the lobby", Env.lobbyOpen == false)
    check("successful join asks for fresh state", Env.remotes.GetSync.invokes == syncBefore + 1,
        Env.remotes.GetSync.invokes - syncBefore)

    Env.signals.lobbyRequested()
    Env.invokeResponses.JoinTable = function()
        return { ok = false, reason = "table_full" }
    end
    Env.signals.tableSelected({ mode = "versus", tableId = 7 })
    check("failed join keeps the lobby open", Env.lobbyOpen == true)
    check("failed join explains why", Env.lobbyMessage == "桌子已满，请换一张", Env.lobbyMessage)

    -- "返回练习" has no old room to restore; it joins a fresh practice room.
    Env.invokeResponses.JoinTable = function()
        return { ok = true }
    end
    Env.signals.tableSelected("practice")
    check("closing the browser requests practice", joinRemote.lastArgs[1] == "practice")
    check("returning to practice closes the browser", Env.lobbyOpen == false)
end

---------------------------------------------------------------- 通知 toast
do
    Env.notices = nil
    fire("Notice", { message = "房间内已没有对战玩家，房主为空，已返回练习" })
    fire("Notice", "字符串通知")
    fire("Notice", { message = "" })
    fire("Notice", 42)
    check("a Notice table shows a toast", Env.notices and #Env.notices == 2, Env.notices and #Env.notices)
    check("a Notice string is accepted", Env.notices and Env.notices[2] == "字符串通知")
    check("empty/invalid Notices are ignored", Env.notices and #Env.notices == 2)
end

---------------------------------------------------------------- 密码房选择原样转发
do
    local joinRemote = Env.remotes.JoinTable
    Env.invokeResponses.JoinTable = function()
        return { ok = true }
    end
    Env.syncResponse = { phase = "waiting", roomId = 42, roundId = 0, roster = {}, yourId = "u1", grid = {} }
    Env.signals.tableSelected({ mode = "versus", tableId = 42, password = "1234" })
    check("password selection reaches the server", joinRemote.lastArgs[1].password == "1234"
        and joinRemote.lastArgs[1].tableId == 42, joinRemote.lastArgs[1].password)

    Env.invokeResponses.JoinTable = function()
        return { ok = false, reason = "password_required" }
    end
    Env.signals.tableSelected({ mode = "versus", tableId = 42 })
    check("a missing password is explained", Env.lobbyMessage == "请输入房间密码", Env.lobbyMessage)

    Env.invokeResponses.JoinTable = function()
        return { ok = false, reason = "wrong_password" }
    end
    Env.signals.tableSelected({ mode = "versus", tableId = 42, password = "0000" })
    check("a wrong password is explained", Env.lobbyMessage == "密码错误", Env.lobbyMessage)

    Env.invokeResponses.JoinTable = function()
        return { ok = false, reason = "too_many_attempts" }
    end
    Env.signals.tableSelected({ mode = "versus", tableId = 42, password = "0000" })
    check("a password lockout is explained", Env.lobbyMessage == "密码错误次数过多，请稍后再试", Env.lobbyMessage)

    Env.invokeResponses.JoinTable = function()
        return { ok = false, reason = "no_tables" }
    end
    Env.signals.tableSelected("versus")
    check("quick join explains password-only tables", Env.lobbyMessage == "没有可直接加入的桌子；密码房请在列表中选择",
        Env.lobbyMessage)
end

---------------------------------------------------------------- 房主设置
do
    local configRemote = Env.remotes.SetRoomConfig
    Env.invokeResponses.SetRoomConfig = function()
        return { ok = true }
    end
    Env.roomConfigResults = nil
    Env.signals.roomConfigSubmitted({ name = "朋友", password = "1234" })
    check("room config reaches the server", configRemote.lastArgs[1].name == "朋友"
        and configRemote.lastArgs[1].password == "1234")
    check("successful config closes the settings dialog", Env.roomConfigResults
        and #Env.roomConfigResults == 1 and Env.roomConfigResults[1].ok == true
        and Env.roomConfigResults[1].message == nil)

    Env.invokeResponses.SetRoomConfig = function()
        return { ok = false, reason = "not_host" }
    end
    Env.signals.roomConfigSubmitted({ name = "朋友" })
    check("config permission errors are shown", Env.roomConfigResults
        and Env.roomConfigResults[2].ok == false
        and Env.roomConfigResults[2].message == "只有房主可以修改设置")

    Env.invokeResponses.SetRoomConfig = function()
        return { ok = false, reason = "invalid_password" }
    end
    Env.signals.roomConfigSubmitted({ password = "12" })
    check("config validation errors are shown", Env.roomConfigResults
        and Env.roomConfigResults[3].message == "密码需为 4–6 位数字")

    Env.invokeResponses.SetRoomConfig = function()
        error("remote failed")
    end
    Env.signals.roomConfigSubmitted({ name = "朋友" })
    check("a throwing config remote is reported", Env.roomConfigResults
        and Env.roomConfigResults[4].ok == false
        and Env.roomConfigResults[4].message == "保存失败，请重试")

    Env.invokeResponses.SetRoomConfig = function()
        return nil
    end
    Env.signals.roomConfigSubmitted({ name = "朋友" })
    check("a non-table config answer is reported", Env.roomConfigResults
        and Env.roomConfigResults[5].ok == false)

    local invokesBefore = configRemote.invokes
    Env.signals.roomConfigSubmitted("not a table")
    check("a non-table config request is rejected locally", configRemote.invokes == invokesBefore)
    check("a non-table config request is explained", Env.roomConfigResults
        and Env.roomConfigResults[6].message == "设置内容无效")
end

---------------------------------------------------------------- 商店面板：进店即离开房间
do
    local leaveRemote = Env.remotes.LeaveTable
    local snapshot = {
        ok = true,
        mode = nil,
        phase = nil,
        items = { { id = "needle", stock = 1, free = 0, purchased = 1, carry = 1 } },
    }
    local order = {}
    local getTablesCalls = 0
    local getShopCalls = 0

    Env.invokeResponses.GetTables = function()
        getTablesCalls += 1
        return {}
    end
    Env.invokeResponses.LeaveTable = function()
        table.insert(order, "leave")
        return { ok = true }
    end
    Env.invokeResponses.GetShop = function()
        getShopCalls += 1
        table.insert(order, "shop")
        return snapshot
    end
    Env.shopSnapshots = nil
    Env.shopMessages = nil
    Env.shopClosed = nil
    Env.shopOpen = true
    Env.myItems = nil
    Env.myItemsCalls = 0

    local leaveBefore = leaveRemote.invokes
    Env.signals.shopRequested()
    check("opening the shop from a room leaves it first",
        leaveRemote.invokes == leaveBefore + 1, leaveRemote.invokes - leaveBefore)
    check("the shop snapshot is requested after the room exit",
        #order == 2 and order[1] == "leave" and order[2] == "shop", table.concat(order, ","))
    check("the exited room shows the browser behind the shop", Env.lobbyOpen == true)
    check("the browser loads tables behind the shop", getTablesCalls == 1, getTablesCalls)
    check("a shop snapshot opens the panel", Env.shopSnapshots
        and #Env.shopSnapshots == 1 and Env.shopSnapshots[1].snapshot == snapshot
        and Env.shopSnapshots[1].open == true)
    check("a successful snapshot refreshes the owned-items summary",
        Env.myItemsCalls == 1 and Env.myItems == snapshot, Env.myItemsCalls)
    check("a successful snapshot clears no message", Env.shopMessages == nil)

    -- The shop already left the old room. A RoundState that was in flight before
    -- the seat was released must not pull the player back into that room.
    local lobbyGrid = Env.lastGrid
    fire("RoundState", {
        phase = "playing",
        roomId = 1,
        roundId = 99,
        roster = {},
        yourId = "u1",
        grid = { "stale-shop-round" },
    })
    check("a stale state cannot pull the shopper back into the old room",
        Env.lobbyOpen == true and Env.lastGrid == lobbyGrid)

    -- Already roomless (either the browser was open or the shop just left the
    -- room): opening the shop must not issue another leave request.
    local leaveAfterExit = leaveRemote.invokes
    Env.signals.shopRequested()
    check("a roomless shop does not leave again", leaveRemote.invokes == leaveAfterExit)
    check("a roomless shop still refreshes from the server", getShopCalls == 2, getShopCalls)
    check("opening a roomless shop keeps the browser behind it", Env.lobbyOpen == true)

    -- Closing while the snapshot request is in flight must not reopen the panel.
    Env.invokeResponses.GetShop = function()
        getShopCalls += 1
        Env.shopOpen = false
        return snapshot
    end
    local snapshotsBeforeClose = #Env.shopSnapshots
    Env.signals.shopRequested()
    check("closing during the request does not reopen the shop",
        #Env.shopSnapshots == snapshotsBeforeClose + 1
            and Env.shopSnapshots[#Env.shopSnapshots].open == false)

    Env.shopOpen = true
    local snapshotsBeforeFailures = #Env.shopSnapshots
    Env.invokeResponses.GetShop = { ok = false, reason = "not_loaded" }
    Env.signals.shopRequested()
    check("a not-loaded shop explains the wait", Env.shopMessages
        and Env.shopMessages[#Env.shopMessages] == "数据仍在加载，请稍后再试")
    check("a failed snapshot does not open the panel",
        #Env.shopSnapshots == snapshotsBeforeFailures, #Env.shopSnapshots)

    Env.invokeResponses.GetShop = function()
        error("remote failed")
    end
    Env.signals.shopRequested()
    check("a throwing shop remote is reported", Env.shopMessages
        and Env.shopMessages[#Env.shopMessages] == "读取道具失败，请稍后再试")

    Env.invokeResponses.GetShop = function()
        return nil
    end
    Env.signals.shopRequested()
    check("a non-table shop answer is reported", Env.shopMessages
        and Env.shopMessages[#Env.shopMessages] == "读取道具失败，请稍后再试")
    check("no failed request opened the panel",
        #Env.shopSnapshots == snapshotsBeforeFailures, #Env.shopSnapshots)

    -- A failed room exit must not leave the shop open over a live countdown.
    Env.invokeResponses.JoinTable = function()
        return { ok = true }
    end
    Env.signals.tableSelected("practice")
    check("a successful join returns to the room UI", Env.lobbyOpen == false)
    Env.shopOpen = true
    Env.shopClosed = nil
    local noticesBefore = #(Env.notices or {})
    Env.invokeResponses.LeaveTable = function()
        return { ok = false, reason = "not_loaded" }
    end
    local shopCallsBeforeFailedLeave = getShopCalls
    Env.signals.shopRequested()
    check("a failed room exit closes the shop", Env.shopClosed == true and Env.shopOpen == false)
    check("a failed room exit does not fetch a snapshot",
        getShopCalls == shopCallsBeforeFailedLeave, getShopCalls - shopCallsBeforeFailedLeave)
    check("a failed room exit explains why", Env.notices
        and #Env.notices == noticesBefore + 1
        and Env.notices[#Env.notices] == "数据仍在加载，请稍后再试", Env.notices and #Env.notices)
    check("a failed room exit leaves the old room UI alone", Env.lobbyOpen == false)

    local shopUpdate = {
        ok = true,
        items = { { id = "needle", stock = 2, free = 0, purchased = 2, carry = 2 } },
    }
    local updatesBefore = #Env.shopSnapshots
    fire("ShopUpdate", shopUpdate)
    check("a shop update refreshes without reopening",
        #Env.shopSnapshots == updatesBefore + 1
            and Env.shopSnapshots[#Env.shopSnapshots].snapshot == shopUpdate
            and Env.shopSnapshots[#Env.shopSnapshots].open == false)
    check("a shop update refreshes the owned-items summary",
        Env.myItems == shopUpdate)
end

---------------------------------------------------------------- 大厅“我的道具”
do
    local myItems = {
        ok = true,
        items = { { id = "needle", stock = 3, free = 1, purchased = 2, carry = 2 } },
    }
    Env.myItems = nil
    Env.myItemsCalls = 0
    Env.invokeResponses.LeaveTable = function()
        return { ok = true }
    end
    Env.invokeResponses.GetShop = function()
        return myItems
    end
    Env.signals.lobbyRequested()
    check("refreshing the lobby loads the owned items",
        Env.myItemsCalls == 1 and Env.myItems == myItems, Env.myItemsCalls)

    Env.invokeResponses.GetShop = { ok = false, reason = "not_loaded" }
    Env.signals.lobbyRequested()
    check("a failed inventory read clears the lobby list",
        Env.myItemsCalls == 2 and Env.myItems == nil, Env.myItemsCalls)

    Env.invokeResponses.GetShop = function()
        error("remote failed")
    end
    Env.signals.lobbyRequested()
    check("a throwing inventory read clears the lobby list",
        Env.myItemsCalls == 3 and Env.myItems == nil, Env.myItemsCalls)
end

---------------------------------------------------------------- 购买提示
do
    Env.purchasePrompts = nil
    Env.promptError = nil
    Env.shopMessages = nil

    Env.signals.purchaseRequested("123")
    Env.signals.purchaseRequested(nil)
    check("a non-numeric product never opens the prompt", Env.purchasePrompts == nil)

    Env.signals.purchaseRequested(91001)
    check("a purchase opens the native prompt", Env.purchasePrompts
        and #Env.purchasePrompts == 1
        and Env.purchasePrompts[1].productId == 91001)
    check("the prompt targets the local player", Env.purchasePrompts
        and Env.purchasePrompts[1].player ~= nil)
    check("the purchase prompt is left to Roblox", Env.shopMessages == nil)

    Env.promptError = "prompt failed"
    Env.signals.purchaseRequested(91002)
    check("a failing prompt is reported", Env.shopMessages
        and Env.shopMessages[#Env.shopMessages] == "无法打开购买窗口，请稍后再试")
    check("the failing prompt never reached Roblox",
        Env.purchasePrompts and #Env.purchasePrompts == 1, Env.purchasePrompts and #Env.purchasePrompts)
end

---------------------------------------------------------------- 输入序号、30Hz 命令流与本地预测
do
    local inputRemote = Env.remotes.Input
    local function sentCount()
        return #inputRemote.sent
    end

    -- A real 15x13 map: the predictor parses the rows into collision tiles.
    local rows = {}
    for y = 1, 13 do
        rows[y] = string.rep(".", 15)
    end

    -- The previous blocks left the browser open; rejoin a fresh practice room
    -- with a real playing snapshot.
    Env.invokeResponses.JoinTable = function()
        return { ok = true, roomId = 9 }
    end
    Env.syncResponse = {
        phase = "playing",
        roomId = 9,
        roundId = 500,
        roster = {},
        yourId = "u1",
        grid = rows,
        snapshot = {
            grid = rows,
            warmup = 0,
            tick = 1,
            players = {
                {
                    id = "u1",
                    x = 60,
                    y = 60,
                    fx = 60,
                    fy = 60,
                    ack = 0,
                    alive = true,
                    trapped = false,
                    speed = 144,
                },
            },
            bombs = {},
            crateSlides = {},
        },
    }
    Env.dirs = nil
    Env.signals.tableSelected("practice")
    check("the prediction test round is active", Env.inputEnabled == true)

    local before = sentCount()
    Env.renderStepped(1 / 60)
    check("the first playing frame sends exactly one command", sentCount() == before + 1,
        sentCount() - before)
    local first = inputRemote.sent[#inputRemote.sent]
    local payload = first and first[1]
    check("the input remote sends an envelope, not a bare array",
        type(payload) == "table" and type(payload.seq) == "number")
    check("the envelope carries the round id", payload and payload.roundId == 500,
        payload and payload.roundId)
    check("the envelope carries the direction list", payload and type(payload.dirs) == "table")
    local firstSeq = payload.seq

    Env.dirs = { "right" }
    for _ = 1, 8 do
        Env.renderStepped(1 / 60)
    end
    local commands = sentCount() - before
    check("input streams at 30Hz instead of once per frame",
        commands >= 4 and commands <= 5, commands)
    local latest = inputRemote.sent[#inputRemote.sent][1]
    check("sequence numbers increase", latest.seq > firstSeq, latest.seq)
    check("every command is scoped to the current round", latest.roundId == 500)
    check("every command carries the latest held directions", latest.dirs[1] == "right",
        latest.dirs[1])

    local rendered = Env.renderUpdate
    check("the renderer receives a predicted local position",
        rendered ~= nil and rendered.localPos ~= nil)
    check("the predicted position targets the local player",
        rendered and rendered.localPos and rendered.localPos.id == "u1")
    check("prediction starts from the authoritative position and advances",
        rendered and rendered.localPos and rendered.localPos.x >= 60
            and rendered.localPos.y == 60,
        rendered and rendered.localPos and rendered.localPos.x)

    ------------------------------------------------------------------ 有序放泡泡与音效
    Env.audioPlays = {}
    Env.audioFx = {}
    Env.dirs = nil
    -- Same round, now advertising the ordered placement capability.
    fire("RoundState", {
        phase = "playing",
        roomId = 9,
        roundId = 500,
        roster = {},
        yourId = "u1",
        grid = rows,
        placeSequenced = true,
    })

    local actionRemote = Env.remotes.Action
    local actionBefore = #(actionRemote.sent or {})
    local scanFrom = #inputRemote.sent
    local function newPlacePayloads(fromIndex)
        local found = {}
        for i = fromIndex + 1, #inputRemote.sent do
            local payload = inputRemote.sent[i][1]
            if type(payload) == "table" and payload.place == true then
                table.insert(found, payload)
            end
        end
        return found
    end

    Env.signals.placePressed()
    local placePayload = nil
    for _ = 1, 4 do
        Env.renderStepped(1 / 60)
        local found = newPlacePayloads(scanFrom)
        if found[1] then
            placePayload = found[1]
            break
        end
    end
    check("a place press rides in the next ordered command", placePayload ~= nil)
    check("the place press is not sent as a legacy action",
        #(actionRemote.sent or {}) == actionBefore)
    check("the local bomb plays the set sound once", #Env.audioPlays == 1
        and Env.audioPlays[1] == "bomb_set", #Env.audioPlays)

    -- The renderer receives the predicted bomb separately from the snapshot.
    Env.renderStepped(1 / 60)
    local renderedPlace = Env.renderUpdate
    check("the predicted bomb is passed to the renderer",
        renderedPlace and renderedPlace.predictedBombs
            and #renderedPlace.predictedBombs == 1,
        renderedPlace and renderedPlace.predictedBombs
            and #renderedPlace.predictedBombs)
    check("the predicted bomb has the ordered id",
        renderedPlace and renderedPlace.predictedBombs
            and renderedPlace.predictedBombs[1].id == "p" .. tostring(placePayload.seq))
    check("the snapshot bombs list is not modified",
        renderedPlace and renderedPlace.current
            and #(renderedPlace.current.bombs or {}) == 0)
    check("only the command that consumed the press carries place",
        #newPlacePayloads(scanFrom) == 1, #newPlacePayloads(scanFrom))
    local placeSeq = placePayload.seq

    -- Confirmation arrives before the Fx event: the removal must not drop the
    -- pending sound suppression.
    fire("Snapshot", {
        players = {
            {
                id = "u1",
                x = 60,
                y = 60,
                fx = 60,
                fy = 60,
                ack = placeSeq,
                alive = true,
                trapped = false,
                speed = 144,
                maxBombs = 1,
            },
        },
        bombs = {
            {
                id = 100,
                x = 1,
                y = 1,
                sx = 60,
                sy = 60,
                fuse = 75,
                remote = false,
                owner = "u1",
                seq = placeSeq,
                pass = { "u1" },
            },
        },
        crateSlides = {},
    })
    frame()
    check("confirmation removes the predicted bomb from the renderer",
        Env.renderUpdate and Env.renderUpdate.predictedBombs
            and #Env.renderUpdate.predictedBombs == 0)
    local fxBefore = #Env.audioFx
    fire("Fx", { kind = "bomb_set", ownerId = "u1", seq = placeSeq })
    check("a server sound for an already-confirmed prediction is suppressed",
        #Env.audioFx == fxBefore, #Env.audioFx - fxBefore)
    fire("Fx", { kind = "bomb_set", ownerId = "u2", seq = placeSeq })
    fire("Fx", { kind = "bomb_set", ownerId = "u1" })
    check("other players' and unsequenced sounds still reach Audio.onFx",
        #Env.audioFx == fxBefore + 2, #Env.audioFx - fxBefore)

    -- Move the local player off the confirmed bomb, then place again and let the
    -- Fx arrive first. The confirmation afterwards must still clean up.
    scanFrom = #inputRemote.sent
    fire("Snapshot", {
        players = {
            {
                id = "u1",
                x = 140,
                y = 60,
                fx = 140,
                fy = 60,
                ack = placeSeq,
                alive = true,
                trapped = false,
                speed = 144,
                maxBombs = 1,
            },
        },
        bombs = {},
        crateSlides = {},
    })
    Env.dirs = nil
    Env.signals.placePressed()
    local secondPlace = nil
    for _ = 1, 4 do
        Env.renderStepped(1 / 60)
        local found = newPlacePayloads(scanFrom)
        if found[1] then
            secondPlace = found[1]
            break
        end
    end
    check("a second placement is ordered", secondPlace ~= nil)
    check("the second local bomb plays one more sound", #Env.audioPlays == 2)
    fxBefore = #Env.audioFx
    fire("Fx", { kind = "bomb_set", ownerId = "u1", seq = secondPlace.seq })
    check("an early server sound for a live prediction is suppressed",
        #Env.audioFx == fxBefore)
    fire("Snapshot", {
        players = {
            {
                id = "u1",
                x = 140,
                y = 60,
                fx = 140,
                fy = 60,
                ack = secondPlace.seq,
                alive = true,
                trapped = false,
                speed = 144,
                maxBombs = 1,
            },
        },
        bombs = {
            {
                id = 101,
                x = 3,
                y = 1,
                sx = 140,
                sy = 60,
                fuse = 75,
                remote = false,
                owner = "u1",
                seq = secondPlace.seq,
                pass = { "u1" },
            },
        },
        crateSlides = {},
    })
    frame()
    check("the second confirmation clears the predicted list",
        Env.renderUpdate and Env.renderUpdate.predictedBombs
            and #Env.renderUpdate.predictedBombs == 0)

    -- Old servers do not advertise placeSequenced: use the immediate Action.
    fire("RoundState", {
        phase = "playing",
        roomId = 9,
        roundId = 500,
        roster = {},
        yourId = "u1",
        grid = rows,
    })
    local actionCount = #(actionRemote.sent or {})
    scanFrom = #inputRemote.sent
    Env.signals.placePressed()
    check("the legacy server gets the immediate place action",
        #(actionRemote.sent or {}) == actionCount + 1)
    local legacyAction = actionRemote.sent[#actionRemote.sent]
    check("the legacy action is the old place string", legacyAction and legacyAction[1] == "place")
    for _ = 1, 3 do
        Env.renderStepped(1 / 60)
    end
    check("the legacy path never sets a pending ordered place",
        #newPlacePayloads(scanFrom) == 0)

    -- A press that has not been consumed must not survive leaving the room.
    fire("RoundState", {
        phase = "playing",
        roomId = 9,
        roundId = 500,
        roster = {},
        yourId = "u1",
        grid = rows,
        placeSequenced = true,
    })
    Env.signals.placePressed()
    check("the pending press does not fire an action on a capable server",
        #(actionRemote.sent or {}) == actionCount + 1)
    Env.invokeResponses.LeaveTable = function()
        return { ok = true }
    end
    Env.signals.lobbyRequested()

    -- Rejoin and make sure the consumed/cleared press cannot leak into the new
    -- round's first command.
    Env.invokeResponses.JoinTable = function()
        return { ok = true, roomId = 10 }
    end
    Env.syncResponse = {
        phase = "playing",
        roomId = 10,
        roundId = 501,
        roster = {},
        yourId = "u1",
        grid = rows,
        placeSequenced = true,
        snapshot = {
            grid = rows,
            warmup = 0,
            tick = 1,
            players = {
                {
                    id = "u1",
                    x = 60,
                    y = 60,
                    fx = 60,
                    fy = 60,
                    ack = 0,
                    alive = true,
                    trapped = false,
                    speed = 144,
                },
            },
            bombs = {},
            crateSlides = {},
        },
    }
    scanFrom = #inputRemote.sent
    Env.signals.tableSelected("practice")
    Env.renderStepped(1 / 60)
    local afterRejoin = inputRemote.sent[#inputRemote.sent][1]
    check("leaving clears a pending place before the next round",
        afterRejoin and afterRejoin.place == nil)
    check("the next round can still send commands", #inputRemote.sent > scanFrom)

    -- The server snapshot is still authoritative for everyone else; the local
    -- override must disappear as soon as the player leaves the room.
    Env.invokeResponses.LeaveTable = function()
        return { ok = true }
    end
    Env.signals.lobbyRequested()
    local leftAt = sentCount()
    Env.renderStepped(1 / 30)
    Env.renderStepped(1 / 30)
    check("leaving the room stops the input stream", sentCount() == leftAt,
        sentCount() - leftAt)
    local afterLeave = Env.renderUpdate
    check("leaving the room drops the predicted override",
        afterLeave ~= nil and afterLeave.localPos == nil)
end

TestLib.finish()
