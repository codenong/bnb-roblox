-- src/shared/Map.luau
-- Verbatim port of BnB/server/map.js (海盗14, 15x13).

local Constants = require(script.Parent.Constants)

local Map = {}

Map.TILE = Constants.TILE
Map.COLS = Constants.COLS
Map.ROWS = Constants.ROWS

Map.EMPTY = 0
Map.WALL = 1 -- ship cannon
Map.SOFT = 2 -- yellow crate
Map.HOUSE = 3 -- central mast
Map.CRATE = 4 -- X crate

local LAYOUT = {
    "oooo...o...oooo",
    "o#o.xxx.xxx.o#o",
    "oo.x.o.x.o.x.oo",
    "o.x.ooo.ooo.x.o",
    "o.xooooHoooox.o",
    "o.x.ooHHHoo.x.o",
    "o.xoooHHHooox.o",
    "oo.x.ooooo.x.oo",
    "ooo.xooooox.ooo",
    "oooo.x.o.x.oooo",
    "oo.oo.xxx.oo.oo",
    "o#.ooo...ooo.#o",
    "o..ooooooooo..o",
}

Map.SPAWNS = {
    { 1, 6 },
    { 13, 6 },
    { 1, 3 },
    { 13, 3 },
    { 2, 11 },
    { 12, 11 },
}

Map.MOUNT_SPOTS = {
    { 4, 0, "turtle" },
    { 10, 0, "turtle" },
    { 1, 5, "owl" },
    { 13, 5, "owl" },
    { 2, 12, "pirateTurtle" },
    { 12, 12, "pirateTurtle" },
}

local CODES = {
    ["."] = Map.EMPTY,
    ["#"] = Map.WALL,
    ["o"] = Map.SOFT,
    ["H"] = Map.HOUSE,
    ["x"] = Map.CRATE,
}

function Map.isSoft(tile: number): boolean
    return tile == Map.SOFT or tile == Map.CRATE
end

function Map.buildMap()
    local grid = {}
    for y = 0, Constants.ROWS - 1 do
        local row = LAYOUT[y + 1]
        assert(#row == Constants.COLS, string.format("map row %d length %d", y, #row))
        local tiles = {}
        for x = 0, Constants.COLS - 1 do
            local ch = string.sub(row, x + 1, x + 1)
            tiles[x] = CODES[ch] or Map.EMPTY
        end
        grid[y] = tiles
    end
    return grid
end

return table.freeze(Map)
