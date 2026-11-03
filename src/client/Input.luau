-- src/client/Input.luau
-- 统一的输入：键盘 WASD/方向键、手柄摇杆/十字键、触屏虚拟方向键
-- 方向约定：返回 (dirX, dirZ)，dirX>0 是屏幕右侧（列增加），dirZ<0 是屏幕上方（行减少）

local UserInputService = game:GetService("UserInputService")

local Input = {}

-- 玩家按下"放泡泡"时触发
Input.BombPressed = Instance.new("BindableEvent")

local MOVE_KEYS = {
    [Enum.KeyCode.W] = { 0, -1 },
    [Enum.KeyCode.Up] = { 0, -1 },
    [Enum.KeyCode.DPadUp] = { 0, -1 },
    [Enum.KeyCode.S] = { 0, 1 },
    [Enum.KeyCode.Down] = { 0, 1 },
    [Enum.KeyCode.DPadDown] = { 0, 1 },
    [Enum.KeyCode.A] = { -1, 0 },
    [Enum.KeyCode.Left] = { -1, 0 },
    [Enum.KeyCode.DPadLeft] = { -1, 0 },
    [Enum.KeyCode.D] = { 1, 0 },
    [Enum.KeyCode.Right] = { 1, 0 },
    [Enum.KeyCode.DPadRight] = { 1, 0 },
}

local BOMB_KEYS = {
    [Enum.KeyCode.Space] = true,
    [Enum.KeyCode.E] = true,
    [Enum.KeyCode.ButtonA] = true,
}

local STICK_DEADZONE = 0.3

local held = {} -- [KeyCode] = true
local stickX, stickZ = 0, 0
local touchHeld = {} -- [按钮] = { x, z }

function Input.getDirection(): (number, number)
    local x, z = 0, 0

    for keyCode in held do
        local vector = MOVE_KEYS[keyCode]
        x += vector[1]
        z += vector[2]
    end

    x += stickX
    z += stickZ

    for _, vector in touchHeld do
        x += vector[1]
        z += vector[2]
    end

    local length = math.sqrt(x * x + z * z)
    if length > 1 then
        x /= length
        z /= length
    end

    return x, z
end

---------------------------------------------------------------- 触屏

local function createTouchButton(parent: Instance, text: string, size: UDim2, position: UDim2): TextButton
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.AnchorPoint = Vector2.new(0.5, 0.5)
    button.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    button.BackgroundTransparency = 0.7
    button.Font = Enum.Font.GothamBold
    button.TextSize = 28
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Text = text
    button.AutoButtonColor = true
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.3, 0)
    corner.Parent = button

    return button
end

local function bindHold(button: TextButton, x: number, z: number)
    local function release()
        touchHeld[button] = nil
    end

    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            touchHeld[button] = { x, z }

            -- 手指滑出按钮范围再抬起时，也能正确松开
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    release()
                end
            end)
        end
    end)

    button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            release()
        end
    end)
end

local function createTouchControls(gui: ScreenGui)
    local pad = Instance.new("Frame")
    pad.Name = "DPad"
    pad.AnchorPoint = Vector2.new(0, 1)
    pad.Position = UDim2.new(0, 24, 1, -24)
    pad.Size = UDim2.fromOffset(190, 190)
    pad.BackgroundTransparency = 1
    pad.Parent = gui

    local buttonSize = UDim2.fromOffset(62, 62)
    bindHold(createTouchButton(pad, "▲", buttonSize, UDim2.fromOffset(95, 31)), 0, -1)
    bindHold(createTouchButton(pad, "▼", buttonSize, UDim2.fromOffset(95, 159)), 0, 1)
    bindHold(createTouchButton(pad, "◀", buttonSize, UDim2.fromOffset(31, 95)), -1, 0)
    bindHold(createTouchButton(pad, "▶", buttonSize, UDim2.fromOffset(159, 95)), 1, 0)

    local bomb = createTouchButton(gui, "泡泡", UDim2.fromOffset(110, 110), UDim2.new(1, -90, 1, -90))
    bomb.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
    bomb.BackgroundTransparency = 0.35
    bomb.Activated:Connect(function()
        Input.BombPressed:Fire()
    end)
end

---------------------------------------------------------------- 初始化

function Input.init(gui: ScreenGui)
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end

        if MOVE_KEYS[input.KeyCode] then
            held[input.KeyCode] = true
        elseif BOMB_KEYS[input.KeyCode] then
            Input.BombPressed:Fire()
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        -- 松开永远处理（即使按下时被聊天框等占用）
        held[input.KeyCode] = nil
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Thumbstick1 then
            local position = input.Position
            if position.Magnitude < STICK_DEADZONE then
                stickX, stickZ = 0, 0
            else
                stickX, stickZ = position.X, -position.Y
            end
        end
    end)

    -- 切走窗口时别让按键"卡住"
    UserInputService.WindowFocusReleased:Connect(function()
        table.clear(held)
        stickX, stickZ = 0, 0
    end)

    if UserInputService.TouchEnabled then
        createTouchControls(gui)
    end
end

return Input
