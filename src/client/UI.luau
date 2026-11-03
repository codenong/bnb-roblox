-- src/client/UI.luau
-- 屏幕上的文字提示：回合状态/倒计时、自己的状态、操作说明

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = {}

local gui: ScreenGui
local messageLabel: TextLabel
local statusLabel: TextLabel

local roundMessage = ""
local roundEndsAt = 0
local localStatus = ""

local function createLabel(name: string, size: number, position: UDim2): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = name
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = position
    label.Size = UDim2.new(0.9, 0, 0, size + 10)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = size
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextStrokeTransparency = 0.4
    label.Text = ""
    label.Parent = gui
    return label
end

function UI.init(): ScreenGui
    gui = Instance.new("ScreenGui")
    gui.Name = "BnBGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

    messageLabel = createLabel("Message", 30, UDim2.new(0.5, 0, 0, 14))
    statusLabel = createLabel("Status", 22, UDim2.new(0.5, 0, 0, 56))
    statusLabel.TextColor3 = Color3.fromRGB(255, 220, 120)

    -- 桌面端的操作提示
    if not UserInputService.TouchEnabled then
        local hint = Instance.new("TextLabel")
        hint.Name = "Hint"
        hint.AnchorPoint = Vector2.new(0.5, 1)
        hint.Position = UDim2.new(0.5, 0, 1, -12)
        hint.Size = UDim2.new(0.9, 0, 0, 24)
        hint.BackgroundTransparency = 1
        hint.Font = Enum.Font.Gotham
        hint.TextSize = 18
        hint.TextColor3 = Color3.new(1, 1, 1)
        hint.TextTransparency = 0.2
        hint.TextStrokeTransparency = 0.6
        hint.Text = "WASD / 方向键 移动　　空格 放泡泡"
        hint.Parent = gui
    end

    return gui
end

function UI.setRound(_state: string, message: string, endsAt: number)
    roundMessage = message
    roundEndsAt = endsAt
end

function UI.setLocalStatus(text: string)
    localStatus = text
end

-- 每帧调用：刷新倒计时
function UI.update()
    local text = roundMessage
    if roundEndsAt > 0 then
        local remaining = math.max(0, math.ceil(roundEndsAt - workspace:GetServerTimeNow()))
        text = string.format("%s  %d", roundMessage, remaining)
    end
    messageLabel.Text = text
    statusLabel.Text = localStatus
end

return UI
