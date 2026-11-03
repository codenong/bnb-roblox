
-- src/server/MapService.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local MapRules = require(Shared:WaitForChild("MapRules"))

local MapService = {}

local TILE = Constants.TILE
local CELL_SIZE = Constants.CELL_SIZE

local FLOOR_THICKNESS = 1
local WALL_HEIGHT = 6
local CRATE_HEIGHT = 4

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

    local map = MapRules.createDefaultMap()

    local folder = Instance.new("Folder")
    folder.Name = "GameMap"
    folder.Parent = workspace

    local mapCenter = Grid.cellToWorld(
        (map.width + 1) / 2,
        (map.height + 1) / 2
    )

    -- 地板覆盖整个网格区域
    createPart(
        folder,
        "Floor",
        Vector3.new(
            map.width * CELL_SIZE,
            FLOOR_THICKNESS,
            map.height * CELL_SIZE
        ),
        Vector3.new(
            mapCenter.X,
            Constants.MAP_ORIGIN.Y - FLOOR_THICKNESS / 2,
            mapCenter.Z
        ),
        Color3.fromRGB(65, 70, 78)
    )

    for row = 1, map.height do
        for col = 1, map.width do
            local tile = MapRules.getCell(map, col, row)
            local center = Grid.cellToWorld(col, row)

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
                    Color3.fromRGB(80, 88, 105)
                )

            elseif tile == TILE.CRATE then
                createPart(
                    folder,
                    "Crate_" .. col .. "_" .. row,
                    Vector3.new(CELL_SIZE * 0.85, CRATE_HEIGHT, CELL_SIZE * 0.85),
                    Vector3.new(
                        center.X,
                        Constants.MAP_ORIGIN.Y + CRATE_HEIGHT / 2,
                        center.Z
                    ),
                    Color3.fromRGB(170, 112, 65)
                )
            end
        end
    end

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

return MapService
