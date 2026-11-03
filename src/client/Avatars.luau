-- src/client/Avatars.luau
-- 玩家外观。只存在于客户端，位置由 Main.client 每帧传入（自己=预测位置，别人=插值位置）。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Grid = require(Shared:WaitForChild("Grid"))

local Avatars = {}

local BODY_SIZE = 5
local BODY_CENTER_Y = BODY_SIZE / 2

local folder: Folder? = nil
local avatars = {} -- [userId] = { model, shell, lastX, lastZ }

local function getFolder(): Folder
    if folder == nil or folder.Parent == nil then
        folder = Instance.new("Folder")
        folder.Name = "BnBAvatars"
        folder.Parent = workspace
    end
    return folder :: Folder
end

local function newBall(name: string, diameter: number, offset: Vector3, color: Color3, parent: Instance): Part
    local part = Instance.new("Part")
    part.Name = name
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(diameter, diameter, diameter)
    part.CFrame = CFrame.new(offset)
    part.Color = color
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Parent = parent
    return part
end

local function create(userId: number, slot: number)
    local rgb = Constants.PLAYER_COLORS[slot] or Constants.PLAYER_COLORS[1]

    local model = Instance.new("Model")
    model.Name = tostring(userId)

    local body = newBall("Body", BODY_SIZE, Vector3.zero, Color3.fromRGB(rgb[1], rgb[2], rgb[3]), model)
    body.Material = Enum.Material.SmoothPlastic
    model.PrimaryPart = body

    -- 俯视角度：两只眼睛放在球的上表面，朝向屏幕下方
    local black = Color3.fromRGB(25, 25, 30)
    newBall("EyeL", 0.9, Vector3.new(-0.9, 2.1, 0.8), black, model)
    newBall("EyeR", 0.9, Vector3.new(0.9, 2.1, 0.8), black, model)

    -- 被困时的泡泡外壳
    local shell = newBall("Shell", BODY_SIZE * 1.55, Vector3.zero, Color3.fromRGB(170, 220, 255), model)
    shell.Material = Enum.Material.Glass
    shell.Transparency = 1

    -- 名字
    local player = Players:GetPlayerByUserId(userId)
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(140, 26)
    billboard.StudsOffset = Vector3.new(0, 4.4, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = body
    billboard.Parent = body

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 16
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextStrokeTransparency = 0.4
    label.Text = player and player.DisplayName or tostring(userId)
    label.Parent = billboard

    model.Parent = getFolder()

    local record = { model = model, shell = shell }
    avatars[userId] = record
    return record
end

-- x, z: 连续的格坐标。trapped: 是否被困。
function Avatars.update(userId: number, slot: number, x: number, z: number, trapped: boolean)
    local record = avatars[userId] or create(userId, slot)

    local position = Grid.cellToWorld(x, z, BODY_CENTER_Y)
    record.model:PivotTo(CFrame.new(position))

    record.shell.Transparency = trapped and 0.55 or 1
end

function Avatars.remove(userId: number)
    local record = avatars[userId]
    if record then
        record.model:Destroy()
        avatars[userId] = nil
    end
end

function Avatars.clear()
    for userId in avatars do
        Avatars.remove(userId)
    end
end

return Avatars
