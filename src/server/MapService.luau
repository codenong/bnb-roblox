-- src/server/MapService.luau
-- 负责地图的逻辑数据和场景中的实体（地板、墙、箱子）

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local MapRules = require(Shared:WaitForChild("MapRules"))

local MapService = {}

-- 当前这局的地图数据，build() 之后可用
MapService.map = nil

local TILE = Constants.TILE
local CELL_SIZE = Constants.CELL_SIZE

-- 纯 2D 俯视：方块都做得很薄，主要靠颜色区分
local FLOOR_THICKNESS = 1
local WALL_HEIGHT = 2.4
local CRATE_HEIGHT = 1.6

local FLOOR_COLORS = {
    Color3.fromRGB(58, 64, 74),
    Color3.fromRGB(68, 75, 87),
}
local WALL_COLOR = Color3.fromRGB(38, 44, 62)
local CRATE_COLOR = Color3.fromRGB(196, 134, 76)

local cratePartsByKey = {}

local function createPart(
    parent: Instance,
    name: string,
    size: Vector3,
    position: Vector3,
    color: Color3
): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.Position = position
    part.Anchored = true
    part.Color = color
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Parent = parent

    return part
end

function MapService.build()
    -- 避免重复生成地图
    local oldMap = workspace:FindFirstChild("GameMap")
    if oldMap then
        oldMap:Destroy()
    end
    table.clear(cratePartsByKey)

    local map = MapRules.createDefaultMap()
    MapService.map = map

    local folder = Instance.new("Folder")
    folder.Name = "GameMap"

    for row = 1, map.height do
        for col = 1, map.width do
            local tile = MapRules.getCell(map, col, row)
            local center = Grid.cellToWorld(col, row)

            -- 棋盘格地板，方便看清格子
            createPart(
                folder,
                "Tile_" .. col .. "_" .. row,
                Vector3.new(CELL_SIZE, FLOOR_THICKNESS, CELL_SIZE),
                Vector3.new(
                    center.X,
                    Constants.MAP_ORIGIN.Y - FLOOR_THICKNESS / 2,
                    center.Z
                ),
                FLOOR_COLORS[(col + row) % 2 + 1]
            )

            if tile == TILE.WALL then
                createPart(
                    folder,
                    "Wall_" .. col .. "_" .. row,
                    Vector3.new(CELL_SIZE, WALL_HEIGHT, CELL_SIZE),
                    Vector3.new(
                        center.X,
                        Constants.MAP_ORIGIN.Y + WALL_HEIGHT / 2,
                        center.Z
                    ),
                    WALL_COLOR
                )

            elseif tile == TILE.CRATE then
                local crate = createPart(
                    folder,
                    "Crate_" .. col .. "_" .. row,
                    Vector3.new(CELL_SIZE * 0.88, CRATE_HEIGHT, CELL_SIZE * 0.88),
                    Vector3.new(
                        center.X,
                        Constants.MAP_ORIGIN.Y + CRATE_HEIGHT / 2,
                        center.Z
                    ),
                    CRATE_COLOR
                )
                cratePartsByKey[Grid.key(col, row)] = crate
            end
        end
    end

    folder.Parent = workspace

    print(
        string.format(
            "地图生成完成：%d × %d，共 %d 个格子",
            map.width,
            map.height,
            map.width * map.height
        )
    )

    return map
end

-- 摧毁一个箱子：逻辑格改为空地，同时移除场景中的实体
function MapService.destroyCrate(col: number, row: number)
    local map = MapService.map
    if not map then
        return
    end

    if MapRules.getCell(map, col, row) == TILE.CRATE then
        MapRules.setCell(map, col, row, TILE.EMPTY)
    end

    local key = Grid.key(col, row)
    local part = cratePartsByKey[key]
    if part then
        cratePartsByKey[key] = nil
        part:Destroy()
    end
end

return MapService
