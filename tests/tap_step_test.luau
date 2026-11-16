-- Why the touch tap pulse is exactly 3 commands: through the real Movement it is
-- always one cell at every speed, while a plain hold of the same stick walks one
-- or two cells depending on a few milliseconds of finger contact.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Movement = require("./Movement")

local T, COLS, ROWS = Constants.TILE, Constants.COLS, Constants.ROWS

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
local world = { grid = grid, bombsByPos = {}, crateSlides = {} }
local START = 2 * T + T / 2

-- Hold `right` for `ticks` commands, then nothing; return cells walked.
local function hold(ticks: number, speed: number): number
    local p = { id = 1, x = START, y = 5 * T + T / 2, speed = speed, dirs = { "right" } }
    for _ = 1, ticks do
        Movement.step(world, p)
    end
    p.dirs = {}
    for _ = 1, 60 do
        Movement.step(world, p)
    end
    return (p.x - START) / T
end

-- Must match TOUCH_TAP_PULSE_TICKS in InputTouch (input_touch_test pins that the
-- pulse really lasts this many commands).
local PULSE_TICKS = 3

for _, speed in ipairs({ 120, 144, 192, 240 }) do
    check(string.format("speed %d: a tap pulse is exactly one cell", speed), hold(PULSE_TICKS, speed) == 1, hold(PULSE_TICKS, speed))
end

-- The thing the pulse replaces: at full speed the same light press is one cell or
-- two depending on contact time (one cell is ~167 ms of travel).
check("full speed: a 150 ms hold is one cell", hold(9, 240) == 1, hold(9, 240))
check("full speed: a 230 ms hold of the same stick is two cells", hold(14, 240) == 2, hold(14, 240))

-- The glide must land on a centre so the next turn is aligned.
do
    local p = { id = 1, x = START, y = 5 * T + T / 2, speed = 240, dirs = { "right" } }
    for _ = 1, PULSE_TICKS do
        Movement.step(world, p)
    end
    p.dirs = {}
    for _ = 1, 60 do
        Movement.step(world, p)
    end
    check("the pulse ends exactly on a cell centre", (p.x - T / 2) % T == 0, p.x)
end

TestLib.finish()
