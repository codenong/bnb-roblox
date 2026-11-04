-- src/client/Board.luau
-- The 600x520 playfield: static deck and obstacles. Dynamic things (players,
-- bombs, items, flames) are drawn by Renderer above these layers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))
local Map = require(Shared:WaitForChild("Map"))
local Sprites = require(Shared:WaitForChild("Sprites"))
local AssetIds = require(Shared:WaitForChild("AssetIds"))

local T = Constants.TILE
local WIDTH = Constants.BOARD_WIDTH
local HEIGHT = Constants.BOARD_HEIGHT

local Board = {}

local board: Frame
local obstacles = {}
local floorBuilt = false
local function asset(key: string): string
    return AssetIds[key] or ""
end

local function setZRecursive(root: GuiObject, z: number)
    root.ZIndex = z
    for _, child in ipairs(root:GetDescendants()) do
        if child:IsA("GuiObject") then
            child.ZIndex = z
        end
    end
end

local function makeObstacleRoot(x: number, y: number, z: number): Frame
    local root = Instance.new("Frame")
    root.Name = string.format("Obstacle_%d_%d", x, y)
    root.BackgroundTransparency = 1
    root.BorderSizePixel = 0
    root.Size = UDim2.fromOffset(0, 0)
    root.Position = UDim2.fromOffset(0, 0)
    root.ZIndex = z
    root.Parent = board
    return root
end

local function makeImage(parent: Instance, key: string, x: number, y: number, w: number, h: number)
    local id = asset(key)
    if id == "" then
        return nil
    end
    local image = Instance.new("ImageLabel")
    image.BackgroundTransparency = 1
    image.BorderSizePixel = 0
    image.Image = id
    image.Position = UDim2.fromOffset(x, y)
    image.Size = UDim2.fromOffset(w, h)
    image.ScaleType = Enum.ScaleType.Stretch
    image.Parent = parent
    return image
end

local function makeBoxFallback(parent: Instance, x: number, y: number, kind: string)
    local box = Instance.new("Frame")
    box.BackgroundColor3 = if kind == "crate"
        then Color3.fromRGB(101, 55, 28)
        else Color3.fromRGB(205, 142, 45)
    box.BorderSizePixel = 0
    box.Position = UDim2.fromOffset(x + 2, y + 5)
    box.Size = UDim2.fromOffset(T - 4, 43)
    box.ZIndex = 2
    box.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.1, 0)
    corner.Parent = box

    local stroke = Instance.new("UIStroke")
    stroke.Color = if kind == "crate"
        then Color3.fromRGB(51, 26, 12)
        else Color3.fromRGB(122, 77, 18)
    stroke.Thickness = 2
    stroke.Parent = box

    local shine = Instance.new("Frame")
    shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    shine.BackgroundTransparency = 0.75
    shine.BorderSizePixel = 0
    shine.Position = UDim2.fromOffset(3, 3)
    shine.Size = UDim2.new(1, -6, 0, 5)
    shine.ZIndex = 3
    shine.Parent = box

    local corner2 = Instance.new("UICorner")
    corner2.CornerRadius = UDim.new(0.3, 0)
    corner2.Parent = shine

    if kind == "crate" then
        local mark = Instance.new("TextLabel")
        mark.BackgroundTransparency = 1
        mark.Size = UDim2.fromScale(1, 1)
        mark.Font = Enum.Font.GothamBold
        mark.Text = "✕"
        mark.TextColor3 = Color3.fromRGB(245, 196, 120)
        mark.TextSize = 22
        mark.TextTransparency = 0.15
        mark.ZIndex = 4
        mark.Parent = box
    end
end

local function makeObstacle(kind: string, x: number, y: number)
    local z = 100 + y * 100
    local root = makeObstacleRoot(x, y, z)

    if kind == "box" or kind == "crate" then
        local sheet = Sprites.SHEETS[if kind == "crate" then "crate" else "box"]
        local image = makeImage(root, sheet.assetKey, x * T, y * T + T / 8, T, T * 1.2)
        if not image then
            makeBoxFallback(root, x * T, y * T, kind)
        end
    elseif kind == "cannon" then
        local sheet = Sprites.SHEETS.cannon
        local image = makeImage(root, sheet.assetKey, x * T, y * T - T, T, T * 2)
        if not image then
            local base = Instance.new("Frame")
            base.BackgroundColor3 = Color3.fromRGB(30, 38, 50)
            base.BorderSizePixel = 0
            base.Position = UDim2.fromOffset(x * T + 2, y * T + 2)
            base.Size = UDim2.fromOffset(T - 4, T - 4)
            base.ZIndex = 2
            base.Parent = root
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0.5, 0)
            corner.Parent = base
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(115, 135, 160)
            stroke.Thickness = 2
            stroke.Parent = base
            local barrel = Instance.new("Frame")
            barrel.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
            barrel.BorderSizePixel = 0
            barrel.Position = UDim2.fromOffset(T / 2 - 4, -10)
            barrel.Size = UDim2.fromOffset(8, 24)
            barrel.ZIndex = 3
            barrel.Parent = root
        end
    end

    setZRecursive(root, z)
    obstacles[string.format("%d,%d", x, y)] = {
        kind = kind,
        root = root,
    }
end

local function removeObstacle(key: string)
    local entry = obstacles[key]
    if entry then
        entry.root:Destroy()
        obstacles[key] = nil
    end
