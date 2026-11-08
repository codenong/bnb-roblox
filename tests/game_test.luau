local TestLib = require("./testlib")
local Constants = require("./Constants")
local Map = require("./Map")
local Characters = require("./Characters")
local Game = require("./Game")

local check, near = TestLib.check, TestLib.near
local TILE = Constants.TILE
local ROWS, COLS = Constants.ROWS, Constants.COLS

local function defs()
    return {
        { id = "a", name = "A" },
        { id = "b", name = "B" },
    }
end

local function makeGame(random, warmup, playerDefs)
    local game = Game.new(playerDefs or defs(), {
        random = random or function()
            return 0.99
        end,
        warmup = warmup == nil and 0 or warmup,
    })
    -- Fixed test anchor: A starts at (1,1) so item/push/kick setups are simple.
    local a = game.players.a
    a.x = 1 * TILE + TILE / 2
    a.y = 1 * TILE + TILE / 2
    return game
end

local function clearField(game)
    for y = 0, ROWS - 1 do
        for x = 0, COLS - 1 do
            game.grid[y][x] = Map.EMPTY
        end
    end
    game.items = {}
end

local function setTilePos(game, id, tx, ty)
    local player = game.players[id]
    player.x = tx * TILE + TILE / 2
    player.y = ty * TILE + TILE / 2
end

local function firstBomb(game, tx, ty)
    for _, bomb in ipairs(game.bombs) do
        if bomb.tx == tx and bomb.ty == ty then
            return bomb
        end
    end
    return nil
end

local function tickN(game, count)
    for _ = 1, count do
        game:tick()
    end
end

-- 321 warmup
do
    local game = Game.new(defs(), {
        random = function()
            return 0.99
        end,
    })
    local a = game.players.a
    check("default warmup", game.warmup == Constants.WARMUP_TICKS, game.warmup)
    check("cannot bomb during warmup", not game:placeBomb("a"))
    game:setInput("a", { "down" })
    local y0 = a.y
    tickN(game, 10)
    check("warmup table frozen", game.tickCount == 0, game.tickCount)
    check("warmup player frozen", a.y == y0, a.y)
    check("warmup snapshot", game:snapshot().warmup == Constants.WARMUP_TICKS - 10)
    tickN(game, Constants.WARMUP_TICKS - 10)
    check("warmup done", game.warmup == 0, game.warmup)
    game:tick()
    check("tick after warmup", game.tickCount == 1, game.tickCount)
    check("input works after warmup", a.y > y0, a.y)
end

-- bomb placement / cap
do
    local game = makeGame()
    check("place bomb", game:placeBomb("a"))
    check("same tile rejected", not game:placeBomb("a"))
    setTilePos(game, "a", 3, 3)
    check("bomb cap", not game:placeBomb("a"))
end

