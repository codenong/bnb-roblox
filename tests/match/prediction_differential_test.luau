-- Frame-by-frame differential between the authoritative Game and the client
-- Prediction shadow. Both use the same Movement module; this test pins down that
-- one command produces the same position, blocked ticks included, and that a
-- placement command creates the same bomb tile on both sides.
local TestLib = require("./testlib")
local check = TestLib.check
local near = TestLib.near

local Constants = require("./Constants")
local Grid = require("./Grid")
local Game = require("./Game")
local Prediction = require("./Prediction")

local TILE = Constants.TILE
local DT = Constants.DT
local STEP = 144 * DT
local COLS = Constants.COLS
local ROWS = Constants.ROWS

local function borderRows()
    local rows = {}
    for y = 1, ROWS do
        if y == 1 or y == ROWS then
            rows[y] = string.rep("#", COLS)
        else
            rows[y] = "#" .. string.rep(".", COLS - 2) .. "#"
        end
    end
    return rows
end

-- One human plus one inert bot: checkOver otherwise ends a one-player round on
-- the first tick.
local function newGame()
    local game = Game.new({
        { id = "u1", name = "U1", char = "baobao" },
        { id = "bot", name = "Bot", char = "haidao", isBot = true },
    }, { warmup = 0 })
    game.grid = Grid.rowsToGrid(borderRows())
    game.items = {}
    game.lootShots = {}
    game.crateSlides = {}
    return game
end

local function snapshotFor(game, prediction, id, now)
    local snap = game:snapshot(true)
    prediction:onSnapshot(snap, id, now)
    return snap
end

local function playerEntry(snap, id)
    for _, entry in ipairs(snap.players or {}) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

---------------------------------------------------------------- 随机方向逐帧对拍

