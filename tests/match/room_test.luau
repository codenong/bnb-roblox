-- Direct Room tests: practice composition, snapshot/result audience and
-- independent lifecycle. Loaded by tests/run.sh from tests/build/match.

local TestLib = require("./testlib")
local check = TestLib.check

local Room = require("./Room")
local PlayerService = require("./PlayerService")
local Net = require("./Net")
local TestEnv = require("./TestEnv")

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

---------------------------------------------------------------- 选角在倒计时最后几秒锁定

do
    local Constants = require("./Constants")
    local erin = addRecord("Erin")
    local frank = addRecord("Frank")

    -- 100-tick countdown, selection locked for the last 30 ticks.
    local room = Room.new({
        id = 104,
        mode = "practice",
        maxPlayers = 2,
        fillBots = true,
        waitingTicks = 100,
        charLockTicks = 30,
        resultsTicks = 4,
    })
    room:addMember(erin)
    check("unlocked right after joining", room:getSync(erin).charLocked == false)

    -- Advance to 31 ticks left: still selectable.
    for _ = 1, 69 do
        room:step()
    end
    check("unlocked with 31 ticks left", room:isCharLocked() == false)
    check("can switch character before the lock", room:selectChar(erin, "haidao") == true)
    check("switch was applied", erin.char == "haidao", erin.char)

    -- The tick that reaches the lock window must be announced to the client.
    Net.reset()
    room:step()
    check("locked once 30 ticks remain", room:isCharLocked() == true)
    check("lock start is broadcast to members", Net.sentCount(erin, "RoundState") >= 1, Net.sentCount(erin, "RoundState"))
    check("state carries charLocked", room:getSync(erin).charLocked == true)
    check("locked state still reports the waiting countdown", room:getSync(erin).phase == "waiting")

    check("selection is rejected while locked", room:selectChar(erin, "baobao") == false)
    check("rejected selection changes nothing", erin.char == "haidao", erin.char)

    -- Still locked on every remaining tick, and the round starts with the locked pick.
    local lockedEveryTick = true
    for _ = 1, 29 do -- 30 ticks remain when the lock starts; the 30th step starts the round
        room:step()
        if not room:isCharLocked() then
            lockedEveryTick = false
        end
    end
    check("stays locked until the round starts", lockedEveryTick)
    room:step()
    local started = room:getSync(erin)
    check("round starts", started.phase == "playing", started.phase)
    check("locked pick is the one that plays", started.roster[1].char == "haidao", started.roster[1].char)
    check("not locked once playing", started.charLocked == false)

    -- Back in the next waiting phase everything is selectable again.
    room:finishRound()
    for _ = 1, 4 do
        room:step()
    end
    local waiting = room:getSync(erin)
    check("next waiting phase is unlocked", waiting.phase == "waiting" and waiting.charLocked == false, waiting.phase)
    check("selection works again", room:selectChar(erin, "baobao") == true)
    room:removeMember(erin)

    -- Someone joining during the lock window restarts the countdown and unlocks.
    local room2 = Room.new({
        id = 105,
        mode = "versus",
        maxPlayers = 2,
        fillBots = false,
        waitingTicks = 100,
        charLockTicks = 30,
    })
    local gina = addRecord("Gina")
    room2:addMember(frank)
    room2:addMember(gina)
    for _ = 1, 75 do
        room2:step()
    end
    check("versus table locked near the end of its countdown", room2:isCharLocked() == true)
    room2:removeMember(gina)
    check("a player leaving cancels the countdown and the lock", room2:isCharLocked() == false)
    check("selection is possible again after the countdown resets", room2:selectChar(frank, "haidao") == true)
    room2:removeMember(frank)

    -- Rooms with a very short wait (tests, tuning) must never start locked.
    local quick = Room.new({ id = 106, mode = "practice", maxPlayers = 2, fillBots = true, waitingTicks = 1 })
    local hank = addRecord("Hank")
    quick:addMember(hank)
    check("1-tick countdown is never locked", quick:isCharLocked() == false)
    quick:removeMember(hank)

    -- Default configuration: 3 seconds of a 10 second countdown.
    local defaults = Room.new({ id = 107, mode = "practice", maxPlayers = 2, fillBots = true })
    local ivan = addRecord("Ivan")
    defaults:addMember(ivan)
    for _ = 1, Constants.WAITING_TICKS - Constants.CHAR_LOCK_TICKS - 1 do
        defaults:step()
    end
    check("default: unlocked just before the last 3 seconds", defaults:isCharLocked() == false)
    defaults:step()
    check("default: locked for the last 3 seconds", defaults:isCharLocked() == true)
    check("default: lock window is 3 seconds", Constants.CHAR_LOCK_SECONDS == 3 and Constants.CHAR_LOCK_TICKS == 3 * Constants.TICK_RATE)
    defaults:removeMember(ivan)
