-- 服务端玩法流程测试：用 Stub 环境真实跑 PlayerService / BombService / RoundService

local Stub = require("./Stub")
local Constants = require("./Constants")
local Grid = require("./Grid")
local MapRules = require("./MapRules")
local Net = require("./Net")
local MapService = require("./MapService")
local PlayerService = require("./PlayerService")
local BombService = require("./BombService")
local RoundService = require("./RoundService")

local TILE = Constants.TILE

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed += 1
    else
        failed += 1
        print("FAIL: " .. name .. (extra ~= nil and (" -> " .. tostring(extra)) or ""))
    end
end

local DT = 1 / 30

local function advance(seconds)
    for _ = 1, math.floor(seconds / DT + 0.5) do
        Stub.clock += DT
        PlayerService.step(DT, Stub.clock)
        BombService.update(Stub.clock)
        RoundService.update(Stub.clock)
    end
end

-- 持续推进直到条件满足（最多 maxSeconds）
local function advanceUntil(cond, maxSeconds)
    local steps = 0
    while not cond() and steps * DT < maxSeconds do
        advance(DT)
        steps += 1
    end
    return cond()
end

local function events(name)
    local list = {}
    for _, e in Stub.sent do
        if e.name == name then
            table.insert(list, e.args)
        end
    end
    return list
end

local function newPlayer(id, name)
    return { UserId = id, DisplayName = name }
end

local function startMatch(players)
    Stub.players = players
    Stub.sent = {}
    RoundService.start()
    advance(Constants.INTERMISSION + 0.5)
end

Net.init()
MapService.build()

---------------------------------------------------------------- 没有玩家时不开局
do
    Stub.players = {}
    RoundService.start()
    advance(6)
    check("no players -> stays in intermission", not RoundService.isPlaying())
end

