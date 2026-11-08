-- src/client/Input.luau
-- Keyboard, gamepad and touch joystick input. Direction order is oldest press
-- first, newest press last; Game treats the last entry as the most recent
-- direction.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
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

-- The touch joystick owns one source. Keeping it separate from keyboard and
-- gamepad sources means releasing it never clears a direction still held on
-- another input device.
local TOUCH_STICK_SOURCE = "touch_stick"
local joystickBase = nil
local joystickKnob = nil
local joystickTouch = nil
local joystickDirection = nil
local joystickTravel = 54

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

local function resetJoystick()
    joystickTouch = nil
    joystickDirection = nil
    setSource(TOUCH_STICK_SOURCE, nil)
    if joystickKnob then
        joystickKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
        joystickKnob.BackgroundTransparency = 0.18
    end
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

-- With a gamepad connected, Roblox auto-selects a visible GUI button and routes
-- D-pad/A presses to GUI navigation. Those inputs then arrive with
-- gameProcessedEvent = true, which InputBegan below deliberately ignores, so the
-- gamepad would stop moving or placing bubbles. While a round is being played the
-- gamepad belongs to the game; on the character-select screen navigation is
-- turned back on so a gamepad can still pick a card.
local function setGuiNavigation(on: boolean)
    pcall(function()
        GuiService.AutoSelectGuiEnabled = on
        GuiService.GuiNavigationEnabled = on
        if not on then
            GuiService.SelectedObject = nil
        end
    end)
end

function Input.setEnabled(value: boolean)
    enabled = value
    setGuiNavigation(not value)
    if not enabled then
        clearSources()
        resetJoystick()
    end
end

function Input.setControlsVisible(visible: boolean)
    if controls then
        controls.Visible = visible
    end
    if not visible then
        resetJoystick()
    end
end

local STICK_THRESHOLD = 0.35

-- x is right-positive and y is up-positive. The game is strictly four-way, so
-- the dominant axis wins; equal diagonals deterministically pick horizontal.
local function directionFromAxes(x: number, y: number): string?
    if math.abs(x) >= math.abs(y) then
        if x > STICK_THRESHOLD then
            return "right"
        elseif x < -STICK_THRESHOLD then
            return "left"
        end
    else
        if y > STICK_THRESHOLD then
            return "up"
        elseif y < -STICK_THRESHOLD then
            return "down"
        end
    end
    return nil
end

local function stickDirection(position: Vector3): string?
    -- Roblox reports Thumbstick1 with +Y up, which already matches our axes.
    return directionFromAxes(position.X, position.Y)
end

---------------------------------------------------------------- 方向键

-- Roblox's default camera script binds the Left and Right arrow keys (and I/O)
-- through ContextActionService to rotate the camera. Those presses reach
-- UserInputService.InputBegan already marked as processed, which the handler in
-- Input.init skips, so Left/Right did nothing while Up/Down (unclaimed) worked.
-- The arrow keys are therefore claimed here with a higher-priority binding that
-- sinks them; the camera never sees them and the game reads them directly.
-- Typing in a TextBox still works: ContextActionService does not fire while one
-- has focus.
local ARROW_ACTION = "BnBArrowKeys"

local function onArrowKey(_actionName: string, state: Enum.UserInputState, input: InputObject)
    local direction = MOVE_KEYS[input.KeyCode]
    if not direction then
        return Enum.ContextActionResult.Pass
    end

    local source = "key_" .. input.KeyCode.Name
    if state == Enum.UserInputState.Begin then
        if enabled then
            setSource(source, direction)
        end
    else
        -- End, or Cancel when another binding takes the key away.
        setSource(source, nil)
    end
    return Enum.ContextActionResult.Sink
end

local function claimArrowKeys()
    local ok, err = pcall(function()
        ContextActionService:BindActionAtPriority(
            ARROW_ACTION,
            onArrowKey,
            false,
            Enum.ContextActionPriority.High.Value,
            Enum.KeyCode.Left,
            Enum.KeyCode.Right,
            Enum.KeyCode.Up,
            Enum.KeyCode.Down
        )
    end)
    if not ok then
        -- InputBegan below still handles whatever the engine leaves unprocessed.
        warn("[BnB] could not claim the arrow keys: " .. tostring(err))
    end
end

---------------------------------------------------------------- 触屏摇杆

