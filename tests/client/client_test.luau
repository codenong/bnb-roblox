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

TestLib.finish()
