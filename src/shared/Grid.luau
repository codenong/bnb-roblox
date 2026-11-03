-- src/ReplicatedStorage/Shared/Grid.luau

local Constants = require(script.Parent.Constants)

local Grid = {}

local CELL_SIZE = Constants.CELL_SIZE
local DEFAULT_ORIGIN = Constants.MAP_ORIGIN

-- 网格坐标转换为世界坐标
-- col: 列，从 1 开始
-- row: 行，从 1 开始
-- y: 世界高度
-- origin: 第一格中心点，可选
function Grid.cellToWorld(col: number, row: number, y: number?, origin: Vector3?): Vector3
    local mapOrigin = origin or DEFAULT_ORIGIN
    local height = y or mapOrigin.Y

    local x = mapOrigin.X + (col - 1) * CELL_SIZE
    local z = mapOrigin.Z + (row - 1) * CELL_SIZE

    return Vector3.new(x, height, z)
end

-- 世界坐标转换为最近的网格坐标
function Grid.worldToCell(position: Vector3, origin: Vector3?): (number, number)
    local mapOrigin = origin or DEFAULT_ORIGIN

    local col = math.floor((position.X - mapOrigin.X) / CELL_SIZE + 0.5) + 1
    local row = math.floor((position.Z - mapOrigin.Z) / CELL_SIZE + 0.5) + 1

    return col, row
end

-- 判断网格坐标是否位于地图范围内
function Grid.isInside(col: number, row: number, width: number?, height: number?): boolean
    local mapWidth = width or Constants.MAP_WIDTH
    local mapHeight = height or Constants.MAP_HEIGHT

    return col >= 1
        and col <= mapWidth
        and row >= 1
        and row <= mapHeight
end

return table.freeze(Grid)