do
    local game = newGame()
    local prediction = Prediction.new()
    local now = 1
    local first = snapshotFor(game, prediction, "u1", now)
    check("prediction activates for the differential", prediction:isActive() == true)
    local start = playerEntry(first, "u1")

    -- A deterministic path that repeatedly walks into the border walls.
    local pattern = { "right", "right", "down", "down", "left", "up", "up", "left" }
    local moved = 0
    local maxError = 0
    for seq = 1, 240 do
        local dirs = if seq % 37 == 0 then {} else { pattern[(seq - 1) % #pattern + 1] }
        game:setInput("u1", dirs, seq)
        prediction:step(seq, dirs, now)
        game:tick()
        local snap = game:snapshot()
        prediction:onSnapshot(snap, "u1", now + 0.001)
        local entry = playerEntry(snap, "u1")
        local tx, ty = prediction:getTargetPosition()
        local errorX = math.abs(tx - entry.fx)
        local errorY = math.abs(ty - entry.fy)
        maxError = math.max(maxError, errorX, errorY)
        if snap.tick > 1 and (entry.fx ~= start.fx or entry.fy ~= start.fy) then
            moved += 1
        end
        now += DT
    end

    check("the differential actually moved the player", moved > 40, moved)
    check("every frame stays within the 0.1px snapshot quantization",
        maxError <= 0.1001, maxError)
    local finalEntry = playerEntry(game:snapshot(), "u1")
    local fx, fy = prediction:getTargetPosition()
    check("the final predicted target equals the authoritative snapshot",
        near(fx, finalEntry.fx, 0.1001) and near(fy, finalEntry.fy, 0.1001),
        tostring(fx) .. "," .. tostring(fy) .. " vs "
            .. tostring(finalEntry.fx) .. "," .. tostring(finalEntry.fy))
    check("no snap was reported during ordinary movement", prediction.lastSnapped == false)
end

---------------------------------------------------------------- 边跑边放：同一个移动前格子

do
    local game = newGame()
    local prediction = Prediction.new()
    local now = 1
    local player = game.players.u1
    player.x = 78
    player.y = 60
    local first = snapshotFor(game, prediction, "u1", now)
    local entry = playerEntry(first, "u1")
    check("the differential starts at the boundary-adjacent position",
        entry.fx == 78 and entry.fy == 60)

    game:setInput("u1", { "right" }, 1, true)
    local _, made = prediction:step(1, { "right" }, now, true)
    check("the client predicts the placement", made == true)
    local predicted = prediction:getPredictedBombs()[1]
    check("the predicted bomb is on the pre-move tile",
        predicted and predicted.tx == 1 and predicted.ty == 1,
        predicted and tostring(predicted.tx))
    check("the predicted bomb gets the owner pass",
        predicted and predicted.pass["u1"] == true)

    game:tick()
    local snap = game:snapshot()
    local bomb = snap.bombs[1]
    check("the server placed exactly one bomb", #snap.bombs == 1, #snap.bombs)
    check("server and client agree on the bomb tile",
        bomb and bomb.x == 1 and bomb.y == 1,
        bomb and (tostring(bomb.x) .. "," .. tostring(bomb.y)))
    check("the server bomb carries the command sequence", bomb and bomb.seq == 1)
    local serverPass = false
    for _, id in ipairs(bomb and bomb.pass or {}) do
        if id == "u1" then
            serverPass = true
        end
    end
    check("server and client agree on the owner pass", serverPass)
    check("the player crossed into the next tile after placement",
        game.players.u1.x > 2 * TILE, game.players.u1.x)

    prediction:onSnapshot(snap, "u1", now + 0.001)
    check("the confirmation removes the predicted bomb",
        #prediction:getPredictedBombs() == 0)
    local tx, ty = prediction:getTargetPosition()
    check("the placement frame's position still matches",
        near(tx, snap.players[1].fx, 0.1001) and near(ty, snap.players[1].fy, 0.1001),
        tostring(tx) .. "," .. tostring(ty))
end

---------------------------------------------------------------- 同格拒绝：两边都不产生新泡泡

do
    local game = newGame()
    local prediction = Prediction.new()
    local now = 1
    snapshotFor(game, prediction, "u1", now)

    game:setInput("u1", {}, 1, true)
    local _, firstMade = prediction:step(1, {}, now, true)
    check("the first placement is predicted", firstMade == true)
    game:tick()
    local snap = game:snapshot()
    prediction:onSnapshot(snap, "u1", now + 0.001)
    check("the first server bomb exists", #game.bombs == 1)
    check("the first prediction was confirmed", #prediction:getPredictedBombs() == 0)

    now += DT
    game:setInput("u1", {}, 2, true)
    local _, secondMade = prediction:step(2, {}, now, true)
    check("the client refuses a second bomb on the same tile", secondMade == false)
    game:tick()
    local rejected = game:snapshot()
    prediction:onSnapshot(rejected, "u1", now + 0.001)
    check("the server refuses a second bomb on the same tile",
        #rejected.bombs == 1, #rejected.bombs)
    check("the server still acknowledges the rejected command",
        playerEntry(rejected, "u1").ack == 2)
    check("the client has no leftover prediction",
        #prediction:getPredictedBombs() == 0)
end

---------------------------------------------------------------- 遥控在外：两边都不新放普通泡泡

do
    local game = newGame()
    local prediction = Prediction.new()
    local now = 1
    game.players.u1.inv.remote = 1
    check("the differential remote bomb was created", game:placeBomb("u1", true) == true)
    local snap = snapshotFor(game, prediction, "u1", now)

    game:setInput("u1", {}, 1, true)
    local _, made = prediction:step(1, {}, now, true)
    check("the client refuses a normal bomb while a remote is out", made == false)
    check("the server did not create a second bomb", #game.bombs == 1, #game.bombs)
    check("the remote was detonated instead", game.bombs[1].fuse == 0)
    check("the ack still advanced", game.players.u1.ack == 1)
    check("the client predicted nothing", #prediction:getPredictedBombs() == 0)
end

TestLib.finish()
