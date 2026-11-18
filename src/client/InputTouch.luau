-- src/client/InputTouch.luau
-- Touch device: a left-hand movement layout plus the bubble and item buttons.
-- Touch.USE_DIRECTION_PAD picks the movement layout when the controls are
-- built (Touch.init): the default is a four-way ring pad in the joystick's
-- old spot; the alternative is the fixed four-way on-screen joystick. Its
-- steering is relative to an anchor that trails the thumb (joystickAnchorX/Y);
-- all distances are screen pixels measured from the anchor. The knob and base
-- are visuals only; only the first finger owns the stick.

local UserInputService = game:GetService("UserInputService")

local Touch = {}

local ctx = nil
local enabled = true

-- The left-hand touch layout. Set before Touch.init (the controls are built
-- once, when the device has a touch screen):
--   true  = the four-way ring pad (default): one touch surface steered by the
--           thumb's position, so it can slide from sector to sector.
--   false = the dragging joystick.
Touch.USE_DIRECTION_PAD = true

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
-- Tap detection: when and where the thumb landed, and whether this touch ever
-- pushed far enough to start moving.
local joystickDownClock = 0
local joystickDownX = 0
local joystickDownY = 0
local joystickEngaged = false

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

-- Tap = one step. Walking is quantised to whole cells by the release glide in
-- Movement, and at full speed a cell is only ~167 ms of travel, so a thumb that
-- rests on the stick for "a light press" (100-250 ms) lands on one cell or two
-- depending on a few milliseconds. A quick touch that never pushed past
-- TOUCH_ENGAGE is therefore not a drag at all: it is a tap on one side of the
-- base, like a D-pad button, and sends a fixed pulse that is always one cell.
--   TOUCH_TAP_MAX_SECONDS  longest contact that still counts as a tap.
--   TOUCH_TAP_MIN_OFFSET   the landing must be this far from the base centre
--                          (the base radius is 53px) to pick a side; a tap on
--                          the middle does nothing, as before.
--   TOUCH_TAP_PULSE_TICKS  commands the direction is held for. 3 ticks (50 ms
--                          at 60Hz) is past the glide's commit distance at every
--                          speed and still far short of a second cell.
local TOUCH_TAP_MAX_SECONDS = 0.20
local TOUCH_TAP_MIN_OFFSET = 14
local TOUCH_TAP_PULSE_TICKS = 3

-- Injectable so tests can fix the contact time (seconds).
local clock = os.clock

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
    joystickEngaged = false
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
        if direction then
            joystickEngaged = true
        end
        setTouchSource(direction)
    end
end

-- Which side of the base a finished touch tapped, or nil if it was not a tap.
-- Called before the joystick state is reset.
local function tapDirection(): string?
    if joystickEngaged or not joystickBase then
        return nil
    end
    if clock() - joystickDownClock > TOUCH_TAP_MAX_SECONDS then
        return nil
    end

    local centerX = joystickBase.AbsolutePosition.X + joystickBase.AbsoluteSize.X / 2
    local centerY = joystickBase.AbsolutePosition.Y + joystickBase.AbsoluteSize.Y / 2
    local ox = joystickDownX - centerX
    local oy = joystickDownY - centerY
    if ox * ox + oy * oy < TOUCH_TAP_MIN_OFFSET * TOUCH_TAP_MIN_OFFSET then
        return nil
    end

    if math.abs(ox) >= math.abs(oy) then
        return if ox >= 0 then "right" else "left"
    end
    return if oy > 0 then "down" else "up"
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

---------------------------------------------------------------- 四方向按键

-- A ring split into four sectors (up / right / down / left) around a round hub.
-- The whole ring is the touch target, so the thumb has a large area to land on,
-- and it is steered by WHERE the thumb is, not by which button it landed on:
--   * One transparent surface owns the touch. The thumb can slide from one
--     sector to the next without lifting, and keeps steering after it leaves the
--     ring, exactly like the joystick (the first finger only; the GUI gives us
--     the press, UserInputService gives us the drag and the lift).
--   * The direction is the quadrant of the thumb around the pad centre, so there
--     are no gaps between the sectors to fall into. It is digital and starts at
--     the moment of the press, like a held key.
--   * Hysteresis keeps it steady: the hub in the middle is a dead zone with an
--     engage/release pair, and switching axis needs a clear margin, the same
--     tuning idea as the joystick and the gamepad stick.
--
-- Drawing: nothing here relies on clipping or on group transparency (CanvasGroup
-- clipping/GroupTransparency did not take effect on the target runtime, and the
-- sectors were drawn as huge unclipped squares). Each sector is built from
-- 1px-thick bars computed row by row, and every bar is kept inside the ring's
-- circle by construction, so nothing can be drawn outside it. Transparency is set
-- on each bar, which is uniform because bars never overlap.
local TOUCH_PAD_SOURCE = "touch_dpad"