---------------------------------------------------------------- 开局 + 出生点
local alice, bob = newPlayer(1, "Alice"), newPlayer(2, "Bob")
do
    startMatch({ alice, bob })
    check("round starts after intermission", RoundService.isPlaying())

    local a, b = PlayerService.get(alice), PlayerService.get(bob)
    check("alice spawn", a.x == 2 and a.z == 2, a.x .. "," .. a.z)
    check("bob spawn (opposite corner)", b.x == 14 and b.z == 12, b.x .. "," .. b.z)

    local reset = events("MapReset")
    check("MapReset broadcast", #reset == 1 and #reset[1][3] == Constants.MAP_WIDTH * Constants.MAP_HEIGHT)

    local snap = PlayerService.snapshot()
    check("snapshot has 2 entries", #snap == 2)
    check("snapshot entry format", #snap[1] == 6)
end

---------------------------------------------------------------- A: 放泡泡 -> 躲进 L 形安全区 -> 爆炸炸掉箱子，自己没事
do
    startMatch({ alice, bob })
    local a = PlayerService.get(alice)
    local map = MapService.map

    PlayerService.setInput(alice, 1, 0)
    advanceUntil(function() return a.x >= 3 end, 2)
    PlayerService.setInput(alice, 0, 0)
    local col, row = Grid.cellOf(a.x, a.z)
    check("alice reached (3,2)", col == 3 and row == 2, col .. "," .. row)

    check("place bubble ok", BombService.place(a, 3, 2, Stub.clock) == true)
    check("bubble registered in map", map.bubbles[Grid.key(3, 2)] == true)
    check("second bubble rejected (max 1)", BombService.place(a, 2, 2, Stub.clock) == false)

    -- 走出泡泡：向左，再向下躲进 (2,3)
    PlayerService.setInput(alice, -1, 0)
    advanceUntil(function() return a.x <= 2.2 end, 2)
    PlayerService.setInput(alice, 0, 1)
    advanceUntil(function() return a.z >= 3 end, 2)
    PlayerService.setInput(alice, 0, 0)
    check("alice walked out of her own bubble", a.x < 2.5 and a.z >= 3, a.x .. "," .. a.z)

    check("crate still there before blast", MapRules.getCell(map, 4, 2) == TILE.CRATE)
    advance(Constants.BUBBLE_FUSE + 0.2)

    check("bubble gone after blast", next(map.bubbles) == nil)
    check("crate destroyed", MapRules.getCell(map, 4, 2) == TILE.EMPTY)
    check("alice survived in safe cell", a.alive and a.trappedUntil == nil)
    check("bubble count restored", a.activeBubbles == 0)

    local ex = events("Explosion")
    check("one Explosion event", #ex == 1)
    check("Explosion lists removed bubble", ex[1] and ex[1][1][1] == 3 and ex[1][1][2] == 2)
    check("Explosion lists broken crate", ex[1] and ex[1][2][1] == 4 and ex[1][2][2] == 2)
    check("round continues", RoundService.isPlaying())

    -- 炸完后可以再放
    check("can place again after blast", BombService.place(a, 2, 3, Stub.clock) == true)
    BombService.reset() -- 别把这个泡泡留给下一个场景
    check("reset clears bubbles", next(map.bubbles) == nil)
end

---------------------------------------------------------------- B: 站在自己泡泡里 -> 被困 -> 超时死亡 -> 对手获胜
do
    startMatch({ alice, bob })
    local a = PlayerService.get(alice)

    check("alice places at feet", BombService.place(a, 2, 2, Stub.clock))
    advance(Constants.BUBBLE_FUSE + 0.2)

    check("alice trapped by own blast", a.alive and a.trappedUntil ~= nil)
    check("PlayerTrapped event", #events("PlayerTrapped") == 1, #events("PlayerTrapped"))

    check("trapped player cannot place", BombService.place(a, 2, 2, Stub.clock) == false)

    advance(Constants.TRAP_DURATION + 0.3)
    check("alice died after timeout", a.alive == false)

    local died = events("PlayerDied")
    check("PlayerDied event (timeout)", #died == 1 and died[1][1] == 1 and died[1][2] == "timeout")
    check("dead player cannot place", BombService.place(a, 2, 2, Stub.clock) == false)

    local info = RoundService.getInfo()
    check("round ended", info.state == "Ended", info.state)
    check("winner announced", string.find(info.message, "Bob", 1, true) ~= nil, info.message)

    advance(Constants.END_DELAY + 0.5)
    check("returns to intermission/next round", RoundService.getInfo().state ~= "Ended")
end

---------------------------------------------------------------- C: 连锁爆炸
do
    startMatch({ alice, bob })
    local a = PlayerService.get(alice)
    a.maxBubbles = 3
    local map = MapService.map

    check("bubble 1", BombService.place(a, 2, 2, Stub.clock))
    PlayerService.setInput(alice, 1, 0)
    advanceUntil(function() return a.x >= 3 end, 2)
    PlayerService.setInput(alice, 0, 0)
    check("bubble 2 (a bit later)", BombService.place(a, 3, 2, Stub.clock))

    -- 第一个泡泡到点时，第二个还没到点，但会被连锁引爆
    advanceUntil(function() return #events("Explosion") > 0 end, Constants.BUBBLE_FUSE + 1)
    local ex = events("Explosion")
    check("single Explosion event for chain", #ex == 1, #ex)
    check("both bubbles removed together", ex[1] and #ex[1][1] == 4, ex[1] and #ex[1][1])
    check("map has no bubbles left", next(map.bubbles) == nil)
    check("owner count back to 0", a.activeBubbles == 0)
    check("alice (inside blast) trapped", a.trappedUntil ~= nil)
end

---------------------------------------------------------------- D: 被困者被其他玩家碰到 -> 立即死亡
do
    startMatch({ alice, bob })
    local a, b = PlayerService.get(alice), PlayerService.get(bob)
    PlayerService.trap(a, Stub.clock)
    b.x, b.z = a.x + 0.3, a.z
    advance(DT * 3)
    check("trapped player killed by touch", a.alive == false)
    local died = events("PlayerDied")
    check("death reason = touched", died[1] and died[1][2] == "touched")
end

---------------------------------------------------------------- E: 不信任客户端的输入
do
    startMatch({ alice, bob })
    local a = PlayerService.get(alice)

    PlayerService.setInput(alice, 0 / 0, 0)
    check("NaN input ignored", a.dirX == 0 and a.dirZ == 0)
    PlayerService.setInput(alice, math.huge, 0)
    check("inf input ignored", a.dirX == 0)
    PlayerService.setInput(alice, "1", 0)
    check("string input ignored", a.dirX == 0)
    PlayerService.setInput(alice, 5, 0)
    check("oversized input clamped to unit length", math.abs(a.dirX - 1) < 1e-6 and a.dirZ == 0)
    PlayerService.setInput(alice, 3, 4)
    check("diagonal clamped", math.abs(math.sqrt(a.dirX ^ 2 + a.dirZ ^ 2) - 1) < 1e-6)
    PlayerService.setInput(alice, 0, 0)

    check("fractional cell rejected", BombService.place(a, 2.5, 2, Stub.clock) == false)
    check("string cell rejected", BombService.place(a, "2", 2, Stub.clock) == false)
    check("far cell rejected", BombService.place(a, 8, 6, Stub.clock) == false)
    a.x = 3
    check("crate cell rejected", BombService.place(a, 4, 2, Stub.clock) == false)
    check("wall cell rejected", BombService.place(a, 3, 3, Stub.clock) == false)
    a.x = 2
    check("valid place still works", BombService.place(a, 2, 2, Stub.clock) == true)
    check("duplicate cell rejected", BombService.place(PlayerService.get(bob), 2, 2, Stub.clock) == false)
end

---------------------------------------------------------------- F: 单人测试模式
do
    startMatch({ alice })
    local a = PlayerService.get(alice)
    advance(3)
    check("solo round does not end while alive", RoundService.isPlaying())
    PlayerService.kill(a, "test")
    advance(0.2)
    local info = RoundService.getInfo()
    check("solo round ends when player eliminated", info.state == "Ended" and info.message == "本局结束", info.message)
end

---------------------------------------------------------------- G: 玩家中途离开
do
    startMatch({ alice, bob })
    PlayerService.remove(bob)
    Stub.players = { alice }
    advance(0.2)
    local info = RoundService.getInfo()
    check("remaining player wins when opponent leaves", info.state == "Ended" and string.find(info.message, "Alice", 1, true) ~= nil, info.message)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    error("server tests failed")
end
