-- src/client/CameraRig.luau
-- 固定俯视镜头：整张地图始终完整显示在屏幕内，不跟随玩家。
-- 默认是正俯视 + 小视角（纯 2D 观感）；改 Constants 里的俯角和 FOV 即可切回斜视角。
-- 屏幕右 = +X（列增加），屏幕上 = -Z（行减少）。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))

local CameraRig = {}

local CELL_SIZE = Constants.CELL_SIZE
local WALL_HEIGHT = 2.4
local MARGIN = CELL_SIZE * 0.8 -- 地图四周留白
local SAFETY = 1.18 -- 透视会让近处看起来更大，多留一点余量

local mapWidth = Constants.MAP_WIDTH
local mapHeight = Constants.MAP_HEIGHT

function CameraRig.setMapSize(width: number, height: number)
    mapWidth = width
    mapHeight = height
end

local function update()
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end

    camera.CameraType = Enum.CameraType.Scriptable
    camera.FieldOfView = Constants.CAMERA_FOV

    local viewport = camera.ViewportSize
    if viewport.Y <= 0 then
        return
    end

    local aspect = viewport.X / viewport.Y
    local tilt = math.rad(Constants.CAMERA_TILT_DEG)
    local tanV = math.tan(math.rad(camera.FieldOfView) / 2)
    local tanH = tanV * aspect

    local halfWidth = mapWidth * CELL_SIZE / 2 + MARGIN
    local halfDepth = mapHeight * CELL_SIZE / 2 + MARGIN

    -- 地图在屏幕上的半高：进深按俯角投影，再加上墙的高度
    local projectedHalfHeight = halfDepth * math.sin(tilt) + WALL_HEIGHT * math.cos(tilt)

    local distance = math.max(projectedHalfHeight / tanV, halfWidth / tanH) * SAFETY

    local center = Grid.cellToWorld((mapWidth + 1) / 2, (mapHeight + 1) / 2, 0)
    local offset = Vector3.new(0, math.sin(tilt), math.cos(tilt)) * distance

    -- 屏幕上方 = -Z（行减少）。正俯视时视线与世界 Y 轴平行，必须显式给出 up 向量。
    camera.CFrame = CFrame.lookAt(center + offset, center, Vector3.new(0, 0, -1))
end

function CameraRig.start()
    RunService:BindToRenderStep("BnBCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraRig
