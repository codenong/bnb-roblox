-- Deterministic network simulation for reconciliation: real Room, real
-- Prediction, delayed/jittered Input and Snapshot delivery on a logical clock.
-- No real waiting. Pins down (a) no >24px snaps under normal jitter, (b) final
-- convergence to the authoritative 0.1px snapshot, and (c) an ordered placement
-- being predicted locally and confirmed by owner+seq.
local TestLib = require("./testlib")
local check = TestLib.check
local near = TestLib.near

local Constants = require("./Constants")
local Grid = require("./Grid")
local Map = require("./Map")
local Prediction = require("./Prediction")
local Room = require("./Room")
local PlayerService = require("./PlayerService")
local Net = require("./Net")

local DT = Constants.DT
local COLS = Constants.COLS
local ROWS = Constants.ROWS

local nextUserId = 9850
local nextRoomId = 780

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

local function playerEntry(snapshot, id)
    for _, entry in ipairs(snapshot and snapshot.players or {}) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

-- Small LCG so jitter is identical on every run and platform.
local function makeRng(seed: number)
    local state = seed
    return function(): number
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
end

local function newHarness(opts)
    nextRoomId += 1
    nextUserId += 1
    local record = PlayerService.add({
        UserId = nextUserId,
        DisplayName = "Net" .. tostring(nextRoomId),
    })
    local room = Room.new({
        id = nextRoomId,
        mode = "practice",
        maxPlayers = 2,
        fillBots = true,
        waitingTicks = 1,
        resultsTicks = 4,
    })
    room:addMember(record)
    room:step()
    check("the network test round started", room:getPhase() == "playing", room:getPhase())
    room.game.warmup = 0
    room.game.grid = Grid.rowsToGrid(borderRows())
    room.game.items = {}
    room.game.lootShots = {}
    room.game.crateSlides = {}

    local prediction = Prediction.new()
    local initial = room.game:snapshot(true)
    prediction:onSnapshot(initial, record.id, 0)

    local h = {
        room = room,
        record = record,
        prediction = prediction,
        initial = initial,
        now = 0,
        sentSeq = 0,
        pendingInputs = {},
        pendingSnaps = {},
        latest = initial,
        maxDelta = 0,
        snapped = false,
        rng = makeRng(opts.seed or 1234567),
        inputBase = opts.inputBase or 0.060,
        inputSpread = opts.inputSpread or 0.020,
        snapBase = opts.snapBase or 0.060,
        snapSpread = opts.snapSpread or 0.025,
        order = 0,
        ignoredOldAck = 0,
    }

    Net.sendHook = function(_, name, payload)
        if name ~= "Snapshot" then
            return
        end
        local delay = h.snapBase + (h.rng() * 2 - 1) * h.snapSpread
        if delay < 0.001 then
            delay = 0.001
        end
        h.order += 1
        table.insert(h.pendingSnaps, {
            at = h.now + delay,
            order = h.order,
            snapshot = payload,
        })
    end

    local function sortDue(list)
        table.sort(list, function(a, b)
            if a.at == b.at then
                return a.order < b.order
            end
            return a.at < b.at
        end)
    end

    function h.deliverDue()
        sortDue(h.pendingSnaps)
        while h.pendingSnaps[1] and h.pendingSnaps[1].at <= h.now + 1e-9 do
            local item = table.remove(h.pendingSnaps, 1)
            local entry = playerEntry(item.snapshot, record.id)
            local beforeAck = prediction:getAck()
            if entry and type(entry.ack) == "number" and entry.ack < beforeAck then
                h.ignoredOldAck += 1
            end
            prediction:onSnapshot(item.snapshot, record.id, h.now)
            if entry and type(entry.ack) == "number" and entry.ack >= beforeAck then
                h.maxDelta = math.max(h.maxDelta, prediction.lastTargetDelta)
                if prediction.lastSnapped then
                    h.snapped = true
                end
            end
            if item.snapshot.tick >= (h.latest and h.latest.tick or -1) then
                h.latest = item.snapshot
            end
        end

        sortDue(h.pendingInputs)
        while h.pendingInputs[1] and h.pendingInputs[1].at <= h.now + 1e-9 do
            local item = table.remove(h.pendingInputs, 1)
            h.room:setInput(record, item.payload)
        end
    end

    function h.send(dirs, place)
        h.sentSeq += 1
        local seq = h.sentSeq
        local delay = h.inputBase + (h.rng() * 2 - 1) * h.inputSpread
        if delay < 0.001 then
            delay = 0.001
        end
        h.order += 1
        table.insert(h.pendingInputs, {
            at = h.now + delay,
            order = h.order,
            payload = {
                seq = seq,
                roundId = room.roundId,
                dirs = dirs,
                place = place,
            },
        })
        return prediction:step(seq, dirs, h.now, place)
    end

    function h.tick(dirs, place)
        h.now += DT
        h.deliverDue()
        local active, made = h.send(dirs or {}, place == true)
        h.room:step()
        return active, made
    end

    function h.advance()
        h.now += DT
        h.deliverDue()
        h.room:step()
    end

    function h.converged(): boolean
        local entry = playerEntry(h.latest, record.id)
        return entry ~= nil and type(entry.ack) == "number" and entry.ack == h.sentSeq
    end

    return h
