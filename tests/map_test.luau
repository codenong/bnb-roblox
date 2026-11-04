local TestLib = require("./testlib")
local Constants = require("./Constants")
local Grid = require("./Grid")
local Map = require("./Map")

local check = TestLib.check
local COLS, ROWS = Constants.COLS, Constants.ROWS

local grid = Map.buildMap()

local rowCount = 0
for _ in pairs(grid) do
    rowCount += 1
end
check("13 rows", rowCount == ROWS, rowCount)
for y = 0, ROWS - 1 do
    local colCount = 0
    for _ in pairs(grid[y]) do
        colCount += 1
    end
    check("row length " .. y, colCount == COLS, colCount)
end

for _, spawn in ipairs(Map.SPAWNS) do
    check(
        string.format("spawn empty (%d,%d)", spawn[1], spawn[2]),
        grid[spawn[2]][spawn[1]] == Map.EMPTY,
        grid[spawn[2]][spawn[1]]
    )
end

local soft, crates, walls, houses = 0, 0, 0, 0
for y = 0, ROWS - 1 do
    for x = 0, COLS - 1 do
        local tile = grid[y][x]
        if Map.isSoft(tile) then
            soft += 1
        end
        if tile == Map.CRATE then
            crates += 1
        elseif tile == Map.WALL then
            walls += 1
        elseif tile == Map.HOUSE then
            houses += 1
        end
    end
end

check("soft+crate >= 100", soft >= 100, soft)
check("crate >= 20", crates >= 20, crates)
check("cannons at four corners", walls == 4, walls)
check("central mast shape", houses == 7, houses)

for _, pos in ipairs({ { 1, 1 }, { 13, 1 }, { 1, 11 }, { 13, 11 } }) do
    check(
        string.format("cannon (%d,%d)", pos[1], pos[2]),
        grid[pos[2]][pos[1]] == Map.WALL
    )
end
for _, pos in ipairs({ { 7, 4 }, { 6, 5 }, { 7, 5 }, { 8, 5 }, { 6, 6 }, { 7, 6 }, { 8, 6 } }) do
    check(
        string.format("mast (%d,%d)", pos[1], pos[2]),
        grid[pos[2]][pos[1]] == Map.HOUSE
    )
end
check("flag tip walkable", grid[3][7] == Map.EMPTY)

for y = 0, ROWS - 1 do
    local symmetric = true
    for x = 0, COLS - 1 do
        if grid[y][x] ~= grid[y][COLS - 1 - x] then
            symmetric = false
            break
        end
    end
    check("row symmetric " .. y, symmetric)
end

check("six spawns", #Map.SPAWNS == 6, #Map.SPAWNS)
check("six mount spots", #Map.MOUNT_SPOTS == 6, #Map.MOUNT_SPOTS)

local mounts = { turtle = 0, owl = 0, pirateTurtle = 0 }
for _, spot in ipairs(Map.MOUNT_SPOTS) do
    check(
        string.format("mount spot empty (%d,%d)", spot[1], spot[2]),
        grid[spot[2]][spot[1]] == Map.EMPTY
    )
    mounts[spot[3]] = (mounts[spot[3]] or 0) + 1
end
check("two turtles", mounts.turtle == 2, mounts.turtle)
check("two owls", mounts.owl == 2, mounts.owl)
check("two pirate turtles", mounts.pirateTurtle == 2, mounts.pirateTurtle)

local rows = Grid.gridToRows(grid)
check("grid serialization", #rows == ROWS and #rows[1] == COLS, #rows)

TestLib.finish()
