-- src/ReplicatedStorage/Shared/MapRules.luau

local Constants = require(script.Parent.Constants)
local Grid = require(script.Parent.Grid)

local MapRules = {}

local TILE = Constants.TILE

-- 创建空地图
function MapRules.createEmptyMap(width: number?, height: number?)
    local mapWidth = width or Constants.MAP_WIDTH
    local mapHeight = height or Constants.MAP_HEIGHT

    local map = {
        width = mapWidth,
        height = mapHeight,
        cells = {},
    }

    for row = 1, mapHeight do
        map.cells[row] = {}

        for col = 1, mapWidth do
            map.cells[row][col] = TILE.EMPTY
        end
    end

    return map
end

-- 创建默认测试地图
function MapRules.createDefaultMap()
    local map = MapRules.createEmptyMap()

    -- 外围固定墙
    for row = 1, map.height do
        for col = 1, map.width do
            if col == 1 or col == map.width
                or row == 1 or row == map.height then
                map.cells[row][col] = TILE.WALL
            end
        end
    end

    -- 内部固定墙，形成规则障碍
    for row = 3, map.height - 2, 2 do
        for col = 3, map.width - 2, 2 do
            map.cells[row][col] = TILE.WALL
        end
    end

    -- 在非固定墙位置布置可破坏箱子
    for row = 2, map.height - 1 do
        for col = 2, map.width - 1 do
            if map.cells[row][col] == TILE.EMPTY then
                map.cells[row][col] = TILE.CRATE
            end
        end
    end

    -- 为四个角落的出生区域留出空间
    local spawnAreas = {
        {2, 2}, {3, 2}, {2, 3},
        {map.width - 1, 2}, {map.width - 2, 2}, {map.width - 1, 3},
        {2, map.height - 1}, {3, map.height - 1}, {2, map.height - 2},
        {map.width - 1, map.height - 1},
        {map.width - 2, map.height - 1},
        {map.width - 1, map.height - 2},
    }

    for _, position in ipairs(spawnAreas) do
        local col = position[1]
        local row = position[2]
        map.cells[row][col] = TILE.EMPTY
    end

    return map
end

-- 获取指定位置的地图单元
-- 越界返回 nil
function MapRules.getCell(map, col: number, row: number): number?
    if not Grid.isInside(col, row, map.width, map.height) then
        return nil
    end

    return map.cells[row][col]
end

-- 修改指定位置的地图单元
function MapRules.setCell(map, col: number, row: number, tileType: number): boolean
    if not Grid.isInside(col, row, map.width, map.height) then
        return false
    end

    map.cells[row][col] = tileType
    return true
end

-- 判断一个格子是否可以通行
function MapRules.isWalkable(map, col: number, row: number): boolean
    return MapRules.getCell(map, col, row) == TILE.EMPTY
end

return table.freeze(MapRules)
