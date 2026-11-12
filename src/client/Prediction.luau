-- src/client/Prediction.luau
-- Client-side movement and bomb prediction for the local player only.
--
-- The client advances a shadow player at 30Hz using the same Movement module as
-- the server and records (seq, dirs, place), one entry per command. A snapshot
-- carries the last sequence the server applied plus the authoritative sub-pixel
-- position. On arrival we reset the shadow to that position, replay every
-- unacknowledged command, and turn the difference into a short visual correction
-- instead of a teleport.
--
-- Placement rides inside the ordered command. The client shows a predicted bomb
-- before the server sees the command; the server's bomb carries the same seq and
-- replaces it on confirmation. A command that reaches the ack without a matching
-- bomb was rejected, so the prediction is dropped.
--
-- The server remains authoritative: explosions, traps, death, pushes and all
-- world outcomes come from snapshots and are never decided here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local Movement = require(Shared:WaitForChild("Movement"))

local Prediction = {}
Prediction.__index = Prediction

local DT = Constants.DT
local TILE = Constants.TILE
local HALF = Constants.HALF
local BOMB_FUSE_TICKS = Constants.BOMB_FUSE_TICKS
-- Small mismatches ease out over roughly this time constant. Anything larger is
-- usually a world change (bomb, slide, trap); snapping avoids a visible glide
-- through walls.
local CORRECTION_TAU = 0.08
local SNAP_DISTANCE = 24
-- Bound local history if snapshots stop arriving for a long time.
local HISTORY_LIMIT = 120
-- A predicted bomb that is neither confirmed nor rejected is dropped eventually.
local PREDICTED_TTL = 3
local PREDICTED_LIMIT = 16
-- Bound the set of server sounds we still need to suppress.
local PLACE_FX_LIMIT = 64

local function clamp01(value: number): number
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

