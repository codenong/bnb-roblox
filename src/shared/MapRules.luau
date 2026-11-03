-- src/shared/MapRules.luau

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
        bubbles = {}, -- [Grid.key(col,row)] = true，当前存在泡泡的格子
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

-- 判断一个格子的地形是否可以通行（不考虑泡泡）
function MapRules.isWalkable(map, col: number, row: number): boolean
    return MapRules.getCell(map, col, row) == TILE.EMPTY
end

-- 四个出生点（按玩家槽位顺序：左上、右下、右上、左下），2 人对战时正好在对角
function MapRules.getSpawnPoints(map)
    return {
        { 2, 2 },
        { map.width - 1, map.height - 1 },
        { map.width - 1, 2 },
        { 2, map.height - 1 },
    }
end

-- 生成"是否阻挡移动"的判断函数，供 Movement 使用
-- ignore: 该玩家当前可以穿过的泡泡集合（刚放下泡泡时，站在里面的人可以走出来）
function MapRules.makeSolidFn(map, ignore)
    local cells = map.cells
    local bubbles = map.bubbles
    local width, height = map.width, map.height

    return function(col: number, row: number): boolean
        if col < 1 or col > width or row < 1 or row > height then
            return true
        end

        if cells[row][col] ~= TILE.EMPTY then
            return true
        end

        local key = Grid.key(col, row)
        if bubbles[key] and not (ignore and ignore[key]) then
            return true
        end

        return false
    end
end

-- 地图压平成一维数组（按行优先），用于网络传输
function MapRules.flatten(map): { number }
    local flat = table.create(map.width * map.height)
    for row = 1, map.height do
        for col = 1, map.width do
            flat[#flat + 1] = map.cells[row][col]
        end
    end
    return flat
end

-- 从一维数组还原地图
function MapRules.unflatten(width: number, height: number, flat: { number })
    local map = MapRules.createEmptyMap(width, height)
    local index = 1
    for row = 1, height do
        for col = 1, width do
            map.cells[row][col] = flat[index]
            index += 1
        end
    end
    return map
end

return table.freeze(MapRules)
