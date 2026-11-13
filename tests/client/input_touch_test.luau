-- Fixed touch joystick: layout, four-way mapping, knob bounds and release
-- semantics, using the real Input.luau with stubbed GUI objects.
local TestLib = require("./testlib")
local check = TestLib.check

local Env = require("./ClientEnv")
local Enum = Env.Enum
local Vector2, Vector3 = Env.Vector2, Env.Vector3

Env.game:GetService("UserInputService").TouchEnabled = true

local Input = require("./Input")
Input.init({})
Input.setEnabled(true)

local function find(name: string)
    for _, instance in ipairs(Env.instances) do
        if instance.Name == name then
            return instance
        end
    end
    return nil
end

local joystick = find("Joystick")
local knob = find("JoystickKnob")
local surface = find("JoystickSurface")
local controls = find("TouchControls")

check("touch controls replace the four-button pad", controls ~= nil and joystick ~= nil and knob ~= nil and surface ~= nil)
check("old D-pad is gone", find("DPad") == nil)
check("bubble and item buttons remain", find("泡泡") ~= nil and find("道具") ~= nil)
check("touch controls start hidden", controls.Visible == false)
Input.setControlsVisible(true)
check("touch controls can be shown", controls.Visible == true)

-- The base is anchored bottom-left at (24, H-24); this is what Roblox would
-- report through AbsolutePosition/AbsoluteSize while the joystick is visible.
joystick.AbsolutePosition = Vector2.new(24, 400)
joystick.AbsoluteSize = Vector2.new(106, 106)
local centerX = 24 + 106 / 2
local centerY = 400 + 106 / 2

local function touchAt(x: number, y: number)
    return {
        UserInputType = Enum.UserInputType.Touch,
        Position = Vector3.new(x, y, 0),
    }
end
local function begin(input)
    surface.InputBegan:Fire(input)
end
local function drag(input, x: number, y: number)
    input.Position = Vector3.new(x, y, 0)
    Env.fire("InputChanged", input)
end
local function release(input)
    Env.fire("InputEnded", input)
end
local function dirs(): string
    return table.concat(Input.getDirs(), ",")
end

-- The stick is relative to where the thumb lands. Constants under test (see
-- Input.luau): engage 5px, release 2.5px, leash 6px, axis bias 1.15.
local input = touchAt(centerX, centerY)
begin(input)
check("pressing the centre does not move", dirs() == "", dirs())

-- Landing is silent wherever on the base the thumb comes down: before, an
-- off-centre landing counted as full deflection and walked the player at once.
local edge = touchAt(centerX + 45, centerY + 20)
release(input)
begin(edge)
check("landing off-centre does not move", dirs() == "", dirs())
drag(edge, edge.Position.X + 4, edge.Position.Y)
check("a push under 5px stays silent", dirs() == "", dirs())
drag(edge, edge.Position.X + 1, edge.Position.Y)
check("a push past 5px moves", dirs() == "right", dirs())
drag(edge, edge.Position.X - 2, edge.Position.Y)
check("easing off to 3px keeps moving (hysteresis)", dirs() == "right", dirs())
drag(edge, edge.Position.X - 1, edge.Position.Y)
check("easing off below 2.5px stops", dirs() == "", dirs())
release(edge)

-- The four directions, each from a fresh landing.
local function pushFrom(dx: number, dy: number)
    local t = touchAt(centerX, centerY)
    begin(t)
    drag(t, centerX + dx, centerY + dy)
    local result = dirs()
    release(t)
    return result
end
check("dragging right moves right", pushFrom(20, 0) == "right")
check("dragging left moves left", pushFrom(-20, 0) == "left")
check("dragging up moves up", pushFrom(0, -20) == "up")
check("dragging down moves down", pushFrom(0, 20) == "down")

-- Axis hysteresis: from a diagonal the stick keeps its axis until the other one
-- wins by 30%, so a wobbling thumb does not flip right/up/right.
input = touchAt(centerX, centerY)
begin(input)
drag(input, centerX + 10, centerY)
check("moving right", dirs() == "right", dirs())
drag(input, centerX + 10, centerY - 6)
check("a vertical push that is not clearly stronger does not turn", dirs() == "right", dirs())
drag(input, centerX + 10, centerY - 8)
check("a clearly stronger vertical turns the corner (~7px of travel)", dirs() == "up", dirs())
drag(input, centerX + 10, centerY - 9)
drag(input, centerX + 10, centerY - 8)
check("and does not flip back on a small wobble", dirs() == "up", dirs())
release(input)

