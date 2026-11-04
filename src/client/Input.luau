-- src/client/Input.luau
-- Keyboard, gamepad and touch input. Direction order is oldest press first,
-- newest press last; Game treats the last entry as the most recent direction.

local UserInputService = game:GetService("UserInputService")

local Input = {}

Input.placePressed = Instance.new("BindableEvent")
Input.usePressed = Instance.new("BindableEvent")

local enabled = true
local controls = nil

local MOVE_KEYS = {
    [Enum.KeyCode.W] = "up",
    [Enum.KeyCode.Up] = "up",
    [Enum.KeyCode.DPadUp] = "up",
    [Enum.KeyCode.S] = "down",
    [Enum.KeyCode.Down] = "down",
    [Enum.KeyCode.DPadDown] = "down",
    [Enum.KeyCode.A] = "left",
    [Enum.KeyCode.Left] = "left",
    [Enum.KeyCode.DPadLeft] = "left",
    [Enum.KeyCode.D] = "right",
    [Enum.KeyCode.Right] = "right",
    [Enum.KeyCode.DPadRight] = "right",
}

local PLACE_KEYS = {
    [Enum.KeyCode.Space] = true,
    [Enum.KeyCode.ButtonA] = true,
}

local USE_KEYS = {
    [Enum.KeyCode.LeftControl] = true,
    [Enum.KeyCode.RightControl] = true,
    [Enum.KeyCode.LeftShift] = true,
    [Enum.KeyCode.RightShift] = true,
    [Enum.KeyCode.E] = true,
    [Enum.KeyCode.ButtonB] = true,
    [Enum.KeyCode.ButtonX] = true,
}

local sources = {}
local sequence = 0

local function setSource(source: string, direction: string?)
    if direction then
        sequence += 1
        sources[source] = { direction = direction, order = sequence }
    else
        sources[source] = nil
    end
end

local function clearSources()
    sources = {}
end

function Input.getDirs(): { string }
    local ordered = {}
    for _, source in pairs(sources) do
        table.insert(ordered, source)
    end
    table.sort(ordered, function(a, b)
        return a.order < b.order
    end)

    local dirs = {}
    local seen = {}
    for _, source in ipairs(ordered) do
        if not seen[source.direction] then
            seen[source.direction] = true
            table.insert(dirs, source.direction)
        end
    end
    return dirs
end

function Input.setEnabled(value: boolean)
    enabled = value
    if not enabled then
        clearSources()
    end
end

function Input.setControlsVisible(visible: boolean)
    if controls then
        controls.Visible = visible
    end
end

local function stickDirection(position: Vector3): string?
    local x = position.X
    local y = -position.Y
    if math.abs(x) >= math.abs(y) then
        if x > 0.35 then
            return "right"
        elseif x < -0.35 then
            return "left"
        end
    else
        if y > 0.35 then
            return "down"
        elseif y < -0.35 then
            return "up"
        end
    end
    return nil
end

---------------------------------------------------------------- 触屏按键

local function makeButton(parent: Instance, text: string, size: number, position: UDim2): TextButton
    local button = Instance.new("TextButton")
    button.Name = text
    button.AnchorPoint = Vector2.new(0.5, 0.5)
    button.Position = position
    button.Size = UDim2.fromOffset(size, size)
    button.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    button.BackgroundTransparency = 0.72
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Font = Enum.Font.GothamBold
    button.Text = text
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.TextSize = math.floor(size * 0.4)
    button.TextTransparency = 0.05
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.55
    stroke.Thickness = 1.5
    stroke.Parent = button

    return button
end

local function bindTouchHold(button: TextButton, direction: string)
    local sourceName = "touch_" .. button.Name .. "_" .. tostring(button)
    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            if enabled then
                setSource(sourceName, direction)
            end
        end
    end)
    button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            setSource(sourceName, nil)
        end
    end)
    button.MouseLeave:Connect(function()
        setSource(sourceName, nil)
    end)
end

local function createTouchControls(gui: ScreenGui)
    local frame = Instance.new("Frame")
    frame.Name = "TouchControls"
    frame.BackgroundTransparency = 1
    frame.Size = UDim2.fromScale(1, 1)
    frame.ZIndex = 50000
    frame.Visible = false
    frame.Parent = gui
    controls = frame

    local padSize = 190
    local dx, dy = 24 + padSize / 2, -24 - padSize / 2
    local pad = Instance.new("Frame")
    pad.Name = "DPad"
    pad.AnchorPoint = Vector2.new(0, 1)
    pad.Position = UDim2.new(0, dx - padSize / 2, 1, dy + padSize / 2)
    pad.Size = UDim2.fromOffset(padSize, padSize)
    pad.BackgroundTransparency = 1
    pad.ZIndex = 50001
    pad.Parent = frame

    local buttonSize = 58
    local up = makeButton(pad, "▲", buttonSize, UDim2.fromOffset(padSize / 2, 29))
    local down = makeButton(pad, "▼", buttonSize, UDim2.fromOffset(padSize / 2, padSize - 29))
    local left = makeButton(pad, "◀", buttonSize, UDim2.fromOffset(29, padSize / 2))
    local right = makeButton(pad, "▶", buttonSize, UDim2.fromOffset(padSize - 29, padSize / 2))
    bindTouchHold(up, "up")
    bindTouchHold(down, "down")
    bindTouchHold(left, "left")
    bindTouchHold(right, "right")

    local bubble = makeButton(frame, "泡泡", 88, UDim2.new(1, -82, 1, -86))
    bubble.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
    bubble.TextSize = 24
    bubble.ZIndex = 50002
    bubble.Activated:Connect(function()
        if enabled then
            Input.placePressed:Fire()
        end
    end)

    local item = makeButton(frame, "道具", 64, UDim2.new(1, -154, 1, -154))
    item.BackgroundColor3 = Color3.fromRGB(240, 170, 90)
    item.TextSize = 20
    item.ZIndex = 50002
    item.Activated:Connect(function()
        if enabled then
            Input.usePressed:Fire()
        end
    end)
end

---------------------------------------------------------------- 初始化

function Input.init(gui: ScreenGui)
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end

        local direction = MOVE_KEYS[input.KeyCode]
        if direction then
            if enabled then
                setSource("key_" .. input.KeyCode.Name, direction)
            end
            return
        end

        if PLACE_KEYS[input.KeyCode] then
            if enabled then
                Input.placePressed:Fire()
            end
        elseif USE_KEYS[input.KeyCode] then
            if enabled then
                Input.usePressed:Fire()
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        local direction = MOVE_KEYS[input.KeyCode]
        if direction then
            setSource("key_" .. input.KeyCode.Name, nil)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Thumbstick1 then
            if enabled then
                local direction = stickDirection(input.Position)
                local previous = sources.gamepad_stick
                if direction then
                    if not previous or previous.direction ~= direction then
                        setSource("gamepad_stick", direction)
                    end
                elseif previous then
                    setSource("gamepad_stick", nil)
                end
            end
        end
    end)

    UserInputService.WindowFocusReleased:Connect(function()
        clearSources()
    end)

    if UserInputService.TouchEnabled then
        createTouchControls(gui)
    end
end

return Input
