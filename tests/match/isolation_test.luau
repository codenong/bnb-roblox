-- Error isolation between rooms: a room that throws must be closed and replaced
-- without stopping any other room, and repeated failures must not churn forever.
local TestLib = require("./testlib")
local check = TestLib.check

local TestEnv = require("./TestEnv")
local Constants = require("./Constants")
local MatchService = require("./MatchService")
local PlayerService = require("./PlayerService")
local Net = require("./Net")

TestEnv.silent = true -- the warnings below are expected; they are asserted instead

local nextUserId = 8000
local function join(name: string)
    nextUserId += 1
    local player = { UserId = nextUserId, DisplayName = name }
    PlayerService.add(player)
    MatchService.onPlayerAdded(player)
    return player
end

local function stepN(n: number)
    local thrown = 0
    for _ = 1, n do
        if not pcall(MatchService.step) then
            thrown += 1
        end
    end
    return thrown
end

local function runUntilPlaying(player, limit: number): boolean
    for _ = 1, limit do
        MatchService.step()
        local room = MatchService.getRoomFor(player)
        if room and room:getPhase() == "playing" then
            return true
        end
    end
    return false
end

local function warningsMatching(text: string): number
    local count = 0
    for _, message in ipairs(TestEnv.warnings) do
        if string.find(message, text, 1, true) then
            count += 1
        end
    end
    return count
end

local function fresh()
    MatchService.init()
    PlayerService.refreshNames()
    Net.reset()
    TestEnv.warnings = {}
end

-- Simulation progress in ticks. During the 3 s warm-up tickCount stays at 0 and
-- warmup counts down, so progress is the sum of both.
local function progress(game): number
    return (Constants.WARMUP_TICKS - game.warmup) + game.tickCount
end

local function breakSnapshots(room)
    room.game.snapshot = function()
        error("boom")
    end
end

---------------------------------------------------------------- 一个房间出错，另一个照常前进（两种创建顺序）
for _, brokenFirst in ipairs({ true, false }) do
    fresh()
    local label = if brokenFirst then "broken room created first" else "broken room created second"
    local a, b = join("A"), join("B")
    local bad, good = if brokenFirst then a else b, if brokenFirst then b else a

    check(label .. ": both reach playing", runUntilPlaying(a, 400) and runUntilPlaying(b, 400))
    local badRoom, goodRoom = MatchService.getRoomFor(bad), MatchService.getRoomFor(good)
    local before = progress(goodRoom.game)
    breakSnapshots(badRoom)
    Net.reset()

    check(label .. ": step never throws", stepN(60) == 0)
    check(label .. ": healthy room advanced every tick", progress(goodRoom.game) - before == 60, progress(goodRoom.game) - before)
    check(label .. ": healthy room untouched", MatchService.getRoomFor(good) == goodRoom and goodRoom:getPhase() == "playing")
    check(label .. ": broken room was closed", MatchService.getRoomFor(bad) ~= badRoom)
    check(label .. ": failure logged once, not every frame", warningsMatching("failed and was closed") == 1, warningsMatching("failed and was closed"))

    local replacement = MatchService.getRoomFor(bad)
    check(label .. ": member re-seated in a fresh waiting room", replacement ~= nil and replacement:getPhase() == "waiting" and replacement:getMemberCount() == 1)
    check(label .. ": re-seated player was told the new state", Net.sentCount(bad, "RoundState") >= 1, Net.sentCount(bad, "RoundState"))
    check(label .. ": no ghost rooms", MatchService.getRoomCount() == 2, MatchService.getRoomCount())
end

---------------------------------------------------------------- 两个房间同一帧都出错
do
    fresh()
    local a, b, c = join("A"), join("B"), join("C")
    runUntilPlaying(a, 400); runUntilPlaying(b, 400); runUntilPlaying(c, 400)
    local roomA, roomB, roomC = MatchService.getRoomFor(a), MatchService.getRoomFor(b), MatchService.getRoomFor(c)
    local before = progress(roomC.game)
    breakSnapshots(roomA)
    breakSnapshots(roomB)

    check("two failing rooms in one frame: step never throws", stepN(60) == 0)
    check("two failing rooms in one frame: third room advanced every tick", progress(roomC.game) - before == 60, progress(roomC.game) - before)
    check("both failing rooms replaced", MatchService.getRoomFor(a) ~= roomA and MatchService.getRoomFor(b) ~= roomB)
    check("three rooms remain", MatchService.getRoomCount() == 3, MatchService.getRoomCount())
end

---------------------------------------------------------------- 持续出错的玩家：重试有上限，且不影响别人
do
    fresh()
    local victim, other = join("Victim"), join("Other")
    -- Every countdown broadcast to the victim throws, so each replacement room
    -- fails again about a second after it is created.
    Net.sendHook = function(player, name, payload)
        if player == victim and name == "RoundState" and payload.phase == "waiting"
            and (payload.endsIn or 0) < Constants.WAITING_SECONDS and (payload.endsIn or 0) > 0 then
            error("send failed")
        end
    end

    local thrown = stepN(600)
    check("repeated failures: step never throws", thrown == 0, thrown)
    check("repeated failures: bounded number of closures", warningsMatching("failed and was closed") == 4, warningsMatching("failed and was closed"))
    check("repeated failures: player eventually left without a room", MatchService.getRoomFor(victim) == nil)
    check("repeated failures: give-up is logged", warningsMatching("not reassigning") == 1, warningsMatching("not reassigning"))
    check("repeated failures: only the other player's room remains", MatchService.getRoomCount() == 1, MatchService.getRoomCount())

    -- No churn after giving up, and the other player is unaffected.
    local before = #TestEnv.warnings
    stepN(300)
    check("no further warnings after giving up", #TestEnv.warnings == before)
    local otherRoom = MatchService.getRoomFor(other)
    check("other player still has their room", otherRoom ~= nil)
    check("other player's round started normally", otherRoom ~= nil and otherRoom:getPhase() == "playing", otherRoom and otherRoom:getPhase())

    -- Rejoining (or a sync request) brings the player back.
    Net.sendHook = nil
    local sync = MatchService.getSync(victim)
    check("sync request re-creates a room for the stranded player", sync ~= nil and MatchService.getRoomFor(victim) ~= nil)
end

---------------------------------------------------------------- 间隔足够久的偶发错误不累计
do
    fresh()
    local p = join("Rare")
    local replaced = 0
    for _ = 1, 5 do
        runUntilPlaying(p, 400)
        local room = MatchService.getRoomFor(p)
        if room and room:getPhase() == "playing" then
            breakSnapshots(room)
            stepN(5)
            if MatchService.getRoomFor(p) ~= room and MatchService.getRoomFor(p) ~= nil then
                replaced += 1
            end
        end
        stepN(31 * Constants.TICK_RATE) -- longer than the 30 s window
    end
    check("rare failures never exhaust the budget", replaced == 5, replaced)
    check("player still has a room after five rare failures", MatchService.getRoomFor(p) ~= nil)
end

---------------------------------------------------------------- 清理
do
    fresh()
    local p = join("Leaver")
    runUntilPlaying(p, 400)
    breakSnapshots(MatchService.getRoomFor(p))
    stepN(5)
    local record = PlayerService.remove(p)
    MatchService.onPlayerRemoving(p, record)
    stepN(5)
    check("leaving after a recycle leaves no rooms behind", MatchService.getRoomCount() == 0, MatchService.getRoomCount())
end

TestEnv.silent = false
TestLib.finish()