-- The reported bug: after pushing to the edge, going back the other way used
-- to need the thumb to cross the whole base. The anchor trails the thumb, so a
-- full reversal costs about LEASH + ENGAGE (6 + 5px) of travel, even if the
-- thumb had run far past the base.
input = touchAt(centerX, centerY)
begin(input)
drag(input, centerX + 90, centerY)
check("pushed far right", dirs() == "right", dirs())
check("the knob pins at the edge", TestLib.near(knob.Position.X.Offset, 29, 0.001), knob.Position.X.Offset)
drag(input, centerX + 90 - 3, centerY)
check("easing back 3px still moves right", dirs() == "right", dirs())
drag(input, centerX + 90 - 4, centerY)
check("easing back 4px stops", dirs() == "", dirs())
drag(input, centerX + 90 - 10, centerY)
check("10px back is still inside the restart threshold", dirs() == "", dirs())
drag(input, centerX + 90 - 11, centerY)
check("reversing 11px from the extreme moves left", dirs() == "left", dirs())
check("the knob follows the reversal", knob.Position.X.Offset < 0, knob.Position.X.Offset)
release(input)

-- Holding past the top edge keeps full deflection; the thumb may leave the base.
local far = touchAt(centerX, centerY)
begin(far)
drag(far, centerX, centerY - 300)
check("holding past the top edge moves up", dirs() == "up", dirs())
check("the knob pins at the top edge", TestLib.near(knob.Position.Y.Offset, -29, 0.001), knob.Position.Y.Offset)
surface.InputEnded:Fire(far)
check("the GUI losing the touch does not stop the stick", dirs() == "up", dirs())
drag(far, centerX, centerY - 500)
check("dragging farther still moves up", dirs() == "up", dirs())
release(far)
check("release stops movement", dirs() == "", dirs())
check("release recentres the knob",
    knob.Position.X.Offset == 0 and knob.Position.Y.Offset == 0,
    tostring(knob.Position.X.Offset) .. "," .. tostring(knob.Position.Y.Offset))

-- A new touch starts from its own landing point, not the previous anchor.
local again = touchAt(centerX + 30, centerY)
begin(again)
check("the next touch lands silent too", dirs() == "", dirs())
release(again)

-- The touch and physical gamepad dead zones are intentionally different. A
-- 20% gamepad tilt is inside its 35% threshold, a separate dead zone from touch.
local gamepad = {
    UserInputType = Enum.UserInputType.Gamepad1,
    KeyCode = Enum.KeyCode.Thumbstick1,
    Position = Vector3.new(0.2, 0, 0),
}
Env.fire("InputChanged", gamepad)
check("the physical gamepad keeps its 35% dead zone", dirs() == "", dirs())
gamepad.Position = Vector3.new(0.4, 0, 0)
Env.fire("InputChanged", gamepad)
check("the physical gamepad still moves past 35%", dirs() == "right", dirs())
gamepad.Position = Vector3.new(0, 0, 0)
Env.fire("InputChanged", gamepad)
check("centring the gamepad clears its direction", dirs() == "", dirs())

-- One movement touch owns the stick; a second finger must not steal it.
local first = touchAt(centerX, centerY)
local second = touchAt(centerX - 40, centerY)
begin(first)
drag(first, centerX + 40, centerY)
surface.InputBegan:Fire(second)
check("a second joystick touch is ignored", dirs() == "right", dirs())
release(second)
check("releasing the ignored touch keeps moving", dirs() == "right", dirs())
release(first)
check("releasing the owning touch stops", dirs() == "", dirs())

-- Losing focus, disabling input and hiding the controls all release the stick.
input = touchAt(centerX, centerY)
begin(input)
drag(input, centerX, centerY - 40)
check("input is held before focus loss", dirs() == "up", dirs())
Env.fire("WindowFocusReleased")
check("focus loss releases the joystick", dirs() == "", dirs())
release(input)

input = touchAt(centerX, centerY)
begin(input)
drag(input, centerX + 40, centerY)
check("input is held before disabling", dirs() == "right", dirs())
Input.setEnabled(false)
check("disabling input releases the joystick", dirs() == "", dirs())
check("disabling recentres the knob", knob.Position.X.Offset == 0 and knob.Position.Y.Offset == 0)
Input.setEnabled(true)
release(input)

input = touchAt(centerX, centerY)
begin(input)
drag(input, centerX, centerY + 40)
check("input is held before hiding", dirs() == "down", dirs())
Input.setControlsVisible(false)
check("hiding controls releases the joystick", dirs() == "", dirs())
Input.setControlsVisible(true)
release(input)

check("touch controls remain shown after re-enabling", controls.Visible == true)

TestLib.finish()
