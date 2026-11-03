-- src/ReplicatedStorage/Shared/Constants.luau

local Constants = {
    -- 地图尺寸
    MAP_WIDTH = 15,
    MAP_HEIGHT = 13,

    -- 每个网格单元对应的 Roblox 世界尺寸
    CELL_SIZE = 8,

    -- 地图中单元格的逻辑类型
    TILE = {
        EMPTY = 0,
        WALL = 1,
        CRATE = 2,
    },

    -- 默认地图中第一格中心点的世界坐标
    MAP_ORIGIN = Vector3.new(0, 0, 0),
}

return table.freeze(Constants)
