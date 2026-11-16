-- src/shared/Movement.luau
-- The part of player movement that both the authoritative Game and client-side
-- prediction must agree on: collision, one four-way step, corner assist, the
-- turn buffer for an early press, and the release glide onto cell centres.
--
-- World is any table with `grid`, `bombsByPos` and `crateSlides`, so Game can
-- pass itself and the client can pass a lightweight projection of a snapshot.
-- Kick/push side effects stay in Game; they never change the mover's position.
--
-- Players carry `lastMoveDir`, the direction of the last successful move (or
-- final turn). It drives both the turn buffer (C) and the release glide (D),
-- so it must survive snapshot reconciliation: Game:snapshot() sends it as
-- `dir` and Prediction re-seeds it before replaying unacknowledged commands.

local Constants = require(script.Parent.Constants)
local Grid = require(script.Parent.Grid)
local Mounts = require(script.Parent.Mounts)

local Movement = {}

local TILE = Constants.TILE
local COLS = Constants.COLS
local ROWS = Constants.ROWS
local HALF = Constants.HALF
local ASSIST_RANGE = Constants.ASSIST_RANGE

local EMPTY = 0

function Movement.bombAt(world, tx: number, ty: number)
    local bombsByPos = world.bombsByPos
    if not bombsByPos then
        return nil
    end
    return bombsByPos[Grid.key(tx, ty)]
end

function Movement.effSpeed(player): number
    if player.mount then
        local mount = Mounts.MOUNTS[player.mount]
        if mount then
            return mount.speed
        end
    end
    return player.speed or 0
end

function Movement.solidFor(world, tx: number, ty: number, player): boolean
    if tx < 0 or ty < 0 or tx >= COLS or ty >= ROWS then
        return true
    end
    local row = world.grid[ty]
    local tile = if row then row[tx] else 1
    if tile ~= EMPTY then
        local border = tx == 0 or ty == 0 or tx == COLS - 1 or ty == ROWS - 1
        if not (player.mount == "ufo" and not border) then
            return true
        end
    end
    for _, slide in ipairs(world.crateSlides or {}) do
        if slide.tx == tx and slide.ty == ty then
            return true
        end
    end
    local bomb = Movement.bombAt(world, tx, ty)
    if bomb and not (bomb.pass and bomb.pass[player.id]) then
        return true
    end
    return false
end

function Movement.collides(world, player, x: number, y: number): boolean
    local x0 = math.floor((x - HALF) / TILE)
    local x1 = math.floor((x + HALF - 0.01) / TILE)
    local y0 = math.floor((y - HALF) / TILE)
    local y1 = math.floor((y + HALF - 0.01) / TILE)
    for ty = y0, y1 do
        for tx = x0, x1 do
            if Movement.solidFor(world, tx, ty, player) then
                return true
            end
        end
    end
    return false
end

function Movement.tryMove(world, player, dx: number, dy: number): boolean
    local nx = player.x + dx
    local ny = player.y + dy
    if not Movement.collides(world, player, nx, ny) then
        player.x = nx
        player.y = ny
        return true
    end
    return false
end

local function clearPush(player)
    player.pushKey = nil
    player.pushAcc = 0
end

-- Sign of each direction along its movement axis (x for left/right, y for
-- up/down). Shared by the turn buffer and the release glide.
local AXIS_SIGN = { left = -1, right = 1, up = -1, down = 1 }

