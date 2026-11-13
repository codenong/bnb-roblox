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

local input = touchAt(centerX, centerY)
begin(input)
check("pressing the centre does not move", dirs() == "", dirs())

drag(input, centerX + 40, centerY)
check("dragging right moves right", dirs() == "right", dirs())
drag(input, centerX, centerY - 40)
check("dragging up moves up", dirs() == "up", dirs())
drag(input, centerX - 40, centerY)
check("dragging left moves left", dirs() == "left", dirs())
drag(input, centerX, centerY + 40)
check("dragging down moves down", dirs() == "down", dirs())

-- Travel is 29px (106/2 - 40/2 - 4), so the 20% radial dead zone has a radius
-- of ~5.8px: pushes of 1px (≈3.4%) and 5px (≈17.2%) stay silent, 6px (≈20.7%)
-- responds.
drag(input, centerX + 1, centerY)
check("a tiny centre offset stays inside the 20% touch dead zone", dirs() == "", dirs())
drag(input, centerX + 5, centerY)
check("a push just inside 20% stays silent", dirs() == "", dirs())
drag(input, centerX + 6, centerY)
check("a push just past 20% responds", dirs() == "right", dirs())
drag(input, centerX + 3, centerY - 6)
check("a small diagonal past 20% picks the dominant axis", dirs() == "up", dirs())
drag(input, centerX + 15, centerY - 40)
check("a mostly vertical drag picks up", dirs() == "up", dirs())
drag(input, centerX + 40, centerY - 15)
check("a mostly horizontal drag picks right", dirs() == "right", dirs())

-- Holding past the top edge must keep the stick at full up deflection. Like a
-- physical joystick, the thumb may leave the base while the direction stays.
local far = touchAt(centerX, centerY - 300)
release(input)
begin(far)
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

-- The touch and physical gamepad dead zones are intentionally different. A
-- 20% gamepad tilt is inside its 35% threshold; touch responds at 20%.
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
local first = touchAt(centerX + 40, centerY)
local second = touchAt(centerX - 40, centerY)
begin(first)
surface.InputBegan:Fire(second)
check("a second joystick touch is ignored", dirs() == "right", dirs())
release(second)
check("releasing the ignored touch keeps moving", dirs() == "right", dirs())
release(first)
check("releasing the owning touch stops", dirs() == "", dirs())

-- Losing focus, disabling input and hiding the controls all release the stick.
input = touchAt(centerX, centerY - 40)
begin(input)
check("input is held before focus loss", dirs() == "up", dirs())
Env.fire("WindowFocusReleased")
check("focus loss releases the joystick", dirs() == "", dirs())
release(input)

input = touchAt(centerX + 40, centerY)
begin(input)
check("input is held before disabling", dirs() == "right", dirs())
Input.setEnabled(false)
check("disabling input releases the joystick", dirs() == "", dirs())
check("disabling recentres the knob", knob.Position.X.Offset == 0 and knob.Position.Y.Offset == 0)
Input.setEnabled(true)
release(input)

input = touchAt(centerX, centerY + 40)
begin(input)
check("input is held before hiding", dirs() == "down", dirs())
Input.setControlsVisible(false)
check("hiding controls releases the joystick", dirs() == "", dirs())
Input.setControlsVisible(true)
release(input)

check("touch controls remain shown after re-enabling", controls.Visible == true)

TestLib.finish()