-- Geometry in screen px. The pad keeps the old joystick's bottom-left spot.
local PAD_SIZE = 152 -- outer diameter of the ring
local PAD_MARGIN = 24 -- from the left and bottom edges
local PAD_HIT_MARGIN = 24 -- the touch surface reaches this far past the ring
local PAD_HUB_DIAMETER = 44 -- the round hub in the middle (dead zone)
local PAD_THUMB_DIAMETER = 13
local PAD_THUMB_REACH = 8 -- how far the dot leans toward the pressed sector
local PAD_SEAM_THICKNESS = 3 -- the dark line between neighbouring sectors
local PAD_ARROW_RADIUS = 49 -- the arrow sits mid-band
local PAD_ARROW_ARM = 14 -- length of each stroke of the chevron
local PAD_ARROW_THICKNESS = 4

-- Steering, in screen px from the pad centre.
--   PAD_ENGAGE_RADIUS  from rest the thumb must be this far out to steer.
--   PAD_RELEASE_RADIUS once steering, only coming back this close stops.
--   PAD_AXIS_BIAS      to turn a corner the other axis must win by this factor.
local PAD_ENGAGE_RADIUS = 18
local PAD_RELEASE_RADIUS = 11
local PAD_AXIS_BIAS = 1.15

-- Look.
local PAD_SECTOR_IDLE_COLOR = Color3.fromRGB(16, 20, 34)
local PAD_SECTOR_IDLE_TRANSPARENCY = 0.42
local PAD_SECTOR_PRESSED_COLOR = Color3.fromRGB(62, 140, 255)
local PAD_SECTOR_PRESSED_TRANSPARENCY = 0.06
local PAD_SEAM_COLOR = Color3.fromRGB(6, 8, 16)
local PAD_SEAM_TRANSPARENCY = 0.3
local PAD_ARROW_IDLE_TRANSPARENCY = 0.35
local PAD_ARROW_PRESSED_TRANSPARENCY = 0
local PAD_HUB_COLOR = Color3.fromRGB(10, 14, 26)
local PAD_HUB_IDLE_TRANSPARENCY = 0.3
local PAD_HUB_PRESSED_TRANSPARENCY = 0.15

-- direction -> unit vector from the pad centre (y grows downward), whether its
-- bars are rows (up/down) or columns (left/right), and the chevron rotation.
local PAD_SECTORS = {
    { name = "DPadUp", direction = "up", x = 0, y = -1, rows = true, arrowRotation = 0 },
    { name = "DPadRight", direction = "right", x = 1, y = 0, rows = false, arrowRotation = 90 },
    { name = "DPadDown", direction = "down", x = 0, y = 1, rows = true, arrowRotation = 180 },
    { name = "DPadLeft", direction = "left", x = -1, y = 0, rows = false, arrowRotation = 270 },
}

local padFrame = nil -- the pad container; its Absolute* gives the centre
local padThumb = nil
local padHub = nil
local padSectors = {} -- direction -> { bars, arrows, lit, x, y }
local padTouch = nil -- the one finger that owns the pad
local padDirection = nil

-- Which way a thumb at (dx, dy) from the pad centre steers, given what it is
-- steering now. y grows downward. Pure, so the hysteresis is easy to test.
local function padDirectionFor(dx: number, dy: number, current: string?): string?
    local radius = if current then PAD_RELEASE_RADIUS else PAD_ENGAGE_RADIUS
    if dx * dx + dy * dy < radius * radius then
        return nil
    end

    local ax, ay = math.abs(dx), math.abs(dy)
    local horizontal
    if current == "left" or current == "right" then
        horizontal = not (ay > ax * PAD_AXIS_BIAS)
    elseif current == "up" or current == "down" then
        horizontal = ax > ay * PAD_AXIS_BIAS
    else
        horizontal = ax >= ay
    end

    if horizontal then
        return if dx >= 0 then "right" else "left"
    end
    return if dy > 0 then "down" else "up"