local function updateJoystick(position: Vector3)
    if not joystickBase then
        return
    end

    local centerX = joystickBase.AbsolutePosition.X + joystickBase.AbsoluteSize.X / 2
    local centerY = joystickBase.AbsolutePosition.Y + joystickBase.AbsoluteSize.Y / 2
    local dx = position.X - centerX
    local dy = position.Y - centerY
    local distance = math.sqrt(dx * dx + dy * dy)
    local travel = math.max(joystickTravel, 1)
    if distance > travel then
        local scale = travel / distance
        dx *= scale
        dy *= scale
    end

    if joystickKnob then
        joystickKnob.Position = UDim2.new(0.5, dx, 0.5, dy)
        joystickKnob.BackgroundTransparency = 0.04
    end

    -- Screen Y grows downward; directionFromAxes expects up-positive Y.
    local direction = directionFromAxes(dx / travel, -dy / travel)
    if direction ~= joystickDirection then
        joystickDirection = direction
        setSource(TOUCH_STICK_SOURCE, direction)
    end
end

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

local function createTouchControls(gui: ScreenGui)
    local frame = Instance.new("Frame")
    frame.Name = "TouchControls"
    frame.BackgroundTransparency = 1
    frame.Size = UDim2.fromScale(1, 1)
    frame.ZIndex = 50000
    frame.Visible = false
    frame.Parent = gui
    controls = frame

    local baseSize = 180
    local knobSize = 64
    local margin = 24

    local base = Instance.new("Frame")
    base.Name = "Joystick"
    base.AnchorPoint = Vector2.new(0.5, 1)
    base.Position = UDim2.new(0, margin + baseSize / 2, 1, -margin)
    base.Size = UDim2.fromOffset(baseSize, baseSize)
    base.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    base.BackgroundTransparency = 0.82
    base.BorderSizePixel = 0
    base.ZIndex = 50001
    base.Parent = frame
    joystickBase = base

    local baseCorner = Instance.new("UICorner")
    baseCorner.CornerRadius = UDim.new(0.5, 0)
    baseCorner.Parent = base

    local baseStroke = Instance.new("UIStroke")
    baseStroke.Color = Color3.fromRGB(255, 255, 255)
    baseStroke.Transparency = 0.55
    baseStroke.Thickness = 1.5
    baseStroke.Parent = base

    local knob = Instance.new("Frame")
    knob.Name = "JoystickKnob"
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0.5, 0, 0.5, 0)
    knob.Size = UDim2.fromOffset(knobSize, knobSize)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BackgroundTransparency = 0.18
    knob.BorderSizePixel = 0
    knob.ZIndex = 50003
    knob.Parent = base
    joystickKnob = knob

    local knobCorner = Instance.new("UICorner")
    knobCorner.CornerRadius = UDim.new(0.5, 0)
    knobCorner.Parent = knob

    local knobStroke = Instance.new("UIStroke")
    knobStroke.Color = Color3.fromRGB(255, 255, 255)
    knobStroke.Transparency = 0.25
    knobStroke.Thickness = 1.5
    knobStroke.Parent = knob

    -- The knob and base are visuals only. This transparent button sits above
    -- them and owns the touch, so pressing the knob itself starts the stick.
    local surface = Instance.new("TextButton")
    surface.Name = "JoystickSurface"
    surface.Text = ""
    surface.TextTransparency = 1
    surface.BackgroundTransparency = 1
    surface.BorderSizePixel = 0
    surface.AutoButtonColor = false
    surface.Selectable = false
    surface.Size = UDim2.fromScale(1, 1)
    surface.ZIndex = 50004
    surface.Parent = base

    joystickTravel = baseSize / 2 - knobSize / 2 - 4

    -- Only the initial press comes from the GUI. Drag and release are tracked
    -- through UserInputService for this exact InputObject, so the stick keeps
    -- moving even when the finger leaves the base or goes past its edge.
    surface.InputBegan:Connect(function(input)
        if not enabled or joystickTouch ~= nil then
            return
        end
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            joystickTouch = input
            updateJoystick(input.Position)
        end
    end)

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
    claimArrowKeys()

    UserInputService.InputBegan:Connect(function(input, processed)
        local direction = MOVE_KEYS[input.KeyCode]
        if processed then
            return
        end

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
        if input == joystickTouch then
            resetJoystick()
        end
        local direction = MOVE_KEYS[input.KeyCode]
        if direction then
            setSource("key_" .. input.KeyCode.Name, nil)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if joystickTouch
            and (input == joystickTouch
                or (joystickTouch.UserInputType == Enum.UserInputType.MouseButton1
                    and input.UserInputType == Enum.UserInputType.MouseMovement))
        then
            updateJoystick(input.Position)
        end

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
        resetJoystick()
    end)

    if UserInputService.TouchEnabled then
        createTouchControls(gui)
    end
end

return Input
