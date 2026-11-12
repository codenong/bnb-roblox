-- Unit tests for the real client-side Prediction module. The shared Constants,
-- Grid and Movement modules are the same ones the server uses, so these tests
-- also pin down that the collector and the authoritative simulation agree.
local TestLib = require("./testlib")
local Env = require("./ClientEnv")

local check = TestLib.check
local near = TestLib.near

local game = Env.game -- required by Prediction's ReplicatedStorage lookup

local Constants = require("./Constants")
local Grid = require("./Grid")
local Prediction = require("./Prediction")

local TILE = Constants.TILE
local DT = Constants.DT
local STEP = 144 * DT -- base speed per tick: 4.8px

local function emptyRows()
    local rows = {}
    for y = 1, Constants.ROWS do
        rows[y] = string.rep(".", Constants.COLS)
    end
    return rows
end

-- Horizontal corridor with solid rows above/below, so a pass list is the only
-- way through a bomb in the player's lane.
local function corridorRows()
    local rows = {}
    for y = 1, Constants.ROWS do
        if y == 1 or y == 3 then
            rows[y] = string.rep("#", Constants.COLS)
        else
            rows[y] = "#" .. string.rep(".", Constants.COLS - 2) .. "#"
        end
    end
    return rows
end

local function playerData(id, x, y, over)
    local data = {
        id = id,
        x = math.floor(x + 0.5),
        y = math.floor(y + 0.5),
        fx = x,
        fy = y,
        ack = 0,
        alive = true,
        trapped = false,
        speed = 144,
    }
    for key, value in pairs(over or {}) do
        data[key] = value
    end
    return data
end

local function snapshot(over)
    local result = {
        warmup = 0,
        players = { playerData("u1", 60, 60) },
        bombs = {},
        crateSlides = {},
    }
    for key, value in pairs(over or {}) do
        result[key] = value
    end
    return result
end

local function find(snap, id)
    for _, entry in ipairs(snap.players) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

---------------------------------------------------------------- 激活与位置

do
    local pred = Prediction.new()
    check("prediction starts inactive", pred:isActive() == false)
    check("inactive prediction has no render position", pred:getRenderPosition(0) == nil)
    check("inactive prediction has no target", pred:getTargetPosition() == nil)

    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    check("a playing snapshot activates prediction", pred:isActive() == true)
    local x, y = pred:getRenderPosition(1)
    check("prediction starts exactly on the authoritative position",
        near(x, 60) and near(y, 60), tostring(x) .. "," .. tostring(y))

    check("step advances while active", pred:step(1, { "right" }, 2) == true)
    local tx, ty = pred:getTargetPosition()
    check("one step is one 30Hz movement tick", near(tx, 60 + STEP) and near(ty, 60),
        tostring(tx) .. "," .. tostring(ty))

    -- Mid-tick render position is interpolated from the previous target.
    local rx = pred:getRenderPosition(2 + DT / 2)
    check("render position interpolates between ticks", near(rx, 60 + STEP / 2), rx)

    check("step with no local player does nothing", pred:step(2, {}, 3) == true)
end

---------------------------------------------------------------- ack 之后的回放

do
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    pred:step(1, { "right" }, 1)
    pred:step(2, { "right" }, 1 + DT)

    -- Server applied seq 1 only and reports a slightly different position (a
    -- real server tick can differ by a fraction of a step). Replaying the
    -- pending seq 2 from there is authoritative for the shadow.
    local snapAt = 1 + DT * 1.5
    local snap = snapshot({
        players = { playerData("u1", 60 + STEP - 2.8, 60, { ack = 1 }) },
    })
    pred:onSnapshot(snap, "u1", snapAt)
    check("ack is exposed for diagnostics", pred:getAck() == 1)
    local tx = pred:getTargetPosition()
    check("pending input is replayed from the server position",
        near(tx, 60 + 2 * STEP - 2.8), tx)

    -- The visual position must not jump to the corrected target; the difference
    -- becomes a short correction instead. Halfway between ticks the visual was
    -- at 60 + 1.5 steps, so the correction is the small gap to 60 + 1.2 steps.
    local rx = pred:getRenderPosition(snapAt)
    check("small corrections do not teleport the visual",
        near(rx, 60 + 1.5 * STEP), rx)
    pred:update(0.5)
    local eased = pred:getRenderPosition(snapAt)
    check("small corrections ease out over time",
        near(eased, 60 + 2 * STEP - 2.8, 0.06), eased)

    -- An ack that already covers every command must not apply them twice.
    local acked = snapshot({
        players = { playerData("u1", 60 + 2 * STEP, 60, { ack = 2 }) },
    })
    pred:onSnapshot(acked, "u1", 2)
    local double = pred:getTargetPosition()
    check("acknowledged commands are never replayed", near(double, 60 + 2 * STEP), double)