end

-- Light the sector that is held (or none) and lean the dot toward it. Only the
-- sectors whose state changes are touched: each one is a few dozen bars.
local function applyPadVisual(direction: string?)
    for sectorDirection, part in pairs(padSectors) do
        local pressed = sectorDirection == direction
        if part.lit ~= pressed then
            part.lit = pressed
            local color = if pressed then PAD_SECTOR_PRESSED_COLOR else PAD_SECTOR_IDLE_COLOR
            local transparency = if pressed then PAD_SECTOR_PRESSED_TRANSPARENCY else PAD_SECTOR_IDLE_TRANSPARENCY
            for _, bar in ipairs(part.bars) do
                bar.BackgroundColor3 = color
                bar.BackgroundTransparency = transparency
            end
            for _, arm in ipairs(part.arrows) do
                arm.BackgroundTransparency = if pressed then PAD_ARROW_PRESSED_TRANSPARENCY else PAD_ARROW_IDLE_TRANSPARENCY
            end
        end
    end
    if padHub then
        padHub.BackgroundTransparency = if direction then PAD_HUB_PRESSED_TRANSPARENCY else PAD_HUB_IDLE_TRANSPARENCY
    end
    if padThumb then
        local lean = if direction then padSectors[direction] else nil
        local half = PAD_SIZE / 2
        padThumb.Position = UDim2.fromOffset(
            half + (if lean then lean.x * PAD_THUMB_REACH else 0),
            half + (if lean then lean.y * PAD_THUMB_REACH else 0)
        )
        padThumb.BackgroundTransparency = if direction then 0.1 else 0.55
    end
end

local function setPadDirection(direction: string?)
    if direction == padDirection then
        return
    end
    padDirection = direction
    applyPadVisual(direction)
    if ctx then
        ctx.setSource(TOUCH_PAD_SOURCE, direction)
    end
end

local function updatePad(position: Vector3)
    if not padFrame then
        return
    end
    -- AbsoluteSize is only zero before the first layout pass (headless runs).
    local width = padFrame.AbsoluteSize.X
    local height = padFrame.AbsoluteSize.Y
    if width <= 0 or height <= 0 then
        width, height = PAD_SIZE, PAD_SIZE
    end
    local dx = position.X - (padFrame.AbsolutePosition.X + width / 2)
    local dy = position.Y - (padFrame.AbsolutePosition.Y + height / 2)
    setPadDirection(padDirectionFor(dx, dy, padDirection))
end

local function resetDirectionPad()
    padTouch = nil
    padDirection = nil
    applyPadVisual(nil)
    if ctx then
        ctx.setSource(TOUCH_PAD_SOURCE, nil)
    end
end

local function makeCircle(instance: GuiObject)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = instance
end

local function addStroke(instance: GuiObject, transparency: number, thickness: number)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = transparency
    stroke.Thickness = thickness
    stroke.Parent = instance
end

