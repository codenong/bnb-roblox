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

-- Physical gamepad dead zone. The touch joystick has its own, smaller radial
-- dead zone in InputTouch; do not lower this one just because a thumb needs
-- less travel.
local STICK_THRESHOLD = 0.35

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
                local direction = stickDirection(input.Position)
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
    -- While a round is being played the gamepad belongs to the game; on the
    -- character-select screen (input disabled) navigation comes back so a
    -- gamepad can still pick a card.
    setGuiNavigation(not value)
end

function Gamepad.setControlsVisible(_visible: boolean)
    -- Gamepad input owns no on-screen controls.
end

function Gamepad.reset()
    -- Sources are cleared centrally by the hub; nothing device-local here.
end

return Gamepad
