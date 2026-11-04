-- Headless exercise of the server match state machine with lightweight stubs.
-- Loaded by tests/run.sh from tests/build/match.

local TestLib = require("./testlib")
local check = TestLib.check

local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")

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

---------------------------------------------------------------- 等待 / 选角

MatchService.init()

local alice = addPlayer("Alice")
local bob = addPlayer("Bob")
local waiting = MatchService.getSync(alice)
check("starts in waiting", waiting and waiting.phase == "waiting", waiting and waiting.phase)
check("waiting countdown", waiting and waiting.endsIn == 4, waiting and waiting.endsIn)
check("waiting roster has both humans", waiting and #waiting.roster == 2, waiting and #waiting.roster)
check("waiting bot fill", waiting and waiting.botFill == 4, waiting and waiting.botFill)
check("waiting yourId", waiting and waiting.yourId ~= nil and not waiting.spectating)

check("select haidao", MatchService.selectChar(alice, "haidao") == true)
check("reject unknown character", MatchService.selectChar(alice, "nope") == false)
waiting = MatchService.getSync(alice)
check("selected char reflected", waiting and waiting.selectedChar == "haidao", waiting and waiting.selectedChar)
local aliceEntry = waiting and findEntry(waiting.roster, "u" .. tostring(alice.UserId))
check("roster carries selected char", aliceEntry and aliceEntry.char == "haidao", aliceEntry and aliceEntry.char)

advance(119)
check("still waiting after 119 ticks", MatchService.getSync(alice).phase == "waiting")
advance(1)

---------------------------------------------------------------- 第一局

local playing = MatchService.getSync(alice)
check("round starts after 120 ticks", playing and playing.phase == "playing", playing and playing.phase)
check("round warmup", playing and playing.warmup == 90, playing and playing.warmup)
check("six participants", playing and #playing.roster == 6, playing and #playing.roster)
check("four bots fill", playing and countBots(playing.roster) == 4, playing and countBots(playing.roster))
check("human persists into roster", playing and findEntry(playing.roster, "u" .. tostring(alice.UserId)) ~= nil)
check("human char persists", playing and findEntry(playing.roster, "u" .. tostring(alice.UserId)).char == "haidao")
check("character select locked in round", MatchService.selectChar(alice, "baobao") == false)
check("locked character unchanged", MatchService.getSync(alice).roster[1].char == "haidao")

local snapshot = playing and playing.snapshot
check("getSync carries snapshot", snapshot ~= nil)
check("snapshot has six players", snapshot and #snapshot.players == 6, snapshot and #snapshot.players)
check("snapshot warmup", snapshot and snapshot.warmup == 90, snapshot and snapshot.warmup)
check("snapshot tick starts at zero", snapshot and snapshot.tick == 0, snapshot and snapshot.tick)
check("snapshot grid rows", snapshot and type(snapshot.grid) == "table" and #snapshot.grid == 13)
check("snapshot grid width", snapshot and type(snapshot.grid[1]) == "string" and #snapshot.grid[1] == 15)
check("snapshot bombs", snapshot and type(snapshot.bombs) == "table")
check("snapshot explosions", snapshot and type(snapshot.expl) == "table")
check("snapshot items", snapshot and type(snapshot.items) == "table")
check("snapshot loot", snapshot and type(snapshot.loot) == "table")
check("snapshot slides", snapshot and type(snapshot.crateSlides) == "table")

local firstPlayer = snapshot and snapshot.players[1]
check("snapshot player id", firstPlayer and type(firstPlayer.id) == "string")
check("snapshot player position", firstPlayer and type(firstPlayer.x) == "number" and type(firstPlayer.y) == "number")
check("snapshot player flags", firstPlayer and type(firstPlayer.alive) == "boolean" and type(firstPlayer.trapped) == "boolean")
check("snapshot player stats", firstPlayer
    and type(firstPlayer.speed) == "number"
    and type(firstPlayer.maxBombs) == "number"
    and type(firstPlayer.range) == "number")
check("snapshot player inventory", firstPlayer and type(firstPlayer.inv) == "table")

advance(90)
playing = MatchService.getSync(alice)
check("warmup ends after 90 ticks", playing and playing.snapshot.warmup == 0, playing and playing.snapshot.warmup)
check("simulation tick starts after warmup", playing and playing.snapshot.tick == 0, playing and playing.snapshot.tick)
advance(5)
playing = MatchService.getSync(alice)
check("simulation advances", playing and playing.snapshot.tick == 5, playing and playing.snapshot.tick)

---------------------------------------------------------------- 中途观战 / 断线 / 结算

local cara = addPlayer("Cara")
local spectator = MatchService.getSync(cara)
check("mid-round join spectates", spectator and spectator.phase == "playing" and spectator.spectating == true)
check("mid-round join has no yourId", spectator and spectator.yourId == nil)
check("mid-round join sees round roster", spectator and #spectator.roster == 6)

removePlayer(alice)
local afterLeave = MatchService.getSync(cara)
check("round continues while a human remains", afterLeave and afterLeave.phase == "playing", afterLeave and afterLeave.phase)
local aliceSnapshot = afterLeave and findPlayer(afterLeave.snapshot, "u" .. tostring(alice.UserId))
check("disconnect marks participant dead", aliceSnapshot and aliceSnapshot.alive == false)

removePlayer(bob)
local ended = MatchService.getSync(cara)
check("round ends when all participating humans leave", ended and ended.phase == "ended", ended and ended.phase)
check("ended state has result", ended and ended.lastResult ~= nil)
check("no humans left yields draw", ended and ended.lastResult.draw == true, ended and ended.lastResult.draw)
check("ended snapshot exists", ended and ended.snapshot ~= nil)
check("ended countdown", ended and ended.endsIn == 4, ended and ended.endsIn)

advance(120)
local nextWaiting = MatchService.getSync(cara)
check("returns to waiting", nextWaiting and nextWaiting.phase == "waiting", nextWaiting and nextWaiting.phase)
check("waiting includes connected spectator", nextWaiting and #nextWaiting.roster == 1, nextWaiting and #nextWaiting.roster)

---------------------------------------------------------------- 超过 6 人 -> 观战

local extra = {}
for i = 1, 6 do
    extra[i] = addPlayer("Extra" .. tostring(i))
end
local fullWaiting = MatchService.getSync(cara)
check("waiting roster caps at six", fullWaiting and #fullWaiting.roster == 6, fullWaiting and #fullWaiting.roster)
check("full waiting has no bot fill", fullWaiting and fullWaiting.botFill == 0, fullWaiting and fullWaiting.botFill)

MatchService.selectChar(cara, "haidao")
advance(120)
local fullRound = MatchService.getSync(cara)
check("seven humans still start a round", fullRound and fullRound.phase == "playing", fullRound and fullRound.phase)
check("six players participate", fullRound and #fullRound.roster == 6, fullRound and #fullRound.roster)
check("no bots when seven humans queue", fullRound and countBots(fullRound.roster) == 0, fullRound and countBots(fullRound.roster))
check("queued human is participant", fullRound and fullRound.yourId ~= nil)
check("participant keeps haidao", fullRound and findEntry(fullRound.roster, "u" .. tostring(cara.UserId)).char == "haidao")

local overflow = MatchService.getSync(extra[6])
check("seventh human spectates", overflow and overflow.phase == "playing" and overflow.spectating == true)
check("seventh human has no yourId", overflow and overflow.yourId == nil)
check("seventh human sees six players", overflow and #overflow.snapshot.players == 6, overflow and #overflow.snapshot.players)

---------------------------------------------------------------- 输入校验

local ok = pcall(function()
    MatchService.setInput(cara, { "up", "up", "nonsense", 5, "left" })
    MatchService.action(cara, "place")
    MatchService.action(cara, "bogus")
end)
check("malformed input/action does not error", ok)

TestLib.finish()