end

---------------------------------------------------------------- 结算回调

do
    local settledCalls = 0
    local settledMembers, settledResult, settledContext
    local jack = PlayerService.add({
        UserId = 9900,
        DisplayName = "Jack",
    })
    local room = Room.new({
        id = 108,
        mode = "practice",
        maxPlayers = 2,
        fillBots = true,
        waitingTicks = 1,
        resultsTicks = 4,
        onSettled = function(members, result, context)
            settledCalls += 1
            settledMembers = members
            settledResult = result
            settledContext = context
        end,
    })
    room:addMember(jack)
    room:step()
    room:finishRound()

    check("settlement hook is called once", settledCalls == 1, settledCalls)
    check("settlement receives the result", settledResult == room.lastResult)
    check("settlement receives a member copy", settledMembers and settledMembers[1] == jack)
    check("settlement context has room/mode/round", settledContext
        and settledContext.roomId == 108
        and settledContext.mode == "practice"
        and settledContext.roundId == room.roundId)

    table.remove(settledMembers, 1)
    check("changing the member copy does not change the room", #room.members == 1, #room.members)
    room:finishRound()
    check("settlement hook is not called twice", settledCalls == 1, settledCalls)
    room:removeMember(jack)
end

do
    local beforeWarnings = #TestEnv.warnings
    local kate = PlayerService.add({
        UserId = 9901,
        DisplayName = "Kate",
    })
    local room = Room.new({
        id = 109,
        mode = "practice",
        maxPlayers = 2,
        fillBots = true,
        waitingTicks = 1,
        resultsTicks = 4,
        onSettled = function()
            error("settlement hook failure")
        end,
    })
    room:addMember(kate)
    room:step()
    TestEnv.silent = true
    room:finishRound()
    TestEnv.silent = false
    check("a failing settlement hook still ends the room", room:getPhase() == "ended", room:getPhase())
    check("a failing settlement hook is logged", #TestEnv.warnings > beforeWarnings)
    room:removeMember(kate)
end

---------------------------------------------------------------- 选角持久化到档案

do
    local profile = { settings = { char = "haidao" } }
    local player = {
        UserId = 9902,
        DisplayName = "Lena",
    }
    local record = PlayerService.add(player, profile)
    check("profile character is restored", record.char == "haidao", record.char)
    check("profile is attached to the record", record.profile == profile)

    check("setChar accepts a valid character", PlayerService.setChar(player, "baobao") == true)
    check("setChar updates the record", record.char == "baobao")
    check("setChar updates the profile", profile.settings.char == "baobao")

    local invalidProfile = { settings = { char = "not-a-character" } }
    local invalidPlayer = {
        UserId = 9903,
        DisplayName = "Mia",
    }
    local invalidRecord = PlayerService.add(invalidPlayer, invalidProfile)
    check("invalid saved character falls back", invalidRecord.char == "baobao", invalidRecord.char)
    check("invalid saved character is repaired in the profile", invalidProfile.settings.char == "baobao")

    PlayerService.remove(player)
    PlayerService.remove(invalidPlayer)
end

TestLib.finish()
