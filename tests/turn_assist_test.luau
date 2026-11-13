-- Corner assist window: how far off a lane centre a turn still gets slid into
-- the lane, using the real shared Movement on a small crossroads. Guards the
-- ASSIST_RANGE tuning (turning at full speed must stay possible for a thumb).
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Movement = require("./Movement")

local T, COLS, ROWS = Constants.TILE, Constants.COLS, Constants.ROWS

-- Solid everywhere except a horizontal corridor (row 5) and a vertical lane (col 7).
local function crossroads()
    local grid = {}
    for ty = 0, ROWS - 1 do
        grid[ty] = {}
        for tx = 0, COLS - 1 do
            grid[ty][tx] = 1
        end
    end
    for tx = 1, COLS - 2 do
        grid[5][tx] = 0
    end
    for ty = 1, ROWS - 2 do
        grid[ty][7] = 0
    end
    return { grid = grid, bombsByPos = {}, crateSlides = {} }
end

local world = crossroads()
local LANE_X = 7 * T + T / 2
local LANE_Y = 5 * T + T / 2
local FREE = 8 -- the player already has ~7px of free room inside its own corridor tile

-- Press `dir` while standing `offset` px off the lane centre, running along the
-- corridor. Returns whether the player really entered the lane, and in how many ticks.
local function enterLane(speed: number, offset: number, vertical: boolean)
    local p
    local dir = "up"
    if vertical then
        -- corridor is the lane (col 7), the side corridor is row 5: mirror the test
        p = { id = 1, x = LANE_X, y = LANE_Y + offset, speed = speed, dirs = { "right" } }
        dir = "right"
    else
        p = { id = 1, x = LANE_X + offset, y = LANE_Y, speed = speed, dirs = { "up" } }
    end
    local x0, y0 = p.x, p.y
    for tick = 1, 14 do
        Movement.step(world, p)
        local moved = if vertical then p.x - x0 else y0 - p.y
        if moved >= FREE + 1 then
            return true, tick
        end
    end
    return false, 14
end

check("assist range stays below half a tile (no two lanes qualify at once)",
    Constants.ASSIST_RANGE < T / 2, tostring(Constants.ASSIST_RANGE))
check("assist range is wide enough for a thumb at full speed (>= 16px)",
    Constants.ASSIST_RANGE >= 16, tostring(Constants.ASSIST_RANGE))

for _, speed in ipairs({ 144, 192, 240 }) do
    local lo, hi
    for offset = -T, T do
        local ok = enterLane(speed, offset, false)
        if ok then
            lo = lo or offset
            hi = offset
        end
    end
    local range = Constants.ASSIST_RANGE
    check(string.format("speed %d: turn window is exactly +-ASSIST_RANGE", speed),
        lo == -range and hi == range, tostring(lo) .. ".." .. tostring(hi))
    local step = speed * Constants.DT
    local ticks = (hi - lo + 1) / step
    check(string.format("speed %d: window lasts %.1f ticks", speed, ticks), ticks >= 4.5)
end

-- Inside the window the turn is prompt, at the centre and at the edges.
for _, offset in ipairs({ -Constants.ASSIST_RANGE, -8, 0, 8, Constants.ASSIST_RANGE }) do
    local ok, ticks = enterLane(240, offset, false)
    check(string.format("full speed, press %+d px from the centre enters the lane quickly", offset),
        ok and ticks <= 3, tostring(ticks))
end

-- Just outside the window the player cannot turn (this is what C/D will remove).
check("one pixel before the window the turn is lost", enterLane(240, -Constants.ASSIST_RANGE - 1, false) == false)
check("one pixel after the window the turn is lost", enterLane(240, Constants.ASSIST_RANGE + 1, false) == false)

-- The same window applies when the lane runs the other way.
for _, offset in ipairs({ -Constants.ASSIST_RANGE, 0, Constants.ASSIST_RANGE }) do
    local ok = enterLane(240, offset, true)
    check(string.format("horizontal turn, press %+d px from the lane centre enters", offset), ok)
end

TestLib.finish()