end

---------------------------------------------------------------- 旧 ack 与瞬移

do
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    pred:step(1, { "right" }, 1)
    pred:step(2, { "right" }, 1 + DT)
    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60 + STEP, 60, { ack = 2 }) } }),
        "u1",
        2
    )
    local before = pred:getTargetPosition()

    -- GetSync answers can cross a live broadcast. A lower ack must be ignored.
    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 1 }) } }),
        "u1",
        2.1
    )
    local after = pred:getTargetPosition()
    check("a regressing ack is ignored", pred:getAck() == 2 and near(after, before),
        tostring(after))

    -- A large mismatch (bomb/explosion/trap outcome) snaps instead of gliding.
    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 400, 60, { ack = 2 }) } }),
        "u1",
        2.2
    )
    local snapped = pred:getRenderPosition(2.2)
    check("large corrections snap", near(snapped, 400, 0.001), snapped)
end

---------------------------------------------------------------- 无法预测的状态

do
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows(), warmup = 30 }), "u1", 1)
    check("warmup disables prediction", pred:isActive() == false)
    check("step is ignored while inactive", pred:step(1, { "right" }, 1) == false)

    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { trapped = true }) } }),
        "u1",
        2
    )
    check("trapped disables prediction", pred:isActive() == false)

    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { alive = false }) } }),
        "u1",
        3
    )
    check("dead disables prediction", pred:isActive() == false)

    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 5 }) } }),
        "u1",
        4
    )
    check("a finished warmup re-enables prediction", pred:isActive() == true)

    -- Older servers without acks must fall back to snapshot interpolation.
    local legacy = Prediction.new()
    legacy:onSnapshot(
        snapshot({ grid = emptyRows(), players = { playerData("u1", 60, 60) } }),
        "u1",
        5
    )
    legacy:onSnapshot(
        snapshot({ grid = emptyRows(), players = { { id = "u1", x = 60, y = 60, alive = true } } }),
        "u1",
        6
    )
    check("a snapshot without ack stays inactive", legacy:isActive() == false)

    local missing = Prediction.new()
    missing:onSnapshot(snapshot({ grid = emptyRows(), players = {} }), "u1", 7)
    check("a snapshot without the local player stays inactive", missing:isActive() == false)
end

---------------------------------------------------------------- 地图种子与炸弹通行证

do
    -- RoundState carries the map; later snapshots omit it until a crate breaks.
    local pred = Prediction.new()
    pred:setGrid(emptyRows())
    pred:onSnapshot(snapshot(), "u1", 1)
    check("a setGrid seed activates prediction", pred:isActive() == true)

    local bombAtTwo = {
        { id = 1, x = 2, y = 1, sx = 100, sy = 60, fuse = 75, remote = false, owner = "u1", pass = { "u1" } },
    }
    local withPass = Prediction.new()
    withPass:onSnapshot(
        snapshot({ grid = corridorRows(), bombs = bombAtTwo }),
        "u1",
        1
    )
    for i = 1, 6 do
        withPass:step(i, { "right" }, 1 + i * DT)
    end
    local passX = withPass:getTargetPosition()
    check("the owner can predict walking through a pass bomb", passX > 2 * TILE, passX)

    local blockedBomb = {
        { id = 2, x = 2, y = 1, sx = 100, sy = 60, fuse = 75, remote = false, owner = "other", pass = {} },
    }
    local blocked = Prediction.new()
    blocked:onSnapshot(
        snapshot({ grid = corridorRows(), bombs = blockedBomb }),
        "u1",
        1
    )
    for i = 1, 6 do
        blocked:step(i, { "right" }, 1 + i * DT)
    end
    local blockedX = blocked:getTargetPosition()
    check("someone else's bomb blocks prediction", blockedX <= 2 * TILE, blockedX)

    -- A sliding crate's destination tile is solid until the slide finishes.
    local sliding = Prediction.new()
    sliding:onSnapshot(
        snapshot({
            grid = corridorRows(),
            crateSlides = { { fx = 1, fy = 1, tx = 2, ty = 1, left = 3, total = 6 } },
        }),
        "u1",
        1
    )
    for i = 1, 6 do
        sliding:step(i, { "right" }, 1 + i * DT)
    end
    local slideX = sliding:getTargetPosition()
    check("a sliding crate blocks prediction", slideX <= 2 * TILE, slideX)