-- flame shape, crate destruction, drop
do
    local game = makeGame(function()
        return 0
    end)
    clearField(game)
    game.grid[3][3] = Map.SOFT
    game.grid[0][1] = Map.WALL
    setTilePos(game, "a", 1, 3)
    game.players.a.range = 3
    check("place flame bomb", game:placeBomb("a"))
    setTilePos(game, "a", 6, 6)
    tickN(game, Constants.BOMB_FUSE_TICKS)

    check("one explosion", #game.explosions == 1, #game.explosions)
    local cells = {}
    if game.explosions[1] then
        for _, cell in ipairs(game.explosions[1].cells) do
            cells[cell[1] .. "," .. cell[2]] = true
        end
    end
    check("flame includes origin", cells["1,3"] == true)
    check("flame right arm", cells["2,3"] == true)
    check("flame includes soft crate", cells["3,3"] == true)
    check("soft crate blocks", not cells["4,3"])
    check("flame up arm", cells["1,2"] == true and cells["1,1"] == true)
    check("wall blocks", not cells["1,0"])
    check("crate destroyed", game.grid[3][3] == Map.EMPTY, game.grid[3][3])
    check("crate dropped item", #game.items == 1, #game.items)
    check("first drop is potion", game.items[1] and game.items[1].kind == "potion", game.items[1] and game.items[1].kind)
end

-- chain explosion
do
    local game = makeGame()
    clearField(game)
    setTilePos(game, "a", 2, 2)
    setTilePos(game, "b", 2, 3)
    check("chain bomb a", game:placeBomb("a"))
    check("chain bomb b", game:placeBomb("b"))
    setTilePos(game, "a", 6, 6)
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("all bombs gone", #game.bombs == 0, #game.bombs)
    check("two explosions", #game.explosions == 2, #game.explosions)
end

-- trapped, timeout, winner
do
    local game = makeGame()
    clearField(game)
    setTilePos(game, "a", 5, 5)
    setTilePos(game, "b", 5, 5)
    check("trap bomb", game:placeBomb("b"))
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    local a = game.players.a
    check("a trapped", a.alive and a.trapped)
    tickN(game, Constants.TRAP_TICKS)
    check("a dead after trap timeout", not a.alive)
    check("game over", game.over)
    check("b winner", game.winner and game.winner.id == "b", game.winner and game.winner.id)
end

-- trapped touch kill
do
    local game = makeGame()
    clearField(game)
    setTilePos(game, "a", 5, 5)
    setTilePos(game, "b", 5, 5)
    check("touch bomb", game:placeBomb("b"))
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("touch victim trapped", game.players.a.trapped)
    tickN(game, Constants.EXPLOSION_TICKS + 2)
    check("still trapped", game.players.a.trapped)
    setTilePos(game, "b", 5, 5)
    game:tick()
    check("touch kill", not game.players.a.alive)
end

-- pushing crates
do
    local game = makeGame()
    clearField(game)
    game.grid[1][2] = Map.CRATE
    game:setInput("a", { "right" })
    tickN(game, 4)
    check("not instant push", game.grid[1][2] == Map.CRATE, game.grid[1][2])

    local function pushedTo(x, y, max)
        max = max or (Constants.PUSH_TICKS + 10)
        for _ = 1, max do
            game:tick()
            if game.grid[y][x] == Map.CRATE then
                return true
            end
        end
        return false
    end

    check("pushed to 3,1", pushedTo(3, 1, Constants.PUSH_TICKS + 10))
    check("pushed to 4,1", pushedTo(4, 1, Constants.PUSH_TICKS + 22))

    game.grid[1][5] = Map.WALL
    check("wall blocks push", not pushedTo(5, 1))

    game.grid[1][5] = Map.CRATE
    tickN(game, Constants.PUSH_TICKS * 2)
    check("crate blocks crate", game.grid[1][4] == Map.CRATE, game.grid[1][4])

    game.grid[1][5] = Map.EMPTY
    setTilePos(game, "b", 5, 1)
    check("bomb for push test", game:placeBomb("b"))
    check("bomb blocks push", not pushedTo(5, 1))
end

-- yellow boxes don't push; pushed crates still explode
do
    local game = makeGame()
    clearField(game)
    game.grid[1][2] = Map.SOFT
    game:setInput("a", { "right" })
    tickN(game, Constants.PUSH_TICKS * 3)
    check("soft box does not push", game.grid[1][2] == Map.SOFT, game.grid[1][2])

    game.grid[1][2] = Map.CRATE
    game:setInput("a", { "right" })
    local pushed = false
    for _ = 1, Constants.PUSH_TICKS + 8 do
        game:tick()
        if game.grid[1][2] == Map.EMPTY then
            pushed = true
            break
        end
    end
    check("pushed soft path", pushed and game.grid[1][3] == Map.CRATE)
    game:setInput("a", {})
    setTilePos(game, "b", 3, 3)
    game.players.b.range = 2
    check("bomb pushed crate", game:placeBomb("b"))
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("pushed crate destroyed", game.grid[1][3] == Map.EMPTY, game.grid[1][3])
end

-- sliding crate cancelled when bombed mid-slide
do
    local game = makeGame()
    clearField(game)
    game.grid[1][2] = Map.CRATE
    game:setInput("a", { "right" })
    local started = false
    for _ = 1, Constants.PUSH_TICKS + 12 do
        game:tick()
        if #game.crateSlides == 1 then
            started = true
            break
        end
    end
    check("slide started", started)
    check("source still crate", game.grid[1][2] == Map.CRATE, game.grid[1][2])
    game.grid[1][2] = Map.EMPTY
    tickN(game, 10)
    check("slide cleared", #game.crateSlides == 0, #game.crateSlides)
    check("no target crate", game.grid[1][3] == Map.EMPTY, game.grid[1][3])
end

-- kick bombs
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    game.items = { { x = 1, y = 1, kind = "kick" } }
    game:tick()
    check("kick pickup", a.kick == true)
    game.grid[1][6] = Map.WALL
    setTilePos(game, "b", 2, 1)
    check("kick test bomb", game:placeBomb("b"))
    local bomb = firstBomb(game, 2, 1)
    game:setInput("a", { "right" })
    for _ = 1, 60 do
        if bomb.tx == 5 then
            break
        end
        game:tick()
    end
    check("bomb kicked to 5", bomb.tx == 5, bomb.tx)
    game:setInput("a", {})
    for _ = 1, 12 do
        if not bomb.slide then
            break
        end
        game:tick()
    end
    check("bomb settled", bomb.slide == nil)
    check("bomb still at 5", bomb.tx == 5, bomb.tx)
end

-- kick stops before another bomb
do
    local game = makeGame()
    clearField(game)
    setTilePos(game, "b", 2, 1)
    check("kick stop b bomb", game:placeBomb("b"))
    setTilePos(game, "a", 5, 1)
    check("kick stop a bomb", game:placeBomb("a"))
    game.players.a.kick = true
    setTilePos(game, "a", 1, 1)
    local kicked = firstBomb(game, 2, 1)
    game:setInput("a", { "right" })
    tickN(game, 40)
    check("kick stops before bomb", kicked and kicked.tx == 4, kicked and kicked.tx)
end

-- mount disables kick
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.kick = true
    a.mount = "turtle"
    setTilePos(game, "b", 2, 1)
    check("mount kick bomb", game:placeBomb("b"))
    local bomb = firstBomb(game, 2, 1)
    game:setInput("a", { "right" })
    tickN(game, 30)
    check("mounted cannot kick", bomb.tx == 2, bomb.tx)
    a.mount = nil
    game.grid[1][6] = Map.WALL
    for _ = 1, 60 do
        if bomb.tx == 5 then
            break
        end
        game:tick()
    end
    check("kick after dismount", bomb.tx == 5, bomb.tx)
end

-- kicked bomb passes ground items
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.kick = true
    setTilePos(game, "b", 2, 1)
    check("item pass bomb", game:placeBomb("b"))
    setTilePos(game, "b", 10, 10)
    local bomb = firstBomb(game, 2, 1)
    game.items = { { x = 4, y = 1, kind = "potion" } }
    game.grid[1][7] = Map.WALL
    game:setInput("a", { "right" })
    for _ = 1, 60 do
        if bomb.tx == 6 then
            break
        end
        game:tick()
    end
    check("bomb passed item", bomb.tx == 6, bomb.tx)
    check("item remains", #game.items == 1 and game.items[1].kind == "potion")
end

-- loot shots
do
    local game = Game.new({
        { id = "a", name = "A" },
        { id = "b", name = "B" },
        { id = "c", name = "C" },
    }, {
        random = function()
            return 0.1
        end,
        warmup = 0,
    })
    clearField(game)
    local a = game.players.a
    setTilePos(game, "a", 1, 1)
    for _, kind in ipairs({ "potion", "bubble", "shoe" }) do
        game.items = { { x = 1, y = 1, kind = kind } }
        game:tick()
    end
    check("eaten record", #a.eaten == 3, #a.eaten)
    game:kill(a)
    check("eaten cleared", #a.eaten == 0)
    check("nothing on ground yet", #game.items == 0, #game.items)
    check("three loot shots", #game.lootShots == 3, #game.lootShots)
    local targets = {}
    for _, shot in ipairs(game.lootShots) do
        local dist = math.abs(shot.tx - 1) + math.abs(shot.ty - 1)
        check("loot launches away", dist >= 1, dist)
        check("loot lands on empty", game.grid[shot.ty][shot.tx] == Map.EMPTY)
        targets[shot.tx .. "," .. shot.ty] = true
    end
    local unique = 0
    for _ in pairs(targets) do
        unique += 1
    end
    check("loot targets unique", unique == 3, unique)
    tickN(game, 12)
    check("loot landed", #game.lootShots == 0 and #game.items == 3, #game.items)
end

-- item stats and caps
do
    local game = makeGame()
    local a = game.players.a
    game.items = { { x = 1, y = 1, kind = "bubble" } }
    game:tick()
    check("bubble raises cap", a.maxBombs == 2, a.maxBombs)
    game.items = { { x = 1, y = 1, kind = "potion" } }
    game:tick()
    check("potion raises range", a.range == 2, a.range)
    game.items = { { x = 1, y = 1, kind = "gremlin" } }
    game:tick()
    check("gremlin max range", a.range == a.caps.range, a.range)
    game.items = { { x = 1, y = 1, kind = "devil" } }
    game:tick()
    check("devil max speed", a.speed == a.caps.speed, a.speed)
end

-- character stats
do
    local game = Game.new({
        { id = "a", name = "A", char = "baobao" },
        { id = "b", name = "B", char = "haidao" },
    }, { warmup = 0, random = function()
        return 0.99
    end })
    local a, b = game.players.a, game.players.b
    check("baobao range", a.range == 1, a.range)
    check("haidao range", b.range == 2, b.range)
    check("baobao bombs", a.maxBombs == 1, a.maxBombs)
    check("haidao bombs", b.maxBombs == 1, b.maxBombs)
    check("baobao speed", a.speed == 144, a.speed)
    check("haidao speed", b.speed == 120, b.speed)
    check("baobao caps", a.caps.speed == 240 and a.caps.range == 7 and a.caps.bombs == 6)
    check("haidao caps", b.caps.speed == 216 and b.caps.range == 7 and b.caps.bombs == 8)
    check("two characters", #Characters.CHARACTERS == 2)
end

-- flame burns items
do
    local game = makeGame()
    clearField(game)
    setTilePos(game, "a", 1, 1)
    game.items = {
        { x = 2, y = 1, kind = "potion" },
        { x = 1, y = 2, kind = "bubble" },
        { x = 6, y = 6, kind = "shoe" },
    }
    check("flame item bomb", game:placeBomb("a"))
    setTilePos(game, "a", 8, 8)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("flame burned items", #game.items == 1, #game.items)
    check("far item survives", game.items[1] and game.items[1].x == 6 and game.items[1].y == 6)
end

-- needle self rescue
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    game.items = { { x = 1, y = 1, kind = "needle" } }
    game:tick()
    check("needle picked", a.inv.needle == 1, a.inv.needle)
    setTilePos(game, "a", 5, 5)
    setTilePos(game, "b", 5, 5)
    check("needle trap bomb", game:placeBomb("b"))
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("needle trapped", a.trapped)
    check("needle rescue", game:useItem("a"))
    check("needle freed", not a.trapped)
    check("needle consumed", a.inv.needle == 0, a.inv.needle)
    check("needle grace", a.grace > 0, a.grace)
end

-- remote bombs
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    game.items = {
        { x = 1, y = 1, kind = "remote" },
        { x = 1, y = 1, kind = "remote" },
    }
    game:tick()
    game:tick()
    check("two remotes", a.inv.remote == 2, a.inv.remote)

    setTilePos(game, "a", 2, 2)
    check("ordinary bomb", game:placeBomb("a"))
    check("ordinary keeps remote", a.inv.remote == 2, a.inv.remote)
    setTilePos(game, "a", 8, 8)
    for _, bomb in ipairs(game.bombs) do
        bomb.fuse = 0
    end
    game:tick()
    check("ordinary cleared", #game.bombs == 0, #game.bombs)

    setTilePos(game, "a", 3, 3)
    check("remote bomb", game:useItem("a"))
    check("remote consumed", a.inv.remote == 1, a.inv.remote)
    setTilePos(game, "a", 8, 8)
    tickN(game, 80)
    check("remote persists", #game.bombs == 1, #game.bombs)

    check("remote detonate", game:placeBomb("a"))
    game:tick()
    check("remote gone", #game.bombs == 0, #game.bombs)
    check("remote made explosion", #game.explosions >= 1, #game.explosions)

    setTilePos(game, "a", 5, 5)
    check("second remote", game:useItem("a"))
    setTilePos(game, "b", 5, 6)
    check("chain setup bomb", game:placeBomb("b"))
    setTilePos(game, "a", 9, 9)
    setTilePos(game, "b", 1, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS + 1)
    check("remote chained", #game.bombs == 0, #game.bombs)
end

-- timeout draw
do
    local game = makeGame()
    game.tickCount = Constants.ROUND_TICKS - 1
    game:tick()
    check("timeout over", game.over)
    check("timeout draw", game.winner == nil)
end

-- mounts
do
    local game = makeGame()
    local a = game.players.a
    check("base speed", game:effSpeed(a) == 144, game:effSpeed(a))
    game.items = { { x = 1, y = 1, kind = "turtle" } }
    game:tick()
    check("turtle mount", a.mount == "turtle")
    check("turtle speed", game:effSpeed(a) == 84, game:effSpeed(a))
    game.items = { { x = 1, y = 1, kind = "owl" } }
    game:tick()
    check("owl replaces", a.mount == "owl")
    check("owl speed", game:effSpeed(a) == 156, game:effSpeed(a))
end

-- mount absorbs one flame hit
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    game.items = { { x = 1, y = 1, kind = "pirateTurtle" } }
    game:tick()
    check("pirate turtle mount", a.mount == "pirateTurtle")
    setTilePos(game, "a", 5, 5)
    setTilePos(game, "b", 5, 5)
    check("mount absorb bomb", game:placeBomb("b"))
    setTilePos(game, "b", 9, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS)
    check("mount consumed", a.mount == nil)
    check("mount absorbed trap", not a.trapped)
    check("mount grace", a.grace > 0, a.grace)

    a.grace = 0
    setTilePos(game, "b", 6, 5)
    check("second trap bomb", game:placeBomb("b"))
    setTilePos(game, "b", 1, 9)
    tickN(game, Constants.BOMB_FUSE_TICKS + 1)
    check("no mount trapped", a.trapped)
end

-- UFO
do
    local game = makeGame()
    local a = game.players.a
    game.items = { { x = 1, y = 1, kind = "ufo" } }
    game:tick()
    check("ufo mount", a.mount == "ufo")
    game.grid[3][3] = Map.SOFT
    check("ufo flies over soft", not game:solidFor(3, 3, a))
    check("ufo blocked by border", game:solidFor(-1, 3, a))
    check("ufo blocked top border", game:solidFor(3, -1, a))
    game.items = { { x = 1, y = 1, kind = "potion" } }
    game:tick()
    check("ufo cannot pick", #game.items == 1, #game.items)
    check("ufo range unchanged", a.range == 1, a.range)
end

-- initial mounts
do
    local game = makeGame()
    local mounts = {}
    for _, item in ipairs(game.items) do
        if item.kind == "turtle" or item.kind == "owl" or item.kind == "pirateTurtle" then
            mounts[item.kind] = (mounts[item.kind] or 0) + 1
        end
    end
    check("six initial mounts", (#game.items == 6), #game.items)
    check("two initial turtles", mounts.turtle == 2, mounts.turtle)
    check("two initial owls", mounts.owl == 2, mounts.owl)
    check("two initial pirate turtles", mounts.pirateTurtle == 2, mounts.pirateTurtle)
end

-- snapshot / grid only when changed
do
    local game = makeGame()
    local first = game:snapshot()
    check("snapshot has grid first time", first.grid ~= nil)
    local second = game:snapshot()
    check("snapshot omits unchanged grid", second.grid == nil)
    game.gridVer += 1
    local third = game:snapshot()
    check("snapshot sends changed grid", third.grid ~= nil)
end

-- forced sync snapshots always carry the map without consuming the pending flag
do
    local game = makeGame()
    game:snapshot()
    game.gridVer += 1
    local sync = game:snapshot(true)
    check("forced snapshot includes grid", sync.grid ~= nil)
    local normal = game:snapshot()
    check("forced snapshot preserves pending grid flag", normal.grid ~= nil)
    local after = game:snapshot()
    check("grid flag clears after normal snapshot", after.grid == nil)
end

-- last survivor wins
do
    local game = makeGame()
    game:kill(game.players.b)
    game:tick()
    check("survivor wins", game.over and game.winner and game.winner.id == "a")
end

-- brought items, map pickups and settlement usage
do
    local game = makeGame(nil, 0, {
        { id = "a", name = "A", carry = { needle = 2, remote = 1, kick = 1 } },
        { id = "b", name = "B" },
    })
    clearField(game)
    setTilePos(game, "a", 1, 1)
    local a, b = game.players.a, game.players.b

    check("carried needle starts in inventory", a.inv.needle == 2, a.inv.needle)
    check("carried remote starts in inventory", a.inv.remote == 1, a.inv.remote)
    check("a carried kick enables kicking", a.kick == true)
    check("a player without items cannot kick", b.kick == false)

    check("a remote can be placed", game:placeBomb("a", true))
    check("placing a remote consumes one", a.inv.remote == 0, a.inv.remote)
    check("placing a remote records its use", a.used.remote == 1, a.used.remote)

    a.trapped = true
    check("a carried needle frees a trapped player", game:useItem("a"))
    check("using a needle consumes one", a.inv.needle == 1, a.inv.needle)
    check("using a needle records its use", a.used.needle == 1, a.used.needle)

    -- Simulate a map pickup. It changes the live inventory, not the brought
    -- snapshot that settlement is capped against.
    a.inv.needle += 1
    a.trapped = true
    check("a picked-up needle can also be used", game:useItem("a"))
    check("only carried stock is tracked as brought", a.carried.needle == 2, a.carried.needle)
    check("all real needs count as usage", a.used.needle == 2, a.used.needle)

    -- Put a bomb directly in front of A and kick it.
    setTilePos(game, "b", 2, 1)
    check("B places the kick target", game:placeBomb("b"))
    game:tryKick(a, "right")
    check("a successful kick is recorded once", a.used.kick == 1, a.used.kick)

    local used, carried = game:getItemUsage("a")
    check("usage snapshot has all three items", used.needle == 2 and used.remote == 1 and used.kick == 1)
    check("carry snapshot is independent from live inventory",
        carried.needle == 2 and carried.remote == 1 and carried.kick == 1)
    check("a player without brought items has zero carry",
        game:getItemUsage("b").needle == 0)
    check("an unknown player has no usage", game:getItemUsage("nobody") == nil)
end

---------------------------------------------------------------- 玩家颜色与出生位置

do
    local game = Game.new({
        { id = "a", name = "A", colorIndex = 5 },
        { id = "b", name = "B", colorIndex = 5 },
        { id = "c", name = "C", colorIndex = 7 },
        { id = "d", name = "D" },
    }, {
        random = function()
            return 0.99
        end,
        warmup = 0,
    })
    check("explicit color is used", game.players.a.colorIndex == 5, game.players.a.colorIndex)
    check("duplicate colors are allowed", game.players.b.colorIndex == 5, game.players.b.colorIndex)
    check("out-of-range color falls back to the seat",
        game.players.c.colorIndex == 2, game.players.c.colorIndex)
    check("missing color falls back to the seat",
        game.players.d.colorIndex == 3, game.players.d.colorIndex)
    for i, id in ipairs({ "a", "b", "c", "d" }) do
        local player = game.players[id]
        local spawn = Map.SPAWNS[i]
        check("spawn " .. id .. " follows seat order",
            player.x == spawn[1] * TILE + TILE / 2
                and player.y == spawn[2] * TILE + TILE / 2)
        check("color " .. id .. " is in range",
            player.colorIndex >= 0 and player.colorIndex < Characters.COLOR_COUNT)
    end
end

TestLib.finish()
