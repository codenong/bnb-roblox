-- src/client/InputGamepad.luau
-- Gamepad device: left thumbstick direction, D-pad movement buttons and
-- A/B/X action buttons. With a gamepad connected, Roblox auto-selects a
-- visible GUI button and routes D-pad/A presses to GUI navigation. Those
-- inputs then arrive with gameProcessedEvent = true, which the InputBegan
-- handler below deliberately ignores, so the gamepad would stop moving or
-- placing bubbles. While a round is being played the gamepad belongs to the
-- game; on the character-select screen navigation is turned back on so a
-- gamepad can still pick a card.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Gamepad = {}

local ctx = nil
local enabled = true

-- Analog thumbstick tuning. Only the stick goes through this; D-pad buttons are
-- digital edges (like keyboard keys) and bypass it. The touch joystick has its
-- own, separate tuning in InputTouch.
--
-- The game is four-way and a held direction is turned into whole cells by the
-- release glide in Movement, so a stick that chatters around one threshold for
-- 2+ ticks (33 ms) would walk a full cell. That is why every threshold below
-- comes in an on/off pair instead of a single dead zone:
--   STICK_ENGAGE         deflection that starts moving from rest.
--   STICK_RELEASE        once moving, deflection must fall below this to stop.
--                        The gap to ENGAGE is the hysteresis: noise around one
--                        threshold can no longer toggle the direction.
--   STICK_AXIS_BIAS      the other axis must beat the current one by this factor
--                        to turn a corner, so a wobbling diagonal does not flip
--                        between two directions every frame.
--   STICK_REVERSE_GUARD  seconds after the stick was last held one way during
--                        which the opposite way needs STICK_REVERSE_ENGAGE. A
--                        released stick springs back through the centre and
--                        overshoots to the other side; without this guard that
--                        overshoot reads as a deliberate reverse.
local STICK_ENGAGE = 0.40
local STICK_RELEASE = 0.28
local STICK_AXIS_BIAS = 1.15
local STICK_REVERSE_GUARD = 0.10
local STICK_REVERSE_ENGAGE = 0.70

local OPPOSITE = {
    left = "right",
    right = "left",
    up = "down",
    down = "up",
}

-- Injectable so tests can drive the time-based reverse guard deterministically.
local clock = os.clock

-- Stick state. Cleared on reset and whenever the module is enabled/disabled, so
-- a stale direction never keeps a hysteresis band open after a hand-over.
local stickDirection: string? = nil
local lastStickDirection: string? = nil
local lastStickTime = 0

local MOVE_BUTTONS = {
    [Enum.KeyCode.DPadUp] = "up",
    [Enum.KeyCode.DPadDown] = "down",
    [Enum.KeyCode.DPadLeft] = "left",
    [Enum.KeyCode.DPadRight] = "right",
}

local PLACE_BUTTONS = {
    [Enum.KeyCode.ButtonA] = true,
}

local USE_BUTTONS = {
    [Enum.KeyCode.ButtonB] = true,
    [Enum.KeyCode.ButtonX] = true,
}

local function resetStick()
    stickDirection = nil
    lastStickDirection = nil
    lastStickTime = 0
end

-- x is right-positive and y is up-positive. The game is strictly four-way, so
-- the dominant axis wins; from rest, equal diagonals deterministically pick
-- horizontal. `now` is in seconds.
local function resolveStick(x: number, y: number, now: number): string?
    local ax, ay = math.abs(x), math.abs(y)
    local magnitude = math.max(ax, ay)
    local direction: string? = nil

    local threshold = if stickDirection then STICK_RELEASE else STICK_ENGAGE
    if magnitude >= threshold then
        local horizontal
        if stickDirection == "left" or stickDirection == "right" then
            horizontal = not (ay > ax * STICK_AXIS_BIAS)
        elseif stickDirection == "up" or stickDirection == "down" then
            horizontal = ax > ay * STICK_AXIS_BIAS
        else
            horizontal = ax >= ay
        end

        if horizontal then
            direction = if x >= 0 then "right" else "left"
        else
            direction = if y >= 0 then "up" else "down"
        end

        -- A reversal is a new push, not a continuation of the old one, so it
        -- has to clear the engage threshold; right after letting go it has to
        -- be a clearly deliberate one (spring-back overshoot is not).
        if lastStickDirection ~= nil and direction == OPPOSITE[lastStickDirection] then
            local needed = if now - lastStickTime < STICK_REVERSE_GUARD then STICK_REVERSE_ENGAGE else STICK_ENGAGE
            if magnitude < needed then
                direction = nil
            end
        end
    end

    if direction ~= nil then
        lastStickDirection = direction
        lastStickTime = now
    end
    stickDirection = direction
    return direction
end

local function stickDirectionFor(position: Vector3): string?
    -- Roblox reports Thumbstick1 with +Y up, which already matches our axes.
    return resolveStick(position.X, position.Y, clock())
end

local function setGuiNavigation(on: boolean)
    pcall(function()
        GuiService.AutoSelectGuiEnabled = on
        GuiService.GuiNavigationEnabled = on
        if not on then
            GuiService.SelectedObject = nil
        end
    end)
end

function Gamepad.init(context, _gui)
    ctx = context

    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
            return
        end

        local direction = MOVE_BUTTONS[input.KeyCode]
        if direction then
            if enabled then
                ctx.setSource("key_" .. input.KeyCode.Name, direction)
            end
            return
        end

        if PLACE_BUTTONS[input.KeyCode] then
            if enabled then
                ctx.placePressed:Fire()
            end
        elseif USE_BUTTONS[input.KeyCode] then
            if enabled then
                ctx.usePressed:Fire()
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        local direction = MOVE_BUTTONS[input.KeyCode]
        if direction then
            ctx.setSource("key_" .. input.KeyCode.Name, nil)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Thumbstick1 then
            if enabled then
                local direction = stickDirectionFor(input.Position)
                local previous = ctx.getSource("gamepad_stick")
                if direction then
                    if not previous or previous ~= direction then
                        ctx.setSource("gamepad_stick", direction)
                    end
                elseif previous then
                    ctx.setSource("gamepad_stick", nil)
                end
            end
        end
    end)
end

function Gamepad.setEnabled(value: boolean)
    enabled = value
    resetStick()
    -- While a round is being played the gamepad belongs to the game; on the
    -- character-select screen (input disabled) navigation comes back so a
    -- gamepad can still pick a card.
    setGuiNavigation(not value)
end

function Gamepad.setControlsVisible(_visible: boolean)
    -- Gamepad input owns no on-screen controls.
end

function Gamepad.reset()
    -- Sources are cleared centrally by the hub; only the stick's own hysteresis
    -- state lives here.
    resetStick()
end

-- Test hook: replace the clock used by the reverse guard (seconds).
function Gamepad._setClock(fn: () -> number)
    clock = fn
end

return Gamepad
