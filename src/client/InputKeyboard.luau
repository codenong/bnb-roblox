-- src/client/InputKeyboard.luau
-- Keyboard device: WASD and arrow keys for movement, Space / Ctrl / Shift / E
-- for actions. Each held key owns one source, so press order decides priority
-- when several keys are down at once.

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local Keyboard = {}

local ctx = nil
local enabled = true

local MOVE_KEYS = {
    [Enum.KeyCode.W] = "up",
    [Enum.KeyCode.Up] = "up",
    [Enum.KeyCode.S] = "down",
    [Enum.KeyCode.Down] = "down",
    [Enum.KeyCode.A] = "left",
    [Enum.KeyCode.Left] = "left",
    [Enum.KeyCode.D] = "right",
    [Enum.KeyCode.Right] = "right",
}

local PLACE_KEYS = {
    [Enum.KeyCode.Space] = true,
}

local USE_KEYS = {
    [Enum.KeyCode.LeftControl] = true,
    [Enum.KeyCode.RightControl] = true,
    [Enum.KeyCode.LeftShift] = true,
    [Enum.KeyCode.RightShift] = true,
    [Enum.KeyCode.E] = true,
}

---------------------------------------------------------------- 方向键

-- Roblox's default camera script binds the Left and Right arrow keys (and I/O)
-- through ContextActionService to rotate the camera. Those presses reach
-- UserInputService.InputBegan already marked as processed, which the handler in
-- init skips, so Left/Right did nothing while Up/Down (unclaimed) worked.
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
            ctx.setSource(source, direction)
        end
    else
        -- End, or Cancel when another binding takes the key away.
        ctx.setSource(source, nil)
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

function Keyboard.init(context, _gui)
    ctx = context
    claimArrowKeys()

    UserInputService.InputBegan:Connect(function(input, processed)
        local direction = MOVE_KEYS[input.KeyCode]
        if processed then
            return
        end

        if direction then
            if enabled then
                ctx.setSource("key_" .. input.KeyCode.Name, direction)
            end
            return
        end

        if PLACE_KEYS[input.KeyCode] then
            if enabled then
                ctx.placePressed:Fire()
            end
        elseif USE_KEYS[input.KeyCode] then
            if enabled then
                ctx.usePressed:Fire()
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        local direction = MOVE_KEYS[input.KeyCode]
        if direction then
            ctx.setSource("key_" .. input.KeyCode.Name, nil)
        end
    end)
end

function Keyboard.setEnabled(value: boolean)
    enabled = value
end

function Keyboard.setControlsVisible(_visible: boolean)
    -- Keyboard input owns no on-screen controls.
end

function Keyboard.reset()
    -- Sources are cleared centrally by the hub; nothing device-local here.
end

return Keyboard