-- One sector as 1px bars. A sector is the part of the ring where the thumb is
-- nearer its axis than either neighbouring axis, i.e. along that axis `d` out
-- from the centre it is |across| <= d wide. For each 1px slice [t, t+1] along the
-- axis the bar spans from the hub's edge (or the middle) out to the diagonal or
-- the circle, whichever comes first. The circle limit uses the slice's far edge,
-- so a bar's corners are never outside the ring. Up/down sectors are rows, left/
-- right sectors are columns.
local function buildSectorBars(parent: Instance, sector, half: number, radius: number, hubRadius: number): { Frame }
    local bars = {}
    local function addBar(x: number, y: number, width: number, height: number)
        local bar = Instance.new("Frame")
        bar.Name = sector.name .. "Bar" .. (#bars + 1)
        bar.Position = UDim2.fromOffset(x, y)
        bar.Size = UDim2.fromOffset(width, height)
        bar.BackgroundColor3 = PAD_SECTOR_IDLE_COLOR
        bar.BackgroundTransparency = PAD_SECTOR_IDLE_TRANSPARENCY
        bar.BorderSizePixel = 0
        bar.ZIndex = 50003
        bar.Parent = parent
        bars[#bars + 1] = bar
    end

    local sign = if sector.rows then sector.y else sector.x
    for slice = 0, math.floor(radius) - 1 do
        local near, far = slice, slice + 1
        local center = slice + 0.5
        local circleHalf = math.sqrt(math.max(radius * radius - far * far, 0))
        local reach = math.min(center, circleHalf)
        -- Overlap the hub by a pixel (it is drawn above) so no hairline shows.
        local hubHalf = if near < hubRadius then math.sqrt(math.max(hubRadius * hubRadius - near * near, 0)) else 0
        local inner = math.max(hubHalf - 1, 0)
        if reach > inner then
            -- `spans` are the pieces along the slice: one when it reaches the
            -- middle, two when the hub splits it.
            local spans = if inner <= 0 then { { -reach, reach } } else { { -reach, -inner }, { inner, reach } }
            for _, span in ipairs(spans) do
                local from, to = span[1], span[2]
                -- Along the axis the slice occupies [near, far] on the sector's side.
                local axisStart = if sign > 0 then half + near else half - far
                if sector.rows then
                    addBar(half + from, axisStart, to - from, 1)
                else
                    addBar(axisStart, half + from, 1, to - from)
                end
            end
        end
    end
    return bars
end

-- An arrow like a chevron: two rounded strokes meeting at a tip, drawn with
-- frames so it never depends on a font having the glyph. `rotation` turns the
-- "up" chevron toward the sector (0 up, 90 right, 180 down, 270 left).
local function buildChevron(parent: Instance, name: string, centerX: number, centerY: number, rotation: number): { Frame }
    local arms = {}
    local radians = math.rad(rotation)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local reach = PAD_ARROW_ARM / 2 * math.sqrt(0.5)
    -- The up chevron: the tip is `reach` above the middle and each stroke leans
    -- 45° back from it, so the whole arrow is centred on (centerX, centerY).
    for index, side in ipairs({ -1, 1 }) do
        local localX = side * reach
        local localY = 0
        local arm = Instance.new("Frame")
        arm.Name = name .. "Arrow" .. index
        arm.AnchorPoint = Vector2.new(0.5, 0.5)
        arm.Position = UDim2.fromOffset(
            centerX + localX * cosine - localY * sine,
            centerY + localX * sine + localY * cosine
        )
        arm.Size = UDim2.fromOffset(PAD_ARROW_ARM, PAD_ARROW_THICKNESS)
        arm.Rotation = rotation + side * 45
        arm.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        arm.BackgroundTransparency = PAD_ARROW_IDLE_TRANSPARENCY
        arm.BorderSizePixel = 0
        arm.ZIndex = 50005
        arm.Parent = parent
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.5, 0)
        corner.Parent = arm
        arms[index] = arm
    end
    return arms
end

local function buildDirectionPad(frame: Frame)
    local half = PAD_SIZE / 2
    local hubRadius = PAD_HUB_DIAMETER / 2

    local pad = Instance.new("Frame")
    pad.Name = "DPad"
    pad.AnchorPoint = Vector2.new(0.5, 1)
    pad.Position = UDim2.new(0, PAD_MARGIN + half, 1, -PAD_MARGIN)
    pad.Size = UDim2.fromOffset(PAD_SIZE, PAD_SIZE)
    pad.BackgroundTransparency = 1
    pad.BorderSizePixel = 0
    pad.ZIndex = 50001
    pad.Parent = frame
    padFrame = pad

    for _, sector in ipairs(PAD_SECTORS) do
        local bars = buildSectorBars(pad, sector, half, half, hubRadius)
        local arrows = buildChevron(
            pad,
            sector.name,
            half + sector.x * PAD_ARROW_RADIUS,
            half + sector.y * PAD_ARROW_RADIUS,
            sector.arrowRotation
        )
        padSectors[sector.direction] = { bars = bars, arrows = arrows, lit = false, x = sector.x, y = sector.y }
    end

    -- Dark seams along the two diagonals separate the sectors and hide the
    -- stair-steps where bars of neighbouring sectors meet. Each seam is as long
    -- as the ring is wide, so it ends on the circle.
    for index, rotation in ipairs({ 45, -45 }) do
        local seam = Instance.new("Frame")
        seam.Name = "DPadSeam" .. index
        seam.AnchorPoint = Vector2.new(0.5, 0.5)
        seam.Position = UDim2.fromOffset(half, half)
        seam.Size = UDim2.fromOffset(PAD_SIZE, PAD_SEAM_THICKNESS)
        seam.Rotation = rotation
        seam.BackgroundColor3 = PAD_SEAM_COLOR
        seam.BackgroundTransparency = PAD_SEAM_TRANSPARENCY
        seam.BorderSizePixel = 0
        seam.ZIndex = 50004
        seam.Parent = pad
    end

    -- A thin outline around the ring so it reads against any background.
    local rim = Instance.new("Frame")
    rim.Name = "DPadRim"
    rim.Size = UDim2.fromScale(1, 1)
    rim.BackgroundTransparency = 1
    rim.BorderSizePixel = 0
    rim.ZIndex = 50004
    rim.Parent = pad
    makeCircle(rim)
    addStroke(rim, 0.72, 1.5)

    -- The hub: a round cap in the middle. It is the steering dead zone.
    local hub = Instance.new("Frame")
    hub.Name = "DPadHub"
    hub.AnchorPoint = Vector2.new(0.5, 0.5)
    hub.Position = UDim2.fromOffset(half, half)
    hub.Size = UDim2.fromOffset(PAD_HUB_DIAMETER, PAD_HUB_DIAMETER)
    hub.BackgroundColor3 = PAD_HUB_COLOR
    hub.BackgroundTransparency = PAD_HUB_IDLE_TRANSPARENCY
    hub.BorderSizePixel = 0
    hub.ZIndex = 50006
    hub.Parent = pad
    makeCircle(hub)
    addStroke(hub, 0.6, 1.2)
    padHub = hub

    -- The dot in the hub leans toward whatever is held.
    local thumb = Instance.new("Frame")
    thumb.Name = "DPadThumb"
    thumb.AnchorPoint = Vector2.new(0.5, 0.5)
    thumb.Position = UDim2.fromOffset(half, half)
    thumb.Size = UDim2.fromOffset(PAD_THUMB_DIAMETER, PAD_THUMB_DIAMETER)
    thumb.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    thumb.BackgroundTransparency = 0.55
    thumb.BorderSizePixel = 0
    thumb.ZIndex = 50007
    thumb.Parent = pad
    makeCircle(thumb)
    padThumb = thumb

    -- The one interactive object. It reaches PAD_HIT_MARGIN past the ring so a
    -- thumb landing near the edge still counts. Only the press comes from the
    -- GUI; the drag and the lift are tracked through UserInputService for this
    -- exact InputObject, so the pad keeps steering after the thumb leaves it.
    local surface = Instance.new("TextButton")
    surface.Name = "DPadSurface"
    surface.Text = ""
    surface.TextTransparency = 1
    surface.BackgroundTransparency = 1
    surface.BorderSizePixel = 0
    surface.AutoButtonColor = false
    surface.Selectable = false
    surface.Position = UDim2.fromOffset(-PAD_HIT_MARGIN, -PAD_HIT_MARGIN)
    surface.Size = UDim2.fromOffset(PAD_SIZE + 2 * PAD_HIT_MARGIN, PAD_SIZE + 2 * PAD_HIT_MARGIN)
    surface.ZIndex = 50010
    surface.Parent = pad

    surface.InputBegan:Connect(function(input)
        if not enabled or padTouch ~= nil then
            return
        end
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            padTouch = input
            updatePad(input.Position)
        end
    end)
end

local function buildJoystick(frame: Frame)
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
            joystickDownClock = clock()
            joystickDownX = input.Position.X
            joystickDownY = input.Position.Y
            joystickEngaged = false
            updateJoystick(input.Position)
        end
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

    if Touch.USE_DIRECTION_PAD then
        buildDirectionPad(frame)
    else
        buildJoystick(frame)
    end

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
            local tap = tapDirection()
            resetJoystick()
            if tap then
                ctx.pulseSource(TOUCH_STICK_SOURCE, tap, TOUCH_TAP_PULSE_TICKS)
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input == padTouch then
            resetDirectionPad()
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if padTouch
            and (input == padTouch
                or (padTouch.UserInputType == Enum.UserInputType.MouseButton1
                    and input.UserInputType == Enum.UserInputType.MouseMovement))
        then
            updatePad(input.Position)
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
        resetDirectionPad()
    end
end

function Touch.setControlsVisible(visible: boolean)
    if controls then
        controls.Visible = visible
    end
    if not visible then
        resetJoystick()
        resetDirectionPad()
    end
end

function Touch.reset()
    resetJoystick()
    resetDirectionPad()
end

-- Test hook: replace the clock used to time a tap (seconds).
function Touch._setClock(fn: () -> number)
    clock = fn
end

return Touch
