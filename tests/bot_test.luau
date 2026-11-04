local TestLib = require("./testlib")
local Constants = require("./Constants")
local Map = require("./Map")
local Game = require("./Game")
local Bot = require("./Bot")

local check = TestLib.check
local TILE = Constants.TILE

local function clearField(game)
    for y = 0, Constants.ROWS - 1 do
        for x = 0, Constants.COLS - 1 do
            game.grid[y][x] = Map.EMPTY
        end
    end
    game.items = {}
end

local function makeGame()
    return Game.new({
        { id = "a", name = "A", isBot = true },
        { id = "b", name = "B", isBot = true },
        -- Game ends immediately when every participant is a bot; keep one
        -- human alive so bomb/explosion tests can advance.
        { id = "h", name = "Human" },
    }, {
        random = function()
            return 0.1
        end,
        warmup = 0,
    })
end

-- Danger map of normal bombs; remote bombs are excluded.
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.x, a.y = 2 * TILE + TILE / 2, 2 * TILE + TILE / 2
    check("bot test bomb", game:placeBomb("a"))
    local danger = Bot.flameDangerMap(game)
    check("danger origin", danger["2,2"] == true)
    check("danger right arm", danger["3,2"] == true)
    check("danger up arm", danger["2,1"] == true)

    local b = game.players.b
    b.inv.remote = 1
    b.x, b.y = 5 * TILE + TILE / 2, 5 * TILE + TILE / 2
    check("bot remote", game:useItem("b"))
    local danger2 = Bot.flameDangerMap(game)
    check("remote excluded from danger", danger2["5,5"] ~= true)
end

-- Explosion set is hard danger.
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.x, a.y = 2 * TILE + TILE / 2, 2 * TILE + TILE / 2
    game.players.b.x, game.players.b.y = 9 * TILE + TILE / 2, 9 * TILE + TILE / 2
    check("explosion bomb", game:placeBomb("a"))
    game.players.a.x, game.players.a.y = 9 * TILE + TILE / 2, 9 * TILE + TILE / 2
    for _ = 1, Constants.BOMB_FUSE_TICKS do
        game:tick()
    end
    local boom = Bot.explosionSet(game)
    check("explosion set origin", boom["2,2"] == true, boom["2,2"])
    check("explosion set arm", boom["3,2"] == true, boom["3,2"])
end

-- Trapped bot uses a needle if available.
do
    local game = makeGame()
    local a = game.players.a
    a.trapped = true
    a.inv.needle = 1
    local decision = Bot.new("a"):decide(game)
    check("trapped bot uses needle", decision.use == true)
    check("trapped bot does not place", decision.place == false)
    check("trapped bot does not move", #decision.dirs == 0)
end

-- Bot places a bomb when adjacent to a soft crate and has an escape route.
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.x, a.y = 1 * TILE + TILE / 2, 1 * TILE + TILE / 2
    game.players.b.x, game.players.b.y = 9 * TILE + TILE / 2, 9 * TILE + TILE / 2
    game.grid[1][2] = Map.SOFT
    local decision = Bot.new("a"):decide(game)
    check("bot decides to bomb soft", decision.place == true, decision.place)
    check("bot has escape direction", #decision.dirs == 1, #decision.dirs)
end

-- Bot escapes when standing in bomb danger.
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.x, a.y = 2 * TILE + TILE / 2, 2 * TILE + TILE / 2
    local b = game.players.b
    b.x, b.y = 2 * TILE + TILE / 2, 2 * TILE + TILE / 2
    check("bot danger bomb", game:placeBomb("b"))
    b.x, b.y = 9 * TILE + TILE / 2, 9 * TILE + TILE / 2
    local brain = Bot.new("a")
    local decision = brain:decide(game)
    check("bot flees danger", #decision.dirs == 1, #decision.dirs)
    check("bot does not bomb while fleeing", decision.place == false)
end

-- Own remote bomb is detonated after escaping its flame.
do
    local game = makeGame()
    clearField(game)
    local a = game.players.a
    a.x, a.y = 1 * TILE + TILE / 2, 1 * TILE + TILE / 2
    a.inv.remote = 1
    check("bot remote bomb", game:useItem("a"))
    a.x, a.y = 8 * TILE + TILE / 2, 8 * TILE + TILE / 2
    game.players.b.x, game.players.b.y = 12 * TILE + TILE / 2, 10 * TILE + TILE / 2
    local decision = Bot.new("a"):decide(game)
    check("bot detonates remote", decision.place == true)
end

-- 6-bot smoke: decisions run and the game reaches a terminal state or times out.
do
    local players = {}
    for i = 1, 6 do
        -- One non-bot keeps Game:checkOver from ending an all-bot match instantly.
        table.insert(players, { id = "bot" .. i, name = "Bot" .. i, isBot = i ~= 1 })
    end
    local game = Game.new(players, {
        random = function()
            return 0.42
        end,
        warmup = 0,
    })
    local brains = {}
    for _, player in ipairs(players) do
        brains[player.id] = Bot.new(player.id)
    end
    for _ = 1, 1200 do
        if game.over then
            break
        end
        for _, player in ipairs(players) do
            if game.players[player.id].alive then
                local decision = brains[player.id]:decide(game)
                game:setInput(player.id, decision.dirs)
                if decision.place then
                    game:placeBomb(player.id, false)
                end
                if decision.use then
                    game:useItem(player.id)
                end
            end
        end
        game:tick()
    end
    check("bot smoke progresses", game.tickCount > 0, game.tickCount)
    if game.over then
        check("bot smoke has winner or draw", game.winner == nil or game.winner.alive)
    else
        check("bot smoke still running", game.tickCount == 1200, game.tickCount)
    end
end

TestLib.finish()
