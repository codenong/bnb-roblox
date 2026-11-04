-- src/shared/Grid.luau
-- Original BnB logic coordinates are 0-based tile/pixel coordinates.

local Constants = require(script.Parent.Constants)

local Grid = {}

local TILE = Constants.TILE
local CHARS = { [0] = ".", [1] = "#", [2] = "o", [3] = "H", [4] = "x" }

function Grid.key(x: number, y: number): string
    return tostring(x) .. "," .. tostring(y)
end

function Grid.parseKey(key: string): (number, number)
    local comma = string.find(key, ",", 1, true)
    if not comma then
        return 0, 0
    end
    return tonumber(string.sub(key, 1, comma - 1)) or 0,
        tonumber(string.sub(key, comma + 1)) or 0
end

function Grid.tileOf(pixel: number): number
    return math.floor(pixel / TILE)
end

function Grid.center(tileValue: number): number
    return tileValue * TILE + TILE / 2
end

function Grid.isInside(x: number, y: number): boolean
    return x >= 0 and y >= 0 and x < Constants.COLS and y < Constants.ROWS
end

function Grid.sign(value: number): number
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

-- grid is 0-based: grid[y][x]; rows are serialized as 15-char strings.
function Grid.gridToRows(grid): { string }
    local rows = {}
    for y = 0, Constants.ROWS - 1 do
        local chars = {}
        for x = 0, Constants.COLS - 1 do
            chars[x + 1] = CHARS[grid[y][x]] or "."
        end
        rows[y + 1] = table.concat(chars)
    end
    return rows
end

function Grid.rowsToGrid(rows): { { number } }
    local grid = {}
    for y = 0, Constants.ROWS - 1 do
        local row = {}
        local text = rows[y + 1] or string.rep(".", Constants.COLS)
        for x = 0, Constants.COLS - 1 do
            local ch = string.sub(text, x + 1, x + 1)
            local tile = 0
            if ch == "#" then
                tile = 1
            elseif ch == "o" then
                tile = 2
            elseif ch == "H" then
                tile = 3
            elseif ch == "x" then
                tile = 4
            end
            row[x] = tile
        end
        grid[y] = row
    end
    return grid
end

return table.freeze(Grid)
