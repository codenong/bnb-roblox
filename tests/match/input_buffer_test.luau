-- Direct Room tests for the sequenced movement protocol: the 1-2 tick input
-- buffer, acknowledgements, queue bounds, round scoping and the extra snapshot
-- fields client prediction needs.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Room = require("./Room")
local PlayerService = require("./PlayerService")

local nextUserId = 9500
local function addRecord(name: string)
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = name,
    })
end

local alice = addRecord("InputAlice")
local room = Room.new({
    id = 601,
    mode = "practice",
    maxPlayers = 2,
    fillBots = true,
    waitingTicks = 1,
    resultsTicks = 4,
})
room:addMember(alice)
room:step()

check("the test round started", room:getPhase() == "playing", room:getPhase())
local roundId = room:getSync(alice).roundId

local function player()
    return room.game.players[alice.id]
end

local function payload(seq, dirs, rid)
    return { seq = seq, roundId = rid or roundId, dirs = dirs }
end

local function queue()
    local state = room.inputQueues[alice.id]
    return if state then state.queue else {}
end

local function queuedSeq()
    local state = room.inputQueues[alice.id]
    return if state then state.lastQueued else 0
end

---------------------------------------------------------------- 兼容旧格式

room:setInput(alice, { "right" })
check("an unsequenced array still applies immediately", player().dirs[1] == "right",
    player().dirs[1])
check("legacy input does not touch the ack", player().ack == 0)

---------------------------------------------------------------- 1–2 tick 缓冲

room:setInput(alice, payload(1, { "left" }))
check("a sequenced command is not applied on arrival", player().dirs[1] == "right")

room:step()
check("one queued command waits for a second or the timeout", player().dirs[1] == "right")

room:step()
check("a lone command applies after the buffer timeout", player().dirs[1] == "left",
    player().dirs[1])
check("the ack follows the applied sequence", player().ack == 1, player().ack)

room:setInput(alice, payload(2, { "up" }))
room:setInput(alice, payload(3, { "down" }))
room:step()
check("a full buffer applies the oldest command first",
    player().ack == 2 and player().dirs[#player().dirs] == "up",
    tostring(player().ack) .. ":" .. table.concat(player().dirs, ","))
room:step()
check("the second command waits its turn", player().ack == 2, player().ack)
room:setInput(alice, payload(4, { "left" }))
room:step()
check("a continuous stream applies one command per tick",
    player().ack == 3 and player().dirs[#player().dirs] == "down", player().ack)

---------------------------------------------------------------- 拒绝乱序 / 旧局 / 非法序号

local queuedBefore = #queue()
room:setInput(alice, payload(4, { "right" }))
check("a duplicate sequence is ignored", #queue() == queuedBefore, #queue())
room:setInput(alice, payload(5, { "up" }, roundId - 1))
check("a previous-round command is ignored", #queue() == queuedBefore, #queue())
room:setInput(alice, payload(0, { "up" }))
room:setInput(alice, payload(-3, { "up" }))
room:setInput(alice, payload(1.5, { "up" }))
room:setInput(alice, payload(math.huge, { "up" }))
room:setInput(alice, payload(0 / 0, { "up" }))
room:setInput(alice, payload("6", { "up" }))
check("invalid sequences are ignored",
    #queue() == queuedBefore and queuedSeq() == 4, tostring(queuedSeq()))

local stranger = addRecord("InputStranger")
room:setInput(stranger, payload(1, { "left" }))
check("a non-member cannot queue input", room.inputQueues[stranger.id] == nil)

room:setInput(alice, payload(5, { "up" }))
check("the next valid sequence is accepted", #queue() == queuedBefore + 1, #queue())

---------------------------------------------------------------- 队列上限

for seq = 6, 25 do
    room:setInput(alice, payload(seq, { "right" }))
end
local capped = queue()
check("the queue cannot grow without bound", #capped == Constants.INPUT_QUEUE_LIMIT,
    #capped)
check("the newest command is kept", capped[#capped].seq == 25, capped[#capped].seq)
check("the oldest commands are dropped",
    capped[1].seq == 25 - Constants.INPUT_QUEUE_LIMIT + 1, capped[1].seq)

for _ = 1, Constants.INPUT_QUEUE_LIMIT + 1 do
    room:step()
end
check("draining the capped queue reaches the newest sequence",
    player().ack == 25, player().ack)
check("the drained queue is empty", #queue() == 0, #queue())

---------------------------------------------------------------- 快照字段

local snapshot = room.game:snapshot()
local entry = nil
for _, candidate in ipairs(snapshot.players) do
    if candidate.id == alice.id then
        entry = candidate
        break
    end
end
check("the snapshot includes the local player", entry ~= nil)
check("snapshots carry the applied sequence", entry and entry.ack == 25,
    entry and entry.ack)
check("snapshots carry a sub-pixel position",
    entry and type(entry.fx) == "number" and type(entry.fy) == "number")

room.game.warmup = 0
check("a bomb can be placed after warmup", room.game:placeBomb(alice.id, false))
local bombSnapshot = room.game:snapshot()
local bomb = bombSnapshot.bombs[1]
check("the bomb is serialized", bomb ~= nil)
check("bomb pass lists are serialized for prediction", bomb and type(bomb.pass) == "table")
local passesAlice = false
for _, id in ipairs(bomb and bomb.pass or {}) do
    if id == alice.id then
        passesAlice = true
    end
end
check("the owner's bomb carries its pass list", passesAlice)

---------------------------------------------------------------- 地图版本

-- gridVer rides with every grid-bearing snapshot so the client can apply map
-- changes monotonically under reordering; it is omitted with the rows.
room.game.grid[2][3] = 2 -- Map.SOFT, an interior cell of the border-only map
room.game.gridVer += 1
local gridSnapshot = room.game:snapshot()
check("a map change rides with grid rows", gridSnapshot.grid ~= nil)
check("grid rows carry the map version", gridSnapshot.gridVer == room.game.gridVer,
    gridSnapshot.gridVer)
check("the map version is omitted without grid rows", room.game:snapshot().gridVer == nil)

local state = room:_buildState(alice)
check("RoundState carries the current map", type(state.grid) == "table")
check("RoundState carries the map version", state.gridVer == room.game.gridVer,
    state.gridVer)

---------------------------------------------------------------- 新一局重置

room:resetForWaiting()
room:step()
check("a new round starts after the reset", room:getPhase() == "playing")
check("the previous round's queue was cleared", room.inputQueues[alice.id] == nil)

local newRoundId = room:getSync(alice).roundId
check("the new round has a new id", newRoundId ~= roundId)
room:setInput(alice, payload(26, { "down" }, newRoundId))
room:step()
room:step()
check("the new round accepts the next sequence", player().ack == 26, player().ack)

-- A late command from the finished round must not leak into the new one.
room:setInput(alice, payload(27, { "left" }, roundId))
check("a stale-round command after the reset is ignored", #queue() == 0, #queue())

TestLib.finish()
