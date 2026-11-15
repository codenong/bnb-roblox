-- src/client/InputTouch.luau
-- Touch device: a fixed four-way on-screen joystick plus the bubble and item
-- buttons. Touch steering is relative to an anchor that trails the thumb
-- (joystickAnchorX/Y); all distances are screen pixels measured from the
-- anchor. The knob and base are visuals only; only the first finger owns the
-- stick.

local UserInputService = game:GetService("UserInputService")

local Touch = {}

local ctx = nil
local enabled = true

local controls = nil
local joystickBase = nil
local joystickKnob = nil
local joystickTouch = nil
local joystickDirection = nil
local joystickTravel = 54
-- The stick is relative: its origin is where the thumb landed, and the origin
-- is dragged along whenever the thumb gets further than TOUCH_LEASH from it.
-- Only the picture of the base stays put.
local joystickAnchorX = nil
local joystickAnchorY = nil

-- The touch joystick owns one source. Keeping it separate from keyboard and
-- gamepad sources means releasing it never clears a direction still held on
-- another input device.
local TOUCH_STICK_SOURCE = "touch_stick"

---------------------------------------------------------------- 触屏摇杆

--   TOUCH_ENGAGE   a resting stick starts moving only after this much push, so
--                  landing the thumb or a small tremor never walks the player.
--   TOUCH_RELEASE  once moving, the stick only stops (or reverses) below this
--                  much push; the gap to TOUCH_ENGAGE is the hysteresis.
--   TOUCH_LEASH    the anchor follows the thumb beyond this distance, so going
--                  back the other way costs about LEASH + ENGAGE (11px) of
--                  thumb travel no matter how far the thumb had overshot the
--                  base: the sweep passes through "stopped" and restarts.
--   TOUCH_AXIS_BIAS the other axis must beat the current one by this factor
--                  before the stick turns a corner; kills diagonal flicker.
--                  Turning a corner needs about LEASH x BIAS (7px) of thumb
--                  travel across the held axis.
local TOUCH_ENGAGE = 5
local TOUCH_RELEASE = 2.5
local TOUCH_LEASH = 6
local TOUCH_AXIS_BIAS = 1.15

local function setTouchSource(direction: string?)
    if ctx then
        ctx.setSource(TOUCH_STICK_SOURCE, direction)
    end
end

local function resetJoystick()
    joystickTouch = nil
    joystickDirection = nil
    joystickAnchorX = nil
    joystickAnchorY = nil
    setTouchSource(nil)
    if joystickKnob then
        joystickKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
        joystickKnob.BackgroundTransparency = 0.18
    end
end

-- rx/ry are screen-space offsets from the anchor (y grows downward).
local function touchDirection(rx: number, ry: number, current: string?): string?
    local threshold = if current then TOUCH_RELEASE else TOUCH_ENGAGE
    if rx * rx + ry * ry < threshold * threshold then
        return nil
    end

    local ax, ay = math.abs(rx), math.abs(ry)
    local horizontal
    if current == "left" or current == "right" then
        horizontal = not (ay > ax * TOUCH_AXIS_BIAS)
    elseif current == "up" or current == "down" then
        horizontal = ax > ay * TOUCH_AXIS_BIAS
    else
        horizontal = ax >= ay
    end

    if horizontal then
        return if rx >= 0 then "right" else "left"
    end
    return if ry > 0 then "down" else "up"
end

local function updateJoystick(position: Vector3)
    if not joystickBase then
        return
    end

    if joystickAnchorX == nil or joystickAnchorY == nil then
        joystickAnchorX = position.X
        joystickAnchorY = position.Y
    end

    local rx = position.X - joystickAnchorX
    local ry = position.Y - joystickAnchorY
    local distance = math.sqrt(rx * rx + ry * ry)
    if distance > TOUCH_LEASH then
        -- Drag the anchor along so the thumb sits exactly LEASH away from it.
        local pull = (distance - TOUCH_LEASH) / distance
        joystickAnchorX += rx * pull
        joystickAnchorY += ry * pull
        rx = position.X - joystickAnchorX
        ry = position.Y - joystickAnchorY
    end

    if joystickKnob then
        -- The knob shows the push relative to the anchor, scaled so a full
        -- LEASH of push is a full knob travel.
        local scale = math.max(joystickTravel, 1) / TOUCH_LEASH
        joystickKnob.Position = UDim2.new(0.5, rx * scale, 0.5, ry * scale)
        joystickKnob.BackgroundTransparency = 0.04
    end

    local direction = touchDirection(rx, ry, joystickDirection)
    if direction ~= joystickDirection then
        joystickDirection = direction
        setTouchSource(direction)
    end
end

---------------------------------------------------------------- 摇杆 UI

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

    -- Sized for a thumb: a 106px base with a 40px cap keeps the whole rocking
    -- motion inside roughly a 29px radius, which is the comfortable arc of a
    -- resting thumb instead of a full swipe across the lower screen.
    local baseSize = 106
    local knobSize = 40
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
            ctx.placePressed:Fire()
        end
    end)

    local item = makeButton(frame, "道具", 64, UDim2.new(1, -154, 1, -154))
    item.BackgroundColor3 = Color3.fromRGB(240, 170, 90)
    item.TextSize = 20
    item.ZIndex = 50002
    item.Activated:Connect(function()
        if enabled then
            ctx.usePressed:Fire()
        end
    end)
end

---------------------------------------------------------------- 初始化

function Touch.init(context, gui)
    ctx = context

    UserInputService.InputEnded:Connect(function(input)
        if input == joystickTouch then
            resetJoystick()
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
    end)

    if UserInputService.TouchEnabled then
        createTouchControls(gui)
    end
end

function Touch.setEnabled(value: boolean)
    enabled = value
    if not enabled then
        resetJoystick()
    end
end

function Touch.setControlsVisible(visible: boolean)
    if controls then
        controls.Visible = visible
    end
    if not visible then
        resetJoystick()
    end
end

function Touch.reset()
    resetJoystick()
end

return Touch