end

local function buildFloor()
    if floorBuilt then
        return
    end
    floorBuilt = true

    local id = asset(Sprites.SHEETS.floor_checker.assetKey)
    if id ~= "" then
        local image = Instance.new("ImageLabel")
        image.Name = "Floor"
        image.BackgroundTransparency = 1
        image.BorderSizePixel = 0
        image.Image = id
        image.ScaleType = Enum.ScaleType.Tile
        image.TileSize = UDim2.fromOffset(80, 80)
        image.Size = UDim2.fromOffset(WIDTH, HEIGHT)
        image.ZIndex = 1
        image.Parent = board
    else
        for y = 0, Constants.ROWS - 1 do
            for x = 0, Constants.COLS - 1 do
                local tile = Instance.new("Frame")
                tile.BorderSizePixel = 0
                tile.Position = UDim2.fromOffset(x * T, y * T)
                tile.Size = UDim2.fromOffset(T, T)
                tile.BackgroundColor3 = if (x + y) % 2 == 0
                    then Color3.fromRGB(151, 105, 45)
                    else Color3.fromRGB(166, 118, 51)
                tile.ZIndex = 1
                tile.Parent = board
            end
        end
    end

    -- Central mast is static; keep it above row 7 obstacles but below row 7 items.
    local mast = makeObstacleRoot(5, 2, 100 + 7 * 100 + 5)
    mast.Name = "Mast"
    local sheet = Sprites.SHEETS.mast
    local image = makeImage(mast, sheet.assetKey, 5 * T, 2 * T, 5 * T, 6 * T)
    if not image then
        local pole = Instance.new("Frame")
        pole.BackgroundColor3 = Color3.fromRGB(79, 49, 26)
        pole.BorderSizePixel = 0
        pole.AnchorPoint = Vector2.new(0.5, 1)
        pole.Position = UDim2.fromOffset(7 * T, 8 * T)
        pole.Size = UDim2.fromOffset(12, 6 * T)
        pole.ZIndex = 2
        pole.Parent = mast

        local sail = Instance.new("TextLabel")
        sail.BackgroundColor3 = Color3.fromRGB(34, 27, 41)
        sail.BorderSizePixel = 0
        sail.AnchorPoint = Vector2.new(0.5, 0.5)
        sail.Position = UDim2.fromOffset(7 * T, 5 * T)
        sail.Size = UDim2.fromOffset(92, 74)
        sail.Font = Enum.Font.GothamBold
        sail.Text = "⚓"
        sail.TextColor3 = Color3.fromRGB(238, 222, 180)
        sail.TextSize = 54
        sail.ZIndex = 3
        sail.Parent = mast

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.15, 0)
        corner.Parent = sail
    end
    setZRecursive(mast, 100 + 7 * 100 + 5)
    obstacles.mast = { kind = "mast", root = mast }
end

function Board.new(parent: Instance): Frame
    board = Instance.new("Frame")
    board.Name = "Board"
    board.AnchorPoint = Vector2.new(0, 0)
    board.Position = UDim2.fromOffset(0, 0)
    board.Size = UDim2.fromOffset(WIDTH, HEIGHT)
    board.BackgroundColor3 = Color3.fromRGB(11, 35, 52)
    board.BorderSizePixel = 0
    board.ClipsDescendants = true
    board.Parent = parent

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(96, 165, 190)
    stroke.Thickness = 2
    stroke.Transparency = 0.25
    stroke.Parent = board

    obstacles = {}
    buildFloor()
    return board
end

function Board.getFrame(): Frame
    return board
end

function Board.setGrid(rows)
    if not rows or not board then
        return
    end
    buildFloor()

    local grid = Grid.rowsToGrid(rows)
    local wanted = {}
    for y = 0, Constants.ROWS - 1 do
        for x = 0, Constants.COLS - 1 do
            local tile = grid[y][x]
            local kind = nil
            if tile == Map.SOFT then
                kind = "box"
            elseif tile == Map.CRATE then
                kind = "crate"
            elseif tile == Map.WALL then
                kind = "cannon"
            end
            if kind then
                local key = string.format("%d,%d", x, y)
                wanted[key] = true
                local existing = obstacles[key]
                if not existing or existing.kind ~= kind then
                    if existing then
                        removeObstacle(key)
                    end
                    makeObstacle(kind, x, y)
                end
            end
        end
    end

    for key, entry in pairs(obstacles) do
        if key ~= "mast" and not wanted[key] then
            entry.root:Destroy()
            obstacles[key] = nil
        end
    end

    Board.setSliding({})
end

-- Hide static crates at the source/target cells while a crate is sliding; the
-- Renderer draws the moving crate on top.
function Board.setSliding(slides)
    if not board then
        return
    end
    local hide = {}
    for _, slide in ipairs(slides or {}) do
        hide[string.format("%d,%d", slide.fx, slide.fy)] = true
        hide[string.format("%d,%d", slide.tx, slide.ty)] = true
    end
    for key, entry in pairs(obstacles) do
        if key ~= "mast" then
            entry.root.Visible = not hide[key]
        end
    end
end

function Board.clear()
    for key, entry in pairs(obstacles) do
        if key ~= "mast" then
            entry.root:Destroy()
            obstacles[key] = nil
        end
    end
    Board.setSliding({})
end

return Board