-- (D) Release glide. With no held direction the player does not stop wherever
-- the thumb happened to release: if they had already committed past the cell
-- centre behind them (more than Constants.SNAP_COMMIT_PX of progress), the
-- crossing is completed to the next centre -- a tap walks exactly one cell.
-- Otherwise they walk back to the centre behind, so an accidental brush
-- cancels out. Rest positions therefore land on cell centres along the last
-- movement axis, which also erases the few px of release-latency drift.
-- The turn buffer (C) does not use this helper: it is pure momentum and always
-- advances a full step along the last direction (see Movement.step).
local function glide(world, player, dir, step: number): boolean
    local sign = AXIS_SIGN[dir]
    local horizontal = dir == "left" or dir == "right"
    local along = if horizontal then player.x else player.y
    -- The centre the player last passed moving in `dir`'s sense: for positive
    -- axes the greatest centre <= along, for negative axes the smallest
    -- centre >= along. Progress is how far past it the player has moved.
    local base = if sign == 1
        then math.floor((along - TILE / 2) / TILE) * TILE + TILE / 2
        else math.ceil((along - TILE / 2) / TILE) * TILE + TILE / 2
    local progress = sign * (along - base)
    local target = if progress > Constants.SNAP_COMMIT_PX then base + sign * TILE else base
    local distance = math.abs(target - along)
    if distance <= 0 then
        return false
    end
    local shift = math.min(step, distance)
    local move = if progress > Constants.SNAP_COMMIT_PX then sign else -sign
    local dx = if horizontal then move * shift else 0
    local dy = if horizontal then 0 else move * shift
    if not Movement.tryMove(world, player, dx, dy) then
        return false
    end
    -- The final step lands on the centre exactly, so both the authoritative
    -- game and the client predictor agree bit-for-bit on the resting position
    -- and later idle ticks see a zero-distance glide.
    if shift >= distance then
        if horizontal then
            player.x = target
        else
            player.y = target
        end
    end
    return true
end

-- Did this assist shift move the player backward along their own momentum
-- axis? The turn buffer (C below) advances the player along lastMoveDir; an
-- assist that then drags them back the same way without completing the forward
-- move would turn the buffer into an 8px oscillation around a lane whose way
-- ahead is shut. Such shifts are undone and the tick falls through to the
-- buffer, so the player keeps advancing until a real window opens. The one
-- exception (F1): when the shift aims at a lane whose cell in the pressed
-- direction is open -- a real turn just behind the player -- the pull-back is
-- kept and later ticks finish it, so a press that landed just past a lane
-- centre still turns there instead of gliding on to the next lane. Shifts
-- along the momentum axis TOWARD the momentum (the early-press approach) and
-- perpendicular shifts are untouched.
local function fightsMomentum(player, shift: number, horizontalShift: boolean): boolean
    local lastDir = player.lastMoveDir
    if lastDir == nil then
        return false
    end
    local lastHorizontal = lastDir == "left" or lastDir == "right"
    if lastHorizontal ~= horizontalShift then
        return false -- the shift is perpendicular to the momentum axis
    end
    return (shift > 0) ~= (AXIS_SIGN[lastDir] > 0)
end

-- (F2) Did this move carry the collision box across a cell boundary along
-- `dir`? Only that first crossing move decides which lane the player ends up
-- in, so it is the one moment worth aligning. Edge indices mirror collides():
-- the leading edge is (pos + HALF - 0.01) in dir's sense, the trailing one is
-- (pos - HALF).
local function enteredNewCell(dir: string, xOld: number, yOld: number, xNew: number, yNew: number): boolean
    if dir == "down" then
        return math.floor((yNew + HALF - 0.01) / TILE) > math.floor((yOld + HALF - 0.01) / TILE)
    elseif dir == "up" then
        return math.floor((yNew - HALF) / TILE) < math.floor((yOld - HALF) / TILE)
    elseif dir == "right" then
        return math.floor((xNew + HALF - 0.01) / TILE) > math.floor((xOld + HALF - 0.01) / TILE)
    else -- left
        return math.floor((xNew - HALF) / TILE) < math.floor((xOld - HALF) / TILE)
    end
end

-- (F2) Lane-entry alignment. The first move along `dir` that crosses a cell
-- boundary snaps the perpendicular coordinate onto the centre of the cell
-- being entered, so a turn starts exactly on the lane centre instead of
-- carrying a 0..(TILE/2 - HALF) px offset for the rest of the lane. Applies
-- only when the box fits a single cell across (the lane case): in wide-open
-- ground the box spans two cells and the straight line is kept.
local function snapAcrossEntry(player, dir: string, xOld: number, yOld: number)
    if not enteredNewCell(dir, xOld, yOld, player.x, player.y) then
        return
    end
    if dir == "down" or dir == "up" then
        if math.floor((player.x - HALF) / TILE) ~= math.floor((player.x + HALF - 0.01) / TILE) then
            return
        end
        player.x = math.floor(player.x / TILE) * TILE + TILE / 2
    else
        if math.floor((player.y - HALF) / TILE) ~= math.floor((player.y + HALF - 0.01) / TILE) then
            return
        end
        player.y = math.floor(player.y / TILE) * TILE + TILE / 2
    end
