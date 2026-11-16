-- src/client/InputGamepad.luau
-- Gamepad device: left thumbstick direction, D-pad movement buttons, R1 to
-- place a bubble and R2 to use an item. Roblox's core scripts claim the face
-- buttons: ButtonA is jump (and a menu click while the gamepad is in GUI
-- navigation mode), so A/B/X presses used to reach InputBegan with
-- gameProcessedEvent = true and were dropped here -- on a real controller the
-- buttons did nothing. The action keys are therefore claimed through
-- ContextActionService, like the arrow keys in InputKeyboard: a high-priority
-- binding gets the press before the core scripts can and sinks it. While a
-- round is on, A is claimed and sunk as well so the default jump never fires;
-- on the character-select screen the claim is released so A activates the
-- highlighted card. Navigation itself is toggled as before: during a round the
-- gamepad belongs to the game, on the character-select screen it is handed
-- back so a gamepad can still pick a card.

local ContextActionService = game:GetService("ContextActionService")
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
    [Enum.KeyCode.ButtonR1] = true,
}

local USE_BUTTONS = {
    [Enum.KeyCode.ButtonR2] = true,
}

---------------------------------------------------------------- 动作键

-- R1 and R2 are claimed the way InputKeyboard claims the arrow keys: a
-- high-priority ContextActionService binding that sinks the press. The plain
-- InputBegan path cannot serve face buttons -- Roblox's core scripts bind
-- ButtonA to jump and treat the face buttons as menu keys while the gamepad is
-- in GUI navigation mode, and anything they consume arrives at InputBegan with
-- gameProcessedEvent = true, which the movement handler below (deliberately)
-- ignores. The binding gets the input first, so the game keys always fire.
local ACTION_KEYS_ACTION = "BnBGamepadActions"

local function onActionKey(_actionName: string, state: Enum.UserInputState, input: InputObject)
    -- One pulse per press: placePressed/usePressed are fire-and-forget signals,
    -- not held sources, so End and Cancel have nothing to clean up.
    if state == Enum.UserInputState.Begin and enabled then
        if PLACE_BUTTONS[input.KeyCode] then
            ctx.placePressed:Fire()
        elseif USE_BUTTONS[input.KeyCode] then
            ctx.usePressed:Fire()
        end
    end
    return Enum.ContextActionResult.Sink
end

local function claimActionKeys()
    local ok, err = pcall(function()
        ContextActionService:BindActionAtPriority(
            ACTION_KEYS_ACTION,
            onActionKey,
            false,
            Enum.ContextActionPriority.High.Value,
            Enum.KeyCode.ButtonR1,
            Enum.KeyCode.ButtonR2
        )
    end)
    if not ok then
        warn("[BnB] could not claim the gamepad action keys: " .. tostring(err))
    end
end

-- Roblox binds ButtonA to jump and a round of this game has no use for
-- jumping. While the round is on, A is claimed and sunk so the character stays
-- on the ground; on the character-select screen the claim is released and A
-- goes back to activating the highlighted card (and B/X are never claimed at
-- all: they are deprecated and nothing reads them).
local JUMP_BLOCK_ACTION = "BnBGamepadJumpBlock"

local function sinkButtonA(_actionName: string, _state: Enum.UserInputState, _input: InputObject)
    return Enum.ContextActionResult.Sink
end

local function claimJumpBlock()
    local ok, err = pcall(function()
        ContextActionService:BindActionAtPriority(
            JUMP_BLOCK_ACTION,
            sinkButtonA,
            false,
            Enum.ContextActionPriority.High.Value,
            Enum.KeyCode.ButtonA
        )
    end)
    if not ok then
        warn("[BnB] could not claim ButtonA: " .. tostring(err))
    end
end

local function releaseJumpBlock()
    pcall(function()
        ContextActionService:UnbindAction(JUMP_BLOCK_ACTION)
    end)
end

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
    claimActionKeys()

    UserInputService.InputBegan:Connect(function(input, processed)
        local direction = MOVE_BUTTONS[input.KeyCode]
        if processed then
            return
        end

        if direction then
            if enabled then
                ctx.setSource("key_" .. input.KeyCode.Name, direction)
            end
            return
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
    -- gamepad can still pick a card, and A goes back to activating it.
    setGuiNavigation(not value)
    if value then
        claimJumpBlock()
    else
        releaseJumpBlock()
    end
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
