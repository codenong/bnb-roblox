-- src/shared/Movement.luau
-- The part of player movement that both the authoritative Game and client-side
-- prediction must agree on: collision, one four-way step, and corner assist.
--
-- World is any table with `grid`, `bombsByPos` and `crateSlides`, so Game can
-- pass itself and the client can pass a lightweight projection of a snapshot.
-- Kick/push side effects stay in Game; they never change the mover's position.

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

-- Move one simulation tick.
-- Returns:
--   "idle"     no held direction
--   "moved"    the direct step succeeded
--   "assisted" a corner-assist shift was attempted (whether or not it unblocked)
--   "blocked"  nothing could be attempted; Game may kick/push here
--
-- The distinction between "assisted" and "blocked" preserves the original
-- Game:movePlayer behavior: kick/push are only tried when the assist branch was
-- never entered.
function Movement.step(world, player): string
    local dir = player.dirs[#player.dirs]
    if not dir then
        clearPush(player)
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

    if Movement.tryMove(world, player, dx, dy) then
        clearPush(player)
        return "moved"
    end

    -- Corner assist: nudge toward the adjacent lane center, then retry.
    if dx ~= 0 then
        local center = math.floor(player.y / TILE) * TILE + TILE / 2
        for _, cy in ipairs({ center, center - TILE, center + TILE }) do
            local delta = cy - player.y
            if delta ~= 0 and math.abs(delta) <= ASSIST_RANGE then
                local shift = if math.abs(delta) <= step then delta else Grid.sign(delta) * step
                if not Movement.collides(world, player, player.x, player.y + shift) then
                    player.y += shift
                    if Movement.tryMove(world, player, dx, 0) then
                        clearPush(player)
                    end
                end
                return "assisted"
            end
        end
    else
        local center = math.floor(player.x / TILE) * TILE + TILE / 2
        for _, cx in ipairs({ center, center - TILE, center + TILE }) do
            local delta = cx - player.x
            if delta ~= 0 and math.abs(delta) <= ASSIST_RANGE then
                local shift = if math.abs(delta) <= step then delta else Grid.sign(delta) * step
                if not Movement.collides(world, player, player.x + shift, player.y) then
                    player.x += shift
                    if Movement.tryMove(world, player, 0, dy) then
                        clearPush(player)
                    end
                end
                return "assisted"
            end
        end
    end

    return "blocked"
end

return table.freeze(Movement)
