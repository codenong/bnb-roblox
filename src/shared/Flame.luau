-- src/shared/Flame.luau
-- Port of computeFlameCells from BnB/server/game.js.

local Constants = require(script.Parent.Constants)
local Map = require(script.Parent.Map)

local Flame = {}

local DIRS4 = Constants.DIRS4

-- Returns an array of {x, y} cells. Includes the bomb cell. Soft crates are
-- included and stop the ray; walls/masts stop without being included.
function Flame.computeFlameCells(grid, tx: number, ty: number, range: number)
    local cells = { { tx, ty } }
    for _, direction in ipairs(DIRS4) do
        local dx, dy = direction[1], direction[2]
        for i = 1, range do
            local x = tx + dx * i
            local y = ty + dy * i
            if x < 0 or y < 0 or x >= Constants.COLS or y >= Constants.ROWS then
                break
            end
            local tile = grid[y][x]
            if tile == Map.WALL or tile == Map.HOUSE then
                break
            end
            table.insert(cells, { x, y })
            if Map.isSoft(tile) then
                break
            end
        end
    end
    return cells
end

return table.freeze(Flame)