end

---------------------------------------------------------------- 延迟 + 抖动下的移动对账

do
    local h = newHarness({
        seed = 24681357,
        inputBase = 0.060,
        inputSpread = 0.020,
        snapBase = 0.060,
        snapSpread = 0.025,
    })
    local prediction = h.prediction
    local record = h.record

    local pattern = {
        "right", "down", "right", "up", "left", "left", "down", "right", "up", "right",
    }
    local start = playerEntry(h.initial, record.id)
    local moved = false
    for i = 1, 180 do
        local dirs = { pattern[(i - 1) % #pattern + 1] }
        h.tick(dirs, false)
    end
    -- Stop pressing, but keep sending empty commands until the client's command
    -- stream is over; otherwise the server queue would still be authoritative.
    for _ = 1, 60 do
        h.tick({}, false)
    end
    for _ = 1, 80 do
        h.advance()
        if h.converged() then
            break
        end
    end
    local settled = playerEntry(h.latest, record.id)
    moved = settled ~= nil and (settled.fx ~= start.fx or settled.fy ~= start.fy)

    check("the simulated round produced movement", moved == true)
    check("all sent commands were applied", h.converged() == true,
        h.latest and playerEntry(h.latest, record.id) and playerEntry(h.latest, record.id).ack)
    check("no normal-jitter snapshot caused a >24px snap", h.snapped == false)
    -- A reordered/dropped command costs exactly one command tick of movement
    -- (144 px/s / 30 Hz = 4.8px) plus the 0.1px snapshot quantization.
    check("the largest correction stays within one command tick", h.maxDelta <= 5.0,
        h.maxDelta)
    check("out-of-order snapshots were actually exercised", h.ignoredOldAck > 0,
        h.ignoredOldAck)

    local latestEntry = playerEntry(h.latest, record.id)
    local tx, ty = prediction:getTargetPosition()
    check("the final prediction converges to the authoritative sub-pixel position",
        latestEntry ~= nil
            and near(tx, latestEntry.fx, 0.1001)
            and near(ty, latestEntry.fy, 0.1001),
        tostring(tx) .. "," .. tostring(ty) .. " vs "
            .. tostring(latestEntry and latestEntry.fx) .. ","
            .. tostring(latestEntry and latestEntry.fy))

    -- An explicit old-ack snapshot must neither roll back nor clear history.
    local ackBefore = prediction:getAck()
    local xBefore, yBefore = prediction:getTargetPosition()
    prediction:onSnapshot(h.initial, record.id, h.now)
    local xAfter, yAfter = prediction:getTargetPosition()
    check("an old initial snapshot is ignored", prediction:getAck() == ackBefore,
        prediction:getAck())
    check("an old snapshot does not move the shadow", near(xAfter, xBefore) and near(yAfter, yBefore),
        tostring(xBefore) .. "," .. tostring(yBefore) .. " -> "
            .. tostring(xAfter) .. "," .. tostring(yAfter))
end

---------------------------------------------------------------- 边跑边放的网络确认

do
    local h = newHarness({
        seed = 1928374,
        -- Fixed uplink delay so the single place command cannot be reordered.
        inputBase = 0.060,
        inputSpread = 0,
        snapBase = 0.060,
        snapSpread = 0.025,
    })
    local room = h.room
    local record = h.record
    local prediction = h.prediction

    -- One tick moves 4.8px: placing at 78 then moving right crosses into tile 2.
    room.game.players[record.id].x = 78
    room.game.players[record.id].y = 60
    local initial = room.game:snapshot(true)
    prediction:reset()
    prediction:onSnapshot(initial, record.id, 0)

    local created = false
    local confirmed = false
    for i = 1, 60 do
        local place = i == 1
        local active, made = h.tick({ "right" }, place)
        if made then
            created = true
            check("the local prediction appears immediately",
                #prediction:getPredictedBombs() == 1,
                #prediction:getPredictedBombs())
        end
        local entry = playerEntry(h.latest, record.id)
        if entry and entry.ack >= 1 then
            for _, bomb in ipairs(h.latest.bombs or {}) do
                if bomb.owner == record.id and bomb.seq == 1 then
                    confirmed = true
                end
            end
        end
        if confirmed and not place then
            break
        end
    end

    check("the placement was predicted locally", created == true)
    check("the server confirmed the predicted bomb", confirmed == true)
    check("confirmation removed the local prediction",
        #prediction:getPredictedBombs() == 0, #prediction:getPredictedBombs())
    check("the ordered sound suppression survived confirmation",
        prediction:consumePlaceFx(1) == true)
    check("the suppression is consumed only once", prediction:consumePlaceFx(1) == false)
    check("no snap occurred around the placement", h.snapped == false)

    local serverBomb = nil
    for _, bomb in ipairs(h.latest.bombs or {}) do
        if bomb.owner == record.id and bomb.seq == 1 then
            serverBomb = bomb
        end
    end
    check("the server bomb is on the pre-move tile", serverBomb
        and serverBomb.x == 1 and serverBomb.y == 1,
        serverBomb and (tostring(serverBomb.x) .. "," .. tostring(serverBomb.y)))
    local pass = false
    for _, id in ipairs(serverBomb and serverBomb.pass or {}) do
        if id == record.id then
            pass = true
        end
    end
    check("the server bomb keeps the owner pass", pass)
    check("the server player moved across the tile boundary after placing",
        room.game.players[record.id].x > 2 * Constants.TILE,
        room.game.players[record.id].x)

    -- Let the delayed empty commands drain, then check final convergence.
    for _ = 1, 80 do
        h.advance()
        if h.converged() then
            break
        end
    end
    check("the placement round acknowledged every command", h.converged() == true)
    local entry = playerEntry(h.latest, record.id)
    local tx, ty = prediction:getTargetPosition()
    check("the placement round converges to the authoritative position",
        entry ~= nil and near(tx, entry.fx, 0.1001) and near(ty, entry.fy, 0.1001),
        tostring(tx) .. "," .. tostring(ty))
    check("the server bomb survived confirmation", #h.latest.bombs >= 1)
end

---------------------------------------------------------------- 地图更新必须越过 ack 回退到达预测器

-- The failure this pins down: at high RTT the snapshot that carries a map
-- change can be reordered behind a newer ack. The old client applied its grid
-- to the board but the predictor's ack guard dropped it, so the cell stayed
-- solid for movement while the crate was already gone on screen. gridVer makes
-- the map application monotonic and independent of the ack guard.
do
    local h = newHarness({
        seed = 654321,
        inputBase = 0.400,
        inputSpread = 0,
        snapBase = 0.400,
        snapSpread = 0,
    })
    local room = h.room
    local record = h.record
    local prediction = h.prediction

    -- A soft crate right in front of the player's lane.
    room.game.players[record.id].x = 60
    room.game.players[record.id].y = 60
    room.game.grid[1][2] = Map.SOFT
    room.game.gridVer = 0

    local before = room.game:snapshot(true)
    prediction:reset()
    prediction:onSnapshot(before, record.id, h.now)
    check("the pre-change map carries gridVer 0", before.gridVer == 0, before.gridVer)

    -- The shadow pushes into the crate and stops at its edge.
    local blockedX = nil
    for i = 1, 40 do
        prediction:step(i, { "right" }, h.now)
    end
    local bx, by = prediction:getTargetPosition()
    blockedX = bx
    check("the shadow is stopped by the crate", bx ~= nil and bx <= 2 * Constants.TILE - Constants.HALF,
        blockedX)

    -- The server explodes the crate (the bomb path itself is covered by the
    -- game tests); the next snapshot carries the opened map at gridVer 1.
    room.game.grid[1][2] = Map.EMPTY
    room.game.gridVer += 1
    local gridSnapshot = room.game:snapshot(true)
    check("the map-change snapshot carries the new gridVer", gridSnapshot.gridVer == 1,
        gridSnapshot.gridVer)

    -- A later snapshot with no grid rows lands first and advances the ack.
    local function cloneWithoutGrid(snap, ackBump)
        local copy = {
            tick = snap.tick,
            warmup = snap.warmup,
            timeLeft = snap.timeLeft,
            players = {},
            bombs = {},
            expl = {},
            items = {},
            loot = {},
            crateSlides = {},
        }
        for _, p in ipairs(snap.players) do
            local entry = {}
            for key, value in pairs(p) do
                entry[key] = value
            end
            entry.ack = (entry.ack or 0) + ackBump
            table.insert(copy.players, entry)
        end
        return copy
    end
    prediction:onSnapshot(cloneWithoutGrid(gridSnapshot, 40), record.id, h.now)
    local ackAfterNewer = prediction:getAck()

    -- The map-change carrier finally arrives out of order, behind that newer
    -- ack. Its map rows must still reach the predictor; everything else stays
    -- at the newer state.
    prediction:onSnapshot(gridSnapshot, record.id, h.now)
    check("the reordered map change does not regress the ack", prediction:getAck() == ackAfterNewer,
        prediction:getAck())
    check("the predictor adopted the new map version", prediction:getGridVersion() == 1,
        prediction:getGridVersion())

    -- The opened crate tile must be open for the shadow's collision. Hold
    -- right and verify the shadow walks through where the crate was.
    local tx, ty = prediction:getTargetPosition()
    check("the shadow kept its position through the reorder", tx ~= nil and math.abs(tx - 60) < 0.001,
        tx)
    check("the lane stayed aligned through the reorder", ty ~= nil and math.abs(ty - 60) < 0.001, ty)

    -- Holding right now walks straight through where the crate was.
    local moved = false
    local lastSeq = ackAfterNewer
    for i = 1, 30 do
        lastSeq += 1
        prediction:step(lastSeq, { "right" }, h.now)
    end
    local fx, fy = prediction:getTargetPosition()
    moved = fx ~= nil and fx > 2 * Constants.TILE + Constants.HALF
    check("the shadow walks through the opened cell", moved == true, fx)
    check("the shadow stays aligned with the lane", fy ~= nil and math.abs(fy - 60) < 0.001, fy)
    check("the map version is unchanged by plain movement", prediction:getGridVersion() == 1,
        prediction:getGridVersion())

    -- A genuinely stale grid (the pre-change rows at the old version) must be
    -- rejected: neither the ack nor the open cell may regress.
    prediction:onSnapshot(before, record.id, h.now)
    check("an old-ack snapshot cannot restore the crate", prediction:getAck() == ackAfterNewer,
        prediction:getAck())
    check("a stale map version cannot re-solidify the cell", prediction:getGridVersion() == 1,
        prediction:getGridVersion())
    local fx2 = prediction:getTargetPosition()
    check("the shadow still stands past the crate", fx2 ~= nil and fx2 > 2 * Constants.TILE,
        fx2)
end

TestLib.finish()
