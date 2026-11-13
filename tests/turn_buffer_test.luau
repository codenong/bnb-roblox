-- Turn buffer (C): an early press keeps the player moving along the previous
-- direction instead of stopping dead; the corner assist completes the turn once
-- the window is reached, and an assist shift that would only fight the momentum
-- is undone so the player keeps advancing instead of oscillating around a lane
-- whose way ahead is shut. Also pins kick parity: pressing into a bomb while
-- buffered still kicks it. Uses the real shared Movement (plus one Game-level
-- kick case) on a small crossroads.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Map = require("./Map")
local Grid = require("./Grid")
local Movement = require("./Movement")

local T, COLS, ROWS = Constants.TILE, Constants.COLS, Constants.ROWS
local HALF = Constants.HALF

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

local function walker(x, y, speed)
	return { id = 1, x = x, y = y, speed = speed or 240, dirs = {} }
end

-- Walk right for one tick to establish momentum, like a real player would.
local function withMomentum(x, y)
	local p = walker(x, y)
	p.dirs = { "right" }
	Movement.step(world, p)
	return p
end

-- An early press, well outside the +-ASSIST_RANGE window, must not stop the
-- player: the buffer carries them forward and the assist turns them in the
-- window.
do
	local p = withMomentum(LANE_X - 56, LANE_Y)
	check("momentum points along the corridor", p.lastMoveDir == "right", tostring(p.lastMoveDir))
	p.dirs = { "up" }
	local statuses = {}
	local turned = false
	for _ = 1, 20 do
		local status = Movement.step(world, p)
		table.insert(statuses, status)
		if p.lastMoveDir == "up" then
			turned = true
			break
		end
	end
	check("an early press still turns into the lane", turned, table.concat(statuses, ","))
	check("the turn ends inside the lane column", math.abs(p.x - LANE_X) < T / 2, tostring(p.x))
	check("the turn actually moved up", p.y < LANE_Y, tostring(p.y))
end

-- A very early press turns too, just later.
do
	local p = withMomentum(LANE_X - 96, LANE_Y)
	p.dirs = { "up" }
	local turned = false
	for _ = 1, 30 do
		Movement.step(world, p)
		if p.lastMoveDir == "up" then
			turned = true
			break
		end
	end
	check("a very early press still turns", turned)
	check("the late-arriving turn also lands in the lane", math.abs(p.x - LANE_X) < T / 2, tostring(p.x))
end

-- A late press past the lane keeps advancing (never freezes), never turns, and
-- stops only at the corridor's end wall.
do
	local p = withMomentum(LANE_X + 30, LANE_Y)
	p.dirs = { "up" }
	local lastX = p.x
	local advanced = 0
	local stopped = false
	for _ = 1, 45 do
		local status = Movement.step(world, p)
		if status == "blocked" then
			stopped = true
			break
		end
		if p.x > lastX then
			advanced += 1
			lastX = p.x
		end
	end
	check("a late press keeps advancing instead of freezing", advanced >= 10, tostring(advanced))
	check("a late press never turns (its window is behind)", p.y == LANE_Y, tostring(p.y))
	check("the buffered walk stops at the corridor end", stopped, tostring(p.x))
	check("the stop is in the last column against the wall",
		p.x >= 13 * T - T / 2 and p.x <= 14 * T - HALF, tostring(p.x))
end

-- Aligned with a blocked column must not oscillate: the assist yank backward
-- along the momentum axis is undone and the buffer advances instead.
do
	local p = withMomentum(LANE_X + 40, LANE_Y)
	p.dirs = { "up" }
	local lastX = p.x
	local monotonic = true
	for _ = 1, 6 do
		Movement.step(world, p)
		if p.x <= lastX then
			monotonic = false
		end
		lastX = p.x
	end
	check("no oscillation around a blocked column (x strictly advances)", monotonic,
		tostring(p.x))
end

-- Holding the SAME direction into a wall still stops dead: the buffer never
-- engages for the direction the player is already pressing.
do
	local p = withMomentum(13 * T + T / 2 + 6, LANE_Y) -- blocked against the end wall
	local startX, startY = p.x, p.y
	p.dirs = { "right" }
	local status = Movement.step(world, p)
	check("pressing into a wall stops", status == "blocked" and p.x == startX and p.y == startY,
		status .. ":" .. tostring(p.x))
end

-- Kick parity at the Game level: pressing up into a bomb while the buffer
-- carries the player right still kicks that bomb.
do
	local Game = require("./Game")
	local game = Game.new({
		{ id = "a", name = "A" },
		{ id = "b", name = "B" },
	}, { warmup = 0 })
	for y = 0, ROWS - 1 do
		for x = 0, COLS - 1 do
			game.grid[y][x] = Map.EMPTY
		end
	end
	local a = game.players.a
	a.x = 3 * T + T / 2
	a.y = 2 * T + T / 2 - 7 -- close enough to the bomb row that up is blocked at once
	a.kick = true
	local b = game.players.b
	b.x = 3 * T + T / 2
	b.y = 1 * T + T / 2
	-- b drops a bomb on their own tile; it is solid for a (no pass).
	game:setInput("b", {}, 1, true)
	game:tick()
	-- Momentum right, then hold up into the bomb above.
	game:setInput("a", { "right" }, 2)
	game:tick()
	check("the buffered walker has rightward momentum", a.lastMoveDir == "right",
		tostring(a.lastMoveDir))
	local startX = a.x
	game:setInput("a", { "up" }, 3)
	game:tick()
	check("the buffered press still advances along the momentum", a.x > startX,
		tostring(a.x) .. " vs " .. tostring(startX))
	local bomb
	for _, candidate in ipairs(game.bombs) do
		if candidate.tx == 3 and candidate.ty == 1 then
			bomb = candidate
		end
	end
	check("the bomb exists above the walker", bomb ~= nil)
	check("pressing into a bomb while buffered still kicks it", bomb and bomb.slide ~= nil,
		bomb and tostring(bomb.slide))
end

-- Sanity: the buffered glide never tunnels through solids (the crossroads
-- corner turns above already prove reachability; here the walker must stay on
-- walkable tiles throughout).
do
	local p = withMomentum(LANE_X - 96, LANE_Y)
	p.dirs = { "up" }
	local onFloor = true
	for _ = 1, 30 do
		Movement.step(world, p)
		local tx, ty = math.floor(p.x / T), math.floor(p.y / T)
		local row = world.grid[ty]
		if not row or row[tx] ~= 0 then
			onFloor = false
		end
		if p.lastMoveDir == "up" then
			break
		end
	end
	check("the buffered walk never leaves walkable tiles", onFloor)
	check("the bomb helper key agrees with Grid", Grid.key(7, 5) ~= nil)
end

TestLib.finish()
