-- src/client/Prediction.luau
-- Client-side movement prediction and reconciliation for the local player only.
--
-- The client advances a shadow player at 30Hz using the same Movement module as
-- the server and records (seq, dirs), one entry per command. A snapshot carries
-- the last sequence the server applied plus the authoritative sub-pixel
-- position. On arrival we reset the shadow to that position, replay every
-- unacknowledged command, and turn the difference into a short visual
-- correction instead of a teleport.
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
-- Small mismatches ease out over roughly this time constant. Anything larger is
-- usually a world change (bomb, slide, trap); snapping avoids a visible glide
-- through walls.
local CORRECTION_TAU = 0.08
local SNAP_DISTANCE = 24
-- Bound local history if snapshots stop arriving for a long time.
local HISTORY_LIMIT = 120

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

function Prediction.new()
    return setmetatable({
        active = false,
        localId = nil,
        grid = nil,
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
    }, Prediction)
end

function Prediction:reset()
    self.active = false
    self.localId = nil
    self.grid = nil
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

-- Grid rows are only included in a snapshot when the map changes, so the same
-- authoritative grid that RoundState carries is used to seed the predictor on
-- round start. Without this the predictor would stay inactive until the next
-- crate broke.
function Prediction:setGrid(rows)
    if rows ~= nil then
        self.grid = Grid.rowsToGrid(rows)
    end
end

-- Snapshot points at the latest tick. Only the parts movement collision needs
-- are projected: the current grid, bombs (including per-player pass) and
-- in-progress crate slides.
function Prediction:_buildWorld(snapshot)
    if snapshot.grid ~= nil then
        self.grid = Grid.rowsToGrid(snapshot.grid)
    end
    if not self.grid then
        return false
    end

    local bombsByPos = {}
    for _, bomb in ipairs(snapshot.bombs or {}) do
        local bx, by = bomb.x, bomb.y
        if type(bx) == "number" and type(by) == "number" then
            local pass = {}
            for _, id in ipairs(bomb.pass or {}) do
                pass[id] = true
            end
            bombsByPos[Grid.key(bx, by)] = {
                x = bx,
                y = by,
                tx = bx,
                ty = by,
                pass = pass,
            }
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

-- Fade a small reconciliation offset. Visual correction is separate from the
-- simulation position so replaying a command never gets fed back into the next
-- command's starting point.
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

    -- Snapshots are reliable, but a GetSync answer and a live broadcast can
    -- cross. Never move the predictor backwards on an older ack.
    if self.active and self.localId == localId and playerData ~= nil
        and type(playerData.ack) == "number" and playerData.ack < self.ack
    then
        return
    end

    -- Keep the projected world fresh even while inactive (warmup, trapped) so
    -- activation never waits for the next grid change.
    self:_buildWorld(snapshot)

    if playerData == nil or type(playerData.ack) ~= "number" then
        -- Missing local player or an older server that does not acknowledge
        -- sequenced input: leave the local player on snapshot interpolation.
        deactivate(self)
        return
    end

    if playerData.alive ~= true or playerData.trapped == true or (snapshot.warmup or 0) > 0 then
        deactivate(self)
        self.ack = playerData.ack
        return
    end
    if not self.grid then
        deactivate(self)
        return
    end

    local wasActive = self.active and self.localId == localId and self.hasVisual
    local oldX, oldY = 0, 0
    if wasActive then
        oldX, oldY = self:_basePosition(now)
        oldX += self.correctionX
        oldY += self.correctionY
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
        player.dirs = command.dirs
        Movement.step(self.world, player)
    end

    local newX, newY = player.x, player.y
    local dx, dy = oldX - newX, oldY - newY
    if wasActive and dx * dx + dy * dy <= SNAP_DISTANCE * SNAP_DISTANCE then
        self.correctionX = dx
        self.correctionY = dy
    else
        self.correctionX = 0
        self.correctionY = 0
    end

    self.prevX = newX
    self.prevY = newY
    self.targetX = newX
    self.targetY = newY
    self.stepAt = now
    self.hasVisual = true
    self.active = true
end

-- Advance the shadow by one local 30Hz command. Returns false while prediction
-- is inactive (warmup, dead, trapped, spectator or an older server).
function Prediction:step(seq: number, dirs, now: number): boolean
    if not self.active or not self.player or not self.world then
        return false
    end

    local commandDirs = copyDirs(dirs)
    table.insert(self.history, { seq = seq, dirs = commandDirs })
    while #self.history > HISTORY_LIMIT do
        table.remove(self.history, 1)
    end

    -- Continue from the currently displayed interpolated base, so a frame that
    -- arrives slightly late or early does not produce a visible jitter.
    self.prevX, self.prevY = self:_basePosition(now)
    self.player.dirs = commandDirs
    Movement.step(self.world, self.player)
    self.targetX = self.player.x
    self.targetY = self.player.y
    self.stepAt = now
    self.hasVisual = true
    return true
end

return table.freeze(Prediction)