local function copyDirs(dirs): { string }
    local result = {}
    for i = 1, math.min(#(dirs or {}), 4) do
        result[i] = dirs[i]
    end
    return result
end

local function findPlayer(snapshot, id)
    for _, player in ipairs(snapshot.players or {}) do
        if player.id == id then
            return player
        end
    end
    return nil
end

-- Same overlap test as Game:overlapsTile. Used to decide whether the owner can
-- still stand on a predicted bomb and whether a replayed placement gets a pass.
local function overlapsTile(player, tx: number, ty: number): boolean
    return player.x + HALF > tx * TILE
        and player.x - HALF < tx * TILE + TILE
        and player.y + HALF > ty * TILE
        and player.y - HALF < ty * TILE + TILE
end

local function clearPredicted(self)
    self.predicted = {}
    self.predictedBySeq = {}
end

local function clearPlaceFx(self)
    self.placeFxSet = {}
    self.placeFxOrder = {}
end

function Prediction.new()
    return setmetatable({
        active = false,
        localId = nil,
        grid = nil,
        -- Monotonic map version of `grid` (snapshot.gridVer). nil means "no
        -- versioned grid seen yet" (old server or fresh reset); in that state
        -- every grid-bearing snapshot is applied, matching the legacy behavior.
        gridVer = nil,
        world = nil,
        player = nil,
        history = {},
        ack = 0,
        prevX = 0,
        prevY = 0,
        targetX = 0,
        targetY = 0,
        stepAt = 0,
        correctionX = 0,
        correctionY = 0,
        hasVisual = false,
        -- Predicted bombs, in creation order. Shared by reference with the
        -- renderer, so this table must only be mutated by this module.
        predicted = {},
        predictedBySeq = {},
        serverBombs = {},
        -- seqs whose server bomb_set sound was already played locally.
        placeFxSet = {},
        placeFxOrder = {},
        -- Diagnostics for deterministic reconciliation tests.
        lastTargetDelta = 0,
        lastSnapped = false,
    }, Prediction)
end

function Prediction:reset()
    self.active = false
    self.localId = nil
    self.grid = nil
    -- A new round restarts the server's gridVer at 0, so the stale version from
    -- the previous round must not reject the fresh map.
    self.gridVer = nil
    self.world = nil
    self.player = nil
    self.history = {}
    self.ack = 0
    self.prevX = 0
    self.prevY = 0
    self.targetX = 0
    self.targetY = 0
    self.stepAt = 0
    self.correctionX = 0
    self.correctionY = 0
    self.hasVisual = false
    clearPredicted(self)
    clearPlaceFx(self)
    self.serverBombs = {}
    self.lastTargetDelta = 0
    self.lastSnapped = false
end

local function deactivate(self)
    self.active = false
    self.history = {}
    self.hasVisual = false
    self.correctionX = 0
    self.correctionY = 0
end

function Prediction:isActive(): boolean
    return self.active
end

function Prediction:getAck(): number
    return self.ack
end

-- Diagnostics: the map version the shadow currently collides against.
function Prediction:getGridVersion(): number?
    return self.gridVer
end

-- Grid rows are only included in a snapshot when the map changes, so the same
-- authoritative grid that RoundState carries is used to seed the predictor on
-- round start. Without this the predictor would stay inactive until the next
-- crate broke.
--
-- `ver` is the monotonic gridVer that rode with the rows. An older or equal
-- version is ignored: RoundState broadcasts and snapshots travel on separate
-- remotes and can cross, so the rows themselves do not prove recency.
-- Without a version (old server) every set still applies, as before.
function Prediction:setGrid(rows, ver: number?)
    if rows == nil then
        return
    end
    if type(ver) == "number" then
        if self.gridVer ~= nil and ver <= self.gridVer then
            return
        end
        self.gridVer = ver
    end
    self.grid = Grid.rowsToGrid(rows)
    -- world.grid shares the grid table, so the next simulated command collides
    -- against the map this grid came from, not the one before it.
    if self.world then
        self.world.grid = self.grid
    end
end

-- Apply a snapshot's map rows before any staleness decision. Grid rows ride on
-- whichever snapshot happened to be built first after the map changed; with
-- reordering that carrier can arrive behind a newer ack, and the ack guard
-- below would otherwise drop the only copy of the map change. The monotonic
-- version check keeps genuinely stale grids out, so applying unconditionally
-- here cannot roll the predictor back.
function Prediction:_applyGridRows(snapshot)
    if type(snapshot) ~= "table" or snapshot.grid == nil then
        return
    end
    local ver = snapshot.gridVer
    if type(ver) == "number" then
        if self.gridVer ~= nil and ver <= self.gridVer then
            return
        end
        self.gridVer = ver
    end
    self.grid = Grid.rowsToGrid(snapshot.grid)
    if self.world then
        self.world.grid = self.grid
    end
end

-- Snapshot points at the latest tick. Only the parts movement collision needs
-- are projected: the current grid, bombs (including per-player pass) and
-- in-progress crate slides. Bomb metadata is kept for prediction checks and
-- owner+seq confirmation.
function Prediction:_buildWorld(snapshot)
    -- The map itself was already applied by _applyGridRows above any staleness
    -- guard; this only rebuilds the per-tick projection around it.
    if not self.grid then
        return false
    end

    local bombsByPos = {}
    local serverBombs = {}
    for _, bomb in ipairs(snapshot.bombs or {}) do
        local bx, by = bomb.x, bomb.y
        if type(bx) == "number" and type(by) == "number" then
            local pass = {}
            for _, id in ipairs(bomb.pass or {}) do
                pass[id] = true
            end
            local record = {
                x = bx,
                y = by,
                tx = bx,
                ty = by,
                pass = pass,
                owner = bomb.owner,
                remote = bomb.remote == true,
                seq = bomb.seq,
            }
            bombsByPos[Grid.key(bx, by)] = record
            table.insert(serverBombs, record)
        end
    end

    local crateSlides = {}
    for _, slide in ipairs(snapshot.crateSlides or {}) do
        table.insert(crateSlides, { tx = slide.tx, ty = slide.ty })
    end

    self.world = {
        grid = self.grid,
        bombsByPos = bombsByPos,
        crateSlides = crateSlides,
    }
    self.serverBombs = serverBombs
    return true
end

function Prediction:_syncPlayer(playerData)
    local player = self.player
    if not player then
        player = {
            dirs = {},
            pushKey = nil,
            pushAcc = 0,
        }
        self.player = player
    end
    player.id = playerData.id
    player.speed = if type(playerData.speed) == "number" and playerData.speed > 0
        then playerData.speed
        else player.speed or 0
    player.mount = playerData.mount
    player.alive = playerData.alive
    player.trapped = playerData.trapped
    player.maxBombs = if type(playerData.maxBombs) == "number"
        then playerData.maxBombs
        else player.maxBombs or 1
    return player
end

function Prediction:_basePosition(now: number): (number, number)
    local alpha = clamp01((now - self.stepAt) / DT)
    local x = self.prevX + (self.targetX - self.prevX) * alpha
    local y = self.prevY + (self.targetY - self.prevY) * alpha
    return x, y
end

function Prediction:getRenderPosition(now: number): (number?, number?)
    if not self.active or not self.hasVisual then
        return nil, nil
    end
    local x, y = self:_basePosition(now)
    return x + self.correctionX, y + self.correctionY
end

function Prediction:getTargetPosition(): (number?, number?)
    if not self.active then
        return nil, nil
    end
    return self.targetX, self.targetY
end

-- Read-only view for the renderer. The array is stable and is mutated in place
-- as predictions are confirmed/rejected.
function Prediction:getPredictedBombs()
    return self.predicted
end

-- Remove one predicted bomb (reverse iteration order is the caller's job).
function Prediction:_removePredictedAt(index: number)
    local bomb = table.remove(self.predicted, index)
    if not bomb then
        return
    end
    self.predictedBySeq[bomb.seq] = nil
    local key = Grid.key(bomb.tx, bomb.ty)
    if self.world and self.world.bombsByPos[key] == bomb then
        self.world.bombsByPos[key] = nil
    end
end

-- Drop predictions that were never confirmed and are no longer plausible.
function Prediction:_prunePredicted(now: number)
    for i = #self.predicted, 1, -1 do
        local bomb = self.predicted[i]
        if now - (bomb.createdAt or now) > PREDICTED_TTL then
            self:_removePredictedAt(i)
        end
    end
    while #self.predicted > PREDICTED_LIMIT do
        self:_removePredictedAt(1)
    end
end

-- Confirm by owner+seq (a kicked bomb moved tile but kept its seq), then drop
-- anything whose command is already acknowledged without a matching bomb.
function Prediction:_reconcilePredicted(localId, ack: number, snapshotBombs, now: number)
    local confirmed = {}
    for _, bomb in ipairs(snapshotBombs or {}) do
        if bomb.owner == localId and type(bomb.seq) == "number" then
            confirmed[bomb.seq] = true
        end
    end
    for i = #self.predicted, 1, -1 do
        local bomb = self.predicted[i]
        if confirmed[bomb.seq] == true
            or bomb.seq <= ack
            or now - (bomb.createdAt or now) > PREDICTED_TTL
        then
            self:_removePredictedAt(i)
        end
    end
    while #self.predicted > PREDICTED_LIMIT do
        self:_removePredictedAt(1)
    end
end

function Prediction:_addPlaceFx(seq: number)
    if self.placeFxSet[seq] then
        return
    end
    self.placeFxSet[seq] = true
    table.insert(self.placeFxOrder, seq)
    while #self.placeFxOrder > PLACE_FX_LIMIT do
        local oldest = table.remove(self.placeFxOrder, 1)
        self.placeFxSet[oldest] = nil
    end
end

-- A server bomb_set for our own sequenced placement is already covered by the
-- local sound. Keep the entry across confirmation: Fx and Snapshot are separate
-- remotes and can arrive in either order.
function Prediction:consumePlaceFx(seq: number): boolean
    if self.placeFxSet[seq] ~= true then
        return false
    end
    self.placeFxSet[seq] = nil
    for i = #self.placeFxOrder, 1, -1 do
        if self.placeFxOrder[i] == seq then
            table.remove(self.placeFxOrder, i)
            break
        end
    end
    return true
end

-- Mirror Game:placeBomb(id, false) closely enough to avoid obvious phantom
-- bombs. The server still decides: a differing result is reconciled by ack.
function Prediction:_predictPlace(seq: number, now: number): boolean
    if not self.active or not self.player or not self.world or not self.localId then
        return false
    end
    if self.predictedBySeq[seq] then
        return false
    end

    self:_prunePredicted(now)

    local player = self.player
    if player.alive ~= true or player.trapped == true then
        return false
    end
    local tx = math.floor(player.x / TILE)
    local ty = math.floor(player.y / TILE)
    local key = Grid.key(tx, ty)
    if self.world.bombsByPos[key] then
        return false
    end

    local owned = 0
    for _, bomb in ipairs(self.serverBombs) do
        if bomb.owner == self.localId then
            if bomb.remote then
                -- Game:placeBomb detonates a remote instead of placing a new
                -- one; predicting a new bomb here would be wrong.
                return false
            end
            owned += 1
        end
    end
    owned += #self.predicted
    if owned >= (player.maxBombs or 1) then
        return false
    end

    local bomb = {
        id = "p" .. tostring(seq),
        seq = seq,
        tx = tx,
        ty = ty,
        x = tx,
        y = ty,
        sx = tx * TILE + TILE / 2,
        sy = ty * TILE + TILE / 2,
        fuse = BOMB_FUSE_TICKS,
        remote = false,
        owner = self.localId,
        pass = {},
        createdAt = now,
    }
    if overlapsTile(player, tx, ty) then
        bomb.pass[self.localId] = true
    end
    table.insert(self.predicted, bomb)
    self.predictedBySeq[seq] = bomb
    self.world.bombsByPos[key] = bomb
    self:_addPlaceFx(seq)
    return true
end

-- Game:updateBombPass removes a pass once its player no longer overlaps the
-- bomb tile; it never re-adds one. Mirror that for the WHOLE projected world
-- at the start of every simulated command, exactly where Game:tick runs
-- updateBombPass. Covering server bombs matters at high RTT: the snapshot that
-- seeded this world is pipeline-depth ticks old and can still carry a pass the
-- server has already revoked. Without this mirror the shadow walks back
-- through its own bomb row (the stale pass keeps the cell passable), diverges
-- from the blocked server position and rubber-bands -- on screen the character
-- repeatedly passes through bombs that should stop it. Only the local
-- player's entries are touched: no other player is simulated here, so their
-- passes never affect the shadow's collision.
function Prediction:_refreshBombPass()
    if not self.player or not self.localId then
        return
    end
    local world = self.world
    if world then
        for _, bomb in pairs(world.bombsByPos) do
            local pass = bomb.pass
            if pass and pass[self.localId]
                and not overlapsTile(self.player, bomb.tx, bomb.ty) then
                pass[self.localId] = nil
            end
        end
    end
    -- Predicted bombs normally sit in world.bombsByPos too; walk the list as a
    -- safety net in case one is not currently keyed in the projection.
    for _, bomb in ipairs(self.predicted) do
        if bomb.pass[self.localId] and not overlapsTile(self.player, bomb.tx, bomb.ty) then
            bomb.pass[self.localId] = nil
        end
    end
end

function Prediction:update(dt: number)
    if not self.active or dt <= 0 then
        return
    end
    local factor = math.exp(-dt / CORRECTION_TAU)
    self.correctionX *= factor
    self.correctionY *= factor
    if math.abs(self.correctionX) < 0.05 then
        self.correctionX = 0
    end
    if math.abs(self.correctionY) < 0.05 then
        self.correctionY = 0
    end
end

-- Feed a new authoritative snapshot. `now` is used for visual interpolation and
-- correction continuity, not for simulation logic.
function Prediction:onSnapshot(snapshot, localId, now: number)
    if type(snapshot) ~= "table" then
        return
    end

    local playerData = if localId ~= nil then findPlayer(snapshot, localId) else nil

    -- Map first: a newer grid must reach the predictor even when the rest of
    -- this snapshot is stale (see _applyGridRows).
    self:_applyGridRows(snapshot)

    -- Snapshots are reliable, but a GetSync answer and a live broadcast can
    -- cross. Never move the predictor backwards on an older ack.
    if self.active and self.localId == localId and playerData ~= nil
        and type(playerData.ack) == "number" and playerData.ack < self.ack
    then
        return
    end

    if self.localId ~= nil and self.localId ~= localId then
        clearPredicted(self)
        clearPlaceFx(self)
    end

    -- Keep the projected world fresh even while inactive (warmup, trapped) so
    -- activation never waits for the next grid change.
    self:_buildWorld(snapshot)

    if playerData == nil or type(playerData.ack) ~= "number" then
        -- Missing local player or an older server that does not acknowledge
        -- sequenced input: leave the local player on snapshot interpolation.
        clearPredicted(self)
        self.localId = localId
        deactivate(self)
        return
    end

    if playerData.alive ~= true or playerData.trapped == true or (snapshot.warmup or 0) > 0 then
        -- No placement from this state will be accepted. Server bombs are
        -- already in the rebuilt world; drop any local phantoms.
        clearPredicted(self)
        self.ack = playerData.ack
        self.localId = localId
        deactivate(self)
        return
    end
    if not self.grid then
        clearPredicted(self)
        deactivate(self)
        return
    end

    -- Reconcile before replaying so confirmed/rejected bombs cannot be injected
    -- back into the world below.
    self:_reconcilePredicted(localId, playerData.ack, snapshot.bombs, now)

    local wasActive = self.active and self.localId == localId and self.hasVisual
    local oldX, oldY = 0, 0
    local beforeTargetX, beforeTargetY = 0, 0
    if wasActive then
        oldX, oldY = self:_basePosition(now)
        oldX += self.correctionX
        oldY += self.correctionY
        beforeTargetX, beforeTargetY = self.targetX, self.targetY
    end

    local player = self:_syncPlayer(playerData)
    local serverX = if type(playerData.fx) == "number" then playerData.fx else playerData.x or 0
    local serverY = if type(playerData.fy) == "number" then playerData.fy else playerData.y or 0
    self.ack = playerData.ack
    self.localId = localId

    -- Drop acknowledged commands, then replay the rest from the authoritative
    -- position. With the same Movement module this must land on the same target
    -- the client had already predicted.
    local pending = {}
    for _, command in ipairs(self.history) do
        if command.seq > self.ack then
            table.insert(pending, command)
        end
    end
    self.history = pending

    player.x = serverX
    player.y = serverY
    for _, command in ipairs(pending) do
        -- Inject a predicted bomb only at its own command. Injecting every
        -- prediction up front would block movement the server executed before
        -- the placement command.
        local predicted = self.predictedBySeq[command.seq]
        if predicted then
            local key = Grid.key(predicted.tx, predicted.ty)
            if not self.world.bombsByPos[key] then
                predicted.pass = {}
                if overlapsTile(player, predicted.tx, predicted.ty) then
                    predicted.pass[localId] = true
                end
                self.world.bombsByPos[key] = predicted
            end
        end
        self:_refreshBombPass()
        player.dirs = command.dirs
        Movement.step(self.world, player)
    end

    local newX, newY = player.x, player.y
    local dx, dy = oldX - newX, oldY - newY
    local snapped = false
    if wasActive and dx * dx + dy * dy <= SNAP_DISTANCE * SNAP_DISTANCE then
        self.correctionX = dx
        self.correctionY = dy
    else
        snapped = wasActive
        self.correctionX = 0
        self.correctionY = 0
    end

    if wasActive then
        local tdx, tdy = beforeTargetX - newX, beforeTargetY - newY
        self.lastTargetDelta = math.sqrt(tdx * tdx + tdy * tdy)
    else
        self.lastTargetDelta = 0
    end
    self.lastSnapped = snapped

    self.prevX = newX
    self.prevY = newY
    self.targetX = newX
    self.targetY = newY
    self.stepAt = now
    self.hasVisual = true
    self.active = true
end

-- Advance the shadow by one local 30Hz command. Returns:
--   active            false while prediction is unavailable
--   predictedBomb     true only when this call actually created a local bomb
function Prediction:step(seq: number, dirs, now: number, place: boolean?): (boolean, boolean)
    if not self.active or not self.player or not self.world then
        return false, false
    end

    local commandDirs = copyDirs(dirs)
    table.insert(self.history, { seq = seq, dirs = commandDirs })
    while #self.history > HISTORY_LIMIT do
        table.remove(self.history, 1)
    end

    -- Continue from the currently displayed interpolated base, so a frame that
    -- arrives slightly late or early does not produce a visible jitter.
    self.prevX, self.prevY = self:_basePosition(now)

    self:_prunePredicted(now)
    local placePredicted = false
    if place == true then
        -- Pre-move, exactly like Game:setInput before Game:tick.
        placePredicted = self:_predictPlace(seq, now)
    end
    self:_refreshBombPass()

    self.player.dirs = commandDirs
    Movement.step(self.world, self.player)
    self.targetX = self.player.x
    self.targetY = self.player.y
    self.stepAt = now
    self.hasVisual = true
    return true, placePredicted
end

return table.freeze(Prediction)
