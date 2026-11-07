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

TestLib.finish()