end

-- Move one simulation tick.
-- Returns:
--   "idle"     no held direction and nothing to glide (or the glide is blocked)
--   "moved"    the direct step succeeded, or the release glide advanced
--   "assisted" a corner-assist shift was attempted (whether or not it unblocked)
--   "buffered" the held direction was blocked but the turn buffer kept the
--              player moving along the last direction; Game still kicks/pushes
--              toward the held direction on this status
--   "blocked"  nothing could be attempted; Game may kick/push here
--
-- The distinction between "assisted" and "blocked" preserves the original
-- Game:movePlayer behavior: kick/push are only tried when the assist branch was
-- never entered. "buffered" reports to kick/push because the player is still
-- pressing into the obstacle even while their momentum carries them along.
function Movement.step(world, player): string
    local dir = player.dirs[#player.dirs]
    if not dir then
        clearPush(player)
        -- (D) Release glide along the last movement axis. lastMoveDir is not
        -- updated: the axis does not change while gliding.
        local lastDir = player.lastMoveDir
        if lastDir ~= nil and glide(world, player, lastDir, Movement.effSpeed(player) * Constants.DT) then
            return "moved"
        end
        return "idle"
    end

    local step = Movement.effSpeed(player) * Constants.DT
    local dx, dy = 0, 0
    if dir == "left" then
        dx = -step
    elseif dir == "right" then
        dx = step
    elseif dir == "up" then
        dy = -step
    elseif dir == "down" then
        dy = step
    end

    local xOld, yOld = player.x, player.y
    if Movement.tryMove(world, player, dx, dy) then
        -- A press perpendicular to the momentum that only creeps along a wall
        -- face (the very next step in the pressed direction is already solid)
        -- must not steal the momentum: undo the creep and let the assist /
        -- turn buffer below carry the player to the real window. Without this
        -- guard, finer tick steps let the body slip a few px inside its own
        -- open row, register a "turn" that dead-ends against the wall face and
        -- leave the player stuck short of the lane. Same-axis presses and
        -- momentum-free players keep the plain move.
        if player.lastMoveDir ~= nil and player.lastMoveDir ~= dir
            and Movement.collides(world, player, player.x + dx, player.y + dy) then
            player.x -= dx
            player.y -= dy
        else
            -- (F2) If this move crossed into a new cell along `dir`, align the
            -- perpendicular coordinate before the lane position is remembered.
            snapAcrossEntry(player, dir, xOld, yOld)
            player.lastMoveDir = dir
            clearPush(player)
            return "moved"
        end
    end

    -- Corner assist: nudge toward the adjacent lane center, then retry. A
    -- shift that fights the turn buffer's momentum and cannot complete the
    -- forward move is undone (see fightsMomentum) -- unless it aims at a lane
    -- whose cell in the pressed direction is open (F1), in which case the
    -- pull-back is kept so later ticks can finish the turn -- and this tick
    -- falls through to the buffer instead of reporting "assisted".
    local assisted = false
    if dx ~= 0 then
        local center = math.floor(player.y / TILE) * TILE + TILE / 2
        for _, cy in ipairs({ center, center - TILE, center + TILE }) do
            local delta = cy - player.y
            if delta ~= 0 and math.abs(delta) <= ASSIST_RANGE then
                assisted = true
                local shift = if math.abs(delta) <= step then delta else Grid.sign(delta) * step
                -- (F1) Is the cell one step in the pressed direction from the
                -- lane row this shift aims at open? A momentum-fighting
                -- pull-back is only kept when it aims at a real turn.
                local laneOpen = not Movement.solidFor(world,
                    math.floor(player.x / TILE) + AXIS_SIGN[dir], math.floor(cy / TILE), player)
                if not Movement.collides(world, player, player.x, player.y + shift) then
                    player.y += shift
                    local xBefore, yBefore = player.x, player.y
                    if Movement.tryMove(world, player, dx, 0) then
                        if player.lastMoveDir ~= nil and player.lastMoveDir ~= dir
                            and Movement.collides(world, player, player.x + dx, player.y) then
                            -- The shift only enabled a wall-face creep (the same
                            -- one-step look-ahead as the direct move above, taken
                            -- from the moved position): undo the move, keep the
                            -- momentum, and keep the alignment shift only when it
                            -- does not fight the momentum (or (F1) aims at a real
                            -- lane) -- otherwise the pull-back and the turn
                            -- buffer would oscillate around the centre behind.
                            player.x -= dx
                            if fightsMomentum(player, shift, false) and not laneOpen then
                                player.y -= shift
                                assisted = false
                            end
                        else
                            -- The turn really happened: remember the new axis
                            -- and (F2) align the entry onto the lane centre.
                            player.lastMoveDir = dir
                            snapAcrossEntry(player, dir, xBefore, yBefore)
                            clearPush(player)
                        end
                    elseif fightsMomentum(player, shift, false) and not laneOpen then
                        player.y -= shift
                        assisted = false
                    end
                end
                break
            end
        end
    else
        local center = math.floor(player.x / TILE) * TILE + TILE / 2
        for _, cx in ipairs({ center, center - TILE, center + TILE }) do
            local delta = cx - player.x
            if delta ~= 0 and math.abs(delta) <= ASSIST_RANGE then
                assisted = true
                local shift = if math.abs(delta) <= step then delta else Grid.sign(delta) * step
                -- (F1) Mirror: the cell one step in the pressed direction from
                -- the lane column this shift aims at.
                local laneOpen = not Movement.solidFor(world,
                    math.floor(cx / TILE), math.floor(player.y / TILE) + AXIS_SIGN[dir], player)
                if not Movement.collides(world, player, player.x + shift, player.y) then
                    player.x += shift
                    local xBefore, yBefore = player.x, player.y
                    if Movement.tryMove(world, player, 0, dy) then
                        if player.lastMoveDir ~= nil and player.lastMoveDir ~= dir
                            and Movement.collides(world, player, player.x, player.y + dy) then
                            -- Mirror of the horizontal branch: undo the wall-face
                            -- creep, keep the momentum, keep a shift that does
                            -- not fight the momentum (or (F1) aims at a real
                            -- lane).
                            player.y -= dy
                            if fightsMomentum(player, shift, true) and not laneOpen then
                                player.x -= shift
                                assisted = false
                            end
                        else
                            -- The turn really happened: remember the new axis
                            -- and (F2) align the entry onto the lane centre.
                            player.lastMoveDir = dir
                            snapAcrossEntry(player, dir, xBefore, yBefore)
                            clearPush(player)
                        end
                    elseif fightsMomentum(player, shift, true) and not laneOpen then
                        player.x -= shift
                        assisted = false
                    end
                end
                break
            end
        end
    end
    if assisted then
        return "assisted"
    end

    -- (C) Turn buffer: the held direction is blocked and no lane qualified for
    -- the assist. Keep the momentum: advance one full step along the last
    -- direction instead of stopping dead. This is pure momentum -- never a
    -- retreat -- so an early press glides forward up to the corner window,
    -- where the assist branch turns on its own. lastMoveDir stays unchanged
    -- while gliding, so the buffer keeps working and cannot swallow the held
    -- direction it is buffering for.
    local lastDir = player.lastMoveDir
    if lastDir ~= nil and lastDir ~= dir then
        local bx, by = 0, 0
        if lastDir == "left" then
            bx = -step
        elseif lastDir == "right" then
            bx = step
        elseif lastDir == "up" then
            by = -step
        elseif lastDir == "down" then
            by = step
        end
        if (bx ~= 0 or by ~= 0) and Movement.tryMove(world, player, bx, by) then
            clearPush(player)
            return "buffered"
        end
    end

    return "blocked"
end

return table.freeze(Movement)
