-- Release glide (D): letting go settles the player on a cell centre along the
-- last movement axis. A committed crossing (more than Constants.SNAP_COMMIT_PX
-- past the centre behind) completes to the next centre -- a tap walks exactly
-- one cell -- while a shorter brush walks back and cancels out. Uses the real
-- shared Movement on a small open room.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Grid = require("./Grid")
local Movement = require("./Movement")

local T = Constants.TILE

-- Open room rows 2..6, cols 2..8; solid border elsewhere.
local function room()
	local grid = {}
	for ty = 0, Constants.ROWS - 1 do
		grid[ty] = {}
		for tx = 0, Constants.COLS - 1 do
			grid[ty][tx] = 1
		end
	end
	for ty = 2, 6 do
		for tx = 2, 8 do
			grid[ty][tx] = 0
		end
	end
	return { grid = grid, bombsByPos = {}, crateSlides = {} }
end

local world = room()

local function walker(x, y, speed)
	return { id = 1, x = x, y = y, speed = speed or 240, dirs = {} }
end

local function holdTicks(p, dir, n)
	p.dirs = { dir }
	for _ = 1, n do
		Movement.step(world, p)
	end
end

local function idleTicks(p, n)
	local statuses = {}
	p.dirs = {}
	for _ = 1, n do
		table.insert(statuses, Movement.step(world, p))
	end
	return statuses
end

-- Committed tap: three full-speed ticks right from a centre, then release ->
-- the crossing completes to the next centre, exactly.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	holdTicks(p, "right", 3)
	check("the tap moved three steps off the centre", p.x == 3 * T + T / 2 + 24, tostring(p.x))
	local statuses = idleTicks(p, 4)
	check("a committed release completes the crossing", p.x == 4 * T + T / 2, tostring(p.x))
	check("the crossing glide actually moved the player", statuses[1] == "moved", statuses[1])
	check("later idle ticks are quiet", statuses[3] == "idle" and statuses[4] == "idle",
		table.concat(statuses, ","))
	check("the resting position is a cell centre", (p.x - T / 2) % T == 0, tostring(p.x))
	check("the other axis never moved during the glide", p.y == 4 * T + T / 2, tostring(p.y))
end

-- A brush at exactly the commit threshold (one full-speed tick = 8px) is not
-- committed: the player walks back and the net movement cancels.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	holdTicks(p, "right", 1)
	p.dirs = {}
	idleTicks(p, 3)
	check("a brush at the commit threshold cancels out", p.x == 3 * T + T / 2, tostring(p.x))
end

-- Fractional speeds still land exactly on the centre (the final glide step
-- snaps instead of accumulating float drift).
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2, 144) -- 4.8px per tick
	holdTicks(p, "right", 3)
	check("the fractional tap is mid-cell", p.x > 3 * T + T / 2 + Constants.SNAP_COMMIT_PX,
		tostring(p.x))
	idleTicks(p, 8)
	check("a fractional release lands exactly on the next centre", p.x == 4 * T + T / 2,
		tostring(p.x))
end

-- Vertical releases behave identically on the y axis.
do
	local p = walker(4 * T + T / 2, 5 * T + T / 2)
	holdTicks(p, "up", 3)
	idleTicks(p, 4)
	check("a vertical release lands on the centre above", p.y == 4 * T + T / 2, tostring(p.y))
	check("a vertical release leaves x alone", p.x == 4 * T + T / 2, tostring(p.x))
end

-- An uncommitted fractional brush returns to the centre behind.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2, 144) -- 4.8px per tick
	holdTicks(p, "right", 1) -- progress 4.8 < 8
	idleTicks(p, 3)
	check("an uncommitted fractional brush returns", p.x == 3 * T + T / 2, tostring(p.x))
end

-- A blocked completion glide stops short without error (synthetic state: the
-- bomb appears under the walker mid-crossing, as it would when another player
-- drops it into the tile the body already overlaps).
do
	local p = walker(3 * T + T / 2, 5 * T + T / 2)
	holdTicks(p, "right", 3) -- x = +24, committed
	world.bombsByPos[Grid.key(4, 5)] = { pass = {} }
	local before = p.x
	idleTicks(p, 3)
	check("a blocked crossing glide does not move", p.x == before, tostring(p.x))
	world.bombsByPos[Grid.key(4, 5)] = nil
	idleTicks(p, 4)
	check("the same release completes once the bomb is gone", p.x == 4 * T + T / 2, tostring(p.x))
end

-- New input takes over immediately, mid-glide, from wherever the glide was.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	holdTicks(p, "right", 3)
	p.dirs = {}
	Movement.step(world, p) -- one glide tick
	p.dirs = { "right" }
	Movement.step(world, p) -- the re-press moves normally
	check("new input resumes normal movement mid-glide",
		p.x == 3 * T + T / 2 + 24 + 8 + 8, tostring(p.x))
end

-- A player that never moved has no momentum and no glide.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	local status = Movement.step(world, p)
	check("no momentum, no glide", status == "idle" and p.x == 3 * T + T / 2 and p.y == 4 * T + T / 2,
		status)
end

-- Releasing exactly on a centre is a no-op.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	holdTicks(p, "right", 5) -- exactly one cell
	check("five ticks land on the next centre", p.x == 4 * T + T / 2, tostring(p.x))
	p.dirs = {}
	local status = Movement.step(world, p)
	check("an aligned release does not move", status == "idle" and p.x == 4 * T + T / 2,
		status .. ":" .. tostring(p.x))
end

-- A 180-degree reversal updates the momentum: releasing after walking back
-- glides along the NEW axis sense, to the next centre leftward.
do
	local p = walker(3 * T + T / 2, 4 * T + T / 2)
	holdTicks(p, "right", 3) -- committed rightward, x = +24
	holdTicks(p, "left", 5) -- back past the start centre, x = -16 from it
	check("the reversal is reflected in lastMoveDir", p.lastMoveDir == "left",
		tostring(p.lastMoveDir))
	p.dirs = {}
	idleTicks(p, 4)
	check("a release after a reversal glides to the next centre leftward",
		p.x == 2 * T + T / 2, tostring(p.x))
end

TestLib.finish()