end

---------------------------------------------------------------- 放泡泡预测

do
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    local active, made = pred:step(1, { "right" }, 1, true)
    check("an active prediction accepts a placement command", active == true)
    check("placement reports that a local bomb was created", made == true)

    local bombs = pred:getPredictedBombs()
    check("the predicted bomb is exposed to the renderer", #bombs == 1, #bombs)
    check("the predicted bomb array is stable", pred:getPredictedBombs() == bombs)
    local bomb = bombs[1]
    check("the predicted bomb has a string id", bomb and bomb.id == "p1", bomb and bomb.id)
    check("the bomb uses the pre-move tile", bomb and bomb.tx == 1 and bomb.ty == 1,
        bomb and (tostring(bomb.tx) .. "," .. tostring(bomb.ty)))
    check("the bomb carries its ordered sequence", bomb and bomb.seq == 1)
    check("the bomb is centred on the tile", bomb and near(bomb.sx, 60) and near(bomb.sy, 60),
        bomb and (tostring(bomb.sx) .. "," .. tostring(bomb.sy)))
    check("the bomb starts with a full fuse", bomb and bomb.fuse == Constants.BOMB_FUSE_TICKS)
    check("the bomb is owned by the local player", bomb and bomb.owner == "u1")
    check("the predicted bomb is not remote", bomb and bomb.remote == false)
    check("the owner can stand on the predicted bomb", bomb and bomb.pass["u1"] == true)

    local _, second = pred:step(2, { "right" }, 1 + DT, false)
    check("a command without place creates nothing", second == false and #bombs == 1)
end

---------------------------------------------------------------- 本地拒绝明显的非法放置

do
    -- Same tile: the first prediction is still there.
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    check("the first placement is predicted", select(2, pred:step(1, {}, 1, true)) == true)
    check("a second bomb on the same tile is refused locally",
        select(2, pred:step(2, {}, 1 + DT, true)) == false)
    check("the refusal did not add a bomb", #pred:getPredictedBombs() == 1)

    -- Bomb/stock cap: walk out of the first bomb's tile, then try again.
    local capped = Prediction.new()
    capped:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    capped:step(1, {}, 1, true)
    for i = 2, 12 do
        capped:step(i, { "right" }, 1 + (i - 1) * DT)
    end
    check("the prediction walked off its own bomb", capped:getTargetPosition() > 2 * TILE)
    check("the max-bomb limit refuses another local placement",
        select(2, capped:step(13, { "right" }, 1 + 12 * DT, true)) == false)
    check("no extra bomb was predicted", #capped:getPredictedBombs() == 1)

    -- A remote bomb is already out: Game detonates instead of placing.
    local remote = Prediction.new()
    remote:onSnapshot(
        snapshot({
            grid = emptyRows(),
            players = { playerData("u1", 60, 60, { maxBombs = 2 }) },
            bombs = {
                {
                    id = 9,
                    x = 3,
                    y = 1,
                    sx = 140,
                    sy = 60,
                    fuse = 9999,
                    remote = true,
                    owner = "u1",
                    pass = {},
                },
            },
        }),
        "u1",
        1
    )
    check("a placement with a remote out is refused locally",
        select(2, remote:step(1, {}, 1, true)) == false)
    check("no normal bomb was predicted", #remote:getPredictedBombs() == 0)

    -- Trapped/warmup states do not predict at all.
    local inactive = Prediction.new()
    inactive:onSnapshot(snapshot({ grid = emptyRows(), warmup = 10 }), "u1", 1)
    check("inactive prediction does not accept a placement",
        select(2, inactive:step(1, {}, 1, true)) == false)
    check("inactive prediction has no bombs", #inactive:getPredictedBombs() == 0)
end

---------------------------------------------------------------- 预测泡泡的 pass 与碰撞

do
    local pred = Prediction.new()
    pred:onSnapshot(
        snapshot({ grid = corridorRows(), players = { playerData("u1", 60, 60) } }),
        "u1",
        1
    )
    pred:step(1, {}, 1, true)
    local bomb = pred:getPredictedBombs()[1]
    check("the bomb starts with an owner pass", bomb and bomb.pass["u1"] == true)

    -- Walk right until the owner no longer overlaps the bomb tile.
    for i = 2, 13 do
        pred:step(i, { "right" }, 1 + (i - 1) * DT)
    end
    check("leaving the bomb tile removes the pass", bomb and bomb.pass["u1"] == nil)

    -- Walking back must stop at the bomb instead of passing through it.
    for i = 14, 26 do
        pred:step(i, { "left" }, 1 + (i - 1) * DT)
    end
    local x = pred:getTargetPosition()
    check("re-entering the bomb tile is blocked", x > 90, x)
end

---------------------------------------------------------------- 服务器确认 / 拒绝 / TTL

do
    -- Confirmation is by owner+seq; the bomb may have been kicked to a new tile.
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    pred:step(5, {}, 1, true)
    pred:onSnapshot(
        snapshot({
            players = { playerData("u1", 60, 60, { ack = 5 }) },
            bombs = {
                { id = 21, x = 7, y = 7, sx = 300, sy = 300, fuse = 74, remote = false, owner = "u1", seq = 5, pass = {} },
            },
        }),
        "u1",
        2
    )
    check("a server bomb with the same owner+seq confirms the prediction",
        #pred:getPredictedBombs() == 0)

    -- The local sound is suppressed once, even after confirmation.
    check("a queued server sound can still be consumed after confirmation",
        pred:consumePlaceFx(5) == true)
    check("the suppression entry is removed after use", pred:consumePlaceFx(5) == false)

    -- Ack covers the command but no bomb exists: the server rejected it.
    local rejected = Prediction.new()
    rejected:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    rejected:step(3, {}, 1, true)
    rejected:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 2 }) } }),
        "u1",
        2
    )
    check("an unacknowledged prediction with no match is kept",
        #rejected:getPredictedBombs() == 1)
    rejected:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 3 }) } }),
        "u1",
        3
    )
    check("an acked prediction without a matching bomb is rejected",
        #rejected:getPredictedBombs() == 0)

    -- A stale snapshot must neither clear nor roll back the prediction.
    local stale = Prediction.new()
    stale:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    stale:step(4, {}, 1, true)
    stale:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 3 }) } }),
        "u1",
        2
    )
    stale:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 2 }) } }),
        "u1",
        3
    )
    check("an older ack snapshot does not drop a newer prediction",
        #stale:getPredictedBombs() == 1 and stale:getAck() == 3)

    -- TTL fallback for a server that never answers this sequence.
    local ttl = Prediction.new()
    ttl:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    ttl:step(1, {}, 1, true)
    ttl:onSnapshot(snapshot({ players = { playerData("u1", 60, 60, { ack = 0 }) } }), "u1", 5)
    check("an unanswered prediction expires after its TTL",
        #ttl:getPredictedBombs() == 0)

    -- reset clears predictions and pending sound suppression.
    local reset = Prediction.new()
    reset:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    reset:step(1, {}, 1, true)
    reset:reset()
    check("reset clears predicted bombs", #reset:getPredictedBombs() == 0)
    check("reset clears pending sound suppression", reset:consumePlaceFx(1) == false)
end

---------------------------------------------------------------- 按 sequence 回放注入

do
    -- Ten commands move the player two tiles right, then seq 11 places. On a
    -- snapshot that has applied none of them, the bomb must only enter the world
    -- when seq 11 is replayed. Injecting it up front would block the earlier
    -- movement that the server already performed.
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    for i = 1, 10 do
        pred:step(i, { "right" }, 1 + i * DT)
    end
    pred:step(11, { "right" }, 1 + 11 * DT, true)
    local bomb = pred:getPredictedBombs()[1]
    check("the test bomb is on the tile reached by the earlier commands",
        bomb and bomb.tx == 2 and bomb.ty == 1, bomb and tostring(bomb.tx))

    pred:onSnapshot(
        snapshot({ players = { playerData("u1", 60, 60, { ack = 0 }) }, bombs = {} }),
        "u1",
        1 + 11 * DT
    )
    local x, y = pred:getTargetPosition()
    check("replay reaches the same position as the ordered placement",
        near(x, 60 + 11 * STEP, 0.11) and near(y, 60, 0.11),
        tostring(x) .. "," .. tostring(y))
    check("the bomb survived the replay", #pred:getPredictedBombs() == 1)
end

---------------------------------------------------------------- reset

do
    local pred = Prediction.new()
    pred:onSnapshot(snapshot({ grid = emptyRows() }), "u1", 1)
    pred:step(1, { "right" }, 1)
    pred:reset()
    check("reset deactivates prediction", pred:isActive() == false)
    check("reset clears the visual", pred:getRenderPosition(1) == nil)
end

TestLib.finish()
