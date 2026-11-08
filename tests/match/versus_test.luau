-- Versus table state machine, spectators, forfeits and table registry.
-- Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local ProfileSchema = require("./ProfileSchema")
local Room = require("./Room")
local VersusStats = require("./VersusStats")

local nextUserId = 12000

local function newProfile()
    return ProfileSchema.normalize(ProfileSchema.newProfile())
end

local function addRecord(name: string, profile)
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = name,
    }, profile)
end

local function addPlayer(name: string, profile)
    nextUserId += 1
    local player = {
        UserId = nextUserId,
        DisplayName = name,
    }
    if profile then
        PlayerService.add(player, profile)
    else
        PlayerService.add(player)
    end
    MatchService.onPlayerAdded(player)
    return player
end

local function versusRoom(opts)
    opts = opts or {}
    return Room.new({
        id = opts.id or 500,
        mode = "versus",
        maxPlayers = Constants.VERSUS_PLAYERS,
        fillBots = false,
        maxSpectators = opts.maxSpectators or Constants.VERSUS_SPECTATORS,
        waitingTicks = opts.waitingTicks or Constants.WAITING_TICKS,
        charLockTicks = opts.charLockTicks or Constants.CHAR_LOCK_TICKS,
        resultsTicks = opts.resultsTicks or Constants.RESULTS_TICKS,
        onSettled = opts.onSettled,
    })
end

local function advance(room, ticks)
    for _ = 1, ticks do
        room:step()
    end
end

local function advanceUntilEnded(room, limit: number): number
    local ticks = 0
    while room:getPhase() ~= "ended" and ticks < (limit or 1000) do
        room:step()
        ticks += 1
    end
    return ticks
end

---------------------------------------------------------------- 满员倒计时、取消、锁定、手动选角

