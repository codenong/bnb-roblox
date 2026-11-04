-- Headless exercise of the room manager with lightweight stubs.
-- Loaded by tests/run.sh from tests/build/match.

local TestLib = require("./testlib")
local check = TestLib.check

local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local Net = require("./Net")

local nextUserId = 5000
local function addPlayer(name: string)
    nextUserId += 1
    local player = {
        UserId = nextUserId,
        DisplayName = name,
    }
    PlayerService.add(player)
    MatchService.onPlayerAdded(player)
    return player
end

local function removePlayer(player: any)
    local record = PlayerService.remove(player)
    MatchService.onPlayerRemoving(player, record)
end

local function advance(ticks: number)
    for _ = 1, ticks do
        MatchService.step()
    end
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

local function findEntry(roster, id)
    for _, entry in ipairs(roster or {}) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function findPlayer(snapshot, id)
    for _, player in ipairs(snapshot.players or {}) do
        if player.id == id then
            return player
        end
    end
    return nil
end

---------------------------------------------------------------- 独立练习房间

MatchService.init()
Net.reset()

local alice = addPlayer("Alice")
local bob = addPlayer("Bob")
local aliceId = "u" .. tostring(alice.UserId)
local bobId = "u" .. tostring(bob.UserId)

local waitingA = MatchService.getSync(alice)
local waitingB = MatchService.getSync(bob)
check("two humans get two rooms", MatchService.getRoomCount() == 2, MatchService.getRoomCount())
check("rooms have distinct ids", waitingA and waitingB and waitingA.roomId ~= waitingB.roomId)
check("practice room starts in waiting", waitingA and waitingA.phase == "waiting", waitingA and waitingA.phase)
check("practice room is 1v1", waitingA and waitingA.mode == "practice" and waitingA.maxPlayers == 2)
check("practice flag is exposed", waitingA and waitingA.practice == true)
check("waiting countdown", waitingA and waitingA.endsIn == 4, waitingA and waitingA.endsIn)
check("alice room only contains alice", waitingA and #waitingA.roster == 1 and waitingA.roster[1].id == aliceId)
check("bob room only contains bob", waitingB and #waitingB.roster == 1 and waitingB.roster[1].id == bobId)
check("waiting bot fill", waitingA and waitingA.botFill == 1, waitingA and waitingA.botFill)
check("waiting yourId", waitingA and waitingA.yourId == aliceId and not waitingA.spectating)

---------------------------------------------------------------- 选角只影响自己的房间

check("select haidao", MatchService.selectChar(alice, "haidao") == true)
check("reject unknown character", MatchService.selectChar(alice, "nope") == false)
waitingA = MatchService.getSync(alice)
waitingB = MatchService.getSync(bob)
check("selected char reflected", waitingA and waitingA.selectedChar == "haidao", waitingA and waitingA.selectedChar)
local aliceEntry = waitingA and findEntry(waitingA.roster, aliceId)
check("roster carries selected char", aliceEntry and aliceEntry.char == "haidao", aliceEntry and aliceEntry.char)
check("bob keeps default char", waitingB and waitingB.roster[1].char == "baobao", waitingB and waitingB.roster[1].char)

advance(119)
check("alice still waiting after 119 ticks", MatchService.getSync(alice).phase == "waiting")
check("bob still waiting after 119 ticks", MatchService.getSync(bob).phase == "waiting")
advance(1)

---------------------------------------------------------------- 两局同时开始

local playingA = MatchService.getSync(alice)
local playingB = MatchService.getSync(bob)
check("alice round starts after 120 ticks", playingA and playingA.phase == "playing", playingA and playingA.phase)
check("bob round starts independently", playingB and playingB.phase == "playing", playingB and playingB.phase)
check("two participants per practice room", playingA and #playingA.roster == 2, playingA and #playingA.roster)
check("one bot per practice room", playingA and countBots(playingA.roster) == 1, playingA and countBots(playingA.roster))
check("alice is a participant of her room", playingA and playingA.yourId == aliceId and not playingA.spectating)
check("bob is a participant of his room", playingB and playingB.yourId == bobId and not playingB.spectating)
check("round warmup", playingA and playingA.warmup == 90, playingA and playingA.warmup)
check("human char persists", playingA and findEntry(playingA.roster, aliceId).char == "haidao")
check("character select locked in round", MatchService.selectChar(alice, "baobao") == false)
check("locked character unchanged", findEntry(MatchService.getSync(alice).roster, aliceId).char == "haidao")

local snapshotA = playingA and playingA.snapshot
local snapshotB = playingB and playingB.snapshot
check("getSync carries a snapshot", snapshotA ~= nil)
check("snapshot has two players", snapshotA and #snapshotA.players == 2, snapshotA and #snapshotA.players)
check("bob snapshot has two players", snapshotB and #snapshotB.players == 2, snapshotB and #snapshotB.players)
check("snapshot warmup", snapshotA and snapshotA.warmup == 90, snapshotA and snapshotA.warmup)
check("snapshot tick starts at zero", snapshotA and snapshotA.tick == 0, snapshotA and snapshotA.tick)
check("snapshot grid rows", snapshotA and type(snapshotA.grid) == "table" and #snapshotA.grid == 13)
check("snapshot grid width", snapshotA and type(snapshotA.grid[1]) == "string" and #snapshotA.grid[1] == 15)
check("snapshot bombs", snapshotA and type(snapshotA.bombs) == "table")
check("snapshot explosions", snapshotA and type(snapshotA.expl) == "table")
check("snapshot items", snapshotA and type(snapshotA.items) == "table")
check("snapshot loot", snapshotA and type(snapshotA.loot) == "table")
check("snapshot slides", snapshotA and type(snapshotA.crateSlides) == "table")

---------------------------------------------------------------- 快照只发给房间成员

-- Both rooms have exactly one member and both snapshot buckets were reset at
-- round start. Two simulation ticks produce exactly one snapshot per room; a
-- global broadcast would give each human two.
Net.reset()
advance(2)
check("alice receives only her room snapshot", Net.sentCount(alice, "Snapshot") == 1, Net.sentCount(alice, "Snapshot"))
check("bob receives only his room snapshot", Net.sentCount(bob, "Snapshot") == 1, Net.sentCount(bob, "Snapshot"))
check("no global snapshot broadcast", Net.broadcastCount("Snapshot") == 0, Net.broadcastCount("Snapshot"))

---------------------------------------------------------------- 倒计时与输入隔离

advance(88)
playingA = MatchService.getSync(alice)
check("warmup ends after 88 more ticks", playingA and playingA.snapshot.warmup == 0, playingA and playingA.snapshot.warmup)
check("simulation tick starts after warmup", playingA and playingA.snapshot.tick == 0, playingA and playingA.snapshot.tick)

local bobBefore = findPlayer(MatchService.getSync(bob).snapshot, bobId)
MatchService.setInput(alice, { "up", "up", "nonsense", 5, "left" })
advance(10)
local bobAfter = findPlayer(MatchService.getSync(bob).snapshot, bobId)
check("input does not cross rooms", bobAfter and bobBefore and bobAfter.x == bobBefore.x and bobAfter.y == bobBefore.y)
check("simulation advances", MatchService.getSync(alice).snapshot.tick == 10,
    MatchService.getSync(alice).snapshot.tick)
MatchService.setInput(alice, {})

---------------------------------------------------------------- 对局中加入：获得自己的练习房间

local cara = addPlayer("Cara")
local waitingC = MatchService.getSync(cara)
check("mid-round join starts its own room", waitingC and waitingC.phase == "waiting" and not waitingC.spectating)
check("three independent rooms", MatchService.getRoomCount() == 3, MatchService.getRoomCount())
check("mid-round join does not enter another room", waitingC and waitingC.roomId ~= playingA.roomId and waitingC.roomId ~= playingB.roomId)
check("existing rounds keep running", MatchService.getSync(bob).phase == "playing")
local bobRoomId = MatchService.getSync(bob).roomId
local bobPlayers = #MatchService.getSync(bob).snapshot.players
check("mid-round join is not added to another room", bobPlayers == 2, bobPlayers)

advance(120)
local playingC = MatchService.getSync(cara)
check("cara round starts in her room", playingC and playingC.phase == "playing" and #playingC.roster == 2)
check("bob room is unchanged", MatchService.getSync(bob).phase == "playing" and MatchService.getSync(bob).roomId == bobRoomId)

---------------------------------------------------------------- 断线清理

removePlayer(alice)
check("alice room is removed", MatchService.getRoomCount() == 2, MatchService.getRoomCount())
check("alice no longer has sync", MatchService.getSync(alice) == nil)
local afterLeave = MatchService.getSync(bob)
check("bob round continues after alice leaves", afterLeave and afterLeave.phase == "playing", afterLeave and afterLeave.phase)
check("alice room did not send RoundEnd to bob", Net.sentCount(bob, "RoundEnd") == 0, Net.sentCount(bob, "RoundEnd"))

removePlayer(bob)
check("bob room is removed", MatchService.getRoomCount() == 1, MatchService.getRoomCount())
check("cara room still runs", MatchService.getSync(cara).phase == "playing")

---------------------------------------------------------------- 输入校验

local ok = pcall(function()
    MatchService.setInput(cara, { "up", "up", "nonsense", 5, "left" })
    MatchService.action(cara, "place")
    MatchService.action(cara, "bogus")
    MatchService.selectChar(cara, "haidao")
end)
check("malformed input/action does not error", ok)

removePlayer(cara)
check("all rooms removed", MatchService.getRoomCount() == 0, MatchService.getRoomCount())

TestLib.finish()
