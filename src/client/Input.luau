-- src/client/Input.luau
-- Input hub. The three input devices live in their own modules
-- (InputKeyboard, InputGamepad, InputTouch) and report directions through the
-- ctx table passed at init; this file owns only the shared plumbing: the
-- source table, the enable flag, the action signals and the public API.
-- Direction order is oldest press first, newest press last; Game treats the
-- last entry as the most recent direction.

local UserInputService = game:GetService("UserInputService")

local Keyboard = require(script.Parent:WaitForChild("InputKeyboard"))
local Gamepad = require(script.Parent:WaitForChild("InputGamepad"))
local Touch = require(script.Parent:WaitForChild("InputTouch"))

local Input = {}

Input.placePressed = Instance.new("BindableEvent")
Input.usePressed = Instance.new("BindableEvent")

local enabled = true
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

-- A pulse is a source that lasts a fixed number of input samples instead of
-- until someone clears it. It is aged by Input.sample(), which the client calls
-- exactly once per command it sends, so a pulse always reaches the server in
-- `ticks` consecutive commands however the frames are paced. A timer could expire
-- between two samples and drop the tap entirely.
local function pulseSource(source: string, direction: string, ticks: number)
    sequence += 1
    sources[source] = { direction = direction, order = sequence, ticksLeft = math.max(1, math.floor(ticks)) }
end

local function getSource(source: string): string?
    local entry = sources[source]
    return entry and entry.direction or nil
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

-- The directions for the command being built, then one tick of ageing for
-- pulses. Only the per-command sampler calls this; everything else peeks with
-- getDirs() so reading never changes state.
function Input.sample(): { string }
    local dirs = Input.getDirs()
    for name, entry in pairs(sources) do
        if entry.ticksLeft then
            entry.ticksLeft -= 1
            if entry.ticksLeft <= 0 then
                sources[name] = nil
            end
        end
    end
    return dirs
end

---------------------------------------------------------------- 初始化

function Input.init(gui: ScreenGui)
    local ctx = {
        setSource = setSource,
        pulseSource = pulseSource,
        getSource = getSource,
        placePressed = Input.placePressed,
        usePressed = Input.usePressed,
    }
    Keyboard.init(ctx, gui)
    Gamepad.init(ctx, gui)
    Touch.init(ctx, gui)

    UserInputService.WindowFocusReleased:Connect(function()
        clearSources()
        Keyboard.reset()
        Gamepad.reset()
        Touch.reset()
    end)
end

function Input.setEnabled(value: boolean)
    enabled = value
    Keyboard.setEnabled(value)
    Gamepad.setEnabled(value)
    Touch.setEnabled(value)
    if not enabled then
        clearSources()
    end
end

function Input.setControlsVisible(visible: boolean)
    Keyboard.setControlsVisible(visible)
    Gamepad.setControlsVisible(visible)
    Touch.setControlsVisible(visible)
end

return Input