do
    local pa, pb = newProfile(), newProfile()
    local alice = addRecord("Alice", pa)
    local bob = addRecord("Bob", pb)
    local settled = 0
    local room = versusRoom({
        id = 501,
        onSettled = function()
            settled += 1
        end,
    })

    room:addMember(alice)
    local lonely = room:getSync(alice)
    check("a versus table waits for a second player", lonely
        and lonely.phase == "waiting"
        and lonely.waitingForPlayers == true
        and lonely.endsIn == 0)
    check("one seated player is not enough", room:isCountdownReady() == false)
    advance(room, 50)
    check("the countdown does not run while waiting for players", room:getWaitingSeconds() == 10,
        room:getWaitingSeconds())

    room:addMember(bob)
    local full = room:getSync(alice)
    check("two players fill the table", room:isFull() and full.seatCount == 2)
    check("a full table starts its countdown", full.endsIn == 10 and full.waitingForPlayers == false)
    advance(room, 5 * Constants.TICK_RATE)
    check("character selection is open during the countdown", room:isCharLocked() == false)
    check("character can be changed before the lock", room:selectChar(alice, "haidao") == true)
    advance(room, 2 * Constants.TICK_RATE)
    check("the last 3 seconds lock character selection", room:isCharLocked() == true)
    check("a locked character pick is rejected", room:selectChar(alice, "baobao") == false)

    -- Leaving during the countdown cancels it and resets the table without a
    -- result or settlement.
    room:removeMember(bob)
    local cancelled = room:getSync(alice)
    check("leaving the countdown cancels it", cancelled.phase == "waiting"
        and cancelled.endsIn == 0
        and room:isCharLocked() == false)
    check("the empty seat is available again", room:getSeatCount() == 1)
    check("cancelling the countdown is not a forfeit", settled == 0, settled)
    check("cancelling does not start a round", room:getPhase() == "waiting")

    -- Rejoining starts a fresh countdown, and the roster locks when it ends.
    room:addMember(bob)
    check("rejoining restarts the countdown", room:getSync(alice).endsIn == 10)
    advance(room, Constants.WAITING_TICKS - 1)
    check("the room is still waiting one tick before the start", room:getPhase() == "waiting")
    advance(room, 1)
    local playing = room:getSync(alice)
    check("a full table starts its round", playing.phase == "playing", playing.phase)
    check("both humans play, with no bot", #playing.roster == 2 and playing.roster[1].isBot == false and playing.roster[2].isBot == false)
    check("the locked pick is the one in the round", playing.roster[1].char == "haidao",
        playing.roster[1].char)
    check("the roster is locked once playing", room:selectChar(alice, "baobao") == false)

    -- A spectator after the start is read-only and does not change the roster.
    local cara = addRecord("Cara")
    room:addMember(cara)
    local watched = room:getSync(cara)
    check("a late joiner becomes a spectator", watched.spectating == true and watched.yourId == nil)
    check("a spectator does not extend the playing roster", #room:getSync(alice).roster == 2)

    local alicePlayer = room.game.players[alice.id]
    local bobPlayer = room.game.players[bob.id]
    local ax, ay = alicePlayer.x, alicePlayer.y
    local bx, by = bobPlayer.x, bobPlayer.y
    room:setInput(cara, { "up" })
    room:action(cara, "place")
    advance(room, 3)
    check("spectator input does not move a participant", alicePlayer.x == ax and alicePlayer.y == ay
        and bobPlayer.x == bx and bobPlayer.y == by)
    check("spectator action cannot place a bomb", #room.game.bombs == 0, #room.game.bombs)

    -- Both participants act, then Bob drops. The short game still settles as a
    -- win/loss because leaving is a forfeit.
    room:setInput(alice, { "up" })
    room:setInput(bob, { "up" })
    local context
    room.onSettled = function(members, result, ctx)
        settled += 1
        context = ctx
        VersusStats.apply(ctx, result)
    end
    room:removeMember(bob)
    local leftResult = room:getSync(alice).lastResult
    check("leaving during the round ends it", room:getPhase() == "ended")
    check("the player who stayed wins", leftResult and leftResult.winnerId == alice.id
        and leftResult.reason == "leave" and leftResult.draw == false)
    check("settlement keeps the leaver as a participant", context
        and #context.participants == 2
        and context.left[bob.id] == true
        and context.activity[alice.id] == true
        and context.activity[bob.id] == true)
    check("the leaver is recorded as a loss", pa.stats.versus.games == 1
        and pa.stats.versus.wins == 1
        and pb.stats.versus.games == 1
        and pb.stats.versus.losses == 1)
    check("settlement fires once for the forfeit", settled == 1, settled)

    -- Remove the spectator, then let the result finish into a fresh waiting
    -- state. One player is not enough to start again.
    room:removeMember(cara)
    advance(room, Constants.RESULTS_TICKS)
    local rematchWaiting = room:getSync(alice)
    check("the table returns to waiting after the result", rematchWaiting.phase == "waiting", rematchWaiting.phase)
    check("a one-player table does not start again", room:getSync(alice).endsIn == 0
        and room:isCountdownReady() == false)
    advance(room, 20)
    check("the lone player keeps waiting", room:getPhase() == "waiting")

    -- Bob rejoins: the rematch is automatic, with no ready button or host.
    local roundBefore = room.roundId
    room:addMember(bob)
    check("the rematch countdown starts when the seat fills", room:getSync(alice).endsIn == 10)
    advance(room, Constants.WAITING_TICKS)
    local rematch = room:getSync(alice)
    check("the rematch starts automatically", rematch.phase == "playing"
        and rematch.roundId == roundBefore + 1)
    check("the rematch has the same two humans", #rematch.roster == 2
        and rematch.roster[1].isBot == false and rematch.roster[2].isBot == false)

    -- A spectator never takes a seat, even when a participant leaves. The table
    -- waits for a new player; the audience stays read-only.
    room:addMember(cara)
    check("a spectator can watch a later round", room:getSync(cara).spectating == true)
    room:removeMember(bob)
    advance(room, Constants.RESULTS_TICKS)
    local waitingForSeat = room:getSync(alice)
    check("the open seat is not filled by a spectator",
        waitingForSeat.phase == "waiting"
        and waitingForSeat.endsIn == 0
        and room:getSeatCount() == 1
        and room:getSpectatorCount() == 1,
        waitingForSeat.endsIn)
    check("the spectator remains a spectator", room:getSync(cara).spectating == true)
    advance(room, Constants.WAITING_TICKS * 2)
    check("an underfilled table never starts", room:getPhase() == "waiting")

    -- Only a new joining player fills the seat; the existing spectator stays in
    -- the audience and does not join the round.
    local dan = addRecord("Dan")
    room:addMember(dan)
    check("a new player fills the open seat", room:getSeatCount() == 2
        and room:getSpectatorCount() == 1)
    check("the spectator is still not a participant", room:getSync(cara).spectating == true)
    check("the table countdown starts with two seated players", room:getSync(alice).endsIn == 10)
    advance(room, Constants.WAITING_TICKS)
    local filledRound = room:getSync(alice)
    check("the new player, not the spectator, plays the next round",
        filledRound.phase == "playing"
        and #filledRound.roster == 2
        and filledRound.roster[1].name == "Alice"
        and filledRound.roster[2].name == "Dan")
    check("the spectator still has no seat in the next round",
        room:getSync(cara).spectating == true)

    room:removeMember(alice)
    room:removeMember(dan)
    room:removeMember(cara)
end

---------------------------------------------------------------- 20 秒无操作判负，且不计战绩

do
    local pa, pb = newProfile(), newProfile()
    local alice = addRecord("Idle Alice", pa)
    local bob = addRecord("Idle Bob", pb)
    local summary
    local room = versusRoom({
        id = 502,
        waitingTicks = 1,
        resultsTicks = 3,
        onSettled = function(_members, result, ctx)
            summary = VersusStats.apply(ctx, result)
        end,
    })
    room:addMember(alice)
    room:addMember(bob)
    room:step()
    check("the no-action room is playing", room:getPhase() == "playing")

    advanceUntilEnded(room, 800)
    local result = room:getSync(alice).lastResult
    check("both idle players end the round", room:getPhase() == "ended")
    check("a double no-action round is a draw", result and result.draw == true and result.reason == "no_action")
    check("the no-action round is unrated", summary and summary.rated == false and summary.reason == "no_action", summary and summary.reason)
    check("no-action does not add a game", pa.stats.versus.games == 0 and pb.stats.versus.games == 0)
    room:removeMember(alice)
    room:removeMember(bob)
end

do
    local pa, pb = newProfile(), newProfile()
    local mover = addRecord("Mover", pa)
    local idler = addRecord("Idler", pb)
    local summary
    local room = versusRoom({
        id = 503,
        waitingTicks = 1,
        resultsTicks = 3,
        onSettled = function(_members, result, ctx)
            summary = VersusStats.apply(ctx, result)
        end,
    })
    room:addMember(mover)
    room:addMember(idler)
    room:step()
    room:setInput(mover, { "up" })
    advanceUntilEnded(room, 800)
    local result = room:getSync(mover).lastResult
    check("an active player beats an idle one", result and result.winnerId == mover.id
        and result.reason == "no_action")
    check("the idle player's round is unrated", summary and summary.rated == false and summary.reason == "no_action")
    check("the active player earns no stats from an idle opponent",
        pa.stats.versus.games == 0 and pb.stats.versus.games == 0)
    room:removeMember(mover)
    room:removeMember(idler)
end

---------------------------------------------------------------- 换桌 = 离开房间

do
    MatchService.init({ precreateVersus = false })

    local pa, pb, pc = newProfile(), newProfile(), newProfile()
    local alice = addPlayer("Leave Alice", pa)
    local bob = addPlayer("Leave Bob", pb)
    local watcher = addPlayer("Leave Watcher", pc)

    local practiceRoom = MatchService.getRoomFor(alice)
    check("a player starts in a practice room", practiceRoom and practiceRoom.mode == "practice")

    local ok, reason = MatchService.leaveTable(alice)
    check("leaving a practice room is accepted", ok == true, reason)
    check("the leaver has no room", MatchService.getRoomFor(alice) == nil)
    check("the empty practice room is removed", MatchService.getRoomCount() == 2,
        MatchService.getRoomCount())
    check("GetSync does not recreate practice while browsing", MatchService.getSync(alice) == nil)

    ok, reason = MatchService.leaveTable(alice)
    check("leaving again is idempotent", ok == true, reason)
    check("a repeat leave still has no room", MatchService.getRoomFor(alice) == nil)

    ok, reason = MatchService.joinPractice(alice)
    check("choosing practice seats the browsing player", ok == true
        and MatchService.getRoomFor(alice).mode == "practice", reason)
    check("choosing a mode clears the browsing state", MatchService.getSync(alice) ~= nil)

    -- A countdown is a room state, not a paused timer: the leaver's seat closes
    -- and the table returns to waiting for a second player.
    ok = MatchService.joinVersus(alice)
    MatchService.joinVersus(bob)
    local table = MatchService.getRoomFor(alice)
    check("both seats share one versus table", table and table == MatchService.getRoomFor(bob))
    check("the full table starts its countdown", MatchService.getSync(bob).endsIn == 10)

    ok, reason = MatchService.leaveTable(alice)
    check("leaving a versus countdown is accepted", ok == true, reason)
    check("the versus leaver has no room", MatchService.getRoomFor(alice) == nil)
    local remaining = MatchService.getSync(bob)
    check("the remaining seat sees its countdown cancelled",
        remaining.phase == "waiting" and remaining.endsIn == 0
        and remaining.seatCount == 1)
    check("the table remains open for a replacement", MatchService.getRoomFor(bob) == table)

    -- The reported bug: a hidden countdown kept running after "换桌" and pulled
    -- the player into a match. Stepping well past the original countdown must
    -- leave both the browsing player and the reduced table alone.
    for _ = 1, Constants.WAITING_TICKS do
        MatchService.step()
    end
    local stillWaiting = MatchService.getSync(bob)
    check("the cancelled countdown does not start without a second seat",
        stillWaiting.phase == "waiting" and stillWaiting.endsIn == 0)
    check("the browsing player is not pulled back by the old countdown",
        MatchService.getSync(alice) == nil and MatchService.getRoomFor(alice) == nil)

    -- A browsing player can choose a full table and spectate, but is never
    -- pulled back into their old room behind the browser.
    local dave = addPlayer("Leave Dave", newProfile())
    ok, reason = MatchService.joinVersus(dave, table.id)
    check("a replacement fills the open seat", ok == true
        and table:getSeatCount() == 2, reason)

    ok, reason = MatchService.joinVersus(watcher, table.id)
    check("a browsing player can choose to spectate", ok == true, reason)
    check("the spectator is not counted as a seat", table:getSeatCount() == 2
        and table:getSpectatorCount() == 1)
    ok, reason = MatchService.leaveTable(dave)
    check("a seated player can leave before the countdown ends", ok == true, reason)
    check("the freed seat does not auto-promote the spectator",
        table:getSeatCount() == 1 and table:getSpectatorCount() == 1
            and MatchService.getSync(watcher).spectating == true)

    ok, reason = MatchService.leaveTable(watcher)
    check("a spectator can leave the table too", ok == true, reason)
    check("leaving a spectator seat releases it", table:getSpectatorCount() == 0)
    check("the spectator stays roomless while browsing", MatchService.getSync(watcher) == nil)

    -- Rejoining quick play uses the open seat the leaver just freed.
    ok = MatchService.joinVersus(alice)
    check("quick join refills the open seat", ok == true
        and MatchService.getRoomFor(alice) == table)
    check("the rejoining player clears browsing", MatchService.getSync(alice) ~= nil)

    PlayerService.remove(alice)
    PlayerService.remove(bob)
    PlayerService.remove(dave)
    PlayerService.remove(watcher)
end

---------------------------------------------------------------- 多桌、换桌、观战与掉线

do
    local summaries = {}
    local settledContexts = {}
    MatchService.init({
        precreateVersus = false,
        onSettled = function(_members, result, ctx)
            local summary = VersusStats.apply(ctx, result)
            table.insert(summaries, summary)
            table.insert(settledContexts, ctx)
        end,
    })

    local pa, pb = newProfile(), newProfile()
    local pc, pd = newProfile(), newProfile()
    local a = addPlayer("A", pa)
    local b = addPlayer("B", pb)
    local c = addPlayer("C", pc)
    local d = addPlayer("D", pd)
    local e = addPlayer("E", newProfile())

    check("players start in independent practice rooms", MatchService.getRoomCount() == 5,
        MatchService.getRoomCount())

    local ok, reason, table1Id = MatchService.joinVersus(a)
    check("a player can open a versus table", ok == true, reason)
    local table1 = MatchService.getRoomFor(a)
    check("the new table has one seat", table1 and table1.mode == "versus" and table1:getSeatCount() == 1)

    ok = MatchService.joinVersus(b)
    check("the next player fills the open table instead of opening another", ok == true
        and MatchService.getRoomFor(b) == table1)
    local _, _, table2Id = MatchService.joinVersus(c)
    MatchService.joinVersus(d)
    check("a second full table is independent", table2Id ~= table1Id
        and MatchService.getRoomFor(c).id == table2Id
        and MatchService.getRoomFor(d).id == table2Id)

    local tables = MatchService.getTables()
    check("the browser lists both full tables", #tables == 2, #tables)
    check("tables are sorted by id", tables[1].id < tables[2].id)
    check("a table summary has its two seats", tables[1].seatCount == 2 and #tables[1].seats == 2)
    local seatName = tables[1].seats[1].name
    tables[1].seats[1].name = "tampered"
    check("table summaries are copies", table1:getSeatSummary()[1].name == seatName)

    -- A full table still allows spectators, up to its audience cap.
    ok, reason = MatchService.joinVersus(e, table1Id)
    check("a full table accepts a spectator", ok == true, reason)
    check("the spectator does not take a seat", table1:getSeatCount() == 2
        and table1:getSpectatorCount() == 1)
    local spectatorSync = MatchService.getSync(e)
    check("the spectator sees the table read-only", spectatorSync.spectating == true
        and spectatorSync.yourId == nil and spectatorSync.roomId == table1Id)

    ok = MatchService.joinVersus(e)
    check("quick join keeps a player at their current versus table", ok == true
        and MatchService.getRoomFor(e) == table1)
    ok, reason = MatchService.joinVersus(e, 99999)
    check("an unknown table is rejected", ok == false and reason == "no_table", reason)
    check("a failed table switch keeps the current seat", MatchService.getRoomFor(e) == table1)

    ok, reason = MatchService.joinPractice(e)
    check("a spectator can switch back to practice", ok == true, reason)
    local practiceRoom = MatchService.getRoomFor(e)
    check("practice is a separate room", practiceRoom and practiceRoom.mode == "practice"
        and practiceRoom.id ~= table1Id)
    check("the spectator slot is released", table1:getSpectatorCount() == 0)

    -- Below the table cap, quick join opens and fills new tables rather than
    -- sending the player straight to the audience.
    ok = MatchService.joinVersus(e)
    local table3 = MatchService.getRoomFor(e)
    check("quick join opens a new table while below the cap", ok == true
        and table3.mode == "versus" and table3 ~= practiceRoom
        and table3:getSeatCount() == 1)
    local f = addPlayer("F", newProfile())
    local g = addPlayer("G", newProfile())
    local h = addPlayer("H", newProfile())
    local i = addPlayer("I", newProfile())
    MatchService.joinVersus(f)
    MatchService.joinVersus(g)
    MatchService.joinVersus(h)
    check("four tables can be running", #MatchService.getTables() == 4
        and MatchService.getRoomFor(e) == MatchService.getRoomFor(f)
        and MatchService.getRoomFor(g) == MatchService.getRoomFor(h))

    ok = MatchService.joinVersus(i)
    check("quick join becomes a spectator once the cap is reached", ok == true
        and MatchService.getSync(i).spectating == true)
    check("quick join does not exceed the table cap", #MatchService.getTables() == 4,
        #MatchService.getTables())

    -- Let every table start. The players act so a later disconnect is rateable.
    for _ = 1, Constants.WAITING_TICKS do
        MatchService.step()
    end
    check("all tables are playing", MatchService.getRoomFor(a):getPhase() == "playing"
        and MatchService.getRoomFor(c):getPhase() == "playing"
        and MatchService.getRoomFor(e):getPhase() == "playing"
        and MatchService.getRoomFor(g):getPhase() == "playing")
    MatchService.setInput(a, { "up" })
    MatchService.setInput(b, { "up" })
    MatchService.setInput(c, { "up" })
    MatchService.setInput(d, { "up" })

    -- A disconnect is the same server path as leaving: remove from the room and
    -- settle immediately.
    local bRecord = PlayerService.remove(b)
    MatchService.onPlayerRemoving(b, bRecord)
    check("a disconnect ends the other participant's round", MatchService.getRoomFor(a):getPhase() == "ended")
    check("the disconnect is reported as a leave result",
        MatchService.getSync(a).lastResult.reason == "leave")
    check("the disconnect is rated as a win/loss",
        summaries[1] and summaries[1].rated == true
        and pa.stats.versus.wins == 1
        and pb.stats.versus.losses == 1)
    check("the leaver is still in settlement after disconnecting",
        settledContexts[1] and #settledContexts[1].participants == 2
        and settledContexts[1].left[bRecord.id] == true)
    check("the other table is unaffected", MatchService.getRoomFor(c):getPhase() == "playing")

    -- Leaving the ended table after the round is not a second settlement.
    local settledBefore = #summaries
    ok = MatchService.joinPractice(a)
    check("a player can leave a table after the result", ok == true)
    check("leaving after the result does not settle again", #summaries == settledBefore,
        #summaries - settledBefore)
    check("the player lands in a practice room", MatchService.getRoomFor(a).mode == "practice")
end

---------------------------------------------------------------- 重复颜色、观战者与同款锁定

do
    local alice = addRecord("ColorAlice", newProfile())
    local bob = addRecord("ColorBob", newProfile())
    local room = versusRoom({ id = 560, waitingTicks = 100, charLockTicks = 30 })
    room:addMember(alice)
    room:addMember(bob)

    check("the first player can choose red", room:selectColor(alice, "red") == true)
    check("the second player can choose the same red", room:selectColor(bob, "red") == true)
    check("duplicate colors are allowed in the roster",
        room:getSync(alice).roster[1].colorIndex == 0
            and room:getSync(alice).roster[2].colorIndex == 0)
    check("each player's state keeps their own color map",
        room:getSync(alice).selectedColor == "red" and room:getSync(bob).selectedColor == "red")

    -- A spectator can pick a color while waiting, but it never enters the roster.
    local cara = addRecord("ColorCara", newProfile())
    room:addMember(cara)
    check("the third player is a spectator", room:getSync(cara).spectating == true)
    check("a waiting spectator can change color", room:selectColor(cara, "purple") == true)
    check("the spectator's own state updates", room:getSync(cara).selectedColor == "purple")
    check("the spectator does not enter the roster",
        #room:getSync(alice).roster == 2 and room:getSync(alice).spectatorCount == 1)

    advance(room, 70)
    check("the versus table is locked", room:isCharLocked() == true)
    local aliceBefore = room:getSync(alice).selectedColor
    check("a seated player cannot change color while locked",
        room:selectColor(alice, "blue") == false)
    check("the locked seated color is unchanged", room:getSync(alice).selectedColor == aliceBefore)
    check("a spectator cannot change color while locked",
        room:selectColor(cara, "orange") == false)
    check("the locked spectator color is unchanged", cara.charColors.baobao == "purple")

    advance(room, 30)
    local playing = room:getSync(alice)
    check("the versus round starts with duplicate colors", playing.phase == "playing",
        playing.phase)
    check("both participants keep red in Game",
        room.game.players[alice.id].colorIndex == 0
            and room.game.players[bob.id].colorIndex == 0)
    check("the spectator is not a Game participant", room.game.players[cara.id] == nil)
    check("color selection is rejected while playing",
        room:selectColor(alice, "green") == false)
    check("the playing color is unchanged", room.game.players[alice.id].colorIndex == 0)
end

TestLib.finish()
