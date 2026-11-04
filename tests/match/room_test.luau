-- Direct Room tests: practice composition, snapshot/result audience and
-- independent lifecycle. Loaded by tests/run.sh from tests/build/match.

local TestLib = require("./testlib")
local check = TestLib.check

local Room = require("./Room")
local PlayerService = require("./PlayerService")
local Net = require("./Net")

local nextUserId = 7000
local function addRecord(name: string)
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = name,
    })
end

local function countBots(roster)
    local bots = 0
    for _, entry in ipairs(roster or {}) do
        if entry.isBot then
            bots += 1
        end
    end
    return bots
end

local alice = addRecord("Alice")
local bob = addRecord("Bob")
local cara = addRecord("Cara")

-- A and B are two independent 1v1 practice rooms. Cara joins A mid-round as a
-- spectator; that exercises the member/audience split directly.
local roomA = Room.new({
    id = 101,
    mode = "practice",
    maxPlayers = 2,
    fillBots = true,
    waitingTicks = 1,
    resultsTicks = 4,
})
local roomB = Room.new({
    id = 102,
    mode = "practice",
    maxPlayers = 2,
    fillBots = true,
    waitingTicks = 1,
    resultsTicks = 4,
})

roomA:addMember(alice)
roomB:addMember(bob)
Net.reset()
roomA:step()
roomB:step()

---------------------------------------------------------------- 1v1 组合

local playingA = roomA:getSync(alice)
local playingB = roomB:getSync(bob)
check("A starts playing", playingA and playingA.phase == "playing", playingA and playingA.phase)
check("B starts playing", playingB and playingB.phase == "playing", playingB and playingB.phase)
check("A is exactly two players", playingA and #playingA.roster == 2, playingA and #playingA.roster)
check("A has exactly one bot", playingA and countBots(playingA.roster) == 1, playingA and countBots(playingA.roster))
check("A human is a participant", playingA and playingA.yourId == alice.id and not playingA.spectating)
check("B has its own two players", playingB and #playingB.roster == 2 and playingB.yourId == bob.id)
check("rooms have different state", playingA and playingB and playingA.roomId ~= playingB.roomId)

---------------------------------------------------------------- 中途观战：只加入目标房间

roomA:addMember(cara)
local spectator = roomA:getSync(cara)
check("Cara sees A as a spectator", spectator and spectator.roomId == roomA.id and spectator.spectating == true)
check("spectator has no yourId", spectator and spectator.yourId == nil)
check("spectator sees the two players", spectator and #spectator.roster == 2)
check("B membership is unchanged", roomB:getMemberCount() == 1, roomB:getMemberCount())

Net.reset()
roomA:step()
roomB:step()
roomA:step()
roomB:step()
check("Alice receives A snapshot", Net.sentCount(alice, "Snapshot") == 1, Net.sentCount(alice, "Snapshot"))
check("Cara receives A snapshot", Net.sentCount(cara, "Snapshot") == 1, Net.sentCount(cara, "Snapshot"))
check("Bob receives only B snapshot", Net.sentCount(bob, "Snapshot") == 1, Net.sentCount(bob, "Snapshot"))
check("snapshots are never broadcast", Net.broadcastCount("Snapshot") == 0, Net.broadcastCount("Snapshot"))

---------------------------------------------------------------- 结算也按房间隔离

Net.reset()
roomA:finishRound()
check("A is ended", roomA:getPhase() == "ended", roomA:getPhase())
check("B keeps playing", roomB:getPhase() == "playing", roomB:getPhase())
check("A result reaches Alice", Net.sentCount(alice, "RoundEnd") == 1, Net.sentCount(alice, "RoundEnd"))
check("A result reaches spectator Cara", Net.sentCount(cara, "RoundEnd") == 1, Net.sentCount(cara, "RoundEnd"))
check("A result does not reach Bob", Net.sentCount(bob, "RoundEnd") == 0, Net.sentCount(bob, "RoundEnd"))
check("RoundEnd is never broadcast", Net.broadcastCount("RoundEnd") == 0, Net.broadcastCount("RoundEnd"))
check("ended sync has result", roomA:getSync(alice).lastResult ~= nil)
check("ended sync has final snapshot", roomA:getSync(alice).snapshot ~= nil)

---------------------------------------------------------------- 结算后回到等待，下一局

for _ = 1, 4 do
    roomA:step()
end
local waitingA = roomA:getSync(alice)
check("A returns to waiting", waitingA and waitingA.phase == "waiting", waitingA and waitingA.phase)
check("spectator joins the next waiting roster", waitingA and #waitingA.roster == 2, waitingA and #waitingA.roster)
check("B still independent", roomB:getPhase() == "playing", roomB:getPhase())

roomA:step()
local nextA = roomA:getSync(alice)
check("A starts the next round", nextA and nextA.phase == "playing", nextA and nextA.phase)
check("next round uses both humans", nextA and #nextA.roster == 2 and countBots(nextA.roster) == 0,
    nextA and #nextA.roster)

---------------------------------------------------------------- 成员清理

roomA:removeMember(cara)
local afterCara = roomA:getSync(alice)
check("A ends after its spectator leaves a 1-human round", afterCara and afterCara.phase == "ended",
    afterCara and afterCara.phase)
check("B still playing", roomB:getPhase() == "playing", roomB:getPhase())
roomA:removeMember(alice)
roomB:removeMember(bob)
check("A is empty", roomA:isEmpty())
check("B is empty", roomB:isEmpty())

---------------------------------------------------------------- 引擎仍支持 N 人配置

local dave = addRecord("Dave")
local roomN = Room.new({
    id = 103,
    mode = "legacy",
    maxPlayers = 6,
    fillBots = true,
    waitingTicks = 1,
})
roomN:addMember(dave)
Net.reset()
roomN:step()
local full = roomN:getSync(dave)
check("N-player room still starts", full and full.phase == "playing", full and full.phase)
check("N-player room fills six slots", full and #full.roster == 6, full and #full.roster)
check("N-player room uses five bots", full and countBots(full.roster) == 5, full and countBots(full.roster))
roomN:removeMember(dave)
check("N-player room cleans up", roomN:isEmpty())

TestLib.finish()
